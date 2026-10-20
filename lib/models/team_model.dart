import 'package:cloud_firestore/cloud_firestore.dart';

/// 全メンバーが同じ招待コードを共有するチーム。
class RowingTeam {
  final String id;
  final String name;
  final String inviteCode;
  final String createdBy;
  final String adminUid;
  final DateTime? createdAt;

  const RowingTeam({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.createdBy,
    required this.adminUid,
    this.createdAt,
  });

  factory RowingTeam.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    final name = data['name'];
    final inviteCode = data['inviteCode'];
    final createdBy = data['createdBy'];
    if (name is! String || inviteCode is! String || createdBy is! String) {
      throw const FormatException('Invalid team document');
    }
    final storedAdminUid = data['adminUid'];
    if (storedAdminUid != null && storedAdminUid is! String) {
      throw const FormatException('Invalid team administrator');
    }
    return RowingTeam(
      id: id,
      name: name,
      inviteCode: inviteCode,
      createdBy: createdBy,
      // adminUid追加前に作られたチームは、作成者を管理者として扱う。
      adminUid: storedAdminUid as String? ?? createdBy,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// 端末内で現在のチームを確立するための最小スナップショット。
class TeamMembership {
  final RowingTeam team;
  final String userId;

  /// メンバー情報(Firestore)に登録されている自分の名前。
  /// 未登録・端末内キャッシュからの復元では null。正は端末内の名前
  /// (`AccountDisplayNameService`)で、これは取り込みと送り直しの判定に使う。
  final String? displayName;

  const TeamMembership({
    required this.team,
    required this.userId,
    this.displayName,
  });

  String get teamId => team.id;
  String get inviteCode => team.inviteCode;
  bool get isAdministrator => userId == team.adminUid;
}

/// 管理画面でだけ表示する最小限の所属情報。
/// 匿名認証のUID全体を画面に出さず、削除対象を取り違えないための識別子にする。
class TeamMemberSummary {
  final String userId;
  final DateTime? joinedAt;

  /// 本人が登録した名前。この機能より前に参加し、まだ新しい版を起動して
  /// いないメンバーは null。同じ名前の人がいてもよいので、識別には [shortId] を併記する。
  final String? displayName;

  const TeamMemberSummary({
    required this.userId,
    this.joinedAt,
    this.displayName,
  });

  factory TeamMemberSummary.fromFirestore(
    String userId,
    Map<String, dynamic> data,
  ) {
    final name = data['displayName'];
    return TeamMemberSummary(
      userId: userId,
      joinedAt: (data['joinedAt'] as Timestamp?)?.toDate(),
      displayName: name is String && name.trim().isNotEmpty ? name : null,
    );
  }

  String get shortId => userId.length <= 8 ? userId : userId.substring(0, 8);

  /// 管理画面の表示名。名前が無ければ「名前未登録」。
  String get displayLabel => displayName ?? '名前未登録';
}
