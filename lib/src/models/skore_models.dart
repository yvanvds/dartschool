/// Models for Smartschool's Skore module (grading and reports): the classes
/// of its report models, the courses of a class with the teachers assigned to
/// them, and the teachers that can be assigned.
///
/// Skore is an **internal** Smartschool module, not part of the official
/// (public) API. Its IDs are its own: a [SkoreClass.id] is a Skore class ID
/// (not a Presence `groupID` or an `adminNumber`), and a [SkoreCourse.id] is a
/// Skore course ID. A teacher ID ([SkoreTeacher.id],
/// [SkoreAssignment.teacherId]) is the Smartschool user ID, the middle part of
/// the ID that `SmartschoolClient.getCurrentUser()` reads (`4069_146_0` →
/// `146`).
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
