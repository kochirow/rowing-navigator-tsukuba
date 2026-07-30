import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_screen_wakelock.dart';
import 'package:rowing_navigator/types/nav_mode.dart';

class _FakeScreenWakelockPlatform implements ScreenWakelockPlatform {
  _FakeScreenWakelockPlatform();

  bool isEnabled = false;
  int enableCalls = 0;
  int disableCalls = 0;

  @override
  Future<bool> get enabled async => isEnabled;

  @override
  Future<void> disable() async {
    disableCalls += 1;
    isEnabled = false;
  }

  @override
  Future<void> enable() async {
    enableCalls += 1;
    isEnabled = true;
  }
}

void main() {
  test('常時点灯は航行中だけ必要で、監視中には要求しない', () {
    expect(shouldKeepScreenAwake(NavMode.navigator), isTrue);
    expect(shouldKeepScreenAwake(NavMode.observer), isFalse);
  });

  test('実状態を確認して必要な切替だけを行い診断へ残す', () async {
    final platform = _FakeScreenWakelockPlatform();
    final diagnostics = <Map<String, dynamic>>[];
    final controller = ScreenWakelockController(
      platform: platform,
      onDiagnostic: (_, details) => diagnostics.add(details),
    );

    await controller.apply(desired: true, reason: 'state_changed');
    await controller.apply(desired: true, reason: 'periodic_reassert');
    await controller.apply(desired: false, reason: 'dispose');

    expect(platform.enableCalls, 1);
    expect(platform.disableCalls, 1);
    expect(diagnostics, [
      {'desired': true, 'actual': true, 'reason': 'state_changed'},
      {'desired': true, 'actual': true, 'reason': 'periodic_reassert'},
      {'desired': false, 'actual': false, 'reason': 'dispose'},
    ]);
  });
}
