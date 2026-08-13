import 'dart:collection';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/observer_awareness_config.dart';
import '../models/boat_model.dart';
import '../services/channel_centerline.dart';
import '../services/channel_lane_resolver.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../utils/geo_math.dart';

/// 監視者へ表示する対向接近の段階。safeは物理的な安全を意味しない。
enum ObserverAwarenessPhase { safe, candidate, aware, clearing, dataDegraded }

enum ObserverEncounterKind {
  opposing,
  sameDirection,
  stopped,
  headingUnknown,
  dataDegraded,
  other,
}

class ObserverPairState {
  final ObserverAwarenessPhase phase;
  final DateTime? evidenceSince;
  final DateTime? phaseSince;
  final DateTime? awareSince;
  final DateTime? holdOrangeUntil;
  final int observations;
  final String? lastObservationToken;

  const ObserverPairState({
    this.phase = ObserverAwarenessPhase.safe,
    this.evidenceSince,
    this.phaseSince,
    this.awareSince,
    this.holdOrangeUntil,
    this.observations = 0,
    this.lastObservationToken,
  });

  static const safe = ObserverPairState();

  ObserverPairState copyWith({
    ObserverAwarenessPhase? phase,
    DateTime? evidenceSince,
    bool clearEvidenceSince = false,
    DateTime? phaseSince,
    DateTime? awareSince,
    bool clearAwareSince = false,
    DateTime? holdOrangeUntil,
    bool clearHoldOrangeUntil = false,
    int? observations,
    String? lastObservationToken,
    bool clearLastObservationToken = false,
  }) =>
      ObserverPairState(
        phase: phase ?? this.phase,
        evidenceSince:
            clearEvidenceSince ? null : evidenceSince ?? this.evidenceSince,
        phaseSince: phaseSince ?? this.phaseSince,
        awareSince: clearAwareSince ? null : awareSince ?? this.awareSince,
        holdOrangeUntil: clearHoldOrangeUntil
            ? null
            : holdOrangeUntil ?? this.holdOrangeUntil,
        observations: observations ?? this.observations,
        lastObservationToken: clearLastObservationToken
            ? null
            : lastObservationToken ?? this.lastObservationToken,
      );
}

class ObserverTrafficState {
  final Map<String, ObserverPairState> pairStates;
  final Map<String, DateTime> reverseSinceByBoatId;

  const ObserverTrafficState({
    this.pairStates = const {},
    this.reverseSinceByBoatId = const {},
  });

  static const empty = ObserverTrafficState();
}

class ObserverPairAwareness {
  final String pairId;
  final List<String> boatIds;
  final List<String> displayNames;
  final ObserverAwarenessPhase phase;
  final ObserverEncounterKind encounter;
  final double distanceMeters;
  final double closingSpeedMetersPerSecond;
  final DateTime? awareSince;
  final bool dataDegraded;

  const ObserverPairAwareness({
    required this.pairId,
    required this.boatIds,
    required this.displayNames,
    required this.phase,
    required this.encounter,
    required this.distanceMeters,
    required this.closingSpeedMetersPerSecond,
    required this.awareSince,
    this.dataDegraded = false,
  });

  bool get visibleInBanner =>
      phase == ObserverAwarenessPhase.aware ||
      phase == ObserverAwarenessPhase.clearing;
}

class ObserverAwarenessGroup {
  final List<String> boatIds;
  final List<String> displayNames;
  final List<ObserverPairAwareness> pairs;

  const ObserverAwarenessGroup({
    required this.boatIds,
    required this.displayNames,
    required this.pairs,
  });

  double get minimumDistanceMeters => pairs.fold<double>(
        double.infinity,
        (value, pair) => math.min(value, pair.distanceMeters),
      );
}

class ObserverTrafficSnapshot {
  final List<Boat> reverseBoats;
  final List<ObserverPairAwareness> pairs;
  final List<ObserverAwarenessGroup> groups;
  final int dataIssueCount;

  const ObserverTrafficSnapshot({
    this.reverseBoats = const [],
    this.pairs = const [],
    this.groups = const [],
    this.dataIssueCount = 0,
  });

  static const empty = ObserverTrafficSnapshot();

  bool get hasApproachingGroups => groups.isNotEmpty;
}

class ObserverTrafficEvaluation {
  final ObserverTrafficState nextState;
  final ObserverTrafficSnapshot snapshot;

  const ObserverTrafficEvaluation({
    required this.nextState,
    required this.snapshot,
  });
}

/// 監視向け早期注意を評価する純粋Dart部品。
///
/// 既存の衝突警報と音声には触れない。現在時刻・前回状態を引数でもらい、
/// 最大12艇（66ペア）を決定的に評価する。
class ObserverTrafficAwarenessEvaluator {
  final CollisionRiskEvaluatorService _reverseEvaluator;

  ObserverTrafficAwarenessEvaluator({
    CollisionRiskEvaluatorService? reverseEvaluator,
  }) : _reverseEvaluator = reverseEvaluator ?? CollisionRiskEvaluatorService();

  ObserverTrafficEvaluation evaluate({
    required Iterable<Boat> boats,
    required DateTime evaluatedAt,
    required ObserverTrafficState previousState,
    ChannelCenterline? channelCenterline,
    ChannelLaneResolver? laneResolver,
  }) {
    final now = evaluatedAt.toUtc();
    final ordered = boats
        .where((boat) => _hasFinitePosition(boat))
        .toList(growable: false)
      ..sort((a, b) => a.boatId.compareTo(b.boatId));
    final tracked = ordered.take(12).toList(growable: false);
    final nextPairs = <String, ObserverPairState>{};
    final outputs = <ObserverPairAwareness>[];
    var dataIssueCount = 0;

    for (var first = 0; first < tracked.length; first++) {
      for (var second = first + 1; second < tracked.length; second++) {
        final a = tracked[first];
        final b = tracked[second];
        final pairId = _pairId(a.boatId, b.boatId);
        final previous =
            previousState.pairStates[pairId] ?? ObserverPairState.safe;
        final features = _features(
          a,
          b,
          now: now,
          channelCenterline: channelCenterline,
          laneResolver: laneResolver,
        ).withObservationToken(_observationToken(a, b));
        if (features.encounter == ObserverEncounterKind.dataDegraded) {
          dataIssueCount++;
        }
        final next = _transition(previous, features, now);
        nextPairs[pairId] = next;
        if (next.phase == ObserverAwarenessPhase.aware ||
            next.phase == ObserverAwarenessPhase.clearing ||
            (next.phase == ObserverAwarenessPhase.dataDegraded &&
                (next.holdOrangeUntil?.isAfter(now) ?? false))) {
          outputs.add(ObserverPairAwareness(
            pairId: pairId,
            boatIds: [a.boatId, b.boatId],
            displayNames: [a.displayName, b.displayName],
            phase: next.phase,
            encounter: features.encounter,
            distanceMeters: features.distanceMeters,
            closingSpeedMetersPerSecond: features.closingSpeed,
            awareSince: next.awareSince,
            dataDegraded: next.phase == ObserverAwarenessPhase.dataDegraded,
          ));
        }
      }
    }

    // 一時的に一覧から消えた艇を、即座に安全と誤認しない。
    for (final entry in previousState.pairStates.entries) {
      if (nextPairs.containsKey(entry.key)) continue;
      final previous = entry.value;
      if (previous.phase != ObserverAwarenessPhase.aware &&
          previous.phase != ObserverAwarenessPhase.clearing &&
          previous.phase != ObserverAwarenessPhase.dataDegraded) {
        continue;
      }
      final held = ObserverPairState(
        phase: ObserverAwarenessPhase.dataDegraded,
        phaseSince: now,
        awareSince: previous.awareSince,
        holdOrangeUntil: now.add(observerAwarenessDataDegradedHoldDuration),
      );
      nextPairs[entry.key] = held;
      dataIssueCount++;
    }

    final nextReverseSince = <String, DateTime>{};
    final reverseBoats = <Boat>[];
    for (final boat in tracked) {
      final centerline =
          laneResolver?.centerlineFor(LatLng(boat.lat, boat.lng)) ??
              channelCenterline;
      final outcome = _reverseEvaluator.evaluateReverseGuidance(
        boat,
        centerline,
        laneResolver: laneResolver,
      );
      if (outcome != ReverseGuidanceOutcome.reverse) continue;
      final since = previousState.reverseSinceByBoatId[boat.boatId] ?? now;
      nextReverseSince[boat.boatId] = since;
      if (!now.difference(since).isNegative &&
          now.difference(since) >= observerReverseConfirmDuration) {
        reverseBoats.add(boat);
      }
    }
    reverseBoats.sort((a, b) => a.displayName.compareTo(b.displayName));

    final groups = _groups(outputs.where((pair) => pair.visibleInBanner));
    return ObserverTrafficEvaluation(
      nextState: ObserverTrafficState(
        pairStates: UnmodifiableMapView(nextPairs),
        reverseSinceByBoatId: UnmodifiableMapView(nextReverseSince),
      ),
      snapshot: ObserverTrafficSnapshot(
        reverseBoats: List.unmodifiable(reverseBoats),
        pairs: List.unmodifiable(outputs),
        groups: List.unmodifiable(groups),
        dataIssueCount: dataIssueCount,
      ),
    );
  }

  _PairFeatures _features(
    Boat a,
    Boat b, {
    required DateTime now,
    ChannelCenterline? channelCenterline,
    ChannelLaneResolver? laneResolver,
  }) {
    final ageA = _age(a, now);
    final ageB = _age(b, now);
    final positionA = _syncedPosition(a, ageA);
    final positionB = _syncedPosition(b, ageB);
    final distance = distanceMeters(positionA, positionB);
    if (ageA > observerAwarenessMaximumTrackAge ||
        ageB > observerAwarenessMaximumTrackAge ||
        (a.accuracy != null && a.accuracy! > 25) ||
        (b.accuracy != null && b.accuracy! > 25)) {
      return _PairFeatures.dataDegraded(distance);
    }
    if (a.speed < observerAwarenessMinimumSpeedMetersPerSecond ||
        b.speed < observerAwarenessMinimumSpeedMetersPerSecond ||
        !a.heading.isFinite ||
        !b.heading.isFinite) {
      return _PairFeatures(distance, 0, ObserverEncounterKind.stopped);
    }
    final closing = _closingSpeed(positionA, a, positionB, b);
    final lineA = laneResolver?.centerlineFor(positionA) ?? channelCenterline;
    final lineB = laneResolver?.centerlineFor(positionB) ?? channelCenterline;
    final sharedLine = lineA;
    if (sharedLine != null && identical(sharedLine, lineB)) {
      final frameA = sharedLine.project(positionA);
      final frameB = sharedLine.project(positionB);
      if (frameA.isInsideCoverage && frameB.isInsideCoverage) {
        final alongA = _alongSpeed(a, frameA.tangentBearingDegrees);
        final alongB = _alongSpeed(b, frameB.tangentBearingDegrees);
        final deltaAlong = frameB.alongMeters - frameA.alongMeters;
        final routeClosing = -_sign(deltaAlong) * (alongB - alongA);
        if (_sign(alongA) != _sign(alongB) &&
            alongA.abs() >= observerAwarenessMinimumSpeedMetersPerSecond &&
            alongB.abs() >= observerAwarenessMinimumSpeedMetersPerSecond &&
            routeClosing >=
                observerAwarenessMinimumClosingSpeedMetersPerSecond) {
          return _PairFeatures(distance, math.max(closing, routeClosing),
              ObserverEncounterKind.opposing);
        }
        if (_sign(alongA) == _sign(alongB)) {
          return _PairFeatures(
              distance, closing, ObserverEncounterKind.sameDirection);
        }
      }
    }
    final headingDifference = _headingDifference(a.heading, b.heading);
    if (headingDifference >= observerAwarenessFallbackOpposingHeadingDegrees &&
        closing >= observerAwarenessMinimumClosingSpeedMetersPerSecond) {
      return _PairFeatures(distance, closing, ObserverEncounterKind.opposing);
    }
    return _PairFeatures(
      distance,
      closing,
      headingDifference <= 60
          ? ObserverEncounterKind.sameDirection
          : ObserverEncounterKind.other,
    );
  }

  ObserverPairState _transition(
    ObserverPairState previous,
    _PairFeatures features,
    DateTime now,
  ) {
    if (features.encounter == ObserverEncounterKind.dataDegraded) {
      return ObserverPairState(
        phase: ObserverAwarenessPhase.dataDegraded,
        phaseSince: now,
        awareSince: previous.awareSince,
        holdOrangeUntil: previous.phase == ObserverAwarenessPhase.aware ||
                previous.phase == ObserverAwarenessPhase.clearing
            ? now.add(observerAwarenessDataDegradedHoldDuration)
            : previous.holdOrangeUntil,
      );
    }
    final evidence = features.encounter == ObserverEncounterKind.opposing &&
        features.distanceMeters <= observerAwarenessPrearmDistanceMeters;
    final token = features.observationToken;
    final hasNewObservation =
        token != null && token != previous.lastObservationToken;
    final nextObservationCount = evidence
        ? previous.observations + (hasNewObservation ? 1 : 0)
        : previous.observations;

    if (!evidence) {
      if (previous.phase == ObserverAwarenessPhase.aware ||
          previous.phase == ObserverAwarenessPhase.clearing) {
        final since = previous.phase == ObserverAwarenessPhase.clearing
            ? previous.phaseSince ?? now
            : now;
        if (now.difference(since) >= observerAwarenessClearDuration) {
          return ObserverPairState.safe;
        }
        return previous.copyWith(
          phase: ObserverAwarenessPhase.clearing,
          phaseSince: since,
        );
      }
      return ObserverPairState.safe;
    }

    if (previous.phase == ObserverAwarenessPhase.aware ||
        previous.phase == ObserverAwarenessPhase.clearing) {
      return previous.copyWith(
        phase: ObserverAwarenessPhase.aware,
        phaseSince: now,
        observations: nextObservationCount,
        lastObservationToken: hasNewObservation ? token : null,
      );
    }

    final evidenceSince = previous.phase == ObserverAwarenessPhase.candidate
        ? previous.evidenceSince ?? now
        : now;
    final observations = previous.phase == ObserverAwarenessPhase.candidate
        ? nextObservationCount
        : 1;
    final confirmed =
        now.difference(evidenceSince) >= observerAwarenessConfirmDuration &&
            observations >= observerAwarenessMinimumObservations &&
            features.distanceMeters <= observerAwarenessDisplayDistanceMeters;
    if (confirmed) {
      return ObserverPairState(
        phase: ObserverAwarenessPhase.aware,
        evidenceSince: evidenceSince,
        phaseSince: now,
        awareSince: now,
        observations: observations,
        lastObservationToken: token,
      );
    }
    return ObserverPairState(
      phase: ObserverAwarenessPhase.candidate,
      evidenceSince: evidenceSince,
      phaseSince: now,
      observations: observations,
      lastObservationToken: token,
    );
  }

  List<ObserverAwarenessGroup> _groups(
    Iterable<ObserverPairAwareness> pairs,
  ) {
    final adjacency = <String, Set<String>>{};
    final pairsByBoat = <String, List<ObserverPairAwareness>>{};
    for (final pair in pairs) {
      final a = pair.boatIds[0];
      final b = pair.boatIds[1];
      adjacency.putIfAbsent(a, () => <String>{}).add(b);
      adjacency.putIfAbsent(b, () => <String>{}).add(a);
      pairsByBoat.putIfAbsent(a, () => <ObserverPairAwareness>[]).add(pair);
      pairsByBoat.putIfAbsent(b, () => <ObserverPairAwareness>[]).add(pair);
    }
    final groups = <ObserverAwarenessGroup>[];
    final visited = <String>{};
    for (final start in adjacency.keys.toList()..sort()) {
      if (!visited.add(start)) continue;
      final queue = Queue<String>()..add(start);
      final ids = <String>{start};
      final groupPairs = <String, ObserverPairAwareness>{};
      while (queue.isNotEmpty) {
        final boatId = queue.removeFirst();
        for (final pair in pairsByBoat[boatId] ?? const []) {
          groupPairs[pair.pairId] = pair;
        }
        for (final next in adjacency[boatId] ?? const <String>{}) {
          if (visited.add(next)) {
            ids.add(next);
            queue.add(next);
          }
        }
      }
      final orderedPairs = groupPairs.values.toList()
        ..sort((a, b) => a.pairId.compareTo(b.pairId));
      final namesById = <String, String>{
        for (final pair in orderedPairs)
          for (var i = 0; i < pair.boatIds.length; i++)
            pair.boatIds[i]: pair.displayNames[i],
      };
      final orderedIds = ids.toList()..sort();
      groups.add(ObserverAwarenessGroup(
        boatIds: List.unmodifiable(orderedIds),
        displayNames: List.unmodifiable(
            orderedIds.map((id) => namesById[id] ?? id).toList()),
        pairs: List.unmodifiable(orderedPairs),
      ));
    }
    groups.sort((a, b) {
      final distance =
          a.minimumDistanceMeters.compareTo(b.minimumDistanceMeters);
      if (distance != 0) return distance;
      return a.boatIds.join('|').compareTo(b.boatIds.join('|'));
    });
    return groups;
  }

  static bool _hasFinitePosition(Boat boat) =>
      boat.lat.isFinite && boat.lng.isFinite;

  static Duration _age(Boat boat, DateTime now) {
    final timestamp = boat.serverUpdatedAt ?? boat.timestamp;
    final result = now.difference(timestamp.toUtc());
    return result.isNegative ? Duration.zero : result;
  }

  static LatLng _syncedPosition(Boat boat, Duration age) {
    final seconds = math.min(
      age.inMilliseconds / Duration.millisecondsPerSecond,
      observerAwarenessMaximumTrackAge.inMilliseconds /
          Duration.millisecondsPerSecond,
    );
    return computeOffset(
      LatLng(boat.lat, boat.lng),
      boat.speed * seconds,
      boat.heading,
    );
  }

  static double _closingSpeed(LatLng a, Boat boatA, LatLng b, Boat boatB) {
    final distance = distanceMeters(a, b);
    if (distance < 0.001) return double.infinity;
    final north = distanceMeters(a, LatLng(b.latitude, a.longitude)) *
        (b.latitude >= a.latitude ? 1 : -1);
    final east = distanceMeters(a, LatLng(a.latitude, b.longitude)) *
        (b.longitude >= a.longitude ? 1 : -1);
    final radiansA = boatA.heading * math.pi / 180;
    final radiansB = boatB.heading * math.pi / 180;
    final relativeEast =
        boatB.speed * math.sin(radiansB) - boatA.speed * math.sin(radiansA);
    final relativeNorth =
        boatB.speed * math.cos(radiansB) - boatA.speed * math.cos(radiansA);
    return -(east * relativeEast + north * relativeNorth) / distance;
  }

  static double _alongSpeed(Boat boat, double tangentDegrees) =>
      boat.speed * math.cos((boat.heading - tangentDegrees) * math.pi / 180);

  static int _sign(double value) => value >= 0 ? 1 : -1;

  static double _headingDifference(double a, double b) {
    final raw = (a - b).abs() % 360;
    return raw > 180 ? 360 - raw : raw;
  }

  static String _pairId(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  static String _observationToken(Boat a, Boat b) {
    final aTime =
        (a.serverUpdatedAt ?? a.timestamp).toUtc().microsecondsSinceEpoch;
    final bTime =
        (b.serverUpdatedAt ?? b.timestamp).toUtc().microsecondsSinceEpoch;
    return a.boatId.compareTo(b.boatId) <= 0
        ? '${a.boatId}:$aTime|${b.boatId}:$bTime'
        : '${b.boatId}:$bTime|${a.boatId}:$aTime';
  }
}

class _PairFeatures {
  final double distanceMeters;
  final double closingSpeed;
  final ObserverEncounterKind encounter;
  final String? observationToken;

  const _PairFeatures(
    this.distanceMeters,
    this.closingSpeed,
    this.encounter, {
    this.observationToken,
  });

  factory _PairFeatures.dataDegraded(double distanceMeters) => _PairFeatures(
        distanceMeters,
        0,
        ObserverEncounterKind.dataDegraded,
      );

  _PairFeatures withObservationToken(String token) => _PairFeatures(
        distanceMeters,
        closingSpeed,
        encounter,
        observationToken: token,
      );
}
