import '../models/message_models.dart';
import 'message_send_options.dart';

/// Encapsulates all parameters for sending a Smartschool message.
class SendMessageParams {
  final List<MessageSearchUser> to;
  final List<MessageSearchUser> cc;
  final List<MessageSearchUser> bcc;
  final List<MessageSearchGroup> toGroups;
  final List<MessageSearchGroup> ccGroups;
  final List<MessageSearchGroup> bccGroups;
  final String subject;
  final String bodyHtml;
  final List<String> attachmentPaths;

  /// Options of the send: the compose form's own options, storing the
  /// message in the LVS ([MessageSendOptions.lvsCopy]) and a delayed send
  /// ([MessageSendOptions.sendAt], #47). The default sends the message as
  /// Smartschool's compose form does by default: not stored in the LVS, sent
  /// now. The other fields of [MessageSendOptions] are deprecated, since the
  /// compose form has no field for any of them, and a send that sets one
  /// throws an [ArgumentError] before any request (#43).
  final MessageSendOptions options;

  const SendMessageParams({
    required this.to,
    this.cc = const [],
    this.bcc = const [],
    this.toGroups = const [],
    this.ccGroups = const [],
    this.bccGroups = const [],
    required this.subject,
    required this.bodyHtml,
    this.attachmentPaths = const [],
    this.options = const MessageSendOptions(),
  });
}
