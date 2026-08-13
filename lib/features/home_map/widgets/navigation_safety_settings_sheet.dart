import 'package:flutter/material.dart';

import '../../../config/risk_evaluator_config.dart';
import '../../../models/danger_zone_settings.dart';
import '../../../models/fixed_obstacle_calibration.dart';
import '../../../models/fixed_obstacle_warning_settings.dart';
import '../../../services/danger_zone_settings_service.dart';
import '../../../services/fixed_obstacle_warning_settings_service.dart';
import '../../../services/preset_obstacle_service.dart';
import '../../../services/risk_evaluator_settings_service.dart';
import '../../../services/shared_safety_calibration_service.dart';

/// 航行を覆い隠さずに、警告に効く設定だけを変更する下半分のシート。
///
/// 艇種・表示名・座席は航行の識別子でもあるためここには置かない。危険区域は
/// 保存前に必ず確認し、生成に失敗した場合はフック側が旧形状を保持する。
class NavigationSafetySettingsSheet extends StatefulWidget {
  final String safetySettingsLabel;
  final bool usesSharedSafetySettings;
  final int? appliedSharedSafetyRevision;
  final int? pendingSharedSafetyRevision;
  final Future<void> Function(
    WarningLeadTimes previous,
    int? sharedRevision,
  ) onApplyWarningLeadTimes;
  final Future<bool> Function({
    required String key,
    required Object? from,
    required Object? to,
    int? sharedRevision,
  }) onApplyObstacles;
  final Future<void> Function() onApplyPendingSharedSafetySettings;

  const NavigationSafetySettingsSheet({
    super.key,
    required this.safetySettingsLabel,
    required this.usesSharedSafetySettings,
    required this.appliedSharedSafetyRevision,
    required this.pendingSharedSafetyRevision,
    required this.onApplyWarningLeadTimes,
    required this.onApplyObstacles,
    required this.onApplyPendingSharedSafetySettings,
  });

  @override
  State<NavigationSafetySettingsSheet> createState() =>
      _NavigationSafetySettingsSheetState();
}

class _NavigationSafetySettingsSheetState
    extends State<NavigationSafetySettingsSheet> {
  final _riskSettings = RiskEvaluatorSettingsService();
  final _zoneSettings = DangerZoneSettingsService();
  final _fixedWarningSettings = FixedObstacleWarningSettingsService();
  final _presetObstacles = PresetObstacleService();
  final _sharedSafety = SharedSafetyCalibrationService();

  WarningLeadTimes? _leadTimes;
  DangerZoneSettings? _zones;
  FixedObstacleWarningSettings? _fixedWarnings;
  List<FixedObstacleCalibrationTarget>? _targets;
  int? _sharedRevision;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sharedRevision = widget.appliedSharedSafetyRevision;
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        _riskSettings.loadWarningLeadTimes(),
        _zoneSettings.load(),
        _fixedWarningSettings.load(),
        _presetObstacles.loadCalibrationTargets(),
      ]);
      var zones = results[1] as DangerZoneSettings;
      var warnings = results[2] as FixedObstacleWarningSettings;
      if (widget.usesSharedSafetySettings) {
        // 航行中に実際に使っている共有cacheを編集の出発点にする。端末内の
        // 下書きを見せると、確認ダイアログと実際に差し替える形状がずれる。
        final shared = await _sharedSafety.loadCached();
        if (shared != null) {
          _leadTimes = WarningLeadTimes(
            primaryWarningLeadSeconds: shared.primaryWarningLeadSeconds,
            advanceWarningLeadSeconds: shared.advanceWarningLeadSeconds,
          );
          zones = shared.dangerZoneSettings;
          warnings = FixedObstacleWarningSettings(
            disabledSourceIds: shared.disabledWarningSourceIds,
          );
          _sharedRevision = shared.revision;
        }
      }
      if (!mounted) return;
      setState(() {
        _leadTimes ??= results[0] as WarningLeadTimes;
        _zones = zones;
        _fixedWarnings = warnings;
        _targets = results[3] as List<FixedObstacleCalibrationTarget>;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String applyLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(applyLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Map<String, Map<String, double>> _zoneSnapshot(DangerZoneSettings value) => {
        for (final kind in DangerZoneKind.values)
          kind.name: {
            'waterSideMeters': value[kind].waterSideMeters,
            'landSideMeters': value[kind].landSideMeters,
          },
      };

  Future<int?> _saveSharedZones(DangerZoneSettings zones) async {
    if (!widget.usesSharedSafetySettings) return null;
    final saved = await _sharedSafety.publishDangerZones(
      dangerZoneSettings: zones,
      expectedRevision: _sharedRevision ?? 0,
    );
    _sharedRevision = saved.revision;
    return saved.revision;
  }

  Future<int?> _saveSharedWarnings(
      FixedObstacleWarningSettings warnings) async {
    if (!widget.usesSharedSafetySettings) return null;
    final saved = await _sharedSafety.publishWarningSettings(
      warningSettings: warnings,
      expectedRevision: _sharedRevision ?? 0,
    );
    _sharedRevision = saved.revision;
    return saved.revision;
  }

  Future<int?> _saveSharedLeadTimes(WarningLeadTimes leadTimes) async {
    if (!widget.usesSharedSafetySettings) return null;
    final saved = await _sharedSafety.publishWarningLeadTimes(
      warningLeadTimes: leadTimes,
      expectedRevision: _sharedRevision ?? 0,
    );
    _sharedRevision = saved.revision;
    return saved.revision;
  }

  void _showResult(bool applied) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(applied
          ? '設定を反映しました。警告は次の評価から新しい設定で継続します。'
          : '形状を作り直せなかったため、航行中の設定は変更せず従来の警告を続けています。'),
    ));
  }

  Future<void> _saveLeadTimes() async {
    final next = _leadTimes;
    if (_busy || next == null) return;
    final previous = await _riskSettings.loadWarningLeadTimes();
    setState(() => _busy = true);
    try {
      await _riskSettings.saveWarningLeadTimes(next);
      final revision = await _saveSharedLeadTimes(next);
      await widget.onApplyWarningLeadTimes(previous, revision);
      _showResult(true);
    } catch (error) {
      if (mounted) setState(() => _error = '警告時間を保存できませんでした: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveZones() async {
    final next = _zones;
    if (_busy || next == null) return;
    final confirmed = await _confirm(
      title: '危険区域の幅を反映しますか？',
      message: widget.usesSharedSafetySettings
          ? 'この変更はチームの共有安全設定にも公開されます。新しい全区域を生成できた場合だけ、一括で切り替えます。'
          : '新しい全区域を生成できた場合だけ、一括で切り替えます。生成に失敗した場合は、現在の警告区域を保ちます。',
      applyLabel: '生成して反映',
    );
    if (!confirmed || !mounted) return;
    final previous = await _zoneSettings.load();
    setState(() => _busy = true);
    try {
      await _zoneSettings.save(next);
      final revision = await _saveSharedZones(next);
      final applied = await widget.onApplyObstacles(
        key: 'dangerZoneOffsets',
        from: _zoneSnapshot(previous),
        to: _zoneSnapshot(next),
        sharedRevision: revision,
      );
      _showResult(applied);
    } catch (error) {
      if (mounted) setState(() => _error = '危険区域を反映できませんでした: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveFixedWarnings() async {
    final next = _fixedWarnings;
    if (_busy || next == null) return;
    final confirmed = await _confirm(
      title: '固定対象物の警告設定を反映しますか？',
      message: widget.usesSharedSafetySettings
          ? 'この変更はチームの共有安全設定にも公開されます。対象物は地図に残し、警告対象だけを新しい一式へ切り替えます。'
          : '対象物は地図に残し、警告対象だけを新しい一式へ切り替えます。',
      applyLabel: '反映',
    );
    if (!confirmed || !mounted) return;
    final previous = await _fixedWarningSettings.load();
    setState(() => _busy = true);
    try {
      await _fixedWarningSettings.save(next);
      final revision = await _saveSharedWarnings(next);
      final applied = await widget.onApplyObstacles(
        key: 'fixedObstacleWarningSettings',
        from: previous.disabledSourceIds.toList()..sort(),
        to: next.disabledSourceIds.toList()..sort(),
        sharedRevision: revision,
      );
      _showResult(applied);
    } catch (error) {
      if (mounted) setState(() => _error = '固定対象物の警告設定を反映できませんでした: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPendingSharedRevision() async {
    final revision = widget.pendingSharedSafetyRevision;
    if (_busy || revision == null) return;
    final confirmed = await _confirm(
      title: '共有安全設定 rev.$revision を反映しますか？',
      message: '新しい全区域を生成できた場合だけ、一括で切り替えます。生成に失敗した場合は、現在の警告区域を保ちます。',
      applyLabel: '反映',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onApplyPendingSharedSafetySettings();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _kindLabel(DangerZoneKind kind) => switch (kind) {
        DangerZoneKind.shore => '岸',
        DangerZoneKind.bridge => '橋',
        DangerZoneKind.island => '中州',
        DangerZoneKind.driftwood => '固定流木',
        DangerZoneKind.testZone => 'テスト区域',
      };

  void _setZone(DangerZoneKind kind, double water, double land) {
    setState(() {
      _zones = _zones!.withOffsets(
        kind,
        DangerZoneOffsets(waterSideMeters: water, landSideMeters: land),
      );
    });
  }

  Widget _offsetSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ${value.toStringAsFixed(1)} m'),
          Slider(
            value: value,
            min: minDangerZoneOffsetMeters,
            max: maxDangerZoneOffsetMeters,
            divisions: 60,
            label: '${value.toStringAsFixed(1)} m',
            onChanged: _busy ? null : onChanged,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final leadTimes = _leadTimes;
    final zones = _zones;
    final warnings = _fixedWarnings;
    final targets = _targets;
    final orderedTargets = targets == null
        ? const <FixedObstacleCalibrationTarget>[]
        : [
            ...targets.where((target) =>
                !FixedObstacleWarningSettings.isSettingsLastSourceId(
                    target.sourceId)),
            ...targets.where((target) =>
                FixedObstacleWarningSettings.isSettingsLastSourceId(
                    target.sourceId)),
          ];
    final primaryMax = leadTimes == null
        ? primaryWarningLeadSeconds + primaryWarningLeadStepSeconds
        : leadTimes.advanceWarningLeadSeconds - primaryWarningLeadStepSeconds;
    final advanceMin = leadTimes == null
        ? minWarningTimeSeconds
        : (leadTimes.primaryWarningLeadSeconds + primaryWarningLeadStepSeconds)
            .clamp(minWarningTimeSeconds, maxWarningTimeSeconds)
            .toDouble();

    return Material(
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('航行中の安全設定'),
              subtitle: Text(widget.safetySettingsLabel),
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            Expanded(
              child: leadTimes == null ||
                      zones == null ||
                      warnings == null ||
                      targets == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      children: [
                        if (widget.pendingSharedSafetyRevision != null)
                          Card(
                            child: ListTile(
                              leading: const Icon(Icons.update),
                              title: Text(
                                  '共有安全設定 rev.${widget.pendingSharedSafetyRevision}'),
                              subtitle: const Text('足元の区域を黙って変えず、確認後に一括反映します。'),
                              trailing: FilledButton(
                                onPressed:
                                    _busy ? null : _applyPendingSharedRevision,
                                child: const Text('反映'),
                              ),
                            ),
                          ),
                        ExpansionTile(
                          initiallyExpanded: true,
                          leading: const Icon(Icons.timer_outlined),
                          title: const Text('本警告・予告の秒数'),
                          childrenPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            Text(
                              '本警告（連続音）の開始: '
                              '${leadTimes.primaryWarningLeadSeconds.toStringAsFixed(1)}秒前',
                            ),
                            Slider(
                              value: leadTimes.primaryWarningLeadSeconds,
                              min: minPrimaryWarningLeadSeconds,
                              max: primaryMax,
                              divisions:
                                  ((primaryMax - minPrimaryWarningLeadSeconds) /
                                          primaryWarningLeadStepSeconds)
                                      .round(),
                              label:
                                  '${leadTimes.primaryWarningLeadSeconds.toStringAsFixed(1)}秒前',
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                        () => _leadTimes = WarningLeadTimes(
                                          primaryWarningLeadSeconds: value,
                                          advanceWarningLeadSeconds: leadTimes
                                              .advanceWarningLeadSeconds,
                                        ),
                                      ),
                            ),
                            Slider(
                              value: leadTimes.advanceWarningLeadSeconds,
                              min: advanceMin,
                              max: maxWarningTimeSeconds,
                              divisions: ((maxWarningTimeSeconds - advanceMin) /
                                      warningTimeStepSeconds)
                                  .round(),
                              label:
                                  '${leadTimes.advanceWarningLeadSeconds.toStringAsFixed(0)}秒前',
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                      () => _leadTimes = WarningLeadTimes(
                                            primaryWarningLeadSeconds: leadTimes
                                                .primaryWarningLeadSeconds,
                                            advanceWarningLeadSeconds: value,
                                          )),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: _busy ? null : _saveLeadTimes,
                                child: const Text('保存して反映'),
                              ),
                            ),
                          ],
                        ),
                        ExpansionTile(
                          leading: const Icon(Icons.straighten_outlined),
                          title: const Text('危険区域の幅'),
                          subtitle: const Text('確認後に全区域を生成して一括で差し替えます。'),
                          childrenPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            for (final kind in DangerZoneKind.values)
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(_kindLabel(kind),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      _offsetSlider(
                                        label: kind == DangerZoneKind.shore
                                            ? '水上側'
                                            : '片側A',
                                        value: zones[kind].waterSideMeters,
                                        onChanged: (value) => _setZone(kind,
                                            value, zones[kind].landSideMeters),
                                      ),
                                      _offsetSlider(
                                        label: kind == DangerZoneKind.shore
                                            ? '陸側'
                                            : '片側B',
                                        value: zones[kind].landSideMeters,
                                        onChanged: (value) => _setZone(kind,
                                            zones[kind].waterSideMeters, value),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: _busy ? null : _saveZones,
                                child: const Text('確認して反映'),
                              ),
                            ),
                          ],
                        ),
                        ExpansionTile(
                          leading: const Icon(Icons.notifications_off_outlined),
                          title: const Text('固定対象物の警告'),
                          subtitle: const Text('オフにしても地図表示は残ります。'),
                          childrenPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            for (final target in orderedTargets)
                              SwitchListTile.adaptive(
                                title: Text(target.name),
                                subtitle: Text(
                                  FixedObstacleWarningSettings
                                          .isSettingsLastSourceId(
                                              target.sourceId)
                                      ? '${target.kind.displayLabel}・現在は未使用（初期オフ）'
                                      : target.kind.displayLabel,
                                ),
                                value: warnings.isEnabled(target.sourceId),
                                onChanged: _busy
                                    ? null
                                    : (enabled) => setState(() =>
                                        _fixedWarnings = warnings.withEnabled(
                                            target.sourceId, enabled)),
                              ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                onPressed: _busy ? null : _saveFixedWarnings,
                                child: const Text('確認して反映'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
