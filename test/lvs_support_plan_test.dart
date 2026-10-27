// Tests for issue #163: a pupil's support plan in the LVS, read as the
// logged-in teacher through LvsService: the periods of the support plans
// (getSupportPlanPeriods), the individual plan with its support needs, goals
// and approach (getSupportPlan), and the profile sketch (getProfileSketch);
// the outcomes without a plan, without a period, and in a closed period;
// the allowlist that keeps the edit flow's calls out, and errors that carry
// no name. And for #189, the IDs that tell whose items they are and which
// courses they are planned in: an item's author ID and course IDs, the kind
// and ID of each entry of a goal's planning, and the plan's courses that
// name those IDs.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/supportplan/
// (doc/lvs-privacy.md: never trimmed from a live answer), in the shapes the
// LVS's JavaScript and templates read (2026-10-21). periods_none.json,
// plan_no_period.json and profile_none.json have the shape the LVS answered
// a made-up pupil in a made-up class with (seen live); a real pupil's
// answers are the developer's capture step (#168). Smaller variants (an
// unknown shape, a refusal) are inline below.
//
// The fake Smartschool fails the test on any request that is not one of the
// service's support plan reads.
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
    File('test/fixtures/lvs/supportplan/$name').readAsStringSync();

Map<String, Object?> _json(String name) =>
    (jsonDecode(_fixture(name)) as Map).cast<String, Object?>();

/// The answer the LVS gives these reads: JSON as text, as `text/html`
/// (seen live).
ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
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

/// An answer of [body].
ResponseBody Function() _text(String body) =>
    () => _answer(body);

/// An answer of [json], encoded.
ResponseBody Function() _of(Object? json) => _text(jsonEncode(json));

/// A POST that the LVS sent on to Smartschool's start page: the redirect
/// itself (the client does not follow one after a POST).
ResponseBody _redirectToStartPage() => _answer(
  '',
  status: 302,
  headers: {
    'location': ['/?module=Homepage'],
  },
);

/// Smartschool's generic error page, with HTTP 500.
ResponseBody _errorPage() => _answer(
  '<!DOCTYPE html><html><body><h1>Oeps, er ging iets mis</h1></body></html>',
  status: 500,
);

/// The support plan reads, by the `file` and `function` of each: the key
/// [_Lvs.answers] takes.
const _reads = {
  ('jqDispatcher_settings', 'getLVSspecificTitles'): 'periods',
  ('jqDispatcher_hp', 'getIHP'): 'plan',
  ('jqDispatcher_hp', 'getProfielSchets'): 'sketch',
};

/// A Smartschool whose LVS answers the support plan reads of the service
/// with [answers], by read (the values of [_reads]). Any other request fails
/// the test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answers);

  final Map<String, ResponseBody Function()> answers;

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
    final query = uri.queryParameters;
    final read =
        options.method == 'POST' &&
            uri.path == '/' &&
            query['module'] == 'LVS' &&
            query.length == 3
        ? _reads[(query['file'], query['function'])]
        : null;
    if (read == null) {
      fail('Not a support plan read of LvsService: ${options.method} $uri');
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
  '1A',
  '9005',
  '9006',
  '9008',
  '/2030',
  '9002',
  '9003',
  'pdf',
  'PDF',
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

/// Each support plan read of pupil 900001 in class 900101, by its key in
/// [_reads], with what the read is called in messages.
final _calls = <String, (String, Future<Object?> Function(LvsService))>{
  'periods': (
    'the periods of the support plans',
    (lvs) => lvs.getSupportPlanPeriods(pupilId: 900001, classId: 900101),
  ),
  'plan': (
    "the pupil's support plan",
    (lvs) => lvs.getSupportPlan(pupilId: 900001, classId: 900101),
  ),
  'sketch': (
    "the pupil's profile sketch",
    (lvs) => lvs.getProfileSketch(pupilId: 900001, classId: 900101),
  ),
};

void main() {
  forbidRealNetwork();

  group('getSupportPlanPeriods', () {
    test('one POST of the period menu, as the web client asks for it above '
        'the plan', () async {
      final (server, lvs) = await _serve({'periods': _file('periods.json')});

      await lvs.getSupportPlanPeriods(pupilId: 900001, classId: 900101);

      expect(server.requests, [
        'POST /?module=LVS&file=jqDispatcher_settings'
            '&function=getLVSspecificTitles',
      ]);
      expect(server.forms.single, {
        'groupID': '900101',
        'pupilID': '900001',
        'type': 'hp_ihp',
        'activeID': '0',
        'color': '#418b09',
        'archiveID': '0',
      });
    });

    test("the periods in the LVS's order, as plain text, each with the "
        'heading before it; a heading is no period', () async {
      final (_, lvs) = await _serve({'periods': _file('periods.json')});

      final periods = await lvs.getSupportPlanPeriods(
        pupilId: 900001,
        classId: 900101,
      );

      expect(periods.map((p) => p.id), [900501, 900502]);
      expect(periods.map((p) => p.name), ['Testperiode', 'Testperiode 2']);
      expect(periods.map((p) => p.heading), [
        'Testschooljaar',
        'Testschooljaar',
      ]);
    });

    test('no menu (check 0, as for a class without a structure of support '
        'plans, seen live): no periods', () async {
      final (_, lvs) = await _serve({'periods': _file('periods_none.json')});

      expect(
        await lvs.getSupportPlanPeriods(pupilId: 900001, classId: 900101),
        isEmpty,
      );
    });

    test('a period before any heading has none', () async {
      final (_, lvs) = await _serve({
        'periods': _of({
          'check': 1,
          'titleMenu': [
            {'titleGroup': false, 'actionID': 900501, 'titleText': 'Test'},
          ],
        }),
      });

      final periods = await lvs.getSupportPlanPeriods(
        pupilId: 900001,
        classId: 900101,
      );

      expect(periods.single.heading, '');
    });
  });

  group('getSupportPlan', () {
    test('one POST of the live plan (exportID 0) of the current period '
        '(periodID 0) when none is given', () async {
      final (server, lvs) = await _serve({'plan': _file('plan.json')});

      await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(server.requests, [
        'POST /?module=LVS&file=jqDispatcher_hp&function=getIHP',
      ]);
      expect(server.forms.single, {
        'groupID': '900101',
        'pupilID': '900001',
        'periodID': '0',
        'exportID': '0',
      });
    });

    test('the period asked for', () async {
      final (server, lvs) = await _serve({'plan': _file('plan.json')});

      await lvs.getSupportPlan(
        pupilId: 900001,
        classId: 900101,
        periodId: 900502,
      );

      expect(server.forms.single['periodID'], '900502');
    });

    test("a plan: its period, and its items in the LVS's order, by "
        'kind', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.status, LvsSupportPlanStatus.plan);
      expect(plan.period.id, 900501);
      expect(plan.period.hasError, isFalse);
      expect(plan.period.message, 'Testperiode');
      expect(plan.period.isOpen, isTrue);
      expect(plan.items.map((i) => i.id), [900601, 900602, 900603, 900604]);
      expect(plan.items.map((i) => i.kind), [
        LvsPlanItemKind.needs,
        LvsPlanItemKind.goals,
        LvsPlanItemKind.goals,
        LvsPlanItemKind.document,
      ]);
      expect(plan.items.map((i) => i.type), [
        'ihp',
        'from_gwp',
        'from_gwp',
        'document',
      ]);
    });

    test('an item of support needs: the needs, main and work goals, '
        'approach with its comment, and courses, as plain text', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final needs = plan.items.first;
      expect(needs.supportNeeds, [
        'Testondersteuningsnood',
        'Tweede testnood & meer',
      ]);
      expect(needs.mainGoals, ['Testhoofddoel']);
      expect(needs.workGoals, ['Testwerkdoel', 'Tweede testwerkdoel']);
      expect(needs.approach, ['Testaanpak']);
      expect(needs.approachComment, 'Testcommentaar bij de aanpak.');
      expect(
        needs.approachCommentHtml,
        '<p>Testcommentaar bij de <i>aanpak</i>.</p>',
      );
      expect(needs.courses, ['Testvak']);
      expect(needs.author, 'Piet Peeters');
      expect(needs.date, '14/10/2030');
      expect(needs.versionId, 900611);
      expect(needs.versionType, 'normal');
      expect(needs.fromGroupPlan, isFalse);
      expect(needs.goals, isEmpty);
      expect(needs.theme, '');
      expect(needs.fileName, '');
    });

    test("goals taken over from the class's group plan: the theme, the start "
        'situation, and each goal with its domain, objectives, approach and '
        'planning', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final goals = plan.items[1];
      expect(goals.fromGroupPlan, isTrue);
      expect(goals.author, 'Céline Dupré');
      expect(goals.versionId, 900612);
      expect(goals.theme, 'Testthema');
      expect(goals.startSituation, 'Testbeginsituatie van de leerling.');
      expect(
        goals.startSituationHtml,
        '<p>Testbeginsituatie van de leerling.</p>',
      );
      expect(goals.supportNeeds, isEmpty);
      final [first, second] = goals.goals;
      expect(first.id, 900801);
      expect(first.name, 'Testdoel');
      expect(first.domain, 'Testdomein > Testsubdomein');
      expect(first.isDeprecated, isFalse);
      expect(first.objectives, ['Testdoelstelling']);
      expect(first.approach, ['Testaanpak bij het doel']);
      expect(first.planning, ['Testvak', 'Testvak 2', 'Testmoment']);
      // Without objectives, approach and planning; no longer in its
      // curriculum.
      expect(second.id, 900802);
      expect(second.domain, '');
      expect(second.isDeprecated, isTrue);
      expect(second.objectives, isEmpty);
      expect(second.approach, isEmpty);
      expect(second.planning, isEmpty);
    });

    test("goals chosen for the pupil (source new), of the school's own "
        'database', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final own = plan.items[2];
      expect(own.fromGroupPlan, isFalse);
      expect(own.versionType, 'eigendb');
      expect(own.theme, '');
      expect(own.startSituation, '');
      expect(own.goals.single.name, 'Testdoel van de school');
      expect(own.goals.single.domain, 'Testdomein');
    });

    test('texts as plain text keep their lines: a line break and each block '
        'of their HTML start a new line (#171)', () async {
      final (_, lvs) = await _serve({'plan': _file('plan_lines.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final [needs, goals] = plan.items;
      expect(needs.supportNeeds, ['Testnood op\ntwee regels']);
      expect(needs.workGoals, ['Testwerkdoel.\nTweede testalinea.']);
      expect(needs.approach, ['Testaanpak een\nTestaanpak twee']);
      expect(
        needs.approachComment,
        'Testcommentaar met\ntwee regels\nTweede testalinea.',
      );
      expect(
        needs.approachCommentHtml,
        '<p>Testcommentaar met<br>twee regels</p><p>Tweede testalinea.</p>',
      );
      expect(
        goals.startSituation,
        'Testbeginsituatie\nTestregel een\nTestregel twee',
      );
      final goal = goals.goals.single;
      expect(goal.name, 'Testdoel met\ntwee regels');
      expect(goal.objectives, [
        'Testdoelstelling een.\nTestdoelstelling twee.',
      ]);
    });

    test('an uploaded plan: its metadata only, the author by name', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final document = plan.items.last;
      expect(document.fileName, 'Testhandelingsplan.pdf');
      expect(document.mimeType, 'PDF');
      expect(document.author, 'Piet Peeters');
      expect(document.date, '02/11/2030');
      expect(document.versionId, isNull);
    });

    test('a pupil without a plan in the period: status noPlan, not a plan '
        'without needs', () async {
      final (_, lvs) = await _serve({'plan': _file('plan_none.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.status, LvsSupportPlanStatus.noPlan);
      expect(plan.items, isEmpty);
      expect(plan.period.hasError, isFalse);
      expect(plan.period.id, 900501);
    });

    test(
      'no period, as the LVS answers a class without a structure of '
      'support plans (seen live): status noPeriod, with its message',
      () async {
        final (_, lvs) = await _serve({'plan': _file('plan_no_period.json')});

        final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

        expect(plan.status, LvsSupportPlanStatus.noPeriod);
        expect(plan.items, isEmpty);
        expect(plan.period.hasError, isTrue);
        expect(plan.period.id, isNull);
        expect(plan.period.isOpen, isNull);
        expect(
          plan.period.message,
          'Testfout: maak eerst een structuur aan voor deze klas',
        );
      },
    );

    test('a closed period: the plan is read, the period is not open', () async {
      final json = _json('plan.json');
      final (_, lvs) = await _serve({
        'plan': _of({
          ...json,
          'period': {...(json['period'] as Map), 'currentlyInOpenPeriod': '0'},
        }),
      });

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.status, LvsSupportPlanStatus.plan);
      expect(plan.period.isOpen, isFalse);
      expect(plan.items, hasLength(4));
    });

    test(
      'items as a map (PHP, a list with gaps in its keys), and an item of '
      'a type the service does not know, kept with its ID and author',
      () async {
        final json = _json('plan.json');
        final items = json['items'] as List;
        final (_, lvs) = await _serve({
          'plan': _of({
            ...json,
            'items': {
              '0': items.first,
              '2': {
                'itemID': 900605,
                'type': 'gwp_other',
                'author': 'Piet Peeters',
                'lastversion': {'itemID': 900605},
              },
            },
          }),
        });

        final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

        expect(plan.items.map((i) => i.kind), [
          LvsPlanItemKind.needs,
          LvsPlanItemKind.unknown,
        ]);
        final unknown = plan.items.last;
        expect(unknown.id, 900605);
        expect(unknown.type, 'gwp_other');
        expect(unknown.author, 'Piet Peeters');
        expect(unknown.supportNeeds, isEmpty);
      },
    );
  });

  group('getSupportPlan: whose items, and which courses (#189)', () {
    test('the user ID of each item\'s author: authorID, and a document\'s '
        'author (its name is authorName)', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.items.map((i) => i.authorId), [
        900201,
        900202,
        900201,
        900201,
      ]);
      expect(plan.items.last.author, 'Piet Peeters');
    });

    test('the course IDs of an item: the keys of its courses flagged 1, as '
        "the web client's filter by course reads them; none for an empty "
        'map (PHP: []) and for a document', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.items.map((i) => i.courseIds), [
        [900301],
        // 900303 is flagged 0: not planned in it.
        [900301, 900302],
        isEmpty,
        isEmpty,
      ]);
    });

    test("each entry of a goal's planning with its kind and ID: a course's "
        'ID, another moment kept as it comes', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      final goal = plan.items[1].goals.first;
      expect(goal.moments.map((m) => m.type), ['course', 'course', 'other']);
      expect(goal.moments.map((m) => m.isCourse), [true, true, false]);
      expect(goal.moments.map((m) => m.id), [900301, 900302, null]);
      expect(goal.moments.map((m) => m.name), [
        'Testvak',
        'Testvak 2',
        'Testmoment',
      ]);
      expect(goal.planning, goal.moments.map((m) => m.name));
      // A goal without planning.
      expect(plan.items[1].goals.last.moments, isEmpty);
    });

    test("the plan's courses name the course IDs of its items and of their "
        'planning', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.courses.map((c) => c.id), [900301, 900302]);
      expect(plan.courses.map((c) => c.name), ['Testvak', 'Testvak 2']);
      final names = {for (final c in plan.courses) c.id: c.name};
      expect(plan.items[1].courseIds.map((id) => names[id]), [
        'Testvak',
        'Testvak 2',
      ]);
      expect(
        [
          for (final goal in plan.items[1].goals)
            for (final moment in goal.moments)
              if (moment.isCourse) names[moment.id],
        ],
        ['Testvak', 'Testvak 2'],
      );
    });

    test('an app tells the items of one author, or of one course, by their '
        'IDs: the items the web client keeps for that filter', () async {
      final (_, lvs) = await _serve({'plan': _file('plan.json')});

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

      expect(plan.items.where((i) => i.authorId == 900201).map((i) => i.id), [
        900601,
        900603,
        900604,
      ]);
      expect(
        plan.items.where((i) => i.courseIds.contains(900302)).map((i) => i.id),
        [900602],
      );
    });

    test('no courses, no author ID, no course IDs: empty, not an '
        'error', () async {
      final json = _json('plan.json');
      final items = (json['items'] as List).cast<Map<String, Object?>>();
      final needs = items.first;
      final goals = items[1];
      final version = (goals['lastversion'] as Map).cast<String, Object?>();
      final goal = ((version['doelen'] as List).first as Map)
          .cast<String, Object?>();
      for (final courses in [null, <Object?>[], <String, Object?>{}]) {
        final (_, lvs) = await _serve({
          'plan': _of({
            ...json,
            'courses': courses,
            'items': [
              {...needs, 'authorID': null, 'courses': null},
              {
                ...goals,
                'authorID': 0,
                'courses': <String, Object?>{},
                'lastversion': {
                  ...version,
                  'doelen': [
                    {
                      ...goal,
                      'occurrence': [
                        {'occName': 'Testmoment'},
                      ],
                    },
                  ],
                },
              },
            ],
          }),
        });

        final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

        expect(plan.courses, isEmpty, reason: '$courses');
        expect(plan.items.map((i) => i.authorId), [null, null]);
        expect(plan.items.map((i) => i.courseIds), [isEmpty, isEmpty]);
        final moment = plan.items.last.goals.single.moments.single;
        expect(moment.type, '');
        expect(moment.isCourse, isFalse);
        expect(moment.id, isNull);
        expect(moment.name, 'Testmoment');
      }
    });

    test(
      'courses as a map (PHP, a list with gaps in its keys), and an item '
      'of a type the service does not know, kept with its author ID',
      () async {
        final json = _json('plan.json');
        final courses = json['courses'] as List;
        final (_, lvs) = await _serve({
          'plan': _of({
            ...json,
            'courses': {'0': courses.first, '3': courses.last},
            'items': [
              {
                'itemID': 900605,
                'type': 'gwp_other',
                'author': 'Piet Peeters',
                'authorID': '900201',
                'courses': {'900301': 1},
              },
            ],
          }),
        });

        final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);

        expect(plan.courses.map((c) => c.id), [900301, 900302]);
        final unknown = plan.items.single;
        expect(unknown.kind, LvsPlanItemKind.unknown);
        expect(unknown.authorId, 900201);
        expect(unknown.courseIds, isEmpty);
      },
    );
  });

  group('getProfileSketch', () {
    test('one POST of the live sketch of the current period when none is '
        'given; the sketch as HTML and plain text', () async {
      final (server, lvs) = await _serve({'sketch': _file('profile.json')});

      final sketch = await lvs.getProfileSketch(
        pupilId: 900001,
        classId: 900101,
      );

      expect(server.requests, [
        'POST /?module=LVS&file=jqDispatcher_hp&function=getProfielSchets',
      ]);
      expect(server.forms.single, {
        'pupilID': '900001',
        'classID': '900101',
        'periodID': '0',
        'exportID': '0',
      });
      expect(sketch.hasSketch, isTrue);
      expect(
        sketch.html,
        '<p>Testprofielschets van de leerling: <b>sterk</b> in testen.</p>',
      );
      expect(
        sketch.text,
        'Testprofielschets van de leerling: sterk in testen.',
      );
      expect(sketch.lastRevision, 'Testversie van 01/10/2030');
      expect(sketch.period.id, 900501);
      // A closed period.
      expect(sketch.period.isOpen, isFalse);
    });

    test('the sketch as plain text keeps its lines: a line break and each '
        'block of its HTML start a new line (#171)', () async {
      final (_, lvs) = await _serve({'sketch': _file('profile_lines.json')});

      final sketch = await lvs.getProfileSketch(
        pupilId: 900001,
        classId: 900101,
      );

      expect(
        sketch.text,
        [
          'Testprofielschets',
          'Testtekst met',
          'twee regels',
          'Tweede testalinea.',
          'Sterk in testen',
          'Test graag',
        ].join('\n'),
      );
      expect(sketch.html, startsWith('<h3>Testprofielschets</h3><p>'));
    });

    test('the period asked for', () async {
      final (server, lvs) = await _serve({'sketch': _file('profile.json')});

      await lvs.getProfileSketch(
        pupilId: 900001,
        classId: 900101,
        periodId: 900502,
      );

      expect(server.forms.single['periodID'], '900502');
    });

    test("no sketch (check 0): the LVS's own message in its place is left "
        'out', () async {
      final (_, lvs) = await _serve({'sketch': _file('profile_none.json')});

      final sketch = await lvs.getProfileSketch(
        pupilId: 900001,
        classId: 900101,
      );

      expect(sketch.hasSketch, isFalse);
      expect(sketch.html, '');
      expect(sketch.text, '');
      expect(sketch.lastRevision, '');
      expect(sketch.period.hasError, isFalse);
    });

    test('no period, as for a made-up class (seen live): no sketch, the '
        "period's error", () async {
      final (_, lvs) = await _serve({
        'sketch': _of({
          ..._json('profile_none.json'),
          'period': _json('plan_no_period.json')['period'],
        }),
      });

      final sketch = await lvs.getProfileSketch(
        pupilId: 900001,
        classId: 900101,
      );

      expect(sketch.hasSketch, isFalse);
      expect(sketch.period.hasError, isTrue);
      expect(sketch.period.id, isNull);
    });
  });

  group('every support plan read', () {
    test('a 403 is a SmartschoolLvsAccessDeniedError, not an empty '
        'result', () async {
      for (final MapEntry(key: read, value: (what, call)) in _calls.entries) {
        final (_, lvs) = await _serve({read: () => _answer('', status: 403)});
        await expectLater(call(lvs), throwsA(_refused(what)), reason: read);
      }
    });

    test("a redirect to Smartschool's start page is a "
        'SmartschoolLvsAccessDeniedError', () async {
      for (final MapEntry(key: read, value: (what, call)) in _calls.entries) {
        final (_, lvs) = await _serve({read: _redirectToStartPage});
        await expectLater(call(lvs), throwsA(_refused(what)), reason: read);
      }
    });

    test("Smartschool's error page with a 500 is a SmartschoolLvsError with "
        'the status', () async {
      for (final MapEntry(key: read, value: (_, call)) in _calls.entries) {
        final (_, lvs) = await _serve({read: _errorPage});
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
          '"Testvak"',
          '[1]',
          '{"name": "Testvak"}',
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

    test('an answer without what the service needs, or with a value of '
        'another type, is a SmartschoolLvsError that names the field, not '
        'the value', () async {
      final periods = _json('periods.json');
      final plan = _json('plan.json');
      final items = plan['items'] as List;
      Map<String, Object?> item(int index) =>
          (items[index] as Map).cast<String, Object?>();
      Map<String, Object?> version(int index) =>
          (item(index)['lastversion'] as Map).cast<String, Object?>();
      Map<String, Object?> withItem(Map<String, Object?> changed) => {
        ...plan,
        'items': [changed],
      };
      final sketch = _json('profile.json');
      final broken = <String, List<Object?>>{
        'periods': [
          {...periods, 'check': 'Testperiode'},
          {...periods, 'check': null},
          {...periods, 'titleMenu': 'Testperiode'},
          {
            ...periods,
            'titleMenu': [
              {'titleText': 'Testperiode', 'actionID': 'Testperiode'},
            ],
          },
          {
            ...periods,
            'titleMenu': [
              {'actionID': 900501},
            ],
          },
          {
            ...periods,
            'titleMenu': ['Testperiode'],
          },
        ],
        'plan': [
          {...plan, 'period': null},
          {
            ...plan,
            'period': {'message': 'Testperiode'},
          },
          {
            ...plan,
            'period': {'error': 0, 'currentPeriodID': 'Testperiode'},
          },
          {...plan, 'items': 'Testvak'},
          withItem({...item(0), 'type': null}),
          withItem({...item(0), 'itemID': 'Testvak'}),
          withItem({...item(0), 'lastversion': null}),
          withItem({
            ...item(0),
            'lastversion': {...version(0), 'ihp': 'Testondersteuningsnood'},
          }),
          withItem({
            ...item(0),
            'lastversion': {
              ...version(0),
              'ihp': {
                'noden': [
                  {'ondName': null},
                ],
              },
            },
          }),
          withItem({
            ...item(0),
            'lastversion': {
              ...version(0),
              'ihp': {'hoofddoelen': 'Testhoofddoel'},
            },
          }),
          withItem({
            ...item(1),
            'lastversion': {...version(1), 'doelen': 'Testdoel'},
          }),
          withItem({
            ...item(1),
            'lastversion': {
              ...version(1),
              'doelen': [
                {'path': 'Testdomein'},
              ],
            },
          }),
          withItem({
            ...item(1),
            'lastversion': {
              ...version(1),
              'beginsituatie': {'Testbeginsituatie': 1},
            },
          }),
          withItem({...item(3), 'fileName': null}),
          withItem({...item(3), 'documentID': 0}),
          withItem({...item(3), 'mime': 'Testbijlage.pdf'}),
          // #189: the courses of the answer, an item's author ID and course
          // IDs, a goal's planning.
          {...plan, 'courses': 'Testvak'},
          {
            ...plan,
            'courses': [
              {'title': 'Testvak'},
            ],
          },
          {
            ...plan,
            'courses': [
              {'courseID': 900301},
            ],
          },
          {
            ...plan,
            'courses': ['Testvak'],
          },
          withItem({...item(0), 'authorID': 'Piet Peeters'}),
          withItem({...item(3), 'author': 'Piet Peeters'}),
          withItem({...item(0), 'courses': 'Testvak'}),
          withItem({
            ...item(0),
            'courses': [900301],
          }),
          withItem({
            ...item(0),
            'courses': {'Testvak': 1},
          }),
          withItem({
            ...item(1),
            'courses': {'900301': 'Testvak'},
          }),
          withItem({
            ...item(1),
            'lastversion': {
              ...version(1),
              'doelen': [
                {
                  'parentName': 'Testdoel',
                  'occurrence': [
                    {'occType': 'course', 'occID': 900301},
                  ],
                },
              ],
            },
          }),
          withItem({
            ...item(1),
            'lastversion': {
              ...version(1),
              'doelen': [
                {
                  'parentName': 'Testdoel',
                  'occurrence': [
                    {
                      'occType': 'course',
                      'occID': 'Testvak',
                      'occName': 'Testvak',
                    },
                  ],
                },
              ],
            },
          }),
        ],
        'sketch': [
          {...sketch, 'check': null},
          {...sketch, 'content': null},
          {...sketch, 'period': 'Testperiode'},
          {
            ...sketch,
            'period': {'error': 'Testfout'},
          },
        ],
      };
      for (final MapEntry(key: read, value: answers) in broken.entries) {
        final call = _calls[read]!.$2;
        for (final answer in answers) {
          final (_, lvs) = await _serve({read: _of(answer)});
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

    test('an ID that is not positive is an ArgumentError, before anything is '
        'sent', () async {
      final (server, lvs) = await _serve({});

      final calls = <Future<Object?> Function()>[
        () => lvs.getSupportPlanPeriods(pupilId: 0, classId: 900101),
        () => lvs.getSupportPlanPeriods(pupilId: 900001, classId: -1),
        () => lvs.getSupportPlan(pupilId: -5, classId: 900101),
        () => lvs.getSupportPlan(pupilId: 900001, classId: 0),
        () => lvs.getSupportPlan(pupilId: 900001, classId: 900101, periodId: 0),
        () => lvs.getProfileSketch(pupilId: 0, classId: 900101),
        () => lvs.getProfileSketch(pupilId: 900001, classId: 0),
        () => lvs.getProfileSketch(
          pupilId: 900001,
          classId: 900101,
          periodId: -900501,
        ),
      ];
      for (final (i, call) in calls.indexed) {
        await expectLater(call(), throwsArgumentError, reason: 'call $i');
      }
      expect(server.requests, isEmpty);
    });

    test('the models print counts, kinds and flags only', () async {
      final (_, lvs) = await _serve({
        'periods': _file('periods.json'),
        'plan': _file('plan.json'),
        'sketch': _file('profile.json'),
      });

      final plan = await lvs.getSupportPlan(pupilId: 900001, classId: 900101);
      final printed = <String>[
        for (final period in await lvs.getSupportPlanPeriods(
          pupilId: 900001,
          classId: 900101,
        ))
          '$period',
        '$plan',
        '${plan.period}',
        for (final item in plan.items) ...[
          '$item',
          for (final goal in item.goals) ...[
            '$goal',
            for (final moment in goal.moments) '$moment',
          ],
        ],
        for (final course in plan.courses) '$course',
        '${await lvs.getProfileSketch(pupilId: 900001, classId: 900101)}',
      ];

      expect(
        printed,
        everyElement(allOf(_quotesNothing, isNot(contains('Testvak')))),
      );
      expect(
        printed,
        containsAll([
          'LvsPlanPeriod(<values hidden>)',
          'LvsSupportPlan(status: plan, items: 4)',
          'LvsPlanPeriodInfo(hasError: false, isOpen: true)',
          'LvsPlanItem(kind: needs, supportNeeds: 2, mainGoals: 1, '
              'workGoals: 2, approach: 1, goals: 0)',
          'LvsPlanGoal(objectives: 1, approach: 1, planning: 3)',
          'LvsPlanMoment(isCourse: true)',
          'LvsPlanMoment(isCourse: false)',
          'LvsPlanCourse(<values hidden>)',
          'LvsProfileSketch(hasSketch: true)',
        ]),
      );
    });
  });

  group('the allowlist of the support plan reads', () {
    test('the reads of the service are on it', () {
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: const {
            'module': 'LVS',
            'file': 'jqDispatcher_settings',
            'function': 'getLVSspecificTitles',
          },
          form: const {
            'groupID': '900101',
            'pupilID': '900001',
            'type': 'hp_ihp',
            'activeID': '0',
            'color': '#418b09',
            'archiveID': '0',
          },
        ),
        same(LvsWire.supportPlanPeriods),
      );
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: const {
            'module': 'LVS',
            'file': 'jqDispatcher_hp',
            'function': 'getIHP',
          },
          form: const {
            'groupID': '900101',
            'pupilID': '900001',
            'periodID': '0',
            'exportID': '0',
          },
        ),
        same(LvsWire.supportPlan),
      );
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: const {
            'module': 'LVS',
            'file': 'jqDispatcher_hp',
            'function': 'getProfielSchets',
          },
          form: const {
            'pupilID': '900001',
            'classID': '900101',
            'periodID': '0',
            'exportID': '0',
          },
        ),
        same(LvsWire.profileSketch),
      );
    });

    test("the calls of the web client's edit flow, its other reads, and the "
        'reads with more, are refused before they are sent', () async {
      final server = _Lvs({});
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;
      final wire = LvsWire(client);

      Map<String, String> hp(
        String function, [
        String file = 'jqDispatcher_hp',
      ]) => {'module': 'LVS', 'file': file, 'function': function};
      const pupil = {'pupilID': '900001', 'groupID': '900101'};
      final refused =
          <(String, String, Map<String, String>, Map<String, String>)>[
            // The reads of the edit flow, and its lock of the synthesis.
            (
              'POST',
              '/',
              hp('getIHPondersteuningsnood'),
              const {'versionID': '900611', 'classID': '900101'},
            ),
            (
              'POST',
              '/',
              hp('getIHPhoofddoelen'),
              const {'versionID': '900611'},
            ),
            (
              'POST',
              '/',
              hp('getIHPWerkdoelen'),
              const {'versionID': '900611'},
            ),
            ('POST', '/', hp('getOD_doelstellingen'), const {...pupil}),
            (
              'POST',
              '/LVS/Handelingsplannen/checkSyntheseEditor',
              const {},
              const {...pupil},
            ),
            // The writes.
            ('POST', '/', hp('saveIHPversion'), const {...pupil}),
            (
              'POST',
              '/',
              hp('setProfielSchets'),
              const {...pupil, 'content': '<p>Testprofielschets.</p>'},
            ),
            ('POST', '/', hp('addHP_own_course'), const {...pupil}),
            ('POST', '/', hp('createIHPfromLoopbaan'), const {...pupil}),
            (
              'POST',
              '/',
              hp('deleteProfielSchetsVersion'),
              const {'revID': '900901'},
            ),
            ('POST', '/', hp('printIhp'), const {...pupil}),
            (
              'POST',
              '/',
              hp('generateReport', 'jqDispatcher_hpReport'),
              const {...pupil},
            ),
            (
              'POST',
              '/',
              hp('setLastPupil', 'jqDispatcher_settings'),
              const {'pupilID': '900001'},
            ),
            // The reads the service does not send: versions, the evaluation, the
            // report, the group plan.
            ('POST', '/', hp('getIHPitemVersions'), const {'itemID': '900601'}),
            (
              'POST',
              '/',
              hp('getProfielSchetsVersions'),
              const {'pupilID': '900001'},
            ),
            (
              'POST',
              '/',
              hp('getPupilEval', 'jqDispatcher_hpEval'),
              const {...pupil},
            ),
            (
              'POST',
              '/',
              hp('getPupilReport', 'jqDispatcher_hpReport'),
              const {...pupil},
            ),
            ('POST', '/', hp('getGwp'), const {...pupil}),
            // The reads, but not as the service sends them.
            ('GET', '/', hp('getIHP'), const {}),
            ('POST', '/', hp('getIHP'), const {...pupil, 'content': 'Test'}),
            (
              'POST',
              '/',
              {...hp('getIHP'), 'exportID': '900801'},
              const {...pupil},
            ),
            (
              'POST',
              '/',
              hp('getProfielSchets'),
              const {'pupilID': '900001', 'groupID': '900101'},
            ),
            (
              'POST',
              '/',
              hp('getLVSspecificTitles', 'jqDispatcher_hp'),
              const {...pupil},
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
