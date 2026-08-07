/**
 * 機械語を生成する関数
 *
 * 新しい命令を追加する場合，このファイルへ命令タイプ・funcの定数と生成関数を追加した後，
 * decorder_sv.sv(機械語の分解)→alu_sv.sv(実行)の順に対応する処理を追加すること．
 */

`ifndef MACHINE_SVH
`define MACHINE_SVH

// 機械語の構成
//
//  31  29 28  23 22  19 18 13 12  7 6  1  0
// | type | func | mask | rs1 | rs2 | rd |imm| + イミディエイトデータ(32bit)

package machine_p;
    typedef logic [63:0] machine_t;   // 機械語のサイズ
    typedef logic [ 2:0] type_t;      // 命令タイプ
    typedef logic [ 5:0] func_t;      // 命令
    typedef logic [ 3:0] mask_t;      // マスクサイズ
    typedef logic [ 5:0] addr_t;      // レジスタのアドレスサイズ
    typedef logic [32:0] imm_t;       // イミディエイトデータのサイズ．最上位ビットはイミディエイトデータを使用するかのフラグ

    // 各機械語
    localparam func_t NOP  = 6'h00;
    localparam func_t AND  = 6'h00;
    localparam func_t OR   = 6'h01;
    localparam func_t XOR  = 6'h02;
    localparam func_t NOT  = 6'h03;
    localparam func_t NAND = 6'h04;
    localparam func_t ADD  = 6'h05;
    localparam func_t SUB  = 6'h06;
    localparam func_t MUL  = 6'h07;
    localparam func_t DIV  = 6'h08;
    localparam func_t SLL  = 6'h00;
    localparam func_t SRL  = 6'h01;
    localparam func_t SLA  = 6'h02;
    localparam func_t SRA  = 6'h03;
    localparam func_t MOV  = 6'h00;
    localparam func_t EQ   = 6'h00;
    localparam func_t NE   = 6'h01;
    localparam func_t LT   = 6'h02;
    localparam func_t GT   = 6'h03;
    localparam func_t ELT  = 6'h04;
    localparam func_t EGT  = 6'h05;
    localparam func_t JMP  = 6'h00;
    localparam func_t CALL = 6'h01;
    localparam func_t RET  = 6'h02;
    localparam func_t RM   = 6'h00;
    localparam func_t WM   = 6'h01;
    localparam func_t BRM  = 6'h02;
    localparam func_t BWM  = 6'h03;
    localparam func_t SCAN  = 6'h00;
    localparam func_t PRINT = 6'h01;

    // 処理を実行しない(N系)
    function machine_t nop(

    );
        nop = {3'h0, NOP, 4'h0, 6'h00, 6'h00, 6'h00, 33'h000000000};
    endfunction

    // 演算系(P系)
    function machine_t and_(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        and_ = {3'h1, AND, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t or_(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        or_ = {3'h1, OR, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t xor_(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        xor_ = {3'h1, XOR, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t not_(
        input addr_t rs1,
        input addr_t rd
    );
        not_ = {3'h1, NOT, 4'h0, rs1, 6'h00, rd, 33'h000000000};
    endfunction
    function machine_t nand_(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        nand_ = {3'h1, NAND, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t add(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        add = {3'h1, ADD, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t sub(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        sub = {3'h1, SUB, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t mul(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd
    );
        mul = {3'h1, MUL, 4'h0, rs1, rs2, rd, 33'h000000000};
    endfunction
    function machine_t div(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        div = {3'h1, DIV, 4'h0, rs1, rs2, rd, imm};
    endfunction

    // シフト系(S系)
    function machine_t sll(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        sll = {3'h2, SLL, 4'h0, rs1, rs2, rd, imm};
    endfunction
    function machine_t srl(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        srl = {3'h2, SRL, 4'h0, rs1, rs2, rd, imm};
    endfunction
    function machine_t sla(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        sla = {3'h2, SLA, 4'h0, rs1, rs2, rd, imm};
    endfunction
    function machine_t sra(
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        sra = {3'h2, SRA, 4'h0, rs1, rs2, rd, imm};
    endfunction

    // 代入系(A系)
    function machine_t mov(
        input mask_t mask,
        input addr_t rs1,
        input addr_t rd,
        input imm_t imm
    );
        mov = {3'h3, MOV, mask, rs1, 6'h00, rd, imm};
    endfunction

    // 分岐系(F系)
    function machine_t eq(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        eq = {3'h4, EQ, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t ne(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        ne = {3'h4, NE, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t lt(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        lt = {3'h4, LT, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t gt(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        gt = {3'h4, GT, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t elt(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        elt = {3'h4, ELT, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t egt(
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        egt = {3'h4, EGT, 4'h0, rs1, rs2, 6'h00, imm};
    endfunction

    // ジャンプ系(J系)
    function machine_t jmp(
        input addr_t rs1,
        input imm_t imm
    );
        jmp = {3'h5, JMP, 4'h0, rs1, 6'h00, 6'h00, imm};
    endfunction
    // 関数呼び出し(戻り先をスタックに保存してジャンプ)
    function machine_t call(
        input addr_t rs1,
        input imm_t imm
    );
        call = {3'h5, CALL, 4'h0, rs1, 6'h00, 6'h00, imm};
    endfunction
    // 関数リターン(スタックから戻り先を復元してジャンプ．引数なし)
    function machine_t ret(

    );
        ret = {3'h5, RET, 4'h0, 6'h00, 6'h00, 6'h00, 33'h000000000};
    endfunction

    // メモリ系(M系)
    function machine_t rm(
        input mask_t mask,
        input addr_t rs1,
        input addr_t rd,
        input imm_t imm
    );
        rm = {3'h6, RM, mask, rs1, 6'h00, rd, imm};
    endfunction
    function machine_t wm(
        input mask_t mask,
        input addr_t rs1,
        input addr_t rs2,
        input imm_t imm
    );
        wm = {3'h6, WM, mask, rs1, rs2, 6'h00, imm};
    endfunction
    function machine_t brm(
        input mask_t mask,
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        brm = {3'h6, BRM, mask, rs1, rs2, rd, imm};
    endfunction
    function machine_t bwm(
        input mask_t mask,
        input addr_t rs1,
        input addr_t rs2,
        input addr_t rd,
        input imm_t imm
    );
        bwm = {3'h6, BWM, mask, rs1, rs2, rd, imm};
    endfunction

    // 標準入出力系(IO系)
    function machine_t scan(
        input addr_t rd
    );
        scan = {3'h7, SCAN, 4'h0, 6'h00, 6'h00, rd, 33'h000000000};
    endfunction
    function machine_t print(
        input addr_t rs1,
        input imm_t imm
    );
        print = {3'h7, PRINT, 4'h0, rs1, 6'h00, 6'h00, imm};
    endfunction

endpackage

`endif
