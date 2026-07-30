import '../config/coach_config.dart';
import '../config/practice_log_config.dart';
import '../models/message_model.dart';
import '../models/practice_log_model.dart';

/// 受信済みの位置列を一括ログ用の点・イベントへ変換する純Dart状態機械。
/// 失敗しても呼び出し元の監視表示へ例外を返さないよう、I/Oは持たない。
class PracticeLogRecorder {
  final DateTime startedAt;
  final int maxPoints;
  final Duration lostAfter;
  final Map<String, _BoatState> _boats = {};
  final List<PracticeLogPoint> _points = [];
  final List<PracticeLogEvent> _events = [];
  bool _limited = false;
  DateTime? _pausedAt;

  PracticeLogRecorder(
      {required this.startedAt,
      this.maxPoints = maxPracticeLogPoints,
      Duration? lostAfter})
      : lostAfter = lostAfter ?? const Duration(seconds: trailDurationSec);
  bool get isLimited => _limited;

  void recordMessages(Iterable<Message> messages, {required DateTime now}) {
    for (final message in messages) {
      recordMessage(message, now: now);
    }
  }

  void recordMessage(Message message, {required DateTime now}) {
    if (_limited) return;
    final state = _boats.putIfAbsent(message.boatId, _BoatState.new);
    final key = '${message.sessionId}:${message.sequence}';
    if (state.lastKey == key) return;
    final previousSession = state.sessionId;
    final previousSequence = state.sequence;
    if (previousSession != null && previousSession != message.sessionId) {
      _event(now, 'boat_session_changed', {
        'boatId': message.boatId,
        'fromSessionId': previousSession,
        'toSessionId': message.sessionId
      });
    } else if (previousSequence != null &&
        message.sequence > previousSequence + 1) {
      _event(now, 'gap', {
        'boatId': message.boatId,
        'sessionId': message.sessionId,
        'fromSeq': previousSequence,
        'toSeq': message.sequence,
        'missingCount': message.sequence - previousSequence - 1,
        'from': state.lastReceivedAt?.toUtc().toIso8601String(),
        'to': now.toUtc().toIso8601String()
      });
    }
    state
      ..lastKey = key
      ..sessionId = message.sessionId
      ..sequence = message.sequence
      ..lastReceivedAt = now.toUtc()
      ..lostEmitted = false;
    _point(PracticeLogPoint(
        t: now.toUtc(),
        source: PracticeLogSource.live,
        boatId: message.boatId,
        displayName: message.displayName,
        sessionId: message.sessionId,
        sequence: message.sequence,
        lat: message.lat,
        lng: message.lng,
        speed: message.speed,
        course: message.heading,
        accuracy: message.accuracy,
        battery: message.battery,
        presentationState: message.presentationState,
        safetyRunMode: message.safetyRunMode,
        audioSuppressedAshore: message.audioSuppressedAshore,
        ageSec: _age(now, message.serverUpdatedAt ?? message.timestamp)));
  }

  void recordObserver(
      {required String observerId,
      required double lat,
      required double lng,
      required DateTime positionAt,
      required DateTime now,
      double? accuracy,
      double? speed,
      double? course}) {
    if (_limited) return;
    _point(PracticeLogPoint(
        t: now.toUtc(),
        source: PracticeLogSource.observer,
        boatId: observerId,
        lat: lat,
        lng: lng,
        speed: speed,
        course: course,
        accuracy: accuracy,
        ageSec: _age(now, positionAt)));
  }

  void observerUnavailable({required DateTime now, required String reason}) =>
      _event(now, 'observer_position_unavailable', {'reason': reason});
  void recordEvent(DateTime now, String type, Map<String, dynamic> details) =>
      _event(now, type, details);

  void tick(DateTime now) {
    for (final entry in _boats.entries) {
      final last = entry.value.lastReceivedAt;
      if (last != null &&
          !entry.value.lostEmitted &&
          now.difference(last) > lostAfter) {
        entry.value.lostEmitted = true;
        _event(now, 'boat_lost', {
          'boatId': entry.key,
          'lastReceivedAt': last.toUtc().toIso8601String(),
          'ageSec': now.difference(last).inMilliseconds / 1000
        });
      }
    }
  }

  void pause(DateTime now, {required String state}) {
    // hidden → paused のように中断が2段で来る端末がある。中断は1回として
    // 数え、開始時刻は最初のものを保つ。
    if (_pausedAt != null) return;
    _pausedAt = now.toUtc();
    _event(now, 'recorder_paused', {'state': state});
  }

  void resume(DateTime now, {required String state}) {
    final paused = _pausedAt;
    _event(now, 'recorder_resumed', {'state': state});
    if (paused != null) {
      _event(now, 'recorder_gap', {
        'from': paused.toIso8601String(),
        'to': now.toUtc().toIso8601String(),
        'reason': 'app_background'
      });
    }
    _pausedAt = null;
  }

  ({List<PracticeLogPoint> points, List<PracticeLogEvent> events}) drain() {
    final result = (
      points: List<PracticeLogPoint>.from(_points),
      events: List<PracticeLogEvent>.from(_events)
    );
    _points.clear();
    _events.clear();
    return result;
  }

  /// 端末I/Oが一時的に失敗したとき、未保存分を次回flushへ戻す。
  void restore({
    required Iterable<PracticeLogPoint> points,
    required Iterable<PracticeLogEvent> events,
  }) {
    _points.insertAll(0, points);
    _events.insertAll(0, events);
  }

  void _point(PracticeLogPoint point) {
    if (_limited) return;
    // drain 済みも含めた通算で数える。未保存分と通算を足すと二重に数え、
    // 上限へ届く前に記録が止まる。
    if (_totalPoints >= maxPoints) {
      _limited = true;
      _event(point.t, 'recorder_limit_reached', {'maxPoints': maxPoints});
      return;
    }
    _points.add(point);
    _totalPoints++;
  }

  int _totalPoints = 0;
  void _event(DateTime at, String type, Map<String, dynamic> details) =>
      _events.add(PracticeLogEvent(
          t: at.toUtc(),
          elapsedMs: at.toUtc().difference(startedAt.toUtc()).inMilliseconds,
          type: type,
          details: details));
  static double _age(DateTime now, DateTime at) {
    final value = now.toUtc().difference(at.toUtc()).inMilliseconds / 1000;
    return value < 0 ? 0 : value;
  }
}

class _BoatState {
  String? lastKey;
  String? sessionId;
  int? sequence;
  DateTime? lastReceivedAt;
  bool lostEmitted = false;
}
