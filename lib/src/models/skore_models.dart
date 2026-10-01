/// Models for Smartschool's Skore module (grading and reports): the classes
/// of its report models, the courses of a class with the teachers assigned to
/// them, the teachers that can be assigned, and the gradebooks of a teacher
/// with the teachers they are shared with.
///
/// Skore is an **internal** Smartschool module, not part of the official
/// (public) API. Its IDs are its own: a [SkoreClass.id] is a Skore class ID
/// (not a Presence `groupID` or an `adminNumber`), and a [SkoreCourse.id] is a
/// Skore course ID. A teacher ID ([SkoreTeacher.id],
/// [SkoreAssignment.teacherId], [SkoreGradebookShares.ownerId]) is the
/// Smartschool user ID, the middle part of the ID that
/// `SmartschoolClient.getCurrentUser()` reads (`4069_146_0` → `146`). A
/// gradebook ID ([SkoreGradebookShares.gradebookId]) is the ID of the
/// assignment that holds the gradebook ([SkoreAssignment.id]).
library;

/// A class in Skore, as listed under a report model:
/// Rapporten > Modellen > (model) > Leden > (group) > (class).
class SkoreClass {
  /// The Skore class ID, the ID [SkoreCourse]s and assignments are kept under
  /// (e.g. `2376`).
  final int id;

  /// The class name (e.g. `"1B1"`).
  final String name;

  /// The ID of the report model the class belongs to (e.g. `178`).
  final int modelId;

  /// The name of the report model (e.g. `"1gr B-str."`).
  final String modelName;

  /// The ID of the group of classes under the model's members ("Leden"), or
  /// `null` when Skore lists the class outside such a group.
  final int? groupId;

  /// The name of that group (e.g. `"1B"`), or `null` when Skore lists the
  /// class outside such a group.
  final String? groupName;

  const SkoreClass({
    required this.id,
    required this.name,
    required this.modelId,
    required this.modelName,
    this.groupId,
    this.groupName,
  });

  @override
  String toString() =>
      'SkoreClass(id: $id, name: $name, modelId: $modelId, '
      'groupName: $groupName)';
}

/// A course of a class in Skore: one row of the class's assignments page
/// ("lesopdrachten"), with the teachers assigned to it.
///
/// Courses are nested: a row can be a group header ([isGroupHeader]) with
/// courses under it, and a course can have sub-courses under it. [depth]
/// gives the nesting; the rows come in Skore's order, so a row's parent is
/// the nearest row above it with a smaller [depth].
///
/// [code] is not unique within a class: a course and its sub-course can carry
/// the same code. Tell them apart by [id] (or [label]).
class SkoreCourse {
  /// The Skore course ID (`courseID`).
  final int id;

  /// The Skore class ID this row belongs to (`classID`).
  final int classId;

  /// The course name (`coursename`, e.g. `"Beeld (1 uur)"`).
  final String name;

  /// The label of the row as Skore shows it, code included (e.g.
  /// `"Beeld (1 uur) (1e lj B) [BEELD]"`).
  final String label;

  /// The course code: the last `[...]` of [label] (e.g. `"BEELD"`), or `null`
  /// when the label ends without one. It can hold spaces (e.g.
  /// `"Digitale vaardigheden"`).
  final String? code;

  /// Whether the row is a group header (`grouponly`): a heading for the
  /// courses under it, which cannot get a teacher.
  final bool isGroupHeader;

  /// The nesting depth of the row: `0` for a top-level row, `1` for a row
  /// under it, and so on (Skore indents each level by 10 pixels).
  final int depth;

  /// The teachers assigned to the course, in Skore's order. Empty when the
  /// course has none (always for a group header).
  final List<SkoreAssignment> assignments;

  const SkoreCourse({
    required this.id,
    required this.classId,
    required this.name,
    required this.label,
    required this.code,
    required this.isGroupHeader,
    required this.depth,
    this.assignments = const [],
  });

  @override
  String toString() =>
      'SkoreCourse(id: $id, code: $code, label: $label, '
      'isGroupHeader: $isGroupHeader, depth: $depth, '
      'assignments: ${assignments.length})';
}

/// A teacher assigned to a course of a class in Skore (an "owner" in Skore's
/// terms; a "lesopdracht" in its interface).
///
/// The assignment, not the teacher, holds the gradebook: giving the course
/// another teacher keeps the assignment's [id].
class SkoreAssignment {
  /// The assignment ID (`ownerID`).
  final int id;

  /// The Smartschool user ID of the teacher (`userID`).
  final int teacherId;

  /// The teacher's name as Skore shows it (`"Last, First"`).
  final String teacherName;

  const SkoreAssignment({
    required this.id,
    required this.teacherId,
    required this.teacherName,
  });

  @override
  String toString() =>
      'SkoreAssignment(id: $id, teacherId: $teacherId, '
      'teacherName: $teacherName)';
}

/// A teacher that Skore lets assign to a course.
class SkoreTeacher {
  /// The Smartschool user ID of the teacher (`userID`).
  final int id;

  /// The teacher's name as Skore shows it (`"Last, First"`).
  final String name;

  const SkoreTeacher({required this.id, required this.name});

  @override
  String toString() => 'SkoreTeacher(id: $id, name: $name)';
}

/// The access a teacher gets to a gradebook shared with them.
enum SkoreShareAccess {
  /// May read the gradebook (Skore's `readers`).
  read,

  /// May read and change the gradebook (Skore's `writers`).
  write,
}

/// A gradebook of a teacher in Skore, with the teachers it is shared with:
/// one entry of Skore's "share gradebooks" manager (Puntenboeken > the share
/// button next to a teacher).
///
/// A teacher is in at most one of [readerIds] and [writerIds], and the owner
/// in neither.
class SkoreGradebookShares {
  /// The gradebook ID: the ID of the assignment that holds the gradebook
  /// ([SkoreAssignment.id], Skore's `ownerID`).
  final int gradebookId;

  /// The Smartschool user ID of the teacher the gradebook belongs to: the
  /// teacher of that assignment.
  final int ownerId;

  /// The name of the class (e.g. `"5WW1"`).
  final String className;

  /// The name of the course (e.g. `"Digitale vaardigheden"`).
  final String courseName;

  /// The icon Skore shows for the course (e.g. `"IconLib:laptop"`, or
  /// `"palette2"`).
  final String icon;

  /// The Smartschool user IDs of the teachers who may read the gradebook, in
  /// Skore's order.
  final List<int> readerIds;

  /// The Smartschool user IDs of the teachers who may read and change the
  /// gradebook, in Skore's order.
  final List<int> writerIds;

  const SkoreGradebookShares({
    required this.gradebookId,
    required this.ownerId,
    required this.className,
    required this.courseName,
    required this.icon,
    this.readerIds = const [],
    this.writerIds = const [],
  });

  /// The access teacher [teacherId] has to the gradebook through a share, or
  /// `null` when it is not shared with them (always for the owner).
  SkoreShareAccess? accessOf(int teacherId) {
    if (writerIds.contains(teacherId)) return SkoreShareAccess.write;
    if (readerIds.contains(teacherId)) return SkoreShareAccess.read;
    return null;
  }

  @override
  String toString() =>
      'SkoreGradebookShares(gradebookId: $gradebookId, ownerId: $ownerId, '
      'className: $className, courseName: $courseName, '
      'readerIds: $readerIds, writerIds: $writerIds)';
}
