// What Skore's gradebook answers the teacher of credentials.yml, read as
// that teacher (#148): SkoreGradebookService lists the own gradebooks of the
// current school year and of an earlier one, and reads the periods, the
// pupils and the rights of a gradebook; and a school year Skore does not
// offer is refused.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/skore_gradebook_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips. It holds for any
// teacher with gradebooks; for the developer's account it also checks the
// live test spot of #148, 6EWI (gradebook 32508, pathIds 176/472/2440,
// course 2264, period DW1 1704), and skips those checks when the account
// has no such gradebook.
//
// It only reads, and changes nothing in Skore, which drives the school's
// grading and has no test instance: getNavigation, init and
// getGradebookContext of Skore's gradebook RPC service. The service refuses
// any other method of that service itself (SkoreGradebookService.rpcMethods),
// and the wire guard (support/live_wire_guard.dart) refuses every Skore POST
// but those reads (and the two reads of the admin side). As every live run,
// it takes the lock of the session first, logs in at most once, and prints
// no credential, no cookie and no name: only IDs, counts and period names.
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
        final book = older.gradebooks.first;
        expectSheet(book, await gradebooks.getGradebook(book));
        expect(run.guard.violations, isEmpty);
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
