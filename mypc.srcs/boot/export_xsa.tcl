# 実装結果から，FSBLの生成に使うハードウェアの情報(PSの設定を含むXSAファイル)を書き出す
# Vivadoのバッチモードで，リポジトリ直下をカレントディレクトリとして実行する(make_fsbl.batから呼ばれる)

# プロジェクトを読み取り専用で開く(開いた場所の絶対パスなどをmypc.xprへ書き戻さないため)
open_project -read_only mypc.xpr
# 実装結果を開く
open_run impl_1
# ハードウェアの情報を書き出す(FSBLにはビットストリームを入れないため，含めない)
write_hw_platform -fixed -force -file mypc.boot/top_wrapper.xsa
# プロジェクトを閉じる
close_project
