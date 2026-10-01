// The live suite (#57): sends real messages to the own account, on the live
// Smartschool of credentials.yml, to check that sending still works there.
//
// It is local and on demand only. dart_test.yaml skips the suites tagged
// `live` without loading them, so `dart test` (CI, the Lefthook pre-commit
// hook) never runs it; `dart test -P live test/live` does (or, for this file
// alone, `dart test -P live test/live/messages_live_test.dart`, #62).
// Without a credentials.yml in the package root, it skips.
//
// The rules (the maintainer's, #57), which the tests and LiveWireGuard
// (support/live_wire_guard.dart, on the wire) both keep:
// - every message goes to the own account only (credentials.yml), in To, CC
//   or BCC, never to a group; replies only to a message this run sent to the
//   own account only, after checking that its reply form names the own
//   account alone;
// - every subject starts with `[dartschool test]` and the run's tag;
// - no LVS copy (`lvsCopy`) and no delayed send (`sendAt`, #58);
// - the run moves both copies of every message it sent (a message sent to
//   oneself has the same ID in the inbox and the sent box) to the trash at
//   the end, also when a test failed: the sent-box copies first, then the
//   inbox copies (out of the archive folder for the one it archived, #64),
//   once each, after checking the run's subject and that the own account
//   sent it, with moveToTrashFrom, which names the box of the copy (#60); it
//   never empties the trash;
// - it archives (moveToArchive) only the inbox copy of a message it sent,
//   once, while the inbox lists it with the run's subject (#64);
// - it sends no quick delete (moveToTrash) at all: that names the ID only,
//   Smartschool acts on whichever copy of the ID its session state points
//   to, and one of a copy in the trash deletes it for good (#19), so it is
//   never a guaranteed no-op, not even for ID 0 (#61); and it moves no ID it
//   did not send in the same run, 0 included;
// - it logs in at most once (usually not at all: the session is kept in
//   `.dart_tool/live_cache`, support/live_client.dart), and never with wrong
//   credentials; it prints no credential and no cookie;
// - it is the only live run in that session: it takes the session's lock
//   first, and refuses to start, before any request, while another live run
//   holds it (support/live_lock.dart, #62).
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose. network_guard_test.dart allows that only for a test file under
// test/live/ tagged `live`.
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, to the own account only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late MessagesService messages;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        messages = run.messages;
      });

      tearDownAll(() async {
        if (started == null) return; // setUpAll failed: nothing was sent.
        // Also when a test failed: moves what the cleanup test did not.
        try {
          final left = await run.cleanUp();
          for (final trashing in left) {
            print('tearDownAll cleanup: $trashing');
          }
          expect(
            left.where((t) => t.leftAlone != null),
            isEmpty,
            reason: 'messages of this run that the cleanup left alone',
          );
        } finally {
          await run.close();
        }
      });

      test('sendMessage to the own account is confirmed (#25) and arrives '
          'once, in the inbox and in the sent box', () async {
        final arrival = await run.original();

        expect(arrival.inbox, hasLength(1), reason: 'copies in the inbox');
        expect(arrival.sent, hasLength(1), reason: 'copies in the sent box');
        expect(
          arrival.sent.single.id,
          arrival.inbox.single.id,
          reason: 'a message sent to oneself has the same ID in both boxes',
        );
      });

      test('sendMessage uploads a small attachment, which arrives with the '
          'message', () async {
        final file = await run.attachment('attachment');
        final subject = run.subject('attachment');

        final arrival = await run.send(
          subject,
          () => messages.sendMessage(
            SendMessageParams(
              to: [run.own],
              subject: subject,
              bodyHtml: run.body('attachment'),
              attachmentPaths: [file.path],
            ),
          ),
        );

        expect(arrival.inbox, hasLength(1));
        expect(arrival.sent, hasLength(1));
        final received = arrival.inbox.single;
        expect(received.attachment, 1);
        final attachments = await messages.getAttachments(received.id);
        expect(attachments.map((a) => a.name), [p.basename(file.path)]);
        expect(
          await attachments.single.download(run.client),
          await file.readAsBytes(),
        );
      });

      test('sendReply is linked to the message it answers (hasReply, #26) '
          'and arrives once', () async {
        final original = (await run.original()).inbox.single.id;
        final before = await run.inboxHeader(original);
        expect(before, isNotNull);
        expect(before!.hasReply, isFalse, reason: 'not replied to yet');
        final recipients = await messages.getReplyRecipients(original);
        expect(
          run.ownOnly(recipients),
          isTrue,
          reason: 'the reply form must name the own account alone',
        );
        final (to, cc, bcc) = recipients;
        final subject = run.replySubject('reply');

        final arrival = await run.send(
          subject,
          () => messages.sendReply(
            original,
            SendMessageParams(
              to: to,
              cc: cc,
              bcc: bcc,
              subject: subject,
              bodyHtml: run.body('reply'),
            ),
          ),
        );

        expect(arrival.inbox, hasLength(1));
        expect(arrival.sent, hasLength(1));
        expect((await run.inboxHeader(original))?.hasReply, isTrue);
      });

      test('sendReply(all: true) arrives once (#26)', () async {
        final original = (await run.original()).inbox.single.id;
        final recipients = await messages.getReplyAllRecipients(original);
        expect(
          run.ownOnly(recipients),
          isTrue,
          reason: 'the reply-all form must name the own account alone',
        );
        final (to, cc, bcc) = recipients;
        final subject = run.replySubject('reply-all');

        final arrival = await run.send(
          subject,
          () => messages.sendReply(
            original,
            SendMessageParams(
              to: to,
              cc: cc,
              bcc: bcc,
              subject: subject,
              bodyHtml: run.body('reply-all'),
            ),
            all: true,
          ),
        );

        expect(arrival.inbox, hasLength(1));
        expect(arrival.sent, hasLength(1));
      });

      test('sendReply moves the recipient of the reply form from To to CC '
          '(#42)', () async {
        final original = (await run.original()).inbox.single.id;
        final recipients = await messages.getReplyRecipients(original);
        expect(
          run.ownOnly(recipients),
          isTrue,
          reason: 'the reply form must name the own account alone',
        );
        final (to, _, _) = recipients;
        final subject = run.replySubject('reply-to-cc');

        final arrival = await run.send(
          subject,
          () => messages.sendReply(
            original,
            SendMessageParams(
              to: const [],
              cc: to,
              subject: subject,
              bodyHtml: run.body('reply-to-cc'),
            ),
          ),
        );

        expect(arrival.inbox, hasLength(1));
        expect(arrival.sent, hasLength(1));
        final reply = await messages.getMessage(arrival.inbox.single.id);
        expect(reply, isNotNull);
        expect(reply!.receivers, isEmpty, reason: 'To');
        expect(reply.ccReceivers, hasLength(1), reason: 'CC');
      });

      test('MessageSendOptions(requestReadReceipt: true) throws before any '
          'request (#43)', () async {
        final subject = run.subject('read-receipt');
        run.expectNoSend(subject);
        final requests = run.guard.requestsSent;

        await expectLater(
          messages.sendMessage(
            SendMessageParams(
              to: [run.own],
              subject: subject,
              bodyHtml: run.body('read-receipt'),
              options: const MessageSendOptions(requestReadReceipt: true),
            ),
          ),
          throwsArgumentError,
        );
        expect(run.guard.requestsSent, requests, reason: 'requests sent');
      });

      test('moveToTrashFrom moves an archived message out of the archive '
          'folder (a boxId other than 0) to the trash, after its sent-box '
          'copy (#64)', () async {
        final subject = run.subject('archive');
        final arrival = await run.send(
          subject,
          () => messages.sendMessage(
            SendMessageParams(
              to: [run.own],
              subject: subject,
              bodyHtml: run.body('archive'),
            ),
          ),
        );
        expect(arrival.inbox, hasLength(1), reason: 'copies in the inbox');
        expect(arrival.sent, hasLength(1), reason: 'copies in the sent box');
        final id = arrival.inbox.single.id;
        expect(arrival.sent.single.id, id);

        // Archives the inbox copy (resolving the archive folder first).
        final archived = await run.archive(id, subject);
        final archiveBoxId = await messages.getArchiveBoxId();
        print(
          'archive scenario: message $id, archive folder $archiveBoxId (the '
          'guard read ${run.guard.archiveBoxId} on the Messages page); '
          'Smartschool answered the move to the archive with '
          '${run.guard.archiveAnswers[id]}',
        );
        expect(
          run.guard.archiveBoxId,
          archiveBoxId,
          reason: 'the archive folder that the Messages page names',
        );
        expect(archived.map((c) => (c.id, c.newValue)), [
          (id, 1),
        ], reason: "Smartschool's answer to the move to the archive");

        // The archive lists it (waiting up to half a minute), the inbox no
        // longer does.
        Future<List<int>> inArchive() async => [
          for (final m in await messages.getArchiveHeaders(boxId: archiveBoxId))
            if (m.subject == subject) m.id,
        ];
        var archivedIds = await inArchive();
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (archivedIds.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 2));
          archivedIds = await inArchive();
        }
        expect(archivedIds, [id], reason: 'the archive');
        expect(
          await run.listed(BoxType.inbox, subject),
          isEmpty,
          reason: 'the inbox',
        );

        // The sent-box copy first, then the archived inbox copy, each while
        // its box (folder) lists it with the run's subject.
        final sentCopy = await run.trash(id, subject, BoxType.sent);
        final archivedCopy = await run.trash(
          id,
          subject,
          BoxType.inbox,
          boxId: archiveBoxId,
        );
        print('archive scenario: $sentCopy');
        print('archive scenario: $archivedCopy');
        expect(sentCopy.leftAlone, isNull, reason: '$sentCopy');
        expect(archivedCopy.leftAlone, isNull, reason: '$archivedCopy');
        expect(
          run.guard.trashMoveAnswers[(id, BoxType.inbox.value)],
          contains('<command>silent</command>'),
          reason: "Smartschool's answer to the move out of the archive",
        );

        // Neither the archive nor the sent box (nor the inbox) lists it, and
        // the trash does.
        expect(await inArchive(), isEmpty, reason: 'the archive, at the end');
        expect(
          (await messages.getHeaders(boxType: BoxType.sent)).map((m) => m.id),
          isNot(contains(id)),
          reason: 'the sent box, at the end',
        );
        expect(
          (await messages.getHeaders()).map((m) => m.id),
          isNot(contains(id)),
          reason: 'the inbox, at the end',
        );
        expect(
          (await messages.getHeaders(boxType: BoxType.trash)).map((m) => m.id),
          contains(id),
          reason: 'the trash, at the end',
        );
      });

      test('moveToTrashFrom moves both copies of every message of the run to '
          'the trash, the sent-box copy first, and each move leaves the other '
          'copy alone (#60)', () async {
        // Where the run's messages are: the IDs that each box lists, and the
        // trash's header of each (the trash lists an ID once).
        Future<(Map<int, ShortMessage>, Set<int>, Set<int>)> boxes() async => (
          {
            for (final m in await messages.getHeaders(boxType: BoxType.trash))
              m.id: m,
          },
          (await messages.getHeaders()).map((m) => m.id).toSet(),
          (await messages.getHeaders(
            boxType: BoxType.sent,
          )).map((m) => m.id).toSet(),
        );

        final sentCopies = await run.cleanUp(boxes: const [BoxType.sent]);
        if (sentCopies.isEmpty) {
          markTestSkipped('this run sent no message');
          return;
        }
        final (trashAfterSent, inboxAfterSent, sentAfterSent) = await boxes();
        final inboxCopies = await run.cleanUp();
        final done = [...sentCopies, ...inboxCopies];
        for (final trashing in done) {
          print('cleanup: $trashing');
        }

        expect(
          done.where((t) => t.leftAlone != null),
          isEmpty,
          reason: 'copies the cleanup left alone',
        );
        final ids = sentCopies.map((t) => t.id).toSet();
        expect(sentCopies.map((t) => t.box), everyElement(BoxType.sent));
        expect(inboxCopies.map((t) => t.box), everyElement(BoxType.inbox));
        expect(inboxCopies.map((t) => t.id).toSet(), ids);
        for (final t in done) {
          // Smartschool's answer, as recorded: an acknowledgement without
          // details, the same whether it moved anything or not.
          expect(
            run.guard.trashMoveAnswers[(t.id, t.box.value)],
            contains('<command>silent</command>'),
            reason: "Smartschool's answer to the move of $t",
          );
        }
        final (trash, inbox, sent) = await boxes();
        for (final id in ids) {
          // The move of the sent-box copy left the inbox copy in the inbox.
          expect(trashAfterSent.keys, contains(id), reason: '$id: trash');
          expect(inboxAfterSent, contains(id), reason: '$id: inbox');
          expect(sentAfterSent, isNot(contains(id)), reason: '$id: sent box');
          // The move of the inbox copy left the message in the trash.
          expect(trash.keys, contains(id), reason: '$id: trash, at the end');
          expect(inbox, isNot(contains(id)), reason: '$id: inbox, at the end');
          expect(sent, isNot(contains(id)), reason: '$id: sent, at the end');
          // A reply marks the inbox copy of the message it answers
          // (hasReply), not its sent-box copy: the trash's header shows which
          // copy the trash lists.
          print(
            'message $id: after the sent-box copies, in the trash '
            '${trashAfterSent.containsKey(id)} (hasReply '
            '${trashAfterSent[id]?.hasReply}), in the inbox '
            '${inboxAfterSent.contains(id)}, in the sent box '
            '${sentAfterSent.contains(id)}; at the end, in the trash '
            '${trash.containsKey(id)} (hasReply ${trash[id]?.hasReply}), in '
            'the inbox ${inbox.contains(id)}, in the sent box '
            '${sent.contains(id)}',
          );
        }
      });
    },
  );
}
