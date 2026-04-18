import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: fetch the 20 most recent sent messages and resolve the original
/// recipient IDs for the first one found via
/// [MessagesService.getSentMessageRecipients].
///
/// Run with:
///   dart run example/get_recipients_from_sent_messages.dart
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

  // ── Fetch sent headers ────────────────────────────────────────────────────

  print('Fetching 20 most recent sent messages …');
  final headers =
      (await messages.getHeaders(boxType: BoxType.sent)).take(20).toList();
  print('  → ${headers.length} messages retrieved.\n');

  if (headers.isEmpty) {
    print('No sent messages found.');
    return;
  }

  // ── Resolve recipients for each sent message ──────────────────────────────

  for (final header in headers) {
    print('══════════════════════════════════════════════════════════');
    print('Message ID : ${header.id}');
    print('Subject    : ${header.subject}');
    print('Date       : ${header.date}');
    print('');

    print('Resolving recipient IDs via sent reply-all compose page …');
    final (toList, ccList) = await messages.getSentMessageRecipients(header.id);

    if (toList.isEmpty && ccList.isEmpty) {
      print('  (no recipients extracted — compose page may be restricted)');
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

  print('══════════════════════════════════════════════════════════');
  print('Done.');
}
