`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2024/07/02 20:50:34
// Design Name:
// Module Name: ram_sv
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


`include "ram.svh"
`include "util.svh"

module ram_sv import ram_p::*, util_p::*; (
    input  logic clk,
    input  logic resetn,

    // メモリデータ読み出し
    ram_read_if.slave ram_read,

    // メモリデータ書き込み
    ram_write_if.slave ram_write
    );

    // メモリに保存されるデータ
    memory_t memory_data = '{default: 8'h00};

    // メモリ読み出し・書き込み状態
    state_enum ram_read_state = IDLE;
    state_enum ram_write_state = IDLE;

    always_ff @(posedge clk) begin
        // リセット
        if (!resetn) begin
            // IO
            ram_read.data <= 32'b0;
            ram_read.ready <= 1'b0;
            ram_read.code <= NONE;
            ram_write.ready <= 1'b0;
            ram_write.code <= NONE;

            // 内部変数
            memory_data <= '{default: 8'h00};
            ram_read_state <= IDLE;
            ram_write_state <= IDLE;
        end
        // メモリ実行
        else begin
            // メモリデータ読み出し
            unique case (ram_read_state)
                // 待機
                IDLE: begin
                    ram_read.code <= NONE;
                    // 読み出し命令を検知
                    if (ram_read.valid) begin
                        ram_read_state <= EXECUTE;
                    end
                end

                // メモリ読み込み実行
                EXECUTE: begin
                    if (ram_read.valid) begin
                        ram_read.ready <= 1'b1;
                       // マスクに応じて読み込み(iはint型のため，実容量超過をラップアラウンドせず判定できる)
                       foreach (ram_read.mask[i]) begin
                           if (ram_read.mask[i] && (int'(ram_read.address) + i < RAM_SIZE))
                               // 32ビットのうち，8ビット分を出力
                               ram_read.data[i*8 + 7:i*8] <= memory_data[ram_read.address + i];
                           else
                               // マスクが立っていない，または実容量を超える番地は0を返す
                               ram_read.data[i*8 + 7:i*8] <= 8'h00;
                       end
                        // 読み込みラスト？
                        if (ram_read.last) begin
                            ram_read_state <= RESPONSE;
                        end
                    end else begin
                        ram_read.ready <= 1'b0;
                    end
                end

                // メモリ読み込みの実行結果を返す
                RESPONSE: begin
                    ram_read.ready <= 1'b0;
                    ram_read.code <= SUCCESS;
                    ram_read_state <= IDLE;
                end
            endcase

            // メモリデータ書き込み
            unique case (ram_write_state)
                // 待機
                IDLE: begin
                    ram_write.code <= NONE;
                    // 書き込み命令を検知
                    if (ram_write.valid) begin
                        ram_write_state <= EXECUTE;
                    end
                end

                // メモリ書き込み実行
                EXECUTE: begin
                    if (ram_write.valid) begin
                        ram_write.ready <= 1'b1;
                       // マスクに応じて書き込み(マスクが立っていない番地・実容量を超える番地は元の値を保持する)
                       foreach (ram_write.mask[i]) begin
                           if (ram_write.mask[i] && (int'(ram_write.address) + i < RAM_SIZE))
                               // 32ビットのうち，8ビット分を入力
                               memory_data[ram_write.address + i] <= ram_write.data[i*8 + 7:i*8];
                       end
                        // 書き込みラスト？
                        if (ram_write.last) begin
                            ram_write_state <= RESPONSE;
                        end
                    end else begin
                        ram_write.ready <= 1'b0;
                    end
                end

                // メモリ書き込みの実行結果を返す
                RESPONSE: begin
                    ram_write.ready <= 1'b0;
                    ram_write.code <= SUCCESS;
                    ram_write_state <= IDLE;
                end
            endcase
        end
    end

endmodule
