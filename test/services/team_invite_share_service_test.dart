import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/team_invite_share_service.dart';

void main() {
  test('共有文に整形コード・参加手順・非公開注意を含める', () {
    final text = TeamInviteShareService.buildText(
      teamName: '桜川チーム',
      inviteCode: '23456789abcd',
    );

    expect(text, contains('桜川チーム'));
    expect(text, contains('2345-6789-ABCD'));
    expect(text, contains('招待コードでチームに参加する'));
    expect(text, contains('同じチーム以外へ転送・公開しない'));
  });

  test('既存20文字コードも共有できる', () {
    final text = TeamInviteShareService.buildText(
      teamName: '既存チーム',
      inviteCode: '23456789ABCDEFGHJKMN',
    );

    expect(text, contains('23456-789AB-CDEFG-HJKMN'));
  });

  test('不正なコードは共有文にしない', () {
    expect(
      () => TeamInviteShareService.buildText(
        teamName: '桜川チーム',
        inviteCode: 'broken',
      ),
      throwsFormatException,
    );
  });
}
