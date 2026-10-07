// Tests for issue #137: an answer of the Presence module that cannot be read
// (an empty body, an HTML page, a body that is not valid JSON) was a plain
// SmartschoolPresenceError, the same type as a save the module refused with
// `errors[]` and as the checks before a save, with its HTTP status only in
// the message. A caller that retries (AccountManager's late-arrival drain,
// yvanvds/AccountManager#461) could not tell "the module said no" from "the
// answer could not be read", and gave a registration up on a proxy's `502`.
//
// Now PresenceService throws a SmartschoolPresenceUnreadableAnswerError for
// it, still a SmartschoolPresenceError, with the endpoint (`path`), the HTTP
// status (`statusCode`), what made it unreadable (`kind`: empty, html,
// malformedJson) and, for an HTML page, its title and heading.
//
// The client takes every status as an answer (`validateStatus` accepts all),
// so a `429` or a `5xx` reaches the service; only a `401` and a redirect to
// the login chain make it log in again (#8, #22). Of these answers, only
// Smartschool's generic `500` page ("Oeps, er ging iets mis", with an empty
// title) was seen live (#5, read-only). The proxy pages are the ones nginx
// serves, not seen from Smartschool.
//
// The fake Smartschool below keeps the half-days of one day and carries out
// a save on them, in the shapes of presence_set_status_test.dart (the
// answer to a save as the module's web client reads it). It can answer the
// next request to an endpoint with an unreadable answer, and for the save,
// carry the save out first (the answer was lost on its way back) or not
// (the answer came from in front of the module). Its pupils are made up.
//
// Issue #143: an answer whose body *is* valid JSON was read as Presence
// data whatever its HTTP status. A `500`, `502` or `503` with a JSON body
// (`{"message":"Internal Server Error"}`, from Smartschool or a proxy) gave
// getConfig a config without classes, which it cached, so every later
// setLate failed with "Class groupID ... is not among the classes"; it gave
// getClassPupils an empty class, so setLate threw PupilNotFound; and it gave
// the save no `errors`, so setLate returned `null`, a confirmed save. Now
// such an answer is a SmartschoolPresenceUnreadableAnswerError of the new
// kind `errorStatus`, with its status, and nothing is cached from it; the
// kinds of the answers above (#137) stay as they were, whatever their
// status. A save answered with the module's own non-empty `errors[]` stays a
// refused save (a plain SmartschoolPresenceError), whatever its status. Seen
// live (read-only, 2026-10-07): the module answered getConfig, getAllCodes
// and getClass (also of a class it does not know) with `200`; a JSON body
// with another status was not seen from it, and was not provoked.
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

const _day = '2026-06-01';
final _date = DateTime(2026, 6, 1);
const _schoolyear = '2026-05-15';

const _classId = 298;
const _structId = 311;

const _aanwezig = 70;
const _teLaat = 497;

const _peeters = 1001; // present in the morning
const _janssens = 1002; // nothing recorded

const _pupils = [
  (_peeters, 5001, 'Peeters, Lotte'),
  (_janssens, 5002, 'Janssens, Emma'),
];

const _codesJson = '''
[{"codeID":70,"code":"|","name":"Aanwezig","structID":311,"alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","structID":311,"alias":[
   {"aliasID":14,"codeID":497,"code":"  ","name":"Te laat zonder geldige reden",
    "dateDeleted":null,"codeOrder":0}]}]
''';

String _configJson({required bool userCanConfirm}) =>
    '''
{"hasErrors":false,"errors":[],
 "state":{"activeClass":{"groupID":-2,"name":"Uit Planner","structID":null},
   "schoolyear":"$_schoolyear"},
 "main":{"allowedClasses":[{"groupID":298,"name":"1A","isOfficial":1,
   "userCanConfirm":$userCanConfirm,"userCanRecord":true,"structID":311}]}}
''';

typedef _Answer = ResponseBody Function();

ResponseBody _json(String body, {int status = 200}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _text(
  String body,
  int status, {
  String contentType = 'text/html; charset=UTF-8',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// Smartschool's generic error page, as the Presence module sends it with a
/// `500` for a request it cannot handle (seen live, #5).
const _oepsPage = '''
<!DOCTYPE html>
<html>
    <head>
        <title></title>
        <meta charset="utf-8">
    </head>
    <body>
        <div id="#smscMain">
            <h1>Oeps, er ging iets mis</h1>
        </div>
    </body>
</html>
''';

/// One of Smartschool's own pages, titled with the school's name, as it
/// serves some of its error pages: with status `200`.
const _notFoundPage =
    '<!DOCTYPE html><html><head><title>Springfield Academy - Smartschool'
    '</title><script>var vars = {"authenticatedUser": "Jan Janssens"};'
    '</script></head><body><h1>De opgevraagde pagina kon niet worden '
    'gevonden</h1><p>Ga terug naar de startpagina.</p></body></html>';

/// The error page nginx serves for a `502`.
const _badGatewayPage =
    '<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n<body>\r\n'
    '<center><h1>502 Bad Gateway</h1></center>\r\n<hr><center>nginx</center>'
    '\r\n</body>\r\n</html>\r\n';

/// What a case answers, and what the error must carry.
typedef _Case = ({
  String label,
  _Answer answer,
  int status,
  PresenceUnreadableAnswerKind kind,
  String? title,
  String? heading,
});

final _cases = <_Case>[
  (
    label: 'an empty 200',
    answer: () => _text('', 200),
    status: 200,
    kind: PresenceUnreadableAnswerKind.empty,
    title: null,
    heading: null,
  ),
  (
    label: "an empty 502 (a proxy's)",
    answer: () => _text('', 502),
    status: 502,
    kind: PresenceUnreadableAnswerKind.empty,
    title: null,
    heading: null,
  ),
  (
    label: 'white space only, 504',
    answer: () => _text(' \r\n\t\n', 504),
    status: 504,
    kind: PresenceUnreadableAnswerKind.empty,
    title: null,
    heading: null,
  ),
  (
    label: "Smartschool's error page, HTML 500",
    answer: () => _text(_oepsPage, 500),
    status: 500,
    kind: PresenceUnreadableAnswerKind.html,
    title: null,
    heading: 'Oeps, er ging iets mis',
  ),
  (
    label: 'an HTML page with status 200',
    answer: () => _text(_notFoundPage, 200),
    status: 200,
    kind: PresenceUnreadableAnswerKind.html,
    title: 'Springfield Academy - Smartschool',
    heading: 'De opgevraagde pagina kon niet worden gevonden',
  ),
  (
    label: "a proxy's 502 page",
    answer: () => _text(_badGatewayPage, 502),
    status: 502,
    kind: PresenceUnreadableAnswerKind.html,
    title: '502 Bad Gateway',
    heading: '502 Bad Gateway',
  ),
  (
    // Before the fix: "Failed to decode JSON" (only a doctype or an <html>
    // at the very start counted as HTML).
    label: 'a page with a comment before its doctype, 200',
    answer: () => _text('<!-- TRANSPARANT LAYER -->\n$_oepsPage', 200),
    status: 200,
    kind: PresenceUnreadableAnswerKind.html,
    title: null,
    heading: 'Oeps, er ging iets mis',
  ),
  (
    label: 'a piece of a page, 200',
    answer: () => _text('<div class="smsc-error">Fout</div>', 200),
    status: 200,
    kind: PresenceUnreadableAnswerKind.html,
    title: null,
    heading: null,
  ),
  (
    label: 'JSON that breaks off, 200',
    answer: () => _json(
      '{"groupID":298,"pupils":[{"movementID":5001,"userID":1001,'
      '"name":"Peeters, Lo',
    ),
    status: 200,
    kind: PresenceUnreadableAnswerKind.malformedJson,
    title: null,
    heading: null,
  ),
  (
    label: 'plain text, 503',
    answer: () => _text(
      'Service Unavailable',
      503,
      contentType: 'text/plain; charset=utf-8',
    ),
    status: 503,
    kind: PresenceUnreadableAnswerKind.malformedJson,
    title: null,
    heading: null,
  ),
  (
    label: 'plain text, 429',
    answer: () => _text('Too Many Requests', 429, contentType: 'text/plain'),
    status: 429,
    kind: PresenceUnreadableAnswerKind.malformedJson,
    title: null,
    heading: null,
  ),
];

/// Answers whose body is valid JSON, with an HTTP status outside `200`–`299`
/// (#143): an error answer, from Smartschool or a proxy, never Presence data.
/// Not seen from the module live; the shapes are those of common error
/// bodies, and of the module's own envelope.
final _errorStatusCases = <_Case>[
  (
    // Before the fix: getConfig a config without classes, getClassPupils an
    // empty class, the save a confirmed `null`; getAllCodes "Unexpected
    // getAllCodes response", a plain SmartschoolPresenceError.
    label: 'a JSON 500 ({"message": "Internal Server Error"})',
    answer: () => _json('{"message":"Internal Server Error"}', status: 500),
    status: 500,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    label: "a proxy's JSON 502",
    answer: () => _json('{"error":"Bad Gateway","status":502}', status: 502),
    status: 502,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    // The module's own envelope, without errors: no refusal, no data.
    label: 'a JSON 503 with an envelope without errors',
    answer: () => _json('{"hasErrors":false,"errors":[]}', status: 503),
    status: 503,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    label: 'a JSON 500 flagged hasErrors, without errors',
    answer: () => _json('{"hasErrors":true}', status: 500),
    status: 500,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    // Before the fix: getAllCodes cached it as "no codes".
    label: 'an empty JSON list, 500',
    answer: () => _json('[]', status: 500),
    status: 500,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    label: 'a JSON 429',
    answer: () => _json('{"message":"Too Many Requests"}', status: 429),
    status: 429,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
  (
    // A body in the module's shapes, which names a pupil: not in the
    // message, and not read.
    label: 'a JSON 404 that names a pupil',
    answer: () => _json(
      '{"groupID":298,"pupils":[{"movementID":5001,"userID":1001,'
      '"name":"Peeters, Lotte","presence":[]}],"saveIsAllowed":true}',
      status: 404,
    ),
    status: 404,
    kind: PresenceUnreadableAnswerKind.errorStatus,
    title: null,
    heading: null,
  ),
];

/// A half-day of the fake: its record and what it holds.
class _Cell {
  _Cell(this.presenceId, {this.codeId});

  final int presenceId;
  int? codeId;
  int? aliasId;
  String? motivation;
}

/// A Smartschool whose Presence module holds the half-days of [_day] for
/// class 1A, and carries out a save on them.
class _Smartschool implements HttpClientAdapter {
  _Smartschool() {
    cells[(_peeters, 'am')] = _Cell(90001, codeId: _aanwezig);
  }

  /// The half-days of [_day], by pupil and part (`am`, `pm`).
  final Map<(int, String), _Cell> cells = {};

  /// The answers the next requests to an endpoint get instead of the
  /// module's, first one first.
  final Map<String, List<_Answer>> unreadable = {};

  /// Whether the module carries out a save whose answer [unreadable]
  /// replaces: the answer was lost on its way back, not refused in front of
  /// the module.
  bool saveLandsAnyway = false;

  /// Whether the module refuses every save with an `errors[]`.
  bool refuseSaves = false;

  /// The HTTP status of the module's own answer to a save, which it carries
  /// out (or refuses, with [refuseSaves]) whatever the status (#143).
  int saveStatus = 200;

  /// The account's `userCanConfirm` for class 1A (#121).
  bool userCanConfirm = true;

  int nextPresenceId = 95001;

  /// Every request, as `METHOD path`.
  final List<String> log = [];

  /// The presences of every save that reached the module, as sent: not of a
  /// save that [unreadable] answered without [saveLandsAnyway].
  final List<Map<String, Object?>> saved = [];

  int get saves => log.where((r) => r == 'POST $_save').length;

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
    final instead = unreadable[path];
    final override = instead == null || instead.isEmpty
        ? null
        : instead.removeAt(0);
    if (override != null) {
      if (path == _save && saveLandsAnyway) _carryOut(form['pupils']!);
      return override();
    }
    switch (path) {
      case _getConfig:
        return _json(_configJson(userCanConfirm: userCanConfirm));
      case _getAllCodes:
        return _json(_codesJson);
      case _getClass:
        return _json(jsonEncode(_classAnswer()));
      case _save:
        return _json(
          jsonEncode(_carryOut(form['pupils']!)),
          status: saveStatus,
        );
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
    'code': {
      'codeID': cell.codeId,
      'name': cell.codeId == _teLaat ? 'Te laat' : 'Aanwezig',
    },
  };

  Map<String, Object?> _classAnswer() => {
    'groupID': _classId,
    'name': '1A',
    'structID': _structId,
    'errorMessage': '',
    'saveIsAllowed': true,
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
  };

  /// Carries out the save of [pupilsJson] (unless [refuseSaves]), and
  /// returns the module's answer to it.
  Map<String, Object?> _carryOut(String pupilsJson) {
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
        if (refuseSaves) {
          errors.add({
            'message': 'De afwezigheid kon niet worden opgeslagen.',
            'presence': {...presence, 'pupil': 'Janssens, Emma'},
          });
          continue;
        }
        // A record sent with its presenceID is updated; one without gets a
        // new record, unless the half-day has one (the module keeps one
        // record per half-day).
        final cell = cells[(userId, part)] ??= _Cell(nextPresenceId++);
        final motivation = presence['motivation'] as String? ?? '';
        cell
          ..codeId = presence['codeID'] as int?
          ..aliasId = presence['aliasID'] as int?
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
      'pupils': answered,
    };
  }

  @override
  void close({bool force = false}) {}
}

/// What smartschool-mcp's `set_pupils_late` (and AccountManager) let a
/// write replace: "Te laat" included, so that a call sent again after an
/// unreadable answer to its save may find what the first one stored.
const _replaceable = {
  PresenceService.nothingRecorded,
  PresenceService.presentCodeName,
  PresenceService.lateCodeName,
  PresenceService.lateWithoutReasonAliasName,
};

/// The unreadable answer of [path] that [c] describes: a
/// [SmartschoolPresenceUnreadableAnswerError], which an existing `catch` of
/// [SmartschoolPresenceError] catches, and not a session problem.
Matcher _unreadable(String path, _Case c) => allOf(
  isA<SmartschoolPresenceError>(),
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolPresenceUnreadableAnswerError>()
      .having((e) => e.path, 'path', path)
      .having((e) => e.statusCode, 'statusCode', c.status)
      .having((e) => e.kind, 'kind', c.kind)
      .having((e) => e.title, 'title', c.title)
      .having((e) => e.heading, 'heading', c.heading)
      .having((e) => e.errors, 'errors', isEmpty)
      .having((e) => e.saveErrors, 'saveErrors', isEmpty)
      .having(
        (e) => e.message,
        'message',
        allOf(
          contains(path),
          contains('HTTP ${c.status}'),
          // Nothing of what the answer holds but its title and heading:
          // not the pupil's name of the JSON that breaks off, nor a page's
          // script or text.
          isNot(contains('Peeters')),
          isNot(contains('Janssens')),
          isNot(contains('startpagina')),
        ),
      ),
);

/// A Presence error that is not an unreadable answer.
Matcher _notUnreadable<T extends SmartschoolPresenceError>() =>
    allOf(isA<T>(), isNot(isA<SmartschoolPresenceUnreadableAnswerError>()));

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

  Future<PresenceSavedHalfDay?> setLate(
    PresenceService presence, {
    int userId = _janssens,
    Set<String>? onlyReplacing = _replaceable,
  }) => presence.setLate(
    userId: userId,
    classGroupId: _classId,
    date: _date,
    part: DayPart.morning,
    onlyReplacing: onlyReplacing,
  );

  final reads = <(String, String, Future<Object?> Function(PresenceService))>[
    ('getConfig', _getConfig, (p) => p.getConfig()),
    ('getAllCodes', _getAllCodes, (p) => p.getAllCodes(_structId)),
    (
      'getClassPupils',
      _getClass,
      (p) => p.getClassPupils(
        classGroupId: _classId,
        date: _date,
        schoolyearRefDate: _schoolyear,
      ),
    ),
  ];

  group('an unreadable answer to a read is a '
      'SmartschoolPresenceUnreadableAnswerError, sent once (#137)', () {
    for (final (name, path, read) in reads) {
      for (final c in _cases) {
        test('$name: ${c.label}', () async {
          // Before the fix: a plain SmartschoolPresenceError.
          final (presence, server) = await serve();
          server.unreadable[path] = [c.answer];

          await expectLater(read(presence), throwsA(_unreadable(path, c)));
          expect(server.log, ['POST $path'], reason: 'no login, no retry');
        });
      }
    }

    test('the read works again once the module answers', () async {
      final (presence, server) = await serve();
      server.unreadable[_getConfig] = [() => _text('', 502)];

      await expectLater(
        presence.getConfig(),
        throwsA(isA<SmartschoolPresenceUnreadableAnswerError>()),
      );
      final config = await presence.getConfig();

      expect(config.classForGroup(_classId)?.userCanConfirm, isTrue);
      expect(server.log, ['POST $_getConfig', 'POST $_getConfig']);
    });
  });

  group('setLate: an unreadable answer to a read before the save is the '
      'same error, and nothing is saved (#137)', () {
    for (final path in [_getConfig, _getAllCodes, _getClass]) {
      test(path, () async {
        final (presence, server) = await serve();
        server.unreadable[path] = [() => _text('', 502)];

        await expectLater(
          setLate(presence),
          throwsA(
            isA<SmartschoolPresenceUnreadableAnswerError>()
                .having((e) => e.path, 'path', path)
                .having((e) => e.statusCode, 'statusCode', 502),
          ),
        );
        expect(server.saves, 0);
        expect(server.cells[(_janssens, 'am')], isNull);
      });
    }
  });

  group('setLate: an unreadable answer to the save is a '
      'SmartschoolPresenceUnreadableAnswerError, and the save is sent once '
      '(#137)', () {
    for (final c in _cases) {
      test(c.label, () async {
        // Before the fix: a plain SmartschoolPresenceError, the type of a
        // save the module refused.
        final (presence, server) = await serve();
        server.unreadable[_save] = [c.answer];

        await expectLater(setLate(presence), throwsA(_unreadable(_save, c)));
        expect(server.saves, 1, reason: 'never sent again by the library');
      });
    }
  });

  group('after an unreadable answer to the save, setLate can be called '
      'again (#137)', () {
    test(
      'the save landed, its answer was lost: the second call finds the '
      'record the first made, and updates it rather than adding one',
      () async {
        final (presence, server) = await serve();
        server
          ..unreadable[_save] = [() => _text('', 502)]
          ..saveLandsAnyway = true;

        await expectLater(
          setLate(presence),
          throwsA(
            isA<SmartschoolPresenceUnreadableAnswerError>()
                .having((e) => e.path, 'path', _save)
                .having((e) => e.statusCode, 'statusCode', 502)
                .having(
                  (e) => e.kind,
                  'kind',
                  PresenceUnreadableAnswerKind.empty,
                ),
          ),
        );
        // The module stored it all the same.
        expect(server.cells[(_janssens, 'am')]?.presenceId, 95001);
        expect(server.cells[(_janssens, 'am')]?.codeId, _teLaat);
        final mark = server.log.length;

        final saved = await setLate(presence);

        expect(saved?.presenceId, 95001);
        expect(saved?.codeId, _teLaat);
        expect(saved?.before?.presenceId, 95001, reason: 'read again first');
        expect(saved?.before?.codeId, _teLaat);
        expect(server.log.skip(mark), [
          'POST $_getClass',
          'POST $_save',
        ], reason: 'the class read again; config and codes are cached');
        expect(
          [for (final s in server.saved) s['presenceID']],
          [null, 95001],
          reason: 'a new record, then that record updated',
        );
        expect(server.nextPresenceId, 95002, reason: 'one record only');
      },
    );

    test('the save landed, and onlyReplacing does not allow "Te laat": the '
        'second call is refused with what the first stored, and sends '
        'nothing', () async {
      final (presence, server) = await serve();
      server
        ..unreadable[_save] = [() => _text(_badGatewayPage, 502)]
        ..saveLandsAnyway = true;
      const onlyPresentOrNothing = {
        PresenceService.nothingRecorded,
        PresenceService.presentCodeName,
      };

      await expectLater(
        setLate(presence, onlyReplacing: onlyPresentOrNothing),
        throwsA(isA<SmartschoolPresenceUnreadableAnswerError>()),
      );
      await expectLater(
        setLate(presence, onlyReplacing: onlyPresentOrNothing),
        throwsA(
          allOf(
            _notUnreadable<SmartschoolPresenceChangeRefusedError>(),
            isA<SmartschoolPresenceChangeRefusedError>().having(
              (e) => e.heldStatus,
              'heldStatus',
              PresenceService.lateCodeName,
            ),
          ),
        ),
      );
      expect(server.saves, 1);
    });

    test('the save did not land (the answer came from in front of the '
        'module): the second call makes the record, once', () async {
      final (presence, server) = await serve();
      server.unreadable[_save] = [() => _text('Bad Gateway', 502)];

      await expectLater(
        setLate(presence),
        throwsA(
          isA<SmartschoolPresenceUnreadableAnswerError>().having(
            (e) => e.kind,
            'kind',
            PresenceUnreadableAnswerKind.malformedJson,
          ),
        ),
      );
      expect(server.cells[(_janssens, 'am')], isNull);

      final saved = await setLate(presence);

      expect(saved?.presenceId, 95001);
      expect(saved?.codeId, _teLaat);
      expect(saved?.before, isNull);
      expect(server.saves, 2, reason: 'one per call');
      expect(
        [for (final s in server.saved) s['presenceID']],
        [null],
        reason: 'the module saw the second save only: a new record',
      );
      expect(server.nextPresenceId, 95002, reason: 'one record only');
    });

    test('a half-day with a record: both saves send that record', () async {
      final (presence, server) = await serve();
      server
        ..unreadable[_save] = [() => _text('', 504)]
        ..saveLandsAnyway = true;

      await expectLater(
        setLate(presence, userId: _peeters),
        throwsA(isA<SmartschoolPresenceUnreadableAnswerError>()),
      );
      final saved = await setLate(presence, userId: _peeters);

      expect(saved?.presenceId, 90001);
      expect([for (final s in server.saved) s['presenceID']], [90001, 90001]);
      expect(server.nextPresenceId, 95001, reason: 'no new record');
    });
  });

  group('the other Presence errors are not an unreadable answer (#137)', () {
    test('a save the module refused with errors[]', () async {
      final (presence, server) = await serve();
      server.refuseSaves = true;

      await expectLater(
        setLate(presence),
        throwsA(
          allOf(
            _notUnreadable<SmartschoolPresenceError>(),
            isA<SmartschoolPresenceError>().having(
              (e) => e.saveErrors.single.message,
              'saveErrors',
              'De afwezigheid kon niet worden opgeslagen.',
            ),
          ),
        ),
      );
    });

    test('an account that may not set the half-days of the class '
        '(NoConfirmRight)', () async {
      final (presence, server) = await serve();
      server.userCanConfirm = false;

      await expectLater(
        setLate(presence),
        throwsA(_notUnreadable<SmartschoolPresenceNoConfirmRightError>()),
      );
      expect(server.saves, 0);
    });

    test('a pupil the class does not list (PupilNotFound)', () async {
      final (presence, server) = await serve();

      await expectLater(
        setLate(presence, userId: 4242),
        throwsA(_notUnreadable<SmartschoolPresencePupilNotFoundError>()),
      );
      expect(server.saves, 0);
    });

    test('a half-day onlyReplacing does not allow (ChangeRefused)', () async {
      final (presence, server) = await serve();

      await expectLater(
        setLate(
          presence,
          userId: _peeters,
          onlyReplacing: {PresenceService.nothingRecorded},
        ),
        throwsA(_notUnreadable<SmartschoolPresenceChangeRefusedError>()),
      );
      expect(server.saves, 0);
    });

    test('a class getConfig does not list', () async {
      final (presence, _) = await serve();

      await expectLater(
        presence.setLate(
          userId: _janssens,
          classGroupId: 4242,
          date: _date,
          part: DayPart.morning,
        ),
        throwsA(_notUnreadable<SmartschoolPresenceError>()),
      );
    });

    test('a code that is not among the codes of the structure', () {
      expect(
        () => PresenceService.resolveCode(const [], codeName: 'Te laat'),
        throwsA(_notUnreadable<SmartschoolPresenceError>()),
      );
    });
  });

  group('a caller can act on the type (#137)', () {
    /// How AccountManager's late-arrival drain handles a failed setLate.
    Future<String> drain(Future<void> Function() call) async {
      try {
        await call();
        return 'registered';
      } on SmartschoolPresenceUnreadableAnswerError {
        return 'try again later';
      } on SmartschoolPresenceError {
        return 'give up';
      }
    }

    /// The same, written before the new type: it still catches it.
    Future<String> drainBefore(Future<void> Function() call) async {
      try {
        await call();
        return 'registered';
      } on SmartschoolPresenceError {
        return 'give up';
      }
    }

    test("a proxy's 502 to the save is tried again, a refused save is given "
        'up; a catch written before the type still catches it', () async {
      final (presence, server) = await serve();
      server
        ..unreadable[_save] = [
          () => _text(_badGatewayPage, 502),
          () => _text('', 503),
        ]
        ..saveLandsAnyway = true;

      expect(await drain(() => setLate(presence)), 'try again later');
      expect(await drainBefore(() => setLate(presence)), 'give up');
      expect(await drain(() => setLate(presence)), 'registered');

      server.refuseSaves = true;
      expect(await drain(() => setLate(presence, userId: _peeters)), 'give up');
    });

    test('a JSON error status is tried again too (#143): to the save, '
        'and to a read', () async {
      // Before the fix: 'registered' for the save (a confirmed `null`), and
      // 'give up' for getConfig (the class not among those of an empty
      // config).
      final (presence, server) = await serve();
      server.unreadable[_save] = [
        () => _json('{"message":"Bad Gateway"}', status: 502),
      ];

      expect(await drain(() => setLate(presence)), 'try again later');
      expect(server.saves, 1);

      final (fresh, other) = await serve();
      other.unreadable[_getConfig] = [
        () => _json('{"message":"Internal Server Error"}', status: 500),
      ];
      expect(await drain(() => setLate(fresh)), 'try again later');
      expect(await drain(() => setLate(fresh)), 'registered');
    });
  });

  group('a JSON answer with an error status to a read is a '
      'SmartschoolPresenceUnreadableAnswerError of kind errorStatus, sent '
      'once (#143)', () {
    for (final (name, path, read) in reads) {
      for (final c in _errorStatusCases) {
        test('$name: ${c.label}', () async {
          final (presence, server) = await serve();
          server.unreadable[path] = [c.answer];

          await expectLater(read(presence), throwsA(_unreadable(path, c)));
          expect(server.log, ['POST $path'], reason: 'no login, no retry');
        });
      }
    }

    test('a 2xx other than 200 is still read as the answer', () async {
      final (presence, server) = await serve();
      server.unreadable[_getConfig] = [
        () => _json(_configJson(userCanConfirm: true), status: 203),
      ];

      final config = await presence.getConfig();

      expect(config.classForGroup(_classId)?.userCanConfirm, isTrue);
    });

    test('the kinds of #137 keep their order; errorStatus comes last', () {
      expect(PresenceUnreadableAnswerKind.values, [
        PresenceUnreadableAnswerKind.empty,
        PresenceUnreadableAnswerKind.html,
        PresenceUnreadableAnswerKind.malformedJson,
        PresenceUnreadableAnswerKind.errorStatus,
      ]);
    });
  });

  group('nothing is cached from a JSON answer with an error status '
      '(#143)', () {
    test('getConfig: the next call asks again, and gets the classes', () async {
      // Before the fix: a config without classes, cached, so the next call
      // sent nothing and had no classes either.
      final (presence, server) = await serve();
      server.unreadable[_getConfig] = [
        () => _json('{"message":"Internal Server Error"}', status: 500),
      ];

      await expectLater(
        presence.getConfig(),
        throwsA(
          isA<SmartschoolPresenceUnreadableAnswerError>().having(
            (e) => e.kind,
            'kind',
            PresenceUnreadableAnswerKind.errorStatus,
          ),
        ),
      );
      final config = await presence.getConfig();

      expect(config.classForGroup(_classId)?.userCanConfirm, isTrue);
      expect(config.schoolyearRefDate, _schoolyear);
      expect(server.log, ['POST $_getConfig', 'POST $_getConfig']);
    });

    test('getAllCodes: the next call asks again, and gets the codes', () async {
      // Before the fix: `[]` cached as "no codes" for the structure.
      final (presence, server) = await serve();
      server.unreadable[_getAllCodes] = [() => _json('[]', status: 503)];

      await expectLater(
        presence.getAllCodes(_structId),
        throwsA(
          isA<SmartschoolPresenceUnreadableAnswerError>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => e.kind,
                'kind',
                PresenceUnreadableAnswerKind.errorStatus,
              ),
        ),
      );
      final codes = await presence.getAllCodes(_structId);

      expect([for (final c in codes) c.name], ['Aanwezig', 'Te laat']);
      expect(server.log, ['POST $_getAllCodes', 'POST $_getAllCodes']);
    });

    test('getConfig(forceRefresh: true) keeps the config it had', () async {
      final (presence, server) = await serve();
      final before = await presence.getConfig();
      server.unreadable[_getConfig] = [
        () => _json('{"message":"Service Unavailable"}', status: 503),
      ];

      await expectLater(
        presence.getConfig(forceRefresh: true),
        throwsA(isA<SmartschoolPresenceUnreadableAnswerError>()),
      );

      expect(await presence.getConfig(), same(before));
      expect(server.log, ['POST $_getConfig', 'POST $_getConfig']);
    });
  });

  group('setLate: a JSON answer with an error status to a read before the '
      'save is a SmartschoolPresenceUnreadableAnswerError, not a refusal, '
      'and nothing is saved (#143)', () {
    for (final path in [_getConfig, _getAllCodes, _getClass]) {
      test(path, () async {
        // Before the fix: getConfig "Class groupID 298 is not among the
        // classes" (a plain SmartschoolPresenceError), getAllCodes
        // "Unexpected getAllCodes response", getClass PupilNotFound.
        final (presence, server) = await serve();
        server.unreadable[path] = [
          () => _json('{"message":"Internal Server Error"}', status: 500),
        ];

        await expectLater(
          setLate(presence),
          throwsA(
            allOf(
              isNot(isA<SmartschoolPresencePupilNotFoundError>()),
              isA<SmartschoolPresenceUnreadableAnswerError>()
                  .having((e) => e.path, 'path', path)
                  .having((e) => e.statusCode, 'statusCode', 500)
                  .having(
                    (e) => e.kind,
                    'kind',
                    PresenceUnreadableAnswerKind.errorStatus,
                  )
                  .having(
                    (e) => e.message,
                    'message',
                    isNot(contains('not among the classes')),
                  ),
            ),
          ),
        );
        expect(server.saves, 0);
        expect(server.cells[(_janssens, 'am')], isNull);

        // Nothing was cached from it: the next call saves.
        final saved = await setLate(presence);

        expect(saved?.presenceId, 95001);
        expect(saved?.codeId, _teLaat);
        expect(server.saves, 1);
      });
    }
  });

  group('setLate: a JSON answer with an error status to the save does not '
      'confirm it (#143)', () {
    for (final c in _errorStatusCases) {
      test(c.label, () async {
        // Before the fix: a confirmed save (`null`, or a plain
        // SmartschoolPresenceError for the `hasErrors` one).
        final (presence, server) = await serve();
        server.unreadable[_save] = [c.answer];

        await expectLater(setLate(presence), throwsA(_unreadable(_save, c)));
        expect(server.saves, 1, reason: 'never sent again by the library');
        expect(server.cells[(_janssens, 'am')], isNull);
      });
    }

    test('the module stored it and answered 500 with the record: not '
        'confirmed; setLate again updates that record', () async {
      // Before the fix: the record returned as stored, from a 500.
      final (presence, server) = await serve();
      server.saveStatus = 500;

      await expectLater(
        setLate(presence),
        throwsA(
          isA<SmartschoolPresenceUnreadableAnswerError>()
              .having((e) => e.path, 'path', _save)
              .having((e) => e.statusCode, 'statusCode', 500)
              .having(
                (e) => e.kind,
                'kind',
                PresenceUnreadableAnswerKind.errorStatus,
              )
              .having((e) => e.saveErrors, 'saveErrors', isEmpty),
        ),
      );
      expect(server.cells[(_janssens, 'am')]?.codeId, _teLaat);

      server.saveStatus = 200;
      final saved = await setLate(presence);

      expect(saved?.presenceId, 95001);
      expect(saved?.before?.presenceId, 95001, reason: 'read again first');
      expect(
        [for (final s in server.saved) s['presenceID']],
        [null, 95001],
        reason: 'a new record, then that record updated',
      );
      expect(server.nextPresenceId, 95002, reason: 'one record only');
    });

    test('a 2xx other than 200 with the record still confirms it', () async {
      final (presence, server) = await serve();
      server.saveStatus = 201;

      final saved = await setLate(presence);

      expect(saved?.presenceId, 95001);
      expect(saved?.codeId, _teLaat);
    });
  });

  group("a save answered with the module's errors[] is refused, whatever "
      'its status (#143)', () {
    for (final status in [400, 500, 503]) {
      test('HTTP $status', () async {
        final (presence, server) = await serve();
        server
          ..refuseSaves = true
          ..saveStatus = status;

        await expectLater(
          setLate(presence),
          throwsA(
            allOf(
              _notUnreadable<SmartschoolPresenceError>(),
              isA<SmartschoolPresenceError>()
                  .having(
                    (e) => e.saveErrors.single.message,
                    'saveErrors',
                    'De afwezigheid kon niet worden opgeslagen.',
                  )
                  .having(
                    (e) => e.saveErrors.single.userId,
                    'saveErrors.userId',
                    _janssens,
                  )
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(contains('HTTP $status'), isNot(contains('Emma'))),
                  ),
            ),
          ),
        );
        expect(server.saves, 1);
      });
    }

    test('with a 200, the message is as before', () async {
      final (presence, server) = await serve();
      server.refuseSaves = true;

      await expectLater(
        setLate(presence),
        throwsA(
          isA<SmartschoolPresenceError>().having(
            (e) => e.message,
            'message',
            'Saving the presence for userID $_janssens failed.',
          ),
        ),
      );
    });
  });
}
