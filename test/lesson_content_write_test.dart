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
// The live test of the same writes is
// test/live/lesson_content_write_live_test.dart.
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

const _lesson = '$_api/lessons/$_lessonId';
const _getLesson = 'GET $_lesson';
const _createLesson = 'POST $_api/lessons/';
const _createAssignment = 'POST $_api/assignments/';
const _courses = 'GET /course-list/api/v1/courses';
const _types = 'GET $_api/assignments/applicable-assignment-types';
const _uploadDirectory = 'GET /upload/api/v1/get-upload-directory';
const _upload = 'POST /Upload/Upload/Index';
const _trash = 'POST $_api/lesson-content/trash/bulk';

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
  'goals': [],
  'courses': [
    for (final course in courses) {'platformId': 4069, 'id': course},
  ],
  'labels': [],
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

const _homePage =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>'
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
  // Trash
  // ---------------------------------------------------------------------------

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
}
