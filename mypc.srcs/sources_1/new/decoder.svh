/**
 * デコーダーに関する関数
 */

`ifndef DECODER_SV
`define DECODER_SV

`include "machine.svh"

package decoder_p;
endpackage

// インターフェース定義
interface command_if;  // 機械語から各値を取得してくるインターフェース
    machine_p::machine_t machine;
    machine_p::type_t    m_type;
    machine_p::func_t    func;
    machine_p::mask_t    mask;
    machine_p::addr_t    rs1;
    machine_p::addr_t    rs2;
    machine_p::addr_t    rd;
    machine_p::imm_t     imm;

    modport slave(
        input machine,
        output m_type,
        output func,
        output mask,
        output rs1,
        output rs2,
        output rd,
        output imm
    );

    modport master(
        output machine,
        input m_type,
        input func,
        input mask,
        input rs1,
        input rs2,
        input rd,
        input imm
    );
endinterface

`endif
