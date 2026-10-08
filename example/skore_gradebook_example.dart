import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: list your own Skore gradebooks, as the logged-in teacher, and
/// print the periods and pupils of one of them (#148), and the evaluations
/// of its active period with whether they are published, the grades and the
/// feedback (#149).
///
/// It only reads: nothing in Skore changes. Any teacher can run it with
/// their own login; no Skore admin rights are needed.
///
/// Run with:
///   dart run example/skore_gradebook_example.dart [GRADEBOOK_ID] [--workyear=ID]
///
/// - Without `GRADEBOOK_ID`, it shows the first gradebook of the list.
/// - `--workyear=ID` reads an earlier school year (a Skore school year ID,
///   as the list of school years printed first shows it); without it, the
///   current one.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebooks of the school year
///      (`SkoreGradebookService.getGradebookYear`) and print them, with the
///      school years Skore offers.
///   3. Read one gradebook (`SkoreGradebookService.getGradebook`) and print
///      its periods (open or closed, and until when), its pupils and whether
///      you may change it.
///   4. Read the evaluations of its active period
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

    final year = await gradebooks.getGradebookYear(workyearId: workyearId);
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
    if (year.gradebooks.isEmpty) return;

    // ── 3. One gradebook ──────────────────────────────────────────────────

    final book = gradebookId == null
        ? year.gradebooks.first
        : year.gradebooks
              .where((g) => g.gradebookId == gradebookId)
              .firstOrNull;
    if (book == null) {
      stderr.writeln(
        '\nGradebook $gradebookId is not one of your gradebooks of '
        '${year.workyear.name}.',
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

    // ── 4. The evaluations of the active period (#149) ────────────────────

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
