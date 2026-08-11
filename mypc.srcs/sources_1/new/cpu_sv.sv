`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2025/04/19 20:35:14
// Design Name:
// Module Name: cpu_sv
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


`include "machine.svh"
`include "rom.svh"
`include "decoder.svh"

module cpu_sv import machine_p::*; (
    input logic clk,
    input logic resetn,

    rom_read_if.master rom_read,

    ram_read_if.master ram_read,
    ram_write_if.master ram_write,

    // 割り算回路用
    output logic [31:0] divisor_tdata,
    output logic        divisor_tvalid,
    output logic [31:0] dividend_tdata,
    output logic        dividend_tvalid,
    input  logic [63:0] dout_tdata,
    input  logic        dout_tvalid,

    // IO
    input  logic [3:0] btn,
    input  logic [1:0] sw,
    output logic [3:0] led,
    output logic [5:0] rgb_led,
    output logic [7:0] number,

    // 標準入力
    input  logic [31:0] stdin_tdata,
    input  logic [ 3:0] stdin_tkeep,
    input  logic        stdin_tlast,
    output logic        stdin_tready,
    input  logic        stdin_tvalid,

    // 標準出力
    output logic [31:0] stdout_tdata,
    output logic [ 3:0] stdout_tkeep,
    output logic        stdout_tlast,
    input  logic        stdout_tready,
    output logic        stdout_tvalid
    );

    // コマンド取得インターフェース
    command_if command();

    // デコーダー
    decoder_sv decoder_sv_0(
        .resetn(resetn),
        .command(command)
    );

    // ALU
    alu_sv alu_sv_0(
        .clk(clk), .resetn(resetn),
        .rom_read(rom_read),
        .command(command),
        .ram_read(ram_read),
        .ram_write(ram_write),
        // 割り算回路用
        .divisor_tdata(divisor_tdata),
        .divisor_tvalid(divisor_tvalid),
        .dividend_tdata(dividend_tdata),
        .dividend_tvalid(dividend_tvalid),
        .dout_tdata(dout_tdata),
        .dout_tvalid(dout_tvalid),
        .btn(btn),
        .sw(sw),
        .led(led),
        .rgb_led(rgb_led),
        .number(number),
        // 標準入出力
        .stdin_tdata(stdin_tdata),
        .stdin_tkeep(stdin_tkeep),
        .stdin_tlast(stdin_tlast),
        .stdin_tready(stdin_tready),
        .stdin_tvalid(stdin_tvalid),
        .stdout_tdata(stdout_tdata),
        .stdout_tkeep(stdout_tkeep),
        .stdout_tlast(stdout_tlast),
        .stdout_tready(stdout_tready),
        .stdout_tvalid(stdout_tvalid)
    );

endmodule
