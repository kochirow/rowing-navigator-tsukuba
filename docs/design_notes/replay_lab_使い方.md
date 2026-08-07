# Replay Lab の使い方

このツール群は個人航跡をリポジトリへ追加せず、端末から書き出した診断ZIPの
`track.csv` を使って測位・警告の変更を比較するためのものです。

アプリのリポジトリ直下で、次を実行します。

```bash
flutter test tool/replay_estimator.dart \
  --dart-define=LOG_DIR=/診断ZIPを展開したフォルダ \
  --dart-define=OUT=/tmp/replay-estimator.json
```

`raw_lat` / `raw_lng` を入力にS0（生GNSS）とS1（現行Kalman）を動かします。
`filtered_*` は比較用であり入力には使いません。出力JSONを確認し、推定器の
入力取り違えを避けてください。

同一艇へ2台を搭載したD/Eログでは、次のようにペア指標を出します。

```bash
flutter test tool/replay_estimator.dart \
  --dart-define=LOG_DIR=/Dの診断フォルダ \
  --dart-define=PAIR_LOG_DIR=/Eの診断フォルダ \
  --dart-define=OUT=/tmp/pair.json
```

実機ログが作業ツリーに無いCIでは、合成データの単体・メタモルフィック試験だけが
実行されます。実機の配信頻度、電池、音量、水上での位置精度はこの手順では確認できません。
