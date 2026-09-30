// Regression tests for issue #8: on an expired session Smartschool answers an
// XML or form POST with a bare `401` and an empty body, not with a redirect to
// `/login`. The auth interceptor only reacted to landing on the login chain,
// so it never logged in again, and `postXml` threw a `SmartschoolParsingError`
// ("non-XML response") instead.
//
// The fake Smartschool below keeps the session state itself and ignores the
// cookies the client sends: it tests what the interceptor does with a 401,
// not the cookie handling of the retry (see session_retry_cookie_test.dart).
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

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

/// A Smartschool whose session has expired: XHR/form POSTs get a bare 401
/// until the client has gone through password and 2FA again.
class _ExpiredSession implements HttpClientAdapter {
  _ExpiredSession({
    this.passwordAccepted = true,
    this.acceptsSessionAfterLogin = true,
  });

  /// Whether the login POST is answered with a redirect home or back to
  /// `/login`.
  final bool passwordAccepted;

  /// Whether the POSTs are accepted once the login completed; `false` keeps
  /// answering 401, as if the new session were not taken into account.
  final bool acceptsSessionAfterLogin;

  bool _passwordDone = false;
  bool _twoFaDone = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  int get dispatcherPosts => log.where((l) => l == 'POST /').length;

  bool get _authenticated =>
      _passwordDone && _twoFaDone && acceptsSessionAfterLogin;

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
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _twoFaDone = true;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }

    // The XML dispatcher and the other XHR/form endpoints: a bare 401 with an
    // empty body on an unauthenticated session, as the live platform does.
    if (options.method == 'POST') {
      if (!_authenticated) return _response('', status: 401);
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
    if (!_passwordDone) return _page(path, '/login', _loginPage);
    if (!_twoFaDone) {
      return _page(path, '/2fa', '<html><body>2fa</body></html>');
    }
    return _page(path, path, '<html><body>home</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = _response(body);
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
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_ExpiredSession> expiredSession({
    bool passwordAccepted = true,
    bool acceptsSessionAfterLogin = true,
  }) async {
    final server = _ExpiredSession(
      passwordAccepted: passwordAccepted,
      acceptsSessionAfterLogin: acceptsSessionAfterLogin,
    );
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_401_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('a 401 on an expired session (#8)', () {
    test('an XML POST logs in again and is retried once', () async {
      final server = await expiredSession();

      // Before the fix: SmartschoolParsingError ("non-XML response"), and no
      // login was attempted.
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
    });

    test('a form POST logs in again and is retried once', () async {
      final server = await expiredSession();

      final body = await client.postFormRaw(_dispatcher, {'field': 'value'});

      expect(body, isNotEmpty);
      expect(server.dispatcherPosts, 2);
      expect(server.log, contains('POST /2fa/api/v1/google-authenticator'));
    });

    test('a failed login is reported as the login failure', () async {
      final server = await expiredSession(passwordAccepted: false);

      await expectLater(
        MessagesService(client).getHeaders(),
        throwsA(isA<SmartschoolInvalidCredentialsError>()),
      );
      expect(server.dispatcherPosts, 1, reason: 'no retry without a login');
    });

    test('a retry that is still refused is an authentication error, and is '
        'not retried again', () async {
      final server = await expiredSession(acceptsSessionAfterLogin: false);

      await expectLater(
        MessagesService(client).getHeaders(),
        throwsA(
          isA<SmartschoolAuthenticationError>().having(
            (e) => e.message,
            'message',
            contains('still answered 401'),
          ),
        ),
      );
      expect(server.dispatcherPosts, 2);
      expect(server.log.where((l) => l == 'POST /login'), hasLength(1));
    });
  });
}
