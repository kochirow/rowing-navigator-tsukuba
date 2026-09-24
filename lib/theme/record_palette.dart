import 'package:flutter/material.dart';

/// 練習記録リプレイ画面の配色（表示専用）。
///
/// 試作（tool/prototypes/record_replay/）で利用者と決めた色。暗い面にペースの5色が
/// 映えるよう、画面全体は暗い基調を既定にし、明るいテーマでは濃いめの色に替える。
@immutable
class RecordPalette {
  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceHigher;
  final Color line;
  final Color text;
  final Color textSub;
  final Color textMute;
  final Color accent;
  final Color onAccent;
  final Color cursor;
  final Color metricPace;
  final Color metricSpm;
  final Color metricDps;
  final Color restTrack;
  final Brightness brightness;

  const RecordPalette._({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHigher,
    required this.line,
    required this.text,
    required this.textSub,
    required this.textMute,
    required this.accent,
    required this.onAccent,
    required this.cursor,
    required this.metricPace,
    required this.metricSpm,
    required this.metricDps,
    required this.restTrack,
    required this.brightness,
  });

  static const dark = RecordPalette._(
    background: Color(0xFF07090C),
    surface: Color(0xFF10141A),
    surfaceHigh: Color(0xFF171C24),
    surfaceHigher: Color(0xFF232A36),
    line: Color(0xFF262E3A),
    text: Color(0xFFF3F6F9),
    textSub: Color(0xFF98A3B1),
    textMute: Color(0xFF65707E),
    accent: Color(0xFF35D6C8),
    onAccent: Color(0xFF04221F),
    cursor: Color(0xFFFF6B4A),
    metricPace: Color(0xFF35D6C8),
    metricSpm: Color(0xFFFFB547),
    metricDps: Color(0xFFA78BFA),
    restTrack: Color(0xFF5B6572),
    brightness: Brightness.dark,
  );

  static const light = RecordPalette._(
    background: Color(0xFFEEF1F5),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFF2F4F7),
    surfaceHigher: Color(0xFFE3E8EE),
    line: Color(0xFFDDE2E9),
    text: Color(0xFF0F1720),
    textSub: Color(0xFF5D6978),
    textMute: Color(0xFF8A95A3),
    accent: Color(0xFF0A8F86),
    onAccent: Color(0xFFFFFFFF),
    cursor: Color(0xFFE5482A),
    metricPace: Color(0xFF0A8F86),
    metricSpm: Color(0xFFD08300),
    metricDps: Color(0xFF7C5CF0),
    restTrack: Color(0xFF9AA4AF),
    brightness: Brightness.light,
  );

  static RecordPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  bool get isDark => brightness == Brightness.dark;

  /// 強度の色（UT=青緑 / AT=琥珀 / ハイレート=朱）。
  Color intensity(int index) => switch (index) {
        0 => metricPace,
        1 => metricSpm,
        _ => cursor,
      };

  /// ペースの色。[ratio] は 0=遅い 〜 1=速い。
  static Color paceRamp(double ratio) {
    const stops = [
      Color(0xFF4F7CFF),
      Color(0xFF35D6C8),
      Color(0xFFB6F25A),
      Color(0xFFFFD84D),
      Color(0xFFFF6B4A),
    ];
    final r = ratio.clamp(0.0, 1.0) * (stops.length - 1);
    final i = r.floor().clamp(0, stops.length - 2);
    return Color.lerp(stops[i], stops[i + 1], r - i)!;
  }
}
