import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: fetch real inbox headers and group them by conversation thread.
///
/// Run with:
///   dart run example/message_threading_headers_example.dart
///
/// Credentials can come from environment variables or credentials.yml.
Future<void> main() async {
  // Pick one credential source.
  // final creds = EnvCredentials();
  final creds = PathCredentials();

  print('Connecting as ${creds.username} ...');
  final client = await SmartschoolClient.create(creds);
  await client.ensureAuthenticated();
  print('Authenticated.');

  final messages = MessagesService(client);

  print('Loading inbox headers...');
  final headers = await messages.getHeaders();

  if (headers.isEmpty) {
    print('No inbox headers found.');
    return;
  }

  // Build thread groups by normalized subject key.
  final groups = <String, List<ShortMessage>>{};
  for (final msg in headers) {
    final key = MessagesService.threadSubjectKey(msg.subject);
    final safeKey = key.isEmpty ? '(empty subject)' : key;
    groups.putIfAbsent(safeKey, () => <ShortMessage>[]).add(msg);
  }

  final ordered = groups.entries.toList()
    ..sort((a, b) {
      final aNewest = a.value
          .map((m) => m.date)
          .reduce((left, right) => left.isAfter(right) ? left : right);
      final bNewest = b.value
          .map((m) => m.date)
          .reduce((left, right) => left.isAfter(right) ? left : right);
      return bNewest.compareTo(aNewest);
    });

  const maxThreadsToPrint = 10;
  final top = ordered.take(maxThreadsToPrint).toList();

  print('');
  print('Top ${top.length} threads from ${headers.length} inbox headers:');
  print('============================================================');

  for (final entry in top) {
    final subjectKey = entry.key;
    final threadMessages = entry.value;

    threadMessages.sort((a, b) => b.date.compareTo(a.date));
    final latest = threadMessages.first;
    final unreadCount = threadMessages.where((m) => m.unread).length;

    print('Thread: $subjectKey');
    print(
      '  messages=${threadMessages.length} unread=$unreadCount '
      'latest=${latest.date.toLocal()}',
    );
    print(
      '  suggested reply subject: '
      '${MessagesService.ensureReplySubject(latest.subject)}',
    );

    for (final msg in threadMessages.take(3)) {
      final unread = msg.unread ? '[UNREAD] ' : '';
      print(
        '    #${msg.id} $unread${msg.date.toLocal()} '
        '${msg.sender}: ${msg.subject}',
      );
    }

    if (threadMessages.length > 3) {
      print('    ... ${threadMessages.length - 3} older messages');
    }

    print('');
  }
}
