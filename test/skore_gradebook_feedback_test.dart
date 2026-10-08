// Tests for issue #152: giving a pupil written feedback on an evaluation of
// the teacher's own gradebook, or changing the feedback the teacher gave
// before (`SkoreGradebookService.saveFeedback`).
//
// What the feedback panel of /SkoreGradebook sends, on Skore's REST API, with
// a JSON body and `x-requested-with: XMLHttpRequest` (verified live once,
// 2026-10-08, with the developer's go-ahead, in a test evaluation that went
// to the trash afterwards):
//   create: POST /skore/api/v1/gradebook/feedback
//     {"evaluation":{"evaluationId":"4069_<refID>","classGroupId":
//      "4069_<classId>","teacherId":"4069_<userId>_0","context":
//      "<modelId>_<groupId>_<classId>"},"studentId":"4069_<pupilId>_0",
//      "text":"...","attachments":[]}
//     → 200 with the new feedback, in the shape of the GET's items (a UUID
//       `id`, `createdAt` = `changedAt`);
//   update: POST /skore/api/v1/gradebook/feedback/{id}
//     {"id":"<id>","evaluation":{...},"studentId":"...","text":"...",
//      "attachments":[...]}
//     → 200 with the feedback: the same `id`, the new `text`, `changedAt`
//       updated, `createdAt` kept;
//   a second create adds a second feedback of the same teacher: it is not
//   an upsert.
//
// The fake Skore below answers the gradebook reads in the shape of the live
// ones (as skore_gradebook_grades_test.dart does), keeps the feedback per
// pupil, and applies the create and the update as Skore did. Pupils,
// teachers, texts, feedback and evaluation IDs are fakes; class, group,
// model, course, gradebook and period IDs are Skore's own, as in the other
// gradebook tests. Nothing here reaches Skore: the fake fails the test on
// any RPC method but the reads (the publishing calls above all), and on any
// other request than the reads of the current user, a login, the feedback
// GET and the two feedback POSTs.
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
const _feedbackApi = '/skore/api/v1/gradebook/feedback';

/// The logged-in teacher, and a colleague (fake user IDs).
const _me = 1005;
const _colleague = 1006;

String _startPage(String userId) =>
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"$userId","name":{"startingWithFirstName"'
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
const _otherClass = 1301;

/// The evaluations of 6EWI's DW1 (fake IDs).
const _toets = 500003; // unpublished: the one written to
const _scheduled = 500001; // public from 2026-10-09 08:00
const _published = 500002; // public since 2026-10-01 08:00
const _planner = 500004; // from the planner
const _scale = 500005; // on a scale, without a highest grade

/// What the create and the update send as `evaluation` for Toets 1.
const _reference = {
  'evaluationId': '4069_$_toets',
  'classGroupId': '4069_2440',
  'teacherId': '4069_${_me}_0',
  'context': '176_472_2440',
};

/// An evaluation of the fake Skore.
class _Evaluation {
  const _Evaluation(
    this.id, {
    this.title = 'Toets 1',
    this.max = 20,
    this.evaltype = 1,
    this.planner = 0,
    this.public = '0',
    this.publicDateTime = '',
  });

  final int id;
  final String title;
  final Object? max;
  final int evaltype;
  final int planner;
  final String public;
  final String publicDateTime;
}

const _dw1 = [
  _Evaluation(_toets),
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

/// A feedback as Skore's REST API gives it (the GET's items, and the answer
/// to a save).
Map<String, Object?> _feedback(
  String id, {
  int pupil = _an,
  int teacher = _me,
  int evaluation = _toets,
  String text = 'Eerste opmerking.',
  String createdAt = '2026-10-08T09:49:36+02:00',
  String? changedAt,
  List<Map<String, Object?>> attachments = const [],
  bool canEdit = true,
}) => {
  'id': id,
  'evaluationId': '4069_$evaluation',
  'student': {
    'id': '4069_${pupil}_0',
    'name': {
      'startingWithFirstName': 'An Aerts',
      'startingWithLastName': 'Aerts An',
    },
    'deleted': false,
  },
  'teacher': {
    'id': '4069_${teacher}_0',
    'name': {
      'startingWithFirstName': teacher == _me ? 'Jan Janssens' : 'Piet Peeters',
      'startingWithLastName': teacher == _me ? 'Janssens Jan' : 'Peeters Piet',
    },
    'deleted': false,
  },
  'text': text,
  'createdAt': createdAt,
  'changedAt': changedAt ?? createdAt,
  'attachments': attachments,
  'capabilities': {'can_read': true, 'can_edit': canEdit},
};

/// An attachment as Skore gives it (not seen live: the fields of the
/// feedback panel's code).
const _attachment = {
  'id': 'att-1',
  'name': 'verbetering.pdf',
  'type': 'OTHER',
  'size': 1234,
  'downloadUrl': '/fake/download',
};

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
      for (final (id, name) in [(_an, 'Aerts, An'), (_bart, 'Claes, Bart')])
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

/// A grade cell's HTML as Skore gives it, empty, with the feedback marker
/// when the pupil has feedback.
String _cellHtml({bool feedback = false}) =>
    '<div class="gbc" raw=""></div>'
    '<div class="gbc_cell_header"><span class="gbc_message_place" >'
    '${feedback ? '<span class="gbc_message"></span>' : '&nbsp;&nbsp;'}'
    '</span></div>';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// A request to Skore's REST feedback API as it reached the fake Skore.
typedef _RestCall = ({
  String method,
  String path,
  String? contentType,
  Object? xRequestedWith,
  String body,
});

/// A Skore that answers the reads of 6EWI, keeps the feedback of each pupil
/// on each evaluation of DW1, and applies the create and the update of a
/// feedback as Skore did live.
class _Skore implements HttpClientAdapter {
  _Skore({
    Map<String, _Answer> answers = const {},
    List<_Evaluation> evaluations = _dw1,
    Map<(int, int), List<Map<String, Object?>>> feedback = const {},
    this.userId = '4069_${_me}_0',
    this.postAnswer,
    this.dropPost = false,
    this.forgetPost = false,
    this.unauthorizedPosts = 0,
    this.getAnswer,
  }) : evaluations = [...evaluations],
       feedback = {
         for (final MapEntry(:key, :value) in feedback.entries)
           key: [for (final f in value) Map.of(f)],
       },
       answers = {
         'getNavigation': _ok(_answer('getNavigation', _navigation())),
         'init': _ok(_answer('init', _init())),
         'getGradebookContext': _ok(_answer('getGradebookContext', _context())),
         ...answers,
       };

  final Map<String, _Answer> answers;

  final List<_Evaluation> evaluations;

  /// The feedback by (evaluation, pupil), in the order written.
  final Map<(int, int), List<Map<String, Object?>>> feedback;

  /// The session's `authenticatedUser.id`.
  final String userId;

  /// The answer to a feedback POST, instead of applying it.
  final _Answer? postAnswer;

  /// Whether a feedback POST is applied and its connection then drops, so
  /// that no answer comes in.
  final bool dropPost;

  /// Whether a feedback POST is answered as applied, but not kept.
  final bool forgetPost;

  /// How many feedback POSTs, from the first, Smartschool answers with a
  /// 401 (a refused session).
  int unauthorizedPosts;

  /// The answer to the [call]th feedback GET (from 0), or `null` for the
  /// feedback as kept.
  final _Answer? Function(int call)? getAnswer;

  /// The RPC methods called, in order.
  final List<String> methods = [];

  /// Every request that reached it: `METHOD path`, `RPC <method>` for an RPC
  /// call.
  final List<String> requests = [];

  /// The requests to the REST feedback API, in order.
  final List<_RestCall> rest = [];

  /// The feedback POSTs, in order.
  List<_RestCall> get posts => [
    for (final c in rest)
      if (c.method == 'POST') c,
  ];

  int _getCalls = 0;
  int _createCount = 0;

  /// getEvaluations of 6EWI's DW1, with the rows of 6WEWI2 Skore sends
  /// along.
  Map<String, Object?> _evaluations() => {
    'head': [
      for (final e in evaluations)
        {
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
          for (final pupil in [_an, _bart])
            {
              'c': '${e.id}',
              'r': 'pupil_${pupil}_2440',
              'v': _cellHtml(
                feedback: feedback[(e.id, pupil)]?.isNotEmpty ?? false,
              ),
              'p': [1, 0, '${e.id}', '32508', e.id],
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

  static final _getPath = RegExp(
    r'^/skore/api/v1/gradebook/feedback/4069_(\d+)/student/4069_(\d+)_0/'
    r'class/4069_2440/teacher/4069_(\d+)_0/context/176_472_2440$',
  );

  _Answer _get(String path) {
    final match = _getPath.firstMatch(path);
    if (match == null) fail('Unexpected feedback GET: $path');
    expect(match.group(3), '$_me', reason: 'the teacher of the GET');
    final answer = getAnswer?.call(_getCalls++);
    if (answer != null) return answer;
    final key = (int.parse(match.group(1)!), int.parse(match.group(2)!));
    return _ok(jsonEncode(feedback[key] ?? const []));
  }

  _Answer _post(String path, Map<String, dynamic> body, RequestOptions o) {
    final answer = postAnswer;
    if (answer != null) return answer;
    final reference = body['evaluation'] as Map<String, dynamic>;
    final evaluation = int.parse(
      (reference['evaluationId'] as String).split('_')[1],
    );
    final pupil = int.parse((body['studentId'] as String).split('_')[1]);
    final list = feedback.putIfAbsent((evaluation, pupil), () => []);
    final Map<String, Object?> saved;
    if (path == _feedbackApi) {
      // A create, also when the pupil has feedback already: a second one.
      _createCount++;
      saved = _feedback(
        '00000000-0000-4000-8000-00000000010$_createCount',
        pupil: pupil,
        evaluation: evaluation,
        teacher: int.parse((reference['teacherId'] as String).split('_')[1]),
        text: body['text'] as String,
        createdAt: '2026-10-08T12:00:0$_createCount+02:00',
        attachments: [
          for (final a in body['attachments'] as List<dynamic>)
            a as Map<String, Object?>,
        ],
      );
      if (!forgetPost) list.add(saved);
    } else {
      final id = path.substring(_feedbackApi.length + 1);
      expect(body['id'], id, reason: 'the id of the update');
      final index = list.indexWhere((f) => f['id'] == id);
      if (index < 0) {
        return (
          status: 404,
          body:
              '{"status":404,"title":"Not Found","detail":"Unknown feedback"}',
        );
      }
      saved = {
        ...list[index],
        'text': body['text'],
        'changedAt': '2026-10-08T12:30:00+02:00',
        'attachments': body['attachments'],
      };
      if (!forgetPost) list[index] = saved;
    }
    if (dropPost) {
      throw DioException.connectionError(
        requestOptions: o,
        reason: 'Connection closed before full header was received',
        error: const SocketException('Connection reset by peer'),
      );
    }
    return _ok(jsonEncode(saved));
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
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final text = utf8.decode(bytes);
    switch ((options.method, path)) {
      case ('GET', '/'):
        requests.add('GET /');
        return _body(_startPage(userId));
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
            'location': ['/'],
          },
        );
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Only the reads: never a publishing call, nor a save of any kind.
        expect(
          method,
          isIn([
            'getNavigation',
            'init',
            'getGradebookContext',
            'getEvaluations',
          ]),
        );
        methods.add(method);
        requests.add('RPC $method');
        final answer = method == 'getEvaluations'
            ? _ok(_answer(method, _evaluations()))
            : answers[method]!;
        return _body(
          answer.body,
          status: answer.status,
          type: 'application/json; charset=utf-8',
        );
    }
    if (path.startsWith(_feedbackApi)) {
      final call = (
        method: options.method,
        path: path,
        contentType: options.contentType,
        xRequestedWith: options.headers[kXRequestedWith],
        body: text,
      );
      rest.add(call);
      requests.add('${options.method} $path');
      final _Answer answer;
      if (options.method == 'GET') {
        answer = _get(path);
      } else if (options.method == 'POST' &&
          (path == _feedbackApi ||
              RegExp('^$_feedbackApi/[0-9a-f-]+\$').hasMatch(path))) {
        if (unauthorizedPosts > 0) {
          unauthorizedPosts--;
          answer = (status: 401, body: '');
        } else {
          answer = _post(
            path,
            jsonDecode(text) as Map<String, dynamic>,
            options,
          );
        }
      } else {
        fail('Unexpected request: ${options.method} ${options.uri}');
      }
      return _body(
        answer.body,
        status: answer.status,
        type: 'application/json',
      );
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// The ID of a feedback the tests start with (fake UUIDs).
const _mine = '00000000-0000-4000-8000-000000000001';
const _theirs = '00000000-0000-4000-8000-000000000002';
const _mineToo = '00000000-0000-4000-8000-000000000003';

/// The ID the fake Skore gives the first feedback it creates.
const _created = '00000000-0000-4000-8000-000000000101';

/// The path of the feedback GET of [pupil] on [evaluation], as the feedback
/// panel reads it.
String _getPath(int pupil, {int evaluation = _toets}) =>
    '$_feedbackApi/4069_$evaluation/student/4069_${pupil}_0/class/4069_2440/'
    'teacher/4069_${_me}_0/context/176_472_2440';

/// The body of a create, as the feedback panel sends it (verified live):
/// the keys in this order.
String _createBody(String text, {int pupil = _an}) => jsonEncode({
  'evaluation': _reference,
  'studentId': '4069_${pupil}_0',
  'text': text,
  'attachments': <Object?>[],
});

/// The body of an update of feedback [id], as the feedback panel sends it.
String _updateBody(
  String id,
  String text, {
  int pupil = _an,
  List<Object?> attachments = const [],
}) => jsonEncode({
  'id': id,
  'evaluation': _reference,
  'studentId': '4069_${pupil}_0',
  'text': text,
  'attachments': attachments,
});

/// Where An's feedback on Toets 1 is, as the messages name it.
const _where =
    'evaluation $_toets ("Toets 1") in period DW1 (1704) of gradebook 32508';

/// A [SmartschoolSkoreChangeRefusedError] of saveFeedback whose message
/// holds [reason].
Matcher _refused(Object reason) => isA<SmartschoolSkoreChangeRefusedError>()
    .having(
      (e) => e.message,
      'message',
      allOf(startsWith('saveFeedback: '), contains(reason)),
    )
    .having((e) => e.message, 'message', endsWith('Nothing was saved.'));

/// A [SmartschoolSkoreFeedbackSaveUnconfirmedError] about An's feedback on
/// Toets 1.
Matcher _unconfirmed({
  required bool isUpdate,
  required Object? feedbackId,
  String text = 'Goed gewerkt.',
  Object? cause = isNull,
  Object? message = anything,
}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>(),
  isA<SmartschoolSkoreFeedbackSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having(
        (e) => e.message,
        'message',
        isUpdate
            ? endsWith('saving it again is harmless.')
            : endsWith(
                'saveFeedback again changes the feedback it created, if it '
                'did, rather than adding a second.',
              ),
      )
      .having((e) => e.gradebookId, 'gradebookId', 32508)
      .having((e) => e.periodId, 'periodId', 1704)
      .having((e) => e.evaluationId, 'evaluationId', _toets)
      .having((e) => e.pupilId, 'pupilId', _an)
      .having((e) => e.text, 'text', text)
      .having((e) => e.isUpdate, 'isUpdate', isUpdate)
      .having((e) => e.feedbackId, 'feedbackId', feedbackId)
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

  /// Serves [server], reads evaluation [id] of DW1 and forgets the requests
  /// of that read, so that the test sees only those of the write.
  Future<(SkoreGradebookService, SkoreEvaluation)> ready(
    _Skore server, [
    int id = _toets,
  ]) async {
    final gradebooks = await serve(server);
    final evaluation = (await gradebooks.getEvaluations(
      _ewi,
      1704,
    )).singleWhere((e) => e.id == id);
    server.methods.clear();
    server.requests.clear();
    server.rest.clear();
    return (gradebooks, evaluation);
  }

  // ---------------------------------------------------------------------------
  // The save
  // ---------------------------------------------------------------------------

  group('saveFeedback', () {
    test('creates the feedback when the user has none: the POST of the '
        'feedback panel, sent once, then read again', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        'Goed gewerkt.',
      );

      expect(server.requests, [
        'RPC getNavigation', // the own gradebooks of the current school year
        'RPC init', // the period: one of the gradebook's, open
        'RPC getGradebookContext', // writable in that period
        'RPC getEvaluations', // the evaluation and the pupil's cell, now
        'GET ${_getPath(_an)}', // the pupil's feedback, now
        'POST $_feedbackApi', // the create
        'GET ${_getPath(_an)}', // the check
      ]);
      final post = server.posts.single;
      expect(post.body, _createBody('Goed gewerkt.'));
      expect(post.contentType, startsWith('application/json'));
      expect(post.xRequestedWith, 'XMLHttpRequest');

      expect(feedback.id, _created);
      expect(feedback.text, 'Goed gewerkt.');
      expect(feedback.pupilId, _an);
      expect(feedback.teacherId, _me);
      expect(feedback.canEdit, isTrue);
      expect(feedback.createdAt, feedback.changedAt);
      expect(server.feedback[(_toets, _an)], hasLength(1));
    });

    test("changes the user's own feedback, sending its attachments back, "
        "and leaves a colleague's alone", () async {
      final colleague = _feedback(
        _theirs,
        teacher: _colleague,
        text: 'Van een collega.',
      );
      final server = _Skore(
        feedback: {
          (_toets, _an): [
            colleague,
            _feedback(_mine, attachments: [_attachment]),
          ],
        },
      );
      final (gradebooks, evaluation) = await ready(server);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        'Goed gewerkt.',
      );

      final post = server.posts.single;
      expect(post.path, '$_feedbackApi/$_mine');
      expect(
        post.body,
        _updateBody(_mine, 'Goed gewerkt.', attachments: [_attachment]),
      );
      expect(post.contentType, startsWith('application/json'));
      expect(post.xRequestedWith, 'XMLHttpRequest');
      expect(server.requests.last, 'GET ${_getPath(_an)}');

      expect(feedback.id, _mine);
      expect(feedback.text, 'Goed gewerkt.');
      expect(feedback.createdAt, DateTime.utc(2026, 10, 8, 7, 49, 36));
      expect(feedback.changedAt, DateTime.utc(2026, 10, 8, 10, 30));
      expect(feedback.attachments.single.json, _attachment);
      // The colleague's feedback is as it was, and still first.
      expect(server.feedback[(_toets, _an)]!.first, colleague);
    });

    test("a colleague's feedback only: creates the user's own, and changes "
        'none of theirs', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [
            _feedback(_theirs, teacher: _colleague, text: 'Van een collega.'),
          ],
        },
      );
      final (gradebooks, evaluation) = await ready(server);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        'Goed gewerkt.',
      );

      expect(server.posts.single.path, _feedbackApi);
      expect(server.posts.single.body, _createBody('Goed gewerkt.'));
      expect(feedback.teacherId, _me);
      expect(
        [for (final f in server.feedback[(_toets, _an)]!) f['text']],
        ['Van een collega.', 'Goed gewerkt.'],
      );
    });

    test('sends the text trimmed, keeping the lines within it', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        '  \nGoed gewerkt.\n\nLet op de lussen.  \n',
      );

      expect(
        server.posts.single.body,
        _createBody('Goed gewerkt.\n\nLet op de lussen.'),
      );
      expect(feedback.text, 'Goed gewerkt.\n\nLet op de lussen.');
    });

    test('on an evaluation on a scale, without a highest grade: feedback is '
        'not a grade', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server, _scale);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _bart,
        'Goede houding.',
      );

      final body = jsonDecode(server.posts.single.body) as Map;
      expect((body['evaluation'] as Map)['evaluationId'], '4069_$_scale');
      expect(body['studentId'], '4069_${_bart}_0');
      expect(feedback.text, 'Goede houding.');
    });

    test('on a published or scheduled evaluation with allowPublished: '
        'true', () async {
      for (final id in [_scheduled, _published]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server, id);
        expect(evaluation.publication.isPublic, isTrue);

        final feedback = await gradebooks.saveFeedback(
          _ewi,
          evaluation,
          _an,
          'Goed gewerkt.',
          allowPublished: true,
        );

        expect(server.posts.single.path, _feedbackApi, reason: '$id');
        expect(feedback.text, 'Goed gewerkt.', reason: '$id');
      }
    });

    test('a change refused for its session logs in and is sent again: it '
        'sends the whole text', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [_feedback(_mine)],
        },
        unauthorizedPosts: 1,
      );
      final (gradebooks, evaluation) = await ready(server);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        'Goed gewerkt.',
      );

      expect(feedback.text, 'Goed gewerkt.');
      expect(
        [for (final p in server.posts) p.path],
        ['$_feedbackApi/$_mine', '$_feedbackApi/$_mine'],
      );
      expect(server.requests.where((r) => r == 'POST /login'), hasLength(1));
    });

    test('a create refused for its session is not sent again: the session '
        'error at once, nothing saved; a new call then logs in first and '
        'creates it once', () async {
      final server = _Skore(unauthorizedPosts: 1);
      final (gradebooks, evaluation) = await ready(server);

      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.posts, hasLength(1));
      expect(server.requests.last, 'POST $_feedbackApi');
      expect(server.requests, isNot(contains('POST /login')));
      expect(server.feedback[(_toets, _an)], isNull);

      final feedback = await gradebooks.saveFeedback(
        _ewi,
        evaluation,
        _an,
        'Goed gewerkt.',
      );
      expect(feedback.text, 'Goed gewerkt.');
      expect(
        [for (final p in server.posts) p.path],
        [_feedbackApi, _feedbackApi],
      );
      expect(server.requests.where((r) => r == 'POST /login'), hasLength(1));
      expect(server.feedback[(_toets, _an)], hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // The checks
  // ---------------------------------------------------------------------------

  group('refuses, saving nothing,', () {
    test('a blank text or a pupil ID that is not positive, before anything '
        'is sent', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);
      for (final text in ['', '   ', '\n\t ']) {
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, _an, text),
          throwsA(_refused('the text is blank')),
          reason: jsonEncode(text),
        );
      }
      for (final pupil in [0, -1201]) {
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, pupil, 'Goed gewerkt.'),
          throwsA(_refused('$pupil is not a pupil ID')),
        );
      }
      expect(server.requests, isEmpty);
    });

    test('a published or a scheduled evaluation, without allowPublished, '
        'before the feedback is read', () async {
      for (final (id, state) in [
        (_published, 'is published'),
        (_scheduled, 'is scheduled to be published'),
      ]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server, id);
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
          throwsA(
            _refused(
              '$state (public "1", publicdatetime "${id == _published ? '2026-10-01T08:00:00' : '2026-10-09T08:00:00'}"): '
              'its pupils see what is written in it',
            ),
          ),
          reason: state,
        );
        expect(server.rest, isEmpty, reason: state);
      }
    });

    test('an evaluation Skore lists as public now, whatever the evaluation '
        'passed says', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);
      expect(evaluation.publication.isPublic, isFalse);
      // Published in Smartschool since it was read.
      server.evaluations[0] = const _Evaluation(
        _toets,
        public: '1',
        publicDateTime: '2026-10-08T08:00:00',
      );

      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(_refused('is published (public "1"')),
      );
      expect(server.rest, isEmpty);
    });

    test('an evaluation from the planner, of another gradebook (before '
        'anything is sent), or no longer listed', () async {
      var server = _Skore();
      var (gradebooks, evaluation) = await ready(server, _planner);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(_refused('comes from the planner (isPlannerEval 1)')),
      );
      expect(server.rest, isEmpty);

      server = _Skore();
      (gradebooks, evaluation) = await ready(server);
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
        gradebooks.saveFeedback(_ewi, foreign, _an, 'Goed gewerkt.'),
        throwsA(
          _refused(
            'evaluation $_toets is one of gradebook 32504, not of gradebook '
            '32508',
          ),
        ),
      );
      expect(server.requests, isEmpty);

      server.evaluations.removeAt(0); // moved to the trash
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _refused(
            'Skore no longer lists evaluation $_toets in period DW1 (1704) of '
            'gradebook 32508',
          ),
        ),
      );
      expect(server.rest, isEmpty);
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
          gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
          throwsA(_refused(reason)),
          reason: name,
        );
        expect(server.rest, isEmpty, reason: name);
      }
    });

    test('a pupil without a cell of the class in the evaluation: of another '
        'class, or unknown', () async {
      for (final pupil in [_otherClass, 9999]) {
        final server = _Skore();
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, pupil, 'Goed gewerkt.'),
          throwsA(
            _refused(
              'in $_where, pupil $pupil has no cell in its rows of class 2440',
            ),
          ),
        );
        expect(server.rest, isEmpty);
      }
    });

    test(
      "the user's own feedback that Skore does not let them change",
      () async {
        final server = _Skore(
          feedback: {
            (_toets, _an): [_feedback(_mine, canEdit: false)],
          },
        );
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
          throwsA(
            _refused(
              'Skore does not let you change your feedback $_mine for pupil '
              '$_an on $_where (can_edit false)',
            ),
          ),
        );
        expect(server.posts, isEmpty);
      },
    );

    test('more than one feedback of the user for the pupil: changes none of '
        'them, nor creates another', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [
            _feedback(_mine),
            _feedback(_theirs, teacher: _colleague),
            _feedback(_mineToo, text: 'Tweede opmerking.'),
          ],
        },
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _refused(
            'you gave pupil $_an 2 feedbacks on $_where already ($_mine, '
            '$_mineToo): the library changes none of them',
          ),
        ),
      );
      expect(server.posts, isEmpty);
    });

    test('a session user ID not in the form 4069_146_0', () async {
      final server = _Skore(userId: '4069_$_me');
      final gradebooks = await serve(server);
      final evaluation = (await gradebooks.getEvaluations(_ewi, 1704)).first;
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(isA<SmartschoolParsingError>()),
      );
      expect(server.rest, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Skore's answers to the save
  // ---------------------------------------------------------------------------

  group("Skore's answer to the save:", () {
    test('400 to 499 is a refusal: a SmartschoolSkoreError with its title '
        'and detail, nothing saved', () async {
      for (final (status, body, reason) in [
        (
          400,
          '{"status":400,"title":"Bad Request","detail":"Text too long"}',
          'HTTP 400: Bad Request: Text too long. Nothing was saved.',
        ),
        (
          403,
          '{"title":"Forbidden","detail":"No access to this evaluation"}',
          'HTTP 403: Forbidden: No access to this evaluation. Nothing was '
              'saved.',
        ),
        (422, '', 'HTTP 422. Nothing was saved.'),
      ]) {
        final server = _Skore(postAnswer: (status: status, body: body));
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
          throwsA(
            allOf(
              isNot(isA<SmartschoolSkoreChangeRefusedError>()),
              isA<SmartschoolSkoreError>().having(
                (e) => e.message,
                'message',
                allOf(
                  startsWith(
                    'saveFeedback: the new feedback for pupil $_an on $_where '
                    'was refused by Skore with ',
                  ),
                  endsWith(reason),
                ),
              ),
            ),
          ),
          reason: '$status',
        );
        expect(server.posts, hasLength(1), reason: '$status');
      }
    });

    test('a 500, or an answer that is not the feedback: unconfirmed, with '
        'what Skore answered', () async {
      final cases = <String, (_Answer, Object)>{
        'a 500 with a problem': (
          (
            status: 500,
            body: '{"title":"Internal Server Error","detail":"Oeps"}',
          ),
          'Skore answered with HTTP 500: Internal Server Error: Oeps',
        ),
        'an HTML page': (
          _ok('<!DOCTYPE html><html><body>Start</body></html>'),
          'Skore answered the save with an HTML page instead of JSON',
        ),
        'not an object': (_ok('[]'), 'without its ID or text'),
        'another pupil': (
          _ok(jsonEncode(_feedback('f-9', pupil: _bart))),
          'for pupil "4069_${_bart}_0"',
        ),
      };
      for (final MapEntry(key: name, value: (answer, reason))
          in cases.entries) {
        final server = _Skore(postAnswer: answer);
        final (gradebooks, evaluation) = await ready(server);
        await expectLater(
          gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
          throwsA(
            _unconfirmed(
              isUpdate: false,
              feedbackId: isNull,
              cause: isA<SmartschoolSkoreError>().having(
                (e) => e.message,
                'message',
                contains(reason),
              ),
              message: allOf(
                startsWith(
                  'saveFeedback: the new feedback for pupil $_an on $_where '
                  "was sent, but Skore's answer is not the feedback saved (",
                ),
                contains(
                  'It may or may not have been created: read the feedback '
                  'again (getFeedback)',
                ),
              ),
            ),
          ),
          reason: name,
        );
        expect(server.posts, hasLength(1), reason: name);
      }
    });

    test('a feedback of another teacher, or for a change another ID: '
        'unconfirmed', () async {
      var server = _Skore(
        postAnswer: _ok(jsonEncode(_feedback('f-9', teacher: _colleague))),
      );
      var (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: false,
            feedbackId: isNull,
            message: contains(
              'Skore answered with feedback f-9 of teacher $_colleague '
              'instead of a new feedback of yours ($_me)',
            ),
          ),
        ),
      );

      server = _Skore(
        feedback: {
          (_toets, _an): [_feedback(_mine)],
        },
        postAnswer: _ok(jsonEncode(_feedback(_mineToo))),
      );
      (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: true,
            feedbackId: _mine,
            message: contains('instead of feedback $_mine of yours ($_me)'),
          ),
        ),
      );
    });

    test('a connection that drops after the create went out: unconfirmed, '
        'not sent again; saveFeedback again changes the one it made', () async {
      final server = _Skore(dropPost: true);
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: false,
            feedbackId: isNull,
            cause: isA<SmartschoolConnectionError>(),
            message: contains('was sent, but no answer came in'),
          ),
        ),
      );
      expect(server.posts, hasLength(1));
      expect(server.feedback[(_toets, _an)]!.single['id'], _created);

      // Called again, with the connection back: it finds the feedback the
      // create made, and changes it, rather than adding a second.
      final again = _Skore(feedback: server.feedback);
      final (gradebooks2, evaluation2) = await ready(again);
      final feedback = await gradebooks2.saveFeedback(
        _ewi,
        evaluation2,
        _an,
        'Goed gewerkt!',
      );
      expect(again.posts.single.path, '$_feedbackApi/$_created');
      expect(feedback.id, _created);
      expect(feedback.text, 'Goed gewerkt!');
      expect(again.feedback[(_toets, _an)], hasLength(1));
    });

    test('a connection that drops after a change went out: unconfirmed, with '
        'its ID', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [_feedback(_mine)],
        },
        dropPost: true,
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: true,
            feedbackId: _mine,
            cause: isA<SmartschoolConnectionError>(),
            message: allOf(
              startsWith(
                'saveFeedback: the change of your feedback $_mine for pupil '
                '$_an on $_where was sent, but no answer came in',
              ),
              contains('It may or may not have been changed'),
            ),
          ),
        ),
      );
      expect(server.posts, hasLength(1));
    });

    test('a change refused for its session also after a new login: the '
        'session error, nothing saved', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [_feedback(_mine)],
        },
        unauthorizedPosts: 2,
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.posts, hasLength(2));
      expect(
        server.feedback[(_toets, _an)]!.single['text'],
        'Eerste opmerking.',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // The check afterwards
  // ---------------------------------------------------------------------------

  group('reading again', () {
    test('does not list the feedback saved: unconfirmed, with the ID Skore '
        'answered', () async {
      final server = _Skore(forgetPost: true);
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: false,
            feedbackId: _created,
            message: allOf(
              contains(
                'was confirmed as feedback $_created, but reading the '
                'feedback again does not list it.',
              ),
              contains(
                'Skore answered that it created it: read the feedback again',
              ),
            ),
          ),
        ),
      );
      expect(server.posts, hasLength(1));
    });

    test('shows the feedback with another text: unconfirmed', () async {
      final server = _Skore(
        feedback: {
          (_toets, _an): [_feedback(_mine)],
        },
        forgetPost: true,
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: true,
            feedbackId: _mine,
            message: contains(
              'but reading the feedback again shows it with another text (17 '
              'characters, not 13).',
            ),
          ),
        ),
      );
    });

    test('fails: unconfirmed, with the failure as its cause; the create is '
        'not sent again', () async {
      final server = _Skore(
        getAnswer: (call) => call == 1
            ? (
                status: 503,
                body: '{"title":"Service Unavailable","detail":"Later"}',
              )
            : null,
      );
      final (gradebooks, evaluation) = await ready(server);
      await expectLater(
        gradebooks.saveFeedback(_ewi, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          _unconfirmed(
            isUpdate: false,
            feedbackId: _created,
            cause: isA<SmartschoolSkoreError>().having(
              (e) => e.message,
              'message',
              contains('HTTP 503: Service Unavailable: Later'),
            ),
            message: contains('reading the feedback again to check it failed'),
          ),
        ),
      );
      expect(server.posts, hasLength(1));
      expect(server.feedback[(_toets, _an)], hasLength(1));
    });
  });
}
