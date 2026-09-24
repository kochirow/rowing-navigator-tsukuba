import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 練習記録リプレイ（表示専用）と安全経路の境界を機械的に守る。
///
/// 実装計画 docs/実装計画_2026-09-24_練習記録リプレイ.md §0-1:
/// - 記録画面の部品は、安全経路から import されない（記録画面の不具合が警告を汚さない）。
/// - 記録画面の純Dart部品は、読み取り専用のモデル・設定だけに依存する。
void main() {
  const recordDirs = ['lib/services/record/', 'lib/screens/record_replay/'];
  // 記録画面の部品を使ってよいのは、記録画面そのものと、その入口だけ。
  const allowedImporters = [
    'lib/services/record/',
    'lib/screens/record_replay/',
    'lib/screens/record_list_screen.dart',
  ];

  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String norm(String p) => p.replaceAll('\\', '/');

  test('安全経路を含むほかの lib ファイルは、記録画面の部品を import しない', () {
    final offenders = <String>[];
    for (final f in libFiles) {
      final path = norm(f.path);
      if (allowedImporters.any(path.startsWith)) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r"""^import\s+'([^']+)'""", multiLine: true)
          .allMatches(src)) {
        final target = m.group(1)!;
        if (target.contains('services/record/') ||
            target.contains('screens/record_replay/')) {
          offenders.add('$path -> $target');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('記録画面の純Dart部品は、安全経路の部品を import しない', () {
    // services/record が読んでよいのは、モデル・設定・同じ record 内・dart:/package:meta など。
    final allowed = RegExp(
        r"^(dart:|package:meta/|\.\./\.\./models/|\.\./\.\./config/|[a-z_]+\.dart$)");
    final offenders = <String>[];
    for (final f in libFiles) {
      final path = norm(f.path);
      if (!path.startsWith(recordDirs.first)) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r"""^import\s+'([^']+)'""", multiLine: true)
          .allMatches(src)) {
        final target = m.group(1)!;
        if (!allowed.hasMatch(target)) offenders.add('$path -> $target');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
