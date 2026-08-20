import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/protocol_config.dart';

void main() {
  test('共有payloadの既定アプリ版はpubspecのプロダクト版と一致する', () {
    final versionLine = File('pubspec.yaml')
        .readAsLinesSync()
        .singleWhere((line) => line.startsWith('version: '));
    final pubspecProductVersion =
        versionLine.substring('version: '.length).split('+').first.trim();

    expect(currentPositionAppVersion, pubspecProductVersion);
    expect(currentPositionAppVersion, isNot(contains('+')));
  });

  test('端末のプロダクト版を優先し、build番号と空値を正規化する', () {
    expect(positionAppVersionFor('1.3.0'), '1.3.0');
    expect(positionAppVersionFor(' 1.3.0+99 '), '1.3.0');
    expect(positionAppVersionFor(''), currentPositionAppVersion);
    expect(positionAppVersionFor(null), currentPositionAppVersion);
  });
}
