import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: connect to Smartschool and print the 10 most recent inbox headers.
///
/// Run with:
///   dart run example/flutter_smartschool_example.dart
///
/// Credentials can be supplied via environment variables:
///   SMARTSCHOOL_USERNAME=john.doe
///   SMARTSCHOOL_PASSWORD=s3cr3t
///   SMARTSCHOOL_MAIN_URL=school.smartschool.be
///   SMARTSCHOOL_MFA=2010-05-15   # birthday, or TOTP secret for 2FA accounts
Future<void> main() async {
  // ----- Credential options -----
  // 1. From environment variables (useful for CI / scripts):
  //final creds = EnvCredentials();

  // 2. Hardcoded (useful during development — never commit real passwords):
  // final creds = AppCredentials(
  //   username: 'john.doe',
  //   password: 's3cr3t',
  //   mainUrl: 'school.smartschool.be',
  // );

  // 3. From a credentials.yml file on disk:
  final creds = PathCredentials();
  // --------------------------------

  print('Connecting to Smartschool as ${creds.username} …');

  final client = await SmartschoolClient.create(creds);

  // Fail fast if the session is not authenticated.
  await client.ensureAuthenticated();
  print('Authenticated successfully.');

  // ----- Messages -----
  final messages = MessagesService(client);

  print('\n--- Inbox (most recent 10) ---');
  final headers = await messages.getHeaders();
  final top10 = headers.take(10).toList();

  for (final msg in top10) {
    final unread = msg.unread ? '[UNREAD] ' : '';
    final attach = msg.attachment > 0 ? ' 📎' : '';
    print(
      '  #${msg.id}  $unread${msg.date.toLocal()}  '
      '${msg.sender}: ${msg.subject}$attach',
    );
  }

  if (top10.isEmpty) {
    print('  (inbox is empty)');
    return;
  }

  // Fetch the full body of the first message
  final first = top10.first;
  print('\n--- Full message #${first.id}: "${first.subject}" ---');
  final full = await messages.getMessage(first.id);
  if (full != null) {
    print('  From   : ${full.sender}');
    print('  To     : ${full.receivers.join(', ')}');
    print(
      '  Body   : ${full.body.substring(0, full.body.length.clamp(0, 200))}…',
    );
  }

  // List attachments (if any)
  if (first.attachment > 0) {
    final attachments = await messages.getAttachments(first.id);
    print('\n--- Attachments ---');
    for (final a in attachments) {
      print('  ${a.name}  (${a.mime}, ${a.size})');
    }
  }
}
