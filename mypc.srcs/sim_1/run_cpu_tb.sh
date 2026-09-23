#!/bin/bash
# CPUのテストベンチ(new/cpu_tb.sv)をVivado付属のシミュレータでコンパイル・実行する．
# Vivadoのbinディレクトリ(xvlog・xelab・xsim)にPATHが通っている必要がある．Git Bash・WSL・Linuxのいずれからも実行できる．
# 引数にguiを指定すると，実行せずに波形ビューア付きのシミュレータを開く．
# 全テストケースが合格すれば終了コード0，不合格があれば0以外で終わる．
# Vivadoプロジェクト(mypc.xpr)のシミュレーション機能を使わないのは，ブロックダイアグラムの
# シミュレーション用出力生成物まで生成・コンパイルすることになり，テストベンチに不要な時間がかかるため
set -e

sim_dir=$(cd "$(dirname "$0")" && pwd)             # このスクリプトのあるディレクトリ
src_dir="$sim_dir/../sources_1/new"                # CPU本体のソース
work_dir="$sim_dir/../../mypc.sim/cpu_tb"          # コンパイル結果・ログの出力先(Git管理外)

# WSLからWindows版のVivadoを使っているか．Windows版に同梱のシェルスクリプトはWSLではLinux版の
# 実行ファイルを探して失敗するため，WSLではバッチファイルをcmd.exe経由で呼ぶ
is_wsl=false
if grep -q -i microsoft /proc/version 2>/dev/null && [ -f "$(command -v xvlog).bat" ]; then
    is_wsl=true
fi

# Vivado付属のコマンドに渡すパス．WSLではWindows形式へ変換する
native_path() {
    if $is_wsl; then
        wslpath -w "$1"
    else
        echo "$1"
    fi
}

# Vivado付属のコマンドを実行する．WSLでは同名のバッチファイルをcmd.exe経由で呼ぶ
run_tool() {
    if $is_wsl; then
        cmd.exe /c "$(wslpath -w "$(command -v "$1").bat")" "${@:2}"
    else
        "$@"
    fi
}

# 出力先へ移動する(コンパイル結果・ログはカレントディレクトリに出力される)
mkdir -p "$work_dir"
cd "$work_dir"

# テストベンチが使うCPU本体のソースと，テストベンチ自身をコンパイルする
run_tool xvlog -sv -i "$(native_path "$src_dir")" \
    "$(native_path "$src_dir/decoder_sv.sv")" \
    "$(native_path "$src_dir/alu_sv.sv")" \
    "$(native_path "$src_dir/cpu_sv.sv")" \
    "$(native_path "$src_dir/ram_sv.sv")" \
    "$(native_path "$sim_dir/new/tb_rom.sv")" \
    "$(native_path "$sim_dir/new/tb_divider.sv")" \
    "$(native_path "$sim_dir/new/cpu_tb.sv")"

# テストベンチをトップとして組み立てる
run_tool xelab cpu_tb -debug typical -s cpu_tb

# guiを指定された場合は，波形ビューア付きのシミュレータを開いて終わる
if [ "$1" = "gui" ]; then
    run_tool xsim cpu_tb -gui
    exit 0
fi

# 全テストケースを実行する
run_tool xsim cpu_tb -runall

# xsimは$fatalで終わっても終了コードが0になるため，ログにエラーが出ていれば失敗として終わる
if grep -q -E "^(Error|Fatal):" xsim.log; then
    exit 1
fi
