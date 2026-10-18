`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2024/07/06 13:34:58
// Design Name:
// Module Name: mother_board_sv
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


`include "ram.svh"
`include "rom.svh"

module mother_board_sv(
    input  logic clk,
    input  logic resetn,

    // 符号あり割り算回路用
    output logic [31:0] div_divisor_tdata,
    output logic        div_divisor_tvalid,
    output logic [31:0] div_dividend_tdata,
    output logic        div_dividend_tvalid,
    input  logic [63:0] div_dout_tdata,
    input  logic        div_dout_tvalid,

    // 符号なし割り算回路用
    output logic [31:0] divu_divisor_tdata,
    output logic        divu_divisor_tvalid,
    output logic [31:0] divu_dividend_tdata,
    output logic        divu_dividend_tvalid,
    input  logic [63:0] divu_dout_tdata,
    input  logic        divu_dout_tvalid,

    // デバッグ用
    input  logic [ 3:0] btn,
    input  logic [ 1:0] sw,
    output logic [ 3:0] led,
    output logic [ 5:0] rgb_led,

    // Pmod A・Pmod B
    output logic [7:0] ja,
    output logic [7:0] jb,

    // Arduino
    output logic [7:0] ar,
    output logic         a,
    output logic         ar_sda,
    output logic         ar_scl,
    output logic         ck_mosi,
    output logic         ck_sck,
    output logic         ck_ss,
    input  logic         ck_miso,

    // Ethernetモジュール(W5100S)
    input  logic         eth_intn,
    output logic         eth_rstn,
    output logic         eth_csn,
    output logic         eth_mosi,
    input  logic         eth_miso,
    output logic         eth_sck,

    // PSのUART0を読み書きするAXI4-Liteのマスタ(PSのS_AXI_GP0ポートへつなぐ)
    output logic [31:0] m_axi_araddr,
    output logic [ 2:0] m_axi_arprot,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [ 1:0] m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    output logic [31:0] m_axi_awaddr,
    output logic [ 2:0] m_axi_awprot,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [ 3:0] m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [ 1:0] m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    // ラズパイヘッダー
    output logic [26:8] gpio
    );

    // メインメモリ読み込み・書き込みインターフェース
    ram_read_if  ram_read();
    ram_write_if ram_write();

    // ROM読み込みインターフェース．1サイクルに2つの番地の命令を読むため2つ持つ
    rom_read_if rom_read1();
    rom_read_if rom_read2();

    // CPUの標準入出力(SCAN命令・PRINT命令)は外部から切り離し，入力は常に空，出力は常に受け取って捨てる状態に固定する
    // 入出力はEthernetモジュールを通したTCPの接続と，UARTの橋渡し回路で行うため，標準入出力を使う相手がいない
    // 固定せずに放っておくと，PRINT命令が受け取られるのを待ち続けてCPUが止まる
    logic [31:0] stdout_tdata;   // CPUが出力するデータ(捨てる)
    logic [ 3:0] stdout_tkeep;   // CPUが出力するデータの有効なバイト(捨てる)
    logic        stdout_tlast;   // CPUが出力するデータの末尾を示す信号(捨てる)
    logic        stdout_tvalid;  // CPUが出力するデータが有効かを示す信号(捨てる)
    logic        stdin_tready;   // CPUが入力を受け取れるかを示す信号(捨てる)

    // CPUとUARTの橋渡し回路の間の受け渡し
    logic       uart_tx_push;       // 送るバイトを送信バッファへ入れるか
    logic [7:0] uart_tx_data;       // 送るバイト
    logic       uart_tx_not_full;   // 送信バッファに空きがあるか
    logic       uart_rx_pop;        // 受信バッファの先頭のバイトを取り除くか
    logic [7:0] uart_rx_head;       // 受信バッファの先頭のバイト
    logic       uart_rx_not_empty;  // 受信バッファに受信したバイトがあるか

    // メインメモリ
    ram_sv ram_sv_0 (
        .clk(clk), .resetn(resetn),
        // メインメモリデータ読み込み
        .ram_read(ram_read),
        // メインメモリデータ書き込み
        .ram_write(ram_write)
    );

    // CPU
    cpu_sv cpu_sv_0 (
        .clk(clk), .resetn(resetn),
        // プログラムデータ読み込み
        .rom_read1(rom_read1),
        .rom_read2(rom_read2),
        // メモリデータ読み書き
        .ram_read(ram_read),
        .ram_write(ram_write),
        // 符号あり割り算回路用
        .div_divisor_tdata(div_divisor_tdata),
        .div_divisor_tvalid(div_divisor_tvalid),
        .div_dividend_tdata(div_dividend_tdata),
        .div_dividend_tvalid(div_dividend_tvalid),
        .div_dout_tdata(div_dout_tdata),
        .div_dout_tvalid(div_dout_tvalid),
        // 符号なし割り算回路用
        .divu_divisor_tdata(divu_divisor_tdata),
        .divu_divisor_tvalid(divu_divisor_tvalid),
        .divu_dividend_tdata(divu_dividend_tdata),
        .divu_dividend_tvalid(divu_dividend_tvalid),
        .divu_dout_tdata(divu_dout_tdata),
        .divu_dout_tvalid(divu_dout_tvalid),
        // IO
        .btn(btn),
        .sw(sw),
        .led(led),
        .rgb_led(rgb_led),
        // 標準入出力(入力は固定値，出力は捨てる信号へつなぐ)
        .stdin_tdata(32'h0),                // 入力のデータ(届かないため使われない)
        .stdin_tkeep(4'h0),                 // 入力のデータの有効なバイト(同上)
        .stdin_tlast(1'b0),                 // 入力のデータの末尾を示す信号(同上)
        .stdin_tready(stdin_tready),        // 捨てる
        .stdin_tvalid(1'b0),                // 入力は届かない
        .stdout_tdata(stdout_tdata),        // 捨てる
        .stdout_tkeep(stdout_tkeep),        // 捨てる
        .stdout_tlast(stdout_tlast),        // 捨てる
        .stdout_tready(1'b1),               // 出力は常に受け取る
        .stdout_tvalid(stdout_tvalid),      // 捨てる
        .ja(ja),
        .jb(jb),
        .ar(ar),
        .a(a),
        .ar_sda(ar_sda),
        .ar_scl(ar_scl),
        .ck_mosi(ck_mosi),
        .ck_sck(ck_sck),
        .ck_ss(ck_ss),
        .ck_miso(ck_miso),
        .eth_intn(eth_intn),
        .eth_rstn(eth_rstn),
        .eth_csn(eth_csn),
        .eth_mosi(eth_mosi),
        .eth_miso(eth_miso),
        .eth_sck(eth_sck),
        .uart_tx_push(uart_tx_push),
        .uart_tx_data(uart_tx_data),
        .uart_tx_not_full(uart_tx_not_full),
        .uart_rx_pop(uart_rx_pop),
        .uart_rx_head(uart_rx_head),
        .uart_rx_not_empty(uart_rx_not_empty),
        .gpio(gpio)
    );

    // UARTの橋渡し回路
    uart_bridge_sv uart_bridge_sv_0 (
        .clk(clk), .resetn(resetn),
        // CPUとの受け渡し
        .tx_push(uart_tx_push),
        .tx_data(uart_tx_data),
        .tx_not_full(uart_tx_not_full),
        .rx_pop(uart_rx_pop),
        .rx_head(uart_rx_head),
        .rx_not_empty(uart_rx_not_empty),
        // PSのUART0との読み書き
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    // プログラムメモリ
    rom_sv rom_sv_0 (
        .clk(clk),
        // プログラムデータ読み込み
        .rom_read1(rom_read1),
        .rom_read2(rom_read2)
    );

endmodule
