// Regression tests for issue #6: Smartschool answers a successful login form
// POST with `302 Location: /`. `dart:io`'s `HttpClient` only follows a
// redirect after a POST when it is a 303, so the response `doLogin()` got back
// still had `realUri` on `/login` — and `_driveAuthChain` read that as a failed
// login and threw, with the right password and the 2FA step never reached.
//
// The fake adapter below mirrors the client's behaviour exactly: a GET that
// hits a redirect is followed (and reported through `redirects`), a POST that
// hits a 302 is handed back as-is with the `Location` header.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

class _TwoFaCredentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_generationTime]" value="1789462456" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button class="smscButton blue" disabled type="submit">Aanmelden</button>
</form>
</body></html>
''';

/// A Smartschool that wants a password and then a TOTP code, answering the
/// login POST the way the live platform does since September 2026.
class _FakeSmartschool implements HttpClientAdapter {
  _FakeSmartschool({
    required this.loginPostStatus,
    this.passwordAccepted = true,
  });

  /// The status the login POST answers with: 302 (what Smartschool sends) or
  /// 303 (what the client used to rely on).
  final int loginPostStatus;

  /// Whether the POST is answered with a redirect home (`/`) or back to
  /// `/login`, which is what a wrong password gets.
  final bool passwordAccepted;

  bool _passwordDone = false;
  bool _twoFaDone = false;

  /// Every request the client made, as `METHOD path`, for the assertions.
  final List<String> log = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');

    if (options.method == 'POST' && path == '/login') {
      _passwordDone = passwordAccepted;
      // The client does not follow a 301/302 after a POST: the body is the
      // "Redirecting to /" stub and `Location` is the only pointer onward.
      final target = passwordAccepted ? '/' : '/login';
      return ResponseBody.fromString(
        '<html><body>Redirecting to $target</body></html>',
        loginPostStatus,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          'location': [target],
        },
      );
    }

    if (path == '/2fa/api/v1/config') {
      return _json(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _twoFaDone = true;
      return _json('{"success":true,"redirectTo":"/"}');
    }

    // A GET anywhere else: the server redirects to wherever the session is in
    // the chain, and the client follows that redirect itself.
    if (!_passwordDone) {
      return _followedTo('/login', _loginPage);
    }
    if (!_twoFaDone) {
      return _followedTo('/2fa', '<html><body>2fa</body></html>');
    }
    return ResponseBody.fromString(
      '<html><body>home</body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  ResponseBody _followedTo(String path, String body) =>
      ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        )
        ..redirects = [
          RedirectRecord(
            302,
            'GET',
            Uri.parse('https://school.smartschool.be$path'),
          ),
        ];

  ResponseBody _json(String body) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  group('login POST answered with a redirect the client did not follow', () {
    test(
      '302 after the password is followed into 2FA (issue #6 regression)',
      () async {
        final client = await SmartschoolClient.create(
          _TwoFaCredentials(),
          cacheDir: tempCacheDir(),
        );
        final server = _FakeSmartschool(loginPostStatus: 302);
        client.dio.httpClientAdapter = server;

        // Before the fix: "Login failed. Check username/password ..." — with the
        // right password, because realUri was still /login after the POST.
        await expectLater(client.getRaw('/index'), completes);

        expect(
          server.log,
          containsAllInOrder(<String>[
            'POST /login',
            'GET /',
            'POST /2fa/api/v1/google-authenticator',
          ]),
          reason:
              'the Location of the 302 must be fetched, and that fetch is '
              'what reveals the /2fa step',
        );

        await client.dispose();
      },
    );

    test('301 is followed the same way', () async {
      final client = await SmartschoolClient.create(
        _TwoFaCredentials(),
        cacheDir: tempCacheDir(),
      );
      client.dio.httpClientAdapter = _FakeSmartschool(loginPostStatus: 301);

      await expectLater(client.getRaw('/index'), completes);

      await client.dispose();
    });

    test('a wrong password still reads as a failed login', () async {
      final client = await SmartschoolClient.create(
        _TwoFaCredentials(),
        cacheDir: tempCacheDir(),
      );
      client.dio.httpClientAdapter = _FakeSmartschool(
        loginPostStatus: 302,
        passwordAccepted: false,
      );

      await expectLater(
        client.getRaw('/index'),
        throwsA(
          isA<SmartschoolAuthenticationError>().having(
            (e) => e.message,
            'message',
            contains('Login failed'),
          ),
        ),
      );

      await client.dispose();
    });
  });
}
