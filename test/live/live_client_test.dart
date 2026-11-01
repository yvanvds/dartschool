// Tests for liveCredentialsFileFor (support/live_client.dart): which
// credentials file the live suite logs in with, `credentials.yml` in the
// package root or the one DARTSCHOOL_LIVE_CREDENTIALS names (#168), in
// temporary folders.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/no_network.dart';
import 'support/live_client.dart';

void main() {
  forbidRealNetwork();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('live_client_test_');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  File write(String path) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync('username: x\n');

  group('without the variable', () {
    test('credentials.yml of the package root', () {
      write('credentials.yml');
      for (final named in [null, '', '  ']) {
        expect(
          liveCredentialsFileFor(named, root: root.path)?.path,
          p.join(root.path, 'credentials.yml'),
        );
      }
    });

    test('null without it: the live suite skips', () {
      expect(liveCredentialsFileFor(null, root: root.path), isNull);
    });
  });

  group('with the variable', () {
    test('a file of the package root that ends in credentials.yml, by a '
        'relative path', () {
      write('credentials.yml');
      write('student-credentials.yml');
      expect(
        liveCredentialsFileFor(
          'student-credentials.yml',
          root: root.path,
        )?.path,
        p.join(root.path, 'student-credentials.yml'),
      );
    });

    test('a file outside the package root, by an absolute path, whatever '
        'its name', () {
      final outside = Directory.systemTemp.createTempSync('live_client_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final file = File(p.join(outside.path, 'pupil.yml'))
        ..writeAsStringSync('username: x\n');
      expect(
        liveCredentialsFileFor(file.path, root: root.path)?.path,
        file.path,
      );
    });

    test('refuses a file of the package root that .gitignore would not '
        'keep out of git', () {
      write('pupil.yml');
      write('sub/pupil.yml');
      for (final named in ['pupil.yml', 'sub/pupil.yml']) {
        expect(
          () => liveCredentialsFileFor(named, root: root.path),
          throwsA(isA<StateError>()),
        );
      }
    });

    test('refuses a file that does not exist, instead of skipping', () {
      write('credentials.yml');
      expect(
        () =>
            liveCredentialsFileFor('missing-credentials.yml', root: root.path),
        throwsA(isA<StateError>()),
      );
    });
  });
}
