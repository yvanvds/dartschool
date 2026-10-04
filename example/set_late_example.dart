import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: mark a pupil **Te laat** ("late") for a half-day, unless the
/// half-day holds another status than nothing or "Aanwezig" (such as an
/// absence the secretariat recorded), then restore "Aanwezig".
///
/// The Presence module is internal to Smartschool and speaks the internal
/// `userID` (not the public API's AccountID/UID). You supply the pupil's
/// internal `userId` and the class `groupID`.
///
/// This only works when the signed-in account may set the half-days of the
/// class: `userCanConfirm` in the module config (`getConfig`), as for an
/// absence administrator. `userCanRecord` is not that right (#121).
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

  // Check the right to set the half-days of the class first (#121):
  // setLate would refuse it with a SmartschoolPresenceNoConfirmRightError.
  final config = await presence.getConfig();
  final classRef = config.classForGroup(classGroupId);
  if (classRef == null || !classRef.userCanConfirm) {
    print(
      'This account may not set the half-days of class $classGroupId '
      '(${classRef == null ? 'not listed' : 'userCanConfirm is false'}).',
    );
    await client.dispose();
    return;
  }

  // Read the current half-day status so we can restore it afterwards.
  final pupils = await presence.getClassPupils(
    classGroupId: classGroupId,
    date: date,
    schoolyearRefDate: config.schoolyearRefDate,
  );
  final pupil = pupils.where((p) => p.userId == userId).firstOrNull;
  if (pupil == null) {
    // When the Presence module lists no pupils (a day after today, a class
    // without pupils or a class ID it does not know), it says why (#104).
    final reason = pupils.isEmpty ? pupils.errorMessage : null;
    print(
      'Pupil $userId not found in class $classGroupId on '
      '${PresenceService.formatDate(date)}'
      '${reason == null ? '' : ' (the Presence module: $reason)'}.',
    );
    await client.dispose();
    return;
  }
  final before = pupil.halfDayFor(part, date: PresenceService.formatDate(date));
  print('Before: ${before ?? '(no half-day record)'}');

  // Mark the pupil late for the morning, but leave any other status alone:
  // the service checks the half-day it reads right before the save (#105).
  final PresenceSavedHalfDay? late;
  try {
    late = await presence.setLate(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      motivation: 'Overslept',
      onlyReplacing: {
        PresenceService.nothingRecorded,
        PresenceService.presentCodeName,
      },
    );
  } on SmartschoolPresenceChangeRefusedError catch (e) {
    print('Left alone: ${e.message}');
    await client.dispose();
    return;
  } on SmartschoolPresencePupilNotFoundError catch (e) {
    // The class, as read right before the save, no longer lists the pupil
    // on that day (#116): nothing was sent.
    print('Not listed: ${e.message}');
    await client.dispose();
    return;
  }
  // The half-day as stored, from the save's answer (null when the answer
  // does not hold it).
  print('✓ Marked "Te laat": ${late ?? '(not in the answer)'}');

  // Restore to present, only while it still holds the "Te laat" set above.
  final restored = await presence.setPresent(
    userId: userId,
    classGroupId: classGroupId,
    date: date,
    part: part,
    onlyReplacing: {PresenceService.lateCodeName},
  );
  print('✓ Restored to "Aanwezig": ${restored ?? '(not in the answer)'}');

  await client.dispose();
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
