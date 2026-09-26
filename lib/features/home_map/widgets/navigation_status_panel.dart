import 'dart:async';

import 'package:flutter/material.dart';

import 'nav_lower_drums.dart';
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

  /// 下半分(ドラム)。null なら距離と経過時間から作る。
  final NavLowerValues? lowerValues;
  final int lowerLeftIndex;
  final int lowerRightIndex;
  final ValueChanged<int>? onLowerLeftChanged;
  final ValueChanged<int>? onLowerRightChanged;
  final VoidCallback? onLowerReset;

  /// 直前の RESET を取り消す。RESET のあとの通知に「元に戻す」として出す。
  final VoidCallback? onLowerUndo;

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
    this.lowerValues,
    this.lowerLeftIndex = 0,
    this.lowerRightIndex = 1,
    this.onLowerLeftChanged,
    this.onLowerRightChanged,
    this.onLowerReset,
    this.onLowerUndo,
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

  /// RESET。押し間違いに備えて、通知に「元に戻す」を付ける。
  void _reset() {
    widget.onLowerReset?.call();
    final undo = widget.onLowerUndo;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: const Text('下の計器を0にしました(記録は練習全体を残します)'),
      action:
          undo == null ? null : SnackBarAction(label: '元に戻す', onPressed: undo),
    ));
  }

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
      lowerValues: widget.lowerValues,
      lowerLeftIndex: widget.lowerLeftIndex,
      lowerRightIndex: widget.lowerRightIndex,
      onLowerLeftChanged: widget.onLowerLeftChanged,
      onLowerRightChanged: widget.onLowerRightChanged,
      onLowerReset: widget.onLowerReset == null ? null : _reset,
    );
  }
}
