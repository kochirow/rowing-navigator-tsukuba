import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/utils/relative_direction.dart';

void main() {
  group('relativeDirectionLabel', () {
    test('進行方向と同じ方位は前方', () {
      expect(relativeDirectionLabel(0, 0), '前方');
      expect(relativeDirectionLabel(90, 90), '前方');
    });

    test('右45度は右前方', () {
      expect(relativeDirectionLabel(0, 45), '右前方');
    });

    test('右90度は右', () {
      expect(relativeDirectionLabel(0, 90), '右');
    });

    test('真後ろは後方', () {
      expect(relativeDirectionLabel(0, 180), '後方');
      expect(relativeDirectionLabel(90, -90), '後方');
    });

    test('左45度は左前方', () {
      expect(relativeDirectionLabel(0, -45), '左前方');
    });

    test('針路をまたぐ正規化(-180/180境界)', () {
      // 針路170度、対象方位-170度 → 相対+20度 → 前方
      expect(relativeDirectionLabel(170, -170), '前方');
    });
  });
  group('relativeBearingDegrees / relativeDirectionLabelOf', () {
    test('相対方位は -180〜180 に正規化され、正が右舷側', () {
      expect(relativeBearingDegrees(0, 90), closeTo(90, 1e-9));
      expect(relativeBearingDegrees(0, 270), closeTo(-90, 1e-9));
      expect(relativeBearingDegrees(350, 10), closeTo(20, 1e-9));
      expect(relativeBearingDegrees(10, 350), closeTo(-20, 1e-9));
    });

    test('相対方位からラベルを直接求められる', () {
      expect(relativeDirectionLabelOf(0), '前方');
      expect(relativeDirectionLabelOf(95), '右');
      expect(relativeDirectionLabelOf(-95), '左');
      expect(relativeDirectionLabelOf(180), '後方');
      expect(relativeDirectionLabelOf(-180), '後方');
    });

    test('方位が使えない値ならラベルを作らない', () {
      expect(relativeDirectionLabelOf(double.nan), '');
      expect(relativeDirectionLabelOf(double.infinity), '');
    });
  });
}
