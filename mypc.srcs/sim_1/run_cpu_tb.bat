@echo off
rem CPUのテストベンチ(new\cpu_tb.sv)をVivado付属のシミュレータでコンパイル・実行する．
rem Vivadoのbinディレクトリ(xvlog・xelab・xsim)にPATHが通っている必要がある．
rem 引数にguiを指定すると，実行せずに波形ビューア付きのシミュレータを開く．
rem 全テストケースが合格すれば終了コード0，不合格があれば0以外で終わる．
rem ダブルクリックで実行した場合は，結果を読めるよう，ウィンドウが閉じる前にキー入力を待つ．
rem
rem Vivadoプロジェクト(mypc.xpr)のシミュレーション機能は使わない．
rem 使うとブロックダイアグラムのシミュレーション用出力生成物まで生成・コンパイルすることになり，時間がかかるため．
rem
rem このファイルはShift_JIS・改行CRLFで保存する．
rem コマンドプロンプトは，このファイルを実行中のコードページ(日本語環境では932)で読むため．
rem UTF-8で保存したり改行をLFだけにしたりすると，日本語を含む行の区切りを誤って読む．
rem その結果，コメントの途中をコマンドとして実行してしまう．
setlocal

set "sim_dir=%~dp0"                                  & rem このファイルのあるディレクトリ(末尾に\が付く)
set "src_dir=%sim_dir%..\sources_1\new"              & rem CPU本体のソース
set "work_dir=%sim_dir%..\..\mypc.sim\cpu_tb"        & rem コンパイル結果・ログの出力先(Git管理外)
set "exit_code=1"                                    & rem このファイルの終了コード．合格を確かめるまでは失敗としておく
set "own_window=0"                                   & rem このファイルを実行するためだけに開いたウィンドウか(1なら終了前にキー入力を待つ)

rem ダブルクリックで実行すると，このファイルのパスを含むコマンドラインでコマンドプロンプトが起動される．
rem 開いているコマンドプロンプトから実行した場合は，コマンドラインにこのファイルのパスが含まれない．
rem findをフルパスで呼ぶのは，PATHの並びによっては同名の別のコマンドが呼ばれるため．
echo %cmdcmdline% | "%SystemRoot%\System32\find.exe" /i "%~0" >nul
if not errorlevel 1 set "own_window=1"

rem 出力先へ移動する(コンパイル結果・ログはカレントディレクトリに出力される)
if not exist "%work_dir%" mkdir "%work_dir%"
pushd "%work_dir%"

rem テストベンチが使うCPU本体のソースと，テストベンチ自身をコンパイルする
call xvlog -sv -i "%src_dir%" ^
    "%src_dir%\decoder_sv.sv" ^
    "%src_dir%\alu_sv.sv" ^
    "%src_dir%\cpu_sv.sv" ^
    "%src_dir%\ram_sv.sv" ^
    "%sim_dir%new\tb_rom.sv" ^
    "%sim_dir%new\tb_divider.sv" ^
    "%sim_dir%new\cpu_tb.sv"
if errorlevel 1 goto finish

rem テストベンチをトップとして組み立てる
call xelab cpu_tb -debug typical -s cpu_tb
if errorlevel 1 goto finish

rem guiを指定された場合は，波形ビューア付きのシミュレータを開いて終わる
if /i "%~1"=="gui" goto gui

rem 前回のログを消す(実行に失敗したとき，前回のログで合否を判定しないため)
if exist xsim.log del xsim.log

rem 全テストケースを実行する．画面への出力は捨て，終了後にログを表示する．
rem テストベンチは結果をUTF-8で出力し，そのまま画面に出すとコードページ932では文字化けするため．
rem コードページをUTF-8へ切り替えて表示しないのは，元の932へ戻すときに画面が消去されるため．
echo テストを実行しています...
call xsim cpu_tb -runall >nul

rem ログをUTF-8として読み，画面のコードページに合わせて表示する
powershell -NoProfile -Command "Get-Content -Encoding UTF8 -Path xsim.log"

rem 最後まで実行され($finishに達し)，ログにエラーが出ていなければ合格とする．
rem xsimの終了コードを使わないのは，$fatalで終わっても0になるため．
findstr /b /c:"$finish called" xsim.log >nul
if errorlevel 1 goto finish
findstr /b /c:"Error:" /c:"Fatal:" xsim.log >nul
if errorlevel 1 set "exit_code=0"
goto finish

:gui
call xsim cpu_tb -gui
set "exit_code=0"

:finish
rem 元のディレクトリへ戻す
popd

rem このファイルのために開いたウィンドウなら，閉じる前に結果を読めるようキー入力を待つ
if "%own_window%"=="1" pause

endlocal & exit /b %exit_code%
