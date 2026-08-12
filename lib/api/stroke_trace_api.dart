import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rowing_navigator/config/navigator_config.dart';

import '../services/team_service.dart';

/// 1ストロークの艇速波形を置く Realtime Database パス。
///
/// **`live_positions` とは必ず別ノードにする。** 位置は全艇が全艇ぶんを
/// 購読するため 12×12 の fan-out があり、そこへ波形を足すと転送量が
/// 144倍で効く。こちらは監視端末が選んだ1艇だけを購読するので、
/// 1艇ぶんの download しか発生しない。
///
/// 艇側は表示のON/OFFに関わらずこのノードを購読しない(送信のみ)。
class StrokeTraceAPI {
  static const path = 'stroke_traces';

  final String? _teamId;

  StrokeTraceAPI({String? teamId}) : _teamId = teamId;

  String get teamId => _teamId ?? TeamService.requireActiveTeamId;

  FirebaseDatabase get _db => realtimeDatabaseUrl.isEmpty
      ? FirebaseDatabase.instance
      : FirebaseDatabase.instanceFor(
          app: Firebase.app(), databaseURL: realtimeDatabaseUrl);

  DatabaseReference get ref => _db.ref('teams/$teamId/$path');

  DatabaseReference boatRef(String boatId) => ref.child(boatId);

  /// 最新の1ストロークだけを上書きする。履歴は残さない。
  ///
  /// 位置共有の atomic update には**混ぜない**。混ぜると、波形側の
  /// validation 失敗で位置の書込ごと拒否され、安全経路が巻き添えになる。
  Future<void> publish({
    required String boatId,
    required Map<String, Object?> trace,
  }) =>
      boatRef(boatId).set(trace);

  /// 接続断で古い波形が残らないようにする。位置側の onDisconnect とは
  /// 独立に登録し、こちらの失敗が位置の削除登録を壊さないようにする。
  Future<void> armRemoval(String boatId) =>
      boatRef(boatId).onDisconnect().remove();

  Future<void> clear(String boatId) => boatRef(boatId).remove();
}
