// Tests for the Presence parsing / payload-building logic that can be validated
// offline (i.e. without a live Smartschool session).
//
// The JSON snippets below are trimmed captures of the real endpoints:
//   - Presence/Main/getConfig
//   - Presence/Code/getAllCodes
//   - Presence/Class/getClass
// with personal data reduced to fakes where practical.
//
// End-to-end verification (which performs a real save + restore against a test
// pupil) lives in `example/set_late_example.dart`.

import 'dart:convert';

import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/services/presence_service.dart';
import 'package:test/test.dart';

Map<String, dynamic> _obj(String src) =>
    jsonDecode(src) as Map<String, dynamic>;
List<dynamic> _arr(String src) => jsonDecode(src) as List<dynamic>;

void main() {
  // ---------------------------------------------------------------------------
  // DayPart
  // ---------------------------------------------------------------------------

  group('DayPart', () {
    test('wire values', () {
      expect(DayPart.morning.wire, 'am');
      expect(DayPart.afternoon.wire, 'pm');
    });

    test('fromWire maps am/pm and rejects the rest', () {
      expect(DayPart.fromWire('am'), DayPart.morning);
      expect(DayPart.fromWire('pm'), DayPart.afternoon);
      expect(DayPart.fromWire('none'), isNull);
      expect(DayPart.fromWire(null), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // parseConfig
  // ---------------------------------------------------------------------------

  group('PresenceService.parseConfig', () {
    const configJson = '''
    {
      "state": {
        "activeClass": {"groupID":298,"name":"1A ","adminNumber":6246,
          "isOfficial":1,"userCanConfirm":true,"userCanRecord":true,
          "instituteNumber":125252,"structID":311},
        "schoolyear": "2025-11-05"
      },
      "main": {
        "allowedClasses": [
          {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
           "userCanRecord":true,"instituteNumber":125252,"structID":311},
          {"groupID":1650,"name":"2A  ","adminNumber":"","isOfficial":0,
           "userCanRecord":true,"instituteNumber":"","structID":""}
        ]
      }
    }
    ''';

    late PresenceConfig config;
    setUpAll(() => config = PresenceService.parseConfig(_obj(configJson)));

    test('schoolyearRefDate', () {
      expect(config.schoolyearRefDate, '2025-11-05');
    });

    test('activeClass fields', () {
      expect(config.activeClass!.groupId, 298);
      expect(config.activeClass!.name, '1A'); // trailing padding trimmed
      expect(config.activeClass!.structId, 311);
      expect(config.activeClass!.adminNumber, 6246);
      expect(config.activeClass!.userCanRecord, isTrue);
      expect(config.activeClass!.isOfficial, isTrue);
    });

    test('allowedClasses count', () {
      expect(config.allowedClasses, hasLength(2));
    });

    test('classForGroup finds an official class', () {
      final c = config.classForGroup(298);
      expect(c, isNotNull);
      expect(c!.structId, 311);
    });

    test('virtual grouping class parses empty numbers as null', () {
      final virtual = config.classForGroup(1650)!;
      expect(virtual.structId, isNull);
      expect(virtual.adminNumber, isNull);
      expect(virtual.instituteNumber, isNull);
      expect(virtual.isOfficial, isFalse);
    });

    test('classForGroup returns null for unknown group', () {
      expect(config.classForGroup(99999), isNull);
    });

    test('handles missing state/main gracefully', () {
      final c = PresenceService.parseConfig({});
      expect(c.activeClass, isNull);
      expect(c.allowedClasses, isEmpty);
      expect(c.schoolyearRefDate, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // parseCodes + resolveCode
  // ---------------------------------------------------------------------------

  group('PresenceService.parseCodes', () {
    const codesJson = '''
    [
      {"codeID":70,"code":"|","name":"Aanwezig","alias":[]},
      {"codeID":497,"code":"L","name":"Te laat","alias":[
        {"aliasID":14,"codeID":497,"code":"  ",
         "name":"Te laat zonder geldige reden","codeOrder":0}
      ]},
      {"codeID":479,"code":"D","name":"Doktersattest","alias":[]}
    ]
    ''';

    late List<PresenceCode> codes;
    setUpAll(() => codes = PresenceService.parseCodes(_arr(codesJson)));

    test('parses all codes', () {
      expect(codes, hasLength(3));
    });

    test('Te laat carries its alias', () {
      final late = codes.firstWhere((c) => c.name == 'Te laat');
      expect(late.codeId, 497);
      expect(late.aliases, hasLength(1));
      expect(late.aliases.single.aliasId, 14);
      expect(late.aliases.single.parentCodeId, 497);
      expect(late.aliases.single.name, 'Te laat zonder geldige reden');
    });

    test('aliasByName is case-insensitive', () {
      final late = codes.firstWhere((c) => c.name == 'Te laat');
      expect(late.aliasByName('te laat zonder geldige reden'), isNotNull);
      expect(late.aliasByName('nope'), isNull);
    });
  });

  group('PresenceService.resolveCode', () {
    final codes = PresenceService.parseCodes(
      _arr('''
      [
        {"codeID":70,"code":"|","name":"Aanwezig","alias":[]},
        {"codeID":497,"code":"L","name":"Te laat","alias":[
          {"aliasID":14,"codeID":497,"name":"Te laat zonder geldige reden"}
        ]}
      ]
      '''),
    );

    test('plain code resolves to codeId with null alias', () {
      final r = PresenceService.resolveCode(codes, codeName: 'Te laat');
      expect(r.codeId, 497);
      expect(r.aliasId, isNull);
    });

    test('alias resolves to aliasId with null codeId', () {
      final r = PresenceService.resolveCode(
        codes,
        codeName: 'Te laat',
        aliasName: 'Te laat zonder geldige reden',
      );
      expect(r.codeId, isNull);
      expect(r.aliasId, 14);
    });

    test('present resolves', () {
      final r = PresenceService.resolveCode(codes, codeName: 'Aanwezig');
      expect(r.codeId, 70);
      expect(r.aliasId, isNull);
    });

    test('name matching is case-insensitive', () {
      final r = PresenceService.resolveCode(codes, codeName: 'te laat');
      expect(r.codeId, 497);
    });

    test('unknown code throws', () {
      expect(
        () => PresenceService.resolveCode(codes, codeName: 'Onbekend'),
        throwsA(isA<SmartschoolPresenceError>()),
      );
    });

    test('unknown alias throws', () {
      expect(
        () => PresenceService.resolveCode(
          codes,
          codeName: 'Te laat',
          aliasName: 'Onbekend',
        ),
        throwsA(isA<SmartschoolPresenceError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // parsePupils
  // ---------------------------------------------------------------------------

  group('PresenceService.parsePupils', () {
    // One enrolled pupil with am/pm half-day cells and per-lesson rows, plus a
    // departed pupil with an empty presence array.
    const classJson = '''
    {
      "groupID": 298,
      "structID": 311,
      "pupils": [
        {
          "movementID": 33046,
          "userID": 12326,
          "name": "Ahmed Hassan Mohamed",
          "presence": [
            {"presenceID":11725778,"presenceDate":"2026-06-01","studentID":12326,
             "hourID":null,"partOfDay":"am","codeID":70,"aliasID":null,
             "motivation":null,"deleteStatus":0},
            {"presenceID":11731166,"presenceDate":"2026-06-01","studentID":12326,
             "hourID":null,"partOfDay":"pm","codeID":70,"aliasID":null,
             "motivation":null,"deleteStatus":0},
            {"presenceID":11722686,"presenceDate":"2026-06-01","studentID":12326,
             "hourID":198,"partOfDay":"none","codeID":1,"aliasID":null,
             "motivation":null,"deleteStatus":0}
          ]
        },
        {
          "movementID": 36018,
          "userID": 12748,
          "name": "Departed Pupil",
          "presence": []
        }
      ]
    }
    ''';

    late List<PresencePupil> pupils;
    setUpAll(() => pupils = PresenceService.parsePupils(_obj(classJson)));

    test('parses both pupils', () {
      expect(pupils, hasLength(2));
    });

    test('extracts only the am/pm half-day cells (skips per-lesson rows)', () {
      final p = pupils.firstWhere((p) => p.userId == 12326);
      expect(p.movementId, 33046);
      expect(p.halfDays, hasLength(2));
      expect(
        p.halfDays.map((c) => c.part),
        containsAll(<DayPart>[DayPart.morning, DayPart.afternoon]),
      );
    });

    test('halfDayFor returns the matching cell', () {
      final p = pupils.firstWhere((p) => p.userId == 12326);
      final am = p.halfDayFor(DayPart.morning, date: '2026-06-01');
      expect(am, isNotNull);
      expect(am!.presenceId, 11725778);
      expect(am.codeId, 70);
    });

    test('halfDayFor returns null for a non-matching date', () {
      final p = pupils.firstWhere((p) => p.userId == 12326);
      expect(p.halfDayFor(DayPart.morning, date: '2020-01-01'), isNull);
    });

    test('departed pupil has no half-day cells (create case)', () {
      final p = pupils.firstWhere((p) => p.userId == 12748);
      expect(p.halfDays, isEmpty);
      expect(p.halfDayFor(DayPart.morning), isNull);
    });

    test('handles a body without pupils', () {
      expect(PresenceService.parsePupils({}), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // buildPupilsPayload
  // ---------------------------------------------------------------------------

  group('PresenceService.buildPupilsPayload', () {
    test('update case (existing presenceID) with a plain code', () {
      final payload = PresenceService.buildPupilsPayload(
        userId: 11110,
        movementId: 35714,
        presenceDate: '2026-06-01',
        part: DayPart.morning,
        presenceId: 11725816,
        codeId: 497,
        aliasId: null,
        motivation: '',
      );
      final decoded = jsonDecode(payload) as List;
      expect(decoded, hasLength(1));
      final pupil = decoded.single as Map<String, dynamic>;
      expect(pupil['userID'], 11110);
      expect(pupil['movementID'], 35714);
      final cell = (pupil['presence'] as List).single as Map<String, dynamic>;
      expect(cell['presenceID'], 11725816);
      expect(cell['studentID'], 11110);
      expect(cell['hourID'], isNull);
      expect(cell['partOfDay'], 'am');
      expect(cell['codeID'], 497);
      expect(cell['aliasID'], isNull);
      expect(cell['deleteStatus'], 0);
    });

    test('create case sends a null presenceID', () {
      final payload = PresenceService.buildPupilsPayload(
        userId: 11110,
        movementId: 35714,
        presenceDate: '2026-06-01',
        part: DayPart.afternoon,
        presenceId: null,
        codeId: 70,
        aliasId: null,
        motivation: 'note',
      );
      final cell =
          ((jsonDecode(payload) as List).single
                  as Map<String, dynamic>)['presence']
              as List;
      final entry = cell.single as Map<String, dynamic>;
      expect(entry.containsKey('presenceID'), isTrue);
      expect(entry['presenceID'], isNull);
      expect(entry['partOfDay'], 'pm');
      expect(entry['motivation'], 'note');
    });

    test('alias case sends null codeID + aliasID', () {
      final payload = PresenceService.buildPupilsPayload(
        userId: 11110,
        movementId: 35714,
        presenceDate: '2026-06-01',
        part: DayPart.afternoon,
        presenceId: 11725817,
        codeId: null,
        aliasId: 14,
        motivation: '',
      );
      final entry =
          (((jsonDecode(payload) as List).single
                          as Map<String, dynamic>)['presence']
                      as List)
                  .single
              as Map<String, dynamic>;
      expect(entry['codeID'], isNull);
      expect(entry['aliasID'], 14);
    });
  });

  // ---------------------------------------------------------------------------
  // parseSaveErrors
  // ---------------------------------------------------------------------------

  group('PresenceService.parseSaveErrors', () {
    test('empty errors array => no errors', () {
      expect(
        PresenceService.parseSaveErrors(
          _obj('{"hasErrors":false,"errors":[]}'),
        ),
        isEmpty,
      );
    });

    test('non-empty errors array => surfaced strings', () {
      final errs = PresenceService.parseSaveErrors(
        _obj('{"hasErrors":true,"errors":["geen rechten","ongeldige datum"]}'),
      );
      expect(errs, ['geen rechten', 'ongeldige datum']);
    });

    test('bare saved-records array => no errors', () {
      expect(
        PresenceService.parseSaveErrors(_arr('[{"presenceID":1}]')),
        isEmpty,
      );
    });

    test('hasErrors true without detail => generic error', () {
      expect(
        PresenceService.parseSaveErrors(_obj('{"hasErrors":true}')),
        isNotEmpty,
      );
    });

    test('unexpected type => reported as an error', () {
      expect(PresenceService.parseSaveErrors(42), isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // formatDate
  // ---------------------------------------------------------------------------

  group('PresenceService.formatDate', () {
    test('zero-pads month and day', () {
      expect(PresenceService.formatDate(DateTime(2026, 6, 1)), '2026-06-01');
      expect(PresenceService.formatDate(DateTime(2026, 12, 25)), '2026-12-25');
    });
  });
}
