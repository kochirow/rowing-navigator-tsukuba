import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/widgets/fixed_obstacle_calibration_controls.dart';

void main() {
  const targets = [
    FixedObstacleCalibrationTarget(
      sourceId: 'bridge_a',
      name: '橋A',
      kind: StaticObstacleKind.bridge,
      sourcePoints: [LatLng(36, 140)],
    ),
    FixedObstacleCalibrationTarget(
      sourceId: 'shore_b',
      name: '岸B',
      kind: StaticObstacleKind.shore,
      sourcePoints: [LatLng(36.001, 140.001)],
    ),
  ];

  group('FixedObstacleCalibrationLayoutSpec', () {
    test('横画面では地図の右側へ操作パネル分の余白を確保する', () {
      final layout = FixedObstacleCalibrationLayoutSpec.fromConstraints(
        const BoxConstraints.tightFor(width: 844, height: 390),
      );

      expect(layout.isLandscape, isTrue);
      expect(layout.panelWidth, closeTo(337.6, 0.001));
      expect(layout.mapPadding, EdgeInsets.only(right: layout.panelWidth));
    });

    test('小さい横画面でも操作パネルが画面幅を超えない', () {
      final layout = FixedObstacleCalibrationLayoutSpec.fromConstraints(
        const BoxConstraints.tightFor(width: 280, height: 200),
      );

      expect(layout.isLandscape, isTrue);
      expect(layout.panelWidth, 280);
      expect(layout.panelWidth, lessThanOrEqualTo(280));
    });

    test('縦画面では地図の下側へ操作パネル分の余白を確保する', () {
      final layout = FixedObstacleCalibrationLayoutSpec.fromConstraints(
        const BoxConstraints.tightFor(width: 390, height: 844),
      );

      expect(layout.isLandscape, isFalse);
      expect(layout.panelWidth, 390);
      expect(layout.portraitPanelHeight, 390);
      expect(
        layout.mapPadding,
        const EdgeInsets.only(bottom: 390),
      );
    });
  });

  testWidgets('地図側で選択が変わった場合もDropdownの選択表示を同期する', (tester) async {
    await tester.pumpWidget(
      _dropdownHarness(
        targets: targets,
        selectedId: 'bridge_a',
      ),
    );

    var dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.initialValue, 'bridge_a');
    expect(dropdown.key, const ValueKey('calibration-target-bridge_a'));

    await tester.pumpWidget(
      _dropdownHarness(
        targets: targets,
        selectedId: 'shore_b',
      ),
    );

    dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.initialValue, 'shore_b');
    expect(dropdown.key, const ValueKey('calibration-target-shore_b'));
  });

  testWidgets('保存中は対象Dropdownを操作できない', (tester) async {
    await tester.pumpWidget(
      _dropdownHarness(
        targets: targets,
        selectedId: 'bridge_a',
        saving: true,
      ),
    );

    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.onChanged, isNull);
  });

  testWidgets('保存中だけ画面離脱を止めて通知する', (tester) async {
    var blockedCount = 0;
    Widget buildGuard(bool saving) {
      return MaterialApp(
        home: FixedObstacleCalibrationSaveGuard(
          saving: saving,
          onBlockedPop: () => blockedCount++,
          child: const Scaffold(body: Text('校正画面')),
        ),
      );
    }

    await tester.pumpWidget(buildGuard(true));
    var popScope = tester.widget<PopScope<Object?>>(
      find.descendant(
        of: find.byType(FixedObstacleCalibrationSaveGuard),
        matching: find.byType(PopScope<Object?>),
      ),
    );
    expect(popScope.canPop, isFalse);
    popScope.onPopInvokedWithResult?.call(false, null);
    expect(blockedCount, 1);

    await tester.pumpWidget(buildGuard(false));
    popScope = tester.widget<PopScope<Object?>>(
      find.descendant(
        of: find.byType(FixedObstacleCalibrationSaveGuard),
        matching: find.byType(PopScope<Object?>),
      ),
    );
    expect(popScope.canPop, isTrue);
    popScope.onPopInvokedWithResult?.call(false, null);
    expect(blockedCount, 1);
  });

  testWidgets('公開前に障害物・移動量・補正前後・参照航行記録を確認できる', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(
          body: FixedObstacleCalibrationPublishConfirmation(
            items: [
              FixedObstacleCalibrationPublishItem(
                target: FixedObstacleCalibrationTarget(
                  sourceId: 'bridge_a',
                  name: '橋A',
                  kind: StaticObstacleKind.bridge,
                  sourcePoints: [LatLng(36, 140)],
                ),
                calibration: FixedObstacleCalibration(
                  northMeters: 1.5,
                  eastMeters: -0.5,
                ),
                beforeCenter: LatLng(36, 140),
                afterCenter: LatLng(36.000013, 139.999994),
              ),
            ],
            referenceSessionLabels: [
              '7/23 06:30・3.2km・上り',
              '7/23 07:15・3.1km・下り',
            ],
          ),
        ),
      ),
    );

    expect(find.text('橋｜橋A'), findsOneWidget);
    expect(find.text('北 +1.5m　東 -0.5m'), findsOneWidget);
    expect(find.text('36.000000, 140.000000'), findsOneWidget);
    expect(find.text('36.000013, 139.999994'), findsOneWidget);
    expect(find.text('・7/23 06:30・3.2km・上り'), findsOneWidget);
    expect(find.text('・7/23 07:15・3.1km・下り'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-publish-calibration-button')),
      findsOneWidget,
    );
  });

  testWidgets('公開中は公開ボタンを無効化し進行状況を表示する', (tester) async {
    var publishCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FixedObstacleCalibrationPublishPanel(
            status: FixedObstacleCalibrationPublishStatus.publishing,
            statusMessage: null,
            enabled: true,
            onPublish: () => publishCount++,
          ),
        ),
      ),
    );

    expect(find.text('チームへ公開しています…'), findsOneWidget);
    expect(find.text('公開中…'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('publish-calibration-button')),
    );
    expect(publishCount, 0);
  });

  testWidgets('チーム所属メンバーには公開ボタンを表示する', (tester) async {
    var publishCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FixedObstacleCalibrationPublishPanel(
            status: FixedObstacleCalibrationPublishStatus.idle,
            statusMessage: '共有確定版: 版 3。',
            enabled: true,
            onPublish: () => publishCount++,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('publish-calibration-button')),
    );
    expect(publishCount, 1);
  });

  testWidgets('チーム未所属では共有状態だけを表示して公開ボタンを隠す', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FixedObstacleCalibrationPublishPanel(
            status: FixedObstacleCalibrationPublishStatus.idle,
            statusMessage: '共有確定版: 版 0。チームに参加すると公開できます。',
            enabled: false,
            showPublishButton: false,
            onPublish: null,
          ),
        ),
      ),
    );

    expect(find.textContaining('チームに参加すると公開できます'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('publish-calibration-button')),
      findsNothing,
    );
  });

  testWidgets('競合と失敗をインライン表示し再試行できる', (tester) async {
    var publishCount = 0;
    Widget buildPanel(
      FixedObstacleCalibrationPublishStatus status,
      String message,
    ) {
      return MaterialApp(
        home: Scaffold(
          body: FixedObstacleCalibrationPublishPanel(
            status: status,
            statusMessage: message,
            enabled: true,
            onPublish: () => publishCount++,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildPanel(
      FixedObstacleCalibrationPublishStatus.conflict,
      '他の端末が先に更新しました。内容を確認して再公開してください。',
    ));
    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    expect(find.textContaining('他の端末が先に更新'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('publish-calibration-button')),
    );
    expect(publishCount, 1);

    await tester.pumpWidget(buildPanel(
      FixedObstacleCalibrationPublishStatus.failure,
      '公開できませんでした。通信を確認して再試行してください。',
    ));
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.textContaining('公開できませんでした'), findsOneWidget);
  });

  testWidgets('危険範囲の公開確認に各分類を表示し警告時間は共有しないと案内する', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DangerZoneSettingsPublishConfirmation(
            settings: DangerZoneSettings.defaults(),
          ),
        ),
      ),
    );

    expect(find.text('岸'), findsOneWidget);
    expect(find.text('橋'), findsOneWidget);
    expect(find.text('中州'), findsOneWidget);
    expect(find.text('固定流木'), findsOneWidget);
    expect(find.textContaining('警告開始時間は公開されず'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-publish-danger-zones-button')),
      findsOneWidget,
    );
  });
}

Widget _dropdownHarness({
  required List<FixedObstacleCalibrationTarget> targets,
  required String selectedId,
  bool saving = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: FixedObstacleCalibrationTargetDropdown(
        targets: targets,
        selectedId: selectedId,
        saving: saving,
        onChanged: (_) {},
      ),
    ),
  );
}
