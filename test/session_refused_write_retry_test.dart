// Regression tests for issue #134: a request sent with
// `retryAfterLogin: false` (a create of the Lesfiches module, a weblink
// added to a lesfiche, the take of an upload directory, the planner's fill of
// a slot, Intradesk's creates, Skore's save of a teacher, the steps of a
// message send) that Smartschool refuses for its session fails with a
// `SmartschoolSessionExpiredError` without logging in, by design (#25). The
// client did not remember that the session was refused, so the next such
// request went out in the same refused session again: a caller that tried
// the write again, as the error invites, was refused the same way, again
// without a login, and could never get through. Only a request that is
// retried after logging in (a read) logged in.
//
// The client now remembers that Smartschool refused the session it holds:
// the next request, of any kind, logs in before it is sent (or waits for the
// login that runs), and then goes out once, in the new session. So does the
// next request after a login that failed. A request that the client logged
// in for first and that Smartschool refuses all the same fails as a refused
// retry does, without a second login.
//
// The issue's own case is `LessonContentService.createLesson(name: 'Lussen')`
// without courses or attachments: the create is its only request before the
// read-back. Intradesk's creates read their parent folder first (#138), and
// that read logs in now, before it goes out, instead of after it was
// refused.
//
// Like the fake in session_shared_login_test.dart, the fake Smartschool
// below keeps its state per `PHPSESSID` cookie, as the live platform does:
// the session in the cookie cache when a test starts (`session-0`) is one it
// accepts until it ends, the login loads the login page without a session
// cookie (#45), and an accepted password moves the client to a new session
// id (`session-1`, ...). So the tests check which session each request
// carried, not only what was sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';
const _sessionCookie = 'PHPSESSID';

/// The session in the cookie cache when a test starts, which Smartschool
/// accepts until a test ends it.
const _firstSession = 'session-0';

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

/// The login POST: one per login.
const _password = 'POST /login';

/// The requests of a login, from the login page to the 2FA answer.
const _login = [
  'GET /login',
  _password,
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
];

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, contentType: Headers.jsonContentType);

enum _Stage { anonymous, passwordDone, authenticated }

/// A Smartschool that tracks each session by its `PHPSESSID` cookie and
/// refuses one it does not accept as the live platform does: a page request
/// (GET) is redirected to the login chain, an XHR/form POST gets a bare
/// `401`, and a POST without `X-Requested-With` (a JSON or multipart POST)
/// gets a `302` to `/login` that the HTTP client does not follow.
///
/// In a session it accepts, it answers a request (`METHOD path`) of
/// [routes], a GET with `page <path>`, and a POST with `ok <path>`.
class _Smartschool implements HttpClientAdapter {
  _Smartschool([this.routes = const {}]);

  final Map<String, _Answer> routes;

  /// Whether the login POST is answered with a redirect home (and a new
  /// session) or back to `/login`.
  bool passwordAccepted = true;

  /// Whether Smartschool accepts a session that got through the login chain;
  /// `false` keeps refusing it, as if the new session were not taken into
  /// account.
  bool acceptsNewSessions = true;

  /// Whether the connection fails when the login chain asks for the 2FA
  /// configuration.
  bool unreachableDuringLogin = false;

  final Map<String, _Stage> _sessions = {_firstSession: _Stage.authenticated};
  int _issued = 0;

  /// The requests (`METHOD path`) before the first of which every session
  /// Smartschool knows ends.
  final Set<String> endSessionsBefore = {};

  /// Every request the client made, as `METHOD path`.
  final List<String> log = [];

  /// The first `PHPSESSID` each request in [log] carried (`null` for none).
  final List<String?> sessionCookies = [];

  /// The requests of [routes] that Smartschool handled, in a session it
  /// accepted, as `<session>: METHOD path`.
  final List<String> handled = [];

  /// How many times the client made [request].
  int count(String request) => log.where((l) => l == request).length;

  /// The requests made from the [from]th on.
  List<String> logFrom(int from) => log.sublist(from);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = '${options.method} ${options.uri.path}';
    if (endSessionsBefore.remove(request)) _sessions.clear();
    final sid = _sessionId(options);
    log.add(request);
    sessionCookies.add(sid);
    if (requestStream != null) await requestStream.drain<void>();
    return _answer(options, request, sid);
  }

  ResponseBody _answer(RequestOptions options, String request, String? sid) {
    final path = options.uri.path;
    if (request == _password) {
      if (!passwordAccepted) return _redirect('/login');
      if (sid != null) _sessions.remove(sid);
      final fresh = 'session-${++_issued}';
      _sessions[fresh] = _Stage.passwordDone;
      return _redirect('/', setSession: fresh);
    }

    final stage = sid == null
        ? _Stage.anonymous
        : (_sessions[sid] ?? _Stage.anonymous);
    if (path == '/2fa/api/v1/config') {
      if (unreachableDuringLogin) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
          error: const SocketException('Failed host lookup'),
        );
      }
      return _respond(
        _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
      );
    }
    if (request == 'POST /2fa/api/v1/google-authenticator') {
      final accepted = stage == _Stage.passwordDone;
      if (accepted) _sessions[sid!] = _Stage.authenticated;
      return _respond(
        _json(
          accepted
              ? '{"success":true,"redirectTo":"/"}'
              : '{"success":false,"error":"Ongeldige code"}',
        ),
      );
    }

    final accepted =
        stage == _Stage.authenticated &&
        (acceptsNewSessions || sid == _firstSession);
    if (accepted) {
      final route = routes[request];
      if (route != null) {
        handled.add('$sid: $request');
        return _respond(route);
      }
      if (options.method == 'GET') return _page(path, path, 'page $path');
      return _respond((
        status: 200,
        body: 'ok $path',
        contentType: 'text/html',
      ));
    }
    if (options.method != 'GET') {
      return _sentWithXhr(options)
          ? _respond((status: 401, body: '', contentType: ''))
          : _redirect('/login');
    }
    if (stage == _Stage.passwordDone) {
      // The login chain following the redirect after an accepted password.
      return _page(path, '/2fa', '<html><body>2fa</body></html>');
    }
    return _page(path, '/login', _loginPage);
  }

  @override
  void close({bool force = false}) {}
}

/// The first `PHPSESSID` in the `Cookie` header of [options], which is the
/// one Smartschool (PHP) reads.
String? _sessionId(RequestOptions options) {
  final header = options.headers[HttpHeaders.cookieHeader] as String?;
  if (header == null) return null;
  for (final pair in header.split(';')) {
    if (pair.trim().startsWith('$_sessionCookie=')) {
      return pair.trim().substring(_sessionCookie.length + 1);
    }
  }
  return null;
}

bool _sentWithXhr(RequestOptions options) => options.headers.entries.any(
  (h) =>
      h.key.toLowerCase() == kXRequestedWith.toLowerCase() &&
      h.value == 'XMLHttpRequest',
);

ResponseBody _respond(_Answer answer) => ResponseBody.fromString(
  answer.body,
  answer.status,
  headers: {
    if (answer.contentType.isNotEmpty)
      Headers.contentTypeHeader: [answer.contentType],
  },
);

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = _respond((
    status: 200,
    body: body,
    contentType: 'text/html',
  ));
  if (requested != at) {
    response.redirects = [
      RedirectRecord(302, 'GET', Uri.parse('https://$_host$at')),
    ];
  }
  return response;
}

/// A 302 the HTTP client leaves unfollowed, as it does after every POST.
ResponseBody _redirect(String location, {String? setSession}) =>
    ResponseBody.fromString(
      '<html><body>Redirecting to $location</body></html>',
      302,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
        'location': [location],
        if (setSession != null)
          HttpHeaders.setCookieHeader: ['$_sessionCookie=$setSession; path=/'],
      },
    );

/// The failure of a request that Smartschool refused for its session and
/// that is not retried after logging in again: the client logs in before
/// the next request.
final Matcher _notRetried = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  allOf(
    contains('not retried after logging in again'),
    contains('it was not carried out'),
    contains('The client logs in before its next request'),
  ),
);

// -------------------------------------------------------------------------
// The Lesfiches module (#129): trimmed captures, as in
// lesson_content_write_test.dart.
// -------------------------------------------------------------------------

const _lessonContentApi = '/lesson-content/api/v1';
const _lessonId = 'b0000000-0000-4000-8000-000000000011';
const _createLesson = 'POST $_lessonContentApi/lessons/';
const _getLesson = 'GET $_lessonContentApi/lessons/$_lessonId';
const _addWeblink = 'POST $_lessonContentApi/lessons/$_lessonId/weblinks';

/// The lesson lesfiche `Lussen`, as the module gives its detail, without
/// courses, weblinks or attachments.
final _lessonDetail = jsonEncode({
  'id': _lessonId,
  'platformId': 4069,
  'name': 'Lussen',
  'icon': 'document_observation',
  'info': '',
  'privateInfo': '',
  'publicInfo': '',
  'isVisible': true,
  'owner': '4069_1001_0',
  'goals': [],
  'courses': [],
  'labels': [],
  'uploadFolder': null,
  'weblinks': [],
  'partnerWeblinks': [],
  'deeplinks': [],
  'attachments': [],
  'miniDBItems': [],
  'capabilities': {
    'canUserSeeUploadFolderInfo': false,
    'canUserCreateUploadFolder': false,
    'canUserSeeDetails': true,
    'canUserEdit': true,
    'canUserTrash': true,
    'canUserTrashAsAdmin': false,
  },
  'type': 'lessons',
});

/// The weblink `Oefeningen` that the module answers its addition with.
final _weblink = jsonEncode({
  'id': 'e0000000-0000-4000-8000-000000000021',
  'name': 'Oefeningen',
  'url': 'https://example.com/oefeningen',
  'icon': 'earth',
  'visibility': {'option': 'always', 'daysAfterEnd': null},
});

// -------------------------------------------------------------------------
// Intradesk (#128, #138): trimmed captures, as in intradesk_write_test.dart.
// -------------------------------------------------------------------------

const _intradeskApi = '/intradesk/api/v1/49';
const _courses = 'GET /course-list/api/v1/courses';

/// The folder "tests" to make a folder in, and the folder it is in.
const _parent = 'aaaa1111-1111-4111-b111-111111111111';
const _top = 'aaaa0000-0000-4000-b000-000000000000';
const _newFolder = 'ffff1111-1111-4111-b111-111111111111';

const _parentsOfParent = 'GET $_intradeskApi/folders/$_parent/parents';
const _listingOfTop =
    'GET $_intradeskApi/directory-listing/forTreeOnlyFolders/$_top';
const _createFolder = 'POST $_intradeskApi/folders/';

/// An Intradesk folder, as a listing and a create give it.
String _folder({
  required String id,
  required String name,
  required String parent,
}) =>
    '{"id":"$id","platform":{"id":49,"name":"Testschool"},"name":"$name",'
    '"color":"yellow","state":"active","visible":true,"confidential":false,'
    '"officeTemplateFolder":false,"parentFolderId":"$parent",'
    '"dateStateChanged":"2026-10-05T20:09:03+02:00",'
    '"dateCreated":"2026-10-05T20:09:03+02:00",'
    '"dateChanged":"2026-10-05T20:09:03+02:00","isFavourite":false,'
    '"inConfidentialFolder":false,"capabilities":{"canManage":true,'
    '"canAdd":true,"canSeeHistory":true,"canSeeViewHistory":true}}';

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;
  late _Smartschool server;

  /// A client on [smartschool], which carries on in [_firstSession].
  Future<void> serve(_Smartschool smartschool) async {
    final cacheDir = tempCacheDir();
    // The session that an earlier run of the app saved.
    final saved = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir, '.cookies')),
    );
    await saved.saveFromResponse(Uri.parse('https://$_host/'), [
      Cookie(_sessionCookie, _firstSession)..path = '/',
    ]);
    server = smartschool;
    client = await SmartschoolClient.create(_Credentials(), cacheDir: cacheDir);
    client.dio.httpClientAdapter = server;
    addTearDown(client.dispose);
  }

  group('SmartschoolClient: a request sent with retryAfterLogin: false that '
      'Smartschool refuses for its session (#134)', () {
    final writes = <String, Future<Response<String>> Function()>{
      'a JSON POST answered 302 to /login (postJsonResponse)': () =>
          client.postJsonResponse(
            '/w',
            data: {'name': 'Lussen'},
            retryAfterLogin: false,
          ),
      'an XHR/form POST answered 401 (postFormResponse)': () => client
          .postFormResponse('/w', {'name': 'Lussen'}, retryAfterLogin: false),
      'a multipart POST answered 302 to /login (postMultipartResponse)': () =>
          client.postMultipartResponse(
            '/w',
            FormData.fromMap({'name': 'Lussen'}),
            retryAfterLogin: false,
          ),
    };

    for (final MapEntry(key: kind, value: write) in writes.entries) {
      test('$kind fails without a login; sent again, it goes out once, in '
          'the session of a login made before it', () async {
        await serve(_Smartschool());
        server.endSessionsBefore.add('POST /w');

        await expectLater(write(), throwsA(_notRetried));
        expect(server.log, ['POST /w']);

        // Before the fix: refused again in the same session, without a
        // login, every time.
        final response = await write();

        expect(response.statusCode, 200);
        expect(response.data, 'ok /w');
        expect(server.log, ['POST /w', ..._login, 'POST /w']);
        expect(server.sessionCookies.last, 'session-1');
        expect(server.count(_password), 1);
      });
    }

    test('the next request of any kind logs in before it is sent: a GET '
        'goes out once, in the new session', () async {
      await serve(_Smartschool());
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));

      expect(await client.getRaw('/r'), 'page /r');

      // Before the fix: the GET was refused first, then logged in, and was
      // sent again.
      expect(server.log, ['POST /w', ..._login, 'GET /r']);
      expect(server.sessionCookies.last, 'session-1');
    });

    test('once that login completed, requests go out without logging in '
        'again', () async {
      await serve(_Smartschool());
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));
      await client.getRaw('/r');
      final before = server.log.length;

      await writes.values.first();
      await client.getRaw('/s');

      expect(server.logFrom(before), ['POST /w', 'GET /s']);
      expect(server.count(_password), 1);
    });

    test('requests that go out together after it share one login, and each '
        'goes out once', () async {
      await serve(_Smartschool());
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));
      final before = server.log.length;

      final results = await Future.wait<Object?>([
        client.getRaw('/a'),
        client.postFormRaw('/b', {'k': 'v'}),
        client.postJsonResponse('/w', data: '{}', retryAfterLogin: false),
      ]);

      expect(results.take(2), ['page /a', 'ok /b']);
      expect((results.last! as Response<String>).data, 'ok /w');
      expect(server.count(_password), 1);
      final sent = server.logFrom(before).skip(_login.length).toList();
      expect(sent, unorderedEquals(['GET /a', 'POST /b', 'POST /w']));
      expect(
        server.sessionCookies.sublist(before + _login.length),
        everyElement('session-1'),
      );
    });

    test('a request sent with sameSessionAs does not log in first: it goes '
        'out only in the session of its answer, as before (#38)', () async {
      await serve(_Smartschool());
      final form = await client.getResponse('/form');
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));

      await expectLater(
        client.postFormResponse(
          '/step',
          {'k': 'v'},
          retryAfterLogin: false,
          sameSessionAs: form,
        ),
        throwsA(_notRetried),
      );

      expect(server.log, ['GET /form', 'POST /w', 'POST /step']);
      expect(server.sessionCookies, everyElement(_firstSession));
      expect(server.count(_password), 0);
    });

    test('when the login before it fails, the request is not sent: it fails '
        'with what the login failed with', () async {
      await serve(_Smartschool()..passwordAccepted = false);
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));

      await expectLater(
        writes.values.first(),
        throwsA(isA<SmartschoolInvalidCredentialsError>()),
      );

      expect(server.count('POST /w'), 1);
      expect(server.count(_password), 1);
    });

    test('a refused read whose login failed leaves the session marked as '
        'refused too: a write after it logs in first', () async {
      await serve(_Smartschool()..unreachableDuringLogin = true);
      server.endSessionsBefore.add('GET /a');
      await expectLater(
        client.getRaw('/a'),
        throwsA(isA<SmartschoolConnectionError>()),
      );
      server.unreachableDuringLogin = false;
      final before = server.log.length;

      // Before the fix: the write went out in the refused session, and
      // failed without a login.
      final response = await writes.values.first();

      expect(response.data, 'ok /w');
      expect(server.logFrom(before), [..._login, 'POST /w']);
      // session-1 is the one of the failed login, which got past the
      // password.
      expect(server.sessionCookies.last, 'session-2');
    });

    test('when Smartschool refuses the new session too, the request fails as '
        'a refused retry does, after one login', () async {
      await serve(_Smartschool()..acceptsNewSessions = false);
      server.endSessionsBefore.add('POST /w');
      await expectLater(writes.values.first(), throwsA(_notRetried));

      await expectLater(
        client.getRaw('/r'),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('after logging in again before it was sent'),
          ),
        ),
      );

      expect(server.log, ['POST /w', ..._login, 'GET /r']);
      expect(server.count(_password), 1);
    });

    test('at the limit on logins in a row, it goes out as it is, and its '
        'error says that the client does not log in (#31)', () async {
      await serve(_Smartschool()..acceptsNewSessions = false);
      server.endSessionsBefore.add('GET /x');
      for (var i = 1; i <= 3; i++) {
        await expectLater(
          client.getRaw('/x'),
          throwsA(isA<SmartschoolSessionExpiredError>()),
        );
      }
      expect(server.count(_password), 3);

      final atLimit = isA<SmartschoolSessionExpiredError>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('not retried after logging in again'),
          contains('does not log in before its next request'),
          contains('3 logins in a row'),
        ),
      );
      await expectLater(writes.values.first(), throwsA(atLimit));
      await expectLater(writes.values.first(), throwsA(atLimit));

      expect(server.count('POST /w'), 2);
      expect(server.count(_password), 3);
    });
  });

  group('a write of a service tried again after Smartschool refused the '
      'session for it (#134)', () {
    test('LessonContentService.createLesson without courses or attachments '
        '(the issue): the second call logs in, and makes the lesfiche '
        'once', () async {
      await serve(
        _Smartschool({
          _createLesson: _json('{"id":"$_lessonId"}', status: 201),
          _getLesson: _json(_lessonDetail),
        }),
      );
      server.endSessionsBefore.add(_createLesson);
      final lessonContent = LessonContentService(client);

      await expectLater(
        lessonContent.createLesson(name: 'Lussen'),
        throwsA(_notRetried),
      );
      expect(server.log, [_createLesson]);
      expect(server.handled, isEmpty);

      // Before the fix: refused again without a login (the create is the
      // only request before the read-back), however often it was called.
      final lesson = await lessonContent.createLesson(name: 'Lussen');

      expect(lesson.id, _lessonId);
      expect(lesson.name, 'Lussen');
      expect(server.log, [_createLesson, ..._login, _createLesson, _getLesson]);
      expect(server.handled, [
        'session-1: $_createLesson',
        'session-1: $_getLesson',
      ]);
    });

    test('LessonContentService.addWeblink: the second call logs in, and adds '
        'the weblink once', () async {
      await serve(_Smartschool({_addWeblink: _json(_weblink)}));
      server.endSessionsBefore.add(_addWeblink);
      final lessonContent = LessonContentService(client);
      final lesson = LessonContentItem.fromJson(
        jsonDecode(_lessonDetail) as Map<String, dynamic>,
      );
      const link = NewLessonContentWeblink(
        name: 'Oefeningen',
        url: 'https://example.com/oefeningen',
      );

      await expectLater(
        lessonContent.addWeblink(lesson, link),
        throwsA(_notRetried),
      );

      final added = await lessonContent.addWeblink(lesson, link);

      expect(added.name, 'Oefeningen');
      expect(server.log, [_addWeblink, ..._login, _addWeblink]);
      expect(server.handled, ['session-1: $_addWeblink']);
    });

    test('IntradeskService.createFolder, which reads its parent first '
        '(#138): the read logs in before it goes out, and the folder is made '
        'once', () async {
      await serve(
        _Smartschool({
          _courses: _json('[{"platformId":49}]'),
          _parentsOfParent: _json('["$_top"]'),
          _listingOfTop: _json(
            '{"folders":[${_folder(id: _parent, name: 'tests', parent: _top)}],'
            '"files":[],"weblinks":[]}',
          ),
          _createFolder: _json(
            _folder(
              id: _newFolder,
              name: 'dartschool test map',
              parent: _parent,
            ),
            status: 201,
          ),
        }),
      );
      server.endSessionsBefore.add(_createFolder);
      final intradesk = IntradeskService(client);
      Future<IntradeskFolder> create() => intradesk.createFolder(
        parentFolderId: _parent,
        name: 'dartschool test map',
      );

      await expectLater(create(), throwsA(_notRetried));
      expect(server.log, [
        _courses,
        _parentsOfParent,
        _listingOfTop,
        _createFolder,
      ]);
      final before = server.log.length;

      final folder = await create();

      expect(folder.id, _newFolder);
      // Before the fix: the read of the parent was refused first, logged in,
      // and was sent again.
      expect(server.logFrom(before), [
        ..._login,
        _parentsOfParent,
        _listingOfTop,
        _createFolder,
      ]);
      expect(server.handled.where((h) => h.endsWith(_createFolder)), [
        'session-1: $_createFolder',
      ]);
    });
  });
}
