import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: save a pupil's rating of a learning goal in a project of one of
/// your own Skore project gradebooks ("Projecten"), as the logged-in teacher
/// (#204), after showing the plan and asking for confirmation. Give a level
/// of the template's scale, or `-` to clear the rating; optionally the
/// cell's info (the feedback text; `""` clears it).
///
/// It writes only into a project that is **not published nor scheduled**:
/// the service refuses the others, since pupils see their ratings (this
/// example does not pass `allowPublished`). Make a test project in Skore
/// first: the library never makes, publishes or removes a project.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// and there is no test instance. Use a test project only, on purpose, and
/// remove it in Smartschool afterwards.
///
/// Run with:
///   dart run example/skore_save_project_rating_example.dart \
///       GRADEBOOK_ID PROJECT_ID PUPIL_ID GOAL_ID LEVEL_ID|- [INFO]
///
/// - `GRADEBOOK_ID`: one of your own gradebooks of the current school year
///   with a project period, or one a colleague shared with you to write
///   (#191); `PROJECT_ID`: a project of it (`SkoreProject.id`); `PUPIL_ID`:
///   a pupil of the gradebook (the Smartschool user ID); `GOAL_ID`: a
///   learning goal of the project's template (`SkoreLearningGoal.id`).
/// - `LEVEL_ID`: a level of the template's scale
///   (`SkoreProjectRatingLevel.id`), or `-` to clear the rating.
/// - `INFO`: the cell's info; leave it out to keep the one it has.
///
/// The flow:
///   1. Authenticate.
///   2. Find the project in the gradebook's project periods, and print the
///      template's levels and the pupil's rating as it is now.
///   3. Print the change, and ask for confirmation (y/N; anything but "y"
///      or "yes", or no answer, saves nothing).
///   4. Save it (`SkoreGradebookService.saveProjectRating`): the service
///      checks it all again first, saves, and reads the ratings again to
///      check it.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  if (args.length < 5 || args.length > 6) return _usage();
  final gradebookId = int.tryParse(args[0]);
  final projectId = int.tryParse(args[1]);
  final pupilId = int.tryParse(args[2]);
  final goalId = args[3];
  final levelId = args[4] == '-' ? null : int.tryParse(args[4]);
  if (gradebookId == null ||
      projectId == null ||
      pupilId == null ||
      (levelId == null && args[4] != '-')) {
    return _usage();
  }
  final info = args.length > 5 ? args[5] : null;
  final change = levelId == null
      ? SkoreProjectRatingChange.clear(
          pupilId: pupilId,
          learningGoalId: goalId,
          info: info,
        )
      : SkoreProjectRatingChange(
          pupilId: pupilId,
          learningGoalId: goalId,
          ratingId: levelId,
          info: info,
        );

  print('WARNING: this changes ratings in the live Skore of your school.\n');

  // ── 1. Authenticate ───────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);

    // ── 2. The project, its template and the pupil's rating now ───────────

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
    SkoreProject? project;
    SkoreProjectTemplate? template;
    for (final period in await gradebooks.getProjectPeriods(book)) {
      for (final t in await gradebooks.getProjectTemplates(book, period.id)) {
        final found = (await gradebooks.getProjects(
          book,
          period.id,
          t,
        )).where((p) => p.id == projectId).firstOrNull;
        if (found != null) (project, template) = (found, t);
      }
    }
    if (project == null || template == null) {
      print(
        'Project $projectId is not in the project periods of the gradebook.',
      );
      exitCode = 1;
      return;
    }
    final scale = template.scale;
    print('Gradebook: ${book.className} – ${book.courseName} ($gradebookId)');
    print(
      'Project:   "${project.title}" ($projectId), template '
      '"${template.title}", ${project.isPublic ? 'published' : 'not published'}'
      '${project.publicAt == null ? '' : ', from ${project.publicAt!.toLocal()}'}',
    );
    print('Levels:');
    for (final level in scale?.levels ?? const <SkoreProjectRatingLevel>[]) {
      print('  ${level.id}: ${level.description} (${level.symbol})');
    }
    final now = (await gradebooks.getProjectRatings(book, project))
        .where((r) => r.pupilId == pupilId && r.learningGoalId == goalId)
        .firstOrNull;
    print('Now:       ${_rating(now, scale)}');
    if (project.isPublic || project.publicAt != null) {
      print(
        '\nThis project is published or scheduled: its pupils see their '
        'ratings. The service refuses it without allowPublished, and this '
        'example does not pass that. Nothing saved.',
      );
      exitCode = 1;
      return;
    }

    // ── 3. The change, and confirmation ───────────────────────────────────

    print(
      '\nSave: pupil $pupilId, goal $goalId: '
      '${levelId == null ? '(clear)' : 'level $levelId'}'
      '${info == null ? '' : ', info ${info.isEmpty ? '(clear)' : '"$info"'}'}',
    );
    stdout.write('Save this rating in Skore? [y/N] ');
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
      final cell = await gradebooks.saveProjectRating(book, project, change);
      print('✓ Saved: Skore lists ${_rating(cell, scale)}.');
    } on SmartschoolSkoreError catch (e) {
      // A check refused it, or a read before the save failed: not saved.
      print('Not saved: ${e.message}');
      exitCode = 1;
    } on SmartschoolSkoreProjectRatingSaveUnconfirmedError catch (e) {
      // Sent, but not confirmed: read the ratings again.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
    }
  } finally {
    await client.dispose();
  }
}

/// [cell] for a line: its level and info, or why there is none.
String _rating(SkoreProjectRating? cell, SkoreProjectScale? scale) {
  if (cell == null) return '(no cell for this pupil and goal)';
  final level = scale?.levelOf(cell.ratingId);
  return '${cell.ratingId == null ? '(no level)' : 'level ${cell.ratingId}${level == null ? '' : ' ${level.description}'}'}'
      '${cell.info == null ? '' : ', info "${cell.info}"'}';
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_save_project_rating_example.dart '
    'GRADEBOOK_ID PROJECT_ID PUPIL_ID GOAL_ID LEVEL_ID|- [INFO]  '
    '(LEVEL_ID "-" clears)',
  );
  exitCode = 64;
}
