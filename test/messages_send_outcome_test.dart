// Regression tests for issue #25: `MessagesService.sendMessage` reported
// failures before and after the submit (the multipart POST that sends the
// message) the same way, and any answer to the submit that was not an error
// page counted as sent.
//
// 1. An unconfirmed submit returned normally: an answer without the page that
//    closes the compose window (`200` + `window.close()`, as in the recorded
//    answer `post/composemessage/on_send.html`) counted as sent, and a
//    connection failure after the submit went out was a
//    `SmartschoolConnectionError`, as if it had failed before. Such an
//    outcome is now a `SmartschoolSendUnconfirmedError`: the message may have
//    been sent, and it is not submitted again.
// 2. The compose state is tied to the session the compose form was loaded in
//    (its `uniqueUsc` and `randomDir` tokens, and the recipients registered
//    with them). Since #8 and #22, a step of the send that Smartschool
//    refused for its session was retried after logging in again, with the
//    tokens of the refused session: the submit could send the message with a
//    stale compose state (see the #22 note on #25). Those steps are no longer
//    retried: the send fails with a `SmartschoolSessionExpiredError` (nothing
//    was sent), and calling `sendMessage` again loads a new compose form.
//
// The fake Smartschool below serves the recorded compose form and send answer
// and keeps the session state itself (ignoring the cookies), as the fake of
// session_login_chain_retry_test.dart does. Each login starts a new session,
// whose compose form carries tokens of its own.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/add_recipient_answer.dart';
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

/// The recorded new-message compose form.
final _recordedComposeForm = _fixture('get/composemessage/new-message.html');

/// The recorded answer to a sent message: `200` and a page whose script
/// calls `checkOpenerActions(); window.close();`.
final _recordedSendAnswer = _fixture('post/composemessage/on_send.html');

/// The compose form of session [session]: the recorded form, with tokens
/// that name the session.
String _composeForm(int session) => _recordedComposeForm
    .replaceFirst(
      RegExp(r'name="uniqueUsc" value="[^"]*"'),
      'name="uniqueUsc" value="usc-of-session-$session"',
    )
    .replaceFirst(
      RegExp(r'name="randomDir" value="[^"]*"'),
      'name="randomDir" value="dir-of-session-$session"',
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
const _compose = 'GET /?file=composeMessage';
const _addRecipient = 'POST /?file=searchUsers';
const _upload = 'POST /Upload/Upload/Index';
const _submit = 'POST /?file=composeMessage';

/// The login chain that a GET redirected to `/login` runs: the login loads the
/// login page itself, in a new session (#45), and goes from the password to
/// the 2FA answer.
const _login = [
  'GET /login',
  'POST /login',
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
];

/// A Smartschool that refuses the session as the live platform does (a GET
/// is redirected to the login chain, an XHR/form POST gets a bare `401`, a
/// POST without `X-Requested-With` gets a `302` to `/login`), and answers the
/// steps of a send with the recorded answers.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.expiresBefore,
    this.expiresAt = 1,
    this.composeForm = _composeForm,
    this.uploadAnswer = 'true',
    this.answerSubmit,
    this.failSubmit,
    this.unreachableAt,
  });

  /// The request (as logged) before which the session expires, once: before
  /// its [expiresAt]th occurrence.
  final String? expiresBefore;
  final int expiresAt;
  int _occurrences = 0;

  /// The compose form of a session.
  final String Function(int session) composeForm;

  /// The answer to an attachment upload.
  final String uploadAnswer;

  /// Smartschool's answer to a submit it handled; the recorded send answer
  /// when `null`.
  final ResponseBody Function()? answerSubmit;

  /// Thrown instead of the answer, once Smartschool handled the submit: the
  /// connection failed after the message went out.
  final Object Function(RequestOptions options)? failSubmit;

  /// The request (as logged) that fails to connect, before it reaches
  /// Smartschool.
  final String? unreachableAt;

  /// The current session: each login starts a new one.
  int session = 1;
  bool _loggedIn = true;
  bool _passwordDone = false;

  /// Every request the client made, as `METHOD path` (see [_label]).
  final List<String> log = <String>[];

  /// The requests made from the one the session expired before (all of
  /// them when it did not expire).
  List<String> get logSinceExpiry => log.sublist(_expiredAt ?? 0);
  int? _expiredAt;

  /// The recipients registered with the session accepted, as
  /// `session <n>: <uniqueUsc> <id>`.
  final List<String> registered = <String>[];

  /// The uploads handled, as `session <n>: <uploadDir>`.
  final List<String> uploads = <String>[];

  /// The submits Smartschool handled (so the messages it sent, unless its
  /// answer says otherwise), as `session <n>: <uniqueUsc> <subject>`.
  final List<String> submits = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = _label(options);
    if (request == expiresBefore && ++_occurrences == expiresAt) {
      _loggedIn = false;
      _expiredAt = log.length;
    }
    log.add(request);
    if (request == unreachableAt) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
        error: const SocketException('Connection refused'),
      );
    }
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
      _loggedIn = true;
      session++;
      return _response(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }

    if (options.method == 'POST') {
      if (!_loggedIn) {
        return _sentWithXhr(options)
            ? _response('', status: 401)
            : _redirect('/login');
      }
      switch (request) {
        case _addRecipient:
          final fields = options.data as Map;
          registered.add(
            'session $session: ${fields['uniqueUsc']} ${fields['id']}',
          );
          return _response(
            registeredRecipientAnswer(fields),
            contentType: registeredRecipientContentType,
          );
        case _upload:
          uploads.add('session $session: ${_field(options, 'uploadDir')}');
          return _response(uploadAnswer);
        case _submit:
          submits.add(
            'session $session: ${_field(options, 'uniqueUsc')} '
            '${_field(options, 'subject')}',
          );
          final fail = failSubmit;
          if (fail != null) throw fail(options);
          return answerSubmit?.call() ?? _response(_recordedSendAnswer);
      }
      fail('unexpected request: $request');
    }

    // A page request: redirected to wherever the session is in the chain.
    if (!_loggedIn) {
      if (_passwordDone) return _page(path, '/2fa', '<html>2fa</html>');
      return _page(path, '/login', _loginPage);
    }
    if (request == _compose) return _response(composeForm(session));
    return _response('<html><body>home</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

String _label(RequestOptions options) {
  final file = options.uri.queryParameters['file'];
  final query = file == null ? '' : '?file=$file';
  return '${options.method} ${options.uri.path}$query';
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

/// A redirect the HTTP client leaves unfollowed, as it does after a POST,
/// with the page Smartschool (Symfony) sends along with it.
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '<!DOCTYPE html>\n<html>\n<head>\n'
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

const _alice = MessageSearchUser(
  userId: 11111,
  displayName: 'Alice Example',
  ssId: 4069,
);
const _bob = MessageSearchUser(
  userId: 22222,
  displayName: 'Bob Example',
  ssId: 4069,
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

/// A [SmartschoolSendUnconfirmedError]: not a [SmartschoolComposeError], so a
/// `catch` meant for the failures that are safe to retry does not catch it.
Matcher _unconfirmed({int? statusCode, Matcher cause = isNull}) => allOf(
  isA<SmartschoolSendUnconfirmedError>()
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.cause, 'cause', cause)
      .having((e) => e.message, 'message', contains('check the sent box')),
  isNot(isA<SmartschoolComposeError>()),
);

/// A [SmartschoolSessionExpiredError] for a step that is not retried after
/// logging in again.
Matcher _notRetried() => isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('not retried after logging in again'),
);

void main() {
  forbidRealNetwork();

  late Directory tempDir;
  late SmartschoolClient client;
  late MessagesService messages;

  Future<_Smartschool> serve(_Smartschool server) async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: p.join(tempDir.path, 'cache'),
    );
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
    return server;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('smartschool_25_');
  });

  tearDown(() async {
    await client.dispose();
    tempDir.deleteSync(recursive: true);
  });

  group('a confirmed send (#25)', () {
    test('returns normally when Smartschool answers with the page that closes '
        'the compose window (the recorded answer)', () async {
      final server = await serve(_Smartschool());

      await messages.sendMessage(_message());

      expect(server.log, [_compose, _addRecipient, _submit]);
      expect(server.submits, ['session 1: usc-of-session-1 Test']);
    });
  });

  group('a submit that Smartschool does not confirm is a '
      'SmartschoolSendUnconfirmedError, and is not submitted again (#25)', () {
    final answers = <String, (ResponseBody Function(), int)>{
      // Before the fix: sendMessage returned normally.
      'a page that does not close the compose window': (
        () => _response('<html><body>Berichten</body></html>'),
        200,
      ),
      'an empty page': (() => _response(''), 200),
      "Smartschool's error page (500)": (
        () => _response(
          '<html><body>Er is een fout opgetreden</body></html>',
          status: 500,
        ),
        500,
      ),
      // Before the fix: a SmartschoolComposeError, which reads as "nothing
      // was sent".
      'a page that closes the window, with an error marker': (
        () => _response(
          '<html><body><script>var error = "Geen ontvangers"; '
          'alert(error); window.close();</script></body></html>',
        ),
        200,
      ),
    };

    for (final MapEntry(key: name, value: (answer, status))
        in answers.entries) {
      test(name, () async {
        final server = await serve(_Smartschool(answerSubmit: answer));

        await expectLater(
          messages.sendMessage(_message()),
          throwsA(_unconfirmed(statusCode: status)),
        );
        expect(server.log, [_compose, _addRecipient, _submit]);
        expect(server.submits, hasLength(1));
      });
    }

    final failures = <String, Object Function(RequestOptions)>{
      'the connection drops': (options) => DioException.connectionError(
        requestOptions: options,
        reason: 'Connection closed before full header was received',
        error: const SocketException('Connection reset by peer'),
      ),
      'the connection drops (a raw socket error)': (_) =>
          const SocketException('Connection reset by peer'),
      'waiting for the answer times out': (options) =>
          DioException.receiveTimeout(
            timeout: const Duration(seconds: 30),
            requestOptions: options,
          ),
    };

    for (final MapEntry(key: name, value: failure) in failures.entries) {
      test('$name after Smartschool received the submit', () async {
        final server = await serve(_Smartschool(failSubmit: failure));

        // Before the fix: a SmartschoolConnectionError, as when the send
        // fails before the submit.
        await expectLater(
          messages.sendMessage(_message()),
          throwsA(_unconfirmed(cause: isA<SmartschoolConnectionError>())),
        );
        expect(server.log, [_compose, _addRecipient, _submit]);
        expect(server.submits, hasLength(1));
      });
    }
  });

  group('a failure before the submit is not a '
      'SmartschoolSendUnconfirmedError: nothing was sent (#25)', () {
    test('Smartschool cannot be reached for the compose form', () async {
      final server = await serve(_Smartschool(unreachableAt: _compose));

      await expectLater(
        messages.sendMessage(_message()),
        throwsA(isA<SmartschoolConnectionError>()),
      );
      expect(server.log, [_compose]);
    });

    test('the connection fails while registering a recipient', () async {
      final server = await serve(_Smartschool(unreachableAt: _addRecipient));

      await expectLater(
        messages.sendMessage(_message()),
        throwsA(isA<SmartschoolConnectionError>()),
      );
      expect(server.log, [_compose, _addRecipient]);
      expect(server.submits, isEmpty);
    });

    test('the compose form has no uniqueUsc', () async {
      final server = await serve(
        _Smartschool(composeForm: (_) => '<html><body></body></html>'),
      );

      await expectLater(
        messages.sendMessage(_message()),
        throwsA(isA<SmartschoolComposeError>()),
      );
      expect(server.log, [_compose]);
    });

    test('Smartschool refuses an attachment', () async {
      final attachment = File(p.join(tempDir.path, 'note.txt'))
        ..writeAsStringSync('attachment');
      final server = await serve(_Smartschool(uploadAnswer: 'false'));

      await expectLater(
        messages.sendMessage(_message(attachments: [attachment.path])),
        throwsA(isA<SmartschoolAttachmentUploadError>()),
      );
      expect(server.log, [_compose, _addRecipient, _upload]);
      expect(server.submits, isEmpty);
    });
  });

  group('a step that Smartschool refuses for its session is not retried with '
      'the compose state of the refused session (#25, #22)', () {
    test('the submit (302 to /login): a SmartschoolSessionExpiredError, '
        'without a login or a second submit', () async {
      final server = await serve(_Smartschool(expiresBefore: _submit));

      // Before the fix: the client logged in again and submitted the compose
      // form of session 1 in session 2.
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(_notRetried()),
      );
      expect(server.logSinceExpiry, [_submit]);
      expect(server.submits, isEmpty);
    });

    test('registering a recipient (401): a SmartschoolSessionExpiredError, '
        'and nothing is submitted', () async {
      final server = await serve(
        _Smartschool(expiresBefore: _addRecipient, expiresAt: 2),
      );

      // Before the fix: the client logged in again, registered Bob in
      // session 2 with the uniqueUsc of session 1, under which Alice was
      // registered in session 1, and submitted that form in session 2.
      await expectLater(
        messages.sendMessage(_message(to: [_alice, _bob])),
        throwsA(_notRetried()),
      );
      expect(server.log, [_compose, _addRecipient, _addRecipient]);
      expect(server.registered, ['session 1: usc-of-session-1 11111']);
      expect(server.submits, isEmpty);
    });

    test('an attachment upload (302 to /login): a '
        'SmartschoolSessionExpiredError, and nothing is submitted', () async {
      final attachment = File(p.join(tempDir.path, 'note.txt'))
        ..writeAsStringSync('attachment');
      final server = await serve(_Smartschool(expiresBefore: _upload));

      // Before the fix: the client logged in again, uploaded the file to the
      // randomDir of session 1 in session 2, and submitted that form.
      await expectLater(
        messages.sendMessage(_message(attachments: [attachment.path])),
        throwsA(_notRetried()),
      );
      expect(server.logSinceExpiry, [_upload]);
      expect(server.uploads, isEmpty);
      expect(server.submits, isEmpty);
    });

    test('sending again logs in at the compose form and sends the message '
        'with the compose state of the new session', () async {
      final server = await serve(_Smartschool(expiresBefore: _submit));
      await expectLater(
        messages.sendMessage(_message()),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );

      await messages.sendMessage(_message());

      // The client knows that Smartschool refused the session for the
      // submit, so it logs in before it loads the compose form (#134).
      // Before #134, the form went out in the refused session first, and was
      // refused, which logged in.
      expect(server.logSinceExpiry, [
        _submit,
        ..._login,
        _compose,
        _addRecipient,
        _submit,
      ]);
      expect(server.registered, [
        'session 1: usc-of-session-1 11111',
        'session 2: usc-of-session-2 11111',
      ]);
      expect(server.submits, ['session 2: usc-of-session-2 Test']);
    });

    test('a session that expired before the send is renewed at the compose '
        'form, and the whole send runs in the new session', () async {
      final server = await serve(_Smartschool(expiresBefore: _compose));

      await messages.sendMessage(_message());

      expect(server.log, [
        _compose,
        ..._login,
        _compose,
        _addRecipient,
        _submit,
      ]);
      expect(server.submits, ['session 2: usc-of-session-2 Test']);
    });
  });
}
