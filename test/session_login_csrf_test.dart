// Regression tests for issue #45: three concurrent read-only GETs on a cookie
// cache that held only a `PHPSESSID` Smartschool did not know all failed with
// `SmartschoolInvalidCredentialsError`. The one shared login (#36) posted the
// CSRF token of a login page that was no longer the token stored in its
// session, so Smartschool sent it back to `/login`, which the login chain can
// only read as a wrong password.
//
// Checked anonymously on the live platform (only `GET /login` and pages that
// redirect there; no credentials), which the fake below models:
// - Smartschool keeps a `PHPSESSID` it does not know as a new, empty session:
//   it does not send a new one. It sends a new one only when the request has
//   none. It also sets a `pid` cookie on an answer to a request without one.
// - The login form's CSRF token (`login_form[_token]`, Symfony's randomized
//   form of the stored token) is stored in the `PHPSESSID` session: renders in
//   one session carry the same stored token whatever the `pid`, and another
//   session gets another token.
// - Smartschool does not lock a session: three pages rendered at the same
//   time in one session that held no token yet stored three different tokens,
//   and the session kept one of them (the last one written), in each of three
//   rounds.
// So concurrent requests on an expired session each store a token of their
// own in that one session, and the login page the shared login got first
// holds a token that another request may have replaced.
//
// The fake answers a password POST whose token is not the one stored in the
// session of its cookie as Smartschool answers a wrong password: with a
// redirect back to `/login`.
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

import 'support/no_network.dart';

const _host = 'school.smartschool.be';
const _session = 'PHPSESSID';
const _pid = 'pid';
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

String _loginPage(String token) =>
    '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_generationTime]" value="123456" />
<input type="hidden" name="login_form[_token]" value="$token" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

/// The login POST: one per login.
const _password = 'POST /login';

/// The 2FA POST, with the one-time code: one per login.
const _twoFactorCode = 'POST /2fa/api/v1/google-authenticator';

enum _Stage { anonymous, passwordDone, authenticated }

/// What Smartschool keeps for one `PHPSESSID`.
class _ServerSession {
  _Stage stage = _Stage.anonymous;

  /// The login form's CSRF token, stored by the first login page rendered in
  /// the session.
  String? csrf;
}

/// A Smartschool that keeps its state per `PHPSESSID`, stores the login
/// form's CSRF token in it without locking the session, and redirects a
/// page request (GET) on a session that is not logged in to `/login`.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.strictSessions = false});

  /// Whether a `PHPSESSID` that Smartschool does not know is answered with a
  /// new one, as PHP does with `session.use_strict_mode`, instead of kept as
  /// a new, empty session, which is what Smartschool does.
  final bool strictSessions;

  final Map<String, _ServerSession> _sessions = <String, _ServerSession>{};
  int _issuedSessions = 0;
  int _issuedPids = 0;
  int _issuedTokens = 0;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  /// The cookies each request in [log] carried.
  final List<Map<String, String>> cookies = <Map<String, String>>[];

  /// The CSRF token of each login page rendered, in the order rendered.
  final List<String> rendered = <String>[];

  /// For each password POST: whether its token was the one stored in the
  /// session of the cookie it carried.
  final List<bool> passwordTokenValid = <bool>[];

  /// The answer to the first request of each `METHOD path` in here waits
  /// until its future completes.
  final Map<String, Future<void>> holdFirst = <String, Future<void>>{};

  final Map<String, Completer<void>> _received = <String, Completer<void>>{};

  /// Completes when a request `METHOD path` has come in.
  Future<void> received(String request) =>
      _received.putIfAbsent(request, Completer<void>.new).future;

  /// How many times the client made [request].
  int count(String request) => log.where((l) => l == request).length;

  /// The `PHPSESSID` the first [request] carried (`null` for none).
  String? sessionOf(String request) => cookies[log.indexOf(request)][_session];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = '${options.method} ${options.uri.path}';
    final sent = _cookies(options);
    log.add(request);
    cookies.add(sent);
    final arrived = _received.putIfAbsent(request, Completer<void>.new);
    if (!arrived.isCompleted) arrived.complete();

    final setCookies = <String>[];
    var sid = sent[_session];
    if (sid == null || (strictSessions && !_sessions.containsKey(sid))) {
      sid = 'session-${++_issuedSessions}';
      setCookies.add('$_session=$sid; path=/');
    }
    final session = _sessions.putIfAbsent(sid, _ServerSession.new);
    if (!sent.containsKey(_pid)) {
      setCookies.add('$_pid=pid-${++_issuedPids}; secure; HttpOnly');
    }
    // A login page reads the session when the request comes in and stores
    // its token when it is answered: pages rendered at the same time in a
    // session without a token each store their own, and the last one wins.
    final tokenAtArrival = session.csrf;

    final hold = holdFirst.remove(request);
    if (hold != null) await hold;
    return _answer(options, sid, session, tokenAtArrival, setCookies);
  }

  ResponseBody _answer(
    RequestOptions options,
    String sid,
    _ServerSession session,
    String? tokenAtArrival,
    List<String> setCookies,
  ) {
    final path = options.uri.path;
    final request = '${options.method} $path';

    String loginForm() {
      final token = tokenAtArrival ?? 'token-${++_issuedTokens}';
      session.csrf = token;
      rendered.add(token);
      return _loginPage(token);
    }

    if (request == _password) {
      final fields = (options.data as Map).cast<String, String>();
      final tokenValid = fields['login_form[_token]'] == session.csrf;
      passwordTokenValid.add(tokenValid);
      if (!tokenValid || fields['login_form[_password]'] != 'pass') {
        return _redirect('/login', setCookies);
      }
      _sessions.remove(sid);
      final fresh = 'session-${++_issuedSessions}';
      _sessions[fresh] = _ServerSession()..stage = _Stage.passwordDone;
      return _redirect('/', [
        ...setCookies.where((c) => !c.startsWith('$_session=')),
        '$_session=$fresh; path=/',
      ]);
    }
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        setCookies,
        contentType: Headers.jsonContentType,
      );
    }
    if (request == _twoFactorCode) {
      final accepted = session.stage == _Stage.passwordDone;
      if (accepted) session.stage = _Stage.authenticated;
      return _response(
        accepted
            ? '{"success":true,"redirectTo":"/"}'
            : '{"success":false,"error":"Ongeldige code"}',
        setCookies,
        contentType: Headers.jsonContentType,
      );
    }
    if (options.method != 'GET') throw UnimplementedError(request);
    if (path == '/login') return _page(path, '/login', loginForm(), setCookies);
    switch (session.stage) {
      case _Stage.authenticated:
        return _page(path, path, 'page $path', setCookies);
      case _Stage.passwordDone:
        return _page(path, '/2fa', '<html><body>2fa</body></html>', setCookies);
      case _Stage.anonymous:
        return _page(path, '/login', loginForm(), setCookies);
    }
  }

  @override
  void close({bool force = false}) {}
}

/// The cookies in the `Cookie` header of [options]; for a name that occurs
/// more than once, the first one, which is the one Smartschool (PHP) reads.
Map<String, String> _cookies(RequestOptions options) {
  final header = options.headers[HttpHeaders.cookieHeader] as String?;
  final cookies = <String, String>{};
  for (final pair in header?.split(';') ?? const <String>[]) {
    final separator = pair.indexOf('=');
    if (separator < 0) continue;
    cookies.putIfAbsent(
      pair.substring(0, separator).trim(),
      () => pair.substring(separator + 1).trim(),
    );
  }
  return cookies;
}

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`. Like
/// the answer of `dart:io`, it carries the `Set-Cookie` of the final page.
ResponseBody _page(
  String requested,
  String at,
  String body,
  List<String> setCookies,
) {
  final response = _response(body, setCookies);
  if (requested != at) {
    response.redirects = [
      RedirectRecord(302, 'GET', Uri.parse('https://$_host$at')),
    ];
  }
  return response;
}

/// A 302 the HTTP client leaves unfollowed, as it does after every POST.
ResponseBody _redirect(String location, List<String> setCookies) =>
    ResponseBody.fromString(
      '<html><body>Redirecting to $location</body></html>',
      302,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
        'location': [location],
        if (setCookies.isNotEmpty) HttpHeaders.setCookieHeader: setCookies,
      },
    );

ResponseBody _response(
  String body,
  List<String> setCookies, {
  String contentType = 'text/html',
}) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: [contentType],
    if (setCookies.isNotEmpty) HttpHeaders.setCookieHeader: setCookies,
  },
);

/// Tells when a response reaches the auth interceptor: it sits right before
/// it, after the cookie manager has handled the response.
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

void main() {
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;
  late _Smartschool server;
  late _Probe probe;

  Future<void> serve(
    _Smartschool smartschool, {
    Credentials? credentials,
  }) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      credentials ?? _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    probe = _Probe();
    // Right before the auth interceptor, which is the last one.
    client.dio.interceptors.insert(client.dio.interceptors.length - 1, probe);
  }

  /// Puts [cookies] in the cookie cache, as an earlier run left it.
  Future<void> cache(Map<String, String> cookies) async {
    final jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir.path, '.cookies')),
    );
    await jar.saveFromResponse(Uri.parse('https://$_host/'), [
      for (final MapEntry(:key, :value) in cookies.entries)
        Cookie(key, value)..path = '/',
    ]);
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_45_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  test('three concurrent GETs on a session Smartschool does not know: the '
      'shared login posts the token of its own session, and each request is '
      'retried in the new session', () async {
    // The live check of #36: only a PHPSESSID that Smartschool does not know.
    await cache({_session: _staleSession});
    await serve(_Smartschool());
    final requests = ['GET /a', 'GET /b', 'GET /c'];
    // Smartschool renders the three login pages at the same time, in the one
    // session they carry. /a is answered first, and its login starts; /b and
    // /c are answered after that and store their tokens before Smartschool
    // checks the password POST.
    final allArrived = Future.wait([
      for (final request in requests) server.received(request),
    ]);
    server.holdFirst['GET /a'] = allArrived;
    for (final request in ['GET /b', 'GET /c']) {
      server.holdFirst[request] = allArrived.then(
        (_) => probe.arrived('GET /a'),
      );
    }
    server.holdFirst[_password] = Future.wait([
      probe.arrived('GET /b'),
      probe.arrived('GET /c'),
    ]).then((_) => pumpEventQueue());

    final pages = await Future.wait([
      client.getRaw('/a'),
      client.getRaw('/b'),
      client.getRaw('/c'),
    ]);

    // The race took place: three login pages in the stale session, each with
    // a token of its own.
    expect(server.rendered.take(3).toSet(), hasLength(3));
    // Before the fix: the password POST carried the token of /a's page,
    // which /b and /c had replaced, and all three requests failed with
    // SmartschoolInvalidCredentialsError.
    expect(pages, ['page /a', 'page /b', 'page /c']);
    expect(server.count(_password), 1);
    expect(server.passwordTokenValid, [true]);
    expect(server.count(_twoFactorCode), 1);
    // The login loaded its own login page, in a session no other request
    // carried, and posted the password in that session.
    expect(server.sessionOf('GET /login'), isNull);
    expect(server.sessionOf(_password), isNot(anyOf(isNull, _staleSession)));
    for (final request in requests) {
      expect(server.count(request), 2, reason: '$request and its retry');
    }
  });

  test('a refused answer that comes in during the login does not replace '
      'its session in the cookie cache', () async {
    // A Smartschool that answers a session id it does not know with a new
    // one (the hypothesis of #45; the live platform keeps the id instead).
    await cache({_session: _staleSession});
    await serve(_Smartschool(strictSessions: true));
    // /b is answered, with a new session id of its own, after the login sent
    // its 2FA code and before that is answered.
    server.holdFirst['GET /b'] = server.received(_twoFactorCode);
    server.holdFirst[_twoFactorCode] = probe
        .arrived('GET /b')
        .then((_) => pumpEventQueue());

    final pages = await Future.wait([client.getRaw('/a'), client.getRaw('/b')]);

    // Before the fix: the cookie manager saved /b's new session id over the
    // one the login got, and both retries went out in it and were refused
    // (SmartschoolSessionExpiredError).
    expect(pages, ['page /a', 'page /b']);
    expect(server.count(_password), 1);
    expect(server.count(_twoFactorCode), 1);
    expect(server.count('GET /a'), 2);
    expect(server.count('GET /b'), 2);
  });

  test('a single refused GET: the login loads its own login page, without '
      'the refused session id, and keeps the other cookies', () async {
    await cache({_session: _staleSession, _pid: 'pid-cached'});
    await serve(_Smartschool());

    expect(await client.getRaw('/a'), 'page /a');

    expect(server.log, [
      'GET /a',
      'GET /login',
      _password,
      'GET /',
      'GET /2fa/api/v1/config',
      _twoFactorCode,
      'GET /a',
    ]);
    expect(server.cookies[1], {_pid: 'pid-cached'});
    expect(server.cookies[2], {_session: 'session-1', _pid: 'pid-cached'});
    expect(server.passwordTokenValid, [true]);
  });

  test('a rejected password is still a SmartschoolInvalidCredentialsError, '
      'with a token that belongs to the session', () async {
    await cache({_session: _staleSession});
    await serve(_Smartschool(), credentials: _WrongPassword());

    await expectLater(
      client.getRaw('/a'),
      throwsA(isA<SmartschoolInvalidCredentialsError>()),
    );
    expect(server.passwordTokenValid, [true]);
  });
}

class _WrongPassword extends _Credentials {
  @override
  String get password => 'wrong';
}
