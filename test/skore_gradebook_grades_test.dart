// Tests for issue #151: saving pupils' grades in an evaluation of the
// teacher's own gradebook (`SkoreGradebookService.saveGrade` and
// `saveGrades`).
//
// What the web client sends for a cell of an evaluation, on Skore's
// gradebook RPC service (/modules/Skore/backend/gradebook/rpc.php):
//   saveGrade(col, row, grade, userID, projectID, catID, courseID, catType,
//       pathIds, evaluationID, ownerID)
// with col the evaluation's refID, row `pupil_<pupilId>_<classId>`, catType,
// evaluationID and ownerID the p[1], p[2] and p[3] of the cell (strings), and
// projectID, catID and courseID 0. Verified live once (2026-10-08, in 6EWI,
// with the developer's go-ahead, in a test evaluation with max 20, each value
// read again with getEvaluations): "15", "15.5" and "12,5" were answered
// `{"savedState":1,"postEvalData":null,"stream":[...],"grade":"12.5"}` (the
// server turns "," into "."), "" cleared the grade, and "25" (above max) got
// HTTP 500 with `{"message":"Internal Server Error"}` and Smartschool's
// "Oeps, er ging iets mis" page, and was not saved.
//
// The fake Skore below answers in the shape of those captures, with fake
// pupils, teachers and evaluation IDs; class, group, model, course,
// gradebook and period IDs are Skore's own, as in the other gradebook tests.
// It keeps the grades, applies what saveGrade sends as Skore did, and lists
// them from then on. Nothing here reaches Skore: the fake fails the test on
// any RPC method outside SkoreGradebookService.rpcMethods (and on the
// publishing ones in any case), and on any other request than the reads of
// the current user and a login.
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

/// The time of the tests: the day of the live check.
final _now = DateTime.utc(2026, 10, 8, 10);

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

/// The pupils of 6EWI (fake IDs), and one of 6WEWI2, whose rows Skore sends
/// along.
const _an = 1201;
const _bart = 1202;
const _cas = 1203;
const _otherClass = 1301;

/// The evaluations of 6EWI's DW1 (fake IDs).
const _toets = 500003; // unpublished, max 20: the one written to
const _scheduled = 500001; // public from 2026-10-09 08:00
const _published = 500002; // public since 2026-10-01 08:00
const _planner = 500004; // from the planner
const _scale = 500005; // on a scale

/// An evaluation of the fake Skore, with its grades (`raw`) by pupil.
class _Evaluation {
  _Evaluation(
    this.id, {
    this.title = 'Toets 1',
    this.max = 20,
    this.evaltype = 1,
    this.planner = 0,
    this.public = '0',
    this.publicDateTime = '',
    Map<int, String> grades = const {},
  }) : grades = {_an: '', _bart: '', _cas: '', ...grades};

  final int id;
  final String title;
  final Object? max;
  final int evaltype;
  final int planner;
  final String public;
  final String publicDateTime;
  final Map<int, String> grades;
}

/// DW1 as the tests start: Toets 1 with An's 12, and the others.
List<_Evaluation> _dw1() => [
  _Evaluation(_toets, grades: {_an: '12'}),
  _Evaluation(
    _scheduled,
    title: 'Python scripts schrijven',
    max: 100,
    public: '1',
    publicDateTime: '2026-10-09T08:00:00',
  ),
  _Evaluation(
    _published,
    title: 'Lussen',
    public: '1',
    publicDateTime: '2026-10-01T08:00:00',
  ),
  _Evaluation(_planner, title: 'Taak uit de planner', planner: 1),
  _Evaluation(_scale, title: 'Houding', evaltype: 2, max: null),
];

/// An RPC answer of Skore with [result].
String _answer(String method, Object? result) => jsonEncode({
  'result': result,
  'session': 1,
  'method': method,
  'timelimit': 0,
  'limitInfo': null,
});

/// getNavigation of 2026-2027 with 6EWI (32508), the teacher's.
Map<String, Object?> _navigation() => {
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
            {
              'raw': '6EWI',
              'crum': {'ids': _pathIds},
              'data': [
                {
                  'coursename': 'Informaticawetenschappen (2 uur) (6e j DO)',
                  'data': {
                    'ownerID': '32508',
                    'userID': '$_me',
                    'classID': '2440',
                    'groupID': '472',
                    'modelID': '176',
                    'courseID': '2264',
                    'structureID': '1564',
                  },
                  'part': ['Janssens Jan'],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
  'workyears': [
    ['24', '2026-2027'],
    ['22', '2025-2026'],
  ],
  'currentWorkyear': '24',
};

/// init of 6EWI: DW1 (1704), open unless [dw1Open] is 0.
Map<String, Object?> _init({int dw1Open = 1}) => {
  'left_0': {
    'stream': [
      {'c': 0, 'r': 'clavg_2440', 'v': '6EWI : Klasgemiddelde'},
      for (final (id, name) in [
        (_an, 'Aerts, An'),
        (_bart, 'Claes, Bart'),
        (_cas, 'Dewulf, Cas'),
      ])
        {
          'c': 0,
          'r': 'pupil_${id}_2440',
          'v': '<span>${id - 1200}.  $name</span>',
        },
    ],
  },
  'periods': [
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
  'activePeriodE': 0,
  'ownerMap': [
    {
      'courseID': '2264',
      'groupID': '472',
      'coursename': _courseName,
      'ownerID': '32508',
      'classID': '2440',
    },
  ],
};

/// getGradebookContext of 6EWI's DW1.
Map<String, Object?> _context({int writable = 1}) => {
  'writable': writable,
  'coordinator': 0,
  'modelId': 176,
  'groupId': 472,
  'classId': 2440,
  'periodId': 1704,
  'courses': [2264],
  'owners': [32508],
  'teacherId': _me,
};

/// A grade cell's HTML as Skore gives it: `raw` with a point, the text with
/// a comma.
String _cellHtml(String raw) =>
    '<div class="gbc" raw="$raw">${raw.replaceAll('.', ',')}</div>'
    '<div class="gbc_cell_header"><span onmousedown="skore.gbc.onCellMessage();" '
    'class="gbc_message_place" >&nbsp;&nbsp;</span></div>'
    '<div class="gbc_presence "><div></div><div></div></div>';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// What Skore answered a grade above max (seen live): HTTP 500 with a JSON
/// line and Smartschool's error page.
const _serverError = (
  status: 500,
  body:
      '{"message":"Internal Server Error"}<!DOCTYPE html>\n<html><head>'
      '<title></title></head><body><h1>Oeps, er ging iets mis</h1></body>'
      '</html>',
);

/// An RPC call as it reached the fake Skore.
typedef _Call = ({
  String method,
  List<dynamic> params,
  Map<String, dynamic> session,
});

/// A Skore that answers the reads of 6EWI, keeps the grades of DW1's
/// evaluations, and applies saveGrade as Skore did live: `,` becomes `.`, a
/// grade above max is answered with HTTP 500 and not saved.
class _Skore implements HttpClientAdapter {
  _Skore({
    Map<String, _Answer> answers = const {},
    List<_Evaluation>? evaluations,
    this.saveAnswers = const {},
    this.dropSaveOf = const {},
    this.forgetSaveOf = const {},
    this.unauthorizedOnce = const {},
    this.loginFails = false,
    this.listAs,
    this.evaluationsAnswer,
  }) : evaluations = evaluations ?? _dw1(),
       answers = {
         'getNavigation': _ok(_answer('getNavigation', _navigation())),
         'init': _ok(_answer('init', _init())),
         'getGradebookContext': _ok(_answer('getGradebookContext', _context())),
         ...answers,
       };

  final Map<String, _Answer> answers;

  final List<_Evaluation> evaluations;

  /// The answer to the save of a pupil, instead of saving it.
  final Map<int, _Answer> saveAnswers;

  /// The pupils whose save fails after it went out, as a connection that
  /// drops (not saved).
  final Set<int> dropSaveOf;

  /// The pupils whose save is answered with savedState 1 but not kept.
  final Set<int> forgetSaveOf;

  /// The pupils whose first save Smartschool answers with a 401 (a refused
  /// session).
  final Set<int> unauthorizedOnce;

  /// Whether a login fails: the password is answered with the login page
  /// again.
  final bool loginFails;

  /// Changes the answer of getEvaluations before it is sent.
  final void Function(Map<String, Object?> result)? listAs;

  /// The answer to the [call]th getEvaluations (from 0), or `null` for the
  /// grades as kept.
  final _Answer? Function(int call)? evaluationsAnswer;

  /// Every RPC call that reached it, in order.
  final List<_Call> calls = [];

  /// Every request that reached it: `METHOD path`, `RPC <method>` for an RPC
  /// call.
  final List<String> requests = [];

  /// The RPC methods called, in order.
  List<String> get methods => [for (final c in calls) c.method];

  /// The parameters of the saveGrade calls, in order.
  List<List<dynamic>> get saves => [
    for (final c in calls)
      if (c.method == 'saveGrade') c.params,
  ];

  int _evaluationsCalls = 0;

  _Evaluation _evaluation(int id) => evaluations.singleWhere((e) => e.id == id);

  /// getEvaluations of 6EWI's DW1, with the rows of 6WEWI2 Skore sends
  /// along.
  Map<String, Object?> _evaluations() => {
    'head': [
      for (final e in evaluations)
        {
          'formula': '',
          'title': e.title,
          'short': null,
          'date': '2026-10-08',
          'componentID': 2,
          'component': 'DW',
          'periodID': 1704,
          'courseID': '2264',
          'coursename': _courseName,
          'public': e.public,
          'publicdatetime': e.publicDateTime,
          'max': e.max,
          'refID': '${e.id}',
          'colID': 'A',
          'evaltype': e.evaltype,
          'evaluationID': '${e.id}',
          'ownerID': '32508',
          'isPlannerEval': e.planner,
          'groupID': 472,
        },
    ],
    'details': {
      'stream': [
        for (final e in evaluations) ...[
          for (final MapEntry(key: pupil, value: raw) in e.grades.entries)
            {
              'c': '${e.id}',
              'r': 'pupil_${pupil}_2440',
              'v': _cellHtml(raw),
              'p': [1, 0, '${e.id}', '32508', e.id],
            },
          {
            'c': '${e.id}',
            'r': 'clavg_2440',
            'v': _cellHtml(''),
            'p': [0],
          },
          {
            'c': '${e.id}',
            'r': 'pupil_${_otherClass}_2444',
            'v': '<div class="gbc" ></div>',
            'p': [1, 0, 0, '32504', -1],
          },
        ],
      ],
    },
    'periodStatus': 1,
    'evalType': 1,
    'archive': <Object?>[],
  };

  /// What Skore answered a save (seen live): the pupil's cell, the class and
  /// group averages, and the grade as kept.
  String _saved(int evaluationId, String row, String grade) =>
      _answer('saveGrade', {
        'savedState': 1,
        'postEvalData': null,
        'stream': [
          {
            'c': evaluationId,
            'r': row,
            'v': _cellHtml(grade),
            'p': [1, 0, '$evaluationId', '32508'],
          },
          {'c': evaluationId, 'r': 'clavg_2440', 'v': _cellHtml(grade)},
          {'c': evaluationId, 'r': 'gravg_472', 'v': _cellHtml(grade)},
        ],
        'grade': grade,
      });

  _Answer _save(List<dynamic> params, RequestOptions options) {
    final evaluation = _evaluation(int.parse(params[0] as String));
    final row = params[1] as String;
    final pupil = int.parse(row.split('_')[1]);
    final answer = saveAnswers[pupil];
    if (answer != null) return answer;
    if (dropSaveOf.contains(pupil)) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection closed before full header was received',
        error: const SocketException('Connection reset by peer'),
      );
    }
    final grade = (params[2] as String).replaceAll(',', '.');
    final number = num.tryParse(grade);
    if (number != null && number > (evaluation.max as num)) {
      return _serverError;
    }
    if (!forgetSaveOf.contains(pupil)) evaluation.grades[pupil] = grade;
    return _ok(_saved(evaluation.id, row, grade));
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
      // A login, after a refused session.
      case ('GET', '/login'):
        requests.add('GET /login');
        return _body(_loginPage);
      case ('POST', '/login'):
        requests.add('POST /login');
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [loginFails ? '/login' : '/'],
          },
        );
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Never let a publishing call through, nor anything off the list.
        expect(method, isNot(anyOf('setPublicProp', 'saveEvalProperties')));
        expect(SkoreGradebookService.rpcMethods, contains(method));
        final params = jsonDecode(form['rpc_params']!) as List<dynamic>;
        calls.add((
          method: method,
          params: params,
          session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
        ));
        requests.add('RPC $method');
        final _Answer? answer;
        if (method == 'saveGrade') {
          final pupil = int.parse((params[1] as String).split('_')[1]);
          answer = unauthorizedOnce.contains(pupil) && _refused.add(pupil)
              ? (status: 401, body: '')
              : _save(params, options);
        } else if (method == 'getEvaluations') {
          final result = _evaluations();
          listAs?.call(result);
          answer =
              evaluationsAnswer?.call(_evaluationsCalls++) ??
              _ok(_answer(method, result));
        } else {
          answer = answers[method];
        }
        if (answer == null) fail('No answer for $method');
        return _body(
          answer.body,
          status: answer.status,
          type: 'application/json; charset=utf-8',
        );
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  final Set<int> _refused = {};

  @override
  void close({bool force = false}) {}
}

/// The parameters of saveGrade for [pupil] in [evaluation], as the web
/// client sends them for a cell (verified live).
List<Object?> _saveParams(int pupil, String grade, {int evaluation = _toets}) =>
    [
      '$evaluation',
      'pupil_${pupil}_2440',
      grade,
      _me,
      0,
      0,
      0,
      '0',
      _pathIds,
      '$evaluation',
      '32508',
    ];

/// A [SmartschoolSkoreChangeRefusedError] of [operation] whose message holds
/// [reason].
Matcher _refused(Object reason, {String operation = 'saveGrade'}) =>
    isA<SmartschoolSkoreChangeRefusedError>()
        .having(
          (e) => e.message,
          'message',
          allOf(startsWith('$operation: '), contains(reason)),
        )
        .having((e) => e.message, 'message', endsWith('Nothing was saved.'));

/// A [SmartschoolSkoreGradeSaveUnconfirmedError] about Toets 1.
Matcher _unconfirmed({
  required Map<int, String> grades,
  required Map<int, Object> unconfirmed,
  Map<int, String?> confirmed = const {},
  Object? cause = isNull,
  Object? message = anything,
}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>(),
  isA<SmartschoolSkoreGradeSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having(
        (e) => e.message,
        'message',
        endsWith(
          'Saving a grade again is harmless: read the grades again '
          '(getResults) and save the ones that differ.',
        ),
      )
      .having((e) => e.gradebookId, 'gradebookId', 32508)
      .having((e) => e.periodId, 'periodId', 1704)
      .having((e) => e.evaluationId, 'evaluationId', _toets)
      .having((e) => e.grades, 'grades', grades)
      .having(
        (e) => {
          for (final MapEntry(:key, :value) in e.confirmed.entries)
            key: value.grade,
        },
        'confirmed',
        confirmed,
      )
      .having((e) => e.unconfirmed.keys, 'unconfirmed pupils', unconfirmed.keys)
      .having((e) => e.unconfirmed, 'unconfirmed', {
        for (final MapEntry(:key, :value) in unconfirmed.entries) key: value,
      })
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

  /// The evaluation [id] of DW1 as getEvaluations reads it now.
  Future<SkoreEvaluation> read(
    SkoreGradebookService gradebooks, [
    int id = _toets,
  ]) async => (await gradebooks.getEvaluations(
    _ewi,
    1704,
  )).singleWhere((e) => e.id == id);

  /// Serves [server], reads evaluation [id] and forgets the calls of that
  /// read, so that the test sees only those of the write.
  Future<(SkoreGradebookService, SkoreEvaluation)> ready(
    _Skore server, [
    int id = _toets,
  ]) async {
    final gradebooks = await serve(server);
    final evaluation = await read(gradebooks, id);
    server.calls.clear();
    server.requests.clear();
    return (gradebooks, evaluation);
  }

  // ---------------------------------------------------------------------------
  // The allowlist
  // ---------------------------------------------------------------------------

  test('saveGrade joins the allowlist; saveGradeColumn, saveGradeInfo and '
      'the publishing calls do not', () {
    expect(SkoreGradebookService.rpcMethods, contains('saveGrade'));
    for (final method in [
      'saveGradeColumn',
      'saveGradeInfo',
      'saveType',
      'getEvaluationIDByOwnerID',
      'setPublicProp',
      'saveEvalProperties',
    ]) {
      expect(SkoreGradebookService.rpcMethods, isNot(contains(method)));
      expect(
        () => SkoreGradebookService.checkRpcMethod(method),
        throwsA(isA<ArgumentError>()),
        reason: method,
      );
    }
  });

  // ---------------------------------------------------------------------------
  // The save
  // ---------------------------------------------------------------------------

  group('saveGrade', () {
    test('checks, saves the grade, and returns the cell as Skore lists it '
        'again', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      final grade = await gradebooks.saveGrade(_ewi, evaluation, _an, '15.5');

      expect(server.methods, [
        'getNavigation', // the own gradebooks of the current school year
        'init', // the period: one of the gradebook's, open
        'getGradebookContext', // writable in that period
        'getEvaluations', // the evaluation and the cell, as they are now
        'saveGrade',
        'getEvaluations', // the check
      ]);
      expect(server.calls.first.session.containsKey('wy'), isFalse);
      for (final call in server.calls.skip(1)) {
        expect(call.session['wy'], '24', reason: call.method);
        expect(call.session['teacher'], _me, reason: call.method);
        expect(call.session['restriction'], 0, reason: call.method);
      }
      // The exact parameters: strings and numbers as the web client sends
      // them (equals tells "0" from 0).
      final saved = server.saves.single;
      expect(saved, _saveParams(_an, '15.5'));
      expect(
        [for (final p in saved) p.runtimeType.toString()],
        [
          'String',
          'String',
          'String',
          'int',
          'int',
          'int',
          'int',
          'String',
          'List<dynamic>',
          'String',
          'String',
        ],
      );

      expect(grade.pupilId, _an);
      expect(grade.classId, 2440);
      expect(grade.grade, '15.5');
      expect(grade.value, 15.5);
      expect(server.evaluations.first.grades[_an], '15.5');
    });

    test('sends a plain decimal with a point: a comma, spaces and zeros are '
        'normalised; null and blank clear the grade', () async {
      final cases = <String?, (String sent, String? listed)>{
        '15': ('15', '15'),
        '15.5': ('15.5', '15.5'),
        '12,5': ('12.5', '12.5'),
        ' 7 ': ('7', '7'),
        '015,50': ('15.5', '15.5'),
        '20.0': ('20', '20'),
        '20': ('20', '20'), // the highest grade itself
        '0': ('0', '0'),
        '0,0': ('0', '0'),
        null: ('', null),
        '': ('', null),
        '   ': ('', null),
      };
      for (final MapEntry(key: grade, value: (sent, listed)) in cases.entries) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server);

        final cell = await gradebooks.saveGrade(_ewi, evaluation, _an, grade);

        expect(server.saves, [_saveParams(_an, sent)], reason: '$grade');
        expect(cell.grade, listed, reason: '$grade');
      }
    });

    test('into a published or scheduled evaluation with allowPublished: '
        'true', () async {
      for (final id in [_scheduled, _published]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server, id);
        expect(evaluation.publication.isPublic, isTrue);

        final cell = await gradebooks.saveGrade(
          _ewi,
          evaluation,
          _bart,
          '9',
          allowPublished: true,
        );

        expect(server.saves, [_saveParams(_bart, '9', evaluation: id)]);
        expect(cell.grade, '9');
      }
    });

    test('a 401 for the save logs in and sends it again: a grade saved twice '
        'is the same grade', () async {
      final server = _Skore(unauthorizedOnce: {_an});
      final (gradebooks, evaluation) = await ready(server);

      final cell = await gradebooks.saveGrade(_ewi, evaluation, _an, '14');

      expect(cell.grade, '14');
      expect(server.saves, [_saveParams(_an, '14'), _saveParams(_an, '14')]);
      expect(server.requests.where((r) => r == 'POST /login'), hasLength(1));
      expect(server.methods.last, 'getEvaluations');
    });
  });

  group('saveGrades', () {
    test('saves the grades in turn, reads the period again once, and returns '
        'the cells by pupil in the order given', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      final grades = await gradebooks.saveGrades(_ewi, evaluation, {
        _cas: '15',
        _an: null,
        _bart: '12,5',
      });

      expect(server.methods, [
        'getNavigation',
        'init',
        'getGradebookContext',
        'getEvaluations',
        'saveGrade',
        'saveGrade',
        'saveGrade',
        'getEvaluations',
      ]);
      expect(server.saves, [
        _saveParams(_cas, '15'),
        _saveParams(_an, ''),
        _saveParams(_bart, '12.5'),
      ]);
      expect(grades.keys, [_cas, _an, _bart]);
      expect(
        {for (final e in grades.entries) e.key: e.value.grade},
        {_cas: '15', _an: null, _bart: '12.5'},
      );
    });

    test('with no grades, reads and sends nothing', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      expect(await gradebooks.saveGrades(_ewi, evaluation, {}), isEmpty);
      expect(server.requests, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The checks
  // ---------------------------------------------------------------------------

  group('refuses, saving nothing,', () {
    test('a grade that is not a number of 0 or more, or a pupil ID that is '
        'not positive, before anything is sent', () async {
      for (final grade in [
        '-1',
        '-0.5',
        'abc',
        '15.',
        ',5',
        '1e1',
        '15,5,5',
        '15 5',
        '+3',
        'AFW',
      ]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, grade),
          throwsA(_refused('the grade ${jsonEncode(grade)} of pupil $_an')),
          reason: grade,
        );
        expect(server.requests, isEmpty, reason: grade);
      }
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {0: '15', -5: '15', _an: 'x'}),
        throwsA(
          _refused(
            '0 is not a pupil ID; -5 is not a pupil ID; the grade "x" of '
            'pupil $_an',
            operation: 'saveGrades',
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('a grade above the highest grade, which Skore answers with HTTP '
        '500', () async {
      for (final grade in ['25', '20.5', '20,01', '100']) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, grade),
          throwsA(
            _refused(
              'in evaluation $_toets ("Toets 1") in period DW1 (1704) of '
              'gradebook 32508, the grade',
            ),
          ),
          reason: grade,
        );
        expect(server.methods, isNot(contains('saveGrade')), reason: grade);
      }
    });

    test('a pupil without a cell of the class in the evaluation: of another '
        'class, or unknown', () async {
      for (final pupil in [_otherClass, 9999]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, pupil, '15'),
          throwsA(
            _refused('pupil $pupil has no cell in its rows of class 2440'),
          ),
        );
        expect(server.methods, isNot(contains('saveGrade')));
      }
    });

    test('a cell without an evaluation ID', () async {
      final server = _Skore(
        listAs: (result) {
          for (final cell
              in (result['details'] as Map)['stream'] as List<Object?>) {
            cell as Map<String, Object?>;
            if (cell['r'] == 'pupil_${_bart}_2440') {
              (cell['p'] as List<Object?>)[2] = '0';
            }
          }
        },
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrade(_ewi, evaluation, _bart, '15'),
        throwsA(_refused('the cell of pupil $_bart has no evaluation ID')),
      );
      expect(server.methods, isNot(contains('saveGrade')));
    });

    test('a batch with one refused pupil: none is saved', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {
          _an: '15',
          _otherClass: '14',
          _bart: '21',
        }),
        throwsA(
          _refused(
            'pupil $_otherClass has no cell in its rows of class 2440; the '
            'grade 21 of pupil $_bart is above the highest grade, 20',
            operation: 'saveGrades',
          ),
        ),
      );
      expect(server.methods, isNot(contains('saveGrade')));
      expect(server.evaluations.first.grades[_an], '12');
    });

    test(
      'a published or a scheduled evaluation, without allowPublished',
      () async {
        for (final (id, state, seen) in [
          (_published, 'published', 'at once'),
          (_scheduled, 'scheduled to be published', 'from then on'),
        ]) {
          final server = _Skore();
          final (gradebooks, evaluation) = await ready(server, id);
          await expectLater(
            gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
            throwsA(
              _refused(
                'is $state (public "1", publicdatetime "${id == _published ? '2026-10-01T08:00:00' : '2026-10-09T08:00:00'}"): '
                'its pupils see what is written in it $seen. Pass '
                'allowPublished: true',
              ),
            ),
          );
          expect(server.methods, isNot(contains('saveGrade')));
        }
      },
    );

    test('an evaluation Skore lists as public now, whatever the evaluation '
        'passed says', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);
      expect(evaluation.publication.isPublic, isFalse);
      // Published in Smartschool since it was read.
      server.evaluations[0] = _Evaluation(
        _toets,
        public: '1',
        publicDateTime: '2026-10-08T08:00:00',
      );

      await expectLater(
        gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
        throwsA(_refused('is published (public "1"')),
      );
      expect(server.methods, isNot(contains('saveGrade')));
    });

    test('an evaluation from the planner, on a scale, or without a highest '
        'grade', () async {
      final cases = <String, (List<_Evaluation>, int, String)>{
        'from the planner': (
          _dw1(),
          _planner,
          'comes from the planner (isPlannerEval 1)',
        ),
        'on a scale': (_dw1(), _scale, 'is not in points (evaltype 2)'),
        'without a highest grade': (
          [_Evaluation(_toets, max: null)],
          _toets,
          'has no highest grade to check grades against',
        ),
      };
      for (final MapEntry(key: name, value: (evaluations, id, reason))
          in cases.entries) {
        final server = _Skore(evaluations: evaluations);
        final (gradebooks, evaluation) = await ready(server, id);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
          throwsA(_refused(reason)),
          reason: name,
        );
        expect(server.methods, isNot(contains('saveGrade')), reason: name);
      }
    });

    test('an evaluation of another gradebook (before anything is sent), or '
        'one Skore no longer lists', () async {
      var server = _Skore();
      var (gradebooks, evaluation) = await ready(server);
      final foreign = SkoreEvaluation(
        id: evaluation.id,
        evaluationId: evaluation.evaluationId,
        gradebookId: 32504,
        periodId: 1704,
        column: 'A',
        title: 'Toets 1',
        shortName: null,
        date: evaluation.date,
        max: 20,
        componentId: 2,
        componentName: 'DW',
        type: SkoreEvaluationType.points,
        typeCode: 1,
        courseId: 2264,
        courseName: _courseName,
        isPlannerEvaluation: false,
        publication: evaluation.publication,
        results: evaluation.results,
      );
      await expectLater(
        gradebooks.saveGrade(_ewi, foreign, _an, '15'),
        throwsA(
          _refused(
            'evaluation $_toets is one of gradebook 32504, not of gradebook '
            '32508',
          ),
        ),
      );
      expect(server.requests, isEmpty);

      server = _Skore();
      (gradebooks, evaluation) = await ready(server);
      server.evaluations.removeAt(0); // moved to the trash
      await expectLater(
        gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
        throwsA(
          _refused(
            'Skore no longer lists evaluation $_toets in period DW1 (1704) of '
            'gradebook 32508',
          ),
        ),
      );
      expect(server.methods, isNot(contains('saveGrade')));
    });

    test('a closed period, or one Skore shows read-only', () async {
      final cases = <String, (Map<String, _Answer>, String)>{
        'closed': (
          {'init': _ok(_answer('init', _init(dw1Open: 0)))},
          'period DW1 (1704) of gradebook 32508 is closed',
        ),
        'read-only': (
          {
            'getGradebookContext': _ok(
              _answer('getGradebookContext', _context(writable: 0)),
            ),
          },
          'read-only to you in period DW1 (1704) (writable 0)',
        ),
      };
      for (final MapEntry(key: name, value: (answers, reason))
          in cases.entries) {
        final server = _Skore(answers: answers);
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
          throwsA(_refused(reason)),
          reason: name,
        );
        expect(server.methods, [
          'getNavigation',
          'init',
          if (name == 'read-only') 'getGradebookContext',
        ], reason: name);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Unconfirmed
  // ---------------------------------------------------------------------------

  group('unconfirmed:', () {
    test('a batch with one failed save goes on with the others, and tells '
        'per pupil what is confirmed', () async {
      final server = _Skore(saveAnswers: {_bart: _serverError});
      final (gradebooks, evaluation) = await ready(server);

      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {
          _an: '15',
          _bart: '13',
          _cas: '11',
        }),
        throwsA(
          _unconfirmed(
            grades: {_an: '15', _bart: '13', _cas: '11'},
            confirmed: {_an: '15', _cas: '11'},
            unconfirmed: {
              _bart: allOf(
                startsWith('no usable answer came in'),
                contains('HTTP 500'),
                endsWith('reading the period again shows no grade'),
              ),
            },
            cause: isA<SmartschoolSkoreError>(),
            message: allOf(
              startsWith(
                'saveGrades: the grades of 3 pupils in evaluation $_toets '
                '("Toets 1") in period DW1 (1704) of gradebook 32508 went '
                'out, but Skore does not confirm 1 of them: pupil $_bart '
                '("13"): no usable answer came in',
              ),
              contains('The others are confirmed.'),
            ),
          ),
        ),
      );
      expect(server.saves, [
        _saveParams(_an, '15'),
        _saveParams(_bart, '13'),
        _saveParams(_cas, '11'),
      ]);
      expect(server.methods.last, 'getEvaluations');
      expect(server.methods.where((m) => m == 'getEvaluations'), hasLength(2));
    });

    test('a save not answered with savedState 1', () async {
      final answers = <String, _Answer>{
        'savedState -1': _ok(_answer('saveGrade', {'savedState': -1})),
        'savedState 0': _ok(_answer('saveGrade', {'savedState': 0})),
        'no savedState': _ok(_answer('saveGrade', {'grade': '15'})),
        'no object': _ok(_answer('saveGrade', true)),
      };
      for (final MapEntry(key: name, value: answer) in answers.entries) {
        final server = _Skore(saveAnswers: {_an: answer});
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
          throwsA(
            _unconfirmed(
              grades: {_an: '15'},
              unconfirmed: {
                _an: allOf(
                  startsWith('Skore answered '),
                  contains('instead of savedState 1'),
                  endsWith('reading the period again shows "12"'),
                ),
              },
              message: startsWith(
                'saveGrade: the grade in evaluation $_toets ("Toets 1") in '
                'period DW1 (1704) of gradebook 32508 went out, but Skore '
                'does not confirm it: pupil $_an ("15"): Skore answered',
              ),
            ),
          ),
          reason: name,
        );
      }
    });

    test('an answer that is not JSON, or a connection that drops', () async {
      final cases = <String, (_Skore, Object)>{
        'an HTML page': (
          _Skore(
            saveAnswers: {
              _an: _ok('<!DOCTYPE html><html><title>Oeps</title></html>'),
            },
          ),
          isA<SmartschoolSkoreError>(),
        ),
        'a dropped connection': (
          _Skore(dropSaveOf: {_an}),
          isA<SmartschoolConnectionError>(),
        ),
      };
      for (final MapEntry(key: name, value: (server, cause)) in cases.entries) {
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
          throwsA(
            _unconfirmed(
              grades: {_an: '15'},
              unconfirmed: {_an: startsWith('no usable answer came in')},
              cause: cause,
            ),
          ),
          reason: name,
        );
        expect(server.methods.last, 'getEvaluations', reason: name);
      }
    });

    test('reading again shows another grade, fails, or does not list the '
        'evaluation', () async {
      var server = _Skore(forgetSaveOf: {_an});
      var (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {_an: '15', _bart: '16'}),
        throwsA(
          _unconfirmed(
            grades: {_an: '15', _bart: '16'},
            confirmed: {_bart: '16'},
            unconfirmed: {_an: 'reading the period again shows "12"'},
          ),
        ),
      );

      server = _Skore(
        evaluationsAnswer: (call) =>
            call == 2 ? (status: 500, body: 'Internal error') : null,
      );
      (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrade(_ewi, evaluation, _an, '15'),
        throwsA(
          _unconfirmed(
            grades: {_an: '15'},
            unconfirmed: {
              _an: startsWith(
                'reading the period again to check it failed '
                '(SmartschoolSkoreError: ',
              ),
            },
            cause: isA<SmartschoolSkoreError>(),
          ),
        ),
      );
      expect(server.saves, hasLength(1));

      server = _Skore(
        evaluationsAnswer: (call) => call == 2
            ? _ok(
                _answer('getEvaluations', {
                  'head': <Object?>[],
                  'details': {'stream': 1},
                }),
              )
            : null,
      );
      (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrade(_ewi, evaluation, _an, ''),
        throwsA(
          _unconfirmed(
            grades: {_an: ''},
            unconfirmed: {
              _an: 'reading the period again does not list the evaluation',
            },
            message: contains('pupil $_an (cleared)'),
          ),
        ),
      );
    });

    test('Skore answers the first save without a session: the session '
        'error, nothing saved, nothing more sent', () async {
      final server = _Skore(
        saveAnswers: {_an: _ok('{"result":null,"method":"saveGrade"}')},
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {_an: '15', _bart: '16'}),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.methods.last, 'saveGrade');
      expect(server.saves, [_saveParams(_an, '15')]);
    });

    test('a login that fails for a later save: the pupils after it are not '
        'sent, and no login per pupil', () async {
      final server = _Skore(unauthorizedOnce: {_bart}, loginFails: true);
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {
          _an: '15',
          _bart: '16',
          _cas: '17',
        }),
        throwsA(
          _unconfirmed(
            grades: {_an: '15', _bart: '16', _cas: '17'},
            // The read afterwards logs in first, and fails too.
            unconfirmed: {
              _an: startsWith('reading the period again to check it failed'),
              _bart: startsWith('Smartschool did not accept the session ('),
              _cas: startsWith(
                'not sent, as Smartschool did not accept the session for an '
                'earlier save',
              ),
            },
            cause: isA<SmartschoolAuthenticationError>(),
          ),
        ),
      );
      expect(server.saves, [_saveParams(_an, '15'), _saveParams(_bart, '16')]);
      // One login for the refused save, one before the read afterwards.
      expect(server.requests.where((r) => r == 'POST /login'), hasLength(2));
      expect(server.methods.last, 'saveGrade');
    });

    test('Skore answers a later save without a session: the pupils after it '
        'are not sent', () async {
      final server = _Skore(
        saveAnswers: {_bart: _ok('{"result":null,"method":"saveGrade"}')},
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveGrades(_ewi, evaluation, {
          _an: '15',
          _bart: '16',
          _cas: '17',
        }),
        throwsA(
          _unconfirmed(
            grades: {_an: '15', _bart: '16', _cas: '17'},
            confirmed: {_an: '15'},
            unconfirmed: {
              _bart: startsWith(
                'Smartschool did not accept the session '
                '(SmartschoolSessionExpiredError: ',
              ),
              _cas: startsWith(
                'not sent, as Smartschool did not accept the session for an '
                'earlier save; reading the period again shows no grade',
              ),
            },
            cause: isA<SmartschoolSessionExpiredError>(),
          ),
        ),
      );
      expect(server.saves, [_saveParams(_an, '15'), _saveParams(_bart, '16')]);
      expect(server.methods.last, 'getEvaluations');
    });
  });
}
