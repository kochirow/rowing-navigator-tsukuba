import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/alert_presentation_config.dart';
import 'package:rowing_navigator/config/warning_audio_config.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

void main() {
  test('杭は流木・中州と同じ物理障害物の警告軸で扱う', () {
    expect(StaticObstacleKind.pile.isEntryGuidance, isFalse);
    expect(
      StaticObstacleKind.pile.defaultProximityCautionMeters,
      StaticObstacleKind.driftwood.defaultProximityCautionMeters,
    );
    expect(audibleProximityCategories, contains('pile'));
    expect(lowSpeedMutedCategories, isNot(contains('pile')));
    expect(bandCappedCategories, isNot(contains('pile')));
    expect(
      defaultWarningAudioAssetFor(StaticObstacleKind.pile),
      'audio/pile_warning.mp3',
    );
  });
}
