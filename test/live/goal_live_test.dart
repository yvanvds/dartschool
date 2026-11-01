// The live goal selector (#222): what GoalService reads of the curricula and
// learning goals that the Lesfiches module and the planner offer, for the
// account of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/goal_live_test.dart` alone. Without a
// credentials.yml in the package root, it skips.
//
// It only reads: the list of curricula and one curriculum with GETs, and
// the naming of a selection of goals with the selector's one POST that
// reads (`"isView": true`), which LiveWireGuard (support/live_wire_guard.dart)
// lets out as the only POST to the goal selector. It never marks a
// favourite or saves the selector's settings. As every live run, it takes
// the lock of the session first, logs in at most once, and prints no
// credential and no cookie; a curriculum and a goal are shown by their IDs.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

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
      late GoalService goals;
      late List<CurriculumGroup> groups;

      setUpAll(() async {
        final run = started = await LiveRun.start(credentials!);
        goals = GoalService(run.client);
        groups = await goals.getCurricula();
      });

      tearDownAll(() async {
        await started?.close();
      });

      /// The first curriculum of the list that has a goal, as a tree.
      Future<Curriculum?> firstWithGoals() async {
        for (final group in groups) {
          for (final item in group.curricula) {
            final tree = await goals.getCurriculum(item.id);
            if (tree.goals.isNotEmpty) return tree;
          }
        }
        return null;
      }

      test('getCurricula: groups of curricula, each with an ID and a '
          'title; the planner lists the same', () async {
        expect(groups, isNotEmpty);
        for (final group in groups) {
          expect(group.name, isNotEmpty);
          for (final item in group.curricula) {
            expect(item.id, isNotEmpty);
            expect(item.title, isNotEmpty, reason: 'curriculum ${item.id}');
          }
        }
        final planner = await goals.getCurricula(
          location: GoalLocation.plannerLessonContent,
        );
        expect(
          planner.expand((g) => g.curricula).map((c) => c.id),
          groups.expand((g) => g.curricula).map((c) => c.id),
        );
      });

      test('getCurriculum: a tree whose goals have a title, a leerplanType '
          'and the curriculum\'s ID in their reference', () async {
        final tree = await firstWithGoals();
        if (tree == null) {
          markTestSkipped('no curriculum of the list has a goal');
          return;
        }
        expect(tree.leerplanType, isNotEmpty);
        expect(tree.selectableTypes, contains('goal'));
        for (final goal in tree.goals) {
          expect(tree.selectableTypes, contains(goal.node.typeName));
          expect(goal.node.text, isNotEmpty, reason: 'goal ${goal.node.id}');
          expect(goal.ref.leerplanId, tree.id);
          expect(goal.ref.type, tree.leerplanType);
        }
      });

      test('getCurriculum: an unknown ID is a '
          'SmartschoolCurriculumNotFoundError', () async {
        await expectLater(
          goals.getCurriculum('00000000-0000-4000-8000-000000000000'),
          throwsA(isA<SmartschoolCurriculumNotFoundError>()),
        );
      });

      test('resolve names a goal of a curriculum with the same title and '
          'the nodes above it', () async {
        final tree = await firstWithGoals();
        if (tree == null) {
          markTestSkipped('no curriculum of the list has a goal');
          return;
        }
        final goal = tree.goals.last;

        final named = await goals.resolve([goal.ref]);

        expect(named.map((c) => c.id), [tree.id]);
        final found = GoalService.findGoal(named, goal.ref);
        expect(found, isNotNull, reason: 'goal ${goal.node.id}');
        expect(found!.node.title, goal.node.title);
        expect(found.path.map((n) => n.id), goal.path.map((n) => n.id));
        expect(named.single.goals, hasLength(1));
      });
    },
  );
}
