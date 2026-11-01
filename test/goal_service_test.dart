// Tests for issue #222: the curricula and learning goals of Smartschool's
// goal selector (`GoalService`), which the Lesfiches module and the planner
// open to pick the goals of a lesfiche or a lesson, and the naming of stored
// goals.
//
// The answers below are written by hand in the shapes seen live (2026-11-01,
// read only): the list of curricula in groups, a curriculum of the eindtermen
// (headings whose `metadata` is null, goals with HTML titles and a number in
// `metadata.prefix`), a mini-database of the school (heading, subheading and
// goals in plain text), and the answer that names a selection (one tree per
// curriculum, pruned). Every ID and title is made up; the made-up kinds of
// node (`cluster`) and the deprecated goal are not from a live answer.
//
// The service tests run the real SmartschoolClient against a fake
// Smartschool that answers the login chain and the selector's routes, and
// fails the test on any other request.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
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

const _api = '/goal/selector/api/v1/leerplannen';

const _eindtermenId = 'e0000000-0000-4000-8000-000000000001';
const _miniDbId = 'e0000000-0000-5000-8000-000000000002';
const _godsdienstId = 'e0000000-0000-4000-8000-000000000003';

const _domainId = 'f0000000-0000-4000-8000-000000000010';
const _goal1Id = 'f0000000-0000-4000-8000-000000000011';
const _goal2Id = 'f0000000-0000-4000-8000-000000000012';
const _clusterId = 'f0000000-0000-4000-8000-000000000013';
const _goal3Id = 'f0000000-0000-4000-8000-000000000014';

const _miniTitleId = 'f0000000-0000-4000-8000-000000000020';
const _miniSubtitleId = 'f0000000-0000-4000-8000-000000000021';
const _miniGoal1Id = 'f0000000-0000-4000-8000-000000000022';
const _miniGoal2Id = 'f0000000-0000-4000-8000-000000000023';

/// The list: two groups, the eindtermen and a mini-database of the school,
/// and a curriculum without metadata.
const _list =
    '''
[{"name":"Overheid SO","leerplanListItems":[
  {"id":"$_eindtermenId","title":"Eindtermen derde graad, voorbeeld","metadata":{"icon":"component_green","isVisible":true,"isFavourite":false}},
  {"id":"$_godsdienstId","title":"Godsdienst, voorbeeld","metadata":null}]},
 {"name":"Minidatabanken","leerplanListItems":[
  {"id":"$_miniDbId","title":"Digitale vaardigheden, voorbeeld","metadata":{"icon":"laptop","isVisible":false,"isFavourite":true}}]}]
''';

/// The eindtermen: a heading without metadata, two goals in HTML with their
/// numbers (the second deprecated), and a node of a kind the library does
/// not know with a goal under it.
const _eindtermen =
    '''
{"id":"$_eindtermenId","type":"eindtermen-derde-graad-doorstroom","title":"Eindtermen derde graad, voorbeeld","metadata":{"isDeprecated":false},
 "config":{"typesThatCanBeFiltered":["title","goal"],"filterObjects":[],"typesThatCanBeSelected":["goal"],"leerplanType":"eindtermen-derde-graad-doorstroom","tokens":[]},
 "children":[{"id":"$_domainId","type":"title","title":"Competenties voorbeeld","metadata":null,"children":[
   {"id":"$_goal1Id","type":"goal","title":"<p>De leerlingen passen  een <strong>voorbeeld</strong> toe &amp; meer.</p>","metadata":{"prefix":"01.01","icon":"target_lpd_redsoft"},"children":[]},
   {"id":"$_goal2Id","type":"goal","title":"<p>Een oud doel.</p>","metadata":{"prefix":"01.02","icon":"target_lpd_redsoft","isDeprecated":true},"children":[]},
   {"id":"$_clusterId","type":"cluster","title":"Een cluster","metadata":{},"children":[
     {"id":"$_goal3Id","type":"goal","title":"<p>Een doel in een cluster.</p>","metadata":{"prefix":"01.03"}}]}]}]}
''';

/// A mini-database: heading, subheading, goals in plain text.
const _miniDb =
    '''
{"id":"$_miniDbId","type":"miniDB","title":"Digitale vaardigheden, voorbeeld","metadata":{"isDeprecated":false},
 "config":{"typesThatCanBeFiltered":["title","subtitle","part","subpart","goal"],"typesThatCanBeSelected":["goal"],"leerplanType":"miniDB","tokens":[]},
 "children":[{"id":"$_miniTitleId","title":"Digitaal communiceren","type":"title","metadata":{"prefix":"GFL 1","number":"GFL 1","icon":null,"isDeprecated":false},"children":[
   {"id":"$_miniSubtitleId","title":"Het platform","type":"subtitle","metadata":{"prefix":"","number":"","icon":null,"isDeprecated":false},"children":[
     {"id":"$_miniGoal1Id","title":"Je kan navigeren","type":"goal","metadata":{"prefix":"","number":"","icon":null,"isDeprecated":false},"children":[]},
     {"id":"$_miniGoal2Id","title":"Je kan bestanden delen","type":"goal","metadata":{"prefix":"","number":"","icon":null,"isDeprecated":false},"children":[]}]}]}]}
''';

/// The named selection of [_goal1Id] and [_miniGoal2Id]: one tree per
/// curriculum, pruned (without `tokens`, as seen live).
const _resolved =
    '''
[{"id":"$_eindtermenId","type":"eindtermen-derde-graad-doorstroom","title":"Eindtermen derde graad, voorbeeld","metadata":{"isDeprecated":false},
  "config":{"typesThatCanBeSelected":["goal"],"leerplanType":"eindtermen-derde-graad-doorstroom"},
  "children":[{"id":"$_domainId","type":"title","title":"Competenties voorbeeld","metadata":null,"children":[
    {"id":"$_goal1Id","type":"goal","title":"<p>De leerlingen passen een voorbeeld toe.</p>","metadata":{"prefix":"01.01"},"children":[]}]}]},
 {"id":"$_miniDbId","type":"miniDB","title":"Digitale vaardigheden, voorbeeld","metadata":{"isDeprecated":false},
  "config":{"typesThatCanBeSelected":["goal"],"leerplanType":"miniDB"},
  "children":[{"id":"$_miniTitleId","title":"Digitaal communiceren","type":"title","metadata":{"prefix":"GFL 1"},"children":[
    {"id":"$_miniSubtitleId","title":"Het platform","type":"subtitle","metadata":{"prefix":""},"children":[
      {"id":"$_miniGoal2Id","title":"Je kan bestanden delen","type":"goal","metadata":{"prefix":""},"children":[]}]}]}]}]
''';

const _goal1Ref = LearningGoalRef(
  id: _goal1Id,
  leerplanId: _eindtermenId,
  type: 'eindtermen-derde-graad-doorstroom',
);
const _miniGoal2Ref = LearningGoalRef(
  id: _miniGoal2Id,
  leerplanId: _miniDbId,
  type: 'miniDB',
);

typedef _Answer = ({int status, String body, String? location});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, location: null);

/// Smartschool's answer to a request on a session it does not accept.
const _Answer _toLogin = (
  status: 302,
  body: '<html><body>Redirecting to /login</body></html>',
  location: '/login',
);

const _loginPage = '''
<html><body>
<form name="login_form" method="post" action="/login">
  <input type="hidden" name="login_form[_token]" value="t">
  <input type="text" name="login_form[_username]">
  <input type="password" name="login_form[_password]">
</form>
</body></html>
''';

/// A Smartschool whose session is accepted, that answers the selector's
/// requests with [answers] in turn (its last answer for every later one),
/// and the login chain, and fails the test on any other request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(List<_Answer> answers) : _answers = [...answers];

  final List<_Answer> _answers;
  bool _passwordDone = false;

  /// Every request that reached it, in order (`METHOD path`).
  final List<String> log = [];

  /// The bodies of the POSTs to the selector, decoded.
  final List<Object?> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final label = '${options.method} ${uri.path}';
    log.add(label);
    switch (label) {
      case 'GET /login':
        return _respond((status: 200, body: _loginPage, location: null));
      case 'POST /login':
        _passwordDone = true;
        return _respond((
          status: 302,
          body: '<html><body>Redirecting to /</body></html>',
          location: '/',
        ));
      case 'GET /':
        return _respond((status: 200, body: '<html>2fa</html>', location: null))
          ..redirects = [
            if (_passwordDone)
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
          ];
      case 'GET /2fa/api/v1/config':
        return _respond(
          _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        return _respond(_json('{"success":true,"redirectTo":"/"}'));
    }
    if (uri.path.startsWith('$_api/')) {
      if (options.method == 'POST') {
        final data = options.data;
        bodies.add(data is String ? jsonDecode(data) : data);
      }
      if (_answers.isEmpty) fail('Unexpected request: $label');
      return _respond(
        _answers.length > 1 ? _answers.removeAt(0) : _answers.single,
      );
    }
    fail('Unexpected request: ${options.method} $uri');
  }

  static ResponseBody _respond(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: [
        answer.body.trimLeft().startsWith('<')
            ? 'text/html; charset=UTF-8'
            : 'application/json',
      ],
      if (answer.location != null) 'location': [answer.location!],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// A plain [SmartschoolGoalError] with [statusCode], not an authentication
/// failure.
Matcher _goalError([Object? message = anything, Object? statusCode = isNull]) =>
    allOf(
      isNot(isA<SmartschoolAuthenticationError>()),
      isNot(isA<SmartschoolGoalAccessDeniedError>()),
      isNot(isA<SmartschoolCurriculumNotFoundError>()),
      isA<SmartschoolGoalError>()
          .having((e) => e.message, 'message', message)
          .having((e) => e.statusCode, 'statusCode', statusCode),
    );

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, GoalService)> serve(List<_Answer> answers) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, GoalService(client));
  }

  final day = DateTime(2026, 11, 1);

  // ---------------------------------------------------------------------------
  // getCurricula
  // ---------------------------------------------------------------------------

  group('GoalService.getCurricula', () {
    test('GETs leerplannen/lesson-content/list/{day} and returns the groups '
        'and their curricula in order', () async {
      final (server, goals) = await serve([_json(_list)]);

      final groups = await goals.getCurricula(date: day);

      expect(server.log, ['GET $_api/lesson-content/list/2026-11-01']);
      expect(groups.map((g) => g.name), ['Overheid SO', 'Minidatabanken']);
      expect(groups.first.curricula.map((c) => c.id), [
        _eindtermenId,
        _godsdienstId,
      ]);
      final eindtermen = groups.first.curricula.first;
      expect(eindtermen.title, 'Eindtermen derde graad, voorbeeld');
      expect(eindtermen.icon, 'component_green');
      expect(eindtermen.isVisible, isTrue);
      expect(eindtermen.isFavourite, isFalse);
      final mini = groups.last.curricula.single;
      expect(mini.icon, 'laptop');
      expect(mini.isVisible, isFalse);
      expect(mini.isFavourite, isTrue);
      final bare = groups.first.curricula.last;
      expect(bare.icon, isNull);
      expect(bare.isVisible, isTrue);
      expect(bare.isFavourite, isFalse);
    });

    test('takes the planner location and today by default', () async {
      final (server, goals) = await serve([_json('[]')]);

      expect(
        await goals.getCurricula(location: GoalLocation.plannerLessonContent),
        isEmpty,
      );
      expect(server.log, [
        'GET $_api/planner-lesson-content/list/'
            '${GoalService.formatDay(DateTime.now())}',
      ]);
    });

    test('logs in again and retries once for a session Smartschool does not '
        'accept', () async {
      final (server, goals) = await serve([_toLogin, _json(_list)]);

      final groups = await goals.getCurricula(date: day);

      expect(groups, hasLength(2));
      expect(server.log.where((r) => r.startsWith('GET $_api/')), hasLength(2));
      expect(server.log, contains('POST /login'));
    });

    test('a 403 is a SmartschoolGoalAccessDeniedError', () async {
      final (_, goals) = await serve([
        _json('{"status":403,"title":"Forbidden"}', status: 403),
      ]);

      await expectLater(
        goals.getCurricula(date: day),
        throwsA(
          isA<SmartschoolGoalAccessDeniedError>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    for (final (what, answer, message) in [
      ('another status', _json('oops', status: 500), contains('HTTP 500')),
      ('an HTML page', _json('<html>app</html>'), contains('HTML page')),
      ('invalid JSON', _json('[{'), contains('invalid JSON')),
      ('an empty body', _json(''), contains('empty body')),
      ('an object', _json('{}'), contains('instead of a list')),
      (
        'a group without its list',
        _json('[{"name":"x"}]'),
        contains('leerplanListItems'),
      ),
      (
        'a curriculum without its id',
        _json('[{"name":"x","leerplanListItems":[{"title":"y"}]}]'),
        contains('"id"'),
      ),
    ]) {
      test('$what is a SmartschoolGoalError', () async {
        final (_, goals) = await serve([answer]);

        await expectLater(
          goals.getCurricula(date: day),
          throwsA(
            _goalError(message, answer.status == 200 ? isNull : answer.status),
          ),
        );
      });
    }
  });

  // ---------------------------------------------------------------------------
  // getCurriculum
  // ---------------------------------------------------------------------------

  group('GoalService.getCurriculum', () {
    test('GETs leerplannen/{location}/{id}/{day} and reads the eindtermen: '
        'headings, goals in HTML with their numbers, deprecated and unknown '
        'nodes', () async {
      final (server, goals) = await serve([_json(_eindtermen)]);

      final tree = await goals.getCurriculum(_eindtermenId, date: day);

      expect(server.log, [
        'GET $_api/lesson-content/$_eindtermenId/2026-11-01',
      ]);
      expect(tree.id, _eindtermenId);
      expect(tree.type, 'eindtermen-derde-graad-doorstroom');
      expect(tree.leerplanType, 'eindtermen-derde-graad-doorstroom');
      expect(tree.title, 'Eindtermen derde graad, voorbeeld');
      expect(tree.isDeprecated, isFalse);
      expect(tree.selectableTypes, ['goal']);

      final domain = tree.children.single;
      expect(domain.type, CurriculumNodeType.title);
      expect(domain.prefix, isNull);
      expect(domain.isDeprecated, isFalse);
      expect(domain.children.map((n) => n.id), [
        _goal1Id,
        _goal2Id,
        _clusterId,
      ]);

      final goal1 = domain.children.first;
      expect(goal1.isGoal, isTrue);
      expect(
        goal1.title,
        '<p>De leerlingen passen  een <strong>voorbeeld</strong> toe &amp; '
        'meer.</p>',
      );
      expect(goal1.text, 'De leerlingen passen een voorbeeld toe & meer.');
      expect(goal1.prefix, '01.01');
      expect(goal1.number, isNull);
      expect(goal1.icon, 'target_lpd_redsoft');
      expect(domain.children[1].isDeprecated, isTrue);

      final cluster = domain.children.last;
      expect(cluster.type, CurriculumNodeType.other);
      expect(cluster.typeName, 'cluster');
      expect(cluster.isGoal, isFalse);
      expect(cluster.children.single.id, _goal3Id);
      expect(cluster.children.single.children, isEmpty);
    });

    test('Curriculum.goals lists every goal depth first, deprecated ones '
        'too, with the nodes above it and its reference', () async {
      final (_, goals) = await serve([_json(_eindtermen)]);

      final tree = await goals.getCurriculum(_eindtermenId, date: day);

      expect(tree.goals.map((g) => g.node.id), [_goal1Id, _goal2Id, _goal3Id]);
      expect(tree.goals.map((g) => g.node.isDeprecated), [false, true, false]);
      expect(tree.goals.last.path.map((n) => n.id), [_domainId, _clusterId]);
      expect(tree.goals.last.titles, [
        'Competenties voorbeeld',
        'Een cluster',
        'Een doel in een cluster.',
      ]);
      expect(tree.goals.first.ref, _goal1Ref);
      expect(tree.goal(_goal2Id)!.node.prefix, '01.02');
      expect(tree.goal(_domainId), isNull);
    });

    test('reads a mini-database: heading, subheading and goals in plain '
        'text', () async {
      final (server, goals) = await serve([_json(_miniDb)]);

      final tree = await goals.getCurriculum(
        _miniDbId,
        location: GoalLocation.plannerLessonContent,
        date: day,
      );

      expect(server.log, [
        'GET $_api/planner-lesson-content/$_miniDbId/2026-11-01',
      ]);
      expect(tree.leerplanType, 'miniDB');
      final heading = tree.children.single;
      expect(heading.type, CurriculumNodeType.title);
      expect(heading.prefix, 'GFL 1');
      expect(heading.number, 'GFL 1');
      final subtitle = heading.children.single;
      expect(subtitle.type, CurriculumNodeType.subtitle);
      expect(subtitle.prefix, isNull);
      expect(subtitle.number, isNull);
      expect(tree.goals.map((g) => g.node.text), [
        'Je kan navigeren',
        'Je kan bestanden delen',
      ]);
      expect(tree.goals.last.path.map((n) => n.id), [
        _miniTitleId,
        _miniSubtitleId,
      ]);
      expect(tree.goals.last.ref, _miniGoal2Ref);
    });

    test('a 404 is a SmartschoolCurriculumNotFoundError', () async {
      final (_, goals) = await serve([
        _json(
          '{"status":404,"title":"Not Found","detail":"","type":""}',
          status: 404,
        ),
      ]);

      await expectLater(
        goals.getCurriculum(_eindtermenId, date: day),
        throwsA(
          isA<SmartschoolCurriculumNotFoundError>()
              .having((e) => e.curriculumId, 'curriculumId', _eindtermenId)
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    for (final id in ['', '../list', 'a b', 'x?y']) {
      test('refuses the ID "$id" without sending anything', () async {
        final (server, goals) = await serve([]);

        expect(() => goals.getCurriculum(id), throwsArgumentError);
        expect(server.log, isEmpty);
      });
    }

    for (final (what, body, message) in [
      ('a list', '[]', contains('instead of an object')),
      (
        'a node without its type',
        '{"id":"x","children":[{"id":"y"}]}',
        contains('"type"'),
      ),
      (
        'a node without its id',
        '{"id":"x","children":[{"type":"goal"}]}',
        contains('"id"'),
      ),
      (
        'children that are not a list',
        '{"id":"x","children":{}}',
        contains('"children"'),
      ),
      (
        'a child that is not an object',
        '{"id":"x","children":[1]}',
        contains('child 0'),
      ),
    ]) {
      test('$what is a SmartschoolGoalError', () async {
        final (_, goals) = await serve([_json(body)]);

        await expectLater(
          goals.getCurriculum(_eindtermenId, date: day),
          throwsA(_goalError(message)),
        );
      });
    }
  });

  // ---------------------------------------------------------------------------
  // resolve
  // ---------------------------------------------------------------------------

  group('GoalService.resolve', () {
    test('POSTs the selection as the selector does (id, goalId, leerplanId, '
        'type; isView) and names the goals', () async {
      final (server, goals) = await serve([_json(_resolved)]);

      final named = await goals.resolve([_goal1Ref, _miniGoal2Ref], date: day);

      expect(server.log, ['POST $_api/lesson-content/2026-11-01']);
      expect(server.bodies.single, {
        'selection': [
          {
            'id': _goal1Id,
            'goalId': _goal1Id,
            'leerplanId': _eindtermenId,
            'type': 'eindtermen-derde-graad-doorstroom',
          },
          {
            'id': _miniGoal2Id,
            'goalId': _miniGoal2Id,
            'leerplanId': _miniDbId,
            'type': 'miniDB',
          },
        ],
        'isView': true,
      });
      expect(named.map((c) => c.id), [_eindtermenId, _miniDbId]);
      expect(
        GoalService.findGoal(named, _goal1Ref)!.node.text,
        'De leerlingen passen een voorbeeld toe.',
      );
      final mini = GoalService.findGoal(named, _miniGoal2Ref)!;
      expect(mini.titles, [
        'Digitaal communiceren',
        'Het platform',
        'Je kan bestanden delen',
      ]);
      expect(mini.ref, _miniGoal2Ref);
      expect(
        GoalService.findGoal(
          named,
          const LearningGoalRef(
            id: _goal2Id,
            leerplanId: _eindtermenId,
            type: 'x',
          ),
        ),
        isNull,
      );
      // The same goal ID under another curriculum is not that goal.
      expect(
        GoalService.findGoal(
          named,
          const LearningGoalRef(
            id: _goal1Id,
            leerplanId: _miniDbId,
            type: 'miniDB',
          ),
        ),
        isNull,
      );
    });

    test('the planner location', () async {
      final (server, goals) = await serve([_json('[]')]);

      expect(
        await goals.resolve(
          [_goal1Ref],
          location: GoalLocation.plannerLessonContent,
          date: day,
        ),
        isEmpty,
      );
      expect(server.log, ['POST $_api/planner-lesson-content/2026-11-01']);
    });

    test('a curriculum without the goal (an unknown goal ID, as seen live) '
        'names nothing', () async {
      final (_, goals) = await serve([
        _json(
          '[{"id":"$_miniDbId","type":"miniDB","title":"x",'
          '"metadata":{"isDeprecated":false},"config":{"leerplanType":"miniDB",'
          '"typesThatCanBeSelected":["goal"]},"children":[]}]',
        ),
      ]);

      final named = await goals.resolve([_miniGoal2Ref], date: day);

      expect(named.single.goals, isEmpty);
      expect(GoalService.findGoal(named, _miniGoal2Ref), isNull);
    });

    test('sends nothing for no goals', () async {
      final (server, goals) = await serve([]);

      expect(await goals.resolve(const []), isEmpty);
      expect(server.log, isEmpty);
    });

    test('is retried once after logging in again (it only reads)', () async {
      final (server, goals) = await serve([_toLogin, _json(_resolved)]);

      final named = await goals.resolve([_goal1Ref], date: day);

      expect(named, hasLength(2));
      expect(server.bodies, hasLength(2));
      expect(server.bodies.first, server.bodies.last);
    });

    test('refuses a goal without an id, leerplanId or type, without sending '
        'anything', () async {
      final (server, goals) = await serve([]);

      for (final ref in const [
        LearningGoalRef(id: '', leerplanId: 'l', type: 't'),
        LearningGoalRef(id: 'i', leerplanId: '', type: 't'),
        LearningGoalRef(id: 'i', leerplanId: 'l', type: ''),
      ]) {
        expect(() => goals.resolve([_goal1Ref, ref]), throwsArgumentError);
      }
      expect(server.log, isEmpty);
    });

    test('an object instead of a list is a SmartschoolGoalError', () async {
      final (_, goals) = await serve([_json('{}')]);

      await expectLater(
        goals.resolve([_goal1Ref], date: day),
        throwsA(_goalError(contains('instead of a list'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------

  group('LearningGoalRef', () {
    test('reads and writes a stored goal; equal by value', () {
      final ref = LearningGoalRef.fromJson({
        'id': _goal1Id,
        'leerplanId': _eindtermenId,
        'type': 'eindtermen-derde-graad-doorstroom',
        'extra': 1,
      });

      expect(ref, _goal1Ref);
      expect(ref.hashCode, _goal1Ref.hashCode);
      expect(ref.toJson(), {
        'id': _goal1Id,
        'leerplanId': _eindtermenId,
        'type': 'eindtermen-derde-graad-doorstroom',
      });
      expect(ref.toWire()['goalId'], _goal1Id);
      expect(ref, isNot(_miniGoal2Ref));
    });

    for (final missing in ['id', 'leerplanId', 'type']) {
      test('without its $missing is a FormatException', () {
        final json = {..._goal1Ref.toJson()}..remove(missing);
        expect(
          () => LearningGoalRef.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('GoalService.formatDay', () {
    test('pads the month and day', () {
      expect(GoalService.formatDay(DateTime(2027, 3, 4)), '2027-03-04');
      expect(
        GoalService.formatDay(DateTime.utc(2026, 12, 31, 23)),
        '2026-12-31',
      );
    });
  });

  group('Curriculum.fromJson', () {
    test('the goals of basic literacy and the extension goals of the first '
        'grade (seen live): goals the selector lets pick, by its config', () {
      final tree = GoalService.parseCurriculum({
        'id': 'x',
        'type': 'eindtermen-eerste-graad-a-stroom',
        'config': {
          'typesThatCanBeSelected': ['goal', 'goal-extension', 'goal-basic'],
          'leerplanType': 'eindtermen-eerste-graad-a-stroom',
        },
        'children': [
          {
            'id': 'h',
            'type': 'title',
            'metadata': null,
            'children': [
              {'id': 'a', 'type': 'goal', 'title': '<p>A&nbsp;</p>'},
              {'id': 'b', 'type': 'goal-basic', 'title': '<p>B</p>'},
              {'id': 'c', 'type': 'goal-extension', 'title': '<p>C</p>'},
            ],
          },
        ],
      });

      expect(tree.goals.map((g) => g.node.id), ['a', 'b', 'c']);
      expect(tree.goals.map((g) => g.node.type), [
        CurriculumNodeType.goal,
        CurriculumNodeType.goalBasic,
        CurriculumNodeType.goalExtension,
      ]);
      expect(tree.goals.every((g) => g.node.isGoal), isTrue);
      expect(tree.goals.first.node.text, 'A');
      expect(tree.children.single.isGoal, isFalse);
    });

    test('lists only the kinds of its config as goals', () {
      final tree = GoalService.parseCurriculum({
        'id': 'x',
        'type': 'miniDB',
        'config': {
          'typesThatCanBeSelected': ['goal'],
        },
        'children': [
          {'id': 'b', 'type': 'goal-basic', 'title': 'B'},
          {'id': 'a', 'type': 'goal', 'title': 'A'},
        ],
      });

      expect(tree.goals.map((g) => g.node.id), ['a']);
    });

    test('falls back to the root type for the leerplanType and to goals for '
        'the selectable types; reads a deprecated curriculum', () {
      final tree = GoalService.parseCurriculum({
        'id': 'x',
        'type': 'miniDB',
        'title': 't',
        'metadata': {'isDeprecated': true},
        'children': [
          {'id': 'g', 'type': 'goal', 'title': 'Doel'},
        ],
      });

      expect(tree.leerplanType, 'miniDB');
      expect(tree.isDeprecated, isTrue);
      expect(tree.selectableTypes, ['goal']);
      expect(tree.goals.single.ref.type, 'miniDB');
      expect(tree.goals.single.path, isEmpty);
    });
  });
}
