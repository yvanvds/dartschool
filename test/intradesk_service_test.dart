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

    test('getFolderListing throws on empty folderId', () async {
      final fakeClient = _FakeSmartschoolClient();
      final service = IntradeskService(fakeClient);
      expect(() => service.getFolderListing(''), throwsA(isA<ArgumentError>()));
    });

    test('downloadFile throws on empty fileId', () async {
      final fakeClient = _FakeSmartschoolClient();
      final service = IntradeskService(fakeClient);
      expect(() => service.downloadFile(''), throwsA(isA<ArgumentError>()));
    });

    test('asMap returns map for valid input', () {
      final map = {'a': 1};
      final result = IntradeskService.asMap(map);
      expect(result, equals(map));
    });

    test('asMap decodes valid JSON string', () {
      final jsonStr = '{"a": 1}';
      final result = IntradeskService.asMap(jsonStr);
      expect(result, containsPair('a', 1));
    });

    test('asMap throws on invalid input', () {
      expect(
        () => IntradeskService.asMap(123),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
