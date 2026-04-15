import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:test/test.dart';

void main() {
  group('XmlInterface', () {
    test('parseResponse returns empty for empty xml', () {
      final result = XmlInterface.parseResponse('', './/foo');
      expect(result, isEmpty);
    });
  });
}
