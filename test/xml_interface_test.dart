import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

void main() {
  forbidRealNetwork();

  group('XmlInterface', () {
    test('parseResponse returns empty for empty xml', () {
      final result = XmlInterface.parseResponse('', './/foo');
      expect(result, isEmpty);
    });
  });
}
