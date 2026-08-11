// PS(ARM)側をダム端末として動かすターミナルエミュレータ．
// キー入力を受け取るたびに1文字ずつFPGA(PL側)へ送信し，
// FPGAからの出力を受け取り次第1文字ずつ画面へ表示する．
// 送信と受信は別スレッドで並行に動き，「全送信完了後にまとめて受信」のような
// ターン切り替えは行わない(入力の締め区切りや出力の終わりの判断はPL側のプログラムに委ねる)．
//
// 【DMAによるPS-PL間通信の概要】
// PS(ARM)からPL(FPGA)へのデータ送信は以下の流れで行われる:
//
//   [PS DDRメモリ(write_data)]
//          ↓ DMA(MM2S)がDDRからデータを読み出す
//   [AXI DMA]
//          ↓ AXI Streamでカスタム CPU IP へ転送
//   [PL: カスタムCPU (stdin_tdata)]
//
// PL(FPGA)からPS(ARM)へのデータ受信は逆の流れ:
//
//   [PL: カスタムCPU (stdout_tdata)]
//          ↓ AXI Streamで転送
//   [AXI DMA]
//          ↓ DMA(S2MM)がDDRへデータを書き込む
//   [PS DDRメモリ(read_data)]
//
// CPUプログラム側からは「変数に書いた値がFPGAに届く / FPGAが書いた値が変数に入る」
// という形で見える．実際のデータ転送はDMAがバックグラウンドで行う．
//
// 送信用と受信用でPYNQ_AXI_DMAのインスタンスを分けている．AXI DMA IP自体はMM2S(送信)と
// S2MM(受信)のレジスタがハードウェア的に独立しているが，PYNQ_AXI_DMA構造体(mmapした
// レジスタ領域へのポインタや割り込み待ちの内部状態)を複数スレッドから共有して安全かは
// ライブラリの実装に依存し，この開発環境からは確認できない．インスタンスを分けて
// 内部状態そのものを共有しない構成にすることで，この不確実性を回避する．

#include <csignal>
#include <iostream>
#include <mutex>
#include <thread>
#include <termios.h>
#include <unistd.h>
extern "C" {
#include <pynq_api.h>
}

// 標準出力への書き込みを送信側(ローカルエコー)・受信側の2スレッド間で排他するためのミューテックス．
// 特にバックスペース表示("\b \b"の3文字)の途中に受信スレッドの出力が割り込むと，画面上の
// カーソル位置とローカルエコー側が数えている表示済み文字数がずれてしまうため必要
std::mutex cout_mutex;

// SIGINTを受けたことを伝えるフラグ
class InterruptFlag {
public:
    static bool isSet() { return flag_ != 0; }
    static void onSigint(int) { flag_ = 1; }

private:
    inline static volatile std::sig_atomic_t flag_ = 0;
};

int main(void) {
    char bit_path[] = "./bit/top_wrapper.bit";

    // AXI DMAのベースアドレス (Vivado Address Editorで /axi_dma_0/S_AXI_LITE に割り当てたアドレス)
    // PSはこのアドレスを通じてDMAの制御レジスタを読み書きし，転送を命令する
    const int ADDR = 0x40400000;

    // ビットストリームをFPGAに書き込む．これによりPL側のカスタムCPUが起動する
    PYNQ_loadBitstream(bit_path);

    // PS-PL間でDMAが直接アクセスできる共有DDRメモリ領域を確保する．
    // 通常のmallocと異なり，DMAがアクセスできる物理アドレスが保証された領域になる．
    // write_memory: PSが値を書き込み，DMAがPLへ送り出す領域 (PS→PL方向)
    // read_memory:  DMAがPLからの値を書き込み，PSが読み出す領域 (PL→PS方向)
    PYNQ_SHARED_MEMORY write_memory, read_memory;
    PYNQ_allocatedSharedMemory(&write_memory, sizeof(int), 1);
    PYNQ_allocatedSharedMemory(&read_memory, sizeof(int), 1);
    int *write_data = (int *)write_memory.pointer;  // write_memoryをint扱いするポインタ
    int *read_data  = (int *)read_memory.pointer;   // read_memoryをint扱いするポインタ
    *write_data = 0;
    *read_data = 0;

    // 送信用・受信用でDMAインスタンスを分けて開く(内部状態を共有しないため)
    PYNQ_AXI_DMA write_dma, read_dma;
    PYNQ_openDMA(&write_dma, ADDR);
    PYNQ_openDMA(&read_dma, ADDR);

    // Ctrl+Cで端末設定を復元してから終了できるようにする(既定のSIGINT動作である即時終了だと，
    // rawモードの端末設定が復元されないまま残ってしまう)．rawモードへの切り替えより前に
    // 登録し，切り替え直後にSIGINTが届いても既定動作(即時終了)が働かないようにする．
    // ただし送信側が`PYNQ_waitForDMAComplete(&write_dma, AXI_DMA_WRITE)`で待機中にSIGINTが
    // 届いた場合，そこから抜けられるかどうかはライブラリの実装(EINTRで復帰するか)に依存し，
    // このコードだけでは保証できない
    std::signal(SIGINT, InterruptFlag::onSigint);

    // 標準入力を1文字ずつ即座に読めるよう，rawモードに切り替える
    // ICANON: 行バッファリングを無効化し，1文字入力されるたびにread()から返るようにする
    // ECHO:   無効化する．OSのローカルエコーはバックスペース(DEL, 0x7F)を送っても`^?`と
    //         表示するだけで直前の文字を消す動作をしないため，このプログラム自身が
    //         下記メインループでローカルエコーを行う(CPU(PL)側がエコーの要否を自ら制御できる
    //         ようになるまでの暫定対応であり，対応後はここを削除する(issue #65))
    termios original_termios, raw_termios;
    tcgetattr(STDIN_FILENO, &original_termios);
    raw_termios = original_termios;
    raw_termios.c_lflag &= ~(ICANON | ECHO);
    raw_termios.c_cc[VMIN] = 1;
    raw_termios.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw_termios);

    // 受信スレッド: FPGAからの出力を1文字受け取るたびに画面へ表示する．これを送信側と
    // 並行に動かすことで，入力の受け付けと出力の表示が互いを待たずに繰り返せるようにする
    std::thread receiver([&]() {
        while (!InterruptFlag::isSet()) {
            PYNQ_readDMA(&read_dma, &read_memory, 0, sizeof(int));
            PYNQ_waitForDMAComplete(&read_dma, AXI_DMA_READ);
            std::lock_guard<std::mutex> lock(cout_mutex);  // ローカルエコーとの出力順序が入れ替わらないようにする
            std::cout << (char)*read_data << std::flush;
        }
    });
    // FPGAが次の出力を送ってこない限りPYNQ_waitForDMACompleteから戻らない．join()(スレッドの
    // 終了をこの場で待ち合わせる操作)を呼ぶとその間メインスレッドも止まってしまうため，
    // 後始末はプロセス終了に委ねる(電源再投入前提の復帰ではなくプロセス終了を想定しており実害は小さい)．
    // そのため`read_dma`・`read_memory`はメインスレッド側でclose/freeしない
    // (受信スレッドがブロックしたまま使い続けている可能性があり，close/free後に
    //  アクセスするとuse-after-free相当の未定義動作になるため)
    receiver.detach();

    // ECHOを無効化した代わりにこのプログラム自身が行うローカルエコーで，直近の改行'\n'以降に
    // 画面へ表示した文字数(バックスペースで消してよい範囲の境界)を数えるカウンタ
    int echoed_count = 0;

    // メインスレッド: 標準入力から1文字読むたびに，ローカルエコーしてから都度FPGAへ送信する
    while (!InterruptFlag::isSet()) {
        char input_char;
        // rawモードのため1バイト入力されるとすぐに返る(シグナル受信時はEINTRで抜ける)
        ssize_t read_bytes = read(STDIN_FILENO, &input_char, 1);
        if (read_bytes == 0) {
            // 標準入力がEOFに達した(リダイレクトしたファイル/パイプの終端等)．
            // read()は以後も0を返し続けるため，busyループにしないためループを抜ける
            break;
        }
        // マルチバイト文字(UTF-8等)には対応しない
        if (read_bytes < 0) {
            continue;
        }

        // ローカルエコー．DMA送信より前に行うことで，DMA転送完了待ちの遅延が
        // キー入力から画面表示までのラグとして体感されないようにする
        {
            std::lock_guard<std::mutex> lock(cout_mutex);  // 受信スレッドの出力との割り込みを防ぐ
            if (input_char == 127) {
                // バックスペース(DEL)．直前の行頭以降に表示した文字がある場合のみ，
                // カーソルを戻して空白で上書きし，再度カーソルを戻すことで実際に1文字消す
                if (echoed_count > 0) {
                    std::cout << "\b \b" << std::flush;
                    echoed_count = echoed_count - 1;
                }
            } else {
                std::cout << input_char << std::flush;
                if (input_char == '\n') {
                    echoed_count = 0;  // 行が確定したので次の行の表示済み文字数を数え直す
                } else {
                    echoed_count = echoed_count + 1;
                }
            }
        }

        // 読んだ文字コードをDDRメモリ(write_data)に書き込む．FPGA側での削除処理の要否に関わらず，
        // DEL(0x7F)を含め読んだバイトをそのまま送る(バッファ上の削除はCPU/シェル側の責務とする)
        // FPGAのstdin_tdataは32bitなので，char→intでゼロ拡張して格納する
        // (charの符号性は環境依存のため，unsigned charを経由してゼロ拡張を確実にする)
        *write_data = (int)(unsigned char)input_char;

        // DMAに対して「write_memoryの先頭からsizeof(int)バイト分をPLへ送れ」と命令する
        PYNQ_writeDMA(&write_dma, &write_memory, 0, sizeof(int));

        // FPGAがSCAN命令でデータを受け取り，DMA転送が完了するまで待機する
        PYNQ_waitForDMAComplete(&write_dma, AXI_DMA_WRITE);
    }

    // 端末設定を元に戻してから終了する
    tcsetattr(STDIN_FILENO, TCSANOW, &original_termios);
    {
        std::lock_guard<std::mutex> lock(cout_mutex);  // detachされたまま動き続ける受信スレッドとの割り込みを防ぐ
        std::cout << std::endl;
    }

    // メインスレッドが単独で使っているリソース(送信側)のみ解放する．
    // 受信側(read_dma・read_memory)は受信スレッドが使用中の可能性があるため解放しない
    PYNQ_closeDMA(&write_dma);
    PYNQ_freeSharedMemory(&write_memory);

    return 0;
}
