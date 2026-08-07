import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/conservative_position_solution.dart';

void main() {
  test('生GNSS優先のalpha-beta解は初期fixをそのまま使い、有界に追従する', () {
    final solution = ConservativePositionSolution();
    expect(
        solution
            .update(latitude: 36, longitude: 140, elapsed: Duration.zero)
            .latitude,
        36);
    final updated = solution.update(
        latitude: 36.0001, longitude: 140, elapsed: const Duration(seconds: 1));
    expect(updated.latitude, greaterThan(36));
    expect(updated.latitude, lessThanOrEqualTo(36.0001));
  });
}
