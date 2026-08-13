# Replay Lab の使い方

このツール群は個人航跡をリポジトリへ追加せず、端末から書き出した診断ZIPの
`track.csv` を使って測位・警告の変更を比較するためのものです。

アプリのリポジトリ直下で、次を実行します。

```bash
flutter test tool/replay_estimator.dart \
  --dart-define=LOG_DIR=/診断ZIPを展開したフォルダ \
  --dart-define=OUT=/tmp/replay-estimator.json
```

S0（生GNSS）とS2（alpha-beta）は `raw_lat` / `raw_lng` から計算します。
S1は推定器を再実行せず、実機が実際に出した`filtered_*`を参照します。これにより、
Stage 2では実機S1と新規S2を同じログ上で比較できます。先頭60秒は初期条件の影響を
避けるため、数値指標から除外してください。

同一艇へ2台を搭載したD/Eログでは、次のようにペア指標を出します。

```bash
flutter test tool/replay_estimator.dart \
  --dart-define=LOG_DIR=/Dの診断フォルダ \
  --dart-define=PAIR_LOG_DIR=/Eの診断フォルダ \
  --dart-define=OUT=/tmp/pair.json
```

実機ログが作業ツリーに無いCIでは、合成データの単体・メタモルフィック試験だけが
実行されます。実機の配信頻度、電池、音量、水上での位置精度はこの手順では確認できません。
