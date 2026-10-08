/// Models for the Skore gradebook of a teacher (#148, #149): what
/// `SkoreGradebookService` reads as the logged-in teacher at `/SkoreGradebook`
/// ("Puntenboek"): the teacher's own gradebooks of a school year, the
/// periods and pupils of one gradebook, and the evaluations of a period with
/// their publication, grades and feedback.
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

/// The type of an evaluation (Skore's `evaltype`).
enum SkoreEvaluationType {
  /// Grades as points (`evaltype` 1, "Cijfers"), out of
  /// [SkoreEvaluation.max].
  points,

  /// Grades on a scale (`evaltype` 2, "Waarderingen"). Not seen live.
  scale,

  /// Another `evaltype` (kept in [SkoreEvaluation.typeCode]).
  unknown,
}

/// Whether the pupils see an evaluation (#149).
enum SkorePublicationState {
  /// Not published (Skore's `public` `"0"`): only the teachers see it.
  notPublished,

  /// To be published at a time still to come (`public` `"1"` with a
  /// `publicdatetime` after now): the pupils do not see it yet.
  scheduled,

  /// Published (`public` `"1"` with a `publicdatetime` at or before now, or
  /// without one): the pupils see it.
  published,
}

/// The publication of an evaluation: Skore's `public` and `publicdatetime`
/// and the state they give (#149).
///
/// The library never publishes an evaluation, nor changes its publication:
/// teachers do that in Smartschool.
class SkorePublication {
  /// The state when the evaluation was read (by the service's clock);
  /// [stateAt] gives it for another time.
  final SkorePublicationState state;

  /// When the evaluation is or was published, in UTC, from Skore's
  /// `publicdatetime`: a time in Belgium without an offset
  /// (`"2026-10-09T08:00:00"`), read as Belgian time (CET, or CEST in
  /// summer). `null` when Skore gives none (`""`, as for an evaluation that
  /// is not published).
  final DateTime? at;

  /// Skore's `public` as it gave it: `"1"` (published or scheduled) or
  /// `"0"`.
  final String rawPublic;

  /// Skore's `publicdatetime` as it gave it (`"2026-10-09T08:00:00"`, or
  /// `""`).
  final String rawPublicDateTime;

  const SkorePublication({
    required this.state,
    required this.at,
    required this.rawPublic,
    required this.rawPublicDateTime,
  });

  /// Whether Skore's `public` flag is set (`"1"`): the evaluation is
  /// [SkorePublicationState.published] or
  /// [SkorePublicationState.scheduled], whatever the time.
  bool get isPublic => rawPublic == '1';

  /// The state at [now]: [SkorePublicationState.notPublished] unless
  /// [isPublic]; then [SkorePublicationState.scheduled] while [at] is after
  /// [now], and [SkorePublicationState.published] from [at] on, or without
  /// [at].
  SkorePublicationState stateAt(DateTime now) {
    if (!isPublic) return SkorePublicationState.notPublished;
    final at = this.at;
    if (at != null && at.isAfter(now)) return SkorePublicationState.scheduled;
    return SkorePublicationState.published;
  }

  @override
  String toString() =>
      'SkorePublication(${state.name}'
      '${at == null ? '' : ' ${at!.toIso8601String()}'})';
}

/// An evaluation (a column of grades) in a period of a gradebook, with its
/// publication and the grades of the gradebook's pupils
/// (`SkoreGradebookService.getEvaluations`, #149).
class SkoreEvaluation {
  /// The evaluation's ID (Skore's `refID`, e.g. `395742`): the one to know
  /// it by, since its [column] changes.
  final int id;

  /// Skore's `evaluationID` (the same as [id] in all that was seen).
  final int evaluationId;

  /// The gradebook it belongs to (Skore's `ownerID`).
  final int gradebookId;

  /// The period it is in (Skore's `periodID`).
  final int periodId;

  /// The column Skore shows it in (`"A"`, `"B"`, ...). **Not stable**: seen
  /// live, a new evaluation took column `"A"` and moved the existing one to
  /// `"B"`. Use [id].
  final String column;

  /// The title.
  final String title;

  /// The short name, or `null` when it has none (Skore gives `null`, also
  /// for one saved as `""`).
  final String? shortName;

  /// The day of the evaluation (Skore's `date`, `"2026-09-30"`), at
  /// midnight in the local time of this machine: only the day counts.
  final DateTime date;

  /// The highest grade (Skore's `max`, e.g. `100`), or `null` when Skore
  /// gives none.
  final num? max;

  /// The ID of the component (Skore's `componentID`, e.g. `2`; `0` for none,
  /// "geen").
  final int componentId;

  /// The short name of the component (Skore's `component`, e.g. `"DW"`), or
  /// `""` for none.
  final String componentName;

  /// The type: points or a scale.
  final SkoreEvaluationType type;

  /// Skore's `evaltype` as it gave it (`1` points, `2` a scale).
  final int typeCode;

  /// The Skore course ID (Skore's `courseID`).
  final int courseId;

  /// The course name (Skore's `coursename`, without the grade the left
  /// panel adds).
  final String courseName;

  /// Whether it comes from the planner (Skore's `isPlannerEval` 1). Skore's
  /// web client leaves those to the planner.
  final bool isPlannerEvaluation;

  /// Whether, and from when, the pupils see it.
  final SkorePublication publication;

  /// The grades of the gradebook's pupils, as Skore gave them with the
  /// evaluation.
  final SkoreEvaluationResults results;

  const SkoreEvaluation({
    required this.id,
    required this.evaluationId,
    required this.gradebookId,
    required this.periodId,
    required this.column,
    required this.title,
    required this.shortName,
    required this.date,
    required this.max,
    required this.componentId,
    required this.componentName,
    required this.type,
    required this.typeCode,
    required this.courseId,
    required this.courseName,
    required this.isPlannerEvaluation,
    required this.publication,
    required this.results,
  });

  @override
  String toString() =>
      'SkoreEvaluation(id: $id, column: $column, date: '
      '${date.toIso8601String().substring(0, 10)}, max: $max, component: '
      '$componentName, type: ${type.name}, publication: $publication, '
      'grades: ${results.grades.length})';
}

/// The grades of one evaluation for the pupils of the gradebook's class,
/// with the averages Skore shows (#149).
class SkoreEvaluationResults {
  /// The evaluation ([SkoreEvaluation.id]).
  final int evaluationId;

  /// One grade per pupil of the gradebook's class, in Skore's order. Not the
  /// pupils of the other classes of the group, which Skore sends along.
  final List<SkoreGrade> grades;

  /// The class average as Skore gives it (`"81.7"`, with a decimal point),
  /// or `null` when there is none (no grades yet).
  final String? classAverage;

  /// The average of the group of classes (Skore's `gravg_<groupId>`), or
  /// `null` when there is none.
  final String? groupAverage;

  const SkoreEvaluationResults({
    required this.evaluationId,
    this.grades = const [],
    this.classAverage,
    this.groupAverage,
  });

  /// The grade of pupil [pupilId], or `null` when Skore gave no row for
  /// that pupil.
  SkoreGrade? gradeOf(int pupilId) =>
      grades.where((g) => g.pupilId == pupilId).firstOrNull;

  @override
  String toString() =>
      'SkoreEvaluationResults(evaluationId: $evaluationId, grades: '
      '${grades.length}, classAverage: $classAverage)';
}

/// The cell of one pupil in an evaluation: the grade, and whether the pupil
/// has feedback (#149).
class SkoreGrade {
  /// The pupil's Smartschool user ID.
  final int pupilId;

  /// The Skore class ID of the row (the gradebook's class).
  final int classId;

  /// The grade as Skore stores it (the cell's `raw`: `"79"`, `"16.7"`, with
  /// a decimal point, unlike the text Skore shows), or `null` for no grade.
  /// A string: Skore can hold other values than numbers.
  final String? grade;

  /// Whether the pupil has feedback on the evaluation (the cell's marker,
  /// `gbc_message`). `SkoreGradebookService.getFeedback` reads it.
  final bool hasFeedback;

  /// The category type of the cell (the second of its `p`; `0` for an
  /// evaluation).
  final int categoryType;

  /// The evaluation ID of the cell (the third of its `p`): the evaluation's
  /// for the gradebook's pupils.
  final int cellEvaluationId;

  const SkoreGrade({
    required this.pupilId,
    required this.classId,
    required this.grade,
    required this.hasFeedback,
    required this.categoryType,
    required this.cellEvaluationId,
  });

  /// [grade] as a number, or `null` when there is no grade or it is not a
  /// number.
  double? get value => grade == null ? null : double.tryParse(grade!);

  /// Skore's key of the pupil's row: `pupil_<pupilId>_<classId>`.
  String get rowKey => 'pupil_${pupilId}_$classId';

  @override
  String toString() =>
      'SkoreGrade(pupilId: $pupilId, grade: $grade, hasFeedback: '
      '$hasFeedback)';
}

/// A feedback text of a teacher for a pupil on an evaluation, as the
/// feedback panel of Skore's gradebook shows it (#149). A pupil can have
/// several on one evaluation, from one or more teachers.
class SkoreFeedback {
  /// The feedback's ID (a UUID).
  final String id;

  /// The text.
  final String text;

  /// The pupil's Smartschool user ID (the middle part of `4069_9200_0`).
  final int pupilId;

  /// The Smartschool user ID of the teacher who wrote it.
  final int teacherId;

  /// The teacher's name, first name first, or `""` when Skore gives none.
  final String teacherName;

  /// When it was written, in UTC, or `null` when Skore gives no time.
  final DateTime? createdAt;

  /// When it was last changed, in UTC, or `null` when Skore gives no time.
  final DateTime? changedAt;

  /// Its attachments.
  final List<SkoreFeedbackAttachment> attachments;

  /// Whether Skore lets the user change it (`capabilities.can_edit`).
  final bool canEdit;

  const SkoreFeedback({
    required this.id,
    required this.text,
    required this.pupilId,
    required this.teacherId,
    this.teacherName = '',
    this.createdAt,
    this.changedAt,
    this.attachments = const [],
    this.canEdit = false,
  });

  @override
  String toString() =>
      'SkoreFeedback(id: $id, pupilId: $pupilId, teacherId: $teacherId, '
      'changedAt: ${changedAt?.toIso8601String()}, attachments: '
      '${attachments.length}, canEdit: $canEdit)';
}

/// An attachment of a [SkoreFeedback]. Not seen live: the fields are those
/// of the feedback panel's code.
class SkoreFeedbackAttachment {
  /// The attachment's ID, or `""` when Skore gives none.
  final String id;

  /// The file name, or `""`.
  final String name;

  /// The size in bytes, or `null`.
  final int? size;

  /// The attachment as Skore gave it, which a change of the feedback sends
  /// back.
  final Map<String, dynamic> json;

  const SkoreFeedbackAttachment({
    required this.id,
    required this.name,
    this.size,
    this.json = const {},
  });

  @override
  String toString() => 'SkoreFeedbackAttachment(id: $id, name: $name)';
}
