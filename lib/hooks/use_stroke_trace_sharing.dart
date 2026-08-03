import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../models/shared_stroke_trace.dart';
import '../services/stroke_trace_share_service.dart';

/// 1ストロークの艇速波形を監視端末へ共有するフック。
///
/// **安全経路から完全に切り離してある。** ここで何が起きても、位置共有・
/// 衝突警告・GPS処理には触れない。送信は待たず、失敗も握り潰す(原則1)。
///
/// 送信頻度は1ストローク(約2〜3秒)に1回。位置共有と違い、購読するのは
/// 監視端末が開いた1艇だけなので、fan-outは起きない。
void useStrokeTraceSharing({
  required bool enabled,
  required String? boatId,
  required ValueNotifier<SharedStrokeTrace?> trace,
  void Function(String type, Map<String, dynamic> details)? onDiagnosticEvent,
  StrokeTraceShareService? service,
}) {
  final shareService =
      useMemoized(() => service ?? StrokeTraceShareService(), [service]);
  final published = useRef(0);
  final failed = useRef(0);
  final lastReportAt = useRef<DateTime?>(null);

  useEffect(() {
    if (!enabled || boatId == null || boatId.isEmpty) return null;

    void report() {
      final now = DateTime.now();
      final last = lastReportAt.value;
      if (last != null && now.difference(last) < const Duration(seconds: 60)) {
        return;
      }
      lastReportAt.value = now;
      onDiagnosticEvent?.call('stroke_trace_share', {
        'published': published.value,
        'failed': failed.value,
      });
    }

    void onTrace() {
      final value = trace.value;
      if (value == null) return;
      unawaited(shareService
          .publish(boatId: boatId, trace: value)
          .then((sent) {
            if (sent) published.value++;
            report();
          })
          .catchError((Object _) {
            failed.value++;
            report();
          }));
    }

    trace.addListener(onTrace);
    onTrace();
    return () {
      trace.removeListener(onTrace);
      // 共有をやめたら、監視端末に古い波形を残さない。
      unawaited(shareService.clear(boatId));
    };
  }, [enabled, boatId, trace, shareService]);
}
