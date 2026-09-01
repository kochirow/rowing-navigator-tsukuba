import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/reverse_guidance_audio_notice.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  testWidgets('逆走注意の音声がオフであることを常設表示する', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const Scaffold(body: ReverseGuidanceAudioNotice()),
    ));

    expect(find.byKey(const ValueKey('reverse-guidance-audio-off-notice')),
        findsOneWidget);
    expect(find.text('逆走注意の音声オフ'), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
  });
}
