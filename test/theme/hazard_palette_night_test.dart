import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/hazard_palette.dart';
import 'package:rowing_navigator/theme/nav_palette.dart';

void main() {
  test('夜の配色では固定の危険区域は琥珀、岸は白の淡い線', () {
    for (final category in ['bridge', 'bridgePier', 'island', 'driftwood']) {
      expect(
        HazardPalette.nightColorOf(category),
        NavPalette.caution,
        reason: category,
      );
    }
    // 岸は約310枚あり常にそこにあるので、背景として淡くする。
    expect(HazardPalette.nightStrokeColorOf('shore').a, lessThan(0.3));
    expect(HazardPalette.nightFillColorOf('shore').a, lessThan(0.1));
  });
}
