import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/types/tracking_mode.dart';

void main() {
  test('ジェスチャー解除だけが自動再センタリングの対象になる', () {
    expect(TrackingMode.track.isTracking, isTrue);
    expect(TrackingMode.track.allowsAutomaticRecentering, isFalse);
    expect(TrackingMode.untrackedByGesture.isTracking, isFalse);
    expect(TrackingMode.untrackedByGesture.allowsAutomaticRecentering, isTrue);
    expect(TrackingMode.untrackedByUser.isTracking, isFalse);
    expect(TrackingMode.untrackedByUser.allowsAutomaticRecentering, isFalse);
  });
}
