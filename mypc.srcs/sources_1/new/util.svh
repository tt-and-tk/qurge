/**
 * 特に分類できない共通系
 */

`ifndef UTIL_SVH
`define UTIL_SVH

package util_p;
    typedef logic bool_t;

    parameter bool_t TRUE  = 1'b1;
    parameter bool_t FALSE = 1'b0;

    // メモリ読み出し・書き込みや標準入出力など各処理の実行状態
    typedef enum logic [1:0] {
        IDLE,          // 待機状態
        EXECUTE,       // 実行
        RESPONSE       // レスポンスを返す
    } state_enum;
endpackage

`endif
