import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: give a pupil written feedback on an evaluation of one of your
/// own Skore gradebooks, as the logged-in teacher (#152), after showing the
/// plan and asking for confirmation. Give several texts to save them in
/// turn: the first creates your feedback (when you have none yet), the next
/// change it; each is read again.
///
/// It writes only into an evaluation that is **not published nor
/// scheduled**: the service refuses the others, since pupils see feedback on
/// a published evaluation at once (this example does not pass
/// `allowPublished`). Make a test evaluation first
/// (`example/skore_create_evaluation_example.dart`). The feedback of other
/// teachers is never changed.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// and there is no test instance. Use a test evaluation only, on purpose,
/// and move it, with its feedback, to the trash in Smartschool afterwards:
/// the library deletes nothing.
///
/// Run with:
///   dart run example/skore_save_feedback_example.dart \
///       GRADEBOOK_ID PERIOD_ID EVALUATION_ID PUPIL_ID TEXT [TEXT ...]
///
/// - `GRADEBOOK_ID`: one of your own gradebooks of the current school year
///   (see `example/skore_gradebook_example.dart`); `PERIOD_ID`: an open
///   period of it; `EVALUATION_ID`: an evaluation in that period (its
///   `SkoreEvaluation.id`); `PUPIL_ID`: a pupil of the gradebook.
/// - `TEXT`: the feedback, quoted when it has spaces.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebook, the evaluation and the pupil, and print the
///      pupil's feedback as it is now (whose, when, how long; not the text).
///   3. Print the plan (create or change, and the texts), and ask for
///      confirmation (y/N; anything but "y" or "yes", or no answer, saves
///      nothing).
///   4. Save each text in turn (`SkoreGradebookService.saveFeedback`): the
///      service checks it all again first, reads the feedback, creates or
///      changes yours, and reads it again to check it. A refused or
///      unconfirmed save stops the run.
///   5. Read the pupil's feedback again and print it.
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
  final texts = args.skip(4).toList();

  print('WARNING: this changes feedback in the live Skore of your school.\n');

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);
    final me = (await client.getCurrentUser()).id;

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
      'Evaluation: "${evaluation.title}" ($evaluationId), '
      '${evaluation.type.name}, ${publication.state.name}'
      '${publication.at == null ? '' : ' ${publication.at!.toLocal()}'}',
    );
    print(
      'Pupil:      ${pupil?.name ?? '(not a pupil of the gradebook)'} '
      '($pupilId)',
    );
    if (publication.isPublic) {
      print(
        '\nThis evaluation is ${publication.state.name}: its pupils see '
        'feedback on it. The service refuses it without allowPublished, and '
        'this example does not pass that. Nothing saved.',
      );
      exitCode = 1;
      return;
    }
    final before = await gradebooks.getFeedback(book, evaluation, pupilId);
    _printFeedback('Now', before, me);
    final own = before.where((f) => f.teacherId == me).toList();
    if (own.length > 1) {
      print(
        '\nYou have ${own.length} feedbacks for this pupil here: the service '
        'changes none of them. Keep one in Smartschool. Nothing saved.',
      );
      exitCode = 1;
      return;
    }

    // ── 3. The plan, and confirmation ─────────────────────────────────────

    print('\nSave in turn, each read again:');
    for (final (i, text) in texts.indexed) {
      final how = i == 0 && own.isEmpty
          ? 'create your feedback'
          : 'change your feedback';
      print('  $how: "$text"');
    }
    stdout.write('\nSave this feedback in Skore? [y/N] ');
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

    for (final text in texts) {
      try {
        final feedback = await gradebooks.saveFeedback(
          book,
          evaluation,
          pupilId,
          text,
        );
        print(
          '✓ Saved: feedback ${feedback.id}, '
          '${feedback.text.length} characters, changed '
          '${feedback.changedAt?.toLocal()}.',
        );
      } on SmartschoolSkoreError catch (e) {
        // A check refused it, Skore refused it, or a read before the save
        // failed: not saved.
        print('Not saved: ${e.message}');
        exitCode = 1;
        break;
      } on SmartschoolSkoreFeedbackSaveUnconfirmedError catch (e) {
        // Sent, but not confirmed: look below what Skore has.
        print('UNCONFIRMED: ${e.message}');
        exitCode = 1;
        break;
      }
    }

    // ── 5. The feedback again ─────────────────────────────────────────────

    _printFeedback(
      '\nAfter',
      await gradebooks.getFeedback(book, evaluation, pupilId),
      me,
    );
  } finally {
    await client.dispose();
  }
}

/// Prints [feedback] under [label]: whose each one is, its ID, when it was
/// changed and its length, not the text.
void _printFeedback(String label, List<SkoreFeedback> feedback, int me) {
  print('$label: ${feedback.isEmpty ? '(no feedback)' : ''}');
  for (final f in feedback) {
    print(
      '  ${f.teacherId == me ? 'yours' : 'teacher ${f.teacherId}'}: ${f.id}, '
      'changed ${f.changedAt?.toLocal()}, ${f.text.length} characters, '
      '${f.attachments.length} attachments'
      '${f.canEdit ? '' : ', not editable'}',
    );
  }
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_save_feedback_example.dart GRADEBOOK_ID '
    'PERIOD_ID EVALUATION_ID PUPIL_ID TEXT [TEXT ...]',
  );
  exitCode = 64;
}
