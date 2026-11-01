// Tests for issue #230: a lesson cluster of a teaching assignment (#229)
// planned for classes over a period (`PlannerService.planLessonCluster`),
// read back (`getPlannedLessonClusters`, `getPlannedLessonClustersOf`,
// `getDetail`, the moments of `getPlannedElements`) and moved to the
// planner's trash (`trashPlannedLessonCluster`).
//
// The answers below are written by hand in the shapes seen live on
// 2026-11-01 (the developer's own planner, one week far ahead, trashed
// again; the issue and test/live/planner_lesson_cluster_live_test.dart):
//   - POST /planner/api/v1/planned-lesson-clusters/ -> 201 with the planned
//       cluster in full (`lessonClusterId`, `teachingAssignmentId`,
//       `plannedLessonClusterContent`, a whole-day period from 00:00:00 to
//       23:59:59)
//   - POST .../planned-lesson-clusters/list -> the planned clusters of the
//       period in the short form (no info, content or cluster IDs)
//   - GET  /lesson-content/api/v1/teaching-assignments/{taPlatformId}/{taId}/
//       lesson-clusters/{platformId}/{id}/planned-lesson-clusters -> the
//       same short form
//   - GET  .../planned-elements/user/{id}: the class's hours of the course
//       as `planned-lesson-cluster-moments`, each with `plannedLessonClusters`
//       in the short form
//   - POST .../planned-lesson-clusters/{platformId}/{id}/trash (no body)
//       -> 200 `[]`; the detail is 404 afterwards
// with obvious fakes ("Jan Janssens" is the authenticated user
// `4069_1001_0`, class `4069_2001` "6A1", course informatica). The answers
// the planner did not give live (unusable answers, refusals) are made up
// from those.
//
// The fake Smartschool answers only the requests each test scripts (and the
// login chain), and fails the test on any other request: `DELETE` and a
// second plan or trash never get an answer.
import 'dart:convert';
import 'dart:io';
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

/// The authenticated user (Jan Janssens).
const _me = '4069_1001_0';

const _planId = 'a3000000-0000-4000-8000-000000000001';
const _clusterId = 'a3000000-0000-4000-8000-000000000002';
const _plannedId = 'e3000000-0000-4000-8000-000000000003';
const _momentId = 'e3000000-0000-4000-8000-000000000004';
const _courseId = 'c0000000-0000-4000-8000-000000000005';

const _api = '/planner/api/v1';
const _clusterPath =
    '/lesson-content/api/v1/teaching-assignments/4069/$_planId/'
    'lesson-clusters/4069/$_clusterId';
const _plannedPath = '$_api/planned-lesson-clusters/4069/$_plannedId';

/// The requests, as the fake logs them.
const _readCluster = 'GET $_clusterPath';
const _plan = 'POST $_api/planned-lesson-clusters/';
const _list = 'POST $_api/planned-lesson-clusters/list';
const _instances = 'GET $_clusterPath/planned-lesson-clusters';
const _readPlanned = 'GET $_plannedPath';
const _trash = 'POST $_plannedPath/trash';
const _readWeek = 'GET $_api/planned-elements/user/$_me';

/// The cluster to plan, kept by its IDs.
const _cluster = LessonClusterRef(
  id: _clusterId,
  platformId: 4069,
  teachingAssignment: TeachingAssignmentRef(id: _planId, platformId: 4069),
);

/// The course informatica, as a timetable slot names it.
const _course = PlannerCourse(
  id: _courseId,
  platformId: 4069,
  name: 'informatica',
);

/// The lesson cluster as the Lesfiches module gives it (#229).
final _clusterAnswer = jsonEncode({
  'id': _clusterId,
  'platformId': 4069,
  'teachingAssignmentId': _planId,
  'teachingAssignmentPlatformId': 4069,
  'name': 'Lussen',
  'icon': 'box_curver_blue',
  'isVisible': true,
  'position': 0,
  'goals': <Object>[],
  'numberOfLessons': 1,
});

/// Jan Janssens as an organiser.
const _organiser = {
  'id': _me,
  'pictureHash': 'initials_JJ',
  'pictureUrl': 'https://userpicture20.smartschool.be/initials_JJ',
  'description': {'startingWithFirstName': '', 'startingWithLastName': ''},
  'name': {
    'startingWithFirstName': 'Jan Janssens',
    'startingWithLastName': 'Janssens Jan',
  },
  'sort': 'janssens-jan',
  'deleted': false,
};

/// Wim Willems, a colleague, as an organiser.
const _colleague = {
  'id': '4069_1003_0',
  'name': {
    'startingWithFirstName': 'Wim Willems',
    'startingWithLastName': 'Willems Wim',
  },
  'deleted': false,
};

const _group = {
  'identifier': '4069_2001',
  'id': '4069_2001',
  'platformId': 4069,
  'name': '6A1',
  'type': 'K',
  'icon': 'briefcase',
  'sort': '6A1',
};

const _courseJson = {
  'id': _courseId,
  'platformId': 4069,
  'name': 'informatica',
  'scheduleCodes': ['INFO'],
  'icon': 'schoolbord',
  'courseCluster': {'id': 4, 'name': 'Informatica'},
  'isVisible': true,
};

/// The week of 11 to 15 January 2027 (winter time), as the planner gives
/// the period of a planned cluster.
const _wholeWeek = {
  'dateTimeFrom': '2027-01-11T00:00:00+01:00',
  'dateTimeTo': '2027-01-15T23:59:59+01:00',
  'wholeDay': true,
  'deadline': false,
};

/// A planned cluster in the short form of the list and of a moment.
Map<String, Object?> _short({Map<String, Object?> changes = const {}}) => {
  'id': _plannedId,
  'platformId': 4069,
  'name': 'Lussen',
  'icon': 'box_curver_blue',
  'period': _wholeWeek,
  'organisers': {
    'users': [_organiser],
  },
  'participants': {
    'users': <Object>[],
    'groups': [_group],
    'userRoles': <Object>[],
    'groupFilters': {'filters': <Object>[], 'additionalUsers': <Object>[]},
    'excludedUsers': <Object>[],
  },
  'isParticipant': false,
  'courses': [_courseJson],
  'isVisible': true,
  'capabilities': {'canUserTrash': true, 'canUserEdit': true},
  'plannedElementType': 'planned-lesson-clusters',
  'isCrossCurricular': false,
  'sort': '20270111',
  'unconfirmed': false,
  'pinned': false,
  'color': 'aqua-200',
  ...changes,
};

/// The planned cluster in full, as the plan's answer and the detail give it.
Map<String, Object?> _full({
  Map<String, Object?> changes = const {},
  Map<String, bool> capabilities = const {},
}) {
  final json = _short()
    ..addAll({
      'privateInfo': '',
      'publicInfo': '',
      'attachments': <Object>[],
      'courseLinks': <Object>[],
      'goals': <Object>[],
      'weblinks': <Object>[],
      'lessonClusterId': _clusterId,
      'lessonClusterPlatformId': 4069,
      'teachingAssignmentId': _planId,
      'teachingAssignmentPlatformId': 4069,
      'plannedLessonClusterContent': [
        {
          'position': 0,
          'id': 'e3000000-0000-4000-8000-000000000005',
          'platformId': 4069,
          'plannedLessonClusterId': _plannedId,
          'plannedLessonClusterPlatformId': 4069,
          'name': 'Herhaling: lussen',
          'plannedElementType': 'planned-lesson-cluster-lessons',
        },
      ],
      'reminders': <Object>[],
    })
    ..addAll(changes);
  json['capabilities'] = {
    ...json['capabilities']! as Map<String, Object?>,
    ...capabilities,
  };
  return json;
}

/// A moment of the planned cluster: a lesson hour of the class and course
/// on Thursday 14 January 2027.
Map<String, Object?> _moment() => {
  'id': _momentId,
  'platformId': 4069,
  'period': {
    'dateTimeFrom': '2027-01-14T10:15:00+01:00',
    'dateTimeTo': '2027-01-14T11:05:00+01:00',
    'wholeDay': false,
    'deadline': false,
  },
  'organisers': {
    'users': [_organiser],
    'groups': <Object>[],
  },
  'participants': {
    'users': <Object>[],
    'groups': [_group],
    'userRoles': <Object>[],
    'groupFilters': {'filters': <Object>[], 'additionalUsers': <Object>[]},
  },
  'plannedElementType': 'planned-lesson-cluster-moments',
  'isParticipant': false,
  'capabilities': {'canUserTrash': false},
  'courses': [_courseJson],
  'locations': <Object>[],
  'plannedLessonClusters': [_short()],
  'sort': '20270114101500',
  'unconfirmed': false,
  'pinned': false,
  'color': 'aqua-200',
};

/// A timetable slot of the same week, which stays as it is.
Map<String, Object?> _slot() => {
  ..._moment(),
  'id': 'e3000000-0000-5000-8000-000000000006',
  'plannedElementType': 'planned-placeholders',
}..remove('plannedLessonClusters');

/// The body that plans [_cluster] for class 4069_2001 and informatica from
/// 11 to 15 January 2027.
Map<String, Object?> _planBody() => {
  'lessonClusterId': _clusterId,
  'lessonClusterPlatformId': 4069,
  'period': {
    'dateTimeFrom': '2027-01-11',
    'dateTimeTo': '2027-01-15',
    'wholeDay': true,
  },
  'participants': {
    'users': <Object>[],
    'groups': ['4069_2001'],
    'groupFilters': {'additionalUsers': <Object>[], 'filters': <Object>[]},
    'excludedUsers': <Object>[],
  },
  'courses': [
    {'id': _courseId, 'platformId': '4069'},
  ],
  'isCrossCurricular': false,
};

/// The planner's answer to the detail of an element it does not have.
const _notFound = '{"status":404,"title":"Not Found","detail":"","type":""}';

/// Smartschool's home page, trimmed to the script that holds the
/// authenticated user (`vars.authenticatedUser`).
const _homePage =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>\n'
    '<script>\n'
    'APP.extend(APP.vars || {}, JSON.parse(\'{"vars":{"authenticatedUser":'
    '{"id":"$_me","name":{"startingWithFirstName":"Jan Janssens",'
    '"startingWithLastName":"Janssens Jan"}}}}\'));\n'
    '</script>\n'
    '</body></html>';

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

typedef _Answer = ({int status, String body, String? location});

_Answer _json(Object body, {int status = 200}) => (
  status: status,
  body: body is String ? body : jsonEncode(body),
  location: null,
);

/// Smartschool's answer to a JSON POST on a session it does not accept: a
/// `302` to `/login`, which the HTTP client leaves unfollowed (#22).
const _Answer _toLogin = (
  status: 302,
  body: '<html><body>Redirecting to /login</body></html>',
  location: '/login',
);

/// A request as it reached the fake Smartschool: its body decoded when it
/// is JSON.
typedef _Request = ({String label, Object? body});

/// A Smartschool whose session is accepted, that answers the planner and
/// Lesfiches requests of [answers] (by label, `METHOD path`; a list is
/// answered in turn, its last answer for every later request), the reads
/// the client makes for the authenticated user, and the login chain; and
/// fails the test on any other request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(Map<String, List<_Answer>> answers, {this.failures = const {}})
    : _answers = {
        for (final MapEntry(:key, :value) in answers.entries) key: [...value],
      };

  final Map<String, List<_Answer>> _answers;
  final Map<String, Object Function(RequestOptions options)> failures;

  bool _passwordDone = false;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The labels of the requests to the planner and the Lesfiches module, in
  /// order.
  List<String> get moduleLog => [
    for (final r in requests)
      if (r.label.contains('/planner/') || r.label.contains('/lesson-content/'))
        r.label,
  ];

  /// The labels of every request, in order.
  List<String> get log => [for (final r in requests) r.label];

  /// The body of the one request [label].
  Object? bodyOf(String label) =>
      requests.singleWhere((r) => r.label == label).body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final label = '${options.method} ${options.uri.path}';
    final text = requestStream == null
        ? ''
        : utf8.decode(
            await requestStream.fold<List<int>>(
              <int>[],
              (all, chunk) => all..addAll(chunk),
            ),
          );
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    requests.add((label: label, body: body));

    final failure = failures[label];
    if (failure != null) throw failure(options);

    switch (label) {
      case 'GET /course-list/api/v1/courses':
        return _respond(_json([_courseJson]));
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
        if (_passwordDone) {
          return _respond((
              status: 200,
              body: '<html>2fa</html>',
              location: null,
            ))
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
            ];
        }
        return _respond((status: 200, body: _homePage, location: null));
      case 'GET /2fa/api/v1/config':
        return _respond(
          _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        return _respond(_json('{"success":true,"redirectTo":"/"}'));
    }

    final queue = _answers[label];
    if (queue == null || queue.isEmpty) {
      fail('Unexpected request: ${options.method} ${options.uri}');
    }
    return _respond(queue.length > 1 ? queue.removeAt(0) : queue.single);
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

/// The plan went out without the planner confirming it.
Matcher _unconfirmed(Object? message, {Object? statusCode = anything}) =>
    isA<SmartschoolPlannerSaveUnconfirmedError>()
        .having((e) => e.message, 'message', message)
        .having((e) => e.message, 'message', contains('may or may not'))
        .having((e) => e.statusCode, 'statusCode', statusCode);

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService)> serve(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures = const {},
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers, failures: failures);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client));
  }

  Future<PlannedLessonCluster> plan(PlannerService planner) =>
      planner.planLessonCluster(
        cluster: _cluster,
        from: DateTime(2027, 1, 11),
        to: DateTime(2027, 1, 15),
        groupIds: ['4069_2001'],
        courses: [_course],
      );

  group('PlannerService.planLessonCluster', () {
    test('reads the cluster, then plans it once with the body of the web '
        'client: whole days as yyyy-MM-dd, a course\'s platformId as a '
        'string; returns the planned cluster linked to the cluster', () async {
      final (server, planner) = await serve({
        _readCluster: [_json(_clusterAnswer)],
        _plan: [_json(_full(), status: 201)],
      });

      final planned = await plan(planner);

      expect(server.moduleLog, [_readCluster, _plan]);
      expect(server.bodyOf(_plan), _planBody());
      expect(planned.id, _plannedId);
      expect(planned.type, PlannedElementType.lessonCluster);
      expect(planned.lessonCluster, _cluster);
      expect(
        planned.lessonCluster!.teachingAssignment,
        _cluster.teachingAssignment,
      );
      expect(planned.isCrossCurricular, isFalse);
      expect(planned.period.wholeDay, isTrue);
      expect(planned.period.from, DateTime(2027, 1, 11));
      expect(planned.period.to, DateTime(2027, 1, 15, 23, 59, 59));
      expect(planned.participantGroups.single.id, '4069_2001');
      expect(planned.organiserUsers.single.id, _me);
      expect(planned.plannedContent, hasLength(1));
      expect(planned.goals, isEmpty);
      expect(planned.toString(), contains(_clusterId));
    });

    test(
      'sends only the dates of from and to, each class and course once',
      () async {
        final (server, planner) = await serve({
          _readCluster: [_json(_clusterAnswer)],
          _plan: [_json(_full(), status: 201)],
        });

        await planner.planLessonCluster(
          cluster: _cluster,
          from: DateTime(2027, 1, 11, 15, 30),
          to: DateTime(2027, 1, 15, 8),
          groupIds: ['4069_2001', '4069_2001'],
          courses: [_course, _course],
        );

        expect(server.bodyOf(_plan), _planBody());
      },
    );

    test('refuses bad arguments before anything is sent', () async {
      final (server, planner) = await serve({});
      Future<void> refused(Future<Object?> Function() call, String name) =>
          expectLater(
            call,
            throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name)),
          );
      Future<PlannedLessonCluster> withArgs({
        DateTime? from,
        DateTime? to,
        List<String> groups = const ['4069_2001'],
        List<PlannerCourse> courses = const [_course],
      }) => planner.planLessonCluster(
        cluster: _cluster,
        from: from ?? DateTime(2027, 1, 11),
        to: to ?? DateTime(2027, 1, 15),
        groupIds: groups,
        courses: courses,
      );

      await refused(() => withArgs(groups: []), 'groupIds');
      await refused(() => withArgs(groups: ['6A1']), 'groupIds');
      await refused(() => withArgs(courses: []), 'courses');
      await refused(
        () => withArgs(
          courses: [const PlannerCourse(id: ' ', platformId: 4069, name: '')],
        ),
        'courses',
      );
      await refused(
        () => withArgs(from: DateTime(2027, 1, 15), to: DateTime(2027, 1, 14)),
        'to',
      );
      // A school year runs from 1 September to 31 August.
      await refused(
        () => withArgs(from: DateTime(2027, 8, 30), to: DateTime(2027, 9, 3)),
        'to',
      );
      expect(server.moduleLog, isEmpty);
    });

    test('plans one day: from and to on the same date', () async {
      final (server, planner) = await serve({
        _readCluster: [_json(_clusterAnswer)],
        _plan: [
          _json(
            _full(
              changes: {
                'period': {
                  'dateTimeFrom': '2027-01-11T00:00:00+01:00',
                  'dateTimeTo': '2027-01-11T23:59:59+01:00',
                  'wholeDay': true,
                },
              },
            ),
            status: 201,
          ),
        ],
      });

      await planner.planLessonCluster(
        cluster: _cluster,
        from: DateTime(2027, 1, 11, 9),
        to: DateTime(2027, 1, 11, 8),
        groupIds: ['4069_2001'],
        courses: [_course],
      );

      final body = server.bodyOf(_plan)! as Map<String, dynamic>;
      expect(body['period'], {
        'dateTimeFrom': '2027-01-11',
        'dateTimeTo': '2027-01-11',
        'wholeDay': true,
      });
    });

    test('refuses a cluster the Lesfiches module does not have (404) before '
        'the plan, and passes on another failure of that read', () async {
      final (server, planner) = await serve({
        _readCluster: [
          _json('{"error":"Resource not found"}', status: 404),
          _json('{}', status: 500),
        ],
      });

      await expectLater(
        plan(planner),
        throwsA(
          isA<SmartschoolPlannerWriteRefusedError>()
              .having(
                (e) => e.reason,
                'reason',
                PlannerWriteRefusalReason.unknownLessonCluster,
              )
              .having((e) => e.element, 'element', isNull)
              .having((e) => e.message, 'message', contains(_clusterId))
              .having(
                (e) => e.message,
                'message',
                contains('Nothing was sent'),
              ),
        ),
      );
      await expectLater(
        plan(planner),
        throwsA(
          isA<SmartschoolLessonContentError>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      expect(server.moduleLog, [_readCluster, _readCluster]);
    });

    group('an answer that does not confirm the plan', () {
      for (final (what, answer, message) in [
        (
          'another cluster',
          _json(
            _full(
              changes: {
                'lessonClusterId': 'a3000000-0000-4000-8000-000000000009',
              },
            ),
            status: 201,
          ),
          contains('of lesson cluster a3000000-0000-4000-8000-000000000009'),
        ),
        (
          'the short form, which names no cluster',
          _json(_short(), status: 201),
          contains('of lesson cluster null'),
        ),
        (
          'another period',
          _json(
            _full(
              changes: {
                'period': {
                  ..._wholeWeek,
                  'dateTimeTo': '2027-01-22T23:59:59+01:00',
                },
              },
            ),
            status: 201,
          ),
          contains('a planned cluster from'),
        ),
        (
          'a colleague\'s',
          _json(
            _full(
              changes: {
                'organisers': {
                  'users': [_colleague],
                },
              },
            ),
            status: 201,
          ),
          contains('not organised by $_me'),
        ),
        (
          'a lesson',
          _json(
            _full(changes: {'plannedElementType': 'planned-lessons'}),
            status: 201,
          ),
          contains('a planned-lessons instead of a planned lesson cluster'),
        ),
        ('HTTP 500', _json('{}', status: 500), contains('cannot be used')),
        (
          'an HTML page',
          (status: 201, body: '<html></html>', location: null),
          contains('cannot be used'),
        ),
      ]) {
        test('$what: unconfirmed, sent once', () async {
          final (server, planner) = await serve({
            _readCluster: [_json(_clusterAnswer)],
            _plan: [answer],
          });

          await expectLater(
            plan(planner),
            throwsA(
              _unconfirmed(
                allOf(
                  message,
                  contains('planLessonCluster'),
                  contains('getPlannedLessonClusters'),
                ),
              ),
            ),
          );
          expect(server.moduleLog, [_readCluster, _plan]);
        });
      }

      test('a connection that drops: unconfirmed, sent once', () async {
        final (server, planner) = await serve(
          {
            _readCluster: [_json(_clusterAnswer)],
          },
          failures: {_plan: _dropped},
        );

        await expectLater(
          plan(planner),
          throwsA(_unconfirmed(contains('no answer came in'))),
        );
        expect(server.moduleLog, [_readCluster, _plan]);
      });
    });

    test('a session refused for the plan is not retried after logging in '
        'again', () async {
      final (server, planner) = await serve({
        _readCluster: [_json(_clusterAnswer)],
        _plan: [_toLogin, _json(_full(), status: 201)],
      });

      await expectLater(
        plan(planner),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.moduleLog, [_readCluster, _plan]);
    });
  });

  group('reading planned lesson clusters back', () {
    test('getPlannedLessonClusters lists those of the own planner in the '
        'days asked for, in the short form', () async {
      final (server, planner) = await serve({
        _list: [
          _json([_short()]),
        ],
      });

      final listed = await planner.getPlannedLessonClusters(
        from: DateTime(2027, 1, 11, 12),
        to: DateTime(2027, 1, 15),
      );

      expect(server.bodyOf(_list), {
        'id': _me,
        'type': 'user',
        'period': {
          'dateTimeFrom': '2027-01-11',
          'dateTimeTo': '2027-01-15',
          'wholeDay': true,
        },
      });
      expect(listed.single.id, _plannedId);
      expect(listed.single.name, 'Lussen');
      expect(listed.single.lessonCluster, isNull);
      expect(listed.single.plannedContent, isEmpty);
      expect(listed.single.toString(), isNot(contains('of cluster')));
    });

    test('getPlannedLessonClusters refuses to before from, and an answer '
        'that is not a list', () async {
      final (server, planner) = await serve({
        _list: [_json('{}')],
      });

      expect(
        () => planner.getPlannedLessonClusters(
          from: DateTime(2027, 1, 15),
          to: DateTime(2027, 1, 14),
        ),
        throwsArgumentError,
      );
      await expectLater(
        planner.getPlannedLessonClusters(
          from: DateTime(2027, 1, 11),
          to: DateTime(2027, 1, 15),
        ),
        throwsA(isA<SmartschoolPlannerError>()),
      );
      expect(server.moduleLog, [_list]);
    });

    test('getPlannedLessonClustersOf lists where the cluster was planned, '
        'linked to it', () async {
      final (server, planner) = await serve({
        _instances: [
          _json([_short()]),
        ],
      });

      final instances = await planner.getPlannedLessonClustersOf(_cluster);

      expect(server.moduleLog, [_instances]);
      expect(instances.single.id, _plannedId);
      expect(instances.single.lessonCluster, _cluster);
    });

    test(
      'getDetail of a planned cluster is a PlannedLessonCluster in full',
      () async {
        final (_, planner) = await serve({
          _readPlanned: [_json(_full())],
        });

        final detail = await planner.getDetail(
          PlannerService.parsePlannedElements([_short()]).single,
        );

        expect(detail, isA<PlannedLessonCluster>());
        expect((detail as PlannedLessonCluster).lessonCluster, _cluster);
      },
    );

    test('the week lists the moments of a planned cluster, each naming the '
        'planned clusters in it; other elements name none', () async {
      final (_, planner) = await serve({
        _readWeek: [
          _json([_moment(), _slot()]),
        ],
      });

      final week = await planner.getPlannedElements(
        PlannerCalendar.user(_me),
        from: DateTime(2027, 1, 11),
        to: DateTime(2027, 1, 15, 23, 59, 59),
      );

      final [moment, slot] = week;
      expect(moment.type, PlannedElementType.lessonClusterMoment);
      expect(moment.plannedLessonClusters!.single.id, _plannedId);
      expect(moment.plannedLessonClusters!.single.lessonCluster, isNull);
      expect(slot.type, PlannedElementType.placeholder);
      expect(slot.plannedLessonClusters, isNull);
    });

    test('a planned cluster that names its cluster without the IDs of its '
        'teaching assignment is an error', () {
      expect(
        () => PlannedLessonCluster.fromJson(
          _full()..remove('teachingAssignmentId'),
        ),
        throwsA(isA<SmartschoolPlannerError>()),
      );
      expect(
        () => PlannedLessonCluster.fromJson(
          _full(changes: {'plannedElementType': 'planned-lessons'}),
        ),
        throwsA(isA<SmartschoolPlannerError>()),
      );
    });
  });

  group('PlannerService.trashPlannedLessonCluster', () {
    final listed = PlannedLessonCluster.fromJson(_short());

    test('reads it again, moves it to the trash once without a body, and '
        'returns once its detail is gone', () async {
      final (server, planner) = await serve({
        _readPlanned: [_json(_full()), _json(_notFound, status: 404)],
        _trash: [_json('[]')],
      });

      await planner.trashPlannedLessonCluster(listed);

      expect(server.moduleLog, [_readPlanned, _trash, _readPlanned]);
      expect(server.bodyOf(_trash), isNull);
      expect(server.log, isNot(contains(startsWith('DELETE'))));
    });

    test('refuses a colleague\'s and one the planner does not let the user '
        'trash, before anything is sent', () async {
      final (server, planner) = await serve({
        _readPlanned: [
          _json(
            _full(
              changes: {
                'organisers': {
                  'users': [_colleague],
                },
              },
            ),
          ),
          _json(_full(capabilities: {'canUserTrash': false})),
        ],
      });

      await expectLater(
        planner.trashPlannedLessonCluster(listed),
        throwsA(
          isA<SmartschoolPlannerWriteRefusedError>().having(
            (e) => e.reason,
            'reason',
            PlannerWriteRefusalReason.notOwn,
          ),
        ),
      );
      await expectLater(
        planner.trashPlannedLessonCluster(listed),
        throwsA(
          isA<SmartschoolPlannerWriteRefusedError>()
              .having(
                (e) => e.reason,
                'reason',
                PlannerWriteRefusalReason.notAllowed,
              )
              .having((e) => e.capabilityFlags, 'flags', ['canUserTrash']),
        ),
      );
      expect(server.moduleLog, [_readPlanned, _readPlanned]);
    });

    test(
      'refuses another element than a planned cluster, a moment too',
      () async {
        final (server, planner) = await serve({});
        final moment = PlannerService.parsePlannedElements([_moment()]).single;

        expect(
          () => planner.trashPlannedLessonCluster(moment),
          throwsArgumentError,
        );
        expect(server.moduleLog, isEmpty);
      },
    );

    test(
      'one that is gone already is a SmartschoolPlannedElementNotFoundError',
      () async {
        final (server, planner) = await serve({
          _readPlanned: [_json(_notFound, status: 404)],
        });

        await expectLater(
          planner.trashPlannedLessonCluster(listed),
          throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
        );
        expect(server.moduleLog, [_readPlanned]);
      },
    );

    test('a detail still there after the trash, or an answer that is not a '
        'list: unconfirmed', () async {
      final (server, planner) = await serve({
        _readPlanned: [_json(_full())],
        _trash: [_json('[]'), _json('{}')],
      });

      await expectLater(
        planner.trashPlannedLessonCluster(listed),
        throwsA(
          _unconfirmed(
            allOf(
              contains('still has the planned lesson cluster'),
              contains('read the planned lesson cluster again'),
            ),
          ),
        ),
      );
      await expectLater(
        planner.trashPlannedLessonCluster(listed),
        throwsA(_unconfirmed(contains('instead of a list'))),
      );
      expect(server.moduleLog, [
        _readPlanned,
        _trash,
        _readPlanned,
        _readPlanned,
        _trash,
      ]);
    });
  });

  test('the flow of the issue: plan, find it in the list and among the '
      'cluster\'s instances, read it in full, trash it', () async {
    final (server, planner) = await serve({
      _readCluster: [_json(_clusterAnswer)],
      _plan: [_json(_full(), status: 201)],
      _list: [
        _json([_short()]),
        _json(<Object>[]),
      ],
      _instances: [
        _json([_short()]),
      ],
      _readPlanned: [
        _json(_full()),
        _json(_full()),
        _json(_notFound, status: 404),
      ],
      _trash: [_json('[]')],
    });
    final from = DateTime(2027, 1, 11);
    final to = DateTime(2027, 1, 15);

    final planned = await plan(planner);
    final listed = await planner.getPlannedLessonClusters(from: from, to: to);
    expect(listed.map((c) => c.id), [planned.id]);
    final instances = await planner.getPlannedLessonClustersOf(
      planned.lessonCluster!,
    );
    expect(instances.single.lessonCluster, _cluster);
    final detail = await planner.getDetail(listed.single);
    expect((detail as PlannedLessonCluster).lessonCluster, _cluster);
    await planner.trashPlannedLessonCluster(listed.single);
    expect(await planner.getPlannedLessonClusters(from: from, to: to), isEmpty);

    expect(server.moduleLog, [
      _readCluster,
      _plan,
      _list,
      _instances,
      _readPlanned,
      _readPlanned,
      _trash,
      _readPlanned,
      _list,
    ]);
  });
}
