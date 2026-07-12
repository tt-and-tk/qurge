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

    localparam integer ROM_SIZE = 10;

    // ===== 定数 =====
    // プログラムアドレス
    localparam integer FUNC1_ADDR = 32'h04;  // func1の先頭PC
    localparam integer FUNC2_ADDR = 32'h08;  // func2の先頭PC
    localparam integer HALT_ADDR  = 32'h03;  // 停止用の無限ループのPC
    // 文字コード
    localparam integer CHAR_A = 32'h41;  // 文字「A」
    localparam integer CHAR_B = 32'h42;  // 文字「B」
    localparam integer CHAR_C = 32'h43;  // 文字「C」
    localparam integer CHAR_D = 32'h44;  // 文字「D」
    localparam integer CHAR_E = 32'h45;  // 文字「E」

    // CALL/RET動作確認プログラム
    // 2階層のネスト呼び出しを行い，正常なら「ABCDE」を出力する
    machine_t machines[0:ROM_SIZE - 1] = {
        // ===== main =====
        print(0, {1'b1, CHAR_A}),            // PC=0: 「A」を出力
        call(0, {1'b1, FUNC1_ADDR}),         // PC=1: func1を呼び出す
        print(0, {1'b1, CHAR_E}),            // PC=2: func1から戻ったら「E」を出力
        jmp(0, {1'b1, HALT_ADDR}),           // PC=3: 無限ループで停止する

        // ===== func1 =====
        print(0, {1'b1, CHAR_B}),            // PC=4: 「B」を出力
        call(0, {1'b1, FUNC2_ADDR}),         // PC=5: func2を呼び出す
        print(0, {1'b1, CHAR_D}),            // PC=6: func2から戻ったら「D」を出力
        ret(),                               // PC=7: mainへ戻る

        // ===== func2 =====
        print(0, {1'b1, CHAR_C}),            // PC=8: 「C」を出力
        ret()                                // PC=9: func1へ戻る
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
