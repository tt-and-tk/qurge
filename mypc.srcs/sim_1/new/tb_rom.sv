`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// テストベンチ用のROM．rom_svと同じ同期読み出し(番地を出した次のサイクルに結果が確定し，
// 範囲外の番地ではvalidを0にしてnopを返す)を行い，命令列と有効な命令数をテストケースごとに書き換えられる
//////////////////////////////////////////////////////////////////////////////////


`include "rom.svh"
`include "machine.svh"

module tb_rom (
    input logic clk,               // クロック
    rom_read_if.slave rom_read     // 命令の読み出し
    );
    import machine_p::*;

    localparam int CAPACITY = 256;  // 格納できる命令数の上限

    machine_t machines[0:CAPACITY - 1];  // 命令列
    int size = 0;                        // 有効な命令数．これ以降の番地はROMの範囲外として扱う

    // 命令列を書き込み，その長さを有効な命令数とする．上限を超える命令列を渡すとシミュレーションを終える
    function automatic void load(input machine_t instructions[$]);
        // 上限を超える命令列は格納できないため，テストケースの誤りとして終える
        if (instructions.size() > CAPACITY)
            $fatal(1, "tb_rom: 命令数%0dが上限%0dを超えています", instructions.size(), CAPACITY);
        // 先頭の番地から順に書き込む
        foreach (instructions[i])
            machines[i] = instructions[i];
        // 書き込んだ長さを有効な命令数とする
        size = instructions.size();
    endfunction

    always_ff @(posedge clk) begin
        // 番地が有効な命令数に収まっているかを返す
        rom_read.valid <= (rom_read.pc < size);

        // 範囲内ならその番地の命令を，範囲外ならnopを返す
        if (rom_read.pc < size) begin
            rom_read.machine <= machines[rom_read.pc];
        end else begin
            rom_read.machine <= nop();
        end
    end

endmodule
