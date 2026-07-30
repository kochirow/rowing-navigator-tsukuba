# 危険区域JSON反映手順（Codex用）

## 目的

座標プロットツールから出力した `sakuragawa_obstacles.json` を、旧座標の共有校正を誤適用せず、アプリ・生成定数・Firestore Rulesの契約を揃えて反映する。

この作業はJSONのコピーだけでは完了しない。少なくとも次を同時に扱う。

- 同梱JSON
- profile versionとSHA-256
- 校正可能なsource IDと頂点数
- 共有校正文書の世代
- Firestore Rules
- 運用対象水域
- プロットツールの既定versionと読込先
- 関連テスト

## 作業場所

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba'
```

## 受領時の原則

1. 最初に `git status --short --branch` を確認し、利用者の既存変更を把握する。
2. 入力JSONと `assets/data/sakuragawa_obstacles.json` のSHAを記録する。
3. 入力は `jq -e . <入力JSON>` で構文検証する。
4. ID、kind、頂点数、追加・削除ID、先頭末尾の重複を新旧比較する。
5. 通常の「JSON書出」より、プロットツールの「変更適用パッケージ」を優先する。パッケージがない場合は、通常JSONを候補としてCodex側で同等の検証を行う。
6. 入力ファイルそのものは変更しない。アプリへ入れるコピーだけを必要に応じて正規化する。

## 反映手順

### 1. プロットツール自身の検証を通す

`importProfileText()` と `validateProject()` を使い、少なくとも次を確認する。

- errorが0件
- ID重複がない
- 座標値が有限で緯度経度の範囲内
- polygonが自己交差していない
- 0.3m未満の隣接重複点がない
- 新しい対象水域が確認範囲チェック内

warningは機械的に無視しない。既存warningか、新JSONによって増えたwarningかを分ける。

閉じた基準線は「先頭点と同じ末尾点」を1個だけ持つ。完全に同一な閉じ点が末尾に2個ある場合は、余分な1点だけを除く。

### 2. profile versionを上げる

座標、頂点数、ID、危険区域の意味が変わる場合、入力JSONの `version` が旧版のままでも次の整数へ上げる。

同じversionのまま座標を変えると、旧座標に対する端末・チーム共有の頂点補正が新座標へ適用される危険がある。

次を同じ値にする。

- JSONの `version`
- `lib/config/hazard_profile_config.dart` の `currentHazardProfileDataVersion`
- `firestore.rules` の `data.baseProfileVersion`
- プロットツールの新規プロジェクト既定version

### 3. 運用対象水域を確認する

新しい危険区域を追加・移動した場合、`operationalCoveragePolygon` が生成後の全危険区域を含むか確認する。

```bash
flutter test --no-pub test/services/preset_obstacle_service_test.dart
```

「運用対象水域は同梱の全危険区域を内側に含む」が失敗した場合、危険区域を削らず、意図した運用範囲に合わせて対応水域を安全側に拡張する。点数や代表点を固定しているテストも意図した変更に更新する。

### 4. 生成定数を更新する

```bash
dart run tool/generate_hazard_constants.dart
```

このコマンドは次をJSONから生成する。

- `lib/models/shared_safety_calibration.g.dart`
- `firestore.rules` 内のsource ID allowlist
- 各source IDの頂点数制約

生成物は手編集しない。

### 5. SHA-256を同期する

JSONとversion・運用対象水域の修正がすべて終わってから実行する。

```bash
tool/update_hazard_profile_hash.sh
tool/update_hazard_profile_hash.sh --check
```

次のSHAが完全一致していることを確認する。

- `assets/data/sakuragawa_obstacles.json` の実SHA
- `lib/config/hazard_profile_config.dart`
- `firestore.rules`

`firestore.rules` のSHAはスクリプトでは自動更新されないため、明示的に同期する。

### 6. 共有校正文書を世代分離する

profile versionまたはSHAが変わる場合、旧プロフィール用のFirestore文書を新プロフィールの書込先として再利用しない。

- 旧文書は同じチームの端末が読める状態で残す。
- 旧文書へのcreate/update/deleteをRulesで禁止する。
- 新しい文書IDをアプリ・Rules・プロットツールで揃える。
- 新アプリは旧profileの頂点補正を引き継がない。
- 新文書がまだなければ、端末内の現行設定からrevision 1を作れるようにする。

Rules上で既存文書の `baseProfileVersion` と `baseProfileSha256` を変更不可にしている場合、同じ文書IDのままversion/hashだけ更新すると公開不能になるので注意する。

### 7. 検証する

```bash
dart run tool/generate_hazard_constants.dart --check
tool/update_hazard_profile_hash.sh --check
dart analyze lib test
flutter test --no-pub \
  test/hazard_profile_config_contract_test.dart \
  test/firebase_rules_contract_test.dart \
  test/models/shared_safety_calibration_test.dart \
  test/services/preset_obstacle_service_test.dart \
  test/services/shared_safety_calibration_service_test.dart

cd tool/obstacle-plotter
npm test
npm run build
cd ../..

flutter test --no-pub --reporter compact
git diff --check
```

全体テストに既存失敗がある場合は、対象テストを単独再実行し、今回の変更ファイル・実行経路との関係を根拠付きで分けて報告する。関連テスト成功を「全体テスト成功」と言い換えない。

### 8. Firestore Rulesを実環境へ反映する

`firestore.rules` を変更しただけでは本番へ反映されない。JavaとRules Emulatorが使える環境でRulesテストを通してから、利用者の承認を得てデプロイする。

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba'
firebase emulators:exec --only firestore,database \
  --project rowing-navigator-tsukuba \
  'cd firebase_rules_test && npm test'
firebase deploy --only firestore:rules --project rowing-navigator-tsukuba
```

RulesテストはFirestoreとRealtime Databaseを同じ
`initializeTestEnvironment()` で初期化するため、`--only firestore` ではなく
`--only firestore,database` とする。Firestoreだけを起動すると、
`The database emulator is not running` でテスト開始前に失敗する。

デプロイ前にFirebase Consoleで直接編集されたRulesとの差分がないか確認する。Codexは利用者の明示承認なしにデプロイしない。

### 9. 手動・実機確認

自動テストでは地図表示、実際のGPS位置、警告音、現地の水面側／陸側を証明できない。配布前に次を人が確認する。

1. 新しいアプリを実機へインストールする。
2. 通常地図で変更した岸・橋・島・流木が意図した場所に描画されることを確認する。
3. 追加した危険区域が運用対象水域内として扱われることを確認する。
4. 岸の水面側／陸側が逆転していないことを航空写真と現地で確認する。
5. 新プロフィールで旧頂点補正が適用されていないことを確認する。
6. 管理可能な端末から新しい共有設定を1回公開し、同じチームの別端末で取得できることを確認する。
7. 橋・岸・追加区域への接近時に、画面警告と録音音声が意図どおりであることを確認する。

## 2026-07-30反映の振り返り

入力:

- `/Users/gotoukousei/Downloads/sakuragawa_obstacles.json`
- 入力SHA: `e99b2bfe465f4ce424472b5549ebb4291681372525b21588e7e8031975620076`
- 入力version: 4

反映結果:

- profile versionを4から5へ更新
- 最終SHA: `15631cf1f94d0edf9c7608b85e16e7d29961a2fcc5d7c47c11976ac0988991da`
- 既存IDの削除なし
- `shore_bd39c863`（霞ヶ浦北岸、27点）を追加
- `bridge_suigo` の完全重複した余分な閉じ点1点を除去
- `shore_north` は153点から154点
- `shore_south` は107点から108点
- 運用対象水域を霞ヶ浦北岸と生成後の危険区域全体を含むよう東側へ拡張
- 校正対象は21件から22件
- 生成危険区域は318件から346件
- 旧profile v4用 `fixed_obstacle_calibrations_v3` を読み取り専用化
- profile v5用 `fixed_obstacle_calibrations_v4` を新設

検証:

- プロットツール: 17 tests passed、production build成功
- 関連Flutterテスト: 26 tests passed
- `dart analyze lib test`: No issues found
- 生成定数check: 成功
- profile SHA check: 成功
- 全Flutterテスト: 675件成功、1件失敗、1件skip。失敗は今回の座標反映経路外の `safety_orchestrator_test.dart` にある音声directive期待値
- Rules Emulator: FirestoreとRealtime Databaseを同時起動し、19件成功
- Firestore Rulesのデプロイ: 初回デプロイは成功。その後、Emulatorで発見した1000式上限対策をRulesへ加えたため、修正版の再デプロイが必要
- 実機・水上確認: 未実施

今回の主な教訓:

- 通常JSON書出では、座標を変更してもprofile versionが自動で上がらない。
- 閉じた基準線の末尾重複はツール検証で見逃す場合があるため、JSONを直接検査する。
- 新しい危険区域の追加時は、座標データだけでなく運用対象水域も更新対象になる。
- Rulesがbase version/hashの変更を禁止しているため、profile更新時は共有校正文書を別IDへ分ける必要がある。
- RulesテストはFirestoreとRealtime Databaseを同時起動する。さらに、Rulesのコンパイル成功だけでは1000式の実行時上限を検出できないため、正常なv4文書のcreate/updateまでEmulatorで通す。
- SHAはすべてのJSON修正を終えてから確定する。
