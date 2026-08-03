import 'package:flutter/material.dart';

import '../models/safety_snapshot.dart';
import '../theme/app_theme.dart';

/// 現地でのトラブルシュート用の読み取り専用画面。
///
/// これまで内部状態は `kReleaseMode` で完全に隠れていたため、「警告が鳴らない」
/// 「他艇が出ない」と現地で言われても、開発ビルドを配り直さないと何も
/// 確かめられなかった。設定は何も変えず、今どうなっているかだけを見せる。
class DeviceStatusScreen extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;
  final DateTime? lastFixAt;
  final int? batteryPercent;
  final bool positionSharingUnavailable;
  final bool otherBoatReceiveUnavailable;
  final bool temporaryObstacleReceiveUnavailable;

  /// 安全判定そのものが今どの状態で動いているか。
  /// 固定危険区域データの欠落や警告処理の停止は、ここへ集約されている。
  final SafetyRunMode safetyRunMode;
  final int otherBoatCount;
  final int obstacleCount;
  final bool navigating;

  /// 現在時刻。テストから固定するために差し替えられる。
  final DateTime Function()? clock;

  const DeviceStatusScreen({
    super.key,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
    this.lastFixAt,
    this.batteryPercent,
    this.positionSharingUnavailable = false,
    this.otherBoatReceiveUnavailable = false,
    this.temporaryObstacleReceiveUnavailable = false,
    this.safetyRunMode = SafetyRunMode.stopped,
    this.otherBoatCount = 0,
    this.obstacleCount = 0,
    this.navigating = false,
    this.clock,
  });

  static String _runModeLabel(SafetyRunMode mode) => switch (mode) {
        SafetyRunMode.stopped => '停止中（待機）',
        SafetyRunMode.runningFull => '通常',
        SafetyRunMode.runningDegraded => '縮退運転',
        SafetyRunMode.unavailable => '利用不可',
      };

  String _formatNumber(double? value, String unit, {int digits = 1}) =>
      value == null || !value.isFinite
          ? '—'
          : '${value.toStringAsFixed(digits)} $unit';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final now = clock?.call() ?? DateTime.now();
    final fixAge = lastFixAt == null
        ? null
        : now.difference(lastFixAt!).inSeconds.clamp(0, 99999);

    return Scaffold(
      appBar: AppBar(title: const Text('端末情報')),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          _Group(
            title: '測位',
            rows: [
              _Row('状態', navigating ? '航行中' : '待機中'),
              _Row('緯度', latitude?.toStringAsFixed(6) ?? '—'),
              _Row('経度', longitude?.toStringAsFixed(6) ?? '—'),
              _Row('推定誤差', _formatNumber(accuracyMeters, 'm')),
              _Row('速度', _formatNumber(speedMetersPerSecond, 'm/s')),
              _Row('進路', _formatNumber(headingDegrees, '°')),
              _Row('最終測位', fixAge == null ? '—' : '$fixAge 秒前'),
              _Row('電池', batteryPercent == null ? '—' : '$batteryPercent %'),
            ],
          ),
          _Group(
            title: '安全機能',
            rows: [
              _Row.status('自艇の位置共有', !positionSharingUnavailable),
              _Row.status('他艇の受信', !otherBoatReceiveUnavailable),
              _Row.status('臨時危険区域の受信', !temporaryObstacleReceiveUnavailable),
              _Row('安全判定', _runModeLabel(safetyRunMode)),
            ],
          ),
          _Group(
            title: '検出対象',
            rows: [
              _Row('受信中の他艇', '$otherBoatCount 隻'),
              _Row('読み込み済みの危険区域', '$obstacleCount 件'),
            ],
          ),
          Container(
            padding: EdgeInsets.all(dimens.space3),
            decoration: BoxDecoration(
              color: colors.cautionSurface,
              borderRadius: dimens.borderMd,
              border: Border.all(color: colors.caution),
            ),
            child: const Text(
              'この画面は現在の状態を表示するだけです。'
              'ここから設定を変更することはできません。',
            ),
          ),
          SizedBox(height: dimens.space5),
        ],
      ),
    );
  }
}

class _Row {
  final String label;
  final String value;
  final bool? ok;

  const _Row(this.label, this.value) : ok = null;

  const _Row.status(this.label, bool healthy)
      : value = healthy ? '正常' : '利用不可',
        ok = healthy;
}

class _Group extends StatelessWidget {
  final String title;
  final List<_Row> rows;

  const _Group({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          SizedBox(height: dimens.space2),
          for (final row in rows)
            Padding(
              padding: EdgeInsets.symmetric(vertical: dimens.space1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row.label,
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  if (row.ok != null) ...[
                    Icon(
                      row.ok! ? Icons.check_circle : Icons.error,
                      size: 16,
                      color: row.ok! ? colors.ok : colors.danger,
                    ),
                    SizedBox(width: dimens.space1),
                  ],
                  Text(
                    row.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color:
                          row.ok == false ? colors.danger : colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
