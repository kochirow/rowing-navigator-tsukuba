import 'dart:async';

import 'package:flutter/material.dart';

import '../config/risk_evaluator_config.dart';
import '../models/danger_zone_settings.dart';
import '../services/danger_zone_settings_service.dart';
import '../services/map_display_settings_service.dart';
import '../services/risk_evaluator_settings_service.dart';
import '../services/shared_safety_calibration_service.dart';
import '../services/team_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_state_views.dart';
import '../widgets/fixed_obstacle_calibration_controls.dart';
import 'fixed_obstacle_warning_settings_screen.dart';

class DangerZoneSettingsScreen extends StatefulWidget {
  const DangerZoneSettingsScreen({super.key});

  @override
  State<DangerZoneSettingsScreen> createState() =>
      _DangerZoneSettingsScreenState();
}

class _DangerZoneSettingsScreenState extends State<DangerZoneSettingsScreen> {
  final _service = DangerZoneSettingsService();
  final _riskEvaluatorService = RiskEvaluatorSettingsService();
  final _sharedCalibrationService = SharedSafetyCalibrationService();
  final _mapDisplaySettings = MapDisplaySettingsService();
  DangerZoneSettings? _settings;
  WarningLeadTimes? _warningLeadTimes;
  bool _saving = false;
  bool _publishing = false;
  int _sharedRevision = 0;
  FixedObstacleCalibrationPublishStatus _publishStatus =
      FixedObstacleCalibrationPublishStatus.idle;
  String? _publishMessage;
  bool _showDeveloperSafetyShapeOverlay = false;

  bool get _busy => _saving || _publishing;
  bool get _hasTeamMembership => TeamService.activeMembership != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _service.load();
    final warningLeadTimes = await _riskEvaluatorService.loadWarningLeadTimes();
    final showDeveloperSafetyShapeOverlay =
        await _mapDisplaySettings.loadDeveloperSafetyShapeOverlay();
    if (mounted) {
      setState(() {
        _settings = settings;
        _warningLeadTimes = warningLeadTimes;
        _showDeveloperSafetyShapeOverlay = showDeveloperSafetyShapeOverlay;
      });
    }
    try {
      final shared = _hasTeamMembership
          ? await _sharedCalibrationService.fetchLatest()
          : await _sharedCalibrationService.loadCached();
      if (!mounted) return;
      setState(() {
        _sharedRevision = shared?.revision ?? 0;
        if (shared != null) {
          _settings = shared.dangerZoneSettings;
          _warningLeadTimes = WarningLeadTimes(
            primaryWarningLeadSeconds: shared.primaryWarningLeadSeconds,
            advanceWarningLeadSeconds: shared.advanceWarningLeadSeconds,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      if (_hasTeamMembership) {
        setState(() {
          _publishStatus = FixedObstacleCalibrationPublishStatus.failure;
          _publishMessage = '共有版の更新状況を取得できませんでした。'
              '端末内の設定は続けられます。';
        });
      }
    }
  }

  void _setDeveloperSafetyShapeOverlay(bool enabled) {
    setState(() => _showDeveloperSafetyShapeOverlay = enabled);
    unawaited(_mapDisplaySettings.saveDeveloperSafetyShapeOverlay(enabled));
  }

  Future<void> _save() async {
    final settings = _settings;
    final warningLeadTimes = _warningLeadTimes;
    if (settings == null || warningLeadTimes == null || _busy) return;
    setState(() => _saving = true);
    try {
      await _service.save(settings);
      await _riskEvaluatorService.saveWarningLeadTimes(warningLeadTimes);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _update(
    DangerZoneKind kind, {
    double? waterSideMeters,
    double? landSideMeters,
  }) {
    final settings = _settings!;
    final current = settings[kind];
    setState(() {
      _settings = settings.withOffsets(
        kind,
        current.copyWith(
          waterSideMeters: waterSideMeters,
          landSideMeters: landSideMeters,
        ),
      );
      _publishStatus = FixedObstacleCalibrationPublishStatus.idle;
      _publishMessage = null;
    });
  }

  Future<void> _publishDangerZones() async {
    final settings = _settings;
    final warningLeadTimes = _warningLeadTimes;
    if (!_hasTeamMembership ||
        settings == null ||
        warningLeadTimes == null ||
        _busy) {
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => DangerZoneSettingsPublishConfirmation(
            settings: settings,
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
      // 公開対象は危険範囲だけだが、画面上の下書きは端末へも確実に保存する。
      await _service.save(settings);
      await _riskEvaluatorService.saveWarningLeadTimes(warningLeadTimes);
      final saved = await _sharedCalibrationService.publishDangerZones(
        dangerZoneSettings: settings,
        warningLeadTimes: warningLeadTimes,
        expectedRevision: _sharedRevision,
      );
      if (!mounted) return;
      setState(() {
        _sharedRevision = saved.revision;
        _publishStatus = FixedObstacleCalibrationPublishStatus.success;
        _publishMessage = '危険範囲と警告開始時間をチームへ公開しました'
            '（版 ${saved.revision}）。';
      });
    } on SharedSafetyCalibrationConflictException {
      if (!mounted) return;
      var message = '他の端末が先に更新しました。最新版を取得して、'
          '内容を確認してから再公開してください。';
      try {
        final latest = await _sharedCalibrationService.fetchLatest(
          forceServer: true,
        );
        if (!mounted) return;
        _sharedRevision = latest?.revision ?? 0;
        message = '他の端末が先に更新しました。最新版（版 $_sharedRevision）を'
            '取得したため、内容を確認して再公開してください。';
      } catch (_) {
        // 競合状態を優先し、端末内へ保存済みの下書きは維持する。
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

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final warningLeadTimes = _warningLeadTimes;
    final primarySliderMax = warningLeadTimes == null
        ? primaryWarningLeadSeconds + primaryWarningLeadStepSeconds
        : warningLeadTimes.advanceWarningLeadSeconds -
            primaryWarningLeadStepSeconds;
    final advanceSliderMin = warningLeadTimes == null
        ? minWarningTimeSeconds
        : (warningLeadTimes.primaryWarningLeadSeconds +
                primaryWarningLeadStepSeconds)
            .clamp(minWarningTimeSeconds, maxWarningTimeSeconds)
            .toDouble();
    return Scaffold(
      appBar: AppBar(
        title: const Text('警告の設定'),
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
      body: settings == null || warningLeadTimes == null
          ? const AppLoadingView(message: '警告の設定を読み込んでいます…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 設定を「時間」と「距離」と「対象」の3つの問いへ分ける。
                // どれも警告の設定だが、答えている問いが違う。
                const _SectionHeader(
                  '警告のタイミングの調整',
                  '到達までの残り時間で、音が上がる段階を決めます。',
                ),
                Card(
                  margin: const EdgeInsets.only(top: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本警告（連続音）: ${warningLeadTimes.primaryWarningLeadSeconds.toStringAsFixed(1)}秒前',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '8+の停止時間約8.15秒より前に連続音へ上げる時間です。予告より短く保ちます。',
                        ),
                        Slider(
                          value: warningLeadTimes.primaryWarningLeadSeconds,
                          min: minPrimaryWarningLeadSeconds,
                          max: primarySliderMax,
                          divisions:
                              ((warningLeadTimes.advanceWarningLeadSeconds -
                                          primaryWarningLeadStepSeconds -
                                          minPrimaryWarningLeadSeconds) /
                                      primaryWarningLeadStepSeconds)
                                  .round(),
                          label:
                              '${warningLeadTimes.primaryWarningLeadSeconds.toStringAsFixed(1)}秒前',
                          onChanged: _busy
                              ? null
                              : (value) => setState(
                                    () => _warningLeadTimes = WarningLeadTimes(
                                      primaryWarningLeadSeconds: value,
                                      advanceWarningLeadSeconds:
                                          warningLeadTimes
                                              .advanceWarningLeadSeconds,
                                    ),
                                  ),
                        ),
                        Text(
                          '${minPrimaryWarningLeadSeconds.toStringAsFixed(1)}秒以上・${primaryWarningLeadStepSeconds.toStringAsFixed(1)}秒刻み',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '予告（断続音・予測地平）: ${warningLeadTimes.advanceWarningLeadSeconds.toStringAsFixed(0)}秒前',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'この時間までを予測し、連続音の前に断続音で知らせます。予測が届かない先では音を鳴らしません。',
                        ),
                        Slider(
                          value: warningLeadTimes.advanceWarningLeadSeconds,
                          min: advanceSliderMin,
                          max: maxWarningTimeSeconds,
                          divisions:
                              ((maxWarningTimeSeconds - advanceSliderMin) /
                                      warningTimeStepSeconds)
                                  .round(),
                          label:
                              '${warningLeadTimes.advanceWarningLeadSeconds.toStringAsFixed(0)}秒前',
                          onChanged: _busy
                              ? null
                              : (value) => setState(
                                    () => _warningLeadTimes = WarningLeadTimes(
                                      primaryWarningLeadSeconds:
                                          warningLeadTimes
                                              .primaryWarningLeadSeconds,
                                      advanceWarningLeadSeconds: value,
                                    ),
                                  ),
                        ),
                        Text(
                          '${minWarningTimeSeconds.toStringAsFixed(0)}〜${maxWarningTimeSeconds.toStringAsFixed(0)}秒前・${warningTimeStepSeconds.toStringAsFixed(0)}秒刻み',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(
                            () => _warningLeadTimes = const WarningLeadTimes(
                              primaryWarningLeadSeconds:
                                  primaryWarningLeadSeconds,
                              advanceWarningLeadSeconds:
                                  advanceWarningLeadSeconds,
                            ),
                          ),
                  icon: const Icon(Icons.restore),
                  label: const Text('警告時間をデフォルトに戻す（本警告10秒前・予告13秒前）'),
                ),
                const SizedBox(height: 24),
                const _SectionHeader(
                  '障害物の当たり判定の調整',
                  '基準線から片側へ広げる実距離です。既定は岸が水上側5m・陸側15m、'
                      '橋は内外5m、その他は片側5m。カーブ・逆走区域は別管理です。',
                ),
                const SizedBox(height: 4),
                _zoneCard(
                  kind: DangerZoneKind.shore,
                  title: '岸',
                  description: '岸から数mを走る正常運用を妨げないため水上側は5m、陸地側の欠損を覆うため陸側は15mです。',
                  waterLabel: '水上側',
                  landLabel: '陸側',
                ),
                _zoneCard(
                  kind: DangerZoneKind.bridge,
                  title: '橋',
                  description: '毎回通過する橋で警告を形骸化させないため、内側・外側とも既定5mです。',
                  waterLabel: '内側',
                  landLabel: '外側',
                ),
                _zoneCard(
                  kind: DangerZoneKind.island,
                  title: '中州',
                  description: '中州1・中州2へ同じ設定を適用します。',
                  waterLabel: '内側',
                  landLabel: '外側',
                ),
                _zoneCard(
                  kind: DangerZoneKind.driftwood,
                  title: '固定流木',
                  description: '固定流木の外周から全方向へ広げる危険範囲を調整します。',
                  waterLabel: '周囲',
                  landLabel: '周囲',
                  symmetric: true,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _settings = DangerZoneSettings.defaults();
                            _publishStatus =
                                FixedObstacleCalibrationPublishStatus.idle;
                            _publishMessage = null;
                          }),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('デフォルト値に戻す（岸5m/15m・橋は両側5m）'),
                ),
                const SizedBox(height: 24),
                FixedObstacleCalibrationPublishPanel(
                  status: _publishStatus,
                  statusMessage: _hasTeamMembership
                      ? _publishMessage
                      : '共有確定版: 版 $_sharedRevision。'
                          '表示中の危険範囲は端末内の下書きです。'
                          'チームに参加すると公開できます。',
                  enabled: !_busy,
                  showPublishButton: _hasTeamMembership,
                  onPublish: _publishDangerZones,
                ),
                const SizedBox(height: 24),
                const _SectionHeader(
                  '警告対象となる障害物の選択',
                  '対象物ごとに警告を止められます。距離を0にして止めないこと。',
                ),
                Card(
                  margin: const EdgeInsets.only(top: 12),
                  child: ListTile(
                    leading: const Icon(Icons.notifications_off_outlined),
                    title: const Text('警告対象となる障害物の選択'),
                    subtitle: const Text('橋・岸・中州・流木ごとに警告のオン・オフ'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final changed = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const FixedObstacleWarningSettingsScreen(),
                        ),
                      );
                      if (changed != true || !context.mounted) return;
                      Navigator.pop(context, true);
                    },
                  ),
                ),
                // 「既設危険区域を位置合わせ」「プライバシーとデータ」
                // 「オープンソースライセンス」はここから外した。
                // 位置合わせは同じ画面への経路が2本あり、どちらが正なのか
                // 判断できなかった(準備タブ/監視中メニューの1本に集約)。
                // プライバシーとライセンスは警告の設定ではないので
                // 「端末とデータ」へ移した。
                const SizedBox(height: 12),
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.architecture_outlined),
                    title: const Text('判定形状を地図に表示（開発者用）'),
                    subtitle: const Text(
                      '艇の実体・静的掃引枠・予測掃引帯を重ねます。表示だけを変え、警告判定は変えません。',
                    ),
                    value: _showDeveloperSafetyShapeOverlay,
                    onChanged: _busy ? null : _setDeveloperSafetyShapeOverlay,
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _zoneCard({
    required DangerZoneKind kind,
    required String title,
    required String description,
    required String waterLabel,
    required String landLabel,
    bool symmetric = false,
  }) {
    final offsets = _settings![kind];
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(description, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (symmetric)
              _rangeSlider(
                label: waterLabel,
                value: offsets.waterSideMeters >= offsets.landSideMeters
                    ? offsets.waterSideMeters
                    : offsets.landSideMeters,
                onChanged: (value) => _update(
                  kind,
                  waterSideMeters: value,
                  landSideMeters: value,
                ),
              )
            else ...[
              _rangeSlider(
                label: waterLabel,
                value: offsets.waterSideMeters,
                onChanged: (value) => _update(kind, waterSideMeters: value),
              ),
              _rangeSlider(
                label: landLabel,
                value: offsets.landSideMeters,
                onChanged: (value) => _update(kind, landSideMeters: value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rangeSlider({
    required String label,
    required double value,
    ValueChanged<double>? onChanged,
  }) {
    final safeValue = value
        .clamp(minDangerZoneOffsetMeters, maxDangerZoneOffsetMeters)
        .toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${safeValue.toStringAsFixed(1)} m'),
        Slider(
          value: safeValue,
          min: minDangerZoneOffsetMeters,
          max: maxDangerZoneOffsetMeters,
          divisions: ((maxDangerZoneOffsetMeters - minDangerZoneOffsetMeters) /
                  dangerZoneOffsetStepMeters)
              .round(),
          label: '${safeValue.toStringAsFixed(1)} m',
          onChanged: _busy ? null : onChanged,
        ),
      ],
    );
  }
}

/// 設定の塊の頭に置く見出し。
///
/// この画面には「時間」「距離」「対象」という答えている問いの違う設定が
/// 並ぶ。見出しがないと、上から順に読んでも何を決めているのか分からない。
class _SectionHeader extends StatelessWidget {
  final String title;
  final String description;

  const _SectionHeader(this.title, this.description);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
