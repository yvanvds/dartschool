import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
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

void main() {
  forbidRealNetwork();

  group('SmartschoolClient', () {
    test('dio getter returns Dio instance', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(client.dio, isNotNull);
    });
    test('notificationCounterUpdates is a broadcast stream', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      expect(client.notificationCounterUpdates, isA<Stream>());
    });
    test('create refuses a negative loginCooldown (#32)', () async {
      await expectLater(
        SmartschoolClient.create(
          DummyCredentials(),
          cacheDir: tempCacheDir(),
          loginCooldown: const Duration(seconds: -1),
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'loginCooldown'),
        ),
      );
    });
  });
}
