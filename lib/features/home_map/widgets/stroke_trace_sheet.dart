import 'dart:async';

import 'package:flutter/material.dart';

import '../../../config/stroke_trace_config.dart';
import '../../../models/shared_stroke_trace.dart';
import '../../../services/stroke_speed_trace.dart';
import '../../../services/stroke_trace_history.dart';
import '../../../services/stroke_trace_share_service.dart';
import '../../../theme/app_theme.dart';
import 'stroke_metrics_chips.dart';
import 'stroke_speed_chart.dart';

/// 監視端末で、選んだ1艇の艇速変化を見るシート。
///
/// **開いている艇の1隻ぶんだけを購読する。** 位置共有と違って全艇を
/// 受け取らないので、監視していない艇の波形は転送されない。閉じれば
/// 購読も止まる。これが無料枠を守るための一番効く設計判断である。
///
/// 表示は監視の補助であり、警告にも艇の描画にも影響しない。
/// 受信できないことは隠さず、そのまま理由として出す(原則6)。
class StrokeTraceSheet extends StatefulWidget {
  final String boatId;
  final String displayName;

  /// テスト用の差し替え口。省略時はRTDBを購読する。
  final Stream<SharedStrokeTrace?> Function(String boatId)? watch;
  final DateTime Function()? clock;

  const StrokeTraceSheet({
    super.key,
    required this.boatId,
    required this.displayName,
    this.watch,
    this.clock,
  });

  @override
  State<StrokeTraceSheet> createState() => _StrokeTraceSheetState();
}

class _StrokeTraceSheetState extends State<StrokeTraceSheet> {
  final _history = StrokeTraceHistory();
  StreamSubscription<SharedStrokeTrace?>? _subscription;
  Timer? _freshnessTimer;
  SharedStrokeTrace? _latest;
  bool _receivedAnything = false;
  String? _error;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _subscribe();
    // 鮮度ラベルだけを1秒で更新する。グラフはTickerが別に流す。
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _subscribe() {
    try {
      final stream =
          (widget.watch ?? StrokeTraceShareService().watch)(widget.boatId);
      _subscription = stream.listen(
        (trace) {
          if (!mounted) return;
          setState(() {
            _error = null;
            if (trace == null) return;
            _receivedAnything = true;
            _latest = trace;
            _history.add(trace, receivedAt: _now);
          });
        },
        onError: (Object error) {
          if (!mounted) return;
          // 受信できないことを空白にしない。理由をそのまま出す。
          setState(() => _error = '受信できません');
        },
      );
    } catch (error) {
      _error = '受信できません';
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _freshnessTimer?.cancel();
    super.dispose();
  }

  StrokeSpeedTraceWindow? _window(DateTime now) {
    if (_history.isStale(now)) return null;
    return _history.window(now: now);
  }

  String _statusText() {
    if (_error != null) return _error!;
    if (!_receivedAnything) {
      return 'この艇は艇速変化を共有していません';
    }
    final age = _history.ageSince(_now);
    if (age == null) return '受信待ち';
    if (_history.isStale(_now)) {
      return '${age.inSeconds}秒前を最後に途絶';
    }
    return '${age.inSeconds}秒前の漕ぎ';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final now = _now;
    final stale = _history.isStale(now);
    final latest = _latest;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textDisabled,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.show_chart, color: colors.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (latest != null && !stale)
                  Text(
                    '${latest.spm.toStringAsFixed(0)} spm',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  stale ? Icons.cloud_off : Icons.circle,
                  size: stale ? 14 : 8,
                  color: stale ? colors.textSecondary : colors.ok,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _statusText(),
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            StrokeSpeedChart(
              key: const ValueKey('shared-stroke-speed-chart'),
              windowBuilder: _window,
              height: 132,
              onDarkSurface: false,
              // 途絶中に古い波形を流し続けない。止まった事実を出す。
              live: !stale,
              emptyLabel: _receivedAnything
                  ? '$sharedStrokeTraceFreshnessSeconds秒以上、新しい波形が届いていません'
                  : '波形の受信を待っています',
            ),
            const SizedBox(height: 12),
            if (latest != null)
              StrokeMetricsChips.fromSharedTrace(latest)
            else
              Text(
                '艇側で「SPM・艇速変化を計測する」と「監視へ共有する」が'
                'ONのときだけ表示できます。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            const SizedBox(height: 12),
            Text(
              '縦軸が艇速、横軸が時間。細い縦線がキャッチで、'
              '直近2ストロークぶんが表示されます。',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
