# ハードウェアの情報(XSAファイル)から，Xilinxが提供するFSBLのソースを生成してビルドする
# xsctで，リポジトリ直下をカレントディレクトリとして実行する(make_fsbl.batから呼ばれる)

# ハードウェアの情報を読み込む
hsi::open_hw_design mypc.boot/top_wrapper.xsa
# PSのCPUの1つ目のコアで動くFSBLを，OSを使わない構成で生成してビルドする(できたFSBLはmypc.boot/fsbl/executable.elf)
hsi::generate_app -hw [hsi::current_hw_design] -os standalone -proc ps7_cortexa9_0 -app zynq_fsbl -compile -sw fsbl -dir mypc.boot/fsbl
# ハードウェアの情報を閉じる
hsi::close_hw_design [hsi::current_hw_design]
