/// A normalized notification counter update.
///
/// Smartschool top navigation pushes module counter changes (for example
/// `Messages`, `Ticket`). This model is transport-agnostic and can be used by
/// polling, websocket, or any other listener implementation.
class NotificationCounterUpdate {
  final String moduleName;
  final int counter;
  final bool isNew;
  final String source;
  final DateTime timestamp;

  const NotificationCounterUpdate({
    required this.moduleName,
    required this.counter,
    this.isNew = false,
    this.source = 'unknown',
    required this.timestamp,
  });
}

/// A message-specific counter update emitted by [MessagesService].
class MessageCounterUpdate {
  final int counter;
  final int? previousCounter;
  final bool isNew;
  final String source;
  final DateTime timestamp;

  const MessageCounterUpdate({
    required this.counter,
    required this.previousCounter,
    this.isNew = false,
    this.source = 'unknown',
    required this.timestamp,
  });
}
