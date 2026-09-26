import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/edge_alert_overlay.dart';
import 'package:rowing_navigator/models/navigation_warning.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';

void main() {
  NavigationWarning warning(String category, double? bearing) =>
      NavigationWarning(
        key: 'a1',
        category: category,
        title: category,
        message: '',
        audioAsset: 'x.mp3',
        relativeBearingDegrees: bearing,
      );
  const directive = AudioDirective(
      alertId: 'a1', asset: 'x.mp3', mode: AudioDirectiveMode.loop);

  test('音が鳴っている衝突警告だけ、音の元の方角の縁を光らせる', () {
    // 艇の左前方(相対 -45°)= 漕手の右後ろ = 画面の右下へ。
    final alert = edgeAlertFor(
      directive: directive,
      warnings: [warning('other_boat', -45)],
      ashore: false,
    )!;
    expect(alert.screenAngleDegrees, 135);
    const size = Size(390, 844);
    final p = edgeAnchorFor(135, size, const Offset(195, 380));
    expect(p.dx, closeTo(390, 0.01), reason: '右の縁に当たる');
    expect(p.dy, greaterThan(380), reason: '自艇より下(後ろ)');

    // 方角が無い(方位が信頼できない)ときは向き不明。
    expect(
      edgeAlertFor(
        directive: directive,
        warnings: [warning('bridge', null)],
        ashore: false,
      )!
          .screenAngleDegrees,
      isNull,
    );
    // 案内(カーブ)・音なし・陸上判定中は光らせない。
    expect(
      edgeAlertFor(
          directive: directive, warnings: [warning('curve', 0)], ashore: false),
      isNull,
    );
    expect(
      edgeAlertFor(
          directive: null, warnings: [warning('other_boat', 0)], ashore: false),
      isNull,
    );
    expect(
      edgeAlertFor(
          directive: directive,
          warnings: [warning('other_boat', 0)],
          ashore: true),
      isNull,
    );
  });

  testWidgets('帯の長さより狭い画面でも、描画で例外を出さない', (tester) async {
    // 右の縁(縦の辺・高さ200)と下の縁(横の辺・幅200)の両方を描かせる。
    for (final angle in [90.0, 180.0]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: EdgeAlertOverlay(
                alert: EdgeAlert(
                  warning: warning('other_boat', 0),
                  screenAngleDegrees: angle,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '画面角 $angle°');
    }
    // 点滅のアニメーションを止めて終える。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
