import 'dart:convert';
import 'dart:io';

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
/// // Mark internal userID 11110 (in class groupID 298) late this morning.
/// await presence.setLate(
///   userId: 11110,
///   classGroupId: 298,
///   date: DateTime(2026, 6, 1),
///   part: DayPart.morning,
/// );
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
///   signing in again does not help.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the session,
///   also after the client logged in again where it could. The request was
///   not carried out: sign in again and retry.
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
  /// the single day [date].
  ///
  /// [schoolyearRefDate] is the reference date from [getConfig]
  /// ([PresenceConfig.schoolyearRefDate]).
  Future<List<PresencePupil>> getClassPupils({
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
  /// Throws [SmartschoolPresenceError] if the class/code cannot be resolved or
  /// the server rejects the save.
  Future<void> setLate({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    bool withoutValidReason = false,
    String motivation = '',
  }) {
    return _setStatusByName(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      codeName: lateCodeName,
      aliasName: withoutValidReason ? lateWithoutReasonAliasName : null,
      motivation: motivation,
    );
  }

  /// Marks [userId] **present** ("Aanwezig") for [date] / [part] in class
  /// [classGroupId].
  ///
  /// Useful to clear a previously recorded status. Throws
  /// [SmartschoolPresenceError] if the class/code cannot be resolved or the
  /// server rejects the save.
  Future<void> setPresent({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    String motivation = '',
  }) {
    return _setStatusByName(
      userId: userId,
      classGroupId: classGroupId,
      date: date,
      part: part,
      codeName: presentCodeName,
      aliasName: null,
      motivation: motivation,
    );
  }

  /// Resolves the class, code (and optional alias) and half-day cell, then
  /// saves the presence. Shared engine behind [setLate] / [setPresent].
  Future<void> _setStatusByName({
    required int userId,
    required int classGroupId,
    required DateTime date,
    required DayPart part,
    required String codeName,
    required String? aliasName,
    required String motivation,
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
    if (pupil == null) {
      throw SmartschoolPresenceError(
        'Pupil userID $userId was not found in class groupID $classGroupId on '
        '${formatDate(date)}.',
      );
    }

    final cell = pupil.halfDayFor(part, date: formatDate(date));

    final payload = buildPupilsPayload(
      userId: userId,
      movementId: pupil.movementId,
      presenceDate: formatDate(date),
      part: part,
      presenceId: cell?.presenceId,
      codeId: resolved.codeId,
      aliasId: resolved.aliasId,
      motivation: motivation,
    );

    final response = await _client.postFormResponse(_savePath, {
      'pupils': payload,
    });
    final errors = parseSaveErrors(_decode(response, _savePath));
    if (errors.isNotEmpty) {
      throw SmartschoolPresenceError(
        'Saving the presence for userID $userId failed.',
        errors: errors,
      );
    }
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

  /// Parses a `getClass` response into its pupils and their half-day cells.
  ///
  /// Only the half-day cells (`partOfDay: "am"|"pm"` with `hourID: null`) are
  /// retained; per-lesson rows (`partOfDay: "none"`) are ignored.
  static List<PresencePupil> parsePupils(Map<String, dynamic> json) {
    final result = <PresencePupil>[];
    final pupilsRaw = json['pupils'];
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
          if (e['hourID'] != null) continue; // per-lesson row, not a half-day
          final part = DayPart.fromWire(e['partOfDay'] as String?);
          if (part == null) continue;
          halfDays.add(
            PresenceHalfDay(
              presenceId: _asInt(e['presenceID']),
              presenceDate: e['presenceDate'] as String? ?? '',
              part: part,
              codeId: _asInt(e['codeID']),
              aliasId: _asInt(e['aliasID']),
              motivation: e['motivation'] as String? ?? '',
            ),
          );
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

  /// Extracts the server-reported error strings from a `savePupilsPresences`
  /// response.
  ///
  /// On success the response carries an empty `errors` array (and the saved
  /// records), so an empty list is returned. A non-empty list means the save
  /// was rejected. An unrecognisable body (e.g. an HTML error page) is itself
  /// reported as an error.
  static List<String> parseSaveErrors(dynamic json) {
    if (json is Map<String, dynamic>) {
      final raw = json['errors'];
      if (raw is List) {
        return raw.map((e) => e.toString()).toList();
      }
      // No errors key but flagged as failed.
      if (json['hasErrors'] == true) {
        return const ['Save reported hasErrors with no error detail.'];
      }
      return const [];
    }
    if (json is List) {
      // A bare array of saved records — success with no errors envelope.
      return const [];
    }
    return ['Unexpected save response (${json.runtimeType}).'];
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
  /// A response that is not JSON is one of two things, which need opposite
  /// actions from the caller (#5), so they are told apart by where the answer
  /// came from rather than by its content:
  ///
  /// - The login chain answered: the request was redirected to `/login`,
  ///   `/2fa` or `/account-verification` (the final URL is there, or a
  ///   redirect the HTTP client left unfollowed, as it does after a POST,
  ///   points there). Smartschool did not accept the session, so this is a
  ///   [SmartschoolSessionExpiredError]. (A `401`, the other way Smartschool
  ///   refuses a session, never gets here: the client logs in again for it,
  ///   and throws that error itself when the retry is refused too.)
  /// - The Presence module answered, with an HTML page instead of JSON: such
  ///   as Smartschool's generic `500` error page, which it sends for a
  ///   request it cannot handle (an invalid request; the account may also
  ///   lack Presence access). The session was accepted, so signing in again
  ///   does not help: this is a [SmartschoolPresenceError]. (A class the
  ///   account may not record for is answered in JSON, not here: `getConfig`
  ///   does not list it, and `setLate` / `setPresent` check that first.)
  dynamic _decode(Response<String> response, String path) {
    final loginChain = _loginChainTarget(response);
    if (loginChain != null) {
      throw SmartschoolSessionExpiredError(
        'Smartschool answered $path with its login chain ($loginChain) '
        'instead of JSON: the session has expired or was not accepted. The '
        'request was not carried out.',
      );
    }

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

  /// The path on the login chain that [response] comes from or redirects to,
  /// or `null` when it is not an answer of the login chain.
  String? _loginChainTarget(Response<String> response) {
    final realUri = response.realUri;
    if (_client.isAuthUri(realUri)) return realUri.path;

    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    final target = realUri.resolve(location);
    return _client.isAuthUri(target) ? target.path : null;
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
