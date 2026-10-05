/// Models for Smartschool's **Lesfiches** module (lesson content,
/// `/lesson-content`): the lesfiches a teacher keeps there, lessons and
/// assignments, with their courses and labels; the detail of one lesfiche,
/// with its weblinks and attachments and when pupils see them; and what a
/// new lesfiche, weblink or attachment is made from (#129).
///
/// The IDs are strings: a lesfiche, a course or a label has a UUID, with the
/// platform ID in a field of its own (`platformId`); a label's ID starts with
/// the platform ID (a school label, `4069_<uuid>`) or the whole user ID of
/// its owner (a label of the teacher's own, `4069_146_0_<uuid>`).
library;

import '../exceptions.dart';
import 'planner_models.dart';

/// The kind of a lesfiche (`type`): a lesson or an assignment.
enum LessonContentType {
  /// A lesson (`lessons`): planned into a lesson hour as a lesson
  /// (`PlannerService.planLessonContent`).
  lesson('lessons'),

  /// An assignment (`assignments`), with a
  /// [LessonContentItem.assignmentType]: planned as an assignment, which the
  /// library does not do.
  assignment('assignments'),

  /// A kind this library does not know. [LessonContentItem.typeName] holds
  /// the module's name for it.
  other(null);

  const LessonContentType(this.wireName);

  /// The module's name of the kind (`lessons`), or `null` for [other].
  final String? wireName;

  /// The kind the module calls [wireName], or [other] when this library
  /// does not know it.
  static LessonContentType fromWire(String wireName) {
    for (final type in values) {
      if (type.wireName == wireName) return type;
    }
    return other;
  }
}

/// A course a lesfiche is for: its ID and platform, as the Lesfiches list
/// gives them, and its [name], which the list does not give (#101).
///
/// `LessonContentService.getItems` names the course after the course with the
/// same ID in the school's course list (`LessonContentService.getCourses`),
/// as the Lesfiches web client does.
class LessonContentCourse {
  /// The course ID (a UUID): the [PlannerCourse.id] of the same course, and
  /// the ID of the course in the school's course list.
  final String id;

  /// The platform (school) the course belongs to.
  final int platformId;

  /// The name of the course (`informatica`), as the school's course list
  /// gives it (the [PlannerCourse.name] of the course with this [id]).
  ///
  /// `null` when it is not known: the lesfiches were read without the course
  /// list (`LessonContentService.getItems(withCourseNames: false)`, or
  /// `LessonContentService.parseItems` without `courses`), or the course list
  /// has no course with this ID, or one without a name, or `getItems` could
  /// not use the course list (the `items` of a
  /// `SmartschoolLessonContentCourseListError`, #118).
  final String? name;

  const LessonContentCourse({
    required this.id,
    required this.platformId,
    this.name,
  });

  /// Parses a course as the Lesfiches list gives it (`{platformId, id}`),
  /// named after its ID in [names] (course names by course ID); `null` for a
  /// course not in it.
  factory LessonContentCourse.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> names = const {},
  }) {
    final id = _requiredString(json, 'id', 'a course');
    return LessonContentCourse(
      id: id,
      platformId: _requiredInt(json, 'platformId', 'a course'),
      name: names[id],
    );
  }

  @override
  String toString() => name == null
      ? 'LessonContentCourse($id)'
      : 'LessonContentCourse($id, $name)';
}

/// A label of a lesfiche: a school label (such as `JAAR 6` or `TRIMESTER 1`)
/// or one of the teacher's own.
class LessonContentLabel {
  /// The label ID (`id`): the platform ID and a UUID for a school label, the
  /// owner's whole user ID and a UUID for an own label.
  final String id;

  /// The text of the label (`JAAR 6`).
  final String text;

  /// The colour the module shows the label in (`aqua`, `yellow`, `steel`),
  /// or `null` when it gave none.
  final String? color;

  /// The kind of label (`type`): `platform` for a label of the school, `user`
  /// for one of the teacher's own.
  final String type;

  /// Whether the label is visible.
  final bool isVisible;

  const LessonContentLabel({
    required this.id,
    required this.text,
    this.color,
    this.type = '',
    this.isVisible = true,
  });

  factory LessonContentLabel.fromJson(Map<String, dynamic> json) =>
      LessonContentLabel(
        id: _requiredString(json, 'id', 'a label'),
        text: (_optionalString(json['text']) ?? '').trim(),
        color: _optionalString(json['color']),
        type: _optionalString(json['type']) ?? '',
        isVisible: json['isVisible'] == null || _bool(json['isVisible']),
      );

  /// Whether this is a label of the school (`type` `platform`).
  bool get isSchoolLabel => type == 'platform';

  @override
  String toString() => 'LessonContentLabel($text)';
}

/// A lesfiche of the Lesfiches module (lesson content): a lesson or an
/// assignment a teacher keeps there to plan into the planner.
///
/// Returned by `LessonContentService.getItems`; its detail, with the
/// weblinks and attachments themselves and the private info, is a
/// [LessonContentDetail] (`LessonContentService.getDetail`, #129), which is
/// a lesfiche too. A lesson lesfiche ([LessonContentType.lesson]) is planned
/// into an empty lesson hour of the own planner with
/// `PlannerService.planLessonContent`.
class LessonContentItem {
  /// The lesfiche ID (a UUID): the `sourceId` the planner plans it by.
  final String id;

  /// The platform (school) of the lesfiche.
  final int platformId;

  /// Whether it is a lesson or an assignment; [LessonContentType.other] for
  /// a kind this library does not know (see [typeName]).
  final LessonContentType type;

  /// The module's name of the kind (`lessons`, `assignments`), also for a
  /// kind this library does not know.
  final String typeName;

  /// The title of the lesfiche; a lesson planned from it gets this name.
  final String name;

  /// The icon of the lesfiche (`document_observation` for the lessons seen,
  /// `flags_red_yellow` for the assignments), or `null`.
  final String? icon;

  /// The info that pupils see (HTML; `""` when empty).
  final String publicInfo;

  /// Whether the lesfiche is visible in the module. A lesfiche that is not
  /// was still planned (seen live, #88).
  final bool isVisible;

  /// The whole user ID of the owner (`owner`, `{platformId}_{userId}_
  /// {coaccount}`, such as `4069_146_0`), or `null` when the module gave
  /// none.
  final String? ownerId;

  /// When the lesfiche was last changed (`dateLastChanged`), or `null` when
  /// the module gave no such date.
  ///
  /// The module gives its dates without an offset from UTC
  /// (`2025-09-01 19:51:25`, unlike the planner): the school's local time,
  /// read here as the local time of this machine.
  final DateTime? dateLastChanged;

  /// When the state of the lesfiche last changed (`dateStateChanged`), as
  /// [dateLastChanged] gives it; `null` when the module gave no such date.
  final DateTime? dateStateChanged;

  /// The courses the lesfiche is for, each with its name when it is known
  /// ([LessonContentCourse.name]).
  final List<LessonContentCourse> courses;

  /// The labels of the lesfiche, school labels and own labels.
  final List<LessonContentLabel> labels;

  /// The type of an assignment lesfiche (such as `Kleine Taak`, `KT`); `null`
  /// for a lesson.
  final PlannerAssignmentType? assignmentType;

  /// How many attachments the lesfiche has (`attachments`).
  final int attachmentCount;

  /// How many weblinks the lesfiche has (`weblinks`).
  final int weblinkCount;

  /// How many weblinks of partners (publishers) the lesfiche has
  /// (`partnerWeblinks`).
  final int partnerWeblinkCount;

  /// How many deeplinks the lesfiche has (`deeplinks`).
  final int deeplinkCount;

  /// What the authenticated user may do with the lesfiche: every
  /// `canUser...` flag by its name (`canUserSeeDetails`, `canUserEdit`,
  /// `canUserTrash`, ...). A flag the module left out is not in it.
  final Map<String, bool> capabilities;

  /// The lesfiche as the module gave it (decoded JSON, read-only), for the
  /// fields this model does not cover (the goals, for instance; the
  /// weblinks and attachments themselves are in a [LessonContentDetail]).
  final Map<String, dynamic> raw;

  const LessonContentItem({
    required this.id,
    required this.platformId,
    required this.type,
    required this.typeName,
    required this.name,
    this.icon,
    this.publicInfo = '',
    this.isVisible = true,
    this.ownerId,
    this.dateLastChanged,
    this.dateStateChanged,
    this.courses = const [],
    this.labels = const [],
    this.assignmentType,
    this.attachmentCount = 0,
    this.weblinkCount = 0,
    this.partnerWeblinkCount = 0,
    this.deeplinkCount = 0,
    this.capabilities = const {},
    this.raw = const {},
  });

  /// Parses a lesfiche as the Lesfiches list gives it, with its courses named
  /// after [courseNames] (course names by course ID; a course not in it has
  /// no [LessonContentCourse.name]). Throws a [SmartschoolLessonContentError]
  /// when it lacks its `id`, `platformId` or `type`, or holds a part in an
  /// unknown shape.
  factory LessonContentItem.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> courseNames = const {},
  }) {
    final id = _requiredString(json, 'id', 'a lesfiche');
    final what = 'lesfiche $id';
    final typeName = _requiredString(json, 'type', what);
    final assignmentType = _optionalMap(
      json['assignmentType'],
      'the assignment type of $what',
    );
    final capabilities =
        _optionalMap(json['capabilities'], 'the capabilities of $what') ??
        const <String, dynamic>{};
    return LessonContentItem(
      id: id,
      platformId: _requiredInt(json, 'platformId', what),
      type: LessonContentType.fromWire(typeName),
      typeName: typeName,
      name: (_optionalString(json['name']) ?? '').trim(),
      icon: _optionalString(json['icon']),
      publicInfo: _optionalString(json['publicInfo']) ?? '',
      isVisible: json['isVisible'] == null || _bool(json['isVisible']),
      ownerId: _optionalString(json['owner']),
      dateLastChanged: _optionalDateTime(
        json['dateLastChanged'],
        'the last change of $what',
      ),
      dateStateChanged: _optionalDateTime(
        json['dateStateChanged'],
        'the state change of $what',
      ),
      courses: _objects(
        json['courses'],
        'the courses of $what',
        (course) => LessonContentCourse.fromJson(course, names: courseNames),
      ),
      labels: _objects(
        json['labels'],
        'the labels of $what',
        LessonContentLabel.fromJson,
      ),
      assignmentType: assignmentType == null
          ? null
          : _assignmentType(assignmentType, what),
      attachmentCount: _list(
        json['attachments'],
        'the attachments of $what',
      ).length,
      weblinkCount: _list(json['weblinks'], 'the weblinks of $what').length,
      partnerWeblinkCount: _list(
        json['partnerWeblinks'],
        'the partner weblinks of $what',
      ).length,
      deeplinkCount: _list(json['deeplinks'], 'the deeplinks of $what').length,
      capabilities: Map.unmodifiable({
        for (final MapEntry(:key, :value) in capabilities.entries)
          if (value is bool) key: value,
      }),
      raw: Map.unmodifiable(json),
    );
  }

  /// Capability [flag] (such as `canUserEdit`); `false` when the module left
  /// it out.
  bool can(String flag) => capabilities[flag] ?? false;

  @override
  String toString() => 'LessonContentItem($typeName $id "$name")';
}

/// When pupils see a weblink or an attachment of a lesfiche: the `option` of
/// its `visibility` (#129), the options the web client offers for it.
enum LessonContentVisibilityOption {
  /// `always`: always (the default, and what an attachment added to a
  /// lesfiche gets).
  always('always'),

  /// `never`: never; only the teacher sees it.
  never('never'),

  /// `at-start`: from the start of the lesson it is planned in.
  atStart('at-start'),

  /// `at-end`: from the end of the lesson it is planned in.
  atEnd('at-end'),

  /// `days-after-end`: from a number of days after the end of the lesson
  /// ([LessonContentVisibility.daysAfterEnd]).
  daysAfterEnd('days-after-end'),

  /// An option this library does not know.
  /// [LessonContentVisibility.optionName] holds the module's name for it.
  other(null);

  const LessonContentVisibilityOption(this.wireName);

  /// The module's name of the option (`at-start`), or `null` for [other].
  final String? wireName;

  /// The option the module calls [wireName], or [other] when this library
  /// does not know it.
  static LessonContentVisibilityOption fromWire(String wireName) {
    for (final option in values) {
      if (option.wireName == wireName) return option;
    }
    return other;
  }
}

/// When pupils see a weblink or an attachment of a lesfiche: its
/// `visibility`, `{"option", "daysAfterEnd"}` (#129).
///
/// Set it with one of the constants ([always], [never], [atStart], [atEnd])
/// or [LessonContentVisibility.afterEnd] for a number of days after the end
/// of the lesson; the module's default, in the web client too, is [always].
/// The times are those of the lesson the lesfiche is planned in: the web
/// client's options (its module `73851`), whose wording the library does not
/// have; what pupils see of a lesfiche that is planned was not checked live.
class LessonContentVisibility {
  const LessonContentVisibility._(
    this.option,
    this.optionName, [
    this.daysAfterEnd,
  ]);

  /// Always (`always`): the default.
  static const always = LessonContentVisibility._(
    LessonContentVisibilityOption.always,
    'always',
  );

  /// Never (`never`): only the teacher sees it.
  static const never = LessonContentVisibility._(
    LessonContentVisibilityOption.never,
    'never',
  );

  /// From the start of the lesson (`at-start`).
  static const atStart = LessonContentVisibility._(
    LessonContentVisibilityOption.atStart,
    'at-start',
  );

  /// From the end of the lesson (`at-end`).
  static const atEnd = LessonContentVisibility._(
    LessonContentVisibilityOption.atEnd,
    'at-end',
  );

  /// The most days after the end of the lesson that the web client offers
  /// for [LessonContentVisibility.afterEnd]: 1 to 14.
  static const maxDaysAfterEnd = 14;

  /// From [days] days after the end of the lesson (`days-after-end`), one of
  /// the 1 to [maxDaysAfterEnd] days the web client offers. Seen live
  /// (2026-10-05): a weblink made with 3 and with 14 days kept them.
  ///
  /// Throws an [ArgumentError] for another number of days.
  factory LessonContentVisibility.afterEnd(int days) {
    if (days < 1 || days > maxDaysAfterEnd) {
      throw ArgumentError.value(
        days,
        'days',
        'must be from 1 to $maxDaysAfterEnd: the days the web client offers',
      );
    }
    return LessonContentVisibility._(
      LessonContentVisibilityOption.daysAfterEnd,
      'days-after-end',
      days,
    );
  }

  /// Parses a `visibility` as the module gives it (`{"option": "at-end",
  /// "daysAfterEnd": null}`). An option this library does not know is
  /// [LessonContentVisibilityOption.other], with its name in [optionName];
  /// the days are taken as given. Throws a [SmartschoolLessonContentError]
  /// for a visibility without its `option`, or with days that are not a
  /// whole number.
  factory LessonContentVisibility.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'option', 'a visibility');
    final days = json['daysAfterEnd'];
    if (days != null && days is! int) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module gave a visibility with daysAfterEnd as '
        '${_kind(days)} instead of a whole number.',
      );
    }
    return LessonContentVisibility._(
      LessonContentVisibilityOption.fromWire(name),
      name,
      days as int?,
    );
  }

  /// The option.
  final LessonContentVisibilityOption option;

  /// The module's name of the option (`at-start`), also for an option this
  /// library does not know.
  final String optionName;

  /// The days after the end of the lesson for
  /// [LessonContentVisibilityOption.daysAfterEnd]; `null` for the other
  /// options (the module sends `null` then).
  final int? daysAfterEnd;

  /// The visibility as the module takes it: `{"option", "daysAfterEnd"}`.
  Map<String, Object?> toJson() => {
    'option': optionName,
    'daysAfterEnd': daysAfterEnd,
  };

  @override
  bool operator ==(Object other) =>
      other is LessonContentVisibility &&
      other.optionName == optionName &&
      other.daysAfterEnd == daysAfterEnd;

  @override
  int get hashCode => Object.hash(optionName, daysAfterEnd);

  @override
  String toString() => daysAfterEnd == null
      ? 'LessonContentVisibility($optionName)'
      : 'LessonContentVisibility($optionName, $daysAfterEnd)';
}

/// A weblink of a lesfiche, as its detail gives it (#129).
class LessonContentWeblink {
  /// The weblink ID (a UUID), which changes and removes it.
  final String id;

  /// The name the weblink shows.
  final String name;

  /// The address it opens, as Smartschool stored it.
  final String url;

  /// Its icon (`earth`, the web client's default).
  final String icon;

  /// When pupils see it.
  final LessonContentVisibility visibility;

  /// The weblink as the module gave it (decoded JSON, read-only).
  final Map<String, dynamic> raw;

  const LessonContentWeblink({
    required this.id,
    required this.name,
    required this.url,
    this.icon = '',
    this.visibility = LessonContentVisibility.always,
    this.raw = const {},
  });

  /// Parses a weblink as the module gives it (`{id, name, url, icon,
  /// visibility}`); without a `visibility`, it is
  /// [LessonContentVisibility.always]. Throws a
  /// [SmartschoolLessonContentError] for one without its `id`.
  factory LessonContentWeblink.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json, 'id', 'a weblink');
    final visibility = _optionalMap(
      json['visibility'],
      'the visibility of weblink $id',
    );
    return LessonContentWeblink(
      id: id,
      name: _optionalString(json['name']) ?? '',
      url: _optionalString(json['url']) ?? '',
      icon: _optionalString(json['icon']) ?? '',
      visibility: visibility == null
          ? LessonContentVisibility.always
          : LessonContentVisibility.fromJson(visibility),
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'LessonContentWeblink($id "$name" $url)';
}

/// An attachment (a file) of a lesfiche, as its detail gives it (#129).
///
/// Download it with `LessonContentService.downloadAttachment`.
class LessonContentAttachment {
  /// The attachment ID (a UUID), which downloads, changes and removes it.
  final String id;

  /// The name of the file. Two attachments of a lesfiche can have the same
  /// name: the module keeps both (seen live, 2026-10-05).
  final String fileName;

  /// The size of the file in bytes, or `null` when the module gave none.
  final int? fileSize;

  /// The type of the file (`text/plain`), or `null` when the module gave
  /// none.
  final String? mimeType;

  /// When pupils see it.
  final LessonContentVisibility visibility;

  /// The attachment as the module gave it (decoded JSON, read-only).
  final Map<String, dynamic> raw;

  const LessonContentAttachment({
    required this.id,
    required this.fileName,
    this.fileSize,
    this.mimeType,
    this.visibility = LessonContentVisibility.always,
    this.raw = const {},
  });

  /// Parses an attachment as the module gives it (`{id, fileName, fileSize,
  /// mimeType, visibility}`); without a `visibility`, it is
  /// [LessonContentVisibility.always]. Throws a
  /// [SmartschoolLessonContentError] for one without its `id`.
  factory LessonContentAttachment.fromJson(Map<String, dynamic> json) {
    final id = _requiredString(json, 'id', 'an attachment');
    final visibility = _optionalMap(
      json['visibility'],
      'the visibility of attachment $id',
    );
    final size = json['fileSize'];
    return LessonContentAttachment(
      id: id,
      fileName: _optionalString(json['fileName']) ?? '',
      fileSize: size is int ? size : null,
      mimeType: _optionalString(json['mimeType']),
      visibility: visibility == null
          ? LessonContentVisibility.always
          : LessonContentVisibility.fromJson(visibility),
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'LessonContentAttachment($id "$fileName")';
}

/// The detail of one lesfiche (#129): the lesfiche as the list gives it
/// ([LessonContentItem]), with its private info, and its weblinks and
/// attachments themselves rather than their numbers.
///
/// Returned by `LessonContentService.getDetail`, `getDetailById`, the
/// creates (`createLesson`, `createAssignment`) and the edits of a lesfiche,
/// which Smartschool answers with the whole lesfiche. The module's detail
/// (`GET /lesson-content/api/v1/{lessons|assignments}/{id}`) has no dates:
/// [dateLastChanged] and [dateStateChanged] are `null`.
class LessonContentDetail extends LessonContentItem {
  /// The info that only the teacher sees (HTML; `""` when empty). The
  /// module also gives it as `info`.
  final String privateInfo;

  /// The weblinks of the lesfiche, in the module's order.
  final List<LessonContentWeblink> weblinks;

  /// The attachments of the lesfiche, in the module's order (seen live: by
  /// file name).
  final List<LessonContentAttachment> attachments;

  LessonContentDetail({
    required super.id,
    required super.platformId,
    required super.type,
    required super.typeName,
    required super.name,
    super.icon,
    super.publicInfo,
    this.privateInfo = '',
    super.isVisible,
    super.ownerId,
    super.dateLastChanged,
    super.dateStateChanged,
    super.courses,
    super.labels,
    super.assignmentType,
    this.weblinks = const [],
    this.attachments = const [],
    super.partnerWeblinkCount,
    super.deeplinkCount,
    super.capabilities,
    super.raw,
  }) : super(
         attachmentCount: attachments.length,
         weblinkCount: weblinks.length,
       );

  /// Parses the detail of a lesfiche as the module gives it, with its
  /// courses named after [courseNames] (course names by course ID; a course
  /// not in it has no [LessonContentCourse.name]). Throws a
  /// [SmartschoolLessonContentError] when it lacks its `id`, `platformId` or
  /// `type`, or holds a part in an unknown shape (such as a weblink or an
  /// attachment without its `id`).
  factory LessonContentDetail.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> courseNames = const {},
  }) {
    final item = LessonContentItem.fromJson(json, courseNames: courseNames);
    final what = 'lesfiche ${item.id}';
    return LessonContentDetail(
      id: item.id,
      platformId: item.platformId,
      type: item.type,
      typeName: item.typeName,
      name: item.name,
      icon: item.icon,
      publicInfo: item.publicInfo,
      privateInfo: _optionalString(json['privateInfo']) ?? '',
      isVisible: item.isVisible,
      ownerId: item.ownerId,
      dateLastChanged: item.dateLastChanged,
      dateStateChanged: item.dateStateChanged,
      courses: item.courses,
      labels: item.labels,
      assignmentType: item.assignmentType,
      weblinks: _objects(
        json['weblinks'],
        'the weblinks of $what',
        LessonContentWeblink.fromJson,
      ),
      attachments: _objects(
        json['attachments'],
        'the attachments of $what',
        LessonContentAttachment.fromJson,
      ),
      partnerWeblinkCount: item.partnerWeblinkCount,
      deeplinkCount: item.deeplinkCount,
      capabilities: item.capabilities,
      raw: item.raw,
    );
  }

  @override
  String toString() => 'LessonContentDetail($typeName $id "$name")';
}

/// A weblink to add to a lesfiche, or the new values of one (#129): for
/// `LessonContentService.createLesson`, `createAssignment`, `addWeblink` and
/// `changeWeblink`.
class NewLessonContentWeblink {
  /// The name it shows; sent without white space around it, and must not be
  /// empty.
  final String name;

  /// The address it opens, sent as the web client sends it
  /// (`LessonContentService.normalizeWeblinkUrl`: `example.com/page` becomes
  /// `http://example.com/page`).
  final String url;

  /// Its icon, from Smartschool's icon set; `earth` (a globe) by default, as
  /// in the web client.
  final String icon;

  /// When pupils see it; [LessonContentVisibility.always] by default.
  final LessonContentVisibility visibility;

  const NewLessonContentWeblink({
    required this.name,
    required this.url,
    this.icon = 'earth',
    this.visibility = LessonContentVisibility.always,
  });

  @override
  String toString() => 'NewLessonContentWeblink("$name" $url)';
}

/// A file to attach to a new lesfiche, or to add to one (#129): for
/// `LessonContentService.createLesson`, `createAssignment` and
/// `addAttachments`.
///
/// The file is uploaded under the last segment of [path] as its name, which
/// must be one Smartschool allows (none of `/ : * ? " \ < > |`, no dot at its
/// start or end).
class NewLessonContentAttachment {
  /// The path of the local file.
  final String path;

  /// When pupils see it; [LessonContentVisibility.always] by default.
  final LessonContentVisibility visibility;

  const NewLessonContentAttachment(
    this.path, {
    this.visibility = LessonContentVisibility.always,
  });

  @override
  String toString() => 'NewLessonContentAttachment($path)';
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

/// [json] as a [PlannerAssignmentType]: the same object as the planner's.
PlannerAssignmentType _assignmentType(Map<String, dynamic> json, String what) {
  try {
    return PlannerAssignmentType.fromJson(json);
  } on SmartschoolPlannerError catch (e) {
    throw SmartschoolLessonContentError(
      'The Lesfiches module gave the assignment type of $what in an unknown '
      'shape: ${e.message}',
    );
  }
}

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
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)} instead of an object.',
  );
}

Map<String, dynamic>? _optionalMap(Object? value, String what) =>
    value == null ? null : _map(value, what);

List<dynamic> _list(Object? value, String what) {
  if (value == null) return const [];
  if (value is List) return value;
  throw SmartschoolLessonContentError(
    'The Lesfiches module gave $what as ${_kind(value)} instead of a list.',
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

bool _bool(Object? value) => value == true || value == 1 || value == 'true';

/// The date of [value] (`2025-09-01 19:51:25`, without an offset: read as
/// local time; with an offset, moved to local time), or `null` for none.
DateTime? _optionalDateTime(Object? value, String what) {
  if (value == null || value is String && value.trim().isEmpty) return null;
  final parsed = value is String ? DateTime.tryParse(value.trim()) : null;
  if (parsed == null) {
    throw SmartschoolLessonContentError(
      'The Lesfiches module gave $what as "$value", which is not a date and '
      'time.',
    );
  }
  return parsed.toLocal();
}
