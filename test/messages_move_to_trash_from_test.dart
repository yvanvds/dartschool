// Tests for issue #60: `MessagesService.moveToTrash` could not move the
// sent-box copy of a message the account sent to itself.
//
// Such a message has the same ID in the inbox and in the sent box, and
// `moveToTrash` sends Smartschool's `quick delete`, which names the ID only:
// seen live, it moved the inbox copy and left the sent-box copy. Calling it
// again was not safe either: the ID is in the trash then, and a `quick
// delete` of a message in the trash deletes it for good (#19).
//
// Smartschool's web client (the Messages module's main-built.js) moves a
// message of the inbox or the sent box to the trash, when it is dragged onto
// the trash, with `quickmove messages` and the box it is listed in:
// `boxType`, `boxID`, `msgID`, `toBoxType` `trash` and `toBoxID` `0`. The
// new `moveToTrashFrom(msgId, boxType: …)` sends that. Seen live
// (2026-10-01) on a message sent to the own account, with nothing of it in
// the trash: moving the sent-box copy put it in the trash and left the inbox
// copy in the inbox; moving the inbox copy then took it out of the inbox and
// left the sent-box copy in the trash. Smartschool answered both moves, and a
// move of ID 0 (no message, #61), with the same `silent` action:
// `quickmove messages.xml`.
//
// The fake Smartschool below records each XML command and answers it.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

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

/// Smartschool's answer to `quickmove messages`, as recorded live.
final _moveAnswer = File(
  'test/fixtures/smartschool/requests/post/postboxes/quickmove messages.xml',
).readAsStringSync();

/// An XML command as it reached the fake Smartschool.
typedef _Command = ({String path, String action, Map<String, String> params});

/// A Smartschool whose XML dispatcher answers every command with [answer]
/// (HTTP `200`, [contentType]).
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answer, {this.contentType = 'application/xml'});

  final String answer;
  final String contentType;

  /// Every command that reached it, in order.
  final List<_Command> commands = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'POST');
    final command = (options.data as Map)['command'] as String;
    expect(command, contains('<subsystem>postboxes</subsystem>'));
    commands.add((
      path: '${options.uri.path}?${options.uri.query}',
      action: RegExp(r'<action>(.*?)</action>').firstMatch(command)!.group(1)!,
      params: {
        for (final m in RegExp(
          r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
        ).allMatches(command))
          m.group(1)!: m.group(2)!,
      },
    ));
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<_Smartschool> serve(
    String answer, {
    String contentType = 'application/xml',
  }) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    final server = _Smartschool(answer, contentType: contentType);
    client.dio.httpClientAdapter = server;
    return server;
  }

  tearDown(() => client.dispose());

  group('moveToTrashFrom moves the copy of the box it names to the trash, '
      "as Smartschool's web client does (#60)", () {
    test('the sent-box copy: quickmove messages out of the outbox', () async {
      final server = await serve(_moveAnswer);

      await MessagesService(
        client,
      ).moveToTrashFrom(4242, boxType: BoxType.sent);

      expect(server.commands, hasLength(1));
      final command = server.commands.single;
      expect(command.path, '/?module=Messages&file=dispatcher');
      expect(command.action, 'quickmove messages');
      expect(command.params, {
        'boxType': 'outbox',
        'boxID': '0',
        'msgID': '4242',
        'toBoxType': 'trash',
        'toBoxID': '0',
      });
    });

    test('the inbox copy: quickmove messages out of the inbox', () async {
      final server = await serve(_moveAnswer);

      await MessagesService(
        client,
      ).moveToTrashFrom(4242, boxType: BoxType.inbox);

      expect(server.commands.single.action, 'quickmove messages');
      expect(server.commands.single.params, {
        'boxType': 'inbox',
        'boxID': '0',
        'msgID': '4242',
        'toBoxType': 'trash',
        'toBoxID': '0',
      });
    });

    test('a copy in a folder of the box, such as the archive', () async {
      final server = await serve(_moveAnswer);

      await MessagesService(
        client,
      ).moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 208);

      expect(server.commands.single.params, {
        'boxType': 'inbox',
        'boxID': '208',
        'msgID': '4242',
        'toBoxType': 'trash',
        'toBoxID': '0',
      });
    });

    test(
      'moveToTrash still sends a quick delete that names the ID only',
      () async {
        final server = await serve(_moveAnswer);

        await MessagesService(client).moveToTrash(4242);

        expect(server.commands.single.action, 'quick delete');
        expect(server.commands.single.params, {'msgID': '4242'});
      },
    );
  });

  group('moveToTrashFrom refuses, before any request, a box it cannot move a '
      'message to the trash from (#60)', () {
    for (final box in [BoxType.trash, BoxType.draft, BoxType.scheduled]) {
      test(box.name, () async {
        final server = await serve(_moveAnswer);

        await expectLater(
          MessagesService(client).moveToTrashFrom(4242, boxType: box),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'boxType'),
          ),
        );
        expect(server.commands, isEmpty);
      });
    }
  });

  group('moveToTrashFrom throws for an answer that is not XML (#60)', () {
    test('an HTML page', () async {
      await serve(
        '<!DOCTYPE html><html><body>login</body></html>',
        contentType: 'text/html',
      );

      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(isA<SmartschoolAuthenticationError>()),
      );
    });

    test('an empty answer', () async {
      await serve('', contentType: 'text/html');

      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(isA<SmartschoolParsingError>()),
      );
    });
  });
}
