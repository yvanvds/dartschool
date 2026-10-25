// What the live notes case of lvs_live_test.dart reads and compares (#161,
// #177), offline-tested in lvs_notes_check_test.dart.
//
// The file overview flags a category that holds notes in any school year
// (LvsCategory.hasNotes), and getNotes reads one school year: the first
// category flagged can hold older notes only, and then its notes are an
// empty list, on which every check of the case held (#177). So the case
// reads the "all items" view (getAllNotes) of the school year first, picks a
// category that holds notes in it, and compares getNotes for that category
// with the notes of the category and its sub-categories in that view.
//
// Both classes keep counts only, never an ID or a value of an answer
// (doc/lvs-privacy.md, rule 4), and their toString() says counts only.
import 'package:flutter_smartschool/flutter_smartschool.dart';

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

/// How the notes `getNotes` read for a category compare with those of the
/// category and its sub-categories in the "all items" view of the same
/// school year: by their IDs, as counts.
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
    final ids = _idsOf(category);
    final expected = {
      for (final note in all)
        if (ids.contains(note.categoryId)) note.id,
    };
    final got = {for (final note in read) note.id};
    return LvsNotesComparison._(
      expected: expected.length,
      read: read.length,
      duplicates: read.length - got.length,
      missing: expected.difference(got).length,
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

  /// Counts only.
  @override
  String toString() =>
      'in the "all items" view: $expected, read: $read, missing: $missing, '
      'extra: $extra, of another category: $outside, twice: $duplicates';
}
