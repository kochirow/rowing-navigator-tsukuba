import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';

import '../config/practice_log_config.dart';
import '../hooks/use_coach_watch.dart';
import '../models/message_model.dart';
import '../models/practice_log_model.dart';
import '../services/geo_service.dart';
import 'use_observer_warning_alerts.dart';
import '../services/practice_log_recorder.dart';
import '../services/practice_log_store_service.dart';

class UsePracticeLogRecording {
  final ValueNotifier<PracticeLog?> log;
  final ValueNotifier<String?> error;

  /// 監視ログへイベントを1件書く(記録中でなければ何もしない)。
  /// 背面の通知(R3)など、画面の描画と関係なく起きたことを残すために使う。
  final void Function(String type, Map<String, dynamic> details) recordEvent;

  const UsePracticeLogRecording({
    required this.log,
    required this.error,
    required this.recordEvent,
  });
}

/// 監視中だけ一括ログを開始する。位置共有・地図の後段で動き、保存に失敗しても
/// 監視表示を止めない。画面を消してもOSが継続を保証するとは言わず、空白は
/// recorder_gapとして残す。
///
/// 受信した位置は [messages] の変化を**直接購読して**記録する。画面の再描画
/// (hook の effect)に頼ると、背面では Flutter が描画しないので記録が止まる
/// (2026-11-04 R8-R6)。
UsePracticeLogRecording usePracticeLogRecording({
  required bool enabled,
  required String? teamId,
  required String? recordedBy,
  required ValueListenable<List<Message>> messages,
  required List<BoatAnomaly> anomalies,
  UseObserverWarningAlerts? observerWarnings,
}) {
  final warningNotifications =
      observerWarnings?.notifications.value ?? const [];
  final log = useState<PracticeLog?>(null);
  final error = useState<String?>(null);
  final store = useMemoized(PracticeLogStoreService.new);
  final geo = useMemoized(GeoService.new);
  final recorder = useRef<PracticeLogRecorder?>(null);
  final pointCount = useRef(0);
  final livePointCount = useRef(0);
  final eventCount = useRef(0);
  final lastCheckpoint = useRef<DateTime?>(null);
  final lastAnomalies = useRef<Set<String>>({});
  final lastWarningNotificationAt = useRef<DateTime?>(null);
  final latestObserver = useRef<Position?>(null);
  final observerUnavailableReported = useRef(false);
  final timer = useRef<Timer?>(null);
  final observerTimer = useRef<Timer?>(null);
  final subscription = useRef<StreamSubscription<Position>?>(null);
  final generation = useRef(0);

  Future<void> flush({required bool checkpoint}) async {
    final current = log.value;
    final currentRecorder = recorder.value;
    if (current == null || currentRecorder == null) return;
    final drained = currentRecorder.drain();
    if (drained.points.isNotEmpty || drained.events.isNotEmpty) {
      try {
        await store.append(current.id,
            points: drained.points, events: drained.events);
      } catch (_) {
        currentRecorder.restore(points: drained.points, events: drained.events);
        rethrow;
      }
      pointCount.value += drained.points.length;
      livePointCount.value += drained.points
          .where((p) => p.source == PracticeLogSource.live)
          .length;
      eventCount.value += drained.events.length;
    }
    if (checkpoint) {
      final updated = current.copyWith(
          pointCount: pointCount.value,
          eventCount: eventCount.value,
          livePointCount: livePointCount.value);
      await store.checkpoint(updated);
      log.value = updated;
      lastCheckpoint.value = DateTime.now().toUtc();
    }
  }

  Future<void> finish() async {
    final current = log.value;
    if (current == null) return;
    timer.value?.cancel();
    timer.value = null;
    observerTimer.value?.cancel();
    observerTimer.value = null;
    await subscription.value?.cancel();
    subscription.value = null;
    try {
      await flush(checkpoint: false);
      final completed = current.copyWith(
          endedAt: DateTime.now().toUtc(),
          isComplete: true,
          pointCount: pointCount.value,
          eventCount: eventCount.value,
          livePointCount: livePointCount.value);
      await store.checkpoint(completed);
      await store.prune();
      log.value = null;
      // 確定した監視ログを「今日の記録」シート(R1)へ知らせる。
      PracticeLogStoreService.notifyFinished(completed.id);
    } catch (_) {
      // metaが未完了のまま残り、次回の一覧で回収できる。監視終了は妨げない。
      log.value = null;
    } finally {
      recorder.value = null;
    }
  }

  useEffect(() {
    if (!enabled ||
        teamId == null ||
        teamId.isEmpty ||
        recordedBy == null ||
        recordedBy.isEmpty) {
      if (log.value != null) unawaited(finish());
      return null;
    }
    final run = ++generation.value;
    unawaited(Future<void>(() async {
      final now = DateTime.now().toUtc();
      final id =
          'practice_${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final created = PracticeLog(
          id: id,
          teamId: teamId,
          recordedBy: recordedBy,
          startedAt: now,
          isComplete: false);
      try {
        await store.create(created);
        if (generation.value != run) return;
        recorder.value = PracticeLogRecorder(startedAt: now);
        pointCount.value = 0;
        livePointCount.value = 0;
        eventCount.value = 0;
        lastCheckpoint.value = now;
        error.value = null;
        log.value = created;
        recorder.value!.recordMessages(messages.value, now: now);
        subscription.value = geo.getObserverPositionStream().listen((position) {
          latestObserver.value = position;
          observerUnavailableReported.value = false;
        }, onError: (_) {
          if (!observerUnavailableReported.value) {
            recorder.value?.observerUnavailable(
                now: DateTime.now(), reason: 'stream_error');
            observerUnavailableReported.value = true;
          }
        });
        // 監視者トラックは observerTrackIntervalSec で刻む。保存間隔に
        // 相乗りさせると、flush間隔を変えた瞬間に記録間隔まで変わる。
        observerTimer.value = Timer.periodic(
            const Duration(seconds: observerTrackIntervalSec), (_) {
          final at = DateTime.now();
          final r = recorder.value;
          if (r == null) return;
          final position = latestObserver.value;
          if (position == null) {
            if (!observerUnavailableReported.value) {
              r.observerUnavailable(now: at, reason: 'no_position');
              observerUnavailableReported.value = true;
            }
            return;
          }
          r.recordObserver(
              observerId: recordedBy,
              lat: position.latitude,
              lng: position.longitude,
              positionAt: position.timestamp,
              now: at,
              accuracy: position.accuracy,
              speed: position.speed,
              course: position.heading);
        });
        timer.value = Timer.periodic(
            const Duration(seconds: practiceLogFlushIntervalSec), (_) {
          final at = DateTime.now();
          final r = recorder.value;
          if (r == null) return;
          r.tick(at);
          final due = lastCheckpoint.value == null ||
              at.difference(lastCheckpoint.value!) >=
                  const Duration(seconds: practiceLogCheckpointIntervalSec);
          unawaited(flush(checkpoint: due).catchError((_) {
            error.value = '練習ログを端末へ保存できませんでした。監視は継続しています。';
          }));
        });
      } catch (_) {
        if (generation.value == run) {
          error.value = '練習ログを開始できませんでした。監視は継続しています。';
        }
      }
    }));
    return () {
      generation.value++;
      if (log.value != null) unawaited(finish());
    };
  }, [enabled, teamId, recordedBy]);

  final enabledRef = useRef(enabled);
  enabledRef.value = enabled;
  useEffect(() {
    void record() {
      final r = recorder.value;
      if (!enabledRef.value || r == null) return;
      r.recordMessages(messages.value, now: DateTime.now());
    }

    messages.addListener(record);
    return () => messages.removeListener(record);
  }, [messages]);

  useEffect(() {
    final r = recorder.value;
    if (!enabled || r == null) return null;
    final next = anomalies.map((a) => a.key).toSet();
    for (final anomaly
        in anomalies.where((a) => !lastAnomalies.value.contains(a.key))) {
      r.recordEvent(DateTime.now(), 'boat_anomaly', {
        'boatId': anomaly.boatId,
        'kind': anomaly.kind.name,
        'detectedAt': anomaly.detectedAt.toUtc().toIso8601String()
      });
    }
    lastAnomalies.value = next;
    return null;
  }, [enabled, anomalies]);

  // 監視端末で漕手の警告を知らせた記録。実練習での通知回数が過剰でないかを
  // 後から確かめるために残す(原則4)。
  useEffect(() {
    final r = recorder.value;
    if (!enabled || r == null) return null;
    final since = lastWarningNotificationAt.value;
    for (final vibration in warningNotifications) {
      if (since != null && !vibration.at.isAfter(since)) continue;
      r.recordEvent(vibration.at, 'observer_warning_notified', {
        'vibrated': observerWarnings?.vibrationEnabled.value ?? false,
        'band': vibration.band.name,
        'boats': [
          for (final warning in vibration.warnings)
            {
              'boatId': warning.boatId,
              'category': warning.categoryCode,
              'band': warning.band.name,
            },
        ],
      });
      lastWarningNotificationAt.value = vibration.at;
    }
    return null;
  }, [enabled, warningNotifications]);

  useOnAppLifecycleStateChange((previous, current) {
    final r = recorder.value;
    if (r == null) return;
    // inactive は通知シェード・着信・アプリスイッチャーのプレビューでも
    // 一瞬立つ。これを中断として記録すると偽の recorder_gap が量産され、
    // 本物の欠測が埋もれる。実際に処理が止まる paused / hidden だけを見る。
    if (current == AppLifecycleState.paused ||
        current == AppLifecycleState.hidden) {
      r.pause(DateTime.now(), state: current.name);
    }
    if (current == AppLifecycleState.resumed) {
      r.resume(DateTime.now(), state: current.name);
    }
    unawaited(flush(checkpoint: true).catchError((_) {}));
  });
  return UsePracticeLogRecording(
    log: log,
    error: error,
    recordEvent: (type, details) =>
        recorder.value?.recordEvent(DateTime.now(), type, details),
  );
}
