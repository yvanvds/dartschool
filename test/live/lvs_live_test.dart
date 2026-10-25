// What the pupil tracking system (LVS) answers the account of
// credentials.yml through LvsService (#160, #161, #162, #163, #164): the
// root of its class tree (checkAccess), a pupil search, the placeholder
// pupil of a made-up ID (its file and its notes), the results app's, the
// support plans' and the absences' answers for that ID, and, when the
// developer names one, the file, the notes, the results, the support plan
// and the absences of a pupil they teach.
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
// category, with no data for all its notes, with an answer to every read of
// its results since they carry the results app's headers (#175, seen
// 2026-10-25: the configuration, and an empty list or page for the others;
// HTTP 500 for every one of them without the headers), with HTTP 500 for
// its absences, and with no period of support
// plans (a made-up class has no structure of them) for the support plan
// reads. With it, it also searches for that text and reads
// the file and today's status of the first pupil found; all its notes of the
// current school year, then the notes of the first of its categories that
// holds notes of its own in that year, which must be that category's own in
// all its notes (#177, #180: a category's notes are never its
// sub-categories'; read twice: it prints how many are new before and after,
// for #168), every note of both reads of that school year (#180: the LVS
// answers notes of other school years too, which the library leaves out;
// the counts by date and by label are printed before the first check that
// can fail), the notes of a category the file flags with notes but that
// holds none of its own in that year (an empty list), and a made-up
// category of it (support/lvs_notes_check.dart picks and compares, tested
// offline in lvs_notes_check_test.dart); its results (configuration,
// periods, courses, a page of two evaluations and all of them, feedback,
// reports: counts and types only),
// and, when its file has a section of support plans, their periods, the
// plan of the current period and the profile sketch (status, kinds and
// counts only), and its absences (counts by period, a school year each,
// part of the day and code only, and that every one has a date, #176):
//
//   DARTSCHOOL_LVS_PUPIL=<part of the name of a pupil you teach> \
//     dart test -P live test/live/lvs_live_test.dart
//
// The name comes from the environment, never from the code. It only reads:
// the wire guard (support/live_wire_guard.dart) refuses every LVS POST but
// getStatusInfo, the root of the class tree, the dispatcher's
// getUserCatItems and getUserData, the support plan reads
// getLVSspecificTitles, getIHP and getProfielSchets, and the absences
// (Pupilpresences), and every PUT; the
// results app's reads
// are GETs, on LvsService's own allowlist (#162). As every live
// run, it takes the lock of the session first, logs in at most once, and
// prints no credential, no cookie and no name.
//
// What the web client itself sends and gets for that pupil is the browser's
// capture (#168): save it as a HAR file in a temp folder and reduce it to
// shapes with `dart run tool/lvs_har_shapes.dart <file.har>` (#178;
// doc/lvs-privacy.md, "Capturing with the browser").
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
import 'support/lvs_notes_check.dart';

/// The environment variable with (part of) the name of a pupil the
/// developer teaches.
const _pupilVariable = 'DARTSCHOOL_LVS_PUPIL';

/// A search text no pupil's name holds.
const _nobody = 'qqxzdartschooltestqq';

/// A pupil ID and a class ID no school has.
const _madeUpId = 999999999;

/// A school year `YYYY-YYYY`, as the LVS keys the periods of a pupil's
/// absences (#176).
final _schoolYear = RegExp(r'^\d{4}\s*-\s*\d{4}$');

/// What a read of the results returned, by its type and count only: never a
/// value of the answer (doc/lvs-privacy.md, rule 4).
String _shapeOf(Object? result) => switch (result) {
  List() => 'a list of ${result.length}',
  LvsEvaluationPage() => 'a page of ${result.evaluations.length}',
  _ => '${result.runtimeType}',
};

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

      test("a made-up pupil's results (#162, #175): every read of the "
          'results app is answered or is a SmartschoolLvsError, never one '
          'the allowlist refuses (with the app\'s headers the LVS answers all '
          'six, the configuration and an empty list or page for the others, '
          'none with HTTP 500, seen 2026-10-25; without them it answered '
          'every one with HTTP 500, seen 2026-10-21)', () async {
        final reads = <String, Future<Object?> Function()>{
          'getResultsConfiguration': () => lvs.getResultsConfiguration(
            pupilId: _madeUpId,
            classId: _madeUpId,
          ),
          'getResultsPeriods': () =>
              lvs.getResultsPeriods(pupilId: _madeUpId, classId: _madeUpId),
          'getResultsCourses': () =>
              lvs.getResultsCourses(pupilId: _madeUpId, classId: _madeUpId),
          'getEvaluations': () =>
              lvs.getEvaluations(pupilId: _madeUpId, classId: _madeUpId),
          'getFeedback': () =>
              lvs.getFeedback(pupilId: _madeUpId, classId: _madeUpId),
          'getReports': () =>
              lvs.getReports(pupilId: _madeUpId, classId: _madeUpId),
        };
        // Every read is tried and printed before any is checked.
        final errors = <String, Object>{};
        for (final MapEntry(key: name, value: read) in reads.entries) {
          try {
            final result = await read();
            // The type and a count only: never a value of an answer.
            print('$name: ${_shapeOf(result)}');
          } catch (e) {
            errors[name] = e;
            // The type and the status only: never the message of an answer.
            print(
              '$name: ${e.runtimeType}'
              '${e is SmartschoolLvsError ? ' (${e.statusCode})' : ''}',
            );
          }
        }
        for (final MapEntry(key: name, value: error) in errors.entries) {
          expect(error, isA<SmartschoolLvsError>(), reason: name);
          expect(
            error,
            isNot(isA<SmartschoolLvsRequestNotAllowedError>()),
            reason: name,
          );
        }
        expect(run.guard.violations, isEmpty);
      });

      test("a made-up pupil's absences (#164): a SmartschoolLvsError (the "
          'LVS answered them with HTTP 500, seen 2026-10-21), never an empty '
          'list', () async {
        Object? error;
        try {
          await lvs.getAbsences(pupilId: _madeUpId, classId: _madeUpId);
        } catch (e) {
          error = e;
        }
        // The type and the status only: never the message of an answer.
        print(
          'getAbsences: ${error.runtimeType}'
          '${error is SmartschoolLvsError ? ' (${error.statusCode})' : ''}',
        );
        expect(error, isA<SmartschoolLvsError>());
        expect(error, isNot(isA<SmartschoolLvsRequestNotAllowedError>()));
        if (access) {
          expect(error, isNot(isA<SmartschoolLvsAccessDeniedError>()));
        }
        expect(run.guard.violations, isEmpty);
      });

      test(
        'a pupil the developer teaches (#164, #176): the absences of the '
        'file, by school year, part of the day and code, each with a date',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their absences'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final match = (await lvs.searchPupils(pupil!)).first;
          final file = await lvs.getPupilFile(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final sections = [
            for (final s in file.allSections)
              if (s.type == LvsSectionType.absences) s,
          ];
          print(
            'sections of type absents: ${sections.length} '
            '(${sections.where((s) => s.hasItems).length} with items)',
          );

          final absences = await lvs.getAbsences(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final all = absences.absences;
          final totals = absences.totalsByCode;
          final schoolYears = absences.periods
              .where((p) => _schoolYear.hasMatch(p.label))
              .length;
          print(
            'absences: $absences, with a year label: '
            '${absences.yearLabel.isNotEmpty}, periods with a label: '
            '${absences.periods.where((p) => p.label.isNotEmpty).length}, '
            'periods that are a school year: $schoolYears, '
            'absences with a day key: '
            '${all.where((a) => a.dateKey.isNotEmpty).length}, with a code '
            'key: ${all.where((a) => a.codeKey.isNotEmpty).length}, '
            'whole days: ${all.where((a) => a.isFullDay).length}, mornings: '
            '${all.where((a) => a.dayPart == DayPart.morning).length}, '
            'afternoons: '
            '${all.where((a) => a.dayPart == DayPart.afternoon).length}, '
            'with a date: ${all.where((a) => a.date != null).length}, with a '
            'shown date: ${all.where((a) => a.formattedDate.isNotEmpty).length}, '
            'with a description: '
            '${all.where((a) => a.codeDescription.isNotEmpty).length}, with a '
            'colour: ${all.where((a) => a.color != null).length}, with a '
            'motivation: ${all.where((a) => a.motivation.isNotEmpty).length}, '
            'codes: ${totals.length}',
          );
          // Every absence has a day, read from the text the LVS shows
          // (`formattedDate`, #176: the days of a school year come as a
          // list, without a day key), and a code: shapes, not values.
          expect(all.every((a) => a.date != null), isTrue);
          expect(all.every((a) => a.code.isNotEmpty), isTrue);
          expect(
            totals.fold<int>(0, (n, t) => n + t.halfDays),
            absences.halfDays,
          );
          expect(run.guard.violations, isEmpty);
        },
      );

      test("a made-up pupil's support plan (#163): no periods, no period for "
          'the plan (status noPeriod) and no profile sketch, as the LVS '
          'answers a class without a structure of support plans (seen '
          '2026-10-21)', () async {
        if (!access) {
          // What the LVS answers without rights was not captured (#168): an
          // error, never an empty result.
          await expectLater(
            lvs.getSupportPlan(pupilId: _madeUpId, classId: _madeUpId),
            throwsA(isA<SmartschoolLvsError>()),
          );
          expect(run.guard.violations, isEmpty);
          return;
        }
        final periods = await lvs.getSupportPlanPeriods(
          pupilId: _madeUpId,
          classId: _madeUpId,
        );
        expect(periods.length, 0);
        final plan = await lvs.getSupportPlan(
          pupilId: _madeUpId,
          classId: _madeUpId,
        );
        expect(plan.status == LvsSupportPlanStatus.noPeriod, isTrue);
        expect(plan.items.length, 0);
        final sketch = await lvs.getProfileSketch(
          pupilId: _madeUpId,
          classId: _madeUpId,
        );
        expect(sketch.hasSketch, isFalse);
        expect(sketch.period.hasError, isTrue);
        expect(run.guard.violations, isEmpty);
      });

      test(
        'a pupil the developer teaches (#163): the periods of the support '
        'plans, the plan of the current period by kind, and the profile '
        'sketch',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their support plan'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final match = (await lvs.searchPupils(pupil!)).first;
          final file = await lvs.getPupilFile(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final sections = file.supportPlanSections;
          print(
            'sections of support plans: ${sections.length} '
            '(${sections.where((s) => s.hasItems).length} with items)',
          );
          if (sections.isEmpty) {
            print('no section of support plans: nothing more to read');
            return;
          }
          final ids = (pupilId: match.pupilId, classId: match.classId);

          final periods = await lvs.getSupportPlanPeriods(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print(
            'periods: ${periods.length} '
            '(${periods.where((p) => p.heading.isNotEmpty).length} under a '
            'heading)',
          );
          expect(periods.every((p) => p.id > 0), isTrue);
          expect(periods.every((p) => p.name.isNotEmpty), isTrue);

          final plan = await lvs.getSupportPlan(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          final items = plan.items;
          int count(Iterable<int> Function(LvsPlanItem) of) =>
              items.fold(0, (n, item) => n + of(item).fold(0, (a, b) => a + b));
          print(
            'plan: ${plan.status.name}, period: ${plan.period}, '
            'period on the menu: '
            '${periods.any((p) => p.id == plan.period.id)}, items: '
            '${items.length}, by kind: '
            '${{for (final kind in LvsPlanItemKind.values) kind.name: items.where((i) => i.kind == kind).length}}, '
            'from the group plan: '
            '${items.where((i) => i.fromGroupPlan).length}, support needs: '
            '${count((i) => [i.supportNeeds.length])}, main goals: '
            '${count((i) => [i.mainGoals.length])}, work goals: '
            '${count((i) => [i.workGoals.length])}, approach: '
            '${count((i) => [i.approach.length])}, goals: '
            '${count((i) => [i.goals.length])} (objectives: '
            '${count((i) => i.goals.map((g) => g.objectives.length))}), with '
            'a start situation: '
            '${items.where((i) => i.startSituation.isNotEmpty).length}',
          );
          expect(items.every((i) => i.id > 0), isTrue);
          expect(
            {for (final item in items) '${item.type} ${item.id}'}.length,
            items.length,
          );

          final sketch = await lvs.getProfileSketch(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print(
            'profile sketch: $sketch, with text: ${sketch.text.isNotEmpty}, '
            'with a last change: ${sketch.lastRevision.isNotEmpty}',
          );
          expect(run.guard.violations, isEmpty);
        },
      );

      test(
        "a pupil the developer teaches (#162): the results of the file's "
        '"Resultaten" section, its periods, courses, evaluations page by '
        'page, feedback and reports',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their results'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final match = (await lvs.searchPupils(pupil!)).first;
          final file = await lvs.getPupilFile(
            pupilId: match.pupilId,
            classId: match.classId,
          );
          final types = {for (final s in file.allSections) s.type};
          print(
            'sections of type results: '
            '${types.contains(LvsSectionType.results)}, of type skore: '
            '${types.contains(LvsSectionType.skore)}',
          );
          if (!types.contains(LvsSectionType.results)) {
            print('no results section: nothing more to read');
            return;
          }
          final ids = (pupilId: match.pupilId, classId: match.classId);

          final config = await lvs.getResultsConfiguration(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print('configuration: $config');

          final periods = await lvs.getResultsPeriods(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          final courses = await lvs.getResultsCourses(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print(
            'periods: ${periods.length} '
            '(${periods.where((p) => p.isActive).length} active), courses: '
            '${courses.length} '
            '(${courses.where((c) => c.parentCourseId != null).length} part '
            'of another)',
          );
          expect(periods.every((p) => p.id > 0), isTrue);
          expect(courses.every((c) => c.id > 0), isTrue);

          // One small page, to see whether the LVS pages the list (#168).
          final first = await lvs.getEvaluations(
            pupilId: ids.pupilId,
            classId: ids.classId,
            itemsOnPage: 2,
          );
          print(
            'page 1 of 2: ${first.evaluations.length} evaluations '
            '(more than 2: the LVS does not page the list)',
          );

          final all = await lvs.getAllEvaluations(
            pupilId: ids.pupilId,
            classId: ids.classId,
            itemsOnPage: 50,
            maxPages: 20,
          );
          final evaluations = all.evaluations;
          // Counts by the library's own words only: a type the library does
          // not know is counted as "other", not printed.
          const evaluationTypes = {'normal', 'project', 'project-with-rubrics'};
          Map<String, int> countBy(
            Set<String> known,
            String Function(LvsEvaluation) of,
          ) => {
            for (final type in known)
              type: evaluations.where((e) => of(e) == type).length,
            'other': evaluations.where((e) => !known.contains(of(e))).length,
          };
          print(
            'evaluations: ${evaluations.length} in ${all.pagesRead} pages '
            '(complete: ${all.isComplete}), by score type: '
            '${countBy(LvsScoreType.known, (e) => e.score.type)}, by type: '
            '${countBy(evaluationTypes, (e) => e.type)}, '
            'with a date: ${evaluations.where((e) => e.date != null).length}, '
            'with a period: '
            '${evaluations.where((e) => e.period != null).length}, '
            'with a component: '
            '${evaluations.where((e) => e.componentName.isNotEmpty).length}, '
            'counting: ${evaluations.where((e) => e.doesCount == true).length}, '
            'published: '
            '${evaluations.where((e) => e.isPublished == true).length}, '
            'with feedback: '
            '${evaluations.where((e) => e.feedbackCount > 0).length}',
          );
          expect(evaluations.every((e) => e.identifier.isNotEmpty), isTrue);
          expect(evaluations.every((e) => e.courses.isNotEmpty), isTrue);
          expect(
            {for (final e in evaluations) e.identifier}.length,
            evaluations.length,
          );

          final feedback = await lvs.getFeedback(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print(
            'feedback: ${feedback.length}, by kind: '
            '${{for (final kind in LvsFeedbackKind.values) kind.name: feedback.where((f) => f.kind == kind).length}}, '
            'attachments: '
            '${feedback.fold<int>(0, (n, f) => n + f.attachments.length)}',
          );
          expect(feedback.every((f) => f.identifier.isNotEmpty), isTrue);

          final reports = await lvs.getReports(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          print(
            'reports: ${reports.length} '
            '(${reports.where((r) => r.date != null).length} with a date, '
            '${reports.where((r) => r.downloadUrl.isNotEmpty).length} with a '
            'download path)',
          );
          expect(reports.every((r) => r.id > 0), isTrue);
          expect(run.guard.violations, isEmpty);
        },
      );

      test(
        'a pupil the developer teaches (#161, #177, #180): the notes of a '
        'category with notes of its own in the school year, not empty, each '
        'with a date and fields, are its own in the "all items" view of that '
        'year; every note of both reads is of that year; a category flagged '
        'with notes but without any of its own in that year is an empty '
        'list; a made-up category is SmartschoolLvsCategoryNotFoundError',
        skip: pupil == null || pupil.isEmpty
            ? 'set $_pupilVariable to (part of) the name of a pupil you '
                  'teach to read their notes'
            : null,
        () async {
          expect(access, isTrue, reason: 'checkAccess');
          final match = (await lvs.searchPupils(pupil!)).first;
          final ids = (pupilId: match.pupilId, classId: match.classId);
          // One school year for every read, so that a category and the
          // "all items" view are read for the same days (#177).
          final year = LvsSchoolYear.current();
          final file = await lvs.getPupilFile(
            pupilId: ids.pupilId,
            classId: ids.classId,
          );
          final categories = flattenNoteCategories(file.noteCategories);
          print(
            'note categories: ${categories.length} '
            '(${categories.where((c) => c.hasNotes).length} with notes, '
            '${categories.where((c) => c.hasNewNotes).length} with new ones)',
          );
          expect(categories.every((c) => c.id > 0), isTrue);

          await expectLater(
            lvs.getNotes(
              pupilId: ids.pupilId,
              classId: ids.classId,
              categoryId: _madeUpId,
              schoolYear: year,
            ),
            throwsA(isA<SmartschoolLvsCategoryNotFoundError>()),
          );

          // The "all items" view first, and the category from it: the file
          // flags a category that holds notes in any school year, so the
          // first one flagged can hold older notes only, and its notes were
          // an empty list on which every check held (#177). A category is
          // picked by its own notes: getNotes never reads a sub-category's
          // (#180).
          final all = await lvs.getAllNotes(
            pupilId: ids.pupilId,
            classId: ids.classId,
            schoolYear: year,
          );
          final allIds = {for (final note in all) note.id};
          final picks = LvsNotePicks.of(file.noteCategories, all);
          print(
            'all notes in the school year: ${all.length} '
            '(${allIds.length} distinct); $picks',
          );
          // Whether the library kept the "all items" view to the school year
          // (#180: the LVS answers other years too): counts only.
          final allInYear = LvsNotesInYear.of(all, year);
          print('all notes against the school year: $allInYear');
          expect(allIds.length, all.length);
          expect(all.every((n) => n.id > 0), isTrue);
          expect(
            allInYear.outside,
            0,
            reason: 'notes of the "all items" view not of the school year',
          );
          expect(
            allInYear.labelledOutside,
            0,
            reason: 'notes of the "all items" view labelled with another year',
          );

          // A category flagged with notes, none of its own in the school
          // year: no error, none.
          final older = picks.flaggedWithoutNotes;
          if (older == null) {
            print(
              'no category flagged with notes but without any of its own in '
              'the school year: its empty list is not read',
            );
          } else {
            final none = await lvs.getNotes(
              pupilId: ids.pupilId,
              classId: ids.classId,
              categoryId: older.id,
              schoolYear: year,
            );
            print(
              'a category without notes of its own in the school year: '
              '${none.length} notes',
            );
            expect(none.length, 0);
          }

          final category = picks.withNotes;
          if (category == null) {
            expect(run.guard.violations, isEmpty);
            markTestSkipped(
              'no category holds notes of its own in the school year: '
              'nothing to compare with the "all items" view (#177)',
            );
            return;
          }
          final notes = await lvs.getNotes(
            pupilId: ids.pupilId,
            classId: ids.classId,
            categoryId: category.id,
            schoolYear: year,
          );
          final fields = [for (final note in notes) ...note.fields];
          print(
            'notes: ${notes.length} (${notes.where((n) => n.isNew).length} '
            'new, ${notes.where((n) => n.viewed).length} viewed, '
            '${notes.where((n) => n.isConfidential).length} confidential), '
            'fields: ${fields.length}, by type: '
            '${{for (final type in LvsNoteFieldType.values) type.name: fields.where((f) => f.type == type).length}}',
          );
          // By the IDs, as counts: an ID is never printed, nor quoted by a
          // failing expect (doc/lvs-privacy.md, rule 4). Printed before the
          // first check that can fail, so that one run gives them all.
          final comparison = LvsNotesComparison.of(
            category: category,
            all: all,
            read: notes,
          );
          final notesInYear = LvsNotesInYear.of(notes, year);
          print('the category against the "all items" view: $comparison');
          print('the category against the school year: $notesInYear');
          expect(notes.length, greaterThan(0));
          expect(
            comparison.missing,
            0,
            reason:
                'notes of the category in the "all items" view of the same '
                'school year that getNotes did not read: a bug of getNotes, '
                'to file (#177)',
          );
          expect(
            comparison.extra,
            0,
            reason:
                'notes getNotes read that the "all items" view does not have '
                'for the category',
          );
          expect(
            comparison.outside,
            0,
            reason: 'notes of another category than the one read (#180)',
          );
          expect(comparison.duplicates, 0, reason: 'notes read twice');
          expect(
            notesInYear.outside,
            0,
            reason: 'notes of the category not of the school year (#180)',
          );
          expect(
            notesInYear.labelledOutside,
            0,
            reason: 'notes of the category labelled with another year (#180)',
          );
          expect(notes.every((n) => n.id > 0), isTrue);
          expect(notes.every((n) => n.date.year >= 2000), isTrue);
          expect(notes.every((n) => n.fields.isNotEmpty), isTrue);
          expect(fields.every((f) => f.paramId >= 0), isTrue);

          // Whether reading the notes takes them as seen (#168): counts only.
          // The "all items" view was read first: its count of the
          // category's new notes is the one before any read of the category.
          final notesIds = {for (final note in notes) note.id};
          final again = await lvs.getNotes(
            pupilId: ids.pupilId,
            classId: ids.classId,
            categoryId: category.id,
            schoolYear: year,
          );
          print(
            'new before and after a read: '
            '${notes.where((n) => n.isNew).length} -> '
            '${again.where((n) => n.isNew).length} (in the "all items" view, '
            'read before: '
            '${all.where((n) => n.isNew && notesIds.contains(n.id)).length})',
          );
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
