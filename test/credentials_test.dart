import 'package:flutter_smartschool/src/credentials.dart';
import 'package:test/test.dart';

void main() {
  group('AppCredentials', () {
    test('throws if username is empty', () {
      expect(
        () => AppCredentials(username: '', password: 'x', mainUrl: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });
    test('throws if password is empty', () {
      expect(
        () => AppCredentials(username: 'x', password: '', mainUrl: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });
    test('throws if mainUrl is empty', () {
      expect(
        () => AppCredentials(username: 'x', password: 'x', mainUrl: ''),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
