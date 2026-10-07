// The live check of #140: SmartschoolClient.ensureAuthenticated() checks the
// session with Smartschool on every call, also once the platform ID is
// known. Before #140 it read the cached platform ID and sent nothing after
// its first call, so it returned normally on a session Smartschool no longer
// accepted. The test calls it on a client whose platform ID is known (the
// run's start reads it), checks that its request went out, then clears the
// client's cookies, as on a session that expired, and calls it again: it
// logs in and returns normally, and a call after that goes out in the new
// session without another login.
//
// It only reads (the course list, `GET /course-list/api/v1/courses`) and logs
// in: it makes, changes and sends nothing.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml):
// `dart test -P live test/live/session_ensure_authenticated_live_test.dart`.
// Without a credentials.yml in the package root, it skips.
//
// It needs the one login a live run may make (LiveWireGuard refuses a
// second): when the run logged in already, because the session it found in
// the live cache had expired, the test skips; run it again, and it starts in
// the session that login saved. Clearing the cookies drops the run's session
// from the live cache (.dart_tool/live_cache, never the user's own cache);
// the login of the test saves a new one there. It prints no credential, no
// cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

/// The request of ensureAuthenticated.
const _courses = 'GET /course-list/api/v1/courses';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, ensureAuthenticated once the platform ID is known (#140):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late _Attempts attempts;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('every call sends its request; after clearCookies() it logs in and '
          'returns normally, and the next call needs no login', () async {
        if (run.guard.loggedIn) {
          markTestSkipped(
            'the run logged in already (the saved session had expired), and '
            'it may log in only once: run this file again',
          );
          return;
        }
        // The run's start read the platform ID (LiveRun checks the own
        // account with authenticatedUser); this makes sure it is known.
        expect(await run.client.platformId, isPositive);

        // Before the fix: nothing was sent.
        var from = attempts.requests.length;
        await run.client.ensureAuthenticated();
        expect(attempts.requests.sublist(from), [_courses]);
        expect(run.guard.loggedIn, isFalse);

        // As on a session that expired.
        await run.client.clearCookies();
        from = attempts.requests.length;
        // Before the fix: it returned normally without sending anything,
        // and the session stayed gone.
        await run.client.ensureAuthenticated();
        final requests = attempts.requests.sublist(from);
        expect(requests.first, _courses, reason: '$requests');
        expect(requests.last, _courses, reason: '$requests');
        expect(requests.where((r) => r == _courses), hasLength(2));
        expect(
          requests.indexOf('POST /login'),
          isPositive,
          reason: 'it logs in after the refused request: $requests',
        );
        expect(run.guard.loggedIn, isTrue);

        // The session of that login is accepted: no login again.
        from = attempts.requests.length;
        await run.client.ensureAuthenticated();
        expect(attempts.requests.sublist(from), [_courses]);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
