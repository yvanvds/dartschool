import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: send a message to yourself, archive it, then move both of its
/// copies to the trash, verifying each step with a fresh API poll.
///
/// WARNING: this example changes a real Smartschool account, the one of
/// `credentials.yml`. It sends a real message to that account, and to that
/// account only (the recipient is the logged-in user, from
/// `getCurrentUserAsRecipient()`: never add another one). It then archives
/// the message and moves its two copies, the archived inbox copy and the
/// sent-box copy, to the trash. It moves no other message, never empties
/// the trash and deletes nothing for good: empty the trash yourself if you
/// want the test message gone. Use a test account if you have one.
///
/// Run with:
///   dart run example/send_message_lifecycle_example.dart
///
/// The flow:
///   1. Authenticate.
///   2. Resolve the logged-in user as a recipient from the compose form.
///   3. Send a timestamped test message to yourself, and to nobody else.
///   4. Poll the inbox (up to 15 s, every 2 s) until the test message
///      appears, then find its copy in the sent box: a message you send
///      yourself has the same ID in the inbox and in the sent box.
///   5. Archive the inbox copy and poll the archive folder (its box ID from
///      `getArchiveBoxId()`) to confirm it is there.
///   6. Verify the message has disappeared from the inbox.
///   7. Move both copies to the trash with `moveToTrashFrom`, the sent-box
///      copy first (`boxType: BoxType.sent`), then the archived inbox copy
///      (`boxType: BoxType.inbox`, with the archive folder's ID as `boxId`):
///      each one only while its box lists it with the test subject.
///   8. Check the listings: poll the trash until it lists the message, then
///      confirm the archive, the inbox and the sent box no longer do.
///
/// Step 7 does not use `moveToTrash`: that sends Smartschool's
/// `quick delete`, which names the message ID only, so Smartschool acts on
/// whichever copy of the ID its own session state points to. For a copy in
/// the trash, that deletes the message for good (#19, #61). `moveToTrashFrom`
/// names the box of the copy it moves, and that box is never the trash
/// (#60). Smartschool's answer to it does not say what it moved, so step 8
/// reads the listings instead.
///
/// The move out of the archive folder (a `boxId` other than `0`) had not
/// been tried live yet when this example was written (#63, #64). If step 8
/// still finds the message in the archive, move it to the trash in
/// Smartschool's web client.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).  Override with environment variables if preferred:
///   SMARTSCHOOL_USERNAME=...
///   SMARTSCHOOL_PASSWORD=...
///   SMARTSCHOOL_MAIN_URL=...
Future<void> main() async {
  print(
    'WARNING: this sends a real message to your own Smartschool account, '
    'archives it and moves both of its copies to the trash.\n',
  );

  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final creds = PathCredentials();

  print('Connecting to Smartschool as ${creds.username} …');
  final client = await SmartschoolClient.create(creds);
  await client.ensureAuthenticated();
  print('✓ Authenticated.\n');

  final messages = MessagesService(client);

  // ── 2. Resolve own user via compose-form search ──────────────────────────

  print('Reading self recipient IDs from compose page …');
  final myself = await messages.getCurrentUserAsRecipient();
  print(
    '  → Verified self: ${myself.displayName} (userId=${myself.userId}, '
    'ssId=${myself.ssId})\n',
  );

  // ── 3. Send a test message to yourself ───────────────────────────────────

  final testSubject = 'Lifecycle test — ${DateTime.now().toIso8601String()}';
  final testBody =
      '<p>This is an automated lifecycle test message '
      'sent at ${DateTime.now().toLocal()}.</p>';

  print('Sending test message to yourself only …');
  print('  Subject : $testSubject');
  await messages.sendMessage(
    SendMessageParams(to: [myself], subject: testSubject, bodyHtml: testBody),
  );
  print('✓ Message sent.\n');

  // ── 4. Poll inbox until the test message appears ──────────────────────────

  print('Polling inbox for the test message (up to 15 s) …');
  final receivedMessage = await _pollUntil(
    description: 'inbox',
    fetch: () => messages.getHeaders(),
    match: (m) => m.subject == testSubject,
    timeoutSeconds: 15,
    pollIntervalSeconds: 2,
  );

  if (receivedMessage == null) {
    print(
      'ERROR: Test message was not found in the inbox after 15 s. '
      'Nothing was moved; look for "$testSubject" in your inbox and sent box.',
    );
    exit(1);
  }

  print(
    '✓ Message found in inbox: #${receivedMessage.id} '
    '"${receivedMessage.subject}"\n',
  );

  print('Polling sent box for its copy (up to 15 s) …');
  final sentCopy = await _pollUntil(
    description: 'sent box',
    fetch: () => messages.getHeaders(boxType: BoxType.sent),
    match: (m) => m.subject == testSubject,
    timeoutSeconds: 15,
    pollIntervalSeconds: 2,
  );

  if (sentCopy == null) {
    print(
      'WARNING: The sent box does not list the test message; step 7 leaves '
      'the sent box alone.\n',
    );
  } else {
    print('✓ Sent-box copy found: #${sentCopy.id}\n');
  }

  // ── 5. Archive the message and confirm it is in the archive ──────────────

  print('Archiving message #${receivedMessage.id} …');
  final archiveResults = await messages.moveToArchive([receivedMessage.id]);
  final archived = archiveResults.firstWhere(
    (r) => r.id == receivedMessage.id,
    orElse: () => MessageChanged(id: receivedMessage.id, newValue: 0),
  );

  if (archived.newValue != 1) {
    print(
      'WARNING: Archive API did not confirm success for '
      'message #${receivedMessage.id}.',
    );
  } else {
    print('✓ Archive API returned success.\n');
  }

  // The archive is a folder of the inbox. Its box ID is read from the
  // Messages module; getArchiveBoxId() falls back to 208 when it cannot be.
  final archiveBoxId = await messages.getArchiveBoxId();

  print(
    'Polling archive (boxId=$archiveBoxId) to confirm the message appears …',
  );
  final archivedMessage = await _pollUntil(
    description: 'archive',
    fetch: () => messages.getArchiveHeaders(boxId: archiveBoxId),
    match: (m) => m.id == receivedMessage.id && m.subject == testSubject,
    timeoutSeconds: 10,
    pollIntervalSeconds: 2,
  );

  if (archivedMessage == null) {
    print(
      'WARNING: Message was not found in the archive after 10 s. '
      'Your school may use a different archive box ID than $archiveBoxId. '
      'Step 7 leaves the inbox copy where it is.',
    );
  } else {
    print('✓ Message confirmed in archive.\n');
  }

  // ── 6. Verify disappearance from inbox ───────────────────────────────────

  print('Verifying the message has left the inbox …');
  final inboxHeaders = await messages.getHeaders();
  final stillInInbox = inboxHeaders.any((m) => m.id == receivedMessage.id);

  if (stillInInbox) {
    print(
      'WARNING: Message #${receivedMessage.id} is still visible in the '
      'inbox after archiving.',
    );
  } else {
    print('✓ Message no longer in inbox.\n');
  }

  // ── 7. Move both copies to the trash, the sent-box copy first ────────────
  //
  // moveToTrashFrom names the box of the copy it moves. Each copy is moved
  // once, and only while its box still lists it with the test subject, so no
  // other message (and never ID 0, #61) is moved.

  if (sentCopy != null) {
    if (await _lists(
      () => messages.getHeaders(boxType: BoxType.sent),
      sentCopy.id,
      testSubject,
    )) {
      print('Moving the sent-box copy #${sentCopy.id} to trash …');
      await messages.moveToTrashFrom(sentCopy.id, boxType: BoxType.sent);
      print('✓ Move sent; step 8 checks where the message is.\n');
    } else {
      print(
        'WARNING: The sent box no longer lists #${sentCopy.id} with the test '
        'subject; left where it is.\n',
      );
    }
  }

  if (archivedMessage != null) {
    if (await _lists(
      () => messages.getArchiveHeaders(boxId: archiveBoxId),
      archivedMessage.id,
      testSubject,
    )) {
      print(
        'Moving the archived inbox copy #${archivedMessage.id} '
        '(boxId=$archiveBoxId) to trash …',
      );
      await messages.moveToTrashFrom(
        archivedMessage.id,
        boxType: BoxType.inbox,
        boxId: archiveBoxId,
      );
      print('✓ Move sent; step 8 checks where the message is.\n');
    } else {
      print(
        'WARNING: The archive no longer lists #${archivedMessage.id} with the '
        'test subject; left where it is.\n',
      );
    }
  }

  // ── 8. Check the listings ────────────────────────────────────────────────
  //
  // moveToTrashFrom returns nothing: Smartschool answers every move the same,
  // whether it moved a message or not. The listings show where it is. The
  // trash lists a message ID once, also when both copies are in it.

  print('Polling trash to confirm the message arrived …');
  final trashedMessage = await _pollUntil(
    description: 'trash',
    fetch: () => messages.getHeaders(boxType: BoxType.trash),
    match: (m) => m.subject == testSubject,
    timeoutSeconds: 10,
    pollIntervalSeconds: 2,
  );

  if (trashedMessage == null) {
    print('WARNING: Message was not found in trash after 10 s.');
  } else {
    print('✓ Message confirmed in trash: #${trashedMessage.id}\n');
  }

  final boxes = <(String, Future<List<ShortMessage>> Function())>[
    ('archive', () => messages.getArchiveHeaders(boxId: archiveBoxId)),
    ('inbox', () => messages.getHeaders()),
    ('sent box', () => messages.getHeaders(boxType: BoxType.sent)),
  ];
  for (final (name, fetch) in boxes) {
    print('Verifying the message has left the $name …');
    final headers = await fetch();
    if (headers.any((m) => m.subject == testSubject)) {
      print(
        'WARNING: The $name still lists the test message. Move it to the '
        "trash in Smartschool's web client.",
      );
    } else {
      print('✓ Message no longer in the $name.\n');
    }
  }

  print('══════════════════════════════════════════════════════════');
  print(
    'Lifecycle test complete. Nothing was deleted for good: empty the '
    'trash yourself if you want the test message gone.',
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Whether the headers that [fetch] returns list message [id] with
/// [subject]: checked right before a copy is moved, so that only a copy of
/// the test message is. Never true for an [id] of `0` or below.
Future<bool> _lists(
  Future<List<ShortMessage>> Function() fetch,
  int id,
  String subject,
) async {
  if (id <= 0) return false;
  final headers = await fetch();
  return headers.any((m) => m.id == id && m.subject == subject);
}

/// Polls [fetch] every [pollIntervalSeconds] until [match] returns `true`
/// for one of the returned items, or until [timeoutSeconds] have elapsed.
///
/// Returns the first matching item, or `null` on timeout.
Future<ShortMessage?> _pollUntil({
  required String description,
  required Future<List<ShortMessage>> Function() fetch,
  required bool Function(ShortMessage) match,
  required int timeoutSeconds,
  int pollIntervalSeconds = 2,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

  while (DateTime.now().isBefore(deadline)) {
    final items = await fetch();
    final found = items.where(match).toList();
    if (found.isNotEmpty) return found.first;

    print(
      '  … not found in $description yet '
      '(${items.length} items), retrying in ${pollIntervalSeconds}s …',
    );
    await Future<void>.delayed(Duration(seconds: pollIntervalSeconds));
  }

  return null;
}
