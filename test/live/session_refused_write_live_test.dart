// The live check of #134: a write sent with `retryAfterLogin: false` that
// Smartschool refuses for its session, tried again. The write is the create
// of a lesson lesfiche without courses or attachments
// (LessonContentService.createLesson), the issue's own case: the create is
// its only request before the read-back. The test clears the client's
// cookies, so that the create goes out without a session, as on a session
// that expired: Smartschool refuses it, it fails with a
// SmartschoolSessionExpiredError without a login, and nothing is made. The
// same create again logs in before it is sent, and makes the lesfiche once,
// in the own library ("Mijn lesfiches"). Before #134 it was refused again
// without a login, however often it was tried.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml):
// `dart test -P live test/live/session_refused_write_live_test.dart`.
// Without a credentials.yml in the package root, it skips.
//
// It needs the one login a live run may make (LiveWireGuard refuses a
// second): when the run logged in already, because the session it found in
// the live cache had expired, the test skips; run it again, and it starts in
// the session that login saved. Clearing the cookies drops the run's session
// from the live cache (.dart_tool/live_cache, never the user's own cache);
// the login of the test saves a new one there.
//
// The own library is private to the teacher. The run makes one lesfiche
// there, named "[dartschool test] <run tag> ...", and moves it to the trash
// (`lesson-content/trash/bulk`) at the end, also when the test failed, and
// checks that the library no longer lists it. LiveWireGuard refuses any
// other lesfiche write on the wire (#129). It prints no credential, no
// cookie and no name.
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
import 'support/live_wire_guard.dart';

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

const _create = 'POST /lesson-content/api/v1/lessons/';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, a lesfiche create refused for its session, tried again (#134):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;
      late _Attempts attempts;

      /// The lesfiches the run made.
      final made = <LessonContentItem>[];

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        lessonContent = LessonContentService(run.client);
      });

      tearDownAll(() async {
        try {
          Object? failure;
          if (made.isNotEmpty) {
            try {
              await lessonContent.trash(made);
            } on Object catch (e) {
              failure = e;
            }
            final listed = {
              for (final item in await lessonContent.getItems(
                withCourseNames: false,
              ))
                item.id,
            };
            expect(
              [
                for (final item in made)
                  if (listed.contains(item.id)) item.id,
              ],
              isEmpty,
              reason:
                  'the lesfiche the run made is in the trash again (failure: '
                  '$failure)',
            );
          }
          expect(failure, isNull);
        } finally {
          await started?.close();
        }
      });

      test(
        'the create fails without a login and makes nothing; tried again, '
        'it logs in before it is sent, and makes the lesfiche once',
        () async {
          if (run.guard.loggedIn) {
            markTestSkipped(
              'the run logged in already (the saved session had expired), and '
              'it may log in only once: run this file again',
            );
            return;
          }
          final lessonName = name('les na een geweigerde sessie');
          Future<LessonContentDetail> create() => lessonContent.createLesson(
            name: lessonName,
            publicInfo:
                '<p>Live test of the dartschool library (#134), run '
                '${run.tag}.</p>',
          );

          // As on a session that expired: the create goes out without one.
          await run.client.clearCookies();
          final first = attempts.requests.length;
          await expectLater(
            create(),
            throwsA(
              isA<SmartschoolSessionExpiredError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('not retried after logging in again'),
                  contains('The client logs in before its next request'),
                ),
              ),
            ),
          );
          expect(attempts.requests.sublist(first), [_create]);
          expect(run.guard.loggedIn, isFalse);

          final second = attempts.requests.length;
          final detail = await create();
          made.add(detail);

          expect(detail.name, lessonName);
          expect(detail.type, LessonContentType.lesson);
          final requests = attempts.requests.sublist(second);
          expect(requests.where((r) => r == _create), hasLength(1));
          expect(
            requests.indexOf('POST /login'),
            allOf(isNonNegative, lessThan(requests.indexOf(_create))),
            reason: 'the client logs in before it sends the create: $requests',
          );
          expect(run.guard.loggedIn, isTrue);

          // The refused create made nothing: the library lists one lesfiche of
          // that name, the one of the second create.
          final items = await lessonContent.getItems(withCourseNames: false);
          expect(
            [
              for (final item in items)
                if (item.name == lessonName) item.id,
            ],
            [detail.id],
          );
        },
      );
    },
  );
}
