// Tests for issue #129: the detail of a lesfiche (LessonContentService
// getDetail, getDetailById) and the writes of the Lesfiches module in the own
// library (createLesson, createAssignment, the edits, the weblinks and
// attachments, the download of an attachment, and the move to the trash),
// against a fake Smartschool.
//
// Its answers are trimmed captures of the module's own, taken live on
// 2026-10-05 in the teacher's own library (made-up names and IDs here: the
// owner is the fake user `4069_1001_0`, the course names are generic ones):
// - `GET lessons/{id}` (and `assignments/{id}`) answers `200` with the whole
//   lesfiche: `privateInfo` (also as `info`), `weblinks` and `attachments`
//   with their `visibility`, no dates; a made-up ID, and a lesson's ID asked
//   for as an assignment, `404` with a bare problem;
// - `POST lessons/` (and `assignments/`) answers `201` with `{"id"}` only,
//   and a body with only a name a bare `400`;
// - the edits (`rename`, `change-icon`, `change-public-info`,
//   `change-private-info`, `change-courses`, `mark-as-visible`,
//   `mark-as-invisible`, `attachments`, `attachments/{id}/change-visibility`)
//   answer `200` with the whole lesfiche; a rename to `""` a bare `400`, and
//   a rename of a lesfiche in the trash `404`;
// - `POST .../weblinks` and `.../weblinks/{id}` answer `200` with the weblink
//   only, and an address that is not a URL a bare `400`;
// - `DELETE .../weblinks/{id}` and `.../attachments/{id}` answer `204`;
// - `POST .../attachments` gives the new attachments the visibility
//   `always`, and keeps two attachments of the same name;
// - `POST lesson-content/trash/bulk` answers `{"exceptions":[]}`, and a
//   lesfiche in the trash already a bare `500`.
//
// The goals of a lesfiche (#223, seen live on 2026-11-01): the detail has
// `goals` as `[{id, leerplanId, type}]`; `POST .../change-goals` with
// `{"newGoals": [{id, goalId, leerplanId, type}]}` answers `200` with the
// whole lesfiche, its goals replaced by the list. The goal IDs here are
// made up.
//
// The trash, restore and duplicate (#227, seen live on 2026-11-01, made-up
// IDs here): `GET lesson-content/trashed` answers an array in the list shape,
// with `dateStateChanged` (when it went to the trash) and the capability
// `canUserDelete`; `POST lesson-content/restore/bulk` with the body of
// `trash/bulk` answers `{"exceptions":[]}`, and for a lesfiche that is not
// in the trash `200` with `{"exceptions": {<the lesfiche as sent, as a JSON
// string>: {status 404, ...}}}`; `POST lesson-content/duplicate/bulk` with
// the same body answers `{"lessonContent": {<the lesfiche as sent>: <the
// copy, in the detail shape, named "<name> - kopie">}, "exceptions": []}`,
// and for a lesfiche in the trash `{"lessonContent": [], "exceptions":
// {<the lesfiche>: {status 403, ...}}}`.
//
// The labels (#228, seen live on 2026-11-01, made-up IDs and texts here):
// the labels module's `GET locations/lesson_content/platform-labels` and
// `GET user-labels/{userId}` answer arrays of labels (`{identifier, id,
// type, text, color, isVisible}` with `platformId` or `userId`); `POST
// .../change-labels` with `{"newLabels": [...]}` answers `200` with the whole
// lesfiche, its labels replaced by the list (an own label without its
// `userId`: a bare `500`); `POST user-labels/{userId}` with `{"text",
// "color", "isVisible"}` answers `201` with the new label, a text that is
// taken `400` with `languageCode` `name.already.used`, a text of 51
// characters a bare `400`.
//
// The live test of the same writes is
// test/live/lesson_content_write_live_test.dart (the labels:
// test/live/lesson_content_labels_live_test.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;
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

const _api = '/lesson-content/api/v1';

/// The lesson and the assignment lesfiche of the tests.
const _lessonId = 'b0000000-0000-4000-8000-000000000011';
const _assignmentId = 'b0000000-0000-4000-8000-000000000012';

/// The school's courses: informatica and wiskunde.
const _informatica = 'c0000000-0000-4000-8000-000000000005';
const _wiskunde = 'c0000000-0000-4000-8000-000000000007';

/// A weblink and attachments of the lesfiche.
const _weblinkId = 'e0000000-0000-4000-8000-000000000021';
const _attachmentId = 'f0000000-0000-4000-8000-000000000031';
const _newAttachmentId = 'f0000000-0000-4000-8000-000000000032';

/// The school's assignment type `Kleine Taak`.
const _typeId = 'a0000000-0000-4000-8000-000000000004';

/// Learning goals (#223): one of the eindtermen and one of a school
/// mini-database, as the goal selector gives them.
const _eindtermen = LearningGoalRef(
  id: 'd0000000-0000-4000-8000-000000000041',
  leerplanId: 'd0000000-0000-4000-8000-000000000040',
  type: 'eindtermen-derde-graad-doorstroom',
);
const _miniGoal = LearningGoalRef(
  id: 'd0000000-0000-4000-8000-000000000051',
  leerplanId: 'd0000000-0000-4000-8000-000000000050',
  type: 'miniDB',
);

const _lesson = '$_api/lessons/$_lessonId';
const _getLesson = 'GET $_lesson';
const _createLesson = 'POST $_api/lessons/';
const _createAssignment = 'POST $_api/assignments/';
const _courses = 'GET /course-list/api/v1/courses';
const _types = 'GET $_api/assignments/applicable-assignment-types';
const _uploadDirectory = 'GET /upload/api/v1/get-upload-directory';
const _upload = 'POST /Upload/Upload/Index';
const _trash = 'POST $_api/lesson-content/trash/bulk';
const _trashed = 'GET $_api/lesson-content/trashed';
const _restore = 'POST $_api/lesson-content/restore/bulk';
const _duplicate = 'POST $_api/lesson-content/duplicate/bulk';

/// The fake user of the tests, as Smartschool's whole user ID.
const _me = '4069_1001_0';

/// The course list, which the client reads once for the platform ID when it
/// reads the session user (`authenticatedUser`), as the labels need it.
final _session = {
  _courses: [_json(_courseList)],
};

/// The labels module (#228).
const _labels = '/labels/api/v1';
const _schoolLabels = 'GET $_labels/locations/lesson_content/platform-labels';
const _ownLabels = 'GET $_labels/user-labels/$_me';
const _createLabel = 'POST $_labels/user-labels/$_me';

/// A school label and two own labels (#228, made-up IDs).
const _schoolLabelId = '4069_a0000000-0000-4000-8000-000000000061';
const _ownLabelId = '${_me}_a0000000-0000-4000-8000-000000000071';
const _newLabelId = '${_me}_a0000000-0000-4000-8000-000000000072';

/// A school label as the labels module gives it (trimmed capture, #228).
Map<String, Object?> _schoolLabelJson({
  String id = _schoolLabelId,
  String text = 'TRIMESTER 1',
}) => {
  'identifier': id,
  'type': 'platform',
  'text': text,
  'color': 'yellow',
  'isVisible': true,
  'id': id,
  'platformId': 4069,
  'ssId': 4069,
  'locations': ['navigator', 'lesson_content', 'planner'],
};

/// An own label as the labels module gives it (trimmed capture, #228).
Map<String, Object?> _ownLabelJson({
  String id = _ownLabelId,
  String text = 'Herhaling',
  String color = 'steel',
}) => {
  'identifier': id,
  'type': 'user',
  'text': text,
  'color': color,
  'isVisible': true,
  'id': id,
  'userId': _me,
};

/// The copies of the lesson and the assignment lesfiche (#227).
const _lessonCopyId = 'b0000000-0000-4000-8000-000000000021';
const _assignmentCopyId = 'b0000000-0000-4000-8000-000000000022';

/// A lesfiche as an answer to a bulk write names it (#227): as it was sent,
/// a JSON object as a string.
String _ref(String id, String type) =>
    jsonEncode({'id': id, 'type': type, 'platformId': 4069});

/// A lesfiche of the trash as the module lists it (#227, trimmed capture):
/// the list shape, `dateStateChanged` when it went to the trash.
Map<String, Object?> _trashedJson({
  String id = _lessonId,
  String type = 'lessons',
  List<String> courses = const [_informatica],
}) => {
  'id': id,
  'platformId': 4069,
  'name': 'Lussen',
  'icon': 'document_observation',
  'publicInfo': '',
  'isVisible': true,
  'owner': '4069_1001_0',
  'dateStateChanged': '2026-11-01 09:30:12',
  'dateLastChanged': '2026-10-05 19:12:37',
  'courses': [
    for (final course in courses) {'platformId': 4069, 'id': course},
  ],
  'labels': [],
  'weblinks': [],
  'partnerWeblinks': [],
  'attachments': [],
  'deeplinks': [],
  'capabilities': {
    'canUserSeeDetails': true,
    'canUserEdit': false,
    'canUserTrash': false,
    'canUserTrashAsAdmin': false,
    'canUserDelete': true,
  },
  'type': type,
};

/// A weblink as the module gives it.
Map<String, Object?> _weblinkJson({
  String id = _weblinkId,
  String name = 'Oefeningen',
  String url = 'https://example.com/oefeningen',
  String icon = 'earth',
  String option = 'at-end',
  int? days,
}) => {
  'id': id,
  'name': name,
  'url': url,
  'icon': icon,
  'visibility': {'option': option, 'daysAfterEnd': days},
};

/// An attachment as the module gives it.
Map<String, Object?> _attachmentJson({
  String id = _attachmentId,
  String fileName = 'lussen.txt',
  int size = 16,
  String option = 'never',
  int? days,
}) => {
  'id': id,
  'fileName': fileName,
  'fileSize': size,
  'mimeType': 'text/plain',
  'visibility': {'option': option, 'daysAfterEnd': days},
};

/// The detail of a lesfiche as the module gives it (trimmed capture).
Map<String, Object?> _detailJson({
  String id = _lessonId,
  String type = 'lessons',
  String name = 'Lussen',
  String icon = 'document_observation',
  String publicInfo = '<p>Hoofdstuk 3</p>',
  String privateInfo = '<p>Voor mij</p>',
  bool visible = true,
  List<String> courses = const [_informatica],
  List<Map<String, Object?>>? weblinks,
  List<Map<String, Object?>>? attachments,
  List<LearningGoalRef> goals = const [],
  List<Map<String, Object?>> labels = const [],
}) => {
  'id': id,
  'platformId': 4069,
  if (type == 'assignments')
    'assignmentType': {
      'id': _typeId,
      'platformId': 4069,
      'name': 'Kleine Taak',
      'abbreviation': 'KT',
      'isVisible': true,
      'defaultTiming': 'deadline',
      'weight': 0,
    },
  'name': name,
  'icon': icon,
  'info': privateInfo,
  'privateInfo': privateInfo,
  'publicInfo': publicInfo,
  'isVisible': visible,
  'owner': '4069_1001_0',
  'goals': [for (final goal in goals) goal.toJson()],
  'courses': [
    for (final course in courses) {'platformId': 4069, 'id': course},
  ],
  'labels': labels,
  'uploadFolder': null,
  'weblinks': weblinks ?? [_weblinkJson()],
  'partnerWeblinks': [],
  'deeplinks': [],
  'attachments': attachments ?? [_attachmentJson()],
  'miniDBItems': [],
  'capabilities': {
    'canUserSeeUploadFolderInfo': false,
    'canUserCreateUploadFolder': false,
    'canUserSeeDetails': true,
    'canUserEdit': true,
    'canUserTrash': true,
    'canUserTrashAsAdmin': false,
    if (type == 'assignments') 'canUserChangeAssignmentTypeAsAdmin': false,
  },
  'type': type,
};

/// The school's course list: informatica and wiskunde.
final _courseList = jsonEncode([
  {
    'id': _informatica,
    'platformId': 4069,
    'name': 'informatica',
    'scheduleCodes': ['INFO'],
    'icon': 'schoolbord',
    'courseCluster': {'id': 35, 'name': 'Informatica'},
    'isVisible': true,
  },
  {
    'id': _wiskunde,
    'platformId': 4069,
    'name': 'wiskunde',
    'scheduleCodes': ['WISKU'],
    'icon': 'schoolbord',
    'courseCluster': null,
    'isVisible': true,
  },
]);

/// The school's assignment types, as the module lists them.
const _typeList =
    '[{"id":"$_typeId","platformId":4069,"name":"Kleine Taak",'
    '"abbreviation":"KT","isVisible":true,"defaultTiming":"deadline",'
    '"weight":0}]';

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

/// Smartschool's home page, trimmed to the script that holds the
/// authenticated user (`vars.authenticatedUser`), whose whole ID names the
/// owner of the own labels (#228).
const _homePage =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>\n'
    '<script>\n'
    'APP.extend(APP.vars || {}, JSON.parse(\'{"vars":{"authenticatedUser":'
    '{"id":"$_me","name":{"startingWithFirstName":"Jan Janssens",'
    '"startingWithLastName":"Janssens Jan"}}}}\'));\n'
    '</script>\n'
    '</body></html>';

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(Object body, {int status = 200}) => (
  status: status,
  body: body is String ? body : jsonEncode(body),
  contentType: 'application/json',
);

/// The module's bare problem answer, as seen live.
_Answer _problem(int status, String title, [List<String>? violations]) => (
  status: status,
  body: jsonEncode({
    'status': status,
    'title': title,
    'detail': '',
    'type': '',
    'violations': ?violations,
  }),
  contentType: 'application/problem+json',
);

final _badRequest = _problem(400, 'Bad Request');
final _notFound = _problem(404, 'Not Found');
final _serverError = _problem(500, 'Internal Server Error');

/// An empty `204`, the module's answer to the removal of a weblink or an
/// attachment.
const _Answer _noContent = (status: 204, body: '', contentType: '');

/// Smartschool refusing the session (#8): an empty `401`.
const _Answer _unauthorized = (status: 401, body: '', contentType: '');

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

/// A request as it reached the fake Smartschool.
typedef _Request = ({String label, Object? data, Map<String, dynamic> headers});

/// A Smartschool that answers each request (`METHOD path`) with the next
/// answer of its queue in [answers] (the last one again when one is left),
/// logs in when asked to, and records what reached it. Any other request
/// fails the test.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(Map<String, List<_Answer>> answers, this.failures)
    : _answers = {
        for (final entry in answers.entries) entry.key: [...entry.value],
      };

  final Map<String, List<_Answer>> _answers;
  final Map<String, Object Function(RequestOptions options)> failures;

  bool _passwordDone = false;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The requests as `METHOD path`.
  List<String> get log => [for (final r in requests) r.label];

  /// The requests that are not part of the login.
  List<String> get calls => [
    for (final label in log)
      if (!label.endsWith('/login') &&
          !label.contains('/2fa') &&
          label != 'GET /')
        label,
  ];

  /// The requests that write: not a GET, and not part of the login.
  List<String> get writes => [
    for (final label in calls)
      if (!label.startsWith('GET ')) label,
  ];

  /// The JSON bodies of the requests with [label].
  List<Object?> bodiesOf(String label) => [
    for (final r in requests)
      if (r.label == label) r.data,
  ];

  /// The `uploadDir` and the file name of each upload step.
  List<(String?, String?)> get uploads => [
    for (final r in requests)
      if (r.label == _upload)
        (
          (r.data! as FormData).fields
              .where((f) => f.key == 'uploadDir')
              .firstOrNull
              ?.value,
          (r.data! as FormData).files.single.value.filename,
        ),
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final label = '${options.method} ${options.uri.path}';
    requests.add((label: label, data: options.data, headers: options.headers));

    final failure = failures[label];
    if (failure != null) throw failure(options);

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
    }

    final queue = _answers[label];
    if (queue == null || queue.isEmpty) {
      fail('Unexpected request: $label');
    }
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

/// The lesson lesfiche of the tests, as the list gives it.
final _lessonItem = LessonContentItem.fromJson({
  ..._detailJson(),
  'dateLastChanged': '2026-10-05 19:12:37',
});

/// The assignment lesfiche of the tests, as the list gives it.
final _assignmentItem = LessonContentItem.fromJson(
  _detailJson(id: _assignmentId, type: 'assignments'),
);

/// Nothing was changed: the module refused the write.
Matcher _refused({required int status, Object? violations = anything}) => allOf(
  isNot(isA<SmartschoolLessonContentSaveUnconfirmedError>()),
  isA<SmartschoolLessonContentWriteRefusedError>()
      .having((e) => e.statusCode, 'statusCode', status)
      .having((e) => e.violations, 'violations', violations)
      .having((e) => e.message, 'message', contains('Nothing was changed')),
);

/// The write went out without the module confirming it.
Matcher _unconfirmed(
  Object? message, {
  Object? statusCode = anything,
  Object? cause = anything,
  Object? lessonContentId = anything,
}) => allOf(
  isNot(isA<SmartschoolLessonContentError>()),
  isA<SmartschoolLessonContentSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.cause, 'cause', cause)
      .having((e) => e.lessonContentId, 'lessonContentId', lessonContentId),
);

/// The files of `addAttachments` were added, and only setting a visibility
/// failed (#135): the attachments made [added] (as `(id, fileName,
/// visibility)`, in the order of the call), the one whose visibility failed,
/// the visibility asked for it, and the visibilities not set, in order.
Matcher _visibilityNotSet({
  required List<(String, String, LessonContentVisibility)> added,
  required String attachmentId,
  required LessonContentVisibility visibility,
  required Map<String, LessonContentVisibility> notSet,
}) => isA<SmartschoolLessonContentVisibilityNotSetError>()
    .having(
      (e) => [
        for (final a in e.addedAttachments) (a.id, a.fileName, a.visibility),
      ],
      'addedAttachments',
      added,
    )
    .having((e) => e.attachment.id, 'attachment.id', attachmentId)
    .having((e) => e.visibility, 'visibility', visibility)
    .having((e) => e.visibilitiesNotSet, 'visibilitiesNotSet', notSet)
    .having(
      (e) => e.visibilitiesNotSet.keys.toList(),
      'the order of visibilitiesNotSet',
      notSet.keys.toList(),
    );

/// A session refused for a write that is not retried.
final _notRetried = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('not retried after logging in again'),
);

void main() {
  forbidRealNetwork();

  late Directory files;

  setUp(() {
    files = Directory.systemTemp.createTempSync('lesson_content_write_test_');
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// A file [name] with [content] in the temporary folder of the test.
  String file(String name, [String content = 'dartschool test\n']) {
    final path = p.join(files.path, name);
    File(path).writeAsStringSync(content);
    return path;
  }

  Future<(_Smartschool, LessonContentService)> serve(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures = const {},
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers, failures);
    client.dio.httpClientAdapter = server;
    return (server, LessonContentService(client));
  }

  // ---------------------------------------------------------------------------
  // Models
  // ---------------------------------------------------------------------------

  group('LessonContentVisibility', () {
    test('the constants and afterEnd go out as the module takes them', () {
      expect(LessonContentVisibility.always.toJson(), {
        'option': 'always',
        'daysAfterEnd': null,
      });
      expect(LessonContentVisibility.never.toJson()['option'], 'never');
      expect(LessonContentVisibility.atStart.toJson()['option'], 'at-start');
      expect(LessonContentVisibility.atEnd.toJson()['option'], 'at-end');
      expect(LessonContentVisibility.afterEnd(3).toJson(), {
        'option': 'days-after-end',
        'daysAfterEnd': 3,
      });
      expect(
        LessonContentVisibility.afterEnd(14).option,
        LessonContentVisibilityOption.daysAfterEnd,
      );
    });

    test('afterEnd takes the 1 to 14 days the web client offers only', () {
      expect(() => LessonContentVisibility.afterEnd(0), throwsArgumentError);
      expect(() => LessonContentVisibility.afterEnd(15), throwsArgumentError);
    });

    test('fromJson reads every option, keeps an unknown one by name, and '
        'compares by value', () {
      final atEnd = LessonContentVisibility.fromJson(const {
        'option': 'at-end',
        'daysAfterEnd': null,
      });
      expect(atEnd, LessonContentVisibility.atEnd);
      expect(atEnd.hashCode, LessonContentVisibility.atEnd.hashCode);
      expect(
        LessonContentVisibility.fromJson(const {
          'option': 'days-after-end',
          'daysAfterEnd': 3,
        }),
        LessonContentVisibility.afterEnd(3),
      );
      final unknown = LessonContentVisibility.fromJson(const {
        'option': 'on-request',
      });
      expect(unknown.option, LessonContentVisibilityOption.other);
      expect(unknown.optionName, 'on-request');
      expect(
        () => LessonContentVisibility.fromJson(const {'daysAfterEnd': 3}),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
      expect(
        () => LessonContentVisibility.fromJson(const {
          'option': 'days-after-end',
          'daysAfterEnd': '3',
        }),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
    });
  });

  group('LessonContentService.normalizeWeblinkUrl', () {
    test('sends the address as the Lesfiches web client does', () {
      const cases = {
        'https://example.com/page': 'https://example.com/page',
        '  example.com/page  ': 'http://example.com/page',
        'HTTPS://Example.com': 'HTTPS://Example.com',
        'www.example.com/a b/c': 'http://www.example.com/ab/c',
        'https://example.com/?q=a b': 'https://example.com/?q=a%20b',
        'https://example.com/r?q=a%20b': 'https://example.com/r?q=a%20b',
        'https://example.com/r?q=é': 'https://example.com/r?q=%C3%A9',
        'https://example.com/r?': 'https://example.com/r',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
          LessonContentService.normalizeWeblinkUrl(key),
          value,
          reason: key,
        );
      }
    });

    test('refuses what the web client refuses', () {
      for (final url in [
        '',
        '   ',
        'geen url',
        'example',
        'https://example.com/?a=1?b=2',
        'ftp//example.com',
      ]) {
        expect(
          LessonContentService.normalizeWeblinkUrl(url),
          isNull,
          reason: url,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // getDetail
  // ---------------------------------------------------------------------------

  group('getDetail', () {
    test('reads lessons/{id}: the private info, the weblinks and attachments '
        'with their visibility, and names the courses after the course '
        'list', () async {
      final (server, lessonContent) = await serve({
        _getLesson: [_json(_detailJson())],
        _courses: [_json(_courseList)],
      });

      final detail = await lessonContent.getDetail(_lessonItem);

      expect(server.calls, [_getLesson, _courses]);
      expect(detail, isA<LessonContentItem>());
      expect(detail.id, _lessonId);
      expect(detail.type, LessonContentType.lesson);
      expect(detail.name, 'Lussen');
      expect(detail.publicInfo, '<p>Hoofdstuk 3</p>');
      expect(detail.privateInfo, '<p>Voor mij</p>');
      expect(detail.dateLastChanged, isNull);
      expect(detail.courses.map((c) => (c.id, c.name)), [
        (_informatica, 'informatica'),
      ]);
      expect(detail.weblinkCount, 1);
      final link = detail.weblinks.single;
      expect(link.id, _weblinkId);
      expect(link.name, 'Oefeningen');
      expect(link.url, 'https://example.com/oefeningen');
      expect(link.icon, 'earth');
      expect(link.visibility, LessonContentVisibility.atEnd);
      expect(detail.attachmentCount, 1);
      final attachment = detail.attachments.single;
      expect(attachment.id, _attachmentId);
      expect(attachment.fileName, 'lussen.txt');
      expect(attachment.fileSize, 16);
      expect(attachment.mimeType, 'text/plain');
      expect(attachment.visibility, LessonContentVisibility.never);
      expect(detail.can('canUserEdit'), isTrue);
    });

    test('an assignment is read at assignments/{id}, with its type; without '
        'course names, one request', () async {
      final (server, lessonContent) = await serve({
        'GET $_api/assignments/$_assignmentId': [
          _json(_detailJson(id: _assignmentId, type: 'assignments')),
        ],
      });

      final detail = await lessonContent.getDetailById(
        LessonContentType.assignment,
        _assignmentId,
        withCourseNames: false,
      );

      expect(server.calls, ['GET $_api/assignments/$_assignmentId']);
      expect(detail.type, LessonContentType.assignment);
      expect(detail.assignmentType?.name, 'Kleine Taak');
      expect(detail.courses.single.name, isNull);
    });

    test('404: a SmartschoolLessonContentNotFoundError', () async {
      final (_, lessonContent) = await serve({
        _getLesson: [_notFound],
      });

      await expectLater(
        lessonContent.getDetailById(LessonContentType.lesson, _lessonId),
        throwsA(
          isA<SmartschoolLessonContentNotFoundError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.type, 'type', LessonContentType.lesson)
              .having((e) => e.id, 'id', _lessonId),
        ),
      );
    });

    test('another lesfiche, a list or the web app: a '
        'SmartschoolLessonContentError', () async {
      for (final answer in [
        _json(_detailJson(id: _assignmentId)),
        _json(_detailJson(type: 'assignments')),
        _json('[]'),
        (status: 200, body: '<!DOCTYPE html><html></html>', contentType: ''),
        _serverError,
      ]) {
        final (_, lessonContent) = await serve({
          _getLesson: [answer],
        });
        await expectLater(
          lessonContent.getDetailById(
            LessonContentType.lesson,
            _lessonId,
            withCourseNames: false,
          ),
          throwsA(
            isA<SmartschoolLessonContentError>().having(
              (e) => e,
              'type',
              isNot(isA<SmartschoolLessonContentNotFoundError>()),
            ),
          ),
          reason: answer.body,
        );
      }
    });

    test('a course list that fails: a SmartschoolLessonContentCourseListError '
        'with the detail as read', () async {
      final (_, lessonContent) = await serve({
        _getLesson: [_json(_detailJson())],
        _courses: [_serverError],
      });

      final error = await lessonContent
          .getDetail(_lessonItem)
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<SmartschoolLessonContentCourseListError>());
      final items = (error! as SmartschoolLessonContentCourseListError).items;
      expect(items.single, isA<LessonContentDetail>());
      expect(items.single.id, _lessonId);
      expect(items.single.courses.single.name, isNull);
    });

    test('refuses a kind it does not know and an ID that is not a UUID, '
        'without a request', () async {
      final (server, lessonContent) = await serve({});

      await expectLater(
        lessonContent.getDetailById(LessonContentType.other, _lessonId),
        throwsArgumentError,
      );
      await expectLater(
        lessonContent.getDetailById(LessonContentType.lesson, 'not-a-uuid'),
        throwsArgumentError,
      );
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Creates
  // ---------------------------------------------------------------------------

  group('createLesson', () {
    test('checks the courses, uploads the files into a new directory, sends '
        'the web client\'s body to lessons/ once, and returns the new '
        'lesfiche as read back, with its courses named', () async {
      final (server, lessonContent) = await serve({
        _courses: [_json(_courseList)],
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_json('true')],
        _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
        _getLesson: [_json(_detailJson())],
      });

      final detail = await lessonContent.createLesson(
        name: '  Lussen ',
        publicInfo: '<p>Hoofdstuk 3</p>',
        privateInfo: '<p>Voor mij</p>',
        courseIds: [_informatica, _informatica],
        weblinks: [
          const NewLessonContentWeblink(
            name: 'Oefeningen',
            url: 'https://example.com/oefeningen',
            visibility: LessonContentVisibility.atEnd,
          ),
        ],
        attachments: [
          NewLessonContentAttachment(
            file('lussen.txt'),
            visibility: LessonContentVisibility.never,
          ),
        ],
      );

      expect(server.calls, [
        _courses,
        _uploadDirectory,
        _upload,
        _createLesson,
        _getLesson,
      ]);
      expect(server.uploads, [('dir1', 'lussen.txt')]);
      expect(server.bodiesOf(_createLesson), [
        {
          'name': 'Lussen',
          'icon': 'document_observation',
          'publicInfo': '<p>Hoofdstuk 3</p>',
          'privateInfo': '<p>Voor mij</p>',
          'courses': [
            {'platformId': 4069, 'id': _informatica},
          ],
          'goals': <Object>[],
          'labels': <Object>[],
          'weblinks': [
            {
              'name': 'Oefeningen',
              'url': 'https://example.com/oefeningen',
              'icon': 'earth',
              'visibility': {'option': 'at-end', 'daysAfterEnd': null},
            },
          ],
          'partnerWeblinks': <Object>[],
          'miniDBItems': <Object>[],
          'deeplinks': <Object>[],
          'randomDir': 'dir1',
          'previousLessonContent': null,
          'visibilityOptions': {
            'lussen.txt': {'option': 'never', 'daysAfterEnd': null},
          },
        },
      ]);
      expect(detail.id, _lessonId);
      expect(detail.courses.single.name, 'informatica');
      expect(detail.weblinks.single.visibility, LessonContentVisibility.atEnd);
      expect(detail.attachments.single.fileName, 'lussen.txt');
    });

    test('with a name only: no course list, no upload, `randomDir` null and '
        'every list empty (a body with only a name gets a 400)', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
        _getLesson: [
          _json(_detailJson(courses: [], weblinks: [], attachments: [])),
        ],
      });

      final detail = await lessonContent.createLesson(name: 'Lussen');

      expect(server.calls, [_createLesson, _getLesson]);
      final body = server.bodiesOf(_createLesson).single! as Map;
      expect(body['randomDir'], isNull);
      expect(body['courses'], isEmpty);
      expect(body['weblinks'], isEmpty);
      expect(body['visibilityOptions'], isEmpty);
      expect(body, isNot(contains('assignmentType')));
      expect(detail.courses, isEmpty);
    });

    test('refuses bad input before any request', () async {
      final (server, lessonContent) = await serve({});
      final present = file('lussen.txt');
      final elsewhere = Directory(p.join(files.path, 'b'))..createSync();
      final twin = File(p.join(elsewhere.path, 'lussen.txt'))
        ..writeAsStringSync('x');
      final badName = file('.verborgen');

      final calls = <(Future<Object?> Function(), String)>[
        (() => lessonContent.createLesson(name: '   '), 'is empty'),
        (() => lessonContent.createLesson(name: 'x' * 256), 'longer than'),
        (
          () => lessonContent.createLesson(name: 'Lussen', icon: ' '),
          'is empty',
        ),
        (
          () => lessonContent.createLesson(name: 'Lussen', courseIds: ['x']),
          'is not a UUID',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            weblinks: [
              const NewLessonContentWeblink(name: 'a', url: 'geen url'),
            ],
          ),
          'is not a web address',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            weblinks: [
              const NewLessonContentWeblink(name: ' ', url: 'example.be'),
            ],
          ),
          'has an empty name',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            weblinks: [
              const NewLessonContentWeblink(
                name: 'a',
                url: 'example.be',
                icon: '',
              ),
            ],
          ),
          'is empty',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            weblinks: [
              NewLessonContentWeblink(
                name: 'a',
                url: 'example.be',
                visibility: LessonContentVisibility.fromJson(const {
                  'option': 'days-after-end',
                  'daysAfterEnd': 30,
                }),
              ),
            ],
          ),
          'is not a visibility the web client offers',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            attachments: [
              NewLessonContentAttachment(p.join(files.path, 'none.txt')),
            ],
          ),
          'names no file',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            attachments: [NewLessonContentAttachment(badName)],
          ),
          'Smartschool does not allow',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            attachments: [
              NewLessonContentAttachment(present),
              NewLessonContentAttachment(twin.path),
            ],
          ),
          'a second file called "lussen.txt"',
        ),
        (
          () => lessonContent.createLesson(
            name: 'Lussen',
            attachments: [
              NewLessonContentAttachment(
                present,
                visibility: LessonContentVisibility.fromJson(const {
                  'option': 'on-request',
                }),
              ),
            ],
          ),
          'is not a visibility the web client offers',
        ),
      ];
      for (final (index, (call, reason)) in calls.indexed) {
        await expectLater(
          call(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains(reason),
            ),
          ),
          reason: 'call $index',
        );
      }
      expect(server.log, isEmpty);
    });

    test('a course the school does not have: an ArgumentError after reading '
        'the course list, and no create', () async {
      final (server, lessonContent) = await serve({
        _courses: [_json(_courseList)],
      });

      await expectLater(
        lessonContent.createLesson(
          name: 'Lussen',
          courseIds: [_informatica, 'c0000000-0000-4000-8000-0000000000ff'],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('c0000000-0000-4000-8000-0000000000ff'),
          ),
        ),
      );
      expect(server.calls, [_courses]);
    });

    test('a bare 400: a SmartschoolLessonContentWriteRefusedError without '
        'violations', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [_badRequest],
      });

      await expectLater(
        lessonContent.createLesson(name: 'Lussen'),
        throwsA(_refused(status: 400, violations: isEmpty)),
      );
      expect(server.calls, [_createLesson]);
    });

    test('a 500, an answer without an ID, and a dropped connection: '
        'unconfirmed, without a lesfiche ID', () async {
      for (final (answer, failure) in [
        (_serverError, null),
        (_json('{"ok":true}', status: 201), null),
        (_json('<html></html>', status: 201), null),
        (_json('{}'), _dropped),
      ]) {
        final (server, lessonContent) = await serve(
          {
            _createLesson: [answer],
          },
          failures: {_createLesson: ?failure},
        );
        await expectLater(
          lessonContent.createLesson(name: 'Lussen'),
          throwsA(
            _unconfirmed(
              contains('look for it in the lesfiches'),
              lessonContentId: isNull,
            ),
          ),
          reason: answer.body,
        );
        expect(server.calls, [_createLesson]);
      }
    });

    test('a session refused for the create is not retried after logging in '
        'again: no login, no second create', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [_unauthorized, _json('{"id":"$_lessonId"}')],
      });

      await expectLater(
        lessonContent.createLesson(name: 'Lussen'),
        throwsA(_notRetried),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.calls, [_createLesson]);
    });

    test('the read-back fails, or does not show what was sent: unconfirmed, '
        'with the ID of the lesfiche that was made', () async {
      for (final answer in [
        _serverError,
        _json(_detailJson(weblinks: [], attachments: [])),
        _json(_detailJson(name: 'Andere naam')),
      ]) {
        final (server, lessonContent) = await serve({
          _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
          _upload: [_json('true')],
          _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
          _getLesson: [answer],
        });
        await expectLater(
          lessonContent.createLesson(
            name: 'Lussen',
            courseIds: const [],
            weblinks: [
              const NewLessonContentWeblink(
                name: 'Oefeningen',
                url: 'https://example.com/oefeningen',
                visibility: LessonContentVisibility.atEnd,
              ),
            ],
            attachments: [
              NewLessonContentAttachment(
                file('lussen.txt'),
                visibility: LessonContentVisibility.never,
              ),
            ],
          ),
          throwsA(
            _unconfirmed(
              allOf(
                contains('was made with ID $_lessonId'),
                contains('do not make it again'),
              ),
              lessonContentId: _lessonId,
            ),
          ),
          reason: answer.body,
        );
        expect(server.writes, [_upload, _createLesson]);
      }
    });

    test('an upload that fails: a SmartschoolAttachmentUploadError, and no '
        'create', () async {
      final (server, lessonContent) = await serve({
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [
          (
            status: 400,
            body: 'De karakters zijn niet toegestaan.',
            contentType: 'text/html',
          ),
        ],
      });

      await expectLater(
        lessonContent.createLesson(
          name: 'Lussen',
          attachments: [NewLessonContentAttachment(file('lussen.txt'))],
        ),
        throwsA(isA<SmartschoolAttachmentUploadError>()),
      );
      expect(server.writes, [_upload]);
    });
  });

  group('createAssignment', () {
    test('checks the type against the module\'s assignment types, and sends '
        'it to assignments/ with the assignment icon', () async {
      final (server, lessonContent) = await serve({
        _types: [_json(_typeList)],
        _createAssignment: [_json('{"id":"$_assignmentId"}', status: 201)],
        'GET $_api/assignments/$_assignmentId': [
          _json(
            _detailJson(
              id: _assignmentId,
              type: 'assignments',
              icon: 'flags_red_yellow',
              name: 'Taak',
              courses: [],
              weblinks: [],
              attachments: [],
            ),
          ),
        ],
      });

      final detail = await lessonContent.createAssignment(
        name: 'Taak',
        assignmentTypeId: _typeId,
      );

      expect(server.calls, [
        _types,
        _createAssignment,
        'GET $_api/assignments/$_assignmentId',
      ]);
      final body = server.bodiesOf(_createAssignment).single! as Map;
      expect(body['assignmentType'], _typeId);
      expect(body['icon'], 'flags_red_yellow');
      expect(detail.type, LessonContentType.assignment);
      expect(detail.assignmentType?.id, _typeId);
    });

    test('a type that is not the school\'s: an ArgumentError after reading '
        'the types, and no create; an empty one before any request', () async {
      final (server, lessonContent) = await serve({
        _types: [_json(_typeList)],
      });

      await expectLater(
        lessonContent.createAssignment(
          name: 'Taak',
          assignmentTypeId: 'a0000000-0000-4000-8000-0000000000ff',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Kleine Taak $_typeId'),
          ),
        ),
      );
      await expectLater(
        lessonContent.createAssignment(name: 'Taak', assignmentTypeId: ' '),
        throwsArgumentError,
      );
      expect(server.calls, [_types]);
    });
  });

  // ---------------------------------------------------------------------------
  // Edits
  // ---------------------------------------------------------------------------

  group('edits', () {
    test('rename sends the new name and returns the lesfiche as '
        'answered', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/rename': [_json(_detailJson(name: 'Lussen 2'))],
      });

      final detail = await lessonContent.rename(_lessonItem, ' Lussen 2 ');

      expect(server.calls, ['POST $_lesson/rename']);
      expect(server.bodiesOf('POST $_lesson/rename'), [
        {'newName': 'Lussen 2'},
      ]);
      expect(detail.name, 'Lussen 2');
      // Not named: the edit does not read the course list.
      expect(detail.courses.single.name, isNull);
    });

    test('changeIcon, changePublicInfo, changePrivateInfo and setVisible '
        'send their bodies to the paths of an assignment', () async {
      const fiche = '$_api/assignments/$_assignmentId';
      Map<String, Object?> answer({
        String icon = 'flags_red_yellow',
        bool visible = true,
      }) => _detailJson(
        id: _assignmentId,
        type: 'assignments',
        icon: icon,
        visible: visible,
      );
      final (server, lessonContent) = await serve({
        'POST $fiche/change-icon': [_json(answer(icon: 'book'))],
        'POST $fiche/change-public-info': [_json(answer())],
        'POST $fiche/change-private-info': [_json(answer())],
        'POST $fiche/mark-as-invisible': [_json(answer(visible: false))],
        'POST $fiche/mark-as-visible': [_json(answer())],
      });

      expect(
        (await lessonContent.changeIcon(_assignmentItem, 'book')).icon,
        'book',
      );
      await lessonContent.changePublicInfo(_assignmentItem, '<p>a</p>');
      await lessonContent.changePrivateInfo(_assignmentItem, '');
      expect(
        (await lessonContent.setVisible(_assignmentItem, false)).isVisible,
        isFalse,
      );
      expect(
        (await lessonContent.setVisible(_assignmentItem, true)).isVisible,
        isTrue,
      );

      expect(server.calls, [
        'POST $fiche/change-icon',
        'POST $fiche/change-public-info',
        'POST $fiche/change-private-info',
        'POST $fiche/mark-as-invisible',
        'POST $fiche/mark-as-visible',
      ]);
      expect(server.bodiesOf('POST $fiche/change-icon'), [
        {'newIcon': 'book'},
      ]);
      expect(server.bodiesOf('POST $fiche/change-public-info'), [
        {'newPublicInfo': '<p>a</p>'},
      ]);
      expect(server.bodiesOf('POST $fiche/change-private-info'), [
        {'newPrivateInfo': ''},
      ]);
      expect(server.bodiesOf('POST $fiche/mark-as-invisible'), [
        <String, Object?>{},
      ]);
    });

    test('changeCourses checks the courses, sends them, and names them in '
        'the answer; an unknown course sends nothing', () async {
      final (server, lessonContent) = await serve({
        _courses: [_json(_courseList)],
        'POST $_lesson/change-courses': [
          _json(_detailJson(courses: [_wiskunde, _informatica])),
        ],
      });

      final detail = await lessonContent.changeCourses(_lessonItem, [
        _wiskunde,
        _informatica,
      ]);

      expect(server.bodiesOf('POST $_lesson/change-courses'), [
        {
          'newCourses': [
            {'platformId': 4069, 'id': _wiskunde},
            {'platformId': 4069, 'id': _informatica},
          ],
        },
      ]);
      expect(detail.courses.map((c) => c.name), ['wiskunde', 'informatica']);

      await expectLater(
        lessonContent.changeCourses(_lessonItem, [
          'c0000000-0000-4000-8000-0000000000ff',
        ]),
        throwsArgumentError,
      );
      expect(server.calls, [
        _courses,
        'POST $_lesson/change-courses',
        _courses,
      ]);
    });

    test('changeCourses with no courses sends an empty list, without reading '
        'the course list', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/change-courses': [_json(_detailJson(courses: []))],
      });

      await lessonContent.changeCourses(_lessonItem, const []);

      expect(server.calls, ['POST $_lesson/change-courses']);
      expect(server.bodiesOf('POST $_lesson/change-courses'), [
        {'newCourses': <Object>[]},
      ]);
    });

    test('an answer without the change, or of another lesfiche: '
        'unconfirmed', () async {
      final (_, lessonContent) = await serve({
        'POST $_lesson/rename': [
          _json(_detailJson(name: 'Lussen')),
          _json(_detailJson(id: _assignmentId, name: 'Lussen 2')),
        ],
        'POST $_lesson/mark-as-invisible': [_json(_detailJson())],
        'POST $_lesson/change-courses': [_json(_detailJson())],
      });

      await expectLater(
        lessonContent.rename(_lessonItem, 'Lussen 2'),
        throwsA(
          _unconfirmed(
            contains('the name "Lussen"'),
            statusCode: 200,
            lessonContentId: _lessonId,
          ),
        ),
      );
      await expectLater(
        lessonContent.rename(_lessonItem, 'Lussen 2'),
        throwsA(_unconfirmed(contains('another lesfiche'))),
      );
      await expectLater(
        lessonContent.setVisible(_lessonItem, false),
        throwsA(_unconfirmed(contains('isVisible true'))),
      );
      await expectLater(
        lessonContent.changeCourses(_lessonItem, const []),
        throwsA(_unconfirmed(contains('the courses [$_informatica]'))),
      );
    });

    test('404 (a lesfiche in the trash, seen live): a '
        'SmartschoolLessonContentNotFoundError; a bare 400 (an empty name, '
        'seen live): refused; a 500: unconfirmed', () async {
      final (_, lessonContent) = await serve({
        'POST $_lesson/rename': [_notFound, _badRequest, _serverError],
      });

      await expectLater(
        lessonContent.rename(_lessonItem, 'Lussen 2'),
        throwsA(
          isA<SmartschoolLessonContentNotFoundError>()
              .having((e) => e.id, 'id', _lessonId)
              .having((e) => e.message, 'message', contains('Nothing was')),
        ),
      );
      await expectLater(
        lessonContent.rename(_lessonItem, 'Lussen 2'),
        throwsA(_refused(status: 400, violations: isEmpty)),
      );
      await expectLater(
        lessonContent.rename(_lessonItem, 'Lussen 2'),
        throwsA(
          _unconfirmed(
            contains('sending the change again is harmless'),
            statusCode: 500,
          ),
        ),
      );
    });

    test('an edit is retried once after logging in again: it sets a '
        'value', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/rename': [
          _unauthorized,
          _json(_detailJson(name: 'Lussen 2')),
        ],
      });

      await lessonContent.rename(_lessonItem, 'Lussen 2');

      expect(server.log, contains('POST /login'));
      expect(server.writes.where((w) => w.endsWith('/rename')), hasLength(2));
    });

    test('refuses bad input before any request', () async {
      final (server, lessonContent) = await serve({});
      final other = LessonContentItem.fromJson(const {
        'id': _lessonId,
        'platformId': 4069,
        'type': 'method-lessons',
      });
      final badId = LessonContentItem.fromJson(const {
        'id': '42',
        'platformId': 4069,
        'type': 'lessons',
      });

      for (final (index, call) in <Future<Object?> Function()>[
        () => lessonContent.rename(_lessonItem, ' '),
        () => lessonContent.rename(other, 'Lussen'),
        () => lessonContent.rename(badId, 'Lussen'),
        () => lessonContent.changeIcon(_lessonItem, ''),
        () => lessonContent.changeCourses(_lessonItem, ['wiskunde']),
        () => lessonContent.setVisible(other, true),
        () => lessonContent.changeAttachmentVisibility(
          _lessonItem,
          'x',
          LessonContentVisibility.never,
        ),
      ].indexed) {
        await expectLater(call(), throwsArgumentError, reason: 'call $index');
      }
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Weblinks
  // ---------------------------------------------------------------------------

  group('weblinks', () {
    test('addWeblink sends the weblink with its address as the web client '
        'sends it, once, and returns the weblink made', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/weblinks': [
          _json(
            _weblinkJson(
              url: 'http://example.com/oefeningen',
              option: 'days-after-end',
              days: 3,
            ),
          ),
        ],
      });

      final link = await lessonContent.addWeblink(
        _lessonItem,
        NewLessonContentWeblink(
          name: ' Oefeningen ',
          url: 'example.com/oefeningen',
          visibility: LessonContentVisibility.afterEnd(3),
        ),
      );

      expect(server.bodiesOf('POST $_lesson/weblinks'), [
        {
          'newName': 'Oefeningen',
          'newIcon': 'earth',
          'newUrl': 'http://example.com/oefeningen',
          'newVisibility': {'option': 'days-after-end', 'daysAfterEnd': 3},
        },
      ]);
      expect(link.id, _weblinkId);
      expect(link.url, 'http://example.com/oefeningen');
      expect(link.visibility, LessonContentVisibility.afterEnd(3));
    });

    test('addWeblink is not retried after logging in again, and an answer '
        'with other values is unconfirmed', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/weblinks': [
          _unauthorized,
          _json(_weblinkJson(name: 'Andere')),
        ],
      });
      const link = NewLessonContentWeblink(
        name: 'Oefeningen',
        url: 'https://example.com/oefeningen',
        visibility: LessonContentVisibility.atEnd,
      );

      await expectLater(
        lessonContent.addWeblink(_lessonItem, link),
        throwsA(_notRetried),
      );
      expect(server.log, isNot(contains('GET /login')));
      await expectLater(
        lessonContent.addWeblink(_lessonItem, link),
        throwsA(
          _unconfirmed(
            allOf(contains('other values'), contains('adds a second weblink')),
            statusCode: 200,
          ),
        ),
      );
    });

    test('addWeblink with an address that the module refuses (a bare 400, '
        'seen live): refused', () async {
      final (_, lessonContent) = await serve({
        'POST $_lesson/weblinks': [_badRequest],
      });

      await expectLater(
        lessonContent.addWeblink(
          _lessonItem,
          const NewLessonContentWeblink(name: 'a', url: 'https://example.be'),
        ),
        throwsA(_refused(status: 400)),
      );
    });

    test('changeWeblink sends every value to weblinks/{id}, and the answer '
        'must be that weblink', () async {
      final (server, lessonContent) = await serve({
        'POST $_lesson/weblinks/$_weblinkId': [
          _json(_weblinkJson(name: 'Nieuw', option: 'at-start')),
          _json(
            _weblinkJson(id: _attachmentId, name: 'Nieuw', option: 'at-start'),
          ),
        ],
      });
      const link = NewLessonContentWeblink(
        name: 'Nieuw',
        url: 'https://example.com/oefeningen',
        visibility: LessonContentVisibility.atStart,
      );

      final changed = await lessonContent.changeWeblink(
        _lessonItem,
        _weblinkId,
        link,
      );
      expect(changed.name, 'Nieuw');
      expect(changed.visibility, LessonContentVisibility.atStart);
      expect(server.bodiesOf('POST $_lesson/weblinks/$_weblinkId').first, {
        'newName': 'Nieuw',
        'newIcon': 'earth',
        'newUrl': 'https://example.com/oefeningen',
        'newVisibility': {'option': 'at-start', 'daysAfterEnd': null},
      });

      await expectLater(
        lessonContent.changeWeblink(_lessonItem, _weblinkId, link),
        throwsA(_unconfirmed(contains('another weblink'))),
      );
    });

    test('removeWeblink sends a DELETE, answered with 204; a weblink the '
        'lesfiche does not have (404): not found', () async {
      final (server, lessonContent) = await serve({
        'DELETE $_lesson/weblinks/$_weblinkId': [_noContent, _notFound],
      });

      await lessonContent.removeWeblink(_lessonItem, _weblinkId);
      await expectLater(
        lessonContent.removeWeblink(_lessonItem, _weblinkId),
        throwsA(isA<SmartschoolLessonContentNotFoundError>()),
      );
      expect(server.calls, [
        'DELETE $_lesson/weblinks/$_weblinkId',
        'DELETE $_lesson/weblinks/$_weblinkId',
      ]);
      await expectLater(
        lessonContent.removeWeblink(_lessonItem, 'x'),
        throwsArgumentError,
      );
      expect(server.calls, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Attachments
  // ---------------------------------------------------------------------------

  group('attachments', () {
    test('addAttachments reads the lesfiche, uploads the files into a new '
        'directory, has the module take it once, sets the visibility the '
        'module did not (it gives every new one "always"), and returns the '
        'new attachments', () async {
      final existing = _attachmentJson(option: 'at-start');
      final (server, lessonContent) = await serve({
        _getLesson: [
          _json(_detailJson(attachments: [existing])),
        ],
        _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
        _upload: [_json('true')],
        'POST $_lesson/attachments': [
          _json(
            _detailJson(
              attachments: [
                // Same name as the one there: the module keeps both.
                _attachmentJson(id: _newAttachmentId, option: 'always'),
                existing,
              ],
            ),
          ),
        ],
        'POST $_lesson/attachments/$_newAttachmentId/change-visibility': [
          _json(
            _detailJson(
              attachments: [
                _attachmentJson(id: _newAttachmentId, option: 'never'),
                existing,
              ],
            ),
          ),
        ],
      });

      final added = await lessonContent.addAttachments(_lessonItem, [
        NewLessonContentAttachment(
          file('lussen.txt'),
          visibility: LessonContentVisibility.never,
        ),
      ]);

      expect(server.calls, [
        _getLesson,
        _uploadDirectory,
        _upload,
        'POST $_lesson/attachments',
        'POST $_lesson/attachments/$_newAttachmentId/change-visibility',
      ]);
      expect(server.bodiesOf('POST $_lesson/attachments'), [
        {'randomDir': 'dir7'},
      ]);
      expect(
        server.bodiesOf(
          'POST $_lesson/attachments/$_newAttachmentId/change-visibility',
        ),
        [
          {
            'newVisibility': {'option': 'never', 'daysAfterEnd': null},
          },
        ],
      );
      expect(added.map((a) => (a.id, a.visibility)), [
        (_newAttachmentId, LessonContentVisibility.never),
      ]);
    });

    test('addAttachments with "always": no visibility change', () async {
      final (server, lessonContent) = await serve({
        _getLesson: [_json(_detailJson(attachments: []))],
        _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
        _upload: [_json('true')],
        'POST $_lesson/attachments': [
          _json(
            _detailJson(
              attachments: [
                _attachmentJson(id: _newAttachmentId, option: 'always'),
              ],
            ),
          ),
        ],
      });

      final added = await lessonContent.addAttachments(_lessonItem, [
        NewLessonContentAttachment(file('lussen.txt')),
      ]);

      expect(server.writes, [_upload, 'POST $_lesson/attachments']);
      expect(added.single.id, _newAttachmentId);
    });

    test('addAttachments: a lesfiche the module does not know sends '
        'nothing; the take is not retried after logging in again; new '
        'attachments other than the files are unconfirmed', () async {
      final (server, lessonContent) = await serve({
        _getLesson: [_notFound, _json(_detailJson(attachments: []))],
        _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
        _upload: [_json('true')],
        'POST $_lesson/attachments': [
          _unauthorized,
          _json(_detailJson(attachments: [])),
        ],
      });
      final files0 = [NewLessonContentAttachment(file('lussen.txt'))];

      await expectLater(
        lessonContent.addAttachments(_lessonItem, files0),
        throwsA(isA<SmartschoolLessonContentNotFoundError>()),
      );
      expect(server.writes, isEmpty);
      await expectLater(
        lessonContent.addAttachments(_lessonItem, files0),
        throwsA(_notRetried),
      );
      expect(server.writes, [_upload, 'POST $_lesson/attachments']);
      await expectLater(
        lessonContent.addAttachments(_lessonItem, files0),
        throwsA(
          _unconfirmed(
            allOf(
              contains('no new attachments'),
              contains('adds the files a second time'),
            ),
            lessonContentId: _lessonId,
          ),
        ),
      );
    });

    test('addAttachments: a visibility that cannot be set is a '
        'SmartschoolLessonContentVisibilityNotSetError, saying the files were '
        'added, with their attachments (#135)', () async {
      final (_, lessonContent) = await serve({
        _getLesson: [_json(_detailJson(attachments: []))],
        _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
        _upload: [_json('true')],
        'POST $_lesson/attachments': [
          _json(
            _detailJson(
              attachments: [
                _attachmentJson(id: _newAttachmentId, option: 'always'),
              ],
            ),
          ),
        ],
        'POST $_lesson/attachments/$_newAttachmentId/change-visibility': [
          _serverError,
        ],
      });

      await expectLater(
        lessonContent.addAttachments(_lessonItem, [
          NewLessonContentAttachment(
            file('lussen.txt'),
            visibility: LessonContentVisibility.atEnd,
          ),
        ]),
        throwsA(
          allOf(
            _unconfirmed(
              allOf(
                contains('went through'),
                contains('Do not add the files'),
                isNot(contains('Not tried')),
              ),
              statusCode: isNull,
              cause: isA<SmartschoolLessonContentSaveUnconfirmedError>().having(
                (e) => e.statusCode,
                'statusCode',
                500,
              ),
              lessonContentId: _lessonId,
            ),
            _visibilityNotSet(
              added: [
                (
                  _newAttachmentId,
                  'lussen.txt',
                  LessonContentVisibility.always,
                ),
              ],
              attachmentId: _newAttachmentId,
              visibility: LessonContentVisibility.atEnd,
              notSet: {_newAttachmentId: LessonContentVisibility.atEnd},
            ),
          ),
        ),
      );
    });

    test('addAttachments of several files: the visibilities are set one at '
        'a time; when one fails, the error has every attachment made, each '
        'with the visibility it has, and the visibilities not set, that one '
        'and those after it, which were not tried (#135)', () async {
      // The module answers the take with the new attachments by file name
      // (seen live): a.txt (never), b.txt (at-start, its change fails),
      // c.txt (2 days after the end, not tried), d.txt (always: nothing to
      // set).
      const a = 'f0000000-0000-4000-8000-000000000041';
      const b = 'f0000000-0000-4000-8000-000000000042';
      const c = 'f0000000-0000-4000-8000-000000000043';
      const d = 'f0000000-0000-4000-8000-000000000044';
      final existing = _attachmentJson(option: 'at-start');
      List<Map<String, Object?>> taken({String aOption = 'always'}) => [
        _attachmentJson(id: a, fileName: 'a.txt', option: aOption),
        _attachmentJson(id: b, fileName: 'b.txt', option: 'always'),
        _attachmentJson(id: c, fileName: 'c.txt', option: 'always'),
        _attachmentJson(id: d, fileName: 'd.txt', option: 'always'),
        existing,
      ];
      final (server, lessonContent) = await serve({
        _getLesson: [
          _json(_detailJson(attachments: [existing])),
        ],
        _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
        _upload: [_json('true')],
        'POST $_lesson/attachments': [_json(_detailJson(attachments: taken()))],
        'POST $_lesson/attachments/$a/change-visibility': [
          _json(_detailJson(attachments: taken(aOption: 'never'))),
        ],
        'POST $_lesson/attachments/$b/change-visibility': [_serverError],
      });

      await expectLater(
        lessonContent.addAttachments(_lessonItem, [
          NewLessonContentAttachment(
            file('d.txt'),
            visibility: LessonContentVisibility.always,
          ),
          NewLessonContentAttachment(
            file('a.txt'),
            visibility: LessonContentVisibility.never,
          ),
          NewLessonContentAttachment(
            file('b.txt'),
            visibility: LessonContentVisibility.atStart,
          ),
          NewLessonContentAttachment(
            file('c.txt'),
            visibility: LessonContentVisibility.afterEnd(2),
          ),
        ]),
        throwsA(
          allOf(
            _unconfirmed(
              allOf(
                contains('setting the visibility of attachment "b.txt" ($b)'),
                contains('Not tried after it: attachment "c.txt" ($c)'),
                contains('Do not add the files again'),
              ),
              statusCode: isNull,
              cause: isA<SmartschoolLessonContentSaveUnconfirmedError>(),
              lessonContentId: _lessonId,
            ),
            _visibilityNotSet(
              // In the order of the call's attachments.
              added: [
                (d, 'd.txt', LessonContentVisibility.always),
                (a, 'a.txt', LessonContentVisibility.never),
                (b, 'b.txt', LessonContentVisibility.always),
                (c, 'c.txt', LessonContentVisibility.always),
              ],
              attachmentId: b,
              visibility: LessonContentVisibility.atStart,
              notSet: {
                b: LessonContentVisibility.atStart,
                c: LessonContentVisibility.afterEnd(2),
              },
            ),
          ),
        ),
      );
      expect(server.writes, [
        _upload,
        _upload,
        _upload,
        _upload,
        'POST $_lesson/attachments',
        'POST $_lesson/attachments/$a/change-visibility',
        'POST $_lesson/attachments/$b/change-visibility',
      ]);
    });

    test(
      'addAttachments: whatever the change of the visibility fails with '
      '(refused, its session refused), the error says the files were '
      'added; a take that is unconfirmed (no answer, an answer that is not '
      'a lesfiche, other new attachments) is not that error (#135)',
      () async {
        const changeVisibility =
            'POST $_lesson/attachments/$_newAttachmentId/change-visibility';
        Map<String, List<_Answer>> answers({
          List<_Answer>? take,
          List<_Answer> change = const [],
        }) => {
          _getLesson: [_json(_detailJson(attachments: []))],
          _uploadDirectory: [_json('{"uploadDir":"dir7"}')],
          _upload: [_json('true')],
          'POST $_lesson/attachments':
              take ??
              [
                _json(
                  _detailJson(
                    attachments: [
                      _attachmentJson(id: _newAttachmentId, option: 'always'),
                    ],
                  ),
                ),
              ],
          if (change.isNotEmpty) changeVisibility: change,
        };
        Future<void> add(LessonContentService lessonContent) =>
            lessonContent.addAttachments(_lessonItem, [
              NewLessonContentAttachment(
                file('lussen.txt'),
                visibility: LessonContentVisibility.never,
              ),
            ]);
        final filesAdded = _visibilityNotSet(
          added: [
            (_newAttachmentId, 'lussen.txt', LessonContentVisibility.always),
          ],
          attachmentId: _newAttachmentId,
          visibility: LessonContentVisibility.never,
          notSet: {_newAttachmentId: LessonContentVisibility.never},
        );
        final takeUnconfirmed = isNot(
          isA<SmartschoolLessonContentVisibilityNotSetError>(),
        );

        // The change refused with a 400: its cause is a
        // SmartschoolLessonContentError, as for a take answered with something
        // that is not a lesfiche (below).
        var (_, lessonContent) = await serve(answers(change: [_badRequest]));
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              filesAdded,
              _unconfirmed(
                anything,
                cause: isA<SmartschoolLessonContentWriteRefusedError>(),
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );

        // Its session refused, also after logging in again.
        (_, lessonContent) = await serve(answers(change: [_unauthorized]));
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              filesAdded,
              _unconfirmed(
                anything,
                cause: isA<SmartschoolSessionExpiredError>(),
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );

        // The take's connection dropping: no answer, so the files may or may
        // not have been added.
        (_, lessonContent) = await serve(
          answers(take: const []),
          failures: {'POST $_lesson/attachments': _dropped},
        );
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              takeUnconfirmed,
              _unconfirmed(
                allOf(
                  contains('no answer came in'),
                  contains('may or may not have been added'),
                ),
                statusCode: isNull,
                cause: isA<SmartschoolConnectionError>(),
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );

        // The take answered with something that is not a lesfiche.
        (_, lessonContent) = await serve(
          answers(
            take: [
              _json({'id': _lessonId}),
            ],
          ),
        );
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              takeUnconfirmed,
              _unconfirmed(
                contains('may or may not have been added'),
                statusCode: 200,
                cause: isA<SmartschoolLessonContentError>(),
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );

        // A 500 for the take, and new attachments other than the files.
        (_, lessonContent) = await serve(
          answers(
            take: [
              _serverError,
              _json(
                _detailJson(
                  attachments: [
                    _attachmentJson(
                      id: _newAttachmentId,
                      fileName: 'ander.txt',
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              takeUnconfirmed,
              _unconfirmed(
                contains('may or may not have been added'),
                statusCode: 500,
                cause: isNull,
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );
        await expectLater(
          add(lessonContent),
          throwsA(
            allOf(
              takeUnconfirmed,
              _unconfirmed(
                allOf(
                  contains('the new attachments "ander.txt"'),
                  contains('may or may not have been added'),
                ),
                statusCode: 200,
                cause: isNull,
                lessonContentId: _lessonId,
              ),
            ),
          ),
        );
      },
    );

    test('addAttachments refuses no files before any request', () async {
      final (server, lessonContent) = await serve({});

      await expectLater(
        lessonContent.addAttachments(_lessonItem, const []),
        throwsArgumentError,
      );
      expect(server.log, isEmpty);
    });

    test('changeAttachmentVisibility sends the visibility; an answer '
        'without the attachment is unconfirmed', () async {
      const path = 'POST $_lesson/attachments/$_attachmentId/change-visibility';
      final (server, lessonContent) = await serve({
        path: [
          _json(
            _detailJson(
              attachments: [
                _attachmentJson(option: 'days-after-end', days: 14),
              ],
            ),
          ),
          _json(_detailJson(attachments: [])),
        ],
      });

      final detail = await lessonContent.changeAttachmentVisibility(
        _lessonItem,
        _attachmentId,
        LessonContentVisibility.afterEnd(14),
      );
      expect(
        detail.attachments.single.visibility,
        LessonContentVisibility.afterEnd(14),
      );
      expect(server.bodiesOf(path).first, {
        'newVisibility': {'option': 'days-after-end', 'daysAfterEnd': 14},
      });
      await expectLater(
        lessonContent.changeAttachmentVisibility(
          _lessonItem,
          _attachmentId,
          LessonContentVisibility.never,
        ),
        throwsA(_unconfirmed(contains('no attachment $_attachmentId'))),
      );
    });

    test('removeAttachment sends a DELETE, answered with 204', () async {
      final (server, lessonContent) = await serve({
        'DELETE $_lesson/attachments/$_attachmentId': [_noContent],
      });

      await lessonContent.removeAttachment(_lessonItem, _attachmentId);

      expect(server.calls, ['DELETE $_lesson/attachments/$_attachmentId']);
    });

    test('downloadAttachment and downloadAttachmentStream read the download '
        'URL without Accept: application/json', () async {
      const path = 'GET $_lesson/attachments/$_attachmentId/download';
      final (server, lessonContent) = await serve({
        path: [
          (status: 200, body: 'dartschool test\n', contentType: 'text/plain'),
        ],
      });

      final bytes = await lessonContent.downloadAttachment(
        _lessonItem,
        _attachmentId,
      );
      final download = await lessonContent.downloadAttachmentStream(
        _lessonItem,
        _attachmentId,
      );
      final streamed = await download.stream.expand((chunk) => chunk).toList();

      expect(utf8.decode(bytes), 'dartschool test\n');
      expect(utf8.decode(streamed), 'dartschool test\n');
      expect(server.calls, [path, path]);
      for (final request in server.requests) {
        final accept = request.headers.entries
            .where((h) => h.key.toLowerCase() == 'accept')
            .map((h) => '${h.value}');
        expect(accept, isNot(contains(contains('application/json'))));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Goals (#223)
  // ---------------------------------------------------------------------------

  group('goals', () {
    const changeGoals = 'POST $_lesson/change-goals';

    test('the detail reads its goals; without them, none; a goal in an '
        'unknown shape is a SmartschoolLessonContentError', () {
      final detail = LessonContentService.parseDetail(
        _detailJson(goals: [_eindtermen, _miniGoal]),
      );
      expect(detail.goals, [_eindtermen, _miniGoal]);
      expect(
        LessonContentService.parseDetail(_detailJson()..remove('goals')).goals,
        isEmpty,
      );
      expect(
        () => LessonContentService.parseDetail({
          ..._detailJson(),
          'goals': [
            {'id': _eindtermen.id, 'leerplanId': _eindtermen.leerplanId},
          ],
        }),
        throwsA(
          isA<SmartschoolLessonContentError>().having(
            (e) => e.message,
            'message',
            contains('"type"'),
          ),
        ),
      );
      expect(
        () => LessonContentService.parseDetail({
          ..._detailJson(),
          'goals': {'id': _eindtermen.id},
        }),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
    });

    test('changeGoals sends the whole list as newGoals, with goalId filled '
        'from id, and returns the lesfiche with its goals', () async {
      final (server, lessonContent) = await serve({
        changeGoals: [
          _json(_detailJson(goals: [_miniGoal, _eindtermen])),
        ],
      });

      final detail = await lessonContent.changeGoals(_lessonItem, [
        _eindtermen,
        _miniGoal,
        _eindtermen,
      ]);

      expect(server.calls, [changeGoals]);
      expect(server.bodiesOf(changeGoals), [
        {
          'newGoals': [
            {
              'id': _eindtermen.id,
              'goalId': _eindtermen.id,
              'leerplanId': _eindtermen.leerplanId,
              'type': 'eindtermen-derde-graad-doorstroom',
            },
            {
              'id': _miniGoal.id,
              'goalId': _miniGoal.id,
              'leerplanId': _miniGoal.leerplanId,
              'type': 'miniDB',
            },
          ],
        },
      ]);
      expect(detail.goals, [_miniGoal, _eindtermen]);
    });

    test('changeGoals with no goals sends an empty list (clears them); an '
        'assignment goes to assignments/{id}', () async {
      final (server, lessonContent) = await serve({
        changeGoals: [_json(_detailJson())],
        'POST $_api/assignments/$_assignmentId/change-goals': [
          _json(
            _detailJson(
              id: _assignmentId,
              type: 'assignments',
              goals: [_miniGoal],
            ),
          ),
        ],
      });

      final cleared = await lessonContent.changeGoals(_lessonItem, const []);
      final assignment = await lessonContent.changeGoals(_assignmentItem, [
        _miniGoal,
      ]);

      expect(server.bodiesOf(changeGoals), [
        {'newGoals': <Object>[]},
      ]);
      expect(cleared.goals, isEmpty);
      expect(assignment.goals, [_miniGoal]);
    });

    test('an answer without the goals sent: unconfirmed; a 404: not found; '
        'a bare 400: refused', () async {
      final (_, lessonContent) = await serve({
        changeGoals: [
          _json(_detailJson(goals: [_eindtermen])),
          _json(
            _detailJson(
              goals: [
                LearningGoalRef(
                  id: _miniGoal.id,
                  leerplanId: _miniGoal.leerplanId,
                  type: 'noType',
                ),
              ],
            ),
          ),
          _notFound,
          _badRequest,
        ],
      });

      await expectLater(
        lessonContent.changeGoals(_lessonItem, [_eindtermen, _miniGoal]),
        throwsA(
          _unconfirmed(
            allOf(
              contains('the goals [${_eindtermen.id}]'),
              contains('sending the change again is harmless'),
            ),
            statusCode: 200,
            lessonContentId: _lessonId,
          ),
        ),
      );
      await expectLater(
        lessonContent.changeGoals(_lessonItem, [_miniGoal]),
        throwsA(_unconfirmed(contains('the goals [${_miniGoal.id}]'))),
      );
      await expectLater(
        lessonContent.changeGoals(_lessonItem, [_miniGoal]),
        throwsA(isA<SmartschoolLessonContentNotFoundError>()),
      );
      await expectLater(
        lessonContent.changeGoals(_lessonItem, [_miniGoal]),
        throwsA(_refused(status: 400)),
      );
    });

    test('changeGoals is retried once after logging in again: it sets a '
        'value', () async {
      final (server, lessonContent) = await serve({
        changeGoals: [
          _unauthorized,
          _json(_detailJson(goals: [_miniGoal])),
        ],
      });

      await lessonContent.changeGoals(_lessonItem, [_miniGoal]);

      expect(server.log, contains('POST /login'));
      expect(server.writes, [changeGoals, changeGoals]);
    });

    test('refuses bad goals before any request, in changeGoals and in the '
        'creates', () async {
      final (server, lessonContent) = await serve({});
      final bad = <(String, LearningGoalRef)>[
        (
          'not a UUID',
          LearningGoalRef(
            id: '42',
            leerplanId: _miniGoal.leerplanId,
            type: 'miniDB',
          ),
        ),
        (
          'empty leerplanId',
          LearningGoalRef(id: _miniGoal.id, leerplanId: ' ', type: 'miniDB'),
        ),
        (
          'empty type',
          LearningGoalRef(
            id: _miniGoal.id,
            leerplanId: _miniGoal.leerplanId,
            type: '',
          ),
        ),
        (
          'white space around type',
          LearningGoalRef(
            id: _miniGoal.id,
            leerplanId: _miniGoal.leerplanId,
            type: 'miniDB ',
          ),
        ),
        (
          'the same id in another curriculum',
          LearningGoalRef(
            id: _miniGoal.id.toUpperCase(),
            leerplanId: _eindtermen.leerplanId,
            type: 'miniDB',
          ),
        ),
      ];
      for (final (reason, goal) in bad) {
        await expectLater(
          lessonContent.changeGoals(_lessonItem, [_miniGoal, goal]),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'goals[1]'),
          ),
          reason: reason,
        );
        await expectLater(
          lessonContent.createLesson(name: 'Lussen', goals: [_miniGoal, goal]),
          throwsArgumentError,
          reason: reason,
        );
        await expectLater(
          lessonContent.createAssignment(
            name: 'Taak',
            assignmentTypeId: _typeId,
            goals: [_miniGoal, goal],
          ),
          throwsArgumentError,
          reason: reason,
        );
      }
      await expectLater(
        lessonContent.changeGoals(
          LessonContentItem.fromJson(const {
            'id': _lessonId,
            'platformId': 4069,
            'type': 'method-lessons',
          }),
          [_miniGoal],
        ),
        throwsArgumentError,
      );
      expect(server.log, isEmpty);
    });

    test('createLesson sends the goals in the create, and checks them in the '
        'read-back', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
        _getLesson: [
          _json(
            _detailJson(
              courses: [],
              weblinks: [],
              attachments: [],
              goals: [_eindtermen, _miniGoal],
            ),
          ),
        ],
      });

      final detail = await lessonContent.createLesson(
        name: 'Lussen',
        goals: [_eindtermen, _miniGoal],
      );

      final body = server.bodiesOf(_createLesson).single! as Map;
      expect(body['goals'], [_eindtermen.toWire(), _miniGoal.toWire()]);
      expect(detail.goals, [_eindtermen, _miniGoal]);
    });

    test('createAssignment sends the goals too', () async {
      final (server, lessonContent) = await serve({
        _types: [_json(_typeList)],
        _createAssignment: [_json('{"id":"$_assignmentId"}', status: 201)],
        'GET $_api/assignments/$_assignmentId': [
          _json(
            _detailJson(
              id: _assignmentId,
              type: 'assignments',
              courses: [],
              weblinks: [],
              attachments: [],
              goals: [_miniGoal],
            ),
          ),
        ],
      });

      final detail = await lessonContent.createAssignment(
        name: 'Lussen',
        assignmentTypeId: _typeId,
        goals: [_miniGoal],
      );

      final body = server.bodiesOf(_createAssignment).single! as Map;
      expect(body['goals'], [_miniGoal.toWire()]);
      expect(detail.goals, [_miniGoal]);
    });

    test('a create whose read-back lacks the goals sent: unconfirmed, with '
        'the ID of the lesfiche that was made', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
        _getLesson: [
          _json(_detailJson(courses: [], weblinks: [], attachments: [])),
        ],
      });

      await expectLater(
        lessonContent.createLesson(name: 'Lussen', goals: [_miniGoal]),
        throwsA(
          _unconfirmed(
            allOf(
              contains('the goals sent (it has none)'),
              contains('was made with ID $_lessonId'),
            ),
            lessonContentId: _lessonId,
          ),
        ),
      );
      expect(server.writes, [_createLesson]);
    });
  });

  // ---------------------------------------------------------------------------
  // Trash
  // ---------------------------------------------------------------------------

  group('labels (#228)', () {
    const changeLabels = 'POST $_lesson/change-labels';
    final school = LessonContentLabel.fromJson(_schoolLabelJson());
    final own = LessonContentLabel.fromJson(_ownLabelJson());

    /// The labels as the library sends them.
    final schoolWire = {
      'identifier': _schoolLabelId,
      'id': _schoolLabelId,
      'type': 'platform',
      'text': 'TRIMESTER 1',
      'color': 'yellow',
      'isVisible': true,
      'platformId': 4069,
    };
    final ownWire = {
      'identifier': _ownLabelId,
      'id': _ownLabelId,
      'type': 'user',
      'text': 'Herhaling',
      'color': 'steel',
      'isVisible': true,
      'userId': _me,
    };

    test('getLabels reads the school labels for the Lesfiches module, then '
        'the own labels of the session user', () async {
      final (server, lessonContent) = await serve({
        ..._session,
        _schoolLabels: [
          _json([_schoolLabelJson()]),
        ],
        _ownLabels: [
          _json([
            _ownLabelJson(),
            _ownLabelJson(id: _newLabelId, text: 'Toets', color: 'aqua'),
          ]),
        ],
      });

      final labels = await lessonContent.getLabels();

      expect(server.calls, [_schoolLabels, _courses, _ownLabels]);
      expect(
        [for (final l in labels) (l.id, l.text, l.color, l.type)],
        [
          (_schoolLabelId, 'TRIMESTER 1', 'yellow', 'platform'),
          (_ownLabelId, 'Herhaling', 'steel', 'user'),
          (_newLabelId, 'Toets', 'aqua', 'user'),
        ],
      );
      expect(labels.first.isSchoolLabel, isTrue);
      expect(labels.first.platformId, 4069);
      expect(labels.first.ownerId, isNull);
      expect(labels[1].isUserLabel, isTrue);
      expect(labels[1].userId, _me);
      expect(labels[1].ownerId, _me);
    });

    test('getLabels: an HTML page, a list in an unknown shape and a 500 are '
        'a SmartschoolLessonContentError', () async {
      final (_, lessonContent) = await serve({
        ..._session,
        _schoolLabels: [
          (status: 200, body: '<!DOCTYPE html><html></html>', contentType: ''),
          _json('{"labels":[]}'),
          _json([_schoolLabelJson()]),
        ],
        _ownLabels: [_serverError],
      });

      for (final what in ['HTML page', 'instead of a list', 'HTTP 500']) {
        await expectLater(
          lessonContent.getLabels(),
          throwsA(
            isA<SmartschoolLessonContentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('The labels module'), contains(what)),
            ),
          ),
        );
      }
    });

    test('changeLabels sends each label once as newLabels, with the userId of '
        'an own label (from its ID when it has none) and the platformId of a '
        'school label, and returns the lesfiche with its labels', () async {
      final (server, lessonContent) = await serve({
        changeLabels: [
          _json(_detailJson(labels: [_schoolLabelJson(), _ownLabelJson()])),
        ],
      });
      // An own label without its userId: the owner is in its ID.
      const bare = LessonContentLabel(
        id: _ownLabelId,
        text: 'Herhaling',
        color: 'steel',
        type: 'user',
      );

      final detail = await lessonContent.changeLabels(_lessonItem, [
        school,
        bare,
        own,
      ]);

      expect(server.calls, [changeLabels]);
      expect(server.bodiesOf(changeLabels), [
        {
          'newLabels': [schoolWire, ownWire],
        },
      ]);
      expect(detail.labels.map((l) => l.id), [_schoolLabelId, _ownLabelId]);
    });

    test('changeLabels with no labels sends an empty list (takes them all '
        'off); an assignment goes to assignments/{id}', () async {
      final (server, lessonContent) = await serve({
        changeLabels: [_json(_detailJson())],
        'POST $_api/assignments/$_assignmentId/change-labels': [
          _json(
            _detailJson(
              id: _assignmentId,
              type: 'assignments',
              labels: [_ownLabelJson()],
            ),
          ),
        ],
      });

      final cleared = await lessonContent.changeLabels(_lessonItem, const []);
      final assignment = await lessonContent.changeLabels(_assignmentItem, [
        own,
      ]);

      expect(server.bodiesOf(changeLabels), [
        {'newLabels': <Object>[]},
      ]);
      expect(cleared.labels, isEmpty);
      expect(assignment.labels.single.id, _ownLabelId);
    });

    test('an answer without the labels sent: unconfirmed; a 404: not found; '
        'a bare 500 (seen live for a label sent without its userId): '
        'unconfirmed; retried once after logging in again', () async {
      final (server, lessonContent) = await serve({
        changeLabels: [
          _json(_detailJson(labels: [_schoolLabelJson()])),
          _notFound,
          _serverError,
          _unauthorized,
          _json(_detailJson(labels: [_ownLabelJson()])),
        ],
      });

      await expectLater(
        lessonContent.changeLabels(_lessonItem, [school, own]),
        throwsA(
          _unconfirmed(
            allOf(
              contains('the labels "TRIMESTER 1" ($_schoolLabelId)'),
              contains('sending the change again is harmless'),
            ),
            statusCode: 200,
            lessonContentId: _lessonId,
          ),
        ),
      );
      await expectLater(
        lessonContent.changeLabels(_lessonItem, [own]),
        throwsA(isA<SmartschoolLessonContentNotFoundError>()),
      );
      await expectLater(
        lessonContent.changeLabels(_lessonItem, [own]),
        throwsA(_unconfirmed(contains('HTTP 500'), statusCode: 500)),
      );
      final detail = await lessonContent.changeLabels(_lessonItem, [own]);

      expect(detail.labels.single.id, _ownLabelId);
      expect(server.log, contains('POST /login'));
      expect(server.writes, List.filled(5, changeLabels));
    });

    test('refuses bad labels before any request, in changeLabels and in the '
        'creates', () async {
      final (server, lessonContent) = await serve({});
      final bad = <(String, LessonContentLabel)>[
        ('without an ID', const LessonContentLabel(id: ' ', text: 'x')),
        (
          'of the kind ""',
          const LessonContentLabel(id: _ownLabelId, text: 'x'),
        ),
        (
          'without its owner',
          const LessonContentLabel(id: 'nounderscore', text: 'x', type: 'user'),
        ),
      ];
      for (final (why, label) in bad) {
        final matcher = throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains(why),
          ),
        );
        await expectLater(
          lessonContent.changeLabels(_lessonItem, [label]),
          matcher,
          reason: why,
        );
        await expectLater(
          lessonContent.createLesson(name: 'Lussen', labels: [label]),
          matcher,
          reason: why,
        );
        await expectLater(
          lessonContent.createAssignment(
            name: 'Taak',
            assignmentTypeId: _typeId,
            labels: [label],
          ),
          matcher,
          reason: why,
        );
      }
      expect(server.log, isEmpty);
    });

    test('createLesson sends the labels in the create, and checks them in '
        'the read-back', () async {
      final (server, lessonContent) = await serve({
        _createLesson: [
          _json('{"id":"$_lessonId"}', status: 201),
          _json('{"id":"$_lessonId"}', status: 201),
        ],
        _getLesson: [
          _json(
            _detailJson(
              courses: [],
              weblinks: [],
              attachments: [],
              labels: [_schoolLabelJson(), _ownLabelJson()],
            ),
          ),
          _json(
            _detailJson(
              courses: [],
              weblinks: [],
              attachments: [],
              labels: [_schoolLabelJson()],
            ),
          ),
        ],
      });

      final detail = await lessonContent.createLesson(
        name: 'Lussen',
        labels: [school, own],
      );
      final body = server.bodiesOf(_createLesson).first! as Map;
      expect(body['labels'], [schoolWire, ownWire]);
      expect(detail.labels.map((l) => l.id), [_schoolLabelId, _ownLabelId]);

      await expectLater(
        lessonContent.createLesson(name: 'Lussen', labels: [school, own]),
        throwsA(
          _unconfirmed(
            contains('the labels sent (it has "TRIMESTER 1"'),
            lessonContentId: _lessonId,
          ),
        ),
      );
    });

    test('createUserLabel sends the text and the colour once, and returns the '
        'new label', () async {
      final (server, lessonContent) = await serve({
        ..._session,
        _createLabel: [
          _json(
            _ownLabelJson(id: _newLabelId, text: 'Toets', color: 'aqua'),
            status: 201,
          ),
        ],
      });

      final label = await lessonContent.createUserLabel(
        '  Toets ',
        color: 'aqua',
      );

      expect(server.calls, [_courses, _createLabel]);
      expect(server.bodiesOf(_createLabel), [
        {'text': 'Toets', 'color': 'aqua', 'isVisible': true},
      ]);
      expect(
        (label.id, label.text, label.color, label.isUserLabel, label.ownerId),
        (_newLabelId, 'Toets', 'aqua', true, _me),
      );
    });

    test('createUserLabel: the default colour is steel; a text that is taken '
        'and a bare 400 (a text too long, seen live): refused; a 500, an '
        'answer that is not the label: unconfirmed', () async {
      final (server, lessonContent) = await serve({
        ..._session,
        _createLabel: [
          _json(_ownLabelJson(id: _newLabelId, text: 'Toets'), status: 201),
          (
            status: 400,
            body: jsonEncode({
              'status': 400,
              'title': 'Bad Request',
              'detail': '',
              'type': '',
              'languageCode': 'name.already.used',
              'parameters': {'text': 'Toets'},
            }),
            contentType: 'application/problem+json',
          ),
          (
            status: 400,
            body: jsonEncode({
              'status': 400,
              'title': 'Bad Request',
              'detail': '',
              'type': '',
              'languageCode': '',
            }),
            contentType: 'application/problem+json',
          ),
          _serverError,
          _json(_ownLabelJson(id: _newLabelId, text: 'Andere'), status: 201),
          _json(_schoolLabelJson(text: 'Toets'), status: 201),
        ],
      });

      expect((await lessonContent.createUserLabel('Toets')).text, 'Toets');
      expect(server.bodiesOf(_createLabel).single, {
        'text': 'Toets',
        'color': 'steel',
        'isVisible': true,
      });

      Matcher refused(Object? violations, String why) =>
          isA<SmartschoolLessonContentWriteRefusedError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.violations, 'violations', violations)
              .having(
                (e) => e.message,
                'message',
                allOf(contains(why), contains('Nothing was made')),
              );
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(refused(['name.already.used'], 'has that text')),
      );
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(refused(isEmpty, 'without saying why')),
      );
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(_unconfirmed(contains('HTTP 500'), statusCode: 500)),
      );
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(_unconfirmed(contains('another label'))),
      );
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(_unconfirmed(contains('another label'))),
      );
    });

    test('createUserLabel is not retried after logging in again, and a '
        'dropped connection is unconfirmed', () async {
      final (server, lessonContent) = await serve({
        ..._session,
        _createLabel: [_unauthorized],
      });
      await expectLater(
        lessonContent.createUserLabel('Toets'),
        throwsA(_notRetried),
      );
      expect(server.writes, [_createLabel]);

      final (_, dropping) = await serve(
        _session,
        failures: {_createLabel: _dropped},
      );
      await expectLater(
        dropping.createUserLabel('Toets'),
        throwsA(_unconfirmed(contains('getLabels'))),
      );
    });

    test('createUserLabel refuses an empty text, one longer than 50 '
        'characters and a colour the web client does not offer, before any '
        'request', () async {
      final (server, lessonContent) = await serve({});
      for (final (text, color, why) in [
        ('  ', 'steel', 'is empty'),
        ('x' * 51, 'steel', 'longer than 50'),
        ('Toets', 'teal', 'not one of the colours'),
      ]) {
        await expectLater(
          lessonContent.createUserLabel(text, color: color),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains(why),
            ),
          ),
        );
      }
      expect(LessonContentService.maxLabelLength, 50);
      expect(LessonContentService.labelColors, contains('steel'));
      expect(server.log, isEmpty);
    });
  });

  group('trash', () {
    test('sends each lesfiche once with its kind and platform, answered '
        'with no exceptions', () async {
      final (server, lessonContent) = await serve({
        _trash: [_json('{"exceptions":[]}')],
      });

      await lessonContent.trash([_lessonItem, _assignmentItem, _lessonItem]);

      expect(server.calls, [_trash]);
      expect(server.bodiesOf(_trash), [
        {
          'lessonContent': [
            {'id': _lessonId, 'type': 'lessons', 'platformId': 4069},
            {'id': _assignmentId, 'type': 'assignments', 'platformId': 4069},
          ],
        },
      ]);
    });

    test('exceptions in the answer, an answer without them, and a 500 (a '
        'lesfiche in the trash already, seen live): unconfirmed', () async {
      final (_, lessonContent) = await serve({
        _trash: [
          _json({
            'exceptions': {
              _lessonId: {'status': 403, 'title': 'Forbidden', 'detail': ''},
            },
          }),
          _json('{}'),
          _serverError,
        ],
      });

      await expectLater(
        lessonContent.trash([_lessonItem]),
        throwsA(_unconfirmed(contains('with exceptions: Forbidden'))),
      );
      await expectLater(
        lessonContent.trash([_lessonItem]),
        throwsA(_unconfirmed(contains('without its exceptions'))),
      );
      await expectLater(
        lessonContent.trash([_lessonItem]),
        throwsA(
          _unconfirmed(contains('in the trash already'), statusCode: 500),
        ),
      );
    });

    test('refuses no lesfiches and a kind it does not know, before any '
        'request', () async {
      final (server, lessonContent) = await serve({});
      final other = LessonContentItem.fromJson(const {
        'id': _lessonId,
        'platformId': 4069,
        'type': 'method-lessons',
      });

      await expectLater(lessonContent.trash(const []), throwsArgumentError);
      await expectLater(lessonContent.trash([other]), throwsArgumentError);
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The trash, restore and duplicate (#227)
  // ---------------------------------------------------------------------------

  group('getTrash', () {
    test('reads the trash, lesfiches in the list shape with the date they '
        'went there, and names their courses', () async {
      final (server, lessonContent) = await serve({
        _trashed: [
          _json([
            _trashedJson(),
            _trashedJson(id: _assignmentId, type: 'assignments', courses: []),
          ]),
        ],
        _courses: [_json(_courseList)],
      });

      final trash = await lessonContent.getTrash();

      expect(server.calls, [_trashed, _courses]);
      expect(
        [for (final item in trash) (item.type, item.id)],
        [
          (LessonContentType.lesson, _lessonId),
          (LessonContentType.assignment, _assignmentId),
        ],
      );
      expect(trash.first.dateStateChanged, DateTime(2026, 11, 1, 9, 30, 12));
      expect(trash.first.courses.single.name, 'informatica');
      expect(trash.first.capabilities['canUserEdit'], isFalse);
    });

    test('without course names, and an empty trash: one request', () async {
      final (server, lessonContent) = await serve({
        _trashed: [
          _json([_trashedJson()]),
          _json('[]'),
        ],
      });

      final trash = await lessonContent.getTrash(withCourseNames: false);
      expect(trash.single.courses.single.name, isNull);
      expect(await lessonContent.getTrash(), isEmpty);
      expect(server.calls, [_trashed, _trashed]);
    });

    test('an answer in an unknown shape, and an HTML page', () async {
      final (_, lessonContent) = await serve({
        _trashed: [
          _json('{}'),
          (status: 200, body: '<html></html>', contentType: 'text/html'),
        ],
      });

      await expectLater(
        lessonContent.getTrash(),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
      await expectLater(
        lessonContent.getTrash(),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
    });
  });

  group('restore', () {
    test('sends each lesfiche once with its kind and platform, answered '
        'with no exceptions', () async {
      final (server, lessonContent) = await serve({
        _restore: [_json('{"exceptions":[]}')],
      });

      await lessonContent.restore([_lessonItem, _assignmentItem, _lessonItem]);

      expect(server.calls, [_restore]);
      expect(server.bodiesOf(_restore), [
        {
          'lessonContent': [
            {'id': _lessonId, 'type': 'lessons', 'platformId': 4069},
            {'id': _assignmentId, 'type': 'assignments', 'platformId': 4069},
          ],
        },
      ]);
    });

    test('a lesfiche that is not in the trash (a 404 exception keyed by the '
        'lesfiche, seen live): unconfirmed, naming it', () async {
      final (_, lessonContent) = await serve({
        _restore: [
          _json({
            'exceptions': {
              _ref(_assignmentId, 'assignments'): {
                'status': 404,
                'title': 'Not Found',
                'detail': '',
                'type': '',
              },
            },
          }),
          _json('{}'),
          _serverError,
        ],
      });

      await expectLater(
        lessonContent.restore([_lessonItem, _assignmentItem]),
        throwsA(
          _unconfirmed(
            allOf(
              contains(
                'with exceptions: assignment lesfiche $_assignmentId: '
                'Not Found (404)',
              ),
              isNot(contains(_lessonId)),
              contains('getTrash'),
            ),
            statusCode: 200,
          ),
        ),
      );
      await expectLater(
        lessonContent.restore([_lessonItem]),
        throwsA(_unconfirmed(contains('without its exceptions'))),
      );
      await expectLater(
        lessonContent.restore([_lessonItem]),
        throwsA(_unconfirmed(anything, statusCode: 500)),
      );
    });

    test('a 4xx: refused; retried once after logging in again', () async {
      final (server, lessonContent) = await serve({
        _restore: [_badRequest, _unauthorized, _json('{"exceptions":[]}')],
      });

      await expectLater(
        lessonContent.restore([_assignmentItem, _lessonItem]),
        throwsA(_refused(status: 400)),
      );
      await lessonContent.restore([_lessonItem]);

      expect(server.log, contains('POST /login'));
      expect(server.writes, [_restore, _restore, _restore]);
    });

    test('refuses no lesfiches and a kind it does not know, before any '
        'request', () async {
      final (server, lessonContent) = await serve({});
      final other = LessonContentItem.fromJson(const {
        'id': _lessonId,
        'platformId': 4069,
        'type': 'method-lessons',
      });

      await expectLater(lessonContent.restore(const []), throwsArgumentError);
      await expectLater(lessonContent.restore([other]), throwsArgumentError);
      expect(server.log, isEmpty);
    });
  });

  group('duplicate', () {
    test('sends each lesfiche once, and returns the copies the answer names, '
        'in the order asked, with the courses named', () async {
      final (server, lessonContent) = await serve({
        _duplicate: [
          _json({
            'lessonContent': {
              _ref(_assignmentId, 'assignments'): _detailJson(
                id: _assignmentCopyId,
                type: 'assignments',
                name: 'Lussen - kopie',
                courses: [_wiskunde],
              ),
              _ref(_lessonId, 'lessons'): _detailJson(
                id: _lessonCopyId,
                name: 'Lussen - kopie',
              ),
            },
            'exceptions': [],
          }),
        ],
      });

      // As getItems gives it: its course named.
      final named = LessonContentItem.fromJson(
        _detailJson(),
        courseNames: const {_informatica: 'informatica'},
      );

      final copies = await lessonContent.duplicate([
        named,
        _assignmentItem,
        _lessonItem,
      ]);

      expect(server.calls, [_duplicate]);
      expect(server.bodiesOf(_duplicate), [
        {
          'lessonContent': [
            {'id': _lessonId, 'type': 'lessons', 'platformId': 4069},
            {'id': _assignmentId, 'type': 'assignments', 'platformId': 4069},
          ],
        },
      ]);
      expect(
        [for (final copy in copies) (copy.type, copy.id, copy.name)],
        [
          (LessonContentType.lesson, _lessonCopyId, 'Lussen - kopie'),
          (LessonContentType.assignment, _assignmentCopyId, 'Lussen - kopie'),
        ],
      );
      expect(copies.first.weblinks.single.name, 'Oefeningen');
      expect(copies.first.courses.single.name, 'informatica');
      // Named after the courses of the lesfiches given: wiskunde is not one.
      expect(copies.last.courses.single.name, isNull);
    });

    test('a lesfiche in the trash (no copy, a 403 exception, seen live): '
        'refused, nothing changed', () async {
      final (server, lessonContent) = await serve({
        _duplicate: [
          _json({
            'lessonContent': [],
            'exceptions': {
              _ref(_lessonId, 'lessons'): {
                'status': 403,
                'title': 'Forbidden',
                'detail': '',
                'type': '',
              },
            },
          }),
        ],
      });

      await expectLater(
        lessonContent.duplicate([_lessonItem]),
        throwsA(
          allOf(
            _refused(status: 403),
            isA<SmartschoolLessonContentWriteRefusedError>().having(
              (e) => e.message,
              'message',
              contains('lesson lesfiche $_lessonId: Forbidden (403)'),
            ),
          ),
        ),
      );
      expect(server.calls, [_duplicate]);
    });

    test('some copies made and others not: unconfirmed, naming the copies '
        'made', () async {
      final (_, lessonContent) = await serve({
        _duplicate: [
          _json({
            'lessonContent': {
              _ref(_lessonId, 'lessons'): _detailJson(
                id: _lessonCopyId,
                name: 'Lussen - kopie',
              ),
            },
            'exceptions': {
              _ref(_assignmentId, 'assignments'): {
                'status': 403,
                'title': 'Forbidden',
              },
            },
          }),
          _json({
            'lessonContent': {
              _ref(_lessonId, 'lessons'): _detailJson(
                id: _lessonCopyId,
                name: 'Lussen - kopie',
              ),
            },
            'exceptions': [],
          }),
        ],
      });

      await expectLater(
        lessonContent.duplicate([_lessonItem, _assignmentItem]),
        throwsA(
          _unconfirmed(
            allOf(
              contains('only the copies lesson lesfiche $_lessonCopyId'),
              contains('do not make them again'),
              contains('assignment lesfiche $_assignmentId: Forbidden (403)'),
            ),
            statusCode: 200,
          ),
        ),
      );
      await expectLater(
        lessonContent.duplicate([_lessonItem, _assignmentItem]),
        throwsA(
          _unconfirmed(
            contains(
              'named no copy and no exception for assignment lesfiche '
              '$_assignmentId',
            ),
          ),
        ),
      );
    });

    test('an answer it cannot use, a 500, a dropped connection: unconfirmed, '
        'and a 4xx refused', () async {
      for (final answer in [
        _json('{"exceptions":[]}'),
        _json('{"lessonContent":{},"exceptions":"no"}'),
        _json({
          'lessonContent': {_lessonId: _detailJson(id: _lessonCopyId)},
          'exceptions': [],
        }),
        _json({
          'lessonContent': {
            _ref(_lessonId, 'lessons'): _detailJson(
              id: _lessonCopyId,
              type: 'assignments',
            ),
          },
          'exceptions': [],
        }),
        _json({
          'lessonContent': {
            _ref(_lessonId, 'lessons'): {'name': 'Lussen - kopie'},
          },
          'exceptions': [],
        }),
        _serverError,
      ]) {
        final (server, lessonContent) = await serve({
          _duplicate: [answer],
        });
        await expectLater(
          lessonContent.duplicate([_lessonItem]),
          throwsA(_unconfirmed(contains('trying again makes more copies'))),
          reason: answer.body,
        );
        expect(server.calls, [_duplicate]);
      }

      final (_, dropped) = await serve({}, failures: {_duplicate: _dropped});
      await expectLater(
        dropped.duplicate([_lessonItem]),
        throwsA(_unconfirmed(contains('no answer came in'))),
      );

      final (_, refused) = await serve({
        _duplicate: [_badRequest],
      });
      await expectLater(
        refused.duplicate([_lessonItem]),
        throwsA(_refused(status: 400)),
      );
    });

    test('a session refused for the duplicate is not retried after logging '
        'in again: no login, no second duplicate', () async {
      final (server, lessonContent) = await serve({
        _duplicate: [_unauthorized, _json('{"lessonContent":[]}')],
      });

      await expectLater(
        lessonContent.duplicate([_lessonItem]),
        throwsA(_notRetried),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.calls, [_duplicate]);
    });

    test('refuses no lesfiches, a kind it does not know and an ID that is '
        'not a UUID, before any request', () async {
      final (server, lessonContent) = await serve({});
      final other = LessonContentItem.fromJson(const {
        'id': _lessonId,
        'platformId': 4069,
        'type': 'method-lessons',
      });
      final badId = LessonContentItem.fromJson(const {
        'id': '42',
        'platformId': 4069,
        'type': 'lessons',
      });

      for (final items in [
        <LessonContentItem>[],
        [other],
        [_lessonItem, badId],
      ]) {
        await expectLater(
          lessonContent.duplicate(items),
          throwsArgumentError,
          reason: '$items',
        );
      }
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The flow of the issue
  // ---------------------------------------------------------------------------

  test('the flow of the issue: make a lesfiche with a weblink and an '
      'attachment in one create, read it, change it, download the '
      'attachment, and move it to the trash', () async {
    final (server, lessonContent) = await serve({
      _courses: [_json(_courseList)],
      _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
      _upload: [_json('true')],
      _createLesson: [_json('{"id":"$_lessonId"}', status: 201)],
      _getLesson: [_json(_detailJson())],
      'POST $_lesson/rename': [_json(_detailJson(name: 'Lussen 2'))],
      'POST $_lesson/weblinks/$_weblinkId': [
        _json(_weblinkJson(option: 'never')),
      ],
      'GET $_lesson/attachments/$_attachmentId/download': [
        (status: 200, body: 'dartschool test\n', contentType: 'text/plain'),
      ],
      _trash: [_json('{"exceptions":[]}')],
    });

    final made = await lessonContent.createLesson(
      name: 'Lussen',
      publicInfo: '<p>Hoofdstuk 3</p>',
      privateInfo: '<p>Voor mij</p>',
      courseIds: [_informatica],
      weblinks: [
        const NewLessonContentWeblink(
          name: 'Oefeningen',
          url: 'https://example.com/oefeningen',
          visibility: LessonContentVisibility.atEnd,
        ),
      ],
      attachments: [
        NewLessonContentAttachment(
          file('lussen.txt'),
          visibility: LessonContentVisibility.never,
        ),
      ],
    );
    final read = await lessonContent.getDetail(made);
    await lessonContent.rename(read, 'Lussen 2');
    await lessonContent.changeWeblink(
      read,
      read.weblinks.single.id,
      NewLessonContentWeblink(
        name: read.weblinks.single.name,
        url: read.weblinks.single.url,
        visibility: LessonContentVisibility.never,
      ),
    );
    final bytes = await lessonContent.downloadAttachment(
      read,
      read.attachments.single.id,
    );
    await lessonContent.trash([read]);

    expect(utf8.decode(bytes), 'dartschool test\n');
    expect(server.writes, [
      _upload,
      _createLesson,
      'POST $_lesson/rename',
      'POST $_lesson/weblinks/$_weblinkId',
      _trash,
    ]);
  });

  test('the flow of #227: duplicate a lesfiche, move both to the trash, find '
      'them there, restore the copy, and move it to the trash again', () async {
    final copyJson = _detailJson(id: _lessonCopyId, name: 'Lussen - kopie');
    final copyItem = LessonContentItem.fromJson(copyJson);
    final (server, lessonContent) = await serve({
      _duplicate: [
        _json({
          'lessonContent': {_ref(_lessonId, 'lessons'): copyJson},
          'exceptions': [],
        }),
      ],
      _trash: [_json('{"exceptions":[]}')],
      _trashed: [
        _json([
          _trashedJson(courses: []),
          {
            ..._trashedJson(id: _lessonCopyId, courses: []),
            'name': 'Lussen - kopie',
          },
        ]),
      ],
      _restore: [_json('{"exceptions":[]}')],
    });

    final copy = (await lessonContent.duplicate([_lessonItem])).single;
    await lessonContent.trash([_lessonItem, copy]);
    final trash = await lessonContent.getTrash();
    final found = trash.singleWhere((item) => item.id == copy.id);
    await lessonContent.restore([found]);
    await lessonContent.trash([found]);

    expect(copy.name, 'Lussen - kopie');
    expect(found.name, copyItem.name);
    expect(server.calls, [_duplicate, _trash, _trashed, _restore, _trash]);
    expect(server.bodiesOf(_restore), [
      {
        'lessonContent': [
          {'id': _lessonCopyId, 'type': 'lessons', 'platformId': 4069},
        ],
      },
    ]);
  });

  test('the flow of #228: make an own label, find it among the labels, put '
      'it and a school label on a lesfiche, and take them off again', () async {
    final (server, lessonContent) = await serve({
      ..._session,
      _createLabel: [
        _json(_ownLabelJson(id: _newLabelId, text: 'Toets'), status: 201),
      ],
      _schoolLabels: [
        _json([_schoolLabelJson()]),
      ],
      _ownLabels: [
        _json([_ownLabelJson(), _ownLabelJson(id: _newLabelId, text: 'Toets')]),
      ],
      'POST $_lesson/change-labels': [
        _json(
          _detailJson(
            labels: [
              _schoolLabelJson(),
              _ownLabelJson(id: _newLabelId, text: 'Toets'),
            ],
          ),
        ),
        _json(_detailJson()),
      ],
    });

    final made = await lessonContent.createUserLabel('Toets');
    final labels = await lessonContent.getLabels();
    final trimester = labels.firstWhere((l) => l.isSchoolLabel);
    final toets = labels.singleWhere((l) => l.id == made.id);
    final labelled = await lessonContent.changeLabels(_lessonItem, [
      trimester,
      toets,
    ]);
    final cleared = await lessonContent.changeLabels(labelled, const []);

    expect(labelled.labels.map((l) => l.text), ['TRIMESTER 1', 'Toets']);
    expect(cleared.labels, isEmpty);
    expect(server.calls, [
      _courses,
      _createLabel,
      _schoolLabels,
      _ownLabels,
      'POST $_lesson/change-labels',
      'POST $_lesson/change-labels',
    ]);
  });
}
