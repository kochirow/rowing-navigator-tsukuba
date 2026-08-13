import '../models/alert_candidate.dart';

/// 静音規則が「何を消してよいか」を型で縛るための権限モデル。
///
/// ## なぜ要るか
///
/// 2026-08-06 の実機ログで、自艇停止中に他艇が 20〜26m まで接近し
/// `actionDeadline` が 3.7 秒まで詰まった候補が、すべて表示のみで終わっていた
/// (5端末合計で他艇警告の音は0回)。原因は、岸の過剰警告対策として足した
/// 静音規則が**カテゴリを問わず**適用され、他艇まで巻き込んだことだった。
///
/// 同じファイルには意図的な除外(`_canSuppressAtRest`)が既にあり、
/// 「自艇が停止していても他艇側が接近する可能性は残る」と明記されていた。
/// **規則を足した箇所がその除外を通っていなかっただけ**である。
///
/// 散文のコメントと補助関数では、規則を足す人が見落とす。
/// **権限をデータとして持ち、適用の直前に機械的に検査する。**
///
/// ## 使い方
///
/// 各静音規則は [SuppressionRule] を宣言し、[SuppressionRule.permits] が
/// true を返したときだけ `behavior` を下げる。判定に必要な入力が
/// 欠けているときは permits が false になる(原則6: データ欠損は
/// 静音の根拠にならない)。
enum SuppressionInput {
  /// 自艇の速度。低速静音・安定停止の判定に要る。
  ownSpeed,

  /// 自艇の座標。桟橋エリア判定に要る。
  ownPosition,

  /// 相手艇の速度。他艇を静音してよいかの判定に要る。
  otherBoatSpeed,
}

/// 静音の対象になり得る最大の切迫度。
///
/// `urgent`(連続音が鳴る段階)は、低速・桟橋・安定停止のような
/// 「状況の穏やかさ」を理由に消してはならない。
enum SuppressibleUrgency { visualOnly, intermittent, continuous }

class SuppressionRule {
  /// 診断・理由コードに使う識別子。
  final String id;

  /// この規則を適用してよいカテゴリ。空なら「禁止リスト以外すべて」。
  final Set<String> allowedCategories;

  /// この規則を**決して**適用してはいけないカテゴリ。
  ///
  /// `other_boat` は原則ここへ入れる。相手が接近してくる以上、
  /// 自艇側の事情(停止・低速・桟橋)だけで消してよい理由にならない。
  /// 例外的に許すときは [allowedCategories] へ明示的に載せ、
  /// **相手の速度が取れていること**を [requiredInputs] で要求する。
  final Set<String> forbiddenCategories;

  /// この規則が下げてよい切迫度の上限。
  final SuppressibleUrgency maximumSuppressibleUrgency;

  /// 適用に必要な入力。1つでも欠けていれば適用しない(原則6)。
  final Set<SuppressionInput> requiredInputs;

  /// 適用されたときに候補へ残す理由コード。
  final String reasonCode;

  const SuppressionRule({
    required this.id,
    required this.reasonCode,
    this.allowedCategories = const {},
    this.forbiddenCategories = const {},
    this.maximumSuppressibleUrgency = SuppressibleUrgency.intermittent,
    this.requiredInputs = const {},
  });

  /// この規則を [candidate] へ適用してよいか。
  ///
  /// [knownInputs] は現在値が取れている入力の集合。
  /// [currentUrgency] は下げる前の切迫度。
  bool permits(
    AlertCandidate candidate, {
    required Set<SuppressionInput> knownInputs,
    required SuppressibleUrgency currentUrgency,
  }) {
    if (forbiddenCategories.contains(candidate.category)) return false;
    if (allowedCategories.isNotEmpty &&
        !allowedCategories.contains(candidate.category)) {
      return false;
    }
    if (currentUrgency.index > maximumSuppressibleUrgency.index) return false;
    for (final input in requiredInputs) {
      if (!knownInputs.contains(input)) return false;
    }
    return true;
  }
}

/// 現行の静音規則の権限表。
///
/// **新しい静音規則を足すときは、必ずここへ宣言を足すこと。**
/// `_applyPresentation` の中だけに条件を書くと、
/// どのカテゴリへ効くのかが一覧できなくなり、2026-08-06 の
/// 他艇無音化と同じ事故が起きる。
class SuppressionRules {
  static const otherBoat = 'other_boat';

  /// 低速時の固定物静音。3秒の確定待ちを持つ。
  static const lowSpeedStatic = SuppressionRule(
    id: 'low_speed_static',
    reasonCode: 'PRESENTATION_LOW_SPEED_SILENT',
    forbiddenCategories: {otherBoat},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownSpeed},
  );

  /// 測位の不確かさでのみ重なっている候補の静音。
  ///
  /// 他艇へも適用し得るが、**相手の速度が取れていること**を要求する。
  /// 速度不明の相手は静音しない(原則6)。
  static const uncertaintyOnly = SuppressionRule(
    id: 'uncertainty_only',
    reasonCode: 'PRESENTATION_UNCERTAINTY_ONLY_VISUAL',
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {
      SuppressionInput.ownSpeed,
      // 他艇へ適用し得る規則は、**相手の速度を必須にする**。
      // 相手が動いているか止まっているか分からないまま消してはいけない。
      // 他艇でない候補では常に「既知」として扱われるので、
      // 固定物への適用条件は変わらない。
      SuppressionInput.otherBoatSpeed,
    },
  );

  /// 桟橋エリア内での静音。
  static const mooringArea = SuppressionRule(
    id: 'mooring_area',
    reasonCode: 'PRESENTATION_MOORING_AREA_SILENT',
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {
      SuppressionInput.ownSpeed,
      SuppressionInput.ownPosition,
      SuppressionInput.otherBoatSpeed,
    },
  );

  /// 安定停止中の反復音抑制。
  static const stableStop = SuppressionRule(
    id: 'stable_stop',
    reasonCode: 'PRESENTATION_STABLE_STOP_SILENT',
    forbiddenCategories: {otherBoat},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownSpeed},
  );

  static const all = <SuppressionRule>[
    lowSpeedStatic,
    uncertaintyOnly,
    mooringArea,
    stableStop,
  ];
}
