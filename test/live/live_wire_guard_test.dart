// Tests for LiveWireGuard (support/live_wire_guard.dart), the wire-level
// guard of the live suite (#57), against a fake Smartschool: it lets out
// what the live suite sends to the own account, and refuses everything else
// before it reaches Smartschool.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/add_recipient_answer.dart';
import '../support/no_network.dart';
import '../support/remove_recipient_answer.dart';
import '../support/temp_cache_dir.dart';
import 'support/live_wire_guard.dart';

const _host = 'school.smartschool.be';
const _tag = 'run-20261001-120000-0abc';

/// The own account of the run: user 777 (Jan Janssens) of the recorded
/// reply form.
const _own = MessageSearchUser(userId: 777, displayName: 'Me', ssId: 100);

/// Another user: the sender of message 900030 in the recorded reply form.
const _other = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

final _newMessageForm = _fixture('get/composemessage/new-message.html');
final _sendAnswer = _fixture('post/composemessage/on_send.html');
final _quickDeleteAnswer = _fixture('post/postboxes/quick delete.xml');
final _moveAnswer = _fixture('post/postboxes/quickmove messages.xml');

/// The reply form of received message 900030, from [_other].
final _replyFormFromOther = _fixture('get/composemessage/reply.html');

/// The To entry of the sender in [_replyFormFromOther].
const _senderSpan =
    '<div oncontextmenu="disableContext(event); return false;" '
    'typeidatt="users" realuserid="201" idatt="U201" userltatt="0" '
    'typeatt="0" ssidatt="100" selected="no" unselectable="on" '
    'name="receiverPart0" id="receiverPart0_100_U201_0" '
    'class="receiverSpan user">';

/// The reply form of message 900030 as the own account sent it to itself:
/// the form names the own account as the sender.
final _replyFormFromOwn = _replyFormFromOther
    .replaceFirst(_senderSpan, _senderSpan.replaceAll('201', '777'))
    .replaceFirst('>Piet Peeters<', '>Jan Janssens<');

/// The subject of a message of the run.
const _runSubject = '[dartschool test] $_tag send';

/// The recorded answer to a `message list`, with the headers [headers], as
/// (ID, subject), in place of the recorded ones.
String _messageList(List<(int, String)> headers) {
  final recorded = _fixture('post/postboxes/message list.xml');
  final start = recorded.indexOf('<message>');
  final end = recorded.lastIndexOf('</message>') + '</message>'.length;
  final template = recorded.substring(
    start,
    recorded.indexOf('</message>') + '</message>'.length,
  );
  return recorded.replaceRange(
    start,
    end,
    [
      for (final (id, subject) in headers)
        template
            .replaceFirst('<id>123456</id>', '<id>$id</id>')
            .replaceFirst(
              '<subject>Re: LO les</subject>',
              '<subject>$subject</subject>',
            ),
    ].join(),
  );
}

/// A Smartschool that answers the steps of a send, a move to the trash and
/// a message list, and records what reaches it.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    required this.replyForm,
    this.answerAdd,
    this.boxes = const {},
  });

  /// The reply form of message 900030.
  final String replyForm;

  /// The headers, as (ID, subject), that a `message list` of each box lists,
  /// by `<boxType>/<boxID>` (such as `inbox/0`); other boxes list none.
  final Map<String, List<(int, String)>> boxes;

  /// The answer to `addUserToSelected` with the given fields; the recorded
  /// answer that registers the recipient asked for when `null`.
  final String Function(Map<dynamic, dynamic> fields)? answerAdd;

  /// Every request that reached it, as `METHOD <path and query>`.
  final List<String> log = [];

  /// The fields of each `addUserToSelected` that reached it.
  final List<Map<dynamic, dynamic>> registered = [];

  /// The fields of each submit that reached it.
  final List<Map<String, String>> submits = [];

  /// The `msgID` of each `quick delete` that reached it.
  final List<String> trashed = [];

  /// Each `quickmove messages` that reached it, as `<boxType> <msgID>`.
  final List<String> moved = [];

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
    switch ((post, uri.path, query['file'], query['function'])) {
      case (false, '/', 'composeMessage', _):
        return _answer(
          query['composeType'] == '0' ? _newMessageForm : replyForm,
        );
      case (true, '/', 'composeMessage', _):
        submits.add({
          for (final field in (options.data as FormData).fields)
            field.key: field.value,
        });
        return _answer(_sendAnswer);
      case (true, '/', 'searchUsers', 'addUserToSelected'):
        final fields = options.data as Map;
        registered.add(fields);
        return _answer(
          (answerAdd ?? registeredRecipientAnswer)(fields),
          contentType: registeredRecipientContentType,
        );
      case (true, '/', 'searchUsers', 'deleteUsersFromSelected'):
        return _answer(
          removedRecipientsAnswer((options.data as Map)['xml'] as String),
          contentType: removedRecipientContentType,
        );
      case (true, '/Upload/Upload/Index', _, _):
        return _answer('true');
      case (true, '/', 'dispatcher', _):
        final command = (options.data as Map)['command'] as String;
        final id = RegExp(r'name="msgID"><!\[CDATA\[(\d+)').firstMatch(command);
        if (command.contains('<action>quick delete</action>')) {
          trashed.add(id!.group(1)!);
          return _answer(
            _quickDeleteAnswer.replaceFirst('123', id.group(1)!),
            contentType: 'text/xml',
          );
        }
        final box = RegExp(
          r'name="boxType"><!\[CDATA\[(\w+)',
        ).firstMatch(command)?.group(1);
        if (command.contains('<action>quickmove messages</action>')) {
          moved.add('$box ${id!.group(1)}');
          return _answer(_moveAnswer, contentType: 'text/xml');
        }
        if (command.contains('<action>message list</action>')) {
          final folder = RegExp(
            r'name="boxID"><!\[CDATA\[(\d+)',
          ).firstMatch(command)!.group(1);
          return _answer(
            _messageList(boxes['$box/$folder'] ?? const []),
            contentType: 'text/xml',
          );
        }
        return _answer(
          '<server><response><status>ok</status><actions><action><data>'
          '<messages/></data></action></actions></response></server>',
          contentType: 'text/xml',
        );
    }
    return _answer('<html><body>ok</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _answer(
  String body, {
  String contentType = 'text/html; charset=UTF-8',
}) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// A client on [server] with a [LiveWireGuard] for the own account (none
/// when [own] is `false`) that records its violations instead of failing the
/// test.
Future<(MessagesService, LiveWireGuard)> _guarded(
  _Smartschool server, {
  bool own = true,
  int maxSubmits = 6,
}) async {
  final client = await SmartschoolClient.create(
    AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  final guard = LiveWireGuard(
    host: _host,
    runTag: _tag,
    maxSubmits: maxSubmits,
    onViolation: (_) {},
  );
  client.dio.interceptors.add(guard);
  if (own) guard.own = _own;
  return (MessagesService(client), guard);
}

/// A bare Dio on [server] with [guard], for requests the library does not
/// make.
Dio _dio(_Smartschool server, LiveWireGuard guard) {
  final dio = Dio(BaseOptions(baseUrl: 'https://$_host'))
    ..httpClientAdapter = server
    ..interceptors.add(guard);
  addTearDown(dio.close);
  return dio;
}

SendMessageParams _params({
  List<MessageSearchUser> to = const [_own],
  List<MessageSearchUser> cc = const [],
  List<MessageSearchUser> bcc = const [],
  List<MessageSearchGroup> toGroups = const [],
  String subject = '[dartschool test] $_tag send',
  List<String> attachmentPaths = const [],
  MessageSendOptions options = const MessageSendOptions(),
}) => SendMessageParams(
  to: to,
  cc: cc,
  bcc: bcc,
  toGroups: toGroups,
  subject: subject,
  bodyHtml: '<p>Live test.</p>',
  attachmentPaths: attachmentPaths,
  options: options,
);

/// A file [name] in a temporary folder, deleted after the test.
File _tempFile(String name) {
  final dir = Directory.systemTemp.createTempSync('live_wire_guard_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return File(p.join(dir.path, name))..writeAsStringSync('attachment');
}

/// The violations of [guard], as text.
List<String> _violations(LiveWireGuard guard) =>
    guard.violations.map((v) => v.message).toList();

void main() {
  forbidRealNetwork();

  test('the recorded reply form names the sender as these tests expect', () {
    expect(_replyFormFromOther, contains(_senderSpan));
    expect(_replyFormFromOwn, isNot(contains(_senderSpan)));
  });

  test('the live suite calls no moveToTrash, which sends a quick delete: the '
      'guard would refuse it on the wire (#61)', () {
    // This file calls it, to check that the guard refuses it.
    final suite = [
      for (final file in Directory(
        p.join('test', 'live'),
      ).listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            p.basename(file.path) != 'live_wire_guard_test.dart')
          file,
    ];
    final call = RegExp(r'\.moveToTrash\s*\(');

    expect(
      suite.map((file) => p.basename(file.path)),
      containsAll(['messages_live_test.dart', 'live_run.dart']),
    );
    expect([
      for (final file in suite)
        if (call.hasMatch(file.readAsStringSync())) file.path,
    ], isEmpty);
  });

  group('lets out', () {
    test('a message to the own account, in To, CC and BCC', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await messages.sendMessage(_params(cc: [_own], bcc: [_own]));

      expect(server.registered.map((f) => (f['id'], f['type'])), [
        ('777', '0'),
        ('777', '2'),
        ('777', '3'),
      ]);
      expect(server.submits, hasLength(1));
      expect(guard.submits, 1);
      expect(guard.violations, isEmpty);
    });

    test('a reply to a message the run sent to the own account only, also '
        'one that moves the own account from To to CC', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      guard.allowReplyTo(900030);
      const subject = 'Re: [dartschool test] $_tag reply';

      await messages.sendReply(900030, _params(subject: subject));
      await messages.sendReply(
        900030,
        _params(to: [], cc: [_own], subject: subject),
      );
      await messages.sendReply(900030, _params(subject: subject), all: true);

      expect(server.submits.map((s) => s['composeType']), ['1', '1', '2']);
      expect(server.registered.map((f) => (f['id'], f['type'])), [
        ('777', '2'),
      ]);
      expect(guard.violations, isEmpty);
    });

    test('an attachment the run made', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      final file = _tempFile('${liveFilePrefix}x.txt');

      await messages.sendMessage(_params(attachmentPaths: [file.path]));

      expect(server.log, contains('POST /Upload/Upload/Index'));
      expect(server.submits, hasLength(1));
      expect(guard.violations, isEmpty);
    });

    test('a move to the trash of the sent-box copy, and then of the inbox '
        'copy, of a message the run sent, listed and checked in each box, '
        'once each (#60, #61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'outbox/0': [(4242, _runSubject)],
          'inbox/0': [(4242, 'Re: $_runSubject'), (5555, 'Hello')],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders();
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox);

      // The second move goes out with the sent-box copy in the trash: it
      // names its box, the inbox.
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox);

      expect(server.moved, ['outbox 4242', 'inbox 4242']);
      expect(guard.trashMoveAnswers.keys, [(4242, 'outbox'), (4242, 'inbox')]);
      expect(guard.trashMoveAnswers.values, everyElement(_moveAnswer));
      expect(guard.violations, isEmpty);
    });

    test('reading: message lists, messages, attachments', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.trash);
      await messages.getMessage(4242);
      await messages.getAttachments(4242);
      await messages.getReplyRecipients(4242);

      expect(server.log, hasLength(5));
      expect(guard.requestsSent, 5);
      expect(guard.violations, isEmpty);
    });
  });

  group('refuses before it reaches Smartschool', () {
    for (final (field, params) in [
      ('To', _params(to: [_own, _other])),
      ('CC', _params(cc: [_other])),
      ('BCC', _params(bcc: [_other])),
    ]) {
      test('registering another user, in $field', () async {
        final server = _Smartschool(replyForm: _replyFormFromOwn);
        final (messages, guard) = await _guarded(server);

        await expectLater(messages.sendMessage(params), throwsA(anything));

        expect(server.registered.map((f) => f['id']), everyElement('777'));
        expect(server.submits, isEmpty);
        expect(_violations(guard), [
          contains('it registers someone other than the own account'),
        ]);
      });
    }

    test('registering a group', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      const group = MessageSearchGroup(
        groupId: 5,
        displayName: 'Group',
        ssId: 100,
      );

      await expectLater(
        messages.sendMessage(_params(toGroups: [group])),
        throwsA(anything),
      );

      expect(server.registered.map((f) => f['typeId']), ['users']);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('it registers a group')]);
    });

    test('registering anyone before the own account is known', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server, own: false);

      await expectLater(messages.sendMessage(_params()), throwsA(anything));

      expect(server.registered, isEmpty);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('is not known yet')]);
    });

    test('a message whose compose form has another user registered: a '
        'reply form that names them', () async {
      final server = _Smartschool(replyForm: _replyFormFromOther);
      final (messages, guard) = await _guarded(server);
      guard.allowReplyTo(900030);

      // The library leaves the sender on the form (the params keep them),
      // and registers the own account too.
      await expectLater(
        messages.sendReply(
          900030,
          _params(to: [_other, _own], subject: 'Re: [dartschool test] $_tag x'),
        ),
        throwsA(anything),
      );

      expect(server.registered.map((f) => f['id']), ['777']);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('someone other than the own account registered'),
      ]);
    });

    test('a reply to a message that the run did not send to the own account '
        'only', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.sendReply(
          900030,
          _params(subject: 'Re: [dartschool test] $_tag x'),
        ),
        throwsA(anything),
      );

      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('replies to a message that this run did not send'),
      ]);
    });

    test(
      'anything more on a form whose answer registered someone else',
      () async {
        // Smartschool answers with the own account and another user: the
        // library finds the own account in it and would go on.
        final server = _Smartschool(
          replyForm: _replyFormFromOwn,
          answerAdd: (fields) => registeredRecipientAnswer(fields).replaceFirst(
            '</users>',
            registeredRecipientAnswer({
              ...fields,
              'id': '201',
            }).split('<users>').last,
          ),
        );
        final (messages, guard) = await _guarded(server);

        await expectLater(messages.sendMessage(_params()), throwsA(anything));

        expect(server.registered, hasLength(1));
        expect(server.submits, isEmpty);
        expect(_violations(guard), [
          contains('Smartschool registered someone other than the own account'),
        ]);
      },
    );

    test('a message stored in the LVS, or sent later', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.sendMessage(
          _params(options: const MessageSendOptions(lvsCopy: LvsCopy.store)),
        ),
        throwsA(anything),
      );
      await expectLater(
        messages.sendMessage(
          _params(
            options: MessageSendOptions(
              sendAt: DateTime.now().add(const Duration(days: 1)),
            ),
          ),
        ),
        throwsA(anything),
      );

      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('it stores the message in the LVS'),
        contains('it schedules the message for later'),
      ]);
    });

    test("a subject without the run's tag", () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      for (final subject in [
        'Hello',
        '[dartschool test] run-20200101-000000-0000 send',
        'Fwd: [dartschool test] $_tag send',
      ]) {
        await expectLater(
          messages.sendMessage(_params(subject: subject)),
          throwsA(anything),
        );
      }

      expect(server.submits, isEmpty);
      expect(_violations(guard), everyElement(contains('its subject')));
    });

    test('more messages than the run may send', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server, maxSubmits: 1);

      await messages.sendMessage(_params());
      await expectLater(messages.sendMessage(_params()), throwsA(anything));

      expect(server.submits, hasLength(1));
      expect(_violations(guard), [contains('its maximum')]);
    });

    test('an attachment the run did not make', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      final file = _tempFile('notes.txt');

      await expectLater(
        messages.sendMessage(_params(attachmentPaths: [file.path])),
        throwsA(anything),
      );

      expect(server.log, isNot(contains('POST /Upload/Upload/Index')));
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('did not make')]);
    });

    test('a quick delete (moveToTrash), of any ID: of 0, and of a message '
        'the run sent, listed and checked (#61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      guard.allowTrashFrom(4242, BoxType.inbox);

      await expectLater(messages.moveToTrash(0), throwsA(anything));
      await expectLater(messages.moveToTrash(4242), throwsA(anything));

      expect(server.trashed, isEmpty);
      expect(
        _violations(guard),
        everyElement(contains('the live suite sends no quick delete')),
      );
      expect(guard.violations, hasLength(2));
    });

    test(
      'a move to the trash of ID 0, also when the run allowed it, and '
      'Smartschool listed it in the box with the run\'s subject (#61)',
      () async {
        final server = _Smartschool(
          replyForm: _replyFormFromOwn,
          boxes: {
            'inbox/0': [(0, _runSubject)],
            'outbox/0': [(0, _runSubject)],
          },
        );
        final (messages, guard) = await _guarded(server);
        await messages.getHeaders();
        await messages.getHeaders(boxType: BoxType.sent);
        guard
          ..allowTrashFrom(0, BoxType.inbox)
          ..allowTrashFrom(0, BoxType.sent);

        await expectLater(
          messages.moveToTrashFrom(0, boxType: BoxType.inbox),
          throwsA(anything),
        );
        await expectLater(
          messages.moveToTrashFrom(0, boxType: BoxType.sent),
          throwsA(anything),
        );

        expect(server.moved, isEmpty);
        expect(_violations(guard), [
          contains('it moves message 0, which names no message'),
          contains('it moves message 0, which names no message'),
        ]);
      },
    );

    test('a move to the trash of a copy that Smartschool did not list in its '
        'box with the run\'s subject, also when the run allowed it: not a '
        'message this run sent (#61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [
            (4242, _runSubject),
            (5555, 'Hello'),
            (6666, '[dartschool test] run-20200101-000000-0000 send'),
          ],
          'trash/0': [(7777, _runSubject)],
          'inbox/208': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders(boxType: BoxType.trash);
      await messages.getHeaders(boxId: 208);
      for (final (id, box) in [
        (1234, BoxType.inbox), // Listed nowhere.
        (4242, BoxType.sent), // Listed in the inbox only.
        (5555, BoxType.inbox), // Another subject.
        (6666, BoxType.inbox), // The subject of another run.
        (7777, BoxType.inbox), // Listed in the trash only.
        (8888, BoxType.inbox), // Listed in a folder of the inbox only.
        (4242, BoxType.inbox),
      ]) {
        guard.allowTrashFrom(id, box);
      }

      for (final (id, box) in [
        (1234, BoxType.inbox),
        (4242, BoxType.sent),
        (5555, BoxType.inbox),
        (6666, BoxType.inbox),
        (7777, BoxType.inbox),
        (8888, BoxType.inbox),
      ]) {
        await expectLater(
          messages.moveToTrashFrom(id, boxType: box),
          throwsA(anything),
          reason: '$id, ${box.value}',
        );
      }
      // The copy that Smartschool listed in its box with the run's subject.
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox);

      expect(server.moved, ['inbox 4242']);
      expect(_violations(guard), [
        for (final (id, box) in [
          (1234, 'inbox'),
          (4242, 'outbox'),
          (5555, 'inbox'),
          (6666, 'inbox'),
          (7777, 'inbox'),
          (8888, 'inbox'),
        ])
          contains(
            "Smartschool did not list message $id in the $box with the run's "
            'subject',
          ),
      ]);
    });

    test('a move to the trash of a copy the run did not check in its box, '
        'or a second one of a copy (#60)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [(4242, _runSubject)],
          'outbox/0': [(4242, _runSubject), (1234, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      guard.allowTrashFrom(4242, BoxType.sent);

      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.inbox),
        throwsA(anything),
      );
      await expectLater(
        messages.moveToTrashFrom(1234, boxType: BoxType.sent),
        throwsA(anything),
      );
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(anything),
      );

      expect(server.moved, ['outbox 4242']);
      expect(_violations(guard), [
        contains(
          'the inbox copy of message 4242 is not one this run sent and '
          'checked there',
        ),
        contains('the outbox copy of message 1234 is not one this run sent'),
        contains(
          'the outbox copy of message 4242 was moved to the trash '
          'already',
        ),
      ]);
    });

    test('a move elsewhere than to the trash, or out of the trash or of a '
        'folder (#60)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox);
      final dio = _dio(server, guard);
      Future<void> move(Map<String, String> params) => expectLater(
        dio.post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(
              'postboxes',
              'quickmove messages',
              params,
            ),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );
      const fromSent = {
        'boxType': 'outbox',
        'boxID': '0',
        'msgID': '4242',
        'toBoxType': 'trash',
        'toBoxID': '0',
      };

      await move({...fromSent, 'toBoxType': 'inbox'});
      await move({...fromSent, 'toBoxID': '208'});
      await move({...fromSent, 'boxType': 'trash'});
      await move({...fromSent, 'boxType': 'inbox', 'boxID': '208'});

      expect(server.moved, isEmpty);
      expect(_violations(guard), [
        contains('it moves message 4242 elsewhere than to the trash'),
        contains('it moves message 4242 elsewhere than to the trash'),
        contains('it moves message 4242 out of the "trash"'),
        contains('it moves message 4242 out of a folder of the inbox'),
      ]);
    });

    test('any other request that changes something', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await expectLater(messages.markUnread(4242), throwsA(anything));
      await expectLater(messages.moveToArchive([4242]), throwsA(anything));
      await expectLater(
        messages.searchRecipientsForCompose('Piet'),
        throwsA(anything),
      );

      // Only the compose form of the search went out.
      expect(server.log, [
        'GET /?module=Messages&file=composeMessage&boxType=inbox'
            '&composeType=0&msgID=undefined',
      ]);
      expect(_violations(guard), [
        contains('no "mark message unread" command'),
        contains('not a request the live suite sends'),
        contains('not a request the live suite sends'),
      ]);
    });

    test('a second login', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);

      await dio.post<String>('/login', data: 'login form');
      await dio.post<String>('/2fa/api/v1/google-authenticator', data: '{}');
      await expectLater(
        dio.post<String>('/login', data: 'login form'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.post<String>('/2fa/api/v1/google-authenticator', data: '{}'),
        throwsA(isA<DioException>()),
      );

      expect(server.log, [
        'POST /login',
        'POST /2fa/api/v1/google-authenticator',
      ]);
      expect(_violations(guard), [
        contains('log in a second time in this run (its password)'),
        contains('log in a second time in this run (its 2FA code)'),
      ]);
    });

    test('a request to another host', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);

      await expectLater(
        dio.get<String>('https://example.com/'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get<String>('http://$_host/'),
        throwsA(isA<DioException>()),
      );

      expect(server.log, isEmpty);
      expect(_violations(guard), everyElement(contains('another host')));
    });
  });

  test('a refusal fails the test that sent the request, whatever the code '
      'under test does with the error', () async {
    final server = _Smartschool(replyForm: _replyFormFromOwn);
    final guard = LiveWireGuard(host: _host, runTag: _tag);
    final dio = _dio(server, guard);

    // What would fail this test is caught here instead, to be checked.
    final failures = <Object>[];
    await runZonedGuarded(() async {
      try {
        await dio.get<String>('https://example.com/');
      } on DioException {
        // The code under test swallows it.
      }
    }, (error, _) => failures.add(error));

    expect(failures, [isA<LiveGuardViolation>()]);
    expect(server.log, isEmpty);
  });
}
