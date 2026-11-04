import 'package:package_info_plus/package_info_plus.dart';

import '../config/build_provenance.dart';
import '../models/message_model.dart';
import '../models/practice_log_model.dart';

/// 監視ログを記録するアプリのビルドを読む。
///
/// 読めなくても監視ログの記録は止めない。ビルド番号が読めなければ `unknown` のまま
/// 残し、推測で埋めない(練習記録の `SessionDiagnosticMetadata` と同じ扱い)。
Future<PracticeLogAppBuild> loadPracticeLogAppBuild({
  Future<PackageInfo> Function() packageInfo = PackageInfo.fromPlatform,
  Duration timeout = const Duration(seconds: 1),
}) async {
  var version = Message.currentAppVersion;
  var buildNumber = const String.fromEnvironment(
    'FLUTTER_BUILD_NUMBER',
    defaultValue: 'unknown',
  );
  try {
    final info = await packageInfo().timeout(timeout);
    if (info.version.isNotEmpty) version = info.version;
    if (info.buildNumber.isNotEmpty) buildNumber = info.buildNumber;
  } catch (_) {/* 既定値のまま記録を続ける */}
  return PracticeLogAppBuild(
    version: version,
    buildNumber: buildNumber,
    gitCommitSha: BuildProvenance.gitCommitSha,
  );
}
