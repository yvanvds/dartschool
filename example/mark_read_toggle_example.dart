import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: toggle the read/unread status of the first inbox message.
///
/// Run with:
///   dart run example/mark_read_toggle_example.dart
///
/// MANUAL VERIFICATION
/// ───────────────────
/// Before running, open the Smartschool Messages inbox in your browser:
///   `https://<your-school>.smartschool.be/?module=Messages&file=index&function=main`
///
/// Keep the page open.  After the example finishes:
///   1. Refresh the inbox.
///   2. Check whether the first message's read/unread indicator has changed.
///   3. Run the example a second time to restore the original state.
///
/// The example calls [MessagesService.markRead] or [MessagesService.markUnread]
/// depending on the current status, so each run flips the status once.
///
/// HOW IT WORKS
/// ────────────
/// The Smartschool website batches three XML dispatcher calls when you click a
/// message to open it:
///   1. postboxes / show message      — load message body
///   2. postboxes / attachment list   — load attachment list
///   3. postboxes / mark message read — flip status to read  (only if currently unread)
///
/// [MessagesService.getMessage] replicates only the first call intentionally,
/// so callers decide when to mark a message as read.  [MessagesService.markRead]
/// wraps the third call in isolation.
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main() async {
  // ── 1. Authenticate ─────────────────────────────────────────────────────

  final creds = PathCredentials();

  print('Connecting to Smartschool as ${creds.username} …');
  final client = await SmartschoolClient.create(creds);
  await client.ensureAuthenticated();
  print('✓ Authenticated.\n');

  final messages = MessagesService(client);

  // ── 2. Fetch inbox headers ───────────────────────────────────────────────

  print('Fetching inbox …');
  final headers = await messages.getHeaders();

  if (headers.isEmpty) {
    print('Inbox is empty — nothing to toggle.');
    return;
  }

  final first = headers.first;
  print(
    '  First message: #${first.id} from "${first.sender}" — '
    '"${first.subject}"',
  );
  print(
    '  Current status: ${first.unread ? "UNREAD" : "READ"} '
    '(unread=${first.unread})\n',
  );

  // ── 3. Toggle read/unread status ─────────────────────────────────────────
  //
  // [MessageChanged.newValue] from the mutation call:
  //   newValue=0 → message is now unread
  //   newValue=1 → message is now read

  if (first.unread) {
    print('Message is unread → calling markRead(${first.id}) …');
    final result = await messages.markRead(first.id);
    if (result == null) {
      print('  WARNING: server returned no data.');
    } else {
      print('  Server newValue: ${result.newValue}  (1 = read)');
      print(
        result.newValue == 1
            ? '✓ Message successfully marked as READ.'
            : 'WARNING: unexpected newValue=${result.newValue}.',
      );
    }
  } else {
    print('Message is read → calling markUnread(${first.id}) …');
    final result = await messages.markUnread(first.id);
    if (result == null) {
      print('  WARNING: server returned no data.');
    } else {
      print('  Server newValue: ${result.newValue}  (0 = unread)');
      print(
        result.newValue == 0
            ? '✓ Message successfully marked as UNREAD.'
            : 'WARNING: unexpected newValue=${result.newValue}.',
      );
    }
  }

  // ── 4. Re-fetch to confirm the change ────────────────────────────────────

  print('\nRe-fetching inbox to confirm …');
  final updated = await messages.getHeaders();
  final updatedFirst = updated.firstWhere(
    (m) => m.id == first.id,
    orElse: () => first,
  );

  print(
    '  Message #${updatedFirst.id} is now: '
    '${updatedFirst.unread ? "UNREAD" : "READ"}',
  );

  final toggled = updatedFirst.unread != first.unread;
  if (toggled) {
    print('✓ Status change confirmed by re-fetch.');
  } else {
    print(
      'WARNING: Status did not change in the re-fetch response.  '
      'Refresh the browser to verify manually.',
    );
  }

  print('\n──────────────────────────────────────────────────────────');
  print('Open your Smartschool Messages inbox and refresh to verify.');
  print('Run again to toggle back to the original state.');
}
