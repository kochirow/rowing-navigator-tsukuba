import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  test('暗色テーマは暗い面と明るい文字を持つ', () {
    final theme = buildAppDarkTheme();
    final colors = theme.extension<AppColors>();

    expect(theme.brightness, Brightness.dark);
    expect(colors, AppColors.dark);
    // 面が暗く、文字が明るいこと。逆になっていると読めない。
    expect(colors!.canvas.computeLuminance(), lessThan(0.1));
    expect(colors.card.computeLuminance(), lessThan(0.15));
    expect(colors.textPrimary.computeLuminance(), greaterThan(0.5));
    expect(theme.scaffoldBackgroundColor, colors.canvas);
  });

  test('明色テーマは従来のトークンを維持する', () {
    final theme = buildAppTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.extension<AppColors>(), AppColors.light);
  });

  test('暗所では危険色を明色版より明るくする', () {
    // 暗い背景に濃い赤を置くと沈んで「危険」に見えない。
    expect(
      AppColors.dark.danger.computeLuminance(),
      greaterThan(AppColors.light.danger.computeLuminance()),
    );
    expect(
      AppColors.dark.warning.computeLuminance(),
      greaterThan(AppColors.light.warning.computeLuminance()),
    );
  });

  test('色と寸法トークンを補間しても必須値を維持する', () {
    final colors = AppColors.light.lerp(
      AppColors.light.copyWith(textDisabled: AppColors.light.textPrimary),
      0.5,
    );
    final dimens = AppDimens.standard.lerp(
      AppDimens.standard.copyWith(mapControlSize: 64),
      0.5,
    );

    expect(colors.textDisabled, isNotNull);
    expect(dimens.mapControlSize, 60);
    expect(dimens.pill, isNotNull);
  });
}
