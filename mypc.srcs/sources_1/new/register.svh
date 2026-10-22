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
parameter machine_p::func_t AR8_13_ADDR        = 6'h26;
parameter machine_p::func_t AR_MISC_ADDR       = 6'h27;
parameter machine_p::func_t AR0_7_ADDR         = 6'h28;
parameter machine_p::func_t SPI_ADDR           = 6'h2a;
parameter machine_p::func_t GPIO0_ADDR         = 6'h2d;
parameter machine_p::func_t GPIO1_ADDR         = 6'h2e;
parameter machine_p::func_t GPIO2_ADDR         = 6'h2f;
parameter machine_p::func_t GPIO3_ADDR         = 6'h30;
parameter machine_p::func_t UART_ADDR          = 6'h31;

// UARTのレジスタの各ビットの役割
// 書き込む値のビットは橋渡し回路(CPUとPSのUART0の間でバイトを受け渡すPL上の回路)への指示や通知を，読み出す値のビットは橋渡し回路の状態を表す
parameter int UART_TX_DATA_LSB  = 0;   // UARTで送信するデータ(1バイト)の最下位ビット(0〜7ビット目)
parameter int UART_TX_REQUEST   = 8;   // 送信の指示．このビットを立てると，送信するデータを送信バッファへ入れる
parameter int UART_RX_POP       = 9;   // 読み終えた通知．このビットを立てると，受信バッファの先頭のバイトを読み終えたことを伝え，そのバイトを受信バッファから取り除かせる
parameter int UART_RX_HEAD_LSB  = 16;  // 受信バッファの先頭のバイトの最下位ビット(16〜23ビット目)
parameter int UART_RX_NOT_EMPTY = 24;  // 受信バッファに受信したバイトがあるか(1:ある)
parameter int UART_TX_NOT_FULL  = 25;  // 送信バッファに空きがあるか(1:ある)

`endif
