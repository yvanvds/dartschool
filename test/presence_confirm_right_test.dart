// Regression tests for issue #121: for a teacher without the right to set
// half-days, `getConfig` listed every class with `userCanRecord: true`,
// which PresenceClassRef documented as "may record presences for this
// class"; `setLate` / `setPresent` read the config, the codes and the class,
// and sent the save, which the module refused. A caller that gated the write
// on `userCanRecord` (as smartschool-mcp did, yvanvds/smartschool-mcp#95)
// offered a write the module refuses, and the refusal only came from the
// save.
//
// Seen live (2026-10-04, one teacher account, flutter_smartschool 0.3.3):
//
// - with its absence-administrator rights switched off: `getConfig` listed
//   88 classes, `userCanRecord` true for all 88, `userCanConfirm` for none;
//   `getClass` for 1A listed its pupils; a `setLate` for the school's test
//   pupil in 1A (approved by the developer, on a test account) was refused
//   by the module with "U heeft geen rechten om afwezigheden te bevestigen
//   voor deze leerling. Contacteer uw beheerder.", and nothing was saved;
// - with them switched on (read-only, the same day): `getConfig` listed 120
//   classes, both flags true for all of them, its active class 1A too.
//
// So `userCanConfirm` is the right to set a half-day. Now `setLate` and
// `setPresent` refuse a class without it with a
// SmartschoolPresenceNoConfirmRightError before anything is sent: they read
// only the config (again, when they had one from before the call, so that
// rights granted during the session count).
//
// The fake Smartschool below answers `getConfig` with the trimmed captures
// (classes and flags as captured; nothing else of the answer is used), and a
// save as the module answers one (the shape its web client reads, #109): for
// an account without the right with the module's reason as seen live.
// Its pupil is made up.
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

/// The day and half-day of the live refusal.
const _day = '2026-10-02';
final _date = DateTime(2026, 10, 2);

const _classId = 298;
const _pupilId = 1001;

const _aanwezig = 70;
const _teLaat = 497;

/// The module's reason for refusing the save of an account without the
/// right, as seen live (2026-10-04).
const _noRight =
    'U heeft geen rechten om afwezigheden te bevestigen voor deze leerling. '
    'Contacteer uw beheerder.';

/// `getConfig` for the account with its absence-administrator rights
/// switched off, trimmed to 1A (of 88 classes), in the shape captured so on
/// 2026-10-03 (presence_class_pupils_test.dart): `userCanRecord` but not
/// `userCanConfirm`, and the placeholder class -2 as its active class
/// (#117).
const _rightsOff = '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"adminNumber":null,"groupID":-2,"instituteNumber":0,
   "name":"Uit Planner","structID":null,"studierichting":"",
   "userCanConfirm":false},"schoolyear":"2026-11-05"},
 "main":{"allowedClasses":[
   {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
    "userCanConfirm":false,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311}]}}
''';

/// `getConfig` for the same account with the rights switched on, as
/// captured live (read-only, 2026-10-04), trimmed from 120 classes to 1A, a
/// virtual grouping class (2A) and an official sub-group (2A ECO): both
/// flags true for every class, the active class 1A too.
const _rightsOn = '''
{"hasErrors":false,"errors":[],"isAdmin":true,"canConfirm":true,
 "state":{"activeClass":{"groupID":298,"name":"1A ","adminNumber":6246,
   "isOfficial":1,"userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
   "instituteNumber":125252,"structID":311},"schoolyear":"2026-11-05"},
 "main":{"allowedClasses":[
   {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311},
   {"groupID":1650,"name":"2A  ","adminNumber":"","isOfficial":0,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":"","structID":"","downStreamGroups":[1968]},
   {"groupID":1968,"name":"2A ECO  ","adminNumber":40091,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311}]}}
''';

const _codesJson = '''
[{"codeID":70,"code":"|","name":"Aanwezig","structID":311,"alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","structID":311,"alias":[
   {"aliasID":14,"codeID":497,"code":"  ","name":"Te laat zonder geldige reden",
    "dateDeleted":null,"codeOrder":0}]}]
''';

/// A Smartschool whose Presence module lists one pupil in 1A, "Aanwezig" on
/// the morning of [_day], and refuses a save unless [rightsOn].
class _Smartschool implements HttpClientAdapter {
  _Smartschool({required this.rightsOn});

  /// Whether the account has its absence-administrator rights: the config
  /// the module gives, and whether it carries out a save. The developer can
  /// switch them during a session.
  bool rightsOn;

  /// Every request, as `METHOD path`.
  final List<String> log = [];

  /// The presences of every save, as sent.
  final List<Map<String, Object?>> saved = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');
    final form = {
      for (final MapEntry(:key, :value)
          in (options.data as Map? ?? const {}).entries)
        '$key': '$value',
    };
    switch (path) {
      case _getConfig:
        return _json(rightsOn ? _rightsOn : _rightsOff);
      case _getAllCodes:
        return _json(_codesJson);
      case _getClass:
        if (form['classID'] != '$_classId' || form['startDate'] != _day) {
          return _json('{"pupils":[],"saveIsAllowed":false}');
        }
        // As seen live for the account without the rights: the class, its
        // pupils and their half-days, and no refusal.
        return _json(
          jsonEncode({
            'groupID': _classId,
            'name': '1A  ',
            'structID': 311,
            'userCanConfirm': rightsOn,
            'userCanRecord': true,
            'errorMessage': '',
            'pupils': [
              {
                'movementID': 5001,
                'userID': _pupilId,
                'name': 'Peeters, Lotte',
                'presence': [_record(90001, _aanwezig)],
              },
            ],
            'saveIsAllowed': true,
          }),
        );
      case _save:
        final presences = [
          for (final pupil in (jsonDecode(form['pupils']!) as List))
            for (final presence in (pupil as Map)['presence'] as List)
              (presence as Map).cast<String, Object?>(),
        ];
        saved.addAll(presences);
        if (!rightsOn) {
          return _json(
            jsonEncode({
              'hasErrors': true,
              'errors': [
                for (final presence in presences)
                  {
                    'message': _noRight,
                    'presence': {...presence, 'pupil': 'Peeters, Lotte'},
                  },
              ],
            }),
          );
        }
        return _json(
          jsonEncode({
            'hasErrors': false,
            'errors': [],
            'pupils': [
              {
                'userID': _pupilId,
                'movementID': 5001,
                'presence': [
                  for (final presence in presences)
                    _record(
                      presence['presenceID'] as int? ?? 95001,
                      presence['codeID'] as int?,
                    ),
                ],
              },
            ],
          }),
        );
    }
    return _json('{}', status: 404);
  }

  Map<String, Object?> _record(int presenceId, int? codeId) => {
    'presenceID': presenceId,
    'presenceDate': _day,
    'studentID': _pupilId,
    'hourID': null,
    'partOfDay': 'am',
    'codeID': codeId,
    'aliasID': null,
    'motivation': null,
    'deleteStatus': 0,
  };

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

/// The reads and the save of a write that goes through.
const _write = [
  'POST $_getConfig',
  'POST $_getAllCodes',
  'POST $_getClass',
  'POST $_save',
];

void main() {
  forbidRealNetwork();

  Future<(PresenceService, _Smartschool)> serve({
    required bool rightsOn,
  }) async {
    final server = _Smartschool(rightsOn: rightsOn);
    final client = await SmartschoolClient.create(
      AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return (PresenceService(client), server);
  }

  /// The refusal for the morning of [_day] of [_pupilId] in 1A: a
  /// [SmartschoolPresenceNoConfirmRightError], which existing `catch`
  /// clauses for [SmartschoolPresenceError] keep catching, and none of its
  /// other subtypes.
  Matcher noRight({DayPart part = DayPart.morning}) => allOf(
    isA<SmartschoolPresenceError>(),
    isNot(isA<SmartschoolPresenceChangeRefusedError>()),
    isNot(isA<SmartschoolPresencePupilNotFoundError>()),
    isA<SmartschoolPresenceNoConfirmRightError>()
        .having((e) => e.userId, 'userId', _pupilId)
        .having((e) => e.classGroupId, 'classGroupId', _classId)
        .having((e) => e.date, 'date', _day)
        .having((e) => e.part, 'part', part)
        .having((e) => e.classRef.groupId, 'classRef.groupId', _classId)
        .having((e) => e.classRef.name, 'classRef.name', '1A')
        .having((e) => e.classRef.userCanRecord, 'userCanRecord', isTrue)
        .having((e) => e.classRef.userCanConfirm, 'userCanConfirm', isFalse)
        .having((e) => e.errors, 'errors', isEmpty)
        .having((e) => e.saveErrors, 'saveErrors', isEmpty)
        .having(
          (e) => e.message,
          'message',
          'This account may not set the half-days of class groupID 298 '
              '("1A"): getConfig gives it userCanConfirm false, and the '
              'Presence module refuses such a save ("geen rechten om '
              'afwezigheden te bevestigen"). Nothing was sent for the '
              '${part.name} of $_day of pupil userID $_pupilId.',
        ),
  );

  group('an account without the right to set half-days (#121)', () {
    test('the issue: setLate for a class with userCanRecord but without '
        'userCanConfirm is refused before anything is sent', () async {
      // Before the fix: the call read the codes and the class and sent the
      // save, which the module refused: a plain SmartschoolPresenceError
      // with the module's reason in its saveErrors.
      final (presence, server) = await serve(rightsOn: false);

      await expectLater(
        presence.setLate(
          userId: _pupilId,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
        ),
        throwsA(noRight()),
      );
      expect(server.log, ['POST $_getConfig']);
      expect(server.saved, isEmpty);
    });

    test('setPresent and setLate without a valid reason are refused the same '
        'way', () async {
      final (presence, server) = await serve(rightsOn: false);

      await expectLater(
        presence.setPresent(
          userId: _pupilId,
          classGroupId: _classId,
          date: _date,
          part: DayPart.afternoon,
          onlyReplacing: {PresenceService.lateCodeName},
        ),
        throwsA(noRight(part: DayPart.afternoon)),
      );
      await expectLater(
        presence.setLate(
          userId: _pupilId,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          withoutValidReason: true,
          motivation: 'Bus',
        ),
        throwsA(noRight()),
      );
      // The second call had the config from the first, and read it again
      // before refusing: the rights could have been switched on meanwhile.
      expect(server.log, ['POST $_getConfig', 'POST $_getConfig']);
      expect(server.saved, isEmpty);
    });

    test('a caller tells, from the config alone, which classes it may offer '
        'the write for: userCanConfirm, not userCanRecord', () async {
      final (presence, server) = await serve(rightsOn: false);

      final config = await presence.getConfig();

      // smartschool-mcp gated the write on userCanRecord: it offered 1A.
      expect(
        config.allowedClasses.where((c) => c.userCanRecord).map((c) => c.name),
        ['1A'],
      );
      // The flag of the right: none.
      expect(config.allowedClasses.where((c) => c.userCanConfirm), isEmpty);
      // And getClass lists the class's pupils for the account all the same:
      // reading is not the right.
      final pupils = await presence.getClassPupils(
        classGroupId: _classId,
        date: _date,
        schoolyearRefDate: config.schoolyearRefDate,
      );
      expect(pupils.map((p) => p.userId), [_pupilId]);
      expect(pupils.saveIsAllowed, isTrue);
      expect(server.saved, isEmpty);
    });
  });

  group('an account with the right (#121)', () {
    test('the config as captured: userCanConfirm for every class, and '
        'setLate saves', () async {
      final (presence, server) = await serve(rightsOn: true);

      final config = await presence.getConfig();
      expect(config.allowedClasses.map((c) => (c.name, c.userCanConfirm)), [
        ('1A', true),
        ('2A', true),
        ('2A ECO', true),
      ]);
      expect(config.activeClass?.userCanConfirm, isTrue);

      final saved = await presence.setLate(
        userId: _pupilId,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
      );

      expect(saved?.codeId, _teLaat);
      expect(saved?.before?.codeId, _aanwezig);
      // The config of the caller's read is used: the right is there.
      expect(server.log, ['POST $_getConfig', ..._write.skip(1)]);
    });

    test('rights switched on during the session: setLate reads the config '
        'again, and saves', () async {
      final (presence, server) = await serve(rightsOn: false);
      final before = await presence.getConfig();
      expect(before.classForGroup(_classId)?.userCanConfirm, isFalse);

      server.rightsOn = true;
      final saved = await presence.setLate(
        userId: _pupilId,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
      );

      expect(saved?.codeId, _teLaat);
      expect(server.log, ['POST $_getConfig', ..._write]);
      expect(
        (await presence.getConfig()).classForGroup(_classId)?.userCanConfirm,
        isTrue,
        reason: 'the config read again is the one kept',
      );
    });

    test('rights switched off after the config was read: the save goes out, '
        "and the module's refusal is a SmartschoolPresenceError with its "
        'reason', () async {
      // What stays: a config read while the account had the right is not
      // read again, so the module decides.
      final (presence, server) = await serve(rightsOn: true);
      await presence.getConfig();

      server.rightsOn = false;
      await expectLater(
        presence.setLate(
          userId: _pupilId,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
        ),
        throwsA(
          allOf(
            isA<SmartschoolPresenceError>(),
            isNot(isA<SmartschoolPresenceNoConfirmRightError>()),
            isA<SmartschoolPresenceError>().having(
              (e) => e.saveErrors.map((s) => (s.message, s.userId, s.part)),
              'saveErrors',
              [(_noRight, _pupilId, DayPart.morning)],
            ),
          ),
        ),
      );
      expect(server.log, ['POST $_getConfig', ..._write.skip(1)]);
    });
  });
}
