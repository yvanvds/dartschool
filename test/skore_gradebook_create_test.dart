// Tests for issue #150: creating an evaluation in a period of the teacher's
// own gradebook (`SkoreGradebookService.createEvaluation`), always
// unpublished, and the components it can count for (`getComponents`).
//
// What the web client's "new evaluation" dialog sends, on Skore's gradebook
// RPC service (/modules/Skore/backend/gradebook/rpc.php):
//   getNewEvalDialogBox(0, owners, groupID, periodID)        the course
//   getPosComponents(0, periodID, groupID, courseID, pathIds) the components
//   saveEvaluation(evaluationID, ownerID, userID, courseID, coursename,
//       title, short, periodID, date, max, compName, componentID, public,
//       chain, pathIds, contentType, contentTypeName, publicdatetime,
//       importParams, evalType)                               the save
// The save and its answer were verified live once (2026-10-08, in 6EWI,
// with the developer's go-ahead): `{"state":1,"incumul":0,"evaluationID":
// 395764,"refID":395764,"importData":null}`, the IDs as numbers, after which
// getEvaluations listed the new evaluation in column A with `public` "0",
// `publicdatetime` "" and `short` null ("" was sent).
//
// The fake Skore below answers in the shape of those captures, with fake
// pupils, teachers and evaluation IDs; class, group, model, course,
// gradebook and period IDs are Skore's own, as in the other gradebook
// tests. It keeps what saveEvaluation sends, and lists it from then on, as
// Skore did. Nothing here reaches Skore: the fake fails the test on any RPC
// method outside SkoreGradebookService.rpcMethods (and on the publishing
// ones in any case), and on any other request than the reads of the current
// user.
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

const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';

/// The logged-in teacher (a fake user ID).
const _me = 1005;

/// A colleague (a fake user ID).
const _colleague = 1006;

const _startPage =
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"4069_${_me}_0","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// The time of the tests: the day of the live check.
final _now = DateTime.utc(2026, 10, 8, 10);

/// The evaluation 6EWI's DW1 already has (a fake ID), published from
/// 2026-10-09 08:00: never touched.
const _existingId = 500001;

/// The ID the fake Skore gives a new evaluation.
const _newId = 500003;

const _courseName = 'Informaticawetenschappen (2 uur)';
const _pathIds = ['176', '472', '2440'];

/// 6EWI's gradebook as `getGradebooks` reads it.
const _ewi = SkoreGradebook(
  gradebookId: 32508,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: 2440,
  className: '6EWI',
  courseId: 2264,
  courseName: 'Informaticawetenschappen (2 uur) (6e j DO)',
  workyearId: 24,
);

/// A gradebook of 6WEWI2 in the tree that belongs to a colleague.
const _colleagues = SkoreGradebook(
  gradebookId: 32504,
  teacherId: _colleague,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: 2444,
  className: '6WEWI2',
  courseId: 2264,
  courseName: 'Informaticawetenschappen (2 uur) (6e j DO)',
  workyearId: 24,
);

/// 5BW's gradebook of 2025-2026.
const _earlier = SkoreGradebook(
  gradebookId: 28998,
  teacherId: _me,
  modelId: 160,
  modelName: '3grD-D/A (ASOTSO)',
  groupId: 450,
  groupName: '5DG',
  classId: 2264,
  className: '5BW',
  courseId: 1766,
  courseName: 'Informaticawetenschappen (2 uur) (5e j DG)',
  workyearId: 22,
);

/// An RPC answer of Skore with [result].
String _answer(String method, Object? result) => jsonEncode({
  'result': result,
  'session': 1,
  'method': method,
  'timelimit': 0,
  'limitInfo': null,
});

/// A class node of getNavigation's tree with one gradebook.
Map<String, Object?> _classNode(
  String name,
  List<String> ids,
  String ownerId,
  int userId,
) => {
  'raw': name,
  'crum': {'ids': ids},
  'data': [
    {
      'coursename': 'Informaticawetenschappen (2 uur) (6e j DO)',
      'data': {
        'ownerID': ownerId,
        'userID': '$userId',
        'classID': ids[2],
        'groupID': ids[1],
        'modelID': ids[0],
        'courseID': '2264',
        'structureID': '1564',
      },
      'part': ['Janssens Jan'],
    },
  ],
};

/// getNavigation of 2026-2027: 6EWI (32508, the teacher's) and 6WEWI2
/// (32504, a colleague's).
Map<String, Object?> _navigation({
  List<List<String>> workyears = const [
    ['24', '2026-2027'],
    ['22', '2025-2026'],
  ],
}) => {
  'navigation': [
    {
      'raw': '3gr D-D/A',
      'children': [
        {
          'raw': '6DO',
          'crum': {
            'ids': ['176', '472'],
          },
          'data': <Object?>[],
          'children': [
            _classNode('6EWI', _pathIds, '32508', _me),
            _classNode('6WEWI2', ['176', '472', '2444'], '32504', _colleague),
          ],
        },
      ],
    },
  ],
  'workyears': workyears,
  'currentWorkyear': '24',
};

/// init of 6EWI: DW1 (1704) open, DW0 (1702) closed.
Map<String, Object?> _init({int dw1Open = 1}) => {
  'left_0': {
    'stream': [
      {'c': 0, 'r': 'clavg_2440', 'v': '6EWI : Klasgemiddelde'},
      {
        'c': 0,
        'r': 'pupil_1201_2440',
        'v': '<span alternate="QW4gQWVydHM=">1.  Aerts, An</span>',
      },
      {
        'c': 0,
        'r': 'pupil_1202_2440',
        'v': '<span alternate="QmFydCBDbGFlcw==">2.  Claes, Bart</span>',
      },
    ],
  },
  'periods': [
    {
      'name': 'DW0',
      'fullname': 'DW0',
      'id': '1702',
      'info': '<p>Gesloten!</p>',
      'open': 0,
      'timestamp': '2026-09-17T20:00:00+0200',
      'categoryMode': 1,
    },
    {
      'name': 'DW1',
      'fullname': 'DW1',
      'id': '1704',
      'info': '<p>Open van 2026-09-18 15:30 tot en met 2026-12-18 20:00</p>',
      'open': dw1Open,
      'timestamp': '2026-12-18T20:00:00+0100',
      'categoryMode': 1,
    },
  ],
  'activePeriodE': 1,
  'ownerMap': [
    {
      'courseID': '2264',
      'groupID': '472',
      'coursename': _courseName,
      'ownerID': '32508',
      'classID': '2440',
    },
  ],
  'allowEvaluationTypes': null,
  'wystring': '2026 - 2027',
};

/// getGradebookContext of 6EWI's period [periodId].
Map<String, Object?> _context({
  int periodId = 1704,
  int writable = 1,
  int coordinator = 0,
}) => {
  'writable': writable,
  'coordinator': coordinator,
  'modelId': 176,
  'groupId': 472,
  'classId': 2440,
  'periodId': periodId,
  'courses': [2264],
  'owners': [32508],
  'teacherId': _me,
  'virtualId': 0,
  'restriction': 0,
};

const _components = [
  [0, 'geen'],
  ['2', 'DW'],
];

/// The head entry of an evaluation of 6EWI's DW1, as getEvaluations gives it.
Map<String, Object?> _head({
  required int id,
  required String column,
  required String title,
  required Object? short,
  required String date,
  required Object max,
  required Object? componentId,
  required String component,
  required String public,
  required String publicDateTime,
}) => {
  'formula': '',
  'title': title,
  'short': short,
  'date': date,
  'componentID': componentId,
  'component': component,
  'periodID': 1704,
  'courseID': '2264',
  'coursename': _courseName,
  'public': public,
  'publicdatetime': publicDateTime,
  'max': max,
  'refID': '$id',
  'colID': column,
  'evaltype': 1,
  'evaluationID': '$id',
  'contentType': '',
  'contentTypeName': '',
  'ownerID': '32508',
  'isPlannerEval': 0,
  'realCourseID': 2264,
  'posComps': _components,
  'groupID': 472,
};

/// The cells of evaluation [id] for the two pupils, without grades.
List<Map<String, Object?>> _emptyCells(int id) => [
  for (final pupil in [1201, 1202])
    {
      'c': '$id',
      'r': 'pupil_${pupil}_2440',
      'v':
          '<div class="gbc" raw=""></div><div class="gbc_cell_header"><span '
          'class="gbc_message_place" >&nbsp;&nbsp;</span></div>',
      'p': [1, 0, '$id', '32508', id],
    },
];

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// An RPC call as it reached the fake Skore.
typedef _Call = ({
  String method,
  List<dynamic> params,
  Map<String, dynamic> session,
});

/// A Skore that answers the reads of a gradebook (6EWI) and the "new
/// evaluation" dialog, keeps what saveEvaluation sends, and lists it in
/// getEvaluations from then on (in column A, unpublished, as seen live),
/// changed by [listAs]. [answers] replaces the answer to a method.
class _Skore implements HttpClientAdapter {
  _Skore({
    Map<String, _Answer> answers = const {},
    this.listAs,
    this.listCreated = true,
    this.failSave,
  }) : answers = {
         'getNavigation': _ok(_answer('getNavigation', _navigation())),
         'init': _ok(_answer('init', _init())),
         'getGradebookContext': _ok(_answer('getGradebookContext', _context())),
         'getNewEvalDialogBox': _ok(
           _answer('getNewEvalDialogBox', [
             ['2264', _courseName],
           ]),
         ),
         'getPosComponents': _ok(_answer('getPosComponents', _components)),
         'saveEvaluation': _ok(
           _answer('saveEvaluation', {
             'state': 1,
             'incumul': 0,
             'evaluationID': _newId,
             'refID': _newId,
             'importData': null,
           }),
         ),
         ...answers,
       };

  final Map<String, _Answer> answers;

  /// Changes the head entry of the new evaluation before it is listed.
  final void Function(Map<String, Object?> entry)? listAs;

  /// Whether getEvaluations lists the saved evaluation.
  final bool listCreated;

  /// Fails the save after it went out, as a connection that drops.
  final DioException Function(RequestOptions options)? failSave;

  /// Every RPC call that reached it, in order.
  final List<_Call> calls = [];

  /// Every request that reached it: `METHOD path`, `RPC <method>` for an RPC
  /// call.
  final List<String> requests = [];

  /// The RPC methods called, in order.
  List<String> get methods => [for (final c in calls) c.method];

  /// The parameters of the one saveEvaluation call.
  List<dynamic> get saved =>
      calls.where((c) => c.method == 'saveEvaluation').single.params;

  /// getEvaluations of 6EWI's DW1: the existing evaluation, and the saved
  /// one (column A) once saved.
  String _evaluations() {
    final save = calls.where((c) => c.method == 'saveEvaluation').firstOrNull;
    final created = save == null || !listCreated
        ? null
        : _head(
            id: _newId,
            column: 'A',
            title: save.params[5] as String,
            short: save.params[6] == '' ? null : save.params[6],
            date: save.params[8] as String,
            max: int.parse(save.params[9] as String),
            // What Skore lists for "geen" was not seen; DW came back as 2.
            componentId: save.params[11] == 0
                ? null
                : int.parse(save.params[11] as String),
            component: save.params[11] == 0 ? '' : save.params[10] as String,
            public: '${save.params[12]}',
            publicDateTime: save.params[17] as String,
          );
    if (created != null) listAs?.call(created);
    final existing = _head(
      id: _existingId,
      column: created == null ? 'A' : 'B',
      title: 'Python scripts schrijven',
      short: null,
      date: '2026-09-30',
      max: 100,
      componentId: 2,
      component: 'DW',
      public: '1',
      publicDateTime: '2026-10-09T08:00:00',
    );
    return _answer('getEvaluations', {
      'head': [?created, existing],
      'details': {
        'stream': [
          if (created != null) ..._emptyCells(_newId),
          ..._emptyCells(_existingId),
        ],
      },
      'periodStatus': 1,
      'evalType': 1,
      'archive': <Object?>[],
    });
  }

  static ResponseBody _body(String body, {int status = 200, String? type}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [type ?? 'text/html; charset=UTF-8'],
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
        return _body(_startPage);
      case ('GET', '/course-list/api/v1/courses'):
        requests.add('GET $path');
        return _body('[{"platformId":4069}]', type: 'application/json');
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Never let a publishing call through, nor anything off the list.
        expect(method, isNot(anyOf('setPublicProp', 'saveEvalProperties')));
        expect(SkoreGradebookService.rpcMethods, contains(method));
        calls.add((
          method: method,
          params: jsonDecode(form['rpc_params']!) as List<dynamic>,
          session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
        ));
        requests.add('RPC $method');
        if (method == 'saveEvaluation' && failSave != null) {
          throw failSave!(options);
        }
        final answer = method == 'getEvaluations'
            ? (answers[method] ?? _ok(_evaluations()))
            : answers[method];
        if (answer == null) fail('No answer for $method');
        return _body(
          answer.body,
          status: answer.status,
          type: 'application/json; charset=utf-8',
        );
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// The parameters of saveEvaluation for a new evaluation in 6EWI's DW1, as
/// the web dialog sends them (verified live), with what may change.
List<Object?> _saveParams({
  String title = 'Toets 1',
  String short = '',
  String date = '2026-10-08',
  String max = '20',
  String compName = 'DW',
  Object compId = '2',
}) => [
  0,
  '32508',
  _me,
  '2264',
  _courseName,
  title,
  short,
  1704,
  date,
  max,
  compName,
  compId,
  0, // public: not published
  <Object?>[],
  _pathIds,
  null,
  null,
  '', // publicdatetime: none
  null,
  1,
];

/// A [SmartschoolSkoreChangeRefusedError] whose message holds [reason].
Matcher _refused(Object reason) => isA<SmartschoolSkoreChangeRefusedError>()
    .having(
      (e) => e.message,
      'message',
      allOf(startsWith('createEvaluation: '), contains(reason)),
    )
    .having((e) => e.message, 'message', endsWith('Nothing was saved.'));

/// A [SmartschoolSkoreEvaluationCreateUnconfirmedError] about 6EWI's DW1.
Matcher _unconfirmed(
  Object message, {
  Object? evaluationId,
  Object? cause = isNull,
}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>(),
  isA<SmartschoolSkoreEvaluationCreateUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having(
        (e) => e.message,
        'message',
        allOf(
          contains(
            evaluationId == null
                ? 'It may or may not have been created, unpublished'
                : 'Skore answered that it created it, unpublished',
          ),
          endsWith('createEvaluation again makes a second evaluation.'),
        ),
      )
      .having((e) => e.gradebookId, 'gradebookId', 32508)
      .having((e) => e.periodId, 'periodId', 1704)
      .having((e) => e.title, 'title', 'Toets 1')
      .having((e) => e.evaluationId, 'evaluationId', evaluationId)
      .having((e) => e.cause, 'cause', cause),
);

void main() {
  forbidRealNetwork();

  Future<SkoreGradebookService> serve(_Skore server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return SkoreGradebookService(client, clock: () => _now);
  }

  /// Creates "Toets 1" (2026-10-08, max 20) in 6EWI's DW1, or what is given.
  Future<SkoreEvaluation> create(
    SkoreGradebookService gradebooks, {
    SkoreGradebook gradebook = _ewi,
    int periodId = 1704,
    String title = 'Toets 1',
    String? shortName,
    DateTime? date,
    int max = 20,
    int? componentId,
  }) => gradebooks.createEvaluation(
    gradebook,
    periodId,
    title: title,
    shortName: shortName,
    date: date ?? DateTime(2026, 10, 8),
    max: max,
    componentId: componentId,
  );

  // ---------------------------------------------------------------------------
  // The allowlist
  // ---------------------------------------------------------------------------

  test('the publishing calls cannot be sent: setPublicProp and '
      'saveEvalProperties are refused by the allowlist', () {
    for (final method in ['setPublicProp', 'saveEvalProperties']) {
      expect(SkoreGradebookService.rpcMethods, isNot(contains(method)));
      expect(
        () => SkoreGradebookService.checkRpcMethod(method),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('nothing was sent'),
          ),
        ),
      );
    }
  });

  // ---------------------------------------------------------------------------
  // The save
  // ---------------------------------------------------------------------------

  group('createEvaluation', () {
    test('checks, saves the evaluation once unpublished, and returns it as '
        'Skore lists it again', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final created = await create(gradebooks);

      expect(server.methods, [
        'getNavigation', // the own gradebooks of the current school year
        'init', // the period: one of the gradebook's, open
        'getGradebookContext', // writable in that period
        'getNewEvalDialogBox', // the course
        'getPosComponents', // the component
        'saveEvaluation',
        'getEvaluations', // the check
      ]);
      // Skore's current school year: no wy for the gradebooks, the
      // gradebook's for the rest.
      expect(server.calls.first.session.containsKey('wy'), isFalse);
      for (final call in server.calls.skip(1)) {
        expect(call.session['wy'], '24', reason: call.method);
        expect(call.session['teacher'], _me, reason: call.method);
        expect(call.session['restriction'], 0, reason: call.method);
      }
      final params = {for (final c in server.calls) c.method: c.params};
      expect(params['getGradebookContext'], [
        _pathIds,
        ['2264'],
        ['32508'],
        _me,
        1704, // the period of the evaluation, not the active one
        0,
        24,
      ]);
      expect(params['getNewEvalDialogBox'], [
        0,
        ['32508'],
        '472',
        1704,
      ]);
      expect(params['getPosComponents'], [0, 1704, '472', '2264', _pathIds]);
      // The exact parameters, strings and numbers as the dialog sends them.
      expect(server.saved, _saveParams());
      expect(params['getEvaluations'], [
        1704,
        _me,
        ['2264'],
        '472',
        '2440',
        _pathIds,
      ]);

      expect(created.id, _newId);
      expect(created.evaluationId, _newId);
      expect(created.gradebookId, 32508);
      expect(created.periodId, 1704);
      expect(created.column, 'A');
      expect(created.title, 'Toets 1');
      expect(created.shortName, isNull);
      expect(created.date, DateTime(2026, 10, 8));
      expect(created.max, 20);
      expect(created.componentId, 2);
      expect(created.componentName, 'DW');
      expect(created.type, SkoreEvaluationType.points);
      expect(created.publication.isPublic, isFalse);
      expect(created.publication.state, SkorePublicationState.notPublished);
      expect(created.publication.rawPublic, '0');
      expect(created.publication.rawPublicDateTime, '');
      expect(created.results.grades.map((g) => g.grade), [null, null]);
    });

    test('sends public 0 and publicdatetime "" in every case', () async {
      final cases =
          <
            String,
            (Future<void> Function(SkoreGradebookService), List<Object?>)
          >{
            'a short name, trimmed': (
              (g) => create(g, title: '  Toets 2 ', shortName: ' T2 '),
              _saveParams(title: 'Toets 2', short: 'T2'),
            ),
            'a blank short name': (
              (g) => create(g, shortName: '   '),
              _saveParams(),
            ),
            'the first day of the school year, max 100': (
              (g) => create(g, date: DateTime(2026, 9, 1), max: 100),
              _saveParams(date: '2026-09-01', max: '100'),
            ),
            'the last day of the school year, with a time': (
              (g) => create(g, date: DateTime(2027, 8, 31, 23, 59)),
              _saveParams(date: '2027-08-31'),
            ),
            'component DW asked for': (
              (g) => create(g, componentId: 2),
              _saveParams(),
            ),
            'no component ("geen") asked for': (
              (g) => create(g, componentId: 0),
              _saveParams(compName: 'geen', compId: 0),
            ),
          };
      for (final MapEntry(key: name, value: (call, expected))
          in cases.entries) {
        final server = _Skore();
        await call(await serve(server));
        final saved = server.saved;
        expect(saved, expected, reason: name);
        expect(saved, hasLength(20), reason: name);
        expect(saved[12], 0, reason: '$name: public');
        expect(saved[17], '', reason: '$name: publicdatetime');
      }
    });

    test("without a component, the one Skore's dialog picks: the second of "
        'exactly two, else "geen"', () async {
      final offered = <List<List<Object>>, (String, Object)>{
        [
          [0, 'geen'],
          ['2', 'DW'],
        ]: (
          'DW',
          '2',
        ),
        [
          [0, 'geen'],
        ]: (
          'geen',
          0,
        ),
        [
          [0, 'geen'],
          ['2', 'DW'],
          ['4', 'PW'],
        ]: (
          'geen',
          0,
        ),
      };
      for (final MapEntry(key: components, value: (name, id))
          in offered.entries) {
        final server = _Skore(
          answers: {
            'getPosComponents': _ok(_answer('getPosComponents', components)),
          },
        );
        await create(await serve(server));
        expect(server.saved[10], name, reason: '$components');
        expect(server.saved[11], id, reason: '$components');
      }
    });

    test('an explicit component of the period', () async {
      final server = _Skore(
        answers: {
          'getPosComponents': _ok(
            _answer('getPosComponents', [
              [0, 'geen'],
              ['2', 'DW'],
              ['4', 'PW'],
            ]),
          ),
        },
      );
      final created = await create(await serve(server), componentId: 4);
      expect(server.saved, _saveParams(compName: 'PW', compId: '4'));
      expect(created.componentId, 4);
      expect(created.componentName, 'PW');
    });
  });

  // ---------------------------------------------------------------------------
  // The checks before the save
  // ---------------------------------------------------------------------------

  group('createEvaluation refuses, saving nothing,', () {
    test('a blank title, a highest grade that is not positive or a period '
        'ID that is not one, before anything is sent', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await expectLater(
        create(gradebooks, title: '  \n '),
        throwsA(_refused('the title is blank')),
      );
      for (final max in [0, -20]) {
        await expectLater(
          create(gradebooks, max: max),
          throwsA(_refused('the highest grade ($max) is not a positive')),
        );
      }
      await expectLater(
        create(gradebooks, periodId: 0),
        throwsA(_refused('0 is not a period ID')),
      );
      expect(server.requests, isEmpty);
    });

    test('a gradebook of an earlier school year', () async {
      final server = _Skore();
      await expectLater(
        create(await serve(server), gradebook: _earlier, periodId: 1610),
        throwsA(
          _refused(
            'gradebook 28998 is of school year 22, not of the current one, '
            '2026-2027 (24): the library writes in the current school year '
            'only',
          ),
        ),
      );
      expect(server.methods, ['getNavigation']);
    });

    test('a gradebook that is not one of the own gradebooks', () async {
      final server = _Skore();
      const unknown = SkoreGradebook(
        gradebookId: 40000,
        teacherId: _me,
        modelId: 176,
        modelName: '3gr D-D/A',
        groupId: 472,
        groupName: '6DO',
        classId: 2440,
        className: '6EWI',
        courseId: 2264,
        courseName: 'Informatica',
        workyearId: 24,
      );
      await expectLater(
        create(await serve(server), gradebook: unknown),
        throwsA(
          _refused(
            'gradebook 40000 is not one of your own gradebooks of 2026-2027',
          ),
        ),
      );
      expect(server.methods, ['getNavigation']);
    });

    test("a colleague's gradebook in the tree", () async {
      final server = _Skore();
      await expectLater(
        create(await serve(server), gradebook: _colleagues),
        throwsA(
          _refused('gradebook 32504 is of teacher $_colleague, not your own'),
        ),
      );
      expect(server.methods, ['getNavigation']);
    });

    test('a period that is not one of the gradebook, or is closed', () async {
      var server = _Skore();
      await expectLater(
        create(await serve(server), periodId: 1800),
        throwsA(
          _refused(
            'period 1800 is not one of gradebook 32508 (it has DW0 (1702), '
            'DW1 (1704))',
          ),
        ),
      );
      expect(server.methods, ['getNavigation', 'init']);

      server = _Skore();
      await expectLater(
        create(await serve(server), periodId: 1702),
        throwsA(_refused('period DW0 (1702) of gradebook 32508 is closed')),
      );
      expect(server.methods, ['getNavigation', 'init']);

      server = _Skore(
        answers: {'init': _ok(_answer('init', _init(dw1Open: 0)))},
      );
      await expectLater(
        create(await serve(server)),
        throwsA(_refused('period DW1 (1704) of gradebook 32508 is closed')),
      );
      expect(server.methods, ['getNavigation', 'init']);
    });

    test('a gradebook Skore shows read-only in the period', () async {
      final contexts = {
        'writable 0': _context(writable: 0),
        'coordinator mode': _context(coordinator: 1),
      };
      for (final MapEntry(key: why, value: context) in contexts.entries) {
        final server = _Skore(
          answers: {
            'getGradebookContext': _ok(_answer('getGradebookContext', context)),
          },
        );
        await expectLater(
          create(await serve(server)),
          throwsA(
            _refused(
              'Skore shows gradebook 32508 read-only to you in period DW1 '
              '(1704) ($why)',
            ),
          ),
        );
        expect(server.methods, [
          'getNavigation',
          'init',
          'getGradebookContext',
        ]);
      }
    });

    test('a date outside the school year', () async {
      for (final date in [DateTime(2026, 8, 31, 23), DateTime(2027, 9, 1)]) {
        final server = _Skore();
        await expectLater(
          create(await serve(server), date: date),
          throwsA(
            _refused(
              'is not in school year 2026-2027 (2026-09-01 to 2027-08-31)',
            ),
          ),
        );
        expect(server.methods, [
          'getNavigation',
          'init',
          'getGradebookContext',
        ]);
      }
    });

    test('a course Skore does not offer for a new evaluation', () async {
      final server = _Skore(
        answers: {
          'getNewEvalDialogBox': _ok(
            _answer('getNewEvalDialogBox', [
              ['1588', 'Digitale vaardigheden'],
            ]),
          ),
        },
      );
      await expectLater(
        create(await serve(server)),
        throwsA(
          _refused(
            'Skore does not offer course 2264 for a new evaluation in period '
            'DW1 (1704) of gradebook 32508 (it offers 1588)',
          ),
        ),
      );
      expect(server.methods.last, 'getNewEvalDialogBox');
    });

    test('a component Skore does not offer, or no "geen" to pick', () async {
      var server = _Skore();
      await expectLater(
        create(await serve(server), componentId: 4),
        throwsA(
          _refused(
            'component 4 is not one Skore offers for period DW1 (1704) of '
            'gradebook 32508 (it offers 0 geen, 2 DW)',
          ),
        ),
      );
      expect(server.methods.last, 'getPosComponents');

      server = _Skore(
        answers: {
          'getPosComponents': _ok(
            _answer('getPosComponents', [
              ['2', 'DW'],
            ]),
          ),
        },
      );
      await expectLater(
        create(await serve(server)),
        throwsA(_refused('Skore offers no "geen" component')),
      );
      expect(server.methods.last, 'getPosComponents');
    });

    test(
      'when a read before the save fails: a plain SmartschoolSkoreError',
      () async {
        final failures = <String, Map<String, _Answer>>{
          'init answers 500': {'init': (status: 500, body: 'Internal error')},
          'the dialog box is no list': {
            'getNewEvalDialogBox': _ok(_answer('getNewEvalDialogBox', {})),
          },
          'a component is no pair': {
            'getPosComponents': _ok(
              _answer('getPosComponents', [
                [0],
              ]),
            ),
          },
          'the school year is not named as one': {
            'getNavigation': _ok(
              _answer(
                'getNavigation',
                _navigation(
                  workyears: [
                    ['24', 'Schooljaar 26'],
                  ],
                ),
              ),
            ),
          },
        };
        for (final MapEntry(key: name, value: answers) in failures.entries) {
          final server = _Skore(answers: answers);
          await expectLater(
            create(await serve(server)),
            throwsA(
              allOf(
                isA<SmartschoolSkoreError>(),
                isNot(isA<SmartschoolSkoreChangeRefusedError>()),
              ),
            ),
            reason: name,
          );
          expect(
            server.methods,
            isNot(contains('saveEvaluation')),
            reason: name,
          );
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Sent once
  // ---------------------------------------------------------------------------

  group('createEvaluation sends the save once, never again,', () {
    test('when Smartschool refuses the session for it: no login, no second '
        'save', () async {
      // Without retryAfterLogin: false, the client would log in (GET /login,
      // an unexpected request here) and send saveEvaluation again: a second
      // evaluation.
      final server = _Skore(
        answers: {'saveEvaluation': (status: 401, body: '')},
      );
      await expectLater(
        create(await serve(server)),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('not retried after logging in again'),
          ),
        ),
      );
      expect(server.methods.where((m) => m == 'saveEvaluation'), hasLength(1));
      expect(server.methods.last, 'saveEvaluation');
      expect(server.requests.where((r) => r.contains('login')), isEmpty);
    });

    test('when Skore answers it without a session', () async {
      final server = _Skore(
        answers: {
          'saveEvaluation': _ok('{"result":null,"method":"saveEvaluation"}'),
        },
      );
      await expectLater(
        create(await serve(server)),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.methods.last, 'saveEvaluation');
    });

    test('and an answer that is not a confirmation leaves it unconfirmed, '
        'without reading again', () async {
      final answers = <String, (_Answer, Matcher)>{
        // Seen live for saveGrade (#151): a 500 with a JSON line and
        // Smartschool's error page, which the client hands on.
        'HTTP 500': (
          (
            status: 500,
            body:
                '{"message":"Internal Server Error"}<!DOCTYPE html><html>'
                '<title>Oeps, er ging iets mis</title></html>',
          ),
          isA<SmartschoolSkoreError>(),
        ),
        'an HTML page': (
          _ok('<!DOCTYPE html><html><title>Oeps</title></html>'),
          isA<SmartschoolSkoreError>(),
        ),
        'state 0': (
          _ok(_answer('saveEvaluation', {'state': 0, 'refID': _newId})),
          isNull,
        ),
        'no refID': (_ok(_answer('saveEvaluation', {'state': 1})), isNull),
        'refID 0': (
          _ok(_answer('saveEvaluation', {'state': 1, 'refID': 0})),
          isNull,
        ),
        'no object': (_ok(_answer('saveEvaluation', true)), isNull),
      };
      for (final MapEntry(key: name, value: (answer, cause))
          in answers.entries) {
        final server = _Skore(answers: {'saveEvaluation': answer});
        await expectLater(
          create(await serve(server)),
          throwsA(
            _unconfirmed(
              allOf(
                contains(
                  'the save of evaluation "Toets 1" (2026-10-08, max 20, '
                  'component DW) in period DW1 (1704) of gradebook 32508 was '
                  'sent',
                ),
              ),
              cause: cause,
            ),
          ),
          reason: name,
        );
        expect(server.methods.last, 'saveEvaluation', reason: name);
        expect(
          server.methods.where((m) => m == 'saveEvaluation'),
          hasLength(1),
          reason: name,
        );
      }
    });

    test('and a connection that drops after it went out leaves it '
        'unconfirmed', () async {
      final server = _Skore(
        failSave: (options) => DioException.connectionError(
          requestOptions: options,
          reason: 'Connection closed before full header was received',
          error: const SocketException('Connection reset by peer'),
        ),
      );
      await expectLater(
        create(await serve(server)),
        throwsA(
          _unconfirmed(
            contains('no usable answer came in'),
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.methods.last, 'saveEvaluation');
    });
  });

  // ---------------------------------------------------------------------------
  // The check afterwards
  // ---------------------------------------------------------------------------

  group('createEvaluation reads the period again:', () {
    test('when that fails, or does not list the evaluation, it is '
        'unconfirmed, with its ID', () async {
      var server = _Skore(
        answers: {'getEvaluations': (status: 500, body: 'Internal error')},
      );
      await expectLater(
        create(await serve(server)),
        throwsA(
          _unconfirmed(
            contains(
              'was confirmed as evaluation $_newId, but reading the period '
              'again to check it failed',
            ),
            evaluationId: _newId,
            cause: isA<SmartschoolSkoreError>(),
          ),
        ),
      );
      expect(server.methods.last, 'getEvaluations');

      server = _Skore(listCreated: false);
      await expectLater(
        create(await serve(server)),
        throwsA(
          _unconfirmed(
            contains('reading the period again does not list it'),
            evaluationId: _newId,
          ),
        ),
      );
    });

    test('when it shows the evaluation otherwise than asked, it is '
        'unconfirmed, with what differs', () async {
      final server = _Skore(
        listAs: (entry) {
          entry['title'] = 'Toets een';
          entry['date'] = '2026-10-09';
          entry['max'] = 10;
          entry['componentID'] = null;
          entry['component'] = '';
        },
      );
      await expectLater(
        create(await serve(server)),
        throwsA(
          _unconfirmed(
            contains(
              'shows it with the title "Toets een", the date 2026-10-09, the '
              'highest grade 10, component 0 ()',
            ),
            evaluationId: _newId,
          ),
        ),
      );
    });

    test('when it came back public, it names the evaluation, and changes '
        'nothing', () async {
      final publications = {
        // Published: the flag without a time.
        ('1', ''): SkorePublicationState.published,
        // Scheduled: the flag with a time to come.
        ('1', '2026-10-09T08:00:00'): SkorePublicationState.scheduled,
      };
      for (final MapEntry(key: (public, at), value: state)
          in publications.entries) {
        final server = _Skore(
          listAs: (entry) {
            entry['public'] = public;
            entry['publicdatetime'] = at;
          },
        );
        await expectLater(
          create(await serve(server)),
          throwsA(
            allOf(
              isNot(isA<SmartschoolSkoreError>()),
              isNot(isA<SmartschoolSkoreSaveUnconfirmedError>()),
              isA<SmartschoolSkoreEvaluationPublicError>()
                  .having((e) => e.evaluation.id, 'evaluation.id', _newId)
                  .having((e) => e.evaluation.publication.state, 'state', state)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains(
                        'evaluation "Toets 1" ($_newId) was created in period '
                        'DW1 (1704) of gradebook 32508, but Skore shows it as '
                        '${state.name}',
                      ),
                      contains('check the evaluation in Smartschool'),
                    ),
                  ),
            ),
          ),
        );
        // It was sent unpublished, and nothing tried to undo it.
        expect(server.saved[12], 0);
        expect(server.saved[17], '');
        expect(server.methods.last, 'getEvaluations');
        expect(
          server.methods.where((m) => m == 'saveEvaluation'),
          hasLength(1),
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The components
  // ---------------------------------------------------------------------------

  group('getComponents', () {
    test("reads the components of the gradebook's period", () async {
      final server = _Skore();
      final components = await (await serve(server)).getComponents(_ewi, 1704);

      expect(
        [for (final c in components) (c.id, c.name, c.isNone)],
        [(0, 'geen', true), (2, 'DW', false)],
      );
      expect(server.methods, ['getPosComponents']);
      expect(server.calls.single.params, [0, 1704, '472', '2264', _pathIds]);
      expect(server.calls.single.session['wy'], '24');
    });

    test(
      'refuses a period ID that is not one before anything is sent',
      () async {
        final server = _Skore();
        await expectLater(
          (await serve(server)).getComponents(_ewi, 0),
          throwsA(isA<ArgumentError>()),
        );
        expect(server.requests, isEmpty);
      },
    );

    test('parseComponents refuses another shape', () {
      expect(
        SkoreGradebookService.parseComponents([
          [0, ' geen '],
          [2, 'DW'],
        ]).map((c) => (c.id, c.name)),
        [(0, 'geen'), (2, 'DW')],
      );
      expect(SkoreGradebookService.parseComponents([]), isEmpty);
      for (final shape in <Object?>[
        null,
        {'comps': []},
        [
          [0],
        ],
        [
          [-1, 'x'],
        ],
        [
          ['DW', 'DW'],
        ],
        [
          [2, null],
        ],
        ['2'],
      ]) {
        expect(
          () => SkoreGradebookService.parseComponents(shape),
          throwsA(isA<SmartschoolSkoreError>()),
          reason: jsonEncode(shape),
        );
      }
    });
  });
}
