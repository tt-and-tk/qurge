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
`include "decoder.svh"
`include "alu.svh"
`include "ram.svh"
`include "machine.svh"
`include "register.svh"

// 命令パイプライン処理の概要．FETCH(ROMへ番地を出す)→FETCH_CAPTURE(結果を取り込む)→
// CHECK(実行可否を確認する)→EXECUTEの4フェーズを基本とする．ROMはクロックに同期した読み出しの
// ため，番地を出した次のサイクルにならないと結果が確定しない．
//
// 実行に複数サイクルかかる命令(DIV・RM/WM・SCAN/PRINTの応答待ちなど)の待機中は，次に実行する
// 命令の番地が既に確定しているため，あらかじめROMから取得してデコードしておく．読み出し・
// 書き込みに使うレジスタ番地の依存関係もこの時点で確認しておき，直前の命令がこのサイクルに
// 書き込む値をレジスタの読み出し結果の代わりに使う(フォワーディング)ことで，命令完了時に
// FETCH/FETCH_CAPTURE/CHECKを省略して直接次の命令のEXECUTEから始められる場合がある．
// 1サイクルで完了する命令(P/S/A/F/J/N_TYPE)はこの先読みが間に合わないため，毎回4フェーズ
// すべてを経る．
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
    register_t register[REGISTER_MAX_ADDR:0] = '{(REGISTER_MAX_ADDR + 1){32'h0}};

    // 実行フェーズ
    cpu_phase_enum cpu_phase = CPU_FETCH;

    // 実行できない命令を検出して停止していることを表すフラグ．立っている間は下のリセット
    // ブロックの中身を毎サイクル実行し続けて停止状態を保ち，外部からのリセット(resetn)が
    // 入るまで下りない．
    // このフラグを下ろす代入は，下のリセット処理の中(if (!resetn)の中)以外に置かないこと
    // (停止状態から自力で抜けると，外部からのリセットを経ずに同じ命令を再実行する動作になる)．
    logic is_halted = 1'b0;

    // ===== 命令の保持・先読み =====
    // 現在実行中の命令と，実行中にあらかじめ取得しておいた次の命令の2系統を保持する

    // CHECK/EXECUTEフェーズで検証・実行の対象になっている命令．FETCH/FETCH_CAPTUREフェーズの
    // 間は，まだ取り込みが済んでおらず前回実行した命令の値が残ったままで，意味を持たない．
    machine_p::machine_t current_instruction = nop();
    // current_instructionをROMの実容量範囲内から取得できたか(CPU_FETCH_CAPTUREで確定する)
    logic current_instruction_pc_valid = 1'b1;

    // 実行中に先読みしておいた次の命令を保持するバッファ．複数サイクルにまたがる命令の
    // 待機中に埋まり，1サイクルで完了する命令の実行中は埋まらないまま次の命令へ進む．
    machine_p::machine_t prefetched_instruction = nop();
    // prefetched_instructionが先読み済みの有効な命令かどうか
    logic prefetched_instruction_valid = 1'b0;
    // prefetched_instructionをROMの実容量範囲内から取得できたか
    logic prefetched_instruction_pc_valid = 1'b1;

    // 次命令を先読みしてよいかどうかを示すフラグ
    logic can_prefetch;
    assign can_prefetch = (cpu_phase == CPU_EXECUTE)    // 実行フェーズの間のみ先読みが可能
        && !prefetched_instruction_valid;               // 既に先読み済みの命令があれば行わない

    // can_prefetchが1サイクル前も立っていたか．ROMの同期読み出しは番地を出した次のサイクルに
    // ならないと結果が確定しないため，1サイクル安定して待ってから取り込んでよいかの判定に使う
    logic can_prefetch_d1 = 1'b0;

    // 次段命令専用のデコーダー．現在実行中の命令のデコード(command)とは独立に，現在実行中の
    // 命令のEXECUTEフェーズの間に，次段のレジスタ読み出し・書き込み可否を前もって確認するために
    // 用いる．先読みでまだ命令が取り込まれていない間は，このデコード結果も無効な値として扱われる
    // (呼び出し側で判定する)．
    command_if command_next();
    assign command_next.machine = prefetched_instruction;
    decoder_sv decoder_sv_next(
        .resetn(resetn),
        .command(command_next)
    );

    // ===== デコード結果を保持する実行用レジスタ =====
    // CPU_CHECKで取り込み，CPU_EXECUTE中はこれらの値を参照して命令を実行する

    register_t rs1_val_r = '0;        // 第1オペランドの読み出し値
    register_t rs2_val_r = '0;        // 第2オペランドの読み出し値
    machine_p::addr_t rd_addr_r = '0; // 書き込み先レジスタの番地
    machine_p::func_t func_r = '0;    // 命令の細分類(演算子・比較方法など)
    machine_p::imm_t imm_r = '0;      // イミディエイトデータ(使用可否のフラグを含む)
    machine_p::mask_t mask_r = '0;    // 書き込みバイトマスク

    // ===== メモリ・標準入出力・割り算回路とのハンドシェイク状態 =====
    // それぞれの命令の実行が複数サイクルにまたがる間，どこまで進んだかを保持する

    util_p::state_enum ram_read_state = IDLE;  // メモリ読み込み(RM)の実行状態
    util_p::state_enum ram_write_state = IDLE; // メモリ書き込み(WM)の実行状態
    util_p::state_enum stdin_state = IDLE;     // 標準入力(SCAN)の実行状態
    util_p::state_enum stdout_state = IDLE;    // 標準出力(PRINT)の実行状態
    util_p::state_enum div_state = IDLE;       // 割り算(DIV)の実行状態
    util_p::state_enum mul_state = IDLE;       // 掛け算(MUL)の実行状態

    // MULの乗算結果(DSP48E1の出力)を一旦保持するレジスタ．乗算結果を確定させるサイクルと，
    // それを使って次命令へフォワーディングするかどうかを判定するサイクルを分離するために使う
    // (issue #87．乗算とフォワーディング判定の比較・マルチプレクサが同一サイクルの組み合わせ
    // 論理として直列に連なるとタイミング違反になるため，間にこのレジスタを挟んで2サイクルに割る)
    register_t mul_result_r = '0;

    // ===== 分岐・ジャンプ先・次番地の算出(組み合わせ回路) =====
    // 実行フェーズの間のみ意味を持つ(それ以外のフェーズでは直前に実行した命令の値が残っている)

    // ROMへ出力する(切り詰め前の)命令アドレスの値が，ROMのアドレスバス幅に収まっているか
    util_p::bool_t pc_fits_in_width;

    // 分岐命令の比較結果がtrueかどうか(定義されていない比較方法はfalseとして扱う)
    logic is_branch_taken;
    assign is_branch_taken = (command.m_type == F_TYPE)
        && ((func_r == EQ  && rs1_val_r == rs2_val_r)
         || (func_r == NE  && rs1_val_r != rs2_val_r)
         || (func_r == LT  && $signed(rs1_val_r) <  $signed(rs2_val_r))
         || (func_r == GT  && $signed(rs1_val_r) >  $signed(rs2_val_r))
         || (func_r == ELT && $signed(rs1_val_r) <= $signed(rs2_val_r))
         || (func_r == EGT && $signed(rs1_val_r) >= $signed(rs2_val_r)));

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

    // 実行中の命令がこのサイクルにプログラムカウンタへ書き込む値．参照してよいのは実行フェーズの
    // 間だけ．それ以外のフェーズでは，命令タイプはこれから確認する命令のものであるのに対し，
    // 比較と飛び先の指定に使う値は直前に実行した命令のものが残っており，別々の命令に由来する
    // 値から番地を求めることになるため，結果に意味がない．
    register_t next_pc;
    assign next_pc = is_branch_taken ? register[PC_ADDR] + imm_r[31:0]  // 比較結果がtrueの分岐は指定されたぶん離れた番地へ
                   : is_jumping      ? jump_target                      // 移動する命令は指定された飛び先へ
                   : register[PC_ADDR] + 1;                             // それ以外は次の番地へ進む

    // ===== CPU_EXECUTE内でのみ一時的に使うスクラッチ変数(ブロッキング代入) =====

    // 今サイクルにadvance_to_next_instruction()が呼ばれたかどうか(末尾の先読みトリガーの可否判定に使う)
    logic advancing;

    // 演算系・シフト系・代入系の結果(レジスタへの書き込みと次の命令へのフォワーディングで共用)
    register_t write_value = '0;

    // write_valueが有効か．funcが不正(unique caseのdefaultに該当)な場合，is_halted <= 1'b1は
    // 次のクロックエッジまで反映されないため，このフラグでガードしないと同じサイクル内で
    // write_valueに残った前回までの値を使って誤った書き込み・フォワーディングが発生してしまう
    logic write_valid;

    // 命令完了時，次の命令へ遷移する処理をまとめたタスク．
    // 次の命令には，先読み済みの機械語(prefetched_instruction)のみを使う(ROMが同期読み出しのため，
    // 先読みが間に合っていない場合は今サイクルのrom_read.machineを信用できない)．
    // 先読みが完了しかつ実行可能だと分かればCHECKを省略してEXECUTEへ直接進み，先読み済みだが
    // 実行できないと分かった場合はCHECKへ進む(CHECKで停止させる)．先読みが間に合っていない
    // 場合はFETCHへ戻ってROMから改めて取得し直す．
    // CPU_EXECUTEフェーズで命令完了時に次命令へ遷移する箇所は，cpu_phase <= CPU_FETCH;を
    // 直接書かず必ずこのタスクを呼ぶこと(先読み機構(prefetched_instruction/can_prefetch)と連動しており，
    // 直接代入すると先読み結果が反映されない)．
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

        // 先読み済みの次の命令が実行可能かどうかを判定する．先読みが間に合っていない場合，
        // 今サイクルのrom_read.machineは1つ前に出した番地に対する値で信用できないため，
        // prefetched_instruction_valid自体を判定の条件に含める
        if (prefetched_instruction_valid && is_instruction_executable(
            prefetched_instruction_pc_valid, command_next.m_type, command_next.func,
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
            current_instruction <= prefetched_instruction;
            current_instruction_pc_valid <= prefetched_instruction_pc_valid;
            cpu_phase <= CPU_EXECUTE;
        end
        // 先読み済みだが実行できないと分かった命令は，CHECKへ進みそこで停止させる
        else if (prefetched_instruction_valid) begin
            current_instruction <= prefetched_instruction;
            current_instruction_pc_valid <= prefetched_instruction_pc_valid;
            cpu_phase <= CPU_CHECK;
        end
        // 先読みが間に合っていない．register[PC_ADDR]は呼び出し元で既に次の番地へ更新済み
        // なので，FETCHへ戻って改めてROMから取得し直す
        else begin
            cpu_phase <= CPU_FETCH;
        end

        // 先読み済みだった命令は消費し終えたので無効化する(今サイクルに新たに先読みが成立すれば，末尾のブロックで改めて1にする)
        prefetched_instruction_valid <= 1'b0;
    endtask

    // 組み合わせ回路
    always_comb begin
        // 機械語を分解してもらう
        command.machine = current_instruction;

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
        if (cpu_phase == CPU_FETCH || cpu_phase == CPU_FETCH_CAPTURE) begin
            // フェッチ中(1サイクル目・同期読み出しの結果を待つ間とも)は，これから実行する
            // 命令の番地を出し続ける(プログラムの1命令目のフェッチ，または先読みが間に合わ
            // なかった命令の取得し直し)
            rom_read.pc = register[PC_ADDR];
            // 切り詰め前のプログラムカウンタがpc_bus_tの幅に収まっているか
            pc_fits_in_width = util_p::is_within_bit_width(register[PC_ADDR], $bits(rom_p::pc_bus_t));
        end
        else if (can_prefetch) begin
            // 実行フェーズにあり，まだ次の命令を先読みしていない場合は，次に実行する命令を取得する
            rom_read.pc = next_pc;
            // 切り詰め前のnext_pcがpc_bus_tの幅に収まっているか(収まらない場合は上位ビットが黙って捨てられる)
            pc_fits_in_width = util_p::is_within_bit_width(next_pc, $bits(rom_p::pc_bus_t));
        end
        else begin
            // 先読み済み，またはCHECKフェーズなど，ROMへ新たな要求を出す必要がない場合
            rom_read.pc = '0;
            // 番地を出していないため，この値は使われない
            pc_fits_in_width = util_p::TRUE;
        end

        // 標準入出力
        stdout_tkeep = 4'hf;
        stdout_tlast = 1'b1;
    end

    // 順序回路
    always_ff @(posedge clk) begin
        // リセット
        if (!resetn || is_halted) begin
            // 実行状態をリセット
            cpu_phase <= CPU_FETCH;
            current_instruction <= nop();
            prefetched_instruction <= nop();
            prefetched_instruction_valid <= 1'b0;
            current_instruction_pc_valid <= 1'b1;
            prefetched_instruction_pc_valid <= 1'b1;
            can_prefetch_d1 <= 1'b0;
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

            // 掛け算回路用
            mul_state <= IDLE;
            mul_result_r <= '0;

            // メモリの読み込み・書き出し状態をリセット
            ram_read_state <= IDLE;
            ram_write_state <= IDLE;

            // 標準入出力の状態と，受け渡しを行っていることを表す信号をリセット
            stdin_state <= IDLE;
            stdout_state <= IDLE;
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

            // レジスタ(標準入出力のデータと受け渡し状況を受け取っているものを除く．
            // 実行中は毎サイクル入出力の信号線から書き込まれるため，初期化しても即座に上書きされる)
            for (logic [5:0] i = 0; i <= 6'h30; i++) begin
                register[i] <= 0;
            end
            // スタックポインタは空を表す自身の番地で初期化する
            register[SP_ADDR] <= SP_ADDR;

            // 実行できない命令を検出して停止した状態は，外部からのリセットが
            // 入っているときだけ解除する．自ら解除するとプログラムの先頭から
            // 同じ命令を踏み直すだけになるため，解除の判断は外部に委ねる．
            // このリセット信号はPS側が出すものをリセット整形用のIP(proc_sys_reset)を
            // 通して受け取っており，ボタンから直接入ってくることはないため，
            // チャタリングによって解除が何度も繰り返されることはない
            if (!resetn) begin
                is_halted <= 1'b0;
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

            // can_prefetchの1サイクル遅延版を更新する(ROMの同期読み出しは番地を出した次の
            // サイクルにならないと結果が確定しないため，先読みの取り込み可否判定に使う)
            can_prefetch_d1 <= can_prefetch;

            // CPUの実行サイクルごとに処理記載
            unique case (cpu_phase)
                // フェッチ1サイクル目(プログラムの1命令目，および先読みが間に合わなかった
                // 命令の取得し直しがここを通る)．ROMへ番地を出す(comb blockで実施済み)だけで，
                // 同期読み出しの結果はまだ確定していないため次のサイクルまで待つ
                CPU_FETCH: begin
                    cpu_phase <= CPU_FETCH_CAPTURE;
                end

                // フェッチ2サイクル目．前サイクルに出した番地に対応するrom_read.machineが
                // 確定しているので取り込む
                CPU_FETCH_CAPTURE: begin
                    // 番地がROMの実容量の範囲内(rom_read.valid)であり，
                    // かつpc_bus_tの幅に収まっている(pc_fits_in_width)場合にのみ有効とする
                    current_instruction <= rom_read.machine;
                    current_instruction_pc_valid <= rom_read.valid && pc_fits_in_width;

                    // 次のサイクルへ
                    cpu_phase <= CPU_CHECK;
                end

                // 実行前確認(プログラムの1命令目，先読みが間に合わずFETCHから取得し直した
                // 命令，先読みの時点で実行できないと分かった命令がここを通る)
                CPU_CHECK: begin
                    // 実行可能な命令であれば実行フェーズへ進む
                    if (is_instruction_executable(
                        current_instruction_pc_valid, command.m_type, command.func,
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
                    // 実行できない命令は動作を保証できないため，停止させる
                    else begin
                        is_halted <= 1'b1;
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

                                // 掛け算(issue #87．乗算結果の確定サイクルと，それを次命令へ
                                // フォワーディングするか判定するサイクルを分離した2サイクル構成．
                                // 1サイクル目で乗算結果をmul_result_rへ確定させ，2サイクル目で
                                // その安定した値を使って書き込み・次命令への遷移を行う)
                                MUL: begin
                                    unique case (mul_state)
                                        // 乗算を実行し，結果が確定するまで待つ
                                        IDLE: begin
                                            mul_result_r <= rs1_val_r * rs2_val_r;
                                            mul_state <= RESPONSE;
                                        end

                                        // 確定した乗算結果を使って書き込み・次命令への遷移を行う
                                        RESPONSE: begin
                                            register[rd_addr_r] <= mul_result_r;
                                            register[PC_ADDR] <= next_pc;
                                            mul_state <= IDLE;
                                            advance_to_next_instruction(1'b1, rd_addr_r, mul_result_r, 1'b0, '0, '0);
                                        end
                                        default: is_halted <= 1'b1;
                                    endcase
                                    // MULはこのcase内で書き込み・遷移まで完結させるため，
                                    // 下の共通処理(541行目付近)には委ねない
                                    write_valid = 1'b0;
                                end

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
                                        default: is_halted <= 1'b1;
                                    endcase
                                end
                                default: begin
                                    is_halted <= 1'b1;
                                    write_valid = 1'b0;
                                end
                            endcase

                            // DIV・MUL以外はここでPCインクリメント・次命令への遷移(不正なfuncでは
                            // レジスタ書き込み・PC更新・次命令への遷移のいずれも行わない．
                            // DIV・MULはそれぞれのcase内で書き込み・遷移まで完結させている)
                            if (func_r != DIV && func_r != MUL && write_valid) begin
                                register[rd_addr_r] <= write_value;
                                register[PC_ADDR] <= next_pc;
                                advance_to_next_instruction(1'b1, rd_addr_r, write_value, 1'b0, '0, '0);
                            end
                        end

                        // シフト系
                        S_TYPE: begin
                            // イミディエイトデータを使用する？命令に応じてシフト結果を求める
                            // (書き込みとフォワーディングの両方でこの値を使う)．有効なfuncであることも
                            // 合わせて記録する(不正なfuncでは以降の処理を一切行わないため)．
                            write_valid = 1'b1;
                            if (imm_r[32]) begin
                                // シフト量は下位5bit(0〜31)のみを使用する
                                unique case (func_r)
                                    SLL: write_value = rs1_val_r << imm_r[4:0];
                                    SRL: write_value = rs1_val_r >> imm_r[4:0];
                                    SLA: write_value = rs1_val_r <<< imm_r[4:0];
                                    SRA: write_value = $signed(rs1_val_r) >>> imm_r[4:0];
                                    default: begin
                                        is_halted <= 1'b1;
                                        write_valid = 1'b0;
                                    end
                                endcase
                            end else begin
                                // シフト量は下位5bit(0〜31)のみを使用する
                                unique case (func_r)
                                    SLL: write_value = rs1_val_r << rs2_val_r[4:0];
                                    SRL: write_value = rs1_val_r >> rs2_val_r[4:0];
                                    SLA: write_value = rs1_val_r <<< rs2_val_r[4:0];
                                    SRA: write_value = $signed(rs1_val_r) >>> rs2_val_r[4:0];
                                    default: begin
                                        is_halted <= 1'b1;
                                        write_valid = 1'b0;
                                    end
                                endcase
                            end

                            // 有効なfuncのときだけレジスタ書き込み・PC更新・次命令への遷移を行う
                            if (write_valid) begin
                                register[rd_addr_r] <= write_value;
                                register[PC_ADDR] <= next_pc;
                                advance_to_next_instruction(1'b1, rd_addr_r, write_value, 1'b0, '0, '0);
                            end
                        end

                        // 代入系
                        A_TYPE: begin
                            // 命令がMOVの時だけ，書き込み・PC更新・次命令への遷移を行う
                            // (書き込みとフォワーディングの両方でwrite_valueを使う)
                            if (func_r == MOV) begin
                                // イミディエイトデータを使用する？
                                // mask_rは未実装のため参照せず，常にrdの全バイトへ書き込む
                                write_value = imm_r[32] ? imm_r[31:0] : rs1_val_r;
                                register[rd_addr_r] <= write_value;
                                register[PC_ADDR] <= next_pc;
                                advance_to_next_instruction(1'b1, rd_addr_r, write_value, 1'b0, '0, '0);
                            end
                            else begin
                                is_halted <= 1'b1;
                            end
                        end

                        // 分岐系
                        F_TYPE: begin
                            // 比較が成立していれば指定されたぶん離れた番地へ，していなければ次の番地へ移動する
                            unique case (func_r)
                                EQ, NE, LT, GT, ELT, EGT: begin
                                    register[PC_ADDR] <= next_pc;

                                    // 次の命令へ(比較するだけでレジスタへ書き込まないためフォワーディングする値はない)
                                    advance_to_next_instruction(1'b0, '0, '0, 1'b0, '0, '0);
                                end
                                // 定義されていない比較方法は実行できない
                                default: begin
                                    is_halted <= 1'b1;
                                end
                            endcase
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
                                    is_halted <= 1'b1;
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
                                            // 切り詰め前の読み込みアドレス(イミディエイトデータ使用時はimm_r，
                                            // 未使用時はrs1_val_rが発生源)がaddress_bus_tの幅に収まっていない場合は
                                            // 不正な番地として停止する
                                            if (!util_p::is_within_bit_width(
                                                (imm_r[32] ? imm_r[31:0] : rs1_val_r), $bits(ram_p::address_bus_t)
                                            )) begin
                                                is_halted <= 1'b1;
                                            end
                                            else begin
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
                                            is_halted <= 1'b1;
                                        end
                                    endcase
                                end

                                // メモリ書き込み
                                WM: begin
                                    unique case(ram_write_state)
                                        // 待機
                                        IDLE: begin
                                            // 切り詰め前の書き込みアドレス(イミディエイトデータ使用時はimm_r，
                                            // 未使用時はrs1_val_rが発生源)がaddress_bus_tの幅に収まっていない場合は
                                            // 不正な番地として停止する
                                            if (!util_p::is_within_bit_width(
                                                (imm_r[32] ? imm_r[31:0] : rs1_val_r), $bits(ram_p::address_bus_t)
                                            )) begin
                                                is_halted <= 1'b1;
                                            end
                                            else begin
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
                                            is_halted <= 1'b1;
                                        end
                                    endcase
                                end
                                // バースト転送はコマンドだけ用意されているが実装予定なし
                                // メモリ読み込み(バースト)
                                BRM: begin
                                    is_halted <= 1'b1;
                                end
                                // メモリ書き込み(バースト)
                                BWM: begin
                                    is_halted <= 1'b1;
                                end

                                default: begin
                                    is_halted <= 1'b1;
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
                                            is_halted <= 1'b1;
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
                                            is_halted <= 1'b1;
                                        end
                                    endcase
                                end

                                default: begin
                                    is_halted <= 1'b1;
                                end
                            endcase
                        end

                        default: begin
                            is_halted <= 1'b1;
                        end
                    endcase

                    // 次の命令を先読みしてよい状態(can_prefetch)で，かつ今サイクルにはまだ次の命令へ
                    // 進んでいない(!advancing)場合に，次の命令をprefetched_instructionへ先読みする．
                    // これに該当するのは，DIVの完了待ちやRM/WM/SCAN/PRINTの応答待ちなど，命令の実行が
                    // 複数サイクルにまたがりまだ完了(advance_to_next_instruction()の呼び出し)に至って
                    // いないサイクル．
                    // このブロックはunique caseの後(CPU_EXECUTE末尾)に置き，かつ!advancingで
                    // 排他制御する必要がある．今サイクルにadvance_to_next_instruction()が呼ばれて
                    // いる(advancing==1)場合，そちらの中で既にprefetched_instruction_valid <= 1'b0が予約されており，
                    // ここでもprefetched_instruction_valid <= 1'b1を予約すると同一サイクル内で同じ信号への代入が
                    // 競合してしまうため．
                    // can_prefetch_d1も合わせて要求するのは，ROMの同期読み出しが番地を出した
                    // 次のサイクルにならないと確定しないため(can_prefetch単独では1サイクル
                    // 早すぎる値を掴んでしまう)．can_prefetchも同時に要求するのは，捕捉が
                    // 完了しprefetched_instruction_valid <= 1'b1が反映された直後の1サイクルは
                    // can_prefetch_d1がまだ1のまま残っており，その間に古い要求(番地'0)への
                    // 応答で誤って再取り込みしてしまうのを防ぐため
                    if (can_prefetch && can_prefetch_d1 && !advancing) begin
                        // 番地がROMの実容量の範囲内(rom_read.valid)であり，
                        // かつpc_bus_tの幅に収まっている(pc_fits_in_width)場合にのみ有効とする
                        prefetched_instruction <= rom_read.machine;
                        prefetched_instruction_valid <= 1'b1;
                        prefetched_instruction_pc_valid <= rom_read.valid && pc_fits_in_width;
                    end
                end
            endcase
        end
    end
endmodule
