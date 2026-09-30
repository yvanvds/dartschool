// The cache folder for the clients that tests create (#49).
//
// `SmartschoolClient.create` keeps its per-user data (the saved session
// cookies) in `~/.cache/smartschool/<username>` unless it is given a
// `cacheDir`. A test that relied on that default would write into the real
// cache of whoever runs the tests, and could clobber a real session when its
// username matches a real one. cache_dir_guard_test.dart fails on any client
// created in a test without a `cacheDir`.
import 'dart:io';

import 'package:test/test.dart';

/// Makes an empty temporary folder to pass as the `cacheDir` of a
/// `SmartschoolClient.create` in a test, and deletes it when the test is done
/// (or, when called in `setUpAll`, when its group is done).
///
/// Each call makes a folder of its own, so clients never share a cookie jar
/// between tests.
String tempCacheDir() {
  final dir = Directory.systemTemp.createTempSync('smartschool_test_cache_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}
