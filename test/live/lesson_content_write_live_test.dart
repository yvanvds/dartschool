// The live writes of LessonContentService (#129): a lesson lesfiche made in
// the own library ("Mijn lesfiches") with a course, a weblink and an
// attachment in one create, read back, changed (name, icon, info, courses,
// visibility, weblinks, attachments), its attachment downloaded back, an
// assignment lesfiche made, and both moved to the module's trash again,
// against the live Lesfiches module of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/lesson_content_write_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// The own library is private to the teacher: a create puts a lesfiche
// there, and nowhere else. The run writes only to the lesfiches it made
// itself, named "[dartschool test] <run tag> ...", with files named
// "dartschool-test-<run tag>-....txt", and moves every one of them to the
// trash (`lesson-content/trash/bulk`) at the end, also when a test failed,
// and checks that the library no longer lists them. It never deletes a
// lesfiche for good, never shares or plans one, never puts one into a year
// plan, and sends no label or goal. LiveWireGuard
// (support/live_wire_guard.dart) refuses on the wire any lesfiche write but
// those, on a lesfiche the run did not make (as Smartschool answered its
// creates), or after its move to the trash. As every live run, it takes the
// lock of the session first, logs in at most once, and prints no
// credential, no cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

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

  /// The requests tried since [from] to the Lesfiches module that are not
  /// GETs.
  List<String> writesSince(int from) => [
    for (final request in requests.skip(from))
      if (!request.startsWith('GET ') && request.contains(' /lesson-content/'))
        request,
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

/// An ID that names no lesfiche.
const _noSuchId = '00000000-0000-4000-8000-000000000000';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, in the own library of lesfiches (#129):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late LessonContentService lessonContent;
      late _Attempts attempts;

      /// Two of the school's courses, for the lesfiche's courses.
      late List<PlannerCourse> courses;

      /// The file attached to the lesson lesfiche.
      late File local;

      /// The lesfiches the run made, in order, and those it moved to the
      /// trash already.
      final made = <LessonContentItem>[];
      final trashed = <String>{};

      /// The lesson lesfiche the first test made.
      LessonContentDetail? lesson;

      String name(String what) => '$liveLessonContentPrefix ${run.tag} $what';

      LessonContentDetail madeLesson() {
        final fiche = lesson;
        expect(fiche, isNotNull, reason: 'the first test made the lesfiche');
        return fiche!;
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        lessonContent = LessonContentService(run.client);
        courses = (await lessonContent.getCourses())
            .where((course) => course.name.isNotEmpty)
            .take(2)
            .toList();
        if (courses.length < 2) {
          throw StateError('The school has fewer than two named courses.');
        }
        local = await run.attachment('lesfiche');
      });

      tearDownAll(() async {
        try {
          final left = [
            for (final item in made)
              if (!trashed.contains(item.id)) item,
          ];
          Object? failure;
          if (left.isNotEmpty) {
            try {
              await lessonContent.trash(left);
              trashed.addAll(left.map((item) => item.id));
            } on Object catch (e) {
              failure = e;
            }
          }
          if (started != null && made.isNotEmpty) {
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
                  'every lesfiche the run made is in the trash again '
                  '(failure: $failure)',
            );
          }
          expect(failure, isNull);
        } finally {
          await started?.close();
        }
      });

      test('createLesson makes a lesfiche in the own library with a course, '
          'a weblink and an attachment in one create, as getDetail and '
          'getItems show it', () async {
        final detail = await lessonContent.createLesson(
          name: name('les'),
          publicInfo:
              '<p>Live test of the dartschool library (#129), run '
              '${run.tag}.</p>',
          privateInfo: '<p>private info</p>',
          courseIds: [courses.first.id],
          weblinks: [
            const NewLessonContentWeblink(
              name: 'dartschool weblink',
              url: 'example.com/dartschool?q=a b',
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
        made.add(detail);
        lesson = detail;

        expect(detail.type, LessonContentType.lesson);
        expect(detail.name, name('les'));
        expect(detail.icon, LessonContentService.defaultLessonIcon);
        expect(detail.publicInfo, contains(run.tag));
        expect(detail.privateInfo, '<p>private info</p>');
        expect(detail.isVisible, isTrue);
        expect(detail.ownerId, (await run.client.authenticatedUser)['id']);
        expect(detail.can('canUserEdit'), isTrue);
        expect(detail.courses.map((c) => (c.id, c.name)), [
          (courses.first.id, courses.first.name),
        ]);
        final link = detail.weblinks.single;
        expect(link.name, 'dartschool weblink');
        expect(link.url, 'http://example.com/dartschool?q=a%20b');
        expect(link.icon, LessonContentService.defaultWeblinkIcon);
        expect(link.visibility, LessonContentVisibility.atEnd);
        final attachment = detail.attachments.single;
        expect(attachment.fileName, local.uri.pathSegments.last);
        expect(attachment.fileSize, await local.length());
        expect(attachment.visibility, LessonContentVisibility.never);

        final read = await lessonContent.getDetail(detail);
        expect(read.name, detail.name);
        expect(read.weblinks.map((w) => w.id), [link.id]);
        expect(read.attachments.map((a) => a.id), [attachment.id]);
        final listed = (await lessonContent.getItems(
          withCourseNames: false,
        )).where((item) => item.id == detail.id).toList();
        expect(listed.map((item) => (item.name, item.weblinkCount)), [
          (name('les'), 1),
        ]);
        expect(listed.single.attachmentCount, 1);
      });

      test('downloadAttachment and downloadAttachmentStream give the file '
          'back unchanged', () async {
        final fiche = madeLesson();
        final attachment = fiche.attachments.single;

        expect(
          await lessonContent.downloadAttachment(fiche, attachment.id),
          await local.readAsBytes(),
        );
        final download = await lessonContent.downloadAttachmentStream(
          fiche,
          attachment.id,
        );
        expect(
          await download.stream.expand((chunk) => chunk).toList(),
          await local.readAsBytes(),
        );
      });

      test('the edits: name, icon, info, courses and visibility, each '
          'answered with the changed lesfiche, as getDetail reads it '
          'after', () async {
        var fiche = await lessonContent.rename(
          madeLesson(),
          name('les (hernoemd)'),
        );
        expect(fiche.name, name('les (hernoemd)'));
        fiche = await lessonContent.changeIcon(fiche, 'book');
        expect(fiche.icon, 'book');
        fiche = await lessonContent.changePublicInfo(
          fiche,
          '<p>nieuwe publieke info</p>',
        );
        expect(fiche.publicInfo, '<p>nieuwe publieke info</p>');
        fiche = await lessonContent.changePrivateInfo(
          fiche,
          '<p>nieuwe private info</p>',
        );
        expect(fiche.privateInfo, '<p>nieuwe private info</p>');
        fiche = await lessonContent.changeCourses(fiche, [
          courses[1].id,
          courses[0].id,
        ]);
        expect(
          {for (final course in fiche.courses) course.id: course.name},
          {for (final course in courses) course.id: course.name},
        );
        fiche = await lessonContent.changeCourses(fiche, const []);
        expect(fiche.courses, isEmpty);
        fiche = await lessonContent.setVisible(fiche, false);
        expect(fiche.isVisible, isFalse);
        fiche = await lessonContent.setVisible(fiche, true);
        expect(fiche.isVisible, isTrue);

        final read = await lessonContent.getDetail(fiche);
        expect(read.name, name('les (hernoemd)'));
        expect(read.icon, 'book');
        expect(read.publicInfo, '<p>nieuwe publieke info</p>');
        expect(read.privateInfo, '<p>nieuwe private info</p>');
        expect(read.courses, isEmpty);
        expect(read.isVisible, isTrue);
        expect(run.guard.violations, isEmpty);
      });

      test('the weblinks: one added, changed and removed again', () async {
        final fiche = madeLesson();

        final added = await lessonContent.addWeblink(
          fiche,
          NewLessonContentWeblink(
            name: 'dartschool weblink 2',
            url: 'https://example.com/2',
            visibility: LessonContentVisibility.afterEnd(3),
          ),
        );
        expect(added.name, 'dartschool weblink 2');
        expect(added.visibility, LessonContentVisibility.afterEnd(3));
        final changed = await lessonContent.changeWeblink(
          fiche,
          added.id,
          const NewLessonContentWeblink(
            name: 'dartschool weblink 2 (gewijzigd)',
            url: 'https://example.com/gewijzigd',
            visibility: LessonContentVisibility.atStart,
          ),
        );
        expect(changed.id, added.id);
        expect(changed.url, 'https://example.com/gewijzigd');
        expect(changed.visibility, LessonContentVisibility.atStart);
        await lessonContent.removeWeblink(fiche, added.id);

        final read = await lessonContent.getDetail(
          fiche,
          withCourseNames: false,
        );
        expect(read.weblinks.map((w) => w.id), [fiche.weblinks.single.id]);
      });

      test('the attachments: one added with a visibility, changed, and '
          'removed again', () async {
        final fiche = madeLesson();
        final second = await run.attachment('lesfiche-2');

        final added = await lessonContent.addAttachments(fiche, [
          NewLessonContentAttachment(
            second.path,
            visibility: LessonContentVisibility.afterEnd(14),
          ),
        ]);
        expect(added.map((a) => a.fileName), [second.uri.pathSegments.last]);
        expect(added.single.fileSize, await second.length());
        expect(added.single.visibility, LessonContentVisibility.afterEnd(14));
        expect(
          await lessonContent.downloadAttachment(fiche, added.single.id),
          await second.readAsBytes(),
        );
        final changed = await lessonContent.changeAttachmentVisibility(
          fiche,
          added.single.id,
          LessonContentVisibility.atStart,
        );
        expect(
          changed.attachments
              .where((a) => a.id == added.single.id)
              .map((a) => a.visibility),
          [LessonContentVisibility.atStart],
        );
        await lessonContent.removeAttachment(fiche, added.single.id);

        final read = await lessonContent.getDetail(
          fiche,
          withCourseNames: false,
        );
        expect(read.attachments.map((a) => a.id), [
          fiche.attachments.single.id,
        ]);
      });

      test('checks before sending: an empty name, an address the web client '
          'refuses and a course the school does not have send no write; a '
          'made-up ID is not found', () async {
        final fiche = madeLesson();
        final mark = attempts.requests.length;

        await expectLater(
          lessonContent.createLesson(name: '   '),
          throwsArgumentError,
        );
        await expectLater(lessonContent.rename(fiche, ''), throwsArgumentError);
        await expectLater(
          lessonContent.addWeblink(
            fiche,
            const NewLessonContentWeblink(name: 'x', url: 'geen url'),
          ),
          throwsArgumentError,
        );
        await expectLater(
          lessonContent.changeCourses(fiche, [_noSuchId]),
          throwsArgumentError,
        );
        await expectLater(
          lessonContent.getDetailById(LessonContentType.lesson, _noSuchId),
          throwsA(isA<SmartschoolLessonContentNotFoundError>()),
        );

        expect(attempts.writesSince(mark), isEmpty);
        expect(run.guard.violations, isEmpty);
      });

      test('createAssignment makes an assignment lesfiche of one of the '
          'school\'s assignment types', () async {
        final type = (await PlannerService(
          run.client,
        ).getAssignmentTypes()).first;

        final detail = await lessonContent.createAssignment(
          name: name('opdracht'),
          assignmentTypeId: type.id,
        );
        made.add(detail);

        expect(detail.type, LessonContentType.assignment);
        expect(detail.name, name('opdracht'));
        expect(detail.icon, LessonContentService.defaultAssignmentIcon);
        expect(detail.assignmentType?.id, type.id);
        expect(detail.courses, isEmpty);
        expect(detail.weblinks, isEmpty);
        expect(detail.attachments, isEmpty);
      });

      test(
        'trash moves the lesfiches out of the own library; their detail '
        'is still answered (seen live: with canUserEdit still set)',
        () async {
          expect(
            made,
            hasLength(2),
            reason: 'the tests before made a lesson and an assignment',
          );

          await lessonContent.trash(made);
          trashed.addAll(made.map((item) => item.id));

          final listed = {
            for (final item in await lessonContent.getItems(
              withCourseNames: false,
            ))
              item.id,
          };
          expect(made.where((item) => listed.contains(item.id)), isEmpty);
          final read = await lessonContent.getDetail(
            made.first,
            withCourseNames: false,
          );
          expect(read.id, made.first.id);
          expect(read.name, name('les (hernoemd)'));
          // The module does not take the trash into the capabilities.
          expect(read.can('canUserEdit'), isTrue);
          expect(run.guard.violations, isEmpty);
        },
      );
    },
  );
}
