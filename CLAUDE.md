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

本プロジェクトはコマンドラインビルドシステムを持たず，**Xilinx Vivado IDE** で操作する．

- **合成・実装・ビットストリーム生成**: Vivado GUI で `Generate Bitstream` を実行
- **プロジェクトファイル**: リポジトリ直下の `mypc.xpr` をVivadoで開く

チェックアウトしたばかりのディレクトリでは，ブロックダイアグラムの出力生成物とデザインチェックポイントがまだ存在しない．このため最初の1回だけ以下が必要になる．

1. ブロックダイアグラムを開き `Generate Output Products` を実行する(IPのHDL・ラッパー・合成用ファイルが生成される)
2. `Generate Bitstream` を実行する．中間生成物が無い状態からの合成になるため長時間かかる

デザインチェックポイントはGit管理外のため，チェックアウトした直後は`mypc.xpr`に登録済みのファイルが見つからない旨の警告が出る．最初の合成で生成されるため対処は不要．

`mypc.xpr`は開いた場所の絶対パス・各ソースの取り込み時刻・上記チェックポイントの登録状態を保持しており，開くだけで内容が書き換わる．ソースを変更していないのに生じたこの差分はコミットしない．ソースやブロックダイアグラムを変更して`mypc.xpr`を正当にコミットする場合も，これらの行だけは元の値に戻してからコミットする(開いた場所によって値が変わるため，そのまま入れるとディレクトリを移るたびに書き換わり続ける)．

## PS側(ARM/C++)のビルド・書き込み方法

`mypc.srcs/cpp/`配下のC++プログラムは，PC側でのクロスコンパイルは行わず，**PYNQ-Z2ボード上のLinux環境で直接ビルド・実行する**．

1. ボード上の任意の作業ディレクトリへ，`mypc.srcs/cpp/`配下のファイル(`run.cpp`・`compile.sh`)と，Vivadoが生成したビットストリームを転送する
2. その作業ディレクトリの直下に`bit/`ディレクトリを作成し，ビットストリームを`bit/top_wrapper.bit`として配置する(`run.cpp`が実行時のカレントディレクトリからの相対パス`./bit/top_wrapper.bit`でこれを参照するため)
3. 作業ディレクトリ内で`bash compile.sh`を実行してビルドする(内容は`g++ -o run run.cpp -lpynq -lcma -lpthread`)
4. `./run`を実行する(root権限は不要)

## ディレクトリ構造

```
mypc/                                  # リポジトリルート(Vivadoプロジェクトルート)
├── mypc.xpr                           # Vivadoプロジェクトファイル
└── mypc.srcs/
    ├── constrs_1/new/top.xdc          # PYNQ-Z2ボードのピン制約  ← 編集可
    ├── cpp/                           # PS(ARM)側のC++プログラム ← 編集可(Vivado標準構成にはなく，独自に追加したディレクトリ)
    ├── pn/                            # ROM上で動くPynesisソース ← 編集可(Vivado標準構成にはなく，独自に追加したディレクトリ)
    ├── sources_1/
    │   ├── bd/                        # Vivadoブロックダイアグラム ← 編集禁止
    │   ├── imports/                   # Vivado自動生成ファイル    ← 編集禁止
    │   └── new/                       # カスタムHDLソース        ← 編集可
    └── utils_1/                       # デザインチェックポイント  ← 編集禁止
```

### 編集禁止ディレクトリ

以下は Vivado が自動生成・管理するディレクトリであり，**開発者・Claude Code ともに直接編集してはならない**．

| ディレクトリ | 理由 | Git管理 |
|-------------|------|---------|
| `mypc.srcs/sources_1/bd/` | Vivadoブロックダイアグラム（GUI操作で変更） | 対象 |
| `mypc.srcs/sources_1/imports/` | Vivado自動生成トップラッパー | 対象 |
| `mypc.srcs/utils_1/` | Vivadoデザインチェックポイント (.dcp) | 対象外 |

チェックアウトしたディレクトリでプロジェクトを開き合成するにはブロックダイアグラムとトップラッパーの実体が要るため，これらはGit管理下に置く．編集はGUI操作を通してのみ行い，ファイルを直接書き換えない．デザインチェックポイントは合成・実装をやり直せば再生成されるためGit管理外とする．

### 編集対象ディレクトリ

| ディレクトリ | 内容 |
|-------------|------|
| `mypc.srcs/sources_1/new/` | カスタムCPUのHDLソース（主な作業対象） |
| `mypc.srcs/constrs_1/new/` | PYNQ-Z2ボードのピン制約 (top.xdc) |
| `mypc.srcs/cpp/` | PS(ARM)側のC++プログラム(`run.cpp`が現行版)．`compile.sh`はPYNQ-Z2ボード上でビルドする際に使うスクリプト |
| `mypc.srcs/pn/` | ROM上で動くPynesisソース(`.pn`)．`compiler`の`c2asm.exe`でアセンブリへ，`assembler`の`asm2bin.exe`で`mypc.srcs/sources_1/new/rom_sv.sv`へ変換する(中間生成物の`.pt`は`.gitignore`対象) |
| `mypc.srcs/sim_1/` | テストベンチ(まだ1つも書いておらず，ディレクトリ自体が存在しない) |

テストベンチはVivadoが自動生成するものではないため，書いた場合はGit管理の対象とする．
