import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../theme/app_theme.dart';
import '../../../utils/tactile_feedback.dart';
import 'map_type_switcher.dart';

/// 地図の見え方を切り替えるパネル。
///
/// **メニュー(行き先の一覧)から分離した理由。**
/// 表示切替は「押すと画面が変わる」行き先ではなく、その場で結果が見える
/// スイッチである。メニューの中に混ぜると、1つ押すたびにシートが閉じ、
/// 次を切り替えるために開き直すことになる。だから項目名の下へ
/// 「表示中・タップで非表示」という説明を足す必要が出ていた。
/// 説明が要るのは、リストという形が合っていない証拠だった。
///
/// このパネルは閉じないので続けて切り替えられ、背後の地図で結果が見える。
///
/// **高さの上限は呼び出し側が与える。** 画面下から開くシートなので、
/// 上部の計器カードと警告バナー(`SafetyBanner` /
/// `ObserverPriorityBanner`)を覆ってはいけない。警告表示は
/// メニュー・パネルより常に優先する。
class MapDisplayPanel extends StatelessWidget {
  final ValueListenable<MapType> mapType;
  final ValueChanged<MapType> onMapTypeChanged;

  final ValueListenable<bool> showChannelCenterline;
  final ValueChanged<bool> onShowChannelCenterlineChanged;

  final ValueListenable<bool> highContrast;
  final ValueChanged<bool> onHighContrastChanged;

  /// 航行中だけ渡す。監視端末は自艇の波形を持たないので、行ごと出さない。
  /// 「使えない項目を無効表示で並べる」より、その状態に無い機能は
  /// 最初から現れないほうが読む量が減る。
  final ValueListenable<bool>? strokeMotion;
  final ValueChanged<bool>? onStrokeMotionChanged;

  const MapDisplayPanel({
    super.key,
    required this.mapType,
    required this.onMapTypeChanged,
    required this.showChannelCenterline,
    required this.onShowChannelCenterlineChanged,
    required this.highContrast,
    required this.onHighContrastChanged,
    this.strokeMotion,
    this.onStrokeMotionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final strokeMotion = this.strokeMotion;
    final onStrokeMotionChanged = this.onStrokeMotionChanged;

    return Material(
      color: colors.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(dimens.radiusLg),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: EdgeInsets.only(
                    top: dimens.space3,
                    bottom: dimens.space3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.textDisabled,
                    borderRadius: dimens.borderSm,
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  dimens.space5,
                  0,
                  dimens.space3,
                  dimens.space2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '表示',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '地図を見ながら切り替えられます',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '閉じる',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              _GroupLabel('地図', dimens: dimens, colors: colors),
              ValueListenableBuilder<MapType>(
                valueListenable: mapType,
                builder: (context, current, _) => Padding(
                  padding: EdgeInsets.symmetric(horizontal: dimens.space5),
                  child: Row(
                    children: [
                      Expanded(
                        child: _MapTypeTile(
                          label: '地図',
                          imagePath: MapTypeSwitcher.normalMapImagePath,
                          selected: current == MapType.normal,
                          onTap: () => onMapTypeChanged(MapType.normal),
                        ),
                      ),
                      SizedBox(width: dimens.space3),
                      Expanded(
                        child: _MapTypeTile(
                          label: '航空写真',
                          imagePath: MapTypeSwitcher.satelliteMapImagePath,
                          selected: current == MapType.hybrid,
                          onTap: () => onMapTypeChanged(MapType.hybrid),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: dimens.space4),
              _GroupLabel('地図に重ねるもの', dimens: dimens, colors: colors),
              _DisplaySwitch(
                icon: Icons.route,
                title: '航路の中央線',
                description: '白い破線。越えないという取り決めを示します',
                value: showChannelCenterline,
                onChanged: onShowChannelCenterlineChanged,
              ),
              // 高コントラストは通常地図のスタイル差し替えなので、
              // 航空写真では効かない。効かない状態でONに見せると
              // 「壊れている」と読まれるため、その場で理由を書く。
              ValueListenableBuilder<MapType>(
                valueListenable: mapType,
                builder: (context, current, _) => _DisplaySwitch(
                  icon: Icons.contrast,
                  title: '高コントラスト',
                  description: current == MapType.normal
                      ? '地図を淡いグレーにし、危険区域を目立たせます'
                      : '航空写真では適用されません',
                  value: highContrast,
                  onChanged: onHighContrastChanged,
                ),
              ),
              if (strokeMotion != null && onStrokeMotionChanged != null)
                _DisplaySwitch(
                  icon: Icons.insights,
                  title: '1ストロークの艇速',
                  description: '計器のすぐ下に波形を出します',
                  value: strokeMotion,
                  onChanged: onStrokeMotionChanged,
                ),
              SizedBox(height: dimens.space4),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  final AppDimens dimens;
  final AppColors colors;

  const _GroupLabel(this.text, {required this.dimens, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        dimens.space5,
        dimens.space1,
        dimens.space5,
        dimens.space2,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.6,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// 地図種別の選択タイル。
///
/// 以前は地図の左下に1つだけ浮いていた `MapTypeSwitcher` を、
/// 他の表示切替と同じ場所へ集めた。切替先ではなく**いまどちらか**を
/// 示す形にしてある(2つ並べれば、選ばれていない側が切替先になる)。
class _MapTypeTile extends StatelessWidget {
  final String label;
  final String imagePath;
  final bool selected;
  final VoidCallback onTap;

  const _MapTypeTile({
    required this.label,
    required this.imagePath,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    // ラベルもタップ対象に含める。画像だけを押せる形にすると、
    // 濡れた手・手袋では下の文字を押して反応しないことが起きる。
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: 0.10)
            : colors.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: dimens.borderMd,
          side: BorderSide(
            color: selected ? colors.primary : colors.textDisabled,
            width: selected ? 3 : 1,
          ),
        ),
        child: InkWell(
          onTap: () {
            TactileFeedback.selection();
            onTap();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 10,
                    child: Image.asset(imagePath, fit: BoxFit.cover),
                  ),
                  if (selected)
                    Positioned(
                      top: dimens.space1,
                      right: dimens.space1,
                      child: Container(
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check,
                          size: 16,
                          color: colors.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: dimens.space2),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                    color: selected ? colors.primary : colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisplaySwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final ValueListenable<bool> value;
  final ValueChanged<bool> onChanged;

  const _DisplaySwitch({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (context, on, _) => SwitchListTile(
        value: on,
        onChanged: (next) {
          TactileFeedback.selection();
          onChanged(next);
        },
        contentPadding: EdgeInsets.symmetric(horizontal: dimens.space5),
        secondary: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: on
                ? colors.primary.withValues(alpha: 0.14)
                : colors.canvas.withValues(alpha: 0.6),
            borderRadius: dimens.borderSm,
          ),
          child: Icon(
            icon,
            size: 22,
            color: on ? colors.primary : colors.textSecondary,
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          description,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      ),
    );
  }
}
