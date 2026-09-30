// Tests for issue #26: `MessagesService.sendReply`, a reply that Smartschool
// links to the message it answers.
//
// `sendMessage` always submits the new-message form (`composeType=0`,
// `msgID=undefined`, `origMsgID` 0 and `composeAction` 0), so a reply sent
// with it is a new message, linked to the original by its subject only.
// Smartschool's reply forms (`composeType=1`, and `2` for reply all, with
// `msgID=<id>`) carry `origMsgID=<id>` and `composeAction=2`, have an empty
// `action`, and are submitted by the web client to the URL they were loaded
// from, with `send=send` (#24; the compose script sets `send` and calls
// `form.submit()`). They come with the recipients of the reply registered on
// them: the web client registers only recipients the user adds, and a reply
// sent without touching the recipients goes to them. Its × on a recipient
// takes it off the form with `deleteUsersFromSelected` (#42), and its drag and
// drop moves one to another field by taking it off its field and registering
// it in the other.
//
// The fake Smartschool below serves the recorded reply form
// (`get/composemessage/reply.html`, whose names, IDs and tokens are made up)
// and the recorded answers to the steps of a send, and logs every request
// with its full URL, so the tests can check the exact requests: the form
// that is loaded, the recipients that are taken off it and registered, and
// the URL and fields of the submit. A reply is never submitted to the live
// platform by these tests or by their author: the live submit of a reply is
// untested.
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
import 'support/remove_recipient_answer.dart';

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

/// The reply form of received message 900030 from Piet Peeters (201), for
/// user 777 (Jan Janssens).
final _replyForm = _fixture('get/composemessage/reply.html');

/// The tokens of [_replyForm].
const _uniqueUsc = '100fakeUniqueUsc00000000000000000000000100';
const _randomDir = 'fakeRandomDir0000000000000000000000000000';
const _encryptedSender = '0123456789abcdef0123456789abcdef';

/// The recorded new-message form.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// The recorded answer to a sent message: `200` and a page whose script
/// calls `checkOpenerActions(); window.close();`.
final _sendAnswer = _fixture('post/composemessage/on_send.html');

/// The To entry of the sender in [_replyForm].
const _senderSpan =
    '<div oncontextmenu="disableContext(event); return false;" '
    'typeidatt="users" realuserid="201" idatt="U201" userltatt="0" '
    'typeatt="0" ssidatt="100" selected="no" unselectable="on" '
    'name="receiverPart0" id="receiverPart0_100_U201_0" '
    'class="receiverSpan user">';

/// A compose form entry of user [userId] in the field with `typeatt` [type].
String _span(int userId, String type) =>
    '<div typeidatt="users" realuserid="$userId" idatt="U$userId" '
    'userltatt="0" typeatt="$type" ssidatt="100" name="receiverPart$type" '
    'class="receiverSpan user"><div class=\'receiverSpanName userm\'>'
    'User $userId</div></div>';

/// [page] with [spans] added at the end of the field whose `typeatt` is
/// [type] (`0` To, `2` CC, `3` BCC).
String _withEntries(String page, String type, String spans) {
  final field =
      '<div class="insertSearchField" name="insertSearchFieldContainer$type"';
  expect(page, contains(field));
  return page.replaceFirst(field, '$spans$field');
}

/// The reply-all form of message 900030: the other To recipients (202, 203)
/// before the sender, and one CC recipient (204). It differs from the reply
/// form in its recipients and its `composeTypeVal` (#24).
final _replyAllForm = _withEntries(
  _replyForm
      .replaceFirst(
        _senderSpan,
        '${_span(202, '0')}${_span(203, '0')}$_senderSpan',
      )
      .replaceFirst(
        'id="composeTypeVal" value="1"',
        'id="composeTypeVal" value="2"',
      ),
  '2',
  _span(204, '2'),
);

/// [_replyForm] with the user (777) as the sender, as Smartschool shows the
/// reply form of a sent message.
final _replyFormFromUser = _replyForm
    .replaceFirst(_senderSpan, _senderSpan.replaceAll('201', '777'))
    .replaceFirst('>Piet Peeters<', '>Jan Janssens<');

/// What Smartschool answers for a message ID the box does not hold: a page
/// without compose form.
const _noComposeForm =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head>'
    '<body><div id="content"></div>'
    '<input type="hidden" id="datepickerPlanner" value="1"></body></html>';

// The URLs of the requests, as the fake logs them.
const _compose = '/?module=Messages&file=composeMessage';
const _replyUrl = '$_compose&boxType=inbox&composeType=1&msgID=900030';
const _replyAllUrl = '$_compose&boxType=inbox&composeType=2&msgID=900030';
const _sentReplyUrl = '$_compose&boxType=outbox&composeType=1&msgID=900030';
const _newMessageUrl = '$_compose&boxType=inbox&composeType=0&msgID=undefined';
const _addUrl = '/?module=Messages&file=searchUsers&function=addUserToSelected';
const _removeUrl =
    '/?module=Messages&file=searchUsers&function=deleteUsersFromSelected';
const _uploadUrl = '/Upload/Upload/Index';

/// The step of a send that a request is.
enum _Step { form, removeRecipient, addRecipient, upload, submit, other }

/// A Smartschool that answers the steps of a send with the recorded answers,
/// and refuses the session for the step [refuse] as the live platform does:
/// an XHR/form POST gets a bare `401`, a POST without `X-Requested-With` a
/// `302` to `/login`, a GET the login chain.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.form = _formFor,
    this.refuse,
    this.unreachable,
    this.answerSubmit,
    this.failSubmit,
    this.answerRemove,
  });

  /// The compose form Smartschool answers a form request with [query].
  final String Function(Map<String, String> query) form;

  static String _formFor(Map<String, String> query) =>
      switch (query['composeType']) {
        '0' => _newMessageForm,
        '1' => _replyForm,
        '2' => _replyAllForm,
        _ => fail('unexpected form: $query'),
      };

  /// The step for which Smartschool refuses the session.
  final _Step? refuse;

  /// The step that fails to connect, before it reaches Smartschool.
  final _Step? unreachable;

  /// Smartschool's answer to a submit it handled; the recorded send answer
  /// when `null`.
  final ResponseBody Function()? answerSubmit;

  /// Thrown instead of the answer, once Smartschool handled the submit: the
  /// connection failed after the message went out.
  final Object Function(RequestOptions options)? failSubmit;

  /// Smartschool's answer to a `deleteUsersFromSelected` it handled; when
  /// `null`, the recorded answer of an entry the form has, which lists the
  /// entries of the request.
  final ResponseBody Function(Map<String, String> fields)? answerRemove;

  /// Every request the client made, as `METHOD <path and query>`.
  final List<String> log = <String>[];

  /// The fields of each `deleteUsersFromSelected` Smartschool handled.
  final List<Map<String, String>> removed = <Map<String, String>>[];

  /// The fields of each `addUserToSelected` Smartschool handled.
  final List<Map<String, String>> registered = <Map<String, String>>[];

  /// The `uploadDir` of each upload Smartschool handled.
  final List<String?> uploads = <String?>[];

  /// The fields of each submit Smartschool handled (so of each message it
  /// sent, unless its answer says otherwise).
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
    final step = _stepOf(options);
    if (step == unreachable) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
        error: const SocketException('Connection refused'),
      );
    }
    if (step == refuse) {
      if (options.method == 'GET') return _response('<html>login</html>');
      return _sentWithXhr(options)
          ? _response('', status: 401)
          : _redirect('/login');
    }

    switch (step) {
      case _Step.form:
        return _response(form(uri.queryParameters));
      case _Step.removeRecipient:
        final fields = Map<String, String>.from(options.data as Map);
        removed.add(fields);
        return answerRemove?.call(fields) ??
            _response(
              removedRecipientsAnswer(fields['xml']!),
              contentType: removedRecipientContentType,
            );
      case _Step.addRecipient:
        final fields = Map<String, String>.from(options.data as Map);
        registered.add(fields);
        return _response(
          registeredRecipientAnswer(fields),
          contentType: registeredRecipientContentType,
        );
      case _Step.upload:
        uploads.add(_fields(options)['uploadDir']);
        return _response('true');
      case _Step.submit:
        submits.add(_fields(options));
        final fail = failSubmit;
        if (fail != null) throw fail(options);
        return answerSubmit?.call() ?? _response(_sendAnswer);
      case _Step.other:
        return _response('not found', status: 404);
    }
  }

  static _Step _stepOf(RequestOptions options) {
    final query = options.uri.queryParameters;
    final post = options.method == 'POST';
    if (query['file'] == 'composeMessage') {
      return post ? _Step.submit : _Step.form;
    }
    if (post && query['function'] == 'addUserToSelected') {
      return _Step.addRecipient;
    }
    if (post && query['function'] == 'deleteUsersFromSelected') {
      return _Step.removeRecipient;
    }
    if (post && options.uri.path == _uploadUrl) return _Step.upload;
    return _Step.other;
  }

  @override
  void close({bool force = false}) {}
}

/// The fields of a multipart request.
Map<String, String> _fields(RequestOptions options) => {
  for (final field in (options.data as FormData).fields) field.key: field.value,
};

bool _sentWithXhr(RequestOptions options) => options.headers.entries.any(
  (h) =>
      h.key.toLowerCase() == kXRequestedWith.toLowerCase() &&
      h.value == 'XMLHttpRequest',
);

/// A redirect the HTTP client leaves unfollowed, as it does after a POST,
/// with the page Smartschool (Symfony) sends along with it.
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '<!DOCTYPE html>\n<html>\n<head>\n'
  '<title>Redirecting to $location</title>\n</head>\n'
  '<body>Redirecting to <a href="$location">$location</a>.</body>\n</html>',
  302,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    'location': [location],
  },
);

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

/// The sender of message 900030, as the reply form names them.
const _sender = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);
const _alice = MessageSearchUser(
  userId: 11111,
  displayName: 'Alice Example',
  ssId: 100,
);
const _bob = MessageSearchUser(
  userId: 22222,
  displayName: 'Bob Example',
  ssId: 100,
);
const _carol = MessageSearchUser(
  userId: 33333,
  displayName: 'Carol Example',
  ssId: 100,
  userLt: 1,
);

SendMessageParams _reply({
  List<MessageSearchUser> to = const [_sender],
  List<MessageSearchUser> cc = const [],
  List<MessageSearchUser> bcc = const [],
  List<String> attachments = const [],
}) => SendMessageParams(
  to: to,
  cc: cc,
  bcc: bcc,
  subject: 'Re: Schoolreis',
  bodyHtml: '<p>Prima, tot vrijdag.</p>',
  attachmentPaths: attachments,
);

/// The fields `addUserToSelected` registers [user] with in the field [type]
/// of the reply form.
Map<String, String> _registration(MessageSearchUser user, RecipientType type) =>
    {
      'id': '${user.userId}',
      'typeId': 'users',
      'type': type.requestType,
      'parentNodeId': type.parentNodeId,
      'ssid': '${user.ssId}',
      'userlt': '${user.userLt}',
      'uniqueUsc': _uniqueUsc,
    };

/// The fields `deleteUsersFromSelected` takes the entry of [user] off the
/// reply form with: the entry's `typeatt` [type] (`0` To, `2` CC, `3` BCC,
/// `1`, `4` and `5` the co-account fields) and `idatt` (`U<userId>`), and its
/// `ssidatt` and `userltatt`, as the web client's × sends them.
Map<String, String> _removal(MessageSearchUser user, String type) => {
  'xml':
      '<users><user><type>$type</type><userid>U${user.userId}</userid>'
      '<ssid>${user.ssId}</ssid><userlt>${user.userLt}</userlt></user></users>',
  'uniqueUsc': _uniqueUsc,
};

/// The fields of the submit of the reply form of message 900030 in [box],
/// with [composeType] `1` (reply) or `2` (reply all).
Map<String, String> _replySubmit({
  String box = 'inbox',
  String composeType = '1',
}) => {
  'module': 'Messages',
  'file': 'composeMessage',
  'boxType': box,
  'composeType': composeType,
  'msgID': '900030',
  'origMsgID': '900030',
  'composeAction': '2',
  'send': 'send',
  'encryptedSender': _encryptedSender,
  'randomDir': _randomDir,
  'uniqueUsc': _uniqueUsc,
  'subject': 'Re: Schoolreis',
  'message': '<p>Prima, tot vrijdag.</p>',
};

/// A [SmartschoolSendUnconfirmedError] of `sendReply`.
Matcher _unconfirmed({int? statusCode, Matcher cause = isNull}) =>
    isA<SmartschoolSendUnconfirmedError>()
        .having((e) => e.statusCode, 'statusCode', statusCode)
        .having((e) => e.cause, 'cause', cause)
        .having((e) => e.message, 'message', contains('sendReply:'))
        .having((e) => e.message, 'message', contains('check the sent box'));

/// A [SmartschoolSessionExpiredError] for a step that is not retried after
/// logging in again.
Matcher _notRetried() => isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('not retried after logging in again'),
);

/// A [SmartschoolComposeError] of `sendReply` whose message contains all of
/// [texts].
Matcher _composeError(List<String> texts) => isA<SmartschoolComposeError>()
    .having((e) => e.message, 'message', contains('sendReply:'))
    .having((e) => e.message, 'message', stringContainsInOrder(texts));

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

  File attachment() =>
      File(p.join(tempDir.path, 'note.txt'))..writeAsStringSync('attachment');

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_26_');
  });

  tearDown(() async {
    await client.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('sendReply submits the reply form of the message (#26)', () {
    test('to the URL it was loaded from, with its origMsgID, composeAction '
        'and tokens, without registering the sender it names again', () async {
      final server = await serve(_Smartschool());

      final (to, cc, bcc) = await messages.getReplyRecipients(900030);
      await messages.sendReply(900030, _reply(to: to, cc: cc, bcc: bcc));

      // Before the change, a reply went through sendMessage: the
      // new-message form, submitted with composeType 0, msgID undefined,
      // origMsgID 0 and composeAction 0, and the sender registered on it.
      expect(server.log, [
        'GET $_replyUrl', // getReplyRecipients
        'GET $_replyUrl',
        'POST $_replyUrl',
      ]);
      expect(server.registered, isEmpty);
      expect(
        server.submits.single,
        allOf([
          for (final MapEntry(:key, :value) in _replySubmit().entries)
            containsPair(key, value),
        ]),
      );
    });

    test('registers the recipients the form does not name with its '
        'uniqueUsc, in their field', () async {
      final server = await serve(_Smartschool());

      await messages.sendReply(
        900030,
        _reply(to: [_sender, _alice], cc: [_bob], bcc: [_carol]),
      );

      expect(server.log, [
        'GET $_replyUrl',
        'POST $_addUrl',
        'POST $_addUrl',
        'POST $_addUrl',
        'POST $_replyUrl',
      ]);
      expect(server.registered, [
        _registration(_alice, RecipientType.to),
        _registration(_bob, RecipientType.cc),
        _registration(_carol, RecipientType.bcc),
      ]);
      expect(server.submits.single, containsPair('origMsgID', '900030'));
    });

    test('with all: the reply-all form, whose recipients are not registered '
        'again', () async {
      final server = await serve(_Smartschool());

      final (to, cc, bcc) = await messages.getReplyAllRecipients(900030);
      expect(to.map((u) => u.userId), [202, 203, 201]);
      expect(cc.map((u) => u.userId), [204]);
      await messages.sendReply(
        900030,
        _reply(to: to, cc: cc, bcc: [...bcc, _carol]),
        all: true,
      );

      expect(server.log, [
        'GET $_replyAllUrl', // getReplyAllRecipients
        'GET $_replyAllUrl',
        'POST $_addUrl',
        'POST $_replyAllUrl',
      ]);
      expect(server.registered, [_registration(_carol, RecipientType.bcc)]);
      expect(
        server.submits.single,
        allOf([
          for (final MapEntry(:key, :value) in _replySubmit(
            composeType: '2',
          ).entries)
            containsPair(key, value),
        ]),
      );
    });

    test('of a message in the sent box: the form of that box', () async {
      final server = await serve(_Smartschool(form: (_) => _replyFormFromUser));
      const user = MessageSearchUser(
        userId: 777,
        displayName: 'Jan Janssens',
        ssId: 100,
      );

      await messages.sendReply(
        900030,
        _reply(to: [user]),
        boxType: BoxType.sent,
      );

      expect(server.log, ['GET $_sentReplyUrl', 'POST $_sentReplyUrl']);
      expect(server.registered, isEmpty);
      expect(
        server.submits.single,
        allOf([
          for (final MapEntry(:key, :value) in _replySubmit(
            box: 'outbox',
          ).entries)
            containsPair(key, value),
        ]),
      );
    });

    test('uploads the attachments to the reply form\'s randomDir', () async {
      final server = await serve(_Smartschool());

      await messages.sendReply(
        900030,
        _reply(attachments: [attachment().path]),
      );

      expect(server.log, [
        'GET $_replyUrl',
        'POST $_uploadUrl',
        'POST $_replyUrl',
      ]);
      expect(server.uploads, [_randomDir]);
      expect(server.submits.single, containsPair('randomDir', _randomDir));
    });

    test('sendMessage still submits the new-message form: a new message, '
        'linked to no other', () async {
      final server = await serve(_Smartschool());

      await messages.sendMessage(_reply());

      expect(server.log, [
        'GET $_newMessageUrl',
        'POST $_addUrl',
        'POST $_newMessageUrl',
      ]);
      // The new-message form names no recipient: the sender is registered.
      expect(server.registered, [
        {
          ..._registration(_sender, RecipientType.to),
          'uniqueUsc': '4069fDsFgJGxHbeGeCwnF3HXbNTDg17757280354069',
        },
      ]);
      final submit = server.submits.single;
      expect(submit, containsPair('boxType', 'inbox'));
      expect(submit, containsPair('composeType', '0'));
      expect(submit, containsPair('msgID', 'undefined'));
      expect(submit, containsPair('origMsgID', '0'));
      expect(submit, containsPair('composeAction', '0'));
    });
  });

  group('sendReply takes a recipient that the form names and the params '
      'leave out of its field off the form (#42)', () {
    test('the sender left out: taken off before the other recipients are '
        'registered, and the reply is submitted', () async {
      final server = await serve(_Smartschool());

      // Before the change: a SmartschoolComposeError ("cannot be taken off")
      // right after loading the form, and nothing else sent.
      await messages.sendReply(900030, _reply(to: [_alice]));

      expect(server.log, [
        'GET $_replyUrl',
        'POST $_removeUrl',
        'POST $_addUrl',
        'POST $_replyUrl',
      ]);
      expect(server.removed, [_removal(_sender, '0')]);
      expect(server.registered, [_registration(_alice, RecipientType.to)]);
      expect(
        server.submits.single,
        allOf([
          for (final MapEntry(:key, :value) in _replySubmit().entries)
            containsPair(key, value),
        ]),
      );
    });

    test('the sender moved to another field: taken off To, registered in '
        'CC', () async {
      final server = await serve(_Smartschool());

      await messages.sendReply(900030, _reply(to: [_alice], cc: [_sender]));

      expect(server.log, [
        'GET $_replyUrl',
        'POST $_removeUrl',
        'POST $_addUrl',
        'POST $_addUrl',
        'POST $_replyUrl',
      ]);
      expect(server.removed, [_removal(_sender, '0')]);
      expect(server.registered, [
        _registration(_alice, RecipientType.to),
        _registration(_sender, RecipientType.cc),
      ]);
      expect(server.submits, hasLength(1));
    });

    test('a reply to all without some of the recipients the reply-all form '
        'names: each taken off its field, the others kept', () async {
      final server = await serve(_Smartschool());
      final (to, cc, _) = await messages.getReplyAllRecipients(900030);
      final user203 = to.singleWhere((u) => u.userId == 203);
      final user204 = cc.single;

      await messages.sendReply(
        900030,
        _reply(to: to.where((u) => u.userId != 203).toList()),
        all: true,
      );

      expect(server.log, [
        'GET $_replyAllUrl', // getReplyAllRecipients
        'GET $_replyAllUrl',
        'POST $_removeUrl',
        'POST $_removeUrl',
        'POST $_replyAllUrl',
      ]);
      expect(server.removed, [_removal(user203, '0'), _removal(user204, '2')]);
      expect(server.registered, isEmpty);
      expect(server.submits.single, containsPair('composeType', '2'));
    });

    test('a recipient in a co-account field is taken off with the type of '
        'that field', () async {
      final server = await serve(
        _Smartschool(
          form: (_) => _withEntries(_replyForm, '2', _span(205, '4')),
        ),
      );
      const user205 = MessageSearchUser(
        userId: 205,
        displayName: 'User 205',
        ssId: 100,
      );

      await messages.sendReply(900030, _reply());

      expect(server.removed, [_removal(user205, '4')]);
      expect(server.registered, isEmpty);
      expect(server.submits, hasLength(1));
    });

    test("the same user with another userLt: the form's entry is taken off, "
        'and the user of the params registered', () async {
      final server = await serve(_Smartschool());
      const otherLt = MessageSearchUser(
        userId: 201,
        displayName: 'Piet Peeters',
        ssId: 100,
        userLt: 1,
      );

      await messages.sendReply(900030, _reply(to: [otherLt]));

      expect(server.removed, [_removal(_sender, '0')]);
      expect(server.registered, [_registration(otherLt, RecipientType.to)]);
      expect(server.submits, hasLength(1));
    });

    test(
      'an entry the form lists twice in one field is taken off once',
      () async {
        final server = await serve(
          _Smartschool(
            form: (_) => _replyForm.replaceFirst(
              _senderSpan,
              '$_senderSpan$_senderSpan',
            ),
          ),
        );

        await messages.sendReply(900030, _reply(to: [_alice]));

        expect(server.removed, [_removal(_sender, '0')]);
        expect(server.submits, hasLength(1));
      },
    );
  });

  group('sendReply stops before the submit when Smartschool does not take a '
      'recipient off the form (#42)', () {
    final answers = <String, ResponseBody Function()>{
      'an empty list (the form does not have the entry)': () => _response(
        noRecipientRemovedAnswer,
        contentType: removedRecipientContentType,
      ),
      'an empty body': () => _response(''),
      'another entry': () => _response(
        removedRecipientsAnswer(_removal(_alice, '0')['xml']!),
        contentType: removedRecipientContentType,
      ),
      'the entry in another field': () => _response(
        removedRecipientsAnswer(_removal(_sender, '2')['xml']!),
        contentType: removedRecipientContentType,
      ),
      'its error page (500)': () => _response(
        '<html><body>Oeps, er liep iets fout.</body></html>',
        status: 500,
      ),
      'a page that is not XML': () => _response('<html><body>'),
    };

    for (final MapEntry(key: name, value: answer) in answers.entries) {
      test('Smartschool answers with $name: a SmartschoolComposeError, and '
          'no recipient, attachment or submit is sent', () async {
        final server = await serve(_Smartschool(answerRemove: (_) => answer()));

        await expectLater(
          messages.sendReply(
            900030,
            _reply(to: [_alice], attachments: [attachment().path]),
          ),
          throwsA(
            _composeError([
              'did not take the recipient Piet Peeters (user 201, To)',
              'off the reply form of message 900030',
              'Nothing was sent',
            ]),
          ),
        );
        expect(server.log, ['GET $_replyUrl', 'POST $_removeUrl']);
        expect(server.registered, isEmpty);
        expect(server.uploads, isEmpty);
        expect(server.submits, isEmpty);
      });
    }

    test('the error names the reply-all form and the field, and shows what '
        'Smartschool answered', () async {
      final server = await serve(
        _Smartschool(
          answerRemove: (_) => _response(
            '<html><body>Oeps, er liep iets fout.</body></html>',
            status: 500,
          ),
        ),
      );
      final (to, _, _) = await messages.getReplyAllRecipients(900030);

      await expectLater(
        messages.sendReply(900030, _reply(to: to), all: true),
        throwsA(
          _composeError([
            'User 204 (user 204, CC)',
            'off the reply-all form of message 900030',
            'HTTP 500, answer: Oeps, er liep iets fout.',
          ]),
        ),
      );
      expect(server.submits, isEmpty);
    });
  });

  group('without the reply form of the message, nothing is sent (#26)', () {
    final pages = <String, String>{
      'a page without compose form (the box holds no such message)':
          _noComposeForm,
      'the reply form of another message': _replyForm.replaceAll(
        '900030',
        '900031',
      ),
      'the new-message form': _newMessageForm,
    };

    for (final MapEntry(key: name, value: page) in pages.entries) {
      test(name, () async {
        final server = await serve(_Smartschool(form: (_) => page));

        await expectLater(
          messages.sendReply(900030, _reply()),
          throwsA(
            _composeError([
              'not answer with the reply form of message 900030',
              'Nothing was sent',
            ]),
          ),
        );
        expect(server.log, ['GET $_replyUrl']);
      });
    }
  });

  group('a reply has the outcome handling of sendMessage (#25, #26)', () {
    test(
      'a submit that Smartschool does not confirm is a '
      'SmartschoolSendUnconfirmedError, and is not submitted again',
      () async {
        final server = await serve(
          _Smartschool(
            answerSubmit: () =>
                _response('<html><body>Berichten</body></html>'),
          ),
        );

        await expectLater(
          messages.sendReply(900030, _reply()),
          throwsA(_unconfirmed(statusCode: 200)),
        );
        expect(server.log, ['GET $_replyUrl', 'POST $_replyUrl']);
        expect(server.submits, hasLength(1));
      },
    );

    test('an error page (500) is a SmartschoolSendUnconfirmedError', () async {
      final server = await serve(
        _Smartschool(
          answerSubmit: () => _response(
            '<html><body>Er is een fout opgetreden</body></html>',
            status: 500,
          ),
        ),
      );

      await expectLater(
        messages.sendReply(900030, _reply()),
        throwsA(_unconfirmed(statusCode: 500)),
      );
      expect(server.submits, hasLength(1));
    });

    test('the connection drops after Smartschool received the submit: a '
        'SmartschoolSendUnconfirmedError, not submitted again', () async {
      final server = await serve(
        _Smartschool(
          failSubmit: (options) => DioException.connectionError(
            requestOptions: options,
            reason: 'Connection closed before full header was received',
            error: const SocketException('Connection reset by peer'),
          ),
        ),
      );

      await expectLater(
        messages.sendReply(900030, _reply()),
        throwsA(_unconfirmed(cause: isA<SmartschoolConnectionError>())),
      );
      expect(server.log, ['GET $_replyUrl', 'POST $_replyUrl']);
      expect(server.submits, hasLength(1));
    });

    test('Smartschool cannot be reached for the reply form: a '
        'SmartschoolConnectionError, nothing sent', () async {
      final server = await serve(_Smartschool(unreachable: _Step.form));

      await expectLater(
        messages.sendReply(900030, _reply()),
        throwsA(
          allOf(
            isA<SmartschoolConnectionError>(),
            isNot(isA<SmartschoolSendUnconfirmedError>()),
          ),
        ),
      );
      expect(server.log, ['GET $_replyUrl']);
    });

    test('the session refused for the submit (302 to /login): a '
        'SmartschoolSessionExpiredError, without a login or a second '
        'submit', () async {
      final server = await serve(_Smartschool(refuse: _Step.submit));

      await expectLater(
        messages.sendReply(900030, _reply()),
        throwsA(_notRetried()),
      );
      expect(server.log, ['GET $_replyUrl', 'POST $_replyUrl']);
      expect(server.submits, isEmpty);
    });

    test('the session refused for registering a recipient (401): a '
        'SmartschoolSessionExpiredError, and nothing is submitted', () async {
      final server = await serve(_Smartschool(refuse: _Step.addRecipient));

      await expectLater(
        messages.sendReply(900030, _reply(to: [_sender, _alice])),
        throwsA(_notRetried()),
      );
      expect(server.log, ['GET $_replyUrl', 'POST $_addUrl']);
      expect(server.registered, isEmpty);
      expect(server.submits, isEmpty);
    });

    test(
      'the session refused for taking a recipient off the form (401): a '
      'SmartschoolSessionExpiredError, and nothing else is sent (#42)',
      () async {
        final server = await serve(_Smartschool(refuse: _Step.removeRecipient));

        await expectLater(
          messages.sendReply(900030, _reply(to: [_alice])),
          throwsA(_notRetried()),
        );
        expect(server.log, ['GET $_replyUrl', 'POST $_removeUrl']);
        expect(server.removed, isEmpty);
        expect(server.registered, isEmpty);
        expect(server.submits, isEmpty);
      },
    );

    test('the session refused for an attachment upload (302 to /login): a '
        'SmartschoolSessionExpiredError, and nothing is submitted', () async {
      final server = await serve(_Smartschool(refuse: _Step.upload));

      await expectLater(
        messages.sendReply(900030, _reply(attachments: [attachment().path])),
        throwsA(_notRetried()),
      );
      expect(server.log, ['GET $_replyUrl', 'POST $_uploadUrl']);
      expect(server.uploads, isEmpty);
      expect(server.submits, isEmpty);
    });
  });
}
