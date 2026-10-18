@echo off
rem BOOT.BINに入れるFSBLを作る．
rem FSBL(First Stage Boot Loader)は，電源を入れたときにPS(ARM)が最初に実行するプログラムで，PSを初期化してからビットストリームをPLへ書き込む．
rem 最初の1回と，ブロックダイアグラムでPS(processing_system7_0)の設定を変えたときに実行する．
rem FSBLはPSの設定だけに依存するため，自作HDLやROMの内容を変えただけなら作り直さなくてよい．
rem 実行前に，VivadoでGenerate Bitstreamまで済ませておく(実装結果からハードウェアの情報を書き出すため)．
rem VivadoとVitisのbinディレクトリ(vivado・xsct)にPATHが通っている必要がある．
rem 作ったFSBLは，リポジトリ直下のmypc.boot\fsbl\executable.elf(Git管理外)に出力される．
rem ダブルクリックで実行した場合は，結果を読めるよう，ウィンドウが閉じる前にキー入力を待つ．
rem
rem このファイルはShift_JIS・改行CRLFで保存する．
rem コマンドプロンプトは，このファイルを実行中のコードページ(日本語環境では932)で読むため．
rem UTF-8で保存したり改行をLFだけにしたりすると，日本語を含む行の区切りを誤って読む．
rem その結果，コメントの途中をコマンドとして実行してしまう．
setlocal

set "boot_dir=%~dp0"                   & rem このファイルのあるディレクトリ(末尾に\が付く)
set "root_dir=%boot_dir%..\.."         & rem リポジトリ直下
set "out_dir=%root_dir%\mypc.boot"     & rem 出力先(Git管理外)
set "exit_code=1"                      & rem このファイルの終了コード．FSBLを作り終えるまでは失敗としておく
set "own_window=0"                     & rem このファイルを実行するためだけに開いたウィンドウか(1なら終了前にキー入力を待つ)

rem ダブルクリックで実行すると，このファイルのパスを含むコマンドラインでコマンドプロンプトが起動される．
rem 開いているコマンドプロンプトから実行した場合は，コマンドラインにこのファイルのパスが含まれない．
rem findをフルパスで呼ぶのは，PATHの並びによっては同名の別のコマンドが呼ばれるため．
echo %cmdcmdline% | "%SystemRoot%\System32\find.exe" /i "%~0" >nul
if not errorlevel 1 set "own_window=1"

rem 出力先のディレクトリが無ければ作る
if not exist "%out_dir%" mkdir "%out_dir%"

rem リポジトリ直下へ移動する(Tclのスクリプトは，リポジトリ直下からの相対パスでファイルを扱う)
pushd "%root_dir%"

rem 実装結果から，ハードウェアの情報(PSの設定を含むXSAファイル)を書き出す
call vivado -mode batch -nojournal -nolog -source "%boot_dir%export_xsa.tcl"
if errorlevel 1 goto finish

rem 書き出したハードウェアの情報からFSBLを生成し，ビルドする
call xsct "%boot_dir%make_fsbl.tcl"
if errorlevel 1 goto finish
set "exit_code=0"

:finish
rem 元のディレクトリへ戻す
popd

rem このファイルのために開いたウィンドウなら，閉じる前に結果を読めるようキー入力を待つ
if "%own_window%"=="1" pause

endlocal & exit /b %exit_code%
