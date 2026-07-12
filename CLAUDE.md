# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

PYNQ-Z2 (Xilinx Zynq-7020 FPGA) 上で動作するカスタムCPUの，ハードウェア実装(Vivadoプロジェクト)．自作PC全体のうち，**ハードウェア部分の実装のみ**を担当する(全体のロードマップは`../CLAUDE.md`を参照)．CALL/RET命令まで実装・実機動作確認済み．

このリポジトリはVivadoプロジェクトのルート(`mypc.xpr`のあるディレクトリ)そのものをGit管理する．Vivadoが合成・実装のたびに再生成するディレクトリ(`mypc.cache/`・`mypc.gen/`・`mypc.hw/`・`mypc.ip_user_files/`・`mypc.runs/`・`mypc.sim/`・`.Xil/`・ログ/ジャーナル)は`.gitignore`で除外している．

## ビルド・シミュレーション方法

本プロジェクトはコマンドラインビルドシステムを持たず、**Xilinx Vivado IDE** で操作する。

- **合成・実装・ビットストリーム生成**: Vivado GUI で `Generate Bitstream` を実行
- **シミュレーション**: Vivado のシミュレーション機能で `sim_1/new/top_sim.v` を使用
- **プロジェクトファイル**: リポジトリ直下の `mypc.xpr` をVivadoで開く

## ディレクトリ構造

```
mypc/                                  # リポジトリルート(Vivadoプロジェクトルート)
├── mypc.xpr                           # Vivadoプロジェクトファイル
└── mypc.srcs/
    ├── constrs_1/new/top.xdc          # PYNQ-Z2ボードのピン制約  ← 編集可
    ├── cpp/                           # PS(ARM)側のC++プログラム ← 編集可
    ├── sim_1/                         # テストベンチ             ← 編集禁止
    ├── sources_1/
    │   ├── bd/                        # Vivadoブロックダイアグラム ← 編集禁止
    │   ├── imports/                   # Vivado自動生成ファイル    ← 編集禁止
    │   └── new/                       # カスタムHDLソース        ← 編集可
    └── utils_1/                       # デザインチェックポイント  ← 編集禁止
```

### 編集禁止ディレクトリ

以下は Vivado が自動生成・管理するディレクトリであり、**開発者・Claude Code ともに直接編集してはならない**。

| ディレクトリ | 理由 |
|-------------|------|
| `mypc.srcs/sim_1/` | Vivado管理のシミュレーションファイル |
| `mypc.srcs/sources_1/bd/` | Vivadoブロックダイアグラム（GUI操作で変更） |
| `mypc.srcs/sources_1/imports/` | Vivado自動生成トップラッパー |
| `mypc.srcs/utils_1/` | Vivadoデザインチェックポイント (.dcp) |

### 編集対象ディレクトリ

| ディレクトリ | 内容 |
|-------------|------|
| `mypc.srcs/sources_1/new/` | カスタムCPUのHDLソース（主な作業対象） |
| `mypc.srcs/constrs_1/new/` | PYNQ-Z2ボードのピン制約 (top.xdc) |
| `mypc.srcs/cpp/` | PS(ARM)側のC++プログラム(`run.cpp`が現行版。`run1.cpp`〜`run4.cpp`は開発初期の試作版) |

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
- **number**: 7セグメントディスプレイへの8ビット出力

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

## 開発上の注意点

- 新しい命令を追加する場合は `machine.svh` → `decorder_sv.sv` → `alu_sv.sv` の順に変更が必要。
- ROMのプログラム変更は `rom_sv.sv` 内の命令配列を直接書き換える。
- `mother_board.v` はVerilogラッパーで、SystemVerilogの `mother_board_sv.sv` を呼び出す構造になっている（Vivado IPとの互換性のため）。

## このプロジェクトの残件・既知課題(ハードウェア)

- CALL/RET のタイミング: RET の `register[register[SP_ADDR]]` (二重インデックス) と CALL の動的書き込みアドレスは組合せMUXが深い．合成は通るが将来最適化の余地あり (CHECKフェーズでの先読みラッチ等)
- スタックオーバーフロー検出なし (10階層 = 6'h1a 超は未定義動作)
- 将来的に戻り先スタックをレジスタ方式 → RAM方式へ移行検討 (ネスト無制限化)
- rom_sv.sv は現在 CALL/RET 動作確認用のテストプログラム (ABCDE出力)．シェル実装時に差し替える
- run.cpp は現在ABCDE受信用．シェル実装時にターミナルエミュレータに改修する

## 仕様書

`../specification/` (絶対パス: `C:\D\program\xilinx\pynq-z2\pc\specification\`) に仕様書が置かれている．

| ファイル | 内容 |
|---------|------|
| `index.md` | 目次・概要 |
| `isa.md` | 命令セットアーキテクチャ |
| `register.md` | レジスタ定義 |
| `memory.md` | メモリ仕様 |
| `circuit.md` | 回路仕様 |
| `rom.md` | ROM仕様 |
| `assembler.md` | アセンブラ仕様 |
| `compiler.md` | 自作C系言語・コンパイラ仕様 |
| `limitations.md` | 通常CPUとの差分・非対応事項 |
