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
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

/// A top-level `main` declaration.
final _mainDeclaration = RegExp(r'^[\w<>?, ]*\bmain\s*\(', multiLine: true);

/// A line that calls [forbidRealNetwork] (not a `//` comment).
final _forbidCall = RegExp(r'^\s*forbidRealNetwork\(\);', multiLine: true);

/// Whether [source], a Dart file at [path] under `test/`, is a program that
/// does not call [forbidRealNetwork].
bool leavesNetworkOpen(String path, String source) {
  final isProgram =
      path.endsWith('_test.dart') || _mainDeclaration.hasMatch(source);
  return isProgram && !_forbidCall.hasMatch(source);
}

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
