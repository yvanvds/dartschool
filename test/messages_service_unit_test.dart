import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/models/notification_models.dart';
import 'package:test/test.dart';

class _FakeSmartschoolClient implements SmartschoolClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MessagesService', () {
    test('can be instantiated', () {
      // Use a minimal fake SmartschoolClient
      final fakeClient = _FakeSmartschoolClient();
      final service = MessagesService(fakeClient);
      expect(service, isA<MessagesService>());
    });
    test('handleNotificationCounterUpdate emits for messages', () async {
      final fakeClient = _FakeSmartschoolClient();
      final service = MessagesService(fakeClient);
      final update = NotificationCounterUpdate(
        moduleName: 'Messages',
        counter: 2,
        isNew: true,
        source: 'test',
        timestamp: DateTime.now(),
      );
      final future = expectLater(
        service.messageCounterUpdates,
        emits(predicate<MessageCounterUpdate>((e) => e.counter == 2)),
      );
      final result = service.handleNotificationCounterUpdate(update);
      expect(result, isTrue);
      await future;
    });
    test('handleNotificationCounterUpdate ignores non-messages', () {
      final fakeClient = _FakeSmartschoolClient();
      final service = MessagesService(fakeClient);
      final result = service.handleNotificationCounterUpdate(
        NotificationCounterUpdate(
          moduleName: 'Other',
          counter: 1,
          isNew: false,
          source: 'test',
          timestamp: DateTime.now(),
        ),
      );
      expect(result, isFalse);
    });
  });
}
