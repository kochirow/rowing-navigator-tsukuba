import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/services/reverse_guidance_debouncer.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 29, 12);
  DateTime at(Duration offset) => t0.add(offset);

  test('5.9秒では確定せず、6.0秒で確定する', () {
    final debouncer = ReverseGuidanceDebouncer();

    expect(debouncer.update(isReverse: true, at: at(Duration.zero)), isFalse);
    expect(
      debouncer.update(
        isReverse: true,
        at: at(const Duration(milliseconds: 5900)),
      ),
      isFalse,
    );
    expect(
      debouncer.update(
        isReverse: true,
        at: at(const Duration(seconds: 6)),
      ),
      isTrue,
    );
    expect(reverseGuidanceConfirmSeconds, 6.0);
  });

  test('途中で逆走でなくなると確定待ちを即座にやり直す', () {
    final debouncer = ReverseGuidanceDebouncer();

    expect(debouncer.update(isReverse: true, at: at(Duration.zero)), isFalse);
    expect(
      debouncer.update(isReverse: true, at: at(const Duration(seconds: 5))),
      isFalse,
    );
    expect(
      debouncer.update(
        isReverse: false,
        at: at(const Duration(milliseconds: 5500)),
      ),
      isFalse,
    );
    expect(
      debouncer.update(isReverse: true, at: at(const Duration(seconds: 6))),
      isFalse,
    );
    expect(
      debouncer.update(isReverse: true, at: at(const Duration(seconds: 12))),
      isTrue,
    );
  });

  test('確定後も逆走でなくなれば即座に解除する', () {
    final debouncer = ReverseGuidanceDebouncer();

    debouncer.update(isReverse: true, at: at(Duration.zero));
    expect(
      debouncer.update(isReverse: true, at: at(const Duration(seconds: 6))),
      isTrue,
    );
    expect(
      debouncer.update(
        isReverse: false,
        at: at(const Duration(seconds: 7)),
      ),
      isFalse,
    );
  });
}
