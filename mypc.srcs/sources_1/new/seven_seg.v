`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2023/02/20 09:35:56
// Design Name:
// Module Name: seven_seg
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


module seven_seg(
    input [7:0] number,
    output [7:0] left_number,
    output [7:0] right_number
    );

    assign left_number = number2seg(number[7:4]);
    assign right_number = number2seg(number[3:0]);

    function [7:0] number2seg(input [3:0] number);

        case (number)
            4'h0: number2seg = ~8'b11111100;
            4'h1: number2seg = ~8'b01100000;
            4'h2: number2seg = ~8'b11011010;
            4'h3: number2seg = ~8'b11110010;
            4'h4: number2seg = ~8'b01100110;
            4'h5: number2seg = ~8'b10110110;
            4'h6: number2seg = ~8'b10111110;
            4'h7: number2seg = ~8'b11100000;
            4'h8: number2seg = ~8'b11111110;
            4'h9: number2seg = ~8'b11110110;
            4'ha: number2seg = ~8'b11101110;
            4'hb: number2seg = ~8'b00111110;
            4'hc: number2seg = ~8'b10011100;
            4'hd: number2seg = ~8'b01111010;
            4'he: number2seg = ~8'b10011110;
            4'hf: number2seg = ~8'b10001110;
        endcase

    endfunction

endmodule
