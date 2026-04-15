import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('SmartschoolParsingError', () {
    test('toString returns message', () {
      final err = SmartschoolParsingError('fail');
      expect(err.toString(), contains('fail'));
    });
  });
}
