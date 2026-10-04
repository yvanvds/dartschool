// Tests for issue #74: sharing a teacher's gradebook with other teachers in
// Skore, as an admin (`SkoreService.getGradebookShares`, `shareGradebook`,
// `unshareGradebook`), and for #103: those two writes return the change in its
// context (`SkoreGradebookShareChange`: the gradebook before it, and whether
// it saved anything).
//
// These go through Skore's gradebooks RPC service
// (/modules/Skore/modules/rapportbeheer/rpc/data.php), the one behind its
// "share gradebooks" manager:
//   - getCourses(userID): the gradebooks of a teacher, each with its readers
//     and writers. The answer below is a trimmed capture (read-only,
//     2026-10-01) of getCourses(146), the gradebook IDs as strings and the
//     teacher IDs as numbers; getCourses(999999), a user ID Skore does not
//     know, answered {"result":[]}.
//   - saveShared(userID, readers, writers): the readers and writers of the
//     gradebooks it holds. Three saves were tried live (approved by the
//     developer, on the developer's own gradebooks), each checked by reading
//     getCourses again:
//       [146, {"31886":[]}, {"31886":[]}]  -> {"state":1}; 34826 kept writer
//                                             320: a gradebook left out is
//                                             not touched
//       [146, {"34826":[]}, {"34826":[]}]  -> the writer was gone: a
//                                             gradebook sent is replaced
//       [146, {"34826":[]}, {"34826":[320]}] -> the writer was back
// The fake Skore below behaves that way. Teachers' names and user IDs are
// replaced by obvious fakes (146 -> 1005, 320 -> 1006); gradebook IDs, class
// and course names are Skore's own. The readers and writers of 31886 are made
// up, to test keeping them.
//
// Skore drives the school's grading and reports, and there is no test
// instance: nothing here reaches it. The fake Smartschool answers only
// getCourses and saveShared of data.php and getTeachers of owners.php, and
// fails the test on any other RPC method (data.php also holds deleteTeacher,
// cleanUpSkore, hideWorkyear, unlockReport, ...) and on any other request
// (such as a login).
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

const _gradebooksRpcPath = '/modules/Skore/modules/rapportbeheer/rpc/data.php';
const _ownersRpcPath = '/modules/Skore/backend/models/owners.php';

/// The labels of the requests in [_Smartschool.log].
const _getCourses = 'RPC getCourses';
const _getTeachers = 'RPC getTeachers';
const _saveShared = 'RPC saveShared';

/// The owner of the gradebooks below (146 live).
const _owner = 1005;

/// The gradebooks of teacher [_owner], as Skore's getCourses gives them,
/// trimmed.
const _gradebooks = '''
[{"id":"34524","icon":"colors","name":"Project 1","class":"5ADB","readers":[],"writers":[]},
 {"id":"31886","icon":"palette2","name":"Esthetica (1 uur)","class":"5WW1","readers":[1001,1002],"writers":[1003]},
 {"id":"34826","icon":"IconLib:laptop","name":"Digitale vaardigheden","class":"5WW1","readers":[],"writers":[1006]},
 {"id":"34582","icon":"colors","name":"Project 1","class":"5WW1","readers":[],"writers":[]}]''';

/// Skore's answer to `getTeachers` of owners.php, trimmed.
const _teachersAnswer = '''
{"result":[{"userID":"1007","name":"Claes, Clara"},{"userID":"1003","name":"Dupré, Céline"},{"userID":"1004","name":"D'Hondt, Karel"},{"userID":"1001","name":"Janssens, Jan"},{"userID":"1006","name":"Maes, Mieke"},{"userID":"1002","name":"Peeters, Piet"},{"userID":"1005","name":"Willems, Wim"}],"session":1,"method":"getTeachers","timelimit":0,"limitInfo":null}''';

/// An RPC answer of Skore with [result].
String _rpcAnswer(String method, String result) =>
    '{"result":$result,"session":1,"method":"$method","timelimit":0,'
    '"limitInfo":null}';

/// Skore's answer to a save.
final _saved = _rpcAnswer('saveShared', '{"state":1}');

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

/// A Skore that holds the gradebooks of teacher [_owner], answers getCourses
/// from them and applies a saveShared to them as live Skore does (a
/// gradebook sent is replaced, one left out is not touched); and answers
/// getTeachers of owners.php.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    String gradebooks = _gradebooks,
    _Answer? save,
    this.applySave = true,
    this.failSave,
    this.reread,
    _Answer? teachers,
  }) : gradebooks = (jsonDecode(gradebooks) as List)
           .map((g) => Map<String, dynamic>.of(g as Map<String, dynamic>))
           .toList(),
       save = save ?? _ok(_saved),
       teachers = teachers ?? _ok(_teachersAnswer);

  /// The gradebooks of [_owner] as Skore holds them.
  final List<Map<String, dynamic>> gradebooks;

  /// Skore's answer to saveShared.
  final _Answer save;

  /// Whether Skore applies a saveShared to [gradebooks].
  final bool applySave;

  /// When set, saveShared fails with what it returns, after it went out.
  final Object Function(RequestOptions options)? failSave;

  /// When set, Skore's answer to getCourses after a saveShared.
  final _Answer? reread;

  /// Skore's answer to getTeachers of owners.php.
  final _Answer teachers;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The labels of [requests], in order.
  List<String> get log => [for (final r in requests) r.label];

  /// The form of the one saveShared.
  Map<String, String> get saveForm =>
      requests.singleWhere((r) => r.label == _saveShared).fields;

  /// The gradebook [id] as Skore holds it now.
  Map<String, dynamic> gradebook(String id) =>
      gradebooks.singleWhere((g) => g['id'] == id);

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
    if (options.method == 'POST' &&
        (path == _gradebooksRpcPath || path == _ownersRpcPath)) {
      final method = form['rpc_method'];
      final params = jsonDecode(form['rpc_params'] ?? 'null') as List;
      final label = 'RPC $method';
      requests.add((label: label, fields: form, params: params));
      switch ((path, method)) {
        case (_gradebooksRpcPath, 'getCourses'):
          final reread = this.reread;
          if (reread != null && log.contains(_saveShared)) {
            return _respond(reread);
          }
          final result = params.single == _owner ? gradebooks : const [];
          return _respond(_ok(_rpcAnswer('getCourses', jsonEncode(result))));
        case (_gradebooksRpcPath, 'saveShared'):
          final failure = failSave;
          if (failure != null) throw failure(options);
          if (applySave && params.first == _owner) _apply(params);
          return _respond(save);
        case (_ownersRpcPath, 'getTeachers'):
          return _respond(teachers);
      }
      // deleteTeacher, cleanUpSkore, saveOwner, ...: never.
      fail('The service called Skore RPC method $method on $path');
    }
    requests.add((
      label: '${options.method} $path',
      fields: const {},
      params: const [],
    ));
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  /// Applies saveShared(userID, readers, writers) as live Skore does.
  void _apply(List params) {
    final readers = params[1] as Map<String, dynamic>;
    final writers = params[2] as Map<String, dynamic>;
    for (final g in gradebooks) {
      final id = g['id'] as String;
      if (readers.containsKey(id)) g['readers'] = readers[id];
      if (writers.containsKey(id)) g['writers'] = writers[id];
    }
  }

  static ResponseBody _respond(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
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
/// neither a missing right nor a refused change.
Matcher _unusable([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isNot(isA<SmartschoolSkoreChangeRefusedError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// Skore's refusal of a request to an account without the rights, as HTTP
/// defines it (403 Forbidden), with a page that names the user. What Skore
/// really answers a teacher without the rights, a redirect to the start
/// page, is tested in skore_service_access_test.dart (#91).
const _forbidden = (
  status: 403,
  body:
      '<!DOCTYPE html><html><body><h1>Geen toegang</h1>'
      '<p>Jan Janssens heeft geen rechten voor deze pagina.</p></body></html>',
);

/// A [SmartschoolSkoreAccessDeniedError] for [area] (#83), still a
/// [SmartschoolSkoreError], whose message quotes nothing of the page.
Matcher _accessDenied(SkoreAccessArea area, String areaName) => allOf(
  isA<SmartschoolSkoreError>(),
  isA<SmartschoolSkoreAccessDeniedError>()
      .having((e) => e.area, 'area', area)
      .having((e) => e.message, 'message', contains(areaName))
      .having((e) => e.message, 'message', isNot(contains('Janssens'))),
);

const _reportManagement = "Skore's report management (Rapporten > Modellen)";
const _gradebookManagement = "Skore's gradebook management (Puntenboeken)";

/// A save that went out without Skore confirming it.
Matcher _unconfirmed(Object? message, {Object? cause = isNull}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('may or may not'))
      .having((e) => e.cause, 'cause', cause),
);

void main() {
  forbidRealNetwork();

  Future<SkoreService> serve(HttpClientAdapter server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return SkoreService(client);
  }

  // ---------------------------------------------------------------------------
  // getGradebookShares
  // ---------------------------------------------------------------------------

  group('SkoreService.getGradebookShares', () {
    test('reads the gradebooks of a teacher with their readers and writers, '
        'in Skore\'s order', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final gradebooks = await skore.getGradebookShares(_owner);

      expect(gradebooks.map((g) => g.gradebookId), [
        34524,
        31886,
        34826,
        34582,
      ]);
      final digital = gradebooks[2];
      expect(digital.ownerId, _owner);
      expect(digital.className, '5WW1');
      expect(digital.courseName, 'Digitale vaardigheden');
      expect(digital.icon, 'IconLib:laptop');
      expect(digital.readerIds, isEmpty);
      expect(digital.writerIds, [1006]);
      final esthetics = gradebooks[1];
      expect(esthetics.readerIds, [1001, 1002]);
      expect(esthetics.writerIds, [1003]);
      expect(server.log, [_getCourses]);
    });

    test('sends getCourses as Skore\'s web client sends an RPC call, the '
        'user ID as a number', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await skore.getGradebookShares(_owner);

      final form = server.requests.single.fields;
      expect(form.keys, {
        'rpc_sessionobj',
        'rpc_requestType',
        'rpc_method',
        'rpc_params',
      });
      expect(form['rpc_requestType'], 'requestData');
      expect(form['rpc_method'], 'getCourses');
      expect(form['rpc_params'], '[1005]');
      final session = jsonDecode(form['rpc_sessionobj']!) as Map;
      expect(session['requestSource'], 'skore-web');
    });

    test('a teacher without gradebooks, or a user ID Skore does not know, has '
        'none', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      expect(await skore.getGradebookShares(999999), isEmpty);
      expect(server.requests.single.fields['rpc_params'], '[999999]');
    });

    test('an HTML page is a SmartschoolSkoreError', () async {
      final skore = await serve(_PageOnGetCourses());

      await expectLater(
        skore.getGradebookShares(_owner),
        throwsA(_unusable(contains('HTML page'))),
      );
    });

    test('Skore refusing it with HTTP 403 is a missing right in gradebook '
        'management (#83)', () async {
      final skore = await serve(_PageOnGetCourses(answer: _forbidden));

      await expectLater(
        skore.getGradebookShares(_owner),
        throwsA(
          allOf(
            _accessDenied(
              SkoreAccessArea.gradebookManagement,
              _gradebookManagement,
            ),
            isA<SmartschoolSkoreError>().having(
              (e) => e.message,
              'message',
              contains('getCourses'),
            ),
          ),
        ),
      );
    });

    test('an answer without a session is an expired session', () async {
      final skore = await serve(
        _PageOnGetCourses(answer: _ok('{"result":[],"method":"getCourses"}')),
      );

      await expectLater(
        skore.getGradebookShares(_owner),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
    });
  });

  group('SkoreService.parseGradebookShares', () {
    test('takes IDs as numbers or as numeric strings', () {
      final gradebooks = SkoreService.parseGradebookShares(
        jsonDecode(
          '[{"id":34826,"icon":"IconLib:laptop","name":"Digitale vaardigheden",'
          '"class":"5WW1","readers":["1001"," 1002 "],"writers":[1006,"1003"]}]',
        ),
        ownerId: _owner,
      );

      expect(gradebooks.single.gradebookId, 34826);
      expect(gradebooks.single.readerIds, [1001, 1002]);
      expect(gradebooks.single.writerIds, [1006, 1003]);
    });

    test('missing names and icon are empty', () {
      final gradebook = SkoreService.parseGradebookShares(
        jsonDecode('[{"id":"34826","readers":[],"writers":[]}]'),
        ownerId: _owner,
      ).single;

      expect(gradebook.className, '');
      expect(gradebook.courseName, '');
      expect(gradebook.icon, '');
    });

    group('refuses a shape it does not recognise, rather than read missing '
        'readers or writers as none', () {
      final shapes = {
        'an object instead of a list': '{"34826":{}}',
        'null': 'null',
        'an entry that is not an object': '["34826"]',
        'an entry without an ID': '[{"readers":[],"writers":[]}]',
        'a non-numeric ID': '[{"id":"abc","readers":[],"writers":[]}]',
        'no readers': '[{"id":"34826","writers":[1006]}]',
        'readers null': '[{"id":"34826","readers":null,"writers":[1006]}]',
        'no writers': '[{"id":"34826","readers":[]}]',
        'writers an object': '[{"id":"34826","readers":[],"writers":{"0":1}}]',
        'a non-numeric reader':
            '[{"id":"34826","readers":["Janssens"],"writers":[]}]',
        'a reader as an object':
            '[{"id":"34826","readers":[{"id":1001}],"writers":[]}]',
      };
      for (final MapEntry(key: name, value: json) in shapes.entries) {
        test(name, () {
          expect(
            () => SkoreService.parseGradebookShares(
              jsonDecode(json),
              ownerId: _owner,
            ),
            throwsA(isA<SmartschoolSkoreError>()),
          );
        });
      }
    });
  });

  group('SkoreGradebookShares.accessOf', () {
    const gradebook = SkoreGradebookShares(
      gradebookId: 31886,
      ownerId: _owner,
      className: '5WW1',
      courseName: 'Esthetica (1 uur)',
      icon: 'palette2',
      readerIds: [1001],
      writerIds: [1003],
    );

    test('tells readers, writers and others apart', () {
      expect(gradebook.accessOf(1001), SkoreShareAccess.read);
      expect(gradebook.accessOf(1003), SkoreShareAccess.write);
      expect(gradebook.accessOf(1006), isNull);
      expect(gradebook.accessOf(_owner), isNull);
    });
  });

  group('SkoreGradebookShareChange (#103)', () {
    const before = SkoreGradebookShares(
      gradebookId: 31886,
      ownerId: _owner,
      className: '5WW1',
      courseName: 'Esthetica (1 uur)',
      icon: 'palette2',
      readerIds: [1001],
      writerIds: [1003],
    );
    const change = SkoreGradebookShareChange(
      gradebookId: 31886,
      ownerId: _owner,
      className: '5WW1',
      courseName: 'Esthetica (1 uur)',
      icon: 'palette2',
      writerIds: [1003, 1001],
      teacherId: 1001,
      before: before,
      saved: true,
    );

    test('gives the access of its teacher before and after the change', () {
      expect(change.accessBefore, SkoreShareAccess.read);
      expect(change.accessAfter, SkoreShareAccess.write);
      expect(change.accessOf(1003), SkoreShareAccess.write);
      expect(change.readerIds, isEmpty);
    });

    test('is a SkoreGradebookShares, and says what it changed', () {
      expect(change, isA<SkoreGradebookShares>());
      expect(
        change.toString(),
        allOf(
          contains('SkoreGradebookShareChange(gradebookId: 31886'),
          contains('teacherId: 1001'),
          contains('accessBefore: read'),
          contains('saved: true'),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // shareGradebook
  // ---------------------------------------------------------------------------

  group('SkoreService.shareGradebook', () {
    test('reads the gradebooks and the teachers, saves only that gradebook '
        'with its complete lists, and returns it as read again', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1007,
        access: SkoreShareAccess.read,
      );

      expect(server.log, [_getCourses, _getTeachers, _saveShared, _getCourses]);
      // The owner and the teacher IDs as numbers, the gradebook ID as the
      // key, and no other gradebook of the owner.
      expect(
        server.saveForm['rpc_params'],
        '[1005,{"34826":[1007]},'
        '{"34826":[1006]}]',
      );
      expect(shared.gradebookId, 34826);
      expect(shared.readerIds, [1007]);
      expect(shared.writerIds, [1006]);
      // Both reads are of the owner's gradebooks.
      for (final r in server.requests.where((r) => r.label == _getCourses)) {
        expect(r.params, [_owner]);
      }
      // The other gradebooks are as they were.
      expect(server.gradebook('31886')['readers'], [1001, 1002]);
      expect(server.gradebook('31886')['writers'], [1003]);
    });

    test("sends saveShared as Skore's web client sends an RPC call", () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1007,
        access: SkoreShareAccess.write,
      );

      final form = server.saveForm;
      expect(form.keys, {
        'rpc_sessionobj',
        'rpc_requestType',
        'rpc_method',
        'rpc_params',
      });
      expect(form['rpc_requestType'], 'requestData');
      expect(form['rpc_method'], 'saveShared');
      expect(form['rpc_params'], '[1005,{"34826":[]},{"34826":[1006,1007]}]');
      final session = jsonDecode(form['rpc_sessionobj']!) as Map;
      expect(session['requestSource'], 'skore-web');
    });

    test('keeps the readers and writers it already has', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1004,
        access: SkoreShareAccess.write,
      );

      expect(
        server.saveForm['rpc_params'],
        '[1005,{"31886":[1001,1002]},{"31886":[1003,1004]}]',
      );
      expect(shared.readerIds, [1001, 1002]);
      expect(shared.writerIds, [1003, 1004]);
    });

    test('a writer shared with read access moves to the readers', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1006,
        access: SkoreShareAccess.read,
      );

      expect(
        server.saveForm['rpc_params'],
        '[1005,{"34826":[1006]},'
        '{"34826":[]}]',
      );
      expect(shared.readerIds, [1006]);
      expect(shared.writerIds, isEmpty);
    });

    test('a reader shared with write access moves to the writers, the others '
        'stay', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1002,
        access: SkoreShareAccess.write,
      );

      expect(
        server.saveForm['rpc_params'],
        '[1005,{"31886":[1001]},{"31886":[1003,1002]}]',
      );
      expect(shared.readerIds, [1001]);
      expect(shared.writerIds, [1003, 1002]);
    });

    test('a teacher in both lists is left in one', () async {
      final server = _Smartschool(
        gradebooks:
            '[{"id":"34826","icon":"","name":"Digitale vaardigheden",'
            '"class":"5WW1","readers":[1006,1001],"writers":[1006]}]',
      );
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1006,
        access: SkoreShareAccess.write,
      );

      expect(
        server.saveForm['rpc_params'],
        '[1005,{"34826":[1001]},'
        '{"34826":[1006]}]',
      );
      expect(shared.accessOf(1006), SkoreShareAccess.write);
    });

    test('takes the lists read again in another order', () async {
      final server = _Smartschool(
        reread: _ok(
          _rpcAnswer(
            'getCourses',
            '[{"id":"31886","icon":"palette2","name":"Esthetica (1 uur)",'
                '"class":"5WW1","readers":[1002,1001],"writers":["1004",1003]}]',
          ),
        ),
      );
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1004,
        access: SkoreShareAccess.write,
      );

      expect(shared.readerIds, [1002, 1001]);
      expect(shared.writerIds, [1004, 1003]);
    });

    test('takes state 1 as a string', () async {
      final server = _Smartschool(
        save: _ok(_rpcAnswer('saveShared', '{"state":"1"}')),
      );
      final skore = await serve(server);

      final shared = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34582,
        teacherId: 1001,
        access: SkoreShareAccess.read,
      );

      expect(shared.readerIds, [1001]);
    });
  });

  // ---------------------------------------------------------------------------
  // unshareGradebook
  // ---------------------------------------------------------------------------

  group('SkoreService.unshareGradebook', () {
    test('takes a writer off, without reading the teachers', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final unshared = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1006,
      );

      expect(server.log, [_getCourses, _saveShared, _getCourses]);
      expect(
        server.saveForm['rpc_params'],
        '[1005,{"34826":[]},'
        '{"34826":[]}]',
      );
      expect(unshared.readerIds, isEmpty);
      expect(unshared.writerIds, isEmpty);
    });

    test('takes a reader off, and the others stay', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final unshared = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1001,
      );

      expect(
        server.saveForm['rpc_params'],
        '[1005,{"31886":[1002]},{"31886":[1003]}]',
      );
      expect(unshared.readerIds, [1002]);
      expect(unshared.writerIds, [1003]);
    });

    test('takes off a teacher who is no longer in getTeachers', () async {
      final server = _Smartschool(
        gradebooks:
            '[{"id":"34582","icon":"colors","name":"Project 1",'
            '"class":"5WW1","readers":[4242],"writers":[1003]}]',
      );
      final skore = await serve(server);

      final unshared = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 34582,
        teacherId: 4242,
      );

      expect(server.log, [_getCourses, _saveShared, _getCourses]);
      expect(
        server.saveForm['rpc_params'],
        '[1005,{"34582":[]},'
        '{"34582":[1003]}]',
      );
      expect(unshared.readerIds, isEmpty);
      expect(unshared.writerIds, [1003]);
    });
  });

  // ---------------------------------------------------------------------------
  // Checks before the save
  // ---------------------------------------------------------------------------

  group('refuses before the save', () {
    test('the owner as the teacher, before any request', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await expectLater(
        skore.shareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: _owner,
          access: SkoreShareAccess.write,
        ),
        throwsA(_refused(contains('is the owner'))),
      );
      await expectLater(
        skore.unshareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: _owner,
        ),
        throwsA(_refused(contains('is the owner'))),
      );
      expect(server.log, isEmpty);
    });

    test('a gradebook that is not one of the owner\'s', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      // 31882 is a gradebook (assignment) of another teacher.
      await expectLater(
        skore.shareGradebook(
          ownerId: _owner,
          gradebookId: 31882,
          teacherId: 1007,
          access: SkoreShareAccess.read,
        ),
        throwsA(_refused(contains('gradebook 31882 is not one of teacher'))),
      );
      await expectLater(
        skore.unshareGradebook(
          ownerId: _owner,
          gradebookId: 31882,
          teacherId: 1006,
        ),
        throwsA(_refused(contains('gradebook 31882 is not one of teacher'))),
      );
      expect(server.log, [_getCourses, _getCourses]);
    });

    test('a gradebook under the wrong owner', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      // 34826 belongs to 1005, not to 1001, which has no gradebooks here.
      await expectLater(
        skore.shareGradebook(
          ownerId: 1001,
          gradebookId: 34826,
          teacherId: 1007,
          access: SkoreShareAccess.read,
        ),
        throwsA(_refused(contains('Skore lists 0 gradebooks'))),
      );
      expect(server.log, [_getCourses]);
      expect(server.requests.single.params, [1001]);
    });

    test('a teacher who is not in getTeachers', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      await expectLater(
        skore.shareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: 4242,
          access: SkoreShareAccess.read,
        ),
        throwsA(_refused(contains('teacher 4242'))),
      );
      expect(server.log, [_getCourses, _getTeachers]);
    });

    test('an answer of getCourses it does not recognise', () async {
      final server = _Smartschool(
        gradebooks: '[{"id":"34826","writers":[1006]}]',
      );
      final skore = await serve(server);

      await expectLater(
        skore.shareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: 1007,
          access: SkoreShareAccess.read,
        ),
        throwsA(_unusable()),
      );
      expect(server.log, [_getCourses]);
    });

    test('Skore refusing the teachers with HTTP 403: a missing right in '
        'report management, nothing saved (#83)', () async {
      final server = _Smartschool(teachers: _forbidden);
      final skore = await serve(server);

      await expectLater(
        skore.shareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: 1007,
          access: SkoreShareAccess.read,
        ),
        throwsA(
          _accessDenied(SkoreAccessArea.reportManagement, _reportManagement),
        ),
      );
      expect(server.log, [_getCourses, _getTeachers]);
    });

    test('Skore refusing the gradebooks with HTTP 403: a missing right in '
        'gradebook management, nothing saved (#83)', () async {
      // Fails the test on any other request than getCourses, so on a save.
      final skore = await serve(_PageOnGetCourses(answer: _forbidden));

      await expectLater(
        skore.unshareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: 1006,
        ),
        throwsA(
          _accessDenied(
            SkoreAccessArea.gradebookManagement,
            _gradebookManagement,
          ),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Nothing to change
  // ---------------------------------------------------------------------------

  group('saves nothing when nothing changes', () {
    test('already shared with the same access', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final writer = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1006,
        access: SkoreShareAccess.write,
      );
      final reader = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1002,
        access: SkoreShareAccess.read,
      );

      expect(writer.writerIds, [1006]);
      expect(reader.readerIds, [1001, 1002]);
      expect(server.log, [_getCourses, _getCourses]);
    });

    test('not shared with the teacher', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final gradebook = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 34582,
        teacherId: 1006,
      );

      expect(gradebook.gradebookId, 34582);
      expect(server.log, [_getCourses]);
    });
  });

  // ---------------------------------------------------------------------------
  // The change in its context (#103)
  // ---------------------------------------------------------------------------

  group('returns the change in its context: the gradebook before it, and '
      'whether it saved anything (#103)', () {
    test('a share that saves: the gradebook after it, with the one read '
        'before it and saved true', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final change = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1007,
        access: SkoreShareAccess.read,
      );

      // Still the gradebook after the save, as before #103.
      final SkoreGradebookShares after = change;
      expect(after.readerIds, [1007]);
      expect(after.writerIds, [1006]);
      expect(change.saved, isTrue);
      expect(change.teacherId, 1007);
      expect(change.before.gradebookId, 34826);
      expect(change.before.ownerId, _owner);
      expect(change.before.courseName, 'Digitale vaardigheden');
      expect(change.before.readerIds, isEmpty);
      expect(change.before.writerIds, [1006]);
      expect(change.accessBefore, isNull);
      expect(change.accessAfter, SkoreShareAccess.read);
      // Nothing more is read for it.
      expect(server.log, [_getCourses, _getTeachers, _saveShared, _getCourses]);
    });

    test('a reader moved to the writers had read access', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final change = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1002,
        access: SkoreShareAccess.write,
      );

      expect(change.saved, isTrue);
      expect(change.accessBefore, SkoreShareAccess.read);
      expect(change.accessAfter, SkoreShareAccess.write);
      expect(change.before.readerIds, [1001, 1002]);
      expect(change.before.writerIds, [1003]);
      expect(change.readerIds, [1001]);
      expect(change.writerIds, [1003, 1002]);
    });

    test('before is the read the call checked, not the read after the '
        'save', () async {
      final server = _Smartschool(
        reread: _ok(
          _rpcAnswer(
            'getCourses',
            '[{"id":"31886","icon":"palette2","name":"Esthetica (1 uur)",'
                '"class":"5WW1","readers":[1002,1001],"writers":["1004",1003]}]',
          ),
        ),
      );
      final skore = await serve(server);

      final change = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1004,
        access: SkoreShareAccess.write,
      );

      expect(change.before.readerIds, [1001, 1002]);
      expect(change.before.writerIds, [1003]);
      expect(change.readerIds, [1002, 1001]);
      expect(change.writerIds, [1004, 1003]);
    });

    test('a share that saves nothing: saved false, before as read, and no '
        'other request', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final change = await skore.shareGradebook(
        ownerId: _owner,
        gradebookId: 34826,
        teacherId: 1006,
        access: SkoreShareAccess.write,
      );

      expect(change.saved, isFalse);
      expect(change.teacherId, 1006);
      expect(change.accessBefore, SkoreShareAccess.write);
      expect(change.accessAfter, SkoreShareAccess.write);
      expect(change.before.writerIds, [1006]);
      expect(change.writerIds, [1006]);
      expect(change.readerIds, isEmpty);
      expect(server.log, [_getCourses]);
    });

    test('an unshare that saves: saved true, with the access the teacher '
        'had', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final change = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 31886,
        teacherId: 1001,
      );

      expect(change.saved, isTrue);
      expect(change.teacherId, 1001);
      expect(change.accessBefore, SkoreShareAccess.read);
      expect(change.accessAfter, isNull);
      expect(change.before.readerIds, [1001, 1002]);
      expect(change.readerIds, [1002]);
      expect(server.log, [_getCourses, _saveShared, _getCourses]);
    });

    test('an unshare that saves nothing: saved false, the teacher had no '
        'access', () async {
      final server = _Smartschool();
      final skore = await serve(server);

      final change = await skore.unshareGradebook(
        ownerId: _owner,
        gradebookId: 34582,
        teacherId: 1006,
      );

      expect(change.saved, isFalse);
      expect(change.accessBefore, isNull);
      expect(change.accessAfter, isNull);
      expect(change.before.gradebookId, 34582);
      expect(server.log, [_getCourses]);
    });

    test("the issue's calls: a caller reports each teacher's change from the "
        'results alone, without reading the gradebooks itself', () async {
      // Gradebook 34826 of teacher 1005: teacher 1006 is a writer, 1001 a
      // reader.
      final server = _Smartschool(
        gradebooks:
            '[{"id":"34826","icon":"IconLib:laptop",'
            '"name":"Digitale vaardigheden","class":"5WW1",'
            '"readers":[1001],"writers":[1006]}]',
      );
      final skore = await serve(server);

      // What smartschool-mcp reports per teacher, from the result only.
      String report(SkoreGradebookShareChange change) {
        final before = change.accessBefore?.name;
        final after = change.accessAfter?.name;
        if (!change.saved) {
          return after == null
              ? 'was not shared; nothing saved'
              : 'already had $after access; nothing saved';
        }
        if (after == null) return 'unshared (had $before access)';
        if (before == null) return 'shared with $after access';
        return 'now $after access instead of $before access';
      }

      Future<SkoreGradebookShareChange> share(int teacherId) =>
          skore.shareGradebook(
            ownerId: _owner,
            gradebookId: 34826,
            teacherId: teacherId,
            access: SkoreShareAccess.write,
          );
      Future<SkoreGradebookShareChange> unshare(int teacherId) =>
          skore.unshareGradebook(
            ownerId: _owner,
            gradebookId: 34826,
            teacherId: teacherId,
          );

      final a = await share(1006); // saves nothing: 1006 already writes
      expect(server.log, [_getCourses]);
      final b = await share(1001); // saves: 1001 moves from read to write
      final c = await share(1007); // saves: 1007 had no access
      final d = await unshare(1002); // saves nothing: never shared
      final e = await unshare(1006); // saves: 1006 had write access

      expect([a, b, c, d, e].map(report), [
        'already had write access; nothing saved',
        'now write access instead of read access',
        'shared with write access',
        'was not shared; nothing saved',
        'unshared (had write access)',
      ]);
      // Each write read the owner's gradebooks once before it (and once
      // after a save): the caller read nothing itself.
      expect(server.log, [
        _getCourses, // a
        _getCourses, _getTeachers, _saveShared, _getCourses, // b
        _getCourses, _getTeachers, _saveShared, _getCourses, // c
        _getCourses, // d
        _getCourses, _saveShared, _getCourses, // e
      ]);
      // Each result's before is the gradebook after the previous call.
      expect(b.before.writerIds, a.writerIds);
      expect(c.before.writerIds, b.writerIds);
      expect(e.before.writerIds, d.writerIds);
      expect(e.readerIds, isEmpty);
      expect(e.writerIds, [1001, 1007]);
    });
  });

  // ---------------------------------------------------------------------------
  // The answer to the save, and the read afterwards
  // ---------------------------------------------------------------------------

  group('a save that is not confirmed is unconfirmed, and is not sent '
      'again', () {
    Future<Object?> share(SkoreService skore) => skore.shareGradebook(
      ownerId: _owner,
      gradebookId: 34826,
      teacherId: 1007,
      access: SkoreShareAccess.read,
    );

    final answers = {
      'state 0': '{"state":0}',
      'no state': '{}',
      'state false': '{"state":false}',
      'a result that is not an object': 'true',
      'a null result': 'null',
    };
    for (final MapEntry(key: name, value: result) in answers.entries) {
      test(name, () async {
        final server = _Smartschool(
          save: _ok(_rpcAnswer('saveShared', result)),
        );
        final skore = await serve(server);

        await expectLater(
          share(skore),
          throwsA(
            _unconfirmed(
              allOf(contains('shareGradebook'), contains('does not confirm')),
            ),
          ),
        );
        expect(server.log, [_getCourses, _getTeachers, _saveShared]);
      });
    }

    final unusable = <String, _Answer>{
      'HTTP 500': (status: 500, body: _errorPage),
      'an HTML page': _ok(_errorPage),
      'invalid JSON': _ok('{"result":'),
      'no result': _ok('{"session":1,"method":"saveShared"}'),
    };
    for (final MapEntry(key: name, value: answer) in unusable.entries) {
      test(name, () async {
        final server = _Smartschool(save: answer, applySave: false);
        final skore = await serve(server);

        await expectLater(
          share(skore),
          throwsA(
            _unconfirmed(
              contains('no usable answer'),
              cause: isA<SmartschoolSkoreError>(),
            ),
          ),
        );
        expect(server.log, [_getCourses, _getTeachers, _saveShared]);
      });
    }

    test('HTTP 403 to the save: unconfirmed, with the missing right as its '
        'cause (#83)', () async {
      final server = _Smartschool(save: _forbidden, applySave: false);
      final skore = await serve(server);

      await expectLater(
        share(skore),
        throwsA(
          _unconfirmed(
            contains('no usable answer'),
            cause: isA<SmartschoolSkoreAccessDeniedError>().having(
              (e) => e.area,
              'area',
              SkoreAccessArea.gradebookManagement,
            ),
          ),
        ),
      );
      expect(server.log, [_getCourses, _getTeachers, _saveShared]);
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
        share(skore),
        throwsA(
          _unconfirmed(
            contains('no usable answer'),
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.log, [_getCourses, _getTeachers, _saveShared]);
    });

    test('Skore answers the save without a session', () async {
      final server = _Smartschool(
        save: _ok('{"result":null,"method":"saveShared"}'),
        applySave: false,
      );
      final skore = await serve(server);

      await expectLater(
        share(skore),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, [_getCourses, _getTeachers, _saveShared]);
    });

    test(
      'Skore answers state 1, but reading again shows the old lists',
      () async {
        final server = _Smartschool(applySave: false);
        final skore = await serve(server);

        await expectLater(
          share(skore),
          throwsA(
            _unconfirmed(
              allOf(
                contains(
                  'reading the gradebooks again shows readers [] and '
                  'writers [1006]',
                ),
                contains('readers [1007], writers [1006]'),
              ),
            ),
          ),
        );
        expect(server.log, [
          _getCourses,
          _getTeachers,
          _saveShared,
          _getCourses,
        ]);
      },
    );

    test('Skore answers state 1, but reading again shows another '
        'teacher', () async {
      final server = _Smartschool(
        reread: _ok(
          _rpcAnswer(
            'getCourses',
            '[{"id":"34826","icon":"","name":"Digitale vaardigheden",'
                '"class":"5WW1","readers":[1007,1001],"writers":[1006]}]',
          ),
        ),
      );
      final skore = await serve(server);

      await expectLater(
        share(skore),
        throwsA(_unconfirmed(contains('shows readers [1007, 1001]'))),
      );
    });

    test('Skore answers state 1, but reading again no longer lists the '
        'gradebook', () async {
      final server = _Smartschool(reread: _ok(_rpcAnswer('getCourses', '[]')));
      final skore = await serve(server);

      await expectLater(
        share(skore),
        throwsA(_unconfirmed(contains('no longer lists the gradebook'))),
      );
      expect(server.log, [_getCourses, _getTeachers, _saveShared, _getCourses]);
    });

    test('Skore answers state 1, but reading again fails', () async {
      final server = _Smartschool(reread: _ok(_errorPage));
      final skore = await serve(server);

      await expectLater(
        share(skore),
        throwsA(
          _unconfirmed(
            contains('check it failed'),
            cause: isA<SmartschoolSkoreError>(),
          ),
        ),
      );
      expect(server.log, [_getCourses, _getTeachers, _saveShared, _getCourses]);
    });

    test('an unshare that reading again does not confirm', () async {
      final server = _Smartschool(applySave: false);
      final skore = await serve(server);

      await expectLater(
        skore.unshareGradebook(
          ownerId: _owner,
          gradebookId: 34826,
          teacherId: 1006,
        ),
        throwsA(
          _unconfirmed(
            allOf(contains('unshareGradebook'), contains('writers [1006]')),
          ),
        ),
      );
      expect(server.log, [_getCourses, _saveShared, _getCourses]);
    });
  });
}

/// A Smartschool that answers getCourses with [answer] (by default an HTML
/// page), and fails the test on any other request.
class _PageOnGetCourses implements HttpClientAdapter {
  _PageOnGetCourses({_Answer? answer}) : answer = answer ?? _ok(_errorPage);

  final _Answer answer;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    final method = data is Map ? data['rpc_method'] : null;
    if (options.uri.path != _gradebooksRpcPath || method != 'getCourses') {
      fail('Unexpected request: ${options.method} ${options.uri} ($method)');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
