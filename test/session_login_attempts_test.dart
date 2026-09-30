// Regression tests for issue #31: the limit on logging in again (at most 3
// logins in a row) did not mean the same thing for every way Smartschool
// refuses a session.
//
// The count was cleared by every answer whose final URL was off the login
// chain, including the retry after a login and the login chain's own requests.
// So:
// - a retry refused with a `401` (#8) or an unfollowed `302` to `/login`
//   (#22) kept the requested URL, cleared the count, and the limit never
//   applied: each request ran a full login (password and 2FA) again;
// - a login without 2FA lands on `/`, which cleared the count too;
// - a retry redirected to `/login` (a GET) did not clear it, so after three
//   such requests the client stopped logging in, with the base
//   `SmartschoolAuthenticationError('Maximum login attempts reached')`.
//
// The count is now cleared only by an answer to a request that Smartschool
// did not refuse, and reaching the limit is a `SmartschoolSessionExpiredError`.
//
// Like the fakes in the other session tests, the fake Smartschool below keeps
// the session state itself and ignores the cookies the client sends. It does
// not accept the session after a login unless a test says so: the login goes
// through, and the request is refused again.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

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

const _home = '<html><body>home</body></html>';

/// The login POST: one per login.
const _password = 'POST /login';

/// A Smartschool that refuses the session as the live platform does: a page
/// request (GET) is redirected to the login chain, an XHR/form POST gets a
/// bare `401`, and a POST without `X-Requested-With` gets a `302` to `/login`
/// that the HTTP client does not follow.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.twoFactor = true, this.passwordAccepted = true});

  /// Whether an accepted password leads to the 2FA step, or straight home.
  final bool twoFactor;

  /// Whether the login POST is answered with a redirect home or back to
  /// `/login`.
  final bool passwordAccepted;

  /// Whether Smartschool accepts the session for a request right now.
  bool acceptsSession = false;

  /// What [acceptsSession] becomes when a login completes; `false` keeps
  /// refusing the session, as if the new one were not taken into account.
  bool acceptsSessionAfterLogin = false;

  bool _afterPassword = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  /// How many times the client logged in (sent its password).
  int get logins => log.where((l) => l == _password).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final request = '${options.method} $path';
    log.add(request);

    if (request == _password) {
      _afterPassword = passwordAccepted;
      return _redirect(passwordAccepted ? '/' : '/login');
    }
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      acceptsSession = acceptsSessionAfterLogin;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }
    if (options.method == 'GET' && _afterPassword) {
      // The client following the redirect after an accepted password.
      _afterPassword = false;
      if (twoFactor) {
        return _page(path, '/2fa', '<html><body>2fa</body></html>');
      }
      acceptsSession = acceptsSessionAfterLogin;
      return _page(path, path, _home);
    }

    if (options.method == 'POST') {
      if (acceptsSession) return _response('ok');
      return _sentWithXhr(options)
          ? _response('', status: 401)
          : _redirect('/login');
    }
    if (acceptsSession) return _page(path, path, _home);
    return _page(path, '/login', _loginPage);
  }

  @override
  void close({bool force = false}) {}
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
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '<html><body>Redirecting to $location</body></html>',
  302,
  headers: {
    Headers.contentTypeHeader: ['text/html'],
    'location': [location],
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

/// The failure of a request whose retry after logging in again was refused.
final Matcher _retryRefused = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('after logging in again'),
);

/// The failure of a refused request once the limit is reached: no login.
final Matcher _limitReached = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  allOf(contains('did not log in again'), contains('3 logins in a row')),
);

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;
  late _Smartschool server;

  Future<void> serve(_Smartschool smartschool) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_31_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  /// The ways Smartschool refuses a session, each with a request it refuses
  /// that way.
  final triggers = <String, Future<Object?> Function()>{
    'a GET redirected to /login': () => client.getRaw('/x'),
    'an XHR/form POST answered 401 (#8)': () => client.postFormRaw('/x', {}),
    'a POST answered 302 to /login (#22)': () =>
        client.postJson('/x', data: '{}'),
  };

  group('every way Smartschool refuses the session counts toward one limit '
      '(#31)', () {
    for (final MapEntry(key: trigger, value: send) in triggers.entries) {
      test('$trigger: 3 logins in a row, then no login', () async {
        await serve(_Smartschool());

        for (var i = 1; i <= 3; i++) {
          await expectLater(send(), throwsA(_retryRefused), reason: '#$i');
          expect(server.logins, i, reason: 'one login for request #$i');
        }
        // Before the fix: a 401 or an unfollowed 302 kept logging in (5
        // logins), and a GET got the base SmartschoolAuthenticationError
        // "Maximum login attempts reached".
        for (var i = 4; i <= 5; i++) {
          final before = server.log.length;
          await expectLater(send(), throwsA(_limitReached), reason: '#$i');
          expect(
            server.log.sublist(before),
            hasLength(1),
            reason:
                'request #$i is sent once, and neither logs in nor '
                'is retried',
          );
        }
        expect(server.logins, 3);
      });
    }

    test('the three ways share one count', () async {
      await serve(_Smartschool());
      final sends = [...triggers.values, ...triggers.values];

      for (final send in sends.take(3)) {
        await expectLater(send(), throwsA(_retryRefused));
      }
      for (final send in sends.skip(3)) {
        await expectLater(send(), throwsA(_limitReached));
      }
      // Before the fix: 5 logins, since only the GET's retry did not clear
      // the count.
      expect(server.logins, 3);
    });

    test('a login without 2FA counts as well', () async {
      // The login lands on `/`, an answer off the login chain.
      await serve(_Smartschool(twoFactor: false));

      for (var i = 1; i <= 3; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      }
      // Before the fix: the login chain's own GET of `/` cleared the count,
      // so every request logged in again.
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.logins, 3);
    });

    test('a rejected password counts as well', () async {
      await serve(_Smartschool(passwordAccepted: false));

      for (var i = 1; i <= 3; i++) {
        await expectLater(
          client.postFormRaw('/x', {}),
          throwsA(isA<SmartschoolInvalidCredentialsError>()),
        );
      }
      // Before the fix: the base SmartschoolAuthenticationError "Maximum
      // login attempts reached".
      await expectLater(client.postFormRaw('/x', {}), throwsA(_limitReached));
      expect(server.logins, 3);
    });
  });

  group('only an answer Smartschool did not refuse clears the count (#31)', () {
    test('an accepted request', () async {
      await serve(_Smartschool());

      for (var i = 1; i <= 2; i++) {
        await expectLater(client.postFormRaw('/x', {}), throwsA(_retryRefused));
      }
      server.acceptsSession = true;
      expect(await client.postFormRaw('/x', {}), 'ok');
      server.acceptsSession = false;

      for (var i = 1; i <= 3; i++) {
        await expectLater(client.postFormRaw('/x', {}), throwsA(_retryRefused));
      }
      await expectLater(client.postFormRaw('/x', {}), throwsA(_limitReached));
      expect(server.logins, 5);
    });

    test('an accepted retry after logging in again', () async {
      await serve(_Smartschool());

      for (var i = 1; i <= 2; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      }
      server.acceptsSessionAfterLogin = true;
      expect(await client.getRaw('/x'), _home);
      server
        ..acceptsSession = false
        ..acceptsSessionAfterLogin = false;

      for (var i = 1; i <= 3; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      }
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.logins, 6);
    });

    test('a client that reached the limit logs in again once a request is '
        'accepted', () async {
      await serve(_Smartschool());

      for (var i = 1; i <= 3; i++) {
        await expectLater(client.postJson('/x'), throwsA(_retryRefused));
      }
      await expectLater(client.postJson('/x'), throwsA(_limitReached));
      expect(server.logins, 3);

      server.acceptsSession = true;
      await client.getRaw('/x');
      server.acceptsSession = false;

      await expectLater(client.postJson('/x'), throwsA(_retryRefused));
      expect(server.logins, 4);
    });
  });
}
