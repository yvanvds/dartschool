import 'package:flutter_smartschool/src/services/presence_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

class _FakeSmartschoolClient implements SmartschoolClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PresenceService', () {
    test('can be instantiated', () {
      final fakeClient = _FakeSmartschoolClient();
      final service = PresenceService(fakeClient);
      expect(service, isA<PresenceService>());
    });
  });
}
