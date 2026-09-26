import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/services/session_list_grouping.dart';

void main() {
  Session s(DateTime at, {double m = 1000, double sec = 600}) => Session(
        id: '$at',
        startedAt: at,
        endedAt: at.add(Duration(seconds: sec.round())),
        boatTypeName: 'r_1x',
        seatPosLabel: '1',
        points: const [],
        summary: SessionSummary(
          totalDistanceMeters: m,
          durationSec: sec,
          maxSpeed: 3,
          avgSpeed: 2,
          splits: const [],
          pieces: const [],
          alertCounts: const {},
        ),
      );

  test('1分未満・100m未満は短い記録。週ごとの距離は月曜始まりで末尾が今週', () {
    expect(isShortSession(s(DateTime(2026, 9, 1), sec: 7)), isTrue);
    expect(isShortSession(s(DateTime(2026, 9, 1), m: 0)), isTrue);
    expect(isShortSession(s(DateTime(2026, 9, 1))), isFalse);

    final now = DateTime(2026, 9, 26); // 土曜
    final weeks = weeklyDistances([
      s(DateTime(2026, 9, 22, 6), m: 7000), // 今週(月曜)
      s(DateTime(2026, 9, 26, 6), m: 3000), // 今週(土曜)
      s(DateTime(2026, 9, 20, 6), m: 5000), // 先週(日曜)
      s(DateTime(2026, 7, 1), m: 9999), // 8週より前
    ], now: now);
    expect(weeks.last, 10000);
    expect(weeks[weeks.length - 2], 5000);
    expect(weeks.reduce((a, b) => a + b), 15000);
  });
}
