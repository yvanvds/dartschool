// Tests for issue #70: reading Skore's classes, the courses of a class with
// the teachers assigned to them, and the teacher list (`SkoreService`).
//
// The answers below are trimmed captures of the live endpoints (read-only,
// 2026-10-01):
//   - GET /modules/Skore/modules/rapportbeheer/data.php
//       ?skajax_respons_type=JSON&skajax_function=select_models
//   - GET /turbowidgets_dev/skore/templates/module/owners/template.php
//       ?classID=2516 (and ?classID=999999, a class ID Skore does not know)
//   - POST /modules/Skore/backend/models/owners.php, rpc_method getTeachers
// with the teachers' names and user IDs replaced by obvious fakes. Class,
// model and course names and the other IDs are Skore's own.
//
// The reads must not write: the fake Smartschool fails the test on any other
// RPC method than getTeachers (Skore drives the school's grading and reports,
// and owners.php also holds write methods such as saveOwner). The writes
// (#71) are tested in skore_service_assign_test.dart.
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

/// The tree of report models, trimmed to two models: their members, groups
/// and classes, and one node of each other kind.
const _modelsJson = r'''
{"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/modellen16.gif\" border=\"0\" alt=\"rootimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;<span id=\"mtn_root\">Modellen</span>","data":{"item":"models","func":1},"children":[
 {"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/blockdevice.png\" border=\"0\" alt=\"modimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;1gr B-str.","data":{"item":"model","func":"178","modelname":"1gr B-str."},"closed":1,"children":[
  {"content":"<img src=\"/smsc/img/users2/users2_16x16.png\" border=\"0\" alt=\"memimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Leden","data":{"item":"members","func":"178","modelname":"1gr B-str."},"closed":1,"children":[
   {"content":"<img src=\"/smsc/img/users3/users3_16x16.png\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;1B","data":{"item":"childmember","func":"178_456","groupname":"1B"},"children":[
    {"content":"<img src=\"/smsc/img/briefcase/briefcase_16x16.png\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;1B1","data":{"item":"classroom","func":"2376"}},
    {"content":"<img src=\"/smsc/img/briefcase/briefcase_16x16.png\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;1B2","data":{"item":"classroom","func":"2378"}}]},
   {"content":"<img src=\"/smsc/img/users3/users3_16x16.png\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;2B","data":{"item":"childmember","func":"178_464","groupname":"2B"},"children":[
    {"content":"<img src=\"/smsc/img/briefcase/briefcase_16x16.png\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;2B1","data":{"item":"classroom","func":"2368"}}]}]},
  {"content":"<img src=\"/smsc/img/cal_purple_31/cal_purple_31_16x16.png\" border=\"0\" alt=\"perimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Periodes","data":{"item":"periods","func":"178"},"closed":"true"},
  {"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/verdeling.gif\" border=\"0\" alt=\"devimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Verdeling","data":{"item":"division","func":"178"}},
  {"content":"<img src=\"/smsc/img/calculator_flat/calculator_flat_16x16.png\" border=\"0\" alt=\"repimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Rapporten","data":{"item":"reports","func":"178"},"closed":1,"children":[
   {"content":"<img src=\"/smsc/img/mime_pdf/mime_pdf_16x16.png\" border=\"0\" alt=\"repimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;R1","data":{"item":"growchildreport","func":"2646","model":"178"}}]}]},
 {"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/blockdevice.png\" border=\"0\" alt=\"modimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;3gr D-D/A","data":{"item":"model","func":"176","modelname":"3gr D-D/A"},"closed":1,"children":[
  {"content":"<img src=\"/smsc/img/users2/users2_16x16.png\" border=\"0\" alt=\"memimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Leden","data":{"item":"members","func":"176","modelname":"3gr D-D/A"},"closed":1,"children":[
   {"content":"<img src=\"/smsc/img/users3/users3_16x16.png\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5DG","data":{"item":"childmember","func":"176_492","groupname":"5DG"},"children":[
    {"content":"<img src=\"/smsc/img/briefcase/briefcase_16x16.png\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5WW1","data":{"item":"classroom","func":"2516"}}]}]},
  {"content":"<img src=\"/smsc/img/calculator_flat/calculator_flat_16x16.png\" border=\"0\" alt=\"repimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;Rapporten","data":{"item":"reports","func":"176"},"closed":1,"children":[
   {"content":"<img src=\"/smsc/img/mime_pdf/mime_pdf_16x16.png\" border=\"0\" alt=\"repimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;R1D","data":{"item":"growchildreport","func":"2762","model":"176"}}]}]}]}
''';

/// The assignments page of class 5WW1 (2516), trimmed: two group headers, a
/// course with one teacher, a course with sub-courses and no teacher, a
/// sub-course with three teachers, a course and its sub-course with the same
/// code (`T.SOGEWE`), and a code with a space in it.
const _ownersPage = '''
<table width="100%" border="0" cellspacing="0" cellpadding="0" class="ownertable">
  <tr class="ownertable_odd">
      <td>
          <div class="owners_vz" style="margin-left:0px;">Vakken  [Vak]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="1966" coursename="Vakken" classID="2516" grouponly="true"></div></td></tr>
  <tr class="ownertable_even">
      <td>
          <div class="owners_v" style="margin-left:10px;">Aardrijkskunde (1 uur) (5e j DG) [AARDR]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="2164" coursename="Aardrijkskunde (1 uur)" classID="2516"><div dojoType="ownernode" ownerID="31882" userID="1001" courseID="2164" classID="2516" coursename="Aardrijkskunde (1 uur)" style="visibility:hidden;">Janssens, Jan</div></div></td></tr>
  <tr class="ownertable_even">
      <td>
          <div class="owners_v" style="margin-left:10px;">Eye4Skills (2 uur) (3e graad) [PROJE]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="2142" coursename="Eye4Skills (2 uur)" classID="2516"></div></td></tr>
  <tr class="ownertable_even">
      <td>
          <div class="owners_v" style="margin-left:20px;">Project 1 (3e graad) [PROJE1]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="1840" coursename="Project 1" classID="2516"><div dojoType="ownernode" ownerID="34580" userID="1002" courseID="1840" classID="2516" coursename="Project 1" style="visibility:hidden;">Peeters, Piet</div><div dojoType="ownernode" ownerID="34582" userID="1003" courseID="1840" classID="2516" coursename="Project 1" style="visibility:hidden;">Dupré, Céline</div><div dojoType="ownernode" ownerID="34584" userID="1004" courseID="1840" classID="2516" coursename="Project 1" style="visibility:hidden;">D&#39;Hondt, Karel</div></div></td></tr>
  <tr class="ownertable_odd">
      <td>
          <div class="owners_v" style="margin-left:10px;">Toegepaste sociale- en gedragswetenschappen (6 uur) (5e j DG (5WW)) [T.SOGEWE]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="1776" coursename="Toegepaste sociale- en gedragswetenschappen (6 uur)" classID="2516"></div></td></tr>
  <tr class="ownertable_even">
      <td>
          <div class="owners_v" style="margin-left:20px;">Toegepaste sociale- en gedragswetenschappen (/90) (5e j DG (5WW)) [T.SOGEWE]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="2676" coursename="Toegepaste sociale- en gedragswetenschappen (/90)" classID="2516"></div></td></tr>
  <tr class="ownertable_odd">
      <td>
          <div class="owners_vz" style="margin-left:0px;">Extra rapporten  [Extra rapporten]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="1590" coursename="Extra rapporten" classID="2516" grouponly="true"></div></td></tr>
  <tr class="ownertable_even">
      <td>
          <div class="owners_v" style="margin-left:10px;">Digitale vaardigheden  [Digitale vaardigheden]</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="1588" coursename="Digitale vaardigheden" classID="2516"><div dojoType="ownernode" ownerID="34826" userID="1005" courseID="1588" classID="2516" coursename="Digitale vaardigheden" style="visibility:hidden;">Willems, Wim</div></div></td></tr></table>''';

/// Skore's answer to the assignments page of a class without a structure,
/// and of a class ID it does not know.
const _noStructurePage =
    '<span data-i18n="class_has_no_structure">Deze klas bevat nog geen '
    "structuur. Geef deze klas een structuur via 'Koppeling'.</span>";

/// Skore's answer to `getTeachers`, trimmed.
const _teachersAnswer = '''
{"result":[{"userID":"1003","name":"Dupré, Céline"},{"userID":"1004","name":"D'Hondt, Karel"},{"userID":"1001","name":"Janssens, Jan"},{"userID":"1002","name":"Peeters, Piet"},{"userID":"1005","name":"Willems, Wim"}],"session":1,"method":"getTeachers","timelimit":0,"limitInfo":null}''';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

typedef _Answer = ({int status, String body, String contentType});

_Answer _ok(String body, {String contentType = 'text/html; charset=UTF-8'}) =>
    (status: 200, body: body, contentType: contentType);

/// A request as it reached the fake Smartschool.
typedef _Request = ({
  String method,
  String path,
  Map<String, String> query,
  Map<String, String> form,
});

/// A Smartschool that answers each Skore endpoint from [answers] (by path).
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answers);

  final Map<String, _Answer> answers;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    final form = data is Map
        ? {for (final e in data.entries) '${e.key}': '${e.value}'}
        : <String, String>{};
    requests.add((
      method: options.method,
      path: options.uri.path,
      query: options.uri.queryParameters,
      form: form,
    ));
    if (options.uri.path == _ownersRpcPath) {
      // Never let a write through: only the read the service may call.
      expect(form['rpc_method'], 'getTeachers');
    }
    final answer = answers[options.uri.path];
    if (answer == null) {
      fail('Unexpected request: ${options.method} ${options.uri}');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: [answer.contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A plain [SmartschoolSkoreError]: an answer the service cannot use (#83),
/// neither a missing right nor a refused change, and not an authentication
/// failure.
Matcher _skoreError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isNot(isA<SmartschoolSkoreChangeRefusedError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// Skore's refusal of a request to an account without the rights, as HTTP
/// defines it (403 Forbidden), with a page that names the user. What Skore
/// really answers such an account has not been captured (#91).
const _forbidden = (
  status: 403,
  body:
      '<!DOCTYPE html><html><body><h1>Geen toegang</h1>'
      '<p>Jan Janssens heeft geen rechten voor deze pagina.</p></body></html>',
  contentType: 'text/html; charset=UTF-8',
);

/// A [SmartschoolSkoreAccessDeniedError] for [area] (#83): still a
/// [SmartschoolSkoreError], not an authentication failure, and its message
/// names the part of Skore but quotes nothing of the page.
Matcher _accessDenied(SkoreAccessArea area, String areaName) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolSkoreError>(),
  isA<SmartschoolSkoreAccessDeniedError>()
      .having((e) => e.area, 'area', area)
      .having((e) => e.message, 'message', contains('HTTP 403'))
      .having((e) => e.message, 'message', contains(areaName))
      .having((e) => e.message, 'message', isNot(contains('Janssens'))),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SkoreService)> serve(
    Map<String, _Answer> answers,
  ) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, SkoreService(client));
  }

  // ---------------------------------------------------------------------------
  // Classes
  // ---------------------------------------------------------------------------

  group('SkoreService.parseClasses', () {
    late List<SkoreClass> classes;
    setUpAll(
      () => classes = SkoreService.parseClasses(jsonDecode(_modelsJson)),
    );

    test('lists the classes of every model, in the order of the tree', () {
      expect(classes.map((c) => c.id), [2376, 2378, 2368, 2516]);
      expect(classes.map((c) => c.name), ['1B1', '1B2', '2B1', '5WW1']);
    });

    test('gives each class its model and group', () {
      final first = classes.first;
      expect(first.modelId, 178);
      expect(first.modelName, '1gr B-str.');
      expect(first.groupId, 456);
      expect(first.groupName, '1B');

      final second = classes[2];
      expect(second.modelId, 178);
      expect(second.groupId, 464);
      expect(second.groupName, '2B');

      final last = classes.last;
      expect(last.modelId, 176);
      expect(last.modelName, '3gr D-D/A');
      expect(last.groupId, 492);
      expect(last.groupName, '5DG');
    });

    test('skips periods, divisions and reports', () {
      expect(classes.map((c) => c.id), isNot(contains(2646)));
      expect(classes.map((c) => c.id), isNot(contains(2762)));
    });

    test('a tree without models has no classes', () {
      expect(
        SkoreService.parseClasses({
          'content': 'Modellen',
          'data': {'item': 'models', 'func': 1},
          'children': <dynamic>[],
        }),
        isEmpty,
      );
    });

    test('a class outside a model is refused', () {
      expect(
        () => SkoreService.parseClasses({
          'data': {'item': 'models', 'func': 1},
          'children': [
            {
              'content': '&nbsp;1B1',
              'data': {'item': 'classroom', 'func': '2376'},
            },
          ],
        }),
        throwsA(_skoreError(contains('outside a model'))),
      );
    });

    test('a class with a non-numeric ID is refused', () {
      expect(
        () => SkoreService.parseClasses({
          'data': {'item': 'model', 'func': '178', 'modelname': 'M'},
          'children': [
            {
              'content': '&nbsp;1B1',
              'data': {'item': 'classroom', 'func': 'x'},
            },
          ],
        }),
        throwsA(_skoreError(contains('"x"'))),
      );
    });

    test('an answer that is not an object is refused', () {
      expect(
        () => SkoreService.parseClasses(<dynamic>[]),
        throwsA(_skoreError()),
      );
    });
  });

  group('SkoreService.getClasses', () {
    test('reads the tree of report models', () async {
      final (server, skore) = await serve({
        _modelsPath: _ok(_modelsJson, contentType: 'text/plain; charset=UTF-8'),
      });

      final classes = await skore.getClasses();

      expect(classes, hasLength(4));
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, _modelsPath);
      expect(request.query, {
        'skajax_respons_type': 'JSON',
        'skajax_function': 'select_models',
      });
    });

    test('an error page is a SmartschoolSkoreError with the status', () async {
      final (_, skore) = await serve({
        _modelsPath: (status: 500, body: _errorPage, contentType: 'text/html'),
      });

      await expectLater(
        skore.getClasses(),
        throwsA(_skoreError(contains('HTTP 500'))),
      );
    });

    test('an HTML page instead of JSON is a SmartschoolSkoreError', () async {
      final (_, skore) = await serve({_modelsPath: _ok(_errorPage)});

      await expectLater(
        skore.getClasses(),
        throwsA(_skoreError(contains('HTML'))),
      );
    });

    test('invalid JSON is a SmartschoolSkoreError', () async {
      final (_, skore) = await serve({_modelsPath: _ok('{"content":')});

      await expectLater(
        skore.getClasses(),
        throwsA(_skoreError(contains('invalid JSON'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Courses and assignments
  // ---------------------------------------------------------------------------

  group('SkoreService.parseCourses', () {
    late List<SkoreCourse> courses;
    setUpAll(() => courses = SkoreService.parseCourses(_ownersPage));

    SkoreCourse course(int id) => courses.singleWhere((c) => c.id == id);

    test('lists every row, in order', () {
      expect(courses.map((c) => c.id), [
        1966,
        2164,
        2142,
        1840,
        1776,
        2676,
        1590,
        1588,
      ]);
      expect(courses.map((c) => c.classId).toSet(), {2516});
    });

    test('a course with one teacher', () {
      final c = course(2164);
      expect(c.name, 'Aardrijkskunde (1 uur)');
      expect(c.label, 'Aardrijkskunde (1 uur) (5e j DG) [AARDR]');
      expect(c.code, 'AARDR');
      expect(c.isGroupHeader, isFalse);
      expect(c.depth, 1);
      expect(c.assignments, hasLength(1));
      final a = c.assignments.single;
      expect(a.id, 31882);
      expect(a.teacherId, 1001);
      expect(a.teacherName, 'Janssens, Jan');
    });

    test('a course with several teachers keeps them all, in order', () {
      final c = course(1840);
      expect(c.depth, 2);
      expect(c.assignments.map((a) => a.id), [34580, 34582, 34584]);
      expect(c.assignments.map((a) => a.teacherId), [1002, 1003, 1004]);
      expect(c.assignments.map((a) => a.teacherName), [
        'Peeters, Piet',
        'Dupré, Céline',
        "D'Hondt, Karel",
      ]);
    });

    test('a course with no teacher', () {
      final c = course(2142);
      expect(c.code, 'PROJE');
      expect(c.isGroupHeader, isFalse);
      expect(c.assignments, isEmpty);
    });

    test('a group header', () {
      final c = course(1966);
      expect(c.isGroupHeader, isTrue);
      expect(c.label, 'Vakken  [Vak]');
      expect(c.code, 'Vak');
      expect(c.name, 'Vakken');
      expect(c.depth, 0);
      expect(c.assignments, isEmpty);
      expect(course(1590).isGroupHeader, isTrue);
    });

    test('two rows with the same code are told apart by ID and label', () {
      final same = courses.where((c) => c.code == 'T.SOGEWE').toList();
      expect(same.map((c) => c.id), [1776, 2676]);
      expect(same.map((c) => c.depth), [1, 2]);
      expect(same.first.label, contains('(6 uur)'));
      expect(same.last.label, contains('(/90)'));
      expect(
        same.last.name,
        'Toegepaste sociale- en gedragswetenschappen (/90)',
      );
    });

    test('a code can hold a space', () {
      expect(course(1588).code, 'Digitale vaardigheden');
      expect(course(1590).code, 'Extra rapporten');
    });

    test('a label without a code has a null code', () {
      final courses = SkoreService.parseCourses(
        '<table class="ownertable"><tr><td><div class="owners_v" '
        'style="margin-left:0px;">Zonder code</div></td><td><div '
        'dojoType="ownercontainer" courseID="1" coursename="Zonder code" '
        'classID="2"></div></td></tr></table>',
      );
      expect(courses.single.code, isNull);
      expect(courses.single.label, 'Zonder code');
    });

    test('a class without a structure has no courses', () {
      expect(SkoreService.parseCourses(_noStructurePage), isEmpty);
    });

    test('a page without the table of courses is refused', () {
      expect(
        () => SkoreService.parseCourses(_errorPage),
        throwsA(_skoreError(contains('no table of courses'))),
      );
    });

    test('a non-numeric ID is refused', () {
      expect(
        () => SkoreService.parseCourses(
          _ownersPage.replaceFirst('ownerID="31882"', 'ownerID=""'),
        ),
        throwsA(_skoreError(contains('assignment'))),
      );
    });
  });

  group('SkoreService.getCourses', () {
    test('reads the assignments page of the class', () async {
      final (server, skore) = await serve({_ownersPagePath: _ok(_ownersPage)});

      final courses = await skore.getCourses(2516);

      expect(courses, hasLength(8));
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, _ownersPagePath);
      expect(request.query, {'classID': '2516'});
    });

    test('an unknown class gives an empty list', () async {
      final (_, skore) = await serve({_ownersPagePath: _ok(_noStructurePage)});

      expect(await skore.getCourses(999999), isEmpty);
    });

    test('an error page is a SmartschoolSkoreError', () async {
      final (_, skore) = await serve({
        _ownersPagePath: (status: 500, body: _errorPage, contentType: 'x'),
      });

      await expectLater(
        skore.getCourses(2516),
        throwsA(_skoreError(contains('HTTP 500'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Teachers (RPC)
  // ---------------------------------------------------------------------------

  group('SkoreService.parseTeachers', () {
    test('reads the user ID and name of each teacher', () {
      final teachers = SkoreService.parseTeachers(
        (jsonDecode(_teachersAnswer) as Map)['result'],
      );
      expect(teachers.map((t) => t.id), [1003, 1004, 1001, 1002, 1005]);
      expect(teachers.first.name, 'Dupré, Céline');
      expect(teachers[1].name, "D'Hondt, Karel");
    });

    test('a result that is not a list is refused', () {
      expect(
        () => SkoreService.parseTeachers({'mygroups': null}),
        throwsA(_skoreError()),
      );
    });

    test('a teacher with a non-numeric ID is refused', () {
      expect(
        () => SkoreService.parseTeachers([
          {'userID': '', 'name': 'Janssens, Jan'},
        ]),
        throwsA(_skoreError(contains('teacher'))),
      );
    });
  });

  group('SkoreService.getTeachers', () {
    test("sends the RPC call as Skore's web client does", () async {
      final (server, skore) = await serve({
        _ownersRpcPath: _ok(
          _teachersAnswer,
          contentType: 'application/json; charset=utf-8',
        ),
      });
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final teachers = await skore.getTeachers();

      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(teachers, hasLength(5));
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _ownersRpcPath);
      expect(request.form.keys, {
        'rpc_sessionobj',
        'rpc_requestType',
        'rpc_method',
        'rpc_params',
      });
      expect(request.form['rpc_requestType'], 'requestData');
      expect(request.form['rpc_method'], 'getTeachers');
      expect(request.form['rpc_params'], '[]');
      final session =
          jsonDecode(request.form['rpc_sessionobj']!) as Map<String, dynamic>;
      expect(session.keys, ['requestSource', 'timelimit', 'client_epoch']);
      expect(session['requestSource'], 'skore-web');
      expect(session['timelimit'], isNull);
      expect(session['client_epoch'], inInclusiveRange(before, after));
    });

    test('an answer without a session is a SmartschoolSessionExpiredError, '
        'without logging in again', () async {
      final (server, skore) = await serve({
        _ownersRpcPath: _ok('{"result":[],"method":"getTeachers"}'),
      });

      await expectLater(
        skore.getTeachers(),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('getTeachers'),
          ),
        ),
      );
      expect(server.requests.map((r) => r.path), [_ownersRpcPath]);
    });

    test('a session of 0 is no session', () async {
      final (_, skore) = await serve({
        _ownersRpcPath: _ok('{"result":[],"session":0}'),
      });

      await expectLater(
        skore.getTeachers(),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
    });

    test('an answer without a result is a SmartschoolSkoreError', () async {
      final (_, skore) = await serve({
        _ownersRpcPath: _ok('{"session":1,"method":"getTeachers"}'),
      });

      await expectLater(
        skore.getTeachers(),
        throwsA(_skoreError(contains('without a result'))),
      );
    });

    test(
      'an answer that is not an object is a SmartschoolSkoreError',
      () async {
        final (_, skore) = await serve({_ownersRpcPath: _ok('[1,2]')});

        await expectLater(skore.getTeachers(), throwsA(_skoreError()));
      },
    );

    test('an HTML page is a SmartschoolSkoreError', () async {
      final (_, skore) = await serve({_ownersRpcPath: _ok(_errorPage)});

      await expectLater(
        skore.getTeachers(),
        throwsA(_skoreError(contains('HTML'))),
      );
    });

    test('an error page is a SmartschoolSkoreError with the status', () async {
      final (_, skore) = await serve({
        _ownersRpcPath: (status: 500, body: _errorPage, contentType: 'x'),
      });

      await expectLater(
        skore.getTeachers(),
        throwsA(_skoreError(contains('HTTP 500'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // An account without the rights (#83)
  // ---------------------------------------------------------------------------

  group('Skore refusing a read with HTTP 403 is a missing right in report '
      'management, not an answer the service cannot use', () {
    const report = "Skore's report management (Rapporten > Modellen)";

    test('getClasses', () async {
      final (server, skore) = await serve({_modelsPath: _forbidden});

      await expectLater(
        skore.getClasses(),
        throwsA(
          allOf(
            _accessDenied(SkoreAccessArea.reportManagement, report),
            isA<SmartschoolSkoreError>().having(
              (e) => e.message,
              'message',
              contains('the list of report models'),
            ),
          ),
        ),
      );
      // Not signed in again: the session was accepted.
      expect(server.requests.map((r) => r.path), [_modelsPath]);
    });

    test('getCourses', () async {
      final (server, skore) = await serve({_ownersPagePath: _forbidden});

      await expectLater(
        skore.getCourses(2516),
        throwsA(_accessDenied(SkoreAccessArea.reportManagement, report)),
      );
      expect(server.requests.map((r) => r.path), [_ownersPagePath]);
    });

    test('getTeachers', () async {
      final (server, skore) = await serve({_ownersRpcPath: _forbidden});

      await expectLater(
        skore.getTeachers(),
        throwsA(
          allOf(
            _accessDenied(SkoreAccessArea.reportManagement, report),
            isA<SmartschoolSkoreError>().having(
              (e) => e.message,
              'message',
              contains('getTeachers'),
            ),
          ),
        ),
      );
      expect(server.requests.map((r) => r.path), [_ownersRpcPath]);
    });

    test('a caller tells the three cases apart by type', () async {
      String kind(Object error) => switch (error) {
        SmartschoolSkoreAccessDeniedError(:final area) => 'no rights: $area',
        SmartschoolSkoreChangeRefusedError() => 'refused',
        SmartschoolSkoreError() => 'unusable answer',
        _ => 'other',
      };
      Future<String> failureOf(Future<Object?> call) async {
        try {
          await call;
        } on Object catch (e) {
          return kind(e);
        }
        fail('The call did not fail');
      }

      final (_, forbidden) = await serve({_ownersRpcPath: _forbidden});
      final (_, broken) = await serve({_ownersRpcPath: _ok(_errorPage)});

      expect(
        await failureOf(forbidden.getTeachers()),
        'no rights: ${SkoreAccessArea.reportManagement}',
      );
      expect(await failureOf(broken.getTeachers()), 'unusable answer');
    });
  });
}
