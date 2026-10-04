// What Skore answers the account of credentials.yml, with or without the
// rights for its parts (#91): every read of SkoreService gives data or
// throws a SmartschoolSkoreAccessDeniedError in the part of Skore of the
// read, never a plain SmartschoolSkoreError (an answer the service cannot
// use); and checkAccess agrees with the reads.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/skore_access_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips. It holds for any
// account: a Skore administrator gets data from every read, a teacher
// without Skore's management rights is refused every read (seen
// 2026-10-04), and it prints which reads were refused.
//
// It only reads, and changes nothing in Skore, which drives the school's
// grading and has no test instance: getClasses, getCourses (of the first
// class, or of a class ID Skore does not know when there is none),
// getTeachers, getGradebookShares of the own account, and checkAccess. The
// wire guard (support/live_wire_guard.dart) refuses every Skore POST but the
// two RPC reads getTeachers and getCourses. As every live run, it takes the
// lock of the session first, logs in at most once, and prints no
// credential, no cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// A class ID Skore does not know: an administrator gets no courses for it
/// (#70).
const _unknownClassId = 999999;

void main() {
  final credentials = liveCredentialsFile();

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
      late SkoreService skore;
      late int me;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        skore = SkoreService(run.client);
        me = (await run.client.getCurrentUser()).id;
      });

      tearDownAll(() async {
        await started?.close();
      });

      /// Runs [read], a read in [area] of Skore: `true` when it gave data,
      /// `false` when Skore refused it to the account. Any other failure
      /// fails the test.
      Future<bool> gaveData(
        String name,
        SkoreAccessArea area,
        Future<Object?> Function() read,
      ) async {
        try {
          await read();
          print('$name: data');
          return true;
        } on SmartschoolSkoreAccessDeniedError catch (e) {
          expect(e.area, area, reason: '$name is a read in ${area.name}');
          print('$name: refused (${e.area.name})');
          return false;
        }
      }

      test('the reads of report management give data or are refused in '
          'report management', () async {
        const area = SkoreAccessArea.reportManagement;
        List<SkoreClass>? classes;
        await gaveData(
          'getClasses',
          area,
          () async => classes = await skore.getClasses(),
        );
        final classId = classes?.firstOrNull?.id ?? _unknownClassId;
        await gaveData('getCourses', area, () => skore.getCourses(classId));
        await gaveData('getTeachers', area, skore.getTeachers);
        expect(run.guard.violations, isEmpty);
      });

      test('the read of gradebook management gives data or is refused in '
          'gradebook management', () async {
        await gaveData(
          'getGradebookShares (own)',
          SkoreAccessArea.gradebookManagement,
          () => skore.getGradebookShares(me),
        );
        expect(run.guard.violations, isEmpty);
      });

      test('checkAccess names the parts whose reads give data', () async {
        final areas = await skore.checkAccess();
        print('checkAccess: ${areas.map((a) => a.name).toList()}');

        final teachers = await gaveData(
          'getTeachers',
          SkoreAccessArea.reportManagement,
          skore.getTeachers,
        );
        final gradebooks = await gaveData(
          'getGradebookShares (own)',
          SkoreAccessArea.gradebookManagement,
          () => skore.getGradebookShares(me),
        );
        expect(areas.contains(SkoreAccessArea.reportManagement), teachers);
        expect(areas.contains(SkoreAccessArea.gradebookManagement), gradebooks);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
