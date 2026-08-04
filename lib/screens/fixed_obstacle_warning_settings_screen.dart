import 'package:flutter/material.dart';

import '../models/fixed_obstacle_warning_settings.dart';
import '../models/fixed_obstacle_calibration.dart';
import '../services/fixed_obstacle_warning_settings_service.dart';
import '../services/preset_obstacle_service.dart';
import '../services/shared_safety_calibration_service.dart';
import '../services/team_service.dart';
import '../widgets/app_state_views.dart';
import '../widgets/fixed_obstacle_calibration_controls.dart';

/// 固定対象物を衝突判定・警告の対象にするかを設定・共有する画面。
class FixedObstacleWarningSettingsScreen extends StatefulWidget {
  const FixedObstacleWarningSettingsScreen({super.key});

  @override
  State<FixedObstacleWarningSettingsScreen> createState() =>
      _FixedObstacleWarningSettingsScreenState();
}

class _FixedObstacleWarningSettingsScreenState
    extends State<FixedObstacleWarningSettingsScreen> {
  final _settingsService = FixedObstacleWarningSettingsService();
  final _presetService = PresetObstacleService();
  final _sharedSafetyService = SharedSafetyCalibrationService();
  FixedObstacleWarningSettings? _settings;
  List<FixedObstacleCalibrationTarget>? _targets;
  bool _saving = false;
  bool _publishing = false;
  int _sharedRevision = 0;
  FixedObstacleCalibrationPublishStatus _publishStatus =
      FixedObstacleCalibrationPublishStatus.idle;
  String? _publishMessage;
  String? _loadError;

  bool get _busy => _saving || _publishing;
  bool get _hasTeamMembership => TeamService.activeMembership != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        _settingsService.load(),
        _presetService.loadCalibrationTargets(),
      ]);
      if (!mounted) return;
      setState(() {
        _settings = results[0] as FixedObstacleWarningSettings;
        _targets = results[1] as List<FixedObstacleCalibrationTarget>;
      });
      try {
        final shared = _hasTeamMembership
            ? await _sharedSafetyService.fetchLatest()
            : await _sharedSafetyService.loadCached();
        if (!mounted) return;
        setState(() {
          _sharedRevision = shared?.revision ?? 0;
          if (shared != null) {
            _settings = FixedObstacleWarningSettings(
              disabledSourceIds: shared.disabledWarningSourceIds,
            );
          }
        });
      } catch (_) {
        if (!mounted || !_hasTeamMembership) return;
        setState(() {
          _publishStatus = FixedObstacleCalibrationPublishStatus.failure;
          _publishMessage = '共有版の更新状況を取得できませんでした。'
              '端末内の下書きは続けられます。';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = '$error');
    }
  }

  Future<void> _save() async {
    final settings = _settings;
    if (settings == null || _busy) return;
    setState(() => _saving = true);
    try {
      await _settingsService.save(settings);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('警告対象の保存に失敗しました: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publishToTeam() async {
    final settings = _settings;
    final targets = _targets;
    if (settings == null || targets == null || !_hasTeamMembership || _busy) {
      return;
    }
    final disabledTargets = [
      for (final target in targets)
        if (!settings.isEnabled(target.sourceId))
          '${target.kind.displayLabel}｜${target.name}',
    ];
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('チームへの公開内容を確認'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SingleChildScrollView(
                child: Text(
                  disabledTargets.isEmpty
                      ? 'すべての固定対象物を警告対象にします。'
                      : '次の固定対象物を警告対象から外します。\n\n'
                          '${disabledTargets.map((name) => '・$name').join('\n')}',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('チームに公開'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() {
      _publishing = true;
      _publishStatus = FixedObstacleCalibrationPublishStatus.publishing;
      _publishMessage = null;
    });
    try {
      // 公開前に端末内にも保存し、通信失敗時も下書きを失わないようにする。
      await _settingsService.save(settings);
      final saved = await _sharedSafetyService.publishWarningSettings(
        warningSettings: settings,
        expectedRevision: _sharedRevision,
      );
      if (!mounted) return;
      setState(() {
        _sharedRevision = saved.revision;
        _publishStatus = FixedObstacleCalibrationPublishStatus.success;
        _publishMessage = '固定対象物の警告設定をチームへ公開しました'
            '（版 ${saved.revision}）。';
      });
    } on SharedSafetyCalibrationConflictException {
      if (!mounted) return;
      var message = '他の端末が先に更新しました。最新版を取得して、'
          '内容を確認してから再公開してください。';
      try {
        final latest =
            await _sharedSafetyService.fetchLatest(forceServer: true);
        if (!mounted) return;
        _sharedRevision = latest?.revision ?? 0;
        message = '他の端末が先に更新しました。最新版（版 $_sharedRevision）を'
            '取得したため、内容を確認して再公開してください。';
      } catch (_) {
        // 競合状態を優先表示し、端末内へ保存した下書きは維持する。
      }
      if (mounted) {
        setState(() {
          _publishStatus = FixedObstacleCalibrationPublishStatus.conflict;
          _publishMessage = message;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _publishStatus = FixedObstacleCalibrationPublishStatus.failure;
        _publishMessage = '公開できませんでした: $error';
      });
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _updateSettings(FixedObstacleWarningSettings settings) {
    setState(() {
      _settings = settings;
      _publishStatus = FixedObstacleCalibrationPublishStatus.idle;
      _publishMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
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
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('固定対象物の警告')),
        body: AppErrorView(
          title: '警告対象を読み込めませんでした',
          message: _loadError!,
          primaryLabel: '再試行',
          onPrimary: () {
            setState(() => _loadError = null);
            _load();
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('固定対象物の警告'),
        actions: [
          TextButton(
            onPressed: settings == null || _busy ? null : _save,
            child: Text(
              _busy ? '保存中…' : '保存',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: settings == null || targets == null
          ? const AppLoadingView(message: '固定対象物を読み込んでいます…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'オフにした対象物は、通常は地図に表示したまま衝突判定・画面警告・音声警告から外れます。ただし現在未使用の逆走注意エリアと島2（上流）は、オフの間は航行地図からも非表示になります。「保存」はこの端末だけに保存します。「チームに公開」を押すと、同じチームの端末にも反映されます。座標調整や危険範囲は変更しません。',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '固定対象物ごとの警告',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                const Text('オン: 警告対象　オフ: 警告しない'),
                const SizedBox(height: 8),
                for (final target in orderedTargets)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: SwitchListTile.adaptive(
                      title: Text(target.name),
                      subtitle: Text(
                        FixedObstacleWarningSettings.isSettingsLastSourceId(
                                target.sourceId)
                            ? '${target.kind.displayLabel}・現在は未使用（初期オフ）'
                            : target.kind.displayLabel,
                      ),
                      value: settings.isEnabled(target.sourceId),
                      onChanged: _busy
                          ? null
                          : (enabled) => _updateSettings(
                                settings.withEnabled(target.sourceId, enabled),
                              ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _updateSettings(FixedObstacleWarningSettings()),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('初期設定に戻す（逆走注意エリア・島2（上流）をオフ）'),
                ),
                const SizedBox(height: 24),
                FixedObstacleCalibrationPublishPanel(
                  status: _publishStatus,
                  statusMessage: _hasTeamMembership
                      ? _publishMessage
                      : '共有確定版: 版 $_sharedRevision。'
                          '表示中の設定は端末内の下書きです。'
                          'チームに参加すると公開できます。',
                  enabled: !_busy,
                  showPublishButton: _hasTeamMembership,
                  onPublish: _publishToTeam,
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
