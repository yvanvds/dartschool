// Regression tests for issue #19: `MessagesService.moveToTrash` reported
// `isDeleted: false` for a message that it did move to the trash.
//
// `isDeleted` was read from the `<status>` of Smartschool's `finish quick
// delete` answer, but that `<status>` is the read state of the message (`0`
// unread, `1` read), as in every message list. Live (from
// yvanvds/smartschool-mcp, at bfd6258): three messages trashed from the
// inbox all left it for the trash, with `isDeleted` true for the read one and
// false for the two unread ones; a message trashed from the archive by the
// send lifecycle example (which does not read it) gave `msgID` the requested
// id, `boxType` `inbox` and `isDeleted` false. The
// raw answers were not captured (a second `quick delete` could delete a
// message for good), so `quick delete unread.xml` is the recorded
// `quick delete.xml` answer with the `<status>` of an unread message.
//
// Smartschool's web client (the Messages module's main-built.js) handles
// `finish quick delete` by removing the message from the list whatever the
// details say, and passes `0 === parseInt(status)` to its unread counter.
//
// The fake Smartschool below answers `quick delete` from canned XML.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
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

String _fixture(String name) => File(
  'test/fixtures/smartschool/requests/post/postboxes/$name',
).readAsStringSync();

/// An answer of Smartschool's XML dispatcher with one action.
String _answer(String action) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions>$action</actions>'
    '</response></server>';

/// A Smartschool whose XML dispatcher answers `quick delete` with [answer].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answer);

  final String answer;

  /// The params of every `quick delete` request, in order.
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
    expect(command, contains('<subsystem>postboxes</subsystem>'));
    expect(command, contains('<action>quick delete</action>'));
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

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<_Smartschool> serve(String answer) async {
    final server = _Smartschool(answer);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  tearDown(() => client.dispose());

  group('moveToTrash reports a message Smartschool moved to the trash as '
      'deleted (#19)', () {
    test('an unread message', () async {
      final server = await serve(_fixture('quick delete unread.xml'));

      // Before the fix: isDeleted false, read from `<status>0</status>`.
      final status = await MessagesService(client).moveToTrash(4242);

      expect(server.requests.single, {'msgID': '4242'});
      expect(status, isNotNull);
      expect(status!.isDeleted, isTrue);
      expect(status.msgId, 4242);
      expect(status.boxType, 'inbox');
      expect(status.unread, isTrue);
    });

    test('a read message', () async {
      await serve(_fixture('quick delete.xml'));

      final status = await MessagesService(client).moveToTrash(123);

      expect(status!.isDeleted, isTrue);
      expect(status.msgId, 123);
      expect(status.unread, isFalse);
    });

    test('a `finish quick delete` without a read state', () async {
      await serve(
        _fixture(
          'quick delete.xml',
        ).replaceFirst('<status>1</status>', '<status></status>'),
      );

      final status = await MessagesService(client).moveToTrash(123);

      expect(status!.isDeleted, isTrue);
      expect(status.unread, isNull);
    });
  });

  group('moveToTrash returns null when Smartschool does not answer with '
      '`finish quick delete` (#19)', () {
    test('another action, with details', () async {
      await serve(
        _answer(
          '<action><subsystem>message list</subsystem>'
          '<command>something else</command><data><details>'
          '<msgID>123</msgID><boxType>inbox</boxType><status>1</status>'
          '</details></data></action>',
        ),
      );

      expect(await MessagesService(client).moveToTrash(123), isNull);
    });

    test('no action', () async {
      await serve(_answer(''));

      expect(await MessagesService(client).moveToTrash(123), isNull);
    });
  });
}
