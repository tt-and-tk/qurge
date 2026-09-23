`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// テストベンチ用のROM．rom_svと同じ同期読み出し(番地を出した次のサイクルに結果が確定し，
// 範囲外の番地ではvalidを0にしてnopを返す)を行い，命令列と有効な命令数をテストケースごとに書き換えられる
//////////////////////////////////////////////////////////////////////////////////


`include "rom.svh"
`include "machine.svh"

module tb_rom (
    input logic clk,
    rom_read_if.slave rom_read
    );
    import machine_p::*;

    localparam int CAPACITY = 256;  // 格納できる命令数の上限

    machine_t machines[0:CAPACITY - 1];  // 命令列
    int size = 0;                        // 有効な命令数．これ以降の番地はROMの範囲外として扱う

    // 命令列を書き込み，その長さを有効な命令数とする
    function automatic void load(input machine_t instructions[$]);
        if (instructions.size() > CAPACITY)
            $fatal(1, "tb_rom: 命令数%0dが上限%0dを超えています", instructions.size(), CAPACITY);
        foreach (instructions[i])
            machines[i] = instructions[i];
        size = instructions.size();
    endfunction

    always_ff @(posedge clk) begin
        rom_read.valid <= (rom_read.pc < size);

        if (rom_read.pc < size) begin
            rom_read.machine <= machines[rom_read.pc];
        end else begin
            rom_read.machine <= nop();
        end
    end

endmodule
