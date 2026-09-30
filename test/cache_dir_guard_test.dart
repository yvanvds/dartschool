// Guard for #49: no test may create a client in the default cache folder.
//
// Without a `cacheDir`, `SmartschoolClient.create` keeps its cookies in the
// real `~/.cache/smartschool/<username>` of whoever runs the tests. This test
// reads every Dart file under `test/` and fails on a client created there
// without one: a `SmartschoolClient.create` call that has no `cacheDir`
// argument, or a `DevInspector.create` call, which cannot take one. Give such
// a client `cacheDir: tempCacheDir()` (support/temp_cache_dir.dart).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Files that may create a client in the default cache folder, with why.
const _allowed = <String, String>{
  'test/support/default_cache_dir_client.dart':
      'session_cache_dir_test.dart runs it as a separate process whose HOME '
      'and USERPROFILE are temporary folders, to test the default folder',
};

/// A call that creates a client, up to and including its `(`.
final _createCall = RegExp(
  r'\b(SmartschoolClient|DevInspector)\s*\.\s*create\s*\(',
);

/// A `cacheDir` named argument.
final _cacheDirArgument = RegExp(r'\bcacheDir\s*:');

/// The calls in [source] that create a client in the default cache folder,
/// each as `line <n>: <the line it starts on>`.
///
/// A call on a line that starts as a `//` comment is not counted.
List<String> defaultCacheDirCalls(String source) {
  final found = <String>[];
  for (final call in _createCall.allMatches(source)) {
    final lineStart = source.lastIndexOf('\n', call.start) + 1;
    if (source.substring(lineStart, call.start).trimLeft().startsWith('//')) {
      continue;
    }
    final takesCacheDir =
        call.group(1) == 'SmartschoolClient' &&
        _cacheDirArgument.hasMatch(_topLevelArguments(source, call.end));
    if (takesCacheDir) continue;

    var lineEnd = source.indexOf('\n', call.start);
    if (lineEnd == -1) lineEnd = source.length;
    final line = '\n'.allMatches(source.substring(0, call.start)).length + 1;
    found.add('line $line: ${source.substring(lineStart, lineEnd).trim()}');
  }
  return found;
}

/// The arguments of the call whose `(` ends just before [start], without
/// what is nested in brackets inside them, so that a `cacheDir:` passed to
/// something else in the arguments does not count.
String _topLevelArguments(String source, int start) {
  final arguments = StringBuffer();
  var depth = 1;
  for (var i = start; i < source.length && depth > 0; i++) {
    final char = source[i];
    if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      depth--;
    } else if (depth == 1) {
      arguments.write(char);
    }
  }
  return arguments.toString();
}

/// [path] relative to the package root, with `/` separators on every
/// platform.
String _packagePath(String path) => p.split(p.relative(path)).join('/');

void main() {
  test('no test creates a client in the default cache folder', () {
    final files =
        Directory('test')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    // Run from the package root (as `dart test` does), there is plenty to
    // check; finding nothing would make this test pass for nothing.
    expect(files, isNotEmpty, reason: 'no Dart files found under test/');

    var calls = 0;
    final offenders = <String>[];
    for (final file in files) {
      final path = _packagePath(file.path);
      final source = file.readAsStringSync();
      calls += _createCall.allMatches(source).length;
      if (_allowed.containsKey(path)) continue;
      for (final call in defaultCacheDirCalls(source)) {
        offenders.add('$path $call');
      }
    }

    expect(calls, greaterThan(0), reason: 'no client creation found at all');
    expect(
      offenders,
      isEmpty,
      reason:
          'These create a client that keeps its cookies in the real '
          '~/.cache/smartschool of whoever runs the tests. Pass '
          '`cacheDir: tempCacheDir()` (test/support/temp_cache_dir.dart):\n'
          '${offenders.join('\n')}',
    );
  });

  test('the files allowed to use the default cache folder exist', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path is gone');
    }
  });

  group('defaultCacheDirCalls', () {
    // Built from pieces, so that this file holds no call itself and the scan
    // above checks it like any other test file.
    const client = 'SmartschoolClient.create';
    const inspector = 'DevInspector.create';

    test('finds a call without a cacheDir', () {
      expect(
        defaultCacheDirCalls(
          'void main() async {\n'
          '  final client = await $client(credentials);\n'
          '}\n',
        ),
        ['line 2: final client = await $client(credentials);'],
      );
    });

    test('finds a call split over lines without a cacheDir', () {
      expect(
        defaultCacheDirCalls(
          'final client = await $client(\n'
          '  credentials,\n'
          '  loginCooldown: Duration.zero,\n'
          ');\n',
        ),
        hasLength(1),
      );
    });

    test('passes a call with a cacheDir, on one line or over several', () {
      expect(
        defaultCacheDirCalls(
          'final a = await $client(credentials, cacheDir: tempCacheDir());\n'
          'final b = await $client(\n'
          '  _credentials(),\n'
          '  loginCooldown: const Duration(minutes: 1),\n'
          '  cacheDir: p.join(tempDir.path, "cache"),\n'
          ');\n',
        ),
        isEmpty,
      );
    });

    test('does not count a cacheDir given to something inside the call', () {
      expect(
        defaultCacheDirCalls(
          'final client = await $client(credentials(cacheDir: dir));\n',
        ),
        hasLength(1),
      );
    });

    test('finds every call of a file, not just the first', () {
      expect(
        defaultCacheDirCalls(
          'final a = await $client(credentials, cacheDir: dir);\n'
          'final b = await $client(credentials);\n'
          'final c = await $client(credentials);\n',
        ),
        [
          'line 2: final b = await $client(credentials);',
          'line 3: final c = await $client(credentials);',
        ],
      );
    });

    test('finds DevInspector.create, which cannot take a cacheDir', () {
      expect(
        defaultCacheDirCalls('final inspector = await $inspector(creds);\n'),
        hasLength(1),
      );
    });

    test('skips a call in a line comment', () {
      expect(
        defaultCacheDirCalls(
          '// final client = await $client(credentials);\n'
          '  /// await $client(credentials);\n',
        ),
        isEmpty,
      );
    });
  });
}
