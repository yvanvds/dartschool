// Tests for issue #34: for a message in the sent box, every recipient name
// that `getMessage` returned in `FullMessage.receivers`, `ccReceivers` and
// `bccReceivers` started with an undocumented `+` or `-`, so the names
// matched no other display name (the user's own, `ShortMessage.sender`, the
// names of `getSentMessageRecipients`).
//
// The marker is the recipient's read state. Smartschool's own web client
// (`modules/Messages/dist/main-built.js`) removes a leading `+` or `-` from
// each To, CC and BCC name when it shows a message of the sent box
// (`boxType` `outbox`, or a search result) and gives the `-` names the class
// `userNotRead`; in other boxes it shows the names as they are. Verified live
// (read-only) on the 150 newest messages of a teacher's sent box: all 726
// recipient names start with `+` or `-`; 13 of those messages name the user
// among their recipients, and for each the user's marker matches the read
// state of the user's own copy of the message, in the inbox, archive or
// trash (`+` read: 10, `-` unread: 3); and `-` is 45% of the names on
// messages sent in the last day, at most 2.5% on older ones.
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

/// A sent message by Jan Janssens to Piet Peeters (read) and An Claes (not
/// read), CC Els Maes (not read), BCC Tom Wouters (read) and Jan Janssens
/// himself (not read).
final _sentMessage = _fixture('show message sent.xml');

/// A Smartschool whose XML dispatcher answers `show message` with [answer].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answer);

  final String answer;

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
    requests.add({
      for (final m in _param.allMatches(command)) m.group(1)!: m.group(2)!,
    });
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

MessageRecipient _read(String name) =>
    MessageRecipient(name: name, hasRead: true);

MessageRecipient _unread(String name) =>
    MessageRecipient(name: name, hasRead: false);

MessageRecipient _unknown(String name) => MessageRecipient(name: name);

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(String answer) async {
    final server = _Smartschool(answer);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_read_state_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('getMessage on the sent box reads the +/- marker (#34)', () {
    test('the recipient names come without the marker', () async {
      final server = await serve(_sentMessage);

      final message = await MessagesService(
        client,
      ).getMessage(900010, boxType: BoxType.sent, includeAllRecipients: true);

      // Before: ['+Piet Peeters', '-An Claes'], ['-Els Maes'] and
      // ['+Tom Wouters', '-Jan Janssens'].
      expect(message!.receivers, ['Piet Peeters', 'An Claes']);
      expect(message.ccReceivers, ['Els Maes']);
      expect(message.bccReceivers, ['Tom Wouters', 'Jan Janssens']);

      expect(server.requests.single, containsPair('msgID', '900010'));
      expect(server.requests.single, containsPair('boxType', 'outbox'));
      expect(server.requests.single, containsPair('limitList', 'false'));
    });

    test('the recipients say who has read the message', () async {
      await serve(_sentMessage);

      final message = await MessagesService(
        client,
      ).getMessage(900010, boxType: BoxType.sent, includeAllRecipients: true);

      expect(message!.toRecipients, [
        _read('Piet Peeters'),
        _unread('An Claes'),
      ]);
      expect(message.ccRecipients, [_unread('Els Maes')]);
      expect(message.bccRecipients, [
        _read('Tom Wouters'),
        _unread('Jan Janssens'),
      ]);
    });

    test('also for the shortened recipient lists', () async {
      final server = await serve(
        _sentMessage.replaceFirst(
          '<totalNrOtherToReciviers>0</totalNrOtherToReciviers>',
          '<totalNrOtherToReciviers>3</totalNrOtherToReciviers>',
        ),
      );

      final message = await MessagesService(
        client,
      ).getMessage(900010, boxType: BoxType.sent);

      expect(message!.receivers, ['Piet Peeters', 'An Claes']);
      expect(message.toRecipients, [
        _read('Piet Peeters'),
        _unread('An Claes'),
      ]);
      expect(message.totalNrOtherToReceivers, 3);
      expect(server.requests.single, containsPair('limitList', 'true'));
    });

    test('only the first character is a marker; a name without one is '
        'kept, with an unknown read state', () async {
      await serve(
        _sentMessage
            .replaceFirst('<to>+Piet Peeters</to>', '<to>Piet Peeters</to>')
            .replaceFirst('<to>-An Claes</to>', '<to>--An Claes-Maes</to>'),
      );

      final message = await MessagesService(
        client,
      ).getMessage(900010, boxType: BoxType.sent, includeAllRecipients: true);

      expect(message!.receivers, ['Piet Peeters', '-An Claes-Maes']);
      expect(message.toRecipients, [
        _unknown('Piet Peeters'),
        _unread('-An Claes-Maes'),
      ]);
    });
  });

  group('getMessage on another box keeps the names as they are (#34)', () {
    test(
      'an inbox message: the read state of its recipients is unknown',
      () async {
        await serve(_fixture('show message all recipients.xml'));

        final message = await MessagesService(
          client,
        ).getMessage(789012, includeAllRecipients: true);

        expect(message!.receivers, ['Student A', 'Student B', 'Student C']);
        expect(message.toRecipients, [
          _unknown('Student A'),
          _unknown('Student B'),
          _unknown('Student C'),
        ]);
        expect(message.ccRecipients, [
          _unknown('Parent X'),
          _unknown('Parent Y'),
        ]);
        expect(message.bccRecipients, isEmpty);
      },
    );

    test('a leading + or - is not read as a marker outside the sent box, '
        'as in Smartschool\'s web client', () async {
      await serve(_sentMessage);

      final message = await MessagesService(
        client,
      ).getMessage(900010, boxType: BoxType.trash, includeAllRecipients: true);

      expect(message!.receivers, ['+Piet Peeters', '-An Claes']);
      expect(message.toRecipients, [
        _unknown('+Piet Peeters'),
        _unknown('-An Claes'),
      ]);
    });
  });

  group('MessageRecipient', () {
    test('fromSentBoxName reads the marker', () {
      expect(
        MessageRecipient.fromSentBoxName('+Piet Peeters'),
        _read('Piet Peeters'),
      );
      expect(
        MessageRecipient.fromSentBoxName('-Piet Peeters'),
        _unread('Piet Peeters'),
      );
      expect(
        MessageRecipient.fromSentBoxName('Piet Peeters'),
        _unknown('Piet Peeters'),
      );
      expect(MessageRecipient.fromSentBoxName(''), _unknown(''));
    });

    test('equality and toString', () {
      expect(_read('Els Maes'), _read('Els Maes'));
      expect(_read('Els Maes').hashCode, _read('Els Maes').hashCode);
      expect(_read('Els Maes'), isNot(_unread('Els Maes')));
      expect(_read('Els Maes'), isNot(_unknown('Els Maes')));
      expect(_read('Els Maes'), isNot(_read('An Claes')));
      expect(
        _unread('Els Maes').toString(),
        'MessageRecipient(name: "Els Maes", hasRead: false)',
      );
    });
  });

  test('a FullMessage constructed without recipients derives them from the '
      'names, with an unknown read state', () {
    final message = FullMessage(
      id: 1,
      subject: 'Onderwerp',
      date: DateTime(2026, 9, 30),
      body: '',
      status: 1,
      attachment: 0,
      unread: false,
      receivers: const ['Piet Peeters'],
      ccReceivers: const ['Els Maes'],
      bccReceivers: const [],
      senderPicture: '',
      fromTeam: 0,
      totalNrOtherToReceivers: 0,
      totalNrOtherCcReceivers: 0,
      totalNrOtherBccReceivers: 0,
      canReply: true,
      hasReply: false,
      hasForward: false,
      sender: 'Jan Janssens',
    );

    expect(message.toRecipients, [_unknown('Piet Peeters')]);
    expect(message.ccRecipients, [_unknown('Els Maes')]);
    expect(message.bccRecipients, isEmpty);
  });
}
