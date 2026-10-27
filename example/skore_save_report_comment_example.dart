import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: write a pupil's course comment ("vakcommentaar") on a report
/// period of one of your Skore gradebooks, as the logged-in teacher (#195),
/// after showing the plan and asking for confirmation. The comment is read
/// again afterwards.
///
/// Skore keeps one course comment per pupil, course and report, and does
/// not say who wrote it: the save replaces it. So the example passes the
/// comment it read as `replacing`: when Skore holds another one by the time
/// of the save, nothing is saved.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// and there is no test instance: **the comment goes on a real report**. It
/// was not tried live when the example was written: run it on purpose, for
/// a pupil whose comment you mean to write, while the report is open. The
/// library never closes, unlocks or publishes a report.
///
/// Run with:
///   dart run example/skore_save_report_comment_example.dart \
///       GRADEBOOK_ID REPORT_ID PUPIL_ID TEXT
///
/// - `GRADEBOOK_ID`: one of your own gradebooks of the current school year
///   (see `example/skore_gradebook_example.dart`), or one a colleague
///   shared with you to write (#191); `REPORT_ID`: an open report of it (a
///   `SkoreReportPeriod.id`); `PUPIL_ID`: a pupil of the gradebook.
/// - `TEXT`: the comment, quoted when it has spaces; `\n` in it starts a
///   new line.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebook and the report, and print the pupil's comment as
///      it is now (how long, whether Skore lets you change it; not the
///      text).
///   3. Print the plan, and ask for confirmation (y/N; anything but "y" or
///      "yes", or no answer, saves nothing).
///   4. Save it (`SkoreGradebookService.saveReportComment`): the service
///      checks it all again first, saves it, and reads the report again to
///      check it. A refused or unconfirmed save is printed.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  if (args.length != 4) return _usage();
  final gradebookId = int.tryParse(args[0]);
  final reportId = int.tryParse(args[1]);
  final pupilId = int.tryParse(args[2]);
  if (gradebookId == null || reportId == null || pupilId == null) {
    return _usage();
  }
  final text = args[3].replaceAll(r'\n', '\n');

  print('WARNING: this writes a course comment on a real report.\n');

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);

    // ── 2. The gradebook, the report and the pupil as they are now ────────

    // Yours, or one a colleague shared with you to write (#191).
    final year = await gradebooks.getGradebookYear(includeShared: true);
    final book = [
      ...year.gradebooks,
      ...year.sharedGradebooks,
    ].where((g) => g.gradebookId == gradebookId).firstOrNull;
    if (book == null) {
      print(
        'Gradebook $gradebookId is not one of your gradebooks of '
        '${year.workyear.name}, nor shared with you.',
      );
      exitCode = 1;
      return;
    }
    final sheet = await gradebooks.getGradebook(book);
    final period = sheet.reports.where((r) => r.id == reportId).firstOrNull;
    if (period == null) {
      print(
        'Report $reportId is not one of gradebook $gradebookId (it has '
        '${sheet.reports.map((r) => '${r.name} ${r.id}').join(', ')}).',
      );
      exitCode = 1;
      return;
    }
    final pupil = sheet.pupils.where((p) => p.id == pupilId).firstOrNull;
    final report = await gradebooks.getReport(book, reportId);
    final comment = report.pupil(pupilId)?.comment;
    print(
      'Gradebook: ${book.className} – ${sheet.courseName} ($gradebookId), '
      '${year.workyear.name}'
      '${book.isShared ? ', shared with you by teacher ${book.teacherId}' : ''}',
    );
    print(
      'Report:    ${period.name} – ${period.fullName} ($reportId), '
      '${period.isOpen ? 'open' : 'closed'} until '
      '${period.closesAt?.toLocal() ?? '-'}',
    );
    print(
      'Pupil:     ${pupil?.name ?? '(not a pupil of the gradebook)'} '
      '($pupilId)',
    );
    if (comment == null) {
      print(
        '\nThe report has no course comment for this pupil. Nothing saved.',
      );
      exitCode = 1;
      return;
    }
    print(
      'Now:       ${comment.isEmpty ? 'no comment' : '${comment.text.length} characters'}'
      '${comment.isEditable ? '' : ', closed for the pupil'}',
    );

    // ── 3. The plan, and confirmation ─────────────────────────────────────

    print(
      '\n${comment.isEmpty ? 'Write' : 'Replace it with'} this comment '
      '(${text.length} characters, at most '
      '${report.commentMaxLength ?? '?'}):\n$text',
    );
    stdout.write('\nSave this comment on the report? [y/N] ');
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

    try {
      final saved = await gradebooks.saveReportComment(
        book,
        reportId,
        pupilId,
        text,
        replacing: comment.isEmpty ? null : comment.text,
      );
      print('✓ Saved and read again: ${saved.text.length} characters.');
    } on SmartschoolSkoreError catch (e) {
      // A check refused it, or a read before the save failed: not saved.
      print('Not saved: ${e.message}');
      exitCode = 1;
    } on SmartschoolSkoreReportCommentSaveUnconfirmedError catch (e) {
      // Sent, but not confirmed: read the report again.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
    }
  } finally {
    await client.dispose();
  }
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_save_report_comment_example.dart '
    'GRADEBOOK_ID REPORT_ID PUPIL_ID TEXT',
  );
  exitCode = 64;
}
