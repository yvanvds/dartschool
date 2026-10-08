import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: save a pupil's grade in an evaluation of one of your own Skore
/// gradebooks, as the logged-in teacher (#151), after showing the plan and
/// asking for confirmation. Give several grades to save them in turn (a
/// whole number, a decimal, then `-` to clear it), each read again.
///
/// It writes only into an evaluation that is **not published nor
/// scheduled**: the service refuses the others, since pupils see their
/// grades at once (this example does not pass `allowPublished`). Make a test
/// evaluation first (`example/skore_create_evaluation_example.dart`).
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// and there is no test instance. Use a test evaluation only, on purpose,
/// and move it to the trash in Smartschool afterwards: the library deletes
/// nothing.
///
/// Run with:
///   dart run example/skore_save_grade_example.dart \
///       GRADEBOOK_ID PERIOD_ID EVALUATION_ID PUPIL_ID GRADE [GRADE ...]
///
/// - `GRADEBOOK_ID`: one of your own gradebooks of the current school year
///   (see `example/skore_gradebook_example.dart`); `PERIOD_ID`: an open
///   period of it; `EVALUATION_ID`: an evaluation in that period (its
///   `SkoreEvaluation.id`); `PUPIL_ID`: a pupil of the gradebook.
/// - `GRADE`: a number up to the evaluation's highest grade (`15`, `15.5`
///   or `15,5`), or `-` to clear the grade.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebook, the evaluation and the pupil, and print the
///      pupil's grade as it is now.
///   3. Print the grades to save, and ask for confirmation (y/N; anything
///      but "y" or "yes", or no answer, saves nothing).
///   4. Save each grade in turn (`SkoreGradebookService.saveGrade`): the
///      service checks it all again first, saves, and reads the period again
///      to check it. A refused or unconfirmed save stops the run.
///   5. Read the evaluation's grades again and print the pupil's.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  if (args.length < 5) return _usage();
  final gradebookId = int.tryParse(args[0]);
  final periodId = int.tryParse(args[1]);
  final evaluationId = int.tryParse(args[2]);
  final pupilId = int.tryParse(args[3]);
  if (gradebookId == null ||
      periodId == null ||
      evaluationId == null ||
      pupilId == null) {
    return _usage();
  }
  // `-` clears the grade.
  final grades = [for (final g in args.skip(4)) g == '-' ? null : g];

  print('WARNING: this changes grades in the live Skore of your school.\n');

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);

    // ── 2. The gradebook, the evaluation and the pupil as they are now ───

    final year = await gradebooks.getGradebookYear();
    final book = year.gradebooks
        .where((g) => g.gradebookId == gradebookId)
        .firstOrNull;
    if (book == null) {
      print(
        'Gradebook $gradebookId is not one of your gradebooks of '
        '${year.workyear.name}.',
      );
      exitCode = 1;
      return;
    }
    final sheet = await gradebooks.getGradebook(book);
    final pupil = sheet.pupils.where((p) => p.id == pupilId).firstOrNull;
    final evaluation = (await gradebooks.getEvaluations(
      book,
      periodId,
    )).where((e) => e.id == evaluationId).firstOrNull;
    if (evaluation == null) {
      print('Evaluation $evaluationId is not in period $periodId.');
      exitCode = 1;
      return;
    }
    final publication = evaluation.publication;
    print(
      'Gradebook:  ${book.className} – ${sheet.courseName} ($gradebookId), '
      '${year.workyear.name}',
    );
    print(
      'Evaluation: "${evaluation.title}" ($evaluationId), max '
      '${evaluation.max}, ${evaluation.type.name}, '
      '${publication.state.name}'
      '${publication.at == null ? '' : ' ${publication.at!.toLocal()}'}',
    );
    print(
      'Pupil:      ${pupil?.name ?? '(not a pupil of the gradebook)'} '
      '($pupilId)',
    );
    print('Now:        ${_grade(evaluation.results.gradeOf(pupilId))}');
    if (publication.isPublic) {
      print(
        '\nThis evaluation is ${publication.state.name}: its pupils see '
        'their grades. The service refuses it without allowPublished, and '
        'this example does not pass that. Nothing saved.',
      );
      exitCode = 1;
      return;
    }

    // ── 3. The grades, and confirmation ───────────────────────────────────

    print('\nSave in turn, each read again:');
    for (final grade in grades) {
      print('  ${grade ?? '(clear)'}');
    }
    stdout.write('\nSave these grades in Skore? [y/N] ');
    String? answer;
    try {
      answer = stdin.readLineSync()?.trim().toLowerCase();
    } on StdinException {
      answer = null; // no terminal to answer from: no answer
    }
    if (answer != 'y' && answer != 'yes') {
      print('Nothing saved.');
      return;
    }

    // ── 4. Save ───────────────────────────────────────────────────────────

    for (final grade in grades) {
      try {
        final cell = await gradebooks.saveGrade(
          book,
          evaluation,
          pupilId,
          grade,
        );
        print('✓ Saved ${grade ?? '(clear)'}: Skore lists ${_grade(cell)}.');
      } on SmartschoolSkoreError catch (e) {
        // A check refused it, or a read before the save failed: not saved.
        print('Not saved: ${e.message}');
        exitCode = 1;
        break;
      } on SmartschoolSkoreGradeSaveUnconfirmedError catch (e) {
        // Sent, but not confirmed: look below what Skore has.
        print('UNCONFIRMED: ${e.message}');
        exitCode = 1;
        break;
      }
    }

    // ── 5. The grades again ───────────────────────────────────────────────

    final results = await gradebooks.getResults(book, evaluation);
    print('\nAfter:      ${_grade(results.gradeOf(pupilId))}');
  } finally {
    await client.dispose();
  }
}

/// [cell] for a line: its grade, or why there is none.
String _grade(SkoreGrade? cell) => cell == null
    ? '(no cell for this pupil)'
    : cell.grade == null
    ? '(no grade)'
    : '"${cell.grade}"';

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_save_grade_example.dart GRADEBOOK_ID '
    'PERIOD_ID EVALUATION_ID PUPIL_ID GRADE [GRADE ...]  (GRADE "-" clears)',
  );
  exitCode = 64;
}
