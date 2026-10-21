/// Models for Smartschool's pupil tracking system (LVS, "leerlingvolgsysteem",
/// `/?module=LVS`, #160): a pupil found by name, and the overview of one
/// pupil's file: who, which class, today's attendance, and which sections of
/// the file hold something; the notes of a pupil, per category (#161).
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

import 'lvs_time.dart';

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

  /// The categories of notes of the file (#161): its sections of type
  /// [LvsSectionType.items], top level first, in the LVS's order, each with
  /// its sub-categories ([LvsCategory.subcategories]: the sections of that
  /// type under it). A category under a section of another type (a heading of
  /// the school's own) is listed where that section is.
  ///
  /// The categories are the school's own: the library does not know
  /// "behaviour" or "care" by name. `LvsService.getNotes` reads the notes of
  /// one by its [LvsCategory.id].
  List<LvsCategory> get noteCategories =>
      LvsCategory._ofSections(sections, LvsSectionType.items);

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

/// A category of notes of a pupil's file in the LVS (#161), with its
/// sub-categories: a section of type [LvsSectionType.items] of
/// [LvsPupilFile.noteCategories].
///
/// The categories are made by each school ("gedrag", "zorg", "oudercontact",
/// ...): the library lists them, it does not know them by name.
/// `LvsService.getNotes` reads the notes of one by its [id], with those of
/// its sub-categories.
class LvsCategory {
  /// The category ID (the section's `id`), which `LvsService.getNotes`
  /// takes as `categoryId`.
  final int id;

  /// The name of the category as the school's LVS shows it.
  final String name;

  /// Whether the category is only a heading for its sub-categories
  /// (`isTitle`).
  final bool isTitle;

  /// Whether the category holds notes for this pupil (`hasItems`).
  final bool hasNotes;

  /// Whether it holds notes the account has not seen yet (`hasNewItems`).
  final bool hasNewNotes;

  /// The sub-categories, in the LVS's order; empty when it has none.
  final List<LvsCategory> subcategories;

  const LvsCategory({
    required this.id,
    required this.name,
    this.isTitle = false,
    required this.hasNotes,
    required this.hasNewNotes,
    this.subcategories = const [],
  });

  /// The categories of [type] in [sections]: each section of that type with
  /// the ones under it, and those under a section of another type in its
  /// place.
  static List<LvsCategory> _ofSections(
    List<LvsSection> sections,
    String type,
  ) => [
    for (final section in sections)
      if (section.type == type)
        LvsCategory(
          id: section.id,
          name: section.name,
          isTitle: section.isTitle,
          hasNotes: section.hasItems,
          hasNewNotes: section.hasNewItems,
          subcategories: _ofSections(section.children, type),
        )
      else
        ..._ofSections(section.children, type),
  ];

  /// Every sub-category, at any depth, depth first.
  Iterable<LvsCategory> get descendants sync* {
    for (final sub in subcategories) {
      yield sub;
      yield* sub.descendants;
    }
  }

  /// Shows the counts only: the name is the school's own.
  @override
  String toString() =>
      'LvsCategory(hasNotes: $hasNotes, hasNewNotes: $hasNewNotes, '
      'subcategories: ${subcategories.length})';
}

/// The period of the notes `LvsService.getNotes` and `getAllNotes` read
/// (#161): a school year, from its first to its last day, sent to the LVS
/// as its page does (`syRange`: `{"from": "YYYY-MM-DD", "until":
/// "YYYY-MM-DD"}`).
///
/// A school year in Belgium runs from 1 September to 31 August
/// ([LvsSchoolYear.starting]); [LvsSchoolYear.current] is the one of today,
/// in Belgian time. Any other range of days can be given too: the LVS page
/// itself sends the period of the user's own settings.
class LvsSchoolYear {
  /// The first day (its year, month and day; the time is not used).
  final DateTime from;

  /// The last day (its year, month and day; the time is not used).
  final DateTime until;

  /// The days [from] to [until]. `LvsService` refuses a range whose
  /// [until] is before [from] ([isEmpty]) with an `ArgumentError`, before
  /// anything is sent.
  const LvsSchoolYear({required this.from, required this.until});

  /// The school year that starts on 1 September of [year] and ends on
  /// 31 August of the year after: `LvsSchoolYear.starting(2030)` is
  /// 2030-2031.
  factory LvsSchoolYear.starting(int year) => LvsSchoolYear(
    from: DateTime.utc(year, DateTime.september),
    until: DateTime.utc(year + 1, DateTime.august, 31),
  );

  /// The school year that holds the calendar day [day] (its year, month and
  /// day fields).
  factory LvsSchoolYear.containing(DateTime day) => LvsSchoolYear.starting(
    day.month >= DateTime.september ? day.year : day.year - 1,
  );

  /// The school year of today in Belgian time (of [now], when given): it
  /// starts on 1 September, 00:00 in Brussels.
  factory LvsSchoolYear.current({DateTime? now}) =>
      LvsSchoolYear.containing(brusselsWallTime(now ?? DateTime.now()));

  /// [from] as `YYYY-MM-DD`.
  String get firstDay => isoDay(from);

  /// [until] as `YYYY-MM-DD`.
  String get lastDay => isoDay(until);

  /// Whether [until] is before [from] (by their days).
  bool get isEmpty => lastDay.compareTo(firstDay) < 0;

  @override
  bool operator ==(Object other) =>
      other is LvsSchoolYear &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay;

  @override
  int get hashCode => Object.hash(firstDay, lastDay);

  /// Shows the days: they are not a pupil's.
  @override
  String toString() => 'LvsSchoolYear($firstDay - $lastDay)';
}

/// A note in a pupil's file in the LVS (#161): an item of a category of
/// notes ("gedrag", "zorg", a talk with the parents, ...), with its fields.
///
/// What a note says is in its [fields]: the category decides which fields a
/// note has (a text, a choice, a date, attachments, ...), each with its
/// label. The [title] is the note's own title.
///
/// The LVS decides which notes the account receives, confidential ones
/// included: a confidential note ("Dit is vertrouwelijke informatie") comes
/// with [isConfidential] `true`, and is not left out. What to show is the
/// app's choice.
class LvsNote {
  /// The note's ID (`itemID`).
  final int id;

  /// The ID of the note's category (`catID`): the category read, or one of
  /// its sub-categories.
  final int categoryId;

  /// The name of the note's category as the LVS gives it (`catName`, or the
  /// name of the category read); empty when the answer names none.
  final String categoryName;

  /// The note's title; empty when it has none.
  final String title;

  /// When the note was made, as the LVS dates it (a Unix time), in UTC.
  final DateTime date;

  /// The name of who wrote the note, as the LVS shows it.
  final String author;

  /// Whether the note is confidential (`privateFile`).
  final bool isConfidential;

  /// Whether the LVS marks the note as new for the account (`isNew`).
  final bool isNew;

  /// Whether the note is marked as viewed for the account (`viewed`).
  final bool viewed;

  /// The school year of the note as the LVS gives it (`schoolyear`); empty
  /// when it gives none.
  final String schoolYear;

  /// The fields of the note, in the LVS's order.
  final List<LvsNoteField> fields;

  const LvsNote({
    required this.id,
    required this.categoryId,
    required this.categoryName,
    required this.title,
    required this.date,
    required this.author,
    required this.isConfidential,
    required this.isNew,
    required this.viewed,
    required this.schoolYear,
    required this.fields,
  });

  /// Shows the count of fields only: the values are a pupil's.
  @override
  String toString() => 'LvsNote(fields: ${fields.length})';
}

/// The types of a field of an LVS note ([LvsNoteField.type]), by the LVS's
/// type numbers ([LvsNoteField.typeCode]).
enum LvsNoteFieldType {
  /// `1`: a line of text.
  text(1),

  /// `2`: a rich text, HTML ([LvsNoteField.html]).
  richText(2),

  /// `3`: one option of a list (radio buttons).
  radio(3),

  /// `4`: options of a list (check boxes).
  checkbox(4),

  /// `5`: one option of a drop-down list.
  select(5),

  /// `6`: attachments ([LvsNoteField.attachments]).
  attachment(6),

  /// `7`: a date ([LvsNoteField.date]).
  date(7),

  /// `8`: a heading between the fields, without a value.
  heading(8),

  /// A type the library does not know: its values are kept as they come
  /// ([LvsNoteField.rawValue], [LvsNoteField.rawOptionValue]).
  unknown(0);

  const LvsNoteFieldType(this.code);

  /// The LVS's number for the type; `0` for [unknown].
  final int code;

  /// The type of the LVS's number [code]; [unknown] for any other.
  static LvsNoteFieldType of(int code) {
    for (final type in values) {
      if (type != unknown && type.code == code) return type;
    }
    return unknown;
  }

  /// Whether the field holds options ([radio], [checkbox], [select]).
  bool get hasOptions => this == radio || this == checkbox || this == select;
}

/// A field of an LVS note (#161): its label and its value, as the LVS's web
/// client shows them.
///
/// [value] is the text to show, for every type: the text, the rich text as
/// plain text, the chosen option(s) as the LVS names them, the day of a date
/// (`YYYY-MM-DD`, Belgian time), the names of the attachments (one per
/// line); empty for a heading and for a field left empty. The other getters
/// hold what a type adds ([html], [optionIds], [date], [attachments]);
/// [rawValue] and [rawOptionValue] what the LVS sent.
class LvsNoteField {
  /// The ID of the category's field (`paramID`).
  final int paramId;

  /// The LVS's type number (`type`), also for a type the library does not
  /// know.
  final int typeCode;

  /// The type ([LvsNoteFieldType.unknown] for one the library does not
  /// know).
  final LvsNoteFieldType type;

  /// The field's label (`title`); for a heading, its text.
  final String label;

  /// The text to show (see the class doc); empty when there is none.
  final String value;

  /// The HTML of a rich text ([LvsNoteFieldType.richText]); `null` for the
  /// other types.
  final String? html;

  /// The IDs of the chosen options of a choice (`val`); empty for the other
  /// types and when none is chosen. Their texts are in [value].
  final List<int> optionIds;

  /// The moment of a date field, in UTC (`val`, a Unix time); `null` for the
  /// other types, and when the field holds no time (empty, or the LVS's
  /// `current`, kept in [value]).
  final DateTime? date;

  /// The attachments of an attachment field: their metadata only; empty for
  /// the other types.
  final List<LvsAttachment> attachments;

  /// The field's `val` as the LVS sent it.
  final String rawValue;

  /// The field's `optionValue` as the LVS sent it (the options' texts, the
  /// attachments as JSON, a heading's level).
  final String rawOptionValue;

  const LvsNoteField({
    required this.paramId,
    required this.typeCode,
    required this.type,
    required this.label,
    required this.value,
    this.html,
    this.optionIds = const [],
    this.date,
    this.attachments = const [],
    required this.rawValue,
    required this.rawOptionValue,
  });

  /// Whether the field holds something to show: a [value] or an
  /// attachment. A heading holds nothing.
  bool get hasValue => value.isNotEmpty || attachments.isNotEmpty;

  /// Shows the type only: the values are a pupil's.
  @override
  String toString() => 'LvsNoteField(type: ${type.name})';
}

/// An attachment of an LVS note: its metadata only (#161). The library does
/// not download it.
class LvsAttachment {
  /// The file's ID (the key of the field's `optionValue`).
  final int id;

  /// The file's name (`fileName`).
  final String name;

  /// The file's media type (`fileMime`), such as `application/pdf`; empty
  /// when the LVS gives none.
  final String mimeType;

  const LvsAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
  });

  /// Shows no value: a file name can name a pupil.
  @override
  String toString() => 'LvsAttachment(<values hidden>)';
}
