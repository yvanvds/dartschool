// What the live notes case of lvs_live_test.dart reads and compares (#161,
// #177, #180), offline-tested in lvs_notes_check_test.dart.
//
// The file overview flags a category that holds notes in any school year
// (LvsCategory.hasNotes), and getNotes reads one school year: the first
// category flagged can hold older notes only, and then its notes are an
// empty list, on which every check of the case held (#177). So the case
// reads the "all items" view (getAllNotes) of the school year first, picks a
// category that holds notes in it, and compares getNotes for that category
// with the notes of the category and its sub-categories in that view.
//
// getNotes missed a note of the view in the developer's run (#180). To tell
// the likely causes apart in one run, the comparison also counts where the
// missing notes are (the category itself or a sub-category, dated outside
// the school year), and LvsNotesInYear counts the notes of the view that
// fall outside the school year read, by their date and by their label.
//
// The classes print counts only, never an ID or a value of an answer
// (doc/lvs-privacy.md, rule 4): their toString() says counts only. What they
// keep besides (a category, a note) is for the live case to read next, never
// to print.
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/models/lvs_time.dart';

/// Every category of [roots] and every sub-category, at any depth, depth
/// first, in the LVS's order.
List<LvsCategory> flattenNoteCategories(Iterable<LvsCategory> roots) => [
  for (final category in roots) ...[category, ...category.descendants],
];

/// The IDs of [category] and of its sub-categories at any depth: the
/// categories whose notes `getNotes` reads for it.
Set<int> _idsOf(LvsCategory category) => {
  category.id,
  for (final sub in category.descendants) sub.id,
};

/// Whether [note] is dated in [year]: its day in Belgian time, the LVS's
/// (lvs_time.dart), from the year's first day to its last, both included,
/// as the days of the `syRange` the notes were read for.
bool _isDatedIn(LvsNote note, LvsSchoolYear year) {
  final day = isoDay(brusselsWallTime(note.date));
  return day.compareTo(year.firstDay) >= 0 && day.compareTo(year.lastDay) <= 0;
}

/// A school year label of a note (`schoolyear`): one year, the first of the
/// school year (`2030` for 2030-2031, as the fixtures of
/// test/fixtures/lvs/notes/ write it; its live form was not seen), or two
/// (`2030-2031`).
final _yearLabel = RegExp(r'^(\d{4})(?:\s*-\s*(\d{4}))?$');

/// Whether the school year label of [note] names [year]; `null` when the
/// label is empty or of neither form of [_yearLabel].
bool? _isLabelledWith(LvsNote note, LvsSchoolYear year) {
  final match = _yearLabel.firstMatch(note.schoolYear.trim());
  if (match == null) return null;
  final second = match[2];
  return int.parse(match[1]!) == year.from.year &&
      (second == null || int.parse(second) == year.until.year);
}

/// The categories of a pupil's file that the live case reads with
/// `getNotes`, picked by the notes of the "all items" view of one school
/// year. A heading (`isTitle`) is never picked: its sub-categories are.
class LvsNotePicks {
  LvsNotePicks._({
    required this.withNotes,
    required this.flaggedWithoutNotes,
    required this.categoriesWithNotes,
    required this.categoriesFlaggedWithoutNotes,
    required this.notesOfUnlistedCategories,
  });

  /// Picks from the categories [roots] of a file
  /// (`LvsPupilFile.noteCategories`) by [all], its "all items" view
  /// (`getAllNotes`) of the school year.
  factory LvsNotePicks.of(Iterable<LvsCategory> roots, List<LvsNote> all) {
    final categories = flattenNoteCategories(roots);
    final inYear = {for (final note in all) note.categoryId};
    bool holdsNotes(LvsCategory c) => _idsOf(c).any(inYear.contains);
    final readable = categories.where((c) => !c.isTitle);
    final withNotes = readable.where(holdsNotes);
    final flaggedWithout = readable.where((c) => c.hasNotes && !holdsNotes(c));
    final listed = {for (final c in categories) c.id};
    return LvsNotePicks._(
      withNotes: withNotes.firstOrNull,
      flaggedWithoutNotes: flaggedWithout.firstOrNull,
      categoriesWithNotes: withNotes.length,
      categoriesFlaggedWithoutNotes: flaggedWithout.length,
      notesOfUnlistedCategories: all
          .where((n) => !listed.contains(n.categoryId))
          .length,
    );
  }

  /// The first category, depth first, that holds notes in the school year,
  /// itself or in a sub-category; `null` when none does.
  final LvsCategory? withNotes;

  /// The first category, depth first, that the file flags with notes, but
  /// that holds none in the school year, itself or in a sub-category: one
  /// with older notes only. `null` when there is none.
  final LvsCategory? flaggedWithoutNotes;

  /// How many categories hold notes in the school year.
  final int categoriesWithNotes;

  /// How many categories are flagged with notes but hold none in it.
  final int categoriesFlaggedWithoutNotes;

  /// How many notes of the view are of a category the file does not list.
  final int notesOfUnlistedCategories;

  /// Counts only: the names and IDs are the school's and the pupil's.
  @override
  String toString() =>
      'categories with notes in the school year: $categoriesWithNotes, '
      'flagged with notes but without any in it: '
      '$categoriesFlaggedWithoutNotes, notes of a category the file does not '
      'list: $notesOfUnlistedCategories';
}

/// How many notes of an answer read for a school year fall outside it
/// (#180): by their date, and by their school year label (`schoolyear`),
/// two counts, since the two can disagree. Counts only.
class LvsNotesInYear {
  LvsNotesInYear._({
    required this.datedOutside,
    required this.labelledOutside,
    required this.unlabelled,
  });

  /// Counts the notes of [notes], an answer read for [year], outside it.
  factory LvsNotesInYear.of(List<LvsNote> notes, LvsSchoolYear year) =>
      LvsNotesInYear._(
        datedOutside: notes.where((n) => !_isDatedIn(n, year)).length,
        labelledOutside: notes
            .where((n) => _isLabelledWith(n, year) == false)
            .length,
        unlabelled: notes.where((n) => _isLabelledWith(n, year) == null).length,
      );

  /// How many notes are dated outside the school year: their day in
  /// Belgian time is before its first day or after its last.
  final int datedOutside;

  /// How many notes have the school year label of another school year.
  final int labelledOutside;

  /// How many notes have no school year label, or one that is neither a
  /// year nor two (`2030`, `2030-2031`): counted neither in nor outside.
  final int unlabelled;

  /// Counts only.
  @override
  String toString() =>
      'dated outside the school year read: $datedOutside, labelled with '
      'another school year: $labelledOutside, with no school year label '
      'read: $unlabelled';
}

/// How the notes `getNotes` read for a category compare with those of the
/// category and its sub-categories in the "all items" view of the same
/// school year: by their IDs, as counts.
class LvsNotesComparison {
  LvsNotesComparison._({
    required this.expected,
    required this.read,
    required this.duplicates,
    required this.missing,
    required this.missingOwn,
    required this.missingInSubcategories,
    required this.missingDatedOutside,
    required this.firstMissingInSubcategory,
    required this.subcategories,
    required this.extra,
    required this.outside,
  });

  /// Compares [read], what `getNotes` read for [category] in [schoolYear],
  /// with [all], the "all items" view (`getAllNotes`) of the same school
  /// year.
  factory LvsNotesComparison.of({
    required LvsCategory category,
    required LvsSchoolYear schoolYear,
    required List<LvsNote> all,
    required List<LvsNote> read,
  }) {
    final ids = _idsOf(category);
    final expected = {
      for (final note in all)
        if (ids.contains(note.categoryId)) note.id,
    };
    final got = {for (final note in read) note.id};
    final missing = expected.difference(got);
    // The missing notes in the view's order, each once.
    final seen = <int>{};
    final missingNotes = [
      for (final note in all)
        if (missing.contains(note.id) && seen.add(note.id)) note,
    ];
    final inSubcategories = missingNotes
        .where((n) => n.categoryId != category.id)
        .toList();
    return LvsNotesComparison._(
      expected: expected.length,
      read: read.length,
      duplicates: read.length - got.length,
      missing: missing.length,
      missingOwn: missingNotes.length - inSubcategories.length,
      missingInSubcategories: inSubcategories.length,
      missingDatedOutside: missingNotes
          .where((n) => !_isDatedIn(n, schoolYear))
          .length,
      firstMissingInSubcategory: inSubcategories.firstOrNull,
      subcategories: category.descendants.length,
      extra: got.difference(expected).length,
      outside: read.where((n) => !ids.contains(n.categoryId)).length,
    );
  }

  /// How many notes of the category and its sub-categories the view has.
  final int expected;

  /// How many notes `getNotes` read.
  final int read;

  /// How many notes `getNotes` read more than once.
  final int duplicates;

  /// How many notes of the category in the view `getNotes` did not read.
  final int missing;

  /// How many of the [missing] notes are of the category itself.
  final int missingOwn;

  /// How many of the [missing] notes are of a sub-category of it, at any
  /// depth.
  final int missingInSubcategories;

  /// How many of the [missing] notes are dated outside the school year read
  /// (as [LvsNotesInYear.datedOutside]).
  final int missingDatedOutside;

  /// The first of the [missing] notes, in the view's order, that is of a
  /// sub-category: the one whose sub-category the live case reads on its
  /// own (#180). `null` when none is. Never to print: it is a pupil's.
  final LvsNote? firstMissingInSubcategory;

  /// How many sub-categories the category has, at any depth.
  final int subcategories;

  /// How many notes `getNotes` read that the view does not have for the
  /// category.
  final int extra;

  /// How many notes `getNotes` read whose category is neither the category
  /// read nor one of its sub-categories.
  final int outside;

  /// Whether `getNotes` read the notes the view has for the category, each
  /// once, and no other.
  bool get isSame =>
      duplicates == 0 && missing == 0 && extra == 0 && outside == 0;

  /// Whether [ofSubcategory], what `getNotes` read for the sub-category of
  /// [firstMissingInSubcategory], holds that note (by its ID); `null` when
  /// no missing note is of a sub-category.
  bool? holdsFirstMissingInSubcategory(List<LvsNote> ofSubcategory) {
    final note = firstMissingInSubcategory;
    if (note == null) return null;
    return ofSubcategory.any((n) => n.id == note.id);
  }

  /// Counts only.
  @override
  String toString() =>
      'in the "all items" view: $expected, read: $read, missing: $missing '
      '(of the category itself: $missingOwn, of a sub-category: '
      '$missingInSubcategories, dated outside the school year: '
      '$missingDatedOutside), extra: $extra, of another category: $outside, '
      'twice: $duplicates; sub-categories of the category: $subcategories';
}
