import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/coach_config.dart';
import '../models/boat_model.dart';
import '../services/preset_obstacle_service.dart';
import '../utils/winding_algorithm.dart';

/// 検知される異常の種類
enum BoatAnomalyKind {
  stopped, // 長時間停止
  outOfArea, // 練習水域から逸脱
  lost, // 更新途絶(電池切れ・アプリ終了・圏外)
}

class BoatAnomaly {
  final String boatId;

  /// 艇の表示名。コーチが読めるのはこちらで、boatIdは内部識別子。
  final String displayName;
  final BoatAnomalyKind kind;

  /// この異常が**最初に**検知された時刻。
  ///
  /// 毎スキャンで現在時刻に作り直すと「いつから停止しているか」が
  /// 分からなくなる。同じ艇・同じ種類の異常が続く間は初検知時刻を保つ。
  final DateTime detectedAt;

  BoatAnomaly({
    required this.boatId,
    required this.displayName,
    required this.kind,
    required this.detectedAt,
  });

  /// 異常の同一性。再通知の抑制と初検知時刻の保持に使う。
  String get key => '$boatId:${kind.name}';

  /// 日常的に起こる異常か。**表示の強調度だけ**に使う。
  ///
  /// 更新途絶は、停止中送信10秒 + 画面OFF + 通信ジッタで普通に起こる。
  /// 沈の疑い(長時間停止)・水域外と同じ赤枠で出すと一覧が常時赤くなり、
  /// 本当にまずい艇が埋もれる(DESIGN_PRINCIPLES 原則4)。
  /// 検知も表示も消さず、目立たせ方だけを下げるための区別である。
  bool get isRoutine => kind == BoatAnomalyKind.lost;

  /// 「3分前から」のように継続時間を示す文言。直後は null。
  String? continuedLabel(DateTime now) {
    final elapsed = now.difference(detectedAt);
    if (elapsed.inSeconds < 30) return null;
    if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}秒前から';
    return '${elapsed.inMinutes}分前から';
  }

  String get label {
    switch (kind) {
      case BoatAnomalyKind.stopped:
        return '長時間停止';
      case BoatAnomalyKind.outOfArea:
        return '水域外';
      case BoatAnomalyKind.lost:
        return '更新途絶';
    }
  }
}

/// コーチ画面の艇ステータス(一覧パネル表示用)
class BoatStatus {
  final Boat boat;
  final double ageSec; // 最終更新からの経過秒数
  final BoatAnomaly? anomaly;

  BoatStatus({required this.boat, required this.ageSec, this.anomaly});
}

class _TrailPoint {
  final DateTime t;
  final LatLng position;
  final double speed;

  _TrailPoint({required this.t, required this.position, required this.speed});
}

/// 監視画面で使う「最後にサーバーへ届いた時刻」。
///
/// 画面側で同じ艇一覧が再描画されても受信時刻を現在時刻へ更新しない。
/// RTDBでは端末時計のずれを補正済みの[Boat.serverUpdatedAt]を優先し、
/// Firestoreの旧データなど値がない場合だけ観測時刻へフォールバックする。
/// 未来時刻は端末時計の補正直後などに起こりうるため、現在時刻へ丸める。
DateTime coachFreshnessTimestamp(Boat boat, DateTime now) {
  final timestamp = boat.serverUpdatedAt ?? boat.timestamp;
  return timestamp.isAfter(now) ? now : timestamp;
}

Duration coachBoatUpdateAge(Boat boat, DateTime now) {
  final age = now.difference(coachFreshnessTimestamp(boat, now));
  return age.isNegative ? Duration.zero : age;
}

/// 「更新途絶」として異常を立てるか。しきい値は [lostAlertSec]。
///
/// スキャン本体と単体テストで同じ判定を使うために切り出してある。
bool coachBoatUpdateIsLost(Duration age) =>
    age.inMilliseconds / Duration.millisecondsPerSecond > lostAlertSec;

/// この種類の異常を音でも知らせるか。設定は [coachAudibleAnomalyKindNames]。
///
/// 既定(空集合)では常に false = 監視モードは無音。
bool isAudibleCoachAnomalyKind(BoatAnomalyKind kind) =>
    coachAudibleAnomalyKindNames.contains(kind.name);

/// コーチ(観察者)モードの監視機能フック。
/// - 各艇の航跡を保持しポリラインとして提供
/// - 長時間停止・水域外・更新途絶を検知して画面に表示
/// - 一覧パネル用のステータスを提供
UseCoachWatch useCoachWatch({
  required List<Boat> otherBoats,
  required bool enabled,
}) {
  final trails = useRef<Map<String, List<_TrailPoint>>>({});
  final lastSeen = useRef<Map<String, DateTime>>({});
  final lastBoat = useRef<Map<String, Boat>>({});
  final anomalies = useState<List<BoatAnomaly>>([]);
  final boatStatuses = useState<List<BoatStatus>>([]);
  final trailPolylines = useState<Set<Polyline>>({});
  final practiceArea = useState<List<LatLng>?>(null);
  // 練習水域が読めないと水域外の検知だけが黙って止まる。航行側の
  // system fault と同じく、能力が欠けていることを画面へ出すために持つ。
  final practiceAreaUnavailable = useState(false);
  final anomalyFirstDetectedAt = useRef<Map<String, DateTime>>({});
  final scanTimer = useState<Timer?>(null);
  final presetService = useMemoized(PresetObstacleService.new);

  // 練習水域の読み込み(初回のみ)
  useEffect(() {
    var cancelled = false;
    unawaited(Future<void>(() async {
      try {
        final loaded = await presetService.loadPracticeArea();
        if (cancelled) return;
        practiceArea.value = loaded;
        // 3点未満のポリゴンでは内外判定ができない。読めなかった場合と同じく
        // 「水域外の検知が働いていない」状態として扱う。
        practiceAreaUnavailable.value = loaded == null || loaded.length < 3;
      } catch (e) {
        if (!cancelled) {
          practiceAreaUnavailable.value = true;
          debugPrint('Failed to load practice area: $e');
        }
      }
    }));
    return () {
      cancelled = true;
    };
  }, []);

  // 受信した艇情報を航跡に蓄積
  useEffect(() {
    if (!enabled) return null;
    final now = DateTime.now();
    for (final boat in otherBoats) {
      // otherBoatsは受信鮮度タイマー等でも再通知される。ここをnowにすると
      // 実データが止まっていても「最終受信0秒前」に戻り続けるため、
      // メッセージ自身の更新時刻を保持する。
      lastSeen.value[boat.boatId] = coachFreshnessTimestamp(boat, now);
      lastBoat.value[boat.boatId] = boat;
      final trail = trails.value.putIfAbsent(boat.boatId, () => []);
      // 同じタイムスタンプの点は重複追加しない
      // (RTDBは他艇の更新でも全艇分のイベントが再送されるため)
      if (trail.isEmpty || trail.last.t != boat.timestamp) {
        trail.add(_TrailPoint(
          t: boat.timestamp,
          position: LatLng(boat.lat, boat.lng),
          speed: boat.speed,
        ));
      }
      // 古い航跡を削除
      trail
          .removeWhere((p) => now.difference(p.t).inSeconds > trailDurationSec);
    }
    return null;
  }, [otherBoats, enabled]);

  // 異常検知とステータス更新(定期スキャン)
  useEffect(() {
    if (!enabled) {
      scanTimer.value?.cancel();
      scanTimer.value = null;
      trails.value.clear();
      lastSeen.value.clear();
      lastBoat.value.clear();
      anomalies.value = [];
      boatStatuses.value = [];
      trailPolylines.value = {};
      anomalyFirstDetectedAt.value.clear();
      return null;
    }

    void scan() {
      final now = DateTime.now();
      final newAnomalies = <BoatAnomaly>[];
      final newStatuses = <BoatStatus>[];

      // 受信イベントが来ない時間帯でも全艇の航跡TTLを進める。
      trails.value.removeWhere((boatId, trail) {
        trail.removeWhere(
          (point) => now.difference(point.t).inSeconds > trailDurationSec,
        );
        if (trail.isNotEmpty) return false;
        final seen = lastSeen.value[boatId];
        if (seen == null || now.difference(seen).inSeconds > trailDurationSec) {
          lastSeen.value.remove(boatId);
          lastBoat.value.remove(boatId);
          return true;
        }
        return false;
      });

      for (final entry in lastBoat.value.entries) {
        final boatId = entry.key;
        final boat = entry.value;
        final seen = lastSeen.value[boatId];
        if (seen == null) continue;
        final age = now.difference(seen);
        final ageSec = (age.isNegative ? Duration.zero : age).inMilliseconds /
            Duration.millisecondsPerSecond;

        // 10分以上前に消えた艇は監視対象から外す
        if (ageSec > trailDurationSec) continue;

        // 同じ艇・同じ種類の異常が続く間は初検知時刻を引き継ぐ。
        // 毎スキャンでnowに作り直すと「いつから停止しているか」が消える。
        BoatAnomaly makeAnomaly(BoatAnomalyKind kind) {
          final key = '$boatId:${kind.name}';
          final firstDetectedAt =
              anomalyFirstDetectedAt.value.putIfAbsent(key, () => now);
          return BoatAnomaly(
            boatId: boatId,
            displayName: boat.displayName,
            kind: kind,
            detectedAt: firstDetectedAt,
          );
        }

        BoatAnomaly? anomaly;

        // 1. 更新途絶(電池切れ・アプリ終了・圏外の可能性)
        if (coachBoatUpdateIsLost(age.isNegative ? Duration.zero : age)) {
          anomaly = makeAnomaly(BoatAnomalyKind.lost);
        }

        // 2. 長時間停止
        if (anomaly == null) {
          final trail = trails.value[boatId] ?? [];
          final recentPoints = trail
              .where((p) => now.difference(p.t).inSeconds <= stoppedAlertSec)
              .toList();
          final trailSpanSec =
              trail.isEmpty ? 0 : now.difference(trail.first.t).inSeconds;
          if (trailSpanSec >= stoppedAlertSec &&
              recentPoints.isNotEmpty &&
              recentPoints.every((p) => p.speed < stoppedSpeedForAlert)) {
            anomaly = makeAnomaly(BoatAnomalyKind.stopped);
          }
        }

        // 3. 練習水域からの逸脱
        // 水域が読めていないときは判定せず、能力低下として画面へ出す
        // (practiceAreaUnavailable)。黙って無効化しない。
        final area = practiceArea.value;
        if (anomaly == null && area != null && area.length >= 3) {
          final inside = isPointInPolygon(LatLng(boat.lat, boat.lng), area);
          if (!inside) {
            anomaly = makeAnomaly(BoatAnomalyKind.outOfArea);
          }
        }

        if (anomaly != null) {
          newAnomalies.add(anomaly);
        }

        newStatuses
            .add(BoatStatus(boat: boat, ageSec: ageSec, anomaly: anomaly));
      }

      newStatuses.sort((a, b) => a.boat.boatId.compareTo(b.boat.boatId));
      // 解消した異常の初検知時刻は捨てる。再発時は新しい異常として扱う。
      final activeKeys = newAnomalies.map((anomaly) => anomaly.key).toSet();
      anomalyFirstDetectedAt.value
          .removeWhere((key, _) => !activeKeys.contains(key));
      anomalies.value = newAnomalies;
      boatStatuses.value = newStatuses;

      // 航跡ポリラインを更新
      final polylines = HashSet<Polyline>();
      trails.value.forEach((boatId, trail) {
        if (trail.length < 2) return;
        polylines.add(Polyline(
          polylineId: PolylineId('trail_$boatId'),
          points: trail.map((p) => p.position).toList(),
          width: 3,
          color: Colors.blue.withValues(alpha: 0.6),
        ));
      });
      trailPolylines.value = polylines;
    }

    scan();
    scanTimer.value = Timer.periodic(
        const Duration(seconds: anomalyScanIntervalSec), (_) => scan());
    return () {
      scanTimer.value?.cancel();
      scanTimer.value = null;
    };
  }, [enabled]);

  return UseCoachWatch(
    anomalies: anomalies,
    boatStatuses: boatStatuses,
    trailPolylines: trailPolylines,
    practiceArea: practiceArea,
    practiceAreaUnavailable: practiceAreaUnavailable,
  );
}

class UseCoachWatch {
  final ValueNotifier<List<BoatAnomaly>> anomalies;
  final ValueNotifier<List<BoatStatus>> boatStatuses;
  final ValueNotifier<Set<Polyline>> trailPolylines;
  final ValueNotifier<List<LatLng>?> practiceArea;

  /// 練習水域を読み込めず、水域外の検知だけが働いていない状態。
  final ValueNotifier<bool> practiceAreaUnavailable;

  UseCoachWatch({
    required this.anomalies,
    required this.boatStatuses,
    required this.trailPolylines,
    required this.practiceArea,
    required this.practiceAreaUnavailable,
  });
}
