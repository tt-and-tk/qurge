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

    localparam int CAPACITY = rom_p::MAX_LINE_NUM;  // 格納できる命令数の上限(ROMの命令数の上限と同じ．末尾の番地の命令も検証できるようにするため)

    machine_t machines[0:CAPACITY - 1];  // 命令列
    int size = 0;                        // 有効な命令数．これ以降の番地はROMの範囲外として扱う

    // 命令列を書き込み，その長さを有効な命令数とする．上限を超える命令列を渡すとシミュレーションを終える
    function automatic void load(input machine_t instructions[$]);
        // 先頭の番地から書き込む
        place(0, instructions);
    endfunction

    // 命令列を指定した番地から書き込み，書き込んだ最後の番地までを有効な命令数とする．
    // 間に書き込んでいない番地があれば，前に書き込んだ命令が残ったまま有効な範囲に含まれる．
    // 上限を超える範囲へ書き込もうとするとシミュレーションを終える
    function automatic void place(input int addr, input machine_t instructions[$]);
        // 上限を超える範囲は格納できないため，テストケースの誤りとして終える
        if (addr + instructions.size() > CAPACITY)
            $fatal(1, "tb_rom: 番地%0dから%0d命令を書き込むと上限%0dを超えます", addr, instructions.size(), CAPACITY);
        // 指定した番地から順に書き込む
        foreach (instructions[i])
            machines[addr + i] = instructions[i];
        // 書き込んだ最後の番地の次までを有効な命令数とする
        size = addr + instructions.size();
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
