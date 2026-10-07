// The live writes of IntradeskService (#128): a folder, a weblink in it and
// an uploaded file, made in the Intradesk folder of the live suite, "tests"
// in "2. SMA" at the root (found by name), checked in Smartschool's
// listings, the file downloaded back, and all of it moved to the trash
// again, against the live Intradesk of credentials.yml. The new folder is
// also read by its ID alone (getFolder, getFolderPath, #132), before and
// after its move to the trash. Before the moves to the trash, it sends a
// made-up ID and the IDs of its own items as another kind to the trash, and
// checks that Intradesk has no such item
// (SmartschoolIntradeskItemNotFoundError) and moved nothing (#133). The
// creates read the folder they add to first (#138): a confidential folder
// in the test folder (an ordinary one) and a weblink in the run's folder
// once it is in the trash are refused before anything is sent.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/intradesk_write_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// That folder is the only place where the live suite writes in Intradesk.
// It must be empty when the run starts (the run refuses to write otherwise),
// and the run leaves it empty: it moves everything it made to Intradesk's
// trash (`POST .../{kind}/{id}/trash`), also when a test failed, and checks
// that the folder is empty again. It never deletes for good. Every folder
// and weblink it makes is named "dartschool test <run tag> ...", every file
// "dartschool-test-<run tag>-....txt". LiveWireGuard
// (support/live_wire_guard.dart) refuses on the wire any Intradesk write
// outside that folder (as Smartschool's own listings name it, read through
// the guard) and the folders the run made in it, a name without the run's
// tag, a move to the trash of anything the run did not make (but a made-up
// ID the guard made up itself, and an item of the run as another kind, once
// and when the run allows it, #133), and every other Intradesk POST. As
// every live run, it takes the lock of the session first, logs in at most
// once, and prints no credential and no cookie.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/live_wire_guard.dart';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, in the Intradesk test folder (#128):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late IntradeskService intradesk;

      /// The test folder: "tests" in "2. SMA" at the root.
      late IntradeskFolder tests;

      /// What the run made, as (kind, ID), in order; and what it moved to
      /// the trash already.
      final made = <(String, String)>[];
      final trashed = <String>{};

      /// The first folder the run made in the test folder, and the file it
      /// uploaded into it.
      IntradeskFolder? folder;
      IntradeskFile? file;

      String name(String what) => '$liveIntradeskPrefix ${run.tag} $what';

      Future<void> trash(String kind, String id) async {
        switch (kind) {
          case 'files':
            await intradesk.trashFile(id);
          case 'weblinks':
            await intradesk.trashWeblink(id);
          default:
            await intradesk.trashFolder(id);
        }
        trashed.add(id);
      }

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        intradesk = IntradeskService(run.client);

        final (parentName, folderName) = liveIntradeskFolder;
        final root = await intradesk.getRootListing();
        final parents = root.folders
            .where((f) => f.name == parentName && f.parentFolderId.isEmpty)
            .toList();
        if (parents.length != 1) {
          throw StateError(
            'Intradesk has ${parents.length} folders "$parentName" at the '
            'root, not one: the live suite writes nowhere.',
          );
        }
        final candidates = (await intradesk.getFolderListing(
          parents.single.id,
        )).folders.where((f) => f.name == folderName).toList();
        if (candidates.length != 1) {
          throw StateError(
            '"$parentName" holds ${candidates.length} folders "$folderName", '
            'not one: the live suite writes nowhere.',
          );
        }
        tests = candidates.single;
        final before = await intradesk.getFolderListing(tests.id);
        if (before.folders.isNotEmpty ||
            before.files.isNotEmpty ||
            before.weblinks.isNotEmpty) {
          throw StateError(
            'The Intradesk test folder "$parentName" > "$folderName" is not '
            'empty ($before): empty it first; the live suite writes in an '
            'empty test folder only.',
          );
        }
        run.guard.allowIntradeskFolder(tests.id);
      });

      tearDownAll(() async {
        try {
          // Files and weblinks first, then the folders, as they were made
          // in reverse; what a test moved to the trash already is left.
          final failures = <String>[];
          for (final (kind, id) in made.reversed) {
            if (trashed.contains(id)) continue;
            try {
              await trash(kind, id);
            } on Object catch (e) {
              failures.add('$kind $id: $e');
            }
          }
          if (started != null && made.isNotEmpty) {
            final after = await intradesk.getFolderListing(tests.id);
            expect(
              [
                ...after.folders.map((f) => f.name),
                ...after.weblinks.map((w) => w.name),
                ...after.files.map((f) => f.name),
              ],
              isEmpty,
              reason:
                  'the test folder is empty again after the run '
                  '(failures: $failures)',
            );
          }
          expect(failures, isEmpty);
        } finally {
          await started?.close();
        }
      });

      test('createFolder adds a folder to the test folder, as its listing '
          'shows it', () async {
        final made0 = await intradesk.createFolder(
          parentFolderId: tests.id,
          name: name('map'),
          color: 'green',
        );
        made.add(('folders', made0.id));
        folder = made0;

        expect(made0.name, name('map'));
        expect(made0.color, 'green');
        expect(made0.parentFolderId, tests.id);
        expect(made0.confidential, isFalse);
        expect(made0.hasChildren, isFalse);
        final listed = (await intradesk.getFolderListing(
          tests.id,
        )).folders.where((f) => f.id == made0.id).toList();
        expect(listed.map((f) => (f.name, f.color)), [(name('map'), 'green')]);
      });

      test('createFolder with a name that is taken: Intradesk renames the new '
          'folder rather than refusing it', () async {
        final first = folder;
        expect(first, isNotNull, reason: 'the first test made a folder');

        final twin = await intradesk.createFolder(
          parentFolderId: tests.id,
          name: name('map'),
        );
        made.add(('folders', twin.id));

        expect(twin.id, isNot(first!.id));
        expect(twin.name, '${name('map')} (1)');
        expect(twin.color, IntradeskService.defaultFolderColor);
      });

      test('createFolder of a confidential folder in the test folder, an '
          'ordinary folder: refused after reading the folder, before anything '
          'is sent (#138)', () async {
        // Intradesk answered this create with HTTP 400 on 2026-10-05; since
        // #138 the service does not send it. LiveWireGuard would refuse it
        // on the wire too (the live suite makes no confidential folder), as
        // a violation.
        await expectLater(
          intradesk.createFolder(
            parentFolderId: tests.id,
            name: name('vertrouwelijk'),
            confidential: true,
          ),
          throwsA(
            isA<SmartschoolIntradeskAddRefusedError>()
                .having(
                  (e) => e.reason,
                  'reason',
                  IntradeskAddRefusalReason.ordinaryParent,
                )
                .having((e) => e.statusCode, 'statusCode', isNull)
                .having((e) => e.parentFolderId, 'parentFolderId', tests.id)
                .having((e) => e.parent?.id, 'parent.id', tests.id)
                .having(
                  (e) => e.parent?.confidential,
                  'parent.confidential',
                  isFalse,
                )
                .having(
                  (e) => e.capabilities.canAdd,
                  'capabilities.canAdd',
                  isTrue,
                ),
          ),
        );
        expect(run.guard.violations, isEmpty);
        final listed = await intradesk.getFolderListing(tests.id);
        expect(
          listed.folders.where((f) => f.name.contains('vertrouwelijk')),
          isEmpty,
        );
      });

      test('getFolder and getFolderPath read the new folder by its ID alone '
          '(#132)', () async {
        final made0 = folder;
        expect(made0, isNotNull, reason: 'the first test made a folder');

        final parentIds = await intradesk.getFolderParentIds(made0!.id);
        final read = await intradesk.getFolder(made0.id);
        final path = await intradesk.getFolderPath(made0.id);

        expect(parentIds, [tests.parentFolderId, tests.id]);
        expect(read.id, made0.id);
        expect(read.name, made0.name);
        expect(read.color, 'green');
        expect(read.parentFolderId, tests.id);
        expect(read.confidential, isFalse);
        expect(read.capabilities.canAdd, isTrue);
        expect(path.map((f) => f.id), [
          tests.parentFolderId,
          tests.id,
          made0.id,
        ]);
        expect(path.last.name, made0.name);
      });

      test('createWeblink adds a weblink to the new folder, with the address '
          'sent as the web client sends it', () async {
        final parent = folder;
        expect(parent, isNotNull, reason: 'the first test made a folder');

        final made0 = await intradesk.createWeblink(
          parentFolderId: parent!.id,
          name: name('link'),
          url: 'example.com/dartschool',
        );
        made.add(('weblinks', made0.id));

        expect(made0.name, name('link'));
        expect(made0.url, 'http://example.com/dartschool');
        expect(made0.icon, IntradeskService.defaultWeblinkIcon);
        expect(made0.parentFolderId, parent.id);
        final listed = (await intradesk.getFolderListing(parent.id)).weblinks;
        expect(listed.map((w) => (w.id, w.name, w.url)), [
          (made0.id, name('link'), 'http://example.com/dartschool'),
        ]);
      });

      test('uploadFiles adds a file to the new folder, which downloads back '
          'unchanged', () async {
        final parent = folder;
        expect(parent, isNotNull, reason: 'the first test made a folder');
        final local = await run.attachment('intradesk');
        final fileName = local.uri.pathSegments.last;

        final result = await intradesk.uploadFiles(
          parentFolderId: parent!.id,
          filePaths: [local.path],
        );
        for (final uploaded in result.files) {
          made.add(('files', uploaded.id));
        }

        expect(result.failures, isEmpty);
        expect(result.files.map((f) => f.name), [fileName]);
        file = result.files.single;
        expect(file!.parentFolderId, parent.id);
        expect(file!.currentRevision?.fileSize, await local.length());
        final listed = (await intradesk.getFolderListing(parent.id)).files;
        expect(listed.map((f) => (f.id, f.name)), [(file!.id, fileName)]);
        expect(
          await intradesk.downloadFile(file!.id),
          await local.readAsBytes(),
        );
      });

      test('a move to the trash of an ID Intradesk has no such item for: a '
          'made-up ID, and the IDs of the file, weblink and folder of the run '
          'as another kind, is a SmartschoolIntradeskItemNotFoundError, and '
          'moves nothing (#133)', () async {
        final parent = folder;
        final link = made.where((m) => m.$1 == 'weblinks').firstOrNull?.$2;
        expect(parent, isNotNull, reason: 'the first test made a folder');
        expect(link, isNotNull, reason: 'a test before made a weblink');
        expect(file, isNotNull, reason: 'a test before uploaded a file');
        Matcher notFound(IntradeskItemKind kind, String id) =>
            isA<SmartschoolIntradeskItemNotFoundError>()
                .having((e) => e.kind, 'kind', kind)
                .having((e) => e.id, 'id', id)
                .having((e) => e.statusCode, 'statusCode', 404);

        final madeUp = run.guard.newMadeUpIntradeskId();
        await expectLater(
          intradesk.trashFolder(madeUp),
          throwsA(notFound(IntradeskItemKind.folder, madeUp)),
        );
        await expectLater(
          intradesk.trashWeblink(madeUp),
          throwsA(notFound(IntradeskItemKind.weblink, madeUp)),
        );
        await expectLater(
          intradesk.trashFile(madeUp),
          throwsA(notFound(IntradeskItemKind.file, madeUp)),
        );
        run.guard.allowIntradeskTrashAs(file!.id, 'folders');
        await expectLater(
          intradesk.trashFolder(file!.id),
          throwsA(notFound(IntradeskItemKind.folder, file!.id)),
        );
        run.guard.allowIntradeskTrashAs(parent!.id, 'weblinks');
        await expectLater(
          intradesk.trashWeblink(parent.id),
          throwsA(notFound(IntradeskItemKind.weblink, parent.id)),
        );
        run.guard.allowIntradeskTrashAs(link!, 'files');
        await expectLater(
          intradesk.trashFile(link),
          throwsA(notFound(IntradeskItemKind.file, link)),
        );

        // Nothing moved: the folder, its weblink and its file are where they
        // were.
        final inTests = await intradesk.getFolderListing(tests.id);
        expect(inTests.folders.map((f) => f.id), contains(parent.id));
        final inFolder = await intradesk.getFolderListing(parent.id);
        expect(inFolder.weblinks.map((w) => w.id), [link]);
        expect(inFolder.files.map((f) => f.id), [file!.id]);
        expect(run.guard.violations, isEmpty);
      });

      test('the moves to the trash: the file, the weblink and the folders '
          'leave the listings, and the test folder is empty again', () async {
        expect(
          made,
          hasLength(4),
          reason: 'the tests before made two folders, a weblink and a file',
        );

        for (final (kind, id) in made.reversed) {
          await trash(kind, id);
        }

        final inTests = await intradesk.getFolderListing(tests.id);
        expect(inTests.folders, isEmpty);
        expect(inTests.weblinks, isEmpty);
        expect(inTests.files, isEmpty);
        expect(run.guard.violations, isEmpty);
      });

      test('a folder in the trash: Smartschool answers its parents as those '
          'of a folder at the root, and getFolder does not take it for one '
          '(#132)', () async {
        final inTrash = folder;
        expect(inTrash, isNotNull, reason: 'the first test made a folder');
        expect(
          trashed,
          contains(inTrash!.id),
          reason: 'the test before moved it to the trash',
        );

        expect(await intradesk.getFolderParentIds(inTrash.id), isEmpty);
        await expectLater(
          intradesk.getFolder(inTrash.id),
          throwsA(
            isA<SmartschoolIntradeskFolderNotFoundError>()
                .having((e) => e.folderId, 'folderId', inTrash.id)
                .having((e) => e.statusCode, 'statusCode', 200)
                .having((e) => e.message, 'message', contains('trash')),
          ),
        );
        await expectLater(
          intradesk.getFolderPath(inTrash.id),
          throwsA(isA<SmartschoolIntradeskFolderNotFoundError>()),
        );
      });

      test('a create in the folder in the trash: the read of the parent does '
          'not find it, and nothing is sent (#138)', () async {
        final inTrash = folder;
        expect(inTrash, isNotNull, reason: 'the first test made a folder');
        expect(trashed, contains(inTrash!.id));

        // LiveWireGuard would refuse it on the wire too (no write in a
        // folder of the run that is in the trash), as a violation.
        await expectLater(
          intradesk.createWeblink(
            parentFolderId: inTrash.id,
            name: name('link in de prullenbak'),
            url: 'https://example.com/dartschool',
          ),
          throwsA(
            isA<SmartschoolIntradeskFolderNotFoundError>()
                .having((e) => e.folderId, 'folderId', inTrash.id)
                .having((e) => e.statusCode, 'statusCode', 200)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    startsWith('createWeblink:'),
                    contains('trash'),
                    endsWith('Nothing was sent.'),
                  ),
                ),
          ),
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
