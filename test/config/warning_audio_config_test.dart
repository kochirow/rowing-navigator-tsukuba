import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/warning_audio_config.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

void main() {
  test('警告音は他アプリの音声を下げずに重ねて再生する', () {
    final config = createWarningAudioContextConfig();

    expect(config.respectSilence, isFalse);
    expect(config.stayAwake, isTrue);
    expect(config.focus, AudioContextConfigFocus.mixWithOthers);
  });

  test('プラットフォーム音声呼び出しは有限時間で打ち切り、連続失敗時に再生成する', () {
    expect(alertPlatformCallTimeout, const Duration(seconds: 3));
    expect(alertPlayerRecreateFailureThreshold, 2);
  });

  test('事前ロード対象の警告音アセットは全て実在する', () {
    for (final asset in warningAudioAssets) {
      expect(
        File('assets/$asset').existsSync(),
        isTrue,
        reason: '$asset が assets/ 配下に無い。事前ロードが失敗する',
      );
    }
  });

  test('危険区域の既定音声も事前ロード対象に含まれる', () {
    for (final kind in StaticObstacleKind.values) {
      expect(
        warningAudioAssets,
        contains(defaultWarningAudioAssetFor(kind)),
        reason: '${kind.name} の既定音声が事前ロード対象から漏れている',
      );
    }
  });

  test('航行中のsystem fault音は事前ロードしない', () {
    expect(warningAudioAssets, isNot(contains(systemFaultWarningAudioAsset)));
  });

  test('監視の異常通知に衝突警告の読み上げを流用しない', () {
    // 「危険区域に注意」を岸の監視者へ流すと意味が食い違う。
    // 監視の異常(沈・電池切れ・更新途絶)は自艇の衝突とは別系統。
    expect(coachAnomalyAlertAudioAsset, isNot(genericWarningAudioAsset));
    expect(coachAnomalyAlertAudioAsset, isNot(otherBoatWarningAudioAsset));
    for (final kind in StaticObstacleKind.values) {
      expect(coachAnomalyAlertAudioAsset,
          isNot(defaultWarningAudioAssetFor(kind)));
    }
    expect(File('assets/$coachAnomalyAlertAudioAsset').existsSync(), isTrue);
  });

  test('危険区域の種類ごとに別の音声を割り当てる', () {
    // 読み上げ音声にした目的そのもの。「何かに当たりそう」ではなく
    // 「何に当たりそうか」を伝えられなければ意味がない。
    // 同じ音を使い回すと、聞いた側は振り向く先を選べない。
    final assetsByKind = <String, String>{
      for (final kind in StaticObstacleKind.values)
        kind.name: defaultWarningAudioAssetFor(kind),
    };
    final distinct = assetsByKind.values.toSet();
    expect(
      distinct,
      hasLength(assetsByKind.length),
      reason: '種類ごとに別音声であること。重複: $assetsByKind',
    );
    // 他艇も静的区域のどれとも違う音であること。
    expect(distinct, isNot(contains(otherBoatWarningAudioAsset)));
  });

  test('同梱する音声には WAV マスターがある', () {
    // assets/audio/ の mp3 は tool/normalize_warning_audio.sh の出力であり、
    // 手で置くものではない。マスターが無いファイルは次の実行で消える。
    // 音圧の検証は tool/check_warning_audio.sh(CI)が行う。
    for (final asset in warningAudioAssets) {
      final name = asset.split('/').last.replaceAll('.mp3', '');
      expect(
        File('tool/audio_src/$name.wav').existsSync(),
        isTrue,
        reason: 'tool/audio_src/$name.wav が無い。'
            'assets/audio/$name.mp3 は正規化を通っていない可能性がある',
      );
    }
  });
}
