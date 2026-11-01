// The live learning goals of a lesfiche (#223): a lesson lesfiche made in
// the own library ("Mijn lesfiches") with a goal of the goal selector in the
// create, its goals changed (`change-goals`), read back and named with
// GoalService.resolve, and cleared again, against the live Lesfiches module
// of credentials.yml; at the end it is moved to the module's trash.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lesson_content_goals_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// The own library is private to the teacher: a create puts a lesfiche
// there, and nowhere else. The run writes only to the lesfiche it made
// itself, named "[dartschool test] <run tag> ...", and moves it to the
// trash (`lesson-content/trash/bulk`) at the end, also when a test failed,
// and checks that the library no longer lists it. The goals it sends are
// goals the goal selector offers (read with GETs), and one made-up goal ID
// to see what the module makes of a goal it does not know. LiveWireGuard
// (support/live_wire_guard.dart) refuses on the wire any lesfiche write but
// those, and any goal not in the shape the library sends. As every live
// run, it takes the lock of the session first, logs in at most once, and
// prints no credential, no cookie and no name.
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

/// A goal ID that names no goal.
const _madeUpGoalId = '00000000-0000-4000-8000-0000000000aa';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, the goals of a lesfiche in the own library (#223):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;
      late GoalService goalService;

      /// Two goals of one curriculum, and a goal of another curriculum when
      /// the selector offers one.
      late List<LearningGoalRef> goals;
      LearningGoalRef? elsewhere;

      /// The lesfiche the first test made, and whether it is in the trash.
      LessonContentDetail? lesson;
      var trashed = false;

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      LessonContentDetail madeLesson() {
        final fiche = lesson;
        expect(fiche, isNotNull, reason: 'the first test made the lesfiche');
        return fiche!;
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lessonContent = LessonContentService(run.client);
        goalService = GoalService(run.client);
        final found = <LearningGoalRef>[];
        search:
        for (final group in await goalService.getCurricula()) {
          for (final item in group.curricula) {
            final tree = await goalService.getCurriculum(item.id);
            final refs = [
              for (final goal in tree.goals)
                if (!goal.node.isDeprecated) goal.ref,
            ];
            if (found.isEmpty && refs.length >= 2) {
              found.addAll(refs.take(2));
            } else if (found.isNotEmpty && refs.isNotEmpty) {
              elsewhere = refs.first;
              break search;
            }
          }
        }
        if (found.isEmpty) {
          throw StateError('No curriculum of the selector has two goals.');
        }
        goals = found;
      });

      tearDownAll(() async {
        try {
          final fiche = lesson;
          if (fiche != null) {
            if (!trashed) await lessonContent.trash([fiche]);
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

      test('createLesson sends a goal in the create, and the lesfiche has '
          'it, as getDetail reads it', () async {
        final detail = await lessonContent.createLesson(
          name: name('doelen'),
          goals: [goals.first],
        );
        lesson = detail;

        expect(detail.goals, [goals.first]);
        final read = await lessonContent.getDetail(detail);
        expect(read.goals, [goals.first]);
        expect(run.guard.violations, isEmpty);
      });

      test('changeGoals replaces the goals with the list sent; getDetail '
          'reads them after, and GoalService.resolve names each', () async {
        final sent = [...goals, ?elsewhere];
        final changed = await lessonContent.changeGoals(madeLesson(), sent);
        expect(changed.goals.toSet(), sent.toSet());

        final read = await lessonContent.getDetail(changed);
        expect(read.goals.toSet(), sent.toSet());
        final named = await goalService.resolve(read.goals);
        for (final goal in sent) {
          expect(
            GoalService.findGoal(named, goal),
            isNotNull,
            reason: 'goal ${goal.id}',
          );
        }

        final fewer = await lessonContent.changeGoals(read, [goals.last]);
        expect(fewer.goals, [goals.last]);
        expect(run.guard.violations, isEmpty);
      });

      test('a goal ID the curriculum does not have: the module stores it '
          'without complaint, and resolve does not name it', () async {
        final madeUp = LearningGoalRef(
          id: _madeUpGoalId,
          leerplanId: goals.first.leerplanId,
          type: goals.first.type,
        );

        final changed = await lessonContent.changeGoals(madeLesson(), [
          goals.first,
          madeUp,
        ]);

        expect(changed.goals.toSet(), {goals.first, madeUp});
        final named = await goalService.resolve(changed.goals);
        expect(GoalService.findGoal(named, goals.first), isNotNull);
        expect(GoalService.findGoal(named, madeUp), isNull);
        expect(run.guard.violations, isEmpty);
      });

      test('changeGoals with no goals clears them', () async {
        final cleared = await lessonContent.changeGoals(madeLesson(), const []);
        expect(cleared.goals, isEmpty);
        final read = await lessonContent.getDetail(cleared);
        expect(read.goals, isEmpty);

        await lessonContent.trash([read]);
        trashed = true;
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
