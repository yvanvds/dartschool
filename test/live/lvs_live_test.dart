// What the pupil tracking system (LVS) answers the account of
// credentials.yml through LvsService (#160, #161): the root of its class
// tree (checkAccess), a pupil search, the placeholder pupil of a made-up ID
// (its file and its notes), and, when the developer names one, the file and
// the notes of a pupil they teach.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lvs_live_test.dart` alone. Without a
// credentials.yml in the package root, it skips.
//
// The LVS holds the most sensitive data of Smartschool (doc/lvs-privacy.md,
// rule 4): this file asserts shapes and counts only. It never prints a value
// of an answer, and its `expect`s compare counts, types and bools, never a
// name or a text, so that a failure quotes nothing either.
//
// Without the environment variable below, it reads no pupil: the class tree
// (the classes the account may see), a search for a text no one has, and a
// made-up pupil ID, which the LVS answers with its school's sections and a
// placeholder pupil (seen 2026-10-21), for its file and for the notes of a
// category, and with no data for all its notes. With it, it also searches
// for that text and reads the file and today's status of the first pupil
// found, the notes of the first of its categories that holds notes (twice:
// it prints how many are new before and after, for #168), all its notes,
// and a made-up category of it:
//
//   DARTSCHOOL_LVS_PUPIL=<part of the name of a pupil you teach> \
//     dart test -P live test/live/lvs_live_test.dart
//
// The name comes from the environment, never from the code. It only reads:
// the wire guard (support/live_wire_guard.dart) refuses every LVS POST but
// getStatusInfo, the root of the class tree and the dispatcher's
// getUserCatItems and getUserData, and every PUT. As every live
// run, it takes the lock of the session first, logs in at most once, and
// prints no credential, no cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// The environment variable with (part of) the name of a pupil the
/// developer teaches.
const _pupilVariable = 'DARTSCHOOL_LVS_PUPIL';

/// A search text no pupil's name holds.
const _nobody = 'qqxzdartschooltestqq';

/// A pupil ID and a class ID no school has.
const _madeUpId = 999999999;

void main() {
  final credentials = liveCredentialsFile();
  final pupil = Platform.environment[_pupilVariable]?.trim();

  group(
    'live, read only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LvsService lvs;
      late bool access;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lvs = LvsService(run.client);
        access = await lvs.checkAccess();
        print('checkAccess: $access');
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('a search for a text no one has: an empty list, or the refusal '
          'checkAccess saw', () async {
        if (access) {
          final found = await lvs.searchPupils(_nobody);
          expect(found.length, 0);
        } else {
          await expectLater(
            lvs.searchPupils(_nobody),
            throwsA(isA<SmartschoolLvsAccessDeniedError>()),
          );
        }
        expect(run.guard.violations, isEmpty);
      });

      test('a made-up pupil ID: SmartschoolLvsPupilNotFoundError, the LVS\'s '
          'placeholder, not a file', () async {
        await expectLater(
          lvs.getPupilFile(pupilId: _madeUpId, classId: _madeUpId),
          throwsA(
            access
                ? isA<SmartschoolLvsPupilNotFoundError>()
                : isA<SmartschoolLvsAccessDeniedError>(),
          ),
        );
        expect(run.guard.violations, isEmpty);
      });

      test("a made-up pupil's notes (#161): SmartschoolLvsPupilNotFoundError "
          'for a category, the LVS\'s placeholder; no notes at all in the '
          '"all items" view', () async {
        if (access) {
          await expectLater(
            lvs.getNotes(
              pupilId: _madeUpId,
              classId: _madeUpId,
              categoryId: _madeUpId,
            ),
            throwsA(isA<SmartschoolLvsPupilNotFoundError>()),
          );
          final all = await lvs.getAllNotes(
            pupilId: _madeUpId,
            classId: _madeUpId,
          );
          expect(all.length, 0);
        } else {
          // What the dispatcher answers without rights was not captured
          // (#168): an error, never an empty list.
          await expectLater(
            lvs.getNotes(
              pupilId: _madeUpId,
              classId: _madeUpId,
              categoryId: _madeUpId,
            ),
            throwsA(isA<SmartschoolLvsError>()),
          );
        }
        expect(run.guard.violations, isEmpty);
      });

      test(
        'a pupil the developer teaches (#161): the notes of a category with '
        'notes, each with a date and fields, all of them in the "all items" '
        'view; a made-up category is SmartschoolLvsCategoryNotFoundError',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their notes'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final match = (await lvs.searchPupils(pupil!)).first;
          final file = await lvs.getPupilFile(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final categories = [
            for (final category in file.noteCategories) ...[
              category,
              ...category.descendants,
            ],
          ];
          print(
            'note categories: ${categories.length} '
            '(${categories.where((c) => c.hasNotes).length} with notes, '
            '${categories.where((c) => c.hasNewNotes).length} with new ones)',
          );
          expect(categories.every((c) => c.id > 0), isTrue);

          await expectLater(
            lvs.getNotes(
              pupilId: match.pupilId,
              classId: match.classId,
              categoryId: _madeUpId,
            ),
            throwsA(isA<SmartschoolLvsCategoryNotFoundError>()),
          );

          final category = categories
              .where((c) => c.hasNotes && !c.isTitle)
              .firstOrNull;
          if (category == null) {
            print('no category with notes: nothing more to read');
            return;
          }
          final ids = {category.id, ...category.descendants.map((c) => c.id)};
          final notes = await lvs.getNotes(
            pupilId: match.pupilId,
            classId: match.classId,
            categoryId: category.id,
          );
          final fields = [for (final note in notes) ...note.fields];
          print(
            'notes: ${notes.length} (${notes.where((n) => n.isNew).length} '
            'new, ${notes.where((n) => n.viewed).length} viewed, '
            '${notes.where((n) => n.isConfidential).length} confidential), '
            'fields: ${fields.length}, by type: '
            '${{for (final type in LvsNoteFieldType.values) type.name: fields.where((f) => f.type == type).length}}',
          );
          expect(notes.every((n) => n.id > 0), isTrue);
          expect(notes.every((n) => ids.contains(n.categoryId)), isTrue);
          expect(notes.every((n) => n.date.year >= 2000), isTrue);
          expect(notes.every((n) => n.fields.isNotEmpty), isTrue);
          expect(fields.every((f) => f.paramId >= 0), isTrue);

          // Whether reading the notes takes them as seen (#168): counts only.
          final again = await lvs.getNotes(
            pupilId: match.pupilId,
            classId: match.classId,
            categoryId: category.id,
          );
          print(
            'new before and after a read: '
            '${notes.where((n) => n.isNew).length} -> '
            '${again.where((n) => n.isNew).length}',
          );

          final all = await lvs.getAllNotes(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final allIds = {for (final note in all) note.id};
          print('all notes: ${all.length} (${allIds.length} distinct)');
          expect(allIds.length, all.length);
          expect(notes.every((n) => allIds.contains(n.id)), isTrue);
          expect(run.guard.violations, isEmpty);
        },
      );

      test(
        'a pupil the developer teaches: found, and the overview of their '
        'file, its sections with an id, a type and a name',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their file'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final found = await lvs.searchPupils(pupil!);
          print('matches: ${found.length}');
          expect(found.length, greaterThan(0));
          expect(found.every((m) => m.pupilId > 0 && m.classId > 0), isTrue);
          expect(found.every((m) => m.name.isNotEmpty), isTrue);

          final match = found.first;
          final file = await lvs.getPupilFile(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final sections = file.allSections.toList();
          print(
            'sections: ${sections.length} '
            '(${sections.where((s) => s.hasItems).length} with items, '
            '${sections.where((s) => !s.isKnownType).length} of another '
            'type), teachers: ${file.teachers.length}, half-days with a '
            'status: ${file.todayStatus.halfDays.length}',
          );
          expect(file.pupilId == match.pupilId, isTrue);
          expect(file.name.isNotEmpty, isTrue);
          expect(file.className.isNotEmpty, isTrue);
          expect(file.sections.length, greaterThan(0));
          expect(sections.every((s) => s.id >= 0), isTrue);
          expect(sections.every((s) => s.type.isNotEmpty), isTrue);
          expect(sections.every((s) => s.name.isNotEmpty), isTrue);
          expect(file.teachers.every((t) => t.id > 0), isTrue);
          expect(file.todayStatus.halfDays.length, lessThanOrEqualTo(2));
          expect(
            file.todayStatus.halfDays.every(
              (h) => h.partOfDay == 'am' || h.partOfDay == 'pm',
            ),
            isTrue,
          );
          expect(run.guard.violations, isEmpty);
        },
      );
    },
  );
}
