import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolParsingError', () {
    test('toString returns message', () {
      final err = SmartschoolParsingError('fail');
      expect(err.toString(), contains('fail'));
    });
  });

  group('login failure types (#11)', () {
    // Default instances, paired with the wording the untyped error used to
    // carry: callers that still match on the message keep working.
    final legacyWording = <SmartschoolAuthenticationError, String>{
      const SmartschoolInvalidCredentialsError(): 'Login failed.',
      const SmartschoolTwoFactorRequiredError(): '2FA requires a TOTP secret',
      const SmartschoolTwoFactorRejectedError(): '2FA verification failed.',
      const SmartschoolUnsupportedTwoFactorMethodError([]):
          'Only googleAuthenticator 2FA is supported',
      const SmartschoolAccountVerificationRequiredError():
          'account-verification requires mfa',
      const SmartschoolAccountVerificationRejectedError():
          'Account verification is still pending.',
    };

    for (final MapEntry(key: error, value: wording) in legacyWording.entries) {
      test('${error.runtimeType} is a SmartschoolAuthenticationError', () {
        // A catch of the base class (or of SmartschoolException) still
        // catches the new type.
        expect(error, isA<SmartschoolAuthenticationError>());
        expect(error, isA<SmartschoolException>());
      });

      test('${error.runtimeType} keeps the legacy message by default', () {
        expect(error.message, startsWith(wording));
      });
    }

    test('a custom message replaces the default', () {
      const error = SmartschoolAccountVerificationRequiredError('custom');
      expect(error.message, 'custom');
      expect(
        error.toString(),
        'SmartschoolAccountVerificationRequiredError: custom',
      );
    });

    test('SmartschoolUnsupportedTwoFactorMethodError lists the methods the '
        'account offers', () {
      const error = SmartschoolUnsupportedTwoFactorMethodError(['sms', 'mail']);
      expect(error.availableMethods, ['sms', 'mail']);
      expect(error.toString(), endsWith('(account offers: sms, mail)'));
    });

    test('SmartschoolUnsupportedTwoFactorMethodError without methods prints '
        'only the message', () {
      const error = SmartschoolUnsupportedTwoFactorMethodError([]);
      expect(
        error.toString(),
        'SmartschoolUnsupportedTwoFactorMethodError: '
        'Only googleAuthenticator 2FA is supported',
      );
    });
  });

  group('SmartschoolConnectionError (#10)', () {
    test('is a SmartschoolException, not a SmartschoolAuthenticationError', () {
      // A network problem must not be caught as a failed login.
      const error = SmartschoolConnectionError('unreachable');
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
    });

    test('carries its cause', () {
      final cause = Exception('socket');
      final error = SmartschoolConnectionError('unreachable', cause: cause);
      expect(error.cause, same(cause));
      expect(error.toString(), 'SmartschoolConnectionError: unreachable');
    });
  });

  group('SmartschoolSessionExpiredError (#5)', () {
    test('is a SmartschoolAuthenticationError, not a '
        'SmartschoolPresenceError', () {
      // "Sign in again" and "give up" must not share a type.
      const error = SmartschoolSessionExpiredError();
      expect(error, isA<SmartschoolAuthenticationError>());
      expect(error, isNot(isA<SmartschoolPresenceError>()));
      expect(
        error.toString(),
        'SmartschoolSessionExpiredError: '
        'Smartschool did not accept the session.',
      );
    });
  });
}
