import 'package:flutter/material.dart';

import '../../../models/navigation_warning.dart';
import '../../../theme/hazard_palette.dart';

/// activeな警告を画面上部にカテゴリ色付きで並べる。
///
/// 表示は2段構え。
/// - 1行目: 対象(「岸」「他艇」)。走りながら一瞥で読める大きさ。
/// - 2行目: 方向と残り秒数(「右 5秒」)。漕手は後ろ向きで前を見ていないため、
///   振り向く側が分からないと判断に時間を失う。音を増やさずに足せる情報。
///
/// 切迫度([NavigationWarning.urgency])で見た目を変える。風・後ろ向き・
/// イヤホン無しでは音が届かないことがあり、そのとき「連続音が鳴っている」のか
/// 「表示だけ」なのかを目で区別できないと、鳴っていない警告と同じ重みで
/// 扱ってしまう。
/// - `imminent`(連続音): 太枠 + 白い脈動。周辺視野でも気づける。
/// - `action`(単発・断続音): 濃色。
/// - `monitoring`(表示のみ): 淡色。
class SafetyBanner extends StatelessWidget {
  final NavigationWarning? warning;
  final List<NavigationWarning> warnings;

  const SafetyBanner({
    super.key,
    this.warning,
    this.warnings = const [],
  });

  /// 連続音が鳴っている警告があるか。計器の縮小と触覚の判断に使う。
  static bool hasImminent(List<NavigationWarning> warnings) => warnings
      .any((warning) => warning.urgency == WarningDisplayUrgency.imminent);

  /// 同じ種類の警告を1枚へまとめる。
  ///
  /// 岸の危険区域は基準線の各辺を長方形へ展開したものなので、岸沿いを走ると
  /// 同じ「岸」チップが複数枚並ぶ。判定は区域ごとのままにして、表示だけ
  /// 最も切迫した1件へ集約し、残りは件数で示す。
  static List<_WarningGroup> _groupByCategory(
    List<NavigationWarning> warnings,
  ) {
    final groups = <String, _WarningGroup>{};
    for (final warning in warnings) {
      final existing = groups[warning.category];
      if (existing == null) {
        groups[warning.category] = _WarningGroup(warning, 1);
        continue;
      }
      groups[warning.category] = _WarningGroup(
        _moreUrgent(existing.representative, warning),
        existing.count + 1,
      );
    }
    return groups.values.toList(growable: false);
  }

  /// 音が鳴っている段階を優先し、次に現在発生中、最後に到達が早いほうを残す。
  static NavigationWarning _moreUrgent(
    NavigationWarning current,
    NavigationWarning next,
  ) {
    if (current.urgency != next.urgency) {
      return next.urgency.index > current.urgency.index ? next : current;
    }
    if (current.isPredicted != next.isPredicted) {
      return current.isPredicted ? next : current;
    }
    final currentSeconds = current.secondsUntilDanger ?? 1 << 30;
    final nextSeconds = next.secondsUntilDanger ?? 1 << 30;
    return nextSeconds < currentSeconds ? next : current;
  }

  @override
  Widget build(BuildContext context) {
    final activeWarnings = warnings.isNotEmpty
        ? warnings
        : warning == null
            ? const <NavigationWarning>[]
            : <NavigationWarning>[warning!];
    if (activeWarnings.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 5,
        children: [
          for (final group in _groupByCategory(activeWarnings))
            _WarningChip(warning: group.representative, count: group.count),
        ],
      ),
    );
  }
}

class _WarningGroup {
  final NavigationWarning representative;
  final int count;

  const _WarningGroup(this.representative, this.count);
}

class _WarningChip extends StatelessWidget {
  final NavigationWarning warning;
  final int count;

  const _WarningChip({required this.warning, this.count = 1});

  @override
  Widget build(BuildContext context) {
    final baseColor = HazardPalette.colorOf(context, warning.category);
    final urgency = warning.urgency;
    // 音が鳴らない段階(表示のみ)だけを淡色にする。以前は「予測かどうか」で
    // 淡色にしていたが、8秒先の予測でも断続音は鳴っているため、
    // 淡色 = 静か、という読み方ができなかった。
    final isQuiet = urgency == WarningDisplayUrgency.monitoring;
    final background =
        isQuiet ? Color.lerp(baseColor, Colors.white, 0.48)! : baseColor;
    // 橋の警告色は明るい黄系なので、現在警告でも濃色文字にして
    // 日光下のコントラストを確保する。他カテゴリの濃色背景は白を使う。
    final foreground = isQuiet || warning.category == 'bridge'
        ? const Color(0xFF241A1A)
        : Colors.white;
    final borderWidth = switch (urgency) {
      WarningDisplayUrgency.imminent => 3.0,
      WarningDisplayUrgency.action => 2.0,
      WarningDisplayUrgency.monitoring => 1.5,
    };
    final labelSize = urgency == WarningDisplayUrgency.imminent ? 26.0 : 22.0;
    final minHeight = urgency == WarningDisplayUrgency.imminent ? 46.0 : 38.0;
    final seconds = warning.secondsUntilDanger;
    final predictionText = seconds == null ? null : '約$seconds秒後に危険';
    final displayLabel = _displayLabel(warning);
    final detail = _detailLabel(warning);
    final semanticParts = [
      warning.title,
      if (warning.directionLabel != null) warning.directionLabel!,
      if (predictionText != null) predictionText,
      if (count > 1) '$count件',
      if (warning.message.isNotEmpty) warning.message,
    ];

    return Semantics(
      // 音が聞こえない利用者にとって、警告の出現を知る唯一の即時経路。
      // label だけでは出現時に読み上げられない。
      liveRegion: true,
      label: semanticParts.join('。'),
      child: _PulseFrame(
        enabled: urgency == WarningDisplayUrgency.imminent,
        child: Container(
          key: ValueKey('safety-warning-${warning.key}'),
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: isQuiet ? baseColor.withValues(alpha: 0.75) : Colors.white,
              width: borderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                warning.isPredicted
                    ? Icons.schedule_rounded
                    : Icons.warning_amber_rounded,
                color: foreground,
                size: 18,
              ),
              const SizedBox(width: 5),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: labelSize,
                          height: 1.05,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (count > 1) ...[
                        const SizedBox(width: 3),
                        Text(
                          '×$count',
                          style: TextStyle(
                            color: foreground,
                            fontSize: 13,
                            height: 1.05,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 14,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「右 5秒」。方向も秒数も無ければ2行目を出さない。
  static String? _detailLabel(NavigationWarning warning) {
    final parts = <String>[
      if (warning.directionLabel != null) warning.directionLabel!,
      if (warning.secondsUntilDanger != null) '${warning.secondsUntilDanger}秒',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  static String _displayLabel(NavigationWarning warning) =>
      switch (warning.category) {
        'shore' => '岸',
        'bridge' => '橋',
        'bridgePier' => '橋脚',
        'island' => '中洲',
        'driftwood' => '流木',
        'pile' => '杭',
        'other_boat' => '他艇',
        'curve' => 'カーブ',
        'reverse' => '逆走',
        'testZone' => 'テスト',
        'gps_unavailable' => 'GPS',
        'position_sharing_unavailable' => '位置共有',
        'other_boat_receive_unavailable' => '他艇受信',
        'other_boat_track_lost' => '他艇途絶',
        'static_profile_unavailable' => '危険区域',
        'audio_unavailable' => '警告音',
        'pipeline_unresponsive' => '警告停止',
        _ => warning.title,
      };
}

/// 連続音が鳴っている警告のまわりだけ、白い縁を1秒周期で明滅させる。
///
/// 直射日光の下では色の差が潰れやすく、静止した濃色チップは背景の一部として
/// 見落とされる。動きは周辺視野に届くため、視線を計器に置いたままでも
/// 「今まさに鳴っている」ことに気づける。
///
/// [enabled] が false のときはアニメーションを完全に止め、素通しで返す。
/// 常時動くものを画面に置くと電池を食い、通常の航行中も注意を奪うため。
/// 止めた [AnimationController] はtickしないので、保持したままでも電池は食わない。
///
/// **controller は [initState] で1度だけ作る。** [SingleTickerProviderStateMixin]
/// の `createTicker` は、古い Ticker を dispose 済みかどうかに関係なく2本目を
/// assert で拒否する。`enabled` が false→true になるたびに作り直すと、
/// `imminent → action → imminent`(バンドは到達時間だけで決まり、境界の7秒を
/// 相対速度の揺れで何度も跨ぐ)の遷移で FlutterError が投げられ、警告チップが
/// ErrorWidget へ置き換わって「他艇」の文字が画面から消える。
///
/// 注意: 有効時は無限に繰り返すため、`imminent` の警告を出したまま
/// `pumpAndSettle` を呼ぶウィジェットテストは完了しない。`pump(duration)` を使う。
class _PulseFrame extends StatefulWidget {
  final bool enabled;
  final Widget child;

  const _PulseFrame({required this.enabled, required this.child});

  @override
  State<_PulseFrame> createState() => _PulseFrameState();
}

class _PulseFrameState extends State<_PulseFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    if (widget.enabled) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PulseFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;
    if (widget.enabled) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color:
              Colors.white.withValues(alpha: 0.15 + 0.55 * _controller.value),
        ),
        child: child,
      ),
    );
  }
}
