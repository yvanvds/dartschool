/// Models for the results of a pupil's file in Smartschool's pupil tracking
/// system (LVS, `/?module=LVS`, #162): the "Resultaten" section of the file,
/// the same results app pupils and parents see, embedded in the LVS for one
/// pupil. A teacher sees the results of the pupil in **every** course there,
/// not only those of their own gradebooks.
///
/// The shapes are those the results app reads (its JavaScript, 2026-10-21);
/// a real pupil's answers are the developer's capture step (#168). Like the
/// other LVS models, these never print their values: their `toString()`
/// shows counts and types only (`doc/lvs-privacy.md`, rule 6).
///
/// Dates are the instants the LVS gives (ISO 8601 with an offset), in UTC.
/// Scores are kept as the LVS gives them ([LvsScore]): the library computes
/// no averages.
library;

/// What the results app may show the account for a pupil
/// (`GET /LVS/Results/getConfiguration`: `{capabilities: {canUserSeeAll,
/// canUserSeeSchoolyear}}`), as the app names its capabilities.
class LvsResultsConfiguration {
  /// `capabilities.canUserSeeAll`: the web client enables its school year
  /// picker with it (other school years than the current one). `null` when
  /// the LVS does not say.
  final bool? canSeeAll;

  /// `capabilities.canUserSeeSchoolyear`. `null` when the LVS does not say.
  final bool? canSeeSchoolYear;

  const LvsResultsConfiguration({this.canSeeAll, this.canSeeSchoolYear});

  /// Shows the flags: they are not a pupil's.
  @override
  String toString() =>
      'LvsResultsConfiguration(canSeeAll: $canSeeAll, '
      'canSeeSchoolYear: $canSeeSchoolYear)';
}

/// A period of a pupil's results (a Skore period: "Trimester 1", "Examens
/// december", ...), as `GET /LVS/Results/getperiods` lists them and an
/// evaluation names its own: `{id, name, icon, class, skoreWorkYear: {id,
/// dateRange: {start, end}}, isActive}`.
class LvsResultsPeriod {
  /// The period's ID (`id`), which `LvsService.getEvaluations` takes in
  /// `periodIds`.
  final int id;

  /// The period's name, as the school named it.
  final String name;

  /// The name of the icon the web client shows it with; empty when none.
  final String icon;

  /// The ID of the class or group of the period (`class.id`); `null` when
  /// the LVS gives none.
  final int? classId;

  /// The name of that class or group (`class.name`); empty when none.
  final String className;

  /// Whether it is an active period (`isActive`); `false` when the LVS does
  /// not say.
  final bool isActive;

  /// The ID of the Skore school year ("werkjaar") of the period
  /// (`skoreWorkYear.id`); `null` when the LVS gives none.
  final int? workYearId;

  /// The first moment of that school year (`skoreWorkYear.dateRange.start`),
  /// in UTC; `null` when none.
  final DateTime? workYearStart;

  /// The last moment of that school year (`skoreWorkYear.dateRange.end`), in
  /// UTC; `null` when none.
  final DateTime? workYearEnd;

  const LvsResultsPeriod({
    required this.id,
    required this.name,
    this.icon = '',
    this.classId,
    this.className = '',
    this.isActive = false,
    this.workYearId,
    this.workYearStart,
    this.workYearEnd,
  });

  /// Shows the flag only: the name is the school's own.
  @override
  String toString() => 'LvsResultsPeriod(isActive: $isActive)';
}

/// A course of a pupil's results, as `GET /LVS/Results/getcourses` lists
/// them and an evaluation names its own: `{id, name, graphic: {type,
/// value}, class, skoreClassId, parentCourseId}` (an evaluation's courses
/// also have `teachers`).
class LvsResultsCourse {
  /// The course's ID (`id`), which `LvsService.getEvaluations` takes in
  /// `courseIds`.
  final int id;

  /// The course's name, as the school named it.
  final String name;

  /// The ID of the class or group of the course (`class.id`); `null` when
  /// the LVS gives none.
  final int? classId;

  /// The name of that class or group (`class.name`); empty when none.
  final String className;

  /// The ID of the Skore class of the course (`skoreClassId`); `null` when
  /// none.
  final int? skoreClassId;

  /// The ID of the course this one is part of (`parentCourseId`); `null`
  /// for a course of its own.
  final int? parentCourseId;

  /// How the web client shows the course (`graphic.type`): `icon` or
  /// `image`; empty when none.
  final String graphicType;

  /// The icon's name, or the path of the image (`graphic.value`); empty when
  /// none.
  final String graphicValue;

  /// The names of the course's teachers (`teachers`, each
  /// `name.startingWithFirstName`), as an evaluation gives them; empty when
  /// the answer names none.
  final List<String> teacherNames;

  const LvsResultsCourse({
    required this.id,
    required this.name,
    this.classId,
    this.className = '',
    this.skoreClassId,
    this.parentCourseId,
    this.graphicType = '',
    this.graphicValue = '',
    this.teacherNames = const [],
  });

  /// Shows the count of teachers only: the name is the school's own.
  @override
  String toString() => 'LvsResultsCourse(teachers: ${teacherNames.length})';
}

/// The kinds of [LvsScore.type] the results app knows.
///
/// The LVS may send others: [LvsScore.type] keeps any type as it comes.
abstract final class LvsScoreType {
  /// A score as a percentage ([LvsScore.percentage]), with the score itself
  /// in [LvsScore.description] ("7/10").
  static const percentage = 'percentage';

  /// A text, such as a letter or a word ([LvsScore.value]).
  static const text = 'text';

  /// An icon, by name ([LvsScore.value]).
  static const icon = 'icon';

  /// An image, by its path ([LvsScore.value]).
  static const image = 'image';

  /// The result of a rubric.
  static const rubrics = 'rubrics';

  /// Every type above.
  static const known = {percentage, text, icon, image, rubrics};
}

/// The score of an evaluation, as the LVS gives it (the evaluation's
/// `graphic`: `{type, color, value, description}`). Nothing is computed:
/// a score in points comes as a percentage ([percentage]) with the points as
/// the web client shows them in [description] ("7/10"); a symbol or a text
/// in [value].
class LvsScore {
  /// The kind of score (`type`): one of [LvsScoreType], or another the LVS
  /// sends, kept as it comes; empty when none.
  final String type;

  /// `value` as text: the percentage as the LVS sent it, the text, the
  /// icon's name, the image's path; empty when none.
  final String value;

  /// `value` as a number, when the LVS sent a number (the percentage of a
  /// [LvsScoreType.percentage] score); `null` otherwise.
  final num? percentage;

  /// `description`: the score as the web client shows it next to the
  /// graphic (the points, "7/10", of a percentage); empty when none.
  final String description;

  /// The colour the web client shows the score in (`color`: `green`,
  /// `orange`, `red`, `steel`, ...); empty when none.
  final String color;

  const LvsScore({
    required this.type,
    this.value = '',
    this.percentage,
    this.description = '',
    this.color = '',
  });

  /// No score: an evaluation without a `graphic`.
  static const none = LvsScore(type: '');

  /// Whether [type] is one of [LvsScoreType.known].
  bool get isKnownType => LvsScoreType.known.contains(type);

  /// Shows the type only: the score is a pupil's.
  @override
  String toString() => 'LvsScore(type: $type)';
}

/// An evaluation of a pupil, with its score, as
/// `GET /LVS/Results/getevaluationsofuser` lists them: `{identifier, type,
/// name, graphic, date, courses, period, component, doesCount,
/// isPublished, feedbacks, ...}`.
///
/// The list is not validated by the results app (its JavaScript reads it
/// as is); the fields are those its pages show. A real pupil's answer is the
/// developer's capture step (#168).
class LvsEvaluation {
  /// The evaluation's identifier (`identifier`), a text such as
  /// `<school>_<pupil>_0_normal_<id>`.
  final String identifier;

  /// The kind of evaluation (`type`): `normal`, `project` or
  /// `project-with-rubrics` in the web client; empty when none.
  final String type;

  /// The evaluation's name.
  final String name;

  /// When the evaluation took place (`date`), in UTC; `null` when the LVS
  /// gives none.
  final DateTime? date;

  /// The score ([LvsScore.none] when the LVS gives none).
  final LvsScore score;

  /// The courses it counts for (`courses`), in the LVS's order; empty when
  /// none.
  final List<LvsResultsCourse> courses;

  /// Its period (`period`); `null` when the LVS gives none.
  final LvsResultsPeriod? period;

  /// The name of the gradebook component it belongs to (`component.name`);
  /// empty when none.
  final String componentName;

  /// The abbreviation of that component (`component.abbreviation`); empty
  /// when none.
  final String componentAbbreviation;

  /// Whether it counts (`doesCount`); `null` when the LVS does not say.
  final bool? doesCount;

  /// Whether it is published to the pupil (`isPublished`); `null` when the
  /// LVS does not say.
  final bool? isPublished;

  /// How many feedbacks it has (`feedbacks`). `LvsService.getFeedback`
  /// reads them, with their texts.
  final int feedbackCount;

  const LvsEvaluation({
    required this.identifier,
    this.type = '',
    required this.name,
    this.date,
    this.score = LvsScore.none,
    this.courses = const [],
    this.period,
    this.componentName = '',
    this.componentAbbreviation = '',
    this.doesCount,
    this.isPublished,
    this.feedbackCount = 0,
  });

  /// Shows the type and counts only: the values are a pupil's.
  @override
  String toString() =>
      'LvsEvaluation(type: $type, score: ${score.type}, '
      'courses: ${courses.length}, feedbacks: $feedbackCount)';
}

/// One page of a pupil's evaluations (`LvsService.getEvaluations`).
class LvsEvaluationPage {
  /// The number of the page, from 1.
  final int pageNumber;

  /// The number of evaluations per page asked for.
  final int itemsOnPage;

  /// The evaluations of the page, in the LVS's order.
  final List<LvsEvaluation> evaluations;

  const LvsEvaluationPage({
    required this.pageNumber,
    required this.itemsOnPage,
    required this.evaluations,
  });

  /// Whether a next page may hold more: this page is full ([itemsOnPage]
  /// evaluations). A page with fewer is the last one; one with more means
  /// the LVS does not page the list, and sent all of it.
  bool get mayHaveMore => evaluations.length == itemsOnPage;

  /// Shows the counts only.
  @override
  String toString() =>
      'LvsEvaluationPage(pageNumber: $pageNumber, '
      'evaluations: ${evaluations.length})';
}

/// A pupil's evaluations read page by page (`LvsService.getAllEvaluations`),
/// up to the cap the caller set.
class LvsEvaluationList {
  /// The evaluations, in the LVS's order, each once.
  final List<LvsEvaluation> evaluations;

  /// Whether the list is complete: the last page read was not full. `false`
  /// when the cap stopped the reading with a full page: there may be more.
  final bool isComplete;

  /// How many pages were read.
  final int pagesRead;

  const LvsEvaluationList({
    required this.evaluations,
    required this.isComplete,
    required this.pagesRead,
  });

  /// Shows the counts only.
  @override
  String toString() =>
      'LvsEvaluationList(evaluations: ${evaluations.length}, '
      'isComplete: $isComplete, pagesRead: $pagesRead)';
}

/// The kinds of [LvsFeedback], as the results app tells them apart by their
/// fields.
enum LvsFeedbackKind {
  /// A remark of the class council on a report: `{identifier, text, type,
  /// report}`, `type` being the report's part it is written in
  /// ([LvsFeedback.reportPart]).
  classCouncil,

  /// A remark per course on a report: `{identifier, text, course, report}`.
  course,

  /// Feedback of a teacher on an evaluation: `{identifier, text, owner,
  /// evaluation, attachments}`.
  evaluation,

  /// Feedback on a goal of a project evaluation: the fields of [evaluation]
  /// and `goal`.
  goal,

  /// Another kind: its identifier and text are kept.
  unknown,
}

/// A feedback on a pupil's results (`GET /LVS/Results/getfeedback`): a
/// remark on a report (of the class council, or per course), or a teacher's
/// feedback on an evaluation or on a goal of one.
class LvsFeedback {
  /// The feedback's identifier (`identifier`).
  final String identifier;

  /// What kind of feedback it is.
  final LvsFeedbackKind kind;

  /// The feedback itself (`text`), as the LVS gives it (the web client shows
  /// it as HTML).
  final String text;

  /// The name of the teacher who wrote it (`owner.name.startingWithFirstName`);
  /// empty when the answer names none (a remark on a report names none).
  final String author;

  /// The report a remark is written on (`report`); `null` for the other
  /// kinds.
  final LvsReport? report;

  /// The part of the report a class council's remark is written in
  /// (`type.name`); empty for the other kinds.
  final String reportPart;

  /// The course a remark per course is about (`course`); `null` for the
  /// other kinds.
  final LvsResultsCourse? course;

  /// The evaluation the feedback is on (`evaluation`); `null` for a remark
  /// on a report.
  final LvsFeedbackEvaluation? evaluation;

  /// The ID of the goal of a project evaluation (`goal.goalId`); `null` for
  /// the other kinds.
  final String? goalId;

  /// The ID of the curriculum ("leerplan") of that goal
  /// (`goal.leerplanId`); `null` for the other kinds.
  final String? curriculumId;

  /// The attachments (`attachments`): their metadata only; empty when none.
  final List<LvsResultsAttachment> attachments;

  const LvsFeedback({
    required this.identifier,
    required this.kind,
    required this.text,
    this.author = '',
    this.report,
    this.reportPart = '',
    this.course,
    this.evaluation,
    this.goalId,
    this.curriculumId,
    this.attachments = const [],
  });

  /// Shows the kind and the count of attachments only: the text is about a
  /// pupil.
  @override
  String toString() =>
      'LvsFeedback(kind: ${kind.name}, attachments: ${attachments.length})';
}

/// The evaluation a [LvsFeedback] is on: `{identifier, name, courses,
/// period, schoolyearLabel, date}`.
class LvsFeedbackEvaluation {
  /// The evaluation's identifier, as [LvsEvaluation.identifier].
  final String identifier;

  /// The evaluation's name.
  final String name;

  /// When it took place (`date`), in UTC; `null` when none.
  final DateTime? date;

  /// Its courses (`{id, name, class: {id}}`); empty when none.
  final List<LvsResultsCourse> courses;

  /// Its period; `null` when none.
  final LvsResultsPeriod? period;

  /// The school year as the LVS labels it (`schoolyearLabel`); empty when
  /// none.
  final String schoolYearLabel;

  const LvsFeedbackEvaluation({
    required this.identifier,
    required this.name,
    this.date,
    this.courses = const [],
    this.period,
    this.schoolYearLabel = '',
  });

  /// Shows the count of courses only.
  @override
  String toString() => 'LvsFeedbackEvaluation(courses: ${courses.length})';
}

/// A report ("rapport") of a pupil (`GET /LVS/Results/getreports`): `{id,
/// name, icon, date, class, schoolyearLabel, downloadUrl}`. Metadata only:
/// the library does not download the report.
class LvsReport {
  /// The report's ID (`id`).
  final int id;

  /// The report's name, as the school named it.
  final String name;

  /// The name of the icon the web client shows it with; empty when none.
  final String icon;

  /// The report's date (`date`), in UTC; `null` when none.
  final DateTime? date;

  /// The ID of the class or group of the report (`class.id`); `null` when
  /// the LVS gives none.
  final int? classId;

  /// The name of that class or group (`class.name`); empty when none.
  final String className;

  /// The school year as the LVS labels it (`schoolyearLabel`); empty when
  /// none.
  final String schoolYearLabel;

  /// The path the web client downloads the report from (`downloadUrl`), kept
  /// as metadata; empty when none.
  final String downloadUrl;

  const LvsReport({
    required this.id,
    required this.name,
    this.icon = '',
    this.date,
    this.classId,
    this.className = '',
    this.schoolYearLabel = '',
    this.downloadUrl = '',
  });

  /// Shows no value: a report is a pupil's.
  @override
  String toString() => 'LvsReport(<values hidden>)';
}

/// An attachment of a [LvsFeedback]: `{id, name, type, size, downloadUrl,
/// ...}`. Metadata only: the library does not download it.
class LvsResultsAttachment {
  /// The attachment's ID (`id`, a text).
  final String id;

  /// The file's name (`name`).
  final String name;

  /// The kind of attachment (`type`): `OTHER` (a file),
  /// `MICROPHONE_RECORDING` or `WEBCAM_RECORDING` in the web client; empty
  /// when none.
  final String type;

  /// The file's size in bytes (`size`); `null` when none.
  final int? size;

  /// The path the web client downloads it from (`downloadUrl`), kept as
  /// metadata; empty when none.
  final String downloadUrl;

  const LvsResultsAttachment({
    required this.id,
    required this.name,
    this.type = '',
    this.size,
    this.downloadUrl = '',
  });

  /// Shows no value: a file name can name a pupil.
  @override
  String toString() => 'LvsResultsAttachment(<values hidden>)';
}
