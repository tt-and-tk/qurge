# AGENTS.md

## このリポジトリについて

GitHubリポジトリ名: `tt-and-tk/qurge`．

CPU・メモリ・ROM等のハードウェア全体のVivadoプロジェクトと，ROM上で動く自作OS Qosmosのソースを置く．

## Pynthesisの中での位置

このリポジトリは，PYNQ-Z2(Zynq-7000)上に実装する自作CPUと，それを動かすソフトウェア群(アセンブラ・コンパイラ・OS)からなる自作パソコンのプロジェクトPynthesisの一部である．Pynthesisは以下の独立したGitHubリポジトリで構成される．

| リポジトリ(GitHub) | ディレクトリ(`pc/`配下) | 役割 |
|:-|:-|:-|
| `specification` | `specification/` | Pynthesisの仕様と，各リポジトリのソースを変更する開発の手順のドキュメント(唯一の一次情報源) |
| `pyntaxis` | `assembler/` | 自作アセンブリ言語Pyntaxis(`.pt`) → SystemVerilog ROM(`.sv`)，または自作OS Qosmosの実行ファイルへのアセンブラ |
| `pynesis` | `compiler/` | 自作プログラミング言語Pynesis(`.pn`) → アセンブリ言語Pyntaxisへのコンパイラ．`pyntaxis`のソースファイルを取り込んで使用し，`.sv`または実行ファイルまで一貫変換も可能 |
| `qurge`(本リポジトリ) | `mypc/` | CPU・メモリ・ROM等のハードウェア全体のVivadoプロジェクトと，ROM上で動く自作OS Qosmos(シェルやファイルシステムなど．Pynesisで記述) |
| `for-pynthesis-skills` | `for-pynthesis-skills/` | 上記各リポジトリで共有するissue起票・対応支援スキルとコーディング規約を提供する．特定のリポジトリが主担当と判断できない，全リポジトリに影響するissueの起票先(受け皿)でもある |

```
入力(.pn) → [pynesisのコンパイラ] → アセンブリ(.pt) → [pyntaxisのアセンブラ] → SystemVerilog ROM(.sv) → [Vivado] → PYNQ-Z2上のハードウェア(qurge，本リポジトリ)
```

## 作業する前に読む文書

作業する前に，`specification`の次の文書を読む．

| 文書 | 内容 |
|:-|:-|
| `qurge/develop/index.md` | ハードウェアのソースの構成，編集の範囲，合成・シミュレーション・BOOT.BINの作成の手順 |
| `qosmos/develop/index.md` | Qosmos(`mypc.srcs/pn/`)のソースの構成と，ROMの生成の手順 |
| `README.md` | 仕様書全体の構成 |
