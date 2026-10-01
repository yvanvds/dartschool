// The live suite (#57): sends real messages to the own account, on the live
// Smartschool of credentials.yml, to check that sending still works there.
//
// It is local and on demand only. dart_test.yaml skips the suites tagged
// `live` without loading them, so `dart test` (CI, the Lefthook pre-commit
// hook) never runs it; `dart test -P live` does. Without a credentials.yml in
// the package root, it skips.
//
// The rules (the maintainer's, #57), which the tests and LiveWireGuard
// (support/live_wire_guard.dart, on the wire) both keep:
// - every message goes to the own account only (credentials.yml), in To, CC
//   or BCC, never to a group; replies only to a message this run sent to the
//   own account only, after checking that its reply form names the own
//   account alone;
// - every subject starts with `[dartschool test]` and the run's tag;
// - no LVS copy (`lvsCopy`) and no delayed send (`sendAt`, #58);
// - the run moves every message it sent to the trash at the end, also when
//   a test failed, once each, after checking the run's subject and that the
//   own account sent it; it never moves a message that is in the trash
//   already (that deletes it for good, #19), and never empties the trash
//   (the sent box keeps its copy of each message, #60);
// - it logs in at most once (usually not at all: the session is kept in
//   `.dart_tool/live_cache`, support/live_client.dart), and never with wrong
//   credentials; it prints no credential and no cookie.
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

      test('moveToTrash(0): what Smartschool answers when it deletes nothing '
          '(#19), and moveToTrash returns null (#59)', () async {
        // ID 0 names no message. Seen live on 2026-10-01: Smartschool answers
        // with an empty body, which moveToTrash reports as nothing deleted
        // (null) since #59; it threw a SmartschoolParsingError before.
        final status = await messages.moveToTrash(0);
        final answer = run.guard.quickDeleteAnswers[0];
        print('Smartschool answered: "$answer"');
        expect(answer?.trim(), isEmpty, reason: "Smartschool's answer");
        expect(status, isNull);
      });

      test('moveToTrash moves every message of the run to the trash and '
          'reports it deleted (#19)', () async {
        final done = await run.cleanUp();
        if (done.isEmpty) {
          markTestSkipped('this run sent no message');
          return;
        }
        for (final trashing in done) {
          print('cleanup: $trashing');
        }

        expect(
          done.where((t) => t.leftAlone != null),
          isEmpty,
          reason: 'messages the cleanup left alone',
        );
        for (final trashing in done) {
          expect(trashing.status, isNotNull, reason: '${trashing.id}');
          expect(trashing.status!.isDeleted, isTrue, reason: '${trashing.id}');
          expect(trashing.status!.msgId, trashing.id);
        }
        final trash = (await messages.getHeaders(
          boxType: BoxType.trash,
        )).map((m) => m.id).toSet();
        final inbox = (await messages.getHeaders()).map((m) => m.id).toSet();
        final sent = (await messages.getHeaders(
          boxType: BoxType.sent,
        )).map((m) => m.id).toSet();
        for (final trashing in done) {
          final id = trashing.id;
          expect(trash, contains(id), reason: 'message $id in the trash');
          if (trashing.box == BoxType.inbox) {
            expect(inbox, isNot(contains(id)), reason: 'message $id in inbox');
          }
          print(
            'message $id: in the trash ${trash.contains(id)}, in the inbox '
            '${inbox.contains(id)}, in the sent box ${sent.contains(id)}',
          );
        }
      });
    },
  );
}
