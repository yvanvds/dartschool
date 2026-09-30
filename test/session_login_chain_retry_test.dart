// Regression tests for issue #22: two ways Smartschool refuses a session got
// past the auth interceptor, so the caller got the login chain's HTML instead
// of a new login or a typed error.
//
// 1. A POST sent without `X-Requested-With` (the multipart POSTs of
//    `MessagesService`: the message send and the attachment upload, and
//    `postJson`) is answered on an expired session with `302 Location: /login`
//    and Symfony's "Redirecting to /login" page, not with the bare `401` an
//    XHR/form POST gets (#8). `dart:io` does not follow a 302 after a POST, so
//    the response kept the requested URL and was not a 401: no login ran.
//    `sendMessage` even returned normally, as if the message had been sent.
// 2. A retry after logging in again that lands on the login chain again (a
//    GET redirected to `/login`, a POST redirected there) was handed to the
//    caller as if it were the data; only a retry answered `401` was reported.
//
// Measured live (read-only): with no session, `POST /Presence/Main/getConfig`
// without `X-Requested-With` gets `302`, `Location: /login` and a 270-byte
// "Redirecting to /login" page; with the header, it gets a bare `401`.
//
// Like the fake in session_unauthorized_test.dart, the fake Smartschool below
// keeps the session state itself and ignores the cookies the client sends.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/intradesk_service.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
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

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

const _composePage = '''
<html><body>
<form name="composeForm">
<input type="hidden" name="uniqueUsc" value="fake-unique-usc" />
<input type="hidden" name="randomDir" value="fake-random-dir" />
<input type="hidden" name="encryptedSender" value="fake-sender" />
</form>
</body></html>
''';

/// What the message send answers when it went through: a page that closes
/// the compose window.
const _sentPage = '<html><body><script>window.close();</script></body></html>';

// The requests, as the fake logs them: `METHOD path`, plus `?file=` for the
// Messages module, which is addressed by query on `/`.
const _send = 'POST /?file=composeMessage';
const _upload = 'POST /Upload/Upload/Index';
const _addRecipient = 'POST /?file=searchUsers';
const _courses = 'GET /course-list/api/v1/courses';
const _compose = 'GET /?file=composeMessage';
const _postJson = 'POST /api/v1/endpoint';

/// A POST that Smartschool redirects off the login chain.
const _elsewhere = 'POST /?file=elsewhere';

/// The requests of the login chain after its first page, from the password
/// to the 2FA answer.
const _password = [
  'POST /login',
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
];

/// The login chain that a refused POST starts: fetching the login page first.
const _login = ['GET /login', ..._password];

/// A Smartschool that refuses the session as the live platform does: a page
/// request (GET) is redirected to the login chain, an XHR/form POST gets a
/// bare `401`, and a POST without `X-Requested-With` gets a `302` to `/login`
/// that the HTTP client does not follow.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.loggedIn = false,
    this.expiresBefore,
    this.acceptsSessionAfterLogin = true,
  });

  /// Whether the session is accepted from the start.
  bool loggedIn;

  /// The request (as logged) before which the session expires, once.
  String? expiresBefore;

  /// Whether the session is accepted once the client logged in again; `false`
  /// keeps refusing it, as if the new session were not taken into account.
  final bool acceptsSessionAfterLogin;

  bool _passwordDone = false;

  /// Every request the client made, as `METHOD path` (see [_label]).
  final List<String> log = <String>[];

  /// The requests made from the one the session expired before (all of
  /// them when it did not expire during the test).
  List<String> get logSinceExpiry => log.sublist(_expiredAt ?? 0);

  int? _expiredAt;

  /// The bodies of the messages sent and attachments uploaded (with the
  /// session accepted).
  final List<String> sent = <String>[];
  final List<String> uploads = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = _label(options);
    if (request == expiresBefore) {
      expiresBefore = null;
      loggedIn = false;
      _expiredAt = log.length;
    }
    log.add(request);
    final path = options.uri.path;

    if (request == 'POST /login') {
      _passwordDone = true;
      return _redirect('/');
    }
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _passwordDone = false;
      loggedIn = acceptsSessionAfterLogin;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }

    if (options.method == 'POST') {
      if (!loggedIn) {
        return _sentWithXhr(options) ? _response('', status: 401) : _toLogin();
      }
      switch (request) {
        case _send:
          sent.add(await _read(requestStream));
          return _response(_sentPage);
        case _upload:
          uploads.add(await _read(requestStream));
          return _response('true');
        case _postJson:
          return _response('{"ok":true}', contentType: Headers.jsonContentType);
        case _elsewhere:
          return _redirect('/?module=Messages&file=index');
      }
      return _response('ok');
    }

    // A page request: redirected to wherever the session is in the chain.
    if (!loggedIn) {
      if (_passwordDone) return _page(path, '/2fa', '<html>2fa</html>');
      return _page(path, '/login', _loginPage);
    }
    if (request == _compose) return _response(_composePage);
    return _response('<html><body>home</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

Future<String> _read(Stream<Uint8List>? body) async => body == null
    ? ''
    : utf8.decode(
        await body.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)),
        allowMalformed: true,
      );

String _label(RequestOptions options) {
  final file = options.uri.queryParameters['file'];
  final query = file == null ? '' : '?file=$file';
  return '${options.method} ${options.uri.path}$query';
}

bool _sentWithXhr(RequestOptions options) => options.headers.entries.any(
  (h) =>
      h.key.toLowerCase() == kXRequestedWith.toLowerCase() &&
      h.value == 'XMLHttpRequest',
);

/// An HTML page at [at], reached from a GET of [requested]: the HTTP client
/// follows GET redirects itself and reports them through `redirects`.
ResponseBody _page(String requested, String at, String body) {
  final response = _response(body);
  if (requested != at) {
    response.redirects = [
      RedirectRecord(302, 'GET', Uri.parse('https://$_host$at')),
    ];
  }
  return response;
}

/// Smartschool's answer to a POST without `X-Requested-With` on an expired
/// session: a 302 to `/login`, which the HTTP client leaves unfollowed.
ResponseBody _toLogin() => _redirect('/login');

/// A redirect the HTTP client leaves unfollowed, as it does after a POST,
/// with the page Smartschool (Symfony) sends along with it.
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '<!DOCTYPE html>\n<html>\n<head>\n'
  '<meta http-equiv="refresh" content="0;url=\'$location\'" />\n'
  '<title>Redirecting to $location</title>\n</head>\n'
  '<body>Redirecting to <a href="$location">$location</a>.</body>\n</html>',
  302,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    'location': [location],
  },
);

ResponseBody _response(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

const _recipient = MessageSearchUser(
  userId: 11111,
  displayName: 'Test Recipient',
  ssId: 4069,
);

SendMessageParams _message({List<String> attachments = const []}) =>
    SendMessageParams(
      to: const [_recipient],
      subject: 'Test',
      bodyHtml: '<p>Test</p>',
      attachmentPaths: attachments,
    );

/// A [SmartschoolSessionExpiredError] that names the login chain.
Matcher _sessionExpired() => isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  allOf(contains('still answered'), contains('login chain (/login)')),
);

void main() {
  late Directory tempDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(_Smartschool server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: p.join(tempDir.path, 'cache'),
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_22_');
  });

  tearDown(() async {
    await client.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('a POST redirected to /login (no X-Requested-With) logs in again and '
      'is retried once (#22)', () {
    test('sendMessage: the message is sent after logging in again', () async {
      final server = await serve(
        _Smartschool(loggedIn: true, expiresBefore: _send),
      );

      // Before the fix: sendMessage returned normally, and nothing was sent.
      await MessagesService(client).sendMessage(_message());

      expect(server.logSinceExpiry, [_send, ..._login, _send]);
      // The retry sends the whole form again, not an empty body.
      expect(server.sent, [
        allOf(contains('fake-unique-usc'), contains('<p>Test</p>')),
      ]);
    });

    test(
      'sendMessage: an attachment is uploaded after logging in again',
      () async {
        final attachment = File(p.join(tempDir.path, 'note.txt'))
          ..writeAsStringSync('attachment');
        final server = await serve(
          _Smartschool(loggedIn: true, expiresBefore: _upload),
        );

        // Before the fix: SmartschoolAttachmentUploadError ("unexpected
        // response"), with the "Redirecting to /login" page in its message.
        await MessagesService(
          client,
        ).sendMessage(_message(attachments: [attachment.path]));

        expect(server.logSinceExpiry, [_upload, ..._login, _upload, _send]);
        // The retry sends the file again, not an empty body.
        expect(server.uploads, [
          allOf(contains('filename="note.txt"'), contains('attachment')),
        ]);
        expect(server.sent, hasLength(1));
      },
    );

    test('postJson returns the data of the retry', () async {
      final server = await serve(_Smartschool());

      // Before the fix: SmartschoolDownloadError (HTTP 302).
      final data = await client.postJson('/api/v1/endpoint', data: '{}');

      expect(data, {'ok': true});
      expect(server.log, [_postJson, ..._login, _postJson]);
    });

    test('an XHR/form POST on the same session still gets a 401 and logs in '
        'again (#8)', () async {
      final server = await serve(
        _Smartschool(loggedIn: true, expiresBefore: _addRecipient),
      );

      await MessagesService(client).sendMessage(_message());

      expect(server.logSinceExpiry, [
        _addRecipient,
        ..._login,
        _addRecipient,
        _send,
      ]);
      expect(server.sent, hasLength(1));
    });

    test('a redirect off the login chain is passed through, without a '
        'login', () async {
      final server = await serve(_Smartschool(loggedIn: true));

      final body = await client.postMultipartRaw(
        '/?module=Messages&file=elsewhere',
        FormData.fromMap({'field': 'value'}),
      );

      expect(body, contains('Redirecting to /?module=Messages&file=index'));
      expect(server.log, [_elsewhere]);
    });
  });

  group('a retry that lands on the login chain again is a '
      'SmartschoolSessionExpiredError, and is not retried again (#22)', () {
    test('a GET redirected to /login again: getJson '
        '(IntradeskService.getRootListing)', () async {
      final server = await serve(_Smartschool(acceptsSessionAfterLogin: false));

      // Before the fix: the base SmartschoolAuthenticationError "Expected
      // JSON but received HTML" from decoding the login page.
      await expectLater(
        IntradeskService(client).getRootListing(),
        throwsA(_sessionExpired()),
      );
      // The HTTP client followed the redirect to the login page itself.
      expect(server.log, [_courses, ..._password, _courses]);
    });

    test('a GET redirected to /login again: getRaw '
        '(MessagesService.getCurrentUserAsRecipient)', () async {
      final server = await serve(_Smartschool(acceptsSessionAfterLogin: false));

      // Before the fix: the login page was returned as the compose page, and
      // parsing it failed with a SmartschoolComposeError.
      await expectLater(
        MessagesService(client).getCurrentUserAsRecipient(),
        throwsA(_sessionExpired()),
      );
      expect(server.log, [_compose, ..._password, _compose]);
    });

    test('a POST redirected to /login again: sendMessage', () async {
      final server = await serve(
        _Smartschool(
          loggedIn: true,
          expiresBefore: _send,
          acceptsSessionAfterLogin: false,
        ),
      );

      await expectLater(
        MessagesService(client).sendMessage(_message()),
        throwsA(_sessionExpired()),
      );
      expect(server.logSinceExpiry, [_send, ..._login, _send]);
      expect(server.sent, isEmpty);
    });

    test('a POST redirected to /login again: postJson', () async {
      final server = await serve(_Smartschool(acceptsSessionAfterLogin: false));

      await expectLater(
        client.postJson('/api/v1/endpoint', data: '{}'),
        throwsA(_sessionExpired()),
      );
      expect(server.log, [_postJson, ..._login, _postJson]);
    });

    test('an on-clause for the authentication error catches it', () async {
      await serve(_Smartschool(acceptsSessionAfterLogin: false));

      Object? caught;
      try {
        await IntradeskService(client).getRootListing();
      } on SmartschoolAuthenticationError catch (e) {
        caught = e;
      }

      expect(caught, isA<SmartschoolSessionExpiredError>());
    });
  });
}
