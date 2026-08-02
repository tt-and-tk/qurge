`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2025/04/20 16:41:07
// Design Name:
// Module Name: alu_sv
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


`include "rom.svh"
`include "decorder.svh"
`include "alu.svh"
`include "ram.svh"
`include "machine.svh"
`include "register.svh"

// 命令パイプライン処理の概要(FETCH/CHECK/EXECUTEの3フェーズを基本とし，以下の3段階でフェーズを
// 省略する)．
//
// 1. 次に実行する命令の番地の早期確定: 実行中の命令がこのサイクルにプログラムカウンタへ書き込む
//    値を，実行と同じサイクルで算出する．比較の成立・不成立や，ジャンプ先・関数の戻り先も
//    この時点で確定するため，どの命令の実行中であっても次に実行すべき命令の番地が分かる．
// 2. 命令フェッチの先読み: 1で求めた番地を使って，実行中に次の命令をあらかじめROMから取得して
//    おく．次の命令へ進む際に取得済みの内容があれば，FETCHフェーズを省略しCHECKから開始する．
// 3. 次の命令の解析の先読みとフォワーディング: 先読みしておいた命令(まだ先読みが済んでいない
//    場合は，このサイクルにROMから取得中の命令)の内容を，実行中の命令とは別の回路であらかじめ
//    解析しておく．解析の結果，読み出し・書き込みに使うレジスタ番地がすべて有効だと分かれば，
//    今完了する命令がこのサイクルにレジスタへ書き込む値を，レジスタの読み出し結果の代わりに
//    そのまま使う(フォワーディング)．これにより次の命令はCHECKフェーズも省略して直接EXECUTEから
//    開始できる．
//
// ここで言うフォワーディングとは，ある命令が書き込む値を，レジスタを読み直さずに次の命令へ直接
// 渡すことを指す．ある命令が結果を書き込んだレジスタを次の命令が計算の元として読む場合(足し算の
// 結果を入れたレジスタを，次の命令が引き算の元として読む場合など)に必要になる．書き込んだ値が
// レジスタから読めるようになるのはサイクルの終わりで，同じサイクルに読んでも1つ前の値しか得られ
// ないため，そのままでは書き込みが反映されるのを1サイクル待つことになる．書き込む値そのものを
// 次の命令へ渡すことで，この待ちを挟まずに次の命令を実行できるようにする．
//
// 次に実行する命令の番地は常に確定しているため，取得した命令が無駄になって破棄が必要になることは
// ない．この結果，本来FETCH→CHECK→EXECUTEの3サイクルを要する命令でも，前の命令の完了直後の
// サイクルから次の命令のEXECUTEを直接開始できる(実質1サイクルで実行完了)．FETCHフェーズを経由
// するのはリセット直後の1命令目のみで，CHECKフェーズを経由するのはその1命令目と，解析の結果
// そのままでは実行できないと分かった命令(CHECKで強制リセットへ落とす)のみ．
module alu_sv (
    input logic clk,
    input logic resetn,

    rom_read_if.master rom_read,
    command_if.master command,

    // メモリ読み込みインターフェース
    ram_read_if.master ram_read,
    // メモリ書き込みインターフェース
    ram_write_if.master ram_write,

    input  logic [3:0] btn,
    input  logic [1:0] sw,
    output logic [3:0] led,
    output logic [5:0] rgb_led,
    output logic [7:0] number,

    // 割り算回路用
    output logic [31:0] divisor_tdata,
    output logic        divisor_tvalid,
    output logic [31:0] dividend_tdata,
    output logic        dividend_tvalid,
    input  logic [63:0] dout_tdata,
    input  logic        dout_tvalid,

    // 標準入出力
    input  logic [31:0] stdin_tdata,
    input  logic [ 3:0] stdin_tkeep,
    input  logic        stdin_tlast,
    output logic        stdin_tready,
    input  logic        stdin_tvalid,

    output logic [31:0] stdout_tdata,
    output logic [ 3:0] stdout_tkeep,
    output logic        stdout_tlast,
    input  logic        stdout_tready,
    output logic        stdout_tvalid
    );

    // import文
    import alu_p::*;
    import ram_p::*;
    import machine_p::*;
    import util_p::*;

    // 内部レジスタ
    register_t register[6'h34:0] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};

    // 実行フェーズ
    cpu_phase_enum cpu_phase = CPU_FETCH;

    // 実行前のものをいったん保存しておく
    machine_p::machine_t ir = nop();     // 命令
    // 実行中に先読みしておいた命令を保持するバッファ．複数サイクルにまたがる命令の待機中に埋まり，
    // 1サイクルで完了する命令の実行中は埋まらないまま次の命令へ進む．
    machine_p::machine_t ir_prefetched = nop();
    logic ir_prefetched_valid = 1'b0;    // ir_prefetchedが先読み済みの有効な命令かどうか
    register_t rs1_val_r = '0;
    register_t rs2_val_r = '0;
    machine_p::addr_t rd_addr_r = '0;
    machine_p::func_t func_r = '0;
    machine_p::imm_t imm_r = '0;
    machine_p::mask_t mask_r = '0;

    // メモリ読み込み・書き出し状態
    util_p::state_enum ram_read_state = IDLE;
    util_p::state_enum ram_write_state = IDLE;

    // 標準入出力の入出力状態
    util_p::state_enum stdin_state = IDLE;
    util_p::state_enum stdout_state = IDLE;

    // 割り算回路の状態
    util_p::state_enum div_state = IDLE;

    // 実行できない命令を検出して停止していることを表すフラグ．
    // 立っている間はリセット処理が働き続け，外部からのリセットが入るまで下りない
    logic force_reset = 1'b0;

    // 次命令を先読みしてよいかどうかを示すフラグ
    logic can_prefetch;
    assign can_prefetch = (cpu_phase == CPU_EXECUTE)    // 実行フェーズの間のみ先読みが可能
        && !ir_prefetched_valid;                        // 既に先読み済みの命令があれば行わない

    // 分岐命令の比較結果がtrueかどうか(定義されていない比較方法はfalseとして扱う)
    logic is_branch_taken;
    assign is_branch_taken = (command.m_type == F_TYPE)
        && ((func_r == EQ  && rs1_val_r == rs2_val_r)
         || (func_r == NE  && rs1_val_r != rs2_val_r)
         || (func_r == LT  && rs1_val_r <  rs2_val_r)
         || (func_r == GT  && rs1_val_r >  rs2_val_r)
         || (func_r == ELT && rs1_val_r <= rs2_val_r)
         || (func_r == EGT && rs1_val_r >= rs2_val_r));

    // 飛び先を指定してプログラムカウンタを書き換える命令かどうか(定義されていない命令コードはfalseとして扱う)
    logic is_jumping;
    assign is_jumping = (command.m_type == J_TYPE)
        && (func_r == JMP || func_r == CALL || func_r == RET);

    // 移動する命令の飛び先．関数リターンはスタックポインタが指す戻り先，
    // それ以外はイミディエイトデータまたはレジスタで指定された番地になる
    register_t jump_target;
    assign jump_target = (func_r == RET) ? register[register[SP_ADDR]]
                       : imm_r[32]       ? imm_r[31:0]
                       : rs1_val_r;

    // 実行中の命令がこのサイクルにプログラムカウンタへ書き込む値．プログラムカウンタへの代入と
    // 次の命令の先読み先の両方がこの値を参照することで，飛び先を求める式を1箇所にまとめている．
    // 参照してよいのは実行フェーズの間だけ．それ以外のフェーズでは，命令タイプはこれから確認する
    // 命令のものであるのに対し，比較と飛び先の指定に使う値は直前に実行した命令のものが残っており，
    // 別々の命令に由来する値から番地を求めることになるため，結果に意味がない．
    register_t next_pc;
    assign next_pc = is_branch_taken ? register[PC_ADDR] + imm_r[31:0]  // 比較結果がtrueの分岐は指定されたぶん離れた番地へ
                   : is_jumping      ? jump_target                      // 移動する命令は指定された飛び先へ
                   : register[PC_ADDR] + 1;                             // それ以外は次の番地へ進む

    // 今サイクルにadvance_to_next_instruction()が呼ばれたかどうかを示すスクラッチ変数(ブロッキング代入で使用)．
    // CPU_EXECUTE突入のたびに先頭で0へ戻し，末尾の先読みトリガーの可否判定にのみ使う．
    logic advancing;

    // 演算系・シフト系・代入系の結果を，レジスタへの書き込みと次の命令へのフォワーディングの
    // 両方から同じ値を参照できるように一旦保持しておくスクラッチ変数(ブロッキング代入で使用)．
    register_t write_value = '0;

    // 有効なfuncによる演算・シフト結果をレジスタへ書き込み・フォワーディングしてよい状態ならtrue．
    // funcが不正(unique caseのdefaultに該当)だった場合はfalseとし，write_valueに前回までの値が
    // 残ったまま書き込み・フォワーディングされてしまうのを防ぐ(ブロッキング代入で使用)．
    logic write_valid;

    // 次の命令として実際に採用する機械語．ir_prefetchedが先読み済みならそれを，
    // まだ先読みできていなければROMから今サイクルに取得中の機械語をそのまま採用する．
    machine_p::machine_t ir_next;
    assign ir_next = ir_prefetched_valid ? ir_prefetched : rom_read.machine;

    // 次段命令(ir_next)専用のデコーダー．現在実行中の命令のデコード(command)とは独立に，
    // 次段のレジスタ読み出し・書き込み可否をEXECUTE中に前もって確認するために用いる．
    command_if command_next();
    assign command_next.machine = ir_next;
    decorder_sv decorder_sv_next(
        .resetn(resetn),
        .command(command_next)
    );

    // 命令完了時，次の命令へ遷移する処理をまとめたタスク．
    // 次の命令には，先読み済みの機械語か今サイクルにROMから取得中の機械語を使う．
    // 実行可能だと分かればFETCHとCHECKをどちらも省略してEXECUTEへ直接進み，実行できないと
    // 分かった場合はCHECKへ進む(CHECKで強制リセットへ落とす)．
    //
    // 引数は，今回完了する命令がこのサイクルにレジスタへ書き込む内容(書き込み先アドレスと
    // 書き込む値の組)を表す．割り算だけは商と余りを同じサイクルに書き込むため，余りの組も
    // あわせて受け取る．割り算以外の命令は結果の組だけを有効にして呼び出し，レジスタへの
    // 書き込みを伴わない命令はどちらの組も無効にして呼び出す．
    task automatic advance_to_next_instruction(
        input logic             result_write_valid,
        input machine_p::addr_t result_write_addr,
        input register_t        result_write_value,
        // ここから下の3つは割り算でのみ使用する
        input logic             remainder_write_valid,
        input machine_p::addr_t remainder_write_addr,
        input register_t        remainder_write_value
    );
        advancing = 1'b1;

        // 次の命令を解析し，実行可能かどうかを判定する
        if (is_instruction_executable(
            command_next.m_type, command_next.func,
            command_next.rs1, command_next.rs2, command_next.rd, command_next.imm
        )) begin
            // 次段命令の読み出し・書き込み可否は確認済みのため，CHECKを省略して直接EXECUTEへ進む．
            // 読み出しアドレスが今サイクルの書き込み先と重なる場合は，レジスタから読んだ値では
            // なく今サイクルに書き込む値をそのまま使う(フォワーディング)．
            // 割り算で商と余りに同じ番地を指定した場合は余りを優先する．レジスタには後から
            // 代入する余りが残るため，商を優先すると次の命令が読む値とレジスタの中身が
            // 食い違ってしまう．
            // プログラムカウンタは書き込み先レジスタの指定を経由せずに今サイクルへ更新されるため，
            // 次の命令が実行される時点の値(=このサイクルに書き込む値)をそのまま渡す．
            rs1_val_r <= (command_next.rs1 == PC_ADDR) ? next_pc
                : (remainder_write_valid && remainder_write_addr == command_next.rs1) ? remainder_write_value
                : (result_write_valid    && result_write_addr    == command_next.rs1) ? result_write_value
                : register[command_next.rs1];
            rs2_val_r <= (command_next.rs2 == PC_ADDR) ? next_pc
                : (remainder_write_valid && remainder_write_addr == command_next.rs2) ? remainder_write_value
                : (result_write_valid    && result_write_addr    == command_next.rs2) ? result_write_value
                : register[command_next.rs2];
            rd_addr_r <= command_next.rd;
            func_r    <= command_next.func;
            imm_r     <= command_next.imm;
            mask_r    <= command_next.mask;
            ir        <= ir_next;
            cpu_phase <= CPU_EXECUTE;
        end
        // 実行できない命令は以下のいずれかの経路でCHECKへ進み，そこで強制リセットへ落とす
        else if (ir_prefetched_valid) begin
            // 前サイクル以前に先読みが完了している場合，それを採用する
            ir <= ir_prefetched;
            cpu_phase <= CPU_CHECK;
        end
        else begin
            // 今サイクルに先読みが完了する場合，レジスタを経由せず直接採用する．
            // このときROMへは次に実行する命令の番地を出しているため，読み出し結果がそのまま次の命令になる
            ir <= rom_read.machine;
            cpu_phase <= CPU_CHECK;
        end

        // 先読み済みだった命令は消費し終えたので無効化する(今サイクルに新たに先読みが成立すれば，末尾のブロックで改めて1にする)
        ir_prefetched_valid <= 1'b0;
    endtask

    // 組み合わせ回路
    always_comb begin
        // 機械語を分解してもらう
        command.machine = ir;

        // メモリのバースト転送はオミットする
        ram_read.last = 1'b1;
        ram_write.last = 1'b1;

        // デバッグ用
        // led     = register[6'h05][3:0];
        led = register[6'h32][3:0];
        rgb_led = 6'h0;
        // number  = register[PC_ADDR][7:0];
        number  = register[6'h31][7:0];

        // ROMへ番地を出力する
        if (can_prefetch) begin
            // 実行フェーズにあり，まだ次の命令を先読みしていない場合は，次に実行する命令を取得する
            rom_read.pc = next_pc;
        end
        else if (ir_prefetched_valid) begin
            // 既に先読み済みの命令がある場合は，取得した命令を使わないため番地を出さない
            rom_read.pc = '0;
        end
        else begin
            // 実行フェーズにない場合は，これから実行する命令自身を取得する(プログラムの1命令目のフェッチ)
            rom_read.pc = register[PC_ADDR];
        end

        // 標準入出力
        stdout_tkeep = 4'hf;
        stdout_tlast = 1'b1;
    end

    // 順序回路
    always_ff @(posedge clk) begin
        // リセット
        if (!resetn || force_reset) begin
            // 実行状態をリセット
            cpu_phase <= CPU_FETCH;
            ir <= nop();
            ir_prefetched <= nop();
            ir_prefetched_valid <= 1'b0;
            rs1_val_r <= '0;
            rs2_val_r <= '0;
            rd_addr_r <= '0;
            func_r <= '0;
            imm_r <= '0;
            mask_r <= '0;

            // 割り算回路用
            divisor_tdata <= '0;
            divisor_tvalid <= 1'b0;
            dividend_tdata <= '0;
            dividend_tvalid <= 1'b0;
            div_state <= IDLE;

            // メモリの読み込み・書き出し状態をリセット
            ram_read_state <= IDLE;
            ram_write_state <= IDLE;

            // 標準入出力の状態をリセット
            stdin_state <= IDLE;
            stdout_state <= IDLE;

            // 標準入出力の受け渡しを行っていることを表す信号も下ろす．
            // 上がったままだと，復帰後に受け取った入力が読まれないまま捨てられたり，
            // 送るつもりのないデータが出力されたりする
            stdin_tready <= 1'b0;
            stdout_tvalid <= 1'b0;
            stdout_tdata <= '0;

            // メモリ読み書き
            ram_read.address <= 0;
            ram_read.mask <= 0;
            ram_read.valid <= 0;
            ram_write.address <= 0;
            ram_write.data <= 0;
            ram_write.mask <= 0;
            ram_write.valid <= 0;

            // レジスタ(標準入出力の状態を写しているものを除く．
            // これらは実行中に毎サイクル入出力信号から書き込まれるため初期化しても即座に上書きされる)
            for (logic [5:0] i = 0; i <= 6'h30; i++) begin
                register[i] <= 0;
            end
            // スタックポインタは空を表す自身の番地で初期化する
            register[SP_ADDR] <= SP_ADDR;

            // 実行できない命令を検出して停止した状態は，外部からのリセットが
            // 入っているときだけ解除する．自ら解除するとプログラムの先頭から
            // 同じ命令を踏み直すだけになるため，解除の判断は外部に委ねる
            if (!resetn) begin
                force_reset <= 1'b0;
            end
        end
        // 命令実行
        else begin
            // IOからレジスタに値を格納する
            register[6'h20] <= {4'b0, btn};
            register[6'h21] <= {6'b0, sw};
            register[6'h31] <= stdin_tdata;
            register[6'h32][2] <= stdin_tlast;
            register[6'h32][1] <= stdin_tvalid;
            register[6'h32][0] <= stdin_tready;
            register[6'h33] <= stdout_tdata;
            register[6'h34][2] <= stdout_tlast;
            register[6'h34][1] <= stdout_tvalid;
            register[6'h34][0] <= stdout_tready;

            // CPUの実行サイクルごとに処理記載
            unique case (cpu_phase)
                // フェッチ(先読みの対象にならないプログラムの1命令目だけがここを通る)
                CPU_FETCH: begin
                    // 命令を取得してくる
                    ir <= rom_read.machine;

                    // 次のサイクルへ
                    cpu_phase <= CPU_CHECK;
                end

                // 実行前確認(プログラムの1命令目と，先読みの時点で実行できないと分かった命令だけがここを通る)
                CPU_CHECK: begin
                    // 実行可能な命令であれば実行フェーズへ進む．
                    // 先読みを経てここへ来た命令は実行できないと判定済みであるため，
                    // こちらへ入るのはプログラムの1命令目だけになる
                    if (is_instruction_executable(
                        command.m_type, command.func,
                        command.rs1, command.rs2, command.rd, command.imm
                    )) begin
                        // 実行に使う値と命令の内容を取り込む
                        rs1_val_r <= register[command.rs1];
                        rs2_val_r <= register[command.rs2];
                        rd_addr_r <= command.rd;
                        func_r    <= command.func;
                        imm_r     <= command.imm;
                        mask_r    <= command.mask;

                        cpu_phase <= CPU_EXECUTE;
                    end
                    // 実行できない命令は動作を保証できないため，リセット状態へ落とす
                    else begin
                        force_reset <= 1'b1;
                    end
                end

                // 処理の実行
                CPU_EXECUTE: begin
                    // このサイクルではまだ次の命令へ進んでいない状態から判定を始めるため，advancingを一旦0に戻す(advance_to_next_instruction()が呼ばれると1になる)
                    advancing = 1'b0;

                    // 関数タイプごとに実行
                    unique case (command.m_type)
                        // 処理を実行しない(N系)
                        N_TYPE: begin
                            // 次に実行する命令の番地へ進む
                            register[PC_ADDR] <= next_pc;

                            // 次の命令へ(レジスタへ書き込まないためフォワーディングする値はない)
                            advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);

                            // 不正な値が入っても全て無視する
                        end

                        // 演算系(P系)
                        P_TYPE: begin
                            // 命令に応じて演算結果を求める(書き込みとフォワーディングの両方でこの値を使う)．
                            // 有効なfuncであることも合わせて記録する(不正なfuncでは書き込み・
                            // フォワーディングとも行わないため)．
                            write_valid = 1'b1;
                            unique case (func_r)
                                AND:  write_value = rs1_val_r & rs2_val_r;
                                OR:   write_value = rs1_val_r | rs2_val_r;
                                XOR:  write_value = rs1_val_r ^ rs2_val_r;
                                NOT:  write_value = ~rs1_val_r;
                                NAND: write_value = ~(rs1_val_r & rs2_val_r);
                                ADD:  write_value = rs1_val_r + rs2_val_r;
                                SUB:  write_value = rs1_val_r - rs2_val_r;
                                MUL:  write_value = rs1_val_r * rs2_val_r;

                                // 割り算
                                DIV: begin
                                    unique case (div_state)
                                        // 入力をIPへ送信
                                        IDLE: begin
                                            dividend_tdata  <= rs1_val_r;
                                            divisor_tdata   <= rs2_val_r;
                                            dividend_tvalid <= 1'b1;
                                            divisor_tvalid  <= 1'b1;
                                            div_state <= EXECUTE;
                                        end

                                        // IPはtreadyなし（常にready）なので1サイクル待ってRESPONSEへ
                                        EXECUTE: begin
                                            dividend_tvalid <= 1'b0;
                                            divisor_tvalid  <= 1'b0;
                                            div_state <= RESPONSE;
                                        end

                                        // 計算結果が返ってくるまで待機
                                        RESPONSE: begin
                                            if (dout_tvalid) begin
                                                // 商をrdへ格納
                                                register[rd_addr_r] <= dout_tdata[63:32];
                                                // imm[32]=1なら余りをimm[5:0]のアドレスへ格納
                                                if (imm_r[32]) begin
                                                    register[imm_r[5:0]] <= dout_tdata[31:0];
                                                end
                                                div_state <= IDLE;
                                                register[PC_ADDR] <= next_pc;
                                                // 次の命令へ(商・余りの2箇所への書き込みを，代入する順に渡す)
                                                advance_to_next_instruction(
                                                    1'b1, rd_addr_r, dout_tdata[63:32],
                                                    imm_r[32], imm_r[5:0], dout_tdata[31:0]
                                                );
                                            end
                                        end
                                        default: force_reset <= 1'b1;
                                    endcase
                                end
                                default: begin
                                    force_reset <= 1'b1;
                                    write_valid = 1'b0;
                                end
                            endcase

                            // DIV以外はここでPCインクリメント・次命令への遷移(不正なfuncでは
                            // レジスタ書き込み・フォワーディングは行わない)
                            if (func_r != DIV) begin
                                if (write_valid) begin
                                    register[rd_addr_r] <= write_value;
                                end
                                register[PC_ADDR] <= next_pc;
                                advance_to_next_instruction(write_valid, rd_addr_r, write_value, 1'b0, '0, '0);
                            end
                        end

                        // シフト系
                        S_TYPE: begin
                            // シフト系はどの命令でも次に実行する命令の番地へ進む
                            register[PC_ADDR] <= next_pc;

                            // イミディエイトデータを使用する？命令に応じてシフト結果を求める
                            // (書き込みとフォワーディングの両方でこの値を使う)．有効なfuncであることも
                            // 合わせて記録する(不正なfuncでは書き込み・フォワーディングとも行わないため)．
                            write_valid = 1'b1;
                            if (imm_r[32]) begin
                                unique case (func_r)
                                    SLL: write_value = rs1_val_r << imm_r[31:0];
                                    SRL: write_value = rs1_val_r >> imm_r[31:0];
                                    SLA: write_value = rs1_val_r <<< imm_r[31:0];
                                    SRA: write_value = rs1_val_r >>> imm_r[31:0];
                                    default: begin
                                        force_reset <= 1'b1;
                                        write_valid = 1'b0;
                                    end
                                endcase
                            end else begin
                                unique case (func_r)
                                    SLL: write_value = rs1_val_r << rs2_val_r;
                                    SRL: write_value = rs1_val_r >> rs2_val_r;
                                    SLA: write_value = rs1_val_r <<< rs2_val_r;
                                    SRA: write_value = rs1_val_r >>> rs2_val_r;
                                    default: begin
                                        force_reset <= 1'b1;
                                        write_valid = 1'b0;
                                    end
                                endcase
                            end
                            if (write_valid) begin
                                register[rd_addr_r] <= write_value;
                            end

                            // 次の命令へ(不正な命令コードでは書き込みもフォワーディングも行わない)
                            advance_to_next_instruction(write_valid, rd_addr_r, write_value, 1'b0, '0, '0);
                        end

                        // 代入系
                        A_TYPE: begin
                            // 代入系はどの命令でも次に実行する命令の番地へ進む
                            register[PC_ADDR] <= next_pc;

                            // 命令がMOVの時だけ実行(書き込みとフォワーディングの両方でwrite_valueを使う)
                            if (func_r == MOV) begin
                                // イミディエイトデータを使用する？
                                write_value = imm_r[32] ? imm_r[31:0] : rs1_val_r;
                                register[rd_addr_r] <= write_value;
                            end
                            else begin
                                force_reset <= 1'b1;
                            end

                            // 次の命令へ(MOV以外はレジスタへ書き込まないためフォワーディングする値はない)
                            advance_to_next_instruction(func_r == MOV, rd_addr_r, write_value, 1'b0, '0, '0);
                        end

                        // 分岐系
                        F_TYPE: begin
                            // 比較が成立していれば指定されたぶん離れた番地へ，していなければ次の番地へ移動する
                            unique case (func_r)
                                EQ, NE, LT, GT, ELT, EGT: begin
                                    register[PC_ADDR] <= next_pc;
                                end
                                // 定義されていない比較方法は実行できない
                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase

                            // 次の命令へ(比較するだけでレジスタへ書き込まないためフォワーディングする値はない)
                            advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                        end

                        // ジャンプ系
                        J_TYPE: begin
                            // 命令ごとに処理実行
                            unique case (func_r)
                                // ジャンプ
                                JMP: begin
                                    // 指定された飛び先へ移動する
                                    register[PC_ADDR] <= next_pc;

                                    // 次の命令へ(レジスタへ書き込まないためフォワーディングする値はない)
                                    advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                end

                                // 関数呼び出し
                                CALL: begin
                                    // 戻り先(呼び出しの次の番地)を次の戻り先レジスタに保存する
                                    register[register[SP_ADDR] + 1] <= register[PC_ADDR] + 1;
                                    // スタックポインタを進める
                                    register[SP_ADDR] <= register[SP_ADDR] + 1;
                                    // 指定された飛び先へ移動する
                                    register[PC_ADDR] <= next_pc;

                                    // 次の命令へ(戻り先とスタックポインタは書き込み先レジスタの指定を経由せずに
                                    // 書き込むためフォワーディングできないが，どちらも読み出しが
                                    // 禁止されており次の命令が読む値になり得ないので，
                                    // フォワーディングしなくても誤った値が読まれることはない)
                                    advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                end

                                // 関数リターン
                                RET: begin
                                    // スタックポインタが指す戻り先へ移動する
                                    register[PC_ADDR] <= next_pc;
                                    // スタックポインタを戻す
                                    register[SP_ADDR] <= register[SP_ADDR] - 1;

                                    // 次の命令へ(レジスタへ書き込まないためフォワーディングする値はない)
                                    advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                end

                                // それ以外はオミット
                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase
                        end

                        // メモリ系
                        M_TYPE: begin
                            unique case (func_r)
                                // メモリ読み込み
                                RM: begin
                                    unique case (ram_read_state)
                                        // 待機
                                        IDLE: begin
                                            // 実行を指示
                                            ram_read_state <= EXECUTE;
                                            // 実行状態であることを送る
                                            ram_read.valid <= 1'b1;

                                            // マスク情報を送る
                                            ram_read.mask <= mask_r;
                                            // アドレス情報を送る
                                            if (imm_r[32]) begin
                                                // イミディエイトデータを使用する指定なら，それを送る
                                                ram_read.address <= imm_r[31:0];
                                            end
                                            else begin
                                                // 読み込みアドレスを送る
                                                ram_read.address <= rs1_val_r;
                                            end
                                        end

                                        // メモリ読み込み実行
                                        EXECUTE: begin
                                            // 読み込みが完了したなら
                                            if (ram_read.ready) begin
                                                // 待機状態に遷移
                                                ram_read_state <= IDLE;
                                                // 実行状態をオフ
                                                ram_read.valid <= 1'b0;

                                                // データを受け取る
                                                register[rd_addr_r] <= ram_read.data;

                                                // 次に実行する命令の番地へ進む
                                                register[PC_ADDR] <= next_pc;

                                                // 次の命令へ
                                                advance_to_next_instruction(1'b1, rd_addr_r, ram_read.data, 1'b0, '0, '0);
                                            end
                                        end

                                        // その他
                                        default: begin
                                            force_reset <= 1'b1;
                                        end
                                    endcase
                                end

                                // メモリ書き込み
                                WM: begin
                                    unique case(ram_write_state)
                                        // 待機
                                        IDLE: begin
                                            // 実行を指示
                                            ram_write_state <= EXECUTE;
                                            // 実行状態であることを送る
                                            ram_write.valid <= 1'b1;

                                            // マスク情報を送る
                                            ram_write.mask <= mask_r;
                                            // アドレス情報を送る
                                            if (imm_r[32]) begin
                                                // イミディエイトデータを使用する指定なら，それを送る
                                                ram_write.address <= imm_r[31:0];
                                            end
                                            else begin
                                                // 書き込みアドレスを送る
                                                ram_write.address <= rs1_val_r;
                                            end
                                            // データを送る
                                            ram_write.data <= rs2_val_r;
                                        end

                                        // メモリ書き込み実行
                                        EXECUTE: begin
                                            // 書き込みが完了したなら
                                            if (ram_write.ready) begin
                                                // 待機状態に遷移
                                                ram_write_state <= IDLE;
                                                // 実行状態をオフ
                                                ram_write.valid <= 1'b0;

                                                // 次に実行する命令の番地へ進む
                                                register[PC_ADDR] <= next_pc;

                                                // 次の命令へ(メモリへ書き込むだけでレジスタへは書き込まないためフォワーディングする値はない)
                                                advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                            end
                                        end

                                        // その他
                                        default: begin
                                            force_reset <= 1'b1;
                                        end
                                    endcase
                                end
                                // バーストはオミット
                                // メモリ読み込み(バースト)
                                BRM: begin
                                    force_reset <= 1'b1;
                                end
                                // メモリ書き込み(バースト)
                                BWM: begin
                                    force_reset <= 1'b1;
                                end

                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase
                        end

                        // 標準入出力系
                        IO_TYPE: begin
                            unique case (func_r)
                                // 標準入力
                                SCAN: begin
                                    unique case (stdin_state)
                                        // 待機
                                        IDLE: begin
                                            // 実行を指示
                                            stdin_state <= EXECUTE;
                                            stdin_tready <= 1'b1;
                                        end

                                        // 実行
                                        EXECUTE: begin
                                            // データが送られてきているなら
                                            if (stdin_tvalid) begin
                                                register[rd_addr_r] <= stdin_tdata;

                                                // 一文字ずつ読み込むため，これだけ読みこんだら終了する
                                                stdin_state <= IDLE;
                                                stdin_tready <= 1'b0;

                                                // 次に実行する命令の番地へ進む
                                                register[PC_ADDR] <= next_pc;

                                                // 次の命令へ
                                                advance_to_next_instruction(1'b1, rd_addr_r, stdin_tdata, 1'b0, '0, '0);
                                            end
                                            else begin
                                                // 読み取り準備が整っていることを送る
                                                stdin_tready <= 1'b1;
                                            end
                                        end

                                        // その他
                                        default: begin
                                            force_reset <= 1'b1;
                                        end
                                    endcase
                                end

                                // 標準出力
                                PRINT: begin
                                    unique case (stdout_state)
                                        // 待機
                                        IDLE: begin
                                            // イミディエイトデータを使用するなら
                                            if (imm_r[32]) begin
                                                // データを送る
                                                stdout_tdata <= imm_r[31:0];
                                            end
                                            // rs1のデータを使用するなら
                                            else begin
                                                stdout_tdata <= rs1_val_r;
                                            end

                                            // 実行を指示
                                            stdout_tvalid <= 1'b1;
                                            stdout_state <= EXECUTE;
                                        end

                                        // 実行
                                        EXECUTE: begin
                                            // データの送信に成功したなら
                                            if (stdout_tready) begin
                                                // 一文字ずつ書き込むため，これだけ書き込んだら終了する
                                                stdout_state <= IDLE;
                                                stdout_tvalid <= 1'b0;

                                                // 次に実行する命令の番地へ進む
                                                register[PC_ADDR] <= next_pc;

                                                // 次の命令へ(出力するだけでレジスタへは書き込まないためフォワーディングする値はない)
                                                advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                            end
                                            else begin
                                                // 書き込み準備が終わっていることを送る
                                                stdout_tvalid <= 1'b1;
                                            end
                                        end

                                        // その他
                                        default: begin
                                            force_reset <= 1'b1;
                                        end
                                    endcase
                                end

                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase
                        end

                        default: begin
                            force_reset <= 1'b1;
                        end
                    endcase

                    // 次の命令を先読みしてよい状態(can_prefetch)で，かつ今サイクルにはまだ次の命令へ
                    // 進んでいない(!advancing)場合に，次の命令をir_prefetchedへ先読みする．
                    // これに該当するのは，DIVの完了待ちやRM/WM/SCAN/PRINTの応答待ちなど，命令の実行が
                    // 複数サイクルにまたがりまだ完了(advance_to_next_instruction()の呼び出し)に至って
                    // いないサイクル．
                    // このブロックはunique caseの後(CPU_EXECUTE末尾)に置き，かつ!advancingで
                    // 排他制御する必要がある．今サイクルにadvance_to_next_instruction()が呼ばれて
                    // いる(advancing==1)場合，そちらの中で既にir_prefetched_valid <= 1'b0が予約されており，
                    // ここでもir_prefetched_valid <= 1'b1を予約すると同一サイクル内で同じ信号への代入が
                    // 競合してしまうため．
                    if (can_prefetch && !advancing) begin
                        ir_prefetched <= rom_read.machine;
                        ir_prefetched_valid <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
