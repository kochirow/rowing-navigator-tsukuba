# codex 総合レビューのレビュー(優先順位づけ)

作成日: 2026-08-12
対象: `docs/reviews/2026-08-12_アプリ総合レビュー_codex原文.md`(原文はこの隣に退避済み)
レビュー対象HEAD: `44a762a`(`agent/2026-08-05-field-log-fixes`)
確認方法: 現行コードの直接確認 + `../実機テストログデータ/2026_08_06/` の5パッケージを再解析

原文は事実誤りが少なく、全体として信頼できる。ただし**優先順位は実態とずれている**。
「実運用前に必須(P1)」に6件が並んでいるが、そのうち出艇の可否を左右するのは2件で、
残りは証拠の衛生管理である。逆に、原文が**問い(12.4)のまま置いた論点にこそ、
ログから確定できる最大のリスクがあった**。

---

## 1. 結論:注力すべきは3つ

| # | 項目 | 原文での扱い | 本レビューの判定 |
| --- | --- | --- | --- |
| 1 | 位置共有不能は送信だけでなく**受信も同時に失う** | 未解決の問い(12.4) | **P0**。ログで確定した。最優先 |
| 2 | `permission-denied` を再試行しない方針 | 疑問として提示(12.5) | **P0**。実機証拠と矛盾する。最新コミットで入った退行 |
| 3 | イベントカタログの完全性テスト | P1の6番目 | **P1**。費用対効果が最大(実装30分) |

これ以外は、**出艇の判断を変えない**。順に落として実施すればよい。

---

## 2. 原文が答えを出していない最重要事実(新規)

### 2.1 共有不能だった端末は、他艇を1隻も「受信」していない

`position_processing_sample`(10秒周期)の `otherBoatCount` を全セッションで集計した。

| session | 艇・席 | heartbeatの共有状態 | otherBoatCount の分布 |
| --- | --- | --- | --- |
| …4599956 (A) | 4x・bow | healthy | 0:80 / 1:243 / 2:240 |
| …5014567 (B) | 8+・7 | **unavailable 82/82** | **0:224(全サンプル)** |
| …5757700 (C) | 2x・stroke | healthy 208/209 | 0:90 / 1:230 / 2:253 |
| …7606648 (D) | 8+・cox | healthy | 0:4 / 1:78 / 2:254 |
| …7619060 (E) | 8+・7 | **unavailable 143/143** | **0:394(全サンプル)** |

Eのセッション(22:07–23:21)は A・C・D と完全に重なっており、その間 A・C・D は常時1〜2隻を見ていた。
B も C と重なっている。**B と E だけが、全時間帯で他艇ゼロ**である。

さらに B・E の `events.jsonl` には、
`dynamic_obstacle_stream_error` も `other_boat_record_rejected` も
`position_sharing_unavailable` すらも**1件もない**(状態は heartbeat にしか出ていない)。

意味するところ:

- 送信できない端末は、**同時に受信もできていなかった**。原因は端末単位(認証・チーム所属・App Check)である可能性が高い。
- その間、この艇には**他艇衝突警告の入力が存在しなかった**。計118分。
- しかも「他艇がいない」と「他艇を受信できない」が区別されていなかった(設計原則6の違反そのもの)。
- 他艇側から見ても、この艇は**地図に出ていなかった**(同時刻の最大観測が2隻=E以外の3艇のうち2隻)。片側の障害が水域全体の安全表示を欠損させる。

`245eb79` の `SharingCapabilityMonitor` はこの状況を捕まえる設計になっている
(`publishSetupComplete=false` で unconfirmed になる)。方向は正しい。
ただし**受信だけが落ちた場合は捕まらない**。監視入力は
`!isDynamicReceiveUnavailable && !rawDynamicReceiveDegraded`
(=購読が例外を出したか)であって、「読めているか」ではない。
Rules上 read が拒否されストリームが静かに空を返す経路は unconfirmed にならない。

**追加すべき対策(原文にない)**: 自艇のレコードが受信ストリームへ戻ってくるかを見る。
自艇は1〜2秒ごとに書いているので、購読が生きていれば必ずエコーが返る。
`n` 秒エコーが無ければ「読み取り能力を確認できない」として能力 fault を立てる。
他艇の在・不在に依存しない、唯一の end-to-end な読み取り証明になる。

### 2.2 `permission-denied` を非再試行にしたのは、実機証拠と逆

C(…5757700)のログ:

```
elapsedMs   133  position_sharing_failed   permission-denied (failureCount 1)
elapsedMs  4428  position_sharing_unavailable  consecutive_publish_failures
elapsedMs  9579  position_sharing_failed   permission-denied (failureCount 4)
elapsedMs 19731  position_sharing_recovered
```

**起動直後の `permission-denied` は19.7秒で自然に消えた。** 恒久障害ではない
(認証トークンやチーム所属ブリッジの伝播待ちとして自然な挙動)。
回復できたのは、送信経路(`LatestOnlyAsyncPublisher.onFailure`)がエラー種別を見ずに
**無制限に再送し続ける**からである。

一方 `245eb79` で追加した setup 経路
(`lib/hooks/use_navigator.dart:3292` `retryPublishingSetup` /
`lib/services/sharing_capability_monitor.dart:171`)は、
`permissionDenied.isRetryable = false` により**1回も再試行しない**。
同じ症状が clear / onDisconnect 側で出れば、そのセッションは最後まで unavailable のままになる。

つまり現状は、**同一の症状に対して送信経路が無限再試行・setup経路が0回**という
矛盾した方針になっている。原文 12.5 の問いへの答えは「矛盾する」である。

最小の修正: `permissionDenied` を「有限回だけ再試行」にする。
`isRetryable` を bool から回数付きへ変えるか、`maxAttempts` を種別に持たせ、
5s / 10s / 20s の3回で打ち切る。電池と転送量の懸念(コメントの根拠)は3回なら成立しない。
`SharingFailureKind` は純Dartなので `test/services/sharing_capability_monitor_test.dart` に
そのまま固定できる。

---

## 3. 原文の各指摘に対する判定

| 原文 | 内容 | 判定 | 優先度(原→本) | 根拠 |
| --- | --- | --- | --- | --- |
| 5.1 | 07-30 位置共有失敗 | 事実。原因未確定も正しい | – | – |
| 5.2 | 08-05 未来時刻で1,499件棄却 → 修正済 | 事実。08-06で再発0も確認 | – | `message_service.dart:128` |
| 5.3 | GPS stream 無通知 → ポーリングで継続 | 事実。08-06 で poll成功539〜817回/失敗0 | – | 再集計で一致 |
| 5.4 | 同一端末で118分の共有不能 | 事実。**過小評価**(受信喪失は書かれていない) | P1 → **P0** | 本書 2.1 |
| 5.5 | 開始時に推定誤差1,026m | **誤読に近い**。1点目の GNSS accuracy が1026.5m、2点目は4.7m。17秒の低精度継続ではない | – → P3 | `track.csv` 先頭10行 |
| 5.6 | 安全評価の一時停止 | 事実(stalled 4回・timer 2回、Cのみ)。現行コードは別物という留保も妥当 | – | ログ一致 |
| 5.7 | 音声は「再生開始」しか証明していない | 妥当。カタログにも同趣旨の注記あり | P2 | `log_config.dart` |
| 5.8 | 記録は堅牢/終了時clearが5秒timeout | 事実(B・Eで `navigation_stop_step_failed` 各1) | – | – |
| 7.2 | manifest に Git SHA 等がない | 事実。版の混乱も実在(pubspec `1.1.0+13` / ログ `1.1.2+12`、`3dd4766`→`9a0885f`) | P1 → **P1**(ただし出艇条件ではない) | `gpx_export_service.dart:92` |
| 7.2後半 | スキーマ版・OSが書き出し時の値 | **事実**。`operatingSystemVersion` は `exportPlatformVersion`、`diagnosticPackageSchemaVersion` はハードコード、catalogVersion も現行アプリの定数 | P1 | `gpx_export_service.dart:93,126` |
| 7.3 | カタログが実ログに追いついていない | 事実だが**過小**。実ログ54種 vs カタログ21種(36種未記載)。現行コードは `use_navigator` だけで71種emit・60種未記載 | P1 → **P1(最優先で着手)** | 実測 |
| 7.4 | 他艇航跡を診断ZIPへ保存 | **過大**。5分類のうち3つは現行ログで判別できる(本書2.1はそれで判定した)。プライバシー負担と実装量に見合わない | P1 → **P3**(代替あり) | `position_processing_sample.otherBoatCount` / `other_boat_record_rejected` |
| 7.5 | 共有失敗の工程が粗い | 妥当。ただし `245eb79` で `failureKind` / `retryable` / `sharing_capability_*` が入り、粒度は上がっている。残る本命は「読み取り能力」 | P1 → **P2** | 本書2.1 |
| 7.5後半 | `serverTimeOffsetUpdatedAt` が常にnull | 事実。0が「差0」か「未取得」か区別できないのは本物の欠陥。**ただし修正は heartbeat に1フィールド足すだけ** | P1 → **P1(小)** | `use_navigator.dart:1110` |
| 7.6 | 上限到達時に重大イベントが消える | **過大**。実績最大8,435件/上限20,000、drop 0件。しかも `diagnosticEventDroppedCount` は heartbeat と manifest の両方に出るので「無言」ではない。航跡36,000点=10時間 | P2 → **P3** | `use_navigator.dart:401` |
| 7.7 | 匿名化の説明と実態の不一致 | **事実**。manifest は `session-local aliases only` と書くが、`RecordFault` の `boatIdHash` は生IDの SHA-256 先頭8桁で**セッションを跨いで安定**。`teamIdHash` も同様。events.jsonl は別名化を通らない | P2 → **P2(修正が3行)** | `message_service.dart:49` / `gpx_export_service.dart:146,226` |
| 7.8 | ファイルハッシュ | 妥当だが緊急性なし | P2 → P3 | – |
| 7.9 | 保存容量・保持期間 | 妥当だが緊急性なし | P2 → P3 | – |
| 7.10 | 利用者の問題マーカー | 価値はある。現場の記憶と時刻を結ぶ唯一の手段 | P2 → P3 | – |
| 7.11 | 警告エピソード評価 | 閾値調整の証拠にはなるが、いま先に効くのは `audioAnnouncementBudgetPerHour` の実測(既にログから出せる) | P2 → P3 | `log_config.dart:25` |
| 9.1 | 出艇前の二端末確認 | **妥当。そのまま実施すべき**。追加項目は下記 | P1 → **P0** | – |

原文の「誤指摘」は 5.5 の1件だけで、他は方向として正しい。品質は高い。

---

## 4. 原文が落としている論点

### 4.1 `useNavigator` にテストが1本もない

原文は「`retryPublishingSetup` の統合テストが確認できなかった」と書いているが、実態はもっと単純で、
`test/hooks/` に `use_navigator` を触るテストが**存在しない**。4,000行超の安全経路の中核が丸ごと未検証である。

全部をテストするのは非現実的なので、方針は**純Dartへ切り出して固定する**こと
(`sharing_capability_monitor.dart` が既にその型をやっている)。
再試行方針・能力判定・degraded起動の遷移をそこへ寄せれば、フックを起動せずに固定できる。

### 4.2 heartbeat に受信側の実績値がない

heartbeat には `positionSharingState` はあるが、**受信できている隻数がない**。
本書2.1の判定には `position_processing_sample`(10秒周期・条件付き)を使うしかなかった。
`otherBoatCount` / 直近の受理・棄却件数を heartbeat に足せば、7.4 の大部分は
他艇航跡を保存せずに達成できる。数行で済む。

### 4.3 「読み取り認可」の独立確認がない(本書2.1)

---

## 5. 実施順序

### Wave 0: 出艇前(コード変更なし)

原文 9.1 の二端末確認をそのまま実施する。**追加する確認項目**:

- 終了後に両端末の診断ZIPを取り、`position_processing_sample` の `otherBoatCount` が
  0 以外を含むこと(画面表示ではなく、内部入力が入っていた証拠)。
- heartbeat の `positionSharingState` が全期間 `healthy` であること。
- 本番RTDB Rules がリポジトリと一致すること(原文 9.2 のまま)。

### Wave 1: 半日でできる、効果の大きいもの

1. `permission-denied` を有限回再試行へ(本書2.2)+ 純Dartテスト
2. イベントカタログ完全性のCIテスト(コードの `appendRuntimeDiagnostic('…')` を正規表現で拾い、
   `diagnosticEventCatalog['eventTypes']` との差分を失敗にする)+ 60件の説明追記
3. heartbeat に受信実績(`otherBoatCount`・棄却件数)と
   `serverTimeOffset` の取得成功/失敗/フォールバックを追加
4. manifest に `gitCommitSha` / `buildTimestamp` / `buildFlavor` を追加し、
   OS版とスキーマ版を**航行時点で記録した値**へ切り替える

### Wave 2: 次の実機ログを取ってから

5. 自艇レコードのエコーによる読み取り能力の確認(本書2.1)
6. 匿名化の実態統一(`boatIdHash` にセッション別 salt を混ぜる。manifest の文言はそのまま正しくなる)
7. 再試行方針・能力判定の純Dart切り出しとテスト

### やらない(いま着手する理由がないもの)

- 他艇航跡の診断ZIP保存(7.4)— Wave 1-3 で代替できる
- ログ上限の優先度制御(7.6)— 実績が上限の42%、drop件数も残っている
- ファイルハッシュ・容量UI・問題マーカー・警告評価UI(7.8〜7.11)— 価値はあるが、
  いま増やすと Wave 1 の実機検証が薄まる

---

## 6. 本レビューでも確認していないこと

- 本番Firebaseに配備されているRulesの内容
- 署名済みArchive・TestFlight配布物
- 実際に水上で音が聞こえたか、警告位置が妥当だったか
- `2026-08-07` 以降の修正を含む実機ログ(**存在しない**。Wave 0 がそれを作る作業でもある)

コードとログで言えるのはここまでで、
**「他艇警告が実運用で機能する」ことは、まだどのログでも証明されていない。**
