// 一桁と一桁の足し算を行う．
// 結果は任意の桁数になりうる（例: 5+6=11）．
// 入力は「数値1+数値2=」の形式で1文字ずつFPGAへ送信し，
// 出力はFPGAが出力しなくなるまで（デッドロックするまで）1文字ずつ受け取る．
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

    const int BURST_SIZE = 100;   // 一度に送れるのは100文字まで
    std::string line = "";

    // ビットストリームをFPGAに書き込む．これによりPL側のカスタムCPUが起動する
    PYNQ_loadBitstream(bit_path);

    // PS-PL間でDMAが直接アクセスできる共有DDRメモリ領域を確保する．
    // 通常のmallocと異なり，DMAがアクセスできる物理アドレスが保証された領域になる．
    // write_memory: PSが値を書き込み，DMAがPLへ送り出す領域 (PS→PL方向)
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
        // 計算式の入力
        std::cout << "計算式を入力してください" << std::endl;
        std::cin >> line;

        // 入力された計算式を1文字ずつFPGAへ送信する
        // FPGAのCPUは1文字ずつSCAN命令で受け取るため，1文字ごとに転送・完了待ちを繰り返す
        for (int i = 0; i < line.size(); i++) {
            // 送信したい文字コードをDDRメモリ(write_data)に書き込む
            // FPGAのstdin_tdataは32bitなので，char→intでゼロ拡張して格納する
            // 例: '1' → 0x00000031
            write_data[0] = (int)line[i];

            // DMAに対して「write_memoryの先頭からsizeof(int)バイト分をPLへ送れ」と命令する
            // DMAはDDRからデータを読み出し，AXI StreamでFPGAのstdin_tdataへ転送する
            PYNQ_writeDMA(&dma, &write_memory, 0, sizeof(int) * 1);

            // FPGAがSCAN命令でデータを受け取り，DMA転送が完了するまで待機する
            // 完了 = FPGAがtready=1にしてAXI Streamのハンドシェイクが成立したとき
            PYNQ_waitForDMAComplete(&dma, AXI_DMA_WRITE);
        }

        // FPGAからの出力を受け取る（FPGAが出力しなくなるとデッドロック）
        while (true) {
            PYNQ_readDMA(&dma, &read_memory, 0, sizeof(int) * 1);
            PYNQ_waitForDMAComplete(&dma, AXI_DMA_READ);
            std::cout << (char)read_data[0] << std::flush;
        }
    }

    // 使用したリソースを解放する
    PYNQ_closeDMA(&dma);
    PYNQ_freeSharedMemory(&write_memory);
    PYNQ_freeSharedMemory(&read_memory);

    return 0;
}
