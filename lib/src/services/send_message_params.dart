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
