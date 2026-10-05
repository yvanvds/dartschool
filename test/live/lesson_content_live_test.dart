// The live names of the courses of the lesfiches (#101): what
// LessonContentService.getItems and getCourses read from the Lesfiches module
// and the school's course list of credentials.yml, against the courses of the
// own planner.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lesson_content_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads, with GET requests: the own lesfiches, the school's course
// list and the own planner from four weeks before to four weeks after today
// (smartschool-mcp's window), never an element of a colleague or of a class.
// LiveWireGuard (support/live_wire_guard.dart) refuses every planner POST
// but the lookup of a calendar, and every lesfiche write but those of
// lesson_content_write_live_test.dart on the lesfiches that run made (#129);
// each test here checks that the library tried no request but a GET to
// them. As every live run, it takes the lock of the session first, logs in
// at most once, and prints no credential, no cookie and no name.
//
// For a course list that fails (#118), one test answers the GET of the course
// list itself, with Smartschool's error page and HTTP 500, before it goes
// out (_FailingCourseList): Smartschool cannot be made to fail it, and the
// lesfiches are still read live.
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

const _fichesPath = '/lesson-content/api/v1/lesson-content/';
const _coursesPath = '/course-list/api/v1/courses';

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The requests tried since [from] to the Lesfiches module, the course list
  /// or the planner that are not GETs.
  List<String> writesSince(int from) => [
    for (final request in requests.skip(from))
      if (!request.startsWith('GET ') &&
          (request.contains(' /planner/') ||
              request.contains(' /lesson-content/') ||
              request.contains(' /course-list/')))
        request,
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

/// While [enabled], answers the GET of the course list with Smartschool's
/// error page and HTTP 500 itself, so that the request does not go out: a
/// course list that fails (#118).
class _FailingCourseList extends Interceptor {
  bool enabled = false;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (enabled &&
        options.method.toUpperCase() == 'GET' &&
        options.uri.path == _coursesPath) {
      handler.resolve(
        Response<String>(
          requestOptions: options,
          statusCode: 500,
          data:
              '<!DOCTYPE html><html><head><title></title></head><body>'
              '<h1>Oeps, er ging iets mis</h1></body></html>',
          headers: Headers.fromMap({
            Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
          }),
        ),
      );
      return;
    }
    handler.next(options);
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
      late LessonContentService lessonContent;
      late _Attempts attempts;
      final failingCourseList = _FailingCourseList();

      /// The school's courses by ID, as getCourses read them.
      late Map<String, PlannerCourse> schoolCourses;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        // After it: the attempts see the course list GET it answers.
        interceptors.insert(interceptors.indexOf(run.guard), failingCourseList);
        lessonContent = LessonContentService(run.client);
        schoolCourses = {
          for (final course in await lessonContent.getCourses())
            course.id: course,
        };
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('getCourses: the school\'s courses, each with an ID, a platform '
          'and a name', () {
        expect(schoolCourses, isNotEmpty);
        for (final course in schoolCourses.values) {
          expect(course.id, isNotEmpty);
          expect(course.platformId, greaterThan(0));
          expect(course.name, isNotEmpty, reason: 'course ${course.id}');
        }
      });

      test('getItems names the course of every lesfiche after the course '
          'list, with one request more', () async {
        final mark = attempts.requests.length;

        final fiches = await lessonContent.getItems();

        final courses = [for (final fiche in fiches) ...fiche.courses];
        if (courses.isEmpty) {
          markTestSkipped('no lesfiche of the user has a course');
          return;
        }
        expect(attempts.requests.skip(mark).toList(), [
          'GET $_fichesPath',
          'GET $_coursesPath',
        ]);
        for (final course in courses) {
          // Named as the course list names the course with its ID; null only
          // for a course the list does not have.
          expect(
            course.name,
            schoolCourses[course.id]?.name,
            reason: 'course ${course.id}',
          );
        }
        // The IDs are the course list's: at least one course is named (seen
        // live, 2026-10-03: every one).
        expect(courses.where((c) => c.name != null), isNotEmpty);
        expect(attempts.writesSince(mark), isEmpty);
      });

      test('getItems(withCourseNames: false): the same lesfiches and course '
          'IDs, without names, with the one request', () async {
        final named = await lessonContent.getItems();
        final mark = attempts.requests.length;

        final plain = await lessonContent.getItems(withCourseNames: false);

        expect(attempts.requests.skip(mark).toList(), ['GET $_fichesPath']);
        expect(plain.map((f) => f.id), named.map((f) => f.id));
        expect(
          plain.map((f) => f.courses.map((c) => c.id).toList()),
          named.map((f) => f.courses.map((c) => c.id).toList()),
        );
        expect(
          plain.expand((f) => f.courses).map((c) => c.name),
          everyElement(isNull),
        );
      });

      test('getItems with a course list that fails (HTTP 500, answered by '
          'the test): a SmartschoolLessonContentCourseListError with the '
          'lesfiches as read live, the same as withCourseNames false '
          '(#118)', () async {
        final plain = await lessonContent.getItems(withCourseNames: false);
        if (plain.every((f) => f.courses.isEmpty)) {
          markTestSkipped('no lesfiche of the user has a course');
          return;
        }
        final mark = attempts.requests.length;

        failingCourseList.enabled = true;
        final Object? error;
        try {
          error = await lessonContent.getItems().then<Object?>(
            (fiches) => fail('getItems returned ${fiches.length} lesfiches'),
            onError: (Object e) => e,
          );
        } finally {
          failingCourseList.enabled = false;
        }

        // The lesfiches went out; the course list was answered here.
        expect(attempts.requests.skip(mark).toList(), [
          'GET $_fichesPath',
          'GET $_coursesPath',
        ]);
        expect(
          error,
          isA<SmartschoolLessonContentCourseListError>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having(
                (e) => e.message,
                'message',
                startsWith(
                  'The course list answered the courses with HTTP 500',
                ),
              ),
        );
        final items = (error! as SmartschoolLessonContentCourseListError).items;
        expect(items.map((f) => f.id), plain.map((f) => f.id));
        expect(
          items.map((f) => f.courses.map((c) => c.id).toList()),
          plain.map((f) => f.courses.map((c) => c.id).toList()),
        );
        expect(
          items.expand((f) => f.courses).map((c) => c.name),
          everyElement(isNull),
        );
        expect(attempts.writesSince(mark), isEmpty);
        expect(run.guard.violations, isEmpty);
      });

      test('the course list has the planner\'s course IDs: every course of '
          'the own planner around today is in it, with the planner\'s '
          'name', () async {
        final planner = PlannerService(run.client);
        final now = DateTime.now();
        final mark = attempts.requests.length;
        final elements = await planner.getPlannedElements(
          await planner.ownCalendar(),
          from: now.subtract(const Duration(days: 28)),
          to: now.add(const Duration(days: 28)),
        );
        final plannerCourses = {
          for (final element in elements)
            for (final course in element.courses) course.id: course,
        };
        if (plannerCourses.isEmpty) {
          markTestSkipped('no course in the own planner around today');
          return;
        }
        for (final course in plannerCourses.values) {
          expect(
            schoolCourses[course.id]?.name,
            course.name,
            reason: 'planner course ${course.id}',
          );
        }
        // A lesfiche of a course in the own planner is named as the planner
        // names it (what smartschool-mcp's workaround read from the planner).
        final fiches = await lessonContent.getItems();
        for (final course in fiches.expand((f) => f.courses)) {
          final planned = plannerCourses[course.id];
          if (planned != null) expect(course.name, planned.name);
        }
        expect(attempts.writesSince(mark), isEmpty);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
