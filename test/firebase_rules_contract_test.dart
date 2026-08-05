import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/hazard_profile_config.dart';

/// `database.rules.json` は Firebase Rules の JSONC(行コメントを書ける)。
/// 設定値の根拠はルールの隣に置きたいので、解析前に行コメントだけ落とす。
Map<String, dynamic> readDatabaseRules() {
  final source = File('database.rules.json')
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  return jsonDecode(source) as Map<String, dynamic>;
}

void main() {
  test('RTDB rules use team paths and reject the former global position path',
      () {
    final rules = readDatabaseRules();
    final root = rules['rules'] as Map<String, dynamic>;

    expect(root['live_positions'], isNull);
    expect(root['team_users'], isA<Map<String, dynamic>>());
    expect(root['team_members'], isA<Map<String, dynamic>>());
    expect(root['team_invites'], isA<Map<String, dynamic>>());
    final teams = root['teams'] as Map<String, dynamic>;
    final scoped = teams[r'$teamId'] as Map<String, dynamic>;
    expect(scoped['live_positions'], isA<Map<String, dynamic>>());
    expect(scoped['boat_profiles'], isA<Map<String, dynamic>>());
    // 送信レート制限の下限。クライアントは `intervalSec * 1000 - 100` で発火する
    // ため2秒間隔では1900msで撃ち、`u` はサーバー到着時刻なのでジッタぶんだけ
    // 間隔が縮む。下限を1900msに戻すと余裕がゼロになり、位置の書き込みが
    // permission-denied で落ちる(2026-07-27 レビュー S2-H)。
    expect(
      rules['rules'].toString(),
      contains("newData.val() >= data.val() + 1700"),
    );

    final livePosition = (scoped['live_positions']
        as Map<String, dynamic>)[r'$boatId'] as Map<String, dynamic>;
    for (final key in ['w', 'm', 'a']) {
      expect(
        livePosition[key],
        isA<Map<String, dynamic>>(),
        reason: 'Build 8が送る$keyを本番Rulesが許可しないと、'
            '位置書き込み全体がpermission-deniedになる。',
      );
    }
    expect(
      (livePosition[r'$other'] as Map<String, dynamic>)['.validate'],
      isNot(false),
      reason: '将来の任意スカラー値で旧Rulesと同じ全拒否に戻さない。',
    );
  });

  test('艇速波形は位置と別ノードで、fan-outを持たない', () {
    final rules = readDatabaseRules();
    final scoped = ((rules['rules'] as Map<String, dynamic>)['teams']
        as Map<String, dynamic>)[r'$teamId'] as Map<String, dynamic>;

    final traces = scoped['stroke_traces'] as Map<String, dynamic>;
    expect(
      traces,
      isA<Map<String, dynamic>>(),
      reason: '波形を live_positions へ混ぜると、全艇が全艇ぶんを受け取る '
          '12x12 の fan-out に乗って転送量が跳ね上がる。',
    );

    // 位置側の必須項目は従来のまま。ここへ波形フィールドを足すと、
    // 旧版の艇が位置を書けなくなり、安全経路が止まる。
    final livePosition = (scoped['live_positions']
        as Map<String, dynamic>)[r'$boatId'] as Map<String, dynamic>;
    expect(
      livePosition['.validate'] as String,
      "newData.hasChildren(['s','q','u','o','x','y','z','c','v'])",
    );

    final trace = traces[r'$boatId'] as Map<String, dynamic>;
    expect(
      trace['.validate'] as String,
      contains("newData.hasChildren(['o','d','b','w','u'])"),
    );
    // 位置と同じレート制限。1ストロークに1回を超えて書かせない。
    expect(
      (trace['u'] as Map<String, dynamic>)['.validate'] as String,
      contains('newData.val() >= data.val() + 1700'),
    );
    // 12〜65spm の外はストロークとして描けない。
    final duration = (trace['d'] as Map<String, dynamic>)['.validate'] as String;
    expect(duration, contains('newData.val() >= 800'));
    expect(duration, contains('newData.val() <= 5200'));
    // 巨大payloadを受け取らない。
    expect(
      (trace['w'] as Map<String, dynamic>)['.validate'] as String,
      contains('newData.val().length <= 176'),
    );
    expect(
      (trace[r'$other'] as Map<String, dynamic>)['.validate'],
      isNot(false),
      reason: '新版が足したスカラーで旧版の読み取りを壊さない。',
    );
  });

  test('RTDB rules accept bounded future protocol and profile versions', () {
    final rules = readDatabaseRules();
    final profiles = ((rules['rules'] as Map<String, dynamic>)['teams']
        as Map<String, dynamic>)[r'$teamId'] as Map<String, dynamic>;
    final boatProfile = (profiles['boat_profiles']
        as Map<String, dynamic>)[r'$boatId'] as Map<String, dynamic>;

    final protocolRule = (boatProfile['protocolVersion']
        as Map<String, dynamic>)['.validate'] as String;
    expect(protocolRule, contains('newData.val() >= 1'));
    expect(protocolRule, contains('newData.val() % 1 === 0'));
    expect(protocolRule.contains('newData.val() ==='), isFalse);

    final profileRule = (boatProfile['profileVersion']
        as Map<String, dynamic>)['.validate'] as String;
    expect(profileRule, contains('newData.isString()'));
    expect(profileRule, contains('newData.val().length <= 128'));
    expect(profileRule.contains('newData.val() ==='), isFalse);

    final appVersionRule = (boatProfile['appVersion']
        as Map<String, dynamic>)['.validate'] as String;
    expect(
      appVersionRule.contains("newData.val() ==="),
      isFalse,
      reason: 'appVersion を特定の値へ固定すると、新版を配信した端末が'
          'プロファイルを書き込めなくなる。互換の判断は protocolVersion だけで行う。',
    );
    expect(appVersionRule, contains('newData.isString()'));
    expect(appVersionRule, contains('newData.val().length <= 64'));
  });

  test('Firestore rules scope all shared collections below teams', () {
    final rules = File('firestore.rules').readAsStringSync();

    expect(rules, contains('match /teams/{teamId}'));
    expect(rules, contains('match /temporary_obstacles/{obstacleId}'));
    expect(rules, contains('match /managed_hazards/fixed_driftwood_01'));
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v2',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v3',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v4',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v5',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v6',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v7',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v8',
      ),
    );
    expect(
      rules,
      contains(
        'match /managed_hazards/fixed_obstacle_calibrations_v9',
      ),
    );
    expect(rules, contains('validSharedSafetyCalibrationV3'));
    expect(rules, contains('validSharedSafetyCalibrationV4'));
    expect(rules, contains('validSharedSafetyCalibrationV5'));
    expect(rules, contains('validSharedSafetyCalibrationV6'));
    expect(rules, contains('validSharedSafetyCalibrationV7'));
    expect(rules, contains('validSharedSafetyCalibrationV8'));
    expect(rules, contains('validScaledOffsetMap'));
    expect(rules, contains('// GENERATED: hazard-allowlist BEGIN'));
    expect(rules, contains('function canPublishTeamSafety(teamId)'));
    expect(rules, contains('function isTeamAdmin(teamId)'));
    expect(rules, contains('function validTermsAcceptance(data)'));
    expect(rules, contains("data.termsVersion == '2026-08-03'"));
    expect(rules, contains("'adminUid'"));
    expect(rules, contains('validPreviousSafetyCalibration'));
    expect(rules, contains('validPreviousSafetyCalibrationV4'));
    expect(rules, contains('validDisabledWarningSourceIds'));
    expect(rules, contains('data.primaryWarningLeadSeconds >= 8.5'));
    expect(rules, contains('data.advanceWarningLeadSeconds <= 25'));
    expect(rules, contains('request.query.limit <= 100'));
    expect(rules, contains('allow list: if false;'));
    expect(
      rules,
      contains('match /temporary_obstacles/{document=**}'),
    );
  });

  test('team management rules rotate invitations and revoke members atomically',
      () {
    final rules = File('firestore.rules').readAsStringSync();
    final rtdb = readDatabaseRules().toString();

    expect(
      rules,
      contains('allow delete: if isTeamAdmin(resource.data.teamId)'),
      reason: '旧招待コードを管理者が無効化できないと、外した利用者が再参加できる。',
    );
    expect(
      rules,
      contains('request.auth.uid != uid && isTeamAdmin(teamId)'),
      reason: '管理者は自分以外のmembers/usersを同一batchで削除する必要がある。',
    );
    expect(
      rtdb,
      contains(
          r"root.child('team_meta').child($teamId).child('ownerUid').val() === auth.uid"),
      reason: 'RTDBの位置・艇情報・membership bridgeも管理者が削除できる必要がある。',
    );
  });

  // ルールは同梱プロファイルのSHA-256とversionを直書きしている
  // (Firestoreルールはimportできない)。ここがずれると、共有校正の
  // 書き込みがサーバ側で**黙って全て拒否される**。実際に
  // `sakuragawa_obstacles.json` へ対応水域を追加したとき、
  // ルール側だけ旧ハッシュのまま取り残された。以後は必ずここで落ちる。
  test('Firestore rules pin the current hazard profile hash and version', () {
    final rules = File('firestore.rules').readAsStringSync();

    expect(
      rules,
      contains("'$currentHazardProfileSha256'"),
      reason: 'firestore.rules の baseProfileSha256 が '
          'currentHazardProfileSha256 と一致していません。'
          'ハザードプロファイルを更新したらルールも更新し、デプロイすること。',
    );
    expect(
      rules,
      contains('data.baseProfileVersion == '
          '$currentHazardProfileDataVersion'),
      reason: 'firestore.rules の baseProfileVersion が '
          'currentHazardProfileDataVersion と一致していません。',
    );
  });
}
