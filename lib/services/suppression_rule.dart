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
/// 欠けているときは permits が false になる(規則の条件を確かめられないため)。
///
/// **例外: 自艇の低速([lowSpeed])は他艇も含めて全部止める**(2026-11-07 利用者決定)。
/// 自艇が分速100mより遅ければ漕手は周りを見て避けられ、相手が速く近づくときは
/// 相手の端末で鳴るためである。相手の速度は要らない。
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
  /// 自艇が低速でないときに働く規則(安定停止など)では、`other_boat` を
  /// ここへ入れる。自艇が動いている間に相手が近づけば、自艇の漕手が
  /// 気づけないまま距離が縮まるためである。
  /// 自艇の低速([SuppressionRules.lowSpeed])だけは他艇も止める。
  final Set<String> forbiddenCategories;

  /// この規則が下げてよい切迫度の上限。
  final SuppressibleUrgency maximumSuppressibleUrgency;

  /// 適用に必要な入力。1つでも欠けていれば適用しない。
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
  static const shore = 'shore';
  static const reverse = 'reverse';

  /// 自艇の低速(分速100m未満が3秒続く)で、すべての警告の音を止める。
  ///
  /// 他艇も対象にする(2026-11-07 利用者決定)。自艇が遅ければ漕手は周りを見て
  /// 避けられる。相手が速く近づくときは、相手の端末(相手は低速でない)で鳴る。
  /// 自艇の速度が取れないときは適用しない。
  static const lowSpeed = SuppressionRule(
    id: 'low_speed',
    reasonCode: 'PRESENTATION_LOW_SPEED_SILENT',
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownSpeed},
  );

  /// 同じ向きに漕いでいる相手への他艇警告の静音(2026-11-09 利用者決定)。
  ///
  /// 向きの差30°以内で、どちらの向きも信頼できる相手([SameDirectionDetector])。
  /// 並走でも縦列でも、少なくとも片方が相手を見ているので、その相手への警告は
  /// 表示だけにする。判定は受け取った位置と向きで行い、相手の速さは使わない
  /// (速さが実際より遅く届くことがある)。追いつく側の安全網に当たっている間は
  /// 適用しない。3艇目の他艇には働かない。
  static const sameDirection = SuppressionRule(
    id: 'same_direction',
    reasonCode: 'PRESENTATION_SAME_DIRECTION_SILENT',
    allowedCategories: {otherBoat},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
  );

  /// 測位の不確かさでのみ重なっている候補の静音。
  ///
  /// 他艇へも適用し得るが、**相手の速度が取れていること**を要求する
  /// (相手が止まっていると確かめる規則なので、速度が無いと条件を確かめられない)。
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

  // ---- 港の中(2026-11-03) ----
  //
  // 発着場所から航路の入口までの水面。音は止めずに控えめにする。
  // 鳴り始めを縮める・1回だけにする・誤差だけの重なりを表示にする、の3つで、
  // 検知・表示・記録は変えない。港の外へは効かない(`harborAreas` の内外判定)。

  /// 港の中の岸: 到達までの時間が「停止時間＋1秒」より先なら表示だけにする。
  static const harborShoreLead = SuppressionRule(
    id: 'harbor_shore_lead',
    reasonCode: 'PRESENTATION_HARBOR_SHORE_LEAD',
    allowedCategories: {shore},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownPosition},
  );

  /// 港の中の岸: 自艇の測位の誤差の円だけで重なる候補は表示だけにする。
  static const harborShoreUncertainty = SuppressionRule(
    id: 'harbor_shore_uncertainty',
    reasonCode: 'PRESENTATION_HARBOR_UNCERTAINTY_VISUAL',
    allowedCategories: {shore},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownPosition},
  );

  /// 港の中の岸: 繰り返さず、1つのエピソードで1回だけ読み上げる。
  static const harborShoreSingle = SuppressionRule(
    id: 'harbor_shore_single',
    reasonCode: 'PRESENTATION_HARBOR_SINGLE',
    allowedCategories: {shore},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownPosition},
  );

  /// 港の中の他艇: 自艇も相手も出し入れの速さ未満なら1回だけ読み上げる。
  /// **相手の速度が取れていることを要求する**(相手の速さを確かめる規則のため)。
  static const harborManeuver = SuppressionRule(
    id: 'harbor_maneuver',
    reasonCode: 'PRESENTATION_HARBOR_SINGLE',
    allowedCategories: {otherBoat},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {
      SuppressionInput.ownSpeed,
      SuppressionInput.ownPosition,
      SuppressionInput.otherBoatSpeed,
    },
  );

  /// 港の中の逆走注意: 読み上げない。港の中ではレーンを使わない。
  static const harborGuidance = SuppressionRule(
    id: 'harbor_guidance',
    reasonCode: 'PRESENTATION_HARBOR_GUIDANCE_SILENT',
    allowedCategories: {reverse},
    maximumSuppressibleUrgency: SuppressibleUrgency.continuous,
    requiredInputs: {SuppressionInput.ownPosition},
  );

  static const all = <SuppressionRule>[
    lowSpeed,
    sameDirection,
    uncertaintyOnly,
    mooringArea,
    stableStop,
    harborShoreLead,
    harborShoreUncertainty,
    harborShoreSingle,
    harborManeuver,
    harborGuidance,
  ];
}
