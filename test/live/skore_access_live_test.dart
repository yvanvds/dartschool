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
// For #194 it reads, last, the classes in a session that expired: it clears
// the client's cookies, so that the GET of the list of report models goes
// out without a session, which Smartschool sends on to its login chain; the
// client logs in (with 2FA, as on the developer's account, it then opens the
// start page, #192), sends the GET again and reads the classes, without the
// one more GET SkoreService sends when Skore sent the GET on to the start
// page at `/`. That needs the one login a live run may make (LiveWireGuard
// refuses a second): when the run logged in already, because the session it
// found in the live cache had expired, that test skips; run the file again,
// and it starts in the session that login saved. It prints where each answer
// to the GET ended and the redirects it followed, by path and module only.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// A class ID Skore does not know: an administrator gets no courses for it
/// (#70).
const _unknownClassId = 999999;

/// The path of the list of report models, which getClasses GETs.
const _modelsPath = '/modules/Skore/modules/rapportbeheer/data.php';

/// [uri] by its path and the `module` of its query only.
String _place(Uri uri) {
  final module = uri.queryParameters['module'];
  return module == null ? uri.path : '${uri.path}?module=$module';
}

/// Records every answer to the GET of the list of report models, as
/// (status, where it ended, the redirects it followed), by path and module
/// only, as it comes in: the first interceptor, so that it sees an answer
/// that the client's login handles too (#194).
class _ModelsAnswers extends Interceptor {
  final List<(int?, String, String)> answers = [];

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler h) {
    final options = response.requestOptions;
    if (options.method == 'GET' && options.uri.path == _modelsPath) {
      answers.add((
        response.statusCode,
        _place(response.realUri),
        response.redirects.map((r) => _place(r.location)).join(' > '),
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

      // Last: it replaces the run's session.
      test('getClasses in a session that expired: the GET is sent on to the '
          'login chain, and the client logs in, sends it again once and '
          'reads the classes (#194)', () async {
        if (run.guard.loggedIn) {
          markTestSkipped(
            'the run logged in already (the saved session had expired), and '
            'it may log in only once: run this file again',
          );
          return;
        }
        final answers = _ModelsAnswers();
        run.client.dio.interceptors.insert(0, answers);
        addTearDown(() => run.client.dio.interceptors.remove(answers));

        // As on a session that expired: the GET goes out without one.
        await run.client.clearCookies();
        List<SkoreClass>? classes;
        final gave = await gaveData(
          'getClasses in a session that expired',
          SkoreAccessArea.reportManagement,
          () async => classes = await skore.getClasses(),
        );

        print('answers (status, ended on, redirects): ${answers.answers}');
        expect(run.guard.loggedIn, isTrue);
        // The first answer ended on the login chain, which made the client
        // log in.
        expect(answers.answers.first.$2, '/login');
        // After the login, the GET was sent once: Skore accepted the new
        // session, so it did not send the GET on to the start page at `/`,
        // and SkoreService did not ask once more.
        expect(answers.answers, hasLength(2));
        expect(answers.answers[1].$2, isNot('/'));
        if (gave) {
          expect(answers.answers[1], (200, _modelsPath, ''));
          expect(classes, isNotEmpty);
        }
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
