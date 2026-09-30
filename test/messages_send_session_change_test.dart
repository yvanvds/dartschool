// Regression tests for issue #38: a login made by another request on the same
// `SmartschoolClient` while `MessagesService.sendMessage` (or `sendReply`)
// runs replaces the session in the cookie cache, and the send went on in the
// new session with the tokens of the compose form it had loaded in the old
// one (`uniqueUsc`, `randomDir`). Smartschool refused none of those steps, so
// the recipients registered after the login, the attachments and the submit
// went out in a session the form's tokens do not belong to (#25 only covers
// the send's own requests being refused).
//
// A step of the send (a recipient, an attachment, the submit) now goes out
// only in the session the compose form was loaded in: when a login started
// since the form's request went out, or one runs, the send stops before the
// step with a `SmartschoolSessionExpiredError`, and nothing is submitted.
//
// Like the fake in `session_shared_login_test.dart`, the fake Smartschool
// below keeps its state per `PHPSESSID` cookie, as the live platform does:
// the login loads the login page without a session cookie and gets a new
// session for it (#45), and an accepted password moves that session to a new
// id. Each session has compose forms with tokens of its own, and Smartschool
// accepts a step of a send in any session it has authenticated, whatever
// the tokens it carries: what it does with tokens of another session was
// never checked live (read-only checks may not send), so the tests only
// check what the client sends.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _host = 'school.smartschool.be';
const _sessionCookie = 'PHPSESSID';

/// The session in the cookie cache when a test starts, which Smartschool has
/// authenticated.
const _firstSession = 'session-0';

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

/// The recorded new-message form.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// The recorded reply form of received message 900030 from Piet Peeters.
final _replyForm = _fixture('get/composemessage/reply.html');

/// The recorded answer to a sent message: `200` and a page whose script
/// calls `checkOpenerActions(); window.close();`.
final _sendAnswer = _fixture('post/composemessage/on_send.html');

/// The recorded answer to `addUserToSelected`.
final _addRecipientAnswer = _fixture(
  'post/composemessage/add-users-to-selected.xml',
);

/// [form] with the tokens of session [sid].
String _withTokensOf(String form, String sid) => form
    .replaceFirst(
      RegExp(r'name="uniqueUsc" value="[^"]*"'),
      'name="uniqueUsc" value="usc-of-$sid"',
    )
    .replaceFirst(
      RegExp(r'name="randomDir" value="[^"]*"'),
      'name="randomDir" value="dir-of-$sid"',
    );

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

// The requests, as the fake logs them: `METHOD path`, plus `?file=` for the
// Messages module, which is addressed by query on `/`.
const _form = 'GET /?file=composeMessage';
const _addRecipient = 'POST /?file=searchUsers';
const _upload = 'POST /Upload/Upload/Index';
const _submit = 'POST /?file=composeMessage';

/// A request of another service on the same client: a page GET.
const _otherRequest = 'GET /';

/// The login POST: one per login.
const _password = 'POST /login';

/// The 2FA POST, with the one-time code: one per login.
const _twoFactorCode = 'POST /2fa/api/v1/google-authenticator';

enum _Stage { anonymous, passwordDone, authenticated }

/// A Smartschool that tracks each session by its `PHPSESSID` cookie, refuses
/// a session as the live platform does (a page request is redirected to the
/// login chain, an XHR/form POST gets a bare `401`, a POST without
/// `X-Requested-With` a `302` to `/login`), and answers the steps of a send
/// with the recorded answers.
class _Smartschool implements HttpClientAdapter {
  final Map<String, _Stage> _sessions = <String, _Stage>{
    _firstSession: _Stage.authenticated,
  };
  int _issued = 0;

  /// Every request the client made, as `METHOD path` (see [_label]).
  final List<String> log = <String>[];

  /// The recipients registered, as `<session>: <uniqueUsc> <id>`.
  final List<String> registered = <String>[];

  /// The attachments uploaded, as `<session>: <uploadDir>`.
  final List<String> uploads = <String>[];

  /// The submits handled (so the messages sent), as
  /// `<session>: <uniqueUsc> <subject>`.
  final List<String> submits = <String>[];

  /// Runs once Smartschool has handled the first request `METHOD path` in
  /// here, before its answer goes back; what it throws is thrown instead of
  /// the answer, as a connection that fails after the request was handled.
  final Map<String, Future<void> Function(RequestOptions options)>
  afterHandling = <String, Future<void> Function(RequestOptions options)>{};

  final Map<String, Completer<void>> _handled = <String, Completer<void>>{};

  /// Completes when Smartschool has handled a request `METHOD path`.
  Future<void> handled(String request) =>
      _handled.putIfAbsent(request, Completer<void>.new).future;

  /// How many times the client made [request].
  int count(String request) => log.where((l) => l == request).length;

  /// Ends session [sid]: Smartschool no longer knows it.
  void expire(String sid) => _sessions.remove(sid);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = _label(options);
    log.add(request);
    final answer = _answer(options, request, _sessionId(options));
    final done = _handled.putIfAbsent(request, Completer<void>.new);
    if (!done.isCompleted) done.complete();
    final after = afterHandling.remove(request);
    if (after != null) await after(options);
    return answer;
  }

  ResponseBody _answer(RequestOptions options, String request, String? sid) {
    final path = options.uri.path;

    if (request == 'GET /login') {
      // The login loads the login page without a session cookie (#45):
      // Smartschool starts a new session for it.
      if (sid != null) fail('the login page was loaded in session $sid');
      final fresh = 'session-${++_issued}';
      _sessions[fresh] = _Stage.anonymous;
      return _response(_loginPage, setSession: fresh);
    }
    if (request == _password) {
      if (sid == null || _sessions[sid] != _Stage.anonymous) {
        fail('password POST in session $sid');
      }
      // An accepted password moves the session to a new id.
      _sessions.remove(sid);
      final fresh = 'session-${++_issued}';
      _sessions[fresh] = _Stage.passwordDone;
      return _redirect('/', setSession: fresh);
    }

    final stage = sid == null
        ? _Stage.anonymous
        : _sessions.putIfAbsent(sid, () => _Stage.anonymous);
    if (path == '/2fa/api/v1/config') {
      return _response(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (request == _twoFactorCode) {
      if (stage != _Stage.passwordDone) fail('2FA POST in session $sid');
      _sessions[sid!] = _Stage.authenticated;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }

    if (stage != _Stage.authenticated) {
      if (options.method == 'POST') {
        return _sentWithXhr(options)
            ? _response('', status: 401)
            : _redirect('/login');
      }
      if (stage == _Stage.passwordDone) {
        return _page(path, '/2fa', '<html><body>2fa</body></html>');
      }
      return _page(path, '/login', _loginPage);
    }

    switch (request) {
      case _form:
        final form = switch (options.uri.queryParameters['composeType']) {
          '0' => _newMessageForm,
          '1' => _replyForm,
          final other => fail('unexpected compose form: $other'),
        };
        return _response(_withTokensOf(form, sid!));
      case _addRecipient:
        final fields = options.data as Map;
        registered.add('$sid: ${fields['uniqueUsc']} ${fields['id']}');
        return _response(_addRecipientAnswer, contentType: 'text/xml');
      case _upload:
        uploads.add('$sid: ${_field(options, 'uploadDir')}');
        return _response('true');
      case _submit:
        submits.add(
          '$sid: ${_field(options, 'uniqueUsc')} '
          '${_field(options, 'subject')}',
        );
        return _response(_sendAnswer);
      case _otherRequest:
        return _response('<html><body>home</body></html>');
    }
    fail('unexpected request: $request');
  }

  @override
  void close({bool force = false}) {}
}

String _label(RequestOptions options) {
  final file = options.uri.queryParameters['file'];
  final query = file == null ? '' : '?file=$file';
  return '${options.method} ${options.uri.path}$query';
}

/// The first `PHPSESSID` in the `Cookie` header of [options], which is the
/// one Smartschool (PHP) reads.
String? _sessionId(RequestOptions options) {
  final header = options.headers[HttpHeaders.cookieHeader] as String?;
  if (header == null) return null;
  for (final pair in header.split(';')) {
    final cookie = pair.trim();
    if (cookie.startsWith('$_sessionCookie=')) {
      return cookie.substring(_sessionCookie.length + 1);
    }
  }
  return null;
}

/// The value of field [name] of a multipart request.
String? _field(RequestOptions options, String name) {
  for (final field in (options.data as FormData).fields) {
    if (field.key == name) return field.value;
  }
  return null;
}

bool _sentWithXhr(RequestOptions options) => options.headers.entries.any(
  (h) =>
      h.key.toLowerCase() == kXRequestedWith.toLowerCase() &&
      h.value == 'XMLHttpRequest',
);

Map<String, List<String>> _headers(String contentType, String? setSession) => {
  Headers.contentTypeHeader: [contentType],
  if (setSession != null)
    HttpHeaders.setCookieHeader: ['$_sessionCookie=$setSession; path=/'],
};

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

/// A redirect the HTTP client leaves unfollowed, as it does after a POST.
ResponseBody _redirect(String location, {String? setSession}) =>
    ResponseBody.fromString(
      '<html><body>Redirecting to $location</body></html>',
      302,
      headers: {
        ..._headers('text/html; charset=UTF-8', setSession),
        'location': [location],
      },
    );

ResponseBody _response(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
  String? setSession,
}) => ResponseBody.fromString(
  body,
  status,
  headers: _headers(contentType, setSession),
);

const _alice = MessageSearchUser(
  userId: 11111,
  displayName: 'Alice Example',
  ssId: 100,
);
const _bob = MessageSearchUser(
  userId: 22222,
  displayName: 'Bob Example',
  ssId: 100,
);

/// The sender of message 900030, as its reply form names them.
const _sender = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);

SendMessageParams _message({
  List<MessageSearchUser> to = const [_alice],
  List<String> attachments = const [],
}) => SendMessageParams(
  to: to,
  subject: 'Test',
  bodyHtml: '<p>Test</p>',
  attachmentPaths: attachments,
);

SendMessageParams _reply({List<MessageSearchUser> to = const [_sender]}) =>
    SendMessageParams(
      to: to,
      subject: 'Re: Schoolreis',
      bodyHtml: '<p>Prima, tot vrijdag.</p>',
    );

/// The error of a send that stopped because the client's session is no
/// longer the one its compose form was loaded in: nothing was sent, and it
/// is safe to send again.
final Matcher _sessionChanged = allOf(
  isA<SmartschoolSessionExpiredError>().having(
    (e) => e.message,
    'message',
    allOf(contains('was not sent'), contains('/?module=Messages')),
  ),
  isNot(isA<SmartschoolSendUnconfirmedError>()),
);

void main() {
  late Directory cacheDir;
  late SmartschoolClient client;
  late MessagesService messages;
  late _Smartschool server;

  setUp(() async {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_38_');
    // The cookie cache holds a session that Smartschool has authenticated.
    final jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cacheDir.path, '.cookies')),
    );
    await jar.saveFromResponse(Uri.parse('https://$_host/'), [
      Cookie(_sessionCookie, _firstSession)..path = '/',
    ]);
    server = _Smartschool();
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  /// Makes Smartschool end the session once it has handled the first
  /// [request] of the send, and another request on the client find it
  /// ended and log in again before the answer to [request] comes back.
  void anotherRequestLogsInAfter(String request) {
    server.afterHandling[request] = (_) async {
      server.expire(_firstSession);
      await client.getRaw('/');
    };
  }

  group('sendMessage stops before the next step when another request logged '
      'in again since the compose form was loaded (#38)', () {
    test('between two recipients: the second recipient and the submit are '
        'not sent', () async {
      anotherRequestLogsInAfter(_addRecipient);

      // Before the fix: Bob was registered and the message submitted in
      // session-2, with the uniqueUsc of session-0.
      await expectLater(
        messages.sendMessage(_message(to: [_alice, _bob])),
        throwsA(_sessionChanged),
      );
      expect(server.registered, ['session-0: usc-of-session-0 11111']);
      expect(server.count(_addRecipient), 1);
      expect(server.count(_password), 1);
      expect(server.count(_submit), 0);
      expect(server.submits, isEmpty);
    });

    test('after the last recipient: the submit is not sent', () async {
      anotherRequestLogsInAfter(_addRecipient);

      // Before the fix: the message was submitted in session-2 with the
      // uniqueUsc of session-0, and sendMessage returned normally.
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(_sessionChanged),
      );
      expect(server.log.where((r) => r.contains('?file=')), [
        _form,
        _addRecipient,
      ]);
      expect(server.submits, isEmpty);
    });

    test('before an attachment: the upload and the submit are not '
        'sent', () async {
      final attachment = File(p.join(cacheDir.path, 'note.txt'))
        ..writeAsStringSync('attachment');
      anotherRequestLogsInAfter(_addRecipient);

      // Before the fix: the file was uploaded in session-2 to the randomDir
      // of session-0, and the message submitted.
      await expectLater(
        messages.sendMessage(_message(attachments: [attachment.path])),
        throwsA(_sessionChanged),
      );
      expect(server.count(_upload), 0);
      expect(server.uploads, isEmpty);
      expect(server.submits, isEmpty);
    });

    test('while the compose form was on its way: its request went out in the '
        'old session, and its answer came in after the login', () async {
      anotherRequestLogsInAfter(_form);

      // The client logged in again before the form came in, so comparing the
      // logins after loading the form is not enough: the form carries the
      // tokens of the session its request went out in. Before the fix: Alice
      // was registered and the message submitted in session-2 with the
      // uniqueUsc of session-0.
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(_sessionChanged),
      );
      expect(server.log.where((r) => r.contains('?file=')), [_form]);
      expect(server.registered, isEmpty);
      expect(server.submits, isEmpty);
    });

    test('while that login runs, once Smartschool accepted its 2FA code: the '
        'submit is not sent in the session the login is setting up', () async {
      final release = Completer<void>();
      Future<String>? other;
      server.afterHandling[_addRecipient] = (_) async {
        server.expire(_firstSession);
        other = client.getRaw('/');
        // Smartschool has authenticated the new session, and the answer to
        // the 2FA code is still on its way to the client.
        await server.handled(_twoFactorCode);
      };
      server.afterHandling[_twoFactorCode] = (_) => release.future;

      try {
        // Before the fix: the cookie cache held the new session already, and
        // the message was submitted in it with the uniqueUsc of session-0.
        await expectLater(
          messages.sendMessage(_message()),
          throwsA(_sessionChanged),
        );
        expect(server.submits, isEmpty);
      } finally {
        release.complete();
        await other;
      }
      expect(server.submits, isEmpty);
    });

    test('after a login that failed once Smartschool had accepted it (the '
        'connection dropped on the answer to the 2FA code): the submit is not '
        'sent in the session it set up', () async {
      server.afterHandling[_twoFactorCode] = (options) async =>
          throw DioException.connectionError(
            requestOptions: options,
            reason: 'Connection reset by peer',
            error: const SocketException('Connection reset by peer'),
          );
      server.afterHandling[_addRecipient] = (_) async {
        server.expire(_firstSession);
        await expectLater(
          client.getRaw('/'),
          throwsA(isA<SmartschoolConnectionError>()),
        );
      };

      // The client did not complete that login, but the cookie cache holds
      // the session Smartschool authenticated for it. Before the fix: the
      // message was submitted in that session with the uniqueUsc of
      // session-0.
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(_sessionChanged),
      );
      expect(server.submits, isEmpty);
    });

    test('sending again loads a new compose form and sends the message in '
        'the new session', () async {
      anotherRequestLogsInAfter(_addRecipient);
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(_sessionChanged),
      );

      await messages.sendMessage(_message());

      expect(server.registered, [
        'session-0: usc-of-session-0 11111',
        'session-2: usc-of-session-2 11111',
      ]);
      expect(server.submits, ['session-2: usc-of-session-2 Test']);
      expect(server.count(_password), 1);
    });

    test('a compose form that waited for a login that another request started '
        'is loaded in the new session, and the send goes on', () async {
      server.expire(_firstSession);
      Future<String>? other;
      // The form is refused; before its answer comes back, another request
      // is refused too and starts the login, which the form then waits for.
      server.afterHandling[_form] = (_) async {
        other = client.getRaw('/');
        await server.handled('GET /login');
      };

      await messages.sendMessage(_message());
      await other;

      expect(server.count(_password), 1);
      expect(server.count(_form), 2);
      expect(server.registered, ['session-2: usc-of-session-2 11111']);
      expect(server.submits, ['session-2: usc-of-session-2 Test']);
    });
  });

  group('sendReply stops before the next step when another request logged in '
      'again since the reply form was loaded (#38)', () {
    test('before the submit, for a reply to the recipients the form names: '
        'the submit is not sent', () async {
      anotherRequestLogsInAfter(_form);

      // Before the fix: the reply was submitted in session-2 with the
      // uniqueUsc of session-0.
      await expectLater(
        messages.sendReply(900030, _reply()),
        throwsA(_sessionChanged),
      );
      expect(server.log.where((r) => r.contains('?file=')), [_form]);
      expect(server.submits, isEmpty);
    });

    test('after a recipient it adds: the submit is not sent', () async {
      anotherRequestLogsInAfter(_addRecipient);

      await expectLater(
        messages.sendReply(900030, _reply(to: [_sender, _alice])),
        throwsA(_sessionChanged),
      );
      expect(server.registered, ['session-0: usc-of-session-0 11111']);
      expect(server.submits, isEmpty);
    });

    test('without a login meanwhile, the reply is sent in the session its '
        'form was loaded in', () async {
      await messages.sendReply(900030, _reply(to: [_sender, _alice]));

      expect(server.registered, ['session-0: usc-of-session-0 11111']);
      expect(server.submits, ['session-0: usc-of-session-0 Re: Schoolreis']);
    });
  });

  group('SmartschoolClient: a request sent with sameSessionAs (#38)', () {
    const addRecipient =
        '/?module=Messages&file=searchUsers&function=addUserToSelected';
    const fields = {'id': '11111', 'uniqueUsc': 'usc-of-session-0'};

    test('goes out in the session of an answer loaded with '
        'getResponse', () async {
      final form = await client.getResponse(
        '/?module=Messages&file=composeMessage&composeType=0',
      );

      await client.postFormRaw(
        addRecipient,
        fields,
        retryAfterLogin: false,
        sameSessionAs: form,
      );

      expect(server.registered, ['session-0: usc-of-session-0 11111']);
    });

    test('is not sent when the answer is not one of this client: its session '
        'is not known', () async {
      final elsewhere = Response<String>(
        requestOptions: RequestOptions(path: '/elsewhere'),
      );

      await expectLater(
        client.postFormRaw(
          addRecipient,
          fields,
          retryAfterLogin: false,
          sameSessionAs: elsewhere,
        ),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            allOf(contains('was not sent'), contains('/elsewhere')),
          ),
        ),
      );
      expect(server.log, isEmpty);
    });
  });
}
