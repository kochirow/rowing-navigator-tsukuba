/// 他艇位置共有プロトコルの互換性境界。
///
/// protocol/app/profileの版は診断・ログ用のメタデータであり、
/// 版の不一致だけで他艇の位置を破棄しない。受信側は自分が理解できる
/// 共通フィールドを使い、未知の任意フィールドは無視する。
///
/// appVersionはストアのbuild番号を含めないプロダクト版とする。
/// 同じ通信仕様の差し戻し再申請(+2, +3...)で互換性を壊さない。
const currentPositionProtocolVersion = 1;

/// `PackageInfo` を利用できない変換・テスト経路で使う既定値。
/// `test/config/protocol_config_test.dart` が `pubspec.yaml` と一致することを
/// 検証するため、リリース版更新時に古い値が静かに残らない。
const currentPositionAppVersion = '1.2.0';

/// 端末から読んだプロダクト版を共有payload用に正規化する。
///
/// `PackageInfo.version` は通常build番号を含まないが、異常な入力でも通信上の
/// 互換性メタデータへbuild番号を混ぜない。取得不能時は上の同期済み既定値を使う。
String positionAppVersionFor(String? runtimeVersion) {
  final productVersion = runtimeVersion?.trim().split('+').first.trim();
  return productVersion == null || productVersion.isEmpty
      ? currentPositionAppVersion
      : productVersion;
}
const currentHazardProfileVersion = 'sakuragawa-v3';

/// 現行アプリが自身で生成する版。受信の拒否リストではない。
const supportedPositionProtocolVersions = {currentPositionProtocolVersion};
const supportedHazardProfileVersions = {currentHazardProfileVersion};
