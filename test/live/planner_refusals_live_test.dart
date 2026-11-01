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
// PlannerService refuses, or finds already done (#226), before anything is
// sent, after reading the planner
// with GET requests. It reads a timetable slot of the own planner some eight
// weeks ahead, the own lesfiches and the school's assignment types, and
// never an element of a colleague or of a class. Two guards keep any write
// from going out should a check let one through: LiveWireGuard
// (support/live_wire_guard.dart) refuses every planner and lesfiche POST,
// which are not requests the live suite sends (but the planner's lookup of
// a calendar by ID, which only reads and which these tests do not send,
// #127), and each test checks that the library did not even try one. The
// last test reads the week again and finds it as it was. As every live run,
// it takes the lock of the session first, logs in at most once, and prints
// no credential, no cookie and no name: an element or a lesfiche is shown
// by its ID, and its name is compared in the test and checked as a boolean
// (support/unshown.dart: `expect` shows the actual value of a failed match
// whatever the matcher, and the toString of an element or a lesfiche holds
// its name, #216).
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
import 'support/unshown.dart';

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

/// An element of [type] with [_noSuchId], at [from], that the planner does
/// not have: for a check that refuses before the element is read (#224),
/// or, on the own [platformId], one that the planner answers with `404`
/// (#225).
PlannedElement _unread(
  PlannedElementType type,
  DateTime from, {
  int platformId = 0,
}) => PlannedElement(
  id: _noSuchId,
  platformId: platformId,
  type: type,
  typeName: type.wireName!,
  period: PlannerPeriod(from: from, to: from.add(const Duration(minutes: 50))),
);

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
        expect(refused.lessonContent?.id, isNull, reason: 'a lesfiche');
        final element = refused.element!;
        expect(
          element is PlannedElementDetail,
          isTrue,
          reason: 'element ${element.id} is not read as its detail',
        );
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
        expect(refused.element?.id, isNull, reason: 'an element');
        expect(refused.lessonContent?.id, isNull, reason: 'a lesfiche');
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
        expect(refused.element?.id, isNull, reason: 'an element');
        expect(refused.lessonContent?.id, fiche.id);
        expectSameUnshown(
          refused.lessonContent?.name,
          fiche.name,
          reason: 'lesfiche ${fiche.id} is not named as getItems names it',
        );
        expect(refused.lessonContent?.type, LessonContentType.assignment);
      });

      test('replaceWithLessonContent of a lesfiche the user does not have: '
          'unknownLessonContent, before the lesson is read (#224)', () async {
        // The lesfiche is checked before the lesson is read: a lesson that
        // the planner does not have is never asked for.
        final lesson = _unread(PlannedElementType.lesson, from);

        final refused = await refusal(
          () => planner.replaceWithLessonContent(
            lesson: lesson,
            lessonContentId: _noSuchId,
          ),
        );

        expect(refused.reason, PlannerWriteRefusalReason.unknownLessonContent);
        expect(refused.element?.id, isNull, reason: 'an element');
      });

      test('planLessonContentInto of an own assignment lesfiche: '
          'notALessonLessonContent, with the lesfiche, before a target is '
          'read (#224)', () async {
        // The lesfiche is checked before the targets are read: an hour that
        // the planner does not have is never asked for.
        final hour = _unread(PlannedElementType.placeholder, from);
        final fiche = (await LessonContentService(run.client).getItems())
            .where((item) => item.type == LessonContentType.assignment)
            .firstOrNull;
        if (fiche == null) {
          markTestSkipped('no assignment lesfiche among the own lesfiches');
          return;
        }

        final refused = await refusal(
          () => planner.planLessonContentInto(
            lessonContentId: fiche.id,
            targets: [hour],
          ),
        );

        expect(
          refused.reason,
          PlannerWriteRefusalReason.notALessonLessonContent,
        );
        expect(refused.element?.id, isNull, reason: 'an element');
        expect(refused.lessonContent?.id, fiche.id);
      });

      test('planLessonContentInto of an own lesson lesfiche into an own hour '
          'read with another period: periodChanged, with the hour as the '
          'planner has it; the bulk plan is not sent (#224)', () async {
        final hour = slot;
        if (hour == null) {
          markTestSkipped('no own empty lesson hour in the week of $from');
          return;
        }
        final fiche = (await LessonContentService(run.client).getItems())
            .where((item) => item.type == LessonContentType.lesson)
            .firstOrNull;
        if (fiche == null) {
          markTestSkipped('no lesson lesfiche among the own lesfiches');
          return;
        }
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
          () => planner.planLessonContentInto(
            lessonContentId: fiche.id,
            targets: [moved],
          ),
        );

        expect(refused.reason, PlannerWriteRefusalReason.periodChanged);
        expect(refused.element?.id, hour.id);
        expect(
          refused.element!.period.from.isAtSameMomentAs(hour.period.from),
          isTrue,
        );
      });

      test('saveAsLessonContent of a lesson the planner does not have: '
          'SmartschoolPlannedElementNotFoundError, before the lesfiches '
          'are read; the save is not sent (#225)', () async {
        // On the own platform: the planner answers a lesson of platform 0
        // with 400, not 404.
        final lesson = _unread(
          PlannedElementType.lesson,
          from,
          platformId: int.parse(own.id.split('_').first),
        );
        final mark = attempts.requests.length;
        final violations = run.guard.violations.length;

        await expectLater(
          planner.saveAsLessonContent(lesson, name: '[dartschool test] no'),
          throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
        );

        expect(attempts.writesSince(mark), isEmpty, reason: 'nothing sent');
        expect(run.guard.violations, hasLength(violations));
        expect(
          attempts.requests
              .skip(mark)
              .where((r) => r.contains(' /lesson-content/')),
          isEmpty,
          reason: 'the lesfiches are read only for a lesson that may be saved',
        );
      });

      test('changeGoals of a lesson the planner does not have: '
          'SmartschoolPlannedElementNotFoundError; the change is not sent '
          '(#226)', () async {
        // On the own platform: the planner answers a lesson of platform 0
        // with 400, not 404.
        final lesson = _unread(
          PlannedElementType.lesson,
          from,
          platformId: int.parse(own.id.split('_').first),
        );
        final mark = attempts.requests.length;
        final violations = run.guard.violations.length;

        await expectLater(
          planner.changeGoals(lesson, const []),
          throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
        );

        expect(attempts.writesSince(mark), isEmpty, reason: 'nothing sent');
        expect(run.guard.violations, hasLength(violations));
      });

      test('changeGoals of an own lesson with the goals it has: the goals '
          'read from its detail, nothing sent, the lesson returned as read '
          '(#226)', () async {
        PlannedElement? ownLesson(List<PlannedElement> elements) => elements
            .where(
              (e) =>
                  e.type == PlannedElementType.lesson &&
                  e.organiserUsers.any((u) => u.id == own.id),
            )
            .firstOrNull;
        // That week, else the coming four weeks (the week ahead may be a
        // holiday).
        var lesson = ownLesson(weekBefore);
        final now = DateTime.now();
        final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
        for (var week = 0; lesson == null && week < 4; week++) {
          final start = DateTime(
            monday.year,
            monday.month,
            monday.day + 7 * week,
          );
          lesson = ownLesson(
            await planner.getPlannedElements(
              own,
              from: start,
              to: DateTime(start.year, start.month, start.day + 6, 23, 59, 59),
              types: {PlannedElementType.lesson},
            ),
          );
        }
        if (lesson == null) {
          markTestSkipped(
            'no own lesson in the week of $from or the coming '
            'four weeks',
          );
          return;
        }
        final detail = await planner.getDetail(lesson);
        if (!detail.capabilities.can('canUserEdit') ||
            !detail.capabilities.can('canUserChangeGoals')) {
          markTestSkipped('own lesson ${lesson.id} may not change its goals');
          return;
        }
        // Only the count and the shape are checked: a failure prints no goal.
        expect(
          detail.goals,
          isNotNull,
          reason: 'the detail of lesson ${lesson.id} has no goals list',
        );
        final mark = attempts.requests.length;
        final violations = run.guard.violations.length;

        final same = await planner.changeGoals(lesson, detail.goals!.reversed);

        expect(attempts.writesSince(mark), isEmpty, reason: 'nothing sent');
        expect(run.guard.violations, hasLength(violations));
        expect(same.id, lesson.id);
        expect(same.goals?.length, detail.goals!.length);
      });

      test('planAssignment of a type the school does not have: '
          'unknownAssignmentType, without an element, with the school\'s '
          'types as the check read them (#119)', () async {
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
        expect(refused.element?.id, isNull, reason: 'an element');

        // The types the check read: the school's, without the refused one,
        // the same as a read of their own right afterwards gives them.
        String key(PlannerAssignmentType t) =>
            '${t.id} ${t.platformId} ${t.name} ${t.abbreviation}';
        final types = await planner.getAssignmentTypes();
        expect(types, isNotEmpty);
        expect(
          refused.assignmentTypes.map(key).toList(),
          types.map(key).toList(),
        );
        expect(
          refused.assignmentTypes.map((t) => t.id),
          isNot(contains(_noSuchId)),
        );
        expect(attempts.writesSince(0), isEmpty);
      });

      test('the week of the own planner is as it was', () async {
        final weekAfter = await planner.getPlannedElements(
          own,
          from: from,
          to: to,
        );
        // The elements by type, ID and period, then their names compared
        // in the test: a failure prints no name.
        String key(PlannedElement e) =>
            '${e.typeName} ${e.id} '
            '${e.period.from.toUtc()} ${e.period.to.toUtc()}';
        expect(weekAfter.map(key).toList(), weekBefore.map(key).toList());
        for (var i = 0; i < weekBefore.length; i++) {
          expectSameUnshown(
            weekAfter[i].name,
            weekBefore[i].name,
            reason: 'element ${weekBefore[i].id} is named otherwise',
          );
        }
        expect(attempts.writesSince(0), isEmpty);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
