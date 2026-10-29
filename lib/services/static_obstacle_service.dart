import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/api/static_obstacle_api.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

import '../utils/geo_math.dart';
import 'firebase_usage_budget.dart';

class StaticObstacleService {
  static const collectionName = StaticObstacleAPI.collectionName;
  static const maxTemporaryObstaclePoints = 200;
  static const defaultTemporaryRadiusMeters = 5.0;
  static const minTemporaryRadiusMeters = 1.0;
  static const maxTemporaryRadiusMeters = 100.0;
  static const circlePointCount = 24;

  /// 削除の印を付けてから、元に戻せる期間。Rules の7日と一致させる。
  static const softDeleteRetention = Duration(days: 7);
  final StaticObstacleAPI staticObstacleRef;

  StaticObstacleService({String? teamId})
      : staticObstacleRef = StaticObstacleAPI(teamId: teamId);

  Stream<Map<String, dynamic>> getStaticObstaclesStream() {
    late StreamController<Map<String, dynamic>> controller;
    StreamSubscription? subscription;
    QuerySnapshot<Map<String, dynamic>>? latestSnapshot;

    void emitLatest() {
      final snapshot = latestSnapshot;
      if (snapshot != null && !controller.isClosed) {
        controller.add(_parseTemporaryObstacles(snapshot));
      }
    }

    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        subscription = staticObstacleRef.collection
            .limit(FirebaseUsageBudget.maxTemporaryObstaclesPerSync)
            .snapshots()
            .listen(
          (snapshot) {
            latestSnapshot = snapshot;
            emitLatest();
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// 通常の地図表示へ戻った直後など、購読を維持しない場面で臨時危険区域を
  /// 1回だけ取得する。
  ///
  /// 航行・監視中は[getStaticObstaclesStream]のlistenerが更新を受けるため、
  /// この取得をGPS処理や定期timerから呼ばない。
  Future<Map<String, dynamic>> fetchCurrentTemporaryObstacles() async {
    final snapshot = await staticObstacleRef.collection
        .limit(FirebaseUsageBudget.maxTemporaryObstaclesPerSync)
        .get();
    return _parseTemporaryObstacles(snapshot);
  }

  Map<String, dynamic> _parseTemporaryObstacles(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final List<StaticObstacle> obstacles = [];
    final List<DeletedTemporaryObstacle> deleted = [];
    for (final doc in snapshot.docs) {
      // 1件の不正な危険区域データで全体の受信を止めない。
      try {
        final data = doc.data();
        final removed = parseDeletedTemporaryObstacle(doc.id, data);
        if (removed != null) {
          deleted.add(removed);
          continue;
        }
        final obstacle = parseTemporaryObstacle(doc.id, data);
        if (obstacle != null) obstacles.add(obstacle);
      } catch (e) {
        debugPrint('Invalid static obstacle ignored: ${doc.id} $e');
      }
    }
    deleted.sort((a, b) =>
        (b.deletedAt ?? DateTime(0)).compareTo(a.deletedAt ?? DateTime(0)));
    // 削除済みも同じ上限の枠を使うので、上限に達したら有効な区域を
    // 読み落としている可能性がある。黙って続けず、呼出側が受信不良として
    // 示せるようにする(2026-10-29 監査 F01)。
    final truncated = snapshot.docs.length >=
        FirebaseUsageBudget.maxTemporaryObstaclesPerSync;
    return {'obstacles': obstacles, 'deleted': deleted, 'truncated': truncated};
  }

  /// 削除の印(`deletedAt`)が付いた文書かどうか。
  static bool isSoftDeleted(Map<String, dynamic> data) =>
      data.containsKey('deletedAt');

  /// 有効な臨時危険区域を1件読む。削除済み・形が不正なら null。
  ///
  /// **削除の印が付いたものは警告にも地図にも出さない。** 印を付けた時点で
  /// 従来の削除と同じ扱いになり、違いは「元に戻せる」ことだけである。
  static StaticObstacle? parseTemporaryObstacle(
    String id,
    Map<String, dynamic> obstacle,
  ) {
    if (isSoftDeleted(obstacle)) return null;
    final rawPoints = obstacle['points'];
    if (rawPoints is! List ||
        rawPoints.length < 3 ||
        rawPoints.length > maxTemporaryObstaclePoints) {
      return null;
    }
    final points = rawPoints
        .whereType<GeoPoint>()
        .map<LatLng>((point) => LatLng(point.latitude, point.longitude))
        .toList();
    if (points.length != rawPoints.length) return null;
    final rawCenter = obstacle['center'];
    final rawRadius = obstacle['radiusMeters'];
    final center = rawCenter is GeoPoint
        ? LatLng(rawCenter.latitude, rawCenter.longitude)
        : null;
    final radius =
        rawRadius is num && rawRadius.isFinite ? rawRadius.toDouble() : null;
    return StaticObstacle(
      id: id,
      name: obstacle['name'] as String?,
      points: points,
      kind: StaticObstacleKind.fromJson(obstacle['kind'] as String?),
      warningAudioAsset: obstacle['warningAudio'] as String?,
      isTemporary: true,
      circleCenter: center,
      circleRadiusMeters: radius,
    );
  }

  /// 削除の印が付いた臨時危険区域を1件読む(元に戻す一覧用)。
  static DeletedTemporaryObstacle? parseDeletedTemporaryObstacle(
    String id,
    Map<String, dynamic> data,
  ) {
    if (!isSoftDeleted(data)) return null;
    final rawDeletedAt = data['deletedAt'];
    final rawCenter = data['center'];
    final rawRadius = data['radiusMeters'];
    return DeletedTemporaryObstacle(
      id: id,
      name: data['name'] as String? ?? '臨時危険区域',
      deletedAt: rawDeletedAt is Timestamp ? rawDeletedAt.toDate() : null,
      deletedBy: data['deletedBy'] as String?,
      center: rawCenter is GeoPoint
          ? LatLng(rawCenter.latitude, rawCenter.longitude)
          : null,
      radiusMeters:
          rawRadius is num && rawRadius.isFinite ? rawRadius.toDouble() : null,
    );
  }

  Future<void> addStaticObstacle(StaticObstacle obstacle) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('臨時危険区域の登録にはログインが必要です。');
    }
    if (obstacle.points.length < 3 ||
        obstacle.points.length > maxTemporaryObstaclePoints) {
      throw ArgumentError.value(
        obstacle.points.length,
        'points',
        'must contain 3-$maxTemporaryObstaclePoints points',
      );
    }
    await staticObstacleRef.collection.doc().set({
      ...obstacle.toJson(),
      'createdBy': user.uid,
      'source': 'user_confirmed',
      'createdAt': FieldValue.serverTimestamp(),
      'confirmedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    });
    debugPrint("Completed addStaticObstacle");
  }

  List<LatLng> createCirclePoints(
    LatLng center,
    double radiusMeters, {
    int pointCount = circlePointCount,
  }) {
    _validateCircle(center, radiusMeters);
    if (pointCount < 8 || pointCount > maxTemporaryObstaclePoints) {
      throw ArgumentError.value(pointCount, 'pointCount', 'must be 8-200');
    }
    return List.generate(
      pointCount,
      (index) => computeOffset(
        center,
        radiusMeters,
        index * 360.0 / pointCount,
      ),
      growable: false,
    );
  }

  Future<String> addTemporaryCircle({
    required LatLng center,
    double radiusMeters = defaultTemporaryRadiusMeters,
  }) async {
    final user = _requireUser();
    _validateCircle(center, radiusMeters);
    final document = staticObstacleRef.collection.doc();
    await document.set({
      'name': '臨時危険区域',
      'shape': 'circle',
      'kind': StaticObstacleKind.generic.name,
      'center': GeoPoint(center.latitude, center.longitude),
      'radiusMeters': radiusMeters,
      'points': createCirclePoints(center, radiusMeters)
          .map((point) => GeoPoint(point.latitude, point.longitude))
          .toList(growable: false),
      'createdBy': user.uid,
      'source': 'user_confirmed',
      'createdAt': FieldValue.serverTimestamp(),
      'confirmedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    });
    return document.id;
  }

  /// 共有編集。作成者・作成時刻は更新しない。
  Future<void> updateTemporaryCircle({
    required String obstacleId,
    required LatLng center,
    required double radiusMeters,
  }) async {
    final user = _requireUser();
    _validateCircle(center, radiusMeters);
    await staticObstacleRef.collection.doc(obstacleId).update({
      'shape': 'circle',
      'center': GeoPoint(center.latitude, center.longitude),
      'radiusMeters': radiusMeters,
      'points': createCirclePoints(center, radiusMeters)
          .map((point) => GeoPoint(point.latitude, point.longitude))
          .toList(growable: false),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
      'confirmedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 削除する。文書は消さず「削除済み」の印を付ける。
  ///
  /// 1人の誤操作・悪意でチーム全艇の警告が消えても、誰でも元に戻せるように
  /// する。印の付いた区域は警告にも地図にも出さない(従来の削除と同じ)。
  /// 印から [softDeleteRetention] を過ぎたものは [purgeExpiredDeleted] で消える。
  Future<void> deleteStaticObstacle(String obstacleId) async {
    final user = _requireUser();
    await staticObstacleRef.collection.doc(obstacleId).update({
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy': user.uid,
      // 外周を空にする。旧版アプリは削除の印を知らないが、外周が3点未満の
      // 区域は読み飛ばすので、旧版の端末でも警告・表示が消える。
      // 元に戻すときは中心と半径から外周を作り直す(臨時危険区域は円だけ)。
      'points': const <GeoPoint>[],
    });
    debugPrint("Completed deleteStaticObstacle");
  }

  /// 削除の印を外して元に戻す。戻した人を更新者として残す。
  Future<void> restoreTemporaryObstacle(DeletedTemporaryObstacle item) async {
    final user = _requireUser();
    final center = item.center;
    final radius = item.radiusMeters;
    if (center == null || radius == null) {
      throw StateError('この区域は中心または半径が読めないため、元に戻せません。');
    }
    _validateCircle(center, radius);
    await staticObstacleRef.collection.doc(item.id).update({
      'points': createCirclePoints(center, radius)
          .map((point) => GeoPoint(point.latitude, point.longitude))
          .toList(growable: false),
      'deletedAt': FieldValue.delete(),
      'deletedBy': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
      'confirmedAt': FieldValue.serverTimestamp(),
      'updatedBy': user.uid,
    });
  }

  /// 削除の印から保持期間を過ぎた文書を消す。失敗しても何もしない
  /// (同期上限100件を圧迫しないための掃除であり、安全機能ではない)。
  Future<void> purgeExpiredDeleted({DateTime? now}) async {
    try {
      final cutoff = (now ?? DateTime.now()).subtract(softDeleteRetention);
      final snapshot = await staticObstacleRef.collection
          .where('deletedAt', isLessThan: Timestamp.fromDate(cutoff))
          .limit(20)
          .get();
      for (final document in snapshot.docs) {
        await document.reference.delete();
      }
    } catch (error) {
      debugPrint('Expired deleted obstacle purge skipped: $error');
    }
  }

  User _requireUser() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('臨時危険区域の編集にはログインが必要です。');
    }
    return user;
  }

  void _validateCircle(LatLng center, double radiusMeters) {
    if (center.latitude < -90 ||
        center.latitude > 90 ||
        center.longitude < -180 ||
        center.longitude > 180 ||
        !radiusMeters.isFinite ||
        radiusMeters < minTemporaryRadiusMeters ||
        radiusMeters > maxTemporaryRadiusMeters) {
      throw ArgumentError('Invalid temporary circle');
    }
  }
}

/// 削除の印が付いた臨時危険区域(元に戻す一覧に出す)。
class DeletedTemporaryObstacle {
  final String id;
  final String name;
  final DateTime? deletedAt;
  final String? deletedBy;
  final LatLng? center;
  final double? radiusMeters;

  const DeletedTemporaryObstacle({
    required this.id,
    required this.name,
    this.deletedAt,
    this.deletedBy,
    this.center,
    this.radiusMeters,
  });
}
