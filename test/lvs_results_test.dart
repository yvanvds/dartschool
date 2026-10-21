// Tests for issue #162: the results of a pupil's file in the LVS, read as the
// logged-in teacher through LvsService: what the results app may show
// (getResultsConfiguration), the periods and courses (getResultsPeriods,
// getResultsCourses), the evaluations a page at a time (getEvaluations) or
// page by page up to a cap (getAllEvaluations), the feedback (getFeedback)
// and the reports (getReports); the school year and filters sent, the
// allowlist of the results app's GETs, and errors that carry no name.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/results/
// (doc/lvs-privacy.md: never trimmed from a live answer), in the shapes the
// results app's JavaScript reads (2026-10-21); a real pupil's answers are
// the developer's capture step (#168). The 500 with Smartschool's error page
// is what the LVS answered every one of these reads with for a made-up pupil
// ID (seen live). Smaller variants (an unknown shape, a refusal) are inline
// below.
//
// The fake Smartschool fails the test on any request that is not one of the
// service's results reads.
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
    File('test/fixtures/lvs/results/$name').readAsStringSync();

ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'application/json',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// An answer of the fixture [name], whatever the request.
ResponseBody Function(Uri) _json(String name) =>
    (_) => _answer(_fixture(name));

/// An answer of [body] as JSON, whatever the request.
ResponseBody Function(Uri) _text(String body) =>
    (_) => _answer(body);

/// The fixture of each page of the evaluations, by `pageNumber`; `[]` for a
/// page not in [pages].
ResponseBody Function(Uri) _pages(Map<int, String> pages) => (uri) {
  final page = pages[int.parse(uri.queryParameters['pageNumber']!)];
  return _answer(page == null ? '[]' : _fixture(page));
};

/// Smartschool's generic error page, as the LVS answered every results read
/// of a made-up pupil ID with it (HTTP 500, seen live).
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

/// A GET that the LVS sent on to Smartschool's start page, as the client
/// gives it: the page it ends on, with the redirect it followed.
ResponseBody _followedToStartPage(Uri _) => _answer(
  '<html><body>Start</body></html>',
  contentType: 'text/html',
)..redirects = [RedirectRecord(302, 'GET', Uri.parse('/?module=Homepage'))];

/// The results reads, by the path of each: the key [_Lvs.answers] takes.
const _reads = {
  '/LVS/Results/getConfiguration': 'configuration',
  '/LVS/Results/getperiods': 'periods',
  '/LVS/Results/getcourses': 'courses',
  '/LVS/Results/getevaluationsofuser': 'evaluations',
  '/LVS/Results/getfeedback': 'feedback',
  '/LVS/Results/getreports': 'reports',
};

/// A Smartschool whose LVS answers the results reads of the service with
/// [answers], by read (the values of [_reads]). Any other request fails the
/// test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answers);

  final Map<String, ResponseBody Function(Uri)> answers;

  /// Every request that reached it, as `METHOD path?query`.
  final requests = <String>[];

  /// The query of each of them, in order.
  final queries = <Map<String, String>>[];

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
    queries.add(uri.queryParameters);
    final read = options.method == 'GET' ? _reads[uri.path] : null;
    if (read == null) {
      fail('Not a results read of LvsService: ${options.method} ${uri.path}');
    }
    final answer = answers[read];
    if (answer == null) fail('The test gave no answer to the $read read');
    return answer(uri);
  }

  @override
  void close({bool force = false}) {}
}

Future<(_Lvs, LvsService)> _serve(
  Map<String, ResponseBody Function(Uri)> answers,
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

/// The fake people, labels, texts and IDs of the fixtures: an error message
/// and a model's `toString()` hold none of them.
const _answerValues = [
  'Janssens',
  'Peeters',
  'Piet',
  'Dupré',
  'Céline',
  'Test',
  'test',
  'TEST',
  '1A',
  '7/10',
  'knight2',
  'briefcase',
  '9000',
  '9001',
  '2030-2031',
  'pdf',
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

/// A [SmartschoolLvsAccessDeniedError] for [what].
Matcher _refused(String what) => isA<SmartschoolLvsAccessDeniedError>()
    .having((e) => e.message, 'message', contains('refused $what'))
    .having((e) => e.message, 'message', _quotesNothing);

/// The school year of the fixtures.
final _year = LvsSchoolYear.starting(2030);

/// Each results read of pupil 900001 in class 900101, by its key in
/// [_reads], with what the read is called in messages.
final _calls = <String, (String, Future<Object?> Function(LvsService))>{
  'configuration': (
    "the configuration of the pupil's results",
    (lvs) => lvs.getResultsConfiguration(pupilId: 900001, classId: 900101),
  ),
  'periods': (
    "the periods of the pupil's results",
    (lvs) => lvs.getResultsPeriods(pupilId: 900001, classId: 900101),
  ),
  'courses': (
    "the courses of the pupil's results",
    (lvs) => lvs.getResultsCourses(pupilId: 900001, classId: 900101),
  ),
  'evaluations': (
    "the pupil's evaluations",
    (lvs) => lvs.getEvaluations(pupilId: 900001, classId: 900101),
  ),
  'feedback': (
    "the feedback on the pupil's results",
    (lvs) => lvs.getFeedback(pupilId: 900001, classId: 900101),
  ),
  'reports': (
    "the pupil's reports",
    (lvs) => lvs.getReports(pupilId: 900001, classId: 900101),
  ),
};

void main() {
  forbidRealNetwork();

  group('getResultsConfiguration', () {
    test('one GET with the pupil and the class; the capabilities as '
        'flags', () async {
      final (server, lvs) = await _serve({
        'configuration': _json('configuration.json'),
      });

      final config = await lvs.getResultsConfiguration(
        pupilId: 900001,
        classId: 900101,
      );

      expect(server.requests, [
        'GET /LVS/Results/getConfiguration?pupilId=900001&groupId=900101',
      ]);
      expect(config.canSeeAll, isTrue);
      expect(config.canSeeSchoolYear, isFalse);
      expect(
        '$config',
        'LvsResultsConfiguration(canSeeAll: true, canSeeSchoolYear: false)',
      );
    });

    test('flags as 0/1, or left out: null', () async {
      final (_, lvs) = await _serve({
        'configuration': _text('{"capabilities": {"canUserSeeAll": 1}}'),
      });

      final config = await lvs.getResultsConfiguration(
        pupilId: 900001,
        classId: 900101,
      );

      expect(config.canSeeAll, isTrue);
      expect(config.canSeeSchoolYear, isNull);
    });
  });

  group('getResultsPeriods', () {
    test('one GET with the pupil, the class and the school year asked '
        'for', () async {
      final (server, lvs) = await _serve({'periods': _json('periods.json')});

      await lvs.getResultsPeriods(
        pupilId: 900001,
        classId: 900101,
        schoolYear: _year,
      );

      expect(server.requests, [
        'GET /LVS/Results/getperiods?pupilId=900001&groupId=900101'
            '&startDate=2030-09-01&endDate=2031-08-31',
      ]);
    });

    test('without a school year: the current one, in Belgian time', () async {
      final (server, lvs) = await _serve({'periods': _json('periods.json')});

      await lvs.getResultsPeriods(pupilId: 900001, classId: 900101);

      final current = LvsSchoolYear.current();
      expect(server.queries.single['startDate'], current.firstDay);
      expect(server.queries.single['endDate'], current.lastDay);
    });

    test("the periods in the LVS's order: ID, name, icon, class, whether "
        'active, and their Skore school year in UTC', () async {
      final (_, lvs) = await _serve({'periods': _json('periods.json')});

      final periods = await lvs.getResultsPeriods(
        pupilId: 900001,
        classId: 900101,
      );

      expect(periods.map((p) => p.id), [900401, 900402]);
      final first = periods.first;
      expect(first.name, 'Testperiode');
      expect(first.icon, 'cal_purple_generic_week');
      expect(first.classId, 900101);
      expect(first.className, '1A');
      expect(first.isActive, isTrue);
      expect(periods.last.isActive, isFalse);
      expect(first.workYearId, 900801);
      expect(first.workYearStart, DateTime.utc(2030, 8, 31, 22));
      expect(first.workYearEnd, DateTime.utc(2031, 8, 31, 21, 59, 59));
      expect(first.workYearStart!.isUtc, isTrue);
    });
  });

  group('getResultsCourses', () {
    test("one GET with the school year; the courses in the LVS's order, with "
        'their class, Skore class, parent course and graphic', () async {
      final (server, lvs) = await _serve({'courses': _json('courses.json')});

      final courses = await lvs.getResultsCourses(
        pupilId: 900001,
        classId: 900101,
        schoolYear: _year,
      );

      expect(server.requests, [
        'GET /LVS/Results/getcourses?pupilId=900001&groupId=900101'
            '&startDate=2030-09-01&endDate=2031-08-31',
      ]);
      expect(courses.map((c) => c.id), [900301, 900302]);
      final (main, part) = (courses.first, courses.last);
      expect(main.name, 'Testvak');
      expect(main.classId, 900101);
      expect(main.className, '1A');
      expect(main.skoreClassId, 900101);
      expect(main.parentCourseId, isNull);
      expect(main.graphicType, 'icon');
      expect(main.graphicValue, 'knight2');
      expect(main.teacherNames, isEmpty);
      expect(part.parentCourseId, 900301);
      expect(part.graphicType, 'image');
      expect(
        part.graphicValue,
        '/skore/api/v1/assets/skore-data/image/900901/view',
      );
    });
  });

  group('getEvaluations', () {
    test('one GET: the page, the courses and periods sorted, each once, '
        'comma-separated, and the school year', () async {
      final (server, lvs) = await _serve({
        'evaluations': _json('evaluations_page1.json'),
      });

      await lvs.getEvaluations(
        pupilId: 900001,
        classId: 900101,
        courseIds: [900302, 900301, 900302],
        periodIds: {900402, 900401},
        pageNumber: 3,
        itemsOnPage: 25,
        schoolYear: _year,
      );

      expect(server.requests, [
        'GET /LVS/Results/getevaluationsofuser?pupilId=900001&groupId=900101'
            '&pageNumber=3&itemsOnPage=25'
            '&courseIds=900301%2C900302&periodIds=900401%2C900402'
            '&startDate=2030-09-01&endDate=2031-08-31',
      ]);
      expect(server.queries.single['courseIds'], '900301,900302');
    });

    test('without filters: all courses and periods, as the results app asks '
        'for them (courseIds and periodIds left out); page 1 of 100 by '
        'default', () async {
      final (server, lvs) = await _serve({
        'evaluations': _json('evaluations_page1.json'),
      });

      await lvs.getEvaluations(pupilId: 900001, classId: 900101);

      expect(server.queries.single.keys, [
        'pupilId',
        'groupId',
        'pageNumber',
        'itemsOnPage',
        'startDate',
        'endDate',
      ]);
      expect(server.queries.single['pageNumber'], '1');
      expect(server.queries.single['itemsOnPage'], '100');
    });

    test('a score in points: its percentage and the points as the LVS shows '
        'them; the courses with their teachers, the period, the component, '
        'whether it counts and is published, and the feedback count', () async {
      final (_, lvs) = await _serve({
        'evaluations': _json('evaluations_page1.json'),
      });

      final page = await lvs.getEvaluations(
        pupilId: 900001,
        classId: 900101,
        itemsOnPage: 2,
      );

      expect(page.pageNumber, 1);
      expect(page.itemsOnPage, 2);
      expect(page.mayHaveMore, isTrue);
      expect(page.evaluations, hasLength(2));
      final points = page.evaluations.first;
      expect(points.identifier, '900000_900001_0_normal_900601');
      expect(points.type, 'normal');
      expect(points.name, 'Testevaluatie');
      expect(points.date, DateTime.utc(2030, 10, 14, 22));
      expect(points.score.type, LvsScoreType.percentage);
      expect(points.score.isKnownType, isTrue);
      expect(points.score.percentage, 70);
      expect(points.score.value, '70');
      expect(points.score.description, '7/10');
      expect(points.score.color, 'yellow');
      expect(points.courses.single.id, 900301);
      expect(points.courses.single.className, '1A');
      expect(points.courses.single.teacherNames, ['Piet Peeters']);
      expect(points.period!.id, 900401);
      expect(points.period!.className, '1A');
      expect(points.componentName, 'Testcomponent');
      expect(points.componentAbbreviation, 'TEST');
      expect(points.doesCount, isTrue);
      expect(points.isPublished, isTrue);
      expect(points.feedbackCount, 1);
    });

    test(
      'a symbol or text: its value and description as they come; a course '
      'without a class; an evaluation that does not count, unpublished',
      () async {
        final (_, lvs) = await _serve({
          'evaluations': _json('evaluations_page1.json'),
        });

        final page = await lvs.getEvaluations(pupilId: 900001, classId: 900101);

        final text = page.evaluations.last;
        expect(text.score.type, LvsScoreType.text);
        expect(text.score.value, 'A');
        expect(text.score.percentage, isNull);
        expect(text.score.description, 'Testbeoordeling');
        expect(text.date, DateTime.utc(2030, 11, 4, 23));
        expect(text.courses.single.classId, isNull);
        expect(text.courses.single.className, '');
        expect(text.courses.single.parentCourseId, 900301);
        expect(text.courses.single.teacherNames, ['Céline Dupré']);
        expect(text.componentName, '');
        expect(text.doesCount, isFalse);
        expect(text.isPublished, isFalse);
        expect(text.feedbackCount, 0);
        // Fewer than asked for: the last page.
        expect(page.mayHaveMore, isFalse);
      },
    );

    test('an icon without a description, a project; what the LVS leaves out '
        'is empty or null', () async {
      final (_, lvs) = await _serve({
        'evaluations': _json('evaluations_page2.json'),
      });

      final page = await lvs.getEvaluations(pupilId: 900001, classId: 900101);

      final icon = page.evaluations.single;
      expect(icon.type, 'project');
      expect(icon.score.type, LvsScoreType.icon);
      expect(icon.score.value, 'target_lpd_steel');
      expect(icon.score.description, '');
      expect(icon.period!.isActive, isFalse);
      expect(icon.period!.workYearId, isNull);
      expect(icon.componentName, '');
      expect(icon.doesCount, isNull);
      expect(icon.isPublished, isNull);
    });

    test('no evaluations: an empty page', () async {
      final (_, lvs) = await _serve({
        'evaluations': _json('evaluations_empty.json'),
      });

      final page = await lvs.getEvaluations(pupilId: 900001, classId: 900101);

      expect(page.evaluations, isEmpty);
      expect(page.mayHaveMore, isFalse);
    });

    test('a score type the service does not know is kept as it comes; an '
        'evaluation without a graphic has none', () async {
      final (_, lvs) = await _serve({
        'evaluations': _text(
          jsonEncode([
            {
              'identifier': '900000_900001_0_normal_900604',
              'name': 'Testevaluatie',
              'graphic': {'type': 'stars', 'value': 3.5},
            },
            {'identifier': '900000_900001_0_normal_900605', 'name': ''},
          ]),
        ),
      });

      final page = await lvs.getEvaluations(pupilId: 900001, classId: 900101);

      final [stars, none] = page.evaluations;
      expect(stars.score.type, 'stars');
      expect(stars.score.isKnownType, isFalse);
      expect(stars.score.percentage, 3.5);
      expect(stars.score.value, '3.5');
      expect(stars.date, isNull);
      expect(stars.courses, isEmpty);
      expect(stars.period, isNull);
      expect(none.score.type, '');
      expect(none.name, '');
    });
  });

  group('getAllEvaluations', () {
    test('reads page after page until one is not full', () async {
      final (server, lvs) = await _serve({
        'evaluations': _pages({
          1: 'evaluations_page1.json',
          2: 'evaluations_page2.json',
        }),
      });

      final all = await lvs.getAllEvaluations(
        pupilId: 900001,
        classId: 900101,
        courseIds: [900301],
        itemsOnPage: 2,
        schoolYear: _year,
      );

      expect(all.evaluations.map((e) => e.identifier), [
        '900000_900001_0_normal_900601',
        '900000_900001_0_normal_900602',
        '900000_900001_0_project_900603',
      ]);
      expect(all.isComplete, isTrue);
      expect(all.pagesRead, 2);
      expect(server.queries.map((q) => q['pageNumber']), ['1', '2']);
      for (final query in server.queries) {
        expect(query['itemsOnPage'], '2');
        expect(query['courseIds'], '900301');
        expect(query['startDate'], '2030-09-01');
      }
    });

    test('a full last page: the empty page after it ends the list', () async {
      final (server, lvs) = await _serve({
        'evaluations': _pages({1: 'evaluations_page1.json'}),
      });

      final all = await lvs.getAllEvaluations(
        pupilId: 900001,
        classId: 900101,
        itemsOnPage: 2,
      );

      expect(all.evaluations, hasLength(2));
      expect(all.isComplete, isTrue);
      expect(all.pagesRead, 2);
      expect(server.requests, hasLength(2));
    });

    test('the cap: no more than maxPages pages; not complete when the last '
        'one was full', () async {
      final (server, lvs) = await _serve({
        'evaluations': _pages({
          1: 'evaluations_page1.json',
          2: 'evaluations_page2.json',
        }),
      });

      final all = await lvs.getAllEvaluations(
        pupilId: 900001,
        classId: 900101,
        itemsOnPage: 2,
        maxPages: 1,
      );

      expect(all.evaluations, hasLength(2));
      expect(all.isComplete, isFalse);
      expect(all.pagesRead, 1);
      expect(server.requests, hasLength(1));
      expect('$all', _quotesNothing);
    });

    test(
      'an evaluation that comes again on a later page is kept once',
      () async {
        final repeated = jsonDecode(_fixture('evaluations_page1.json')) as List;
        final next = jsonDecode(_fixture('evaluations_page2.json')) as List;
        final (_, lvs) = await _serve({
          'evaluations': (uri) => _answer(
            jsonEncode(switch (uri.queryParameters['pageNumber']) {
              '1' => repeated,
              '2' => [repeated.last, next.single],
              _ => <Object?>[],
            }),
          ),
        });

        final all = await lvs.getAllEvaluations(
          pupilId: 900001,
          classId: 900101,
          itemsOnPage: 2,
        );

        expect(all.evaluations.map((e) => e.identifier).toSet(), hasLength(3));
        expect(all.evaluations, hasLength(3));
        expect(all.isComplete, isTrue);
        expect(all.pagesRead, 3);
      },
    );

    test('a page of only the evaluations before it: the LVS does not page '
        'the list, a SmartschoolLvsError, not a list that looks '
        'complete', () async {
      final (_, lvs) = await _serve({
        'evaluations': _json('evaluations_page1.json'),
      });

      await expectLater(
        lvs.getAllEvaluations(pupilId: 900001, classId: 900101, itemsOnPage: 2),
        throwsA(
          allOf(
            _unreadable(statusCode: 200),
            isA<SmartschoolLvsError>().having(
              (e) => e.message,
              'message',
              contains('does not page'),
            ),
          ),
        ),
      );
    });

    test('more than a page: the LVS sent them all at once, the list is '
        'complete after one request', () async {
      final (server, lvs) = await _serve({
        'evaluations': _json('evaluations_page1.json'),
      });

      final all = await lvs.getAllEvaluations(
        pupilId: 900001,
        classId: 900101,
        itemsOnPage: 1,
      );

      expect(all.evaluations, hasLength(2));
      expect(all.isComplete, isTrue);
      expect(server.requests, hasLength(1));
    });
  });

  group('getFeedback', () {
    test('one GET with the school year', () async {
      final (server, lvs) = await _serve({'feedback': _json('feedback.json')});

      await lvs.getFeedback(
        pupilId: 900001,
        classId: 900101,
        schoolYear: _year,
      );

      expect(server.requests, [
        'GET /LVS/Results/getfeedback?pupilId=900001&groupId=900101'
            '&startDate=2030-09-01&endDate=2031-08-31',
      ]);
    });

    test('remarks on a report: of the class council, in a part of the '
        'report, and per course', () async {
      final (_, lvs) = await _serve({'feedback': _json('feedback.json')});

      final feedback = await lvs.getFeedback(pupilId: 900001, classId: 900101);

      expect(feedback.map((f) => f.kind), [
        LvsFeedbackKind.classCouncil,
        LvsFeedbackKind.course,
        LvsFeedbackKind.evaluation,
        LvsFeedbackKind.goal,
      ]);
      final council = feedback[0];
      expect(council.identifier, '00000000-0000-0000-0000-000000901001');
      expect(council.text, 'Testopmerking van de klassenraad.');
      expect(council.reportPart, 'Testcomponent');
      expect(council.report!.id, 900501);
      expect(council.report!.name, 'Testrapport');
      expect(council.author, '');
      expect(council.course, isNull);
      expect(council.evaluation, isNull);
      expect(council.attachments, isEmpty);

      final course = feedback[1];
      expect(course.text, 'Testopmerking voor het vak.');
      expect(course.course!.id, 900301);
      expect(course.course!.classId, 900101);
      expect(course.report!.id, 900501);
      expect(course.reportPart, '');
    });

    test("a teacher's feedback on an evaluation, with the evaluation and an "
        'attachment (metadata only)', () async {
      final (_, lvs) = await _serve({'feedback': _json('feedback.json')});

      final feedback = await lvs.getFeedback(pupilId: 900001, classId: 900101);

      final onEvaluation = feedback[2];
      expect(onEvaluation.text, 'Testfeedback bij de evaluatie.');
      expect(onEvaluation.author, 'Piet Peeters');
      expect(onEvaluation.report, isNull);
      final evaluation = onEvaluation.evaluation!;
      expect(evaluation.identifier, '900000_900001_0_normal_900601');
      expect(evaluation.name, 'Testevaluatie');
      expect(evaluation.date, DateTime.utc(2030, 10, 14, 22));
      expect(evaluation.courses.single.id, 900301);
      expect(evaluation.courses.single.classId, 900101);
      expect(evaluation.period!.id, 900401);
      expect(evaluation.period!.workYearId, 900801);
      expect(evaluation.schoolYearLabel, '2030-2031');
      final attachment = onEvaluation.attachments.single;
      expect(attachment.id, '00000000-0000-0000-0000-000000900701');
      expect(attachment.name, 'Testbijlage.pdf');
      expect(attachment.type, 'OTHER');
      expect(attachment.size, 12345);
      expect(
        attachment.downloadUrl,
        '/results/api/v1/attachments/00000000-0000-0000-0000-000000900701/'
        'download',
      );
      expect(onEvaluation.goalId, isNull);
    });

    test("feedback on a project's goal: the goal and its curriculum", () async {
      final (_, lvs) = await _serve({'feedback': _json('feedback.json')});

      final feedback = await lvs.getFeedback(pupilId: 900001, classId: 900101);

      final onGoal = feedback[3];
      expect(onGoal.author, 'Céline Dupré');
      expect(onGoal.goalId, '00000000-0000-0000-0000-000000902001');
      expect(onGoal.curriculumId, '00000000-0000-0000-0000-000000902002');
      expect(onGoal.evaluation!.identifier, '900000_900001_0_project_900603');
      expect(onGoal.evaluation!.period!.isActive, isFalse);
      expect(onGoal.attachments, isEmpty);
    });

    test('a kind the service does not know is kept, with its identifier and '
        'text; none is an empty list', () async {
      final (_, lvs) = await _serve({
        'feedback': _text(
          jsonEncode([
            {
              'identifier': '00000000-0000-0000-0000-000000901005',
              'text': 'Testfeedback van een nieuw soort.',
              'other': {'id': 900999},
            },
          ]),
        ),
      });

      final feedback = await lvs.getFeedback(pupilId: 900001, classId: 900101);

      expect(feedback.single.kind, LvsFeedbackKind.unknown);
      expect(feedback.single.text, 'Testfeedback van een nieuw soort.');
      expect(feedback.single.report, isNull);

      final (_, empty) = await _serve({'feedback': _text('[]')});
      expect(
        await empty.getFeedback(pupilId: 900001, classId: 900101),
        isEmpty,
      );
    });
  });

  group('getReports', () {
    test("one GET with the school year; the reports in the LVS's order, "
        'metadata only', () async {
      final (server, lvs) = await _serve({'reports': _json('reports.json')});

      final reports = await lvs.getReports(
        pupilId: 900001,
        classId: 900101,
        schoolYear: _year,
      );

      expect(server.requests, [
        'GET /LVS/Results/getreports?pupilId=900001&groupId=900101'
            '&startDate=2030-09-01&endDate=2031-08-31',
      ]);
      expect(reports.map((r) => r.id), [900501, 900502]);
      final first = reports.first;
      expect(first.name, 'Testrapport');
      expect(first.icon, 'document_certificate');
      expect(first.date, DateTime.utc(2030, 12, 20, 11));
      expect(first.classId, 900101);
      expect(first.className, '1A');
      expect(first.schoolYearLabel, '2030-2031');
      expect(
        first.downloadUrl,
        '/skore/api/v1/reports/900501/student/900001/download',
      );
      expect(reports.last.classId, isNull);
      expect(reports.last.className, '');
      expect(reports.last.date, DateTime.utc(2031, 6, 30, 10));
    });
  });

  group('every results read', () {
    test('a 403 is a SmartschoolLvsAccessDeniedError, as the results app '
        'takes it for "no access": not an empty list', () async {
      for (final MapEntry(key: read, value: (what, call)) in _calls.entries) {
        final (_, lvs) = await _serve({
          read: (_) => _answer('', status: 403, contentType: 'text/html'),
        });
        await expectLater(call(lvs), throwsA(_refused(what)), reason: read);
      }
    });

    test("a redirect to Smartschool's start page is a "
        'SmartschoolLvsAccessDeniedError', () async {
      for (final MapEntry(key: read, value: (what, call)) in _calls.entries) {
        final (_, lvs) = await _serve({read: _followedToStartPage});
        await expectLater(call(lvs), throwsA(_refused(what)), reason: read);
      }
    });

    test("the 500 with Smartschool's error page, as the LVS answers a "
        'made-up pupil, is a SmartschoolLvsError with the status', () async {
      for (final MapEntry(key: read, value: (_, call)) in _calls.entries) {
        final (_, lvs) = await _serve({
          read: (_) =>
              _answer(_errorPage, status: 500, contentType: 'text/html'),
        });
        await expectLater(
          call(lvs),
          throwsA(_unreadable(statusCode: 500)),
          reason: read,
        );
      }
    });

    test('an HTML page, an answer that is not JSON, or JSON of another '
        'shape is a SmartschoolLvsError that quotes nothing', () async {
      for (final MapEntry(key: read, value: (_, call)) in _calls.entries) {
        for (final body in [
          '<html><body>Testpagina 1A</body></html>',
          '{"Testvak": ',
          '{"name": "Testvak"}',
          '"Testvak"',
          '[1]',
        ]) {
          final (_, lvs) = await _serve({read: _text(body)});
          await expectLater(
            call(lvs),
            throwsA(_unreadable(statusCode: 200)),
            reason: '$read: $body',
          );
        }
      }
    });

    test('an item without what the service needs, or with a value of '
        'another type, is a SmartschoolLvsError that names the field, not '
        'the value', () async {
      Map<String, Object?> json(String name, int index) =>
          ((jsonDecode(_fixture(name)) as List)[index] as Map)
              .cast<String, Object?>();
      final broken = <String, List<Object?>>{
        'configuration': [
          {'capabilities': 'Testvak'},
          {
            'capabilities': {'canUserSeeAll': 'Testvak'},
          },
        ],
        'periods': [
          [
            {...json('periods.json', 0), 'id': 'Testperiode'},
          ],
          [
            {...json('periods.json', 0), 'name': null},
          ],
          [
            {
              ...json('periods.json', 0),
              'skoreWorkYear': {
                'id': 900801,
                'dateRange': {'start': 'Testperiode 1A'},
              },
            },
          ],
          [
            {...json('periods.json', 0), 'isActive': 'Testperiode'},
          ],
        ],
        'courses': [
          [
            {...json('courses.json', 0), 'id': 0},
          ],
          [
            {...json('courses.json', 0), 'class': 'Testvak 1A'},
          ],
          [
            {
              ...json('courses.json', 0),
              'teachers': [
                {'id': '900000_900201_0'},
              ],
            },
          ],
        ],
        'evaluations': [
          [
            {...json('evaluations_page1.json', 0), 'identifier': ''},
          ],
          [
            {
              ...json('evaluations_page1.json', 0),
              'graphic': {
                'type': 'percentage',
                'value': {'Testvak': 7},
              },
            },
          ],
          [
            {...json('evaluations_page1.json', 0), 'date': 'Testdatum'},
          ],
          [
            {...json('evaluations_page1.json', 0), 'feedbacks': 'Testvak'},
          ],
          [
            {...json('evaluations_page1.json', 0), 'courses': 'Testvak'},
          ],
        ],
        'feedback': [
          [
            {...json('feedback.json', 2), 'text': null},
          ],
          [
            {
              ...json('feedback.json', 2),
              'attachments': [
                {'name': 'Testbijlage.pdf'},
              ],
            },
          ],
          [
            {...json('feedback.json', 0), 'report': 'Testrapport'},
          ],
          [
            {...json('feedback.json', 2), 'owner': 'Piet Peeters'},
          ],
        ],
        'reports': [
          [
            {...json('reports.json', 0), 'id': null},
          ],
          [
            {...json('reports.json', 0), 'downloadUrl': 900501},
          ],
        ],
      };
      for (final MapEntry(key: read, value: answers) in broken.entries) {
        final call = _calls[read]!.$2;
        for (final answer in answers) {
          final (_, lvs) = await _serve({read: _text(jsonEncode(answer))});
          await expectLater(
            call(lvs),
            throwsA(
              allOf(
                _unreadable(statusCode: 200),
                isA<SmartschoolLvsError>().having(
                  (e) => e.message,
                  'message',
                  contains('in a shape the service does not recognise'),
                ),
              ),
            ),
            reason: '$read: $answer',
          );
        }
      }
    });

    test('an ID, a page, a page size or a cap that is not positive, or a '
        'school year that ends before it starts, is an ArgumentError, '
        'before anything is sent', () async {
      final (server, lvs) = await _serve({});
      final backwards = LvsSchoolYear(
        from: DateTime.utc(2031, 9),
        until: DateTime.utc(2031, 8, 31),
      );

      final calls = <Future<Object?> Function()>[
        () => lvs.getResultsConfiguration(pupilId: 0, classId: 900101),
        () => lvs.getResultsConfiguration(pupilId: 900001, classId: -1),
        () => lvs.getResultsPeriods(pupilId: -5, classId: 900101),
        () => lvs.getResultsPeriods(
          pupilId: 900001,
          classId: 900101,
          schoolYear: backwards,
        ),
        () => lvs.getResultsCourses(pupilId: 900001, classId: 0),
        () => lvs.getEvaluations(pupilId: 0, classId: 900101),
        () => lvs.getEvaluations(
          pupilId: 900001,
          classId: 900101,
          courseIds: [900301, 0],
        ),
        () => lvs.getEvaluations(
          pupilId: 900001,
          classId: 900101,
          periodIds: [-900401],
        ),
        () =>
            lvs.getEvaluations(pupilId: 900001, classId: 900101, pageNumber: 0),
        () => lvs.getEvaluations(
          pupilId: 900001,
          classId: 900101,
          itemsOnPage: 0,
        ),
        () => lvs.getEvaluations(
          pupilId: 900001,
          classId: 900101,
          schoolYear: backwards,
        ),
        () => lvs.getAllEvaluations(
          pupilId: 900001,
          classId: 900101,
          maxPages: 0,
        ),
        () => lvs.getAllEvaluations(
          pupilId: 900001,
          classId: 900101,
          itemsOnPage: -1,
        ),
        () => lvs.getAllEvaluations(pupilId: 900001, classId: 0),
        () => lvs.getFeedback(pupilId: 900001, classId: 0),
        () => lvs.getFeedback(
          pupilId: 900001,
          classId: 900101,
          schoolYear: backwards,
        ),
        () => lvs.getReports(pupilId: 0, classId: 900101),
      ];
      for (final (i, call) in calls.indexed) {
        await expectLater(call(), throwsArgumentError, reason: 'call $i');
      }
      expect(server.requests, isEmpty);
    });

    test('the models print counts and types only', () async {
      final (_, lvs) = await _serve({
        'configuration': _json('configuration.json'),
        'periods': _json('periods.json'),
        'courses': _json('courses.json'),
        'evaluations': _json('evaluations_page1.json'),
        'feedback': _json('feedback.json'),
        'reports': _json('reports.json'),
      });

      final printed = <String>[
        '${await lvs.getResultsConfiguration(pupilId: 900001, classId: 900101)}',
        for (final period in await lvs.getResultsPeriods(
          pupilId: 900001,
          classId: 900101,
        ))
          '$period',
        for (final course in await lvs.getResultsCourses(
          pupilId: 900001,
          classId: 900101,
        ))
          '$course',
      ];
      final page = await lvs.getEvaluations(pupilId: 900001, classId: 900101);
      printed.add('$page');
      for (final evaluation in page.evaluations) {
        printed
          ..add('$evaluation')
          ..add('${evaluation.score}');
        for (final course in evaluation.courses) {
          printed.add('$course');
        }
      }
      for (final feedback in await lvs.getFeedback(
        pupilId: 900001,
        classId: 900101,
      )) {
        printed
          ..add('$feedback')
          ..add('${feedback.report}')
          ..add('${feedback.evaluation}')
          ..addAll(feedback.attachments.map((a) => '$a'));
      }
      for (final report in await lvs.getReports(
        pupilId: 900001,
        classId: 900101,
      )) {
        printed.add('$report');
      }

      expect(
        printed,
        everyElement(allOf(_quotesNothing, isNot(contains('Testvak')))),
      );
      expect(
        printed,
        containsAll([
          'LvsEvaluation(type: normal, score: percentage, courses: 1, '
              'feedbacks: 1)',
          'LvsScore(type: percentage)',
          'LvsFeedback(kind: evaluation, attachments: 1)',
          'LvsReport(<values hidden>)',
          'LvsResultsAttachment(<values hidden>)',
          'LvsResultsPeriod(isActive: true)',
          'LvsResultsCourse(teachers: 1)',
          'LvsEvaluationPage(pageNumber: 1, evaluations: 2)',
        ]),
      );
    });
  });

  group('the allowlist of the results reads', () {
    test('the reads of the service are on it', () {
      const year = {'startDate': '2030-09-01', 'endDate': '2031-08-31'};
      const pupil = {'pupilId': '900001', 'groupId': '900101'};
      expect(
        LvsWire.readOf(
          'GET',
          '/LVS/Results/getConfiguration',
          query: const {...pupil},
        ),
        same(LvsWire.resultsConfiguration),
      );
      for (final (path, read) in [
        ('/LVS/Results/getperiods', LvsWire.resultsPeriods),
        ('/LVS/Results/getcourses', LvsWire.resultsCourses),
        ('/LVS/Results/getfeedback', LvsWire.resultsFeedback),
        ('/LVS/Results/getreports', LvsWire.reports),
      ]) {
        expect(
          LvsWire.readOf('GET', path, query: const {...pupil, ...year}),
          same(read),
          reason: path,
        );
      }
      expect(
        LvsWire.readOf(
          'GET',
          '/LVS/Results/getevaluationsofuser',
          query: const {
            ...pupil,
            'pageNumber': '1',
            'itemsOnPage': '100',
            'courseIds': '900301,900302',
            'periodIds': '900401',
            ...year,
          },
        ),
        same(LvsWire.evaluations),
      );
    });

    test('any other request of the results app, or a read with more, is '
        'refused before it is sent', () async {
      final server = _Lvs({});
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;
      final wire = LvsWire(client);

      const pupil = {'pupilId': '900001', 'groupId': '900101'};
      final refused = <(String, String, Map<String, String>)>[
        // The export, and the reads the service does not send.
        ('GET', '/LVS/Results/exportgoals', const {...pupil}),
        ('GET', '/LVS/Results/getevaluationbyid', const {...pupil}),
        ('GET', '/LVS/Results/getcomponents', const {...pupil}),
        ('GET', '/LVS/Results/getleerplannen', const {...pupil}),
        ('GET', '/LVS/Results/getgoalsbyleerplan', const {...pupil}),
        // The reads, but not as the service sends them.
        ('POST', '/LVS/Results/getreports', const {...pupil}),
        ('PUT', '/LVS/Results/getfeedback', const {...pupil}),
        (
          'GET',
          '/LVS/Results/getConfiguration',
          const {...pupil, 'startDate': '2030-09-01'},
        ),
        (
          'GET',
          '/LVS/Results/getevaluationsofuser',
          const {...pupil, 'componentIds': '900911'},
        ),
        (
          'GET',
          '/LVS/Results/getevaluationsofuser',
          const {...pupil, 'isPublished': 'false'},
        ),
        ('GET', '/LVS/Results/getreports', const {...pupil, 'export': '1'}),
        ('GET', '/LVS/Results/getreports/900501', const {...pupil}),
        ('GET', '/LVS/Results/getperiods/../exportgoals', const {...pupil}),
      ];
      for (final (method, path, query) in refused) {
        await expectLater(
          wire.send(method, path, query: query),
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
}
