// Regression tests for issue #20: a login failure triggered by a regular
// request (a service call on a cold or expired session) reached the caller
// wrapped in a `DioException`, as its `error`. The auth interceptor can only
// reject a request with a `DioException`, and only `ensureAuthenticated()`
// unwrapped it, so an `on SmartschoolInvalidCredentialsError` (or any
// `on SmartschoolAuthenticationError`) around a service call never matched.
//
// The request helpers of `SmartschoolClient` now throw the `SmartschoolException`
// itself. The fake Smartschool below rejects the password: a GET is redirected
// to `/login`, an XHR/form POST is answered with a bare `401` (#8), and both
// start the login chain.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/services/intradesk_service.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/presence_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'wrong';
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

/// A Smartschool that rejects the password: every request ends on `/login`.
class _RejectsPassword implements HttpClientAdapter {
  _RejectsPassword({this.loginPage = _loginPage});

  /// The HTML served at `/login`.
  final String loginPage;

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

    // The password is rejected: a 302 back to the login page.
    if (options.method == 'POST' && path == '/login') {
      return ResponseBody.fromString(
        '<html><body>Redirecting to /login</body></html>',
        302,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          'location': ['/login'],
        },
      );
    }

    // An XHR/form POST on an unauthenticated session: a bare 401 (#8).
    if (options.method == 'POST') {
      return ResponseBody.fromString('', 401);
    }

    // A GET: redirected to the login page, a redirect the HTTP client follows
    // itself and reports through `redirects`.
    final response = ResponseBody.fromString(
      loginPage,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
    if (path != '/login') {
      response.redirects = [
        RedirectRecord(302, 'GET', Uri.parse('https://$_host/login')),
      ];
    }
    return response;
  }

  @override
  void close({bool force = false}) {}
}

/// Fails every request the way `IOHttpClientAdapter` reports a host that does
/// not resolve.
class _Unreachable implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: "Failed host lookup: '$_host'",
    error: const SocketException("Failed host lookup: '$_host'"),
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;

  Future<T> clientFor<T extends HttpClientAdapter>(T server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_service_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('a login failure during a service call is thrown as itself, not '
      'wrapped in a DioException (#20)', () {
    // One call per public request helper of SmartschoolClient, through a
    // service method where one uses it.
    final calls = <String, Future<Object?> Function(SmartschoolClient)>{
      'postXml: MessagesService.getHeaders()': (c) =>
          MessagesService(c).getHeaders(),
      'getJson: MessagesService.searchRecipients()': (c) =>
          MessagesService(c).searchRecipients('jan'),
      'getJson: IntradeskService.getRootListing() (platformId)': (c) =>
          IntradeskService(c).getRootListing(),
      'getRaw: MessagesService.getCurrentUserAsRecipient()': (c) =>
          MessagesService(c).getCurrentUserAsRecipient(),
      'postFormRaw: PresenceService.getConfig()': (c) =>
          PresenceService(c).getConfig(),
      'postFormEncodedRaw: MessagesService.moveToArchive()': (c) =>
          MessagesService(c).moveToArchive([1]),
      'postMultipartRaw': (c) => c.postMultipartRaw(
        '/?module=Messages&file=composeMessage',
        FormData.fromMap({'field': 'value'}),
      ),
      'postJson': (c) => c.postJson('/api/v1/endpoint', data: '{}'),
      'download': (c) => c.download('/files/document.pdf'),
    };

    for (final MapEntry(key: name, value: call) in calls.entries) {
      test(name, () async {
        final server = await clientFor(_RejectsPassword());

        // Before the fix: DioException(error: SmartschoolInvalidCredentialsError).
        await expectLater(
          call(client),
          throwsA(
            isA<SmartschoolInvalidCredentialsError>().having(
              (e) => e.message,
              'message',
              startsWith('Login failed'),
            ),
          ),
        );
        expect(server.log, contains('POST /login'), reason: 'a login ran');
      });
    }

    test('an on-clause for the login failure matches around a service '
        'call', () async {
      await clientFor(_RejectsPassword());

      Object? caught;
      try {
        await MessagesService(client).getHeaders();
      } on SmartschoolAuthenticationError catch (e) {
        caught = e;
      }

      expect(caught, isA<SmartschoolInvalidCredentialsError>());
    });

    test('another SmartschoolException raised in the login chain is thrown '
        'as itself too', () async {
      // A login page without the login form: filling it in fails with a
      // parsing error, which Dio wraps in a DioException like any error.
      await clientFor(
        _RejectsPassword(loginPage: '<html><body>maintenance</body></html>'),
      );

      await expectLater(
        MessagesService(client).getCurrentUserAsRecipient(),
        throwsA(
          isA<SmartschoolParsingError>().having(
            (e) => e.message,
            'message',
            contains('login_form'),
          ),
        ),
      );
    });

    test('a DioException that carries no SmartschoolException is left '
        'alone', () async {
      // Only the SmartschoolException inside a DioException is unwrapped: a
      // network failure during a service call still reaches the caller as the
      // DioException it is (only ensureAuthenticated() maps it to a
      // SmartschoolConnectionError; see #21).
      await clientFor(_Unreachable());

      await expectLater(
        MessagesService(client).getHeaders(),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.connectionError)
              .having((e) => e.error, 'error', isA<SocketException>()),
        ),
      );
    });
  });
}
