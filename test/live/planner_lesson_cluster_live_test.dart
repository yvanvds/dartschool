// The live plan of a lesson cluster for a class over a week (#230): a
// teaching assignment and a lesson cluster named after the run, with a
// lesson lesfiche of the run in it (#229), planned with
// PlannerService.planLessonCluster for the classes and course of a lesson
// hour of the own planner, over one week far ahead; read back with
// getPlannedLessonClusters, getPlannedLessonClustersOf, getDetail and the
// week's elements (the planner's lesson-cluster moments); and moved to the
// planner's trash again with trashPlannedLessonCluster, after which the
// week is as before. Against the live planner of credentials.yml.
//
// **Opt-in twice**: local and on demand only, as messages_live_test.dart
// (see there and dart_test.yaml), and only with
// DARTSCHOOL_LIVE_PLAN_CLUSTER=1 in the environment, since pupils of the
// class see the moments of a planned cluster while it is planned:
//
//   DARTSCHOOL_LIVE_PLAN_CLUSTER=1 \
//     dart test -P live test/live/planner_lesson_cluster_live_test.dart
//
// Without a credentials.yml in the package root, or without that variable,
// it skips.
//
// The week is the first one, from five weeks ahead on and in this school
// year, that has an own timetable slot with a class and a course and no
// planned cluster yet; LiveWireGuard refuses a plan that starts sooner than
// four weeks from today, of another cluster than the run's, for users, or
// over more than a week. The run writes only to what it made itself, each
// named "[dartschool test] <run tag> ...". At the end, also when a test
// failed, it moves the planned cluster to the planner's trash, deletes the
// teaching assignment (with its cluster) and moves the lesfiche to the
// trash, and checks that the teaching assignment is not listed any more.
// As every live run, it takes the lock of the session first, logs in at
// most once, and prints no credential, no cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/live_wire_guard.dart';

/// The variable that lets this file plan a lesson cluster (#230).
const _optInVariable = 'DARTSCHOOL_LIVE_PLAN_CLUSTER';

void main() {
  final credentials = liveCredentialsFile();
  final optedIn = Platform.environment[_optInVariable]?.trim() == '1';

  group(
    'live, a lesson cluster planned for a class over a week (#230):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : !optedIn
        ? 'plans a lesson cluster that pupils of a class see while it is '
              'planned; set $_optInVariable=1 to run it'
        : null,
    timeout: const Timeout(Duration(minutes: 4)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;
      late TeachingAssignmentService plans;
      late PlannerService planner;
      late PlannerCalendar own;

      /// The week planned in: Monday to Friday.
      late DateTime monday;
      late DateTime friday;

      /// The own timetable slot whose classes and course the cluster is
      /// planned for.
      late PlannedElement slot;

      /// The week's elements before the plan.
      late List<PlannedElement> before;

      /// What the run made.
      LessonContentDetail? lesson;
      TeachingAssignment? plan;
      LessonCluster? unit;
      PlannedLessonCluster? planned;
      var trashed = false;

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      T done<T>(T? value) {
        expect(value, isNotNull, reason: 'an earlier test made it');
        return value as T;
      }

      Future<List<PlannedElement>> week() => planner.getPlannedElements(
        own,
        from: monday,
        to: DateTime(friday.year, friday.month, friday.day, 23, 59, 59),
      );

      /// The week's elements, read until [settled] holds for them (the list
      /// lags behind a change for a few seconds), at most about 30 seconds.
      Future<List<PlannedElement>> weekUntil(
        bool Function(List<PlannedElement> elements) settled,
      ) async {
        var elements = await week();
        for (var i = 0; i < 15 && !settled(elements); i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          elements = await week();
        }
        return elements;
      }

      /// The timetable slots of [elements] by their start, courses and
      /// classes: a slot that comes back may have a new ID.
      List<String> slotsOf(List<PlannedElement> elements) => [
        for (final element in elements)
          if (element.type == PlannedElementType.placeholder)
            '${element.period.from.toIso8601String()} '
                '${element.courses.map((c) => c.id).join(',')} '
                '${element.participantGroups.map((g) => g.id).join(',')}',
      ]..sort();

      bool hasMoments(List<PlannedElement> elements) =>
          elements.any((e) => e.type == PlannedElementType.lessonClusterMoment);

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lessonContent = LessonContentService(run.client);
        plans = TeachingAssignmentService(run.client);
        planner = PlannerService(run.client);
        own = await planner.ownCalendar();

        // The first week, five weeks ahead or later and in this school
        // year, with an own slot of a class and a course and no planned
        // cluster.
        final today = DateTime.now();
        final schoolYearEnd = DateTime(
          today.month >= DateTime.september ? today.year + 1 : today.year,
          6,
          20,
        );
        var start = DateTime(
          today.year,
          today.month,
          today.day + 35 - (today.weekday - 1),
        );
        PlannedElement? found;
        while (found == null && start.isBefore(schoolYearEnd)) {
          monday = start;
          friday = DateTime(start.year, start.month, start.day + 4);
          before = await week();
          if (!hasMoments(before)) {
            found = before
                .where(
                  (e) =>
                      e.type == PlannedElementType.placeholder &&
                      e.participantGroups.isNotEmpty &&
                      e.courses.isNotEmpty,
                )
                .firstOrNull;
          }
          start = DateTime(start.year, start.month, start.day + 7);
        }
        if (found == null) {
          throw StateError(
            'No week of this school year, five weeks ahead or later, has an '
            'own timetable slot with a class and a course.',
          );
        }
        slot = found;

        lesson = await lessonContent.createLesson(name: name('les'));
        plan = await plans.createTeachingAssignment(name: name('plan'));
        unit = await plans.addCluster(plan!, name: name('unit'));
        await plans.addLessonContent(unit!, [lesson!]);
      });

      tearDownAll(() async {
        try {
          final made = planned;
          if (made != null && !trashed) {
            await planner.trashPlannedLessonCluster(made);
          }
          final madePlan = plan;
          if (madePlan != null) {
            await plans.deleteTeachingAssignment(madePlan);
            final listed = await plans.getTeachingAssignments();
            expect(listed.map((p) => p.id), isNot(contains(madePlan.id)));
          }
          final fiche = lesson;
          if (fiche != null) await lessonContent.trash([fiche]);
          expect(run.guard.plannedLessonClustersMade, isEmpty);
        } finally {
          await started?.close();
        }
      });

      test('planLessonCluster plans the cluster for the slot\'s classes and '
          'course over the week, linked to the cluster', () async {
        final cluster = done(unit);
        final groups = [for (final group in slot.participantGroups) group.id];

        final made = planned = await planner.planLessonCluster(
          cluster: cluster,
          from: monday,
          to: friday,
          groupIds: groups,
          courses: slot.courses,
        );

        expect(made.type, PlannedElementType.lessonCluster);
        expect(made.lessonCluster, cluster);
        expect(made.isCrossCurricular, isFalse);
        expect(made.period.wholeDay, isTrue);
        expect(made.period.from, monday);
        expect(
          made.period.to,
          DateTime(friday.year, friday.month, friday.day, 23, 59, 59),
        );
        expect(
          made.participantGroups.map((g) => g.id).toSet(),
          containsAll(groups),
        );
        expect(made.courses.map((c) => c.id), contains(slot.courses.first.id));
        expect(made.plannedContent, hasLength(1));
        expect(run.guard.plannedLessonClustersMade, {made.id.toLowerCase()});
      });

      test('the week shows lesson-cluster moments in the class\'s hours, and '
          'the cluster is listed and read back', () async {
        final made = done(planned);

        final elements = await weekUntil(hasMoments);
        final moments = [
          for (final e in elements)
            if (e.type == PlannedElementType.lessonClusterMoment) e,
        ];
        expect(moments, isNotEmpty);
        for (final moment in moments) {
          expect(
            moment.plannedLessonClusters?.map((c) => c.id.toLowerCase()),
            contains(made.id.toLowerCase()),
          );
        }
        expect(slotsOf(elements).length, lessThan(slotsOf(before).length));

        final listed = await planner.getPlannedLessonClusters(
          from: monday,
          to: friday,
        );
        expect(listed.map((c) => c.id), contains(made.id));
        // The list gives the short form, which names no cluster.
        expect(listed.firstWhere((c) => c.id == made.id).name, made.name);

        final instances = await planner.getPlannedLessonClustersOf(done(unit));
        expect(instances.map((c) => c.id), [made.id]);
        expect(instances.single.lessonCluster, done(unit));

        final detail = await planner.getDetail(made);
        expect(detail, isA<PlannedLessonCluster>());
        expect((detail as PlannedLessonCluster).lessonCluster, done(unit));
      });

      test('trashPlannedLessonCluster moves it to the trash: the list no '
          'longer has it and the week is as before', () async {
        final made = done(planned);

        await planner.trashPlannedLessonCluster(made);
        trashed = true;

        expect(run.guard.plannedLessonClustersMade, isEmpty);
        final listed = await planner.getPlannedLessonClusters(
          from: monday,
          to: friday,
        );
        expect(listed.map((c) => c.id), isNot(contains(made.id)));
        expect(await planner.getPlannedLessonClustersOf(done(unit)), isEmpty);
        final wanted = slotsOf(before);
        final elements = await weekUntil(
          (elements) =>
              slotsOf(elements).join('\n') == wanted.join('\n') &&
              !hasMoments(elements),
        );
        expect(slotsOf(elements), wanted);
        expect(hasMoments(elements), isFalse);
      });
    },
  );
}
