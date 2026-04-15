import 'package:flutter_smartschool/src/dev/dev_inspector.dart';
import 'package:test/test.dart';

void main() {
  group('DevInspector', () {
    test('parseQueryString returns correct map', () {
      final result = DevInspector.parseQueryString('a=1&b=2&c=');
      expect(result, {'a': '1', 'b': '2', 'c': ''});
    });

    test('parseQueryString handles empty and no equals', () {
      expect(DevInspector.parseQueryString(''), {});
      expect(DevInspector.parseQueryString('foo'), {'foo': ''});
    });
  });
}
