import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/map_style_config.dart';

void main() {
  test('自動再センタリング時間は2〜10秒の範囲にある', () {
    expect(isValidMapAutoRecenterDelay(mapAutoRecenterDelay), isTrue);
    expect(
      isValidMapAutoRecenterDelay(const Duration(seconds: 1)),
      isFalse,
    );
    expect(
      isValidMapAutoRecenterDelay(const Duration(seconds: 11)),
      isFalse,
    );
  });
}
