/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

class PermissionService {
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
}
