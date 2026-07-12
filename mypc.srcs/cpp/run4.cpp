// CALL/RET命令の動作確認プログラム．
// FPGA(カスタムCPU)は起動直後にROM上のテストプログラムを実行し，
// 2階層のネスト関数呼び出しを行って「ABCDE」を1文字ずつ出力する．
// このPS側プログラムはその出力を受信して表示する．入力(SCAN)は使わない．
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
// 今回は受信(PL→PS)のみ使用する．

#include <iostream>
#include <string>
extern "C" {
#include <pynq_api.h>
}

int main(void) {
    char bit_path[] = "./bit/top_wrapper.bit";

    // AXI DMAのベースアドレス (Vivado Address Editorで /axi_dma_0/S_AXI_LITE に割り当てたアドレス)
    // PSはこのアドレスを通じてDMAの制御レジスタを読み書きし，転送を命令する
    const int ADDR = 0x40400000;

    const int BURST_SIZE = 100;   // 共有メモリに確保する要素数
    const int OUTPUT_SIZE = 5;    // FPGAが出力する文字数 (ABCDEの5文字)

    // ビットストリームをFPGAに書き込む．これによりPL側のカスタムCPUが起動する
    PYNQ_loadBitstream(bit_path);

    // PS-PL間でDMAが直接アクセスできる共有DDRメモリ領域を確保する．
    // 通常のmallocと異なり，DMAがアクセスできる物理アドレスが保証された領域になる．
    // write_memory: PSが値を書き込み，DMAがPLへ送り出す領域 (PS→PL方向，今回は未使用)
    // read_memory:  DMAがPLからの値を書き込み，PSが読み出す領域 (PL→PS方向)
    PYNQ_SHARED_MEMORY write_memory, read_memory;
    PYNQ_allocatedSharedMemory(&write_memory, sizeof(int) * BURST_SIZE, 1);
    PYNQ_allocatedSharedMemory(&read_memory, sizeof(int) * BURST_SIZE, 1);
    int *write_data = (int *)write_memory.pointer;  // write_memoryをint配列として扱うポインタ
    int *read_data  = (int *)read_memory.pointer;   // read_memoryをint配列として扱うポインタ
    for (int i = 0; i < BURST_SIZE; i++) {
        write_data[i] = 0;
        read_data[i] = 0;
    }

    // DMAを初期化する．ADDRのレジスタをメモリマップし，DMAを使える状態にする
    PYNQ_AXI_DMA dma;
    PYNQ_openDMA(&dma, ADDR);

    // メイン部分
    {
        // FPGAからの出力を1文字ずつ受信する
        // FPGAのCPUはPRINT命令で1文字ずつstdout_tdataに出力するため，
        // 1文字ごとに受信・完了待ちを繰り返す
        for (int i = 0; i < OUTPUT_SIZE; i++) {
            // DMAに「PLからsizeof(int)バイト受け取ってread_memoryに書け」と命令する
            // FPGAがPRINT命令でstdout_tdataに値を出力するまでここで待機する
            PYNQ_readDMA(&dma, &read_memory, 0, sizeof(int) * 1);
            PYNQ_waitForDMAComplete(&dma, AXI_DMA_READ);

            // 受信した文字を即座に表示する(どこまで出力されたか確認するため)
            std::cout << (char)read_data[0] << std::flush;
        }
        std::cout << std::endl;
    }

    // 使用したリソースを解放する
    PYNQ_closeDMA(&dma);
    PYNQ_freeSharedMemory(&write_memory);
    PYNQ_freeSharedMemory(&read_memory);

    return 0;
}
