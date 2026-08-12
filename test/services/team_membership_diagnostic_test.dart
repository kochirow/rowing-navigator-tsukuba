import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/team_service.dart';

void main() {
  test('所属診断はIDを含まず、不明値と不在を区別する', () {
    const result = TeamMembershipDiagnostic(
      authenticated: true,
      teamUserMatchesActiveTeam: false,
      memberRecordExists: null,
      readDenied: true,
      failureCode: 'permission-denied',
    );

    expect(result.toDiagnosticDetails(), {
      'authenticated': true,
      'teamUserMatchesActiveTeam': false,
      'memberRecordExists': null,
      'readDenied': true,
      'failureCode': 'permission-denied',
    });
    expect(result.toDiagnosticDetails().keys, isNot(contains('uid')));
    expect(result.toDiagnosticDetails().keys, isNot(contains('teamId')));
  });
}
