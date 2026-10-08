// What Skore's gradebook answers the teacher of credentials.yml, read as
// that teacher (#148, #149): SkoreGradebookService lists the own gradebooks
// of the current school year and of an earlier one, and reads the periods,
// the pupils and the rights of a gradebook; a school year Skore does not
// offer is refused; and it reads the evaluations of a period with their
// publication and grades, and the pupils' feedback (#149), and the components
// of a period (#150). createEvaluation (#150) is tried only where its checks
// refuse it, before its save: an earlier school year, a date outside the
// school year, a component Skore does not offer.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/skore_gradebook_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips. It holds for any
// teacher with gradebooks; for the developer's account it also checks the
// live test spot of #148, 6EWI (gradebook 32508, pathIds 176/472/2440,
// course 2264, period DW1 1704, and, for #149, its evaluation 395742 with
// grades and feedback, to be published on 2026-10-09 08:00), and skips those
// checks when the account has no such gradebook.
//
// It only reads, and changes nothing in Skore, which drives the school's
// grading and has no test instance: getNavigation, init,
// getGradebookContext, getEvaluations, getNewEvalDialogBox and
// getPosComponents of Skore's gradebook RPC service, and the GET of a
// pupil's feedback of its REST API; never saveEvaluation. The service refuses
// any other method of that service itself (SkoreGradebookService.rpcMethods),
// and the wire guard (support/live_wire_guard.dart) refuses every Skore POST
// but those reads (and the two reads of the admin side), its REST API
// included. As every live run, it takes the lock of the session first, logs
// in at most once, and prints no credential, no cookie, no name and no
// feedback text: only IDs, counts, states, dates and period names.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// The live test spot of #148: the developer's gradebook of 6EWI.
const _testGradebookId = 32508;

/// 6EWI's period DW1, and its evaluation with grades and feedback (#149),
/// which is published from 2026-10-09 08:00 (CEST). Read only: never
/// written to.
const _testPeriodId = 1704;
const _testEvaluationId = 395742;

/// The developer's gradebook of 5BW in 2025-2026, whose evaluations are
/// published (#149); read only.
const _earlierGradebookId = 28998;

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late SkoreGradebookService gradebooks;
      late int me;
      late SkoreGradebookYear year;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        gradebooks = SkoreGradebookService(run.client);
        me = (await run.client.getCurrentUser()).id;
        year = await gradebooks.getGradebookYear();
      });

      tearDownAll(() async {
        await started?.close();
      });

      /// Checks [books], gradebooks of school year [workyearId] as
      /// getNavigation lists them.
      void expectGradebooks(List<SkoreGradebook> books, int workyearId) {
        final ids = books.map((g) => g.gradebookId).toList();
        expect(ids.toSet(), hasLength(ids.length), reason: 'each once');
        for (final book in books) {
          expect(book.workyearId, workyearId);
          expect(book.teacherId, me, reason: 'the own gradebooks');
          expect(book.pathIds, everyElement(greaterThan(0)));
          expect(book.courseId, greaterThan(0));
          expect(book.className, isNotEmpty);
          expect(book.courseName, isNotEmpty);
        }
      }

      /// Checks [sheet], [book] as getGradebook reads it, and prints it
      /// without names.
      void expectSheet(SkoreGradebook book, SkoreGradebookSheet sheet) {
        print(
          'gradebook ${book.gradebookId} (class ${book.classId}, course '
          '${book.courseId}, school year ${book.workyearId}): periods '
          '${[for (final p in sheet.periods) '${p.name} ${p.id} ${p.isOpen ? 'open' : 'closed'} until ${p.closesAt?.toIso8601String()}']}, '
          'active ${sheet.activePeriod?.name}; ${sheet.pupils.length} pupils, '
          '${sheet.pupils.where((p) => p.number != null).length} with a '
          'class number, ${sheet.pupils.where((p) => !p.isActive).length} '
          'inactive; writable ${sheet.writable}, coordinator '
          '${sheet.isCoordinator}',
        );
        expect(sheet.gradebook, same(book));
        expect(sheet.courseName, isNotEmpty);
        expect(sheet.periods, isNotEmpty);
        expect(sheet.periods, contains(sheet.activePeriod));
        expect(sheet.pupils, isNotEmpty);
        final pupilIds = sheet.pupils.map((p) => p.id).toList();
        expect(pupilIds.toSet(), hasLength(pupilIds.length));
        for (final pupil in sheet.pupils) {
          expect(pupil.classId, book.classId);
          expect(pupil.name, contains(','));
          expect(pupil.displayName, isNotEmpty);
        }
      }

      test('getGradebookYear lists the own gradebooks of the current school '
          'year, each once, with the school years Skore offers', () {
        print(
          'school year ${year.workyear.name} (${year.workyear.id}): '
          '${year.gradebooks.length} gradebooks; offered: '
          '${year.workyears.map((y) => y.id).toList()}',
        );
        expect(year.workyears.map((y) => y.id), contains(year.workyear.id));
        expect(year.gradebooks, isNotEmpty);
        expectGradebooks(year.gradebooks, year.workyear.id);
        expect(run.guard.violations, isEmpty);
      });

      test('6EWI (gradebook $_testGradebookId), the live test spot, as the '
          'research of #148 saw it', () {
        final book = year.gradebooks
            .where((g) => g.gradebookId == _testGradebookId)
            .firstOrNull;
        if (book == null) {
          markTestSkipped('no gradebook $_testGradebookId in this account');
          return;
        }
        expect(book.pathIds, [176, 472, 2440]);
        expect(book.className, '6EWI');
        expect(book.groupName, '6DO');
        expect(book.courseId, 2264);
        expect(book.courseName, startsWith('Informaticawetenschappen'));
      });

      test('getGradebook reads the periods, the pupils and the rights of a '
          'gradebook', () async {
        final book =
            year.gradebooks
                .where((g) => g.gradebookId == _testGradebookId)
                .firstOrNull ??
            year.gradebooks.first;

        final sheet = await gradebooks.getGradebook(book);

        expectSheet(book, sheet);
        if (book.gradebookId == _testGradebookId) {
          expect(sheet.courseName, 'Informaticawetenschappen (2 uur)');
          final dw1 = sheet.periods.where((p) => p.id == 1704).single;
          expect(dw1.name, 'DW1');
          expect(dw1.closesAt, DateTime.utc(2026, 12, 18, 19));
          expect(sheet.writable, isTrue);
          expect(sheet.pupils.map((p) => p.number), everyElement(isNotNull));
        }
        expect(run.guard.violations, isEmpty);
      });

      test('an earlier school year: its gradebooks, and one of them', () async {
        final earlier = year.workyears
            .where((y) => y.id != year.workyear.id)
            .firstOrNull;
        if (earlier == null) {
          markTestSkipped('Skore offers no other school year');
          return;
        }

        final older = await gradebooks.getGradebookYear(workyearId: earlier.id);

        print(
          'school year ${older.workyear.name} (${older.workyear.id}): '
          '${older.gradebooks.length} gradebooks',
        );
        expect(older.workyear.id, earlier.id);
        expectGradebooks(older.gradebooks, earlier.id);
        if (older.gradebooks.isEmpty) {
          markTestSkipped('no gradebooks in ${earlier.name}');
          return;
        }
        final book =
            older.gradebooks
                .where((g) => g.gradebookId == _earlierGradebookId)
                .firstOrNull ??
            older.gradebooks.first;
        final sheet = await gradebooks.getGradebook(book);
        expectSheet(book, sheet);

        // Its evaluations (#149), of the first period that has any:
        // published long ago, as far as they are public.
        for (final period in sheet.periods) {
          final evaluations = await gradebooks.getEvaluations(book, period.id);
          print(
            'gradebook ${book.gradebookId}, period ${period.name}: '
            '${[for (final e in evaluations) '${e.id} ${e.publication.state.name} ${e.publication.at?.toIso8601String()}, ${e.results.grades.where((g) => g.grade != null).length}/${e.results.grades.length} grades']}',
          );
          for (final evaluation in evaluations) {
            expect(evaluation.periodId, period.id);
            expect(
              evaluation.publication.state,
              evaluation.publication.isPublic
                  ? SkorePublicationState.published
                  : SkorePublicationState.notPublished,
            );
            for (final grade in evaluation.results.grades) {
              expect(grade.classId, book.classId);
            }
          }
          if (evaluations.isNotEmpty) break;
        }
        expect(run.guard.violations, isEmpty);
      });

      /// The live test spot of #149 (6EWI) when the account has it, else
      /// the first gradebook, with its sheet and the period to read: DW1 for
      /// 6EWI, the active period for another; `null` without periods.
      Future<(SkoreGradebook, SkoreGradebookSheet, int?)>
      evaluationSpot() async {
        final book =
            year.gradebooks
                .where((g) => g.gradebookId == _testGradebookId)
                .firstOrNull ??
            year.gradebooks.first;
        final sheet = await gradebooks.getGradebook(book);
        final periodId = book.gradebookId == _testGradebookId
            ? _testPeriodId
            : sheet.activePeriod?.id;
        return (book, sheet, periodId);
      }

      test('getEvaluations reads the evaluations of a period with their '
          'publication and grades (#149)', () async {
        final (book, sheet, periodId) = await evaluationSpot();
        if (periodId == null) {
          markTestSkipped('gradebook ${book.gradebookId} has no periods');
          return;
        }

        final evaluations = await gradebooks.getEvaluations(book, periodId);
        final readAt = DateTime.now();

        final pupilIds = sheet.pupils.map((p) => p.id).toSet();
        for (final evaluation in evaluations) {
          final grades = evaluation.results.grades;
          final publication = evaluation.publication;
          print(
            'evaluation ${evaluation.id} (column ${evaluation.column}, '
            '${evaluation.date.toIso8601String().substring(0, 10)}, max '
            '${evaluation.max}, ${evaluation.componentName}, '
            '${evaluation.type.name}): ${publication.state.name}'
            '${publication.at == null ? '' : ' ${publication.at!.toIso8601String()}'}'
            ' (public "${publication.rawPublic}", publicdatetime '
            '"${publication.rawPublicDateTime}"); ${grades.length} rows, '
            '${grades.where((g) => g.grade != null).length} grades, '
            '${grades.where((g) => g.hasFeedback).length} with feedback; '
            'class average ${evaluation.results.classAverage}',
          );
          expect(evaluation.gradebookId, book.gradebookId);
          expect(evaluation.periodId, periodId);
          expect(evaluation.title, isNotEmpty);
          expect(
            publication.state,
            publication.stateAt(readAt),
            reason: 'no publication time between the answer and now',
          );
          for (final grade in grades) {
            expect(grade.classId, book.classId);
            expect(pupilIds, contains(grade.pupilId));
            expect(grade.cellEvaluationId, evaluation.evaluationId);
          }
          final rows = grades.map((g) => g.pupilId).toList();
          expect(rows.toSet(), hasLength(rows.length), reason: 'each once');
        }
        final ids = evaluations.map((e) => e.id).toList();
        expect(ids.toSet(), hasLength(ids.length));

        if (book.gradebookId == _testGradebookId) {
          final spot = evaluations
              .where((e) => e.id == _testEvaluationId)
              .single;
          expect(spot.date, DateTime(2026, 9, 30));
          expect(spot.max, 100);
          expect(spot.componentName, 'DW');
          expect(spot.type, SkoreEvaluationType.points);
          expect(spot.isPlannerEvaluation, isFalse);
          // Published from 2026-10-09 08:00 in Belgium: scheduled before
          // then, published from then on.
          final publication = spot.publication;
          expect(publication.isPublic, isTrue);
          expect(publication.rawPublicDateTime, '2026-10-09T08:00:00');
          expect(publication.at, DateTime.utc(2026, 10, 9, 6));
          expect(
            publication.state,
            readAt.isBefore(publication.at!)
                ? SkorePublicationState.scheduled
                : SkorePublicationState.published,
          );
          final grades = spot.results.grades;
          expect(grades, isNotEmpty);
          for (final grade in grades.where((g) => g.grade != null)) {
            expect(grade.value, isNotNull, reason: 'a number with a point');
          }
          expect(grades.where((g) => g.hasFeedback), isNotEmpty);
          expect(double.tryParse(spot.results.classAverage ?? ''), isNotNull);
        }
        expect(run.guard.violations, isEmpty);
      });

      test('getResults reads the grades of an evaluation again, the same '
          '(#149)', () async {
        final (book, _, periodId) = await evaluationSpot();
        final evaluation = periodId == null
            ? null
            : (await gradebooks.getEvaluations(book, periodId)).firstOrNull;
        if (evaluation == null) {
          markTestSkipped('no evaluation in gradebook ${book.gradebookId}');
          return;
        }

        final results = await gradebooks.getResults(book, evaluation);

        expect(results.evaluationId, evaluation.id);
        expect(
          [for (final g in results.grades) (g.pupilId, g.grade, g.hasFeedback)],
          [
            for (final g in evaluation.results.grades)
              (g.pupilId, g.grade, g.hasFeedback),
          ],
        );
        expect(results.classAverage, evaluation.results.classAverage);
        expect(run.guard.violations, isEmpty);
      });

      test("getFeedback reads a pupil's feedback, each apart (#149)", () async {
        final (book, _, periodId) = await evaluationSpot();
        if (book.gradebookId != _testGradebookId) {
          markTestSkipped('no gradebook $_testGradebookId in this account');
          return;
        }
        final spot = (await gradebooks.getEvaluations(
          book,
          periodId!,
        )).where((e) => e.id == _testEvaluationId).single;
        final grades = spot.results.grades;

        for (final grade in grades.where((g) => g.hasFeedback)) {
          final feedback = await gradebooks.getFeedback(
            book,
            spot,
            grade.pupilId,
          );
          print(
            'pupil ${grade.pupilId}: ${feedback.length} feedback, by teachers '
            '${feedback.map((f) => f.teacherId).toList()}, of '
            '${feedback.map((f) => f.text.length).toList()} characters, '
            'changed ${feedback.map((f) => f.changedAt?.toIso8601String()).toList()}, '
            '${feedback.map((f) => f.attachments.length).toList()} '
            'attachments, can edit ${feedback.map((f) => f.canEdit).toList()}',
          );
          expect(feedback, isNotEmpty, reason: 'its cell is marked');
          for (final item in feedback) {
            expect(item.id, isNotEmpty);
            expect(item.pupilId, grade.pupilId);
            expect(item.teacherId, greaterThan(0));
            expect(item.text, isNotEmpty);
            expect(item.createdAt, isNotNull);
            expect(item.changedAt, isNotNull);
          }
        }
        final without = grades.where((g) => !g.hasFeedback).firstOrNull;
        if (without != null) {
          expect(
            await gradebooks.getFeedback(book, spot, without.pupilId),
            isEmpty,
            reason: 'its cell is not marked',
          );
        }
        expect(run.guard.violations, isEmpty);
      });

      test('getComponents reads the components of a period (#150)', () async {
        final (book, _, periodId) = await evaluationSpot();
        if (periodId == null) {
          markTestSkipped('gradebook ${book.gradebookId} has no periods');
          return;
        }

        final components = await gradebooks.getComponents(book, periodId);

        print(
          'gradebook ${book.gradebookId}, period $periodId: components '
          '${[for (final c in components) '${c.id} ${c.name}']}',
        );
        expect(components.where((c) => c.isNone), hasLength(1));
        if (book.gradebookId == _testGradebookId) {
          expect(
            [for (final c in components) (c.id, c.name)],
            [(0, 'geen'), (2, 'DW')],
          );
        }
        expect(run.guard.violations, isEmpty);
      });

      // createEvaluation is tried only where one of its checks refuses it:
      // it reads, and never sends its save (the wire guard refuses
      // saveEvaluation as well, and would list it as a violation). The live
      // write itself is the developer's, with the example, on their go-ahead.
      group('createEvaluation refuses before its save (#150):', () {
        Matcher refused(String reason) =>
            isA<SmartschoolSkoreChangeRefusedError>().having(
              (e) => e.message,
              'message',
              allOf(contains(reason), endsWith('Nothing was saved.')),
            );

        test('a gradebook of an earlier school year', () async {
          final earlier = year.workyears
              .where((y) => y.id != year.workyear.id)
              .firstOrNull;
          final older = earlier == null
              ? const <SkoreGradebook>[]
              : await gradebooks.getGradebooks(workyearId: earlier.id);
          if (older.isEmpty) {
            markTestSkipped('no gradebooks of an earlier school year');
            return;
          }
          final book =
              older
                  .where((g) => g.gradebookId == _earlierGradebookId)
                  .firstOrNull ??
              older.first;
          final period = (await gradebooks.getGradebook(book)).activePeriod;

          await expectLater(
            gradebooks.createEvaluation(
              book,
              period?.id ?? 1,
              title: 'dartschool test (mag weg)',
              date: DateTime.now(),
              max: 20,
            ),
            throwsA(refused('writes in the current school year only')),
          );
          expect(run.guard.violations, isEmpty);
        });

        test('a date outside the school year, and a component Skore does not '
            'offer, in an open period of the own gradebook', () async {
          final (book, sheet, periodId) = await evaluationSpot();
          final period = sheet.periods
              .where((p) => p.id == periodId)
              .firstOrNull;
          if (period == null || !period.isOpen || !sheet.writable) {
            markTestSkipped(
              'no open period in gradebook ${book.gradebookId} to try it in',
            );
            return;
          }
          Future<SkoreEvaluation> create({
            required DateTime date,
            int? componentId,
          }) => gradebooks.createEvaluation(
            book,
            period.id,
            title: 'dartschool test (mag weg)',
            date: date,
            max: 20,
            componentId: componentId,
          );

          // Refused after the gradebook, the period and the rights.
          await expectLater(
            create(date: DateTime(2020, 1, 1)),
            throwsA(refused('is not in school year ${year.workyear.name}')),
          );
          // Refused after the reads of the dialog too: the course and the
          // components, read live.
          await expectLater(
            create(date: DateTime.now(), componentId: 999),
            throwsA(refused('component 999 is not one Skore offers')),
          );
          expect(run.guard.violations, isEmpty);
        });
      });

      test('a school year Skore does not offer is refused', () async {
        final offered = year.workyears.map((y) => y.id).toSet();
        final unknown = [
          99,
          999,
          9999,
        ].firstWhere((id) => !offered.contains(id));

        await expectLater(
          gradebooks.getGradebooks(workyearId: unknown),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'workyearId'),
          ),
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
