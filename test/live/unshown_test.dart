// Tests for support/unshown.dart (#215): the checks of the live suite that
// show no value when they fail. A failure is a TestFailure, whose message is
// what a run prints; it must hold the reason, and no value compared.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'package:test/test.dart';

import '../support/no_network.dart';
import 'support/unshown.dart';

/// Values that stand for names of the live Smartschool.
const _name = 'Fakename Jan';
const _otherName = 'Othername Piet';

/// The message of the TestFailure that [check] fails with.
String _failureOf(void Function() check) {
  try {
    check();
  } on TestFailure catch (failure) {
    return failure.message ?? '';
  }
  fail('the check did not fail');
}

void main() {
  forbidRealNetwork();

  test('a matcher cannot hide the actual value: expect shows it, whatever '
      'the description (why these checks match a boolean)', () {
    // The matcher of planner_calendar_live_test.dart before #215.
    final message = _failureOf(
      () => expect(
        _name,
        predicate<String>(
          (actual) => actual == _otherName,
          'the same name as the element gives (not shown)',
        ),
      ),
    );

    expect(message, contains('Actual: '));
    expect(message, contains(_name));
  });

  group('expectSameUnshown', () {
    test('holds for the same value', () {
      expectSameUnshown(_name, _name, reason: 'not the same name');
      expectSameUnshown(null, null, reason: 'not the same name');
    });

    test('fails with the reason, and shows neither value', () {
      final message = _failureOf(
        () => expectSameUnshown(
          _name,
          _otherName,
          reason: 'not the same name as the element gives',
        ),
      );

      expect(
        message,
        contains('not the same name as the element gives (not shown)'),
      );
      expect(message, isNot(contains(_name)));
      expect(message, isNot(contains(_otherName)));
    });

    test('fails for a value against null, and shows it not', () {
      final message = _failureOf(
        () => expectSameUnshown(_name, null, reason: 'a name'),
      );

      expect(message, isNot(contains(_name)));
    });
  });

  group('expectSameFieldsUnshown', () {
    test('holds for the same fields', () {
      expectSameFieldsUnshown(
        {'id': 'a', 'name': _name, 'visible': true},
        {'id': 'a', 'name': _name, 'visible': true},
        reason: 'not the same entry',
      );
    });

    test('fails with the reason and the keys that differ, and shows no '
        'value', () {
      final message = _failureOf(
        () => expectSameFieldsUnshown(
          {'id': 'a', 'name': _name, 'color': 'fakecolour-a', 'visible': true},
          {
            'id': 'a',
            'name': _otherName,
            'color': 'fakecolour-b',
            'visible': true,
          },
          reason: 'getFolder of the test folder',
        ),
      );

      expect(message, contains('getFolder of the test folder: the fields'));
      expect(message, contains("'name'"));
      expect(message, contains("'color'"));
      expect(message, isNot(contains("'id'")));
      expect(message, isNot(contains("'visible'")));
      for (final value in [_name, _otherName, 'fakecolour-a', 'fakecolour-b']) {
        expect(message, isNot(contains(value)));
      }
    });

    test('takes a key that one of them lacks for a field that differs, '
        'also when the other holds null', () {
      final message = _failureOf(
        () => expectSameFieldsUnshown(
          {'id': 'a', 'name': _name},
          {'id': 'a', 'parent': null},
          reason: 'not the same entry',
        ),
      );

      expect(message, contains("'name'"));
      expect(message, contains("'parent'"));
      expect(message, isNot(contains(_name)));
    });
  });
}
