// Regression tests for issue #1: a *successful* 2FA response was misdetected
// as a failure because `_driveAuthChain` classified success by inspecting the
// request URL. `do2fa()` POSTs to `/2fa/api/v1/google-authenticator`, whose
// path contains `/2fa/`, so a correct code (HTTP 200, `{"success":true}`) was
// wrongly treated as "still stuck on the 2FA page" and threw.
//
// These tests drive the real auth interceptor end-to-end against a fake
// `HttpClientAdapter` so the fix is exercised through the same code path the
// library uses in production.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

/// Credentials with a valid base32 TOTP secret so `do2fa()` can generate a code.
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

/// A fake adapter that returns canned responses based on the request path,
/// simulating the Smartschool 2FA endpoints.
class _FakeAdapter implements HttpClientAdapter {
  /// Body returned by the `/2fa/api/v1/google-authenticator` POST.
  final String twoFaResultBody;

  /// True once the protected page has already redirected to `/2fa`, so the
  /// post-auth retry lands on a clean page instead of looping back.
  bool _authenticated = false;

  _FakeAdapter({required this.twoFaResultBody});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;

    if (path == '/2fa/api/v1/config') {
      return _json(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
      );
    }

    if (path == '/2fa/api/v1/google-authenticator') {
      _authenticated = true;
      return _json(twoFaResultBody);
    }

    // The protected page. On the first hit it redirects to /2fa (which triggers
    // the auth flow); after authentication the retry gets a plain page.
    if (!_authenticated) {
      return ResponseBody.fromString(
          '<html><body>2fa</body></html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        )
        ..redirects = [
          RedirectRecord(
            302,
            'GET',
            Uri.parse('https://school.smartschool.be/2fa'),
          ),
        ];
    }

    return ResponseBody.fromString(
      '<html><body>home</body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

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
  group('_SmartschoolAuthInterceptor 2FA handling', () {
    test('accepted 2FA code does NOT throw (issue #1 regression)', () async {
      final client = await SmartschoolClient.create(_TwoFaCredentials());
      client.dio.httpClientAdapter = _FakeAdapter(
        // Exactly what Smartschool returns for a correct code.
        twoFaResultBody: '{"success":true,"redirectTo":"/"}',
      );

      // Before the fix this threw "2FA verification failed" because the
      // /2fa/api/v1/google-authenticator URL "contains '/2fa/'".
      await expectLater(client.getRaw('/index'), completes);

      await client.dispose();
    });

    test('rejected 2FA code throws SmartschoolAuthenticationError', () async {
      final client = await SmartschoolClient.create(_TwoFaCredentials());
      client.dio.httpClientAdapter = _FakeAdapter(
        twoFaResultBody:
            '{"success":false,"error":"authentication.google2fa_not_valid"}',
      );

      // The interceptor rejects by wrapping the auth error in a DioException.
      await expectLater(
        client.getRaw('/index'),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<SmartschoolAuthenticationError>().having(
              (e) => e.message,
              'message',
              contains('2FA verification failed'),
            ),
          ),
        ),
      );

      await client.dispose();
    });
  });

  group('SmartschoolClient.parse2faSuccess', () {
    late SmartschoolClient client;

    setUp(() async {
      client = await SmartschoolClient.create(_TwoFaCredentials());
    });

    tearDown(() async {
      await client.dispose();
    });

    Response<String> resp(String? body) => Response<String>(
      requestOptions: RequestOptions(path: '/2fa'),
      data: body,
    );

    test('returns true for {"success":true}', () {
      expect(
        client.parse2faSuccess(resp('{"success":true,"redirectTo":"/"}')),
        isTrue,
      );
    });

    test('returns false for {"success":false}', () {
      expect(
        client.parse2faSuccess(
          resp(
            '{"success":false,"error":"authentication.google2fa_not_valid"}',
          ),
        ),
        isFalse,
      );
    });

    test('returns null for an HTML body', () {
      expect(
        client.parse2faSuccess(resp('<html><body>2fa</body></html>')),
        isNull,
      );
    });

    test('returns null for an empty or missing body', () {
      expect(client.parse2faSuccess(resp('')), isNull);
      expect(client.parse2faSuccess(resp(null)), isNull);
    });
  });
}
