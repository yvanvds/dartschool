import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../session.dart';
import '../models/presence_models.dart';

export '../models/presence_models.dart';

/// Writes a pupil's absence/presence code for a specific half-day via
/// Smartschool's **internal** Presence module.
///
/// Smartschool's official (public) API cannot write presences; only this
/// internal endpoint (`Presence/Class/savePupilsPresences`) can. The primary
/// use case is marking a pupil **Te laat** ("late"), optionally **Te laat
/// zonder geldige reden** ("late without a valid reason"), with a motivation.
///
/// ```dart
/// final presence = PresenceService(client);
///
/// // Mark internal userID 11110 (in class groupID 298) late this morning,
/// // unless the half-day holds another status than nothing or "Aanwezig"
/// // (such as an absence the secretariat recorded).
/// final saved = await presence.setLate(
///   userId: 11110,
///   classGroupId: 298,
///   date: DateTime(2026, 6, 1),
///   part: DayPart.morning,
///   onlyReplacing: {
///     PresenceService.nothingRecorded,
///     PresenceService.presentCodeName,
///   },
/// );
/// // The half-day as stored, from the save's answer (#105).
/// print(saved?.codeId);
/// ```
///
/// ### Access requirement
/// This only works when the signed-in account has **Presence-handling access**
/// for the class (i.e. `userCanRecord` is true in the module config). Accounts
/// without that right receive a rejection from the server, surfaced as a
/// [SmartschoolPresenceError].
///
/// ### Errors
/// The failures a caller has to tell apart arrive as different types:
///
/// - [SmartschoolPresenceError]: the Presence module refused the request (an
///   error page instead of JSON, or a non-empty `errors[]` on a save), or a
///   class, code or pupil could not be resolved. The session was accepted:
///   signing in again does not help. Its subtypes, for which nothing was
///   sent: [SmartschoolPresenceChangeRefusedError], the half-day holds a
///   status that the call's `onlyReplacing` does not allow (#105); and
///   [SmartschoolPresencePupilNotFoundError], the class, as read right before
///   the save, does not list the pupil on that day (#116).
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the session,
///   also after the client logged in again and retried the request once. The
///   request was not carried out: sign in again and retry.
/// - Another [SmartschoolAuthenticationError] (e.g.
///   [SmartschoolInvalidCredentialsError]): logging in again for the request
///   failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
///
/// ### Identity note
/// The Presence module speaks Smartschool's internal `userID` (e.g. 11110),
/// which is *not* the public API's `AccountID` / `RegisterID` / `UID`. The
/// caller supplies the internal `userId` and the class `classGroupId`; classes
/// map to the public API by `adminNumber`.
class PresenceService {
  final SmartschoolClient _client;

  PresenceConfig? _config;
  final Map<int, List<PresenceCode>> _codesByStruct = {};

  PresenceService(SmartschoolClient client) : _client = client;

  // ---------------------------------------------------------------------------
  // Endpoint paths
  // ---------------------------------------------------------------------------

  static const _getConfigPath = '/Presence/Main/getConfig';
  static const _getAllCodesPath = '/Presence/Code/getAllCodes';
  static const _getClassPath = '/Presence/Class/getClass';
  static const _savePath = '/Presence/Class/savePupilsPresences';

  /// The status name that marks a pupil late.
  static const lateCodeName = 'Te laat';

  /// The alias name (of [lateCodeName]) for "late without a valid reason".
  static const lateWithoutReasonAliasName = 'Te laat zonder geldige reden';

  /// The status name that marks a pupil present.
  static const presentCodeName = 'Aanwezig';

  /// The status name of a half-day that holds nothing: no record yet, or a
  /// record without a code or alias (#105).
  ///
  /// Pass it in the `onlyReplacing` of [setLate] / [setPresent] to allow
  /// changing such a half-day; [statusNameOf] gives it for one.
  static const nothingRecorded = '';

  // ---------------------------------------------------------------------------
  // Read endpoints
  // ---------------------------------------------------------------------------

  /// Returns the Presence module configuration for the signed-in account.
  ///
  /// Cached after the first call; pass [forceRefresh] to re-fetch.
  Future<PresenceConfig> getConfig({bool forceRefresh = false}) async {
    if (_config != null && !forceRefresh) return _config!;
    final response = await _client.postFormResponse(_getConfigPath, const {});
    final decoded = _decode(response, _getConfigPath);
    if (decoded is! Map<String, dynamic>) {
      throw SmartschoolPresenceError(
        'Unexpected getConfig response (${decoded.runtimeType}).',
      );
    }
    return _config = parseConfig(decoded);
  }

  /// Returns the presence codes for [structId], resolved by structure.
  ///
  /// Cached per structure; pass [forceRefresh] to re-fetch.
  Future<List<PresenceCode>> getAllCodes(
    int structId, {
    bool forceRefresh = false,
  }) async {
    final cached = _codesByStruct[structId];
    if (cached != null && !forceRefresh) return cached;
    final response = await _client.postFormResponse(_getAllCodesPath, {
      'structID': '$structId',
      'ofschoolage': 'of_school_age',
    });
    final decoded = _decode(response, _getAllCodesPath);
    if (decoded is! List) {
      throw SmartschoolPresenceError(
        'Unexpected getAllCodes response (${decoded.runtimeType}).',
      );
    }
    return _codesByStruct[structId] = parseCodes(decoded);
  }

  /// Returns the pupils (with their half-day cells) of class [classGroupId] for
  /// the single day [date], with what the Presence module said about the
  /// class on that day (#104).
  ///
  /// [schoolyearRefDate] is the reference date from [getConfig]
  /// ([PresenceConfig.schoolyearRefDate]).
  ///
  /// The result is a `List<PresencePupil>`. When it is empty, the module says
  /// why: [PresenceClassPupils.saveIsAllowed] is `false` and
  /// [PresenceClassPupils.errorMessage] has its reason, such as a day after
  /// today ("Het is niet mogelijk om in de toekomst afwezigheden op te
  /// nemen.") or a class without pupils ("Deze klas bevat geen
  /// leerlingen."). [PresenceClassPupils.classRef] is `null` for a class ID
  /// the module does not know, which it answers with that same reason. See
  /// [PresenceClassPupils] for what was seen live. A class the module lists
  /// no pupils for is not an error: nothing is thrown for it.
  Future<PresenceClassPupils> getClassPupils({
    required int classGroupId,
    required DateTime date,
    required String schoolyearRefDate,
  }) async {
    final day = formatDate(date);
    final response = await _client.postFormResponse(_getClassPath, {
      'classID': '$classGroupId',
      'startDate': day,
      'endDate': day,
      'schoolyearRefDate': schoolyearRefDate,
      'includePupils': '1',
      'includePresences': '1',
    });
    final decoded = _decode(response, _getClassPath);
    if (decoded is! Map<String, dynamic>) {
      throw SmartschoolPresenceError(
        'Unexpected getClass response (${decoded.runtimeType}).',
      );
    }
    return parsePupils(decoded);
  }

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Marks [userId] **late** for [date] / [part] in class [classGroupId].
  ///
  /// When [withoutValidReason] is true the "Te laat zonder geldige reden" alias
  /// is used instead of plain "Te laat". [motivation] is an optional free-text
  /// note stored on the presence.
  ///
  /// The call reads the class (`getClass`) right before it saves. Without
  /// [onlyReplacing] it saves over whatever the half-day holds, also an
  /// absence the secretariat recorded (a doctor's note, say). With it, the
  /// half-day may only hold one of the statuses it names, by name as
  /// [statusNameOf] gives them (case-insensitive): such as [presentCodeName],
  /// [lateCodeName], [lateWithoutReasonAliasName], or [nothingRecorded] for
  /// a half-day that holds nothing. For any other status, as read right
  /// before the save, it throws a [SmartschoolPresenceChangeRefusedError]
  /// that names it, and sends nothing (#105):
  ///
  /// ```dart
  /// await presence.setLate(
  ///   userId: 11110,
  ///   classGroupId: 298,
  ///   date: DateTime(2026, 6, 1),
  ///   part: DayPart.morning,
  ///   onlyReplacing: {
  ///     PresenceService.nothingRecorded,
  ///     PresenceService.presentCodeName,
  ///     PresenceService.lateCodeName,
  ///     PresenceService.lateWithoutReasonAliasName,
  ///   },
  /// );
  /// ```
  ///
  /// Returns the half-day as stored (#105): the record the Presence module
  /// answered the save with (its `presenceId`, a new one when the half-day
  /// had none, and the `codeId` / `aliasId` and `motivation` it stores),
  /// with [PresenceSavedHalfDay.before], the half-day as read right before
  /// the save. Nothing more is read for it. `null` when the answer holds no
  /// record of the half-day: the save itself was confirmed (no `errors`), so
  /// read the class to see what it holds.
  ///
  /// Throws [SmartschoolPresenceError] if the class/code cannot be resolved or
  /// the server rejects the save: then its
  /// [SmartschoolPresenceError.saveErrors] has the module's errors, each with
  /// its reason and the record that was not saved (#109). The class read
  /// right before the save not listing the pupil on that day is its subtype
  /// [SmartschoolPresencePupilNotFoundError], with the module's reason when
  /// it listed no pupils (#116); nothing was sent.
  Future<PresenceSavedHalfDay?> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    bool withoutValidReason = false,
    String motivation = '',
    Set<String>? onlyReplacing,
  }) {
    return _setStatusByName(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      codeName: lateCodeName,
      aliasName: withoutValidReason ? lateWithoutReasonAliasName : null,
      motivation: motivation,
      onlyReplacing: onlyReplacing,
    );
  }

  /// Marks [userId] **present** ("Aanwezig") for [date] / [part] in class
  /// [classGroupId].
  ///
  /// Useful to clear a previously recorded status. [onlyReplacing] and the
  /// result are as for [setLate]: pass, say, `{PresenceService.lateCodeName}`
  /// to clear a "Te laat" and refuse any other status (#105).
  ///
  /// Throws [SmartschoolPresenceError] if the class/code cannot be resolved or
  /// the server rejects the save, its subtype
  /// [SmartschoolPresenceChangeRefusedError] when [onlyReplacing] refuses the
  /// change, and its subtype [SmartschoolPresencePupilNotFoundError] when the
  /// class does not list the pupil on that day (nothing was sent for
  /// either).
  Future<PresenceSavedHalfDay?> setPresent({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    String motivation = '',
    Set<String>? onlyReplacing,
  }) {
    return _setStatusByName(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      codeName: presentCodeName,
      aliasName: null,
      motivation: motivation,
      onlyReplacing: onlyReplacing,
    );
  }

  /// Resolves the class, code (and optional alias) and half-day cell, checks
  /// the cell against [onlyReplacing], then saves the presence and returns
  /// the half-day as stored. Shared engine behind [setLate] / [setPresent].
  Future<PresenceSavedHalfDay?> _setStatusByName({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    required String codeName,
    required String? aliasName,
    required String motivation,
    required Set<String>? onlyReplacing,
  }) async {
    final config = await getConfig();
    final classRef = config.classForGroup(classGroupId);
    if (classRef == null) {
      throw SmartschoolPresenceError(
        'Class groupID $classGroupId is not among the classes this account '
        'may record presences for.',
      );
    }
    final structId = classRef.structId;
    if (structId == null) {
      throw SmartschoolPresenceError(
        'Class groupID $classGroupId has no structID (it looks like a virtual '
        'grouping class, not an official class).',
      );
    }

    final codes = await getAllCodes(structId);
    final resolved = resolveCode(
      codes,
      codeName: codeName,
      aliasName: aliasName,
    );

    final pupils = await getClassPupils(
      classGroupId: classGroupId,
      date: date,
      schoolyearRefDate: config.schoolyearRefDate,
    );
    PresencePupil? pupil;
    for (final p in pupils) {
      if (p.userId == userId) {
        pupil = p;
        break;
      }
    }
    final day = formatDate(date);
    if (pupil == null) {
      // The module's reason when it listed no pupils (#104), such as a day
      // after today.
      final listedNone = pupils.isEmpty;
      final reason = listedNone ? pupils.errorMessage : null;
      final why = reason == null
          ? ''
          : ': the Presence module listed no pupils ("$reason")';
      throw SmartschoolPresencePupilNotFoundError(
        'Pupil userID $userId was not found in class groupID $classGroupId on '
        '$day$why.',
        userId: userId,
        classGroupId: classGroupId,
        date: day,
        saveIsAllowed: listedNone ? pupils.saveIsAllowed : null,
        errorMessage: reason,
      );
    }

    final cell = pupil.halfDayFor(part, date: day);

    if (onlyReplacing != null) {
      final held = statusNameOf(cell, codes);
      if (!_allows(onlyReplacing, held)) {
        throw SmartschoolPresenceChangeRefusedError(
          'The ${part.name} of $day of pupil userID $userId in class groupID '
          '$classGroupId holds ${_describeHeld(held, cell)}, which '
          'onlyReplacing does not allow (${_describeAllowed(onlyReplacing)}): '
          'nothing was sent.',
          userId: userId,
          part: part,
          date: day,
          halfDay: cell,
          heldStatus: held,
          onlyReplacing: onlyReplacing,
        );
      }
    }

    final payload = buildPupilsPayload(
      userId: userId,
      movementId: pupil.movementId,
      presenceDate: day,
      part: part,
      presenceId: cell?.presenceId,
      codeId: resolved.codeId,
      aliasId: resolved.aliasId,
      motivation: motivation,
    );

    final response = await _client.postFormResponse(_savePath, {
      'pupils': payload,
    });
    final answer = _decode(response, _savePath);
    final saveErrors = parseSaveErrorDetails(answer);
    if (saveErrors.isNotEmpty) {
      throw SmartschoolPresenceError(
        'Saving the presence for userID $userId failed.',
        errors: [for (final error in saveErrors) error.message],
        saveErrors: saveErrors,
      );
    }
    final stored = parseSavedHalfDay(
      answer,
      userId: userId,
      date: day,
      part: part,
    );
    return stored == null
        ? null
        : PresenceSavedHalfDay.of(stored, before: cell);
  }

  /// Whether [onlyReplacing] holds [held] (a name from [statusNameOf]),
  /// compared trimmed and case-insensitively. A status without a name
  /// (`null`) is never allowed.
  static bool _allows(Set<String> onlyReplacing, String? held) {
    if (held == null) return false;
    final target = held.trim().toLowerCase();
    return onlyReplacing.any((name) => name.trim().toLowerCase() == target);
  }

  /// What the half-day [cell] holds, for a message: [held] is its status
  /// name from [statusNameOf].
  static String _describeHeld(String? held, PresenceHalfDay? cell) {
    if (held == null) {
      final id = cell?.aliasId != null
          ? 'aliasID ${cell?.aliasId}'
          : 'codeID ${cell?.codeId}';
      return 'a status that is not among the codes of its school structure '
          '($id)';
    }
    return held.trim().isEmpty ? 'nothing recorded' : '"$held"';
  }

  /// The statuses of an `onlyReplacing`, for a message.
  static String _describeAllowed(Set<String> onlyReplacing) {
    if (onlyReplacing.isEmpty) return 'no status';
    return [
      for (final name in onlyReplacing)
        name.trim().isEmpty ? 'nothing recorded' : '"${name.trim()}"',
    ].join(', ');
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Parses a `getConfig` response body into a [PresenceConfig].
  static PresenceConfig parseConfig(Map<String, dynamic> json) {
    final state = json['state'] as Map<String, dynamic>? ?? const {};
    final main = json['main'] as Map<String, dynamic>? ?? const {};

    final activeRaw = state['activeClass'];
    final activeClass = activeRaw is Map<String, dynamic>
        ? PresenceClassRef.fromJson(activeRaw)
        : null;

    final allowed = <PresenceClassRef>[];
    final allowedRaw = main['allowedClasses'];
    if (allowedRaw is List) {
      for (final c in allowedRaw) {
        if (c is Map<String, dynamic>) {
          allowed.add(PresenceClassRef.fromJson(c));
        }
      }
    }

    return PresenceConfig(
      activeClass: activeClass,
      allowedClasses: allowed,
      schoolyearRefDate: state['schoolyear'] as String? ?? '',
    );
  }

  /// Parses a `getAllCodes` response array into a list of [PresenceCode]s.
  static List<PresenceCode> parseCodes(List<dynamic> json) {
    final codes = <PresenceCode>[];
    for (final c in json) {
      if (c is Map<String, dynamic>) {
        codes.add(PresenceCode.fromJson(c));
      }
    }
    return codes;
  }

  /// Parses a `getClass` response into its pupils and their half-day cells,
  /// with what the module said about the class (#104): the class it names
  /// ([PresenceClassRef], `null` when it names none), `saveIsAllowed` and
  /// `errorMessage` (`null` when absent or empty).
  ///
  /// Only the half-day cells (`partOfDay: "am"|"pm"` with `hourID: null`) are
  /// retained; per-lesson rows (`partOfDay: "none"`) are ignored.
  static PresenceClassPupils parsePupils(Map<String, dynamic> json) {
    final saveIsAllowed = json['saveIsAllowed'];
    final errorMessage = json['errorMessage'];
    final trimmedMessage = errorMessage is String ? errorMessage.trim() : '';
    return PresenceClassPupils(
      _parsePupilList(json['pupils']),
      classRef: _asInt(json['groupID']) == null
          ? null
          : PresenceClassRef.fromJson(json),
      saveIsAllowed: saveIsAllowed is bool ? saveIsAllowed : null,
      errorMessage: trimmedMessage.isEmpty ? null : trimmedMessage,
    );
  }

  static List<PresencePupil> _parsePupilList(Object? pupilsRaw) {
    final result = <PresencePupil>[];
    if (pupilsRaw is! List) return result;

    for (final p in pupilsRaw) {
      if (p is! Map<String, dynamic>) continue;
      final userId = _asInt(p['userID']);
      final movementId = _asInt(p['movementID']);
      if (userId == null || movementId == null) continue;

      final halfDays = <PresenceHalfDay>[];
      final presenceRaw = p['presence'];
      if (presenceRaw is List) {
        for (final e in presenceRaw) {
          if (e is! Map<String, dynamic>) continue;
          final halfDay = _parseHalfDay(e);
          if (halfDay != null) halfDays.add(halfDay);
        }
      }

      result.add(
        PresencePupil(
          userId: userId,
          movementId: movementId,
          name: p['name'] as String? ?? '',
          halfDays: halfDays,
        ),
      );
    }
    return result;
  }

  /// Parses a presence record (of `getClass`, or of the answer to a save) as
  /// a half-day cell, or `null` for a per-lesson row (`hourID` set, or a
  /// `partOfDay` other than `"am"` / `"pm"`).
  static PresenceHalfDay? _parseHalfDay(Map<String, dynamic> e) {
    if (e['hourID'] != null) return null; // per-lesson row, not a half-day
    final part = DayPart.fromWire(e['partOfDay'] as String?);
    if (part == null) return null;
    return PresenceHalfDay(
      presenceId: _asInt(e['presenceID']),
      presenceDate: e['presenceDate'] as String? ?? '',
      part: part,
      codeId: _asInt(e['codeID']),
      aliasId: _asInt(e['aliasID']),
      motivation: e['motivation'] as String? ?? '',
    );
  }

  /// Returns the half-day of [userId] on [date] (`yyyy-MM-dd`) / [part] that
  /// a `savePupilsPresences` answer holds (#105), or `null` when it holds
  /// none.
  ///
  /// The module answers a save with the pupils sent, each with the records
  /// as stored (`{"pupils":[{"userID", "movementID", "presence":[...]}],
  /// "errors":[]}`, the shape its web client reads), in the shape of the
  /// records of `getClass`: a new `presenceID` for a half-day that had no
  /// record. A record is the pupil's by its `studentID`, or else by the
  /// pupil's `userID`.
  static PresenceHalfDay? parseSavedHalfDay(
    Object? json, {
    required int userId,
    required String date,
    required DayPart part,
  }) {
    if (json is! Map<String, dynamic>) return null;
    final pupils = json['pupils'];
    if (pupils is! List) return null;
    for (final pupil in pupils) {
      if (pupil is! Map<String, dynamic>) continue;
      final records = pupil['presence'];
      if (records is! List) continue;
      for (final record in records) {
        if (record is! Map<String, dynamic>) continue;
        final owner = _asInt(record['studentID']) ?? _asInt(pupil['userID']);
        if (owner != userId) continue;
        // Checked here, so that a record in another shape is passed over
        // rather than failing a call whose save went through.
        if (record['presenceDate'] != date) continue;
        if (record['partOfDay'] != part.wire) continue;
        final motivation = record['motivation'];
        if (motivation != null && motivation is! String) continue;
        final halfDay = _parseHalfDay(record);
        if (halfDay != null) return halfDay;
      }
    }
    return null;
  }

  /// Returns the name of the status [halfDay] holds, from [codes] (those of
  /// the class's school structure, [getAllCodes]) (#105):
  ///
  /// - the name of its alias when it has an `aliasId` (the module stores
  ///   "Te laat zonder geldige reden" as an alias, with `codeId` `null`);
  /// - else the name of its code, such as [presentCodeName] or
  ///   "Doktersattest";
  /// - [nothingRecorded] (`""`) when it has neither, or there is no
  ///   [halfDay] (no record yet);
  /// - `null` when its code or alias is not among [codes], or has no name.
  static String? statusNameOf(
    PresenceHalfDay? halfDay,
    List<PresenceCode> codes,
  ) {
    final aliasId = halfDay?.aliasId;
    if (aliasId != null) {
      for (final code in codes) {
        for (final alias in code.aliases) {
          if (alias.aliasId == aliasId) return _named(alias.name);
        }
      }
      return null;
    }
    final codeId = halfDay?.codeId;
    if (codeId != null) {
      for (final code in codes) {
        if (code.codeId == codeId) return _named(code.name);
      }
      return null;
    }
    return nothingRecorded;
  }

  static String? _named(String name) => name.trim().isEmpty ? null : name;

  /// Resolves [codeName] (and optional [aliasName]) against [codes], returning
  /// the `codeID` / `aliasID` pair to send when saving.
  ///
  /// When an alias is requested the server keys on the alias, so `codeId` is
  /// returned as `null` and `aliasId` carries the alias. Matching is by name,
  /// case-insensitively. Throws [SmartschoolPresenceError] when no match.
  static ({int? codeId, int? aliasId}) resolveCode(
    List<PresenceCode> codes, {
    required String codeName,
    String? aliasName,
  }) {
    final target = codeName.trim().toLowerCase();
    PresenceCode? match;
    for (final c in codes) {
      if (c.name.toLowerCase() == target) {
        match = c;
        break;
      }
    }
    if (match == null) {
      throw SmartschoolPresenceError(
        'Presence code "$codeName" was not found for this school structure.',
      );
    }

    if (aliasName == null) {
      return (codeId: match.codeId, aliasId: null);
    }

    final alias = match.aliasByName(aliasName);
    if (alias == null) {
      throw SmartschoolPresenceError(
        'Presence alias "$aliasName" was not found under code "$codeName".',
      );
    }
    // The server stores codeID: null and keys on the alias.
    return (codeId: null, aliasId: alias.aliasId);
  }

  /// Builds the JSON string sent as the single `pupils` form field of
  /// `savePupilsPresences`.
  ///
  /// [presenceId] is `null` for the "create" case (no existing half-day cell).
  static String buildPupilsPayload({
    required int userId,
    required int movementId,
    required String presenceDate,
    required DayPart part,
    required int? presenceId,
    required int? codeId,
    required int? aliasId,
    required String motivation,
  }) {
    return jsonEncode([
      {
        'userID': userId,
        'movementID': movementId,
        'presence': [
          {
            'presenceID': presenceId,
            'presenceDate': presenceDate,
            'studentID': userId,
            'hourID': null,
            'partOfDay': part.wire,
            'codeID': codeId,
            'aliasID': aliasId,
            'motivation': motivation,
            'deleteStatus': 0,
          },
        ],
      },
    ]);
  }

  /// Extracts the server-reported errors from a `savePupilsPresences`
  /// response, as text: the [PresenceSaveError.message] of each error that
  /// [parseSaveErrorDetails] gives, the module's reason, without the pupil's
  /// name (#109).
  ///
  /// On success the response carries an empty `errors` array (and the saved
  /// records), so an empty list is returned. A non-empty list means the save
  /// was rejected. An unrecognisable body (e.g. an HTML error page) is itself
  /// reported as an error.
  static List<String> parseSaveErrors(dynamic json) => [
    for (final error in parseSaveErrorDetails(json)) error.message,
  ];

  /// Extracts the server-reported errors from a `savePupilsPresences`
  /// response, typed (#109).
  ///
  /// The module answers a refused save with an `errors` array of objects,
  /// which its web client reads (its Presence JavaScript, read-only): the
  /// reason in `message`, and the record that was not saved in `presence`,
  /// with its `presenceDate`, `partOfDay`, `studentID` and `pupil` (the
  /// pupil's name). Each becomes a [PresenceSaveError] with the `message`
  /// (trimmed; [PresenceSaveError.noReason] when it has none) and the
  /// record's day, half of the day, `studentID` and pupil's name. An error
  /// that is a text is kept as its message; an error in another shape gets a
  /// message that says so, without its content, which can name a pupil.
  ///
  /// On success the response carries an empty `errors` array (and the saved
  /// records), so an empty list is returned. A non-empty list means the save
  /// was rejected. An answer flagged `hasErrors` without an `errors` array,
  /// and an unrecognisable body, are each reported as one error with a
  /// message of the library's.
  static List<PresenceSaveError> parseSaveErrorDetails(dynamic json) {
    if (json is Map<String, dynamic>) {
      final raw = json['errors'];
      if (raw is List) {
        return [for (final error in raw) _parseSaveError(error)];
      }
      // No errors key but flagged as failed.
      if (json['hasErrors'] == true) {
        return const [
          PresenceSaveError(
            message: 'Save reported hasErrors with no error detail.',
          ),
        ];
      }
      return const [];
    }
    if (json is List) {
      // A bare array of saved records — success with no errors envelope.
      return const [];
    }
    return [
      PresenceSaveError(
        message: 'Unexpected save response (${json.runtimeType}).',
      ),
    ];
  }

  /// One entry of a save answer's `errors`, as [parseSaveErrorDetails]
  /// describes.
  static PresenceSaveError _parseSaveError(Object? error) {
    if (error is String) {
      final text = error.trim();
      return PresenceSaveError(
        message: text.isEmpty ? PresenceSaveError.noReason : text,
      );
    }
    if (error is! Map) {
      return PresenceSaveError(
        message:
            'The Presence module refused the save with an error the library '
            'does not recognise (${error.runtimeType}).',
      );
    }
    final message = error['message'];
    final text = message is String ? message.trim() : '';
    final presence = error['presence'];
    final record = presence is Map ? presence : const {};
    final date = record['presenceDate'];
    final partOfDay = record['partOfDay'];
    final pupil = record['pupil'];
    return PresenceSaveError(
      message: text.isEmpty ? PresenceSaveError.noReason : text,
      userId: _asInt(record['studentID']),
      date: date is String && date.isNotEmpty ? date : null,
      part: DayPart.fromWire(partOfDay is String ? partOfDay : null),
      pupilName: pupil is String && pupil.trim().isNotEmpty
          ? pupil.trim()
          : null,
    );
  }

  /// Formats [date] as `yyyy-MM-dd` (the format the Presence API expects).
  static String formatDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Decodes the JSON body of [response] to a request for [path].
  ///
  /// A response that is not JSON is the Presence module answering with an
  /// HTML page instead: such as Smartschool's generic `500` error page, which
  /// it sends for a request it cannot handle (an invalid request; the account
  /// may also lack Presence access). The session was accepted, so signing in
  /// again does not help: this is a [SmartschoolPresenceError]. (A class the
  /// account may not record for is answered in JSON, not here: `getConfig`
  /// does not list it, and `setLate` / `setPresent` check that first. So is
  /// a class `getClass` lists no pupils for: [getClassPupils] returns the
  /// module's reason with the empty list, #104.)
  ///
  /// The login chain answering never gets here (#5, #22): for a request that
  /// is answered with `401` or redirected to `/login`, `/2fa` or
  /// `/account-verification`, the client logs in again and retries it once,
  /// and a retry that Smartschool refuses again fails with a
  /// [SmartschoolSessionExpiredError].
  dynamic _decode(Response<String> response, String path) {
    final body = response.data ?? '';
    final status = response.statusCode;
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty) {
      throw SmartschoolPresenceError(
        'Empty response from $path (HTTP $status).',
      );
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      throw SmartschoolPresenceError(
        'The Presence module answered $path with an HTML page (HTTP $status) '
        'instead of JSON: it could not handle the request (the request is '
        'invalid, or the account may lack Presence access).',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolPresenceError('Failed to decode JSON from $path: $e');
    }
  }
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}
