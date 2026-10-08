import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: create an evaluation (a column of grades) in a period of one of
/// your own Skore gradebooks, as the logged-in teacher (#150), after showing
/// it and asking for confirmation. The evaluation is **not published**: check
/// it in Smartschool and publish it there yourself. The library never
/// publishes.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// and there is no test instance. Use a test title such as "dartschool test
/// (mag weg)", only on purpose, and move the evaluation to the trash in
/// Smartschool afterwards: the library deletes nothing.
///
/// Run with:
///   dart run example/skore_create_evaluation_example.dart \
///       GRADEBOOK_ID PERIOD_ID TITLE YYYY-MM-DD MAX \
///       [--short=NAME] [--component=ID]
///
/// - `GRADEBOOK_ID`: one of your own gradebooks of the current school year
///   (see `example/skore_gradebook_example.dart`); `PERIOD_ID`: an open
///   period of it.
/// - `TITLE`, the day, and the highest grade `MAX` (a positive whole
///   number); `--short` a short name.
/// - `--component=ID`: one of the components the example prints (`0` for
///   none); without it, the one Skore's dialog picks.
///
/// The flow:
///   1. Authenticate.
///   2. Read the gradebook, the period, its components and its evaluations,
///      and print them as they are now.
///   3. Print the evaluation to create, and ask for confirmation (y/N;
///      anything but "y" or "yes", or no answer, saves nothing).
///   4. Create it (`SkoreGradebookService.createEvaluation`): the service
///      checks it all again first, sends the save once, and reads the period
///      again to check it.
///   5. Read the period again and print its evaluations as they are then.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  String? shortName;
  int? componentId;
  final positional = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--short=')) {
      shortName = arg.substring('--short='.length);
    } else if (arg.startsWith('--component=')) {
      componentId = int.tryParse(arg.substring('--component='.length));
      if (componentId == null) return _usage();
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 5) return _usage();
  final gradebookId = int.tryParse(positional[0]);
  final periodId = int.tryParse(positional[1]);
  final title = positional[2];
  final date = DateTime.tryParse(positional[3]);
  final max = int.tryParse(positional[4]);
  if (gradebookId == null || periodId == null || date == null || max == null) {
    return _usage();
  }

  print(
    'WARNING: this creates an evaluation in the live Skore of your school.\n',
  );

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final client = await SmartschoolClient.create(PathCredentials());
  try {
    await client.ensureAuthenticated();
    print('✓ Authenticated.\n');
    final gradebooks = SkoreGradebookService(client);

    // ── 2. The gradebook and the period as they are now ───────────────────

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
    final period = sheet.periods.where((p) => p.id == periodId).firstOrNull;
    if (period == null) {
      print('Period $periodId is not one of gradebook $gradebookId.');
      exitCode = 1;
      return;
    }
    final components = await gradebooks.getComponents(book, periodId);
    print(
      'Gradebook: ${book.className} – ${sheet.courseName} ($gradebookId), '
      '${year.workyear.name}',
    );
    print(
      'Period:    ${period.name} ($periodId), '
      '${period.isOpen ? 'open' : 'CLOSED'} until '
      '${period.closesAt?.toLocal() ?? '-'}',
    );
    print(
      'Components: '
      '${components.map((c) => '${c.id} ${c.name}').join(', ')}',
    );
    print('\nNow:');
    _printEvaluations(await gradebooks.getEvaluations(book, periodId));

    // ── 3. The evaluation, and confirmation ───────────────────────────────

    // The one createEvaluation takes without --component, as Skore's dialog.
    final component = componentId != null
        ? components.where((c) => c.id == componentId).firstOrNull
        : components.length == 2
        ? components[1]
        : components.where((c) => c.isNone).firstOrNull;
    final day = date.toIso8601String().substring(0, 10);
    print(
      '\nCreate:    "${title.trim()}"'
      '${shortName == null || shortName.trim().isEmpty ? '' : ' (${shortName.trim()})'}'
      ', $day, max $max, component '
      '${component == null ? '$componentId (not offered)' : '${component.name} (${component.id})'}'
      '${componentId == null ? ', as Skore\'s dialog picks it' : ''}',
    );
    print(
      '           NOT published: check it in Smartschool and publish it '
      'there yourself.',
    );

    stdout.write('\nCreate this evaluation in Skore? [y/N] ');
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

    // ── 4. Create ─────────────────────────────────────────────────────────

    try {
      final created = await gradebooks.createEvaluation(
        book,
        periodId,
        title: title,
        shortName: shortName,
        date: date,
        max: max,
        componentId: componentId,
      );
      print(
        '✓ Created: evaluation ${created.id} "${created.title}" in column '
        '${created.column}, ${created.publication.state.name}.',
      );
    } on SmartschoolSkoreError catch (e) {
      // A check refused it, or a read before the save failed: nothing saved.
      print('Not saved: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolSkoreEvaluationPublicError catch (e) {
      // Created, but Skore shows it as public: the library changes nothing.
      print(
        'CREATED, BUT PUBLIC: evaluation ${e.evaluation.id} '
        '"${e.evaluation.title}" (${e.evaluation.publication.state.name}). '
        'Change its publication in Smartschool now.',
      );
      exitCode = 1;
    } on SmartschoolSkoreEvaluationCreateUnconfirmedError catch (e) {
      // Sent, but not confirmed: look below whether it is there.
      print(
        'UNCONFIRMED: "${e.title}"'
        '${e.evaluationId == null ? '' : ' (evaluation ${e.evaluationId})'} '
        'may or may not have been created.',
      );
      print('             ${e.message}');
      exitCode = 1;
    }

    // ── 5. The period again ───────────────────────────────────────────────

    print('\nAfter:');
    _printEvaluations(await gradebooks.getEvaluations(book, periodId));
  } finally {
    await client.dispose();
  }
}

/// Prints [evaluations], one per line, with their publication.
void _printEvaluations(List<SkoreEvaluation> evaluations) {
  if (evaluations.isEmpty) print('  (no evaluations)');
  for (final e in evaluations) {
    print(
      '  ${e.column.padRight(2)} ${e.id}  "${e.title}"  '
      '${e.date.toIso8601String().substring(0, 10)}, max ${e.max}, '
      '${e.componentName.isEmpty ? '-' : e.componentName}  '
      '${e.publication.state.name}'
      '${e.publication.at == null ? '' : ' ${e.publication.at!.toLocal()}'}',
    );
  }
}

void _usage() {
  stderr.writeln(
    'Usage: dart run example/skore_create_evaluation_example.dart '
    'GRADEBOOK_ID PERIOD_ID TITLE YYYY-MM-DD MAX [--short=NAME] '
    '[--component=ID]',
  );
  exitCode = 64;
}
