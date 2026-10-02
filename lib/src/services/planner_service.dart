import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/planner_models.dart';
import '../session.dart';

export '../models/planner_models.dart';

/// Reads Smartschool's **planner** (Planner): the elements planned in a
/// calendar in a period (lessons, assignments, timetable slots, ...) and the
/// full detail of one element. A calendar is the planner of a user (the
/// account itself, or another teacher), of a class or of a location, as
/// `/planner/main/user/...`, `/planner/main/group/...` and
/// `/planner/main/location/...` show it.
///
/// ```dart
/// final planner = PlannerService(client);
///
/// final me = await planner.ownCalendar();
/// final week = await planner.getPlannedElements(
///   me,
///   from: DateTime(2026, 10, 5),
///   to: DateTime(2026, 10, 9, 23, 59, 59),
/// );
/// for (final element in week) {
///   print('${element.period.from} ${element.typeName} ${element.name ?? ''}');
/// }
///
/// // The tests of a class in a period.
/// final tests = await planner.getPlannedElements(
///   PlannerCalendar.group('4069_2001'),
///   from: DateTime(2026, 10, 5),
///   to: DateTime(2026, 10, 9, 23, 59, 59),
///   types: {PlannedElementType.assignment},
/// );
/// final detail = await planner.getDetail(tests.first);
/// print(detail.publicInfo);
/// ```
///
/// Everything here reads: the service sends GET requests only, to the
/// planner's JSON API (`/planner/api/v1/`).
///
/// ### What a teacher sees
/// A class calendar holds the elements of all teachers of the class, and a
/// colleague's lessons and assignments can be read in full, their
/// [PlannedElementDetail.privateInfo] included: "private" info is the info
/// pupils do not see, not info only its teacher sees.
///
/// ### Timetable slots
/// The timetable shows as [PlannedElementType.placeholder] elements: one per
/// teacher per lesson hour, with the classes, the course and the room, and
/// no name. Do not keep their IDs: a slot that was filled and cleared again
/// comes back with a new ID. Find a slot again by its period, course and
/// groups.
///
/// ### The list lags behind
/// After a change in the planner, [getPlannedElements] may still show the old
/// state for a few seconds, while [getPlannedElement] and [getDetail] show
/// the new one at once: read an element's detail to check a change.
///
/// ### Errors
/// - [SmartschoolPlannerError]: the planner answered with something the
///   service cannot use: another HTTP status than `200` (its
///   [SmartschoolPlannerError.statusCode]), an HTML page, invalid JSON, or
///   data in an unknown shape. The session was accepted: signing in again
///   does not help.
/// - [SmartschoolPlannedElementNotFoundError] (a [SmartschoolPlannerError]):
///   [getPlannedElement] or [getDetail] asked for an element the planner
///   does not have (`404`).
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once. Sign in again and retry.
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
/// - [ArgumentError]: a request the service refuses before sending it (see
///   each method).
class PlannerService {
  final SmartschoolClient _client;

  PlannerService(SmartschoolClient client) : _client = client;

  /// The base path of the planner's JSON API.
  ///
  /// The service sends GET requests only. The planner also answers POSTs on
  /// it that change the planner; one of them,
  /// `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, moves
  /// everything in a period to the trash. Writes that a later version adds
  /// must never use the bulk endpoints.
  static const _apiPath = '/planner/api/v1';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// The planner of the authenticated user: [PlannerCalendar.user] with the
  /// whole user ID of the session (`authenticatedUser.id`,
  /// `{platformId}_{userId}_{coaccount}`, such as `4069_146_0`).
  ///
  /// Uses the user the client read at login; when it has none yet, the
  /// client reads it from a Smartschool page first.
  ///
  /// Throws a [SmartschoolParsingError] when the session's user ID is not in
  /// that form.
  Future<PlannerCalendar> ownCalendar() async {
    final user = await _client.authenticatedUser;
    final id = user['id'];
    if (id is! String || !_userId.hasMatch(id)) {
      throw SmartschoolParsingError(
        'Could not read a planner user ID from authenticatedUser.id "$id".',
      );
    }
    return PlannerCalendar.user(id);
  }

  /// Returns the elements of [calendar] in the period from [from] to [to],
  /// in the planner's order.
  ///
  /// [from] and [to] go out as ISO 8601 with their offset from UTC (see
  /// [formatDateTime]): a local [DateTime] in the local time of this machine,
  /// a UTC one in UTC. The planner returns the elements that fall in the
  /// period; a whole school year in one request works. Use
  /// `DateTime(2026, 10, 9, 23, 59, 59)` rather than midnight to include the
  /// last day.
  ///
  /// [types] keeps only the elements of those types (the planner's `types`
  /// filter); `null` (the default) returns every type. Several types go out
  /// comma-separated, as the planner's web client sends them; only one type
  /// at a time was tried on the live site.
  ///
  /// Throws an [ArgumentError], without sending anything, when [to] is
  /// before [from], or [types] is empty or holds [PlannedElementType.other].
  Future<List<PlannedElement>> getPlannedElements(
    PlannerCalendar calendar, {
    required DateTime from,
    required DateTime to,
    Set<PlannedElementType>? types,
  }) async {
    if (to.isBefore(from)) {
      throw ArgumentError.value(to, 'to', 'is before from ($from)');
    }
    if (types != null) {
      if (types.isEmpty) {
        throw ArgumentError.value(
          types,
          'types',
          'is empty; pass null for every type',
        );
      }
      if (types.contains(PlannedElementType.other)) {
        throw ArgumentError.value(
          types,
          'types',
          'holds PlannedElementType.other, which the planner cannot filter on',
        );
      }
    }
    final what = 'the elements of $calendar';
    final response = await _client.getResponse(
      '$_apiPath/planned-elements/${calendar.type.wireName}/'
      '${Uri.encodeComponent(calendar.id)}',
      query: {
        'from': formatDateTime(from),
        'to': formatDateTime(to),
        if (types != null)
          'types': [
            for (final type in PlannedElementType.values)
              if (types.contains(type)) type.wireName,
          ].join(','),
      },
    );
    return parsePlannedElements(_decode(response, what));
  }

  /// Returns the full detail of the element of [type] with ID [id] on
  /// platform [platformId] (the [PlannedElement.type],
  /// [PlannedElement.platformId] and [PlannedElement.id] of a listed
  /// element; [getDetail] takes the element itself).
  ///
  /// The detail is up to date at once after a change, unlike the list.
  ///
  /// Throws a [SmartschoolPlannedElementNotFoundError] when the planner has
  /// no such element (`404`), and an [ArgumentError], without sending
  /// anything, for [PlannedElementType.other] (use [getDetail], which knows
  /// the element's [PlannedElement.typeName]) or an empty [id].
  Future<PlannedElementDetail> getPlannedElement({
    required PlannedElementType type,
    required int platformId,
    required String id,
  }) async {
    final typeName = type.wireName;
    if (typeName == null) {
      throw ArgumentError.value(
        type,
        'type',
        'is not a type the planner knows; use getDetail with the element',
      );
    }
    return _detail(typeName, platformId, id);
  }

  /// Returns the full detail of [element], an element of a calendar; see
  /// [getPlannedElement]. Works for an element of a type this library does
  /// not know too ([PlannedElementType.other]).
  Future<PlannedElementDetail> getDetail(PlannedElement element) =>
      _detail(element.typeName, element.platformId, element.id);

  Future<PlannedElementDetail> _detail(
    String typeName,
    int platformId,
    String id,
  ) async {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'is empty');
    }
    final what = 'the detail of $typeName $id';
    final response = await _client.getResponse(
      '$_apiPath/${Uri.encodeComponent(typeName)}/$platformId/'
      '${Uri.encodeComponent(id)}',
    );
    if (response.statusCode == 404) {
      throw SmartschoolPlannedElementNotFoundError(
        'The planner has no $typeName with ID $id on platform $platformId '
        '(HTTP 404: ${_preview(response.data ?? '')}).',
        elementType: typeName,
        platformId: platformId,
        elementId: id,
      );
    }
    final detail = parsePlannedElementDetail(_decode(response, what));
    if (detail.id.toLowerCase() != id.toLowerCase()) {
      throw SmartschoolPlannerError(
        'The planner answered $what with element ${detail.id}.',
      );
    }
    return detail;
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// [time] as the planner's API takes a date and time: ISO 8601 to the
  /// second, with the offset from UTC (`2026-11-20T11:10:00+01:00`), as the
  /// planner writes its own dates.
  ///
  /// A local [DateTime] is written in the local time of this machine, with
  /// its offset at that moment (in Belgium `+01:00` in winter, `+02:00` in
  /// summer); a UTC one in UTC (`+00:00`). Both name the same moment as
  /// [time]. With [timeZoneOffset], [time] is written in that offset
  /// instead. Milliseconds are left out.
  static String formatDateTime(DateTime time, {Duration? timeZoneOffset}) {
    final offset =
        timeZoneOffset ?? (time.isUtc ? Duration.zero : time.timeZoneOffset);
    final wall = time.toUtc().add(offset);
    String pad(int n, [int width = 2]) => '$n'.padLeft(width, '0');
    final minutes = offset.inMinutes.abs();
    return '${pad(wall.year, 4)}-${pad(wall.month)}-${pad(wall.day)}'
        'T${pad(wall.hour)}:${pad(wall.minute)}:${pad(wall.second)}'
        '${offset.isNegative ? '-' : '+'}${pad(minutes ~/ 60)}:'
        '${pad(minutes % 60)}';
  }

  /// Parses the planner's list of elements (a JSON array of elements).
  static List<PlannedElement> parsePlannedElements(dynamic json) {
    if (json is! List) {
      throw SmartschoolPlannerError(
        'The planner gave the elements of a calendar as ${json.runtimeType} '
        'instead of a list.',
      );
    }
    return [
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          PlannedElement.fromJson(item)
        else
          throw SmartschoolPlannerError(
            'The planner gave element $index of a calendar as '
            '${item.runtimeType} instead of an object.',
          ),
    ];
  }

  /// Parses the planner's detail of one element (a JSON object).
  static PlannedElementDetail parsePlannedElementDetail(dynamic json) {
    if (json is! Map<String, dynamic>) {
      throw SmartschoolPlannerError(
        'The planner gave the detail of an element as ${json.runtimeType} '
        'instead of an object.',
      );
    }
    return PlannedElementDetail.fromJson(json);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static final _userId = RegExp(r'^\d+_\d+_\d+$');

  /// The decoded JSON of [response], the planner's answer to [what].
  static dynamic _decode(Response<String> response, String what) {
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (status != 200) {
      throw SmartschoolPlannerError(
        'The planner answered $what with HTTP $status: ${_preview(body)}',
        statusCode: status,
      );
    }
    if (body.isEmpty) {
      throw SmartschoolPlannerError(
        'The planner answered $what with an empty body.',
      );
    }
    if (body.startsWith('<')) {
      throw SmartschoolPlannerError(
        'The planner answered $what with an HTML page instead of JSON: '
        '${_preview(body)}',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolPlannerError(
        'The planner answered $what with invalid JSON (${e.message}): '
        '${_preview(body)}',
      );
    }
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
