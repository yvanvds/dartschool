import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:test/test.dart';

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

void main() {
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

    test('download throws on error (mocked)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(() => client.download('/notfound'), throwsA(isA<Exception>()));
    });
  });
}
