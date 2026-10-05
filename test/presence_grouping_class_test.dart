// Tests for issue #126: a caller had no way to name the statuses of a
// grouping class. A grouping class (`isOfficial` 0, `structID` "" in
// getConfig, so PresenceClassRef.structId is null) has no school structure
// to ask getAllCodes for, yet getClassPupils lists its pupils with half-days
// that hold codes (`codeID`, `aliasID`) of their official classes, and
// PresenceService.statusNameOf needs "the codes of the class's school
// structure".
//
// What the Presence module answers, seen live (read-only, 2026-10-05, an
// account with the absence-administrator rights; trimmed below, with the
// pupils made up):
//
// - getConfig lists 17 grouping classes beside 103 official classes of the
//   school's one structure (311). Each class has a `downStreamGroups`: empty
//   for the official classes and for 11 grouping classes (such as
//   "Taalatelier groep 1"), the official classes of a year for 6 others
//   (2A: 2A MAW, 2A MOW, 2A STEMW, 2A ECO). The library parsed none of it.
// - getClass for a grouping class lists its pupils as for any class. Each
//   pupil has an `officialClass`, the groupID of its official class, which
//   getConfig lists with the structure 311 (for every pupil of all 17
//   grouping classes on 2026-10-02). Each half-day record carries a `code`:
//   the code (`codeID`, `code`, `name`, `structID`, `isAlias` false) or, for
//   an alias, the alias (`aliasID`, `parentCodeID`, `name`, `isAlias` true,
//   `codeID` set to the alias ID). The module's own web client shows a
//   record's status from it. Its name was the one statusNameOf gives from
//   getAllCodes(311) for every one of some 1700 half-days. A pupil's
//   half-days are the same records (`presenceID`) in its official class.
// - getAllCodes with an empty `structID` answers four codes of no structure
//   ("Aanwezig" 1, "Te laat" 2, "Afwezig" 3, "Online aanwezig" 591), those
//   of the per-lesson rows, which name none of the half-days.
//
// Now PresenceHalfDay.statusName has the name the module gives with the
// record, PresencePupil.officialClassId the pupil's official class (whose
// structure getConfig gives), and PresenceClassRef.downStreamGroupIds the
// classes a class groups.
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

/// getConfig as captured (2026-10-05), trimmed from 120 classes to the
/// grouping classes 2A (which names the classes it groups) and Taalatelier
/// groep 1 (which names none), the official classes 2A groups, and 2E ECO,
/// the official class of a pupil below.
const _configJson = '''
{"hasErrors":false,"errors":[],"isAdmin":true,"canConfirm":true,
 "state":{"activeClass":{"groupID":298,"name":"1A ","adminNumber":6246,
   "isOfficial":1,"userCanConfirm":true,"userCanRecord":true,
   "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   "schoolyear":"2026-11-05"},
 "main":{"allowedClasses":[
   {"groupID":1650,"name":"2A  ","adminNumber":"","isOfficial":0,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":"","structID":"","studierichting":"",
    "downStreamGroups":[1652,1654,1658,1968]},
   {"groupID":1652,"name":"2A MAW  ","adminNumber":40088,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   {"groupID":1654,"name":"2A MOW  ","adminNumber":40089,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   {"groupID":1658,"name":"2A STEMW  ","adminNumber":40090,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   {"groupID":1968,"name":"2A ECO  ","adminNumber":40091,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   {"groupID":3542,"name":"2E ECO  ","adminNumber":40120,"isOfficial":1,
    "userCanConfirm":true,"userCanRecord":true,"isOKAN":false,
    "instituteNumber":125252,"structID":311,"downStreamGroups":[]},
   {"groupID":5248,"name":"Taalatelier groep 1  ","adminNumber":"",
    "isOfficial":0,"userCanConfirm":true,"userCanRecord":true,
    "isOKAN":false,"instituteNumber":"","structID":"","studierichting":"",
    "downStreamGroups":[]}]}}
''';

/// getAllCodes for the structure 311, trimmed to the codes the half-days
/// below hold.
const _codes311 = '''
[{"codeID":70,"code":"|","name":"Aanwezig","structID":311,"alias":[]},
 {"codeID":71,"code":"-","name":"Reden afwezigheid voorlopig onbekend",
  "structID":311,"alias":[]},
 {"codeID":479,"code":"D","name":"Doktersattest","structID":311,"alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","structID":311,"alias":[
   {"aliasID":14,"codeID":497,"code":"  ",
    "name":"Te laat zonder geldige reden","dateDeleted":null,
    "codeOrder":0}]}]
''';

/// getAllCodes for an empty `structID`, as captured (2026-10-05): the codes
/// of no structure, those of the per-lesson rows.
const _codesWithoutStructure = '''
[{"codeID":1,"code":"","name":"Aanwezig","isOfficial":0,"structID":"","alias":[]},
 {"codeID":591,"code":"","name":"Online aanwezig","isOfficial":0,"structID":"","alias":[]},
 {"codeID":2,"code":"","name":"Te laat","isOfficial":0,"structID":"","alias":[]},
 {"codeID":3,"code":"","name":"Afwezig","isOfficial":0,"structID":"","alias":[]}]
''';

/// The `code` the module gives with a record of [codeId], as captured
/// (trimmed).
String _code(int codeId, String name, String glyph) =>
    '{"codeID":$codeId,"code":"$glyph","name":"$name","icon":"",'
    '"color":"red","isOfficial":1,"structID":311,"isAlias":false}';

/// The `code` the module gives with a record of the alias 14, as captured:
/// its `codeID` is the alias ID.
const _aliasCode =
    '{"aliasID":14,"codeID":14,"code":"L","name":"Te laat zonder geldige '
    'reden","dateDeleted":null,"codeOrder":0,"parentCodeID":497,'
    '"aliasCode":"L ","color":"yellow","isAlias":true}';

/// A half-day record of [userId] on 2026-10-02, as getClass gives it.
String _record(
  int userId,
  String partOfDay, {
  int? codeId,
  int? aliasId,
  String? code,
  String? motivation,
}) =>
    '{"presenceID":${userId * 10 + (partOfDay == 'am' ? 1 : 2)},'
    '"presenceDate":"2026-10-02","studentID":$userId,"hourID":null,'
    '"partOfDay":"$partOfDay","codeID":${codeId ?? 'null'},'
    '"aliasID":${aliasId ?? 'null'},'
    '"motivation":${motivation == null ? 'null' : jsonEncode(motivation)},'
    '"deleteStatus":0${code == null ? '' : ',"code":$code'}}';

/// A per-lesson row of [userId], with the code of no structure it holds.
String _lessonRow(int userId) =>
    '{"presenceID":${userId * 10 + 9},"presenceDate":"2026-10-02",'
    '"studentID":$userId,"hourID":216,"partOfDay":"none","codeID":1,'
    '"aliasID":null,"motivation":null,"deleteStatus":0,"code":{"codeID":1,'
    '"code":"","name":"Aanwezig","isOfficial":0,"structID":"",'
    '"isAlias":false}}';

/// A pupil as getClass gives it, in the official class [officialClass].
String _pupil(
  int userId,
  int officialClass,
  List<String> records, {
  String movement = '{"from":"2026-09-01","until":"2027-08-31"}',
}) =>
    '{"movementID":${userId + 30000},"userID":$userId,"name":"Pupil $userId",'
    '"sex":"f","ofSchoolage":"of_school_age","movement":$movement,'
    '"sickNotesTotal":0,"attendanceSuggestion":false,'
    '"officialClass":$officialClass,"showWarning":true,'
    '"presence":[${records.join(',')}]}';

/// A grouping class's own fields, with which getClass starts its answer.
String _groupingFields(int groupId, String name, List<int> downStream) =>
    '"groupID":$groupId,"name":"$name ","adminNumber":"","isOfficial":0,'
    '"userCanConfirm":true,"userCanRecord":true,"isOKAN":false,'
    '"instituteNumber":"","structID":"","studierichting":"",'
    '"downStreamGroups":${jsonEncode(downStream)},"hasDiscimus":true,'
    '"iconclass":"briefcase",';

String _classAnswer(String fields, List<String> pupils) =>
    '{$fields"schoolyear":{"label":"2026-2027","start":"2026-09-01",'
    '"stop":"2027-08-31"},"errorMessage":"","pupils":[${pupils.join(',')}],'
    '"saveIsAllowed":true}';

/// getClass for the grouping class 2A on 2026-10-02: a pupil of each of
/// three official classes it groups, "Aanwezig", absent for an unknown
/// reason, and late without a valid reason (an alias).
final _class2A = _classAnswer(
  _groupingFields(1650, '2A', [1652, 1654, 1658, 1968]),
  [
    _pupil(
      11110,
      1968,
      [
        _record(11110, 'am', codeId: 70, code: _code(70, 'Aanwezig', '|')),
        _record(11110, 'pm', codeId: 70, code: _code(70, 'Aanwezig', '|')),
        _lessonRow(11110),
      ],
      movement:
          '{"from":"2026-09-01","until":"2027-08-31","currentClassID":1968,'
          '"currentClass":"2A ECO","previousClassID":false,'
          '"nextClassID":false,"outSchoolDate":null}',
    ),
    _pupil(11112, 1652, [
      _record(
        11112,
        'am',
        codeId: 71,
        motivation: 'Ziek',
        code: _code(71, 'Reden afwezigheid voorlopig onbekend', '-'),
      ),
      _record(
        11112,
        'pm',
        codeId: 71,
        code: _code(71, 'Reden afwezigheid voorlopig onbekend', '-'),
      ),
    ]),
    _pupil(11114, 1658, [
      _record(11114, 'am', aliasId: 14, code: _aliasCode),
      _record(11114, 'pm', codeId: 70, code: _code(70, 'Aanwezig', '|')),
    ]),
  ],
);

/// getClass for the grouping class Taalatelier groep 1 on 2026-10-02, which
/// names no class it groups: pupils of official classes across the school.
final _classTaalatelier = _classAnswer(
  _groupingFields(
    5248,
    'Taalatelier '
    'groep 1',
    [],
  ),
  [
    _pupil(11116, 3542, [
      _record(11116, 'am', codeId: 479, code: _code(479, 'Doktersattest', 'D')),
      _record(11116, 'pm', codeId: 479, code: _code(479, 'Doktersattest', 'D')),
    ]),
    _pupil(11118, 1968, [
      _record(11118, 'am', codeId: 497, code: _code(497, 'Te laat', 'L')),
      _record(11118, 'pm', codeId: 70, code: _code(70, 'Aanwezig', '|')),
    ]),
  ],
);

/// A Smartschool whose Presence module answers as captured.
class _Smartschool implements HttpClientAdapter {
  /// Every request, as `METHOD path`.
  final List<String> log = [];

  /// The `structID` of each `getAllCodes`.
  final List<String?> codeRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');
    final fields = {
      for (final MapEntry(:key, :value)
          in (options.data as Map? ?? const {}).entries)
        '$key': '$value',
    };
    switch (path) {
      case _getConfig:
        return _json(_configJson);
      case _getAllCodes:
        codeRequests.add(fields['structID']);
        return _json(
          fields['structID'] == '311' ? _codes311 : _codesWithoutStructure,
        );
      case _getClass:
        final answer = switch ('${fields['classID']} ${fields['startDate']}') {
          '1650 2026-10-02' => _class2A,
          '5248 2026-10-02' => _classTaalatelier,
          _ =>
            '{"errorMessage":"Deze klas bevat geen leerlingen.",'
                '"pupils":[],"saveIsAllowed":false}',
        };
        return _json(answer);
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

  Future<PresenceClassPupils> classPupils(
    PresenceService presence,
    int classGroupId,
  ) => presence.getClassPupils(
    classGroupId: classGroupId,
    date: DateTime(2026, 10, 2),
    schoolyearRefDate: '2026-11-05',
  );

  /// The statuses of [pupils], as `userID part: name`.
  List<String> named(
    PresenceClassPupils pupils,
    String? Function(PresencePupil pupil, PresenceHalfDay halfDay) name,
  ) => [
    for (final pupil in pupils)
      for (final halfDay in pupil.halfDays)
        '${pupil.userId} ${halfDay.part.wire}: ${name(pupil, halfDay)}',
  ];

  const statuses2A = [
    '11110 am: Aanwezig',
    '11110 pm: Aanwezig',
    '11112 am: Reden afwezigheid voorlopig onbekend',
    '11112 pm: Reden afwezigheid voorlopig onbekend',
    '11114 am: Te laat zonder geldige reden',
    '11114 pm: Aanwezig',
  ];

  const statusesTaalatelier = [
    '11116 am: Doktersattest',
    '11116 pm: Doktersattest',
    '11118 am: Te laat',
    '11118 pm: Aanwezig',
  ];

  group('a grouping class (#126)', () {
    test('getConfig: a grouping class has no structure, and names the '
        'classes it groups in downStreamGroupIds; an official class names '
        'none', () async {
      final (presence, server) = await serve();

      final config = await presence.getConfig();

      final grouping2A = config.classForGroup(1650)!;
      expect(grouping2A.structId, isNull);
      expect(grouping2A.isOfficial, isFalse);
      expect(grouping2A.downStreamGroupIds, [1652, 1654, 1658, 1968]);
      final taalatelier = config.classForGroup(5248)!;
      expect(taalatelier.structId, isNull);
      expect(taalatelier.downStreamGroupIds, isEmpty);
      final eco = config.classForGroup(1968)!;
      expect(eco.structId, 311);
      expect(eco.downStreamGroupIds, isEmpty);
      expect(config.activeClass?.downStreamGroupIds, isEmpty);
      // The classes 2A groups are official classes with a structure.
      expect(
        [
          for (final id in grouping2A.downStreamGroupIds)
            config.classForGroup(id)?.structId,
        ],
        [311, 311, 311, 311],
      );
      expect(server.log, ['POST $_getConfig']);
    });

    test('getClassPupils: each pupil with its official class and each '
        'half-day with the name of its status, from the answer alone, '
        'without the codes of a structure', () async {
      // Before the fix: no officialClassId, no statusName, and no structure
      // to ask getAllCodes for.
      final (presence, server) = await serve();

      final pupils = await classPupils(presence, 1650);

      expect(pupils.map((p) => p.officialClassId), [1968, 1652, 1658]);
      expect(named(pupils, (_, h) => h.statusName), statuses2A);
      // The alias is stored as an alias, as for an official class; the
      // per-lesson row is still left out.
      final late = pupils[2].halfDayFor(DayPart.morning)!;
      expect((late.codeId, late.aliasId), (null, 14));
      expect(pupils.first.halfDays, hasLength(2));
      expect(pupils[1].halfDayFor(DayPart.morning)!.motivation, 'Ziek');
      expect(pupils.classRef?.structId, isNull);
      expect(pupils.classRef?.downStreamGroupIds, [1652, 1654, 1658, 1968]);
      expect(server.log, ['POST $_getClass']);
    });

    test('a caller names the half-days of a grouping class with the codes '
        "of each pupil's official class, and gets the names the module "
        'gives with the records', () async {
      final (presence, server) = await serve();
      final config = await presence.getConfig();

      // What smartschool-mcp's readPresenceDay can do instead of reading the
      // codes of every structure of the school
      // (yvanvds/smartschool-mcp#99, #101).
      Future<List<String>> byOfficialClass(int classGroupId) async {
        final pupils = await classPupils(presence, classGroupId);
        final codesOf = <int, List<PresenceCode>>{};
        for (final pupil in pupils) {
          final structId = config
              .classForGroup(pupil.officialClassId!)!
              .structId!;
          codesOf[pupil.userId] = await presence.getAllCodes(structId);
        }
        return named(
          pupils,
          (p, h) => PresenceService.statusNameOf(h, codesOf[p.userId]!),
        );
      }

      expect(await byOfficialClass(1650), statuses2A);
      // A grouping class that names no class it groups: its pupils come
      // from official classes across the school.
      expect(await byOfficialClass(5248), statusesTaalatelier);
      expect(
        named(await classPupils(presence, 5248), (_, h) => h.statusName),
        statusesTaalatelier,
      );
      // Only the structure of the official classes, once (cached).
      expect(server.codeRequests, ['311']);
    });

    test('the codes of no structure, which the module gives for an empty '
        "structID, name none of a grouping class's half-days", () async {
      final (presence, _) = await serve();
      final pupils = await classPupils(presence, 1650);
      final withoutStructure = PresenceService.parseCodes(
        jsonDecode(_codesWithoutStructure) as List,
      );

      expect(
        named(
          pupils,
          (_, h) => PresenceService.statusNameOf(h, withoutStructure),
        ),
        everyElement(endsWith(': null')),
      );
    });

    test('setLate for a grouping class is still refused before anything is '
        'sent', () async {
      final (presence, server) = await serve();

      await expectLater(
        presence.setLate(
          userId: 11110,
          classGroupId: 1650,
          date: DateTime(2026, 10, 2),
          part: DayPart.morning,
        ),
        throwsA(
          isA<SmartschoolPresenceError>().having(
            (e) => e.message,
            'message',
            contains('has no structID'),
          ),
        ),
      );
      expect(server.log, ['POST $_getConfig']);
      expect(server.log, isNot(contains('POST $_save')));
    });
  });

  group('the parsing of the new fields (#126)', () {
    test('a record without a code, or with one without a name: statusName '
        'null, and statusNameOf names it from the codes as before', () {
      final pupils = PresenceService.parsePupils(
        jsonDecode(
              _classAnswer(_groupingFields(1650, '2A', []), [
                _pupil(11110, 1968, [
                  _record(11110, 'am', codeId: 70),
                  _record(
                    11110,
                    'pm',
                    codeId: 70,
                    code: '{"codeID":70,"name":"  "}',
                  ),
                ]),
                _pupil(11112, 1968, [
                  _record(11112, 'am', codeId: 70, code: '"Aanwezig"'),
                  _record(11112, 'pm', codeId: 70, code: '{"name":42}'),
                ]),
              ]),
            )
            as Map<String, dynamic>,
      );
      final codes = PresenceService.parseCodes(jsonDecode(_codes311) as List);

      for (final halfDay in pupils.expand((p) => p.halfDays)) {
        expect(halfDay.statusName, isNull);
        expect(PresenceService.statusNameOf(halfDay, codes), 'Aanwezig');
      }
    });

    test('the name is trimmed', () {
      final pupils = PresenceService.parsePupils(
        jsonDecode(
              _classAnswer(_groupingFields(1650, '2A', []), [
                _pupil(11110, 1968, [
                  _record(
                    11110,
                    'am',
                    codeId: 70,
                    code: '{"codeID":70,"name":" Aanwezig  "}',
                  ),
                ]),
              ]),
            )
            as Map<String, dynamic>,
      );
      expect(pupils.single.halfDays.single.statusName, 'Aanwezig');
    });

    test('a pupil without officialClass, a class without downStreamGroups or '
        'with entries that are no IDs: null and the IDs it has', () {
      final pupils = PresenceService.parsePupils({
        'groupID': 298,
        'structID': 311,
        'downStreamGroups': [1652, '1654', '', null, 'x', 1658.0],
        'pupils': [
          {'userID': 11110, 'movementID': 35714, 'name': 'Test Pupil'},
          {
            'userID': 11112,
            'movementID': 35716,
            'name': 'Pupil',
            'officialClass': false,
          },
        ],
      });

      expect(pupils.map((p) => p.officialClassId), [null, null]);
      expect(pupils.classRef?.downStreamGroupIds, [1652, 1654, 1658]);
      expect(
        PresenceClassRef.fromJson(const {
          'groupID': 298,
          'name': '1A',
        }).downStreamGroupIds,
        isEmpty,
      );
      expect(
        const PresenceClassRef(groupId: 298, name: '1A').downStreamGroupIds,
        isEmpty,
      );
    });

    test('the half-day a save stores has the name its answer gives with it, '
        'and PresenceSavedHalfDay.of keeps it', () {
      // The answer's shape is the one the module's web client reads (#105),
      // with the `code` getClass gives with a record.
      final answer =
          jsonDecode(
                '{"hasErrors":false,"errors":[],"pupils":[{"userID":11114,'
                '"movementID":41114,"presence":['
                '${_record(11114, 'am', aliasId: 14, code: _aliasCode)}]}]}',
              )
              as Map<String, dynamic>;

      final stored = PresenceService.parseSavedHalfDay(
        answer,
        userId: 11114,
        date: '2026-10-02',
        part: DayPart.morning,
      )!;
      final saved = PresenceSavedHalfDay.of(stored);

      expect(stored.statusName, 'Te laat zonder geldige reden');
      expect(saved.statusName, 'Te laat zonder geldige reden');
      expect((saved.codeId, saved.aliasId), (null, 14));
    });
  });
}
