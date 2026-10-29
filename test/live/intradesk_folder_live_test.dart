// The live reads of a folder's own entry by its ID alone (#132):
// IntradeskService.getFolderParentIds, getFolder and getFolderPath, compared
// with the listings that hold the folders, and of the root's capabilities
// (getRootCapabilities, the Intradesk page, #138), against the live
// Intradesk of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/intradesk_folder_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// It only reads (GETs): the root listing, the listing of "2. SMA" (the
// folder that holds the live suite's test folder, "tests"), and of one
// folder in it with subfolders, and the parents of those folders, of a
// made-up ID and of a file; and the Intradesk page (`GET /intradesk`) for
// the root's capabilities. The last test checks that the library did not
// even try an Intradesk request that is not a GET. What it does with a
// folder in the trash needs a
// folder moved there, so intradesk_write_live_test.dart tries that, with a
// folder it made. As every live run, it takes the lock of the session first,
// logs in at most once, and prints no credential, no cookie and no folder
// name: names are compared in the test, never shown (support/unshown.dart:
// `expect` shows the actual value of a failed match whatever the matcher,
// so a failure shows the fields that differ, not their values, #215).
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/live_wire_guard.dart';
import 'support/unshown.dart';

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

/// [folder] as the fields the reads of #132 are for, to compare a folder
/// read by its ID with the one a listing gives: its ID, name, colour, parent,
/// whether it is confidential (or in a confidential folder), visible, has
/// subfolders, and its capabilities.
Map<String, Object> _entry(IntradeskFolder folder) => {
  'id': folder.id,
  'name': folder.name,
  'color': folder.color,
  'state': folder.state,
  'parentFolderId': folder.parentFolderId,
  'visible': folder.visible,
  'confidential': folder.confidential,
  'inConfidentialFolder': folder.inConfidentialFolder,
  'hasChildren': folder.hasChildren,
  'canManage': folder.capabilities.canManage,
  'canAdd': folder.capabilities.canAdd,
  'canSeeHistory': folder.capabilities.canSeeHistory,
  'dateCreated': folder.dateCreated,
};

/// Expects [actual] to be the entry [expected] (see [_entry]), and shows no
/// folder name when it fails: only [what] and the fields that differ.
void _expectSameEntry(
  IntradeskFolder actual,
  IntradeskFolder expected,
  String what,
) => expectSameFieldsUnshown(_entry(actual), _entry(expected), reason: what);

/// Expects [path] to be the entries [expected], folder by folder (see
/// [_entry]), and shows no folder name when it fails: only [what], the
/// number of folders and the fields that differ.
void _expectSamePath(
  List<IntradeskFolder> path,
  List<IntradeskFolder> expected,
  String what,
) {
  expect(path.length, expected.length, reason: '$what: the number of folders');
  for (var i = 0; i < expected.length; i++) {
    _expectSameEntry(path[i], expected[i], '$what, folder ${i + 1}');
  }
}

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only (#132):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late IntradeskService intradesk;
      late _Attempts attempts;

      /// "2. SMA" at the root, as the root listing gives it, and what it
      /// holds.
      late IntradeskFolder sma;
      late IntradeskListing inSma;

      /// "tests" in "2. SMA", as the listing of "2. SMA" gives it.
      late IntradeskFolder tests;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        intradesk = IntradeskService(run.client);

        final (parentName, folderName) = liveIntradeskFolder;
        sma = (await intradesk.getRootListing()).folders.singleWhere(
          (f) => f.name == parentName,
        );
        inSma = await intradesk.getFolderListing(sma.id);
        tests = inSma.folders.singleWhere((f) => f.name == folderName);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('getFolderParentIds gives the folders above the test folder, '
          'and none above a folder at the root', () async {
        expect(await intradesk.getFolderParentIds(tests.id), [sma.id]);
        expect(await intradesk.getFolderParentIds(sma.id), isEmpty);
      });

      test('getFolder reads the test folder by its ID alone, as the listing '
          'of its parent gives it', () async {
        final folder = await intradesk.getFolder(tests.id);

        _expectSameEntry(
          folder,
          tests,
          'getFolder of the test folder, against the listing of its parent',
        );
        expect(folder.parentFolderId, sma.id);
        // The live account adds to it: the writes of the live suite do.
        expect(folder.capabilities.canAdd, isTrue);
        expect(folder.confidential, isFalse);
      });

      test('getFolder reads a folder at the root, as the root listing gives '
          'it', () async {
        final folder = await intradesk.getFolder(sma.id);

        _expectSameEntry(
          folder,
          sma,
          'getFolder of a folder at the root, against the root listing',
        );
        expect(folder.parentFolderId, isEmpty);
      });

      test('getFolderPath of the test folder is "2. SMA" > "tests"', () async {
        final path = await intradesk.getFolderPath(tests.id);

        _expectSamePath(path, [sma, tests], 'getFolderPath of the test folder');
      });

      test('getFolderPath of a folder two levels down names the folders '
          'above it', () async {
        final withSubfolders = inSma.folders
            .where((f) => f.hasSubfolders && f.id != tests.id)
            .firstOrNull;
        if (withSubfolders == null) {
          markTestSkipped('no folder with subfolders in "2. SMA"');
          return;
        }
        final deeper = (await intradesk.getFolderListing(
          withSubfolders.id,
        )).folders.first;

        expect(await intradesk.getFolderParentIds(deeper.id), [
          sma.id,
          withSubfolders.id,
        ]);
        _expectSameEntry(
          await intradesk.getFolder(deeper.id),
          deeper,
          'getFolder of a folder two levels down, against its listing',
        );
        _expectSamePath(await intradesk.getFolderPath(deeper.id), [
          sma,
          withSubfolders,
          deeper,
        ], 'getFolderPath of a folder two levels down');
        // In capitals, as Smartschool takes it.
        _expectSameEntry(
          await intradesk.getFolder(deeper.id.toUpperCase()),
          deeper,
          'getFolder of a folder two levels down, its ID in capitals',
        );
      });

      test('a made-up ID and the ID of a file are no folder: '
          'SmartschoolIntradeskFolderNotFoundError, status 404', () async {
        const madeUp = '00000000-0000-4000-8000-000000000000';
        Matcher notFound(String id) => throwsA(
          isA<SmartschoolIntradeskFolderNotFoundError>()
              .having((e) => e.folderId, 'folderId', id)
              .having((e) => e.statusCode, 'statusCode', 404),
        );

        await expectLater(intradesk.getFolder(madeUp), notFound(madeUp));
        await expectLater(intradesk.getFolderPath(madeUp), notFound(madeUp));
        final file = inSma.files.firstOrNull;
        if (file == null) {
          markTestSkipped('no file in "2. SMA" to ask for as a folder');
          return;
        }
        await expectLater(
          intradesk.getFolderParentIds(file.id),
          notFound(file.id),
        );
      });

      test('getRootCapabilities reads the root\'s capabilities from the '
          'Intradesk page (#138)', () async {
        final capabilities = await intradesk.getRootCapabilities();

        // As the page's configuration had them for the live account (an
        // administrator) on 2026-10-07: it may add at the root, and the
        // platform allows no confidential folder there.
        expect(capabilities.canAdd, isTrue);
        expect(capabilities.canManage, isTrue);
        expect(capabilities.canAddConfidentialFolder, isFalse);
        expect(
          attempts.requests.where((r) => r == 'GET /intradesk'),
          hasLength(1),
        );
      });

      test('nothing but GETs was tried in Intradesk', () {
        expect(
          attempts.requests.where(
            (r) => r.contains(' /intradesk/') && !r.startsWith('GET '),
          ),
          isEmpty,
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
