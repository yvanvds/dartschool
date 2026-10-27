// Tests for issue #194: SkoreService.getClasses was answered once with
// Smartschool's start page, right after the client logged in again with 2FA,
// and its error quoted only the start of that page, Smartschool's banner in
// an HTML comment, so which page it was could not be told.
//
// Seen live (read-only, 2026-10-27, test/live/skore_access_live_test.dart):
//   1. The GET of the list of report models
//      (`/modules/Skore/modules/rapportbeheer/data.php?...select_models`)
//      sent without a session is redirected to `/`, and `/` on to `/login`:
//      the client follows both and ends on the login page, so it logs in
//      and sends the GET again.
//   2. With the login's opening of the start page after the 2FA step (#192)
//      switched off, the GET sent again right after the login was redirected
//      to `/` and ended there with `200`: Smartschool's start page, which it
//      serves at `/` in a session it accepts, with the header
//      `smsc-module: Homepage` (also seen on a GET of `/`). That is the answer
//      of #194. Sent once more, the GET gave the list: following the
//      redirect had loaded the start page, after which Skore accepted the
//      session (#192). With the start page opened by the login, the GET
//      sent again gives the list at once.
//
// So a GET of SkoreService that ends on `/` after a redirect (without a
// query: Skore's refusal to an account without the rights goes to
// `/?module=Homepage`, #91) is sent once more, and when it ends there again,
// it is a SmartschoolSessionExpiredError. An HTML page instead of the JSON of
// the list is an error that names the page (where it ended, its module, the
// redirects that led there; by path and module only), not its start.
//
// The fake Smartschool keeps the session state itself and ignores the
// cookies the client sends, as the one in session_login_chain_retry_test.dart.
// The start page is made up (school "Voorbeeldschool", user "Wim Willems").
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
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

const _modelsPath = '/modules/Skore/modules/rapportbeheer/data.php';
const _ownersPagePath =
    '/turbowidgets_dev/skore/templates/module/owners/template.php';

/// The requests of the two reads, as the fake logs them.
const _models = 'GET $_modelsPath';
const _ownersPage = 'GET $_ownersPagePath';

/// The login chain that the GET of a read without a session starts: the
/// login page in a new session (#45), the password, the 2FA step, and the
/// start page, which the login opens after it as a browser does (#192).
const _login = [
  'GET /login',
  'POST /login',
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
  'GET /',
];

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

/// Smartschool's start page, trimmed: its banner, its title (the school's
/// name) and the script with the signed-in user, all made up.
const _startPage = r'''


<!DOCTYPE html>
<!--
  ___ __  __   _   ___ _____ ___  ___ _  _  ___   ___  _
 / __|  \/  | /_\ | _ \_   _/ __|/ __| || |/ _ \ / _ \| |
 \__ \ |\/| |/ _ \|   / | | \__ \ (__| __ | (_) | (_) | |__
 |___/_|  |_/_/ \_\_|_\ |_| |___/\___|_||_|\___/ \___/|____|

-->
<html lang="nl">
    <head>
                    <title>Voorbeeldschool - Smartschool</title>
            <meta charset="utf-8">
    </head>
    <body class=" modern-ui">
        <script type="text/javascript">$.extend(true, SMSC, JSON.parse('{"vars":{"authenticatedUser":{"id":"4069_1005_0","name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"}},"ssID":4069}}'));</script>
    </body>
</html>
''';

/// Smartschool's generic error page, with the banner.
const _errorPage = '''
<!DOCTYPE html>
<!--
  ___ __  __   _   ___ _____ ___  ___ _  _  ___   ___  _
-->
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

/// A Skore administrator's list of report models (#70), trimmed.
const _modelsJson =
    '{"content":"Modellen","data":{"item":"models","func":1},"children":['
    '{"content":"&nbsp;3gr D-D/A","data":{"item":"model","func":"176",'
    '"modelname":"3gr D-D/A"},"children":[{"content":"&nbsp;Leden","data":'
    '{"item":"members","func":"176"},"children":[{"content":"&nbsp;5DG",'
    '"data":{"item":"childmember","func":"176_492","groupname":"5DG"},'
    '"children":[{"content":"&nbsp;5WW1","data":{"item":"classroom",'
    '"func":"2516"}}]}]}]}]}';

/// The assignments page of class 2516, trimmed to one course.
const _ownersPageHtml = '''
<table class="ownertable"><tr>
<td><div class="owners_v" style="margin-left:0px">Digitale vaardigheden [DIGI]</div></td>
<td><div dojoType="ownercontainer" courseID="1588" coursename="Digitale vaardigheden" classID="2516">
<div dojoType="ownernode" ownerID="9001" userID="1001">Janssens, Jan</div>
</div></td>
</tr></table>
''';

/// A Smartschool whose Skore answers its two reads as it did live (see
/// above): a GET without a session is redirected through `/` to `/login`,
/// and one in a session that Skore does not accept yet through `/` to the
/// start page, which loads it.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.loggedIn = true,
    this.startPageLoaded = true,
    this.alwaysToSiteRoot = false,
    this.answers = const {},
  });

  /// Whether Smartschool accepts the session.
  bool loggedIn;

  /// Whether the start page was loaded since the last login: until then,
  /// Skore sends a request on to `/` (seen live, #192, #194).
  bool startPageLoaded;

  /// Whether Skore sends its reads on to `/` also after the start page was
  /// loaded (not seen).
  final bool alwaysToSiteRoot;

  /// Answers that replace the above, by request (as in [log]).
  final Map<String, ResponseBody Function()> answers;

  bool _passwordDone = false;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final request = '${options.method} $path';
    log.add(request);
    final replaced = answers[request];
    if (replaced != null) return replaced();

    switch (request) {
      case 'POST /login':
        _passwordDone = true;
        return _redirect('/');
      case 'GET /2fa/api/v1/config':
        return _json(
          '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        loggedIn = true;
        startPageLoaded = false;
        return _json('{"success":true,"redirectTo":"/"}');
    }
    if (options.method != 'GET') {
      fail('Unexpected request: ${options.method} ${options.uri}');
    }

    if (!loggedIn) {
      // A page request: redirected to where the session is in the chain;
      // Skore's reads first to `/`, which sends them on.
      final skore = path == _modelsPath || path == _ownersPagePath;
      final at = _passwordDone ? '/2fa' : '/login';
      return _page(
        _passwordDone ? '<html>2fa</html>' : _loginPage,
        via: [if (skore) '/', if (path != at) at],
      );
    }
    if (path == '/') {
      startPageLoaded = true;
      return _startPageAnswer();
    }
    if (path == _modelsPath || path == _ownersPagePath) {
      if (!startPageLoaded || alwaysToSiteRoot) {
        // Followed by the client: the start page, which loads it.
        startPageLoaded = true;
        return _startPageAnswer(via: ['/']);
      }
      return path == _modelsPath ? _page(_modelsJson) : _page(_ownersPageHtml);
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// An HTML page, reached by following the redirects to [via]: paths on the
/// fake's host, or URLs of another (absolute, as the HTTP client reports
/// them).
ResponseBody _page(
  String body, {
  List<String> via = const [],
  Map<String, List<String>> headers = const {},
}) =>
    ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
          ...headers,
        },
      )
      ..redirects = [
        for (final at in via)
          RedirectRecord(
            302,
            'GET',
            Uri.parse(at.startsWith('/') ? 'https://$_host$at' : at),
          ),
      ];

/// The start page, as Smartschool serves it at `/`: with its module in the
/// `smsc-module` header (seen live).
ResponseBody _startPageAnswer({List<String> via = const []}) => _page(
  _startPage,
  via: via,
  headers: {
    'smsc-module': ['Homepage'],
  },
);

ResponseBody _json(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// A redirect that the HTTP client leaves unfollowed, as it does after a
/// POST.
ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  302,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    'location': [location],
  },
);

/// A message that names a page by path and module, and holds nothing of the
/// page itself: not its banner, its title (the school) or the user.
Matcher _namesThePage(String page) => allOf(
  contains(page),
  isNot(contains('___')),
  isNot(contains('DOCTYPE')),
  isNot(contains('Voorbeeldschool')),
  isNot(contains('Willems')),
  isNot(contains('Oeps')),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SkoreService)> serve(_Smartschool server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return (server, SkoreService(client));
  }

  group('a read in a session that expired (seen live, #194):', () {
    test('getClasses: the GET is sent on through / to the login chain; '
        'after the login, which opens the start page after the 2FA step, it '
        'is sent again once and gives the classes', () async {
      final (server, skore) = await serve(_Smartschool(loggedIn: false));

      final classes = await skore.getClasses();

      expect(classes.map((c) => c.id), [2516]);
      expect(server.log, [_models, ..._login, _models]);
    });

    test('getCourses: the same', () async {
      final (server, skore) = await serve(_Smartschool(loggedIn: false));

      final courses = await skore.getCourses(2516);

      expect(courses.map((c) => c.id), [1588]);
      expect(server.log, [_ownersPage, ..._login, _ownersPage]);
    });
  });

  group('a read that Skore sends on to the start page at / (a session it '
      'does not accept until the start page was loaded, #192) is sent once '
      'more:', () {
    test('getClasses gives the classes, without a login', () async {
      final (server, skore) = await serve(_Smartschool(startPageLoaded: false));

      // Before the fix: "Skore answered the list of report models with an
      // HTML page instead of JSON: <!DOCTYPE html> <!-- ___ ...".
      final classes = await skore.getClasses();

      expect(classes.map((c) => c.id), [2516]);
      expect(server.log, [_models, _models]);
    });

    test('getCourses gives the courses, without a login', () async {
      final (server, skore) = await serve(_Smartschool(startPageLoaded: false));

      // Before the fix: "The assignments page holds no table of courses:
      // <!DOCTYPE html> <!-- ___ ...".
      final courses = await skore.getCourses(2516);

      expect(courses.map((c) => c.id), [1588]);
      expect(server.log, [_ownersPage, _ownersPage]);
    });

    test(
      'sent on to / again: a SmartschoolSessionExpiredError that names '
      'the page by path and module, after two GETs, without a login',
      () async {
        final (server, skore) = await serve(
          _Smartschool(alwaysToSiteRoot: true),
        );

        await expectLater(
          skore.getClasses(),
          throwsA(
            isA<SmartschoolSessionExpiredError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('the list of report models'),
                _namesThePage('/ (module Homepage), after a redirect to /'),
              ),
            ),
          ),
        );
        expect(server.log, [_models, _models]);
      },
    );

    test("Skore's refusal to an account without the rights "
        '(/?module=Homepage, #91) is not sent once more', () async {
      final (server, skore) = await serve(
        _Smartschool(
          answers: {
            _models: () => _startPageAnswer(via: ['/?module=Homepage']),
          },
        ),
      );

      await expectLater(
        skore.getClasses(),
        throwsA(isA<SmartschoolSkoreAccessDeniedError>()),
      );
      expect(server.log, [_models]);
    });
  });

  group('an HTML page instead of the list of report models: the error names '
      'the page, not its start', () {
    test('a page that a redirect led to', () async {
      final (server, skore) = await serve(
        _Smartschool(
          answers: {
            _models: () => _page(
              _errorPage,
              via: ['/?module=Messages&id=1234'],
              headers: {
                'smsc-module': ['Messages'],
              },
            ),
          },
        ),
      );

      // Before the fix: "... with an HTML page instead of JSON: <!DOCTYPE
      // html> <!-- ___ ...".
      await expectLater(
        skore.getClasses(),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(
                'the list of report models with an HTML page instead '
                'of JSON',
              ),
              _namesThePage(
                '/?module=Messages, after a redirect to /?module=Messages.',
              ),
              // The rest of a query can hold IDs.
              isNot(contains('1234')),
            ),
          ),
        ),
      );
      expect(server.log, [_models]);
    });

    test('a page at the requested URL, with its module from the '
        'smsc-module header', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            _models: () => _page(
              _errorPage,
              headers: {
                'smsc-module': ['Skore'],
              },
            ),
          },
        ),
      );

      await expectLater(
        skore.getClasses(),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            _namesThePage('JSON: $_modelsPath (module Skore).'),
          ),
        ),
      );
    });

    test('a page that two redirects led to, through another host: each by '
        'its path and module, the host when it is another one', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            _models: () => _page(
              _errorPage,
              via: [
                'https://other.smartschool.be/sso?id=5',
                '/?module=Messages&id=7',
              ],
            ),
          },
        ),
      );

      await expectLater(
        skore.getClasses(),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            allOf(
              _namesThePage(
                'JSON: /?module=Messages, after redirects to '
                'https://other.smartschool.be/sso, then /?module=Messages.',
              ),
              isNot(contains('id=')),
            ),
          ),
        ),
      );
    });
  });
}
