import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/config/practice_log_config.dart';

// =============================================
// 位置情報サービス
// =============================================
class GeoService {
  Position? _lastObservedPosition;

  LocationSettings _locationSettings(
    LocationAccuracy accuracy, {
    Duration? timeLimit,
  }) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        timeLimit: timeLimit,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Rowing Navigator が航行を記録中',
          // 実機のlock/background試験が完了するまでは、安全評価の継続を
          // 通知文だけで保証しない。通知はセッション実行中の事実だけを示す。
          notificationText: '航行セッションを実行中です。アプリの状態を確認してください。',
          notificationChannelName: '航行中の位置情報',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        // -1 is kCLDistanceFilterNone. 0 is not equivalent in
        // geolocator_apple 2.3.13's Objective-C mapper.
        distanceFilter: iosDistanceFilterNone,
        timeLimit: timeLimit,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: 0,
      timeLimit: timeLimit,
    );
  }

  @visibleForTesting
  LocationSettings locationSettingsForTesting(
    LocationAccuracy accuracy, {
    Duration? timeLimit,
  }) =>
      _locationSettings(accuracy, timeLimit: timeLimit);

  // 現在地を取得
  Future<Position> getCurrentPosition(LocationAccuracy accuracy) async {
    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: _locationSettings(
        accuracy,
        timeLimit: const Duration(seconds: initialPositionTimeoutSeconds),
      ),
    );
    _lastObservedPosition = position;
    return position;
  }

  /// 航行開始用の位置を取得する。
  ///
  /// 同じ画面で既に取得した位置かOSのlast-known fixを足掛かりにして、
  /// 「航行スタート」を新しい高精度fix待ちで塞がない。古さ・精度は
  /// 呼び出し側のGPS品質監視で「利用不可」として扱い、新しいstream測位を待つ。
  Future<Position> getNavigationBootstrapPosition(
    LocationAccuracy accuracy,
  ) async {
    final cached =
        _lastObservedPosition ?? await Geolocator.getLastKnownPosition();
    if (cached != null) return cached;
    return getCurrentPosition(accuracy);
  }

  Stream<Position> getPositionStream(LocationAccuracy accuracy) {
    return Geolocator.getPositionStream(
      locationSettings: _locationSettings(accuracy),
    ).map((position) {
      _lastObservedPosition = position;
      return position;
    });
  }

  /// 監視者トラック専用。航行用の1秒・bestForNavigation設定を流用せず、
  /// 画面消灯中も位置バックグラウンド資格を維持しつつ10秒単位で記録する。
  Stream<Position> getObserverPositionStream() {
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: observerTrackIntervalSec),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Rowing Navigator が監視記録中',
          notificationText: '練習一括ログを記録中です。画面を消すと記録が途切れることがあります。',
          notificationChannelName: '監視中の位置情報',
          enableWakeLock: false,
          setOngoing: true,
        ),
      );
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 5);
    }
    return Geolocator.getPositionStream(locationSettings: settings)
        .map((position) {
      _lastObservedPosition = position;
      return position;
    });
  }
}
