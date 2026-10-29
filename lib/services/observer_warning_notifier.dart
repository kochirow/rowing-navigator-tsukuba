import '../config/coach_config.dart';
import '../models/presentation_state_protocol.dart';

/// 漕手に鳴った音の帯(`w` の1文字目)。
enum ObserverWarningBand {
  /// 1: 単発の読み上げ。
  single,

  /// 2: 連続音。
  continuous,
}

/// 監視端末が受け取った1艇の警告状態の入力。
class ObserverWarningInput {
  final String boatId;
  final String? presentationState;

  /// 受信した位置メッセージの時刻(サーバー時刻があればそれ)。
  final DateTime observedAt;

  const ObserverWarningInput({
    required this.boatId,
    required this.presentationState,
    required this.observedAt,
  });
}

/// いま漕手に音が鳴っている1艇の警告。**表示専用**で衝突評価には使わない。
class ObserverBoatWarning {
  final String boatId;
  final String categoryCode;
  final ObserverWarningBand band;

  /// この種類の音ありになった時刻(継続時間の表示に使う)。
  final DateTime since;

  const ObserverBoatWarning({
    required this.boatId,
    required this.categoryCode,
    required this.band,
    required this.since,
  });

  /// 種類の短い名前(地図の艇印に添える)。
  String get categoryLabel => observerWarningCategoryLabel(categoryCode);

  String get bandLabel =>
      band == ObserverWarningBand.continuous ? '連続音' : '単発';

  /// 艇一覧の行(「警告：他艇に注意(連続音)」)。
  String get listLabel => '警告：$categoryLabelに注意（$bandLabel）';

  @override
  bool operator ==(Object other) =>
      other is ObserverBoatWarning &&
      boatId == other.boatId &&
      categoryCode == other.categoryCode &&
      band == other.band &&
      since == other.since;

  @override
  int get hashCode => Object.hash(boatId, categoryCode, band, since);
}

/// 種類コード(`PresentationStateProtocol.categoryCodes`)の短い名前。
String observerWarningCategoryLabel(String code) => switch (code) {
      'o' => '他艇',
      'b' => '橋',
      'p' => '橋脚',
      's' => '岸',
      'i' => '中州',
      'd' => '流木',
      'k' => '杭',
      'c' => 'カーブ',
      'r' => '逆走',
      _ => 'その他',
    };

/// 1回のバイブと、その元になった警告(記録 `observer_warning_notified` 用)。
class ObserverWarningVibration {
  final DateTime at;
  final List<ObserverBoatWarning> warnings;

  const ObserverWarningVibration({required this.at, required this.warnings});

  /// まとめたうち1艇でも連続音なら、長めの振動を2回にする。
  ObserverWarningBand get band =>
      warnings.any((w) => w.band == ObserverWarningBand.continuous)
          ? ObserverWarningBand.continuous
          : ObserverWarningBand.single;
}

class ObserverWarningUpdate {
  /// 艇IDごとの、いま音が鳴っている警告。
  final Map<String, ObserverBoatWarning> active;

  /// 今回バイブさせるもの(なければ null)。
  final ObserverWarningVibration? vibration;

  const ObserverWarningUpdate({required this.active, this.vibration});
}

/// 監視端末で、航行中の艇の漕手に鳴った警告をバイブで知らせるか決める(純Dart)。
///
/// - 音なし(null・band 0・古い)から音あり(band 1・2)に変わったとき、
///   または音ありのまま種類が変わったときに1回。
/// - 同じ艇・同じ種類の音ありが続く間は繰り返さない。音なしが
///   [observerWarningRearmSilence] 続いてから、次の音ありで再び鳴らす。
/// - 複数の艇が同時に変わっても [observerWarningMinVibrationInterval] に1回へまとめる。
/// - 画面が前面にない間([deliver] が false)の変化は、鳴らさずに消化する。
///   復帰したときにまとめて鳴らしても役に立たないため。
///
/// 受信した他艇の警告状態は、監視端末での通知と表示にだけ使う(不変条件12)。
class ObserverWarningNotifier {
  final Map<String, ObserverBoatWarning> _active = {};

  /// 艇ごとの「最後にバイブさせた(または消化した)種類」。再武装で消える。
  final Map<String, String> _notifiedCategory = {};
  final Map<String, DateTime> _lastAudibleAt = {};
  final Map<String, ObserverBoatWarning> _pending = {};
  DateTime? _lastVibrationAt;

  ObserverWarningUpdate update({
    required Iterable<ObserverWarningInput> inputs,
    required DateTime now,
    required bool deliver,
  }) {
    final latest = <String, ObserverWarningInput>{};
    for (final input in inputs) {
      final previous = latest[input.boatId];
      if (previous == null || input.observedAt.isAfter(previous.observedAt)) {
        latest[input.boatId] = input;
      }
    }
    final audibleNow = <String, (String, ObserverWarningBand)>{};
    for (final input in latest.values) {
      final decoded = _decodeAudible(input, now);
      if (decoded != null) audibleNow[input.boatId] = decoded;
    }

    for (final boatId in {..._active.keys, ..._notifiedCategory.keys}) {
      if (audibleNow.containsKey(boatId)) continue;
      _active.remove(boatId);
      _pending.remove(boatId);
      final lastAudible = _lastAudibleAt[boatId];
      if (lastAudible == null ||
          now.difference(lastAudible) >= observerWarningRearmSilence) {
        _notifiedCategory.remove(boatId);
        _lastAudibleAt.remove(boatId);
      }
    }

    for (final entry in audibleNow.entries) {
      final boatId = entry.key;
      final (category, band) = entry.value;
      final current = _active[boatId];
      final warning = current != null && current.categoryCode == category
          ? (current.band == band
              ? current
              : ObserverBoatWarning(
                  boatId: boatId,
                  categoryCode: category,
                  band: band,
                  since: current.since,
                ))
          : ObserverBoatWarning(
              boatId: boatId,
              categoryCode: category,
              band: band,
              since: now,
            );
      _active[boatId] = warning;
      _lastAudibleAt[boatId] = now;
      if (_notifiedCategory[boatId] != category) {
        _notifiedCategory[boatId] = category;
        if (deliver) {
          _pending[boatId] = warning;
        }
      } else if (_pending.containsKey(boatId)) {
        // まとめ待ちの間に帯が変わったら、新しい帯で鳴らす。
        _pending[boatId] = warning;
      }
    }

    ObserverWarningVibration? vibration;
    if (!deliver) {
      _pending.clear();
    } else if (_pending.isNotEmpty) {
      final last = _lastVibrationAt;
      if (last == null ||
          now.difference(last) >= observerWarningMinVibrationInterval) {
        vibration = ObserverWarningVibration(
          at: now,
          warnings: List.unmodifiable(_pending.values),
        );
        _pending.clear();
        _lastVibrationAt = now;
      }
    }
    return ObserverWarningUpdate(
      active: Map.unmodifiable(_active),
      vibration: vibration,
    );
  }

  void reset() {
    _active.clear();
    _notifiedCategory.clear();
    _lastAudibleAt.clear();
    _pending.clear();
    _lastVibrationAt = null;
  }

  static (String, ObserverWarningBand)? _decodeAudible(
    ObserverWarningInput input,
    DateTime now,
  ) {
    final state = input.presentationState;
    if (state == null || !PresentationStateProtocol.isValid(state)) {
      return null;
    }
    if (now.difference(input.observedAt) > observerWarningMaxMessageAge) {
      return null;
    }
    final band = switch (state[0]) {
      '1' => ObserverWarningBand.single,
      '2' => ObserverWarningBand.continuous,
      _ => null,
    };
    final category = state[1];
    // system fault は艇側でも表示のみ。漕手に音は鳴っていない。
    if (band == null || category == 'f') return null;
    return (category, band);
  }
}
