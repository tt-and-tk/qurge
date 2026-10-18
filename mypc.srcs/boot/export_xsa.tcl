# FSBLの生成に使うハードウェアの情報(PSの設定を含むXSAファイル)を書き出す
# 前提: VivadoでGenerate Bitstreamまで済ませ，配置配線を終えた設計(impl_1の結果)があること
# 実行の仕方: Vivadoのバッチモードで，リポジトリ直下をカレントディレクトリとして実行する(make_fsbl.batから呼ばれる)
# 作成するもの: mypc.boot/top_wrapper.xsa

# プロジェクトを読み取り専用で開く(開いた場所の絶対パスなどをmypc.xprへ書き戻さないため)
open_project -read_only mypc.xpr
# 配置配線を終えた設計を開く
open_run impl_1
# ハードウェアの情報を書き出す(FSBLにはビットストリームを入れないため，含めない)
write_hw_platform -fixed -force -file mypc.boot/top_wrapper.xsa
# プロジェクトを閉じる
close_project
