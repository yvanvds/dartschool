// Tests for issues #164 and #176: a pupil's absences in the LVS, read as the
// logged-in teacher through LvsService.getAbsences: the half-days with an
// absence code, grouped by school year (the periods of the answer), each
// dated by its shown day (`formattedDate`: `vr 23 oktober 2030`, the month
// by the answer's `lng_months` or its Dutch name, the year from the school
// year when the text has none; no date when it does not parse), with the
// code, its key, its description and colour and the motivation (plain text
// or HTML, as plain text), and the totals per code; no absences; the shapes
// the web client takes (the class view's days keyed `YYYY-MM-DD`, keys it
// leaves out); refusals and unknown shapes as errors that carry no value;
// the allowlist that keeps the section's other calls out; and a pupil the
// LVS does not know (#190): on HTTP 500 for the absences, the read of the
// pupil's file without today's status, whose placeholder pupil is a
// SmartschoolLvsPupilNotFoundError.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/absences/
// (doc/lvs-privacy.md: never trimmed from a live answer), in the shape of a
// real pupil's answer as the developer captured it in a browser (#176,
// shapes only): per school year a list of days; and, for the file, those of
// test/fixtures/lvs/spotlight/. Smaller variants are inline below.
//
// The fake Smartschool fails the test on any request that is not the
// service's read of the absences or of the pupil's file.
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

/// A fixture of the pupil's file (#190): `pupil_file.json` (pupil 900001 in
/// class 900101) or `pupil_not_found.json` (the LVS's placeholder for pupil
/// 900009).
ResponseBody Function() _spotlight(String name) =>
    () => _answer(File('test/fixtures/lvs/spotlight/$name').readAsStringSync());

/// Smartschool's error page with HTTP 500, as the LVS answered the absences
/// of a made-up pupil in a made-up class (seen live).
ResponseBody _errorPage() => _answer(
  '<!DOCTYPE html><html><body><h1>Oeps, er ging iets mis</h1>'
  '</body></html>',
  status: 500,
  contentType: 'text/html; charset=UTF-8',
);

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

/// A Smartschool whose LVS answers the read of the absences with [answer],
/// and the read of the pupil's file with [file] (#190). Any other request
/// fails the test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answer, {this.file});

  final ResponseBody Function()? answer;

  final ResponseBody Function()? file;

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
    if (options.method == 'GET' && uri.path.startsWith('/LVS/Spotlight/')) {
      final file = this.file;
      if (file == null) fail("The test gave no answer to the pupil's file");
      return file();
    }
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

Future<(_Lvs, LvsService)> _serve(
  ResponseBody Function()? answer, {
  ResponseBody Function()? file,
}) async {
  final server = _Lvs(answer, file: file);
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
  '2032',
  'september',
  'oktober',
  'januari',
  'Volledige',
  'middag',
  '9001',
  '9005',
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

/// A half-day of an inline answer, with code [code], shown on the day
/// [shown] (`formattedDate`).
Map<String, Object?> _halfDay([
  String code = 'TA',
  String shown = 'ma 16 september 2030',
]) => {
  'partOfDay': 'Volledige dag',
  'codeKey': '900501',
  'code': code,
  'codeColor': 'red',
  'codeDescr': 'Testcode',
  'motivation': 'Testmotivatie.',
  'formattedDate': shown,
};

/// A school year's list of days of an inline answer: a whole day for each
/// shown day of [shown].
List<Object?> _days(List<String> shown) => [
  for (final day in shown) {'full': _halfDay('TA', day)},
];

/// The Dutch names of the months, as the LVS gives them (`lng_months`).
const _dutchMonths = [
  'januari',
  'februari',
  'maart',
  'april',
  'mei',
  'juni',
  'juli',
  'augustus',
  'september',
  'oktober',
  'november',
  'december',
];

/// An answer with [presences], as the LVS sends it, with the month names
/// [months] (`lng_months`; left out when `null`).
Map<String, Object?> _withPresences(
  Object? presences, {
  Object? months = _dutchMonths,
}) => {
  'lng_noresults': 'Geen resultaten',
  'lng_months': ?months,
  'presences': presences,
  'year_label': '2030-2031',
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

    test("the school years in the LVS's order (the periods), each with its "
        'days as a list: a whole day or a half-day, dated by the day the LVS '
        'shows (formattedDate), with the code, its key, its description and '
        'colour, as the LVS gives them (#176)', () async {
      final (_, lvs) = await _serve(_file('absences.json'));

      final absences = await _read(lvs);

      expect(absences.yearLabel, '2031-2032');
      expect(absences.isEmpty, isFalse);
      expect(absences.periods.map((p) => p.label), ['2030-2031', '2031-2032']);
      expect(absences.periods.map((p) => p.absences.length), [3, 2]);

      final all = absences.absences;
      expect(all.map((a) => a.date), [
        DateTime.utc(2030, 9, 16),
        DateTime.utc(2030, 10, 2),
        DateTime.utc(2030, 10, 2),
        DateTime.utc(2031, 9, 18),
        DateTime.utc(2032, 1, 20),
      ]);
      expect(all.map((a) => a.formattedDate), [
        'ma 16 september 2030',
        'wo 2 oktober 2030',
        'wo 2 oktober 2030',
        'do 18 september 2031',
        'di 20 januari 2032',
      ]);
      // The days come as a list: no day keys.
      expect(all.map((a) => a.dateKey), everyElement(isEmpty));
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
      expect(all.map((a) => a.codeKey), [
        '900501',
        '900502-900503',
        '900501',
        '900502-900503',
        '900501',
      ]);
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
      expect(all.map((a) => a.partOfDayLabel), [
        'Volledige dag',
        'Voormiddag',
        'Namiddag',
        'Namiddag',
        'Volledige dag',
      ]);
    });

    test('a shown day without a year takes it from the school year: '
        'September to December its first year, January to August its second '
        '(#176)', () async {
      final (_, lvs) = await _serve(_file('absences_no_year.json'));

      final absences = await _read(lvs);

      expect(absences.periods.single.label, '2030-2031');
      expect(absences.absences.map((a) => a.date), [
        DateTime.utc(2030, 9, 2),
        DateTime.utc(2030, 10, 23),
        DateTime.utc(2030, 12, 3),
        DateTime.utc(2031, 2, 3),
        DateTime.utc(2031, 8, 29),
      ]);
      expect(absences.absences.map((a) => a.formattedDate), [
        'ma 2 september',
        'wo 23 oktober',
        'di 3 december',
        'ma 3 februari',
        'vr 29 augustus',
      ]);
    });

    test("the month by the answer's names (lng_months), in any case; the "
        'Dutch name when they lack it or when the answer gives none, or none '
        'that the service can use (#176)', () async {
      const french = [
        'janvier',
        'février',
        'mars',
        'avril',
        'mai',
        'juin',
        'juillet',
        'août',
        'septembre',
        'octobre',
        'novembre',
        'décembre',
      ];
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            '2030-2031': _days([
              'me 23 octobre 2030',
              'LU 3 FÉVRIER 2031',
              've 29 Août',
              'wo 23 Oktober 2030',
              'MA 2 SEPTEMBER',
            ]),
          }, months: french),
        ),
      );

      expect((await _read(lvs)).absences.map((a) => a.date), [
        DateTime.utc(2030, 10, 23),
        DateTime.utc(2031, 2, 3),
        DateTime.utc(2031, 8, 29),
        DateTime.utc(2030, 10, 23),
        DateTime.utc(2030, 9, 2),
      ]);

      // No names, or names the service cannot use: the Dutch ones, never an
      // error.
      for (final months in <Object?>[
        null,
        'Testmaanden',
        {'1': 'janvier'},
        french.sublist(0, 11),
        [for (var i = 0; i < 12; i++) i],
      ]) {
        final (_, lvs) = await _serve(
          _of(
            _withPresences({
              '2030-2031': _days(['wo 23 oktober 2030', 'me 23 octobre 2030']),
            }, months: months),
          ),
        );
        expect((await _read(lvs)).absences.map((a) => a.date), [
          DateTime.utc(2030, 10, 23),
          null,
        ], reason: '$months');
      }
    });

    test('a shown day that does not parse, or a day without a year in a '
        'period that is no school year, has no date: the absence is kept, '
        'never an error (#176)', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            '2030-2031': [
              ..._days([
                'ma 16/09/2030',
                '16 september 2030',
                'Testdatum',
                '',
                'vr 30 februari 2031',
                'vr 32 oktober 2030',
                'vr 0 oktober 2030',
                'vr 23 testmaand 2030',
                'vr 23 oktober 2030 VM',
                'vr 23 oktober 20301',
              ]),
              {
                'full': {..._halfDay(), 'formattedDate': null},
              },
            ],
            'Testperiode': _days(['wo 23 oktober']),
          }),
        ),
      );

      final absences = await _read(lvs);

      expect(absences.periods.map((p) => p.absences.length), [11, 1]);
      expect(absences.absences.map((a) => a.date), everyElement(isNull));
      expect(absences.absences.map((a) => a.code), everyElement('TA'));
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
      expect(absences.yearLabel, '2030-2031');
    });

    test('presences that the web client takes for none (null, false, an '
        'empty map, or none at all next to the year): no periods', () async {
      final answers = <Object?>[
        _withPresences(null),
        _withPresences(false),
        _withPresences(<String, Object?>{}),
        {'year_label': '2030-2031', 'lng_noresults': 'Geen resultaten'},
      ];
      for (final answer in answers) {
        final (_, lvs) = await _serve(_of(answer));
        final absences = await _read(lvs);
        expect(absences.periods, isEmpty, reason: '$answer');
        expect(absences.yearLabel, '2030-2031', reason: '$answer');
      }
    });

    test('a school year without days is kept, empty; a day that is an empty '
        'list is left out', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            '2030-2031': <String, Object?>{},
            '2031-2032': [
              {'am': _halfDay('TA', 'do 18 september 2031')},
              <Object?>[],
              {'pm': _halfDay('TB', 'di 20 januari')},
            ],
            '2032-2033': <Object?>[],
          }),
        ),
      );

      final absences = await _read(lvs);

      expect(absences.periods.map((p) => p.label), [
        '2030-2031',
        '2031-2032',
        '2032-2033',
      ]);
      expect(absences.periods.map((p) => p.absences.length), [0, 2, 0]);
      final listed = absences.periods[1].absences;
      expect(listed.map((a) => a.code), ['TA', 'TB']);
      expect(listed.map((a) => a.dateKey), ['', '']);
      expect(listed.map((a) => a.date), [
        DateTime.utc(2031, 9, 18),
        DateTime.utc(2032, 1, 20),
      ]);
    });

    test('days keyed YYYY-MM-DD, as the class view keys them, still work: '
        'the key dates the day, before the shown day; a key that is not a '
        'day leaves the date to the shown day; the keys of a day other than '
        'full, am and pm are left out, as the web client leaves them '
        'out', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            'Testperiode': {
              'Testdag': {'full': _halfDay()},
              '2030-02-30': {'am': _halfDay('TA', '')},
              '2030-09-17': {
                'none': _halfDay('TB'),
                'pm': _halfDay('TA'),
                'am': _halfDay('TB'),
              },
              '2030-09-18': <Object?>[],
            },
            '2030-2031': {
              '2030-10-02': {'full': _halfDay('TA', 'Testdatum')},
            },
          }),
        ),
      );

      final absences = await _read(lvs);
      final all = absences.absences;

      expect(absences.periods.map((p) => p.label), [
        'Testperiode',
        '2030-2031',
      ]);
      expect(all.map((a) => a.dateKey), [
        'Testdag',
        '2030-02-30',
        '2030-09-17',
        '2030-09-17',
        '2030-10-02',
      ]);
      expect(all.map((a) => a.date), [
        DateTime.utc(2030, 9, 16),
        null,
        DateTime.utc(2030, 9, 17),
        DateTime.utc(2030, 9, 17),
        DateTime.utc(2030, 10, 2),
      ]);
      // In the answer's order, as the web client shows them.
      expect(all.map((a) => a.dayPart), [
        null,
        DayPart.morning,
        DayPart.afternoon,
        DayPart.morning,
        null,
      ]);
      expect(all.map((a) => a.code), ['TA', 'TA', 'TA', 'TB', 'TA']);
    });

    test('a half-day with only its code: the rest empty, no colour, no '
        'date; a code or a code key that is a number is taken as its '
        'text', () async {
      final (_, lvs) = await _serve(
        _of(
          _withPresences({
            '2030-2031': [
              {
                'full': {'code': 'TA'},
                'pm': {'code': 7, 'codeKey': 900501, 'codeColor': ''},
              },
            ],
          }),
        ),
      );

      final all = (await _read(lvs)).absences;

      expect(all.map((a) => a.code), ['TA', '7']);
      expect(all.map((a) => a.codeKey), ['', '900501']);
      expect(all.map((a) => a.color), [null, null]);
      expect(all.map((a) => a.codeDescription), ['', '']);
      expect(all.map((a) => a.motivation), ['', '']);
      expect(all.map((a) => a.formattedDate), ['', '']);
      expect(all.map((a) => a.date), [null, null]);
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
        _withPresences({
          '2030-2031': [
            {
              'pm': {
                ..._halfDay(),
                'codeKey': ['900501'],
              },
            },
          ],
        }),
        _withPresences({
          '2030-2031': [
            {
              'full': {
                ..._halfDay(),
                'formattedDate': {'Test': 2030},
              },
            },
          ],
        }),
        _withPresences({
          '2030-2031': ['Testdag'],
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
      final (server, lvs) = await _serve(null);

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

  group('a pupil the LVS does not know (#190)', () {
    /// The error of the absences themselves: their HTTP 500, not an error of
    /// the read of the file.
    Matcher absencesFailed() => allOf(
      _unreadable(statusCode: 500),
      isA<SmartschoolLvsError>().having(
        (e) => e.message,
        'message',
        contains("the pupil's absences with HTTP 500"),
      ),
    );

    test("Smartschool's error page with a 500, as the LVS answered a made-up "
        "pupil in a made-up class (seen live), then the LVS's placeholder "
        "pupil for the pupil's file: a SmartschoolLvsPupilNotFoundError with "
        'both IDs, neither in its message, as getPupilFile throws', () async {
      final (server, lvs) = await _serve(
        _errorPage,
        file: _spotlight('pupil_not_found.json'),
      );

      await expectLater(
        lvs.getAbsences(pupilId: 900009, classId: 900109),
        throwsA(
          isA<SmartschoolLvsPupilNotFoundError>()
              .having((e) => e.pupilId, 'pupilId', 900009)
              .having((e) => e.classId, 'classId', 900109)
              .having((e) => e.message, 'message', _quotesNothing)
              .having((e) => e.message, 'message', isNot(contains('900009')))
              .having((e) => e.message, 'message', isNot(contains('900109')))
              .having((e) => '$e', 'toString()', _quotesNothing),
        ),
      );
      // The file only, as getPupilFile reads it without today's status: no
      // getStatusInfo.
      expect(server.requests, [
        'POST /LVS/Pupilpresences',
        'GET /LVS/Spotlight/900009?classID=900109',
      ]);
      expect(server.forms.last, isEmpty);
    });

    test('a 500 for the absences of a pupil the LVS knows: the file is read, '
        'and the 500 stands, a plain SmartschoolLvsError with the '
        'status', () async {
      final (server, lvs) = await _serve(
        _errorPage,
        file: _spotlight('pupil_file.json'),
      );

      await expectLater(_read(lvs), throwsA(absencesFailed()));
      expect(server.requests, [
        'POST /LVS/Pupilpresences',
        'GET /LVS/Spotlight/900001?classID=900101',
      ]);
    });

    test('a 500 for the absences and a read of the file that fails (a '
        "refusal, a 500, an answer that is not JSON, another pupil's file, an "
        'unknown shape, no connection): the 500 of the absences '
        'stands', () async {
      final files = <String, ResponseBody Function()>{
        '403': () => _answer('', status: 403, contentType: 'text/html'),
        '500': _errorPage,
        'not JSON': () => _answer('{"pupil": '),
        'another pupil': _spotlight('pupil_file.json'),
        'unknown shape': _of({'pupil': 'Testleerling'}),
        'no connection': () => throw const SocketException('Testfout'),
      };
      for (final MapEntry(key: what, value: file) in files.entries) {
        final (server, lvs) = await _serve(_errorPage, file: file);
        await expectLater(
          lvs.getAbsences(pupilId: 900009, classId: 900109),
          throwsA(absencesFailed()),
          reason: what,
        );
        expect(server.requests, [
          'POST /LVS/Pupilpresences',
          'GET /LVS/Spotlight/900009?classID=900109',
        ], reason: what);
      }
    });

    test('an answer of the absences other than a 500 (a refusal, another '
        'status, an HTML page, an answer that is not JSON, an unknown shape) '
        'reads no file', () async {
      final answers = <String, ResponseBody Function()>{
        '403': () => _answer('', status: 403),
        'start page': () => _answer(
          '',
          status: 302,
          headers: {
            'location': ['/?module=Homepage'],
          },
        ),
        '404': () => _answer('', status: 404, contentType: 'text/html'),
        '502': () => _answer('', status: 502, contentType: 'text/html'),
        '503': () => _answer('', status: 503, contentType: 'text/html'),
        'HTML': () => _answer(
          '<html><body>Testpagina</body></html>',
          contentType: 'text/html',
        ),
        'not JSON': () => _answer('{"presences": '),
        'unknown shape': _of(['Testperiode']),
      };
      for (final MapEntry(key: what, value: answer) in answers.entries) {
        final (server, lvs) = await _serve(
          answer,
          file: _spotlight('pupil_not_found.json'),
        );
        await expectLater(
          lvs.getAbsences(pupilId: 900009, classId: 900109),
          throwsA(
            allOf(
              isA<SmartschoolLvsError>(),
              isNot(isA<SmartschoolLvsPupilNotFoundError>()),
            ),
          ),
          reason: what,
        );
        expect(server.requests, ['POST /LVS/Pupilpresences'], reason: what);
      }
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
