# iOS ビルド手順(Swift Package Manager + CocoaPods 混在)

作成日: 2026-10-20
対象: 後任の開発者。Mac と Xcode があれば、この文書だけで iOS の配布ビルドを再現できることを目標にする。

## 1. 構成

| 依存 | 取り込み方 | 版の決まり方 |
| --- | --- | --- |
| Firebase(core / auth / firestore / database / app_check) | **Swift Package Manager** | FlutterFire 各パッケージの `ios/<名前>/Package.swift` にある `firebaseSdkVersion`(exact 指定) |
| その他の Flutter プラグイン(geolocator・audioplayers など) | Swift Package Manager | 各プラグインの `Package.swift` |
| Google Maps(`google_maps_flutter_ios`) | **CocoaPods** | `ios/Podfile.lock` |

- `pubspec.yaml` の `flutter: config: enable-swift-package-manager: true` で SwiftPM を有効にしている。
- **Firebase iOS SDK は CocoaPods での配布を 2026年10月で終えた**(12.19.0 が最後)。
  以後の SDK 更新は SwiftPM でしか受け取れない。CocoaPods へ戻すと Firebase は
  12.19.0 で止まる。
- `google_maps_flutter_ios` 2.15.4 は SwiftPM 未対応なので、Google Maps だけ CocoaPods に残る。
  ビルド時に「The following plugins do not support Swift Package Manager」という警告が出るが、
  これは想定どおり。SwiftPM 対応の代替実装 `google_maps_flutter_ios_sdk10` へ替えれば
  CocoaPods は不要になる。今後の改修点として [今後実装したい機能.md](今後実装したい機能.md) の FUT-002 に記録してある。
- 2026-10-20 時点で SwiftPM が解決した版(`ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved`):

  | パッケージ | 版 |
  | --- | --- |
  | firebase-ios-sdk | 13.0.0 |
  | app-check(Google) | 12.0.0 |
  | grpc-binary | 1.83.1 |
  | abseil-cpp-binary | 1.2025051202.0 |
  | recaptcha-enterprise-mobile-sdk | 18.9.1 |

  `Package.resolved` は Git で管理する。推移依存(gRPC など)の版がビルドのたびに
  変わらないようにするため。`ios/Runner.xcodeproj/project.xcworkspace/` 側にも同じ内容の
  ファイルがあり、どちらも Flutter / Xcode が書き換える。

## 2. 必要なもの

| もの | 確認した版(2026-10-20) |
| --- | --- |
| Xcode | 27.1 |
| Flutter | 3.44.5(Dart 3.12.2) |
| CocoaPods | 1.17.0 |
| 秘密ファイル | `ios/Flutter/Secrets.xcconfig`(Google Maps の API キー。Git 管理外。`Secrets.xcconfig.example` を複製して作る) |

`ios/Runner/GoogleService-Info.plist` と `ios/Runner/Environment.swift` は Git 管理下にある。

## 3. 必ず守ること

1. **`LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` を付ける。** 付けないと `pod install` が
   CPU 0% のまま固まるか、`Unicode Normalization not appropriate for ASCII-8BIT` で落ちる。
   毎回付けるのが面倒なら `~/.zprofile` に `export LANG=en_US.UTF-8` と `export LC_ALL=en_US.UTF-8` を書く。
2. **Xcode で開くのは `ios/Runner.xcworkspace`。** `Runner.xcodeproj` を開くと CocoaPods(Google Maps)が
   リンクされず失敗する。
3. **配布ビルドには Git SHA を入れる。** Runner の Run Script が `tool/xcode_provenance_env.sh` を読み、
   `GIT_COMMIT_SHA` などを `DART_DEFINES` に足す。`flutter build` 経由でも Xcode の Archive 経由でも効く。
   作業ツリーが Git リポジトリでないと SHA は `unknown` になる(zip で配ったコピーからビルドしない)。

## 4. 作業パス(日本語パスと英数字パス)

- 2026-10-20 に、日本語を含む本体のパス(`…/漕艇部/桜川プロジェクト/…`)で
  `flutter build ios --release --no-codesign` が SwiftPM 有効のまま通ることを確認した。
  以前は FlutterFire の Swift Package が日本語パスを解決できず、そのため SwiftPM を
  無効にしていた(いつの版で直ったかは確認していない)。
- それでも**配布ビルドは英数字パスの複製で作ることを勧める。**
  - Android の `flutter build apk` は日本語パスで失敗する(`app.dill` のコピー)。
    iOS と Android を同じ複製で作れば手順が1つで済む。
  - 複製を `git clone` で作ると、未コミットの変更が配布物へ混ざらない。
  - 日本語パスの問題が再発しても(Flutter・FlutterFire の更新で起こりうる)、複製なら影響を受けない。
- `flutter analyze` は日本語パスでは引き続きクラッシュする(Dart analysis server の LSP の問題。
  SwiftPM とは無関係)。本体では `dart analyze lib test tool` を使う。

### 英数字パスの複製を作る

```bash
git clone <このリポジトリ> ~/dev/rowing-navigator
cd ~/dev/rowing-navigator
cp <本体>/ios/Flutter/Secrets.xcconfig ios/Flutter/
# Android も作るなら
cp <本体>/android/key.properties <本体>/android/secret.properties <本体>/android/local.properties android/
```

GitHub の `main` に合わせてからビルドする(`git fetch origin && git checkout -B main origin/main`)。

## 5. 確認用ビルド(署名なし)

```bash
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
flutter pub get
flutter build ios --release --no-codesign
```

- 初回は「Adding Swift Package Manager integration...」で firebase-ios-sdk などを取得するため
  7分ほどかかる。2回目以降はキャッシュ(`~/Library/Caches/org.swift.swiftpm`)が効く。
- Xcode のビルド自体は4分前後。初回は合計で20分程度みておく。
- 成功すると `build/ios/iphoneos/Runner.app` ができる。

## 6. 配布ビルド(Archive → TestFlight)

どちらの方法でもよい。どちらも Git SHA が入る。

### 方法A: コマンドで ipa を作る

```bash
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
zsh tool/flutter_with_provenance.sh build ipa --release --build-number <前回より大きい整数>
```

- `build/ios/ipa/*.ipa` ができる。署名には Xcode に登録した Apple Developer アカウントと
  Distribution 証明書が要る(Xcode → Settings → Accounts)。
- アップロードは Apple の「Transporter」アプリへ ipa をドラッグするか、
  `xcrun altool --upload-app` を使う。

### 方法B: Xcode の Archive

1. 先に一度 `flutter build ios --release --config-only` を実行する
   (`ios/Flutter/Generated.xcconfig` と SwiftPM の生成パッケージを最新にする)。
2. `open ios/Runner.xcworkspace`
3. 実行先を「Any iOS Device (arm64)」にし、Product → Archive。
4. Organizer が開いたら Distribute App → App Store Connect → Upload。
5. App Store Connect の TestFlight 画面で処理が終わるのを待ち、テスターへ配る。

ビルド番号は `pubspec.yaml` の `version:` の `+` の後ろ、または `--build-number` で上げる。
App Store Connect は同じビルド番号の再アップロードを受け付けない。

**版(`+` の前の `1.2.1` の部分)は利用者の指示がない限り上げない。ビルド番号だけを上げる。**
版を上げると iOS は App Store の審査へ出し直しになるため、なるべく同じ版を使い続ける方針である
(2026-10-24 利用者決定)。機能追加があっても、エージェントの判断で版を上げてはいけない。
同日、エージェントが無断で 1.2.2 に上げて指摘を受け、1.2.1 へ戻した
(Android のビルド19だけは 1.2.2 の表示名で配布済み。Android は versionCode だけで更新を判定するので、
次の 1.2.1+20 もそのまま上書きで入る)。

## 7. Firebase SDK を更新するとき

1. `pubspec.yaml` の firebase_* パッケージを上げて `flutter pub get`。
2. SwiftPM で使われる Firebase iOS SDK の版は、`~/.pub-cache/hosted/pub.dev/firebase_core-<版>/ios/firebase_core/Package.swift`
   の `firebaseSdkVersion` で分かる(FlutterFire リポジトリでは `scripts/firebase_sdk_version_spm.dart` が基準)。
   `firebase_sdk_version.rb` は CocoaPods 用の値なので見ない。
3. `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --config-only --release` を実行すると
   `Package.resolved` が更新される。差分をコミットする。
4. 上の確認用ビルドを通し、実機で App Check が Verified になることを Firebase コンソールで確認する。

## 8. 困ったとき

| 症状 | 対処 |
| --- | --- |
| `Running pod install...` から進まない | `LANG` / `LC_ALL` を付け直す(3.1) |
| 「concurrent builds」で失敗する | 途中で止めた flutter の xcodebuild が残っている。`pkill -f "xcodebuild -clonedSourcePackagesDirPath"` |
| Swift Package の解決で失敗する | `flutter clean` の後に再ビルド。直らなければ `~/Library/Caches/org.swift.swiftpm` と `~/Library/Developer/Xcode/DerivedData` の該当フォルダを消す |
| `No such module 'GoogleMaps'` など | `Runner.xcodeproj` を開いている。`Runner.xcworkspace` を開く |
| 日本語パスで Swift Package が解決できない | 4章の英数字パスの複製でビルドする |
| 診断ログの `gitCommitSha` が `unknown` | Git 管理外のフォルダでビルドした。`git clone` した複製でやり直す |
| シミュレーターで ▶ Run すると長いビルドの最後に「release/profile builds are only supported for physical devices」 | 共有スキームの Run は実機用に Release。シミュレーターは Edit Scheme → Run → Build Configuration を Debug にする(スキームは変えない) |
| `flutter build ios --simulator` が「does not contain architectures "arm64 x86_64"」で失敗する | Xcode 27 の lipo の仕様変更(flutter/flutter#188461、Flutter 3.47 系で修正)。機種を指定して Debug でビルドする: `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'id=<UDID>' build` |

## 9. 参考: ビルド結果の中身(2026-10-20 確認)

- `Runner` が動的にリンクするのは `Flutter.framework` だけ。Firebase(Firestore の C++ 部分・gRPC・abseil・reCAPTCHA)は
  `Frameworks/` に同梱されるが、`Runner` はそれらを動的にロードしない
  (`otool -L` に出ず、`nm -u` に Firebase の未解決シンボルが無い。release ビルドで本体へ統合されている)。
  Google Maps は CocoaPods の静的ライブラリとして本体へリンクされる。
- そのため CocoaPods の「[CP] Embed Pods Frameworks」ビルドフェーズは不要になり、`pod install` が削除した。
- `App.framework` にはビルド時の HEAD の SHA が入っていた(Run Script が効いている)。
