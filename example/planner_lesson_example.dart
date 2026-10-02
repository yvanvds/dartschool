import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: fill an empty lesson hour of your own planner with a test lesson,
/// rename it, and clear the hour again (#87); or plan a lesfiche of your
/// Lesfiches library into the hour and clear it again (#88). It shows the
/// hour (and the lesfiche) and asks for confirmation first.
///
/// WARNING: this changes the live planner of the account of
/// `credentials.yml`. While the lesson exists, the pupils of the hour's
/// classes see its name and public info (for a lesfiche, those the planner
/// takes from it): use an hour far in the future, and only on purpose.
///
/// Run with:
///   dart run example/planner_lesson_example.dart YYYY-MM-DD HH:MM [LESFICHE]
///
/// The date and the start of a lesson hour of your own timetable, in the
/// local time of this machine, such as `2026-11-20 11:10`. LESFICHE, when
/// given, is the ID or the exact name of a lesson lesfiche
/// (`LessonContentService.getItems`); one that matches no lesson lesfiche
/// (such as `?`) prints your lesson lesfiches and changes nothing.
///
/// The flow:
///   1. Authenticate.
///   2. Read the own planner of that day and print the empty lesson hour
///      (timetable slot) that starts then; with LESFICHE, also read your
///      lesfiches and print the one to plan.
///   3. Ask for confirmation (y/N; anything but "y" or "yes", or no answer,
///      changes nothing).
///   4. Fill it with a `[dartschool test]` lesson (`PlannerService.planLesson`)
///      or with the lesfiche (`PlannerService.planLessonContent`; the lesson
///      is named after the lesfiche). The service reads the slot (and the
///      lesfiches) again first, and sends the fill once.
///   5. Rename the test lesson (`renameElement`); a lesson planned from a
///      lesfiche is left as the planner made it.
///   6. Clear the hour again (`clearLesson`), also when the rename failed.
///   7. Read the hour again and print it: an empty slot, with a new ID.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  final start = args.length == 2 || args.length == 3
      ? DateTime.tryParse('${args[0]}T${args[1]}:00')
      : null;
  if (start == null) {
    stderr.writeln(
      'Usage: dart run example/planner_lesson_example.dart YYYY-MM-DD HH:MM '
      '[LESFICHE]',
    );
    exitCode = 64;
    return;
  }
  final lesficheArg = args.length == 3 ? args[2].trim() : null;

  print(
    'WARNING: this changes your live planner. Pupils see the test lesson '
    'while it exists.\n',
  );

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final planner = PlannerService(client);
    final me = await planner.ownCalendar();

    // ── 2. The empty lesson hour ──────────────────────────────────────────

    final slot = await _slotAt(planner, me, start);
    if (slot == null) {
      print(
        'No empty lesson hour of your own planner starts at $start. (A '
        'filled hour is a lesson, not a slot.)',
      );
      exitCode = 1;
      return;
    }
    _printElement('Now:   ', slot);
    if (!slot.capabilities.canReplace) {
      print('The planner does not let you fill this hour (canUserReplace).');
      exitCode = 1;
      return;
    }

    final LessonContentItem? fiche;
    if (lesficheArg == null) {
      fiche = null;
    } else {
      fiche = await _lessonFiche(LessonContentService(client), lesficheArg);
      if (fiche == null) {
        exitCode = 1;
        return;
      }
      print(
        'Lesfiche: "${fiche.name}" (${fiche.id})'
        '${fiche.isVisible ? '' : ', hidden'}, '
        'labels ${fiche.labels.map((l) => l.text).join(', ')}',
      );
    }

    // ── 3. Confirmation ───────────────────────────────────────────────────

    print(
      fiche == null
          ? 'Change: fill it with "[dartschool test] planner lesson", rename '
                'it, and clear the hour again.'
          : 'Change: plan lesfiche "${fiche.name}" into it (pupils see the '
                'lesson while it exists), and clear the hour again.',
    );
    stdout.write('\nChange your planner? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      print('Nothing changed.');
      return;
    }

    // ── 4. Fill ───────────────────────────────────────────────────────────

    final PlannedElementDetail lesson;
    try {
      lesson = fiche == null
          ? await planner.planLesson(
              placeholder: slot,
              name: '[dartschool test] planner lesson',
              publicInfo: '<p>[dartschool test] Wordt meteen verwijderd.</p>',
              privateInfo: '<p>[dartschool test] Notities.</p>',
            )
          : await planner.planLessonContent(
              placeholder: slot,
              lessonContentId: fiche.id,
            );
      print('✓ Filled: lesson ${lesson.id} "${lesson.name}".');
    } on SmartschoolPlannerError catch (e) {
      // A check refused it, or the slot was gone: nothing was sent.
      print('Not filled: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolLessonContentError catch (e) {
      // The lesfiches could not be read again: nothing was sent.
      print('Not filled: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolPlannerSaveUnconfirmedError catch (e) {
      // It may have been filled: look at the hour, and clear a lesson there
      // by hand (or with clearLesson) when it was.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
      return;
    }

    // ── 5. Rename, 6. Clear (also after a failed rename) ──────────────────

    try {
      if (fiche == null) {
        final renamed = await planner.renameElement(
          lesson,
          '[dartschool test] planner lesson (renamed)',
        );
        print('✓ Renamed: "${renamed.name}".');
      }
    } on SmartschoolException catch (e) {
      print('Rename failed: $e');
      exitCode = 1;
    } finally {
      try {
        final empty = await planner.clearLesson(lesson);
        print('✓ Cleared: the hour is slot ${empty.id} again.');
      } on SmartschoolException catch (e) {
        print(
          'CLEAR FAILED: $e\nClear lesson ${lesson.id} by hand in the '
          'planner.',
        );
        exitCode = 1;
      }
    }

    // ── 7. The hour again ─────────────────────────────────────────────────

    // The list may show the old state for a few seconds after a change.
    await Future<void>.delayed(const Duration(seconds: 5));
    final after = await _slotAt(planner, me, start);
    print('');
    if (after == null) {
      print('After: no empty lesson hour at $start (yet); check the planner.');
    } else {
      _printElement('After: ', after);
    }
  } finally {
    await client.dispose();
  }
}

/// The empty lesson hour of [me] that starts at [start], or `null`.
Future<PlannedElement?> _slotAt(
  PlannerService planner,
  PlannerCalendar me,
  DateTime start,
) async {
  final day = DateTime(start.year, start.month, start.day);
  final slots = await planner.getPlannedElements(
    me,
    from: day,
    to: day.add(const Duration(hours: 23, minutes: 59, seconds: 59)),
    types: {PlannedElementType.placeholder},
  );
  return slots
      .where((slot) => slot.period.from.isAtSameMomentAs(start))
      .firstOrNull;
}

/// The lesson lesfiche whose ID or exact name is [wanted], or `null` after
/// printing the lesson lesfiches when none (or more than one) is.
Future<LessonContentItem?> _lessonFiche(
  LessonContentService lessonContent,
  String wanted,
) async {
  final lessons = [
    for (final fiche in await lessonContent.getItems())
      if (fiche.type == LessonContentType.lesson) fiche,
  ];
  final matches = [
    for (final fiche in lessons)
      if (fiche.id.toLowerCase() == wanted.toLowerCase() ||
          fiche.name == wanted)
        fiche,
  ];
  if (matches.length == 1) return matches.single;
  print(
    matches.isEmpty
        ? 'No lesson lesfiche has the ID or name "$wanted". Your lesson '
              'lesfiches:'
        : 'More than one lesson lesfiche is called "$wanted": give its ID.',
  );
  for (final fiche in matches.isEmpty ? lessons : matches) {
    print(
      '  ${fiche.id}  ${fiche.name}'
      '${fiche.isVisible ? '' : ' (hidden)'}'
      '  [${fiche.labels.map((l) => l.text).join(', ')}]',
    );
  }
  print('Nothing changed.');
  return null;
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
