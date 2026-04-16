/// Unofficial Dart library for the Smartschool platform.
///
/// Usage:
/// ```dart
/// import 'package:flutter_smartschool/flutter_smartschool.dart';
///
/// final client = await SmartschoolClient.create(
///   AppCredentials(
///     username: 'john.doe',
///     password: 's3cr3t',
///     mainUrl: 'school.smartschool.be',
///   ),
/// );
///
/// final messages = MessagesService(client);
/// final headers = await messages.getHeaders();
/// for (final msg in headers) {
///   print('${msg.date}  ${msg.sender}: ${msg.subject}');
/// }
/// ```
library;

// Core session + credentials
export 'src/credentials.dart';
export 'src/session.dart';

// Exceptions
export 'src/exceptions.dart';

// Models
export 'src/models/message_models.dart';
export 'src/models/intradesk_models.dart';
export 'src/models/notification_models.dart';

// Services
export 'src/services/messages_service.dart';
export 'src/services/intradesk_service.dart';
export 'src/services/message_send_options.dart';
export 'src/services/send_message_params.dart';
