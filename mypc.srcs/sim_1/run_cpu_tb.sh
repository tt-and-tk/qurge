#!/bin/bash
# CPUのテストベンチ(new/cpu_tb.sv)をVivado付属のシミュレータでコンパイル・実行する．
# Vivadoのbinディレクトリ(xvlog・xelab・xsim)にPATHが通っている必要がある．
# 引数にguiを指定すると，実行せずに波形ビューア付きのシミュレータを開く．
# Vivadoプロジェクト(mypc.xpr)のシミュレーション機能を使わないのは，ブロックダイアグラムの
# シミュレーション用出力生成物まで生成・コンパイルすることになり，テストベンチに不要な時間がかかるため
set -e

sim_dir=$(cd "$(dirname "$0")" && pwd)             # このスクリプトのあるディレクトリ
src_dir="$sim_dir/../sources_1/new"                # CPU本体のソース
work_dir="$sim_dir/../../mypc.sim/cpu_tb"          # コンパイル結果・ログの出力先(Git管理外)

mkdir -p "$work_dir"
cd "$work_dir"

# テストベンチが使うCPU本体のソースと，テストベンチ自身をコンパイルする
xvlog -sv -i "$src_dir" \
    "$src_dir/decoder_sv.sv" \
    "$src_dir/alu_sv.sv" \
    "$src_dir/cpu_sv.sv" \
    "$src_dir/ram_sv.sv" \
    "$sim_dir/new/tb_rom.sv" \
    "$sim_dir/new/tb_divider.sv" \
    "$sim_dir/new/cpu_tb.sv"

# テストベンチをトップとして組み立てる
xelab cpu_tb -debug typical -s cpu_tb

if [ "$1" = "gui" ]; then
    xsim cpu_tb -gui
    exit 0
fi

# 全テストケースを実行する．xsimは$fatalで終わっても終了コードが0になるため，ログに
# エラーが出ていれば失敗として0以外の終了コードで終わる
xsim cpu_tb -runall
if grep -q -E "^(Error|Fatal):" xsim.log; then
    exit 1
fi
