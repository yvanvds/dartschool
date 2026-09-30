// Tests for issue #43: `SendMessageParams.options` (a `MessageSendOptions`
// with `requestReadReceipt`, `highPriority` and `extra`) was accepted by
// `MessagesService.sendMessage` and `sendReply`, but never sent: `_send`
// built the submit from the other parameters only, so a message asked to go
// out with a read receipt or a high priority went out without them, silently.
//
// Smartschool's compose form has no field for any of them: neither the
// recorded new-message and reply forms, nor the live new-message form
// (checked with a GET only, nothing submitted), nor the compose scripts that
// submit it have a read receipt or a priority, and every field of the form is
// in the submit already. Its only options of its own are `copyToLVS` and a
// delayed send (`sendDate`), submitted with the form's defaults (#47). So the
// three options are deprecated, and a send that sets one now throws an
// `ArgumentError` before any request, instead of sending the message without
// it. The default options leave the submit as the compose form makes it.
//
// The fake Smartschool below serves the recorded compose forms and answers,
// and records every request and the fields of each submit.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/message_send_options.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/add_recipient_answer.dart';
import 'support/no_network.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

/// The recorded new-message form.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// The reply form of received message 900030 from Piet Peeters (201).
final _replyForm = _fixture('get/composemessage/reply.html');

/// The recorded answer to a sent message: `200` and a page whose script
/// calls `checkOpenerActions(); window.close();`.
final _sendAnswer = _fixture('post/composemessage/on_send.html');

/// A Smartschool that serves the compose forms and answers the steps of a
/// send with the recorded answers.
class _Smartschool implements HttpClientAdapter {
  /// Every request the client made, as `METHOD <path and query>`.
  final List<String> log = <String>[];

  /// The fields of each submit Smartschool handled.
  final List<Map<String, String>> submits = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    log.add(
      '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    );
    final query = uri.queryParameters;
    final post = options.method == 'POST';
    if (query['file'] == 'composeMessage' && !post) {
      return _response(switch (query['composeType']) {
        '0' => _newMessageForm,
        '1' => _replyForm,
        _ => fail('unexpected form: $query'),
      });
    }
    if (query['file'] == 'composeMessage') {
      submits.add({
        for (final field in (options.data as FormData).fields)
          field.key: field.value,
      });
      return _response(_sendAnswer);
    }
    if (post && query['function'] == 'addUserToSelected') {
      return _response(
        registeredRecipientAnswer(options.data as Map),
        contentType: registeredRecipientContentType,
      );
    }
    return _response('not found', status: 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// The value the compose form [html] gives its option fields by default: the
/// selected option of `copyToLVS`, and the value of `sendDate`.
Map<String, String> _formOptionDefaults(String html) {
  final doc = html_parser.parse(html);
  final lvs = doc.querySelector('select[name="copyToLVS"]')!;
  final selected =
      lvs.querySelector('option[selected]') ?? lvs.querySelector('option')!;
  return {
    'copyToLVS': selected.attributes['value']!,
    'sendDate': doc
        .querySelector('input[name="sendDate"]')!
        .attributes['value']!,
  };
}

/// The names of the fields of every submit: those of Smartschool's compose
/// form (its hidden tokens, the search fields, the subject, `copyToLVS`,
/// the message and `bcc`), and the query of the URL it is submitted to.
const _submitFieldNames = {
  'module',
  'file',
  'boxType',
  'composeType',
  'msgID',
  'encryptedSender',
  'send',
  'origMsgID',
  'composeAction',
  'randomDir',
  'uniqueUsc',
  'showTab',
  'delFile',
  'msgFormSelectedTab',
  'sendDate',
  'searchField3',
  'searchField1',
  'searchField4',
  'searchField5',
  'subject',
  'copyToLVS',
  'message',
  'bcc',
};

const _alice = MessageSearchUser(
  userId: 11111,
  displayName: 'Alice Example',
  ssId: 100,
);

/// The sender of message 900030, as the reply form names them.
const _sender = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);

SendMessageParams _params(
  MessageSendOptions options, {
  MessageSearchUser to = _alice,
}) => SendMessageParams(
  to: [to],
  subject: 'Schoolreis',
  bodyHtml: '<p>Tot vrijdag.</p>',
  options: options,
);

/// The ways to set an option that the compose form has no field for, with
/// the names the error message gives them.
final _unsupported = <(String, MessageSendOptions, List<String>)>[
  (
    'requestReadReceipt',
    const MessageSendOptions(requestReadReceipt: true),
    ['requestReadReceipt'],
  ),
  (
    'highPriority',
    const MessageSendOptions(highPriority: true),
    ['highPriority'],
  ),
  (
    'extra with a field of the form',
    const MessageSendOptions(extra: {'copyToLVS': 'copyToLVS'}),
    ['extra (copyToLVS;'],
  ),
  (
    'extra with a field the form does not have',
    const MessageSendOptions(extra: {'priority': 'high'}),
    ['extra (priority;'],
  ),
  (
    'all of them',
    const MessageSendOptions(
      requestReadReceipt: true,
      highPriority: true,
      extra: {'receipt': '1', 'priority': 'high'},
    ),
    ['requestReadReceipt', 'highPriority', 'extra (receipt, priority;'],
  ),
];

/// The ways to leave the options unset.
final _unset = <(String, MessageSendOptions)>[
  ('the default options', const MessageSendOptions()),
  (
    'every option set to its default',
    const MessageSendOptions(
      requestReadReceipt: false,
      highPriority: false,
      extra: null,
    ),
  ),
  ('an empty extra', const MessageSendOptions(extra: {})),
];

/// The [ArgumentError] of [operation] for the options named [options].
Matcher _refused(String operation, List<String> options) => isA<ArgumentError>()
    .having((e) => e.name, 'name', 'params.options')
    .having(
      (e) => e.message,
      'message',
      allOf([
        contains('$operation:'),
        contains("compose form has no field for"),
        for (final option in options) contains(option),
        contains('Nothing was sent'),
      ]),
    );

void main() {
  forbidRealNetwork();

  late Directory tempDir;
  late SmartschoolClient client;
  late MessagesService messages;

  Future<_Smartschool> serve() async {
    final server = _Smartschool();
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: p.join(tempDir.path, 'cache'),
    );
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
    return server;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_43_');
  });

  tearDown(() async {
    await client.dispose();
    tempDir.deleteSync(recursive: true);
  });

  // Each send method, with the form it submits and the params it sends.
  final sends =
      <
        (
          String,
          String,
          Future<void> Function(MessagesService, MessageSendOptions),
        )
      >[
        (
          'sendMessage',
          _newMessageForm,
          (messages, options) => messages.sendMessage(_params(options)),
        ),
        (
          'sendReply',
          _replyForm,
          (messages, options) =>
              messages.sendReply(900030, _params(options, to: _sender)),
        ),
      ];

  for (final (operation, form, send) in sends) {
    group('$operation with the options left unset (#43)', () {
      for (final (description, options) in _unset) {
        test('submits the fields of the compose form, its options with the '
            "form's own defaults: $description", () async {
          final server = await serve();

          await send(messages, options);

          final submit = server.submits.single;
          expect(submit.keys.toSet(), _submitFieldNames);
          expect(
            submit,
            allOf([
              for (final MapEntry(:key, :value) in _formOptionDefaults(
                form,
              ).entries)
                containsPair(key, value),
            ]),
          );
          // The form's defaults: not stored in the LVS, sent now.
          expect(submit['copyToLVS'], 'dontCopyToLVS');
          expect(submit['sendDate'], '');
          expect(submit['send'], 'send');
        });
      }
    });

    group('$operation refuses an option that the compose form has no field '
        'for, before any request (#43)', () {
      for (final (description, options, names) in _unsupported) {
        test(description, () async {
          final server = await serve();

          // Before the change, the message was sent without the option: the
          // form was loaded and submitted, and the call returned normally.
          await expectLater(
            send(messages, options),
            throwsA(_refused(operation, names)),
          );
          expect(server.log, isEmpty);
          expect(server.submits, isEmpty);
        });
      }
    });
  }
}
