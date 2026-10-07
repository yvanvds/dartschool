import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/planner_models.dart';
import '../session.dart';
import 'lesson_content_service.dart';

export '../models/planner_models.dart';

/// Reads Smartschool's **planner** (Planner): the elements planned in a
/// calendar in a period (lessons, assignments, timetable slots, ...) and the
/// full detail of one element. A calendar is the planner of a user (the
/// account itself, or another teacher), of a class or of a location, as
/// `/planner/main/user/...`, `/planner/main/group/...` and
/// `/planner/main/location/...` show it; [searchCalendars] finds one by
/// name, and [getCalendar] names one by its ID, or tells that the planner
/// does not know it.
///
/// In the authenticated user's own planner, it fills a lesson hour with a
/// new lesson ([planLesson]) or with a lesfiche of the Lesfiches library
/// ([planLessonContent], the lesfiches read with `LessonContentService`) and
/// clears the hour again ([clearLesson]); it adds an assignment (a test, a
/// task) for classes ([planAssignment]) and moves it to the planner's trash
/// again ([trashAssignment]); and it changes the name and info of an own
/// lesson or assignment ([renameElement], [changePublicInfo],
/// [changePrivateInfo]). See *Writes* below.
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
/// // A calendar named by its ID; null when the planner does not know it.
/// final named = await planner.getCalendar(PlannerCalendar.group('4069_2001'));
/// print(named?.name ?? 'no such planner'); // 6A1
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
/// for (final file in detail.attachments ?? const <PlannerAttachment>[]) {
///   print('${file.name} (${file.size} bytes)');
/// }
/// for (final link in detail.weblinks ?? const <PlannerWeblink>[]) {
///   print('${link.name}: ${link.url}');
/// }
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
/// The reads go through the planner's JSON API (`/planner/api/v1/`; the
/// assignment types through the lesson-content API,
/// `/lesson-content/api/v1/`): GET requests, and POSTs that only read: the
/// search of [searchCalendars], the lookup of [getCalendar] and the
/// workload calls of [getAssignmentsOfGroups], [getWorkloadSchedule] and
/// [calculateWorkload].
///
/// ### Writes
/// Only [planLesson], [planLessonContent], [clearLesson], [planAssignment],
/// [trashAssignment], [renameElement], [changePublicInfo] and
/// [changePrivateInfo] change the planner, each with one POST for one
/// element:
///
/// ```dart
/// final me = await planner.ownCalendar();
/// final slot = (await planner.getPlannedElements(
///   me,
///   from: DateTime(2026, 11, 20, 11, 10),
///   to: DateTime(2026, 11, 20, 12),
///   types: {PlannedElementType.placeholder},
/// )).single;
///
/// final lesson = await planner.planLesson(
///   placeholder: slot,
///   name: 'Lussen: for en while',
///   publicInfo: '<p>Breng je laptop mee.</p>',
/// );
/// await planner.renameElement(lesson, 'Lussen: for, while en break');
/// await planner.changePrivateInfo(lesson, '<p>Oefening 3 overslaan.</p>');
///
/// final emptyAgain = await planner.clearLesson(lesson); // a new slot ID
///
/// // A lesfiche of the Lesfiches library into the same hour.
/// final fiche = (await LessonContentService(client).getItems())
///     .firstWhere((item) => item.type == LessonContentType.lesson);
/// final planned = await planner.planLessonContent(
///   placeholder: emptyAgain,
///   lessonContentId: fiche.id,
/// ); // named after the lesfiche
///
/// // A test for the classes of that hour, due at its start.
/// final ko = (await planner.getAssignmentTypes())
///     .firstWhere((type) => type.abbreviation == 'KO');
/// final test = await planner.planAssignment(
///   groupIds: [for (final group in slot.participantGroups) group.id],
///   course: slot.courses.first,
///   type: ko,
///   name: 'Test: lussen',
///   due: slot.period.from,
///   until: slot.period.to,
///   publicInfo: '<p>Leerstof: hoofdstuk 3.</p>',
/// );
/// await planner.renameElement(test, 'Test: lussen en functies');
/// await planner.trashAssignment(test); // to the planner's trash
/// ```
///
/// Each write that changes an element reads it again first and refuses,
/// with a [SmartschoolPlannerWriteRefusedError] and without sending
/// anything, an element that is not organised by the authenticated user or
/// whose capabilities do not allow the change: a class calendar also shows
/// the elements of colleagues, which the service never changes. A new
/// assignment is organised by the authenticated user, of one of the school's
/// assignment types. The fill of a slot, the clear of a lesson, the create
/// of an assignment and its move to the trash are sent once, never again
/// after logging in again; the edits, which set a value, are retried once
/// after logging in again, as a read is. A write that went out without the
/// planner's answer confirming it throws a
/// [SmartschoolPlannerSaveUnconfirmedError]. Of the planner's trash the
/// service only uses the move of one own assignment ([trashAssignment]); it
/// never uses its permanent delete
/// (`DELETE {plannedElementType}/{platformId}/{id}`), its restore, or its
/// bulk endpoints (`planned-elements/trash`, `planned-elements/delete`,
/// `planned-elements/bulk/...`, `planned-elements/replace-with-...`, and
/// `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, which
/// moves everything in a period to the trash), nor an assignment's
/// `announce`.
///
/// [PlannedElementDetail.privateInfo] is not private to the teacher: other
/// teachers who can read the element see it too (see below). Pupils see the
/// name and [PlannedElementDetail.publicInfo] of a lesson as soon as it is
/// planned, and of an assignment as soon as it is created.
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
///   does not help. From a write, it (and each subtype) means nothing was
///   sent.
/// - [SmartschoolPlannedElementNotFoundError] (a [SmartschoolPlannerError]):
///   [getPlannedElement] or [getDetail] asked for an element the planner
///   does not have (`404`); so did a write, for the element it reads again
///   first (such as a slot that was filled since it was read).
/// - [SmartschoolPlannerWriteRefusedError] (a [SmartschoolPlannerError]): a
///   check before a write refused it. Nothing was sent. Its
///   [SmartschoolPlannerWriteRefusedError.reason] says which check (a
///   [PlannerWriteRefusalReason], such as
///   [PlannerWriteRefusalReason.notOwn]), and its
///   [SmartschoolPlannerWriteRefusedError.element] is the element as read
///   again, so an app can say why in its own words.
/// - [SmartschoolLessonContentError]: [planLessonContent] could not read the
///   lesfiches before it planned one. Nothing was sent.
/// - [SmartschoolPlannerSaveUnconfirmedError]: a write went out, but the
///   planner's answer does not confirm it. It may or may not have been
///   made: read the element again (for a new assignment, the calendar of
///   one of its classes).
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; for the fill of a slot, the clear of a lesson, and the create and
///   trash of an assignment, which are not retried, at once. The request was
///   not carried out: call the method again, the client logs in before its
///   next request (#134).
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
  /// The reads send GET requests, and POSTs that only read:
  /// `quick-search/planner/search` and `quick-search/planner/start`
  /// ([getCalendar], #127), and `workload/planned-elements`,
  /// `workload/schedule` and `workload/calculate` (checked in the web
  /// client's code: it reads with them, it sends `start` each time its
  /// search field opens, and `calculate` is the check it runs before it
  /// saves an assignment). The writes send, for one element each,
  /// `planned-placeholders/{platformId}/{id}/replace/planned-lessons/blanco`
  /// ([planLesson]), `.../replace/planned-lessons` ([planLessonContent]),
  /// `planned-elements/clear` ([clearLesson]),
  /// `planned-assignments/blanco?waitForRefresh=true` ([planAssignment]),
  /// `planned-assignments/{platformId}/{id}/trash` ([trashAssignment]), and
  /// `{plannedElementType}/{platformId}/{id}/rename`,
  /// `.../change-public-info` and `.../change-private-info` (the edits). The
  /// planner also answers POSTs on it that change the planner or the user's
  /// settings and that the service never sends: the favourites of the search
  /// (`quick-search/planner/mark-as-favourite` and `discard-as-favourite`),
  /// the restore from the trash (`.../trash/restore`), an assignment's
  /// `announce` and `remove-announcement`, the bulk endpoints
  /// (`planned-elements/trash`, `planned-elements/delete`,
  /// `planned-elements/bulk/...`, `planned-elements/replace-with-...`), and
  /// `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, which
  /// moves everything in a period to the trash; nor its `DELETE` of an
  /// element, which deletes it for good.
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

  /// Names [calendar] by its ID (#127): the user, class or location whose
  /// planner it is, as the planner's search names it, with its
  /// [PlannerSearchResult.name], [PlannerSearchResult.title] and
  /// [PlannerSearchResult.description] (a class's full name), and whether a
  /// user was deleted ([PlannerSearchResult.isDeleted]); its
  /// [PlannerSearchResult.calendar] is [calendar]. Returns `null` when the
  /// planner does not know the ID.
  ///
  /// This tells a calendar ID that names no planner from a planner with
  /// nothing planned, which [getPlannedElements] does not: it answers a
  /// location ID the planner does not have with an empty list, as a room
  /// with nothing planned, and a user or class ID it does not have with HTTP
  /// `500`, an error that does not say why (seen live, 2026-10-05).
  ///
  /// `null` means that the planner does not offer the calendar (seen live,
  /// 2026-10-05, with an account that may see other planners): no such
  /// user, class or location (a made-up ID, a co-account number the user
  /// does not have, an ID of another platform), and also a group that the
  /// planner's search does not find by name either, such as the groups with
  /// the icon `star_green` seen live. The planner's page still names the
  /// planner of such a group (`/planner/main/group/{id}`), and
  /// [getPlannedElements] answered the one tried with an empty list.
  /// Whether the planner names other users' calendars for an account that
  /// may not see other planners was not tried.
  ///
  /// A deleted user is named, with [PlannerSearchResult.isDeleted] set:
  /// unlike [searchCalendars], which leaves deleted users out. The own
  /// calendar ([ownCalendar]) is named after the authenticated user (from
  /// `authenticatedUser.name`, which the client read at login; when it has
  /// none yet, it reads it from a Smartschool page first): the planner names
  /// it `%quicksearch.me%` (`Mezelf` in the web client), which this replaces.
  ///
  /// Sends `POST quick-search/planner/start` with `{"users": [], "groups":
  /// [], "miniDbItems": []}` and the calendar ID in the list of its kind (a
  /// location in `miniDbItems`): the request with which the planner's web
  /// client opens its search field, whose answer names the calendars it is
  /// given (`selection`), next to the search's suggestions and the user's
  /// favourites, which are not returned. It only reads: the web client sends
  /// it each time the search field opens, and the favourites stayed as they
  /// were.
  ///
  /// Throws a [SmartschoolPlannerError] when the planner answers with
  /// another HTTP status (it answered a class ID whose part after the
  /// platform ID is not a number, `4069_abc`, with `500`), or names another
  /// calendar than [calendar]: it reads the parts of a user or class ID as
  /// numbers, and answered `4069_04256` as `4069_4256`.
  Future<PlannerSearchResult?> getCalendar(PlannerCalendar calendar) async {
    final id = calendar.id;
    final response = await _client.postJsonResponse(
      '$_apiPath/quick-search/planner/start',
      data: {
        'users': [if (calendar.type == PlannerCalendarType.user) id],
        'groups': [if (calendar.type == PlannerCalendarType.group) id],
        'miniDbItems': [if (calendar.type == PlannerCalendarType.location) id],
      },
    );
    final what = 'the lookup of $calendar';
    final named = parseCalendarLookup(_decode(response, what));
    if (named.isEmpty) return null;
    final hit = named.where((hit) => hit.calendar == calendar).firstOrNull;
    if (hit == null) {
      throw SmartschoolPlannerError(
        'The planner answered $what with ${named.join(', ')}, not with that '
        'calendar.',
      );
    }
    return _namedAfterOwnUser(hit);
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
  /// The planner does not check that [calendar] names a planner (seen live,
  /// 2026-10-05, #127): it answers a location ID it does not have with an
  /// empty list, the same as a room with nothing planned, and a user or
  /// class ID it does not have with HTTP `500`, a [SmartschoolPlannerError]
  /// with that [SmartschoolPlannerError.statusCode] that does not say why.
  /// [getCalendar] tells a calendar the planner does not know apart, and
  /// names one with nothing planned.
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

  /// Returns the full detail of the element with ID [id] on platform
  /// [platformId], of [type] or of the type the planner calls [typeName]
  /// (the [PlannedElement.type] or [PlannedElement.typeName],
  /// [PlannedElement.platformId] and [PlannedElement.id] of a listed
  /// element; [getDetail] takes the element itself). Pass one of [type] and
  /// [typeName].
  ///
  /// [typeName] is the planner's name of the type (`planned-lessons`), as
  /// [PlannedElement.typeName] keeps it: it reads an element of any type,
  /// also one this library does not know ([PlannedElementType.other]), from
  /// the three parts a caller kept of it. A type name the planner does not
  /// have is answered with `404`, as an element it does not have.
  ///
  /// The detail holds what the list does not: the info texts, and the
  /// element's labels, attachments and weblinks
  /// ([PlannedElementDetail.labels], [PlannedElementDetail.attachments],
  /// [PlannedElementDetail.weblinks]; the files themselves are not
  /// downloaded). The detail is up to date at once after a change, unlike
  /// the list.
  ///
  /// Throws a [SmartschoolPlannedElementNotFoundError] when the planner has
  /// no such element (`404`), and an [ArgumentError], without sending
  /// anything, when neither or both of [type] and [typeName] are given, for
  /// [PlannedElementType.other] (which has no planner name: pass the
  /// element's [typeName] instead), for a [typeName] that is not of the form
  /// of the planner's type names (`planned-` and words of lowercase letters
  /// and digits joined by hyphens), or for an empty [id].
  Future<PlannedElementDetail> getPlannedElement({
    PlannedElementType? type,
    String? typeName,
    required int platformId,
    required String id,
  }) async {
    if (type == null && typeName == null) {
      throw ArgumentError.value(
        null,
        'type',
        'and typeName are both missing; pass one of them',
      );
    }
    if (type != null && typeName != null) {
      throw ArgumentError.value(
        typeName,
        'typeName',
        'is given together with type; pass one of them',
      );
    }
    if (type != null) {
      final wireName = type.wireName;
      if (wireName == null) {
        throw ArgumentError.value(
          type,
          'type',
          'has no planner name; pass the element\'s typeName instead',
        );
      }
      return _detail(wireName, platformId, id);
    }
    if (!_typeName.hasMatch(typeName!)) {
      throw ArgumentError.value(
        typeName,
        'typeName',
        'is not a planner element type such as planned-lessons',
      );
    }
    return _detail(typeName, platformId, id);
  }

  /// Returns the full detail of [element], an element of a calendar; see
  /// [getPlannedElement]. Works for an element of a type this library does
  /// not know too ([PlannedElementType.other]), as [getPlannedElement] with
  /// its [PlannedElement.typeName] does.
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

  // ---------------------------------------------------------------------------
  // Writes: a lesson in a lesson hour of the own planner
  // ---------------------------------------------------------------------------

  /// The icon [planLesson] gives a lesson when the caller names none
  /// (`document_observation`): the icon of the lessons seen live, which the
  /// fill was tried with.
  static const defaultLessonIcon = 'document_observation';

  /// Fills [placeholder], an empty lesson hour (a timetable slot,
  /// [PlannedElementType.placeholder]) of the authenticated user's own
  /// planner, with a new lesson ("lesfiche") named [name], as the planner's
  /// "plan a blank lesson" does. Returns the lesson: a new element of type
  /// [PlannedElementType.lesson], with its own ID, in the slot's period, with
  /// its classes, course and room.
  ///
  /// [publicInfo] is what pupils see, [privateInfo] what they do not (but
  /// colleagues who read the element do: it is not private to the teacher);
  /// both are HTML, `""` (the default) for none, and go out as given. [icon]
  /// is the lesson's icon ([defaultLessonIcon] by default). [name] goes out
  /// without the white space around it. Pupils of the classes see the name
  /// and [publicInfo] as soon as the lesson is planned.
  ///
  /// Before it sends anything, it reads the slot again (its detail, which is
  /// up to date at once, unlike the list) and refuses with a
  /// [SmartschoolPlannerWriteRefusedError]:
  /// - a slot that is not organised by the authenticated user (a class
  ///   calendar also shows colleagues' slots);
  /// - a slot whose capabilities do not allow filling it (`canUserReplace`);
  /// - a slot whose period is no longer the one of [placeholder];
  /// - a slot with participant roles or group filters, which the timetable
  ///   slots seen live never had, and which the service does not know how to
  ///   send on.
  ///
  /// A slot that was filled (or cleared) since [placeholder] was read is gone
  /// under its ID, and reading it again throws a
  /// [SmartschoolPlannedElementNotFoundError]: read the calendar again.
  ///
  /// The lesson gets the slot's organisers, classes, course, period and rooms
  /// as reading the slot again gave them, not as [placeholder] holds them:
  /// `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons/blanco`
  /// with the body the web client sends (tried live, 2026-10-02). The fill is
  /// sent **once**, never again after logging in again: a second one could
  /// plan a second lesson. When the planner's answer is not a lesson with
  /// [name] in the slot's period (or no usable answer comes in), this throws
  /// a [SmartschoolPlannerSaveUnconfirmedError]: read the slot again
  /// ([getDetail] of [placeholder] answers `404` once it was filled) before
  /// trying again. Calling this again is safe in itself: once the fill went
  /// through, reading the slot again fails.
  ///
  /// Throws an [ArgumentError], without sending anything, when [placeholder]
  /// is not a timetable slot, or [name] or [icon] is empty.
  Future<PlannedElementDetail> planLesson({
    required PlannedElement placeholder,
    required String name,
    String publicInfo = '',
    String privateInfo = '',
    String icon = defaultLessonIcon,
  }) async {
    final title = name.trim();
    if (title.isEmpty) {
      throw ArgumentError.value(name, 'name', 'is empty');
    }
    if (icon.trim().isEmpty) {
      throw ArgumentError.value(icon, 'icon', 'is empty');
    }
    return _fillSlot(
      'planLesson',
      placeholder,
      route: 'planned-lessons/blanco',
      content: {
        'name': title,
        'info': '',
        'publicInfo': publicInfo,
        'privateInfo': privateInfo,
        'icon': icon,
      },
      name: title,
    );
  }

  /// Fills [placeholder], an empty lesson hour (a timetable slot,
  /// [PlannedElementType.placeholder]) of the authenticated user's own
  /// planner, with the lesfiche [lessonContentId] of the Lesfiches library
  /// (a [LessonContentItem.id] of `LessonContentService.getItems`), as the
  /// planner's "plan a lesfiche" does. Returns the lesson: a new element of
  /// type [PlannedElementType.lesson], with its own ID, in the slot's period,
  /// with its classes, course and room, **named after the lesfiche** by the
  /// planner. Pupils of the classes see the lesson as soon as it is planned.
  ///
  /// The planner makes the lesson from the lesfiche: in the try live
  /// (2026-10-02) it took the lesfiche's name, labels and goals, and the
  /// lesfiche's (empty) info. Whether it copies the attachments, weblinks and
  /// info of a richer lesfiche, and whether later changes to the lesfiche
  /// reach a lesson planned from it, was not checked. The answer has no
  /// field that points back to the lesfiche. Planning does not change the
  /// lesfiche (the whole list was the same afterwards), and a hidden
  /// lesfiche ([LessonContentItem.isVisible] `false`) was planned like any
  /// other.
  ///
  /// Before it sends anything, it reads the lesfiches again
  /// (`LessonContentService.getItems`, without the course names: one
  /// request) and refuses with a
  /// [SmartschoolPlannerWriteRefusedError] a [lessonContentId] that is not
  /// among them, or that is not a lesson lesfiche
  /// ([LessonContentType.lesson]): an assignment lesfiche is planned as
  /// another element type (an assignment), which this method does not do
  /// ([planAssignment] adds a new assignment, not one from a lesfiche). It
  /// then reads the slot again
  /// and checks it as [planLesson] does (organised by the authenticated user,
  /// `canUserReplace`, the same period, no participant roles or group
  /// filters); a slot that is gone throws a
  /// [SmartschoolPlannedElementNotFoundError]. When the lesfiches cannot be
  /// read, the [SmartschoolLessonContentError] of
  /// `LessonContentService.getItems` is thrown: nothing was sent.
  ///
  /// Sends `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons`
  /// (the route of [planLesson] without `/blanco`) with the slot's organisers,
  /// classes, course, period and rooms as reading the slot again gave them,
  /// the lesfiche's ID as `sourceId` and its icon ([defaultLessonIcon] when
  /// it has none), and no name or info (tried live, 2026-10-02). The fill is
  /// sent **once**, never again after logging in again. When the planner's
  /// answer is not a lesson named as the lesfiche in the slot's period (or no
  /// usable answer comes in), this throws a
  /// [SmartschoolPlannerSaveUnconfirmedError]: read the slot again
  /// ([getDetail] of [placeholder] answers `404` once it was filled) before
  /// trying again. The lesson is cleared again with [clearLesson].
  ///
  /// Throws an [ArgumentError], without sending anything, when [placeholder]
  /// is not a timetable slot, or [lessonContentId] is empty.
  Future<PlannedElementDetail> planLessonContent({
    required PlannedElement placeholder,
    required String lessonContentId,
  }) async {
    const operation = 'planLessonContent';
    _checkSlot(placeholder);
    final sourceId = lessonContentId.trim();
    if (sourceId.isEmpty) {
      throw ArgumentError.value(lessonContentId, 'lessonContentId', 'is empty');
    }
    // The lesfiche's ID and kind are all it needs: no course names, so no
    // read of the course list (#101).
    final fiches = await LessonContentService(
      _client,
    ).getItems(withCourseNames: false);
    final fiche = fiches
        .where((item) => item.id.toLowerCase() == sourceId.toLowerCase())
        .firstOrNull;
    if (fiche == null) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: there is no lesfiche $sourceId among your '
        '${fiches.length} lesfiches (LessonContentService.getItems). Nothing '
        'was sent.',
        reason: PlannerWriteRefusalReason.unknownLessonContent,
      );
    }
    if (fiche.type != LessonContentType.lesson) {
      final kind = fiche.type == LessonContentType.assignment
          ? 'an assignment'
          : 'a "${fiche.typeName}"';
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: lesfiche ${fiche.id} "${fiche.name}" is $kind lesfiche '
        '(${fiche.typeName}), not a lesson one (lessons): planning it would '
        'not make a lesson. Nothing was sent.',
        reason: PlannerWriteRefusalReason.notALessonLessonContent,
        lessonContent: fiche,
      );
    }
    final icon = fiche.icon?.trim() ?? '';
    return _fillSlot(
      operation,
      placeholder,
      route: 'planned-lessons',
      content: {
        'sourceId': fiche.id,
        'icon': icon.isEmpty ? defaultLessonIcon : icon,
      },
      name: fiche.name,
    );
  }

  /// Renames [element], an element of the authenticated user's own planner
  /// (a lesson or an assignment), to [newName], which goes out without the
  /// white space around it. Returns the element as the planner holds it
  /// after the change.
  ///
  /// Sends `POST {plannedElementType}/{platformId}/{id}/rename` with
  /// `{"newName": newName}` (tried live on a lesson and on an assignment,
  /// 2026-10-02). See [changePublicInfo] for the checks before it, and for
  /// what this throws.
  ///
  /// Throws an [ArgumentError], without sending anything, when [newName] is
  /// empty.
  Future<PlannedElementDetail> renameElement(
    PlannedElement element,
    String newName,
  ) {
    final name = newName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'is empty');
    }
    return _edit(
      'renameElement',
      element,
      action: 'rename',
      capability: 'canUserRename',
      field: 'name',
      body: {'newName': name},
      valueOf: (detail) => (detail.name ?? '').trim(),
      value: name,
    );
  }

  /// Sets the info that pupils see of [element], an element of the
  /// authenticated user's own planner (a lesson; an assignment the same
  /// way, at its own route), to [newInfo] (HTML, sent as given; `""` empties
  /// it). Returns the element as the planner holds it after the change.
  ///
  /// Before it sends anything, it reads the element again (its detail) and
  /// refuses with a [SmartschoolPlannerWriteRefusedError] an element that is
  /// not organised by the authenticated user (a class calendar also shows
  /// colleagues' elements), or whose capabilities do not allow the change
  /// (`canUserEdit` and `canUserChangePublicInfo`; for [renameElement]
  /// `canUserRename`, for [changePrivateInfo] `canUserChangePrivateInfo`).
  /// An element that is gone throws a
  /// [SmartschoolPlannedElementNotFoundError]. When the element already has
  /// that value, it sends nothing and returns the element as read.
  ///
  /// Sends `POST {plannedElementType}/{platformId}/{id}/change-public-info`
  /// with `{"newInfo": newInfo}` (tried live on a lesson, 2026-10-02: the
  /// planner kept the HTML as given). The change sets a value, so sending it
  /// again does not change the outcome: it is retried once after logging in
  /// again, as a read is. When the planner's answer is not the element with
  /// that value (or no usable answer comes in), this throws a
  /// [SmartschoolPlannerSaveUnconfirmedError]: read the element again before
  /// trying again.
  Future<PlannedElementDetail> changePublicInfo(
    PlannedElement element,
    String newInfo,
  ) => _edit(
    'changePublicInfo',
    element,
    action: 'change-public-info',
    capability: 'canUserChangePublicInfo',
    field: 'publicInfo',
    body: {'newInfo': newInfo},
    valueOf: (detail) => detail.publicInfo,
    value: newInfo,
  );

  /// Sets the info that pupils do not see of [element], an element of the
  /// authenticated user's own planner, to [newInfo] (HTML, sent as given;
  /// `""` empties it). Returns the element as the planner holds it after the
  /// change; its [PlannedElementDetail.info] follows (seen live).
  ///
  /// This info is **not private to the teacher**: colleagues who can read
  /// the element (in the calendar of one of its classes, for instance) see
  /// it too.
  ///
  /// Sends `POST {plannedElementType}/{platformId}/{id}/change-private-info`
  /// with `{"newInfo": newInfo}` (tried live on a lesson, 2026-10-02), after
  /// the checks of [changePublicInfo] with `canUserChangePrivateInfo`; it
  /// throws what [changePublicInfo] throws.
  Future<PlannedElementDetail> changePrivateInfo(
    PlannedElement element,
    String newInfo,
  ) => _edit(
    'changePrivateInfo',
    element,
    action: 'change-private-info',
    capability: 'canUserChangePrivateInfo',
    field: 'privateInfo',
    body: {'newInfo': newInfo},
    valueOf: (detail) => detail.privateInfo,
    value: newInfo,
  );

  /// Clears [lesson], a lesson in a lesson hour of the authenticated user's
  /// own planner: the hour is an empty timetable slot again, as the
  /// planner's "delete and keep the placeholder" does. Returns that slot
  /// ([PlannedElementType.placeholder]), with the same period, classes,
  /// course and room, but a **new ID**. The lesson, its name and its info
  /// are gone: the planner answers its detail with `404`.
  ///
  /// Before it sends anything, it reads the lesson again (its detail) and
  /// refuses with a [SmartschoolPlannerWriteRefusedError]:
  /// - a lesson that is not organised by the authenticated user (a class
  ///   calendar also shows colleagues' lessons);
  /// - a lesson whose capabilities do not allow editing it (`canUserEdit`, as
  ///   the web client requires for this action);
  /// - a lesson that the planner lets the user trash or delete
  ///   (`canUserTrash`, `canUserDelete`): the lessons in a timetable hour seen
  ///   live allowed neither, clearing being the planner's way to remove them.
  ///   The clear of a lesson outside the timetable was not tried, so the
  ///   service does not send it.
  ///
  /// A lesson that is gone throws a [SmartschoolPlannedElementNotFoundError].
  ///
  /// Sends `POST planned-elements/clear` with `{"type": "planned-lessons",
  /// "elementId": id, "elementPlatformId": platformId}` (tried live,
  /// 2026-10-02), **once**: never again after logging in again. When the
  /// planner's answer is not a timetable slot of the authenticated user in
  /// the lesson's period (or no usable answer comes in), this throws a
  /// [SmartschoolPlannerSaveUnconfirmedError]: read the lesson again
  /// ([getDetail] answers `404` once it was cleared) before trying again.
  ///
  /// After the clear, [getPlannedElements] may show the lesson for a few
  /// seconds more; the detail is up to date at once.
  ///
  /// Throws an [ArgumentError], without sending anything, when [lesson] is not
  /// a [PlannedElementType.lesson].
  Future<PlannedElementDetail> clearLesson(PlannedElement lesson) async {
    const operation = 'clearLesson';
    if (lesson.type != PlannedElementType.lesson) {
      throw ArgumentError.value(
        lesson,
        'lesson',
        'is a ${lesson.typeName}, not a lesson (planned-lessons)',
      );
    }
    final me = await _ownUserId();
    final current = await _detail(
      lesson.typeName,
      lesson.platformId,
      lesson.id,
    );
    final what = _describe(current);
    _refuseUnlessOwn(operation, current, me);
    _refuseUnlessCapable(operation, current, const ['canUserEdit']);
    final removable = [
      for (final flag in const ['canUserTrash', 'canUserDelete'])
        if (current.capabilities.can(flag)) flag,
    ];
    if (removable.isNotEmpty) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: the planner lets you trash or delete $what '
        '(${removable.first}), so it is not a lesson in a timetable hour as '
        'the service knows them, which only clearing removes. Nothing was '
        'sent.',
        reason: PlannerWriteRefusalReason.trashable,
        element: current,
        capabilityFlags: List.unmodifiable(removable),
      );
    }
    return _write(
      operation,
      path: '$_apiPath/planned-elements/clear',
      body: {
        'type': current.typeName,
        'elementId': current.id,
        'elementPlatformId': current.platformId,
      },
      change: 'the clear of $what',
      retryAfterLogin: false,
      unconfirmed:
          'It may or may not have been cleared: read the lesson again '
          '(getDetail; the planner answers 404 once it was cleared) before '
          'trying again.',
      problemOf: (answer) {
        if (answer.type != PlannedElementType.placeholder) {
          return 'a ${answer.typeName} instead of a timetable slot';
        }
        if (!_samePeriod(answer.period, current.period)) {
          return 'a slot in another period (${answer.period.from} - '
              '${answer.period.to})';
        }
        if (!_organisedBy(answer, me)) {
          return 'a slot that is not organised by $me';
        }
        return null;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Writes: an assignment in the own planner
  // ---------------------------------------------------------------------------

  /// The icon [planAssignment] gives an assignment when the caller names
  /// none (`flags_red_yellow`): the icon of the assignments seen live, which
  /// the create was tried with. The planner requires an icon for an
  /// assignment (it answers the create without one with `400`).
  static const defaultAssignmentIcon = 'flags_red_yellow';

  /// Adds an assignment ("opdracht": a test, a task, something to bring
  /// along) to the authenticated user's own planner, for the classes
  /// [groupIds], as the planner's "new assignment" does. Returns the
  /// assignment: a new element of type [PlannedElementType.assignment],
  /// organised by the authenticated user, of [type], due at [due].
  ///
  /// **Pupils of the classes see the assignment at once**: the planner makes
  /// it visible from the moment it is created (its
  /// [PlannedElementDetail.visibleFrom]), with its name and [publicInfo].
  /// It is not announced
  /// ([PlannedElementDetail.isAnnounced] `false`); the planner's "announce"
  /// is not used.
  ///
  /// An assignment is not tied to a lesson hour: it is a deadline. [due] is
  /// the moment it is due (usually the start of a lesson hour, the
  /// [PlannerPeriod.from] of a timetable slot), [until] the end of its
  /// period (the end of that hour); both go out as [formatDateTime] writes
  /// them. In the class calendar it shows next to the timetable slot of that
  /// hour, which stays as it is.
  ///
  /// - [groupIds] are class IDs `{platformId}_{groupId}` (a class calendar's
  ///   [PlannerCalendar.id], a [PlannerGroup.id] of a slot), each sent once;
  /// - [course] is the course the assignment is about, such as one of the
  ///   [PlannedElement.courses] of a timetable slot;
  /// - [type] is one of the school's assignment types ([getAssignmentTypes]);
  /// - [name] goes out without the white space around it;
  /// - [publicInfo] is what pupils see, [privateInfo] what they do not (but
  ///   colleagues who read the assignment do: it is not private to the
  ///   teacher); both are HTML, `""` (the default) for none, and go out as
  ///   given;
  /// - [icon] is the assignment's icon ([defaultAssignmentIcon] by default);
  /// - [locations] are its rooms (none by default), such as the
  ///   [PlannedElement.locations] of a timetable slot.
  ///
  /// Before it sends anything, it reads the school's assignment types again
  /// ([getAssignmentTypes]) and refuses with a
  /// [SmartschoolPlannerWriteRefusedError] a [type] whose ID is not among
  /// them; the error carries the types it read as its
  /// [SmartschoolPlannerWriteRefusedError.assignmentTypes] (#119). When the
  /// types cannot be read, the [SmartschoolPlannerError] of
  /// [getAssignmentTypes] is thrown: nothing was sent either.
  ///
  /// Sends `POST planned-assignments/blanco?waitForRefresh=true` with the
  /// body the web client sends (tried live, 2026-10-02: the planner answered
  /// `201` with the assignment, and the class calendar showed it at once):
  /// the authenticated user as the only organiser, the classes as
  /// participants, the course, the period with `deadline` `true` and
  /// `dateTime` set to [due], the name, an empty `info`, the info texts, the
  /// type's ID as `assignmentType`, the icon and the locations. The create
  /// is sent **once**, never again after logging in again: a second one
  /// would add a second assignment. When the planner's answer is not an
  /// assignment of the authenticated user with [name] and [type], due at
  /// [due] (or no usable answer comes in), this throws a
  /// [SmartschoolPlannerSaveUnconfirmedError]: look for the assignment in
  /// the calendar of one of its classes ([getPlannedElements] with
  /// [PlannedElementType.assignment], or [getAssignmentsOfGroups]) before
  /// trying again; **calling this again adds another assignment** when the
  /// first one was made.
  ///
  /// The assignment is changed with [renameElement], [changePublicInfo] and
  /// [changePrivateInfo], and moved to the planner's trash with
  /// [trashAssignment]. Rescheduling it, changing its type, classes or
  /// visibility, announcing it, hand-in folders, a linked Skore evaluation,
  /// attachments and the planning of an assignment lesfiche are not
  /// covered.
  ///
  /// Throws an [ArgumentError], without sending anything, when [groupIds] is
  /// empty or holds an ID that is not a group ID, [name] or [icon] is empty,
  /// [course] or [type] has an empty ID, or [until] is before [due].
  Future<PlannedElementDetail> planAssignment({
    required Iterable<String> groupIds,
    required PlannerCourse course,
    required PlannerAssignmentType type,
    required String name,
    required DateTime due,
    required DateTime until,
    String publicInfo = '',
    String privateInfo = '',
    String icon = defaultAssignmentIcon,
    Iterable<PlannerLocation> locations = const [],
  }) async {
    const operation = 'planAssignment';
    final groups = _checkedGroupIds(groupIds);
    final title = name.trim();
    if (title.isEmpty) {
      throw ArgumentError.value(name, 'name', 'is empty');
    }
    if (icon.trim().isEmpty) {
      throw ArgumentError.value(icon, 'icon', 'is empty');
    }
    if (course.id.trim().isEmpty) {
      throw ArgumentError.value(course, 'course', 'has an empty ID');
    }
    if (type.id.trim().isEmpty) {
      throw ArgumentError.value(type, 'type', 'has an empty ID');
    }
    if (until.isBefore(due)) {
      throw ArgumentError.value(until, 'until', 'is before due ($due)');
    }
    final me = await _ownUserId();
    final types = await getAssignmentTypes();
    final known = types
        .where((known) => known.id.toLowerCase() == type.id.toLowerCase())
        .firstOrNull;
    if (known == null) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: assignment type ${type.id} "${type.name}" is not one of '
        'the school\'s ${types.length} assignment types '
        '(getAssignmentTypes). Nothing was sent.',
        reason: PlannerWriteRefusalReason.unknownAssignmentType,
        assignmentTypes: List.unmodifiable(types),
      );
    }
    final dueAt = formatDateTime(due);
    final what =
        'assignment "$title" (${known.name}) for ${groups.join(', ')}, due '
        '$dueAt';
    return _write(
      operation,
      path: '$_apiPath/planned-assignments/blanco',
      query: const {'waitForRefresh': 'true'},
      ok: const {200, 201},
      body: {
        'organisers': {
          'users': [me],
          'groups': const <Object>[],
        },
        'participants': {
          'groups': groups,
          'users': const <Object>[],
          'userRoles': const <Object>[],
        },
        'courses': [
          {'platformId': course.platformId, 'id': course.id},
        ],
        'period': {
          'dateTimeFrom': dueAt,
          'dateTimeTo': formatDateTime(until),
          'wholeDay': false,
          'deadline': true,
          'dateTime': dueAt,
        },
        'name': title,
        'info': '',
        'publicInfo': publicInfo,
        'privateInfo': privateInfo,
        'assignmentType': known.id,
        'icon': icon,
        'locations': [
          for (final location in locations) _locationBody(location),
        ],
      },
      change: 'the creation of $what',
      retryAfterLogin: false,
      unconfirmed:
          'It may or may not have been made: look for it in the calendar of '
          'one of its classes (getPlannedElements with '
          'PlannedElementType.assignment) before trying again; trying again '
          'adds another assignment if it was made.',
      problemOf: (answer) {
        if (answer.type != PlannedElementType.assignment) {
          return 'a ${answer.typeName} instead of an assignment';
        }
        if ((answer.name ?? '').trim() != title) {
          return 'an assignment named "${answer.name ?? ''}" instead of '
              '"$title"';
        }
        final answerType = answer.assignmentType;
        if (answerType == null ||
            answerType.id.toLowerCase() != known.id.toLowerCase()) {
          return 'an assignment of type ${answerType?.id} '
              '"${answerType?.name ?? ''}" instead of ${known.id}';
        }
        if (!answer.period.deadline) {
          return 'an assignment that is not a deadline';
        }
        if (!answer.period.from.isAtSameMomentAs(due)) {
          return 'an assignment due at ${answer.period.from}';
        }
        if (!_organisedBy(answer, me)) {
          return 'an assignment that is not organised by $me';
        }
        return null;
      },
    );
  }

  /// Moves [assignment], an assignment of the authenticated user's own
  /// planner, to the planner's trash, as the planner's "delete" of one
  /// assignment does. Afterwards the planner answers its detail with `404`
  /// and the class calendars no longer show it; pupils no longer see it.
  ///
  /// The planner keeps what is in its trash for 30 days (as its page
  /// configuration says, `daysTrashedSaved`), and its web client can restore
  /// it from there (`.../trash/restore`); the service does neither read nor
  /// restore the trash (the restore was not tried), nor empty it.
  ///
  /// Before it sends anything, it reads the assignment again (its detail)
  /// and refuses with a [SmartschoolPlannerWriteRefusedError]:
  /// - an assignment that is not organised by the authenticated user (a
  ///   class calendar also shows colleagues' assignments);
  /// - an assignment the planner does not let the user trash
  ///   (`canUserTrash`, which the web client's delete requires);
  /// - an assignment with a linked Skore evaluation
  ///   ([PlannedElementDetail.hasLinkedEvaluation]): the trash of one was not
  ///   tried.
  ///
  /// An assignment that is gone (also one that was trashed already) throws a
  /// [SmartschoolPlannedElementNotFoundError].
  ///
  /// Sends `POST planned-assignments/{platformId}/{id}/trash` without a body
  /// (tried live, 2026-10-02: the planner answered `200` with `[]`),
  /// **once**: never again after logging in again. It then reads the
  /// assignment's detail again, which is up to date at once, and returns
  /// when the planner answers it with `404`. When the planner's answer to
  /// the trash is not a list with status `200`, the detail is still there,
  /// or it cannot be read, this throws a
  /// [SmartschoolPlannerSaveUnconfirmedError]: read the assignment again
  /// ([getDetail]; `404` once it was trashed) before trying again.
  ///
  /// The service never sends the planner's `DELETE` of an element (which
  /// deletes it for good, without the trash) or its trash of several
  /// elements or of a whole period.
  ///
  /// Throws an [ArgumentError], without sending anything, when [assignment]
  /// is not a [PlannedElementType.assignment].
  Future<void> trashAssignment(PlannedElement assignment) async {
    const operation = 'trashAssignment';
    if (assignment.type != PlannedElementType.assignment) {
      throw ArgumentError.value(
        assignment,
        'assignment',
        'is a ${assignment.typeName}, not an assignment (planned-assignments)',
      );
    }
    final me = await _ownUserId();
    final current = await _detail(
      assignment.typeName,
      assignment.platformId,
      assignment.id,
    );
    final what = _describe(current);
    _refuseUnlessOwn(operation, current, me);
    _refuseUnlessCapable(operation, current, const ['canUserTrash']);
    if (current.hasLinkedEvaluation ?? false) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: $what has a linked Skore evaluation '
        '(hasLinkedEvaluation); the trash of such an assignment was not '
        'tried, so the service does not send it. Nothing was sent.',
        reason: PlannerWriteRefusalReason.linkedEvaluation,
        element: current,
      );
    }

    final change = 'the move of $what to the trash';
    const unconfirmed =
        'It may or may not be in the trash: read the assignment again '
        '(getDetail; the planner answers 404 once it was trashed) before '
        'trying again.';
    final response = await _send(
      operation,
      path:
          '$_apiPath/${Uri.encodeComponent(current.typeName)}/'
          '${current.platformId}/${Uri.encodeComponent(current.id)}/trash',
      body: null,
      change: change,
      retryAfterLogin: false,
      unconfirmed: unconfirmed,
    );
    final Object? answer;
    try {
      answer = _decode(response, change);
    } on SmartschoolPlannerError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolPlannerSaveUnconfirmedError(
          '$operation: $change was sent, but the planner\'s answer cannot be '
          'used (${e.message}). $unconfirmed',
          statusCode: response.statusCode,
          cause: e,
        ),
        stackTrace,
      );
    }
    if (answer is! List) {
      throw SmartschoolPlannerSaveUnconfirmedError(
        '$operation: $change was sent, but the planner answered with '
        '${answer.runtimeType} instead of a list. $unconfirmed',
        statusCode: response.statusCode,
      );
    }

    // The trash answers with a list (empty in the try live); the detail
    // tells whether the assignment is gone.
    try {
      await _detail(current.typeName, current.platformId, current.id);
    } on SmartschoolPlannedElementNotFoundError {
      return;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolPlannerSaveUnconfirmedError(
          '$operation: $change was sent and answered, but reading the '
          'assignment again failed ($e). $unconfirmed',
          statusCode: response.statusCode,
          cause: e,
        ),
        stackTrace,
      );
    }
    throw SmartschoolPlannerSaveUnconfirmedError(
      '$operation: $change was sent and answered, but the planner still has '
      'the assignment. $unconfirmed',
      statusCode: response.statusCode,
    );
  }

  /// Fills slot [placeholder] through
  /// `planned-placeholders/{platformId}/{id}/replace/[route]` with the slot's
  /// organisers, participants, courses, period and locations (read again)
  /// and [content]; returns the new element once the answer confirms it: of
  /// type `planned-lessons`, named [name] when it is given, in the slot's
  /// period. Sent once, never retried.
  ///
  /// [route] and [content] are what the kind of fill adds: a blank lesson
  /// (`planned-lessons/blanco`, with the name, info and icon, [planLesson]),
  /// or a lesfiche (`planned-lessons`, with its `sourceId` and icon,
  /// [planLessonContent]; the planner names the lesson after the lesfiche).
  Future<PlannedElementDetail> _fillSlot(
    String operation,
    PlannedElement placeholder, {
    required String route,
    required Map<String, Object?> content,
    String? name,
  }) async {
    _checkSlot(placeholder);
    final me = await _ownUserId();
    final slot = await _detail(
      placeholder.typeName,
      placeholder.platformId,
      placeholder.id,
    );
    final what = _describe(slot);
    if (slot.type != PlannedElementType.placeholder) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: ${slot.id} is a ${slot.typeName} now, not a timetable '
        'slot. Nothing was sent.',
        reason: PlannerWriteRefusalReason.noLongerASlot,
        element: slot,
      );
    }
    if (!_samePeriod(slot.period, placeholder.period)) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: $what is no longer in the period it was read with '
        '(${placeholder.period.from} - ${placeholder.period.to}): read the '
        'calendar again. Nothing was sent.',
        reason: PlannerWriteRefusalReason.periodChanged,
        element: slot,
      );
    }
    _refuseUnlessOwn(operation, slot, me);
    _refuseUnlessCapable(operation, slot, const ['canUserReplace']);
    final participants = slot.raw['participants'];
    final roles = participants is Map ? participants['userRoles'] : null;
    final filters = participants is Map ? participants['groupFilters'] : null;
    if (_isFilled(roles) ||
        filters is Map &&
            (_isFilled(filters['filters']) ||
                _isFilled(filters['additionalUsers']))) {
      throw SmartschoolPlannerWriteRefusedError(
        '$operation: $what has participant roles or group filters, which '
        'the service does not know how to send on. Nothing was sent.',
        reason: PlannerWriteRefusalReason.participantRoles,
        element: slot,
      );
    }

    return _write(
      operation,
      path:
          '$_apiPath/planned-placeholders/${slot.platformId}/'
          '${Uri.encodeComponent(slot.id)}/replace/$route',
      body: {..._slotBody(slot), ...content},
      change: 'the fill of $what',
      retryAfterLogin: false,
      unconfirmed:
          'It may or may not have been filled: read the slot again '
          '(getDetail; the planner answers 404 once it was filled) before '
          'trying again.',
      problemOf: (answer) {
        if (answer.type != PlannedElementType.lesson) {
          return 'a ${answer.typeName} instead of a lesson';
        }
        if (name != null && (answer.name ?? '').trim() != name) {
          return 'a lesson named "${answer.name ?? ''}" instead of "$name"';
        }
        if (!_samePeriod(answer.period, slot.period)) {
          return 'a lesson in another period (${answer.period.from} - '
              '${answer.period.to})';
        }
        return null;
      },
    );
  }

  /// Changes [field] of [element] to [value] through
  /// `{plannedElementType}/{platformId}/{id}/[action]` with [body], after
  /// reading the element again and checking that it is the authenticated
  /// user's own and that its capabilities hold `canUserEdit` and
  /// [capability]. Sends nothing when [valueOf] the element read is [value]
  /// already. Retried once after logging in again: the change sets a value.
  Future<PlannedElementDetail> _edit(
    String operation,
    PlannedElement element, {
    required String action,
    required String capability,
    required String field,
    required Map<String, Object?> body,
    required String Function(PlannedElementDetail detail) valueOf,
    required String value,
  }) async {
    final me = await _ownUserId();
    final current = await _detail(
      element.typeName,
      element.platformId,
      element.id,
    );
    _refuseUnlessOwn(operation, current, me);
    _refuseUnlessCapable(operation, current, ['canUserEdit', capability]);
    if (valueOf(current) == value) return current;
    final what = _describe(current);
    return _write(
      operation,
      path:
          '$_apiPath/${Uri.encodeComponent(current.typeName)}/'
          '${current.platformId}/${Uri.encodeComponent(current.id)}/$action',
      body: body,
      change: 'the change of the $field of $what',
      retryAfterLogin: true,
      unconfirmed:
          'It may or may not have been changed: read the element again '
          '(getDetail) before trying again.',
      problemOf: (answer) {
        if (answer.id.toLowerCase() != current.id.toLowerCase()) {
          return 'element ${answer.id}';
        }
        if (valueOf(answer) != value) {
          return 'the $field "${_preview(valueOf(answer), max: 80)}"';
        }
        return null;
      },
    );
  }

  /// Sends the write [body] to [path] (with [query]) and returns the element
  /// of the planner's answer, which must have one of the HTTP statuses [ok],
  /// once [problemOf] finds nothing wrong with it.
  ///
  /// A session that Smartschool refuses (an
  /// [SmartschoolAuthenticationError]) is thrown as it is: the write was not
  /// carried out. Any other failure, an unusable answer or a [problemOf] is
  /// a [SmartschoolPlannerSaveUnconfirmedError] that ends in [unconfirmed].
  Future<PlannedElementDetail> _write(
    String operation, {
    required String path,
    required Map<String, Object?> body,
    required String change,
    required bool retryAfterLogin,
    required String unconfirmed,
    required String? Function(PlannedElementDetail answer) problemOf,
    Map<String, String>? query,
    Set<int> ok = const {200},
  }) async {
    final response = await _send(
      operation,
      path: path,
      body: body,
      query: query,
      change: change,
      retryAfterLogin: retryAfterLogin,
      unconfirmed: unconfirmed,
    );
    final PlannedElementDetail answer;
    try {
      answer = parsePlannedElementDetail(_decode(response, change, ok: ok));
    } on SmartschoolPlannerError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolPlannerSaveUnconfirmedError(
          '$operation: $change was sent, but the planner\'s answer cannot be '
          'used (${e.message}). $unconfirmed',
          statusCode: response.statusCode,
          cause: e,
        ),
        stackTrace,
      );
    }
    final problem = problemOf(answer);
    if (problem != null) {
      throw SmartschoolPlannerSaveUnconfirmedError(
        '$operation: $change was sent, but the planner answered with '
        '$problem. $unconfirmed',
        statusCode: response.statusCode,
      );
    }
    return answer;
  }

  /// Sends the write [body] (none when `null`) to [path] (with [query]) and
  /// returns the planner's answer, whatever its status.
  ///
  /// A session that Smartschool refuses (an
  /// [SmartschoolAuthenticationError]) is thrown as it is: the write was not
  /// carried out. Any other failure is a
  /// [SmartschoolPlannerSaveUnconfirmedError] that ends in [unconfirmed]:
  /// the write may have reached the planner.
  Future<Response<String>> _send(
    String operation, {
    required String path,
    required Map<String, Object?>? body,
    required String change,
    required bool retryAfterLogin,
    required String unconfirmed,
    Map<String, String>? query,
  }) async {
    try {
      return await _client.postJsonResponse(
        path,
        data: body,
        query: query,
        retryAfterLogin: retryAfterLogin,
      );
    } on SmartschoolAuthenticationError {
      // Refused before the planner handled it (and, for a write that is not
      // retried, not sent again): the planner was not changed.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolPlannerSaveUnconfirmedError(
          '$operation: $change was sent, but no answer came in ($e). '
          '$unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
  }

  /// Throws an [ArgumentError] unless [placeholder] is a timetable slot.
  static void _checkSlot(PlannedElement placeholder) {
    if (placeholder.type == PlannedElementType.placeholder) return;
    throw ArgumentError.value(
      placeholder,
      'placeholder',
      'is a ${placeholder.typeName}, not a timetable slot '
          '(planned-placeholders)',
    );
  }

  /// The whole user ID of the authenticated user (`4069_146_0`).
  Future<String> _ownUserId() async => (await ownCalendar()).id;

  /// Refuses [element] unless the authenticated user [me] is one of its
  /// organising users.
  static void _refuseUnlessOwn(
    String operation,
    PlannedElement element,
    String me,
  ) {
    if (_organisedBy(element, me)) return;
    final organisers = [
      for (final user in element.organiserUsers) '${user.name} (${user.id})',
    ];
    throw SmartschoolPlannerWriteRefusedError(
      '$operation: ${_describe(element)} is not in your own planner: it is '
      'organised by ${organisers.isEmpty ? 'no user' : organisers.join(', ')}'
      ', not by $me. Nothing was sent.',
      reason: PlannerWriteRefusalReason.notOwn,
      element: element,
    );
  }

  /// Refuses [element] unless its capabilities hold every flag of [flags].
  static void _refuseUnlessCapable(
    String operation,
    PlannedElement element,
    List<String> flags,
  ) {
    final missing = [
      for (final flag in flags)
        if (!element.capabilities.can(flag)) flag,
    ];
    if (missing.isEmpty) return;
    throw SmartschoolPlannerWriteRefusedError(
      '$operation: the planner does not let you change '
      '${_describe(element)} (${missing.join(', ')} not set). Nothing was '
      'sent.',
      reason: PlannerWriteRefusalReason.notAllowed,
      element: element,
      capabilityFlags: List.unmodifiable(missing),
    );
  }

  static bool _organisedBy(PlannedElement element, String userId) =>
      element.organiserUsers.any((user) => user.id == userId);

  static bool _samePeriod(PlannerPeriod a, PlannerPeriod b) =>
      a.from.isAtSameMomentAs(b.from) &&
      a.to.isAtSameMomentAs(b.to) &&
      a.wholeDay == b.wholeDay;

  /// Whether [value] is a list or a map with something in it.
  static bool _isFilled(Object? value) =>
      value is List && value.isNotEmpty || value is Map && value.isNotEmpty;

  /// [element] for a message: its type, ID, name and period.
  static String _describe(PlannedElement element) =>
      '${element.typeName} ${element.id}'
      '${element.name == null ? '' : ' "${element.name}"'} '
      '(${element.period.from} - ${element.period.to})';

  /// The part of the fill of a timetable slot that comes from [slot]: its
  /// organisers, participants, courses, period and locations, as the
  /// planner's web client sends them (IDs as strings, a course and a
  /// location as an object; `platformlName` is the web client's own
  /// spelling). The period goes out as the planner gave it.
  static Map<String, Object?> _slotBody(PlannedElementDetail slot) {
    final period = slot.raw['period'];
    String time(String key, DateTime parsed) {
      final value = period is Map ? period[key] : null;
      return value is String ? value : formatDateTime(parsed);
    }

    return {
      'organisers': {
        'users': [for (final user in slot.organiserUsers) user.id],
        'groups': [for (final group in slot.organiserGroups) group.id],
      },
      'participants': {
        'groups': [for (final group in slot.participantGroups) group.id],
        'users': [for (final user in slot.participantUsers) user.id],
        'userRoles': const <Object>[],
        'groupFilters': {
          'filters': const <Object>[],
          'additionalUsers': const <Object>[],
        },
      },
      'courses': [
        for (final course in slot.courses)
          {'platformId': course.platformId, 'id': course.id},
      ],
      'period': {
        'dateTimeFrom': time('dateTimeFrom', slot.period.from),
        'dateTimeTo': time('dateTimeTo', slot.period.to),
        'wholeDay': slot.period.wholeDay,
      },
      'locations': [
        for (final location in slot.locations) _locationBody(location),
      ],
    };
  }

  /// [location] as the planner's web client sends it in a write
  /// (`platformlName` is the web client's own spelling).
  static Map<String, Object?> _locationBody(PlannerLocation location) => {
    'id': location.id,
    'platformId': location.platformId,
    'platformlName': location.platformName,
    'type': location.type,
  };

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

  /// The name the planner gives the authenticated user in the answer to
  /// [getCalendar] (`origin.name`, `origin.nameReverse` and the `title`):
  /// a key of the web client's texts, which it shows as `Mezelf` (seen
  /// live, 2026-10-05). The search names the user by name.
  static const _ownUserPlaceholder = '%quicksearch.me%';

  /// [hit], or, when the planner named the authenticated user with
  /// [_ownUserPlaceholder], [hit] with the user's name from
  /// `authenticatedUser.name` (first name first, and last name first as the
  /// title). Reads the authenticated user only then.
  Future<PlannerSearchResult> _namedAfterOwnUser(
    PlannerSearchResult hit,
  ) async {
    if (hit.kind != PlannerSearchResultKind.user ||
        (hit.name != _ownUserPlaceholder && hit.title != _ownUserPlaceholder)) {
      return hit;
    }
    final user = await _client.authenticatedUser;
    final names = user['name'];
    String nameOf(String key) {
      final value = names is Map ? names[key] : null;
      return value is String ? value.trim() : '';
    }

    final name = nameOf('startingWithFirstName');
    if (user['id'] != hit.id || name.isEmpty) return hit;
    final title = nameOf('startingWithLastName');
    return PlannerSearchResult(
      id: hit.id,
      typeName: hit.typeName,
      kind: hit.kind,
      calendar: hit.calendar,
      name: name,
      title: title.isEmpty ? name : title,
      description: hit.description,
      pictureUrl: hit.pictureUrl,
      icon: hit.icon,
      isDeleted: hit.isDeleted,
      raw: hit.raw,
    );
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

  /// Parses the calendars the planner names in its answer to the lookup of
  /// [getCalendar] (`quick-search/planner/start`): the hits of its
  /// `selection`, in the form of the search's hits. An empty `selection` is
  /// an empty list; the rest of the answer (the search's suggestions, the
  /// user's favourites, its options) is left out.
  static List<PlannerSearchResult> parseCalendarLookup(dynamic json) {
    if (json is! Map<String, dynamic>) {
      throw SmartschoolPlannerError(
        'The planner gave the lookup of a calendar as ${json.runtimeType} '
        'instead of an object.',
      );
    }
    final selection = json['selection'];
    if (selection is! List) {
      throw SmartschoolPlannerError(
        'The planner gave the calendars of a lookup (selection) as '
        '${selection.runtimeType} instead of a list.',
      );
    }
    return [
      for (final (index, item) in selection.indexed)
        if (item is Map<String, dynamic>)
          PlannerSearchResult.fromJson(item)
        else
          throw SmartschoolPlannerError(
            'The planner gave calendar $index of a lookup as '
            '${item.runtimeType} instead of an object.',
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

  /// The form of the planner's names of element types (`planned-lessons`,
  /// `planned-lesson-cluster-moments`): every name of [PlannedElementType]
  /// has it. A name of another form never goes into a request path.
  static final _typeName = RegExp(r'^planned(?:-[a-z0-9]+)+$');

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

  /// The decoded JSON of [response], the planner's answer to [what], which
  /// must have one of the HTTP statuses [ok] (`200` by default; the create
  /// of an assignment is answered with `201`).
  static dynamic _decode(
    Response<String> response,
    String what, {
    Set<int> ok = const {200},
  }) {
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (!ok.contains(status)) {
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
