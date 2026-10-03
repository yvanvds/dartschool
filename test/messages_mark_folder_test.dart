// Tests for issue #94: `markRead` and `setLabel` name no folder of the box,
// where `markUnread` does (its `boxId`). Whether Smartschool then finds a
// message in a folder, such as the archive (folder 208 of the inbox), had
// not been seen.
//
// Smartschool's web client (the Messages module's main-built.js) sends the
// same requests as the library:
// - `mark message read`, when it opens an unread message, with `msgID`,
//   `boxType` and `limitList` only, also in the archive (its box there is
//   `inbox` with box ID `208`, which it does not send);
// - `save msglabel`, from the flag buttons of the message list and of an
//   opened message, with `boxType`, `msgLabel`, `msgID` (and `clAction` from
//   the list) only;
// - `mark message unread` with `boxType`, `boxID`, `msgID` and `clAction`:
//   the only one of the three that names the folder.
//
// Tried live (2026-10-03) by the live suite's scenario of #94
// (test/live/messages_live_test.dart), on a message sent to the own account
// and moved to the archive: `markUnread(id, boxId: 208)`, then `markRead(id)`,
// `setLabel(id, MessageLabel.redFlag)` and `setLabel(id, MessageLabel.noFlag)`.
// Smartschool answered each with the message's ID and its new state (below),
// and the archive listed it after each with that state, still in the archive.
// So nothing changes in the library: these tests keep the requests as the
// web client sends them and as they were tried.
//
// Issue #95: the three calls read their answer's `<message>` with
// `MessageChanged.fromXml`, which read a missing, empty or non-numeric
// `<id>`, `<status>` or `<label>` as `0`: for `markUnread` and for
// `setLabel(..., MessageLabel.noFlag)` the very state asked for, so a caller
// (smartschool-mcp's mark and flag tools) took such an answer as confirmed.
// And it read the `<status>` (the read state) when an answer held both, also
// for `setLabel`. The calls now return `null` for such an answer, as for one
// without a `<message>`; the mark calls read the `<status>` only and
// `setLabel` the `<label>` only. The fake below answers as the live run did
// unless a test gives it another answer.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

/// The archive folder of the inbox, as Smartschool's Messages page named it
/// in the live run.
const _archive = 208;

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

/// Smartschool's answer to a change of message 4242, as it answered the
/// changes of the archived message of the live run (2026-10-03, its ID
/// replaced): [kind] `status` with the new read state, or `label` with the
/// new flag, as its `<command>` and the element that holds [value].
String _answer(String kind, int value) =>
    _answerWith(kind, '<id>4242</id><$kind>$value</$kind>');

/// Smartschool's answer of [kind] (`status` or `label`) to a change of a
/// message, with [message] as the content of its `<message>`.
String _answerWith(String kind, String message) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>message list</subsystem><command>$kind</command>'
    '<data><message>$message</message></data>'
    '</action></actions></response></server>';

/// An XML command as it reached the fake Smartschool.
typedef _Command = ({String action, Map<String, String> params});

/// A Smartschool whose XML dispatcher answers `mark message read`, `mark
/// message unread` and `save msglabel` as the live one did, or with
/// [answer] when a test sets it, and records each command.
class _Smartschool implements HttpClientAdapter {
  /// Every command that reached it, in order.
  final List<_Command> commands = [];

  /// The answer to every command, instead of the live run's, when set.
  String? answer;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'POST');
    expect(
      '${options.uri.path}?${options.uri.query}',
      '/?module=Messages&file=dispatcher',
    );
    final command = (options.data as Map)['command'] as String;
    expect(command, contains('<subsystem>postboxes</subsystem>'));
    final params = {
      for (final m in RegExp(
        r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
      ).allMatches(command))
        m.group(1)!: m.group(2)!,
    };
    final action = RegExp(
      r'<action>(.*?)</action>',
    ).firstMatch(command)!.group(1)!;
    commands.add((action: action, params: params));
    final body =
        answer ??
        switch (action) {
          'mark message read' => _answer('status', 1),
          'mark message unread' => _answer('status', 0),
          'save msglabel' => _answer('label', int.parse(params['msgLabel']!)),
          _ => throw StateError('unexpected command $action'),
        };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;
  late _Smartschool server;
  late MessagesService messages;

  setUp(() async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    server = _Smartschool();
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
  });

  tearDown(() => client.dispose());

  group('a message in the archive folder, as the live run changed it and as '
      "Smartschool's web client sends it (#94)", () {
    test('markUnread names the archive folder (boxID)', () async {
      final changed = await messages.markUnread(4242, boxId: _archive);

      expect(server.commands.single.action, 'mark message unread');
      expect(server.commands.single.params, {
        'boxType': 'inbox',
        'boxID': '$_archive',
        'msgID': '4242',
        'clAction': 'status',
      });
      expect((changed?.id, changed?.newValue), (4242, 0));
    });

    test('markRead names no folder: no boxID', () async {
      final changed = await messages.markRead(4242);

      expect(server.commands.single.action, 'mark message read');
      expect(server.commands.single.params, {
        'msgID': '4242',
        'boxType': 'inbox',
        'limitList': 'true',
      });
      expect((changed?.id, changed?.newValue), (4242, 1));
    });

    test('setLabel names no folder: no boxID, to flag and to clear', () async {
      final flagged = await messages.setLabel(4242, MessageLabel.redFlag);
      final cleared = await messages.setLabel(4242, MessageLabel.noFlag);

      expect(server.commands.map((c) => c.action), [
        'save msglabel',
        'save msglabel',
      ]);
      expect(server.commands.map((c) => c.params), [
        {
          'boxType': 'inbox',
          'msgLabel': '3',
          'msgID': '4242',
          'clAction': 'label',
        },
        {
          'boxType': 'inbox',
          'msgLabel': '0',
          'msgID': '4242',
          'clAction': 'label',
        },
      ]);
      expect((flagged?.id, flagged?.newValue), (4242, 3));
      expect((cleared?.id, cleared?.newValue), (4242, 0));
    });
  });

  group('an answer that confirms no state (#95)', () {
    // The content of the answer's `<message>`, with `$kind` for its kind:
    // `status` for the mark calls, `label` for setLabel.
    const unusable = {
      'no state': '<id>4242</id>',
      'an empty state': r'<id>4242</id><$kind/>',
      'a state that is not a number': r'<id>4242</id><$kind>none</$kind>',
      'no ID': r'<$kind>0</$kind>',
      'an empty ID': r'<id/><$kind>0</$kind>',
    };

    for (final MapEntry(key: what, value: message) in unusable.entries) {
      test('markRead, markUnread and setLabel return null for $what', () async {
        String answerOf(String kind) =>
            _answerWith(kind, message.replaceAll(r'$kind', kind));

        server.answer = answerOf('status');
        final read = await messages.markRead(4242);
        final unread = await messages.markUnread(4242, boxId: _archive);
        server.answer = answerOf('label');
        final cleared = await messages.setLabel(4242, MessageLabel.noFlag);

        expect(server.commands.map((c) => c.action), [
          'mark message read',
          'mark message unread',
          'save msglabel',
        ]);
        expect(read, isNull, reason: 'markRead');
        expect(unread, isNull, reason: 'markUnread: no confirmed unread');
        expect(cleared, isNull, reason: 'setLabel: no confirmed "no flag"');
      });
    }

    test(
      'markUnread returns null for a label alone: it is no read state',
      () async {
        server.answer = _answerWith('status', '<id>4242</id><label>0</label>');

        expect(await messages.markUnread(4242), isNull);
      },
    );

    test('setLabel returns null for a status alone: it is no flag', () async {
      server.answer = _answerWith('label', '<id>4242</id><status>0</status>');

      expect(await messages.setLabel(4242, MessageLabel.noFlag), isNull);
    });

    test('with both a status and a label, setLabel reads the label and the '
        'mark calls the status', () async {
      server.answer = _answerWith(
        'label',
        '<id>4242</id><status>1</status><label>0</label>',
      );
      final cleared = await messages.setLabel(4242, MessageLabel.noFlag);
      server.answer = _answerWith(
        'status',
        '<id>4242</id><status>0</status><label>3</label>',
      );
      final unread = await messages.markUnread(4242);

      expect((cleared?.id, cleared?.newValue), (4242, 0));
      expect((unread?.id, unread?.newValue), (4242, 0));
    });

    test('an answer without a <message> still returns null', () async {
      server.answer =
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
          '<server><response><status>ok</status><actions/></response>'
          '</server>';

      expect(await messages.markRead(4242), isNull);
      expect(await messages.setLabel(4242, MessageLabel.redFlag), isNull);
    });
  });
}
