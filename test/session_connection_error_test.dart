// Tests for issue #10: `ensureAuthenticated()` reports a network failure
// (Smartschool unreachable) as a `SmartschoolConnectionError`, not as a
// `SmartschoolAuthenticationError`, so callers can tell "check your network"
// apart from "check your password".
//
// The fakes stand in for Dio's `IOHttpClientAdapter` and fail the way it does:
// DNS failures and refused connections as `DioExceptionType.connectionError`
// (carrying the `SocketException`), timeouts as the matching timeout type, and
// a `SocketException` raised after the connection is up as a raw error that
// Dio wraps as `DioExceptionType.unknown`.
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
  String? get mfa => null;
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

/// Sends the first GET to the login page, then drops the connection on the
/// login POST: the network fails halfway through the login chain.
class _DropsOnLoginPost implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection reset by peer',
        error: const SocketException('Connection reset by peer'),
      );
    }
    final response = ResponseBody.fromString(
      '<html><body><form name="login_form" method="post">'
      '<input type="text" name="login_form[_username]" />'
      '<input type="password" name="login_form[_password]" />'
      '</form></body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
    response.redirects = [
      RedirectRecord(302, 'GET', Uri.parse('https://$_host/login')),
    ];
    return response;
  }

  @override
  void close({bool force = false}) {}
}

const _hostLookupFailure = SocketException(
  "Failed host lookup: '$_host'",
  osError: OSError('No such host is known.', 11001),
);

/// A [SmartschoolConnectionError] whose `cause` is the [DioException] of
/// [type] that the request failed with.
TypeMatcher<SmartschoolConnectionError> _connectionError(
  DioExceptionType type,
) => isA<SmartschoolConnectionError>()
    .having((e) => e, 'error', isNot(isA<SmartschoolAuthenticationError>()))
    .having(
      (e) => e.cause,
      'cause',
      isA<DioException>().having((d) => d.type, 'type', type),
    )
    .having((e) => e.message, 'message', contains(_host));

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;

  Future<void> clientFor(HttpClientAdapter server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_network_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('ensureAuthenticated reports an unreachable Smartschool as a '
      'SmartschoolConnectionError (#10)', () {
    test('a host that does not resolve', () async {
      await clientFor(
        _Unreachable(
          (options) => DioException.connectionError(
            requestOptions: options,
            reason: _hostLookupFailure.message,
            error: _hostLookupFailure,
          ),
        ),
      );

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(
          _connectionError(
            DioExceptionType.connectionError,
          ).having((e) => e.message, 'message', contains('Failed host lookup')),
        ),
      );
    });

    final timeouts = <DioExceptionType, DioException Function(RequestOptions)>{
      DioExceptionType.connectionTimeout: (options) =>
          DioException.connectionTimeout(
            timeout: const Duration(seconds: 5),
            requestOptions: options,
          ),
      DioExceptionType.sendTimeout: (options) => DioException.sendTimeout(
        timeout: const Duration(seconds: 5),
        requestOptions: options,
      ),
      DioExceptionType.receiveTimeout: (options) => DioException.receiveTimeout(
        timeout: const Duration(seconds: 5),
        requestOptions: options,
      ),
    };
    for (final MapEntry(key: type, value: fail) in timeouts.entries) {
      test('a ${type.name}', () async {
        await clientFor(_Unreachable(fail));

        await expectLater(
          client.ensureAuthenticated(),
          throwsA(_connectionError(type)),
        );
      });
    }

    test('a connection that drops after it was set up', () async {
      // The adapter lets a SocketException raised mid-request through
      // unconverted; Dio wraps it as DioExceptionType.unknown.
      await clientFor(
        _Unreachable((_) => const SocketException('Connection reset by peer')),
      );

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(_connectionError(DioExceptionType.unknown)),
      );
    });

    test('the network failing halfway through the login chain', () async {
      await clientFor(_DropsOnLoginPost());

      await expectLater(
        client.ensureAuthenticated(),
        throwsA(_connectionError(DioExceptionType.connectionError)),
      );
    });

    test(
      'a failure that is not a network problem is not reported as one',
      () async {
        // Control: only an unreachable Smartschool becomes a connection error.
        await clientFor(
          _Unreachable((_) => const FormatException('not a network problem')),
        );

        await expectLater(
          client.ensureAuthenticated(),
          throwsA(
            isA<SmartschoolException>().having(
              (e) => e,
              'error',
              isNot(isA<SmartschoolConnectionError>()),
            ),
          ),
        );
      },
    );
  });
}
