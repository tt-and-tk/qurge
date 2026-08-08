# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

GitHubリポジトリ名: `tt-and-tk/qurge`．

PYNQ-Z2(Zynq-7000)上に実装する自作CPUと，それを動かすソフトウェア群(アセンブラ・コンパイラ)からなる自作PCプロジェクトの一部．プロジェクト全体は以下の独立したGitHubリポジトリで構成される．

| リポジトリ(GitHub) | ディレクトリ(`pc/`配下) | 役割 |
|:-|:-|:-|
| `specification` | `specification/` | CPUアーキテクチャ・ISA・アセンブリ言語・コンパイラ仕様のドキュメント(唯一の一次情報源) |
| `pyntaxis` | `assembler/` | 自作アセンブリ言語Pyntaxis(`.pt`) → SystemVerilog ROM(`.sv`)へのアセンブラ |
| `pynesis` | `compiler/` | 自作プログラミング言語Pynesis(`.pn`) → アセンブリ言語Pyntaxisへのコンパイラ．`pyntaxis`のソースファイルをincludeして使用し，`.sv`まで一貫変換も可能 |
| `qurge`(本リポジトリ) | `mypc/` | CPU・メモリ・ROM等のハードウェア全体のVivadoプロジェクト(SystemVerilog + PS側C++) |
| `for-pynthesis-skills` | `for-pynthesis-skills/` | 上記各リポジトリで共有するissue起票・対応支援スキルを提供する．特定のリポジトリが主担当と判断できない，全リポジトリに影響するissueの起票先(受け皿)でもある |

```
入力(.pn) → [pynesisのコンパイラ] → アセンブリ(.pt) → [pyntaxisのアセンブラ] → SystemVerilog ROM(.sv) → [Vivado] → PYNQ-Z2上のハードウェア(qurge，本リポジトリ)
```

## ビルド・シミュレーション方法

本プロジェクトはコマンドラインビルドシステムを持たず、**Xilinx Vivado IDE** で操作する。

- **合成・実装・ビットストリーム生成**: Vivado GUI で `Generate Bitstream` を実行
- **プロジェクトファイル**: リポジトリ直下の `mypc.xpr` をVivadoで開く

チェックアウトしたばかりのディレクトリでは，ブロックダイアグラムの出力生成物とデザインチェックポイントがまだ存在しない。このため最初の1回だけ以下が必要になる。

1. ブロックダイアグラムを開き `Generate Output Products` を実行する(IPのHDL・ラッパー・合成用ファイルが生成される)
2. `Generate Bitstream` を実行する。中間生成物が無い状態からの合成になるため長時間かかる

デザインチェックポイントはGit管理外のため，チェックアウトした直後は`mypc.xpr`に登録済みのファイルが見つからない旨の警告が出る。最初の合成で生成されるため対処は不要。

`mypc.xpr`は開いた場所の絶対パス・各ソースの取り込み時刻・上記チェックポイントの登録状態を保持しており，開くだけで内容が書き換わる。ソースを変更していないのに生じたこの差分はコミットしない。ソースやブロックダイアグラムを変更して`mypc.xpr`を正当にコミットする場合も，これらの行だけは元の値に戻してからコミットする(開いた場所によって値が変わるため，そのまま入れるとディレクトリを移るたびに書き換わり続ける)。

## ディレクトリ構造

```
mypc/                                  # リポジトリルート(Vivadoプロジェクトルート)
├── mypc.xpr                           # Vivadoプロジェクトファイル
└── mypc.srcs/
    ├── constrs_1/new/top.xdc          # PYNQ-Z2ボードのピン制約  ← 編集可
    ├── cpp/                           # PS(ARM)側のC++プログラム ← 編集可(Vivado標準構成にはなく，独自に追加したディレクトリ)
    ├── sim_1/                         # テストベンチ(未作成)     ← 編集可
    ├── sources_1/
    │   ├── bd/                        # Vivadoブロックダイアグラム ← 編集禁止
    │   ├── imports/                   # Vivado自動生成ファイル    ← 編集禁止
    │   └── new/                       # カスタムHDLソース        ← 編集可
    └── utils_1/                       # デザインチェックポイント  ← 編集禁止
```

### 編集禁止ディレクトリ

以下は Vivado が自動生成・管理するディレクトリであり、**開発者・Claude Code ともに直接編集してはならない**。

| ディレクトリ | 理由 | Git管理 |
|-------------|------|---------|
| `mypc.srcs/sources_1/bd/` | Vivadoブロックダイアグラム（GUI操作で変更） | 対象 |
| `mypc.srcs/sources_1/imports/` | Vivado自動生成トップラッパー | 対象 |
| `mypc.srcs/utils_1/` | Vivadoデザインチェックポイント (.dcp) | 対象外 |

チェックアウトしたディレクトリでプロジェクトを開き合成するにはブロックダイアグラムとトップラッパーの実体が要るため，これらはGit管理下に置く。編集はGUI操作を通してのみ行い，ファイルを直接書き換えない。デザインチェックポイントは合成・実装をやり直せば再生成されるためGit管理外とする。

### 編集対象ディレクトリ

| ディレクトリ | 内容 |
|-------------|------|
| `mypc.srcs/sources_1/new/` | カスタムCPUのHDLソース（主な作業対象） |
| `mypc.srcs/constrs_1/new/` | PYNQ-Z2ボードのピン制約 (top.xdc) |
| `mypc.srcs/cpp/` | PS(ARM)側のC++プログラム(`run.cpp`が現行版。`run1.cpp`〜`run4.cpp`は開発途中のスナップショット) |
| `mypc.srcs/sim_1/` | テストベンチ(まだ1つも書いておらず，ディレクトリ自体が存在しない) |

テストベンチはVivadoが自動生成するものではないため，書いた場合はGit管理の対象とする。

## アーキテクチャ

### 階層構造

```
top_wrapper.v (Vivado自動生成)
└── top.bd (ブロックダイアグラム)
    ├── Processing System 7 (ARM Cortex-A9)
    ├── AXI DMA + AXI Stream FIFO  ← stdin/stdout の転送
    └── mother_board IP
        └── mother_board.v (Verilogラッパー)
            └── mother_board_sv.sv
                ├── cpu_sv.sv
                │   ├── decorder_sv.sv
                │   └── alu_sv.sv
                ├── ram_sv.sv
                └── rom_sv.sv
```

### カスタムCPU仕様

**64ビット機械語フォーマット** (`machine.svh`)
```
[type:3bit | func:6bit | mask:4bit | rs1:6bit | rs2:6bit | rd:6bit | imm:33bit]
```
※イミディエイトデータの最上位ビットは，イミディエイトデータを使用するかどうかのフラグ．\
　実データは下位32bitぶんのみ．

**命令タイプ** (3bit)
| type | 名前 | 内容 |
|------|------|------|
| N_TYPE | NOP | 何もしない |
| P_TYPE | 演算 | AND/OR/XOR/NOT/NAND/ADD/SUB |
| S_TYPE | シフト | SLL/SRL/SLA/SRA |
| A_TYPE | MOV | レジスタ転送 |
| F_TYPE | 分岐 | EQ/NE/LT/GT/ELT/EGT |
| J_TYPE | ジャンプ | 無条件ジャンプ |
| M_TYPE | メモリ | RM/WM/BRM/BWM |
| IO_TYPE | 入出力 | SCAN(入力)/PRINT(出力) |

**レジスタマップ** (`alu.svh`, `register.svh`)
- `0x00-0x0F`: 汎用レジスタ (R0-R15)
- `0x10`: SP (スタックポインタ)
- `0x1C`: FLG (フラグレジスタ)
- `0x1F`: PC (プログラムカウンタ)
- `0x20`: BTN (ボタン入力、読み取り専用)
- `0x21`: SW (スイッチ入力、読み取り専用)
- `0x22`: LED (LED出力、書き込み専用)
- `0x30`: STDIN (AXI Stream入力)
- `0x31`: STDOUT (AXI Stream出力)
- 総レジスタ数: 53個 (32ビット幅)

### I/Oインターフェース

- **stdin/stdout**: AXI Stream インターフェース経由でPS(ARM)と通信
- **btn/sw/led**: GPIO直結
- **rgb_led**: RGB LED
- **number**: 7セグメントディスプレイへの8ビット出力(デバッグ用)

### メモリ

- **ROM** (`rom_sv.sv`): プログラムメモリ (最大固定命令数)
- **RAM** (`ram_sv.sv`): データメモリ、IDLE→EXECUTE→RESPONSEの状態遷移

### ヘッダーファイル（インターフェース定義）

| ファイル | 内容 |
|----------|------|
| `machine.svh` | 命令フォーマット・タイプ・関数コード定数 |
| `alu.svh` | ALU関数定義、レジスタアドレス定数、`is_readable()`/`is_writable()` |
| `decorder.svh` | `command_if` インターフェース (master/slave modport) |
| `ram.svh` | `ram_read_if`, `ram_write_if` インターフェース |
| `rom.svh` | `rom_read_if` インターフェース |
| `register.svh` | SP/FLG/PCなどの特殊レジスタアドレス定数 |
| `util.svh` | `bool_t` 型定義 |

### svファイル

| ファイル | 内容 |
|----------|------|
| `mother_board_sv.sv` | マザーボード部分．CPUやメインメモリなど各パーツを格納する |
| `ram_sv.sv` | メインメモリ |
| `cpu_sv` | CPU．命令のデコードと実行を担当する |
| `rom.sv` | 読み込み専用メモリ．実行するプログラムを格納する |
| `decorder_sv.sv` | 機械語の命令を分解する |
| `alu_sv.sv` | 機械語で指定された命令を実行する．レジスタを持つ |

### 変数命名規則

- パッケージ: `xx_p`
- 列挙体: `xx_enum`
- インターフェース: `xx_if`
- 変数の型: `xx_t`

## Issue対応の徹底

ファイルを修正する場合は，必ず対応するGitHub issueを起票し，そのissue用のブランチ(`fix/issue-<番号>-<内容を表す短い語句>`)を作成してから行う．デフォルトブランチを直接編集しない．

**例外:** `CLAUDE.md`や`.claude/skills/`配下のスキル定義ファイルの修正は，ソースコードの変更ではないためissue起票は不要．ただしブランチ作成は必要(デフォルトブランチを直接編集しない)．作業中の既存ブランチがあれば，新たにブランチを切らずそれに乗せてよい．

## このプロジェクトの残件・既知課題(ハードウェア)

- CALL/RET のタイミング: RET の `register[register[SP_ADDR]]` (二重インデックス) と CALL の動的書き込みアドレスは組合せMUXが深い．さらにRETの戻り先は`next_pc`経由でROMアドレスにも入るため，この二重インデックスの先にROM読み出し・次命令デコード・実行可否判定が直列に繋がる．戻り先スタックの先頭を専用レジスタに持たせれば二重インデックスをこの経路から外せる (将来最適化の余地あり)
- RETを先読み対象から外せばROMアドレス経路から二重インデックスが消え，代償はRET1回あたり数サイクルのバブルのみ．合成でタイミングが収束しない場合の逃げ道として`can_prefetch`に条件を1つ足す
- スタックオーバーフロー検出なし (10階層 = 6'h1a 超は未定義動作)
- スタックアンダーフロー検出なし (空スタックでRETするとSPが汎用レジスタ領域へ潜り込み，戻り先としてSP自身の初期値が読まれる)
- 将来的に戻り先スタックをレジスタ方式 → RAM方式へ移行検討 (ネスト無制限化)
- rom_sv.sv は現在 制御ハザード動作確認用のテストプログラム (後方分岐の繰り返し・連続分岐・出力直後の分岐・関数呼び出し・ネスト呼び出し・飛び先をレジスタで指定する呼び出しと移動を通り「012OK」を出力)．シェル実装時に差し替える
- run.cpp は現在，入力を1文字ずつ送信したあとFPGAからの出力を1文字ずつ受信し続ける実装．シェル実装時にターミナルエミュレータに改修する
- ROMの`ROM_SIZE`はハードウェア側の固定値ではなく，コンパイル対象プログラムのサイズに応じてアセンブラが自動算出する．現在のROM読み出し回路(`rom_sv.sv`)は組合せ論理(非同期読み出し)であり，この方式のままではVivado合成時にBlock RAM(BRAM)には推論されずLUT資源(XC7Z020: 53,200 LUT)を消費する形になる．PYNQ-Z2搭載のZynq-7020のBRAM容量(4.9Mbit)を活用してより大きなプログラムを収容するには，ROM読み出し回路を同期(クロック同期)方式に変更しBRAM推論可能な設計にするハードウェア変更が必要(CPUのフェッチ段のタイミングにも影響するため要検証．優先度は高くないが#6で管理)
