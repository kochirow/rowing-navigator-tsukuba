import 'dart:async';

import 'package:flutter/material.dart';

import 'nav_status_card.dart';

/// 時刻による1秒更新を地図画面全体から切り離すためのパネル。
class NavigationStatusPanel extends StatefulWidget {
  final int paceSeconds;
  final int distanceMeters;
  final double? spm;
  final bool spmMeasurementEnabled;
  final bool compact;
  final bool portraitCompact;
  final DateTime? sessionStartedAt;

  final DateTime Function()? clock;

  const NavigationStatusPanel({
    super.key,
    required this.paceSeconds,
    required this.distanceMeters,
    required this.sessionStartedAt,
    this.spm,
    this.spmMeasurementEnabled = false,
    this.compact = false,
    this.portraitCompact = false,
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
      spmMeasurementEnabled: widget.spmMeasurementEnabled,
      compact: widget.compact,
      portraitCompact: widget.portraitCompact,
    );
  }
}
