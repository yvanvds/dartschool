// Tests for issue #149: reading, as the logged-in teacher, the evaluations
// of a period of a gradebook (`SkoreGradebookService.getEvaluations`), with
// whether and when each is published, the grades of the gradebook's pupils
// (`getResults`) and their feedback (`getFeedback`).
//
// The evaluations come from Skore's gradebook RPC service
// (/modules/Skore/backend/gradebook/rpc.php):
//   getEvaluations(periodID, userID, courses, groupID, classID, pathIds)
// and the feedback from Skore's REST API, as the feedback panel of
// /SkoreGradebook reads it:
//   GET /skore/api/v1/gradebook/feedback/{ss}_{refID}/student/
//       {ss}_{pupilId}_0/class/{ss}_{classId}/teacher/{ss}_{userId}_0/
//       context/{modelId}_{groupId}_{classId}
//
// The answers below have the shape of live captures (read-only, 2026-10-08)
// of the developer's gradebook of 6EWI (32508, period DW1 1704): an
// evaluation with grades, feedback and a publication scheduled for the next
// morning, and a new evaluation that is not published (`public` "0",
// `publicdatetime` ""), with empty cells, one of them with feedback (seen
// live: feedback without a grade). Pupils, teachers, texts, evaluation IDs
// and the base64 in the tooltips are fakes; class, group, model, course,
// gradebook and period IDs are Skore's own, as in
// skore_gradebook_service_test.dart. Seen live and kept here:
//   - the stream holds the rows of the other classes of the group (6WEWI1,
//     6WEWI2), with another owner and `p` [1, 0, 0, "<owner>", -1], and a
//     `div.gbc` without `raw`;
//   - a grade's `raw` has a decimal point, its text a decimal comma;
//   - the feedback marker is the class `gbc_message` with a `tooltip` after
//     `skoretooltip="true"`, which joins all feedback of a pupil with ", ";
//   - the REST feedback list keeps them apart, in the order they were
//     written.
//
// Nothing here reaches Skore: the fake Smartschool fails the test on any
// other RPC method than getEvaluations, and on any other request than the
// reads of the current user and the feedback GET.
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
const _feedbackApi = '/skore/api/v1/gradebook/feedback/';

/// The logged-in teacher (a fake user ID), on platform 4069.
const _me = 1005;

/// Smartschool's start page, where the client reads the logged-in user,
/// whose ID is [userId].
String _startPage([String userId = '4069_${_me}_0']) =>
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"$userId","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// The evaluation that is published from 2026-10-09 08:00 (Belgian time), in
/// column B: grades 79, 15.5 and none; feedback for the first two pupils.
const _scheduledId = 500001;

/// The new evaluation, not published, in column A: no grades; feedback for
/// the second pupil.
const _newId = 500002;

/// When the scheduled evaluation is published: 2026-10-09 08:00 in Belgium
/// (CEST, UTC+2).
final _publishedFrom = DateTime.utc(2026, 10, 9, 6);

/// The time of the captures: the day before.
final _captured = DateTime.utc(2026, 10, 8, 10);

/// Skore's answer to getEvaluations for 6EWI's period DW1 (see the top of
/// the file).
const _evaluationsAnswer = r'''
{"result":{"head":[{"formula":"","title":"Toets 1","short":null,"date":"2026-10-08","componentID":2,"component":"DW","periodID":1704,"courseID":"2264","coursename":"Informaticawetenschappen (2 uur)","public":"0","publicdatetime":"","max":20,"catID":null,"catDescr":null,"etodID":"","refID":"500002","colID":"A","evaltype":1,"evaluationID":"500002","cumulate":"","cumulateGlobal":"","projectID":"","color":"#ffffff","virtual":"0","contentType":"","contentTypeName":"","ownerID":"32508","externeUuid":"","isPlannerEval":0,"plaId":"","pleType":"","realCourseID":2264,"posComps":[[0,"geen"],["2","DW"]],"groupID":472},{"formula":"","title":"Python scripts schrijven","short":"toets-python","date":"2026-09-30","componentID":2,"component":"DW","periodID":1704,"courseID":"2264","coursename":"Informaticawetenschappen (2 uur)","public":"1","publicdatetime":"2026-10-09T08:00:00","max":100,"catID":null,"catDescr":null,"etodID":"","refID":"500001","colID":"B","evaltype":1,"evaluationID":"500001","cumulate":"","cumulateGlobal":"","projectID":"","color":"#ffffff","virtual":"0","contentType":"","contentTypeName":"","ownerID":"32508","externeUuid":"","isPlannerEval":0,"plaId":"","pleType":"","realCourseID":2264,"posComps":[[0,"geen"],["2","DW"]],"groupID":472}],"max":{"orientation":"byColumn","rowHeader":{"sort":[0],"styles":["background:#eeeeee;"]},"colHeader":{"sort":["500002","500001"]},"stream":[{"c":"500001","r":0,"v":[100,"500001","B",1,"","","","1"],"w":"maxcell"},{"c":"500002","r":0,"v":[20,"500002","A",1,"","","","0"],"w":"maxcell"}]},"details":{"orientation":"byColumn","rowHeader":{"sort":[]},"colHeader":{"sort":[]},"stream":[{"c":"500001","r":"pupil_1201_2440","v":"<div class=\"gbc\" raw=\"79\">79</div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place gbc_message\" skoretooltip=\"true\" tooltip=\"PHVsIHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQ7bWFyZ2luOjBweDtwYWRkaW5nOjEycHg7Ij48bGk+R29lZCBnZXdlcmt0LCBnYSB6byBkb29yLjwvbGk+PC91bD4=\" encoding=\"base64\">&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500001","32508",500001]},{"c":"500001","r":"pupil_1202_2440","v":"<div class=\"gbc\" raw=\"15.5\">15,5</div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place gbc_message\" skoretooltip=\"true\" tooltip=\"PHVsIHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQ7bWFyZ2luOjBweDtwYWRkaW5nOjEycHg7Ij48bGk+RWVyc3RlIG9wbWVya2luZy4sIFR3ZWVkZSBvcG1lcmtpbmcuPC9saT48L3VsPg==\" encoding=\"base64\">&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500001","32508",500001]},{"c":"500001","r":"pupil_1203_2440","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500001","32508",500001]},{"c":"500001","r":"clavg_2440","v":"<div class=\"gbc\" raw=\"47.3\">47,3</div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[0]},{"c":"500001","r":"gravg_472","v":"<div class=\"gbc\" raw=\"47.3\">47,3</div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[0]},{"c":"500002","r":"pupil_1201_2440","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500002","32508",500002]},{"c":"500002","r":"pupil_1202_2440","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place gbc_message\" skoretooltip=\"true\" tooltip=\"PHVsIHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQ7bWFyZ2luOjBweDtwYWRkaW5nOjEycHg7Ij48bGk+RmVlZGJhY2sgem9uZGVyIGNpamZlci48L2xpPjwvdWw+\" encoding=\"base64\">&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500002","32508",500002]},{"c":"500002","r":"pupil_1203_2440","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,"500002","32508",500002]},{"c":"500002","r":"clavg_2440","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[0]},{"c":"500002","r":"gravg_472","v":"<div class=\"gbc\" raw=\"\"></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[0]},{"c":"500001","r":"pupil_1401_2442","v":"<div class=\"gbc\" ></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,0,"32506",-1]},{"c":"500001","r":"pupil_1501_2444","v":"<div class=\"gbc\" ></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence am_red pm_red\"><div></div><div></div></div>","p":[1,0,0,"32504",-1]},{"c":"500002","r":"pupil_1401_2442","v":"<div class=\"gbc\" ></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence \"><div></div><div></div></div>","p":[1,0,0,"32506",-1]},{"c":"500002","r":"pupil_1501_2444","v":"<div class=\"gbc\" ></div><div class=\"gbc_cell_header\"><span onmousedown=\"skore.gbc.onCellMessage();\" class=\"gbc_message_place\" >&nbsp;&nbsp;</span></div><div class=\"gbc_presence am_red pm_red\"><div></div><div></div></div>","p":[1,0,0,"32504",-1]}]},"periodStatus":1,"evalType":1,"archive":[]},"session":1,"method":"getEvaluations","timelimit":0,"limitInfo":null}''';

/// Skore's answer to getEvaluations for a period without evaluations (seen
/// live, 2025-2026): an empty `head`, and the stream `1`.
const _emptyPeriodAnswer = r'''
{"result":{"head":[],"max":{"orientation":"byColumn","rowHeader":{"sort":[0],"styles":["background:#eeeeee;"]},"colHeader":{"sort":[]},"stream":1},"details":{"orientation":"byColumn","rowHeader":{"sort":[]},"colHeader":{"sort":[]},"stream":1},"periodStatus":1,"evalType":1,"archive":[]},"session":1,"method":"getEvaluations","timelimit":0,"limitInfo":null}''';

/// The REST feedback of pupil 1202 on the scheduled evaluation: two, from
/// two teachers, in the order they were written.
const _twoFeedback = r'''
[{"id":"00000000-0000-4000-8000-000000000001","evaluationId":"4069_500001","student":{"id":"4069_1202_0","name":{"startingWithFirstName":"Bart Claes","startingWithLastName":"Claes Bart"},"pictureHash":"fake","pictureUrl":"/smsc/img/fake/initials_BC.png","sort":"claes bart","deleted":false},"teacher":{"id":"4069_1005_0","name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"pictureHash":"fake","pictureUrl":"/smsc/img/fake/initials_JJ.png","sort":"janssens jan","deleted":false},"text":"Eerste opmerking.","createdAt":"2026-10-08T09:49:36+02:00","changedAt":"2026-10-08T09:49:36+02:00","attachments":[],"capabilities":{"can_read":true,"can_edit":true}},
 {"id":"00000000-0000-4000-8000-000000000002","evaluationId":"4069_500001","student":{"id":"4069_1202_0","name":{"startingWithFirstName":"Bart Claes","startingWithLastName":"Claes Bart"},"pictureHash":"fake","pictureUrl":"/smsc/img/fake/initials_BC.png","sort":"claes bart","deleted":false},"teacher":{"id":"4069_1006_0","name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"pictureHash":"fake","pictureUrl":"/smsc/img/fake/initials_PP.png","sort":"peeters piet","deleted":false},"text":"Tweede opmerking.","createdAt":"2026-10-08T10:02:11+02:00","changedAt":"2026-10-08T10:15:00+02:00","attachments":[{"id":"att-1","name":"verbetering.pdf","type":"OTHER","size":1234,"downloadUrl":"/fake/download"}],"capabilities":{"can_read":true,"can_edit":false}}]''';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// An RPC call as it reached the fake Smartschool.
typedef _Call = ({
  String method,
  List<dynamic> params,
  Map<String, dynamic> session,
  Map<String, String> form,
});

/// A Smartschool whose Skore gradebook answers getEvaluations with
/// [evaluations], and the feedback GET of a path with [feedback] (`[]` for
/// a path it has none for).
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    _Answer? evaluations,
    this.feedback = const {},
    this.userId = '4069_${_me}_0',
  }) : evaluations = [evaluations ?? _ok(_evaluationsAnswer)];

  /// The answers to getEvaluations, one per call; the last one repeats.
  final List<_Answer> evaluations;
  final Map<String, _Answer> feedback;
  final String userId;

  /// Every RPC call that reached it, in order.
  final List<_Call> calls = [];

  /// Every request that reached it, as `METHOD path` (`RPC <method>` for an
  /// RPC call).
  final List<String> requests = [];

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
        return _body(_startPage(userId));
      case ('GET', '/course-list/api/v1/courses'):
        requests.add('GET $path');
        return _body('[{"platformId":4069}]', type: 'application/json');
      case ('GET', _) when path.startsWith(_feedbackApi):
        requests.add('GET $path');
        final answer = feedback[path] ?? _ok('[]');
        return _body(
          answer.body,
          status: answer.status,
          type: 'application/json',
        );
      case ('POST', _rpcPath):
        final form = {
          for (final e in (options.data as Map).entries)
            '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Never let anything else through: only the read of #149.
        expect(SkoreGradebookService.rpcMethods, contains(method));
        expect(method, 'getEvaluations');
        calls.add((
          method: method,
          params: jsonDecode(form['rpc_params']!) as List<dynamic>,
          session: jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>,
          form: form,
        ));
        requests.add('RPC $method');
        final answer = evaluations.length > 1
            ? evaluations.removeAt(0)
            : evaluations.single;
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

/// A plain [SmartschoolSkoreError]: an answer the service cannot use.
Matcher _skoreError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// The `result` of [answer], an RPC answer above.
Map<String, dynamic> _result([String answer = _evaluationsAnswer]) =>
    (jsonDecode(answer) as Map<String, dynamic>)['result']
        as Map<String, dynamic>;

/// The `result` of getEvaluations with its `head` entry [index] changed by
/// [change].
Map<String, dynamic> _withHead(
  int index,
  void Function(Map<String, dynamic> entry) change,
) {
  final result = _result();
  change((result['head'] as List)[index] as Map<String, dynamic>);
  return result;
}

/// The `result` of getEvaluations with [cells] in front of its stream.
Map<String, dynamic> _withCells(List<Object?> cells) {
  final result = _result();
  final details = result['details'] as Map<String, dynamic>;
  details['stream'] = [...cells, ...details['stream'] as List];
  return result;
}

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
  teacherNames: ['Janssens Jan'],
);

/// 6WEWI2's gradebook, in the same group.
const _wewi2 = SkoreGradebook(
  gradebookId: 32504,
  teacherId: _me,
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

List<SkoreEvaluation> _parse(Object? result, {DateTime? now}) =>
    SkoreGradebookService.parseEvaluations(
      result,
      _ewi,
      1704,
      now: now ?? _captured,
    );

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SkoreGradebookService)> serve({
    _Answer? evaluations,
    Map<String, _Answer> feedback = const {},
    String userId = '4069_${_me}_0',
    DateTime Function()? clock,
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(
      evaluations: evaluations,
      feedback: feedback,
      userId: userId,
    );
    client.dio.httpClientAdapter = server;
    return (
      server,
      SkoreGradebookService(client, clock: clock ?? () => _captured),
    );
  }

  // ---------------------------------------------------------------------------
  // The evaluations of a period
  // ---------------------------------------------------------------------------

  group('SkoreGradebookService.parseEvaluations', () {
    late List<SkoreEvaluation> evaluations;
    setUpAll(() => evaluations = _parse(_result()));

    test("the gradebook's evaluations, in Skore's order, by refID", () {
      expect(evaluations.map((e) => e.id), [_newId, _scheduledId]);
      expect(evaluations.map((e) => e.column), ['A', 'B']);

      final scheduled = evaluations.last;
      expect(scheduled.evaluationId, _scheduledId);
      expect(scheduled.gradebookId, 32508);
      expect(scheduled.periodId, 1704);
      expect(scheduled.title, 'Python scripts schrijven');
      expect(scheduled.shortName, 'toets-python');
      expect(scheduled.date, DateTime(2026, 9, 30));
      expect(scheduled.max, 100);
      expect(scheduled.componentId, 2);
      expect(scheduled.componentName, 'DW');
      expect(scheduled.type, SkoreEvaluationType.points);
      expect(scheduled.typeCode, 1);
      expect(scheduled.courseId, 2264);
      expect(scheduled.courseName, 'Informaticawetenschappen (2 uur)');
      expect(scheduled.isPlannerEvaluation, isFalse);

      final fresh = evaluations.first;
      expect(fresh.title, 'Toets 1');
      expect(fresh.shortName, isNull); // `null`
      expect(fresh.date, DateTime(2026, 10, 8));
      expect(fresh.max, 20);
    });

    test('the publication: scheduled until its time, and not published', () {
      final scheduled = evaluations.last.publication;
      expect(scheduled.state, SkorePublicationState.scheduled);
      expect(scheduled.isPublic, isTrue);
      expect(scheduled.at, _publishedFrom);
      expect(scheduled.at!.isUtc, isTrue);
      expect(scheduled.rawPublic, '1');
      expect(scheduled.rawPublicDateTime, '2026-10-09T08:00:00');

      final fresh = evaluations.first.publication;
      expect(fresh.state, SkorePublicationState.notPublished);
      expect(fresh.isPublic, isFalse);
      expect(fresh.at, isNull);
      expect(fresh.rawPublic, '0');
      expect(fresh.rawPublicDateTime, '');
    });

    test('the state is that at the time given', () {
      for (final (now, state) in [
        (_publishedFrom.subtract(const Duration(seconds: 1)), 'scheduled'),
        (_publishedFrom, 'published'),
        (DateTime.utc(2026, 11, 1), 'published'),
      ]) {
        expect(
          _parse(_result(), now: now).last.publication.state.name,
          state,
          reason: '$now',
        );
      }
      // And for any time afterwards, without reading again.
      final scheduled = evaluations.last.publication;
      expect(
        scheduled.stateAt(DateTime.utc(2026, 10, 9, 7)),
        SkorePublicationState.published,
      );
      expect(
        evaluations.first.publication.stateAt(DateTime.utc(2030)),
        SkorePublicationState.notPublished,
      );
    });

    test('the grades of the pupils of the class, as Skore stores them', () {
      final results = evaluations.last.results;
      expect(results.evaluationId, _scheduledId);
      expect(results.grades.map((g) => g.pupilId), [1201, 1202, 1203]);
      expect(results.grades.map((g) => g.classId), everyElement(2440));
      // The raw value with its decimal point (Skore shows "15,5"), and none.
      expect(results.grades.map((g) => g.grade), ['79', '15.5', null]);
      expect(results.grades.map((g) => g.value), [79.0, 15.5, null]);
      expect(results.grades.map((g) => g.hasFeedback), [true, true, false]);
      expect(results.grades.map((g) => g.categoryType), everyElement(0));
      expect(
        results.grades.map((g) => g.cellEvaluationId),
        everyElement(_scheduledId),
      );
      expect(results.grades.first.rowKey, 'pupil_1201_2440');
      expect(results.gradeOf(1202)?.grade, '15.5');
      expect(results.gradeOf(1401), isNull); // another class
      expect(results.classAverage, '47.3');
      expect(results.groupAverage, '47.3');
    });

    test('an evaluation without grades: empty cells, no averages, and '
        'feedback without a grade', () {
      final results = evaluations.first.results;
      expect(results.grades.map((g) => g.pupilId), [1201, 1202, 1203]);
      expect(results.grades.map((g) => g.grade), everyElement(isNull));
      expect(results.grades.map((g) => g.value), everyElement(isNull));
      expect(results.grades.map((g) => g.hasFeedback), [false, true, false]);
      expect(results.classAverage, isNull);
      expect(results.groupAverage, isNull);
    });

    test('leaves out the rows of other classes and gradebooks, and the '
        'evaluations of another gradebook', () {
      final evaluations = _parse(
        _withCells([
          // A row of the own class with another owner (as the rows of the
          // other classes have), before the real one.
          {
            'c': '$_scheduledId',
            'r': 'pupil_1201_2440',
            'v': '<div class="gbc" raw="1">1</div>',
            'p': [1, 0, 0, '32506', -1],
          },
          // The class average of another class.
          {
            'c': '$_scheduledId',
            'r': 'clavg_2442',
            'v': '<div class="gbc" raw="3">3</div>',
            'p': [0],
          },
          // A cell of a column that is not one of the evaluations.
          {
            'c': '999',
            'r': 'pupil_1201_2440',
            'v': '<div class="gbc" raw="5">5</div>',
            'p': [1, 0, '999', '32508', 999],
          },
        ])..update(
          'head',
          (head) => [
            ...head as List,
            {
              ...(head.first as Map),
              'refID': '500003',
              'evaluationID': '500003',
              'ownerID': '32506',
            },
          ],
        ),
      );
      expect(evaluations.map((e) => e.id), [_newId, _scheduledId]);
      final results = evaluations.last.results;
      expect(results.grades.map((g) => g.grade), ['79', '15.5', null]);
      expect(results.classAverage, '47.3');
    });

    test("a pupil's first cell of an evaluation counts", () {
      final evaluations = _parse(
        _withCells([
          {
            'c': '$_scheduledId',
            'r': 'pupil_1203_2440',
            'v': '<div class="gbc" raw="12">12</div>',
            'p': [1, 0, '$_scheduledId', '32508', _scheduledId],
          },
        ]),
      );
      expect(evaluations.last.results.grades.map((g) => g.pupilId), [
        1203,
        1201,
        1202,
      ]);
      expect(evaluations.last.results.gradeOf(1203)?.grade, '12');
    });

    test('for the gradebook of another class of the group: its own '
        'evaluation and pupils', () {
      final evaluations = SkoreGradebookService.parseEvaluations(
        _withCells([
          {
            'c': '$_scheduledId',
            'r': 'pupil_1501_2444',
            'v': '<div class="gbc" raw="9">9</div>',
            'p': [1, 0, '$_scheduledId', '32504', _scheduledId],
          },
        ])..update(
          'head',
          (head) => [
            {...(head as List).last as Map, 'ownerID': '32504'},
          ],
        ),
        _wewi2,
        1704,
        now: _captured,
      );
      final evaluation = evaluations.single;
      expect(evaluation.id, _scheduledId);
      expect(evaluation.gradebookId, 32504);
      expect(evaluation.results.grades.single.pupilId, 1501);
      expect(evaluation.results.grades.single.classId, 2444);
      expect(evaluation.results.grades.single.grade, '9');
      // 6EWI's class average is not 6WEWI2's; the group's is the same.
      expect(evaluation.results.classAverage, isNull);
      expect(evaluation.results.groupAverage, '47.3');
    });

    test('a period without evaluations: an empty list', () {
      // Skore's live answer for a period without evaluations (2025-2026).
      expect(_parse(_result(_emptyPeriodAnswer)), isEmpty);
      expect(
        _parse({
          'head': <dynamic>[],
          'details': {'stream': <dynamic>[]},
        }),
        isEmpty,
      );
      // Only without evaluations.
      expect(
        () => _parse(_result()..['details'] = {'stream': 1}),
        throwsA(_skoreError()),
      );
    });

    test('other values Skore may give', () {
      final evaluations = _parse(
        _withHead(1, (e) {
          e
            ..['short'] = '  '
            ..['max'] = '20.5'
            ..['componentID'] = 0
            ..['component'] = null
            ..['evaltype'] = '2'
            ..['isPlannerEval'] = '1';
        }),
      );
      final evaluation = evaluations.last;
      expect(evaluation.shortName, isNull);
      expect(evaluation.max, 20.5);
      expect(evaluation.componentId, 0);
      expect(evaluation.componentName, '');
      expect(evaluation.type, SkoreEvaluationType.scale);
      expect(evaluation.isPlannerEvaluation, isTrue);

      final other = _parse(
        _withHead(1, (e) {
          e
            ..['max'] = null
            ..['evaltype'] = 7;
        }),
      ).last;
      expect(other.max, isNull);
      expect(other.type, SkoreEvaluationType.unknown);
      expect(other.typeCode, 7);
    });

    test('an evaluation of another period is refused', () {
      expect(
        () => _parse(_withHead(0, (e) => e['periodID'] = 1706)),
        throwsA(_skoreError(contains('of period 1706'))),
      );
    });

    test('an unknown shape is refused, never read as no evaluations or no '
        'grades', () {
      final pupilCell = {
        'c': '$_scheduledId',
        'r': 'pupil_1201_2440',
        'v': '<div class="gbc" raw="79">79</div>',
        'p': [1, 0, '$_scheduledId', '32508', _scheduledId],
      };
      final cases = <String, Object?>{
        'not an object': <dynamic>[],
        'no head': _result()..remove('head'),
        'a head that is not a list': _result()..['head'] = {},
        'no details': _result()..remove('details'),
        'details without a stream': _result()..['details'] = {},
        'an evaluation that is not an object': _result()..['head'] = ['500001'],
        'an evaluation without its refID': _withHead(
          0,
          (e) => e.remove('refID'),
        ),
        'an evaluation without its owner': _withHead(
          0,
          (e) => e['ownerID'] = null,
        ),
        'an evaluation without its period': _withHead(
          0,
          (e) => e.remove('periodID'),
        ),
        'no title': _withHead(0, (e) => e.remove('title')),
        'a short name that is not text': _withHead(0, (e) => e['short'] = 3),
        'a date in another form': _withHead(0, (e) => e['date'] = '08/10/2026'),
        'a date that does not exist': _withHead(
          0,
          (e) => e['date'] = '2026-02-30',
        ),
        'a highest grade that is no number': _withHead(
          0,
          (e) => e['max'] = 'twintig',
        ),
        'no type': _withHead(0, (e) => e.remove('evaltype')),
        'no course': _withHead(0, (e) => e.remove('courseID')),
        'a publication flag that is not 0 or 1': _withHead(
          0,
          (e) => e['public'] = '2',
        ),
        'no publication flag': _withHead(0, (e) => e.remove('public')),
        'a publication time that is no time': _withHead(
          1,
          (e) => e['publicdatetime'] = 'morgen',
        ),
        'a cell that is not an object': _withCells(['79']),
        'a pupil row in another form': _withCells([
          {...pupilCell, 'r': 'pupil_1201'},
        ]),
        'a pupil cell without its p': _withCells([
          {...pupilCell}..remove('p'),
        ]),
        'a pupil cell with a short p': _withCells([
          {
            ...pupilCell,
            'p': [1, 0],
          },
        ]),
        'a pupil cell without its value': _withCells([
          {...pupilCell, 'v': null},
        ]),
        'a pupil cell without its raw': _withCells([
          {...pupilCell, 'v': '<div class="gbc" >79</div>'},
        ]),
        'a pupil cell without its div.gbc': _withCells([
          {...pupilCell, 'v': '<span raw="79">79</span>'},
        ]),
        'a class average without its raw': _withCells([
          {
            'c': '$_scheduledId',
            'r': 'clavg_2440',
            'v': '<div class="gbc">81</div>',
            'p': [0],
          },
        ]),
      };
      for (final MapEntry(key: name, value: result) in cases.entries) {
        expect(() => _parse(result), throwsA(_skoreError()), reason: name);
      }
    });
  });

  group('SkoreGradebookService.parsePublication', () {
    SkorePublication parse(Object? public, Object? time, {DateTime? now}) =>
        SkoreGradebookService.parsePublication(
          public,
          time,
          now: now ?? _captured,
        );

    test('"0" with "": not published (seen live)', () {
      final publication = parse('0', '');
      expect(publication.state, SkorePublicationState.notPublished);
      expect(publication.at, isNull);
      expect(publication.isPublic, isFalse);
      // Not published, whatever the time and without one.
      expect(parse(0, null).state, SkorePublicationState.notPublished);
      expect(
        parse('0', '2026-10-01T08:00:00').state,
        SkorePublicationState.notPublished,
      );
    });

    test('"1" with a time after now: scheduled; at or before now: '
        'published', () {
      expect(
        parse('1', '2026-10-09T08:00:00').state,
        SkorePublicationState.scheduled,
      );
      expect(
        parse('1', '2026-10-08T12:00:00').state, // 10:00 UTC: now
        SkorePublicationState.published,
      );
      expect(
        parse('1', '2026-10-08T11:59:59').state,
        SkorePublicationState.published,
      );
      expect(
        parse('1', '2026-10-08T12:00:01').state,
        SkorePublicationState.scheduled,
      );
      expect(parse(1, '2025-10-16T08:00:00').state.name, 'published');
    });

    test('"1" without a time: published (not seen live)', () {
      for (final time in ['', null]) {
        final publication = parse('1', time);
        expect(publication.state, SkorePublicationState.published);
        expect(publication.at, isNull);
        expect(publication.isPublic, isTrue);
        expect(publication.rawPublicDateTime, '');
      }
    });

    test('the time is Belgian time: CEST in summer, CET in winter', () {
      final cases = {
        '2026-10-09T08:00:00': DateTime.utc(2026, 10, 9, 6),
        '2025-12-12T08:00:00': DateTime.utc(2025, 12, 12, 7),
        '2026-02-11T08:00:00': DateTime.utc(2026, 2, 11, 7),
        // Summer time starts on the last Sunday of March, at 02:00 CET.
        '2026-03-29T01:59:00': DateTime.utc(2026, 3, 29, 0, 59),
        '2026-03-29T03:00:00': DateTime.utc(2026, 3, 29, 1),
        // And ends on the last Sunday of October, at 03:00 CEST.
        '2026-10-25T01:59:00': DateTime.utc(2026, 10, 24, 23, 59),
        '2026-10-25T03:00:00': DateTime.utc(2026, 10, 25, 2),
        // Without seconds, and with a space (as Skore's proposal for a
        // publication time gives it).
        '2026-10-09T08:00': DateTime.utc(2026, 10, 9, 6),
        '2026-10-09 08:00:00': DateTime.utc(2026, 10, 9, 6),
        // With an offset: as it says.
        '2026-10-09T08:00:00+01:00': DateTime.utc(2026, 10, 9, 7),
        '2026-10-09T06:00:00Z': DateTime.utc(2026, 10, 9, 6),
      };
      for (final MapEntry(key: time, value: at) in cases.entries) {
        final publication = parse('1', time);
        expect(publication.at, at, reason: time);
        expect(publication.at!.isUtc, isTrue, reason: time);
        expect(publication.rawPublicDateTime, time, reason: time);
      }
    });

    test('anything else is refused', () {
      final cases = <(Object?, Object?)>[
        ('2', ''),
        ('', ''),
        (null, ''),
        (true, ''),
        (1.0, ''),
        ('1', 'morgen'),
        ('1', '2026-13-01T08:00:00'),
        ('1', '2026-10-32T08:00:00'),
        ('1', '2026-10-09T24:00:00'),
        ('1', '2026-10-09'),
        ('1', 20261009),
      ];
      for (final (public, time) in cases) {
        expect(
          () => parse(public, time),
          throwsA(_skoreError()),
          reason: '$public $time',
        );
      }
    });
  });

  group('SkoreGradebookService.getEvaluations', () {
    test('sends getEvaluations as the web client does, for the '
        "gradebook's school year", () async {
      final (server, gradebooks) = await serve();

      final evaluations = await gradebooks.getEvaluations(_ewi, 1704);

      expect(evaluations.map((e) => e.id), [_newId, _scheduledId]);
      expect(server.calls, hasLength(1));
      final call = server.calls.single;
      expect(call.method, 'getEvaluations');
      // The period and the user as numbers, the other IDs as strings.
      expect(
        call.form['rpc_params'],
        '[1704,$_me,["2264"],"472","2440",["176","472","2440"]]',
      );
      expect(call.session['teacher'], _me);
      expect(call.session['restriction'], 0);
      expect(call.session['wy'], '24');
      expect(server.requests, [
        'GET /course-list/api/v1/courses',
        'GET /',
        'RPC getEvaluations',
      ]);
    });

    test("the publication state follows the service's clock", () async {
      var now = _captured;
      final (_, gradebooks) = await serve(clock: () => now);

      final before = await gradebooks.getEvaluations(_ewi, 1704);
      now = _publishedFrom;
      final after = await gradebooks.getEvaluations(_ewi, 1704);

      expect(before.last.publication.state, SkorePublicationState.scheduled);
      expect(after.last.publication.state, SkorePublicationState.published);
      expect(after.first.publication.state, SkorePublicationState.notPublished);
    });

    test('a period ID that is not positive is refused before anything is '
        'sent', () async {
      final (server, gradebooks) = await serve();

      for (final id in [0, -1704]) {
        await expectLater(
          gradebooks.getEvaluations(_ewi, id),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'periodId'),
          ),
        );
      }
      expect(server.requests, isEmpty);
    });

    test('an answer about another period is refused', () async {
      final (_, gradebooks) = await serve();

      await expectLater(
        gradebooks.getEvaluations(_ewi, 1706),
        throwsA(_skoreError(contains('of period 1704'))),
      );
    });

    test(
      'an answer the service cannot use is a SmartschoolSkoreError',
      () async {
        final cases = <String, _Answer>{
          'HTTP 500': (
            status: 500,
            body: '{"message":"Internal Server Error"}',
          ),
          'an HTML page': _ok(
            '<!DOCTYPE html><html><body><h1>Oeps, er ging iets mis</h1>'
            '</body></html>',
          ),
          'no result': _ok('{"session":1}'),
          'a result that is not an object': _ok('{"result":[],"session":1}'),
        };
        for (final MapEntry(key: name, value: answer) in cases.entries) {
          final (_, gradebooks) = await serve(evaluations: answer);
          await expectLater(
            gradebooks.getEvaluations(_ewi, 1704),
            throwsA(_skoreError()),
            reason: name,
          );
        }
      },
    );

    test('an answer without a session is an expired session', () async {
      final (_, gradebooks) = await serve(
        evaluations: _ok('{"result":{},"session":0}'),
      );

      await expectLater(
        gradebooks.getEvaluations(_ewi, 1704),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
    });
  });

  group('SkoreGradebookService.getResults', () {
    test('reads the grades of the evaluation again', () async {
      final (server, gradebooks) = await serve();
      final scheduled = (await gradebooks.getEvaluations(_ewi, 1704)).last;
      // Skore now has another grade for the third pupil.
      server.evaluations
        ..clear()
        ..add(
          _ok(
            _evaluationsAnswer.replaceFirst(
              r'<div class=\"gbc\" raw=\"\"></div>',
              r'<div class=\"gbc\" raw=\"12.5\">12,5</div>',
            ),
          ),
        );

      final results = await gradebooks.getResults(_ewi, scheduled);

      expect(results.evaluationId, _scheduledId);
      expect(results.grades.map((g) => g.grade), ['79', '15.5', '12.5']);
      expect(server.calls.map((c) => c.method), [
        'getEvaluations',
        'getEvaluations',
      ]);
      expect(server.calls.last.params.first, 1704);
    });

    test('an evaluation Skore no longer lists is refused', () async {
      final (server, gradebooks) = await serve();
      final fresh = (await gradebooks.getEvaluations(_ewi, 1704)).first;
      server.evaluations
        ..clear()
        ..add(
          _ok(
            jsonEncode({
              'result': _result()
                ..['head'] = [(_result()['head'] as List).last],
              'session': 1,
            }),
          ),
        );

      await expectLater(
        gradebooks.getResults(_ewi, fresh),
        throwsA(_skoreError(contains('no longer lists evaluation $_newId'))),
      );
    });

    test('an evaluation of another gradebook is refused before anything is '
        'sent', () async {
      final (server, gradebooks) = await serve();
      final scheduled = _parse(_result()).last;

      await expectLater(
        gradebooks.getResults(_wewi2, scheduled),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'evaluation'),
        ),
      );
      expect(server.requests, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Feedback
  // ---------------------------------------------------------------------------

  group('SkoreGradebookService.feedbackPath', () {
    test('builds the REST path from the IDs, as the feedback panel does', () {
      expect(
        SkoreGradebookService.feedbackPath(
          platform: 4069,
          userId: _me,
          gradebook: _ewi,
          evaluationId: _scheduledId,
          pupilId: 1201,
        ),
        // In the form of the live example of #149.
        '/skore/api/v1/gradebook/feedback/4069_500001/student/4069_1201_0/'
        'class/4069_2440/teacher/4069_1005_0/context/176_472_2440',
      );
    });
  });

  group('SkoreGradebookService.parseFeedback', () {
    List<SkoreFeedback> parse(Object? json, {int pupilId = 1202}) =>
        SkoreGradebookService.parseFeedback(
          json,
          pupilId: pupilId,
          evaluationId: _scheduledId,
        );

    test('none: an empty list', () {
      expect(parse(<dynamic>[]), isEmpty);
    });

    test('one', () {
      final feedback = parse([(jsonDecode(_twoFeedback) as List).first]);
      final one = feedback.single;
      expect(one.id, '00000000-0000-4000-8000-000000000001');
      expect(one.text, 'Eerste opmerking.');
      expect(one.pupilId, 1202);
      expect(one.teacherId, _me);
      expect(one.teacherName, 'Jan Janssens');
      // "2026-10-08T09:49:36+02:00"
      expect(one.createdAt, DateTime.utc(2026, 10, 8, 7, 49, 36));
      expect(one.createdAt!.isUtc, isTrue);
      expect(one.changedAt, one.createdAt);
      expect(one.attachments, isEmpty);
      expect(one.canEdit, isTrue);
    });

    test('two, each its own, in the order Skore gives them', () {
      final feedback = parse(jsonDecode(_twoFeedback));
      expect(feedback.map((f) => f.text), [
        'Eerste opmerking.',
        'Tweede opmerking.',
      ]);
      expect(feedback.map((f) => f.teacherId), [_me, 1006]);
      expect(feedback.map((f) => f.canEdit), [true, false]);
      final second = feedback.last;
      expect(second.changedAt, DateTime.utc(2026, 10, 8, 8, 15));
      expect(second.attachments.single.id, 'att-1');
      expect(second.attachments.single.name, 'verbetering.pdf');
      expect(second.attachments.single.size, 1234);
      expect(second.attachments.single.json['downloadUrl'], '/fake/download');
    });

    test('what the panel does without: no times, names, attachments or '
        'capabilities', () {
      final feedback = parse([
        {
          'id': 'f-1',
          'student': {'id': '4069_1202_0'},
          'teacher': {'id': '4069_1005_0'},
          'text': '',
        },
      ]).single;
      expect(feedback.text, '');
      expect(feedback.teacherName, '');
      expect(feedback.createdAt, isNull);
      expect(feedback.changedAt, isNull);
      expect(feedback.attachments, isEmpty);
      expect(feedback.canEdit, isFalse);
    });

    test('feedback about another pupil or evaluation, or in an unknown '
        'shape, is refused', () {
      final one =
          (jsonDecode(_twoFeedback) as List).first as Map<String, dynamic>;
      final cases = <String, Object?>{
        'not a list': {'items': <dynamic>[]},
        'an item that is not an object': ['Eerste opmerking.'],
        'no ID': [
          {...one}..remove('id'),
        ],
        'no text': [
          {...one}..remove('text'),
        ],
        'another pupil': [
          {
            ...one,
            'student': {'id': '4069_1201_0'},
          },
        ],
        'no pupil': [
          {...one}..remove('student'),
        ],
        'no teacher': [
          {...one}..remove('teacher'),
        ],
        'another evaluation': [
          {...one, 'evaluationId': '4069_500002'},
        ],
        'a time without its offset': [
          {...one, 'createdAt': '2026-10-08T09:49:36'},
        ],
        'attachments that are not a list': [
          {...one, 'attachments': 'none'},
        ],
        'an attachment that is not an object': [
          {
            ...one,
            'attachments': ['verbetering.pdf'],
          },
        ],
      };
      for (final MapEntry(key: name, value: json) in cases.entries) {
        expect(() => parse(json), throwsA(_skoreError()), reason: name);
      }
    });
  });

  group('SkoreGradebookService.getFeedback', () {
    const path =
        '/skore/api/v1/gradebook/feedback/4069_500001/student/4069_1202_0/'
        'class/4069_2440/teacher/4069_${_me}_0/context/176_472_2440';

    test('sends the GET of the feedback panel, built from the IDs', () async {
      final (server, gradebooks) = await serve(
        feedback: {path: _ok(_twoFeedback)},
      );
      final scheduled = _parse(_result()).last;

      final feedback = await gradebooks.getFeedback(_ewi, scheduled, 1202);

      expect(feedback.map((f) => f.id), [
        '00000000-0000-4000-8000-000000000001',
        '00000000-0000-4000-8000-000000000002',
      ]);
      expect(server.requests.last, 'GET $path');
      expect(server.calls, isEmpty); // no RPC call
    });

    test('a pupil without feedback: an empty list', () async {
      final (server, gradebooks) = await serve();
      final scheduled = _parse(_result()).last;

      expect(await gradebooks.getFeedback(_ewi, scheduled, 1203), isEmpty);
      expect(server.requests.last, contains('/student/4069_1203_0/'));
    });

    test("Skore's error answers are a SmartschoolSkoreError, with their "
        'title and detail', () async {
      final scheduled = _parse(_result()).last;
      final cases = <String, (_Answer, Matcher)>{
        'a 404 with a problem': (
          (
            status: 404,
            body:
                '{"status":404,"title":"Not Found","detail":"Unknown '
                'evaluation","type":""}',
          ),
          allOf(contains('HTTP 404'), contains('Not Found: Unknown')),
        ),
        'a 403 without a body': (
          (status: 403, body: ''),
          contains('HTTP 403.'),
        ),
        'a 500 with an HTML page': (
          (status: 500, body: '<html><body>Oeps</body></html>'),
          contains('HTTP 500.'),
        ),
        'an HTML page': (
          _ok('<!DOCTYPE html><html><body>Start</body></html>'),
          contains('HTML page'),
        ),
        'not a list': (_ok('{"items":[]}'), contains('instead of a list')),
      };
      for (final MapEntry(key: name, value: (answer, message))
          in cases.entries) {
        final (_, gradebooks) = await serve(feedback: {path: answer});
        await expectLater(
          gradebooks.getFeedback(_ewi, scheduled, 1202),
          throwsA(_skoreError(message)),
          reason: name,
        );
      }
    });

    test('an evaluation of another gradebook, or a pupil ID that is not '
        'positive, is refused before anything is sent', () async {
      final (server, gradebooks) = await serve();
      final scheduled = _parse(_result()).last;

      await expectLater(
        gradebooks.getFeedback(_wewi2, scheduled, 1501),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'evaluation'),
        ),
      );
      for (final id in [0, -1202]) {
        await expectLater(
          gradebooks.getFeedback(_ewi, scheduled, id),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'pupilId'),
          ),
        );
      }
      expect(server.requests, isEmpty);
    });

    test(
      'a session user ID in another form is refused before the GET',
      () async {
        final (server, gradebooks) = await serve(userId: '1005');
        final scheduled = _parse(_result()).last;

        await expectLater(
          gradebooks.getFeedback(_ewi, scheduled, 1202),
          throwsA(isA<SmartschoolParsingError>()),
        );
        expect(server.requests.where((r) => r.contains(_feedbackApi)), isEmpty);
      },
    );
  });
}
