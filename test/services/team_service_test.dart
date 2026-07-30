import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/team_service.dart';

void main() {
  group('TeamInviteCode', () {
    test('generates a high entropy fixed-length code from safe characters', () {
      final code = TeamInviteCode.generate(Random(42));

      expect(code, hasLength(12));
      expect(TeamInviteCode.isValid(code), isTrue);
      expect(code, isNot(contains(RegExp(r'[01ILOU]'))));
    });

    test('normalizes grouped lower-case user input', () {
      const raw = '2345-6789 abcd';

      expect(TeamInviteCode.normalize(raw), '23456789ABCD');
      expect(TeamInviteCode.isValid(raw), isTrue);
      expect(
        TeamInviteCode.format(raw),
        '2345-6789-ABCD',
      );
    });

    test('keeps existing 20-character team codes valid', () {
      const legacy = '23456-789ab-cdefg-hjkmn';

      expect(TeamInviteCode.isValid(legacy), isTrue);
      expect(
        TeamInviteCode.format(legacy),
        '23456-789AB-CDEFG-HJKMN',
      );
    });

    test('rejects short, ambiguous, or unknown characters', () {
      expect(TeamInviteCode.isValid('23456'), isFalse);
      expect(TeamInviteCode.isValid('123456789ABC'), isFalse);
      expect(TeamInviteCode.isValid('23456789ABC!'), isFalse);
      expect(TeamInviteCode.isValid('23456789ABCDE'), isFalse);
    });
  });

  group('TeamRecoveryHint', () {
    test('keeps a valid team and invite only as a rejoin hint', () {
      final hint = TeamRecoveryHint.fromCachedValues(
        teamName: '  桜川ボートクラブ  ',
        inviteCode: '23456-789ab-cdefg-hjkmn',
      );

      expect(hint, isNotNull);
      expect(hint!.teamName, '桜川ボートクラブ');
      expect(hint.inviteCode, '23456789ABCDEFGHJKMN');
    });

    test('rejects partial or corrupted membership cache', () {
      expect(
        TeamRecoveryHint.fromCachedValues(
          teamName: '桜川ボートクラブ',
          inviteCode: null,
        ),
        isNull,
      );
      expect(
        TeamRecoveryHint.fromCachedValues(
          teamName: '桜川ボートクラブ',
          inviteCode: 'broken-code',
        ),
        isNull,
      );
    });
  });

  group('TeamRestoreErrorPolicy', () {
    test('uses membership cache only for transient network failures', () {
      expect(
        TeamRestoreErrorPolicy.allowsOfflineCache('unavailable'),
        isTrue,
      );
      expect(
        TeamRestoreErrorPolicy.allowsOfflineCache('deadline-exceeded'),
        isTrue,
      );
      expect(
        TeamRestoreErrorPolicy.allowsOfflineCache('resource-exhausted'),
        isTrue,
      );
      expect(
        TeamRestoreErrorPolicy.allowsOfflineCache('permission-denied'),
        isTrue,
      );
      expect(
        TeamRestoreErrorPolicy.allowsOfflineCache('unauthenticated'),
        isTrue,
      );
      expect(TeamRestoreErrorPolicy.allowsOfflineCache('unknown'), isFalse);
    });
  });
}
