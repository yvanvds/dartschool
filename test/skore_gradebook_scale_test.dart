// Tests for issue #193: the scale of the evaluations on a scale
// ("Waarderingen", `evaltype` 2) of Skore's gradebook
// (`SkoreGradebookService.getScale`), and the level of a grade on it
// (`SkoreScale.levelOf`).
//
// Skore's web client has the scale from its gradebook frame: the page
// /SkoreGradebook hands the frame a start-up secret (`startUpSecret`, with
// `fcm`), and the frame (GET /modules/Skore/gradebook.php?fcm=1&initcontrol=
// <secret>&teacher=) gives it as `defaultScale` of its `djConfig`. The page
// and the frame below have the shape of live captures (read-only,
// 2026-10-27, the developer's account): the frame answers `not good` for a
// secret of another session, and its scale had two levels without a
// graphic. The scale's ID, name and levels here are fakes; so is the
// secret. The third level, and the one with a graphic, are not from a live
// answer: a graphic's fields are those of the web client's feedback panel.
//
// How the web client finds the level of a grade (`provideScaleForPrc` of
// the gradebook frame's code): the grade as a percentage of the highest
// grade (`parseInt(max)`, the percentage rounded to one decimal), cut to a
// whole number, and the last level whose `range.lowerThreshold` is at most
// that. No evaluation on a scale was seen live.
//
// Nothing here reaches Smartschool: the fake fails the test on any request
// other than the GETs of the page and the frame.
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

const _page = '/SkoreGradebook';
const _frame = '/modules/Skore/gradebook.php';

/// The page of Skore's gradebook, with its start-up secret [secret] (a
/// fake) in the shape seen live.
String _gradebookPage(String secret) =>
    '<!DOCTYPE html><html><head><title>Puntenboek</title></head><body>'
    '<script>window.SMSC = {"vars":{"lng":{"skore_feedback_copy_dialog_ok":'
    '"Kopi\\u00ebren"}},"activeClass":null,"userFullName":"Jan Janssens",'
    '"teacherRequest":1005,"teacherParam":"","teacherId":1005,'
    '"startUpSecret":"$secret","fcm":1,"coordmode":0}};</script>'
    '</body></html>';

/// The scale of the frame, in the shape seen live (fake values), with a
/// third level.
const _scaleJson =
    '{"id":"00000000-0000-4000-8000-000000000193","name":"Houding",'
    '"levels":['
    '{"id":901,"description":"Zwak","range":{"lowerThreshold":0,"value":0},'
    '"graphic":null,"abbreviation":"Z","color":"red"},'
    '{"id":902,"description":"Goed","range":{"lowerThreshold":50,"value":75},'
    '"graphic":null,"abbreviation":"G","color":"green"},'
    '{"id":903,"description":"Zeer goed {top}","range":{"lowerThreshold":80,'
    '"value":100},"graphic":null,"abbreviation":"ZG","color":"olive"}]}';

/// The frame of Skore's gradebook with [scale] as its `defaultScale`, in the
/// shape seen live.
String _gradebookFrame([String scale = _scaleJson]) =>
    '<!DOCTYPE html><html><head><title>Skore</title>\n'
    '<script type="text/javascript" nonce="abc">\n'
    '  var djConfig = {\n'
    '    isDebug : false,\n'
    '    me:1005,\n'
    '    actualWy:24,\n'
    '    resultsOptions: {"colorScales":[{"lowerThreshold":0,"color":"red"},'
    '{"lowerThreshold":50,"color":"mint"}]},\n'
    '    defaultScale: $scale\n'
    '  };\n'
    '</script></head><body><div widgetID="gradebook" dojoType="gradebook2">'
    '</div></body></html>';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// A Smartschool that answers the page of Skore's gradebook and its frame,
/// in turn from [pages] and [frames] (the last one repeats).
class _Smartschool implements HttpClientAdapter {
  _Smartschool({required this.pages, required this.frames});

  final List<_Answer> pages;
  final List<_Answer> frames;

  /// Every request that reached it, as `METHOD path?query`.
  final List<String> requests = [];

  static ResponseBody _body(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    },
  );

  static _Answer _next(List<_Answer> answers) =>
      answers.length > 1 ? answers.removeAt(0) : answers.single;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(
      '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    );
    switch ((options.method, uri.path)) {
      case ('GET', _page):
        return _body(_next(pages));
      case ('GET', _frame):
        return _body(_next(frames));
    }
    fail('Unexpected request: ${options.method} $uri');
  }

  @override
  void close({bool force = false}) {}
}

/// A plain [SmartschoolSkoreError] whose message is [message].
Matcher _skoreError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// An evaluation of [type] (`evaltype` [typeCode]) with the highest grade
/// [max], read as getEvaluations reads one.
SkoreEvaluation _evaluation({
  SkoreEvaluationType type = SkoreEvaluationType.scale,
  int typeCode = 2,
  num? max = 10,
}) => SkoreEvaluation(
  id: 500012,
  evaluationId: 500012,
  gradebookId: 32508,
  periodId: 1704,
  column: 'B',
  title: 'Inzet',
  shortName: null,
  date: DateTime(2026, 10, 6),
  max: max,
  componentId: 0,
  componentName: '',
  type: type,
  typeCode: typeCode,
  courseId: 2264,
  courseName: 'Informaticawetenschappen (2 uur)',
  isPlannerEvaluation: false,
  publication: const SkorePublication(
    state: SkorePublicationState.notPublished,
    at: null,
    rawPublic: '0',
    rawPublicDateTime: '',
  ),
  results: const SkoreEvaluationResults(evaluationId: 500012),
);

/// A pupil's cell with the grade [grade] (Skore's `raw`, `null` for none).
SkoreGrade _grade(String? grade) => SkoreGrade(
  pupilId: 1201,
  classId: 2440,
  grade: grade,
  hasFeedback: false,
  categoryType: 0,
  cellEvaluationId: 500012,
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SkoreGradebookService)> serve({
    List<_Answer>? pages,
    List<_Answer>? frames,
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(
      pages: pages ?? [_ok(_gradebookPage('s3cr3tFAKE'))],
      frames: frames ?? [_ok(_gradebookFrame())],
    );
    client.dio.httpClientAdapter = server;
    return (server, SkoreGradebookService(client));
  }

  group('SkoreGradebookService.parseStartUp', () {
    test("the page's start-up secret and fcm, as seen live", () {
      final startUp = SkoreGradebookService.parseStartUp(
        _gradebookPage('s3cr3tFAKE'),
      );
      expect(startUp.secret, 's3cr3tFAKE');
      expect(startUp.fcm, '1');
    });

    test('a page without them is refused, quoting nothing of it', () {
      for (final (page, missing) in [
        ('<html><body>Jan Janssens</body></html>', 'startUpSecret'),
        (_gradebookPage('s3cr3tFAKE').replaceFirst('"fcm":1', ''), 'fcm'),
        (_gradebookPage(''), 'startUpSecret'),
      ]) {
        expect(
          () => SkoreGradebookService.parseStartUp(page),
          throwsA(
            _skoreError(
              allOf(contains(missing), isNot(contains('Jan Janssens'))),
            ),
          ),
          reason: missing,
        );
      }
    });
  });

  group('SkoreGradebookService.parseScale', () {
    test("the frame's defaultScale: its levels, in Skore's order", () {
      final scale = SkoreGradebookService.parseScale(_gradebookFrame());
      expect(scale.id, '00000000-0000-4000-8000-000000000193');
      expect(scale.name, 'Houding');
      expect(scale.levels.map((l) => l.id), [901, 902, 903]);
      expect(scale.levels.map((l) => l.description), [
        'Zwak',
        'Goed',
        'Zeer goed {top}', // a brace in a string does not end the object
      ]);
      expect(scale.levels.map((l) => l.abbreviation), ['Z', 'G', 'ZG']);
      expect(scale.levels.map((l) => l.color), ['red', 'green', 'olive']);
      expect(scale.levels.map((l) => l.lowerThreshold), [0, 50, 80]);
      expect(scale.levels.map((l) => l.value), [0, 75, 100]);
      expect(scale.levels.map((l) => l.graphic), everyElement(isNull));
      expect('$scale', 'SkoreScale(id: ${scale.id}, levels: 3)');
    });

    test('other values Skore may give: a graphic (from the web client), '
        'numbers as text, no colour', () {
      final scale = SkoreGradebookService.parseScale(
        _gradebookFrame(
          '{"id":"x","name":" Houding ","levels":['
          '{"id":"904","description":"Top","range":{"lowerThreshold":"90",'
          '"value":"100"},"graphic":{"type":"icon","value":"star","url":"",'
          '"color":"olive"},"abbreviation":"T","color":null},'
          '{"id":905,"description":"Leeg","range":{"lowerThreshold":0,'
          '"value":0},"graphic":"","abbreviation":"L"}]}',
        ),
      );
      expect(scale.name, 'Houding');
      final [top, empty] = scale.levels;
      expect(top.id, 904);
      expect(top.lowerThreshold, 90);
      expect(top.value, 100);
      expect(top.graphic, {
        'type': 'icon',
        'value': 'star',
        'url': '',
        'color': 'olive',
      });
      expect(top.color, '');
      expect(empty.graphic, isNull);
      expect(empty.color, '');
    });

    test('"not good", a frame without the scale, or a scale in another '
        'shape is refused, quoting nothing of the frame', () {
      String level(String change) => '{"id":"x","name":"n","levels":[$change]}';
      const good =
          '"id":901,"description":"Zwak","range":{"lowerThreshold":0,'
          '"value":0},"graphic":null,"abbreviation":"Z","color":"red"';
      final cases = <String, (String, String)>{
        'not good': ('not good', 'not good'),
        'no defaultScale': (
          '<html><body>Jan Janssens</body></html>',
          'holds no defaultScale',
        ),
        'a defaultScale that is not an object': (
          _gradebookFrame('null'),
          'holds no readable defaultScale',
        ),
        'a defaultScale that is not JSON': (
          _gradebookFrame("{id: 'x', name: 'Jan Janssens'}"),
          'holds no readable defaultScale',
        ),
        'a defaultScale that does not close': (
          '<script>var djConfig = {defaultScale: {"id":"x","name":"n"',
          'holds no readable defaultScale',
        ),
        'no id': (_gradebookFrame('{"name":"n","levels":[]}'), 'its id'),
        'no name': (_gradebookFrame('{"id":"x","levels":[]}'), 'its name'),
        'levels that are not a list': (
          _gradebookFrame('{"id":"x","name":"n","levels":{}}'),
          'its levels',
        ),
        'a level that is not an object': (
          _gradebookFrame(level('"Zwak"')),
          'its object',
        ),
        'a level without its id': (
          _gradebookFrame(level('{${good.replaceFirst('"id":901,', '')}}')),
          'its id',
        ),
        'a level without its description': (
          _gradebookFrame(
            level('{${good.replaceFirst('"description":"Zwak",', '')}}'),
          ),
          'its description',
        ),
        'a level without its abbreviation': (
          _gradebookFrame(
            level('{${good.replaceFirst(',"abbreviation":"Z"', '')}}'),
          ),
          'its abbreviation',
        ),
        'a colour that is not text': (
          _gradebookFrame(
            level('{${good.replaceFirst('"color":"red"', '"color":1')}}'),
          ),
          'its color',
        ),
        'a level without its range': (
          _gradebookFrame(
            level(
              '{${good.replaceFirst('"range":{"lowerThreshold":0,"value":0},', '')}}',
            ),
          ),
          'its range',
        ),
        'a threshold that is not a number': (
          _gradebookFrame(
            level(
              '{${good.replaceFirst('"lowerThreshold":0', '"lowerThreshold":"laag"')}}',
            ),
          ),
          'its range.lowerThreshold',
        ),
        'a range without its value': (
          _gradebookFrame(level('{${good.replaceFirst(',"value":0', '')}}')),
          'its range.value',
        ),
        'a graphic that is neither an object nor none': (
          _gradebookFrame(
            level('{${good.replaceFirst('"graphic":null', '"graphic":3')}}'),
          ),
          'its graphic',
        ),
      };
      for (final MapEntry(key: name, value: (frame, message))
          in cases.entries) {
        expect(
          () => SkoreGradebookService.parseScale(frame),
          throwsA(
            _skoreError(
              allOf(contains(message), isNot(contains('Jan Janssens'))),
            ),
          ),
          reason: name,
        );
      }
    });
  });

  group('SkoreScale.levelOf', () {
    final scale = SkoreGradebookService.parseScale(_gradebookFrame());

    test('the level of a grade, as the web client finds it: the percentage '
        'of max, and the last level whose threshold it reaches', () {
      final evaluation = _evaluation(); // max 10
      String? level(String? grade) =>
          scale.levelOf(evaluation, _grade(grade))?.abbreviation;
      expect(level('0'), 'Z');
      expect(level('4.9'), 'Z'); // 49%
      expect(level('4.995'), 'G'); // 49.95%, rounded to 50.0%
      expect(level('5'), 'G');
      expect(level('7.99'), 'G'); // 79.9%
      expect(level('8'), 'ZG');
      expect(level('10'), 'ZG');
      // The label and the short label of a grade.
      final good = scale.levelOf(evaluation, _grade('7.5'))!;
      expect(good.description, 'Goed');
      expect(good.abbreviation, 'G');
    });

    test("the highest grade cut to a whole number, as the web client's "
        'parseInt does', () {
      // 10 of 20.5: 50% of 20, not 48.8% of 20.5.
      expect(
        scale.levelOf(_evaluation(max: 20.5), _grade('10'))?.abbreviation,
        'G',
      );
    });

    test('no level: no grade, a grade that is not a number, no highest '
        'grade, or a percentage no level covers', () {
      expect(scale.levelOf(_evaluation(), _grade(null)), isNull);
      expect(scale.levelOf(_evaluation(), _grade('G')), isNull);
      expect(scale.levelOf(_evaluation(max: null), _grade('5')), isNull);
      expect(scale.levelOf(_evaluation(max: 0.5), _grade('0')), isNull);
      expect(scale.levelOf(_evaluation(), _grade('10.1')), isNull); // 101%
      final fromTen = SkoreScale(
        id: 'x',
        name: 'n',
        levels: [scale.levels[1]], // from 50%
      );
      expect(fromTen.levelOf(_evaluation(), _grade('4')), isNull);
      expect(
        const SkoreScale(id: 'x', name: 'n').levelForPercentage(50),
        isNull,
      );
    });

    test('levelForPercentage: cut to a whole number, from 0 to 100', () {
      String? level(num percentage) =>
          scale.levelForPercentage(percentage)?.abbreviation;
      expect(level(0), 'Z');
      expect(level(49.99), 'Z');
      expect(level(50), 'G');
      expect(level(100), 'ZG');
      expect(level(100.9), 'ZG');
      expect(level(-0.5), 'Z'); // cut to 0, as parseInt does
      expect(level(101), isNull);
      expect(level(-1), isNull);
      expect(level(double.nan), isNull);
      expect(level(double.infinity), isNull);
    });

    test('an evaluation that is not on a scale is an ArgumentError', () {
      for (final (type, code) in [
        (SkoreEvaluationType.points, 1),
        (SkoreEvaluationType.unknown, 3),
      ]) {
        expect(
          () => scale.levelOf(
            _evaluation(type: type, typeCode: code),
            _grade('5'),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('evaltype $code'),
            ),
          ),
        );
      }
    });
  });

  group('SkoreGradebookService.getScale', () {
    test('GETs the page, then the frame with its secret, as the web client '
        'loads them, and reads the scale; nothing else', () async {
      final (server, gradebooks) = await serve();

      final scale = await gradebooks.getScale();

      expect(scale.levels.map((l) => l.abbreviation), ['Z', 'G', 'ZG']);
      expect(server.requests, [
        'GET $_page',
        'GET $_frame?fcm=1&initcontrol=s3cr3tFAKE&teacher=',
      ]);
    });

    test('a frame that does not take the secret ("not good") is asked once '
        'more, with the secret of the page loaded again', () async {
      final (server, gradebooks) = await serve(
        pages: [_ok(_gradebookPage('oldFAKE')), _ok(_gradebookPage('newFAKE'))],
        frames: [_ok('not good'), _ok(_gradebookFrame())],
      );

      final scale = await gradebooks.getScale();

      expect(scale.levels, hasLength(3));
      expect(server.requests, [
        'GET $_page',
        'GET $_frame?fcm=1&initcontrol=oldFAKE&teacher=',
        'GET $_page',
        'GET $_frame?fcm=1&initcontrol=newFAKE&teacher=',
      ]);
    });

    test('"not good" twice is a SmartschoolSkoreError; no third try', () async {
      final (server, gradebooks) = await serve(frames: [_ok('not good')]);

      await expectLater(
        gradebooks.getScale(),
        throwsA(_skoreError(contains('"not good"'))),
      );
      expect(server.requests, hasLength(4));
    });

    test('another HTTP status than 200 is a SmartschoolSkoreError', () async {
      var (server, gradebooks) = await serve(
        pages: [(status: 500, body: 'Internal error')],
      );
      await expectLater(
        gradebooks.getScale(),
        throwsA(
          _skoreError(
            "Skore answered the page of Skore's gradebook (/SkoreGradebook) "
            'with HTTP 500.',
          ),
        ),
      );
      expect(server.requests, ['GET $_page']);

      (server, gradebooks) = await serve(
        frames: [(status: 404, body: 'Not found')],
      );
      await expectLater(
        gradebooks.getScale(),
        throwsA(_skoreError(contains('($_frame) with HTTP 404'))),
      );
    });

    test('a page without the secret, or a frame without the scale, is a '
        'SmartschoolSkoreError', () async {
      var (_, gradebooks) = await serve(
        pages: [_ok('<html><body></body></html>')],
      );
      await expectLater(
        gradebooks.getScale(),
        throwsA(_skoreError(contains('startUpSecret'))),
      );

      (_, gradebooks) = await serve(frames: [_ok('<html></html>')]);
      await expectLater(
        gradebooks.getScale(),
        throwsA(_skoreError(contains('holds no defaultScale'))),
      );
    });
  });
}
