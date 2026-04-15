import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

class _FakeSmartschoolClient implements SmartschoolClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('IntradeskService', () {
    test('can be instantiated', () {
      final fakeClient = _FakeSmartschoolClient();
      final service = IntradeskService(fakeClient);
      expect(service, isA<IntradeskService>());
    });
  });
}
