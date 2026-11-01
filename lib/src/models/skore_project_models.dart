// The project gradebooks of Skore ("Projecten", #204): a project period's
// templates with their rating scale, its learning goals, its projects and
// the pupils' ratings, as `SkoreGradebookService` reads them.

/// A template of a project period: what Skore's project sheet offers in its
/// selector "Project:" (Skore's `getTemplateList`, #204), such as
/// "Digitale vaardigheden 3e graad". It holds the learning goals
/// (`SkoreGradebookService.getLearningGoals`) and the projects
/// (`SkoreGradebookService.getProjects`) of the period, and the scale their
/// ratings are on.
///
/// Seen live: `{"creator": {"id", "name", "surname"}, "info", "descr",
/// "isComponentRequired", "isComponentForbidden", "isRatingAllowed",
/// "isGradesAllowed", "isRubricsEnabled", "id", "title", "templateType",
/// "componentId", "scale": {...}}`.
class SkoreProjectTemplate {
  /// The template's ID (e.g. `380`).
  final int id;

  /// The title Skore shows (e.g. `"Digitale vaardigheden 3e graad"`).
  final String title;

  /// Skore's `descr` of the template; `""` when it has none.
  final String description;

  /// Skore's `info` of the template; `""` when it has none.
  final String info;

  /// Skore's `templateType` (`1` in what was seen live).
  final int templateType;

  /// The ID of the component its projects count for (Skore's
  /// `componentId`); `0` for none.
  final int componentId;

  /// Whether its projects take a rating on [scale] per learning goal
  /// (Skore's `isRatingAllowed`).
  final bool isRatingAllowed;

  /// Whether its projects take a grade per learning goal (Skore's
  /// `isGradesAllowed`).
  final bool isGradesAllowed;

  /// Whether its learning goals have rubric descriptions (Skore's
  /// `isRubricsEnabled`).
  final bool isRubricsEnabled;

  /// Skore's `isComponentRequired`.
  final bool isComponentRequired;

  /// Skore's `isComponentForbidden`.
  final bool isComponentForbidden;

  /// The Smartschool user ID of whoever made the template (Skore's
  /// `creator.id`); `null` when Skore gives none.
  final int? creatorId;

  /// The scale the ratings of its projects are on, or `null` when Skore
  /// gives none (a template without ratings; not seen live).
  final SkoreProjectScale? scale;

  /// The template as Skore gave it. Skore's project sheet sends it back
  /// whole with the reads of the template's learning goals and projects;
  /// so does `SkoreGradebookService`.
  final Map<String, Object?> json;

  const SkoreProjectTemplate({
    required this.id,
    required this.title,
    required this.json,
    this.scale,
    this.description = '',
    this.info = '',
    this.templateType = 1,
    this.componentId = 0,
    this.isRatingAllowed = true,
    this.isGradesAllowed = false,
    this.isRubricsEnabled = false,
    this.isComponentRequired = false,
    this.isComponentForbidden = false,
    this.creatorId,
  });

  @override
  String toString() =>
      'SkoreProjectTemplate(id: $id, title: $title, '
      'levels: ${scale?.levels.length ?? 0})';
}

/// The rating scale of a project template (Skore's `scale`: `{"ratings",
/// "id", "description", "name"}`, #204).
class SkoreProjectScale {
  /// The scale's ID (e.g. `12`).
  final int id;

  /// The scale's name, as the school named it.
  final String name;

  /// Skore's `description` of the scale.
  final String description;

  /// Its levels, in Skore's order: from low to high in what was seen live.
  final List<SkoreProjectRatingLevel> levels;

  const SkoreProjectScale({
    required this.id,
    required this.name,
    this.description = '',
    this.levels = const [],
  });

  /// The level with the ID [ratingId] (a [SkoreProjectRating.ratingId]), or
  /// `null` when the scale has none with it.
  SkoreProjectRatingLevel? levelOf(int? ratingId) =>
      levels.where((l) => l.id == ratingId).firstOrNull;

  @override
  String toString() =>
      'SkoreProjectScale(id: $id, name: $name, levels: ${levels.length})';
}

/// A level of a project's rating scale (an item of Skore's
/// `scale.ratings`, #204): `{"id", "description", "symbol", "min", "max",
/// "scaleValue", "color", "icon", "iconBig", "iconName"}`.
class SkoreProjectRatingLevel {
  /// The level's ID: the [SkoreProjectRating.ratingId] of a rating at this
  /// level.
  final int id;

  /// The level's description, as the school named it (e.g.
  /// `"Behaald"`).
  final String description;

  /// The short symbol Skore shows (e.g. `"niv 2"`).
  final String symbol;

  /// The lowest percentage of the level (Skore's `min`).
  final int min;

  /// The highest percentage of the level (Skore's `max`).
  final int max;

  /// Skore's `scaleValue` of the level: the percentage it counts as.
  final int scaleValue;

  /// Skore's `color` of the level (e.g. `"green"`); `""` when none.
  final String color;

  /// Skore's `iconName` of the level; `""` when none.
  final String iconName;

  const SkoreProjectRatingLevel({
    required this.id,
    required this.description,
    this.symbol = '',
    this.min = 0,
    this.max = 0,
    this.scaleValue = 0,
    this.color = '',
    this.iconName = '',
  });

  @override
  String toString() =>
      'SkoreProjectRatingLevel(id: $id, description: $description, '
      'symbol: $symbol)';
}

/// A learning goal of a project template ("rubriek"; an item of Skore's
/// `getCategoriesList`, #204): a row of the project sheet, such as "LPD
/// 16.1.1 Je ...". They form a tree, from the course's root down.
///
/// Seen live: `{"id": "214900001", "parentId": "214900000", "description",
/// "number": "LPD 16.1.1", "level": 2, "isTitle": false, "isCourse": false,
/// "enabled": true, "courseInstanceId": 1588}`; the course's root has the
/// ID `"-1588"` (a minus and the course ID) and the parent `"0"`.
class SkoreLearningGoal {
  /// The goal's ID, as Skore gives it: a string of digits, or a minus and
  /// the course ID (`"-1588"`) for the course's root.
  final String id;

  /// The ID of the goal it is under, or `null` for the course's root
  /// (Skore's `parentId` `"0"`).
  final String? parentId;

  /// The goal's text (Skore's `description`).
  final String description;

  /// The goal's number (e.g. `"LPD 16.1.1"`); `""` when it has none.
  final String number;

  /// Its depth in Skore's tree (Skore's `level`, from `0`).
  final int level;

  /// Whether it is a heading rather than a goal (Skore's `isTitle`).
  final bool isTitle;

  /// Whether it is the course's root (Skore's `isCourse`).
  final bool isCourse;

  /// Skore's `enabled` of the goal: whether it is one of the goals the
  /// template rates (Skore's project sheet can filter its rows on them).
  final bool isEnabled;

  /// The Skore course ID (Skore's `courseInstanceId`).
  final int courseId;

  const SkoreLearningGoal({
    required this.id,
    required this.parentId,
    required this.description,
    required this.courseId,
    this.number = '',
    this.level = 0,
    this.isTitle = false,
    this.isCourse = false,
    this.isEnabled = true,
  });

  @override
  String toString() =>
      'SkoreLearningGoal(id: $id, number: $number, level: $level, '
      'isEnabled: $isEnabled)';
}

/// A project of a project period (an item of Skore's `getProjectList`,
/// #204): a column of ratings of the period's learning goals, made in
/// Skore's project sheet.
///
/// Seen live: `{"id", "periodId", "title", "short", "date":
/// "2026-10-30T00:00:00+0100", "max": 10.0, "evalType": "ratings",
/// "isPublic": false, "publicDateTime": null, "inCount": true,
/// "componentId", "groupContext": false, "maxNoRecalculation": false,
/// "owners": [{"teacherId", "classId", "courseId"}], "template": {...}}`.
class SkoreProject {
  /// The project's ID (e.g. `3901`).
  final int id;

  /// The project period it is in (Skore's `periodId`).
  final int periodId;

  /// The ID of its template (Skore's `template.id`).
  final int templateId;

  /// The title.
  final String title;

  /// The short name, or `null` when it has none (Skore's `short`, `""`).
  final String? shortName;

  /// The day of the project (Skore's `date`), at midnight in the local time
  /// of this machine: only the day counts. `null` when Skore gives none.
  final DateTime? date;

  /// The highest grade (Skore's `max`, e.g. `10.0`), or `null` when Skore
  /// gives none.
  final num? max;

  /// Skore's `evalType` of the project (`"ratings"` in what was seen live).
  final String evalType;

  /// Whether the pupils see it (Skore's `isPublic`).
  final bool isPublic;

  /// When the pupils see it from (Skore's `publicDateTime`), in UTC; `null`
  /// when Skore gives none.
  final DateTime? publicAt;

  /// Whether it counts (Skore's `inCount`).
  final bool inCount;

  /// The ID of the component it counts for (Skore's `componentId`).
  final int componentId;

  /// Whether it is a project of the group of classes (Skore's
  /// `groupContext`) rather than of one class.
  final bool groupContext;

  /// The project as Skore gave it. Skore's project sheet sends it back
  /// whole to read its ratings; so does `SkoreGradebookService`.
  final Map<String, Object?> json;

  const SkoreProject({
    required this.id,
    required this.periodId,
    required this.templateId,
    required this.title,
    required this.json,
    this.shortName,
    this.date,
    this.max,
    this.evalType = '',
    this.isPublic = false,
    this.publicAt,
    this.inCount = true,
    this.componentId = 0,
    this.groupContext = false,
  });

  @override
  String toString() =>
      'SkoreProject(id: $id, periodId: $periodId, title: $title, '
      'isPublic: $isPublic)';
}

/// A pupil's rating of a learning goal in a project (an item of Skore's
/// `getCategoryGradesByProject`, #204): a cell of the project sheet.
///
/// Seen live: `{"id", "projectId", "categoryId": "214900001", "ratingId":
/// 64, "grade": null, "info": null, "options": [], "pupil": {"id",
/// "userId", "classId", "classNumber", ...}}`; Skore lists the cells that
/// hold something.
class SkoreProjectRating {
  /// The rating's ID (e.g. `980001`).
  final int id;

  /// The project (Skore's `projectId`).
  final int projectId;

  /// The learning goal rated (a [SkoreLearningGoal.id]; Skore's
  /// `categoryId`).
  final String learningGoalId;

  /// The pupil's Smartschool user ID (Skore's `pupil.userId`), as
  /// [SkoreGradebookPupil.id] gives it.
  final int pupilId;

  /// Skore's own ID of the pupil (Skore's `pupil.id`), not the Smartschool
  /// user ID.
  final int skorePupilId;

  /// The Skore class ID of the pupil (Skore's `pupil.classId`).
  final int classId;

  /// The level on the template's scale (a [SkoreProjectRatingLevel.id];
  /// Skore's `ratingId`), or `null` when the cell has none.
  /// [SkoreProjectScale.levelOf] gives the level.
  final int? ratingId;

  /// The grade, as Skore gives it, or `null` when the cell has none (every
  /// cell seen live: a template without grades).
  final String? grade;

  /// Skore's `info` of the cell, or `null` when it has none (every cell
  /// seen live).
  final String? info;

  const SkoreProjectRating({
    required this.id,
    required this.projectId,
    required this.learningGoalId,
    required this.pupilId,
    required this.skorePupilId,
    required this.classId,
    this.ratingId,
    this.grade,
    this.info,
  });

  @override
  String toString() =>
      'SkoreProjectRating(projectId: $projectId, learningGoalId: '
      '$learningGoalId, pupilId: $pupilId, ratingId: $ratingId)';
}
