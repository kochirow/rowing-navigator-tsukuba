import 'package:flutter/material.dart';

import '../../../theme/nav_palette.dart';

/// 計器の下半分に出せる指標。ドラムを縦に回した順番もこの順。
///
/// 表記は NK SpeedCoach に倣う(2026-09-26 利用者): 距離=m、漕いでいる時間=chrono、
/// 1本の距離=DPS、リセットからの本数=count。日本語に言い換えない。
enum NavLowerMetric { distance, chrono, dps, count }

/// 下半分に出す値。距離・chrono・count は「リセットからの値」。
class NavLowerValues {
  const NavLowerValues({
    required this.distanceMeters,
    required this.chronoSeconds,
    this.dpsMeters,
    this.strokeCount,
  });

  final int distanceMeters;
  final int chronoSeconds;

  /// 直近1本の DPS [m]。計測できていなければ null。
  final double? dpsMeters;

  /// リセットからの本数。計測できていなければ null。
  final int? strokeCount;
}

/// 計器の下半分: 左右2つのドラム(縦に回すと指標が切り替わる)と RESET。
///
/// 左の枠は右より一回り大きい(既定で距離を置く)。文字の大きさは桁数の型
/// ([_slotOf])で決め、桁が変わっても揺らさない。単位は各枠の右下。
class NavLowerDrums extends StatelessWidget {
  const NavLowerDrums({
    super.key,
    required this.values,
    required this.leftIndex,
    required this.rightIndex,
    this.onLeftChanged,
    this.onRightChanged,
    this.onReset,
  });

  final NavLowerValues values;
  final int leftIndex;
  final int rightIndex;
  final ValueChanged<int>? onLeftChanged;
  final ValueChanged<int>? onRightChanged;

  /// 押すと距離・chrono・count の表示を0にする。null なら出さない。
  final VoidCallback? onReset;

  /// 左右の面の高さ。大きいほう(左 46px)の数字+単位の行+余白。
  static const double plateHeight = 74;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 125,
              child: _Drum(
                key: const ValueKey('nav-lower-left'),
                values: values,
                index: leftIndex,
                valueFontSize: 46,
                onChanged: onLeftChanged,
              ),
            ),
            const SizedBox(width: _gap),
            Expanded(
              flex: 100,
              child: _Drum(
                key: const ValueKey('nav-lower-right'),
                values: values,
                index: rightIndex,
                valueFontSize: 36,
                onChanged: onRightChanged,
              ),
            ),
          ],
        ),
        if (onReset != null)
          Align(
            alignment: Alignment.centerRight,
            child: _ResetButton(onPressed: onReset!),
          ),
      ],
    );
  }
}

class _Drum extends StatefulWidget {
  const _Drum({
    super.key,
    required this.values,
    required this.index,
    required this.valueFontSize,
    this.onChanged,
  });

  final NavLowerValues values;
  final int index;
  final double valueFontSize;
  final ValueChanged<int>? onChanged;

  @override
  State<_Drum> createState() => _DrumState();
}

class _DrumState extends State<_Drum> {
  late final PageController _controller =
      PageController(initialPage: widget.index);
  late int _page = widget.index;

  @override
  void didUpdateWidget(covariant _Drum oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 保存していた位置を読み込んだときなど、外から位置が変わったら合わせる。
    if (widget.index != _page && _controller.hasClients) {
      _page = widget.index;
      _controller.jumpToPage(widget.index);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const metrics = NavLowerMetric.values;
    return Container(
      height: NavLowerDrums.plateHeight,
      decoration: BoxDecoration(
        color: NavPalette.cell,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            scrollDirection: Axis.vertical,
            itemCount: metrics.length,
            onPageChanged: (page) {
              setState(() => _page = page);
              widget.onChanged?.call(page);
            },
            itemBuilder: (context, i) => _DrumFace(
              metric: metrics[i],
              values: widget.values,
              valueFontSize: widget.valueFontSize,
            ),
          ),
          // 何番目かの印(左端の縦の点)。
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < metrics.length; i++)
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? NavPalette.value
                          : NavPalette.label.withValues(alpha: 0.35),
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

/// 各指標の**桁数の型**。実際の値ではなくこれで文字サイズを決める。
///
/// **下半分の数字は桁数で大きさを揺らさない。** 桁が変わるたびに
/// (`9:59` → `10:00`、`999` → `1,000`)大きさが跳ねると、目が毎回そこへ
/// 引かれて主計器から離れる(旧 副計器からの原則)。型に収まる限り大きさは
/// 一定で、型を超える値(1時間を超えた chrono、100km 以上)だけが縮む。
const _slotOf = {
  NavLowerMetric.distance: '00,000',
  NavLowerMetric.chrono: '00:00',
  NavLowerMetric.dps: '00.0',
  NavLowerMetric.count: '0000',
};

class _DrumFace extends StatelessWidget {
  const _DrumFace({
    required this.metric,
    required this.values,
    required this.valueFontSize,
  });

  final NavLowerMetric metric;
  final NavLowerValues values;
  final double valueFontSize;

  @override
  Widget build(BuildContext context) {
    final (value, unit) = switch (metric) {
      NavLowerMetric.distance => (
          formatNavDistance(values.distanceMeters),
          'm'
        ),
      NavLowerMetric.chrono => (
          formatNavChrono(values.chronoSeconds),
          'chrono'
        ),
      NavLowerMetric.dps => (
          values.dpsMeters == null ? '—' : values.dpsMeters!.toStringAsFixed(1),
          'DPS'
        ),
      NavLowerMetric.count => (values.strokeCount?.toString() ?? '—', 'count'),
    };
    const style = TextStyle(
      height: 1,
      fontWeight: FontWeight.bold,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Semantics(
      label: '$unit $value',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
        child: LayoutBuilder(builder: (context, constraints) {
          // 型が幅に収まる大きさ(上限 [valueFontSize])を先に決める。
          final scaler = MediaQuery.textScalerOf(context);
          final slot = TextPainter(
            text: TextSpan(
              text: _slotOf[metric],
              style: style.copyWith(fontSize: 100),
            ),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout();
          final fitted = slot.width <= 0
              ? valueFontSize
              : (100 * constraints.maxWidth / slot.width)
                  .clamp(12.0, valueFontSize);
          slot.dispose();
          return Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 型を超える値(1時間超の chrono など)だけがここで縮む。
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: style.copyWith(
                      color: NavPalette.value,
                      fontSize: fitted.toDouble(),
                    ),
                  ),
                ),
              ),
              // 単位は右下にそろえる(利用者)。
              Text(
                unit,
                maxLines: 1,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: NavPalette.label,
                  fontSize: 13,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '下の計器を0にする。記録は練習全体を残す',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        // 押しやすさより、数字の邪魔をしないことを優先して小さく端に置く
        // (押すのは止まっているとき)。触れる範囲は高さ36を確保する。
        child: const SizedBox(
          height: 36,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.restart_alt, size: 16, color: NavPalette.label),
                SizedBox(width: 4),
                Text(
                  'RESET',
                  style: TextStyle(
                    color: NavPalette.label,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 距離の表示。桁区切りつきの m(`12,480`)。km へは切り替えない
/// (切り替わる瞬間に桁と大きさが跳ねる。NK SpeedCoach も m のまま)。
String formatNavDistance(int meters) {
  final digits = meters.clamp(0, 999999).toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// chrono の表示。`m:ss`、1時間を超えたら `h:mm:ss`。
String formatNavChrono(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
