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
/// `/planner/main/location/...` show it; [searchCalendars] finds one by
/// name.
///
/// For the planner's workload view ("werkbelasting") it reads the school's
/// assignment types ([getAssignmentTypes]), the assignments of classes in a
/// period ([getAssignmentsOfGroups]) and the planner's workload figures of
/// those classes per day ([getWorkloadSchedule]) or for one moment
/// ([calculateWorkload]). It returns the facts as the planner gives them;
/// choosing a good moment for a test is up to the caller.
///
/// ```dart
/// final planner = PlannerService(client);
///
/// // A class found by name.
/// final hits = await planner.searchCalendars('6A1');
/// final klas = hits
///     .firstWhere((hit) => hit.kind == PlannerSearchResultKind.group)
///     .calendar!;
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
///   klas,
///   from: DateTime(2026, 10, 5),
///   to: DateTime(2026, 10, 9, 23, 59, 59),
///   types: {PlannedElementType.assignment},
/// );
/// final detail = await planner.getDetail(tests.first);
/// print(detail.publicInfo);
///
/// // The assignments of the class in that week, of all its teachers, and
/// // the planner's workload figures per day.
/// final assignments = await planner.getAssignmentsOfGroups(
///   groupIds: [klas.id],
///   from: DateTime(2026, 10, 5),
///   to: DateTime(2026, 10, 9, 23, 59, 59),
/// );
/// final load = await planner.getWorkloadSchedule(
///   groupIds: [klas.id],
///   from: DateTime(2026, 10, 5),
///   to: DateTime(2026, 10, 9, 23, 59, 59),
/// );
/// ```
///
/// Everything here reads, through the planner's JSON API
/// (`/planner/api/v1/`; the assignment types through the lesson-content API,
/// `/lesson-content/api/v1/`): the service sends GET requests, and POSTs that
/// only read: the search of [searchCalendars] and the workload calls of
/// [getAssignmentsOfGroups], [getWorkloadSchedule] and [calculateWorkload].
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
  /// The service sends GET requests, and POSTs that only read:
  /// `quick-search/planner/search`, and `workload/planned-elements`,
  /// `workload/schedule` and `workload/calculate` (checked in the web
  /// client's code: it reads with them, and `calculate` is the check it runs
  /// before it saves an assignment). The planner also answers POSTs on it
  /// that change the planner or the user's settings: the favourites of the
  /// search (`quick-search/planner/mark-as-favourite` and
  /// `discard-as-favourite`), and
  /// `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, which
  /// moves everything in a period to the trash. Writes that a later version
  /// adds must never use the bulk endpoints.
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

  /// Finds the calendars of the users, classes and locations whose name
  /// holds [text], as the search field of the planner ("Zoek een planner")
  /// does: `6A` finds `6A1` and `6A2`, `Janssens` every Janssens, `101` the
  /// room. Returns the hits in the planner's order; an empty list when
  /// nothing matches.
  ///
  /// Each hit has its [PlannerSearchResult.calendar], for
  /// [getPlannedElements]; a hit of a kind this library does not know is
  /// kept as [PlannerSearchResultKind.other], without a calendar.
  ///
  /// Users are not told apart: teachers, pupils and co-accounts come in the
  /// same form (a co-account with an ID of its own and a description such as
  /// `Interimaris van ...`). Telling teachers apart is up to the caller, for
  /// instance with the teacher list of `SkoreService.getTeachers()`, whose
  /// IDs are the middle part of a user's calendar ID.
  ///
  /// Sends `POST quick-search/planner/search` with
  /// `{"searchString": text, "searchOptions": []}` as the web client does:
  /// a POST that only reads. [text] goes out without the white space around
  /// it. The planner's `include-deleted` option is not sent, so the search
  /// leaves out what the planner counts as deleted; the user's favourites of
  /// the search are left alone.
  ///
  /// Throws an [ArgumentError], without sending anything, when [text] is
  /// empty or white space only.
  Future<List<PlannerSearchResult>> searchCalendars(String text) async {
    final searchString = text.trim();
    if (searchString.isEmpty) {
      throw ArgumentError.value(text, 'text', 'is empty');
    }
    final response = await _client.postJsonResponse(
      '$_apiPath/quick-search/planner/search',
      data: {'searchString': searchString, 'searchOptions': const <Object>[]},
    );
    return parseSearchResults(
      _decode(response, 'the search for "$searchString"'),
    );
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
    _checkPeriod(from, to);
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

  // ---------------------------------------------------------------------------
  // Assignment types and workload
  // ---------------------------------------------------------------------------

  /// Returns the school's assignment types (such as `Kleine Overhoring`,
  /// `KO`), in the order the planner gives them: the types a teacher can
  /// choose for an assignment, and the same objects a planned assignment
  /// names as its [PlannedElement.assignmentType].
  ///
  /// Sends `GET /lesson-content/api/v1/assignments/applicable-assignment-types`
  /// as the planner's web client does: the list lives in the lesson-content
  /// API, not in the planner's. The type of the planner's lessons
  /// (`assignmentTypeConfig.customTypes.lesson` in the page config) is not
  /// in it.
  Future<List<PlannerAssignmentType>> getAssignmentTypes() async {
    final response = await _client.getResponse(
      '$_lessonContentPath/assignments/applicable-assignment-types',
    );
    return parseAssignmentTypes(_decode(response, 'the assignment types'));
  }

  /// Returns the assignments of the classes [groupIds] in the period from
  /// [from] to [to], of every teacher, in the planner's order (which is not
  /// by date): the assignments that the planner's workload view
  /// ("werkbelasting") shows for those classes, with their
  /// [PlannedElement.assignmentType] and their teacher
  /// ([PlannedElement.organiserUsers]).
  ///
  /// [groupIds] are class calendar IDs `{platformId}_{groupId}`
  /// ([PlannerCalendar.id] of a class, [PlannerGroup.id]); one request covers
  /// them all. An assignment of several classes comes once, with all its
  /// classes in [PlannedElement.participantGroups], also the classes that
  /// were not asked for. The same assignments are in each class calendar
  /// ([getPlannedElements] with [PlannedElementType.assignment]).
  ///
  /// Sends `POST workload/planned-elements?from=&to=` with
  /// `{"users": [], "groups": groupIds, "courses": []}` as the web client
  /// does: a POST that only reads. [from] and [to] go out as in
  /// [getPlannedElements]. Only assignments were seen in the answer; an
  /// element of another type would be returned as well.
  ///
  /// Throws an [ArgumentError], without sending anything, when [groupIds] is
  /// empty or holds an ID that is not a group ID, or [to] is before [from].
  Future<List<PlannedElement>> getAssignmentsOfGroups({
    required Iterable<String> groupIds,
    required DateTime from,
    required DateTime to,
  }) async {
    final groups = _checkedGroupIds(groupIds);
    _checkPeriod(from, to);
    final response = await _client.postJsonResponse(
      '$_apiPath/workload/planned-elements',
      query: {'from': formatDateTime(from), 'to': formatDateTime(to)},
      data: {
        'users': const <Object>[],
        'groups': groups,
        'courses': const <Object>[],
      },
    );
    return parsePlannedElements(
      _decode(response, 'the assignments of ${groups.join(', ')}'),
    );
  }

  /// Returns the workload of the classes [groupIds] per day of the period
  /// from [from] to [to], as the planner's workload view shows it: for every
  /// day the planner names, a [PlannerGroupWorkload] per class, with the
  /// planner's `weight` and `concurrentWeight` and the class's workload
  /// setting.
  ///
  /// The keys are the days as the planner names them (`2026-10-05`), as local
  /// [DateTime]s at midnight (`DateTime(2026, 10, 5)`), in date order; an
  /// empty map when the planner names no day. The figures are returned as
  /// the planner gives them: see [PlannerGroupWorkload] for what they say
  /// (at the school seen live: nothing, every weight was `0`). The
  /// assignments behind them are read with [getAssignmentsOfGroups].
  ///
  /// Sends `POST workload/schedule?from=&to=` with `{"groups": groupIds}` as
  /// the web client does: a POST that only reads. [from] and [to] go out as
  /// in [getPlannedElements].
  ///
  /// Throws an [ArgumentError], without sending anything, when [groupIds] is
  /// empty or holds an ID that is not a group ID, or [to] is before [from].
  Future<Map<DateTime, List<PlannerGroupWorkload>>> getWorkloadSchedule({
    required Iterable<String> groupIds,
    required DateTime from,
    required DateTime to,
  }) async {
    final groups = _checkedGroupIds(groupIds);
    _checkPeriod(from, to);
    final response = await _client.postJsonResponse(
      '$_apiPath/workload/schedule',
      query: {'from': formatDateTime(from), 'to': formatDateTime(to)},
      data: {'groups': groups},
    );
    return parseWorkloadSchedule(
      _decode(response, 'the workload schedule of ${groups.join(', ')}'),
    );
  }

  /// Returns the workload of the classes [groupIds] for an assignment from
  /// [from] to [to]: a [PlannerGroupWorkload] per class, as the planner
  /// computes it before it saves an assignment (the web client warns when a
  /// limit is passed). The figures are returned as the planner gives them;
  /// see [PlannerGroupWorkload].
  ///
  /// [wholeDay] and [deadline] are the period's flags as an assignment has
  /// them (an assignment is a deadline: `deadline` defaults to `true`).
  ///
  /// Sends `POST workload/calculate` with `{"period": {"dateTimeFrom",
  /// "dateTimeTo", "wholeDay", "deadline"}, "participants": {"users": [],
  /// "groups": groupIds, "groupFilters": {}}}` as the web client does: a
  /// POST that only reads, which saves nothing. [from] and [to] go out as
  /// [formatDateTime] writes them. The web client's `excludePlannedElement`,
  /// which leaves out an assignment that is being moved, is not sent.
  ///
  /// Throws an [ArgumentError], without sending anything, when [groupIds] is
  /// empty or holds an ID that is not a group ID, or [to] is before [from].
  Future<List<PlannerGroupWorkload>> calculateWorkload({
    required Iterable<String> groupIds,
    required DateTime from,
    required DateTime to,
    bool wholeDay = false,
    bool deadline = true,
  }) async {
    final groups = _checkedGroupIds(groupIds);
    _checkPeriod(from, to);
    final response = await _client.postJsonResponse(
      '$_apiPath/workload/calculate',
      data: {
        'period': {
          'dateTimeFrom': formatDateTime(from),
          'dateTimeTo': formatDateTime(to),
          'wholeDay': wholeDay,
          'deadline': deadline,
        },
        'participants': {
          'users': const <Object>[],
          'groups': groups,
          'groupFilters': const <String, Object>{},
        },
      },
    );
    return parseGroupWorkloads(
      _decode(response, 'the workload of ${groups.join(', ')}'),
    );
  }

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

  /// Parses the hits of the planner's search (a JSON array of hits).
  static List<PlannerSearchResult> parseSearchResults(dynamic json) {
    if (json is! List) {
      throw SmartschoolPlannerError(
        'The planner gave the hits of a search as ${json.runtimeType} '
        'instead of a list.',
      );
    }
    return [
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          PlannerSearchResult.fromJson(item)
        else
          throw SmartschoolPlannerError(
            'The planner gave hit $index of a search as ${item.runtimeType} '
            'instead of an object.',
          ),
    ];
  }

  /// Parses the school's assignment types (a JSON array of types).
  static List<PlannerAssignmentType> parseAssignmentTypes(dynamic json) {
    if (json is! List) {
      throw SmartschoolPlannerError(
        'The planner gave the assignment types as ${json.runtimeType} '
        'instead of a list.',
      );
    }
    return [
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          PlannerAssignmentType.fromJson(item)
        else
          throw SmartschoolPlannerError(
            'The planner gave assignment type $index as ${item.runtimeType} '
            'instead of an object.',
          ),
    ];
  }

  /// Parses the planner's workload per day (`{"schedule": {"2026-10-05":
  /// [...], ...}}`): the days as local [DateTime]s at midnight, in date
  /// order, each with the workload of every group. An empty schedule (`{}`,
  /// or `[]` as the planner may write an empty map) is an empty map.
  static Map<DateTime, List<PlannerGroupWorkload>> parseWorkloadSchedule(
    dynamic json,
  ) {
    if (json is! Map<String, dynamic>) {
      throw SmartschoolPlannerError(
        'The planner gave the workload schedule as ${json.runtimeType} '
        'instead of an object.',
      );
    }
    final schedule = json['schedule'];
    if (schedule is List && schedule.isEmpty) return const {};
    if (schedule is! Map<String, dynamic>) {
      throw SmartschoolPlannerError(
        'The planner gave the days of the workload schedule as '
        '${schedule.runtimeType} instead of an object.',
      );
    }
    final days = <DateTime, List<PlannerGroupWorkload>>{};
    for (final MapEntry(:key, :value) in schedule.entries) {
      final day = _parseDay(key);
      if (day == null) {
        throw SmartschoolPlannerError(
          'The planner gave a day of the workload schedule as "$key", which '
          'is not a date.',
        );
      }
      days[day] = parseGroupWorkloads(value, day: key);
    }
    final sorted = days.keys.toList()..sort();
    return Map.unmodifiable({for (final day in sorted) day: days[day]!});
  }

  /// Parses the planner's workload of groups (a JSON array, one per group),
  /// as the planner gives it for one moment, or for [day] of a schedule.
  static List<PlannerGroupWorkload> parseGroupWorkloads(
    dynamic json, {
    String? day,
  }) {
    final what = day == null ? 'the workload' : 'the workload of $day';
    if (json is! List) {
      throw SmartschoolPlannerError(
        'The planner gave $what as ${json.runtimeType} instead of a list.',
      );
    }
    return List.unmodifiable([
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          PlannerGroupWorkload.fromJson(item)
        else
          throw SmartschoolPlannerError(
            'The planner gave group $index of $what as ${item.runtimeType} '
            'instead of an object.',
          ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// The base path of the lesson-content JSON API, which holds the school's
  /// assignment types ([getAssignmentTypes]).
  static const _lessonContentPath = '/lesson-content/api/v1';

  static final _userId = RegExp(r'^\d+_\d+_\d+$');

  static final _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// The local date at midnight that [text] (`2026-10-05`) names, or `null`
  /// when it names none.
  static DateTime? _parseDay(String text) {
    final match = _day.firstMatch(text);
    if (match == null) return null;
    final [year, month, day] = [
      for (var i = 1; i <= 3; i++) int.parse(match[i]!),
    ];
    final date = DateTime(year, month, day);
    return date.month == month && date.day == day ? date : null;
  }

  /// The distinct IDs of [groupIds], in order, each checked to be a group
  /// calendar ID `{platformId}_{groupId}`.
  static List<String> _checkedGroupIds(Iterable<String> groupIds) {
    final groups = <String>[];
    for (final id in groupIds) {
      try {
        PlannerCalendar.group(id);
      } on ArgumentError {
        throw ArgumentError.value(
          groupIds,
          'groupIds',
          'holds "$id", which is not a planner group ID {platformId}_{groupId} '
              '(such as 4069_2001)',
        );
      }
      if (!groups.contains(id)) groups.add(id);
    }
    if (groups.isEmpty) {
      throw ArgumentError.value(groupIds, 'groupIds', 'is empty');
    }
    return groups;
  }

  static void _checkPeriod(DateTime from, DateTime to) {
    if (to.isBefore(from)) {
      throw ArgumentError.value(to, 'to', 'is before from ($from)');
    }
  }

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
