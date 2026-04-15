class MessageSendOptions {
  final bool requestReadReceipt;
  final bool highPriority;
  final Map<String, dynamic>? extra;

  const MessageSendOptions({
    this.requestReadReceipt = false,
    this.highPriority = false,
    this.extra,
  });
}
