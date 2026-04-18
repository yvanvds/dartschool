import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: scan the 50 most recent inbox messages and find the first message
/// with multiple To recipients and the first with multiple CC recipients.
/// For each, resolve the full recipient list with platform user IDs via
/// [MessagesService.getReplyAllRecipients] and print the results.
///
/// Run with:
///   dart run example/reply_all_recipients_example.dart
///
/// Credentials are read from `credentials.yml` next to the workspace root
/// (see [PathCredentials]).
Future<void> main() async {
  // ── Authenticate ──────────────────────────────────────────────────────────

  final creds = PathCredentials();

  print('Connecting to Smartschool as ${creds.username} …');
  final client = await SmartschoolClient.create(creds);
  await client.ensureAuthenticated();
  print('✓ Authenticated.\n');

  final messages = MessagesService(client);

  // ── Fetch 50 most recent inbox headers ────────────────────────────────────

  print('Fetching 50 most recent inbox messages …');
  final headers = (await messages.getHeaders()).take(50).toList();
  print('  → ${headers.length} messages retrieved.\n');

  // ── Scan for candidates ───────────────────────────────────────────────────

  // For each header we fetch the full message (with limitList=true, which is
  // the fast default). A message has "multiple To" when the server reports
  // hidden recipients (totalNrOtherToReceivers > 0) or the visible list
  // already contains more than one entry.  Same logic applies to CC.

  FullMessage? multiToMsg;
  FullMessage? multiCcMsg;

  print(
    'Scanning for messages with multiple To or CC recipients '
    '(up to ${headers.length} calls) …',
  );

  for (final header in headers) {
    final bothFound = multiToMsg != null && multiCcMsg != null;
    if (bothFound) break;

    final full = await messages.getMessage(header.id);
    if (full == null) continue;

    final totalTo = full.receivers.length + full.totalNrOtherToReceivers;
    final totalCc = full.ccReceivers.length + full.totalNrOtherCcReceivers;

    if (multiToMsg == null && totalTo > 1) {
      multiToMsg = full;
      print('  ✓ Found multi-To message  : #${full.id} "${full.subject}"');
    }
    if (multiCcMsg == null && totalCc > 1) {
      multiCcMsg = full;
      print('  ✓ Found multi-CC message  : #${full.id} "${full.subject}"');
    }
  }

  print('');

  // ── Report results ────────────────────────────────────────────────────────

  if (multiToMsg == null && multiCcMsg == null) {
    print(
      'No messages with multiple To or CC recipients were found among '
      'the ${headers.length} most recent inbox messages.',
    );
    return;
  }

  Future<void> showMessage(FullMessage msg, String label) async {
    print('══════════════════════════════════════════════════════════');
    print(label);
    print('  Message ID : ${msg.id}');
    print('  Subject    : ${msg.subject}');
    print('  From       : ${msg.sender}');
    print('  Date       : ${msg.date}');
    print('');

    print('  Resolving recipient IDs via reply-all compose page …');
    final (toList, ccList) = await messages.getReplyAllRecipients(msg.id);

    if (toList.isEmpty && ccList.isEmpty) {
      print('  (no recipients extracted — compose page may be restricted)');
      return;
    }

    if (toList.isNotEmpty) {
      print('  To (${toList.length}):');
      for (final u in toList) {
        print(
          '    • ${u.displayName.padRight(35)} userId=${u.userId}  ssId=${u.ssId}',
        );
      }
    }

    if (ccList.isNotEmpty) {
      print('  CC (${ccList.length}):');
      for (final u in ccList) {
        print(
          '    • ${u.displayName.padRight(35)} userId=${u.userId}  ssId=${u.ssId}',
        );
      }
    }

    print('');
  }

  if (multiToMsg != null) {
    await showMessage(multiToMsg, 'Message with multiple To recipients');
  } else {
    print(
      'No message with multiple To recipients found among the '
      '${headers.length} most recent messages.',
    );
    print('');
  }

  if (multiCcMsg != null) {
    // Avoid fetching reply-all twice when the same message satisfies both.
    if (multiCcMsg.id == multiToMsg?.id) {
      print('══════════════════════════════════════════════════════════');
      print('Message with multiple CC recipients');
      print(
        '  (same message as above — #${multiCcMsg.id} "${multiCcMsg.subject}")',
      );
      print('');
    } else {
      await showMessage(multiCcMsg, 'Message with multiple CC recipients');
    }
  } else {
    print(
      'No message with multiple CC recipients found among the '
      '${headers.length} most recent messages.',
    );
    print('');
  }

  print('══════════════════════════════════════════════════════════');
  print('Done.');
}
