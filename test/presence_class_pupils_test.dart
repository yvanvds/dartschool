// Regression tests for issue #104: PresenceService.getClassPupils returned an
// empty list for every class the Presence module listed no pupils for, the
// same for a class without pupils as for a day it refuses or a class it does
// not know, and dropped the module's `saveIsAllowed` and `errorMessage`.
//
// What the module answers `Presence/Class/getClass`, seen live (read-only,
// 2026-10-03, every class of the school on one school day and one class on
// other days):
//
// - a class with pupils, on a day up to today (also a Saturday, and a day of
//   the previous school year): the class's own fields (`groupID`, `name`,
//   `structID`, `userCanRecord`, ...), its pupils, `saveIsAllowed: true` and
//   `errorMessage: ""`;
// - a day after today: the class's fields, no pupils, `saveIsAllowed: false`
//   and "Het is niet mogelijk om in de toekomst afwezigheden op te nemen.";
// - a class without pupils (one of the school's classes): its fields, no
//   pupils, `false` and "Deze klas bevat geen leerlingen.";
// - a class ID it does not know: no class fields at all, no pupils, `false`
//   and the same "Deze klas bevat geen leerlingen.";
// - the class -2 ("Uit Planner", the config's `activeClass` of a teacher who
//   has no lesson at that moment): no class fields, no pupils, `false` and
//   "U geeft momenteel geen les. Kies een andere klas in de keuzelijst.".
//
// No answer with an empty list and `saveIsAllowed: true` was seen. The fake
// Smartschool below answers in those shapes; its pupils are made up.
//
// Issue #117: that class -2 was the config's `activeClass`, an ordinary
// PresenceClassRef, and `classForGroup(-2)` returned it, so a caller that
// lists the classes of the account (the allowed classes, plus the active
// class when it is not among them) listed "Uit Planner" as a class. Now
// getConfig gives it as `activePlaceholder`, `activeClass` is null for it and
// `classForGroup` does not return it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

const _getConfig = '/Presence/Main/getConfig';
const _getAllCodes = '/Presence/Code/getAllCodes';
const _getClass = '/Presence/Class/getClass';
const _save = '/Presence/Class/savePupilsPresences';

const _future =
    'Het is niet mogelijk om in de toekomst afwezigheden op te '
    'nemen.';
const _noPupils = 'Deze klas bevat geen leerlingen.';
const _noLesson =
    'U geeft momenteel geen les. Kies een andere klas in de keuzelijst.';

/// The config as captured (2026-10-03) with an account whose
/// absence-administrator rights were switched off: `userCanRecord` but not
/// `userCanConfirm`, so it may not set the half-days of 1A (#121).
const _configJson = '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"adminNumber":null,"groupID":-2,"instituteNumber":0,
   "name":"Uit Planner","structID":null,"studierichting":"",
   "userCanConfirm":false},"schoolyear":"2026-11-05"},
 "main":{"allowedClasses":[
   {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
    "userCanConfirm":false,"userCanRecord":true,"instituteNumber":125252,
    "structID":311}]}}
''';

/// [_configJson] for an account that may set the half-days of 1A
/// (`userCanConfirm`, as an absence administrator's, seen live 2026-10-04,
/// #121): `setLate` and `setPresent` read the class for it.
final _configWithHalfDayRight = _configJson.replaceFirst(
  '"userCanConfirm":false,"userCanRecord":true',
  '"userCanConfirm":true,"userCanRecord":true',
);

const _codesJson = '''
[{"codeID":70,"code":"|","name":"Aanwezig","alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","alias":[]}]
''';

/// The class's own fields, with which the module starts its answer for a
/// class it knows.
String _classFields(int groupId, String name) =>
    '"groupID":$groupId,"name":"$name ","adminNumber":6246,"isOfficial":1,'
    '"userCanConfirm":false,"userCanRecord":true,"isOKAN":false,'
    '"instituteNumber":125252,"structID":311,"studierichting":"1ste leerjaar A",'
    '"downStreamGroups":[],"hasDiscimus":true,"iconclass":"briefcase",';

const _schoolyear =
    '"schoolyear":{"ssID":4069,"label":"2026-2027","start":"2026-09-01",'
    '"stop":"2027-08-31","date_in_between":"2026-11-05"},';

const _hours =
    ',"hourBlocks":[{"hourID":216,"shortdesc":1,"title":"1ste lesuur",'
    '"active":false,"partOfDay":"am"}],"ampm":{"amHourID":216,'
    '"pmHourID":226,"unofficialAMhourID":216,"unofficialPMhourID":226}';

String _pupil(int userId, int movementId, String name) =>
    '{"movementID":$movementId,"userID":$userId,"name":"$name",'
    '"presence":[{"presenceID":${userId * 10},"presenceDate":"2026-10-01",'
    '"studentID":$userId,"hourID":null,"partOfDay":"am","codeID":70,'
    '"aliasID":null,"motivation":null,"deleteStatus":0}]}';

/// The answer for a class the module lists: [pupils] (none for a class
/// without pupils), [saveIsAllowed] and [errorMessage], after the class's
/// fields when [classFields] is given.
String _classAnswer({
  String? classFields,
  List<String> pupils = const [],
  required bool saveIsAllowed,
  required String errorMessage,
}) =>
    '{${classFields ?? ''}$_schoolyear'
    '"errorMessage":${jsonEncode(errorMessage)},'
    '"pupils":[${pupils.join(',')}],"saveIsAllowed":$saveIsAllowed$_hours}';

final _listed = _classAnswer(
  classFields: _classFields(298, '1A '),
  pupils: [_pupil(11110, 35714, 'Test Pupil'), _pupil(11112, 35716, 'Pupil')],
  saveIsAllowed: true,
  errorMessage: '',
);

final _dayInTheFuture = _classAnswer(
  classFields: _classFields(298, '1A '),
  saveIsAllowed: false,
  errorMessage: _future,
);

final _classWithoutPupils = _classAnswer(
  classFields: _classFields(4882, '2F ECO'),
  saveIsAllowed: false,
  errorMessage: _noPupils,
);

final _unknownClass = _classAnswer(
  saveIsAllowed: false,
  errorMessage: _noPupils,
);

final _noLessonNow = _classAnswer(
  saveIsAllowed: false,
  errorMessage: _noLesson,
);

/// A Smartschool whose Presence module answers `getClass` with
/// [classAnswers], by `<classID> <startDate>`.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.classAnswers, {this.config = _configJson});

  final Map<String, String> classAnswers;

  /// The answer to `getConfig`.
  final String config;

  /// Every request, as `METHOD path`.
  final List<String> log = [];

  /// The fields of each `getClass`.
  final List<Map<String, String>> classRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');
    switch (path) {
      case _getConfig:
        return _json(config);
      case _getAllCodes:
        return _json(_codesJson);
      case _getClass:
        final fields = {
          for (final MapEntry(:key, :value) in (options.data as Map).entries)
            '$key': '$value',
        };
        classRequests.add(fields);
        final answer =
            classAnswers['${fields['classID']} ${fields['startDate']}'];
        return answer == null ? _json('{}', status: 404) : _json(answer);
      case _save:
        return _json('{"hasErrors":false,"errors":[]}');
    }
    return _json('{}', status: 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, {int status = 200}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  forbidRealNetwork();

  Future<(PresenceService, _Smartschool)> serve(
    Map<String, String> classAnswers, {
    String config = _configJson,
  }) async {
    final server = _Smartschool(classAnswers, config: config);
    final client = await SmartschoolClient.create(
      AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return (PresenceService(client), server);
  }

  Future<PresenceClassPupils> classPupils(
    PresenceService presence,
    int classGroupId,
    DateTime date,
  ) => presence.getClassPupils(
    classGroupId: classGroupId,
    date: date,
    schoolyearRefDate: '2026-11-05',
  );

  group('getClassPupils says why the module lists no pupils (#104)', () {
    test('a class it lists: the pupils, saveIsAllowed true, no reason, and '
        'the class as the module names it', () async {
      final (presence, server) = await serve({'298 2026-10-01': _listed});

      final pupils = await classPupils(presence, 298, DateTime(2026, 10, 1));

      expect(pupils, isA<List<PresencePupil>>());
      expect(pupils.map((p) => p.userId), [11110, 11112]);
      expect(pupils.first.halfDayFor(DayPart.morning)?.codeId, 70);
      expect(pupils.saveIsAllowed, isTrue);
      expect(pupils.errorMessage, isNull, reason: 'the module answers ""');
      expect(pupils.classRef?.groupId, 298);
      expect(pupils.classRef?.name, '1A');
      expect(pupils.classRef?.structId, 311);
      expect(pupils.classRef?.userCanRecord, isTrue);
      // The same single request as before.
      expect(server.log, ['POST $_getClass']);
      expect(server.classRequests.single, {
        'classID': '298',
        'startDate': '2026-10-01',
        'endDate': '2026-10-01',
        'schoolyearRefDate': '2026-11-05',
        'includePupils': '1',
        'includePresences': '1',
      });
    });

    test('a day after today: no pupils, saveIsAllowed false and the '
        "module's reason, with the class", () async {
      // Before the fix: an empty list, as for a class without pupils.
      final (presence, _) = await serve({'298 2026-11-03': _dayInTheFuture});

      final pupils = await classPupils(presence, 298, DateTime(2026, 11, 3));

      expect(pupils, isEmpty);
      expect(pupils.saveIsAllowed, isFalse);
      expect(pupils.errorMessage, _future);
      expect(pupils.classRef?.groupId, 298);
    });

    test('a class without pupils and a class ID the module does not know: '
        'the same reason, told apart by the class', () async {
      final (presence, _) = await serve({
        '4882 2026-10-01': _classWithoutPupils,
        '99999 2026-10-01': _unknownClass,
      });

      final empty = await classPupils(presence, 4882, DateTime(2026, 10, 1));
      final unknown = await classPupils(presence, 99999, DateTime(2026, 10, 1));

      expect(empty, isEmpty);
      expect(empty.saveIsAllowed, isFalse);
      expect(empty.errorMessage, _noPupils);
      expect(empty.classRef?.groupId, 4882);
      expect(empty.classRef?.name, '2F ECO');

      expect(unknown, isEmpty);
      expect(unknown.saveIsAllowed, isFalse);
      expect(unknown.errorMessage, _noPupils);
      expect(unknown.classRef, isNull);
    });

    test('the class -2 of a teacher who has no lesson now: no pupils, its '
        'reason, and no class', () async {
      final (presence, _) = await serve({'-2 2026-10-01': _noLessonNow});
      final config = await presence.getConfig();

      // The config gives it as its placeholder, not as a class (#117).
      final pupils = await classPupils(
        presence,
        config.activePlaceholder!.groupId,
        DateTime(2026, 10, 1),
      );

      expect(config.activePlaceholder!.groupId, -2);
      expect(pupils, isEmpty);
      expect(pupils.saveIsAllowed, isFalse);
      expect(pupils.errorMessage, _noLesson);
      expect(pupils.classRef, isNull);
    });

    test('an answer without saveIsAllowed or errorMessage: null for both, '
        'not a made-up value', () async {
      final (presence, _) = await serve({
        '298 2026-10-01':
            '{"groupID":298,"structID":311,"pupils":['
            '${_pupil(11110, 35714, 'Test Pupil')}]}',
        '298 2026-10-02': '{"pupils":[]}',
      });

      final listed = await classPupils(presence, 298, DateTime(2026, 10, 1));
      final empty = await classPupils(presence, 298, DateTime(2026, 10, 2));

      expect(listed.single.userId, 11110);
      expect(listed.saveIsAllowed, isNull);
      expect(listed.errorMessage, isNull);
      expect(listed.classRef?.groupId, 298);
      expect(empty, isEmpty);
      expect(empty.saveIsAllowed, isNull);
      expect(empty.errorMessage, isNull);
      expect(empty.classRef, isNull);
    });

    test('a caller tells the pupils of a class, a class or day the module '
        'lists none for, and a class it does not know apart', () async {
      // What an app such as smartschool-mcp's list_class_presences says.
      String describe(PresenceClassPupils pupils) {
        if (pupils.isNotEmpty) return '${pupils.length} pupils';
        final reason = pupils.errorMessage ?? 'no reason given';
        if (pupils.classRef == null) return 'no such class: $reason';
        return 'none listed: $reason';
      }

      final (presence, _) = await serve({
        '298 2026-10-01': _listed,
        '298 2026-11-03': _dayInTheFuture,
        '4882 2026-10-01': _classWithoutPupils,
        '99999 2026-10-01': _unknownClass,
      });

      expect(
        [
          describe(await classPupils(presence, 298, DateTime(2026, 10, 1))),
          describe(await classPupils(presence, 298, DateTime(2026, 11, 3))),
          describe(await classPupils(presence, 4882, DateTime(2026, 10, 1))),
          describe(await classPupils(presence, 99999, DateTime(2026, 10, 1))),
        ],
        [
          '2 pupils',
          'none listed: $_future',
          'none listed: $_noPupils',
          'no such class: $_noPupils',
        ],
      );
    });

    test('the result is a List<PresencePupil> as before: it can be sorted, '
        'filtered, added to and emptied', () async {
      final (presence, _) = await serve({'298 2026-10-01': _listed});

      final List<PresencePupil> pupils = await classPupils(
        presence,
        298,
        DateTime(2026, 10, 1),
      );
      pupils.sort((a, b) => b.userId.compareTo(a.userId));
      pupils.add(const PresencePupil(userId: 1, movementId: 2, name: 'New'));
      pupils.insert(0, const PresencePupil(userId: 3, movementId: 4, name: ''));

      expect(pupils.map((p) => p.userId), [3, 11112, 11110, 1]);
      expect(pupils.where((p) => p.userId > 10000), hasLength(2));
      pupils.removeWhere((p) => p.userId < 10);
      expect(pupils.map((p) => p.userId), [11112, 11110]);
      pupils.clear();
      expect(pupils, isEmpty);
    });
  });

  group('setLate / setPresent for a pupil the module does not list (#104, '
      '#116)', () {
    /// A [SmartschoolPresencePupilNotFoundError] (#116), which existing
    /// `catch` clauses for [SmartschoolPresenceError] keep catching.
    Matcher notListed({
      required int userId,
      required String date,
      required bool? saveIsAllowed,
      required String? errorMessage,
      required String message,
    }) => allOf(
      isA<SmartschoolPresenceError>(),
      isA<SmartschoolPresencePupilNotFoundError>()
          .having((e) => e.userId, 'userId', userId)
          .having((e) => e.classGroupId, 'classGroupId', 298)
          .having((e) => e.date, 'date', date)
          .having((e) => e.saveIsAllowed, 'saveIsAllowed', saveIsAllowed)
          .having((e) => e.errorMessage, 'errorMessage', errorMessage)
          .having((e) => e.message, 'message', message),
    );

    test("a day after today: the error has the module's reason and "
        'saveIsAllowed, and nothing is saved', () async {
      // Before #104: "Pupil userID 11110 was not found in class groupID 298
      // on 2026-11-03.", without the reason. Before #116: a plain
      // SmartschoolPresenceError, with the reason in its message only.
      final (presence, server) = await serve({
        '298 2026-11-03': _dayInTheFuture,
      }, config: _configWithHalfDayRight);

      await expectLater(
        presence.setLate(
          userId: 11110,
          classGroupId: 298,
          date: DateTime(2026, 11, 3),
          part: DayPart.morning,
        ),
        throwsA(
          notListed(
            userId: 11110,
            date: '2026-11-03',
            saveIsAllowed: false,
            errorMessage: _future,
            message:
                'Pupil userID 11110 was not found in class groupID 298 on '
                '2026-11-03: the Presence module listed no pupils '
                '("$_future").',
          ),
        ),
      );
      expect(server.log, isNot(contains('POST $_save')));
    });

    test('a class it lists, without the pupil: the message as before, '
        'without a reason, and no saveIsAllowed', () async {
      final (presence, server) = await serve({
        '298 2026-10-01': _listed,
      }, config: _configWithHalfDayRight);

      await expectLater(
        presence.setPresent(
          userId: 42,
          classGroupId: 298,
          date: DateTime(2026, 10, 1),
          part: DayPart.afternoon,
        ),
        throwsA(
          notListed(
            userId: 42,
            date: '2026-10-01',
            saveIsAllowed: null,
            errorMessage: null,
            message:
                'Pupil userID 42 was not found in class groupID 298 on '
                '2026-10-01.',
          ),
        ),
      );
      expect(server.log, isNot(contains('POST $_save')));
    });
  });

  group('getConfig keeps the placeholder class -2 apart from the classes '
      '(#117)', () {
    /// The classes of the account, as a caller such as smartschool-mcp's
    /// `presenceClasses` (yvanvds/smartschool-mcp#84) lists them: the allowed
    /// classes, plus the active class when it is not among them, as
    /// [PresenceConfig.classForGroup] finds them; without its workaround,
    /// which left out an active class with a `groupId` below 1.
    List<PresenceClassRef> classesOf(PresenceConfig config) => [
      ...config.allowedClasses,
      if (config.activeClass case final active?
          when !config.allowedClasses.any((c) => c.groupId == active.groupId))
        active,
    ];

    /// A config whose active class is 2F ECO, a class of the account that it
    /// may view but not record for, and not among its allowed classes.
    const withLesson = '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"groupID":4882,"name":"2F ECO ","adminNumber":6250,
   "isOfficial":1,"userCanConfirm":false,"userCanRecord":false,
   "instituteNumber":125252,"structID":311},"schoolyear":"2026-11-05"},
 "main":{"allowedClasses":[
   {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
    "userCanConfirm":false,"userCanRecord":true,"instituteNumber":125252,
    "structID":311}]}}
''';

    test('a teacher without a lesson now: the classes of the account are its '
        'allowed classes, without "Uit Planner"', () async {
      // Before the fix: [298, -2], "Uit Planner" listed as a class.
      final (presence, server) = await serve(const {});

      final config = await presence.getConfig();
      final classes = classesOf(config);

      expect(classes.map((c) => c.groupId), [298]);
      expect(classes.map((c) => c.name), ['1A']);
      expect(config.activeClass, isNull);
      expect(config.classForGroup(-2), isNull);
      for (final c in classes) {
        expect(config.classForGroup(c.groupId), same(c));
      }
      expect(server.log, ['POST $_getConfig']);
    });

    test('the placeholder is still there, apart: a caller can tell that the '
        'teacher has no lesson now', () async {
      final (presence, _) = await serve({'-2 2026-10-01': _noLessonNow});

      final config = await presence.getConfig();
      final placeholder = config.activePlaceholder;

      expect(placeholder?.groupId, -2);
      expect(placeholder?.name, 'Uit Planner');
      expect(placeholder?.isPlaceholder, isTrue);
      // What the module says for it, read with its groupId.
      final pupils = await classPupils(
        presence,
        placeholder!.groupId,
        DateTime(2026, 10, 1),
      );
      expect(pupils, isEmpty);
      expect(pupils.errorMessage, _noLesson);
    });

    test('a teacher with a lesson now: its class is the active class, and '
        'listed with the classes of the account', () async {
      final (presence, _) = await serve(const {}, config: withLesson);

      final config = await presence.getConfig();

      expect(config.activeClass?.groupId, 4882);
      expect(config.activeClass?.isPlaceholder, isFalse);
      expect(config.activePlaceholder, isNull);
      expect(classesOf(config).map((c) => c.name), ['1A', '2F ECO']);
      expect(config.classForGroup(4882)?.userCanRecord, isFalse);
    });

    test('setLate for the class -2: not among the classes of the account, '
        'and nothing but the config is read', () async {
      // Before the fix: classForGroup(-2) returned the placeholder, and the
      // call failed on it as on a class: "Class groupID -2 has no structID
      // (it looks like a virtual grouping class, not an official class)."
      final (presence, server) = await serve({'-2 2026-10-01': _noLessonNow});

      await expectLater(
        presence.setLate(
          userId: 11110,
          classGroupId: -2,
          date: DateTime(2026, 10, 1),
          part: DayPart.morning,
        ),
        throwsA(
          isA<SmartschoolPresenceError>()
              .having(
                (e) => e,
                'type',
                isNot(isA<SmartschoolPresencePupilNotFoundError>()),
              )
              .having(
                (e) => e.message,
                'message',
                'Class groupID -2 is not among the classes this account may '
                    'record presences for.',
              ),
        ),
      );
      expect(server.log, ['POST $_getConfig']);
    });
  });
}
