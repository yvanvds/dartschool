import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';

/// Example: send a message to yourself then exercise the full
/// archive / trash lifecycle, verifying each step with a fresh API poll.
///
/// Run with:
///   dart run example/send_message_lifecycle_example.dart
///
/// The flow:
///   1. Authenticate.
///   2. Search for the logged-in user in the compose-form recipient search.
///   3. Send a timestamped test message to yourself.
///   4. Poll inbox (up to 15 s, every 2 s) until the test message appears.
///   5. Archive the message and poll the archive to confirm it is there.
///   6. Verify the message has disappeared from the inbox.
///   7. Move the archived message to trash.
///   8. Poll the trash to confirm it arrived; confirm it is gone from the archive.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).  Override with environment variables if preferred:
///   SMARTSCHOOL_USERNAME=...
///   SMARTSCHOOL_PASSWORD=...
///   SMARTSCHOOL_MAIN_URL=...
Future<void> main() async {
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

  print('Sending test message …');
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
    print('ERROR: Test message was not found in the inbox after 15 s.');
    exit(1);
  }

  print(
    '✓ Message found in inbox: #${receivedMessage.id} '
    '"${receivedMessage.subject}"\n',
  );

  // ── 5. Archive the message ────────────────────────────────────────────────

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

  // ── 6. Verify the message is in the archive ───────────────────────────────

  print('Polling archive (boxId=208) to confirm the message appears …');
  // Default archive box ID is 208; override with your school's value if needed.
  const archiveBoxId = 208;

  final archivedMessage = await _pollUntil(
    description: 'archive',
    fetch: () => messages.getArchiveHeaders(boxId: archiveBoxId),
    match: (m) => m.id == receivedMessage.id,
    timeoutSeconds: 10,
    pollIntervalSeconds: 2,
  );

  if (archivedMessage == null) {
    print(
      'WARNING: Message was not found in the archive after 10 s. '
      'Your school may use a different archive box ID than $archiveBoxId.',
    );
  } else {
    print('✓ Message confirmed in archive.\n');
  }

  // ── Verify disappearance from inbox ──────────────────────────────────────

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

  // ── 7. Move to trash ─────────────────────────────────────────────────────

  print('Moving message #${receivedMessage.id} to trash …');
  final trashStatus = await messages.moveToTrash(receivedMessage.id);

  if (trashStatus == null) {
    print('WARNING: moveToTrash returned no status.');
  } else if (!trashStatus.isDeleted) {
    print('WARNING: moveToTrash status indicates not deleted: $trashStatus');
  } else {
    print('✓ Trash API confirmed deletion.\n');
  }

  // ── 8. Poll trash to confirm ──────────────────────────────────────────────

  print('Polling trash to confirm the message arrived …');
  final trashedMessage = await _pollUntil(
    description: 'trash',
    fetch: () => messages.getHeaders(boxType: BoxType.trash),
    match: (m) => m.id == receivedMessage.id,
    timeoutSeconds: 10,
    pollIntervalSeconds: 2,
  );

  if (trashedMessage == null) {
    print(
      'WARNING: Message was not found in trash after 10 s.  '
      'Smartschool may have permanently deleted it immediately.',
    );
  } else {
    print('✓ Message confirmed in trash.\n');
  }

  // ── Verify disappearance from archive ────────────────────────────────────

  print('Verifying the message has left the archive …');
  final archiveHeaders = await messages.getArchiveHeaders(boxId: archiveBoxId);
  final stillInArchive = archiveHeaders.any((m) => m.id == receivedMessage.id);

  if (stillInArchive) {
    print(
      'WARNING: Message #${receivedMessage.id} is still visible in the '
      'archive after moving to trash.',
    );
  } else {
    print('✓ Message no longer in archive.\n');
  }

  print('══════════════════════════════════════════════════════════');
  print('Lifecycle test complete.');
}

// ── Polling helper ────────────────────────────────────────────────────────────

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
