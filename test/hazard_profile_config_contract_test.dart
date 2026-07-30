import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/hazard_profile_config.dart';

void main() {
  test('同梱障害物プロフィールのversionとSHA-256が設定値と一致する', () {
    final source =
        File('assets/data/sakuragawa_obstacles.json').readAsBytesSync();
    final profile = jsonDecode(utf8.decode(source)) as Map<String, dynamic>;

    expect(profile['version'], currentHazardProfileDataVersion);
    expect(sha256.convert(source).toString(), currentHazardProfileSha256);
  });
}
