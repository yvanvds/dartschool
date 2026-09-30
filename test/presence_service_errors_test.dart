// Regression tests for issue #5: `PresenceService` reported every HTML answer
// as one `SmartschoolPresenceError` ("The session may have expired, or the
// account lacks Presence access"), so a caller could not tell "sign in again"
// from "give up" other than by matching the message.
//
// What a Presence request can still get back as a non-JSON answer, verified
// live (read-only, `Presence/Main/getConfig` and `Presence/Class/getClass`):
//
// - On an expired session, Smartschool answers the XHR/form POST with a bare
//   `401` (#8). The client logs in again and retries; a retry that is refused
//   too ends as a `SmartschoolSessionExpiredError`.
// - A POST that is redirected to `/login` instead (what Smartschool does with
//   a POST sent without `X-Requested-With`) gets `302 Location: /login` and a
//   "Redirecting to /login" HTML page, which the HTTP client does not follow
//   for a POST. Since #22 the client logs in again for it too and retries
//   once. A retry that is redirected to the login chain again, or lands on
//   the login page itself, is the login chain answering:
//   `SmartschoolSessionExpiredError`.
// - With the session accepted, a request the module cannot handle (an
//   invalid request, such as `getClass` with `includePupils=0`, or an unknown
//   action) gets HTTP `500` with Smartschool's generic "Oeps, er ging iets
//   mis" page: `SmartschoolPresenceError`. Signing in again does not help.
//   (A class the account may not record for is answered in JSON: an empty
//   `pupils` list, `saveIsAllowed: false` and an `errorMessage`.)
//
// The fake Smartschool below serves the Presence endpoints from canned
// answers; its pupil data is made up.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/services/presence_service.dart';
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

const _getConfig = '/Presence/Main/getConfig';
const _getAllCodes = '/Presence/Code/getAllCodes';
const _getClass = '/Presence/Class/getClass';
const _save = '/Presence/Class/savePupilsPresences';

const _configJson = '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"groupID":298,"name":"1A","structID":311,
   "userCanRecord":true},"schoolyear":"2026-09-01"},
 "main":{"allowedClasses":[{"groupID":298,"name":"1A","structID":311,
   "userCanRecord":true}]}}
''';

const _codesJson = '''
[{"codeID":70,"code":"|","name":"Aanwezig","alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","alias":[
   {"aliasID":14,"codeID":497,"name":"Te laat zonder geldige reden"}]}]
''';

const _classJson = '''
{"groupID":298,"structID":311,"pupils":[
 {"movementID":35714,"userID":11110,"name":"Test Pupil","presence":[
   {"presenceID":1001,"presenceDate":"2026-09-30","studentID":11110,
    "hourID":null,"partOfDay":"am","codeID":70,"aliasID":null,
    "motivation":null,"deleteStatus":0}]}]}
''';

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

/// Smartschool's generic error page, as the Presence module sends it with a
/// `500` for a request it refuses.
const _errorPage = '''
<!DOCTYPE html>
<html>
    <head>
        <title></title>
        <meta charset="utf-8">
    </head>
    <body>
        <div id="#smscMain">
            <h1>Oeps, er ging iets mis</h1>
        </div>
    </body>
</html>
''';

typedef _Answer = ResponseBody Function();

ResponseBody _json(String body) =>
    _response(body, contentType: Headers.jsonContentType);

/// The Presence module refusing the request.
ResponseBody _refused() => _response(_errorPage, status: 500);

/// Smartschool refusing the session for an XHR/form POST (#8).
ResponseBody _unauthorized() => _response('', status: 401);

/// A redirect the HTTP client leaves unfollowed, as it does for a POST, with
/// the page Smartschool (Symfony) sends along with it.
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '<!DOCTYPE html>\n<html>\n<head>\n'
  '<meta http-equiv="refresh" content="0;url=\'$location\'" />\n'
  '<title>Redirecting to $location</title>\n</head>\n'
  '<body>Redirecting to <a href="$location">$location</a>.</body>\n</html>',
  302,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    'location': [location],
  },
);

/// The login page, reached through a redirect the HTTP client followed.
ResponseBody _landedOnLogin() => _page('/login', _loginPage, redirected: true);

ResponseBody _page(String at, String body, {required bool redirected}) {
  final response = _response(body);
  if (redirected) {
    response.redirects = [
      RedirectRecord(303, 'GET', Uri.parse('https://$_host$at')),
    ];
  }
  return response;
}

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

/// A Smartschool whose Presence endpoints answer from [answers].
///
/// With [sessionAccepted] false, the Presence endpoints answer with [refusal]
/// (by default a bare `401`, as Smartschool does for an XHR/form POST on an
/// expired session) until the client has gone through password and 2FA
/// again; they then answer with [afterLogin] when given, or else from
/// [answers].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    this.answers, {
    this.sessionAccepted = true,
    this.afterLogin,
    this.refusal = _unauthorized,
  });

  final Map<String, _Answer> answers;
  final bool sessionAccepted;
  final _Answer? afterLogin;
  final _Answer refusal;

  bool _passwordDone = false;
  bool _twoFaDone = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  int posts(String path) => log.where((l) => l == 'POST $path').length;

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
      return _redirect('/');
    }
    if (path == '/2fa/api/v1/config') {
      return _json(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      _twoFaDone = true;
      return _json('{"success":true,"redirectTo":"/"}');
    }

    if (path.startsWith('/Presence/')) {
      final loggedIn = _passwordDone && _twoFaDone;
      if (!sessionAccepted && !loggedIn) return refusal();
      if (loggedIn && afterLogin != null) return afterLogin!();
      final answer = answers[path];
      return answer == null ? _response('', status: 404) : answer();
    }

    // A page request: redirected to wherever the session is in the chain.
    if (!_passwordDone) {
      return _page('/login', _loginPage, redirected: path != '/login');
    }
    if (!_twoFaDone) {
      return _page('/2fa', '<html><body>2fa</body></html>', redirected: true);
    }
    return _page(path, '<html><body>home</body></html>', redirected: false);
  }

  @override
  void close({bool force = false}) {}
}

/// The Presence endpoints of an account that may record presences for the
/// class: [save] answers the save.
Map<String, _Answer> _recordable({required _Answer save}) => {
  _getConfig: () => _json(_configJson),
  _getAllCodes: () => _json(_codesJson),
  _getClass: () => _json(_classJson),
  _save: save,
};

Future<void> _setLate(PresenceService presence) => presence.setLate(
  userId: 11110,
  classGroupId: 298,
  date: DateTime(2026, 9, 30),
  part: DayPart.morning,
);

/// "Sign in again": a [SmartschoolSessionExpiredError], which an existing
/// `on SmartschoolAuthenticationError` catches, and not a Presence refusal.
Matcher _sessionExpired({Object? message = anything}) => allOf(
  isA<SmartschoolAuthenticationError>(),
  isNot(isA<SmartschoolPresenceError>()),
  isA<SmartschoolSessionExpiredError>().having(
    (e) => e.message,
    'message',
    message,
  ),
);

/// "Give up": a [SmartschoolPresenceError], not an authentication failure.
Matcher _presenceRefusal({Object? message = anything}) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolPresenceError>().having((e) => e.message, 'message', message),
);

void main() {
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(
    Map<String, _Answer> answers, {
    bool sessionAccepted = true,
    _Answer? afterLogin,
    _Answer refusal = _unauthorized,
  }) async {
    final server = _Smartschool(
      answers,
      sessionAccepted: sessionAccepted,
      afterLogin: afterLogin,
      refusal: refusal,
    );
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_presence_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group('the Presence module refuses the request (#5)', () {
    test('an error page for getConfig is a SmartschoolPresenceError, and '
        'does not start a login', () async {
      final server = await serve({_getConfig: _refused});

      await expectLater(
        PresenceService(client).getConfig(),
        throwsA(
          _presenceRefusal(
            message: allOf(contains('HTTP 500'), isNot(contains('expired'))),
          ),
        ),
      );
      expect(server.log, ['POST $_getConfig']);
    });

    test('an error page for getClass is a SmartschoolPresenceError', () async {
      await serve({_getClass: _refused});

      await expectLater(
        PresenceService(client).getClassPupils(
          classGroupId: 298,
          date: DateTime(2026, 9, 30),
          schoolyearRefDate: '2026-09-01',
        ),
        throwsA(_presenceRefusal()),
      );
    });

    test('setLate: a save answered with an error page is a '
        'SmartschoolPresenceError', () async {
      final server = await serve(_recordable(save: _refused));

      await expectLater(
        _setLate(PresenceService(client)),
        throwsA(_presenceRefusal()),
      );
      expect(server.posts(_save), 1);
    });

    test('a redirect off the login chain is not a session problem', () async {
      await serve({_getConfig: () => _redirect('/')});

      await expectLater(
        PresenceService(client).getConfig(),
        throwsA(_presenceRefusal()),
      );
    });
  });

  group('the login chain answers a Presence request (#5, #22)', () {
    test('a redirect to /login is a SmartschoolSessionExpiredError, after '
        'logging in again and retrying once', () async {
      // Before #5: SmartschoolPresenceError ("The session may have expired,
      // or the account lacks Presence access"). Before #22: the same error
      // type, but thrown by PresenceService itself, without logging in again.
      final server = await serve({_getConfig: () => _redirect('/login')});

      await expectLater(
        PresenceService(client).getConfig(),
        throwsA(_sessionExpired(message: contains('/login'))),
      );
      expect(server.posts(_getConfig), 2, reason: 'retried once');
      expect(server.posts('/login'), 1, reason: 'logged in once');
    });

    test('a redirect to /2fa is a SmartschoolSessionExpiredError, after '
        'logging in again and retrying once', () async {
      final server = await serve({_getAllCodes: () => _redirect('/2fa')});

      await expectLater(
        PresenceService(client).getAllCodes(311),
        throwsA(_sessionExpired(message: contains('/2fa'))),
      );
      expect(server.posts(_getAllCodes), 2, reason: 'retried once');
      expect(server.posts('/login'), 1, reason: 'logged in once');
    });

    test('setLate: a save redirected to /login is a '
        'SmartschoolSessionExpiredError, after logging in again and retrying '
        'once', () async {
      final server = await serve(_recordable(save: () => _redirect('/login')));

      await expectLater(
        _setLate(PresenceService(client)),
        throwsA(_sessionExpired()),
      );
      expect(server.posts(_save), 2, reason: 'retried once');
    });

    test('a redirect to /login that the retry after logging in again no '
        'longer gets returns the data (#22)', () async {
      // Before the fix: SmartschoolSessionExpiredError, without logging in
      // again.
      final server = await serve(
        {_getConfig: () => _json(_configJson)},
        sessionAccepted: false,
        refusal: () => _redirect('/login'),
      );

      final config = await PresenceService(client).getConfig();

      expect(config.classForGroup(298)?.structId, 311);
      expect(server.posts(_getConfig), 2, reason: 'redirect, then the retry');
      expect(server.posts('/2fa/api/v1/google-authenticator'), 1);
    });

    test('a retry that lands on the login page again is a '
        'SmartschoolSessionExpiredError', () async {
      final server = await serve(
        const {},
        sessionAccepted: false,
        afterLogin: _landedOnLogin,
      );

      await expectLater(
        PresenceService(client).getConfig(),
        throwsA(_sessionExpired()),
      );
      expect(server.posts(_getConfig), 2, reason: 'retried once');
      expect(server.posts('/2fa/api/v1/google-authenticator'), 1);
    });
  });

  group('a 401 on a Presence request (#5, on top of #8)', () {
    test('a retry that is still refused is a SmartschoolSessionExpiredError '
        'and keeps its message', () async {
      // Before the fix: the base SmartschoolAuthenticationError.
      final server = await serve(
        const {},
        sessionAccepted: false,
        afterLogin: () => _response('', status: 401),
      );

      await expectLater(
        PresenceService(client).getConfig(),
        throwsA(_sessionExpired(message: contains('still answered 401'))),
      );
      expect(server.posts(_getConfig), 2);
    });

    test('an accepted retry returns the data', () async {
      final server = await serve(
        _recordable(save: () => _json('{"hasErrors":false,"errors":[]}')),
        sessionAccepted: false,
      );

      await _setLate(PresenceService(client));

      expect(server.posts(_getConfig), 2, reason: '401, then the retry');
      expect(server.posts(_save), 1);
    });
  });

  group('a caller can act on the type (#5)', () {
    Future<String> classify(Future<void> Function() call) async {
      try {
        await call();
        return 'ok';
      } on SmartschoolSessionExpiredError {
        return 'sign in again';
      } on SmartschoolPresenceError {
        return 'give up';
      }
    }

    test('a refused save and an expired session take opposite paths', () async {
      await serve(_recordable(save: _refused));
      expect(
        await classify(() => _setLate(PresenceService(client))),
        'give up',
      );
      await client.dispose();

      await serve(_recordable(save: () => _redirect('/login')));
      expect(
        await classify(() => _setLate(PresenceService(client))),
        'sign in again',
      );
    });
  });
}
