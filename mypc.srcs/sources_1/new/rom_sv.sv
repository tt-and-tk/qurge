`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2025/04/19 20:51:41
// Design Name:
// Module Name: rom_sv
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

`include "rom.svh"
`include "machine.svh"
`include "register.svh"

module rom_sv (
    // メモリデータ読み出し
    rom_read_if.slave rom_read
    );
    // import文
    import machine_p::*;

    localparam integer ROM_SIZE = 25;

    // ===== 定数 =====
    // プログラムアドレス
    localparam logic [31:0] HALT_ADDR  = 32'd20;  // 停止用の無限ループのPC
    localparam logic [31:0] EMPTY_ADDR = 32'd21;  // 戻るだけの関数の先頭PC
    localparam logic [31:0] OUTER_ADDR = 32'd22;  // ネスト呼び出しの外側の関数の先頭PC
    localparam logic [31:0] INNER_ADDR = 32'd24;  // ネスト呼び出しの内側の関数の先頭PC
    // 分岐のイミディエイトデータ(分岐命令自身のPCからの相対値)
    localparam logic [31:0] LOOP_BACK = -32'd3;  // 繰り返しの先頭へ戻る(3つ手前)
    localparam logic [31:0] SKIP_ONE  =  32'd2;  // 次の1命令を飛ばす
    // レジスタ
    localparam addr_t REG_COUNT = 6'h00;  // 繰り返しの回数
    localparam addr_t REG_LIMIT = 6'h01;  // 繰り返しを終える回数
    localparam addr_t REG_STEP  = 6'h02;  // 繰り返しごとの増分
    localparam addr_t REG_CHAR  = 6'h03;  // 出力する文字
    localparam addr_t REG_ADDR  = 6'h04;  // 移動先・呼び出し先の番地
    // 文字コード
    localparam logic [31:0] CHAR_ZERO = 32'h30;  // 文字「0」
    localparam logic [31:0] CHAR_O    = 32'h4f;  // 文字「O」
    localparam logic [31:0] CHAR_K    = 32'h4b;  // 文字「K」
    localparam logic [31:0] CHAR_X    = 32'h58;  // 文字「X」

    // 制御ハザード動作確認プログラム
    // 後方分岐による繰り返し，連続した分岐，出力の直後の分岐，戻るだけの関数の呼び出し，
    // ネストした呼び出し，飛び先をレジスタで指定する呼び出し・移動を通過し，正常なら
    // 「012OK」を出力する(分岐の判定を誤ると「X」が混ざるか出力が止まる)
    machine_t machines[0:ROM_SIZE - 1] = {
        // ===== 繰り返しの準備 =====
        mov(0, 0, REG_CHAR,  {1'b1, CHAR_ZERO}),      // PC=0: 出力する文字を「0」にする
        mov(0, 0, REG_COUNT, {1'b1, 32'd0}),          // PC=1: 回数を0にする
        mov(0, 0, REG_LIMIT, {1'b1, 32'd3}),          // PC=2: 3回繰り返す設定にする
        mov(0, 0, REG_STEP,  {1'b1, 32'd1}),          // PC=3: 増分を1にする

        // ===== 繰り返し本体(後方分岐の飛び先が複数サイクルを要する命令になる) =====
        print(REG_CHAR, 0),                           // PC=4: 「0」「1」「2」を順に出力する
        add(REG_CHAR, REG_STEP, REG_CHAR),            // PC=5: 次に出力する文字へ進める
        add(REG_COUNT, REG_STEP, REG_COUNT),          // PC=6: 回数を1つ進める
        lt(REG_COUNT, REG_LIMIT, {1'b1, LOOP_BACK}),  // PC=7: 3回に満たなければ繰り返しの先頭へ戻る

        // ===== 連続した分岐 =====
        ne(REG_COUNT, REG_LIMIT, {1'b1, SKIP_ONE}),   // PC=8: 3回に達しているため成立せず次へ進む
        eq(REG_COUNT, REG_LIMIT, {1'b1, SKIP_ONE}),   // PC=9: 3回に達しているため成立し次を飛ばす
        print(0, {1'b1, CHAR_X}),                     // PC=10: 飛ばされるはずの命令

        // ===== 番地を直接指定する関数呼び出し =====
        call(0, {1'b1, EMPTY_ADDR}),                  // PC=11: 戻るだけの関数を呼び出す
        print(0, {1'b1, CHAR_O}),                     // PC=12: 「O」を出力する

        // ===== 出力の直後の分岐 =====
        eq(REG_COUNT, REG_LIMIT, {1'b1, SKIP_ONE}),   // PC=13: 3回に達しているため成立し次を飛ばす
        print(0, {1'b1, CHAR_X}),                     // PC=14: 飛ばされるはずの命令

        // ===== 飛び先をレジスタで指定する関数呼び出し =====
        mov(0, 0, REG_ADDR, {1'b1, OUTER_ADDR}),      // PC=15: 呼び出し先の番地を用意する
        call(REG_ADDR, 0),                            // PC=16: ネストした呼び出しを行う
        print(0, {1'b1, CHAR_K}),                     // PC=17: 「K」を出力する

        // ===== 飛び先をレジスタで指定する移動 =====
        mov(0, 0, REG_ADDR, {1'b1, HALT_ADDR}),       // PC=18: 移動先の番地を用意する
        jmp(REG_ADDR, 0),                             // PC=19: 停止処理へ移動する

        // ===== 停止 =====
        jmp(0, {1'b1, HALT_ADDR}),                    // PC=20: 無限ループで停止する

        // ===== 戻るだけの関数 =====
        ret(),                                        // PC=21: 呼び出し元へ戻る

        // ===== ネスト呼び出しの外側 =====
        call(0, {1'b1, INNER_ADDR}),                  // PC=22: 内側の関数を呼び出す
        ret(),                                        // PC=23: 呼び出し元へ戻る

        // ===== ネスト呼び出しの内側 =====
        ret()                                         // PC=24: 外側の関数へ戻る
    };

    // メモリデータの読み出し
    always_comb begin
        if (rom_read.pc >= ROM_SIZE) begin
            rom_read.machine = nop();
        end else begin
            rom_read.machine = machines[rom_read.pc];
        end
    end

endmodule
