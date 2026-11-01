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
Map<String, Object?> _rows() => {
  'orientation': 'byColumn',
  'rowHeader': {
    'sort': [
      'pupil_${_an}_$_classId',
      'pupil_${_bart}_$_classId',
      'clavg_$_classId',
    ],
    'styles': [null, null, null],
    'classes': [null, null, null],
  },
  'colHeader': {
    'sort': [0],
  },
  'stream': [
    {'c': 0, 'r': 'pupil_${_an}_$_classId', 'v': '<span>1.  Aerts, An</span>'},
    {
      'c': 0,
      'r': 'pupil_${_bart}_$_classId',
      'v': '<span>2.  Bosmans, Bart</span>',
    },
    {'c': 0, 'r': 'clavg_$_classId', 'v': '6EWI : Klasgemiddelde'},
  ],
};

/// `init` with the page `1`: the project periods.
Map<String, Object?> _init(
  SkoreGradebook gradebook, {
  int classId = _classId,
}) => {
  'left_0': _rows(),
  'left_1': _rows(),
  'left_2': _rows(),
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

typedef _Rpc = ({
  String method,
  Map<String, dynamic> session,
  List<dynamic> params,
});

typedef _Post = ({String method, Map<String, String> fields});

typedef _Answer = ({int status, String body, String? type});

class _Skore implements HttpClientAdapter {
  _Skore({this.sheet = const {}, this.contextClassId = _classId});

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
      case 'init':
        return (
          status: 200,
          body: _answer('init', _init(gradebook)),
          type: 'application/json',
        );
      case 'getGradebookContext':
        return (
          status: 200,
          body: _answer(
            'getGradebookContext',
            _context(gradebook, call.params[4] as int, classId: contextClassId),
          ),
          type: 'application/json',
        );
    }
    fail('Unexpected RPC call: ${call.method}');
  }

  _Answer _sheet(_Post post) {
    final answer = sheet[post.method];
    if (answer != null) return answer;
    final Object json = switch (post.method) {
      'getTemplateList' => [_templateJson()],
      'getCategoriesList' => _goals(),
      'getProjectList' => [_projectJson()],
      'getCategoryGradesByProject' => _ratings(),
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
        ['-$_courseId', '900100', '900101', '900102'],
      );
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
    test('projectMethods are the four reads of the project sheet', () {
      expect(SkoreGradebookService.projectMethods, {
        'getTemplateList',
        'getCategoriesList',
        'getProjectList',
        'getCategoryGradesByProject',
      });
    });

    test('checkProjectMethod refuses the sheet\'s writes', () {
      for (final method in [
        'saveCategoryGrades',
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
}
