`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// UARTの橋渡し回路(uart_bridge_sv)を検証するテストベンチ．
// 橋渡し回路は実物を使い，PSのUART0をテストベンチ用のAXI4-Liteのスレーブのモデルに差し替える．
// テストケースごとに，モデルが受信したバイトの列や送信FIFOの空きを設定し，CPU側から送るバイトを入れて，
// 橋渡し回路の受信バッファから取り出せたバイトと，モデルの送信FIFOへ書き込まれたバイトを期待値と比較する．
// 最後に合否の件数を表示し，失敗があれば$fatalで終了する．
//
// このファイルで使う用語
// - モデル: PSのUART0を模したAXI4-Liteのスレーブ．状態のレジスタと，送信FIFO・受信FIFOの番地を持つ
// - 失敗の応答: 読み書きの応答のうち，成功(OKAY)以外の値(ここではSLVERRを使う)
//////////////////////////////////////////////////////////////////////////////////


module uart_bridge_tb;

    localparam int BUFFER_DEPTH = 4;                   // 送信バッファ・受信バッファの大きさ(満杯の場合を少ないバイト数で確かめるため小さくする)
    localparam int START_WAIT_CYCLES = 1024;           // 橋渡し回路がリセットの解除後に読み書きを始めるまで待つサイクル数
    localparam int MAX_CYCLES = 5000;                  // 1つの待ち合わせを打ち切るサイクル数
    localparam logic [31:0] UART_STATUS_ADDR = 32'he000_002c;  // 状態のレジスタの番地
    localparam logic [31:0] UART_FIFO_ADDR   = 32'he000_0030;  // 送信FIFO・受信FIFOの番地
    localparam logic [1:0]  RESP_OKAY   = 2'b00;      // 成功の応答
    localparam logic [1:0]  RESP_SLVERR = 2'b10;      // 失敗の応答

    // ===== 試験対象 =====

    logic clk = 1'b0;     // クロック
    logic resetn = 1'b0;  // リセット(Lowで有効)

    // 10nsごとに1周期のクロックを作る
    always #5 clk = ~clk;

    logic        tx_push = 1'b0;   // 送るバイトを送信バッファへ入れるか
    logic [7:0]  tx_data = '0;     // 送るバイト
    logic        tx_not_full;      // 送信バッファに空きがあるか
    logic        rx_pop = 1'b0;    // 受信バッファの先頭のバイトを取り除くか
    logic [7:0]  rx_head;          // 受信バッファの先頭のバイト
    logic        rx_not_empty;     // 受信バッファに受信したバイトがあるか

    logic [31:0] araddr;           // 読み出し番地
    logic [ 2:0] arprot;           // 読み出しの保護属性
    logic        arvalid;          // 読み出し番地が有効か
    logic        arready = 1'b0;   // モデルが読み出し番地を受け取れるか
    logic [31:0] rdata = '0;       // 読み出したデータ
    logic [ 1:0] rresp = '0;       // 読み出しの応答
    logic        rvalid = 1'b0;    // 読み出したデータが有効か
    logic        rready;           // 橋渡し回路が読み出したデータを受け取れるか
    logic [31:0] awaddr;           // 書き込み番地
    logic [ 2:0] awprot;           // 書き込みの保護属性
    logic        awvalid;          // 書き込み番地が有効か
    logic        awready = 1'b0;   // モデルが書き込み番地を受け取れるか
    logic [31:0] wdata;            // 書き込むデータ
    logic [ 3:0] wstrb;            // 書き込むデータのうち有効なバイト
    logic        wvalid;           // 書き込むデータが有効か
    logic        wready = 1'b0;    // モデルが書き込むデータを受け取れるか
    logic [ 1:0] bresp = '0;       // 書き込みの応答
    logic        bvalid = 1'b0;    // 書き込みの応答が有効か
    logic        bready;           // 橋渡し回路が書き込みの応答を受け取れるか

    // 試験対象の橋渡し回路
    uart_bridge_sv #(.BUFFER_DEPTH(BUFFER_DEPTH)) dut (
        .clk(clk), .resetn(resetn),
        .tx_push(tx_push),
        .tx_data(tx_data),
        .tx_not_full(tx_not_full),
        .rx_pop(rx_pop),
        .rx_head(rx_head),
        .rx_not_empty(rx_not_empty),
        .m_axi_araddr(araddr),
        .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),
        .m_axi_awaddr(awaddr),
        .m_axi_awprot(awprot),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready)
    );

    // ===== PSのUART0のモデル =====
    // 信号はクロックの立ち下がりで変え，立ち上がりで橋渡し回路の信号を見る

    logic [7:0] model_rx_fifo[$];     // 受信FIFOにあるバイトの列(テストケースが入れる)
    logic [7:0] model_tx_log[$];      // 送信FIFOへ書き込まれたバイトの列
    bit         model_tx_full = 0;    // 送信FIFOが満杯か(テストケースが決める)
    int         model_delay = 0;      // 番地・データを受け取るまでと，応答を返すまでに空けるサイクル数
    int         model_status_errors = 0; // これから返す状態のレジスタの読み出しの応答のうち，失敗の応答にする数
    int         model_fifo_errors = 0;   // これから返す受信FIFOの読み出しの応答のうち，失敗の応答にする数(失敗の応答では受信FIFOからバイトを取り除かない)
    int         model_write_errors = 0;  // これから返す書き込みの応答のうち，失敗の応答にする数
    int         model_aw_extra = 0;   // 書き込み番地を受け取るまでに，番地・データに共通のサイクル数より多く空けるサイクル数
    int         model_w_extra = 1;    // 書き込みデータを受け取るまでに，番地・データに共通のサイクル数より多く空けるサイクル数
    int         model_reads = 0;      // 読み出し番地を受け取った回数
    bit         aw_received = 0;      // 書き込み番地を受け取り，まだ応答していないか
    bit         w_received = 0;       // 書き込みデータを受け取り，まだ応答していないか
    logic [31:0] model_awaddr;        // 受け取った書き込み番地
    logic [7:0]  model_wdata;         // 受け取った書き込みデータの最下位バイト

    // 読み出し: 番地を受け取ってから，番地に応じた値を応答とともに返す
    initial forever begin
        logic [31:0] addr;  // 受け取った読み出し番地
        // 読み出し番地が有効になるまで待つ
        @(negedge clk);
        if (!arvalid)
            continue;
        // 決められたサイクル数だけ空けてから受け取る
        repeat (model_delay) @(negedge clk);
        arready = 1'b1;
        @(posedge clk);
        // 待つ間にリセットで取り下げられていれば，受け取らずに次の番地を待つ
        if (!arvalid) begin
            @(negedge clk);
            arready = 1'b0;
            continue;
        end
        addr = araddr;
        model_reads++;
        @(negedge clk);
        arready = 1'b0;
        // 決められたサイクル数だけ空けてから応答する
        repeat (model_delay) @(negedge clk);
        // その番地で失敗の応答にする数が残っていれば，値0xe0を添えた失敗の応答にする
        // 0xe0は，状態としては受信FIFOが空でなく送信FIFOに空きがあることを表すため，橋渡し回路が誤って使えば受信FIFOを読みに行く
        if (
            // 状態のレジスタで，失敗の応答にする数が残っている
            (addr == UART_STATUS_ADDR && model_status_errors > 0)
            // 受信FIFOで，失敗の応答にする数が残っている
            || (addr == UART_FIFO_ADDR && model_fifo_errors > 0)
        ) begin
            if (addr == UART_STATUS_ADDR)
                model_status_errors--;
            else
                model_fifo_errors--;
            rresp = RESP_SLVERR;
            rdata = 32'h0000_00e0;
        end
        // 状態のレジスタは，受信FIFOが空か(ビット1)と，送信FIFOが満杯か(ビット4)を返す
        else if (addr == UART_STATUS_ADDR) begin
            rresp = RESP_OKAY;
            rdata = {27'b0, model_tx_full, 2'b0, model_rx_fifo.size() == 0, 1'b0};
        end
        // 受信FIFOは，先頭のバイトを取り除いて返す
        else if (addr == UART_FIFO_ADDR && model_rx_fifo.size() > 0) begin
            rresp = RESP_OKAY;
            rdata = {24'b0, model_rx_fifo.pop_front()};
        end
        // それ以外の番地と空の受信FIFOは0を返す
        else begin
            rresp = RESP_OKAY;
            rdata = 32'h0;
        end
        rvalid = 1'b1;
        // 橋渡し回路は応答を常に受け取るため，1サイクルで取り下げる
        @(posedge clk);
        if (!rready)
            fail("読み出しの応答を受け取れない状態になっている");
        @(negedge clk);
        rvalid = 1'b0;
    end

    // 書き込み番地: 決められたサイクル数だけ空けてから受け取る
    initial forever begin
        @(negedge clk);
        if (!awvalid || aw_received)
            continue;
        repeat (model_delay + model_aw_extra) @(negedge clk);
        awready = 1'b1;
        @(posedge clk);
        // 待つ間にリセットで取り下げられていれば，受け取らずに次の番地を待つ
        if (!awvalid) begin
            @(negedge clk);
            awready = 1'b0;
            continue;
        end
        model_awaddr = awaddr;
        aw_received = 1;
        @(negedge clk);
        awready = 1'b0;
    end

    // 書き込みデータ: 決められたサイクル数だけ空けてから受け取る
    // 空けるサイクル数を番地と変えて，番地とデータを受け取る順と，同じサイクルに受け取る場合を確かめる(既定はデータを番地より1サイクル後に受け取る)
    initial forever begin
        @(negedge clk);
        if (!wvalid || w_received)
            continue;
        repeat (model_delay + model_w_extra) @(negedge clk);
        wready = 1'b1;
        @(posedge clk);
        // 待つ間にリセットで取り下げられていれば，受け取らずに次のデータを待つ
        if (!wvalid) begin
            @(negedge clk);
            wready = 1'b0;
            continue;
        end
        model_wdata = wdata[7:0];
        if (wstrb != 4'b0001)
            fail($sformatf("書き込むバイトの指定: 期待値0001，実際%b", wstrb));
        w_received = 1;
        @(negedge clk);
        wready = 1'b0;
    end

    // 書き込みの応答: 番地とデータの両方を受け取ったら，送信FIFOへ記録して応答する
    initial forever begin
        @(negedge clk);
        if (!(aw_received && w_received))
            continue;
        repeat (model_delay) @(negedge clk);
        // 失敗の応答にする数が残っていれば，記録せずに失敗の応答にする
        if (model_write_errors > 0) begin
            model_write_errors--;
            bresp = RESP_SLVERR;
        end
        // 送信FIFOの番地へ空きがある状態で書き込まれたら記録する
        else begin
            bresp = RESP_OKAY;
            if (model_awaddr == UART_FIFO_ADDR && !model_tx_full)
                model_tx_log.push_back(model_wdata);
        end
        aw_received = 0;
        w_received = 0;
        bvalid = 1'b1;
        // 橋渡し回路は応答を常に受け取るため，1サイクルで取り下げる
        @(posedge clk);
        if (!bready)
            fail("書き込みの応答を受け取れない状態になっている");
        @(negedge clk);
        bvalid = 1'b0;
    end

    // 保護属性は常に非特権・セキュア・データの読み書きを表す値で出す
    always @(posedge clk) begin
        if (arvalid && arprot != 3'b000)
            fail($sformatf("読み出しの保護属性: 期待値000，実際%b", arprot));
        if (awvalid && awprot != 3'b000)
            fail($sformatf("書き込みの保護属性: 期待値000，実際%b", awprot));
    end

    // ===== CPU側の操作 =====

    logic [7:0] received[$];  // 受信バッファから取り出したバイトの列

    // リセットを入れてから解除し，モデルの状態を初期状態に戻す(受信FIFOはテストケースが後から入れる)
    task automatic reset_dut();
        @(negedge clk);
        resetn = 1'b0;
        model_rx_fifo.delete();
        model_tx_log.delete();
        model_tx_full = 0;
        model_delay = 0;
        model_status_errors = 0;
        model_fifo_errors = 0;
        model_write_errors = 0;
        model_aw_extra = 0;
        model_w_extra = 1;
        model_reads = 0;
        aw_received = 0;
        w_received = 0;
        received.delete();
        repeat (2) @(negedge clk);
        resetn = 1'b1;
    endtask

    // 送るバイトを1つ送信バッファへ入れる
    task automatic push_tx(input logic [7:0] value);
        @(negedge clk);
        tx_push = 1'b1;
        tx_data = value;
        @(negedge clk);
        tx_push = 1'b0;
    endtask

    // 受信バッファの先頭のバイトを取り出して記録する(取り除いた結果が先頭のバイトへ反映されるまで1サイクル待つ)
    task automatic pop_rx();
        @(negedge clk);
        received.push_back(rx_head);
        rx_pop = 1'b1;
        @(negedge clk);
        rx_pop = 1'b0;
    endtask

    // 受信バッファから，指定したバイト数を取り出し終えるまで待つ．打ち切りのサイクル数に達したら失敗とする
    task automatic receive(input int count);
        for (int cycle = 0; received.size() < count; cycle++) begin
            if (cycle >= MAX_CYCLES) begin
                fail($sformatf("受信バッファから%0dバイト取り出せない(%0dバイトで打ち切り)", count, received.size()));
                return;
            end
            // 受信したバイトがあれば取り出し，なければ1サイクル待つ
            if (rx_not_empty)
                pop_rx();
            else
                @(negedge clk);
        end
    endtask

    // モデルの送信FIFOへ指定したバイト数が書き込まれるまで待つ．打ち切りのサイクル数に達したら失敗とする
    task automatic wait_tx(input int count);
        for (int cycle = 0; model_tx_log.size() < count; cycle++) begin
            if (cycle >= MAX_CYCLES) begin
                fail($sformatf("送信FIFOへ%0dバイト書き込まれない(%0dバイトで打ち切り)", count, model_tx_log.size()));
                return;
            end
            @(negedge clk);
        end
    endtask

    // ===== 合否の判定 =====

    string test_name = "";     // 実行中のテストケースの名前
    int    test_errors = 0;    // 実行中のテストケースで見つかった不一致の数
    bit    test_open = 1'b0;   // 合否の件数へまだ数えていないテストケースがあるか
    int    passed = 0;         // 合格したテストケースの数
    int    failed = 0;         // 不合格だったテストケースの数

    // 実行中のテストケースを，不一致の有無に応じて合格・不合格の件数へ数える
    function automatic void finish_test();
        // 数えていないテストケースがなければ何もしない
        if (!test_open)
            return;
        // 不一致がなければ合格，あれば不合格として数える
        if (test_errors == 0)
            passed++;
        else
            failed++;
        test_open = 1'b0;
    endfunction

    // 前のテストケースを合否の件数へ数え，新しいテストケースを始める
    function automatic void begin_test(input string name);
        finish_test();
        test_name   = name;
        test_errors = 0;
        test_open   = 1'b1;
    endfunction

    // テストケースの名前を文字列リテラルで指定してbegin_testを呼ぶ．xsimは日本語の文字列リテラルを
    // string型の値として渡すと文字化けさせ，$sformatfの書式として渡した場合は正しく扱うため，書式を経由させる
    `define BEGIN_TEST(name) begin_test($sformatf(name))

    // 不一致を，実行中のテストケースの名前を添えてエラーとして表示し，不一致の数に加える
    function automatic void fail(input string message);
        $error("[%s] %s", test_name, message);
        test_errors++;
    endfunction

    // 受信バッファから取り出したバイトの列を確かめる
    function automatic void expect_received(input logic [7:0] values[$]);
        if (received != values)
            fail($sformatf("取り出したバイト: 期待値%p，実際%p", values, received));
    endfunction

    // 送信FIFOへ書き込まれたバイトの列を確かめる
    function automatic void expect_sent(input logic [7:0] values[$]);
        if (model_tx_log != values)
            fail($sformatf("送信FIFOへ書き込まれたバイト: 期待値%p，実際%p", values, model_tx_log));
    endfunction

    // ===== テストケース =====

    initial begin
        // 受信FIFOに3バイトある状態で，受信バッファから取り出す
        `BEGIN_TEST("受信FIFOのバイトを受信バッファから順に取り出せる");
        reset_dut();
        model_rx_fifo = '{8'h41, 8'h42, 8'h43};
        receive(3);
        // 受信した順に取り出せる
        expect_received('{8'h41, 8'h42, 8'h43});

        // 番地・データの受け取りと応答に3サイクルずつかかる状態で，受信FIFOのバイトを取り出す
        `BEGIN_TEST("スレーブの応答が遅くても受信FIFOのバイトを取り出せる");
        reset_dut();
        model_delay = 3;
        model_rx_fifo = '{8'h44, 8'h45};
        receive(2);
        // 受信した順に取り出せる
        expect_received('{8'h44, 8'h45});

        // 受信バッファの大きさより多いバイトが受信FIFOにある状態で，しばらく取り出さずに待ってから取り出す
        `BEGIN_TEST("受信バッファが満杯の間は受信FIFOにバイトを残し，取り出すと続きを受け取る");
        reset_dut();
        model_rx_fifo = '{8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56};
        repeat (START_WAIT_CYCLES + 200) @(negedge clk);
        // 受信バッファに入りきらない分は，受信FIFOに残る
        if (model_rx_fifo.size() != 6 - BUFFER_DEPTH)
            fail($sformatf("受信FIFOに残ったバイト数: 期待値%0d，実際%0d", 6 - BUFFER_DEPTH, model_rx_fifo.size()));
        // 取り出すと，残りも順に受け取れる
        receive(6);
        expect_received('{8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56});

        // 送信バッファへ2バイト入れる
        `BEGIN_TEST("送信バッファのバイトを送信FIFOへ順に書き込む");
        reset_dut();
        push_tx(8'h61);
        push_tx(8'h62);
        wait_tx(2);
        // 入れた順に書き込まれる
        expect_sent('{8'h61, 8'h62});

        // スレーブが書き込みデータを書き込み番地より2サイクル先に受け取る状態で，送信バッファへ2バイト入れる
        `BEGIN_TEST("書き込みデータを書き込み番地より先に受け取られても送信FIFOへ書き込む");
        reset_dut();
        model_aw_extra = 2;
        model_w_extra = 0;
        push_tx(8'h64);
        push_tx(8'h65);
        wait_tx(2);
        // 入れた順に書き込まれる
        expect_sent('{8'h64, 8'h65});

        // スレーブが書き込み番地とデータを同じサイクルに受け取る状態で，送信バッファへ2バイト入れる
        `BEGIN_TEST("書き込み番地とデータを同じサイクルに受け取られても送信FIFOへ書き込む");
        reset_dut();
        model_w_extra = 0;
        push_tx(8'h66);
        push_tx(8'h67);
        wait_tx(2);
        // 入れた順に書き込まれる
        expect_sent('{8'h66, 8'h67});

        // 送信FIFOが満杯の状態で送信バッファへ入れ，しばらく待ってから空きを作る
        `BEGIN_TEST("送信FIFOが満杯の間は書き込まず，空いたら書き込む");
        reset_dut();
        model_tx_full = 1;
        push_tx(8'h63);
        repeat (START_WAIT_CYCLES + 200) @(negedge clk);
        // 満杯の間は書き込まれない
        expect_sent('{});
        // 空きができると書き込まれる
        model_tx_full = 0;
        wait_tx(1);
        expect_sent('{8'h63});

        // 送信FIFOが満杯の状態で，送信バッファの大きさより1つ多く入れる
        `BEGIN_TEST("送信バッファが満杯になると空きがないことを示し，入れたバイトを捨てる");
        reset_dut();
        model_tx_full = 1;
        push_tx(8'h71);
        push_tx(8'h72);
        push_tx(8'h73);
        push_tx(8'h74);
        // 満杯になると空きがないことを示す
        @(negedge clk);
        if (tx_not_full)
            fail("満杯の送信バッファで空きがあることを示している");
        push_tx(8'h75);
        // 空きができると，満杯になるまでに入れた4バイトだけが書き込まれる
        model_tx_full = 0;
        wait_tx(4);
        repeat (200) @(negedge clk);
        expect_sent('{8'h71, 8'h72, 8'h73, 8'h74});

        // 受信と送信を同時に行う
        `BEGIN_TEST("受信と送信を並行して行える");
        reset_dut();
        model_rx_fifo = '{8'h81, 8'h82, 8'h83};
        push_tx(8'h91);
        push_tx(8'h92);
        receive(3);
        wait_tx(2);
        // どちらも順番どおりに行われる
        expect_received('{8'h81, 8'h82, 8'h83});
        expect_sent('{8'h91, 8'h92});

        // リセットを解除した直後に，求めていない読み出しと書き込みの応答を届ける
        `BEGIN_TEST("リセットの解除後に届いた求めていない応答を捨て，その後の読み書きを正しく行う");
        reset_dut();
        model_rx_fifo = '{8'ha1};
        // リセットの直前に始まっていた読み出しをモデルが受け取った場合に数えないよう，数え直してから届ける
        repeat (5) @(negedge clk);
        model_reads = 0;
        // 書き換える前の回路の応答を模して，読み出しの応答と書き込みの応答を1回ずつ届ける
        @(negedge clk);
        rresp = RESP_OKAY;
        rdata = 32'h0000_00e0;
        rvalid = 1'b1;
        bresp = RESP_OKAY;
        bvalid = 1'b1;
        @(negedge clk);
        rvalid = 1'b0;
        bvalid = 1'b0;
        // 待つサイクル数の間は読み出しを求めない
        repeat (START_WAIT_CYCLES - 20) @(negedge clk);
        if (model_reads != 0)
            fail($sformatf("待つ間に読み出しを求めた(%0d回)", model_reads));
        // 待ち終えた後は，届いた応答に惑わされず受信FIFOのバイトを取り出せる
        push_tx(8'hb1);
        receive(1);
        wait_tx(1);
        expect_received('{8'ha1});
        expect_sent('{8'hb1});

        // 受信FIFOが空の状態で，状態のレジスタの読み出しに失敗の応答を3回返す
        `BEGIN_TEST("状態の読み出しの失敗の応答で届いた値は使わず，読み出し直す");
        reset_dut();
        model_status_errors = 3;
        repeat (START_WAIT_CYCLES + 200) @(negedge clk);
        // 失敗の応答の値に従って受信FIFOを読みに行かず，状態を読み直し続ける
        if (rx_not_empty)
            fail("失敗の応答の値に従って受信FIFOを読み出している");
        if (model_status_errors != 0)
            fail($sformatf("状態を読み直していない(残りの失敗の応答%0d回)", model_status_errors));
        // 読み直した状態に従って，後から届いたバイトを受け取る
        model_rx_fifo = '{8'hc1};
        receive(1);
        expect_received('{8'hc1});

        // 受信FIFOの読み出しに失敗の応答を1回返す
        `BEGIN_TEST("受信FIFOの読み出しの失敗の応答で届いた値は受信バッファへ入れない");
        reset_dut();
        model_fifo_errors = 1;
        model_rx_fifo = '{8'hc2, 8'hc3};
        receive(2);
        repeat (200) @(negedge clk);
        // 失敗の応答に添えた値は入らず，受信FIFOのバイトだけを受け取る
        expect_received('{8'hc2, 8'hc3});
        if (rx_not_empty)
            fail("失敗の応答に添えた値が受信バッファに入っている");

        // 送信FIFOへの書き込みに失敗の応答を返す
        `BEGIN_TEST("書き込みの失敗の応答でも送信バッファから取り除き，次のバイトへ進む");
        reset_dut();
        model_write_errors = 1;
        push_tx(8'hd1);
        push_tx(8'hd2);
        wait_tx(1);
        repeat (200) @(negedge clk);
        // 失敗したバイトは書き直さず，次のバイトだけが書き込まれる
        expect_sent('{8'hd2});

        // 最後のテストケースを数える
        finish_test();

        // 合否の件数を表示し，不合格があれば失敗として終える
        $display("==== 合格 %0d件，不合格 %0d件 ====", passed, failed);
        if (failed > 0)
            $fatal(1, "不合格のテストケースがあります");
        $finish;
    end

endmodule
