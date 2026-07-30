import 'package:flutter/material.dart';

import '../../../config/navigator_config.dart';
import '../../../services/gps_health_monitor.dart';
import '../../../theme/app_theme.dart';

/// 航行中に画面上部へ常時表示する計器カード。
///
/// 情報を3階層に分けて視線誘導を明確にする。
///   1. 主計器: ペース(/500m)。SPM実験機能がONの時だけレートを併記。
///   2. 補助: 距離・経過時間。
///   3. 状態: GPS鮮度・通信/対応水域の能力低下。異常時のみ強調し、正常時は最小。
/// 一番下に安全上の注記を最小ウェイトで常時表示する。
class NavStatusCard extends StatelessWidget {
  final int paceSeconds;
  final int distanceMeters;
  final int elapsedTimeSeconds;
  final double? spm; // ストロークレート(計測不能時はnull)
  final bool spmMeasurementEnabled; // ユーザーがSPM計測をONにしているか
  final bool compact; // 横向き用の省スペース表示
  final bool portraitCompact; // 縦向き用。主計器の可読性を保ちながら左上へ縮小
  final int? gpsAgeSeconds; // 最後のGPS測位からの経過秒(不明時はnull)
  final GpsHealthQuality gpsQuality;
  final bool positionSharingUnavailable;
  final bool otherBoatReceiveUnavailable;
  final bool temporaryObstacleReceiveUnavailable;
  final bool operationalCoverageLimited;
  final String safetySettingsLabel;
  final bool safetySettingsNeedsAttention;
  final int? pendingSharedSafetyRevision;
  final VoidCallback? onApplyPendingSafetySettings;

  /// 連続音の警告が出ている間、主計器を控えめにする。
  ///
  /// 画面でいちばん大きい数字がペースのままだと、一瞬のチラ見で最初に目へ
  /// 入るのが「2:05 /500m」になる。危険が迫っている間だけ主計器を縮め、
  /// 警告バナーを視線の一等地へ譲る。距離・時間・状態表示は消さない。
  final bool deemphasized;

  const NavStatusCard({
    super.key,
    required this.paceSeconds,
    required this.distanceMeters,
    required this.elapsedTimeSeconds,
    this.spm,
    this.spmMeasurementEnabled = false,
    this.compact = false,
    this.portraitCompact = false,
    this.gpsAgeSeconds,
    this.gpsQuality = GpsHealthQuality.good,
    this.positionSharingUnavailable = false,
    this.otherBoatReceiveUnavailable = false,
    this.temporaryObstacleReceiveUnavailable = false,
    this.operationalCoverageLimited = false,
    this.safetySettingsLabel = '安全設定: 読込中',
    this.safetySettingsNeedsAttention = true,
    this.pendingSharedSafetyRevision,
    this.onApplyPendingSafetySettings,
    this.deemphasized = false,
  });

  // 数字が変わっても幅が揺れない等幅数字
  static const _tabularFigures = [FontFeature.tabularFigures()];

  String _formatTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString()}:${remainingSeconds.toString().padLeft(2, '0')}';
    }
  }

  /// 停止中や極端な低速時は無意味な巨大ペースになるため '--:--' を表示
  String _formatPace(int seconds) {
    if (seconds <= 0 || seconds > 1800) return '--:--';
    return _formatTime(seconds);
  }

  String _formatDistance(int meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
    return '$meters m';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final onDark = colors.onDark;
    final onDarkSub = onDark.withValues(alpha: 0.7);

    final gpsStale = gpsQuality != GpsHealthQuality.good ||
        (gpsAgeSeconds != null && gpsAgeSeconds! >= gpsStaleIndicatorSec);
    final statusLabel = switch (gpsQuality) {
      GpsHealthQuality.unusable =>
        gpsAgeSeconds == null ? 'GPS捕捉中' : 'GPS再捕捉中 $gpsAgeSeconds秒前',
      GpsHealthQuality.degraded => 'GPS精度低下',
      GpsHealthQuality.good => gpsStale ? 'GPS $gpsAgeSeconds秒前' : null,
    };
    final degraded = positionSharingUnavailable ||
        otherBoatReceiveUnavailable ||
        temporaryObstacleReceiveUnavailable ||
        operationalCoverageLimited;

    // SPMは実験機能。OFF時は値だけでなく表示領域ごと取り除く。
    final spmValueText = spm?.toStringAsFixed(0) ?? '--';
    final capabilityBadges = <Widget>[
      if (otherBoatReceiveUnavailable)
        _CapabilityBadge(label: '他艇受信: 利用不可', color: colors.danger),
      if (positionSharingUnavailable)
        _CapabilityBadge(label: '自艇共有: 利用不可', color: colors.danger),
      if (temporaryObstacleReceiveUnavailable)
        _CapabilityBadge(label: '臨時危険区域: 受信不可', color: colors.danger),
      if (operationalCoverageLimited)
        _CapabilityBadge(label: '固定危険区域: 未検証水域', color: colors.warning),
    ];

    if (compact || portraitCompact) {
      return _buildCompact(
        colors: colors,
        onDark: onDark,
        onDarkSub: onDarkSub,
        gpsStale: gpsStale,
        statusLabel: statusLabel,
        degraded: degraded,
        spmValueText: spmValueText,
        portrait: portraitCompact,
      );
    }

    return Container(
      margin: EdgeInsets.symmetric(
        vertical: dimens.space2,
        horizontal: dimens.space3,
      ),
      padding: EdgeInsets.fromLTRB(
        dimens.space5,
        dimens.space3,
        dimens.space5,
        dimens.space2,
      ),
      decoration: BoxDecoration(
        color: colors.mapPanelScrim,
        borderRadius: dimens.borderLg,
        boxShadow: [
          dimens.shadow(Colors.black.withValues(alpha: 0.25)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- 第1階層(主計器): ペース / レート ----
          Row(
            children: [
              Expanded(
                flex: 3,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _formatPace(paceSeconds),
                        style: TextStyle(
                          fontSize: deemphasized ? 32 : 52,
                          height: 1.1,
                          fontWeight: FontWeight.bold,
                          color: onDark,
                          fontFeatures: _tabularFigures,
                        ),
                      ),
                      Text(
                        ' /500m',
                        style: TextStyle(fontSize: 18, color: onDarkSub),
                      ),
                    ],
                  ),
                ),
              ),
              if (spmMeasurementEnabled && !deemphasized) ...[
                SizedBox(width: dimens.space3),
                Expanded(
                  flex: 2,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          spmValueText,
                          style: TextStyle(
                            fontSize: 44,
                            height: 1.1,
                            fontWeight: FontWeight.bold,
                            color: onDark,
                            fontFeatures: _tabularFigures,
                          ),
                        ),
                        Text(
                          ' spm',
                          style: TextStyle(fontSize: 18, color: onDarkSub),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: dimens.space2),
          Divider(height: 1, color: onDark.withValues(alpha: 0.2)),
          SizedBox(height: dimens.space2),
          // ---- 第2階層(補助) + 第3階層(状態) ----
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InlineMetric(
                      icon: Icons.straighten,
                      value: _formatDistance(distanceMeters),
                    ),
                    SizedBox(height: dimens.space1),
                    _InlineMetric(
                      icon: Icons.timer_outlined,
                      value: _formatTime(elapsedTimeSeconds),
                    ),
                  ],
                ),
              ),
              SizedBox(width: dimens.space2),
              // GPSが途絶えたら明示する(気づかないまま航行するのが最も危険)。
              // 正常時は最小の淡色アイコンのみ。
              if (statusLabel != null)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: dimens.space2,
                    vertical: dimens.space1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.danger,
                    borderRadius: dimens.borderSm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        gpsStale ? Icons.gps_off : Icons.cloud_off,
                        size: 16,
                        color: onDark,
                      ),
                      SizedBox(width: dimens.space1),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: onDark,
                          fontFeatures: _tabularFigures,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Icon(Icons.gps_fixed,
                    size: 18, color: onDark.withValues(alpha: 0.38)),
            ],
          ),
          // 能力低下バッジ(異常時のみ)
          //
          // 固定2列だと「臨時危険区域: 受信不可」のような長い文言が幅に
          // 収まらず省略され、どの能力が落ちたのか読めなくなる。自然折返しに
          // して、文言が切れるより行が増えるほうを選ぶ。
          if (degraded) ...[
            SizedBox(height: dimens.space2),
            Wrap(
              spacing: dimens.space2,
              runSpacing: dimens.space1,
              children: capabilityBadges,
            ),
          ],
          SizedBox(height: dimens.space2),
          // 常時表示して、複数艇の危険形状が揃っているかを出艇中にも
          // 照合できるようにする。既定値・端末のみ・古いcacheは注意色だが、
          // 原則1に従い航行自体は止めない。
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 15,
                color:
                    safetySettingsNeedsAttention ? colors.warning : onDarkSub,
              ),
              SizedBox(width: dimens.space1),
              Expanded(
                child: Text(
                  safetySettingsLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: safetySettingsNeedsAttention
                        ? colors.warning
                        : onDarkSub,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (pendingSharedSafetyRevision != null &&
                  onApplyPendingSafetySettings != null)
                TextButton(
                  onPressed: onApplyPendingSafetySettings,
                  style: TextButton.styleFrom(
                    foregroundColor: onDark,
                    minimumSize: const Size(40, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: const Text('反映'),
                ),
            ],
          ),
          SizedBox(height: dimens.space2),
          // 安全注記: 最小ウェイトで常時表示
          Text(
            'アプリで共有中の艇のみ検出します・周囲を目視確認',
            maxLines: 2,
            style: TextStyle(
              color: onDarkSub,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompact({
    required AppColors colors,
    required Color onDark,
    required Color onDarkSub,
    required bool gpsStale,
    required String? statusLabel,
    required bool degraded,
    required String spmValueText,
    required bool portrait,
  }) {
    final statusParts = <String>[
      if (statusLabel != null) statusLabel,
      if (otherBoatReceiveUnavailable) '他艇受信不可',
      if (positionSharingUnavailable) '自艇共有不可',
      if (temporaryObstacleReceiveUnavailable) '危険区域受信不可',
      if (operationalCoverageLimited) '未検証水域',
      safetySettingsLabel,
    ];

    return Container(
      key: ValueKey(
        portrait
            ? 'nav-status-card-portrait-compact'
            : 'nav-status-card-compact',
      ),
      // 縦向きはSPMを使わない場合に幅そのものをさらに縮める。
      // 外側8px余白を含む実表示幅は、それぞれ約230/268px。
      constraints: BoxConstraints(
        maxWidth: portrait
            ? spmMeasurementEnabled
                ? 252
                : 214
            : 244,
      ),
      margin: const EdgeInsets.all(8),
      padding: EdgeInsets.symmetric(
        horizontal: portrait ? 10 : 12,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: colors.mapPanelScrim,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _formatPace(paceSeconds),
                        style: TextStyle(
                          color: onDark,
                          // 縦向きは従来52pxから少しだけ縮め、主計器の
                          // 読みやすさを維持する。横向きだけ30pxにする。
                          // 連続音の警告中はさらに落として警告へ譲る。
                          fontSize: deemphasized
                              ? (portrait ? 28 : 22)
                              : (portrait ? 46 : 30),
                          height: 1,
                          fontWeight: FontWeight.bold,
                          fontFeatures: _tabularFigures,
                        ),
                      ),
                      Text(
                        ' /500m',
                        style: TextStyle(
                          color: onDarkSub,
                          fontSize: portrait ? 13 : 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (spmMeasurementEnabled && !deemphasized) ...[
                const SizedBox(width: 8),
                Text(
                  '$spmValueText spm',
                  key: const ValueKey('compact-spm'),
                  style: TextStyle(
                    color: onDark,
                    fontSize: portrait ? 18 : 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: _tabularFigures,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _CompactMetric(
                  icon: Icons.timer_outlined,
                  value: _formatTime(elapsedTimeSeconds),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CompactMetric(
                  icon: Icons.straighten,
                  value: _formatDistance(distanceMeters),
                ),
              ),
            ],
          ),
          if (gpsStale || degraded || safetySettingsNeedsAttention) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  gpsStale ? Icons.gps_off : Icons.warning_amber_rounded,
                  size: 14,
                  color: gpsStale ? colors.danger : colors.warning,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    statusParts.join('・'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: onDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineMetric extends StatelessWidget {
  final IconData icon;
  final String value;

  const _InlineMetric({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    final onDark = context.colors.onDark;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: onDark.withValues(alpha: 0.7)),
          SizedBox(width: context.dimens.space1),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: onDark,
              fontFeatures: NavStatusCard._tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _CapabilityBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return ConstrainedBox(
      // Wrap は子へ無限幅を渡すため、上限が無いと省略も折返しもできずに
      // カードからはみ出す。1バッジがカード幅を越えないところで頭打ちにする。
      constraints: const BoxConstraints(maxWidth: 260),
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: dimens.space2,
          vertical: dimens.space1,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: dimens.borderSm,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _CompactMetric extends StatelessWidget {
  final IconData icon;
  final String value;

  const _CompactMetric({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    final onDark = context.colors.onDark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: onDark.withValues(alpha: 0.7)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: onDark,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFeatures: NavStatusCard._tabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}
