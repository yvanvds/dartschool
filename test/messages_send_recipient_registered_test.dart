// Regression tests for issue #39: `MessagesService.sendMessage` (and
// `sendReply`, which shares its send) registered each recipient on the
// compose form with `addUserToSelected` and ignored the answer. A recipient
// that Smartschool did not register went unnoticed: the form was submitted,
// Smartschool confirmed the send, and the method returned normally although
// the message went to fewer recipients than asked, or to none.
//
// Each answer is now checked for the recipient that was asked for, and a
// recipient that Smartschool does not register stops the send with a
// `SmartschoolComposeError` naming it, before the attachments and the
// submit: nothing is sent.
//
// The fake Smartschool below answers `addUserToSelected` as the live platform
// did for #39 (checked on a new-message compose form that was then
// abandoned, never submitted): a recipient it registers with `200` and XML
// that describes it (`support/add_recipient_answer.dart`), a second
// registration of a recipient in the same field with `200` and an empty
// body, as it answers an unknown user; and, for an unknown `ssid`, `500`
// with its error page.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/add_recipient_answer.dart';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

/// The recorded new-message form.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// The recorded reply form of received message 900030 from Piet Peeters
/// (user 201), which names him in To.
final _replyForm = _fixture('get/composemessage/reply.html');

/// The recorded answer to a sent message: `200` and a page whose script
/// calls `checkOpenerActions(); window.close();`.
final _sendAnswer = _fixture('post/composemessage/on_send.html');

/// The recorded answer to `addUserToSelected` for John Smith (user 146).
final _recordedAnswerFor146 = _fixture(
  'post/composemessage/add-users-to-selected.xml',
);

/// Smartschool's generic error page, as it answered `addUserToSelected`
/// with `ssid` `0` (HTTP `500`, verified live; shortened).
const _errorPage =
    '<!DOCTYPE html><html><head><title></title><meta charset="utf-8">'
    '</head><body><div id="#smscMain"><div class="container">'
    '<div class="container-textbox"><h1>Oeps, er ging iets mis</h1>'
    '<p>We zijn ermee bezig om deze situatie zo snel mogelijk te herstellen.'
    '</p></div></div></div></body></html>';

// The steps of a send, as the fake logs them.
const _form = 'form';
const _upload = 'upload';
const _submit = 'submit';

/// The registration of the recipient with [typeId] and [id] in the field
/// [type], as the fake logs it.
String _add(String typeId, int id, [RecipientType type = RecipientType.to]) =>
    'add $typeId $id to field ${type.requestType}';

/// A Smartschool that answers the steps of a send as the live platform does.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.answers = const {}});

  /// Smartschool's answer to the registration of a recipient, by the
  /// registration as logged (see [_add]), in place of the answer the live
  /// platform gives (such as the answer for a recipient it does not
  /// register).
  final Map<String, ResponseBody Function()> answers;

  /// Every step of a send the client made (see [_add] for a registration).
  final List<String> log = <String>[];

  /// The recipients registered on the form, by field: registration as logged.
  final Set<String> _registered = <String>{};

  /// The number of submits Smartschool handled: the messages it sent.
  int submits = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final query = options.uri.queryParameters;
    final post = options.method == 'POST';
    if (query['file'] == 'composeMessage') {
      if (!post) {
        log.add(_form);
        return _response(
          query['composeType'] == '0' ? _newMessageForm : _replyForm,
        );
      }
      log.add(_submit);
      submits++;
      return _response(_sendAnswer);
    }
    if (post && query['function'] == 'addUserToSelected') {
      final fields = Map<String, String>.from(options.data as Map);
      final registration =
          'add ${fields['typeId']} ${fields['id']} to field '
          '${fields['type']}';
      log.add(registration);
      final answer = answers[registration];
      if (answer != null) return answer();
      // A second registration in the same field: an empty answer.
      if (!_registered.add(registration)) return _response('');
      return _response(
        registeredRecipientAnswer(fields),
        contentType: registeredRecipientContentType,
      );
    }
    if (post && options.uri.path == '/Upload/Upload/Index') {
      log.add(_upload);
      return _response('true');
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

const _alice = MessageSearchUser(
  userId: 11111,
  displayName: 'Alice Example',
  ssId: 4069,
);
const _bob = MessageSearchUser(
  userId: 22222,
  displayName: 'Bob Example',
  ssId: 4069,
);
const _john = MessageSearchUser(
  userId: 146,
  displayName: 'John Smith',
  ssId: 4069,
);
const _class1A = MessageSearchGroup(
  groupId: 298,
  displayName: '1A',
  ssId: 4069,
);

/// The sender of message 900030, as its reply form names him.
const _piet = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);

SendMessageParams _message({
  List<MessageSearchUser> to = const [_alice],
  List<MessageSearchUser> cc = const [],
  List<MessageSearchUser> bcc = const [],
  List<MessageSearchGroup> toGroups = const [],
  List<MessageSearchGroup> ccGroups = const [],
  List<MessageSearchGroup> bccGroups = const [],
  List<String> attachments = const [],
}) => SendMessageParams(
  to: to,
  cc: cc,
  bcc: bcc,
  toGroups: toGroups,
  ccGroups: ccGroups,
  bccGroups: bccGroups,
  subject: 'Test',
  bodyHtml: '<p>Test</p>',
  attachmentPaths: attachments,
);

/// The [SmartschoolComposeError] of [operation] for [recipient], which
/// Smartschool did not register: nothing was sent, so it is not a
/// [SmartschoolSendUnconfirmedError].
Matcher _notRegistered(String operation, String recipient) => allOf(
  isA<SmartschoolComposeError>().having(
    (e) => e.message,
    'message',
    allOf(
      startsWith('$operation: '),
      contains('did not register the recipient $recipient'),
      contains('Nothing was sent.'),
    ),
  ),
  isNot(isA<SmartschoolSendUnconfirmedError>()),
);

void main() {
  late Directory tempDir;
  late SmartschoolClient client;
  late MessagesService messages;

  Future<_Smartschool> serve(_Smartschool server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: p.join(tempDir.path, 'cache'),
    );
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
    return server;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_39_');
  });

  tearDown(() async {
    await client.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('sendMessage stops before the submit when Smartschool does not '
      'register a recipient (#39)', () {
    final answers = <String, ResponseBody Function()>{
      'an empty answer (as for a user Smartschool does not know)': () =>
          _response(''),
      "Smartschool's error page (500, as for an unknown ssid)": () =>
          _response(_errorPage, status: 500),
      'an answer that registers another user (the recorded answer for '
          'user 146)': () =>
          _response(_recordedAnswerFor146, contentType: 'text/xml'),
      'an answer that registers a group with the ID of the user': () =>
          _response(
            registeredRecipientAnswer({
              'id': '22222',
              'typeId': 'groups',
              'type': '0',
              'parentNodeId': 'insertSearchFieldContainer_0_0',
              'ssid': '4069',
              'userlt': '0',
            }),
            contentType: registeredRecipientContentType,
          ),
      'a page that is not XML': () =>
          _response('<html><body>Berichten</body></html>'),
    };

    for (final MapEntry(key: name, value: answer) in answers.entries) {
      test(name, () async {
        final server = await serve(
          _Smartschool(answers: {_add('users', 22222): answer}),
        );

        // Before the fix: the form was submitted without Bob, and
        // sendMessage returned normally.
        await expectLater(
          messages.sendMessage(_message(to: [_alice, _bob])),
          throwsA(
            _notRegistered('sendMessage', 'Bob Example (user 22222, To)'),
          ),
        );
        expect(server.log, [_form, _add('users', 11111), _add('users', 22222)]);
        expect(server.submits, 0);
      });
    }

    test('the error names the field of the recipient: CC', () async {
      final server = await serve(
        _Smartschool(
          answers: {
            _add('users', 22222, RecipientType.cc): () => _response(''),
          },
        ),
      );

      await expectLater(
        messages.sendMessage(_message(cc: [_bob])),
        throwsA(_notRegistered('sendMessage', 'Bob Example (user 22222, CC)')),
      );
      expect(server.submits, 0);
    });

    test('the error names the field of the recipient: BCC', () async {
      final server = await serve(
        _Smartschool(
          answers: {
            _add('users', 22222, RecipientType.bcc): () => _response(''),
          },
        ),
      );

      await expectLater(
        messages.sendMessage(_message(bcc: [_bob])),
        throwsA(_notRegistered('sendMessage', 'Bob Example (user 22222, BCC)')),
      );
      expect(server.submits, 0);
    });

    test('a group', () async {
      final server = await serve(
        _Smartschool(answers: {_add('groups', 298): () => _response('')}),
      );

      await expectLater(
        messages.sendMessage(_message(toGroups: [_class1A])),
        throwsA(_notRegistered('sendMessage', '1A (group 298, To)')),
      );
      expect(server.log, [_form, _add('users', 11111), _add('groups', 298)]);
      expect(server.submits, 0);
    });

    test('the attachments are not uploaded', () async {
      final attachment = File(p.join(tempDir.path, 'note.txt'))
        ..writeAsStringSync('attachment');
      final server = await serve(
        _Smartschool(answers: {_add('users', 11111): () => _response('')}),
      );

      await expectLater(
        messages.sendMessage(_message(attachments: [attachment.path])),
        throwsA(isA<SmartschoolComposeError>()),
      );
      expect(server.log, [_form, _add('users', 11111)]);
      expect(server.submits, 0);
    });

    test('the error shows what Smartschool answered', () async {
      await serve(
        _Smartschool(
          answers: {
            _add('users', 11111): () => _response(_errorPage, status: 500),
          },
        ),
      );

      await expectLater(
        messages.sendMessage(_message()),
        throwsA(
          isA<SmartschoolComposeError>().having(
            (e) => e.message,
            'message',
            contains('(HTTP 500, answer: Oeps, er ging iets mis'),
          ),
        ),
      );
    });
  });

  group('sendMessage sends when Smartschool registers every recipient '
      '(#39)', () {
    test('users and groups, in every field', () async {
      final server = await serve(_Smartschool());

      await messages.sendMessage(
        _message(
          to: [_alice],
          cc: [_bob],
          bcc: [_john],
          toGroups: [_class1A],
          ccGroups: [_class1A],
          bccGroups: [_class1A],
        ),
      );

      expect(server.log, [
        _form,
        _add('users', 11111),
        _add('users', 22222, RecipientType.cc),
        _add('users', 146, RecipientType.bcc),
        _add('groups', 298),
        _add('groups', 298, RecipientType.cc),
        _add('groups', 298, RecipientType.bcc),
        _submit,
      ]);
      expect(server.submits, 1);
    });

    test('the recorded answer registers user 146', () async {
      final server = await serve(
        _Smartschool(
          answers: {
            _add('users', 146): () =>
                _response(_recordedAnswerFor146, contentType: 'text/xml'),
          },
        ),
      );

      await messages.sendMessage(_message(to: [_john]));

      expect(server.log, [_form, _add('users', 146), _submit]);
      expect(server.submits, 1);
    });

    test('a recipient listed twice in a field is registered once: '
        'Smartschool answers a second registration without it', () async {
      final server = await serve(_Smartschool());

      // Before the fix: registered twice (the second answer, empty, was
      // ignored); with the check alone, the empty answer would stop the send.
      await messages.sendMessage(
        _message(to: [_alice, _alice], toGroups: [_class1A, _class1A]),
      );

      expect(server.log, [
        _form,
        _add('users', 11111),
        _add('groups', 298),
        _submit,
      ]);
      expect(server.submits, 1);
    });

    test('a recipient in two fields is registered in each', () async {
      final server = await serve(_Smartschool());

      await messages.sendMessage(_message(to: [_alice], cc: [_alice]));

      expect(server.log, [
        _form,
        _add('users', 11111),
        _add('users', 11111, RecipientType.cc),
        _submit,
      ]);
    });
  });

  group('sendReply stops before the submit when Smartschool does not '
      'register a recipient (#39)', () {
    test('a recipient it adds to the reply form', () async {
      final server = await serve(
        _Smartschool(answers: {_add('users', 11111): () => _response('')}),
      );

      // Before the fix: the reply was submitted to Piet only, and sendReply
      // returned normally.
      await expectLater(
        messages.sendReply(900030, _message(to: [_piet, _alice])),
        throwsA(_notRegistered('sendReply', 'Alice Example (user 11111, To)')),
      );
      expect(server.log, [_form, _add('users', 11111)]);
      expect(server.submits, 0);
    });

    test('the recipient the reply form names is not registered, and the '
        'reply is sent', () async {
      final server = await serve(_Smartschool());

      await messages.sendReply(900030, _message(to: [_piet, _alice]));

      expect(server.log, [_form, _add('users', 11111), _submit]);
      expect(server.submits, 1);
    });
  });
}
