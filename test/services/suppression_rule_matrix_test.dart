import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/services/suppression_rule.dart';

/// Stage 3 S3-07: 静音規則の権限を、全カテゴリ×全規則の組み合わせで固定する。
///
/// 2026-08-06 の他艇無音化は「不変条件がコメントと補助関数として存在したのに、
/// 新しい規則を足した箇所で強制されなかった」ために起きた。
/// ここが赤くなったら、規則の権限を変えたということである。
/// **意図した変更なら期待表を更新し、意図していなければ規則を直す。**
void main() {
  const categories = <String>[
    'other_boat',
    'shore',
    'bridge',
    'bridgePier',
    'island',
    'driftwood',
    'pile',
    'curve',
    'reverse',
  ];

  AlertCandidate candidateOf(String category) => AlertCandidate.stable(
        detectorId: 'test',
        category: category,
        targetId: category == 'other_boat' ? 'other-1' : null,
        behavior: AlertBehavior.continuousAction,
        evaluatedAt: DateTime.utc(2026, 8, 6),
        observationId: 'obs-$category',
        actionDeadline: const Duration(seconds: 3),
      );

  const allInputs = {
    SuppressionInput.ownSpeed,
    SuppressionInput.ownPosition,
    SuppressionInput.otherBoatSpeed,
  };

  group('カテゴリ × 規則の権限表', () {
    // 期待表。true = その規則がそのカテゴリを静音してよい。
    // 入力はすべて既知、切迫度は continuous(連続音が鳴る段階)とする。
    const expected = <String, Map<String, bool>>{
      'low_speed_static': {
        'other_boat': false, // 相手が接近してくるので消してはいけない
        'shore': true,
        'bridge': true,
        'bridgePier': true,
        'island': true,
        'driftwood': true,
        'pile': true,
        'curve': true,
        'reverse': true,
      },
      'uncertainty_only': {
        // 他艇にも適用し得るが、相手の速度が取れていることが条件
        // (下の「入力欠損」グループで検査する)。
        'other_boat': true,
        'shore': true,
        'bridge': true,
        'bridgePier': true,
        'island': true,
        'driftwood': true,
        'pile': true,
        'curve': true,
        'reverse': true,
      },
      'mooring_area': {
        'other_boat': true,
        'shore': true,
        'bridge': true,
        'bridgePier': true,
        'island': true,
        'driftwood': true,
        'pile': true,
        'curve': true,
        'reverse': true,
      },
      'stable_stop': {
        'other_boat': false, // 停止中こそ避けられない側である
        'shore': true,
        'bridge': true,
        'bridgePier': true,
        'island': true,
        'driftwood': true,
        'pile': true,
        'curve': true,
        'reverse': true,
      },
    };

    for (final rule in SuppressionRules.all) {
      for (final category in categories) {
        test('${rule.id} × $category', () {
          final want = expected[rule.id]?[category];
          expect(
            want,
            isNotNull,
            reason: '期待表に ${rule.id} × $category がない。規則かカテゴリを足したら表も更新すること。',
          );
          expect(
            rule.permits(
              candidateOf(category),
              knownInputs: allInputs,
              currentUrgency: SuppressibleUrgency.continuous,
            ),
            want,
          );
        });
      }
    }
  });

  group('入力欠損では静音しない(原則6)', () {
    test('相手の速度が取れない他艇は、どの規則でも静音できない', () {
      final withoutOtherSpeed = {
        SuppressionInput.ownSpeed,
        SuppressionInput.ownPosition,
      };
      for (final rule in SuppressionRules.all) {
        if (rule.forbiddenCategories.contains('other_boat')) continue;
        // 他艇へ適用し得る規則は、相手速度を必須入力にしていること。
        expect(
          rule.requiredInputs.contains(SuppressionInput.otherBoatSpeed) ||
              !rule.permits(
                candidateOf('other_boat'),
                knownInputs: withoutOtherSpeed,
                currentUrgency: SuppressibleUrgency.continuous,
              ),
          isTrue,
          reason: '${rule.id} は他艇へ適用し得るのに、相手速度の欠損で止まらない',
        );
      }
    });

    test('自艇の速度が取れなければ、速度を要求する規則は適用されない', () {
      for (final rule in SuppressionRules.all) {
        if (!rule.requiredInputs.contains(SuppressionInput.ownSpeed)) continue;
        expect(
          rule.permits(
            candidateOf('shore'),
            knownInputs: const {SuppressionInput.ownPosition},
            currentUrgency: SuppressibleUrgency.continuous,
          ),
          isFalse,
        );
      }
    });

    test('自艇の座標が取れなければ、桟橋規則は適用されない', () {
      expect(
        SuppressionRules.mooringArea.permits(
          candidateOf('shore'),
          knownInputs: const {SuppressionInput.ownSpeed},
          currentUrgency: SuppressibleUrgency.continuous,
        ),
        isFalse,
      );
    });
  });

  group('切迫度の上限', () {
    test('上限を超える切迫度は、権限のある規則でも消せない', () {
      const limited = SuppressionRule(
        id: 'limited',
        reasonCode: 'X',
        maximumSuppressibleUrgency: SuppressibleUrgency.intermittent,
      );
      expect(
        limited.permits(
          candidateOf('shore'),
          knownInputs: allInputs,
          currentUrgency: SuppressibleUrgency.intermittent,
        ),
        isTrue,
      );
      expect(
        limited.permits(
          candidateOf('shore'),
          knownInputs: allInputs,
          currentUrgency: SuppressibleUrgency.continuous,
        ),
        isFalse,
      );
    });
  });
}
