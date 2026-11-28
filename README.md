# qurge

このリポジトリは，ハードウェアQurgeのVivadoプロジェクトと，自作OS Qosmosのソースを置く．Qurgeは，CPUを含むハードウェア全体である．Qosmosは，QurgeのROM上で動くOSであり，自作プログラミング言語Pynesisで書く．

このリポジトリは，PYNQ-Z2(Zynq-7000)上に実装する自作CPUと，それを動かすソフトウェア群(アセンブラ・コンパイラ・OS)からなる自作パソコンのプロジェクトPynthesisの一部である．

## 文書

文書は，仕様書のリポジトリ`specification`に置く．このリポジトリにかかわる文書は次のとおり．

- [README.md](https://github.com/tt-and-tk/specification/blob/master/README.md): 仕様書全体の構成
- [terms.md](https://github.com/tt-and-tk/specification/blob/master/terms.md): Pynthesisの構成要素の名称と，Pynthesis全体で共通に使う用語
- [qurge/](https://github.com/tt-and-tk/specification/tree/master/qurge): Qurgeの仕様と開発の手順
- [qosmos/](https://github.com/tt-and-tk/specification/tree/master/qosmos): Qosmosの仕様と開発の手順
- [operation.md](https://github.com/tt-and-tk/specification/blob/master/operation.md): 実機を動かすための手順
