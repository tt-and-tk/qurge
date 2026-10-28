`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// CPUの命令の動作を検証するテストベンチ．
// CPU本体(cpu_sv)とメインメモリ(ram_sv)は実物を使い，ROMと除算IPをテストベンチ用のモデルに差し替える．
// テストケースごとにmachine.svhの関数で組んだ命令列をROMへ書き込んで実行し，実行後のレジスタ・メモリ・
// 停止の有無と番地を期待値と比較する．最後に合否の件数を表示し，失敗があれば$fatalで終了する．
//
// このファイルで使う用語
// - テストケース: 1つの命令列を実行し，その結果を期待値と比較する単位．合否はテストケースごとに数える
// - 正常終了: 命令列の末尾に置いた，自分自身へジャンプし続ける命令の実行に入ること(仕様上のプログラムの終わり方)
// - 停止: CPUが実行できない命令や不正な値を検出して実行を止めること(仕様はhalt.md)
// - 先読み: CPUが命令を実行している間に，次の命令をROMから取得しておくこと
// - メインメモリの後半: PCのうちROMの命令数の上限に続く範囲が，ここに置いた命令に対応する(仕様はrom.md)．命令列を置いた部分をコード領域と呼ぶ
// - フォワーディング: 直前の命令がレジスタへ書き込む値を，次の命令がレジスタを経由せずに受け取ること
// - 同時実行: 連続した2命令の実行を，同じサイクルに始めること．2命令のうち先に実行する命令を先頭，後の命令を2番目と呼ぶ．
//   2番目にできるのは単純な演算(1サイクルで完了し，レジスタへ書き込む以外の動作を持たない命令)だけである
// - 所要サイクル数: リセットを解除してから，正常終了または停止に至るまでのサイクル数
//////////////////////////////////////////////////////////////////////////////////


`include "machine.svh"
`include "register.svh"
`include "alu.svh"
`include "ram.svh"
`include "rom.svh"

module cpu_tb;
    import machine_p::*;
    import alu_p::*;

    localparam int MAX_CYCLES = 5000;  // 1テストケースの実行を打ち切るサイクル数

    // ===== 試験対象と周辺のモデル =====

    logic clk = 1'b0;     // クロック
    logic resetn = 1'b0;  // リセット(Lowで有効)

    // 10nsごとに1周期のクロックを作る
    always #5 clk = ~clk;

    rom_read_if  rom_read1();  // CPUとROMの接続(1つ目の読み出しポート)
    rom_read_if  rom_read2();  // CPUとROMの接続(2つ目の読み出しポート)
    ram_read_if  ram_read();   // CPUとメインメモリの接続(読み出し)
    ram_write_if ram_write();  // CPUとメインメモリの接続(書き込み)

    logic [31:0] div_divisor_tdata, div_dividend_tdata;      // 符号ありの除算IPへ送る除数・被除数
    logic        div_divisor_tvalid, div_dividend_tvalid;    // 符号ありの除算IPへ送る除数・被除数が有効か
    logic [63:0] div_dout_tdata;                             // 符号ありの除算IPの計算結果
    logic        div_dout_tvalid;                            // 符号ありの除算IPの計算結果が出たか
    logic [31:0] divu_divisor_tdata, divu_dividend_tdata;    // 符号なしの除算IPへ送る除数・被除数
    logic        divu_divisor_tvalid, divu_dividend_tvalid;  // 符号なしの除算IPへ送る除数・被除数が有効か
    logic [63:0] divu_dout_tdata;                            // 符号なしの除算IPの計算結果
    logic        divu_dout_tvalid;                           // 符号なしの除算IPの計算結果が出たか

    logic [ 3:0] btn = 4'b0;                               // タクトスイッチ
    logic [ 1:0] sw = 2'b0;                                // DIPスイッチ
    logic [ 3:0] led;                                      // LED
    logic [ 5:0] rgb_led;                                  // RGB LED
    logic [ 7:0] ja, jb;                                   // Pmod A・Pmod B
    logic [ 7:0] ar;                                       // Arduinoのデジタル入出力0〜7番ピン
    logic        a, ar_sda, ar_scl;                        // Arduinoの単体デジタルピン・I2CのSDA/SCL
    logic        ck_mosi, ck_sck, ck_ss;                   // Arduino SPIのMOSI・SCK・SS
    logic        ck_miso = 1'b0;                           // Arduino SPIのMISO
    logic        eth_rstn, eth_csn, eth_mosi, eth_sck;     // EthernetモジュールのRSTn・CSn・MOSI・SCK
    logic        eth_intn = 1'b0;                          // EthernetモジュールのINTn
    logic        eth_miso = 1'b0;                          // EthernetモジュールのMISO
    logic        uart_tx_push;                             // CPUが送信するデータを送信バッファへ入れるか
    logic [ 7:0] uart_tx_data;                             // CPUが送信するデータ
    logic        uart_tx_not_full = 1'b0;                  // 送信バッファに空きがあるか
    logic        uart_rx_pop;                              // CPUが受信バッファの先頭のバイトを取り除くか
    logic [ 7:0] uart_rx_head = '0;                        // 受信バッファの先頭のバイト
    logic        uart_rx_not_empty = 1'b0;                 // 受信バッファに受信したバイトがあるか
    logic [26:8] gpio;                                     // ラズパイヘッダーのGPIO8〜GPIO26

    // 試験対象のCPU
    cpu_sv dut (
        .clk(clk), .resetn(resetn),
        .rom_read1(rom_read1),
        .rom_read2(rom_read2),
        .ram_read(ram_read),
        .ram_write(ram_write),
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
        .uart_tx_push(uart_tx_push),
        .uart_tx_data(uart_tx_data),
        .uart_tx_not_full(uart_tx_not_full),
        .uart_rx_pop(uart_rx_pop),
        .uart_rx_head(uart_rx_head),
        .uart_rx_not_empty(uart_rx_not_empty),
        .gpio(gpio)
    );

    // メインメモリ(実物)
    ram_sv ram (
        .clk(clk), .resetn(resetn),
        .ram_read(ram_read),
        .ram_write(ram_write)
    );

    // テストケースごとに命令列を書き換えるROM
    tb_rom rom (
        .clk(clk),
        .rom_read1(rom_read1),
        .rom_read2(rom_read2)
    );

    // 符号ありの除算IPのモデル．レイテンシはブロックダイアグラム上の除算IP(top_div_gen_0_0)に合わせる
    tb_divider #(.LATENCY(36), .IS_SIGNED(1)) div_model (
        .aclk(clk), .aresetn(resetn),
        .s_axis_divisor_tdata(div_divisor_tdata),
        .s_axis_divisor_tvalid(div_divisor_tvalid),
        .s_axis_dividend_tdata(div_dividend_tdata),
        .s_axis_dividend_tvalid(div_dividend_tvalid),
        .m_axis_dout_tdata(div_dout_tdata),
        .m_axis_dout_tvalid(div_dout_tvalid)
    );

    // 符号なしの除算IPのモデル．レイテンシはブロックダイアグラム上の除算IP(top_div_gen_0_1)に合わせる
    tb_divider #(.LATENCY(34), .IS_SIGNED(0)) divu_model (
        .aclk(clk), .aresetn(resetn),
        .s_axis_divisor_tdata(divu_divisor_tdata),
        .s_axis_divisor_tvalid(divu_divisor_tvalid),
        .s_axis_dividend_tdata(divu_dividend_tdata),
        .s_axis_dividend_tvalid(divu_dividend_tvalid),
        .m_axis_dout_tdata(divu_dout_tdata),
        .m_axis_dout_tvalid(divu_dout_tvalid)
    );

    // ===== UARTの橋渡し回路のモデル =====
    // CPUから見た受け渡しだけを模し，PSのUART0との読み書きは行わない．
    // 実物と同じく，受け取った指示は次のサイクルに状態(先頭のバイト・バイトがあるか・空きがあるか)へ反映する

    localparam int UART_TX_DEPTH = 4;  // 送信バッファにためられるバイト数(満杯の場合を少ない命令で確かめるため，実物より少なくする)

    logic [7:0] uart_rx_queue[$];  // 受信バッファにあるバイトの列(実行前にテストケースが入れる)
    logic [7:0] uart_tx_log[$];    // 送信バッファへ入ったバイトの列

    // 受信バッファ．読み終えた通知を受けたら先頭のバイトを取り除く
    always @(posedge clk) begin
        // 読み終えた通知を受け，バイトがあれば先頭を取り除く(リセットでは消さない．テストケースが実行前に入れた列を残すため)
        if (resetn && uart_rx_pop && uart_rx_queue.size() > 0)
            void'(uart_rx_queue.pop_front());
        // 取り除いた後の状態を出す
        uart_rx_not_empty <= uart_rx_queue.size() > 0;
        uart_rx_head      <= (uart_rx_queue.size() > 0) ? uart_rx_queue[0] : 8'h00;
    end

    // 送信バッファ．送信の指示を受け，空きがあれば送信するデータを記録する
    always @(posedge clk) begin
        // 空きがあれば記録する
        if (resetn && uart_tx_push && uart_tx_log.size() < UART_TX_DEPTH)
            uart_tx_log.push_back(uart_tx_data);
        // 記録した後の状態を出す
        uart_tx_not_full <= uart_tx_log.size() < UART_TX_DEPTH;
    end

    // ===== テストケースの記述を短くする関数 =====

    // イミディエイトデータを使用するimmを作る
    function automatic imm_t im(input logic [31:0] value);
        return {1'b1, value};
    endfunction

    localparam imm_t NO_IMM = 33'h0;  // イミディエイトデータを使用しないimm

    // 即値をレジスタへ代入する命令を作る
    function automatic machine_t movi(input addr_t rd, input logic [31:0] value);
        return mov(4'hf, 6'h00, rd, im(value));
    endfunction

    // レジスタの値を別のレジスタへ代入する命令を作る
    function automatic machine_t movr(input addr_t rd, input addr_t rs1);
        return mov(4'hf, rs1, rd, NO_IMM);
    endfunction

    // 各フィールドを直接指定して命令を作る．machine.svhに関数のない，未定義のfuncなどを表すために使う
    function automatic machine_t raw(
        input type_t m_type, input func_t func, input addr_t rs1, input addr_t rs2, input addr_t rd, input imm_t imm
    );
        return {m_type, func, 4'h0, rs1, rs2, rd, imm};
    endfunction

    typedef machine_t machine_queue_t[$];  // 命令列

    localparam int CODE_AREA_PC = rom_p::CODE_AREA_PC_BASE;  // メモリの後半の先頭の命令に対応するPC

    // メモリの後半の先頭からindex番目の命令を置くメインメモリの番地を返す
    function automatic int code_area_address(input int index);
        return ram_p::CODE_AREA_BASE + index * 8;
    endfunction

    // 命令をメモリの後半のindex番目へWMで書き込む命令列を作る．下位ワード(イミディエイトデータ)を小さい番地へ，
    // 上位ワード(命令語)をその4バイト後へ書く．書き込む値の受け渡しにr15を使う
    function automatic machine_queue_t store_code(input int index, input machine_t instruction);
        return '{movi(15, instruction[31:0]),  wm(4'hf, 6'h00, 15, im(code_area_address(index))),
                 movi(15, instruction[63:32]), wm(4'hf, 6'h00, 15, im(code_area_address(index) + 4))};
    endfunction

    // ===== 実行と結果の採取 =====

    typedef enum {ENDED, HALTED, TIMED_OUT} outcome_enum;  // 実行の終わり方(正常終了・停止・打ち切り)

    outcome_enum    outcome;                          // 直前の実行の終わり方
    int             cycles;                           // 直前の実行の所要サイクル数
    bit             redirect_met_early_jump;          // 直前の実行で，実行段が分岐・ジャンプで取得し直すサイクルに，先行取得する即値のジャンプがROMから届いたことがあるか
    register_t      regs[0:REGISTER_MAX_ADDR];        // 直前の実行を終えた時点のレジスタの値
    bit             kernel_mode;                      // 直前の実行を終えた時点で，動作状態がカーネルモードか(0ならユーザーモード)
    int             end_pc;                           // 正常終了を表す命令の番地
    machine_queue_t code_area;                        // 実行前にコード領域へ直接置く命令列
    int             code_area_index = 0;              // code_areaを置き始める，メモリの後半の先頭からの命令の順番
    machine_queue_t rom_tail;                         // 実行前にROMの末尾(最後の命令をROMの命令数の上限の直前の番地に揃える位置)へ置く命令列

    // CPUの現在のレジスタの値と動作状態を，実行を終えた時点の値として写し取る
    function automatic void take_snapshot();
        for (int i = 0; i <= REGISTER_MAX_ADDR; i++)
            regs[i] = dut.alu_sv_0.register[i];
        // PCはレジスタ配列ではなく，実行段の命令の番地を保持するex_pcから写し取る(実行段で停止した場合は停止した番地になる)
        regs[PC_ADDR] = dut.alu_sv_0.ex_pc;
        // 動作状態はレジスタ配列ではなく，CPUの中の状態から写し取る
        kernel_mode = dut.alu_sv_0.kernel_mode;
    endfunction

    // メインメモリをすべて0にする
    function automatic void clear_ram();
        foreach (ram.memory_lane_0[i]) begin
            ram.memory_lane_0[i] = '0;
            ram.memory_lane_1[i] = '0;
            ram.memory_lane_2[i] = '0;
            ram.memory_lane_3[i] = '0;
        end
    endfunction

    // メインメモリの指定した番地へ1バイトを書き込む
    function automatic void set_ram_byte(input int addr, input logic [7:0] value);
        // メインメモリは番地を4で割った余りごとに別の配列(レーン)へ分けて持っている
        case (addr % 4)
            0: ram.memory_lane_0[addr / 4] = value;
            1: ram.memory_lane_1[addr / 4] = value;
            2: ram.memory_lane_2[addr / 4] = value;
            default: ram.memory_lane_3[addr / 4] = value;
        endcase
    endfunction

    // 命令列をメモリの後半のindex番目から直接書き込む．各命令の下位のバイトほど小さい番地に置く
    function automatic void put_code_area(input int index, input machine_queue_t instructions);
        // 1命令ずつ，8バイトを下位のバイトから順に書き込む
        foreach (instructions[i])
            for (int b = 0; b < 8; b++)
                set_ram_byte(code_area_address(index + i) + b, instructions[i][b * 8 +: 8]);
    endfunction

    // 命令列をROMの先頭へ，code_area・rom_tailの命令列をそれぞれメモリの後半・ROMの末尾へ書き込み，
    // リセットしてから，正常終了・停止・打ち切りのいずれかに至るまで実行する．
    // 実行の終わり方と，終えた時点のレジスタの値を残す．停止した場合のレジスタの値は，停止を検出した
    // 時点のもの(初期値へ戻る前)になる．
    // 末尾に正常終了を表す命令を付けない場合(ROMの範囲外へ進む場合の検証)は2番目の引数を0に，
    // 前の実行でメモリへ書いた値を残す場合は3番目の引数を1にする
    task automatic run(input machine_t body[$], input bit append_end = 1'b1, input bit keep_ram = 1'b0);
        machine_t instructions[$] = body;  // ROMへ書き込む命令列
        bit       unreachable_halt;        // このサイクルに，命令を置けない番地へ進んだことで停止するか
        int       unreachable_pc;          // その停止で停止する番地

        // 命令列の直後の番地を正常終了を表す命令の番地とし，そこに自分自身へジャンプする命令を置く
        end_pc = body.size();
        if (append_end)
            instructions.push_back(jmp(6'h00, im(end_pc)));

        // リセットを入れる
        @(negedge clk);
        resetn = 1'b0;
        // リセット中に，メインメモリを消す(残す指定がなければ)
        if (!keep_ram)
            clear_ram();
        // リセット中に，メモリの後半へ置く命令列を書き込む(メモリを消した後に書くため，消す処理より後に置く)
        put_code_area(code_area_index, code_area);
        // リセット中に，命令列をROMへ書き込む
        rom.load(instructions);
        // リセット中に，ROMの末尾へ置く命令列を書き込む(有効な命令数がROMの命令数の上限まで広がる)
        if (rom_tail.size() > 0)
            rom.place(rom_p::MAX_LINE_NUM - rom_tail.size(), rom_tail);
        // リセット中に，前の実行で送信バッファへ入ったバイトを消す
        uart_tx_log.delete();
        // リセットを2サイクル保ってから解除する
        repeat (2) @(negedge clk);
        resetn = 1'b1;

        // 実行段が取得し直すサイクルに先行取得する即値のジャンプが届いたかを，まだ届いていない状態から数え始める
        redirect_met_early_jump = 1'b0;
        // 停止・正常終了・打ち切りのいずれかに至るまで1サイクルずつ進める
        for (int cycle = 0; ; cycle++) begin
            // ROMにもメモリの後半にも命令を置けない番地へ進んで停止する場合は，CPUがその番地をどこにも残さないため，
            // 停止する前のこのサイクルのうちに，停止するかとその番地(取得用のプログラムカウンタ)を控える
            unreachable_halt = dut.alu_sv_0.pipeline_drained && !dut.alu_sv_0.pc_in_code_area;
            unreachable_pc   = dut.alu_sv_0.fetch_pc;
            // 実行段が取得し直すと決まったサイクルに，先行取得する即値のジャンプが届いたかを控える
            if (dut.alu_sv_0.ex_redirects && dut.alu_sv_0.push_early_jump)
                redirect_met_early_jump = 1'b1;
            // クロックの立ち上がりで更新された値が確定するのを待つ
            @(posedge clk);
            #1;
            // ここまでに経たサイクル数を，所要サイクル数として控える
            cycles = cycle + 1;
            // 停止した．仕様上は停止と同時にレジスタが初期値へ戻るが，CPUは停止を検出した次のクロックで
            // 戻すため，このサイクルのうちに採取すれば停止した番地と書き換えの有無を確かめられる．
            // 停止と同じクロックで初期値へ戻す実装に変えた場合は，この採取方法を見直す必要がある
            if (dut.alu_sv_0.is_halted) begin
                outcome = HALTED;
                break;
            end
            // 正常終了を表す命令の実行に入った
            if (append_end && dut.alu_sv_0.ex_pc == end_pc && dut.alu_sv_0.ex_occupied) begin
                outcome = ENDED;
                break;
            end
            // どちらにも至らないまま上限のサイクル数に達した
            if (cycle >= MAX_CYCLES) begin
                outcome = TIMED_OUT;
                break;
            end
        end

        // 正常終了した場合は，正常終了を表す命令を渡したサイクルに完了した2本目のパイプラインの命令の結果が，
        // 次のサイクルにレジスタへ書き込まれるため，1サイクル進めてから写し取る．
        // 正常終了を表す命令は自分自身へジャンプし続けるだけで，レジスタを書き換えないため，進めても採取する値は変わらない．
        // 停止した場合は進めない(次のクロックでレジスタが初期値へ戻るため)．このため，停止を検出したサイクルに
        // 書き込みを待っていた2本目の結果は，写し取る値に含まれない
        if (outcome == ENDED) begin
            @(posedge clk);
            #1;
        end
        // 実行を終えた時点のレジスタの値を写し取る
        take_snapshot();
        // 命令を置けない番地へ進んで停止した場合は，控えておいたその番地を停止した番地とする
        if (outcome == HALTED && unreachable_halt)
            regs[PC_ADDR] = unreachable_pc;
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

    // 前のテストケースを合否の件数へ数え，新しいテストケースを始める．
    // UARTの受信バッファ，メモリの後半・ROMの末尾へ置く命令列は空に戻す
    function automatic void begin_test(input string name);
        // 前のテストケースを数える
        finish_test();
        // 新しいテストケースの名前を控え，不一致の数を0から数え直す
        test_name    = name;
        test_errors  = 0;
        test_open    = 1'b1;
        // UARTの受信バッファを空にする
        uart_rx_queue.delete();
        // メモリの後半・ROMの末尾へ置く命令列を空にする
        code_area.delete();
        code_area_index = 0;
        rom_tail.delete();
    endfunction

    // テストケースの名前を文字列リテラルで指定してbegin_testを呼ぶ．xsimは日本語の文字列リテラルを
    // string型の値として渡すと文字化けさせ，$sformatfの書式として渡した場合は正しく扱うため，書式を経由させる
    `define BEGIN_TEST(name) begin_test($sformatf(name))

    // 不一致を，実行中のテストケースの名前を添えてエラーとして表示し，不一致の数に加える
    function automatic void fail(input string message);
        $error("[%s] %s", test_name, message);
        test_errors++;
    endfunction

    // 直前の実行が正常終了したことを確かめる
    function automatic void expect_end();
        if (outcome != ENDED)
            fail($sformatf("正常終了していない(%s，PC=%0d)", outcome.name(), regs[PC_ADDR]));
    endfunction

    // 直前の実行が，指定した番地の命令で停止したことを確かめる
    function automatic void expect_halt(input int pc);
        // 停止していない
        if (outcome != HALTED)
            fail($sformatf("停止していない(%s，PC=%0d)", outcome.name(), regs[PC_ADDR]));
        // 停止したが，番地が違う
        else if (regs[PC_ADDR] != pc)
            fail($sformatf("停止した番地: 期待値%0d，実際%0d", pc, regs[PC_ADDR]));
    endfunction

    // 直前の実行を終えた時点のレジスタの値を確かめる
    function automatic void expect_reg(input addr_t addr, input logic [31:0] value);
        if (regs[addr] !== value)
            fail($sformatf("レジスタ0x%02h: 期待値0x%08h，実際0x%08h", addr, value, regs[addr]));
    endfunction

    // 直前の実行を終えた時点の動作状態を確かめる
    function automatic void expect_kernel_mode(input bit value);
        // 期待値ごとに，日本語の文字列を書式へ直接書く(xsimは日本語の文字列リテラルを値として渡すと文字化けさせるため)
        if (kernel_mode !== value) begin
            if (value)
                fail($sformatf("動作状態: 期待値カーネルモード，実際ユーザーモード"));
            else
                fail($sformatf("動作状態: 期待値ユーザーモード，実際カーネルモード"));
        end
    endfunction

    // メインメモリの指定した番地の1バイトを返す
    function automatic logic [7:0] ram_byte(input int addr);
        // メインメモリは番地を4で割った余りごとに別の配列(レーン)へ分けて持っている
        case (addr % 4)
            0: return ram.memory_lane_0[addr / 4];
            1: return ram.memory_lane_1[addr / 4];
            2: return ram.memory_lane_2[addr / 4];
            default: return ram.memory_lane_3[addr / 4];
        endcase
    endfunction

    // メインメモリの指定した番地の1バイトを確かめる
    function automatic void expect_mem(input int addr, input logic [7:0] value);
        if (ram_byte(addr) !== value)
            fail($sformatf("メモリ0x%04h番地: 期待値0x%02h，実際0x%02h", addr, value, ram_byte(addr)));
    endfunction

    // メインメモリの指定した番地から4バイトを，下位バイトを小さい番地に置いた32ビット値として確かめる
    function automatic void expect_mem32(input int addr, input logic [31:0] value);
        // 1バイトずつ，下位のバイトから順に確かめる
        for (int i = 0; i < 4; i++)
            expect_mem(addr + i, value[i * 8 +: 8]);
    endfunction

    // 直前の実行の所要サイクル数を確かめる
    function automatic void expect_cycles(input int value);
        if (cycles != value)
            fail($sformatf("所要サイクル数: 期待値%0d，実際%0d", value, cycles));
    endfunction

    // ===== テストケース =====
    // 各テストケースは，名前を付けて始め，命令列を実行し，結果を確かめる．
    // 汎用レジスタはr0〜r15と書く(r0はリセット後の初期値0のまま使うことがある)

    // 処理を実行しない(N系)
    task automatic test_n_type();
        // r1へ代入した後にNOPを2つ実行する
        `BEGIN_TEST("NOPは何も書き換えずに次の命令へ進む");
        run('{movi(1, 32'h1234), nop(), nop()});
        // 正常終了し，r1が代入した値のまま残る
        expect_end();
        expect_reg(1, 32'h1234);

        // N系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("N系で未定義のfuncは停止する");
        run('{nop(), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(1);
    endtask

    // 演算系(P系)
    task automatic test_p_type();
        // r1・r2の論理演算の結果をr3〜r7へ格納する
        `BEGIN_TEST("AND/OR/XOR/NOT/NAND");
        run('{movi(1, 32'hf0f0_1234), movi(2, 32'hff00_ff00),
              and_(1, 2, 3), or_(1, 2, 4), xor_(1, 2, 5), not_(1, 6), nand_(1, 2, 7)});
        // 各演算の結果がビットごとの演算と一致する
        expect_end();
        expect_reg(3, 32'hf000_1200);
        expect_reg(4, 32'hfff0_ff34);
        expect_reg(5, 32'h0ff0_ed34);
        expect_reg(6, 32'h0f0f_edcb);
        expect_reg(7, 32'h0fff_edff);

        // 0xffffffff+1と0-1(桁あふれ)，100+58と100-58(通常)を計算する
        `BEGIN_TEST("ADD/SUBは32ビットで桁あふれする");
        run('{movi(1, 32'hffff_ffff), movi(2, 32'h1), movi(3, 32'd100), movi(4, 32'd58),
              add(1, 2, 5), sub(0, 2, 6), add(3, 4, 7), sub(3, 4, 8)});
        // 桁あふれした上位ビットは捨てられる
        expect_end();
        expect_reg(5, 32'h0);
        expect_reg(6, 32'hffff_ffff);
        expect_reg(7, 32'd158);
        expect_reg(8, 32'd42);

        // 0x10001の2乗(64ビットでは0x1_0002_0001)，-3×5，5×5を計算する
        `BEGIN_TEST("MULは積の下位32ビットを格納する");
        run('{movi(1, 32'h0001_0001), movi(2, 32'hffff_fffd), movi(3, 32'd5),
              mul(1, 1, 4), mul(2, 3, 5), mul(3, 3, 6)});
        // 積の下位32ビットが格納される
        expect_end();
        expect_reg(4, 32'h0002_0001);
        expect_reg(5, 32'hffff_fff1);
        expect_reg(6, 32'd25);

        // 7/2，-7/2，7/-2，-7/-2の商と余りを求める
        `BEGIN_TEST("DIVは0方向へ切り捨て，余りは被除数の符号に従う");
        run('{movi(1, 32'd7), movi(2, 32'd2), movi(3, -32'sd7), movi(4, -32'sd2),
              div(1, 2, 5, im(6)), div(3, 2, 7, im(8)), div(1, 4, 9, im(10)), div(3, 4, 11, im(12))});
        // 商は0方向へ切り捨てられ，余りは被除数と同じ符号になる
        expect_end();
        expect_reg(5, 32'd3);
        expect_reg(6, 32'd1);
        expect_reg(7, -32'sd3);
        expect_reg(8, -32'sd1);
        expect_reg(9, -32'sd3);
        expect_reg(10, 32'd1);
        expect_reg(11, 32'd3);
        expect_reg(12, -32'sd1);

        // r4へ値を入れてから，余りの格納先を指定しないDIVを実行する
        `BEGIN_TEST("DIVはimm未使用なら余りを書き込まない");
        run('{movi(1, 32'd7), movi(2, 32'd2), movi(4, 32'h55), div(1, 2, 3, NO_IMM)});
        // 商だけが格納され，r4やr0は書き換わらない
        expect_end();
        expect_reg(3, 32'd3);
        expect_reg(4, 32'h55);
        expect_reg(0, 32'h0);

        // 商と余りの格納先をどちらもr3にして7/2を計算する
        `BEGIN_TEST("DIVで商と余りの格納先が同じなら余りが残る");
        run('{movi(1, 32'd7), movi(2, 32'd2), div(1, 2, 3, im(3))});
        // 後から書き込まれる余りが残る
        expect_end();
        expect_reg(3, 32'd1);

        // 符号ありでは負になる0xffffffff・0x80000000を割る
        `BEGIN_TEST("DIVUは符号なしとして割る");
        run('{movi(1, 32'hffff_ffff), movi(2, 32'd2), movi(3, 32'h8000_0000), movi(4, 32'd3),
              divu(1, 2, 5, im(6)), divu(3, 4, 7, im(8))});
        // 符号なし整数としての商と余りになる
        expect_end();
        expect_reg(5, 32'h7fff_ffff);
        expect_reg(6, 32'd1);
        expect_reg(7, 32'h2aaa_aaaa);
        expect_reg(8, 32'd2);

        // 商・余りの格納先に値を入れてから，0(r0)で割る
        `BEGIN_TEST("DIVの0除算は商・余りを書き込まずに停止する");
        run('{movi(1, 32'd7), movi(3, 32'h77), movi(4, 32'h88), div(1, 0, 3, im(4))});
        // DIVの番地で停止し，商・余りの格納先は元の値のまま
        expect_halt(3);
        expect_reg(3, 32'h77);
        expect_reg(4, 32'h88);

        // 商の格納先に値を入れてから，0(r0)で割る
        `BEGIN_TEST("DIVUの0除算は停止する");
        run('{movi(1, 32'd7), movi(3, 32'h77), divu(1, 0, 3, im(4))});
        // DIVUの番地で停止し，商の格納先は元の値のまま
        expect_halt(2);
        expect_reg(3, 32'h77);

        // 符号ありの最小値を-1で割る(商は32ビットで表せない)
        `BEGIN_TEST("DIVで符号ありの最小値を-1で割っても停止しない");
        run('{movi(1, 32'h8000_0000), movi(2, 32'hffff_ffff), div(1, 2, 3, im(4))});
        // 停止せずに正常終了する(結果は仕様上不定のため確かめない)
        expect_end();

        // 17/5の直後に，商と余りの和・差を求める
        `BEGIN_TEST("DIVの直後の命令は商と余りを読める(フォワーディング)");
        run('{movi(1, 32'd17), movi(2, 32'd5), div(1, 2, 3, im(4)), add(3, 4, 5), sub(3, 4, 6)});
        // 直後の命令が商3と余り2を読める
        expect_end();
        expect_reg(5, 32'd5);
        expect_reg(6, 32'd1);

        // 商と余りの格納先をどちらもr3にした17/5の直後に，r3をr4へ写す
        `BEGIN_TEST("DIVの直後の命令は商と余りの格納先が同じなら余りを読む(フォワーディング)");
        run('{movi(1, 32'd17), movi(2, 32'd5), div(1, 2, 3, im(3)), movr(4, 3)});
        // 直後の命令が読む値は，r3に残る余りと一致する
        expect_end();
        expect_reg(4, 32'd2);

        // 6×7の直後に，積を2倍する
        `BEGIN_TEST("MULの直後の命令は積を読める");
        run('{movi(1, 32'd6), movi(2, 32'd7), mul(1, 2, 3), add(3, 3, 4)});
        // 直後の命令が積42を読める
        expect_end();
        expect_reg(4, 32'd84);

        // P系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("P系で未定義のfuncは停止する");
        run('{movi(3, 32'h77), raw(3'h1, 6'h0a, 1, 2, 3, NO_IMM)});
        // その命令の番地で停止し，書き込み先は元の値のまま
        expect_halt(1);
        expect_reg(3, 32'h77);
    endtask

    // シフト系(S系)
    task automatic test_s_type();
        // 最上位・最下位ビットが立った値を，即値で指定した4ビットだけ各命令でシフトする
        `BEGIN_TEST("SLL/SRL/SLA/SRAのシフト量を即値で指定する");
        run('{movi(1, 32'h8000_0001),
              sll(1, 0, 2, im(4)), srl(1, 0, 3, im(4)), sla(1, 0, 4, im(4)), sra(1, 0, 5, im(4))});
        // 左シフトは0で埋め，SRLは上位を0で，SRAは符号ビットで埋める
        expect_end();
        expect_reg(2, 32'h0000_0010);
        expect_reg(3, 32'h0800_0000);
        expect_reg(4, 32'h0000_0010);
        expect_reg(5, 32'hf800_0000);

        // 同じ値を，rs2で指定した4ビットだけ各命令でシフトする
        `BEGIN_TEST("SLL/SRL/SLA/SRAのシフト量をrs2で指定する");
        run('{movi(1, 32'h8000_0001), movi(6, 32'd4),
              sll(1, 6, 2, NO_IMM), srl(1, 6, 3, NO_IMM), sla(1, 6, 4, NO_IMM), sra(1, 6, 5, NO_IMM)});
        // 即値で指定した場合と同じ結果になる
        expect_end();
        expect_reg(2, 32'h0000_0010);
        expect_reg(3, 32'h0800_0000);
        expect_reg(4, 32'h0000_0010);
        expect_reg(5, 32'hf800_0000);

        // 32以上のシフト量を，即値・rs2(直前の命令の結果を含む)で指定して左シフト・論理右シフトする．
        // 32以上を表すビットのうち最下位(32)・最上位(0x8000_0000)だけが立つ値と，下位5ビットが1の33・負の-1を使う
        `BEGIN_TEST("シフト量が32以上なら左シフト・論理右シフトの結果は0になる");
        run('{movi(1, 32'h8000_0001), movi(7, 32'hffff_ffff), movi(6, 32'd33),
              srl(1, 6, 2, NO_IMM), sll(1, 0, 3, im(32)), sla(1, 7, 4, NO_IMM), srl(1, 0, 5, im(32'h8000_0000))});
        // 全ビットがあふれ，空いたビットを埋める0だけが残る
        expect_end();
        expect_reg(2, 32'h0);
        expect_reg(3, 32'h0);
        expect_reg(4, 32'h0);
        expect_reg(5, 32'h0);

        // 負の値と正の値を，32以上のシフト量(即値の32・rs2の33と-1)で算術右シフトする
        `BEGIN_TEST("シフト量が32以上なら算術右シフトの結果は符号ビットで埋まる");
        run('{movi(1, 32'h8000_0001), movi(8, 32'h7fff_ffff), movi(6, 32'd33), movi(7, 32'hffff_ffff),
              sra(1, 0, 2, im(32)), sra(8, 0, 3, im(32)), sra(1, 6, 4, NO_IMM), sra(8, 7, 5, NO_IMM)});
        // 負の値は-1，正の値は0になる
        expect_end();
        expect_reg(2, 32'hffff_ffff);
        expect_reg(3, 32'h0);
        expect_reg(4, 32'hffff_ffff);
        expect_reg(5, 32'h0);

        // 32未満で最大のシフト量31を即値で指定する
        `BEGIN_TEST("シフト量31は32以上として扱わずにシフトする");
        run('{movi(1, 32'h8000_0001), sll(1, 0, 2, im(31)), srl(1, 0, 3, im(31)), sra(1, 0, 4, im(31))});
        expect_end();
        // 左シフト・論理右シフトは，最上位・最下位ビットが反対の端へ移る
        expect_reg(2, 32'h8000_0000);
        expect_reg(3, 32'h0000_0001);
        // 算術右シフトは，最上位ビットが最下位へ移り，空いたビットが符号ビットで埋まる
        expect_reg(4, 32'hffff_ffff);

        // 即値でシフト量1を指定し，無視されるrs2には32以上の33と-1を入れておく
        `BEGIN_TEST("即値でシフト量を指定するとrs2が32以上でも即値だけシフトする");
        run('{movi(1, 32'h8000_0001), movi(6, 32'd33), movi(7, 32'hffff_ffff),
              sll(1, 6, 2, im(1)), sra(1, 7, 3, im(1))});
        // rs2の値によらず1ビットだけシフトされる
        expect_end();
        expect_reg(2, 32'h0000_0002);
        expect_reg(3, 32'hc000_0000);

        // S系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("S系で未定義のfuncは停止する");
        run('{raw(3'h2, 6'h04, 1, 0, 2, im(1))});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // 代入系(A系)
    task automatic test_a_type();
        // 即値をr1へ，r1の値をr2へ代入する
        `BEGIN_TEST("MOVは即値・レジスタの値を代入する");
        run('{movi(1, 32'hdead_beef), movr(2, 1)});
        // どちらにも同じ値が入る
        expect_end();
        expect_reg(1, 32'hdead_beef);
        expect_reg(2, 32'hdead_beef);

        // maskを0と1にして即値を代入する
        `BEGIN_TEST("MOVはmaskによらず全バイトへ書き込む");
        run('{mov(4'h0, 6'h00, 1, im(32'h1234_5678)), mov(4'h1, 6'h00, 2, im(32'h8765_4321))});
        // maskは無視され，全バイトが書き込まれる
        expect_end();
        expect_reg(1, 32'h1234_5678);
        expect_reg(2, 32'h8765_4321);

        // 2番地のMOVでPCをr1へ代入する
        `BEGIN_TEST("MOVでPCを読むとその命令の番地が読める");
        run('{nop(), nop(), movr(1, PC_ADDR)});
        // r1にそのMOV自身の番地が入る
        expect_end();
        expect_reg(1, 32'd2);

        // DIV・RMの直後(先読みされる番地)のMOVでPCをr4・r6へ代入する
        `BEGIN_TEST("先読みされた命令がPCを読むとその命令の番地が読める");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movr(4, PC_ADDR),
              rm(4'hf, 6'h00, 5, im(32'h100)), movr(6, PC_ADDR)});
        // r4・r6にそれぞれのMOV自身の番地が入る
        expect_end();
        expect_reg(4, 32'd3);
        expect_reg(6, 32'd5);

        // DIVの直後のADDで，rs1・rs2のそれぞれにPCを指定してr0(値0)と足す
        `BEGIN_TEST("先読みされた命令がrs1・rs2のどちらでPCを読んでもその命令の番地が読める");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), add(PC_ADDR, 0, 4),
              div(1, 2, 3, NO_IMM), add(0, PC_ADDR, 5)});
        // r4・r5にそれぞれのADD自身の番地が入る
        expect_end();
        expect_reg(4, 32'd3);
        expect_reg(5, 32'd5);

        // 書き込み不可のPCへ即値を代入する
        `BEGIN_TEST("書き込み不可のPCへのMOVは停止する");
        run('{nop(), movi(PC_ADDR, 32'd0)});
        // そのMOVの番地で停止する
        expect_halt(1);

        // 書き込み不可のFLGへ即値を代入する
        `BEGIN_TEST("書き込み不可のFLGへのMOVは停止する");
        run('{movi(FLG_ADDR, 32'd1)});
        // そのMOVの番地で停止する
        expect_halt(0);

        // A系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("A系で未定義のfuncは停止する");
        run('{raw(3'h3, 6'h01, 0, 0, 1, im(1))});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // 分岐系(F系)の1つの比較を確かめるテストケース
    typedef struct {
        string       name;   // 比較方法の名前
        func_t       func;   // 比較方法
        logic [31:0] rs1;    // 比較する値1
        logic [31:0] rs2;    // 比較する値2
        bit          taken;  // 分岐するか
    } branch_case_t;

    // 分岐系(F系)
    task automatic test_f_type();
        // 各比較方法について，成立する値と成立しない値の組．LT/LTUなどは-1と1で符号あり・なしの違いを確かめる
        branch_case_t cases[$] = '{
            '{"EQ",   EQ,   32'd5,        32'd5,        1'b1},
            '{"EQ",   EQ,   32'd5,        32'd6,        1'b0},
            '{"NE",   NE,   32'd5,        32'd6,        1'b1},
            '{"NE",   NE,   32'd5,        32'd5,        1'b0},
            '{"LT",   LT,   32'hffff_ffff, 32'd1,       1'b1},
            '{"LT",   LT,   32'd1,        32'hffff_ffff, 1'b0},
            '{"LT",   LT,   32'd5,        32'd5,        1'b0},
            '{"GT",   GT,   32'd1,        32'hffff_ffff, 1'b1},
            '{"GT",   GT,   32'hffff_ffff, 32'd1,       1'b0},
            '{"GT",   GT,   32'd5,        32'd5,        1'b0},
            '{"ELT",  ELT,  32'd5,        32'd5,        1'b1},
            '{"ELT",  ELT,  32'd6,        32'd5,        1'b0},
            '{"EGT",  EGT,  32'd5,        32'd5,        1'b1},
            '{"EGT",  EGT,  32'd4,        32'd5,        1'b0},
            '{"LTU",  LTU,  32'd1,        32'hffff_ffff, 1'b1},
            '{"LTU",  LTU,  32'hffff_ffff, 32'd1,       1'b0},
            '{"GTU",  GTU,  32'hffff_ffff, 32'd1,       1'b1},
            '{"GTU",  GTU,  32'd1,        32'hffff_ffff, 1'b0},
            '{"ELTU", ELTU, 32'd5,        32'd5,        1'b1},
            '{"ELTU", ELTU, 32'hffff_ffff, 32'd1,       1'b0},
            '{"EGTU", EGTU, 32'd5,        32'd5,        1'b1},
            '{"EGTU", EGTU, 32'd1,        32'hffff_ffff, 1'b0}
        };

        foreach (cases[i]) begin
            // 分岐するかどうかを名前に含めてテストケースを始める
            if (cases[i].taken)
                begin_test($sformatf("%s(0x%08h, 0x%08h)は分岐する", cases[i].name, cases[i].rs1, cases[i].rs2));
            else
                begin_test($sformatf("%s(0x%08h, 0x%08h)は分岐しない", cases[i].name, cases[i].rs1, cases[i].rs2));
            // r1・r2を比較し，成立すれば2つ先の番地へ分岐し，不成立ならr3へ1を代入する命令を通る
            run('{movi(1, cases[i].rs1), movi(2, cases[i].rs2),
                  raw(3'h4, cases[i].func, 1, 2, 0, im(2)), movi(3, 32'd1)});
            // 分岐した場合だけr3が0のまま残る
            expect_end();
            expect_reg(3, cases[i].taken ? 32'd0 : 32'd1);
        end

        // r1が5になるまで，r1に1を足して1つ前の番地へ戻るループを回す
        `BEGIN_TEST("負のオフセットで後方へ分岐してループする");
        run('{movi(3, 32'd1), movi(2, 32'd5), add(1, 3, 1), ne(1, 2, im(-32'sd1))});
        // r1が5になってループを抜ける
        expect_end();
        expect_reg(1, 32'd5);

        // メモリへ書いた5をRMでr1へ読み戻し，直後(先読みされる番地)のEQでr2の5と比較して2つ先へ分岐する
        `BEGIN_TEST("先読みされた分岐は直前のRMで読んだ値を比較し，自身の番地から分岐する");
        run('{movi(2, 32'd5), movi(4, 32'd5), wm(4'hf, 6'h00, 4, im(32'h100)),
              rm(4'hf, 6'h00, 1, im(32'h100)), eq(1, 2, im(2)), movi(3, 32'd1)});
        // 分岐してr3へ代入する命令を飛び越え，r3は0のまま残る
        expect_end();
        expect_reg(3, 32'd0);

        // 分岐先をimmで指定しない分岐を実行する
        `BEGIN_TEST("F系でimm未使用は停止する");
        run('{eq(0, 0, 33'h0_0000_0002)});
        // その命令の番地で停止する
        expect_halt(0);

        // F系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("F系で未定義のfuncは停止する");
        run('{raw(3'h4, 6'h0a, 0, 0, 0, im(2))});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // ジャンプ系(J系)
    task automatic test_j_type();
        // r1へ代入する命令を飛び越えて，即値の番地へジャンプする
        `BEGIN_TEST("JMPは即値の番地へジャンプする");
        run('{jmp(6'h00, im(2)), movi(1, 32'd1)});
        // r1は0のまま残る
        expect_end();
        expect_reg(1, 32'd0);

        // r1へ代入する命令を飛び越えて，r2に入れた番地へジャンプする
        `BEGIN_TEST("JMPはレジスタの番地へジャンプする");
        run('{movi(2, 32'd3), jmp(2, NO_IMM), movi(1, 32'd1)});
        // r1は0のまま残る
        expect_end();
        expect_reg(1, 32'd0);

        // 3番地の関数を呼び，関数の中でSPとスタックの先頭を読んでから戻り，戻った後のSPを読む
        `BEGIN_TEST("CALLは戻り先をスタックへ積み，RETで戻る");
        run('{call(6'h00, im(3)), movr(5, SP_ADDR), jmp(6'h00, im(7)),
              movr(2, SP_ADDR), rmr(4'hf, SP_ADDR, 3, im(0)), movi(1, 32'd1), ret()});
        // 関数の中ではSPが4減って戻り先1を指し，戻るとSPが元に戻る
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'h7ffc);
        expect_reg(3, 32'd1);
        expect_reg(5, 32'h8000);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ffc, 32'd1);

        // r4に入れた番地の関数を呼び，戻った後のSPを読む
        `BEGIN_TEST("CALLはレジスタの番地を呼び出せる");
        run('{movi(4, 32'd4), call(4, NO_IMM), movr(5, SP_ADDR), jmp(6'h00, im(6)),
              movi(1, 32'd1), ret()});
        // 関数が実行され，戻り先2が積まれ，戻るとSPが元に戻る
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(5, 32'h8000);
        expect_mem32(32'h7ffc, 32'd2);

        // DIVで求めた6番地の関数を直後(先読みされる番地)のCALLで呼び，関数の中はRMの直後のRETで戻る
        `BEGIN_TEST("先読みされたCALL・RETもスタックを読み書きして呼び出し・復帰する");
        run('{movi(1, 32'd24), movi(2, 32'd4), div(1, 2, 3, NO_IMM), call(3, NO_IMM), movr(5, SP_ADDR),
              jmp(6'h00, im(8)), rm(4'hf, 6'h00, 7, im(32'h100)), ret()});
        // 戻り先4が積まれ，戻るとSPが元に戻る
        expect_end();
        expect_reg(5, 32'h8000);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ffc, 32'd4);

        // r1を1ずつ減らしながら自分自身を呼び出し，r2に呼び出した段数，r4に戻った段数を数える
        `BEGIN_TEST("12段にネストした関数呼び出しからすべて戻る");
        run('{movi(3, 32'd1), movi(1, 32'd12), call(6'h00, im(4)), jmp(6'h00, im(10)),
              eq(1, 0, im(5)), sub(1, 3, 1), add(2, 3, 2), call(6'h00, im(4)), add(4, 3, 4), ret()});
        // 12段呼び出して12段戻り，SPが元に戻る．スタックには最初の呼び出しの戻り先3と，
        // 最も深い呼び出し(13回目)の戻り先8が積まれている
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd12);
        expect_reg(4, 32'd12);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ffc, 32'd3);
        expect_mem32(32'h8000 - 13 * 4, 32'd8);

        // 次の番地(1番地)を関数として呼び，呼んだ先の命令でSPを読む
        `BEGIN_TEST("次の番地を呼ぶCALLの直後の命令は下げた後のSPを読む");
        run('{call(6'h00, im(1)), movr(1, SP_ADDR)});
        // 戻り先を積んで4減ったSPが読める
        expect_end();
        expect_reg(1, 32'h7ffc);

        // 何も積んでいないスタックでRETする(戻り先を読む番地がメモリの後半の先頭になる)
        `BEGIN_TEST("空のスタックでのRETは停止する");
        run('{nop(), ret()});
        // RETの番地で停止し，SPは元のまま
        expect_halt(1);
        expect_reg(SP_ADDR, 32'h8000);

        // SPを0x8004にしてから関数を呼ぶ(戻り先の積み先がメモリの後半の先頭になる)
        `BEGIN_TEST("スタックの積み先がメモリの後半に入るCALLは書き込まずに停止する");
        run('{movi(SP_ADDR, 32'h8004), call(6'h00, im(0))});
        // CALLの番地で停止し，SPもメモリの後半も書き換わらない
        expect_halt(1);
        expect_reg(SP_ADDR, 32'h8004);
        expect_mem32(32'h8000, 32'd0);

        // SPを0x8000のまま，SPからの相対位置でメモリの後半の先頭を読み書きする
        `BEGIN_TEST("SPからの相対位置でメモリの後半を読み書きするRMR/WMRは停止しない");
        run('{movi(1, 32'h1234_5678), wmr(4'hf, SP_ADDR, 1, im(0)), rmr(4'hf, SP_ADDR, 2, im(0))});
        // 正常終了し，メモリの後半の先頭が読み書きされる
        expect_end();
        expect_mem32(32'h8000, 32'h1234_5678);
        expect_reg(2, 32'h1234_5678);

        // SPを0にしてから関数を呼ぶ(戻り先の積み先が0-4になる)
        `BEGIN_TEST("スタックの積み先がメモリの範囲外になるCALLは書き込まずに停止する");
        run('{movi(SP_ADDR, 32'd0), call(6'h00, im(0))});
        // CALLの番地で停止し，SPもメモリも書き換わらない
        expect_halt(1);
        expect_reg(SP_ADDR, 32'd0);
        expect_mem32(32'hfffc, 32'd0);

        // ROMの命令数を超える100番地へジャンプする
        `BEGIN_TEST("ROMの命令数の範囲外へのジャンプは停止する");
        run('{jmp(6'h00, im(100))});
        // ジャンプ先の番地で停止する
        expect_halt(100);

        // ROMへ渡せるビット幅を超える0x10000番地へジャンプする
        `BEGIN_TEST("ROMのビット幅を超える番地へのジャンプは停止する");
        run('{jmp(6'h00, im(32'h1_0000))});
        // ジャンプ先の番地で停止する
        expect_halt(32'h1_0000);

        // J系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("J系で未定義のfuncは停止する");
        run('{raw(3'h5, 6'h05, 0, 0, 0, im(1))});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // メモリ系(M系)
    task automatic test_m_type();
        // 同じ値を即値の番地0x100とr2の番地0x104へ書き込み，それぞれから読み出す
        `BEGIN_TEST("WM/RMは即値・レジスタの番地を読み書きする");
        run('{movi(1, 32'h1122_3344), movi(2, 32'h104),
              wm(4'hf, 6'h00, 1, im(32'h100)), wm(4'hf, 2, 1, NO_IMM),
              rm(4'hf, 6'h00, 3, im(32'h100)), rm(4'hf, 2, 4, NO_IMM)});
        // 下位バイトから小さい番地に書き込まれ，読み出すと同じ値になる
        expect_end();
        expect_mem32(32'h100, 32'h1122_3344);
        expect_mem32(32'h104, 32'h1122_3344);
        expect_reg(3, 32'h1122_3344);
        expect_reg(4, 32'h1122_3344);

        // 0x100番地から書いた4バイトを，1・2バイトのmaskと4の倍数でない番地で読み出す
        `BEGIN_TEST("RMはmaskのバイトだけを読み，それ以外のバイトを0にする");
        run('{movi(1, 32'h1122_3344), wm(4'hf, 6'h00, 1, im(32'h100)),
              rm(4'b0001, 6'h00, 2, im(32'h101)), rm(4'b0011, 6'h00, 3, im(32'h102)),
              rm(4'b0110, 6'h00, 4, im(32'h100))});
        // maskのビットiが番地+iのバイトをレジスタのiバイト目へ読み，それ以外のバイトは0になる
        expect_end();
        expect_reg(2, 32'h0000_0033);
        expect_reg(3, 32'h0000_1122);
        expect_reg(4, 32'h0022_3300);

        // 0x100番地から書いた4バイトの一部を，maskを絞ったWMで上書きする
        `BEGIN_TEST("WMはmaskのバイトだけを書き込み，それ以外の番地を保持する");
        run('{movi(1, 32'h1122_3344), wm(4'hf, 6'h00, 1, im(32'h100)),
              movi(2, 32'haabb_ccdd), wm(4'b0010, 6'h00, 2, im(32'h100)),
              movi(3, 32'h0000_00ee), wm(4'b0001, 6'h00, 3, im(32'h103))});
        // maskのバイトだけが書き換わり，それ以外は元の値のまま
        expect_end();
        expect_mem32(32'h100, 32'hee22_cc44);

        // r1(0x200)から-4・+8離れた番地をRMR/WMRで読み書きする
        `BEGIN_TEST("RMR/WMRはrs1にimmを足した番地を読み書きする");
        run('{movi(1, 32'h200), movi(2, 32'h5566_7788), movi(3, 32'h99aa_bbcc),
              wmr(4'hf, 1, 2, im(-32'sd4)), wmr(4'hf, 1, 3, im(32'd8)),
              rmr(4'hf, 1, 4, im(-32'sd4)), rmr(4'hf, 1, 5, im(32'd8))});
        // 0x1fc番地と0x208番地が読み書きされる
        expect_end();
        expect_mem32(32'h1fc, 32'h5566_7788);
        expect_mem32(32'h208, 32'h99aa_bbcc);
        expect_reg(4, 32'h5566_7788);
        expect_reg(5, 32'h99aa_bbcc);

        // 0xffffffffに0x101を足した番地(桁あふれを捨てると0x100)をRMR/WMRで読み書きする
        `BEGIN_TEST("RMR/WMRの番地の足し算は32ビットで桁あふれを捨てる");
        run('{movi(1, 32'hffff_ffff), movi(2, 32'h1234_5678),
              wmr(4'hf, 1, 2, im(32'h101)), rmr(4'hf, 1, 3, im(32'h101))});
        // 0x100番地が読み書きされる
        expect_end();
        expect_mem32(32'h100, 32'h1234_5678);
        expect_reg(3, 32'h1234_5678);

        // メモリから21を読み出した直後に，その値を2倍する
        `BEGIN_TEST("RMの直後の命令は読んだ値を使える(フォワーディング)");
        run('{movi(1, 32'd21), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, 2, im(32'h100)), add(2, 2, 3)});
        // 直後の命令が読んだ値21を使える
        expect_end();
        expect_reg(3, 32'd42);

        // メモリへ書き込んだ直後に，書き込んだデータのレジスタを2倍する
        `BEGIN_TEST("WMの直後の命令はレジスタを正しく読める");
        run('{movi(1, 32'd21), wm(4'hf, 6'h00, 1, im(32'h100)), add(1, 1, 3)});
        // 直後の命令がレジスタの値21を読める
        expect_end();
        expect_reg(3, 32'd42);

        // メモリの範囲外の0x10000番地へ書き込む
        `BEGIN_TEST("メモリの範囲外へのWMは書き込まずに停止する");
        run('{movi(1, 32'hdead_beef), wm(4'hf, 6'h00, 1, im(32'h1_0000))});
        // WMの番地で停止し，折り返した先の0番地も書き換わらない
        expect_halt(1);
        expect_mem32(32'h0, 32'h0);

        // メモリの範囲外の0x10000番地から読み出す
        `BEGIN_TEST("メモリの範囲外からのRMは停止する");
        run('{movi(2, 32'h77), rm(4'hf, 6'h00, 2, im(32'h1_0000))});
        // RMの番地で停止し，書き込み先は元の値のまま
        expect_halt(1);
        expect_reg(2, 32'h77);

        // 0xfffcに4を足した範囲外の番地へWMRで書き込む
        `BEGIN_TEST("足した番地がメモリの範囲外になるWMRは書き込まずに停止する");
        run('{movi(1, 32'hfffc), movi(2, 32'hdead_beef), wmr(4'hf, 1, 2, im(32'd4))});
        // WMRの番地で停止し，折り返した先の0番地も書き換わらない
        expect_halt(2);
        expect_mem32(32'h0, 32'h0);

        // 0xfffcに4を足した範囲外の番地からRMRで読み出す
        `BEGIN_TEST("足した番地がメモリの範囲外になるRMRは停止する");
        run('{movi(1, 32'hfffc), movi(2, 32'h77), rmr(4'hf, 1, 2, im(32'd4))});
        // RMRの番地で停止し，書き込み先は元の値のまま
        expect_halt(2);
        expect_reg(2, 32'h77);

        // 未実装のBRMを実行する
        `BEGIN_TEST("BRMは停止する");
        run('{brm(4'hf, 0, 0, 1, im(0))});
        // その命令の番地で停止する
        expect_halt(0);

        // 未実装のBWMを実行する
        `BEGIN_TEST("BWMは停止する");
        run('{bwm(4'hf, 0, 0, 1, im(0))});
        // その命令の番地で停止する
        expect_halt(0);

        // 番地に足す値をimmで指定しないRMRを実行する
        `BEGIN_TEST("RMRでimm未使用は停止する");
        run('{rmr(4'hf, 0, 1, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(0);

        // 番地に足す値をimmで指定しないWMRを実行する
        `BEGIN_TEST("WMRでimm未使用は停止する");
        run('{wmr(4'hf, 0, 1, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(0);

        // 0x103番地から2バイト(4バイト境界をまたぐ)を読み書きする
        `BEGIN_TEST("ワード境界をまたぐmaskは停止しない");
        run('{movi(1, 32'h1122_3344), wm(4'b0011, 6'h00, 1, im(32'h103)), rm(4'b0011, 6'h00, 2, im(32'h103))});
        // 停止せずに正常終了する(読み書きされる番地は仕様上誤った番地のため確かめない)
        expect_end();

        // M系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("M系で未定義のfuncは停止する");
        run('{raw(3'h6, 6'h06, 0, 0, 1, im(0))});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // どの命令タイプにも割り当てていない命令コード
    task automatic test_undefined_type();
        // 命令コード3'h7の命令を実行する
        `BEGIN_TEST("どの命令タイプにも割り当てていない命令コードは停止する");
        run('{raw(3'h7, 6'h00, 0, 0, 0, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // 仕様で定めた読み書きの可否に基づき，その番地のレジスタをカーネルモードで命令のオペランドとして読めるかを返す
    function automatic bit spec_readable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h12], [6'h1c:6'h21], 6'h26, 6'h2a, 6'h31: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 仕様で定めた読み書きの可否に基づき，その番地のレジスタをカーネルモードで命令のオペランドとして書けるかを返す
    function automatic bit spec_writable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h12], 6'h1d, 6'h1e, [6'h22:6'h28], 6'h2a, [6'h2d:6'h31]: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 仕様で定めた読み書きの可否に基づき，その番地のレジスタがユーザーモードでも読み書きの対象にできるかを返す．
    // できる番地の読み書きの可否は，カーネルモードと同じになる
    function automatic bit spec_user_accessible(input addr_t addr);
        case (addr) inside
            KENTRY_ADDR, KRET_ADDR, [6'h20:6'h3f]: return 1'b0;
            default: return 1'b1;
        endcase
    endfunction

    // ユーザーモードへ移ってから命令列を実行するための前置き．カーネルモードからの戻り先を前置きの直後(2番地)にして復帰する
    function automatic machine_queue_t enter_user_mode();
        return '{movi(KRET_ADDR, 32'd2), sysret()};
    endfunction

    // 全番地のレジスタの，カーネルモード・ユーザーモードそれぞれでの読み書き可否
    task automatic test_register_access();
        for (int addr = 0; addr <= REGISTER_MAX_ADDR; addr++) begin
            bit             user_readable;  // ユーザーモードで読み出せるか
            bit             user_writable;  // ユーザーモードで書き込めるか
            machine_queue_t body;           // ユーザーモードへ移る前置きを含めた命令列
            user_readable = spec_readable(addr) && spec_user_accessible(addr);
            user_writable = spec_writable(addr) && spec_user_accessible(addr);

            // 読み出せるかどうかを名前に含めてテストケースを始める
            if (spec_readable(addr))
                begin_test($sformatf("レジスタ0x%02hはカーネルモードで読み出せる", addr));
            else
                begin_test($sformatf("レジスタ0x%02hをカーネルモードで読み出すと停止する", addr));
            // その番地のレジスタをMOVでr2へ読み出す
            run('{movi(1, 32'h77), movr(2, addr)});
            // 読み出せるなら正常終了し，読み出せないならMOVの番地で停止してr2は書き換わらない
            if (spec_readable(addr)) begin
                expect_end();
            end
            else begin
                expect_halt(1);
                expect_reg(2, 32'h0);
            end

            // 書き込めるかどうかを名前に含めてテストケースを始める
            if (spec_writable(addr))
                begin_test($sformatf("レジスタ0x%02hへカーネルモードで書き込める", addr));
            else
                begin_test($sformatf("レジスタ0x%02hへカーネルモードで書き込むと停止する", addr));
            // その番地のレジスタへMOVで0を書き込む
            run('{nop(), movi(addr, 32'h0)});
            // 書き込めるなら正常終了し，書き込めないならMOVの番地で停止する
            if (spec_writable(addr))
                expect_end();
            else
                expect_halt(1);

            // ユーザーモードで読み出せるかどうかを名前に含めてテストケースを始める
            if (user_readable)
                begin_test($sformatf("レジスタ0x%02hはユーザーモードで読み出せる", addr));
            else
                begin_test($sformatf("レジスタ0x%02hをユーザーモードで読み出すと停止する", addr));
            // ユーザーモードへ移ってから，その番地のレジスタをMOVでr2へ読み出す
            body = {enter_user_mode(), movi(1, 32'h77), movr(2, addr)};
            run(body);
            // 読み出せるならユーザーモードのまま正常終了し，読み出せないならMOVの番地で停止してr2は書き換わらない
            if (user_readable) begin
                expect_end();
                expect_kernel_mode(1'b0);
            end
            else begin
                expect_halt(3);
                expect_reg(2, 32'h0);
            end

            // ユーザーモードで書き込めるかどうかを名前に含めてテストケースを始める
            if (user_writable)
                begin_test($sformatf("レジスタ0x%02hへユーザーモードで書き込める", addr));
            else
                begin_test($sformatf("レジスタ0x%02hへユーザーモードで書き込むと停止する", addr));
            // ユーザーモードへ移ってから，その番地のレジスタへMOVで0を書き込む
            body = {enter_user_mode(), nop(), movi(addr, 32'h0)};
            run(body);
            // 書き込めるならユーザーモードのまま正常終了し，書き込めないならMOVの番地で停止する
            if (user_writable) begin
                expect_end();
                expect_kernel_mode(1'b0);
            end
            else begin
                expect_halt(3);
            end
        end
    endtask

    // 1つの命令が停止するかどうかを確かめるテストケース
    typedef struct {
        string    name;         // テストケースの名前
        machine_t instruction;  // 確かめる命令
        bit       halts;        // 停止するか
    } operand_case_t;

    // 命令の種類ごとに，実際に使うオペランドだけが読み書き可否の判定対象になるか
    task automatic test_operand_checks();
        // 読み込み不可の番地として0x1b，書き込み不可の番地としてPCを，使うオペランド・使わないオペランドに入れた命令
        operand_case_t cases[$] = '{
            '{$sformatf("即値を使うMOVはrs1が読み込み不可でも停止しない"),       mov(4'hf, 6'h1b, 1, im(5)),                   1'b0},
            '{$sformatf("即値でシフト量を指定するとrs2が読み込み不可でも停止しない"), sll(1, 6'h1b, 3, im(1)),                  1'b0},
            '{$sformatf("NOTはrs2が読み込み不可でも停止しない"),                   raw(3'h1, NOT, 1, 6'h1b, 3, NO_IMM),          1'b0},
            '{$sformatf("imm未使用のDIVは余りの格納先が書き込み不可でも停止しない"), div(1, 2, 3, {1'b0, 26'h0, PC_ADDR}),       1'b0},
            '{$sformatf("即値の番地へのJMPはrs1が読み込み不可でも停止しない"),     jmp(6'h1b, im(2)),                            1'b0},
            '{$sformatf("即値の番地のRMはrs1が読み込み不可でも停止しない"),       rm(4'hf, 6'h1b, 3, im(32'h100)),              1'b0},
            '{$sformatf("WMは使わないrdが書き込み不可でも停止しない"),             raw(3'h6, WM, 0, 2, PC_ADDR, im(32'h100)),    1'b0},
            '{$sformatf("rs2でシフト量を指定するとrs2が読み込み不可なら停止する"), sll(1, 6'h1b, 3, NO_IMM),                   1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先が書き込み不可なら停止する"),   div(1, 2, 3, im(PC_ADDR)),                    1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先が番地の上限を超えると停止する"), div(1, 2, 3, im(REGISTER_MAX_ADDR + 1)),       1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先の上位ビットが立つと停止する"),  div(1, 2, 3, im(32'h41)),                     1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先の最上位ビットが立つと停止する"), div(1, 2, 3, im(32'h8000_0001)),              1'b1},
            '{$sformatf("レジスタの番地へのJMPはrs1が読み込み不可なら停止する"),   jmp(6'h1b, NO_IMM),                           1'b1},
            '{$sformatf("レジスタの番地へのCALLはrs1が読み込み不可なら停止する"),  call(6'h1b, NO_IMM),                          1'b1},
            '{$sformatf("分岐はrs1が読み込み不可なら停止する"),                   eq(6'h1b, 0, im(1)),                          1'b1},
            '{$sformatf("RMは書き込み先が書き込み不可なら停止する"),               rm(4'hf, 6'h00, PC_ADDR, im(32'h100)),        1'b1},
            '{$sformatf("WMは書き込むデータのrs2が読み込み不可なら停止する"),     wm(4'hf, 6'h00, 6'h1b, im(32'h100)),          1'b1},
            '{$sformatf("RMRは番地の基準のrs1が読み込み不可なら停止する"),       rmr(4'hf, 6'h1b, 3, im(0)),                   1'b1},
            '{$sformatf("WMRは書き込むデータのrs2が読み込み不可なら停止する"),   wmr(4'hf, 2, 6'h1b, im(0)),                   1'b1}
        };

        foreach (cases[i]) begin
            // 命令ごとの名前でテストケースを始める
            begin_test(cases[i].name);
            // 割り算の除数に使うr2へ1を入れてから，確かめる命令を実行する
            run('{movi(2, 32'd1), cases[i].instruction});
            // 停止するなら確かめる命令の番地で停止し，停止しないなら正常終了する
            if (cases[i].halts)
                expect_halt(1);
            else
                expect_end();
        end

        // immを扱わないADDで，imm[32](即値使用フラグの位置)を1にして3+4を計算する
        `BEGIN_TEST("ADDはimm[32]が1でもrs1とrs2を足す");
        run('{movi(1, 32'd3), movi(2, 32'd4), raw(3'h1, ADD, 1, 2, 3, im(32'd100))});
        // 即値は無視され，rs1とrs2の和になる
        expect_end();
        expect_reg(3, 32'd7);
    endtask

    // 動作状態(カーネルモード・ユーザーモード)と，それを切り替えるシステムコール・その復帰
    task automatic test_mode();
        machine_queue_t body;      // ユーザーモードへ移る前置きを含めた命令列
        operand_case_t  cases[$];  // ユーザーモードで停止するかを命令ごとに確かめるテストケース

        // r1・r2へ0以外を入れてから，書き込む前の入口と戻り先を読み出す
        `BEGIN_TEST("リセット直後の入口と戻り先は0である");
        run('{movi(1, 32'h77), movi(2, 32'h77), movr(1, KENTRY_ADDR), movr(2, KRET_ADDR)});
        // どちらも0が読める
        expect_end();
        expect_reg(1, 32'h0);
        expect_reg(2, 32'h0);

        // 入口と戻り先へ値を書き込んでから読み出す
        `BEGIN_TEST("リセット直後はカーネルモードで，入口と戻り先を読み書きできる");
        run('{movi(KENTRY_ADDR, 32'h1234), movi(KRET_ADDR, 32'h5678), movr(1, KENTRY_ADDR), movr(2, KRET_ADDR)});
        // 書き込んだ値が読め，カーネルモードのまま終わる
        expect_end();
        expect_reg(1, 32'h1234);
        expect_reg(2, 32'h5678);
        expect_kernel_mode(1'b1);

        // ユーザーモードへ移ってから，もう一度復帰する．停止を検出した次のクロックの動作状態も見る
        `BEGIN_TEST("ユーザーモードでのSYSRETは停止し，停止するとカーネルモードに戻る");
        run('{movi(KRET_ADDR, 32'd2), sysret(), sysret()});
        // 2つ目の復帰の番地で停止する
        expect_halt(2);
        // 停止を検出した次のクロックで，レジスタの初期化とともにカーネルモードに戻る
        @(posedge clk);
        #1;
        if (dut.alu_sv_0.kernel_mode !== 1'b1) begin
            fail($sformatf("停止した後の動作状態がカーネルモードではない"));
        end

        // 戻り先を3番地にして復帰する
        `BEGIN_TEST("SYSRETは戻り先の番地へユーザーモードで飛ぶ");
        run('{movi(KRET_ADDR, 32'd3), sysret(), movi(1, 32'd1), movi(2, 32'd2)});
        // 2番地の代入を飛び越えて3番地から実行し，ユーザーモードで終わる
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd2);
        expect_kernel_mode(1'b0);

        // 入口を5番地にしてユーザーモードへ移り，3番地でシステムコールを呼ぶ
        `BEGIN_TEST("SYSCALLは次の命令の番地を戻り先へ保存し，入口へカーネルモードで飛ぶ");
        run('{movi(KENTRY_ADDR, 32'd5), movi(KRET_ADDR, 32'd3), sysret(), syscall(), movi(1, 32'd1), movr(2, KRET_ADDR)});
        // 4番地の代入を飛び越えて入口から実行し，戻り先には4番地が入り，カーネルモードで終わる
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd4);
        expect_kernel_mode(1'b1);

        // ユーザーモードの3番地でシステムコールを呼び，入口(6番地)でr2へ代入してから復帰する
        `BEGIN_TEST("SYSCALLの入口からSYSRETで戻ると，呼び出しの次の命令から実行する");
        run('{movi(KENTRY_ADDR, 32'd6), movi(KRET_ADDR, 32'd3), sysret(), syscall(), movi(1, 32'd1), jmp(6'h00, im(8)),
              movi(2, 32'd2), sysret()});
        // 入口の代入と，戻った4番地の代入がどちらも実行され，ユーザーモードで終わる
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd2);
        expect_kernel_mode(1'b0);

        // カーネルモードのまま，入口を3番地にしてシステムコールを呼ぶ
        `BEGIN_TEST("カーネルモードでもSYSCALLは戻り先を保存して入口へ飛ぶ");
        run('{movi(KENTRY_ADDR, 32'd3), syscall(), movi(1, 32'd1), movr(2, KRET_ADDR)});
        // 2番地の代入を飛び越え，戻り先には2番地が入り，カーネルモードで終わる
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd2);
        expect_kernel_mode(1'b1);

        // ユーザーモードのシステムコールの直後に，ユーザーモードでは読めないタクトスイッチを読む命令を置く
        `BEGIN_TEST("ユーザーモードのSYSCALLの直後の命令は，ユーザーモードで読めないレジスタを読んでも停止しない");
        run('{movi(KENTRY_ADDR, 32'd5), movi(KRET_ADDR, 32'd3), sysret(), syscall(), movr(1, BTN_ADDR)});
        // 直後の命令は実行されず，入口(正常終了を表す命令)へ進む
        expect_end();
        expect_reg(1, 32'd0);
        expect_kernel_mode(1'b1);

        // 戻り先へ範囲外の9番地を書き込んだ後，1本目のパイプラインで5番地へ書き換えてすぐに復帰する
        `BEGIN_TEST("直前に1本目で書き込んだ戻り先へSYSRETで飛ぶ");
        run('{movi(KRET_ADDR, 32'd9), movi(1, 32'd1), movi(KRET_ADDR, 32'd5), sysret(), movi(2, 32'd2)});
        // 書き換えた後の5番地へ飛び，4番地の代入は実行されない
        expect_end();
        expect_reg(2, 32'd0);
        expect_kernel_mode(1'b0);

        // 戻り先へ範囲外の9番地を書き込んだ後，NOPを先頭とする同時実行の2番目で5番地へ書き換えてすぐに復帰する
        `BEGIN_TEST("直前に2本目で書き込んだ戻り先へSYSRETで飛ぶ");
        run('{movi(KRET_ADDR, 32'd9), nop(), movi(KRET_ADDR, 32'd5), sysret(), movi(2, 32'd2)});
        // 書き換えた後の5番地へ飛び，4番地の代入は実行されない
        expect_end();
        expect_reg(2, 32'd0);
        expect_kernel_mode(1'b0);

        // 入口へ範囲外の9番地を書き込んだ後，1本目のパイプラインで5番地へ書き換えてすぐにシステムコールを呼ぶ
        `BEGIN_TEST("直前に1本目で書き込んだ入口へSYSCALLで飛ぶ");
        run('{movi(KENTRY_ADDR, 32'd9), movi(1, 32'd1), movi(KENTRY_ADDR, 32'd5), syscall(), movi(2, 32'd2)});
        // 書き換えた後の5番地へ飛び，4番地の代入は実行されない
        expect_end();
        expect_reg(2, 32'd0);

        // 入口へ範囲外の9番地を書き込んだ後，NOPを先頭とする同時実行の2番目で5番地へ書き換えてすぐにシステムコールを呼ぶ
        `BEGIN_TEST("直前に2本目で書き込んだ入口へSYSCALLで飛ぶ");
        run('{movi(KENTRY_ADDR, 32'd9), nop(), movi(KENTRY_ADDR, 32'd5), syscall(), movi(2, 32'd2)});
        // 書き換えた後の5番地へ飛び，4番地の代入は実行されない
        expect_end();
        expect_reg(2, 32'd0);

        // 入口を5番地にし，NOPを先頭とする同時実行の2番目で戻り先へ書き込んだ直後に，システムコールを呼ぶ
        `BEGIN_TEST("同時実行の2番目が戻り先へ書き込んだ直後のSYSCALLは，保存した戻り先を残す");
        run('{movi(KENTRY_ADDR, 32'd5), nop(), movi(KRET_ADDR, 32'h99), syscall(), movi(2, 32'd2), movr(1, KRET_ADDR)});
        // 入口で読む戻り先は，システムコールの次の4番地になる
        expect_end();
        expect_reg(1, 32'd4);
        expect_reg(2, 32'd0);

        // メモリへ5を書き込み，そこから戻り先へ読み込んだ直後に復帰する
        `BEGIN_TEST("直前にメモリから読み込んだ戻り先へSYSRETで飛ぶ");
        run('{movi(1, 32'd5), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, KRET_ADDR, im(32'h100)), sysret(), movi(2, 32'd2)});
        // 読み込んだ5番地へ飛び，4番地の代入は実行されない
        expect_end();
        expect_reg(2, 32'd0);
        expect_kernel_mode(1'b0);

        // ユーザーモードで，余りの格納先をLEDにした割り算を実行する
        `BEGIN_TEST("ユーザーモードで読み書きできないレジスタを余りの格納先にした割り算は停止する");
        body = {enter_user_mode(), movi(1, 32'd6), movi(2, 32'd4), div(1, 2, 3, im(LED_ADDR))};
        run(body);
        // 割り算の番地で停止する
        expect_halt(4);

        // メモリの後半の先頭へ復帰し，そこでr1へ代入してからシステムコールを呼ぶ．入口(3番地)で戻り先を読む
        `BEGIN_TEST("メモリの後半へSYSRETで移り，そこからSYSCALLでROMの入口へ戻る");
        code_area = '{movi(1, 32'd1), syscall(), movi(3, 32'd3)};
        run('{movi(KENTRY_ADDR, 32'd3), movi(KRET_ADDR, CODE_AREA_PC), sysret(), movr(2, KRET_ADDR)});
        // メモリの後半の代入が実行され，システムコールの次の代入は実行されない．
        // 戻り先にはシステムコールの次の番地が入り，カーネルモードで終わる
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, CODE_AREA_PC + 2);
        expect_reg(3, 32'd0);
        expect_kernel_mode(1'b1);

        // ユーザーモードで読み書きできないレジスタをオペランドに入れた命令を，命令の種類ごとに実行する．
        // そのオペランドを命令が使う場合は停止し，即値を使うために無視する場合は停止しない
        cases = '{
            '{$sformatf("ユーザーモードでrs2が読めないADDは停止する"),                              add(1, SW_ADDR, 3),                     1'b1},
            '{$sformatf("ユーザーモードのシフトは，シフト量を指定するrs2が読めないと停止する"),     sll(1, SW_ADDR, 3, NO_IMM),             1'b1},
            '{$sformatf("ユーザーモードのシフトは，シフト量が即値ならrs2が読めなくても停止しない"), sll(1, SW_ADDR, 3, im(1)),              1'b0},
            '{$sformatf("ユーザーモードでrs1が読めない分岐は停止する"),                             eq(BTN_ADDR, 0, im(1)),                 1'b1},
            '{$sformatf("ユーザーモードでrs1が読めないレジスタの番地へのJMPは停止する"),            jmp(KENTRY_ADDR, NO_IMM),               1'b1},
            '{$sformatf("ユーザーモードで即値の番地へのJMPは，rs1が読めなくても停止しない"),        jmp(KENTRY_ADDR, im(4)),                1'b0},
            '{$sformatf("ユーザーモードでrs1が読めないレジスタの番地へのCALLは停止する"),           call(KENTRY_ADDR, NO_IMM),              1'b1},
            '{$sformatf("ユーザーモードで書き込み先が書けないRMは停止する"),                        rm(4'hf, 6'h00, LED_ADDR, im(32'h100)), 1'b1},
            '{$sformatf("ユーザーモードで書き込むデータのrs2が読めないWMは停止する"),               wm(4'hf, 6'h00, BTN_ADDR, im(32'h100)), 1'b1},
            '{$sformatf("ユーザーモードで番地のrs1が読めないWMは停止する"),                         wm(4'hf, SW_ADDR, 1, NO_IMM),           1'b1},
            '{$sformatf("ユーザーモードで番地の基準のrs1が読めないRMRは停止する"),                  rmr(4'hf, KENTRY_ADDR, 3, im(0)),       1'b1},
            '{$sformatf("ユーザーモードで書き込むデータのrs2が読めないWMRは停止する"),              wmr(4'hf, 2, KRET_ADDR, im(0)),         1'b1}
        };

        foreach (cases[i]) begin
            // 命令ごとの名前でテストケースを始める
            begin_test(cases[i].name);
            // ユーザーモードへ移り，r2へ1を入れてから，確かめる命令を実行する
            body = {enter_user_mode(), movi(2, 32'd1), cases[i].instruction};
            run(body);
            // 停止するなら確かめる命令の番地で停止し，停止しないなら正常終了する
            if (cases[i].halts) begin
                expect_halt(3);
            end
            else begin
                expect_end();
            end
        end
    endtask

    // ボード上の入出力ピンにつながるレジスタ
    task automatic test_pins();
        // 出力用の各レジスタへ値を書き込む
        `BEGIN_TEST("出力用のレジスタへの書き込みが対応するピンに出る");
        run('{movi(LED_ADDR, 32'h5), movi(RGB_LED_ADDR, 32'h2a), movi(PMOD_A_ADDR, 32'ha5), movi(PMOD_B_ADDR, 32'h5a),
              movi(AR0_7_ADDR, 32'h81), movi(AR8_13_ADDR, 32'b101010), movi(AR_MISC_ADDR, 32'b101),
              movi(SPI_ADDR, 32'b0110), movi(GPIO1_ADDR, 32'h81), movi(GPIO2_ADDR, 32'h42), movi(GPIO3_ADDR, 32'h5)});
        // 正常終了する
        expect_end();
        // LED・RGB LED・Pmodへ書いた値がそのままピンに出る
        if (led !== 4'h5)
            fail($sformatf("LED: 期待値0x5，実際0x%h", led));
        if (rgb_led !== 6'h2a)
            fail($sformatf("RGB LED: 期待値0x2a，実際0x%h", rgb_led));
        if (ja !== 8'ha5 || jb !== 8'h5a)
            fail($sformatf("Pmod A・B: 期待値0xa5・0x5a，実際0x%h・0x%h", ja, jb));
        // AR0〜AR7へ書いた値がそのまま出る
        if (ar !== 8'h81)
            fail($sformatf("AR0〜AR7: 期待値0x81，実際0x%h", ar));
        // AR8〜AR13へ書いた値が，ビットごとに対応するEthernetモジュールのピンに出る
        if ({eth_sck, eth_mosi, eth_csn, eth_rstn} !== 4'b1101)
            fail($sformatf("Ethernetモジュール(SCK,MOSI,CSn,RSTn): 期待値1101，実際%b", {eth_sck, eth_mosi, eth_csn, eth_rstn}));
        // Arduinoの単体ピン・I2C・SPIへ書いた値が，ビットごとに対応するピンに出る
        if ({a, ar_sda, ar_scl} !== 3'b101)
            fail($sformatf("A・AR_SDA・AR_SCL: 期待値101，実際%b", {a, ar_sda, ar_scl}));
        if ({ck_sck, ck_mosi, ck_ss} !== 3'b110)
            fail($sformatf("SPI(SCK,MOSI,SS): 期待値110，実際%b", {ck_sck, ck_mosi, ck_ss}));
        // GPIOの3つのレジスタへ書いた値が，GPIO番号の順に並んで出る
        if (gpio !== 19'h54281)
            fail($sformatf("GPIO8〜GPIO26: 期待値0x54281，実際0x%h", gpio));

        // 出力用の各レジスタとGPIO0へ，全ビットが1の値を書き込む
        `BEGIN_TEST("出力用のレジスタは使うビットだけが書き込んだ値になり，使わないビットは0になる");
        run('{movi(LED_ADDR, '1), movi(RGB_LED_ADDR, '1), movi(PMOD_A_ADDR, '1), movi(PMOD_B_ADDR, '1),
              movi(AR0_7_ADDR, '1), movi(AR8_13_ADDR, '1), movi(AR_MISC_ADDR, '1),
              movi(GPIO0_ADDR, '1), movi(GPIO1_ADDR, '1), movi(GPIO2_ADDR, '1), movi(GPIO3_ADDR, '1)});
        // 仕様で使うとされたビットだけが1で残る．どのピンにも出ないGPIO0は全ビット0になる．
        // AR8〜AR13のINTn・MISOのビットは，書き込んだ値ではなくピンの0になる
        expect_end();
        expect_reg(LED_ADDR,     32'hf);
        expect_reg(RGB_LED_ADDR, 32'h3f);
        expect_reg(PMOD_A_ADDR,  32'hff);
        expect_reg(PMOD_B_ADDR,  32'hff);
        expect_reg(AR0_7_ADDR,   32'hff);
        expect_reg(AR8_13_ADDR,  32'h2e);
        expect_reg(AR_MISC_ADDR, 32'h7);
        expect_reg(GPIO0_ADDR,   32'h0);
        expect_reg(GPIO1_ADDR,   32'hff);
        expect_reg(GPIO2_ADDR,   32'hff);
        expect_reg(GPIO3_ADDR,   32'h7);

        // タクトスイッチ・DIPスイッチを押した状態で，それぞれのレジスタを読み出す
        `BEGIN_TEST("タクトスイッチ・DIPスイッチの状態を読める");
        btn = 4'b1010;
        sw  = 2'b01;
        run('{movr(1, BTN_ADDR), movr(2, SW_ADDR)});
        // 後のテストケースへ影響しないよう，スイッチを離した状態へ戻す
        btn = 4'b0;
        sw  = 2'b0;
        // 押したスイッチのビットが1で読める
        expect_end();
        expect_reg(1, 32'b1010);
        expect_reg(2, 32'b01);

        // MISOピンを1にした状態で，SPIのレジスタを読み出す
        `BEGIN_TEST("MISOピンの値がSPIのレジスタのビット3に読める");
        ck_miso = 1'b1;
        run('{movr(1, SPI_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // ビット3がMISOの1，ビット0がSSの初期値1になる
        expect_end();
        expect_reg(1, 32'b1001);

        // MISOピンを0にした状態で，ビット3を1にした値をSPIのレジスタへ書き込んでから読み出す
        `BEGIN_TEST("SPIのレジスタへの書き込みではMISOのビットが変わらない");
        run('{movi(SPI_ADDR, 32'b1001), movr(1, SPI_ADDR)});
        // ビット3は書き込んだ1ではなくMISOの0になり，ほかのビットは書き込んだ値になる
        expect_end();
        expect_reg(1, 32'b0001);

        // MISOピンを1にした状態で，SPIのレジスタへ書き込んだ直後と2つ後の命令で読み出す
        `BEGIN_TEST("SPIのレジスタへMOVで書き込んだ直後と2つ後の命令もMISOの値を読める");
        ck_miso = 1'b1;
        run('{movi(SPI_ADDR, 32'b0110), movr(1, SPI_ADDR), movr(2, SPI_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // どちらもビット3がMISOの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(1, 32'b1110);
        expect_reg(2, 32'b1110);

        // MISOピンを1にした状態で，SPIのレジスタへ書き込んだ直後の命令で，第2オペランドとして読み出す
        `BEGIN_TEST("SPIのレジスタへ書き込んだ直後の命令が第2オペランドで読んでもMISOの値を読める");
        ck_miso = 1'b1;
        run('{movi(SPI_ADDR, 32'b0110), or_(0, SPI_ADDR, 1)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // ビット3がMISOの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(1, 32'b1110);

        // MISOピンを1にした状態で，メモリから読んだ値をRMでSPIのレジスタへ書き込み，直後の命令で読み出す
        `BEGIN_TEST("SPIのレジスタへRMで書き込んだ直後の命令もMISOの値を読める");
        ck_miso = 1'b1;
        run('{movi(1, 32'b0100), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, SPI_ADDR, im(32'h100)), movr(2, SPI_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // ビット3がMISOの1，ほかのビットがメモリから読んだ値になる
        expect_end();
        expect_reg(2, 32'b1100);

        // MISOピンを0にした状態で，上位ビットを立てた値をMOVでSPIのレジスタへ書き込み，直後と2つ後の命令で読み出す
        `BEGIN_TEST("SPIのレジスタへMOVで書き込んでも上位28ビットは0で読める");
        run('{movi(SPI_ADDR, 32'hffff_fff6), movr(1, SPI_ADDR), movr(2, SPI_ADDR)});
        // どちらも上位28ビットが0，ビット3がMISOの0，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(1, 32'b0110);
        expect_reg(2, 32'b0110);

        // MISOピンを0にした状態で，上位ビットを立てた値をRMでSPIのレジスタへ書き込み，直後の命令で読み出す
        `BEGIN_TEST("SPIのレジスタへRMで書き込んでも上位28ビットは0で読める");
        run('{movi(1, 32'hffff_fff6), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, SPI_ADDR, im(32'h100)), movr(2, SPI_ADDR)});
        // 上位28ビットが0，ビット3がMISOの0，ほかのビットがメモリから読んだ値になる
        expect_end();
        expect_reg(2, 32'b0110);

        // MISOピンを0にした状態で，全ビットが1の余り(-10÷-9の余り-1)をSPIのレジスタへ書き込み，直後の命令で読み出す
        `BEGIN_TEST("SPIのレジスタへ割り算の余りを書き込んでも上位28ビットは0で読める");
        run('{movi(1, 32'hffff_fff6), movi(2, 32'hffff_fff7), div(1, 2, 3, im(SPI_ADDR)), movr(4, SPI_ADDR)});
        // 上位28ビットが0，ビット3がMISOの0，ほかのビットが余りの1になる
        expect_end();
        expect_reg(4, 32'b0111);

        // INTnピンだけを1にした状態と，MISOピンだけを1にした状態で，AR8〜AR13のレジスタを読み出す
        `BEGIN_TEST("INTn・MISOピンの値がそれぞれAR8〜AR13のレジスタのビット0・4に読める");
        eth_intn = 1'b1;
        run('{movr(1, AR8_13_ADDR)});
        // 次の読み出しへ影響しないよう，INTnピンを0へ戻す
        eth_intn = 1'b0;
        // ビット0だけがピンの1になり，ビット1・2はRSTn・CSnの初期値1になる
        expect_end();
        expect_reg(1, 32'b000111);
        // MISOピンだけを1にした状態で，AR8〜AR13のレジスタを読み出す
        eth_miso = 1'b1;
        run('{movr(1, AR8_13_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        eth_miso = 1'b0;
        // ビット4だけがピンの1になり，ビット1・2はRSTn・CSnの初期値1になる
        expect_end();
        expect_reg(1, 32'b010110);

        // INTn・MISOピンを1にした状態で，上位ビットとビット0・4以外を立てた値をAR8〜AR13のレジスタへ書き込み，
        // 直後の命令で第1オペランドとして，2つ後の命令で第2オペランドとして読み出す
        `BEGIN_TEST("AR8〜AR13のレジスタへ書き込んだ直後と2つ後の命令もINTn・MISOの値を読み，上位26ビットは0で読める");
        eth_intn = 1'b1;
        eth_miso = 1'b1;
        run('{movi(AR8_13_ADDR, 32'hffff_ffea), movr(1, AR8_13_ADDR), or_(0, AR8_13_ADDR, 2)});
        // 後のテストケースへ影響しないよう，INTn・MISOピンを0へ戻す
        eth_intn = 1'b0;
        eth_miso = 1'b0;
        // どちらも上位26ビットが0，ビット0・4がピンの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(1, 32'b111011);
        expect_reg(2, 32'b111011);
    endtask

    // 命令の種類によらない停止の条件と，停止後の挙動
    task automatic test_common();
        // 使わないフィールド(NOPのrs1)にレジスタ番地の上限を超える値を入れる
        `BEGIN_TEST("使わないフィールドでもレジスタ番地の上限を超えると停止する");
        run('{nop(), raw(3'h0, NOP, REGISTER_MAX_ADDR + 1, 0, 0, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(1);

        // 複数サイクルかかるDIVの直後に，未定義のfuncの命令を置く．DIVの実行中にその命令を先読みし，
        // 実行できないと判定する経路を通る
        `BEGIN_TEST("先読みした命令が実行できない場合もその番地で停止する");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), raw(3'h1, 6'h0a, 1, 2, 4, NO_IMM)});
        // 先読みした命令の番地で停止し，DIVの商は書き込まれ，停止した命令の書き込み先は書き換わらない
        expect_halt(3);
        expect_reg(3, 32'd2);
        expect_reg(4, 32'd0);

        // 0除算で停止するDIVの後に，r3への代入を置く
        `BEGIN_TEST("実行中に停止した命令の後の命令は実行されない");
        run('{movi(1, 32'd7), div(1, 0, 2, NO_IMM), movi(3, 32'd1)});
        // DIVの番地で停止し，後の命令の書き込み先は書き換わらない
        expect_halt(1);
        expect_reg(3, 32'd0);

        // 正常終了を表す命令を付けずに，2つの命令だけを実行する
        `BEGIN_TEST("ROMの最後の命令の次へ進むと停止する");
        run('{nop(), nop()}, 1'b0);
        // ROMの範囲外の番地で停止する
        expect_halt(2);

        // 正常終了を表す命令を付けずに，最後に複数サイクルかかるWMを実行する．WMの実行中に
        // ROMの範囲外の番地を先読みする経路を通る
        `BEGIN_TEST("複数サイクルかかる最後の命令の次へ進むと停止する");
        run('{movi(1, 32'h1), wm(4'hf, 6'h00, 1, im(32'h100))}, 1'b0);
        // ROMの範囲外の番地で停止し，最後のWMは実行されている
        expect_halt(2);
        expect_mem32(32'h100, 32'h1);

        // r1・SPを書き換え，NOPをはさんでから，書き込み不可のPCへの書き込みで停止させる．
        // NOPは，r1への代入と同時実行したSPへの代入の結果を，停止する前にレジスタへ書き込ませるために置く
        `BEGIN_TEST("停止するとレジスタが初期値へ戻り，リセットまで停止が続く");
        run('{movi(1, 32'd5), movi(SP_ADDR, 32'h100), nop(), movi(PC_ADDR, 32'd0)});
        // 停止した番地と，停止した時点のr1・SPの値を確かめる
        expect_halt(3);
        expect_reg(1, 32'd5);
        expect_reg(SP_ADDR, 32'h100);
        // 次のクロックまで進めてから，レジスタの値を写し取る
        @(posedge clk);
        #1;
        take_snapshot();
        // r1・SP・PCが初期値へ戻っている
        expect_reg(1, 32'd0);
        expect_reg(SP_ADDR, 32'h8000);
        expect_reg(PC_ADDR, 32'd0);
        // リセットを入れていないので，停止したまま
        if (dut.alu_sv_0.is_halted !== 1'b1)
            fail($sformatf("リセットを入れる前に停止が解除された"));

        // メモリの値を1増やしてから停止する命令列を実行する
        `BEGIN_TEST("停止後のリセットでメモリを保持したまま先頭から実行し直す");
        run('{movi(3, 32'd1), rm(4'hf, 6'h00, 1, im(32'h100)), add(1, 3, 1),
              wm(4'hf, 6'h00, 1, im(32'h100)), movi(PC_ADDR, 32'd0)});
        // 停止し，メモリの値が1になっている
        expect_halt(4);
        expect_mem32(32'h100, 32'd1);
        // 同じ命令列を，メモリを消さずにもう一度実行する
        run('{movi(3, 32'd1), rm(4'hf, 6'h00, 1, im(32'h100)), add(1, 3, 1),
              wm(4'hf, 6'h00, 1, im(32'h100)), movi(PC_ADDR, 32'd0)}, 1'b1, 1'b1);
        // 先頭から実行し直して再び停止し，前の実行で書いた1にさらに1が足されている
        expect_halt(4);
        expect_mem32(32'h100, 32'd2);
    endtask

    // メインメモリの後半に置いた命令の実行
    task automatic test_code_area();
        machine_queue_t body;  // ROMへ書き込む命令列

        // メモリの後半の0番目にr1への代入を，1番目にRETを，ROM上の命令がWMで書き込んでからCALLで呼び，戻った後のSPを読む
        `BEGIN_TEST("WMでメモリの後半へ書いた命令をCALLで実行し，RETで戻る");
        body = {store_code(0, movi(1, 32'h1234)), store_code(1, ret())};
        body.push_back(call(6'h00, im(CODE_AREA_PC)));
        body.push_back(movr(5, SP_ADDR));
        run(body);
        // コード領域の命令が実行され，CALLの次の番地へ戻り，SPが元に戻る
        expect_end();
        expect_reg(1, 32'h1234);
        expect_reg(5, 32'h8000);
        expect_mem32(32'h7ffc, body.size() - 1);

        // コード領域の命令で，メモリを即値の番地・レジスタ相対の番地で読み書きし，読んだ値どうしをレジスタで足す
        `BEGIN_TEST("コード領域の命令はメモリを読み書きでき，即値を使う命令も使わない命令も実行できる");
        code_area = '{movi(1, 32'h1122_3344), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, 2, im(32'h100)),
                      movi(3, 32'h200), wmr(4'hf, 3, 1, im(32'd4)), rmr(4'hf, 3, 4, im(32'd4)), add(2, 4, 5), ret()};
        run('{call(6'h00, im(CODE_AREA_PC))});
        // 書いた値が読め，複数サイクルかかる読み込みの直後の命令も読んだ値を使える
        expect_end();
        expect_mem32(32'h100, 32'h1122_3344);
        expect_mem32(32'h204, 32'h1122_3344);
        expect_reg(2, 32'h1122_3344);
        expect_reg(4, 32'h1122_3344);
        expect_reg(5, 32'h2244_6688);

        // コード領域の中で，r1が5になるまで1つ前の番地へ戻るループを回し，その後r4への代入をJMPで飛び越える
        `BEGIN_TEST("コード領域の中でF系の分岐とJMPが働く");
        code_area = '{movi(3, 32'd1), movi(2, 32'd5), add(1, 3, 1), ne(1, 2, im(-32'sd1)),
                      jmp(6'h00, im(CODE_AREA_PC + 6)), movi(4, 32'd1), ret()};
        run('{call(6'h00, im(CODE_AREA_PC))});
        // ループを抜けた時点でr1が5になり，r4は0のまま残る
        expect_end();
        expect_reg(1, 32'd5);
        expect_reg(4, 32'd0);

        // コード領域の1番目のMOVと，複数サイクルかかるRMの直後の3番目のMOVでPCを読む
        `BEGIN_TEST("コード領域の命令がPCを読むとその命令のPCが読める");
        code_area = '{nop(), movr(1, PC_ADDR), rm(4'hf, 6'h00, 2, im(32'h100)), movr(3, PC_ADDR), ret()};
        run('{call(6'h00, im(CODE_AREA_PC))});
        // それぞれのMOV自身のPCが入る
        expect_end();
        expect_reg(1, CODE_AREA_PC + 1);
        expect_reg(3, CODE_AREA_PC + 3);

        // コード領域の0番目から，コード領域の3番目の関数を呼び，その中でSPを読む
        `BEGIN_TEST("コード領域の命令からコード領域の関数をCALLできる");
        code_area = '{call(6'h00, im(CODE_AREA_PC + 3)), movi(2, 32'd2), ret(),
                      movi(1, 32'd1), movr(3, SP_ADDR), ret()};
        run('{call(6'h00, im(CODE_AREA_PC))});
        // 2段の呼び出しからそれぞれの呼び出し元へ戻り，スタックには2つの戻り先が積まれている
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd2);
        expect_reg(3, 32'h7ff8);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ffc, 32'd1);
        expect_mem32(32'h7ff8, CODE_AREA_PC + 1);

        // コード領域の関数から，ROMの2番目の関数を呼ぶ
        `BEGIN_TEST("コード領域の命令からROMの関数をCALLし，RETでコード領域へ戻る");
        code_area = '{call(6'h00, im(32'd2)), movi(2, 32'd2), ret()};
        run('{call(6'h00, im(CODE_AREA_PC)), jmp(6'h00, im(32'd4)), movi(1, 32'd1), ret()});
        // ROMの関数を実行してコード領域へ戻り，さらにROMへ戻る
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd2);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ff8, CODE_AREA_PC + 1);

        // ROMの最後の番地に1サイクルで終わる命令を置き，そこへジャンプする
        `BEGIN_TEST("ROMの最後の番地の命令の次はメモリの後半の先頭へ進む");
        rom_tail = '{movi(1, 32'd1)};
        code_area = '{movi(2, 32'd2), jmp(6'h00, im(32'd1))};
        run('{jmp(6'h00, im(CODE_AREA_PC - 1))});
        // ROMの最後の命令とメモリの後半の先頭の命令が順に実行される
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd2);

        // ROMの最後の番地に複数サイクルかかるRMを置き，そこへジャンプする．RMの実行中に次の番地を先読みしない経路を通る
        `BEGIN_TEST("複数サイクルかかるROMの最後の命令の次もメモリの後半の先頭へ進む");
        rom_tail = '{rm(4'hf, 6'h00, 1, im(32'h100))};
        code_area = '{add(1, 1, 2), jmp(6'h00, im(32'd3))};
        run('{movi(3, 32'h55), wm(4'hf, 6'h00, 3, im(32'h100)), jmp(6'h00, im(CODE_AREA_PC - 1))});
        // RMで読んだ値をメモリの後半の先頭の命令が使える
        expect_end();
        expect_reg(2, 32'haa);

        // ROMの最後の3番地にDIVと2つの代入を置き，そこへジャンプする．DIVの実行中に後の2命令を取得し終え，
        // 命令キューに命令を残したままROMの範囲を出る
        `BEGIN_TEST("命令キューに命令を残したままROMの範囲を出てもメモリの後半の先頭へ進む");
        rom_tail = '{div(1, 2, 3, NO_IMM), movi(4, 32'd4), movi(5, 32'd5)};
        code_area = '{add(4, 5, 6), jmp(6'h00, im(32'd3))};
        run('{movi(1, 32'd9), movi(2, 32'd4), jmp(6'h00, im(CODE_AREA_PC - 3))});
        // ROMの最後の3命令がすべて実行されてから，メモリの後半の先頭の命令が実行される
        expect_end();
        expect_reg(3, 32'd2);
        expect_reg(6, 32'd9);

        // メモリの後半の最後の位置に1サイクルで終わる命令を置き，そこへジャンプする
        `BEGIN_TEST("メモリの後半の最後の命令の次へ進むと停止する");
        code_area_index = rom_p::CODE_AREA_PC_NUM - 1;
        code_area = '{movi(1, 32'd1)};
        run('{jmp(6'h00, im(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM - 1))});
        // 最後の命令は実行され，その次の番地で停止する
        expect_halt(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM);
        expect_reg(1, 32'd1);

        // メモリの後半の最後の位置に複数サイクルかかるWMを置き，そこへジャンプする
        `BEGIN_TEST("複数サイクルかかるメモリの後半の最後の命令の次へ進むと停止する");
        code_area_index = rom_p::CODE_AREA_PC_NUM - 1;
        code_area = '{wm(4'hf, 6'h00, 1, im(32'h100))};
        run('{movi(1, 32'd7), jmp(6'h00, im(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM - 1))});
        // 最後のWMは実行され，その次の番地で停止する
        expect_halt(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM);
        expect_mem32(32'h100, 32'd7);

        // メモリの後半の1番目にN系で未定義のfuncを持つ命令を置き，メモリの後半の先頭へジャンプする
        `BEGIN_TEST("コード領域の実行できない命令はそのPCで停止する");
        code_area = '{nop(), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM)};
        run('{jmp(6'h00, im(CODE_AREA_PC))});
        // その命令のPCで停止する
        expect_halt(CODE_AREA_PC + 1);

        // コード領域の0〜3番目の命令で，直後の4番目(初めはNOP)をr1への代入に書き換えてから実行する
        `BEGIN_TEST("コード領域の命令が直後の命令を書き換えると書き換えた命令が実行される");
        code_area = {store_code(4, movi(1, 32'h55)), nop(), ret()};
        run('{call(6'h00, im(CODE_AREA_PC))});
        // 書き換えた後の代入が実行される
        expect_end();
        expect_reg(1, 32'h55);
    endtask

    // 命令を重ねて実行するパイプラインの所要サイクル数と，直前の命令の結果の受け取り
    task automatic test_pipeline();
        int             base;  // 比べる基準とする実行の所要サイクル数
        machine_queue_t body;  // ROMへ書き込む命令列

        // r1への代入だけの命令列と，その後に依存関係のない単純な演算を10個並べた命令列を実行する
        `BEGIN_TEST("依存関係のない単純な演算は2命令ずつ同時に実行される");
        run('{movi(1, 32'd1)});
        base = cycles;
        run('{movi(1, 32'd1), movi(2, 32'd2), add(0, 0, 3), sll(0, 0, 4, im(1)), movi(5, 32'd5), or_(0, 0, 6),
              movi(7, 32'd7), xor_(0, 0, 8), movi(9, 32'd9), not_(0, 10), movi(11, 32'd11)});
        // 並べた10命令ぶんの半分のサイクル数だけ多くかかる
        expect_end();
        expect_reg(10, 32'hffff_ffff);
        expect_reg(11, 32'd11);
        expect_cycles(base + 5);

        // r1への代入だけの命令列と，その後に直前の結果を2倍するADDを10個並べた命令列を実行する
        `BEGIN_TEST("直前の1サイクル命令の結果を使う命令も1命令1サイクルで実行される");
        run('{movi(1, 32'd1)});
        base = cycles;
        body = '{movi(1, 32'd1)};
        repeat (10) body.push_back(add(1, 1, 1));
        run(body);
        // 1を10回2倍した値になり，並べた10命令ぶんのサイクル数だけ多くかかる
        expect_end();
        expect_reg(1, 32'd1024);
        expect_cycles(base + 10);

        // r1へ代入し，1つ命令を挟んでからr1を2倍する
        `BEGIN_TEST("2つ前の命令の結果を読める");
        run('{movi(1, 32'd7), nop(), add(1, 1, 2)});
        // 代入した値の2倍になる
        expect_end();
        expect_reg(2, 32'd14);

        // ADDで作った値を，直後のWMの書き込むデータ・RMRの番地の基準に使う
        `BEGIN_TEST("1サイクル命令の結果を直後のWM・RMRが使える");
        run('{movi(1, 32'd5), add(1, 1, 2), wm(4'hf, 6'h00, 2, im(32'h100)),
              movi(3, 32'h80), add(3, 3, 4), rmr(4'hf, 4, 5, im(32'd0))});
        // 0x100番地へ10が書かれ，それを読み戻せる
        expect_end();
        expect_mem32(32'h100, 32'd10);
        expect_reg(5, 32'd10);

        // ADDで作った値を，直後のSLLのシフト量と，直後の分岐のrs1・rs2に使う
        `BEGIN_TEST("1サイクル命令の結果を直後の命令がシフト量・分岐の比較に使える");
        run('{movi(1, 32'd5), movi(6, 32'd1), add(6, 6, 7), sll(1, 7, 8, NO_IMM),
              movi(10, 32'd10), add(1, 1, 9), eq(9, 10, im(2)), movi(11, 32'd1),
              add(1, 1, 12), eq(10, 12, im(2)), movi(13, 32'd1)});
        // 5を2ビットシフトした20になり，どちらの分岐も成立して代入を飛び越える
        expect_end();
        expect_reg(8, 32'd20);
        expect_reg(11, 32'd0);
        expect_reg(13, 32'd0);

        // ADDで作った4番地へ直後のJMPで飛び，ADDで作った8番地の関数を直後のCALLで呼ぶ
        `BEGIN_TEST("1サイクル命令の結果を直後のJMP・CALLが飛び先に使える");
        run('{movi(1, 32'd2), add(1, 1, 3), jmp(3, NO_IMM), movi(2, 32'd1),
              movi(5, 32'd4), add(5, 5, 6), call(6, NO_IMM), jmp(6'h00, im(10)),
              movi(7, 32'd1), ret()});
        // JMPはr2への代入を飛び越え，CALLは関数を実行して戻り先7を積む
        expect_end();
        expect_reg(2, 32'd0);
        expect_reg(7, 32'd1);
        expect_reg(SP_ADDR, 32'h8000);
        expect_mem32(32'h7ffc, 32'd7);

        // 実行に数十サイクルかかるDIVだけの命令列と，その後に単純な演算を5個並べた命令列を実行する
        `BEGIN_TEST("長く待つ命令の後も単純な演算は2命令ずつ同時に実行される");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM)});
        base = cycles;
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM),
              movi(4, 32'd4), movi(5, 32'd5), movi(6, 32'd6), movi(7, 32'd7), movi(8, 32'd8)});
        // 1つ目の代入はDIVと同時に実行され，残りの4命令ぶんの半分のサイクル数だけ多くかかる
        expect_end();
        expect_reg(8, 32'd8);
        expect_cycles(base + 2);

        // r1への代入だけの命令列と，その後に成立しない分岐を3個並べた命令列を実行する
        `BEGIN_TEST("成立しない分岐は1サイクルで実行される");
        run('{movi(1, 32'd1)});
        base = cycles;
        run('{movi(1, 32'd1), ne(0, 0, im(5)), ne(0, 0, im(5)), ne(0, 0, im(5))});
        // 並べた3命令ぶんのサイクル数だけ多くかかる
        expect_end();
        expect_cycles(base + 3);

        // r1への代入だけの命令列と，その後に次の番地へ分岐する成立する分岐を3個並べた命令列を実行する
        `BEGIN_TEST("成立する分岐は飛び先から取得し直すため4サイクルかかる");
        run('{movi(1, 32'd1)});
        base = cycles;
        run('{movi(1, 32'd1), eq(0, 0, im(1)), eq(0, 0, im(1)), eq(0, 0, im(1))});
        // 3命令ぶんの4倍のサイクル数だけ多くかかる
        expect_end();
        expect_cycles(base + 12);

        // r1への代入だけの命令列と，その後に次の番地への即値のJMPを3個並べた命令列を実行する
        `BEGIN_TEST("即値のJMPは届いた時点で飛び先から取得するため2サイクルで実行される");
        run('{movi(1, 32'd1)});
        base = cycles;
        run('{movi(1, 32'd1), jmp(6'h00, im(2)), jmp(6'h00, im(3)), jmp(6'h00, im(4))});
        // 3命令ぶんの2倍のサイクル数から1を引いたサイクル数だけ多くかかる．
        // 1を引くのは，基準の命令列では正常終了を表す命令が代入と同じ組で届き，代入を実行段へ渡すまで1サイクル待つため
        expect_end();
        expect_cycles(base + 5);

        // 即値のJMPと飛び越える代入を組の偶数番地・奇数番地に置いた命令列と，その2命令の代わりにNOPを2つ置いた命令列を実行する
        `BEGIN_TEST("組の偶数番地の即値のJMPで飛び越える奇数番地の命令は実行されず，読み飛ばしで飛び先の実行は遅れない");
        run('{nop(), nop(), movi(2, 32'd1)});
        base = cycles;
        run('{jmp(6'h00, im(2)), movi(1, 32'd1), movi(2, 32'd1)});
        // 奇数番地の代入は実行されず，飛び先の代入は実行される．
        // 奇数番地の代入を読み飛ばすサイクルは飛び先が届くのを待つ間に重なるため，NOPを2つ並べた場合より
        // 多くかかるのは，そちらで2つ目のNOPと飛び先の代入を同時に実行して減る1サイクルぶんだけになる
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd1);
        expect_cycles(base + 1);

        // 代入と即値のJMPを組の偶数番地・奇数番地に置き，JMPで次の組の偶数番地の代入を飛び越える
        `BEGIN_TEST("組の奇数番地の即値のJMPは，同じ組の偶数番地の命令を実行してから飛び先へ進み，1サイクルで実行される");
        run('{movi(1, 32'd1), nop(), movi(3, 32'd1)});
        base = cycles;
        run('{movi(1, 32'd1), jmp(6'h00, im(3)), movi(2, 32'd1), movi(3, 32'd1)});
        // 偶数番地の代入と飛び先の代入は実行され，飛び越えた代入は実行されない．
        // 偶数番地の代入を実行している間に飛び先が届くため，JMPの代わりにNOPを1つ置いた場合より多くかかるのは，
        // そちらでNOPと次の代入を同時に実行して減る1サイクルぶんだけになる
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd0);
        expect_reg(3, 32'd1);
        expect_cycles(base + 1);

        // 奇数番地へ飛ぶ即値のJMPを置き，飛び先の直前(同じ組の偶数番地)には，飛び先の次の代入を飛び越える即値のJMPを置く
        `BEGIN_TEST("飛び先が奇数番地なら，同じ組の偶数番地の命令は実行も先行取得もされない");
        run('{jmp(6'h00, im(3)), movi(1, 32'd1), jmp(6'h00, im(5)), movi(2, 32'd1), movi(3, 32'd1), movi(4, 32'd1)});
        // 飛び先から順に実行され，偶数番地のJMPの飛び先へは進まない
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd1);
        expect_reg(3, 32'd1);
        expect_reg(4, 32'd1);

        // 偶数番地へ飛ぶ即値のJMPと，奇数番地へ飛ぶ即値のJMPで，飛び先から同じ命令を同じ数だけ実行する
        `BEGIN_TEST("飛び先が奇数番地で最初に1命令しか届かなくても，偶数番地へ飛ぶ場合と同じサイクル数で終わる");
        run('{jmp(6'h00, im(2)), nop(), movi(1, 32'd1), movi(2, 32'd1), movi(3, 32'd1)});
        base = cycles;
        run('{jmp(6'h00, im(3)), nop(), nop(), movi(1, 32'd1), movi(2, 32'd1), movi(3, 32'd1)});
        // どちらも飛び先の3つの代入を実行する．
        // 奇数番地へ飛ぶ場合は最初に1命令しか届かないが，その1命令を実行する間に次の組が届くため，サイクル数は変わらない
        expect_end();
        expect_reg(3, 32'd1);
        expect_cycles(base);

        // 組の偶数番地に即値のCALLを，奇数番地(CALLの戻り先)に別の番地への即値のJMPを置く
        `BEGIN_TEST("組の2命令とも即値のジャンプなら偶数番地の飛び先へ進み，戻った後に奇数番地のジャンプを実行する");
        run('{call(6'h00, im(3)), jmp(6'h00, im(5)), movi(1, 32'd1), movi(2, 32'd1), ret(), movi(3, 32'd1)});
        // 呼んだ関数の代入を実行してから戻り先のJMPで飛び，飛び越えた代入は実行されない
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd1);
        expect_reg(3, 32'd1);

        // DIVで実行段が止まっている間に，偶数番地の即値のJMPと奇数番地のWMの組が届く
        `BEGIN_TEST("命令キューに命令が溜まっている間に読み飛ばした奇数番地のWMは実行されない");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movi(4, 32'd1),
              jmp(6'h00, im(6)), wm(4'hf, 6'h00, 1, im(32'h100)), movi(5, 32'd1)});
        // 商が求まり，JMPの手前と飛び先の代入は実行され，WMはメモリへ書き込まない
        expect_end();
        expect_reg(3, 32'd2);
        expect_reg(4, 32'd1);
        expect_reg(5, 32'd1);
        expect_mem32(32'h100, 32'd0);

        // r1への代入だけの命令列と，その後にr1が指す次の番地へのJMPを置いた命令列を実行する
        `BEGIN_TEST("レジスタの番地へのJMPは実行段で取得し直すため4サイクルかかる");
        run('{movi(1, 32'd2)});
        base = cycles;
        run('{movi(1, 32'd2), jmp(1, NO_IMM)});
        // 1命令ぶんの4倍のサイクル数だけ多くかかる
        expect_end();
        expect_cycles(base + 4);

        // 同じ番地の関数を，即値のCALLとレジスタの番地へのCALLでそれぞれ呼ぶ
        `BEGIN_TEST("即値のCALLはレジスタの番地へのCALLより3サイクル早く終わる");
        run('{movi(1, 32'd2), call(1, NO_IMM)});
        base = cycles;
        run('{movi(1, 32'd2), call(6'h00, im(2))});
        // 呼び出しが正しく行われる．即値のCALLはスタックへの書き込みを待つ間に飛び先を取得し終え，
        // 完了の次のサイクルに飛び先を実行できる．レジスタの番地へのCALLは完了後に4サイクルかかるため，3サイクル早い
        expect_end();
        expect_reg(SP_ADDR, 32'h7ffc);
        expect_mem32(32'h7ffc, 32'd2);
        expect_cycles(base - 3);

        // 呼んだ関数の先頭ですぐにRETで戻る
        `BEGIN_TEST("即値のCALLの飛び先の先頭がRETでも復帰する");
        run('{call(6'h00, im(3)), movi(1, 32'd1), jmp(6'h00, im(4)), ret()});
        // 戻り先の代入が実行され，SPが元に戻る
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(SP_ADDR, 32'h8000);

        // 呼んだ関数の先頭でCALLを，その関数の先頭でSPを読み，RETを2回続けて戻る
        `BEGIN_TEST("即値のCALLの飛び先の先頭がCALLでも呼び出し・復帰する");
        run('{call(6'h00, im(3)), movi(1, 32'd1), jmp(6'h00, im(7)),
              call(6'h00, im(5)), ret(), movr(2, SP_ADDR), ret()});
        // 2段呼び出した中でSPが8減っており，2段戻ってSPが元に戻る
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'h7ff8);
        expect_reg(SP_ADDR, 32'h8000);

        // 呼んだ関数の先頭で，SPからの相対位置のRMRで積まれた戻り先を読む
        `BEGIN_TEST("即値のCALLの飛び先の先頭のRMRは下げた後のSPから戻り先を読む");
        run('{call(6'h00, im(3)), movi(1, 32'd1), jmp(6'h00, im(5)), rmr(4'hf, SP_ADDR, 2, im(0)), ret()});
        // 戻り先1が読め，戻った後の代入も実行される
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd1);

        // r1を3から1ずつ減らし，0になったら抜けるループを，末尾の後方への即値のJMPで先頭の判定へ戻して回す
        `BEGIN_TEST("後方への即値のJMPで戻るループを繰り返してから抜ける");
        run('{movi(1, 32'd3), movi(3, 32'd1), eq(1, 0, im(4)), sub(1, 3, 1), add(2, 3, 2), jmp(6'h00, im(2))});
        // 3回繰り返して抜ける
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd3);

        // 即値のJMPの飛び先に，別の即値のJMPを置く
        `BEGIN_TEST("即値のJMPの飛び先が即値のJMPでも，飛び越えた命令は実行されない");
        run('{jmp(6'h00, im(2)), movi(1, 32'd1), jmp(6'h00, im(4)), movi(2, 32'd1), movi(3, 32'd1)});
        // 2つの代入を飛び越え，最後の代入だけが実行される
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd0);
        expect_reg(3, 32'd1);

        // DIVの実行中に命令キューが満杯になり，その後に届く即値のJMPで代入を飛び越える
        `BEGIN_TEST("命令キューが満杯の間に届いた即値のJMPも飛び先へ進む");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movi(4, 32'd1), movi(5, 32'd1),
              jmp(6'h00, im(8)), movi(6, 32'd1), movi(7, 32'd1), movi(8, 32'd1)});
        // 商が求まり，JMPの手前までと飛び先の代入だけが実行される
        expect_end();
        expect_reg(3, 32'd2);
        expect_reg(5, 32'd1);
        expect_reg(6, 32'd0);
        expect_reg(7, 32'd0);
        expect_reg(8, 32'd1);

        // 成立する分岐の直後に，分岐先の代入を飛び越える即値のJMPを置く
        // (分岐とJMPが同じ組で届き，分岐が実行段で完了する前にJMPの飛び先を取得し始める)
        `BEGIN_TEST("成立した分岐で飛び越えた即値のJMPの飛び先へは進まない");
        run('{eq(0, 0, im(2)), jmp(6'h00, im(3)), movi(1, 32'd1), movi(2, 32'd1)});
        // 分岐先の代入から順に実行される
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd1);

        // 関数から戻るRETの直後に，戻り先の代入を飛び越える即値のJMPを置く
        `BEGIN_TEST("RETで飛び越えた即値のJMPの飛び先へは進まない");
        run('{call(6'h00, im(4)), movi(1, 32'd1), movi(2, 32'd1), jmp(6'h00, im(7)),
              ret(), jmp(6'h00, im(2)), movi(3, 32'd1)});
        // 戻り先の代入から順に実行され，RETの後のJMPの飛び先は実行されない
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd1);
        expect_reg(3, 32'd0);

        // 2つのNOPに続けて成立する分岐を置き，その2つ後(次の組の偶数番地)に，分岐先の代入を飛び越える即値のJMPを置く．
        // 命令キューに命令が溜まって組の取得が2サイクルに1回になるため，分岐の実行段と同じサイクルにJMPが届く
        `BEGIN_TEST("成立した分岐の実行と同じサイクルに届いた即値のJMPの飛び先へは進まない");
        run('{nop(), nop(), eq(0, 0, im(3)), nop(), jmp(6'h00, im(6)), movi(1, 32'd1), movi(2, 32'd1)});
        // 分岐先の代入から順に実行される
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd1);
        // 命令の配置が意図どおり，分岐の実行と同じサイクルにJMPを届かせている(命令キューの深さなどが変わると届く時機がずれるため確かめる)
        if (!redirect_met_early_jump)
            fail("分岐で取得し直すサイクルに即値のJMPが届いていません");

        // 即値のJMPの直後に，WM・MOVを置き，JMPでそれを飛び越える
        `BEGIN_TEST("即値のJMPで飛び越えたWM・MOVは実行されない");
        run('{movi(1, 32'd5), jmp(6'h00, im(4)), wm(4'hf, 6'h00, 1, im(32'h100)), movi(2, 32'd1)});
        // メモリへの書き込みもレジスタへの代入も行われない
        expect_end();
        expect_mem32(32'h100, 32'd0);
        expect_reg(2, 32'd0);

        // 成立する分岐の直後に，N系で未定義のfuncを持つ命令を置き，分岐でそれを飛び越える
        `BEGIN_TEST("成立した分岐で飛び越えた実行できない命令では停止しない");
        run('{eq(0, 0, im(2)), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM), movi(1, 32'd1)});
        // 停止せずに飛び先の命令が実行される
        expect_end();
        expect_reg(1, 32'd1);

        // JMPの直後に，N系で未定義のfuncを持つ命令を置き，JMPでそれを飛び越える
        `BEGIN_TEST("JMPで飛び越えた実行できない命令では停止しない");
        run('{jmp(6'h00, im(2)), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM), movi(1, 32'd1)});
        // 停止せずに飛び先の命令が実行される
        expect_end();
        expect_reg(1, 32'd1);

        // 成立しない分岐の直後に，N系で未定義のfuncを持つ命令を置く
        `BEGIN_TEST("成立しない分岐の直後の実行できない命令では停止する");
        run('{ne(0, 0, im(2)), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM), movi(1, 32'd1)});
        // 分岐の次の命令の番地で停止する
        expect_halt(1);
    endtask

    // 連続した2命令を同じサイクルに実行段へ渡す同時実行の条件と，同時実行した命令の結果の受け渡し
    task automatic test_simultaneous_execution();
        int pair;  // 同時実行できる2命令の所要サイクル数
        int base;  // 比べる基準とする実行の所要サイクル数

        // 依存関係のない2つの代入と，書き込み先が同じ2つの代入を実行する
        `BEGIN_TEST("書き込み先が同じ2命令は同時実行されない");
        run('{movi(1, 32'd1), movi(2, 32'd2)});
        pair = cycles;
        run('{movi(1, 32'd1), movi(1, 32'd2)});
        // 後の代入の値が残り，同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_reg(1, 32'd2);
        expect_cycles(pair + 1);

        // 代入の後に，単純な演算でないNOPを置く
        `BEGIN_TEST("2番目が単純な演算でなければ同時実行されない");
        run('{movi(1, 32'd1), nop()});
        // 同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_cycles(pair + 1);
        run('{movi(1, 32'd3), movi(2, 32'd4), movi(5, 32'd1), mul(1, 2, 3)});
        // 複数サイクルかかるMULは単純な演算でないため同時実行されず，積が書き込まれる
        expect_end();
        expect_reg(3, 32'd12);

        // 成立しない分岐の後に代入を置く
        `BEGIN_TEST("先頭が分岐なら同時実行されない");
        run('{ne(0, 0, im(5)), movi(2, 32'd2)});
        // 同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_reg(2, 32'd2);
        expect_cycles(pair + 1);

        // 代入の後に，N系で未定義のfuncを持つ命令を置く
        `BEGIN_TEST("2番目が実行できなければ同時実行されず，先頭の実行後にその番地で停止する");
        run('{movi(1, 32'd1), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM)});
        // 先頭の代入は実行され，2番目の番地で停止する
        expect_halt(1);
        expect_reg(1, 32'd1);

        // 代入の後に，代入先を第1オペランド・第2オペランドとして読むADDをそれぞれ置く
        `BEGIN_TEST("2番目が先頭の書き込み先を読むなら同時実行されない");
        run('{movi(1, 32'd1), add(1, 0, 2)});
        // 第1オペランドで読む場合は，代入した値を受け取り，同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_reg(2, 32'd1);
        expect_cycles(pair + 1);
        run('{movi(1, 32'd1), add(0, 1, 2)});
        // 第2オペランドで読む場合も同じ
        expect_end();
        expect_reg(2, 32'd1);
        expect_cycles(pair + 1);
        run('{movi(1, 32'h55), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, 3, im(32'h100)), add(3, 0, 4)});
        // 先頭がメモリから読み込むRMで，2番目がその書き込み先を読む場合は，同時実行されずにRMが読み込んだ値を受け取る
        expect_end();
        expect_reg(4, 32'h55);

        // 代入の後に，代入先の番地をオペランドのフィールドに持つが，その値を使わない命令をそれぞれ置く
        `BEGIN_TEST("2番目が実際には使わないオペランドが先頭の書き込み先と同じでも同時実行される");
        run('{movi(1, 32'd1), mov(4'hf, 1, 2, im(32'd5))});
        // イミディエイトデータを代入するMOVの第1オペランドは使わないため，同時実行できる場合と同じサイクル数で終わる
        expect_end();
        expect_reg(2, 32'd5);
        expect_cycles(pair);
        run('{movi(1, 32'd1), sll(0, 1, 2, im(1))});
        // シフト量をイミディエイトデータで指定したシフトの第2オペランドも使わないため同じ
        expect_end();
        expect_cycles(pair);

        // WM(書き込み先レジスタのフィールドは0)の後に，r0を読むADDとNOPをそれぞれ置く
        `BEGIN_TEST("先頭がレジスタへ書き込まない命令なら，そのrdのフィールドの番地を2番目が読んでも同時実行される");
        run('{wm(4'hf, 6'h00, 0, im(32'h100)), nop()});
        base = cycles;
        run('{wm(4'hf, 6'h00, 0, im(32'h100)), add(0, 0, 2)});
        // ADDはWMと同時に実行され，WMの後にNOPを実行する場合より1サイクル早く終わる
        expect_end();
        expect_cycles(base - 1);

        // DIVの後に，商・余りの書き込み先と関係しない演算と，商・余りの書き込み先を読み書きする演算をそれぞれ置く
        `BEGIN_TEST("2番目が割り算の商・余りの書き込み先を読み書きするなら同時実行されない");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), add(0, 0, 5)});
        base = cycles;
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), add(3, 0, 5)});
        // 商を読む場合は，商を受け取り，関係しない演算より1サイクル多くかかる
        expect_end();
        expect_reg(5, 32'd2);
        expect_cycles(base + 1);
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), add(4, 0, 5)});
        // 余りを読む場合も同じ
        expect_end();
        expect_reg(5, 32'd1);
        expect_cycles(base + 1);
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), movi(3, 32'd7)});
        // 商の書き込み先へ書き込む場合は，後の代入の値が残り，関係しない演算より1サイクル多くかかる
        expect_end();
        expect_reg(3, 32'd7);
        expect_cycles(base + 1);
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), movi(4, 32'd7)});
        // 余りの書き込み先へ書き込む場合は，後の代入の値が残り，関係しない演算より1サイクル多くかかる
        expect_end();
        expect_reg(4, 32'd7);
        expect_cycles(base + 1);

        // 代入の後に，AR_SPIを読む代入を置く
        `BEGIN_TEST("2番目がAR_SPIを読むなら同時実行されない");
        run('{movi(1, 32'd1), movr(2, SPI_ADDR)});
        // SSの初期値1を読み，同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_reg(2, 32'd1);
        expect_cycles(pair + 1);

        // 代入の後に，AR8〜AR13を読む代入を置く
        `BEGIN_TEST("2番目がAR8〜AR13を読むなら同時実行されない");
        run('{movi(1, 32'd1), movr(2, AR8_13_ADDR)});
        // RSTn・CSnの初期値1を読み，同時実行できる場合より1サイクル多くかかる
        expect_end();
        expect_reg(2, 32'b000110);
        expect_cycles(pair + 1);

        // 代入の後に，プログラムカウンタを読む代入を置く
        `BEGIN_TEST("同時実行した2番目の命令はプログラムカウンタとして自身の番地を読む");
        run('{movi(1, 32'd1), movr(2, PC_ADDR)});
        // 2番目の命令の番地1を読み，同時実行できる場合と同じサイクル数で終わる
        expect_end();
        expect_reg(2, 32'd1);
        expect_cycles(pair);

        // 2つの代入を同時実行し，次に同時実行する先頭・2番目が，2つの代入の結果を第1・第2オペランドで読む
        `BEGIN_TEST("同時実行した2命令の結果を，次に同時実行する先頭・2番目の命令が受け取る");
        run('{movi(1, 32'd3), movi(2, 32'd5), movi(3, 32'd8), movi(4, 32'hffff_fffe)});
        base = cycles;
        run('{movi(1, 32'd3), movi(2, 32'd5), add(2, 1, 3), sub(1, 2, 4)});
        // 先頭は5+3，2番目は3-5を求め，4つの代入と同じサイクル数で終わる
        expect_end();
        expect_reg(3, 32'd8);
        expect_reg(4, 32'hffff_fffe);
        expect_cycles(base);

        // DIVと代入を同時実行し，次に同時実行する2番目が商と余りを読む
        `BEGIN_TEST("複数サイクル命令の結果を，次に同時実行する2番目の命令が受け取る");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), movi(6, 32'd1), movi(7, 32'd1), movi(5, 32'd3)});
        base = cycles;
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, im(4)), movi(6, 32'd1), movi(7, 32'd1), add(3, 4, 5)});
        // DIVと同時実行したr6への代入はDIVの完了時に書き込まれ，ADDは商2と余り1の和を求める．
        // ADDの代わりに和を代入する命令列と同じサイクル数で終わる
        expect_end();
        expect_reg(6, 32'd1);
        expect_reg(5, 32'd3);
        expect_cycles(base);

        // DIVとr6への代入を同時実行し，DIVの完了後に実行するADDがr6を読む
        `BEGIN_TEST("複数サイクル命令と同時実行した2番目の命令の結果を，次の命令が受け取る");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movi(6, 32'd5), add(6, 0, 7)});
        // ADDはr6へ代入した値を受け取る
        expect_end();
        expect_reg(7, 32'd5);

        // DIVとr6への代入を同時実行し，DIVの完了後に単独で実行段へ渡すr8への代入をはさんで，その次に実行段へ渡すADDがr6を読む
        `BEGIN_TEST("複数サイクル命令と同時実行した2番目の命令の結果を，1命令後に実行段へ渡す命令が受け取る");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movi(6, 32'd5), movi(8, 32'd1), add(6, 8, 7)});
        // ADDはr6へ代入した5とr8へ代入した1の和を求める
        expect_end();
        expect_reg(7, 32'd6);

        // 2つの代入を同時実行し，次のサイクルに単独で実行段へ渡す代入をはさんで，その次に実行段へ渡す命令が
        // r2を第1オペランドと第2オペランドのそれぞれで読む
        `BEGIN_TEST("同時実行した2番目の結果を，1命令後に実行段へ渡す命令が受け取る");
        // r6への代入を読むADDは代入と同時実行されず，代入の次のサイクルに先頭として実行段へ渡す
        run('{movi(1, 32'd3), movi(2, 32'd5), movi(6, 32'd1), add(2, 6, 3)});
        // ADDはr2へ代入した5とr6へ代入した1の和を求める
        expect_end();
        expect_reg(3, 32'd6);
        // r6へ代入する2命令は同時実行されず，後の代入の次のサイクルに，2番目として後の代入と同時実行するADDを実行段へ渡す
        run('{movi(1, 32'd3), movi(2, 32'd5), movi(6, 32'd1), movi(6, 32'd2), add(2, 1, 3)});
        // ADDはr2へ代入した5とr1へ代入した3の和を求める
        expect_end();
        expect_reg(3, 32'd8);
        // r6への代入を読むSUBは代入と同時実行されず，代入の次のサイクルに先頭として実行段へ渡し，r2を第2オペランドで読む
        run('{movi(1, 32'd3), movi(2, 32'd5), movi(6, 32'd1), sub(6, 2, 3)});
        // SUBはr6へ代入した1からr2へ代入した5を引く
        expect_end();
        expect_reg(3, 32'hffff_fffc);
        // r6へ代入する2命令は同時実行されず，後の代入の次のサイクルに，2番目として後の代入と同時実行するSUBを実行段へ渡し，
        // SUBはr2を第2オペランドで読む
        run('{movi(1, 32'd3), movi(2, 32'd5), movi(6, 32'd1), movi(6, 32'd2), sub(1, 2, 3)});
        // SUBはr1へ代入した3からr2へ代入した5を引く
        expect_end();
        expect_reg(3, 32'hffff_fffe);

        // 2つの代入を同時実行し，続けて単独で実行段へ渡す代入が，2番目と同じレジスタへ書き込む
        `BEGIN_TEST("同時実行した2番目と，次に実行段へ渡す命令が同じレジスタへ書き込むと，後の命令の値が残る");
        run('{movi(1, 32'd1), movi(2, 32'd5), movi(2, 32'd7)});
        expect_end();
        expect_reg(2, 32'd7);

        // 2組の代入を続けて同時実行し，どちらの組の2番目もr2へ書き込む
        `BEGIN_TEST("続けて同時実行した2組の2番目が同じレジスタへ書き込むと，後の組の値が残る");
        run('{movi(1, 32'd1), movi(2, 32'd5), movi(3, 32'd1), movi(2, 32'd7)});
        expect_end();
        expect_reg(2, 32'd7);

        // 代入と，スタックポインタへの代入を同時実行し，直後のCALLで戻り先を積む
        `BEGIN_TEST("同時実行した2番目がスタックポインタへ書き込んだ直後のCALL・RETは，書き込んだ値を使う");
        run('{movi(1, 32'd1), movi(SP_ADDR, 32'h200), call(6'h00, im(4)), jmp(6'h00, im(6)),
              movr(5, SP_ADDR), ret()});
        // 代入した番地の1ワード下へ戻り先3を積み，戻るとスタックポインタは代入した値に戻る
        expect_end();
        expect_reg(5, 32'h1fc);
        expect_mem32(32'h1fc, 32'd3);
        expect_reg(SP_ADDR, 32'h200);
        // 戻り先5をメモリへ書き込むWMと，その番地のスタックポインタへの代入を同時実行し，直後のRETで戻る
        run('{movi(2, 32'd5), wm(4'hf, 6'h00, 2, im(32'h100)), movi(SP_ADDR, 32'h100), ret(), movi(3, 32'd1)});
        // 代入した番地から戻り先5を下ろして正常終了し，RETの直後の代入は実行されない
        expect_end();
        expect_reg(3, 32'd0);
        expect_reg(SP_ADDR, 32'h104);

        // ADDの代わりに和を代入する命令列と，ADDとADDが読むr1への代入を同時実行する命令列を実行する
        `BEGIN_TEST("先頭が読むレジスタへ同時実行した2番目が書き込んでも，先頭は書き込む前の値を使う");
        run('{movi(1, 32'd5), movi(2, 32'd3), movi(3, 32'd8), movi(1, 32'd9)});
        base = cycles;
        run('{movi(1, 32'd5), movi(2, 32'd3), add(1, 2, 3), movi(1, 32'd9)});
        // ADDは書き込む前のr1で和を求め，r1には後の代入の値が残る．
        // ADDの代わりに和を代入する命令列と同じサイクル数で終わる
        expect_end();
        expect_reg(3, 32'd8);
        expect_reg(1, 32'd9);
        expect_cycles(base);
        // WMと，WMがメモリへ書き込むr1への代入を同時実行する
        run('{movi(1, 32'd5), wm(4'hf, 6'h00, 1, im(32'h100)), movi(1, 32'd9)});
        // メモリには書き込む前のr1が書かれ，r1には後の代入の値が残る
        expect_end();
        expect_mem32(32'h100, 32'd5);
        expect_reg(1, 32'd9);

        // 0で割るDIVと代入を同時実行する
        `BEGIN_TEST("先頭が停止すると，同時実行した2番目の命令は書き込まない");
        run('{movi(1, 32'd9), div(1, 0, 3, NO_IMM), movi(5, 32'd1)});
        // DIVの番地で停止し，代入は書き込まれない
        expect_halt(1);
        expect_reg(5, 32'd0);

        // 成立する分岐の後に，同時実行できる2つの代入と，分岐先の代入を置く
        `BEGIN_TEST("成立した分岐が完了するサイクルに同時実行した2命令は，どちらも実行されない");
        run('{eq(0, 0, im(3)), movi(1, 32'd1), movi(2, 32'd1), movi(3, 32'd1)});
        // 分岐で飛び越えた2つの代入は書き込まれず，分岐先の代入は実行される
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd0);
        expect_reg(3, 32'd1);

        // MISOピンを1にした状態で，代入と，上位ビットを立てた値をAR_SPIへ書き込む代入を同時実行し，直後の命令でAR_SPIを読む
        `BEGIN_TEST("同時実行した2番目の命令がAR_SPIへ書き込んだ直後の命令もMISOの値を読める");
        ck_miso = 1'b1;
        run('{movi(1, 32'd1), movi(SPI_ADDR, 32'hffff_fff6), movr(2, SPI_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // 上位28ビットが0，ビット3がMISOの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(2, 32'b1110);

        // MISOピンを1にした状態で，代入と，上位ビットを立てた値をAR_SPIへ書き込む代入を同時実行し，
        // 次のサイクルに単独で実行段へ渡す代入をはさんで，その次の命令でAR_SPIを読む
        `BEGIN_TEST("同時実行した2番目の命令がAR_SPIへ書き込んだ1命令後の命令もMISOの値を読める");
        ck_miso = 1'b1;
        run('{movi(1, 32'd1), movi(SPI_ADDR, 32'hffff_fff6), movi(6, 32'd1), movr(2, SPI_ADDR)});
        // 後のテストケースへ影響しないよう，MISOピンを0へ戻す
        ck_miso = 1'b0;
        // 上位28ビットが0，ビット3がMISOの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(2, 32'b1110);

        // INTn・MISOピンを1にした状態で，代入と，上位ビットを立てた値をAR8〜AR13へ書き込む代入を同時実行し，直後の命令でAR8〜AR13を読む
        `BEGIN_TEST("同時実行した2番目の命令がAR8〜AR13へ書き込んだ直後の命令もINTn・MISOの値を読める");
        eth_intn = 1'b1;
        eth_miso = 1'b1;
        run('{movi(1, 32'd1), movi(AR8_13_ADDR, 32'hffff_ffea), movr(2, AR8_13_ADDR)});
        // 後のテストケースへ影響しないよう，INTn・MISOピンを0へ戻す
        eth_intn = 1'b0;
        eth_miso = 1'b0;
        // 上位26ビットが0，ビット0・4がピンの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(2, 32'b111011);

        // INTn・MISOピンを1にした状態で，代入と，上位ビットを立てた値をAR8〜AR13へ書き込む代入を同時実行し，
        // 次のサイクルに単独で実行段へ渡す代入をはさんで，その次の命令でAR8〜AR13を読む
        `BEGIN_TEST("同時実行した2番目の命令がAR8〜AR13へ書き込んだ1命令後の命令もINTn・MISOの値を読める");
        eth_intn = 1'b1;
        eth_miso = 1'b1;
        run('{movi(1, 32'd1), movi(AR8_13_ADDR, 32'hffff_ffea), movi(6, 32'd1), movr(2, AR8_13_ADDR)});
        // 後のテストケースへ影響しないよう，INTn・MISOピンを0へ戻す
        eth_intn = 1'b0;
        eth_miso = 1'b0;
        // 上位26ビットが0，ビット0・4がピンの1，ほかのビットが書き込んだ値になる
        expect_end();
        expect_reg(2, 32'b111011);
    endtask

    // 直前の実行で送信バッファへ入ったバイトの列を確かめる
    function automatic void expect_uart_tx(input logic [7:0] values[$]);
        if (uart_tx_log != values)
            fail($sformatf("送信バッファへ入ったバイト: 期待値%p，実際%p", values, uart_tx_log));
    endfunction

    // UARTのレジスタ．送信の指示は書き込んだ次のサイクルにモデルへ届くため，送信を確かめる命令列は末尾にNOPを置いてから正常終了させる
    task automatic test_uart();
        // 受信バッファが空で送信バッファに空きがある状態で，UARTのレジスタを読み出す
        `BEGIN_TEST("UARTのレジスタで送信バッファに空きがあることを読める");
        run('{movr(1, UART_ADDR)});
        // 空きがあることを示すビット25だけが1になる
        expect_end();
        expect_reg(1, 32'h0200_0000);

        // 受信バッファに1バイトある状態で，UARTのレジスタを読み出す
        `BEGIN_TEST("UARTのレジスタで受信バッファの先頭のバイトを読める");
        uart_rx_queue = '{8'h41};
        run('{movr(1, UART_ADDR)});
        // ビット16〜23が先頭のバイト，ビット24が受信したバイトがあること，ビット25が空きがあることを示す
        expect_end();
        expect_reg(1, 32'h0341_0000);

        // 受信バッファに2バイトある状態で，取り出しを指示した直後の命令と，数命令後の命令で読み出す
        `BEGIN_TEST("取り出しを指示した直後は受信したバイトがあることを示さず，後で次のバイトを示す");
        uart_rx_queue = '{8'h41, 8'h42};
        run('{movi(5, 32'h0300_0000), movi(UART_ADDR, 32'h200), movr(2, UART_ADDR), nop(), nop(), nop(), nop(), movr(3, UART_ADDR),
              and_(2, 5, 4)});
        // 直後の命令ではバイトがあること・空きがあることのビットが0になり，後の命令では1バイトだけ取り除いた状態が読める
        expect_end();
        expect_reg(4, 32'h0);
        expect_reg(3, 32'h0342_0000);

        // 送信を指示するビットを立てた値と，立てない値を続けてUARTのレジスタへ書き込む
        `BEGIN_TEST("送信を指示したバイトだけが送信バッファへ入る");
        run('{movi(UART_ADDR, 32'h141), movi(UART_ADDR, 32'h042), movi(UART_ADDR, 32'h143), nop(), nop()});
        // 送信を指示した1つ目と3つ目のバイトが，書き込んだ順に入る
        expect_end();
        expect_uart_tx('{8'h41, 8'h43});

        // 送信を指示した直後の命令と，数命令後の命令でUARTのレジスタを読み出す
        `BEGIN_TEST("送信を指示した直後は空きがあることを示さず，後で空きがあることを示す");
        run('{movi(UART_ADDR, 32'h141), movr(2, UART_ADDR), nop(), nop(), nop(), nop(), movr(3, UART_ADDR)});
        // 直後の命令では空きがあることのビットが0になり，後の命令では空きがあることを示す
        expect_end();
        expect_uart_tx('{8'h41});
        expect_reg(2, 32'h0);
        expect_reg(3, 32'h0200_0000);

        // 送信バッファにためられるバイト数より1つ多く送信を指示してから，UARTのレジスタを読み出す
        `BEGIN_TEST("送信バッファが満杯になると送信の指示は無視され，空きがないことを示す");
        run('{movi(UART_ADDR, 32'h141), movi(UART_ADDR, 32'h142), movi(UART_ADDR, 32'h143), movi(UART_ADDR, 32'h144),
              movi(UART_ADDR, 32'h145), nop(), nop(), nop(), nop(), movr(1, UART_ADDR)});
        // ためられる4バイトだけが入り，空きがあることのビットが0になる
        expect_end();
        expect_uart_tx('{8'h41, 8'h42, 8'h43, 8'h44});
        expect_reg(1, 32'h0);

        // 代入と，UARTのレジスタへの送信の指示を同時実行する
        `BEGIN_TEST("同時実行した2番目の命令による送信の指示も送信バッファへ入る");
        run('{movi(1, 32'd1), movi(UART_ADDR, 32'h146), nop(), nop()});
        // 指示したバイトが入る
        expect_end();
        expect_uart_tx('{8'h46});

        // メモリから読んだ値をRMでUARTのレジスタへ書き込む
        `BEGIN_TEST("RMによる送信の指示も送信バッファへ入る");
        run('{movi(1, 32'h147), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, UART_ADDR, im(32'h100)), nop(), nop()});
        // 読んだ値のバイトが入る
        expect_end();
        expect_uart_tx('{8'h47});

        // 0x148÷0x1000の余り0x148を，UARTのレジスタへ書き込む
        `BEGIN_TEST("割り算の余りによる送信の指示も送信バッファへ入る");
        run('{movi(1, 32'h148), movi(2, 32'h1000), div(1, 2, 3, im(UART_ADDR)), nop(), nop()});
        // 余りのバイトが入る
        expect_end();
        expect_uart_tx('{8'h48});

        // 全ビットが1の値をUARTのレジスタへ書き込んでから，数命令後に読み出す
        `BEGIN_TEST("UARTのレジスタへ書き込んだ指示のビットは読み出せない");
        run('{movi(UART_ADDR, '1), nop(), nop(), nop(), nop(), movr(1, UART_ADDR)});
        // 送信を指示したバイトが入り，読み出した値は空きがあることのビット25だけが1になる
        expect_end();
        expect_uart_tx('{8'hff});
        expect_reg(1, 32'h0200_0000);
    endtask

    initial begin
        // 命令の種類ごとのテストケースを実行する
        test_n_type();
        test_p_type();
        test_s_type();
        test_a_type();
        test_f_type();
        test_j_type();
        test_m_type();
        test_undefined_type();
        // 命令の種類をまたぐテストケースを実行する
        test_register_access();
        test_operand_checks();
        test_mode();
        test_pins();
        test_uart();
        test_common();
        test_code_area();
        test_pipeline();
        test_simultaneous_execution();
        // 最後のテストケースを数える
        finish_test();

        // 合否の件数を表示し，不合格があれば失敗として終える
        $display("==== 合格 %0d件，不合格 %0d件 ====", passed, failed);
        if (failed > 0)
            $fatal(1, "不合格のテストケースがあります");
        $finish;
    end

endmodule
