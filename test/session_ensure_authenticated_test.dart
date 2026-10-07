// Regression tests for issue #140: `SmartschoolClient.ensureAuthenticated()`
// was documented as "Forces a lightweight authenticated request and throws if
// session is invalid", but it only read `platformId`, which the client caches
// after its first fetch. Once the platform ID was known, it sent nothing at
// all: it neither checked that Smartschool still accepted the session nor
// logged in when it did not, and returned normally on a session that had
// expired on the server, or that `clearCookies()` had dropped.
//
// It now sends its request (`GET /course-list/api/v1/courses`, the one the
// platform ID is read from) on every call. Like any request of the client, it
// logs in when Smartschool refuses the session and is retried once, and it
// logs in before it is sent when Smartschool refused the session for an
// earlier request (#134). So when it returns normally, Smartschool accepted
// the session just now; otherwise it throws what the login failed with, or a
// `SmartschoolSessionExpiredError`. `platformId` itself stays cached.
//
// Like the fake in session_refused_write_retry_test.dart, the fake
// Smartschool below keeps its state per `PHPSESSID` cookie, as the live
// platform does: the session in the cookie cache when a test starts
// (`session-0`) is one it accepts until a test ends it, the login loads the
// login page without a session cookie (#45), and an accepted password moves
// the client to a new session id (`session-1`, ...). So the tests check which
// session each request carried, not only what was sent.
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

/// The request of [SmartschoolClient.ensureAuthenticated]: the user's course
/// list, which [SmartschoolClient.platformId] is read from.
const _courses = 'GET /course-list/api/v1/courses';

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

enum _Stage { anonymous, passwordDone, authenticated }

/// A Smartschool that tracks each session by its `PHPSESSID` cookie and
/// refuses one it does not accept as the live platform does: a page request
/// (GET) is redirected to the login chain, and a POST without
/// `X-Requested-With` (a JSON POST) gets a `302` to `/login` that the HTTP
/// client does not follow.
///
/// In a session it accepts, it answers [_courses] with a course list of
/// platform 49, another GET with `page <path>`, and a POST with `ok <path>`.
class _Smartschool implements HttpClientAdapter {
  /// Whether the login POST is answered with a redirect home (and a new
  /// session) or back to `/login`.
  bool passwordAccepted = true;

  /// Whether Smartschool accepts a session that got through the login chain;
  /// `false` keeps refusing it, as if the new session were not taken into
  /// account.
  bool acceptsNewSessions = true;

  final Map<String, _Stage> _sessions = {_firstSession: _Stage.authenticated};
  int _issued = 0;

  /// The requests (`METHOD path`) before the first of which every session
  /// Smartschool knows ends.
  final Set<String> endSessionsBefore = {};

  /// Every request the client made, as `METHOD path`.
  final List<String> log = [];

  /// The first `PHPSESSID` each request in [log] carried (`null` for none).
  final List<String?> sessionCookies = [];

  /// The requests that Smartschool answered with data, in a session it
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
      return _json(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
      );
    }
    if (request == 'POST /2fa/api/v1/google-authenticator') {
      final accepted = stage == _Stage.passwordDone;
      if (accepted) _sessions[sid!] = _Stage.authenticated;
      return _json(
        accepted
            ? '{"success":true,"redirectTo":"/"}'
            : '{"success":false,"error":"Ongeldige code"}',
      );
    }

    final accepted =
        stage == _Stage.authenticated &&
        (acceptsNewSessions || sid == _firstSession);
    if (accepted) {
      handled.add('$sid: $request');
      if (request == _courses) {
        return _json(
          '[{"id":"c0000000-0000-4000-8000-000000000001","platformId":49,'
          '"name":"Informatica","isVisible":true}]',
        );
      }
      if (options.method == 'GET') return _page(path, path, 'page $path');
      return _respond(200, 'ok $path', 'text/html');
    }
    if (options.method != 'GET') return _redirect('/login');
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

ResponseBody _respond(int status, String body, String contentType) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );

ResponseBody _json(String body) => _respond(200, body, Headers.jsonContentType);

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = _respond(200, body, 'text/html');
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

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;
  late _Smartschool server;

  /// A client on a new fake Smartschool, which carries on in [_firstSession]
  /// and has checked it once with [SmartschoolClient.ensureAuthenticated]:
  /// the platform ID is known.
  Future<void> serveChecked() async {
    final cacheDir = tempCacheDir();
    // The session that an earlier run of the app saved.
    final saved = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir, '.cookies')),
    );
    await saved.saveFromResponse(Uri.parse('https://$_host/'), [
      Cookie(_sessionCookie, _firstSession)..path = '/',
    ]);
    server = _Smartschool();
    client = await SmartschoolClient.create(_Credentials(), cacheDir: cacheDir);
    client.dio.httpClientAdapter = server;
    addTearDown(client.dispose);

    await client.ensureAuthenticated();
    expect(await client.platformId, 49);
    expect(server.log, [_courses]);
  }

  group('SmartschoolClient.ensureAuthenticated checks the session on every '
      'call, also once the platform ID is known (#140)', () {
    test('a second call sends its request again, in the session it '
        'checks; platformId sends nothing once known', () async {
      await serveChecked();

      // Before the fix: nothing was sent.
      await client.ensureAuthenticated();
      expect(await client.platformId, 49);

      expect(server.log, [_courses, _courses]);
      expect(server.sessionCookies, [_firstSession, _firstSession]);
      expect(server.count(_password), 0);
    });

    test('when the session expired on the server since, it logs in, and the '
        'next requests go out in the new session', () async {
      await serveChecked();
      server.endSessionsBefore.add(_courses);

      // Before the fix: it returned normally without sending anything.
      await client.ensureAuthenticated();

      expect(server.logFrom(1), [_courses, ..._login, _courses]);
      expect(server.handled.last, 'session-1: $_courses');

      expect(await client.getRaw('/r'), 'page /r');
      expect(server.logFrom(1 + 1 + _login.length + 1), ['GET /r']);
      expect(server.sessionCookies.last, 'session-1');
      expect(server.count(_password), 1);
    });

    test('after clearCookies() (the issue), it logs in', () async {
      await serveChecked();

      await client.clearCookies();
      // Before the fix: it returned normally without sending anything.
      await client.ensureAuthenticated();

      expect(server.logFrom(1), [_courses, ..._login, _courses]);
      // Sent without a session, then in the session of the login.
      expect(server.sessionCookies[1], isNull);
      expect(server.handled.last, 'session-1: $_courses');
      expect(server.count(_password), 1);
    });

    test(
      'when the login fails, it throws what the login failed with',
      () async {
        await serveChecked();
        server
          ..passwordAccepted = false
          ..endSessionsBefore.add(_courses);

        // Before the fix: it returned normally without sending anything.
        await expectLater(
          client.ensureAuthenticated(),
          throwsA(isA<SmartschoolInvalidCredentialsError>()),
        );

        expect(server.count(_courses), 2);
        expect(server.count(_password), 1);
      },
    );

    test('when Smartschool refuses the new session too, it throws a '
        'SmartschoolSessionExpiredError', () async {
      await serveChecked();
      server
        ..acceptsNewSessions = false
        ..endSessionsBefore.add(_courses);

      // Before the fix: it returned normally without sending anything.
      await expectLater(
        client.ensureAuthenticated(),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('after logging in again'),
          ),
        ),
      );

      expect(server.logFrom(1), [_courses, ..._login, _courses]);
      expect(server.count(_password), 1);
    });

    test('after Smartschool refused the session for a request sent with '
        'retryAfterLogin: false, it logs in before its request is sent '
        '(#134)', () async {
      await serveChecked();
      server.endSessionsBefore.add('POST /w');
      await expectLater(
        client.postJsonResponse('/w', data: '{}', retryAfterLogin: false),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      final before = server.log.length;

      // Before the fix: it returned normally without sending anything, though
      // the client knew that Smartschool had refused its session.
      await client.ensureAuthenticated();

      expect(server.logFrom(before), [..._login, _courses]);
      expect(server.handled.last, 'session-1: $_courses');
      expect(server.count(_password), 1);
    });
  });
}
