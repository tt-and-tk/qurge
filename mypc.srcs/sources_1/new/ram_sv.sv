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

    // 1ワード(4バイト)あたりのワード数(仕様上，RM/WM 1回のアクセスは4バイトワード境界をまたがないためこの単位で分割できる．詳細はspecification/memory.md参照)．
    // addressのビット幅はRAM_SIZEからちょうど決まる($clog2(RAM_SIZE))ため，現状のパラメータでは以下のWORDS境界チェックは常に真になるが，
    // RAM_SIZEが4の倍数以外に変わった場合の安全策として残す
    localparam int WORDS = RAM_SIZE / 4;

    // メモリに保存されるデータ．4バイトを4本の独立したバイトレーンに分割する(1本の配列のまま複数番地へ同時アクセスする形だと
    // Block RAMの1ポート=1番地という制約と噛み合わずBRAMへ推論されないため，レーンごとに単一番地アクセスへ揃える)．
    // レーンを選ぶ添字が実行時の可変値だとBRAM推論の妨げになるため，4本を別名の配列として持ち，各レーンへのアクセスは
    // 常に静的な名前(memory_lane_0〜3)で行う(どの位置iのデータをどのレーンに読み書きするかだけを動的に計算する)
    (* ram_style = "block" *) logic [7:0] memory_lane_0 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_1 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_2 [0:WORDS - 1] = '{default: 8'h00};
    (* ram_style = "block" *) logic [7:0] memory_lane_3 [0:WORDS - 1] = '{default: 8'h00};

    // レーンlane(0〜3の固定値)が，addressの下位2ビット(addr_low)のとき，データバス上のどの位置(0〜3)に対応するかを求める
    // (addressが4バイト境界からずれているぶんだけ，レーンとデータバス位置の対応が巡回シフトする)
    function automatic logic [1:0] lane_to_pos(input logic [1:0] lane, input logic [1:0] addr_low);
        lane_to_pos = (4 + lane - addr_low) % 4;
    endfunction

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
                       // 4本のレーンそれぞれ，このサイクルでデータバス上のどの位置(pos)に対応するかを求める．
                       // 既定値として0を書いたうえで，対応するマスクビットが立っていれば(かつ実容量内なら)配列の値で上書きする．
                       // BRAM推論の標準テンプレート(有効時のみ配列を読み出すif文，elseを伴わない)に合わせるため，
                       // 既定値の代入と配列読み出しの代入を分ける(elseへ定数を書くと配列読み出しと同居して推論の妨げになりうるため)
                       ram_read.data[lane_to_pos(2'd0, ram_read.address[1:0])*8 +: 8] <= 8'h00;
                       if (ram_read.mask[lane_to_pos(2'd0, ram_read.address[1:0])] && (ram_read.address[$bits(ram_read.address)-1:2] < WORDS))
                           ram_read.data[lane_to_pos(2'd0, ram_read.address[1:0])*8 +: 8] <= memory_lane_0[ram_read.address[$bits(ram_read.address)-1:2]];

                       ram_read.data[lane_to_pos(2'd1, ram_read.address[1:0])*8 +: 8] <= 8'h00;
                       if (ram_read.mask[lane_to_pos(2'd1, ram_read.address[1:0])] && (ram_read.address[$bits(ram_read.address)-1:2] < WORDS))
                           ram_read.data[lane_to_pos(2'd1, ram_read.address[1:0])*8 +: 8] <= memory_lane_1[ram_read.address[$bits(ram_read.address)-1:2]];

                       ram_read.data[lane_to_pos(2'd2, ram_read.address[1:0])*8 +: 8] <= 8'h00;
                       if (ram_read.mask[lane_to_pos(2'd2, ram_read.address[1:0])] && (ram_read.address[$bits(ram_read.address)-1:2] < WORDS))
                           ram_read.data[lane_to_pos(2'd2, ram_read.address[1:0])*8 +: 8] <= memory_lane_2[ram_read.address[$bits(ram_read.address)-1:2]];

                       ram_read.data[lane_to_pos(2'd3, ram_read.address[1:0])*8 +: 8] <= 8'h00;
                       if (ram_read.mask[lane_to_pos(2'd3, ram_read.address[1:0])] && (ram_read.address[$bits(ram_read.address)-1:2] < WORDS))
                           ram_read.data[lane_to_pos(2'd3, ram_read.address[1:0])*8 +: 8] <= memory_lane_3[ram_read.address[$bits(ram_read.address)-1:2]];
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
                       // 読み出しと同様，4本のレーンそれぞれが対応するデータバス上の位置(pos)を求め，
                       // 対応するマスクビットが立っているぶんだけ書き込む(立っていない・実容量を超える番地は元の値を保持する)
                       if (ram_write.mask[lane_to_pos(2'd0, ram_write.address[1:0])] && (ram_write.address[$bits(ram_write.address)-1:2] < WORDS))
                           memory_lane_0[ram_write.address[$bits(ram_write.address)-1:2]] <= ram_write.data[lane_to_pos(2'd0, ram_write.address[1:0])*8 +: 8];

                       if (ram_write.mask[lane_to_pos(2'd1, ram_write.address[1:0])] && (ram_write.address[$bits(ram_write.address)-1:2] < WORDS))
                           memory_lane_1[ram_write.address[$bits(ram_write.address)-1:2]] <= ram_write.data[lane_to_pos(2'd1, ram_write.address[1:0])*8 +: 8];

                       if (ram_write.mask[lane_to_pos(2'd2, ram_write.address[1:0])] && (ram_write.address[$bits(ram_write.address)-1:2] < WORDS))
                           memory_lane_2[ram_write.address[$bits(ram_write.address)-1:2]] <= ram_write.data[lane_to_pos(2'd2, ram_write.address[1:0])*8 +: 8];

                       if (ram_write.mask[lane_to_pos(2'd3, ram_write.address[1:0])] && (ram_write.address[$bits(ram_write.address)-1:2] < WORDS))
                           memory_lane_3[ram_write.address[$bits(ram_write.address)-1:2]] <= ram_write.data[lane_to_pos(2'd3, ram_write.address[1:0])*8 +: 8];
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
