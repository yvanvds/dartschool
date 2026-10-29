// Checks of the live suite that show no value of the live Smartschool when
// they fail (#215): no name of a person, a class, a room or a folder.
//
// A matcher cannot keep a value out of the output: `expect` writes the
// actual value of every failed match (`Actual: ...`, package:matcher's
// formatFailure), whatever the matcher's description and its
// describeMismatch. So a `predicate` described "(not shown)" still showed
// the name it compared. These checks compare in the test and match what
// they found: a boolean, or the keys of the fields that differ.
// Offline-tested in unshown_test.dart.
import 'package:test/test.dart';

/// Expects [actual] to be [expected] (`==`), and shows neither when it
/// fails: only [reason], which must hold no value of either.
void expectSameUnshown(
  Object? actual,
  Object? expected, {
  required String reason,
}) {
  expect(actual == expected, isTrue, reason: '$reason (not shown)');
}

/// Expects [actual] to have the fields of [expected]: the same keys, with
/// the same values (`==`). When it fails, it shows [reason] and the keys
/// that differ, never a value: the keys must be the test's own names of
/// the fields, not values of an answer.
void expectSameFieldsUnshown(
  Map<String, Object?> actual,
  Map<String, Object?> expected, {
  required String reason,
}) {
  final differing = [
    for (final key in {...expected.keys, ...actual.keys})
      if (actual.containsKey(key) != expected.containsKey(key) ||
          actual[key] != expected[key])
        key,
  ];
  expect(
    differing,
    isEmpty,
    reason: '$reason: the fields that differ (their values not shown)',
  );
}
