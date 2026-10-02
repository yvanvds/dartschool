import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// The name of the test assignment: easy to find, and to remove by hand.
const _testName = '[dartschool test] planner assignment';

/// Example: add a test assignment to your own planner for the classes of one
/// of your lesson hours, read it back, rename it, and move it to the
/// planner's trash again (#89). It shows the hour and the assignment type and
/// asks for confirmation first.
///
/// WARNING: this changes the live planner of the account of
/// `credentials.yml`. **Pupils of the hour's classes see the assignment at
/// once**, from the moment it is created until it is in the trash: use an
/// hour far in the future, and only on purpose. The assignment stays in the
/// planner's trash for 30 days.
///
/// Run with:
///   dart run example/planner_assignment_example.dart YYYY-MM-DD HH:MM [TYPE]
///
/// The date and the start of a lesson hour of your own timetable, in the
/// local time of this machine, such as `2026-11-20 11:10`: the assignment is
/// due at the start of that hour, for its classes, course and room. TYPE is
/// the abbreviation or the name of one of the school's assignment types
/// (`KO` by default); one that matches none (such as `?`) prints the types
/// and changes nothing.
///
/// The flow:
///   1. Authenticate.
///   2. Read the own planner of that day and print the lesson hour (an empty
///      timetable slot or a lesson) that starts then; read the school's
///      assignment types and print the one to use.
///   3. Ask for confirmation (y/N; anything but "y" or "yes", or no answer,
///      changes nothing).
///   4. Add the `[dartschool test]` assignment
///      (`PlannerService.planAssignment`). The service checks the type
///      against the school's types first, and sends the create once.
///   5. Read it back (`getDetail`) and look for it in the calendar of its
///      first class.
///   6. Rename it (`renameElement`).
///   7. Move it to the planner's trash (`trashAssignment`), also when the
///      read or the rename failed; when the create was not confirmed, look
///      for it in the class calendar and trash what is found there.
///   8. Read it again: the planner answers `404`.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  final start = args.length == 2 || args.length == 3
      ? DateTime.tryParse('${args[0]}T${args[1]}:00')
      : null;
  if (start == null) {
    stderr.writeln(
      'Usage: dart run example/planner_assignment_example.dart YYYY-MM-DD '
      'HH:MM [TYPE]',
    );
    exitCode = 64;
    return;
  }
  final typeArg = args.length == 3 ? args[2].trim() : 'KO';

  print(
    'WARNING: this changes your live planner. Pupils see the test assignment '
    'while it exists.\n',
  );

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final planner = PlannerService(client);
    final me = await planner.ownCalendar();

    // ── 2. The lesson hour and the type ───────────────────────────────────

    final hour = await _hourAt(planner, me, start);
    if (hour == null) {
      print('No lesson hour of your own planner starts at $start.');
      exitCode = 1;
      return;
    }
    _printElement('Hour:  ', hour);
    if (hour.participantGroups.isEmpty || hour.courses.isEmpty) {
      print('The hour has no classes or no course to give the assignment.');
      exitCode = 1;
      return;
    }
    final type = await _type(planner, typeArg);
    if (type == null) {
      exitCode = 1;
      return;
    }
    print('Type:  ${type.name} (${type.abbreviation}, ${type.id})');

    // ── 3. Confirmation ───────────────────────────────────────────────────

    print(
      '\nChange: add "$_testName" (${type.abbreviation}) for '
      '${hour.participantGroups.map((g) => g.name).join(', ')}, due '
      '${hour.period.from}; pupils see it at once. Then rename it and move '
      'it to the planner\'s trash.',
    );
    stdout.write('\nChange your planner? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      print('Nothing changed.');
      return;
    }

    // ── 4. Create ─────────────────────────────────────────────────────────

    final PlannedElementDetail assignment;
    try {
      assignment = await planner.planAssignment(
        groupIds: [for (final group in hour.participantGroups) group.id],
        course: hour.courses.first,
        type: type,
        name: _testName,
        due: hour.period.from,
        until: hour.period.to,
        publicInfo: '<p>[dartschool test] Wordt meteen verwijderd.</p>',
        locations: hour.locations,
      );
      print('✓ Added: assignment ${assignment.id} "${assignment.name}".');
    } on SmartschoolPlannerError catch (e) {
      // A check refused it, or the types could not be read: nothing was
      // sent.
      print('Not added: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolPlannerSaveUnconfirmedError catch (e) {
      // It may have been added: look in the class calendar, and trash what
      // is there. Never create it again blindly.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
      await _trashLeftovers(planner, hour);
      return;
    }

    // ── 5. Read back, 6. Rename, 7. Trash (also after a failure) ─────────

    try {
      final detail = await planner.getDetail(assignment);
      print(
        '✓ Read back: "${detail.name}", ${detail.assignmentType?.name}, due '
        '${detail.period.from}, visible from ${detail.visibleFrom}, '
        'announced ${detail.isAnnounced}.',
      );
      // The list may show a change a few seconds late.
      await Future<void>.delayed(const Duration(seconds: 3));
      final klas = hour.participantGroups.first;
      final listed = await _ownTestsIn(planner, klas.calendar, hour);
      print(
        listed.any((e) => e.id == assignment.id)
            ? '✓ The calendar of ${klas.name} shows it.'
            : 'The calendar of ${klas.name} does not show it (yet).',
      );
      final renamed = await planner.renameElement(
        assignment,
        '$_testName (renamed)',
      );
      print('✓ Renamed: "${renamed.name}".');
    } on SmartschoolException catch (e) {
      print('Read or rename failed: $e');
      exitCode = 1;
    } finally {
      await _trash(planner, assignment);
    }

    // ── 8. Gone ───────────────────────────────────────────────────────────

    try {
      await planner.getDetail(assignment);
      print('The planner still has assignment ${assignment.id}: check it.');
      exitCode = 1;
    } on SmartschoolPlannedElementNotFoundError {
      print('✓ Gone: the planner answers 404 for ${assignment.id}.');
    }
  } finally {
    await client.dispose();
  }
}

/// The lesson hour of [me] (an empty timetable slot or a lesson) that starts
/// at [start], or `null`.
Future<PlannedElement?> _hourAt(
  PlannerService planner,
  PlannerCalendar me,
  DateTime start,
) async {
  final day = DateTime(start.year, start.month, start.day);
  final elements = await planner.getPlannedElements(
    me,
    from: day,
    to: day.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
  );
  return elements
      .where(
        (e) =>
            (e.type == PlannedElementType.placeholder ||
                e.type == PlannedElementType.lesson) &&
            e.period.from.isAtSameMomentAs(start),
      )
      .firstOrNull;
}

/// The school's assignment type whose abbreviation or name is [wanted], or
/// `null` after printing the types when none is.
Future<PlannerAssignmentType?> _type(
  PlannerService planner,
  String wanted,
) async {
  final types = await planner.getAssignmentTypes();
  final match = types
      .where(
        (type) =>
            type.abbreviation.toLowerCase() == wanted.toLowerCase() ||
            type.name.toLowerCase() == wanted.toLowerCase(),
      )
      .firstOrNull;
  if (match != null) return match;
  print('No assignment type is called "$wanted". The school\'s types:');
  for (final type in types) {
    print('  ${type.abbreviation.padRight(4)} ${type.name}');
  }
  print('Nothing changed.');
  return null;
}

/// The own `[dartschool test]` assignments in [calendar] on the day of
/// [hour].
Future<List<PlannedElement>> _ownTestsIn(
  PlannerService planner,
  PlannerCalendar calendar,
  PlannedElement hour,
) async {
  final me = (await planner.ownCalendar()).id;
  final from = hour.period.from;
  final day = DateTime(from.year, from.month, from.day);
  final assignments = await planner.getPlannedElements(
    calendar,
    from: day,
    to: day.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
    types: {PlannedElementType.assignment},
  );
  return [
    for (final assignment in assignments)
      if ((assignment.name ?? '').startsWith(_testName) &&
          assignment.organiserUsers.any((user) => user.id == me))
        assignment,
  ];
}

/// After a create that was not confirmed: trashes the own test assignments
/// in the calendar of the first class of [hour], if any.
Future<void> _trashLeftovers(
  PlannerService planner,
  PlannedElement hour,
) async {
  await Future<void>.delayed(const Duration(seconds: 5));
  final klas = hour.participantGroups.first;
  final found = await _ownTestsIn(planner, klas.calendar, hour);
  if (found.isEmpty) {
    print(
      'No test assignment in the calendar of ${klas.name}; check it by hand '
      'in a while (the list may lag).',
    );
    return;
  }
  for (final assignment in found) {
    await _trash(planner, assignment);
  }
}

/// Moves [assignment] to the planner's trash, and says what to do by hand
/// when that fails.
Future<void> _trash(PlannerService planner, PlannedElement assignment) async {
  try {
    await planner.trashAssignment(assignment);
    print('✓ In the trash: assignment ${assignment.id}.');
  } on SmartschoolException catch (e) {
    print(
      'TRASH FAILED: $e\nRemove assignment ${assignment.id} '
      '"${assignment.name}" by hand in the planner.',
    );
    exitCode = 1;
  }
}

/// Prints [element] after [prefix].
void _printElement(String prefix, PlannedElement element) {
  final groups = element.participantGroups.map((g) => g.name).join(', ');
  final courses = element.courses.map((c) => c.name).join(', ');
  final rooms = element.locations.map((l) => l.title).join(', ');
  print(
    '$prefix${element.period.from} - ${element.period.to}  '
    '${element.typeName} ${element.id}\n'
    '       classes $groups, course $courses, room $rooms',
  );
}
