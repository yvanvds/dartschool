/// Options of a message that `MessagesService.sendMessage` and
/// `MessagesService.sendReply` send, beyond its recipients, subject, body and
/// attachments (`SendMessageParams.options`).
///
/// None of its fields is supported, and all three are deprecated (#43):
/// Smartschool's compose form (the new-message form and the reply forms, and
/// the compose script that submits them) has no read receipt, no priority,
/// and no field that the library leaves for [extra] to fill. Its only other
/// options are `copyToLVS` (store the message in the LVS) and a delayed send
/// (`sendDate`), which the library submits with the form's own defaults and
/// does not expose yet (#47).
///
/// So none of them is sent. Rather than send the message without what the
/// caller asked for, `sendMessage` and `sendReply` throw an [ArgumentError]
/// when one is set ([requestReadReceipt] or [highPriority] `true`, or a
/// non-empty [extra]), before any request: nothing was sent. The default
/// `MessageSendOptions()` sends the message as the compose form does.
class MessageSendOptions {
  /// Asks for a read receipt. Not supported: Smartschool's compose form has
  /// no read receipt, so a send with `true` throws an [ArgumentError] and
  /// sends nothing (#43).
  @Deprecated(
    'Smartschool has no read receipt: a send that sets it throws an '
    'ArgumentError (#43)',
  )
  final bool requestReadReceipt;

  /// Marks the message as high priority. Not supported: Smartschool's
  /// compose form has no priority, so a send with `true` throws an
  /// [ArgumentError] and sends nothing (#43).
  @Deprecated(
    'Smartschool has no message priority: a send that sets it throws an '
    'ArgumentError (#43)',
  )
  final bool highPriority;

  /// Extra fields for the submit of the compose form. Not supported: the
  /// submit already holds every field of the form, filled from the other
  /// parameters of the send (tokens, recipients, subject, body) or with the
  /// form's own defaults, so an extra field could only override one of them.
  /// A send with a non-empty map throws an [ArgumentError] and sends nothing
  /// (#43).
  @Deprecated(
    'Smartschool\'s compose form has no field for it: a send that sets it '
    'throws an ArgumentError (#43)',
  )
  final Map<String, dynamic>? extra;

  const MessageSendOptions({
    @Deprecated(
      'Smartschool has no read receipt: a send that sets it throws an '
      'ArgumentError (#43)',
    )
    this.requestReadReceipt = false,
    @Deprecated(
      'Smartschool has no message priority: a send that sets it throws an '
      'ArgumentError (#43)',
    )
    this.highPriority = false,
    @Deprecated(
      'Smartschool\'s compose form has no field for it: a send that sets it '
      'throws an ArgumentError (#43)',
    )
    this.extra,
  });
}
