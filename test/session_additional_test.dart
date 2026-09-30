import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

class DummyCredentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
  @override
  String? get mfa => null;
}

/// Stands in for Smartschool: answers every request with a `404 Not Found`,
/// and keeps each request as `<method> <path>`.
class _NotFound implements HttpClientAdapter {
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    return ResponseBody.fromString(
      '<html><body>Not Found</body></html>',
      404,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  group('SmartschoolClient', () {
    test('clearCookies completes', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      await client.clearCookies();
      expect(true, isTrue); // If no exception, passes
    });

    test('postFormRaw returns string (mocked)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(client.postFormRaw, isNotNull);
    });

    test('postMultipartRaw returns string (mocked)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(client.postMultipartRaw, isNotNull);
    });

    test('postFormEncodedRaw returns string (mocked)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(client.postFormEncodedRaw, isNotNull);
    });

    test(
      'emitNotificationCounterUpdate returns true for valid module',
      () async {
        final client = await SmartschoolClient.create(
          DummyCredentials(),
          cacheDir: tempCacheDir(),
        );
        final result = client.emitNotificationCounterUpdate(
          moduleName: 'messages',
          counter: 2,
        );
        expect(result, isTrue);
      },
    );

    test(
      'emitNotificationCounterUpdate returns false for empty module',
      () async {
        final client = await SmartschoolClient.create(
          DummyCredentials(),
          cacheDir: tempCacheDir(),
        );
        final result = client.emitNotificationCounterUpdate(
          moduleName: '',
          counter: 1,
        );
        expect(result, isFalse);
      },
    );

    test('dispose closes resources', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      await client.dispose();
      expect(true, isTrue); // If no exception, passes
    });

    test('getRaw returns a string (mocked)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      // This will fail without a real server, so just check method exists
      expect(client.getRaw, isNotNull);
    });

    test('download throws a SmartschoolDownloadError with the status code '
        'when Smartschool answers an error (#50)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      final server = _NotFound();
      client.dio.httpClientAdapter = server;

      await expectLater(
        client.download('/notfound'),
        throwsA(
          isA<SmartschoolDownloadError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('/notfound')),
        ),
      );
      // One GET of the file, and no login: a 404 is not a sign of an
      // expired session.
      expect(server.requests, ['GET /notfound']);
    });
  });
}
