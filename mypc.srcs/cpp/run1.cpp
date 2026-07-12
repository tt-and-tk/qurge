// 最初に作成したプログラム
// 文字を送ったら同じものが送り返されてくる

#include <iostream>
#include <string>
extern "C" {
#include <pynq_api.h>
}

int main(void) {
    char bit_path[] = "./bit/top_wrapper.bit";
    const int ADDR = 0x40400000;
    const int BURST_SIZE = 100;   // 一度に送れるのは100文字まで
    std::string line = "";

    // ビットファイルの準備
    PYNQ_loadBitstream(bit_path);

    // メモリの準備
    PYNQ_SHARED_MEMORY write_memory,read_memory;
    PYNQ_allocatedSharedMemory(&write_memory, sizeof(int) * BURST_SIZE, 1);
    PYNQ_allocatedSharedMemory(&read_memory, sizeof(int) * BURST_SIZE, 1);
    int *write_data = (int *)write_memory.pointer;
    int *read_data = (int *)read_memory.pointer;
    for (int i = 0; i < BURST_SIZE; i++) {
        write_data[i] = 0;
        read_data[i] = 0;
    }

    // DMAの準備
    PYNQ_AXI_DMA dma;
    PYNQ_openDMA(&dma, ADDR);

    // メイン部分
    while (line != "exit") {
        // 一行分の入力を受け付ける
        std::cout << ">>> ";
        std::cin >> line;

        // 標準入出力から読み込んだデータを送る
        for (int i = 0; i < line.size(); i++) {
            // データコピー
            write_data[0] = (int)line[i];

            // 文字列を出力する
            PYNQ_writeDMA(&dma, &write_memory, 0, sizeof(int) * 1);
            PYNQ_waitForDMAComplete(&dma, AXI_DMA_WRITE);
        }

        int line_size = line.size();
        for (int i = 0; i < line_size; i++) {
            // 文字列を受け取る
            PYNQ_readDMA(&dma, &read_memory, 0, sizeof(int) * 1);
            PYNQ_waitForDMAComplete(&dma, AXI_DMA_READ);

            // 受け取った文字列を出力する
            std::cout << (char)read_data[0];
        }
        std::cout << std::endl;
    }

    // DMAを閉じる
    PYNQ_closeDMA(&dma);
    PYNQ_freeSharedMemory(&write_memory);
    PYNQ_freeSharedMemory(&read_memory);

    return 0;
}
