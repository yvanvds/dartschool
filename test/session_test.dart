import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolClient', () {
    test('throws if credentials are missing', () async {
      expect(
        () => SmartschoolClient.create(
          AppCredentials(username: '', password: '', mainUrl: ''),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
