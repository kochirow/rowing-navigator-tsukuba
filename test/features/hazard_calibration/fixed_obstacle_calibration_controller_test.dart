import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/features/hazard_calibration/bundled_hazard_card.dart';
import 'package:rowing_navigator/features/hazard_calibration/fixed_obstacle_calibration_controller.dart';
import 'package:rowing_navigator/features/hazard_calibration/fixed_obstacle_calibration_panel.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/session_model.dart';
import 'package:rowing_navigator/models/shared_safety_calibration.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/fixed_obstacle_calibration_service.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/session_store_service.dart';
import 'package:rowing_navigator/services/shared_safety_calibration_service.dart';
import 'package:rowing_navigator/widgets/fixed_obstacle_calibration_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _targets = [
  FixedObstacleCalibrationTarget(
    sourceId: 'bridge_a',
    name: '橋A',
    kind: StaticObstacleKind.bridge,
    sourcePoints: [LatLng(36, 140), LatLng(36.0001, 140)],
  ),
  FixedObstacleCalibrationTarget(
    sourceId: 'shore_b',
    name: '岸B',
    kind: StaticObstacleKind.shore,
    sourcePoints: [LatLng(36.001, 140.001), LatLng(36.0012, 140.001)],
  ),
];

class _FakePresets extends PresetObstacleService {
  int presetLoads = 0;
  @override
  Future<List<FixedObstacleCalibrationTarget>> loadCalibrationTargets() async =>
      _targets;
  @override
  Future<List<StaticObstacle>> loadPresets(
      {bool refreshManagedHazards = false}) async {
    presetLoads++;
    return const [];
  }
}

class _FakeShared extends SharedSafetyCalibrationService {
  bool conflict = false;
  int published = 0;
  @override
  Future<SharedSafetyCalibrationState?> loadCached() async =>
      SharedSafetyCalibrationState(revision: 3);
  @override
  Future<SharedSafetyCalibrationState?> fetchLatest(
          {bool forceServer = false}) async =>
      SharedSafetyCalibrationState(revision: conflict ? 5 : 3);
  @override
  Future<SharedSafetyCalibrationState> publishCalibrations({
    required Map<String, FixedObstacleCalibration> calibrations,
    required int expectedRevision,
  }) async {
    if (conflict) throw const SharedSafetyCalibrationConflictException();
    published++;
    // 実在しない区域IDは検証で弾かれるので、版だけを返す。
    return SharedSafetyCalibrationState(revision: expectedRevision + 1);
  }
}

class _NoSessions extends SessionStoreService {
  @override
  Future<List<Session>> listSessions() async => const [];
}

void main() {
  late List<String> messages;
  late _FakeShared shared;
  late _FakePresets presets;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messages = [];
    shared = _FakeShared();
    presets = _FakePresets();
  });

  FixedObstacleCalibrationController controller(
          {String? initial, bool member = true}) =>
      FixedObstacleCalibrationController(
        onMessage: messages.add,
        initialSourceId: initial,
        presetService: presets,
        calibrationService: FixedObstacleCalibrationService(),
        sessionStoreService: _NoSessions(),
        sharedCalibrationService: shared,
        isTeamMember: () => member,
      );

  test('押した同梱の区域を選んだ状態で始まる', () async {
    final c = controller(initial: 'shore_b');
    await c.load();
    expect(c.loading, isFalse);
    expect(c.selectedId, 'shore_b');
    expect(c.sharedRevision, 3);
    expect(c.hasUnpublishedChanges, isFalse);
  });

  test('対象にない区域なら、最初の対象から始める', () async {
    final c = controller(initial: 'unknown');
    await c.load();
    expect(c.selectedId, 'bridge_a');
  });

  test('座標点を選ばずに矢印を押すと知らせ、選べば0.5m動かして端末内に保存する', () async {
    final c = controller(initial: 'bridge_a');
    await c.load();
    await c.nudge(northDelta: 0.5);
    expect(messages.single, contains('座標点を選択'));
    expect(c.changed, isFalse);

    c.selectVertex(1);
    await c.nudge(northDelta: 0.5);
    expect(c.draft.vertexOffsetFor(1).northMeters, 0.5);
    expect(c.changed, isTrue);
    expect(c.hasUnpublishedChanges, isTrue);
    final saved = await FixedObstacleCalibrationService().loadAll();
    expect(saved['bridge_a']!.vertexOffsetFor(1).northMeters, 0.5);
  });

  test('公開すると「未公開の変更」が消え、版が上がる', () async {
    final c = controller(initial: 'bridge_a');
    await c.load();
    c.selectVertex(0);
    await c.nudge(eastDelta: 0.5);
    expect(c.publishItems().single.target.sourceId, 'bridge_a');

    await c.publishToTeam();
    expect(shared.published, 1);
    expect(c.publishMessage, contains('版 4'));
    expect(c.sharedRevision, 4);
    expect(c.hasUnpublishedChanges, isFalse);
    expect(c.publishStatus, FixedObstacleCalibrationPublishStatus.success);
  });

  test('先に他の端末が公開していたら、最新の版を取り直して再公開を促す', () async {
    final c = controller(initial: 'bridge_a');
    await c.load();
    c.selectVertex(0);
    await c.nudge(eastDelta: 0.5);
    shared.conflict = true;
    await c.publishToTeam();
    expect(c.publishStatus, FixedObstacleCalibrationPublishStatus.conflict);
    expect(c.sharedRevision, 5);
    expect(c.hasUnpublishedChanges, isTrue);
  });

  test('チームに入っていなければ公開しない', () async {
    final c = controller(initial: 'bridge_a', member: false);
    await c.load();
    await c.publishToTeam();
    expect(shared.published, 0);
  });

  test('すべて解除すると端末内の位置合わせが消える', () async {
    final c = controller(initial: 'bridge_a');
    await c.load();
    c.selectVertex(0);
    await c.nudge(eastDelta: 0.5);
    await c.resetAll();
    expect(c.calibrations, isEmpty);
    expect(c.draft.isZero, isTrue);
    expect(await FixedObstacleCalibrationService().loadAll(), isEmpty);
  });

  test('終えた後に保存が返ってきても例外にしない', () async {
    final c = controller(initial: 'bridge_a');
    final loading = c.load();
    c.dispose();
    await loading;
  });

  group('同梱の区域のカード', () {
    final obstacle = StaticObstacle(
      id: 'bridge_a_0',
      sourceId: 'bridge_a',
      name: '橋A',
      points: const [
        LatLng(36, 140),
        LatLng(36.0001, 140),
        LatLng(36, 140.0001)
      ],
      isDefault: true,
      kind: StaticObstacleKind.bridge,
    );

    testWidgets('出艇前なら「位置合わせを始める」を押せる', (tester) async {
      var started = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BundledHazardCard(
            obstacle: obstacle,
            blockedReason: null,
            onStartCalibration: () => started++,
            onClose: () {},
          ),
        ),
      ));
      expect(find.text('橋A'), findsOneWidget);
      expect(find.text('公開するとチーム全員に効く'), findsOneWidget);
      expect(find.byKey(const Key('calibration-blocked-reason')), findsNothing);
      await tester.tap(find.byKey(const Key('start-calibration')));
      expect(started, 1);
    });

    testWidgets('航行中・監視中はボタンを隠さず、押せない理由を出す', (tester) async {
      var started = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BundledHazardCard(
            obstacle: obstacle,
            blockedReason: '位置合わせは出艇前にできます。',
            onStartCalibration: () => started++,
            onClose: () {},
          ),
        ),
      ));
      expect(find.text('位置合わせは出艇前にできます。'), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('start-calibration')));
      expect(button.onPressed, isNull);
    });
  });

  group('位置合わせのパネル', () {
    Future<FixedObstacleCalibrationController> pumpPanel(WidgetTester tester,
        {bool member = true, void Function()? onFinish}) async {
      final c = controller(initial: 'bridge_a', member: member);
      await tester.runAsync(c.load);
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: c,
              builder: (_, __) => FixedObstacleCalibrationPanel(
                controller: c,
                onFinish: onFinish ?? () {},
              ),
            ),
          ),
        ),
      ));
      return c;
    }

    testWidgets('見出しに「公開するとチーム全員に効く」を出し、「終える」で戻れる', (tester) async {
      var finished = 0;
      await pumpPanel(tester, onFinish: () => finished++);
      expect(find.text('同梱の危険区域の位置合わせ'), findsOneWidget);
      expect(find.text('公開するとチーム全員に効く'), findsOneWidget);
      await tester.tap(find.byKey(const Key('calibration-finish')));
      expect(finished, 1);
    });

    testWidgets('チームに入っていなければ公開ボタンを出さない', (tester) async {
      await pumpPanel(tester, member: false);
      expect(find.textContaining('チームに参加すると公開できます'), findsOneWidget);
    });
  });
}
