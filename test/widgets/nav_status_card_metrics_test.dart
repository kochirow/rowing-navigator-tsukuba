import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_lower_drums.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_status_card.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

/// 計器の大きさが状況で変わらないことを守るテスト。
///
/// 元の実装は連続音の警告中に主計器を縮めていた(`deemphasized`)。
/// 大きさが変わること自体が読み取りを遅らせるため廃止した。
/// 「警告中だから縮める」たぐいの分岐が戻ってきたら、ここで落ちる。
///
/// あわせて、**航行中の計器カードに艇速変化グラフを戻さない**ことも
/// ここで固定する(2026-08-13に廃止)。グラフが占めていた高さは
/// 副計器(経過時間・距離)へ回した。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    bool spmEnabled = true,
    bool compact = false,
    bool portraitCompact = false,
    int paceSeconds = 120,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: NavStatusCard(
            paceSeconds: paceSeconds,
            distanceMeters: 1000,
            elapsedTimeSeconds: 60,
            spm: 24,
            spmMeasurementEnabled: spmEnabled,
            compact: compact,
            portraitCompact: portraitCompact,
          ),
        ),
      ),
    );
  }

  double fontSizeOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.fontSize!;

  testWidgets('主計器はペース52px・SPM44px', (tester) async {
    await pumpCard(tester);

    expect(fontSizeOf(tester, '2:00'), 52);
    expect(fontSizeOf(tester, '24'), 44);
  });

  testWidgets('副計器(距離・経過時間)は主計器より小さく、添え物には落とさない', (tester) async {
    await pumpCard(tester);

    // 16px(グラフがあった頃の添え物)まで戻したら落ちる。
    expect(fontSizeOf(tester, '1.00 km'), 24);
    expect(fontSizeOf(tester, '1:00'), 24);
    expect(fontSizeOf(tester, '1.00 km'), lessThan(fontSizeOf(tester, '2:00')));
  });

  testWidgets('再buildしても主計器の大きさは変わらない', (tester) async {
    await pumpCard(tester);
    final normalPace = fontSizeOf(tester, '2:00');
    final normalSpm = fontSizeOf(tester, '24');

    await pumpCard(tester);

    expect(fontSizeOf(tester, '2:00'), normalPace);
    expect(fontSizeOf(tester, '24'), normalSpm);
  });

  testWidgets('SPMは計測ONなら常時表示する', (tester) async {
    await pumpCard(tester, spmEnabled: true);
    expect(find.text('24'), findsOneWidget);

    // OFFのときだけ表示領域ごと取り除く(従来どおり)。
    await pumpCard(tester, spmEnabled: false);
    expect(find.text('24'), findsNothing);
  });

  testWidgets('縦向き小型でもSPMを消さず、主計器がカード幅を使い切る', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    expect(find.byKey(const ValueKey('compact-spm')), findsOneWidget);
    // 画面上の実寸で確認する。文字は FittedBox で拡大されるため、
    // style.fontSize は基準値であって表示サイズではない。
    final card = tester.getRect(
        find.byKey(const ValueKey('nav-status-card-portrait-compact')));
    final pace = tester.getRect(find.text('2:00'));
    final spm = tester.getRect(find.text('24'));
    expect(pace.height, greaterThan(40));
    expect(pace.height, greaterThan(spm.height));
    // ペース左端からレート右端までがカード幅の8割以上を占める。
    expect(spm.right - pace.left, greaterThan(card.width * 0.8));
  });

  testWidgets('主計器の数字はカード幅に対する取り分を保つ', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    final card = tester.getRect(
        find.byKey(const ValueKey('nav-status-card-portrait-compact')));
    final pace = tester.getRect(find.text('2:00'));

    // 主計器の実寸は「カード幅 ÷ 行全体の基準幅」で決まる。単位や面の余白を
    // 太らせると、カードの大きさは変わらないまま数字だけが縮む。
    // 幅から逆算する方式(2026-08-13)にしてからの取り分をここで固定する。
    expect(pace.height, greaterThan(card.width * 0.14));
  });

  testWidgets('主計器の大きさは表示する値でも状態でも変わらない', (tester) async {
    // 桁で揺れないこと。等幅数字なので `2:00` と `5:59` は同じ幅の型に入る。
    await pumpCard(tester, portraitCompact: true);
    final base = tester.getRect(find.text('2:00')).height;

    await pumpCard(tester, portraitCompact: true, paceSeconds: 359);
    expect(tester.getRect(find.text('5:59')).height, closeTo(base, 0.5));

    // SPM計測のON/OFFでも変えない。面は広がるが数字は同じ大きさ。
    await pumpCard(tester, portraitCompact: true, spmEnabled: false);
    expect(tester.getRect(find.text('2:00')).height, closeTo(base, 0.5));
  });

  testWidgets('意味を持たない遅さは値ではなく代替表示にする', (tester) async {
    // 10分/500m より遅いのは漂流・係留であってペースではない。
    // ここを値として出すと桁が5つになり、漕行中の数字まで小さくなる。
    await pumpCard(tester, portraitCompact: true, paceSeconds: 601);
    expect(find.text('--:--'), findsOneWidget);

    await pumpCard(tester, portraitCompact: true, paceSeconds: 599);
    expect(find.text('9:59'), findsOneWidget);
  });

  testWidgets('縦向き小型の下半分は面を持ち、行いっぱいに置く', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    final card = tester.getRect(
        find.byKey(const ValueKey('nav-status-card-portrait-compact')));
    final left = tester.getRect(find.byKey(const ValueKey('nav-lower-left')));
    final right = tester.getRect(find.byKey(const ValueKey('nav-lower-right')));

    // 下半分はドラム式(2026-09-26)。既定は 左=距離(m)・右=chrono。
    expect(find.text('1,000'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    // 左右に並べる。上下に積むと高さだけ取って読まれない。
    expect(left.left, lessThan(right.left));
    expect(left.center.dy, closeTo(right.center.dy, 2));
    // 左(距離)は右(chrono)より一回り大きい枠。
    expect(left.width, greaterThan(right.width));
    // 2つで行の左右へ広がる(グラフの左に58pxで畳まれていた頃に戻さない)。
    expect(right.right - left.left, greaterThan(card.width * 0.8));
    // 主計器の下にある。
    expect(left.top, greaterThan(tester.getRect(find.text('2:00')).bottom));
  });

  testWidgets('主計器はフィールドごとの面で分け、字には縁取りを掛けない', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    // 面はペース・レート・下半分の左右で4枚。色が読めなくても
    // 「計器が並んでいる」ことが形で分かる。
    // カード自身の面は descendant に含まれない。
    final plates = tester
        .widgetList<Container>(find.descendant(
      of: find.byKey(const ValueKey('nav-status-card-portrait-compact')),
      matching: find.byType(Container),
    ))
        .where((container) {
      final decoration = container.decoration;
      // ドラムの位置の印(小さな丸い点)は計器の面ではない。
      return decoration is BoxDecoration &&
          decoration.color != null &&
          decoration.shape == BoxShape.rectangle;
    }).toList();
    expect(plates.length, 4, reason: '計器の面が4枚でない');
    // レート側だけが縁を持つ。**面の色と縁が背景と別の系統になる**ことが
    // 「枠が効かない」への答えなので、縁を落とさないよう固定する。
    expect(
      plates
          .where((p) => (p.decoration as BoxDecoration).border != null)
          .length,
      1,
      reason: 'レートの面から縁が消えている',
    );

    // 下地が濃紺1種類に確定したので、字の縁取りはコストだけが残る。
    // (字画の内側を食って数字を鈍らせる)。掛けないことを固定する。
    for (final text in ['2:00', '24', '1:00', '1,000']) {
      final style = tester.widget<Text>(find.text(text)).style!;
      expect(
        style.shadows ?? const [],
        isEmpty,
        reason: '$text に縁取りが戻っている(面で対比を作る設計に反する)',
      );
    }

    // 2枚の面は同じ高さに揃える。字なりに作ると「格の違う2つ」に見える。
    final paceHeight = tester.getRect(find.text('2:00')).height;
    final spmHeight = tester.getRect(find.text('24')).height;
    expect(paceHeight, greaterThan(spmHeight), reason: '主計器はペースが主で、レートが従');
  });

  testWidgets('横向き小型でもSPMを消さない', (tester) async {
    await pumpCard(tester, compact: true);

    expect(find.byKey(const ValueKey('compact-spm')), findsOneWidget);
    expect(tester.getRect(find.text('2:00')).height, greaterThan(40));
  });

  testWidgets('縦向き小型は画面幅の96%を使い中央に寄せる', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final card = tester.getRect(
        find.byKey(const ValueKey('nav-status-card-portrait-compact')));
    expect(card.width, closeTo(screenWidth * 0.96, 1));
    expect(card.center.dx, closeTo(screenWidth / 2, 1));
  });

  testWidgets('航行中の計器カードに艇速変化グラフ・1ストローク指標を出さない', (tester) async {
    for (final compact in [false, true]) {
      await pumpCard(tester, portraitCompact: compact);

      // 波形は監視端末(StrokeTraceSheet)だけの機能に戻した。
      expect(find.byKey(const ValueKey('stroke-speed-chart')), findsNothing);
      expect(find.byKey(const ValueKey('stroke-metrics-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsNothing);
      expect(find.text('分析'), findsNothing);
      expect(find.textContaining('艇速変化'), findsNothing);
    }
  });

  testWidgets('長い練習でも下半分がはみ出さず、単位と RESET を出す', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: NavStatusCard(
            paceSeconds: 125,
            distanceMeters: 12480,
            elapsedTimeSeconds: 5320,
            spm: 34,
            spmMeasurementEnabled: true,
            portraitCompact: true,
            lowerValues: const NavLowerValues(
              distanceMeters: 12480,
              chronoSeconds: 5320,
              dpsMeters: 10.4,
              strokeCount: 1780,
            ),
            onLowerReset: () => resets++,
          ),
        ),
      ),
    );
    // はみ出すと RenderFlex overflow の例外になる。
    expect(tester.takeException(), isNull);
    expect(find.text('12,480'), findsOneWidget);
    expect(find.text('1:28:40'), findsOneWidget);
    expect(find.text('m'), findsOneWidget);
    expect(find.text('chrono'), findsOneWidget);

    await tester.tap(find.text('RESET'));
    expect(resets, 1);
  });

  test('距離は桁区切りの m、chrono は m:ss / h:mm:ss', () {
    expect(formatNavDistance(0), '0');
    expect(formatNavDistance(999), '999');
    expect(formatNavDistance(12480), '12,480');
    expect(formatNavChrono(59), '0:59');
    expect(formatNavChrono(1720), '28:40');
    expect(formatNavChrono(5320), '1:28:40');
  });
}
