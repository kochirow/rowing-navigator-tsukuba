import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../models/practice_log_model.dart';
import '../../models/session_model.dart';
import '../../services/diagnostic_bundle_service.dart';
import '../../services/gpx_export_service.dart';
import '../../services/practice_log_store_service.dart';
import '../../services/session_end_prompt_policy.dart';
import '../../services/session_store_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/alert_category_label.dart';
import '../../widgets/practice_log_share_flow.dart';
import '../../widgets/session_diagnostic_share_flow.dart';
import '../../widgets/session_feedback_editor.dart';
import '../../widgets/share_origin.dart';

/// 練習・監視を終えたあと、地図の上に「今日の記録」シートを出す(R1)。
///
/// - 記録が確定した知らせ([SessionStoreService.finishedSessionIds] と
///   [PracticeLogStoreService.finishedLogIds])を受け、[ready](出艇前の姿勢)の
///   ときだけ出す。航行中・監視中には出さない(R1-R15)。
/// - 途切れた記録は、次回起動で確定されたときに同じ知らせが来て、出艇前の
///   地図が開いたときに出る(R1-R13)。途切れた監視ログもここで確定する(R1-R16)。
/// - 出す前に「出した」印を保存し、二度と出さない(R1-R12)。
/// - シートの表示・保存に失敗しても、地図・次の航行開始・警告は止めない。
void useSessionEndPrompt(
  BuildContext context, {
  required bool ready,
  SessionStoreService? sessionStore,
  PracticeLogStoreService? logStore,
}) {
  final sessions = useMemoized(() => sessionStore ?? SessionStoreService());
  final logs = useMemoized(() => logStore ?? PracticeLogStoreService());
  final mountedAt = useMemoized(DateTime.now);
  final pending = useRef(<_PromptTarget>[]);
  final showing = useRef(false);
  final readyRef = useRef(ready);
  readyRef.value = ready;
  final arrivals = useState(0);

  useEffect(() {
    void enqueue(_PromptTarget target) {
      if (pending.value.contains(target)) return;
      pending.value.add(target);
      arrivals.value++;
    }

    final sessionSubscription = SessionStoreService.finishedSessionIds
        .listen((id) => enqueue(_PromptTarget(id, isPracticeLog: false)));
    final logSubscription = PracticeLogStoreService.finishedLogIds
        .listen((id) => enqueue(_PromptTarget(id, isPracticeLog: true)));
    // 前回途切れた監視ログを確定する。確定したものは finishedLogIds で届く。
    unawaited(logs
        .recoverIncompleteLogs(startedBefore: mountedAt)
        .then((_) {}, onError: (_) {}));
    return () {
      unawaited(sessionSubscription.cancel());
      unawaited(logSubscription.cancel());
    };
  }, const []);

  useEffect(() {
    if (!ready || showing.value || pending.value.isEmpty) return null;
    showing.value = true;
    unawaited(() async {
      try {
        while (pending.value.isNotEmpty && readyRef.value) {
          if (!context.mounted) break;
          final target = pending.value.removeAt(0);
          try {
            if (target.isPracticeLog) {
              await _promptPracticeLog(context, target.id, logs);
            } else {
              await _promptSession(context, target.id, sessions);
            }
          } catch (error) {
            // 表示の失敗で地図や次の航行を止めない(R1-R15)。
            debugPrint('今日の記録シートを出せませんでした: $error');
          }
        }
      } finally {
        showing.value = false;
      }
    }());
    return null;
  }, [ready, arrivals.value]);
}

class _PromptTarget {
  final String id;
  final bool isPracticeLog;
  const _PromptTarget(this.id, {required this.isPracticeLog});

  @override
  bool operator ==(Object other) =>
      other is _PromptTarget &&
      other.id == id &&
      other.isPracticeLog == isPracticeLog;

  @override
  int get hashCode => Object.hash(id, isPracticeLog);
}

/// シートの間に記録を保存する窓口。保存は1本ずつ順に行い、後の保存が
/// 先の保存を古い内容で上書きしないようにする。
class SessionPromptController {
  SessionPromptController(this._session, this._store);

  Session _session;
  final SessionStoreService _store;
  Future<void> _queue = Future.value();
  Session get session => _session;
  SessionStoreService get store => _store;

  Future<void> update(Session Function(Session current) change) {
    _session = change(_session);
    final snapshot = _session;
    _queue = _queue.then((_) => _store.saveSession(snapshot)).catchError((_) {
      // 保存の失敗は次の保存で取り戻す。シートの操作は止めない。
    });
    return _queue;
  }

  /// 共有の流れが保存した記録(送信済みの印つき)を受け取る。
  void adopt(Session updated) => _session = updated;

  Future<void> flush() => _queue;
}

Future<void> _promptSession(
  BuildContext context,
  String id,
  SessionStoreService store,
) async {
  final loaded = await store.loadSession(id);
  if (loaded == null || !shouldPromptSessionEnd(loaded)) return;
  if (!context.mounted) return;
  final now = DateTime.now();
  final controller = SessionPromptController(loaded, store);
  // 出す前に印を保存する。途中でアプリが終わっても、二度と出さない。
  await controller.update((s) => s.copyWith(
        endPromptShownAt: now,
        diagnosticEvents: [
          ...s.diagnosticEvents,
          SessionDiagnosticEvent(
            sequence: _nextSequence(s),
            t: now,
            type: 'session_end_prompt_shown',
            details: {
              'recovered': s.wasRecoveredAfterTermination,
              'warningAudioCount': warningAudioCountsOf(s)
                  .values
                  .fold<int>(0, (sum, count) => sum + count),
            },
          ),
        ],
      ));
  if (!context.mounted) return;
  final action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => TodayRecordSheet(controller: controller),
      ) ??
      'dismissed';
  await controller.flush();
  final feedback = controller.session.userFeedback;
  await controller.update((s) => s.copyWith(diagnosticEvents: [
        ...s.diagnosticEvents,
        SessionDiagnosticEvent(
          sequence: _nextSequence(s),
          t: DateTime.now(),
          type: 'session_end_prompt_closed',
          details: {
            'action': action,
            'timingOffset': feedback?.timingOffset,
            'amountOffset': feedback?.amountOffset,
            'hasComment': feedback?.comment != null,
          },
        ),
      ]));
}

int _nextSequence(Session session) =>
    session.diagnosticEvents.fold<int>(
      0,
      (current, event) =>
          (event.sequence ?? 0) > current ? event.sequence! : current,
    ) +
    1;

/// 航行を終えたときの「今日の記録」シート(R1-R2・R1-R3)。
class TodayRecordSheet extends StatefulWidget {
  final SessionPromptController controller;
  final GpxExportService? exporter;

  const TodayRecordSheet({super.key, required this.controller, this.exporter});

  @override
  State<TodayRecordSheet> createState() => _TodayRecordSheetState();
}

class _TodayRecordSheetState extends State<TodayRecordSheet> {
  final _commentKey = GlobalKey<FeedbackCommentFieldState>();
  bool _sharing = false;

  Session get _session => widget.controller.session;

  void _setFeedback({
    int? Function()? timing,
    int? Function()? amount,
    String? Function()? comment,
  }) {
    final now = DateTime.now();
    setState(() {
      unawaited(widget.controller.update((s) {
        final base = s.userFeedback ?? SessionUserFeedback(updatedAt: now);
        return s.copyWith(
          userFeedback: () => base.copyWith(
            timingOffset: timing,
            amountOffset: amount,
            comment: comment,
            updatedAt: now,
          ),
        );
      }));
    });
  }

  Future<void> _share(Rect origin) async {
    _commentKey.currentState?.flush();
    await widget.controller.flush();
    if (!mounted) return;
    setState(() => _sharing = true);
    try {
      final updated = await shareSessionDiagnostics(
        context,
        session: widget.controller.session,
        exporter: widget.exporter ?? GpxExportService(),
        store: widget.controller.store,
        origin: origin,
      );
      if (updated != null) {
        widget.controller.adopt(updated);
        if (mounted) Navigator.of(context).pop('shared');
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final feedback = session.userFeedback;
    final counts = warningAudioCountsOf(session).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final distanceKm = session.summary.totalDistanceMeters / 1000;
    final minutes = (practiceSecOf(session) / 60).round();
    return _SheetFrame(
      title: '今日の練習',
      notice: session.wasRecoveredAfterTermination
          ? '前回の航行は終了ボタンを押さずに終わりました'
              '（${_hhmm(session.endedAt)} まで記録）'
          : null,
      content: [
        Text(
          '${distanceKm.toStringAsFixed(1)} km ・ $minutes分',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          counts.isEmpty
              ? '鳴った警告：なし'
              : '鳴った警告：${counts.map((e) => '${alertCategoryLabel(e.key)} ${e.value}').join('・')}',
          key: const Key('today-record-warning-counts'),
        ),
        const SizedBox(height: 16),
        FeedbackScaleSelector(
          scale: FeedbackScale.timing,
          value: feedback?.timingOffset,
          onChanged: (value) => _setFeedback(timing: () => value),
        ),
        const SizedBox(height: 12),
        FeedbackScaleSelector(
          scale: FeedbackScale.amount,
          value: feedback?.amountOffset,
          onChanged: (value) => _setFeedback(amount: () => value),
        ),
        const SizedBox(height: 12),
        FeedbackCommentField(
          key: _commentKey,
          initialValue: feedback?.comment,
          onChanged: (value) => _setFeedback(comment: () => value),
        ),
      ],
      sharing: _sharing,
      onShare: _share,
    );
  }
}

Future<void> _promptPracticeLog(
  BuildContext context,
  String id,
  PracticeLogStoreService store,
) async {
  final loaded = (await store.list()).where((log) => log.id == id).firstOrNull;
  if (loaded == null || !shouldPromptPracticeLogEnd(loaded)) return;
  if (!context.mounted) return;
  final now = DateTime.now();
  final shown =
      await store.updateMeta(id, (log) => log.copyWith(endPromptShownAt: now));
  if (shown == null || !context.mounted) return;
  await _appendPracticeEvent(store, shown, now, 'end_prompt_shown', {
    'recovered': shown.wasRecoveredAfterTermination,
  });
  if (!context.mounted) return;
  final action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ObserverRecordSheet(log: shown, store: store),
      ) ??
      'dismissed';
  await _appendPracticeEvent(
      store, shown, DateTime.now(), 'end_prompt_closed', {'action': action});
}

Future<void> _appendPracticeEvent(
  PracticeLogStoreService store,
  PracticeLog log,
  DateTime at,
  String type,
  Map<String, dynamic> details,
) async {
  try {
    await store.append(log.id, events: [
      PracticeLogEvent(
        t: at.toUtc(),
        elapsedMs: at.toUtc().difference(log.startedAt.toUtc()).inMilliseconds,
        type: type,
        details: details,
      ),
    ]);
  } catch (_) {/* 記録の失敗でシートを止めない */}
}

/// 監視を終えたときのシート。5段階は置かず、ひとことだけ(R1-R5)。
class ObserverRecordSheet extends StatefulWidget {
  final PracticeLog log;
  final PracticeLogStoreService store;

  const ObserverRecordSheet(
      {super.key, required this.log, required this.store});

  @override
  State<ObserverRecordSheet> createState() => _ObserverRecordSheetState();
}

class _ObserverRecordSheetState extends State<ObserverRecordSheet> {
  final _commentKey = GlobalKey<FeedbackCommentFieldState>();
  late PracticeLog _log = widget.log;
  Future<void> _queue = Future.value();
  bool _sharing = false;

  void _saveComment(String? comment) {
    final now = DateTime.now();
    _log = _log.copyWith(userComment: () => comment, userCommentUpdatedAt: now);
    _queue = _queue
        .then((_) => widget.store.updateMeta(
            _log.id,
            (log) => log.copyWith(
                userComment: () => comment, userCommentUpdatedAt: now)))
        .catchError((_) => null);
  }

  Future<void> _share(Rect origin) async {
    _commentKey.currentState?.flush();
    await _queue;
    if (!mounted) return;
    setState(() => _sharing = true);
    try {
      final shared = await sharePracticeLog(context,
          log: _log, origin: origin, store: widget.store);
      if (shared && mounted) Navigator.of(context).pop('shared');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final minutes = (practiceLogSecOf(_log) / 60).round();
    return _SheetFrame(
      title: '今日の監視',
      notice: _log.wasRecoveredAfterTermination && _log.endedAt != null
          ? '前回の監視は終了ボタンを押さずに終わりました'
              '（${_hhmm(_log.endedAt!)} まで記録）'
          : null,
      content: [
        Text('監視 $minutes分',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        FeedbackCommentField(
          key: _commentKey,
          initialValue: _log.userComment,
          hintText: '例：港の出口で他艇の警告が何度も鳴った',
          onChanged: _saveComment,
        ),
      ],
      sharing: _sharing,
      onShare: _share,
    );
  }
}

/// 2つのシートに共通の枠(つまみ・見出し・送る/あとで)。
class _SheetFrame extends StatelessWidget {
  final String title;
  final String? notice;
  final List<Widget> content;
  final bool sharing;
  final Future<void> Function(Rect origin) onShare;

  const _SheetFrame({
    required this.title,
    required this.notice,
    required this.content,
    required this.sharing,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Padding(
      // キーボードが出てもひとこと欄が隠れないようにする。
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Material(
          color: colors.canvas,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(dimens.radiusLg)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  dimens.space4, 0, dimens.space4, dimens.space3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: EdgeInsets.only(
                          top: dimens.space3, bottom: dimens.space3),
                      decoration: BoxDecoration(
                        color: colors.textDisabled,
                        borderRadius: dimens.borderSm,
                      ),
                    ),
                  ),
                  if (notice != null) ...[
                    Container(
                      padding: EdgeInsets.all(dimens.space2),
                      decoration: BoxDecoration(
                        color: colors.cautionSurface,
                        borderRadius: dimens.borderSm,
                      ),
                      child: Text(notice!,
                          key: const Key('today-record-recovered-notice')),
                    ),
                    SizedBox(height: dimens.space2),
                  ],
                  Semantics(
                    header: true,
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 8),
                  ...content,
                  const SizedBox(height: 16),
                  Builder(builder: (button) {
                    return FilledButton.icon(
                      key: const Key('today-record-send-log'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      icon: sharing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.outgoing_mail),
                      label: Text(sharing ? '作成中…' : 'ログを送る'),
                      onPressed: sharing
                          ? null
                          : () => unawaited(onShare(shareOriginOf(button))),
                    );
                  }),
                  TextButton(
                    key: const Key('today-record-later'),
                    style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: sharing
                        ? null
                        : () => Navigator.of(context).pop('later'),
                    child: const Text('あとで'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _hhmm(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
