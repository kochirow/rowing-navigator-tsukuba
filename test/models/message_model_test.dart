import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  test('RTDB送信にprotocol/session/sequenceとserver timestampを含む', () {
    final observedAt = DateTime.utc(2026, 7, 15, 12);
    final serverTimestamp = <String, String>{'.sv': 'timestamp'};
    final message = Message(
      boatId: 'boat-a',
      displayName: '後藤',
      sessionId: 'session-a',
      sequence: 42,
      boatType: BoatType.r_1x,
      lat: 36.0,
      lng: 140.0,
      heading: -10,
      speed: 4,
      timestamp: observedAt,
      accuracy: 5,
    );

    final json = message.toRtdbJson(serverUpdatedAt: serverTimestamp);
    expect(json['protocolVersion'], Message.currentProtocolVersion);
    expect(json['displayName'], '後藤');
    expect(json['sessionId'], 'session-a');
    expect(json['sequence'], 42);
    expect(json['serverUpdatedAt'], same(serverTimestamp));
    expect(json['observedAt'], observedAt.millisecondsSinceEpoch);
    expect(json['course'], 350);
    expect(json['capabilities'], contains('session_sequence'));
    expect(json['capabilities'], contains('display_name'));
  });

  test('protocolメッセージを受信モデルへ戻せる', () {
    final observedAt = DateTime.utc(2026, 7, 15, 12);
    final json = Message(
      boatId: 'boat-a',
      displayName: '後藤',
      sessionId: 'session-a',
      sequence: 7,
      boatType: BoatType.r_2x,
      lat: 36.0,
      lng: 140.0,
      heading: 20,
      speed: 3,
      timestamp: observedAt,
      accuracy: 4,
    ).toRtdbJson(
      serverUpdatedAt: observedAt
          .add(const Duration(milliseconds: 50))
          .millisecondsSinceEpoch,
    );

    final decoded = Message.fromRtdbJson(json);
    expect(decoded.sessionId, 'session-a');
    expect(decoded.displayName, '後藤');
    expect(decoded.sequence, 7);
    expect(decoded.boatType, BoatType.r_2x);
    expect(decoded.heading, 20);
    expect(decoded.serverUpdatedAt, isNotNull);
  });

  test('差分配信用payloadは250 bytes未満でprofileと再結合できる', () {
    final observedAt = DateTime.utc(2026, 7, 20, 12);
    final message = Message(
      boatId: 'anonymous-user-id',
      displayName: '後藤',
      sessionId: 'h5k9xz4p-2',
      sequence: 123456,
      boatType: BoatType.r_4x,
      lat: 36.0712345,
      lng: 140.2012345,
      heading: 359.8,
      speed: 6.25,
      timestamp: observedAt,
      battery: 88,
      accuracy: 3.4,
      courseAccuracy: 2.1,
      speedAccuracy: 0.2,
      presentationState: '2o',
      safetyRunMode: 'd',
      audioSuppressedAshore: true,
    );
    final compact = message.toCompactRtdbJson(
      serverUpdatedAt: observedAt.millisecondsSinceEpoch,
    );
    final encodedBytes = utf8.encode(jsonEncode(compact));

    expect(encodedBytes.length, lessThan(200));
    expect(compact, isNot(contains('displayName')));
    expect(compact, isNot(contains('boatType')));
    expect(compact['w'], '2o');
    expect(compact['m'], 'd');
    expect(compact['a'], 1);

    final expanded = Message.expandCompactRtdbJson(
      boatId: message.boatId,
      compact: compact,
      profile: message.toRtdbProfileJson(updatedAt: 1),
    );
    expect(expanded['boatId'], message.boatId);
    expect(expanded['displayName'], '後藤');
    expect(expanded['boatType'], 'r_4x');
    expect(expanded['lat'], message.lat);
    expect(expanded['serverUpdatedAt'], observedAt.millisecondsSinceEpoch);
    expect(expanded['presentationState'], '2o');
    expect(expanded['safetyRunMode'], 'd');
    expect(expanded['capabilities'], contains('presentation_state'));
  });
}
