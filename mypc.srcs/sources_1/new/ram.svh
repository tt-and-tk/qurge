/**
 * メインメモリに関する関数
 */

`ifndef RAM_SVH
`define RAM_SVH

`include "machine.svh"

package ram_p;
    // 定数
    localparam int RAM_SIZE = 65536;         // メモリの実容量(バイト)．範囲外番地をアドレスバス幅で判定するため2のべき乗とする
    localparam int KERNEL_STACK_END = RAM_SIZE / 2;  // カーネルモードのスタックを置くメモリの前半の大きさ(前半の末尾の直後の番地)．2のべき乗とする

    // 変数型
    typedef logic [$clog2(RAM_SIZE)-1:0] address_bus_t;  // アドレスバス幅
    typedef logic [31:0] data_bus_t;                     // データバス幅
endpackage

// インターフェース定義
interface ram_read_if;     // メモリ読み込みインターフェース
    ram_p::address_bus_t address;
    ram_p::data_bus_t    data;
    machine_p::mask_t    mask;
    logic                valid;
    logic                ready;
    logic                last;

    modport slave(
        input  address,
        output data,
        input  mask,
        input  valid,
        output ready,
        input  last
    );

    modport master(
        output address,
        input  data,
        output mask,
        output valid,
        input  ready,
        output last
    );
endinterface
interface ram_write_if;     // メモリ書き込みインターフェース
    ram_p::address_bus_t address;
    ram_p::data_bus_t    data;
    machine_p::mask_t    mask;
    logic                valid;
    logic                ready;
    logic                last;

    modport slave(
        input  address,
        input  data,
        input  mask,
        input  valid,
        output ready,
        input last
    );

    modport master(
        output address,
        output data,
        output mask,
        output valid,
        input  ready,
        output last
    );
endinterface

`endif
