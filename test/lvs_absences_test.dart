// Tests for issue #164: a pupil's absences in the LVS, read as the logged-in
// teacher through LvsService.getAbsences: the half-days with an absence code
// in a school year, grouped by period, with the code's description and
// colour and the motivation (HTML as plain text), and the totals per code;
// no absences; the shapes the web client takes (a period as a list, keys it
// leaves out); refusals and unknown shapes as errors that carry no value;
// the allowlist that keeps the section's other calls out.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/absences/
// (doc/lvs-privacy.md: never trimmed from a live answer), in the shape the
// LVS's JavaScript reads (2026-10-21); a real pupil's answer is the
// developer's capture step (#168). Smaller variants are inline below.
//
// The fake Smartschool fails the test on any request that is not the
// service's read of the absences.
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
    File('test/fixtures/lvs/absences/$name').readAsStringSync();

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

/// An answer of the fixture [name].
ResponseBody Function() _file(String name) =>
    () => _answer(_fixture(name));

/// An answer of [json], encoded.
ResponseBody Function() _of(Object? json) =>
    () => _answer(jsonEncode(json));

/// A Smartschool whose LVS answers the read of the absences with [answer].
/// Any other request fails the test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answer);

  final ResponseBody Function()? answer;

  /// Every request that reached it, as `METHOD path?query`.
  final requests = <String>[];

  /// The form of each of them, in order.
  final forms = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(
      '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    );
    final data = options.data;
    forms.add(data is Map ? data.cast<String, String>() : const {});
    if (options.method != 'POST' ||
        uri.path != '/LVS/Pupilpresences' ||
        uri.hasQuery) {
      fail('Not the read of the absences: ${options.method} $uri');
    }
    final answer = this.answer;
    if (answer == null) fail('The test gave no answer to the absences');
    return answer();
  }

  @override
  void close({bool force = false}) {}
}

Future<(_Lvs, LvsService)> _serve([ResponseBody Function()? answer]) async {
  final server = _Lvs(answer);
  final client = await SmartschoolClient.create(
    _Credentials(),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  return (server, LvsService(client));
}

/// The absences of pupil 900001 in class 900101.
Future<LvsAbsences> _read(LvsService lvs) =>
    lvs.getAbsences(pupilId: 900001, classId: 900101);

/// The fake labels, codes, texts and days of the fixtures: an error message
/// and a model's `toString()` hold none of them.
const _answerValues = [
  'Test',
  'test',
  'yellow',
  '2030',
  '2031',
  'Volledige',
  'middag',
  '9001',
];

/// A text that quotes nothing of the answers.
Matcher get _quotesNothing =>
    allOf([for (final value in _answerValues) isNot(contains(value))]);

/// A plain [SmartschoolLvsError]: an answer the service cannot use, no
/// refusal.
Matcher _unreadable({int? statusCode}) => allOf(
  isNot(isA<SmartschoolLvsAccessDeniedError>()),
  isNot(isA<SmartschoolLvsPupilNotFoundError>()),
  isNot(isA<SmartschoolLvsRequestNotAllowedError>()),
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolLvsError>()
      .having((e) => e.message, 'message', _quotesNothing)
      .having((e) => '$e', 'toString()', _quotesNothing)
      .having((e) => e.statusCode, 'statusCode', statusCode ?? anything),
);

/// An answer the service does not recognise: a [_unreadable] error that
/// says so.
Matcher get _unknownShape => allOf(
  _unreadable(statusCode: 200),
  isA<SmartschoolLvsError>().having(
    (e) => e.message,
    'message',
    contains("the pupil's absences in a shape the service does not recognise"),
  ),
);

/// A [SmartschoolLvsAccessDeniedError] for the absences.
Matcher get _refused => isA<SmartschoolLvsAccessDeniedError>()
    .having(
      (e) => e.message,
      'message',
      contains("refused the pupil's absences"),
    )
    .having((e) => e.message, 'message', _quotesNothing);

/// A half-day of an inline answer, with code [code].
Map<String, Object?> _halfDay([String code = 'TA']) => {
  'formattedDate': 'ma 16/09/2030',
  'partOfDay': 'Volledige dag',
  'code': code,
  'codeColor': 'red',
  'codeDescr': 'Testcode',
  'motivation': 'Testmotivatie.',
};

/// An answer with [presences], as the LVS sends it.
Map<String, Object?> _withPresences(Object? presences) => {
  'presences': presences,
  'lng_noresults': 'Geen resultaten',
  'year_label': '2030 - 2031',
};

void main() {
  forbidRealNetwork();

  group('getAbsences', () {
    test('one POST of the absences with the pupil and the class, as the web '
        'client opens the section; nothing else', () async {
      final (server, lvs) = await _serve(_file('absences.json'));

      await _read(lvs);

      expect(server.requests, ['POST /LVS/Pupilpresences']);
      expect(server.forms.single, {'pupilID': '900001', 'groupID': '900101'});
    });

    test("the periods in the LVS's order, each with its absences day after "
        'day: a whole day or a half-day, with the code, its description and '
        'colour, as the LVS gives them', () async {
      final (_, lvs) = await _serve(_file('absences.json'));

      final absences = await _read(lvs);

      expect(absences.yearLabel, '2030 - 2031');
      expect(absences.isEmpty, isFalse);
      expect(absences.periods.map((p) => p.label), [
        'Testperiode',
        'Testperiode 2',
      ]);
      expect(absences.periods.map((p) => p.absences.length), [3, 2]);

      final all = absences.absences;
      expect(all.map((a) => a.date), [
        DateTime.utc(2030, 9, 16),
        DateTime.utc(2030, 10, 2),
        DateTime.utc(2030, 10, 2),
        DateTime.utc(2031, 1, 13),
        DateTime.utc(2031, 2, 3),
      ]);
      expect(all.map((a) => a.dateKey), [
        '2030-09-16',
        '2030-10-02',
        '2030-10-02',
        '2031-01-13',
        '2031-02-03',
      ]);
      expect(all.map((a) => a.dayPart), [
        null,
        DayPart.morning,
        DayPart.afternoon,
        DayPart.afternoon,
        null,
      ]);
      expect(all.map((a) => a.isFullDay), [true, false, false, false, true]);
      expect(all.map((a) => a.halfDays), [2, 1, 1, 1, 2]);
      expect(all.map((a) => a.code), ['TA', 'TB', 'TA', 'TB', 'TA']);
      expect(all.map((a) => a.codeDescription), [
        'Testcode',
        'Testcode 2',
        'Testcode',
        'Testcode 2',
        'Testcode',
      ]);
      expect(all.map((a) => a.color), [
        'red',
        'yellow',
        'red',
        'yellow',
        'red',
      ]);
      expect(all.first.formattedDate, 'ma 16/09/2030');
      expect(all.map((a) => a.partOfDayLabel), [
        'Volledige dag',
        'Voormiddag',
        'Namiddag',
        'Namiddag',
        'Volledige dag',
      ]);
    });

    test('the motivation as plain text, its HTML kept; empty when there is '
        'none', () async {
      final (_, lvs) = await _serve(_file('absences.json'));

      final all = (await _read(lvs)).absences;

      expect(all.map((a) => a.motivation), [
        'Testmotivatie: thuis gebleven.',
        '',
        'Testmotivatie in platte tekst.',
        'Testmotivatie met opmaak & een teken.',
        '',
      ]);
      expect(all.map((a) => a.motivationHtml), [
        '<p>Testmotivatie: <b>thuis</b> gebleven.</p>',
        '',
        'Testmotivatie in platte tekst.',
        '<p>Testmotivatie met <i>opmaak</i> &amp; een teken.</p>',
        '',
      ]);
    });

    test('the motivation as plain text keeps its lines: a line break and each '
        'block of its HTML start a new line (#171)', () async {
      final (_, lvs) = await _serve(_file('absences_lines.json'));

      final absence = (await _read(lvs)).absences.single;

      expect(
        absence.motivation,
        'Testmotivatie met\ntwee regels\nTweede testalinea.',
      );
      expect(
        absence.motivationHtml,
        '<p>Testmotivatie met<br>twee regels</p><p>Tweede testalinea.</p>',
      );
    });

    test('the totals per code, in the order a code first comes: the '
        'absences and the half-days (a whole day counts two)', () async {
      final (_, lvs) = await _serve(_file('absences.json'));

      final absences = await _read(lvs);
      final totals = absences.totalsByCode;

      expect(totals.map((t) => t.code), ['TA', 'TB']);
      expect(totals.map((t) => t.codeDescription), ['Testcode', 'Testcode 2']);
      expect(totals.map((t) => t.color), ['red', 'yellow']);
      expect(totals.map((t) => t.count), [3, 2]);
      expect(totals.map((t) => t.halfDays), [5, 2]);
      expect(absences.halfDays, 7);
      expect(absences.periods.map((p) => p.halfDays), [4, 3]);
    });

    test('no absences (PHP sends the empty map as []): no periods, the '
        'school year kept', () async {
      final (_, lvs) = await _serve(_file('none.json'));

      final absences = await _read(lvs);

      expect(absences.periods, isEmpty);
      expect(absences.absences, isEmpty);
      expect(absences.isEmpty, isTrue);
      expect(absences.totalsByCode, isEmpty);
      expect(absences.halfDays, 0);
      expect(absences.yearLabel, '2030 - 2031');
    });

    test('presences that the web client takes for none (null, false, an '
        'empty map, or none at all next to the year): no periods', () async {
      final answers = <Object?>[
        _withPresences(null),
        _withPresences(false),
        _withPresences(<String, Object?>{}),
        {'year_label': '2030 - 2031', 'lng_noresults': 'Geen resultaten'},
      ];
      for (final answer in answers) {
        final (_, lvs) = await _serve(_of(answer));
        final absences = await _read(lvs);
        expect(absences.periods, isEmpty, reason: '$answer');
        expect(absences.yearLabel, '2030 - 2031', reason: '$answer');
      }
    });

    test('a period without days is kept, empty; a period whose days come as '
        'a list has no day keys', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            'Testperiode': <String, Object?>{},
            'Testperiode 2': [
              {'am': _halfDay('TA')},
              {'pm': _halfDay('TB')},
            ],
          }),
        ),
      );

      final absences = await _read(lvs);

      expect(absences.periods.map((p) => p.label), [
        'Testperiode',
        'Testperiode 2',
      ]);
      expect(absences.periods.first.absences, isEmpty);
      final listed = absences.periods.last.absences;
      expect(listed.map((a) => a.code), ['TA', 'TB']);
      expect(listed.map((a) => a.dateKey), ['', '']);
      expect(listed.map((a) => a.date), [null, null]);
    });

    test('a day key that is not a day YYYY-MM-DD is kept, without a date; '
        'the keys of a day other than full, am and pm are left out, as the '
        'web client leaves them out', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            'Testperiode': {
              'Testdag': {'full': _halfDay()},
              '2030-02-30': {'am': _halfDay()},
              '2030-09-17': {
                'none': _halfDay('TB'),
                'pm': _halfDay('TA'),
                'am': _halfDay('TB'),
              },
              '2030-09-18': <Object?>[],
            },
          }),
        ),
      );

      final all = (await _read(lvs)).absences;

      expect(all.map((a) => a.dateKey), [
        'Testdag',
        '2030-02-30',
        '2030-09-17',
        '2030-09-17',
      ]);
      expect(all.map((a) => a.date), [
        null,
        null,
        DateTime.utc(2030, 9, 17),
        DateTime.utc(2030, 9, 17),
      ]);
      // In the answer's order, as the web client shows them.
      expect(all.map((a) => a.dayPart), [
        null,
        DayPart.morning,
        DayPart.afternoon,
        DayPart.morning,
      ]);
      expect(all.map((a) => a.code), ['TA', 'TA', 'TA', 'TB']);
    });

    test('a half-day with only its code: the rest empty, no colour; a code '
        'that is a number is taken as its text', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            'Testperiode': {
              '2030-09-16': {
                'full': {'code': 'TA'},
                'pm': {'code': 7, 'codeColor': ''},
              },
            },
          }),
        ),
      );

      final all = (await _read(lvs)).absences;

      expect(all.map((a) => a.code), ['TA', '7']);
      expect(all.map((a) => a.color), [null, null]);
      expect(all.map((a) => a.codeDescription), ['', '']);
      expect(all.map((a) => a.motivation), ['', '']);
      expect(all.map((a) => a.formattedDate), ['', '']);
      expect(all.map((a) => a.partOfDayLabel), ['', '']);
    });

    test('an answer without what the service needs, or with a value of '
        'another type, is a SmartschoolLvsError that names the field, not '
        'the value', () async {
      final broken = <Object?>[
        ['Testperiode'],
        {'lng_noresults': 'Geen resultaten'},
        _withPresences('Testperiode'),
        _withPresences(['Testperiode']),
        _withPresences({'Testperiode': 'Testdag'}),
        _withPresences({
          'Testperiode': {
            '2030-09-16': ['Testdag'],
          },
        }),
        _withPresences({
          'Testperiode': {
            '2030-09-16': {'full': 'TA'},
          },
        }),
        _withPresences({
          'Testperiode': {
            '2030-09-16': {
              'full': {..._halfDay(), 'code': null},
            },
          },
        }),
        _withPresences({
          'Testperiode': {
            '2030-09-16': {
              'full': {
                ..._halfDay(),
                'code': {'TA': 1},
              },
            },
          },
        }),
        _withPresences({
          'Testperiode': {
            '2030-09-16': {
              'am': {
                ..._halfDay(),
                'motivation': ['Testmotivatie.'],
              },
            },
          },
        }),
        {
          ..._withPresences(<Object?>[]),
          'year_label': {'Test': 2030},
        },
      ];
      for (final answer in broken) {
        final (_, lvs) = await _serve(_of(answer));
        await expectLater(
          _read(lvs),
          throwsA(_unknownShape),
          reason: '$answer',
        );
      }
    });

    test('a 403 is a SmartschoolLvsAccessDeniedError, not an empty '
        'list', () async {
      final (_, lvs) = await _serve(() => _answer('', status: 403));

      await expectLater(_read(lvs), throwsA(_refused));
    });

    test("a redirect to Smartschool's start page is a "
        'SmartschoolLvsAccessDeniedError', () async {
      final (_, lvs) = await _serve(
        () => _answer(
          '',
          status: 302,
          headers: {
            'location': ['/?module=Homepage'],
          },
        ),
      );

      await expectLater(_read(lvs), throwsA(_refused));
    });

    test("Smartschool's error page with a 500, as the LVS answered a "
        'made-up pupil in a made-up class (seen live), is a '
        'SmartschoolLvsError with the status', () async {
      final (_, lvs) = await _serve(
        () => _answer(
          '<!DOCTYPE html><html><body><h1>Oeps, er ging iets mis</h1>'
          '</body></html>',
          status: 500,
          contentType: 'text/html; charset=UTF-8',
        ),
      );

      await expectLater(_read(lvs), throwsA(_unreadable(statusCode: 500)));
    });

    test('an HTML page, an answer that is not JSON, or an empty answer is a '
        'SmartschoolLvsError that quotes nothing', () async {
      for (final body in [
        '<html><body>Testpagina 2030</body></html>',
        '{"Testperiode": ',
        '"Testperiode"',
        '',
      ]) {
        final (_, lvs) = await _serve(() => _answer(body));
        await expectLater(
          _read(lvs),
          throwsA(_unreadable(statusCode: 200)),
          reason: body,
        );
      }
    });

    test('an ID that is not positive is an ArgumentError, before anything is '
        'sent', () async {
      final (server, lvs) = await _serve();

      for (final (pupilId, classId) in [(0, 900101), (900001, -1), (-5, 0)]) {
        await expectLater(
          lvs.getAbsences(pupilId: pupilId, classId: classId),
          throwsArgumentError,
          reason: '$pupilId $classId',
        );
      }
      expect(server.requests, isEmpty);
    });

    test('the models print counts and the part of the day only', () async {
      final (_, lvs) = await _serve(_file('absences.json'));

      final absences = await _read(lvs);
      final printed = <String>[
        '$absences',
        for (final period in absences.periods) '$period',
        for (final absence in absences.absences) '$absence',
        for (final total in absences.totalsByCode) '$total',
      ];

      expect(printed, everyElement(_quotesNothing));
      expect(
        printed,
        containsAll([
          'LvsAbsences(periods: 2, absences: 5, halfDays: 7)',
          'LvsAbsencePeriod(absences: 3)',
          'LvsAbsencePeriod(absences: 2)',
          'LvsAbsence(full)',
          'LvsAbsence(am)',
          'LvsAbsence(pm)',
          'LvsAbsenceTotal(count: 3, halfDays: 5)',
          'LvsAbsenceTotal(count: 2, halfDays: 2)',
        ]),
      );
    });
  });

  group('the allowlist of the absences', () {
    test('the read of the service is on it', () {
      expect(
        LvsWire.readOf(
          'POST',
          '/LVS/Pupilpresences',
          form: const {'pupilID': '900001', 'groupID': '900101'},
        ),
        same(LvsWire.absences),
      );
    });

    test("the section's charts, the class view, the older route, and the "
        'read with more or as a GET, are refused before they are '
        'sent', () async {
      final server = _Lvs(null);
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;
      final wire = LvsWire(client);

      const pupil = {'pupilID': '900001', 'groupID': '900101'};
      final refused =
          <(String, String, Map<String, String>, Map<String, String>)>[
            ('POST', '/LVS/Pupilpresencesgraphs', const {}, pupil),
            ('POST', '/LVS/Classpresences', const {}, const {'groupID': '1'}),
            ('POST', '/LVS/Classpresencesgraphs', const {}, const {}),
            (
              'POST',
              '/',
              const {
                'module': 'LVS',
                'file': 'jqDispatcher_presence',
                'function': 'getPupilPresences',
              },
              const {...pupil, 'type': 'official'},
            ),
            ('GET', '/LVS/Pupilpresences', const {}, const {}),
            ('GET', '/LVS/Pupilpresences', pupil, const {}),
            ('POST', '/LVS/Pupilpresences', const {}, {...pupil, 'save': '1'}),
            (
              'POST',
              '/LVS/Pupilpresences',
              const {'schoolyear': '2030'},
              pupil,
            ),
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
          reason: '$method $path $query $form',
        );
      }
      expect(server.requests, isEmpty);
    });
  });
}
