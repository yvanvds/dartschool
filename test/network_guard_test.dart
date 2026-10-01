// Guard for #50: no test may reach the network.
//
// forbidRealNetwork() (support/no_network.dart) refuses every request of its
// isolate to another machine and fails the test that sent it. It only holds
// in the isolates that call it: every test file runs in an isolate of its
// own, and a program that a test runs as a separate process in a process of
// its own. So this test reads every Dart file under `test/` and fails on a
// test file, or another program (a file that declares a top-level `main`),
// that does not call it. The other tests here check that it does what it
// says.
//
// One exemption, for the live suite (#57), which sends real messages to the
// own account on purpose: a test file under `test/live/` that is tagged
// `live` for the whole file (`@Tags(['live'])` on its `library;`).
// dart_test.yaml skips such a file without loading it unless the `live`
// preset is chosen (`dart test -P live`), which a test below checks. Any
// other file under `test/live/`, and a file tagged `live` elsewhere, must
// call forbidRealNetwork() like every other.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

/// A top-level `main` declaration.
final _mainDeclaration = RegExp(r'^[\w<>?, ]*\bmain\s*\(', multiLine: true);

/// A line that calls [forbidRealNetwork] (not a `//` comment).
final _forbidCall = RegExp(r'^\s*forbidRealNetwork\(\);', multiLine: true);

/// The `live` tag on the whole file: `@Tags(['live'])` (alone) on its
/// `library;` directive, at the start of a line.
final _liveLibrary = RegExp(
  r'''^@Tags\(\s*\[\s*(['"])live\1\s*,?\s*\]\s*\)\s*library\s*;''',
  multiLine: true,
);

/// Whether [source], a Dart file at [path] under `test/`, is a program that
/// does not call [forbidRealNetwork], other than a live suite (see
/// [isLiveSuite]).
bool leavesNetworkOpen(String path, String source) {
  final isProgram =
      path.endsWith('_test.dart') || _mainDeclaration.hasMatch(source);
  return isProgram &&
      !_forbidCall.hasMatch(source) &&
      !isLiveSuite(path, source);
}

/// Whether [source], a Dart file at [path] (relative to the package root),
/// is a suite of the live tests (#57): a test file under `test/live/` tagged
/// `live` for the whole file, which dart_test.yaml skips unless the `live`
/// preset is chosen.
bool isLiveSuite(String path, String source) =>
    p.split(p.normalize(path)).join('/').startsWith('test/live/') &&
    path.endsWith('_test.dart') &&
    _liveLibrary.hasMatch(source);

/// [path] relative to the package root, with `/` separators on every
/// platform.
String _packagePath(String path) => p.split(p.relative(path)).join('/');

void main() {
  forbidRealNetwork();

  test('every test file and program under test/ forbids the network', () {
    final files =
        Directory('test')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    // Run from the package root (as `dart test` does), there is plenty to
    // check; finding nothing would make this test pass for nothing.
    expect(
      files.where((file) => file.path.endsWith('_test.dart')),
      hasLength(greaterThan(1)),
      reason: 'no test files found under test/',
    );

    final offenders = [
      for (final file in files)
        if (leavesNetworkOpen(file.path, file.readAsStringSync()))
          _packagePath(file.path),
    ];

    expect(
      offenders,
      isEmpty,
      reason:
          'These can send requests to a live Smartschool (or any other '
          'host) without failing. Call `forbidRealNetwork();` first in their '
          '`main()` (test/support/no_network.dart):\n'
          '${offenders.join('\n')}',
    );
  });

  group('leavesNetworkOpen', () {
    const forbid = 'forbidRealNetwork();';

    test('finds a test file that does not call forbidRealNetwork', () {
      expect(
        leavesNetworkOpen(
          'test/x_test.dart',
          'void main() {\n'
              '  test("x", () {});\n'
              '}\n',
        ),
        isTrue,
      );
    });

    test('finds a program under test/ that does not call it', () {
      expect(
        leavesNetworkOpen(
          'test/support/tool.dart',
          'Future<void> main(List<String> args) async {\n'
              '  await run(args);\n'
              '}\n',
        ),
        isTrue,
      );
    });

    test('does not count a call in a comment', () {
      expect(
        leavesNetworkOpen(
          'test/x_test.dart',
          'void main() {\n'
              '  // $forbid\n'
              '}\n',
        ),
        isTrue,
      );
    });

    test('passes a test file or program that calls it', () {
      expect(
        leavesNetworkOpen('test/x_test.dart', 'void main() {\n  $forbid\n}\n'),
        isFalse,
      );
      expect(
        leavesNetworkOpen(
          'test/support/tool.dart',
          'Future<void> main(List<String> args) async {\n  $forbid\n}\n',
        ),
        isFalse,
      );
    });

    test('passes a library under test/ that is not a program', () {
      expect(
        leavesNetworkOpen(
          'test/support/helper.dart',
          'String helper() => "main()";\n',
        ),
        isFalse,
      );
    });

    group('live suites (#57):', () {
      const live = "@Tags(['live'])\nlibrary;\n\n";
      const body = 'void main() {\n  test("x", () {});\n}\n';

      test('passes a test file under test/live/ tagged live for the whole '
          'file', () {
        expect(
          leavesNetworkOpen('test/live/x_test.dart', '$live$body'),
          isFalse,
        );
        expect(
          leavesNetworkOpen(
            p.join('test', 'live', 'x_test.dart'),
            '// Sends to the own account.\n'
            '@Tags(["live"])\n'
            'library;\n\n'
            '$body',
          ),
          isFalse,
        );
      });

      test('finds a test file under test/live/ without the live tag', () {
        expect(leavesNetworkOpen('test/live/x_test.dart', body), isTrue);
        expect(
          leavesNetworkOpen(
            'test/live/x_test.dart',
            "@Tags(['slow'])\nlibrary;\n\n$body",
          ),
          isTrue,
        );
        expect(
          leavesNetworkOpen(
            'test/live/x_test.dart',
            "@Tags(['live', 'slow'])\nlibrary;\n\n$body",
          ),
          isTrue,
          reason: 'only the live tag alone is recognised',
        );
      });

      test('finds a test file tagged live for a group or a test only', () {
        expect(
          leavesNetworkOpen(
            'test/live/x_test.dart',
            'void main() {\n'
                "  group('x', tags: ['live'], () {});\n"
                '}\n',
          ),
          isTrue,
        );
      });

      test('does not count a live tag in a comment', () {
        expect(
          leavesNetworkOpen('test/live/x_test.dart', '// $live$body'),
          isTrue,
        );
      });

      test('finds a test file tagged live outside test/live/', () {
        expect(leavesNetworkOpen('test/x_test.dart', '$live$body'), isTrue);
        expect(
          leavesNetworkOpen('test/support/live/x_test.dart', '$live$body'),
          isTrue,
        );
      });

      test('finds a program under test/live/ that is not a test file', () {
        expect(
          leavesNetworkOpen(
            'test/live/support/tool.dart',
            '${live}Future<void> main(List<String> args) async {}\n',
          ),
          isTrue,
        );
      });
    });
  });

  test('dart_test.yaml skips the live suites unless the live preset is '
      'chosen (#57)', () {
    final config = loadYaml(File('dart_test.yaml').readAsStringSync()) as Map;
    // `dart test` (CI, the pre-commit hook) skips them without loading them.
    final skip = (config['tags'] as Map)['live']['skip'];
    expect(skip, isA<String>().having((s) => s.trim(), 'reason', isNotEmpty));
    // Nothing else may leave them out or run them: `exclude_tags` would keep
    // the preset from running them, and a default that includes them would
    // run them in `dart test`.
    expect(config.keys, isNot(contains('exclude_tags')));
    expect(config.keys, isNot(contains('include_tags')));
    expect(config.keys, isNot(contains('add_presets')));
    // `dart test -P live` runs them, and only them.
    final preset = (config['presets'] as Map)['live'] as Map;
    expect(preset['include_tags'], 'live');
    expect(preset['paths'], ['test/live']);
    expect((preset['tags'] as Map)['live'], {'skip': false});

    // And there is a live suite for that, under test/live/.
    final suites = Directory(p.join('test', 'live'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => isLiveSuite(file.path, file.readAsStringSync()));
    expect(suites, isNotEmpty);
  });

  group('forbidRealNetwork', () {
    test('refuses a request to another machine before it goes out, and '
        'fails the test that sent it', () async {
      // A client whose test forgot to give it a fake adapter. The host does
      // not exist (.invalid), so even without the guard this sends nothing.
      final client = await SmartschoolClient.create(
        AppCredentials(
          username: 'user',
          password: 'pass',
          mainUrl: 'school.smartschool.invalid',
        ),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);

      // What would fail this test is caught here instead, to be checked.
      final failures = <Object>[];
      Object? thrown;
      await runZonedGuarded(() async {
        try {
          await client.download('/file');
        } catch (e) {
          thrown = e;
        }
      }, (error, _) => failures.add(error));

      final refused = isA<RealNetworkForbidden>().having(
        (e) => e.url,
        'url',
        Uri.parse('https://school.smartschool.invalid/file'),
      );
      // Refused before any lookup of the host: without the guard, the lookup
      // would fail and the client would throw a SmartschoolConnectionError.
      expect(
        thrown,
        isA<DioException>().having((e) => e.error, 'error', refused),
      );
      // The test fails even though the client caught nothing wrong with it.
      expect(failures, [refused]);
    });

    test('lets a request to a server of the test on loopback go out', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..write('hello from ${request.uri.path}')
          ..close();
      });
      // Dio's default adapter, as a client without a fake one uses.
      final dio = Dio();
      addTearDown(dio.close);

      final response = await dio.get<String>(
        'http://127.0.0.1:${server.port}/ping',
      );

      expect(response.statusCode, 200);
      expect(response.data, 'hello from /ping');
    });

    test('takes localhost and loopback addresses for this machine', () {
      for (final host in [
        'localhost',
        'LocalHost',
        '127.0.0.1',
        '127.1.2.3',
        '::1',
      ]) {
        expect(isLoopbackHost(host), isTrue, reason: host);
      }
    });

    test('takes any other host for another machine', () {
      for (final host in [
        'school.smartschool.be',
        'localhost.example.com',
        'mylocalhost',
        '10.0.0.1',
        '192.168.1.1',
        '0.0.0.0',
        '::',
        '2001:db8::1',
      ]) {
        expect(isLoopbackHost(host), isFalse, reason: host);
      }
    });

    test('sends a request to this machine straight to it, whatever proxy '
        'the environment names', () {
      const environment = {
        'http_proxy': 'proxy.example:3128',
        'https_proxy': 'proxy.example:3128',
      };
      for (final url in [
        'http://127.0.0.1:8080/',
        'https://localhost/',
        'http://[::1]:8080/',
      ]) {
        expect(
          NoRealNetwork().findProxyFromEnvironment(Uri.parse(url), environment),
          'DIRECT',
          reason: url,
        );
      }
    });
  });
}
