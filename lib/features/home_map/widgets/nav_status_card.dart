import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 航行中に画面上部へ常時表示する計器カード。
///
/// 計器と補助値だけを表示し、GPS・通信・安全設定などのシステム状態は
/// 上部の警告や専用画面へ集約する。
///   1. 主計器: ペース。SPM計測がONの時はレートを併記。
///   2. 副計器: 経過時間・距離。主計器と同じ「面」で、行いっぱいに置く。
///
/// **1ストロークの艇速変化グラフは航行中には出さない(2026-08-13)。**
/// 漕ぎながら波形を読む場面が実際には無く、上部の一等地を主計器と
/// 取り合っていた。空いた高さは副計器(経過時間・距離)へ回し、
/// 14〜15pxの添え物だったものを面のある計器に戻してある。
/// 波形そのものは監視端末側(`stroke_trace_sheet.dart`)に残っており、
/// 艇側は従来どおり計測・共有する(陸上で見るぶんには有用なため)。
/// **戻すときは「漕ぎながら読むのか」を先に確かめること。**
///
/// **小型表示の主計器は、カード幅が許す限り大きくする。**
/// ペース・レート・単位を1つの [FittedBox] に入れて横いっぱいへ拡大する
/// ので、実寸は幅で決まる(`_paceBaseFontSize` 他は比率)。地図との両立は
/// 文字を縮めることではなく、**縦向きは横幅9割の中央寄せ・横向きは
/// 左上寄せで幅を絞ること**と、**カード面を半透明にすること**で取る。
///
/// **主計器の大きさは状況で変えない(`deemphasized` を廃止した記録)。**
///
/// 元の実装には「連続音が鳴っている間は主計器を縮めて(ペース52→32px、
/// SPMは非表示)、警告バナーへ視線の一等地を譲る」という意図があった。
/// これを外したのは、**計器の大きさが状況で変わること自体が読み取りを
/// 遅らせる**という利用者判断による。漕手が常時見たいのはペースとSPMの
/// 2つだけで、その2つが警告のたびに動く・消えることのほうが害が大きい。
///
/// 警告バナーの表示・音・優先順位は一切変えていないので、警告が伝わらなく
/// なることはない。**この判断を戻すときは、その理由もここへ書くこと。**
class NavStatusCard extends StatelessWidget {
  final int paceSeconds;
  final int distanceMeters;
  final int elapsedTimeSeconds;
  final double? spm; // ストロークレート(計測不能時はnull)
  final bool spmMeasurementEnabled; // ユーザーがSPM計測をONにしているか
  final bool compact; // 横向き用。左上へ寄せ、幅だけを絞る
  final bool portraitCompact; // 縦向き用。横幅9割を中央寄せで使う
  const NavStatusCard({
    super.key,
    required this.paceSeconds,
    required this.distanceMeters,
    required this.elapsedTimeSeconds,
    this.spm,
    this.spmMeasurementEnabled = false,
    this.compact = false,
    this.portraitCompact = false,
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

    // OFF時は値だけでなくSPM・艇速分析の表示領域ごと取り除く。
    final spmValueText = spm?.toStringAsFixed(0) ?? '--';

    if (compact || portraitCompact) {
      return _buildCompact(
        colors: colors,
        onDark: onDark,
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
        dimens.space4,
        dimens.space5,
        dimens.space4,
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
                          fontSize: 52,
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
              if (spmMeasurementEnabled) ...[
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
                          style: const TextStyle(
                            fontSize: 44,
                            height: 1.1,
                            fontWeight: FontWeight.bold,
                            color: _rateAccent,
                            fontFeatures: _tabularFigures,
                          ),
                        ),
                        Text(
                          ' spm',
                          style: TextStyle(
                            fontSize: 18,
                            color: _rateAccent.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: dimens.space3),
          Divider(height: 1, color: onDark.withValues(alpha: 0.2)),
          SizedBox(height: dimens.space3),
          // ---- 第2階層(副計器): 経過時間・距離 ----
          //
          // 艇速グラフを外したぶんの高さをここへ回している。横に2つ並べ、
          // 行いっぱいを使う。縦に積んで16pxで書いていた頃は、主計器の
          // 下に付いた添え物にしか見えず、揺れる艇の上では読めなかった。
          Row(
            children: [
              Expanded(
                child: _InlineMetric(
                  icon: Icons.timer_outlined,
                  value: _formatTime(elapsedTimeSeconds),
                ),
              ),
              SizedBox(width: dimens.space3),
              Expanded(
                child: _InlineMetric(
                  icon: Icons.straighten,
                  value: _formatDistance(distanceMeters),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 主計器の基準寸法。**実寸ではなく比率**として使う。
  ///
  /// ペース・レート・単位を1つの [FittedBox] へ入れて横幅いっぱいまで
  /// 拡大するので、実際の文字サイズは「カード幅 ÷ この組の基準幅」で決まる。
  /// ここの値どうしの比だけが見た目を決める。単位を小さくすると
  /// そのぶん数字が大きくなる。
  ///
  /// レートはペースの約77%(ペース80pxならレート62px)。レートは2桁固定で
  /// 幅が出ないため、同じ比でも小さく見える。かといって近づけすぎると
  /// 「主計器が2つある」ように見えて、視線がどちらへ行くか決まらない。
  static const double _paceBaseFontSize = 92;
  static const double _paceUnitBaseFontSize = 16;
  static const double _spmBaseFontSize = 71;
  static const double _spmUnitBaseFontSize = 14;

  /// 計器の面どうしの間隔(基準寸法。[FittedBox] が一緒に縮小する)。
  static const double _plateGap = 10;

  /// 面の左右の余白(基準寸法)。
  static const double _platePaddingHorizontal = 12;

  /// 面の高さ(基準寸法)。
  ///
  /// **2枚を同じ高さにする。** ペースとレートは字の大きさが違うので、
  /// 面を字なりに作ると高さの違う箱が2つ並び、「格の違う2つ」に見える。
  /// 大きいほうの字([_paceBaseFontSize])に上下の余白を足した値で固定する。
  ///
  /// [FittedBox] の中は縦が無制限なので、`CrossAxisAlignment.stretch` では
  /// 高さを揃えられない(レイアウトが解けない)。実寸で決め打つ。
  static const double _plateHeight = _paceBaseFontSize + 12;

  /// 面の角丸。
  static const double _plateRadius = 14;

  /// レート側の面の縁の太さ。[FittedBox] の縮小(実測で約0.75倍)を見込んで、
  /// 実寸で1.5px程度になる値を置く。
  static const double _plateBorderWidth = 2;

  /// 副計器(経過時間・距離)の面の高さ。
  ///
  /// **主計器の半分強にする。** 同じ高さにすると計器が4つ横並びに見えて、
  /// ペースとレートがどれか分からなくなる。艇速グラフ(84px)を外して
  /// 空いた高さのうち、ここへ回すのは面1枚ぶんだけで、残りは地図へ返す。
  static const double _secondaryPlateHeight = 52;

  /// 副計器の数値・単位・アイコンの寸法。**実寸**(拡大しない)。
  ///
  /// 主計器と違って [FittedBox] で行いっぱいへ引き伸ばさない。桁数が
  /// 変わるたびに(`9:59` → `10:00`、`999 m` → `1.00 km`)大きさが跳ねると、
  /// 目が毎回そこへ引かれて主計器から離れる。**桁で揺れないことが、
  /// 数pxの大きさより効く。**
  static const double _secondaryValueFontSize = 30;
  static const double _secondaryUnitFontSize = 14;
  static const double _secondaryIconSize = 20;

  /// 主計器のうち、レートだけに与える色。
  ///
  /// ペースとレートは同じ大きさ帯の数字が2つ並ぶので、白一色だと視線が
  /// どちらへ行くか決まらない。ペースは白のまま(いちばん明るい=主)にし、
  /// レートはアプリの寒色系の明るい方へ振る。**色は補助チャネルで、
  /// 位置と単位が主。** 色が読めなくても意味は失われない。
  ///
  /// danger/warning/caution/ok は状態を表す色として取ってあるので、
  /// 計器には使わない(赤い数字は「異常」に見える)。
  static const Color _rateAccent = Color(0xFF8FD0EA);

  /// レートの字面。ペースの白に対して、明度をできるだけ落とさずに色相で分ける。
  static const Color _rateValueColor = Color(0xFFD6F2FF);

  /// 計器の面。**ペースもレートも同じ暗い面を使う。**
  ///
  /// 初版はレート側を水色 alpha 0.14 で染めていたが、**明るい文字の下に
  /// 明るい面を敷いたことで対比を自分で削っていた**(実機で「レートが読み
  /// にくい」)。カードの面の上に重ねた実効色で概算すると、
  /// ペースの白が約15:1に対してレートは約7:1しかなかった。
  ///
  /// 面を暗いほうへ揃えると約12:1まで戻る。**色は面ではなく縁と字が持つ。**
  /// 屋外の定石(明るい対象を暗い下地へ)にも、これが正しい向きである。
  /// 面を染め直したくなったら、まず対比を計算すること。
  static const Color _plateColor = Color(0x8C001E33);

  /// レート側の面の縁。ここだけが背景と別の色系統を持つ。
  ///
  /// **枠の色分けは縁が担う。** 面を染めると字の対比を失うが、縁なら
  /// 字に触れずに「別の計器だ」と言える。
  static const Color _ratePlateBorderColor = Color(0xE68FD0EA);

  /// 横向きカードの最大幅。縦向き(画面幅の9割)と同程度の文字寸法になる幅。
  static const double _landscapeMaxWidth = 360;

  /// 縦向きカードが使う画面幅の割合。
  static const double _portraitWidthFactor = 0.9;

  /// **文字の縁取り(輪郭影)はもう持たない(2026-08-05 / 2026-08-13)。**
  ///
  /// 半透明のカードに白文字を置いていた頃は、「明るいにじみ + 黒の
  /// キーライン」の二重縁取りで、明るい地図の上でも暗い水面の上でも
  /// 対比が残るようにしていた。その後
  ///   1. カードの面を alpha 0.86 まで濃くして下地を濃紺1種類に確定させ、
  ///   2. 計器をフィールドごとの面([_MetricPlate] / [_SecondaryPlate])で分けた
  /// ため、縁取りは対比を作らずに字画の内側を食うだけになった
  /// (ペース92pxで7.4px)。**対比は面の明度差で作る。**
  ///
  /// 最後まで残っていた補助情報(14px)の縁取りは、艇速グラフを外して
  /// 経過時間・距離を面に載せた時点で下地が確定したので落とした。
  /// 戻すときは「下地が本当に混在するのか」を先に確かめること。
  /// 実装は git 履歴(`_outlineShadows`)にある。

  Widget _buildCompact({
    required AppColors colors,
    required Color onDark,
    required String spmValueText,
    required bool portrait,
  }) {
    if (portrait) {
      // 縦向きは横幅を目一杯(9割)使い、中央へ寄せる。
      // 親の Align が左寄せでも中央に見えるよう、余白を左右へ等分する。
      return LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final cardWidth = available * _portraitWidthFactor;
          final side = ((available - cardWidth) / 2).clamp(0.0, available);
          return _compactCard(
            colors: colors,
            onDark: onDark,
            spmValueText: spmValueText,
            portrait: true,
            width: cardWidth,
            margin: EdgeInsets.fromLTRB(side, 8, side, 8),
          );
        },
      );
    }
    return _compactCard(
      colors: colors,
      onDark: onDark,
      spmValueText: spmValueText,
      portrait: false,
      margin: const EdgeInsets.all(8),
    );
  }

  Widget _compactCard({
    required AppColors colors,
    required Color onDark,
    required String spmValueText,
    required bool portrait,
    required EdgeInsets margin,
    double? width,
  }) {
    // 余白は Container の margin ではなく外側の Padding で持つ。
    // margin にすると key で取れる大きさに余白が混ざり、
    // 「カードの幅」を測るテストが実寸を見られなくなる。
    return Padding(
      padding: margin,
      child: Container(
        key: ValueKey(
          portrait
              ? 'nav-status-card-portrait-compact'
              : 'nav-status-card-compact',
        ),
        width: width,
        constraints: width == null
            ? const BoxConstraints(maxWidth: _landscapeMaxWidth)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          // 文字の輪郭影(`_outlineShadows`)だけでは、地図の明るい部分
          // (建物・砂地・白い橋)の上で数字が沈む。実機では日光下で読めない
          // 場面があったため、面をほぼ不透明まで濃くする。地図はカードの
          // 外側に十分残っており、ここを透かして得るものはない。
          color: colors.mapPanelScrim.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.24),
            width: 1,
          ),
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
            // ペースとレートを1つの FittedBox に入れ、カード幅いっぱいまで
            // 拡大する。2つを別々に縮小すると、間に無駄な余白が空いたまま
            // 数字だけが小さいという最悪の組合せになる。
            //
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _MetricPlate(
                      plateColor: _plateColor,
                      borderColor: null,
                      value: _formatPace(paceSeconds),
                      valueColor: onDark,
                      valueFontSize: _paceBaseFontSize,
                      unit: '/500m',
                      unitColor: onDark.withValues(alpha: 0.82),
                      unitFontSize: _paceUnitBaseFontSize,
                    ),
                    if (spmMeasurementEnabled) ...[
                      const SizedBox(width: _plateGap),
                      _MetricPlate(
                        plateColor: _plateColor,
                        borderColor: _ratePlateBorderColor,
                        value: spmValueText,
                        valueKey: const ValueKey('compact-spm'),
                        valueColor: _rateValueColor,
                        valueFontSize: _spmBaseFontSize,
                        unit: 'spm',
                        unitColor: _rateValueColor.withValues(alpha: 0.9),
                        unitFontSize: _spmUnitBaseFontSize,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 副計器(経過時間・距離)。**主計器と同じ「面」に載せる。**
            //
            // 艇速グラフを外して空いた高さをここへ回した。以前は14pxの
            // 文字を1行に並べただけで、面も持たず、グラフを出すと左端の
            // 58px幅の列へ畳まれていた。ピースの経過時間は漕ぎながら
            // いちばん見る値の1つなので、面のある計器に戻す。
            const SizedBox(height: _plateGap),
            Row(
              children: [
                Expanded(
                  child: _SecondaryPlate(
                    icon: Icons.timer_outlined,
                    value: _formatTime(elapsedTimeSeconds),
                  ),
                ),
                const SizedBox(width: _plateGap),
                Expanded(
                  child: _SecondaryPlate(
                    icon: Icons.straighten,
                    value: _formatDistance(distanceMeters),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 主計器1つぶんの「面」。数字と単位を1枚の面へ載せる。
///
/// **枠は文字の輪郭ではなく、計器の境界である。** 舶用計器や自転車用
/// サイクルコンピュータがデータフィールドを箱で区切るのと同じで、
/// 面が分かれていれば「計器が2つある」ことが色を読まなくても分かる。
/// 面の色はそのうえで**どちらの計器か**を補助的に伝える。
///
/// 単位は数字の右下へベースライン揃えで置く。位置と単位が主で色は従、
/// という [NavStatusCard._rateAccent] の方針をそのまま引き継ぐ。
class _MetricPlate extends StatelessWidget {
  final Color plateColor;
  final Color? borderColor;
  final String value;
  final Key? valueKey;
  final Color valueColor;
  final double valueFontSize;
  final String unit;
  final Color unitColor;
  final double unitFontSize;

  const _MetricPlate({
    required this.plateColor,
    required this.borderColor,
    required this.value,
    required this.valueColor,
    required this.valueFontSize,
    required this.unit,
    required this.unitColor,
    required this.unitFontSize,
    this.valueKey,
  });

  @override
  Widget build(BuildContext context) {
    final border = borderColor;
    return Container(
      height: NavStatusCard._plateHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: NavStatusCard._platePaddingHorizontal,
      ),
      decoration: BoxDecoration(
        color: plateColor,
        borderRadius: BorderRadius.circular(NavStatusCard._plateRadius),
        border: border == null
            ? null
            : Border.all(
                color: border,
                width: NavStatusCard._plateBorderWidth,
              ),
      ),
      // 高さを決め打つので、中身は面の中央へ置く。`widthFactor: 1` で
      // 横幅だけは字なりに縮める(面の幅が字で決まる)。
      child: Center(
        widthFactor: 1,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              key: valueKey,
              style: TextStyle(
                color: valueColor,
                fontSize: valueFontSize,
                height: 1,
                fontWeight: FontWeight.bold,
                fontFeatures: NavStatusCard._tabularFigures,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              unit,
              style: TextStyle(
                color: unitColor,
                fontSize: unitFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
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
          Icon(icon, size: 22, color: onDark.withValues(alpha: 0.75)),
          SizedBox(width: context.dimens.space2),
          Text(
            value,
            style: TextStyle(
              // 副計器。主計器(ペース52px・SPM44px)との差は保ちつつ、
              // 艇速グラフを外して空いた高さのぶんだけ大きくする。
              fontSize: 24,
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

/// 副計器(経過時間・距離)1つぶんの面。
///
/// **主計器と同じ形で、一段小さい。** 面・角丸・等幅数字は [_MetricPlate]
/// と揃え、高さと文字だけを落とす。同じ形なら「同じ種類のもの(計器)が
/// 4つある」と読め、大きさの差だけが主従を伝える。
///
/// アイコンは種類の印として残す。`0:14` と `120 m` は形でも見分けが
/// つくが、日光下でちらりと見るときは時計と物差しの形のほうが速い。
///
/// 面を持つので、文字の縁取り([NavStatusCard._smallOutlineShadows])は
/// 掛けない。下地が濃紺1種類に確定していれば縁は字画を食うだけになる、
/// という主計器と同じ理由。
class _SecondaryPlate extends StatelessWidget {
  final IconData icon;
  final String value;

  const _SecondaryPlate({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    final onDark = context.colors.onDark;
    // 「12.35 km」の単位側だけを小さくする。数字が主で単位は従。
    final spaceIndex = value.indexOf(' ');
    final number = spaceIndex < 0 ? value : value.substring(0, spaceIndex);
    final unit = spaceIndex < 0 ? null : value.substring(spaceIndex + 1);
    return Container(
      height: NavStatusCard._secondaryPlateHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: NavStatusCard._platePaddingHorizontal,
      ),
      decoration: BoxDecoration(
        color: NavStatusCard._plateColor,
        borderRadius: BorderRadius.circular(NavStatusCard._plateRadius),
      ),
      // 桁が増えても面から溢れないよう、中身だけを縮める。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        // アイコンはベースライン揃えの行の外へ出す。文字ではないので
        // ベースラインを持たず、中へ入れると縦位置が決められない。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: NavStatusCard._secondaryIconSize,
              color: onDark.withValues(alpha: 0.75),
            ),
            const SizedBox(width: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  number,
                  style: TextStyle(
                    color: onDark,
                    fontSize: NavStatusCard._secondaryValueFontSize,
                    height: 1,
                    fontWeight: FontWeight.bold,
                    fontFeatures: NavStatusCard._tabularFigures,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit,
                    style: TextStyle(
                      color: onDark.withValues(alpha: 0.8),
                      fontSize: NavStatusCard._secondaryUnitFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
