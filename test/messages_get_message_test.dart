// Regression tests for issue #16: for a message id that the requested box
// does not hold, `MessagesService.getMessage` returned a made-up
// `FullMessage` (sender "Niet beschikbaar", subject "* Bericht zonder
// onderwerp *", dated 1970-01-01, unread) instead of `null` as documented.
//
// Smartschool does not leave the `<message>` element out for such an id; it
// answers with a placeholder. Verified live (read-only, `postboxes / show
// message`) for an unknown id (1 and 999999999, with `limitList` true and
// false) and for an id that is in another box (2 in `outbox`, an inbox
// message asked for in `trash`): a `200` whose `<message>` echoes the
// requested id, has the texts above, and has an empty `<status>`, `<unread>`,
// `<label>` and `<canReply>` and `<date>wrong input format</date>` (fixture
// `show message not found.xml`). A real message, in the inbox, the sent box
// and the drafts, has a `<status>` of `0` or `1` and a real date; a draft
// without a subject has the placeholder's subject too.
//
// The fake Smartschool below answers `show message` from canned XML; its
// names are made up.
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

String _fixture(String name) => File(
  'test/fixtures/smartschool/requests/post/postboxes/$name',
).readAsStringSync();

/// Smartschool's answer for an id the requested box does not hold: the
/// placeholder, with the requested id echoed back.
String _placeholder(Map<String, String> params) => _fixture(
  'show message not found.xml',
).replaceFirst('<id>999999999</id>', '<id>${params['msgID']}</id>');

/// A `show message` answer for a real message with [fields] as the children
/// of its `<message>` element.
String _message(String fields) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>show message</subsystem><command>rebuild</command>'
    '<data><message>$fields</message></data>'
    '</action></actions></response></server>';

/// A draft without a subject, body or recipients: it has the placeholder's
/// subject, but it is a message.
const _draftWithoutSubject =
    '<id>4242</id><from>Jan Janssens</from><to />'
    '<subject>* Bericht zonder onderwerp *</subject>'
    '<date>2026-08-31 13:59</date><body /><status>1</status>'
    '<attachment>0</attachment><unread>1</unread><label>0</label>'
    '<receivers /><ccreceivers /><bccreceivers />'
    '<senderPicture>initials_JJ</senderPicture><markedInLVS />'
    '<fromTeam>0</fromTeam><totalNrOtherToReciviers>0</totalNrOtherToReciviers>'
    '<totalnrOtherCcReceivers>0</totalnrOtherCcReceivers>'
    '<totalnrOtherBccReceivers>0</totalnrOtherBccReceivers>'
    '<canReply>1</canReply><hasReply>0</hasReply><hasForward>0</hasForward>'
    '<sendDate />';

/// A Smartschool whose XML dispatcher answers `show message` with [answer].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answer);

  final String Function(Map<String, String> params) answer;

  /// The params of every `show message` request, in order.
  final List<Map<String, String>> requests = [];

  static final _param = RegExp(
    r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final command = (options.data as Map)['command'] as String;
    expect(command, contains('<action>show message</action>'));
    final params = {
      for (final m in _param.allMatches(command)) m.group(1)!: m.group(2)!,
    };
    requests.add(params);
    return ResponseBody.fromString(
      answer(params),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(
    String Function(Map<String, String> params) answer,
  ) async {
    final server = _Smartschool(answer);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_message_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('getMessage returns null for the placeholder Smartschool answers '
      'with when the box has no such message (#16)', () {
    test('an unknown id', () async {
      final server = await serve(_placeholder);

      // Before the fix: FullMessage(id: 999999999, subject: "* Bericht
      // zonder onderwerp *"), sender "Niet beschikbaar", dated 1970-01-01.
      final message = await MessagesService(client).getMessage(999999999);

      expect(message, isNull);
      expect(server.requests.single, containsPair('msgID', '999999999'));
      expect(server.requests.single, containsPair('boxType', 'inbox'));
    });

    test('an id that is not in the given box', () async {
      final server = await serve(_placeholder);

      final message = await MessagesService(
        client,
      ).getMessage(2, boxType: BoxType.sent);

      expect(message, isNull);
      expect(server.requests.single, containsPair('msgID', '2'));
      expect(server.requests.single, containsPair('boxType', 'outbox'));
    });

    test('with includeAllRecipients', () async {
      final server = await serve(_placeholder);

      final message = await MessagesService(
        client,
      ).getMessage(1, includeAllRecipients: true);

      expect(message, isNull);
      expect(server.requests.single, containsPair('limitList', 'false'));
    });
  });

  group('getMessage still returns a message the box holds (#16)', () {
    test('a message', () async {
      await serve((_) => _fixture('show message.xml'));

      final message = await MessagesService(client).getMessage(123456);

      expect(message, isNotNull);
      expect(message!.id, 123456);
      expect(message.subject, 'Griezelfestijn');
      expect(message.date, DateTime(2023, 10, 8, 11, 56));
    });

    test('a draft with the placeholder\'s subject and no body or '
        'recipients', () async {
      await serve((_) => _message(_draftWithoutSubject));

      final message = await MessagesService(
        client,
      ).getMessage(4242, boxType: BoxType.draft);

      expect(message, isNotNull);
      expect(message!.id, 4242);
      expect(message.sender, 'Jan Janssens');
      expect(message.subject, '* Bericht zonder onderwerp *');
      expect(message.body, isEmpty);
      expect(message.receivers, isEmpty);
      expect(message.date, DateTime(2026, 8, 31, 13, 59));
    });

    test('a message with only one of the placeholder\'s gaps: no status, '
        'or no readable date', () async {
      final noStatus = _draftWithoutSubject.replaceFirst(
        '<status>1</status>',
        '<status />',
      );
      final noDate = _draftWithoutSubject.replaceFirst(
        '<date>2026-08-31 13:59</date>',
        '<date>wrong input format</date>',
      );

      final answers = {'1': noStatus, '2': noDate};
      await serve((params) => _message(answers[params['msgID']]!));
      final messages = MessagesService(client);

      expect(await messages.getMessage(1), isNotNull, reason: 'no status');
      expect(await messages.getMessage(2), isNotNull, reason: 'no date');
    });
  });
}
