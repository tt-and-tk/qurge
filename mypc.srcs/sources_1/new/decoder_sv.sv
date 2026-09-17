`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2025/04/20 16:22:23
// Design Name:
// Module Name: decoder_sv
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


`include "decoder.svh"

module decoder_sv (
    command_if.slave command
    );

    // 組み合わせ回路
    always_comb begin
        // 機械語を展開
        command.m_type = command.machine[31 + 32:29 + 32];
        command.func   = command.machine[28 + 32:23 + 32];
        command.mask   = command.machine[22 + 32:19 + 32];
        command.rs1    = command.machine[18 + 32:13 + 32];
        command.rs2    = command.machine[12 + 32: 7 + 32];
        command.rd     = command.machine[ 6 + 32: 1 + 32];
        command.imm    = command.machine[32:0];
    end

endmodule
