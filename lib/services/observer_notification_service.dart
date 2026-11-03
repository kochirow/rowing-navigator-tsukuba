import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'permission_service.dart';

/// 監視端末が背面にある間の通知を出す窓口(R3)。音は鳴らさない(DESIGN_PRINCIPLES 3.5-3)。
///
/// 同じ艇の通知は同じIDで上書きする(艇ごとに1つ)。許可が無い・失敗したときは
/// false を返すだけで、監視・記録は止めない。
class ObserverNotificationService {
  static const _channel = MethodChannel(
    'jp.kosei.rowingnavigator.tsukuba/observer_notifications',
  );
  static const title = '監視中の艇';

  final PermissionService _permissions;
  ObserverNotificationService({PermissionService? permissions})
      : _permissions = permissions ?? PermissionService();

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// 通知の許可を求める。iOS はバナーだけ(音の許可は求めない)。
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        return await _permissions.requestNavigationNotificationPermission();
      }
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> show({required String boatId, required String body}) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('show', {
            'id': boatId,
            'title': title,
            'body': body,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
