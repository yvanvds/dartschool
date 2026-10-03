// The live refusals of the planner's writes (#100): the reason and the
// element a SmartschoolPlannerWriteRefusedError carries, against the live
// planner of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/planner_refusals_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads: every write it calls is one that a check of
// PlannerService refuses before anything is sent, after reading the planner
// with GET requests. It reads a timetable slot of the own planner some eight
// weeks ahead, the own lesfiches and the school's assignment types, and
// never an element of a colleague or of a class. Two guards keep any write
// from going out should a check let one through: LiveWireGuard
// (support/live_wire_guard.dart) refuses every planner and lesfiche POST,
// which are not requests the live suite sends, and each test checks that
// the library did not even try one. The last test reads the week again and
// finds it as it was. As every live run, it takes the lock of the session
// first, logs in at most once, and prints no credential, no cookie and no
// name.
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

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The requests tried since [from] that would change the planner or the
  /// Lesfiches module: anything but a GET to them.
  List<String> writesSince(int from) => [
    for (final request in requests.skip(from))
      if (!request.startsWith('GET ') &&
          (request.contains(' /planner/') ||
              request.contains(' /lesson-content/')))
        request,
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

/// A lesfiche ID that is no UUID Smartschool hands out.
const _noSuchId = '00000000-0000-4000-8000-000000000000';

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
      late PlannerService planner;
      late _Attempts attempts;
      late PlannerCalendar own;
      late DateTime from;
      late DateTime to;
      late List<PlannedElement> weekBefore;

      /// An empty lesson hour of the own planner in that week, which the
      /// planner lets the user fill; `null` when the week has none.
      PlannedElement? slot;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        planner = PlannerService(run.client);

        own = await planner.ownCalendar();
        final ahead = DateTime.now().add(const Duration(days: 56));
        from = DateTime(ahead.year, ahead.month, ahead.day - ahead.weekday + 1);
        to = DateTime(from.year, from.month, from.day + 6, 23, 59, 59);
        weekBefore = await planner.getPlannedElements(own, from: from, to: to);
        slot = weekBefore
            .where(
              (e) =>
                  e.type == PlannedElementType.placeholder &&
                  e.organiserUsers.any((u) => u.id == own.id) &&
                  e.capabilities.canReplace &&
                  e.participantGroups.isNotEmpty &&
                  e.courses.isNotEmpty,
            )
            .firstOrNull;
      });

      tearDownAll(() async {
        await started?.close();
      });

      /// Runs [refuse], which must throw the refusal, and returns it; checks
      /// that the library tried no write on the way.
      Future<SmartschoolPlannerWriteRefusedError> refusal(
        Future<Object?> Function() refuse,
      ) async {
        final mark = attempts.requests.length;
        final violations = run.guard.violations.length;
        SmartschoolPlannerWriteRefusedError? refused;
        try {
          await refuse();
        } on SmartschoolPlannerWriteRefusedError catch (e) {
          refused = e;
        }
        expect(attempts.writesSince(mark), isEmpty, reason: 'nothing sent');
        expect(run.guard.violations, hasLength(violations));
        expect(refused, isNotNull, reason: 'the write must be refused');
        expect(refused!.message, endsWith('Nothing was sent.'));
        return refused;
      }

      test('planLesson in an own hour read with another period: '
          'periodChanged, with the hour as the planner has it', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }
        // The hour as if it had been read a week later: the check reads it
        // again and finds it in its own period.
        final period = Map<String, dynamic>.of(
          hour.raw['period'] as Map<String, dynamic>,
        );
        period['dateTimeFrom'] = PlannerService.formatDateTime(
          hour.period.from.add(const Duration(days: 7)),
        );
        period['dateTimeTo'] = PlannerService.formatDateTime(
          hour.period.to.add(const Duration(days: 7)),
        );
        final moved = PlannedElement.fromJson({...hour.raw, 'period': period});

        final refused = await refusal(
          () => planner.planLesson(
            placeholder: moved,
            name: '[dartschool test] refused',
          ),
        );

        expect(refused.reason, PlannerWriteRefusalReason.periodChanged);
        expect(refused.capabilityFlags, isEmpty);
        expect(refused.lessonContent, isNull);
        final element = refused.element!;
        expect(element, isA<PlannedElementDetail>());
        expect(element.id, hour.id);
        expect(element.type, PlannedElementType.placeholder);
        expect(element.period.from.isAtSameMomentAs(hour.period.from), isTrue);
        expect(element.period.to.isAtSameMomentAs(hour.period.to), isTrue);
        expect(
          element.participantGroups.map((g) => g.id),
          hour.participantGroups.map((g) => g.id),
        );
        expect(element.courses.map((c) => c.id), hour.courses.map((c) => c.id));
        expect(element.organiserUsers.map((u) => u.id), contains(own.id));
      });

      test('renameElement of an own hour, which the planner does not let '
          'the user rename: notAllowed, with the flags not set', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }
        final detail = await planner.getDetail(hour);
        final missing = [
          for (final flag in const ['canUserEdit', 'canUserRename'])
            if (!detail.capabilities.can(flag)) flag,
        ];
        if (missing.isEmpty) {
          // The planner would let the user rename it: the rename would go
          // out (and the guard refuse it). Never seen on a timetable slot.
          markTestSkipped('the planner lets the user rename this hour');
          return;
        }

        final refused = await refusal(
          () => planner.renameElement(hour, '[dartschool test] refused'),
        );

        expect(refused.reason, PlannerWriteRefusalReason.notAllowed);
        expect(refused.capabilityFlags, missing);
        expect(refused.element!.id, hour.id);
      });

      test('planLessonContent of a lesfiche the user does not have: '
          'unknownLessonContent, before the hour is read', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }

        final refused = await refusal(
          () => planner.planLessonContent(
            placeholder: hour,
            lessonContentId: _noSuchId,
          ),
        );

        expect(refused.reason, PlannerWriteRefusalReason.unknownLessonContent);
        expect(refused.element, isNull);
        expect(refused.lessonContent, isNull);
      });

      test('planLessonContent of an own assignment lesfiche: '
          'notALessonLessonContent, with the lesfiche', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }
        final fiche = (await LessonContentService(run.client).getItems())
            .where((item) => item.type == LessonContentType.assignment)
            .firstOrNull;
        if (fiche == null) {
          markTestSkipped('no assignment lesfiche among the own lesfiches');
          return;
        }

        final refused = await refusal(
          () => planner.planLessonContent(
            placeholder: hour,
            lessonContentId: fiche.id,
          ),
        );

        expect(
          refused.reason,
          PlannerWriteRefusalReason.notALessonLessonContent,
        );
        expect(refused.element, isNull);
        expect(refused.lessonContent?.id, fiche.id);
        expect(refused.lessonContent?.name, fiche.name);
        expect(refused.lessonContent?.type, LessonContentType.assignment);
      });

      test('planAssignment of a type the school does not have: '
          'unknownAssignmentType, without an element', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }

        final refused = await refusal(
          () => planner.planAssignment(
            groupIds: [for (final group in hour.participantGroups) group.id],
            course: hour.courses.first,
            type: const PlannerAssignmentType(
              id: _noSuchId,
              name: '[dartschool test] no such type',
            ),
            name: '[dartschool test] refused',
            due: hour.period.from,
            until: hour.period.to,
          ),
        );

        expect(refused.reason, PlannerWriteRefusalReason.unknownAssignmentType);
        expect(refused.element, isNull);
      });

      test('the week of the own planner is as it was', () async {
        final weekAfter = await planner.getPlannedElements(
          own,
          from: from,
          to: to,
        );
        String key(PlannedElement e) =>
            '${e.typeName} ${e.id} ${e.name} '
            '${e.period.from.toUtc()} ${e.period.to.toUtc()}';
        expect(weekAfter.map(key).toList(), weekBefore.map(key).toList());
        expect(attempts.writesSince(0), isEmpty);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
