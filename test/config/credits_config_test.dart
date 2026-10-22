import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/credits_config.dart';

void main() {
  test('音声クレジットは VOICEVOX の指定どおりの表記である', () {
    expect(voiceCredit, 'VOICEVOX:ずんだもん');
    expect(applicationLegalese, contains(voiceCredit));
  });

  test('原開発者のクレジットは NOTICE と一致し、ライセンス画面へ同梱される', () {
    final notice = File('NOTICE').readAsStringSync();
    expect(notice, contains(originalDeveloperCredit));
    expect(applicationLegalese, contains(originalDeveloperCredit));
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('    - NOTICE\n'));
    expect(pubspec, contains('    - LICENSE\n'));
  });
}
