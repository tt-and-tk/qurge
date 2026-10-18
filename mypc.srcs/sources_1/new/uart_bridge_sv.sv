`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/10/18 12:00:00
// Design Name:
// Module Name: uart_bridge_sv
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


// PS(ARM側)のUART0を使って，CPUが送受信するバイトをUSBのシリアル通信(UART)でやり取りする回路(以下，橋渡し回路)
// PYNQ-Z2の電源用のUSBは，ボード上の変換チップを通してPSのUART0にだけつながっており，PLのピンからは使えないため，PSのUART0を借りる
//
// PSのUART0は，番地を指定して読み書きするレジスタとしてPLから見える．PLから読み書きするには，AXIの手順に従う
// AXIは，読み書きを求める側(マスタ)と応じる側(スレーブ)が，番地・データ・応答をそれぞれ別の信号の組(チャネル)でやり取りする取り決めである
// 各チャネルは，送り手が載せた内容が有効なことを示すvalidと，受け手が受け取れることを示すreadyを持ち，両方が1のサイクルに1回のやり取りが成り立つ
// 橋渡し回路は，その簡易版のAXI4-Liteのマスタとして，1回に1つの読み書きだけを行う
// - 読み出し: 読み出し番地のチャネル(AR)で番地を送り，読み出しデータのチャネル(R)でデータと応答を受け取る
// - 書き込み: 書き込み番地のチャネル(AW)で番地を，書き込みデータのチャネル(W)でデータを送り，書き込み応答のチャネル(B)で応答を受け取る
//
// PSのUART0は，送信するバイトをためる送信FIFOと，受信したバイトをためる受信FIFOを持ち，シリアル通信への変換はUART0が行う
// UART0の通信速度などの設定は，起動時にFSBL(PSが最初に実行するプログラム)が済ませている
// 橋渡し回路は，UART0の状態を読み続け，次の2つを繰り返す
// - 受信FIFOにバイトがあれば1バイト読み出し，PL側の受信バッファへ入れる
//   受信FIFOは64バイトしかためられず，CPUがほかの処理で受信を確かめない間にあふれうるため，大きい受信バッファへ移しておく
// - PL側の送信バッファにバイトがあり，送信FIFOに空きがあれば，送信FIFOへ1バイト書き込む
//   CPUが送信FIFOの空きを待たずに次の処理へ進めるよう，送るバイトは送信バッファへためておく
module uart_bridge_sv #(
    parameter int BUFFER_DEPTH = 2048  // 送信バッファ・受信バッファそれぞれにためられるバイト数(2のべき乗)
    ) (
    input  logic        clk,
    input  logic        resetn,

    // CPUとの受け渡し
    input  logic        tx_push,       // 1のサイクルに，送るバイトを送信バッファへ入れる(満杯なら入れない)
    input  logic [7:0]  tx_data,       // 送るバイト
    output logic        tx_not_full,   // 送信バッファに空きがあるか(1:ある)
    input  logic        rx_pop,        // 1のサイクルに，受信バッファの先頭のバイトを取り除く
    output logic [7:0]  rx_head,       // 受信バッファの先頭のバイト
    output logic        rx_not_empty,  // 受信バッファに受信したバイトがあるか(1:ある)

    // PSのUART0を読み書きするAXI4-Liteのマスタ
    output logic [31:0] m_axi_araddr,   // 読み出し番地
    output logic [ 2:0] m_axi_arprot,   // 読み出しの保護属性
    output logic        m_axi_arvalid,  // 読み出し番地が有効か
    input  logic        m_axi_arready,  // スレーブが読み出し番地を受け取れるか
    input  logic [31:0] m_axi_rdata,    // 読み出したデータ
    input  logic [ 1:0] m_axi_rresp,    // 読み出しの応答
    input  logic        m_axi_rvalid,   // 読み出したデータが有効か
    output logic        m_axi_rready,   // 読み出したデータを受け取れるか
    output logic [31:0] m_axi_awaddr,   // 書き込み番地
    output logic [ 2:0] m_axi_awprot,   // 書き込みの保護属性
    output logic        m_axi_awvalid,  // 書き込み番地が有効か
    input  logic        m_axi_awready,  // スレーブが書き込み番地を受け取れるか
    output logic [31:0] m_axi_wdata,    // 書き込むデータ
    output logic [ 3:0] m_axi_wstrb,    // 書き込むデータのうち有効なバイト
    output logic        m_axi_wvalid,   // 書き込むデータが有効か
    input  logic        m_axi_wready,   // スレーブが書き込むデータを受け取れるか
    input  logic [ 1:0] m_axi_bresp,    // 書き込みの応答
    input  logic        m_axi_bvalid,   // 書き込みの応答が有効か
    output logic        m_axi_bready    // 書き込みの応答を受け取れるか
    );

    // PSのUART0のレジスタの番地
    localparam logic [31:0] UART_STATUS_ADDR = 32'he000_002c;  // 状態(Channel_sts_reg0)
    localparam logic [31:0] UART_FIFO_ADDR   = 32'he000_0030;  // 送信FIFOへの書き込みと受信FIFOからの読み出し(TX_RX_FIFO0)

    // 状態のレジスタの各ビット
    localparam int UART_STATUS_RX_EMPTY = 1;  // 受信FIFOが空か(1:空)
    localparam int UART_STATUS_TX_FULL  = 4;  // 送信FIFOが満杯か(1:満杯)

    // 応答のうち，成功を表す値(OKAY)．ほかの値は失敗を表す
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    // リセットを解除してから，最初の読み書きを始めるまで待つサイクル数
    // 動いている間にビットストリームを書き換えると，書き換える前の回路が求めた読み書きの応答が，書き換えた後に届くことがある
    // その応答を最初に求めた読み書きの応答と取り違えないよう，届きうる間は読み書きを求めずに応答を受け取って捨てる
    localparam int START_WAIT_CYCLES = 1024;

    // 読み書きの段階
    typedef enum logic [2:0] {
        START_WAIT,   // リセットの解除後，届きうる応答を捨てながら待っている
        STATUS_ADDR,  // 状態のレジスタの読み出し番地を送っている
        STATUS_DATA,  // 状態のレジスタの値を待っている
        RX_ADDR,      // 受信FIFOの読み出し番地を送っている
        RX_DATA,      // 受信FIFOから読み出したバイトを待っている
        TX_REQUEST,   // 送信FIFOへの書き込み番地とデータを送っている
        TX_RESPONSE   // 送信FIFOへの書き込みの応答を待っている
    } step_enum;

    step_enum step = START_WAIT;                            // 読み書きの段階
    logic [$clog2(START_WAIT_CYCLES):0] start_wait_count = '0;  // 待ち始めてから数えたサイクル数
    logic tx_fifo_has_space = 1'b0;                         // 最後に読んだ状態で，送信FIFOに空きがあったか
    logic aw_sent = 1'b0;                                   // 送信FIFOへの書き込み番地を送り終えたか
    logic w_sent = 1'b0;                                    // 送信FIFOへの書き込みデータを送り終えたか

    // 送信バッファの先頭のバイトと，先頭のバイトがあるか
    logic [7:0] tx_head;
    logic       tx_not_empty;
    // 受信バッファに空きがあるか(1:ある)
    logic       rx_not_full;
    // 受信バッファにバイトを入れるか(受信FIFOから読み出したバイトが成功の応答とともに届いたサイクル)
    logic       rx_push;
    // 送信バッファの先頭のバイトを取り除くか(送信FIFOへの書き込みの応答が届いたサイクル)
    logic       tx_pop;

    // CPUが送るバイトをためる送信バッファ
    uart_buffer_sv #(.DEPTH(BUFFER_DEPTH)) tx_buffer (
        .clk(clk), .resetn(resetn),
        .push(tx_push),
        .push_data(tx_data),
        .not_full(tx_not_full),
        .pop(tx_pop),
        .head(tx_head),
        .not_empty(tx_not_empty)
    );

    // 受信したバイトをCPUが取り出すまでためる受信バッファ
    uart_buffer_sv #(.DEPTH(BUFFER_DEPTH)) rx_buffer (
        .clk(clk), .resetn(resetn),
        .push(rx_push),
        .push_data(m_axi_rdata[7:0]),
        .not_full(rx_not_full),
        .pop(rx_pop),
        .head(rx_head),
        .not_empty(rx_not_empty)
    );

    // 受信FIFOのバイトが成功の応答とともに届いたら，受信バッファへ入れる(失敗の応答で届いた値は受信したバイトではないため捨てる)
    assign rx_push = (step == RX_DATA) && m_axi_rvalid && (m_axi_rresp == AXI_RESP_OKAY);
    // 送信FIFOへの書き込みの応答が届いたら，送信バッファから取り除く
    // 失敗の応答でも取り除くのは，同じバイトを書き込み続けて送信が止まらないようにするため
    assign tx_pop = (step == TX_RESPONSE) && m_axi_bvalid;

    // AXIの信号のうち，段階によらず決まるもの
    always_comb begin
        // 保護属性は，非特権・セキュア・データの読み書きとする(PSのUART0は，セキュアでない読み書きを受け付けない設定になりうるため)
        m_axi_arprot = 3'b000;
        m_axi_awprot = 3'b000;
        // 応答は，段階やリセット中によらず常に受け取る(求めていない応答が届いても，捨てて読み書きを続けられるようにするため)
        m_axi_rready = 1'b1;
        m_axi_bready = 1'b1;
        // 書き込みは送信FIFOだけで，番地とデータは段階によらず同じものを載せる(有効かどうかはvalidで示す)
        m_axi_awaddr = UART_FIFO_ADDR;
        m_axi_wdata  = {24'b0, tx_head};
        // 書き込むのは最下位の1バイト
        m_axi_wstrb  = 4'b0001;
        // 読み出し番地は，段階に応じて状態のレジスタか受信FIFOを指す
        m_axi_araddr  = (step == RX_ADDR) ? UART_FIFO_ADDR : UART_STATUS_ADDR;
        // 読み出し番地は，番地を送る段階の間だけ有効にする
        m_axi_arvalid = (step == STATUS_ADDR) || (step == RX_ADDR);
        // 書き込み番地とデータは，送る段階のうち，まだ受け取られていない間だけ有効にする
        m_axi_awvalid = (step == TX_REQUEST) && !aw_sent;
        m_axi_wvalid  = (step == TX_REQUEST) && !w_sent;
    end

    always_ff @(posedge clk) begin
        // リセット
        if (!resetn) begin
            // 届きうる応答を捨てながら待つところから始める
            step <= START_WAIT;
            start_wait_count <= '0;
            tx_fifo_has_space <= 1'b0;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
        end
        else begin
            unique case (step)
                // 待つサイクル数に達したら，状態の読み出しを始める
                START_WAIT: begin
                    start_wait_count <= start_wait_count + 1'b1;
                    if (start_wait_count == START_WAIT_CYCLES - 1) begin
                        step <= STATUS_ADDR;
                    end
                end
                // 読み出し番地が受け取られたら，値を待つ
                STATUS_ADDR: begin
                    if (m_axi_arready) begin
                        step <= STATUS_DATA;
                    end
                end
                // 状態が届いたら，受信FIFOの読み出しと送信FIFOへの書き込みのうち，できるものへ進む
                // 失敗の応答で届いた値は状態ではないため，受信FIFOが空で送信FIFOが満杯とみなし，状態を読み直す
                STATUS_DATA: begin
                    if (m_axi_rvalid) begin
                        // 送信FIFOに空きがあるかを，受信FIFOを読み出した後の判断に使うため控える
                        tx_fifo_has_space <= (m_axi_rresp == AXI_RESP_OKAY) && !m_axi_rdata[UART_STATUS_TX_FULL];
                        // 次に進む段階を選ぶ
                        if (
                            // 成功の応答である
                            m_axi_rresp == AXI_RESP_OKAY
                            // かつ，受信FIFOにバイトがある
                            && !m_axi_rdata[UART_STATUS_RX_EMPTY]
                            // かつ，受信バッファに空きがある(空きがなければ，受信FIFOに残しておく)
                            && rx_not_full
                        ) begin
                            // 受信FIFOから1バイト読み出す
                            step <= RX_ADDR;
                        end
                        else if (
                            // 成功の応答である
                            m_axi_rresp == AXI_RESP_OKAY
                            // かつ，送信FIFOに空きがある
                            && !m_axi_rdata[UART_STATUS_TX_FULL]
                            // かつ，送信バッファに送るバイトがある
                            && tx_not_empty
                        ) begin
                            // 送信FIFOへ1バイト書き込む
                            step <= TX_REQUEST;
                        end
                        else begin
                            // どちらもできなければ，状態を読み直す
                            step <= STATUS_ADDR;
                        end
                    end
                end
                // 読み出し番地が受け取られたら，バイトを待つ
                RX_ADDR: begin
                    if (m_axi_arready) begin
                        step <= RX_DATA;
                    end
                end
                // バイトが届いたら(受信バッファへは別の組み合わせ回路で入れる)，続けて送信FIFOへ書き込めるなら書き込み，書き込めなければ状態を読み直す
                RX_DATA: begin
                    if (m_axi_rvalid) begin
                        if (tx_fifo_has_space && tx_not_empty) begin
                            step <= TX_REQUEST;
                        end
                        else begin
                            step <= STATUS_ADDR;
                        end
                    end
                end
                // 書き込み番地とデータがどちらも受け取られたら，応答を待つ
                // 番地とデータは，スレーブが別々のサイクルに受け取ることがあるため，受け取られたものから控える
                TX_REQUEST: begin
                    if (
                        // 書き込み番地を受け取り済みか，このサイクルに受け取られる
                        (aw_sent || m_axi_awready)
                        // かつ，書き込みデータを受け取り済みか，このサイクルに受け取られる
                        && (w_sent || m_axi_wready)
                    ) begin
                        // 次の書き込みに備えて控えを消し，応答を待つ
                        aw_sent <= 1'b0;
                        w_sent <= 1'b0;
                        step <= TX_RESPONSE;
                    end
                    else begin
                        // 受け取られたものを控える
                        aw_sent <= aw_sent || m_axi_awready;
                        w_sent <= w_sent || m_axi_wready;
                    end
                end
                // 応答が届いたら(送信バッファからは別の組み合わせ回路で取り除く)，状態を読み直す
                TX_RESPONSE: begin
                    if (m_axi_bvalid) begin
                        step <= STATUS_ADDR;
                    end
                end
                default: begin
                    step <= START_WAIT;
                end
            endcase
        end
    end

endmodule
