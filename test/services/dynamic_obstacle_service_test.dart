import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/services/dynamic_obstacle_service.dart';
import 'package:rowing_navigator/services/message_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  final now = DateTime.utc(2026, 7, 26, 12, 0, 0);

  Message message({
    required String boatId,
    double lat = 36.07,
    double lng = 140.21,
    Duration age = Duration.zero,
  }) {
    return Message(
      boatId: boatId,
      boatType: BoatType.r_1x,
      lat: lat,
      lng: lng,
      heading: 90,
      speed: 3.0,
      timestamp: now.subtract(age),
      serverUpdatedAt: now.subtract(age),
    );
  }

  List<Boat> boatsOf(Map<String, dynamic> snapshot) =>
      snapshot['boats'] as List<Boat>;

  test('正常なレコードだけならストリーム障害にならない', () {
    final snapshot = DynamicObstacleService().summarize(
      [message(boatId: 'a'), message(boatId: 'b')],
      now: now,
    );

    expect(boatsOf(snapshot), hasLength(2));
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 0);
    expect(snapshot['receivedRecordCount'], 2);
  });

  test('ストリーム障害だけを受信障害として扱う', () {
    final snapshot = DynamicObstacleService().summarize(
      [
        message(boatId: 'a'),
        const TransportFault('RTDB_POSITION_STREAM_ERROR')
      ],
      now: now,
    );

    // 受信層の障害でも、読めた艇は落とさない(原則1: 機能を止めない)。
    expect(boatsOf(snapshot), hasLength(1));
    expect(snapshot['receiveDegraded'], isTrue);
    // fault はレコード数に数えない。
    expect(snapshot['receivedRecordCount'], 1);
    expect(snapshot['unreadableRecordCount'], 0);
  });

  test('壊れたレコードが1件混じっても、読める艇があれば障害にしない', () {
    final snapshot = DynamicObstacleService().summarize(
      [message(boatId: 'a'), 'broken-record', message(boatId: 'b')],
      now: now,
    );

    expect(boatsOf(snapshot), hasLength(2));
    // RTDBに壊れたレコードが1件残っているだけで永久にフラップさせない。
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 1);
    expect(snapshot['receivedRecordCount'], 3);
  });

  test('全件が壊れていても通信経路の障害にはしない', () {
    final snapshot = DynamicObstacleService().summarize(
      ['broken-a', 'broken-b'],
      now: now,
    );

    expect(boatsOf(snapshot), isEmpty);
    // 不正レコードを受け取れたことは、通信経路が生きている証拠である。
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 2);
    expect(snapshot['receivedRecordCount'], 2);
  });

  test('個別レコード拒否は診断へ残すが受信障害にはしない', () {
    const rejected = RecordFault(
      boatIdHash: 'a1b2c3d4',
      status: 'rejectedInvalidMessage',
      validationFailure: 'lat:outOfRange',
    );
    final snapshot = DynamicObstacleService().summarize(
      [message(boatId: 'a'), rejected],
      now: now,
    );

    expect(boatsOf(snapshot), hasLength(1));
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 1);
    expect(snapshot['recordFaults'], [rejected]);
  });

  test('レコードが0件(誰も出ていない)は障害ではない', () {
    final snapshot = DynamicObstacleService().summarize([], now: now);

    expect(boatsOf(snapshot), isEmpty);
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 0);
    expect(snapshot['receivedRecordCount'], 0);
  });

  test('位置が使えない値の艇は落とし、読めなかった件数へ数える', () {
    final snapshot = DynamicObstacleService().summarize(
      [
        message(boatId: 'a'),
        message(boatId: 'nan', lat: double.nan),
        message(boatId: 'range', lng: 200.0),
      ],
      now: now,
    );

    expect(boatsOf(snapshot).map((boat) => boat.boatId), ['a']);
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 2);
    expect(snapshot['receivedRecordCount'], 3);
  });

  test('幽霊艇フィルタは従来どおり働き、読めなかった件数には数えない', () {
    final snapshot = DynamicObstacleService().summarize(
      [
        message(boatId: 'fresh'),
        message(
          boatId: 'edge',
          age: const Duration(seconds: boatStaleTimeoutSeconds),
        ),
        message(
          boatId: 'ghost',
          age: const Duration(seconds: boatStaleTimeoutSeconds + 1),
        ),
      ],
      now: now,
    );

    expect(
      boatsOf(snapshot).map((boat) => boat.boatId),
      ['fresh', 'edge'],
    );
    // 幽霊艇は「正常に読めた結果として捨てた」ので障害ではない。
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 0);
    expect(snapshot['receivedRecordCount'], 3);
  });

  test('全件が幽霊艇でも障害にはしない', () {
    final snapshot = DynamicObstacleService().summarize(
      [
        message(
          boatId: 'ghost',
          age: const Duration(seconds: boatStaleTimeoutSeconds + 5),
        ),
      ],
      now: now,
    );

    expect(boatsOf(snapshot), isEmpty);
    expect(snapshot['receiveDegraded'], isFalse);
    expect(snapshot['unreadableRecordCount'], 0);
  });
}
