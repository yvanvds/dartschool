import 'dart:async';

import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Example: trigger debounced incremental inbox refreshes from counter events.
///
/// Run with:
///   dart run example/message_change_stream_example.dart
Future<void> main() async {
  // final creds = EnvCredentials();
  final creds = PathCredentials();

  print('Connecting as ${creds.username} ...');
  final client = await SmartschoolClient.create(creds);
  final messages = MessagesService(client);

  StreamSubscription<NotificationCounterUpdate>? forwardSub;
  StreamSubscription<MessageCounterUpdate>? refreshSub;

  try {
    await client.ensureAuthenticated();
    print('Authenticated.');

    final initialHeaders = await messages.getHeaders();
    messages.seedIncrementalSeenIds(initialHeaders.map((m) => m.id));
    print('Seeded ${initialHeaders.length} seen message IDs.');

    // Bridge generic client counter updates into message-specific updates.
    forwardSub = messages.bindNotificationCounterStream(
      client.notificationCounterUpdates,
    );

    // React to message counter updates with coalesced incremental refreshes.
    refreshSub = messages.messageCounterUpdates.listen((update) async {
      print(
        'Message counter changed '
        '${update.previousCounter ?? '-'} -> ${update.counter} '
        '(source=${update.source}, isNew=${update.isNew})',
      );

      final newHeaders = await messages.refreshHeadersOnMessageCounter(update);
      if (newHeaders.isEmpty) {
        print('No new headers from incremental refresh.');
        return;
      }

      print('Fetched ${newHeaders.length} new headers:');
      for (final header in newHeaders) {
        print('  #${header.id} ${header.sender}: ${header.subject}');
      }
    });

    // In production, a websocket listener would call emitNotificationCounterUpdate.
    // This demo publishes synthetic updates to show the flow and dedupe behavior.
    client.emitNotificationCounterUpdate(
      moduleName: 'Messages',
      counter: 3,
      source: 'demo',
      isNew: true,
    );
    client.emitNotificationCounterUpdate(
      moduleName: 'Messages',
      counter: 3,
      source: 'demo',
      isNew: true,
    );
    client.emitNotificationCounterUpdate(
      moduleName: 'Messages',
      counter: 4,
      source: 'demo',
      isNew: true,
    );

    // Give the debounced refresh enough time to run in this demo.
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    await refreshSub?.cancel();
    await forwardSub?.cancel();
    await messages.dispose();
    await client.dispose();
  }
}
