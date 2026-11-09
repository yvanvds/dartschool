// Tests for issue #229: the year plans of the Lesfiches module
// (TeachingAssignmentService): teaching assignments and their lesson
// clusters, with lesfiches, titles and goals, against a fake Smartschool.
//
// Its answers are written by hand in the shapes seen live on 2026-11-01 in
// the developer's own library (made-up names and IDs here: the owner is the
// fake user `4069_1001_0`):
// - `GET teaching-assignments/{userId}` answers an array of teaching
//   assignments (`[]` for a teacher without one);
// - `POST teaching-assignments/{userId}` answers `201` with the teaching
//   assignment: `{id, platformId, owner: <user>, name, icon, collaborators:
//   [{user, privileges, contentFilter: {type, values}}], publication,
//   lessonClusters: [], visibility, favourite}`;
// - `GET teaching-assignments/{platformId}/{id}` answers the same, its
//   `lessonClusters` in short (`{id, platformId, name, icon, position,
//   isVisible}`); `DELETE` of it `204`;
// - `GET .../{platformId}/{id}/lesson-content` answers lesfiches in the list
//   shape;
// - `POST teaching-assignments/{userId}/{p}/{id}/lesson-clusters` answers
//   `201` with the cluster: `{id, platformId, teachingAssignmentId,
//   teachingAssignmentPlatformId, name, icon, privateInfo: {text,
//   attachments, weblinks}, publicInfo, isVisible, position, goals,
//   numberOfLessons, numberOfAssignments, numberOfGoals,
//   teachingHoursEstimate, numberOfAttachments, numberOfWebLinks}`;
// - `POST .../lesson-clusters/{p}/{id}/titles` answers `200` with the title
//   (`{id, platformId, lessonClusterId, lessonClusterPlatformId, position,
//   text, "type": "titles"}`);
// - `POST .../lesson-content-from-teaching-assignment` answers `201` with
//   `{"lessonContent": [<the lesfiches>], "exceptions": []}`, or per
//   lesfiche refused an exception keyed `{platformId}_lesson_{id}` with the
//   status `403`;
// - `GET .../lesson-cluster-content` answers the titles and lesfiches in
//   order, a lesfiche with `lessonClusterId`, `position`,
//   `teachingHoursEstimate` (`null` when new) and `numberOfGoals`;
// - `POST .../change-goals` answers `200` with the cluster.
//
// The live test of the same is
// test/live/teaching_assignment_live_test.dart.
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

const _me = '4069_1001_0';
const _api = '/lesson-content/api/v1/teaching-assignments';
const _taId = 'a2290000-0000-4000-8000-000000000001';
const _clusterId = 'a2290000-0000-4000-8000-000000000002';
const _titleId = 'a2290000-0000-4000-8000-000000000003';
const _lessonId = 'a2290000-0000-4000-8000-000000000011';
const _otherLessonId = 'a2290000-0000-4000-8000-000000000012';
const _thirdLessonId = 'a2290000-0000-4000-8000-000000000013';

const _ta = TeachingAssignmentRef(id: _taId, platformId: 4069);
const _cluster = LessonClusterRef(
  id: _clusterId,
  platformId: 4069,
  teachingAssignment: _ta,
);
const _clusterPath = '$_api/4069/$_taId/lesson-clusters/4069/$_clusterId';

const _goal = LearningGoalRef(
  id: 'd2290000-0000-4000-8000-000000000041',
  leerplanId: 'd2290000-0000-4000-8000-000000000040',
  type: 'miniDB',
);

const _courses = 'GET /course-list/api/v1/courses';

Map<String, Object?> _user([String id = _me]) => {
  'id': id,
  'pictureHash': '4069_00000000-0000-4000-8000-000000000000',
  'pictureUrl': 'https://example.com/picture',
  'description': {'startingWithFirstName': '', 'startingWithLastName': ''},
  'name': {
    'startingWithFirstName': 'Jan Janssens',
    'startingWithLastName': 'Janssens Jan',
  },
  'sort': 'janssens-jan',
  'deleted': false,
};

Map<String, Object?> _taJson({
  String name = 'Informatica 5',
  String filter = 'all',
  List<Object?> clusters = const [],
}) => {
  'id': _taId,
  'platformId': 4069,
  'owner': _user(),
  'name': name,
  'icon': 'box_curver_blue',
  'collaborators': [
    {
      'user': _user(),
      'privileges': {'read': true, 'edit': true, 'delete': true},
      'contentFilter': {'type': filter, 'values': null},
    },
  ],
  'publication': null,
  'lessonClusters': clusters,
  'visibility': true,
  'favourite': false,
};

Map<String, Object?> _clusterJson({
  String name = 'Lussen',
  List<Object?> goals = const [],
  int lessons = 0,
  int? goalCount,
}) => {
  'id': _clusterId,
  'platformId': 4069,
  'teachingAssignmentId': _taId,
  'teachingAssignmentPlatformId': 4069,
  'name': name,
  'icon': 'box_curver_blue',
  'privateInfo': {'text': '<p>Voor mij</p>', 'attachments': [], 'weblinks': []},
  'publicInfo': {'text': '', 'attachments': [], 'weblinks': []},
  'isVisible': true,
  'position': 0,
  'goals': goals,
  'numberOfLessons': lessons,
  'numberOfAssignments': 0,
  'numberOfGoals': goalCount ?? goals.length,
  'teachingHoursEstimate': 0,
  'numberOfAttachments': 0,
  'numberOfWebLinks': 0,
};

Map<String, Object?> _lessonJson({String id = _lessonId, Object? owner}) => {
  'id': id,
  'platformId': 4069,
  'name': 'Lussen 1',
  'icon': 'document_observation',
  'publicInfo': '',
  'isVisible': true,
  'owner': owner ?? _me,
  'dateStateChanged': '2026-11-01 19:12:41',
  'dateLastChanged': '2026-11-01 19:12:41',
  'courses': [],
  'labels': [],
  'weblinks': [],
  'partnerWeblinks': [],
  'attachments': [],
  'deeplinks': [],
  'capabilities': {'canUserSeeDetails': true, 'canUserEdit': true},
  'type': 'lessons',
};

Map<String, Object?> _titleJson({String text = 'Week 1', int position = 0}) => {
  'id': _titleId,
  'platformId': 4069,
  'lessonClusterId': _clusterId,
  'lessonClusterPlatformId': 4069,
  'position': position,
  'text': text,
  'type': 'titles',
};

final _lesson = LessonContentItem.fromJson(_lessonJson());
final _otherLesson = LessonContentItem.fromJson(
  _lessonJson(id: _otherLessonId),
);
final _thirdLesson = LessonContentItem.fromJson(
  _lessonJson(id: _thirdLessonId),
);

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

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(Object? body, {int status = 200}) => (
  status: status,
  body: body is String ? body : jsonEncode(body),
  contentType: 'application/json',
);

_Answer _problem(int status, String title) => (
  status: status,
  body: jsonEncode({
    'status': status,
    'title': title,
    'detail': '',
    'type': '',
  }),
  contentType: 'application/problem+json',
);

const _Answer _noContent = (status: 204, body: '', contentType: '');
const _Answer _unauthorized = (status: 401, body: '', contentType: '');

typedef _Request = ({String label, Object? data, Map<String, dynamic> query});

/// A Smartschool that answers each request (`METHOD path`) with the next
/// answer of its queue (the last one again when one is left), logs in when
/// asked to, and records what reached it.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(Map<String, List<_Answer>> answers)
    : _answers = {
        for (final entry in answers.entries) entry.key: [...entry.value],
      };

  final Map<String, List<_Answer>> _answers;
  bool _passwordDone = false;
  final List<_Request> requests = [];

  List<String> get calls => [
    for (final r in requests)
      if (!r.label.endsWith('/login') &&
          !r.label.contains('/2fa') &&
          r.label != 'GET /' &&
          r.label != _courses)
        r.label,
  ];

  List<Object?> bodiesOf(String label) => [
    for (final r in requests)
      if (r.label == label) r.data,
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final label = '${options.method} ${options.uri.path}';
    requests.add((
      label: label,
      data: options.data,
      query: options.uri.queryParameters,
    ));
    switch (label) {
      case 'GET /login':
        return _respond((
          status: 200,
          body: _loginPage,
          contentType: 'text/html',
        ));
      case 'POST /login':
        _passwordDone = true;
        return _respond((
          status: 302,
          body: '<html><body>Redirecting to /</body></html>',
          contentType: 'text/html',
        ), location: '/');
      case 'GET /':
        if (_passwordDone) {
          return _respond((
              status: 200,
              body: '<html>2fa</html>',
              contentType: 'text/html',
            ))
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
            ];
        }
        return _respond((
          status: 200,
          body: _homePage,
          contentType: 'text/html',
        ));
      case 'GET /2fa/api/v1/config':
        return _respond(
          _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        return _respond(_json('{"success":true,"redirectTo":"/"}'));
      case _courses:
        // The client reads the platform ID from the course list.
        return _respond(
          _json([
            {
              'id': 'c2290000-0000-4000-8000-000000000005',
              'platformId': 4069,
              'name': 'informatica',
              'scheduleCodes': ['INFO'],
              'icon': 'schoolbord',
              'courseCluster': null,
              'isVisible': true,
            },
          ]),
        );
    }
    final queue = _answers[label];
    if (queue == null || queue.isEmpty) fail('Unexpected request: $label');
    return _respond(queue.length > 1 ? queue.removeAt(0) : queue.single);
  }

  static ResponseBody _respond(_Answer answer, {String? location}) =>
      ResponseBody.fromString(
        answer.body,
        answer.status,
        headers: {
          if (answer.contentType.isNotEmpty)
            Headers.contentTypeHeader: [answer.contentType],
          'location': ?(location == null ? null : [location]),
        },
      );

  @override
  void close({bool force = false}) {}
}

Matcher _refused(int status) => allOf(
  isA<SmartschoolLessonContentWriteRefusedError>()
      .having((e) => e.statusCode, 'statusCode', status)
      .having((e) => e.message, 'message', contains('Nothing was changed')),
);

Matcher _unconfirmed(Object? message) =>
    isA<SmartschoolLessonContentSaveUnconfirmedError>().having(
      (e) => e.message,
      'message',
      message,
    );

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, TeachingAssignmentService)> serve(
    Map<String, List<_Answer>> answers,
  ) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, TeachingAssignmentService(client));
  }

  group('teaching assignments', () {
    test('getTeachingAssignments reads teaching-assignments/{userId}: the '
        'owner, the content filter, and the clusters in short, each naming '
        'its teaching assignment', () async {
      final (server, plans) = await serve({
        'GET $_api/$_me': [
          _json([
            _taJson(
              clusters: [
                {
                  'id': _clusterId,
                  'platformId': 4069,
                  'name': 'Lussen',
                  'icon': 'box_curver_blue',
                  'position': 0,
                  'isVisible': true,
                },
              ],
            ),
          ]),
        ],
      });

      final list = await plans.getTeachingAssignments();

      expect(server.calls, ['GET $_api/$_me']);
      final plan = list.single;
      expect(plan.id, _taId);
      expect(plan.platformId, 4069);
      expect(plan.ownerId, _me);
      expect(plan.name, 'Informatica 5');
      expect(plan.icon, 'box_curver_blue');
      expect(plan.contentFilter, TeachingAssignmentContentFilter.all);
      expect(plan.isVisible, isTrue);
      expect(plan.isFavourite, isFalse);
      expect(plan == _ta, isTrue);
      final cluster = plan.clusters.single;
      expect(cluster.name, 'Lussen');
      expect(cluster.position, 0);
      expect(cluster.teachingAssignment, _ta);
      expect(cluster == _cluster, isTrue);
      expect(cluster.numberOfLessons, isNull);
      expect(cluster.toWire(), {'id': _clusterId, 'platformId': 4069});
    });

    test('getTeachingAssignments reads an empty list', () async {
      final (_, plans) = await serve({
        'GET $_api/$_me': [_json([])],
      });
      expect(await plans.getTeachingAssignments(), isEmpty);
    });

    test('getTeachingAssignment reads {platformId}/{id}; a 404 is a '
        'SmartschoolLessonContentError with that status', () async {
      final (server, plans) = await serve({
        'GET $_api/4069/$_taId': [
          _json(_taJson(filter: 'none')),
          _problem(404, 'Not Found'),
        ],
      });

      final plan = await plans.getTeachingAssignment(_ta);
      expect(plan.contentFilter, TeachingAssignmentContentFilter.none);
      await expectLater(
        plans.getTeachingAssignment(_ta),
        throwsA(
          isA<SmartschoolLessonContentError>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(server.calls, ['GET $_api/4069/$_taId', 'GET $_api/4069/$_taId']);
    });

    test('createTeachingAssignment sends the web client\'s body once and '
        'returns the teaching assignment', () async {
      final (server, plans) = await serve({
        'POST $_api/$_me': [_json(_taJson(), status: 201)],
      });

      final plan = await plans.createTeachingAssignment(
        name: '  Informatica 5 ',
      );

      expect(plan.id, _taId);
      expect(server.calls, ['POST $_api/$_me']);
      expect(server.bodiesOf('POST $_api/$_me').single, {
        'name': 'Informatica 5',
        'icon': 'box_curver_blue',
        'contentFilter': {
          'type': 'all',
          'labels': [],
          'labelFilterType': 'oneOf',
          'courses': [],
          'courseFilterType': 'oneOf',
          'assignmentTypes': [],
        },
        'privileges': {'read': true, 'edit': true, 'delete': true},
        'collaborators': {'users': [], 'groups': []},
        'publication': null,
      });
    });

    test('createTeachingAssignment is not sent again after a refused '
        'session', () async {
      final (server, plans) = await serve({
        'POST $_api/$_me': [_unauthorized, _json(_taJson(), status: 201)],
      });

      await expectLater(
        plans.createTeachingAssignment(name: 'Informatica 5'),
        throwsA(isA<SmartschoolAuthenticationError>()),
      );
      expect(server.bodiesOf('POST $_api/$_me'), hasLength(1));
    });

    test('createTeachingAssignment: another name in the answer is '
        'unconfirmed; a refusal is refused', () async {
      final (_, plans) = await serve({
        'POST $_api/$_me': [
          _json(_taJson(name: 'Iets anders'), status: 201),
          _problem(400, 'Bad Request'),
        ],
      });

      await expectLater(
        plans.createTeachingAssignment(name: 'Informatica 5'),
        throwsA(_unconfirmed(contains('Iets anders'))),
      );
      await expectLater(
        plans.createTeachingAssignment(name: 'Informatica 5'),
        throwsA(_refused(400)),
      );
    });

    test('createTeachingAssignment refuses a bad name, icon or filter '
        'without sending anything', () async {
      final (server, plans) = await serve({});

      for (final call in [
        () => plans.createTeachingAssignment(name: '  '),
        () => plans.createTeachingAssignment(name: 'x' * 51),
        () => plans.createTeachingAssignment(name: 'a', icon: ' '),
        () => plans.createTeachingAssignment(
          name: 'a',
          contentFilter: TeachingAssignmentContentFilter.particular,
        ),
      ]) {
        await expectLater(call(), throwsArgumentError);
      }
      expect(server.calls, isEmpty);
    });

    test('deleteTeachingAssignment sends DELETE {platformId}/{id}, retried '
        'after logging in again; a 404 is refused', () async {
      final (server, plans) = await serve({
        'DELETE $_api/4069/$_taId': [
          _unauthorized,
          _noContent,
          _problem(404, 'Not Found'),
        ],
      });

      await plans.deleteTeachingAssignment(_ta);
      expect(server.calls, [
        'DELETE $_api/4069/$_taId',
        'DELETE $_api/4069/$_taId',
      ]);
      await expectLater(
        plans.deleteTeachingAssignment(_ta),
        throwsA(_refused(404)),
      );
    });

    test('a reference whose ID is not a UUID is an ArgumentError, before '
        'anything is sent', () async {
      final (server, plans) = await serve({});
      const bad = TeachingAssignmentRef(id: 'x', platformId: 4069);
      await expectLater(plans.getTeachingAssignment(bad), throwsArgumentError);
      await expectLater(
        plans.deleteTeachingAssignment(bad),
        throwsArgumentError,
      );
      expect(server.calls, isEmpty);
    });

    test('getLessonContent reads the lesfiches it takes, the owner as a '
        'user object', () async {
      final (server, plans) = await serve({
        'GET $_api/4069/$_taId/lesson-content': [
          _json([_lessonJson(owner: _user())]),
        ],
      });

      final items = await plans.getLessonContent(_ta);

      expect(server.calls, ['GET $_api/4069/$_taId/lesson-content']);
      expect(items.single.id, _lessonId);
      expect(items.single.ownerId, _me);
      expect(items.single.type, LessonContentType.lesson);
    });
  });

  group('lesson clusters', () {
    test('getClusters reads {userId}/{p}/{id}/lesson-clusters with the '
        'metadata: counts, info and goals', () async {
      final path = 'GET $_api/$_me/4069/$_taId/lesson-clusters';
      final (server, plans) = await serve({
        path: [
          _json([
            _clusterJson(goals: [_goal.toJson()], lessons: 2),
          ]),
        ],
      });

      final cluster = (await plans.getClusters(_ta)).single;

      expect(server.calls, [path]);
      expect(server.requests.last.query, {'includeMetadata': 'true'});
      expect(cluster.teachingAssignment, _ta);
      expect(cluster.name, 'Lussen');
      expect(cluster.privateInfo, '<p>Voor mij</p>');
      expect(cluster.publicInfo, '');
      expect(cluster.goals, [_goal]);
      expect(cluster.numberOfLessons, 2);
      expect(cluster.numberOfGoals, 1);
      expect(cluster.teachingHoursEstimate, 0);
    });

    test('numberOfGoals is the count of the module, which also counts the '
        "goals of the cluster's lesfiches, not goals.length (#237)", () async {
      // As seen live (smartschool-mcp#206): a cluster with two lesfiches of
      // 2 goals each and 1 goal of its own counted 3, and 2 once its own
      // goal was cleared; with no estimate in its lesfiches its estimate
      // was 0.
      final path = 'GET $_api/$_me/4069/$_taId/lesson-clusters';
      final (_, plans) = await serve({
        path: [
          _json([
            _clusterJson(goals: [_goal.toJson()], lessons: 2, goalCount: 3),
          ]),
          _json([_clusterJson(lessons: 2, goalCount: 2)]),
        ],
      });

      final withGoal = (await plans.getClusters(_ta)).single;
      expect(withGoal.goals, [_goal]);
      expect(withGoal.numberOfGoals, 3);
      expect(withGoal.teachingHoursEstimate, 0);

      final cleared = (await plans.getClusters(_ta)).single;
      expect(cleared.goals, isEmpty);
      expect(cleared.numberOfGoals, 2);
    });

    test('getCluster reads one cluster', () async {
      final (server, plans) = await serve({
        'GET $_clusterPath': [_json(_clusterJson())],
      });
      final cluster = await plans.getCluster(_cluster);
      expect(server.calls, ['GET $_clusterPath']);
      expect(cluster == _cluster, isTrue);
    });

    test('addCluster sends {name, icon, isVisible} once and returns the '
        'cluster', () async {
      final path = 'POST $_api/$_me/4069/$_taId/lesson-clusters';
      final (server, plans) = await serve({
        path: [_json(_clusterJson(), status: 201)],
      });

      final cluster = await plans.addCluster(_ta, name: ' Lussen ');

      expect(cluster.id, _clusterId);
      expect(server.bodiesOf(path).single, {
        'name': 'Lussen',
        'icon': 'box_curver_blue',
        'isVisible': true,
      });
    });

    test('addCluster: a cluster of another name is unconfirmed', () async {
      final path = 'POST $_api/$_me/4069/$_taId/lesson-clusters';
      final (_, plans) = await serve({
        path: [_json(_clusterJson(name: 'Anders'), status: 201)],
      });
      await expectLater(
        plans.addCluster(_ta, name: 'Lussen'),
        throwsA(_unconfirmed(contains('Anders'))),
      );
    });

    test('getClusterContent reads titles and lesfiches in order', () async {
      final (server, plans) = await serve({
        'GET $_clusterPath/lesson-cluster-content': [
          _json([
            _titleJson(),
            {
              ..._lessonJson(),
              'lessonClusterId': _clusterId,
              'lessonClusterPlatformId': 4069,
              'position': 1,
              'teachingHoursEstimate': null,
              'numberOfGoals': 0,
            },
          ]),
        ],
      });

      final entries = await plans.getClusterContent(_cluster);

      expect(server.calls, ['GET $_clusterPath/lesson-cluster-content']);
      expect(entries, hasLength(2));
      final title = entries.first as LessonClusterTitle;
      expect(title.text, 'Week 1');
      expect(title.position, 0);
      expect(title.lessonClusterId, _clusterId);
      final fiche = entries.last as LessonClusterLesfiche;
      expect(fiche.item.id, _lessonId);
      expect(fiche.position, 1);
      expect(fiche.teachingHoursEstimate, isNull);
      expect(fiche.numberOfGoals, 0);
    });

    test('addTitle sends {text} once and returns the title', () async {
      final path = 'POST $_clusterPath/titles';
      final (server, plans) = await serve({
        path: [_json(_titleJson())],
      });

      final title = await plans.addTitle(_cluster, ' Week 1 ');

      expect(title.id, _titleId);
      expect(title.text, 'Week 1');
      expect(server.bodiesOf(path).single, {'text': 'Week 1'});
      await expectLater(plans.addTitle(_cluster, ' '), throwsArgumentError);
      await expectLater(
        plans.addTitle(_cluster, 'x' * 51),
        throwsArgumentError,
      );
      expect(server.bodiesOf(path), hasLength(1));
    });

    group('addLessonContent', () {
      const path = 'POST $_clusterPath/lesson-content-from-teaching-assignment';

      test('sends the identifiers once (a lesfiche given twice once) and '
          'returns the lesfiches added', () async {
        final (server, plans) = await serve({
          path: [
            _json({
              'lessonContent': [_lessonJson()],
              'exceptions': [],
            }, status: 201),
          ],
        });

        final added = await plans.addLessonContent(_cluster, [
          _lesson,
          _lesson,
        ]);

        expect(added.single.id, _lessonId);
        expect(server.bodiesOf(path).single, {
          'lessonContentIdentifiers': [
            {'id': _lessonId, 'type': 'lessons', 'platformId': 4069},
          ],
        });
      });

      test('a lesfiche refused by the content filter (403 for each) is '
          'refused', () async {
        final (_, plans) = await serve({
          path: [
            _json({
              'lessonContent': [],
              'exceptions': {
                '4069_lesson_$_lessonId': {'status': 403},
              },
            }, status: 201),
          ],
        });
        await expectLater(
          plans.addLessonContent(_cluster, [_lesson]),
          throwsA(_refused(403)),
        );
      });

      test('some added, one refused and one not named carries each as data '
          '(#244)', () async {
        final (server, plans) = await serve({
          path: [
            _json({
              'lessonContent': [_lessonJson()],
              'exceptions': {
                '4069_lesson_$_otherLessonId': {
                  'status': 403,
                  'title': 'Forbidden',
                  'detail': '',
                  'type': '',
                },
              },
            }, status: 201),
          ],
        });

        final error = await plans
            .addLessonContent(_cluster, [
              _lesson,
              _otherLesson,
              _thirdLesson,
              _lesson,
            ])
            .then<Object?>((_) => null, onError: (Object e) => e);

        expect(server.bodiesOf(path), hasLength(1));
        expect(
          error,
          _unconfirmed(
            allOf(
              contains('only lesfiche $_lessonId'),
              contains('do not add them again'),
              contains('lesfiche $_otherLessonId: {"status":403'),
              contains('it named nothing for lesfiche $_thirdLessonId'),
            ),
          ),
        );
        final e = error! as SmartschoolLessonContentBulkSaveUnconfirmedError;
        expect(e.statusCode, 201);
        expect(e.cause, isNull);
        expect(e.lessonContentId, isNull);
        expect(e.items, [_lesson, _otherLesson, _thirdLesson]);
        expect(e.done, [_lesson]);
        expect(e.added.keys, [_lesson]);
        expect(e.added[_lesson]!.id, _lessonId);
        expect(e.added[_lesson]!.name, 'Lussen 1');
        expect(e.copies, isEmpty);
        expect(e.failed.keys, [_otherLesson]);
        final failure = e.failed[_otherLesson]!;
        expect(failure.statusCode, 403);
        expect(failure.message, 'Forbidden');
        expect(failure.raw, containsPair('status', 403));
        expect(e.unanswered, [_thirdLesson]);
      });

      test('a single lesfiche the answer does not name is unanswered, with '
          'its ID (#244)', () async {
        final (_, plans) = await serve({
          path: [
            _json({'lessonContent': [], 'exceptions': []}, status: 201),
          ],
        });
        await expectLater(
          plans.addLessonContent(_cluster, [_lesson]),
          throwsA(
            isA<SmartschoolLessonContentBulkSaveUnconfirmedError>()
                .having((e) => e.message, 'message', contains('none of them'))
                .having((e) => e.lessonContentId, 'lessonContentId', _lessonId)
                .having((e) => e.items, 'items', [_lesson])
                .having((e) => e.done, 'done', isEmpty)
                .having((e) => e.added, 'added', isEmpty)
                .having((e) => e.failed, 'failed', isEmpty)
                .having((e) => e.unanswered, 'unanswered', [_lesson]),
          ),
        );
      });

      test('an exception keyed in an unknown way stays a plain '
          'SaveUnconfirmedError', () async {
        final (_, plans) = await serve({
          path: [
            _json({
              'lessonContent': [_lessonJson()],
              'exceptions': {
                'iets': {'status': 403},
              },
            }, status: 201),
          ],
        });
        await expectLater(
          plans.addLessonContent(_cluster, [_lesson, _otherLesson]),
          throwsA(
            allOf(
              _unconfirmed(contains('in an unknown way ("iets")')),
              isNot(isA<SmartschoolLessonContentBulkSaveUnconfirmedError>()),
            ),
          ),
        );
      });

      test('flow: from the error, only the lesfiche not added and not in the '
          'cluster is added again (#244)', () async {
        Map<String, Object?> inCluster(String id, int position) => {
          ..._lessonJson(id: id),
          'lessonClusterId': _clusterId,
          'lessonClusterPlatformId': 4069,
          'position': position,
          'teachingHoursEstimate': null,
          'numberOfGoals': 0,
        };
        final (server, plans) = await serve({
          path: [
            _json({
              'lessonContent': [_lessonJson()],
              'exceptions': {
                '4069_lesson_$_otherLessonId': {
                  'status': 403,
                  'title': 'Forbidden',
                },
              },
            }, status: 201),
            _json({
              'lessonContent': [_lessonJson(id: _thirdLessonId)],
              'exceptions': [],
            }, status: 201),
          ],
          'GET $_clusterPath/lesson-cluster-content': [
            _json([_titleJson(), inCluster(_lessonId, 1)]),
          ],
        });

        final List<LessonContentItem> retried;
        try {
          await plans.addLessonContent(_cluster, [
            _lesson,
            _otherLesson,
            _thirdLesson,
          ]);
          fail('addLessonContent should not confirm the add');
        } on SmartschoolLessonContentBulkSaveUnconfirmedError catch (e) {
          expect(e.added.values.map((i) => i.id), [_lessonId]);
          expect(e.failed[_otherLesson]?.statusCode, 403);
          final there = {
            for (final entry in await plans.getClusterContent(_cluster))
              if (entry is LessonClusterLesfiche) entry.item.id,
          };
          final missing = [
            for (final fiche in e.unanswered)
              if (!there.contains(fiche.id)) fiche,
          ];
          retried = await plans.addLessonContent(_cluster, missing);
        }

        expect(retried.single.id, _thirdLessonId);
        expect(server.bodiesOf(path), [
          {
            'lessonContentIdentifiers': [
              for (final id in [_lessonId, _otherLessonId, _thirdLessonId])
                {'id': id, 'type': 'lessons', 'platformId': 4069},
            ],
          },
          {
            'lessonContentIdentifiers': [
              {'id': _thirdLessonId, 'type': 'lessons', 'platformId': 4069},
            ],
          },
        ]);
      });

      test('no lesfiches, or a lesfiche of an unknown kind, is an '
          'ArgumentError before anything is sent', () async {
        final (server, plans) = await serve({});
        await expectLater(
          plans.addLessonContent(_cluster, []),
          throwsArgumentError,
        );
        await expectLater(
          plans.addLessonContent(_cluster, [
            LessonContentItem.fromJson({..._lessonJson(), 'type': 'methods'}),
          ]),
          throwsArgumentError,
        );
        expect(server.calls, isEmpty);
      });
    });

    test('changeClusterGoals sends newGoals as the web client does, retried '
        'after logging in again, and checks the goals of the answer', () async {
      final path = 'POST $_clusterPath/change-goals';
      final (server, plans) = await serve({
        path: [
          _unauthorized,
          _json(_clusterJson(goals: [_goal.toJson()])),
          _json(_clusterJson()),
        ],
      });

      final cluster = await plans.changeClusterGoals(_cluster, [_goal]);
      expect(cluster.goals, [_goal]);
      expect(server.bodiesOf(path), [
        for (var i = 0; i < 2; i++)
          {
            'newGoals': [_goal.toWire()],
          },
      ]);

      await expectLater(
        plans.changeClusterGoals(_cluster, [_goal]),
        throwsA(_unconfirmed(contains('the goals none'))),
      );
    });

    test('getClusterGoals reads the goals with their counts', () async {
      final (server, plans) = await serve({
        'GET $_clusterPath/goals': [
          _json([
            {..._goal.toJson(), 'count': 2},
          ]),
        ],
      });
      final goals = await plans.getClusterGoals(_cluster);
      expect(server.calls, ['GET $_clusterPath/goals']);
      expect(goals.single.goal, _goal);
      expect(goals.single.count, 2);
    });
  });
}
