import 'team_service.dart';

/// 招待コード共有用の文面を一元化する純Dartヘルパー。
class TeamInviteShareService {
  const TeamInviteShareService._();

  static String buildText({
    required String teamName,
    required String inviteCode,
  }) {
    final normalized = TeamInviteCode.normalize(inviteCode);
    if (!TeamInviteCode.isValid(normalized)) {
      throw const FormatException('Invalid team invite code');
    }
    final formatted = TeamInviteCode.format(normalized);
    return 'Rowing Navigatorの「$teamName」へ参加する招待コードです。\n'
        '$formatted\n\n'
        'アプリを開き「招待コードでチームに参加する」から入力してください。\n'
        '位置情報と危険区域を共有するコードのため、同じチーム以外へ転送・公開しないでください。';
  }
}
