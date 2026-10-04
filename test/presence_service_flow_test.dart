// Tests for the Presence parsing / payload-building logic that can be validated
// offline (i.e. without a live Smartschool session).
//
// The JSON snippets below are trimmed captures of the real endpoints:
//   - Presence/Main/getConfig
//   - Presence/Code/getAllCodes
//   - Presence/Class/getClass
// with pupil names and IDs replaced by obvious fakes (userID 11110 is the
// school's test pupil, as in `example/set_late_example.dart`).
//
// End-to-end verification (which performs a real save + restore against a test
// pupil) lives in `example/set_late_example.dart`.

import 'dart:convert';

import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/services/presence_service.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

Map<String, dynamic> _obj(String src) =>
    jsonDecode(src) as Map<String, dynamic>;
List<dynamic> _arr(String src) => jsonDecode(src) as List<dynamic>;

void main() {
  forbidRealNetwork();

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
    // The config of an account that may set half-days (#121): its active
    // class, with both userCanConfirm and userCanRecord true, matches in
    // every field it has the one captured live (read-only, 2026-10-04) with
    // an absence administrator's account, which gave both flags true for
    // every class it listed (120), the virtual 2A among them. (Its origin
    // was not noted before, and its allowed classes had userCanRecord only.)
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
           "userCanConfirm":true,"userCanRecord":true,
           "instituteNumber":125252,"structID":311},
          {"groupID":1650,"name":"2A  ","adminNumber":"","isOfficial":0,
           "userCanConfirm":true,"userCanRecord":true,"instituteNumber":"",
           "structID":""}
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
      expect(config.activeClass!.userCanConfirm, isTrue);
      expect(config.activeClass!.isOfficial, isTrue);
    });

    test('both rights of each allowed class (#121)', () {
      expect(
        config.allowedClasses.map((c) => (c.userCanRecord, c.userCanConfirm)),
        [(true, true), (true, true)],
      );
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
      expect(c.activePlaceholder, isNull);
      expect(c.allowedClasses, isEmpty);
      expect(c.schoolyearRefDate, isEmpty);
    });

    test('an active class that is a class: activeClass, no placeholder', () {
      expect(config.activeClass!.isPlaceholder, isFalse);
      expect(config.activePlaceholder, isNull);
    });

    // #117: the module's active class of a teacher who has no lesson at that
    // moment is the placeholder -2, "Uit Planner" (seen live, read-only,
    // 2026-10-03). Before the fix it was activeClass, and classForGroup(-2)
    // returned it as a class of the account.
    group('the placeholder class -2 ("Uit Planner") (#117)', () {
      const placeholderJson = '''
      {"state":{"activeClass":{"adminNumber":null,"groupID":-2,
         "instituteNumber":0,"name":"Uit Planner","structID":null,
         "studierichting":"","userCanConfirm":false},
         "schoolyear":"2026-11-05"},
       "main":{"allowedClasses":[
         {"groupID":298,"name":"1A  ","adminNumber":6246,"isOfficial":1,
          "userCanRecord":true,"instituteNumber":125252,"structID":311}]}}
      ''';

      late PresenceConfig placeholder;
      setUpAll(
        () => placeholder = PresenceService.parseConfig(_obj(placeholderJson)),
      );

      test('is no activeClass, but activePlaceholder', () {
        expect(placeholder.activeClass, isNull);
        expect(placeholder.activePlaceholder?.groupId, -2);
        expect(placeholder.activePlaceholder?.name, 'Uit Planner');
        expect(placeholder.activePlaceholder?.structId, isNull);
        expect(placeholder.activePlaceholder?.isPlaceholder, isTrue);
        expect(placeholder.allowedClasses.map((c) => c.groupId), [298]);
      });

      test('classForGroup does not return it', () {
        expect(placeholder.classForGroup(-2), isNull);
        expect(placeholder.classForGroup(298)?.name, '1A');
      });

      test('an active class without a groupID (read as 0) is no class '
          'either', () {
        final c = PresenceService.parseConfig({
          'state': {
            'activeClass': {'name': 'Uit Planner'},
          },
        });
        expect(c.activeClass, isNull);
        expect(c.activePlaceholder?.groupId, 0);
        expect(c.classForGroup(0), isNull);
      });

      test('a groupID below 1 is a placeholder, 1 and above a class', () {
        PresenceClassRef ref(int groupId) =>
            PresenceClassRef(groupId: groupId, name: '');
        expect(ref(-2).isPlaceholder, isTrue);
        expect(ref(-1).isPlaceholder, isTrue);
        expect(ref(0).isPlaceholder, isTrue);
        expect(ref(1).isPlaceholder, isFalse);
        expect(ref(298).isPlaceholder, isFalse);
      });

      test('classForGroup returns no placeholder from a config built by '
          'hand either', () {
        const byHand = PresenceConfig(
          activeClass: PresenceClassRef(groupId: -2, name: 'Uit Planner'),
          allowedClasses: [PresenceClassRef(groupId: -1, name: 'Other')],
          schoolyearRefDate: '2026-11-05',
        );
        expect(byHand.classForGroup(-2), isNull);
        expect(byHand.classForGroup(-1), isNull);
      });
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
          "movementID": 5001,
          "userID": 1001,
          "name": "Enrolled Pupil",
          "presence": [
            {"presenceID":90001,"presenceDate":"2026-06-01","studentID":1001,
             "hourID":null,"partOfDay":"am","codeID":70,"aliasID":null,
             "motivation":null,"deleteStatus":0},
            {"presenceID":90002,"presenceDate":"2026-06-01","studentID":1001,
             "hourID":null,"partOfDay":"pm","codeID":70,"aliasID":null,
             "motivation":null,"deleteStatus":0},
            {"presenceID":90003,"presenceDate":"2026-06-01","studentID":1001,
             "hourID":198,"partOfDay":"none","codeID":1,"aliasID":null,
             "motivation":null,"deleteStatus":0}
          ]
        },
        {
          "movementID": 5002,
          "userID": 1002,
          "name": "Departed Pupil",
          "presence": []
        }
      ]
    }
    ''';

    late PresenceClassPupils pupils;
    setUpAll(() => pupils = PresenceService.parsePupils(_obj(classJson)));

    test('parses both pupils', () {
      expect(pupils, hasLength(2));
    });

    test('extracts only the am/pm half-day cells (skips per-lesson rows)', () {
      final p = pupils.firstWhere((p) => p.userId == 1001);
      expect(p.movementId, 5001);
      expect(p.halfDays, hasLength(2));
      expect(
        p.halfDays.map((c) => c.part),
        containsAll(<DayPart>[DayPart.morning, DayPart.afternoon]),
      );
    });

    test('halfDayFor returns the matching cell', () {
      final p = pupils.firstWhere((p) => p.userId == 1001);
      final am = p.halfDayFor(DayPart.morning, date: '2026-06-01');
      expect(am, isNotNull);
      expect(am!.presenceId, 90001);
      expect(am.codeId, 70);
    });

    test('halfDayFor returns null for a non-matching date', () {
      final p = pupils.firstWhere((p) => p.userId == 1001);
      expect(p.halfDayFor(DayPart.morning, date: '2020-01-01'), isNull);
    });

    test('departed pupil has no half-day cells (create case)', () {
      final p = pupils.firstWhere((p) => p.userId == 1002);
      expect(p.halfDays, isEmpty);
      expect(p.halfDayFor(DayPart.morning), isNull);
    });

    test('handles a body without pupils', () {
      expect(PresenceService.parsePupils({}), isEmpty);
    });

    test('reads the class of the answer; no saveIsAllowed or errorMessage in '
        'it gives null (#104)', () {
      expect(pupils.classRef?.groupId, 298);
      expect(pupils.classRef?.structId, 311);
      expect(pupils.saveIsAllowed, isNull);
      expect(pupils.errorMessage, isNull);

      final none = PresenceService.parsePupils({});
      expect(none.classRef, isNull);
      expect(none.saveIsAllowed, isNull);
      expect(none.errorMessage, isNull);
    });

    test('reads saveIsAllowed and the module\'s errorMessage (#104)', () {
      final refused = PresenceService.parsePupils(
        _obj('''
        {"groupID":298,"name":"1A  ","userCanRecord":true,"structID":311,
         "errorMessage":" Het is niet mogelijk om in de toekomst afwezigheden op te nemen. ",
         "pupils":[],"saveIsAllowed":false}
        '''),
      );
      expect(refused, isEmpty);
      expect(refused.saveIsAllowed, isFalse);
      expect(
        refused.errorMessage,
        'Het is niet mogelijk om in de toekomst afwezigheden op te nemen.',
      );
      expect(refused.classRef?.name, '1A');
      expect(refused.classRef?.userCanRecord, isTrue);

      final listed = PresenceService.parsePupils(
        _obj('{"errorMessage":"","pupils":[],"saveIsAllowed":true}'),
      );
      expect(listed.saveIsAllowed, isTrue);
      expect(listed.errorMessage, isNull, reason: '"" is no reason');
      expect(listed.classRef, isNull, reason: 'no groupID in the answer');
    });

    test('a saveIsAllowed that is no bool, or an errorMessage that is no '
        'text, is null (#104)', () {
      final odd = PresenceService.parsePupils(
        _obj('{"errorMessage":42,"pupils":[],"saveIsAllowed":"0"}'),
      );
      expect(odd.saveIsAllowed, isNull);
      expect(odd.errorMessage, isNull);
      expect(
        PresenceService.parsePupils(
          _obj('{"errorMessage":"   "}'),
        ).errorMessage,
        isNull,
      );
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

    // A refused save, in the shape the module's web client reads (its
    // Presence JavaScript, read-only): each error an object with the reason
    // in `message` and the record that was not saved in `presence`, with the
    // pupil's name in `pupil` (#109). Not captured live: no live save.
    const refusedJson = '''
    {"hasErrors":true,"errors":[
      {"message":" De afwezigheid kon niet worden opgeslagen. ",
       "presence":{"presenceID":90001,"presenceDate":"2026-06-01",
         "studentID":1001,"hourID":null,"partOfDay":"am","codeID":497,
         "aliasID":null,"motivation":"","deleteStatus":0,
         "pupil":"Peeters, Lotte"}},
      {"message":"De afwezigheid kon niet worden opgeslagen.",
       "presence":{"presenceID":null,"presenceDate":"2026-06-01",
         "studentID":"1002","hourID":null,"partOfDay":"pm","codeID":497,
         "aliasID":null,"motivation":"","deleteStatus":0,
         "pupil":"Janssens, Emma"}}
    ],"pupils":[]}
    ''';

    test("error objects => the module's message each, without the pupil's "
        'name (#109)', () {
      // The issue's example. Before the fix: each error as its
      // Map.toString(), "{message: ..., presence: {..., pupil: Peeters,
      // Lotte}}".
      final errs = PresenceService.parseSaveErrors(
        _obj('''
        {"hasErrors":true,"errors":[{
          "message":"De afwezigheid kon niet worden opgeslagen.",
          "presence":{"presenceDate":"2026-06-01","partOfDay":"am",
            "studentID":1001,"pupil":"Peeters, Lotte"}}]}
        '''),
      );
      expect(errs, ['De afwezigheid kon niet worden opgeslagen.']);

      final both = PresenceService.parseSaveErrors(_obj(refusedJson));
      expect(both, [
        'De afwezigheid kon niet worden opgeslagen.',
        'De afwezigheid kon niet worden opgeslagen.',
      ]);
      for (final name in ['Peeters', 'Lotte', 'Janssens', 'Emma']) {
        expect(both.join(), isNot(contains(name)));
      }
    });

    test('parseSaveErrorDetails types the record of each error (#109)', () {
      final errs = PresenceService.parseSaveErrorDetails(_obj(refusedJson));
      expect(errs, hasLength(2));
      expect(
        [
          for (final e in errs)
            (e.message, e.userId, e.date, e.part, e.pupilName),
        ],
        [
          (
            'De afwezigheid kon niet worden opgeslagen.',
            1001,
            '2026-06-01',
            DayPart.morning,
            'Peeters, Lotte',
          ),
          (
            'De afwezigheid kon niet worden opgeslagen.',
            1002,
            '2026-06-01',
            DayPart.afternoon,
            'Janssens, Emma',
          ),
        ],
      );
      expect(
        errs.first.toString(),
        'PresenceSaveError: De afwezigheid kon niet worden opgeslagen. '
        '(2026-06-01, morning, userID 1001)',
      );
      expect(errs.join(), isNot(contains('Peeters')));
    });

    test('an error object without a message, or a record in another shape: '
        'noReason, and null for what it does not name (#109)', () {
      final errs = PresenceService.parseSaveErrorDetails(
        _obj('''
        {"hasErrors":true,"errors":[
          {"presence":{"presenceDate":"2026-06-01","partOfDay":"none",
            "studentID":"x","pupil":"  "}},
          {"message":"   ","presence":"Peeters, Lotte"},
          {"message":42,"presence":{"presenceDate":20260601,"partOfDay":1,
            "studentID":null,"pupil":7}}
        ]}
        '''),
      );
      expect(
        [
          for (final e in errs)
            (e.message, e.userId, e.date, e.part, e.pupilName),
        ],
        [
          (PresenceSaveError.noReason, null, '2026-06-01', null, null),
          (PresenceSaveError.noReason, null, null, null, null),
          (PresenceSaveError.noReason, null, null, null, null),
        ],
      );
      expect(errs.join(), isNot(contains('Peeters')));
    });

    test('error texts are kept as they are, trimmed', () {
      final errs = PresenceService.parseSaveErrors(
        _obj(
          '{"hasErrors":true,"errors":[" geen rechten","ongeldige datum",""]}',
        ),
      );
      expect(errs, [
        'geen rechten',
        'ongeldige datum',
        PresenceSaveError.noReason,
      ]);
      expect(
        PresenceService.parseSaveErrorDetails(
          _obj('{"errors":["geen rechten"]}'),
        ).single.userId,
        isNull,
      );
    });

    test('an error in another shape says so, without its content (#109)', () {
      final errs = PresenceService.parseSaveErrors(
        _obj('{"hasErrors":true,"errors":[["Peeters, Lotte"],42,null]}'),
      );
      expect(errs, hasLength(3));
      expect(errs.first, contains('does not recognise'));
      expect(errs.join(), isNot(contains('Peeters')));
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
      expect(
        PresenceService.parseSaveErrorDetails(
          _obj('{"hasErrors":true}'),
        ).single.message,
        'Save reported hasErrors with no error detail.',
      );
    });

    test('unexpected type => reported as an error', () {
      expect(PresenceService.parseSaveErrors(42), isNotEmpty);
      expect(
        PresenceService.parseSaveErrorDetails(42).single.message,
        'Unexpected save response (int).',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // statusNameOf (#105)
  // ---------------------------------------------------------------------------

  group('PresenceService.statusNameOf (#105)', () {
    // The codes as read live (2026-10-03), trimmed.
    final codes = PresenceService.parseCodes(
      _arr('''
      [
        {"codeID":70,"code":"|","name":"Aanwezig","alias":[]},
        {"codeID":479,"code":"D","name":"Doktersattest","alias":[]},
        {"codeID":497,"code":"L","name":"Te laat","alias":[
          {"aliasID":14,"codeID":497,"name":"Te laat zonder geldige reden"}
        ]},
        {"codeID":12,"code":"?","name":"  ","alias":[]}
      ]
      '''),
    );

    PresenceHalfDay cell({int? codeId, int? aliasId}) => PresenceHalfDay(
      presenceId: 90001,
      presenceDate: '2026-06-01',
      part: DayPart.morning,
      codeId: codeId,
      aliasId: aliasId,
      motivation: '',
    );

    test('a code by its name', () {
      expect(PresenceService.statusNameOf(cell(codeId: 70), codes), 'Aanwezig');
      expect(
        PresenceService.statusNameOf(cell(codeId: 479), codes),
        'Doktersattest',
      );
    });

    test('an alias by its own name, also with its code set', () {
      // Seen live: an alias cell has codeID null and aliasID 14.
      expect(
        PresenceService.statusNameOf(cell(aliasId: 14), codes),
        PresenceService.lateWithoutReasonAliasName,
      );
      expect(
        PresenceService.statusNameOf(cell(codeId: 497, aliasId: 14), codes),
        PresenceService.lateWithoutReasonAliasName,
      );
    });

    test('no record, or a record without a code: nothing recorded', () {
      expect(
        PresenceService.statusNameOf(null, codes),
        PresenceService.nothingRecorded,
      );
      expect(
        PresenceService.statusNameOf(cell(), codes),
        PresenceService.nothingRecorded,
      );
    });

    test('a code or alias not among the codes, or without a name: null', () {
      expect(PresenceService.statusNameOf(cell(codeId: 999), codes), isNull);
      expect(PresenceService.statusNameOf(cell(aliasId: 99), codes), isNull);
      expect(PresenceService.statusNameOf(cell(codeId: 12), codes), isNull);
      expect(PresenceService.statusNameOf(cell(codeId: 70), const []), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // parseSavedHalfDay (#105)
  // ---------------------------------------------------------------------------

  group('PresenceService.parseSavedHalfDay (#105)', () {
    // The answer to a save of two pupils, in the shape the module's web
    // client reads: the pupils sent, with their records as stored.
    const answerJson = '''
    {"hasErrors":false,"errors":[],"pupils":[
      {"userID":1002,"movementID":5002,"presence":[
        {"presenceID":95001,"presenceDate":"2026-06-01","studentID":1002,
         "hourID":null,"partOfDay":"am","codeID":497,"aliasID":null,
         "motivation":"Bus","deleteStatus":0,
         "code":{"codeID":497,"name":"Te laat"}}]},
      {"userID":1001,"movementID":5001,"presence":[
        {"presenceID":90003,"presenceDate":"2026-06-01","studentID":1001,
         "hourID":198,"partOfDay":"none","codeID":1,"aliasID":null,
         "motivation":null,"deleteStatus":0},
        {"presenceID":"90002","presenceDate":"2026-06-01","studentID":1001,
         "hourID":null,"partOfDay":"pm","codeID":null,"aliasID":14,
         "motivation":null,"deleteStatus":0,
         "code":{"codeID":14,"aliasID":14,"parentCodeID":497,
                 "name":"Te laat zonder geldige reden","isAlias":true}}]}
    ]}
    ''';

    PresenceHalfDay? saved(
      Object? json,
      int userId, {
      String date = '2026-06-01',
      DayPart part = DayPart.afternoon,
    }) => PresenceService.parseSavedHalfDay(
      json,
      userId: userId,
      date: date,
      part: part,
    );

    test('finds the pupil\'s record of the half-day', () {
      final morning = saved(_obj(answerJson), 1002, part: DayPart.morning)!;
      expect(morning.presenceId, 95001);
      expect(morning.presenceDate, '2026-06-01');
      expect(morning.part, DayPart.morning);
      expect((morning.codeId, morning.aliasId), (497, null));
      expect(morning.motivation, 'Bus');

      // Past a per-lesson row; a presenceID as text, which the web client
      // reads with parseInt.
      final afternoon = saved(_obj(answerJson), 1001)!;
      expect(afternoon.presenceId, 90002);
      expect((afternoon.codeId, afternoon.aliasId), (null, 14));
      expect(afternoon.motivation, isEmpty);
    });

    test('another pupil, day or half of the day: null', () {
      expect(saved(_obj(answerJson), 1002), isNull, reason: 'no pm record');
      expect(saved(_obj(answerJson), 1003), isNull);
      expect(saved(_obj(answerJson), 1001, date: '2026-06-02'), isNull);
    });

    test('a record without studentID is the pupil\'s by its userID', () {
      final answer = _obj('''
      {"errors":[],"pupils":[{"userID":1001,"presence":[
        {"presenceID":90002,"presenceDate":"2026-06-01","hourID":null,
         "partOfDay":"pm","codeID":70,"aliasID":null,"motivation":""}]}]}
      ''');
      expect(saved(answer, 1001)?.codeId, 70);
      expect(saved(answer, 1002), isNull);
    });

    test('an answer without records, or in another shape: null, without '
        'throwing', () {
      expect(saved(_obj('{"hasErrors":false,"errors":[]}'), 1001), isNull);
      expect(saved(_arr('[{"presenceID":1}]'), 1001), isNull);
      expect(saved(42, 1001), isNull);
      expect(saved(null, 1001), isNull);
      expect(
        saved(_obj('{"errors":[],"pupils":[42,{"presence":"x"}]}'), 1001),
        isNull,
      );
      expect(
        saved(
          _obj('''
          {"errors":[],"pupils":[{"userID":1001,"presence":[
            {"presenceDate":20260601,"partOfDay":"pm","hourID":null},
            {"presenceDate":"2026-06-01","partOfDay":1,"hourID":null},
            {"presenceDate":"2026-06-01","partOfDay":"pm","hourID":null,
             "motivation":42}]}]}
          '''),
          1001,
        ),
        isNull,
      );
    });

    test('PresenceSavedHalfDay.of keeps the record, with before', () {
      final stored = saved(_obj(answerJson), 1001)!;
      const before = PresenceHalfDay(
        presenceId: 90002,
        presenceDate: '2026-06-01',
        part: DayPart.afternoon,
        codeId: 70,
        aliasId: null,
        motivation: '',
      );
      final result = PresenceSavedHalfDay.of(stored, before: before);
      expect(result, isA<PresenceHalfDay>());
      expect(
        (result.presenceId, result.presenceDate, result.part),
        (90002, '2026-06-01', DayPart.afternoon),
      );
      expect(
        (result.codeId, result.aliasId, result.motivation),
        (null, 14, ''),
      );
      expect(result.before, same(before));
      expect(PresenceSavedHalfDay.of(stored).before, isNull);
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
