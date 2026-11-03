import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/log_export_config.dart';
import '../models/session_feedback.dart';

/// 「真ん中＝ちょうどよい」の5段階の選択(R1-3)。
///
/// 5つのボタンを横に並べ、選んだものだけを強調する。選んだボタンをもう一度
/// 押すと未選択(null)に戻る。真ん中は少し幅を広げて「ちょうど」と書く。
class FeedbackScaleSelector extends StatelessWidget {
  final FeedbackScale scale;
  final int? value;
  final ValueChanged<int?> onChanged;
  final Color? labelColor;

  const FeedbackScaleSelector({
    super.key,
    required this.scale,
    required this.value,
    required this.onChanged,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${scale.title}（任意）',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: labelColor ?? scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final offset in const [-2, -1, 0, 1, 2])
              Expanded(
                flex: offset == 0 ? 5 : 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _ScaleButton(
                    key: Key('feedback-${scale.name}-$offset'),
                    label: scale.buttonLabelFor(offset),
                    semanticsLabel: '${scale.title}：${scale.labelFor(offset)}',
                    selected: value == offset,
                    onTap: () => onChanged(value == offset ? null : offset),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ScaleButton extends StatelessWidget {
  final String label;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onTap;

  const _ScaleButton({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      excludeSemantics: true,
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            // 指で押しやすい高さ(48)を確保する。
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「ひとこと」の入力欄。入力が止まって1秒後と、閉じるときに [onChanged] を呼ぶ
/// (R1-R6)。空にすると null を渡す。
class FeedbackCommentField extends StatefulWidget {
  final String? initialValue;
  final ValueChanged<String?> onChanged;
  final String hintText;
  final Color? labelColor;

  const FeedbackCommentField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.hintText = '例：港を出るまでずっと鳴っていた（どこで・いつ頃も書くと助かります）',
    this.labelColor,
  });

  @override
  State<FeedbackCommentField> createState() => FeedbackCommentFieldState();
}

/// 送る直前など、待たずに入力を確定したいときは [flush] を呼ぶ。
class FeedbackCommentFieldState extends State<FeedbackCommentField> {
  static const _debounce = Duration(seconds: 1);
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue ?? '');
  Timer? _timer;
  String? _lastSent;

  @override
  void initState() {
    super.initState();
    _lastSent = normalizeFeedbackComment(widget.initialValue);
  }

  void _schedule(String _) {
    _timer?.cancel();
    _timer = Timer(_debounce, _flush);
  }

  /// 入力中のひとことをすぐに確定する(変わっていなければ何もしない)。
  void flush() => _flush();

  void _flush() {
    _timer?.cancel();
    _timer = null;
    final value = normalizeFeedbackComment(_controller.text);
    if (value == _lastSent) return;
    _lastSent = value;
    widget.onChanged(value);
  }

  @override
  void dispose() {
    // 閉じる時点の入力も失わない(R1-R6)。
    _flush();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'ひとこと（任意）',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: widget.labelColor ?? scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('feedback-comment'),
          controller: _controller,
          minLines: 2,
          maxLines: 4,
          maxLength: userFeedbackCommentMaxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          textInputAction: TextInputAction.done,
          onChanged: _schedule,
          onEditingComplete: () {
            _flush();
            FocusScope.of(context).unfocus();
          },
          onTapOutside: (_) => FocusScope.of(context).unfocus(),
          decoration: InputDecoration(
            hintText: widget.hintText,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}
