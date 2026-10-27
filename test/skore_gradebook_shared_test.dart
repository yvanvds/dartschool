// Tests for issue #191: the gradebooks colleagues shared with the logged-in
// teacher (Skore's tab "Gedeeld"), read and written as Skore's web client
// opens them (SkoreGradebookService.getSharedGradebooks, and the other
// methods on a shared gradebook).
//
// What was seen live (read-only, 2026-10-27), and what the web client's code
// sends:
//   - the list: `accessableList(userID)` of gradebook/rpc.php, in the own
//     scope (session `teacher` the user, `restriction` 0), for the school
//     year of the session's `wy`: a list of `{id: "<teacher>_<gradebook>",
//     userId, ownerId, courseId, writable: 1, username, classcourse:
//     "<class>/<course>", text, userPictureUrl, navigation: {pathIds,
//     data: {classID, courseID, groupID, modelID, ownerID, userID}}}`
//     (`/SkoreGradebook/Main/getSharedGradebooks` gives the same, with
//     numbers). Every gradebook shared with the developer's account was
//     shared to write; `writable` 0 (to read only) is from the web client's
//     "writable"/"readable";
//   - a shared gradebook is opened as the web client's `setUser(teacher,
//     ownerRestriction)` does for an item of that list: the session's
//     `teacher` is the gradebook's teacher and its `restriction` the
//     gradebook; `init(courses, owners, teacher, pathIds, 0, gradebook)`,
//     `getGradebookContext(pathIds, courses, owners, teacher, period,
//     gradebook, wy)` (answered with `writable` 1, `owners` [gradebook],
//     `teacherId` the teacher, `restriction` the gradebook) and
//     `getEvaluations(period, teacher, ...)` (seen live, with periods without
//     evaluations); `saveGrade(..., teacher, ...)` in the same session (from
//     the web client's code, not tried live);
//   - the feedback panel names the gradebook's teacher in the path of the
//     read and in `evaluation.teacherId` of a save (its `gbc.userID`), and a
//     feedback's own `teacher` is who wrote it (`isCurrentUser`) (from the
//     web client's code, not tried live).
//
// Teachers, pupils, names, texts, feedback and evaluation IDs are fakes;
// class, group, model, course, gradebook and period IDs are Skore's own, as
// in the other gradebook tests (34999 is made up). Nothing here reaches
// Skore: the fake fails the test on any request it does not expect.
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

const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';
const _feedbackApi = '/skore/api/v1/gradebook/feedback';

/// The logged-in teacher, the colleague who shared 6EWI's gradebook with
/// them to write, and one who shared another to read only (fake user IDs).
const _me = 1005;
const _owner = 1006;
const _reader = 1007;

/// The gradebook of 6EWI shared to write, and one of 6WEWI2 shared to read.
const _sharedId = 34980;
const _readOnlyId = 34999;

/// 6EWI's evaluation period of 2026-2027 in the shared gradebook.
const _period = 1758;

/// The pupils of 6EWI (fake IDs).
const _an = 1201;
const _bart = 1202;

/// An evaluation in the shared gradebook (fake ID), unpublished.
const _toets = 500010;

/// The time of the tests.
final _now = DateTime.utc(2026, 10, 27, 10);

String _startPage(String userId) =>
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"$userId","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// An RPC answer of Skore with [result].
String _answer(String method, Object? result) => jsonEncode({
  'result': result,
  'session': 1,
  'method': method,
  'timelimit': 0,
  'limitInfo': null,
});

/// An entry of `accessableList`, as Skore gives it (IDs as strings).
Map<String, Object?> _entry({
  int teacher = _owner,
  int gradebook = _sharedId,
  int writable = 1,
  String name = 'Piet Peeters',
  String label = '6EWI/Digitale vaardigheden',
  List<Object?> pathIds = const ['176', '472', '2440'],
  int course = 1588,
  String? id,
  Map<String, Object?>? data,
}) => {
  'id': id ?? '${teacher}_$gradebook',
  'userId': '$teacher',
  'userPictureUrl': 'https://userpicture20.smartschool.be/fake',
  'text': '$label $name',
  'username': name,
  'classcourse': label,
  'writable': writable,
  'ownerId': '$gradebook',
  'courseId': '$course',
  'navigation': {
    'pathIds': pathIds,
    'data':
        data ??
        {
          'classID': '${pathIds.last}',
          'courseID': '$course',
          'groupID': '${pathIds[1]}',
          'modelID': '${pathIds.first}',
          'ownerID': '$gradebook',
          'userID': '$teacher',
        },
  },
};

/// The list of the gradebooks shared with the user: 6EWI's to write, and
/// 6WEWI2's to read only.
List<Map<String, Object?>> _sharedList() => [
  _entry(),
  _entry(
    teacher: _reader,
    gradebook: _readOnlyId,
    writable: 0,
    name: 'Céline Dupré',
    label: '6WEWI2/Digitale vaardigheden',
    pathIds: const ['176', '472', '2444'],
  ),
];

/// getNavigation with the user's own gradebook of 6EWI, for school year
/// [year] (`"24"`, 2026-2027, Skore's current one).
Map<String, Object?> _navigation({String year = '24'}) => {
  'navigation': [
    {
      'raw': '3gr D-D/A',
      'children': [
        {
          'raw': '6EWI',
          'crum': {
            'ids': ['176', '472', '2440'],
          },
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
              },
              'part': ['Janssens Jan'],
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
  'currentWorkyear': year,
};

/// init of the shared gradebook of 6EWI: its period (open unless [open] is
/// 0), as seen live (`activePeriodE` -1), or none, with its report period.
Map<String, Object?> _init({int open = 1, bool periods = true}) => {
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
    if (periods)
      {
        'name': 'DW1',
        'fullname': 'Dagelijks werk 1',
        'id': '$_period',
        'info': '<p>Open tot 2027-06-26 22:00</p>',
        'virtual': '0',
        'scope': '2',
        'open': open,
        'timestamp': '2027-06-26T22:00:00+0200',
        'lockIcon': 0,
        'categoryMode': 1,
      },
  ],
  'reports': [
    {
      'name': 'R1D',
      'fullname': 'Rapport 1',
      'id': '2762',
      'open': 1,
      'timestamp': '2026-10-30T23:00:00+0100',
    },
  ],
  'activePeriodE': -1,
  'ownerMap': [
    {
      'courseID': '1588',
      'groupID': '472',
      'coursename': 'Digitale vaardigheden',
      'ownerID': '$_sharedId',
      'classID': '2440',
    },
  ],
  'isRestrictedAccess': 0,
};

/// getGradebookContext of the shared gradebook, as seen live.
Map<String, Object?> _context({int writable = 1}) => {
  'writable': writable,
  'coordinator': 0,
  'modelId': 176,
  'groupId': 472,
  'classId': 2440,
  'periodId': _period,
  'courses': [1588],
  'owners': [_sharedId],
  'teacherId': _owner,
  'virtualId': 0,
  'restriction': _sharedId,
};

/// getEvaluations of the shared gradebook's period: Toets 1, with a cell for
/// each pupil ([grades] by pupil, `""` for none).
Map<String, Object?> _evaluations(Map<int, String> grades) => {
  'head': [
    {
      'title': 'Toets 1',
      'short': null,
      'date': '2026-10-20',
      'componentID': 0,
      'component': 'geen',
      'periodID': _period,
      'courseID': '1588',
      'coursename': 'Digitale vaardigheden',
      'public': '0',
      'publicdatetime': '',
      'max': 20,
      'refID': '$_toets',
      'colID': 'A',
      'evaltype': 1,
      'evaluationID': '$_toets',
      'ownerID': '$_sharedId',
      'isPlannerEval': 0,
    },
  ],
  'details': {
    'stream': [
      for (final pupil in [_an, _bart])
        {
          'c': '$_toets',
          'r': 'pupil_${pupil}_2440',
          'v': '<div class="gbc" raw="${grades[pupil] ?? ''}"></div>',
          'p': [1, 0, '$_toets', '$_sharedId', _toets],
        },
    ],
  },
  'periodStatus': 1,
  'evalType': 1,
  'archive': <Object?>[],
};

/// A feedback as Skore's REST API gives it, written by [teacher].
Map<String, Object?> _feedback(
  String id, {
  int teacher = _me,
  int pupil = _an,
  String text = 'Eerste opmerking.',
}) => {
  'id': id,
  'evaluationId': '4069_$_toets',
  'student': {'id': '4069_${pupil}_0'},
  'teacher': {
    'id': '4069_${teacher}_0',
    'name': {'startingWithFirstName': 'Fake Teacher'},
  },
  'text': text,
  'createdAt': '2026-10-27T09:00:00+01:00',
  'changedAt': '2026-10-27T09:00:00+01:00',
  'attachments': <Object?>[],
  'capabilities': {'can_read': true, 'can_edit': teacher == _me},
};

/// An RPC call as it reached the fake Skore.
typedef _Call = ({
  String method,
  List<dynamic> params,
  Map<String, dynamic> session,
});

/// A Skore that answers the reads of the user's own gradebooks and of those
/// shared with them, keeps the grades and the feedback of Toets 1 in the
/// shared gradebook of 6EWI, and records every request.
class _Skore implements HttpClientAdapter {
  _Skore({
    List<Map<String, Object?>>? shared,
    Map<String, Object?>? init,
    Map<String, Object?>? context,
    Map<int, List<Map<String, Object?>>> feedback = const {},
  }) : shared = shared ?? _sharedList(),
       init = init ?? _init(),
       context = context ?? _context(),
       feedback = {
         for (final MapEntry(:key, :value) in feedback.entries)
           key: [for (final f in value) Map.of(f)],
       };

  final List<Map<String, Object?>> shared;
  final Map<String, Object?> init;
  final Map<String, Object?> context;

  /// The grades of Toets 1, by pupil.
  final Map<int, String> grades = {};

  /// The feedback on Toets 1, by pupil, in the order written.
  final Map<int, List<Map<String, Object?>>> feedback;

  /// Every request that reached it: `METHOD path`, `RPC <method>` for an RPC
  /// call.
  final List<String> requests = [];

  /// The RPC calls, in order.
  final List<_Call> calls = [];

  /// The bodies of the feedback POSTs, in order.
  final List<Map<String, dynamic>> posts = [];

  int _created = 0;

  static ResponseBody _body(String body, {int status = 200, String? type}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [type ?? 'application/json'],
        },
      );

  /// Checks that [call] goes out in the scope of the shared gradebook of
  /// 6EWI: in its teacher's name, restricted to it.
  static void _expectShared(_Call call) {
    expect(call.session['teacher'], _owner, reason: '${call.method} teacher');
    expect(
      call.session['restriction'],
      _sharedId,
      reason: '${call.method} restriction',
    );
  }

  Object? _rpc(_Call call) {
    final p = call.params;
    switch (call.method) {
      case 'getNavigation':
        expect(p, [_me, 0]);
        expect(call.session['teacher'], _me);
        expect(call.session['restriction'], 0);
        return _navigation(year: '${call.session['wy'] ?? 24}');
      case 'accessableList':
        expect(p, [_me]);
        expect(call.session['teacher'], _me);
        expect(call.session['restriction'], 0);
        return shared;
      case 'init':
        _expectShared(call);
        expect(p, [
          ['1588'],
          ['$_sharedId'],
          _owner,
          ['176', '472', '2440'],
          0,
          _sharedId,
        ]);
        return init;
      case 'getGradebookContext':
        _expectShared(call);
        expect(p, [
          ['176', '472', '2440'],
          ['1588'],
          ['$_sharedId'],
          _owner,
          _period,
          _sharedId,
          24,
        ]);
        return context;
      case 'getEvaluations':
        _expectShared(call);
        expect(p, [
          _period,
          _owner,
          ['1588'],
          '472',
          '2440',
          ['176', '472', '2440'],
        ]);
        return _evaluations(grades);
      case 'saveGrade':
        _expectShared(call);
        final [col, row, value, userId, ...rest] = p;
        expect(col, '$_toets');
        expect(userId, _owner, reason: "saveGrade's userID: the teacher");
        expect(rest, [
          0,
          0,
          0,
          '0',
          ['176', '472', '2440'],
          '$_toets',
          '$_sharedId',
        ]);
        final pupil = int.parse((row as String).split('_')[1]);
        grades[pupil] = value as String;
        return {'savedState': 1, 'grade': value};
    }
    fail('Unexpected RPC method: ${call.method}');
  }

  static final _getPath = RegExp(
    r'^/skore/api/v1/gradebook/feedback/4069_(\d+)/student/4069_(\d+)_0/'
    r'class/4069_2440/teacher/4069_(\d+)_0/context/176_472_2440$',
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
    switch ((options.method, path)) {
      case ('GET', '/'):
        requests.add('GET /');
        return _body(_startPage('4069_${_me}_0'), type: 'text/html');
      case ('GET', '/course-list/api/v1/courses'):
        requests.add('GET $path');
        return _body('[{"platformId":4069}]');
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final call = (
          method: form['rpc_method']!,
          params: jsonDecode(form['rpc_params']!) as List<dynamic>,
          session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
        );
        calls.add(call);
        requests.add('RPC ${call.method}');
        return _body(_answer(call.method, _rpc(call)));
    }
    if (path.startsWith(_feedbackApi)) {
      requests.add('${options.method} $path');
      if (options.method == 'GET') {
        final match = _getPath.firstMatch(path);
        if (match == null) fail('Unexpected feedback GET: $path');
        expect(match.group(1), '$_toets');
        expect(
          match.group(3),
          '$_owner',
          reason: "the GET's teacher: the gradebook's",
        );
        final pupil = int.parse(match.group(2)!);
        return _body(jsonEncode(feedback[pupil] ?? const []));
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      posts.add(body);
      final pupil = int.parse((body['studentId'] as String).split('_')[1]);
      final list = feedback.putIfAbsent(pupil, () => []);
      final Map<String, Object?> saved;
      if (path == _feedbackApi) {
        _created++;
        // Written by the user, whatever the evaluation's teacher.
        saved = _feedback(
          '00000000-0000-4000-8000-00000000010$_created',
          pupil: pupil,
          text: body['text'] as String,
        );
        list.add(saved);
      } else {
        final id = path.substring(_feedbackApi.length + 1);
        final index = list.indexWhere((f) => f['id'] == id);
        expect(index, isNonNegative, reason: 'the feedback changed');
        saved = {...list[index], 'text': body['text']};
        list[index] = saved;
      }
      return _body(jsonEncode(saved));
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// The shared gradebook of 6EWI as getSharedGradebooks reads it.
const _shared = SkoreGradebook(
  gradebookId: _sharedId,
  teacherId: _owner,
  modelId: 176,
  modelName: '',
  groupId: 472,
  groupName: '',
  classId: 2440,
  className: '6EWI',
  courseId: 1588,
  courseName: 'Digitale vaardigheden',
  workyearId: 24,
  access: SkoreGradebookAccess.write,
  ownerName: 'Piet Peeters',
);

/// The gradebook of 6WEWI2 shared to read only, as getSharedGradebooks
/// reads it.
const _readOnly = SkoreGradebook(
  gradebookId: _readOnlyId,
  teacherId: _reader,
  modelId: 176,
  modelName: '',
  groupId: 472,
  groupName: '',
  classId: 2444,
  className: '6WEWI2',
  courseId: 1588,
  courseName: 'Digitale vaardigheden',
  workyearId: 24,
  access: SkoreGradebookAccess.read,
  ownerName: 'Céline Dupré',
);

/// The path of An's feedback on Toets 1 in the shared gradebook, as the
/// feedback panel reads it there: with the gradebook's teacher.
const _anFeedback =
    '$_feedbackApi/4069_$_toets/student/4069_${_an}_0/class/4069_2440/'
    'teacher/4069_${_owner}_0/context/176_472_2440';

/// The parts of [gradebook] a test compares.
List<Object?> _parts(SkoreGradebook gradebook) => [
  gradebook.gradebookId,
  gradebook.teacherId,
  gradebook.pathIds,
  gradebook.modelName,
  gradebook.groupName,
  gradebook.className,
  gradebook.courseId,
  gradebook.courseName,
  gradebook.workyearId,
  gradebook.teacherNames,
  gradebook.access,
  gradebook.ownerName,
];

/// A [SmartschoolSkoreGradebookReadOnlyError] of [operation] about
/// [gradebook].
Matcher _readOnlyError(String operation, int gradebook) =>
    isA<SmartschoolSkoreGradebookReadOnlyError>()
        .having(
          (e) => e.message,
          'message',
          allOf(
            startsWith('$operation: gradebook $gradebook is shared with you '),
            contains('to read only'),
            endsWith('Nothing was saved.'),
          ),
        )
        .having((e) => e.gradebook.gradebookId, 'gradebook', gradebook)
        .having((e) => e.gradebook.access, 'access', SkoreGradebookAccess.read);

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

  /// Serves [server], reads Toets 1 of the shared gradebook and forgets the
  /// requests of that read.
  Future<(SkoreGradebookService, SkoreEvaluation)> ready(_Skore server) async {
    final gradebooks = await serve(server);
    final evaluation = (await gradebooks.getEvaluations(
      _shared,
      _period,
    )).single;
    server.requests.clear();
    server.calls.clear();
    return (gradebooks, evaluation);
  }

  group('parseSharedGradebooks', () {
    test("reads each gradebook with its teacher, the user's access, its "
        'class and course from the label, and its school year', () {
      final books = SkoreGradebookService.parseSharedGradebooks(
        _sharedList(),
        workyearId: 24,
      );

      expect(books.map(_parts), [_parts(_shared), _parts(_readOnly)]);
      expect(books.map((b) => b.isShared), [true, true]);
    });

    test('reads the IDs as numbers too, as /SkoreGradebook/Main/'
        'getSharedGradebooks gives them; each gradebook once', () {
      final numbers = {
        ..._entry(),
        'userId': _owner,
        'ownerId': _sharedId,
        'courseId': 1588,
        'navigation': {
          'pathIds': [176, 472, 2440],
          'data': {
            'classID': 2440,
            'courseID': 1588,
            'groupID': 472,
            'modelID': 176,
            'ownerID': _sharedId,
            'userID': _owner,
          },
        },
      };

      final books = SkoreGradebookService.parseSharedGradebooks([
        numbers,
        _entry(),
      ], workyearId: 24);

      expect(books.map(_parts), [_parts(_shared)]);
    });

    test('a label without a "/": all of it is the class, no course name; '
        'a course name with a "/" keeps it', () {
      final books = SkoreGradebookService.parseSharedGradebooks([
        _entry(label: '6EWI'),
        _entry(gradebook: 34981, label: '6EWI/Frans/Engels'),
      ], workyearId: 24);

      expect(
        [for (final b in books) (b.className, b.courseName)],
        [('6EWI', ''), ('6EWI', 'Frans/Engels')],
      );
    });

    test('refuses an answer in another shape with a SmartschoolSkoreError, '
        'never an empty list', () {
      void refused(Object? result, Object reason) => expect(
        () =>
            SkoreGradebookService.parseSharedGradebooks(result, workyearId: 24),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            contains(reason),
          ),
        ),
      );

      refused({'gradebooks': []}, 'instead of a list');
      refused(['34980'], 'instead of an object');
      refused([
        {..._entry(), 'writable': 2},
      ], 'instead of writable 1 or 0');
      refused([
        {..._entry()}..remove('writable'),
      ], 'instead of writable 1 or 0');
      refused([_entry(id: '1007_34980')], 'instead of 1006_34980');
      refused([
        {..._entry()}..remove('ownerId'),
      ], 'a gradebook in the gradebooks shared with you');
      refused([
        _entry(pathIds: const ['176', '472']),
      ], 'instead of the pathIds of a class');
      refused([
        _entry(pathIds: const ['176', '-1', '2440']),
      ], 'which is not that of a class');
      refused([
        _entry(
          data: const {
            'classID': '2444',
            'courseID': '1588',
            'groupID': '472',
            'modelID': '176',
            'ownerID': '34980',
            'userID': '1006',
          },
        ),
      ], 'which is not that of a class');
      refused([
        {..._entry(), 'classcourse': 12},
      ], 'instead of texts');
    });
  });

  group('the list', () {
    test('getSharedGradebooks reads the own gradebooks for the school year, '
        'then accessableList for the user, both as the user', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final books = await gradebooks.getSharedGradebooks();

      expect(server.requests, [
        'GET /course-list/api/v1/courses', // the session's user
        'GET /',
        'RPC getNavigation',
        'RPC accessableList',
      ]);
      expect(server.calls.map((c) => c.session.containsKey('wy')), [
        false,
        false,
      ]);
      expect(books.map(_parts), [_parts(_shared), _parts(_readOnly)]);
    });

    test('getGradebookYear with includeShared gives both lists; without it, '
        'accessableList is not asked', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final plain = await gradebooks.getGradebookYear();
      expect(server.requests.where((r) => r.startsWith('RPC')), [
        'RPC getNavigation',
      ]);
      expect(plain.sharedGradebooks, isEmpty);
      expect(plain.gradebooks.single.access, SkoreGradebookAccess.own);

      server.requests.clear();
      final year = await gradebooks.getGradebookYear(includeShared: true);
      expect(server.requests, ['RPC getNavigation', 'RPC accessableList']);
      expect(year.gradebooks.single.gradebookId, 32508);
      expect(year.sharedGradebooks.map((b) => b.gradebookId), [
        _sharedId,
        _readOnlyId,
      ]);
      expect(year.toString(), contains('shared: 2'));
    });

    test('an earlier school year: both go out for it (wy), and the shared '
        'gradebooks are of it', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final books = await gradebooks.getSharedGradebooks(workyearId: 22);

      expect(server.calls.map((c) => (c.method, c.session['wy'])), [
        ('getNavigation', '22'),
        ('accessableList', '22'),
      ]);
      expect(books.map((b) => b.workyearId), [22, 22]);
    });
  });

  group('reading a shared gradebook', () {
    test('getGradebook opens it as the web client does: in the name of its '
        'teacher, restricted to it', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_shared);

      expect(server.requests, [
        'GET /course-list/api/v1/courses', // the session's user
        'GET /',
        'RPC init',
        'RPC getGradebookContext',
      ]);
      expect(sheet.gradebook, same(_shared));
      expect(sheet.courseName, 'Digitale vaardigheden');
      expect(sheet.periods.single.id, _period);
      // Skore's activePeriodE -1, as seen live: the first period.
      expect(sheet.activePeriod?.id, _period);
      expect(sheet.pupils.map((p) => p.id), [_an, _bart]);
      expect(sheet.writable, isTrue);
      expect(server.calls.map((c) => c.session['wy']), ['24', '24']);
    });

    test('a shared gradebook without evaluation periods (only a report '
        'period, as seen live): its pupils, getGradebookContext not '
        'asked', () async {
      final server = _Skore(init: _init(periods: false));
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_shared);

      expect(server.requests, [
        'GET /course-list/api/v1/courses', // the session's user
        'GET /',
        'RPC init',
      ]);
      expect(sheet.periods, isEmpty);
      expect(sheet.writable, isFalse);
      expect(sheet.pupils, hasLength(2));
    });

    test('getEvaluations and getFeedback name the gradebook\'s teacher; the '
        "feedback is each teacher's", () async {
      final server = _Skore(
        feedback: {
          _an: [_feedback('f-owner', teacher: _owner), _feedback('f-mine')],
        },
      );
      final gradebooks = await serve(server);

      final evaluation = (await gradebooks.getEvaluations(
        _shared,
        _period,
      )).single;
      final feedback = await gradebooks.getFeedback(_shared, evaluation, _an);

      expect(evaluation.id, _toets);
      expect(evaluation.gradebookId, _sharedId);
      expect(evaluation.results.grades.map((g) => g.pupilId), [_an, _bart]);
      expect(server.requests.last, 'GET $_anFeedback');
      expect(feedback.map((f) => (f.id, f.teacherId)), [
        ('f-owner', _owner),
        ('f-mine', _me),
      ]);
    });

    test("the own gradebooks still go out in the user's name, without a "
        'restriction', () async {
      final server = _Skore();
      final gradebooks = await serve(server);
      final own = (await gradebooks.getGradebooks()).single;

      expect(own.isShared, isFalse);
      expect(server.calls.single.session['teacher'], _me);
      expect(server.calls.single.session['restriction'], 0);
      expect(
        SkoreGradebookService.feedbackPath(
          platform: 4069,
          userId: _me,
          gradebook: own,
          evaluationId: _toets,
          pupilId: _an,
        ),
        contains('/teacher/4069_${_me}_0/'),
      );
    });
  });

  group('writing in a gradebook shared to write', () {
    test("saveFeedback creates the user's own feedback, naming the "
        "gradebook's teacher as the web client does; the teacher's feedback "
        'is left alone', () async {
      final teachers = _feedback('f-owner', teacher: _owner);
      final server = _Skore(
        feedback: {
          _an: [teachers],
        },
      );
      final (gradebooks, evaluation) = await ready(server);

      final saved = await gradebooks.saveFeedback(
        _shared,
        evaluation,
        _an,
        'Goed gewerkt.',
      );

      expect(server.requests, [
        'RPC getNavigation', // the current school year
        'RPC accessableList', // still shared with the user, to write
        'RPC init', // the period: one of the gradebook's, open
        'RPC getGradebookContext', // writable in that period
        'RPC getEvaluations', // the evaluation and the pupil's cell, now
        'GET $_anFeedback', // the pupil's feedback, the teacher's included
        'POST $_feedbackApi', // the create
        'GET $_anFeedback', // the check
      ]);
      expect(server.posts.single, {
        'evaluation': {
          'evaluationId': '4069_$_toets',
          'classGroupId': '4069_2440',
          'teacherId': '4069_${_owner}_0',
          'context': '176_472_2440',
        },
        'studentId': '4069_${_an}_0',
        'text': 'Goed gewerkt.',
        'attachments': <Object?>[],
      });
      expect(saved.teacherId, _me);
      expect(saved.text, 'Goed gewerkt.');
      expect(server.feedback[_an]!.first, teachers);
    });

    test("saveFeedback changes the user's own feedback there", () async {
      final server = _Skore(
        feedback: {
          _an: [_feedback('f-owner', teacher: _owner), _feedback('f-mine')],
        },
      );
      final (gradebooks, evaluation) = await ready(server);

      final saved = await gradebooks.saveFeedback(
        _shared,
        evaluation,
        _an,
        'Beter.',
      );

      expect(server.requests, contains('POST $_feedbackApi/f-mine'));
      expect(server.posts.single['id'], 'f-mine');
      expect(
        (server.posts.single['evaluation'] as Map)['teacherId'],
        '4069_${_owner}_0',
      );
      expect(saved.id, 'f-mine');
      expect(server.feedback[_an]!.first['text'], 'Eerste opmerking.');
    });

    test('saveGrades sends saveGrade in the name of the gradebook\'s teacher, '
        'restricted to it, as the web client does', () async {
      final server = _Skore();
      final (gradebooks, evaluation) = await ready(server);

      final saved = await gradebooks.saveGrades(_shared, evaluation, {
        _an: '15,5',
        _bart: '12',
      });

      expect(server.requests, [
        'RPC getNavigation',
        'RPC accessableList',
        'RPC init',
        'RPC getGradebookContext',
        'RPC getEvaluations',
        'RPC saveGrade',
        'RPC saveGrade',
        'RPC getEvaluations', // the check
      ]);
      expect(saved.map((pupil, cell) => MapEntry(pupil, cell.grade)), {
        _an: '15.5',
        _bart: '12',
      });
    });
  });

  group('refuses, saving nothing,', () {
    test('a gradebook shared to read only, before anything is sent: a '
        'SmartschoolSkoreGradebookReadOnlyError', () async {
      final server = _Skore();
      final gradebooks = await serve(server);
      final evaluation = SkoreEvaluation(
        id: _toets,
        evaluationId: _toets,
        gradebookId: _readOnlyId,
        periodId: _period,
        column: 'A',
        title: 'Toets 1',
        shortName: null,
        date: DateTime(2026, 10, 20),
        max: 20,
        componentId: 0,
        componentName: 'geen',
        type: SkoreEvaluationType.points,
        typeCode: 1,
        courseId: 1588,
        courseName: 'Digitale vaardigheden',
        isPlannerEvaluation: false,
        publication: const SkorePublication(
          state: SkorePublicationState.notPublished,
          at: null,
          rawPublic: '0',
          rawPublicDateTime: '',
        ),
        results: const SkoreEvaluationResults(evaluationId: _toets),
      );

      await expectLater(
        gradebooks.saveGrade(_readOnly, evaluation, _an, '15'),
        throwsA(_readOnlyError('saveGrade', _readOnlyId)),
      );
      await expectLater(
        gradebooks.saveGrades(_readOnly, evaluation, {_an: 'not a grade'}),
        throwsA(_readOnlyError('saveGrades', _readOnlyId)),
      );
      await expectLater(
        gradebooks.saveFeedback(_readOnly, evaluation, _an, ''),
        throwsA(_readOnlyError('saveFeedback', _readOnlyId)),
      );
      await expectLater(
        gradebooks.createEvaluation(
          _readOnly,
          _period,
          title: 'Toets 2',
          date: DateTime(2026, 10, 28),
          max: 20,
        ),
        throwsA(_readOnlyError('createEvaluation', _readOnlyId)),
      );
      expect(server.requests, isEmpty);
    });

    test('a gradebook passed as shared to write that Skore lists as shared '
        'to read only now: the same error, with the gradebook as listed, '
        'after reading the list again', () async {
      final server = _Skore(shared: [_entry(writable: 0)]);
      final (gradebooks, evaluation) = await ready(server);

      await expectLater(
        gradebooks.saveFeedback(_shared, evaluation, _an, 'Goed gewerkt.'),
        throwsA(
          allOf(
            _readOnlyError('saveFeedback', _sharedId),
            isA<SmartschoolSkoreGradebookReadOnlyError>().having(
              (e) => e.message,
              'message',
              contains('as Skore lists the gradebooks shared with you now'),
            ),
          ),
        ),
      );
      expect(server.requests, ['RPC getNavigation', 'RPC accessableList']);
      expect(server.posts, isEmpty);
    });

    test('a gradebook no longer shared with the user: a refused change, not '
        'a read-only one', () async {
      final server = _Skore(shared: [_sharedList().last]);
      final (gradebooks, evaluation) = await ready(server);

      await expectLater(
        gradebooks.saveGrade(_shared, evaluation, _an, '15'),
        throwsA(
          isA<SmartschoolSkoreChangeRefusedError>()
              .having(
                (e) => e,
                'error',
                isNot(isA<SmartschoolSkoreGradebookReadOnlyError>()),
              )
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains(
                    'gradebook $_sharedId is not shared with you in '
                    '2026-2027 (Skore lists 1 gradebooks shared with you)',
                  ),
                  endsWith('Nothing was saved.'),
                ),
              ),
        ),
      );
      expect(server.requests, ['RPC getNavigation', 'RPC accessableList']);
      expect(server.grades, isEmpty);
    });

    test('a period of a shared gradebook that Skore shows read-only to the '
        'user', () async {
      final server = _Skore(context: _context(writable: 0));
      final (gradebooks, evaluation) = await ready(server);

      await expectLater(
        gradebooks.saveGrade(_shared, evaluation, _an, '15'),
        throwsA(
          isA<SmartschoolSkoreChangeRefusedError>().having(
            (e) => e.message,
            'message',
            contains('Skore shows gradebook $_sharedId read-only to you'),
          ),
        ),
      );
      expect(server.grades, isEmpty);
    });

    test('createEvaluation in a gradebook shared to write: the library '
        'creates evaluations in the own gradebooks only (before anything is '
        'sent)', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.createEvaluation(
          _shared,
          _period,
          title: 'Toets 2',
          date: DateTime(2026, 10, 28),
          max: 20,
        ),
        throwsA(
          isA<SmartschoolSkoreChangeRefusedError>()
              .having(
                (e) => e,
                'error',
                isNot(isA<SmartschoolSkoreGradebookReadOnlyError>()),
              )
              .having(
                (e) => e.message,
                'message',
                'createEvaluation: gradebook $_sharedId is shared with you by '
                    'teacher $_owner: the library creates evaluations in your '
                    'own gradebooks only. Nothing was saved.',
              ),
        ),
      );
      expect(server.requests, isEmpty);
    });
  });

  test('SmartschoolSkoreGradebookReadOnlyError is a refused change, and so a '
      'SmartschoolSkoreError: nothing was saved', () {
    const error = SmartschoolSkoreGradebookReadOnlyError(
      'read only',
      gradebook: _readOnly,
    );

    expect(error, isA<SmartschoolSkoreChangeRefusedError>());
    expect(error, isA<SmartschoolSkoreError>());
    expect(error.gradebook, same(_readOnly));
    expect(
      error.toString(),
      'SmartschoolSkoreGradebookReadOnlyError: read only',
    );
    expect(
      _readOnly.toString(),
      allOf(contains('access: read'), contains('teacherId: $_reader')),
    );
  });
}
