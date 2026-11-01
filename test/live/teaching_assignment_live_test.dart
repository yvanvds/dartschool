// The live year plans of the Lesfiches module (#229): a teaching assignment
// named after the run (`createTeachingAssignment`, the content filter
// `all`), a lesson cluster in it (`addCluster`), a title, a lesson lesfiche
// the run makes in the own library and a learning goal in that cluster
// (`addTitle`, `addLessonContent`, `changeClusterGoals`), and the reads of
// all of them, against the live Lesfiches module of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/teaching_assignment_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// The names are short: the module takes 50 characters at most for a
// teaching assignment, a cluster and a title, and the run's tag takes 43.
//
// The own library and the teaching assignments of a teacher are private to
// the teacher (until shared; the run shares nothing). The run writes only to
// what it made itself, each named "[dartschool test] <run tag> ...": one
// teaching assignment, one cluster in it, one lesfiche. At the end, also
// when a test failed, it deletes the teaching assignment (with its cluster)
// and moves the lesfiche to the trash, and checks that neither is listed
// any more. LiveWireGuard (support/live_wire_guard.dart) refuses on the wire
// any teaching assignment or lesfiche write but those. As every live run, it
// takes the lock of the session first, logs in at most once, and prints no
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
import 'support/live_wire_guard.dart';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, a teaching assignment with a lesson cluster in the own library '
    '(#229):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;
      late TeachingAssignmentService plans;

      /// A goal of the goal selector.
      late LearningGoalRef goal;

      /// What the run made.
      LessonContentDetail? lesson;
      TeachingAssignment? plan;
      LessonCluster? unit;

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      T done<T>(T? value) {
        expect(value, isNotNull, reason: 'an earlier test made it');
        return value as T;
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lessonContent = LessonContentService(run.client);
        plans = TeachingAssignmentService(run.client);
        final goals = GoalService(run.client);
        LearningGoalRef? found;
        search:
        for (final group in await goals.getCurricula()) {
          for (final item in group.curricula) {
            final tree = await goals.getCurriculum(item.id);
            for (final selectable in tree.goals) {
              if (!selectable.node.isDeprecated) {
                found = selectable.ref;
                break search;
              }
            }
          }
        }
        if (found == null) {
          throw StateError('No curriculum of the selector has a goal.');
        }
        goal = found;
      });

      tearDownAll(() async {
        try {
          final made = plan;
          if (made != null) {
            await plans.deleteTeachingAssignment(made);
            final listed = await plans.getTeachingAssignments();
            expect(listed.map((p) => p.id), isNot(contains(made.id)));
          }
          final fiche = lesson;
          if (fiche != null) {
            await lessonContent.trash([fiche]);
            final listed = {
              for (final item in await lessonContent.getItems(
                withCourseNames: false,
              ))
                item.id,
            };
            expect(listed, isNot(contains(fiche.id)));
          }
        } finally {
          await started?.close();
        }
      });

      test('createTeachingAssignment makes a teaching assignment named after '
          'the run, which getTeachingAssignments and getTeachingAssignment '
          'read', () async {
        lesson = await lessonContent.createLesson(name: name('les'));
        final made = plan = await plans.createTeachingAssignment(
          name: name('plan'),
        );

        expect(made.name, name('plan'));
        expect(made.contentFilter, TeachingAssignmentContentFilter.all);
        expect(made.clusters, isEmpty);
        final listed = await plans.getTeachingAssignments();
        expect(listed.where((p) => p.id == made.id), hasLength(1));
        final read = await plans.getTeachingAssignment(made);
        expect(read.name, made.name);
        expect(read.ownerId, made.ownerId);
      });

      test('getLessonContent lists the lesfiche of the run (the filter '
          'all)', () async {
        final made = done(plan);
        final fiche = done(lesson);
        final items = await plans.getLessonContent(made);
        expect(items.map((i) => i.id), contains(fiche.id));
        expect(items.firstWhere((i) => i.id == fiche.id).ownerId, made.ownerId);
      });

      test('addCluster adds a cluster, which getClusters, getCluster and '
          'getTeachingAssignment read', () async {
        final made = done(plan);
        final cluster = unit = await plans.addCluster(made, name: name('unit'));

        expect(cluster.name, name('unit'));
        expect(cluster.teachingAssignment, made);
        expect(cluster.numberOfLessons, 0);
        final clusters = await plans.getClusters(made);
        expect(clusters.map((c) => c.id), [cluster.id]);
        expect((await plans.getCluster(cluster)).name, cluster.name);
        final read = await plans.getTeachingAssignment(made);
        expect(read.clusters.single == cluster, isTrue);
      });

      test('addTitle and addLessonContent fill the cluster, which '
          'getClusterContent reads in order', () async {
        final cluster = done(unit);
        final fiche = done(lesson);

        final title = await plans.addTitle(cluster, name('w1'));
        expect(title.text, name('w1'));
        final added = await plans.addLessonContent(cluster, [fiche]);
        expect(added.map((i) => i.id), [fiche.id]);

        final entries = await plans.getClusterContent(cluster);
        expect(entries, hasLength(2));
        expect((entries.first as LessonClusterTitle).id, title.id);
        final entry = entries.last as LessonClusterLesfiche;
        expect(entry.item.id, fiche.id);
        expect(entry.lessonClusterId, cluster.id);
        expect(entries.map((e) => e.position), [0, 1]);
        expect((await plans.getCluster(cluster)).numberOfLessons, 1);
      });

      test('changeClusterGoals sets a goal, which getCluster and '
          'getClusterGoals read, and an empty list clears it', () async {
        final cluster = done(unit);

        final changed = await plans.changeClusterGoals(cluster, [goal]);
        expect(changed.goals, [goal]);
        expect((await plans.getCluster(cluster)).goals, [goal]);
        final goals = await plans.getClusterGoals(cluster);
        expect(goals.map((g) => g.goal), [goal]);

        final cleared = await plans.changeClusterGoals(cluster, const []);
        expect(cleared.goals, isEmpty);
      });
    },
  );
}
