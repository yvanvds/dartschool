// What Skore's gradebook answers the teacher of credentials.yml, read as
// that teacher (#148, #149): SkoreGradebookService lists the own gradebooks
// of the current school year and of an earlier one, and reads the periods,
// the pupils and the rights of a gradebook; a school year Skore does not
// offer is refused; and it reads the evaluations of a period with their
// publication and grades, and the pupils' feedback (#149), and the components
// of a period (#150). createEvaluation (#150) is tried only where its checks
// refuse it, before its save: an earlier school year, a date outside the
// school year, a component Skore does not offer; and so are saveGrade
// (#151) and saveFeedback (#152): a published or scheduled evaluation, an
// earlier school year (and, for saveFeedback, a blank text).
//
// For #192 it reads a gradebook without evaluation periods (the developer's
// behaviour gradebook, 35158, which has only a report period; skipped when
// the account has no such gradebook), and, last, a gradebook in a session
// that expired: it clears the client's cookies, so that `init` goes out
// without a session, which Skore answers with a redirect to `/`; the client
// logs in, sends it again and reads the gradebook (with 2FA, as on the
// developer's account, only because the login opens the start page after
// the 2FA step: Skore refuses the new session the same way until then).
// That needs the one login
// a live run may make (LiveWireGuard refuses a second): when the run logged
// in already, because the session it found in the live cache had expired,
// that test skips; run the file again, and it starts in the session that
// login saved.
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
// When a period closes is the school's to set, and it moves it (#198: DW1's
// closing time moved after #148). So no test expects a closing time, or
// that a period is open: each checks a period's closing time against the
// rest of Skore's answer (its info, whether it is open, the school year),
// and expects of a period, open or closed, what Skore does for that state
// (the refusals of saveGrade and saveFeedback, the rights).
//
// It only reads, and changes nothing in Skore, which drives the school's
// grading and has no test instance: getNavigation, init,
// getGradebookContext, getEvaluations, getNewEvalDialogBox and
// getPosComponents of Skore's gradebook RPC service, and the GET of a
// pupil's feedback of its REST API; never saveEvaluation or saveGrade, nor
// a POST of a feedback (#152) to that API. The service refuses any other
// method of that service itself (SkoreGradebookService.rpcMethods), and the
// wire guard (support/live_wire_guard.dart) refuses every Skore POST but
// those reads (and the two reads of the admin side), its REST API included.
// As every live run, it takes the lock of the session first, logs in at
// most once, and prints no credential, no cookie, no name and no feedback
// text: only IDs, counts, states, dates and period names.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/models/lvs_time.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// The live test spot of #148: the developer's gradebook of 6EWI.
const _testGradebookId = 32508;

/// 6EWI's period DW1, and its evaluation with grades and feedback (#149),
/// which is published from 2026-10-09 08:00 (CEST). Read only: never
/// written to. The school sets when DW1 closes, and moves it (#198): the
/// tests read that, and whether DW1 is open, from Skore.
const _testPeriodId = 1704;
const _testEvaluationId = 395742;

/// The developer's gradebook of 5BW in 2025-2026, whose evaluations are
/// published (#149); read only.
const _earlierGradebookId = 28998;

/// The developer's behaviour gradebook of 2026-2027 (#192): no evaluation
/// periods, only a report period. Read only.
const _behaviourGradebookId = 35158;

/// The opening and closing time in the info of an open period, in Belgian
/// time: "Open van 2026-09-18 15:30<br/> tot en met 2026-12-18 20:00"
/// (#198). A closed period's info says "Gesloten!" instead.
final _infoOpens = RegExp(r'Open van\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})');
final _infoCloses = RegExp(r'tot en met\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})');

/// A school year's name, "2026-2027".
final _schoolYearName = RegExp(r'^(\d{4})\s*-\s*(\d{4})$');

/// [instant] in Belgian time to the minute, as a period's info gives it:
/// `2026-12-18 20:00`.
String _belgianMinute(DateTime instant) {
  final wall = brusselsWallTime(instant);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${isoDay(wall)} ${two(wall.hour)}:${two(wall.minute)}';
}

/// Records Skore's answer to every call of its gradebook RPC service, as
/// (method, status, `Location`), as it comes in: the first interceptor, so
/// that it sees an answer that the client's login handles too (#192).
class _RpcAnswers extends Interceptor {
  final List<(String, int?, String?)> answers = [];

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler h) {
    final options = response.requestOptions;
    final data = options.data;
    if (options.uri.path == '/modules/Skore/backend/gradebook/rpc.php' &&
        data is Map) {
      answers.add((
        '${data['rpc_method']}',
        response.statusCode,
        response.headers.value('location'),
      ));
    }
    h.next(response);
  }
}

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

      /// Checks the closing time of [period], of a gradebook of school year
      /// [workyear] read from [readFrom] on, against the rest of Skore's
      /// answer, never against a date: the school sets it and moves it
      /// (#198). A period may have none.
      void expectClosingTime(
        SkoreGradebookPeriod period,
        SkoreWorkyear workyear,
        DateTime readFrom,
      ) {
        final closesAt = period.closesAt;
        if (closesAt == null) return;
        final where = 'period ${period.name} (${period.id})';
        expect(closesAt.isUtc, isTrue, reason: where);
        final years = _schoolYearName.firstMatch(workyear.name.trim());
        if (years != null) {
          expect(
            brusselsWallTime(closesAt).year,
            anyOf(int.parse(years[1]!), int.parse(years[2]!)),
            reason: '$where closes in school year ${workyear.name}',
          );
        }
        // Skore closes a period at its closing time.
        if (period.isOpen) {
          expect(
            closesAt.isAfter(readFrom),
            isTrue,
            reason: '$where is open: it closes later',
          );
        }
        final closes = _infoCloses.firstMatch(period.info)?[1];
        if (closes != null) {
          expect(_belgianMinute(closesAt), closes, reason: '$where: its info');
          final opens = _infoOpens.firstMatch(period.info)?[1];
          if (opens != null) {
            expect(
              opens.compareTo(closes),
              isNegative,
              reason: '$where opens before it closes',
            );
          }
        }
      }

      /// Checks [sheet], [book] of school year [workyear] as getGradebook
      /// reads it from [readFrom] on, and prints it without names.
      void expectSheet(
        SkoreGradebook book,
        SkoreGradebookSheet sheet,
        SkoreWorkyear workyear,
        DateTime readFrom,
      ) {
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
        for (final period in sheet.periods) {
          expectClosingTime(period, workyear, readFrom);
        }
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

        final readFrom = DateTime.now();
        final sheet = await gradebooks.getGradebook(book);

        expectSheet(book, sheet, year.workyear, readFrom);
        if (book.gradebookId == _testGradebookId) {
          expect(sheet.courseName, 'Informaticawetenschappen (2 uur)');
          final dw1 = sheet.periods.where((p) => p.id == _testPeriodId).single;
          expect(dw1.name, 'DW1');
          // Set, and checked by expectSheet against the info, which gives it
          // while DW1 is open: the school moves it (#198).
          expect(dw1.closesAt, isNotNull);
          if (dw1.isOpen) expect(dw1.info, matches(_infoCloses));
          // The own gradebook takes grades in an open period. In a closed
          // one Skore may answer either: writable 1 was seen for a closed
          // period of an earlier school year (#148).
          if (sheet.activePeriod!.isOpen) {
            expect(sheet.writable, isTrue, reason: 'an open period');
          }
          expect(sheet.pupils.map((p) => p.number), everyElement(isNotNull));
        }
        expect(run.guard.violations, isEmpty);
      });

      test('getGradebook reads a gradebook without evaluation periods: the '
          'behaviour gradebook $_behaviourGradebookId (#192)', () async {
        final book = year.gradebooks
            .where((g) => g.gradebookId == _behaviourGradebookId)
            .firstOrNull;
        if (book == null) {
          markTestSkipped(
            'no gradebook $_behaviourGradebookId in this account',
          );
          return;
        }
        final answers = _RpcAnswers();
        run.client.dio.interceptors.insert(0, answers);
        addTearDown(() => run.client.dio.interceptors.remove(answers));

        final sheet = await gradebooks.getGradebook(book);

        print(
          'gradebook ${book.gradebookId} (class ${book.classId}, course '
          '${book.courseId}): ${sheet.periods.length} periods, '
          '${sheet.pupils.length} pupils, writable ${sheet.writable}',
        );
        expect(sheet.gradebook, same(book));
        expect(sheet.periods, isEmpty);
        expect(sheet.activePeriod, isNull);
        expect(sheet.writable, isFalse);
        expect(sheet.pupils, isNotEmpty);
        for (final pupil in sheet.pupils) {
          expect(pupil.classId, book.classId);
          expect(pupil.name, contains(','));
        }
        // Without periods, getGradebookContext is not asked.
        expect(answers.answers, [('init', 200, null)]);
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
        final readFrom = DateTime.now();
        final sheet = await gradebooks.getGradebook(book);
        expectSheet(book, sheet, older.workyear, readFrom);

        // The components of a closed period, as DW1 of 6EWI is once its
        // closing time has passed (#198): read as those of an open one.
        final closed = sheet.periods.where((p) => !p.isOpen).firstOrNull;
        if (closed != null) {
          final components = await gradebooks.getComponents(book, closed.id);
          print(
            'gradebook ${book.gradebookId}, closed period ${closed.name}: '
            '${components.length} components',
          );
          expect(components.where((c) => c.isNone), hasLength(1));
        }

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

      /// What a write into [evaluation], a published or scheduled one of
      /// [sheet], without allowPublished, is refused for: its period first,
      /// when Skore gives that closed (as DW1 of 6EWI once its closing time,
      /// which the school sets, has passed: #198) or read-only; else its
      /// publication.
      String publicRefusal(
        SkoreGradebookSheet sheet,
        SkoreEvaluation evaluation,
      ) {
        final period = sheet.periods
            .where((p) => p.id == evaluation.periodId)
            .single;
        if (!period.isOpen) return 'is closed';
        if (period.id == sheet.activePeriod?.id &&
            (!sheet.writable || sheet.isCoordinator)) {
          return 'read-only to you';
        }
        return evaluation.publication.state == SkorePublicationState.scheduled
            ? 'is scheduled to be published'
            : 'is published';
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
          // DW1 of 6EWI while it is open, else the period Skore opens the
          // gradebook on, while that is open: the school sets when a period
          // closes (#198).
          final period = [
            ...sheet.periods.where((p) => p.id == periodId),
            ?sheet.activePeriod,
          ].where((p) => p.isOpen).firstOrNull;
          if (period == null || !sheet.writable) {
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

      // saveGrade is tried only where one of its checks refuses it: it reads,
      // and never sends its save (the wire guard refuses saveGrade as well,
      // and would list it as a violation). The live write itself is the
      // developer's, with the example, on their go-ahead.
      group('saveGrade refuses before its save (#151):', () {
        Matcher refused(String reason) =>
            isA<SmartschoolSkoreChangeRefusedError>().having(
              (e) => e.message,
              'message',
              allOf(
                startsWith('saveGrade: '),
                contains(reason),
                endsWith('Nothing was saved.'),
              ),
            );

        test(
          'a published or scheduled evaluation, without allowPublished',
          () async {
            final (book, sheet, periodId) = await evaluationSpot();
            final evaluations = periodId == null
                ? const <SkoreEvaluation>[]
                : await gradebooks.getEvaluations(book, periodId);
            final public =
                evaluations
                    .where((e) => e.id == _testEvaluationId)
                    .firstOrNull ??
                evaluations
                    .where(
                      (e) => e.publication.isPublic && !e.isPlannerEvaluation,
                    )
                    .firstOrNull;
            final pupil = public?.results.grades.firstOrNull;
            if (public == null || pupil == null) {
              markTestSkipped(
                'no public evaluation with pupils in gradebook '
                '${book.gradebookId}',
              );
              return;
            }

            await expectLater(
              gradebooks.saveGrade(book, public, pupil.pupilId, '1'),
              throwsA(refused(publicRefusal(sheet, public))),
            );
            expect(run.guard.violations, isEmpty);
          },
        );

        test(
          'an evaluation of a gradebook of an earlier school year',
          () async {
            final earlier = year.workyears
                .where((y) => y.id != year.workyear.id)
                .firstOrNull;
            final older = earlier == null
                ? const <SkoreGradebook>[]
                : await gradebooks.getGradebooks(workyearId: earlier.id);
            final book =
                older
                    .where((g) => g.gradebookId == _earlierGradebookId)
                    .firstOrNull ??
                older.firstOrNull;
            final period = book == null
                ? null
                : (await gradebooks.getGradebook(book)).activePeriod;
            final evaluation = book == null || period == null
                ? null
                : (await gradebooks.getEvaluations(
                    book,
                    period.id,
                  )).firstOrNull;
            final pupil = evaluation?.results.grades.firstOrNull;
            if (book == null || evaluation == null || pupil == null) {
              markTestSkipped('no evaluation of an earlier school year');
              return;
            }

            await expectLater(
              gradebooks.saveGrade(
                book,
                evaluation,
                pupil.pupilId,
                '1',
                allowPublished: true,
              ),
              throwsA(refused('writes in the current school year only')),
            );
            expect(run.guard.violations, isEmpty);
          },
        );
      });

      // saveFeedback is tried only where one of its checks refuses it, before
      // it reads the feedback: it never sends its POST (the wire guard
      // refuses every POST to Skore's REST API as well, and would list it as
      // a violation). The live write itself is the developer's, with the
      // example, on their go-ahead.
      group('saveFeedback refuses before its save (#152):', () {
        Matcher refused(String reason) =>
            isA<SmartschoolSkoreChangeRefusedError>().having(
              (e) => e.message,
              'message',
              allOf(
                startsWith('saveFeedback: '),
                contains(reason),
                endsWith('Nothing was saved.'),
              ),
            );

        test('a published or scheduled evaluation, without allowPublished; a '
            'blank text, before anything is sent', () async {
          final (book, sheet, periodId) = await evaluationSpot();
          final evaluations = periodId == null
              ? const <SkoreEvaluation>[]
              : await gradebooks.getEvaluations(book, periodId);
          final public =
              evaluations.where((e) => e.id == _testEvaluationId).firstOrNull ??
              evaluations
                  .where(
                    (e) => e.publication.isPublic && !e.isPlannerEvaluation,
                  )
                  .firstOrNull;
          final pupil = public?.results.grades.firstOrNull;
          if (public == null || pupil == null) {
            markTestSkipped(
              'no public evaluation with pupils in gradebook '
              '${book.gradebookId}',
            );
            return;
          }

          await expectLater(
            gradebooks.saveFeedback(book, public, pupil.pupilId, 'Test'),
            throwsA(refused(publicRefusal(sheet, public))),
          );
          await expectLater(
            gradebooks.saveFeedback(
              book,
              public,
              pupil.pupilId,
              '   ',
              allowPublished: true,
            ),
            throwsA(refused('the text is blank')),
          );
          expect(run.guard.violations, isEmpty);
        });

        test(
          'an evaluation of a gradebook of an earlier school year',
          () async {
            final earlier = year.workyears
                .where((y) => y.id != year.workyear.id)
                .firstOrNull;
            final older = earlier == null
                ? const <SkoreGradebook>[]
                : await gradebooks.getGradebooks(workyearId: earlier.id);
            final book =
                older
                    .where((g) => g.gradebookId == _earlierGradebookId)
                    .firstOrNull ??
                older.firstOrNull;
            final period = book == null
                ? null
                : (await gradebooks.getGradebook(book)).activePeriod;
            final evaluation = book == null || period == null
                ? null
                : (await gradebooks.getEvaluations(
                    book,
                    period.id,
                  )).firstOrNull;
            final pupil = evaluation?.results.grades.firstOrNull;
            if (book == null || evaluation == null || pupil == null) {
              markTestSkipped('no evaluation of an earlier school year');
              return;
            }

            await expectLater(
              gradebooks.saveFeedback(
                book,
                evaluation,
                pupil.pupilId,
                'Test',
                allowPublished: true,
              ),
              throwsA(refused('writes in the current school year only')),
            );
            expect(run.guard.violations, isEmpty);
          },
        );
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

      // Last: it replaces the run's session.
      test('getGradebook in a session that expired: Skore redirects init to '
          '/, and the client logs in, sends it again and reads the gradebook '
          '(#192)', () async {
        if (run.guard.loggedIn) {
          markTestSkipped(
            'the run logged in already (the saved session had expired), and '
            'it may log in only once: run this file again',
          );
          return;
        }
        final book =
            year.gradebooks
                .where((g) => g.gradebookId == _behaviourGradebookId)
                .firstOrNull ??
            year.gradebooks.first;
        final answers = _RpcAnswers();
        run.client.dio.interceptors.insert(0, answers);
        addTearDown(() => run.client.dio.interceptors.remove(answers));

        // As on a session that expired: init goes out without one.
        await run.client.clearCookies();
        final sheet = await gradebooks.getGradebook(book);

        print(
          'gradebook ${book.gradebookId}: answers ${answers.answers}; '
          '${sheet.periods.length} periods, ${sheet.pupils.length} pupils',
        );
        expect(answers.answers.first, ('init', 302, '/'));
        expect(answers.answers[1], ('init', 200, null));
        expect(run.guard.loggedIn, isTrue);
        expect(sheet.gradebook, same(book));
        expect(sheet.pupils, isNotEmpty);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
