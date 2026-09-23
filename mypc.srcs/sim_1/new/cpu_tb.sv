`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// CPUの命令の動作を検証するテストベンチ．
// CPU本体(cpu_sv)とメインメモリ(ram_sv)は実物を使い，ROMと除算IPをテストベンチ用のモデルに差し替える．
// テストケースごとにmachine.svhの関数で組んだ命令列をROMへ書き込んで実行し，実行後のレジスタ・メモリ・
// 停止の有無と番地・標準出力を期待値と比較する．最後に合否の件数を表示し，失敗があれば$fatalで終了する
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
    always #5 clk = ~clk;

    // ROM・メインメモリとの接続
    rom_read_if  rom_read();
    ram_read_if  ram_read();
    ram_write_if ram_write();

    // 除算IPとの接続
    logic [31:0] div_divisor_tdata, div_dividend_tdata, divu_divisor_tdata, divu_dividend_tdata;
    logic        div_divisor_tvalid, div_dividend_tvalid, divu_divisor_tvalid, divu_dividend_tvalid;
    logic [63:0] div_dout_tdata, divu_dout_tdata;
    logic        div_dout_tvalid, divu_dout_tvalid;

    // 標準入出力
    logic [31:0] stdin_tdata = '0;
    logic        stdin_tvalid = 1'b0;
    logic        stdin_tready;
    logic [31:0] stdout_tdata;
    logic [ 3:0] stdout_tkeep;
    logic        stdout_tlast;
    logic        stdout_tvalid;
    logic        stdout_tready = 1'b0;

    // ボード上の入出力ピン
    logic [ 3:0] btn = 4'b0;
    logic [ 1:0] sw = 2'b0;
    logic [ 3:0] led;
    logic [ 5:0] rgb_led;
    logic [ 7:0] ja, jb;
    logic [13:0] ar;
    logic        a, ar_sda, ar_scl, ck_mosi, ck_sck, ck_ss;
    logic        ck_miso = 1'b0;
    logic [26:8] gpio;

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

    ram_sv ram (
        .clk(clk), .resetn(resetn),
        .ram_read(ram_read),
        .ram_write(ram_write)
    );

    tb_rom rom (
        .clk(clk),
        .rom_read(rom_read)
    );

    // レイテンシはブロックダイアグラム上の除算IP(符号あり: top_div_gen_0_0，符号なし: top_div_gen_0_1)に合わせる
    tb_divider #(.LATENCY(36), .IS_SIGNED(1)) div_model (
        .aclk(clk), .aresetn(resetn),
        .s_axis_divisor_tdata(div_divisor_tdata),
        .s_axis_divisor_tvalid(div_divisor_tvalid),
        .s_axis_dividend_tdata(div_dividend_tdata),
        .s_axis_dividend_tvalid(div_dividend_tvalid),
        .m_axis_dout_tdata(div_dout_tdata),
        .m_axis_dout_tvalid(div_dout_tvalid)
    );
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
    int          stdin_delay = 0;  // 1つ前の受け渡しからtvalidを立てるまでに空けるサイクル数
    logic [31:0] stdout_log[$];    // 標準出力から受け取った値の列
    int          stdout_delay = 0; // tvalidを見てからtreadyを立てるまでのサイクル数．0ならtreadyを常に立てておく
    int          stdin_wait = 0;   // 標準入力でtvalidを立てるまでに待ったサイクル数
    int          stdout_wait = 0;  // 標準出力でtreadyを立てるまでに待ったサイクル数

    // 標準入力．値をtvalidとともに出し，tvalidとtreadyが揃ったサイクルに受け渡しを終えて次の値へ進む
    always @(posedge clk) begin
        if (!resetn) begin
            stdin_tvalid <= 1'b0;
            stdin_wait   <= 0;
        end
        else if (stdin_tvalid && stdin_tready) begin
            stdin_tvalid <= 1'b0;
            stdin_wait   <= 0;
        end
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

    // 標準出力．tvalidとtreadyが揃ったサイクルの値を記録する
    always @(posedge clk) begin
        if (!resetn) begin
            stdout_tready <= 1'b0;
            stdout_wait   <= 0;
        end
        else if (stdout_delay == 0) begin
            if (stdout_tvalid && stdout_tready)
                stdout_log.push_back(stdout_tdata);
            stdout_tready <= 1'b1;
        end
        else if (stdout_tvalid && stdout_tready) begin
            stdout_log.push_back(stdout_tdata);
            stdout_tready <= 1'b0;
            stdout_wait   <= 0;
        end
        else if (stdout_tvalid) begin
            if (stdout_wait >= stdout_delay)
                stdout_tready <= 1'b1;
            else
                stdout_wait <= stdout_wait + 1;
        end
    end

    // ===== テストケースの記述を短くする関数 =====

    // イミディエイトデータを使用するimm
    function automatic imm_t im(input logic [31:0] value);
        return {1'b1, value};
    endfunction

    // イミディエイトデータを使用しないimm
    localparam imm_t NO_IMM = 33'h0;

    // 即値をrdへ代入する
    function automatic machine_t movi(input addr_t rd, input logic [31:0] value);
        return mov(4'hf, 6'h00, rd, im(value));
    endfunction

    // レジスタrs1の値をrdへ代入する
    function automatic machine_t movr(input addr_t rd, input addr_t rs1);
        return mov(4'hf, rs1, rd, NO_IMM);
    endfunction

    // 各フィールドを直接指定して機械語を組む(machine.svhに関数のない，未定義のfuncなどを表すため)
    function automatic machine_t raw(
        input type_t m_type, input func_t func, input addr_t rs1, input addr_t rs2, input addr_t rd, input imm_t imm
    );
        return {m_type, func, 4'h0, rs1, rs2, rd, imm};
    endfunction

    // ===== 実行と結果の採取 =====

    typedef enum {ENDED, HALTED, TIMED_OUT} outcome_enum;  // 実行の終わり方

    outcome_enum outcome;                          // 直前の実行の終わり方
    register_t   regs[0:REGISTER_MAX_ADDR];        // 実行を終えた時点のレジスタの値
    int          end_pc;                           // 正常終了を表す，自分自身へジャンプする命令の番地

    // 現在のレジスタの値をregsへ写す
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

    // 命令列を実行する．append_endが1なら末尾に自分自身へジャンプする命令(正常終了)を付け，
    // その命令の実行に入った時点を正常終了とする．停止した場合は，停止した命令のクロックの直後
    // (レジスタが初期値へ戻る前)にレジスタを採取する．
    // 仕様上，停止した時点のレジスタの値は残らないが，CPUは停止を検出した次のクロックで初期値へ戻すため，
    // その間に採取すれば停止した番地と，停止した命令がレジスタを書き換えていないことを確認できる．
    // 停止と同じクロックで初期値へ戻す実装に変えた場合は，この採取方法を見直す必要がある
    task automatic run(input machine_t body[$], input bit append_end = 1'b1, input bit keep_ram = 1'b0);
        machine_t instructions[$] = body;

        end_pc = body.size();
        if (append_end)
            instructions.push_back(jmp(6'h00, im(end_pc)));

        // リセットを入れた状態でメモリとROMを準備する
        @(negedge clk);
        resetn = 1'b0;
        if (!keep_ram)
            clear_ram();
        rom.load(instructions);
        stdout_log.delete();
        repeat (2) @(negedge clk);
        resetn = 1'b1;

        // 停止・正常終了・打ち切りのいずれかに至るまで1サイクルずつ進める
        for (int cycle = 0; ; cycle++) begin
            @(posedge clk);
            #1;
            if (dut.alu_sv_0.is_halted) begin
                outcome = HALTED;
                break;
            end
            if (append_end && dut.alu_sv_0.register[PC_ADDR] == end_pc && dut.alu_sv_0.cpu_phase == CPU_EXECUTE) begin
                outcome = ENDED;
                break;
            end
            if (cycle >= MAX_CYCLES) begin
                outcome = TIMED_OUT;
                break;
            end
        end
        take_snapshot();
    endtask

    // ===== 合否の判定 =====

    string test_name = "";     // 実行中のテストケースの名前
    int    test_errors = 0;    // 実行中のテストケースで見つかった不一致の数
    bit    test_open = 1'b0;   // 集計していないテストケースがあるか
    int    passed = 0;         // 合格したテストケースの数
    int    failed = 0;         // 不合格だったテストケースの数

    // 実行中のテストケースを合否の件数へ集計する
    function automatic void finish_test();
        if (!test_open)
            return;
        if (test_errors == 0)
            passed++;
        else
            failed++;
        test_open = 1'b0;
    endfunction

    // 新しいテストケースを始める．標準入出力の相手は，入力なし・遅延なしの状態に戻す
    function automatic void begin_test(input string name);
        finish_test();
        test_name    = name;
        test_errors  = 0;
        test_open    = 1'b1;
        stdin_queue.delete();
        stdin_delay  = 0;
        stdout_delay = 0;
    endfunction

    // テストケースの名前を文字列リテラルで指定してbegin_testを呼ぶ．xsimは日本語の文字列リテラルを
    // string型の値として渡すと文字化けさせ，$sformatfの書式として渡した場合は正しく扱うため，書式を経由させる
    `define BEGIN_TEST(name) begin_test($sformatf(name))

    function automatic void fail(input string message);
        $error("[%s] %s", test_name, message);
        test_errors++;
    endfunction

    function automatic void expect_end();
        if (outcome != ENDED)
            fail($sformatf("正常終了していない(%s，PC=%0d)", outcome.name(), regs[PC_ADDR]));
    endfunction

    function automatic void expect_halt(input int pc);
        if (outcome != HALTED)
            fail($sformatf("停止していない(%s，PC=%0d)", outcome.name(), regs[PC_ADDR]));
        else if (regs[PC_ADDR] != pc)
            fail($sformatf("停止した番地: 期待値%0d，実際%0d", pc, regs[PC_ADDR]));
    endfunction

    function automatic void expect_reg(input addr_t addr, input logic [31:0] value);
        if (regs[addr] !== value)
            fail($sformatf("レジスタ0x%02h: 期待値0x%08h，実際0x%08h", addr, value, regs[addr]));
    endfunction

    // メインメモリのaddr番地の1バイト
    function automatic logic [7:0] ram_byte(input int addr);
        case (addr % 4)
            0: return ram.memory_lane_0[addr / 4];
            1: return ram.memory_lane_1[addr / 4];
            2: return ram.memory_lane_2[addr / 4];
            default: return ram.memory_lane_3[addr / 4];
        endcase
    endfunction

    function automatic void expect_mem(input int addr, input logic [7:0] value);
        if (ram_byte(addr) !== value)
            fail($sformatf("メモリ0x%04h番地: 期待値0x%02h，実際0x%02h", addr, value, ram_byte(addr)));
    endfunction

    // addr番地から4バイトを，下位バイトを小さい番地に置いた32ビット値として比較する
    function automatic void expect_mem32(input int addr, input logic [31:0] value);
        for (int i = 0; i < 4; i++)
            expect_mem(addr + i, value[i * 8 +: 8]);
    endfunction

    function automatic void expect_output(input logic [31:0] values[$]);
        if (stdout_log != values)
            fail($sformatf("標準出力: 期待値%p，実際%p", values, stdout_log));
    endfunction

    // ===== テストケース =====

    // 処理を実行しない(N系)
    task automatic test_n_type();
        `BEGIN_TEST("NOPは何も書き換えずに次の命令へ進む");
        run('{movi(1, 32'h1234), nop(), nop()});
        expect_end();
        expect_reg(1, 32'h1234);

        `BEGIN_TEST("N系で未定義のfuncは停止する");
        run('{nop(), raw(3'h0, 6'h01, 0, 0, 0, NO_IMM)});
        expect_halt(1);
    endtask

    // 演算系(P系)
    task automatic test_p_type();
        `BEGIN_TEST("AND/OR/XOR/NOT/NAND");
        run('{movi(1, 32'hf0f0_1234), movi(2, 32'hff00_ff00),
              and_(1, 2, 3), or_(1, 2, 4), xor_(1, 2, 5), not_(1, 6), nand_(1, 2, 7)});
        expect_end();
        expect_reg(3, 32'hf000_1200);
        expect_reg(4, 32'hfff0_ff34);
        expect_reg(5, 32'h0ff0_ed34);
        expect_reg(6, 32'h0f0f_edcb);
        expect_reg(7, 32'h0fff_edff);

        `BEGIN_TEST("ADD/SUBは32ビットで桁あふれする");
        run('{movi(1, 32'hffff_ffff), movi(2, 32'h1), movi(3, 32'd100), movi(4, 32'd58),
              add(1, 2, 5), sub(0, 2, 6), add(3, 4, 7), sub(3, 4, 8)});
        expect_end();
        expect_reg(5, 32'h0);
        expect_reg(6, 32'hffff_ffff);
        expect_reg(7, 32'd158);
        expect_reg(8, 32'd42);

        `BEGIN_TEST("MULは積の下位32ビットを格納する");
        run('{movi(1, 32'h0001_0001), movi(2, 32'hffff_fffd), movi(3, 32'd5),
              mul(1, 1, 4), mul(2, 3, 5), mul(3, 3, 6)});
        expect_end();
        expect_reg(4, 32'h0002_0001);
        expect_reg(5, 32'hffff_fff1);
        expect_reg(6, 32'd25);

        `BEGIN_TEST("DIVは0方向へ切り捨て，余りは被除数の符号に従う");
        run('{movi(1, 32'd7), movi(2, 32'd2), movi(3, -32'sd7), movi(4, -32'sd2),
              div(1, 2, 5, im(6)), div(3, 2, 7, im(8)), div(1, 4, 9, im(10)), div(3, 4, 11, im(12))});
        expect_end();
        expect_reg(5, 32'd3);
        expect_reg(6, 32'd1);
        expect_reg(7, -32'sd3);
        expect_reg(8, -32'sd1);
        expect_reg(9, -32'sd3);
        expect_reg(10, 32'd1);
        expect_reg(11, 32'd3);
        expect_reg(12, -32'sd1);

        `BEGIN_TEST("DIVはimm未使用なら余りを書き込まない");
        run('{movi(1, 32'd7), movi(2, 32'd2), movi(4, 32'h55), div(1, 2, 3, NO_IMM)});
        expect_end();
        expect_reg(3, 32'd3);
        expect_reg(4, 32'h55);
        expect_reg(0, 32'h0);

        `BEGIN_TEST("DIVで商と余りの格納先が同じなら余りが残る");
        run('{movi(1, 32'd7), movi(2, 32'd2), div(1, 2, 3, im(3))});
        expect_end();
        expect_reg(3, 32'd1);

        `BEGIN_TEST("DIVUは符号なしとして割る");
        run('{movi(1, 32'hffff_ffff), movi(2, 32'd2), movi(3, 32'h8000_0000), movi(4, 32'd3),
              divu(1, 2, 5, im(6)), divu(3, 4, 7, im(8))});
        expect_end();
        expect_reg(5, 32'h7fff_ffff);
        expect_reg(6, 32'd1);
        expect_reg(7, 32'h2aaa_aaaa);
        expect_reg(8, 32'd2);

        `BEGIN_TEST("DIVの0除算は商・余りを書き込まずに停止する");
        run('{movi(1, 32'd7), movi(3, 32'h77), movi(4, 32'h88), div(1, 0, 3, im(4))});
        expect_halt(3);
        expect_reg(3, 32'h77);
        expect_reg(4, 32'h88);

        `BEGIN_TEST("DIVUの0除算は停止する");
        run('{movi(1, 32'd7), movi(3, 32'h77), divu(1, 0, 3, im(4))});
        expect_halt(2);
        expect_reg(3, 32'h77);

        `BEGIN_TEST("DIVで符号ありの最小値を-1で割っても停止しない");
        run('{movi(1, 32'h8000_0000), movi(2, 32'hffff_ffff), div(1, 2, 3, im(4))});
        expect_end();

        `BEGIN_TEST("DIVの直後の命令は商と余りを読める(フォワーディング)");
        run('{movi(1, 32'd17), movi(2, 32'd5), div(1, 2, 3, im(4)), add(3, 4, 5), sub(3, 4, 6)});
        expect_end();
        expect_reg(5, 32'd5);
        expect_reg(6, 32'd1);

        `BEGIN_TEST("DIVの直後の命令は商と余りの格納先が同じなら余りを読む(フォワーディング)");
        run('{movi(1, 32'd17), movi(2, 32'd5), div(1, 2, 3, im(3)), movr(4, 3)});
        expect_end();
        expect_reg(4, 32'd2);

        `BEGIN_TEST("MULの直後の命令は積を読める");
        run('{movi(1, 32'd6), movi(2, 32'd7), mul(1, 2, 3), add(3, 3, 4)});
        expect_end();
        expect_reg(4, 32'd84);

        `BEGIN_TEST("P系で未定義のfuncは停止する");
        run('{movi(3, 32'h77), raw(3'h1, 6'h0a, 1, 2, 3, NO_IMM)});
        expect_halt(1);
        expect_reg(3, 32'h77);
    endtask

    // シフト系(S系)
    task automatic test_s_type();
        `BEGIN_TEST("SLL/SRL/SLA/SRAのシフト量を即値で指定する");
        run('{movi(1, 32'h8000_0001),
              sll(1, 0, 2, im(4)), srl(1, 0, 3, im(4)), sla(1, 0, 4, im(4)), sra(1, 0, 5, im(4))});
        expect_end();
        expect_reg(2, 32'h0000_0010);
        expect_reg(3, 32'h0800_0000);
        expect_reg(4, 32'h0000_0010);
        expect_reg(5, 32'hf800_0000);

        `BEGIN_TEST("SLL/SRL/SLA/SRAのシフト量をrs2で指定する");
        run('{movi(1, 32'h8000_0001), movi(6, 32'd4),
              sll(1, 6, 2, NO_IMM), srl(1, 6, 3, NO_IMM), sla(1, 6, 4, NO_IMM), sra(1, 6, 5, NO_IMM)});
        expect_end();
        expect_reg(2, 32'h0000_0010);
        expect_reg(3, 32'h0800_0000);
        expect_reg(4, 32'h0000_0010);
        expect_reg(5, 32'hf800_0000);

        `BEGIN_TEST("シフト量は下位5ビットだけを使う");
        run('{movi(1, 32'h8000_0001), movi(6, 32'd33), sll(1, 0, 2, im(33)), srl(1, 6, 3, NO_IMM)});
        expect_end();
        expect_reg(2, 32'h0000_0002);
        expect_reg(3, 32'h4000_0000);

        `BEGIN_TEST("S系で未定義のfuncは停止する");
        run('{raw(3'h2, 6'h04, 1, 0, 2, im(1))});
        expect_halt(0);
    endtask

    // 代入系(A系)
    task automatic test_a_type();
        `BEGIN_TEST("MOVは即値・レジスタの値を代入する");
        run('{movi(1, 32'hdead_beef), movr(2, 1)});
        expect_end();
        expect_reg(1, 32'hdead_beef);
        expect_reg(2, 32'hdead_beef);

        `BEGIN_TEST("MOVはmaskによらず全バイトへ書き込む");
        run('{mov(4'h0, 6'h00, 1, im(32'h1234_5678)), mov(4'h1, 6'h00, 2, im(32'h8765_4321))});
        expect_end();
        expect_reg(1, 32'h1234_5678);
        expect_reg(2, 32'h8765_4321);

        `BEGIN_TEST("MOVでPCを読むとその命令の番地が読める");
        run('{nop(), nop(), movr(1, PC_ADDR)});
        expect_end();
        expect_reg(1, 32'd2);

        `BEGIN_TEST("先読みされた命令がPCを読むとその命令の番地が読める");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), movr(4, PC_ADDR),
              rm(4'hf, 6'h00, 5, im(32'h100)), movr(6, PC_ADDR)});
        expect_end();
        expect_reg(4, 32'd3);
        expect_reg(6, 32'd5);

        // rs1・rs2のそれぞれにPCを指定し，r0(値0)との和としてPCを読む
        `BEGIN_TEST("先読みされた命令がrs1・rs2のどちらでPCを読んでもその命令の番地が読める");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), add(PC_ADDR, 0, 4),
              div(1, 2, 3, NO_IMM), add(0, PC_ADDR, 5)});
        expect_end();
        expect_reg(4, 32'd3);
        expect_reg(5, 32'd5);

        `BEGIN_TEST("書き込み不可のPCへのMOVは停止する");
        run('{nop(), movi(PC_ADDR, 32'd0)});
        expect_halt(1);

        `BEGIN_TEST("書き込み不可のFLGへのMOVは停止する");
        run('{movi(FLG_ADDR, 32'd1)});
        expect_halt(0);

        `BEGIN_TEST("A系で未定義のfuncは停止する");
        run('{raw(3'h3, 6'h01, 0, 0, 1, im(1))});
        expect_halt(0);
    endtask

    // 分岐系(F系)
    typedef struct {
        string       name;   // 比較方法の名前
        func_t       func;   // 比較方法
        logic [31:0] rs1;    // 比較する値1
        logic [31:0] rs2;    // 比較する値2
        bit          taken;  // 分岐するか
    } branch_case_t;

    task automatic test_f_type();
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

        // 比較が成立すれば2つ先の番地へ分岐し，不成立ならr3へ1を代入する命令を通る
        foreach (cases[i]) begin
            if (cases[i].taken)
                begin_test($sformatf("%s(0x%08h, 0x%08h)は分岐する", cases[i].name, cases[i].rs1, cases[i].rs2));
            else
                begin_test($sformatf("%s(0x%08h, 0x%08h)は分岐しない", cases[i].name, cases[i].rs1, cases[i].rs2));
            run('{movi(1, cases[i].rs1), movi(2, cases[i].rs2),
                  raw(3'h4, cases[i].func, 1, 2, 0, im(2)), movi(3, 32'd1)});
            expect_end();
            expect_reg(3, cases[i].taken ? 32'd0 : 32'd1);
        end

        `BEGIN_TEST("負のオフセットで後方へ分岐してループする");
        run('{movi(3, 32'd1), movi(2, 32'd5), add(1, 3, 1), ne(1, 2, im(-32'sd1))});
        expect_end();
        expect_reg(1, 32'd5);

        `BEGIN_TEST("F系でimm未使用は停止する");
        run('{eq(0, 0, 33'h0_0000_0002)});
        expect_halt(0);

        `BEGIN_TEST("F系で未定義のfuncは停止する");
        run('{raw(3'h4, 6'h0a, 0, 0, 0, im(2))});
        expect_halt(0);
    endtask

    // ジャンプ系(J系)
    task automatic test_j_type();
        `BEGIN_TEST("JMPは即値の番地へジャンプする");
        run('{jmp(6'h00, im(2)), movi(1, 32'd1)});
        expect_end();
        expect_reg(1, 32'd0);

        `BEGIN_TEST("JMPはレジスタの番地へジャンプする");
        run('{movi(2, 32'd3), jmp(2, NO_IMM), movi(1, 32'd1)});
        expect_end();
        expect_reg(1, 32'd0);

        `BEGIN_TEST("CALLは戻り先をスタックへ積み，RETで戻る");
        run('{call(6'h00, im(3)), movr(5, SP_ADDR), jmp(6'h00, im(7)),
              movr(2, SP_ADDR), rmr(4'hf, SP_ADDR, 3, im(0)), movi(1, 32'd1), ret()});
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(2, 32'hfffc);
        expect_reg(3, 32'd1);
        expect_reg(5, 32'h1_0000);
        expect_reg(SP_ADDR, 32'h1_0000);
        expect_mem32(32'hfffc, 32'd1);

        `BEGIN_TEST("CALLはレジスタの番地を呼び出せる");
        run('{movi(4, 32'd4), call(4, NO_IMM), movr(5, SP_ADDR), jmp(6'h00, im(6)),
              movi(1, 32'd1), ret()});
        expect_end();
        expect_reg(1, 32'd1);
        expect_reg(5, 32'h1_0000);
        expect_mem32(32'hfffc, 32'd2);

        // r1を1ずつ減らしながら自分自身を呼び出し，r2に呼び出した段数，r4に戻った段数を数える
        `BEGIN_TEST("12段にネストした関数呼び出しからすべて戻る");
        run('{movi(3, 32'd1), movi(1, 32'd12), call(6'h00, im(4)), jmp(6'h00, im(10)),
              eq(1, 0, im(5)), sub(1, 3, 1), add(2, 3, 2), call(6'h00, im(4)), add(4, 3, 4), ret()});
        expect_end();
        expect_reg(1, 32'd0);
        expect_reg(2, 32'd12);
        expect_reg(4, 32'd12);
        expect_reg(SP_ADDR, 32'h1_0000);
        expect_mem32(32'hfffc, 32'd3);
        expect_mem32(32'h1_0000 - 13 * 4, 32'd8);

        `BEGIN_TEST("空のスタックでのRETは停止する");
        run('{nop(), ret()});
        expect_halt(1);
        expect_reg(SP_ADDR, 32'h1_0000);

        `BEGIN_TEST("スタックの積み先がメモリの範囲外になるCALLは書き込まずに停止する");
        run('{movi(SP_ADDR, 32'd0), call(6'h00, im(0))});
        expect_halt(1);
        expect_reg(SP_ADDR, 32'd0);
        expect_mem32(32'hfffc, 32'd0);

        `BEGIN_TEST("ROMの命令数の範囲外へのジャンプは停止する");
        run('{jmp(6'h00, im(100))});
        expect_halt(100);

        `BEGIN_TEST("ROMのビット幅を超える番地へのジャンプは停止する");
        run('{jmp(6'h00, im(32'h1_0000))});
        expect_halt(32'h1_0000);

        `BEGIN_TEST("J系で未定義のfuncは停止する");
        run('{raw(3'h5, 6'h03, 0, 0, 0, im(1))});
        expect_halt(0);
    endtask

    // メモリ系(M系)
    task automatic test_m_type();
        `BEGIN_TEST("WM/RMは即値・レジスタの番地を読み書きする");
        run('{movi(1, 32'h1122_3344), movi(2, 32'h104),
              wm(4'hf, 6'h00, 1, im(32'h100)), wm(4'hf, 2, 1, NO_IMM),
              rm(4'hf, 6'h00, 3, im(32'h100)), rm(4'hf, 2, 4, NO_IMM)});
        expect_end();
        expect_mem32(32'h100, 32'h1122_3344);
        expect_mem32(32'h104, 32'h1122_3344);
        expect_reg(3, 32'h1122_3344);
        expect_reg(4, 32'h1122_3344);

        `BEGIN_TEST("RMはmaskのバイトだけを読み，それ以外のバイトを0にする");
        run('{movi(1, 32'h1122_3344), wm(4'hf, 6'h00, 1, im(32'h100)),
              rm(4'b0001, 6'h00, 2, im(32'h101)), rm(4'b0011, 6'h00, 3, im(32'h102)),
              rm(4'b0110, 6'h00, 4, im(32'h100))});
        expect_end();
        expect_reg(2, 32'h0000_0033);
        expect_reg(3, 32'h0000_1122);
        expect_reg(4, 32'h0022_3300);

        `BEGIN_TEST("WMはmaskのバイトだけを書き込み，それ以外の番地を保持する");
        run('{movi(1, 32'h1122_3344), wm(4'hf, 6'h00, 1, im(32'h100)),
              movi(2, 32'haabb_ccdd), wm(4'b0010, 6'h00, 2, im(32'h100)),
              movi(3, 32'h0000_00ee), wm(4'b0001, 6'h00, 3, im(32'h103))});
        expect_end();
        expect_mem32(32'h100, 32'hee22_cc44);

        `BEGIN_TEST("RMR/WMRはrs1にimmを足した番地を読み書きする");
        run('{movi(1, 32'h200), movi(2, 32'h5566_7788), movi(3, 32'h99aa_bbcc),
              wmr(4'hf, 1, 2, im(-32'sd4)), wmr(4'hf, 1, 3, im(32'd8)),
              rmr(4'hf, 1, 4, im(-32'sd4)), rmr(4'hf, 1, 5, im(32'd8))});
        expect_end();
        expect_mem32(32'h1fc, 32'h5566_7788);
        expect_mem32(32'h208, 32'h99aa_bbcc);
        expect_reg(4, 32'h5566_7788);
        expect_reg(5, 32'h99aa_bbcc);

        `BEGIN_TEST("RMの直後の命令は読んだ値を使える(フォワーディング)");
        run('{movi(1, 32'd21), wm(4'hf, 6'h00, 1, im(32'h100)), rm(4'hf, 6'h00, 2, im(32'h100)), add(2, 2, 3)});
        expect_end();
        expect_reg(3, 32'd42);

        `BEGIN_TEST("WMの直後の命令はレジスタを正しく読める");
        run('{movi(1, 32'd21), wm(4'hf, 6'h00, 1, im(32'h100)), add(1, 1, 3)});
        expect_end();
        expect_reg(3, 32'd42);

        `BEGIN_TEST("メモリの範囲外へのWMは書き込まずに停止する");
        run('{movi(1, 32'hdead_beef), wm(4'hf, 6'h00, 1, im(32'h1_0000))});
        expect_halt(1);
        expect_mem32(32'h0, 32'h0);

        `BEGIN_TEST("メモリの範囲外からのRMは停止する");
        run('{movi(2, 32'h77), rm(4'hf, 6'h00, 2, im(32'h1_0000))});
        expect_halt(1);
        expect_reg(2, 32'h77);

        `BEGIN_TEST("足した番地がメモリの範囲外になるWMRは書き込まずに停止する");
        run('{movi(1, 32'hfffc), movi(2, 32'hdead_beef), wmr(4'hf, 1, 2, im(32'd4))});
        expect_halt(2);
        expect_mem32(32'h0, 32'h0);

        `BEGIN_TEST("BRMは停止する");
        run('{brm(4'hf, 0, 0, 1, im(0))});
        expect_halt(0);

        `BEGIN_TEST("BWMは停止する");
        run('{bwm(4'hf, 0, 0, 1, im(0))});
        expect_halt(0);

        `BEGIN_TEST("RMRでimm未使用は停止する");
        run('{rmr(4'hf, 0, 1, NO_IMM)});
        expect_halt(0);

        `BEGIN_TEST("WMRでimm未使用は停止する");
        run('{wmr(4'hf, 0, 1, NO_IMM)});
        expect_halt(0);

        `BEGIN_TEST("ワード境界をまたぐmaskは停止しない");
        run('{movi(1, 32'h1122_3344), wm(4'b0011, 6'h00, 1, im(32'h103)), rm(4'b0011, 6'h00, 2, im(32'h103))});
        expect_end();

        `BEGIN_TEST("M系で未定義のfuncは停止する");
        run('{raw(3'h6, 6'h06, 0, 0, 1, im(0))});
        expect_halt(0);
    endtask

    // 標準入出力系(IO系)
    task automatic test_io_type();
        `BEGIN_TEST("SCANは入力が届くまで待って受け取る");
        stdin_queue = '{32'h41, 32'h42};
        stdin_delay = 20;
        run('{scan(1), scan(2), add(1, 2, 3)});
        expect_end();
        expect_reg(1, 32'h41);
        expect_reg(2, 32'h42);
        expect_reg(3, 32'h83);

        // SCANの実行が2サイクルで終わり，次の命令の先読みが間に合わない経路を通る
        `BEGIN_TEST("SCANは既に届いている入力を受け取る");
        stdin_queue = '{32'h41, 32'h42};
        stdin_delay = 0;
        run('{scan(1), scan(2), add(1, 2, 3)});
        expect_end();
        expect_reg(1, 32'h41);
        expect_reg(2, 32'h42);
        expect_reg(3, 32'h83);

        `BEGIN_TEST("PRINTは受け取られるまで待って即値・レジスタの値を出力する");
        stdout_delay = 20;
        run('{movi(1, 32'h43), print(6'h00, im(32'h41)), print(1, NO_IMM), movi(2, 32'd1)});
        expect_end();
        expect_output('{32'h41, 32'h43});
        expect_reg(2, 32'd1);

        // PRINTの実行が2サイクルで終わり，次の命令の先読みが間に合わない経路を通る
        `BEGIN_TEST("PRINTはすぐに受け取られる場合も即値・レジスタの値を出力する");
        stdout_delay = 0;
        run('{movi(1, 32'h43), print(6'h00, im(32'h41)), print(1, NO_IMM), movi(2, 32'd1)});
        expect_end();
        expect_output('{32'h41, 32'h43});
        expect_reg(2, 32'd1);

        `BEGIN_TEST("IO系で未定義のfuncは停止する");
        run('{raw(3'h7, 6'h02, 0, 0, 0, NO_IMM)});
        expect_halt(0);
    endtask

    // 仕様(register.md)の表に基づき，その番地のレジスタを命令のオペランドとして読めるか
    function automatic bit spec_readable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h10], [6'h1c:6'h21], 6'h29, 6'h2a, 6'h31: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 仕様(register.md)の表に基づき，その番地のレジスタを命令のオペランドとして書けるか
    function automatic bit spec_writable(input addr_t addr);
        case (addr) inside
            [6'h00:6'h10], 6'h1d, 6'h1e, [6'h22:6'h28], 6'h2a, [6'h2d:6'h30], 6'h33: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // 全番地のレジスタについて，MOVで読む・書くと仕様どおりに実行を続けるか停止するか
    task automatic test_register_access();
        for (int addr = 0; addr <= REGISTER_MAX_ADDR; addr++) begin
            if (spec_readable(addr))
                begin_test($sformatf("レジスタ0x%02hは読み出せる", addr));
            else
                begin_test($sformatf("レジスタ0x%02hを読み出すと停止する", addr));
            run('{movi(1, 32'h77), movr(2, addr)});
            if (spec_readable(addr)) begin
                expect_end();
            end
            else begin
                expect_halt(1);
                expect_reg(2, 32'h0);
            end

            if (spec_writable(addr))
                begin_test($sformatf("レジスタ0x%02hへ書き込める", addr));
            else
                begin_test($sformatf("レジスタ0x%02hへ書き込むと停止する", addr));
            run('{nop(), movi(addr, 32'h0)});
            if (spec_writable(addr))
                expect_end();
            else
                expect_halt(1);
        end
    endtask

    // ボード上の入出力ピンにつながるレジスタ
    task automatic test_pins();
        `BEGIN_TEST("出力用のレジスタへの書き込みが対応するピンに出る");
        run('{movi(LED_ADDR, 32'h5), movi(RGB_LED_ADDR, 32'h2a), movi(PMOD_A_ADDR, 32'ha5), movi(PMOD_B_ADDR, 32'h5a),
              movi(AR_LOW_ADDR, 32'h81), movi(AR_HIGH_ADDR, 32'h21), movi(AR_MISC_ADDR, 32'b101),
              movi(SPI_ADDR, 32'b0110), movi(GPIO1_ADDR, 32'h81), movi(GPIO2_ADDR, 32'h42), movi(GPIO3_ADDR, 32'h5)});
        expect_end();
        if (led !== 4'h5)
            fail($sformatf("LED: 期待値0x5，実際0x%h", led));
        if (rgb_led !== 6'h2a)
            fail($sformatf("RGB LED: 期待値0x2a，実際0x%h", rgb_led));
        if (ja !== 8'ha5 || jb !== 8'h5a)
            fail($sformatf("Pmod A・B: 期待値0xa5・0x5a，実際0x%h・0x%h", ja, jb));
        if (ar !== 14'h2181)
            fail($sformatf("AR0〜AR13: 期待値0x2181，実際0x%h", ar));
        if ({a, ar_sda, ar_scl} !== 3'b101)
            fail($sformatf("A・AR_SDA・AR_SCL: 期待値101，実際%b", {a, ar_sda, ar_scl}));
        if ({ck_sck, ck_mosi, ck_ss} !== 3'b110)
            fail($sformatf("SPI(SCK,MOSI,SS): 期待値110，実際%b", {ck_sck, ck_mosi, ck_ss}));
        if (gpio !== 19'h54281)
            fail($sformatf("GPIO8〜GPIO26: 期待値0x54281，実際0x%h", gpio));

        `BEGIN_TEST("タクトスイッチ・DIPスイッチの状態を読める");
        btn = 4'b1010;
        sw  = 2'b01;
        run('{nop(), movr(1, BTN_ADDR), movr(2, SW_ADDR)});
        btn = 4'b0;
        sw  = 2'b0;
        expect_end();
        expect_reg(1, 32'b1010);
        expect_reg(2, 32'b01);

        `BEGIN_TEST("MISOピンの値がSPIのレジスタのビット3に読める");
        ck_miso = 1'b1;
        run('{nop(), nop(), movr(1, SPI_ADDR)});
        ck_miso = 1'b0;
        expect_end();
        expect_reg(1, 32'b1001);
    endtask

    // 命令の種類によらない停止の条件と，停止後の挙動
    task automatic test_common();
        `BEGIN_TEST("使わないフィールドでもレジスタ番地の上限を超えると停止する");
        run('{nop(), raw(3'h0, NOP, 6'h35, 0, 0, NO_IMM)});
        expect_halt(1);

        // 複数サイクルかかるDIVの実行中に，次の未定義funcの命令を先読みして実行できないと判定する経路を通る
        `BEGIN_TEST("先読みした命令が実行できない場合もその番地で停止する");
        run('{movi(1, 32'd9), movi(2, 32'd4), div(1, 2, 3, NO_IMM), raw(3'h1, 6'h0a, 1, 2, 4, NO_IMM)});
        expect_halt(3);
        expect_reg(3, 32'd2);
        expect_reg(4, 32'd0);

        `BEGIN_TEST("ROMの最後の命令の次へ進むと停止する");
        run('{nop(), nop()}, 1'b0);
        expect_halt(2);

        // 最後の命令が複数サイクルかかる場合は，範囲外の番地を先読みした経路を通る
        `BEGIN_TEST("複数サイクルかかる最後の命令の次へ進むと停止する");
        run('{movi(1, 32'h1), wm(4'hf, 6'h00, 1, im(32'h100))}, 1'b0);
        expect_halt(2);
        expect_mem32(32'h100, 32'h1);

        `BEGIN_TEST("停止するとレジスタが初期値へ戻り，リセットまで停止が続く");
        run('{movi(1, 32'd5), movi(SP_ADDR, 32'h100), movi(PC_ADDR, 32'd0)});
        expect_halt(2);
        expect_reg(1, 32'd5);
        @(posedge clk);
        #1;
        take_snapshot();
        expect_reg(1, 32'd0);
        expect_reg(SP_ADDR, 32'h1_0000);
        expect_reg(PC_ADDR, 32'd0);
        if (dut.alu_sv_0.is_halted !== 1'b1)
            fail($sformatf("リセットを入れる前に停止が解除された"));

        // メモリの値を1増やしてから停止するプログラムを，メモリを消さずに2回実行する
        `BEGIN_TEST("停止後のリセットでメモリを保持したまま先頭から実行し直す");
        run('{movi(3, 32'd1), rm(4'hf, 6'h00, 1, im(32'h100)), add(1, 3, 1),
              wm(4'hf, 6'h00, 1, im(32'h100)), movi(PC_ADDR, 32'd0)});
        expect_halt(4);
        expect_mem32(32'h100, 32'd1);
        run('{movi(3, 32'd1), rm(4'hf, 6'h00, 1, im(32'h100)), add(1, 3, 1),
              wm(4'hf, 6'h00, 1, im(32'h100)), movi(PC_ADDR, 32'd0)}, 1'b1, 1'b1);
        expect_halt(4);
        expect_mem32(32'h100, 32'd2);
    endtask

    initial begin
        test_n_type();
        test_p_type();
        test_s_type();
        test_a_type();
        test_f_type();
        test_j_type();
        test_m_type();
        test_io_type();
        test_register_access();
        test_pins();
        test_common();
        finish_test();

        $display("==== 合格 %0d件，不合格 %0d件 ====", passed, failed);
        if (failed > 0)
            $fatal(1, "不合格のテストケースがあります");
        $finish;
    end

endmodule
