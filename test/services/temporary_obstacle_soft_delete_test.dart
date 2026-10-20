import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/static_obstacle_service.dart';

Map<String, dynamic> _hazard({Map<String, dynamic> extra = const {}}) => {
      'name': '流木',
      'shape': 'circle',
      'kind': 'generic',
      'center': const GeoPoint(36.07, 140.2),
      'radiusMeters': 5,
      'points': List.generate(
        24,
        (index) => GeoPoint(36.07 + index * 0.000001, 140.2),
      ),
      'createdBy': 'u1',
      'source': 'user_confirmed',
      ...extra,
    };

void main() {
  test('削除の印が無い区域は警告・地図に使う区域として読む', () {
    final obstacle =
        StaticObstacleService.parseTemporaryObstacle('a', _hazard());
    expect(obstacle, isNotNull);
    expect(obstacle!.isTemporary, isTrue);
    expect(obstacle.points, hasLength(24));
    expect(StaticObstacleService.parseDeletedTemporaryObstacle('a', _hazard()),
        isNull);
  });

  test('削除の印が付いた区域は警告・地図に出さず、元に戻す一覧にだけ出す', () {
    final deletedAt = DateTime.utc(2026, 10, 20, 9);
    final data = _hazard(extra: {
      'deletedAt': Timestamp.fromDate(deletedAt),
      'deletedBy': 'u2',
    });
    expect(StaticObstacleService.parseTemporaryObstacle('b', data), isNull);
    final deleted =
        StaticObstacleService.parseDeletedTemporaryObstacle('b', data);
    expect(deleted, isNotNull);
    expect(deleted!.id, 'b');
    expect(deleted.name, '流木');
    expect(deleted.deletedAt!.isAtSameMomentAs(deletedAt), isTrue);
    expect(deleted.deletedBy, 'u2');
    expect(deleted.radiusMeters, 5);
  });

  test('削除時刻がまだ書き込まれていない(サーバー時刻待ち)印も削除として扱う', () {
    // FieldValue.serverTimestamp() の書込み直後は、手元のスナップショットで
    // deletedAt が null になる。その間に区域が警告へ戻ってはいけない。
    final data = _hazard(extra: {'deletedAt': null, 'deletedBy': 'u2'});
    expect(StaticObstacleService.parseTemporaryObstacle('c', data), isNull);
    expect(
      StaticObstacleService.parseDeletedTemporaryObstacle('c', data)?.deletedAt,
      isNull,
    );
  });

  test('形が不正な区域は読まない', () {
    final data = _hazard(extra: {
      'points': [const GeoPoint(36.07, 140.2)],
    });
    expect(StaticObstacleService.parseTemporaryObstacle('d', data), isNull);
  });
}
