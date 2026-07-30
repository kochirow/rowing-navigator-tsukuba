/* spellchecker: disable */
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

class PermissionService {
  static const _permissionChannel =
      MethodChannel('jp.kosei.rowingnavigator.tsukuba/permissions');

  // =============================================
  // 位置情報利用の許可
  // =============================================
  Future<void> requestLocationServicePermission() async {
    // 位置情報サービスが利用可能かどうかを確認
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('位置情報サービスが無効です。');
    }

    // 位置情報の利用権限を確認
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission(); // 権限をリクエスト
      if (permission == LocationPermission.denied) {
        return Future.error('位置情報を取得する権限がありません。');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error('位置情報サービスの権限が永久に拒否されています。権限を要求することができません。');
    }
  }

  /// 航行中の追跡に必要な位置権限を確認する。
  ///
  /// 航行は利用者がフォアグラウンドで明示的に開始する。Androidは
  /// location foreground service、iOSはBackground Location modeにより、
  /// whileInUse権限のまま画面消灯・別アプリ表示中の更新を継続する。
  /// 停止中の自動起動は行わないため、「常に許可」は必須にしない。
  Future<void> requireBackgroundLocationPermission() async {
    await requestLocationServicePermission();
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.whileInUse &&
        permission != LocationPermission.always) {
      throw StateError(
        '航行追跡には位置情報の利用許可が必要です。',
      );
    }
  }

  /// Android 13以降で、航行中のforeground service通知を
  /// 通知ドロワーに表示するための許可を要求する。
  /// 拒否されてもFGSは継続できるため、航行開始自体は止めない。
  Future<bool> requestNavigationNotificationPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    return await _permissionChannel.invokeMethod<bool>(
          'requestNotificationPermission',
        ) ??
        false;
  }
}
