import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: share a teacher's gradebook with another teacher in Skore, or
/// stop sharing it, after showing the change and asking for confirmation.
/// This needs Skore admin rights.
///
/// WARNING: this changes the live Skore of the school of `credentials.yml`,
/// which drives its grading and reports, and there is no test instance. Use
/// a gradebook that is not in use, and only on purpose.
///
/// Run with:
///   dart run example/skore_share_gradebook_example.dart \
///       OWNER_ID GRADEBOOK_ID TEACHER_ID read|write|remove
///
/// - `read` or `write` shares the gradebook with the teacher with read
///   access, or with read and write access (`SkoreService.shareGradebook`).
///   A teacher who has the other access already is moved.
/// - `remove` stops sharing it with the teacher
///   (`SkoreService.unshareGradebook`).
///
/// The other teachers the gradebook is shared with keep their access, and
/// the owner's other gradebooks are not touched.
///
/// The owner and the teacher are Smartschool user IDs (see `getTeachers`);
/// the gradebook ID is the ID of the assignment that holds it (see
/// `getCourses`, or `getGradebookShares` of the owner).
///
/// The flow:
///   1. Authenticate.
///   2. Read the owner's gradebooks and the teachers, and print the gradebook
///      as it is now.
///   3. Print the change, and ask for confirmation (y/N; anything but "y" or
///      "yes", or no answer, saves nothing).
///   4. Save it. The service reads the gradebooks again and checks the
///      change before it saves, and reads them again afterwards to check the
///      save. Print the change from the result: the teacher's access before
///      it as the service read it, whether it saved anything, and the
///      gradebook after it.
///   5. Only when the save was not confirmed: read the owner's gradebooks
///      again and print the gradebook as it is then.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main(List<String> args) async {
  final ids = args.take(3).map(int.tryParse).toList();
  final action = args.length == 4 ? args[3].toLowerCase() : null;
  const actions = {'read', 'write', 'remove'};
  if (args.length != 4 || ids.contains(null) || !actions.contains(action)) {
    stderr.writeln(
      'Usage: dart run example/skore_share_gradebook_example.dart '
      'OWNER_ID GRADEBOOK_ID TEACHER_ID read|write|remove',
    );
    exitCode = 64;
    return;
  }
  final ownerId = ids[0]!;
  final gradebookId = ids[1]!;
  final teacherId = ids[2]!;
  final access = switch (action) {
    'read' => SkoreShareAccess.read,
    'write' => SkoreShareAccess.write,
    _ => null,
  };

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

    final gradebook = (await skore.getGradebookShares(
      ownerId,
    )).where((g) => g.gradebookId == gradebookId).firstOrNull;
    if (gradebook == null) {
      print('Gradebook $gradebookId is not one of teacher $ownerId.');
      exitCode = 1;
      return;
    }
    final names = {for (final t in await skore.getTeachers()) t.id: t.name};
    String name(int id) => '${names[id] ?? 'unknown teacher'} ($id)';

    print('Owner:   ${name(ownerId)}');
    _printGradebook('Now:    ', gradebook, name);

    // ── 3. The change, and confirmation ───────────────────────────────────

    final current = gradebook.accessOf(teacherId);
    print(
      access == null
          ? 'Change:  stop sharing it with ${name(teacherId)} '
                '(now: ${current?.name ?? 'not shared'}).'
          : 'Change:  share it with ${name(teacherId)} with '
                '${access.name} access (now: ${current?.name ?? 'not shared'}).',
    );
    if (current == access) {
      print('Nothing to change.');
      return;
    }

    stdout.write('\nSave this change in Skore? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      print('Nothing saved.');
      return;
    }

    // ── 4. Save ───────────────────────────────────────────────────────────

    try {
      final change = access == null
          ? await skore.unshareGradebook(
              ownerId: ownerId,
              gradebookId: gradebookId,
              teacherId: teacherId,
            )
          : await skore.shareGradebook(
              ownerId: ownerId,
              gradebookId: gradebookId,
              teacherId: teacherId,
              access: access,
            );
      // The result holds the gradebook as the service read it before the
      // change (the access the teacher had then), whether it saved anything,
      // and the gradebook after it: no need to read the gradebooks again to
      // report the change.
      final before = change.accessBefore?.name ?? 'not shared';
      final after = change.accessAfter?.name ?? 'not shared';
      print(
        change.saved
            ? '✓ Saved: ${name(teacherId)} now $after (was $before).'
            : 'Nothing saved: ${name(teacherId)} was already $before when '
                  'the service checked.',
      );
      print('');
      _printGradebook('After:  ', change, name);
      return;
    } on SmartschoolSkoreError catch (e) {
      // A check before the save refused it: nothing was saved.
      print('Not saved: ${e.message}');
      exitCode = 1;
      return;
    } on SmartschoolSkoreSaveUnconfirmedError catch (e) {
      // Read the gradebooks again below: it shows whether the save went
      // through.
      print('UNCONFIRMED: ${e.message}');
      exitCode = 1;
    }

    // ── 5. Unconfirmed: read the gradebooks again ─────────────────────────

    final after = (await skore.getGradebookShares(
      ownerId,
    )).where((g) => g.gradebookId == gradebookId).firstOrNull;
    if (after == null) {
      print('Gradebook $gradebookId is no longer one of teacher $ownerId.');
      exitCode = 1;
      return;
    }
    print('');
    _printGradebook('After:  ', after, name);
  } finally {
    await client.dispose();
  }
}

/// Prints [gradebook] and the teachers it is shared with after [prefix].
void _printGradebook(
  String prefix,
  SkoreGradebookShares gradebook,
  String Function(int id) name,
) {
  print(
    '$prefix ${gradebook.className} / ${gradebook.courseName} '
    '(gradebook ${gradebook.gradebookId})',
  );
  if (gradebook.readerIds.isEmpty && gradebook.writerIds.isEmpty) {
    print('         (not shared)');
  }
  for (final id in gradebook.readerIds) {
    print('         read:  ${name(id)}');
  }
  for (final id in gradebook.writerIds) {
    print('         write: ${name(id)}');
  }
}
