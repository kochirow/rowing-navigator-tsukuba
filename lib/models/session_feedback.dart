import '../config/log_export_config.dart';

/// 練習の後に、漕いだ本人が残す評価とひとこと(R1)。
///
/// 5段階は「真ん中＝ちょうどよい」の両側。−2〜+2、未入力は null。
/// - タイミング: −2 早すぎた … 0 ちょうどよい … +2 遅すぎた
/// - 量: −2 少なすぎた … 0 ちょうどよい … +2 多すぎた
///
/// 監視ログでは5段階を使わず、ひとことだけを持つ(監視者は漕手に鳴った音を
/// 聞いていない)。
class SessionUserFeedback {
  final int? timingOffset;
  final int? amountOffset;
  final String? comment;
  final DateTime updatedAt;

  SessionUserFeedback({
    int? timingOffset,
    int? amountOffset,
    String? comment,
    required this.updatedAt,
  })  : timingOffset = _clampOffset(timingOffset),
        amountOffset = _clampOffset(amountOffset),
        comment = normalizeFeedbackComment(comment);

  bool get isEmpty =>
      timingOffset == null && amountOffset == null && comment == null;

  SessionUserFeedback copyWith({
    int? Function()? timingOffset,
    int? Function()? amountOffset,
    String? Function()? comment,
    required DateTime updatedAt,
  }) =>
      SessionUserFeedback(
        timingOffset: timingOffset != null ? timingOffset() : this.timingOffset,
        amountOffset: amountOffset != null ? amountOffset() : this.amountOffset,
        comment: comment != null ? comment() : this.comment,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'timingOffset': timingOffset,
        'amountOffset': amountOffset,
        'comment': comment,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  static SessionUserFeedback? fromJson(Object? json) {
    if (json is! Map) return null;
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (updatedAt == null) return null;
    return SessionUserFeedback(
      timingOffset: (json['timingOffset'] as num?)?.toInt(),
      amountOffset: (json['amountOffset'] as num?)?.toInt(),
      comment: json['comment'] as String?,
      updatedAt: updatedAt,
    );
  }

  static int? _clampOffset(int? value) {
    if (value == null) return null;
    if (value < -2 || value > 2) return null;
    return value;
  }
}

/// ひとことの空白を整え、空なら null、長すぎれば上限で切る。
String? normalizeFeedbackComment(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final runes = trimmed.runes.toList();
  if (runes.length <= userFeedbackCommentMaxLength) return trimmed;
  return String.fromCharCodes(runes.take(userFeedbackCommentMaxLength));
}

/// 5段階の目盛りの言葉(R1-3)。
enum FeedbackScale {
  timing,
  amount;

  String labelFor(int offset) => switch ((this, offset)) {
        (FeedbackScale.timing, -2) => '早すぎた',
        (FeedbackScale.timing, -1) => '少し早かった',
        (FeedbackScale.timing, 1) => '少し遅かった',
        (FeedbackScale.timing, 2) => '遅すぎた',
        (FeedbackScale.amount, -2) => '少なすぎた',
        (FeedbackScale.amount, -1) => '少し少なかった',
        (FeedbackScale.amount, 1) => '少し多かった',
        (FeedbackScale.amount, 2) => '多すぎた',
        _ => 'ちょうどよい',
      };

  /// ボタンに書く短い言葉。
  String buttonLabelFor(int offset) => switch ((this, offset)) {
        (FeedbackScale.timing, -2) => '早すぎ',
        (FeedbackScale.timing, -1) => '少し早い',
        (FeedbackScale.timing, 1) => '少し遅い',
        (FeedbackScale.timing, 2) => '遅すぎ',
        (FeedbackScale.amount, -2) => '少なすぎ',
        (FeedbackScale.amount, -1) => '少し少ない',
        (FeedbackScale.amount, 1) => '少し多い',
        (FeedbackScale.amount, 2) => '多すぎ',
        _ => 'ちょうど',
      };

  String get title => switch (this) {
        FeedbackScale.timing => '警告のタイミング',
        FeedbackScale.amount => '警告の量',
      };

  /// 人が読む形(feedback.txt)。未入力は「未入力」。
  String describe(int? offset) {
    if (offset == null) return '未入力';
    final sign = offset > 0 ? '+$offset' : '$offset';
    return '${labelFor(offset)}（$sign）';
  }
}
