# qurge

ハードウェアQurge(CPU・メモリ・ROMなどからなるハードウェア全体)のVivadoプロジェクトと，ROM上で動く自作OS Qosmosのソースを置く．QosmosはPynesisで書き，シェルやファイルシステムなどを持つ．

このリポジトリは，PYNQ-Z2(Zynq-7000)上に実装する自作CPUと，それを動かすソフトウェア群(アセンブラ・コンパイラ・OS)からなる自作パソコンのプロジェクトPynthesisの一部である．

## 文書

ハードウェアとQosmosの仕様・開発の手順と，実機の準備の手順は，仕様書のリポジトリ`specification`に置く．

- [qurge/](https://github.com/tt-and-tk/specification/tree/master/qurge): ハードウェアの仕様と開発の手順
- [qosmos/](https://github.com/tt-and-tk/specification/tree/master/qosmos): Qosmosの仕様と開発の手順
- [operation.md](https://github.com/tt-and-tk/specification/blob/master/operation.md): 実機の準備・接続・起動のやり直し・実行ファイルを置く方法の手順
- [terms.md](https://github.com/tt-and-tk/specification/blob/master/terms.md): Pynthesisの構成要素の名称と，Pynthesis全体で共通に使う用語
- [README.md](https://github.com/tt-and-tk/specification/blob/master/README.md): 仕様書全体の構成
