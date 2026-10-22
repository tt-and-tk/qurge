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


// CPUとPS(ARM側)のUART0の間でバイトを受け渡す回路(以下，橋渡し回路)
// USBのシリアル通信(UART)の信号を実際に送受信するのはUART0で，橋渡し回路は，CPUが送信するデータをUART0へ渡し，UART0が受信したバイトをCPUへ渡す
// PYNQ-Z2の電源用のUSBは，ボード上の変換チップを通してPSのUART0にだけつながっており，PLのピンからは使えないため，PSのUART0を借りる
//
// このファイルで使う用語
// - 送信FIFO・受信FIFO: UART0の中にあるバッファ(各64バイト)．UART0は，送信FIFOのバイトを順にシリアル通信で送り，受信したバイトを受信FIFOにためる
// - 送信バッファ・受信バッファ: 橋渡し回路の中にPLの回路として作ったバッファ(各2KB)．CPUが送信するデータを送信バッファにため，受信FIFOから取り出したバイトを受信バッファにためる
// - 状態のレジスタ・FIFOのレジスタ: UART0のレジスタのうち，送信FIFO・受信FIFOを読み書きするための2つ．UART0の外から送信FIFO・受信FIFOを扱う手段は，この2つだけである
//   - 状態のレジスタ: 読み出すと，送信FIFOが満杯か，受信FIFOが空かが分かる
//   - FIFOのレジスタ: 値をためるものではなく，送信FIFO・受信FIFOへの出入口である．1つの番地で，書き込むと送信FIFOの末尾にバイトが加わり，読み出すと受信FIFOの先頭のバイトが取り出される
//
// PSのUART0は，番地を指定して読み書きするレジスタとしてPLから見える．PLから読み書きするには，AXIの手順に従う
// AXIは，読み書きを求める側(マスタ)と応じる側(スレーブ)が，番地・データ・応答をそれぞれ別の信号の組(チャネル)でやり取りする取り決めである
// 各チャネルは，送り手が載せた内容が有効なことを示すvalidと，受け手が受け取れることを示すreadyを持ち，両方が1のサイクルに1回のやり取りが成り立つ
// 橋渡し回路は，その簡易版のAXI4-Liteのマスタとして，1回に1つの読み書きだけを行う
// - 読み出し: 読み出し番地のチャネル(AR)で番地を送り，読み出しデータのチャネル(R)でデータと応答を受け取る
// - 書き込み: 書き込み番地のチャネル(AW)で番地を，書き込みデータのチャネル(W)でデータを送り，書き込み応答のチャネル(B)で応答を受け取る
//
// UART0の通信速度などの設定は，起動時にFSBL(PSが最初に実行するプログラム)が済ませている
// 橋渡し回路は，状態のレジスタとFIFOのレジスタを次の手順を繰り返して読み書きし，送信FIFO・受信FIFOとバイトを受け渡す
// 1. 状態のレジスタを読み出し，送信FIFOが満杯か，受信FIFOが空かを知る
// 2. 受信FIFOにバイトがあり，受信バッファに空きがあれば，FIFOのレジスタを読み出して受信FIFOから1バイト取り出し，受信バッファへ入れる
//    受信FIFOは64バイトしかためられず，CPUがほかの処理で受信を確かめない間にあふれうるため，大きい受信バッファへ移しておく
// 3. 送信バッファにバイトがあり，送信FIFOに空きがあれば，送信バッファの先頭のバイトをFIFOのレジスタへ書き込み，送信FIFOへ加える
//    CPUが送信FIFOの空きを待たずに次の処理へ進めるよう，送信するデータは送信バッファへためておく
module uart_bridge_sv #(
    parameter int BUFFER_DEPTH = 2048  // 送信バッファ・受信バッファそれぞれにためられるバイト数(2のべき乗)
    ) (
    input  logic        clk,
    input  logic        resetn,

    // CPUとの受け渡し
    input  logic        tx_push,       // この信号が1のサイクルに，送信バッファに空きがあれば，送信するデータを入れる
    input  logic [7:0]  tx_data,       // 送信するデータ
    output logic        tx_not_full,   // 送信バッファに空きがあるか(1:ある)
    input  logic        rx_pop,        // この信号が1のサイクルに，受信バッファにバイトがあれば，先頭のバイトを取り除く
    output logic [7:0]  rx_head,       // 受信バッファの先頭のバイト(受信したバイトが無い間は不定)
    output logic        rx_not_empty,  // 受信バッファに受信したバイトがあるか(1:ある)

    // PSのUART0を読み書きするAXI4-Liteのマスタ
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
    output logic        m_axi_bready
    );

    // PSのUART0のレジスタの番地
    localparam logic [31:0] UART_STATUS_ADDR = 32'he000_002c;  // 状態のレジスタ(UART0の資料での名前はChannel_sts_reg0)
    localparam logic [31:0] UART_FIFO_ADDR   = 32'he000_0030;  // FIFOのレジスタ(UART0の資料での名前はTX_RX_FIFO0)

    // 状態のレジスタの各ビット
    localparam int UART_STATUS_RX_EMPTY = 1;  // 受信FIFOが空か(1:空)
    localparam int UART_STATUS_TX_FULL  = 4;  // 送信FIFOが満杯か(1:満杯)

    // 応答のうち，成功を表す値(OKAY)．ほかの値は失敗を表す
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    // リセットを解除してから，最初の読み書きを始めるまで待つサイクル数
    // 開発中は，動いているPLへVivadoから回路(ビットストリーム)を書き込み直すことがある．PLの回路は作り直されるが，PSのUART0は動き続ける
    // このため，書き込み直す前の回路が求めた読み書きの応答が，書き込み直した後の回路へ遅れて届くことがある
    // 遅れて届いた応答を，自分が求めた読み書きの応答と取り違えないよう，届きうる間は読み書きを求めず，届いた応答は受け取って捨てる
    localparam int START_WAIT_CYCLES = 1024;

    // 読み書きの段階
    typedef enum logic [2:0] {
        START_WAIT,       // 最初の読み書きを始める前に待っている(遅れて届いた応答は捨てる)
        STATUS_REQUEST,   // 状態のレジスタの読み出しを求めている
        STATUS_RESPONSE,  // 状態のレジスタの値が届くのを待っている
        RX_REQUEST,       // FIFOのレジスタの読み出し(受信FIFOの先頭のバイトの取り出し)を求めている
        RX_RESPONSE,      // 受信FIFOから取り出したバイトが届くのを待っている
        TX_REQUEST,       // FIFOのレジスタへの書き込み(送信FIFOへのバイトの追加)を求めている
        TX_RESPONSE       // 書き込みの応答が届くのを待っている
    } step_enum;

    step_enum step = START_WAIT;                            // 読み書きの段階
    logic [$clog2(START_WAIT_CYCLES)-1:0] start_wait_count = '0;  // 待ち始めてから数えたサイクル数(0〜待つサイクル数-1)
    logic tx_fifo_has_space = 1'b0;                         // 最後に読んだ状態で，送信FIFOに空きがあったか
    logic aw_sent = 1'b0;                                   // FIFOのレジスタへの書き込みの番地を，スレーブが受け取ったか
    logic w_sent = 1'b0;                                    // FIFOのレジスタへの書き込みのデータを，スレーブが受け取ったか

    // 送信バッファの先頭のバイトと，送信バッファが空でないか
    // 空の間は先頭のバイトが不定のため，空かどうかは空でないかの信号で判断し，その信号が1のときだけ先頭のバイトを使う
    logic [7:0] tx_head;       // 送信バッファの先頭のバイト(空の間は不定)
    logic       tx_not_empty;  // 送信バッファが空でないか(1:空でない)
    // 受信バッファに空きがあるか(1:ある)
    logic       rx_not_full;
    // 受信FIFOから取り出したバイトを，受信バッファへ入れるか(受信バッファへは橋渡し回路が入れ，CPUが取り出す)
    logic       rx_push;
    // 送信FIFOへ書き込み終えた送信バッファの先頭のバイトを，送信バッファから取り除くか
    logic       tx_pop;

    // CPUが送信するデータをためる送信バッファ
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

    // 受信FIFOから読み出したバイトを受信バッファへ入れるかを求める
    assign rx_push =
        // 受信FIFOから読み出したバイトを待っている
        (step == RX_RESPONSE)
        // かつ，応答が届いた
        && m_axi_rvalid
        // かつ，成功の応答である(失敗の応答で届いた値は受信したバイトではないため捨てる)
        && (m_axi_rresp == AXI_RESP_OKAY);
    // 送信バッファの先頭のバイトを取り除くかを求める
    assign tx_pop =
        // 送信FIFOへの書き込みの応答を待っている
        (step == TX_RESPONSE)
        // かつ，応答が届いた(失敗の応答でも取り除き，同じバイトを書き込み続けて送信が止まらないようにする)
        && m_axi_bvalid;

    // AXIの信号のうち，段階によらず決まるもの
    always_comb begin
        // 保護属性は，非特権・セキュア・データの読み書きとする(PSのUART0は，セキュアでない読み書きを受け付けない設定になりうるため)
        m_axi_arprot = 3'b000;
        m_axi_awprot = 3'b000;
        // 応答は，段階や，リセット中かどうかによらず常に受け取る(求めていない応答が届いても，捨てて読み書きを続けられるようにするため)
        m_axi_rready = 1'b1;
        m_axi_bready = 1'b1;
        // 書き込みは送信FIFOだけで，番地とデータは段階によらず同じものを載せる(有効かどうかはvalidで示す)
        m_axi_awaddr = UART_FIFO_ADDR;
        m_axi_wdata  = {24'b0, tx_head};
        // 書き込むのは最下位の1バイト
        m_axi_wstrb  = 4'b0001;
        // 読み出し番地は，段階に応じて状態のレジスタか受信FIFOを指す
        m_axi_araddr  = (step == RX_REQUEST) ? UART_FIFO_ADDR : UART_STATUS_ADDR;
        // 読み出し番地は，番地を送る段階の間だけ有効にする
        m_axi_arvalid = (step == STATUS_REQUEST) || (step == RX_REQUEST);
        // 書き込みの番地とデータは，書き込みを求めている段階のうち，スレーブがまだ受け取っていない間だけ有効にする
        m_axi_awvalid = (step == TX_REQUEST) && !aw_sent;
        m_axi_wvalid  = (step == TX_REQUEST) && !w_sent;
    end

    always_ff @(posedge clk) begin
        // リセット
        if (!resetn) begin
            // 最初の読み書きを始める前に待つ段階から始める
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
                        step <= STATUS_REQUEST;
                    end
                end

                // スレーブが読み出しの番地を受け取ったら，値が届くのを待つ
                STATUS_REQUEST: begin
                    if (m_axi_arready) begin
                        step <= STATUS_RESPONSE;
                    end
                end

                // 状態が届いたら，次のいずれかへ進む(失敗の応答で届いた値は状態ではないため，読み直す)
                // - 成功の応答で，受信FIFOから読み出せる: 受信FIFOの読み出し
                // - 成功の応答で，送信FIFOへ書き込める: 送信FIFOへの書き込み
                // - それ以外: 状態の読み直し
                STATUS_RESPONSE: begin
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
                            step <= RX_REQUEST;
                        end
                        else if (
                            // 成功の応答である
                            m_axi_rresp == AXI_RESP_OKAY
                            // かつ，送信FIFOに空きがある
                            && !m_axi_rdata[UART_STATUS_TX_FULL]
                            // かつ，送信バッファに送信するデータがある
                            && tx_not_empty
                        ) begin
                            // 送信FIFOへ1バイト書き込む
                            step <= TX_REQUEST;
                        end
                        else begin
                            // どちらもできなければ，状態を読み直す
                            step <= STATUS_REQUEST;
                        end
                    end
                end

                // スレーブが読み出しの番地を受け取ったら，バイトが届くのを待つ
                RX_REQUEST: begin
                    if (m_axi_arready) begin
                        step <= RX_RESPONSE;
                    end
                end

                // バイトが届いたら(受信バッファへは別の組み合わせ回路で入れる)，続けて送信FIFOへ書き込めるなら書き込み，書き込めなければ状態を読み直す
                RX_RESPONSE: begin
                    if (m_axi_rvalid) begin
                        // 次に進む段階を選ぶ
                        if (
                            // 最後に読んだ状態で，送信FIFOに空きがあった
                            tx_fifo_has_space
                            // かつ，送信バッファに送信するデータがある
                            && tx_not_empty
                        ) begin
                            // 送信FIFOへ1バイト書き込む
                            step <= TX_REQUEST;
                        end
                        else begin
                            // 書き込めなければ，状態を読み直す
                            step <= STATUS_REQUEST;
                        end
                    end
                end

                // スレーブが書き込みの番地とデータをどちらも受け取ったら，応答が届くのを待つ
                // スレーブは番地とデータを別々のサイクルに受け取ることがあるため，受け取るたびに控える
                TX_REQUEST: begin
                    if (
                        // スレーブが書き込みの番地を受け取り済みか，このサイクルに受け取る(readyが1)
                        (aw_sent || m_axi_awready)
                        // かつ，スレーブが書き込みのデータを受け取り済みか，このサイクルに受け取る(readyが1)
                        && (w_sent || m_axi_wready)
                    ) begin
                        // 次の書き込みに備えて控えを消し，応答を待つ
                        aw_sent <= 1'b0;
                        w_sent <= 1'b0;
                        step <= TX_RESPONSE;
                    end
                    else begin
                        // スレーブが受け取ったものを控える
                        aw_sent <= aw_sent || m_axi_awready;
                        w_sent <= w_sent || m_axi_wready;
                    end
                end

                // 応答が届いたら(送信バッファからは別の組み合わせ回路で取り除く)，状態を読み直す
                TX_RESPONSE: begin
                    if (m_axi_bvalid) begin
                        step <= STATUS_REQUEST;
                    end
                end

                default: begin
                    step <= START_WAIT;
                end
            endcase
        end
    end

endmodule
