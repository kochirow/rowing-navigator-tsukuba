import '../utils/relative_direction.dart';

enum WarningAudioMode { loop, once, none }

/// 画面上での切迫度。
///
/// 音の鳴り方(`AlertBehavior`)と同じ根拠から導出するだけで、新しい判定は
/// 行わない。風・後ろ向き・イヤホン無しで音が聞こえない状況でも、連続音が
/// 鳴っているのか表示だけなのかを目で判別できるようにするための表示値。
enum WarningDisplayUrgency {
  /// 表示のみ(音は鳴っていない)。
  monitoring,

  /// 単発音・断続音。
  action,

  /// 連続音。
  imminent,
}

/// 航行中に利用者へ提示する単一の警告状態。
///
/// 衝突計算内部のリスクレベルとは分離し、画面と音声は警告対象に応じて
/// 切り替える。同じ[key]が続く間は同じ音声をループ再生する。
class NavigationWarning {
  final String key;
  final String category;
  final String title;
  final String message;
  final String? audioAsset;
  final WarningAudioMode audioMode;
  final String? audioEventId;
  final Duration? timeUntilDanger;

  /// 自艇針路から見た脅威の相対方位 [度](-180〜180、正が右舷側)。
  /// 自艇の方位が信頼できないときは null。
  final double? relativeBearingDegrees;

  /// 画面上の切迫度。音の鳴り方から導出した表示専用の値。
  final WarningDisplayUrgency urgency;

  const NavigationWarning({
    required this.key,
    this.category = 'generic',
    required this.title,
    required this.message,
    required this.audioAsset,
    this.audioMode = WarningAudioMode.loop,
    this.audioEventId,
    this.timeUntilDanger,
    this.relativeBearingDegrees,
    this.urgency = WarningDisplayUrgency.action,
  });

  bool get isPredicted => timeUntilDanger != null;

  /// 「右」「左後方」などの短い方向ラベル。方向が分からなければ null。
  ///
  /// 漕手は後ろ向きで前を見ていない。「何が」だけでは振り向く側を決められず、
  /// 5m/sでは迷った2秒が10mになる。音を増やさずに伝えられる情報なので、
  /// 分かるときだけ添える。
  String? get directionLabel {
    final bearing = relativeBearingDegrees;
    if (bearing == null || !bearing.isFinite) return null;
    final label = relativeDirectionLabelOf(bearing);
    return label.isEmpty ? null : label;
  }

  /// Compact second count for the on-map banner. Round up so the label never
  /// suggests that the remaining response time is shorter due to truncation.
  int? get secondsUntilDanger {
    final remaining = timeUntilDanger;
    if (remaining == null) return null;
    final milliseconds = remaining.inMilliseconds.clamp(0, 3600000).toInt();
    return (milliseconds / 1000).ceil().clamp(1, 3600).toInt();
  }
}
