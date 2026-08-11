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

    // 32bit値を指定ビット幅へ切り詰めても情報が失われないか(指定ビット幅を超える上位ビットが全て0か)を判定する
    function bool_t fits_in_width(
        logic [31:0] value,  // 判定対象の値
        int          width   // 切り詰め先のビット幅
    );
        fits_in_width = ((value >> width) == '0);
    endfunction
endpackage

`endif
