import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/gps_health_monitor.dart';
import '../../../services/rowing_motion_fusion.dart';
import '../../../services/stroke_speed_trace.dart';
import 'nav_status_card.dart';

/// 時刻による1秒更新を地図画面全体から切り離すためのパネル。
class NavigationStatusPanel extends StatefulWidget {
  final int paceSeconds;
  final int distanceMeters;
  final double? spm;
  final RowingMotionMetrics? strokeMotion;
  final bool strokeMotionDisplayEnabled;
  final StrokeSpeedTraceWindow? Function(DateTime now)? strokeTraceWindowBuilder;
  final bool spmMeasurementEnabled;
  final bool compact;
  final bool portraitCompact;
  final DateTime? sessionStartedAt;
  final DateTime? lastGpsTimestamp;
  final GpsHealthQuality gpsQuality;
  final bool gpsStreamRecovering;
  final bool positionSharingUnavailable;
  final bool otherBoatReceiveUnavailable;
  final bool temporaryObstacleReceiveUnavailable;
  final String safetySettingsLabel;
  final bool safetySettingsNeedsAttention;
  final int? pendingSharedSafetyRevision;
  final VoidCallback? onApplyPendingSafetySettings;

  final DateTime Function()? clock;

  const NavigationStatusPanel({
    super.key,
    required this.paceSeconds,
    required this.distanceMeters,
    required this.sessionStartedAt,
    required this.lastGpsTimestamp,
    this.gpsQuality = GpsHealthQuality.good,
    this.gpsStreamRecovering = false,
    this.spm,
    this.strokeMotion,
    this.strokeMotionDisplayEnabled = false,
    this.strokeTraceWindowBuilder,
    this.spmMeasurementEnabled = false,
    this.compact = false,
    this.portraitCompact = false,
    this.positionSharingUnavailable = false,
    this.otherBoatReceiveUnavailable = false,
    this.temporaryObstacleReceiveUnavailable = false,
    this.safetySettingsLabel = '安全設定: 読込中',
    this.safetySettingsNeedsAttention = true,
    this.pendingSharedSafetyRevision,
    this.onApplyPendingSafetySettings,
    this.clock,
  });

  @override
  State<NavigationStatusPanel> createState() => _NavigationStatusPanelState();
}

class _NavigationStatusPanelState extends State<NavigationStatusPanel> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = _readNow();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = _readNow());
    });
  }

  @override
  void didUpdateWidget(covariant NavigationStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 親がGPS更新で再buildされた場合も、表示時刻を即時合わせる。
    _now = _readNow();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  int _ageSeconds(DateTime? timestamp) {
    if (timestamp == null) return 0;
    return _now.difference(timestamp).inSeconds.clamp(0, 9999).toInt();
  }

  DateTime _readNow() => widget.clock?.call() ?? DateTime.now();

  @override
  Widget build(BuildContext context) {
    return NavStatusCard(
      paceSeconds: widget.paceSeconds,
      distanceMeters: widget.distanceMeters,
      elapsedTimeSeconds: _ageSeconds(widget.sessionStartedAt),
      spm: widget.spm,
      strokeMotion: widget.strokeMotion,
      strokeMotionDisplayEnabled: widget.strokeMotionDisplayEnabled,
      strokeTraceWindowBuilder: widget.strokeTraceWindowBuilder,
      spmMeasurementEnabled: widget.spmMeasurementEnabled,
      compact: widget.compact,
      portraitCompact: widget.portraitCompact,
      gpsAgeSeconds: widget.lastGpsTimestamp == null
          ? null
          : _ageSeconds(widget.lastGpsTimestamp),
      gpsQuality: widget.gpsQuality,
      gpsStreamRecovering: widget.gpsStreamRecovering,
      positionSharingUnavailable: widget.positionSharingUnavailable,
      otherBoatReceiveUnavailable: widget.otherBoatReceiveUnavailable,
      temporaryObstacleReceiveUnavailable:
          widget.temporaryObstacleReceiveUnavailable,
      safetySettingsLabel: widget.safetySettingsLabel,
      safetySettingsNeedsAttention: widget.safetySettingsNeedsAttention,
      pendingSharedSafetyRevision: widget.pendingSharedSafetyRevision,
      onApplyPendingSafetySettings: widget.onApplyPendingSafetySettings,
    );
  }
}
