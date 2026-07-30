import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// アプリ全体のデザイントークン。
///
/// 色・角丸・余白をここに集約し、各画面/ウィジェットは実値ではなく
/// 意味(セマンティック)で参照する。将来のダークテーマ追加は
/// [AppColors.dark] を足して `ThemeData.extensions` に差し込むだけで済む
/// 構造にしてある(本改修時点ではライトのみ実装)。
///
/// 注意: 警告の「しきい値・時間」など挙動を決める設定値は従来どおり
/// `lib/config/` に置く。ここで扱うのは色・寸法という視覚値のみ。
class AppColors extends ThemeExtension<AppColors> {
  // ブランド(桜川の水面をイメージした深い青)
  final Color primary;
  final Color primaryLight;
  final Color primaryDark;
  final Color onPrimary;

  // セマンティック状態
  final Color danger; // 緊急・削除・異常
  final Color warning; // 警告
  final Color caution; // 注意
  final Color ok; // 正常・安全
  final Color info;

  // 面
  final Color canvas; // scaffold 背景
  final Color card; // カード面
  final Color cautionSurface; // 注意カードの淡い背景
  final Color mapControlSurface; // マップ操作ボタンの面
  final Color panelScrim; // マップ上の計器カード(濃色・半透明)
  final Color chipScrim; // マップ上の小チップ(濃色・半透明)
  final Color labelScrim; // マップ操作ボタンのラベルピル

  // テキスト
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color onDark; // 濃色面上の文字(白)

  const AppColors({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.onPrimary,
    required this.danger,
    required this.warning,
    required this.caution,
    required this.ok,
    required this.info,
    required this.canvas,
    required this.card,
    required this.cautionSurface,
    required this.mapControlSurface,
    required this.panelScrim,
    required this.chipScrim,
    required this.labelScrim,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.onDark,
  });

  static const light = AppColors(
    primary: Color(0xFF095372),
    primaryLight: Color(0xFF4D9CBF),
    primaryDark: Color(0xFF002E4D),
    onPrimary: Colors.white,
    danger: Color(0xFFC62828),
    warning: Color(0xFFE65100),
    caution: Color(0xFFF9A825),
    ok: Color(0xFF2E7D32),
    info: Color(0xFF1565C0),
    canvas: Color(0xFFF4F6F8),
    card: Colors.white,
    cautionSurface: Color(0xFFFFF8E1),
    mapControlSurface: Colors.white,
    panelScrim: Color(0xE0002E4D), // primaryDark 約0.88
    chipScrim: Color(0x99000000), // 黒 約0.6
    labelScrim: Color(0x8C000000), // 黒 約0.55
    textPrimary: Color(0xDE000000), // black87
    textSecondary: Color(0x8A000000), // black54
    textDisabled: Color(0x61000000), // black38
    onDark: Colors.white,
  );

  /// 暗所・早朝夕方向け。
  ///
  /// 練習は日の出前後と夕方に集中する。暗い水面を見ていた目に真っ白な設定画面を
  /// 出すと、戻ったときしばらく水面が見えない。
  ///
  /// セマンティック色は明色版より明度を上げてある。暗い背景では
  /// `#C62828` のような濃い赤は沈んで「危険」に見えない。
  static const dark = AppColors(
    primary: Color(0xFF5CB4D8),
    primaryLight: Color(0xFF8FD0EA),
    primaryDark: Color(0xFF17384A),
    // 明るいアクセント面の上は濃色文字にする。
    onPrimary: Color(0xFF00202C),
    danger: Color(0xFFFF6B6B),
    warning: Color(0xFFFFA04D),
    caution: Color(0xFFFFCC55),
    ok: Color(0xFF66BB6A),
    info: Color(0xFF64B5F6),
    canvas: Color(0xFF10161B),
    card: Color(0xFF1B242C),
    cautionSurface: Color(0xFF3A3016),
    mapControlSurface: Color(0xFF243039),
    // マップ上の計器は明暗どちらでも濃色スクリム。地図が背後にあるため
    // 明色にすると地図が読めなくなる。
    panelScrim: Color(0xF00B1318),
    chipScrim: Color(0xB3000000),
    labelScrim: Color(0xA6000000),
    textPrimary: Color(0xF2FFFFFF),
    textSecondary: Color(0xB3FFFFFF),
    textDisabled: Color(0x80FFFFFF),
    onDark: Colors.white,
  );

  Color get mapPanelScrim => panelScrim;

  @override
  AppColors copyWith({
    Color? primary,
    Color? primaryLight,
    Color? primaryDark,
    Color? onPrimary,
    Color? danger,
    Color? warning,
    Color? caution,
    Color? ok,
    Color? info,
    Color? canvas,
    Color? card,
    Color? cautionSurface,
    Color? mapControlSurface,
    Color? panelScrim,
    Color? chipScrim,
    Color? labelScrim,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? onDark,
  }) {
    return AppColors(
      primary: primary ?? this.primary,
      primaryLight: primaryLight ?? this.primaryLight,
      primaryDark: primaryDark ?? this.primaryDark,
      onPrimary: onPrimary ?? this.onPrimary,
      danger: danger ?? this.danger,
      warning: warning ?? this.warning,
      caution: caution ?? this.caution,
      ok: ok ?? this.ok,
      info: info ?? this.info,
      canvas: canvas ?? this.canvas,
      card: card ?? this.card,
      cautionSurface: cautionSurface ?? this.cautionSurface,
      mapControlSurface: mapControlSurface ?? this.mapControlSurface,
      panelScrim: panelScrim ?? this.panelScrim,
      chipScrim: chipScrim ?? this.chipScrim,
      labelScrim: labelScrim ?? this.labelScrim,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      onDark: onDark ?? this.onDark,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      primary: Color.lerp(primary, other.primary, t)!,
      primaryLight: Color.lerp(primaryLight, other.primaryLight, t)!,
      primaryDark: Color.lerp(primaryDark, other.primaryDark, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      info: Color.lerp(info, other.info, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      card: Color.lerp(card, other.card, t)!,
      cautionSurface: Color.lerp(cautionSurface, other.cautionSurface, t)!,
      mapControlSurface:
          Color.lerp(mapControlSurface, other.mapControlSurface, t)!,
      panelScrim: Color.lerp(panelScrim, other.panelScrim, t)!,
      chipScrim: Color.lerp(chipScrim, other.chipScrim, t)!,
      labelScrim: Color.lerp(labelScrim, other.labelScrim, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      onDark: Color.lerp(onDark, other.onDark, t)!,
    );
  }
}

/// 余白・角丸のスケール(8ptグリッド基準)。
class AppDimens extends ThemeExtension<AppDimens> {
  final double space1; // 4
  final double space2; // 8
  final double space3; // 12
  final double space4; // 16
  final double space5; // 24
  final double space6; // 32
  final double radiusSm; // 8
  final double radiusMd; // 12
  final double radiusLg; // 16
  final double elevationSm; // 1
  final double elevationMd; // 4
  final double shadowBlur; // 8
  final double shadowOffsetY; // 2
  final double mapControlSize; // 56

  const AppDimens({
    required this.space1,
    required this.space2,
    required this.space3,
    required this.space4,
    required this.space5,
    required this.space6,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.elevationSm,
    required this.elevationMd,
    required this.shadowBlur,
    required this.shadowOffsetY,
    required this.mapControlSize,
  });

  static const standard = AppDimens(
    space1: 4,
    space2: 8,
    space3: 12,
    space4: 16,
    space5: 24,
    space6: 32,
    radiusSm: 8,
    radiusMd: 12,
    radiusLg: 16,
    elevationSm: 1,
    elevationMd: 4,
    shadowBlur: 8,
    shadowOffsetY: 2,
    mapControlSize: 56,
  );

  BorderRadius get borderSm => BorderRadius.circular(radiusSm);
  BorderRadius get borderMd => BorderRadius.circular(radiusMd);
  BorderRadius get borderLg => BorderRadius.circular(radiusLg);
  StadiumBorder get pill => const StadiumBorder();

  BoxShadow shadow(Color color) => BoxShadow(
        color: color,
        blurRadius: shadowBlur,
        offset: Offset(0, shadowOffsetY),
      );

  @override
  AppDimens copyWith({
    double? space1,
    double? space2,
    double? space3,
    double? space4,
    double? space5,
    double? space6,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? elevationSm,
    double? elevationMd,
    double? shadowBlur,
    double? shadowOffsetY,
    double? mapControlSize,
  }) {
    return AppDimens(
      space1: space1 ?? this.space1,
      space2: space2 ?? this.space2,
      space3: space3 ?? this.space3,
      space4: space4 ?? this.space4,
      space5: space5 ?? this.space5,
      space6: space6 ?? this.space6,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      elevationSm: elevationSm ?? this.elevationSm,
      elevationMd: elevationMd ?? this.elevationMd,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
      mapControlSize: mapControlSize ?? this.mapControlSize,
    );
  }

  @override
  AppDimens lerp(ThemeExtension<AppDimens>? other, double t) {
    if (other is! AppDimens) return this;
    return AppDimens(
      space1: lerpDouble(space1, other.space1, t)!,
      space2: lerpDouble(space2, other.space2, t)!,
      space3: lerpDouble(space3, other.space3, t)!,
      space4: lerpDouble(space4, other.space4, t)!,
      space5: lerpDouble(space5, other.space5, t)!,
      space6: lerpDouble(space6, other.space6, t)!,
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t)!,
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t)!,
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t)!,
      elevationSm: lerpDouble(elevationSm, other.elevationSm, t)!,
      elevationMd: lerpDouble(elevationMd, other.elevationMd, t)!,
      shadowBlur: lerpDouble(shadowBlur, other.shadowBlur, t)!,
      shadowOffsetY: lerpDouble(shadowOffsetY, other.shadowOffsetY, t)!,
      mapControlSize: lerpDouble(mapControlSize, other.mapControlSize, t)!,
    );
  }
}

/// トークンへ短く安全にアクセスするためのヘルパー。
///
/// `ThemeData.extensions` 未登録の文脈(例: MaterialAppより外側の
/// 起動直後のローディング)でも落ちないよう、ライト既定へフォールバックする。
extension AppThemeContext on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
  AppDimens get dimens =>
      Theme.of(this).extension<AppDimens>() ?? AppDimens.standard;
}

/// 明色テーマ。
ThemeData buildAppTheme() => _buildTheme(AppColors.light, Brightness.light);

/// 暗色テーマ。`ThemeMode.system` で OS 設定に追従する。
ThemeData buildAppDarkTheme() => _buildTheme(AppColors.dark, Brightness.dark);

/// トークンから [ThemeData] を構築する。
ThemeData _buildTheme(AppColors tokens, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: tokens.primary,
    brightness: brightness,
  ).copyWith(
    primary: tokens.primary,
    onPrimary: tokens.onPrimary,
    error: tokens.danger,
    surface: tokens.card,
    onSurface: tokens.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    primaryColor: tokens.primary,
    primaryColorLight: tokens.primaryLight,
    primaryColorDark: tokens.primaryDark,
    scaffoldBackgroundColor: tokens.canvas,
    appBarTheme: AppBarTheme(
      // 暗色では AppBar をブランド色で塗らない。アクセント色は暗い面の上で
      // 使うために明るくしてあるので、そのまま大面積に敷くと眩しい。
      backgroundColor: isDark ? tokens.card : tokens.primary,
      foregroundColor: isDark ? tokens.textPrimary : tokens.onPrimary,
      elevation: 0,
    ),
    // 屋外・移動中でも読みやすいフローティング表示
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      // 画面下端は「航行終了」「航行スタート」の定位置。既定の余白(下10)だと
      // 通知がその上へ重なり、終了したいのに通知を押してしまう。
      // ボタン1個分を空けて、通知が主要操作を塞がないようにする。
      insetPadding: const EdgeInsets.fromLTRB(16, 5, 16, 104),
      backgroundColor: tokens.primaryDark,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.standard.radiusMd),
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[
      tokens,
      AppDimens.standard,
    ],
  );
}
