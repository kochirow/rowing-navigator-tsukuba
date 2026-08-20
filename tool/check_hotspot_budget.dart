import 'dart:convert';
import 'dart:io';

/// 肥大化が安全な変更を妨げないよう、現状値と停止上限を分けて監視する。
///
/// - recommended: 2026-08-20 時点の基準。超過しても警告だけでCIは通す。
/// - hard: 小さな変更の余地を含む停止上限。超過したらCIを失敗させる。
///
/// 切り出しで値が下がったときは recommended と hard も下げ、余白を
/// 使い直して元の大きさへ戻さない。上限の引き上げは、行数削減では解決
/// できない理由をPRへ明記する場合だけにする。
const hotspotBudgets = <HotspotBudget>[
  HotspotBudget(
    path: 'lib/hooks/use_navigator.dart',
    lines: MetricBudget(recommended: 5330, hard: 5600),
    imports: MetricBudget(recommended: 82, hard: 86),
    useRefs: MetricBudget(recommended: 107, hard: 112),
    useStates: MetricBudget(recommended: 46, hard: 49),
  ),
  HotspotBudget(
    path: 'lib/screens/home_map_screen.dart',
    lines: MetricBudget(recommended: 2175, hard: 2300),
    imports: MetricBudget(recommended: 71, hard: 75),
    useRefs: MetricBudget(recommended: 6, hard: 8),
    useStates: MetricBudget(recommended: 19, hard: 21),
  ),
];

class MetricBudget {
  final int recommended;
  final int hard;

  const MetricBudget({required this.recommended, required this.hard})
      : assert(recommended <= hard);
}

class HotspotBudget {
  final String path;
  final MetricBudget lines;
  final MetricBudget imports;
  final MetricBudget useRefs;
  final MetricBudget useStates;

  const HotspotBudget({
    required this.path,
    required this.lines,
    required this.imports,
    required this.useRefs,
    required this.useStates,
  });
}

class HotspotMetrics {
  final int lines;
  final int imports;
  final int useRefs;
  final int useStates;

  const HotspotMetrics({
    required this.lines,
    required this.imports,
    required this.useRefs,
    required this.useStates,
  });
}

class BudgetReport {
  final HotspotMetrics metrics;
  final List<String> warnings;
  final List<String> errors;

  const BudgetReport({
    required this.metrics,
    required this.warnings,
    required this.errors,
  });
}

HotspotMetrics measureHotspotSource(String source) {
  final lines =
      source.isEmpty ? 0 : const LineSplitter().convert(source).length;
  final code = _withoutCommentsAndStrings(source);
  return HotspotMetrics(
    lines: lines,
    imports: RegExp(r'^\s*import\s+', multiLine: true).allMatches(code).length,
    // 対象ファイルは dart format 済みであることをCIが別途保証する。
    // 型引数の有無と、代入の次行から始まる呼び出しの両方を数える。
    useRefs: RegExp(r'\buseRef(?:<[^;\n(]*>)?\s*\(').allMatches(code).length,
    useStates:
        RegExp(r'\buseState(?:<[^;\n(]*>)?\s*\(').allMatches(code).length,
  );
}

/// コメントや文字列に書かれた `useRef(` を実コードとして数えないための
/// 軽量スキャナ。改行は残し、importの行頭判定と総行数を安定させる。
String _withoutCommentsAndStrings(String source) {
  final output = StringBuffer();
  var index = 0;
  var blockCommentDepth = 0;

  bool startsWith(String value) => source.startsWith(value, index);

  while (index < source.length) {
    if (blockCommentDepth > 0) {
      if (startsWith('/*')) {
        blockCommentDepth++;
        output.write('  ');
        index += 2;
      } else if (startsWith('*/')) {
        blockCommentDepth--;
        output.write('  ');
        index += 2;
      } else {
        output.write(source[index] == '\n' ? '\n' : ' ');
        index++;
      }
      continue;
    }

    if (startsWith('//')) {
      while (index < source.length && source[index] != '\n') {
        output.write(' ');
        index++;
      }
      continue;
    }
    if (startsWith('/*')) {
      blockCommentDepth = 1;
      output.write('  ');
      index += 2;
      continue;
    }

    var raw = false;
    var quoteIndex = index;
    if ((source[index] == 'r' || source[index] == 'R') &&
        index + 1 < source.length &&
        (source[index + 1] == "'" || source[index + 1] == '"')) {
      raw = true;
      output.write(' ');
      quoteIndex++;
    }
    final quote = source[quoteIndex];
    if (quote != "'" && quote != '"') {
      output.write(source[index]);
      index++;
      continue;
    }

    final triple = source.startsWith('$quote$quote$quote', quoteIndex);
    final delimiter = triple ? '$quote$quote$quote' : quote;
    index = quoteIndex + delimiter.length;
    output.write(triple ? '   ' : ' ');
    while (index < source.length) {
      if (source.startsWith(delimiter, index)) {
        output.write(triple ? '   ' : ' ');
        index += delimiter.length;
        break;
      }
      if (!raw && source[index] == r'\' && index + 1 < source.length) {
        output.write('  ');
        index += 2;
        continue;
      }
      output.write(source[index] == '\n' ? '\n' : ' ');
      index++;
    }
  }

  return output.toString();
}

BudgetReport checkHotspotSource(String source, HotspotBudget budget) {
  final metrics = measureHotspotSource(source);
  final warnings = <String>[];
  final errors = <String>[];

  void check(String label, int actual, MetricBudget limit) {
    final detail = '$label=$actual (recommended=${limit.recommended}, '
        'hard=${limit.hard})';
    if (actual > limit.hard) {
      errors.add('$detail: 停止上限を超えています');
    } else if (actual > limit.recommended) {
      warnings.add('$detail: 基準値を超え、許容余白を使用しています');
    }
  }

  check('lines', metrics.lines, budget.lines);
  check('imports', metrics.imports, budget.imports);
  check('useRef', metrics.useRefs, budget.useRefs);
  check('useState', metrics.useStates, budget.useStates);

  return BudgetReport(
    metrics: metrics,
    warnings: warnings,
    errors: errors,
  );
}

void main(List<String> arguments) {
  final root = Directory(arguments.isEmpty ? '.' : arguments.single);
  var hasError = false;

  for (final budget in hotspotBudgets) {
    final file = File('${root.path}/${budget.path}');
    if (!file.existsSync()) {
      stderr.writeln('ERROR ${budget.path}: ファイルが見つかりません');
      hasError = true;
      continue;
    }

    final report = checkHotspotSource(file.readAsStringSync(), budget);
    stdout.writeln(
      '${budget.path}: lines=${report.metrics.lines}, '
      'imports=${report.metrics.imports}, useRef=${report.metrics.useRefs}, '
      'useState=${report.metrics.useStates}',
    );
    for (final warning in report.warnings) {
      stdout.writeln('::warning file=${budget.path}::$warning');
    }
    for (final error in report.errors) {
      stderr.writeln('::error file=${budget.path}::$error');
      hasError = true;
    }
  }

  if (hasError) {
    stderr.writeln(
      '巨大ファイルの停止上限を超えました。新しい責務を外へ出すか、'
      '上限変更の理由をPRに明記してください。',
    );
    exitCode = 1;
  }
}
