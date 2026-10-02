import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:otp/otp.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

void main() {
  forbidRealNetwork();

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

  group('Credentials.normalizeTotpSecret (#79)', () {
    const secret = 'JBSWY3DPEHPK3PXP';

    final copies = <String, String>{
      'as it is': secret,
      'in groups, as an authenticator setup screen shows it':
          'JBSW Y3DP EHPK 3PXP',
      'with leading and trailing white space': '  $secret\n',
      'with tabs, line breaks and non-breaking spaces':
          'JBSW\tY3DP\nEHPK\u00a03PXP',
      'with hyphens': 'JBSW-Y3DP-EHPK-3PXP',
      'in lower case': 'jbsw y3dp ehpk 3pxp',
      'with = padding': '$secret====',
    };
    for (final MapEntry(key: copy, value: key) in copies.entries) {
      test('a key $copy is the Base32 secret', () {
        expect(Credentials.normalizeTotpSecret(key), secret);
      });
    }

    test('the normalised key generates the codes of the key itself', () {
      // What do2fa does with it: the code of a key copied in groups is the
      // code an authenticator app set up with the key shows.
      final time = DateTime(2026, 10, 2, 12).millisecondsSinceEpoch;
      String code(String key) => OTP.generateTOTPCodeString(
        key,
        time,
        length: 6,
        interval: 30,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
      expect(
        code(Credentials.normalizeTotpSecret('jbsw-y3dp ehpk-3pxp=')),
        code(secret),
      );
    });

    final notKeys = <String, String>{
      'the 6-digit code of the authenticator app': '123456',
      'a code of the digits 2-7 only, which are Base32': '234567',
      'a date': '2010-05-15',
      'a key with a character that is not Base32 (1)': 'JBSW Y3DP EHPK 3PX1',
      'a key with a letter that upper-cases to Base32 ones (sharp s)':
          'JBSWY3DPEHPK3PX\u00df',
      'a key with other punctuation': 'JBSW.Y3DP.EHPK.3PXP',
      'a key with = padding in the middle': 'JBSW==Y3DPEHPK3PXP',
      'only padding': '====',
      'only white space and hyphens': ' - ',
      'empty': '',
    };
    for (final MapEntry(key: what, value: key) in notKeys.entries) {
      test('$what is not a TOTP secret', () {
        expect(
          () => Credentials.normalizeTotpSecret(key),
          throwsA(
            isA<SmartschoolInvalidTotpSecretError>().having(
              (e) => e.message,
              'message',
              contains('not the 6-digit code'),
            ),
          ),
        );
      });
    }

    test('the error does not hold the secret', () {
      const typo = 'JBSW Y3DP EHPK 3PX1';
      try {
        Credentials.normalizeTotpSecret(typo);
        fail('no error');
      } on SmartschoolInvalidTotpSecretError catch (e) {
        expect(e.toString(), isNot(contains('JBSW')));
        expect(e.toString(), isNot(contains('3PX1')));
      }
    });
  });
}
