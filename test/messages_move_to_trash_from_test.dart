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
// That answer says nothing about the move, so `moveToTrashFrom` checks it
// itself (#96): right after it, it sends `show message` for the message in
// the box it moved the copy out of, as `getMessage` does, and returns `true`
// for Smartschool's placeholder (the box holds no such message, #16), `false`
// for the message, and `null` for an answer that says neither. Seen live
// (2026-10-03), by the live suite, on messages sent to the own account: after
// the move of the sent-box copy, `show message` in the sent box answered with
// the placeholder and in the inbox with the message; after the move of the
// inbox copy, or of an archived one out of the archive folder, in the inbox
// with the placeholder; and in the trash with the message. The answer for a
// message moved to the trash (`show message moved to trash.xml`, asked in the
// inbox) is the placeholder, with the ID asked.
//
// Issue #115: when that check failed, `moveToTrashFrom` threw the check's
// error as it was, after the move went out: the same
// `SmartschoolSessionExpiredError`, `SmartschoolUnexpectedPageError` or
// `SmartschoolParsingError` as for a move that failed. A caller that sends a
// call again on a `SmartschoolSessionExpiredError` (as smartschool-mcp does)
// could not tell, and sent the move a second time for a message that may be
// in the trash already. Now a failed check is a
// `SmartschoolMoveUncheckedError` with the check's error as its cause, and
// the message, box and folder of the move; the move's own errors are thrown
// as before.
//
// The fake Smartschools below record each XML command and answer it; one of
// them refuses the session for the commands it is told to, also after the
// client logged in again.
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

String _fixture(String name) => File(
  'test/fixtures/smartschool/requests/post/postboxes/$name',
).readAsStringSync();

/// Smartschool's answer to `quickmove messages`, as recorded live.
final _moveAnswer = _fixture('quickmove messages.xml');

/// Smartschool's answer to `show message` in a box that holds no message
/// [id], as recorded live for a message moved to the trash out of the inbox
/// (#96): the placeholder, which echoes the ID asked.
String _gone(int id) => _fixture(
  'show message moved to trash.xml',
).replaceFirst('<id>6484136</id>', '<id>$id</id>');

/// Smartschool's answer to `show message` in a box that holds message [id].
String _held(int id) => _fixture(
  'show message.xml',
).replaceFirst('<id>123456</id>', '<id>$id</id>');

/// A `show message` answer whose `<data>` holds [data].
String _shown(String data) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>show message</subsystem><command>rebuild</command>'
    '<data>$data</data></action></actions></response></server>';

/// The `<message>` element of [_held], with [id] as the text of its `<id>`.
String _heldWithId(String id) {
  final held = _held(4242);
  final end = held.indexOf('</message>') + '</message>'.length;
  return held
      .substring(held.indexOf('<message>'), end)
      .replaceFirst('<id>4242</id>', '<id>$id</id>');
}

/// An XML command as it reached the fake Smartschool.
typedef _Command = ({String path, String action, Map<String, String> params});

/// The XML command that [options] posts to the dispatcher.
_Command _commandOf(RequestOptions options) {
  expect(options.method, 'POST');
  final command = (options.data as Map)['command'] as String;
  expect(command, contains('<subsystem>postboxes</subsystem>'));
  return (
    path: '${options.uri.path}?${options.uri.query}',
    action: RegExp(r'<action>(.*?)</action>').firstMatch(command)!.group(1)!,
    params: {
      for (final m in RegExp(
        r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
      ).allMatches(command))
        m.group(1)!: m.group(2)!,
    },
  );
}

ResponseBody _response(
  String body, {
  int status = 200,
  String contentType = 'text/html',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// A Smartschool whose XML dispatcher answers `show message` with [shown]
/// (HTTP `200`, [shownContentType]; by default the placeholder for message
/// `4242`) and every other command with [answer] (HTTP `200`,
/// [contentType]). With [shownUnreachable], the connection fails at the
/// `show message` instead, before an answer comes in.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    this.answer, {
    this.contentType = 'application/xml',
    String? shown,
    this.shownContentType = 'application/xml',
    this.shownUnreachable = false,
  }) : shown = shown ?? _gone(4242);

  final String answer;
  final String contentType;
  final String shown;
  final String shownContentType;
  final bool shownUnreachable;

  /// Every command that reached it, in order.
  final List<_Command> commands = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final command = _commandOf(options);
    commands.add(command);
    final show = command.action == 'show message';
    if (show && shownUnreachable) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection closed before full header was received',
        error: const SocketException('Connection reset by peer'),
      );
    }
    return _response(
      show ? shown : answer,
      contentType: show ? shownContentType : contentType,
    );
  }

  @override
  void close({bool force = false}) {}
}

const _loginPage = '''
<!DOCTYPE html>
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

/// A Smartschool on which the session expired (#115): it refuses every XML
/// command with a bare `401` and an empty body, as it refuses an XML POST on
/// such a session (#8), until the client logged in again (password and
/// 2FA). Then it answers `quickmove messages` with the recorded answer and
/// `show message` with the placeholder for message `4242`, except the
/// commands named in [refused]: those it refuses every time, also after the
/// client logged in again, and it drops the session with them, so that the
/// client logs in again from the start.
class _ExpiringSmartschool implements HttpClientAdapter {
  _ExpiringSmartschool({required this.refused});

  final Set<String> refused;

  bool _passwordDone = false;
  bool _twoFaDone = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = [];

  /// Every XML command that reached it, in order.
  final List<_Command> commands = [];

  /// The actions of [commands], in order.
  List<String> get actions => [for (final c in commands) c.action];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');

    if (options.method == 'POST' && path == '/login') {
      _passwordDone = true;
      final response = _response(
        '<html><body>Redirecting to /</body></html>',
        status: 302,
      );
      response.headers['location'] = ['/'];
      return response;
    }
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _twoFaDone = true;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }
    if (options.method == 'POST') {
      final command = _commandOf(options);
      commands.add(command);
      if (!_passwordDone || !_twoFaDone) return _response('', status: 401);
      if (refused.contains(command.action)) {
        _passwordDone = _twoFaDone = false;
        return _response('', status: 401);
      }
      return _response(
        command.action == 'show message' ? _gone(4242) : _moveAnswer,
        contentType: 'application/xml',
      );
    }

    // A page request: redirected to wherever the session is in the chain.
    final (at, page) = !_passwordDone
        ? ('/login', _loginPage)
        : !_twoFaDone
        ? ('/2fa', '<html><body>2fa</body></html>')
        : (path, '<html><body>home</body></html>');
    final response = _response(page);
    if (at != path) {
      response.redirects = [
        RedirectRecord(302, 'GET', Uri.parse('https://$_host$at')),
      ];
    }
    return response;
  }

  @override
  void close({bool force = false}) {}
}

/// Moves message [id] out of [box] to the trash as a caller does that sends
/// a call once more when Smartschool did not accept the session for it, as
/// smartschool-mcp does (yvanvds/smartschool-mcp, #115): the call is safe to
/// repeat then, as nothing was carried out.
Future<bool?> _moveRepeatingOnRefusedSession(
  MessagesService messages,
  int id,
  BoxType box,
) async {
  try {
    return await messages.moveToTrashFrom(id, boxType: box);
  } on SmartschoolSessionExpiredError {
    return messages.moveToTrashFrom(id, boxType: box);
  }
}

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<T> use<T extends HttpClientAdapter>(T server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  Future<_Smartschool> serve(
    String answer, {
    String contentType = 'application/xml',
    String? shown,
    String shownContentType = 'application/xml',
    bool shownUnreachable = false,
  }) => use(
    _Smartschool(
      answer,
      contentType: contentType,
      shown: shown,
      shownContentType: shownContentType,
      shownUnreachable: shownUnreachable,
    ),
  );

  tearDown(() => client.dispose());

  group('moveToTrashFrom moves the copy of the box it names to the trash, '
      "as Smartschool's web client does (#60)", () {
    test('the sent-box copy: quickmove messages out of the outbox', () async {
      final server = await serve(_moveAnswer);

      await MessagesService(
        client,
      ).moveToTrashFrom(4242, boxType: BoxType.sent);

      expect(server.commands.map((c) => c.action), [
        'quickmove messages',
        'show message',
      ]);
      final command = server.commands.first;
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

      expect(server.commands.first.action, 'quickmove messages');
      expect(server.commands.first.params, {
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

      expect(server.commands.first.action, 'quickmove messages');
      expect(server.commands.first.params, {
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
      final server = await serve(
        '<!DOCTYPE html><html><body>login</body></html>',
        contentType: 'text/html',
      );

      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(isA<SmartschoolAuthenticationError>()),
      );
      expect(server.commands.map((c) => c.action), [
        'quickmove messages',
      ], reason: 'a move that failed is not checked');
    });

    test('an empty answer', () async {
      final server = await serve('', contentType: 'text/html');

      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(isA<SmartschoolParsingError>()),
      );
      expect(server.commands.map((c) => c.action), [
        'quickmove messages',
      ], reason: 'a move that failed is not checked');
    });
  });

  group('moveToTrashFrom checks its move with show message in the box it '
      'moved the copy out of, and says whether that box still holds the '
      'message (#96)', () {
    for (final (box, boxId, value) in [
      (BoxType.sent, 0, 'outbox'),
      (BoxType.inbox, 0, 'inbox'),
      (BoxType.inbox, 208, 'inbox'),
    ]) {
      test('the check of a move out of the $value (folder $boxId) names the '
          'box and the message, and no folder, as getMessage does', () async {
        final server = await serve(_moveAnswer);

        await MessagesService(
          client,
        ).moveToTrashFrom(4242, boxType: box, boxId: boxId);

        expect(server.commands, hasLength(2));
        final check = server.commands.last;
        expect(check.path, '/?module=Messages&file=dispatcher');
        expect(check.action, 'show message');
        expect(check.params, {
          'msgID': '4242',
          'boxType': value,
          'limitList': 'true',
        });
      });
    }

    for (final (box, boxId) in [
      (BoxType.sent, 0),
      (BoxType.inbox, 0),
      (BoxType.inbox, 208),
    ]) {
      test('true: the ${box.value} (folder $boxId) answers with the '
          'placeholder, as the inbox did live for a message moved to the '
          'trash', () async {
        await serve(_moveAnswer, shown: _gone(4242));

        expect(
          await MessagesService(
            client,
          ).moveToTrashFrom(4242, boxType: box, boxId: boxId),
          isTrue,
        );
      });
    }

    test('false: the box answers with the message, which it still '
        'holds', () async {
      await serve(_moveAnswer, shown: _held(4242));

      expect(
        await MessagesService(
          client,
        ).moveToTrashFrom(4242, boxType: BoxType.sent),
        isFalse,
      );
    });

    test('false for the message with white space around its ID', () async {
      await serve(_moveAnswer, shown: _shown(_heldWithId(' 4242\n')));

      expect(
        await MessagesService(
          client,
        ).moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 208),
        isFalse,
      );
    });

    for (final (name, shown) in [
      ('no <message>', _shown('')),
      ('an empty <message />', _moveAnswer),
      ('no <data>', _moveAnswer.replaceFirst('<data><message /></data>', '')),
      ('the placeholder of another message', _gone(4343)),
      ('another message', _held(4343)),
      ('two messages', _shown(_heldWithId('4242') + _heldWithId('4242'))),
      (
        'a message without an <id>',
        _shown(_heldWithId('').replaceFirst('<id></id>', '')),
      ),
      ('a message with an empty <id>', _shown(_heldWithId(''))),
      ('a message with a non-numeric <id>', _shown(_heldWithId('4242a'))),
      ('a message with a hexadecimal <id>', _shown(_heldWithId('0x1092'))),
      (
        'a message with a repeated <id>',
        _shown(
          _heldWithId(
            '4242',
          ).replaceFirst('<id>4242</id>', '<id>4242</id><id>4242</id>'),
        ),
      ),
    ]) {
      test('null: an answer with $name says neither', () async {
        final server = await serve(_moveAnswer, shown: shown);

        expect(
          await MessagesService(
            client,
          ).moveToTrashFrom(4242, boxType: BoxType.sent),
          isNull,
        );
        expect(server.commands.map((c) => c.action), [
          'quickmove messages',
          'show message',
        ]);
      });
    }

    test('getMessage, which sends the same show message, returns null for '
        'the placeholder of a moved message, and the message for one the '
        'box holds', () async {
      await serve(_moveAnswer, shown: _gone(4242));
      expect(await MessagesService(client).getMessage(4242), isNull);
      await client.dispose();

      await serve(_moveAnswer, shown: _held(4242));
      final message = await MessagesService(client).getMessage(4242);
      expect(message?.id, 4242);
      expect(message?.subject, 'Griezelfestijn');
    });
  });

  group('moveToTrashFrom throws a SmartschoolMoveUncheckedError, with the '
      "check's error as its cause, when its check fails after the move went "
      "out, and the move's own error when the move fails (#115)", () {
    /// A [SmartschoolMoveUncheckedError] for the move of message `4242` out
    /// of [box] (folder [boxId]), with a [T] as its cause.
    Matcher unchecked<T>(BoxType box, {int boxId = 0}) =>
        isA<SmartschoolMoveUncheckedError>()
            .having((e) => e.msgId, 'msgId', 4242)
            .having((e) => e.boxType, 'boxType', box)
            .having((e) => e.boxId, 'boxId', boxId)
            .having((e) => e.cause, 'cause', isA<T>());

    /// What [call] throws, or `null` when it returns.
    Future<Object?> thrownBy(Future<Object?> call) =>
        call.then<Object?>((_) => null, onError: (Object e) => e);

    test('Smartschool refuses the session for the check, also after the '
        'client logged in again: not a SmartschoolSessionExpiredError, and '
        'the move is not sent again', () async {
      final server = await use(_ExpiringSmartschool(refused: {'show message'}));

      // Before the fix: the check's SmartschoolSessionExpiredError, the
      // same error as for a move that Smartschool refused.
      final error = await thrownBy(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.inbox),
      );

      expect(error, unchecked<SmartschoolSessionExpiredError>(BoxType.inbox));
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      // The move went out and was answered; the check was refused, logged
      // in again for, and refused again.
      expect(server.actions, [
        'quickmove messages', // refused: the session expired
        'quickmove messages', // after logging in: answered
        'show message', // refused, and the session dropped
        'show message', // after logging in again: refused again
      ]);
      expect(
        server.log.where((r) => r == 'POST /2fa/api/v1/google-authenticator'),
        hasLength(2),
      );
    });

    test('Smartschool refuses the session for the move, also after the '
        'client logged in again: a SmartschoolSessionExpiredError, and no '
        'check', () async {
      final server = await use(
        _ExpiringSmartschool(refused: {'quickmove messages'}),
      );

      final error = await thrownBy(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.inbox),
      );

      expect(error, isA<SmartschoolSessionExpiredError>());
      expect(server.actions, [
        'quickmove messages', // refused: the session expired
        'quickmove messages', // after logging in: refused again
      ], reason: 'a move that failed is not checked');
    });

    test('a caller that sends a call again when Smartschool did not accept '
        'the session for it does not send the move again when only the '
        'check was refused', () async {
      final server = await use(_ExpiringSmartschool(refused: {'show message'}));

      // Before the fix: the caller sent the move a second time, for a
      // message that may be in the trash already.
      final error = await thrownBy(
        _moveRepeatingOnRefusedSession(
          MessagesService(client),
          4242,
          BoxType.inbox,
        ),
      );

      expect(server.actions, [
        'quickmove messages', // refused: the session expired
        'quickmove messages', // after logging in: answered
        'show message',
        'show message',
      ]);
      expect(error, unchecked<SmartschoolSessionExpiredError>(BoxType.inbox));
    });

    test('... and sends it again when the move itself was refused', () async {
      final server = await use(
        _ExpiringSmartschool(refused: {'quickmove messages'}),
      );

      final error = await thrownBy(
        _moveRepeatingOnRefusedSession(
          MessagesService(client),
          4242,
          BoxType.inbox,
        ),
      );

      expect(error, isA<SmartschoolSessionExpiredError>());
      // Each call: refused, logged in again, refused again; never checked.
      expect(server.actions, List.filled(4, 'quickmove messages'));
    });

    test('a check answered with an HTML page', () async {
      final server = await serve(
        _moveAnswer,
        shown: '<!DOCTYPE html><html><body>login</body></html>',
        shownContentType: 'text/html',
      );

      // Before the fix: the check's SmartschoolUnexpectedPageError.
      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(unchecked<SmartschoolUnexpectedPageError>(BoxType.sent)),
      );
      expect(server.commands.map((c) => c.action), [
        'quickmove messages',
        'show message',
      ]);
    });

    test('a check answered with an empty body, after a move out of the '
        'archive folder', () async {
      await serve(_moveAnswer, shown: '', shownContentType: 'text/html');

      // Before the fix: the check's SmartschoolParsingError.
      await expectLater(
        MessagesService(
          client,
        ).moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 208),
        throwsA(unchecked<SmartschoolParsingError>(BoxType.inbox, boxId: 208)),
      );
    });

    test('a check whose connection fails before an answer comes in', () async {
      final server = await serve(_moveAnswer, shownUnreachable: true);

      // Before the fix: the check's SmartschoolConnectionError.
      await expectLater(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(unchecked<SmartschoolConnectionError>(BoxType.sent)),
      );
      expect(server.commands.map((c) => c.action), [
        'quickmove messages',
        'show message',
      ]);
    });

    test('its message says that the move went out, what the check failed '
        'with, and how to check the move', () async {
      await serve(
        _moveAnswer,
        shown: '<!DOCTYPE html><html><body>login</body></html>',
        shownContentType: 'text/html',
      );

      final error = await thrownBy(
        MessagesService(client).moveToTrashFrom(4242, boxType: BoxType.sent),
      );

      expect(error, isA<SmartschoolMoveUncheckedError>());
      final text = error.toString();
      expect(
        text,
        startsWith('SmartschoolMoveUncheckedError: moveToTrashFrom: '),
      );
      expect(text, contains('message 4242'));
      expect(text, contains('went out'));
      expect(text, contains('SmartschoolUnexpectedPageError'));
      expect(text, contains('getMessage(4242, boxType: BoxType.sent)'));
    });
  });
}
