import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/ashore_config.dart';

/// 陸上判定の入力となる1測位。
class AshoreObservation {
  final LatLng position;
  final double? accuracyMeters;
  final bool gpsQualityUsable;
  final DateTime at;

  const AshoreObservation({
    required this.position,
    required this.at,
    this.accuracyMeters,
    this.gpsQualityUsable = true,
  });
}

/// [AshoreState] が今の値になった理由。診断イベントへ残す。
enum AshoreDecisionReason {
  /// どの陸上エリアにも入っていない。水上の測位1点で即座に戻る。
  onWater,

  /// 陸上エリアが無い・全件不正で読めない。安全側として音を止めない。
  ashoreAreasUnavailable,

  /// GPS品質が良くないため陸上と判定しない。
  gpsNotUsable,

  /// GPS精度の上界が分からないため陸上と判定しない。
  accuracyUnknown,

  /// 陸上エリア内だが、その境界から必要な距離だけ入っていない。
  insideMargin,

  /// 条件は満たすが、30秒の確認時間を満たしていない。
  pendingConfirmation,

  /// 利用者が手動で音を戻した。次の水上測位まで維持する。
  manualOverride,

  /// 陸上を確定。止めてよいのは警告音だけ。
  ashoreConfirmed,
}

/// 陸上判定の結果。
class AshoreState {
  final bool isAshore;
  final AshoreDecisionReason reason;
  final DateTime? ashoreSince;

  /// 最寄りの陸上エリア境界からの符号付き距離[m]。
  /// 内側が正、外側が負。陸上エリアが無い場合だけnull。
  final double? landSideDistanceMeters;

  const AshoreState({
    required this.isAshore,
    required this.reason,
    this.ashoreSince,
    this.landSideDistanceMeters,
  });

  static const initial = AshoreState(
    isAshore: false,
    reason: AshoreDecisionReason.onWater,
  );

  @override
  bool operator ==(Object other) =>
      other is AshoreState &&
      other.isAshore == isAshore &&
      other.reason == reason &&
      other.ashoreSince == ashoreSince &&
      other.landSideDistanceMeters == landSideDistanceMeters;

  @override
  int get hashCode =>
      Object.hash(isAshore, reason, ashoreSince, landSideDistanceMeters);
}

/// 明示プロットした陸上エリアの内外から、警告音だけを止める判定器。
///
/// `ashoreAreas` だけを読む。航路・廃止済みの練習水域・岸の基準線は参照しないため、
/// 岸の頂点順や航路ポリゴンの欠損で水上の音が止まることはない。
/// エリアが無い・壊れている場合も必ず水上扱いにする（原則6）。
/// 純Dart。検知・表示・記録・位置共有には一切影響しない。
class AshoreDetector {
  static const double _earthRadiusMeters = 6378137.0;
  static const double _degreesToRadians = math.pi / 180;

  final double landSideMarginMeters;
  final double accuracyMarginFactor;
  final Duration confirmationDuration;

  final LatLng _origin;
  final double _originCosLatitude;
  final List<List<(double, double)>> _areas = [];

  DateTime? _candidateSince;
  DateTime? _ashoreSince;
  bool _manualOverride = false;
  AshoreState _current = AshoreState.initial;

  AshoreDetector({
    required List<List<LatLng>> ashoreAreas,
    this.landSideMarginMeters = ashoreLandSideMarginMeters,
    this.accuracyMarginFactor = ashoreAccuracyMarginFactor,
    this.confirmationDuration = ashoreConfirmationDuration,
  })  : _origin = _originOf(ashoreAreas),
        _originCosLatitude = math.cos(
          _originOf(ashoreAreas).latitude * _degreesToRadians,
        ) {
    for (final area in ashoreAreas) {
      final local = area.where(_isFinite).map(_toLocal).toList(growable: false);
      if (local.length >= 3 && _hasNonZeroArea(local)) _areas.add(local);
    }
  }

  /// 読み込めた陸上エリア数。0なら安全側として常に水上扱い。
  int get areaCount => _areas.length;

  /// デバッグ互換用の境界辺数。安全判定の根拠は陸上ポリゴンのみ。
  int get segmentCount => _areas.fold(0, (sum, area) => sum + area.length);

  AshoreState get current => _current;

  AshoreState update(AshoreObservation observation) {
    if (_areas.isEmpty) {
      return _settle(const AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.ashoreAreasUnavailable,
      ));
    }
    if (!_isFinite(observation.position)) {
      return _settle(const AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.gpsNotUsable,
      ));
    }

    final boundary = _nearestBoundary(observation.position);
    if (!boundary.$1) {
      // 水上を1点でも測位したら、品質値が欠けていても即座に音を戻す。
      _manualOverride = false;
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.onWater,
        landSideDistanceMeters: -boundary.$2,
      ));
    }
    if (_manualOverride) {
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.manualOverride,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    if (!observation.gpsQualityUsable) {
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.gpsNotUsable,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    final accuracy = observation.accuracyMeters;
    if (accuracy == null || !accuracy.isFinite || accuracy < 0) {
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.accuracyUnknown,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    final requiredMargin = math.max(
      landSideMarginMeters,
      accuracy * accuracyMarginFactor,
    );
    if (boundary.$2 <= requiredMargin) {
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.insideMargin,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    final candidateSince = _candidateSince;
    if (candidateSince == null || observation.at.isBefore(candidateSince)) {
      _candidateSince = observation.at;
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.pendingConfirmation,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    if (observation.at.difference(candidateSince) < confirmationDuration) {
      return _settle(AshoreState(
        isAshore: false,
        reason: AshoreDecisionReason.pendingConfirmation,
        landSideDistanceMeters: boundary.$2,
      ));
    }
    _ashoreSince ??= observation.at;
    return _settle(AshoreState(
      isAshore: true,
      reason: AshoreDecisionReason.ashoreConfirmed,
      ashoreSince: _ashoreSince,
      landSideDistanceMeters: boundary.$2,
    ));
  }

  void overrideToWater() {
    _manualOverride = true;
    _candidateSince = null;
    _ashoreSince = null;
    _current = const AshoreState(
      isAshore: false,
      reason: AshoreDecisionReason.manualOverride,
    );
  }

  void reset() {
    _manualOverride = false;
    _candidateSince = null;
    _ashoreSince = null;
    _current = AshoreState.initial;
  }

  AshoreState _settle(AshoreState state) {
    if (!state.isAshore) {
      _candidateSince = state.reason == AshoreDecisionReason.pendingConfirmation
          ? _candidateSince
          : null;
      _ashoreSince = null;
    }
    _current = state;
    return state;
  }

  /// (内側か, 最寄り境界までの距離[m])。複数エリアのどれかに入れば陸上。
  ///
  /// 距離は**全エリアの和集合の外周**までを測る。重なり合うエリアの内部に
  /// 埋もれた辺は境界ではないので除外する。除外しないと、2枚を重ねて描いた
  /// 継ぎ目に沿って幅[landSideMarginMeters]の帯ができ、そこでは奥まで
  /// 入っても陸上が確定しない(音が止まらない)。
  /// 艇庫前・桟橋・スロープを別オブジェクトで描く運用を壊さないための処理。
  (bool, double) _nearestBoundary(LatLng point) {
    final target = _toLocal(point);
    var inside = false;
    var minimumDistance = double.infinity;
    for (var areaIndex = 0; areaIndex < _areas.length; areaIndex++) {
      final area = _areas[areaIndex];
      if (_contains(area, target)) {
        inside = true;
      }
      for (var index = 0; index < area.length; index++) {
        final start = area[index];
        final end = area[(index + 1) % area.length];
        if (_isInteriorEdge(areaIndex, start, end)) continue;
        final distance = _distanceToSegment(target, start, end);
        if (distance < minimumDistance) minimumDistance = distance;
      }
    }
    // 全辺が他エリアに埋もれる形は作れない(和集合には必ず外周がある)が、
    // 数値誤差で全除外された場合は距離不明として扱い、陸上を確定させない。
    if (!minimumDistance.isFinite) return (inside, 0.0);
    return (inside, minimumDistance);
  }

  /// 辺[start]-[end]が、自分以外のエリアの内部に完全に埋もれているか。
  ///
  /// 端点は継ぎ目上で内外判定が不定になるため、内分点だけで判定する。
  /// 判定を誤ったときに距離を過大評価しないよう、**すべての標本が内部**の
  /// ときだけ除外する。
  bool _isInteriorEdge(
    int ownerIndex,
    (double, double) start,
    (double, double) end,
  ) {
    const samples = [0.15, 0.35, 0.5, 0.65, 0.85];
    for (var areaIndex = 0; areaIndex < _areas.length; areaIndex++) {
      if (areaIndex == ownerIndex) continue;
      final other = _areas[areaIndex];
      var allInside = true;
      for (final t in samples) {
        final sample = (
          start.$1 + (end.$1 - start.$1) * t,
          start.$2 + (end.$2 - start.$2) * t,
        );
        if (!_contains(other, sample)) {
          allInside = false;
          break;
        }
      }
      if (allInside) return true;
    }
    return false;
  }

  static bool _contains(
      List<(double, double)> polygon, (double, double) point) {
    var inside = false;
    for (var index = 0, previous = polygon.length - 1;
        index < polygon.length;
        previous = index++) {
      final a = polygon[index];
      final b = polygon[previous];
      final crosses = (a.$2 > point.$2) != (b.$2 > point.$2) &&
          point.$1 < (b.$1 - a.$1) * (point.$2 - a.$2) / (b.$2 - a.$2) + a.$1;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static double _distanceToSegment(
    (double, double) point,
    (double, double) start,
    (double, double) end,
  ) {
    final dx = end.$1 - start.$1;
    final dy = end.$2 - start.$2;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-9) {
      return math.sqrt(
        (point.$1 - start.$1) * (point.$1 - start.$1) +
            (point.$2 - start.$2) * (point.$2 - start.$2),
      );
    }
    final t = (((point.$1 - start.$1) * dx + (point.$2 - start.$2) * dy) /
            lengthSquared)
        .clamp(0.0, 1.0);
    final x = point.$1 - (start.$1 + dx * t);
    final y = point.$2 - (start.$2 + dy * t);
    return math.sqrt(x * x + y * y);
  }

  static bool _hasNonZeroArea(List<(double, double)> points) {
    var twiceArea = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      twiceArea += points[index].$1 * next.$2 - next.$1 * points[index].$2;
    }
    return twiceArea.abs() > 1e-3;
  }

  static bool _isFinite(LatLng point) =>
      point.latitude.isFinite && point.longitude.isFinite;

  static LatLng _originOf(List<List<LatLng>> areas) {
    for (final area in areas) {
      for (final point in area) {
        if (_isFinite(point)) return point;
      }
    }
    return const LatLng(0, 0);
  }

  (double, double) _toLocal(LatLng point) => (
        (point.longitude - _origin.longitude) *
            _degreesToRadians *
            _earthRadiusMeters *
            _originCosLatitude,
        (point.latitude - _origin.latitude) *
            _degreesToRadians *
            _earthRadiusMeters,
      );
}
