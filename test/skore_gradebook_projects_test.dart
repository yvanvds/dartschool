// Tests for issue #204: the project gradebooks of Skore ("Projecten"), read
// as Skore's project sheet reads them (`SkoreGradebookService`'s
// `getProjectPeriods`, `getProjectTemplates`, `getLearningGoals`,
// `getProjects` and `getProjectRatings`).
//
// What was seen live (read-only, 2026-11-01), and what the web client's code
// sends:
//   - the gradebook's tab "Projecten" sends `init(courses, owners, userID,
//     pathIds, 1, ownerRestriction)`: the page `1`. Its `periods` are the
//     project periods (`{name, fullname, id: "<digits>", info, open,
//     timestamp, categoryMode: 1, virtual, scope, lockIcon}`); `left_0`,
//     `left_1` and `left_2` are the same pupil rows;
//   - a project period in `categoryMode` 1 opens the page
//     `/Gradebook?context=<JSON>`, the context being the `result` of
//     `getGradebookContext` for the period (`{writable, coordinator,
//     modelId, groupId, classId, periodId, courses, owners, teacherId,
//     virtualId, restriction}`); that page reads with form POSTs to
//     `/Gradebook/Main/<method>`, JSON answers:
//       getTemplateList {context}: `[{id, title, descr, info, templateType,
//         componentId, isRatingAllowed, isGradesAllowed, isRubricsEnabled,
//         isComponentRequired, isComponentForbidden, creator: {id, name,
//         surname}, scale: {id, name, description, ratings: [{id,
//         description, symbol, min, max, scaleValue, color, icon, iconBig,
//         iconName}]}}]`;
//       getCategoriesList {context, template}: `[{id: "<digits>", parentId,
//         description, number, level, isTitle, isCourse, enabled,
//         courseInstanceId}]`, the course's root `"-<courseId>"` under `"0"`;
//       getProjectList {context, template}: `[]` before a project was made,
//         then `[{id, periodId, title, short, date, max, evalType:
//         "ratings", isPublic, publicDateTime, inCount, componentId,
//         groupContext, maxNoRecalculation, owners: [{teacherId, classId,
//         courseId}], template: {...}}]`;
//       getCategoryGradesByProject {context, project}: `[{id, projectId,
//         categoryId: "<digits>", ratingId, grade: null, info: null,
//         options: [], pupil: {id, userId, classId, classNumber, ...}}]`,
//         `userId` the Smartschool user ID of the gradebook's rows;
//     the template and the project go as JSON, as the sheet got them.
//
// Every value here is made up: teachers, pupils, names, texts and IDs.
// Nothing reaches Skore: the fake fails the test on any request it does not
// expect.
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
const _sheetPath = '/Gradebook/Main';

/// The logged-in teacher, and a colleague who shares a gradebook with them.
const _me = 1005;
const _colleague = 1006;

/// Pupils of the class (Smartschool user IDs, and Skore's own IDs), and one
/// of another class of the group.
const _an = 1201;
const _bart = 1202;
const _other = 1301;
const _skoreAn = 970001;
const _skoreBart = 970002;
const _skoreOther = 970003;

/// The class, its group and model, and the course.
const _classId = 2440;
const _otherClassId = 2441;
const _courseId = 1588;

/// The project period, the template and the project.
const _period = 1790;
const _template = 380;
const _project = 3901;

/// The rating levels of the template's scale.
const _low = 61;
const _high = 62;

String _startPage() =>
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"4069_${_me}_0","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// The class's project gradebook, the teacher's own.
const _own = SkoreGradebook(
  gradebookId: 34990,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: _classId,
  className: '6EWI',
  courseId: _courseId,
  courseName: 'Digitale vaardigheden',
  workyearId: 24,
);

/// The same course's project gradebook of the colleague, shared with the
/// teacher.
const _shared = SkoreGradebook(
  gradebookId: 34991,
  teacherId: _colleague,
  modelId: 176,
  modelName: '',
  groupId: 472,
  groupName: '',
  classId: _classId,
  className: '6EWI',
  courseId: _courseId,
  courseName: 'Digitale vaardigheden',
  workyearId: 24,
  access: SkoreGradebookAccess.write,
  ownerName: 'Piet Peeters',
);

/// An RPC answer of Skore with [result].
String _answer(String method, Object? result) => jsonEncode({
  'result': result,
  'session': 1,
  'method': method,
  'timelimit': 0,
  'limitInfo': null,
});

/// The pupil rows of `init`, the same in `left_0`, `left_1` and `left_2`.
/// Pupils of the class beyond An and Bart, for a save of more than 30
/// cells: [_extraCount] of them, from [_firstExtra] on (Smartschool user
/// IDs; Skore's own is that plus 800000).
const _firstExtra = 1210;

/// The pupil rows of `init`, the same in `left_0`, `left_1` and `left_2`,
/// with [extra] pupils after An and Bart.
Map<String, Object?> _rows({int extra = 0}) {
  final pupils = [
    (_an, 'Aerts, An'),
    (_bart, 'Bosmans, Bart'),
    for (var i = 0; i < extra; i++) (_firstExtra + i, 'Leerling, Nummer$i'),
  ];
  return {
    'orientation': 'byColumn',
    'colHeader': {
      'sort': [0],
    },
    'stream': [
      for (final (i, (id, name)) in pupils.indexed)
        {
          'c': 0,
          'r': 'pupil_${id}_$_classId',
          'v': '<span>${i + 1}.  $name</span>',
        },
      {'c': 0, 'r': 'clavg_$_classId', 'v': '6EWI : Klasgemiddelde'},
    ],
  };
}

/// `init` with the page `1`: the project periods.
Map<String, Object?> _init(
  SkoreGradebook gradebook, {
  int classId = _classId,
  int extra = 0,
}) => {
  'left_0': _rows(extra: extra),
  'left_1': _rows(extra: extra),
  'left_2': _rows(extra: extra),
  'periods': [
    {
      'name': 'Proj',
      'fullname': 'Projecten digitaal',
      'id': '$_period',
      'info': '<p>Open</p>',
      'virtual': '0',
      'scope': '2',
      'open': 1,
      'timestamp': '2027-06-26T22:00:00+0200',
      'lockIcon': 0,
      'categoryMode': 1,
    },
  ],
  'reports': [
    {
      'name': 'R1D',
      'fullname': 'Rapport 1',
      'id': '2790',
      'info': '',
      'open': 1,
      'type': 'a',
      'rating': 0,
      'timestamp': '2026-10-30T23:00:00+0100',
      'lockIcon': 1,
    },
  ],
  'activePeriodE': -1,
  'activePeriodP': 0,
  'activeReport': 0,
  'projectAdmin': 1,
  'ownerMap': [
    {
      'courseID': '$_courseId',
      'groupID': '472',
      'coursename': 'Digitale vaardigheden',
      'ownerID': '${gradebook.gradebookId}',
      'classID': '$classId',
    },
  ],
  'wystring': '2026 - 2027',
  'isRestrictedAccess': 0,
};

/// A period of `init`'s `periods`: of [scope] `'1'` (an evaluation period)
/// or `'2'` (a project period), as seen live (#236).
Map<String, Object?> _initPeriod(int id, String name, {String scope = '1'}) => {
  'name': name,
  'fullname': name,
  'id': '$id',
  'info': '<p>Open</p>',
  'virtual': '0',
  'scope': scope,
  'open': 1,
  'timestamp': '2027-06-26T22:00:00+0200',
  'lockIcon': 0,
  'categoryMode': 1,
};

/// Two evaluation periods of a normal gradebook (#236).
const _dw1 = 1704;
const _dw2 = 1708;

/// `getGradebookContext` for project period [periodId].
Map<String, Object?> _context(
  SkoreGradebook gradebook,
  int periodId, {
  int classId = _classId,
}) => {
  'writable': 1,
  'coordinator': 0,
  'modelId': 176,
  'groupId': 472,
  'classId': classId,
  'periodId': periodId,
  'courses': [_courseId],
  'owners': [gradebook.gradebookId],
  'teacherId': gradebook.teacherId,
  'virtualId': 0,
  'restriction': gradebook.isShared ? gradebook.gradebookId : 0,
};

/// The template, as getTemplateList gives it.
Map<String, Object?> _templateJson() => {
  'creator': {'id': 4, 'name': 'Els', 'surname': 'Claes'},
  'info': 'Sjabloon digitale vaardigheden',
  'isComponentRequired': true,
  'isComponentForbidden': false,
  'isRatingAllowed': true,
  'isGradesAllowed': false,
  'isRubricsEnabled': false,
  'id': _template,
  'title': 'Digitale vaardigheden',
  'templateType': 1,
  'descr': 'Sjabloon digitale vaardigheden',
  'componentId': 6,
  'scale': {
    'ratings': [
      {
        'icon': '/icons/low.png',
        'iconBig': '/icons/low-big.png',
        'iconName': 'IconLib:low',
        'id': _low,
        'description': 'Niet behaald',
        'min': 0,
        'max': 49,
        'scaleValue': 30,
        'symbol': 'niv 1',
        'color': 'red',
      },
      {
        'icon': '/icons/high.png',
        'iconBig': '/icons/high-big.png',
        'iconName': 'IconLib:high',
        'id': _high,
        'description': 'Behaald',
        'min': 50,
        'max': 100,
        'scaleValue': 100,
        'symbol': 'niv 2',
        'color': 'green',
      },
    ],
    'id': 12,
    'description': 'D-V',
    'name': 'Digitale vaardigheden',
  },
};

/// The learning goals, as getCategoriesList gives them: the course's root,
/// a heading, a goal under it and a goal under that.
List<Object?> _goals() => [
  {
    'id': '-$_courseId',
    'enabled': false,
    'parentId': '0',
    'description': 'Digitale vaardigheden',
    'courseInstanceId': _courseId,
    'number': '',
    'isTitle': false,
    'isCourse': true,
    'level': 0,
  },
  {
    'id': '900100',
    'enabled': false,
    'parentId': '-$_courseId',
    'description': 'VAKGEBONDEN',
    'courseInstanceId': _courseId,
    'number': '',
    'isTitle': true,
    'isCourse': false,
    'level': 0,
  },
  {
    'id': '900101',
    'enabled': true,
    'parentId': '900100',
    'description': 'Je werkt samen in de cloud.',
    'courseInstanceId': _courseId,
    'number': 'LPD 1.1',
    'isTitle': false,
    'isCourse': false,
    'level': 1,
  },
  {
    'id': '900103',
    'enabled': false,
    'parentId': '900101',
    'description': 'Je kiest een bestandsformaat.',
    'courseInstanceId': _courseId,
    'number': 'LPD 1.1.2',
    'isTitle': false,
    'isCourse': false,
    'level': 2,
  },
  {
    'id': '900102',
    'enabled': true,
    'parentId': '900101',
    'description': 'Je deelt een bestand.',
    'courseInstanceId': _courseId,
    'number': 'LPD 1.1.1',
    'isTitle': false,
    'isCourse': false,
    'level': 2,
  },
];

/// The project, as getProjectList gives it.
Map<String, Object?> _projectJson({
  int periodId = _period,
  int templateId = _template,
  Object? publicDateTime,
}) => {
  'owners': [
    {'teacherId': _me, 'classId': _classId, 'courseId': _courseId},
  ],
  'evalType': 'ratings',
  'publicDateTime': publicDateTime,
  'maxNoRecalculation': false,
  'id': _project,
  'template': {..._templateJson(), 'id': templateId},
  'componentId': 6,
  'groupContext': false,
  'periodId': periodId,
  'inCount': true,
  'title': 'Cloudproject',
  'short': '',
  'date': '2026-10-30T00:00:00+0100',
  'max': 10.0,
  'isPublic': false,
};

/// A cell of getCategoryGradesByProject.
Map<String, Object?> _rating(
  int id,
  String goal,
  int userId,
  int skoreId, {
  int? ratingId = _high,
  int classId = _classId,
  int projectId = _project,
}) => {
  'options': <Object?>[],
  'projectId': projectId,
  'categoryId': goal,
  'grade': null,
  'ratingId': ratingId,
  'info': null,
  'id': id,
  'pupil': {
    'name': 'Voornaam',
    'surname': 'Achternaam',
    'sex': 'f',
    'classNumber': 1,
    'avatarHash': 'hash',
    'avatarUrl': '/avatar',
    'className': '6EWI',
    'classId': classId,
    'icon': 'woman3',
    'enabledCourses': <Object?>[],
    'enabled': 1,
    'id': skoreId,
    'userId': userId,
  },
};

List<Object?> _ratings() => [
  _rating(980001, '900101', _an, _skoreAn),
  _rating(980002, '900102', _an, _skoreAn, ratingId: _low),
  _rating(980003, '900101', _bart, _skoreBart),
  _rating(980004, '900101', _other, _skoreOther, classId: _otherClassId),
];

/// getNavigation of 2026-2027 with the class's project gradebook, the
/// teacher's.
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
              'crum': {
                'ids': ['176', '472', '$_classId'],
              },
              'data': [
                {
                  'coursename': _own.courseName,
                  'data': {
                    'ownerID': '${_own.gradebookId}',
                    'userID': '$_me',
                    'classID': '$_classId',
                    'groupID': '472',
                    'modelID': '176',
                    'courseID': '$_courseId',
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
  ],
  'currentWorkyear': '24',
};

/// accessableList: the colleague's project gradebook, shared with the
/// teacher, to write unless [writable] is 0.
List<Object?> _accessable({int writable = 1}) => [
  {
    'id': '${_colleague}_${_shared.gradebookId}',
    'userId': '$_colleague',
    'ownerId': '${_shared.gradebookId}',
    'courseId': '$_courseId',
    'writable': writable,
    'username': 'Piet Peeters',
    'classcourse': '6EWI/Digitale vaardigheden',
    'navigation': {
      'pathIds': ['176', '472', '$_classId'],
      'data': {
        'classID': '$_classId',
        'courseID': '$_courseId',
        'groupID': '472',
        'modelID': '176',
        'ownerID': '${_shared.gradebookId}',
        'userID': '$_colleague',
      },
    },
  },
];

/// getGradebookConfig, with the user's [rights].
Map<String, Object?> _config({Object? rights}) => {
  'templateFilter': <Object?>[],
  'usedFilter': 0,
  'metaOptions': <Object?>[],
  'components': [
    {'id': 6, 'name': 'Digitaal', 'short': 'DV'},
  ],
  'rights':
      rights ??
      {
        'readonly': false,
        'admin': false,
        'presence': {'$_classId': true},
      },
  'wySpecs': {
    'startDateTime': '2026-09-01 00:00:00',
    'endDateTime': '2027-08-31 23:59:59',
  },
};

/// A pupil as the project sheet's getPupilTree gives it: the keys of the
/// `pupil` of a rating, with the course in `enabledCourses` (seen live).
Map<String, Object?> _treePupil(
  int userId,
  int skoreId, {
  int classId = _classId,
  int enabled = 1,
  List<int> courses = const [_courseId],
}) => {
  'name': 'Voornaam',
  'surname': 'Achternaam',
  'sex': 'm',
  'classNumber': 1,
  'avatarHash': 'hash',
  'avatarUrl': '/avatar',
  'className': classId == _classId ? '6EWI' : '6WEWI',
  'classId': classId,
  'icon': 'user1',
  'enabledCourses': courses,
  'enabled': enabled,
  'id': skoreId,
  'userId': userId,
};

/// getPupilTree: the group with the class's pupils ([pupils]) and the other
/// class of the group.
List<Object?> _pupilTree(List<Map<String, Object?>> pupils) => [
  {
    'id': 472,
    'name': '6DO',
    'icon': 'group',
    'classes': [
      {'id': _classId, 'name': '6EWI', 'icon': 'class', 'pupils': pupils},
      {
        'id': _otherClassId,
        'name': '6WEWI',
        'icon': 'class',
        'pupils': [_treePupil(_other, _skoreOther, classId: _otherClassId)],
      },
    ],
  },
];

typedef _Rpc = ({
  String method,
  Map<String, dynamic> session,
  List<dynamic> params,
});

typedef _Post = ({String method, Map<String, String> fields});

typedef _Answer = ({int status, String body, String? type});

class _Skore implements HttpClientAdapter {
  _Skore({
    this.sheet = const {},
    this.contextClassId = _classId,
    this.writable = 1,
    this.sharedWritable = 1,
    this.periodOpen = 1,
    this.isPublic = false,
    this.publicDateTime,
    this.rights,
    this.forgetSave = false,
    this.saveAnswer,
    this.extra = 0,
    this.pupilTree,
    this.initPeriods,
    this.activePeriodE = 0,
    List<Object?>? ratings,
  }) : store = [
         for (final r in ratings ?? _ratings())
           jsonDecode(jsonEncode(r)) as Map<String, dynamic>,
       ];

  /// The `writable` of getGradebookContext.
  final int writable;

  /// The `periods` of init instead of the fixture's one project period,
  /// with [activePeriodE] (#236); `null` for the fixture's.
  final List<Map<String, Object?>>? initPeriods;

  /// The `activePeriodE` of init with [initPeriods].
  final int activePeriodE;

  /// The pupils of the class beyond An and Bart (see [_rows]).
  final int extra;

  /// The answer of getPupilTree; `null` for the class's pupils (An, Bart
  /// and the [extra] ones), all enabled, with the course.
  final Object? pupilTree;

  /// The `writable` of the shared gradebook in accessableList.
  final int sharedWritable;

  /// The `open` of the project period.
  final int periodOpen;

  /// The publication of the project in getProjectList.
  final bool isPublic;
  final Object? publicDateTime;

  /// The `rights` of getGradebookConfig (the fixture's when `null`).
  final Object? rights;

  /// Whether a saveCategoryGrades is answered as applied, but not kept.
  final bool forgetSave;

  /// The answer to the [call]th saveCategoryGrades (from 0), instead of
  /// applying it; `null` to apply it.
  final _Answer? Function(int call)? saveAnswer;

  /// The project's cells, as getCategoryGradesByProject gives them.
  final List<Map<String, dynamic>> store;

  /// The cells of each saveCategoryGrades, in order.
  final List<List<Map<String, dynamic>>> saves = [];

  var _nextId = 990001;

  /// Applies the cells of a saveCategoryGrades to [store], as Skore did
  /// live: a cell without an ID is made, with one; `ratingId` -1 clears the
  /// level, `info` "" the info. Returns the cells saved.
  List<Map<String, dynamic>> _apply(List<Map<String, dynamic>> cells) {
    final saved = <Map<String, dynamic>>[];
    for (final cell in cells) {
      final kept = Map<String, dynamic>.of(cell);
      if (kept['ratingId'] == -1) kept['ratingId'] = null;
      if (kept['info'] == '') kept['info'] = null;
      if (kept['id'] == null) {
        kept['id'] = _nextId++;
        if (!forgetSave) store.add(kept);
      } else if (!forgetSave) {
        final i = store.indexWhere((r) => r['id'] == kept['id']);
        store[i] = kept;
      }
      saved.add(kept);
    }
    return saved;
  }

  /// The answers of the project sheet by method; a method without one gets
  /// the fixture's answer.
  final Map<String, _Answer> sheet;

  /// The class getGradebookContext answers with.
  final int contextClassId;

  final List<_Rpc> rpcs = [];
  final List<_Post> posts = [];

  /// Every request, in order: an RPC call by its method, a request to the
  /// project sheet as `sheet:<method>`.
  final List<String> requests = [];

  SkoreGradebook _gradebookOf(Map<String, dynamic> session) =>
      session['restriction'] == _shared.gradebookId ? _shared : _own;

  _Answer _rpc(_Rpc call) {
    final gradebook = _gradebookOf(call.session);
    switch (call.method) {
      case 'getNavigation':
        return (
          status: 200,
          body: _answer('getNavigation', _navigation()),
          type: 'application/json',
        );
      case 'accessableList':
        return (
          status: 200,
          body: _answer(
            'accessableList',
            _accessable(writable: sharedWritable),
          ),
          type: 'application/json',
        );
      case 'init':
        final init = _init(gradebook, extra: extra);
        final periods = initPeriods;
        if (periods == null) {
          ((init['periods']! as List).single as Map)['open'] = periodOpen;
        } else {
          init['periods'] = periods;
          init['activePeriodE'] = activePeriodE;
          init['activePeriodP'] = periods.indexWhere((p) => p['scope'] == '2');
        }
        return (
          status: 200,
          body: _answer('init', init),
          type: 'application/json',
        );
      case 'getGradebookContext':
        return (
          status: 200,
          body: _answer('getGradebookContext', {
            ..._context(
              gradebook,
              call.params[4] as int,
              classId: contextClassId,
            ),
            'writable': writable,
          }),
          type: 'application/json',
        );
    }
    fail('Unexpected RPC call: ${call.method}');
  }

  _Answer _sheet(_Post post) {
    final answer = sheet[post.method];
    if (answer != null) return answer;
    if (post.method == 'saveCategoryGrades') {
      final cells = [
        for (final c in jsonDecode(post.fields['grades']!) as List)
          c as Map<String, dynamic>,
      ];
      saves.add(cells);
      final custom = saveAnswer?.call(saves.length - 1);
      if (custom != null) return custom;
      return (
        status: 200,
        body: jsonEncode(_apply(cells)),
        type: 'application/json',
      );
    }
    final Object json = switch (post.method) {
      'getTemplateList' => [_templateJson()],
      'getGradebookConfig' => _config(rights: rights),
      'getCategoriesList' => _goals(),
      'getProjectList' => [
        {..._projectJson(publicDateTime: publicDateTime), 'isPublic': isPublic},
      ],
      'getCategoryGradesByProject' => store,
      'getPupilTree' =>
        pupilTree ??
            _pupilTree([
              _treePupil(_an, _skoreAn),
              _treePupil(_bart, _skoreBart),
              for (var i = 0; i < extra; i++)
                _treePupil(_firstExtra + i, 800000 + _firstExtra + i),
            ]),
      _ => fail('Unexpected request to the project sheet: ${post.method}'),
    };
    return (status: 200, body: jsonEncode(json), type: 'application/json');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (options.method == 'GET' && path == '/') return _body(_startPage());
    if (options.method == 'GET' && path == '/course-list/api/v1/courses') {
      return _body('[{"platformId":4069}]', type: 'application/json');
    }
    if (options.method == 'POST' && path == _rpcPath) {
      final form = {
        for (final e in (options.data as Map).entries) '${e.key}': '${e.value}',
      };
      final call = (
        method: form['rpc_method']!,
        session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
        params: jsonDecode(form['rpc_params']!) as List<dynamic>,
      );
      rpcs.add(call);
      requests.add(call.method);
      final answer = _rpc(call);
      return _body(answer.body, status: answer.status, type: answer.type);
    }
    if (options.method == 'POST' && path.startsWith('$_sheetPath/')) {
      final post = (
        method: path.substring(_sheetPath.length + 1),
        fields: {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        },
      );
      posts.add(post);
      requests.add('sheet:${post.method}');
      final answer = _sheet(post);
      if (answer.status == 302) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
            'location': [answer.body],
          },
        );
      }
      return _body(answer.body, status: answer.status, type: answer.type);
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
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
  void close({bool force = false}) {}
}

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

  /// The template as getProjectTemplates reads it from the fixture.
  SkoreProjectTemplate template() =>
      SkoreGradebookService.parseProjectTemplates([_templateJson()]).single;

  /// The project as getProjects reads it from the fixture.
  SkoreProject project() => SkoreGradebookService.parseProjects(
    [_projectJson()],
    periodId: _period,
    templateId: _template,
  ).single;

  group('the project periods', () {
    test('getProjectPeriods sends init with the page 1 and reads its '
        'periods', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final periods = await gradebooks.getProjectPeriods(_own);

      expect(periods, hasLength(1));
      final p = periods.single;
      expect(
        (p.id, p.name, p.fullName),
        (_period, 'Proj', 'Projecten digitaal'),
      );
      expect(p.isOpen, isTrue);
      expect(p.categoryMode, 1);
      expect(p.closesAt, DateTime.utc(2027, 6, 26, 20));
      expect(server.requests, ['init']);
      final init = server.rpcs.single;
      expect(init.params, [
        ['$_courseId'],
        ['${_own.gradebookId}'],
        _me,
        ['176', '472', '$_classId'],
        1,
        0,
      ]);
      expect(init.session['teacher'], _me);
      expect(init.session['restriction'], 0);
      expect(init.session['wy'], '24');
    });

    test('a shared gradebook is read in the name of its teacher', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await gradebooks.getProjectPeriods(_shared);

      final init = server.rpcs.single;
      expect(init.params[2], _colleague);
      expect(init.params[5], _shared.gradebookId);
      expect(init.session['teacher'], _colleague);
      expect(init.session['restriction'], _shared.gradebookId);
    });

    // #236: init lists evaluation periods (scope 1) and project periods
    // (scope 2) in the same `periods`, whatever the page.
    test('getProjectPeriods of a normal gradebook: none, though init lists '
        'its evaluation periods (#236)', () async {
      final server = _Skore(
        initPeriods: [_initPeriod(_dw1, 'DW1'), _initPeriod(_dw2, 'DW2')],
        activePeriodE: 1,
      );
      final gradebooks = await serve(server);

      final periods = await gradebooks.getProjectPeriods(_own);

      expect(periods, isEmpty);
      expect(server.requests, ['init']);
    });

    test('getGradebook of a project gradebook: no evaluation periods and no '
        'active period, its project period in projectPeriods, and no '
        'getGradebookContext for it (#236)', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_own);

      expect(sheet.periods, isEmpty);
      expect(sheet.activePeriod, isNull);
      expect(sheet.writable, isFalse);
      expect(sheet.projectPeriods.map((p) => (p.id, p.scope, p.isProject)), [
        (_period, 2, true),
      ]);
      expect(sheet.pupils.map((p) => p.id), [_an, _bart]);
      expect(server.requests, ['init']);
      expect(server.rpcs.single.params[4], 0, reason: 'the page 0');
      // getProjectPeriods gives the same project periods.
      expect(
        (await gradebooks.getProjectPeriods(_own)).map((p) => p.id),
        sheet.projectPeriods.map((p) => p.id),
      );
    });

    test('getGradebook of a normal gradebook: its evaluation periods, the '
        'active one at activePeriodE, no project periods (#236)', () async {
      final server = _Skore(
        initPeriods: [_initPeriod(_dw1, 'DW1'), _initPeriod(_dw2, 'DW2')],
        activePeriodE: 1,
      );
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_own);

      expect(sheet.periods.map((p) => (p.id, p.isProject)), [
        (_dw1, false),
        (_dw2, false),
      ]);
      expect(sheet.activePeriod?.id, _dw2);
      expect(sheet.projectPeriods, isEmpty);
      expect(sheet.writable, isTrue);
      expect(server.requests, ['init', 'getGradebookContext']);
      expect(server.rpcs.last.params[4], _dw2);
    });

    test('a gradebook with both kinds (not seen live): each in its own list, '
        'activePeriodE an index in the evaluation periods (#236)', () async {
      final server = _Skore(
        initPeriods: [
          _initPeriod(_period, 'Proj', scope: '2'),
          _initPeriod(_dw1, 'DW1'),
        ],
      );
      final gradebooks = await serve(server);

      final sheet = await gradebooks.getGradebook(_own);
      final projectPeriods = await gradebooks.getProjectPeriods(_own);

      expect(sheet.periods.map((p) => p.id), [_dw1]);
      expect(sheet.activePeriod?.id, _dw1);
      expect(sheet.projectPeriods.map((p) => p.id), [_period]);
      expect(projectPeriods.map((p) => p.id), [_period]);
      expect(server.requests, ['init', 'getGradebookContext', 'init']);
      expect(server.rpcs[1].params[4], _dw1);
    });
  });

  group('the templates', () {
    test('getProjectTemplates reads the context, then getTemplateList with '
        'it, and reads each template with its scale', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final templates = await gradebooks.getProjectTemplates(_own, _period);

      expect(server.requests, ['getGradebookContext', 'sheet:getTemplateList']);
      expect(server.rpcs.single.params[4], _period);
      final post = server.posts.single;
      expect(post.fields.keys, ['context']);
      expect(jsonDecode(post.fields['context']!), _context(_own, _period));

      final t = templates.single;
      expect(t.id, _template);
      expect(t.title, 'Digitale vaardigheden');
      expect(t.description, 'Sjabloon digitale vaardigheden');
      expect(t.templateType, 1);
      expect(t.componentId, 6);
      expect(t.isRatingAllowed, isTrue);
      expect(t.isGradesAllowed, isFalse);
      expect(t.isRubricsEnabled, isFalse);
      expect(t.isComponentRequired, isTrue);
      expect(t.creatorId, 4);
      expect(t.json, _templateJson());
      final scale = t.scale!;
      expect((scale.id, scale.name), (12, 'Digitale vaardigheden'));
      expect(
        [for (final l in scale.levels) (l.id, l.description, l.symbol)],
        [(_low, 'Niet behaald', 'niv 1'), (_high, 'Behaald', 'niv 2')],
      );
      final high = scale.levelOf(_high)!;
      expect(
        (high.min, high.max, high.scaleValue, high.color),
        (50, 100, 100, 'green'),
      );
      expect(high.iconName, 'IconLib:high');
      expect(scale.levelOf(99), isNull);
      expect(scale.levelOf(null), isNull);
    });

    test('a template without a scale has none', () {
      final t = SkoreGradebookService.parseProjectTemplates([
        {..._templateJson(), 'scale': null, 'isRatingAllowed': false},
      ]).single;
      expect(t.scale, isNull);
      expect(t.isRatingAllowed, isFalse);
    });

    test('a period ID that is not positive is refused before anything is '
        'sent', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getProjectTemplates(_own, 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });

    test('a context about another class is refused, and the sheet is not '
        'asked', () async {
      final server = _Skore(contextClassId: _otherClassId);
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getProjectTemplates(_own, _period),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            contains('getGradebookContext for project period $_period'),
          ),
        ),
      );
      expect(server.requests, ['getGradebookContext']);
    });
  });

  group('the learning goals', () {
    test('getLearningGoals sends the template back as Skore gave it and '
        'reads the tree', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final goals = await gradebooks.getLearningGoals(
        _own,
        _period,
        template(),
      );

      expect(server.requests, [
        'getGradebookContext',
        'sheet:getCategoriesList',
      ]);
      final post = server.posts.single;
      expect(post.fields.keys, ['context', 'template']);
      expect(jsonDecode(post.fields['template']!), _templateJson());
      expect(jsonDecode(post.fields['context']!), _context(_own, _period));

      expect(
        [for (final g in goals) g.id],
        ['-$_courseId', '900100', '900101', '900103', '900102'],
      );
      expect(goals[3].isEnabled, isFalse);
      final root = goals.first;
      expect(root.parentId, isNull);
      expect(root.isCourse, isTrue);
      expect(root.isEnabled, isFalse);
      expect(goals[1].isTitle, isTrue);
      expect(goals[1].parentId, '-$_courseId');
      final leaf = goals.last;
      expect(leaf.parentId, '900101');
      expect(leaf.number, 'LPD 1.1.1');
      expect(leaf.description, 'Je deelt een bestand.');
      expect(leaf.level, 2);
      expect(leaf.isEnabled, isTrue);
      expect(leaf.courseId, _courseId);
    });

    test('a goal without its ID is refused', () {
      expect(
        () => SkoreGradebookService.parseLearningGoals([
          {...(_goals().last! as Map<String, Object?>), 'id': ''},
        ]),
        throwsA(isA<SmartschoolSkoreError>()),
      );
    });

    test('an answer that is not a list is refused', () {
      expect(
        () => SkoreGradebookService.parseLearningGoals({'error': 'x'}),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            contains('instead of a list'),
          ),
        ),
      );
    });
  });

  group('the projects', () {
    test(
      'getProjects sends the template back and reads each project',
      () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        final projects = await gradebooks.getProjects(
          _own,
          _period,
          template(),
        );

        expect(server.requests, [
          'getGradebookContext',
          'sheet:getProjectList',
        ]);
        expect(
          jsonDecode(server.posts.single.fields['template']!),
          _templateJson(),
        );
        final p = projects.single;
        expect(p.id, _project);
        expect(p.periodId, _period);
        expect(p.templateId, _template);
        expect(p.title, 'Cloudproject');
        expect(p.shortName, isNull);
        expect(p.date, DateTime(2026, 10, 30));
        expect(p.max, 10);
        expect(p.evalType, 'ratings');
        expect(p.isPublic, isFalse);
        expect(p.publicAt, isNull);
        expect(p.inCount, isTrue);
        expect(p.componentId, 6);
        expect(p.groupContext, isFalse);
        expect(p.json, _projectJson());
      },
    );

    test('a period without projects has none', () async {
      final server = _Skore(
        sheet: {
          'getProjectList': (status: 200, body: '[]', type: 'application/json'),
        },
      );
      final gradebooks = await serve(server);

      expect(await gradebooks.getProjects(_own, _period, template()), isEmpty);
    });

    test('a publication time is read in UTC', () {
      final p = SkoreGradebookService.parseProjects(
        [_projectJson(publicDateTime: '2026-11-03T08:00:00+0100')],
        periodId: _period,
        templateId: _template,
      ).single;
      expect(p.publicAt, DateTime.utc(2026, 11, 3, 7));
    });

    test('a project of another period or template is refused', () {
      for (final json in [
        _projectJson(periodId: _period + 1),
        _projectJson(templateId: _template + 1),
      ]) {
        expect(
          () => SkoreGradebookService.parseProjects(
            [json],
            periodId: _period,
            templateId: _template,
          ),
          throwsA(isA<SmartschoolSkoreError>()),
        );
      }
    });

    test('a date that is not a date is refused', () {
      expect(
        () => SkoreGradebookService.parseProjects(
          [
            {..._projectJson(), 'date': 'morgen'},
          ],
          periodId: _period,
          templateId: _template,
        ),
        throwsA(isA<SmartschoolSkoreError>()),
      );
    });
  });

  group('the ratings', () {
    test('getProjectRatings sends the project back and reads the ratings '
        'of the class', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final ratings = await gradebooks.getProjectRatings(_own, project());

      expect(server.requests, [
        'getGradebookContext',
        'sheet:getCategoryGradesByProject',
      ]);
      expect(server.rpcs.single.params[4], _period);
      final post = server.posts.single;
      expect(post.fields.keys, ['context', 'project']);
      expect(jsonDecode(post.fields['project']!), _projectJson());

      expect(
        [for (final r in ratings) (r.pupilId, r.learningGoalId, r.ratingId)],
        [
          (_an, '900101', _high),
          (_an, '900102', _low),
          (_bart, '900101', _high),
        ],
      );
      final first = ratings.first;
      expect(first.id, 980001);
      expect(first.projectId, _project);
      expect(first.skorePupilId, _skoreAn);
      expect(first.classId, _classId);
      expect(first.grade, isNull);
      expect(first.info, isNull);
      expect(template().scale!.levelOf(first.ratingId)!.description, 'Behaald');
    });

    test('a rating of another project is refused', () {
      expect(
        () => SkoreGradebookService.parseProjectRatings(
          [_rating(980001, '900101', _an, _skoreAn, projectId: _project + 1)],
          projectId: _project,
          classId: _classId,
        ),
        throwsA(isA<SmartschoolSkoreError>()),
      );
    });

    test('a rating without its pupil or learning goal is refused', () {
      for (final row in [
        {..._rating(980001, '900101', _an, _skoreAn), 'pupil': null},
        {..._rating(980001, '900101', _an, _skoreAn), 'categoryId': ''},
      ]) {
        expect(
          () => SkoreGradebookService.parseProjectRatings(
            [row],
            projectId: _project,
            classId: _classId,
          ),
          throwsA(isA<SmartschoolSkoreError>()),
        );
      }
    });

    test('a grade and info are kept as text', () {
      final r = SkoreGradebookService.parseProjectRatings(
        [
          {
            ..._rating(980001, '900101', _an, _skoreAn, ratingId: null),
            'grade': 7.5,
            'info': 'Goed gedaan.',
          },
        ],
        projectId: _project,
        classId: _classId,
      ).single;
      expect(r.ratingId, isNull);
      expect(r.grade, '7.5');
      expect(r.info, 'Goed gedaan.');
    });
  });

  group('the project sheet\'s answers', () {
    test('another status than 200 is a SmartschoolSkoreError that names '
        'the message', () async {
      final server = _Skore(
        sheet: {
          'getTemplateList': (
            status: 500,
            body: '{"message":"Er ging iets mis"}',
            type: 'application/json',
          ),
        },
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getProjectTemplates(_own, _period),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP 500'), contains('Er ging iets mis')),
          ),
        ),
      );
    });

    test('an HTML page is a SmartschoolSkoreError', () async {
      final server = _Skore(
        sheet: {
          'getProjectList': (
            status: 200,
            body: '<!DOCTYPE html><html><body>Oeps</body></html>',
            type: 'text/html',
          ),
        },
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getProjects(_own, _period, template()),
        throwsA(
          isA<SmartschoolSkoreError>().having(
            (e) => e.message,
            'message',
            contains('HTML page instead of JSON'),
          ),
        ),
      );
    });

    test('a redirect to the start page is Skore\'s refusal to the '
        'account', () async {
      final server = _Skore(
        sheet: {
          'getTemplateList': (
            status: 302,
            body: '/?module=Homepage',
            type: null,
          ),
        },
      );
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.getProjectTemplates(_own, _period),
        throwsA(
          isA<SmartschoolSkoreAccessDeniedError>().having(
            (e) => e.area,
            'area',
            SkoreAccessArea.gradebook,
          ),
        ),
      );
    });
  });

  group('only reads', () {
    test('projectMethods are the reads of the project sheet and its save '
        'of ratings', () {
      expect(SkoreGradebookService.projectMethods, {
        'getTemplateList',
        'getGradebookConfig',
        'getCategoriesList',
        'getProjectList',
        'getCategoryGradesByProject',
        'getPupilTree',
        'saveCategoryGrades',
      });
    });

    test('checkProjectMethod refuses the sheet\'s writes', () {
      for (final method in [
        'saveProject',
        'removeProject',
        'saveTemplateFilter',
        'registerUsedFilter',
      ]) {
        expect(
          () => SkoreGradebookService.checkProjectMethod(method),
          throwsA(isA<ArgumentError>()),
          reason: method,
        );
      }
      for (final method in SkoreGradebookService.projectMethods) {
        SkoreGradebookService.checkProjectMethod(method);
      }
    });
  });

  group('saving ratings', () {
    /// The requests of a save that passes its checks, with [saves] saves.
    List<String> saveRequests({int saves = 1}) => [
      'getNavigation', // the own gradebooks of the current school year
      'init', // the project period: one of the gradebook's, open
      'getGradebookContext', // writable
      'sheet:getProjectList', // the project as listed now
      'sheet:getGradebookConfig', // rights.readonly
      'sheet:getCategoriesList', // the learning goals
      'sheet:getCategoryGradesByProject', // the cells now
      'sheet:getPupilTree', // the pupils
      for (var i = 0; i < saves; i++) 'sheet:saveCategoryGrades',
      'sheet:getCategoryGradesByProject', // the check
    ];

    /// A [SmartschoolSkoreChangeRefusedError] of [operation] whose message
    /// holds [reason].
    Matcher refused(Object reason, {String operation = 'saveProjectRatings'}) =>
        isA<SmartschoolSkoreChangeRefusedError>()
            .having(
              (e) => e.message,
              'message',
              allOf(startsWith('$operation: '), contains(reason)),
            )
            .having(
              (e) => e.message,
              'message',
              endsWith('Nothing was saved.'),
            );

    test('changes a level, clears one and makes a new cell, in one '
        'saveCategoryGrades, and returns the cells as read again', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final saved = await gradebooks.saveProjectRatings(_own, project(), [
        const SkoreProjectRatingChange(
          pupilId: _an,
          learningGoalId: '900102',
          ratingId: _high,
        ),
        const SkoreProjectRatingChange.clear(
          pupilId: _bart,
          learningGoalId: '900101',
        ),
        const SkoreProjectRatingChange(
          pupilId: _bart,
          learningGoalId: '900102',
          ratingId: _low,
          info: '  Nog oefenen.  ',
        ),
      ]);

      expect(server.requests, saveRequests());
      final post = server.posts.firstWhere(
        (p) => p.method == 'saveCategoryGrades',
      );
      expect(post.fields.keys, ['context', 'grades']);
      expect(jsonDecode(post.fields['context']!), _context(_own, _period));
      final cells = server.saves.single;
      expect(cells, hasLength(3));
      // An existing cell goes out as Skore gave it, with the new level.
      expect(cells[0], {
        ...(_ratings()[1]! as Map<String, Object?>),
        'ratingId': _high,
      });
      // A clear sends -1, and keeps the cell's ID.
      expect(cells[1]['id'], 980003);
      expect(cells[1]['ratingId'], -1);
      // A new cell has no ID, and the pupil as the pupil tree gives it.
      expect(cells[2]['id'], isNull);
      expect(cells[2]['projectId'], _project);
      expect(cells[2]['categoryId'], '900102');
      expect(cells[2]['ratingId'], _low);
      expect(cells[2]['info'], 'Nog oefenen.');
      expect(cells[2]['grade'], isNull);
      expect(cells[2]['pupil'], _treePupil(_bart, _skoreBart));

      expect(
        [for (final r in saved) (r.pupilId, r.learningGoalId, r.ratingId)],
        [
          (_an, '900102', _high),
          (_bart, '900101', null),
          (_bart, '900102', _low),
        ],
      );
      expect(saved[2].id, 990001);
      expect(saved[2].info, 'Nog oefenen.');
    });

    test(
      'in a gradebook shared to write, in the name of its teacher',
      () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        final cell = await gradebooks.saveProjectRating(
          _shared,
          project(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900101',
            ratingId: _low,
          ),
        );

        expect(cell.ratingId, _low);
        expect(server.requests.take(2), ['getNavigation', 'accessableList']);
        final init = server.rpcs.firstWhere((r) => r.method == 'init');
        expect(init.session['teacher'], _colleague);
        expect(init.session['restriction'], _shared.gradebookId);
        final context = jsonDecode(
          server.posts
              .firstWhere((p) => p.method == 'saveCategoryGrades')
              .fields['context']!,
        );
        expect(context['teacherId'], _colleague);
        expect(context['restriction'], _shared.gradebookId);
      },
    );

    test(
      'a gradebook Skore now lists as shared to read only is refused',
      () async {
        final server = _Skore(sharedWritable: 0);
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveProjectRating(
            _shared,
            project(),
            const SkoreProjectRatingChange(
              pupilId: _an,
              learningGoalId: '900101',
              ratingId: _low,
            ),
          ),
          throwsA(isA<SmartschoolSkoreGradebookReadOnlyError>()),
        );
        expect(server.saves, isEmpty);
      },
    );

    test('a pupil\'s first rating in the project goes out with the pupil as '
        'the pupil tree gives it', () async {
      // Skore lists no cell of Bart in the project yet.
      final server = _Skore(ratings: [_ratings().first]);
      final gradebooks = await serve(server);

      final cell = await gradebooks.saveProjectRating(
        _own,
        project(),
        const SkoreProjectRatingChange(
          pupilId: _bart,
          learningGoalId: '900101',
          ratingId: _low,
        ),
      );

      final sent = server.saves.single.single;
      expect(sent['id'], isNull);
      expect(sent['pupil'], _treePupil(_bart, _skoreBart));
      expect(sent['ratingId'], _low);
      expect(
        (cell.id, cell.pupilId, cell.skorePupilId, cell.ratingId),
        (990001, _bart, _skoreBart, _low),
      );
    });

    test(
      'a pupil tree with empty enabledCourses lets the pupil be rated',
      () async {
        final server = _Skore(
          pupilTree: _pupilTree([
            _treePupil(_an, _skoreAn, courses: const []),
            _treePupil(_bart, _skoreBart),
          ]),
        );
        final gradebooks = await serve(server);

        final cell = await gradebooks.saveProjectRating(
          _own,
          project(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900101',
            ratingId: _low,
          ),
        );
        expect(cell.ratingId, _low);
      },
    );

    group('a malformed pupil tree is a SmartschoolSkoreError, nothing '
        'saved', () {
      for (final (name, tree) in [
        ('not a list', <String, Object?>{'groups': <Object?>[]}),
        (
          'a group without classes',
          [
            {'id': 472, 'name': '6DO'},
          ],
        ),
        (
          'a class without pupils',
          [
            {
              'id': 472,
              'classes': [
                {'id': _classId, 'name': '6EWI'},
              ],
            },
          ],
        ),
        (
          'a pupil without its user ID',
          _pupilTree([
            {..._treePupil(_an, _skoreAn), 'userId': null},
          ]),
        ),
      ]) {
        test(name, () async {
          final server = _Skore(pupilTree: tree);
          final gradebooks = await serve(server);

          await expectLater(
            gradebooks.saveProjectRating(
              _own,
              project(),
              const SkoreProjectRatingChange(
                pupilId: _an,
                learningGoalId: '900101',
                ratingId: _low,
              ),
            ),
            throwsA(
              allOf(
                isA<SmartschoolSkoreError>(),
                isNot(isA<SmartschoolSkoreChangeRefusedError>()),
                isA<SmartschoolSkoreError>().having(
                  (e) => e.message,
                  'message',
                  contains('pupil tree'),
                ),
              ),
            ),
          );
          expect(server.saves, isEmpty);
        });
      }
    });

    test('saveProjectRating saves one change and returns its cell', () async {
      final server = _Skore();
      final gradebooks = await serve(server);

      final cell = await gradebooks.saveProjectRating(
        _own,
        project(),
        const SkoreProjectRatingChange(
          pupilId: _an,
          learningGoalId: '900101',
          ratingId: _low,
          info: 'Goed geprobeerd.',
        ),
      );

      expect(
        (cell.id, cell.ratingId, cell.info),
        (980001, _low, 'Goed geprobeerd.'),
      );
      expect(server.saves.single.single['info'], 'Goed geprobeerd.');
    });

    test('info "" clears the info, null keeps it', () async {
      final ratings = _ratings();
      (ratings[0]! as Map<String, Object?>)['info'] = 'Oud.';
      (ratings[2]! as Map<String, Object?>)['info'] = 'Blijft.';
      final server = _Skore(ratings: ratings);
      final gradebooks = await serve(server);

      final saved = await gradebooks.saveProjectRatings(_own, project(), [
        const SkoreProjectRatingChange(
          pupilId: _an,
          learningGoalId: '900101',
          ratingId: _high,
          info: '',
        ),
        const SkoreProjectRatingChange(
          pupilId: _bart,
          learningGoalId: '900101',
          ratingId: _low,
        ),
      ]);

      expect([for (final c in server.saves.single) c['info']], ['', 'Blijft.']);
      expect([for (final r in saved) r.info], [null, 'Blijft.']);
    });

    test('more than 30 cells go out in requests of at most 30', () async {
      const extra = 16; // 18 pupils, 2 goals: 36 cells
      final pupils = [
        (_an, _skoreAn),
        (_bart, _skoreBart),
        for (var i = 0; i < extra; i++)
          (_firstExtra + i, 800000 + _firstExtra + i),
      ];
      final server = _Skore(
        extra: extra,
        ratings: [
          for (final (i, (id, skoreId)) in pupils.indexed)
            _rating(981000 + i, '900101', id, skoreId),
        ],
      );
      final gradebooks = await serve(server);

      final saved = await gradebooks.saveProjectRatings(_own, project(), [
        for (final (id, _) in pupils)
          for (final goal in ['900101', '900102'])
            SkoreProjectRatingChange(
              pupilId: id,
              learningGoalId: goal,
              ratingId: _high,
            ),
      ]);

      expect(SkoreGradebookService.projectRatingChunk, 30);
      expect(server.requests, saveRequests(saves: 2));
      expect([for (final s in server.saves) s.length], [30, 6]);
      expect(saved, hasLength(36));
      expect(saved.every((r) => r.ratingId == _high), isTrue);
    });

    test('a published project is refused without allowPublished, with the '
        'project as listed', () async {
      final server = _Skore(isPublic: true);
      final gradebooks = await serve(server);
      const change = SkoreProjectRatingChange(
        pupilId: _an,
        learningGoalId: '900101',
        ratingId: _low,
      );

      await expectLater(
        gradebooks.saveProjectRating(_own, project(), change),
        throwsA(
          isA<SmartschoolSkoreProjectPublishedError>()
              .having((e) => e.project.isPublic, 'project.isPublic', isTrue)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('published'), contains('allowPublished')),
              ),
        ),
      );
      expect(server.saves, isEmpty);

      final cell = await gradebooks.saveProjectRating(
        _own,
        project(),
        change,
        allowPublished: true,
      );
      expect(cell.ratingId, _low);
    });

    test('a scheduled project is refused too', () async {
      final server = _Skore(publicDateTime: '2027-01-10T08:00:00+0100');
      final gradebooks = await serve(server);

      await expectLater(
        gradebooks.saveProjectRating(
          _own,
          project(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900101',
            ratingId: _low,
          ),
        ),
        throwsA(
          isA<SmartschoolSkoreProjectPublishedError>().having(
            (e) => e.message,
            'message',
            contains('scheduled'),
          ),
        ),
      );
      expect(server.saves, isEmpty);
    });

    group('refused before anything is sent', () {
      for (final (name, change, reason) in [
        (
          'a pupil ID that is not positive',
          const SkoreProjectRatingChange(
            pupilId: 0,
            learningGoalId: '900101',
            ratingId: _low,
          ),
          '0 is not a pupil ID',
        ),
        (
          'a blank learning goal',
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: ' ',
            ratingId: _low,
          ),
          'is blank',
        ),
        (
          'a level ID that is not positive',
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900101',
            ratingId: -1,
          ),
          '-1 is not a level ID',
        ),
      ]) {
        test(name, () async {
          final server = _Skore();
          final gradebooks = await serve(server);

          await expectLater(
            gradebooks.saveProjectRatings(_own, project(), [change]),
            throwsA(refused(reason)),
          );
          expect(server.requests, isEmpty);
        });
      }

      test('two changes of the same pupil and goal', () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveProjectRatings(_own, project(), [
            const SkoreProjectRatingChange(
              pupilId: _an,
              learningGoalId: '900101',
              ratingId: _low,
            ),
            const SkoreProjectRatingChange.clear(
              pupilId: _an,
              learningGoalId: '900101',
            ),
          ]),
          throwsA(refused('has two changes of goal 900101')),
        );
        expect(server.requests, isEmpty);
      });

      test('a gradebook shared to read only', () async {
        final server = _Skore();
        final gradebooks = await serve(server);
        const readOnly = SkoreGradebook(
          gradebookId: 34991,
          teacherId: _colleague,
          modelId: 176,
          modelName: '',
          groupId: 472,
          groupName: '',
          classId: _classId,
          className: '6EWI',
          courseId: _courseId,
          courseName: 'Digitale vaardigheden',
          workyearId: 24,
          access: SkoreGradebookAccess.read,
          ownerName: 'Piet Peeters',
        );

        await expectLater(
          gradebooks.saveProjectRating(
            readOnly,
            project(),
            const SkoreProjectRatingChange(
              pupilId: _an,
              learningGoalId: '900101',
              ratingId: _low,
            ),
          ),
          throwsA(isA<SmartschoolSkoreGradebookReadOnlyError>()),
        );
        expect(server.requests, isEmpty);
      });
    });

    group('refused after reading Skore again, nothing saved', () {
      const ok = SkoreProjectRatingChange(
        pupilId: _an,
        learningGoalId: '900101',
        ratingId: _low,
      );
      for (final (name, server, change, reason) in [
        (
          'a gradebook Skore shows read-only (writable 0)',
          () => _Skore(writable: 0),
          ok,
          'read-only to you in project period',
        ),
        (
          'a project sheet read-only to the user (rights.readonly)',
          () => _Skore(rights: {'readonly': true}),
          ok,
          'project sheet of template $_template read-only',
        ),
        (
          'a project sheet without rights',
          () => _Skore(rights: <String, Object?>{}),
          ok,
          'read-only',
        ),
        (
          'a closed project period',
          () => _Skore(periodOpen: 0),
          ok,
          'is closed',
        ),
        (
          'a period Skore lists as an evaluation period (scope 1, #236)',
          () => _Skore(initPeriods: [_initPeriod(_period, 'Proj')]),
          ok,
          'project period $_period is not one of gradebook',
        ),
        (
          'a level that is not one of the scale',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900101',
            ratingId: 99,
          ),
          'level 99 is not one of the scale',
        ),
        (
          'a learning goal of another template',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '123',
            ratingId: _low,
          ),
          'learning goal 123 is not one of template',
        ),
        (
          'a heading',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900100',
            ratingId: _low,
          ),
          'a heading',
        ),
        (
          'the course\'s root',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '-$_courseId',
            ratingId: _low,
          ),
          'the course\'s root',
        ),
        (
          'a goal that is not enabled',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _an,
            learningGoalId: '900103',
            ratingId: _low,
          ),
          'not enabled',
        ),
        (
          'a pupil of another class',
          () => _Skore(),
          const SkoreProjectRatingChange(
            pupilId: _other,
            learningGoalId: '900101',
            ratingId: _low,
          ),
          'pupil $_other is not one of class $_classId',
        ),
        (
          'a clear of a rating the pupil does not have',
          () => _Skore(),
          const SkoreProjectRatingChange.clear(
            pupilId: _bart,
            learningGoalId: '900102',
          ),
          'has no rating of goal 900102 to clear',
        ),
        (
          'a pupil missing from the pupil tree',
          () => _Skore(pupilTree: _pupilTree([_treePupil(_an, _skoreAn)])),
          const SkoreProjectRatingChange(
            pupilId: _bart,
            learningGoalId: '900101',
            ratingId: _low,
          ),
          'pupil $_bart is not one of class $_classId in the project',
        ),
        (
          'a pupil the pupil tree shows disabled',
          () => _Skore(
            pupilTree: _pupilTree([
              _treePupil(_an, _skoreAn),
              _treePupil(_bart, _skoreBart, enabled: 0),
            ]),
          ),
          const SkoreProjectRatingChange(
            pupilId: _bart,
            learningGoalId: '900101',
            ratingId: _low,
          ),
          'pupil $_bart is not enabled',
        ),
        (
          'a pupil who does not take the course',
          () => _Skore(
            pupilTree: _pupilTree([
              _treePupil(_an, _skoreAn),
              _treePupil(_bart, _skoreBart, courses: [_courseId + 1]),
            ]),
          ),
          const SkoreProjectRatingChange(
            pupilId: _bart,
            learningGoalId: '900101',
            ratingId: _low,
          ),
          'pupil $_bart does not take course $_courseId',
        ),
      ]) {
        test(name, () async {
          final fake = server();
          final gradebooks = await serve(fake);

          await expectLater(
            gradebooks.saveProjectRatings(_own, project(), [change]),
            throwsA(refused(reason)),
          );
          expect(fake.saves, isEmpty);
          expect(
            fake.requests.where((r) => r == 'sheet:saveCategoryGrades'),
            isEmpty,
          );
        });
      }

      test('one refused change saves none', () async {
        final server = _Skore();
        final gradebooks = await serve(server);

        await expectLater(
          gradebooks.saveProjectRatings(_own, project(), [
            ok,
            const SkoreProjectRatingChange(
              pupilId: _bart,
              learningGoalId: '900100',
              ratingId: _low,
            ),
          ]),
          throwsA(refused('a heading')),
        );
        expect(server.saves, isEmpty);
      });
    });

    group('unconfirmed', () {
      test('a save Skore answers but does not keep', () async {
        final server = _Skore(forgetSave: true);
        final gradebooks = await serve(server);
        const change = SkoreProjectRatingChange(
          pupilId: _an,
          learningGoalId: '900102',
          ratingId: _high,
        );

        await expectLater(
          gradebooks.saveProjectRatings(_own, project(), [change]),
          throwsA(
            allOf(
              isNot(isA<SmartschoolSkoreError>()),
              isA<SmartschoolSkoreSaveUnconfirmedError>(),
              isA<SmartschoolSkoreProjectRatingSaveUnconfirmedError>()
                  .having((e) => e.gradebookId, 'gradebookId', _own.gradebookId)
                  .having((e) => e.projectId, 'projectId', _project)
                  .having((e) => e.changes, 'changes', [change])
                  .having((e) => e.confirmed, 'confirmed', isEmpty)
                  .having(
                    (e) => e.unconfirmed[change],
                    'unconfirmed',
                    contains('shows level $_low'),
                  )
                  .having(
                    (e) => e.message,
                    'message',
                    contains('Saving a rating again is harmless'),
                  ),
            ),
          ),
        );
      });

      test('a failed request leaves its cells unconfirmed, the others are '
          'confirmed', () async {
        const extra = 15; // 17 pupils, 2 goals: 34 cells
        final pupils = [
          (_an, _skoreAn),
          (_bart, _skoreBart),
          for (var i = 0; i < extra; i++)
            (_firstExtra + i, 800000 + _firstExtra + i),
        ];
        final server = _Skore(
          extra: extra,
          ratings: [
            for (final (i, (id, skoreId)) in pupils.indexed)
              _rating(981000 + i, '900101', id, skoreId),
          ],
          saveAnswer: (call) => call == 0
              ? (
                  status: 500,
                  body: '{"message":"Er ging iets mis"}',
                  type: 'application/json',
                )
              : null,
        );
        final gradebooks = await serve(server);
        final changes = [
          for (final (id, _) in pupils)
            for (final goal in ['900101', '900102'])
              SkoreProjectRatingChange(
                pupilId: id,
                learningGoalId: goal,
                ratingId: _low,
              ),
        ];

        await expectLater(
          gradebooks.saveProjectRatings(_own, project(), changes),
          throwsA(
            isA<SmartschoolSkoreProjectRatingSaveUnconfirmedError>()
                .having((e) => e.unconfirmed.length, 'unconfirmed', 30)
                .having((e) => e.confirmed.length, 'confirmed', 4)
                .having((e) => e.cause, 'cause', isA<SmartschoolSkoreError>())
                .having(
                  (e) => e.unconfirmed[changes.first],
                  'first',
                  contains('no usable answer came in'),
                ),
          ),
        );
        expect([for (final s in server.saves) s.length], [30, 4]);
      });
    });
  });
}
