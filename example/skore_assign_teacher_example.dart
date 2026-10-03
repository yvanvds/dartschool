import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: assign a teacher to a course of a class in Skore, after showing
/// the change and asking for confirmation.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// which drives its grading and reports, and there is no test instance. Use
/// a class and course that are not in use, and only on purpose.
///
/// Run with:
///   dart run example/skore_assign_teacher_example.dart \
///       CLASS_ID COURSE_ID TEACHER_ID [ASSIGNMENT_ID]
///
/// - Without an assignment ID, it adds the teacher to the course: a new
///   assignment (`SkoreService.addTeacher`), which holds all pupils of the
///   class.
/// - With one, it gives that assignment of the course the teacher instead of
///   its current one (`SkoreService.replaceTeacher`): the assignment and its
///   gradebook stay.
///
/// The IDs are Skore's own (see `getClasses`, `getCourses`); a teacher ID is
/// the Smartschool user ID (see `getTeachers`).
///
/// The flow:
///   1. Authenticate.
///   2. Read the class, its course and the teacher, and print the course as
///      it is now.
///   3. Print the change, and ask for confirmation (y/N; anything but "y" or
///      "yes", or no answer, saves nothing).
///   4. Save it. The service checks the change again before it saves, and
///      sends the save once. Print the change from the result: the course
///      and the replaced teacher as the service read them before the save.
///   5. Read the class again and print the course as it is then.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  final ids = args.map(int.tryParse).toList();
  if (ids.length < 3 || ids.length > 4 || ids.contains(null)) {
    stderr.writeln(
      'Usage: dart run example/skore_assign_teacher_example.dart '
      'CLASS_ID COURSE_ID TEACHER_ID [ASSIGNMENT_ID]',
    );
    exitCode = 64;
    return;
  }
  final classId = ids[0]!;
  final courseId = ids[1]!;
  final teacherId = ids[2]!;
  final assignmentId = ids.length == 4 ? ids[3] : null;

  print(
    'WARNING: this changes the live Skore (grading and reports) of your '
    'school.\n',
  );

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final skore = SkoreService(client);

    // ── 2. The current state ──────────────────────────────────────────────

    final schoolClass = (await skore.getClasses())
        .where((c) => c.id == classId)
        .firstOrNull;
    if (schoolClass == null) {
      print('Class $classId is not in any report model of Skore.');
      exitCode = 1;
      return;
    }
    final courses = await skore.getCourses(classId);
    final course = courses.where((c) => c.id == courseId).firstOrNull;
    if (course == null) {
      print('Course $courseId is not in class ${schoolClass.name}.');
      exitCode = 1;
      return;
    }
    final teacher = (await skore.getTeachers())
        .where((t) => t.id == teacherId)
        .firstOrNull;
    if (teacher == null) {
      print('Teacher $teacherId is not one Skore lets assign.');
      exitCode = 1;
      return;
    }

    print(
      'Class:   ${schoolClass.name} ($classId), model '
      '${schoolClass.modelName}',
    );
    _printCourse('Now:    ', course);

    // ── 3. The change, and confirmation ───────────────────────────────────

    if (assignmentId == null) {
      print(
        'Change:  add ${teacher.name} ($teacherId) as a teacher of the '
        'course (a new assignment, with all pupils of the class).',
      );
    } else {
      final current = course.assignments
          .where((a) => a.id == assignmentId)
          .firstOrNull;
      print(
        'Change:  assignment $assignmentId '
        '(${current?.teacherName ?? 'not on this course'}) gets '
        '${teacher.name} ($teacherId) instead; the assignment and its '
        'gradebook stay.',
      );
    }

    stdout.write('\nSave this change in Skore? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      print('Nothing saved.');
      return;
    }

    // ── 4. Save ───────────────────────────────────────────────────────────

    try {
      final saved = assignmentId == null
          ? await skore.addTeacher(
              classId: classId,
              courseId: courseId,
              teacherId: teacherId,
            )
          : await skore.replaceTeacher(
              classId: classId,
              courseId: courseId,
              assignmentId: assignmentId,
              teacherId: teacherId,
            );
      // The result holds the course and the replaced assignment as the
      // service read them before the save: no need to read the class again
      // to report the change.
      final replaced = saved.replaced;
      print(
        '✓ Saved: assignment ${saved.id}, ${saved.teacherName}'
        '${replaced == null ? '' : ' instead of ${replaced.teacherName}'}'
        ' on course "${saved.course.label}" (course ${saved.course.id}) of '
        'class ${saved.course.classId}.',
      );
    } on SmartschoolSkoreMyGroupsError catch (e) {
      // The current teacher works with "Mijn lesgroepen": nothing was saved.
      print(
        'Not saved: ${e.teacherName ?? 'the current teacher'} '
        '(${e.teacherId}) works with "Mijn '
        'lesgroepen" for the course. Handle those groups in Skore first.',
      );
      exitCode = 1;
      return;
    } on SmartschoolSkoreError catch (e) {
      // A check before the save refused it, or Skore answered a read before
      // it with something the service cannot use: nothing was saved.
      print('Not saved: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolSkoreSaveUnconfirmedError catch (e) {
      // Read the class again below: it shows whether the save went through.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
    }

    // ── 5. Read the class again ───────────────────────────────────────────

    final coursesAfter = await skore.getCourses(classId);
    final after = coursesAfter.where((c) => c.id == courseId).firstOrNull;
    if (after == null) {
      print('Course $courseId is no longer in class $classId.');
      exitCode = 1;
      return;
    }
    print('');
    _printCourse('After:  ', after);
  } finally {
    await client.dispose();
  }
}

/// Prints [course] and its assignments after [prefix].
void _printCourse(String prefix, SkoreCourse course) {
  print('$prefix ${course.label} (course ${course.id})');
  if (course.assignments.isEmpty) {
    print('         (no teacher)');
  }
  for (final a in course.assignments) {
    print('         assignment ${a.id}: ${a.teacherName} (${a.teacherId})');
  }
}
