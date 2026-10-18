# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

GitHubリポジトリ名: `tt-and-tk/qurge`．

PYNQ-Z2(Zynq-7000)上に実装する自作CPUと，それを動かすソフトウェア群(アセンブラ・コンパイラ・OS)からなる自作パソコンのプロジェクトPynthesisの一部．Pynthesisは以下の独立したGitHubリポジトリで構成される．

| リポジトリ(GitHub) | ディレクトリ(`pc/`配下) | 役割 |
|:-|:-|:-|
| `specification` | `specification/` | CPUアーキテクチャ・ISA・アセンブリ言語・コンパイラ・Qosmosの仕様のドキュメント(唯一の一次情報源) |
| `pyntaxis` | `assembler/` | 自作アセンブリ言語Pyntaxis(`.pt`) → SystemVerilog ROM(`.sv`)，または自作OS Qosmosの実行ファイルへのアセンブラ |
| `pynesis` | `compiler/` | 自作プログラミング言語Pynesis(`.pn`) → アセンブリ言語Pyntaxisへのコンパイラ．`pyntaxis`のソースファイルをincludeして使用し，`.sv`または実行ファイルまで一貫変換も可能 |
| `qurge`(本リポジトリ) | `mypc/` | CPU・メモリ・ROM等のハードウェア全体のVivadoプロジェクト(SystemVerilog)と，ROM上で動く自作OS Qosmos(シェルやファイルシステムなど．Pynesisで記述．仕様は`specification`の`qosmos.md`) |
| `for-pynthesis-skills` | `for-pynthesis-skills/` | 上記各リポジトリで共有するissue起票・対応支援スキルを提供する．特定のリポジトリが主担当と判断できない，全リポジトリに影響するissueの起票先(受け皿)でもある |

```
入力(.pn) → [pynesisのコンパイラ] → アセンブリ(.pt) → [pyntaxisのアセンブラ] → SystemVerilog ROM(.sv) → [Vivado] → PYNQ-Z2上のハードウェア(qurge，本リポジトリ)
```

## ビルド・シミュレーション方法

合成・実装はコマンドラインビルドシステムを持たず，**Xilinx Vivado IDE** で操作する．

- **合成・実装・ビットストリーム生成**: Vivado GUI で `Generate Bitstream` を実行
- **プロジェクトファイル**: リポジトリ直下の `mypc.xpr` をVivadoで開く

チェックアウトしたばかりのディレクトリでは，ブロックダイアグラムの出力生成物とデザインチェックポイントがまだ存在しない．このため最初の1回だけ以下が必要になる．

1. ブロックダイアグラムを開き `Generate Output Products` を実行する(IPのHDL・ラッパー・合成用ファイルが生成される)
2. `Generate Bitstream` を実行する．中間生成物が無い状態からの合成になるため長時間かかる

デザインチェックポイントはGit管理外のため，チェックアウトした直後は`mypc.xpr`に登録済みのファイルが見つからない旨の警告が出る．最初の合成で生成されるため対処は不要．

`mypc.xpr`とブロックダイアグラムは，Vivadoが内容を自動で書き換える．ソースを変更していないのに生じたこれらの差分はコミットしない．正当な変更をコミットする場合の扱いはファイルごとに異なる．

- `mypc.xpr`: 開いた場所の絶対パス・各ソースの取り込み時刻・上記チェックポイントのパスを保持している．絶対パスと取り込み時刻は開くだけで書き換わる．チェックポイントのパスは，記録された場所と異なるディレクトリでチェックポイントが無い状態から合成すると，プロジェクト起点の`$PSRCDIR/...`から`$PPRDIR/..`でプロジェクトの外をたどる相対パスに書き換わる．ソースやブロックダイアグラムを変更して`mypc.xpr`を正当にコミットする場合も，これらの行だけは元の値に戻してからコミットする(開いた場所によって値が変わるため，そのまま入れるとディレクトリを移るたびに書き換わり続ける)
- ブロックダイアグラム: 自作HDLを取り込んだブロックの`ip_revision`(`top.bd`と，そのブロックの`.xci`．`.xci`では`IPREVISION`も同じ値を持つ)は，Vivadoがそのブロックを更新するたびに変わる(値は更新した時刻とみられる)．別の場所で開いて合成すると変わり，同じ場所で開き直すだけでは変わらない．ブロックダイアグラムの差分がこれらの値だけの場合は，ファイルを編集せずgitで差分を破棄する．ブロックダイアグラムを正当に変更したコミットでは，`ip_revision`の変更もそのまま含める(`mypc.xpr`の行と違い開いた場所そのものを表す値ではなく，同じ`.xci`でポート定義が変わっているのに版番号だけ戻すと食い違った状態になるため)

### QosmosのROMの生成

ROMの内容(`mypc.srcs/sources_1/new/rom_sv.sv`)は，QosmosのPynesisソース(`mypc.srcs/pn/`)から生成したものを使い，Qosmosの変更は`.pn`に対して行う．検証などのため一時的にQosmosのPynesisソース以外から作ったROMの内容を置いてもよいが，`.pn`から生成し直すと上書きされるためコミットしない．Vivadoはこの変換を行わず，生成済みの`rom_sv.sv`を他のHDLソースと同じく読み込むだけである．このため，`mypc.srcs/pn/`配下を変更したときと，コンパイラ・アセンブラを更新して生成結果が変わりうるときは，合成の前にリポジトリ直下で次を実行して`rom_sv.sv`を生成し直す．

```
pn2mc.exe -pn mypc.srcs/pn/qosmos.pn -pt mypc.srcs/pn/qosmos.pt -sv mypc.srcs/sources_1/new/rom_sv.sv
```

`pn2mc.exe`は`compiler`リポジトリでビルドし，そのディレクトリにPATHを通しておく．起動引数は`specification`の`compiler.md`を参照する．`-sv`を省略すると`.pt`と同じ場所へ出力されVivadoが読む`rom_sv.sv`は更新されないため，省略しない．

生成し直した`rom_sv.sv`に差分が出たらコミットする．`.pn`の変更によるものはその変更と同じコミットに含め，コンパイラ・アセンブラの更新によるものは単独でコミットする．チェックアウトした直後に変換ツールなしで合成できるよう，`rom_sv.sv`もGit管理下に置いているためである．

### CPUのシミュレーション

CPUの命令の動作は，合成せずVivado付属のシミュレータで検証できる．Vivadoのbinディレクトリ(`xvlog`・`xelab`・`xsim`)にPATHを通した上で，コマンドプロンプトから`mypc.srcs\sim_1\run_cpu_tb.bat`を実行する．全テストケースが合格すれば終了コード0で終わり，不合格があればその内容を表示して0以外で終わる．引数に`gui`を付けると，実行せずに波形ビューア付きのシミュレータを開く．コンパイル結果とログは`mypc.sim/cpu_tb/`(Git管理外)に出力される．

テストベンチはCPU本体とメインメモリを実物のまま使い，ROMと除算IPをモデルに差し替える．このため，ROMの内容(`rom_sv.sv`)とブロックダイアグラムは検証の対象外である．タイミング違反の有無も確認できないため，従来どおり合成と実機で確認する．\
`mypc.xpr`のシミュレーション機能は使わない．ブロックダイアグラムのシミュレーション用出力生成物まで生成・コンパイルすることになり，テストベンチに不要な時間がかかるためである．

## 実機での起動方法

PYNQ-Z2は，電源を入れるとボードのSDカードスロットに挿したカードのBOOT.BINから起動する．BOOT.BINには，FSBLとビットストリームだけを入れる．FSBL(First Stage Boot Loader)は，PS(ARM)が最初に実行するプログラムで，PSを初期化してからビットストリームをPLへ書き込む．書き込み後はPSを使わず，PL上のCPUだけが動き続ける．CPUのクロックとリセットはPSから受け取っており，PSを初期化して初めて供給される．

SDカードは2枚使う．

- ボードのSDカードスロットのカード: FAT32でフォーマットし，BOOT.BINを第1パーティションのルートに置く．ボードの起動元を選ぶジャンパ(Boot)はSDにしておく
- ArduinoヘッダのSPIにつないだカード: Qosmosのファイルシステムを置く(仕様は`specification`の`qosmos.md`)

### BOOT.BINの作成

VivadoとVitis(版はVivadoと揃える)のbinディレクトリ(`vivado`・`xsct`・`bootgen`)にPATHを通し，コマンドプロンプトから次を行う．Vitisは，PSで動くプログラムを作るXilinxの開発環境で，FSBLの生成とビルドに使う(`xsct`はそのコマンドラインのツール)．`bootgen`は，FSBLとビットストリームをBOOT.BINにまとめるツールで，Vivadoに付属する．出力はリポジトリ直下の`mypc.boot/`(Git管理外)に置かれる．

1. Vivadoで`Generate Bitstream`を実行する
2. 最初の1回と，ブロックダイアグラムでPS(`processing_system7_0`)の設定を変えたときは，`mypc.srcs\boot\make_fsbl.bat`を実行してFSBLを作る．FSBLはPSの設定だけに依存するため，自作HDLやROMの内容を変えただけなら作り直さなくてよい
3. `mypc.srcs\boot\make_boot.bat`を実行すると，`mypc.boot\BOOT.BIN`ができる

### 開発中の書き込み

動作を確かめる段階では，BOOT.BINを置いたカードで一度起動した後に，VivadoのHardware ManagerからJTAG(USB)でビットストリームを書き込んで上書きしてよい．ビットストリームを作り直すたびにBOOT.BINを作り直さずに済む．先にBOOT.BINで起動しておくのは，JTAGではPSを初期化せず，CPUのクロックとリセットがFSBLの起動で初めて供給されるためである．

## ディレクトリ構造

```
mypc/                                  # リポジトリルート(Vivadoプロジェクトルート)
├── mypc.xpr                           # Vivadoプロジェクトファイル
└── mypc.srcs/
    ├── boot/                          # BOOT.BINを作るスクリプト  ← 編集可(Vivado標準構成にはなく，独自に追加したディレクトリ)
    ├── constrs_1/new/top.xdc          # PYNQ-Z2ボードのピン制約  ← 編集可
    ├── pn/                            # ROM上で動くQosmosのPynesisソース ← 編集可(Vivado標準構成にはなく，独自に追加したディレクトリ)
    ├── sim_1/                         # テストベンチ              ← 編集可
    ├── sources_1/
    │   ├── bd/                        # Vivadoブロックダイアグラム ← 編集禁止
    │   ├── imports/                   # Vivado自動生成ファイル    ← 編集禁止
    │   └── new/                       # カスタムHDLソース        ← 編集可
    └── utils_1/                       # デザインチェックポイント  ← 編集禁止
```

### 編集禁止ディレクトリ

以下は Vivado が自動生成・管理するディレクトリである．中のファイルを変更してよいのはVivadoを介した操作(GUIかTclかは問わない)だけであり，**開発者・Claude Code ともに，エディタやファイル編集ツールなどVivadoを介さない手段で書き換えてはならない**．

| ディレクトリ | 理由 | Git管理 |
|-------------|------|---------|
| `mypc.srcs/sources_1/bd/` | Vivadoブロックダイアグラム（GUI操作で変更） | 対象 |
| `mypc.srcs/sources_1/imports/` | Vivado自動生成トップラッパー | 対象 |
| `mypc.srcs/utils_1/` | Vivadoデザインチェックポイント (.dcp) | 対象外 |

チェックアウトしたディレクトリでプロジェクトを開き合成するにはブロックダイアグラムとトップラッパーの実体が要るため，これらはGit管理下に置く．デザインチェックポイントは合成・実装をやり直せば再生成されるためGit管理外とし，削除してもよい．

### 編集対象ディレクトリ

| ディレクトリ | 内容 |
|-------------|------|
| `mypc.srcs/sources_1/new/` | カスタムCPUのHDLソース(主な作業対象)．このうちROMの内容(`rom_sv.sv`)は手で編集せず，「QosmosのROMの生成」の手順で生成する |
| `mypc.srcs/constrs_1/new/` | PYNQ-Z2ボードのピン制約 (top.xdc) |
| `mypc.srcs/boot/` | BOOT.BINを作るスクリプトと，BOOT.BINの構成(`boot.bif`)．手順は「実機での起動方法」の「BOOT.BINの作成」を参照 |
| `mypc.srcs/pn/` | ROM上で動くQosmosのPynesisソース(`.pn`)．入口は`qosmos.pn`で，「QosmosのROMの生成」の手順で`rom_sv.sv`へ変換する．`lib/`は，Qosmosの実行ファイルのソースが取り込むライブラリ(ROMには入らない．番号などの取り決めを置くファイルはシェルも取り込む) |
| `mypc.srcs/sim_1/` | テストベンチ(`new/`)と，それをコンパイル・実行するスクリプト．実行方法は「CPUのシミュレーション」を参照 |
