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
parameter machine_p::func_t PMOD_A_ADDR        = 6'h24;
parameter machine_p::func_t PMOD_B_ADDR        = 6'h25;
parameter machine_p::func_t AR_HIGH_ADDR       = 6'h26;  // AR8〜AR13
parameter machine_p::func_t AR_MISC_ADDR       = 6'h27;  // A・AR_SDA・AR_SCL
parameter machine_p::func_t AR_LOW_ADDR        = 6'h28;  // AR0〜AR7
parameter machine_p::func_t SPI_ADDR           = 6'h2a;  // AR_MISO・AR_SCK・AR_MOSI・AR_SS
parameter machine_p::func_t GPIO0_ADDR         = 6'h2d;  // GPIO0〜GPIO7
parameter machine_p::func_t GPIO1_ADDR         = 6'h2e;  // GPIO8〜GPIO15
parameter machine_p::func_t GPIO2_ADDR         = 6'h2f;  // GPIO16〜GPIO23
parameter machine_p::func_t GPIO3_ADDR         = 6'h30;  // GPIO24〜GPIO27
parameter machine_p::func_t STDIN_DATA_ADDR    = 6'h31;
parameter machine_p::func_t STDIN_SIGNAL_ADDR  = 6'h32;
parameter machine_p::func_t STDOUT_DATA_ADDR   = 6'h33;
parameter machine_p::func_t STDOUT_SIGNAL_ADDR = 6'h34;

`endif
