# P8: use_navigator

実施日: 2026-07-27
対象: `lib/hooks/use_navigator.dart`（3,189行）
主観点: F（状態と並行性）、D（不変条件1）、G（縮退運転）

## 0. カバレッジの明示（重要）

**このパスは全行読了ではない。** 3,189行に対して、次の方針で**対象を絞った検証**を行った。

- 不変条件1（評価が送信間隔と独立に毎秒実行される）に関わる経路
- 単一writer（`SafetySnapshot`）の維持
- ストリーム購読・タイマーのライフサイクル
- P3・P5 から持ち越した具体的な問い（方位の保持・不確実性の消費先・外挿の絞り込み）
- system fault 候補の構築（P6・P7 から参照）

**未読の領域**: セッション記録・GPX・チーム連携・地図描画連動・診断イベントの詳細など、
安全経路の外側にある部分。**P15 の前に本パスを再訪して全行を読む必要がある。**
残りは P11（周辺機能）・P13（UI）と重複するため、そちらの結果を見てから範囲を確定するのが効率的。

## 1. 検証して正しかったこと

### 1.1 不変条件1: リスク評価は送信間隔と独立に毎秒実行される

- GPS ストリームの各測位で `assessRisk`（`:1954`）が呼ばれる。送信は別経路（`positionPublisher`）。
- `startGpsWatchdog`（`:1394-1412`）が **1秒周期の `Timer.periodic`** を持ち、
  測位が来なくても評価と fault 判定が回る。
- **watchdog の tick が例外を投げても止まらない**（`:1399-1410` の try/catch）。
  コメントが「`Timer.periodic` はcallbackが例外を投げても次回以降も発火するため
  警告が永久停止することはないが、原因調査のために必ず記録する」と明記 ✓
  診断の記録失敗でも watchdog を止めない二重の防御（`:1407`）✓

### 1.2 単一writer の維持

- `SafetySnapshotGate`（`safety_snapshot.dart:197-208`）が古い・重複したリビジョンを弾く。
- `:1597` `if (!safetySnapshotGate.value.accept(result.snapshot)) return;` が唯一の適用点。
- `SafetySnapshot` 自体が構築時に不変条件を検証する
  （`primaryAlertId` が `activeAlerts` に実在すること・`revision >= 0`）✓
- 航行世代のガードが **15箇所**（`isCurrentNavigation(generation)`）。
  `await` を挟むたびに世代を確認しており、古い航行の結果で新しい状態を上書きしない ✓
- 新しい航行では orchestrator と gate を**同時に**作り直す（`:2414-2418`）✓

### 1.3 P3 からの持ち越し1: 停止時の方位は呼び出し側が保持している

推定器は速度がほぼ0のとき方位が実質ノイズになる（P3 で指摘）。
`buildMyBoat`（`:1664-1717`）を読んで解決した。

```dart
var heading_ = preHeading.value ?? 0.0;   // 前回の方位を初期値にする
...
if (estimate != null && speed_ >= stoppedSpeedThreshold && ...) {
  measuredHeading = estimate.headingDegrees;   // 0.5m/s 以上のときだけ採用
}
...
if (measuredHeading != null) { heading_ = _blendHeading(...); }
preHeading.value = heading_;                   // 保持
```

- **推定器の方位を採用するのは `speed_ >= stoppedSpeedThreshold`(0.5m/s) のときだけ** ✓
- 採用しない場合は `preHeading` の値がそのまま残る = CLAUDE.md の「最後の進行方位を保持する」と一致 ✓
- 生 GNSS の heading を使う経路も同じしきい値でガードされている（`:1705`）✓
- 加えて、**推定器由来のときは追加の平滑化を掛けない**（`:1684-1688`）。
  コメントが「1Hzの一次遅れが二重にかかり、定常旋回で 10°/s の旋回で約10°、
  5m/s・10秒先の予測で終端 8.7m の遅れになる」と、捨てた選択肢の影響まで数値で書いている ✓

**指摘なし。CLAUDE.md の記述は正確だった。**

### 1.4 P3 からの持ち越し2: `uncertaintyMeters` の消費先

`:1749` — `final accuracy_ = estimate?.uncertaintyMeters ?? (生の accuracy);`

推定器の 95% 不確実性が `Boat.accuracy` になり、そこから
`_gpsAccuracyMeters`（`collision_risk_evaluator_service.dart:309`）を経て
静的GPS帯・ペアGPS帯の両方へ流れる ✓

床が二重に入っている（`minimumUncertaintyFractionOfReported` = 報告値の0.5倍、
`uncertaintyFloorMeters` = 3m の大きいほう）ことがコメントに明記されている（`:1744-1748`）✓

**ただし**: フィルタ収束時は報告 accuracy の**半分**まで下がりうる。報告 15m なら 7.5m。
これは 2026-07-25 の安全レビュー S2-4「Kalman不確実性の下限緩和(要実地検証)」として
**既に未決事項になっている**。本レビューでも実地検証なしには判断できないため、未決のまま引き継ぐ。

### 1.5 P5 からの持ち越し: 外挿の絞り込み

`:1939-1946` — `extrapolateToNow` を呼ぶ前に
`now.difference(updatedAt).inMilliseconds < boatPredictionTimeoutSeconds * 1000` で絞っている。

`extrapolateToNow` の内部上限は 30秒だが、**唯一の呼び出し側が 6秒で事前に絞る**ため
実効は仕様どおり 6秒 ✓（食い違いは安全レビュー S3-1 として記録済み）

コメントも「受信ストリームが止まった場合に古い艇情報で評価し続けないよう、
評価直前にも鮮度フィルタを適用する（受信時のフィルタと二重の防御）」と意図を書いている ✓

### 1.6 縮退運転と原則6

- `unknownBoatIds`（`:1565-1574`）— 6〜30秒の艇を「不明」として保持し、
  消えたことを表示と fault の根拠にする。**黙って消さない** ✓
- `boatDataQualityById`（`:1583-1595`）— 艇ごとに good / degraded / unusable を付ける。
  鮮度階層（3秒 / 6秒）と一致 ✓
- system fault の既定が「音なし」（`:1420-1422`）。
  コメントが「既定を音ありにしていた頃、新しい fault を足すたびに読み上げが増えていった」と、
  なぜ既定を反転したのかを書いている ✓
- Wakelock の取得失敗で航行開始を止めない（`:2422-2425` の try/timeout）= 不変条件5 ✓

## 2. 指摘

### P8-01（S3）`SafetySnapshotGate` が「同一世代・別セッションID」を永久に拒否する

- `safety_snapshot.dart:187-193`:

```dart
bool supersedes(SafetySnapshot other) {
  if (sessionGeneration != other.sessionGeneration) {
    return sessionGeneration > other.sessionGeneration;
  }
  if (sessionId != other.sessionId) return false;   // ← ここ
  return revision > other.revision;
}
```

- `sessionGeneration` が同じで `sessionId` だけが変わると、**新しいスナップショットは永久に拒否される**。
  `SafetySnapshotGate.accept` が false を返し続け、`:1597` で毎回 return するため、
  **画面表示・音声指令・`runMode` が最後に受理したスナップショットで凍結する**。
  評価パイプラインは回り続けるので、外からは「警告が固まった」ようにしか見えない。
- **現状は到達不能。** `:2414-2418` で orchestrator（`sessionId` と `sessionGeneration` を持つ）と
  gate が必ず同時に作り直されるため、`sessionId` が変わるときは `sessionGeneration` も変わり、
  かつ gate も新品になる。
- しかし「一致しないなら拒否」という選択は、**失敗モードが最も重い側**（安全表示の凍結）に倒れている。
  同じ状況で「新しいほうを受理する」設計にしておけば、将来の変更で凍結は起きない。
- 重大度 S3 は到達不能であることによる。**到達した場合の影響は S1 相当。**

### P8-02（S3・P1-02 の再掲）幾何例外の診断が release で残らない

P1・P5 で挙げた `collision_risk_evaluator_service.dart:646` の無条件 `debugPrint` は、
`use_navigator` が持つ診断イベント基盤（`appendRuntimeDiagnostic` / `events.jsonl`）を使っていない。

`log_config.dart:83` の仮説 H3_WARNING_TIMING_AND_POSITION は
「過剰警告・警告漏れ・位置ずれがないか」を実機ログから検証することを目的にしているが、
**幾何例外が起きていた事実はログに残らない**ため、この仮説の検証に穴がある。

`use_navigator` 側には `gps_watchdog_tick_error` のように例外を診断へ落とす前例がある（`:1404`）ので、
同じ扱いへ揃えられる。

## 3. 次パスへの持ち越し

| # | 問い | 宛先 |
| --- | --- | --- |
| 1 | **本パスの未読領域の全行読了** | P15 の前に再訪 |
| 2 | Kalman 不確実性の下限緩和（報告 accuracy の 0.5 倍まで下がる）の実地妥当性 | 実機検証・利用者判断 |
| 3 | セッション記録・診断イベントの詳細 | P11 |
| 4 | 地図描画との連動（不変条件6: 描画は安全判定用の拡張を反映しない） | P13 |

## 4. テスト

| 対象 | テスト |
| --- | --- |
| `use_navigator` | **専用テストなし**。`test/widget_test.dart`（736行）が一部を通す |
| `SafetySnapshot` / `SafetySnapshotGate` | `test/models/safety_snapshot_test.dart` ✓ |

2026-07-26 の安全レビュー S3-1 が指摘した「S1-1 / S1-2 はフック層のためユニットテストで
固定できていない」という構造的な問題が残っている。**3,189行の中核フックに専用テストが無い。**
純Dartへ切り出せる部分（鮮度分類・system fault 候補の構築・`buildMyBoat` の方位保持）を
services 層へ移せば固定できる。

## 4.5 P13/P14 やり直しで判明した接続点（2026-07-27 追記）

`home_map_screen` を全行読了した結果、`use_navigator` が公開する値の**消費側**に
2件の S2 が見つかった。いずれも `use_navigator` 自身の欠陥ではないが、
提供する値の性質が消費側の前提と合っていない。

| # | 内容 | 影響 |
| --- | --- | --- |
| 1 | `myBoat.value.speed` に NaN ガードが無い。`buildMyBoat:1680` は `estimate?.speedMetersPerSecond ?? rawSpeed` をそのまま入れる。評価側は `_usableBoat` が複製時に潰すが、**UI へ渡る `myBoat` は素のまま** | `home_map_screen.dart:1030` の `500 ~/ speed` が例外を投げ、航行画面全体が描画不能になる（[P13-02](P13_P14_UI・設定画面.md)） |
| 2 | `activeWarnings` の `urgency` は 7秒/10秒の境界で頻繁に上下する | `safety_banner` の `_PulseFrame` が Ticker を二重生成し、警告チップが消える（[P13-01](P13_P14_UI・設定画面.md)）。修正は banner 側 |

**1 は `buildMyBoat` 側で潰すのが筋**である。`Boat` は位置共有・記録・UI の全経路へ流れるため、
入口で有限性を保証するほうが、消費側それぞれで防ぐより確実で、
このコードベースの他の箇所（`_usableBoat` / `_gpsAccuracyMeters`）の流儀とも揃う。

## 5. 総評

**検証した範囲では、状態管理の規律が高い。** 世代ガード15箇所、gate による単一writer、
watchdog の二重 try/catch、Wakelock 失敗で開始を止めない縮退。
いずれも「機能を止めない」（原則1）と「単一writer」を意識して書かれている。

`buildMyBoat` の方位保持は、CLAUDE.md の記述が正確であることを確認できた。
捨てた選択肢（二重平滑化）の影響まで数値でコメントに残っている。

**ただし本パスは全行読了ではない**（第0章）。指摘の少なさは、
カバレッジの狭さと切り分けられていない。P15 の前に再訪すること。

指摘: S3 が2件（うち P8-01 は到達不能だが影響は S1 相当）+ 上記4.5 の接続点1件（S2・`buildMyBoat` の NaN ガード）。
テスト不足1件（最大の未固定領域）。

**未読領域は依然として残っている**（セッション記録・診断イベント・チーム連携の詳細）。
本追記は P13/P14 のやり直しで判明した接続点のみを反映したもので、全行読了ではない。
