# ハードウェアの情報(XSAファイル)から，Xilinxが提供するFSBLのソースを生成してビルドする
# 前提: export_xsa.tclでmypc.boot/top_wrapper.xsaを書き出してあること
# 実行の仕方: xsctで，リポジトリ直下をカレントディレクトリとして実行する(make_fsbl.batから呼ばれる)
# 作成するもの: mypc.boot/fsbl/executable.elf(FSBL)と，そのソース・ビルドの中間ファイル

# ハードウェアの情報を読み込む
hsi::open_hw_design mypc.boot/top_wrapper.xsa
# PSのCPUの1つ目のコアで，OS(Linuxなど)を介さず直接動くFSBLを生成してビルドする
hsi::generate_app -hw [hsi::current_hw_design] -os standalone -proc ps7_cortexa9_0 -app zynq_fsbl -compile -sw fsbl -dir mypc.boot/fsbl
# ハードウェアの情報を閉じる
hsi::close_hw_design [hsi::current_hw_design]
