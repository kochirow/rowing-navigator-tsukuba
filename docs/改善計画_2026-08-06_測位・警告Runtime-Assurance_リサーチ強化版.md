# 改善計画 2026-08-06 — 測位・警告 Runtime Assurance（リサーチ強化版）

作成日: 2026-08-06  
位置づけ: `改善計画_2026-08-06_測位パイプラインと提示ポリシーの根治.md` を置き換えず、
その分析と優先順位を土台に、追加リサーチから得た手法を実装可能な計画へ落とした別案である。

> **統合済み。実装は [統合版](改善計画_2026-08-06_統合版_測位パイプライン再建.md) に従うこと。**
> 本書の Workstream A/C/G/H はほぼ全面採用した。統合版で変更したのは3点:
> ① **Fix Ingress を Release 4 から前倒し**（最大のレバーかつ最小の変更であり、
>    dt が 1 秒に戻れば発散自体が減る可能性が高いため）。
> ② **時系列 Conformal Calibration（E-4）は現時点では採らない**
>    （1水域×1ペア×677対応点を多層に分けると過適合する。D/Eペアは校正ではなく検証に使う）。
> ③ **`gps_guard_entry` の降格廃止は他艇に限定する**
>    （静的区域の1バンド降格は連続音の信頼性を守る意図的設計。全廃すると過剰警告が戻る）。

前提資料:

- [2026-08-06 実機テストログ分析（5端末・霞ヶ浦）](design_notes/2026-08-06_実機ログ分析_5端末.md)
- `実機テストログデータ/2026_08_06/` の5診断パッケージ
- 既存の改善計画、`DESIGN_PRINCIPLES.md`、現行コードとテスト

---

## 1. 結論

しばらく追加の実機テストができない以上、改善の成否を新しい現場データだけに依存させない。
既存5端末ログから多数の反実仮想ケースを作り、候補推定器を並列比較し、
本番では高度な推定器が壊れても単純で保守的な経路へ退避できる構造を先に作る。

本計画の中核は次の5点である。

1. **反実仮想ログ実験室**: 実ログから欠落・遅延・まとめ配信・外れ値・通信劣化を生成する。
2. **Runtime Assurance / Simplex**: 高性能だが複雑な推定器を、単純な安全監視器と退避経路で包む。
3. **Solution Separation**: 主推定、raw GNSS、保守的推定の食い違いから発散を検出する。
4. **経験的保護半径**: D/Eの実測済み端末間距離を用い、時系列依存を考慮して相対誤差帯を校正する。
5. **エピソード型警告**: 単発イベントの回数制限ではなく、危険の開始・悪化・解除を管理する。

目標は「最も滑らかな位置」ではない。次の順に守る。

1. 必要な他艇警告を見逃さない。
2. 最初の警告を遅らせない。
3. 推定器が発散しても自信満々な誤位置を使い続けない。
4. 不確かさを理由に安全機能を無音化しない。
5. 同一危険の無意味な反復を減らす。

---

## 2. なぜこの構成にするか

### 2-1. 単一推定器への依存が現在の構造的弱点

D/Eは同じ8+に搭載され、端末間距離は1.5〜2mと実測されている。
raw GNSSの系列間距離は概ねこの範囲に近い一方、filteredはテールで10〜32mまで開いた。
これは少なくとも艇間の**相対位置**について、推定器がrawより悪い状態を継続し得ることを示す。

現在は主推定器が発散したとき、それを独立に監視する別解がない。
そこで、航空GNSSのRAIMで用いられる **Solution Separation** の考え方をアプリ層へ移植する。
RAIMでは、異なる観測集合から得た複数解の分離を用いて故障検出や保護レベルを計算する。
本アプリでは衛星ごとの生観測を前提にせず、異なる性質の位置解を並列に走らせて監視する。

### 2-2. 高度な方式を安全に導入するRuntime Assurance

CMUのSimplex ArchitectureとNASAのRuntime Assuranceは、完全には検証しにくい高性能コンポーネントを、
単純で高保証な監視器と退避機能で包む考え方である。本計画では次のように対応させる。

| Runtime Assurance | Rowing Navigator |
| --- | --- |
| Advanced component | RobustPositionEstimator / 将来のIMM・適応推定器 |
| Safety monitor | 解分離、fix鮮度、共分散、innovation、時刻整合性の監視 |
| Assured fallback | 最新の妥当raw fix + 単純な定速度予測 + 急速に膨らむ保護半径 |
| Switching logic | trusted / suspect / fallback / reacquiring 状態機械 |

革新的な推定器を先に完成させるのではなく、まず「壊れたときの逃げ道」を実装する。

### 2-3. 実機なしでも反実仮想・メタモルフィック試験で前進できる

自律システム分野では、実環境で全条件を試せないため、シミュレーション内の反実仮想解析や
メタモルフィックテストで、安全上重要な失敗を探索する研究が進んでいる。
本アプリでも、完全な絶対真値がないケースを「検証不能」とせず、
入力変換に対して守られるべき性質を大量に試験する。

---

## 3. 目標アーキテクチャ

```text
Core Location / polling
        |
        v
Fix Ingress（順序・重複・鮮度を検証、捨てた理由を記録）
        |
        +------------------+-------------------+
        |                  |                   |
        v                  v                   v
  Raw Solution       Advanced Estimator   Conservative Estimator
  最新妥当fix         現行改良版/IMM候補     単純・早期再捕捉
        |                  |                   |
        +------------------+-------------------+
                           |
                           v
                  Integrity / RTA Monitor
          （解分離、鮮度、NIS、共分散、連続棄却）
                           |
              +------------+-------------+
              |                          |
              v                          v
        Selected Position          Protection Radius
              |                          |
              +------------+-------------+
                           |
                           v
              Reachable-Set Risk Evaluation
                           |
                           v
                    Alert Episode Manager
                           |
                           v
              表示 / 音声 / 記録 / 説明理由コード
```

### 3-1. 責務を分離する

- Fix Ingressは「位置を良くする」のではなく、時系列の正当性を保証する。
- 各推定器は互いの内部状態を共有しない。共通原因で同時に壊れにくくする。
- RTA Monitorだけが使用解を選ぶ。
- Risk Evaluationは点ではなく、位置と保護半径から危険領域を作る。
- Episode Managerは危険検出を変えず、提示の反復と優先順位だけを管理する。

---

## 4. Workstream A — 反実仮想ログ実験室

### A-1. 目的

`tool/replay_field_log.dart` を、単なる過去ログ再生から「障害注入・候補比較・安全差分検査」へ拡張する。

### A-2. 入力を3層に分ける

1. **原観測層**: raw位置、timestamp、accuracy、speed、heading、到着順。
2. **障害変換層**: 欠落、遅延、重複、逆順、バッチ、位置偏り、通信遅延。
3. **評価層**: 推定器、危険判定、提示ポリシーの出力比較。

元ログを直接書き換えず、変換レシピとseedを保存して同一条件を再現できるようにする。

### A-3. 障害変換カタログ

| ID | 変換 | 値の候補 | 狙い |
| --- | --- | --- | --- |
| `drop_periodic` | N件ごとに欠落 | 2, 3, 5 | 0.5Hz/0.33Hz相当 |
| `drop_burst` | 連続欠落 | 3, 6, 10秒 | 橋下・一時停止 |
| `delivery_delay` | 到着だけ遅延 | 0.3〜3秒 | fix時刻と到着時刻の分離 |
| `batch_delivery` | 複数fixを同時到着 | 2, 3, 5件 | 900msゲート検証 |
| `duplicate_fix` | 同一fixを再送 | 1〜3回 | 重複耐性 |
| `out_of_order` | 隣接fixを逆順化 | 2〜5件 | 時刻逆行耐性 |
| `stale_replay` | 古いfixを後着 | 2〜10秒遅れ | 過去位置への巻き戻り防止 |
| `accuracy_scale` | accuracyだけ変更 | 0.5, 2, 4倍 | 自己申告誤差への依存検査 |
| `residual_block` | D/E残差ブロックを加算 | 10〜60秒 | 時間相関を保った誤差 |
| `bias_ramp` | 偏りを徐々に増加 | 0→5/10/20m | 遅い発散の検出 |
| `heading_loss` | headingを欠損 | 区間指定 | 到達領域の保守性 |
| `remote_delay` | 他艇だけ遅延 | 1〜30秒 | 位置共有の鮮度低下 |
| `remote_speed_null` | 他艇速度欠損 | 区間指定 | 欠損時に静音しないこと |

### A-4. ブロック・ブートストラップ

GNSS誤差には時間相関があるため、各点を独立にランダム化しない。
D/Eのraw差、filtered差、innovationの連続区間を10〜60秒のブロックとして再標本化する。

- 同一セッション内の近接点を学習・評価へ跨がせない。
- 校正用・選択用・最終評価用を**セッション単位**で分ける。
- D/Eの片側を調整に使った場合、同時刻のもう片側を最終評価へ使わない。

### A-5. メタモルフィック不変条件

完全な真値がなくても、次は常に成立すべきである。

1. 座標を一括平行移動しても、艇間距離・DCPA・警告時刻は変わらない。
2. 全方位を同じ角度だけ回転しても、相対衝突判定は同じになる。
3. 同一fixの重複で警告エピソード数が増えない。
4. 古いfixの後着でselected positionが過去へ戻らない。
5. 欠落時間が長いほど保護半径が縮まらない。
6. 主推定器とrawの分離が増えたとき、integrity状態が改善方向へ遷移しない。
7. 他艇速度を欠損させても、提示が静かにならない。
8. 同一危険のサンプル数を増やしても、初回音声回数は増えない。
9. より緊急な候補を追加しても、既存の緊急音声が静音規則で消えない。
10. 端末IDやD/Eを入れ替えても、対称な相対判定は同じになる。

### A-6. 候補選択の順序

候補は加重平均スコアで選ばない。次の辞書式で失格判定する。

1. 必須他艇警告の見逃しが1件でも増えたら失格。
2. 最初の警告がbaselineより遅れたら失格（許容差は別途固定）。
3. 10m超相対誤差の継続時間が増えたら失格。
4. 経験的保護半径の被覆率が目標未満なら失格。
5. 以上を満たす候補間で、不要反復・計算量・電池を比較する。

---

## 5. Workstream B — Fix Ingressの根治

### B-1. 原則

安全評価、Firebase送信、地図描画、診断記録を同じ周期で間引かない。

- 安全評価: 単調に新しい妥当fixを原則すべて処理する。
- 位置共有: 回線・速度・危険度に応じて間引く。
- 地図描画: UI周期で間引く。
- 重い診断: さらに低頻度でよい。

### B-2. FixEnvelope

全測位を次の構造で包み、推定器へ入る前に記録する。

```text
FixEnvelope {
  sequence,
  source,                 // stream / polling
  arrivedAtMonotonic,
  fixTimestamp,
  ageAtArrivalMs,
  deltaFromPreviousFixMs,
  deltaFromPreviousArrivalMs,
  accuracy,
  accepted,
  rejectionReason,
}
```

棄却理由は最低限、`duplicate`、`timestamp_regression`、`stale`、`invalid_coordinate`、
`superseded_in_batch`、`navigation_generation_mismatch`を区別する。

### B-3. バッチ受信

まとめて届いたfixを先着順に1件だけ処理するのではなく、fix timestampで並べる。

- 過去状態を再計算しない場合: 窓内の最新fixを採用。
- 連続更新が必要な場合: timestamp順に全件処理し、描画・送信だけを抑制。
- どちらを採るかは反実仮想テストの処理時間と警告時刻で決める。

### B-4. Core Location設定

iOSでは`distanceFilter`を未設定または`kCLDistanceFilterNone`相当にする候補を用意する。
現行`geolocator_apple 2.3.13`のmapper挙動を単体テストで固定し、プラグイン更新時に再確認する。

変更は機能フラグで分ける。

- `iosDistanceFilterNone`
- `processAllMonotonicFixes`
- `latestFixPerWindow`

追加実機テストができない期間は、Aの反実仮想試験でα/βの挙動を比較し、
実機では次回利用時にshadowメトリクスを自動収集できる状態まで準備する。

---

## 6. Workstream C — Runtime Assurance / Solution Separation

### C-1. 3つの独立解

#### S0: Raw Solution

- 最新の妥当raw fix。
- 平滑化しない。
- 古さを必ず付与する。
- 推定器監視と緊急退避に使う。

#### S1: Advanced Solution

- 現行`RobustPositionEstimator`の改良版。
- 通常時の表示・危険判定で主に使用。
- 将来IMMまたはInnovation-Adaptive方式へ交換可能。

#### S2: Conservative Solution

- 単純な定速度またはα-β型。
- hard rejectを最小化する。
- 長時間予測しない。
- 欠落中は不確かさを速く膨らませる。
- 新しい良好fixを速やかに採用する。

3解が同一の`RobustPositionEstimator`内部関数を共有しすぎると独立性が失われる。
座標変換などの純粋関数以外は、できるだけ別実装にする。

### C-2. IntegrityObservation

```text
IntegrityObservation {
  rawToAdvancedMeters,
  rawToConservativeMeters,
  advancedToConservativeMeters,
  fixAgeMs,
  nis,
  estimatorDisposition,
  consecutiveRejectedDurationMs,
  advancedUncertaintyMeters,
  expectedMotionBoundMeters,
}
```

### C-3. 状態機械

```text
trusted
  -> suspect       解分離・NIS・連続棄却のいずれかが悪化
suspect
  -> trusted       回復条件を連続して満たす
  -> fallback      複数監視条件が一致、または上限超過
fallback
  -> reacquiring   新しい良好fixが到着
reacquiring
  -> trusted       規定時間、3解が整合
  -> fallback      再び分離
```

サンプル数ではなく経過時間を主要条件にする。測位周期が変わっても意味が保たれるためである。

### C-4. 解分離の判定

固定の距離だけでなく、予測可能な運動量と各解の不確かさで正規化する。

```text
separationScore = distance(S1, referenceConsensus)
                / max(minimumScale,
                      protectionS1 + protectionConsensus + motionAllowance)
```

`referenceConsensus`は次の順に決める。

1. S0とS2が互いに整合し、S1だけ離れる: S1をsuspect/fallback。
2. S0だけ離れる: 単発GNSS外れ値候補。S1/S2を維持し保護半径を拡大。
3. 全解が離れる: 正解不明。最も新しい妥当fixを基準に保護半径を最大化。
4. fixが古い: どの解もtrustedにしない。

### C-5. Fallback時の安全動作

- 危険判定を停止しない。
- rawまたはS2をselected positionにする。
- 静的危険物には拡大した絶対保護半径を使う。
- 他艇には通信遅延を含む到達可能領域を使う。
- `gps_guard_entry`を理由に他艇音声を自動降格しない。
- 画面に「測位精度低下・目視優先」を表示する。
- 位置共有にはintegrity状態と保護半径も送れる契約を将来検討する。

---

## 7. Workstream D — Advanced Estimatorの候補

RTAを先に完成させ、その内側で候補を比較する。

### D-1. 候補1: `Q(dt)`を正した現行モデル

最小変更候補。固定gateを直接広げる前に、状態遷移とプロセスノイズのdt依存を確認する。

- `Q`がdt、dt²、dt³、dt⁴のどの項を持つかをモデル式とテストで固定。
- 停止、定速、加速、旋回を別fixtureにする。
- 共分散が正定値・有限であることを全dt範囲で検査。
- 連続棄却中に共分散を膨らませる。

### D-2. 候補2: Innovation-Adaptive Estimation

直近のinnovation実測共分散と理論共分散を比較し、モデル不一致を検出する。

- 単発の大外れ: 観測重みを限定的に下げる。
- 同方向のinnovationが継続: GNSSを捨て続けず、Qを増やす。
- 連続棄却: suspectへ遷移し、再捕捉を優先。
- 適応係数には上下限と変化率制限を置く。

オンライン適応が自己増幅しないよう、適応状態をログへ残し、Aの反実仮想試験で固定Q版と比較する。

### D-3. 候補3: 軽量IMM

3モデルを並列に走らせる。

| モデル | 特徴 | 主な場面 |
| --- | --- | --- |
| M0 Stop/Drift | 速度減衰強、位置揺れを速度化しにくい | 停止・待機 |
| M1 Cruise | 現行相当 | 通常直進 |
| M2 Maneuver | Q大、新fixを強く採用 | 全力・加減速・旋回 |

innovationが増えたとき、即座に観測を異常扱いせず、M2確率を上げる。
モード確率は急に0/1へ張り付かないよう下限と遷移行列を持つ。

### D-4. 採用判断

複雑さを含むPareto比較とする。

- `Q(dt)`修正版で10m超excursionが0になるなら、それを第一候補とする。
- 適応版がテールを改善しても警告時刻を遅らせるなら不採用。
- IMMが明確な追加利益を出す場合のみ採用。
- どの候補でもRTA MonitorとS2は残す。

---

## 8. Workstream E — 経験的保護半径

### E-1. 目的

Kalmanの自己申告共分散をそのまま安全距離に使わず、D/Eの実測済み端末間距離から
「実際にどの程度外れたか」を校正する。

### E-2. 相対誤差の定義

同時刻対応を許容時間内で作り、次を計算する。

```text
relativeExcessError = max(0, observedPairDistance - expectedMaxDistance)
expected distance range = 1.5〜2.0m
```

端末の前後オフセットと艇首方向が利用可能なら、単なる距離差ではなく期待相対ベクトルで評価する。

### E-3. 状態別校正

- 停止 / 低速 / 通常 / 全力
- 直進 / 旋回
- fix age帯
- reported accuracy帯
- accepted / downWeighted / rejected / reacquired
- trusted / suspect / fallback / reacquiring

データが少ない層は細分化せず、上位層へまとめる。

### E-4. 時系列向けConformal Calibration

通常のsplit conformalは交換可能性を前提とするが、GNSS残差は時系列依存を持つ。
そのため以下を採用する。

- サンプル単位でランダム分割しない。
- セッション単位のleave-one-session-out評価を主とする。
- 同一艇同時刻のD/Eを別foldへ分けない。
- ブロック置換を用いた時系列向けconformalを候補とする。
- 95%だけでなく99%被覆と連続未被覆時間を記録する。
- 被覆率だけでなく、未被覆が特定状態へ集中していないか確認する。

現在は5端末・実質3艇と少ないため、「一般的な99%保証」とは呼ばず、
**2026-08-06条件に対する経験的保護半径**と明記する。

### E-5. 他艇用保護半径

```text
relativeProtectionRadius =
    empiricalRelativeRadius(state)
  + communicationReachability(remoteAge, maxBoatSpeed)
  + solutionSeparationAllowance
```

静的危険物には相対保護半径を流用せず、従来の絶対不確かさを保守的に維持する。

---

## 9. Workstream F — 到達可能領域による他艇判定

### F-1. 点予測から領域予測へ

各艇について、今後数秒で存在し得る領域を作る。

- 現在位置と保護半径
- 速度・方位
- 最大加速度・減速度
- 最大旋回率
- 情報の古さ
- 予測時間

最初は計算の軽いカプセル形状または複数円でよい。

### F-2. 情報欠損時

- 相手速度不明: 0m/sではなく、設定上限まで動ける領域。
- 方位不明: 全方向へ円形に拡大。
- remote age増加: 到達可能距離を単調に増やす。
- 共有unavailable: 「他艇なし」と判定せず、能力不明を表示。

### F-3. 警告レベル

| 状態 | 意味 | 提示 |
| --- | --- | --- |
| monitoring | 領域は離れているが接近傾向 | 地図のみ |
| caution | 保護領域が予測時間内に接触 | バナー、必要なら単発音 |
| warning | definite領域または短いdeadline | 音声 |
| urgent | action deadlineが極短、悪化中 | 優先音声・他警告を抑える |

不確かさが大きいだけでwarningを自動降格しない。
不確かさによる接触は「確実な衝突」と表示上区別しつつ、安全上の音声可否は
自艇停止だけで決めず、相手の到達可能性とdeadlineで決める。

---

## 10. Workstream G — Alert Episode Manager

### G-1. 目的

サンプルごとの候補生成と、人に伝える警告単位を分離する。

```text
inactive
 -> observing
 -> announced
 -> escalating
 -> stable
 -> cleared
```

### G-2. エピソード識別子

```text
episodeKey = hazardFamily + physicalTarget + causalContext
```

例:

- 同じ岸へ停止中に接近・離脱を繰り返す: 1エピソード。
- 同じ逆走区間に連続滞在: 1エピソード。
- 同じ他艇との接近: 1エピソード。
- 一度十分に離れ、再接近した: 新エピソード。

### G-3. 音声規則

- 初回: 対象と行動を1回。
- 危険度が上がった: より短いエスカレーション音声。
- 危険度不変: 表示更新のみ。
- 改善: 音なし。
- 解除: 原則音なし。
- 再侵入: rearm条件を満たした場合だけ新規音声。

「5秒ごとに最大3回」のような回数制限だけでなく、状態変化を意味として扱う。

### G-4. 優先順位と静音権限

規則を宣言的にするが、単純に「最も静かな結果」を採らない。

各規則に次を必須とする。

```text
SuppressionRule {
  id,
  allowedCategories,
  forbiddenCategories,
  maximumSuppressibleUrgency,
  requiredKnownInputs,
  targetBehavior,
  reasonCode,
}
```

不変条件:

- `other_boat`は静音対象として明示許可されない限り抑制不可。
- 相手速度不明は静音の根拠にしない。
- urgentは低速・桟橋・安定停止規則で抑制しない。
- 下位カテゴリの規則が上位警告を上書きしない。
- 集約前の個別危険は記録に残す。

IMOのBridge Alert Managementは、警告の優先度、集約、機能グループ化、履歴を扱う。
本アプリはIEC/IMO適合を名乗らず、危険エピソードの優先順位・集約設計の参考として採用する。

---

## 11. Workstream H — 位置共有の能力監視

### H-1. 「0隻」ではなく能力を監視する

0隻は正常状態でもあり得る。次の状態を別々に持つ。

- publish setup
- publish ACK freshness
- subscription connected
- authorization state
- server time offset freshness
- last remote update
- known team roster availability

### H-2. 再試行分類

| 原因 | 再試行 |
| --- | --- |
| timeout / network unavailable | jitter付き指数バックオフ |
| transient disconnect | 即時1回後、指数バックオフ |
| permission-denied | 無限再試行せず、認証・所属・Rules原因として表示・記録 |
| invalid data contract | 再試行せず、互換性fault |

### H-3. 表示

「他艇がいません」ではなく、能力が確認できない場合は次の意味を伝える。

> 他艇情報を受信できる状態を確認できません。周囲を直接確認してください。

表示のみを基本とするが、航行開始時に共有能力が未確立なら、開始確認UIで明示する案を検討する。

---

## 12. 実施順とリリース単位

### Release 0 — 他艇無音化regression

依存なし、単独修正。

- 不確かさのみ×自艇低速の静音規則から`other_boat`を除外。
- 自艇停止・他艇接近・`gps_guard_entry`付きで音声が残る回帰テスト。
- 相手速度不明で静音しないテスト。
- Aログに仮想他艇を重ねた再生。

### Release 1 — 反実仮想ログ実験室

本番挙動を変えない。

- 障害変換レシピ。
- seed固定。
- メタモルフィック試験。
- baseline比較JSON。
- 失格条件レポート。

### Release 2 — 観測とShadow Mode

本番選択解は現行のまま。

- FixEnvelope。
- estimator disposition / NIS。
- S0/S1/S2並列計算。
- 解分離と候補出力をログだけに記録。
- 処理時間と概算CPU負荷を記録。

### Release 3 — RTA Fallback

高性能推定器の交換より先に導入。

- trusted/suspect/fallback/reacquiring。
- 保守的S2。
- 保護半径拡大。
- fallback中も安全評価継続。
- 画面の測位品質低下表示。

### Release 4 — Fix Ingress変更

機能フラグ単位で導入。

- iOS distance filter候補。
- timestamp順処理。
- 最新fix優先。
- 送信・描画と安全評価の間引き分離。

### Release 5 — Advanced Estimator

反実仮想評価で勝った候補だけをS1へ採用。

- 第一候補: `Q(dt)`修正版。
- 第二候補: Innovation-Adaptive版。
- 第三候補: 軽量IMM。

### Release 6 — 経験的保護半径と到達可能領域

- セッション分離校正。
- 相対保護半径。
- 通信遅延到達領域。
- 他艇判定への段階導入。

### Release 7 — Episode Manager

- エピソード識別。
- 初回・悪化・解除。
- カテゴリ横断集約。
- 静音権限の型付け。

### Release 8 — 水域データ

位置パイプラインが安定してから実施。

- 霞ヶ浦の待機区域。
- レーン適用条件。
- 水域別運用前提。
- hazard profile version/hash更新。

---

## 13. オフライン受け入れ基準

### 13-1. Fix Ingress

- timestamp逆行を採用しない。
- 重複fixで安全評価回数・警告エピソードが増えない。
- batch deliveryで窓内の最新fixが失われない。
- `arrival time`と`fix time`を区別して記録する。

### 13-2. 推定器・RTA

- D/Eペアで10m超相対誤差excursionを0回にする。
- filtered相対誤差p99がrawより悪化しない。
- 3秒、6秒、10秒欠落後に有限時間で再捕捉する。
- 欠落中に保護半径が単調に増える。
- S1だけを人工的に偏らせた場合、規定時間内にfallbackする。
- raw単発外れ値ではselected positionが同じ大きさで飛ばない。
- 全解不一致ではtrustedを維持しない。

### 13-3. 危険判定

- baselineで成立した他艇危険エピソードを失わない。
- 最初の警告がbaselineより遅れない。
- remote age増加で到達可能領域が縮まらない。
- 他艇速度不明で警告が静かにならない。

### 13-4. 提示

- 自艇停止だけで他艇警告を静音しない。
- 同一エピソードのサンプル数を増やしても初回音声は1回。
- 危険度悪化では再通知できる。
- 低優先度規則がurgentを無音化しない。
- 集約しても個別危険と理由コードをログに残す。

### 13-5. 性能

- 各fixの安全評価処理p99を端末予算内に置く。
- 並列推定器は処理時間・メモリを診断に記録する。
- 長時間実機が再開できるまでは、Mac上のCPU値を電池の証明として扱わない。

---

## 14. 次回実機テストが再開したときの最小確認

実機テストが再開するまで開発を止めない。一方、次はローカルで証明できないため外部ゲートとして残す。

1. iOSでの実測fix到着頻度と鮮度。
2. background中の継続受信。
3. 並列推定器による電池消費。
4. speaker / Bluetooth / Buddycom併用時の実可聴性。
5. 位置共有の復帰。
6. 霞ヶ浦の待機区域・レーン境界。
7. 水上での他艇接近時の警告タイミング。

手動で記録するもの:

- 端末機種、OS、搭載位置、アンテナ面の向き。
- D/E端末間距離と艇首方向の前後オフセット。
- 開始・終了電池、他アプリ音声、Bluetooth接続先、端末音量。
- 停止・通常・全力・旋回区間の時刻。
- 音声が実際に聞こえたかを記録する観察者。

---

## 15. やらないこと

- 新しい実機データがないことを理由に、開発全体を止めない。
- 5ログへの過適合を「一般的な安全保証」と呼ばない。
- 高性能推定器を単独で本番の唯一解にしない。
- 平均誤差の改善だけで候補を採用しない。
- warning件数の固定上限だけをCI合否にしない。
- 不確かさの増加を、他艇警告の静音理由にしない。
- 欠落・速度不明・共有unavailableを安全の根拠にしない。
- 水域データを測位改善前の航跡だけで固定しない。
- ローカル再生結果を、実機可聴性・水上安全性・電池の証明と呼ばない。

---

## 16. 実装成果物

### ツール

- `tool/replay_field_log.dart` の候補比較モード。
- 障害変換レシピとseed。
- ペアログ同期・相対誤差レポート。
- メタモルフィックテストランナー。
- 候補別の差分JSON/Markdownレポート。

### ランタイム

- `FixEnvelope`。
- `PositionSolution`共通契約。
- `ConservativePositionEstimator`。
- `PositionIntegrityMonitor`。
- `PositionIntegrityState`。
- `RelativeProtectionRadiusCalibrator`または生成済み定数。
- `ReachableSetEvaluator`。
- `AlertEpisodeManager`。

### 診断

- fix到着・fix時刻・鮮度・棄却理由。
- 3解の位置・分離距離。
- integrity状態遷移と理由。
- 保護半径の構成要素。
- エピソード開始・悪化・解除。
- 各提示規則の適用・不適用理由。

### テスト

- 単体テスト。
- 既存ログ回帰。
- D/Eペア回帰。
- 障害注入。
- メタモルフィック不変条件。
- 候補差分と失格条件。

---

## 17. リサーチから採用した知見と適用範囲

### Runtime Assurance / Simplex

複雑で完全検証が困難なコンポーネントを、単純な監視・退避系で包む。
本計画では推定器の高度化を安全に試す設計原則として採用する。

- CMU SEI, [An Architectural Description of the Simplex Architecture](https://www.sei.cmu.edu/library/an-architectural-description-of-the-simplex-architecture/)
- NASA, [A Formal Verification Framework for Runtime Assurance](https://ntrs.nasa.gov/citations/20240006522)

### GNSS Integrity / Solution Separation

複数解の分離と保護レベルを用いて、単一の位置解を無条件に信用しない。
本アプリでは衛星観測レベルのRAIM適合ではなく、アプリ層の異種解監視として応用する。

- ESA Navipedia, [RAIM Algorithms](https://gssc.esa.int/navipedia/index.php/RAIM_Algorithms)
- ESA Navipedia, [RAIM Fundamentals](https://gssc.esa.int/navipedia/index.php/RAIM_Fundamentals)

### Innovation監視・適応Kalman

innovationの実測統計と理論値の不一致から、観測外れ値とモデル不一致を監視する。
オンライン適応は上下限・変化率制限・RTAによる退避を前提にする。

- [Adaptive Fusion based on Covariance Matching](https://pmc.ncbi.nlm.nih.gov/articles/PMC9607358/)
- [Tightly Coupled GNSS/INS with Robust Sequential Kalman Filter](https://pmc.ncbi.nlm.nih.gov/articles/PMC7014498/)

### 時系列向けConformal Prediction

通常の独立同分布前提をそのまま置かず、ブロック構造とセッション分離で経験的保護半径を校正する。

- Chernozhukov et al., [Exact and Robust Conformal Inference with Dependent Data](https://proceedings.mlr.press/v75/chernozhukov18a.html)
- Xu and Xie, [Sequential Predictive Conformal Inference for Time Series](https://proceedings.mlr.press/v202/xu23r.html)
- Lindemann et al., [Safe Planning in Dynamic Environments using Conformal Prediction](https://arxiv.org/abs/2210.10254)
- Muthali et al., [Multi-Agent Reachability Calibration with Conformal Prediction](https://arxiv.org/abs/2304.00432)

### メタモルフィック・反実仮想試験

完全なoracleがない自律システムでも、入力変換に対する不変条件と反実仮想シナリオで失敗を探索する。

- [Metamorphic Testing in Autonomous System Simulations](https://arxiv.org/abs/2209.11031)
- [Counterfactual Analysis in Behaviorally Diverse Simulation](https://arxiv.org/abs/2011.11991)

### 警告管理・Human Factors

警告の優先順位、集約、履歴と、nuisance alertによる注意低下を設計根拠にする。
本アプリは大型船・航空管制の規格適合を名乗らず、提示設計の参考として用いる。

- IMO Resolution [MSC.302(87): Bridge Alert Management](https://wwwcdn.imo.org/localresources/en/KnowledgeCentre/IndexofIMOResolutions/MSCResolutions/MSC.302%2887%29.pdf)
- FAA, [Human Factors Analysis of Safety Alerts in Air Traffic Control](https://hf.tc.faa.gov/publications/2007-human-factors-analysis/full_text.pdf)

### Core Location

全移動通知には`kCLDistanceFilterNone`を用いるという仕様と、iOS 16.4以降の
バックグラウンド高精度継続更新に関するApple担当者の案内を設定候補の根拠にする。

- Apple, [CLLocationManager.distanceFilter](https://developer.apple.com/documentation/corelocation/cllocationmanager/distancefilter)
- Apple Developer Forums, [Background location updates stop in iOS 16.4](https://developer.apple.com/forums/thread/726945?page=2)

---

## 18. 最初の実装単位

長期計画を一度に実装しない。最初の作業単位は次の3つとする。

1. **他艇無音化regressionの単独修正**。
2. **反実仮想ログ実験室の最小版**: 欠落、バッチ、遅延、重複、逆順の5変換。
3. **Shadow Solution Separation**: S0/S1/S2と分離距離を記録するが、本番選択は変えない。

この3つが揃えば、追加実機テストを待たずに、推定器候補を安全に比較する基盤が完成する。
