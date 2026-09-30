// The per-user cache folder of SmartschoolClient (#30): the folder a client
// uses (`cacheDir`) and the default one per username (`defaultCacheDir`).
//
// None of these tests touches the real `~/.cache/smartschool`: the default
// rule is checked against injected environment variables, a client with a
// given folder gets a temporary one, and the client with the default folder
// runs in a separate process whose home folder is temporary.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/cache_dir.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

AppCredentials _credentials(String username) => AppCredentials(
  username: username,
  password: 'pass',
  mainUrl: 'school.smartschool.be',
);

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_30_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('the default cache folder', () {
    test('is .cache/smartschool/<username> in HOME', () {
      final home = p.join(tempDir.path, 'home');

      expect(
        defaultCacheDirFor('john.doe', {'HOME': home}),
        p.join(home, '.cache', 'smartschool', 'john.doe'),
      );
    });

    test('is in USERPROFILE when HOME is not set (Windows)', () {
      final profile = p.join(tempDir.path, 'profile');

      expect(
        defaultCacheDirFor('john.doe', {'USERPROFILE': profile}),
        p.join(profile, '.cache', 'smartschool', 'john.doe'),
      );
    });

    test('is in HOME when USERPROFILE is set too (Git Bash, MSYS)', () {
      final home = p.join(tempDir.path, 'home');
      final profile = p.join(tempDir.path, 'profile');

      expect(
        defaultCacheDirFor('john.doe', {'HOME': home, 'USERPROFILE': profile}),
        p.join(home, '.cache', 'smartschool', 'john.doe'),
      );
    });

    test('is relative to the current directory without HOME or '
        'USERPROFILE', () {
      final dir = defaultCacheDirFor('john.doe', const {});

      expect(dir, p.join('.', '.cache', 'smartschool', 'john.doe'));
      expect(p.isRelative(dir), isTrue);
    });

    test('is a folder of its own per username', () {
      final env = {'HOME': p.join(tempDir.path, 'home')};
      final john = defaultCacheDirFor('john.doe', env);
      final jane = defaultCacheDirFor('jane.doe', env);

      expect(john, isNot(jane));
      expect(p.basename(john), 'john.doe');
      expect(p.basename(jane), 'jane.doe');
      expect(p.dirname(john), p.dirname(jane));
    });

    test('uses the Windows profile folder and separators on Windows', () {
      expect(
        defaultCacheDirFor('john.doe', {'USERPROFILE': r'C:\Users\jane'}),
        r'C:\Users\jane\.cache\smartschool\john.doe',
      );
    }, testOn: 'windows');

    test('uses the home folder and separators on POSIX', () {
      expect(
        defaultCacheDirFor('john.doe', {'HOME': '/home/jane'}),
        '/home/jane/.cache/smartschool/john.doe',
      );
    }, testOn: '!windows');

    test('SmartschoolClient.defaultCacheDir applies the rule to this '
        "process's environment", () {
      expect(
        SmartschoolClient.defaultCacheDir('john.doe'),
        defaultCacheDirFor('john.doe', Platform.environment),
      );
    });
  });

  group('SmartschoolClient.cacheDir', () {
    test('is the cacheDir given to create, as given', () async {
      final given = p.join(tempDir.path, 'nested', 'cache');
      final client = await SmartschoolClient.create(
        _credentials('john.doe'),
        cacheDir: given,
      );
      addTearDown(client.dispose);

      expect(client.cacheDir, given);
      expect(Directory(given).existsSync(), isTrue);
    });

    test('is the default cache folder of the user when create is given '
        'none, and create makes it there', () async {
      // HOME and USERPROFILE differ so the test shows which one is used,
      // whatever the platform.
      final home = Directory(p.join(tempDir.path, 'home'))..createSync();
      final profile = Directory(p.join(tempDir.path, 'profile'))..createSync();
      final output = p.join(tempDir.path, 'result.json');

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          p.join('test', 'support', 'default_cache_dir_client.dart'),
          'jane.doe',
          output,
        ],
        environment: {'HOME': home.path, 'USERPROFILE': profile.path},
      );

      expect(
        result.exitCode,
        0,
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      final found =
          jsonDecode(File(output).readAsStringSync()) as Map<String, dynamic>;
      final expected = p.join(home.path, '.cache', 'smartschool', 'jane.doe');
      expect(found['cacheDir'], expected);
      expect(found['defaultCacheDir'], expected);
      expect(found['exists'], isTrue);
      expect(Directory(expected).existsSync(), isTrue);
      expect(
        Directory(p.join(profile.path, '.cache')).existsSync(),
        isFalse,
        reason: 'HOME is set, so USERPROFILE is not used',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
