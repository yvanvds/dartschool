// Tests for issue #192: `SkoreGradebookService.getGradebook` failed for the
// developer's own behaviour gradebook ("Gedrag") with "Skore answered the RPC
// call init of its gradebook with HTTP 302", which did not say where the
// redirect pointed.
//
// What the read-only research found (2026-10-27):
//   - in a valid session, `init` of that gradebook is answered as for any
//     other gradebook (HTTP 200), in the same shape: the rows of its class,
//     `ownerMap`, ... It has no evaluation periods: `periods` `[]` and
//     `activePeriodE` `-1`, with one report period in `reports` (the same
//     `R1D` "Rapport 1" as the other gradebooks of the class's model);
//   - Skore answers an RPC call in a session Smartschool does not accept
//     (sent without a session cookie, or with one Smartschool does not know)
//     with `302`, `Location: /` and an empty body, with or without
//     `X-Requested-With`: `init` and `getNavigation` of the gradebook RPC,
//     and `getTeachers` and `getCourses` of the admin side. A GET of `/`
//     without a session is redirected to `/login`;
//   - after a login with 2FA (the developer's account has it), Skore answers
//     its RPC calls in the same way, until the start page was loaded once in
//     the new session: a browser opens it after the 2FA answer (`redirectTo`
//     "/"), the client did not.
// So the 302 of the report was a session that had expired, which the client
// did not take for one: no login, no retry. The client now does, and opens
// the start page after the 2FA step, so that the call sent again is answered
// (session_login_chain_retry_test.dart tests both on the client itself);
// and the error of any other redirect names its target, by path and
// `module` only.
//
// The behaviour gradebook below is in the shape of that capture, written by
// hand: the gradebook, class, group, model, course and report period IDs are
// Skore's own, as in the other gradebook tests; the pupils (names and
// `alternate`) are fakes of test/fixtures/lvs/FAKES.md, their user IDs are
// made up, as are the class and group names, and the rows carry no tooltip.
// Nothing here reaches Skore: the fake fails the test on any other RPC
// method than `init`, and on any other request than the reads of the current
// user and a login.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/services/skore_rpc.dart';
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

const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';

/// The logged-in teacher (a fake user ID).
const _me = 1005;

/// Smartschool's start page, where the client reads the logged-in user.
const _startPage =
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"4069_${_me}_0","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

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

/// The behaviour gradebook as `getGradebooks` reads it.
const _gedrag = SkoreGradebook(
  gradebookId: 35158,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 492,
  groupName: '4XX',
  classId: 2516,
  className: '4XY',
  courseId: 2890,
  courseName: 'Gedrag (A-stroom, D/A en D) (4e j)',
  workyearId: 24,
  teacherNames: ['Janssens Jan'],
);

/// The rows of the behaviour gradebook: the class average and three pupils.
final _rows = {
  'orientation': 'byColumn',
  'rowHeader': {
    'sort': [
      'clavg_2516',
      'pupil_1401_2516',
      'pupil_1402_2516',
      'pupil_1403_2516',
    ],
    'styles': ['background:#eeeeee;font-weight:bold;', null, null, null],
    'classes': [null, 'gradebook_odd', 'gradebook_even', 'gradebook_odd'],
  },
  'colHeader': {
    'sort': [0],
  },
  'stream': [
    {'c': 0, 'r': 'clavg_2516', 'v': '4XY : Klasgemiddelde'},
    for (final (id, number, name, alternate) in [
      (1401, 1, 'Peeters, Lars', 'TGFycyBQZWV0ZXJz'),
      (1402, 2, 'Peeters, Marie', 'TWFyaWUgUGVldGVycw=='),
      (1403, 3, 'Van den Broeck, Noor', 'Tm9vciBWYW4gZGVuIEJyb2Vjaw=='),
    ])
      {
        'c': 0,
        'r': 'pupil_${id}_2516',
        'v':
            '<span encoding="base64" skoretooltip="true" '
            'alternate="$alternate">$number.  $name</span>'
            '<span style="position:absolute; right:20px;top:2px;"></span>',
      },
  ],
};

/// `init` of the behaviour gradebook, in the shape of the capture: no
/// evaluation periods (`periods` `[]`, `activePeriodE` `-1`), one report
/// period.
final _behaviourInit = jsonEncode({
  'result': {
    'left_0': _rows,
    'left_1': _rows,
    'left_2': _rows,
    'periods': <Object>[],
    'reports': [
      {
        'name': 'R1D',
        'fullname': 'Rapport 1',
        'id': '2762',
        'info':
            '<p><u><b>R1D</b></u></p><p>Open tot en met 2026-10-30 '
            '23:00</p>',
        'open': 1,
        'type': 'a',
        'rating': 0,
        'timestamp': '2026-10-30T23:00:00+0100',
        'lockIcon': 0,
      },
    ],
    'activePeriodE': -1,
    'activePeriodP': -1,
    'activeReport': 0,
    'projectAdmin': 1,
    'classesMap': {
      '_492': ['2516'],
    },
    'skoreClasses': {'_2482': '4AB', '_2512': '4CDE', '_2516': '4XY'},
    'virtualClasses': null,
    'coursesMap': {'_2890': 'Gedrag'},
    'ownerMap': [
      {
        'courseID': '2890',
        'groupID': '492',
        'coursename': 'Gedrag',
        'ownerID': '35158',
        'classID': '2516',
      },
    ],
    'allowEvaluationTypes': null,
    'wystring': '2026 - 2027',
    'isRestrictedAccess': 0,
  },
  'session': 1,
  'method': 'init',
  'timelimit': 0,
  'limitInfo': 'Y',
});

/// A Smartschool whose Skore gradebook answers `init` of the behaviour
/// gradebook, and refuses a session as Skore does: a `302` to `/` with an
/// empty body (seen live, #192), also after a login with 2FA, until the
/// start page was loaded in the new session (seen live too).
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.sessionAccepted = true,
    this.acceptedAfterLogin = true,
    this.refusedTo = '/',
    this.initRedirect,
    this.initRedirectWithoutLocation = false,
  });

  /// Whether Smartschool accepts the client's session; a login sets it to
  /// [acceptedAfterLogin].
  bool sessionAccepted;

  /// Whether Smartschool accepts the session of a login; `false` keeps
  /// refusing it.
  final bool acceptedAfterLogin;

  /// Where Skore sends an RPC call in a session Smartschool does not accept:
  /// `/` (seen live).
  final String refusedTo;

  /// Where Skore redirects `init` in a session it accepts, or `null` for its
  /// answer.
  final String? initRedirect;

  /// Whether Skore answers `init` in a session it accepts with a redirect
  /// without a `Location`.
  final bool initRedirectWithoutLocation;

  /// Whether the password of a login went through, and its 2FA step is
  /// next.
  bool _passwordDone = false;

  /// Whether the start page was loaded since the last login.
  bool _startPageSinceLogin = true;

  /// Every request that reached it, as `METHOD path` (`RPC <method>` for an
  /// RPC call).
  final List<String> requests = [];

  /// The requests from the first RPC call on.
  List<String> get fromRpc {
    final first = requests.indexWhere((r) => r.startsWith('RPC '));
    return first < 0 ? const [] : requests.sublist(first);
  }

  static ResponseBody _body(String body, {int status = 200, String? type}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [type ?? 'text/html; charset=UTF-8'],
        },
      );

  /// Skore's redirect of a POST: a `302` with an empty body.
  static ResponseBody _redirect(String? location) => ResponseBody.fromString(
    '',
    302,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
      if (location != null) 'location': [location],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    switch ((options.method, path)) {
      case ('GET', '/'):
        requests.add('GET /');
        if (_passwordDone) {
          // The password went through: on to the 2FA step.
          return _body('<html>2fa</html>')
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
            ];
        }
        _startPageSinceLogin = true;
        return _body(_startPage);
      case ('GET', '/course-list/api/v1/courses'):
        requests.add('GET $path');
        return _body('[{"platformId":4069}]', type: 'application/json');
      case ('GET', '/login'):
        requests.add('GET /login');
        return _body(_loginPage);
      case ('POST', '/login'):
        requests.add('POST /login');
        _passwordDone = true;
        return _redirect('/');
      case ('GET', '/2fa/api/v1/config'):
        requests.add('GET $path');
        return _body(
          '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
          type: 'application/json',
        );
      case ('POST', '/2fa/api/v1/google-authenticator'):
        requests.add('POST $path');
        _passwordDone = false;
        sessionAccepted = acceptedAfterLogin;
        _startPageSinceLogin = false;
        return _body(
          '{"success":true,"redirectTo":"/"}',
          type: 'application/json',
        );
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Never let anything else through: only the read of the gradebook.
        expect(method, 'init');
        requests.add('RPC $method');
        if (!sessionAccepted) return _redirect(refusedTo);
        // A session that got past the 2FA step is refused the same way until
        // the start page was loaded in it (seen live).
        if (!_startPageSinceLogin) return _redirect('/');
        if (initRedirectWithoutLocation) return _redirect(null);
        final redirect = initRedirect;
        if (redirect != null) return _redirect(redirect);
        return _body(_behaviourInit, type: 'application/json; charset=utf-8');
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// A plain [SmartschoolSkoreError] with [message]: an answer the service
/// cannot use, not an authentication failure.
Matcher _skoreError(Object? message) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// The login with 2FA a refused call starts, then the start page, and the
/// call sent again.
const _loginAndRetry = [
  'RPC init',
  'GET /login',
  'POST /login',
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
  'GET /',
  'RPC init',
];

void main() {
  forbidRealNetwork();

  Future<SkoreGradebookService> serve(_Smartschool server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return SkoreGradebookService(client);
  }

  /// Checks [sheet], the behaviour gradebook as `getGradebook` reads it.
  void expectBehaviourGradebook(SkoreGradebookSheet sheet) {
    expect(sheet.gradebook, same(_gedrag));
    expect(sheet.courseName, 'Gedrag');
    expect(sheet.periods, isEmpty);
    expect(sheet.activePeriod, isNull);
    expect(sheet.writable, isFalse);
    expect(sheet.isCoordinator, isFalse);
    expect(sheet.pupils.map((p) => (p.id, p.number, p.name, p.displayName)), [
      (1401, 1, 'Peeters, Lars', 'Lars Peeters'),
      (1402, 2, 'Peeters, Marie', 'Marie Peeters'),
      (1403, 3, 'Van den Broeck, Noor', 'Noor Van den Broeck'),
    ]);
    expect(sheet.pupils.map((p) => p.classId), everyElement(2516));
  }

  group('the behaviour gradebook (#192)', () {
    test('its init in the captured shape: read with its pupils, without '
        'evaluation periods, and without asking getGradebookContext', () async {
      final server = _Smartschool();
      final gradebooks = await serve(server);

      expectBehaviourGradebook(await gradebooks.getGradebook(_gedrag));
      expect(server.fromRpc, ['RPC init']);
    });
  });

  group('an RPC call that Skore redirects (#192)', () {
    test(
      'to /, its answer in a session Smartschool does not accept: the '
      'client logs in, sends the call again and the gradebook is read',
      () async {
        final server = _Smartschool(sessionAccepted: false);
        final gradebooks = await serve(server);

        // Before the fix: SmartschoolSkoreError "Skore answered the RPC call
        // init of its gradebook with HTTP 302.", without a login.
        expectBehaviourGradebook(await gradebooks.getGradebook(_gedrag));
        expect(server.fromRpc, _loginAndRetry);
      },
    );

    test('to the login chain: the client logs in and sends the call '
        'again', () async {
      final server = _Smartschool(sessionAccepted: false, refusedTo: '/login');
      final gradebooks = await serve(server);

      expectBehaviourGradebook(await gradebooks.getGradebook(_gedrag));
      expect(server.fromRpc, _loginAndRetry);
    });

    test('to / again after the login: a SmartschoolSessionExpiredError, '
        'without a second login', () async {
      final server = _Smartschool(
        sessionAccepted: false,
        acceptedAfterLogin: false,
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getGradebook(_gedrag),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('login chain (/, on to /login)'),
          ),
        ),
      );
      expect(server.fromRpc, _loginAndRetry);
    });

    test('to the start page in a session Smartschool accepts: a '
        'SmartschoolSkoreError that names it, without a login', () async {
      final server = _Smartschool(initRedirect: '/?module=Homepage');
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getGradebook(_gedrag),
        throwsA(
          _skoreError(
            'Skore answered the RPC call init of its gradebook with HTTP '
            '302, a redirect to /?module=Homepage.',
          ),
        ),
      );
      expect(server.fromRpc, ['RPC init']);
    });

    test('elsewhere: the error names its path and module, not the rest of '
        'its query', () async {
      final server = _Smartschool(
        initRedirect:
            '/index.php?module=Skore&ownerID=35158&pupil=1401&name=Marie#top',
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getGradebook(_gedrag),
        throwsA(
          _skoreError(
            allOf(
              endsWith('with HTTP 302, a redirect to /index.php?module=Skore.'),
              isNot(contains('1401')),
              isNot(contains('Marie')),
            ),
          ),
        ),
      );
      expect(server.fromRpc, ['RPC init']);
    });

    test('without a Location: the error says so', () async {
      final server = _Smartschool(initRedirectWithoutLocation: true);
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getGradebook(_gedrag),
        throwsA(
          _skoreError(
            endsWith('with HTTP 302, a redirect without a Location.'),
          ),
        ),
      );
    });
  });

  group('SkoreRpc.redirectNote', () {
    Response<String> answer(int status, {String? location}) => Response(
      requestOptions: RequestOptions(path: 'https://$_host$_rpcPath'),
      statusCode: status,
      headers: Headers.fromMap({
        if (location != null) 'location': [location],
      }),
    );

    test('names the path and module of a redirect, and the host when it is '
        'another one', () {
      expect(
        SkoreRpc.redirectNote(answer(302, location: '/')),
        ', a redirect to /',
      );
      expect(
        SkoreRpc.redirectNote(answer(301, location: '/?module=Homepage')),
        ', a redirect to /?module=Homepage',
      );
      expect(
        SkoreRpc.redirectNote(
          answer(303, location: 'https://$_host/login?redirect=%2Fx'),
        ),
        ', a redirect to /login',
      );
      expect(
        SkoreRpc.redirectNote(
          answer(307, location: 'https://elsewhere.example/a/b?id=7'),
        ),
        ', a redirect to https://elsewhere.example/a/b',
      );
      expect(
        SkoreRpc.redirectNote(answer(302, location: 'gradebook?id=7')),
        ', a redirect to /modules/Skore/backend/gradebook/gradebook',
      );
    });

    test('a redirect without a Location, or with one that is not a URL', () {
      expect(
        SkoreRpc.redirectNote(answer(302)),
        ', a redirect without a Location',
      );
      expect(
        SkoreRpc.redirectNote(answer(302, location: 'http://[::1')),
        ', a redirect to a Location that is not a URL',
      );
    });

    test('nothing for an answer that is not a redirect', () {
      for (final status in [200, 204, 400, 401, 404, 500]) {
        expect(
          SkoreRpc.redirectNote(answer(status, location: '/')),
          '',
          reason: '$status',
        );
      }
    });
  });
}
