`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2024/07/06 13:34:58
// Design Name:
// Module Name: mother_board
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


module mother_board(
    input  wire clk,
    input  wire resetn,

    // 割り算回路用
    output wire [31:0] divisor_tdata,
    output wire        divisor_tvalid,
    output wire [31:0] dividend_tdata,
    output wire        dividend_tvalid,
    input  wire [63:0] dout_tdata,
    input  wire        dout_tvalid,

    // 標準入力用
    input  wire [31:0] stdin_tdata,
    input  wire [ 3:0] stdin_tkeep,
    input  wire        stdin_tlast,
    output wire        stdin_tready,
    input  wire        stdin_tvalid,

    // 標準出力用
    output wire [31:0] stdout_tdata,
    output wire [ 3:0] stdout_tkeep,
    output wire        stdout_tlast,
    input  wire        stdout_tready,
    output wire        stdout_tvalid,

    // デバッグ用
    input  wire [ 3:0] btn,
    input  wire [ 1:0] sw,
    output wire [ 3:0] led,
    output wire [ 5:0] rgb_led,
    output wire [ 7:0] number
    );

    mother_board_sv mother_board_sv_0 (
        .clk(clk), .resetn(resetn),

        .divisor_tdata(divisor_tdata),
        .divisor_tvalid(divisor_tvalid),
        .dividend_tdata(dividend_tdata),
        .dividend_tvalid(dividend_tvalid),
        .dout_tdata(dout_tdata),
        .dout_tvalid(dout_tvalid),

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

        .btn(btn),
        .sw(sw),
        .led(led),
        .rgb_led(rgb_led),
        .number(number)
    );

endmodule
