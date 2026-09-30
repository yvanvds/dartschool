// Regression tests for issue #9: with an expired session in the cookie cache,
// the client logged in again (password and 2FA accepted), but the retry of the
// original request was still refused — a GET landed on `/login` again, an XML
// or form POST got a `401` again.
//
// The retry was built with `RequestOptions.copyWith`, which keeps the headers
// of the original request, including the `Cookie` header `CookieManager` had
// put on it: the stale `PHPSESSID`. `CookieManager` merges such a header with
// the jar and lists the cookies parsed from it first, so the retry sent
// `PHPSESSID=<stale>; PHPSESSID=<fresh>`, and Smartschool (PHP) reads the
// first one.
//
// Unlike the fakes in the other session tests, the fake Smartschool below
// keeps its state per session cookie, the way the live platform does.
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

const _host = 'school.smartschool.be';
const _session = 'PHPSESSID';
const _staleSession = 'stale-session';

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

const _dispatcher = '/?module=Messages&file=dispatcher';

enum _Stage { anonymous, passwordDone, authenticated }

/// A Smartschool that tracks each session by its `PHPSESSID` cookie.
///
/// Like PHP, it reads the first `PHPSESSID` in the `Cookie` header and adopts
/// an unknown id as a new, anonymous session. An accepted password moves the
/// session to a new id (sent with `Set-Cookie`), so the id in the cache before
/// the login is never valid afterwards.
class _SessionCookieSmartschool implements HttpClientAdapter {
  final Map<String, _Stage> _sessions = <String, _Stage>{};
  int _issued = 0;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  /// The `PHPSESSID` values each request in [log] carried, in the order sent.
  final List<List<String>> sessionCookies = <List<String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final sent = _sessionIds(options);
    log.add('${options.method} $path');
    sessionCookies.add(sent);

    final sid = sent.isEmpty ? null : sent.first;
    final stage = sid == null
        ? _Stage.anonymous
        : _sessions.putIfAbsent(sid, () => _Stage.anonymous);

    if (options.method == 'POST' && path == '/login') {
      if (sid != null) _sessions.remove(sid);
      final fresh = 'fresh-session-${++_issued}';
      _sessions[fresh] = _Stage.passwordDone;
      return _redirect('/', setSession: fresh);
    }
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      final accepted = stage == _Stage.passwordDone;
      if (accepted) _sessions[sid!] = _Stage.authenticated;
      return _response(
        accepted
            ? '{"success":true,"redirectTo":"/"}'
            : '{"success":false,"error":"no login in progress"}',
        contentType: Headers.jsonContentType,
      );
    }

    // The XML dispatcher and the other XHR/form endpoints: a bare 401 with an
    // empty body on an unauthenticated session.
    if (options.method == 'POST') {
      if (stage != _Stage.authenticated) return _response('', status: 401);
      if (options.uri.queryParameters['file'] == 'dispatcher') {
        return _response(
          File(
            'test/fixtures/smartschool/requests/post/postboxes/message list.xml',
          ).readAsStringSync(),
          contentType: 'text/xml',
        );
      }
      return _response('saved');
    }

    // A page request: redirected to wherever the session is in the chain.
    switch (stage) {
      case _Stage.anonymous:
        return _page(path, '/login', _loginPage);
      case _Stage.passwordDone:
        return _page(path, '/2fa', '<html><body>2fa</body></html>');
      case _Stage.authenticated:
        if (path == '/course-list/api/v1/courses') {
          return _response(
            '[{"platformId":42}]',
            contentType: Headers.jsonContentType,
          );
        }
        return _page(path, path, '<html><body>home</body></html>');
    }
  }

  @override
  void close({bool force = false}) {}
}

/// The `PHPSESSID` values in the `Cookie` header of [options], in order.
List<String> _sessionIds(RequestOptions options) {
  final header = options.headers[HttpHeaders.cookieHeader] as String?;
  if (header == null) return const <String>[];
  return [
    for (final pair in header.split(';'))
      if (pair.trim().startsWith('$_session='))
        pair.trim().substring(_session.length + 1),
  ];
}

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
ResponseBody _redirect(String location, {required String setSession}) =>
    ResponseBody.fromString(
      '<html><body>Redirecting to $location</body></html>',
      302,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
        'location': [location],
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

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;
  late _SessionCookieSmartschool server;

  setUp(() async {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_retry_');

    // A cookie cache left behind by an earlier run, whose session has expired
    // on the server since.
    final staleCache = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir.path, '.cookies')),
    );
    await staleCache.saveFromResponse(Uri.parse('https://$_host/'), [
      Cookie(_session, _staleSession)..path = '/',
    ]);

    server = _SessionCookieSmartschool();
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('the retry after logging in again with a stale cookie cache (#9)', () {
    test('a GET redirected to /login is retried with the new session '
        'cookie only', () async {
      // Before the fix: the retry sent the stale PHPSESSID first, was
      // redirected to /login again, and getJson threw "Expected JSON but
      // received HTML".
      expect(await client.platformId, 42);

      expect(server.log, [
        'GET /course-list/api/v1/courses',
        'POST /login',
        'GET /',
        'GET /2fa/api/v1/config',
        'POST /2fa/api/v1/google-authenticator',
        'GET /course-list/api/v1/courses',
      ]);
      expect(server.sessionCookies.first, [_staleSession]);
      expect(server.sessionCookies.last, ['fresh-session-1']);
    });

    test('an XML POST answered with 401 is retried with the new session '
        'cookie only', () async {
      // Before the fix: the retry sent the stale PHPSESSID first and got a 401
      // again ("still answered 401").
      final headers = await MessagesService(client).getHeaders();

      expect(headers.map((h) => h.id), [123456, 7890123]);
      expect(server.log, [
        'POST /',
        'GET /login',
        'POST /login',
        'GET /',
        'GET /2fa/api/v1/config',
        'POST /2fa/api/v1/google-authenticator',
        'POST /',
      ]);
      expect(server.sessionCookies.first, [_staleSession]);
      expect(server.sessionCookies.last, ['fresh-session-1']);
    });

    test('a form POST answered with 401 is retried with the new session '
        'cookie only', () async {
      final body = await client.postFormRaw(_dispatcher, {'field': 'value'});

      expect(body, isNotEmpty);
      expect(server.log.last, 'POST /');
      expect(server.sessionCookies.last, ['fresh-session-1']);
    });

    test('the next request reuses the new session without logging in '
        'again', () async {
      await client.platformId;
      final page = await client.getRaw('/');

      expect(page, contains('home'));
      expect(server.log.where((l) => l == 'POST /login'), hasLength(1));
      expect(server.sessionCookies.last, ['fresh-session-1']);
    });
  });
}
