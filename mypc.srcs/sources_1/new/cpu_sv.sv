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

    // 符号あり割り算回路用
    output logic [31:0] div_divisor_tdata,
    output logic        div_divisor_tvalid,
    output logic [31:0] div_dividend_tdata,
    output logic        div_dividend_tvalid,
    input  logic [63:0] div_dout_tdata,
    input  logic        div_dout_tvalid,

    // 符号なし割り算回路用
    output logic [31:0] divu_divisor_tdata,
    output logic        divu_divisor_tvalid,
    output logic [31:0] divu_dividend_tdata,
    output logic        divu_dividend_tvalid,
    input  logic [63:0] divu_dout_tdata,
    input  logic        divu_dout_tvalid,

    // IO
    input  logic [3:0] btn,
    input  logic [1:0] sw,
    output logic [3:0] led,
    output logic [5:0] rgb_led,

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
    output logic        stdout_tvalid,

    // Pmod A・Pmod B
    output logic [7:0] ja,
    output logic [7:0] jb,

    // Arduino
    output logic [13:0] ar,
    output logic         a,
    output logic         ar_sda,
    output logic         ar_scl,
    output logic         ck_mosi,
    output logic         ck_sck,
    output logic         ck_ss,
    input  logic         ck_miso,

    // ラズパイヘッダー
    output logic [26:8] gpio
    );

    // コマンド取得インターフェース
    command_if command();

    // デコーダー
    decoder_sv decoder_sv_0(
        .command(command)
    );

    // ALU
    alu_sv alu_sv_0(
        .clk(clk), .resetn(resetn),
        .rom_read(rom_read),
        .command(command),
        .ram_read(ram_read),
        .ram_write(ram_write),
        // 符号あり割り算回路用
        .div_divisor_tdata(div_divisor_tdata),
        .div_divisor_tvalid(div_divisor_tvalid),
        .div_dividend_tdata(div_dividend_tdata),
        .div_dividend_tvalid(div_dividend_tvalid),
        .div_dout_tdata(div_dout_tdata),
        .div_dout_tvalid(div_dout_tvalid),
        // 符号なし割り算回路用
        .divu_divisor_tdata(divu_divisor_tdata),
        .divu_divisor_tvalid(divu_divisor_tvalid),
        .divu_dividend_tdata(divu_dividend_tdata),
        .divu_dividend_tvalid(divu_dividend_tvalid),
        .divu_dout_tdata(divu_dout_tdata),
        .divu_dout_tvalid(divu_dout_tvalid),
        .btn(btn),
        .sw(sw),
        .led(led),
        .rgb_led(rgb_led),
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
        .stdout_tvalid(stdout_tvalid),
        .ja(ja),
        .jb(jb),
        .ar(ar),
        .a(a),
        .ar_sda(ar_sda),
        .ar_scl(ar_scl),
        .ck_mosi(ck_mosi),
        .ck_sck(ck_sck),
        .ck_ss(ck_ss),
        .ck_miso(ck_miso),
        .gpio(gpio)
    );

endmodule
