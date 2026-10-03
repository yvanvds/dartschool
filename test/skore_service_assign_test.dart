// Tests for issue #71: assigning a teacher to a course of a class in Skore
// (`SkoreService.addTeacher`, `SkoreService.replaceTeacher`); and #102: both
// return the assignment saved with the course and, for a replace, the
// assignment it replaced, as read before the save.
//
// Both go through `saveOwner(classID, courseID, ownerID, userID)` of Skore's
// RPC service owners.php: an empty ownerID adds an assignment, an existing
// one gives it another teacher. A replace first asks
// `getMyGroups(userID, classID, courseID)` for the current teacher. The
// answers below follow the two saves tried live on 2026-10-01 (approved by
// the developer, class 5WW1 = 2516, course "Digitale vaardigheden" = 1588):
//   ["2516","1588","","146"]      -> {"result":{"ownerID":34826,"userID":146}}
//   ["2516","1588","34826","320"] -> {"result":{"ownerID":34826,"userID":320}}
// and the getMyGroups answer seen live for a teacher without groups
// ({"result":{"mygroups":null}}). Teachers' names and user IDs are replaced
// by obvious fakes (146 -> 1005, 320 -> 1006); class, course and assignment
// IDs are Skore's own. The answer with groups has never been seen: the tests
// with groups use made-up shapes.
//
// Skore drives the school's grading and reports, and there is no test
// instance: nothing here reaches it. The fake Smartschool answers only the
// reads and the two RPC methods the service may call (getMyGroups,
// saveOwner), and fails the test on any other RPC method (deleteOwner,
// explodeMyGroups, ...) and on any other request (such as a login).
import 'dart:convert';
import 'dart:io';
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

const _ownersPagePath =
    '/turbowidgets_dev/skore/templates/module/owners/template.php';
const _ownersRpcPath = '/modules/Skore/backend/models/owners.php';

/// The labels of the requests in [_Smartschool.log].
const _readClass = 'GET owners page';
const _getTeachers = 'RPC getTeachers';
const _getMyGroups = 'RPC getMyGroups';
const _saveOwner = 'RPC saveOwner';

/// A row of the assignments page: a course, or a group header.
String _row(
  int courseId,
  String label, {
  int depth = 1,
  bool header = false,
  List<(int ownerId, int userId, String name)> owners = const [],
}) {
  final nodes = [
    for (final (ownerId, userId, name) in owners)
      '<div dojoType="ownernode" ownerID="$ownerId" userID="$userId" '
          'courseID="$courseId" classID="2516" coursename="$label" '
          'style="visibility:hidden;">$name</div>',
  ].join();
  return '''
  <tr class="ownertable_even">
      <td>
          <div class="${header ? 'owners_vz' : 'owners_v'}" style="margin-left:${depth * 10}px;">$label</div></td>
      <td>
          <div class="class" dojoType="ownercontainer" courseID="$courseId" coursename="$label" classID="2516"${header ? ' grouponly="true"' : ''}>$nodes</div></td></tr>''';
}

/// The assignments page of class 5WW1 (2516), trimmed: a group header, a
/// course with one teacher, a course with three, a second group header and
/// "Digitale vaardigheden" (1588), without a teacher before the live add and
/// with assignment 34826 after it ([digitalOwner]).
String _ownersPage({(int ownerId, int userId, String name)? digitalOwner}) =>
    '''
<table width="100%" border="0" cellspacing="0" cellpadding="0" class="ownertable">
${_row(1966, 'Vakken  [Vak]', depth: 0, header: true)}
${_row(2164, 'Aardrijkskunde (1 uur) (5e j DG) [AARDR]', owners: [(31882, 1001, 'Janssens, Jan')])}
${_row(1840, 'Project 1 (3e graad) [PROJE1]', depth: 2, owners: [(34580, 1002, 'Peeters, Piet'), (34582, 1003, 'Dupré, Céline'), (34584, 1004, "D'Hondt, Karel")])}
${_row(1590, 'Extra rapporten  [Extra rapporten]', depth: 0, header: true)}
${_row(1588, 'Digitale vaardigheden  [Digitale vaardigheden]', owners: [?digitalOwner])}
</table>''';

/// Before the live add: course 1588 has no teacher.
final _pageBeforeAdd = _ownersPage();

/// After the live add: course 1588 has assignment 34826 (teacher 1005).
final _pageWithAssignment = _ownersPage(
  digitalOwner: (34826, 1005, 'Willems, Wim'),
);

/// Skore's answer to a class without a structure, and to an unknown class ID.
const _noStructurePage =
    '<span data-i18n="class_has_no_structure">Deze klas bevat nog geen '
    "structuur. Geef deze klas een structuur via 'Koppeling'.</span>";

/// Skore's answer to `getTeachers`, trimmed.
const _teachersAnswer = '''
{"result":[{"userID":"1003","name":"Dupré, Céline"},{"userID":"1004","name":"D'Hondt, Karel"},{"userID":"1001","name":"Janssens, Jan"},{"userID":"1006","name":"Maes, Mieke"},{"userID":"1002","name":"Peeters, Piet"},{"userID":"1005","name":"Willems, Wim"}],"session":1,"method":"getTeachers","timelimit":0,"limitInfo":null}''';

/// An RPC answer of Skore with [result].
String _rpcAnswer(String method, String result) =>
    '{"result":$result,"session":1,"method":"$method","timelimit":0,'
    '"limitInfo":null}';

/// Skore's answer to `getMyGroups` for a teacher without "Mijn lesgroepen".
final _noGroups = _rpcAnswer('getMyGroups', '{"mygroups":null}');

/// Skore's answer to the live add (user ID replaced: 146 -> 1005).
final _addAnswer = _rpcAnswer('saveOwner', '{"ownerID":34826,"userID":1005}');

/// Skore's answer to the live replace (user ID replaced: 320 -> 1006).
final _replaceAnswer = _rpcAnswer(
  'saveOwner',
  '{"ownerID":34826,"userID":1006}',
);

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// A request as it reached the fake Smartschool.
typedef _Request = ({String label, Map<String, String> fields, List params});

/// A Smartschool that answers the assignments page of a class, and the RPC
/// methods getTeachers, getMyGroups and saveOwner of owners.php.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    String? page,
    String? myGroups,
    _Answer? save,
    this.failSave,
    _Answer? teachers,
  }) : page = _ok(page ?? _pageBeforeAdd),
       myGroups = _ok(myGroups ?? _noGroups),
       save = save ?? _ok(_addAnswer),
       teachers = teachers ?? _ok(_teachersAnswer);

  final _Answer page;
  final _Answer myGroups;
  final _Answer save;
  final _Answer teachers;

  /// When set, saveOwner fails with what it returns, after it went out.
  final Object Function(RequestOptions options)? failSave;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The labels of [requests], in order.
  List<String> get log => [for (final r in requests) r.label];

  /// The parameters of the one call of RPC [label].
  List rpcParams(String label) =>
      requests.singleWhere((r) => r.label == label).params;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final data = options.data;
    final form = data is Map
        ? {for (final e in data.entries) '${e.key}': '${e.value}'}
        : <String, String>{};
    if (options.method == 'GET' && path == _ownersPagePath) {
      requests.add((
        label: _readClass,
        fields: options.uri.queryParameters,
        params: const [],
      ));
      return _respond(page);
    }
    if (options.method == 'POST' && path == _ownersRpcPath) {
      final method = form['rpc_method'];
      final label = 'RPC $method';
      requests.add((
        label: label,
        fields: form,
        params: jsonDecode(form['rpc_params'] ?? 'null') as List,
      ));
      switch (method) {
        case 'getTeachers':
          return _respond(teachers);
        case 'getMyGroups':
          return _respond(myGroups);
        case 'saveOwner':
          final failure = failSave;
          if (failure != null) throw failure(options);
          return _respond(save);
      }
      // deleteOwner, explodeMyGroups, welcomeBackLostOnes, ...: never.
      fail('The service called Skore RPC method $method');
    }
    requests.add((
      label: '${options.method} $path',
      fields: const {},
      params: const [],
    ));
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  static ResponseBody _respond(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// A refusal before the save: a [SmartschoolSkoreChangeRefusedError] (#83),
/// still a [SmartschoolSkoreError], that says nothing was saved.
Matcher _refused(Object? message) => allOf(
  isA<SmartschoolSkoreError>(),
  isA<SmartschoolSkoreChangeRefusedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('Nothing was saved')),
);

/// An answer the service cannot use: a plain [SmartschoolSkoreError] (#83),
/// neither a missing right nor a refused change, that says nothing was saved.
Matcher _unusable(Object? message) => allOf(
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isNot(isA<SmartschoolSkoreChangeRefusedError>()),
  isA<SmartschoolSkoreError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('Nothing was saved')),
);

/// Skore's refusal of a request to an account without the rights, as HTTP
/// defines it (403 Forbidden), with a page that names the user. What Skore
/// really answers such an account has not been captured (#91).
const _forbidden = (
  status: 403,
  body:
      '<!DOCTYPE html><html><body><h1>Geen toegang</h1>'
      '<p>Jan Janssens heeft geen rechten voor deze pagina.</p></body></html>',
);

/// A save that went out without Skore confirming it.
Matcher _unconfirmed(Object? message, {Object? cause = isNull}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('may or may not'))
      .having((e) => e.cause, 'cause', cause),
);

/// The assignments of [course], as `"<id>: <teacherId> <teacherName>"`.
List<String> _teachersOf(SkoreCourse course) => [
  for (final a in course.assignments)
    '${a.id}: ${a.teacherId} ${a.teacherName}',
];

void main() {
  forbidRealNetwork();

  Future<SkoreService> serve(_Smartschool server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return SkoreService(client);
  }

  // ---------------------------------------------------------------------------
  // addTeacher
  // ---------------------------------------------------------------------------

  group('SkoreService.addTeacher', () {
    test('reads the class and the teachers, then saves once with an empty '
        'ownerID, and returns the new assignment', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final assignment = await skore.addTeacher(
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
      );

      expect(assignment.id, 34826);
      expect(assignment.teacherId, 1005);
      expect(assignment.teacherName, 'Willems, Wim');
      // No getMyGroups: there is no current teacher.
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
      expect(server.requests.first.fields, {'classID': '2516'});
      expect(server.rpcParams(_saveOwner), ['2516', '1588', '', '1005']);
    });

    test("sends saveOwner as Skore's web client sends an RPC call", () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005);

      final form = server.requests.last.fields;
      expect(form.keys, {
        'rpc_sessionobj',
        'rpc_requestType',
        'rpc_method',
        'rpc_params',
      });
      expect(form['rpc_requestType'], 'requestData');
      expect(form['rpc_method'], 'saveOwner');
      expect(form['rpc_params'], '["2516","1588","","1005"]');
      final session = jsonDecode(form['rpc_sessionobj']!) as Map;
      expect(session['requestSource'], 'skore-web');
    });

    test('adds a second teacher to a course that has one', () async {
      final server = _Smartschool(
        save: _ok(_rpcAnswer('saveOwner', '{"ownerID":40001,"userID":1006}')),
      );
      final skore = await serve(server);

      final assignment = await skore.addTeacher(
        classId: 2516,
        courseId: 2164,
        teacherId: 1006,
      );

      expect(assignment.id, 40001);
      expect(assignment.teacherName, 'Maes, Mieke');
      expect(server.rpcParams(_saveOwner), ['2516', '2164', '', '1006']);
    });

    test('takes IDs sent as strings', () async {
      final server = _Smartschool(
        save: _ok(
          _rpcAnswer('saveOwner', '{"ownerID":"34826","userID":"1005"}'),
        ),
      );
      final skore = await serve(server);

      final assignment = await skore.addTeacher(
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
      );

      expect(assignment.id, 34826);
      expect(assignment.teacherId, 1005);
    });
  });

  // ---------------------------------------------------------------------------
  // replaceTeacher
  // ---------------------------------------------------------------------------

  group('SkoreService.replaceTeacher', () {
    test('reads the class and the teachers, asks getMyGroups for the current '
        'teacher, then saves once with the ownerID', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok(_replaceAnswer),
      );
      final skore = await serve(server);

      final assignment = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1588,
        assignmentId: 34826,
        teacherId: 1006,
      );

      expect(assignment.id, 34826);
      expect(assignment.teacherId, 1006);
      expect(assignment.teacherName, 'Maes, Mieke');
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
      expect(server.requests.first.fields, {'classID': '2516'});
      // getMyGroups(userID, classID, courseID), for the current teacher.
      expect(server.rpcParams(_getMyGroups), ['1005', '2516', '1588']);
      expect(server.rpcParams(_saveOwner), ['2516', '1588', '34826', '1006']);
    });

    test('replaces one of several teachers of a course', () async {
      final server = _Smartschool(
        save: _ok(_rpcAnswer('saveOwner', '{"ownerID":34582,"userID":1006}')),
      );
      final skore = await serve(server);

      final assignment = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1840,
        assignmentId: 34582,
        teacherId: 1006,
      );

      expect(assignment.id, 34582);
      expect(server.rpcParams(_getMyGroups), ['1003', '2516', '1840']);
      expect(server.rpcParams(_saveOwner), ['2516', '1840', '34582', '1006']);
    });

    test('an empty list of groups is no groups', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        myGroups: _rpcAnswer('getMyGroups', '{"mygroups":[]}'),
        save: _ok(_replaceAnswer),
      );
      final skore = await serve(server);

      await skore.replaceTeacher(
        classId: 2516,
        courseId: 1588,
        assignmentId: 34826,
        teacherId: 1006,
      );

      expect(server.log.last, _saveOwner);
    });

    group('refuses when the current teacher works with "Mijn lesgroepen", '
        'without saving or deleting them', () {
      final withGroups = {
        'a list of groups': '{"mygroups":[{"groupID":"77","name":"Groep A"}]}',
        'a list of group IDs': '{"mygroups":["77"]}',
        'an object of groups': '{"mygroups":{"77":{"name":"Groep A"}}}',
      };
      for (final MapEntry(key: name, value: result) in withGroups.entries) {
        test(name, () async {
          final server = _Smartschool(
            page: _pageWithAssignment,
            myGroups: _rpcAnswer('getMyGroups', result),
          );
          final skore = await serve(server);

          await expectLater(
            skore.replaceTeacher(
              classId: 2516,
              courseId: 1588,
              assignmentId: 34826,
              teacherId: 1006,
            ),
            throwsA(
              allOf(
                // A refused change, like the other checks (#83).
                _refused(
                  allOf(
                    contains('Mijn lesgroepen'),
                    // The current teacher and the course, as read (#102).
                    contains('1005 (Willems, Wim)'),
                    contains(
                      '"Digitale vaardigheden  [Digitale '
                      'vaardigheden]"',
                    ),
                  ),
                ),
                isA<SmartschoolSkoreMyGroupsError>()
                    .having((e) => e.classId, 'classId', 2516)
                    .having((e) => e.courseId, 'courseId', 1588)
                    .having((e) => e.teacherId, 'teacherId', 1005)
                    // The name the service read from the class (#102).
                    .having(
                      (e) => e.teacherName,
                      'teacherName',
                      'Willems, Wim',
                    ),
              ),
            ),
          );
          expect(server.log, [_readClass, _getTeachers, _getMyGroups]);
        });
      }
    });

    group('refuses a getMyGroups answer it does not recognise', () {
      final unknown = {
        'no mygroups': '{}',
        'mygroups false': '{"mygroups":false}',
        'mygroups a string': '{"mygroups":"77"}',
        'mygroups an empty object': '{"mygroups":{}}',
        'a list instead of an object': '[]',
        'null': 'null',
      };
      for (final MapEntry(key: name, value: result) in unknown.entries) {
        test(name, () async {
          final server = _Smartschool(
            page: _pageWithAssignment,
            myGroups: _rpcAnswer('getMyGroups', result),
          );
          final skore = await serve(server);

          await expectLater(
            skore.replaceTeacher(
              classId: 2516,
              courseId: 1588,
              assignmentId: 34826,
              teacherId: 1006,
            ),
            throwsA(_unusable(contains('getMyGroups'))),
          );
          expect(server.log, [_readClass, _getTeachers, _getMyGroups]);
        });
      }
    });

    test('a getMyGroups answer without a session saves nothing', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        myGroups: '{"result":{"mygroups":null},"method":"getMyGroups"}',
      );
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 1006,
        ),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, [_readClass, _getTeachers, _getMyGroups]);
    });
  });

  // ---------------------------------------------------------------------------
  // The result: the assignment saved, in its context (#102)
  // ---------------------------------------------------------------------------

  group('returns the assignment saved with the course and the assignment it '
      'replaced, as read before the save, without reading the class '
      'again (#102)', () {
    test('addTeacher: the course with its teachers before the add, and no '
        'replaced assignment', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final saved = await skore.addTeacher(
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
      );

      expect(saved, isA<SkoreSavedAssignment>());
      expect(saved.id, 34826);
      expect(saved.teacherId, 1005);
      expect(saved.teacherName, 'Willems, Wim');
      expect(saved.replaced, isNull);
      final course = saved.course;
      expect(course.id, 1588);
      expect(course.classId, 2516);
      expect(course.label, 'Digitale vaardigheden  [Digitale vaardigheden]');
      expect(course.code, 'Digitale vaardigheden');
      expect(course.depth, 1);
      expect(course.isGroupHeader, isFalse);
      // Before the add: the course had no teacher.
      expect(course.assignments, isEmpty);
      // One read of the class: the one the checks used.
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
    });

    test('addTeacher to a course with a teacher: the course holds the other '
        'teacher, not the new assignment', () async {
      final server = _Smartschool(
        save: _ok(_rpcAnswer('saveOwner', '{"ownerID":40001,"userID":1006}')),
      );
      final skore = await serve(server);

      final saved = await skore.addTeacher(
        classId: 2516,
        courseId: 2164,
        teacherId: 1006,
      );

      expect(saved.id, 40001);
      expect(saved.teacherName, 'Maes, Mieke');
      expect(saved.replaced, isNull);
      expect(saved.course.id, 2164);
      expect(saved.course.label, 'Aardrijkskunde (1 uur) (5e j DG) [AARDR]');
      expect(saved.course.code, 'AARDR');
      expect(_teachersOf(saved.course), ['31882: 1001 Janssens, Jan']);
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
    });

    test('replaceTeacher: the assignment it replaced holds the previous '
        'teacher', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok(_replaceAnswer),
      );
      final skore = await serve(server);

      final saved = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1588,
        assignmentId: 34826,
        teacherId: 1006,
      );

      expect(saved.id, 34826);
      expect(saved.teacherId, 1006);
      expect(saved.teacherName, 'Maes, Mieke');
      final replaced = saved.replaced!;
      expect(replaced.id, 34826);
      expect(replaced.teacherId, 1005);
      expect(replaced.teacherName, 'Willems, Wim');
      expect(saved.course.id, 1588);
      expect(saved.course.classId, 2516);
      expect(
        saved.course.label,
        'Digitale vaardigheden  [Digitale vaardigheden]',
      );
      // Before the replace: the assignment with its previous teacher.
      expect(_teachersOf(saved.course), ['34826: 1005 Willems, Wim']);
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
    });

    test('replaceTeacher of one of several teachers: the replaced one is the '
        'assignment asked for, and the course holds the others', () async {
      final server = _Smartschool(
        save: _ok(_rpcAnswer('saveOwner', '{"ownerID":34582,"userID":1006}')),
      );
      final skore = await serve(server);

      final saved = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1840,
        assignmentId: 34582,
        teacherId: 1006,
      );

      expect(saved.teacherName, 'Maes, Mieke');
      expect(saved.replaced?.id, 34582);
      expect(saved.replaced?.teacherId, 1003);
      expect(saved.replaced?.teacherName, 'Dupré, Céline');
      expect(saved.course.label, 'Project 1 (3e graad) [PROJE1]');
      expect(saved.course.code, 'PROJE1');
      expect(saved.course.depth, 2);
      expect(_teachersOf(saved.course), [
        '34580: 1002 Peeters, Piet',
        '34582: 1003 Dupré, Céline',
        "34584: 1004 D'Hondt, Karel",
      ]);
      // The other teachers of the course: those of the other assignments.
      expect(
        saved.course.assignments
            .where((a) => a.id != saved.id)
            .map((a) => a.teacherName),
        ['Peeters, Piet', "D'Hondt, Karel"],
      );
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
    });

    test('a caller reports the change from the result alone, as '
        'smartschool-mcp does, and code that takes a SkoreAssignment keeps '
        'working', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok(_replaceAnswer),
      );
      final skore = await serve(server);

      // The type the writes returned before #102.
      final SkoreAssignment assignment = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1588,
        assignmentId: 34826,
        teacherId: 1006,
      );
      expect(assignment.id, 34826);
      expect(assignment.teacherName, 'Maes, Mieke');

      final saved = assignment as SkoreSavedAssignment;
      final course = saved.course;
      expect(
        '${saved.teacherName} instead of ${saved.replaced?.teacherName} on '
            'course "${course.code}" (course id ${course.id}) of class id '
            '${course.classId}',
        'Maes, Mieke instead of Willems, Wim on course "Digitale '
            'vaardigheden" (course id 1588) of class id 2516',
      );
      // Nothing was read for the report: no second read of the class.
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
    });

    test('toString names the course, the class and the replaced '
        'assignment', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok(_replaceAnswer),
      );
      final skore = await serve(server);

      final saved = await skore.replaceTeacher(
        classId: 2516,
        courseId: 1588,
        assignmentId: 34826,
        teacherId: 1006,
      );

      expect(
        '$saved',
        'SkoreSavedAssignment(id: 34826, teacherId: 1006, teacherName: '
            'Maes, Mieke, course: 1588 (Digitale vaardigheden  [Digitale '
            'vaardigheden]), class: 2516, replaced: SkoreAssignment(id: '
            '34826, teacherId: 1005, teacherName: Willems, Wim))',
      );
    });

    test('a refusal for "Mijn lesgroepen" names the current teacher of the '
        'assignment asked for, not another teacher of the course', () async {
      final server = _Smartschool(
        myGroups: _rpcAnswer('getMyGroups', '{"mygroups":["77"]}'),
      );
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1840,
          assignmentId: 34582,
          teacherId: 1006,
        ),
        throwsA(
          isA<SmartschoolSkoreMyGroupsError>()
              .having((e) => e.teacherId, 'teacherId', 1003)
              .having((e) => e.teacherName, 'teacherName', 'Dupré, Céline')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('1003 (Dupré, Céline)'),
                  contains('"Project 1 (3e graad) [PROJE1]"'),
                ),
              ),
        ),
      );
      expect(server.rpcParams(_getMyGroups), ['1003', '2516', '1840']);
      expect(server.log, [_readClass, _getTeachers, _getMyGroups]);
    });
  });

  // ---------------------------------------------------------------------------
  // Checks before the save
  // ---------------------------------------------------------------------------

  group('refuses before the save', () {
    test('a course that is not in the class', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 9999, teacherId: 1005),
        throwsA(_refused(contains('not in class 2516'))),
      );
      expect(server.log, [_readClass]);
    });

    test('a class ID Skore does not know (no course structure)', () async {
      final server = _Smartschool(page: _noStructurePage);
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 999999, courseId: 1588, teacherId: 1005),
        throwsA(_refused(contains('not in class 999999'))),
      );
      expect(server.log, [_readClass]);
      expect(server.requests.single.fields, {'classID': '999999'});
    });

    test('a group header', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1590, teacherId: 1005),
        throwsA(_refused(contains('group header'))),
      );
      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1966,
          assignmentId: 31882,
          teacherId: 1005,
        ),
        throwsA(_refused(contains('group header'))),
      );
      expect(server.log, [_readClass, _readClass]);
    });

    test('a teacher who already has an assignment on the course', () async {
      final server = _Smartschool(page: _pageWithAssignment);
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(_refused(contains('already has assignment 34826'))),
      );
      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1840, teacherId: 1003),
        throwsA(_refused(contains('already has assignment 34582'))),
      );
      expect(server.log, [_readClass, _readClass]);
    });

    test('a replace by the current teacher of the assignment', () async {
      final server = _Smartschool(page: _pageWithAssignment);
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 1005,
        ),
        throwsA(_refused(contains('already has assignment 34826'))),
      );
      expect(server.log, [_readClass]);
    });

    test(
      'a replace by a teacher with another assignment on the course',
      () async {
        final server = _Smartschool();
        final skore = await serve(server);

        await expectLater(
          skore.replaceTeacher(
            classId: 2516,
            courseId: 1840,
            assignmentId: 34580,
            teacherId: 1004,
          ),
          throwsA(_refused(contains('already has assignment 34584'))),
        );
        expect(server.log, [_readClass]);
      },
    );

    test('an assignment that is not one of the course', () async {
      final server = _Smartschool(page: _pageWithAssignment);
      final skore = await serve(server);

      // 31882 is an assignment of course 2164 of the class, not of 1588.
      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 31882,
          teacherId: 1006,
        ),
        throwsA(_refused(contains('assignment 31882 is not one of course'))),
      );
      expect(server.log, [_readClass]);
    });

    test('an assignment of a course without teachers', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 1006,
        ),
        throwsA(_refused(contains('assignment 34826 is not one of course'))),
      );
      expect(server.log, [_readClass]);
    });

    test('a teacher who is not in getTeachers', () async {
      final server = _Smartschool(page: _pageWithAssignment);
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 2164, teacherId: 4242),
        throwsA(_refused(contains('teacher 4242'))),
      );
      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 4242,
        ),
        throwsA(_refused(contains('teacher 4242'))),
      );
      expect(server.log, [_readClass, _getTeachers, _readClass, _getTeachers]);
    });

    test('Skore refusing the teachers with HTTP 403: a missing right in '
        'report management, not a refused change (#83)', () async {
      final server = _Smartschool(teachers: _forbidden);
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(
          allOf(
            isA<SmartschoolSkoreError>(),
            isNot(isA<SmartschoolSkoreChangeRefusedError>()),
            isA<SmartschoolSkoreAccessDeniedError>()
                .having((e) => e.area, 'area', SkoreAccessArea.reportManagement)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('getTeachers'),
                    contains('report management'),
                    isNot(contains('Janssens')),
                  ),
                ),
          ),
        ),
      );
      expect(server.log, [_readClass, _getTeachers]);
    });

    test('Smartschool cannot be reached for the class: a '
        'SmartschoolConnectionError, not unconfirmed', () async {
      final server = _UnreachableClassPage();
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(isA<SmartschoolConnectionError>()),
      );
      expect(server.log, [_readClass]);
    });
  });

  // ---------------------------------------------------------------------------
  // The answer to the save
  // ---------------------------------------------------------------------------

  group('an answer that does not confirm the save is unconfirmed, and the '
      'save is not sent again', () {
    final answers = <String, (_Answer, Object?)>{
      'no ownerID': (
        _ok(_rpcAnswer('saveOwner', '{"userID":1005}')),
        contains('does not name the assignment'),
      ),
      'no userID': (
        _ok(_rpcAnswer('saveOwner', '{"ownerID":34826}')),
        contains('does not name the assignment'),
      ),
      'ownerID 0': (
        _ok(_rpcAnswer('saveOwner', '{"ownerID":0,"userID":1005}')),
        contains('does not name the assignment'),
      ),
      'ownerID false': (
        _ok(_rpcAnswer('saveOwner', '{"ownerID":false,"userID":1005}')),
        contains('does not name the assignment'),
      ),
      'a result that is not an object': (
        _ok(_rpcAnswer('saveOwner', 'true')),
        contains('does not name the assignment'),
      ),
      'another teacher': (
        _ok(_rpcAnswer('saveOwner', '{"ownerID":34826,"userID":1001}')),
        contains('names teacher 1001 instead'),
      ),
    };
    for (final MapEntry(key: name, value: (answer, message))
        in answers.entries) {
      test(name, () async {
        final server = _Smartschool(save: answer);
        final skore = await serve(server);

        await expectLater(
          skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
          throwsA(_unconfirmed(allOf(contains('addTeacher'), message))),
        );
        expect(server.log, [_readClass, _getTeachers, _saveOwner]);
      });
    }

    test('a replace answered with another assignment', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok(_rpcAnswer('saveOwner', '{"ownerID":40001,"userID":1006}')),
      );
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 1006,
        ),
        throwsA(_unconfirmed(contains('names assignment 40001 instead'))),
      );
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
    });

    final unusable = <String, _Answer>{
      'HTTP 500': (status: 500, body: _errorPage),
      'an HTML page': _ok(_errorPage),
      'invalid JSON': _ok('{"result":'),
      'no result': _ok('{"session":1,"method":"saveOwner"}'),
    };
    for (final MapEntry(key: name, value: answer) in unusable.entries) {
      test(name, () async {
        final server = _Smartschool(save: answer);
        final skore = await serve(server);

        await expectLater(
          skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
          throwsA(
            _unconfirmed(
              contains('no usable answer'),
              cause: isA<SmartschoolSkoreError>(),
            ),
          ),
        );
        expect(server.log, [_readClass, _getTeachers, _saveOwner]);
      });
    }

    test('HTTP 403 to the save: unconfirmed, with the missing right as its '
        'cause (#83)', () async {
      final server = _Smartschool(save: _forbidden);
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(
          _unconfirmed(
            contains('no usable answer'),
            cause: isA<SmartschoolSkoreAccessDeniedError>().having(
              (e) => e.area,
              'area',
              SkoreAccessArea.reportManagement,
            ),
          ),
        ),
      );
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
    });

    test('the connection drops after the save went out', () async {
      final server = _Smartschool(
        failSave: (options) => DioException.connectionError(
          requestOptions: options,
          reason: 'Connection closed before full header was received',
          error: const SocketException('Connection reset by peer'),
        ),
      );
      final skore = await serve(server);

      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(
          _unconfirmed(
            contains('no usable answer'),
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
    });
  });

  group('a session refused for the save is not retried after logging in '
      'again: no second saveOwner', () {
    test('Smartschool answers 401', () async {
      final server = _Smartschool(save: (status: 401, body: ''));
      final skore = await serve(server);

      // Before the fix (retryAfterLogin left on): the client logged in again
      // (GET /login) to send saveOwner a second time.
      await expectLater(
        skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 1005),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('not retried after logging in again'),
          ),
        ),
      );
      expect(server.log, [_readClass, _getTeachers, _saveOwner]);
    });

    test('Skore answers without a session', () async {
      final server = _Smartschool(
        page: _pageWithAssignment,
        save: _ok('{"result":null,"method":"saveOwner"}'),
      );
      final skore = await serve(server);

      await expectLater(
        skore.replaceTeacher(
          classId: 2516,
          courseId: 1588,
          assignmentId: 34826,
          teacherId: 1006,
        ),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, [_readClass, _getTeachers, _getMyGroups, _saveOwner]);
    });
  });
}

/// A Smartschool that cannot be reached for the assignments page.
class _UnreachableClassPage extends _Smartschool {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == _ownersPagePath) {
      requests.add((label: _readClass, fields: const {}, params: const []));
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
        error: const SocketException('Connection refused'),
      );
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}
