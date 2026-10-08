/// Models for the Skore gradebook of a teacher (#148): what
/// `SkoreGradebookService` reads as the logged-in teacher at `/SkoreGradebook`
/// ("Puntenboek"): the teacher's own gradebooks of a school year, and the
/// periods and pupils of one gradebook.
///
/// This is the teacher's side of Skore, which any teacher reaches with their
/// own login. The admin side (report models, assignments, sharing) is
/// `SkoreService`, with the models of `skore_models.dart`.
///
/// IDs are Skore's own, as in `skore_models.dart`: a gradebook ID
/// ([SkoreGradebook.gradebookId], Skore's `ownerID`) is the ID of the
/// assignment that holds the gradebook (`SkoreAssignment.id`); class, group,
/// model and course IDs are Skore's. A teacher ID and a pupil ID are
/// Smartschool user IDs (the middle part of `4069_146_0`).
library;

/// A school year of Skore (a "werkjaar"), as Skore's gradebook lists them:
/// `["24", "2026-2027"]`.
class SkoreWorkyear {
  /// Skore's ID of the school year (e.g. `24`). Not the calendar year: the
  /// IDs go up by two in Skore's list (`24`, `22`, `20`, ...), with gaps.
  final int id;

  /// The name Skore shows for it (e.g. `"2026-2027"`).
  final String name;

  const SkoreWorkyear({required this.id, required this.name});

  @override
  String toString() => 'SkoreWorkyear(id: $id, name: $name)';
}

/// The logged-in teacher's own gradebooks of one school year, as the left
/// panel of Skore's gradebook lists them, with the school years Skore offers
/// (`SkoreGradebookService.getGradebookYear`).
class SkoreGradebookYear {
  /// The school year of [gradebooks]: the one asked for, or Skore's current
  /// school year when none was asked for.
  final SkoreWorkyear workyear;

  /// The school years Skore offers in its year choice, as it lists them
  /// (newest first in what was seen live). Holds [workyear].
  final List<SkoreWorkyear> workyears;

  /// The teacher's gradebooks of [workyear], one per class and course, in
  /// the order of the left panel (per model, group and class). Empty for a
  /// teacher without gradebooks in that year.
  final List<SkoreGradebook> gradebooks;

  const SkoreGradebookYear({
    required this.workyear,
    this.workyears = const [],
    this.gradebooks = const [],
  });

  @override
  String toString() =>
      'SkoreGradebookYear(workyear: ${workyear.name} (${workyear.id}), '
      'gradebooks: ${gradebooks.length}, workyears: ${workyears.length})';
}

/// A gradebook of the logged-in teacher: the grades of one class for one
/// course in one school year, as the left panel of Skore's gradebook lists
/// it (Skore's `getNavigation`).
///
/// Pass it to `SkoreGradebookService.getGradebook` for its periods and
/// pupils. Every call about the gradebook goes out for its [workyearId].
class SkoreGradebook {
  /// The gradebook ID (Skore's `ownerID`): the ID of the assignment that
  /// holds it, `SkoreAssignment.id` of the admin side (e.g. `32508`).
  final int gradebookId;

  /// The Smartschool user ID of the teacher the gradebook belongs to
  /// (Skore's `userID`). For the teacher's own gradebooks, the logged-in
  /// user (all of them, seen live).
  final int teacherId;

  /// The ID of the report model of the class (e.g. `176`), the first of
  /// [pathIds].
  final int modelId;

  /// The name of the report model (e.g. `"3gr D-D/A"`).
  final String modelName;

  /// The ID of the group of classes (e.g. `472`), the second of [pathIds].
  final int groupId;

  /// The name of the group of classes (e.g. `"6DO"`).
  final String groupName;

  /// The Skore class ID (e.g. `2440`), the last of [pathIds].
  final int classId;

  /// The class name (e.g. `"6EWI"`).
  final String className;

  /// The Skore course ID (e.g. `2264`).
  final int courseId;

  /// The course as the left panel names it, with the grade Skore adds to it
  /// (e.g. `"Informaticawetenschappen (2 uur) (6e j DO)"`). Skore's other
  /// calls leave the grade out: `SkoreGradebookSheet.courseName`.
  final String courseName;

  /// The names of the teachers of the course, as Skore lists them in the
  /// left panel (Skore's `part`, e.g. `["Janssens Jan"]`: last name first,
  /// without a comma).
  final List<String> teacherNames;

  /// The Skore ID of the school year the gradebook is of
  /// ([SkoreWorkyear.id]).
  final int workyearId;

  const SkoreGradebook({
    required this.gradebookId,
    required this.teacherId,
    required this.modelId,
    required this.modelName,
    required this.groupId,
    required this.groupName,
    required this.classId,
    required this.className,
    required this.courseId,
    required this.courseName,
    required this.workyearId,
    this.teacherNames = const [],
  });

  /// Skore's path to the class (its `pathIds`): [modelId], [groupId] and
  /// [classId]. Skore's gradebook calls name the class by it.
  List<int> get pathIds => [modelId, groupId, classId];

  @override
  String toString() =>
      'SkoreGradebook(gradebookId: $gradebookId, class: $className '
      '($classId), course: $courseName ($courseId), pathIds: $pathIds, '
      'workyearId: $workyearId)';
}

/// One gradebook with its periods and pupils
/// (`SkoreGradebookService.getGradebook`).
class SkoreGradebookSheet {
  /// The gradebook, as it was passed to `getGradebook`.
  final SkoreGradebook gradebook;

  /// The course name as the gradebook names it, without the grade the left
  /// panel adds (e.g. `"Informaticawetenschappen (2 uur)"`; Skore's
  /// `ownerMap`).
  final String courseName;

  /// The periods ("Evaluaties | DW1", ...) of the gradebook, in Skore's
  /// order. Skore adds periods during the school year.
  final List<SkoreGradebookPeriod> periods;

  /// The period Skore opens the gradebook on (its `activePeriodE`), or
  /// `null` when the gradebook has no periods. Seen live: the only period of
  /// a new school year, and the last of the five of an earlier one.
  final SkoreGradebookPeriod? activePeriod;

  /// The pupils of the gradebook's class, in the class's order (by class
  /// number). Not the class average, and not the pupils of other classes.
  final List<SkoreGradebookPupil> pupils;

  /// Whether Skore lets the user change the gradebook (`writable` 1 in
  /// Skore's `getGradebookContext`, asked for [activePeriod]). Skore's web
  /// client shows the gradebook read-only otherwise.
  ///
  /// It is about the user's rights in the gradebook, not about a period:
  /// seen live, Skore also answers `writable` 1 for a closed period of an
  /// earlier school year. Whether a period takes grades is
  /// [SkoreGradebookPeriod.isOpen]. `false` when the gradebook has no
  /// periods: then Skore is not asked.
  final bool writable;

  /// Whether Skore answered the gradebook in coordinator mode
  /// (`coordinator` 1 in `getGradebookContext`), in which Skore's web client
  /// shows a gradebook read-only too. Not seen live (always `0` for the own
  /// gradebooks).
  final bool isCoordinator;

  const SkoreGradebookSheet({
    required this.gradebook,
    required this.courseName,
    this.periods = const [],
    this.activePeriod,
    this.pupils = const [],
    this.writable = false,
    this.isCoordinator = false,
  });

  @override
  String toString() =>
      'SkoreGradebookSheet(gradebookId: ${gradebook.gradebookId}, '
      'courseName: $courseName, periods: ${periods.length}, '
      'activePeriod: ${activePeriod?.name}, pupils: ${pupils.length}, '
      'writable: $writable)';
}

/// A period of a gradebook: a tab of Skore's gradebook ("Evaluaties | DW1"),
/// in which the teacher enters grades while it is open.
class SkoreGradebookPeriod {
  /// The period ID (e.g. `1704`).
  final int id;

  /// The short name Skore shows on the tab (e.g. `"DW1"`).
  final String name;

  /// The full name (Skore's `fullname`; the same as [name] in what was seen
  /// live).
  final String fullName;

  /// Whether the period is open (Skore's `open` 1): whether Skore takes
  /// grades in it. Closed periods show a lock in Skore.
  final bool isOpen;

  /// When the period closes (or closed), from Skore's `timestamp`
  /// (`"2026-12-18T20:00:00+0100"`), in UTC; `null` when Skore gives none.
  final DateTime? closesAt;

  /// Skore's description of the period, as HTML (e.g. "Open van 2026-09-18
  /// 15:30 tot en met 2026-12-18 20:00" and the school's note, or
  /// "Gesloten!" once closed).
  final String info;

  /// Skore's `categoryMode` of the period: `1` for evaluations (the only
  /// one seen live, and the one the gradebook service is about).
  final int categoryMode;

  const SkoreGradebookPeriod({
    required this.id,
    required this.name,
    required this.fullName,
    required this.isOpen,
    required this.closesAt,
    this.info = '',
    this.categoryMode = 1,
  });

  @override
  String toString() =>
      'SkoreGradebookPeriod(id: $id, name: $name, isOpen: $isOpen, '
      'closesAt: ${closesAt?.toIso8601String()})';
}

/// A pupil of a gradebook's class: a row of Skore's gradebook.
class SkoreGradebookPupil {
  /// The pupil's Smartschool user ID (e.g. `1201` of the row
  /// `pupil_1201_2440`).
  final int id;

  /// The Skore class ID of the row (the gradebook's class).
  final int classId;

  /// The pupil's class number (`1` of `"1.  Janssens, Jan"`), or `null` when
  /// Skore shows none (`"- Janssens, Jan"`, seen for every pupil of an
  /// earlier school year).
  final int? number;

  /// The name as the gradebook lists it: last name first
  /// (e.g. `"Janssens, Jan"`).
  final String name;

  /// The name first name first (e.g. `"Jan Janssens"`), as Skore gives it
  /// with the row (its `alternate`, in base64). [name] when the row has
  /// none.
  final String displayName;

  /// Whether the pupil is an active member of the class. `false` for a row
  /// Skore greys out (class `gbc_hidden`): Skore's web client takes those
  /// for inactive and gives them no feedback panel. Seen live in the list of
  /// an earlier school year; who exactly is greyed out was not checked.
  final bool isActive;

  const SkoreGradebookPupil({
    required this.id,
    required this.classId,
    required this.number,
    required this.name,
    required this.displayName,
    this.isActive = true,
  });

  /// Skore's key of the pupil's row in the gradebook:
  /// `pupil_<id>_<classId>`.
  String get rowKey => 'pupil_${id}_$classId';

  @override
  String toString() =>
      'SkoreGradebookPupil(id: $id, classId: $classId, number: $number, '
      'name: $name, isActive: $isActive)';
}
