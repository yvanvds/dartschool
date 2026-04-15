import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:test/test.dart';

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
    test('dio getter returns Dio instance', () async {
      final client = await SmartschoolClient.create(DummyCredentials());
      expect(client.dio, isNotNull);
    });
    test('notificationCounterUpdates is a broadcast stream', () async {
      final client = await SmartschoolClient.create(DummyCredentials());
      expect(client.notificationCounterUpdates, isA<Stream>());
    });
  });
}
