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
// And for issue #59: `moveToTrash` threw a `SmartschoolParsingError` ("a
// non-XML response") when Smartschool deleted nothing, instead of returning
// `null`. Seen live by the live suite of #57 (`moveToTrash(0)`, ID 0 names no
// message): Smartschool answered that `quick delete` with an empty body (not
// always: a `quick delete` is never a guaranteed no-op, #61). An empty body
// is also how Smartschool refuses the session of an XML POST, with a `401`
// (#8), so only an empty `200` means that nothing was deleted.
//
// The fake Smartschool below answers `quick delete` from canned XML.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
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

/// A Smartschool whose XML dispatcher answers `quick delete` with [answer],
/// with HTTP [status] and [contentType].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    this.answer, {
    this.status = 200,
    this.contentType = 'application/xml',
  });

  final String answer;
  final int status;
  final String contentType;

  /// The params of every `quick delete` request, in order.
  final List<Map<String, String>> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_quickDeleteParams(options));
    return _response(answer, status: status, contentType: contentType);
  }

  @override
  void close({bool force = false}) {}
}

/// The params of the `quick delete` command that [options] posts.
Map<String, String> _quickDeleteParams(RequestOptions options) {
  final command = (options.data as Map)['command'] as String;
  expect(command, contains('<subsystem>postboxes</subsystem>'));
  expect(command, contains('<action>quick delete</action>'));
  return {
    for (final m in RegExp(
      r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
    ).allMatches(command))
      m.group(1)!: m.group(2)!,
  };
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

/// A Smartschool on which the session expired: it refuses the `quick delete`
/// with a bare `401` and an empty body, as it refuses every XML POST on such
/// a session (#8), until the client logged in again (password and 2FA). Then
/// it answers it with [afterLogin], or refuses it again when that is `null`.
class _ExpiredSession implements HttpClientAdapter {
  _ExpiredSession({required this.afterLogin});

  final String? afterLogin;

  bool _passwordDone = false;
  bool _twoFaDone = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = [];

  /// The params of every `quick delete` request, in order.
  final List<Map<String, String>> requests = [];

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
      return ResponseBody.fromString(
        '<html><body>Redirecting to /</body></html>',
        302,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
          'location': ['/'],
        },
      );
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
      requests.add(_quickDeleteParams(options));
      final answer = afterLogin;
      if (!_passwordDone || !_twoFaDone || answer == null) {
        return _response('', status: 401);
      }
      return _response(answer, contentType: 'application/xml');
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
    int status = 200,
    String contentType = 'application/xml',
  }) => use(_Smartschool(answer, status: status, contentType: contentType));

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

  group('moveToTrash returns null when Smartschool deletes nothing: an empty '
      'answer (#59)', () {
    test('an empty answer', () async {
      final server = await serve('', contentType: 'text/html');

      // Before the fix: SmartschoolParsingError ("non-XML response").
      final status = await MessagesService(client).moveToTrash(0);

      expect(status, isNull);
      expect(server.requests.single, {'msgID': '0'});
    });

    test('an answer of white space only', () async {
      await serve(' \r\n', contentType: 'text/html');

      expect(await MessagesService(client).moveToTrash(0), isNull);
    });

    test('an empty answer to the retry after logging in again', () async {
      final server = await use(_ExpiredSession(afterLogin: ''));

      final status = await MessagesService(client).moveToTrash(0);

      expect(status, isNull);
      expect(server.requests, [
        {'msgID': '0'},
        {'msgID': '0'},
      ]);
      expect(server.log, contains('POST /2fa/api/v1/google-authenticator'));
    });
  });

  group('moveToTrash still throws for an answer that does not say that '
      'nothing was deleted (#59)', () {
    test('an HTML page', () async {
      await serve(_loginPage, contentType: 'text/html');

      await expectLater(
        MessagesService(client).moveToTrash(0),
        throwsA(
          isA<SmartschoolAuthenticationError>().having(
            (e) => e.message,
            'message',
            contains('HTML instead of XML'),
          ),
        ),
      );
    });

    test('text that is not XML', () async {
      await serve('Fatal error', contentType: 'text/html');

      await expectLater(
        MessagesService(client).moveToTrash(0),
        throwsA(isA<SmartschoolParsingError>()),
      );
    });

    test('an empty answer with an error status', () async {
      await serve('', status: 500, contentType: 'text/html');

      await expectLater(
        MessagesService(client).moveToTrash(0),
        throwsA(isA<SmartschoolParsingError>()),
      );
    });

    test('an empty 401 that Smartschool still answers after logging in '
        'again: the session is refused, not nothing deleted', () async {
      final server = await use(_ExpiredSession(afterLogin: null));

      await expectLater(
        MessagesService(client).moveToTrash(0),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.requests, hasLength(2));
    });
  });

  test('postXml still throws for an empty answer to a command that does not '
      'allow one, as every command but `quick delete` (#59)', () async {
    await serve('', contentType: 'text/html');

    await expectLater(
      client.postXml(
        url: '/?module=Messages&file=dispatcher',
        subsystem: 'postboxes',
        action: 'quick delete',
        params: {'msgID': '0'},
        xpath: './/actions/action',
      ),
      throwsA(
        isA<SmartschoolParsingError>().having(
          (e) => e.message,
          'message',
          contains('non-XML response'),
        ),
      ),
    );
  });
}
