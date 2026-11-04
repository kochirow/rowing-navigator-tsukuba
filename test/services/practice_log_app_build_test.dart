import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rowing_navigator/models/practice_log_model.dart';
import 'package:rowing_navigator/services/practice_log_app_build.dart';

PackageInfo info({String version = '1.2.1', String buildNumber = '22'}) =>
    PackageInfo(
      appName: 'Rowing Navigator',
      packageName: 'jp.example',
      version: version,
      buildNumber: buildNumber,
    );

void main() {
  test('端末のアプリ情報から版とビルド番号を読む', () async {
    final build = await loadPracticeLogAppBuild(
        packageInfo: () async => info(buildNumber: '22'));
    expect(build.version, '1.2.1');
    expect(build.buildNumber, '22');
    expect(build.gitCommitSha, isNotEmpty);
  });

  test('アプリ情報が読めなくても記録を止めず、ビルド番号は推測しない', () async {
    final build = await loadPracticeLogAppBuild(
        packageInfo: () async => throw Exception('unavailable'));
    expect(build.buildNumber, 'unknown');
  });

  test('meta.jsonへ保存して読み戻せる', () {
    final log = PracticeLog(
      id: 'practice_20261104_220000',
      teamId: 'team',
      recordedBy: 'observer',
      startedAt: DateTime.utc(2026, 11, 4, 22),
      isComplete: false,
      appBuild: const PracticeLogAppBuild(
          version: '1.2.1', buildNumber: '22', gitCommitSha: 'abc1234'),
    );
    final restored = PracticeLog.fromJson(log.toJson());
    expect(restored.appBuild?.buildNumber, '22');
    expect(restored.appBuild?.gitCommitSha, 'abc1234');
    // 完了扱いに直すなど、copyWith を通しても消えない。
    expect(restored.copyWith(isComplete: true).appBuild?.buildNumber, '22');
  });
}
