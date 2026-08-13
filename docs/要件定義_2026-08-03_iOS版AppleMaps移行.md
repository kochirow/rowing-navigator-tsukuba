# 要件定義・実装計画: iOS版の地図をApple Maps(MapKit)へ移行する

作成日: 2026-08-03
対象: **iOSの地図描画層のみ**。Androidは Google Maps のまま変更しない。
上位規範: [docs/DESIGN_PRINCIPLES.md](DESIGN_PRINCIPLES.md)(食い違ったらそちらが優先)
関連: [CLAUDE.md](../CLAUDE.md)

---

## 0. この文書の使い方

### 0.1 作業者への約束

1. **上から順に読み、順に実行する。** フェーズの「完了条件」を満たさないまま次のフェーズへ進まない。
2. **触ってよいファイルは第9章の一覧にあるものだけ。** 一覧に無いファイルを変更したくなったら、
   そこで手を止めて相談する。特に `lib/services/collision_risk_evaluator_service.dart`
   `lib/services/ship_domain_service.dart` `lib/utils/sat_algorithm.dart` など
   **衝突判定の中身には一切触らない**(理由は 5.3)。
3. **各フェーズの最後で必ず次を実行し、緑であることを確認してから進む。**

   ```bash
   dart analyze lib test && flutter test
   ```

   > `flutter analyze` はこの作業パス(日本語ディレクトリ)では必ずクラッシュする。
   > ローカルは `dart analyze lib test`、`flutter analyze` は CI で担保する。

4. **判断に迷ったら止めて質問する。** この文書に書いていないことは「やらない」が正解。
5. **1フェーズ = 1コミット**(または1PR)。まとめてコミットしない。切り戻しができなくなる。

### 0.2 用語

| 用語 | 意味 |
| --- | --- |
| Google Maps | 現在 iOS/Android 両方で使っている地図。Flutterパッケージは `google_maps_flutter` |
| Apple Maps / MapKit | Apple 純正の地図。iOS/macOS にのみ存在する。APIキー不要 |
| 描画層 | 地図に「何を描くか」をプラットフォームへ渡す部分。`lib/hooks/use_nav_map.dart` と3つの地図画面 |
| ジオメトリ層 | 衝突判定の中で座標・多角形を計算する部分。`lib/services/`・`lib/utils/` の純Dart |
| 中立型 | Google にも Apple にも依存しない、自前の描画記述クラス(`NavMarker` など)。本移行で新設する |
| アノテーション(Annotation) | MapKit でのマーカー相当。Google の `Marker` に対応する |
| 注記回転 | マーカー画像を艇の向きに合わせて回すこと。Google は標準機能、**MapKit には無い**(3.1) |

---

## 1. 目的とスコープ

### 1.1 何をするか(一文)

**iOS版アプリの地図表示を、Google Maps から Apple Maps(MapKit)へ置き換える。
安全機能(衝突警告・音声・位置共有・記録)の挙動は一切変えない。**

### 1.2 前提の確認(作業開始前に発注者へ確認すること)

本移行の動機は複数ありうる。**どれが目的かで「妥協してよい点」が変わる**ため、着手前に確認する。

| 想定される動機 | 該当する場合の優先事項 |
| --- | --- |
| Google Maps Platform の課金を減らしたい | 第7章 Phase 7(iOS から Google Maps SDK を完全に外す)まで実施する |
| iOS の見た目を純正に寄せたい | 3.2 の「意図的な差分」をユーザーへ説明する文面が要る |
| アプリサイズを減らしたい | Phase 7 必須。Phase 6 までではサイズは減らない(5.8) |
| Apple の審査・規約対応 | 具体的な指摘内容を先に確認する。本計画で足りるとは限らない |

> **重要**: iOS の地図表示だけを Apple Maps に変えても、`google_maps_flutter` を依存に残す限り
> **Google Maps iOS SDK はアプリに同梱されたまま**である。課金もサイズも減らない。
> これを解消するのは Phase 7(オプション)である。5.8 を必ず読むこと。

### 1.3 スコープ

**やる**

- iOS で `GoogleMap` ウィジェットの代わりに Apple Maps を表示する(3画面すべて)
- 艇マーカー・名前ラベル・危険区域ポリゴン・航跡ポリライン・円の描画
- カメラ追従(位置・方位・ズーム)、地図/航空写真の切替、現在地表示、タップ操作
- 描画層をプラットフォーム非依存の中立型へ置き換える(Android も同じ中立型を通る)
- iOS 起動時の Google Maps APIキー必須チェックの緩和(6.6)
- ドキュメント・ストア提出資料の記述更新(Phase 6)

**やらない(スコープ外)**

- Android の地図の変更(Google Maps のまま)
- 衝突判定・警告ロジック・音声・位置共有・練習ログの変更
- `LatLng` 型の自前型への置き換え(5.3 の理由により**明示的に見送る**)
- 危険区域データ(`assets/data/sakuragawa_obstacles.json`)の変更
- 新機能の追加、UIレイアウトの刷新
- 経路探索・住所検索・ジオコーディング(そもそも未使用)

---

## 2. 事前調査の結果(2026-08-03 時点の事実)

**この章は調査済みの事実である。作業者が調べ直す必要はない。**

### 2.1 現状の Google Maps 利用実態

`lib/` 配下で `package:google_maps_flutter` を import しているのは **39ファイル**。
ただしその大半は **`LatLng` を座標型として使っているだけ**で、地図描画とは関係がない。

| 区分 | ファイル数 | 内容 | 本移行での扱い |
| --- | --- | --- | --- |
| A. 描画層 | 9 | `GoogleMap` ウィジェット・`Marker`・描画用 `Polygon` などを扱う | **書き換える** |
| B. `LatLng` のみ | 24 | 座標型としてのみ使用(モデル・純Dartサービス・utils) | **触らない** |
| C. `Polygon` をジオメトリとして使用 | 4 | 衝突判定の内部で多角形の入れ物として使用 | **触らない**(5.3) |
| D. コメントに出てくるだけ | 2 | `map_render_update_policy.dart` ほか | **触らない**(文言のみ後で調整可) |

**A(書き換える9ファイル)**

| ファイル | 使っているもの |
| --- | --- |
| [lib/hooks/use_nav_map.dart](../lib/hooks/use_nav_map.dart) | `GoogleMapController` `Marker` `Polygon` `Polyline` `BitmapDescriptor` `CameraPosition` `CameraUpdate` `MapType` `InfoWindow` |
| [lib/screens/home_map_screen.dart:957](../lib/screens/home_map_screen.dart:957) | `GoogleMap` `CameraPosition` `MapType` `Polygon` `style` |
| [lib/screens/area_setting_screen.dart:301](../lib/screens/area_setting_screen.dart:301) | `GoogleMap` `Marker` `Polygon` `BitmapDescriptor.defaultMarkerWithHue` |
| [lib/screens/fixed_obstacle_calibration_screen.dart:944](../lib/screens/fixed_obstacle_calibration_screen.dart:944) | `GoogleMap` `Marker` `Polygon` `Polyline` `Circle` `zoomControlsEnabled` `padding` |
| [lib/hooks/use_coach_watch.dart:255](../lib/hooks/use_coach_watch.dart:255) | 航跡 `Polyline` の生成 |
| [lib/hooks/use_map_editor.dart:16](../lib/hooks/use_map_editor.dart:16) | 引数の `GoogleMapController?`(**受け取るだけで一度も使っていない**) |
| [lib/features/home_map/widgets/map_type_switcher.dart](../lib/features/home_map/widgets/map_type_switcher.dart) | `MapType` |
| [lib/utils/image2icon.dart](../lib/utils/image2icon.dart) | `BitmapDescriptor` を返す3関数 |
| [lib/services/safety_shape_overlay_service.dart](../lib/services/safety_shape_overlay_service.dart) | 開発者用オーバーレイの `Polygon` 生成(表示専用) |

**地図ウィジェットは3箇所しかない。** これが移行の実質的な作業量を決める。

**未使用の死んだAPI**(移行対象から外し、Phase 2 で削除してよい):
`useNavMap` の `createHiddenMarker` / `createPolygon` / `createPolyline` は
`use_nav_map.dart` の外から一度も呼ばれていない。

### 2.2 iOS で Apple Maps を出す手段の比較

pub.dev / GitHub の実測値(2026-08-03 取得)。

| 案 | パッケージ | 最終更新 | Dart 3 対応 | 最低iOS | 評価 |
| --- | --- | --- | --- | --- | --- |
| **案A** | `apple_maps_flutter` 1.4.0 (fluttercommunity) | 2025-01-23(**約19か月前**) | **× `sdk: >=2.14.0 <3.0.0`** | 12 | API が `google_maps_flutter` とほぼ1:1。ただし**そのままでは `pub get` に失敗する** |
| 案B | `mapkit_flutter` 0.3.6 (esenmx) | 2026-07-26(活発) | ○ `^3.10.0` / Flutter ≥3.41 | **17** | pub score 160/160。ただし like 1・30日DL 400 の新興、0.3系でAPI変動リスク。API 形が全く別で差分が大きい |
| 案C | `platform_maps_flutter` 2.0.0-beta | 2024-06-03(beta 止まり) | ○ `>=2.17.0 <4.0.0` | 12 | Android/iOS 統一API。**両OSの最小公倍数しか使えず Android が劣化する** |

**確定した事実(すべて実ソースで確認済み)**

- 案Aの `Annotation` には `rotation` も `flat` も**存在しない**。
  → 艇の向きを地図に描く手段がプラグイン側に無い(3.1)。
- 案Bの `mapkit_flutter` も「Annotation rotation は非対応」と README に明記。
  **→ 注記回転が無いのは MapKit 側の性質であり、どの案を選んでも自前対応が必要。**
- 案Aの `Polygon` / `Polyline` / `Circle` は
  `points` `strokeColor` `strokeWidth` `fillColor` `visible` `zIndex` `onTap` `consumeTapEvents`
  を持ち、**Google 版とほぼ同名同義**。
- 案Aの `AppleMapController` は
  `moveCamera` `animateCamera` `getZoomLevel()`(戻り値 `Future<double?>`)
  `getVisibleRegion` `getScreenCoordinate` `takeSnapshot` を持つ。
- 案Aの `AppleMap` は
  `initialCameraPosition` `mapType` `myLocationEnabled` `myLocationButtonEnabled`
  `padding` `minMaxZoomPreference` `rotateGesturesEnabled` `annotations` `polygons`
  `polylines` `circles` `onCameraMoveStarted` `onCameraMove` `onCameraIdle` `onTap` `onLongPress`
  を持つ。**現在使っている `GoogleMap` の引数はほぼ揃っている。**
- 案Aに `setMapStyle` 相当は**無い**。MapKit にスタイルJSONの概念が無い(3.2)。
- 案Bは最低 iOS 17。本アプリの現在の `IPHONEOS_DEPLOYMENT_TARGET` は **14.0** なので、
  案Bを選ぶと iOS 14〜16 の端末を切り捨てることになる。

### 2.3 決定: 案A(`apple_maps_flutter`)をリポジトリ内へ取り込んで使う

**採用理由**

1. API が `google_maps_flutter` の写しなので、**描画層の書き換えが機械的**になる。
   作業者の判断が要る箇所が最小になり、本要件の目的(誤りを起こさない)に最も適う。
2. 最低iOSを上げずに済む(現行 14.0 を維持でき、既存利用者を切らない)。
3. Dart 3 非対応という唯一の致命的欠点は、**pubspec の1行を書き換えるだけ**で解消する。
   ライセンスは BSD-2-Clause なので、著作権表示を保ったままリポジトリへ取り込んでよい。

**却下理由**

- 案B: 最低 iOS 17 は現時点で受け入れられない。加えて 0.3 系・like 1 は
  安全機能を載せる土台としては実績が薄い。**将来 iOS 17 が最低要件になった時点で再検討する。**
- 案C: 統一APIのために **Android 側の既存機能(注記回転・高コントラストスタイル)が失われる**。
  「動いているものを壊さない」に反する。

**取り込み方法**

`third_party/apple_maps_flutter/` へ vendoring(コピー配置)し、`pubspec.yaml` から
`path:` 依存で参照する。git 依存や fork リポジトリではなく vendoring にする理由は、
**パッチが本体と同じPRでレビューでき、外部リポジトリの消失に影響されないため**。

> 取り込み時は `LICENSE` と `AUTHORS` を必ず一緒にコピーし、削除しないこと。
> 変更点は `third_party/apple_maps_flutter/PATCHES.md` に必ず記録する(Phase 1)。

---

## 3. MapKit では原理的にできないこと

**ここが本移行の本体である。** 以下は「頑張れば直る」ものではなく、
仕様として代替策を決めておく必要がある。

### 3.1 【最重要】マーカー画像を地図に合わせて回転できない

**何が問題か**

現在、自艇・他艇は「艇首を向いた矢羽」で描かれている
([use_nav_map.dart:146](../lib/hooks/use_nav_map.dart:146))。

```dart
Marker(..., rotation: spec.heading, flat: true)
```

`flat: true` は「地図に貼り付いて一緒に回る」、`rotation` は「その向き」を意味する。
**MapKit のアノテーションはこの2つを持たない。** 画像は常に画面に対して正立する。

**これを放置すると何が起きるか**

すべての艇が同じ向きの矢羽になり、**他艇がこちらへ向かってくるのか離れていくのかが
画面から読めなくなる**。衝突警告の音は鳴るが、どちらを向けばよいかが分からない。
表示専用の情報ではあるが、警告時に「振り向く先」を決める唯一の視覚情報なので、
落としてはいけない(CLAUDE.md「種類ごとに別の音声を割り当てる=振り向く先を選べるように」と同じ趣旨)。

**採用する解決策: 画像を描く時点で回しておく(iOSのみ)**

矢羽は元々 Canvas で毎回描いている(`getBoatArrowBitmapDescriptor`)。
描画時に Canvas ごと回してから PNG 化すれば、回転済みの画像が得られる。

回す角度は **地図の向きを差し引いた相対角**である。

```
画像に与える回転角 = 艇の方位 - 地図カメラの方位   (0〜360 に正規化)
```

- 航行中は地図がヘディングアップ(カメラ方位 = 自艇の方位)なので、
  **自艇は常に 0度(画面上向き)**、他艇は「自艇から見た相対的な向き」になる。これは正しい表示である。
- 監視モードなど地図が北固定のときはカメラ方位が 0 なので、画像回転角 = 艇の方位。これも正しい。

**必ず守る実装条件**

| 条件 | 理由 |
| --- | --- |
| 回転角は **5度単位に量子化**してキャッシュキーに含める | 毎フレーム全艇分の PNG を描き直すと発熱・電池を食う。5度なら見た目に差が出ず、キャッシュは最大72通り |
| カメラ方位の変化が **3度未満なら再描画しない** | 追従中はカメラ方位が毎秒変わる。閾値なしだと毎秒全艇再描画になる |
| 画像の外接矩形は回転後も収まるサイズで確保する | 回すと対角線分だけ大きくなる。切れると矢羽が欠ける |
| **Android は従来どおり `rotation` + `flat` を使う** | 動いているものを変えない。回転済み画像は iOS 側のレンダラだけで作る |
| 回転の基準は「画像の中心」、アンカーは `Offset(0.5, 0.5)` を維持 | 中心以外で回すと艇の位置がずれる |

**名前ラベル(監視モードの艇名)は回さない。** 文字は常に正立が読みやすい。
アンカー `Offset(0.5, 1)` も維持する。

### 3.2 地図のスタイル(高コントラスト表示)が使えない

現在、直射日光下での視認性のために Google Maps のスタイルJSONを当てている
([map_style_config.dart](../lib/config/map_style_config.dart) の `highContrastMapStyle`、
[home_map_screen.dart:974](../lib/screens/home_map_screen.dart:974))。
**MapKit にスタイルJSONは無い。**

**Phase 6 までの扱い(受け入れる劣化)**

- iOS では高コントラスト切替を**設定画面から隠す**(トグル自体を出さない)。
  無効なトグルを残すと「押しても何も起きない」となり、利用者の信頼を損なう。
- 隠すのは iOS の通常地図のときだけ。航空写真では元々スタイルが効かないので差は出ない。

**Phase 7 以降の改善余地(任意・別PR)**

MapKit には JSON スタイルは無いが、同じ目的を果たす公式APIが2つある。
取り込んだプラグインへ Swift で 10〜20 行足せば実現できる。

| MapKit API | 効果 | 相当する現行スタイル |
| --- | --- | --- |
| `MKStandardMapConfiguration.emphasisStyle = .muted` | 地図の彩度を落とす | `saturation: -100` |
| `MKStandardMapConfiguration.pointOfInterestFilter = .excludingAll` | POI を消す | `featureType: poi → visibility off` |

**これは今回の必須要件ではない。** やるなら移行完了後、独立したPRで。

### 3.3 その他の差分(影響が小さいもの)

| 項目 | Google | Apple | 対応 |
| --- | --- | --- | --- |
| ズーム倍率 | `getZoomLevel()` → `double` | `getZoomLevel()` → `double?`(null あり) | null のときは直近値、無ければ 18.0 を使う。**null を 0 として扱わない**(艇が極大化する) |
| ズームの定義 | Web Mercator タイル倍率 | 地図領域から換算した近似値 | **倍率から実寸を逆算せず、`getScreenCoordinate` で実測する**(5.5) |
| ズームボタン | `zoomControlsEnabled` | 引数が無い(そもそも iOS の Google Maps にも無い) | 引数を渡さない。挙動は現状と同じ |
| 地図種別 | `MapType.normal` / `.hybrid` | `MapType.standard` / `.hybrid` | 中立型 `NavMapType.normal` / `.hybrid` で吸収 |
| 既定ピン | `BitmapDescriptor.defaultMarkerWithHue` | `BitmapDescriptor.defaultAnnotationWithHue` | 中立型 `NavIconSpec.hue()` で吸収 |
| PNG からの画像 | `BitmapDescriptor.bytes(bytes)` | `BitmapDescriptor.fromBytes(bytes)` | レンダラ内で吸収 |
| 描画順 | 未指定でも概ね追加順 | `zIndex` 未指定時の順序は保証されない | **すべての描画物に明示的な zIndex を与える**(5.6) |
| 吹き出し | `InfoWindow` | `InfoWindow`(同名) | そのまま |

---

## 4. 機能要件

### 4.1 絶対に壊してはいけないこと(受け入れ判定の前提)

以下は「地図が変わっても変わらない」ことを検証で示す。1つでも崩れたら移行は不合格。

1. **衝突リスク評価は毎秒実行され、送信間隔と独立である**(不変条件1)。
   地図の再描画が重くて評価が遅れる、ということが起きてはならない。
2. **航行開始を地図がブロックしない**(安全方針)。
   地図が描けなくても、警告・音声・位置共有・記録は継続する。
   Apple Maps の初期化に失敗しても `SafetyRunMode` は変化しない。
3. **地図描画は安全判定用の拡張を反映しない**(不変条件6)。
   `getShipDomains(headingReliable: true)` を使う現行の呼び出しを変えない。
4. **警告音の鳴り方は一切変わらない。** 提示ポリシー(バンド・連続音/断続音)に触れない。
5. **画面の常時点灯は航行中だけ。** `WakelockPlus` を呼ぶのは
   `lib/hooks/use_screen_wakelock.dart` だけ、という約束を破らない。
6. **他艇の警告状態は地図に描かない**(不変条件12)。
7. **`lib/config/` の設定値を勝手に変えない。** 描画の都合で警告距離等を触らない。

### 4.2 機能対応表(現行 → 移行後)

| # | 機能 | 現行(Google) | iOS移行後(Apple) | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 自艇マーカー(赤い矢羽) | `Marker` + `rotation`/`flat` | 回転済み画像のアノテーション | **同等**(3.1) |
| 2 | 他艇マーカー(青い矢羽) | 同上 | 同上 | **同等** |
| 3 | 艇名ラベル(監視) | `Marker`(正立) | アノテーション(正立) | 同等 |
| 4 | 船体領域・排他領域 | `Polygon` 線のみ | `Polygon` 線のみ | 同等 |
| 5 | 危険区域(約310枚) | `Polygon` 塗り+線 | `Polygon` 塗り+線 | 同等。**性能要検証**(8.3) |
| 6 | 航跡(監視) | `Polyline` | `Polyline` | 同等 |
| 7 | 校正画面の円・頂点 | `Circle` | `Circle` | 同等 |
| 8 | カメラ追従(位置/方位/ズーム) | `moveCamera` | `moveCamera` | 同等 |
| 9 | ジェスチャー検知→追従解除 | `onCameraMoveStarted`/`onCameraIdle` | 同名あり | 同等 |
| 10 | 地図/航空写真の切替 | `MapType.normal`/`hybrid` | `standard`/`hybrid` | 同等 |
| 11 | OS標準の現在地表示 | `myLocationEnabled` | 同名あり | 同等 |
| 12 | 地図タップで臨時区域を追加 | `onTap(LatLng)` | 同名あり | 同等 |
| 13 | ポリゴンタップで選択 | `Polygon.onTap` | 同名あり | 同等 |
| 14 | 高コントラスト表示 | スタイルJSON | **無い** | **iOSのみ機能削除**(3.2) |
| 15 | 地図パディング | `padding` | 同名あり | 同等 |
| 16 | ズームボタン非表示 | `zoomControlsEnabled: false` | 引数不要 | 同等 |

### 4.3 利用者から見える差分(リリースノートに書くこと)

iOS 版だけ、次が変わる。**隠さず明記する**(設計原則2「使い方は使い手が決める」)。

- 地図が Apple の地図になる。地名・道路・航空写真の見え方が Android と違う。
- **高コントラスト表示の切替が iOS では無くなる。**
- 航空写真の解像度・撮影時期が Google のものと異なる。
  → **桜川の橋・中州・岸の見え方が変わるため、座標校正画面での目視突き合わせに影響しうる。**
  現地検証(7.4)で必ず確認する。

---

## 5. 設計

### 5.1 レイヤー構成

```
  画面 / hooks         home_map_screen, area_setting_screen,
  (何を描くか)          fixed_obstacle_calibration_screen, use_coach_watch
        │
        │  中立型 (NavMarker / NavPolygon / NavPolyline / NavCircle / NavIconSpec)
        ▼
  useNavMap            描画物の集合を保持する。プラットフォームを知らない
        │
        ▼
  NavMapView           ← 新設。ここだけが分岐する
        ├─ Android → GoogleNavMapView  (google_maps_flutter)
        └─ iOS     → AppleNavMapView   (apple_maps_flutter)

  ── ここから下は今回一切触らない ───────────────────
  services / utils     LatLng・Polygon をジオメトリとして使う衝突判定
```

**この形にする理由**: 分岐点を1箇所(`NavMapView`)に閉じ込める。
画面側のコードには `if (Platform.isIOS)` を一切書かない。

### 5.2 新規ファイル(すべて新設。既存を壊さない)

```
lib/map/
  nav_map_types.dart        中立型の定義(NavMarker/NavPolygon/NavPolyline/NavCircle/NavMapType/NavCameraPosition)
  nav_icon_spec.dart        アイコンの「作り方」の記述(実体の画像は各レンダラが作る)
  nav_map_view.dart         NavMapView(公開ウィジェット)と NavMapController(抽象)。ここで分岐
  google_nav_map_view.dart  Android実装
  apple_nav_map_view.dart   iOS実装
  nav_icon_cache.dart       アイコン画像のキャッシュ(回転角を含むキー)
third_party/apple_maps_flutter/   取り込んだプラグイン(LICENSE 同梱、PATCHES.md 付き)
```

> ディレクトリを `lib/features/map/` ではなく `lib/map/` にする理由:
> これは画面機能ではなく、全画面が使う横断レイヤーだから。

### 5.3 【厳守】触ってはいけない層

`Polygon`(google_maps_flutter 由来)は、本アプリでは**2つの意味で使われている**。

| 用途 | 例 | 今回の扱い |
| --- | --- | --- |
| ① 判定用のジオメトリ(多角形の入れ物) | `ShipDomainService.getShipDomains()` の戻り値、`sat_algorithm.dart`、`collision_risk_evaluator_service.dart` | **絶対に触らない** |
| ② 地図へ渡す描画記述 | `navMap.setPolygons(...)` に渡す集合 | 中立型 `NavPolygon` へ置き換える |

**①を②へ変換するのは画面側の責任。** すでに現行コードがそうなっている
([home_map_screen.dart:813](../lib/screens/home_map_screen.dart:813) は
`futureShipBodyDomain.points` を取り出して描画用 `Polygon` を作り直している)。
この境界を維持すれば、衝突判定のコードは1行も変わらない。

**同じ理由で `LatLng` も自前型へ置き換えない。**
`LatLng` は `lib/` の 269 箇所、`test/` を含めればさらに多くで使われており、
その大半が衝突判定の中核である。Android が `google_maps_flutter` を使い続ける以上
このパッケージは依存に残るので、**`LatLng` を置き換える必要は無い**。
Apple 側の `LatLng` への変換は各レンダラの入口1箇所だけで行う。

> `LatLng` の自前型化は Phase 7(Google Maps SDK を iOS から完全に外す)を
> やる場合にのみ必要になる。その時に別要件として検討する。

### 5.4 中立型の定義(骨子)

```dart
// lib/map/nav_map_types.dart
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

enum NavMapType { normal, hybrid }

/// 地図へ渡すマーカーの記述。画像そのものは持たず「作り方」だけを持つ。
class NavMarker {
  final String id;
  final LatLng position;
  final NavIconSpec icon;
  /// 真北を0度とした艇の方位。回転しないマーカーでは 0 を入れる。
  final double headingDegrees;
  /// true なら「地図と一緒に回る」。Androidは flat+rotation、iOSは画像を回して実現する。
  final bool rotatesWithMap;
  final Offset anchor;
  final String? title;
  final String? snippet;
  final double alpha;
  final int zIndex;
  final VoidCallback? onTap;
  // == / hashCode は全フィールドで実装する(集合の差分検出に使うため)
}

class NavPolygon {
  final String id;
  final List<LatLng> points;
  final int strokeWidth;
  final Color strokeColor;
  final Color fillColor;
  final int zIndex;
  final bool consumeTapEvents;
  final VoidCallback? onTap;
}

class NavPolyline { final String id; final List<LatLng> points; final int width; final Color color; final int zIndex; }
class NavCircle   { final String id; final LatLng center; final double radius;
                    final int strokeWidth; final Color strokeColor; final Color fillColor;
                    final int zIndex; final bool consumeTapEvents; final VoidCallback? onTap; }

class NavCameraPosition { final LatLng target; final double bearing; final double zoom; }
```

```dart
// lib/map/nav_icon_spec.dart
sealed class NavIconSpec {}

/// 艇の矢羽。実寸(m)と縮尺(px/m)から描く。
class BoatArrowIconSpec extends NavIconSpec {
  final double lengthMeters, widthMeters, pixelsPerMeter;
  final Color color;
  final int minPixels;
}
/// 監視モードの艇名ラベル。
class NameLabelIconSpec extends NavIconSpec { final String label; }
/// 同梱PNG。矢羽が描けない端末のフォールバック。
class AssetIconSpec extends NavIconSpec { final String assetPath; final int widthPixels; }
/// 既定ピン(校正画面・区域編集画面で使用)。
class HueIconSpec extends NavIconSpec { final double hue; }
```

```dart
// lib/map/nav_map_view.dart
abstract class NavMapController {
  /// 表示倍率。取得できない場合は null。呼び出し側は直近値→18.0 の順にフォールバックする。
  Future<double?> getZoomLevel();
  /// 指定緯度における「端末物理px / メートル」。矢羽の実寸描画に使う。
  Future<double> pixelsPerMeterAt(LatLng position);
  Future<void> moveCamera(NavCameraPosition position);
  /// 直近のカメラ方位[度]。iOSの画像回転補正に使う。Androidは常に参照されない。
  double get cameraBearingDegrees;
}

class NavMapView extends StatelessWidget {
  // GoogleMap の現行引数に対応する引数を持つ
  // build() で Platform.isIOS ? AppleNavMapView(...) : GoogleNavMapView(...)
}
```

> `Platform.isIOS` の判定は `dart:io` ではなく
> `defaultTargetPlatform == TargetPlatform.iOS` を使う(`flutter test` で差し替えられるため)。

### 5.5 縮尺(pixelsPerMeter)の実装仕様

矢羽は「地図上の実寸」で描かれる。現在は Web Mercator の式で倍率から換算している
([map_render_update_policy.dart:125](../lib/services/map_render_update_policy.dart:125) `mapPixelsPerMeterAt`)。

**MapKit の「ズーム倍率」は Google のタイル倍率と定義が一致する保証が無い。**
式で換算すると、**艇のサイズが実際の縮尺とずれる**。艇の大きさは
「あと何mで届くか」を目で測る唯一の手がかりなので、ずれてはいけない。

**したがって iOS では倍率から換算せず、実測する。**

```
pixelsPerMeterAt(position):
  1. p1 = position
  2. p2 = position から真東へ 50m 進んだ点(既存の geo_math を使う)
  3. s1 = getScreenCoordinate(p1), s2 = getScreenCoordinate(p2)
  4. return (s1 と s2 の画面距離) / 50.0        ← 単位は Phase 0 で確定させる
  5. 取得失敗・非有限・0以下 なら従来の mapPixelsPerMeterAt() へ縮退する
```

- **50m にする理由**: 短すぎると画面座標の丸め誤差が効き、長すぎると画面外に出て精度が落ちる。
  川幅40〜50mと同程度で、常に画面内に収まる。
- `getScreenCoordinate` の戻り値が論理pxか物理pxかは **Phase 0 で実測して確定する**
  (`devicePixelRatio` を掛けるかどうかがここで決まる)。
- **毎フレーム呼ばない。** カメラ静止時にキャッシュし、ズーム変化時のみ更新する。
- Android は現行の `mapPixelsPerMeterAt()` のまま。**変更しない。**

### 5.6 描画順(zIndex)の仕様

現在、危険区域ポリゴンには zIndex を与えていない
(開発者オーバーレイだけが 28〜30 を使う)。MapKit では未指定時の重なり順が保証されないため、
**すべての描画物に明示的な zIndex を与える。** 値は Android でも同じものを使う
(Android の見え方は現状と変わらない範囲で決める)。

| 層 | zIndex | 内容 |
| --- | --- | --- |
| 危険区域(岸) | 10 | 面積が大きく背景に近い |
| 危険区域(その他: 橋・橋脚・中州・流木・臨時) | 12 | 岸より上 |
| 航跡ポリライン | 15 | 区域の上 |
| 船体領域・排他領域(予測) | 20 | 線のみ。区域の上 |
| 開発者オーバーレイ | 28〜30 | 現行のまま |
| 艇マーカー | 40 | 常に最前面 |
| 艇名ラベル | 41 | 艇マーカーの上 |

> **岸を最下層にするのは意味がある。** release で約310枚になる岸の長方形が
> 流木・中州の上に来ると、本当に避けたいものが隠れる(CLAUDE.md の色分けと同じ趣旨)。

### 5.7 レンダラの責務(Apple 側)

`AppleNavMapView` は次だけを行う。**判断ロジックを持たない。**

1. 中立型 → `apple_maps_flutter` の型へ変換する
2. `NavIconSpec` + 回転角 → `BitmapDescriptor` を作る(`nav_icon_cache.dart` を経由)
3. `onCameraMove` でカメラ方位を保持し、3度以上変化したらマーカーを作り直す
4. `LatLng` を google 版 ↔ apple 版で相互変換する
5. **失敗しても例外を画面へ伝播させない。** 変換に失敗した1件は描かずに飛ばし、残りを描く
   (設計原則1「機能を止めない」)

### 5.8 Google Maps SDK は iOS から消えない(重要な注意)

`google_maps_flutter` を依存に残す限り、その iOS 実装
(`google_maps_flutter_ios` → `GoogleMaps` 8.4.0 CocoaPod)は
**Apple Maps に切り替えた後も iOS ビルドへリンクされ続ける**。

- アプリサイズは**減らない**(むしろ Apple 側プラグインの分だけ僅かに増える)
- ただし `GoogleMap` ウィジェットを一度も生成しなければ **Google Maps API の課金は発生しない**
  (Maps SDK for iOS は地図の表示時に課金対象となるため)

Phase 6 までの完了時点でこの状態になる。サイズまで削るなら Phase 7 が必要で、
その場合は `LatLng` の自前型化まで踏み込むことになる(5.3)。**別要件として扱う。**

---

## 6. 作業手順

### Phase 0: 事前検証(スパイク) — 半日〜1日

**目的**: 「そもそも動くのか」を、本体を1行も変えずに確かめる。
**ここで詰まったら、この計画全体を見直す。先へ進まない。**

1. 使い捨てのブランチを切る。

   ```bash
   git switch -c spike/apple-maps-feasibility
   ```

2. `apple_maps_flutter` 1.4.0 を `third_party/apple_maps_flutter/` へ取り込む
   (`git clone` → `.git` を削除 → 配置。`LICENSE` は必ず残す)。
3. `third_party/apple_maps_flutter/pubspec.yaml` の SDK 制約を書き換える。

   ```yaml
   environment:
     sdk: ">=3.0.0 <4.0.0"
     flutter: ">=3.10.0"
   ```

4. ルートの `pubspec.yaml` へ path 依存を足す。

   ```yaml
   dependencies:
     apple_maps_flutter:
       path: third_party/apple_maps_flutter
   ```

5. `flutter pub get` → `cd ios && pod install` が通ることを確認する。
6. **確認用の捨て画面を1つ作り**、次の6点を実機(または iOS シミュレータ)で確かめる。
   スクリーンショットを `docs/work_logs/` へ残す。

   | # | 確認項目 | 判定基準 |
   | --- | --- | --- |
   | 0-1 | `AppleMap` が表示される | 桜川周辺(36.09, 140.19 付近)が出る |
   | 0-2 | Flutter 3.44.5 / 現行 Xcode でビルドが通る | 警告は可、エラー不可 |
   | 0-3 | ポリゴン100枚以上を描いても操作が滑らか | パン/ズームで目に見える引っかかりが無い |
   | 0-4 | `getZoomLevel()` が非nullを返す | 値を記録する |
   | 0-5 | **`getScreenCoordinate()` の戻り値の単位** | 論理pxか物理pxかを確定させ、文書へ追記する(5.5) |
   | 0-6 | `moveCamera` で方位(heading)が変わる | 地図が回る |

7. **危険区域310枚の実データで 0-3 を再確認する。**
   `assets/data/sakuragawa_obstacles.json` を読ませ、実際の枚数で描く。

**完了条件**: 0-1〜0-7 がすべて合格し、`getScreenCoordinate` の単位が確定している。
**失敗時**: 表示できない/性能が足りない場合は、案B(`mapkit_flutter`、ただし iOS 17 以上)へ
方針変更するか、移行そのものを見送るかを発注者と決める。**独断で進めない。**

---

### Phase 1: プラグインの取り込みを本編へ入れる — 半日

1. Phase 0 のブランチを捨て、正式ブランチを切る。

   ```bash
   git switch main && git switch -c feature/ios-apple-maps
   ```

2. `third_party/apple_maps_flutter/` を配置する(Phase 0 と同じ手順)。
3. `third_party/apple_maps_flutter/PATCHES.md` を作り、**上流からの変更点を全部書く**。

   ```markdown
   # 上流からの変更点
   取り込み元: https://github.com/fluttercommunity/apple_maps_flutter (v1.4.0, 2025-01-23)
   ライセンス: BSD-2-Clause(LICENSE をそのまま同梱)

   ## 1. pubspec.yaml の SDK 制約を Dart 3 対応へ
   - before: sdk: ">=2.14.0 <3.0.0"
   - after:  sdk: ">=3.0.0 <4.0.0"
   - 理由: 本アプリは Dart 3.12 系。上流は 2025-01 以降更新が無く、対応版が出ていない。
   ```

4. `pubspec.yaml` に path 依存を追加。
5. `analysis_options.yaml` で `third_party/` を解析対象から除外する
   (取り込んだコードの lint 違反で CI が落ちるのを避ける)。

   ```yaml
   analyzer:
     exclude:
       - third_party/**
   ```

6. `.github/workflows/ci.yml` は変更不要(`flutter analyze` は `lib`/`test` を見る)。
   ただし **Phase 1 の時点で CI を1回通す**。

**完了条件**: `dart analyze lib test` と `flutter test` が緑。
Android ビルドが従来どおり通る。iOS ビルドが通る。**アプリの見た目は一切変わっていない。**

---

### Phase 2: 中立型を導入する(まだ iOS を切り替えない) — 2〜3日

**このフェーズが最も分量が多い。しかし作業は機械的である。**
**この時点では Android も iOS も Google Maps のまま動く。** 見た目が変わったら失敗。

1. `lib/map/nav_map_types.dart` と `lib/map/nav_icon_spec.dart` を作る(5.4 の骨子どおり)。
   - `==` と `hashCode` を**全フィールドで**実装する。忘れると再描画が止まらなくなる。
2. `lib/map/nav_map_view.dart` に `NavMapController`(抽象)と `NavMapView` を作る。
   **この時点では中身は `GoogleNavMapView` を返すだけでよい。**
3. `lib/map/google_nav_map_view.dart` を作り、現行 `GoogleMap` の設定を丸ごと移す。
   中立型 → google 型の変換もここに書く。
4. `lib/utils/image2icon.dart` の3関数を、**`BitmapDescriptor` ではなく `Uint8List` を返すよう変更**する。
   - `getBoatArrowBitmapDescriptor` → `renderBoatArrowPng({..., double rotationDegrees = 0})`
     - **回転引数をこの時点で足しておく**(iOS 実装で必要になる。Android は 0 のまま呼ぶ)
     - 回転後も切れないよう、キャンバスサイズは対角線基準で確保する
   - `getBitmapDescriptorFromAssetBytes` → `renderAssetPng`
   - `getNameLabelBitmapDescriptor` → `renderNameLabelPng`
   - `BitmapDescriptor` へ包むのは各レンダラの仕事にする
5. `lib/hooks/use_nav_map.dart` を中立型へ書き換える。
   - `GoogleMapController?` → `NavMapController?`
   - `Set<Marker>` → `Set<NavMarker>`、`Polygon`→`NavPolygon`、`Polyline`→`NavPolyline`、`Circle`→`NavCircle`
   - `MapType` → `NavMapType`
   - **未使用の `createHiddenMarker` / `createPolygon` / `createPolyline` は削除する**(2.1)
   - `renderBoatMarkers` の差分キャッシュ・世代ゲート(`LatestMapRenderGate`)の仕組みは**そのまま維持**する
   - 縮尺は `controller.pixelsPerMeterAt(...)` を使う形にする(Google 実装は従来式を返す)
6. 呼び出し側を順に直す。**1ファイルずつ、直すたびに `dart analyze lib test` を回す。**
   1. [lib/features/home_map/widgets/map_type_switcher.dart](../lib/features/home_map/widgets/map_type_switcher.dart) — `MapType` → `NavMapType`
   2. [lib/hooks/use_coach_watch.dart:255](../lib/hooks/use_coach_watch.dart:255) — 航跡 `Polyline` → `NavPolyline`(zIndex 15)
   3. [lib/hooks/use_map_editor.dart:16](../lib/hooks/use_map_editor.dart:16) — **未使用の引数 `GoogleMapController?` を削除**する
   4. [lib/services/safety_shape_overlay_service.dart](../lib/services/safety_shape_overlay_service.dart) — 戻り値を `Set<NavPolygon>` へ。**中の計算は触らない**
   5. [lib/screens/home_map_screen.dart](../lib/screens/home_map_screen.dart) — `GoogleMap` → `NavMapView`、描画用 `Polygon` → `NavPolygon`(zIndex を 5.6 に従って付与)
   6. [lib/screens/area_setting_screen.dart](../lib/screens/area_setting_screen.dart) — 同上。`defaultMarkerWithHue` → `HueIconSpec`
   7. [lib/screens/fixed_obstacle_calibration_screen.dart](../lib/screens/fixed_obstacle_calibration_screen.dart) — 同上。`Circle` → `NavCircle`
7. テストを直す。
   - [test/services/safety_shape_overlay_service_test.dart](../test/services/safety_shape_overlay_service_test.dart) — 型名の追随のみ
   - [test/screens/fixed_obstacle_calibration_screen_test.dart](../test/screens/fixed_obstacle_calibration_screen_test.dart) — 同上
   - **他のテスト(衝突判定・警告・音声)は1行も変えない。変える必要が出たら設計が間違っている。**
8. 中立型そのものの新規テストを追加する(7.1 参照)。

**完了条件**

- `dart analyze lib test` と `flutter test` が緑
- **Android 実機で、移行前とまったく同じ表示・同じ挙動**(艇の向き・区域の色・航跡・追従)
- iOS 実機でも移行前と同じ(まだ Google Maps のまま)
- `lib/screens/` `lib/hooks/` から `import 'package:google_maps_flutter/...'` が消えている
  (`LatLng` だけが必要なファイルは `lib/map/nav_map_types.dart` 経由で受け取る)

---

### Phase 3: Apple レンダラを実装する — 2〜3日

**まだ切り替えない。** `AppleNavMapView` を作るが、`NavMapView` は Google を返したままにする。

1. `lib/map/nav_icon_cache.dart` を作る。
   - キー: `種別 + サイズ + 色 + pixelsPerMeter(小数4桁) + dpr(小数2桁) + 回転角(5度単位)`
   - 値: `Future<Uint8List>`
   - **失敗した Future はキャッシュから外す**(現行 `use_nav_map.dart:78` と同じ方針)
   - 上限を設ける(例: 512件、LRU)。回転角を含むためキーが増えやすい
2. `lib/map/apple_nav_map_view.dart` を作る。
   - 中立型 → apple 型の変換
   - `LatLng` の相互変換(1関数に閉じる)
   - `onCameraMove` でカメラ方位を保持。**3度以上変化したときだけ**マーカー再生成を要求する
   - `rotatesWithMap == true` のマーカーは、`(headingDegrees - cameraBearing)` を
     0〜360 に正規化し 5度単位へ量子化した角度で画像を描く(3.1)
   - `pixelsPerMeterAt` を `getScreenCoordinate` の実測で実装(5.5)。
     失敗時は `mapPixelsPerMeterAt()` へ縮退
   - `getZoomLevel()` の null 対策(3.3)
   - 変換失敗は握りつぶして**その1件だけ描かない**(5.7)
3. **単体テストを書く**(実機なしで検証できる部分)。
   - 回転角の計算: 艇方位 350度・カメラ方位 10度 → 340度、5度量子化 → 340度
   - 量子化: 342度 → 340度、343度 → 345度
   - 正規化: 負の角・360超が 0〜360 に収まる
   - 中立型 → apple 型変換の全フィールド一致
   - `getScreenCoordinate` が null を返したときに従来式へ縮退する

**完了条件**: `dart analyze lib test`・`flutter test` が緑。`AppleNavMapView` は
まだどこからも使われていないが、テストで論理が検証されている。

---

### Phase 4: iOS を切り替える — 半日

1. `lib/map/nav_map_view.dart` の分岐を有効にする。

   ```dart
   @override
   Widget build(BuildContext context) {
     if (defaultTargetPlatform == TargetPlatform.iOS) {
       return AppleNavMapView(...);
     }
     return GoogleNavMapView(...);
   }
   ```

2. iOS の高コントラスト切替を隠す(3.2)。
   - `home_map_screen.dart` の `style:` 相当の指定を Google 実装側だけに残す
   - 設定UIのトグルを `defaultTargetPlatform != TargetPlatform.iOS` の条件で出す
   - **トグルを無効表示にするのではなく、項目ごと出さない**
3. iOS シミュレータで起動し、3画面すべてが表示されることを確認する。

**完了条件**: iOS シミュレータで地図が Apple Maps になり、
**Android は 1ピクセルも変わっていない**(Phase 2 完了時のスクリーンショットと突き合わせる)。

---

### Phase 5: iOS 固有の作り込みと調整 — 1〜2日

1. **矢羽の実寸を合わせる**(5.5)。
   校正画面で既知サイズの区域(橋の幅など)と艇マーカーを並べ、比率が Android と一致するか確認する。
2. **描画順を確認する**(5.6)。岸の上に流木・中州・艇が出ているか。
3. **回転の追従を確認する**。地図を手で回したとき、艇の向きが地図と一緒に回るか。
   カメラ方位が変わっても艇が「実際に向いている方角」を指し続けること。
4. **性能を測る**。8.3 の基準で判定する。足りなければ 8.3 の対策を順に適用する。
5. **タップ操作を確認する**。区域編集画面のポリゴンタップ・地図タップが効くか。

**完了条件**: 7.2 と 7.3 の全項目に合格。

---

### Phase 6: 後始末(コード・ドキュメント・提出資料) — 半日

1. **iOS 起動時の Google Maps APIキー必須チェックを緩和する。**
   [ios/Runner/AppDelegate.swift:15](../ios/Runner/AppDelegate.swift:15) は現在、
   キーが無いと `preconditionFailure` で**アプリを落とす**。
   iOS が Apple Maps になった後は、キーが無くても起動できなければならない
   (設計原則1「機能を止めない」)。

   ```swift
   // Apple Maps へ移行したため、iOS では Google Maps API キーは不要。
   // 将来 Google Maps へ戻す可能性を残し、キーがあれば従来どおり渡す。
   if let apiKey = Env.googleMapApiKey {
     GMSServices.provideAPIKey(apiKey)
   }
   // キーが無くても起動を止めない。iOS の地図は MapKit で描く。
   ```

   > `Info.plist` の `GMSApiKey`(`$(GOOGLE_MAPS_API_KEY)`)と
   > `ios/Flutter/Secrets.xcconfig` の仕組みは**そのまま残す**。消すのは Phase 7。

2. **ドキュメントを更新する。**

   | ファイル | 更新内容 |
   | --- | --- |
   | [README.md:87](../README.md:87) | iOS の Google Maps キー設定を「Android のみ必須。iOS は Apple Maps のため不要(設定があれば従来どおり使う)」へ |
   | [CLAUDE.md](../CLAUDE.md) | アーキテクチャ表へ `lib/map/` を追加。地図がプラットフォームで分かれることを明記 |
   | [docs/DESIGN.md](DESIGN.md) | 地図まわりの記述を更新 |
   | 本書 | Phase 0 で確定した `getScreenCoordinate` の単位を 5.5 へ追記 |

3. **ストア・法務資料を更新する。** iOS が Google のサービスへ地図データを取りに行かなくなるため、
   第三者提供の記載が変わる。

   次のコマンドで「Google」に言及している提出資料を洗い出し、**1件ずつ実態と合っているか確認する**。

   ```bash
   grep -rln -i "google" docs/store/*.md
   ```

   2026-08-03 時点で該当するのは次の9件。iOS の地図提供元に触れている箇所だけを直す
   (Firebase / Google Play に関する記述は**変更しない**)。

   | ファイル | 確認事項 |
   | --- | --- |
   | [docs/store/データ取扱い台帳.md](store/データ取扱い台帳.md) | iOS 版の地図提供元を Apple へ。第三者提供の記載 |
   | [docs/store/プライバシーポリシー案.md](store/プライバシーポリシー案.md) | 同上 |
   | [docs/store/Privacy Policy Draft.md](store/Privacy%20Policy%20Draft.md) | 同上(英語版) |
   | [docs/store/ストア掲載・審査資料案.md](store/ストア掲載・審査資料案.md) | 使用SDK・第三者サービスの一覧 |
   | [docs/store/サポートページ案.md](store/サポートページ案.md) | 地図の説明 |
   | [docs/store/Support Page Draft.md](store/Support%20Page%20Draft.md) | 同上(英語版) |
   | [docs/store/公開前チェックリスト_2026-07-20.md](store/公開前チェックリスト_2026-07-20.md) | iOS の地図キー確認項目 |
   | [docs/store/無料枠・可用性検証_2026-07-21.md](store/無料枠・可用性検証_2026-07-21.md) | Maps SDK for iOS の課金見積り(**iOS 分が消える**) |
   | [docs/store/公開候補_実機試験記録.md](store/公開候補_実機試験記録.md) | 過去の記録。**書き換えず、追記で iOS が Apple Maps になった旨を残す** |

   > **この更新は法務的な意味がある。** 実態と食い違ったまま提出しない。

4. **リリースノートに 4.3 の差分を書く。**

**完了条件**: CI が緑。上記すべてが更新済み。

---

### Phase 7(任意・別要件): iOS から Google Maps SDK を外す

**Phase 6 までではアプリサイズも Google の依存も減らない**(5.8)。
本当に外すなら、`google_maps_flutter` への依存自体を切る必要があり、
そのためには `LatLng` を自前型へ置き換える大規模変更(269箇所以上)が要る。

**これは今回やらない。** やるなら独立した要件定義を書き、
衝突判定のテストを全件通すことを合格条件にする。

まず現状のサイズを測り、判断材料にする。

```bash
flutter build ios --release --analyze-size
```

---

## 7. 検証

### 7.1 自動テスト(必須)

**既存テストは1件も落としてはならない。** 型追随以外の修正が必要になったら設計が間違っている。

新規に追加するテスト:

| 対象 | 検証内容 |
| --- | --- |
| `NavMarker` ほか中立型 | `==`/`hashCode` が全フィールドを見ている。1フィールドだけ違う2件が等しくならない |
| 回転角の計算 | 艇方位−カメラ方位の正規化(負・360超)、5度量子化の境界(342→340, 343→345) |
| zIndex の割当 | 岸 < その他区域 < 航跡 < 予測領域 < 艇マーカー の順序が保たれる |
| 縮尺の縮退 | `getScreenCoordinate` が null / 非有限 / 0 を返したとき `mapPixelsPerMeterAt()` の値になる |
| ズーム倍率の縮退 | `getZoomLevel()` が null のとき直近値→18.0 の順で使われ、**0 にはならない** |
| 中立型→apple型変換 | 全フィールドが正しく写る。points の順序が保たれる |
| 中立型→google型変換 | 同上(Android の無回帰を型レベルで担保する) |

```bash
dart analyze lib test && flutter test
```

### 7.2 iOS シミュレータで確認すること

| # | 項目 | 合格基準 |
| --- | --- | --- |
| S-1 | ホーム地図が表示される | 桜川が Apple の地図で出る |
| S-2 | 危険区域が色分けされて出る | 岸・橋・中州・流木の色が Android と同じ |
| S-3 | 岸が他の区域を隠さない | 流木・中州が岸の上に見える |
| S-4 | 地図/航空写真の切替 | 両方に切り替わる |
| S-5 | 区域編集画面のポリゴンタップ | 選択状態になる |
| S-6 | 区域編集画面の地図タップ | 臨時区域の追加ダイアログ/保存が動く |
| S-7 | 座標校正画面 | ポリゴン・線・円・頂点がすべて出る |
| S-8 | 高コントラスト設定が iOS に無い | 設定画面に項目が出ない |
| S-9 | 位置情報を拒否した状態で起動 | 起動を妨げない。地図が出なくても落ちない |

### 7.3 実機(卓上)で確認すること

シミュレータでは GPS・方位・性能が測れない。**必ず実機で行う。**

| # | 項目 | 合格基準 |
| --- | --- | --- |
| R-1 | 自艇の矢羽が出る | 赤い矢羽が現在地に出る |
| R-2 | 端末を回すと矢羽の向きが追従する | 実際の向きと一致する。逆向き・90度ずれが無い |
| R-3 | 追従中は自艇が常に画面上向き | ヘディングアップが Android と同じ |
| R-4 | 地図を手で回しても矢羽が実方位を指す | **3.1 の回転補正の検証。最重要** |
| R-5 | 2台で他艇が見える | 相手の矢羽が相手の向きで出る |
| R-6 | 追従解除→3秒で自動復帰 | `mapAutoRecenterDelay` どおり |
| R-7 | ズームすると矢羽の実寸が変わる | Android と同じ縮尺感。**橋の幅と比べて破綻しない** |
| R-8 | 警告音が従来どおり鳴る | 地図を変えても鳴り方が変わらない |
| R-9 | 30分連続で発熱・電池が悪化しない | 8.3 の基準 |
| R-10 | GPS を切っても地図以外が継続する | 警告・記録・共有が止まらない |
| R-11 | iOS 14 相当の古い端末で動く | 対象最低OSで確認する |

### 7.4 現地(桜川)で確認すること

**テストでは証明できないものだけをここで見る。**

| # | 項目 | 見るべきこと |
| --- | --- | --- |
| F-1 | 航空写真の見え方 | Apple の航空写真で橋・中州・岸が判別できるか。**判別できないなら座標校正画面は Google のままにする判断もありうる** |
| F-2 | 直射日光下の視認性 | 高コントラストが無い状態で、危険区域の赤が地図に埋もれないか。埋もれるなら 3.2 の Phase 7 改善を前倒しする |
| F-3 | 橋の下での挙動 | GPS 欠測時に地図が固まらない。警告は従来どおり |
| F-4 | 対向艇とのすれ違い | 相手の矢羽の向きが実際と合っている |
| F-5 | 8艇以上の同時表示 | 描画が追従を妨げない |
| F-6 | 危険区域の位置ずれ | Apple の地図上で、区域が実際の岸・橋と合っているか。**ずれるなら座標ではなく地図側の測地系/描画の問題を疑う** |

### 7.5 合格基準(これを満たさなければリリースしない)

1. 7.1 の自動テストが全件緑
2. 7.2 / 7.3 の全項目が合格
3. 7.4 の F-1・F-2・F-4・F-6 が合格
4. **Android の表示・挙動が移行前と一致**(スクリーンショット突き合わせ)
5. 4.1 の「絶対に壊してはいけないこと」7項目がすべて維持されている

---

## 8. リスクと対策

### 8.1 プラグインが実質メンテナンスされていない

**事実**: `apple_maps_flutter` は 2025-01 が最終更新、issue 48件。

**対策**

- リポジトリ内へ vendoring するので、上流が消えてもビルドは壊れない
- 変更点は `PATCHES.md` に必ず記録し、誰でも追えるようにする
- Flutter の破壊的変更で壊れた場合、**自分たちで直せる範囲**であることを Phase 0 で確認する
- 将来 iOS 17 が最低要件になったら `mapkit_flutter` への再移行を検討する
  (中立型を通しているので、置き換えるのは `lib/map/apple_nav_map_view.dart` の1ファイル)

### 8.2 回転補正のバグで艇の向きが誤って表示される

**影響**: 表示専用なので衝突判定は汚れない。しかし **警告時に振り向く先を誤らせる**。

**対策**

- Phase 3 で回転角の計算を純Dartの単体テストで固める(実機不要)
- R-4(地図を手で回しても実方位を指す)を必須項目にする
- **万一自信が持てないときは、艇の向きが不確かなら矢羽を回さず円で描く**という
  縮退を入れてもよい(不変条件10「方向は表示専用」と同じ考え方: 誤った側へ振り向かせるより出さない)

### 8.3 描画性能(危険区域 約310枚 + 艇 最大12隻)

**基準**

- 追従中(毎秒のカメラ更新)に地図がカクつかない
- 30分連続でサーマル状態が `serious` に達しない
  (`lib/services/device_runtime_diagnostics_service.dart` で観測できる)
- **リスク評価が毎秒実行され続ける**(不変条件1)。ここが崩れたら即時に対策する

**足りないときの対策(この順に適用する)**

1. すべての描画物に zIndex を付ける(5.6。順序解決のコストが下がる)
2. **表示中の領域 + 余白 200m の外にある危険区域を描かない**
   (`getVisibleRegion()` で判定。**表示だけの間引きであり、判定対象からは絶対に外さない**)
3. 岸の長方形を、隣接するものだけ結合して枚数を減らす(表示専用)
4. 予測領域のサンプル数を減らす(`shipDomainMaxSamplesPerBoat`。**iOS の表示だけ**)

> **2〜4 はいずれも「表示の間引き」である。**
> `navigator.obstacles` そのものを減らしてはいけない。減らした瞬間、
> 画面外の橋脚が衝突判定から消える(不変条件: 地図描画は安全判定に影響しない、の逆方向の違反)。

### 8.4 縮尺のずれで艇が実寸と違う大きさになる

**影響**: 艇の大きさは「あと何mで届くか」を目で測る手がかり。ずれると距離感を誤らせる。

**対策**: 5.5 の実測方式。R-7 と F-6 で検証。

### 8.5 iOS だけ回帰し、Android を巻き添えにする

**対策**

- Phase 2 完了時点で Android のスクリーンショットを撮り、Phase 4 以降で毎回突き合わせる
- Google 実装(`GoogleNavMapView`)は Phase 2 で作った後**一切変更しない**
- 中立型→google 型変換のテストを書く(7.1)

### 8.6 Apple の航空写真が座標校正に使えない

**影響**: 座標校正画面([fixed_obstacle_calibration_screen.dart](../lib/screens/fixed_obstacle_calibration_screen.dart))は
航空写真と航跡を突き合わせて橋脚などの座標を合わせる、精度に直結する画面。

**対策**: F-1 で判定する。使えないと判断したら、
**この画面だけ Google Maps のまま残す**という選択肢を持っておく
(`NavMapView` に「この画面は Google を使う」という明示フラグを追加すれば済む)。
安全に関わる作業画面なので、見た目の統一より精度を優先する。

### 8.7 作業中に安全経路を壊す

**対策**: 第9章の一覧外を触らない。特に次を変更したら**必ず差し戻す**。

- `lib/services/collision_risk_evaluator_service.dart`
- `lib/services/ship_domain_service.dart`
- `lib/services/continuous_collision_service.dart`
- `lib/services/safety_orchestrator.dart`
- `lib/services/alert_state_machine.dart`
- `lib/config/` 配下の警告設定値
- `assets/data/sakuragawa_obstacles.json`

移行完了後、リリース前に安全レビューを1回通すこと。

---

## 9. 影響ファイル一覧(作業チェックリスト)

### 9.1 新規作成

- [ ] `third_party/apple_maps_flutter/`(LICENSE 同梱、`PATCHES.md` 付き)
- [ ] `lib/map/nav_map_types.dart`
- [ ] `lib/map/nav_icon_spec.dart`
- [ ] `lib/map/nav_map_view.dart`
- [ ] `lib/map/google_nav_map_view.dart`
- [ ] `lib/map/apple_nav_map_view.dart`
- [ ] `lib/map/nav_icon_cache.dart`
- [ ] `test/map/nav_map_types_test.dart`
- [ ] `test/map/apple_nav_map_conversion_test.dart`(回転角・量子化・縮退を含む)
- [ ] `test/map/google_nav_map_conversion_test.dart`

### 9.2 変更(描画層のみ)

- [ ] `pubspec.yaml`(path 依存の追加)
- [ ] `analysis_options.yaml`(`third_party/**` 除外)
- [ ] `lib/hooks/use_nav_map.dart`
- [ ] `lib/hooks/use_coach_watch.dart`(航跡ポリラインのみ。異常検知には触らない)
- [ ] `lib/hooks/use_map_editor.dart`(未使用引数の削除のみ)
- [ ] `lib/screens/home_map_screen.dart`
- [ ] `lib/screens/area_setting_screen.dart`
- [ ] `lib/screens/fixed_obstacle_calibration_screen.dart`
- [ ] `lib/features/home_map/widgets/map_type_switcher.dart`
- [ ] `lib/utils/image2icon.dart`(戻り値を `Uint8List` へ。回転引数を追加)
- [ ] `lib/services/safety_shape_overlay_service.dart`(戻り値の型のみ。計算は不変)
- [ ] `lib/config/map_style_config.dart`(`highContrastMapStyle` が Android 専用である旨をコメントに追記)
- [ ] `ios/Runner/AppDelegate.swift`(APIキー必須チェックの緩和)
- [ ] `test/services/safety_shape_overlay_service_test.dart`(型追随のみ)
- [ ] `test/screens/fixed_obstacle_calibration_screen_test.dart`(型追随のみ)

### 9.3 変更(ドキュメント・提出資料)

- [ ] `README.md`
- [ ] `CLAUDE.md`
- [ ] `docs/DESIGN.md`
- [ ] `docs/store/` の該当9件(Phase 6-3 の表を参照)
- [ ] 本書(Phase 0 の実測値を 5.5 へ追記)

### 9.4 絶対に変更しないファイル

- `lib/services/` のうち衝突判定・警告・音声・送信ポリシーに関わるすべて
- `lib/config/` の警告設定値(`map_style_config.dart` のコメント追記を除く)
- `lib/models/` すべて
- `lib/utils/` のうち `image2icon.dart` 以外すべて
- `assets/data/sakuragawa_obstacles.json`
- `firestore.rules` / `database.rules.json`
- `android/` 配下すべて

---

## 10. ロールバック手順

**iOS だけ Google Maps へ戻す**(最も可能性が高い切り戻し)

`lib/map/nav_map_view.dart` の分岐を1行変えるだけ。

```dart
// return defaultTargetPlatform == TargetPlatform.iOS ? AppleNavMapView(...) : GoogleNavMapView(...);
return GoogleNavMapView(...);   // 一時的に全プラットフォームで Google Maps を使う
```

- 中立型・レンダラの構造はそのまま残るので、原因を直してから1行戻せば再切替できる
- `ios/Runner/AppDelegate.swift` のキー必須チェックは**緩和したままでよい**
  (キーがあれば従来どおり動く)。ただし `ios/Flutter/Secrets.xcconfig` にキーがあることを確認する

**特定の画面だけ Google に戻す**(8.6 の座標校正画面など)

`NavMapView` に `forceGoogle: true` のような明示フラグを足し、その画面だけ渡す。
**「iOS だから」ではなく「この画面は航空写真の精度が要るから」という理由をコメントに書く。**

**全部やめる**

`feature/ios-apple-maps` ブランチをマージしない。main は無傷のまま。

---

## 11. スコープ外(今回やらないと明示する)

| 項目 | 理由 |
| --- | --- |
| Android の Apple Maps 化 | MapKit は Android に存在しない |
| `LatLng` の自前型化 | 269箇所以上・衝突判定の中核。Android が Google Maps を使う限り不要(5.3) |
| iOS から Google Maps SDK を外す | Phase 7。別要件(5.8) |
| MapKit の `.muted` / POI除去による高コントラスト代替 | 3.2。移行完了後の別PR |
| `mapkit_flutter` への移行 | 最低 iOS 17 が受け入れられるようになってから再検討(2.3) |
| 経路探索・住所検索 | 元々使っていない |
| 地図タイルのオフラインキャッシュ | 別要件。MapKit も Google も公式手段が無い |
| 危険区域データの更新 | 本移行と無関係 |

---

## 12. 工数の目安

| フェーズ | 内容 | 目安 |
| --- | --- | --- |
| Phase 0 | 事前検証(スパイク) | 0.5〜1日 |
| Phase 1 | プラグイン取り込み | 0.5日 |
| Phase 2 | 中立型の導入 | 2〜3日 |
| Phase 3 | Apple レンダラ実装 | 2〜3日 |
| Phase 4 | iOS 切替 | 0.5日 |
| Phase 5 | iOS 固有調整 | 1〜2日 |
| Phase 6 | 後始末・ドキュメント | 0.5日 |
| 検証 | 実機・現地 | 1〜2日(現地は天候・練習日程に依存) |
| **合計** | | **8〜13日** + 現地検証待ち |

Phase 7(Google Maps SDK の完全除去)は含まない。
