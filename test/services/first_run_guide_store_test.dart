import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/first_run_guide_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = FirstRunGuideStore();

  test('初めての端末では1回だけ出す', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await store.shouldShow(), isTrue);

    await store.markSeen();
    expect(await store.shouldShow(), isFalse);
  });

  test('航行したことのある既存の端末には出さない', () async {
    SharedPreferences.setMockInitialValues({
      FirstRunGuideStore.existingUserKey: '後藤',
    });
    expect(await store.shouldShow(), isFalse);

    // 表示済みとして覚え、名前を消しても出さない。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FirstRunGuideStore.seenKey), isTrue);
  });

  test('既存利用者の判定キーは航行設定の名前の保存キーと一致する', () {
    // NavigationDefaultsService のキー名が変わると、既存の利用者にも案内が出る。
    expect(FirstRunGuideStore.existingUserKey, 'navigation_display_name_v1');
  });
}
