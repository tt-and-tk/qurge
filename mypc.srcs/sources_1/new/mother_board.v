`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2024/07/06 13:34:58
// Design Name:
// Module Name: mother_board
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


module mother_board(
    input  wire clk,
    input  wire resetn,

    // 符号あり割り算回路用
    output wire [31:0] div_divisor_tdata,
    output wire        div_divisor_tvalid,
    output wire [31:0] div_dividend_tdata,
    output wire        div_dividend_tvalid,
    input  wire [63:0] div_dout_tdata,
    input  wire        div_dout_tvalid,

    // 符号なし割り算回路用
    output wire [31:0] divu_divisor_tdata,
    output wire        divu_divisor_tvalid,
    output wire [31:0] divu_dividend_tdata,
    output wire        divu_dividend_tvalid,
    input  wire [63:0] divu_dout_tdata,
    input  wire        divu_dout_tvalid,

    // デバッグ用
    input  wire [ 3:0] btn,
    input  wire [ 1:0] sw,
    output wire [ 3:0] led,
    output wire [ 5:0] rgb_led,

    // Pmod A・Pmod B
    output wire [7:0] ja,
    output wire [7:0] jb,

    // Arduino
    output wire [7:0] ar,
    output wire         a,
    output wire         ar_sda,
    output wire         ar_scl,
    output wire         ck_mosi,
    output wire         ck_sck,
    output wire         ck_ss,
    input  wire         ck_miso,

    // Ethernetモジュール(W5100S)
    input  wire         eth_intn,
    output wire         eth_rstn,
    output wire         eth_csn,
    output wire         eth_mosi,
    input  wire         eth_miso,
    output wire         eth_sck,

    // PSのUART0を読み書きするAXI4-Liteのマスタ(PSのS_AXI_GP0ポートへつなぐ)
    output wire [31:0] m_axi_araddr,
    output wire [ 2:0] m_axi_arprot,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    output wire [31:0] m_axi_awaddr,
    output wire [ 2:0] m_axi_awprot,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [ 3:0] m_axi_wstrb,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [ 1:0] m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    // ラズパイヘッダー
    output wire [26:8] gpio
    );

    mother_board_sv mother_board_sv_0 (
        .clk(clk), .resetn(resetn),

        .div_divisor_tdata(div_divisor_tdata),
        .div_divisor_tvalid(div_divisor_tvalid),
        .div_dividend_tdata(div_dividend_tdata),
        .div_dividend_tvalid(div_dividend_tvalid),
        .div_dout_tdata(div_dout_tdata),
        .div_dout_tvalid(div_dout_tvalid),

        .divu_divisor_tdata(divu_divisor_tdata),
        .divu_divisor_tvalid(divu_divisor_tvalid),
        .divu_dividend_tdata(divu_dividend_tdata),
        .divu_dividend_tvalid(divu_dividend_tvalid),
        .divu_dout_tdata(divu_dout_tdata),
        .divu_dout_tvalid(divu_dout_tvalid),

        .btn(btn),
        .sw(sw),
        .led(led),
        .rgb_led(rgb_led),

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
        .m_axi_bready(m_axi_bready),

        .gpio(gpio)
    );

endmodule
