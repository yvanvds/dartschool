import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

void main() {
  forbidRealNetwork();

  group('SmartschoolClient', () {
    test('throws if credentials are missing', () async {
      expect(
        () => SmartschoolClient.create(
          AppCredentials(username: '', password: '', mainUrl: ''),
          cacheDir: tempCacheDir(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
