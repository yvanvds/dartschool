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
// Issue #32: a client that reached the limit stayed stuck until a new
// `SmartschoolClient` was made, since only an answer Smartschool accepts
// cleared the count, and none can arrive without a login. It now tries one
// login again once a cooldown has passed (unless Smartschool rejected the
// credentials at the last login), and `resetLoginAttempts()` lets it log in
// again at once. Those tests move a fake clock instead of waiting.
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

import 'support/no_network.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  _Credentials({this.mfa = 'JBSWY3DPEHPK3PXP'});

  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  final String? mfa;
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
  _Smartschool({
    this.twoFactor = true,
    this.passwordAccepted = true,
    this.twoFactorAccepted = true,
  });

  /// Whether an accepted password leads to the 2FA step, or straight home.
  final bool twoFactor;

  /// Whether the login POST is answered with a redirect home or back to
  /// `/login`.
  bool passwordAccepted;

  /// Whether the 2FA code is accepted.
  final bool twoFactorAccepted;

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
      if (!twoFactorAccepted) {
        return _response(
          '{"success":false,"error":"Ongeldige code"}',
          contentType: Headers.jsonContentType,
        );
      }
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

/// The failure of a refused request once the limit is reached, when
/// Smartschool rejected the credentials at the last login: no login, also
/// after the cooldown (#32).
final Matcher _credentialsRejected = allOf(
  _limitReached,
  isA<SmartschoolSessionExpiredError>().having(
    (e) => e.message,
    'message',
    allOf(
      contains('rejected the credentials'),
      contains('resetLoginAttempts()'),
    ),
  ),
);

void main() {
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;
  late _Smartschool server;

  Future<void> serve(
    _Smartschool smartschool, {
    DateTime Function() clock = DateTime.now,
    Duration loginCooldown = SmartschoolClient.defaultLoginCooldown,
    String mfa = 'JBSWY3DPEHPK3PXP',
  }) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      _Credentials(mfa: mfa),
      cacheDir: cacheDir.path,
      clock: clock,
      loginCooldown: loginCooldown,
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

  group('a client that reached the limit logs in again after a cooldown '
      '(#32)', () {
    // The fake clock: it only moves when a test moves it.
    late DateTime now;
    DateTime clock() => now;

    setUp(() => now = DateTime.utc(2026, 9, 30, 12));

    /// Three logins in a row, each with its retry refused: the limit.
    Future<void> reachLimit(Future<Object?> Function() send) async {
      for (var i = 1; i <= 3; i++) {
        await expectLater(send(), throwsA(_retryRefused), reason: '#$i');
      }
      expect(server.logins, 3);
    }

    for (final MapEntry(key: trigger, value: send) in triggers.entries) {
      test('$trigger: one login once 5 minutes have passed since the last, '
          'and after another 5 minutes when it fails', () async {
        await serve(_Smartschool(), clock: clock);
        await reachLimit(send);

        now = now.add(const Duration(minutes: 5, microseconds: -1));
        await expectLater(
          send(),
          throwsA(
            allOf(
              _limitReached,
              isA<SmartschoolSessionExpiredError>().having(
                (e) => e.message,
                'message',
                contains('again from 2026-09-30T12:05:00.000Z on'),
              ),
            ),
          ),
        );
        expect(server.logins, 3);

        // Before #32: no login, however long the client had waited.
        now = now.add(const Duration(microseconds: 1));
        await expectLater(send(), throwsA(_retryRefused));
        expect(server.logins, 4);

        // It failed: the next login waits another 5 minutes.
        await expectLater(send(), throwsA(_limitReached));
        now = now.add(const Duration(minutes: 4, seconds: 59));
        await expectLater(send(), throwsA(_limitReached));
        expect(server.logins, 4);

        now = now.add(const Duration(seconds: 1));
        await expectLater(send(), throwsA(_retryRefused));
        expect(server.logins, 5);
      });
    }

    test('a login after the cooldown that gets the session accepted clears '
        'the count', () async {
      await serve(_Smartschool(), clock: clock);
      await reachLimit(() => client.getRaw('/x'));

      now = now.add(SmartschoolClient.defaultLoginCooldown);
      server.acceptsSessionAfterLogin = true;
      expect(await client.getRaw('/x'), _home);
      expect(server.logins, 4);

      // Three logins in a row again, without waiting.
      server
        ..acceptsSession = false
        ..acceptsSessionAfterLogin = false;
      for (var i = 1; i <= 3; i++) {
        await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      }
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.logins, 7);
    });

    test(
      'requests refused while that login runs do not start another one',
      () async {
        await serve(_Smartschool(), clock: clock);
        await reachLimit(() => client.postFormRaw('/x', {}));

        now = now.add(SmartschoolClient.defaultLoginCooldown);
        final failures = await Future.wait([
          for (var i = 0; i < 3; i++)
            client
                .postFormRaw('/x', {})
                .then<Object?>((_) => null, onError: (Object e) => e),
        ]);
        // Since #36 they wait for that login and are retried in its session,
        // instead of failing at once; it is still one login.
        expect(failures, [_retryRefused, _retryRefused, _retryRefused]);
        expect(server.logins, 4);

        // It counted once, and failed: the next login waits a cooldown.
        await expectLater(client.postFormRaw('/x', {}), throwsA(_limitReached));
        expect(server.logins, 4);
      },
    );

    test('loginCooldown sets how long the client waits', () async {
      await serve(
        _Smartschool(),
        clock: clock,
        loginCooldown: const Duration(seconds: 30),
      );
      await reachLimit(() => client.postJson('/x'));

      now = now.add(const Duration(seconds: 29));
      await expectLater(client.postJson('/x'), throwsA(_limitReached));
      expect(server.logins, 3);

      now = now.add(const Duration(seconds: 1));
      await expectLater(client.postJson('/x'), throwsA(_retryRefused));
      expect(server.logins, 4);
    });

    test('a clock that was set back does not hold the client for the size '
        'of the jump', () async {
      await serve(_Smartschool(), clock: clock);
      await reachLimit(() => client.getRaw('/x'));

      now = now.subtract(const Duration(hours: 1));
      await expectLater(client.getRaw('/x'), throwsA(_retryRefused));
      expect(server.logins, 4);

      // The cooldown runs from that login.
      await expectLater(client.getRaw('/x'), throwsA(_limitReached));
      expect(server.logins, 4);
    });

    final credentialFailures =
        <String, (_Smartschool Function(), Matcher, {String mfa})>{
          'a rejected password': (
            () => _Smartschool(passwordAccepted: false),
            isA<SmartschoolInvalidCredentialsError>(),
            mfa: 'JBSWY3DPEHPK3PXP',
          ),
          'a rejected 2FA code': (
            () => _Smartschool(twoFactorAccepted: false),
            isA<SmartschoolTwoFactorRejectedError>(),
            mfa: 'JBSWY3DPEHPK3PXP',
          ),
          // A date passes the check before the password (#79): the login
          // posts it, and the 2FA step finds it is no key.
          'a date as TOTP secret, found at the 2FA step (#79)': (
            () => _Smartschool(),
            isA<SmartschoolInvalidTotpSecretError>(),
            mfa: '2010-05-15',
          ),
        };
    for (final MapEntry(key: failure, value: (smartschool, loginFailed, :mfa))
        in credentialFailures.entries) {
      test('$failure: no login after the cooldown, until '
          'resetLoginAttempts()', () async {
        await serve(smartschool(), clock: clock, mfa: mfa);
        for (var i = 1; i <= 3; i++) {
          await expectLater(
            client.postFormRaw('/x', {}),
            throwsA(loginFailed),
            reason: '#$i',
          );
        }
        expect(server.logins, 3);

        // Trying the same credentials every few minutes could get the
        // account locked.
        now = now.add(const Duration(days: 1));
        await expectLater(
          client.postFormRaw('/x', {}),
          throwsA(_credentialsRejected),
        );
        expect(server.logins, 3);

        client.resetLoginAttempts();
        await expectLater(client.postFormRaw('/x', {}), throwsA(loginFailed));
        expect(server.logins, 4);
      });
    }

    test('a login after the cooldown whose password is rejected stops the '
        'client until resetLoginAttempts()', () async {
      await serve(_Smartschool(), clock: clock);
      await reachLimit(() => client.getRaw('/x'));

      // The password was changed in the meantime.
      server.passwordAccepted = false;
      now = now.add(SmartschoolClient.defaultLoginCooldown);
      await expectLater(
        client.getRaw('/x'),
        throwsA(isA<SmartschoolInvalidCredentialsError>()),
      );
      expect(server.logins, 4);

      now = now.add(const Duration(days: 1));
      await expectLater(client.getRaw('/x'), throwsA(_credentialsRejected));
      expect(server.logins, 4);

      // The app got the new password.
      server
        ..passwordAccepted = true
        ..acceptsSessionAfterLogin = true;
      client.resetLoginAttempts();
      expect(await client.getRaw('/x'), _home);
      expect(server.logins, 5);
    });

    test('resetLoginAttempts() lets the client log in again at once, three '
        'times in a row', () async {
      await serve(_Smartschool(), clock: clock);
      await reachLimit(() => client.postJson('/x'));
      await expectLater(client.postJson('/x'), throwsA(_limitReached));

      client.resetLoginAttempts();
      for (var i = 1; i <= 3; i++) {
        await expectLater(client.postJson('/x'), throwsA(_retryRefused));
      }
      await expectLater(client.postJson('/x'), throwsA(_limitReached));
      expect(server.logins, 6);
    });
  });
}
