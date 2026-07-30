import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/compact_position_joiner.dart';

void main() {
  const compact = <Object?, Object?>{
    's': 'session-a',
    'q': 1,
    'u': 1000,
    'o': 900,
    'x': 36.07,
    'y': 140.2,
    'z': 3.0,
    'c': 180.0,
    'v': 4.0,
  };
  const profile = <Object?, Object?>{
    'displayName': '後藤',
    'boatType': 'r_1x',
    'protocolVersion': 1,
    'appVersion': '1.0.0',
    'profileVersion': 'sakuragawa-v3',
  };

  test('positionがprofileより先に着いても保留して結合する', () {
    final joiner = CompactPositionJoiner();
    joiner.putPosition('boat-a', compact);

    expect(joiner.takeExpanded('boat-a'), isNull);
    joiner.putProfile('boat-a', profile);
    final expanded = joiner.takeExpanded('boat-a');

    expect(expanded?['boatId'], 'boat-a');
    expect(expanded?['displayName'], '後藤');
    expect(expanded?['lat'], 36.07);
    expect(joiner.takeExpanded('boat-a'), isNull);
  });

  test('profileがpositionより先に着いても結合する', () {
    final joiner = CompactPositionJoiner();
    joiner.putProfile('boat-a', profile);
    joiner.putPosition('boat-a', compact);

    expect(joiner.takeExpanded('boat-a'), isNotNull);
  });

  test('childRemoved後は未処理positionを復活させない', () {
    final joiner = CompactPositionJoiner();
    joiner.putPosition('boat-a', compact);
    joiner.removePosition('boat-a');
    joiner.putProfile('boat-a', profile);

    expect(joiner.takeExpanded('boat-a'), isNull);
  });
}
