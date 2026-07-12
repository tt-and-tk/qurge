/**
 * ROMに関する関数
 */

`ifndef ROM_SVH
`define ROM_SVH

`include "ram.svh"
`include "machine.svh"

package rom_p;
    typedef ram_p::address_bus_t pc_bus_t;  // プログラムカウンタ
endpackage

// インターフェース定義
interface rom_read_if;  // ROM読み込みインターフェース
    rom_p::pc_bus_t      pc;
    machine_p::machine_t machine;

    modport slave(
        input pc,
        output machine
    );

    modport master(
        output pc,
        input machine
    );
endinterface

`endif
