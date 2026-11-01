// Guard: a credentials file never goes into the published package.
//
// When a package has a .pubignore, `dart pub publish` reads it instead of
// .gitignore (in that folder). #168 widened .gitignore from `credentials.yml`
// to `*credentials.yml`, for a second account's file such as
// `student-credentials.yml` (DARTSCHOOL_LIVE_CREDENTIALS), but not
// .pubignore: the archive of 0.4.2 held `student-credentials.yml` until the
// upload was cancelled. This test keeps every credentials pattern of
// .gitignore in .pubignore too.
import 'dart:io';

import 'package:test/test.dart';

import 'support/no_network.dart';

/// The patterns of an ignore file: its lines without comments and blanks.
Set<String> _patterns(String path) => File(path)
    .readAsLinesSync()
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .toSet();

void main() {
  forbidRealNetwork();

  test('.pubignore keeps every *credentials.yml out, in any folder', () {
    expect(_patterns('.pubignore'), contains('*credentials.yml'));
  });

  test('.pubignore has every credentials pattern of .gitignore', () {
    final pub = _patterns('.pubignore');
    final credentials = _patterns(
      '.gitignore',
    ).where((pattern) => pattern.toLowerCase().contains('credential'));
    expect(credentials, isNotEmpty);
    for (final pattern in credentials) {
      expect(
        pub,
        contains(pattern),
        reason:
            '$pattern is in .gitignore but not in .pubignore, which pub '
            'reads instead',
      );
    }
  });
}
