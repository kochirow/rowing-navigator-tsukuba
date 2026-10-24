import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/config/display_name_config.dart';
import 'package:rowing_navigator/features/home_map/widgets/rounded_button.dart';
import 'package:rowing_navigator/features/home_map/widgets/warning_audio_volume_sheet.dart';

import '../../../models/workout_plan.dart';
import '../../../providers/nav_config_providers.dart';
import '../../../screens/workout_setup_screen.dart';
import '../../../theme/app_theme.dart';
import '../../../services/account_display_name_service.dart';
import '../../../services/navigation_defaults_service.dart';
import '../../../types/boat_type.dart';
import '../../../widgets/boat_name_tag.dart';

/// 航行開始前の設定シート(艇種・シート位置)。
/// 出艇直前の慌ただしい状況で使うため、選択肢は大きなチップで表示し、
/// 安全上の注意を添えてからスタートさせる。
class NavSettingModal extends HookConsumerWidget {
  final Future<void> Function(
    String displayName,
    bool strokeRateEnabled,
  ) onPressStartNav;
  final Future<void> Function()? onPressTestAudio;

  /// アプリ内の警告音量。[onWarningAudioVolumeChanged] と一緒に渡したときだけ、
  /// 「音声を確認する」の下に音量の小さな入口を出す。
  final ValueNotifier<double>? warningAudioVolume;
  final Future<void> Function(double volume)? onWarningAudioVolumeChanged;

  /// 開いた時点で決めてある、この航行で使うワークアウト。無ければ null。
  final WorkoutPlan? preparedWorkout;

  /// この航行で使うワークアウトを決めた・やめた(null)とき。
  /// 渡したときだけ、ワークアウトの欄を出す。表示専用の機能なので、
  /// 決めなくても航行は始められる。
  final void Function(WorkoutPlan? plan)? onWorkoutChanged;

  const NavSettingModal({
    super.key,
    required this.onPressStartNav,
    this.onPressTestAudio,
    this.warningAudioVolume,
    this.onWarningAudioVolumeChanged,
    this.preparedWorkout,
    this.onWorkoutChanged,
  });

  /// 見出しは1語だけ。「選んでください」のような副題は付けない
  /// (チップが並んでいれば選ぶものだと分かる)。
  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
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
    // 名前の札のプレビューを、打つたびに更新する。
    useListenable(nameController);
    final nameError = useState<String?>(null);
    // レート(SPM)は常に計測する(2026-10-23 利用者決定。切替は廃止)。
    // 以前「オフ」で保存した端末でも、前回設定から戻さない。
    const strokeRateEnabled = true;
    final isStarting = useState(false);
    final defaultsService = useMemoized(NavigationDefaultsService.new);
    final accountNameService = useMemoized(AccountDisplayNameService.new);
    // 前回設定を復元できたかどうか。復元できたときだけ、スクロールなしで
    // 開始できる近道を先頭に出す。
    final restoredSummary = useState<String?>(null);
    // シートは開いた時点の値で組まれ、呼び出し元の再描画では更新されない。
    // ここで持って、変えたら呼び出し元へ知らせる。
    final workoutPlan = useState<WorkoutPlan?>(preparedWorkout);

    void setWorkout(WorkoutPlan? plan) {
      workoutPlan.value = plan;
      onWorkoutChanged?.call(plan);
    }

    Future<void> openWorkoutSetup() async {
      final plan = await Navigator.of(context).push<WorkoutPlan>(
        MaterialPageRoute(
          builder: (_) => WorkoutSetupScreen(
            initial: workoutPlan.value,
            beforeNavigation: true,
          ),
        ),
      );
      if (plan != null) setWorkout(plan);
    }

    useEffect(() {
      var disposed = false;
      Future<void> restore() async {
        // 名前は毎回アカウントの名前から始める。この航行だけ別の名前に
        // したいときは書き換えればよく、書き換えた名前は次へ持ち越さない。
        String? accountName;
        try {
          accountName = await accountNameService.load();
        } catch (error) {
          debugPrint('Failed to load account display name: $error');
        }
        NavigationDefaults? defaults;
        try {
          defaults = await defaultsService.load();
        } catch (error) {
          debugPrint('Failed to restore navigation defaults: $error');
        }
        if (disposed || !context.mounted) return;
        final name = accountName ?? defaults?.displayName;
        if (name != null) nameController.text = name;
        if (defaults == null) return;
        final boatConfig = boatConfigs.byBoatType(defaults.boatType);
        final seats = boatConfig.seatPosList;
        var seat = seats.first;
        for (final candidate in seats) {
          if (candidate.position == defaults.seatPosition) {
            seat = candidate;
            break;
          }
        }
        ref.read(boatTypeProvider.notifier).state = defaults.boatType;
        ref.read(seatPositionProvider.notifier).state = seat;
        restoredSummary.value = '${name ?? defaults.displayName}・'
            '${boatConfig.label}・${seat.label}';
      }

      unawaited(restore());
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
            strokeRateEnabled: strokeRateEnabled,
          )
              .catchError((Object error) {
            debugPrint('Failed to save navigation defaults: $error');
          }),
        );
        await onPressStartNav(
          displayName,
          strokeRateEnabled,
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
        // つまみと「閉じる」は、スクロールする本体の外に固定する。
        // 中に置くと、下の項目を見ようとスクロールした時点で出口が
        // 画面外へ消え、閉じる手段を探すことになる。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // つまみと「閉じる」。
            //
            // シート外の暗い部分をタップしても閉じられるが、それは見えない
            // 操作なので、揺れる艇の上で迷わない出口を明示しておく。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: SizedBox(
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
            ),
            Flexible(
              child: SingleChildScrollView(
                // シートは画面の8割で頭打ちにしてあるため、キーボードが出ると
                // その分だけ表示領域が狭くなる。同じ高さをスクロール領域の下へ
                // 足して、入力中の欄がキーボードに隠れないようにする。
                padding: EdgeInsets.fromLTRB(
                  20,
                  4,
                  20,
                  20 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ワークアウトは、どちらの「航行スタート」より上に置く。
                    // 前回設定の近道から始める人も、押す前に必ず目に入る。
                    if (onWorkoutChanged != null) ...[
                      _WorkoutEntry(
                        plan: workoutPlan.value,
                        enabled: !isStarting.value,
                        onTap: openWorkoutSetup,
                        onClear: () => setWorkout(null),
                      ),
                      const SizedBox(height: 16),
                    ],
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
                          border:
                              Border.all(color: Theme.of(context).primaryColor),
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
                                label:
                                    isStarting.value ? '準備中…' : 'この設定で航行スタート',
                                icon: isStarting.value
                                    ? Icons.hourglass_top
                                    : Icons.rowing,
                                onPressed: startNavigation,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    // 名前は欄そのものの見出し(labelText)で足りるので、
                    // 上に同じ語の見出しを重ねない。
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
                        errorText: nameError.value,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.person),
                      ),
                      onChanged: (_) {
                        if (nameError.value != null) nameError.value = null;
                      },
                    ),
                    // 「艇種と一緒に他の艇と監視端末へ共有される」ことを、
                    // 地図に出る札そのもので見せる。
                    if (nameController.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      BoatNameTag(
                        label:
                            boatNameLabel(boatType, nameController.text.trim()),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _sectionTitle(context, '艇種'),
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
                    _sectionTitle(context, '端末の位置（シート番号）'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: boatConfigs
                          .byBoatType(boatType)
                          .seatPosList
                          .map((seatPos) {
                        return _selectChip(
                          context: context,
                          label: seatPos.label,
                          selected: seatPos == seatPosision,
                          onPressed: () => setSeatPosition(seatPos),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),
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
                      // 音量は控えめな入口だけ置き、押すとシートを開く
                      // (2026-10-24 利用者要望: 開始画面では目立たせない)。
                      if (warningAudioVolume != null &&
                          onWarningAudioVolumeChanged != null)
                        WarningAudioVolumeLink(
                          volume: warningAudioVolume!,
                          onChanged: onWarningAudioVolumeChanged!,
                          onTest: onPressTestAudio,
                        ),
                      const SizedBox(height: 12),
                    ],
                    Center(
                      child: RoundedButton(
                        label: isStarting.value ? '準備中…' : '航行スタート',
                        icon: isStarting.value
                            ? Icons.hourglass_top
                            : Icons.rowing,
                        onPressed: startNavigation,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 航行開始前の、ワークアウトの欄。
///
/// 決めてあれば内容と始まり方を出し、無ければ「フリー」と出す。
/// 押すと設定画面へ入る。決めたメニューは航行開始で準備された状態になる
/// (`UseWorkout.prepared`)。
class _WorkoutEntry extends StatelessWidget {
  const _WorkoutEntry({
    required this.plan,
    required this.enabled,
    required this.onTap,
    required this.onClear,
  });

  final WorkoutPlan? plan;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final plan = this.plan;
    return Material(
      color: colors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dimens.radiusLg),
        side: BorderSide(
          color: plan == null ? colors.textDisabled : colors.primary,
          width: plan == null ? 1 : 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            dimens.space3,
            dimens.space3,
            dimens.space1,
            dimens.space3,
          ),
          child: Row(
            children: [
              Icon(Icons.timer_outlined, color: colors.textSecondary),
              SizedBox(width: dimens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ワークアウト',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                    Text(
                      plan == null
                          ? '決めていません(フリー)'
                          : '${workoutShortName(plan)} ・ '
                              '${formatRest(plan.restUnit, plan.restValue)}',
                      key: const ValueKey('nav-setting-workout-summary'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // 押せることは右の › が示す。始まり方だけは
                    // メニューごとに違うので、決めてあるときに添える。
                    if (plan != null)
                      Text(
                        plan.autoStart
                            ? '航行を始めると READY で待ち、漕ぎ出しで1本目'
                            : '航行中に、ワークアウトのボタンから始めます',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (plan != null)
                TextButton(
                  onPressed: enabled ? onClear : null,
                  child: const Text('やめる'),
                )
              else
                Padding(
                  padding: EdgeInsets.only(right: dimens.space2),
                  child: Icon(Icons.chevron_right, color: colors.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
