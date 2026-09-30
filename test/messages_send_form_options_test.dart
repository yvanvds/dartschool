// Tests for issue #47: `MessagesService.sendMessage` and `sendReply` let a
// send choose the compose form's own options, which they always submitted
// with the form's defaults:
//
// - `MessageSendOptions.lvsCopy` (`LvsCopy`), the form's `copyToLVS` select:
//   `dontCopyToLVS` (selected), `copyToLVS` or `copyToLVSAndMarkAsPrivate`
//   (the recorded new-message and reply forms; the live forms, checked with a
//   GET only, have the same options and labels).
// - `MessageSendOptions.sendAt`, the form's hidden `sendDate` field, which
//   the delayed-send dialog of Smartschool's web client
//   (`Messages/desktop/delayedMessages`) fills with the chosen time
//   (`setHiddenInputSendDate`: date-fns `formatISO`, the local time to the
//   second with its UTC offset) before the same submit as a send now
//   (`oCheckForm.checkAndSubmit()`, no other field). The dialog refuses a
//   time that is not after now, and its date picker offers days up to a year
//   ahead; the send button fills `sendDate` only when the form's `SMSC.vars`
//   has `isScheduledMessagesEnabled`.
//
// The defaults are unchanged: `dontCopyToLVS` and the form's empty
// `sendDate`. A time outside the dialog's limits is refused before any
// request, and an option that the loaded form does not offer is refused
// before any recipient is registered, so that the message never goes out
// without the option it was sent with.
//
// Nothing here was verified with a real send: the fake Smartschool below
// serves the recorded compose forms and answers, and records every request
// and the fields of each submit.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/message_send_options.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

import 'support/add_recipient_answer.dart';
import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

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

/// A Smartschool that serves the compose forms (as [edit] changes them) and
/// answers the steps of a send with the recorded answers, or the submit with
/// [submitAnswer].
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.edit, this.submitAnswer});

  final String Function(String form)? edit;
  final String? submitAnswer;

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
      final form = switch (query['composeType']) {
        '0' => _newMessageForm,
        '1' => _replyForm,
        _ => fail('unexpected form: $query'),
      };
      return _response(edit == null ? form : edit!(form));
    }
    if (query['file'] == 'composeMessage') {
      submits.add({
        for (final field in (options.data as FormData).fields)
          field.key: field.value,
      });
      return _response(submitAnswer ?? _sendAnswer);
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

/// [form] with [from] replaced by [to]; fails when [form] does not contain
/// [from], so that a changed fixture cannot quietly leave a test without the
/// form it is about.
String _replace(String form, Pattern from, String to) {
  expect(form, contains(from), reason: 'the compose form fixture changed');
  return form.replaceAll(from, to);
}

/// The compose form without its `copyToLVS` select, as Smartschool serves it
/// to an account that may not store messages in the LVS.
String _withoutLvsSelect(String form) => _replace(
  form,
  RegExp(r'<select[^>]*name="copyToLVS"[^>]*>[\s\S]*?</select>'),
  '',
);

/// The compose form whose `copyToLVS` select has no confidential option.
String _withoutConfidentialOption(String form) => _replace(
  form,
  RegExp(r'<option value="copyToLVSAndMarkAsPrivate">[^<]*</option>'),
  '',
);

/// The compose form of a platform whose scheduled messages are disabled.
String _scheduledMessagesDisabled(String form) => _replace(
  form,
  '"isScheduledMessagesEnabled":true',
  '"isScheduledMessagesEnabled":false',
);

/// The compose form without its `sendDate` field.
String _withoutSendDate(String form) => _replace(
  form,
  '<input type="hidden" id="sendDate" name="sendDate" value="">',
  '',
);

/// The values of the options of the compose form [html]'s `copyToLVS`
/// select, in order, and the selected one.
(List<String>, String) _lvsOptions(String html) {
  final select = html_parser
      .parse(html)
      .querySelector('select[name="copyToLVS"]')!;
  final options = select.querySelectorAll('option');
  return (
    [for (final option in options) option.attributes['value']!],
    options
        .firstWhere((option) => option.attributes.containsKey('selected'))
        .attributes['value']!,
  );
}

/// The names of the fields of every submit: those of Smartschool's compose
/// form, and the query of the URL it is submitted to. A delayed send and an
/// LVS copy add none: the web client submits the same form.
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

String _two(int n) => '$n'.padLeft(2, '0');

/// The UTC offset of [local] as ISO 8601 writes it: `Z`, or `+HH:MM` /
/// `-HH:MM`.
String _offset(DateTime local) {
  final offset = local.timeZoneOffset;
  if (offset == Duration.zero) return 'Z';
  final minutes = offset.inMinutes.abs();
  return '${offset.isNegative ? '-' : '+'}${_two(minutes ~/ 60)}:'
      '${_two(minutes % 60)}';
}

/// What `formatISO` of date-fns writes for a time that is the local wall
/// clock time [local]: `yyyy-MM-ddTHH:mm:ss` and the offset.
String _iso(DateTime local) =>
    '${'${local.year}'.padLeft(4, '0')}-${_two(local.month)}-'
    '${_two(local.day)}T${_two(local.hour)}:${_two(local.minute)}:'
    '${_two(local.second)}${_offset(local)}';

/// ISO 8601 as the delayed-send dialog writes it into `sendDate`.
final _isoFormat = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$',
);

/// Two days from today at 07:30, local time: the kind of time that the
/// dialog's "tomorrow morning" offers.
DateTime _morningInTwoDays() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + 2, 7, 30);
}

/// The [ArgumentError] of [operation] for a [MessageSendOptions.sendAt] that
/// the delayed-send dialog does not offer, with [message] in its message.
Matcher _refusedSendAt(String operation, String message) => isA<ArgumentError>()
    .having((e) => e.name, 'name', 'params.options.sendAt')
    .having(
      (e) => e.message,
      'message',
      allOf([
        contains('$operation:'),
        contains(message),
        contains('Nothing was sent'),
      ]),
    );

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;
  late MessagesService messages;

  Future<_Smartschool> serve({
    String Function(String form)? edit,
    String? submitAnswer,
  }) async {
    final server = _Smartschool(edit: edit, submitAnswer: submitAnswer);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
    return server;
  }

  test('LvsCopy has the options of the copyToLVS select of the compose '
      'forms, in their order, and none is the one they select', () {
    for (final form in [_newMessageForm, _replyForm]) {
      final (values, selected) = _lvsOptions(form);
      expect([for (final copy in LvsCopy.values) copy.value], values);
      expect(LvsCopy.none.value, selected);
    }
    expect(const MessageSendOptions().lvsCopy, LvsCopy.none);
    expect(const MessageSendOptions().sendAt, isNull);
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
          '0',
          (messages, options) => messages.sendMessage(_params(options)),
        ),
        (
          'sendReply',
          '1',
          (messages, options) =>
              messages.sendReply(900030, _params(options, to: _sender)),
        ),
      ];

  for (final (operation, composeType, send) in sends) {
    group('$operation (#47)', () {
      group('with the default options submits the form\'s defaults', () {
        for (final (description, options) in [
          ('MessageSendOptions()', const MessageSendOptions()),
          (
            'lvsCopy none and sendAt null',
            const MessageSendOptions(lvsCopy: LvsCopy.none, sendAt: null),
          ),
        ]) {
          test(description, () async {
            final server = await serve();

            await send(messages, options);

            final submit = server.submits.single;
            expect(submit.keys.toSet(), _submitFieldNames);
            // Not stored in the LVS, sent now: the form's own values.
            expect(submit['copyToLVS'], 'dontCopyToLVS');
            expect(submit['sendDate'], '');
          });
        }
      });

      group('stores the message in the LVS with the option of lvsCopy', () {
        for (final (copy, value) in [
          (LvsCopy.none, 'dontCopyToLVS'),
          (LvsCopy.store, 'copyToLVS'),
          (LvsCopy.storeConfidential, 'copyToLVSAndMarkAsPrivate'),
        ]) {
          test('${copy.name}: copyToLVS $value', () async {
            final server = await serve();

            await send(messages, MessageSendOptions(lvsCopy: copy));

            final submit = server.submits.single;
            expect(submit.keys.toSet(), _submitFieldNames);
            // Before #47, copyToLVS was always dontCopyToLVS.
            expect(submit['copyToLVS'], value);
            expect(submit['sendDate'], '');
          });
        }
      });

      group('schedules the message at sendAt', () {
        test('a local time: sendDate in ISO 8601, to the second, with the '
            'UTC offset', () async {
          final server = await serve();
          final sendAt = _morningInTwoDays();

          await send(messages, MessageSendOptions(sendAt: sendAt));

          final submit = server.submits.single;
          expect(submit.keys.toSet(), _submitFieldNames);
          // Before #47, sendDate was always the form's empty value.
          final sendDate = submit['sendDate']!;
          expect(sendDate, _iso(sendAt));
          expect(sendDate, matches(_isoFormat));
          expect(sendDate, contains('T07:30:00'));
          expect(DateTime.parse(sendDate).isAtSameMomentAs(sendAt), isTrue);
          expect(submit['copyToLVS'], 'dontCopyToLVS');
          expect(submit['send'], 'send');
        });

        test('a UTC time: sendDate in the local time of the machine, the same '
            'instant', () async {
          final server = await serve();
          final sendAt = _morningInTwoDays().toUtc();

          await send(messages, MessageSendOptions(sendAt: sendAt));

          final sendDate = server.submits.single['sendDate']!;
          expect(sendDate, _iso(sendAt.toLocal()));
          expect(DateTime.parse(sendDate).isAtSameMomentAs(sendAt), isTrue);
        });

        test('seconds are sent, milliseconds dropped', () async {
          final server = await serve();
          final morning = _morningInTwoDays();
          final sendAt = morning.add(
            const Duration(seconds: 42, milliseconds: 999, microseconds: 1),
          );

          await send(messages, MessageSendOptions(sendAt: sendAt));

          final sendDate = server.submits.single['sendDate']!;
          expect(sendDate, _iso(morning.add(const Duration(seconds: 42))));
          expect(sendDate, contains('T07:30:42'));
        });

        test('with an LVS copy', () async {
          final server = await serve();
          final sendAt = _morningInTwoDays();

          await send(
            messages,
            MessageSendOptions(
              lvsCopy: LvsCopy.storeConfidential,
              sendAt: sendAt,
            ),
          );

          final submit = server.submits.single;
          expect(submit.keys.toSet(), _submitFieldNames);
          expect(submit['copyToLVS'], 'copyToLVSAndMarkAsPrivate');
          expect(submit['sendDate'], _iso(sendAt));
        });

        test('up to the end of the same day next year', () async {
          final server = await serve();
          final now = DateTime.now();
          // The same day next year, or the last day of its month when it
          // has no such day (29 February).
          final lastDay = DateTime(now.year + 1, now.month + 1, 0).day;
          final sendAt = DateTime(
            now.year + 1,
            now.month,
            now.day <= lastDay ? now.day : lastDay,
            23,
          );

          await send(messages, MessageSendOptions(sendAt: sendAt));

          expect(server.submits.single['sendDate'], _iso(sendAt));
        });

        test('a scheduled send that Smartschool does not confirm is a '
            'SmartschoolSendUnconfirmedError that points to the scheduled '
            'box', () async {
          // Smartschool's answer to a scheduled message is not recorded. When
          // it is not the answer to a sent message, the send reports that it
          // may have been scheduled.
          final server = await serve(
            submitAnswer: composeType == '0' ? _newMessageForm : _replyForm,
          );

          await expectLater(
            send(messages, MessageSendOptions(sendAt: _morningInTwoDays())),
            throwsA(
              isA<SmartschoolSendUnconfirmedError>().having(
                (e) => e.message,
                'message',
                allOf([
                  contains('$operation:'),
                  contains('may or may not have been scheduled'),
                  contains('check the scheduled box'),
                ]),
              ),
            ),
          );
          expect(server.submits, hasLength(1));
        });

        test('a send now that Smartschool does not confirm still points to '
            'the sent box', () async {
          await serve(
            submitAnswer: composeType == '0' ? _newMessageForm : _replyForm,
          );

          await expectLater(
            send(messages, const MessageSendOptions()),
            throwsA(
              isA<SmartschoolSendUnconfirmedError>().having(
                (e) => e.message,
                'message',
                allOf([
                  contains('may or may not have been sent'),
                  contains('check the sent box'),
                  isNot(contains('scheduled')),
                ]),
              ),
            ),
          );
        });
      });

      group('refuses a sendAt that the delayed-send dialog does not offer, '
          'before any request', () {
        for (final (description, sendAt, message) in [
          (
            'in the past',
            () => DateTime.now().subtract(const Duration(minutes: 1)),
            'must be after now',
          ),
          ('now', DateTime.now, 'must be after now'),
          (
            'more than a year ahead',
            () {
              final now = DateTime.now();
              return DateTime(now.year + 1, now.month, now.day + 2, 0, 30);
            },
            'at most a year ahead',
          ),
        ]) {
          test(description, () async {
            final server = await serve();

            await expectLater(
              send(messages, MessageSendOptions(sendAt: sendAt())),
              throwsA(_refusedSendAt(operation, message)),
            );
            expect(server.log, isEmpty);
            expect(server.submits, isEmpty);
          });
        }
      });

      group('refuses an option that the compose form does not offer, before '
          'registering any recipient: a SmartschoolComposeError', () {
        for (final (description, edit, options, message) in [
          (
            'an LVS copy on a form without the copyToLVS select',
            _withoutLvsSelect,
            const MessageSendOptions(lvsCopy: LvsCopy.store),
            'does not offer to store the message in the LVS',
          ),
          (
            'a confidential LVS copy on a form without that option',
            _withoutConfidentialOption,
            const MessageSendOptions(lvsCopy: LvsCopy.storeConfidential),
            'does not offer to store the message in the LVS',
          ),
          (
            'a delayed send on a platform without scheduled messages',
            _scheduledMessagesDisabled,
            MessageSendOptions(sendAt: _morningInTwoDays()),
            'does not offer a delayed send',
          ),
          (
            'a delayed send on a form without the sendDate field',
            _withoutSendDate,
            MessageSendOptions(sendAt: _morningInTwoDays()),
            'does not offer a delayed send',
          ),
        ]) {
          test(description, () async {
            final server = await serve(edit: edit);

            // Without the check, the message went out without the option.
            await expectLater(
              send(messages, options),
              throwsA(
                isA<SmartschoolComposeError>().having(
                  (e) => e.message,
                  'message',
                  allOf([
                    contains('$operation:'),
                    contains(message),
                    contains('Nothing was sent'),
                  ]),
                ),
              ),
            );
            expect(server.log, hasLength(1));
            expect(server.log.single, startsWith('GET /'));
            expect(server.log.single, contains('file=composeMessage'));
            expect(server.submits, isEmpty);
          });
        }

        test('the default options still send on such a form', () async {
          final server = await serve(
            edit: (form) =>
                _withoutSendDate(_withoutLvsSelect(form)).replaceAll(
                  '"isScheduledMessagesEnabled":true',
                  '"isScheduledMessagesEnabled":false',
                ),
          );

          await send(messages, const MessageSendOptions());

          final submit = server.submits.single;
          expect(submit['copyToLVS'], 'dontCopyToLVS');
          expect(submit['sendDate'], '');
        });
      });
    });
  }
}
