import 'dart:async';
import 'dart:collection';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:html/parser.dart' as html_parser;

/// Example: listen for message notifications and print full message content.
///
/// Run with:
///   dart run example/notification_listener_full_message_example.dart
///
/// This example uses an internal polling bridge to emit notification events:
/// - It polls inbox headers with `alreadySeenIds`.
/// - When new headers arrive, it emits a `Messages` counter update.
/// - The notification listener fetches the full message and prints content.
Future<void> main() async {
  // final creds = EnvCredentials();
  final creds = PathCredentials();

  print('Connecting as ${creds.username} ...');
  final client = await SmartschoolClient.create(creds);
  final messages = MessagesService(client);

  StreamSubscription<NotificationCounterUpdate>? notificationSub;

  try {
    await client.ensureAuthenticated();
    print('Authenticated.');

    final initialHeaders = await messages.getHeaders();
    final seenIds = <int>{...initialHeaders.map((m) => m.id)};
    var messageCounter = initialHeaders.where((m) => m.unread).length;

    print('');
    print('=== Notification Listener Ready ===');
    print('1. Open Smartschool in your browser.');
    print('2. Send a message to yourself.');
    print('3. Wait a few seconds.');
    print('This terminal will print the full message content on notification.');
    print('Press Ctrl+C to stop.');
    print('');

    final pendingMessageIds = Queue<int>();
    var isProcessingQueue = false;

    Future<void> processPendingMessages() async {
      if (isProcessingQueue) return;
      isProcessingQueue = true;
      try {
        while (pendingMessageIds.isNotEmpty) {
          final msgId = pendingMessageIds.removeFirst();
          final full = await messages.getMessage(msgId);

          if (full == null) {
            print('[notification] message #$msgId was no longer available.');
            continue;
          }

          final plainText = _toPlainText(full.body);

          print('');
          print('=== New Message Notification ===');
          print('id      : ${full.id}');
          print('from    : ${full.sender}');
          print('subject : ${full.subject}');
          print('date    : ${full.date.toLocal()}');
          print('content :');
          print(plainText.isEmpty ? '(empty body)' : plainText);
          print('================================');
          print('');
        }
      } finally {
        isProcessingQueue = false;
      }
    }

    notificationSub = client.notificationCounterUpdates.listen((update) async {
      if (update.moduleName.toLowerCase() != 'messages') return;
      await processPendingMessages();
    });

    // Polling bridge: detect new inbox message IDs and emit a notification.
    while (true) {
      final newHeaders = await messages.getHeaders(
        alreadySeenIds: seenIds.toList(growable: false),
      );

      if (newHeaders.isNotEmpty) {
        // Oldest first gives a readable terminal sequence when multiple arrive.
        newHeaders.sort((a, b) => a.date.compareTo(b.date));

        for (final header in newHeaders) {
          seenIds.add(header.id);
          pendingMessageIds.add(header.id);
        }

        messageCounter += newHeaders.length;

        client.emitNotificationCounterUpdate(
          moduleName: 'Messages',
          counter: messageCounter,
          isNew: true,
          source: 'poll-bridge',
        );
      }

      await Future<void>.delayed(const Duration(seconds: 3));
    }
  } finally {
    await notificationSub?.cancel();
    await messages.dispose();
    await client.dispose();
  }
}

String _toPlainText(String html) {
  final document = html_parser.parse(html);
  return (document.body?.text ?? '').trim();
}
