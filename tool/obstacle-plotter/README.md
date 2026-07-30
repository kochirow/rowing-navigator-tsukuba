# 桜川 障害物座標プロットツール

Apple Maps航空写真の上で、Rowing Navigator の固定危険区域、陸上エリア、航路中心線、航路ポリゴンを個別に作図する、Macローカル専用ツールです。

- Web画面とAPIは `127.0.0.1` にだけ待受します。LANへ公開しません。
- `.p8`秘密鍵、プロジェクトデータ、座標はMac外へ送信しません。
- Firebase接続は臨時障害物の読込み専用です。初回の招待コード入力時だけ、ツール用匿名IDのチーム所属を原子的に作成しますが、臨時障害物・固定障害物・共有校正をツールから書き換えることはありません。
- 陸上エリアと航路は危険区域として書き出しません。水面・陸地全体を常時警告にする事故を防ぎます。

## 初回設定（Apple Developerの作業）

この設定は、Apple Developer Program の **Account Holder または Admin** が必要です。既存のMaps IDとMapKit用秘密鍵がある場合は、新規発行せずその値を使ってください。

1. [Apple Developer Account](https://developer.apple.com/account/) にサインインします。
2. **Certificates, Identifiers & Profiles** を開き、左側の **Identifiers** を選びます。
3. 左上の **+** → **Maps IDs** → **Continue** を順に押します。
4. 説明（例: `Rowing Navigator obstacle plotter`）と、`maps.` から始まるMaps ID（例: `maps.jp.example.rowingnavigator`）を入力し、**Continue** → **Register** を押します。
5. 左側の **Keys** を選び、**+** を押します。MapKit JSを有効にする鍵を作成し、上で作成したMaps IDへ関連付けます。
6. **Download** で取得した `.p8` を、次のリポジトリ外の場所へ移動します。ダウンロードできるのは通常1回だけです。

```bash
mkdir -p '/Users/gotoukousei/.config/rowing-navigator/mapkit'
mv '/Users/gotoukousei/Downloads/AuthKey_XXXXXXXXXX.p8' '/Users/gotoukousei/.config/rowing-navigator/mapkit/AuthKey_XXXXXXXXXX.p8'
chmod 600 '/Users/gotoukousei/.config/rowing-navigator/mapkit/AuthKey_XXXXXXXXXX.p8'
```

7. 次を実行して設定ファイルを作ります。

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba/tool/obstacle-plotter'
cp .env.example .env
```

8. `.env` を開き、`APPLE_TEAM_ID`、`APPLE_KEY_ID`、`APPLE_MAPS_ID`、`APPLE_PRIVATE_KEY_PATH` を入力します。
   - Team ID: Apple Developer Account の **Membership** 画面。
   - Key ID: 作成した鍵の詳細画面。
   - `MAPKIT_ORIGIN`: 開発時は既定の `http://127.0.0.1:5173` のままにします。JWTの `origin` はブラウザのOriginとプロトコルを含めて完全一致する必要があります。

`APPLE_PRIVATE_KEY_PATH` 以外の場所へ `.p8` をコピーしないでください。`.env` と生成した変更適用パッケージはGitの対象外です。

## 起動

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba/tool/obstacle-plotter'
npm install
npm run dev
```

`npm install` がローカルのnpmキャッシュ権限で失敗する環境では、次を一度だけ実行してください（プロジェクトの依存関係や鍵を変更しません）。

```bash
npm install --cache /private/tmp/obstacle-plotter-npm-cache
```

ブラウザで `http://127.0.0.1:5173` を開きます。`.env`のMapKit必須値が不足している場合は、地図を表示するときだけ具体的な不足項目を示します。秘密鍵なしの曖昧な地図起動は行いません。

**変更適用パッケージを作るときは、必ず `npm run dev` を使います。** `npm run dev:offline` はAPIを起動しないため、画面上の「変更適用パッケージ」は作成できません。通常の `npm run dev` では、Apple Mapsの設定が未完了でも、JSON読込み・JSON書出し・変更適用パッケージの作成はできます。地図を表示しようとしたときだけ、MapKit設定不足のメッセージが出ます。

MapKitのトークン問題はブラウザの開発者ツールConsoleで確認できます。`origin`の不一致は `MAPKIT_ORIGIN` と実際のURL（`127.0.0.1` と `localhost` も別物）を一致させます。

## 操作

1. **同梱JSONを読込** を押して現在のプロファイルを読み込みます。
2. 左上の種別を選び、**＋作成** を押します。
3. 地図上をクリックして頂点を追加します。EnterまたはEscapeで作図を終了します。
4. 岸は「岸（向きのある基準線）」を選びます。選択時に、青（水面側）/茶（陸側）の危険区域プレビューを確認し、必要なら **向きを反転** を押します。
5. 陸上エリアは、艇庫・スロープ・艇置き場など、艇があれば確実に漕いでいない場所だけを覆います。水面を含めてはいけません。
6. 航路中心線は、川の幾何学的中心ではなく、実際に通る線を中州・橋脚を避けて引きます。
7. **検証** の赤いエラーをすべて解消してから、**変更適用パッケージ** を押します。

「変更適用パッケージ」を押すと、右下に保存先が表示されます。保存先はアプリのリポジトリの一段上にある `障害物座標プロット_変更適用/<日時>/` です。何も作られない場合は、右下の具体的なエラーに従い、ツールのターミナルで `npm run dev` を実行し直してください。

### フォルダの整理

- 左側の **＋ フォルダを追加** で最上位フォルダを作成します。フォルダを選択してから押すと、そのフォルダの中に子フォルダを作成します。
- フォルダ名をクリックすると右側に **フォルダ情報** が開き、名前と親フォルダを変更できます。自分自身や子フォルダを親にする選択肢は表示されません。
- 各オブジェクトは右側の **フォルダ** から移動できます。フォルダは作図データの整理用であり、航路・危険判定の種類そのものはオブジェクトの種別で決まります。

通常のJSON書き出しはダウンロードだけで、アプリ資産を自動変更しません。安全データの反映は必ず次の変更適用パッケージ経由で確認してください。

## 臨時障害物の運用と固定化

臨時障害物には、次の二通りの用途があります。

1. **その日限りの障害物**（釣り人、漂流中の流木など）: 練習終了後、不要になったことを確認してアプリの地図編集画面から削除します。
2. **新たに発見した固定障害物の記録**: 練習後にこのツールへ取り込み、航空写真・現地記録で形状を確認して固定候補へ昇格します。

固定化する場合の手順は次のとおりです。

1. ツール上部の「招待コード（初回のみ）」へ、アプリで使っているチームの招待コードを入力し、**臨時障害物を取込**を押します。初回だけ、ツール専用の匿名Firebase IDをそのチームの読取りメンバーとして登録します。危険区域データや共有校正はツールから変更しません。
2. 「臨時（取込）」の候補を選び、形状・種別・`export ID` を確認して**固定候補へ昇格**します。これはまだFirestoreの元文書を消しません。
3. **変更適用パッケージ**を作成し、`CHANGESET.md` に従って同梱JSON・生成定数・Rulesを更新し、アプリをビルドして配布します。
4. 配布版の端末で固定障害物として表示・警告されることを確認してから、`CHANGESET.md` に記載された元の臨時障害物をアプリで手動削除します。

固定障害物はFirestoreから端末へ自動配信されません。`assets/data/sakuragawa_obstacles.json` を含む新しいアプリ版を配布した端末だけが、次回以降その固定障害物を端末内データとして使います。

## 変更適用パッケージ

リポジトリの一段上にある、次の専用フォルダへ日時ごとに作ります。

```text
桜川アプリ/障害物座標プロット_変更適用/<日時>/
```

- `CHANGESET.md`: 人・AIエージェント用の反映手順
- `files/sakuragawa_obstacles.json`: アプリ資産への候補
- `files/sakuragawa_obstacles.layout.json`: 表示レイアウト
- `constants/`: SHA-256、校正対象の定数・Rules断片
- `verify.sh`: 反映後の検証コマンド

これはアプリ・Firestoreを自動更新しません。Codexへ「最新の変更適用パッケージを確認して反映して」と依頼し、差分と検証を確認してからアプリ資産へ反映します。特にFirestore Rulesの変更は、レビュー後にFirebase ConsoleまたはCLIで別途デプロイする必要があります。

## 開発時の検証

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba/tool/obstacle-plotter'
npm run build
npm test
npm run check:read-only
```

アプリ側の生成定数も、リポジトリのルートで検査します。

```bash
cd '/Users/gotoukousei/obsidian/My_Obsidian/漕艇部/桜川プロジェクト/桜川アプリ/rowing-navigator-tsukuba'
dart run tool/generate_hazard_constants.dart --check
tool/update_hazard_profile_hash.sh --check
dart analyze lib test
flutter test
```

緑のテストは、実機での音の開始・停止、水上で音が止まらないこと、Firestore Rulesのデプロイ、署名済みアーカイブを証明するものではありません。これらは別のリリース・現地確認ゲートです。
