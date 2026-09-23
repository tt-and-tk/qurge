@echo off
rem CPUのテストベンチ(new\cpu_tb.sv)をVivado付属のシミュレータでコンパイル・実行する．
rem Vivadoのbinディレクトリ(xvlog・xelab・xsim)にPATHが通っている必要がある．
rem 引数にguiを指定すると，実行せずに波形ビューア付きのシミュレータを開く．
rem 全テストケースが合格すれば終了コード0，不合格があれば0以外で終わる．
rem Vivadoプロジェクト(mypc.xpr)のシミュレーション機能を使わないのは，ブロックダイアグラムの
rem シミュレーション用出力生成物まで生成・コンパイルすることになり，テストベンチに不要な時間がかかるため．
rem このファイルはShift_JIS・改行CRLFで保存する．コマンドプロンプトはこのファイルを実行中のコードページ
rem (日本語環境では932)で読むため，UTF-8で保存したり改行をLFだけにしたりすると，日本語を含む行の区切りを
rem 誤って読み，コメントの途中をコマンドとして実行してしまう
setlocal

set "sim_dir=%~dp0"                                  & rem このファイルのあるディレクトリ(末尾に\が付く)
set "src_dir=%sim_dir%..\sources_1\new"              & rem CPU本体のソース
set "work_dir=%sim_dir%..\..\mypc.sim\cpu_tb"        & rem コンパイル結果・ログの出力先(Git管理外)
set "exit_code=1"                                    & rem このファイルの終了コード．合格を確かめるまでは失敗としておく

rem 現在のコードページを控える(シミュレータの実行中だけUTF-8へ切り替えた後に戻すため)
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

rem 全テストケースを実行する．テストベンチは結果をUTF-8で出力するため，画面で文字化けしないよう実行中だけ
rem コードページをUTF-8へ切り替える．切り替えと戻しは子のコマンドプロンプトの中で行う(このファイルを
rem 読み進める間にUTF-8へ切り替わっていると，Shift_JISの日本語を含む行を誤って読むため)
cmd /c "chcp 65001 >nul & call xsim cpu_tb -runall & chcp %saved_codepage% >nul"

rem 最後まで実行され($finishに達し)，ログにエラーが出ていなければ合格とする．xsimの終了コードは，
rem $fatalで終わっても0になるうえ，上の子のコマンドプロンプトからは受け取れないため使わない
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
