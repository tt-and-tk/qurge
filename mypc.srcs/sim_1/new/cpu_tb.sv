`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// CPUの命令の動作を検証するテストベンチ．
// CPU本体(cpu_sv)とメインメモリ(ram_sv)は実物を使い，ROMと除算IPをテストベンチ用のモデルに差し替える．
// テストケースごとにmachine.svhの関数で組んだ命令列をROMへ書き込んで実行し，実行後のレジスタ・メモリ・
// 停止の有無と番地・標準出力を期待値と比較する．最後に合否の件数を表示し，失敗があれば$fatalで終了する．
//
// このファイルで使う用語
// - テストケース: 1つの命令列を実行し，その結果を期待値と比較する単位．合否はテストケースごとに数える
// - 正常終了: 命令列の末尾に置いた，自分自身へジャンプし続ける命令の実行に入ること(仕様上のプログラムの終わり方)
// - 停止: CPUが実行できない命令や不正な値を検出して実行を止めること(仕様はhalt.md)
// - 先読み: CPUが複数サイクルかかる命令を実行している間に，次の命令をROMから取得しておくこと
// - コード領域: メインメモリの後半．PCのうちROMの命令数の上限に続く範囲が，ここに置いた命令に対応する(仕様はrom.md)
// - フォワーディング: 先読みした命令が，直前の命令がそのサイクルに書き込む値をレジスタを経由せずに受け取ること
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

    rom_read_if  rom_read();   // CPUとROMの接続
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

    logic [31:0] stdin_tdata = '0;       // 標準入力へ送る値
    logic        stdin_tvalid = 1'b0;    // 標準入力へ送る値が有効か
    logic        stdin_tready;           // CPUが標準入力を受け取れるか
    logic [31:0] stdout_tdata;           // CPUが標準出力へ出す値
    logic [ 3:0] stdout_tkeep;           // 標準出力の有効バイト(CPUは常に全バイト有効で出す)
    logic        stdout_tlast;           // 標準出力の終端(CPUは常に1で出す)
    logic        stdout_tvalid;          // CPUが標準出力へ出す値が有効か
    logic        stdout_tready = 1'b0;   // 標準出力を受け取れるか

    logic [ 3:0] btn = 4'b0;                               // タクトスイッチ
    logic [ 1:0] sw = 2'b0;                                // DIPスイッチ
    logic [ 3:0] led;                                      // LED
    logic [ 5:0] rgb_led;                                  // RGB LED
    logic [ 7:0] ja, jb;                                   // Pmod A・Pmod B
    logic [13:0] ar;                                       // Arduinoのデジタル入出力0〜13番ピン
    logic        a, ar_sda, ar_scl;                        // Arduinoの単体デジタルピン・I2CのSDA/SCL
    logic        ck_mosi, ck_sck, ck_ss;                   // Arduino SPIのMOSI・SCK・SS
    logic        ck_miso = 1'b0;                           // Arduino SPIのMISO
    logic [26:8] gpio;                                     // ラズパイヘッダーのGPIO8〜GPIO26

    // 試験対象のCPU
    cpu_sv dut (
        .clk(clk), .resetn(resetn),
        .rom_read(rom_read),
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
        .stdin_tdata(stdin_tdata),
        .stdin_tkeep(4'hf),
        .stdin_tlast(1'b1),
        .stdin_tready(stdin_tready),
        .stdin_tvalid(stdin_tvalid),
        .stdout_tdata(stdout_tdata),
        .stdout_tkeep(stdout_tkeep),
        .stdout_tlast(stdout_tlast),
        .stdout_tready(stdout_tready),
        .stdout_tvalid(stdout_tvalid),
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
        .rom_read(rom_read)
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

    // ===== 標準入出力の相手 =====

    logic [31:0] stdin_queue[$];   // これから標準入力へ送る値の列
    int          stdin_delay = 0;  // 1つ前の受け渡しから次の値を送り始めるまでに空けるサイクル数
    logic [31:0] stdout_log[$];    // 標準出力から受け取った値の列
    int          stdout_delay = 0; // CPUが値を出してから受け取るまでのサイクル数．0なら常に受け取れる状態にしておく
    int          stdin_wait = 0;   // 標準入力で次の値を送り始めるまでに待ったサイクル数
    int          stdout_wait = 0;  // 標準出力で受け取るまでに待ったサイクル数

    // 標準入力．値を1つずつ送り，CPUが受け取ったサイクルに次の値へ進む
    always @(posedge clk) begin
        // リセット中は何も送らない
        if (!resetn) begin
            stdin_tvalid <= 1'b0;
            stdin_wait   <= 0;
        end
        // CPUが受け取ったので，送るのをやめて次の値を待つ
        else if (stdin_tvalid && stdin_tready) begin
            stdin_tvalid <= 1'b0;
            stdin_wait   <= 0;
        end
        // 送る値が残っていれば，決められたサイクル数だけ待ってから次の値を送り始める
        else if (!stdin_tvalid && stdin_queue.size() > 0) begin
            if (stdin_wait >= stdin_delay) begin
                stdin_tdata  <= stdin_queue.pop_front();
                stdin_tvalid <= 1'b1;
            end
            else begin
                stdin_wait <= stdin_wait + 1;
            end
        end
    end

    // 標準出力．CPUが出した値を受け取ったサイクルにその値を記録する
    always @(posedge clk) begin
        // リセット中は受け取らない
        if (!resetn) begin
            stdout_tready <= 1'b0;
            stdout_wait   <= 0;
        end
        // 待たない場合は常に受け取れる状態にしておき，値が出たサイクルに記録する
        else if (stdout_delay == 0) begin
            if (stdout_tvalid && stdout_tready)
                stdout_log.push_back(stdout_tdata);
            stdout_tready <= 1'b1;
        end
        // 受け取ったサイクルに値を記録し，次の値に備えて受け取れない状態へ戻す
        else if (stdout_tvalid && stdout_tready) begin
            stdout_log.push_back(stdout_tdata);
            stdout_tready <= 1'b0;
            stdout_wait   <= 0;
        end
        // CPUが値を出していれば，決められたサイクル数だけ待ってから受け取れる状態にする
        else if (stdout_tvalid) begin
            if (stdout_wait >= stdout_delay)
                stdout_tready <= 1'b1;
            else
                stdout_wait <= stdout_wait + 1;
        end
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

    localparam int CODE_AREA_PC = rom_p::CODE_AREA_PC_BASE;  // コード領域の先頭の命令に対応するPC

    // コード領域の先頭からindex番目の命令を置くメインメモリの番地を返す
    function automatic int code_area_address(input int index);
        return ram_p::CODE_AREA_BASE + index * 8;
    endfunction

    // 命令をコード領域のindex番目へWMで書き込む命令列を作る．下位ワード(イミディエイトデータ)を小さい番地へ，
    // 上位ワード(命令語)をその4バイト後へ書く．書き込む値の受け渡しにr15を使う
    function automatic machine_queue_t store_code(input int index, input machine_t instruction);
        return '{movi(15, instruction[31:0]),  wm(4'hf, 6'h00, 15, im(code_area_address(index))),
                 movi(15, instruction[63:32]), wm(4'hf, 6'h00, 15, im(code_area_address(index) + 4))};
    endfunction

    // ===== 実行と結果の採取 =====

    typedef enum {ENDED, HALTED, TIMED_OUT} outcome_enum;  // 実行の終わり方(正常終了・停止・打ち切り)

    outcome_enum    outcome;                          // 直前の実行の終わり方
    register_t      regs[0:REGISTER_MAX_ADDR];        // 直前の実行を終えた時点のレジスタの値
    int             end_pc;                           // 正常終了を表す命令の番地
    machine_queue_t code_area;                        // 実行前にコード領域へ直接置く命令列
    int             code_area_index = 0;              // code_areaを置き始める，コード領域の先頭からの命令の順番
    machine_queue_t rom_tail;                         // 実行前にROMの末尾(最後の命令をROMの命令数の上限の直前の番地に揃える位置)へ置く命令列

    // CPUの現在のレジスタの値を，実行を終えた時点の値として写し取る
    function automatic void take_snapshot();
        for (int i = 0; i <= REGISTER_MAX_ADDR; i++)
            regs[i] = dut.alu_sv_0.register[i];
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

    // 命令列をコード領域のindex番目から直接書き込む．各命令の下位のバイトほど小さい番地に置く
    function automatic void put_code_area(input int index, input machine_queue_t instructions);
        // 1命令ずつ，8バイトを下位のバイトから順に書き込む
        foreach (instructions[i])
            for (int b = 0; b < 8; b++)
                set_ram_byte(code_area_address(index + i) + b, instructions[i][b * 8 +: 8]);
    endfunction

    // 命令列をROMの先頭へ，code_area・rom_tailの命令列をそれぞれコード領域・ROMの末尾へ書き込み，
    // リセットしてから，正常終了・停止・打ち切りのいずれかに至るまで実行する．
    // 実行の終わり方と，終えた時点のレジスタの値を残す．停止した場合のレジスタの値は，停止した命令が
    // 実行された時点のもの(初期値へ戻る前)になる．
    // 末尾に正常終了を表す命令を付けない場合(ROMの範囲外へ進む場合の検証)は2番目の引数を0に，
    // 前の実行でメモリへ書いた値を残す場合は3番目の引数を1にする
    task automatic run(input machine_t body[$], input bit append_end = 1'b1, input bit keep_ram = 1'b0);
        machine_t instructions[$] = body;  // ROMへ書き込む命令列

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
        // リセット中に，コード領域へ置く命令列を書き込む(メモリを消した後に書くため，消す処理より後に置く)
        put_code_area(code_area_index, code_area);
        // リセット中に，命令列をROMへ書き込む
        rom.load(instructions);
        // リセット中に，ROMの末尾へ置く命令列を書き込む(有効な命令数がROMの命令数の上限まで広がる)
        if (rom_tail.size() > 0)
            rom.place(rom_p::MAX_LINE_NUM - rom_tail.size(), rom_tail);
        // リセット中に，前の実行で受け取った標準出力を消す
        stdout_log.delete();
        // リセットを2サイクル保ってから解除する
        repeat (2) @(negedge clk);
        resetn = 1'b1;

        // 停止・正常終了・打ち切りのいずれかに至るまで1サイクルずつ進める
        for (int cycle = 0; ; cycle++) begin
            // クロックの立ち上がりで更新された値が確定するのを待つ
            @(posedge clk);
            #1;
            // 停止した．仕様上は停止と同時にレジスタが初期値へ戻るが，CPUは停止を検出した次のクロックで
            // 戻すため，このサイクルのうちに採取すれば停止した番地と書き換えの有無を確かめられる．
            // 停止と同じクロックで初期値へ戻す実装に変えた場合は，この採取方法を見直す必要がある
            if (dut.alu_sv_0.is_halted) begin
                outcome = HALTED;
                break;
            end
            // 正常終了を表す命令の実行に入った
            if (append_end && dut.alu_sv_0.register[PC_ADDR] == end_pc && dut.alu_sv_0.cpu_phase == CPU_EXECUTE) begin
                outcome = ENDED;
                break;
            end
            // どちらにも至らないまま上限のサイクル数に達した
            if (cycle >= MAX_CYCLES) begin
                outcome = TIMED_OUT;
                break;
            end
        end

        // 実行を終えた時点のレジスタの値を写し取る
        take_snapshot();
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
    // 標準入出力の相手は入力なし・待ちなしの状態に，コード領域・ROMの末尾へ置く命令列は空に戻す
    function automatic void begin_test(input string name);
        // 前のテストケースを数える
        finish_test();
        // 新しいテストケースの名前を控え，不一致の数を0から数え直す
        test_name    = name;
        test_errors  = 0;
        test_open    = 1'b1;
        // 標準入出力の相手を，入力なし・待ちなしの状態に戻す
        stdin_queue.delete();
        stdin_delay  = 0;
        stdout_delay = 0;
        // コード領域・ROMの末尾へ置く命令列を空にする
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

    // 直前の実行で標準出力へ出た値の列を確かめる
    function automatic void expect_output(input logic [31:0] values[$]);
        if (stdout_log != values)
            fail($sformatf("標準出力: 期待値%p，実際%p", values, stdout_log));
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

        // シフト量に33(下位5ビットは1)を即値・rs2で指定する
        `BEGIN_TEST("シフト量は下位5ビットだけを使う");
        run('{movi(1, 32'h8000_0001), movi(6, 32'd33), sll(1, 0, 2, im(33)), srl(1, 6, 3, NO_IMM)});
        // 1ビットだけシフトされる
        expect_end();
        expect_reg(2, 32'h0000_0002);
        expect_reg(3, 32'h4000_0000);

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

        // 何も積んでいないスタックでRETする(戻り先を読む番地がコード領域の先頭になる)
        `BEGIN_TEST("空のスタックでのRETは停止する");
        run('{nop(), ret()});
        // RETの番地で停止し，SPは元のまま
        expect_halt(1);
        expect_reg(SP_ADDR, 32'h8000);

        // SPを0x8004にしてから関数を呼ぶ(戻り先の積み先がコード領域の先頭になる)
        `BEGIN_TEST("スタックの積み先がコード領域に入るCALLは書き込まずに停止する");
        run('{movi(SP_ADDR, 32'h8004), call(6'h00, im(0))});
        // CALLの番地で停止し，SPもコード領域も書き換わらない
        expect_halt(1);
        expect_reg(SP_ADDR, 32'h8004);
        expect_mem32(32'h8000, 32'd0);

        // SPを0x8000のまま，SPからの相対位置でコード領域の先頭を読み書きする
        `BEGIN_TEST("SPからの相対位置でコード領域を読み書きするRMR/WMRは停止しない");
        run('{movi(1, 32'h1234_5678), wmr(4'hf, SP_ADDR, 1, im(0)), rmr(4'hf, SP_ADDR, 2, im(0))});
        // 正常終了し，コード領域の先頭が読み書きされる
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
        run('{raw(3'h5, 6'h03, 0, 0, 0, im(1))});
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

    // 標準入出力系(IO系)
    task automatic test_io_type();
        // 20サイクルずつ遅れて届く2つの入力を受け取り，その和を求める
        `BEGIN_TEST("SCANは入力が届くまで待って受け取る");
        stdin_queue = '{32'h41, 32'h42};
        stdin_delay = 20;
        run('{scan(1), scan(2), add(1, 2, 3)});
        // 届いた順に受け取れる
        expect_end();
        expect_reg(1, 32'h41);
        expect_reg(2, 32'h42);
        expect_reg(3, 32'h83);

        // 既に届いている2つの入力を受け取り，その和を求める．SCANの実行が2サイクルで終わり，
        // 次の命令の先読みが間に合わない経路を通る
        `BEGIN_TEST("SCANは既に届いている入力を受け取る");
        stdin_queue = '{32'h41, 32'h42};
        stdin_delay = 0;
        run('{scan(1), scan(2), add(1, 2, 3)});
        // 届いた順に受け取れる
        expect_end();
        expect_reg(1, 32'h41);
        expect_reg(2, 32'h42);
        expect_reg(3, 32'h83);

        // 受け取りが20サイクル遅れる相手へ，即値とr1の値を出力する
        `BEGIN_TEST("PRINTは受け取られるまで待って即値・レジスタの値を出力する");
        stdout_delay = 20;
        run('{movi(1, 32'h43), print(6'h00, im(32'h41)), print(1, NO_IMM), movi(2, 32'd1)});
        // 出力した順に受け取られ，その後の命令も実行される
        expect_end();
        expect_output('{32'h41, 32'h43});
        expect_reg(2, 32'd1);

        // すぐに受け取る相手へ，即値とr1の値を出力する．PRINTの実行が2サイクルで終わり，
        // 次の命令の先読みが間に合わない経路を通る
        `BEGIN_TEST("PRINTはすぐに受け取られる場合も即値・レジスタの値を出力する");
        stdout_delay = 0;
        run('{movi(1, 32'h43), print(6'h00, im(32'h41)), print(1, NO_IMM), movi(2, 32'd1)});
        // 出力した順に受け取られ，その後の命令も実行される
        expect_end();
        expect_output('{32'h41, 32'h43});
        expect_reg(2, 32'd1);

        // IO系で未定義のfuncを持つ命令を実行する
        `BEGIN_TEST("IO系で未定義のfuncは停止する");
        run('{raw(3'h7, 6'h02, 0, 0, 0, NO_IMM)});
        // その命令の番地で停止する
        expect_halt(0);
    endtask

    // 仕様(register.md)の表に基づき，その番地のレジスタを命令のオペランドとして読めるかを返す
    function automatic bit spec_readable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h10], [6'h1c:6'h21], 6'h29, 6'h2a, 6'h31: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 仕様(register.md)の表に基づき，その番地のレジスタを命令のオペランドとして書けるかを返す
    function automatic bit spec_writable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h10], 6'h1d, 6'h1e, [6'h22:6'h28], 6'h2a, [6'h2d:6'h30], 6'h33: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 全番地のレジスタの読み書き可否
    task automatic test_register_access();
        for (int addr = 0; addr <= REGISTER_MAX_ADDR; addr++) begin
            // 読み出せるかどうかを名前に含めてテストケースを始める
            if (spec_readable(addr))
                begin_test($sformatf("レジスタ0x%02hは読み出せる", addr));
            else
                begin_test($sformatf("レジスタ0x%02hを読み出すと停止する", addr));
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
                begin_test($sformatf("レジスタ0x%02hへ書き込める", addr));
            else
                begin_test($sformatf("レジスタ0x%02hへ書き込むと停止する", addr));
            // その番地のレジスタへMOVで0を書き込む
            run('{nop(), movi(addr, 32'h0)});
            // 書き込めるなら正常終了し，書き込めないならMOVの番地で停止する
            if (spec_writable(addr))
                expect_end();
            else
                expect_halt(1);
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
        // 読み込み不可の番地として0x11，書き込み不可の番地としてPCを，使うオペランド・使わないオペランドに入れた命令
        operand_case_t cases[$] = '{
            '{$sformatf("即値を使うMOVはrs1が読み込み不可でも停止しない"),       mov(4'hf, 6'h11, 1, im(5)),                   1'b0},
            '{$sformatf("即値でシフト量を指定するとrs2が読み込み不可でも停止しない"), sll(1, 6'h11, 3, im(1)),                  1'b0},
            '{$sformatf("NOTはrs2が読み込み不可でも停止しない"),                   raw(3'h1, NOT, 1, 6'h11, 3, NO_IMM),          1'b0},
            '{$sformatf("imm未使用のDIVは余りの格納先が書き込み不可でも停止しない"), div(1, 2, 3, {1'b0, 26'h0, PC_ADDR}),       1'b0},
            '{$sformatf("即値の番地へのJMPはrs1が読み込み不可でも停止しない"),     jmp(6'h11, im(2)),                            1'b0},
            '{$sformatf("即値の番地のRMはrs1が読み込み不可でも停止しない"),       rm(4'hf, 6'h11, 3, im(32'h100)),              1'b0},
            '{$sformatf("WMは使わないrdが書き込み不可でも停止しない"),             raw(3'h6, WM, 0, 2, PC_ADDR, im(32'h100)),    1'b0},
            '{$sformatf("即値を出力するPRINTはrs1が読み込み不可でも停止しない"),   print(6'h11, im(32'h41)),                     1'b0},
            '{$sformatf("rs2でシフト量を指定するとrs2が読み込み不可なら停止する"), sll(1, 6'h11, 3, NO_IMM),                   1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先が書き込み不可なら停止する"),   div(1, 2, 3, im(PC_ADDR)),                    1'b1},
            '{$sformatf("imm使用のDIVは余りの格納先が番地の上限を超えると停止する"), div(1, 2, 3, im(REGISTER_MAX_ADDR + 1)),       1'b1},
            '{$sformatf("レジスタの番地へのJMPはrs1が読み込み不可なら停止する"),   jmp(6'h11, NO_IMM),                           1'b1},
            '{$sformatf("レジスタの番地へのCALLはrs1が読み込み不可なら停止する"),  call(6'h11, NO_IMM),                          1'b1},
            '{$sformatf("分岐はrs1が読み込み不可なら停止する"),                   eq(6'h11, 0, im(1)),                          1'b1},
            '{$sformatf("RMは書き込み先が書き込み不可なら停止する"),               rm(4'hf, 6'h00, PC_ADDR, im(32'h100)),        1'b1},
            '{$sformatf("WMは書き込むデータのrs2が読み込み不可なら停止する"),     wm(4'hf, 6'h00, 6'h11, im(32'h100)),          1'b1},
            '{$sformatf("RMRは番地の基準のrs1が読み込み不可なら停止する"),       rmr(4'hf, 6'h11, 3, im(0)),                   1'b1},
            '{$sformatf("WMRは書き込むデータのrs2が読み込み不可なら停止する"),   wmr(4'hf, 2, 6'h11, im(0)),                   1'b1},
            '{$sformatf("SCANは書き込み先が書き込み不可なら停止する"),             scan(PC_ADDR),                                1'b1},
            '{$sformatf("レジスタを出力するPRINTはrs1が読み込み不可なら停止する"), print(6'h11, NO_IMM),                         1'b1}
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

    // ボード上の入出力ピンにつながるレジスタ
    task automatic test_pins();
        // 出力用の各レジスタへ値を書き込む
        `BEGIN_TEST("出力用のレジスタへの書き込みが対応するピンに出る");
        run('{movi(LED_ADDR, 32'h5), movi(RGB_LED_ADDR, 32'h2a), movi(PMOD_A_ADDR, 32'ha5), movi(PMOD_B_ADDR, 32'h5a),
              movi(AR_LOW_ADDR, 32'h81), movi(AR_HIGH_ADDR, 32'h21), movi(AR_MISC_ADDR, 32'b101),
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
        // AR0〜AR7とAR8〜AR13へ書いた値が，AR番号の順に並んで出る
        if (ar !== 14'h2181)
            fail($sformatf("AR0〜AR13: 期待値0x2181，実際0x%h", ar));
        // Arduinoの単体ピン・I2C・SPIへ書いた値が，ビットごとに対応するピンに出る
        if ({a, ar_sda, ar_scl} !== 3'b101)
            fail($sformatf("A・AR_SDA・AR_SCL: 期待値101，実際%b", {a, ar_sda, ar_scl}));
        if ({ck_sck, ck_mosi, ck_ss} !== 3'b110)
            fail($sformatf("SPI(SCK,MOSI,SS): 期待値110，実際%b", {ck_sck, ck_mosi, ck_ss}));
        // GPIOの3つのレジスタへ書いた値が，GPIO番号の順に並んで出る
        if (gpio !== 19'h54281)
            fail($sformatf("GPIO8〜GPIO26: 期待値0x54281，実際0x%h", gpio));

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

        // r1・SPを書き換えてから，書き込み不可のPCへの書き込みで停止させる
        `BEGIN_TEST("停止するとレジスタが初期値へ戻り，リセットまで停止が続く");
        run('{movi(1, 32'd5), movi(SP_ADDR, 32'h100), movi(PC_ADDR, 32'd0)});
        // 停止した番地と，停止した時点のr1の値を確かめる
        expect_halt(2);
        expect_reg(1, 32'd5);
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

    // コード領域(メインメモリ)に置いた命令の実行
    task automatic test_code_area();
        machine_queue_t body;  // ROMへ書き込む命令列

        // コード領域の0番目にr1への代入を，1番目にRETを，ROM上の命令がWMで書き込んでからCALLで呼び，戻った後のSPを読む
        `BEGIN_TEST("WMでコード領域へ書いた命令をCALLで実行し，RETで戻る");
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
        `BEGIN_TEST("ROMの最後の番地の命令の次はコード領域の先頭へ進む");
        rom_tail = '{movi(1, 32'd1)};
        code_area = '{movi(2, 32'd2), jmp(6'h00, im(32'd1))};
        run('{jmp(6'h00, im(CODE_AREA_PC - 1))});
        // ROMの最後の命令とコード領域の先頭の命令が順に実行される
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'd2);

        // ROMの最後の番地に複数サイクルかかるRMを置き，そこへジャンプする．RMの実行中に次の番地を先読みしない経路を通る
        `BEGIN_TEST("複数サイクルかかるROMの最後の命令の次もコード領域の先頭へ進む");
        rom_tail = '{rm(4'hf, 6'h00, 1, im(32'h100))};
        code_area = '{add(1, 1, 2), jmp(6'h00, im(32'd3))};
        run('{movi(3, 32'h55), wm(4'hf, 6'h00, 3, im(32'h100)), jmp(6'h00, im(CODE_AREA_PC - 1))});
        // RMで読んだ値をコード領域の先頭の命令が使える
        expect_end();
        expect_reg(2, 32'haa);

        // コード領域の最後の位置に1サイクルで終わる命令を置き，そこへジャンプする
        `BEGIN_TEST("コード領域の最後の命令の次へ進むと停止する");
        code_area_index = rom_p::CODE_AREA_PC_NUM - 1;
        code_area = '{movi(1, 32'd1)};
        run('{jmp(6'h00, im(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM - 1))});
        // 最後の命令は実行され，その次の番地で停止する
        expect_halt(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM);
        expect_reg(1, 32'd1);

        // コード領域の最後の位置に複数サイクルかかるWMを置き，そこへジャンプする
        `BEGIN_TEST("複数サイクルかかるコード領域の最後の命令の次へ進むと停止する");
        code_area_index = rom_p::CODE_AREA_PC_NUM - 1;
        code_area = '{wm(4'hf, 6'h00, 1, im(32'h100))};
        run('{movi(1, 32'd7), jmp(6'h00, im(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM - 1))});
        // 最後のWMは実行され，その次の番地で停止する
        expect_halt(CODE_AREA_PC + rom_p::CODE_AREA_PC_NUM);
        expect_mem32(32'h100, 32'd7);

        // コード領域の1番目にN系で未定義のfuncを持つ命令を置き，コード領域の先頭へジャンプする
        `BEGIN_TEST("コード領域の実行できない命令はそのPCで停止する");
        code_area = '{nop(), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM)};
        run('{jmp(6'h00, im(CODE_AREA_PC))});
        // その命令のPCで停止する
        expect_halt(CODE_AREA_PC + 1);
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
        test_io_type();
        // 命令の種類をまたぐテストケースを実行する
        test_register_access();
        test_operand_checks();
        test_pins();
        test_common();
        test_code_area();
        // 最後のテストケースを数える
        finish_test();

        // 合否の件数を表示し，不合格があれば失敗として終える
        $display("==== 合格 %0d件，不合格 %0d件 ====", passed, failed);
        if (failed > 0)
            $fatal(1, "不合格のテストケースがあります");
        $finish;
    end

endmodule
