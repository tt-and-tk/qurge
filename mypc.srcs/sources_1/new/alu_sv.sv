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
    // 実行中に先読みした次の命令(分岐・ジャンプ命令の実行中は先読みしない)
    machine_p::machine_t ir_next = nop();
    logic ir_next_valid = 1'b0;
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

    // 強制リセット
    logic force_reset = 1'b0;

    // 分岐・ジャンプが確定するまでは次命令のPCが定まらないため，先読みしない
    logic prefetch_fires;
    assign prefetch_fires = (cpu_phase == CPU_EXECUTE) && !ir_next_valid
        && (command.m_type != F_TYPE) && (command.m_type != J_TYPE);

    // 命令完了時，次の命令へ遷移する処理をまとめたタスク．
    // 先読み済みの命令があればFETCHフェーズを省略し，直接CHECKへ進む．
    task automatic retire();
        if (ir_next_valid) begin
            // 前サイクル以前に先読みが完了している場合，それを採用する
            ir <= ir_next;
            cpu_phase <= CPU_CHECK;
        end
        else if (prefetch_fires) begin
            // 今サイクルに先読みが完了する場合，レジスタを経由せず直接採用する
            ir <= rom_read.machine;
            cpu_phase <= CPU_CHECK;
        end
        else begin
            // 分岐・ジャンプ直後など，先読みできなかった場合は通常通りFETCHへ
            cpu_phase <= CPU_FETCH;
        end
        ir_next_valid <= 1'b0;
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

        // pcを出力する．実行中の命令が分岐・ジャンプでなければ次命令を先読みする
        if (prefetch_fires) begin
            rom_read.pc = register[PC_ADDR] + 1;
        end
        else begin
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
            ir_next <= nop();
            ir_next_valid <= 1'b0;
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

            // メモリ読み書き
            ram_read.address <= 0;
            ram_read.mask <= 0;
            ram_read.valid <= 0;
            ram_write.address <= 0;
            ram_write.data <= 0;
            ram_write.mask <= 0;
            ram_write.valid <= 0;

            // レジスタ(標準入出力を覗く)
            for (logic [5:0] i = 0; i <= 6'h30; i++) begin
                register[i] <= 0;
            end
            // スタックポインタは空を表す自身の番地で初期化する
            register[SP_ADDR] <= SP_ADDR;

            // 強制リセット状態は元に戻さない．
            // 強制リセットが働いたときはリセット状態から戻さない．
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
                // フェッチ
                CPU_FETCH: begin
                    // 命令を取得してくる
                    ir <= rom_read.machine;

                    // 次のサイクルへ
                    cpu_phase <= CPU_CHECK;
                end

                // 実行前確認
                CPU_CHECK: begin
                    // 関数タイプごとに実行
                    unique case (command.m_type)
                        // 処理を実行しない(N系)
                        N_TYPE: begin
                            // 確認はないので実行
                            cpu_phase <= CPU_EXECUTE;
                        end

                        // 演算系(P系)
                        P_TYPE: begin
                            // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                            if (
                                is_readable(command.rs1)
                                && is_readable(command.rs2)
                                && is_writable(command.rd)
                                // イミディエイトデータを使用する場合，そのアドレスも確認する
                                && (!command.imm[32] ||  is_writable(command.imm[5:0])
                                )
                            ) begin
                                cpu_phase <= CPU_EXECUTE;

                                // 実行前準備
                                rs1_val_r <= register[command.rs1];
                                rs2_val_r <= register[command.rs2];
                                rd_addr_r <= command.rd;
                                imm_r <= command.imm;
                                func_r <= command.func;
                            end
                            else begin
                                force_reset <= 1'b1;
                            end
                        end

                        // シフト系(S系)
                        S_TYPE: begin
                            // イミディエイトデータを使用するなら
                            if (command.imm[32]) begin
                                // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                                if (
                                    is_readable(command.rs1)
                                    && is_writable(command.rd)
                                ) begin
                                    cpu_phase <= CPU_EXECUTE;
                                end
                                else begin
                                    force_reset <= 1'b1;
                                end
                            end
                            else begin
                                // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                                if (
                                    is_readable(command.rs1)
                                    && is_readable(command.rs2)
                                    && is_writable(command.rd)
                                ) begin
                                    cpu_phase <= CPU_EXECUTE;
                                end
                                else begin
                                    force_reset <= 1'b1;
                                end
                            end

                            // 実行前準備
                            rs1_val_r <= register[command.rs1];
                            rs2_val_r <= register[command.rs2];
                            rd_addr_r <= command.rd;
                            imm_r <= command.imm;
                            func_r <= command.func;
                        end

                        // 代入系(A系)
                        A_TYPE: begin
                            // イミディエイトデータを使用するなら
                            if (command.imm[32]) begin
                                // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                                if (is_writable(command.rd)) begin
                                    cpu_phase <= CPU_EXECUTE;
                                end
                                else begin
                                    force_reset <= 1'b1;
                                end
                            end
                            else begin
                                // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                                if (is_readable(command.rs1) && is_writable(command.rd)) begin
                                    cpu_phase <= CPU_EXECUTE;
                                end
                                else begin
                                    force_reset <= 1'b1;
                                end
                            end

                            // 実行前準備
                            rs1_val_r <= register[command.rs1];
                            rd_addr_r <= command.rd;
                            imm_r <= command.imm;
                            func_r <= command.func;
                        end

                        // 分岐系(F系)
                        F_TYPE: begin
                            // 使用されているアドレスが全て使用可能
                            // かつイミディエイトデータを使用する設定の時だけ，処理を実行する
                            if (
                                is_readable(command.rs1)
                                && is_readable(command.rs2)
                                && command.imm[32]
                            ) begin
                                cpu_phase <= CPU_EXECUTE;

                                // 実行前準備
                                rs1_val_r <= register[command.rs1];
                                rs2_val_r <= register[command.rs2];
                                imm_r <= command.imm;
                                func_r <= command.func;
                            end
                            else begin
                                force_reset <= 1'b1;
                            end
                        end

                        // ジャンプ系(J系)
                        J_TYPE: begin
                            // 命令ごとのチェック項目
                            unique case (command.func)
                                // ジャンプ・関数呼び出しはジャンプ先の指定方法を確認する
                                JMP, CALL: begin
                                    // イミディエイトデータを使用しないなら
                                    if (!command.imm[32]) begin
                                        // 指定されているアドレスが全て使用可能な場合のみ，処理を実行する
                                        if (is_readable(command.rs1)) begin
                                            cpu_phase <= CPU_EXECUTE;
                                        end
                                        else begin
                                            force_reset <= 1'b1;
                                        end
                                    end
                                    // イミディエイトデータを使用するならチェック不要
                                    else begin
                                        cpu_phase <= CPU_EXECUTE;
                                    end

                                    // 実行前準備
                                    rs1_val_r <= register[command.rs1];
                                    imm_r <= command.imm;
                                    func_r <= command.func;
                                end

                                // 関数リターンは引数なしなのでチェック不要
                                RET: begin
                                    cpu_phase <= CPU_EXECUTE;

                                    // 実行前準備
                                    func_r <= command.func;
                                end

                                // それ以外はオミット
                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase
                        end

                        // メモリ系(M系)
                        M_TYPE: begin
                            // 命令ごとのチェック項目
                            unique case (command.func)
                                // メモリ読み込み
                                RM: begin
                                    if (
                                        // rdに書き込み可能か
                                        is_writable(command.rd)
                                        // イミディエイトデータを使用しない場合，rs1が読み取り可能かについてもチェックする
                                        && (command.imm[32] || is_readable(command.rs1))
                                    ) begin
                                        cpu_phase <= CPU_EXECUTE;

                                        // 実行前準備
                                        rs1_val_r <= register[command.rs1];
                                        rd_addr_r <= command.rd;
                                        imm_r <= command.imm;
                                        mask_r <= command.mask;
                                        func_r <= command.func;
                                    end
                                    else begin
                                        force_reset <= 1'b1;
                                    end
                                end

                                // メモリ書き込み
                                WM: begin
                                    if (
                                        // rs2は読み込み可能か
                                        is_readable(command.rs2)
                                        // イミディエイトデータを使用しない場合，rs1が読み取り可能かについてもチェックする
                                        && (command.imm[32] || is_readable(command.rs1))
                                    ) begin
                                        cpu_phase <= CPU_EXECUTE;

                                        // 実行前準備
                                        rs1_val_r <= register[command.rs1];
                                        rs2_val_r <= register[command.rs2];
                                        imm_r <= command.imm;
                                        mask_r <= command.mask;
                                        func_r <= command.func;
                                    end
                                    else begin
                                        force_reset <= 1'b1;
                                    end
                                end

                                // それ以外はオミット
                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase
                        end

                        // 標準入出力系(IO系)
                        IO_TYPE: begin
                            // 命令ごとのチェック項目
                            unique case (command.func)
                                // 標準入力
                                SCAN: begin
                                    if (is_writable(command.rd)) begin
                                        cpu_phase <= CPU_EXECUTE;

                                        // 実行準備もしておく
                                        rd_addr_r <= command.rd;
                                        func_r <= command.func;
                                    end
                                    else begin
                                        force_reset <= 1'b1;
                                    end
                                end

                                // 標準出力
                                PRINT: begin
                                    if (is_readable(command.rs1)) begin
                                        cpu_phase <= CPU_EXECUTE;

                                        // 実行前準備もしておく
                                        rs1_val_r <= register[command.rs1];
                                        imm_r <= command.imm;
                                        func_r <= command.func;
                                    end
                                    else begin
                                        force_reset <= 1'b1;
                                    end
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
                end

                // 処理の実行
                CPU_EXECUTE: begin
                    // 分岐・ジャンプでなければ，実行中に次の命令を先読みしておく
                    if (prefetch_fires) begin
                        ir_next <= rom_read.machine;
                        ir_next_valid <= 1'b1;
                    end

                    // 関数タイプごとに実行
                    unique case (command.m_type)
                        // 処理を実行しない(N系)
                        N_TYPE: begin
                            // pcをカウントアップ
                            register[PC_ADDR] <= register[PC_ADDR] + 1;

                            // 次の命令へ
                            retire();

                            // 不正な値が入っても全て無視する
                        end

                        // 演算系(P系)
                        P_TYPE: begin
                            // 命令に応じて処理実行
                            unique case (func_r)
                                AND:  register[rd_addr_r] <= rs1_val_r & rs2_val_r;
                                OR:   register[rd_addr_r] <= rs1_val_r | rs2_val_r;
                                XOR:  register[rd_addr_r] <= rs1_val_r ^ rs2_val_r;
                                NOT:  register[rd_addr_r] <= ~rs1_val_r;
                                NAND: register[rd_addr_r] <= ~(rs1_val_r & rs2_val_r);
                                ADD:  register[rd_addr_r] <= rs1_val_r + rs2_val_r;
                                SUB:  register[rd_addr_r] <= rs1_val_r - rs2_val_r;
                                MUL:  register[rd_addr_r] <= rs1_val_r * rs2_val_r;

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
                                                register[PC_ADDR] <= register[PC_ADDR] + 1;
                                                retire();
                                            end
                                        end
                                        default: force_reset <= 1'b1;
                                    endcase
                                end
                                default: force_reset <= 1'b1;
                            endcase

                            // DIV以外はここでPCインクリメントと次命令への遷移
                            if (func_r != DIV) begin
                                register[PC_ADDR] <= register[PC_ADDR] + 1;
                                retire();
                            end
                        end

                        // シフト系
                        S_TYPE: begin
                            // シフト系はどの命令でもpcをカウントアップする
                            register[PC_ADDR] <= register[PC_ADDR] + 1;

                            // イミディエイトデータを使用する？
                            if (imm_r[32]) begin
                                // 命令に応じて処理実行
                                unique case (func_r)
                                    SLL: register[rd_addr_r] <= rs1_val_r << imm_r[31:0];
                                    SRL: register[rd_addr_r] <= rs1_val_r >> imm_r[31:0];
                                    SLA: register[rd_addr_r] <= rs1_val_r <<< imm_r[31:0];
                                    SRA: register[rd_addr_r] <= rs1_val_r >>> imm_r[31:0];
                                    default: force_reset <= 1'b1;
                                endcase
                            end else begin
                                // 命令に応じて処理実行
                                unique case (func_r)
                                    SLL: register[rd_addr_r] <= rs1_val_r << rs2_val_r;
                                    SRL: register[rd_addr_r] <= rs1_val_r >> rs2_val_r;
                                    SLA: register[rd_addr_r] <= rs1_val_r <<< rs2_val_r;
                                    SRA: register[rd_addr_r] <= rs1_val_r >>> rs2_val_r;
                                    default: force_reset <= 1'b1;
                                endcase
                            end

                            // 次の命令へ
                            retire();
                        end

                        // 代入系
                        A_TYPE: begin
                            // 代入系はどの命令でもpcをカウントアップする
                            register[PC_ADDR] <= register[PC_ADDR] + 1;

                            // 命令がMOVの時だけ実行
                            if (func_r == MOV) begin
                                // イミディエイトデータを使用する？
                                if (imm_r[32]) begin
                                    register[rd_addr_r] <= imm_r[31:0];
                                end else begin
                                    register[rd_addr_r] <= rs1_val_r;
                                end
                            end
                            else begin
                                force_reset <= 1'b1;
                            end

                            // 次の命令へ
                            retire();
                        end

                        // 分岐系
                        F_TYPE: begin
                            // 命令に応じて処理実行
                            unique case (func_r)
                                EQ: begin
                                    if (rs1_val_r == rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                NE: begin
                                    if (rs1_val_r != rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                LT: begin
                                    if (rs1_val_r < rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                GT: begin
                                    if (rs1_val_r > rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                ELT: begin
                                    if (rs1_val_r <= rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                EGT: begin
                                    if (rs1_val_r >= rs2_val_r)
                                        register[PC_ADDR] <= register[PC_ADDR] + imm_r[31:0];
                                    else
                                        register[PC_ADDR] <= register[PC_ADDR] + 1;
                                end
                                default: begin
                                    force_reset <= 1'b1;
                                end
                            endcase

                            // 次の命令へ(分岐命令のため先読みは行われない)
                            retire();
                        end

                        // ジャンプ系
                        J_TYPE: begin
                            // 命令ごとに処理実行
                            unique case (func_r)
                                // ジャンプ
                                JMP: begin
                                    // イミディエイトデータを使用する？
                                    if (imm_r[32]) begin
                                        register[PC_ADDR] <= imm_r[31:0];
                                    end
                                    else begin
                                        register[PC_ADDR] <= rs1_val_r;
                                    end

                                    // 次の命令へ(ジャンプ命令のため先読みは行われない)
                                    retire();
                                end

                                // 関数呼び出し
                                CALL: begin
                                    // 戻り先(PC+1)を次の戻り先レジスタに保存する
                                    register[register[SP_ADDR] + 1] <= register[PC_ADDR] + 1;
                                    // スタックポインタを進める
                                    register[SP_ADDR] <= register[SP_ADDR] + 1;
                                    // ジャンプ先へ移動する
                                    if (imm_r[32]) begin
                                        register[PC_ADDR] <= imm_r[31:0];
                                    end
                                    else begin
                                        register[PC_ADDR] <= rs1_val_r;
                                    end

                                    // 次の命令へ(CALL命令のため先読みは行われない)
                                    retire();
                                end

                                // 関数リターン
                                RET: begin
                                    // スタックポインタが指す戻り先レジスタの値へジャンプする
                                    register[PC_ADDR] <= register[register[SP_ADDR]];
                                    // スタックポインタを戻す
                                    register[SP_ADDR] <= register[SP_ADDR] - 1;

                                    // 次の命令へ(RET命令のため先読みは行われない)
                                    retire();
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

                                                // プログラムカウンタをインクリメント
                                                register[PC_ADDR] <= register[PC_ADDR] + 1;

                                                // 次の命令へ
                                                retire();
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

                                                // プログラムカウンタをインクリメント
                                                register[PC_ADDR] <= register[PC_ADDR] + 1;

                                                // 次の命令へ
                                                retire();
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

                                                // プログラムカウンタをインクリメント
                                                register[PC_ADDR] <= register[PC_ADDR] + 1;

                                                // 次の命令へ
                                                retire();
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

                                                // プログラムカウンタをインクリメント
                                                register[PC_ADDR] <= register[PC_ADDR] + 1;

                                                // 次の命令へ
                                                retire();
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
                end
            endcase
        end
    end
endmodule
