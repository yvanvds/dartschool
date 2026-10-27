/// Models for the Skore gradebook of a teacher (#148, #149, #150): what
/// `SkoreGradebookService` reads as the logged-in teacher at `/SkoreGradebook`
/// ("Puntenboek"): the teacher's own gradebooks of a school year and those
/// colleagues shared with them (#191), the periods and pupils of one
/// gradebook, and the evaluations of a period with their publication, grades
/// and feedback, and the components a new evaluation can count for; and the
/// report periods of a gradebook, with each pupil's results so far and the
/// course comment that goes on the report (#195); and the scale of the
/// evaluations on a scale (#193).
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

import '../exceptions.dart' show SmartschoolSkoreEvaluationUnreadableError;

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
/// (`SkoreGradebookService.getGradebookYear`), and, when asked for, the
/// gradebooks colleagues shared with the teacher (#191).
class SkoreGradebookYear {
  /// The school year of [gradebooks]: the one asked for, or Skore's current
  /// school year when none was asked for.
  final SkoreWorkyear workyear;

  /// The school years Skore offers in its year choice, as it lists them
  /// (newest first in what was seen live). Holds [workyear].
  final List<SkoreWorkyear> workyears;

  /// The teacher's gradebooks of [workyear], one per class and course, in
  /// the order of the left panel (per model, group and class). Empty for a
  /// teacher without gradebooks in that year. Each with
  /// [SkoreGradebookAccess.own].
  final List<SkoreGradebook> gradebooks;

  /// The gradebooks of [workyear] that colleagues shared with the teacher
  /// ("Gedeeld" in Skore's left panel), to read or to write
  /// ([SkoreGradebook.access]), in Skore's order, each once (#191).
  ///
  /// Only read when asked for (`getGradebookYear(includeShared: true)`, or
  /// `getSharedGradebooks`): empty otherwise, and for a teacher with whom no
  /// gradebook is shared.
  final List<SkoreGradebook> sharedGradebooks;

  const SkoreGradebookYear({
    required this.workyear,
    this.workyears = const [],
    this.gradebooks = const [],
    this.sharedGradebooks = const [],
  });

  @override
  String toString() =>
      'SkoreGradebookYear(workyear: ${workyear.name} (${workyear.id}), '
      'gradebooks: ${gradebooks.length}, shared: ${sharedGradebooks.length}, '
      'workyears: ${workyears.length})';
}

/// Whose gradebook a [SkoreGradebook] is to the logged-in user, and what
/// Skore lets them do in it (#191).
enum SkoreGradebookAccess {
  /// One of the user's own gradebooks: they are its teacher (the left panel
  /// of Skore's gradebook, `getNavigation`).
  own,

  /// A colleague's gradebook, shared with the user **to read only**
  /// (`writable` 0 in Skore's list of shared gradebooks; Skore's web client
  /// shows it as "readable"). The writes of `SkoreGradebookService` refuse
  /// it before anything is sent (`SmartschoolSkoreGradebookReadOnlyError`).
  /// Not seen live: every gradebook shared with the developer's account was
  /// shared to write (2026-10-27).
  read,

  /// A colleague's gradebook, shared with the user to read and to write
  /// (`writable` 1), as an admin shares it with `SkoreService.shareGradebook`
  /// (#74). Grades and feedback can be saved in it; an evaluation is not
  /// created in it (`createEvaluation` keeps to the own gradebooks).
  write,
}

/// A gradebook the logged-in teacher can open: the grades of one class for
/// one course in one school year. One of their own, as the left panel of
/// Skore's gradebook lists it (Skore's `getNavigation`), or one a colleague
/// shared with them, as its tab "Gedeeld" lists it (Skore's
/// `accessableList`, #191): [access] tells which.
///
/// Pass it to `SkoreGradebookService.getGradebook` for its periods and
/// pupils. Every call about the gradebook goes out for its [workyearId]; one
/// about a shared gradebook goes out as Skore's web client opens it, in the
/// name of its teacher ([teacherId]) and restricted to it (#191).
class SkoreGradebook {
  /// The gradebook ID (Skore's `ownerID`): the ID of the assignment that
  /// holds it, `SkoreAssignment.id` of the admin side (e.g. `32508`).
  final int gradebookId;

  /// The Smartschool user ID of the teacher the gradebook belongs to
  /// (Skore's `userID`). For the teacher's own gradebooks, the logged-in
  /// user (all of them, seen live). For a gradebook shared with the user,
  /// the colleague it belongs to, who shared it ([ownerName]; seen live,
  /// #191).
  final int teacherId;

  /// The ID of the report model of the class (e.g. `176`), the first of
  /// [pathIds].
  final int modelId;

  /// The name of the report model (e.g. `"3gr D-D/A"`). `""` for a shared
  /// gradebook: Skore's list of shared gradebooks does not name it.
  final String modelName;

  /// The ID of the group of classes (e.g. `472`), the second of [pathIds].
  final int groupId;

  /// The name of the group of classes (e.g. `"6DO"`). `""` for a shared
  /// gradebook: Skore's list of shared gradebooks does not name it.
  final String groupName;

  /// The Skore class ID (e.g. `2440`), the last of [pathIds].
  final int classId;

  /// The class name (e.g. `"6EWI"`). For a shared gradebook, the part
  /// before the first `/` of the label Skore's list gives it
  /// (`classcourse`, `"6EWI/Digitale vaardigheden"`).
  final String className;

  /// The Skore course ID (e.g. `2264`).
  final int courseId;

  /// The course as the left panel names it, with the grade Skore adds to it
  /// (e.g. `"Informaticawetenschappen (2 uur) (6e j DO)"`). Skore's other
  /// calls leave the grade out: `SkoreGradebookSheet.courseName`. For a
  /// shared gradebook, the part after the first `/` of its label in Skore's
  /// list (`"Digitale vaardigheden"`).
  final String courseName;

  /// The names of the teachers of the course, as Skore lists them in the
  /// left panel (Skore's `part`, e.g. `["Janssens Jan"]`: last name first,
  /// without a comma). Empty for a shared gradebook: [ownerName] names its
  /// teacher.
  final List<String> teacherNames;

  /// The Skore ID of the school year the gradebook is of
  /// ([SkoreWorkyear.id]).
  final int workyearId;

  /// Whose gradebook it is to the user, and what Skore lets them do in it
  /// (#191): [SkoreGradebookAccess.own] for one of their own gradebooks,
  /// [SkoreGradebookAccess.read] or [SkoreGradebookAccess.write] for one a
  /// colleague shared with them. [SkoreGradebookAccess.own] by default.
  final SkoreGradebookAccess access;

  /// For a gradebook shared with the user, the name of its teacher, who
  /// shared it, as Skore's list of shared gradebooks gives it (`username`,
  /// first name first, e.g. `"Jan Janssens"`). `""` for the user's own.
  final String ownerName;

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
    this.access = SkoreGradebookAccess.own,
    this.ownerName = '',
  });

  /// Skore's path to the class (its `pathIds`): [modelId], [groupId] and
  /// [classId]. Skore's gradebook calls name the class by it.
  List<int> get pathIds => [modelId, groupId, classId];

  /// Whether a colleague shared the gradebook with the user (to read or to
  /// write), rather than it being one of their own (#191).
  bool get isShared => access != SkoreGradebookAccess.own;

  @override
  String toString() =>
      'SkoreGradebook(gradebookId: $gradebookId, class: $className '
      '($classId), course: $courseName ($courseId), pathIds: $pathIds, '
      'workyearId: $workyearId'
      '${isShared ? ', access: ${access.name}, teacherId: $teacherId' : ''})';
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

  /// The report periods ("Rapporten | Rapport 1") of the gradebook, in
  /// Skore's order (the `reports` of Skore's `init`, #195): where the
  /// teacher writes the course comment of each pupil that goes on the
  /// report (`SkoreGradebookService.getReport` and `saveReportComment`).
  /// Empty for a gradebook without report periods. Seen live: one per
  /// gradebook in October 2026, also for a gradebook without evaluation
  /// periods (a behaviour gradebook).
  final List<SkoreReportPeriod> reports;

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
  ///
  /// For a gradebook shared with the user to write, Skore answered `1`
  /// (seen live, #191); what it answers for one shared to read only was not
  /// seen. Whether a gradebook was shared to write is
  /// [SkoreGradebook.access].
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
    this.reports = const [],
  });

  @override
  String toString() =>
      'SkoreGradebookSheet(gradebookId: ${gradebook.gradebookId}, '
      'courseName: $courseName, periods: ${periods.length}, '
      'activePeriod: ${activePeriod?.name}, reports: ${reports.length}, '
      'pupils: ${pupils.length}, writable: $writable)';
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

/// A report period of a gradebook: a tab of Skore's gradebook under
/// "Rapporten" ("Rapporten | Rapport 1", #195), as Skore's `init` lists it:
/// `{"name": "R1D", "fullname": "Rapport 1", "id": "2762", "info": "<p>...",
/// "open": 1, "type": "a", "rating": 0, "timestamp":
/// "2026-10-30T23:00:00+0100", "lockIcon": 0}` (seen live).
///
/// While it is open, the teacher writes the course comment of each pupil
/// that goes on the report (`SkoreGradebookService.saveReportComment`). Its
/// ID is not the ID of an evaluation period: `getEvaluations` does not take
/// it.
class SkoreReportPeriod {
  /// The report's ID (e.g. `2762`). The gradebooks of a report model share
  /// it (seen live).
  final int id;

  /// The short name Skore shows on the tab (e.g. `"R1D"`).
  final String name;

  /// The full name (Skore's `fullname`, e.g. `"Rapport 1"`); [name] when
  /// Skore gives none.
  final String fullName;

  /// Whether the report is open (Skore's `open` 1): whether its course
  /// comments can be written. Skore's web client shows a closed report's
  /// comments read-only ("Dit rapport is gesloten. Enkel de beheerder kan
  /// nog vakinfo ingeven.").
  final bool isOpen;

  /// When the report closes (or closed), from Skore's `timestamp`
  /// (`"2026-10-30T23:00:00+0100"`), in UTC; `null` when Skore gives none.
  final DateTime? closesAt;

  /// Skore's description of the report, as HTML (e.g. "Rapport 1", "Open
  /// tot 2026-10-30 23:00" and the school's note).
  final String info;

  /// Skore's `type` of the report as it gave it (`"a"`, the only one seen
  /// live); what it means was not found out.
  final String typeCode;

  /// Skore's `rating` of the report (`0`, the only one seen live); what it
  /// means was not found out.
  final int rating;

  const SkoreReportPeriod({
    required this.id,
    required this.name,
    required this.fullName,
    required this.isOpen,
    required this.closesAt,
    this.info = '',
    this.typeCode = '',
    this.rating = 0,
  });

  @override
  String toString() =>
      'SkoreReportPeriod(id: $id, name: $name, isOpen: $isOpen, '
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

  /// Grades on a scale (`evaltype` 2, "Waarderingen"), read as Skore's web
  /// client reads them (#193): a grade is still a value out of
  /// [SkoreEvaluation.max], and its level is the one of the school's scale
  /// that [SkoreScale.levelOf] finds for it. Not seen live: none of the
  /// developer's gradebooks, own or shared, of 2023-2024 to 2026-2027 had
  /// one (2026-10-27).
  scale,

  /// Another `evaltype` (kept in [SkoreEvaluation.typeCode]). Its cells are
  /// not read: such an evaluation is not [SkoreEvaluation.isReadable].
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

  final SkoreEvaluationResults _results;

  /// Why the library could not read the grades of the evaluation, or `null`
  /// when it could ([isReadable]) (#193): its type is not one it knows
  /// ([SkoreEvaluationType.unknown], with its [typeCode]), or a cell of it
  /// is in a shape it does not recognise (such as a cell without its `raw`).
  /// Names the cell by its row (`pupil_<id>_<classId>`), and quotes nothing
  /// of Skore's answer.
  ///
  /// `SkoreGradebookService.getEvaluations` reads the rest of the period
  /// then: the other evaluations, with their grades and feedback markers,
  /// and this one's title, date, type and publication.
  final String? unreadableReason;

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
    required SkoreEvaluationResults results,
    this.unreadableReason,
  }) : _results = results;

  /// Whether the library could read the grades of the evaluation
  /// ([unreadableReason] is `null`), so that [results] gives them.
  bool get isReadable => unreadableReason == null;

  /// The grades of the gradebook's pupils, as Skore gave them with the
  /// evaluation.
  ///
  /// For an evaluation the library could not read (not [isReadable]), it
  /// throws a [SmartschoolSkoreEvaluationUnreadableError] that names the
  /// evaluation and [unreadableReason], rather than give no grades: check
  /// [isReadable] first.
  SkoreEvaluationResults get results {
    final reason = unreadableReason;
    if (reason == null) return _results;
    throw SmartschoolSkoreEvaluationUnreadableError(
      'Evaluation $id ("$title") of period $periodId of gradebook '
      '$gradebookId (evaltype $typeCode) cannot be read: $reason.',
      evaluationId: id,
      typeCode: typeCode,
      reason: reason,
    );
  }

  @override
  String toString() =>
      'SkoreEvaluation(id: $id, column: $column, date: '
      '${date.toIso8601String().substring(0, 10)}, max: $max, component: '
      '$componentName, type: ${type.name}, publication: $publication, '
      '${isReadable ? 'grades: ${_results.grades.length}' : 'unreadable'})';
}

/// A component an evaluation in a period can count for, as the "new
/// evaluation" dialog of Skore's gradebook lists them
/// (`SkoreGradebookService.getComponents`, #150): `geen` (none, [id] `0`)
/// and, for instance, `DW` (2, "Dagelijks werk").
class SkoreEvaluationComponent {
  /// The component's ID (Skore's `componentID`, e.g. `2`), `0` for none
  /// ("geen"): what [SkoreEvaluation.componentId] holds.
  final int id;

  /// Its short name (e.g. `"DW"`, or `"geen"` for none), what
  /// [SkoreEvaluation.componentName] holds.
  final String name;

  const SkoreEvaluationComponent({required this.id, required this.name});

  /// Whether this is "geen": the evaluation counts for no component.
  bool get isNone => id == 0;

  @override
  String toString() => 'SkoreEvaluationComponent(id: $id, name: $name)';
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
  ///
  /// For an evaluation on a scale ([SkoreEvaluationType.scale]), also a
  /// value out of [SkoreEvaluation.max], as Skore's web client reads it
  /// (#193; not seen live): [SkoreScale.levelOf] gives its level, with the
  /// label Skore shows for it.
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

/// The scale of the evaluations on a scale ("Waarderingen",
/// [SkoreEvaluationType.scale]) of Skore's gradebook: its levels, from low
/// to high (`SkoreGradebookService.getScale`, #193).
///
/// Skore's web client has one, the school's (its `defaultScale`), for every
/// evaluation on a scale of every gradebook: it finds the level of a grade
/// in it ([levelOf]) and offers its levels in the feedback panel. Seen live
/// (2026-10-27): a scale of two levels, each with a description, an
/// abbreviation, a colour, a lower threshold and a value, without a
/// graphic. Whether a school can have more than one scale was not found
/// out.
class SkoreScale {
  /// The scale's ID (a UUID).
  final String id;

  /// The scale's name, as the school named it.
  final String name;

  /// Its levels, in Skore's order: from the lowest threshold to the highest
  /// in what was seen live.
  final List<SkoreScaleLevel> levels;

  const SkoreScale({
    required this.id,
    required this.name,
    this.levels = const [],
  });

  /// The level of [grade], a grade of [evaluation], an evaluation on a scale
  /// ([SkoreEvaluationType.scale]), as Skore's web client finds it: its
  /// [SkoreGrade.grade] as a percentage of [SkoreEvaluation.max] (the
  /// highest grade cut to a whole number, the percentage rounded to one
  /// decimal), and the level for that percentage ([levelForPercentage]).
  ///
  /// `null` when the pupil has no grade, a grade that is not a number, or
  /// when the evaluation has no highest grade of 1 or more, or when no level
  /// covers the percentage. An [ArgumentError] for an evaluation that is
  /// not on a scale.
  ///
  /// From the code of Skore's web client: no evaluation on a scale was seen
  /// live, so how Skore stores a level in a cell was not seen either.
  SkoreScaleLevel? levelOf(SkoreEvaluation evaluation, SkoreGrade grade) {
    if (evaluation.type != SkoreEvaluationType.scale) {
      throw ArgumentError.value(
        evaluation.id,
        'evaluation',
        'not an evaluation on a scale (evaltype ${evaluation.typeCode})',
      );
    }
    final value = grade.value;
    final max = evaluation.max?.truncate();
    if (value == null || max == null || max <= 0) return null;
    // The web client's Math.round(grade / max * 100 * 10) / 10.
    final percentage = (value / max * 100 * 10 + 0.5).floor() / 10;
    return levelForPercentage(percentage);
  }

  /// The level for [percentage] (`0` to `100`), as Skore's web client finds
  /// it: the percentage cut to a whole number, and of the levels whose
  /// [SkoreScaleLevel.lowerThreshold] is at most that, the last in
  /// [levels]. `null` for a percentage that, cut, is below `0` or above
  /// `100`, or one no level covers.
  SkoreScaleLevel? levelForPercentage(num percentage) {
    if (!percentage.isFinite) return null;
    final whole = percentage.truncate();
    if (whole < 0 || whole > 100) return null;
    return levels.where((l) => l.lowerThreshold <= whole).lastOrNull;
  }

  @override
  String toString() => 'SkoreScale(id: $id, levels: ${levels.length})';
}

/// A level of a [SkoreScale]: what a grade on a scale means, with the label
/// Skore shows for it (#193). Skore's `{"id": 901, "description": "Goed",
/// "range": {"lowerThreshold": 50, "value": 100}, "graphic": null,
/// "abbreviation": "G", "color": "green"}` (in the shape seen live).
class SkoreScaleLevel {
  /// The level's ID (e.g. `901`).
  final int id;

  /// Its description, the label (e.g. `"Goed"`).
  final String description;

  /// Its abbreviation, the short label Skore shows in a cell without a
  /// graphic (e.g. `"G"`).
  final String abbreviation;

  /// Its colour, by Skore's name (e.g. `"green"`), or `""` when it has none.
  final String color;

  /// The lowest percentage of the highest grade that has this level
  /// (Skore's `range.lowerThreshold`, e.g. `50`).
  final num lowerThreshold;

  /// Skore's `range.value` of the level (e.g. `100`; `0` for the lowest
  /// level seen live): presumably the percentage a grade of this level is
  /// stored as, which was not seen live.
  final num value;

  /// Skore's `graphic` of the level, an icon or an image the web client
  /// shows instead of the abbreviation, as Skore gives it (in the web
  /// client's code: `type` `"icon"` or `"image"`, `value`, `url`, `color`),
  /// or `null` for none (as seen live).
  final Map<String, dynamic>? graphic;

  const SkoreScaleLevel({
    required this.id,
    required this.description,
    required this.abbreviation,
    this.color = '',
    required this.lowerThreshold,
    required this.value,
    this.graphic,
  });

  @override
  String toString() =>
      'SkoreScaleLevel(id: $id, abbreviation: $abbreviation, '
      'lowerThreshold: $lowerThreshold)';
}

/// A feedback text of a teacher for a pupil on an evaluation, as the
/// feedback panel of Skore's gradebook shows it (#149). A pupil can have
/// several on one evaluation, from one or more teachers.
/// `SkoreGradebookService.saveFeedback` creates or changes the user's own
/// (#152).
class SkoreFeedback {
  /// The feedback's ID (a UUID).
  final String id;

  /// The text.
  final String text;

  /// The pupil's Smartschool user ID (the middle part of `4069_900001_0`).
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

/// A report period of a gradebook as Skore's gradebook shows it
/// (`SkoreGradebookService.getReport`, #195): per pupil of the gradebook's
/// class, the results so far per component of the course, as Skore
/// calculates them, and the course comment ("vakcommentaar") that goes on
/// the report.
///
/// Skore keeps **one** course comment per pupil, course and report: not one
/// per teacher, and it does not say who wrote it.
class SkoreReport {
  /// The gradebook (its `SkoreGradebook.gradebookId`).
  final int gradebookId;

  /// The report ([SkoreReportPeriod.id]).
  final int reportId;

  /// The course of the gradebook (its `SkoreGradebook.courseId`).
  final int courseId;

  /// The course as the report names it (e.g. `"Informaticawetenschappen
  /// (2 uur)"`).
  final String courseName;

  /// The components of the course the report shows results for (e.g.
  /// `DW`), in Skore's order. Empty for a course without them, such as a
  /// behaviour course, whose report holds only the comment (seen live).
  final List<SkoreReportComponent> components;

  /// Whether the report has a course comment for the course (Skore's
  /// column `<courseId>_info`). Seen live for every report read.
  final bool hasComments;

  /// The most characters a course comment may have, as Skore gives it with
  /// the report (its `length`, `1600` seen live), or `null` when it gives
  /// none.
  final int? commentMaxLength;

  /// The pupils of the gradebook's class, in Skore's order. Not the class
  /// average, and not the pupils of other classes.
  final List<SkoreReportPupil> pupils;

  const SkoreReport({
    required this.gradebookId,
    required this.reportId,
    required this.courseId,
    required this.courseName,
    this.components = const [],
    this.hasComments = false,
    this.commentMaxLength,
    this.pupils = const [],
  });

  /// The row of pupil [pupilId], or `null` when the report has none.
  SkoreReportPupil? pupil(int pupilId) =>
      pupils.where((p) => p.pupilId == pupilId).firstOrNull;

  @override
  String toString() =>
      'SkoreReport(gradebookId: $gradebookId, reportId: $reportId, '
      'courseId: $courseId, components: ${components.length}, pupils: '
      '${pupils.length}, comments: '
      '${pupils.where((p) => p.comment?.isEmpty == false).length})';
}

/// A component of a course on a report (e.g. `DW`, "Dagelijks werk"), with
/// the class average Skore shows for it (#195).
class SkoreReportComponent {
  /// Skore's column of the component (e.g. `"2264_1"`: the course ID, and
  /// the component's place on the report). Not a component ID of
  /// `SkoreEvaluation.componentId`.
  final String column;

  /// The component's short name (e.g. `"DW"`).
  final String name;

  /// The class average as Skore shows it (e.g. `"74"`), or `null` when it
  /// shows none (`-`).
  final String? classAverage;

  const SkoreReportComponent({
    required this.column,
    required this.name,
    this.classAverage,
  });

  @override
  String toString() =>
      'SkoreReportComponent(column: $column, name: $name, classAverage: '
      '$classAverage)';
}

/// One pupil's row of a report (#195): the results per component, and the
/// course comment.
class SkoreReportPupil {
  /// The pupil's Smartschool user ID.
  final int pupilId;

  /// The Skore class ID of the row (the gradebook's class).
  final int classId;

  /// The pupil's result for each of the report's components, in their
  /// order. Read-only: Skore calculates them from the evaluations.
  final List<SkoreReportResult> results;

  /// The pupil's course comment, or `null` when the report has no comment
  /// for the pupil.
  final SkoreReportComment? comment;

  const SkoreReportPupil({
    required this.pupilId,
    required this.classId,
    this.results = const [],
    this.comment,
  });

  /// Skore's key of the pupil's row: `pupil_<pupilId>_<classId>`.
  String get rowKey => 'pupil_${pupilId}_$classId';

  /// The result for the component in Skore's [column], or `null` when the
  /// row has none.
  SkoreReportResult? resultOf(String column) =>
      results.where((r) => r.column == column).firstOrNull;

  @override
  String toString() =>
      'SkoreReportPupil(pupilId: $pupilId, results: ${results.length}, '
      'comment: ${comment == null ? 'none' : '${comment!.text.length} characters'})';
}

/// A pupil's result for a component on a report, as Skore shows it (#195).
class SkoreReportResult {
  /// The component's column ([SkoreReportComponent.column]).
  final String column;

  /// The result as Skore shows it (e.g. `"79"`), or `null` when it shows
  /// none (`-`, or empty).
  final String? value;

  /// Whether Skore marks the result as low (the class `gbc_low`, which it
  /// shows in red).
  final bool isLow;

  const SkoreReportResult({
    required this.column,
    required this.value,
    this.isLow = false,
  });

  @override
  String toString() =>
      'SkoreReportResult(column: $column, value: $value, isLow: $isLow)';
}

/// The course comment ("vakcommentaar") of a pupil on a report, which is
/// printed on the report (#195). One per pupil, course and report: Skore
/// does not say who wrote it.
class SkoreReportComment {
  /// The pupil's Smartschool user ID.
  final int pupilId;

  /// The report ([SkoreReportPeriod.id]).
  final int reportId;

  /// The course ([SkoreReport.courseId]).
  final int courseId;

  /// The text, plain, with its lines; `""` when the pupil has none.
  final String text;

  /// Whether Skore lets the user change it: the first of the cell's
  /// parameters is `1`. Skore marks a comment it does not let them change
  /// (`0`) as closed (`gbc_closed`; seen live for some pupils of a report
  /// that is open). And only while the report is open
  /// ([SkoreReportPeriod.isOpen]).
  final bool isEditable;

  /// The parameters of the comment's cell as Skore gives them, as text
  /// (`["1", "2762"]`: whether it may be changed, and the report), which
  /// the save sends back, as Skore's web client does.
  final List<String> cellParams;

  const SkoreReportComment({
    required this.pupilId,
    required this.reportId,
    required this.courseId,
    required this.text,
    required this.isEditable,
    this.cellParams = const [],
  });

  /// Whether the pupil has no comment.
  bool get isEmpty => text.isEmpty;

  @override
  String toString() =>
      'SkoreReportComment(pupilId: $pupilId, reportId: $reportId, '
      '${text.length} characters, isEditable: $isEditable)';
}
