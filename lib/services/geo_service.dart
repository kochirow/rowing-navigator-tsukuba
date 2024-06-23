/* spellchecker: disable */
import 'package:geolocator/geolocator.dart';

// =============================================
// 位置情報サービス
// =============================================
class GeoService {
  // 現在地を取得
  Future<Position> getCurrentPosition(LocationAccuracy accuracy) async {
    final Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: accuracy,
    );
    return position;
  }
}
