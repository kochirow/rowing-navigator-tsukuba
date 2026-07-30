# 衝突警告 安全レビュー報告 2026-07-25

対象: 本日の変更(航路中心線予測・DCPA近接・符号付き距離・低速時領域拡張・
空間索引・Kalman非等方ノイズ・起動ゲート撤去)と、標準セットの警告経路一式。

## 1. サマリ

| 重大度 | 件数 | 状態 |
| --- | --- | --- |
| S1(警告漏れに直結) | 2 | **いずれも本レビュー中に修正済み・回帰テスト追加済み** |
| S2(条件が重なると寄与) | 4 | 3件修正、1件は未採用の相談事項として保留 |
| S3(品質・保守性) | 2 | 記録のみ |

S1はいずれも**今回の変更で新たに作り込んだもの**であり、レビューで検出・修正した。

## 2. チェックリスト結果

| 項目 | 判定 | 根拠 |
| --- | --- | --- |
| A1 しきい値の等号の向き | OK | `continuous_collision_service.dart:192` `>= / <=` + `_epsilon` で境界を含む側。`collision_risk_evaluator_service.dart:900` `entryDistance <= ownStoppingDistance` |
| A2 浮動小数点・NaN | OK | `_usableBoat` (`collision_risk_evaluator_service.dart:217`) が NaN/範囲外を正規化。`ChannelPathPredictor.predict` は `isFinite` を全入力に適用 (`channel_path_predictor.dart:66-97`) |
| A3 先読みの最終評価点 | OK | 連続SATは区間 `[0, horizon]` を閉区間で解く。点サンプリングを使わないため取りこぼしが構造的に存在しない (`continuous_collision_service.dart:230-244`) |
| A4 単位・型 | OK | 中心線は m 単位のローカル平面で計算し、境界のみ度へ戻す (`channel_centerline.dart:114-122`) |
| B1 すり抜け(tunneling) | OK | 連続SATのため時間刻みが無い。多区間化しても `startTime += duration` で時間軸が連続 (`channel_path_predictor.dart:202`) |
| B2 先読み範囲 | OK | `staticHorizon = max(warningTime, stoppingTime)`。8+ @5m/s の停止時間8.15s < 10s |
| B3 外挿の上下限 | OK | `extrapolateToNow` が `boatStaleTimeoutSeconds` で頭打ち。基準は `serverUpdatedAt` 優先 |
| B4 停止判定と漂流 | OK(改善) | 低速時に領域を横へ拡張(下記E2)。近接注意も `directionUnknown` で残る |
| C1 不正ポリゴン | OK | `_validatePoints`/`_triangulate` が例外→距離ベースへフォールバック (`collision_risk_evaluator_service.dart:806-825`) |
| C2 三角分割・SATの例外 | OK | catch節は「脅威なし」ではなく保守的判定へ退避 |
| C3 平面近似の用途 | OK | 交差判定と距離計算を分離。中心線・索引とも局所ENUで統一 |
| C4 辺上・頂点上の内外判定 | OK | `_epsilon` を含む側に倒す (`continuous_collision_service.dart:423`) |
| D1 fail-silent | OK | 新規経路も同様。`loadChannelCenterline` は失敗時 null → 直線予測へ縮退(判定は従来どおり継続) |
| D2 ログのみ継続する経路 | OK | 新規は3箇所(中心線導出失敗・checksum不一致・version不一致)。いずれも警告能力を落とさない |
| D3 受信値の異常 | OK | `OtherBoatTrackStore` / `RemoteBoatMessage.tryParse` 既存経路のまま |
| E1 GPS誤差 vs マージン | **要確認** | 排他-船体差は全艇種で横1.5m/縦1.5m。想定GPS誤差5〜15mに対し不足(既知・相談事項1) |
| E2 方位/速度欠損 | **NG→修正** | S1-1 参照 |
| E3 マージン合計の検算 | **NG(保留)** | 相談事項1。外挿30mに対し pair guard 上限1.5m |
| F1 送信間隔 < 幽霊艇TTL | OK | 10s < 30s。検算は §5 |
| F2 幽霊艇フィルタ | OK | `_LostBoatContext` が警告中の艇を保持 |
| F3 受信間隔の不確実性 | **NG(保留)** | 相談事項1と同一 |
| F4 リスク時の送信短縮 | OK | 前回評価結果を使うため最大1周期(2s)のラグ。変更なし |
| G1 レベル→提示の写像 | OK | `safety_orchestrator.dart:469-488`。lv1は無音(相談事項2) |
| G2 抑制が脅威を隠さないか | OK | 安定停止の抑制は固定障害物のみ。2m接近で再武装 |
| G3 primaryThreat の一致 | OK | `raiseLevel` の `sameLevelButMoreUrgent` で入替 |
| H1 停止距離式 | OK | §5 に検算 |
| H2 刻み vs 最小寸法 | 該当なし | 連続判定のため刻みが存在しない(旧 `evalIntervalDistance` は削除済み) |
| H3 近接距離 vs GPS誤差 | **NG(保留)** | プリセットは実効0m。相談事項1 |
| H4 warningTime の妥当性 | OK | 10s。8+ の停止時間8.15sを上回る |

## 3. 所見一覧

### S1-1: 低速時に広げた領域が broad-phase で捨てられる(修正済み)

- 該当箇所: `collision_risk_evaluator_service.dart` の `myDomainRadius` / `otherDomainRadius`
- 再現シナリオ: 8+ が 0.1 m/s で回頭中。実効排他半径は 14.72m だが、到達距離の見積りに
  生パラメータの 12.60m を使っていたため、**中心から 12.6〜14.7m の帯にある橋脚・流木を
  評価前に捨てる**。速度が小さいほど `speed × horizon` 項が消え、この差が支配的になる。
- 影響: 低速時の横方向拡張(=この変更の目的そのもの)が、最も効くべき場面で無効化される。
- 修正: `ShipDomainService.effectiveExclusiveRadius()` を追加し、broad-phase・空間索引・
  外接円フォールバックのすべてを実効値ベースに統一。
- 回帰テスト: `collision_risk_channel_test.dart`「低速で広げた領域が触れる区域を broad-phase で捨てない」

### S1-2: 危険区域の内部にいるとき近接注意が立たなくなる(修正済み)

- 該当箇所: `findProximityThreats` に入れた `if (cautionDistance + guard <= 0) continue;`
- 再現シナリオ: プリセット区域は `proximityCautionDistanceMeters == 0`。従来は
  `minDistanceToPolygonMeters` が内部で 0 を返し `veryClose`(2m以内)で脅威が立っていた。
  早期continueを入れたことで、**岸の危険区域に入り込んだ状態でも近接注意が出なくなった**。
- 影響: 掃引判定が幾何例外で失敗した場合の予備が失われる(多重防御の1枚が抜ける)。
- 修正: 早期continueを撤去。空間索引による絞り込みだけを残した(性能改善はそのまま維持)。
- 回帰テスト: `collision_risk_channel_test.dart`「危険区域の内部にいる間は近接注意も必ず立つ」

### S2-1: 近接すれ違い判定が楽観側の隙間を使っていた(修正済み)

- `separationMeters` に GPS帯なしの値だけを使っていた。GPS帯込みのほうが隙間は狭く出るため、
  両者の `min` を採るよう修正。影響は lv1(表示のみ)に限られる。

### S2-2: プリセット危険区域のGPSガード帯と近接注意が実効0(保留)

- 相談事項1として未採用。**本レビュー時点で未解決の最大のFN要因**。
  外挿30mに対し pair guard 1.5m、静的区域の guard 0m。

### S2-3: 区間境界での領域回転による微小な隙間(許容)

- 多区間掃引では区間境界で領域が Δθ だけ回転する。6分割・半径80mのカーブで Δθ ≒ 3°、
  8+ の艇長半分11.45m に対し取りこぼし幅は `11.45·sin(1.5°) ≒ 0.30m`。
  同条件の曲率マージンは 0.3〜3.0m でこれを上回るため覆われる。直線では Δθ=0 で隙間も0。

### S2-4: Kalman不確実性の下限緩和(要実地検証)

- `uncertaintyMeters` が報告accuracyの 0.5倍(下限3m)まで下がり得るようになった。
  安全マージンは `boat.accuracy` 由来なので、収束時にマージンが約半分になる。
- 対処方針: **修正しない。** 相談事項での明示的な採用事項であり、下限比率と絶対下限で
  有界化してある。`TrackPoint` に `gnssAccuracyMeters` と `estimateUncertaintyMeters` を
  両方記録済みなので、実走2本で「どちらが実誤差に近いか」を検証してから定数を確定する。

### S3-1: `distanceMeters` の符号付き化に伴う順位付けの縮退

- `AlertCandidateComparator._distanceMillimeters` が負値を0へclampするため、
  区域内部の複数警告は距離で順位が付かず `internalPriority` へ落ちる。実害なし。

### S3-2: `positionUncertaintyMeters` が本番未使用のまま

- 経過時間ベースのマージン関数がテストからしか呼ばれていない。相談事項1で採用されれば解消。

## 4. 境界シナリオのトレース記録

1. **微速0.3m/sで横向き漂流** — `headingIsReliable` false → 領域を横へ 1x:3.21m / 8+:4.00m 拡張。
   実効半径 1x 9.53m。掃引距離は 0.3×10=3m と小さいので、拡張分が支配的に効く。
   S1-1修正後は broad-phase もこの半径を使う。→ 検知される。
2. **8+ 5.5m/s と 1x 0.6m/s の交差** — 相対速度6.1m/s。連続SATに時間刻みが無いため
   すり抜けは構造的に起きない。horizon = max(10, 8.15)=10s、相対到達61m。
   `relativeReach = (5.5+0.6)×10 + 12.6 + 7.18 + 1.5 = 82.3m` で broad-phase を通過。
3. **並走2艇・双方GPS誤差10m** — 排他-船体差は横1.5m、pair guard = √(10²+10²)×0.125 = 1.77 → 上限1.5m。
   合計3.0m < 想定相対誤差。**警告漏れが起こり得る(S2-2・相談事項1で保留)**。
4. **停止艇へ背後から接近** — 停止艇は送信10s間隔。受信側の予測TTLは6sなので、
   停止艇は外挿対象から外れる時間帯がある。ただし停止艇は動かないため最終位置がそのまま有効で、
   表示TTL 30s で保持され、接近側の掃引対象に残る。→ 検知される。
5. **相手端末の時計±5秒ずれ** — 鮮度・外挿とも `serverUpdatedAt` 基準
   (`collision_risk_evaluator_service.dart:248`)。端末時計のずれは影響しない。
   自艇側も `EstimatorClock` がドリフト2秒超で処理時刻へ退避する。
6. **頂点2点・自己交差のポリゴン** — `evaluateStaticContinuousIntersection` は3点未満で
   `invalid_static_geometry` を返し、`assessRisk` の catch が距離ベースへ退避。
   `signedDistanceToPolygonMeters` は2点で線分距離、1点で点距離を返し無限大にしない。
7. **警告距離ちょうどの障害物** — 連続SATが `[0, horizon]` の閉区間を解くため、
   `entryTime == horizon` ちょうどでも `clippedEnter <= clippedExit` が成立し検知される。

## 5. 設定値の検算記録

### H1 停止距離 [m]

| 艇種 | 2 m/s | 3.5 m/s | 5 m/s | 停止時間@5m/s |
| --- | --- | --- | --- | --- |
| 1x | 13.9 | 24.3 | 34.8 | 6.95 s |
| 2x | 13.2 | 23.1 | 33.0 | 6.60 s |
| 4x | 13.4 | 23.4 | 33.4 | 6.68 s |
| 8+ | 16.3 | 28.5 | 40.8 | 8.15 s |

いずれも `warningTime = 10s` 以内に収まる。式は速度の1次式であり、
高速域で過小評価となる可能性は残る(実測での検証が望ましい・S3扱い)。

### E1 排他領域と船体領域の差 [m]

全艇種で 横1.50 / 縦1.50。**想定GPS誤差5〜15mを大きく下回る。**

### 低速時の実効半径 [m]

| 艇種 | 横拡張/側 | 実効半径 | 生半径 |
| --- | --- | --- | --- |
| 1x | 3.21 | 9.53 | 7.18 |
| 2x | 3.84 | 10.70 | 8.07 |
| 4x | 4.00 | 11.81 | 9.35 |
| 8+ | 4.00 | 14.72 | 12.60 |

### F1 鮮度の階層

`freshUntil 3s < boatPredictionTimeoutSeconds 6s < boatStaleTimeoutSeconds 30s`
かつ `sendIntervalStoppedSec 10s < 30s`。成立。

### H3 近接注意 vs GPS誤差

プリセット全310枚で `cautionDistance = 0.0`、`staticGpsInflatePerSideMeters = 0.0`。
**区域外での近接注意は発生しない。** 相談事項1で未採用のため保留。

## 6. テスト実行結果

- `dart analyze lib test` — No issues found
  (`flutter analyze` は日本語パスでLSPがクラッシュするため使用不可。CIで担保)
- `flutter test` — **386件 全パス**(3回連続で安定)
- 本レビューで追加した回帰テスト
  - 「低速で広げた領域が触れる区域を broad-phase で捨てない」(S1-1)
  - 「危険区域の内部にいる間は近接注意も必ず立つ」(S1-2)

## 7. 完了条件の充足確認

| 条件 | 充足 |
| --- | --- |
| 1. A1〜H4 全項目に判定と根拠 | ✅ |
| 2. 境界シナリオ7件の数値トレース | ✅ |
| 3. NG項目に再現シナリオ・重大度・修正案 | ✅ |
| 4. チェックリストHの数値検算 | ✅ |
| 5. テスト実行結果 | ✅ 386件全パス |
| 6. 報告書の保存 | ✅ 本ファイル |
| 7. S1所見が0件、または対処方針明記 | ✅ S1 2件とも修正済み・回帰テスト済み |

## 8. 追記(同日・相談事項の採用後)

相談事項1・2が採用され、E1/E3/F3/H3 のNGはすべて解消した。追加の実装と、
その過程で見つけた所見を以下に記録する。

### 解消したNG

| 項目 | 対処 |
| --- | --- |
| E1 / E3 / F3 | 他艇マージンに外挿齢比例項を追加(0.4 m/s、上限2.5m)。accuracy項も係数0.20・上限2.5mへ |
| H3 | 近接注意をkind別に(岸3 / 橋5 / 中州5 / 流木6 m)。プリセットのGPS帯0特例を撤去し片側1.5mへ |

### S1-3: `boundingRadius` が `s > h` の艇種で外接半径を過小評価(修正済み)

- 該当箇所: `ship_domain_service.dart` の `boundingRadius`
- 内容: 六角形の頂点は「船首・船尾方向の h/2」と「側方の sqrt((s/2)²+(w/2)²)」の
  2種類。8+ は低速拡張後に `s`(26.88m)が `h`(22.9m)を上回るため、
  従来の `0.5·sqrt(h²+w²)` = 14.72m が実際の最遠頂点 16.32m を**1.6m下回っていた**。
- 影響: S1-1と同じ経路(broad-phase の到達距離見積り)で、触れる障害物を捨てる。
- 修正: 3つの候補値の最大を返す。従来値も下限に残し、円フォールバックの
  安全余裕をこの修正で減らさないようにした。
- 回帰テスト: 「到達距離の見積りが領域の実寸を下回らない(全艇種・低速/巡航)」で
  全艇種 × 低速/巡航について「見積り半径 ≥ 実際の最遠頂点距離」を固定。

### 提示ポリシーの変更(相談事項2)

音を内部レベルではなく到達時間だけで決めるようにした。
G1・G2 の判定は再確認済み(下表)。

| 確認 | 結果 |
| --- | --- |
| 予測地平(10秒)より先で音が鳴らないか | OK。バンド上限を `defaultWarningTimeSeconds` と一致させた |
| 不確実な候補が連続音にならないか | OK。confidence < 1.0 で1バンド降格 |
| 橋の通過で連続音が鳴らないか | OK。`bandCappedCategories` で単発1回に据え置き(従来と同じ) |
| 岸沿い走行で近接注意が鳴らないか | OK。`audibleProximityCategories` に岸を含めない |
| 停止中に断続音が鳴り続けないか | OK。安定停止・低速時は `repeating` を落とす |
| 4秒以内に現れた脅威が確定待ちで遅れないか | OK。`immediateActionDeadline` を2→4秒 |

### 残る既知の課題(今回は対象外)

- **橋脚と桁下が同じ `bridge` kind のまま。** 橋脚に向かうコースでも単発音1回に
  留まる。`bridgeSpan` / `bridgePier` の分離が必要(データ側の対応も要る)。
- **停止距離式が速度の1次式。** 高速域で過小評価の可能性。実測での検証が望ましい。
- **Kalman不確実性の下限緩和は実地検証待ち。** `gnssAccuracyMeters` と
  `estimateUncertaintyMeters` を両方記録済みなので、実走2本で確定する。
- 相談事項1の数値は**現地検証で確定させる前提**。`alerts.jsonl` の
  `category` 別件数と `separationMeters` 分布で過剰警告の増減を測ること。

### 再検証

- `dart analyze lib test` — No issues found
- `flutter test` — **397件 全パス**(2回連続)
