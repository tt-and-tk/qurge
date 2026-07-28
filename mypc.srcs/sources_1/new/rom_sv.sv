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

    localparam integer ROM_SIZE = 21;

    // ===== 定数 =====
    // プログラムアドレス
    localparam integer HALT_ADDR  = 32'h10;  // 停止用の無限ループのPC
    localparam integer EMPTY_ADDR = 32'h11;  // 戻るだけの関数の先頭PC
    localparam integer OUTER_ADDR = 32'h12;  // ネスト呼び出しの外側の関数の先頭PC
    localparam integer INNER_ADDR = 32'h14;  // ネスト呼び出しの内側の関数の先頭PC
    // 分岐のイミディエイトデータ(分岐命令自身のPCからの相対値)
    localparam integer LOOP_BACK   = 32'hfffffffd;  // 繰り返しの先頭へ戻る(3つ手前)
    localparam integer SKIP_ONE    = 32'h00000002;  // 次の1命令を飛ばす
    // レジスタ
    localparam addr_t REG_COUNT = 6'h00;  // 繰り返しの回数
    localparam addr_t REG_LIMIT = 6'h01;  // 繰り返しを終える回数
    localparam addr_t REG_BASE  = 6'h02;  // 数字を文字コードへ変換するための下駄
    localparam addr_t REG_STEP  = 6'h03;  // 繰り返しごとの増分
    localparam addr_t REG_CHAR  = 6'h04;  // 出力する文字
    // 文字コード
    localparam integer CHAR_ZERO = 32'h30;  // 文字「0」
    localparam integer CHAR_O    = 32'h4f;  // 文字「O」
    localparam integer CHAR_K    = 32'h4b;  // 文字「K」
    localparam integer CHAR_X    = 32'h58;  // 文字「X」

    // 制御ハザード動作確認プログラム
    // 後方分岐による繰り返し，連続した分岐，戻るだけの関数の呼び出し，ネストした呼び出しを
    // 通過し，正常なら「012OK」を出力する(分岐の判定を誤ると「X」が混ざるか出力が止まる)
    machine_t machines[0:ROM_SIZE - 1] = {
        // ===== 繰り返しの準備 =====
        mov(0, 0, REG_COUNT, {1'b1, 32'h00000000}),   // PC=0: 回数を0にする
        mov(0, 0, REG_LIMIT, {1'b1, 32'h00000003}),   // PC=1: 3回繰り返す設定にする
        mov(0, 0, REG_BASE,  {1'b1, CHAR_ZERO}),      // PC=2: 数字を文字にする下駄を用意する
        mov(0, 0, REG_STEP,  {1'b1, 32'h00000001}),   // PC=3: 増分を1にする

        // ===== 繰り返し本体(後方分岐) =====
        add(REG_COUNT, REG_BASE, REG_CHAR),           // PC=4: 回数を文字コードへ変換する
        print(REG_CHAR, 0),                           // PC=5: 「0」「1」「2」を順に出力する
        add(REG_COUNT, REG_STEP, REG_COUNT),          // PC=6: 回数を1つ進める
        lt(REG_COUNT, REG_LIMIT, {1'b1, LOOP_BACK}),  // PC=7: 3回に満たなければ繰り返しの先頭へ戻る

        // ===== 連続した分岐 =====
        ne(REG_COUNT, REG_LIMIT, {1'b1, SKIP_ONE}),   // PC=8: 3回に達しているため成立せず次へ進む
        eq(REG_COUNT, REG_LIMIT, {1'b1, SKIP_ONE}),   // PC=9: 3回に達しているため成立し次を飛ばす
        print(0, {1'b1, CHAR_X}),                     // PC=10: 飛ばされるはずの命令

        // ===== 関数呼び出し =====
        call(0, {1'b1, EMPTY_ADDR}),                  // PC=11: 戻るだけの関数を呼び出す
        print(0, {1'b1, CHAR_O}),                     // PC=12: 「O」を出力する
        call(0, {1'b1, OUTER_ADDR}),                  // PC=13: ネストした呼び出しを行う
        print(0, {1'b1, CHAR_K}),                     // PC=14: 「K」を出力する
        jmp(0, {1'b1, HALT_ADDR}),                    // PC=15: 停止処理へ移動する

        // ===== 停止 =====
        jmp(0, {1'b1, HALT_ADDR}),                    // PC=16: 無限ループで停止する

        // ===== 戻るだけの関数 =====
        ret(),                                        // PC=17: 呼び出し元へ戻る

        // ===== ネスト呼び出しの外側 =====
        call(0, {1'b1, INNER_ADDR}),                  // PC=18: 内側の関数を呼び出す
        ret(),                                        // PC=19: 呼び出し元へ戻る

        // ===== ネスト呼び出しの内側 =====
        ret()                                         // PC=20: 外側の関数へ戻る
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
