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

// 命令パイプライン処理の概要．FETCH_REQUEST(命令の読み出しを要求する)→FETCH_ROM_CAPTUREまたは
// FETCH_RAM_CAPTURE(読み出した命令を取り込む)→CHECK(実行可否を確認する)→EXECUTEの4フェーズを基本とする．
// 命令はプログラムカウンタに応じてROMかメインメモリのコード領域から読み出し，取り込むフェーズは読み出し元ごとに分ける．
// ROMはクロックに同期した読み出しのため，番地を出した次のサイクルに結果が確定する．メインメモリは応答を
// 待つ必要があり，読み出しも1回32ビットのため，64ビットの命令をイミディエイトデータ・命令語の順に2回に分けて読む．
//
// 実行可否の確認は，命令のデコード時点で分かる情報(命令種別・func・レジスタ番地など)はCHECK
// フェーズでalu.svh::is_instruction_executable()により一括判定する．レジスタの値そのものに基づく
// 判定は値が確定するまで行えないため，値が確定するEXECUTE中に個別に判定する．
//
// 次の命令がROMにある場合は，実行に複数サイクルかかる命令のうち分岐・ジャンプを行わないもの(メモリ・
// 標準入出力の応答待ちや割り算の完了待ちなど)の待機中に，次の命令をあらかじめROMから取得してデコードしておく
// (先読み)．待機中は次に実行する命令の番地が順番どおりの次の番地に確定しているためである．コード領域の命令を
// 先読みしないのは，メインメモリの読み出しポートを実行中の命令と共用しているため．
// 読み出し・書き込みに使うレジスタ番地の依存関係も先読みの時点で確認しておき，直前の命令がこのサイクルに
// 書き込む値をレジスタの読み出し結果の代わりに使う(フォワーディング)ことで，命令完了時に
// FETCH_REQUEST/FETCH_ROM_CAPTURE/CHECKを省略して直接次の命令のEXECUTEから始められる場合がある．
// 先読みが成立するには実行フェーズが3サイクル以上続く必要がある(ROMの読み出しに1サイクルかかり，
// 取り込んだ結果を使えるのはさらに次のサイクルから)．これに届かない命令と，分岐・ジャンプを行う命令
// (メモリの応答を待つため複数サイクルかかるCALL・RETを含む)，次の命令がコード領域にある命令は，毎回4フェーズすべてを経る．
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

    // 符号あり割り算回路用(DIV)
    output logic [31:0] div_divisor_tdata,
    output logic        div_divisor_tvalid,
    output logic [31:0] div_dividend_tdata,
    output logic        div_dividend_tvalid,
    input  logic [63:0] div_dout_tdata,
    input  logic        div_dout_tvalid,

    // 符号なし割り算回路用(DIVU)
    output logic [31:0] divu_divisor_tdata,
    output logic        divu_divisor_tvalid,
    output logic [31:0] divu_dividend_tdata,
    output logic        divu_dividend_tvalid,
    input  logic [63:0] divu_dout_tdata,
    input  logic        divu_dout_tvalid,

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
    output logic        stdout_tvalid,

    // Pmod A・Pmod B
    output logic [7:0] ja,
    output logic [7:0] jb,

    // Arduino
    output logic [13:0] ar,       // AR0(ar[0])〜AR13(ar[13])
    output logic        a,        // 単体のデジタルI/Oピン
    output logic        ar_sda,
    output logic        ar_scl,
    output logic        ck_mosi,
    output logic        ck_sck,
    output logic        ck_ss,
    input  logic        ck_miso,

    // ラズパイヘッダー
    output logic [26:8] gpio
    );

    // import文
    import alu_p::*;
    import ram_p::*;
    import machine_p::*;
    import util_p::*;

    // レジスタの初期値．FPGAのコンフィグ直後の値とリセット時の値を兼ねており，
    // どちらの経路で初期化されても同じ状態から始まる
    localparam register_t REGISTER_INIT[REGISTER_MAX_ADDR:0] = '{
        // スタックはメモリの前半に置き，前半の末尾から番地の小さい方へ伸ばす．スタックポインタは最後に積んだ値の番地を指すため，
        // 何も積んでいない初期状態では，前半の末尾のすぐ上の番地(メモリの後半にあるコード領域の先頭番地)にしておく
        SP_ADDR:  register_t'(CODE_AREA_BASE),
        // Arduino SPIのSSはアクティブLowのため，非選択を表すHighにする
        SPI_ADDR: 32'h1,
        default:  '0
    };

    // 内部レジスタ
    register_t register[REGISTER_MAX_ADDR:0] = REGISTER_INIT;

    // 外部ピンからの非同期入力の準安定状態を消す2段のシフトレジスタ(添字1が後段)
    (* ASYNC_REG = "TRUE" *) logic [1:0][3:0] btn_sync = '0;  // タクトスイッチ
    (* ASYNC_REG = "TRUE" *) logic [1:0][1:0] sw_sync = '0;   // DIPスイッチ
    (* ASYNC_REG = "TRUE" *) logic [1:0] miso_sync = '0;      // Arduino SPIのMISO

    // 実行フェーズ
    cpu_phase_enum cpu_phase = CPU_FETCH_REQUEST;

    // 実行できない命令を検出して停止していることを表すフラグ．立っている間は下のリセット
    // ブロックの中身を毎サイクル実行し続けて停止状態を保ち，外部からのリセット(resetn)が
    // 入るまで下りない．
    // このフラグを下ろす代入は，下のリセット処理の中(if (!resetn)の中)以外に置かないこと
    // (停止状態から自力で抜けると，外部からのリセットを経ずに同じ命令を再実行する動作になる)．
    logic is_halted = 1'b0;

    // ===== 命令の保持・先読み =====
    // 現在実行中の命令と，実行中にあらかじめ取得しておいた次の命令の2系統を保持する

    // CHECK/EXECUTEフェーズで検証・実行の対象になっている命令．FETCH_REQUEST/FETCH_ROM_CAPTURE/FETCH_RAM_CAPTURE
    // フェーズの間は，まだ取り込みが済んでおらず前回実行した命令の値が残ったままで，意味を持たない．
    machine_p::machine_t current_instruction = nop();
    // current_instructionを，命令を置ける番地(ROMの実容量範囲内またはコード領域)から取得できたか
    // (CPU_FETCH_ROM_CAPTURE・CPU_FETCH_RAM_CAPTUREで確定する)
    logic current_instruction_pc_valid = 1'b1;

    // CPU_FETCH_RAM_CAPTUREで読み出し中のワードが命令の上位32ビット(命令語)か．0なら下位32ビット(イミディエイトデータ)
    logic fetching_upper_word = 1'b0;

    // 実行中に先読みしておいた次の命令を保持するバッファ．複数サイクルにまたがる命令の
    // 待機中に埋まり，1サイクルで完了する命令の実行中は埋まらないまま次の命令へ進む．
    // prefetched_instruction_validが0の間は，取り込んだ直後に破棄された値など意味のない内容が
    // 残っていることがあるため，prefetched_instruction_validを確かめずに参照してはならない
    // (prefetched_instruction_pc_validも同様)．
    machine_p::machine_t prefetched_instruction = nop();
    // prefetched_instructionが先読み済みの有効な命令かどうか
    logic prefetched_instruction_valid = 1'b0;
    // prefetched_instructionをROMの実容量範囲内から取得できたか
    logic prefetched_instruction_pc_valid = 1'b1;

    // 次命令を先読みしてよいかどうかを示すフラグ
    logic can_prefetch;
    assign can_prefetch = (cpu_phase == CPU_EXECUTE)    // 実行フェーズの間のみ先読みが可能
        && (command.m_type != J_TYPE)                   // ジャンプ系の命令なら，飛び先が順番どおりの次の番地とは限らないため行わない
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

    util_p::state_enum ram_read_state = IDLE;  // メモリ読み込み(RM・RMR)とRETの実行状態
    util_p::state_enum ram_write_state = IDLE; // メモリ書き込み(WM・WMR)とCALLの実行状態
    util_p::state_enum stdin_state = IDLE;     // 標準入力(SCAN)の実行状態
    util_p::state_enum stdout_state = IDLE;    // 標準出力(PRINT)の実行状態
    util_p::state_enum mul_state = IDLE;       // 掛け算(MUL)の実行状態
    util_p::state_enum div_state = IDLE;       // 割り算(DIV/DIVU)の実行状態

    // 掛け算の結果．確定まで1サイクル待つため，サイクルをまたいで値を保持できない
    // 組み合わせ回路(write_value)ではなく，この専用レジスタへ格納する
    register_t mul_result_r = '0;

    // 実行中の割り算命令が応答を待つ除算IPの出力．DIVは符号あり，DIVUは符号なしの除算IPから受け取り，
    // 割り算以外の命令では応答が届かない扱い(tvalid・tdataとも0)にする．
    // 2つのIPのtdataをORでまとめないのは，使わない側のIPも前回の除算結果を出し続けているため
    logic        div_result_tvalid;
    logic [63:0] div_result_tdata;
    assign div_result_tvalid = (func_r == DIV)  ? div_dout_tvalid
                             : (func_r == DIVU) ? divu_dout_tvalid
                             : 1'b0;
    assign div_result_tdata  = (func_r == DIV)  ? div_dout_tdata
                             : (func_r == DIVU) ? divu_dout_tdata
                             : '0;

    // ===== コード領域からの命令の取得(組み合わせ回路) =====
    // プログラムカウンタのうち，コード領域の先頭の命令のプログラムカウンタ(CODE_AREA_PC_BASE)から，コード領域に置ける
    // 命令数(CODE_AREA_PC_NUM)ぶんの範囲がコード領域に対応する．命令数は2のべき乗で，先頭のプログラムカウンタは
    // 命令数の倍数とするため，この範囲のプログラムカウンタは次の2つに分けられる
    // - 下位ビット: その命令がコード領域の先頭から何番目か(0〜命令数-1)
    // - 上位ビット: 範囲内のどの命令でも同じ値(先頭のプログラムカウンタの上位ビット)

    // プログラムカウンタのうち，コード領域の先頭から何番目の命令かを表す下位ビットの幅
    localparam int CODE_AREA_PC_WIDTH = $clog2(rom_p::CODE_AREA_PC_NUM);
    // コード領域を指すプログラムカウンタに共通する上位ビットの値
    localparam logic [31-CODE_AREA_PC_WIDTH:0] CODE_AREA_PC_UPPER = rom_p::CODE_AREA_PC_BASE >> CODE_AREA_PC_WIDTH;

    // コード領域についての判定は，次の2つの前提の上に成り立つ
    // ROMの命令数の上限を変えるなどして前提が崩れた場合は，誤った判定のまま合成されないよう，組み立て時にエラーにする
    // 先頭のプログラムカウンタが命令数の倍数でなければ，上の分け方が成り立たない
    if (rom_p::CODE_AREA_PC_BASE % rom_p::CODE_AREA_PC_NUM != 0)
        $error("コード領域の先頭のプログラムカウンタがコード領域の命令数の倍数になっていません");
    // 先読みの取り込みでは，次の番地がROMへ渡せる幅(pc_bus_t)に収まらないことを，ROMの外を指すことの判定に使う
    // このため，先頭のプログラムカウンタは，その幅で表せる範囲のちょうど直後でなければならない
    if (rom_p::CODE_AREA_PC_BASE != 2 ** $bits(rom_p::pc_bus_t))
        $error("コード領域の先頭のプログラムカウンタが，ROMへ渡せる幅で表せる範囲の直後になっていません");

    // プログラムカウンタがコード領域を指しているか．上位ビットがコード領域に共通する値と一致するかで判定する
    // (一致比較1つで範囲の下端・上端の両方を判定できる．大小比較で書くと下端・上端の2つが要る)
    logic pc_in_code_area;
    assign pc_in_code_area = (register[PC_ADDR][31:CODE_AREA_PC_WIDTH] == CODE_AREA_PC_UPPER);

    // プログラムカウンタが指す命令の，下位ワード(イミディエイトデータ)・上位ワード(命令語)のメインメモリ上の番地
    ram_p::address_bus_t fetch_lower_address;
    ram_p::address_bus_t fetch_upper_address;
    // 下位ワードの番地は，コード領域の先頭番地 + 先頭から何番目の命令か × 8(1命令のバイト数)．コード領域の先頭番地は
    // メモリの後半の先頭で最上位ビットだけが立っており，何番目か × 8はそれより下のビットに収まる．立っているビットが
    // 重ならず加算とORの結果が同じになるため，加算器を使わずORで組み立てる
    assign fetch_lower_address = ram_p::address_bus_t'(CODE_AREA_BASE)                                       // 最上位ビット: コード領域の先頭番地
                               | (ram_p::address_bus_t'(register[PC_ADDR][CODE_AREA_PC_WIDTH-1:0]) << 3);  // その下のビット: 何番目の命令か × 8(下位3ビットは0)
    // 上位ワードの番地は下位ワードの4バイト後．下位ワードの番地は8の倍数(下位3ビットが0)のため，4を表すビットを立てるだけでよい
    assign fetch_upper_address = fetch_lower_address | ram_p::address_bus_t'(4);

    // ===== 分岐・ジャンプ先・次番地の算出(組み合わせ回路) =====
    // 実行フェーズの間のみ意味を持つ(それ以外のフェーズでは直前に実行した命令の値が残っている)

    // ROMへ出力する(切り詰め前の)命令アドレスの値が，ROMのアドレスバス幅に収まっているか
    util_p::bool_t pc_fits_in_width;

    // 分岐命令の比較に使う，rs1とrs2の一致・大小関係．符号あり・符号なしのすべての比較方法で共有する
    logic rs_equal;            // rs1とrs2が一致するか
    logic rs_less_unsigned;    // 符号なし整数としてrs1がrs2より小さいか
    logic rs_less_signed;      // 符号あり整数としてrs1がrs2より小さいか
    assign rs_equal         = (rs1_val_r == rs2_val_r);
    assign rs_less_unsigned = (rs1_val_r <  rs2_val_r);
    // 符号ビットが異なれば負である側が小さく，同じなら符号なし整数としての大小と一致する．
    // $signedで別に比較しないのは，符号あり・符号なしで32ビットの大小比較器を2つ持つことになり回路規模が増えるため
    assign rs_less_signed   = (rs1_val_r[31] != rs2_val_r[31]) ? rs1_val_r[31] : rs_less_unsigned;

    // 分岐命令の比較結果がtrueかどうか(定義されていない比較方法はfalseとして扱う)
    logic is_branch_taken;
    assign is_branch_taken = (command.m_type == F_TYPE)
        && ((func_r == EQ   &&  rs_equal)
         || (func_r == NE   && !rs_equal)
         || (func_r == LT   &&  rs_less_signed)
         || (func_r == GT   && !rs_less_signed && !rs_equal)
         || (func_r == ELT  &&  (rs_less_signed || rs_equal))
         || (func_r == EGT  && !rs_less_signed)
         || (func_r == LTU  &&  rs_less_unsigned)
         || (func_r == GTU  && !rs_less_unsigned && !rs_equal)
         || (func_r == ELTU &&  (rs_less_unsigned || rs_equal))
         || (func_r == EGTU && !rs_less_unsigned));

    // 飛び先を指定してプログラムカウンタを書き換える命令かどうか(定義されていない命令コードはfalseとして扱う)
    logic is_jumping;
    assign is_jumping = (command.m_type == J_TYPE)
        && (func_r == JMP || func_r == CALL || func_r == RET);

    // 移動する命令の飛び先．関数リターンはメモリ上のスタックから読み出した戻り先(読み出しが
    // 完了したサイクルにのみ有効)，それ以外はイミディエイトデータまたはレジスタで指定された番地になる
    register_t jump_target;
    assign jump_target = (func_r == RET) ? ram_read.data
                       : imm_r[32]       ? imm_r[31:0]
                       : rs1_val_r;

    // メモリ系の命令と，戻り先を積み下ろすCALL・RETがアクセスする番地(アドレスバス幅へ切り詰める前の値)．
    // funcの値は命令タイプごとに割り当てられ，異なる命令タイプで同じ値が現れるため，命令タイプとあわせて判定する
    register_t mem_address;
    assign mem_address = (command.m_type == J_TYPE && func_r == CALL)                   ? register[SP_ADDR] - 4     // 戻り先を積むスタックポインタの1ワード下
                       : (command.m_type == J_TYPE && func_r == RET)                    ? register[SP_ADDR]         // 戻り先を下ろすスタックポインタが指す番地
                       : (command.m_type == M_TYPE && (func_r == RMR || func_r == WMR)) ? rs1_val_r + imm_r[31:0]   // rs1にイミディエイトデータを足した番地(32ビットで折り返す)
                       : imm_r[32]                                                      ? imm_r[31:0]               // イミディエイトデータで指定された番地
                       : rs1_val_r;                                                                                 // rs1で指定された番地

    // mem_addressが読み書きしてよい範囲に収まっているか．
    // J系の命令のうちメモリを読み書きするのはCALL・RETだけで，その番地は飛び先ではなく，戻り先を積み下ろしするスタックの番地である．
    // スタックはメモリの前半に置くため，J系では前半に収まる番地だけを範囲内とする(空のスタックでのRETを停止させ，
    // CALLが後半のコード領域を書き換えないようにするため)．それ以外の命令はメモリ全体を読み書きできる．
    // 前半の大きさ(コード領域の先頭番地)は2のべき乗のため，前半に収まるかはビット幅で判定できる
    util_p::bool_t mem_address_in_range;
    assign mem_address_in_range = (command.m_type == J_TYPE)
        ? util_p::is_within_bit_width(mem_address, $clog2(CODE_AREA_BASE))
        : util_p::is_within_bit_width(mem_address, $bits(ram_p::address_bus_t));

    // 分岐・ジャンプを行わない命令の次の番地(現在の番地の直後)．オペランドの値に依存せず
    // プログラムカウンタだけから求まる
    register_t sequential_pc;
    assign sequential_pc = register[PC_ADDR] + 1;

    // 実行中の命令がこのサイクルにプログラムカウンタへ書き込む値．参照してよいのは実行フェーズの
    // 間だけ．それ以外のフェーズでは，命令タイプはこれから確認する命令のものであるのに対し，
    // 比較と飛び先の指定に使う値は直前に実行した命令のものが残っており，別々の命令に由来する
    // 値から番地を求めることになるため，結果に意味がない．
    register_t next_pc;
    assign next_pc = is_branch_taken ? register[PC_ADDR] + imm_r[31:0]  // 比較結果がtrueの分岐は指定されたぶん離れた番地へ
                   : is_jumping      ? jump_target                      // 移動する命令は指定された飛び先へ
                   : sequential_pc;                                     // それ以外は次の番地へ進む

    // ===== 1サイクルで完了する命令の結果の算出(組み合わせ回路) =====
    // 実行フェーズの間のみ意味を持つ．ここでは結果を求めるだけで，レジスタへ書き込むかどうかと，
    // 不正な命令での停止(is_halted)はメインの順序回路が判定する(is_haltedは順序回路が駆動する
    // レジスタであり，ここから停止させることはできない)

    // 1サイクルでレジスタへの書き込みまで完了する命令の結果．それ以外の命令では0になり使われない
    register_t write_value;

    // シフト系のシフト量．イミディエイトデータまたはrs2の下位5bit(0〜31)のみを使用する
    logic [4:0] shift_amount;
    assign shift_amount = imm_r[32] ? imm_r[4:0] : rs2_val_r[4:0];

    always_comb begin
        write_value = '0;

        unique case (command.m_type)
            // 演算系
            P_TYPE: begin
                unique case (func_r)
                    AND:  write_value = rs1_val_r & rs2_val_r;
                    OR:   write_value = rs1_val_r | rs2_val_r;
                    XOR:  write_value = rs1_val_r ^ rs2_val_r;
                    NOT:  write_value = ~rs1_val_r;
                    NAND: write_value = ~(rs1_val_r & rs2_val_r);
                    ADD:  write_value = rs1_val_r + rs2_val_r;
                    SUB:  write_value = rs1_val_r - rs2_val_r;
                    // 掛け算・割り算は結果の確定に複数サイクルかかるため，順序回路側で求める
                    MUL, DIV, DIVU: ;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // シフト系
            S_TYPE: begin
                unique case (func_r)
                    SLL: write_value = rs1_val_r << shift_amount;
                    SRL: write_value = rs1_val_r >> shift_amount;
                    SLA: write_value = rs1_val_r <<< shift_amount;
                    SRA: write_value = $signed(rs1_val_r) >>> shift_amount;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // 代入系．mask_rは未実装のため参照せず，常にrdの全バイトへ書き込む
            A_TYPE: begin
                unique case (func_r)
                    MOV: write_value = imm_r[32] ? imm_r[31:0] : rs1_val_r;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // 残りの命令タイプは，1サイクルで確定する書き込み値を持たない(応答を待つ命令の
            // 読み出し結果は，応答が返ったサイクルに順序回路側が直接書き込む)
            default: ;
        endcase
    end

    // 命令完了時に次の命令へ遷移する処理は，次の2つのタスクにまとめてある．CPU_EXECUTEフェーズで
    // 命令完了時に次命令へ遷移する箇所は，cpu_phase <= CPU_FETCH_REQUEST;やプログラムカウンタの更新を
    // 直接書かず必ずどちらかのタスクを呼ぶこと(先読み機構(prefetched_instruction/can_prefetch)と
    // 連動しており，直接代入すると先読み結果が反映されない)．どちらのタスクも，CPU_EXECUTEの
    // 先頭で同じサイクルに取り込んだ先読みを，prefetched_instruction_validへの0の代入で打ち消す．
    //
    // 分岐・ジャンプを行わず実行フェーズが3サイクル以上続く，先読みが成立し得る命令の完了時に呼ぶタスク．
    // 次の命令には，先読み済みの機械語(prefetched_instruction)のみを使う(ROMが同期読み出しのため，
    // 先読みが間に合っていない場合は今サイクルのrom_read.machineを信用できない)．
    // 先読みが完了しかつ実行可能だと分かればCHECKを省略してEXECUTEへ直接進み，先読み済みだが
    // 実行できないと分かった場合はCHECKへ進む(CHECKで停止させる)．先読み済みでない場合は
    // FETCH_REQUESTへ戻って改めて取得し直す．
    // これらの命令はいずれも分岐・ジャンプを行わないため，プログラムカウンタは順番どおりの
    // 次の番地(sequential_pc)へ更新する．分岐・ジャンプを行う命令をこのタスクから完了させては
    // ならない(飛び先が無視される)．
    //
    // 引数は，今回完了する命令がこのサイクルにレジスタへ書き込む内容(書き込み先アドレスと
    // 書き込む値の組)を表す．割り算だけは商と余りを同じサイクルに書き込むため，余りの組も
    // あわせて受け取る．割り算以外の命令は結果の組だけを有効にして呼び出し，レジスタへの
    // 書き込みを伴わない命令はどちらの組も無効にして呼び出す．
    task automatic advance_with_prefetch(
        input logic             result_write_valid,
        input machine_p::addr_t result_write_addr,
        input register_t        result_write_value,
        // ここから下の3つは割り算でのみ使用する
        input logic             remainder_write_valid,
        input machine_p::addr_t remainder_write_addr,
        input register_t        remainder_write_value
    );
        // 次の番地へ進む
        register[PC_ADDR] <= sequential_pc;

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
            // 次の命令が実行される時点の値(=このサイクルに書き込むsequential_pc)をそのまま渡す．
            rs1_val_r <= (command_next.rs1 == PC_ADDR) ? sequential_pc
                : (remainder_write_valid && remainder_write_addr == command_next.rs1) ? remainder_write_value
                : (result_write_valid    && result_write_addr    == command_next.rs1) ? result_write_value
                : register[command_next.rs1];
            rs2_val_r <= (command_next.rs2 == PC_ADDR) ? sequential_pc
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
        // 先読み済みでない．先読みが間に合っていない場合のほか，次の番地がROMへ渡せる幅に収まらない(コード領域を
        // 指すなど)場合もここに来る．後者はCPU_EXECUTEの先頭の先読みの取り込みで，先読み済みの印
        // (prefetched_instruction_valid)を立てずにおくためである．
        // プログラムカウンタは上で次の番地へ更新済みなので，FETCH_REQUESTへ戻って改めて取得し直す
        else begin
            cpu_phase <= CPU_FETCH_REQUEST;
        end

        // 先読み済みだった命令は消費し終えたので無効化する(同じサイクルに取り込んだ先読みも打ち消す)
        prefetched_instruction_valid <= 1'b0;
    endtask

    // 先読みが成立し得ない命令(分岐・ジャンプを行う命令と，実行フェーズが3サイクルに届かない命令)の
    // 完了時に呼ぶタスク．
    // プログラムカウンタを分岐・ジャンプを反映した番地(next_pc)へ更新し，FETCH_REQUESTから次の命令を
    // 取得し直す．
    // これらの命令では先読み済みの命令を使う遷移は起こり得ない．先読み・フォワーディングの判定を
    // 持たないタスクに分けることで，演算結果や分岐の比較結果が次の命令のオペランドレジスタ
    // (rs1_val_r/rs2_val_r)へ回り込む組み合わせ経路自体が作られなくなる
    // (この経路は1クロックに収まらずタイミング違反になる)．
    task automatic advance_by_refetch();
        // 分岐・ジャンプの結果を反映した番地へ進む
        register[PC_ADDR] <= next_pc;

        cpu_phase <= CPU_FETCH_REQUEST;

        // 先読み済みの命令を無効化する(同じサイクルに取り込んだ先読みも打ち消す)
        prefetched_instruction_valid <= 1'b0;
    endtask

    // メモリを読み書きする命令が，メモリへ要求を出す際に呼ぶタスク．番地はmem_addressを使い，
    // 読み書きしてよい範囲(mem_address_in_range)を外れる場合は，折り返した番地へアクセスせず要求を出さずに停止する
    // (停止した命令はメモリ・レジスタをいずれも書き換えない)
    task automatic request_ram_read(
        input machine_p::mask_t mask  // 読み込むバイトの指定
    );
        if (!mem_address_in_range) begin
            is_halted <= 1'b1;
        end
        else begin
            // 実行を指示
            ram_read_state   <= EXECUTE;
            // 実行状態であることを送る
            ram_read.valid   <= 1'b1;
            // マスク情報を送る
            ram_read.mask    <= mask;
            // アドレス情報を送る
            ram_read.address <= mem_address;
        end
    endtask
    task automatic request_ram_write(
        input machine_p::mask_t mask,  // 書き込むバイトの指定
        input register_t        data   // 書き込むデータ
    );
        if (!mem_address_in_range) begin
            is_halted <= 1'b1;
        end
        else begin
            // 実行を指示
            ram_write_state   <= EXECUTE;
            // 実行状態であることを送る
            ram_write.valid   <= 1'b1;
            // マスク情報を送る
            ram_write.mask    <= mask;
            // アドレス情報を送る
            ram_write.address <= mem_address;
            // データを送る
            ram_write.data    <= data;
        end
    endtask

    // 組み合わせ回路
    always_comb begin
        // 機械語を分解してもらう
        command.machine = current_instruction;

        // メモリのバースト転送はオミットする
        ram_read.last = 1'b1;
        ram_write.last = 1'b1;

        // LED・RGB LED
        led     = register[LED_ADDR][3:0];
        rgb_led = register[RGB_LED_ADDR][5:0];

        // Pmod A・Pmod B
        ja = register[PMOD_A_ADDR][7:0];
        jb = register[PMOD_B_ADDR][7:0];

        // Arduino．AR0〜AR7とAR8〜AR13はレジスタが分かれているため，ビット位置をAR番号にそのまま合わせている
        ar = {register[AR_HIGH_ADDR][5:0], register[AR_LOW_ADDR][7:0]};
        a       = register[AR_MISC_ADDR][2];
        ar_sda  = register[AR_MISC_ADDR][1];
        ar_scl  = register[AR_MISC_ADDR][0];

        // Arduino SPI．MISOは下のIO取り込みでレジスタへミラーする
        ck_mosi = register[SPI_ADDR][1];
        ck_sck  = register[SPI_ADDR][2];
        ck_ss   = register[SPI_ADDR][0];

        // ラズパイヘッダー．GPIOn(n=8〜26)はgpio[n]に対応する．GPIO0〜7はヘッダーへ出力しない
        gpio = {register[GPIO3_ADDR][2:0], register[GPIO2_ADDR][7:0], register[GPIO1_ADDR][7:0]};

        // ROMへ番地を出力する
        if (cpu_phase == CPU_FETCH_REQUEST || cpu_phase == CPU_FETCH_ROM_CAPTURE) begin
            // フェッチ中(1サイクル目・同期読み出しの結果を待つ間とも)は，これから実行する
            // 命令の番地を出し続ける(プログラムの1命令目のフェッチ，または先読みが間に合わ
            // なかった命令の取得し直し)
            rom_read.pc = register[PC_ADDR];
            // 切り詰め前のプログラムカウンタがpc_bus_tの幅に収まっているか
            pc_fits_in_width = util_p::is_within_bit_width(register[PC_ADDR], $bits(rom_p::pc_bus_t));
        end
        else if (can_prefetch) begin
            // 実行フェーズにあり，まだ次の命令を先読みしていない場合は，次に実行する命令を取得する．
            // 先読みが成立するのは分岐・ジャンプを行わない複数サイクル命令の実行中だけのため，
            // 飛び先を考慮したnext_pcではなく順番どおりの次の番地を出す(1サイクル命令の実行中も
            // 番地は出るが，その結果は取り込まれる前に捨てられる)
            rom_read.pc = sequential_pc;
            // 切り詰め前のsequential_pcがpc_bus_tの幅に収まっているか(収まらない場合は上位ビットが黙って捨てられる)
            pc_fits_in_width = util_p::is_within_bit_width(sequential_pc, $bits(rom_p::pc_bus_t));
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

    // 外部ピンからの非同期入力の同期化．準安定状態をシフトレジスタで消してからメインの順序回路で取り込む
    // メインの順序回路とブロックを分けているのは，リセット中・停止中も止めずに動かし続けるため
    // 準安定状態を消すだけでチャタリングは除去しない
    always_ff @(posedge clk) begin
        // タクトスイッチ
        btn_sync <= {btn_sync[0], btn};
        // DIPスイッチ
        sw_sync <= {sw_sync[0], sw};
        // Arduino SPIのMISO
        miso_sync <= {miso_sync[0], ck_miso};
    end

    // メインの順序回路
    always_ff @(posedge clk) begin
        // リセット
        if (!resetn || is_halted) begin
            // 実行状態をリセット
            cpu_phase <= CPU_FETCH_REQUEST;
            current_instruction <= nop();
            prefetched_instruction <= nop();
            prefetched_instruction_valid <= 1'b0;
            current_instruction_pc_valid <= 1'b1;
            fetching_upper_word <= 1'b0;
            prefetched_instruction_pc_valid <= 1'b1;
            can_prefetch_d1 <= 1'b0;
            rs1_val_r <= '0;
            rs2_val_r <= '0;
            rd_addr_r <= '0;
            func_r <= '0;
            imm_r <= '0;
            mask_r <= '0;

            // 掛け算回路用
            mul_state <= IDLE;
            mul_result_r <= '0;

            // 割り算回路用
            div_divisor_tdata <= '0;
            div_divisor_tvalid <= 1'b0;
            div_dividend_tdata <= '0;
            div_dividend_tvalid <= 1'b0;
            divu_divisor_tdata <= '0;
            divu_divisor_tvalid <= 1'b0;
            divu_dividend_tdata <= '0;
            divu_dividend_tvalid <= 1'b0;
            div_state <= IDLE;

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

            // レジスタ(標準入出力の信号線を写し取るものも含む．リセット中・停止中は写し取りを
            // 行わないため，初期化しないと停止した時点の値がそのまま残る)
            register <= REGISTER_INIT;

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
            // タクトスイッチ・DIPスイッチは同期化後の値で，ピンの値が届くまでこの1段と合わせて3サイクルかかる
            register[BTN_ADDR] <= {4'b0, btn_sync[1]};
            register[SW_ADDR] <= {6'b0, sw_sync[1]};
            register[STDIN_DATA_ADDR] <= stdin_tdata;
            register[STDIN_SIGNAL_ADDR][2] <= stdin_tlast;
            register[STDIN_SIGNAL_ADDR][1] <= stdin_tvalid;
            register[STDIN_SIGNAL_ADDR][0] <= stdin_tready;
            register[STDOUT_DATA_ADDR] <= stdout_tdata;
            register[STDOUT_SIGNAL_ADDR][2] <= stdout_tlast;
            register[STDOUT_SIGNAL_ADDR][1] <= stdout_tvalid;
            register[STDOUT_SIGNAL_ADDR][0] <= stdout_tready;
            // Arduino SPIのMISOビットのみ外部ピンを毎サイクル取り込む(SCK・MOSI・SSビットは
            // CPUの書き込みをそのまま保持し，このブロックでは触れない)
            // 取り込むのは同期化後の値で，ピンの値が届くまでこの1段と合わせて3サイクルかかる
            register[SPI_ADDR][3] <= miso_sync[1];

            // can_prefetchの1サイクル遅延版を更新する(ROMの同期読み出しは番地を出した次の
            // サイクルにならないと結果が確定しないため，先読みの取り込み可否判定に使う)
            can_prefetch_d1 <= can_prefetch;

            // CPUの実行サイクルごとに処理記載
            unique case (cpu_phase)
                // 命令の読み出しの要求(プログラムの1命令目，先読みが間に合わなかった命令，
                // 次の命令がコード領域にある場合の取得がここを通る)．プログラムカウンタに応じて読み出し元を選ぶ
                CPU_FETCH_REQUEST: begin
                    // コード領域を指していれば，メインメモリへ命令の下位ワードの読み出しを要求する
                    if (pc_in_code_area) begin
                        ram_read.valid   <= 1'b1;
                        ram_read.mask    <= 4'hf;
                        ram_read.address <= fetch_lower_address;
                        fetching_upper_word <= 1'b0;
                        cpu_phase <= CPU_FETCH_RAM_CAPTURE;
                    end
                    // それ以外はROMへ番地を出す(comb blockで実施済み)だけで，同期読み出しの結果はまだ確定して
                    // いないため次のサイクルまで待つ．ROMの幅に収まらない番地もここを通り，CHECKで停止する
                    else begin
                        cpu_phase <= CPU_FETCH_ROM_CAPTURE;
                    end
                end

                // ROMからの命令の取り込み．前サイクルに出した番地に対応するrom_read.machineが
                // 確定しているので取り込む
                CPU_FETCH_ROM_CAPTURE: begin
                    // 番地がROMの実容量の範囲内(rom_read.valid)であり，
                    // かつpc_bus_tの幅に収まっている(pc_fits_in_width)場合にのみ有効とする
                    current_instruction <= rom_read.machine;
                    current_instruction_pc_valid <= rom_read.valid && pc_fits_in_width;

                    // 次のサイクルへ
                    cpu_phase <= CPU_CHECK;
                end

                // メインメモリ(コード領域)からの命令の取り込み．下位ワード・上位ワードの順に読み出して取り込む．
                // メインメモリの読み出しを要求している間は停止しない(停止はCHECK・EXECUTEでのみ起こる)ことを前提に，
                // 停止時のメインメモリのリセットは行っていない(メインメモリはresetnでのみリセットされる)
                CPU_FETCH_RAM_CAPTURE: begin
                    // 読み出しが完了したら，読んだワードを命令の該当する位置へ取り込む
                    if (ram_read.ready) begin
                        // 下位ワード(イミディエイトデータ)を取り込み，続けて上位ワードを読む．validを下ろさずに番地だけを
                        // 変えると，メインメモリは完了を返した次のサイクルに待機へ戻った時点で新しい要求として受け付ける
                        // (一度下ろすと，上げ直すまでの1サイクルが余分にかかる)
                        if (!fetching_upper_word) begin
                            current_instruction[31:0] <= ram_read.data;
                            ram_read.address <= fetch_upper_address;
                            fetching_upper_word <= 1'b1;
                        end
                        // 上位ワード(命令語)を取り込んで命令が揃ったので，読み出しを終えて実行前確認へ進む
                        else begin
                            current_instruction[63:32] <= ram_read.data;
                            current_instruction_pc_valid <= 1'b1;
                            ram_read.valid <= 1'b0;
                            fetching_upper_word <= 1'b0;
                            cpu_phase <= CPU_CHECK;
                        end
                    end
                end

                // 実行前確認(プログラムの1命令目，先読みが間に合わずFETCH_REQUESTから取得し直した
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
                    // 次の命令を先読みしてよい状態(can_prefetch)であれば，次の命令をprefetched_instructionへ
                    // 先読みする．実際に先読みが残るのは，割り算の完了待ちやメモリ・標準入出力の応答待ちなど，
                    // 命令の実行が複数サイクルにまたがりまだ完了していないサイクルだけである．同じサイクルに
                    // 下で次命令への遷移タスクが呼ばれた場合は，タスク内のprefetched_instruction_valid <= 1'b0が
                    // 後から実行されてこの取り込みを打ち消す(ノンブロッキング代入は最後のものが有効になる)．
                    // このため，この取り込みはunique caseより前(CPU_EXECUTEの先頭)に置く必要がある．
                    // can_prefetch_d1も合わせて要求するのは，ROMの同期読み出しが番地を出した
                    // 次のサイクルにならないと確定しないため(can_prefetch単独では1サイクル
                    // 早すぎる値を掴んでしまう)．can_prefetchも同時に要求するのは，捕捉が
                    // 完了しprefetched_instruction_valid <= 1'b1が反映された直後の1サイクルは
                    // can_prefetch_d1がまだ1のまま残っており，その間に古い要求(番地'0)への
                    // 応答で誤って再取り込みしてしまうのを防ぐため．
                    // 次の番地がROMへ渡せる幅(pc_bus_t)に収まらない場合は，ROMではなくコード領域などを指しているため
                    // 取り込まず，命令の完了後にFETCH_REQUESTで取得し直す．この条件をcan_prefetch側に加えないのは，
                    // ROMの番地入力までの組み合わせ経路が伸びるため(取り込み側なら計算済みのpc_fits_in_widthを
                    // イネーブルに使うだけで済む)
                    if (can_prefetch && can_prefetch_d1 && pc_fits_in_width) begin
                        prefetched_instruction <= rom_read.machine;
                        prefetched_instruction_valid <= 1'b1;
                        // 取り込んだ命令は，番地がROMに格納された命令数の範囲内だった場合にのみ実行できるものとして扱う
                        prefetched_instruction_pc_valid <= rom_read.valid;
                    end

                    // 関数タイプごとに実行
                    unique case (command.m_type)
                        // 処理を実行しない(N系)
                        N_TYPE: begin
                            // 次の命令へ
                            advance_by_refetch();

                            // 不正な値が入っても全て無視する
                        end

                        // 演算系(P系)
                        P_TYPE: begin
                            unique case (func_r)
                                // 1サイクルで完了する演算は，組み合わせ回路で求めた結果を書き込んで次の命令へ
                                AND, OR, XOR, NOT, NAND, ADD, SUB: begin
                                    register[rd_addr_r] <= write_value;
                                    advance_by_refetch();
                                end

                                // 掛け算．結果が確定するまで1サイクル待ってから，書き込み・
                                // 次命令への遷移を行う
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
                                            mul_state <= IDLE;
                                            advance_by_refetch();
                                        end

                                        // その他
                                        default: is_halted <= 1'b1;
                                    endcase
                                end

                                // 割り算．DIVは符号あり，DIVUは符号なしの除算IPで計算する
                                DIV, DIVU: begin
                                    unique case (div_state)
                                        // 命令に対応する除算IPへ入力を送信
                                        IDLE: begin
                                            // 除数が0なら送信せず停止する
                                            if (rs2_val_r == '0) begin
                                                is_halted <= 1'b1;
                                            end
                                            // 符号あり除算
                                            else if (func_r == DIV) begin
                                                div_dividend_tdata   <= rs1_val_r;
                                                div_divisor_tdata    <= rs2_val_r;
                                                div_dividend_tvalid  <= 1'b1;
                                                div_divisor_tvalid   <= 1'b1;
                                                div_state <= EXECUTE;
                                            end
                                            // 符号なし除算
                                            else if (func_r == DIVU) begin
                                                divu_dividend_tdata  <= rs1_val_r;
                                                divu_divisor_tdata   <= rs2_val_r;
                                                divu_dividend_tvalid <= 1'b1;
                                                divu_divisor_tvalid  <= 1'b1;
                                                div_state <= EXECUTE;
                                            end
                                            // 割り算以外の命令はどちらの除算IPへも送信できないため停止する
                                            else begin
                                                is_halted <= 1'b1;
                                            end
                                        end

                                        // IPはtreadyなし（常にready）なので1サイクル待ってRESPONSEへ．
                                        // 送信しなかった側のIPのtvalidは元から0のため，どちらへ送ったかによらず両方を下ろす
                                        EXECUTE: begin
                                            div_dividend_tvalid  <= 1'b0;
                                            div_divisor_tvalid   <= 1'b0;
                                            divu_dividend_tvalid <= 1'b0;
                                            divu_divisor_tvalid  <= 1'b0;
                                            div_state <= RESPONSE;
                                        end

                                        // 計算結果が返ってくるまで待機
                                        RESPONSE: begin
                                            if (div_result_tvalid) begin
                                                // 商をrdへ格納
                                                register[rd_addr_r] <= div_result_tdata[63:32];
                                                // imm[32]=1なら余りをimm[5:0]のアドレスへ格納
                                                if (imm_r[32]) begin
                                                    register[imm_r[5:0]] <= div_result_tdata[31:0];
                                                end
                                                div_state <= IDLE;
                                                // 次の命令へ(商・余りの2箇所への書き込みを，代入する順に渡す)
                                                advance_with_prefetch(
                                                    1'b1, rd_addr_r, div_result_tdata[63:32],
                                                    imm_r[32], imm_r[5:0], div_result_tdata[31:0]
                                                );
                                            end
                                        end
                                        default: is_halted <= 1'b1;
                                    endcase
                                end
                                default: begin
                                    is_halted <= 1'b1;
                                end
                            endcase
                        end

                        // シフト系
                        S_TYPE: begin
                            unique case (func_r)
                                // 組み合わせ回路で求めたシフト結果を書き込んで次の命令へ
                                SLL, SRL, SLA, SRA: begin
                                    register[rd_addr_r] <= write_value;
                                    advance_by_refetch();
                                end
                                default: begin
                                    is_halted <= 1'b1;
                                end
                            endcase
                        end

                        // 代入系
                        A_TYPE: begin
                            // 命令がMOVの時だけ，書き込み・次命令への遷移を行う
                            if (func_r == MOV) begin
                                // 組み合わせ回路で求めた代入値(イミディエイトデータまたはrs1)を書き込む
                                register[rd_addr_r] <= write_value;
                                advance_by_refetch();
                            end
                            else begin
                                is_halted <= 1'b1;
                            end
                        end

                        // 分岐系
                        F_TYPE: begin
                            // 比較が成立していれば指定されたぶん離れた番地へ，していなければ次の番地へ移動する
                            unique case (func_r)
                                EQ, NE, LT, GT, ELT, EGT, LTU, GTU, ELTU, EGTU: begin
                                    // 比較結果を反映した番地の次の命令へ
                                    advance_by_refetch();
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
                                    // 指定された飛び先の命令へ
                                    advance_by_refetch();
                                end

                                // 関数呼び出し
                                CALL: begin
                                    unique case (ram_write_state)
                                        // 戻り先(呼び出しの次の番地)を，スタックポインタの1ワード下へ書き込む
                                        IDLE: request_ram_write(4'hf, sequential_pc);

                                        // 書き込みが完了したら，積んだ戻り先を指すようスタックポインタを下げて飛び先の命令へ
                                        EXECUTE: begin
                                            if (ram_write.ready) begin
                                                ram_write_state <= IDLE;
                                                ram_write.valid <= 1'b0;
                                                register[SP_ADDR] <= register[SP_ADDR] - 4;
                                                advance_by_refetch();
                                            end
                                        end

                                        // その他
                                        default: is_halted <= 1'b1;
                                    endcase
                                end

                                // 関数リターン
                                RET: begin
                                    unique case (ram_read_state)
                                        // スタックポインタが指す番地から戻り先を読み出す
                                        IDLE: request_ram_read(4'hf);

                                        // 読み出しが完了したら，下ろした戻り先の分スタックポインタを上げて戻り先の命令へ
                                        EXECUTE: begin
                                            if (ram_read.ready) begin
                                                ram_read_state <= IDLE;
                                                ram_read.valid <= 1'b0;
                                                register[SP_ADDR] <= register[SP_ADDR] + 4;
                                                advance_by_refetch();
                                            end
                                        end

                                        // その他
                                        default: is_halted <= 1'b1;
                                    endcase
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
                                // メモリ読み込み(RMは番地をそのまま，RMRはレジスタ相対で指定する)
                                RM, RMR: begin
                                    unique case (ram_read_state)
                                        // 待機
                                        IDLE: request_ram_read(mask_r);

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

                                                // 次の命令へ
                                                advance_with_prefetch(1'b1, rd_addr_r, ram_read.data, 1'b0, '0, '0);
                                            end
                                        end

                                        // その他
                                        default: begin
                                            is_halted <= 1'b1;
                                        end
                                    endcase
                                end

                                // メモリ書き込み(WMは番地をそのまま，WMRはレジスタ相対で指定する)
                                WM, WMR: begin
                                    unique case(ram_write_state)
                                        // 待機
                                        IDLE: request_ram_write(mask_r, rs2_val_r);

                                        // メモリ書き込み実行
                                        EXECUTE: begin
                                            // 書き込みが完了したなら
                                            if (ram_write.ready) begin
                                                // 待機状態に遷移
                                                ram_write_state <= IDLE;
                                                // 実行状態をオフ
                                                ram_write.valid <= 1'b0;

                                                // 次の命令へ(メモリへ書き込むだけでレジスタへは書き込まないためフォワーディングする値はない)
                                                advance_with_prefetch(1'b0, '0, '0, 1'b0, '0, '0);
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

                                                // 次の命令へ
                                                advance_with_prefetch(1'b1, rd_addr_r, stdin_tdata, 1'b0, '0, '0);
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

                                                // 次の命令へ(出力するだけでレジスタへは書き込まないためフォワーディングする値はない)
                                                advance_with_prefetch(1'b0, '0, '0, 1'b0, '0, '0);
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
                end

                // 定義されていない実行フェーズ(フェーズを表すビット幅のうち使っていない値)．動作を保証できないため停止させる
                default: begin
                    is_halted <= 1'b1;
                end
            endcase
        end
    end
endmodule
