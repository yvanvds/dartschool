// What the live notes case of lvs_live_test.dart reads and compares (#161,
// #177, #180), offline-tested in lvs_notes_check_test.dart.
//
// The file overview flags a category that holds notes in any school year
// (LvsCategory.hasNotes), and getNotes reads one school year: the first
// category flagged can hold older notes only, and then its notes are an
// empty list, on which every check of the case held (#177). So the case
// reads the "all items" view (getAllNotes) of the school year first, picks a
// category that holds notes of its own in it, and compares getNotes for that
// category with the category's notes in that view.
//
// A category's notes are its own: getNotes never reads those of its
// sub-categories (seen live, #180: a parent read without the note of its
// sub-category, the sub-category read with it). And the LVS does not keep
// to the school year it is sent (#180: most notes of the view were of other
// school years): the library keeps the notes of the school year itself
// (LvsSchoolYear.includesNote), and LvsNotesInYear counts the notes of an
// answer that are not of it, by that rule, by their date and by their label,
// so that the case asserts that both reads hold notes of the year only.
//
// The classes print counts only, never an ID or a value of an answer
// (doc/lvs-privacy.md, rule 4): their toString() says counts only. What they
// keep besides (a category) is for the live case to read next, never to
// print.
import 'package:flutter_smartschool/flutter_smartschool.dart';

/// Every category of [roots] and every sub-category, at any depth, depth
/// first, in the LVS's order.
List<LvsCategory> flattenNoteCategories(Iterable<LvsCategory> roots) => [
  for (final category in roots) ...[category, ...category.descendants],
];

/// The categories of a pupil's file that the live case reads with
/// `getNotes`, picked by their own notes in the "all items" view of one
/// school year. A heading (`isTitle`) is never picked: its sub-categories
/// are.
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
    bool holdsNotes(LvsCategory c) => inYear.contains(c.id);
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

  /// The first category, depth first, that holds notes of its own in the
  /// school year (not counting those of its sub-categories); `null` when
  /// none does.
  final LvsCategory? withNotes;

  /// The first category, depth first, that the file flags with notes, but
  /// that holds none of its own in the school year: one with older notes
  /// only, or whose notes are its sub-categories'. `null` when there is
  /// none.
  final LvsCategory? flaggedWithoutNotes;

  /// How many categories hold notes of their own in the school year.
  final int categoriesWithNotes;

  /// How many categories are flagged with notes but hold none of their own
  /// in it.
  final int categoriesFlaggedWithoutNotes;

  /// How many notes of the view are of a category the file does not list.
  final int notesOfUnlistedCategories;

  /// Counts only: the names and IDs are the school's and the pupil's.
  @override
  String toString() =>
      'categories with notes of their own in the school year: '
      '$categoriesWithNotes, flagged with notes but without any of their own '
      'in it: $categoriesFlaggedWithoutNotes, notes of a category the file '
      'does not list: $notesOfUnlistedCategories';
}

/// How many notes of an answer read for a school year are not of it (#180):
/// by the library's rule ([LvsSchoolYear.includesNote]: the label, the date
/// without one), and, apart, by their date and by their school year label
/// (`schoolyear`), since the two can disagree. Counts only.
class LvsNotesInYear {
  LvsNotesInYear._({
    required this.outside,
    required this.datedOutside,
    required this.labelledOutside,
    required this.unlabelled,
  });

  /// Counts the notes of [notes], an answer read for [year], not of it.
  factory LvsNotesInYear.of(List<LvsNote> notes, LvsSchoolYear year) {
    final labels = [
      for (final n in notes) LvsSchoolYear.tryParse(n.schoolYear),
    ];
    return LvsNotesInYear._(
      outside: notes.where((n) => !year.includesNote(n)).length,
      datedOutside: notes.where((n) => !year.includesDay(n.date)).length,
      labelledOutside: labels.where((l) => l != null && l != year).length,
      unlabelled: labels.where((l) => l == null).length,
    );
  }

  /// How many notes are not of the school year, as the library keeps them
  /// ([LvsSchoolYear.includesNote]): the notes `getNotes` and `getAllNotes`
  /// leave out. `0` for what they return.
  final int outside;

  /// How many notes are dated outside the school year: their day in
  /// Belgian time is before its first day or after its last.
  final int datedOutside;

  /// How many notes have the school year label of another school year.
  final int labelledOutside;

  /// How many notes have no school year label, or one that names no school
  /// year ([LvsSchoolYear.tryParse] reads none): counted neither in nor
  /// outside by their label.
  final int unlabelled;

  /// Counts only.
  @override
  String toString() =>
      'not of the school year read: $outside (dated outside it: '
      '$datedOutside, labelled with another school year: $labelledOutside, '
      'with no school year label read: $unlabelled)';
}

/// How the notes `getNotes` read for a category compare with the
/// category's own notes in the "all items" view of the same school year:
/// by their IDs, as counts.
class LvsNotesComparison {
  LvsNotesComparison._({
    required this.expected,
    required this.read,
    required this.duplicates,
    required this.missing,
    required this.extra,
    required this.outside,
  });

  /// Compares [read], what `getNotes` read for [category], with [all], the
  /// "all items" view (`getAllNotes`) of the same school year.
  factory LvsNotesComparison.of({
    required LvsCategory category,
    required List<LvsNote> all,
    required List<LvsNote> read,
  }) {
    final expected = {
      for (final note in all)
        if (note.categoryId == category.id) note.id,
    };
    final got = {for (final note in read) note.id};
    return LvsNotesComparison._(
      expected: expected.length,
      read: read.length,
      duplicates: read.length - got.length,
      missing: expected.difference(got).length,
      extra: got.difference(expected).length,
      outside: read.where((n) => n.categoryId != category.id).length,
    );
  }

  /// How many notes of the category itself the view has.
  final int expected;

  /// How many notes `getNotes` read.
  final int read;

  /// How many notes `getNotes` read more than once.
  final int duplicates;

  /// How many notes of the category in the view `getNotes` did not read.
  final int missing;

  /// How many notes `getNotes` read that the view does not have for the
  /// category.
  final int extra;

  /// How many notes `getNotes` read whose category is not the category
  /// read: of a sub-category, say.
  final int outside;

  /// Whether `getNotes` read the notes the view has for the category, each
  /// once, and no other.
  bool get isSame =>
      duplicates == 0 && missing == 0 && extra == 0 && outside == 0;

  /// Counts only.
  @override
  String toString() =>
      'in the "all items" view: $expected, read: $read, missing: $missing, '
      'extra: $extra, of another category: $outside, twice: $duplicates';
}
