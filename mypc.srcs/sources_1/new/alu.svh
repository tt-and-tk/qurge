/**
 * aluに関する関数など
 */

`ifndef ALU_SVH
`define ALU_SVH

`include "util.svh"
`include "decoder.svh"

package alu_p;
    import machine_p::*;

    // 列挙体
    typedef enum type_t {   // 機械語の命令タイプ
        N_TYPE,   // 処理を実行しない
        P_TYPE,   // 演算系
        S_TYPE,   // シフト系
        A_TYPE,   // 代入系
        F_TYPE,   // 分岐系
        J_TYPE,   // ジャンプ系
        M_TYPE,   // メモリ系
        IO_TYPE   // 標準入出力系
    } type_enum;

    // 変数型
    typedef logic [31:0] register_t;   // レジスタサイズ

    // 定数
    localparam machine_p::addr_t REGISTER_MAX_ADDR = 6'h34;   // レジスタ配列の最大有効番地(0x00〜この値が有効)

    // 関数
    function util_p::bool_t is_readable(   // そのアドレスのレジスタが読み込み可能か
        machine_p::addr_t addr
    );
        // CPU内のレジスタ
        if (6'h00 <= addr && addr <= 6'h0f)
            is_readable = util_p::TRUE;
        // スタックポインタ
        else if (addr == 6'h10)
            is_readable = util_p::TRUE;
        // 空き
        else if (6'h11 <= addr && addr <= 6'h1b)
            is_readable = util_p::FALSE;
        // フラグ
        else if (addr == 6'h1c)
            is_readable = util_p::TRUE;
        // 引数が格納されているレジスタの一つ目の番地
        else if (addr == 6'h1d)
            is_readable = util_p::TRUE;
        // 演算結果
        else if (addr == 6'h1e)
            is_readable = util_p::TRUE;
        // プログラムカウンタ
        else if (addr == 6'h1f)
            is_readable = util_p::TRUE;
        // タクトスイッチ
        else if (addr == 6'h20)
            is_readable = util_p::TRUE;
        // DIPスイッチ
        else if (addr == 6'h21)
            is_readable = util_p::TRUE;
        // LED
        else if (addr == 6'h22)
            is_readable = util_p::FALSE;
        // RGB LED
        else if (addr == 6'h23)
            is_readable = util_p::FALSE;
        // Pmod A
        else if (addr == 6'h24)
            is_readable = util_p::FALSE;
        // Pmod B
        else if (addr == 6'h25)
            is_readable = util_p::FALSE;
        // AR
        else if (addr == 6'h26 || addr == 6'h28)
            is_readable = util_p::FALSE;
        // I2C
        else if (addr == 6'h27)
            is_readable = util_p::FALSE;
        // 空き
        else if (addr == 6'h29)
            is_readable = util_p::FALSE;
        // SPI
        else if (addr == 6'h2a)
            is_readable = util_p::TRUE;
        // アナログピン
        else if (addr == 6'h2b)
            is_readable = util_p::FALSE;    // オミット
        // XADC
        else if (addr == 6'h2c)
            is_readable = util_p::FALSE;    // オミット
        // GPIO
        else if (6'h2d <= addr && addr <= 6'h30)
            is_readable = util_p::FALSE;
        // 空き
        else if (6'h31 <= addr && addr <= 6'h34)
            is_readable = util_p::FALSE;
        // 定義されていない
        else
            is_readable = util_p::FALSE;
    endfunction
    function util_p::bool_t is_writable(  // そのアドレスのレジスタが書き込み可能か
        machine_p::addr_t addr
    );
        // CPU内のレジスタ
        if (6'h00 <= addr && addr <= 6'h0f)
            is_writable = util_p::TRUE;
        // スタックポインタ
        else if (addr == 6'h10)
            is_writable = util_p::TRUE;
        // 空き
        else if (6'h11 <= addr && addr <= 6'h1b)
            is_writable = util_p::FALSE;
        // フラグ
        else if (addr == 6'h1c)
            is_writable = util_p::FALSE;
        // 引数が格納されているレジスタの一つ目の番地
        else if (addr == 6'h1d)
            is_writable = util_p::TRUE;
        // 演算結果
        else if (addr == 6'h1e)
            is_writable = util_p::TRUE;
        // プログラムカウンタ
        else if (addr == 6'h1f)
            is_writable = util_p::FALSE;
        // タクトスイッチ
        else if (addr == 6'h20)
            is_writable = util_p::FALSE;
        // DIPスイッチ
        else if (addr == 6'h21)
            is_writable = util_p::FALSE;
        // LED
        else if (addr == 6'h22)
            is_writable = util_p::TRUE;
        // RGB LED
        else if (addr == 6'h23)
            is_writable = util_p::TRUE;
        // Pmod A
        else if (addr == 6'h24)
            is_writable = util_p::TRUE;
        // Pmod B
        else if (addr == 6'h25)
            is_writable = util_p::TRUE;
        // AR
        else if (addr == 6'h26 || addr == 6'h28)
            is_writable = util_p::TRUE;
        // I2C
        else if (addr == 6'h27)
            is_writable = util_p::TRUE;
        // 空き
        else if (addr == 6'h29)
            is_writable = util_p::FALSE;
        // SPI
        else if (addr == 6'h2a)
            is_writable = util_p::TRUE;
        // アナログピン
        else if (addr == 6'h2b)
            is_writable = util_p::FALSE;    // オミット
        // XADC
        else if (addr == 6'h2c)
            is_writable = util_p::FALSE;    // オミット
        // GPIO
        else if (6'h2d <= addr && addr <= 6'h30)
            is_writable = util_p::TRUE;
        // 空き
        else if (6'h31 <= addr && addr <= 6'h34)
            is_writable = util_p::FALSE;
        // 定義されていない
        else
            is_writable = util_p::FALSE;
    endfunction
    // そのアドレスのレジスタの各ビットを使うかを，ビットごとに表した値を返す．
    // 使うビットの位置を1，使わないビットの位置を0とする(ビットの数ではない)．
    // 使わないビットは常に0になる．
    // 関数内の'1は全ビットが1，'0は全ビットが0の値を表す
    function register_t used_bits(
        machine_p::addr_t addr
    );
        // CPU内のレジスタ
        if (6'h00 <= addr && addr <= 6'h0f)
            used_bits = '1;
        // スタックポインタ
        else if (addr == 6'h10)
            used_bits = '1;
        // 空き
        else if (6'h11 <= addr && addr <= 6'h1b)
            used_bits = '0;
        // フラグ．値を格納する命令がない
        else if (addr == 6'h1c)
            used_bits = '0;
        // 引数が格納されているレジスタの一つ目の番地
        else if (addr == 6'h1d)
            used_bits = '1;
        // 演算結果
        else if (addr == 6'h1e)
            used_bits = '1;
        // プログラムカウンタ．値はレジスタ配列ではなく命令の番地として別に持つ
        else if (addr == 6'h1f)
            used_bits = '0;
        // タクトスイッチ
        else if (addr == 6'h20)
            used_bits = 32'hf;
        // DIPスイッチ
        else if (addr == 6'h21)
            used_bits = 32'h3;
        // LED
        else if (addr == 6'h22)
            used_bits = 32'hf;
        // RGB LED
        else if (addr == 6'h23)
            used_bits = 32'h3f;
        // Pmod A
        else if (addr == 6'h24)
            used_bits = 32'hff;
        // Pmod B
        else if (addr == 6'h25)
            used_bits = 32'hff;
        // AR8〜AR13
        else if (addr == 6'h26)
            used_bits = 32'h3f;
        // I2C
        else if (addr == 6'h27)
            used_bits = 32'h7;
        // AR0〜AR7
        else if (addr == 6'h28)
            used_bits = 32'hff;
        // 空き
        else if (addr == 6'h29)
            used_bits = '0;
        // SPI
        else if (addr == 6'h2a)
            used_bits = 32'hf;
        // アナログピン
        else if (addr == 6'h2b)
            used_bits = '0;    // オミット
        // XADC
        else if (addr == 6'h2c)
            used_bits = '0;    // オミット
        // GPIO0〜GPIO7．どのピンにも出力しない
        else if (addr == 6'h2d)
            used_bits = '0;
        // GPIO8〜GPIO15
        else if (addr == 6'h2e)
            used_bits = 32'hff;
        // GPIO16〜GPIO23
        else if (addr == 6'h2f)
            used_bits = 32'hff;
        // GPIO24〜GPIO26
        else if (addr == 6'h30)
            used_bits = 32'h7;
        // 空き
        else if (6'h31 <= addr && addr <= 6'h34)
            used_bits = '0;
        // 定義されていない
        else
            used_bits = '0;
    endfunction

    // 命令のデコード時点で分かる情報(命令種別・func・レジスタ番地)から，その命令が実行可能かを
    // 判定する．
    function util_p::bool_t is_instruction_executable(
        logic             pc_valid,  // 命令を，命令を置ける番地(ROMの範囲内またはメモリの後半)から取得できたか
        machine_p::type_t m_type,
        machine_p::func_t func,
        machine_p::addr_t rs1,
        machine_p::addr_t rs2,
        machine_p::addr_t rd,
        machine_p::imm_t  imm
    );
        // 範囲外から取得した命令は，中身がnop()相当であっても実行不可扱いにする
        if (!pc_valid) begin
            is_instruction_executable = util_p::FALSE;
        // rs1・rs2・rdは命令の種類によらず機械語中に必ず存在するフィールドのため，命令が
        // 実際には使わない番地であっても，レジスタ配列の宣言範囲を超えていれば無条件に
        // 実行不可扱いにする(範囲外番地を読み出さないようにするため)．immは番地として
        // 使われる箇所(DIV・DIVUの余り書き込み先)が使用時に限られ，そこで個別にチェック済みのためここでは見ない
        end else if (rs1 > REGISTER_MAX_ADDR || rs2 > REGISTER_MAX_ADDR || rd > REGISTER_MAX_ADDR) begin
            is_instruction_executable = util_p::FALSE;
        end else begin
            unique case (m_type)
                // 処理を実行しないだけなので，funcがNOPであれば常に有効
                N_TYPE: is_instruction_executable = (func == NOP);
                P_TYPE: begin
                    unique case (func)
                        // 単項演算: 読み出し元1つと書き込み先が有効か
                        NOT:
                            is_instruction_executable = is_readable(rs1) && is_writable(rd);
                        // 二項演算: 読み出し元2つと書き込み先が有効か
                        AND, OR, XOR, NAND, ADD, SUB, MUL:
                            is_instruction_executable = is_readable(rs1) && is_readable(rs2) && is_writable(rd);
                        // 割り算: 読み出し元2つと書き込み先(イミディエイトデータ使用時は余りの書き込み先も)が有効か
                        DIV, DIVU:
                            is_instruction_executable = is_readable(rs1) && is_readable(rs2) && is_writable(rd)
                                && (!imm[32] || is_writable(imm[5:0]));
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                S_TYPE: begin
                    unique case (func)
                        // シフト系: イミディエイトデータ使用時は読み出し元1つ，未使用時は読み出し元2つと書き込み先が有効か
                        SLL, SRL, SLA, SRA:
                            is_instruction_executable = imm[32]
                                ? (is_readable(rs1) && is_writable(rd))
                                : (is_readable(rs1) && is_readable(rs2) && is_writable(rd));
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                A_TYPE: begin
                    unique case (func)
                        // 代入系: イミディエイトデータ使用時は書き込み先のみ，未使用時は読み出し元と書き込み先が有効か
                        MOV:
                            is_instruction_executable = imm[32]
                                ? is_writable(rd)
                                : (is_readable(rs1) && is_writable(rd));
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                F_TYPE: begin
                    unique case (func)
                        // 分岐系: 読み出し元2つが有効で，かつ分岐先はイミディエイトデータでの指定に限る
                        EQ, NE, LT, GT, ELT, EGT, LTU, GTU, ELTU, EGTU:
                            is_instruction_executable = is_readable(rs1) && is_readable(rs2) && imm[32];
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                J_TYPE: begin
                    unique case (func)
                        // ジャンプ・関数呼び出し: ジャンプ先をイミディエイトデータで指定するか，読み出し元が有効か
                        JMP, CALL: is_instruction_executable = imm[32] || is_readable(rs1);
                        // 関数リターンは引数を使わないので，デコード時点では常に有効(実行時にも別途判定する)
                        RET:       is_instruction_executable = util_p::TRUE;
                        // それ以外は不正な命令として無効扱い
                        default:   is_instruction_executable = util_p::FALSE;
                    endcase
                end
                M_TYPE: begin
                    unique case (func)
                        // メモリ読み込み: 書き込み先が有効で，かつ読み込みアドレスをイミディエイトデータで
                        // 指定するか読み出し元が有効か
                        RM:      is_instruction_executable = is_writable(rd) && (imm[32] || is_readable(rs1));
                        // メモリ書き込み: 書き込むデータの読み出し元が有効で，かつ書き込みアドレスを
                        // イミディエイトデータで指定するか読み出し元が有効か
                        WM:      is_instruction_executable = is_readable(rs2) && (imm[32] || is_readable(rs1));
                        // レジスタ相対のメモリ読み込み: 書き込み先と番地の基準になる読み出し元が有効で，
                        // かつ番地に足すイミディエイトデータを指定しているか
                        RMR:     is_instruction_executable = is_readable(rs1) && is_writable(rd) && imm[32];
                        // レジスタ相対のメモリ書き込み: 書き込むデータと番地の基準になる読み出し元が有効で，
                        // かつ番地に足すイミディエイトデータを指定しているか
                        WMR:     is_instruction_executable = is_readable(rs1) && is_readable(rs2) && imm[32];
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                IO_TYPE: begin
                    unique case (func)
                        // 標準入力: 書き込み先が有効か
                        SCAN:    is_instruction_executable = is_writable(rd);
                        // 標準出力: 出力するデータをイミディエイトデータで指定するか，読み出し元が有効か
                        PRINT:   is_instruction_executable = imm[32] || is_readable(rs1);
                        // それ以外は不正な命令として無効扱い
                        default: is_instruction_executable = util_p::FALSE;
                    endcase
                end
                // 定義されていない命令タイプは無効扱い
                default: is_instruction_executable = util_p::FALSE;
            endcase
        end
    endfunction
endpackage

// インターフェース定義

`endif
