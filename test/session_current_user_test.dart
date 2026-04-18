import 'package:flutter_smartschool/src/models/user_models.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolUser', () {
    test('can be constructed with all fields', () {
      const user = SmartschoolUser(
        id: 146,
        displayName: 'Yvan Vander Sanden',
        avatarUrl:
            'https://userpicture20.smartschool.be/User/Userimage/hashimage/hash/4069_7b97d0dc-1f67-41ae-924c-0a5c4c420e3b/plain/1/res/128',
      );
      expect(user.id, 146);
      expect(user.displayName, 'Yvan Vander Sanden');
      expect(user.avatarUrl, contains('4069_7b97d0dc'));
    });

    test('avatarUrl is nullable', () {
      const user = SmartschoolUser(id: 1, displayName: 'Test User');
      expect(user.avatarUrl, isNull);
    });
  });

  group('authenticatedUser.id parsing', () {
    // The server embeds the user's ID in the format "{ssID}_{userId}_{coaccountIdx}".
    // getCurrentUser() splits on '_' and takes index 1 as the integer user ID.
    int? parseUserId(String idStr) {
      final parts = idStr.split('_');
      return parts.length >= 2 ? int.tryParse(parts[1]) : null;
    }

    test('parses userId from normal identifier', () {
      expect(parseUserId('4069_146_0'), 146);
    });

    test('parses userId from co-account identifier', () {
      expect(parseUserId('49_10880_2'), 10880);
    });

    test('returns null for malformed identifier', () {
      expect(parseUserId('invalid'), isNull);
      expect(parseUserId(''), isNull);
    });
  });
}
