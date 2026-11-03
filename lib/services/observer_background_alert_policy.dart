import '../config/coach_config.dart';
import '../models/message_model.dart';
import '../types/boat_type.dart';
import 'observer_warning_notifier.dart';

/// 監視端末が背面にある間に、通知で知らせる種類(R3)。
enum ObserverBackgroundAlertKind {
  /// 漕手に警告の音が鳴った。
  warning,

  /// 更新途絶([lostAlertSec])。
  lost,

  /// 長時間停止([observerBackgroundStoppedNotifySec])。
  stopped;

  /// 艇一覧の上の切り替えに出す短い名前。
  String get settingsLabel => switch (this) {
        ObserverBackgroundAlertKind.warning => '漕手の警告',
        ObserverBackgroundAlertKind.lost => '更新途絶',
        ObserverBackgroundAlertKind.stopped => '長時間停止',
      };

  static ObserverBackgroundAlertKind? fromName(String name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// 出す通知1件。同じ艇は同じIDで上書きする(艇ごとに1つ)。
class ObserverBackgroundAlert {
  final String boatId;
  final ObserverBackgroundAlertKind kind;

  /// 通知の本文。「艇名：種類」(例「4+ 後藤：長時間停止」)。
  final String body;
  final DateTime at;

  const ObserverBackgroundAlert({
    required this.boatId,
    required this.kind,
    required this.body,
    required this.at,
  });

  /// 記録(`observer_background_notified`)に残す形。
  Map<String, dynamic> toDiagnosticDetails({required bool delivered}) => {
        'boatId': boatId,
        'kind': kind.name,
        'body': body,
        'delivered': delivered,
      };
}

/// 艇が「控えめにする場所」(係留区域・港の中)にいるかを答える関数。
typedef QuietPlaceTest = bool Function(double lat, double lng);

/// 背面の監視端末で、どの通知を出すかを決める(純Dart)。
///
/// 受信のたびと一定間隔に [update] を呼ぶ。どちらも画面の描画に頼らないので、
/// 背面でも動く。通知そのものは呼び出し側が出す。
///
/// - **前面にある間([foreground])と、切った種類は、通知せずに消化する。**
///   前面ではバイブと艇一覧が受け持つ。背面へ回った瞬間に、続いていた
///   状態をまとめて通知しても役に立たない。
/// - 警告: [ObserverWarningNotifier] と同じ規則(種類が変わるまで繰り返さない・
///   無音が続いたら再武装)。
/// - 更新途絶: 最後の受信から [lostAfter] を超えたら1回。係留区域・港の中・
///   陸上判定中に途絶えた艇(練習を終えた艇)は出さない。次に受信したら再武装。
/// - 長時間停止: [stoppedSpeedForAlert] 未満が [stoppedAfter] 続いたら1回。
///   係留区域・港の中・陸上判定中の艇と、途絶えている艇は出さない。
///   動き出したら再武装。
///
/// 受信した他艇の警告状態は、監視端末での通知・表示にだけ使う(不変条件12)。
class ObserverBackgroundAlertPolicy {
  ObserverBackgroundAlertPolicy({
    required this.isQuietPlace,
    this.stoppedAfter =
        const Duration(seconds: observerBackgroundStoppedNotifySec),
    this.lostAfter = const Duration(seconds: lostAlertSec),
    ObserverWarningNotifier? warningNotifier,
  }) : _warnings = warningNotifier ?? ObserverWarningNotifier();

  final QuietPlaceTest isQuietPlace;
  final Duration stoppedAfter;
  final Duration lostAfter;
  final ObserverWarningNotifier _warnings;
  final Map<String, _BoatTrack> _boats = {};

  List<ObserverBackgroundAlert> update({
    required Iterable<Message> messages,
    required DateTime now,
    required bool foreground,
    required Set<ObserverBackgroundAlertKind> enabled,
  }) {
    final latest = <String, Message>{};
    for (final message in messages) {
      final previous = latest[message.boatId];
      if (previous == null ||
          _observedAt(message).isAfter(_observedAt(previous))) {
        latest[message.boatId] = message;
      }
    }
    for (final message in latest.values) {
      _observe(message);
    }

    final alerts = <ObserverBackgroundAlert>[];
    void offer(ObserverBackgroundAlert alert) {
      // 前面・切った種類は消化だけする(印は付いているので後で出さない)。
      if (foreground || !enabled.contains(alert.kind)) return;
      alerts.add(alert);
    }

    final warningUpdate = _warnings.update(
      inputs: latest.values.map((message) => ObserverWarningInput(
            boatId: message.boatId,
            presentationState: message.presentationState,
            observedAt: _observedAt(message),
          )),
      now: now,
      deliver: true,
    );
    for (final warning
        in warningUpdate.vibration?.warnings ?? const <ObserverBoatWarning>[]) {
      final track = _boats[warning.boatId];
      offer(ObserverBackgroundAlert(
        boatId: warning.boatId,
        kind: ObserverBackgroundAlertKind.warning,
        body: '${track?.label ?? '艇'}：${warning.listLabel}',
        at: now,
      ));
    }

    for (final entry in _boats.entries) {
      final track = entry.value;
      final silentFor = now.difference(track.lastObservedAt);
      final quiet =
          track.lastAshore || isQuietPlace(track.lastLat, track.lastLng);
      if (silentFor > lostAfter) {
        if (!track.lostHandled) {
          track.lostHandled = true;
          if (!quiet) {
            offer(ObserverBackgroundAlert(
              boatId: entry.key,
              kind: ObserverBackgroundAlertKind.lost,
              body: '${track.label}：更新途絶（${lostAfter.inSeconds}秒以上）',
              at: now,
            ));
          }
        }
        continue;
      }
      final stoppedSince = track.stoppedSince;
      if (stoppedSince != null &&
          !track.stoppedHandled &&
          now.difference(stoppedSince) >= stoppedAfter) {
        track.stoppedHandled = true;
        if (!quiet) {
          offer(ObserverBackgroundAlert(
            boatId: entry.key,
            kind: ObserverBackgroundAlertKind.stopped,
            body: '${track.label}：長時間停止（${stoppedAfter.inMinutes}分以上）',
            at: now,
          ));
        }
      }
    }
    return alerts;
  }

  void _observe(Message message) {
    final observedAt = _observedAt(message);
    final track = _boats[message.boatId];
    if (track != null && !observedAt.isAfter(track.lastObservedAt)) return;
    final next = track ?? _BoatTrack(observedAt);
    next
      ..label = boatNameLabel(message.boatType, message.displayName)
      ..lastObservedAt = observedAt
      ..lastLat = message.lat
      ..lastLng = message.lng
      ..lastAshore = message.audioSuppressedAshore
      ..lostHandled = false;
    if (message.speed.isFinite && message.speed < stoppedSpeedForAlert) {
      next.stoppedSince ??= observedAt;
    } else {
      // 速度が分からないときも「止まっている」とは数えない(原則6の裏返しで、
      // 欠損を通知の根拠にしない)。動き出したら再武装する。
      next
        ..stoppedSince = null
        ..stoppedHandled = false;
    }
    _boats[message.boatId] = next;
  }

  static DateTime _observedAt(Message message) =>
      message.serverUpdatedAt ?? message.timestamp;
}

class _BoatTrack {
  _BoatTrack(this.lastObservedAt);

  String label = '艇';
  DateTime lastObservedAt;
  double lastLat = 0;
  double lastLng = 0;
  bool lastAshore = false;
  DateTime? stoppedSince;
  bool stoppedHandled = false;
  bool lostHandled = false;
}
