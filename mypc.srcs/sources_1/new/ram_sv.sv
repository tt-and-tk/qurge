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

    // ワード数(1ワード=4バイトとしてRAM_SIZEを割った値．仕様上RM/WM 1回のアクセスは4バイトワード境界をまたがないため，
    // この単位でメモリを分割できる．詳細はspecification/memory.md参照)
    localparam int WORDS = RAM_SIZE / 4;

    // メモリに保存されるデータ．RAM全体を，物理番地 mod 4 == laneであるバイトだけを集めた4本の配列(レーン0〜3)に
    // 分割し，各レーンをBlock RAMへ推論させる．レーンの選択そのものを実行時の可変値で行うとBRAM推論の妨げになる
    // ため，4本を別名の配列として持ち，各レーンへのアクセスは常に静的な名前(memory_lane_0〜3)で行う
    (* ram_style = "block" *) logic [7:0] memory_lane_0 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_1 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_2 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_3 [0:WORDS - 1] = '{default: 8'h00};

    // レーンlaneが，このサイクルの32ビットデータバス(ram_read.data/ram_write.data)上のどの位置(0〜3バイト目)に
    // 対応するバイトを持っているかを求める
    function automatic logic [1:0] lane_to_pos(input logic [1:0] lane, input logic [1:0] addr_low);
        // データバス位置iはaddress+i番地を指すため，lane(== (address+i) mod 4 == (addr_low+i) mod 4)をiについて解く．
        // addr_lowが0(addressが4バイト境界に揃っている)ときはi=laneとなり，位置とレーンがそのまま一致する
        lane_to_pos = (4 + lane - addr_low) % 4;
    endfunction

    // 4本のレーンそれぞれが，このサイクルで対応するデータバス位置(0〜3)．読み出し・書き込みで別々に求める
    logic [1:0] read_pos_0, read_pos_1, read_pos_2, read_pos_3;
    assign read_pos_0 = lane_to_pos(2'd0, ram_read.address[1:0]);
    assign read_pos_1 = lane_to_pos(2'd1, ram_read.address[1:0]);
    assign read_pos_2 = lane_to_pos(2'd2, ram_read.address[1:0]);
    assign read_pos_3 = lane_to_pos(2'd3, ram_read.address[1:0]);

    logic [1:0] write_pos_0, write_pos_1, write_pos_2, write_pos_3;
    assign write_pos_0 = lane_to_pos(2'd0, ram_write.address[1:0]);
    assign write_pos_1 = lane_to_pos(2'd1, ram_write.address[1:0]);
    assign write_pos_2 = lane_to_pos(2'd2, ram_write.address[1:0]);
    assign write_pos_3 = lane_to_pos(2'd3, ram_write.address[1:0]);

    // 全レーン共通のワード番地(addressの下位2ビットを除いた部分．4バイトごとに1ワードとして扱う．0〜WORDS-1の範囲)
    logic [$clog2(WORDS)-1:0] read_word_addr;
    logic [$clog2(WORDS)-1:0] write_word_addr;
    assign read_word_addr  = ram_read.address[$bits(ram_read.address)-1:2];
    assign write_word_addr = ram_write.address[$bits(ram_write.address)-1:2];

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
                       // 既定値として0を書いたうえで，対応するマスクビットが立っていれば(かつ実容量内なら)配列の値で上書きする．
                       // BRAM推論の標準テンプレート(有効時のみ配列を読み出すif文，elseを伴わない)に合わせるため，
                       // 既定値の代入と配列読み出しの代入を分ける(elseへ定数を書くと配列読み出しと同居して推論の妨げになりうるため)
                       ram_read.data[read_pos_0*8 +: 8] <= 8'h00;
                       if (ram_read.mask[read_pos_0] && (read_word_addr < WORDS))
                           ram_read.data[read_pos_0*8 +: 8] <= memory_lane_0[read_word_addr];

                       ram_read.data[read_pos_1*8 +: 8] <= 8'h00;
                       if (ram_read.mask[read_pos_1] && (read_word_addr < WORDS))
                           ram_read.data[read_pos_1*8 +: 8] <= memory_lane_1[read_word_addr];

                       ram_read.data[read_pos_2*8 +: 8] <= 8'h00;
                       if (ram_read.mask[read_pos_2] && (read_word_addr < WORDS))
                           ram_read.data[read_pos_2*8 +: 8] <= memory_lane_2[read_word_addr];

                       ram_read.data[read_pos_3*8 +: 8] <= 8'h00;
                       if (ram_read.mask[read_pos_3] && (read_word_addr < WORDS))
                           ram_read.data[read_pos_3*8 +: 8] <= memory_lane_3[read_word_addr];
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
                       // 対応するマスクビットが立っているぶんだけ書き込む(立っていない・実容量を超える番地は元の値を保持する)
                       if (ram_write.mask[write_pos_0] && (write_word_addr < WORDS))
                           memory_lane_0[write_word_addr] <= ram_write.data[write_pos_0*8 +: 8];

                       if (ram_write.mask[write_pos_1] && (write_word_addr < WORDS))
                           memory_lane_1[write_word_addr] <= ram_write.data[write_pos_1*8 +: 8];

                       if (ram_write.mask[write_pos_2] && (write_word_addr < WORDS))
                           memory_lane_2[write_word_addr] <= ram_write.data[write_pos_2*8 +: 8];

                       if (ram_write.mask[write_pos_3] && (write_word_addr < WORDS))
                           memory_lane_3[write_word_addr] <= ram_write.data[write_pos_3*8 +: 8];
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
