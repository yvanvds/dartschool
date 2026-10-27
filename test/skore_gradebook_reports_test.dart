// Tests for issue #195: the report periods of a gradebook ("Rapporten |
// Rapport 1"), a report with each pupil's results so far and course comment
// (`SkoreGradebookService.getReport`), and the save of a course comment
// (`saveReportComment`).
//
// What was seen live (read-only, 2026-10-27), and what the web client's code
// sends:
//   - `init` lists the report periods as `reports`: `[{name: "R1D",
//     fullname: "Rapport 1", id: "2762", info: "<p>...", open: 1, type: "a",
//     rating: 0, timestamp: "2026-10-30T23:00:00+0100", lockIcon: 0}]`, also
//     for a gradebook without evaluation periods (a behaviour gradebook);
//   - the web client opens a report with `getReportsResults(pathIds,
//     courses, reportID, userID)`, the report's ID a string, in the
//     gradebook's scope (#191; seen live for gradebooks shared with the
//     account too). Its answer: `{courses, comps, results, length, stamp}`,
//     three tables of `{orientation, rowHeader, colHeader: {sort}, stream}`.
//     `comps` has a column per component of the course (`2264_1`, `div.gbcomps`
//     "DW") and the comment's column (`2264_info`); a behaviour gradebook has
//     the comment's column only. In `results`, a component's cell holds
//     `<div class="gbc">79</div>` (`-` for none, the class `gbc_low` for a
//     low one), without `p`; the rows `gravg_` and `clavg_<classId>` hold
//     the averages; a comment's cell `<div class="gbinfo readonly
//     extern-editor" data-type="separated" skoretooltip="true"
//     tooltip="<base64>" encoding="base64">text</div>` with `p` [1, 2762],
//     or, closed for the pupil, the class `gbc_closed` and `p` [0, 2762];
//     `length` is "1600";
//   - a course that is not on the report: HTTP 404 with `{"message":
//     "Course not found in source!"}`, without a session;
//   - the web client saves a comment with `saveType("info", col, row, text,
//     params, pathIds)`: the comment's column and the pupil's row, the text
//     with its line breaks as `\n` (its cells show them as U+205F), the
//     cell's `p` as strings, and the class's `pathIds`; it reads
//     `{savedState, stream}`. From its code: **not tried live**.
//
// Teachers, pupils, names and texts are fakes; class, group, model, course,
// gradebook and report IDs are Skore's own, as in the other gradebook tests
// (34999 is made up). Nothing here reaches Skore: the fake fails the test on
// any request it does not expect.
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

/// The logged-in teacher, and a colleague who shares gradebooks with them
/// (fake user IDs).
const _me = 1005;
const _colleague = 1006;

/// The pupils of 6EWI (fake IDs), and one of 6WEWI2, whose rows Skore may
/// send along.
const _an = 1201;
const _bart = 1202;
const _cas = 1203;
const _otherClass = 1301;

/// The open report of 2026-2027, and a closed one (made up).
const _r1 = 2762;
const _closed = 2570;

const _pathIds = ['176', '472', '2440'];

String _startPage() =>
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"4069_${_me}_0","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// 6EWI's gradebook of Informatica, the teacher's own.
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

/// 6EWI's behaviour gradebook ("Gedrag"), the teacher's own: no evaluation
/// periods, a report with comments only.
const _gedrag = SkoreGradebook(
  gradebookId: 35158,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: 2440,
  className: '6EWI',
  courseId: 2890,
  courseName: 'Gedrag (6e j DO)',
  workyearId: 24,
);

/// 6EWI's gradebook of Digitale vaardigheden, which a colleague shared with
/// the teacher to write, as getSharedGradebooks reads it.
const _shared = SkoreGradebook(
  gradebookId: 34980,
  teacherId: _colleague,
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

/// The same, shared to read only.
const _sharedRead = SkoreGradebook(
  gradebookId: 34980,
  teacherId: _colleague,
  modelId: 176,
  modelName: '',
  groupId: 472,
  groupName: '',
  classId: 2440,
  className: '6EWI',
  courseId: 1588,
  courseName: 'Digitale vaardigheden',
  workyearId: 24,
  access: SkoreGradebookAccess.read,
  ownerName: 'Piet Peeters',
);

/// 6EWI's gradebook of Informatica of 2025-2026.
const _older = SkoreGradebook(
  gradebookId: 28998,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: 2440,
  className: '6EWI',
  courseId: 2264,
  courseName: 'Informaticawetenschappen (2 uur) (6e j DO)',
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

/// getNavigation of 2026-2027 with 6EWI's gradebooks of Informatica and
/// Gedrag, the teacher's.
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
                for (final book in [_ewi, _gedrag])
                  {
                    'coursename': book.courseName,
                    'data': {
                      'ownerID': '${book.gradebookId}',
                      'userID': '$_me',
                      'classID': '2440',
                      'groupID': '472',
                      'modelID': '176',
                      'courseID': '${book.courseId}',
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

/// accessableList: 6EWI's Digitale vaardigheden, shared by the colleague
/// with the teacher, to write unless [writable] is 0.
List<Object?> _accessable({int writable = 1}) => [
  {
    'id': '${_colleague}_34980',
    'userId': '$_colleague',
    'ownerId': '34980',
    'courseId': '1588',
    'writable': writable,
    'username': 'Piet Peeters',
    'classcourse': '6EWI/Digitale vaardigheden',
    'navigation': {
      'pathIds': _pathIds,
      'data': {
        'classID': '2440',
        'courseID': '1588',
        'groupID': '472',
        'modelID': '176',
        'ownerID': '34980',
        'userID': '$_colleague',
      },
    },
  },
];

/// R1D, the open report, as `init` lists it (seen live).
Map<String, Object?> _r1d({int open = 1}) => {
  'name': 'R1D',
  'fullname': 'Rapport 1',
  'id': '$_r1',
  'info':
      '<p><u><b>Rapport 1</b></u></p><p>Open tot 2026-10-30 23:00</p>'
      '<p>Rapport 1 van de school</p>',
  'open': open,
  'type': 'a',
  'rating': 0,
  'timestamp': '2026-10-30T23:00:00+0100',
  'lockIcon': 0,
};

/// init of [book]: DW1 for a gradebook of Informatica, no evaluation
/// periods for Gedrag; R1D (open unless [r1Open] is 0) and a closed report.
Map<String, Object?> _init(SkoreGradebook book, {int r1Open = 1}) => {
  'left_0': {
    'stream': [
      {'c': 0, 'r': 'clavg_2440', 'v': '6EWI : Klasgemiddelde'},
      for (final (id, name) in [
        (_an, 'Aerts, An'),
        (_bart, 'Claes, Bart'),
        (_cas, 'Dierckx, Cas'),
      ])
        {
          'c': 0,
          'r': 'pupil_${id}_2440',
          'v': '<span>${id - 1200}.  $name</span>',
        },
    ],
  },
  'periods': book.courseId == 2890
      ? <Object?>[]
      : [
          {
            'name': 'DW1',
            'fullname': 'DW1',
            'id': '1704',
            'info': '<p>Open van 2026-09-18 15:30 tot en met 2026-12-18</p>',
            'open': 1,
            'timestamp': '2026-12-18T20:00:00+0100',
            'categoryMode': 1,
          },
        ],
  'reports': [
    _r1d(open: r1Open),
    {
      'name': 'R0',
      'fullname': 'Rapport 0',
      'id': '$_closed',
      'info': '<p>Gesloten!</p>',
      'open': 0,
      'type': 'a',
      'rating': 0,
      'timestamp': '2026-09-30T23:00:00+0200',
      'lockIcon': 1,
    },
  ],
  'activePeriodE': book.courseId == 2890 ? -1 : 0,
  'activeReport': 0,
  'ownerMap': [
    {
      'courseID': '${book.courseId}',
      'groupID': '472',
      'coursename': book.courseId == 2890 ? 'Gedrag' : 'Informatica',
      'ownerID': '${book.gradebookId}',
      'classID': '2440',
    },
  ],
};

/// A comment's cell HTML as Skore gives it: [text] with its line breaks as
/// U+205F, as its tooltip in base64 too, and the class `gbc_closed` when it
/// is [closed].
String _commentHtml(String text, {bool closed = false}) {
  final shown = text.replaceAll('\n', ' ');
  final tooltip = text.isEmpty
      ? ''
      : '  skoretooltip="true" tooltip="${base64.encode(utf8.encode(shown))}" '
            'encoding="base64"';
  return '<div class="gbinfo readonly extern-editor'
      '${closed ? ' gbc_closed' : ''}"   data-type="separated"$tooltip>'
      '${htmlEscape.convert(shown)}</div>';
}

/// A result's cell HTML as Skore gives it.
String _resultHtml(String value, {bool low = false}) =>
    '<div class="gbc${low ? ' gbc_low' : ''}" >$value</div>'
    '<div class="gbc_cell_header"><span onmousedown="skore.gbc.onCellMessage();" '
    'class="gbc_message_place" >&nbsp;&nbsp;</span></div>'
    '<div class="gbc_presence "><div></div><div></div></div>';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// An RPC call as it reached the fake Skore.
typedef _Call = ({
  String method,
  Map<String, dynamic> session,
  List<dynamic> params,
});

/// A Skore that answers the reads of the gradebooks above, keeps the
/// course comment of each pupil on R1D per course, and applies a save of a
/// comment as Skore's web client expects it.
class _Skore implements HttpClientAdapter {
  _Skore({
    Map<int, String> comments = const {},
    this.r1Open = 1,
    this.writable = 1,
    this.reportAnswer,
    this.saveAnswer,
    this.forgetSave = false,
    this.length = '1600',
  }) : comments = {
         2264: {...comments},
         2890: {...comments},
         1588: {...comments},
       };

  /// The comments on R1D, by course and pupil.
  final Map<int, Map<int, String>> comments;

  /// The pupils whose comment is closed (`p` [0, report]): Cas.
  final Set<int> closedFor = const {_cas};

  /// Whether R1D is open.
  final int r1Open;

  /// The `writable` of the shared gradebook in accessableList.
  final int writable;

  /// The answer to the [call]th getReportsResults (from 0), or `null` for
  /// the report as kept.
  final _Answer? Function(int call)? reportAnswer;

  /// The answer to a saveType, instead of applying it.
  final _Answer? saveAnswer;

  /// Whether a saveType is answered as applied, but not kept.
  final bool forgetSave;

  /// The report's `length`.
  final Object? length;

  /// The RPC calls, in order.
  final List<_Call> calls = [];

  /// The RPC methods called, in order.
  List<String> get methods => [for (final c in calls) c.method];

  int _reportCalls = 0;

  /// getReportsResults for [courseId]: 6EWI's pupils (and one of 6WEWI2,
  /// which Skore may send along), a component for Informatica, none for
  /// Gedrag.
  Map<String, Object?> _report(int courseId, int reportId) {
    final components = courseId == 2890 ? const <String>[] : ['${courseId}_1'];
    final pupils = [_an, _bart, _cas];
    final kept = comments[courseId]!;
    return {
      'courses': {
        'orientation': 'byColumn',
        'rowHeader': {
          'sort': [0],
        },
        'colHeader': {
          'sort': [courseId],
          'widths': [469],
        },
        'stream': [
          {
            'c': courseId,
            'r': 0,
            'v':
                '<div class="gbcourse" >${courseId == 2890 ? 'Gedrag' : 'Informaticawetenschappen (2 uur)'}</div>'
                '<div class="gbc_cell_header"><span class="gbc_message_place" '
                '>&nbsp;&nbsp;</span></div>',
          },
        ],
      },
      'comps': {
        'orientation': 'byColumn',
        'rowHeader': {
          'sort': [0],
        },
        'colHeader': {
          'sort': [...components, '${courseId}_info'],
        },
        'stream': [
          for (final column in components)
            {'c': column, 'r': 0, 'v': '<div class="gbcomps" >DW</div>'},
          {
            'c': '${courseId}_info',
            'r': 0,
            'v': '<div class="gbcomps" >Vakcommentaar</div>',
          },
        ],
      },
      'results': {
        'orientation': 'byColumn',
        'rowHeader': {'sort': <Object?>[]},
        'colHeader': {'sort': <Object?>[]},
        'stream': [
          for (final column in components) ...[
            {'c': column, 'r': 'gravg_', 'v': _resultHtml('-')},
            {'c': column, 'r': 'clavg_2440', 'v': _resultHtml('71')},
            {'c': column, 'r': 'pupil_${_an}_2440', 'v': _resultHtml('79')},
            {
              'c': column,
              'r': 'pupil_${_bart}_2440',
              'v': _resultHtml('38', low: true),
            },
            {'c': column, 'r': 'pupil_${_cas}_2440', 'v': _resultHtml('-')},
            {
              'c': column,
              'r': 'pupil_${_otherClass}_2444',
              'v': _resultHtml('50'),
            },
          ],
          for (final pupil in pupils)
            {
              'c': '${courseId}_info',
              'r': 'pupil_${pupil}_2440',
              'v': _commentHtml(
                kept[pupil] ?? '',
                closed: closedFor.contains(pupil),
              ),
              'p': [closedFor.contains(pupil) ? 0 : 1, reportId],
            },
          {
            'c': '${courseId}_info',
            'r': 'pupil_${_otherClass}_2444',
            'v': _commentHtml('Andere klas.'),
            'p': [1, reportId],
          },
        ],
      },
      'length': length,
      'stamp': {'_2440': null},
    };
  }

  static ResponseBody _body(String body, {int status = 200, String? type}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [type ?? 'text/html; charset=UTF-8'],
        },
      );

  _Answer _rpc(_Call call) {
    final session = call.session;
    final params = call.params;
    // The scope of a gradebook (#191): the colleague's shared one in their
    // name, restricted to it; the own ones in the user's.
    void expectScope(int teacher, int restriction) {
      expect(session['teacher'], teacher, reason: '${call.method} teacher');
      expect(
        session['restriction'],
        restriction,
        reason: '${call.method} restriction',
      );
    }

    switch (call.method) {
      case 'getNavigation':
        expectScope(_me, 0);
        return _ok(_answer(call.method, _navigation()));
      case 'accessableList':
        expectScope(_me, 0);
        return _ok(_answer(call.method, _accessable(writable: writable)));
      case 'init':
        final owner = int.parse((params[1] as List).single as String);
        final book = owner == 34980
            ? _shared
            : owner == 35158
            ? _gedrag
            : _ewi;
        expectScope(
          book.isShared ? _colleague : _me,
          book.isShared ? 34980 : 0,
        );
        return _ok(_answer(call.method, _init(book, r1Open: r1Open)));
      case 'getGradebookContext':
        // getGradebook only, for DW1: never asked by the writes of a report.
        expectScope(_me, 0);
        expect(params[4], 1704);
        return _ok(
          _answer(call.method, {
            'writable': 1,
            'coordinator': 0,
            'classId': 2440,
            'owners': [32508],
          }),
        );
      case 'getReportsResults':
        final answer = reportAnswer?.call(_reportCalls++);
        if (answer != null) return answer;
        expect(params, hasLength(4));
        expect(params[0], _pathIds, reason: 'pathIds, as strings');
        final course = int.parse((params[1] as List).single as String);
        expect(params[2], isA<String>(), reason: "the report's ID: a string");
        final shared = course == 1588;
        expect(params[3], shared ? _colleague : _me, reason: 'userID');
        expectScope(shared ? _colleague : _me, shared ? 34980 : 0);
        return _ok(
          _answer(call.method, _report(course, int.parse(params[2] as String))),
        );
      case 'saveType':
        expect(params, hasLength(6));
        expect(params[0], 'info');
        final column = params[1] as String;
        final course = int.parse(column.split('_').first);
        expect(column, '${course}_info');
        final row = (params[2] as String).split('_');
        expect(row.first, 'pupil');
        expect(row.last, '2440');
        expect(params[3], isA<String>());
        expect(params[4], everyElement(isA<String>()), reason: 'params');
        expect(params[5], _pathIds);
        final shared = course == 1588;
        expectScope(shared ? _colleague : _me, shared ? 34980 : 0);
        final answer = saveAnswer;
        if (answer != null) return answer;
        if (!forgetSave) {
          comments[course]![int.parse(row[1])] = params[3] as String;
        }
        return _ok(
          _answer(call.method, {'savedState': 1, 'stream': <Object?>[]}),
        );
    }
    fail('Unexpected RPC call: ${call.method}');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    switch ((options.method, path)) {
      case ('GET', '/'):
        return _body(_startPage());
      case ('GET', '/course-list/api/v1/courses'):
        return _body('[{"platformId":4069}]', type: 'application/json');
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final call = (
          method: form['rpc_method']!,
          session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
          params: jsonDecode(form['rpc_params']!) as List<dynamic>,
        );
        calls.add(call);
        final answer = _rpc(call);
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

/// The answer Skore gave live to a course that is not on the report.
const _notInSource = (
  status: 404,
  body: '{"message":"Course not found in source!"}',
);

/// A [SmartschoolSkoreChangeRefusedError] of saveReportComment whose message
/// holds [reason].
Matcher _refused(Object reason) => isA<SmartschoolSkoreChangeRefusedError>()
    .having(
      (e) => e.message,
      'message',
      allOf(startsWith('saveReportComment: '), contains(reason)),
    )
    .having((e) => e.message, 'message', endsWith('Nothing was saved.'));

/// A [SmartschoolSkoreReportCommentSaveUnconfirmedError] about An's comment
/// on R1D of 6EWI's Informatica.
Matcher _unconfirmed({
  String text = 'Zeer goed gewerkt.',
  Object? cause = isNull,
  Object? message = anything,
}) => allOf(
  isNot(isA<SmartschoolSkoreError>()),
  isA<SmartschoolSkoreSaveUnconfirmedError>(),
  isA<SmartschoolSkoreReportCommentSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having(
        (e) => e.message,
        'message',
        endsWith('and pass the comment it shows as replacing).'),
      )
      .having((e) => e.gradebookId, 'gradebookId', 32508)
      .having((e) => e.reportId, 'reportId', _r1)
      .having((e) => e.pupilId, 'pupilId', _an)
      .having((e) => e.text, 'text', text)
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
    return SkoreGradebookService(client);
  }

  // ---------------------------------------------------------------------------
  // The report periods
  // ---------------------------------------------------------------------------

  group('the report periods of a gradebook', () {
    test(
      'getGradebook reads them from init, next to the evaluation periods',
      () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        final sheet = await gradebooks.getGradebook(_ewi);

        expect(sheet.periods.map((p) => p.name), ['DW1']);
        expect(sheet.reports, hasLength(2));
        final r1d = sheet.reports.first;
        expect(r1d.id, _r1);
        expect(r1d.name, 'R1D');
        expect(r1d.fullName, 'Rapport 1');
        expect(r1d.isOpen, isTrue);
        expect(r1d.closesAt, DateTime.utc(2026, 10, 30, 22));
        expect(r1d.info, contains('Open tot 2026-10-30 23:00'));
        expect(r1d.typeCode, 'a');
        expect(r1d.rating, 0);
        final r0 = sheet.reports.last;
        expect((r0.id, r0.name, r0.isOpen), (_closed, 'R0', false));
        expect(server.methods, ['init', 'getGradebookContext']);
      },
    );

    test('a gradebook without evaluation periods has its report period '
        '(a behaviour gradebook, #192)', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_gedrag);

      expect(sheet.periods, isEmpty);
      expect(sheet.activePeriod, isNull);
      expect(sheet.writable, isFalse);
      expect(sheet.reports.map((r) => r.id), [_r1, _closed]);
      expect(server.methods, ['init']);
    });

    test('parseReports: none for an init without reports; unknown shapes '
        'refused', () {
      expect(SkoreGradebookService.parseReports(null), isEmpty);
      expect(SkoreGradebookService.parseReports(<Object?>[]), isEmpty);
      final noTime = SkoreGradebookService.parseReports([
        {'id': 7, 'name': 'R2', 'open': '1', 'timestamp': ''},
      ]).single;
      expect(noTime.closesAt, isNull);
      expect(noTime.fullName, 'R2');
      expect(noTime.isOpen, isTrue);
      for (final wrong in <Object?>[
        'R1D',
        {'id': '2762'},
        ['R1D'],
        [
          {'id': 'x', 'name': 'R1D'},
        ],
        [
          {'id': '2762', 'timestamp': '2026-10-30 23:00'},
        ],
      ]) {
        expect(
          () => SkoreGradebookService.parseReports(wrong),
          throwsA(isA<SmartschoolSkoreError>()),
          reason: '$wrong',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // getReport
  // ---------------------------------------------------------------------------

  group('getReport', () {
    test("reads the pupils' results and course comments as the web client "
        'opens a report', () async {
      final server = _Skore(
        comments: {
          _an: 'Goed gewerkt & mooi verbeterd.\nZo verder.',
          _cas: 'Afwezig.',
        },
      );
      final gradebooks = await serve(server);

      final report = await gradebooks.getReport(_ewi, _r1);

      final call = server.calls.single;
      expect(call.method, 'getReportsResults');
      expect(call.params, [
        _pathIds,
        ['2264'],
        '$_r1',
        _me,
      ]);
      expect(call.session['wy'], '24');

      expect(report.gradebookId, 32508);
      expect(report.reportId, _r1);
      expect(report.courseId, 2264);
      expect(report.courseName, 'Informaticawetenschappen (2 uur)');
      expect(report.hasComments, isTrue);
      expect(report.commentMaxLength, 1600);
      final dw = report.components.single;
      expect((dw.column, dw.name, dw.classAverage), ('2264_1', 'DW', '71'));

      // The class's pupils, in Skore's order: not the pupil of 6WEWI2.
      expect(report.pupils.map((p) => p.pupilId), [_an, _bart, _cas]);
      final an = report.pupil(_an)!;
      expect(an.rowKey, 'pupil_${_an}_2440');
      expect(an.resultOf('2264_1')!.value, '79');
      expect(an.resultOf('2264_1')!.isLow, isFalse);
      // The line break Skore shows as U+205F, the entity decoded.
      expect(an.comment!.text, 'Goed gewerkt & mooi verbeterd.\nZo verder.');
      expect(an.comment!.isEditable, isTrue);
      expect(an.comment!.cellParams, ['1', '$_r1']);
      expect(an.comment!.reportId, _r1);
      expect(an.comment!.courseId, 2264);

      final bart = report.pupil(_bart)!;
      expect(bart.results.single.value, '38');
      expect(bart.results.single.isLow, isTrue);
      expect(bart.comment!.isEmpty, isTrue);
      expect(bart.comment!.isEditable, isTrue);

      // Closed for the pupil: gbc_closed, p [0, report].
      final cas = report.pupil(_cas)!;
      expect(cas.results.single.value, isNull, reason: '-: none');
      expect(cas.comment!.text, 'Afwezig.');
      expect(cas.comment!.isEditable, isFalse);
      expect(cas.comment!.cellParams, ['0', '$_r1']);

      expect(report.pupil(_otherClass), isNull);
      // Prints no comment.
      expect('$report', isNot(contains('Goed')));
      expect('${an.comment}', isNot(contains('Goed')));
      expect('$an', isNot(contains('Goed')));
    });

    test('a behaviour gradebook: the comments only, no components', () async {
      final server = _Skore(comments: {_bart: 'Beleefd.'});
      final gradebooks = await serve(server);

      final report = await gradebooks.getReport(_gedrag, _r1);

      expect(server.calls.single.params[1], ['2890']);
      expect(report.courseName, 'Gedrag');
      expect(report.components, isEmpty);
      expect(report.hasComments, isTrue);
      expect(report.pupils.map((p) => p.pupilId), [_an, _bart, _cas]);
      expect(report.pupil(_an)!.results, isEmpty);
      expect(report.pupil(_bart)!.comment!.text, 'Beleefd.');
    });

    test('a gradebook shared with the user: in the name of its teacher, '
        'restricted to it (#191)', () async {
      final server = _Skore(comments: {_an: 'Vlot.'});
      final gradebooks = await serve(server);

      final report = await gradebooks.getReport(_shared, _r1);

      final call = server.calls.single;
      expect(call.session['teacher'], _colleague);
      expect(call.session['restriction'], 34980);
      expect(call.params, [
        _pathIds,
        ['1588'],
        '$_r1',
        _colleague,
      ]);
      expect(report.pupil(_an)!.comment!.text, 'Vlot.');
    });

    test('a course that is not on the report: Skore\'s 404 with its message, '
        'a SmartschoolSkoreError', () async {
      final server = _Skore(reportAnswer: (_) => _notInSource);
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getReport(_ewi, _r1),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('getReportsResults'),
              contains('HTTP 404'),
              contains('"Course not found in source!"'),
            ),
          ),
        ),
      );
    });

    test(
      'a report ID that is not positive: an ArgumentError, nothing sent',
      () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        for (final id in [0, -1]) {
          await expectLater(
            gradebooks.getReport(_ewi, id),
            throwsA(isA<ArgumentError>()),
          );
        }
        expect(server.calls, isEmpty);
      },
    );

    test('a comment cell with a <br>: a line break', () {
      final report = SkoreGradebookService.parseReport(
        {
          'courses': {
            'colHeader': {
              'sort': [2264],
            },
            'stream': [
              {
                'c': 2264,
                'r': 0,
                'v': '<div class="gbcourse">Informatica</div>',
              },
            ],
          },
          'comps': {
            'colHeader': {
              'sort': ['2264_info'],
            },
            'stream': <Object?>[],
          },
          'results': {
            'stream': [
              {
                'c': '2264_info',
                'r': 'pupil_${_an}_2440',
                'v': '<div class="gbinfo"> Lijn 1<br>Lijn 2 </div>',
                'p': ['1', '$_r1'],
              },
            ],
          },
        },
        _ewi,
        _r1,
      );
      expect(report.pupil(_an)!.comment!.text, 'Lijn 1\nLijn 2');
      expect(report.pupil(_an)!.comment!.isEditable, isTrue);
      expect(report.commentMaxLength, isNull, reason: 'no length');
    });

    test('unknown shapes, another report or without the course: a '
        'SmartschoolSkoreError', () {
      Map<String, Object?> report({
        Object? courses,
        Object? comment = '<div class="gbinfo">Goed.</div>',
        Object? p = const [1, _r1],
        Object? columns = const ['2264_1', '2264_info'],
      }) => {
        'courses':
            courses ??
            {
              'colHeader': {
                'sort': [2264],
              },
              'stream': [
                {'c': 2264, 'r': 0, 'v': '<div class="gbcourse">I</div>'},
              ],
            },
        'comps': {
          'colHeader': {'sort': columns},
          'stream': <Object?>[],
        },
        'results': {
          'stream': [
            {'c': '2264_1', 'r': 'pupil_${_an}_2440', 'v': _resultHtml('79')},
            {'c': '2264_info', 'r': 'pupil_${_an}_2440', 'v': comment, 'p': p},
          ],
        },
        'length': '1600',
      };
      // In this shape, it reads.
      expect(
        SkoreGradebookService.parseReport(
          report(),
          _ewi,
          _r1,
        ).pupil(_an)!.comment!.text,
        'Goed.',
      );
      final wrong = <String, Object?>{
        'not an object': ['x'],
        'without its tables': <String, Object?>{},
        'another course only': report(
          courses: {
            'colHeader': {
              'sort': [1588],
            },
            'stream': [
              {'c': 1588, 'r': 0, 'v': '<div class="gbcourse">D</div>'},
            ],
          },
        ),
        'a comment of another report': report(p: const [1, _closed]),
        'a comment without its parameters': report(p: null),
        'a comment without its div.gbinfo': report(comment: '<div>Goed.</div>'),
        'a column not in the form <courseId>_<n>': report(
          columns: const ['DW', '2264_info'],
        ),
        'columns that are not a list': report(columns: 'DW'),
      };
      for (final MapEntry(key: why, value: answer) in wrong.entries) {
        expect(
          () => SkoreGradebookService.parseReport(answer, _ewi, _r1),
          throwsA(isA<SmartschoolSkoreError>()),
          reason: why,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // saveReportComment
  // ---------------------------------------------------------------------------

  group('saveReportComment', () {
    test('writes the comment of a pupil who has none: the saveType of the '
        'web client, then the report read again', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final comment = await gradebooks.saveReportComment(
        _ewi,
        _r1,
        _an,
        'Zeer goed gewerkt.',
      );

      expect(server.methods, [
        'getNavigation', // the own gradebooks of the current school year
        'init', // the report: one of the gradebook's, open
        'getReportsResults', // the pupil's comment, now
        'saveType', // the save
        'getReportsResults', // the check
      ]);
      final save = server.calls[3];
      expect(save.params, [
        'info',
        '2264_info',
        'pupil_${_an}_2440',
        'Zeer goed gewerkt.',
        ['1', '$_r1'],
        _pathIds,
      ]);
      expect(save.session['teacher'], _me);
      expect(save.session['restriction'], 0);
      expect(save.session['wy'], '24');

      expect(comment.text, 'Zeer goed gewerkt.');
      expect(comment.pupilId, _an);
      expect(comment.isEditable, isTrue);
      expect(server.comments[2264]![_an], 'Zeer goed gewerkt.');
      // Nothing else changed.
      expect(server.comments[2264]!.keys, [_an]);
    });

    test(
      'replaces the comment passed as replacing, compared with its white '
      'space collapsed; the text sent as the comment editor sends it',
      () async {
        final server = _Skore(comments: {_an: 'Goed gewerkt.\nZo verder.'});
        final gradebooks = await serve(server);

        final comment = await gradebooks.saveReportComment(
          _ewi,
          _r1,
          _an,
          '  Zeer goed gewerkt.  \r\n\r\n\r\n\r\n   Ga zo door! Proficiat. ',
          replacing: 'Goed gewerkt.  Zo verder. ',
        );

        const sent = 'Zeer goed gewerkt.\n\nGa zo door!\nProficiat.';
        expect(server.calls[3].params[3], sent);
        expect(server.comments[2264]![_an], sent);
        expect(comment.text, sent);
      },
    );

    test('in a gradebook shared with the user to write: in the name of its '
        'teacher, restricted to it (#191)', () async {
      final server = _Skore(comments: {_an: 'Vlot.'});
      final gradebooks = await serve(server);

      final comment = await gradebooks.saveReportComment(
        _shared,
        _r1,
        _an,
        'Vlot en zelfstandig.',
        replacing: 'Vlot.',
      );

      expect(server.methods, [
        'getNavigation',
        'accessableList', // still shared with the user, to write
        'init',
        'getReportsResults',
        'saveType',
        'getReportsResults',
      ]);
      final save = server.calls[4];
      expect(save.session['teacher'], _colleague);
      expect(save.session['restriction'], 34980);
      expect(save.params.take(3), ['info', '1588_info', 'pupil_${_an}_2440']);
      expect(comment.text, 'Vlot en zelfstandig.');
      expect(server.comments[1588]![_an], 'Vlot en zelfstandig.');
    });

    test('in a behaviour gradebook, which has no evaluation period: no '
        'getGradebookContext', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await gradebooks.saveReportComment(_gedrag, _r1, _bart, 'Beleefd.');

      expect(server.methods, [
        'getNavigation',
        'init',
        'getReportsResults',
        'saveType',
        'getReportsResults',
      ]);
      expect(server.calls[3].params[1], '2890_info');
      expect(server.comments[2890]![_bart], 'Beleefd.');
    });
  });

  group('saveReportComment refuses, saving nothing,', () {
    test('a blank text, a pupil or report ID that is not positive, or a '
        'gradebook shared to read only, before anything is sent', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, ' \n  '),
        throwsA(_refused('the text is blank')),
      );
      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, 0, 'Goed.'),
        throwsA(_refused('0 is not a pupil ID')),
      );
      await expectLater(
        gradebooks.saveReportComment(_ewi, -1, _an, 'Goed.'),
        throwsA(_refused('-1 is not a report ID')),
      );
      await expectLater(
        gradebooks.saveReportComment(_sharedRead, _r1, _an, 'Goed.'),
        throwsA(
          isA<SmartschoolSkoreGradebookReadOnlyError>().having(
            (e) => e.message,
            'message',
            startsWith('saveReportComment: '),
          ),
        ),
      );
      expect(server.calls, isEmpty);
    });

    test('a gradebook of an earlier school year, or one shared to read only '
        'now', () async {
      final server = _Skore(writable: 0);
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_older, _r1, _an, 'Goed.'),
        throwsA(_refused('not of the current one, 2026-2027 (24)')),
      );
      await expectLater(
        gradebooks.saveReportComment(_shared, _r1, _an, 'Goed.'),
        throwsA(isA<SmartschoolSkoreGradebookReadOnlyError>()),
      );
      expect(server.methods, isNot(contains('saveType')));
      expect(server.methods, isNot(contains('init')));
    });

    test(
      'a report that is not one of the gradebook\'s, or that is closed',
      () async {
        final server = _Skore(r1Open: 0);
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveReportComment(_ewi, 1704, _an, 'Goed.'),
          throwsA(
            _refused(
              'report 1704 is not one of gradebook 32508 (it has R1D (2762), '
              'R0 (2570))',
            ),
          ),
        );
        await expectLater(
          gradebooks.saveReportComment(_ewi, _r1, _an, 'Goed.'),
          throwsA(_refused('report R1D (2762) of gradebook 32508 is closed')),
        );
        await expectLater(
          gradebooks.saveReportComment(_ewi, _closed, _an, 'Goed.'),
          throwsA(_refused('report R0 (2570) of gradebook 32508 is closed')),
        );
        expect(server.methods, isNot(contains('getReportsResults')));
        expect(server.methods, isNot(contains('saveType')));
      },
    );

    test(
      'a pupil without a comment in the class, or whose comment is closed',
      () async {
        final server = _Skore(comments: {_cas: 'Afwezig.'});
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveReportComment(_ewi, _r1, _otherClass, 'Goed.'),
          throwsA(
            _refused(
              'pupil $_otherClass has no course comment on report R1D (2762) of '
              'gradebook 32508 in class 2440',
            ),
          ),
        );
        await expectLater(
          gradebooks.saveReportComment(
            _ewi,
            _r1,
            _cas,
            'Goed.',
            replacing: 'Afwezig.',
          ),
          throwsA(
            _refused(
              'Skore does not let you change the course comment of pupil '
              '$_cas on report R1D (2762) of gradebook 32508 (it is closed for '
              'the pupil)',
            ),
          ),
        );
        expect(server.methods, isNot(contains('saveType')));
      },
    );

    test('a report without course comments for the course', () async {
      final server = _Skore(
        reportAnswer: (_) => _ok(
          _answer('getReportsResults', {
            'courses': {
              'colHeader': {
                'sort': [2264],
              },
              'stream': [
                {'c': 2264, 'r': 0, 'v': '<div class="gbcourse">I</div>'},
              ],
            },
            'comps': {
              'colHeader': {
                'sort': ['2264_1'],
              },
              'stream': <Object?>[],
            },
            'results': {
              'stream': [
                {
                  'c': '2264_1',
                  'r': 'pupil_${_an}_2440',
                  'v': _resultHtml('79'),
                },
              ],
            },
            'length': '1600',
          }),
        ),
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'Goed.'),
        throwsA(
          _refused(
            'report R1D (2762) of gradebook 32508 has no course comments for '
            'course 2264',
          ),
        ),
      );
      expect(server.methods, isNot(contains('saveType')));
    });

    test('a text longer than the report allows', () async {
      final server = _Skore(length: '20');
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'x' * 21),
        throwsA(
          _refused(
            'the text has 21 characters, more than the 20 report R1D (2762) '
            'of gradebook 32508 allows',
          ),
        ),
      );
      // 20 fit.
      await gradebooks.saveReportComment(_ewi, _r1, _an, 'x' * 20);
      expect(server.comments[2264]![_an], 'x' * 20);
    });

    test('another comment than replacing: one the caller did not pass, none '
        'when one was passed, or another one', () async {
      final server = _Skore(comments: {_an: 'Goed gewerkt.'});
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed.'),
        throwsA(
          _refused(
            'pupil $_an has a course comment on report R1D (2762) of '
            'gradebook 32508 already (13 characters): pass it as replacing '
            'to replace it',
          ),
        ),
      );
      await expectLater(
        gradebooks.saveReportComment(
          _ewi,
          _r1,
          _an,
          'Zeer goed.',
          replacing: 'Goed gedaan.',
        ),
        throwsA(
          _refused(
            'pupil $_an has another course comment on report R1D (2762) of '
            'gradebook 32508 (13 characters) than the one passed as '
            'replacing (12 characters)',
          ),
        ),
      );
      await expectLater(
        gradebooks.saveReportComment(
          _ewi,
          _r1,
          _bart,
          'Zeer goed.',
          replacing: 'Goed gewerkt.',
        ),
        throwsA(
          _refused(
            'pupil $_bart has no course comment on report R1D (2762) of '
            'gradebook 32508, not the comment passed as replacing (13 '
            'characters)',
          ),
        ),
      );
      expect(server.methods, isNot(contains('saveType')));
      expect(server.comments[2264], {_an: 'Goed gewerkt.'});
    });

    test('its messages hold no comment text', () async {
      final server = _Skore(comments: {_an: 'Goed gewerkt.'});
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(
          _ewi,
          _r1,
          _an,
          'Geheim.',
          replacing: 'Iets anders.',
        ),
        throwsA(
          isA<SmartschoolSkoreChangeRefusedError>().having(
            (e) => e.message,
            'message',
            allOf(
              isNot(contains('Goed')),
              isNot(contains('Geheim')),
              isNot(contains('Iets')),
            ),
          ),
        ),
      );
    });
  });

  group("saveReportComment: Skore's answer to the save", () {
    test('another savedState: unconfirmed, without the stream', () async {
      final server = _Skore(
        saveAnswer: _ok(
          _answer('saveType', {
            'savedState': 0,
            'stream': ['Geheim'],
          }),
        ),
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed gewerkt.'),
        throwsA(
          _unconfirmed(
            message: allOf(
              contains('answered {"savedState":0} instead of savedState 1'),
              isNot(contains('Geheim')),
            ),
          ),
        ),
      );
      expect(server.methods.last, 'saveType', reason: 'no read after it');
    });

    test('a 500: unconfirmed, with the error as its cause', () async {
      final server = _Skore(saveAnswer: (status: 500, body: ''));
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed gewerkt.'),
        throwsA(
          _unconfirmed(
            cause: isA<SmartschoolSkoreError>(),
            message: contains('no usable answer came in'),
          ),
        ),
      );
    });

    test(
      'an answer without a session: the session error, nothing saved',
      () async {
        final server = _Skore(
          saveAnswer: _ok('{"result":null,"session":0,"method":"saveType"}'),
        );
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed gewerkt.'),
          throwsA(isA<SmartschoolSessionExpiredError>()),
        );
        expect(server.methods.last, 'saveType');
      },
    );

    test('reading again shows another text: unconfirmed', () async {
      final server = _Skore(forgetSave: true);
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed gewerkt.'),
        throwsA(
          _unconfirmed(
            message: contains(
              'reading the report again shows another text (0 characters, '
              'not 18)',
            ),
          ),
        ),
      );
      expect(server.methods.last, 'getReportsResults');
    });

    test(
      'reading again fails: unconfirmed, with the failure as its cause',
      () async {
        final server = _Skore(
          reportAnswer: (call) => call == 1 ? _notInSource : null,
        );
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveReportComment(_ewi, _r1, _an, 'Zeer goed gewerkt.'),
          throwsA(
            _unconfirmed(
              cause: isA<SmartschoolSkoreError>(),
              message: contains('reading the report again to check it failed'),
            ),
          ),
        );
        expect(server.comments[2264]![_an], 'Zeer goed gewerkt.');
      },
    );
  });

  group('the text of a course comment', () {
    test('reportCommentText: as the comment editor sends it', () {
      final cases = {
        'Goed.': 'Goed.',
        '  Goed.  ': 'Goed.',
        'Lijn 1\r\nLijn 2': 'Lijn 1\nLijn 2',
        'Lijn 1\rLijn 2': 'Lijn 1\nLijn 2',
        'Lijn 1 Lijn 2': 'Lijn 1\nLijn 2',
        ' Lijn 1 \n\n\n\n Lijn 2 ': 'Lijn 1\n\nLijn 2',
        'Lijn 1\n  \n \nLijn 2': 'Lijn 1\n\nLijn 2',
        ' \n ': '',
      };
      for (final MapEntry(key: text, value: sent) in cases.entries) {
        expect(
          SkoreGradebookService.reportCommentText(text),
          sent,
          reason: jsonEncode(text),
        );
      }
    });

    test('sameReportComment: compared with the white space collapsed', () {
      expect(
        SkoreGradebookService.sameReportComment(
          'Lijn 1 Lijn 2',
          ' Lijn 1\n\nLijn 2 ',
        ),
        isTrue,
      );
      expect(SkoreGradebookService.sameReportComment('', '  '), isTrue);
      expect(SkoreGradebookService.sameReportComment('Goed', 'goed'), isFalse);
      expect(SkoreGradebookService.sameReportComment('Goed.', ''), isFalse);
    });
  });
}
