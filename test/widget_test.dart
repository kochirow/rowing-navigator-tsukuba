import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/features/home_map/widgets/navigation_status_panel.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_status_card.dart';
import 'package:rowing_navigator/features/home_map/widgets/safety_banner.dart';
import 'package:rowing_navigator/main.dart';
import 'package:rowing_navigator/models/navigation_warning.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  void useNavigationSettingsViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  const warning = NavigationWarning(
    key: 'obstacle:test',
    category: 'bridge',
    title: '桜川橋に接近',
    message: '',
    audioAsset: 'audio/bridge_warning.mp3',
  );

  testWidgets('警告対象がなければバナーを表示しない', (tester) async {
    await tester.pumpWidget(wrap(const SafetyBanner(warning: null)));
    expect(find.byType(Text), findsNothing);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('対象名だけを省スペースで表示する', (tester) async {
    await tester.pumpWidget(wrap(const SafetyBanner(warning: warning)));
    expect(find.text('橋'), findsOneWidget);
    expect(find.text('桜川橋に接近'), findsNothing);
    expect(tester.widget<Text>(find.text('橋')).style?.fontSize, 22);
    expect(
      tester.widget<Text>(find.text('橋')).style?.color,
      const Color(0xFF241A1A),
    );
    expect(find.textContaining('後方を振り向いて'), findsNothing);
  });

  testWidgets('推測と現在の複数警告を横並びで区別する', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'shore',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              timeUntilDanger: Duration(milliseconds: 4200),
            ),
            NavigationWarning(
              key: 'reverse',
              category: 'reverse',
              title: '逆走注意',
              message: '',
              audioAsset: 'audio/reverse_warning.mp3',
            ),
          ],
        ),
      ),
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(find.text('岸'), findsOneWidget);
    expect(find.text('約5秒後に危険'), findsNothing);
    expect(find.text('逆走'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('振り向く側と残り秒数を対象名の下に添える', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'boat:other',
              category: 'other_boat',
              title: '他艇に接近',
              message: '',
              audioAsset: 'audio/boat_warning.mp3',
              timeUntilDanger: Duration(milliseconds: 4200),
              relativeBearingDegrees: 95,
            ),
          ],
        ),
      ),
    );

    expect(find.text('他艇'), findsOneWidget);
    expect(find.text('右 5秒'), findsOneWidget);
  });

  testWidgets('連続音が鳴っている警告は文字を大きくし脈動枠で囲む', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'obstacle:shore',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              urgency: WarningDisplayUrgency.imminent,
            ),
          ],
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('岸'));
    expect(label.style?.fontSize, 26);

    // 脈動は無限に繰り返すため pumpAndSettle は使わない。
    // 2フレーム進めて枠の色が変化することだけを確かめる。
    Color? frameColor() {
      final decorated = tester
          .widgetList<Container>(find.byType(Container))
          .map((container) => container.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.border == null);
      return decorated.color;
    }

    final before = frameColor();
    await tester.pump(const Duration(milliseconds: 250));
    expect(frameColor(), isNot(before));
  });

  testWidgets('表示のみの警告は淡色、音が鳴る警告は濃色にする', (tester) async {
    Color? chipColor() => tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.border != null)
        .color;

    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'obstacle:shore',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: null,
              urgency: WarningDisplayUrgency.monitoring,
            ),
          ],
        ),
      ),
    );
    final quiet = chipColor();

    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'obstacle:shore',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              urgency: WarningDisplayUrgency.action,
            ),
          ],
        ),
      ),
    );
    final audible = chipColor();

    expect(quiet, isNot(audible));
    // 淡色のほうが明るい(白へ寄せている)。
    expect(quiet!.computeLuminance(), greaterThan(audible!.computeLuminance()));
  });

  testWidgets('自艇の方位が信頼できないときは方向を出さない', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'boat:other',
              category: 'other_boat',
              title: '他艇に接近',
              message: '',
              audioAsset: 'audio/boat_warning.mp3',
              timeUntilDanger: Duration(seconds: 3),
            ),
          ],
        ),
      ),
    );

    expect(find.text('3秒'), findsOneWidget);
    expect(find.textContaining('右'), findsNothing);
    expect(find.textContaining('左'), findsNothing);
  });

  testWidgets('同じ種類の警告は1枚へまとめ、最も切迫した1件を代表にする', (tester) async {
    // 岸の危険区域は基準線の各辺を長方形へ展開したものなので、岸沿いを
    // 走ると同じ「岸」が複数枚立つ。表示だけ集約し、件数で示す。
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'shore-a',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              timeUntilDanger: Duration(seconds: 8),
            ),
            NavigationWarning(
              key: 'shore-b',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              timeUntilDanger: Duration(seconds: 3),
            ),
            NavigationWarning(
              key: 'shore-c',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              timeUntilDanger: Duration(seconds: 9),
            ),
          ],
        ),
      ),
    );

    expect(find.text('岸'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    // 代表は最も到達が早い1件。
    expect(find.text('3秒'), findsOneWidget);
  });

  testWidgets('現在発生中の警告は、予測中の同種警告より優先して代表になる', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SafetyBanner(
          warnings: [
            NavigationWarning(
              key: 'shore-predicted',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
              timeUntilDanger: Duration(seconds: 2),
            ),
            NavigationWarning(
              key: 'shore-current',
              category: 'shore',
              title: '岸に接近',
              message: '',
              audioAsset: 'audio/shore_warning.mp3',
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
  });

  testWidgets('物理警告と別に通信・対応水域の能力低下を常時表示する', (tester) async {
    await tester.pumpWidget(
      wrap(
        const NavStatusCard(
          paceSeconds: 120,
          distanceMeters: 500,
          elapsedTimeSeconds: 60,
          positionSharingUnavailable: true,
          otherBoatReceiveUnavailable: true,
          operationalCoverageLimited: true,
        ),
      ),
    );

    expect(find.text('他艇受信: 利用不可'), findsOneWidget);
    expect(find.text('自艇共有: 利用不可'), findsOneWidget);
    expect(find.text('固定危険区域: 未検証水域'), findsOneWidget);
  });

  testWidgets('SPM計測OFFでは表示領域を完全に取り除く', (tester) async {
    await tester.pumpWidget(
      wrap(
        const NavStatusCard(
          paceSeconds: 120,
          distanceMeters: 500,
          elapsedTimeSeconds: 60,
          spmMeasurementEnabled: false,
        ),
      ),
    );

    expect(find.textContaining('SPM'), findsNothing);
    expect(find.text('--'), findsNothing);
  });

  testWidgets('横向き用カードは左上配置可能な幅で主要3指標を表示する', (tester) async {
    await tester.pumpWidget(
      wrap(
        const Align(
          alignment: Alignment.topLeft,
          child: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 500,
            elapsedTimeSeconds: 60,
            compact: true,
            spmMeasurementEnabled: false,
          ),
        ),
      ),
    );

    final card = find.byKey(const ValueKey('nav-status-card-compact'));
    expect(card, findsOneWidget);
    expect(tester.getSize(card).width, lessThanOrEqualTo(260));
    expect(tester.getSize(card).height, lessThan(120));
    expect(find.text('2:00'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('500 m'), findsOneWidget);
    expect(find.textContaining('spm'), findsNothing);
  });

  testWidgets('縦向き用カードはペース文字を保ち、SPMなしではさらに細くなる', (tester) async {
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      wrap(
        const Align(
          alignment: Alignment.topLeft,
          child: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 500,
            elapsedTimeSeconds: 60,
            portraitCompact: true,
            spmMeasurementEnabled: false,
          ),
        ),
      ),
    );

    final card = find.byKey(const ValueKey('nav-status-card-portrait-compact'));
    expect(tester.getSize(card).width, lessThanOrEqualTo(230));
    expect(tester.getSize(card).height, lessThan(120));
    expect(tester.widget<Text>(find.text('2:00')).style?.fontSize, 46);
    expect(find.textContaining('spm'), findsNothing);

    await tester.pumpWidget(
      wrap(
        const Align(
          alignment: Alignment.topLeft,
          child: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 500,
            elapsedTimeSeconds: 60,
            portraitCompact: true,
            spmMeasurementEnabled: true,
            spm: 18,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(card).width, greaterThan(230));
    expect(tester.getSize(card).width, lessThanOrEqualTo(268));
    expect(find.text('18 spm'), findsOneWidget);
  });

  testWidgets('SE相当・文字1.3倍でも計器と全能力低下表示が破綻しない', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: const Scaffold(
            body: NavStatusCard(
              paceSeconds: 599,
              distanceMeters: 12345,
              elapsedTimeSeconds: 3723,
              gpsAgeSeconds: 30,
              positionSharingUnavailable: true,
              otherBoatReceiveUnavailable: true,
              temporaryObstacleReceiveUnavailable: true,
              operationalCoverageLimited: true,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('他艇受信: 利用不可'), findsOneWidget);
    expect(find.text('自艇共有: 利用不可'), findsOneWidget);
    expect(find.text('臨時危険区域: 受信不可'), findsOneWidget);
    expect(find.text('固定危険区域: 未検証水域'), findsOneWidget);
    expect(find.textContaining('周囲を目視確認'), findsOneWidget);
  });

  testWidgets('経過時間の1秒更新を独立パネル内で行う', (tester) async {
    final startedAt = DateTime.now();
    var now = startedAt;
    await tester.pumpWidget(
      wrap(
        NavigationStatusPanel(
          paceSeconds: 120,
          distanceMeters: 500,
          sessionStartedAt: startedAt,
          lastGpsTimestamp: startedAt,
          clock: () => now,
        ),
      ),
    );

    expect(find.text('0:00'), findsOneWidget);
    now = startedAt.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:01'), findsOneWidget);
  });

  testWidgets('前回設定があればスクロールせずに開始できる近道を先頭へ出す', (tester) async {
    useNavigationSettingsViewport(tester);
    SharedPreferences.setMockInitialValues({
      'navigation_display_name_v1': '後藤',
      'navigation_boat_type_v1': BoatType.r_1x.name,
      'navigation_seat_position_v1': 1,
      'navigation_stroke_rate_enabled_v1': false,
    });

    String? submittedName;
    bool? submittedStrokeRate;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (displayName, strokeRateEnabled) async {
                submittedName = displayName;
                submittedStrokeRate = strokeRateEnabled;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('前回の設定'), findsOneWidget);
    expect(find.textContaining('後藤'), findsWidgets);

    // 近道はシート先頭にあるので、スクロールせずにそのまま押せる。
    await tester.tap(find.text('この設定で航行スタート'));
    await tester.pumpAndSettle();

    expect(submittedName, '後藤');
    // 保存済みのSPM設定(オフ)がそのまま引き継がれる。
    expect(submittedStrokeRate, isFalse);
  });

  testWidgets('前回設定がなければ近道は出さない', (tester) async {
    useNavigationSettingsViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(onPressStartNav: (_, __) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('前回の設定'), findsNothing);
    expect(find.text('この設定で航行スタート'), findsNothing);
    expect(find.text('航行スタート'), findsOneWidget);
  });

  testWidgets('航行設定シートは画面いっぱいに開かず、閉じて地図へ戻れる', (tester) async {
    // 全画面まで伸びると、閉じるために触れる場所が画面の最上端しか残らない。
    // そこからの下スワイプはOSの通知センターに取られ、戻れなくなる。
    useNavigationSettingsViewport(tester);
    const screenHeight = 1000.0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.8,
                  ),
                  builder: (_) =>
                      NavSettingModal(onPressStartNav: (_, __) async {}),
                ),
                child: const Text('航行スタート'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('航行スタート'));
    await tester.pumpAndSettle();
    expect(find.byType(NavSettingModal), findsOneWidget);

    // シートは画面の8割を超えない。上に2割の逃げ場が残る。
    final sheetHeight = tester.getSize(find.byType(NavSettingModal)).height;
    expect(sheetHeight, lessThanOrEqualTo(screenHeight * 0.8));
    expect(tester.getTopLeft(find.byType(NavSettingModal)).dy,
        greaterThanOrEqualTo(screenHeight * 0.2 - 1));

    // 明示的な出口がある。押せば地図へ戻る。
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();
    expect(find.byType(NavSettingModal), findsNothing);
    expect(find.text('航行スタート'), findsOneWidget);
  });

  testWidgets('航行開始前に音声確認ボタンを表示し、押せる', (tester) async {
    useNavigationSettingsViewport(tester);
    var tapped = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (_, __) async {},
              onPressTestAudio: () async {
                tapped = true;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('音声を確認する'), findsOneWidget);
    await tester.ensureVisible(find.text('音声を確認する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音声を確認する'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('名前が空のままでは航行開始できず、入力した名前を渡す', (tester) async {
    useNavigationSettingsViewport(tester);
    String? submittedName;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (displayName, _) async {
                submittedName = displayName;
              },
            ),
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.text('航行スタート'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('航行スタート'));
    await tester.pump();
    expect(find.text('名前を入力してください。'), findsOneWidget);
    expect(submittedName, isNull);

    await tester.enterText(find.widgetWithText(TextField, '名前'), '  後藤  ');
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('航行スタート'));
    await tester.pump();
    expect(submittedName, '後藤');
  });

  testWidgets('SPM(レート)計測は既定ONで航行開始へ渡せる', (tester) async {
    useNavigationSettingsViewport(tester);
    bool? submittedStrokeRateEnabled;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (_, strokeRateEnabled) async {
                submittedStrokeRateEnabled = strokeRateEnabled;
              },
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '名前'), '後藤');
    await tester.ensureVisible(find.text('SPM(レート)を計測する'));
    await tester.pumpAndSettle();
    expect(find.text('SPM(レート)計測'), findsOneWidget);
    expect(find.text('バッテリーが残り少ない場合はオフ推奨'), findsOneWidget);

    await tester.ensureVisible(find.text('航行スタート'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('航行スタート'));
    await tester.pump();
    expect(submittedStrokeRateEnabled, isTrue);
  });

  testWidgets('航行開始処理中の二重押しを無視する', (tester) async {
    useNavigationSettingsViewport(tester);
    final startCompleter = Completer<void>();
    var startCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (_, __) {
                startCount += 1;
                return startCompleter.future;
              },
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '名前'), '後藤');
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('航行スタート'));
    await tester.tap(find.text('航行スタート'));
    await tester.pump();

    expect(startCount, 1);
    expect(find.text('準備中…'), findsOneWidget);

    startCompleter.complete();
    await tester.pump();
    expect(find.text('航行スタート'), findsOneWidget);
  });

  testWidgets('Firebase初期化失敗を白画面にせず再試行できる', (tester) async {
    var attempts = 0;
    Future<void> initialize() async {
      attempts += 1;
      if (attempts == 1) throw StateError('test initialization failure');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseBootstrap(
          initialize: initialize,
          initializedChild: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('サービスを開始できませんでした'), findsOneWidget);
    await tester.tap(find.text('再試行'));
    await tester.pump();
    expect(attempts, 2);
  });

  testWidgets('App Check一時失敗でも端末内機能の起動を止めない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseBootstrap(
          initialize: () async {},
          activateAppCheck: () async {
            throw StateError('attestation unavailable');
          },
          initializedChild: const Text('端末内マップを開始'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('端末内マップを開始'), findsOneWidget);
    expect(find.text('サービスを開始できませんでした'), findsNothing);
  });
}
