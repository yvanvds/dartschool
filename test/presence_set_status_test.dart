// Tests for issue #105: PresenceService.setLate and setPresent read the class
// (`getClass`) right before they save, then saved over whatever the half-day
// held, also an absence the secretariat recorded, such as a doctor's note
// ("Doktersattest", codeID 479), and returned nothing about what was stored.
//
// Now `onlyReplacing` names the statuses the half-day may hold, checked on
// the read right before the save, and a half-day that holds another one is
// refused with a SmartschoolPresenceChangeRefusedError before anything is
// sent; and both return the half-day as stored, from the save's answer.
//
// The fake Smartschool below keeps the half-days of one day and carries out
// a save on them. It answers in the shapes of the live module:
//
// - `getConfig`, `getAllCodes` and `getClass` as in the captures of
//   presence_service_flow_test.dart and presence_class_pupils_test.dart; the
//   school's codes as read live (read-only, 2026-10-03), trimmed: "Aanwezig"
//   (70), "Doktersattest" (479), "Te laat" (497) with its alias "Te laat
//   zonder geldige reden" (14). A half-day held by the alias comes with
//   `codeID: null`, `aliasID: 14` and a `code` with `isAlias: true`, as read
//   live in a class's `getClass`.
// - the answer to `savePupilsPresences` as the module's web client reads it
//   (its Presence JavaScript, read-only): `{"pupils":[{"userID",
//   "movementID","presence":[...]}],"errors":[]}`, the pupils sent with
//   their records as stored, in the shape of `getClass`'s (a new
//   `presenceID` for a half-day without a record). A refused save has
//   `errors` of `{"message", "presence"}`: the reason, and the record that
//   was not saved with the pupil's name in its `pupil`, which the web
//   client's error dialog lists (#109). No save was sent to the live module
//   for these tests: what it answers is the web client's reading of it, and
//   the "saved records plus `errors: []`" of #2.
//
// Its pupils are made up.
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

/// The day of the tests, as in the issue.
const _day = '2026-06-01';
final _date = DateTime(2026, 6, 1);

const _classId = 298;

const _aanwezig = 70;
const _doktersattest = 479;
const _teLaat = 497;
const _zonderReden = 14;

/// A code that is not among the codes of the structure.
const _unknownCode = 999;

const _configJson = '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"groupID":-2,"name":"Uit Planner","structID":null},
   "schoolyear":"2026-05-15"},
 "main":{"allowedClasses":[{"groupID":298,"name":"1A  ","adminNumber":6246,
   "isOfficial":1,"userCanRecord":true,"instituteNumber":125252,
   "structID":311}]}}
''';

const _codesJson = '''
[{"codeID":70,"code":"|","name":"Aanwezig","structID":311,"alias":[]},
 {"codeID":479,"code":"D","name":"Doktersattest","structID":311,"alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","structID":311,"alias":[
   {"aliasID":14,"codeID":497,"code":"  ","name":"Te laat zonder geldige reden",
    "dateDeleted":null,"codeOrder":0}]}]
''';

/// The `code` the module gives with a record, as read live.
Map<String, Object?> _codeOf(int? codeId, int? aliasId) => switch ((
  codeId,
  aliasId,
)) {
  (null, _zonderReden) => {
    'codeID': _zonderReden,
    'aliasID': _zonderReden,
    'parentCodeID': _teLaat,
    'name': 'Te laat zonder geldige reden',
    'isAlias': true,
  },
  (_aanwezig, null) => {'codeID': _aanwezig, 'name': 'Aanwezig'},
  (_doktersattest, null) => {'codeID': _doktersattest, 'name': 'Doktersattest'},
  (_teLaat, null) => {'codeID': _teLaat, 'name': 'Te laat'},
  _ => {'codeID': codeId, 'name': 'Onbekend'},
};

/// A half-day of the fake: its record and what it holds.
class _Cell {
  _Cell(this.presenceId, {this.codeId, this.aliasId, this.motivation});

  final int presenceId;
  int? codeId;
  int? aliasId;
  String? motivation;
}

/// A pupil of class 1A: internal user ID, movement ID, name.
typedef _Pupil = (int userId, int movementId, String name);

const _peeters = 1001; // present in the morning and the afternoon
const _janssens = 1002; // nothing recorded
const _dupont = 1003; // a doctor's note in the morning
const _claes = 1004; // late in the morning, late without reason after noon
const _maes = 1005; // a code that is not the structure's in the morning

const _pupils = <_Pupil>[
  (_peeters, 5001, 'Peeters, Lotte'),
  (_janssens, 5002, 'Janssens, Emma'),
  (_dupont, 5003, 'Dupont, Noah'),
  (_claes, 5004, 'Claes, Mila'),
  (_maes, 5005, 'Maes, Finn'),
];

/// The name of the pupil [userId], as the module gives it.
String _nameOf(int userId) => _pupils.firstWhere((p) => p.$1 == userId).$3;

/// The reason the fake gives for a save it refuses.
const _refusal = 'De afwezigheid kon niet worden opgeslagen.';

/// How the fake answers a save.
enum _SaveAnswer {
  /// Carried out, answered with the records as stored and no errors.
  records,

  /// Carried out, answered with no errors but without the records.
  noRecords,

  /// Not carried out, answered with an error per presence sent.
  refused,
}

/// A Smartschool whose Presence module holds the half-days of [_day] for
/// class 1A, and carries out a save on them.
class _Smartschool implements HttpClientAdapter {
  _Smartschool() {
    cells[(_peeters, 'am')] = _Cell(90001, codeId: _aanwezig);
    cells[(_peeters, 'pm')] = _Cell(90002, codeId: _aanwezig);
    cells[(_dupont, 'am')] = _Cell(90005, codeId: _doktersattest);
    cells[(_dupont, 'pm')] = _Cell(90006, codeId: _aanwezig);
    cells[(_claes, 'am')] = _Cell(90007, codeId: _teLaat, motivation: 'Bus');
    cells[(_claes, 'pm')] = _Cell(90008, aliasId: _zonderReden);
    cells[(_maes, 'am')] = _Cell(90009, codeId: _unknownCode);
  }

  /// The half-days of [_day], by pupil and part (`am`, `pm`).
  final Map<(int, String), _Cell> cells = {};

  _SaveAnswer saveAnswer = _SaveAnswer.records;

  int _nextPresenceId = 95001;

  /// Every request, as `METHOD path`.
  final List<String> log = [];

  /// The presences of every save, as sent, with the pupil's `userID`.
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
        return _json(_configJson);
      case _getAllCodes:
        return _json(_codesJson);
      case _getClass:
        if (form['classID'] != '$_classId' || form['startDate'] != _day) {
          return _json('{"pupils":[],"saveIsAllowed":false}');
        }
        return _json(jsonEncode(_classAnswer()));
      case _save:
        return _json(jsonEncode(_saveAnswerFor(form['pupils']!)));
    }
    return _json('{}', status: 404);
  }

  Map<String, Object?> _record(int userId, String part, _Cell cell) => {
    'presenceID': cell.presenceId,
    'presenceDate': _day,
    'studentID': userId,
    'hourID': null,
    'partOfDay': part,
    'codeID': cell.codeId,
    'aliasID': cell.aliasId,
    'motivation': cell.motivation,
    'deleteStatus': 0,
    'code': _codeOf(cell.codeId, cell.aliasId),
  };

  Map<String, Object?> _classAnswer() => {
    'groupID': _classId,
    'name': '1A  ',
    'structID': 311,
    'userCanRecord': true,
    'errorMessage': '',
    'pupils': [
      for (final (userId, movementId, name) in _pupils)
        {
          'movementID': movementId,
          'userID': userId,
          'name': name,
          'presence': [
            for (final part in ['am', 'pm'])
              if (cells[(userId, part)] case final cell?)
                _record(userId, part, cell),
          ],
        },
    ],
    'saveIsAllowed': true,
  };

  Map<String, Object?> _saveAnswerFor(String pupilsJson) {
    final pupils = (jsonDecode(pupilsJson) as List)
        .cast<Map<String, Object?>>();
    final answered = <Map<String, Object?>>[];
    final errors = <Map<String, Object?>>[];
    for (final pupil in pupils) {
      final userId = pupil['userID']! as int;
      final records = <Map<String, Object?>>[];
      for (final presence
          in (pupil['presence']! as List).cast<Map<String, Object?>>()) {
        saved.add({'userID': userId, ...presence});
        final part = presence['partOfDay']! as String;
        if (saveAnswer == _SaveAnswer.refused) {
          errors.add({
            'message': _refusal,
            'presence': {...presence, 'pupil': _nameOf(userId)},
          });
          continue;
        }
        final motivation = presence['motivation'] as String? ?? '';
        final cell = cells[(userId, part)] ??= _Cell(_nextPresenceId++);
        cell
          ..codeId = presence['codeID'] as int?
          ..aliasId = presence['aliasID'] as int?
          // The module sends an empty motivation as null.
          ..motivation = motivation.isEmpty ? null : motivation;
        records.add(_record(userId, part, cell));
      }
      answered.add({
        'userID': userId,
        'movementID': pupil['movementID'],
        'presence': records,
      });
    }
    return {
      'hasErrors': errors.isNotEmpty,
      'errors': errors,
      if (saveAnswer != _SaveAnswer.noRecords) 'pupils': answered,
    };
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

/// What smartschool-mcp's `set_pupils_late` lets a write replace.
const _replaceable = {
  PresenceService.nothingRecorded,
  PresenceService.presentCodeName,
  PresenceService.lateCodeName,
  PresenceService.lateWithoutReasonAliasName,
};

/// The reads of a write, before its save.
const _reads = ['POST $_getConfig', 'POST $_getAllCodes', 'POST $_getClass'];

void main() {
  forbidRealNetwork();

  Future<(PresenceService, _Smartschool)> serve() async {
    final server = _Smartschool();
    final client = await SmartschoolClient.create(
      AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return (PresenceService(client), server);
  }

  TypeMatcher<SmartschoolPresenceChangeRefusedError> refused({
    required int userId,
    required DayPart part,
    required Object? heldStatus,
    required Object? message,
  }) => isA<SmartschoolPresenceChangeRefusedError>()
      .having((e) => e.userId, 'userId', userId)
      .having((e) => e.part, 'part', part)
      .having((e) => e.date, 'date', _day)
      .having((e) => e.heldStatus, 'heldStatus', heldStatus)
      .having((e) => e.errors, 'errors', isEmpty)
      .having((e) => e.message, 'message', message);

  group('onlyReplacing refuses a half-day that holds another status, before '
      'anything is sent (#105)', () {
    test('the issue: setLate over a doctor\'s note is refused, and names '
        'it', () async {
      // Before the fix: no onlyReplacing; setLate saved "Te laat" over the
      // doctor's note.
      final (presence, server) = await serve();

      await expectLater(
        presence.setLate(
          userId: _dupont,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: _replaceable,
        ),
        throwsA(
          allOf(
            isA<SmartschoolPresenceError>(),
            refused(
              userId: _dupont,
              part: DayPart.morning,
              heldStatus: 'Doktersattest',
              message:
                  'The morning of 2026-06-01 of pupil userID 1003 in class '
                  'groupID 298 holds "Doktersattest", which onlyReplacing does '
                  'not allow (nothing recorded, "Aanwezig", "Te laat", "Te '
                  'laat zonder geldige reden"): nothing was sent.',
            ).having(
              (e) =>
                  (e.halfDay?.presenceId, e.halfDay?.codeId, e.onlyReplacing),
              'halfDay, onlyReplacing',
              (90005, _doktersattest, _replaceable),
            ),
          ),
        ),
      );
      expect(server.log, _reads, reason: 'no save');
      expect(server.cells[(_dupont, 'am')]!.codeId, _doktersattest);
    });

    test('setPresent over a doctor\'s note is refused too', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setPresent(
          userId: _dupont,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: {
            PresenceService.lateCodeName,
            PresenceService.lateWithoutReasonAliasName,
          },
        ),
        throwsA(
          refused(
            userId: _dupont,
            part: DayPart.morning,
            heldStatus: 'Doktersattest',
            message: contains('holds "Doktersattest"'),
          ),
        ),
      );
      expect(server.saved, isEmpty);
    });

    test('the check is on the read right before the save, not on a read the '
        'caller made earlier', () async {
      final (presence, server) = await serve();
      final config = await presence.getConfig();
      final earlier = await presence.getClassPupils(
        classGroupId: _classId,
        date: _date,
        schoolyearRefDate: config.schoolyearRefDate,
      );
      final peeters = earlier.firstWhere((p) => p.userId == _peeters);
      expect(peeters.halfDayFor(DayPart.morning)?.codeId, _aanwezig);

      // Meanwhile, the secretariat records a doctor's note.
      server.cells[(_peeters, 'am')]!.codeId = _doktersattest;

      await expectLater(
        presence.setLate(
          userId: _peeters,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: _replaceable,
        ),
        throwsA(
          refused(
            userId: _peeters,
            part: DayPart.morning,
            heldStatus: 'Doktersattest',
            message: contains('holds "Doktersattest"'),
          ),
        ),
      );
      expect(server.saved, isEmpty);
      expect(
        server.log.where((r) => r == 'POST $_getClass'),
        hasLength(2),
        reason: "the caller's read, and the call's own",
      );
    });

    test('nothing recorded is a status too: refused when not allowed', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setPresent(
          userId: _janssens,
          classGroupId: _classId,
          date: _date,
          part: DayPart.afternoon,
          onlyReplacing: {PresenceService.lateCodeName},
        ),
        throwsA(
          refused(
            userId: _janssens,
            part: DayPart.afternoon,
            heldStatus: PresenceService.nothingRecorded,
            message:
                'The afternoon of 2026-06-01 of pupil userID 1002 in class '
                'groupID 298 holds nothing recorded, which onlyReplacing does '
                'not allow ("Te laat"): nothing was sent.',
          ).having((e) => e.halfDay, 'halfDay', isNull),
        ),
      );
      expect(server.saved, isEmpty);
    });

    test('an alias is a status of its own, not its code\'s', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setPresent(
          userId: _claes,
          classGroupId: _classId,
          date: _date,
          part: DayPart.afternoon,
          onlyReplacing: {PresenceService.lateCodeName},
        ),
        throwsA(
          refused(
            userId: _claes,
            part: DayPart.afternoon,
            heldStatus: 'Te laat zonder geldige reden',
            message: contains('holds "Te laat zonder geldige reden"'),
          ),
        ),
      );
      expect(server.saved, isEmpty);
    });

    test('a code that is not among the structure\'s codes is never allowed, '
        'and named by its ID', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setLate(
          userId: _maes,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: _replaceable,
        ),
        throwsA(
          refused(
            userId: _maes,
            part: DayPart.morning,
            heldStatus: isNull,
            message: contains(
              'holds a status that is not among the codes of its school '
              'structure (codeID 999)',
            ),
          ),
        ),
      );
      expect(server.saved, isEmpty);
    });

    test('an empty onlyReplacing allows no status', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setLate(
          userId: _peeters,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: const {},
        ),
        throwsA(
          refused(
            userId: _peeters,
            part: DayPart.morning,
            heldStatus: 'Aanwezig',
            message: contains('does not allow (no status)'),
          ),
        ),
      );
      expect(server.saved, isEmpty);
    });

    test(
      'a caller tells the refusal apart from a save the module refused',
      () async {
        final (presence, server) = await serve();
        server.saveAnswer = _SaveAnswer.refused;

        Future<String> classify(Future<Object?> Function() call) async {
          try {
            await call();
            return 'saved';
          } on SmartschoolPresenceChangeRefusedError catch (e) {
            return 'left alone: ${e.heldStatus}';
          } on SmartschoolPresenceError {
            return 'refused by the module';
          }
        }

        expect(
          await classify(
            () => presence.setLate(
              userId: _dupont,
              classGroupId: _classId,
              date: _date,
              part: DayPart.morning,
              onlyReplacing: _replaceable,
            ),
          ),
          'left alone: Doktersattest',
        );
        expect(
          await classify(
            () => presence.setLate(
              userId: _peeters,
              classGroupId: _classId,
              date: _date,
              part: DayPart.morning,
              onlyReplacing: _replaceable,
            ),
          ),
          'refused by the module',
        );
        expect(
          server.saved,
          hasLength(1),
          reason: "only Peeters' save went out",
        );
      },
    );
  });

  group('onlyReplacing lets a half-day that holds an allowed status be '
      'changed (#105)', () {
    test('nothing recorded: the record is created', () async {
      final (presence, server) = await serve();

      final saved = await presence.setLate(
        userId: _janssens,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
        motivation: 'Overslept',
        onlyReplacing: _replaceable,
      );

      expect(server.log, [..._reads, 'POST $_save']);
      expect(server.saved.single, containsPair('presenceID', null));
      expect(saved, isA<PresenceSavedHalfDay>());
      expect(saved!.presenceId, 95001, reason: 'the new record');
      expect(saved.presenceDate, _day);
      expect(saved.part, DayPart.morning);
      expect((saved.codeId, saved.aliasId), (_teLaat, null));
      expect(saved.motivation, 'Overslept');
      expect(saved.before, isNull, reason: 'no record before');
    });

    test(
      '"Aanwezig": late without a valid reason is stored as the alias',
      () async {
        final (presence, server) = await serve();

        final saved = await presence.setLate(
          userId: _peeters,
          classGroupId: _classId,
          date: _date,
          part: DayPart.afternoon,
          withoutValidReason: true,
          onlyReplacing: _replaceable,
        );

        expect(server.saved.single, containsPair('presenceID', 90002));
        expect(saved!.presenceId, 90002);
        expect((saved.codeId, saved.aliasId), (null, _zonderReden));
        expect(saved.motivation, isEmpty);
        expect(saved.before?.presenceId, 90002);
        expect(saved.before?.codeId, _aanwezig);
      },
    );

    test('the alias, by its own name: setPresent clears it', () async {
      final (presence, _) = await serve();

      final saved = await presence.setPresent(
        userId: _claes,
        classGroupId: _classId,
        date: _date,
        part: DayPart.afternoon,
        onlyReplacing: {PresenceService.lateWithoutReasonAliasName},
      );

      expect((saved!.codeId, saved.aliasId), (_aanwezig, null));
      expect(
        (saved.before?.codeId, saved.before?.aliasId),
        (null, _zonderReden),
      );
    });

    test('names are compared trimmed and case-insensitively', () async {
      final (presence, server) = await serve();

      final saved = await presence.setLate(
        userId: _claes,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
        motivation: 'Bus again',
        onlyReplacing: {' te LAAT '},
      );

      expect(server.saved, hasLength(1));
      expect(saved!.before?.motivation, 'Bus');
      expect(saved.motivation, 'Bus again');
    });
  });

  group('a save the module refuses (#109)', () {
    test("the module's reason, as text and typed with the record, and no "
        "pupil's name in the error's text", () async {
      // Before the fix: errors held each error object's Map.toString(),
      // "{message: ..., presence: {..., pupil: Peeters, Lotte}}", also in
      // the error's toString(), which ends up in logs.
      final (presence, server) = await serve();
      server.saveAnswer = _SaveAnswer.refused;

      late SmartschoolPresenceError error;
      try {
        await presence.setLate(
          userId: _peeters,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: _replaceable,
        );
        fail('the save was refused');
      } on SmartschoolPresenceError catch (e) {
        error = e;
      }

      expect(error, isNot(isA<SmartschoolPresenceChangeRefusedError>()));
      expect(server.log, [..._reads, 'POST $_save']);
      expect(server.cells[(_peeters, 'am')]!.codeId, _aanwezig);

      expect(error.errors, [_refusal]);
      expect(
        error.toString(),
        'SmartschoolPresenceError: Saving the presence for userID 1001 '
        'failed. (De afwezigheid kon niet worden opgeslagen.)',
      );
      final saveError = error.saveErrors.single;
      expect(
        (saveError.message, saveError.userId, saveError.date, saveError.part),
        (_refusal, _peeters, _day, DayPart.morning),
      );
      expect(saveError.pupilName, 'Peeters, Lotte', reason: 'kept as a field');
      for (final text in [error.message, '$error', '$saveError']) {
        expect(text, isNot(contains('Peeters')));
        expect(text, isNot(contains('Lotte')));
      }
    });

    test('an app shows the reason once and the half-days it names, as the '
        'web client does', () async {
      final (presence, server) = await serve();
      server.saveAnswer = _SaveAnswer.refused;

      Future<String> report(Future<Object?> Function() call) async {
        try {
          await call();
          return 'saved';
        } on SmartschoolPresenceError catch (e) {
          // The reason once, then a line per half-day, with the pupil's
          // name from its field.
          return [
            e.saveErrors.first.message,
            for (final error in e.saveErrors)
              '${error.date} ${error.part?.wire} - ${error.pupilName}',
          ].join('\n');
        }
      }

      expect(
        await report(
          () => presence.setPresent(
            userId: _claes,
            classGroupId: _classId,
            date: _date,
            part: DayPart.afternoon,
          ),
        ),
        'De afwezigheid kon niet worden opgeslagen.\n'
        '2026-06-01 pm - Claes, Mila',
      );
      expect(server.cells[(_claes, 'pm')]!.aliasId, _zonderReden);
    });
  });

  group('setLate and setPresent return the half-day as stored (#105)', () {
    test('the stored half-day is what a read of the class shows after, '
        'without that read', () async {
      // Before the fix: both returned nothing, so a caller read the class
      // again to report what was stored.
      final (presence, server) = await serve();

      final saved = await presence.setLate(
        userId: _peeters,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
        motivation: 'Overslept',
      );
      expect(server.log, [..._reads, 'POST $_save'], reason: 'nothing more');

      final config = await presence.getConfig();
      final after = await presence.getClassPupils(
        classGroupId: _classId,
        date: _date,
        schoolyearRefDate: config.schoolyearRefDate,
      );
      final cell = after
          .firstWhere((p) => p.userId == _peeters)
          .halfDayFor(DayPart.morning, date: _day)!;
      expect(
        (saved!.presenceId, saved.codeId, saved.aliasId, saved.motivation),
        (cell.presenceId, cell.codeId, cell.aliasId, cell.motivation),
      );
      expect(
        PresenceService.statusNameOf(
          saved,
          await presence.getAllCodes(after.classRef!.structId!),
        ),
        PresenceService.lateCodeName,
      );
    });

    test('without onlyReplacing, it saves over any status, as before, and '
        'says what it replaced', () async {
      final (presence, server) = await serve();

      final saved = await presence.setLate(
        userId: _dupont,
        classGroupId: _classId,
        date: _date,
        part: DayPart.morning,
      );

      expect(server.saved, hasLength(1));
      expect(server.cells[(_dupont, 'am')]!.codeId, _teLaat);
      expect(saved!.codeId, _teLaat);
      expect(saved.before?.codeId, _doktersattest);
    });

    test(
      'an answer without the record: null, and nothing more is read',
      () async {
        final (presence, server) = await serve();
        server.saveAnswer = _SaveAnswer.noRecords;

        final saved = await presence.setPresent(
          userId: _claes,
          classGroupId: _classId,
          date: _date,
          part: DayPart.morning,
          onlyReplacing: {PresenceService.lateCodeName},
        );

        expect(saved, isNull);
        expect(server.log, [..._reads, 'POST $_save']);
        expect(
          server.cells[(_claes, 'am')]!.codeId,
          _aanwezig,
          reason: 'saved',
        );
      },
    );

    test('a caller can still take the call as a Future<void>', () async {
      final (presence, server) = await serve();
      Future<void> markLate() => presence.setLate(
        userId: _janssens,
        classGroupId: _classId,
        date: _date,
        part: DayPart.afternoon,
      );

      await markLate();

      expect(server.cells[(_janssens, 'pm')]!.codeId, _teLaat);
    });
  });
}
