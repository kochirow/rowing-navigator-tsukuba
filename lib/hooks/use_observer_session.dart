import 'package:flutter/foundation.dart';

import '../models/boat_model.dart';
import '../models/message_model.dart';
import '../services/channel_centerline.dart';
import '../services/channel_lane_resolver.dart';
import 'use_coach_watch.dart';
import 'use_observer_background_alerts.dart';
import 'use_observer_warning_alerts.dart';
import 'use_practice_log_recording.dart';

/// 監視中に動くもの(航跡・異常検知、漕手の警告の知らせ、監視ログ)をまとめる。
///
/// 地図の画面は、ここから表示に要るものだけを受け取る。監視の仕組みを
/// 1か所で見渡せるようにし、画面のファイルを太らせないために切り出した。
class UseObserverSession {
  final UseCoachWatch coachWatch;
  final UseObserverWarningAlerts warnings;
  final UsePracticeLogRecording recording;

  /// 監視端末が背面にある間の通知(R3)。
  final UseObserverBackgroundAlerts backgroundAlerts;

  const UseObserverSession({
    required this.coachWatch,
    required this.warnings,
    required this.recording,
    required this.backgroundAlerts,
  });
}

UseObserverSession useObserverSession({
  required bool enabled,
  required ValueListenable<List<Boat>> otherBoats,
  required ValueListenable<List<Message>> receivedMessages,
  required String? teamId,
  required String? recordedBy,
  ChannelCenterline? channelCenterline,
  ChannelLaneResolver? channelLaneResolver,
}) {
  final coachWatch = useCoachWatch(
    otherBoats: otherBoats,
    enabled: enabled,
    channelCenterline: channelCenterline,
    channelLaneResolver: channelLaneResolver,
  );
  final warnings = useObserverWarningAlerts(
    enabled: enabled,
    messages: receivedMessages.value,
  );
  final recording = usePracticeLogRecording(
    enabled: enabled,
    teamId: teamId,
    recordedBy: recordedBy,
    messages: receivedMessages,
    anomalies: coachWatch.anomalies.value,
    observerWarnings: warnings,
  );
  final backgroundAlerts = useObserverBackgroundAlerts(
    enabled: enabled,
    messages: receivedMessages,
    onRecord: recording.recordEvent,
  );
  return UseObserverSession(
    coachWatch: coachWatch,
    warnings: warnings,
    recording: recording,
    backgroundAlerts: backgroundAlerts,
  );
}
