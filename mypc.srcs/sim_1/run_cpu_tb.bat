@echo off
rem CPUのテストベンチ(new\cpu_tb.sv)をVivado付属のシミュレータでコンパイル・実行する．
rem Vivadoのbinディレクトリ(xvlog・xelab・xsim)にPATHが通っている必要がある．
rem 引数にguiを指定すると，実行せずに波形ビューア付きのシミュレータを開く．
rem 全テストケースが合格すれば終了コード0，不合格があれば0以外で終わる．
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

rem 現在のコードページを控える(シミュレータの実行後に戻すため)
for /f "tokens=2 delims=:" %%c in ('chcp') do set /a saved_codepage=%%c

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

rem 全テストケースを実行する．実行中だけ，子のコマンドプロンプトの中でコードページをUTF-8へ切り替えて戻す．
rem 切り替えるのは，テストベンチが結果をUTF-8で出力し，そのままでは画面で文字化けするため．
rem 子の中で戻すのは，このファイルを読み進める間にUTF-8へ切り替わっていると，日本語を含む行を誤って読むため．
cmd /c "chcp 65001 >nul & call xsim cpu_tb -runall & chcp %saved_codepage% >nul"

rem 最後まで実行され($finishに達し)，ログにエラーが出ていなければ合格とする．
rem xsimの終了コードを使わないのは，$fatalで終わっても0になるため．
rem また，上の子のコマンドプロンプトからは受け取れないため．
findstr /b /c:"$finish called" xsim.log >nul
if errorlevel 1 goto finish
findstr /b /c:"Error:" /c:"Fatal:" xsim.log >nul
if errorlevel 1 set "exit_code=0"
goto finish

:gui
call xsim cpu_tb -gui
set "exit_code=0"

:finish
rem 元のディレクトリへ戻して終わる
popd
endlocal & exit /b %exit_code%
