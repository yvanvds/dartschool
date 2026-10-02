/// Models for Smartschool's **planner** (Planner): the calendars it shows (of
/// a user, a class or a location), the elements planned in them (lessons,
/// assignments, timetable slots, ...) and the full detail of one element.
///
/// The planner's IDs are strings, and come in two forms:
/// - a calendar ID, the platform ID and the ID joined by `_`: a user
///   `{platformId}_{userId}_{coaccount}` (`4069_146_0`, the whole
///   `authenticatedUser.id` of the session, not the `SmartschoolUser.id`,
///   which is only its middle part), a class `{platformId}_{groupId}`
///   (`4069_2001`), a location `{platformId}_{itemId}`;
/// - the ID of a planned element, a course or a location: a UUID, with the
///   platform ID in a field of its own (`platformId`).
///
/// [PlannerUser.calendar], [PlannerGroup.calendar] and
/// [PlannerLocation.calendar] give the calendar of a user, class or location
/// that an element names.
library;

import '../exceptions.dart';

// ---------------------------------------------------------------------------
// Calendars
// ---------------------------------------------------------------------------

/// The kind of calendar the planner shows: the `{calendarType}` of
/// `/planner/api/v1/planned-elements/{calendarType}/{calendarId}`.
enum PlannerCalendarType {
  /// The planner of a user (a teacher, or the account itself).
  user('user'),

  /// The planner of a class: the elements of all its teachers.
  group('group'),

  /// The planner of a location (a room).
  location('location');

  const PlannerCalendarType(this.wireName);

  /// The name in the planner's URL (`user`, `group`, `location`).
  final String wireName;
}

/// A calendar of the planner: the planner of a user, a class or a location,
/// as `/planner/main/user/...`, `/planner/main/group/...` and
/// `/planner/main/location/...` show it.
///
/// ```dart
/// final me = await planner.ownCalendar();      // PlannerCalendar.user('4069_146_0')
/// final klas = PlannerCalendar.group('4069_2001');
/// final room = element.locations.first.calendar; // PlannerCalendar.location('4069_<uuid>')
/// ```
///
/// The constructors check the form of the ID (see the library comment) and
/// throw an [ArgumentError] for another one, before anything is sent:
/// Smartschool answers a location's bare UUID with `400`, and a bare user ID
/// (the `SmartschoolUser.id`) is not a planner ID.
class PlannerCalendar {
  const PlannerCalendar._(this.type, this.id);

  /// The calendar of [type] with ID [id]; see [PlannerCalendar.user],
  /// [PlannerCalendar.group] and [PlannerCalendar.location].
  factory PlannerCalendar(PlannerCalendarType type, String id) =>
      switch (type) {
        PlannerCalendarType.user => PlannerCalendar.user(id),
        PlannerCalendarType.group => PlannerCalendar.group(id),
        PlannerCalendarType.location => PlannerCalendar.location(id),
      };

  /// The planner of user [id], the whole user ID
  /// `{platformId}_{userId}_{coaccount}` (`4069_146_0`; a co-account ends in
  /// its own number, such as `_1`).
  factory PlannerCalendar.user(String id) {
    if (!_userId.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'not a planner user ID {platformId}_{userId}_{coaccount} (such as '
            '4069_146_0)',
      );
    }
    return PlannerCalendar._(PlannerCalendarType.user, id);
  }

  /// The planner of class [id], `{platformId}_{groupId}` (`4069_2001`). It
  /// holds the elements of all teachers of the class.
  factory PlannerCalendar.group(String id) =>
      PlannerCalendar._(PlannerCalendarType.group, _checkedId(id, 'group'));

  /// The planner of location [id], `{platformId}_{itemId}` (see
  /// [PlannerLocation.calendar]); the bare item ID is refused.
  factory PlannerCalendar.location(String id) => PlannerCalendar._(
    PlannerCalendarType.location,
    _checkedId(id, 'location'),
  );

  /// The kind of calendar.
  final PlannerCalendarType type;

  /// The calendar ID, as the planner's URL holds it.
  final String id;

  static final _userId = RegExp(r'^\d+_\d+_\d+$');
  static final _platformPrefixedId = RegExp(r'^\d+_[^\s/?#]+$');

  static String _checkedId(String id, String kind) {
    if (!_platformPrefixedId.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'not a planner $kind ID {platformId}_{id} (the platform ID, an '
            'underscore and the ID)',
      );
    }
    return id;
  }

  @override
  bool operator ==(Object other) =>
      other is PlannerCalendar && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => 'PlannerCalendar(${type.wireName}: $id)';
}

// ---------------------------------------------------------------------------
// Element types
// ---------------------------------------------------------------------------

/// The type of a planned element (`plannedElementType`), as the planner's
/// web client names them.
///
/// Only [lesson], [assignment] and [placeholder] were seen on the live site;
/// the others are the web client's constants. A type this library does not
/// know is [other]; [PlannedElement.typeName] keeps its name.
enum PlannedElementType {
  /// A lesson (`planned-lessons`): a "lesfiche" in a lesson hour.
  lesson('planned-lessons'),

  /// An assignment (`planned-assignments`): a test, a task, something to
  /// bring along; with a [PlannedElement.assignmentType].
  assignment('planned-assignments'),

  /// A timetable slot (`planned-placeholders`): one per teacher per lesson
  /// hour, with the classes, the course and the room, but no name.
  placeholder('planned-placeholders'),

  /// `planned-to-dos`.
  toDo('planned-to-dos'),

  /// `planned-school-activities`.
  schoolActivity('planned-school-activities'),

  /// `planned-meetings`.
  meeting('planned-meetings'),

  /// `planned-lesson-free-days`.
  lessonFreeDay('planned-lesson-free-days'),

  /// `planned-generics`.
  generic('planned-generics'),

  /// `planned-activities`.
  activity('planned-activities'),

  /// `planned-routines`.
  routine('planned-routines'),

  /// `planned-partner-elements`.
  partnerElement('planned-partner-elements'),

  /// `planned-lesson-clusters`.
  lessonCluster('planned-lesson-clusters'),

  /// `planned-lesson-cluster-moments`.
  lessonClusterMoment('planned-lesson-cluster-moments'),

  /// `planned-lesson-cluster-lessons`.
  lessonClusterLesson('planned-lesson-cluster-lessons'),

  /// `planned-lesson-cluster-assignments`.
  lessonClusterAssignment('planned-lesson-cluster-assignments'),

  /// `planned-merged-teaching-moments`.
  mergedTeachingMoment('planned-merged-teaching-moments'),

  /// A type this library does not know. [PlannedElement.typeName] holds the
  /// planner's name for it.
  other(null);

  const PlannedElementType(this.wireName);

  /// The planner's name of the type (`planned-lessons`), or `null` for
  /// [other].
  final String? wireName;

  /// The type the planner calls [wireName], or [other] when this library
  /// does not know it.
  static PlannedElementType fromWire(String wireName) {
    for (final type in values) {
      if (type.wireName == wireName) return type;
    }
    return other;
  }
}

// ---------------------------------------------------------------------------
// Parts of an element
// ---------------------------------------------------------------------------

/// When a planned element takes place (`period`).
class PlannerPeriod {
  /// The start, in the local time of this machine. The planner gives it with
  /// the school's offset from UTC (`2026-10-05T08:30:00+02:00`).
  final DateTime from;

  /// The end, in the local time of this machine.
  final DateTime to;

  /// Whether the element takes the whole day.
  final bool wholeDay;

  /// Whether the element is a deadline (`true` for an assignment: due at
  /// [from]).
  final bool deadline;

  const PlannerPeriod({
    required this.from,
    required this.to,
    this.wholeDay = false,
    this.deadline = false,
  });

  factory PlannerPeriod.fromJson(Map<String, dynamic> json) => PlannerPeriod(
    from: _dateTime(json['dateTimeFrom'], 'the start of a period'),
    to: _dateTime(json['dateTimeTo'], 'the end of a period'),
    wholeDay: _bool(json['wholeDay']),
    deadline: _bool(json['deadline']),
  );

  @override
  String toString() =>
      'PlannerPeriod($from - $to${wholeDay ? ', whole day' : ''}'
      '${deadline ? ', deadline' : ''})';
}

/// A user an element names: an organiser (the teacher) or a participant.
class PlannerUser {
  /// The planner's user ID, `{platformId}_{userId}_{coaccount}`
  /// (`4069_1002_0`).
  final String id;

  /// The name, first name first (`name.startingWithFirstName`).
  final String name;

  /// The name, last name first (`name.startingWithLastName`).
  final String nameLastFirst;

  /// The URL of the user's picture, or `null` when the planner gave none.
  final String? pictureUrl;

  /// Whether the user was deleted.
  final bool isDeleted;

  const PlannerUser({
    required this.id,
    required this.name,
    this.nameLastFirst = '',
    this.pictureUrl,
    this.isDeleted = false,
  });

  factory PlannerUser.fromJson(Map<String, dynamic> json) {
    final names = _optionalMap(json['name'], 'the name of a user') ?? const {};
    return PlannerUser(
      id: _requiredString(json, 'id', 'a user'),
      name: (_optionalString(names['startingWithFirstName']) ?? '').trim(),
      nameLastFirst: (_optionalString(names['startingWithLastName']) ?? '')
          .trim(),
      pictureUrl: _optionalString(json['pictureUrl']),
      isDeleted: _bool(json['deleted']),
    );
  }

  /// The planner of this user.
  PlannerCalendar get calendar => PlannerCalendar.user(id);

  @override
  String toString() => 'PlannerUser($id, $name)';
}

/// A group an element names: typically a class whose pupils take part.
class PlannerGroup {
  /// The planner's group ID, `{platformId}_{groupId}` (`4069_2001`).
  final String id;

  /// The platform (school) the group belongs to.
  final int platformId;

  /// The group's name (`6A1`).
  final String name;

  /// The kind of group as the planner gives it (`K` for a class).
  final String type;

  /// The icon the planner shows for the group (`briefcase`), or `null`.
  final String? icon;

  const PlannerGroup({
    required this.id,
    required this.platformId,
    required this.name,
    this.type = '',
    this.icon,
  });

  factory PlannerGroup.fromJson(Map<String, dynamic> json) => PlannerGroup(
    id: _requiredString(json, 'id', 'a group'),
    platformId: _requiredInt(json, 'platformId', 'a group'),
    name: (_optionalString(json['name']) ?? '').trim(),
    type: _optionalString(json['type']) ?? '',
    icon: _optionalString(json['icon']),
  );

  /// The planner of this group (for a class: the elements of all its
  /// teachers).
  PlannerCalendar get calendar => PlannerCalendar.group(id);

  @override
  String toString() => 'PlannerGroup($id, $name)';
}

/// A course an element is about.
class PlannerCourse {
  /// The course ID (a UUID).
  final String id;

  /// The platform (school) the course belongs to.
  final int platformId;

  /// The course name (`wiskunde`).
  final String name;

  /// The timetable codes of the course (`WISKU`, `WISKU1`).
  final List<String> scheduleCodes;

  /// The icon the planner shows for the course, or `null`.
  final String? icon;

  /// The ID of the course's cluster (`courseCluster.id`), or `null`.
  final int? clusterId;

  /// The name of the course's cluster (`Wiskunde`), or `null`.
  final String? clusterName;

  /// Whether the course is visible.
  final bool isVisible;

  const PlannerCourse({
    required this.id,
    required this.platformId,
    required this.name,
    this.scheduleCodes = const [],
    this.icon,
    this.clusterId,
    this.clusterName,
    this.isVisible = true,
  });

  factory PlannerCourse.fromJson(Map<String, dynamic> json) {
    final cluster = _optionalMap(json['courseCluster'], 'a course cluster');
    return PlannerCourse(
      id: _requiredString(json, 'id', 'a course'),
      platformId: _requiredInt(json, 'platformId', 'a course'),
      name: (_optionalString(json['name']) ?? '').trim(),
      scheduleCodes: [
        for (final code in _list(json['scheduleCodes'], 'schedule codes'))
          if (_optionalString(code) case final String text) text,
      ],
      icon: _optionalString(json['icon']),
      clusterId: cluster == null ? null : _optionalInt(cluster['id']),
      clusterName: cluster == null ? null : _optionalString(cluster['name']),
      isVisible: json['isVisible'] == null || _bool(json['isVisible']),
    );
  }

  @override
  String toString() => 'PlannerCourse($id, $name)';
}

/// A location an element takes place in: a room.
class PlannerLocation {
  /// The location's item ID (a UUID). Its calendar ID is
  /// `{platformId}_{id}`: see [calendar].
  final String id;

  /// The platform (school) the location belongs to.
  final int platformId;

  /// The name of that platform (the school's name).
  final String platformName;

  /// The location's number, `""` when it has none.
  final String number;

  /// The location's title (the room, such as `101`).
  final String title;

  /// The icon the planner shows for the location, or `null`.
  final String? icon;

  /// The kind of location as the planner gives it (`mini-db-item`).
  final String type;

  /// Whether the location can be chosen for an element.
  final bool selectable;

  const PlannerLocation({
    required this.id,
    required this.platformId,
    required this.title,
    this.platformName = '',
    this.number = '',
    this.icon,
    this.type = '',
    this.selectable = false,
  });

  factory PlannerLocation.fromJson(Map<String, dynamic> json) =>
      PlannerLocation(
        id: _requiredString(json, 'id', 'a location'),
        platformId: _requiredInt(json, 'platformId', 'a location'),
        platformName: _optionalString(json['platformName']) ?? '',
        number: _optionalString(json['number']) ?? '',
        title: (_optionalString(json['title']) ?? '').trim(),
        icon: _optionalString(json['icon']),
        type: _optionalString(json['type']) ?? '',
        selectable: _bool(json['selectable']),
      );

  /// The planner of this location: calendar ID `{platformId}_{id}`.
  PlannerCalendar get calendar => PlannerCalendar.location('${platformId}_$id');

  @override
  String toString() => 'PlannerLocation($id, $title)';
}

/// The type of an assignment (`assignmentType`): a school's kind of test or
/// task, such as `Kleine Overhoring` (`KO`).
class PlannerAssignmentType {
  /// The type ID (a UUID).
  final String id;

  /// The platform (school) of the type, or `null` when the planner left it
  /// out (it does inside a planned element).
  final int? platformId;

  /// The type's name (`Kleine Overhoring`).
  final String name;

  /// The type's abbreviation (`KO`).
  final String abbreviation;

  /// Whether the type is visible.
  final bool isVisible;

  /// When an assignment of this type is due by default (`deadline`).
  final String defaultTiming;

  /// The type's weight in the planner's workload, as the school set it (`0`
  /// when it set none).
  final num weight;

  const PlannerAssignmentType({
    required this.id,
    required this.name,
    this.platformId,
    this.abbreviation = '',
    this.isVisible = true,
    this.defaultTiming = '',
    this.weight = 0,
  });

  factory PlannerAssignmentType.fromJson(Map<String, dynamic> json) {
    final weight = json['weight'];
    return PlannerAssignmentType(
      id: _requiredString(json, 'id', 'an assignment type'),
      platformId: _optionalInt(json['platformId']),
      name: (_optionalString(json['name']) ?? '').trim(),
      abbreviation: (_optionalString(json['abbreviation']) ?? '').trim(),
      isVisible: json['isVisible'] == null || _bool(json['isVisible']),
      defaultTiming: _optionalString(json['defaultTiming']) ?? '',
      weight: weight is num ? weight : num.tryParse('${weight ?? ''}') ?? 0,
    );
  }

  @override
  String toString() =>
      'PlannerAssignmentType($id, $name${abbreviation.isEmpty ? '' : ' '
                '($abbreviation)'})';
}

/// What the authenticated user may do with a planned element
/// (`capabilities`), as the planner tells it.
///
/// [flags] holds every `canUser...` flag by its name; the getters give the
/// common ones. A flag the planner left out reads as `false`.
class PlannedElementCapabilities {
  /// Every `canUser...` flag of the element, by its name (`canUserEdit`).
  final Map<String, bool> flags;

  /// The properties of the element the user may see (the names that
  /// `canUserSeeProperties` sets to `true`, such as `privateInfo`).
  final Set<String> visibleProperties;

  const PlannedElementCapabilities({
    this.flags = const {},
    this.visibleProperties = const {},
  });

  factory PlannedElementCapabilities.fromJson(Map<String, dynamic> json) {
    final flags = <String, bool>{};
    for (final MapEntry(:key, :value) in json.entries) {
      if (value is bool) flags[key] = value;
    }
    final seen = _optionalMap(
      json['canUserSeeProperties'],
      'the visible properties of an element',
    );
    return PlannedElementCapabilities(
      flags: Map.unmodifiable(flags),
      visibleProperties: Set.unmodifiable({
        for (final MapEntry(:key, :value) in (seen ?? const {}).entries)
          if (value == true) key,
      }),
    );
  }

  /// Flag [name] (such as `canUserChangeLabels`); `false` when the planner
  /// left it out.
  bool can(String name) => flags[name] ?? false;

  /// `canUserEdit`.
  bool get canEdit => can('canUserEdit');

  /// `canUserRename`.
  bool get canRename => can('canUserRename');

  /// `canUserReplace`: for a timetable slot, whether it can be filled.
  bool get canReplace => can('canUserReplace');

  /// `canUserReschedule`.
  bool get canReschedule => can('canUserReschedule');

  /// `canUserChangePublicInfo`.
  bool get canChangePublicInfo => can('canUserChangePublicInfo');

  /// `canUserChangePrivateInfo`.
  bool get canChangePrivateInfo => can('canUserChangePrivateInfo');

  /// `canUserTrash`.
  bool get canTrash => can('canUserTrash');

  /// `canUserDelete`.
  bool get canDelete => can('canUserDelete');

  @override
  String toString() =>
      'PlannedElementCapabilities('
      '${[for (final MapEntry(:key, :value) in flags.entries)
        if (value) key].join(', ')})';
}

// ---------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------

/// An element of a planner calendar, as the calendar lists it: a lesson, an
/// assignment, a timetable slot (placeholder), ...
///
/// Returned by `PlannerService.getPlannedElements`. The full detail of an
/// element (with its info texts) is a [PlannedElementDetail], from
/// `PlannerService.getDetail`.
///
/// Do not keep the ID of a timetable slot ([PlannedElementType.placeholder])
/// for later: a slot that was filled and cleared again comes back with a new
/// ID. Find a slot again by its period, course and groups.
class PlannedElement {
  /// The element ID (a UUID).
  final String id;

  /// The platform (school) of the element.
  final int platformId;

  /// The element type; [PlannedElementType.other] for a type this library
  /// does not know (see [typeName]).
  final PlannedElementType type;

  /// The planner's name of the type (`planned-lessons`), also for a type this
  /// library does not know.
  final String typeName;

  /// The element's name (title), or `null` when it has none: a timetable
  /// slot (placeholder) has no name.
  final String? name;

  /// When the element takes place.
  final PlannerPeriod period;

  /// The users who organise the element: its teacher (`organisers.users`).
  final List<PlannerUser> organiserUsers;

  /// The groups that organise the element (`organisers.groups`).
  final List<PlannerGroup> organiserGroups;

  /// The users who take part (`participants.users`).
  final List<PlannerUser> participantUsers;

  /// The groups that take part: the classes (`participants.groups`).
  final List<PlannerGroup> participantGroups;

  /// Whether the authenticated user takes part in the element.
  final bool isParticipant;

  /// What the authenticated user may do with the element.
  final PlannedElementCapabilities capabilities;

  /// The icon of the element (`document_observation`), or `null`.
  final String? icon;

  /// The courses the element is about.
  final List<PlannerCourse> courses;

  /// The locations (rooms) of the element.
  final List<PlannerLocation> locations;

  /// The type of an assignment; `null` for other elements.
  final PlannerAssignmentType? assignmentType;

  /// The status of an assignment (`unresolved`); `null` for other elements.
  final String? resolvedStatus;

  /// Whether the element is pinned.
  final bool pinned;

  /// Whether the element is unconfirmed.
  final bool unconfirmed;

  /// The colour the planner shows the element in (`aqua-200`), or `null`.
  final String? color;

  /// The element as the planner gave it (decoded JSON, read-only), for the
  /// fields these models do not cover.
  final Map<String, dynamic> raw;

  const PlannedElement({
    required this.id,
    required this.platformId,
    required this.type,
    required this.typeName,
    required this.period,
    this.name,
    this.organiserUsers = const [],
    this.organiserGroups = const [],
    this.participantUsers = const [],
    this.participantGroups = const [],
    this.isParticipant = false,
    this.capabilities = const PlannedElementCapabilities(),
    this.icon,
    this.courses = const [],
    this.locations = const [],
    this.assignmentType,
    this.resolvedStatus,
    this.pinned = false,
    this.unconfirmed = false,
    this.color,
    this.raw = const {},
  });

  /// A copy of [element], for [PlannedElementDetail].
  PlannedElement._copy(PlannedElement element)
    : id = element.id,
      platformId = element.platformId,
      type = element.type,
      typeName = element.typeName,
      name = element.name,
      period = element.period,
      organiserUsers = element.organiserUsers,
      organiserGroups = element.organiserGroups,
      participantUsers = element.participantUsers,
      participantGroups = element.participantGroups,
      isParticipant = element.isParticipant,
      capabilities = element.capabilities,
      icon = element.icon,
      courses = element.courses,
      locations = element.locations,
      assignmentType = element.assignmentType,
      resolvedStatus = element.resolvedStatus,
      pinned = element.pinned,
      unconfirmed = element.unconfirmed,
      color = element.color,
      raw = element.raw;

  /// Parses an element as the planner gives it. Throws a
  /// [SmartschoolPlannerError] when it lacks its `id`, `platformId`,
  /// `plannedElementType` or `period`, or holds a part in an unknown shape.
  factory PlannedElement.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json, 'id', 'a planned element');
    final what = 'planned element $id';
    final typeName = _requiredString(json, 'plannedElementType', what);
    final organisers =
        _optionalMap(json['organisers'], 'the organisers of $what') ??
        const <String, dynamic>{};
    final participants =
        _optionalMap(json['participants'], 'the participants of $what') ??
        const <String, dynamic>{};
    final assignmentType = _optionalMap(
      json['assignmentType'],
      'the assignment type of $what',
    );
    final name = _optionalString(json['name']);
    return PlannedElement(
      id: id,
      platformId: _requiredInt(json, 'platformId', what),
      type: PlannedElementType.fromWire(typeName),
      typeName: typeName,
      name: name,
      period: PlannerPeriod.fromJson(
        _map(json['period'], 'the period of $what'),
      ),
      organiserUsers: _objects(
        organisers['users'],
        'the organising users of $what',
        PlannerUser.fromJson,
      ),
      organiserGroups: _objects(
        organisers['groups'],
        'the organising groups of $what',
        PlannerGroup.fromJson,
      ),
      participantUsers: _objects(
        participants['users'],
        'the participating users of $what',
        PlannerUser.fromJson,
      ),
      participantGroups: _objects(
        participants['groups'],
        'the participating groups of $what',
        PlannerGroup.fromJson,
      ),
      isParticipant: _bool(json['isParticipant']),
      capabilities: PlannedElementCapabilities.fromJson(
        _optionalMap(json['capabilities'], 'the capabilities of $what') ??
            const {},
      ),
      icon: _optionalString(json['icon']),
      courses: _objects(
        json['courses'],
        'the courses of $what',
        PlannerCourse.fromJson,
      ),
      locations: _objects(
        json['locations'],
        'the locations of $what',
        PlannerLocation.fromJson,
      ),
      assignmentType: assignmentType == null
          ? null
          : PlannerAssignmentType.fromJson(assignmentType),
      resolvedStatus: _optionalString(json['resolvedStatus']),
      pinned: _bool(json['pinned']),
      unconfirmed: _bool(json['unconfirmed']),
      color: _optionalString(json['color']),
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() =>
      'PlannedElement($typeName $id${name == null ? '' : ' "$name"'}, '
      '${period.from} - ${period.to})';
}

/// The full detail of one planned element: the [PlannedElement] fields, and
/// the info texts and other fields only the detail holds.
///
/// Returned by `PlannerService.getPlannedElement` and `getDetail`. The detail
/// is up to date at once after a change in the planner; the calendar list
/// may still show the old state for a few seconds.
class PlannedElementDetail extends PlannedElement {
  /// The old name of [privateInfo]: it held the same text in every answer
  /// seen. HTML; `""` when empty.
  final String info;

  /// The info that pupils do not see (HTML; `""` when empty). Not private to
  /// the organiser: other teachers who can read the element (for instance in
  /// the calendar of a class) see it too.
  final String privateInfo;

  /// The info that pupils see (HTML; `""` when empty).
  final String publicInfo;

  /// For an assignment: whether it was announced ("aankondigen"); `null` for
  /// other elements.
  final bool? isAnnounced;

  /// For an assignment: from when pupils see it (`visibility.afterDate`), in
  /// local time; `null` when the planner gave no such date.
  final DateTime? visibleFrom;

  /// For an assignment: whether a Skore evaluation is linked to it; `null`
  /// for other elements.
  final bool? hasLinkedEvaluation;

  /// For an assignment: when it was created, in local time; `null` when the
  /// planner gave no such date.
  final DateTime? dateCreated;

  PlannedElementDetail._(
    super.element, {
    required this.info,
    required this.privateInfo,
    required this.publicInfo,
    this.isAnnounced,
    this.visibleFrom,
    this.hasLinkedEvaluation,
    this.dateCreated,
  }) : super._copy();

  /// Parses the detail of an element as the planner gives it; see
  /// [PlannedElement.fromJson].
  factory PlannedElementDetail.fromJson(Map<String, dynamic> json) {
    final element = PlannedElement.fromJson(json);
    final what = 'planned element ${element.id}';
    final visibility = _optionalMap(
      json['visibility'],
      'the visibility of $what',
    );
    final visibleFrom = visibility?['afterDate'];
    final created = json['dateCreated'];
    return PlannedElementDetail._(
      element,
      info: _optionalString(json['info']) ?? '',
      privateInfo: _optionalString(json['privateInfo']) ?? '',
      publicInfo: _optionalString(json['publicInfo']) ?? '',
      isAnnounced: json['isAnnounced'] == null
          ? null
          : _bool(json['isAnnounced']),
      visibleFrom: visibleFrom == null
          ? null
          : _dateTime(visibleFrom, 'the visibility date of $what'),
      hasLinkedEvaluation: json['hasLinkedEvaluation'] == null
          ? null
          : _bool(json['hasLinkedEvaluation']),
      dateCreated: created == null
          ? null
          : _dateTime(created, 'the creation date of $what'),
    );
  }

  @override
  String toString() =>
      'PlannedElementDetail($typeName $id${name == null ? '' : ' "$name"'}, '
      '${period.from} - ${period.to})';
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

String _kind(Object? value) => switch (value) {
  null => 'null',
  String() => 'a string',
  num() => 'a number',
  bool() => 'a boolean',
  List() => 'a list',
  Map() => 'an object',
  _ => value.runtimeType.toString(),
};

Map<String, dynamic> _map(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return {for (final e in value.entries) '${e.key}': e.value};
  throw SmartschoolPlannerError(
    'The planner gave $what as ${_kind(value)} instead of an object.',
  );
}

Map<String, dynamic>? _optionalMap(Object? value, String what) =>
    value == null ? null : _map(value, what);

List<dynamic> _list(Object? value, String what) {
  if (value == null) return const [];
  if (value is List) return value;
  throw SmartschoolPlannerError(
    'The planner gave $what as ${_kind(value)} instead of a list.',
  );
}

/// The objects in list [value], each parsed with [parse].
List<T> _objects<T>(
  Object? value,
  String what,
  T Function(Map<String, dynamic>) parse,
) => List.unmodifiable([
  for (final item in _list(value, what)) parse(_map(item, 'one of $what')),
]);

String _requiredString(Map<String, dynamic> json, String key, String what) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  if (value is int) return '$value';
  throw SmartschoolPlannerError(
    'The planner gave $what without its $key (${_kind(value)}).',
  );
}

String? _optionalString(Object? value) => switch (value) {
  null => null,
  String() => value,
  num() || bool() => '$value',
  _ => throw SmartschoolPlannerError(
    'The planner gave ${_kind(value)} where it gives a text.',
  ),
};

int _requiredInt(Map<String, dynamic> json, String key, String what) {
  final value = _optionalInt(json[key]);
  if (value != null) return value;
  throw SmartschoolPlannerError(
    'The planner gave $what without a numeric $key (${_kind(json[key])}).',
  );
}

int? _optionalInt(Object? value) => switch (value) {
  int() => value,
  String() => int.tryParse(value.trim()),
  _ => null,
};

bool _bool(Object? value) => value == true || value == 1 || value == 'true';

DateTime _dateTime(Object? value, String what) {
  final parsed = value is String ? DateTime.tryParse(value.trim()) : null;
  if (parsed == null) {
    throw SmartschoolPlannerError(
      'The planner gave $what as "$value", which is not a date and time.',
    );
  }
  return parsed.toLocal();
}
