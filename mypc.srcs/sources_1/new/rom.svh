/**
 * ROMに関する関数
 */

`ifndef ROM_SVH
`define ROM_SVH

`include "ram.svh"
`include "machine.svh"

package rom_p;
    localparam int MAX_LINE_NUM = 16384;       // アセンブラが許容する最大命令数(アセンブラ(pyntaxis)がROMに置ける命令数の上限と一致させる)
    typedef logic [$clog2(MAX_LINE_NUM)-1:0] pc_bus_t;  // プログラムカウンタ

    // プログラムカウンタのうち，ROMの命令数の上限の直後からをメインメモリの後半に対応させる．
    // 1命令は8バイトを占めるため，メモリの後半の先頭からの命令の順番に8を掛けた番地に置かれる
    localparam int CODE_AREA_PC_BASE = MAX_LINE_NUM;                                     // メモリの後半の先頭の命令に対応するプログラムカウンタ
    localparam int CODE_AREA_PC_NUM = (ram_p::RAM_SIZE - ram_p::CODE_AREA_BASE) / 8;     // メモリの後半に置ける命令数
endpackage

// インターフェース定義
interface rom_read_if;  // ROM読み込みインターフェース
    rom_p::pc_bus_t      pc;
    machine_p::machine_t machine;
    logic                valid;  // pcがROMの命令数に収まっているか

    modport slave(
        input pc,
        output machine,
        output valid
    );

    modport master(
        output pc,
        input machine,
        input valid
    );
endinterface

`endif
