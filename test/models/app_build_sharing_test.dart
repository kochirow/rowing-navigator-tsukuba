import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/models/remote_boat_message.dart';
import 'package:rowing_navigator/types/boat_type.dart';

Message _message({String? appBuild}) => Message(
      boatId: 'boat-a',
      displayName: '一号艇',
      boatType: BoatType.r_1x,
      lat: 36.075,
      lng: 140.118,
      heading: 180,
      speed: 4.2,
      timestamp: DateTime.utc(2026, 11, 10, 3),
      accuracy: 4.0,
      appVersion: '1.2.1',
      appBuild: appBuild,
    );

Map<Object?, Object?> _parseInput(Map<String, dynamic> profile, DateTime now) {
  final compact = _message()
      .toCompactRtdbJson(serverUpdatedAt: now.millisecondsSinceEpoch);
  return Message.expandCompactRtdbJson(
    boatId: 'boat-a',
    compact: compact,
    profile: profile,
  );
}

void main() {
  final now = DateTime.utc(2026, 11, 10, 3);

  test('ビルド番号は profile にだけ載り、毎秒の位置には載らない', () {
    final message = _message(appBuild: '23');
    expect(message.toRtdbProfileJson()['appBuild'], '23');
    expect(message.toCompactRtdbJson().containsKey('appBuild'), isFalse);
    expect(message.toRtdbProfileJson()['appVersion'], '1.2.1');
  });

  test('ビルド番号を送った艇を受信側が読める。版にはビルド番号を混ぜない', () {
    final profile = _message(appBuild: '23').toRtdbProfileJson();
    final result = RemoteBoatMessage.tryParse(
      _parseInput(profile, now),
      estimatedServerNow: now,
    );
    expect(result.isValid, isTrue);
    expect(result.message!.appBuild, '23');
    expect(result.message!.appVersion, '1.2.1');
  });

  test('旧版(appBuildなし)の艇も今までどおり受信できる', () {
    final profile = _message().toRtdbProfileJson();
    expect(profile.containsKey('appBuild'), isFalse);
    final result = RemoteBoatMessage.tryParse(
      _parseInput(profile, now),
      estimatedServerNow: now,
    );
    expect(result.isValid, isTrue);
    expect(result.message!.appBuild, isNull);
  });

  test('壊れたビルド番号は捨てるだけで、艇の位置は捨てない', () {
    for (final bad in <Object>['', 'abc', '1.2', '9' * 13, 23]) {
      final profile = _message().toRtdbProfileJson()..['appBuild'] = bad;
      final result = RemoteBoatMessage.tryParse(
        _parseInput(profile, now),
        estimatedServerNow: now,
      );
      expect(result.isValid, isTrue, reason: '$bad');
      expect(result.message!.appBuild, isNull, reason: '$bad');
    }
  });

  test('型の違う appBuild が来ても Message への変換で例外にならない', () {
    final json = <String, dynamic>{
      ..._message().toRtdbJson(),
      'appBuild': 23, // 数値(Rulesは数値も通す)
    };
    expect(Message.fromRtdbJson(json).appBuild, isNull);
    json['appBuild'] = '23';
    expect(Message.fromRtdbJson(json).appBuild, '23');
  });
}
