// Tests for issue #91: what Skore answers an account without the rights, as
// a SmartschoolSkoreAccessDeniedError with its area, and
// `SkoreService.checkAccess`.
//
// Captured live (read-only, 2026-10-04) with a teacher account whose "Skore
// administrator" right was switched off for the capture, through the
// library's own client (its user agent; GETs follow redirects, POSTs do
// not):
//   1. GET /modules/Skore/modules/rapportbeheer/data.php
//        ?skajax_respons_type=JSON&skajax_function=select_models
//   2. GET /turbowidgets_dev/skore/templates/module/owners/template.php
//        ?classID=2516
//      Both: 302 with `Location: /?module=Homepage`, followed to Smartschool's
//      start page: 200, text/html; charset=UTF-8, the whole start page (61 KB),
//      `realUri` /?module=Homepage.
//   3. POST /modules/Skore/backend/models/owners.php, rpc_method getTeachers
//   4. POST /modules/Skore/modules/rapportbeheer/rpc/data.php, rpc_method
//      getCourses, rpc_params [<the account's own user ID>]
//      Both: 302 with `Location: /?module=Homepage`, text/html;
//      charset=UTF-8, an empty body.
// No call answered with an empty result, and none with HTTP 403. The start
// page below is trimmed to its frame and to the script with the
// authenticated user (made up: user 1005, "Wim Willems"); the school's name
// and host are replaced. A pupil account, and an account with only one of
// the two rights, were not available: their answers were not captured. The
// answers of a Skore administrator are the captures of #70 and #74, in
// skore_service_test.dart and skore_service_share_test.dart; the trimmed
// ones below serve checkAccess.
//
// Skore drives the school's grading and reports: the fake Smartschool fails
// the test on any RPC method other than the reads getTeachers (owners.php)
// and getCourses (data.php), and saveShared where a test allows it.
import 'dart:convert';
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
const _ownersRpcPath = '/modules/Skore/backend/models/owners.php';
const _gradebooksRpcPath = '/modules/Skore/modules/rapportbeheer/rpc/data.php';

/// The account's own user ID, as the start page names it.
const _me = 1005;

/// Where Skore sends every request of an account without the rights.
const _startPageLocation = '/?module=Homepage';

/// Smartschool's start page, trimmed: its frame, and the script that holds
/// the authenticated user (which `getCurrentUser` reads).
const _startPage = r'''
<!DOCTYPE html>
<html lang="nl">
    <head>
                    <title>Voorbeeldschool - Smartschool</title>
            <meta charset="utf-8">
    </head>
    <body class=" modern-ui">
        <div id="smscMain" class="smscMain " tabindex="-1">
<div id="container" class="homepage">
	<div id="leftcontainer" class="smsc-container--left homepage__left"></div>
	<div id="centercontainer" class="smsc-container--main homepage__center"></div>
</div>
<script type="text/javascript">
var _getItemsurl = '/?module=Homepage&function=getCalendarItems';
</script>
        </div>
        <script type="text/javascript">$.extend(true, SMSC, JSON.parse('{"vars":{"authenticatedUser":{"id":"4069_1005_0","name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"}},"ssID":4069}}'));</script>
    </body>
</html>
''';

/// A Skore administrator's answers (#70, #74), trimmed.
const _modelsJson =
    '{"content":"Modellen","data":{"item":"models","func":1},"children":['
    '{"content":"&nbsp;3gr D-D/A","data":{"item":"model","func":"176",'
    '"modelname":"3gr D-D/A"},"children":[{"content":"&nbsp;Leden","data":'
    '{"item":"members","func":"176"},"children":[{"content":"&nbsp;5DG",'
    '"data":{"item":"childmember","func":"176_492","groupname":"5DG"},'
    '"children":[{"content":"&nbsp;5WW1","data":{"item":"classroom",'
    '"func":"2516"}}]}]}]}]}';
const _teachersAnswer =
    '{"result":[{"userID":"1001","name":"Janssens, Jan"},'
    '{"userID":"1005","name":"Willems, Wim"}],"session":1,'
    '"method":"getTeachers","timelimit":0,"limitInfo":null}';
const _gradebooksAnswer =
    '{"result":[{"id":"34826","icon":"IconLib:laptop","name":"Digitale '
    'vaardigheden","class":"5WW1","readers":[],"writers":[]}],"session":1,'
    '"method":"getCourses","timelimit":0,"limitInfo":null}';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

/// A request as it reached the fake Smartschool: `GET <path>`, or
/// `RPC <method> <params>` for a Skore RPC call.
typedef _Request = String;

/// A Smartschool whose Skore refuses the parts in [denied] as it refused
/// them live (#91), and answers the others as it answers an administrator.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.denied = const {},
    this.redirectSave = false,
    this.answers = const {},
  });

  /// The parts of Skore the account lacks the rights for.
  final Set<SkoreAccessArea> denied;

  /// Whether a save (`saveShared`) is sent on to the start page.
  final bool redirectSave;

  /// Answers that replace the above, by request (as in [requests]).
  final Map<_Request, ResponseBody Function()> answers;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  static ResponseBody _html(String body, {int status = 200}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
        },
      );

  /// A GET that Skore sent on to [location], as the client gives it: the
  /// page it ends on, with the redirect it followed.
  static ResponseBody _followed(String location, String page) =>
      _html(page)
        ..redirects = [RedirectRecord(302, 'GET', Uri.parse(location))];

  /// A POST that Skore sent on to [location], as the client gives it: the
  /// redirect itself, with an empty body.
  static ResponseBody _redirect(String location) => ResponseBody.fromString(
    '',
    302,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
      'location': [location],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final data = options.data;
    final form = data is Map ? data : const {};
    final request = options.method == 'GET'
        ? 'GET $path'
        : 'RPC ${form['rpc_method']} ${form['rpc_params']}';
    requests.add(request);
    final replaced = answers[request];
    if (replaced != null) return replaced();

    bool refused(SkoreAccessArea area) => denied.contains(area);
    const report = SkoreAccessArea.reportManagement;
    const gradebooks = SkoreAccessArea.gradebookManagement;
    switch ((options.method, path)) {
      case ('GET', '/'):
        return _html(_startPage);
      case ('GET', '/course-list/api/v1/courses'):
        return ResponseBody.fromString(
          '[{"platformId":4069}]',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      case ('GET', _modelsPath):
        return refused(report)
            ? _followed(_startPageLocation, _startPage)
            : _html(_modelsJson);
      case ('GET', _ownersPagePath):
        return refused(report)
            ? _followed(_startPageLocation, _startPage)
            : _html('<table class="ownertable"></table>');
      case ('POST', _ownersRpcPath):
        // Never let a write through: only the read the service may call.
        expect(form['rpc_method'], 'getTeachers');
        return refused(report)
            ? _redirect(_startPageLocation)
            : _html(_teachersAnswer);
      case ('POST', _gradebooksRpcPath):
        final method = form['rpc_method'];
        if (method == 'saveShared' && redirectSave) {
          return _redirect(_startPageLocation);
        }
        expect(method, 'getCourses');
        return refused(gradebooks)
            ? _redirect(_startPageLocation)
            : _html(_gradebooksAnswer);
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

const _reportManagement = "Skore's report management (Rapporten > Modellen)";
const _gradebookManagement = "Skore's gradebook management (Puntenboeken)";

/// A [SmartschoolSkoreAccessDeniedError] for [area], for an answer that sent
/// the request on to the start page: still a [SmartschoolSkoreError], not an
/// authentication failure, and its message names the part of Skore but
/// quotes nothing of the start page.
Matcher _accessDenied(SkoreAccessArea area, String areaName) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolSkoreError>(),
  isA<SmartschoolSkoreAccessDeniedError>()
      .having((e) => e.area, 'area', area)
      .having((e) => e.message, 'message', contains("start page"))
      .having((e) => e.message, 'message', contains(areaName))
      .having((e) => e.message, 'message', isNot(contains('Voorbeeldschool')))
      .having((e) => e.message, 'message', isNot(contains('Willems'))),
);

/// A plain [SmartschoolSkoreError]: an answer the service cannot use,
/// neither a missing right nor a refused change.
Matcher _unusable([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isNot(isA<SmartschoolSkoreChangeRefusedError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
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

  const report = SkoreAccessArea.reportManagement;
  const gradebooks = SkoreAccessArea.gradebookManagement;
  const both = {report, gradebooks};

  group('a teacher without Skore rights, as captured live:', () {
    test('getClasses: the select_models GET ends on the start page', () async {
      final (_, skore) = await serve(_Smartschool(denied: both));
      await expectLater(
        skore.getClasses(),
        throwsA(_accessDenied(report, _reportManagement)),
      );
    });

    test(
      'getCourses: the assignments page GET ends on the start page',
      () async {
        final (_, skore) = await serve(_Smartschool(denied: both));
        await expectLater(
          skore.getCourses(2516),
          throwsA(_accessDenied(report, _reportManagement)),
        );
      },
    );

    test('getTeachers: the RPC POST is answered with the redirect', () async {
      final (server, skore) = await serve(_Smartschool(denied: both));
      await expectLater(
        skore.getTeachers(),
        throwsA(_accessDenied(report, _reportManagement)),
      );
      expect(server.requests, ['RPC getTeachers []']);
    });

    test('getGradebookShares: the RPC POST is answered with the redirect, '
        'in gradebook management', () async {
      final (server, skore) = await serve(_Smartschool(denied: both));
      await expectLater(
        skore.getGradebookShares(_me),
        throwsA(_accessDenied(gradebooks, _gradebookManagement)),
      );
      expect(server.requests, ['RPC getCourses [$_me]']);
    });

    test('checkAccess: no part of Skore', () async {
      final (server, skore) = await serve(_Smartschool(denied: both));
      expect(await skore.checkAccess(), isEmpty);
      expect(server.requests.where((r) => r.startsWith('RPC')), [
        'RPC getTeachers []',
        'RPC getCourses [$_me]',
      ]);
    });

    test('addTeacher: refused by the read before the save; nothing is '
        'sent', () async {
      final (server, skore) = await serve(_Smartschool(denied: both));
      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1001),
        throwsA(_accessDenied(report, _reportManagement)),
      );
      expect(server.requests, ['GET $_ownersPagePath']);
    });

    test('shareGradebook: refused by the read before the save; nothing is '
        'sent', () async {
      final (server, skore) = await serve(_Smartschool(denied: both));
      await expectLater(
        skore.shareGradebook(
          ownerId: _me,
          gradebookId: 34826,
          teacherId: 1001,
          access: SkoreShareAccess.write,
        ),
        throwsA(_accessDenied(gradebooks, _gradebookManagement)),
      );
      expect(server.requests, ['RPC getCourses [$_me]']);
    });
  });

  group('checkAccess', () {
    test('a Skore administrator: both parts, from one small read each, the '
        'own gradebooks by the own user ID', () async {
      final (server, skore) = await serve(_Smartschool());
      expect(await skore.checkAccess(), both);
      expect(server.requests, [
        'RPC getTeachers []',
        'GET /course-list/api/v1/courses',
        'GET /',
        'RPC getCourses [$_me]',
      ]);
    });

    // Not captured: no account with only one of the two rights was
    // available. These check that each part is told on its own read.
    test('report management refused: gradebook management only', () async {
      final (_, skore) = await serve(_Smartschool(denied: {report}));
      expect(await skore.checkAccess(), {gradebooks});
    });

    test('gradebook management refused: report management only', () async {
      final (_, skore) = await serve(_Smartschool(denied: {gradebooks}));
      expect(await skore.checkAccess(), {report});
    });

    test('an answer it cannot use is thrown, not taken for missing '
        'rights', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'RPC getTeachers []': () =>
                _Smartschool._html(_errorPage, status: 500),
          },
        ),
      );
      await expectLater(
        skore.checkAccess(),
        throwsA(_unusable(contains('HTTP 500'))),
      );
    });

    test('a read answered without a session is thrown as such', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'RPC getCourses [$_me]': () => _Smartschool._html(
              '{"result":null,"session":0,"method":"getCourses"}',
            ),
          },
        ),
      );
      await expectLater(
        skore.checkAccess(),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
    });
  });

  group('a save that Skore sends on to the start page', () {
    test('is unconfirmed, with the missing right as its cause', () async {
      final (server, skore) = await serve(_Smartschool(redirectSave: true));
      await expectLater(
        skore.shareGradebook(
          ownerId: _me,
          gradebookId: 34826,
          teacherId: 1001,
          access: SkoreShareAccess.write,
        ),
        throwsA(
          isA<SmartschoolSkoreSaveUnconfirmedError>().having(
            (e) => e.cause,
            'cause',
            _accessDenied(gradebooks, _gradebookManagement),
          ),
        ),
      );
      expect(
        server.requests.where((r) => r.startsWith('RPC saveShared')),
        hasLength(1),
      );
    });
  });

  group('a redirect elsewhere is an answer it cannot use, not a missing '
      'right:', () {
    test('a POST sent on to another module', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'RPC getTeachers []': () =>
                _Smartschool._redirect('/?module=Messages'),
          },
        ),
      );
      await expectLater(
        skore.getTeachers(),
        throwsA(_unusable(contains('HTTP 302'))),
      );
    });

    test('a POST sent on to the start page of another host', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'RPC getCourses [$_me]': () => _Smartschool._redirect(
              'https://other.smartschool.be/?module=Homepage',
            ),
          },
        ),
      );
      await expectLater(
        skore.getGradebookShares(_me),
        throwsA(_unusable(contains('HTTP 302'))),
      );
    });

    test('a GET that ends on another page', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'GET $_modelsPath': () =>
                _Smartschool._followed('/?module=Messages', _errorPage),
          },
        ),
      );
      await expectLater(
        skore.getClasses(),
        throwsA(_unusable(contains('HTML page instead of JSON'))),
      );
    });

    test('the start page without a redirect (a 200 HTML answer)', () async {
      final (_, skore) = await serve(
        _Smartschool(
          answers: {
            'GET $_ownersPagePath': () => _Smartschool._html(_startPage),
          },
        ),
      );
      await expectLater(
        skore.getCourses(2516),
        throwsA(_unusable(contains('no table of courses'))),
      );
    });
  });

  test('the trimmed start page names the made-up own user', () {
    // Guards the fixture: checkAccess reads the own user ID from it.
    final script = RegExp(r"JSON\.parse\('(.*)'\)\);").firstMatch(_startPage);
    final vars = jsonDecode(script!.group(1)!)['vars'] as Map;
    expect(vars['authenticatedUser']['id'], '4069_${_me}_0');
  });
}
