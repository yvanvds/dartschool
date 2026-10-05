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
final _searchAnswer = _fixture('post/composemessage/search-user.xml');

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

const _skoreOwners = '/modules/Skore/backend/models/owners.php';
const _skoreGradebooks = '/modules/Skore/modules/rapportbeheer/rpc/data.php';

/// The `result` of Skore's answers to its reads (#91), by RPC method, with a
/// made-up teacher; any other method is answered as a save that went
/// through.
const _skoreResults = {
  'getTeachers': '[{"userID":"1001","name":"Janssens, Jan"}]',
  'getCourses':
      '[{"id":"34826","icon":"IconLib:laptop","name":"Digitale vaardigheden",'
      '"class":"5WW1","readers":[],"writers":[]}]',
};

/// The planner's lookup of a calendar by ID (#127), the one planner POST the
/// live suite sends.
const _plannerLookup = '/planner/api/v1/quick-search/planner/start';

/// The planner's answer to the lookup of class `4069_2001`, trimmed to the
/// class (made up).
const _plannerLookupAnswer =
    '{"selection":[{"identifier":{"id":"4069_2001","type":"group"},'
    '"title":[{"part":"6A1","isHighlighted":false}],"description":[],'
    '"origin":{"groupIdentifier":"4069_2001","name":"6A1",'
    '"description":"6 Latijn 1"}}],"suggestions":[],"favourites":[]}';

/// The Presence module's answers to its reads (#104, #105), by path, with a
/// made-up pupil; any other Presence request is answered as a save that went
/// through. The account may set the half-days of the class
/// (`userCanConfirm`, #121), so that `setLate` gets as far as its save.
const _presenceAnswers = {
  '/Presence/Main/getConfig':
      '{"hasErrors":false,"errors":[],"state":{"activeClass":null,'
      '"schoolyear":"2026-11-05"},"main":{"allowedClasses":[{"groupID":298,'
      '"name":"1A  ","structID":311,"userCanConfirm":true,'
      '"userCanRecord":true}]}}',
  '/Presence/Code/getAllCodes':
      '[{"codeID":497,"code":"L","name":"Te laat","alias":[]}]',
  '/Presence/Class/getClass':
      '{"groupID":298,"name":"1A  ","structID":311,"userCanRecord":true,'
      '"errorMessage":"","pupils":[{"movementID":35714,"userID":11110,'
      '"name":"Test Pupil","presence":[]}],"saveIsAllowed":true}',
};

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

/// A Smartschool that answers the steps of a send, a move to the trash or
/// to the archive, a message list and the Messages page, and records what
/// reaches it.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    required this.replyForm,
    this.answerAdd,
    this.boxes = const {},
    this.archiveFolder,
  });

  /// The reply form of message 900030.
  final String replyForm;

  /// The archive folder of the inbox that the Messages page names, or
  /// `null` for a page that names none.
  int? archiveFolder;

  /// The headers, as (ID, subject), that a `message list` of each box lists,
  /// by `<boxType>/<boxID>` (such as `inbox/0`); other boxes list none.
  final Map<String, List<(int, String)>> boxes;

  /// The answer to `addUserToSelected` with the given fields; the recorded
  /// answer that registers the recipient asked for when `null`.
  final String Function(Map<dynamic, dynamic> fields)? answerAdd;

  /// HTML pages that the dispatcher answers the next XML commands with, one
  /// per command, before it answers them as usual again (#106).
  final List<String> dispatcherPages = [];

  /// Every request that reached it, as `METHOD <path and query>`.
  final List<String> log = [];

  /// The fields of each `addUserToSelected` that reached it.
  final List<Map<dynamic, dynamic>> registered = [];

  /// The fields of each recipient search that reached it (#97).
  final List<Map<dynamic, dynamic>> searched = [];

  /// The fields of each submit that reached it.
  final List<Map<String, String>> submits = [];

  /// The `msgID` of each `quick delete` that reached it.
  final List<String> trashed = [];

  /// Each Skore RPC call that reached it, as `<path> <rpc_method>` (#91).
  final List<String> skoreCalls = [];

  /// Each `quickmove messages` that reached it, as `<boxType> <msgID>`, or
  /// `<boxType>/<boxID> <msgID>` out of a folder.
  final List<String> moved = [];

  /// The IDs of each move to the archive that reached it.
  final List<List<int>> archived = [];

  /// Each change of the read state or the flag of a message that reached it,
  /// as `<action> <boxType> <msgID>` for a command that names no folder, or
  /// `<action> <boxType>/<boxID> <msgID>` for one that names it (#94).
  final List<String> marked = [];

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
      case (true, '/', 'searchUsers', null):
        searched.add(options.data as Map);
        return _answer(_searchAnswer, contentType: 'text/xml');
      case (true, '/Upload/Upload/Index', _, _):
        return _answer('true');
      case (true, final path, _, _) when path.startsWith('/Presence/'):
        return _answer(
          _presenceAnswers[path] ?? '{"hasErrors":false,"errors":[]}',
          contentType: 'application/json',
        );
      case (true, final path, _, _) when path.startsWith('/modules/Skore/'):
        final method = (options.data as Map)['rpc_method'];
        skoreCalls.add('$path $method');
        return _answer(
          '{"result":${_skoreResults[method] ?? '{"state":1}'},"session":1}',
          contentType: 'application/json',
        );
      case (true, _plannerLookup, _, _):
        return _answer(_plannerLookupAnswer, contentType: 'application/json');
      case (false, '/', 'index', 'main'):
        final folder = archiveFolder;
        return _answer(
          folder == null
              ? '<html><body>Berichten</body></html>'
              : '<div class="postboxsub" boxtype="inbox" boxid="$folder">'
                    '<div class="postbox_ico_sub archive" boxtype="inbox" '
                    'boxid="$folder"></div></div>',
        );
      case (true, '/Messages/Xhr/archivemessages', _, _):
        final ids = [
          for (final match in RegExp(
            r'msgIDs%5B%5D=(\d+)',
          ).allMatches(options.data as String))
            int.parse(match.group(1)!),
        ];
        archived.add(ids);
        return _answer(
          '{"success":[${ids.join(',')}]}',
          contentType: 'application/json',
        );
      case (true, '/', 'dispatcher', _) when dispatcherPages.isNotEmpty:
        return _answer(dispatcherPages.removeAt(0));
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
        final folder = RegExp(
          r'name="boxID"><!\[CDATA\[(\d+)',
        ).firstMatch(command)?.group(1);
        if (command.contains('<action>quickmove messages</action>')) {
          final from = folder == '0' ? '$box' : '$box/$folder';
          moved.add('$from ${id!.group(1)}');
          return _answer(_moveAnswer, contentType: 'text/xml');
        }
        if (command.contains('<action>message list</action>')) {
          return _answer(
            _messageList(boxes['$box/$folder'] ?? const []),
            contentType: 'text/xml',
          );
        }
        final mark = RegExp(
          '<action>(mark message read|mark message unread|save msglabel)'
          '</action>',
        ).firstMatch(command)?.group(1);
        if (mark != null) {
          final where = folder == null ? '$box' : '$box/$folder';
          marked.add('$mark $where ${id!.group(1)}');
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
  final (client, guard) = await _guardedClient(
    server,
    own: own,
    maxSubmits: maxSubmits,
  );
  return (MessagesService(client), guard);
}

/// The client of [_guarded] itself, for another service than Messages.
Future<(SmartschoolClient, LiveWireGuard)> _guardedClient(
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
  return (client, guard);
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

    test('a move to the archive of the inbox copy of a message the run sent, '
        'listed and checked in the inbox; then a move to the trash of its '
        'sent-box copy, and of its archived copy out of the archive folder '
        'that the Messages page names, listed and checked there, once each '
        '(#64)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (5555, 'Hello')],
          'outbox/0': [(4242, _runSubject)],
          'inbox/312': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      guard.allowArchive(4242);

      final archiveBoxId = await messages.getArchiveBoxId();
      final archived = await messages.moveToArchive([4242]);
      await messages.getArchiveHeaders(boxId: archiveBoxId);
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox, boxId: archiveBoxId);
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await messages.moveToTrashFrom(
        4242,
        boxType: BoxType.inbox,
        boxId: archiveBoxId,
      );

      expect(archiveBoxId, 312);
      expect(guard.archiveBoxId, 312);
      expect(archived.map((c) => (c.id, c.newValue)), [(4242, 1)]);
      expect(server.archived, [
        [4242],
      ]);
      expect(guard.archiveAnswers, {4242: '{"success":[4242]}'});
      expect(server.moved, ['outbox 4242', 'inbox/312 4242']);
      expect(guard.trashMoveAnswers.keys, [(4242, 'outbox'), (4242, 'inbox')]);
      expect(guard.violations, isEmpty);
    });

    test('marking the inbox copy of a message the run sent unread and read, '
        'and flagging it, listed and checked in the inbox, and after a move '
        'to the archive in the archive folder that the Messages page names; '
        'markUnread names the folder, markRead and setLabel name none '
        '(#94)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (5555, 'Hello')],
          'inbox/312': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      guard
        ..allowMark(4242)
        ..allowArchive(4242);

      await messages.markUnread(4242);
      await messages.markRead(4242);
      await messages.setLabel(4242, MessageLabel.redFlag);
      final archiveBoxId = await messages.getArchiveBoxId();
      await messages.moveToArchive([4242]);
      // The inbox no longer lists it: only the archive folder's list does.
      await messages.getArchiveHeaders(boxId: archiveBoxId);
      await messages.markUnread(4242, boxId: archiveBoxId);
      await messages.markRead(4242);
      await messages.setLabel(4242, MessageLabel.noFlag);

      expect(server.marked, [
        'mark message unread inbox/0 4242',
        'mark message read inbox 4242',
        'save msglabel inbox 4242',
        'mark message unread inbox/312 4242',
        'mark message read inbox 4242',
        'save msglabel inbox 4242',
      ]);
      expect(guard.markAnswers.map((a) => (a.action, a.id)), [
        ('mark message unread', 4242),
        ('mark message read', 4242),
        ('save msglabel', 4242),
        ('mark message unread', 4242),
        ('mark message read', 4242),
        ('save msglabel', 4242),
      ]);
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
      expect(guard.unexpectedAnswers, isEmpty);
    });

    test('an answer to an XML command that is not XML, which it keeps with '
        'what the page is, without its scripts (#106)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn)
        ..dispatcherPages.addAll([
          '\n<!DOCTYPE html><html><head><title>Springfield Academy - '
              'Smartschool</title></head><body><h1>Storing</h1><p>Probeer het '
              'later opnieuw.</p><script>var user = "Jan Janssens";</script>'
              '</body></html>',
          'Fatal error',
        ]);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.getHeaders(),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      await expectLater(
        messages.getMessage(4242),
        throwsA(isA<SmartschoolParsingError>()),
      );
      await messages.getHeaders();

      expect(guard.unexpectedAnswers, [
        'Smartschool answered "message list" with something that is not XML '
            '(#106): status 200, text/html; charset=UTF-8, not its login page, '
            'title "Springfield Academy - Smartschool", heading "Storing", text '
            '"Storing Probeer het later opnieuw."',
        'Smartschool answered "show message" with something that is not XML '
            '(#106): status 200, text/html; charset=UTF-8, not its login page, '
            'text "Fatal error"',
      ]);
      expect(server.log, hasLength(3));
      expect(guard.violations, isEmpty);
    });

    test('the Presence reads: the config, the pupils of a class on a day '
        '(#104), and the codes of a school structure (#105)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final presence = PresenceService(client);

      final config = await presence.getConfig();
      final pupils = await presence.getClassPupils(
        classGroupId: 298,
        date: DateTime(2026, 10, 1),
        schoolyearRefDate: config.schoolyearRefDate,
      );
      final codes = await presence.getAllCodes(311);

      expect(pupils.single.userId, 11110);
      expect(codes.single.name, 'Te laat');
      expect(server.log, [
        'POST /Presence/Main/getConfig',
        'POST /Presence/Class/getClass',
        'POST /Presence/Code/getAllCodes',
      ]);
      expect(guard.violations, isEmpty);
    });

    test('the Skore reads: the teachers and the gradebooks of a teacher '
        '(#91)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final skore = SkoreService(client);

      final teachers = await skore.getTeachers();
      final gradebooks = await skore.getGradebookShares(146);

      expect(teachers.single.id, 1001);
      expect(gradebooks.single.gradebookId, 34826);
      expect(server.skoreCalls, [
        '$_skoreOwners getTeachers',
        '$_skoreGradebooks getCourses',
      ]);
      expect(guard.violations, isEmpty);
    });

    test('the planner\'s lookup of a calendar by ID (#127)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);

      final klas = await PlannerService(
        client,
      ).getCalendar(PlannerCalendar.group('4069_2001'));

      expect(klas!.name, '6A1');
      expect(server.log, ['POST $_plannerLookup']);
      expect(guard.violations, isEmpty);
    });

    test('a recipient search on a compose form loaded through it, which '
        'registers no one (#97)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      final (users, _) = await messages.searchRecipientsForCompose('John');

      expect(users.map((u) => u.userId), contains(146));
      expect(server.log, [
        'GET /?module=Messages&file=composeMessage&boxType=inbox'
            '&composeType=0&msgID=undefined',
        'POST /?module=Messages&file=searchUsers',
      ]);
      expect(server.searched.single['val'], 'John');
      expect(server.registered, isEmpty);
      expect(guard.searches, 1);
      expect(guard.violations, isEmpty);
    });

    test('several recipient searches on one compose form loaded through it '
        '(#107)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      final results = await messages.searchRecipientsForComposeAll([
        'John',
        'Piet',
      ]);

      expect(results.keys, ['John', 'Piet']);
      expect(results['Piet']!.$1.map((u) => u.userId), contains(146));
      expect(server.log, [
        'GET /?module=Messages&file=composeMessage&boxType=inbox'
            '&composeType=0&msgID=undefined',
        'POST /?module=Messages&file=searchUsers',
        'POST /?module=Messages&file=searchUsers',
      ]);
      expect(server.searched.map((f) => f['val']), ['John', 'Piet']);
      expect(server.searched.map((f) => f['uniqueUsc']).toSet(), hasLength(1));
      expect(server.registered, isEmpty);
      expect(guard.searches, 2);
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
          'checked in the inbox',
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

    test('a move to the archive of ID 0, of a message that Smartschool did '
        "not list in the inbox with the run's subject, of one the run did not "
        'check there, of more than one message at once, of a copy the run '
        'moved to the trash, and a second one (#64)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [
            (0, _runSubject),
            (4242, _runSubject),
            (1234, _runSubject),
            (5555, 'Hello'),
            (9999, _runSubject),
          ],
          'outbox/0': [(6666, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      for (final id in [0, 4242, 5555, 6666, 7777, 9999]) {
        guard.allowArchive(id);
      }
      guard.allowTrashFrom(9999, BoxType.inbox);
      await messages.moveToTrashFrom(9999, boxType: BoxType.inbox);

      for (final ids in [
        [0],
        [5555], // Another subject.
        [6666], // Listed in the sent box only.
        [7777], // Listed nowhere.
        [1234], // Listed, but the run did not check it.
        [4242, 1234],
        [9999], // Its inbox copy was moved to the trash.
      ]) {
        await expectLater(
          messages.moveToArchive(ids),
          throwsA(anything),
          reason: '$ids',
        );
      }
      await messages.moveToArchive([4242]);
      // The inbox no longer lists it: a move to the trash out of the inbox
      // needs a new listing there.
      guard.allowTrashFrom(4242, BoxType.inbox);
      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.inbox),
        throwsA(anything),
      );
      await expectLater(messages.moveToArchive([4242]), throwsA(anything));

      expect(server.archived, [
        [4242],
      ]);
      expect(server.moved, ['inbox 9999']);
      String notListed(int id) =>
          "Smartschool did not list message $id in the inbox with the run's "
          'subject';
      expect(_violations(guard), [
        contains('it archives message 0, which names no message'),
        contains(notListed(5555)),
        contains(notListed(6666)),
        contains(notListed(7777)),
        contains(
          'message 1234 is not one this run sent and checked in the inbox',
        ),
        contains('it archives 2 messages at once'),
        contains(
          'the inbox copy of message 9999 was moved to the trash already',
        ),
        contains(notListed(4242)),
        contains('message 4242 was moved to the archive already'),
      ]);
    });

    test('a move to the trash out of the archive folder of a copy that '
        "Smartschool did not list there with the run's subject, or that the "
        'run did not check there; a second move of a copy, out of any folder; '
        'and a move out of another folder, or out of the archive while no '
        'Messages page names it (#64)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (6666, _runSubject)],
          'inbox/312': [
            (4242, _runSubject),
            (3333, _runSubject),
            (5555, 'Hello'),
            (7777, _runSubject),
          ],
          'inbox/400': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxId: 312);
      await messages.getHeaders(boxId: 400);
      guard
        ..allowTrashFrom(4242, BoxType.inbox)
        ..allowTrashFrom(4242, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(4242, BoxType.sent, boxId: 312)
        ..allowTrashFrom(3333, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(5555, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(6666, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(7777, BoxType.inbox) // Out of the inbox itself only.
        ..allowTrashFrom(8888, BoxType.inbox, boxId: 400);
      Future<void> refused(int id, BoxType box, int boxId) => expectLater(
        messages.moveToTrashFrom(id, boxType: box, boxId: boxId),
        throwsA(anything),
        reason: '$id, ${box.value}/$boxId',
      );

      await refused(4242, BoxType.inbox, 312); // No Messages page yet.
      expect(await messages.getArchiveBoxId(), 312);
      await refused(5555, BoxType.inbox, 312); // Another subject.
      await refused(6666, BoxType.inbox, 312); // Listed in the inbox only.
      await refused(7777, BoxType.inbox, 312); // Not checked in the archive.
      await refused(8888, BoxType.inbox, 400); // Not the archive folder.
      await refused(4242, BoxType.sent, 312); // A folder of the sent box.
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 312);
      await refused(4242, BoxType.inbox, 312);
      await refused(4242, BoxType.inbox, 0); // The same copy.
      // A page that names another archive folder: the guard trusts neither,
      // and refuses a move it let out until then.
      server.archiveFolder = 400;
      await _dio(
        server,
        guard,
      ).get<String>('/?module=Messages&file=index&function=main');
      expect(guard.archiveBoxId, isNull);
      await refused(3333, BoxType.inbox, 312);

      expect(server.moved, ['inbox/312 4242']);
      const notArchive = 'that is not the archive folder of the inbox';
      expect(_violations(guard), [
        contains(
          'it moves message 4242 out of a folder of the inbox $notArchive',
        ),
        contains(
          "Smartschool did not list message 5555 in the archive folder (312) "
          "of the inbox with the run's subject",
        ),
        contains(
          "Smartschool did not list message 6666 in the archive folder (312) "
          "of the inbox with the run's subject",
        ),
        contains(
          'the inbox copy of message 7777 is not one this run sent and '
          'checked in the archive folder (312) of the inbox',
        ),
        contains(
          'it moves message 8888 out of a folder of the inbox $notArchive',
        ),
        contains(
          'it moves message 4242 out of a folder of the outbox $notArchive',
        ),
        contains(
          'the inbox copy of message 4242 was moved to the trash already',
        ),
        contains(
          'the inbox copy of message 4242 was moved to the trash already',
        ),
        contains(
          'it moves message 3333 out of a folder of the inbox $notArchive',
        ),
      ]);
    });

    test('marking read or unread, or flagging, ID 0, a message that '
        "Smartschool did not list in the inbox or its archive folder with the "
        "run's subject, one the run did not check, a copy in another box or "
        'in another folder, or in the archive folder while no Messages page '
        'names it, and a copy the run moved to the trash (#94)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [
            (4242, _runSubject),
            (5555, 'Hello'),
            (6666, _runSubject),
            (9999, _runSubject),
          ],
          'outbox/0': [(4242, _runSubject)],
          'inbox/312': [(7777, _runSubject)],
          'inbox/400': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders(boxId: 312);
      await messages.getHeaders(boxId: 400);
      guard
        ..allowMark(0)
        ..allowMark(4242)
        ..allowMark(5555)
        ..allowMark(7777)
        ..allowMark(8888)
        ..allowMark(9999)
        ..allowTrashFrom(9999, BoxType.inbox);
      Future<void> refused(Future<Object?> change, String reason) =>
          expectLater(change, throwsA(anything), reason: reason);

      // No Messages page named the archive folder yet.
      await refused(messages.markUnread(7777, boxId: 312), 'archive unknown');
      await refused(messages.markRead(7777), 'archive unknown: inbox only');
      expect(await messages.getArchiveBoxId(), 312);
      await refused(messages.markRead(0), 'ID 0');
      await refused(
        messages.setLabel(5555, MessageLabel.redFlag),
        'another subject',
      );
      await refused(messages.markRead(6666), 'not checked');
      await refused(
        messages.markRead(4242, boxType: BoxType.sent),
        'the sent box',
      );
      await refused(
        messages.markUnread(8888, boxId: 400),
        'not the archive folder',
      );
      await refused(
        messages.markUnread(4242, boxId: 312),
        'listed in the inbox, not in the archive folder',
      );
      await messages.moveToTrashFrom(9999, boxType: BoxType.inbox);
      await refused(
        messages.setLabel(9999, MessageLabel.redFlag),
        'moved to the trash',
      );
      // What it lets out: a copy listed in the archive folder (a command
      // without a folder), and one listed in the inbox (with folder 0).
      await messages.markRead(7777);
      await messages.markUnread(4242);

      expect(server.moved, ['inbox 9999']);
      expect(server.marked, [
        'mark message read inbox 7777',
        'mark message unread inbox/0 4242',
      ]);
      const notArchive = 'in a folder of the inbox that is not the archive';
      String notListed(int id, String where) =>
          "Smartschool did not list message $id in $where with the run's "
          'subject';
      expect(_violations(guard), [
        contains('it changes message 7777 $notArchive'),
        contains(notListed(7777, 'the inbox')),
        contains('it changes message 0, which names no message'),
        contains(notListed(5555, 'the inbox or its archive folder (312)')),
        contains(
          'message 6666 is not one this run sent and checked to change its '
          'read state and flag',
        ),
        contains('it changes the outbox copy of message 4242'),
        contains('it changes message 8888 $notArchive'),
        contains(notListed(4242, 'the archive folder (312) of the inbox')),
        contains(
          'the inbox copy of message 9999 was moved to the trash already',
        ),
      ]);
    });

    test('any other request that changes something', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);

      await expectLater(
        dio.post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(
              'postboxes',
              'empty_trash',
              {},
            ),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.post<String>(
          '/?module=Messages&file=index&function=main',
          data: {'folder': '1'},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );

      expect(server.log, isEmpty);
      expect(_violations(guard), [
        contains('no "empty_trash" command'),
        contains('not a request the live suite sends'),
      ]);
    });

    test('a save of presences, and any other Presence request but its reads '
        '(#104)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final dio = _dio(server, guard);

      // setLate reads the config, the codes and the pupils (#105: the codes
      // are a read too), then saves: refused there.
      await expectLater(
        PresenceService(client).setLate(
          userId: 11110,
          classGroupId: 298,
          date: DateTime(2026, 10, 1),
          part: DayPart.morning,
        ),
        throwsA(anything),
      );
      for (final path in [
        '/Presence/Class/savePupilsPresences',
        '/Presence/Class/deletePresences',
      ]) {
        await expectLater(
          dio.post<String>(
            path,
            data: {'pupils': '[]'},
            options: Options(contentType: Headers.formUrlEncodedContentType),
          ),
          throwsA(isA<DioException>()),
        );
      }

      expect(server.log, [
        'POST /Presence/Main/getConfig',
        'POST /Presence/Code/getAllCodes',
        'POST /Presence/Class/getClass',
      ]);
      expect(_violations(guard), [
        allOf(
          contains('POST /Presence/Class/savePupilsPresences was not sent'),
          contains('changes no presence'),
        ),
        allOf(
          contains('POST /Presence/Class/savePupilsPresences was not sent'),
          contains('changes no presence'),
        ),
        allOf(
          contains('POST /Presence/Class/deletePresences was not sent'),
          contains('changes no presence'),
        ),
      ]);
    });

    test('a save in Skore, and any other Skore POST but its two reads '
        '(#91)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final dio = _dio(server, guard);

      // shareGradebook reads the gradebooks and the teachers, then saves:
      // refused there.
      await expectLater(
        SkoreService(client).shareGradebook(
          ownerId: 146,
          gradebookId: 34826,
          teacherId: 1001,
          access: SkoreShareAccess.read,
        ),
        throwsA(anything),
      );
      final others = [
        (_skoreOwners, 'saveOwner'),
        (_skoreOwners, 'deleteOwner'),
        (_skoreOwners, 'getMyGroups'),
        (_skoreGradebooks, 'deleteTeacher'),
        (_skoreGradebooks, 'getTeachers'),
        ('/modules/Skore/backend/gradebook/rpc.php', 'gradebooksToAccess'),
      ];
      for (final (path, method) in others) {
        await expectLater(
          dio.post<String>(
            path,
            data: {'rpc_method': method, 'rpc_params': '[]'},
            options: Options(contentType: Headers.formUrlEncodedContentType),
          ),
          throwsA(isA<DioException>()),
        );
      }

      expect(server.skoreCalls, [
        '$_skoreGradebooks getCourses',
        '$_skoreOwners getTeachers',
      ]);
      expect(_violations(guard), [
        for (final path in [
          _skoreGradebooks,
          for (final (path, _) in others) path,
        ])
          allOf(
            contains('POST $path was not sent'),
            contains('changes nothing in Skore'),
          ),
      ]);
    });

    test(
      'any planner POST but its lookup of a calendar by ID (#127)',
      () async {
        final server = _Smartschool(replyForm: _replyFormFromOwn);
        final (_, guard) = await _guardedClient(server);
        final dio = _dio(server, guard);

        // The search (which only reads, but the live suite does not send it),
        // a change of the user's favourites, the clear of a lesson hour, and
        // the move of a whole period to the trash.
        final others = [
          '/planner/api/v1/quick-search/planner/search',
          '/planner/api/v1/quick-search/planner/mark-as-favourite',
          '/planner/api/v1/planned-elements/clear',
          '/planner/api/v1/planned-elements/user/4069_1001_0/trash'
              '?from=2026-10-05&to=2026-10-09',
        ];
        for (final path in others) {
          await expectLater(
            dio.post<String>(path, data: {'users': <Object>[]}),
            throwsA(isA<DioException>()),
          );
        }

        expect(server.log, isEmpty);
        expect(_violations(guard), [
          for (final path in others)
            allOf(
              contains('POST $path was not sent'),
              contains('changes nothing in the planner'),
            ),
        ]);
      },
    );

    test('a recipient search on a compose form not loaded through it, or with '
        'a selection (#97)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);
      final form = await dio.get<String>(
        '/?module=Messages&file=composeMessage&boxType=inbox&composeType=0'
        '&msgID=undefined',
      );
      final uniqueUsc = MessagesService.parseHiddenFields(
        form.data!,
      )['uniqueUsc']!;
      Future<void> search(String uniqueUsc, String xml) => expectLater(
        dio.post<String>(
          '/?module=Messages&file=searchUsers',
          data: {'val': 'Piet', 'xml': xml, 'uniqueUsc': uniqueUsc},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );

      await search('not-a-loaded-form', '<results></results>');
      await search(
        uniqueUsc,
        '<results><users><user><userID>201</userID></user></users></results>',
      );

      expect(server.searched, isEmpty);
      expect(guard.searches, 0);
      expect(_violations(guard), [
        contains('its compose form was not loaded through the guard'),
        contains('its selection (xml) is not the empty one'),
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
