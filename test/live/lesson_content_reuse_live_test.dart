// The live reuse of lesfiches (#227): a lesson lesfiche made in the own
// library ("Mijn lesfiches") with a course, a learning goal, a weblink and
// an attachment, duplicated (`lesson-content/duplicate/bulk`), both moved to
// the module's trash, read back from the trash (`lesson-content/trashed`),
// the copy restored (`lesson-content/restore/bulk`) and moved to the trash
// again, against the live Lesfiches module of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lesson_content_reuse_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// The own library is private to the teacher: a create and a duplicate put a
// lesfiche there, and nowhere else. The run writes only to the lesfiche it
// made itself, named "[dartschool test] <run tag> ...", and to its copy;
// it restores only the copy it moved to the trash, and moves both to the
// trash at the end, also when a test failed, and checks that the library no
// longer lists them. It never deletes a lesfiche for good. LiveWireGuard
// (support/live_wire_guard.dart) refuses on the wire any lesfiche write but
// those. As every live run, it takes the lock of the session first, logs in
// at most once, and prints no credential, no cookie and no name.
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

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, duplicate, trash and restore in the own library (#227):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;

      /// A named course of the school, for the lesfiche's course.
      late PlannerCourse course;

      /// A goal of the goal selector, for the lesfiche's goals.
      late LearningGoalRef goal;

      /// The file attached to the lesfiche.
      late File local;

      /// The lesfiche and its copy, and those that are in the trash.
      LessonContentDetail? lesson;
      LessonContentDetail? copy;
      final trashed = <String>{};

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      T made<T>(T? fiche) {
        expect(fiche, isNotNull, reason: 'an earlier test made it');
        return fiche as T;
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lessonContent = LessonContentService(run.client);
        course = (await lessonContent.getCourses()).firstWhere(
          (course) => course.name.isNotEmpty,
        );
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
        local = await run.attachment('kopie');
      });

      tearDownAll(() async {
        try {
          final fiches = [?lesson, ?copy];
          final left = [
            for (final fiche in fiches)
              if (!trashed.contains(fiche.id)) fiche,
          ];
          if (left.isNotEmpty) await lessonContent.trash(left);
          if (fiches.isNotEmpty) {
            final listed = {
              for (final item in await lessonContent.getItems(
                withCourseNames: false,
              ))
                item.id,
            };
            expect([
              for (final fiche in fiches)
                if (listed.contains(fiche.id)) fiche.id,
            ], isEmpty);
          }
        } finally {
          await started?.close();
        }
      });

      test('duplicate makes a copy in the own library with a new ID, named '
          '"<name> - kopie", with the info, course, goal, weblink and '
          'attachment of the lesfiche, as getDetail and getItems show '
          'it', () async {
        final fiche = lesson = await lessonContent.createLesson(
          name: name('kopie'),
          publicInfo: '<p>Live test of #227, run ${run.tag}.</p>',
          privateInfo: '<p>private info</p>',
          courseIds: [course.id],
          goals: [goal],
          weblinks: [
            const NewLessonContentWeblink(
              name: 'dartschool weblink',
              url: 'https://example.com/dartschool',
              visibility: LessonContentVisibility.atEnd,
            ),
          ],
          attachments: [
            NewLessonContentAttachment(
              local.path,
              visibility: LessonContentVisibility.never,
            ),
          ],
        );
        final items = await lessonContent.getItems();
        final source = items.singleWhere((item) => item.id == fiche.id);

        final duplicated = copy = (await lessonContent.duplicate([
          source,
        ])).single;

        expect(duplicated.id, isNot(fiche.id));
        expect(duplicated.type, LessonContentType.lesson);
        expect(duplicated.name, '${name('kopie')} - kopie');
        expect(duplicated.icon, fiche.icon);
        expect(duplicated.publicInfo, fiche.publicInfo);
        expect(duplicated.privateInfo, fiche.privateInfo);
        expect(duplicated.isVisible, isTrue);
        expect(duplicated.courses.map((c) => (c.id, c.name)), [
          (course.id, course.name),
        ]);
        expect(duplicated.goals, [goal]);
        final link = duplicated.weblinks.single;
        expect(link.id, isNot(fiche.weblinks.single.id));
        expect(
          (link.name, link.url, link.visibility),
          (
            'dartschool weblink',
            'https://example.com/dartschool',
            LessonContentVisibility.atEnd,
          ),
        );
        expect(duplicated.attachments.map((a) => (a.fileName, a.visibility)), [
          (local.uri.pathSegments.last, LessonContentVisibility.never),
        ]);

        final read = await lessonContent.getDetail(duplicated);
        expect(read.name, duplicated.name);
        expect(read.goals, [goal]);
        expect(
          read.attachments.map((a) => a.fileName),
          duplicated.attachments.map((a) => a.fileName),
        );
        expect(
          await lessonContent.downloadAttachment(
            read,
            read.attachments.single.id,
          ),
          await local.readAsBytes(),
        );
        final listed = await lessonContent.getItems(withCourseNames: false);
        expect(listed.map((item) => item.id), containsAll([fiche.id, read.id]));
        expect(run.guard.violations, isEmpty);
      });

      test('getTrash lists both after their move to the trash, with the date '
          'of the move, and getItems no longer does', () async {
        final fiche = made(lesson);
        final duplicated = made(copy);
        // The module gives the date without a time zone: allow for one.
        final before = DateTime.now().subtract(const Duration(hours: 3));

        await lessonContent.trash([fiche, duplicated]);
        trashed.addAll([fiche.id, duplicated.id]);

        final trash = await lessonContent.getTrash();
        final ours = trash
            .where((item) => item.id == fiche.id || item.id == duplicated.id)
            .toList();
        expect(ours.map((item) => item.name).toSet(), {
          fiche.name,
          duplicated.name,
        });
        for (final item in ours) {
          expect(item.type, LessonContentType.lesson);
          expect(item.dateStateChanged, isNotNull);
          expect(item.dateStateChanged!.isAfter(before), isTrue);
          expect(item.courses.map((c) => c.name), [course.name]);
        }
        final listed = await lessonContent.getItems(withCourseNames: false);
        expect(
          listed.map((item) => item.id),
          isNot(anyOf(contains(fiche.id), contains(duplicated.id))),
        );
        expect(run.guard.violations, isEmpty);
      });

      test('restore takes the copy out of the trash: getItems lists it again '
          'and getTrash no longer does; it can be moved to the trash '
          'again', () async {
        final duplicated = made(copy);
        final inTrash = (await lessonContent.getTrash(
          withCourseNames: false,
        )).singleWhere((item) => item.id == duplicated.id);

        await lessonContent.restore([inTrash]);
        trashed.remove(duplicated.id);

        final listed = await lessonContent.getItems(withCourseNames: false);
        expect(listed.map((item) => item.id), contains(duplicated.id));
        final trash = await lessonContent.getTrash(withCourseNames: false);
        expect(trash.map((item) => item.id), isNot(contains(duplicated.id)));
        expect(
          trash.map((item) => item.id),
          contains(made(lesson).id),
          reason: 'only the copy was restored',
        );

        await lessonContent.trash([duplicated]);
        trashed.add(duplicated.id);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
