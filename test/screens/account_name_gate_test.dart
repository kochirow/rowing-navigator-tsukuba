import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/team_model.dart';
import 'package:rowing_navigator/screens/app_entry_gate.dart';
import 'package:rowing_navigator/services/account_display_name_service.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const team = RowingTeam(
    id: 'team-a',
    name: '桜川',
    inviteCode: '23456789ABCD',
    createdBy: 'u1',
    adminUid: 'u1',
  );

  Future<List<String>> pumpGate(
    WidgetTester tester, {
    String? serverName,
    Future<void> Function(String name)? publish,
  }) async {
    final published = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AccountNameGate(
          membership: TeamMembership(
            team: team,
            userId: 'u1',
            displayName: serverName,
          ),
          service: AccountDisplayNameService(),
          publish: publish ?? (name) async => published.add(name),
          homeBuilder: (_) => const Scaffold(body: Text('地図')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return published;
  }

  testWidgets('名前が未登録なら地図の前に登録画面を出し、候補を入れておく', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.legacyNavigationNameKey: '後藤',
    });
    final published = await pumpGate(tester);

    expect(find.text('地図'), findsNothing);
    expect(find.text('あなたの名前を登録してください'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('account-display-name-field')),
    );
    expect(field.controller!.text, '後藤');

    await tester.tap(find.byKey(const ValueKey('account-display-name-submit')));
    await tester.pumpAndSettle();

    expect(find.text('地図'), findsOneWidget);
    expect(await AccountDisplayNameService().load(), '後藤');
    expect(published, ['後藤']);
  });

  testWidgets('空のまま登録しようとすると先へ進めない', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpGate(tester);

    await tester.tap(find.byKey(const ValueKey('account-display-name-submit')));
    await tester.pumpAndSettle();

    expect(find.text('名前を入力してください。'), findsOneWidget);
    expect(find.text('地図'), findsNothing);
  });

  testWidgets('登録済みなら登録画面を出さない', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.displayNameKey: '後藤',
    });
    await pumpGate(tester);

    expect(find.text('地図'), findsOneWidget);
  });

  testWidgets('メンバー情報に名前があれば登録画面を出さずに取り込む', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final published = await pumpGate(tester, serverName: '後藤');

    expect(find.text('地図'), findsOneWidget);
    expect(await AccountDisplayNameService().load(), '後藤');
    expect(published, isEmpty);
  });

  testWidgets('メンバー情報へ送れなくても地図へ進む', (tester) async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.displayNameKey: '後藤',
    });
    await pumpGate(
      tester,
      publish: (_) async => throw StateError('permission-denied'),
    );

    expect(find.text('地図'), findsOneWidget);
  });
}
