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
    for (final doc in snapshot.docs) {
      // 1件の不正な危険区域データで全体の受信を止めない。
      try {
        final obstacle = doc.data();
        final rawPoints = obstacle['points'];
        if (rawPoints is! List ||
            rawPoints.length < 3 ||
            rawPoints.length > maxTemporaryObstaclePoints) {
          continue;
        }
        final points = (obstacle['points'] as List<dynamic>)
            .whereType<GeoPoint>()
            .map<LatLng>((point) => LatLng(point.latitude, point.longitude))
            .toList();
        if (points.length != rawPoints.length) continue;
        final rawCenter = obstacle['center'];
        final rawRadius = obstacle['radiusMeters'];
        final center = rawCenter is GeoPoint
            ? LatLng(rawCenter.latitude, rawCenter.longitude)
            : null;
        final radius = rawRadius is num && rawRadius.isFinite
            ? rawRadius.toDouble()
            : null;
        obstacles.add(StaticObstacle(
          id: doc.id,
          name: obstacle['name'] as String?,
          points: points,
          kind: StaticObstacleKind.fromJson(obstacle['kind'] as String?),
          warningAudioAsset: obstacle['warningAudio'] as String?,
          isTemporary: true,
          circleCenter: center,
          circleRadiusMeters: radius,
        ));
      } catch (e) {
        debugPrint('Invalid static obstacle ignored: ${doc.id} $e');
      }
    }
    return {'obstacles': obstacles};
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

  Future<void> deleteStaticObstacle(String obstacleId) async {
    _requireUser();
    await staticObstacleRef.collection.doc(obstacleId).delete();
    debugPrint("Completed deleteStaticObstacle");
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
