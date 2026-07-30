import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/api/live_position_api.dart';

void main() {
  test('profile必要時はpositionと同じatomic updateに含める', () {
    final updates = LivePositionAPI.buildPublishUpdates(
      teamId: 'team-a',
      boatId: 'boat-a',
      position: const {'q': 1, 'x': 36.07},
      profile: const {'displayName': '後藤'},
    );

    expect(updates, {
      'teams/team-a/live_positions/boat-a': {'q': 1, 'x': 36.07},
      'teams/team-a/boat_profiles/boat-a': {'displayName': '後藤'},
    });
  });

  test('通常送信はprofileを再送せずpositionだけ更新する', () {
    final updates = LivePositionAPI.buildPublishUpdates(
      teamId: 'team-a',
      boatId: 'boat-a',
      position: const {'q': 2},
    );

    expect(updates.keys, ['teams/team-a/live_positions/boat-a']);
  });

  test('停止・切断時はprofileとpositionを1回で削除する', () {
    expect(
      LivePositionAPI.buildClearUpdates(
        teamId: 'team-a',
        boatId: 'boat-a',
      ),
      {
        'teams/team-a/live_positions/boat-a': null,
        'teams/team-a/boat_profiles/boat-a': null,
      },
    );
  });
}
