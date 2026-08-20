import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_hotspot_budget.dart';

const _roomyBudget = HotspotBudget(
  path: 'sample.dart',
  lines: MetricBudget(recommended: 100, hard: 110),
  imports: MetricBudget(recommended: 10, hard: 11),
  useRefs: MetricBudget(recommended: 1, hard: 2),
  useStates: MetricBudget(recommended: 10, hard: 11),
);

void main() {
  test('コメント・文字列を除き、型引数と改行の有無によらずhook呼び出しを数える', () {
    const source = '''
import 'a.dart';
import 'b.dart';
// import 'commented.dart';

void example() {
  // useRef(99);
  final label = 'useState(false)';
  final first = useRef(0);
  final second =
      useRef<List<String>>([]);
  final enabled = useState(false);
  final selected =
      useState<String?>(null);
}
''';

    final metrics = measureHotspotSource(source);
    expect(metrics.lines, 14);
    expect(metrics.imports, 2);
    expect(metrics.useRefs, 2);
    expect(metrics.useStates, 2);
  });

  test('基準値超過は警告だけで、停止上限までは許容する', () {
    const source = '''
void example() {
  final first = useRef(0);
  final second = useRef(1);
}
''';

    final report = checkHotspotSource(source, _roomyBudget);
    expect(report.warnings, hasLength(1));
    expect(report.warnings.single, contains('許容余白'));
    expect(report.errors, isEmpty);
  });

  test('停止上限を超えた場合だけ失敗として報告する', () {
    const source = '''
void example() {
  final first = useRef(0);
  final second = useRef(1);
  final third = useRef(2);
}
''';

    final report = checkHotspotSource(source, _roomyBudget);
    expect(report.errors, hasLength(1));
    expect(report.errors.single, contains('停止上限'));
  });
}
