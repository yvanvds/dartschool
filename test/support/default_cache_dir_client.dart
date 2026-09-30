// Run as a separate process by session_cache_dir_test.dart, with `HOME` and
// `USERPROFILE` pointing into a temporary folder: it creates a client with
// the default cache folder, which the test process cannot do without touching
// the real `~/.cache/smartschool` (#30).
//
// Usage: dart test/support/default_cache_dir_client.dart <username> <output>
// Writes what it found as JSON to <output>.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

Future<void> main(List<String> args) async {
  final username = args[0];
  final client = await SmartschoolClient.create(
    AppCredentials(
      username: username,
      password: 'pass',
      mainUrl: 'school.smartschool.be',
    ),
  );
  await client.dispose();
  File(args[1]).writeAsStringSync(
    jsonEncode({
      'cacheDir': client.cacheDir,
      'defaultCacheDir': SmartschoolClient.defaultCacheDir(username),
      'exists': Directory(client.cacheDir).existsSync(),
    }),
  );
}
