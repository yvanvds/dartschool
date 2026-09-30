// Tests for issue #11: each login failure is thrown as its own subclass of
// `SmartschoolAuthenticationError`, so callers can match on the type instead
// of on the message text.
//
// The tests drive the real auth interceptor against a fake Smartschool
// (`HttpClientAdapter`) that walks the login chain the way the live platform
// does: the login POST and the account-verification POST are answered with a
// 302 the client follows itself (see #6), and the 2FA API answers with JSON.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

const _totpSecret = 'JBSWY3DPEHPK3PXP';

class _Credentials extends Credentials {
  _Credentials({this.mfa});

  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
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

const _accountVerificationPage = '''
<html><body>
<form class="form" name="account_verification_form" method="post">
<input type="date" name="account_verification_form[_security_question_answer]" />
<input type="hidden" name="account_verification_form[_token]" value="csrf" />
</form>
</body></html>
''';

/// The step Smartschool asks for after an accepted password.
enum _SecondStep { twoFactor, accountVerification }

/// How the 2FA API answers the code the client posts.
enum _TwoFactorAnswer {
  /// `{"success":true}`.
  accept,

  /// `{"success":false}`: what Smartschool sends for a wrong code.
  reject,

  /// A redirect back to the HTML `/2fa` page, not the JSON shape.
  backToPage,
}

class _FakeSmartschool implements HttpClientAdapter {
  _FakeSmartschool({
    this.passwordAccepted = true,
    this.secondStep = _SecondStep.twoFactor,
    this.twoFactorMethods = const ['googleAuthenticator'],
    this.twoFactorAnswer = _TwoFactorAnswer.accept,
    this.verificationAccepted = true,
  });

  final bool passwordAccepted;
  final _SecondStep secondStep;
  final List<String> twoFactorMethods;
  final _TwoFactorAnswer twoFactorAnswer;
  final bool verificationAccepted;

  bool _passwordDone = false;
  bool _secondStepDone = false;

  /// Every request the client made, as `METHOD path`.
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
      return _redirect(passwordAccepted ? '/' : '/login');
    }

    if (path == '/2fa/api/v1/config') {
      final methods = twoFactorMethods.map((m) => '"$m"').join(',');
      return _json('{"possibleAuthenticationMechanisms":[$methods]}');
    }

    if (path == '/2fa/api/v1/google-authenticator') {
      switch (twoFactorAnswer) {
        case _TwoFactorAnswer.accept:
          _secondStepDone = true;
          return _json('{"success":true,"redirectTo":"/"}');
        case _TwoFactorAnswer.reject:
          return _json(
            '{"success":false,"error":"authentication.google2fa_not_valid"}',
          );
        case _TwoFactorAnswer.backToPage:
          return _redirect('/2fa');
      }
    }

    if (options.method == 'POST' && path == '/account-verification') {
      _secondStepDone = verificationAccepted;
      return _redirect(verificationAccepted ? '/' : '/account-verification');
    }

    // A GET anywhere else: the server sends the client to wherever the
    // session is in the chain, and the client follows that redirect itself.
    if (!_passwordDone) return _page(path, '/login', _loginPage);
    if (!_secondStepDone) {
      return switch (secondStep) {
        _SecondStep.twoFactor => _page(
          path,
          '/2fa',
          '<html><body>2fa</body></html>',
        ),
        _SecondStep.accountVerification => _page(
          path,
          '/account-verification',
          _accountVerificationPage,
        ),
      };
    }
    return _page(path, path, '<html><body>home</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

/// Sends every GET to [stuckOn], an auth page the login chain does not know.
class _StuckOnUnknownAuthPage implements HttpClientAdapter {
  _StuckOnUnknownAuthPage(this.stuckOn);

  final String stuckOn;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      _page(options.uri.path, stuckOn, '<html><body>unknown</body></html>');

  @override
  void close({bool force = false}) {}
}

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html'],
    },
  );
  if (requested != at) {
    response.redirects = [
      RedirectRecord(302, 'GET', Uri.parse('https://school.smartschool.be$at')),
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

ResponseBody _json(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;

  Future<SmartschoolClient> clientFor(
    HttpClientAdapter server, {
    String? mfa = _totpSecret,
  }) async {
    client = await SmartschoolClient.create(
      _Credentials(mfa: mfa),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return client;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_login_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('a login failure is thrown as its own type (#11)', () {
    test(
      'a rejected password is a SmartschoolInvalidCredentialsError',
      () async {
        await clientFor(_FakeSmartschool(passwordAccepted: false));

        await expectLater(
          client.getRaw('/index'),
          throwsA(
            isA<SmartschoolInvalidCredentialsError>().having(
              (e) => e.message,
              'message',
              startsWith('Login failed'),
            ),
          ),
        );
      },
    );

    test(
      'a rejected 2FA code is a SmartschoolTwoFactorRejectedError',
      () async {
        await clientFor(
          _FakeSmartschool(twoFactorAnswer: _TwoFactorAnswer.reject),
        );

        await expectLater(
          client.getRaw('/index'),
          throwsA(isA<SmartschoolTwoFactorRejectedError>()),
        );
      },
    );

    test('a 2FA code answered with the 2FA page again is a '
        'SmartschoolTwoFactorRejectedError', () async {
      final server = _FakeSmartschool(
        twoFactorAnswer: _TwoFactorAnswer.backToPage,
      );
      await clientFor(server);

      await expectLater(
        client.getRaw('/index'),
        throwsA(isA<SmartschoolTwoFactorRejectedError>()),
      );
      expect(server.log, contains('POST /2fa/api/v1/google-authenticator'));
    });

    test('2FA without an authenticator app is a '
        'SmartschoolUnsupportedTwoFactorMethodError', () async {
      final server = _FakeSmartschool(twoFactorMethods: const ['sms']);
      await clientFor(server);

      await expectLater(
        client.getRaw('/index'),
        throwsA(
          isA<SmartschoolUnsupportedTwoFactorMethodError>().having(
            (e) => e.availableMethods,
            'availableMethods',
            ['sms'],
          ),
        ),
      );
      expect(
        server.log,
        isNot(contains('POST /2fa/api/v1/google-authenticator')),
        reason: 'no code is sent for a method the library cannot answer',
      );
    });

    test(
      '2FA without a TOTP secret is a SmartschoolTwoFactorRequiredError',
      () async {
        final server = _FakeSmartschool();
        await clientFor(server, mfa: null);

        await expectLater(
          client.getRaw('/index'),
          throwsA(isA<SmartschoolTwoFactorRequiredError>()),
        );
        expect(
          server.log,
          isNot(contains('POST /2fa/api/v1/google-authenticator')),
        );
      },
    );

    test('account verification without mfa is a '
        'SmartschoolAccountVerificationRequiredError', () async {
      final server = _FakeSmartschool(
        secondStep: _SecondStep.accountVerification,
      );
      await clientFor(server, mfa: '  ');

      await expectLater(
        client.getRaw('/index'),
        throwsA(isA<SmartschoolAccountVerificationRequiredError>()),
      );
      expect(server.log, isNot(contains('POST /account-verification')));
    });

    test('account verification asking a date while mfa is a TOTP secret is a '
        'SmartschoolAccountVerificationRequiredError', () async {
      final server = _FakeSmartschool(
        secondStep: _SecondStep.accountVerification,
      );
      await clientFor(server, mfa: _totpSecret);

      await expectLater(
        client.getRaw('/index'),
        throwsA(
          isA<SmartschoolAccountVerificationRequiredError>().having(
            (e) => e.message,
            'message',
            contains('expects a date'),
          ),
        ),
      );
      expect(server.log, isNot(contains('POST /account-verification')));
    });

    test('a rejected account verification answer is a '
        'SmartschoolAccountVerificationRejectedError', () async {
      final server = _FakeSmartschool(
        secondStep: _SecondStep.accountVerification,
        verificationAccepted: false,
      );
      await clientFor(server, mfa: '2010-05-15');

      await expectLater(
        client.getRaw('/index'),
        throwsA(isA<SmartschoolAccountVerificationRejectedError>()),
      );
      expect(server.log, contains('POST /account-verification'));
    });

    test(
      'an accepted account verification answer completes the login',
      () async {
        // Control for the rejected case above: the same chain with the answer
        // accepted gets through, so the rejection is what the test measures.
        await clientFor(
          _FakeSmartschool(secondStep: _SecondStep.accountVerification),
          mfa: '2010-05-15',
        );

        expect(await client.getRaw('/index'), contains('home'));
      },
    );

    test('an unrecognised step in the login chain is still the base '
        'SmartschoolAuthenticationError', () async {
      await clientFor(_StuckOnUnknownAuthPage('/login/unknown-step'));

      await expectLater(
        client.getRaw('/index'),
        throwsA(
          isA<SmartschoolAuthenticationError>().having(
            (e) => e.runtimeType,
            'runtimeType',
            SmartschoolAuthenticationError,
          ),
        ),
      );
    });
  });

  group('ensureAuthenticated', () {
    test('throws the typed login failure unwrapped', () async {
      await clientFor(_FakeSmartschool(passwordAccepted: false));

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(isA<SmartschoolInvalidCredentialsError>()),
      );
    });

    test('throws a rejected 2FA code unwrapped', () async {
      await clientFor(
        _FakeSmartschool(twoFactorAnswer: _TwoFactorAnswer.reject),
      );

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(isA<SmartschoolTwoFactorRejectedError>()),
      );
    });
  });
}
