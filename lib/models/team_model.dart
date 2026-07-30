import 'package:cloud_firestore/cloud_firestore.dart';

/// 全メンバーが同じ招待コードを共有するチーム。
class RowingTeam {
  final String id;
  final String name;
  final String inviteCode;
  final String createdBy;
  final DateTime? createdAt;

  const RowingTeam({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.createdBy,
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
    return RowingTeam(
      id: id,
      name: name,
      inviteCode: inviteCode,
      createdBy: createdBy,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// 端末内で現在のチームを確立するための最小スナップショット。
class TeamMembership {
  final RowingTeam team;
  final String userId;

  const TeamMembership({required this.team, required this.userId});

  String get teamId => team.id;
  String get inviteCode => team.inviteCode;
}
