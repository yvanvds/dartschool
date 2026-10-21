/// Models for the support plans of a pupil's file in Smartschool's pupil
/// tracking system (LVS, `/?module=LVS`, #163): the individual plan ("IHP",
/// "individueel handelingsplan") with the pupil's support needs
/// ("ondersteuningsnoden"), goals and approach, its periods, and the
/// profile sketch ("profielschets").
///
/// A school that uses the LVS's support plans ("handelingsplannen") keeps
/// them per period; a pupil's file then has a section of type
/// `handelingsplannen` (`LvsPupilFile.supportPlanSections`). Schools that do
/// not use them keep educational needs in their note categories (#161).
///
/// The shapes are those the LVS's web client reads (its JavaScript and its
/// templates, 2026-10-21), with the envelope seen live for a made-up pupil
/// in a made-up class; a real pupil's answers are the developer's capture
/// step (#168). Like the other LVS models, these never print their values:
/// their `toString()` shows counts and kinds only (`doc/lvs-privacy.md`,
/// rule 6). A support plan is among the most sensitive data there is.
library;

/// A period of the support plans of a pupil's class
/// (`LvsService.getSupportPlanPeriods`): an entry of the LVS's period menu,
/// `{actionID, titleText, ...}`.
class LvsPlanPeriod {
  /// The period's ID (`actionID`), which `LvsService.getSupportPlan` and
  /// `getProfileSketch` take as `periodId`.
  final int id;

  /// The period's name as the school named it (`titleText`, as plain text).
  final String name;

  /// The heading the menu lists the period under (the text of the menu
  /// entry before it that is a heading, such as a school year); empty when
  /// none.
  final String heading;

  const LvsPlanPeriod({
    required this.id,
    required this.name,
    this.heading = '',
  });

  /// Shows no value: the name is the school's own.
  @override
  String toString() => 'LvsPlanPeriod(<values hidden>)';
}

/// The period an answer of the support plans is about: its `period`,
/// `{currentPeriodID, error, message, currentlyInOpenPeriod}`.
class LvsPlanPeriodInfo {
  /// The period's ID (`currentPeriodID`); `null` when the LVS gives none
  /// (with [hasError]).
  final int? id;

  /// Whether the LVS has no period for it (`error`): seen live for a class
  /// without a structure of support plans. [message] says why.
  final bool hasError;

  /// The period as the LVS describes it, or why there is none
  /// ([hasError]), as plain text; empty when it gives nothing.
  final String message;

  /// Whether the period is open (`currentlyInOpenPeriod`): a closed one is
  /// read only in the web client. `null` when the LVS does not say.
  final bool? isOpen;

  const LvsPlanPeriodInfo({
    this.id,
    required this.hasError,
    this.message = '',
    this.isOpen,
  });

  /// Shows the flags only.
  @override
  String toString() =>
      'LvsPlanPeriodInfo(hasError: $hasError, isOpen: $isOpen)';
}

/// What `LvsService.getSupportPlan` found ([LvsSupportPlan.status]).
enum LvsSupportPlanStatus {
  /// The pupil has a plan in the period: [LvsSupportPlan.items] holds it.
  plan,

  /// The period is there, but the pupil has no plan in it (the LVS's
  /// `count` `0`).
  noPlan,

  /// The LVS has no period of support plans for it
  /// ([LvsPlanPeriodInfo.hasError]): seen live for a class without a
  /// structure of support plans.
  noPeriod,
}

/// A pupil's support plan in one period (`LvsService.getSupportPlan`): the
/// items of the individual plan ("IHP").
///
/// An empty plan is not a plan without needs: [status] tells whether the
/// pupil has no plan in the period ([LvsSupportPlanStatus.noPlan]) or the
/// LVS has no period for it ([LvsSupportPlanStatus.noPeriod]).
class LvsSupportPlan {
  /// The period of the plan.
  final LvsPlanPeriodInfo period;

  /// The items of the plan (`items`), in the LVS's order; empty when there
  /// is no plan ([status]).
  final List<LvsPlanItem> items;

  const LvsSupportPlan({required this.period, required this.items});

  /// What was found: a plan, no plan in the period, or no period.
  LvsSupportPlanStatus get status => items.isNotEmpty
      ? LvsSupportPlanStatus.plan
      : period.hasError
      ? LvsSupportPlanStatus.noPeriod
      : LvsSupportPlanStatus.noPlan;

  /// Shows the status and the counts only: the plan is about a pupil.
  @override
  String toString() =>
      'LvsSupportPlan(status: ${status.name}, items: ${items.length})';
}

/// The kinds of [LvsPlanItem], by the LVS's `type` of an item.
enum LvsPlanItemKind {
  /// `ihp`: an item of support needs, with the main and work goals, the
  /// approach and the courses it is planned in ([LvsPlanItem.supportNeeds],
  /// [LvsPlanItem.mainGoals], [LvsPlanItem.workGoals],
  /// [LvsPlanItem.approach], [LvsPlanItem.courses]).
  needs,

  /// `from_gwp`: goals for the pupil, each with its objectives, approach and
  /// planning ([LvsPlanItem.goals]), a theme and a start situation; taken
  /// over from the class's group plan ("GWP",
  /// [LvsPlanItem.fromGroupPlan]), or chosen for the pupil (`source`
  /// `new`).
  goals,

  /// `document`: a plan uploaded as a file: its metadata only
  /// ([LvsPlanItem.fileName], [LvsPlanItem.mimeType]).
  document,

  /// Another type: its ID, author and date are kept.
  unknown,
}

/// An item of a pupil's support plan ([LvsSupportPlan.items]): what its
/// last version holds (`lastversion`).
///
/// Which fields hold something depends on the [kind]; the others are empty.
/// Texts are plain text (the LVS's HTML left out); the two rich texts also
/// keep their HTML ([startSituationHtml], [approachCommentHtml]).
class LvsPlanItem {
  /// The item's ID (`itemID`; `documentID` for a [LvsPlanItemKind.document]).
  final int id;

  /// The item's type as the LVS names it (`type`): `ihp`, `from_gwp`,
  /// `document`, or another, kept as it comes.
  final String type;

  /// The kind of item, by [type].
  final LvsPlanItemKind kind;

  /// Whether the goals are taken over from the class's group plan
  /// (`from_gwp` with a `source` other than `new`); `false` for the other
  /// kinds.
  final bool fromGroupPlan;

  /// The ID of the item's last version (`lastversion.versionID`); `null`
  /// when none.
  final int? versionId;

  /// The kind of goals of the last version (`lastversion.versionType`):
  /// `normal`, `bubao`, `eigendb` (the school's own goals) in the web
  /// client; empty when none.
  final String versionType;

  /// Who wrote the item, as the LVS shows it (`author`; `authorName` of a
  /// document).
  final String author;

  /// When, as the LVS shows it (`lastversion.dateToShow`; `dateToShow` of a
  /// document): a text, kept as it comes; empty when none.
  final String date;

  /// The support needs ("ondersteuningsnoden", `ihp.noden`).
  final List<String> supportNeeds;

  /// The main goals ("hoofddoelen", `ihp.hoofddoelen`).
  final List<String> mainGoals;

  /// The work goals ("werkdoelen", `ihp.werkdoelen`).
  final List<String> workGoals;

  /// The approach ("aanpak", `ihp.aanpak`), and of a goal
  /// ([LvsPlanGoal.approach]).
  final List<String> approach;

  /// The general comment on the approach (`ihp.aanpakcomment`), as plain
  /// text; empty when none.
  final String approachComment;

  /// That comment as HTML, as the LVS gives it; empty when none.
  final String approachCommentHtml;

  /// The courses the item is planned in (`ihp.courses`, their `title`).
  final List<String> courses;

  /// The theme, module or assignment of the goals ("thema",
  /// `lastversion.themeName`); empty when none.
  final String theme;

  /// The start situation ("beginsituatie", `lastversion.beginsituatie`), as
  /// plain text; empty when none.
  final String startSituation;

  /// That start situation as HTML, as the LVS gives it; empty when none.
  final String startSituationHtml;

  /// The goals (`lastversion.doelen`), in the LVS's order.
  final List<LvsPlanGoal> goals;

  /// The name of the uploaded file of a document (`fileName`); empty for the
  /// other kinds.
  final String fileName;

  /// The kind of file of a document as the LVS names it (`mime.type`);
  /// empty when none.
  final String mimeType;

  const LvsPlanItem({
    required this.id,
    required this.type,
    required this.kind,
    this.fromGroupPlan = false,
    this.versionId,
    this.versionType = '',
    this.author = '',
    this.date = '',
    this.supportNeeds = const [],
    this.mainGoals = const [],
    this.workGoals = const [],
    this.approach = const [],
    this.approachComment = '',
    this.approachCommentHtml = '',
    this.courses = const [],
    this.theme = '',
    this.startSituation = '',
    this.startSituationHtml = '',
    this.goals = const [],
    this.fileName = '',
    this.mimeType = '',
  });

  /// Shows the kind and the counts only: the item is about a pupil.
  @override
  String toString() =>
      'LvsPlanItem(kind: ${kind.name}, supportNeeds: ${supportNeeds.length}, '
      'mainGoals: ${mainGoals.length}, workGoals: ${workGoals.length}, '
      'approach: ${approach.length}, goals: ${goals.length})';
}

/// A goal of a [LvsPlanItemKind.goals] item: an entry of
/// `lastversion.doelen`, `{parentID, parentName, path, parentDeprecated,
/// doelstellingen, aanpak, occurrence}`.
class LvsPlanGoal {
  /// The goal's ID (`parentID`); `null` when none.
  final int? id;

  /// The goal (`parentName`), as plain text.
  final String name;

  /// The domain the goal is in, as its path (`path`); empty when none.
  final String domain;

  /// Whether the goal is no longer in its curriculum (`parentDeprecated`).
  final bool isDeprecated;

  /// The objectives ("doelstellingen", their `doelName`).
  final List<String> objectives;

  /// The approach ("aanpak", their `aanpakName`).
  final List<String> approach;

  /// When it is worked on ("planning", `occurrence`: their `occName`, a
  /// course or another moment).
  final List<String> planning;

  const LvsPlanGoal({
    this.id,
    required this.name,
    this.domain = '',
    this.isDeprecated = false,
    this.objectives = const [],
    this.approach = const [],
    this.planning = const [],
  });

  /// Shows the counts only.
  @override
  String toString() =>
      'LvsPlanGoal(objectives: ${objectives.length}, '
      'approach: ${approach.length}, planning: ${planning.length})';
}

/// A pupil's profile sketch ("profielschets") in one period
/// (`LvsService.getProfileSketch`): a text about the pupil, written by the
/// school.
class LvsProfileSketch {
  /// The period of the sketch.
  final LvsPlanPeriodInfo period;

  /// Whether there is a sketch (the LVS's `check`). Without one the LVS
  /// sends a message of its own in the sketch's place (seen live), which is
  /// left out: [html] and [text] are empty.
  final bool hasSketch;

  /// The sketch as HTML (`content`); empty without a sketch.
  final String html;

  /// The sketch as plain text; empty without a sketch.
  final String text;

  /// The last change as the LVS shows it (`lastrevision`): a text, kept as
  /// it comes; empty without a sketch.
  final String lastRevision;

  const LvsProfileSketch({
    required this.period,
    required this.hasSketch,
    this.html = '',
    this.text = '',
    this.lastRevision = '',
  });

  /// Shows the flag only: the sketch is about a pupil.
  @override
  String toString() => 'LvsProfileSketch(hasSketch: $hasSketch)';
}
