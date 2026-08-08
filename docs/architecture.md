# ハードウェア実装の内部構成

Vivadoプロジェクトのモジュール階層・I/O配線・ファイル一覧を説明する。CPU命令フォーマット・レジスタ番地などのISA仕様そのものは`../specification/isa.md`・`../specification/register.md`を参照(このファイルには記載しない)。

## 階層構造

```
top_wrapper.v (Vivado自動生成)
└── top.bd (ブロックダイアグラム)
    ├── Processing System 7 (ARM Cortex-A9)
    ├── AXI DMA  ← stdin/stdout の転送(AXI Stream)
    ├── 除算器IP(div_gen_0)  ← alu_sv.svのDIV命令が使用
    ├── 7セグメント表示IP(seven_seg_0)  ← number出力を駆動
    └── mother_board IP
        └── mother_board.v (Verilogラッパー)
            └── mother_board_sv.sv
                ├── cpu_sv.sv
                │   ├── decorder_sv.sv
                │   └── alu_sv.sv
                ├── ram_sv.sv
                └── rom_sv.sv
```

## I/Oインターフェース

- **stdin/stdout**: AXI Stream インターフェース経由でPS(ARM)と通信(AXI DMA)
- **btn/sw/led**: GPIO直結
- **rgb_led**: RGB LED
- **number**: 7セグメントディスプレイへの8ビット出力(デバッグ用．`seven_seg_0`IPを駆動)
- **除算(divisor/dividend/dout)**: `div_gen_0`(除算器IP)とのAXI Streamインターフェース。DIV命令の実行に使用

## メモリ

- **ROM** (`rom_sv.sv`): プログラムメモリ (最大固定命令数)
- **RAM** (`ram_sv.sv`): データメモリ、IDLE→EXECUTE→RESPONSEの状態遷移

## ヘッダーファイル（インターフェース定義）

| ファイル | 内容 |
|----------|------|
| `machine.svh` | 命令フォーマット・タイプ・関数コード定数 |
| `alu.svh` | ALU関数定義、レジスタアドレス定数、`is_readable()`/`is_writable()` |
| `decorder.svh` | `command_if` インターフェース (master/slave modport) |
| `ram.svh` | `ram_read_if`, `ram_write_if` インターフェース |
| `rom.svh` | `rom_read_if` インターフェース |
| `register.svh` | SP/FLG/PCなどの特殊レジスタアドレス定数 |
| `util.svh` | `bool_t` 型定義 |

## svファイル・Verilogラッパー

| ファイル | 内容 |
|----------|------|
| `mother_board_sv.sv` | マザーボード部分．CPUやメインメモリなど各パーツを格納する |
| `ram_sv.sv` | メインメモリ |
| `cpu_sv.sv` | CPU．命令のデコードと実行を担当する |
| `rom_sv.sv` | 読み込み専用メモリ．実行するプログラムを格納する |
| `decorder_sv.sv` | 機械語の命令を分解する |
| `alu_sv.sv` | 機械語で指定された命令を実行する．レジスタを持つ |
| `mother_board.v` | `mother_board_sv.sv`を呼び出すVerilogラッパー(Vivado IPとの互換性のため) |
| `seven_seg.v` | 7セグメントディスプレイ制御 |
