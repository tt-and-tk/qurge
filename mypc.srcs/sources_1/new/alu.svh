/**
 * aluに関する関数など
 */

`ifndef ALU_SVH
`define ALU_SVH

`include "util.svh"
`include "decorder.svh"

package alu_p;
    import machine_p::*;

    // 列挙体
    typedef enum type_t {   // 機械語の命令タイプ
        N_TYPE,   // 処理を実行しない
        P_TYPE,   // 演算系
        S_TYPE,   // シフト系
        A_TYPE,   // 代入系
        F_TYPE,   // 分岐系
        J_TYPE,   // ジャンプ系
        M_TYPE,   // メモリ系
        IO_TYPE   // 標準入出力系
    } type_enum;
    typedef enum logic[1:0] {    // CPUの実行フェーズ(フェッチや実行などを別のクロックに分ける)
        CPU_FETCH,    // 命令フェッチ
        CPU_CHECK,    // 命令を実行可能かどうかチェックする
        CPU_EXECUTE   // 命令実行
    } cpu_phase_enum;

    // 変数型
    typedef logic [31:0] register_t;   // レジスタサイズ

    // 関数
    function util_p::bool_t is_readable(   // そのアドレスのレジスタが読み込み可能か
        machine_p::addr_t addr
    );
        // CPU内のレジスタ
        if (6'h00 <= addr && addr <= 6'h0f)
            is_readable = util_p::TRUE;
        // スタックポインタ
        else if (addr == 6'h10)
            is_readable = util_p::FALSE;
        // 呼び出し関数の戻り先
        else if (6'h11 <= addr && addr <= 6'h1a)
            is_readable = util_p::FALSE;
        // フラグ
        else if (addr == 6'h1c)
            is_readable = util_p::TRUE;
        // 引数が格納されているレジスタの一つ目の番地
        else if (addr == 6'h1d)
            is_readable = util_p::TRUE;
        // 演算結果
        else if (addr == 6'h1e)
            is_readable = util_p::TRUE;
        // プログラムカウンタ
        else if (addr == 6'h1f)
            is_readable = util_p::TRUE;
        // タクトスイッチ
        else if (addr == 6'h20)
            is_readable = util_p::TRUE;
        // DIPスイッチ
        else if (addr == 6'h21)
            is_readable = util_p::TRUE;
        // LED
        else if (addr == 6'h22)
            is_readable = util_p::FALSE;
        // RGB LED
        else if (addr == 6'h23)
            is_readable = util_p::FALSE;
        // Pmod A
        else if (addr == 6'h24)
            is_readable = util_p::TRUE;
        // Pmod B
        else if (addr == 6'h25)
            is_readable = util_p::TRUE;
        // AR
        else if (addr == 6'h26 || addr == 6'h28)
            is_readable = util_p::TRUE;
        // I2C
        else if (addr == 6'h27)
            is_readable = util_p::TRUE;
        // AR_RST
        else if (addr == 6'h29)
            is_readable = util_p::TRUE;
        // SPI
        else if (addr == 6'h2a)
            is_readable = util_p::TRUE;
        // アナログピン
        else if (addr == 6'h2b)
            is_readable = util_p::FALSE;    // オミット
        // XADC
        else if (addr == 6'h2c)
            is_readable = util_p::FALSE;    // オミット
        // GPIO
        else if (6'h2d <= addr && addr <= 6'h30)
            is_readable = util_p::TRUE;
        // 標準入力(データ)
        else if (addr == 6'h31)
            is_readable = util_p::TRUE;
        // 標準入力(信号)
        else if (addr == 6'h32)
            is_readable = util_p::TRUE;  // レジスタ自体の読み込みは一律許可することにする
        // 標準出力(データ)
        else if (addr == 6'h33)
            is_readable = util_p::FALSE;
        // 標準出力(信号)
        else if (addr == 6'h34)
            is_readable = util_p::TRUE;  // レジスタ自体の読み込みは一律許可することにする
        // 定義されていない
        else
            is_readable = util_p::FALSE;
    endfunction
    function util_p::bool_t is_writable(  // そのアドレスのレジスタが書き込み可能か
        machine_p::addr_t addr
    );
        // CPU内のレジスタ
        if (6'h00 <= addr && addr <= 6'h0f)
            is_writable = util_p::TRUE;
        // スタックポインタ
        else if (addr == 6'h10)
            is_writable = util_p::FALSE;
        // 呼び出し関数の戻り先
        else if (6'h11 <= addr && addr <= 6'h1a)
            is_writable = util_p::FALSE;
        // フラグ
        else if (addr == 6'h1c)
            is_writable = util_p::FALSE;
        // 引数が格納されているレジスタの一つ目の番地
        else if (addr == 6'h1d)
            is_writable = util_p::FALSE;
        // 演算結果
        else if (addr == 6'h1e)
            is_writable = util_p::FALSE;
        // プログラムカウンタ
        else if (addr == 6'h1f)
            is_writable = util_p::FALSE;
        // タクトスイッチ
        else if (addr == 6'h20)
            is_writable = util_p::FALSE;
        // DIPスイッチ
        else if (addr == 6'h21)
            is_writable = util_p::FALSE;
        // LED
        else if (addr == 6'h22)
            is_writable = util_p::TRUE;
        // RGB LED
        else if (addr == 6'h23)
            is_writable = util_p::TRUE;
        // Pmod A
        else if (addr == 6'h24)
            is_writable = util_p::TRUE;
        // Pmod B
        else if (addr == 6'h25)
            is_writable = util_p::TRUE;
        // AR
        else if (addr == 6'h26 || addr == 6'h28)
            is_writable = util_p::TRUE;
        // I2C
        else if (addr == 6'h27)
            is_writable = util_p::TRUE;
        // AR_RST
        else if (addr == 6'h29)
            is_writable = util_p::FALSE;
        // SPI
        else if (addr == 6'h2a)
            is_writable = util_p::TRUE;
        // アナログピン
        else if (addr == 6'h2b)
            is_writable = util_p::FALSE;    // オミット
        // XADC
        else if (addr == 6'h2c)
            is_writable = util_p::FALSE;    // オミット
        // GPIO
        else if (6'h2d <= addr && addr <= 6'h30)
            is_writable = util_p::TRUE;
        // 標準入力(データ)
        else if (addr == 6'h31)
            is_writable = util_p::FALSE;
        // 標準入力(信号)
        else if (addr == 6'h32)
            is_writable = util_p::TRUE;  // レジスタ自体の書き込みは一律許可することにする
        // 標準出力(データ)
        else if (addr == 6'h33)
            is_writable = util_p::TRUE;
        // 標準出力(信号)
        else if (addr == 6'h34)
            is_writable = util_p::TRUE;  // レジスタ自体の書き込みは一律許可することにする
        // 定義されていない
        else
            is_writable = util_p::FALSE;
    endfunction
endpackage

// インターフェース定義

`endif
