import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: list your own Skore gradebooks, as the logged-in teacher, and
/// those colleagues shared with you (#191), and print the periods and pupils
/// of one of them (#148), its report periods with each pupil's results and
/// course comment (#195), and the evaluations of its active period with
/// whether they are published, the grades and the feedback (#149).
///
/// It only reads: nothing in Skore changes. Any teacher can run it with
/// their own login; no Skore admin rights are needed.
///
/// Run with:
///   dart run example/skore_gradebook_example.dart [GRADEBOOK_ID] [--workyear=ID]
///
/// - Without `GRADEBOOK_ID`, it shows the first gradebook of the list. A
///   `GRADEBOOK_ID` of a gradebook shared with you opens that one, as
///   Skore's web client does (#191).
/// - `--workyear=ID` reads an earlier school year (a Skore school year ID,
///   as the list of school years printed first shows it); without it, the
///   current one.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebooks of the school year, yours and those shared
///      with you (`SkoreGradebookService.getGradebookYear` with
///      `includeShared`), and print them, with the school years Skore
///      offers.
///   3. Read one gradebook (`SkoreGradebookService.getGradebook`) and print
///      its periods (open or closed, and until when), its pupils and whether
///      you may change it.
///   4. Read each of its report periods (`SkoreGradebookService.getReport`)
///      and print each pupil's results and course comment.
///   5. Read the evaluations of its active period
///      (`SkoreGradebookService.getEvaluations`) and print each with its
///      publication (not published, scheduled or published, and when), the
///      grades and the feedback (`SkoreGradebookService.getFeedback`).
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  int? gradebookId;
  int? workyearId;
  for (final arg in args) {
    if (arg.startsWith('--workyear=')) {
      workyearId = int.tryParse(arg.substring('--workyear='.length));
      if (workyearId == null) return _usage();
    } else {
      gradebookId = int.tryParse(arg);
      if (gradebookId == null) return _usage();
    }
  }

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);

    // ── 2. The gradebooks of the school year ──────────────────────────────

    final year = await gradebooks.getGradebookYear(
      workyearId: workyearId,
      includeShared: true,
    );
    print(
      'School years: '
      '${year.workyears.map((y) => '${y.name} (${y.id})').join(', ')}',
    );
    print(
      '\nYour gradebooks of ${year.workyear.name}: '
      '${year.gradebooks.length}\n',
    );
    for (final book in year.gradebooks) {
      print(
        '  ${book.gradebookId}  ${book.className.padRight(8)} '
        '${book.courseName}  (${book.teacherNames.join(', ')})',
      );
    }
    // A shared list Skore answered in a way the library cannot read keeps
    // the own gradebooks (#207): sharedGradebooks would throw sharedError.
    final sharedError = year.sharedError;
    final shared = sharedError == null
        ? year.sharedGradebooks
        : const <SkoreGradebook>[];
    if (sharedError != null) {
      stderr.writeln(
        '\nThe gradebooks shared with you in ${year.workyear.name} could not '
        'be read: ${sharedError.message}',
      );
    } else {
      print('\nShared with you in ${year.workyear.name}: ${shared.length}\n');
    }
    for (final book in shared) {
      print(
        '  ${book.gradebookId}  ${book.className.padRight(8)} '
        '${book.courseName}  (${book.ownerName}, to ${book.access.name})',
      );
    }
    final all = [...year.gradebooks, ...shared];
    if (all.isEmpty) return;

    // ── 3. One gradebook ──────────────────────────────────────────────────

    final book = gradebookId == null
        ? all.first
        : all.where((g) => g.gradebookId == gradebookId).firstOrNull;
    if (book == null) {
      stderr.writeln(
        '\nGradebook $gradebookId is not one of your gradebooks of '
        '${year.workyear.name}, nor shared with you.',
      );
      exitCode = 1;
      return;
    }
    final sheet = await gradebooks.getGradebook(book);
    print(
      '\n${book.className} – ${sheet.courseName} (gradebook '
      '${book.gradebookId}, pathIds ${book.pathIds.join('/')}, course '
      '${book.courseId})',
    );
    print(
      sheet.writable
          ? 'You may change this gradebook.'
          : 'Skore shows this gradebook read-only to you.',
    );
    print('\nPeriods:');
    for (final period in sheet.periods) {
      final active = identical(period, sheet.activePeriod) ? '  (active)' : '';
      print(
        '  ${period.id}  ${period.name.padRight(6)} '
        '${period.isOpen ? 'open  ' : 'closed'}  until '
        '${period.closesAt?.toLocal() ?? '-'}$active',
      );
    }
    print('\nPupils (${sheet.pupils.length}):');
    for (final pupil in sheet.pupils) {
      final number = pupil.number == null ? ' -' : '${pupil.number}'.padLeft(2);
      final inactive = pupil.isActive ? '' : '  (inactive)';
      print('  $number. ${pupil.name}  [${pupil.id}]$inactive');
    }

    // ── 4. The report periods, with results and comments (#195) ──────────

    for (final report in sheet.reports) {
      print(
        '\nReport ${report.name} – ${report.fullName} (${report.id}): '
        '${report.isOpen ? 'open' : 'closed'} until '
        '${report.closesAt?.toLocal() ?? '-'}',
      );
      final SkoreReport read;
      try {
        read = await gradebooks.getReport(book, report.id);
      } on SmartschoolSkoreCourseNotOnReportError {
        // Skore's 404 "Course not found in source!" (#204): nothing to read.
        print('  course ${book.courseId} is not on this report');
        continue;
      } on SmartschoolSkoreError catch (e) {
        print('  not read: ${e.message}');
        continue;
      }
      print(
        '  ${read.courseName}: ${read.components.map((c) => '${c.name} (class '
            'average ${c.classAverage ?? '-'})').join(', ')}; comments of at '
        'most ${read.commentMaxLength ?? '?'} characters',
      );
      final names = {for (final p in sheet.pupils) p.id: p.name};
      for (final pupil in read.pupils) {
        final comment = pupil.comment;
        print(
          '    ${(names[pupil.pupilId] ?? '${pupil.pupilId}').padRight(28)} '
          '${pupil.results.map((r) => r.value ?? '-').join(' ')}'
          '${comment == null ? '' : '  ${comment.isEditable ? '' : '(closed) '}"${comment.text}"'}',
        );
      }
    }

    // ── 5. The evaluations of the active period (#149) ────────────────────

    final period = sheet.activePeriod;
    if (period == null) return;
    final evaluations = await gradebooks.getEvaluations(book, period.id);
    print('\nEvaluations of ${period.name} (${evaluations.length}):');
    final names = {for (final p in sheet.pupils) p.id: p.name};
    for (final evaluation in evaluations) {
      final publication = evaluation.publication;
      print(
        '\n  ${evaluation.id}  ${evaluation.title}  '
        '(${evaluation.date.toIso8601String().substring(0, 10)}, '
        '/${evaluation.max}, ${evaluation.componentName})  '
        '${publication.state.name}'
        '${publication.at == null ? '' : ' ${publication.at!.toLocal()}'}',
      );
      // An evaluation the library cannot read (of a type it does not know,
      // #193) has no grades to show: its `results` would throw.
      if (!evaluation.isReadable) {
        print('    cannot be read: ${evaluation.unreadableReason}');
        continue;
      }
      for (final grade in evaluation.results.grades) {
        print(
          '    ${(names[grade.pupilId] ?? '${grade.pupilId}').padRight(28)} '
          '${grade.grade ?? '-'}',
        );
        if (!grade.hasFeedback) continue;
        for (final feedback in await gradebooks.getFeedback(
          book,
          evaluation,
          grade.pupilId,
        )) {
          print('      feedback (${feedback.teacherName}): ${feedback.text}');
        }
      }
      print('    class average: ${evaluation.results.classAverage ?? '-'}');
    }
  } on SmartschoolSkoreError catch (e) {
    stderr.writeln('Skore error: ${e.message}');
    exitCode = 1;
  } finally {
    await client.dispose();
  }
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_gradebook_example.dart '
    '[GRADEBOOK_ID] [--workyear=ID]',
  );
  exitCode = 64;
}
