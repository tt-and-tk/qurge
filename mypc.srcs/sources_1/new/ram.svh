/**
 * メインメモリに関する関数
 */

`ifndef RAM_SVH
`define RAM_SVH

`include "machine.svh"

package ram_p;
    // 列挙体
    typedef enum logic [1:0] {   // メモリ読み出し・書き込み成否
        NONE,          // 初期状態
        SUCCESS        // 成功
    } code_enum;

    // 定数
    localparam int RAM_SIZE = 4096;          // メモリの実容量(バイト)

    // 変数型
    typedef logic [$clog2(RAM_SIZE)-1:0] address_bus_t;  // アドレスバス幅
    typedef logic [31:0] data_bus_t;         // データバス幅
endpackage

// インターフェース定義
interface ram_read_if;     // メモリ読み込みインターフェース
    ram_p::address_bus_t address;
    ram_p::data_bus_t    data;
    machine_p::mask_t    mask;
    logic                valid;
    logic                ready;
    logic                last;
    ram_p::code_enum     code;

    modport slave(
        input  address,
        output data,
        input  mask,
        input  valid,
        output ready,
        input  last,
        output code
    );

    modport master(
        output address,
        input  data,
        output mask,
        output valid,
        input  ready,
        output last,
        input  code
    );
endinterface
interface ram_write_if;     // メモリ書き込みインターフェース
    ram_p::address_bus_t address;
    ram_p::data_bus_t    data;
    machine_p::mask_t    mask;
    logic                valid;
    logic                ready;
    logic                last;
    ram_p::code_enum     code;

    modport slave(
        input  address,
        input  data,
        input  mask,
        input  valid,
        output ready,
        input last,
        output code
    );

    modport master(
        output address,
        output data,
        output mask,
        output valid,
        input  ready,
        output last,
        input  code
    );
endinterface

`endif
