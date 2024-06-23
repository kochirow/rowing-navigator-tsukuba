/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

class PermissionService {
  // =============================================
  // 位置情報取得の許可
  // =============================================
  Future<void> requestPermission() async {
    // 位置情報の許可を求める
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }
}
