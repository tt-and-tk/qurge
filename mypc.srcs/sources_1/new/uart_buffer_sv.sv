`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/10/18 12:00:00
// Design Name:
// Module Name: uart_buffer_sv
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


// 入れた順にバイトを取り出すバッファ(FIFO)．バッファが空でなければ，取り出す指示を待たずに先頭のバイトを読める
// 中身はBlock RAMへ推論させる．Block RAMは番地を与えた次のサイクルに読めるため，
// 先頭のバイトと，バッファが空でないかは，取り出しや追加を受け付けた次のサイクルに変わる
module uart_buffer_sv #(
    parameter int DEPTH = 2048  // ためられるバイト数(2のべき乗)
    ) (
    input  logic       clk,
    input  logic       resetn,

    // 追加
    input  logic       push,       // この信号が1のサイクルに，追加するバイトを末尾へ加える(満杯なら加えない)
    input  logic [7:0] push_data,  // 追加するバイト
    output logic       not_full,   // 空きがあるか(1:ある)

    // 取り出し
    input  logic       pop,        // この信号が1のサイクルに，先頭のバイトを取り除く(空なら何もしない)
    output logic [7:0] head,       // 先頭のバイト(バッファが空の間は不定)
    output logic       not_empty   // バッファが空でないか(1:空でなく，先頭のバイトが有効)
    );

    localparam int INDEX_WIDTH = $clog2(DEPTH);  // 中身の番地のビット数

    // 追加・取り出しの位置．満杯と空を区別するため，中身の番地より1ビット広くし，上位1ビットで周回を数える
    typedef logic [INDEX_WIDTH:0] position_t;

    (* ram_style = "block" *) logic [7:0] memory [0:DEPTH - 1];  // 中身
    position_t write_position = '0;                              // 次に追加する位置
    position_t read_position = '0;                               // 先頭の位置
    position_t next_read_position;                               // 取り出しを反映した後の先頭の位置

    // 空きがあるか(追加した数と取り出した数の差がためられるバイト数に達していなければ空きがある)
    assign not_full = (write_position - read_position) != position_t'(DEPTH);

    // 取り出しを受け付けたら，先頭の位置を1つ進める
    assign next_read_position = read_position + position_t'(pop && not_empty);

    always_ff @(posedge clk) begin
        // リセット
        // 中身はBlock RAMのため消さず，位置を戻して空にするだけにする(位置が空を表していれば，中身の値は使われない)
        if (!resetn) begin
            // 空にする
            write_position <= '0;
            read_position <= '0;
            not_empty <= 1'b0;
        end
        else begin
            // 取り出しを反映した後の先頭の位置から，1バイトを読む
            // 読んだ値は，バッファが空でないときだけ先頭のバイトとして使われる．空のバッファへ追加したサイクルは，書き込む前の番地から不定な値を読むが，このサイクルもバッファが空とみなされるため，その値は使われない
            head <= memory[next_read_position[INDEX_WIDTH - 1:0]];
            // 空きがあれば，追加するバイトを末尾へ書き込み，追加の位置を1つ進める
            if (push && not_full) begin
                memory[write_position[INDEX_WIDTH - 1:0]] <= push_data;
                write_position <= write_position + 1'b1;
            end
            // 先頭の位置を，取り出しを反映した位置へ進める
            read_position <= next_read_position;
            // バッファが空でないかを求める
            // このサイクルに追加したバイトは，次のサイクルにならないと先頭のバイトとして読めないため，追加したサイクルはまだ空とみなす(追加前の位置と比べる)
            not_empty <= write_position != next_read_position;
        end
    end

endmodule
