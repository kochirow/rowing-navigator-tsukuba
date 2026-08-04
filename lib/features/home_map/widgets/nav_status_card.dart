import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/rowing_motion_fusion.dart';
import '../../../services/stroke_speed_trace.dart';
import '../../../theme/app_theme.dart';
import 'stroke_metrics_chips.dart';
import 'stroke_speed_chart.dart';

/// 航行中に画面上部へ常時表示する計器カード。
///
/// 計器と補助値だけを表示し、GPS・通信・安全設定などのシステム状態は
/// 上部の警告や専用画面へ集約する。
///   1. 主計器: ペース。SPM計測がONの時はレートを併記。
///   2. 補助: 距離・経過時間(16px)。
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
  final RowingMotionMetrics? strokeMotion;
  final bool strokeMotionDisplayEnabled;

  /// 艇速変化グラフ1画面ぶんの切り出し。
  ///
  /// **`ValueNotifier` ではなく関数で受ける。** 25Hzで値を配ると計器カード
  /// 全体が毎フレーム再buildされ、ペース・SPMの文字まで作り直しになる。
  /// グラフは自前のTickerでこの関数を引き、CustomPaintだけを描き直す。
  final StrokeSpeedTraceWindow? Function(DateTime now)?
      strokeTraceWindowBuilder;
  final bool spmMeasurementEnabled; // ユーザーがSPM計測をONにしているか
  final bool compact; // 横向き用。左上へ寄せ、幅だけを絞る
  final bool portraitCompact; // 縦向き用。横幅9割を中央寄せで使う
  const NavStatusCard({
    super.key,
    required this.paceSeconds,
    required this.distanceMeters,
    required this.elapsedTimeSeconds,
    this.spm,
    this.strokeMotion,
    this.strokeMotionDisplayEnabled = false,
    this.strokeTraceWindowBuilder,
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
          if (strokeMotionDisplayEnabled) ...[
            SizedBox(height: dimens.space2),
            _StrokeMotionSection(
              metrics: strokeMotion,
              windowBuilder: strokeTraceWindowBuilder,
              chartHeight: 82,
            ),
          ],
          SizedBox(height: dimens.space2),
          Divider(height: 1, color: onDark.withValues(alpha: 0.2)),
          SizedBox(height: dimens.space2),
          // ---- 第2階層(補助) ----
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

  /// 縮小カードで艇速グラフに与える高さ。
  ///
  /// 経過時間・距離をグラフの左へ畳んだぶん、独立した行(約26px)が不要に
  /// なったので、その分をここへ回している。
  static const double _compactChartHeight = 84;

  /// グラフ左の細い列の幅。
  ///
  /// アイコンを外し、数値を列の左端へ寄せてある。アイコンぶんの18pxを
  /// 削れたので、空きは数値とグラフのあいだ(=ふつうの余白)に見える。
  /// これ以上広げるとグラフの横(=時間軸)が痩せて、2ストロークが詰まる。
  static const double _compactMetricRailWidth = 58;

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

  /// 縁取り(キーライン)の色。
  ///
  /// **わずかに暖色へ振った不透明の黒。** カードの面はどれも寒色の紺
  /// (`panelScrim` = #002E4D 系)なので、同じ寒色の黒だと面と同系色に
  /// なって縁が沈む。暖色側へ寄せると、明度差だけでなく色相差でも
  /// 分離するため、暗い面の上でも縁が縁として見える。
  static const Color _outlineColor = Color(0xFF120A04);

  /// 縁取りの太さ(文字サイズに対する比)。
  ///
  /// [FittedBox] が文字ごと縮小するので、比で持たないと縮小時に
  /// 縁だけが相対的に太くなって数字が潰れる。
  static const double _outlineWidthRatio = 0.08;

  /// 白文字を「明るいにじみ + 黒のキーライン」の二重で縁取る影。
  ///
  /// **主計器(ペース・レート)はもうこれを使わない(2026-08-05)。**
  /// 以下の設計は「文字の背後に濃色の面と透けた地図が混在する」ことが
  /// 前提だった。その後カードの面を alpha 0.86 まで濃くしたので、
  /// **下地は常に濃紺1種類に確定した**。すると、
  ///   - 黒のキーライン(`_outlineColor`)は濃紺の上でほぼ不可視になり、
  ///     字画の内側を `fontSize × 0.08`(ペース92pxなら7.4px)食うだけになる
  ///   - 明るいにじみは、白い字のまわりに薄靄を作って輪郭を甘くする
  /// という、コストだけが残る状態になっていた。実機でレートの数字が
  /// ペースより鈍く見えたのはこれが理由(水色のほうが黒に食われる差が出る)。
  ///
  /// いまは主計器を **フィールドごとの面([_MetricPlate])** で分け、
  /// 対比は面の明度差で作る。字には縁取りを掛けない。屋外ディスプレイの
  /// 定石(明るい対象を暗い下地へ置く・要素を絞る)にも合う。
  ///
  /// **この関数はまだ補助情報(14px)が使っている。** 距離・経過時間・
  /// 「分析」ラベルは、艇速グラフの上や地図が透ける端に掛かるため、
  /// 下地が確定していない。戻すときは「下地が本当に混在するのか」を
  /// 先に確かめること。
  ///
  /// **黒一色の縁取りだけでは足りない。** このカードは半透明なので、
  /// 文字の背後には「濃色の面」と「透けた地図」が混在する。
  ///   - 地図が明るいとき(白い建物・空・砂地): 黒の縁が効く
  ///   - 面が暗いとき・夕暮れの水面: 黒の縁は背景に沈んで見えない
  ///
  /// そこで字幕やコミックの組版で使う二重縁取りを使う。
  ///   1. いちばん下に**明るいにじみ**を広めに敷く
  ///   2. その上に**ぼかさない黒**を8方向へ置いてキーラインを作る
  ///   3. いちばん上が白い字面
  ///
  /// 黒のキーラインが明るいにじみの内側を覆うので、実際に見えるのは
  /// 「白い字 → 黒い細線 → ほのかな明るい縁」の三層になる。
  /// 背景が明るければ黒線が、暗ければ明るい縁が効く。どちらの下地でも
  /// 必ずどこかの層が対比を作るのがこの積み方の要点。
  ///
  /// 影は list の先頭から順に描かれ、字面はいちばん最後に乗る。
  /// **順番を入れ替えないこと。** 黒を先に置くとにじみが黒を覆い、
  /// 単に眠い文字になる。
  ///
  /// なお文字を2枚重ねる(`PaintingStyle.stroke` + 塗り)方式は使わない。
  /// Textが1つのままならベースライン揃えも寸法も変わらないため。
  ///
  /// **方向の数は縁の太さから決める(重要)。** この方式の輪郭は
  /// 「字を N 方向へずらした複製の和」なので、字の角は半径 d の正N角形に
  /// なる。8方向のままキーラインを太くすると、角が目に見える多角形に
  /// なって「フォントがギザギザ」に見える。1辺の長さは
  /// `2*d*sin(π/N)` なので、これが約1px以下に収まる N を選ぶ。
  static List<Shadow> _outlineShadows(double fontSize) {
    final d = fontSize * _outlineWidthRatio;
    // 1辺 ≒ 1px 以下。細い縁では8方向で十分(描画回数を無駄にしない)。
    final steps =
        d <= 1.5 ? 8 : (math.pi / math.asin(0.5 / d)).ceil().clamp(8, 32);
    return [
      // 1. 明るいにじみ。暗い下地に対して字の塊を浮かせる。
      //    強くするとカードの上で灰色のもやに見えるので控えめに。
      Shadow(
        color: const Color(0x40C8E8F7),
        blurRadius: fontSize * 0.18,
      ),
      // 2. 黒のキーライン。明るい下地に対して輪郭を切る。
      for (var i = 0; i < steps; i++)
        Shadow(
          color: _outlineColor,
          offset: Offset(
            d * math.cos(2 * math.pi * i / steps),
            d * math.sin(2 * math.pi * i / steps),
          ),
        ),
    ];
  }

  /// 補助情報(距離・経過時間・アイコン)用。文字が小さいので比ではなく実寸。
  static final List<Shadow> _smallOutlineShadows = _outlineShadows(14);

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
            // グラフを出すときは、経過時間と距離をグラフの左へ寄せる。
            //
            // 両者はグラフより1段低い情報なので、下に独立した行を持たせると
            // 高さだけを取って読まれない。左端の細い列へ畳むと、空いた分を
            // そのままグラフの縦幅へ回せる(65 → 84px、約3割増)。
            // 波形は上下の振れ幅を読むものなので、縦が効く。
            if (strokeMotionDisplayEnabled) ...[
              const SizedBox(height: 5),
              // 高さは固定しない。1ストローク指標を開くとグラフの下へ
              // 行が増えるので、外側を固定すると溢れる。左の列だけを
              // グラフと同じ高さにして、上端を揃える。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _compactMetricRailWidth,
                    height: _compactChartHeight,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _RailMetric(value: _formatTime(elapsedTimeSeconds)),
                        _RailMetric(value: _formatDistance(distanceMeters)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StrokeMotionSection(
                      metrics: strokeMotion,
                      windowBuilder: strokeTraceWindowBuilder,
                      chartHeight: _compactChartHeight,
                      compact: true,
                    ),
                  ),
                ],
              ),
            ] else ...[
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
            ],
          ],
        ),
      ),
    );
  }
}

/// 艇速変化グラフと、その下の1ストローク指標。
///
/// **指標が出せなくてもグラフは出す。** 解析が確定するのは数ストローク
/// あとなので、そこまで何も出さないと「壊れている」ように見える(原則1)。
///
/// **1ストローク指標(距離・キャッチ減速など)は既定で畳む。**
/// 漕ぎながら読むものではなく、常時2行を占めると地図と主計器を圧迫する。
/// グラフをタップした時だけ開き、同じタップで閉じる。値そのものは
/// 練習ログに残るので、畳んでも失われる情報はない。
/// 監視端末側(`stroke_trace_sheet.dart`)は陸上で見るものなので常時表示のまま。
class _StrokeMotionSection extends StatefulWidget {
  final RowingMotionMetrics? metrics;
  final StrokeSpeedTraceWindow? Function(DateTime now)? windowBuilder;
  final double chartHeight;
  final bool compact;

  const _StrokeMotionSection({
    required this.metrics,
    required this.windowBuilder,
    required this.chartHeight,
    this.compact = false,
  });

  @override
  State<_StrokeMotionSection> createState() => _StrokeMotionSectionState();
}

class _StrokeMotionSectionState extends State<_StrokeMotionSection> {
  bool _metricsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final windowBuilder = widget.windowBuilder;
    final metrics = widget.metrics;
    final onDark = context.colors.onDark;
    final canExpand = metrics != null && windowBuilder != null;
    // グラフが無ければ畳む手段(タップ先)も無い。その場合は指標を出す。
    final showMetrics = metrics != null && (_metricsExpanded || !canExpand);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (windowBuilder != null)
          GestureDetector(
            key: const ValueKey('stroke-metrics-toggle'),
            behavior: HitTestBehavior.opaque,
            onTap: canExpand
                ? () => setState(() => _metricsExpanded = !_metricsExpanded)
                : null,
            child: Stack(
              children: [
                StrokeSpeedChart(
                  key: const ValueKey('stroke-speed-chart'),
                  windowBuilder: windowBuilder,
                  height: widget.chartHeight,
                  emptyLabel: 'ストロークの艇速変化を計測中',
                ),
                // 畳んでいることと、開く手段があることを示す最小の目印。
                // グラフの上に重ねるので高さを1pxも増やさない。
                if (canExpand)
                  Positioned(
                    left: 4,
                    bottom: 2,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _metricsExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 14,
                          color: onDark.withValues(alpha: 0.85),
                          shadows: NavStatusCard._smallOutlineShadows,
                        ),
                        Text(
                          '分析',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: onDark.withValues(alpha: 0.85),
                            shadows: NavStatusCard._smallOutlineShadows,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (showMetrics) ...[
          SizedBox(height: widget.compact ? 4 : 6),
          StrokeMetricsChips.fromMetrics(metrics, compact: widget.compact),
        ],
      ],
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
          Icon(icon, size: 18, color: onDark.withValues(alpha: 0.7)),
          SizedBox(width: context.dimens.space1),
          Text(
            value,
            style: TextStyle(
              // 補助情報。主計器(ペース52px・SPM44px)との差を明確にする。
              fontSize: 16,
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
        Icon(
          icon,
          size: 14,
          color: onDark.withValues(alpha: 0.8),
          shadows: NavStatusCard._smallOutlineShadows,
        ),
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
              shadows: NavStatusCard._smallOutlineShadows,
            ),
          ),
        ),
      ],
    );
  }
}

/// 艇速グラフの左に置く、経過時間と距離。
///
/// **アイコンを持たない。** `0:14` は時計、`120 m` は距離だと形で分かる
/// (コロンと単位が印になる)。アイコンを外したぶん列を18px細くでき、
/// その分がグラフの時間軸へ回る。
class _RailMetric extends StatelessWidget {
  final String value;

  const _RailMetric({required this.value});

  @override
  Widget build(BuildContext context) {
    final onDark = context.colors.onDark;
    // 「12.35 km」の単位側だけを小さくする。数字が主で単位は従。
    final spaceIndex = value.indexOf(' ');
    final number = spaceIndex < 0 ? value : value.substring(0, spaceIndex);
    final unit = spaceIndex < 0 ? null : value.substring(spaceIndex);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            number,
            style: TextStyle(
              color: onDark,
              fontSize: 15,
              height: 1,
              fontWeight: FontWeight.bold,
              fontFeatures: NavStatusCard._tabularFigures,
              shadows: NavStatusCard._smallOutlineShadows,
            ),
          ),
          if (unit != null)
            Text(
              unit,
              style: TextStyle(
                color: onDark.withValues(alpha: 0.75),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                shadows: NavStatusCard._smallOutlineShadows,
              ),
            ),
        ],
      ),
    );
  }
}
