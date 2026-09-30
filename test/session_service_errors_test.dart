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
//
// And for issue #21: a network failure during a service call (Smartschool
// unreachable) reached the caller as the raw `DioException`, while
// `ensureAuthenticated()` reports it as a `SmartschoolConnectionError` (#10).
// The request helpers now throw a `SmartschoolConnectionError` for it too. The
// fakes fail the way Dio's `IOHttpClientAdapter` does: DNS failures and
// refused connections as `DioExceptionType.connectionError` (carrying the
// `SocketException`), timeouts as the matching timeout type, and a socket or
// TLS error raised after the connection is up as a raw error that Dio wraps
// as `DioExceptionType.unknown`.
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

import 'support/no_network.dart';

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

/// Smartschool drops the connection on the login POST: the network fails
/// halfway through the login chain that a service call started.
class _DropsOnLoginPost extends _RejectsPassword {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.uri.path == '/login') {
      log.add('POST /login');
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection reset by peer',
        error: const SocketException('Connection reset by peer'),
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

/// Fails every request with the error [fail] builds for it.
class _Unreachable implements HttpClientAdapter {
  _Unreachable(this.fail);

  final Object Function(RequestOptions options) fail;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw fail(options);

  @override
  void close({bool force = false}) {}
}

const _hostLookupFailure = SocketException(
  "Failed host lookup: '$_host'",
  osError: OSError('No such host is known.', 11001),
);

/// Fails the request the way `IOHttpClientAdapter` reports a host that does
/// not resolve.
DioException _hostNotFound(RequestOptions options) =>
    DioException.connectionError(
      requestOptions: options,
      reason: _hostLookupFailure.message,
      error: _hostLookupFailure,
    );

/// A [SmartschoolConnectionError] whose `cause` is the [DioException] of
/// [type] that the request failed with.
TypeMatcher<SmartschoolConnectionError> _connectionError(
  DioExceptionType type,
) => isA<SmartschoolConnectionError>()
    .having(
      (e) => e.cause,
      'cause',
      isA<DioException>().having((d) => d.type, 'type', type),
    )
    .having(
      (e) => e.message,
      'message',
      startsWith('Unable to reach Smartschool at $_host: '),
    );

/// One call per public request helper of SmartschoolClient, through a service
/// method where one uses it.
final _calls = <String, Future<Object?> Function(SmartschoolClient)>{
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
  // The answer to it comes as a stream (#41).
  'downloadStream': (c) => c.downloadStream('/files/document.pdf'),
};

void main() {
  forbidRealNetwork();

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
    for (final MapEntry(key: name, value: call) in _calls.entries) {
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
  });

  group('a network failure during a service call is thrown as a '
      'SmartschoolConnectionError (#21)', () {
    for (final MapEntry(key: name, value: call) in _calls.entries) {
      test(name, () async {
        await clientFor(_Unreachable(_hostNotFound));

        // Before the fix: the DioException itself.
        await expectLater(
          call(client),
          throwsA(
            _connectionError(DioExceptionType.connectionError)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Failed host lookup'),
                )
                .having(
                  (e) => (e.cause! as DioException).error,
                  'cause.error',
                  same(_hostLookupFailure),
                ),
          ),
        );
      });
    }

    final failures =
        <String, (DioExceptionType, Object Function(RequestOptions))>{
          'a connection timeout': (
            DioExceptionType.connectionTimeout,
            (options) => DioException.connectionTimeout(
              timeout: const Duration(seconds: 5),
              requestOptions: options,
            ),
          ),
          'a send timeout': (
            DioExceptionType.sendTimeout,
            (options) => DioException.sendTimeout(
              timeout: const Duration(seconds: 5),
              requestOptions: options,
            ),
          ),
          'a receive timeout': (
            DioExceptionType.receiveTimeout,
            (options) => DioException.receiveTimeout(
              timeout: const Duration(seconds: 5),
              requestOptions: options,
            ),
          ),
          'a rejected server certificate': (
            DioExceptionType.badCertificate,
            (options) => DioException.badCertificate(requestOptions: options),
          ),
          // The adapter lets a socket or TLS error raised after the connection is
          // up through unconverted; Dio wraps it as DioExceptionType.unknown.
          'a connection that drops after it was set up': (
            DioExceptionType.unknown,
            (_) => const SocketException('Connection reset by peer'),
          ),
          'a failed TLS handshake': (
            DioExceptionType.unknown,
            (_) => const HandshakeException(
              'Connection terminated during handshake',
            ),
          ),
        };
    for (final MapEntry(key: name, value: (type, fail)) in failures.entries) {
      test(name, () async {
        await clientFor(_Unreachable(fail));

        await expectLater(
          MessagesService(client).getHeaders(),
          throwsA(_connectionError(type)),
        );
      });
    }

    // The login chain a service call starts: from a 401 on a POST (#8), and
    // from a GET redirected to /login.
    final startsLogin = <String, Future<Object?> Function(SmartschoolClient)>{
      'MessagesService.getHeaders() (401)': (c) =>
          MessagesService(c).getHeaders(),
      'IntradeskService.getRootListing() (redirect)': (c) =>
          IntradeskService(c).getRootListing(),
    };
    for (final MapEntry(key: name, value: call) in startsLogin.entries) {
      test(
        'the network failing halfway through the login chain: $name',
        () async {
          final server = await clientFor(_DropsOnLoginPost());

          await expectLater(
            call(client),
            throwsA(_connectionError(DioExceptionType.connectionError)),
          );
          expect(server.log, contains('POST /login'), reason: 'a login ran');
        },
      );
    }

    test('an on-clause for the connection error matches around a service '
        'call; one for the authentication error does not', () async {
      await clientFor(_Unreachable(_hostNotFound));

      Object? caught;
      try {
        try {
          await PresenceService(client).getConfig();
        } on SmartschoolAuthenticationError {
          fail('a network failure is not an authentication failure');
        }
      } on SmartschoolConnectionError catch (e) {
        caught = e;
      }

      expect(caught, isA<SmartschoolConnectionError>());
    });

    test('ensureAuthenticated() reports it the same way', () async {
      await clientFor(_Unreachable(_hostNotFound));

      Object? fromService;
      try {
        await IntradeskService(client).getRootListing();
      } on SmartschoolConnectionError catch (e) {
        fromService = e;
      }
      expect(fromService, isA<SmartschoolConnectionError>());

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(
          _connectionError(DioExceptionType.connectionError).having(
            (e) => e.message,
            'message',
            (fromService! as SmartschoolConnectionError).message,
          ),
        ),
      );
    });

    test('a DioException that is not a network failure is left '
        'alone', () async {
      // Control: only an unreachable Smartschool becomes a connection error.
      await clientFor(
        _Unreachable((_) => const FormatException('not a network problem')),
      );

      await expectLater(
        MessagesService(client).getHeaders(),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.unknown)
              .having((e) => e.error, 'error', isA<FormatException>()),
        ),
      );
    });

    test('a request made on client.dio directly still gets the '
        'DioException', () async {
      await clientFor(_Unreachable(_hostNotFound));

      await expectLater(
        client.dio.get<String>('/'),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
    });
  });
}
