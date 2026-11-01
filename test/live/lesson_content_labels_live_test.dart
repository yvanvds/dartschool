// The live labels of lesfiches (#228): the labels a lesfiche can get (the
// school's for the Lesfiches module and the own ones, `getLabels`), a lesson
// lesfiche made in the own library ("Mijn lesfiches") with a label that
// exists already, a new own label named after the run (`createUserLabel`),
// both put on the lesfiche and taken off again (`changeLabels`), against the
// live Lesfiches and labels modules of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lesson_content_labels_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// The own library is private to the teacher, and so are the own labels. The
// run writes only to the lesfiche it made itself, named "[dartschool test]
// <run tag> ...", puts on it only a label that exists and the one label it
// made, named "[dartschool test] <run tag>"; at the end, also when a test
// failed, it moves the lesfiche to the trash and removes its label again
// (`DELETE /labels/api/v1/user/{id}`, the web client's removal; the library
// does not remove labels), and checks that neither is listed any more.
// LiveWireGuard (support/live_wire_guard.dart) refuses on the wire any
// lesfiche or label write but those. As every live run, it takes the lock of
// the session first, logs in at most once, and prints no credential, no
// cookie and no name.
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
    'live, the labels of a lesfiche in the own library (#228):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;

      /// The labels as read at the start.
      late List<LessonContentLabel> labels;

      /// A label that exists already: a school label, or else an own one.
      LessonContentLabel? existing;

      /// The lesfiche and the own label the run made.
      LessonContentDetail? lesson;
      LessonContentLabel? made;

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      T done<T>(T? value) {
        expect(value, isNotNull, reason: 'an earlier test made it');
        return value as T;
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        lessonContent = LessonContentService(run.client);
        labels = await lessonContent.getLabels();
        existing =
            labels.where((l) => l.isSchoolLabel).firstOrNull ??
            labels.where((l) => l.isUserLabel).firstOrNull;
      });

      tearDownAll(() async {
        try {
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
          final label = made;
          if (label != null) {
            final removed = await run.client.deleteResponse(
              '/labels/api/v1/user/${label.id}',
              retryAfterLogin: false,
            );
            expect(removed.statusCode, anyOf(200, 204));
            final left = await lessonContent.getLabels();
            expect(left.map((l) => l.id), isNot(contains(label.id)));
          }
        } finally {
          await started?.close();
        }
      });

      test('getLabels reads the school labels, then the own ones, each of a '
          'known kind with an ID, a text and a colour', () {
        expect(labels, isNotEmpty, reason: 'the account has labels');
        expect(labels.every((l) => l.isSchoolLabel || l.isUserLabel), isTrue);
        final kinds = [for (final l in labels) l.isSchoolLabel];
        expect(kinds, [
          ...kinds.where((s) => s),
          ...kinds.where((s) => !s),
        ], reason: 'the school labels come first');
        for (final label in labels) {
          expect(label.id, isNotEmpty);
          expect(label.text, isNotEmpty);
          expect(LessonContentService.labelColors, contains(label.color));
          if (label.isUserLabel) {
            expect(label.userId, isNotNull);
            expect(label.id, startsWith('${label.userId}_'));
          } else {
            expect(label.platformId, isNotNull);
          }
        }
      });

      test('createLesson with a label that exists makes a lesfiche with that '
          'label', () async {
        final label = existing;
        expect(label, isNotNull, reason: 'the account has a label');
        final fiche = lesson = await lessonContent.createLesson(
          name: name('labels'),
          labels: [label!],
        );

        expect(fiche.labels.map((l) => l.id), [label.id]);
        final read = await lessonContent.getDetail(fiche);
        expect(read.labels.map((l) => l.id), [label.id]);
      });

      test('createUserLabel makes an own label named after the run, which '
          'getLabels then lists', () async {
        final label = made = await lessonContent.createUserLabel(
          name(''),
          color: 'aqua',
        );

        expect(label.isUserLabel, isTrue);
        expect(label.text, name('').trim());
        expect(label.color, 'aqua');
        final listed = await lessonContent.getLabels();
        expect(listed.where((l) => l.id == label.id), hasLength(1));
      });

      test('changeLabels puts the label that exists and the own label on the '
          'lesfiche, and an empty list takes them off', () async {
        final fiche = done(lesson);
        final own = done(made);
        final label = existing!;

        final labelled = await lessonContent.changeLabels(fiche, [label, own]);
        expect(labelled.labels.map((l) => l.id).toSet(), {label.id, own.id});
        final read = await lessonContent.getDetail(fiche);
        expect(read.labels.map((l) => l.id).toSet(), {label.id, own.id});

        final cleared = await lessonContent.changeLabels(fiche, const []);
        expect(cleared.labels, isEmpty);
        expect((await lessonContent.getDetail(fiche)).labels, isEmpty);
      });
    },
  );
}
