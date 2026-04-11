import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

void main() {
  group('Credentials', () {
    test('AppCredentials exposes provided values', () {
      const username = 'john.doe';
      const password = 'secret';
      const mainUrl = 'school.smartschool.be';
      const mfa = '2010-05-15';

      final credentials = AppCredentials(
        username: username,
        password: password,
        mainUrl: mainUrl,
        mfa: mfa,
      );

      expect(credentials.username, username);
      expect(credentials.password, password);
      expect(credentials.mainUrl, mainUrl);
      expect(credentials.mfa, mfa);
    });
  });
}
