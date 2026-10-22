import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/account_display_name_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('未登録なら null。前の版で航行に使った名前を登録画面の候補にする', () async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.legacyNavigationNameKey: '後藤',
    });
    final service = AccountDisplayNameService();

    // 候補はあくまで候補。登録したことにはしない(初回の登録画面を出す)。
    expect(await service.resolve(), isNull);
    expect(await service.suggestion(), '後藤');
  });

  test('旧版の既定値「名前未設定」は候補にしない', () async {
    SharedPreferences.setMockInitialValues({
      AccountDisplayNameService.legacyNavigationNameKey: '名前未設定',
    });
    expect(await AccountDisplayNameService().suggestion(), isNull);
  });

  test('登録した名前は前後の空白を落として保存し、次の起動で読める', () async {
    final service = AccountDisplayNameService();
    expect(await service.save('  後藤 '), '後藤');
    expect(await AccountDisplayNameService().resolve(), '後藤');
  });

  test('不正な名前は保存しない', () async {
    final service = AccountDisplayNameService();
    expect(() => service.save('   '), throwsArgumentError);
    expect(() => service.save('あ' * 21), throwsArgumentError);
    expect(await service.load(), isNull);
  });

  test('端末内に無く、メンバー情報に名前があれば取り込む', () async {
    final service = AccountDisplayNameService();
    expect(await service.resolve(serverName: '後藤'), '後藤');
    expect(await service.load(), '後藤');
  });

  test('端末内の名前をメンバー情報より優先する', () async {
    final service = AccountDisplayNameService();
    await service.save('後藤');
    expect(await service.resolve(serverName: '古い名前'), '後藤');
  });

  group('メンバー情報への送信', () {
    test('違っていれば送り、送れた名前は二度送らない', () async {
      final service = AccountDisplayNameService();
      await service.save('後藤');
      final sent = <String>[];
      Future<void> publish(String name) async => sent.add(name);

      expect(
        await service.publishIfNeeded(
          userId: 'u1',
          serverName: null,
          publish: publish,
        ),
        isTrue,
      );
      await service.publishIfNeeded(
        userId: 'u1',
        serverName: null,
        publish: publish,
      );
      expect(sent, ['後藤']);
    });

    test('失敗しても例外を投げず、次の機会に送り直す', () async {
      final service = AccountDisplayNameService();
      await service.save('後藤');
      var attempts = 0;
      Future<void> failing(String name) async {
        attempts += 1;
        throw StateError('permission-denied');
      }

      expect(
        await service.publishIfNeeded(
          userId: 'u1',
          serverName: null,
          publish: failing,
        ),
        isFalse,
      );
      final sent = <String>[];
      await service.publishIfNeeded(
        userId: 'u1',
        serverName: null,
        publish: (name) async => sent.add(name),
      );
      expect(attempts, 1);
      expect(sent, ['後藤']);
    });

    test('名前を変えたら送り直す。同じ名前でも別のUIDなら送る', () async {
      final service = AccountDisplayNameService();
      final sent = <String>[];
      Future<void> publish(String name) async => sent.add(name);

      await service.save('後藤');
      await service.publishIfNeeded(
          userId: 'u1', serverName: null, publish: publish);
      await service.save('後藤 光正');
      await service.publishIfNeeded(
          userId: 'u1', serverName: '後藤', publish: publish);
      await service.publishIfNeeded(
          userId: 'u2', serverName: null, publish: publish);
      expect(sent, ['後藤', '後藤 光正', '後藤 光正']);
    });

    test('メンバー情報がすでに同じ名前なら送らない', () async {
      final service = AccountDisplayNameService();
      await service.save('後藤');
      final sent = <String>[];
      await service.publishIfNeeded(
        userId: 'u1',
        serverName: '後藤',
        publish: (name) async => sent.add(name),
      );
      expect(sent, isEmpty);
    });
  });
}
