// Tests for support/lvs_notes_check.dart (#177): which category the live
// notes case of lvs_live_test.dart reads with getNotes, picked by the "all
// items" view of the school year, and how it compares the two answers.
//
// The case runs against a real pupil only on the developer's machine
// (doc/lvs-privacy.md: a coding agent does not read a pupil's data), so its
// logic is checked here, on notes and categories made of the fakes of
// test/fixtures/lvs/FAKES.md, with IDs in 900000-999999.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import '../support/no_network.dart';
import 'support/lvs_notes_check.dart';

/// A category of the fakes: flagged with notes, or not.
LvsCategory _category(
  int id, {
  bool hasNotes = true,
  bool isTitle = false,
  List<LvsCategory> subcategories = const [],
}) => LvsCategory(
  id: id,
  name: 'Testcategorie',
  isTitle: isTitle,
  hasNotes: hasNotes,
  hasNewNotes: false,
  subcategories: subcategories,
);

/// A note [id] of category [categoryId], made of the fakes.
LvsNote _note(int id, int categoryId) => LvsNote(
  id: id,
  categoryId: categoryId,
  categoryName: 'Testcategorie',
  title: 'Testnotitie',
  date: DateTime.utc(2030, 10, 1),
  author: 'Piet Peeters',
  isConfidential: false,
  isNew: false,
  viewed: true,
  schoolYear: '2030-2031',
  fields: const [],
);

void main() {
  forbidRealNetwork();

  group('LvsNotePicks', () {
    test('the first category flagged with notes holds none in the school '
        'year (#177): not that one, the first one with notes in the "all '
        'items" view is picked', () {
      final older = _category(900101);
      final current = _category(900102);
      final picks = LvsNotePicks.of(
        [older, current],
        [_note(900201, 900102), _note(900202, 900102)],
      );
      expect(picks.withNotes, same(current));
      expect(picks.flaggedWithoutNotes, same(older));
      expect(picks.categoriesWithNotes, 1);
      expect(picks.categoriesFlaggedWithoutNotes, 1);
      expect(picks.notesOfUnlistedCategories, 0);
    });

    test('a category whose notes are in a sub-category holds notes; one '
        'flagged whose sub-category holds them is not "without notes"', () {
      final sub = _category(900112);
      final parent = _category(900111, subcategories: [sub]);
      final picks = LvsNotePicks.of([parent], [_note(900211, 900112)]);
      expect(picks.withNotes, same(parent));
      expect(picks.flaggedWithoutNotes, isNull);
      expect(picks.categoriesWithNotes, 2);
    });

    test('a heading is never picked: its sub-category is', () {
      final sub = _category(900122, hasNotes: false);
      final heading = _category(900121, isTitle: true, subcategories: [sub]);
      final picks = LvsNotePicks.of([heading], [_note(900221, 900122)]);
      expect(picks.withNotes, same(sub));
      expect(picks.categoriesWithNotes, 1);
    });

    test('a heading flagged with notes is not "without notes" either', () {
      final heading = _category(900131, isTitle: true);
      final picks = LvsNotePicks.of([heading], const []);
      expect(picks.flaggedWithoutNotes, isNull);
      expect(picks.categoriesFlaggedWithoutNotes, 0);
    });

    test('no note in the school year: no category to compare (the case '
        'skips), and the first one flagged is the empty one', () {
      final flagged = _category(900141);
      final picks = LvsNotePicks.of([
        _category(900140, hasNotes: false),
        flagged,
      ], const []);
      expect(picks.withNotes, isNull);
      expect(picks.flaggedWithoutNotes, same(flagged));
      expect(picks.categoriesWithNotes, 0);
    });

    test('a note of a category the file does not list is counted', () {
      final picks = LvsNotePicks.of(
        [_category(900151)],
        [_note(900251, 900151), _note(900252, 900159)],
      );
      expect(picks.withNotes?.id, 900151);
      expect(picks.notesOfUnlistedCategories, 1);
    });

    test('toString says counts only, no ID and no name', () {
      final text = LvsNotePicks.of(
        [_category(900161)],
        [_note(900261, 900161)],
      ).toString();
      expect(text, isNot(contains('9001')));
      expect(text, isNot(contains('9002')));
      expect(text, isNot(contains('Test')));
    });
  });

  group('LvsNotesComparison', () {
    final sub = _category(900302);
    final category = _category(900301, subcategories: [sub]);
    final all = [
      _note(900401, 900301),
      _note(900402, 900302),
      _note(900403, 900309),
    ];

    test('the notes of the category and its sub-categories, in any order: '
        'the same', () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [_note(900402, 900302), _note(900401, 900301)],
      );
      expect(comparison.isSame, isTrue);
      expect(comparison.expected, 2);
      expect(comparison.read, 2);
    });

    test('an empty list, as the case once passed on (#177): every note of '
        'the view missing', () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: const [],
      );
      expect(comparison.isSame, isFalse);
      expect(comparison.missing, 2);
    });

    test("a note of a sub-category left out: missing", () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [_note(900401, 900301)],
      );
      expect(comparison.isSame, isFalse);
      expect(comparison.missing, 1);
      expect(comparison.extra, 0);
    });

    test('a note the view does not have: extra', () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [
          _note(900401, 900301),
          _note(900402, 900302),
          _note(900404, 900302),
        ],
      );
      expect(comparison.isSame, isFalse);
      expect(comparison.extra, 1);
      expect(comparison.missing, 0);
    });

    test('a note of another category: outside, and extra', () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [
          _note(900401, 900301),
          _note(900402, 900302),
          _note(900403, 900309),
        ],
      );
      expect(comparison.isSame, isFalse);
      expect(comparison.outside, 1);
      expect(comparison.extra, 1);
    });

    test('a note read twice: a duplicate', () {
      final comparison = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [
          _note(900401, 900301),
          _note(900402, 900302),
          _note(900402, 900302),
        ],
      );
      expect(comparison.isSame, isFalse);
      expect(comparison.duplicates, 1);
      expect(comparison.missing, 0);
    });

    test('toString says counts only, no ID', () {
      final text = LvsNotesComparison.of(
        category: category,
        all: all,
        read: [_note(900401, 900301)],
      ).toString();
      expect(text, isNot(contains('9003')));
      expect(text, isNot(contains('9004')));
    });
  });
}
