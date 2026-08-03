import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/config/display_name_config.dart';
import 'package:rowing_navigator/features/home_map/widgets/rounded_button.dart';

import '../../../providers/nav_config_providers.dart';
import '../../../theme/app_theme.dart';
import '../../../services/navigation_defaults_service.dart';
import '../../../types/boat_type.dart';

/// 航行開始前の設定シート(艇種・シート位置)。
/// 出艇直前の慌ただしい状況で使うため、選択肢は大きなチップで表示し、
/// 安全上の注意を添えてからスタートさせる。
class NavSettingModal extends HookConsumerWidget {
  final Future<void> Function(
    String displayName,
    bool strokeRateEnabled,
    bool strokeMotionDisplayEnabled,
  ) onPressStartNav;
  final Future<void> Function()? onPressTestAudio;

  const NavSettingModal({
    super.key,
    required this.onPressStartNav,
    this.onPressTestAudio,
  });

  Widget _sectionTitle(BuildContext context, String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
        ),
      ],
    );
  }

  Widget _selectChip({
    required BuildContext context,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final primary = Theme.of(context).primaryColor;
    return RawChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      backgroundColor: context.colors.card,
      selectedColor: primary,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected ? primary : context.colors.textDisabled,
          width: selected ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      labelStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: selected ? context.colors.onPrimary : context.colors.textPrimary,
      ),
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boatType = ref.watch(boatTypeProvider);
    final seatPosision = ref.watch(seatPositionProvider);
    final nameController = useTextEditingController();
    final nameError = useState<String?>(null);
    final strokeRateEnabled = useState(true);
    final strokeMotionDisplayEnabled = useState(false);
    final isStarting = useState(false);
    final defaultsService = useMemoized(NavigationDefaultsService.new);
    // 前回設定を復元できたかどうか。復元できたときだけ、スクロールなしで
    // 開始できる近道を先頭に出す。
    final restoredSummary = useState<String?>(null);

    useEffect(() {
      var disposed = false;
      unawaited(
        defaultsService.load().then((defaults) {
          if (disposed || defaults == null || !context.mounted) return;
          final boatConfig = boatConfigs.byBoatType(defaults.boatType);
          final seats = boatConfig.seatPosList;
          var seat = seats.first;
          for (final candidate in seats) {
            if (candidate.position == defaults.seatPosition) {
              seat = candidate;
              break;
            }
          }
          nameController.text = defaults.displayName;
          strokeRateEnabled.value = defaults.strokeRateEnabled;
          strokeMotionDisplayEnabled.value =
              defaults.strokeMotionDisplayEnabled;
          ref.read(boatTypeProvider.notifier).state = defaults.boatType;
          ref.read(seatPositionProvider.notifier).state = seat;
          restoredSummary.value =
              '${defaults.displayName}・${boatConfig.label}・${seat.label}';
        }).catchError((Object error) {
          debugPrint('Failed to restore navigation defaults: $error');
        }),
      );
      return () => disposed = true;
    }, const []);

    setBoatType(BoatType type) {
      ref.read(boatTypeProvider.notifier).state = type;
    }

    setSeatPosition(SeatPosition pos) {
      ref.read(seatPositionProvider.notifier).state = pos;
    }

    Future<void> startNavigation() async {
      if (isStarting.value) return;
      final displayName = normalizeDisplayName(nameController.text);
      final error = displayNameValidationError(displayName);
      if (error != null) {
        nameError.value = error;
        return;
      }
      isStarting.value = true;
      try {
        unawaited(
          defaultsService
              .save(
            displayName: displayName,
            boatType: boatType,
            seatPosition: seatPosision.position,
            strokeRateEnabled: strokeRateEnabled.value,
            strokeMotionDisplayEnabled: strokeMotionDisplayEnabled.value,
          )
              .catchError((Object error) {
            debugPrint('Failed to save navigation defaults: $error');
          }),
        );
        await onPressStartNav(
          displayName,
          strokeRateEnabled.value,
          strokeMotionDisplayEnabled.value,
        );
      } finally {
        if (context.mounted) isStarting.value = false;
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          // シートは画面の8割で頭打ちにしてあるため、キーボードが出ると
          // その分だけ表示領域が狭くなる。同じ高さをスクロール領域の下へ
          // 足して、入力中の欄がキーボードに隠れないようにする。
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // つまみと「閉じる」。
              //
              // シート外の暗い部分をタップしても閉じられるが、それは見えない
              // 操作なので、揺れる艇の上で迷わない出口を明示しておく。
              SizedBox(
                height: 40,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.colors.textDisabled,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: '閉じる',
                        // 開始処理中に閉じると、準備の途中で画面だけ戻る。
                        onPressed: isStarting.value
                            ? null
                            : () => Navigator.of(context).maybePop(),
                        icon: Icon(
                          Icons.close,
                          color: context.colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 出艇直前に毎回7項目をスクロールして確認するのは現実的でない。
              // 前回設定を復元できたときは、まずそのまま開始できる道を出し、
              // 変えたい人だけ下の詳細を触ればよいようにする。
              if (restoredSummary.value != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.colors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Theme.of(context).primaryColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '前回の設定',
                        style: TextStyle(
                          fontSize: 13,
                          color: context.colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        restoredSummary.value!,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: RoundedButton(
                          label: isStarting.value ? '準備中…' : 'この設定で航行スタート',
                          icon: isStarting.value
                              ? Icons.hourglass_top
                              : Icons.rowing,
                          onPressed: startNavigation,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    '変更する場合は、下の項目を編集してください。',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
              _sectionTitle(context, '名前', '監視画面で表示する名前を入力してください'),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                maxLength: maxDisplayNameLength,
                maxLines: 1,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(maxDisplayNameLength),
                ],
                decoration: InputDecoration(
                  labelText: '名前',
                  hintText: '例: 後藤',
                  helperText: '航行中、監視端末と他の艇に共有されます。',
                  errorText: nameError.value,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person),
                ),
                onChanged: (_) {
                  if (nameError.value != null) nameError.value = null;
                },
              ),
              const SizedBox(height: 16),
              _sectionTitle(context, '艇種', '乗る艇の種類を選んでください'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: boatConfigs.allConfigs.map((config) {
                  final type = config.type;
                  return _selectChip(
                    context: context,
                    label: config.label,
                    selected: type == boatType,
                    onPressed: () {
                      setBoatType(type);
                      setSeatPosition(
                          boatConfigs.byBoatType(type).seatPosList.first);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              _sectionTitle(context, '端末の位置', '端末を置くシートを選んでください'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children:
                    boatConfigs.byBoatType(boatType).seatPosList.map((seatPos) {
                  return _selectChip(
                    context: context,
                    label: seatPos.label,
                    selected: seatPos == seatPosision,
                    onPressed: () => setSeatPosition(seatPos),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              _sectionTitle(
                context,
                'SPM・艇速分析',
                '艇にスマホを固定して使用・電池残量が少ない場合はオフ推奨',
              ),
              const SizedBox(height: 8),
              Material(
                color: Colors.transparent,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'SPM・艇速変化を計測する',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  secondary: Icon(
                    strokeRateEnabled.value
                        ? Icons.speed
                        : Icons.battery_saver_outlined,
                  ),
                  value: strokeRateEnabled.value,
                  onChanged: isStarting.value
                      ? null
                      : (value) {
                          strokeRateEnabled.value = value;
                          if (!value) strokeMotionDisplayEnabled.value = false;
                        },
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: strokeRateEnabled.value ? 1 : 0.45,
                child: Material(
                  color: Colors.transparent,
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '1ストロークの艇速分析を表示',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text('計器のすぐ下に表示します'),
                    secondary: const Icon(Icons.insights_outlined),
                    value: strokeRateEnabled.value &&
                        strokeMotionDisplayEnabled.value,
                    onChanged: isStarting.value || !strokeRateEnabled.value
                        ? null
                        : (value) => strokeMotionDisplayEnabled.value = value,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 安全上の注意(アプリの位置づけを毎回リマインドする)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colors.cautionSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.colors.caution),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: context.colors.warning, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本アプリは安全確認の補助です。周囲の目視確認を必ず行ってください。',
                        style: TextStyle(
                          fontSize: 13,
                          color: context.colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (onPressTestAudio != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.volume_up),
                    label: const Text('音声を確認する'),
                    onPressed: onPressTestAudio,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '必要なら、開始前に警告音を実際に確認できます。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Center(
                child: RoundedButton(
                  label: isStarting.value ? '準備中…' : '航行スタート',
                  icon: isStarting.value ? Icons.hourglass_top : Icons.rowing,
                  onPressed: startNavigation,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
