/// Models for Smartschool's pupil tracking system (LVS, "leerlingvolgsysteem",
/// `/?module=LVS`, #160): a pupil found by name, and the overview of one
/// pupil's file: who, which class, today's attendance, and which sections of
/// the file hold something.
///
/// The LVS is an **internal** Smartschool module, not part of the official
/// (public) API, and it holds the most sensitive data Smartschool has. So
/// these models never print their values: their `toString()` shows counts
/// only, since an app logs what it prints (`doc/lvs-privacy.md`, rule 6).
///
/// A pupil ID ([LvsPupilMatch.pupilId], [LvsPupilFile.pupilId]) is the
/// Smartschool user ID of the pupil. A class ID ([LvsPupilMatch.classId],
/// [LvsPupilFile.classId]) is the ID of the class group, the `classID` of the
/// LVS (the `groupID` of Presence).
library;

/// A pupil whose name matches a search of the LVS
/// (`LvsService.searchPupils`), with their class.
class LvsPupilMatch {
  /// The pupil's Smartschool user ID (the LVS's `userID`).
  final int pupilId;

  /// The ID of the pupil's class (`classID`), which
  /// `LvsService.getPupilFile` takes with [pupilId].
  final int classId;

  /// The pupil's name as the LVS lists it, as plain text: the LVS's
  /// `foundName` without the markup that highlights the match.
  final String name;

  /// The name of the pupil's class (`className`), such as `1A`.
  final String className;

  const LvsPupilMatch({
    required this.pupilId,
    required this.classId,
    required this.name,
    required this.className,
  });

  /// Shows no value: the name and the IDs are a pupil's.
  @override
  String toString() => 'LvsPupilMatch(<values hidden>)';
}

/// The overview of one pupil's file in the LVS
/// (`LvsService.getPupilFile`): who, which class, today's attendance, and
/// the sections of the file with whether each holds something.
///
/// The sections are those of the school's LVS, the same for every pupil;
/// [LvsSection.hasItems] and [LvsSection.hasNewItems] are about this pupil.
/// What a section holds is read by the reads that follow (notes per
/// category, results, support plans, absences: #161 to #164).
class LvsPupilFile {
  /// The pupil's Smartschool user ID (`pupilID`).
  final int pupilId;

  /// The ID of the class the file was read in (`classID`).
  final int classId;

  /// The pupil's name as the LVS shows it (`name`).
  final String name;

  /// The name of the pupil's class (`class`), such as `1A`.
  final String className;

  /// The description of the class (`classDesc`); empty when the LVS gives
  /// none.
  final String classDescription;

  /// The class teachers ("titularissen", `teachers`), in the LVS's order;
  /// empty when the class has none.
  final List<LvsTeacher> teachers;

  /// The sections of the file (`categories`), top level first, in the LVS's
  /// order, each with its own [LvsSection.children].
  final List<LvsSection> sections;

  /// The pupil's attendance today (`getStatusInfo`).
  final LvsTodayStatus todayStatus;

  const LvsPupilFile({
    required this.pupilId,
    required this.classId,
    required this.name,
    required this.className,
    required this.classDescription,
    required this.teachers,
    required this.sections,
    required this.todayStatus,
  });

  /// Every section of the file, at any depth: each section followed by its
  /// children (depth first), in the LVS's order.
  Iterable<LvsSection> get allSections sync* {
    for (final section in sections) {
      yield section;
      yield* section.descendants;
    }
  }

  /// Shows counts only: the values are a pupil's.
  @override
  String toString() =>
      'LvsPupilFile(sections: ${allSections.length}, '
      'teachers: ${teachers.length}, '
      'todayStatus: ${todayStatus.halfDays.length} half-days)';
}

/// A class teacher of a pupil ("titularis"), as the LVS names them in a
/// pupil's file.
class LvsTeacher {
  /// The teacher's Smartschool user ID.
  final int id;

  /// The teacher's name as the LVS shows it.
  final String name;

  const LvsTeacher({required this.id, required this.name});

  /// Shows no value.
  @override
  String toString() => 'LvsTeacher(<values hidden>)';
}

/// The types of [LvsSection] that the LVS's web client knows
/// ([LvsSection.type]), as the LVS names them.
///
/// The LVS may send others: [LvsSection.type] keeps any type as it comes.
abstract final class LvsSectionType {
  /// A category of notes ("items"); its [LvsSection.id] is the category ID.
  static const items = 'items';

  /// A category of support plans ("handelingsplannen"); its [LvsSection.id]
  /// is the category ID.
  static const supportPlans = 'handelingsplannen';

  /// The pupil's reports in Skore.
  static const skore = 'skore';

  /// The pupil's results.
  static const results = 'results';

  /// The class council's deliberations.
  static const deliberation = 'deliberation';

  /// Forms.
  static const forms = 'forms';

  /// Contact moments.
  static const contactMoments = 'contact_moments';

  /// Absences.
  static const absences = 'absents';

  /// The pupil's whole school career ("Alle informatie").
  static const career = 'career';

  /// Messages kept in the LVS.
  static const messages = 'messages';

  /// Smartsignal.
  static const smartSignal = 'smartsignal';

  /// Every type above.
  static const known = {
    items,
    supportPlans,
    skore,
    results,
    deliberation,
    forms,
    contactMoments,
    absences,
    career,
    messages,
    smartSignal,
  };
}

/// A section of a pupil's file in the LVS: a category of notes, a category
/// of support plans, or one of the LVS's own parts (results, absences, ...).
class LvsSection {
  /// The ID of the section (`id`). For a category of notes or of support
  /// plans ([LvsSectionType.items], [LvsSectionType.supportPlans]) it is the
  /// category ID; the LVS's own parts have `0`, so it is not unique.
  final int id;

  /// The type of the section as the LVS names it (`type`): one of
  /// [LvsSectionType], or another the LVS sends, kept as it comes.
  final String type;

  /// The name of the section as the school's LVS shows it (`name`).
  final String name;

  /// Whether the section is only a heading for the sections under it
  /// (`isTitle`).
  final bool isTitle;

  /// Whether the section holds something for this pupil (`hasItems`).
  final bool hasItems;

  /// Whether the section holds something the account has not seen yet
  /// (`hasNewItems`).
  final bool hasNewItems;

  /// The sections under this one (`children`), in the LVS's order; empty when
  /// it has none.
  final List<LvsSection> children;

  const LvsSection({
    required this.id,
    required this.type,
    required this.name,
    this.isTitle = false,
    required this.hasItems,
    required this.hasNewItems,
    this.children = const [],
  });

  /// Whether [type] is one of [LvsSectionType.known].
  bool get isKnownType => LvsSectionType.known.contains(type);

  /// Every section under this one, at any depth, depth first.
  Iterable<LvsSection> get descendants sync* {
    for (final child in children) {
      yield child;
      yield* child.descendants;
    }
  }

  /// Shows the type and the counts only: the name can be a school's own.
  @override
  String toString() =>
      'LvsSection(type: $type, hasItems: $hasItems, '
      'hasNewItems: $hasNewItems, children: ${children.length})';
}

/// A pupil's attendance today, as the LVS shows it on a pupil's file
/// (`getStatusInfo`): the code of each half-day that has one.
class LvsTodayStatus {
  /// The half-days that have a code, in the LVS's order. Empty when today
  /// has none (no school, or nothing registered yet).
  final List<LvsHalfDayStatus> halfDays;

  const LvsTodayStatus(this.halfDays);

  /// No half-day with a code.
  static const none = LvsTodayStatus([]);

  /// The morning's code (`partOfDay` `am`), or `null`.
  LvsHalfDayStatus? get am => _of('am');

  /// The afternoon's code (`partOfDay` `pm`), or `null`.
  LvsHalfDayStatus? get pm => _of('pm');

  LvsHalfDayStatus? _of(String partOfDay) {
    for (final halfDay in halfDays) {
      if (halfDay.partOfDay == partOfDay) return halfDay;
    }
    return null;
  }

  /// Shows the count only.
  @override
  String toString() => 'LvsTodayStatus(halfDays: ${halfDays.length})';
}

/// The attendance code of a half-day of today, on a pupil's file in the LVS.
class LvsHalfDayStatus {
  /// The half-day as the LVS names it (`partOfDay`): `am` (morning) or `pm`
  /// (afternoon); another value is kept as it comes.
  final String partOfDay;

  /// The short code (`code.code`), as the school's Presence codes name it.
  final String code;

  /// The name of the code (`code.name`).
  final String name;

  /// The colour the LVS shows the code in (`code.color`: `green`, `red` or
  /// `yellow` in the web client), or `null` when it gives none.
  final String? color;

  const LvsHalfDayStatus({
    required this.partOfDay,
    required this.code,
    required this.name,
    this.color,
  });

  /// Shows the half-day only.
  @override
  String toString() => 'LvsHalfDayStatus(partOfDay: $partOfDay)';
}
