# CLAUDE.md

このファイルは、Claude(および他のAIアシスタント)がこのリポジトリで作業する際のガイドです。

## プロジェクト概要

Rowing Navigator は、ローイング(ボート競技)の安全航行を支援する Flutter 製アプリ(iOS/Android)。
茨城県土浦市の**桜川**でのボート練習向けに調整されている。

運用前提(詳細と根拠は [docs/DESIGN_PRINCIPLES.md](docs/DESIGN_PRINCIPLES.md) 第1章):
川幅40〜50m・狭所35m、**右側通行の片側1レーンですれ違う**、カーブ間隔は最短200m・最長700m、
同時に出る艇は2〜12、**コーチ艇はいない**、休憩は橋の下または航路の端。

**水域によって前提が違う。** 上は桜川本流の前提であり、**霞ヶ浦(開水面)では成立しない**
(DESIGN_PRINCIPLES 1.2b)。霞ヶ浦では対岸が数百m先で、レーンは「推奨経路」であって
「越えない取り決め」ではないため、レーンの被覆が落ちる(航跡の17〜44%がレーン外)。
ただしそれは**警告漏れであって誤発報ではない**ので、逆走判定は有効のまま残す。
岸も北岸しか定義していない。
**新しい水域を足すときは、先に 1.2c へ前提を書いてから設定値を決めること。**

- 自艇・他艇の位置/針路/速度を Realtime Database 経由でリアルタイム共有
- 静的危険区域(橋脚・浅瀬・岸など)と艇を Google Maps 上に表示
- 衝突リスクを段階評価(lv0〜lv3)し、音声+画面バナーで警告

## 設計原則(最上位規範)

**設定値を変える・機能を足す・警告の出し方を変える前に、必ず
[docs/DESIGN_PRINCIPLES.md](docs/DESIGN_PRINCIPLES.md) を読むこと。**
運用前提(川幅・右側通行・片側1レーン・カーブ間隔・艇数・休憩場所)と、
そこから導かれる設計原則・設定値の根拠がそこにある。判断はすべてそこから導く。

このファイル(CLAUDE.md)は AI 作業ガイドであり、設計原則の要約と実装の地図である。
両者が食い違ったら DESIGN_PRINCIPLES.md が優先する。

要約:

1. **機能を止めない。** 欠けているときは縮退運転 + 明示的な警告で継続する。
2. **使い方は使い手が決める。** 「正しい使い方」を強制しない。
3. **その時々で出せる最大限の価値を出す。**
4. **過剰警告は安全機能の破壊である。** 正常な運用で鳴る警告は不具合として扱う。
5. **「どれだけまずいか」と「どれだけ切迫しているか」を混ぜない。**
6. **データ欠損は安全の根拠にならない。**
7. **設定値には前提を書く。**

## 安全方針(最重要)

- **本アプリは衝突回避を保証しない。安全確認の補助である。**
- 警告漏れ(false negative)を避けることを優先しつつ、過剰警告で使われなくなることも避ける。
  **形骸化した警告は警告漏れと同じ**であり、どちらも安全機能の喪失として扱う。
- **機能を止めないこと。** 危険な状況を防ぐ目的であっても、航行開始をブロックしたり
  警告経路を無効化したりしてはいけない。能力が欠けているときは「縮退運転 + 明示的な警告」で
  継続する(`SafetyRunMode.runningDegraded` / `unavailable` と system fault 警告)。
- **正常な運用で鳴る警告は、安全側に倒した設計ではなく不具合である。**
  何が「正常な運用」かは DESIGN_PRINCIPLES.md 第1章が定義する
  (岸から数mを走る・橋の下で休む・対向艇と十数mですれ違う、はいずれも正常)。
- **画面の常時点灯(Wakelock)は「航行中だけ」である。**
  漕手は航行中に端末を触れない(両手がオールで塞がり、端末は艇に固定されている)ので、
  画面が消えたら復帰させる手段がない。**監視者は陸上で端末を操作できる**ため、
  監視中は常時点灯しない(電池を使うだけで得るものがない)。
  DESIGN_PRINCIPLES.md 1.3・1.4 が根拠。
  **`WakelockPlus` を呼ぶのは `lib/hooks/use_screen_wakelock.dart` だけにすること。**
  持ち主を分けると、片方の後片付けがもう片方の点灯を打ち消す。
- 警告ロジックを変更する場合は、必ず `test/` の単体テストを更新すること。
  特に**実データ(`assets/data/sakuragawa_obstacles.json`)を使う統合テスト**は、
  設定値の意図と実効値の乖離を検出する唯一の手段なので必ず維持する。

## ビルド・テスト

```bash
flutter pub get
dart analyze lib test tool   # ← flutter analyze は使わない(下記)
flutter test
flutter run
```

> **`flutter analyze` はこの作業パスでは必ずクラッシュする。**
> Dart analysis server の LSP チャネルが、URLエンコードされた日本語パス
> (`漕艇部` / `桜川プロジェクト`)でヘッダのバイト長とUTF-16長を取り違えるため。
> ローカルでは `dart analyze lib test tool` を使い、`flutter analyze` は
> ASCIIパスで動く GitHub Actions(`.github/workflows/ci.yml`)で担保する。

> **`tool` を必ず入れること。** `tool/replay_alerts.dart` /
> `tool/replay_field_log.dart` は `lib/` のモデルを直接呼ぶため、安全経路の
> クラスから引数を1つ削るだけで壊れる。`lib test` だけで解析すると
> ローカルは緑のまま CI の `flutter analyze`(プロジェクト全体)だけが落ちる。
> 実際にこれで2回落ちている(`1724d33`、および 2026-08-03 の
> `insideSupportedCoverage` 削除)。

起動には Firebase 設定と Google Maps API キーが必要(README参照)。

## アーキテクチャ

レイヤー: Presentation(screens/features) → Hooks(hooks/) → Services(services/) → API(api/) → Models(models/)

### 中核(安全経路)

| 場所 | 役割 |
| ---- | ---- |
| `lib/hooks/use_navigator.dart` | 全体の中核。GPSストリーム→品質選別→Kalman推定→リスク評価→提示→記録→適応送信 |
| `lib/services/gps_position_filter.dart` | 測位の妥当性選別(座標・精度・時刻・速度飛び) |
| `lib/services/gps_health_monitor.dart` | 単発ノイズと本当の途絶を分ける good/degraded/unusable 判定 |
| `lib/services/robust_position_estimator.dart` | 4状態ロバストKalman。**surge/sway非等方プロセスノイズ**・soft/hard gate・再捕捉 |
| `lib/services/estimator_clock.dart` | KalmanのdtをGNSS測位時刻基準にする単調時計(純Dart) |
| `lib/services/channel_centerline.dart` | 航路中心線と曲線座標(along/cross)の相互変換(純Dart) |
| `lib/services/channel_path_predictor.dart` | 予測経路を直線または川なりの折れ線として生成(純Dart) |
| `lib/services/continuous_collision_service.dart` | 等速直線掃引の連続SAT + ear-clipping三角分割(純Dart) |
| `lib/services/collision_risk_evaluator_service.dart` | リスク評価の本体。静的区域・他艇・近接・区域進入を統合 |
| `lib/services/static_obstacle_index.dart` | 固定危険区域の空間索引(グリッドハッシュ・純Dart) |
| `lib/services/ship_domain_service.dart` | 船体領域/排他領域の生成。低速時は横方向を有界に拡張 |
| `lib/services/safety_orchestrator.dart` | 全detectorの候補を1つのFSMへ集約する単一writer。提示ポリシー |
| `lib/services/alert_state_machine.dart` | 警告のライフサイクル(candidate→alerting→clearing→safe) |
| `lib/hooks/use_alert.dart` | 警告音の再生と、OS割込みからの自動復旧。**再生要求は直列キューで1本ずつ実行する**(並行実行すると、段階が上がる瞬間に古い要求が新しい音を止める)。2本目のプレイヤー(`playCue`)は現在未使用(読み上げを重ねると両方聞き取れないため) |
| `lib/services/ashore_detector.dart` | 陸上判定(純Dart)。岸の基準線の陸側にいるかで判定し、**音だけ**を止める |
| `lib/services/receive_fault_debouncer.dart` | 能力劣化を system fault へ昇格させるヒステリシス(純Dart)。受信劣化は両側15秒、GPS途絶・評価停止は確定10秒・解除0秒の非対称 |

### 周辺

| 場所 | 役割 |
| ---- | ---- |
| `lib/hooks/use_coach_watch.dart` | コーチ(監視)機能。航跡・艇一覧・異常検知。異常は初検知時刻を保持し、新規・`anomalyReannounceSec` 経過で音とバナーを出す。**監視中はWakelockを保持しない**(下記) |
| `lib/hooks/use_stroke_rate.dart` | 加速度センサからのSPM計測。Kalmanのノイズ設計にも渡す |
| `lib/services/stroke_speed_trace.dart` | 艇速変化グラフ用の連続波形(純Dart)。**表示専用**。1サンプルO(1)のリング。**航行中の画面には出さない**(2026-08-13に廃止。監視端末専用) |
| `lib/services/stroke_trace_history.dart` | 監視端末が受けた1ストロークずつを連結する(純Dart) |
| `lib/hooks/use_stroke_trace_sharing.dart` | 1ストロークの波形を監視端末へ共有。安全経路の外側。**波形を見る口はここ(監視端末の `stroke_trace_sheet.dart`)だけ**で、艇側は送るだけ |
| `lib/features/home_map/widgets/nav_status_card.dart` | 航行中の計器カード(ペース・レート・経過時間・距離)。**艇速変化グラフは置かない**(2026-08-13に廃止。漕ぎながら波形を読む場面が無く、上部の一等地を主計器と取り合っていた)。理由と寸法の根拠は同ファイル冒頭 |
| `lib/services/message_service.dart` | 位置共有。RTDB(既定)/Firestoreをフラグで切替。onDisconnect対応 |
| `lib/services/other_boat_track_store.dart` | 受信メッセージの検証・順序付け・鮮度管理(純Dart) |
| `lib/services/send_policy.dart` | 適応送信の間隔決定 |
| `lib/services/session_analyzer_service.dart` | 練習ログ解析(距離・スプリット・ピース検出)。純Dart |
| `lib/services/session_store_service.dart` | セッションの端末内JSON保存 |
| `lib/services/gpx_export_service.dart` | GPX/CSV出力 |
| `lib/services/preset_obstacle_service.dart` | 同梱プリセットの読み込み・検証・中心線導出 |
| `lib/theme/map_layer_spec.dart` | 地図の層(中央線＝白い破線／危険区域＝塗り／予測＝線)の配色と `zIndex` を集約。**実線＝実在するもの、破線＝越えない取り決め。** 航路は中央線1本だけを描き、レーンの外側の辺は描かない(往路・復路の帯を廃止した経緯も同ファイル) |
| `lib/services/channel_cross_section.dart` | 「中央線のどちら側を、どれだけ離れて走っているか」の表示用モデル(純Dart)。左右は**漕手の体の左右**(=画面の左右)で持つ。レーンの左右は右側通行の規則ではなくレーン形状から決める(水域により向きが違う)。**表示専用・警告にしない** |
| `lib/theme/boat_palette.dart` | 艇の表示色。航行中は自艇＝赤・他艇＝濃い青みグレーで**艇ごとに色分けしない**(色の暗記を要求しない・赤の特別扱いを守る)。監視中だけ `assignBoatTrackColors` が艇IDから識別色を決め、航跡・艇印・艇一覧で同じ色を使う。**表示専用**(純Dartに近い割当ロジック) |
| `lib/services/swept_outline_service.dart` | 予測掃引の外形(凸包)を1枚にまとめる(純Dart)。**表示専用で判定には使わない** |
| `lib/services/static_obstacle_service.dart` | 臨時危険区域の CRUD(Firestore) |
| `lib/config/` | 全設定値(コメント付き)。調整はここ |

**リアルタイムTTSは実装されていない。** 警告は事前生成の音声アセットのみ。
ただし**中身は読み上げ音声**である(VOICEVOX / ずんだもん)。
「他艇に注意」「橋に注意」のように**何に当たりそうかを言葉で告げる**。
種類ごとに別の音声を割り当てること(同じ音を使い回すと振り向く先を選べない)。

音声アセットを追加・差し替える手順:

1. WAV マスターを `tool/audio_src/` へ置く(`assets/audio/` を直接編集しない)
2. `./tool/normalize_warning_audio.sh` で `assets/audio/*.mp3` を生成する
3. `./tool/check_warning_audio.sh` で音圧が揃っていることを確認する(CIでも検証)

**音圧を揃えるのは音質ではなく安全の問題である。** 端末のボリュームは1つしか
ないので、ファイル間で音圧が違うと「読み上げが聞こえる音量にするとアラート音が
耳をつんざく」状態になり、どちらかが必ず犠牲になる。実測(2026-07-27)では
最大 23.3 LU の差があった。目標は -10 LUFS、ファイル間の差は 2.5 LU 以内。

各ファイルは語句を1回読み上げるだけの 0.5〜1.4 秒で、切迫度は**鳴らし方**
(連続ループ / 3秒間隔 / 5秒間隔)で表す。緊急版のような別録りは持たない。
末尾 0.15 秒の無音がループ時の語句どうしの間隔になる。

## 衝突警告の仕組み

1. GPSストリームから測位を受け、`GpsPositionFilter` で明らかに使えないものを落とす
2. `RobustPositionEstimator` が位置・速度・方位を推定(dtはGNSS測位時刻基準)
3. **適応送信**: 停止中10秒/他艇なし5秒/近傍・リスク時2秒でRTDBへ送信。
   受信側は推測航法(`extrapolateToNow`)で最大6秒まで現在位置を外挿。
   **他艇を受信できない間は2秒を維持する**(`receiveUnavailable`)。
   「近傍に他艇がいる」は自艇が受信できた艇からしか作れないため、受信だけが
   落ちた艇が10秒送信を続けると予測TTL(6秒)を超え、他艇の評価から
   10秒周期のうち4秒間消える
4. **予測経路の生成**: 航路中心線があれば「川沿いに進む成分」と「岸へ寄る成分」を
   曲線座標で分けて積分し、川なりの折れ線を作る。中心線が無ければ等速直線1区間
5. **連続掃引(SAT)**: 予測経路の各区間で、自艇の排他領域を掃引して
   他艇の船体領域/危険区域と重なる時刻区間を求める(点サンプリングではない)
6. 他艇は**相対速度**で掃引する。同期時刻で重なるかを見るため、
   航跡が地理的に交差しても到達時刻が違えば衝突としない
7. 内部レベル判定(**表示色・優先順位・ログ専用**。音の鳴り方には使わない):
   - 自艇の停止距離内で確実な衝突 → lv3 / 不確実(GPS帯込みでのみ重なる) → lv2
   - 警告距離内で確実 → lv2 / 不確実 → lv1
   - 相手側の停止距離内 → lv2
   - すれ違い間隔(DCPA)が `nearMissSeparationMeters` 以下 → lv1
   - 危険区域への近接(接近中・極近・方位不明のいずれか) → lv1
   - カーブ/逆走の区域進入 → lv1(区域進入イベント)
   - 橋は通過する区域なので lv2 が上限
8. `SafetyOrchestrator` が提示を決め、`AlertStateMachine` が確定/解除を管理
9. `SafetySnapshot` を単一writerとして UI と音声へ配る

## 提示ポリシー(音の鳴り方)

**2つの軸を分離している。混ぜないこと。**

- **内部レベル lv0〜3** = どれだけまずいか(停止距離内か・確度)。
  表示色・優先順位・ログにだけ使う。
- **緊急度バンド** = どれだけ切迫しているか(到達までの時間だけ)。音を決める。

| バンド | 条件(TTE = 到達までの秒数) | 音 |
| --- | --- | --- |
| `imminent` | TTE ≤ 本警告時間（既定10s）、または現在すでに重複 | **連続音** |
| `approaching` | 本警告時間 < TTE ≤ 予告時間（既定13s） | **3秒間隔の断続音** |
| `monitoring` | 到達予測なし(近接注意・DCPA) | 表示のみ |

- 予告時間の既定13秒は予測地平(`advanceWarningLeadSeconds`)と一致させている。
  「予測が届かない先では音が鳴らない」が不変条件。
- **確度が低い候補は1バンド下げる。** 連続音の信頼性を守るため。該当するのは2つ。
  - GPS帯込みでのみ重なる(`gps_guard_entry`)
  - 低速時の方位不確かさで広げた領域でのみ重なる(`heading_uncertainty_entry`)。
    折り返しの回頭中は領域が横へ最大4m広がる。他艇は安定停止の無音化対象外なので、
    ここを確実扱いにすると回頭のたびに通過艇へ連続音が鳴る。検知は残して音だけ下げる。
- **橋は連続音まで上げない**(`bandCappedCategories`)。毎回くぐって通過するため。
- 近接注意で鳴らすのは流木・中州だけ(`audibleProximityCategories`)。
  岸は川幅40mでは常に近く、鳴らすと確実に形骸化する。
  鳴らす場合も接近エピソードごとに1回で、最接近点から3m離れるまで鳴り直さない。
- カーブ/逆走は `entryEvent`。**区域内にいる間 `guidanceRepeatInterval`(5秒)ごとに
  読み上げ直す**(1回では聞き逃す)。退出後5秒で再武装、逆走は60秒。
  衝突警告(band 0/1)に対して band 3 なので、**衝突警告が鳴っている間は無音**になり、
  消えれば次の周期から戻る。2本目のプレイヤーへは回さない
  (重ねると「他艇に注意」と「カーブに注意」が混ざって両方聞き取れない)。
- 橋も同じ理由で2本目のプレイヤーへ回さない。band 1 なので持続音チャンネルで
  対等に競い、負けるのはより期限の近い衝突警告がいるときだけ。
- system fault は候補の寿命管理に `persistentSystemFault` を使うが、
  **カテゴリによらずすべて表示のみで、音声チャンネルには入れない。**
  GPS途絶・評価停止も、バナー・能力バッジ・`runMode` で明示する。
  橋の下・木立での数秒のGPS欠測や、漕ぎながら対処できない通信情報を
  読み上げると、本当に鳴るべき物理的な衝突警告を覆い隠すためである。
  `AlertDataQuality.unusable` で古い物理警告を3秒で終える場合も、対応する
  system faultの表示は残し、データ欠損を安全の根拠にしない(不変条件3・原則6)。
  **候補・表示・バナー・`runMode` は残す**(原則1・原則6)。
  `NavigationWarningService` で `?? genericWarningAudioAsset` のような
  既定音フォールバックを書かないこと。音の有無は提示ポリシーが決める。

自艇が安定停止(0.4m/s未満が5秒継続)している間、**固定障害物**の反復音・断続音は抑える。
他艇は相手が接近してくるため抑制対象にしない。

**`currentOverlap` は無条件に連続音にしない。** 岸との並走・桟橋への係留は
「重なっている」が切迫していない。静的区域は距離が 0.3m/s 以上で
縮まっていなければ1段下げ、5秒の猶予後は表示のみへ落とす。
**距離が取れないときは接近中として扱う**(原則6)。他艇は対象外。

**音声チャンネルは表示 primary と独立している。**
持続音(`SafetySnapshot.audioDirective`)は「音声アセットを持つ候補」から選ぶ。
無音の system fault が表示 primary になっても鳴っている音は止まらない。
**読み上げは同時に2本鳴らさない。** 2本目のプレイヤー
(`SafetySnapshot.oneShotAudioCues` / `alert.playCue`)は、いま誰も使っていない。
持続音がビープ音だった頃は、その上に短い読み上げを重ねても両方聞き取れたが、
全アセットが読み上げになったいまは、重ねると2つの音声が同時に流れて
どちらも聞き取れない。1本を確実に伝えるほうが2本を潰すより良い。
カーブ・逆走(band 3)も橋(band 1)も持続音チャンネルで対等に競い、
負けた側は無音になる。相手はより切迫した衝突警告なので、これが正しい。
仕組みは残してあるので、読み上げと重ねても潰し合わない音
(短いチャイムなど)を将来足すなら `_isCueEligible` が受け皿になる。

**静的警告は `sourceId` 単位に集約する。** 岸・橋は基準線の各辺が
独立した危険区域になるため、集約しないと岸沿いで音が連鎖し、
橋は手前の面と奥の面で2回鳴る。

**陸上判定中は持続音・単発合図を止める。** 検知・表示・記録・位置共有は続く。
陸上確定は30秒、水上復帰は水面側の測位1点で即座(非対称)。

**この提示ポリシーは航路中心線予測(上記4)が前提。** 直線予測のままだと、
5m/sで7〜10秒先(35〜50m)はカーブで外岸へ5m以上膨らみ、蛇行区間のたびに
音が鳴ってしまう。中心線予測を無効化するなら、バンドも見直すこと。

## 重要な不変条件

変更時に壊していないか必ず確認すること。

1. **リスク評価は送信間隔と独立に毎秒実行される。** 適応送信の変更が警告の応答性を落とさないこと
2. **鮮度の階層**: `OtherBoatTrackStore.freshUntil`(3s) < `boatPredictionTimeoutSeconds`(6s)
   < `boatStaleTimeoutSeconds`(30s)。かつ `sendIntervalStoppedSec`(10s) < 30s
3. **データ欠損 ≠ 安全。** 受信途絶・GPS断は警告を消す根拠にしない。
   `AlertDataQuality.unusable` は3秒の上限で古い物理警告を終わらせるが、
   対応する system fault が必ず同時に立つ
4. **中心線・空間索引・Kalmanは、いずれも判定結果を安全側で変えないか、
   使えない場合に従来経路へ縮退する。** これらの機能で警告が止まってはならない
5. **航行開始をブロックしない。** 音声・危険区域データ・通信のいずれが欠けても開始できる。
   位置情報権限だけは例外(原理的に全機能が成立しない)
6. **地図描画は安全判定用の拡張を反映しない。** `getShipDomains(headingReliable: true)` を使う
7. **`ThreatInfo.distanceMeters` は符号付き**(危険区域の内部で負)。自艇の
   `BoundedPositionSet` を使う判定では、集合の最近点から同じ符号付き距離を
   求める。0へ潰すと停止中の再接近検出が単調でなくなる
8. **`ShipDomainService.boundingRadius` は領域の実寸を下回ってはならない。**
   broad-phase の到達半径と円フォールバックの両方に使うため、過小評価すると
   触れる障害物を評価前に捨てる。位置集合を足す場合は船体領域とのMinkowski和の
   外接半径を使う(`effectiveExclusiveRadius(positionSetBoundingRadiusMeters: ...)`)。
   低速時の横方向拡張も含め、生パラメータから再計算しない
9. **船体領域の六角形は凸に保つ**(`s <= h`)。低速時の方位不確かさで広げるのは
   横方向 `w` だけ。`s`(前後方向)まで広げると凹になり、実効的な全長が伸びる
10. **警告の方向・残り秒数は表示専用。** `ThreatInfo.relativeBearingDegrees` は
   自艇の方位が信頼できるとき(`headingIsReliable`)だけ入る。回頭中は保持方位が
   実際の艇の向きと最大90度ずれるため、誤った側へ振り向かせるより出さない
11. **近接注意距離を0にして警告を止めてはいけない。** 種類ごとの既定値は
   `StaticObstacleKind.defaultProximityCautionMeters`。特定の区域を対象外に
   するのは `FixedObstacleWarningSettings`(`isWarningEnabled`)の役割
12. **受信した他艇の警告状態(`w`/`m`/`a`)は記録専用。** 地図描画にも衝突評価にも
   渡さない。`Boat` には持たせず、`RemoteBoatMessage` / `Message` で止めて
   `PracticeLogRecorder` だけが読む。他艇の警告は自艇の判断材料にならず、
   表示すれば画面が混み(原則4)、安全経路へ入れれば他艇のアプリの不具合が
   自艇の警告を汚染する
13. **1ストロークの艇速波形は表示専用で、位置payloadへ混ぜない。** 衝突評価にも
   地図描画にも渡さない(不変条件12と同じ理由)。共有の書込を位置の atomic update へ
   入れると、波形側の validation 失敗で位置の書込ごと拒否され安全経路が巻き添えになる。
   `onDisconnect` も位置とは独立に登録する

## 練習一括ログ(監視端末)

- 監視中だけ `usePracticeLogRecording` が全艇+監視者を端末内へJSONL追記で記録し、
  ZIPで共有する。サーバー送信はしない。**記録はOFFにできない**(監視機能の一部)
- **記録される提示状態は「実際にどう鳴っていたか」である。** `PresentationStateCodec`
  は `AlertBehavior` ではなく `SafetySnapshot.audioDirective` の対象と `mode` から
  バンドを作る。音声対象がなければ表示primaryをband 0として記録するため、
  system faultは実際の提示どおり「表示のみ」で残る
- **欠測は必ず書く。** 艇側の途絶(`seq` の飛び = `gap`)と監視端末側の中断
  (`recorder_gap`)は別イベントにする。空白を「そこに艇がいなかった」と読ませない(原則6)
- **記録の失敗が監視表示・安全経路を止めてはならない。** 保存失敗は表示のみで継続する
- 監視者トラックの位置ストリームは記録専用。**バックグラウンド継続の資格もここから来る**
  (Wakelockとは無関係)。設定値は `lib/config/practice_log_config.dart`

## 通信バックエンド

- 位置共有・シグナル: Realtime Database(転送量課金・無料枠内で運用可能)
- **1ストロークの艇速波形は `stroke_traces` という別ノードへ置く。**
  `live_positions` は全12艇が全12艇ぶんを購読するため、そこへ足したバイト数は
  144倍で効く。波形は監視端末が開いた1艇だけが購読し、艇側は購読しない(送信のみ)。
  詳細は [docs/design_notes/2026-08-03_艇速変化グラフと監視共有_設計.md](docs/design_notes/2026-08-03_艇速変化グラフと監視共有_設計.md)
- 固定危険区域: アプリ内JSON。臨時危険区域だけFirestore(低頻度)
- `useRealtimeDatabaseForPositions = false` でFirestoreに切り戻せる(コスト大・検証用)
- RTDBのURLが `firebase_options.dart` にない場合は `realtimeDatabaseUrl` で指定

## 危険区域データの管理

- 固定危険区域: `assets/data/sakuragawa_obstacles.json` を編集 → ビルド。Firestoreには保存しない
- **編集したら必ず `tool/update_hazard_profile_hash.sh` を実行する。**
  ハッシュが古いままでも航行機能は止まらない(同梱形状をそのまま使う)が、
  「検証済み」状態が外れ、診断ログに `hazard_profile_unverified` が残る
- **座標の意味が変わる変更をしたら `currentHazardProfileDataVersion` を上げる。**
  version不一致のときだけ座標校正値(現地で合わせたオフセット)を適用しない
- 岸の基準線は各辺が長方形の危険区域へ展開されるため、release でも約310枚になる。
  評価は `StaticObstacleIndex` で周辺の数枚へ絞られる
- 航路中心線は、`channelCenterline.points` があればそれを、無ければ左右の岸基準線から
  自動導出する。導出できなければ直線予測へ縮退する
- 現地で見つけた流木などの臨時危険区域だけ、アプリの描画機能からFirestoreへ保存する

## 練習ログ

- ナビ終了時に `SessionStoreService` が端末内にJSON保存(サーバー送信なし)
- 途中チェックポイントは60秒ごと。解析(`SessionAnalyzerService`)は5分ごとにだけ作り直す
- 解析ロジック変更時は必ず `test/services/session_analyzer_test.dart` を更新
- GPXはStrava互換。形式変更時は `test/services/gpx_export_test.dart` で検証

## してはいけないこと

- **航行開始・警告経路を条件付きで無効化すること**(安全方針に反する)
- **「安全のため」を理由に、使い方の自由度を削ること**(設計原則2に反する)
- **正常な運用で鳴る警告を「安全側だから」と放置すること**(設計原則4に反する)
- Firebase プロジェクト設定・認証方式・課金設定の変更
- API キーや秘密情報のコード直書き(`android/secret.properties` / `ios/Runner/Environment.swift` を使用)
- 既存機能の理由なき削除、大規模リファクタリング
- `git reset` / `rm -rf` などの破壊的コマンド
- ストア申請・外部公開に関わる操作

## コード規約

- 既存のスタイル(flutter_lints)に従う。ファイル名は既存の慣習(hooks は useXxx.dart、widgets はパスカルケース)を踏襲
- コメント・UI文言は日本語
- 警告関連の設定値はハードコードせず `lib/config/` に置く
- 安全判定に関わる純粋ロジックは `services/` の純Dartクラスへ切り出し、単体テストを付ける

## レビュー

レビュー(動作確認・総合レビュー)を依頼されたら、自己流で読み始めず
[docs/review_guide/README.md](docs/review_guide/README.md) の手順に従う。
Claude Code も codex も同じ文書を使う(Claude の入口は
`.claude/skills/full-app-review/SKILL.md`、codex の入口は `AGENTS.md`)。
機械チェックは `bash tool/review/smoke_check.sh`(引数なし)。
衝突判定本体だけを深く見るときは `.claude/skills/collision-safety-review/SKILL.md`。

## GitHub運用

コミット、作業ブランチへのpush、PR作成に関する共通規約は
[`AGENTS.md`](AGENTS.md) を必ず読むこと。実装が検証可能な区切りまで完了したら、
同規約に従って対象ファイルだけを自律的にコミットする。既存の未コミット変更を
まとめてステージしてはいけない。必要な検証とPRの必須チェックが成功し、競合や未解決の
安全上の問題がなければ、利用者の追加確認を待たずにPRをmainへマージする。チェック失敗、
競合、必須レビュー不足、外部設定変更などがある場合は、マージせず理由を報告する。
