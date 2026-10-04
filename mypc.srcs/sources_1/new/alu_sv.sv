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

// 命令パイプライン処理の概要．命令は次の4段を1サイクルずつ進み，各段は別々の命令を同時に処理する．
// 分岐・ジャンプや複数サイクルかかる命令がなければ，毎サイクル1命令ずつ実行が終わる．
// - 取得段: 取得用のプログラムカウンタ(fetch_pc)が指す命令を，ROMかメインメモリの後半から読み出す．
//   ROMからは，番地入力へ読み出す命令の番地を与えると(以下，ROMへ番地を出すと書く)，次のサイクルに命令が確定する
//   (クロックに同期した読み出しのため)．メインメモリの後半からは，パイプラインが空になってから1命令ずつ読み出す
//   (理由はこの概要の最後の段落)
// - 取り込み段: 取得した命令を命令キューの末尾へ取り込む
// - 確認段: 命令キューの先頭の命令が実行できるかを確認し，レジスタから値を読み出して実行段へ渡す
// - 実行段: 命令を実行する．メモリ・標準入出力の応答待ちや割り算の完了待ちなど，複数サイクルかかる命令の
//   実行中は，確認段の命令を待たせる
//
// 実行可否の確認は，命令のデコード時点で分かる情報(命令種別・func・レジスタ番地など)は確認段
// でalu.svh::is_instruction_executable()により一括判定する．レジスタの値そのものに基づく
// 判定は値が確定するまで行えないため，値が確定する実行段で個別に判定する．
//
// 前の命令の結果を使う命令は，結果がレジスタへ書き込まれるのを待たずに受け取る(フォワーディング)．
// 1サイクルで終わる命令の結果は保持しておき，次の命令が実行段の入口で読み出した値と差し替える．
// 確認段で差し替えないのは，演算結果から確認段の比較・選択を経て実行段の入力に至る経路が1クロックに収まらないため．
// 複数サイクルかかる命令の結果は，メモリ・標準入力・除算IPの出力や掛け算の結果のレジスタから出る値で経路が短いため，確認段で差し替える．
//
// 分岐が成立した場合とジャンプ系の命令の完了時は，それより後に取得していた命令をすべて捨て，飛び先から取得し直す．
// 分岐が成立しなかった場合は，順番どおりに取得していた命令をそのまま実行する．
//
// 命令はプログラムカウンタに応じてROMかメインメモリの後半から読み出す．メインメモリは，読み出しポートを実行段と
// 共用し，応答を待つ必要があり，読み出しも1回32ビットである．このため，メモリの後半の命令はパイプラインが
// 空になってから，64ビットの命令をイミディエイトデータ・命令語の順に2回に分けて読み，1命令ずつ実行する．
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
        // 何も積んでいない初期状態では，前半の末尾のすぐ上の番地(メモリの後半の先頭番地)にしておく
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

    // 実行できない命令を検出して停止していることを表すフラグ．立っている間は下のリセット
    // ブロックの中身を毎サイクル実行し続けて停止状態を保ち，外部からのリセット(resetn)が
    // 入るまで下りない．
    // このフラグを下ろす代入は，下のリセット処理の中(if (!resetn)の中)以外に置かないこと
    // (停止状態から自力で抜けると，外部からのリセットを経ずに同じ命令を再実行する動作になる)．
    logic is_halted = 1'b0;

    // ===== 取得段: ROMからの命令の取得 =====

    // 順番どおりに取得していく場合に，次にROMへ出す番地．
    // プログラムカウンタはROMの外(メモリの後半など)も指すため，ROMへ渡せる幅(pc_bus_t)ではなく，
    // 命令から読み出せるプログラムカウンタと同じ32ビットのregister_tで持つ(以下の番地も同様)
    register_t fetch_next_pc = '0;
    // 前のサイクルに実行段が分岐・ジャンプで後の命令を捨てたか．捨てた次のサイクルに飛び先から取得し直す
    logic redirect_pending = 1'b0;
    // 前のサイクルに実行段が求めた飛び先．redirect_pendingが1のときだけ意味を持つ
    register_t redirect_pc = '0;

    // このサイクルにROMへ出す番地(次に取得する命令のプログラムカウンタ)．取得し直すサイクルは控えた飛び先，それ以外は順番どおりの番地を選ぶ．
    // 飛び先をfetch_next_pcへ直接入れないのは，ROMを作る多数のブロックRAMへ番地を配るためにfetch_next_pcが合成で
    // 多数複製され，分岐の比較結果から全ての複製までの経路が1クロックに収まらないため
    // (控えたレジスタから選ぶため，飛び先をROMへ出すサイクルは直接入れる場合と変わらない)
    register_t fetch_pc;
    assign fetch_pc = redirect_pending ? redirect_pc : fetch_next_pc;
    // このサイクルにROMから命令が届いたか(前のサイクルにROMへ番地を出したか)
    logic rom_arrived = 1'b0;
    // ROMから届いた命令の番地(前のサイクルにROMへ出した番地)
    register_t rom_arrived_pc = '0;

    // fetch_pcが，ROMへ渡せる幅(pc_bus_t)に収まっているか．収まらない番地(メモリの後半など)はROMへ出さない
    util_p::bool_t fetch_pc_fits;
    assign fetch_pc_fits = util_p::is_within_bit_width(fetch_pc, $bits(rom_p::pc_bus_t));

    // ===== 命令キュー(取り込み段から確認段への受け渡し) =====
    // ROMは番地を出した次のサイクルに，その番地の命令を出力する．出力を止める手段がないため，
    // 確認段が命令を待たせている間にROMから出力された命令を，失わないよう溜めておく．
    // 添字が小さいほど先に取得した命令(プログラム上で先に実行する命令)が入る．実行段の命令は含まず，
    // 先頭(添字0)が常に確認段の命令(次に実行段へ渡す命令)になるよう，先頭を取り除くたびに残りを1つずつ前へ詰める．
    // 先頭の位置が変わるリングバッファにしないのは，先頭を選ぶ回路が確認段の手前に入り，経路が伸びるため

    // 命令キューに置ける命令数．ROMへ番地を出すかを前のサイクルまでのレジスタだけで決めながら，
    // 毎サイクル1命令ずつ流すには，確認段の1命令・読み出し中の1命令に加えて，もう1命令ぶんの空きが要る
    localparam int QUEUE_DEPTH = 3;

    // 命令キューの機械語
    machine_p::machine_t queue_instruction[QUEUE_DEPTH] = '{default: nop()};
    // 命令キューの命令のプログラムカウンタ
    register_t queue_pc[QUEUE_DEPTH] = '{default: '0};
    // 命令キューの命令を，命令を置ける番地(ROMの実容量範囲内またはメモリの後半)から取得できたか
    logic queue_pc_valid[QUEUE_DEPTH] = '{default: 1'b1};
    // 命令キューに入っている命令数(0〜QUEUE_DEPTH)
    logic [$clog2(QUEUE_DEPTH + 1)-1:0] queue_count = '0;

    // このサイクルにROMへ番地を出すか．前のサイクルまでのレジスタだけで決め，実行段の完了待ちなどの判定を
    // 含めない(ROMの番地を出すまでの経路を伸ばさないため)
    logic fetch_request;
    assign fetch_request =
        // 取得用のプログラムカウンタがROMへ渡せる幅に収まっている
        fetch_pc_fits
        // かつ，次のサイクルに届く命令を取り込む場所が命令キューに残る(入っている命令と，このサイクルに届いた命令を除いても空きがある)
        && (queue_count + rom_arrived < QUEUE_DEPTH);

    // ===== 確認段 =====

    // 確認段(命令キューの先頭)の命令をデコードする．命令キューが空の間のデコード結果は意味を持たない
    command_if command_next();
    assign command_next.machine = queue_instruction[0];
    decoder_sv decoder_sv_next(
        .command(command_next)
    );

    // 確認段に命令があるか
    logic check_occupied;
    assign check_occupied = (queue_count != 0);

    // 確認段の命令が実行できるか
    util_p::bool_t check_executable;
    assign check_executable = is_instruction_executable(
        queue_pc_valid[0], command_next.m_type, command_next.func,
        command_next.rs1, command_next.rs2, command_next.rd, command_next.imm
    );

    // ===== 取得段: メモリの後半からの命令の取得 =====

    // メインメモリから命令を読み出している最中か
    logic fetching_from_ram = 1'b0;
    // メインメモリから読み出し中のワードが命令の上位32ビット(命令語)か．0なら下位32ビット(イミディエイトデータ)
    logic fetching_upper_word = 1'b0;

    // ===== 実行段 =====
    // 確認段から命令を受け取るときに設定し，実行中はこれらの値を参照して命令を実行する

    // 実行段に命令が入っているか．入っていない間も，実行段の各レジスタ(機械語や読み出し値など)はNOPなどへ
    // 書き換えず，最後に実行した命令の値を保持したままにする．実行段の値から求める組み合わせ回路の結果は，
    // このフラグが1の間だけ使い，0の間は求められた値を使わない
    logic ex_occupied = 1'b0;
    // 実行段の命令の番地．分岐の飛び先とCALLの戻り先を求めるのに使う
    register_t ex_pc = '0;
    // 実行段の命令の機械語．ex_occupiedが0の間は前回実行した命令の値が残ったままで，意味を持たない
    machine_p::machine_t current_instruction = nop();

    register_t rs1_val_r = '0;        // 第1オペランドの読み出し値
    register_t rs2_val_r = '0;        // 第2オペランドの読み出し値
    machine_p::addr_t rd_addr_r = '0; // 書き込み先レジスタの番地
    machine_p::func_t func_r = '0;    // 命令の細分類(演算子・比較方法など)
    machine_p::imm_t imm_r = '0;      // イミディエイトデータ(使用可否のフラグを含む)
    machine_p::mask_t mask_r = '0;    // 書き込みバイトマスク

    // 直前に完了した1サイクル命令が書き込んだ値．次の命令がこの値を受け取る(フォワーディング)ために保持する．
    // 受け取った命令が実行段にある間は書き換えない(その間に完了する1サイクル命令はないため，自然に守られる)
    register_t alu_result_r = '0;
    // 実行段の命令が，第1・第2オペランドとしてrs1_val_r・rs2_val_rの代わりにalu_result_rを使うか
    logic rs1_forward_r = 1'b0;
    logic rs2_forward_r = 1'b0;

    // 実行段の命令が使う第1・第2オペランドの値．実行段ではrs1_val_r・rs2_val_rを直接参照せず，必ずこちらを使う
    register_t rs1_val;
    register_t rs2_val;
    assign rs1_val = rs1_forward_r ? alu_result_r : rs1_val_r;
    assign rs2_val = rs2_forward_r ? alu_result_r : rs2_val_r;

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

    // ===== 取得段: メモリの後半からの命令の取得(組み合わせ回路) =====
    // プログラムカウンタのうち，メモリの後半の先頭の命令のプログラムカウンタ(CODE_AREA_PC_BASE)から，メモリの後半に置ける
    // 命令数(CODE_AREA_PC_NUM)ぶんの範囲がメモリの後半に対応する．命令数は2のべき乗で，先頭のプログラムカウンタは
    // 命令数の倍数とするため，この範囲のプログラムカウンタは次の2つに分けられる
    // - 下位ビット: その命令がメモリの後半の先頭から何番目か(0〜命令数-1)
    // - 上位ビット: 範囲内のどの命令でも同じ値(先頭のプログラムカウンタの上位ビット)

    // プログラムカウンタのうち，メモリの後半の先頭から何番目の命令かを表す下位ビットの幅
    localparam int CODE_AREA_PC_WIDTH = $clog2(rom_p::CODE_AREA_PC_NUM);
    // メモリの後半を指すプログラムカウンタに共通する上位ビットの値
    localparam logic [31-CODE_AREA_PC_WIDTH:0] CODE_AREA_PC_UPPER = rom_p::CODE_AREA_PC_BASE >> CODE_AREA_PC_WIDTH;

    // メモリの後半についての判定は，次の前提の上に成り立つ
    // ROMの命令数の上限を変えるなどして前提が崩れた場合は，誤った判定のまま合成されないよう，組み立て時にエラーにする
    // 前提1: 先頭のプログラムカウンタが命令数の倍数である
    // 倍数でなければ，プログラムカウンタを上に書いた下位ビットと上位ビットに分けられない
    if (rom_p::CODE_AREA_PC_BASE % rom_p::CODE_AREA_PC_NUM != 0)
        $error("メモリの後半の先頭のプログラムカウンタがメモリの後半に置ける命令数の倍数になっていません");
    // 前提2: 先頭のプログラムカウンタが，ROMへ渡せる幅(pc_bus_t)で表せる範囲のちょうど直後である
    // ROMへ出せない番地(fetch_pc_fitsが偽)になったことを，ROMの外へ出たことの判定に使うため
    if (rom_p::CODE_AREA_PC_BASE != 2 ** $bits(rom_p::pc_bus_t))
        $error("メモリの後半の先頭のプログラムカウンタが，ROMへ渡せる幅で表せる範囲の直後になっていません");

    // 取得用のプログラムカウンタがメモリの後半を指しているか．上位ビットがメモリの後半に共通する値と一致するかで判定する
    // (一致比較1つで範囲の下端・上端の両方を判定できる．大小比較で書くと下端・上端の2つが要る)
    logic pc_in_code_area;
    assign pc_in_code_area = (fetch_pc[31:CODE_AREA_PC_WIDTH] == CODE_AREA_PC_UPPER);

    // 取得用のプログラムカウンタが指す命令の，下位ワード(イミディエイトデータ)・上位ワード(命令語)のメインメモリ上の番地
    ram_p::address_bus_t fetch_lower_address;
    ram_p::address_bus_t fetch_upper_address;
    // 下位ワードの番地は，メモリの後半の先頭番地 + 先頭から何番目の命令か × 8(1命令のバイト数)
    // メモリの後半の先頭番地は，最上位ビットだけが立っている
    // 何番目か × 8はそれより下のビットに収まるため，立っているビットが重ならず，加算とORの結果が同じになる
    // このため，加算器を使わずORで組み立てる
    assign fetch_lower_address = ram_p::address_bus_t'(CODE_AREA_BASE)                                // 最上位ビット: メモリの後半の先頭番地
                               | (ram_p::address_bus_t'(fetch_pc[CODE_AREA_PC_WIDTH-1:0]) << 3);      // その下のビット: 何番目の命令か × 8(下位3ビットは0)
    // 上位ワードの番地は下位ワードの4バイト後．下位ワードの番地は8の倍数(下位3ビットが0)のため，4を表すビットを立てるだけでよい
    assign fetch_upper_address = fetch_lower_address | ram_p::address_bus_t'(4);

    // メインメモリから読み出した命令の下位ワード(イミディエイトデータ)．上位ワードが届くまで控えておく
    register_t ram_fetch_lower_r = '0;

    // 取得用のプログラムカウンタがROMへ渡せる幅を外れ，パイプラインが空になったか
    logic pipeline_drained;
    assign pipeline_drained =
        // 取得用のプログラムカウンタがROMへ渡せる幅を外れている(ROMへ番地を出せない)
        !fetch_pc_fits
        // ROMから結果を待っている命令がない
        && !rom_arrived
        // 命令キュー(確認段を含む)に命令がない
        && queue_count == 0
        // 実行段に命令がない
        && !ex_occupied
        // メインメモリから命令を読み出している最中でない
        && !fetching_from_ram;

    // このサイクルにメインメモリから命令が届いたか(上位ワードが届き，命令が揃ったか)
    logic ram_arrived;
    assign ram_arrived = fetching_from_ram && ram_read.ready && fetching_upper_word;

    // ===== 取り込み段: 命令キューへ取り込む命令(組み合わせ回路) =====
    // ROMとメインメモリのどちらかから届いた命令を取り込む(同じサイクルに両方から届くことはない)

    // このサイクルに命令キューへ命令を取り込むか
    logic queue_push;
    assign queue_push = rom_arrived || ram_arrived;
    // 取り込む命令の機械語・プログラムカウンタ・命令を置ける番地から取得できたか
    machine_p::machine_t push_instruction;
    register_t           push_pc;
    logic                push_pc_valid;
    // 機械語は，ROMから届いた命令ではROMの出力，メインメモリから届いた命令では届いた上位ワードと控えておいた下位ワード
    assign push_instruction = rom_arrived ? rom_read.machine : {ram_read.data, ram_fetch_lower_r};
    // プログラムカウンタは，ROMから届いた命令では番地を出したときに控えた番地，メインメモリから届いた命令では取得用のプログラムカウンタ
    assign push_pc          = rom_arrived ? rom_arrived_pc : fetch_pc;
    // 取得できたかは，ROMから届いた命令では，ROMが命令とともに返すrom_read.valid(番地がROMに格納された命令数の範囲内か)を使う．
    // 番地がROMへ渡せる幅に収まるかは，収まる番地しかROMへ出さない(fetch_request)ため確かめなくてよい．
    // メインメモリから届いた命令は，メモリの後半を指す番地でしか取得しないため，常に取得できたものとする．
    // ROMへ渡せる幅にもメモリの後半にも収まらない番地は，どちらからも取得せず命令が届かないため，ここでは扱わない．
    // その番地へ進んだ場合は，パイプラインが空になった時点で停止させる(pipeline_drainedを使う取得段の処理)
    assign push_pc_valid    = rom_arrived ? rom_read.valid   : 1'b1;

    // ===== 分岐・ジャンプ先・次番地の算出(組み合わせ回路) =====
    // 実行段に命令がある間(ex_occupiedが1の間)のみ意味を持つ(それ以外では直前に実行した命令の値が残っている)

    // 分岐命令の比較に使う，rs1とrs2の一致・大小関係．符号あり・符号なしのすべての比較方法で共有する
    logic rs_equal;            // rs1とrs2が一致するか
    logic rs_less_unsigned;    // 符号なし整数としてrs1がrs2より小さいか
    logic rs_less_signed;      // 符号あり整数としてrs1がrs2より小さいか
    assign rs_equal         = (rs1_val == rs2_val);
    assign rs_less_unsigned = (rs1_val <  rs2_val);
    // 符号ビットが異なれば負である側が小さく，同じなら符号なし整数としての大小と一致する．
    // $signedで別に比較しないのは，符号あり・符号なしで32ビットの大小比較器を2つ持つことになり回路規模が増えるため
    assign rs_less_signed   = (rs1_val[31] != rs2_val[31]) ? rs1_val[31] : rs_less_unsigned;

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
                       : rs1_val;

    // メモリ系の命令と，戻り先を積み下ろすCALL・RETがアクセスする番地(アドレスバス幅へ切り詰める前の値)．
    // funcの値は命令タイプごとに割り当てられ，異なる命令タイプで同じ値が現れるため，命令タイプとあわせて判定する
    register_t mem_address;
    assign mem_address = (command.m_type == J_TYPE && func_r == CALL)                   ? register[SP_ADDR] - 4     // 戻り先を積むスタックポインタの1ワード下
                       : (command.m_type == J_TYPE && func_r == RET)                    ? register[SP_ADDR]         // 戻り先を下ろすスタックポインタが指す番地
                       : (command.m_type == M_TYPE && (func_r == RMR || func_r == WMR)) ? rs1_val + imm_r[31:0]     // rs1にイミディエイトデータを足した番地(32ビットで折り返す)
                       : imm_r[32]                                                      ? imm_r[31:0]               // イミディエイトデータで指定された番地
                       : rs1_val;                                                                                   // rs1で指定された番地

    // mem_addressが読み書きしてよい範囲に収まっているか
    // J系の命令のうちメモリを読み書きするのはCALL・RETだけで，読み書きするのは戻り先を積み下ろしするスタックである
    // スタックはメモリの前半に置くため，J系では前半に収まる番地だけを範囲内とする
    // 空のスタックでのRETを停止させ，CALLがメモリの後半を書き換えないようにするためである
    // それ以外の命令はメモリ全体を読み書きできる
    // 前半の大きさ(メモリの後半の先頭番地)は2のべき乗のため，前半に収まるかはビット幅で判定できる
    util_p::bool_t mem_address_in_range;
    assign mem_address_in_range = (command.m_type == J_TYPE)
        ? util_p::is_within_bit_width(mem_address, $clog2(CODE_AREA_BASE))
        : util_p::is_within_bit_width(mem_address, $bits(ram_p::address_bus_t));

    // 分岐・ジャンプを行わない命令の次の番地(現在の番地の直後)．オペランドの値に依存せず
    // プログラムカウンタだけから求まる
    register_t sequential_pc;
    assign sequential_pc = ex_pc + 1;

    // 実行段の命令の次に実行する命令の番地．参照してよいのは実行段に命令がある間だけ．
    // それ以外では，命令タイプと，比較と飛び先の指定に使う値が直前に実行した命令のものが残っているだけで，結果に意味がない．
    register_t next_pc;
    assign next_pc = is_branch_taken ? ex_pc + imm_r[31:0]              // 比較結果がtrueの分岐は指定されたぶん離れた番地へ
                   : is_jumping      ? jump_target                      // 移動する命令は指定された飛び先へ
                   : sequential_pc;                                     // それ以外は次の番地へ進む

    // ===== 1サイクルで完了する命令の結果の算出(組み合わせ回路) =====
    // 実行段に命令がある間(ex_occupiedが1の間)のみ意味を持つ．ここでは結果を求めるだけで，レジスタへ書き込むかどうかと，
    // 不正な命令での停止(is_halted)はメインの順序回路が判定する(is_haltedは順序回路が駆動する
    // レジスタであり，ここから停止させることはできない)

    // 1サイクルでレジスタへの書き込みまで完了する命令の結果．それ以外の命令では0になり使われない
    register_t write_value;

    // シフト系のシフト量．イミディエイトデータまたはrs2の下位5bit(0〜31)のみを使用する
    logic [4:0] shift_amount;
    assign shift_amount = imm_r[32] ? imm_r[4:0] : rs2_val[4:0];

    always_comb begin
        write_value = '0;

        unique case (command.m_type)
            // 演算系
            P_TYPE: begin
                unique case (func_r)
                    AND:  write_value = rs1_val & rs2_val;
                    OR:   write_value = rs1_val | rs2_val;
                    XOR:  write_value = rs1_val ^ rs2_val;
                    NOT:  write_value = ~rs1_val;
                    NAND: write_value = ~(rs1_val & rs2_val);
                    ADD:  write_value = rs1_val + rs2_val;
                    SUB:  write_value = rs1_val - rs2_val;
                    // 掛け算・割り算は結果の確定に複数サイクルかかるため，順序回路側で求める
                    MUL, DIV, DIVU: ;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // シフト系
            S_TYPE: begin
                unique case (func_r)
                    SLL: write_value = rs1_val << shift_amount;
                    SRL: write_value = rs1_val >> shift_amount;
                    SLA: write_value = rs1_val <<< shift_amount;
                    SRA: write_value = $signed(rs1_val) >>> shift_amount;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // 代入系．mask_rは未実装のため参照せず，常にrdの全バイトへ書き込む
            A_TYPE: begin
                unique case (func_r)
                    MOV: write_value = imm_r[32] ? imm_r[31:0] : rs1_val;
                    // 不正なfunc．順序回路側が停止させる
                    default: ;
                endcase
            end

            // 残りの命令タイプは，1サイクルで確定する書き込み値を持たない(応答を待つ命令の
            // 読み出し結果は，下の実行段の完了判定で求める)
            default: ;
        endcase
    end

    // ===== 実行段の完了判定(組み合わせ回路) =====
    // 実行段の命令がこのサイクルに完了するかと，完了するときにレジスタへ書き込む内容を求める．
    // 応答を待つ命令は，下の順序回路が要求を出し，ここでは応答が返ったかどうかだけを見る

    // 実行段の命令がこのサイクルに完了するか
    logic ex_completes;
    // 完了する命令が，1サイクルで求めた結果(write_value)をrd_addr_rへ書き込むか
    logic ex_alu_write;
    // 完了する命令が，複数サイクルかけて得た結果を書き込むか．書き込み先と値の組
    logic             late_write_valid;
    machine_p::addr_t late_write_addr;
    register_t        late_write_value;
    // 割り算が余りを書き込むか．書き込み先と値の組
    logic             remainder_write_valid;
    machine_p::addr_t remainder_write_addr;
    register_t        remainder_write_value;

    always_comb begin
        // 既定値として「完了せず何も書き込まない」を全ての出力に与え，下の場合分けで該当する命令だけが上書きする
        // (場合分けで代入しない経路があると，前の値を保持するラッチが作られるため)
        ex_completes          = 1'b0;
        ex_alu_write          = 1'b0;
        late_write_valid      = 1'b0;
        late_write_addr       = rd_addr_r;               // 書き込む命令が共通して使う書き込み先を既定値にし，場合分けでの代入を減らす
        late_write_value      = '0;
        remainder_write_valid = 1'b0;
        remainder_write_addr  = imm_r[5:0];              // 余りを書き込む唯一の命令である割り算が使う書き込み先
        remainder_write_value = div_result_tdata[31:0];  // 同じく割り算が使う，除算IPが返す余り

        // 定義されていないfuncの命令は確認段で停止させるため，ここではどの命令タイプでも定義済みのfuncだけを扱う
        if (ex_occupied) begin
            unique case (command.m_type)
                // 処理を実行しない
                N_TYPE: ex_completes = 1'b1;

                // 演算系
                P_TYPE: begin
                    unique case (func_r)
                        // 1サイクルで完了する演算は，求めた結果を書き込む
                        AND, OR, XOR, NOT, NAND, ADD, SUB: begin
                            ex_completes = 1'b1;
                            ex_alu_write = 1'b1;
                        end
                        // 掛け算は，結果が確定したら書き込む
                        MUL: begin
                            ex_completes     = (mul_state == RESPONSE);
                            late_write_valid = (mul_state == RESPONSE);
                            late_write_value = mul_result_r;
                        end
                        // 割り算は，除算IPから結果が届いたら商を書き込み，imm[32]=1なら余りもimm[5:0]の番地へ書き込む
                        DIV, DIVU: begin
                            ex_completes          = (div_state == RESPONSE) && div_result_tvalid;
                            late_write_valid      = (div_state == RESPONSE) && div_result_tvalid;
                            late_write_value      = div_result_tdata[63:32];
                            remainder_write_valid = (div_state == RESPONSE) && div_result_tvalid && imm_r[32];
                        end
                        default: ;
                    endcase
                end

                // シフト系・代入系は，求めた結果を書き込む
                S_TYPE, A_TYPE: begin
                    ex_completes = 1'b1;
                    ex_alu_write = 1'b1;
                end

                // 分岐系は，比較結果を反映した番地へ進む
                F_TYPE: ex_completes = 1'b1;

                // ジャンプ系
                J_TYPE: begin
                    unique case (func_r)
                        // ジャンプは，指定された飛び先へ進む
                        JMP:  ex_completes = 1'b1;
                        // 関数呼び出しは，戻り先をスタックへ書き込み終えたら飛び先へ進む
                        CALL: ex_completes = (ram_write_state == EXECUTE) && ram_write.ready;
                        // 関数リターンは，戻り先をスタックから読み出し終えたら戻り先へ進む
                        RET:  ex_completes = (ram_read_state == EXECUTE) && ram_read.ready;
                        default: ;
                    endcase
                end

                // メモリ系
                M_TYPE: begin
                    unique case (func_r)
                        // メモリ読み込みは，読み出しが完了したら読んだ値を書き込む
                        RM, RMR: begin
                            ex_completes     = (ram_read_state == EXECUTE) && ram_read.ready;
                            late_write_valid = (ram_read_state == EXECUTE) && ram_read.ready;
                            late_write_value = ram_read.data;
                        end
                        // メモリ書き込みは，書き込みが完了したら次の命令へ進む
                        WM, WMR: ex_completes = (ram_write_state == EXECUTE) && ram_write.ready;
                        default: ;
                    endcase
                end

                // 標準入出力系
                IO_TYPE: begin
                    unique case (func_r)
                        // 標準入力は，値が届いたら受け取った値を書き込む
                        SCAN: begin
                            ex_completes     = (stdin_state == EXECUTE) && stdin_tvalid;
                            late_write_valid = (stdin_state == EXECUTE) && stdin_tvalid;
                            late_write_value = stdin_tdata;
                        end
                        // 標準出力は，値が受け取られたら次の命令へ進む
                        PRINT: ex_completes = (stdout_state == EXECUTE) && stdout_tready;
                        default: ;
                    endcase
                end

                default: ;
            endcase
        end
    end

    // 実行段の命令の完了時に，それより後に取得していた命令を捨てて飛び先から取得し直すか
    logic ex_redirects;
    assign ex_redirects =
        // 実行段の命令がこのサイクルに完了する(CALL・RETは完了するまで飛び先が確定しないため)
        ex_completes
        // かつ，分岐が成立したか，ジャンプ系の命令である．ジャンプ系は飛び先が次の番地でも捨てる(一致を確かめる比較を
        // 経路に加えないため)．常に捨てるため，CALL・RETが書き換えるスタックポインタを確認段へ回す必要もない
        && (is_branch_taken || is_jumping);

    // ===== 確認段から実行段への受け渡し(組み合わせ回路) =====

    // 実行段がこのサイクルにAR_SPIへ書き込み，確認段の命令がAR_SPIを読み出すか．
    // AR_SPIへ書き込む命令はレジスタ全体(32ビット)の値を書き込むが，そのうちMISOビットはピンの値を写す
    // 読み出し専用のビットで，書き込んだ値では変わらない．書き込む32ビットの値をそのまま確認段の命令へ回すと，
    // MISOビットだけが書き込んだ値になって誤る．このため回さずに，書き込みを終えたレジスタを読めるまで確認段の命令を1サイクル待たせる
    logic spi_hazard;
    assign spi_hazard =
        // 確認段の命令が，第1・第2オペランドのどちらかでAR_SPIを読み出す
        (command_next.rs1 == SPI_ADDR || command_next.rs2 == SPI_ADDR)
        // かつ，実行段がこのサイクルに次のいずれかの書き込みでAR_SPIへ書き込む
        && (
            // 1サイクルで完了する命令の結果
            (ex_alu_write          && rd_addr_r            == SPI_ADDR)
            // 複数サイクルかけて得た結果
         || (late_write_valid      && late_write_addr      == SPI_ADDR)
            // 割り算の余り
         || (remainder_write_valid && remainder_write_addr == SPI_ADDR)
        );

    // 確認段の命令をこのサイクルに実行段へ渡すか
    logic dispatch;
    assign dispatch =
        // 確認段に命令が入っている
        check_occupied
        // かつ，実行段が空いているか，このサイクルに空く．実行段の命令が分岐・ジャンプで後の命令を捨てる場合も渡して
        // から捨てる(捨てるかを条件に含めると，分岐の比較結果から多数のレジスタの取り込み可否までの経路ができるため)
        && (!ex_occupied || ex_completes)
        // かつ，AR_SPIへの書き込みが終わるのを待つ必要がない
        && !spi_hazard;

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

        // ROMへ取得用のプログラムカウンタを出す．番地を出さないサイクル(fetch_requestが偽)の結果は取り込まない．
        // ROMへ渡せる幅に収まらない上位ビットは捨てられるが，その場合はfetch_requestが偽になる
        rom_read.pc = rom_p::pc_bus_t'(fetch_pc);

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
            // 取得段・命令キュー・実行段をリセット
            fetch_next_pc <= '0;
            redirect_pending <= 1'b0;
            redirect_pc <= '0;
            rom_arrived <= 1'b0;
            rom_arrived_pc <= '0;
            queue_instruction <= '{default: nop()};
            queue_pc <= '{default: '0};
            queue_pc_valid <= '{default: 1'b1};
            queue_count <= '0;
            fetching_from_ram <= 1'b0;
            fetching_upper_word <= 1'b0;
            ram_fetch_lower_r <= '0;
            ex_occupied <= 1'b0;
            ex_pc <= '0;
            current_instruction <= nop();
            rs1_val_r <= '0;
            rs2_val_r <= '0;
            rd_addr_r <= '0;
            func_r <= '0;
            imm_r <= '0;
            mask_r <= '0;
            alu_result_r <= '0;
            rs1_forward_r <= 1'b0;
            rs2_forward_r <= 1'b0;

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

            // レジスタ
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
            // ===== 取得段: ROMからの命令の取得 =====

            // ROMへ番地を出したら，次のサイクルに届く命令を命令キューへ取り込めるよう番地を控える．
            // 分岐・ジャンプで取得し直す場合は，出した番地の結果を捨てるため控えない
            rom_arrived <= fetch_request && !ex_redirects;
            if (fetch_request) begin
                rom_arrived_pc <= fetch_pc;
            end
            // 順番どおりに取得する番地を，ROMへ番地を出したかメインメモリから命令を取り込み終えた場合は，このサイクルに
            // 取得した番地(取得し直すサイクルなら飛び先)の次へ進める．
            // 取得段は取得した命令が分岐・ジャンプかを調べず，常に順番どおりの次の番地を取得していく．
            // 飛び先が確定するのは実行段で，飛び先を控えて次のサイクルに置き換える(fetch_pcを参照)
            fetch_next_pc <= fetch_pc + register_t'(fetch_request || ram_arrived);
            // 実行段が分岐・ジャンプで後の命令を捨てるかと，その飛び先を控える
            redirect_pending <= ex_redirects;
            redirect_pc <= next_pc;

            // ===== 取得段: メモリの後半からの命令の取得 =====

            // 取得用のプログラムカウンタがROMへ渡せる幅を外れ，パイプラインが空になったら，メモリの後半から取得するか停止する．
            // パイプラインが空になるのを待つのは，実行中の命令とメインメモリの読み出しポートを取り合わないためと，
            // 前の命令が分岐・ジャンプで飛び先を変える可能性や，メモリの後半へ命令を書き込み終えていない可能性があるため
            if (pipeline_drained) begin
                // メモリの後半を指していれば，メインメモリへ命令の下位ワードの読み出しを要求する
                if (pc_in_code_area) begin
                    ram_read.valid   <= 1'b1;
                    ram_read.mask    <= 4'hf;
                    ram_read.address <= fetch_lower_address;
                    fetching_from_ram <= 1'b1;
                    fetching_upper_word <= 1'b0;
                end
                // ROMにもメモリの後半にも命令を置けない番地へ進んだため，その番地で停止する
                else begin
                    is_halted <= 1'b1;
                end
            end

            // メインメモリからの命令の取り込み．下位ワード・上位ワードの順に読み出す．
            // メインメモリの読み出しを要求している間は停止しない(取得段の停止は要求を出す前に起こり，要求中はパイプラインが
            // 空のため確認段・実行段の停止も起こらない)ことを前提に，
            // 停止時のメインメモリのリセットは行っていない(メインメモリはresetnでのみリセットされる)
            if (fetching_from_ram && ram_read.ready) begin
                // 下位ワード(イミディエイトデータ)を控え，続けて上位ワードを読む．validを下ろさずに番地だけを
                // 変えると，メインメモリは完了を返した次のサイクルに待機へ戻った時点で新しい要求として受け付ける
                // (一度下ろすと，上げ直すまでの1サイクルが余分にかかる)
                if (!fetching_upper_word) begin
                    ram_fetch_lower_r <= ram_read.data;
                    ram_read.address <= fetch_upper_address;
                    fetching_upper_word <= 1'b1;
                end
                // 上位ワード(命令語)が届いて命令が揃ったので，読み出しを終える(命令は命令キューへ取り込む)
                else begin
                    ram_read.valid <= 1'b0;
                    fetching_from_ram <= 1'b0;
                    fetching_upper_word <= 1'b0;
                end
            end

            // ===== 取り込み段 =====

            // 命令キューの各位置を更新する．取り込んだ命令を入れる位置(前へ詰めた後の末尾)には取り込んだ命令を入れ，
            // それ以外は，確認段の命令を実行段へ渡す場合に，後ろの命令を1つずつ前へ詰める
            for (int i = 0; i < QUEUE_DEPTH; i++) begin
                if (queue_push && i == queue_count - dispatch) begin
                    queue_instruction[i] <= push_instruction;
                    queue_pc[i]          <= push_pc;
                    queue_pc_valid[i]    <= push_pc_valid;
                end
                else if (dispatch && i < QUEUE_DEPTH - 1) begin
                    queue_instruction[i] <= queue_instruction[i + 1];
                    queue_pc[i]          <= queue_pc[i + 1];
                    queue_pc_valid[i]    <= queue_pc_valid[i + 1];
                end
            end
            // 命令キューの命令数を，分岐・ジャンプで取得し直す場合は0にし，それ以外は入れた数と取り除いた数で更新する
            if (ex_redirects) begin
                queue_count <= '0;
            end
            else begin
                queue_count <= queue_count + queue_push - dispatch;
            end

            // ===== 確認段: 実行段への受け渡し =====

            if (dispatch) begin
                // 実行できる命令は，実行に使う値と命令の内容を実行段へ渡す
                if (check_executable) begin
                    // 第1オペランドの読み出し値を選ぶ．読み出しアドレスが，このサイクルに完了する複数サイクル命令の書き込み先と
                    // 重なる場合は，レジスタから読んだ値ではなく書き込む値をそのまま使う(フォワーディング)
                    rs1_val_r <=
                        // 読み出すのがプログラムカウンタなら，渡す命令自身の番地(プログラムカウンタはレジスタから読まないため)
                        (command_next.rs1 == PC_ADDR) ? queue_pc[0]
                        // 割り算がこのサイクルに余りを書き込む番地なら，その余り．商と同じ番地なら余りを優先する
                        // (レジスタには後から代入する余りが残り，商を優先すると読む値とレジスタの中身が食い違うため)
                        : (remainder_write_valid && remainder_write_addr == command_next.rs1) ? remainder_write_value
                        // 複数サイクル命令がこのサイクルに結果を書き込む番地なら，その結果
                        : (late_write_valid      && late_write_addr      == command_next.rs1) ? late_write_value
                        // それ以外は，レジスタから読んだ値
                        : register[command_next.rs1];
                    // 第2オペランドも，第1オペランドと同じ優先順で選ぶ
                    rs2_val_r <=
                        // 読み出すのがプログラムカウンタなら，渡す命令自身の番地
                        (command_next.rs2 == PC_ADDR) ? queue_pc[0]
                        // 割り算がこのサイクルに余りを書き込む番地なら，その余り
                        : (remainder_write_valid && remainder_write_addr == command_next.rs2) ? remainder_write_value
                        // 複数サイクル命令がこのサイクルに結果を書き込む番地なら，その結果
                        : (late_write_valid      && late_write_addr      == command_next.rs2) ? late_write_value
                        // それ以外は，レジスタから読んだ値
                        : register[command_next.rs2];
                    // 読み出しアドレスが，このサイクルに完了する1サイクル命令の書き込み先と重なる場合は，実行段の入口で
                    // その結果(このサイクルにalu_result_rへ入る値)を使う．プログラムカウンタは書き込み先にならないため重ならない．
                    // 上の読み出し値のように確認段で差し替えないのは，1サイクル命令の結果は演算回路から出るため，ここまでの経路が
                    // 1クロックに収まらないため(複数サイクル命令の結果はメモリなどのレジスタから出るため収まる)
                    rs1_forward_r <= ex_alu_write && (rd_addr_r == command_next.rs1);
                    rs2_forward_r <= ex_alu_write && (rd_addr_r == command_next.rs2);
                    rd_addr_r <= command_next.rd;
                    func_r    <= command_next.func;
                    imm_r     <= command_next.imm;
                    mask_r    <= command_next.mask;
                    current_instruction <= queue_instruction[0];
                end
                // 実行段の命令が分岐・ジャンプで後の命令を捨てる場合は，実行できない命令でも捨てられるため何もしない
                else if (ex_redirects) begin
                    ;
                end
                // 実行できない命令は動作を保証できないため，その番地で停止させる
                else begin
                    is_halted <= 1'b1;
                end
            end

            // ===== 実行段: 複数サイクルかかる命令の要求と応答待ち =====
            // 完了の判定と結果の書き込みは，ここではなく実行段の完了判定(ex_completes)と下の共通の処理で行う
            if (ex_occupied) begin
                // 関数タイプごとに実行
                unique case (command.m_type)
                    // 処理を実行しない(N系)．不正な値が入っても全て無視する
                    N_TYPE: ;

                    // 演算系(P系)
                    P_TYPE: begin
                        unique case (func_r)
                            // 1サイクルで完了する演算は，共通の処理で結果を書き込むだけで，ここで行うことはない
                            AND, OR, XOR, NOT, NAND, ADD, SUB: ;

                            // 掛け算．結果が確定するまで1サイクル待ってから完了する
                            MUL: begin
                                unique case (mul_state)
                                    // 乗算を実行し，結果が確定するまで待つ
                                    IDLE: begin
                                        mul_result_r <= rs1_val * rs2_val;
                                        mul_state <= RESPONSE;
                                    end

                                    // 確定した乗算結果を書き込んで完了する
                                    RESPONSE: mul_state <= IDLE;

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
                                        if (rs2_val == '0) begin
                                            is_halted <= 1'b1;
                                        end
                                        // 符号あり除算
                                        else if (func_r == DIV) begin
                                            div_dividend_tdata   <= rs1_val;
                                            div_divisor_tdata    <= rs2_val;
                                            div_dividend_tvalid  <= 1'b1;
                                            div_divisor_tvalid   <= 1'b1;
                                            div_state <= EXECUTE;
                                        end
                                        // 符号なし除算
                                        else if (func_r == DIVU) begin
                                            divu_dividend_tdata  <= rs1_val;
                                            divu_divisor_tdata   <= rs2_val;
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

                                    // 計算結果が返ってくるまで待機し，返ってきたら商・余りを書き込んで完了する
                                    RESPONSE: begin
                                        if (div_result_tvalid) begin
                                            div_state <= IDLE;
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
                            // 共通の処理でシフト結果を書き込むだけで，ここで行うことはない
                            SLL, SRL, SLA, SRA: ;
                            default: begin
                                is_halted <= 1'b1;
                            end
                        endcase
                    end

                    // 代入系
                    A_TYPE: begin
                        // 命令がMOVなら，共通の処理で代入値(イミディエイトデータまたはrs1)を書き込むだけで，ここで行うことはない
                        if (func_r != MOV) begin
                            is_halted <= 1'b1;
                        end
                    end

                    // 分岐系
                    F_TYPE: begin
                        unique case (func_r)
                            // 共通の処理で比較結果を反映した番地へ進むだけで，ここで行うことはない
                            EQ, NE, LT, GT, ELT, EGT, LTU, GTU, ELTU, EGTU: ;
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
                            // ジャンプ．共通の処理で飛び先へ進むだけで，ここで行うことはない
                            JMP: ;

                            // 関数呼び出し
                            CALL: begin
                                unique case (ram_write_state)
                                    // 戻り先(呼び出しの次の番地)を，スタックポインタの1ワード下へ書き込む
                                    IDLE: request_ram_write(4'hf, sequential_pc);

                                    // 書き込みが完了したら，積んだ戻り先を指すようスタックポインタを下げる(飛び先へは共通の処理で進む)
                                    EXECUTE: begin
                                        if (ram_write.ready) begin
                                            ram_write_state <= IDLE;
                                            ram_write.valid <= 1'b0;
                                            register[SP_ADDR] <= register[SP_ADDR] - 4;
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

                                    // 読み出しが完了したら，下ろした戻り先の分スタックポインタを上げる(戻り先へは共通の処理で進む)
                                    EXECUTE: begin
                                        if (ram_read.ready) begin
                                            ram_read_state <= IDLE;
                                            ram_read.valid <= 1'b0;
                                            register[SP_ADDR] <= register[SP_ADDR] + 4;
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
                                        // 読み込みが完了したなら(読んだ値は共通の処理で書き込む)
                                        if (ram_read.ready) begin
                                            // 待機状態に遷移
                                            ram_read_state <= IDLE;
                                            // 実行状態をオフ
                                            ram_read.valid <= 1'b0;
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
                                    IDLE: request_ram_write(mask_r, rs2_val);

                                    // メモリ書き込み実行
                                    EXECUTE: begin
                                        // 書き込みが完了したなら
                                        if (ram_write.ready) begin
                                            // 待機状態に遷移
                                            ram_write_state <= IDLE;
                                            // 実行状態をオフ
                                            ram_write.valid <= 1'b0;
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
                                        // データが送られてきているなら(受け取った値は共通の処理で書き込む)
                                        if (stdin_tvalid) begin
                                            // 一文字ずつ読み込むため，これだけ読みこんだら終了する
                                            stdin_state <= IDLE;
                                            stdin_tready <= 1'b0;
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
                                            stdout_tdata <= rs1_val;
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

            // ===== 実行段: 完了した命令の結果の書き込み =====

            // 1サイクルで完了する命令の結果を書き込み，次の命令が受け取れるよう保持する
            if (ex_alu_write) begin
                register[rd_addr_r] <= write_value;
                alu_result_r <= write_value;
            end
            // 複数サイクルかけて得た結果を書き込む
            if (late_write_valid) begin
                register[late_write_addr] <= late_write_value;
            end
            // 割り算の余りを書き込む．商と同じ番地を指定された場合は，後から代入する余りが残る
            if (remainder_write_valid) begin
                register[remainder_write_addr] <= remainder_write_value;
            end
            // 実行段に命令が入っているかを更新する
            // 実行できる命令を受け取れば入る(分岐・ジャンプで後の命令を捨てる場合は，同じサイクルに受け取った命令も捨てるため除く)
            if (dispatch && check_executable && !ex_redirects) begin
                ex_occupied <= 1'b1;
            end
            // 受け取らずに命令が完了すれば空く(後の命令を捨てる場合もここに来る)
            else if (ex_completes) begin
                ex_occupied <= 1'b0;
            end

            // ===== 実行段: 実行段の命令の番地 =====

            // 確認段から命令を受け取る場合はその命令の番地にする(実行できず停止する命令でも同じく更新する)
            if (dispatch) begin
                ex_pc <= queue_pc[0];
            end

            // ===== IOからレジスタへの取り込み =====
            // 同じクロックで同じ変数へ複数のノンブロッキング代入を行うと，代入する値はどれも代入前の値から求まるが，
            // 変数に残るのは後に実行した代入の値になる．この性質を使い，命令による書き込みより後に置くことで，
            // 命令が同じサイクルにAR_SPIへ書き込んでも，MISOビットにはピンの値が残るようにしている

            // タクトスイッチ・DIPスイッチは同期化後の値で，ピンの値が届くまでこの1段と合わせて3サイクルかかる
            register[BTN_ADDR] <= {4'b0, btn_sync[1]};
            register[SW_ADDR] <= {6'b0, sw_sync[1]};
            // Arduino SPIのMISOビットのみ外部ピンを毎サイクル取り込む(SCK・MOSI・SSビットは
            // CPUの書き込みをそのまま保持し，このブロックでは触れない)
            // 取り込むのは同期化後の値で，ピンの値が届くまでこの1段と合わせて3サイクルかかる
            register[SPI_ADDR][3] <= miso_sync[1];
        end
    end
endmodule
