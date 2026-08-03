import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/store_config.dart';

void main() {
  test('public privacy, support, and report contacts are HTTPS URLs', () {
    for (final value in [
      privacyPolicyUrl,
      supportUrl,
      supportReportFormUrl,
    ]) {
      final uri = Uri.tryParse(value);
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, isNotEmpty);
    }
  });

  test('team terms version is fixed for initial membership consent', () {
    expect(teamTermsVersion, '2026-08-03');
  });
}
