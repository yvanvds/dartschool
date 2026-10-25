// Tests for issue #160: LvsService, the pupil tracking system (LVS) read as
// the logged-in teacher: find a pupil by name (searchPupils), read the
// overview of the pupil's file (getPupilFile: the file and today's status),
// and checkAccess (the root of the LVS's left tree); the allowlist of its
// requests, and errors that carry no name.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/ (spotlight,
// status, tree; doc/lvs-privacy.md: never trimmed from a live answer), in the
// shapes read from the LVS's own JavaScript and seen live without a pupil
// (2026-10-21): an empty search, the placeholder pupil the LVS answers for a
// made-up pupil ID (`classID` null), the `500` with Smartschool's error page
// that it answers today's status of that ID with, and the root of the tree.
// Smaller variants (an unknown shape, a refusal) are inline below.
//
// The fake Smartschool fails the test on any request that is not one of the
// service's reads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/services/lvs_wire.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

String _fixture(String name) =>
    File('test/fixtures/lvs/$name').readAsStringSync();

ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'application/json',
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
    ...headers,
  },
);

ResponseBody Function() _json(String fixture) =>
    () => _answer(_fixture(fixture));

/// Smartschool's generic error page, as the LVS answered today's status of
/// a made-up pupil ID with it (HTTP 500, seen live).
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

ResponseBody Function() _html(String page, {int status = 200}) =>
    () => _answer(page, status: status, contentType: 'text/html');

/// A GET that the LVS sent on to Smartschool's start page, as the client
/// gives it: the page it ends on, with the redirect it followed.
ResponseBody _followedToStartPage() => _answer(
  '<html><body>Start</body></html>',
  contentType: 'text/html',
)..redirects = [RedirectRecord(302, 'GET', Uri.parse('/?module=Homepage'))];

/// A POST that the LVS sent on to Smartschool's start page: the redirect
/// itself (the client does not follow one after a POST).
ResponseBody _redirectToStartPage() => _answer(
  '',
  status: 302,
  contentType: 'text/html',
  headers: {
    'location': ['/?module=Homepage'],
  },
);

/// A Smartschool whose LVS answers the reads of the service with [answers],
/// by read: `search`, `file`, `status`, `tree`. Any other request fails the
/// test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answers);

  final Map<String, ResponseBody Function()> answers;

  /// Every request that reached it, as `METHOD path?query form`.
  final requests = <String>[];

  /// The headers of each of them, in order, as the adapter sends them, by
  /// their names in lower case.
  final headers = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final data = options.data;
    final form = data is Map ? data : const {};
    headers.add({
      for (final MapEntry(:key, :value) in options.headers.entries)
        key.toLowerCase(): '$value',
    });
    requests.add(
      [
        options.method,
        '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
        if (form.isNotEmpty)
          form.entries.map((e) => '${e.key}=${e.value}').join('&'),
      ].join(' '),
    );
    final query = uri.queryParameters;
    final read = switch ((options.method, uri.path)) {
      ('GET', '/LVS/Spotlight') => 'search',
      ('GET', final path) when path.startsWith('/LVS/Spotlight/') => 'file',
      ('POST', '/LVS/Pupilxhr/getStatusInfo') => 'status',
      ('POST', '/') when query['module'] == 'LVS' => switch (query['file']) {
        'treeBuilder' when !query.containsKey('function') => 'tree',
        _ => null,
      },
      _ => null,
    };
    if (read == null) {
      fail('Not a read of LvsService: ${options.method} ${uri.path}');
    }
    final answer = answers[read];
    if (answer == null) fail('The test gave no answer to the $read read');
    return answer();
  }

  @override
  void close({bool force = false}) {}
}

Future<(_Lvs, LvsService)> _serve(
  Map<String, ResponseBody Function()> answers,
) async {
  final server = _Lvs(answers);
  final client = await SmartschoolClient.create(
    _Credentials(),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  return (server, LvsService(client));
}

/// The fake people, classes and IDs of the fixtures: an error message holds
/// none of them.
const _answerValues = [
  'Janssens',
  'Jan',
  'Peeters',
  'Marie',
  'Lars',
  'Piet',
  'Dupré',
  'Testcategorie',
  'Testsectie',
  'Testrichting',
  'Testcode',
  'Niet beschikbaar',
  '1A',
  '2B',
  '9000',
  '9001',
  '9002',
  '9004',
];

/// A message that quotes nothing of the answers.
Matcher get _quotesNothing =>
    allOf([for (final value in _answerValues) isNot(contains(value))]);

/// A plain [SmartschoolLvsError]: an answer the service cannot use, no
/// refusal, no unknown pupil.
Matcher _unreadable({int? statusCode}) => allOf(
  isNot(isA<SmartschoolLvsAccessDeniedError>()),
  isNot(isA<SmartschoolLvsPupilNotFoundError>()),
  isNot(isA<SmartschoolLvsRequestNotAllowedError>()),
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolLvsError>()
      .having((e) => e.message, 'message', _quotesNothing)
      .having((e) => e.statusCode, 'statusCode', statusCode ?? anything),
);

/// A [SmartschoolLvsAccessDeniedError] for [what].
Matcher _refused(String what) => isA<SmartschoolLvsAccessDeniedError>()
    .having((e) => e.message, 'message', contains('refused $what'))
    .having((e) => e.message, 'message', _quotesNothing);

void main() {
  forbidRealNetwork();

  group('searchPupils', () {
    test(
      'no match: an empty list, from GET /LVS/Spotlight?searchVal=',
      () async {
        final (server, lvs) = await _serve({
          'search': _json('spotlight/search_none.json'),
        });

        final found = await lvs.searchPupils('Aerts');

        expect(found, isEmpty);
        expect(server.requests, ['GET /LVS/Spotlight?searchVal=Aerts']);
      },
    );

    test('one match: the pupil, their class, and the name without the '
        'highlight markup', () async {
      final (server, lvs) = await _serve({
        'search': _json('spotlight/search_one.json'),
      });

      final found = await lvs.searchPupils('  janssens ');

      expect(found, hasLength(1));
      final match = found.single;
      expect(match.pupilId, 900001);
      expect(match.classId, 900101);
      expect(match.name, 'Janssens Jan');
      expect(match.className, '1A');
      // The search text goes out trimmed.
      expect(server.requests, ['GET /LVS/Spotlight?searchVal=janssens']);
    });

    test('several matches, in the LVS\'s order: IDs as numbers or strings, '
        'markup and entities stripped, white space collapsed; the classes the '
        'search also finds are left out', () async {
      final (_, lvs) = await _serve({
        'search': _json('spotlight/search_several.json'),
      });

      final found = await lvs.searchPupils('peeters');

      expect(found.map((m) => m.pupilId), [900002, 900005]);
      expect(found.map((m) => m.classId), [900102, 900103]);
      expect(found.map((m) => m.name), ['Peeters Marie', 'Peeters Lars']);
      expect(found.map((m) => m.className), ['2B', '3C']);
    });

    test('a match prints no value', () async {
      final (_, lvs) = await _serve({
        'search': _json('spotlight/search_one.json'),
      });

      final match = (await lvs.searchPupils('janssens')).single;

      expect('$match', 'LvsPupilMatch(<values hidden>)');
    });

    test('a blank text is an ArgumentError, before anything is sent', () async {
      final (server, lvs) = await _serve({});

      await expectLater(lvs.searchPupils('  '), throwsArgumentError);
      expect(server.requests, isEmpty);
    });

    test('an answer the service cannot read is a SmartschoolLvsError, never '
        'an empty list', () async {
      final answers = <String, ResponseBody Function()>{
        'no list of pupils': () => _answer('{"search":"","classes":[]}'),
        'pupils not a list': () => _answer('{"pupils":{"a":1}}'),
        'not an object': () => _answer('[]'),
        'a pupil without userID': () => _answer(
          '{"pupils":[{"classID":900101,"className":"1A",'
          '"foundName":"<b>Janssens</b> Jan"}]}',
        ),
        'a pupil without foundName': () =>
            _answer('{"pupils":[{"userID":900001,"classID":900101}]}'),
        'not JSON': () => _answer('{"pupils":[{"foundName":"Janssens'),
        'an HTML page': _html('<html><body>Janssens Jan</body></html>'),
        'empty': () => _answer(''),
      };
      for (final MapEntry(key: name, value: answer) in answers.entries) {
        final (_, lvs) = await _serve({'search': answer});
        await expectLater(
          lvs.searchPupils('janssens'),
          throwsA(_unreadable(statusCode: 200)),
          reason: name,
        );
      }
    });

    test('invalid JSON keeps the decoder\'s error as the cause, out of the '
        'message', () async {
      final (_, lvs) = await _serve({
        'search': () => _answer('{"pupils":[{"foundName":"Janssens'),
      });

      await expectLater(
        lvs.searchPupils('janssens'),
        throwsA(
          isA<SmartschoolLvsError>()
              .having((e) => e.cause, 'cause', isA<FormatException>())
              .having((e) => '$e', 'toString()', _quotesNothing),
        ),
      );
    });

    test('another status is a SmartschoolLvsError with it', () async {
      final (_, lvs) = await _serve({'search': _html(_errorPage, status: 500)});

      await expectLater(
        lvs.searchPupils('janssens'),
        throwsA(_unreadable(statusCode: 500)),
      );
    });

    test('a refusal (403, or the start page) is a '
        'SmartschoolLvsAccessDeniedError, never an empty list', () async {
      for (final answer in [
        () => _answer('', status: 403, contentType: 'text/html'),
        _followedToStartPage,
      ]) {
        final (_, lvs) = await _serve({'search': answer});
        await expectLater(
          lvs.searchPupils('janssens'),
          throwsA(_refused('the pupil search')),
        );
      }
    });
  });

  group('getPupilFile', () {
    test('reads the file, then today\'s status, and nothing else', () async {
      final (server, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/both.json'),
      });

      await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      expect(server.requests, [
        'GET /LVS/Spotlight/900001?classID=900101',
        'POST /LVS/Pupilxhr/getStatusInfo pupilID=900001',
      ]);
    });

    test('who, which class, and the class teachers', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/none.json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      expect(file.pupilId, 900001);
      expect(file.classId, 900101);
      expect(file.name, 'Janssens Jan');
      expect(file.className, '1A');
      expect(file.classDescription, 'Testrichting');
      expect(file.teachers.map((t) => t.id), [900201, 900202]);
      expect(file.teachers.map((t) => t.name), [
        'Peeters Piet',
        'Dupré Céline',
      ]);
    });

    test('the sections, with their children at any depth, in the LVS\'s '
        'order', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/none.json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      expect(file.sections.map((s) => s.type), [
        LvsSectionType.items,
        LvsSectionType.supportPlans,
        LvsSectionType.results,
        'testsection',
      ]);
      final notes = file.sections.first;
      expect(notes.id, 900401);
      expect(notes.name, 'Testcategorie');
      expect(notes.hasItems, isTrue);
      expect(notes.children.map((s) => s.id), [900402, 900403]);
      expect(notes.children.first.hasNewItems, isTrue);
      final heading = notes.children.last;
      expect(heading.isTitle, isTrue);
      expect(heading.children.single.id, 900404);
      expect(heading.children.single.hasNewItems, isFalse);

      expect(file.allSections.map((s) => s.id), [
        900401,
        900402,
        900403,
        900404,
        900405,
        0,
        0,
      ]);
    });

    test('a section with its ID as a string and 0/1 flags', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/none.json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      final plans = file.sections[1];
      expect(plans.id, 900405);
      expect(plans.type, 'handelingsplannen');
      expect(plans.hasItems, isFalse);
      expect(plans.hasNewItems, isFalse);
      expect(plans.isTitle, isFalse);
    });

    test('a section of a type the service does not know is kept as it '
        'comes', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/none.json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      final unknown = file.sections.last;
      expect(unknown.type, 'testsection');
      expect(unknown.isKnownType, isFalse);
      expect(unknown.id, 0);
      expect(file.sections[2].isKnownType, isTrue);
    });

    group('today\'s status', () {
      test('none: no half-day', () async {
        final (_, lvs) = await _serve({
          'file': _json('spotlight/pupil_file.json'),
          'status': _json('status/none.json'),
        });

        final status = (await lvs.getPupilFile(
          pupilId: 900001,
          classId: 900101,
        )).todayStatus;

        expect(status.halfDays, isEmpty);
        expect(status.am, isNull);
        expect(status.pm, isNull);
      });

      test('the morning only', () async {
        final (_, lvs) = await _serve({
          'file': _json('spotlight/pupil_file.json'),
          'status': _json('status/am.json'),
        });

        final status = (await lvs.getPupilFile(
          pupilId: 900001,
          classId: 900101,
        )).todayStatus;

        expect(status.halfDays, hasLength(1));
        expect(status.am?.code, 'TA');
        expect(status.am?.name, 'Testcode');
        expect(status.am?.color, 'green');
        expect(status.pm, isNull);
      });

      test('both half-days', () async {
        final (_, lvs) = await _serve({
          'file': _json('spotlight/pupil_file.json'),
          'status': _json('status/both.json'),
        });

        final status = (await lvs.getPupilFile(
          pupilId: 900001,
          classId: 900101,
        )).todayStatus;

        expect(status.halfDays.map((h) => h.partOfDay), ['am', 'pm']);
        expect(status.am?.code, 'TA');
        expect(status.pm?.code, 'TB');
        expect(status.pm?.color, 'red');
      });

      test(
        'a status the service cannot read is a SmartschoolLvsError',
        () async {
          for (final body in [
            '{"partOfDay":"am"}',
            '[{"partOfDay":"am"}]',
            '[{"code":{"code":"TA","name":"Testcode"}}]',
            '[{"partOfDay":"am","code":{"name":"Testcode"}}]',
          ]) {
            final (_, lvs) = await _serve({
              'file': _json('spotlight/pupil_file.json'),
              'status': () => _answer(body),
            });
            await expectLater(
              lvs.getPupilFile(pupilId: 900001, classId: 900101),
              throwsA(_unreadable(statusCode: 200)),
              reason: body,
            );
          }
        },
      );

      test('the 500 with Smartschool\'s error page is a SmartschoolLvsError '
          'with the status', () async {
        final (_, lvs) = await _serve({
          'file': _json('spotlight/pupil_file.json'),
          'status': _html(_errorPage, status: 500),
        });

        await expectLater(
          lvs.getPupilFile(pupilId: 900001, classId: 900101),
          throwsA(_unreadable(statusCode: 500)),
        );
      });
    });

    test(
      'the LVS\'s placeholder pupil is a SmartschoolLvsPupilNotFoundError, '
      'with neither ID in its message; today\'s status is not read',
      () async {
        final (server, lvs) = await _serve({
          'file': _json('spotlight/pupil_not_found.json'),
        });

        await expectLater(
          lvs.getPupilFile(pupilId: 900009, classId: 900109),
          throwsA(
            isA<SmartschoolLvsPupilNotFoundError>()
                .having((e) => e.pupilId, 'pupilId', 900009)
                .having((e) => e.classId, 'classId', 900109)
                .having((e) => e.message, 'message', _quotesNothing)
                .having((e) => e.message, 'message', isNot(contains('900109'))),
          ),
        );
        expect(server.requests, ['GET /LVS/Spotlight/900009?classID=900109']);
      },
    );

    test('a file of another pupil than the one asked for is a '
        'SmartschoolLvsError', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/none.json'),
      });

      await expectLater(
        lvs.getPupilFile(pupilId: 900002, classId: 900101),
        throwsA(_unreadable(statusCode: 200)),
      );
    });

    test('a file the service cannot read is a SmartschoolLvsError', () async {
      final file =
          jsonDecode(_fixture('spotlight/pupil_file.json'))
              as Map<String, dynamic>;
      Map<String, dynamic> changed(void Function(Map<String, dynamic>) edit) {
        final copy = jsonDecode(jsonEncode(file)) as Map<String, dynamic>;
        edit(copy);
        return copy;
      }

      Map<String, dynamic> section(Map<String, dynamic> json) =>
          (json['categories'] as List).first as Map<String, dynamic>;
      Map<String, dynamic> pupil(Map<String, dynamic> json) =>
          json['pupil'] as Map<String, dynamic>;
      final answers = {
        'no categories': changed((j) => j.remove('categories')),
        'no pupil': changed((j) => j.remove('pupil')),
        'a section without type': changed((j) => section(j).remove('type')),
        'a section without id': changed((j) => section(j).remove('id')),
        'a section without name': changed((j) => section(j).remove('name')),
        'a flag that is none': changed((j) => section(j)['hasItems'] = 'x'),
        'children not a list': changed((j) => section(j)['children'] = 1),
        'teachers not a map': changed((j) => pupil(j)['teachers'] = 'x'),
        'a teacher without ID': changed(
          (j) => pupil(j)['teachers'] = {'x': 'Peeters Piet'},
        ),
        'a class ID that is none': changed((j) => pupil(j)['classID'] = 'x'),
        'no name': changed((j) => pupil(j).remove('name')),
      };
      for (final MapEntry(key: name, value: json) in answers.entries) {
        final (_, lvs) = await _serve({
          'file': () => _answer(jsonEncode(json)),
          'status': _json('status/none.json'),
        });
        await expectLater(
          lvs.getPupilFile(pupilId: 900001, classId: 900101),
          throwsA(_unreadable(statusCode: 200)),
          reason: name,
        );
      }
    });

    test('a refusal (403, or the start page) is a '
        'SmartschoolLvsAccessDeniedError', () async {
      for (final answer in [
        () => _answer('', status: 403, contentType: 'text/html'),
        _followedToStartPage,
      ]) {
        final (_, lvs) = await _serve({'file': answer});
        await expectLater(
          lvs.getPupilFile(pupilId: 900001, classId: 900101),
          throwsA(_refused("the pupil's file")),
        );
      }
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _redirectToStartPage,
      });
      await expectLater(
        lvs.getPupilFile(pupilId: 900001, classId: 900101),
        throwsA(_refused("the pupil's status today")),
      );
    });

    test('an ID that is not positive is an ArgumentError, before anything is '
        'sent', () async {
      final (server, lvs) = await _serve({});

      await expectLater(
        lvs.getPupilFile(pupilId: 0, classId: 900101),
        throwsArgumentError,
      );
      await expectLater(
        lvs.getPupilFile(pupilId: 900001, classId: -1),
        throwsArgumentError,
      );
      expect(server.requests, isEmpty);
    });

    test('the file prints counts only', () async {
      final (_, lvs) = await _serve({
        'file': _json('spotlight/pupil_file.json'),
        'status': _json('status/both.json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);

      expect(
        '$file',
        'LvsPupilFile(sections: 7, teachers: 2, todayStatus: 2 half-days)',
      );
      for (final printed in [
        '$file',
        ...file.allSections.map((s) => '$s'),
        ...file.teachers.map((t) => '$t'),
        '${file.todayStatus}',
        ...file.todayStatus.halfDays.map((h) => '$h'),
      ]) {
        expect(printed, _quotesNothing);
      }
    });
  });

  group('checkAccess', () {
    test('true when the LVS answers the root of its class tree, read with '
        'POST /?module=LVS&file=treeBuilder, id 0', () async {
      final (server, lvs) = await _serve({
        'tree': () => _answer(
          _fixture('tree/root.json'),
          contentType: 'text/json; charset=utf-8',
        ),
      });

      expect(await lvs.checkAccess(), isTrue);
      expect(server.requests, ['POST /?module=LVS&file=treeBuilder id=0']);
    });

    test('false when the LVS refuses it (403, or the start page)', () async {
      for (final answer in [
        () => _answer('', status: 403, contentType: 'text/html'),
        _redirectToStartPage,
      ]) {
        final (_, lvs) = await _serve({'tree': answer});
        expect(await lvs.checkAccess(), isFalse);
      }
    });

    test('an answer it cannot read is thrown, not taken for missing '
        'rights', () async {
      for (final answer in [
        _html('<html><body>Klassen</body></html>'),
        () => _answer('[]'),
        () => _answer('[{"attributes":{"rel":"class"}}]'),
        _html(_errorPage, status: 500),
      ]) {
        final (_, lvs) = await _serve({'tree': answer});
        await expectLater(lvs.checkAccess(), throwsA(_unreadable()));
      }
    });
  });

  // Only the reads of the results app go out with its headers (#175,
  // test/lvs_results_test.dart): the LVS answers the Spotlight GETs without
  // them (seen live).
  group("the results app's headers (#175)", () {
    test(
      'the Spotlight GETs go out without X-Requested-With and without a '
      'Content-Type; the POSTs, form-encoded, with X-Requested-With',
      () async {
        final (server, lvs) = await _serve({
          'search': _json('spotlight/search_one.json'),
          'file': _json('spotlight/pupil_file.json'),
          'status': _json('status/none.json'),
          'tree': () => _answer(
            _fixture('tree/root.json'),
            contentType: 'text/json; charset=utf-8',
          ),
        });

        await lvs.searchPupils('janssens');
        await lvs.getPupilFile(pupilId: 900001, classId: 900101);
        await lvs.checkAccess();

        expect(server.requests, [
          'GET /LVS/Spotlight?searchVal=janssens',
          'GET /LVS/Spotlight/900001?classID=900101',
          'POST /LVS/Pupilxhr/getStatusInfo pupilID=900001',
          'POST /?module=LVS&file=treeBuilder id=0',
        ]);
        final [search, file, status, tree] = server.headers;
        for (final get in [search, file]) {
          expect(get.containsKey('x-requested-with'), isFalse);
          expect(get.containsKey('content-type'), isFalse);
        }
        for (final post in [status, tree]) {
          expect(post['x-requested-with'], 'XMLHttpRequest');
          expect(post['content-type'], Headers.formUrlEncodedContentType);
        }
      },
    );
  });

  group('the allowlist', () {
    test('the reads of the service are on it', () {
      expect(
        LvsWire.readOf(
          'GET',
          '/LVS/Spotlight',
          query: const {'searchVal': 'janssens'},
        ),
        same(LvsWire.pupilSearch),
      );
      expect(
        LvsWire.readOf(
          'GET',
          '/LVS/Spotlight/900001',
          query: const {'classID': '900101'},
        ),
        same(LvsWire.pupilFile),
      );
      expect(
        LvsWire.readOf(
          'POST',
          '/LVS/Pupilxhr/getStatusInfo',
          form: const {'pupilID': '900001'},
        ),
        same(LvsWire.todayStatus),
      );
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: const {'module': 'LVS', 'file': 'treeBuilder'},
          form: const {'id': '0'},
        ),
        same(LvsWire.tree),
      );
    });

    test('any other request is refused before it is sent', () async {
      final server = _Lvs({});
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;
      final wire = LvsWire(client);

      const lvs = {'module': 'LVS'};
      final refused =
          <(String, String, Map<String, String>, Map<String, String>)>[
            // Writes next to the reads, some on the same URL (#160).
            ('PUT', '/LVS/Message', const {}, const {}),
            ('GET', '/LVS/Message', const {}, const {}),
            ('PUT', '/LVS/Watch', const {}, const {}),
            (
              'POST',
              '/',
              {
                ...lvs,
                'file': 'jqDispatcher_settings',
                'function': 'setLastPupil',
              },
              const {'pupilID': '900001'},
            ),
            ('POST', '/LVS/Itemxhr/setItemViewState', const {}, const {}),
            ('POST', '/LVS/Pupilxhr/saveKeyword', const {}, const {}),
            ('POST', '/LVS/Pupilxhr/getAgendaInfo', const {}, const {}),
            (
              'POST',
              '/',
              {...lvs, 'file': 'dispatcher'},
              const {'command': ''},
            ),
            // The reads, but not as the service sends them.
            ('POST', '/LVS/Spotlight', const {'searchVal': 'x'}, const {}),
            ('GET', '/LVS/Spotlight', const {'type': 'assign'}, const {}),
            ('GET', '/LVS/Spotlight', const {'catID': '900401'}, const {}),
            ('GET', '/LVS/Spotlight/0', const {'classID': '900101'}, const {}),
            ('GET', '/LVS/Spotlight/77/edit', const {}, const {}),
            ('GET', '/LVS/Spotlight/../Message', const {}, const {}),
            ('GET', '/LVS/Pupilxhr/getStatusInfo', const {}, const {}),
            (
              'POST',
              '/LVS/Pupilxhr/getStatusInfo',
              const {},
              const {'pupilID': '900001', 'save': '1'},
            ),
            (
              'POST',
              '/',
              {...lvs, 'file': 'treeBuilder', 'function': 'adminTree'},
              const {'id': '0'},
            ),
            ('POST', '/', const {'file': 'treeBuilder'}, const {'id': '0'}),
          ];
      for (final (method, path, query, form) in refused) {
        await expectLater(
          wire.send(method, path, query: query, form: form),
          throwsA(
            isA<SmartschoolLvsRequestNotAllowedError>()
                .having((e) => e.method, 'method', method)
                .having((e) => e.path, 'path', path)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Nothing was sent'),
                )
                .having((e) => e.message, 'message', isNot(contains('900001'))),
          ),
          reason: '$method $path $query',
        );
      }
      expect(server.requests, isEmpty);
    });
  });

  group('a search text is left out of the client\'s errors', () {
    test('a session refused even after logging in again', () async {
      final server = _RefusingSmartschool();
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;

      await expectLater(
        LvsService(client).searchPupils('Janssens Jan'),
        throwsA(
          isA<SmartschoolSessionExpiredError>()
              .having((e) => e.message, 'message', contains('/LVS/Spotlight'))
              .having(
                (e) => e.message,
                'message',
                contains('searchVal=<searchVal>'),
              )
              .having((e) => e.message, 'message', isNot(contains('Janssens'))),
        ),
      );
      // It did log in, and retried the search once.
      expect(
        server.requests.where((r) => r.startsWith('GET /LVS/Spotlight')),
        hasLength(2),
      );
    });

    test('a client disposed while the search runs', () async {
      final arrived = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // The server never answers: the search runs until the client is
      // disposed, which drops the connection.
      server.listen((_) => arrived.complete());
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      client.dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
      addTearDown(() async {
        await client.dispose();
        await server.close(force: true);
      });

      final search = LvsService(client).searchPupils('Janssens Jan');
      await arrived.future;
      await client.dispose();

      await expectLater(
        search,
        throwsA(
          isA<SmartschoolClientDisposedError>()
              .having((e) => e.message, 'message', contains('/LVS/Spotlight'))
              .having(
                (e) => e.message,
                'message',
                contains('searchVal=<searchVal>'),
              )
              .having((e) => e.message, 'message', isNot(contains('Janssens'))),
        ),
      );
    });
  });

  // The plain text of every HTML the LVS services read (#171): the notes'
  // rich texts, the support plans' texts, the absences' motivations; their
  // tests through LvsService are in the test files of those reads.
  group('LvsWire.plainText', () {
    test('a line break starts a new line', () {
      expect(
        LvsWire.plainText('<p>Testtekst met<br>twee regels</p>'),
        'Testtekst met\ntwee regels',
      );
      expect(LvsWire.plainText('Test<br/>regel'), 'Test\nregel');
    });

    test('each block starts a new line: paragraphs, divisions, items of a '
        'list, rows of a table, headings, and the other blocks', () {
      expect(
        LvsWire.plainText('<p>Eerste testalinea.</p><p>Tweede.</p>'),
        'Eerste testalinea.\nTweede.',
      );
      for (final block in [
        'p',
        'div',
        'li',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'blockquote',
        'pre',
        'dt',
        'dd',
        'section',
        'article',
        'header',
        'footer',
        'address',
        'figcaption',
      ]) {
        expect(
          LvsWire.plainText('Test<$block>een</$block><$block>twee</$block>na'),
          'Test\neen\ntwee\nna',
          reason: block,
        );
      }
      expect(
        LvsWire.plainText('<ul><li>Testpunt een</li><li>twee</li></ul>verder'),
        'Testpunt een\ntwee\nverder',
      );
      expect(
        LvsWire.plainText('<ol><li>Test</li></ol><dl><dt>een</dt></dl>'),
        'Test\neen',
      );
      expect(LvsWire.plainText('Test<hr>regel'), 'Test\nregel');
    });

    test('the cells of a row stay on its line, apart', () {
      expect(
        LvsWire.plainText(
          '<table><thead><tr><th>Testkop</th><th>twee</th></tr></thead>'
          '<tbody><tr><td>Testcel</td><td>twee</td></tr>'
          '<tr><td>drie</td></tr></tbody></table>',
        ),
        'Testkop twee\nTestcel twee\ndrie',
      );
    });

    test('inline elements do not split a word, nor start a line', () {
      expect(LvsWire.plainText('<b>Jan</b>ssens'), 'Janssens');
      expect(
        LvsWire.plainText('<span>Test</span><i>tekst</i> met <a>een</a> link'),
        'Testtekst met een link',
      );
    });

    test('white space collapsed within a line; no empty lines, nothing before '
        'or after', () {
      expect(
        LvsWire.plainText(
          '\n  <p>  Testtekst\n   over\ttwee  </p>\n\n  <p>&nbsp;</p>'
          '<p></p><br><br>  <div> <p>regels.<br></p> </div>\n',
        ),
        'Testtekst over twee\nregels.',
      );
      // CRLF line ends of the source too: white space, no line of their own.
      expect(
        LvsWire.plainText(
          '<p>Testtekst\r\nover twee</p>\r\n\r\n<p>regels.<br>\r\n</p>\r\n',
        ),
        'Testtekst over twee\nregels.',
      );
      expect(
        LvsWire.plainText('Testtekst\r\nzonder opmaak'),
        'Testtekst zonder opmaak',
      );
      expect(LvsWire.plainText('<p>&nbsp;</p><br>'), '');
      expect(LvsWire.plainText(''), '');
    });

    test('entities decoded; a text without HTML has its white space '
        'collapsed, as HTML does', () {
      expect(
        LvsWire.plainText('<p>Test &amp; meer &lt;b&gt;</p>'),
        'Test & meer <b>',
      );
      expect(
        LvsWire.plainText('  Testtekst\n zonder   opmaak '),
        'Testtekst zonder opmaak',
      );
    });
  });
}

/// A Smartschool that refuses every LVS request with a bare `401`, also
/// after the client logged in again (password and 2FA), as an expired
/// session it does not take into account.
class _RefusingSmartschool implements HttpClientAdapter {
  final requests = <String>[];
  bool _passwordDone = false;
  bool _twoFaDone = false;

  static const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final path = uri.path;
    requests.add('${options.method} $path');
    if (options.method == 'POST' && path == '/login') {
      _passwordDone = true;
      return _answer(
        '',
        status: 302,
        contentType: 'text/html',
        headers: {
          'location': ['/'],
        },
      );
    }
    if (path == '/2fa/api/v1/config') {
      return _answer(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _twoFaDone = true;
      return _answer('{"success":true,"redirectTo":"/"}');
    }
    if (path.startsWith('/LVS/')) {
      return _answer('', status: 401, contentType: 'text/html');
    }
    // A page: where the session is in the login chain.
    final at = !_passwordDone
        ? '/login'
        : !_twoFaDone
        ? '/2fa'
        : path;
    final page = _answer(
      at == '/login' ? _loginPage : '<html><body>$at</body></html>',
      contentType: 'text/html',
    );
    if (at != path) {
      page.redirects = [
        RedirectRecord(302, 'GET', Uri.parse('https://$_host$at')),
      ];
    }
    return page;
  }

  @override
  void close({bool force = false}) {}
}
