import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../api/stroke_trace_api.dart';
import '../config/stroke_trace_config.dart';
import '../models/shared_stroke_trace.dart';

/// 何を送るかを決める純粋な判定。書込レートの上限をここだけで持つ。
///
/// database.rules.json 側にも同じ趣旨のレート制限があるが、規則で弾かれる
/// 前にクライアントで間引く。**規則違反の書込を出さない**ことが目的で、
/// 弾かれた書込を再送し続けると無駄な通信と permission-denied ログが残る。
class StrokeTracePublishPolicy {
  final Duration minimumInterval;
  DateTime? _lastPublishedAt;
  DateTime? _lastStrokeStartedAt;

  StrokeTracePublishPolicy({
    this.minimumInterval =
        const Duration(milliseconds: sharedStrokeTraceMinimumIntervalMs),
  });

  void reset() {
    _lastPublishedAt = null;
    _lastStrokeStartedAt = null;
  }

  /// 同じストロークの再送と、規則の下限を下回る連投を落とす。
  bool shouldPublish({
    required DateTime strokeStartedAt,
    required DateTime now,
  }) {
    final lastStroke = _lastStrokeStartedAt;
    if (lastStroke != null && !strokeStartedAt.isAfter(lastStroke)) return false;
    final lastPublished = _lastPublishedAt;
    if (lastPublished != null &&
        now.difference(lastPublished) < minimumInterval) {
      return false;
    }
    return true;
  }

  void markPublished({
    required DateTime strokeStartedAt,
    required DateTime now,
  }) {
    _lastStrokeStartedAt = strokeStartedAt;
    _lastPublishedAt = now;
  }
}

/// 艇速波形の共有(送信・購読)。
///
/// **安全経路ではない。** 送信の失敗は握り潰し、監視表示・警告・位置共有の
/// いずれも止めない(原則1)。呼出元はこの Future を待たない。
class StrokeTraceShareService {
  final StrokeTraceAPI _api;
  final StrokeTracePublishPolicy _policy;
  bool _removalArmed = false;
  String? _armedBoatId;

  StrokeTraceShareService({
    StrokeTraceAPI? api,
    StrokeTracePublishPolicy? policy,
  })  : _api = api ?? StrokeTraceAPI(),
        _policy = policy ?? StrokeTracePublishPolicy();

  /// 1ストロークぶんを送る。送ったら true。
  Future<bool> publish({
    required String boatId,
    required SharedStrokeTrace trace,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    if (!_policy.shouldPublish(
      strokeStartedAt: trace.strokeStartedAt,
      now: at,
    )) {
      return false;
    }
    try {
      if (!_removalArmed || _armedBoatId != boatId) {
        _armedBoatId = boatId;
        _removalArmed = true;
        // 失敗しても送信は続ける。残骸は受信側の鮮度判定で無視される。
        unawaited(_api.armRemoval(boatId).catchError((Object error) {
          _removalArmed = false;
          if (kDebugMode) debugPrint('Stroke trace onDisconnect failed: $error');
        }));
      }
      await _api.publish(
        boatId: boatId,
        trace: trace.toRtdbJson(serverUpdatedAt: ServerValue.timestamp),
      );
      _policy.markPublished(strokeStartedAt: trace.strokeStartedAt, now: at);
      return true;
    } catch (error) {
      if (kDebugMode) debugPrint('Stroke trace publish failed: $error');
      return false;
    }
  }

  /// 停止時の後片付け。失敗しても航行終了処理を止めない。
  Future<void> clear(String boatId) async {
    _policy.reset();
    _removalArmed = false;
    _armedBoatId = null;
    try {
      await _api.clear(boatId);
    } catch (error) {
      if (kDebugMode) debugPrint('Stroke trace clear failed: $error');
    }
  }

  /// 監視端末が**選んだ1艇だけ**を購読する。
  ///
  /// 検証を通らないレコードは null として流し、購読自体は続ける。
  /// 1件の壊れたデータで監視画面のグラフが二度と出なくなることを防ぐ。
  Stream<SharedStrokeTrace?> watch(String boatId) {
    return _api.boatRef(boatId).onValue.map((event) {
      final value = event.snapshot.value;
      if (value is! Map) return null;
      return SharedStrokeTrace.fromRtdbJson(Map<Object?, Object?>.from(value));
    });
  }
}
