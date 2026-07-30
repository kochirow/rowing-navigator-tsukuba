import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/widgets/map_control_button.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: Center(child: child)),
      );

  Material buttonMaterial(WidgetTester tester) {
    return tester.widget<Material>(
      find
          .descendant(
            of: find.byType(MapControlButton),
            matching: find.byType(Material),
          )
          .first,
    );
  }

  testWidgets('通常・選択状態の面色を区別する', (tester) async {
    await tester.pumpWidget(
      wrap(
        MapControlButton(
          icon: Icons.navigation,
          label: '追跡',
          onPressed: () {},
        ),
      ),
    );
    expect(buttonMaterial(tester).color, AppColors.light.mapControlSurface);

    await tester.pumpWidget(
      wrap(
        MapControlButton(
          icon: Icons.navigation,
          label: '追跡',
          active: true,
          onPressed: () {},
        ),
      ),
    );
    expect(buttonMaterial(tester).color, AppColors.light.primary);
  });

  testWidgets('無効状態はタップ処理を持たない', (tester) async {
    await tester.pumpWidget(
      wrap(
        const MapControlButton(
          icon: Icons.navigation,
          label: '追跡',
        ),
      ),
    );

    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
  });
}
