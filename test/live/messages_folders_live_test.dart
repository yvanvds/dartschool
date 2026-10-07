// The live reads of the account's own message folders (#136):
// MessagesService.getFolders, and the listing of a folder with getAllHeaders
// and getHeaderPages, against the live Smartschool of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/messages_folders_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// Its test spot is the folder "dartschool test" directly in the inbox of the
// live account (box ID 30650), made for #136 on 2026-10-07 with three
// messages moved into it from the archive. The folder and its messages stay
// as they are: this file only reads, so it moves, marks, flags, archives or
// trashes nothing, makes and removes no folder, and the last test checks
// that no other command went out (LiveWireGuard, the last interceptor,
// refuses those too). It reads the folder tree (`quickactions` /
// `requestmovelist`), the Messages page (getArchiveBoxId), the test folder
// and the first pages of the archive (`message list`, `continue_messages`),
// and one message of the test folder (`show message`, which leaves its read
// state as it is: the test checks that too).
//
// Listing the archive restarts the account's paging of the archive
// elsewhere (#76): a paging of it in the web client or smartschool-mcp at
// the same time would fail and need to list it again. As every live run, it
// takes the lock of the session first, logs in at most once, and prints no
// credential, no cookie, and nothing of the messages but their IDs.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

/// The folder of the live account that this file reads: directly in the
/// inbox, made for #136.
const _testFolder = (id: 30650, name: 'dartschool test');

/// Records every request the library tries to send, before LiveWireGuard
/// decides whether it goes out: `subsystem/action` for an XML command,
/// `METHOD path` for anything else.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final data = options.data;
    final command = data is Map ? data['command'] : null;
    if (command is String) {
      final xml = XmlDocument.parse(command);
      String text(String name) =>
          xml.findAllElements(name).firstOrNull?.innerText ?? '';
      requests.add('${text('subsystem')}/${text('action')}');
    } else {
      requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    }
    handler.next(options);
  }
}

/// The IDs of [headers], each with whether it is unread.
Map<int, bool> _readStates(List<ShortMessage> headers) => {
  for (final header in headers) header.id: header.unread,
};

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only (#136):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late MessagesService messages;
      late _Attempts attempts;

      /// The folders of the account, as getFolders gives them.
      late List<MessageFolder> folders;

      /// The test folder, as getFolders gives it.
      late MessageFolder testFolder;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        messages = run.messages;

        folders = await messages.getFolders();
        testFolder = MessageFolder.flatten(
          folders,
        ).singleWhere((f) => f.id == _testFolder.id);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('getFolders lists the test folder directly in the inbox, and the '
          'archive, the folder getArchiveBoxId names', () async {
        expect(testFolder.boxType, BoxType.inbox);
        expect(testFolder.name, _testFolder.name);
        expect(testFolder.path, [_testFolder.name]);
        expect(testFolder.parentId, isNull);
        expect(testFolder.isArchive, isFalse);
        expect(folders.map((f) => f.id), contains(_testFolder.id));

        final flat = MessageFolder.flatten(folders);
        final archive = flat.where((f) => f.isArchive).single;
        expect(archive.boxType, BoxType.inbox);
        expect(archive.parentId, isNull);
        expect(archive.id, await messages.getArchiveBoxId());

        // Box IDs are unique within a box, and never 0 (the box itself).
        for (final type in BoxType.values) {
          final ids = [
            for (final f in flat)
              if (f.boxType == type) f.id,
          ];
          expect(ids.toSet(), hasLength(ids.length), reason: '$type');
        }
        expect(flat.map((f) => f.id), everyElement(greaterThan(0)));
        // A folder of a box Smartschool moves messages to: no drafts or
        // scheduled box.
        expect(
          flat.map((f) => f.boxType),
          everyElement(isIn([BoxType.inbox, BoxType.sent, BoxType.trash])),
        );
      });

      test('getAllHeaders lists the messages of the test folder, and '
          'getMessage reads one of them, without changing their read '
          'state', () async {
        final headers = await messages.getAllHeaders(
          boxType: testFolder.boxType,
          boxId: testFolder.id,
        );
        expect(headers, isNotEmpty, reason: 'the test folder holds messages');
        expect(headers.map((h) => h.realBox), everyElement('inbox'));

        // One that is read already, when there is one.
        final header = headers.firstWhere(
          (h) => !h.unread,
          orElse: () => headers.first,
        );
        final message = await messages.getMessage(
          header.id,
          boxType: testFolder.boxType,
        );
        expect(message?.id, header.id);

        final again = await messages.getAllHeaders(
          boxType: testFolder.boxType,
          boxId: testFolder.id,
        );
        expect(_readStates(again), _readStates(headers));
      });

      test('the archive and the test folder keep a paging position each: '
          'listing the folder between the second and the third page of the '
          'archive does not restart the archive\'s paging', () async {
        final archive = MessageFolder.flatten(
          folders,
        ).singleWhere((f) => f.isArchive);
        // Whether the archive has a third page to get.
        final probe = await messages
            .getHeaderPages(boxType: archive.boxType, boxId: archive.id)
            .take(3)
            .toList();
        if (probe.length < 3) {
          markTestSkipped('the archive holds less than three pages');
          return;
        }

        final paging = StreamIterator(
          messages.getHeaderPages(boxType: archive.boxType, boxId: archive.id),
        );
        try {
          expect(await paging.moveNext(), isTrue);
          final seen = {for (final h in paging.current) h.id};
          expect(await paging.moveNext(), isTrue);
          seen.addAll(paging.current.map((h) => h.id));

          final inFolder = await messages.getHeaders(
            boxType: testFolder.boxType,
            boxId: testFolder.id,
          );
          expect(inFolder, isNotEmpty);

          // Had the folder's listing restarted the archive's paging,
          // Smartschool would answer with its second page again, and the
          // stream would fail with a SmartschoolPagingRestartedError.
          expect(await paging.moveNext(), isTrue);
          final third = paging.current.map((h) => h.id).toList();
          expect(third, isNotEmpty);
          expect(third.where(seen.contains), isEmpty);
        } finally {
          await paging.cancel();
        }
        expect(attempts.requests.reversed.take(4).toList().reversed.toList(), [
          'postboxes/message list',
          'postboxes/continue_messages',
          'postboxes/message list',
          'postboxes/continue_messages',
        ]);
      });

      test('nothing but reads went out: the folder tree, listings, a message '
          'and pages (GETs)', () {
        const reads = {
          'quickactions/requestmovelist',
          'postboxes/message list',
          'postboxes/continue_messages',
          'postboxes/show message',
        };
        expect(
          attempts.requests.where(
            (r) => !reads.contains(r) && !r.startsWith('GET '),
          ),
          isEmpty,
        );
        expect(
          attempts.requests.where((r) => r == 'quickactions/requestmovelist'),
          hasLength(1),
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
