// Regression tests for issue #33: `MessagesService.getSentMessageRecipients`
// returned the BCC recipients of a sent message in its To list. The result
// was a `(to, cc)` record, so a caller could not tell them apart from the To
// recipients, and a reply-all built from it would name them openly.
//
// The reply-all compose page of a sent message (`boxType=outbox&
// composeType=2`) has a container per recipient field, and each recipient
// entry's `typeatt` is its field's `droppedtype`: To 0, CC 2, BCC 3, and
// for co-accounts To 1, CC 4, BCC 5. `parseReplyAllRecipients` read only
// `2` (CC) and put every other entry in To. Verified live (read-only) on the
// 50 newest messages of a teacher's sent box: two were sent to BCC
// recipients only, 25 and 154; their pages list the BCC recipients with
// `typeatt="3"` in the BCC field and the user once, in the To field, also
// the message whose BCC recipients include the user; the names of the
// `typeatt="3"` entries are the message's `bccReceivers` (without the user);
// and `getSentMessageRecipients` returned all of them, the user included, in
// To. The other messages used typeatt 0, 1 and 2 only.
//
// The fake Smartschool below answers the compose page and `show message`
// from canned fixtures; its names and IDs are made up.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
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

/// The reply-all compose page of sent message 900020 by user 777 (Jan
/// Janssens), whose recipients were all in BCC: Piet Peeters (201), An
/// Claes (202), Els Maes (203) and, in [_sentBccWithUser], the user.
final _composePage = _fixture('get/composemessage/sent-bcc.html');

/// `show message` of sent message 900020: BCC Piet Peeters, An Claes, Jan
/// Janssens (the user) and Els Maes.
final _sentBccWithUser = _fixture('post/postboxes/show message sent bcc.xml');

/// The same message without the user among its BCC recipients.
final _sentBccWithoutUser = _sentBccWithUser.replaceFirst(
  '<to>+Jan Janssens</to>',
  '',
);

/// A Smartschool that answers the compose page with [composePage] and
/// `show message` with [showMessage].
class _Smartschool implements HttpClientAdapter {
  _Smartschool({required this.composePage, this.showMessage});

  final String composePage;
  final String? showMessage;

  /// The query of every compose page request, in order.
  final List<Map<String, String>> composeRequests = [];

  /// The params of every `show message` request, in order.
  final List<Map<String, String>> showRequests = [];

  static final _param = RegExp(
    r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      final query = options.uri.queryParameters;
      expect(query, containsPair('file', 'composeMessage'));
      composeRequests.add(query);
      return ResponseBody.fromString(
        composePage,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }

    final command = (options.data as Map)['command'] as String;
    expect(command, contains('<action>show message</action>'));
    expect(showMessage, isNotNull, reason: 'no show message expected');
    showRequests.add({
      for (final m in _param.allMatches(command)) m.group(1)!: m.group(2)!,
    });
    return ResponseBody.fromString(
      showMessage!,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

List<int> _ids(List<MessageSearchUser> users) =>
    users.map((u) => u.userId).toList();

/// A compose page entry of user [userId] in the field with `typeatt`
/// [type].
String _span(int userId, String type) =>
    '<div typeidatt="users" realuserid="$userId" idatt="U$userId" '
    'userltatt="0" typeatt="$type" ssidatt="100" name="receiverPart$type" '
    'class="receiverSpan user"><div class=\'receiverSpanName userm\'>'
    'User $userId</div></div>';

void main() {
  forbidRealNetwork();

  group('MessagesService with a sent message to BCC recipients (#33)', () {
    late Directory cacheDir;
    late SmartschoolClient client;

    Future<_Smartschool> serve({String? showMessage}) async {
      final server = _Smartschool(
        composePage: _composePage,
        showMessage: showMessage,
      );
      client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: cacheDir.path,
      );
      client.dio.httpClientAdapter = server;
      return server;
    }

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync('smartschool_bcc_');
    });

    tearDown(() async {
      await client.dispose();
      cacheDir.deleteSync(recursive: true);
    });

    test('getSentMessageRecipients returns the BCC recipients as BCC, '
        'not To', () async {
      final server = await serve(showMessage: _sentBccWithoutUser);

      // Before the fix: to held 201, 202 and 203.
      final (to, cc, bcc) = await MessagesService(
        client,
      ).getSentMessageRecipients(900020);

      expect(to, isEmpty);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 203]);
      expect(bcc.map((u) => u.displayName), [
        'Piet Peeters',
        'An Claes',
        'Els Maes',
      ]);
      expect(bcc.map((u) => u.ssId), everyElement(100));
      expect(bcc.map((u) => u.userLt), everyElement(0));

      expect(server.composeRequests.single, containsPair('boxType', 'outbox'));
      expect(server.composeRequests.single, containsPair('composeType', '2'));
      expect(server.composeRequests.single, containsPair('msgID', '900020'));
      expect(server.showRequests.single, containsPair('msgID', '900020'));
      expect(server.showRequests.single, containsPair('boxType', 'outbox'));
    });

    test('getSentMessageRecipients returns the user who is one of the BCC '
        'recipients as BCC', () async {
      // The page lists the user in To either way; the message's BCC
      // recipient names include the user.
      await serve(showMessage: _sentBccWithUser);

      // Before the fix: to held 201, 202, 203 and 777.
      final (to, cc, bcc) = await MessagesService(
        client,
      ).getSentMessageRecipients(900020);

      expect(to, isEmpty);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 203, 777]);
    });

    test('getReplyAllRecipients on the sent box returns the BCC field as '
        'BCC', () async {
      final server = await serve();

      final (to, cc, bcc) = await MessagesService(
        client,
      ).getReplyAllRecipients(900020, boxType: BoxType.sent);

      // The page as it is: the user in To, the recipients in BCC.
      expect(_ids(to), [777]);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 203]);

      expect(server.composeRequests.single, containsPair('boxType', 'outbox'));
      expect(server.composeRequests.single, containsPair('composeType', '2'));
      expect(server.showRequests, isEmpty);
    });
  });

  group('parseReplyAllRecipients reads the field of each entry (#33)', () {
    test('To, CC and BCC, also for co-accounts', () {
      final html =
          '<html><body>'
          '${_span(1, '0')}${_span(2, '2')}${_span(3, '3')}'
          '${_span(4, '1')}${_span(5, '4')}${_span(6, '5')}'
          '</body></html>';

      final (to, cc, bcc) = MessagesService.parseReplyAllRecipients(html);

      expect(_ids(to), [1, 4]);
      expect(_ids(cc), [2, 5]);
      expect(_ids(bcc), [3, 6]);
    });

    test('an entry with another or no typeatt is a To recipient', () {
      final html =
          '<html><body>${_span(1, '9')}'
          '<div class="receiverSpan" realuserid="2" ssidatt="100">'
          '<div class="receiverSpanName">User 2</div></div>'
          '</body></html>';

      final (to, cc, bcc) = MessagesService.parseReplyAllRecipients(html);

      expect(_ids(to), [1, 2]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);
    });
  });

  group('parseSentMessageRecipients with BCC recipients (#33)', () {
    test('without the sent message, the user is left out and the BCC '
        'recipients stay BCC', () {
      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        _composePage,
      );

      expect(to, isEmpty);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 203]);
    });

    test('a user named in To and in BCC is kept in each', () {
      final html = _composePage.replaceFirst(
        '<div class="insertSearchField" name="insertSearchFieldContainer0"',
        '${_span(204, '0')}'
            '<div class="insertSearchField" name="insertSearchFieldContainer0"',
      );
      final xml = _sentBccWithUser.replaceFirst(
        '<receivers />',
        '<receivers><to>+User 204</to><to>-Jan Janssens</to></receivers>',
      );
      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: _sent(xml),
      );

      expect(_ids(to), [204, 777]);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 203, 777]);
    });
  });
}

/// The sent message of the `show message` answer [xml], parsed as
/// `getMessage` parses it for the sent box.
FullMessage _sent(String xml) {
  final message = Map<String, dynamic>.from(
    XmlInterface.parseResponse(xml, './/data/message').single,
  );
  for (final field in ['receivers', 'ccreceivers', 'bccreceivers']) {
    final v = message[field];
    if (v == null || (v is String && v.trim().isEmpty)) message[field] = null;
  }
  return FullMessage.fromXml(message, boxType: BoxType.sent);
}
