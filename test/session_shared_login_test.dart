// Regression tests for issue #36: concurrent requests that found the session
// expired each ran the whole login chain, one password POST and one 2FA POST
// (with the same one-time code) per request, and each login counted toward
// the limit on logging in again (#31).
//
// Requests on one client now share a login: a request that Smartschool
// refuses while a login runs waits for it and is then retried once in its
// session, a failed login fails every request that waited for it with the
// same error, and a request that went out before a login completed and is
// refused after it is retried in the new session without logging in again.
//
// Like the fake in `session_retry_cookie_test.dart`, the fake Smartschool
// below keeps its state per `PHPSESSID` cookie, as the live platform does:
// the session in the cookie cache when a test starts is unknown to it, and
// an accepted password moves the client to a new session id. The tests hold
// the login until every concurrent request was refused, so that they all
// find it running.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = 'school.smartschool.be';
const _session = 'PHPSESSID';
const _staleSession = 'stale-session';

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

/// The 2FA POST, with the one-time code: one per login.
const _twoFactorCode = 'POST /2fa/api/v1/google-authenticator';

enum _Stage { anonymous, passwordDone, authenticated }

/// A Smartschool that tracks each session by its `PHPSESSID` cookie and
/// refuses a session as the live platform does: a page request (GET) is
/// redirected to the login chain, an XHR/form POST gets a bare `401`, and a
/// POST without `X-Requested-With` gets a `302` to `/login` that the HTTP
/// client does not follow.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.passwordAccepted = true,
    this.twoFactorAccepted = true,
    this.acceptsNewSessions = true,
    this.unreachableDuringLogin = false,
  });

  /// Whether the login POST is answered with a redirect home (and a new
  /// session) or back to `/login`.
  final bool passwordAccepted;

  /// Whether the 2FA code is accepted.
  final bool twoFactorAccepted;

  /// Whether Smartschool accepts a session that got through the login chain;
  /// `false` keeps refusing it, as if the new session were not taken into
  /// account.
  final bool acceptsNewSessions;

  /// Whether the connection fails when the login chain asks for the 2FA
  /// configuration.
  final bool unreachableDuringLogin;

  final Map<String, _Stage> _sessions = <String, _Stage>{};
  int _issued = 0;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  /// The first `PHPSESSID` each request in [log] carried (`null` for none).
  final List<String?> sessionCookies = <String?>[];

  /// The answer to the first request of each `METHOD path` in here waits
  /// until its future completes.
  final Map<String, Future<void>> holdFirst = <String, Future<void>>{};

  final Map<String, Completer<void>> _received = <String, Completer<void>>{};

  /// Completes when a request `METHOD path` has come in.
  Future<void> received(String request) =>
      _received.putIfAbsent(request, Completer<void>.new).future;

  /// How many times the client made [request].
  int count(String request) => log.where((l) => l == request).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = '${options.method} ${options.uri.path}';
    final sid = _sessionId(options);
    log.add(request);
    sessionCookies.add(sid);
    final arrived = _received.putIfAbsent(request, Completer<void>.new);
    if (!arrived.isCompleted) arrived.complete();

    final hold = holdFirst.remove(request);
    if (hold != null) await hold;
    return _answer(options, sid);
  }

  ResponseBody _answer(RequestOptions options, String? sid) {
    final path = options.uri.path;
    if ('${options.method} $path' == _password) {
      if (!passwordAccepted) return _redirect('/login');
      if (sid != null) _sessions.remove(sid);
      final fresh = 'session-${++_issued}';
      _sessions[fresh] = _Stage.passwordDone;
      return _redirect('/', setSession: fresh);
    }

    final stage = sid == null
        ? _Stage.anonymous
        : _sessions.putIfAbsent(sid, () => _Stage.anonymous);
    if (path == '/2fa/api/v1/config') {
      if (unreachableDuringLogin) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Failed host lookup',
          error: const SocketException('Failed host lookup'),
        );
      }
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if ('${options.method} $path' == _twoFactorCode) {
      final accepted = twoFactorAccepted && stage == _Stage.passwordDone;
      if (accepted) _sessions[sid!] = _Stage.authenticated;
      return _response(
        accepted
            ? '{"success":true,"redirectTo":"/"}'
            : '{"success":false,"error":"Ongeldige code"}',
        contentType: Headers.jsonContentType,
      );
    }

    final accepted = stage == _Stage.authenticated && acceptsNewSessions;
    if (options.method == 'POST') {
      if (accepted) return _response('ok $path');
      return _sentWithXhr(options)
          ? _response('', status: 401)
          : _redirect('/login');
    }
    if (stage == _Stage.passwordDone) {
      // The login chain following the redirect after an accepted password.
      return _page(path, '/2fa', '<html><body>2fa</body></html>');
    }
    if (accepted) return _page(path, path, 'page $path');
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
    if (pair.trim().startsWith('$_session=')) {
      return pair.trim().substring(_session.length + 1);
    }
  }
  return null;
}

bool _sentWithXhr(RequestOptions options) => options.headers.entries.any(
  (h) =>
      h.key.toLowerCase() == kXRequestedWith.toLowerCase() &&
      h.value == 'XMLHttpRequest',
);

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = _response(body);
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
          HttpHeaders.setCookieHeader: ['$_session=$setSession; path=/'],
      },
    );

ResponseBody _response(
  String body, {
  int status = 200,
  String contentType = 'text/html',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// Tells when a response reaches the auth interceptor: it sits right before
/// it, so the auth interceptor handles a response once the event queue has
/// run after [arrived] saw it.
class _Probe extends Interceptor {
  final Map<String, Completer<void>> _arrived = <String, Completer<void>>{};

  /// Completes when a response to the first `METHOD path` request has
  /// reached the auth interceptor.
  Future<void> arrived(String request) =>
      _arrived.putIfAbsent(request, Completer<void>.new).future;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    final seen = _arrived.putIfAbsent(
      '${options.method} ${options.uri.path}',
      Completer<void>.new,
    );
    if (!seen.isCompleted) seen.complete();
    handler.next(response);
  }
}

/// The failure of a request whose retry after logging in again was refused.
final Matcher _retryRefused = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('after logging in again'),
);

/// The failure of a refused request once the login limit is reached.
final Matcher _limitReached = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  allOf(contains('did not log in again'), contains('3 logins in a row')),
);

/// The failure of a request that is not retried after logging in again
/// (`retryAfterLogin: false`, #25).
final Matcher _notRetried = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('carries state of the refused session'),
);

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;
  late _Smartschool server;
  late _Probe probe;

  Future<void> serve(_Smartschool smartschool) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    probe = _Probe();
    // Right before the auth interceptor, which is the last one.
    client.dio.interceptors.insert(client.dio.interceptors.length - 1, probe);
  }

  /// Holds the login until the first request of each of [requests] was
  /// refused and handed to the auth interceptor.
  void holdLoginUntilRefused(Iterable<String> requests) {
    server.holdFirst[_password] = Future.wait([
      for (final request in requests) probe.arrived(request),
    ]).then((_) => pumpEventQueue());
  }

  /// Runs [send] and returns what it failed with, or `null`.
  Future<Object?> failure(Future<Object?> Function() send) =>
      send().then<Object?>((_) => null, onError: (Object e) => e);

  setUp(() async {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_36_');

    // A cookie cache left behind by an earlier run, whose session has expired
    // on the server since.
    final staleCache = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir.path, '.cookies')),
    );
    await staleCache.saveFromResponse(Uri.parse('https://$_host/'), [
      Cookie(_session, _staleSession)..path = '/',
    ]);
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('concurrent requests that find the session expired share one login '
      '(#36)', () {
    test('four GETs: one password POST, one 2FA POST, and each is retried '
        'once in the new session', () async {
      await serve(_Smartschool());
      final paths = ['/a', '/b', '/c', '/d'];
      holdLoginUntilRefused([for (final path in paths) 'GET $path']);

      final pages = await Future.wait([
        for (final path in paths) client.getRaw(path),
      ]);

      expect(pages, [for (final path in paths) 'page $path']);
      // Before the fix: four logins, each with its own password and 2FA POST.
      expect(server.count(_password), 1);
      expect(server.count(_twoFactorCode), 1);
      for (final path in paths) {
        final request = 'GET $path';
        expect(server.count(request), 2, reason: '$path and its retry');
        // The retry went out in the session of that one login.
        expect(
          server.sessionCookies[server.log.indexOf(request)],
          _staleSession,
        );
        expect(
          server.sessionCookies[server.log.lastIndexOf(request)],
          'session-1',
        );
      }
    });

    test('a GET redirected to /login, an XHR/form POST answered 401 (#8) and '
        'a multipart POST answered 302 to /login (#22)', () async {
      await serve(_Smartschool());
      holdLoginUntilRefused(['GET /a', 'POST /b', 'POST /c']);

      final results = await Future.wait([
        client.getRaw('/a'),
        client.postFormRaw('/b', {'field': 'value'}),
        client.postMultipartRaw('/c', FormData.fromMap({'field': 'value'})),
      ]);

      expect(results, ['page /a', 'ok /b', 'ok /c']);
      expect(server.count(_password), 1);
      expect(server.count(_twoFactorCode), 1);
      for (final request in ['GET /a', 'POST /b', 'POST /c']) {
        expect(server.count(request), 2, reason: '$request and its retry');
      }
    });

    test('a request refused after the login it did not wait for is retried '
        'in the new session without logging in again', () async {
      await serve(_Smartschool());
      // /b goes out with the expired session before the login, and its
      // answer comes in only after the login completed and /a was retried.
      final a = Completer<void>();
      server.holdFirst[_password] = server.received('GET /b');
      server.holdFirst['GET /b'] = a.future;

      final b = client.getRaw('/b');
      expect(await client.getRaw('/a'), 'page /a');
      a.complete();

      // Before the fix: /b logged in a second time.
      expect(await b, 'page /b');
      expect(server.count(_password), 1);
      expect(server.count(_twoFactorCode), 1);
      expect(server.count('GET /b'), 2);
    });

    test('a request after the login uses its session', () async {
      await serve(_Smartschool());
      holdLoginUntilRefused(['GET /a', 'GET /b']);
      await Future.wait([client.getRaw('/a'), client.getRaw('/b')]);

      expect(await client.getRaw('/c'), 'page /c');
      expect(server.count(_password), 1);
      expect(server.count('GET /c'), 1);
    });
  });

  group('a login that fails fails every request that waited for it with the '
      'same error (#36)', () {
    final failures = <String, (_Smartschool Function(), Matcher, int)>{
      'a rejected password': (
        () => _Smartschool(passwordAccepted: false),
        isA<SmartschoolInvalidCredentialsError>(),
        0,
      ),
      'a rejected 2FA code': (
        () => _Smartschool(twoFactorAccepted: false),
        isA<SmartschoolTwoFactorRejectedError>(),
        1,
      ),
      'Smartschool becoming unreachable': (
        () => _Smartschool(unreachableDuringLogin: true),
        isA<SmartschoolConnectionError>(),
        0,
      ),
    };

    for (final MapEntry(key: kind, value: (smartschool, failed, codes))
        in failures.entries) {
      test('$kind: one login, and three requests that fail with it', () async {
        await serve(smartschool());
        holdLoginUntilRefused(['GET /a', 'POST /b', 'POST /c']);

        final errors = await Future.wait([
          failure(() => client.getRaw('/a')),
          failure(() => client.postFormRaw('/b', {})),
          failure(
            () => client.postMultipartRaw('/c', FormData.fromMap({'k': 'v'})),
          ),
        ]);

        expect(errors, everyElement(failed));
        // Before the fix: a login per request.
        expect(server.count(_password), 1);
        expect(server.count(_twoFactorCode), codes);
        for (final request in ['GET /a', 'POST /b', 'POST /c']) {
          expect(server.count(request), 1, reason: '$request is not retried');
        }
      });
    }

    test('the requests that waited get the failure of that login, not one of '
        'their own', () async {
      await serve(_Smartschool(unreachableDuringLogin: true));
      holdLoginUntilRefused(['GET /a', 'GET /b', 'GET /c']);

      final errors = await Future.wait([
        for (final path in ['/a', '/b', '/c'])
          failure(() => client.getRaw(path)),
      ]);

      final causes = [
        for (final error in errors)
          (error! as SmartschoolConnectionError).cause,
      ];
      expect(causes.first, isA<DioException>());
      // Before the fix: each request failed on a login of its own.
      expect(causes, everyElement(same(causes.first)));
      expect(server.count('GET /2fa/api/v1/config'), 1);
    });
  });

  group('a shared login counts once toward the limit on logging in again '
      '(#31)', () {
    test('three requests whose retries are refused: two more logins in a '
        'row, then none', () async {
      await serve(_Smartschool(acceptsNewSessions: false));
      holdLoginUntilRefused(['GET /a', 'POST /b', 'POST /c']);

      final errors = await Future.wait([
        failure(() => client.getRaw('/a')),
        failure(() => client.postFormRaw('/b', {})),
        failure(() => client.postJson('/c', data: '{}')),
      ]);
      expect(errors, everyElement(_retryRefused));
      expect(server.count(_password), 1);

      // Before the fix: the three logins reached the limit already.
      for (var i = 2; i <= 3; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
        expect(server.count(_password), i);
      }
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.count(_password), 3);
    });

    test('three requests whose login is refused: two more logins in a row, '
        'then none', () async {
      await serve(_Smartschool(passwordAccepted: false));
      holdLoginUntilRefused(['GET /a', 'GET /b', 'GET /c']);

      final errors = await Future.wait([
        for (final path in ['/a', '/b', '/c'])
          failure(() => client.getRaw(path)),
      ]);
      expect(errors, everyElement(isA<SmartschoolInvalidCredentialsError>()));
      expect(server.count(_password), 1);

      for (var i = 2; i <= 3; i++) {
        await expectLater(
          client.getRaw('/x'),
          throwsA(isA<SmartschoolInvalidCredentialsError>()),
        );
        expect(server.count(_password), i);
      }
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.count(_password), 3);
    });

    test('an accepted retry after the shared login clears the count', () async {
      await serve(_Smartschool());
      holdLoginUntilRefused(['GET /a', 'GET /b']);
      await Future.wait([client.getRaw('/a'), client.getRaw('/b')]);
      expect(server.count(_password), 1);

      // The new session expires: three logins in a row are allowed again.
      client.dio.httpClientAdapter = server = _Smartschool(
        acceptsNewSessions: false,
      );
      for (var i = 1; i <= 3; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      }
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.count(_password), 3);
    });
  });

  group('a request sent with retryAfterLogin: false does not wait for a login '
      'that runs (#25)', () {
    final sends = <String, (String, Future<Object?> Function())>{
      'a multipart POST answered 302 to /login': (
        'POST /send',
        () => client.postMultipartResponse(
          '/send',
          FormData.fromMap({'k': 'v'}),
          retryAfterLogin: false,
        ),
      ),
      'a form POST answered 401': (
        'POST /send',
        () => client.postFormResponse('/send', {
          'k': 'v',
        }, retryAfterLogin: false),
      ),
    };

    for (final MapEntry(key: kind, value: (request, send)) in sends.entries) {
      test('$kind fails at once, and is not retried', () async {
        await serve(_Smartschool());
        final release = Completer<void>();
        server.holdFirst[_password] = release.future;

        final a = client.getRaw('/a');
        await server.received(_password);

        // The login is still held: the request did not wait for it.
        await expectLater(send(), throwsA(_notRetried));
        expect(server.count(_twoFactorCode), 0);

        release.complete();
        expect(await a, 'page /a');
        expect(server.count(_password), 1);
        expect(server.count(request), 1);
      });
    }
  });
}
