import 'package:flutter/foundation.dart';

/// 配布物とソースを紐づけるコンパイル時情報。
///
/// [tool/flutter_with_provenance.sh] 経由で起動・ビルドすると
/// Git SHA・UTCビルド時刻・flavorが `--dart-define` で入る。
/// 通常の `flutter` を直接使った場合は推測せず `unknown`
/// とし、診断ZIPから識別不能な事実が分かるようにする。
abstract final class BuildProvenance {
  static const gitCommitSha = String.fromEnvironment(
    'GIT_COMMIT_SHA',
    defaultValue: 'unknown',
  );

  static const buildTimestampUtc = String.fromEnvironment(
    'BUILD_TIMESTAMP_UTC',
    defaultValue: 'unknown',
  );

  static const configuredFlavor = String.fromEnvironment(
    'BUILD_FLAVOR',
    defaultValue: 'unknown',
  );

  static String get buildMode => kReleaseMode
      ? 'release'
      : kProfileMode
          ? 'profile'
          : 'debug';
}
