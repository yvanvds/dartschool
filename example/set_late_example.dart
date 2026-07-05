import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: mark a pupil **Te laat** ("late") for a half-day, then restore the
/// original status.
///
/// The Presence module is internal to Smartschool and speaks the internal
/// `userID` (not the public API's AccountID/UID). You supply the pupil's
/// internal `userId` and the class `groupID`.
///
/// This only works when the signed-in account has **Presence-handling access**
/// for the class.
///
/// Run with:
///   dart run example/set_late_example.dart
Future<void> main() async {
  // The internal Presence userID and Presence class groupID of the pupil.
  const userId = 11110; // e.g. test pupil "x test"
  const classGroupId = 298; // e.g. class 1A
  final date = DateTime(2026, 6, 1);
  const part = DayPart.morning;

  final client = await SmartschoolClient.create(PathCredentials());
  await client.ensureAuthenticated();
  print('✓ Authenticated.\n');

  final presence = PresenceService(client);

  // Read the current half-day status so we can restore it afterwards.
  final config = await presence.getConfig();
  final pupils = await presence.getClassPupils(
    classGroupId: classGroupId,
    date: date,
    schoolyearRefDate: config.schoolyearRefDate,
  );
  final pupil = pupils.where((p) => p.userId == userId).firstOrNull;
  if (pupil == null) {
    print(
      'Pupil $userId not found in class $classGroupId on '
      '${PresenceService.formatDate(date)}.',
    );
    await client.dispose();
    return;
  }
  final before = pupil.halfDayFor(part, date: PresenceService.formatDate(date));
  print('Before: ${before ?? '(no half-day record)'}');

  // Mark the pupil late for the morning.
  await presence.setLate(
    userId: userId,
    classGroupId: classGroupId,
    date: date,
    part: part,
    motivation: 'Overslept',
  );
  print('✓ Marked "Te laat".');

  // Restore to present.
  await presence.setPresent(
    userId: userId,
    classGroupId: classGroupId,
    date: date,
    part: part,
  );
  print('✓ Restored to "Aanwezig".');

  await client.dispose();
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
