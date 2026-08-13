import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/log_config.dart';

final _diagnosticCallPattern = RegExp(
  r'\b(appendRuntimeDiagnostic|queuePreSessionDiagnostic|emitDiagnostic|onDiagnostic|onDiagnosticEvent)'
  r'(?:\?\.call)?\s*\(',
);
final _eventConstructorPattern = RegExp(r'\bSessionDiagnosticEvent\s*\(');
final _eventNamePattern = RegExp(r'^[a-z][a-z0-9_]*$');
final _quotedStringPattern = RegExp(r"(?:r)?'((?:\\.|[^'\\])*)'");

void main() {
  test('catalog entries have valid names and useful descriptions', () {
    final catalog =
        diagnosticEventCatalog['eventTypes']! as Map<String, dynamic>;
    for (final entry in catalog.entries) {
      expect(
        entry.key,
        matches(_eventNamePattern),
        reason: 'Event names must remain machine-readable snake_case.',
      );
      expect(
        entry.value,
        isA<String>().having(
          (value) => value.trim().length,
          'description length',
          greaterThanOrEqualTo(10),
        ),
        reason: '${entry.key} needs a useful description for offline review.',
      );
    }
  });

  test('all statically emitted diagnostic events are documented', () {
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList(growable: false);
    final emitted = <String>{};
    final unresolved = <String>[];
    final forwardingExpressions = <String, int>{};

    for (final file in sources) {
      final source = file.readAsStringSync();
      final codeOffsets = _codeOffsets(source);

      for (final match in _diagnosticCallPattern.allMatches(source)) {
        if (!codeOffsets[match.start]) continue;
        final expression = _firstArgument(source, match.end - 1);
        final forwardingKind = _diagnosticForwardingKind(expression);
        if (forwardingKind != null) {
          forwardingExpressions.update(
            forwardingKind,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          continue;
        }
        final names = _eventNamesIn(expression);
        if (names.isEmpty) {
          unresolved.add(
            '${file.path}:${_lineNumber(source, match.start)} '
            '${match.group(1)}($expression)',
          );
        }
        emitted.addAll(names);
      }

      for (final match in _eventConstructorPattern.allMatches(source)) {
        if (!codeOffsets[match.start]) continue;
        final arguments = _parenthesizedContents(source, match.end - 1);
        // The class' generative constructor declaration starts with `{`.
        if (arguments.trimLeft().startsWith('{')) continue;
        final typeExpression = _namedArgument(arguments, 'type');
        if (typeExpression == null) {
          unresolved.add(
            '${file.path}:${_lineNumber(source, match.start)} '
            'SessionDiagnosticEvent without type',
          );
          continue;
        }
        final forwardingKind = _diagnosticForwardingKind(typeExpression);
        if (forwardingKind != null) {
          forwardingExpressions.update(
            forwardingKind,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          continue;
        }
        final names = _eventNamesIn(typeExpression);
        if (names.isEmpty) {
          unresolved.add(
            '${file.path}:${_lineNumber(source, match.start)} '
            'SessionDiagnosticEvent(type: $typeExpression)',
          );
        }
        emitted.addAll(names);
      }
    }

    expect(
      unresolved,
      isEmpty,
      reason: 'A diagnostic emitter could not be resolved statically. '
          'Use a literal/conditional event name, or move the event name into '
          'a typed registry before adding it to the intentional forwarders.',
    );
    expect(
      forwardingExpressions,
      <String, int>{
        // appendRuntimeDiagnostic / queuePreSessionDiagnostic / emitter API.
        'emitter declaration': 3,
        // appendRuntimeDiagnostic / audio callback / pre-session queue.
        'runtime forwarding': 3,
        'JSON deserialization': 1,
      },
      reason: 'Dynamic event names are allowed only at the audited forwarding '
          'and deserialization boundaries. A changed count requires review.',
    );

    final catalog =
        (diagnosticEventCatalog['eventTypes']! as Map<String, dynamic>).keys;
    final missing = emitted.difference(catalog.toSet()).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'Every event that can reach events.jsonl must have a catalog '
          'description. Missing: ${missing.join(', ')}',
    );
  });
}

/// Dynamic names are allowed only in the two functions that forward an event
/// emitted elsewhere. Any other expression is treated as an extraction gap.
String? _diagnosticForwardingKind(String expression) {
  final normalized = expression.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized == 'String type') return 'emitter declaration';
  if (normalized == 'type') return 'runtime forwarding';
  if (normalized.contains("json['type']")) return 'JSON deserialization';
  return null;
}

Set<String> _eventNamesIn(String expression) => _quotedStringPattern
    .allMatches(expression)
    .map((match) => match.group(1)!)
    .where(_eventNamePattern.hasMatch)
    .toSet();

String _firstArgument(String source, int openParen) {
  final contents = _parenthesizedContents(source, openParen);
  return _splitTopLevel(contents).first.trim();
}

String? _namedArgument(String arguments, String name) {
  for (final argument in _splitTopLevel(arguments)) {
    final separator = _topLevelColon(argument);
    if (separator < 0) continue;
    if (argument.substring(0, separator).trim() == name) {
      return argument.substring(separator + 1).trim();
    }
  }
  return null;
}

int _topLevelColon(String source) {
  final parts = _topLevelDelimiters(source, <int>{58});
  return parts.isEmpty ? -1 : parts.first;
}

List<String> _splitTopLevel(String source) {
  final commas = _topLevelDelimiters(source, <int>{44});
  final result = <String>[];
  var start = 0;
  for (final comma in commas) {
    result.add(source.substring(start, comma));
    start = comma + 1;
  }
  result.add(source.substring(start));
  return result;
}

List<int> _topLevelDelimiters(String source, Set<int> delimiters) {
  final result = <int>[];
  var round = 0;
  var square = 0;
  var curly = 0;
  var quote = 0;
  var escaped = false;
  for (var index = 0; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (quote != 0) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == quote) {
        quote = 0;
      }
      continue;
    }
    if (char == 39 || char == 34) {
      quote = char;
      continue;
    }
    switch (char) {
      case 40:
        round += 1;
      case 41:
        round -= 1;
      case 91:
        square += 1;
      case 93:
        square -= 1;
      case 123:
        curly += 1;
      case 125:
        curly -= 1;
      default:
        if (round == 0 &&
            square == 0 &&
            curly == 0 &&
            delimiters.contains(char)) {
          result.add(index);
        }
    }
  }
  return result;
}

String _parenthesizedContents(String source, int openParen) {
  var depth = 1;
  var quote = 0;
  var escaped = false;
  for (var index = openParen + 1; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (quote != 0) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == quote) {
        quote = 0;
      }
      continue;
    }
    if (char == 39 || char == 34) {
      quote = char;
    } else if (char == 40) {
      depth += 1;
    } else if (char == 41) {
      depth -= 1;
      if (depth == 0) return source.substring(openParen + 1, index);
    }
  }
  throw FormatException('Unclosed parenthesis at offset $openParen');
}

List<bool> _codeOffsets(String source) {
  final result = List<bool>.filled(source.length, true);
  var index = 0;
  while (index < source.length) {
    final char = source.codeUnitAt(index);
    final next = index + 1 < source.length ? source.codeUnitAt(index + 1) : 0;
    if (char == 47 && next == 47) {
      while (index < source.length && source.codeUnitAt(index) != 10) {
        result[index++] = false;
      }
      continue;
    }
    if (char == 47 && next == 42) {
      result[index++] = false;
      result[index++] = false;
      while (index + 1 < source.length &&
          !(source.codeUnitAt(index) == 42 &&
              source.codeUnitAt(index + 1) == 47)) {
        result[index++] = false;
      }
      if (index < source.length) result[index++] = false;
      if (index < source.length) result[index++] = false;
      continue;
    }
    if (char == 39 || char == 34) {
      final quote = char;
      result[index++] = false;
      var escaped = false;
      while (index < source.length) {
        final current = source.codeUnitAt(index);
        result[index++] = false;
        if (escaped) {
          escaped = false;
        } else if (current == 92) {
          escaped = true;
        } else if (current == quote) {
          break;
        }
      }
      continue;
    }
    index += 1;
  }
  return result;
}

int _lineNumber(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;
