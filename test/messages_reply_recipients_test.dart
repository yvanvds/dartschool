// Tests for issue #24: `MessagesService.getReplyRecipients`, the recipient
// of a plain reply, read from Smartschool's reply form (`composeType=1`).
//
// `getReplyAllRecipients` reads the reply-all form (`composeType=2`), whose
// To list holds the sender of the message among the other To recipients,
// in no fixed place and not marked as the sender. The reply form names the
// sender alone, with the same `receiverSpan` markup. Verified live
// (read-only) on 12 read inbox messages, one in the archive (with
// `boxType=inbox`) and two in the sent box: every reply form had exactly one
// entry, in To (`typeatt="0"`), with the user ID, `ssID` and `userLT` of one
// of the reply-all form's To entries: of the seven messages with several To
// recipients, the last entry in six and the first in one. For a message the
// user sent to themselves, and for the sent messages, the entry was the user.
// A message ID that the box does not hold gave a page without compose form.
//
// The fake Smartschool below answers the compose pages from canned fixtures;
// its names and IDs are made up.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

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

/// The reply form of received message 900030 from Piet Peeters (201), for
/// user 777 (Jan Janssens).
final _replyPage = _fixture('get/composemessage/reply.html');

/// The To entry of the sender in [_replyPage].
const _senderSpan =
    '<div oncontextmenu="disableContext(event); return false;" '
    'typeidatt="users" realuserid="201" idatt="U201" userltatt="0" '
    'typeatt="0" ssidatt="100" selected="no" unselectable="on" '
    'name="receiverPart0" id="receiverPart0_100_U201_0" '
    'class="receiverSpan user">';

/// A compose page entry of user [userId] in the field with `typeatt`
/// [type].
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

/// [_replyPage] with the user (777) as the sender, as Smartschool shows the
/// reply form of a sent message or of a message the user sent to themselves.
final _replyPageFromUser = _replyPage
    .replaceFirst(_senderSpan, _senderSpan.replaceAll('201', '777'))
    .replaceFirst('>Piet Peeters<', '>Jan Janssens<');

/// The reply-all form of message 900030: the other To recipients (202, 203)
/// before the sender, and one CC recipient (204).
final _replyAllPage = _withEntries(
  _replyPage.replaceFirst(
    _senderSpan,
    '${_span(202, '0')}${_span(203, '0')}'
    '$_senderSpan',
  ),
  '2',
  _span(204, '2'),
);

/// What Smartschool answers for a message ID the box does not hold: a page
/// without compose form.
const _noComposeForm =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head>'
    '<body><div id="content"></div>'
    '<input type="hidden" id="datepickerPlanner" value="1"></body></html>';

/// A Smartschool that answers the reply form (`composeType=1`) with
/// [replyPage] and the reply-all form (`composeType=2`) with [replyAllPage].
class _Smartschool implements HttpClientAdapter {
  _Smartschool({required this.replyPage, this.replyAllPage});

  final String replyPage;
  final String? replyAllPage;

  /// The query of every compose page request, in order.
  final List<Map<String, String>> composeRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'loading a form posts nothing');
    final query = options.uri.queryParameters;
    expect(query, containsPair('module', 'Messages'));
    expect(query, containsPair('file', 'composeMessage'));
    composeRequests.add(query);

    final page = switch (query['composeType']) {
      '1' => replyPage,
      '2' => replyAllPage,
      _ => null,
    };
    expect(page, isNotNull, reason: 'unexpected form: $query');
    return ResponseBody.fromString(
      page!,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

List<int> _ids(List<MessageSearchUser> users) =>
    users.map((u) => u.userId).toList();

void main() {
  forbidRealNetwork();

  group('MessagesService.getReplyRecipients (#24)', () {
    late Directory cacheDir;
    late SmartschoolClient client;

    Future<_Smartschool> serve(String replyPage, {String? replyAllPage}) async {
      final server = _Smartschool(
        replyPage: replyPage,
        replyAllPage: replyAllPage,
      );
      client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: cacheDir.path,
      );
      client.dio.httpClientAdapter = server;
      return server;
    }

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync('smartschool_reply_');
    });

    tearDown(() async {
      await client.dispose();
      cacheDir.deleteSync(recursive: true);
    });

    test('returns the sender of a received message from the reply form, '
        'ready for sendMessage', () async {
      final server = await serve(_replyPage);

      final (to, cc, bcc) = await MessagesService(
        client,
      ).getReplyRecipients(900030);

      expect(to, hasLength(1));
      final sender = to.single;
      expect(sender.userId, 201);
      expect(sender.displayName, 'Piet Peeters');
      expect(sender.ssId, 100);
      expect(sender.userLt, 0);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);

      final request = server.composeRequests.single;
      expect(request, containsPair('boxType', 'inbox'));
      expect(request, containsPair('composeType', '1'));
      expect(request, containsPair('msgID', '900030'));
    });

    test('names the sender that getReplyAllRecipients lists among the other '
        'To recipients', () async {
      final server = await serve(_replyPage, replyAllPage: _replyAllPage);
      final messages = MessagesService(client);

      final (allTo, allCc, _) = await messages.getReplyAllRecipients(900030);
      final (to, cc, bcc) = await messages.getReplyRecipients(900030);

      // Nothing in the reply-all To list says which entry is the sender.
      expect(_ids(allTo), [202, 203, 201]);
      expect(_ids(allCc), [204]);
      expect(_ids(to), [201]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);

      expect(server.composeRequests.map((q) => q['composeType']), ['2', '1']);
    });

    test('returns the user when the form names them as the sender: a sent '
        'message, or one they sent to themselves', () async {
      final server = await serve(_replyPageFromUser);
      final messages = MessagesService(client);

      final (sentTo, _, _) = await messages.getReplyRecipients(
        900031,
        boxType: BoxType.sent,
      );
      final (selfTo, _, _) = await messages.getReplyRecipients(900032);

      expect(_ids(sentTo), [777]);
      expect(sentTo.single.displayName, 'Jan Janssens');
      expect(_ids(selfTo), [777]);

      expect(server.composeRequests[0], containsPair('boxType', 'outbox'));
      expect(server.composeRequests[0], containsPair('composeType', '1'));
      expect(server.composeRequests[0], containsPair('msgID', '900031'));
      expect(server.composeRequests[1], containsPair('boxType', 'inbox'));
      expect(server.composeRequests[1], containsPair('msgID', '900032'));
    });

    test('returns the fields of the form as they are', () async {
      // Not seen live: a reply form with CC and BCC entries. They are read
      // with the field mapping of the reply-all form (#33).
      await serve(
        _withEntries(
          _withEntries(_replyPage, '2', _span(204, '2')),
          '3',
          _span(205, '3'),
        ),
      );

      final (to, cc, bcc) = await MessagesService(
        client,
      ).getReplyRecipients(900030);

      expect(_ids(to), [201]);
      expect(_ids(cc), [204]);
      expect(_ids(bcc), [205]);
    });

    test('returns no recipients when the box holds no such message', () async {
      await serve(_noComposeForm);

      final (to, cc, bcc) = await MessagesService(
        client,
      ).getReplyRecipients(900099);

      expect(to, isEmpty);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);
    });
  });
}
