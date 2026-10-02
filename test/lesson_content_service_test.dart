// Tests for issue #88: the lesfiches of the Lesfiches module (lesson content,
// `LessonContentService.getItems`), which `PlannerService.planLessonContent`
// plans into a lesson hour.
//
// The list below is a trimmed capture of the live module (read-only,
// 2026-10-02):
//   - GET /lesson-content/api/v1/lesson-content/ -> 200 with a JSON array of
//       all the teacher's lesfiches (84 there: 74 lessons, 10 assignments),
//       dates without an offset from UTC (`2025-09-01 19:51:25`);
// trimmed to three lesfiches, with every lesfiche, course, label and
// assignment type ID, every lesfiche title, own label text and weblink
// replaced by obvious fakes (the owner is the fake authenticated user
// `4069_1001_0`, "Jan Janssens"; `JAAR 6` and `TRIMESTER 1` are the
// school's labels as they are). The capture had no attachments: the
// attachment of the third lesfiche is made up, and so are the answers that
// the module did not give live (unknown kinds, unusable answers).
//
// Everything here reads: the fake Smartschool answers the GET of the list
// (and the login chain), and fails the test on any other request.
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

const _listPath = '/lesson-content/api/v1/lesson-content/';
const _list = 'GET $_listPath';

const _lessonId = 'b0000000-0000-4000-8000-000000000001';
const _assignmentId = 'b0000000-0000-4000-8000-000000000002';
const _thirdId = 'b0000000-0000-4000-8000-000000000003';

/// Three lesfiches as the module lists them: a hidden lesson with two school
/// labels and no info; a visible assignment (`Kleine Taak`) with public
/// info, a weblink and an own label; a visible lesson of two courses with
/// an (made-up) attachment.
const _fiches = r'''
[{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Herhaling: lussen","icon":"document_observation","publicInfo":"","isVisible":false,"owner":"4069_1001_0","dateStateChanged":"2025-09-01 08:15:00","dateLastChanged":"2026-09-07 19:51:25","courses":[{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000005"}],"labels":[{"identifier":"4069_d0000000-0000-4000-8000-000000000001","type":"platform","text":"JAAR 6","color":"aqua","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000001","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]},{"identifier":"4069_d0000000-0000-4000-8000-000000000002","type":"platform","text":"TRIMESTER 1","color":"yellow","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000002","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]}],"weblinks":[],"partnerWeblinks":[],"attachments":[],"deeplinks":[],"capabilities":{"canUserSeeDetails":true,"canUserEdit":true,"canUserTrash":true,"canUserTrashAsAdmin":false},"type":"lessons"},
{"id":"b0000000-0000-4000-8000-000000000002","platformId":4069,"assignmentType":{"id":"a0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Kleine Taak","abbreviation":"KT","isVisible":true,"defaultTiming":"deadline","weight":0},"name":"Taak: een eigen spel","icon":"flags_red_yellow","publicInfo":"<p>Dien je taak in via de digitale klas.<\/p>","isVisible":true,"owner":"4069_1001_0","dateStateChanged":"2025-09-05 11:30:28","dateLastChanged":"2025-09-05 11:30:28","courses":[{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000005"}],"labels":[{"identifier":"4069_1001_0_d0000000-0000-4000-8000-000000000003","type":"user","text":"Lussen","color":"steel","isVisible":true,"id":"4069_1001_0_d0000000-0000-4000-8000-000000000003","userId":"4069_1001_0"}],"weblinks":[{"id":"e0000000-0000-4000-8000-000000000020","name":"Opdracht","url":"https:\/\/example.com\/opdracht","icon":"earth","visibility":{"option":"always","daysAfterEnd":null}}],"partnerWeblinks":[],"attachments":[],"deeplinks":[],"capabilities":{"canUserSeeDetails":true,"canUserEdit":true,"canUserTrash":true,"canUserTrashAsAdmin":false,"canUserChangeAssignmentTypeAsAdmin":false},"type":"assignments"},
{"id":"b0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Functies","icon":"document_observation","publicInfo":"<p>Hoofdstuk 4<\/p>","isVisible":true,"owner":"4069_1001_0","dateStateChanged":"2025-09-02 10:00:00","dateLastChanged":"2025-09-12 12:24:59","courses":[{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000005"},{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000006"}],"labels":[],"weblinks":[],"partnerWeblinks":[],"attachments":[{"id":"f0000000-0000-4000-8000-000000000030","name":"hoofdstuk4.pdf"}],"deeplinks":[],"capabilities":{"canUserSeeDetails":true,"canUserEdit":true,"canUserTrash":true,"canUserTrashAsAdmin":false},"type":"lessons"}]
''';

/// The lesfiches of [_fiches], decoded, to change one in a test.
List<Map<String, dynamic>> _decoded() => [
  for (final item in jsonDecode(_fiches) as List) item as Map<String, dynamic>,
];

/// [_fiches] with the first lesfiche changed by [change].
String _withFirst(void Function(Map<String, dynamic> fiche) change) {
  final fiches = _decoded();
  change(fiches.first);
  return jsonEncode(fiches);
}

/// The answer of the module to a route it does not know (such as
/// `lesson-content/{id}`): its web app.
const _webApp = '''
<!DOCTYPE html>
<html><head><title>Lesfiches</title></head>
<body><div id="lesson-content-app"></div><script src="/lesson-content/main.js"></script></body>
</html>
''';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

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

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, location: null);

/// Smartschool's answer to a request on a session it does not accept: a
/// `302` to `/login`, which the HTTP client leaves unfollowed (#22).
const _Answer _toLogin = (
  status: 302,
  body: '<html><body>Redirecting to /login</body></html>',
  location: '/login',
);

/// A Smartschool whose session is accepted, that answers the GET of the list
/// with [answers] in turn (its last answer for every later request) and the
/// login chain, and fails the test on any other request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(List<_Answer> answers) : _answers = [...answers];

  final List<_Answer> _answers;
  bool _passwordDone = false;

  /// Every request that reached it, in order (`METHOD path?query`).
  final List<String> log = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final label = '${options.method} ${uri.path}';
    log.add(uri.query.isEmpty ? label : '$label?${uri.query}');
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
      case _list:
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

/// A [SmartschoolLessonContentError], not an authentication failure.
Matcher _lessonContentError([
  Object? message = anything,
  Object? statusCode = anything,
]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isNot(isA<SmartschoolPlannerError>()),
  isA<SmartschoolLessonContentError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.statusCode, 'statusCode', statusCode),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, LessonContentService)> serve(
    List<_Answer> answers,
  ) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, LessonContentService(client));
  }

  // ---------------------------------------------------------------------------
  // getItems
  // ---------------------------------------------------------------------------

  group('LessonContentService.getItems', () {
    test('GETs lesson-content/ of the lesson-content API (with the slash, '
        'no query) and returns every lesfiche, both kinds, in order', () async {
      final (server, lessonContent) = await serve([_json(_fiches)]);

      final fiches = await lessonContent.getItems();

      expect(server.log, [_list]);
      expect(fiches.map((f) => f.id), [_lessonId, _assignmentId, _thirdId]);
      expect(fiches.map((f) => f.type), [
        LessonContentType.lesson,
        LessonContentType.assignment,
        LessonContentType.lesson,
      ]);
    });

    test('a session refused for the list is retried once after logging in '
        'again, as every read', () async {
      final (server, lessonContent) = await serve([_toLogin, _json(_fiches)]);

      final fiches = await lessonContent.getItems();

      expect(fiches, hasLength(3));
      expect(server.log.first, _list);
      expect(server.log.last, _list);
      expect(server.log, contains('POST /login'));
      expect(server.log.where((l) => l == _list), hasLength(2));
    });

    group('an answer the service cannot use is a '
        'SmartschoolLessonContentError', () {
      final answers = <String, (_Answer, Object?, Object?)>{
        'HTTP 500': (_json(_errorPage, status: 500), contains('HTTP 500'), 500),
        'HTTP 404': (
          _json(
            '{"status":404,"title":"Not Found","detail":"","type":""}',
            status: 404,
          ),
          contains('HTTP 404'),
          404,
        ),
        'the web app (an HTML page)': (
          _json(_webApp),
          contains('HTML page instead of JSON'),
          isNull,
        ),
        'invalid JSON': (_json('[{"id":'), contains('invalid JSON'), isNull),
        'an empty body': (_json(''), contains('empty body'), isNull),
        'not a list': (
          _json('{"items":[]}'),
          contains('instead of a list'),
          isNull,
        ),
        'a lesfiche without its type': (
          _json(_withFirst((f) => f.remove('type'))),
          contains('without its type'),
          isNull,
        ),
      };
      for (final MapEntry(key: name, value: (answer, message, status))
          in answers.entries) {
        test(name, () async {
          final (server, lessonContent) = await serve([answer]);

          await expectLater(
            lessonContent.getItems(),
            throwsA(_lessonContentError(message, status)),
          );
          expect(server.log, [_list]);
        });
      }
    });
  });

  // ---------------------------------------------------------------------------
  // parseItems
  // ---------------------------------------------------------------------------

  group('LessonContentService.parseItems', () {
    late List<LessonContentItem> fiches;
    setUp(() => fiches = LessonContentService.parseItems(jsonDecode(_fiches)));

    test('a lesson lesfiche: its name, icon, owner, course, school labels and '
        'capabilities; hidden, without info', () {
      final lesson = fiches.first;
      expect(lesson.id, _lessonId);
      expect(lesson.platformId, 4069);
      expect(lesson.type, LessonContentType.lesson);
      expect(lesson.typeName, 'lessons');
      expect(lesson.name, 'Herhaling: lussen');
      expect(lesson.icon, 'document_observation');
      expect(lesson.publicInfo, '');
      expect(lesson.isVisible, isFalse);
      expect(lesson.ownerId, '4069_1001_0');
      expect(lesson.assignmentType, isNull);
      expect(lesson.courses.single.id, 'c0000000-0000-4000-8000-000000000005');
      expect(lesson.courses.single.platformId, 4069);
      expect(lesson.labels.map((l) => '${l.text}/${l.color}/${l.type}'), [
        'JAAR 6/aqua/platform',
        'TRIMESTER 1/yellow/platform',
      ]);
      expect(
        lesson.labels.first.id,
        '4069_d0000000-0000-4000-8000-000000000001',
      );
      expect(lesson.labels.every((l) => l.isSchoolLabel), isTrue);
      expect(lesson.labels.every((l) => l.isVisible), isTrue);
      expect(lesson.can('canUserEdit'), isTrue);
      expect(lesson.can('canUserTrashAsAdmin'), isFalse);
      expect(lesson.can('canUserFly'), isFalse);
      expect(lesson.capabilities, {
        'canUserSeeDetails': true,
        'canUserEdit': true,
        'canUserTrash': true,
        'canUserTrashAsAdmin': false,
      });
      expect(
        [
          lesson.attachmentCount,
          lesson.weblinkCount,
          lesson.partnerWeblinkCount,
          lesson.deeplinkCount,
        ],
        [0, 0, 0, 0],
      );
    });

    test('the dates have no offset: the school\'s local time, read as local '
        'time', () {
      final lesson = fiches.first;
      expect(lesson.dateStateChanged, DateTime(2025, 9, 1, 8, 15));
      expect(lesson.dateLastChanged, DateTime(2026, 9, 7, 19, 51, 25));
      expect(lesson.dateLastChanged!.isUtc, isFalse);
    });

    test('a date with an offset is the same moment, in local time', () {
      final fiche = LessonContentService.parseItems(
        jsonDecode(
          _withFirst((f) => f['dateLastChanged'] = '2026-09-07T19:51:25+02:00'),
        ),
      ).first;
      expect(
        fiche.dateLastChanged!.isAtSameMomentAs(
          DateTime.utc(2026, 9, 7, 17, 51, 25),
        ),
        isTrue,
      );
      expect(fiche.dateLastChanged!.isUtc, isFalse);
    });

    test('an assignment lesfiche: its assignment type, public info, weblink '
        'and own label', () {
      final assignment = fiches[1];
      expect(assignment.type, LessonContentType.assignment);
      expect(assignment.typeName, 'assignments');
      expect(assignment.name, 'Taak: een eigen spel');
      expect(assignment.icon, 'flags_red_yellow');
      expect(
        assignment.publicInfo,
        '<p>Dien je taak in via de digitale klas.</p>',
      );
      expect(assignment.isVisible, isTrue);
      expect(
        assignment.assignmentType!.id,
        'a0000000-0000-4000-8000-000000000004',
      );
      expect(assignment.assignmentType!.name, 'Kleine Taak');
      expect(assignment.assignmentType!.abbreviation, 'KT');
      expect(assignment.weblinkCount, 1);
      final label = assignment.labels.single;
      expect(label.text, 'Lussen');
      expect(label.type, 'user');
      expect(label.isSchoolLabel, isFalse);
      expect(label.id, '4069_1001_0_d0000000-0000-4000-8000-000000000003');
      expect(assignment.can('canUserChangeAssignmentTypeAsAdmin'), isFalse);
    });

    test('a lesfiche of two courses, with an attachment and no labels', () {
      final third = fiches[2];
      expect(third.courses.map((c) => c.id), [
        'c0000000-0000-4000-8000-000000000005',
        'c0000000-0000-4000-8000-000000000006',
      ]);
      expect(third.attachmentCount, 1);
      expect(third.labels, isEmpty);
    });

    test('raw keeps the fields the model does not cover, read-only', () {
      final assignment = fiches[1];
      final weblink = (assignment.raw['weblinks'] as List).single as Map;
      expect(weblink['url'], 'https://example.com/opdracht');
      expect(() => assignment.raw['name'] = 'x', throwsUnsupportedError);
      expect(() => fiches.add(fiches.first), throwsUnsupportedError);
    });

    test('a kind this library does not know is kept, with the module\'s '
        'name', () {
      final fiche = LessonContentService.parseItems(
        jsonDecode(_withFirst((f) => f['type'] = 'activities')),
      ).first;
      expect(fiche.type, LessonContentType.other);
      expect(fiche.typeName, 'activities');
      expect(LessonContentType.other.wireName, isNull);
      expect(LessonContentType.fromWire('lessons'), LessonContentType.lesson);
      expect(
        LessonContentType.fromWire('assignments'),
        LessonContentType.assignment,
      );
    });

    test('a lesfiche without the optional parts: no dates, no lists, no '
        'capabilities, visible', () {
      final fiche = LessonContentService.parseItems(
        jsonDecode(
          '[{"id":"$_lessonId","platformId":4069,"type":"lessons",'
          '"name":"  Leeg  "}]',
        ),
      ).single;
      expect(fiche.name, 'Leeg');
      expect(fiche.icon, isNull);
      expect(fiche.publicInfo, '');
      expect(fiche.isVisible, isTrue);
      expect(fiche.ownerId, isNull);
      expect(fiche.dateLastChanged, isNull);
      expect(fiche.dateStateChanged, isNull);
      expect(fiche.courses, isEmpty);
      expect(fiche.labels, isEmpty);
      expect(fiche.capabilities, isEmpty);
      expect(fiche.can('canUserEdit'), isFalse);
    });

    test('an empty list has no lesfiches', () {
      expect(LessonContentService.parseItems(jsonDecode('[]')), isEmpty);
    });

    group('refuses', () {
      final shapes = <String, (Object?, Object?)>{
        'an answer that is not a list': (
          {'items': <Object>[]},
          contains('instead of a list'),
        ),
        'a lesfiche that is not an object': (
          ['b0000000'],
          contains('lesfiche 0 as String'),
        ),
        'a lesfiche without its id': (
          jsonDecode(_withFirst((f) => f.remove('id'))),
          contains('without its id'),
        ),
        'a lesfiche without its platform': (
          jsonDecode(_withFirst((f) => f.remove('platformId'))),
          contains('without a numeric platformId'),
        ),
        'a lesfiche without its type': (
          jsonDecode(_withFirst((f) => f['type'] = '')),
          contains('without its type'),
        ),
        'courses that are not a list': (
          jsonDecode(_withFirst((f) => f['courses'] = {'id': 'x'})),
          contains('the courses of lesfiche $_lessonId as an object'),
        ),
        'a label without its id': (
          jsonDecode(
            _withFirst(
              (f) => f['labels'] = [
                {'text': 'JAAR 6'},
              ],
            ),
          ),
          contains('a label without its id'),
        ),
        'a date that is not a date': (
          jsonDecode(_withFirst((f) => f['dateLastChanged'] = 'gisteren')),
          contains('"gisteren", which is not a date'),
        ),
        'an assignment type without its id': (
          jsonDecode(
            _withFirst((f) => f['assignmentType'] = {'name': 'Kleine Taak'}),
          ),
          contains('the assignment type of lesfiche $_lessonId'),
        ),
      };
      for (final MapEntry(key: name, value: (json, message))
          in shapes.entries) {
        test(name, () {
          expect(
            () => LessonContentService.parseItems(json),
            throwsA(_lessonContentError(message, isNull)),
          );
        });
      }
    });
  });
}
