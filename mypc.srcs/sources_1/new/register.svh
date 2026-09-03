/**
 * レジスタに関する定義
 */

`ifndef REGISTER_SVH
`define REGISTER_SVH

`include "machine.svh"

// アドレスの定義
parameter machine_p::func_t SP_ADDR            = 6'h10;
parameter machine_p::func_t FLG_ADDR           = 6'h1c;
parameter machine_p::func_t RSI_ADDR           = 6'h1d;
parameter machine_p::func_t RAX_ADDR           = 6'h1e;
parameter machine_p::func_t PC_ADDR            = 6'h1f;
parameter machine_p::func_t BTN_ADDR           = 6'h20;
parameter machine_p::func_t SW_ADDR            = 6'h21;
parameter machine_p::func_t LED_ADDR           = 6'h22;
parameter machine_p::func_t RGB_LED_ADDR       = 6'h23;
parameter machine_p::func_t STDIN_DATA_ADDR    = 6'h31;
parameter machine_p::func_t STDIN_SIGNAL_ADDR  = 6'h32;
parameter machine_p::func_t STDOUT_DATA_ADDR   = 6'h33;
parameter machine_p::func_t STDOUT_SIGNAL_ADDR = 6'h34;

`endif
