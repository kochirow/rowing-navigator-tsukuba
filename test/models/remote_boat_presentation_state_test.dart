import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/presentation_state_protocol.dart';
import 'package:rowing_navigator/models/remote_boat_message.dart';

void main() {
  test('橋脚・杭を含む全提示コードを受信モデルが保持する', () {
    final now = DateTime.utc(2026, 8, 13, 12);
    for (final categoryCode in PresentationStateProtocol.categoryCodes) {
      final result = RemoteBoatMessage.tryParse(
        <Object?, Object?>{
          'protocolVersion': 1,
          'appVersion': '1.1.2',
          'profileVersion': 'sakuragawa-v10',
          'boatId': 'boat-a',
          'displayName': '一号艇',
          'sessionId': 'session-a',
          'sequence': 1,
          'serverUpdatedAt': now.millisecondsSinceEpoch,
          'observedAt': now.millisecondsSinceEpoch,
          'lat': 36.075,
          'lng': 140.118,
          'accuracy': 4.0,
          'course': 180.0,
          'speed': 4.2,
          'boatType': 'r_1x',
          'presentationState': '2$categoryCode',
        },
        estimatedServerNow: now,
      );

      expect(result.isValid, isTrue, reason: categoryCode);
      expect(result.message!.presentationState, '2$categoryCode');
    }
  });
}
