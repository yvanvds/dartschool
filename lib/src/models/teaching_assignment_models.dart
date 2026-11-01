import '../exceptions.dart';
import 'goal_models.dart';
import 'lesson_content_models.dart';

/// Which lesfiches a teaching assignment takes, the `type` of its
/// `contentFilter` (#229): only the lesfiches it lets in can be added to
/// one of its lesson clusters.
///
/// Seen live (2026-11-01): with [none], the module refused every lesfiche
/// added to a cluster (an exception with the status `403` for each); with
/// [all], the teaching assignment listed all the user's lesfiches and took
/// them. [particular] filters by labels, courses and assignment types; the
/// library reads it, but does not make it.
enum TeachingAssignmentContentFilter {
  /// `none`: no lesfiches.
  none('none'),

  /// `all`: all the user's lesfiches.
  all('all'),

  /// `particular`: the lesfiches with some labels, courses or assignment
  /// types.
  particular('particular'),

  /// A filter this library does not know (or none was given).
  other(null);

  const TeachingAssignmentContentFilter(this.wireName);

  /// The module's name of the filter; `null` for [other].
  final String? wireName;

  /// The filter named [name], or [other].
  static TeachingAssignmentContentFilter fromWire(Object? name) =>
      values.firstWhere(
        (filter) => filter.wireName != null && filter.wireName == name,
        orElse: () => other,
      );
}

/// A teaching assignment of the Lesfiches module, by its IDs (#229): what
/// `TeachingAssignmentService` needs to name one. A [TeachingAssignment] is
/// one.
class TeachingAssignmentRef {
  /// The teaching assignment's ID (a UUID).
  final String id;

  /// The platform (school) of the teaching assignment.
  final int platformId;

  const TeachingAssignmentRef({required this.id, required this.platformId});

  @override
  bool operator ==(Object other) =>
      other is TeachingAssignmentRef &&
      other.id.toLowerCase() == id.toLowerCase() &&
      other.platformId == platformId;

  @override
  int get hashCode => Object.hash(id.toLowerCase(), platformId);

  @override
  String toString() => 'TeachingAssignmentRef($platformId $id)';
}

/// A **teaching assignment** ("leeropdracht") of the Lesfiches module, the
/// year plan of a teacher (#229): a named collection of the teacher's
/// lesfiches, split into lesson clusters ([LessonCluster], the units of the
/// year), which the planner plans over a period for a class.
///
/// Returned by `TeachingAssignmentService.getTeachingAssignments`,
/// `getTeachingAssignment` and `createTeachingAssignment`.
class TeachingAssignment extends TeachingAssignmentRef {
  /// The whole user ID of the owner (`owner.id`, such as `4069_146_0`), or
  /// `null` when the module gave none.
  final String? ownerId;

  /// The name of the teaching assignment.
  final String name;

  /// Its icon (such as `box_curver_blue`), or `null`.
  final String? icon;

  /// Which lesfiches it takes, as the module gives it for the owner (the
  /// `contentFilter` of the owner among its `collaborators`).
  final TeachingAssignmentContentFilter contentFilter;

  /// Its lesson clusters, in the module's order, each with its ID, name,
  /// icon, position and visibility only: the counts, info and goals are in
  /// `TeachingAssignmentService.getClusters`.
  final List<LessonCluster> clusters;

  /// Whether it is visible (`visibility`).
  final bool isVisible;

  /// Whether the user marked it as a favourite (`favourite`).
  final bool isFavourite;

  /// The teaching assignment as the module gave it (decoded JSON,
  /// read-only), for the fields this model does not cover (the
  /// collaborators, the publication).
  final Map<String, dynamic> raw;

  const TeachingAssignment({
    required super.id,
    required super.platformId,
    this.ownerId,
    required this.name,
    this.icon,
    this.contentFilter = TeachingAssignmentContentFilter.other,
    this.clusters = const [],
    this.isVisible = true,
    this.isFavourite = false,
    this.raw = const {},
  });

  /// Parses a teaching assignment as the module gives it. Throws a
  /// [SmartschoolLessonContentError] when it lacks its `id` or
  /// `platformId`, or holds a part in an unknown shape.
  factory TeachingAssignment.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json, 'id', 'a teaching assignment');
    final what = 'teaching assignment $id';
    final platformId = _requiredInt(json, 'platformId', what);
    final ownerId = _userId(json['owner'], 'the owner of $what');
    var filter = TeachingAssignmentContentFilter.other;
    for (final collaborator in _list(
      json['collaborators'],
      'the collaborators of $what',
    )) {
      final entry = _map(collaborator, 'a collaborator of $what');
      final userId = _userId(entry['user'], 'a collaborator of $what');
      if (ownerId == null || userId == ownerId) {
        final contentFilter = entry['contentFilter'];
        filter = TeachingAssignmentContentFilter.fromWire(
          contentFilter is Map ? contentFilter['type'] : null,
        );
        break;
      }
    }
    return TeachingAssignment(
      id: id,
      platformId: platformId,
      ownerId: ownerId,
      name: (_optionalString(json['name']) ?? '').trim(),
      icon: _optionalString(json['icon']),
      contentFilter: filter,
      clusters: List.unmodifiable([
        for (final cluster in _list(
          json['lessonClusters'],
          'the lesson clusters of $what',
        ))
          LessonCluster.fromJson(
            _map(cluster, 'a lesson cluster of $what'),
            teachingAssignment: TeachingAssignmentRef(
              id: id,
              platformId: platformId,
            ),
          ),
      ]),
      isVisible: json['visibility'] == null || json['visibility'] == true,
      isFavourite: json['favourite'] == true,
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'TeachingAssignment($platformId $id "$name")';
}

/// A lesson cluster by its IDs and those of its teaching assignment (#229):
/// what `TeachingAssignmentService` needs to name one, and what the planner
/// keeps when it plans a cluster for a class (#230). A [LessonCluster] is
/// one; one kept by its IDs can be made with the constructor.
class LessonClusterRef {
  /// The lesson cluster's ID (a UUID).
  final String id;

  /// The platform (school) of the lesson cluster.
  final int platformId;

  /// The teaching assignment the cluster is part of.
  final TeachingAssignmentRef teachingAssignment;

  const LessonClusterRef({
    required this.id,
    required this.platformId,
    required this.teachingAssignment,
  });

  /// The cluster as the module names it in a list of identifiers:
  /// `{"id", "platformId"}`.
  Map<String, Object> toWire() => {'id': id, 'platformId': platformId};

  @override
  bool operator ==(Object other) =>
      other is LessonClusterRef &&
      other.id.toLowerCase() == id.toLowerCase() &&
      other.platformId == platformId &&
      other.teachingAssignment == teachingAssignment;

  @override
  int get hashCode => Object.hash(id.toLowerCase(), platformId);

  @override
  String toString() => 'LessonClusterRef($platformId $id)';
}

/// A **lesson cluster** ("lescluster") of a teaching assignment (#229): a
/// unit of the year plan, which holds lesfiches and titles in order
/// (`TeachingAssignmentService.getClusterContent`), with learning goals,
/// info for pupils and for the teacher, and an estimate of its teaching
/// hours. The planner plans a cluster over a period for a class (#230).
///
/// The counts ([numberOfLessons] and the others), the info and the goals
/// are `null` (or empty) in the short form a [TeachingAssignment] lists its
/// clusters in; `TeachingAssignmentService.getClusters`, `getCluster` and
/// the writes give them.
class LessonCluster extends LessonClusterRef {
  /// The name of the cluster.
  final String name;

  /// Its icon (such as `box_curver_blue`), or `null`.
  final String? icon;

  /// Whether it is visible (`isVisible`).
  final bool isVisible;

  /// Its place among the clusters of its teaching assignment (`position`,
  /// from `0`), or `null` when the module gave none.
  final int? position;

  /// The info that pupils see (`publicInfo.text`, HTML; `""` when empty).
  final String publicInfo;

  /// The info that only the teacher sees (`privateInfo.text`, HTML; `""`
  /// when empty).
  final String privateInfo;

  /// The learning goals of the cluster (`goals`), in the module's order:
  /// references to name with `GoalService.resolve`. Set with
  /// `TeachingAssignmentService.changeClusterGoals`.
  final List<LearningGoalRef> goals;

  /// How many lesson lesfiches it holds (`numberOfLessons`).
  final int? numberOfLessons;

  /// How many assignment lesfiches it holds (`numberOfAssignments`).
  final int? numberOfAssignments;

  /// How many learning goals it has (`numberOfGoals`).
  final int? numberOfGoals;

  /// The estimate of its teaching hours (`teachingHoursEstimate`).
  final num? teachingHoursEstimate;

  /// How many attachments its info has (`numberOfAttachments`).
  final int? numberOfAttachments;

  /// How many weblinks its info has (`numberOfWebLinks`).
  final int? numberOfWebLinks;

  /// The cluster as the module gave it (decoded JSON, read-only).
  final Map<String, dynamic> raw;

  const LessonCluster({
    required super.id,
    required super.platformId,
    required super.teachingAssignment,
    required this.name,
    this.icon,
    this.isVisible = true,
    this.position,
    this.publicInfo = '',
    this.privateInfo = '',
    this.goals = const [],
    this.numberOfLessons,
    this.numberOfAssignments,
    this.numberOfGoals,
    this.teachingHoursEstimate,
    this.numberOfAttachments,
    this.numberOfWebLinks,
    this.raw = const {},
  });

  /// Parses a lesson cluster as the module gives it: in full (with
  /// `teachingAssignmentId` and `teachingAssignmentPlatformId`), or in the
  /// short form of a teaching assignment's `lessonClusters`, which names
  /// neither, so [teachingAssignment] must. Throws a
  /// [SmartschoolLessonContentError] when it lacks its `id`, `platformId`
  /// or teaching assignment, or holds a part in an unknown shape.
  factory LessonCluster.fromJson(
    Map<String, dynamic> json, {
    TeachingAssignmentRef? teachingAssignment,
  }) {
    final id = _requiredString(json, 'id', 'a lesson cluster');
    final what = 'lesson cluster $id';
    final TeachingAssignmentRef parent;
    if (json['teachingAssignmentId'] != null) {
      parent = TeachingAssignmentRef(
        id: _requiredString(json, 'teachingAssignmentId', what),
        platformId: _requiredInt(json, 'teachingAssignmentPlatformId', what),
      );
    } else if (teachingAssignment != null) {
      parent = teachingAssignment;
    } else {
      throw SmartschoolLessonContentError(
        'The Lesfiches module gave $what without its teaching assignment.',
      );
    }
    return LessonCluster(
      id: id,
      platformId: _requiredInt(json, 'platformId', what),
      teachingAssignment: parent,
      name: (_optionalString(json['name']) ?? '').trim(),
      icon: _optionalString(json['icon']),
      isVisible: json['isVisible'] == null || json['isVisible'] == true,
      position: _optionalInt(json['position'], 'the position of $what'),
      publicInfo: _infoText(json['publicInfo'], 'the public info of $what'),
      privateInfo: _infoText(json['privateInfo'], 'the private info of $what'),
      goals: List.unmodifiable([
        for (final goal in _list(json['goals'], 'the goals of $what'))
          _goal(_map(goal, 'a goal of $what'), what),
      ]),
      numberOfLessons: _optionalInt(json['numberOfLessons'], what),
      numberOfAssignments: _optionalInt(json['numberOfAssignments'], what),
      numberOfGoals: _optionalInt(json['numberOfGoals'], what),
      teachingHoursEstimate: _optionalNum(
        json['teachingHoursEstimate'],
        'the teaching hours of $what',
      ),
      numberOfAttachments: _optionalInt(json['numberOfAttachments'], what),
      numberOfWebLinks: _optionalInt(json['numberOfWebLinks'], what),
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'LessonCluster($platformId $id "$name")';
}

/// An entry of a lesson cluster, in the cluster's order (#229): a
/// [LessonClusterLesfiche] or a [LessonClusterTitle]. Returned by
/// `TeachingAssignmentService.getClusterContent`.
sealed class LessonClusterEntry {
  /// The ID of the cluster it is in (`lessonClusterId`).
  final String lessonClusterId;

  /// Its place in the cluster (`position`, from `0`), or `null` when the
  /// module gave none.
  final int? position;

  /// The entry as the module gave it (decoded JSON, read-only).
  final Map<String, dynamic> raw;

  const LessonClusterEntry({
    required this.lessonClusterId,
    this.position,
    this.raw = const {},
  });

  /// Parses an entry of a cluster's content: a title (`type` `titles`) or a
  /// lesfiche (any other `type`). Throws a [SmartschoolLessonContentError]
  /// for an entry in an unknown shape.
  factory LessonClusterEntry.fromJson(Map<String, dynamic> json) {
    final what = 'an entry of a lesson cluster';
    final clusterId = _requiredString(json, 'lessonClusterId', what);
    final position = _optionalInt(json['position'], 'the position of $what');
    if (json['type'] == 'titles') {
      return LessonClusterTitle(
        id: _requiredString(json, 'id', 'a title of a lesson cluster'),
        platformId: _requiredInt(json, 'platformId', 'a title'),
        text: _optionalString(json['text']) ?? '',
        lessonClusterId: clusterId,
        position: position,
        raw: Map.unmodifiable(json),
      );
    }
    return LessonClusterLesfiche(
      item: LessonContentItem.fromJson(json),
      teachingHoursEstimate: _optionalNum(
        json['teachingHoursEstimate'],
        'the teaching hours of $what',
      ),
      numberOfGoals: _optionalInt(json['numberOfGoals'], what),
      lessonClusterId: clusterId,
      position: position,
      raw: Map.unmodifiable(json),
    );
  }
}

/// A lesfiche in a lesson cluster (#229): the lesfiche in the shape of
/// `LessonContentService.getItems` (its courses without names), with its
/// place in the cluster. The same lesfiche can be in a cluster more than
/// once (seen live).
final class LessonClusterLesfiche extends LessonClusterEntry {
  /// The lesfiche.
  final LessonContentItem item;

  /// The estimate of its teaching hours in the cluster
  /// (`teachingHoursEstimate`), or `null` (as seen live for a new entry).
  final num? teachingHoursEstimate;

  /// How many learning goals it has (`numberOfGoals`).
  final int? numberOfGoals;

  const LessonClusterLesfiche({
    required this.item,
    this.teachingHoursEstimate,
    this.numberOfGoals,
    required super.lessonClusterId,
    super.position,
    super.raw,
  });

  @override
  String toString() =>
      'LessonClusterLesfiche(${item.typeName} ${item.id} "${item.name}")';
}

/// A title in a lesson cluster (#229), such as "Week 1": a heading between
/// its lesfiches.
final class LessonClusterTitle extends LessonClusterEntry {
  /// The title's ID (a UUID).
  final String id;

  /// The platform (school) of the title.
  final int platformId;

  /// The text of the title.
  final String text;

  const LessonClusterTitle({
    required this.id,
    required this.platformId,
    required this.text,
    required super.lessonClusterId,
    super.position,
    super.raw,
  });

  @override
  String toString() => 'LessonClusterTitle($id "$text")';
}

/// A learning goal of a lesson cluster, with how many of its lesfiches have
/// it (#229): an entry of `TeachingAssignmentService.getClusterGoals`.
class LessonClusterGoal {
  /// The goal.
  final LearningGoalRef goal;

  /// The module's `count` (presumably how many of the cluster's lesfiches
  /// have the goal), or `null` when it gave none.
  final int? count;

  const LessonClusterGoal({required this.goal, this.count});

  /// Parses an entry of a cluster's goals (`{id, leerplanId, type, count}`).
  factory LessonClusterGoal.fromJson(Map<String, dynamic> json) =>
      LessonClusterGoal(
        goal: _goal(json, 'a lesson cluster'),
        count: _optionalInt(json['count'], 'the count of a goal'),
      );

  @override
  String toString() => 'LessonClusterGoal(${goal.id}, $count)';
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

LearningGoalRef _goal(Map<String, dynamic> json, String what) {
  try {
    return LearningGoalRef.fromJson(json);
  } on FormatException catch (e) {
    throw SmartschoolLessonContentError(
      'The Lesfiches module gave a goal of $what in an unknown shape: '
      '${e.message}',
    );
  }
}

/// The whole user ID of a user object (`{"id", ...}`) or of a user ID.
String? _userId(Object? value, String what) => switch (value) {
  null => null,
  final String id => id,
  final Map<String, dynamic> user => _optionalString(user['id']),
  _ => throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)}.',
  ),
};

/// The `text` of an info object (`{"text", "attachments", "weblinks"}`).
String _infoText(Object? value, String what) => switch (value) {
  null => '',
  final String text => text,
  final Map<String, dynamic> info => _optionalString(info['text']) ?? '',
  _ => throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)}.',
  ),
};

String _kind(Object? value) => switch (value) {
  null => 'nothing',
  String() => 'a text',
  num() => 'a number',
  bool() => 'a boolean',
  List() => 'a list',
  Map() => 'an object',
  _ => value.runtimeType.toString(),
};

List<dynamic> _list(Object? value, String what) {
  if (value == null) return const [];
  if (value is List) return value;
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)} instead of a list.',
  );
}

Map<String, dynamic> _map(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)} instead of an object.',
  );
}

String _requiredString(Map<String, dynamic> json, String key, String what) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what without its $key (${_kind(value)}).',
  );
}

String? _optionalString(Object? value) => switch (value) {
  null => null,
  String() => value,
  num() || bool() => '$value',
  _ => throw SmartschoolLessonContentError(
    'The Lesfiches module gave ${_kind(value)} where it gives a text.',
  ),
};

int _requiredInt(Map<String, dynamic> json, String key, String what) {
  final value = json[key];
  final number = switch (value) {
    int() => value,
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  if (number != null) return number;
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what without a numeric $key (${_kind(value)}).',
  );
}

int? _optionalInt(Object? value, String what) => switch (value) {
  null => null,
  int() => value,
  double() when value == value.roundToDouble() => value.toInt(),
  String() when int.tryParse(value.trim()) != null => int.parse(value.trim()),
  _ => throw SmartschoolLessonContentError(
    'The Lesfiches module gave a number of $what as ${_kind(value)}.',
  ),
};

num? _optionalNum(Object? value, String what) => switch (value) {
  null => null,
  num() => value,
  String() when num.tryParse(value.trim()) != null => num.parse(value.trim()),
  _ => throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)}.',
  ),
};
