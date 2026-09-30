// Regression tests for issue #27: `MessagesService.getSentMessageRecipients`
// returned no recipients for a message the user sent to themselves, and left
// the user out of the recipients of a message they sent to themselves and to
// others.
//
// The reply-all compose page of a sent message (`boxType=outbox&
// composeType=2`) fills the To field with the recipients and the user (the
// sender). It lists the user once, also when the user was a recipient too, so
// removing the user's entry, as the method did, removed a recipient. Verified
// live (read-only) on the 50 newest messages of a teacher's sent box: the
// five that came back empty were each sent to the user only (the page had
// one entry, the user's), and in two others the user was one of the To (12)
// or BCC (154) recipients and was missing from the result. In
// `show message` (`getMessage(id, boxType: BoxType.sent,
// includeAllRecipients: true)`) each recipient name of a sent message starts
// with `+` or `-`, so the user's own name there reads `-Jan Janssens`.
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

/// A Smartschool that answers the compose page with [composePage] and
/// `show message` with [showMessage].
class _Smartschool implements HttpClientAdapter {
  _Smartschool({required this.composePage, required this.showMessage});

  final String composePage;
  final String showMessage;

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
    showRequests.add({
      for (final m in _param.allMatches(command)) m.group(1)!: m.group(2)!,
    });
    return ResponseBody.fromString(
      showMessage,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A reply-all compose page of a sent message by user 777 (Jan Janssens)
/// with [spans] as its recipient entries.
String _composePage(String spans) => '''
<html><head><script>
window.tinymceInitConfig = { userID : '777', userLT : '0', ssID : '100' };
</script></head><body>$spans</body></html>''';

/// A recipient entry of the compose page; [type] is `0` (To), `2` (CC) or
/// `3` (BCC).
String _span(int userId, String name, {int type = 0}) =>
    '<div typeidatt="users" realuserid="$userId" idatt="U$userId" '
    'userltatt="0" typeatt="$type" ssidatt="100" name="receiverPart$type" '
    'class="receiverSpan user"><div class=\'receiverSpanName userm\'>$name'
    '</div></div>';

/// The `show message` answer for a sent message with recipient names [to],
/// [cc] and [bcc], each starting with the `+`/`-` marker of the sent box.
String _sentXml({
  List<String> to = const [],
  List<String> cc = const [],
  List<String> bcc = const [],
}) {
  String list(List<String> names) => names.map((n) => '<to>$n</to>').join();
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<server><response><status>ok</status><actions><action>'
      '<subsystem>show message</subsystem><command>rebuild</command>'
      '<data><message><id>900002</id><from>Jan Janssens</from><to />'
      '<subject>Onderwerp</subject><date>2026-09-30 10:00</date><body />'
      '<status>1</status><attachment>0</attachment><unread>0</unread>'
      '<label>0</label><receivers>${list(to)}</receivers>'
      '<ccreceivers>${list(cc)}</ccreceivers>'
      '<bccreceivers>${list(bcc)}</bccreceivers>'
      '<senderPicture>initials_JJ</senderPicture><fromTeam>0</fromTeam>'
      '<totalNrOtherToReciviers>0</totalNrOtherToReciviers>'
      '<totalnrOtherCcReceivers>0</totalnrOtherCcReceivers>'
      '<totalnrOtherBccReceivers>0</totalnrOtherBccReceivers>'
      '<canReply>1</canReply><hasReply>0</hasReply><hasForward>0</hasForward>'
      '<sendDate /></message></data></action></actions></response></server>';
}

/// The sent message of [_sentXml], parsed as `getMessage` parses it for the
/// sent box.
FullMessage _sent({
  List<String> to = const [],
  List<String> cc = const [],
  List<String> bcc = const [],
}) {
  final xml = Map<String, dynamic>.from(
    XmlInterface.parseResponse(
      _sentXml(to: to, cc: cc, bcc: bcc),
      './/data/message',
    ).single,
  );
  for (final field in ['receivers', 'ccreceivers', 'bccreceivers']) {
    final v = xml[field];
    if (v == null || (v is String && v.trim().isEmpty)) xml[field] = null;
  }
  return FullMessage.fromXml(xml, boxType: BoxType.sent);
}

List<int> _ids(List<MessageSearchUser> users) =>
    users.map((u) => u.userId).toList();

void main() {
  forbidRealNetwork();

  group('getSentMessageRecipients (#27)', () {
    late Directory cacheDir;
    late SmartschoolClient client;

    Future<_Smartschool> serve({
      required String composePage,
      required String showMessage,
    }) async {
      final server = _Smartschool(
        composePage: composePage,
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
      cacheDir = Directory.systemTemp.createTempSync('smartschool_sent_');
    });

    tearDown(() async {
      await client.dispose();
      cacheDir.deleteSync(recursive: true);
    });

    test(
      'returns the user for a message the user sent to themselves',
      () async {
        final server = await serve(
          composePage: _fixture('get/composemessage/sent-to-self.html'),
          showMessage: _fixture('post/postboxes/show message sent to self.xml'),
        );

        // Before the fix: ([], []).
        final (to, cc, bcc) = await MessagesService(
          client,
        ).getSentMessageRecipients(900001);

        expect(to, hasLength(1));
        expect(to.single.userId, 777);
        expect(to.single.displayName, 'Jan Janssens');
        expect(to.single.ssId, 100);
        expect(to.single.userLt, 0);
        expect(cc, isEmpty);
        expect(bcc, isEmpty);

        expect(
          server.composeRequests.single,
          containsPair('boxType', 'outbox'),
        );
        expect(server.composeRequests.single, containsPair('composeType', '2'));
        expect(server.composeRequests.single, containsPair('msgID', '900001'));
        expect(server.showRequests.single, containsPair('msgID', '900001'));
        expect(server.showRequests.single, containsPair('boxType', 'outbox'));
        expect(server.showRequests.single, containsPair('limitList', 'false'));
      },
    );

    test('still leaves out the user when they only sent the message', () async {
      await serve(
        composePage: _composePage(
          _span(201, 'Piet Peeters') + _span(777, 'Jan Janssens'),
        ),
        showMessage: _sentXml(to: ['+Piet Peeters']),
      );

      final (to, cc, bcc) = await MessagesService(
        client,
      ).getSentMessageRecipients(900003);

      expect(_ids(to), [201]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);
    });
  });

  group('parseSentMessageRecipients with the sent message (#27)', () {
    test('keeps the user who is one of the To recipients', () {
      final html = _composePage(
        _span(201, 'Piet Peeters') +
            _span(777, 'Jan Janssens') +
            _span(202, 'An Claes'),
      );
      final message = _sent(
        to: ['+Piet Peeters', '-Jan Janssens', '+An Claes'],
      );

      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: message,
      );

      expect(_ids(to), [201, 202, 777]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);
    });

    test('keeps the user who is one of the BCC recipients in the BCC list, '
        'with the other BCC recipients', () {
      // Live shape: the page lists the user in To (typeatt 0) and the
      // other BCC recipients in the BCC field (typeatt 3). Until #33 all
      // of them were returned in To.
      final html = _composePage(
        _span(777, 'Jan Janssens') +
            _span(201, 'Piet Peeters', type: 3) +
            _span(202, 'An Claes', type: 3),
      );
      final message = _sent(
        bcc: ['+Jan Janssens', '+Piet Peeters', '-An Claes'],
      );

      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: message,
      );

      expect(to, isEmpty);
      expect(cc, isEmpty);
      expect(_ids(bcc), [201, 202, 777]);
    });

    test('puts the user who is a CC recipient in the CC list', () {
      final html = _composePage(
        _span(201, 'Piet Peeters') +
            _span(777, 'Jan Janssens') +
            _span(301, 'Els Maes', type: 2),
      );
      final message = _sent(
        to: ['+Piet Peeters'],
        cc: ['+Els Maes', '+Jan Janssens'],
      );

      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: message,
      );

      expect(_ids(to), [201]);
      expect(_ids(cc), [301, 777]);
      expect(bcc, isEmpty);
    });

    test('does not take a namesake of the user for the user', () {
      // Another Jan Janssens (user 203) is the recipient; the user is not.
      final html = _composePage(
        _span(203, 'Jan Janssens') + _span(777, 'Jan Janssens'),
      );

      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: _sent(to: ['+Jan Janssens']),
      );

      expect(_ids(to), [203]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);

      // Both are recipients: the name is there twice.
      final (toBoth, _, _) = MessagesService.parseSentMessageRecipients(
        html,
        message: _sent(to: ['+Jan Janssens', '-Jan Janssens']),
      );

      expect(_ids(toBoth), [203, 777]);
    });

    test('reads recipient names with or without the +/- marker', () {
      final html = _composePage(_span(777, 'Jan Janssens'));

      for (final name in ['+Jan Janssens', '-Jan Janssens', 'Jan Janssens']) {
        final (to, _, _) = MessagesService.parseSentMessageRecipients(
          html,
          message: _sent(to: [name]),
        );
        expect(_ids(to), [777], reason: name);
      }
    });

    test('leaves out the user when the message does not name them', () {
      final html = _composePage(
        _span(201, 'Piet Peeters') + _span(777, 'Jan Janssens'),
      );

      final (to, cc, bcc) = MessagesService.parseSentMessageRecipients(
        html,
        message: _sent(to: ['+Piet Peeters']),
      );

      expect(_ids(to), [201]);
      expect(cc, isEmpty);
      expect(bcc, isEmpty);
    });
  });
}
