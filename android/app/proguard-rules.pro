# Firebase のコンポーネント登録(ComponentRegistrar)は、AndroidManifest の
# meta-data からクラス名を読み、引数なしコンストラクタをリフレクションで呼ぶ。
#
# firebase-components 18.0.0 の consumer rules は
#   -keep class * implements com.google.firebase.components.ComponentRegistrar
# とメンバー指定なしで書いている。AGP 9 の R8(strict full mode)では、
# メンバー指定のない -keep は既定コンストラクタを残さない。そのため
# リリースビルドで FirebaseAppCheckRegistrar.<init>() などが削られ、
# App Check の初期化が NoSuchMethodException で失敗していた(2026-10-20 確認)。
# 位置共有は縮退運転で続くが、App Check の enforcement を有効にすると
# Android 版だけが RTDB / Firestore へ書き込めなくなる。
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
