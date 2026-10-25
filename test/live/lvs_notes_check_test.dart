// Tests for support/lvs_notes_check.dart (#177, #180): which category the
// live notes case of lvs_live_test.dart reads with getNotes, picked by its
// own notes in the "all items" view of the school year (a category's notes
// are never its sub-categories', #180), how it compares the two answers, and
// how it counts the notes of an answer that are not of the school year read:
// by the library's rule, by their date and by their label.
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

/// The school year the fakes are read for: 2030-2031.
final _year = LvsSchoolYear.starting(2030);

/// A note [id] of category [categoryId], made of the fakes: of 1 October
/// 2030 and labelled 2030-2031 (as test/fixtures/lvs/notes/ label it),
/// unless [date] or [schoolYear] say otherwise.
LvsNote _note(
  int id,
  int categoryId, {
  DateTime? date,
  String schoolYear = '2030-2031',
}) => LvsNote(
  id: id,
  categoryId: categoryId,
  categoryName: 'Testcategorie',
  title: 'Testnotitie',
  date: date ?? DateTime.utc(2030, 10, 1),
  author: 'Piet Peeters',
  isConfidential: false,
  isNew: false,
  viewed: true,
  schoolYear: schoolYear,
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

    test('a category is picked by its own notes (#180): a parent whose notes '
        'are all in a sub-category is not, the sub-category is; the parent, '
        'flagged, is "without notes" of its own', () {
      final sub = _category(900112);
      final parent = _category(900111, subcategories: [sub]);
      final picks = LvsNotePicks.of([parent], [_note(900211, 900112)]);
      expect(picks.withNotes, same(sub));
      expect(picks.flaggedWithoutNotes, same(parent));
      expect(picks.categoriesWithNotes, 1);
      expect(picks.categoriesFlaggedWithoutNotes, 1);
    });

    test('a parent with notes of its own is picked before its '
        'sub-category', () {
      final sub = _category(900114);
      final parent = _category(900113, subcategories: [sub]);
      final picks = LvsNotePicks.of(
        [parent],
        [_note(900213, 900114), _note(900214, 900113)],
      );
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
      expect(text, contains('categories with notes of their own'));
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
      _note(900404, 900301),
    ];

    LvsNotesComparison compare(List<LvsNote> read) =>
        LvsNotesComparison.of(category: category, all: all, read: read);

    test("the category's own notes, in any order: the same", () {
      final comparison = compare([
        _note(900404, 900301),
        _note(900401, 900301),
      ]);
      expect(comparison.isSame, isTrue);
      expect(comparison.expected, 2);
      expect(comparison.read, 2);
    });

    test('an empty list, as the case once passed on (#177): every own note '
        'of the view missing', () {
      final comparison = compare(const []);
      expect(comparison.isSame, isFalse);
      expect(comparison.missing, 2);
    });

    test('a note of a sub-category is not expected (#180): read, it is of '
        'another category, and extra', () {
      final comparison = compare([
        _note(900401, 900301),
        _note(900404, 900301),
        _note(900402, 900302),
      ]);
      expect(comparison.isSame, isFalse);
      expect(comparison.expected, 2);
      expect(comparison.outside, 1);
      expect(comparison.extra, 1);
      expect(comparison.missing, 0);
    });

    test('an own note left out: missing', () {
      final comparison = compare([_note(900401, 900301)]);
      expect(comparison.isSame, isFalse);
      expect(comparison.missing, 1);
      expect(comparison.extra, 0);
    });

    test('an own note the view does not have: extra, not outside', () {
      final comparison = compare([
        _note(900401, 900301),
        _note(900404, 900301),
        _note(900405, 900301),
      ]);
      expect(comparison.isSame, isFalse);
      expect(comparison.extra, 1);
      expect(comparison.outside, 0);
      expect(comparison.missing, 0);
    });

    test('a note read twice: a duplicate', () {
      final comparison = compare([
        _note(900401, 900301),
        _note(900404, 900301),
        _note(900404, 900301),
      ]);
      expect(comparison.isSame, isFalse);
      expect(comparison.duplicates, 1);
      expect(comparison.missing, 0);
    });

    test('toString says counts only, no ID', () {
      final text = compare([_note(900401, 900301)]).toString();
      expect(text, contains('missing: 1'));
      expect(text, isNot(contains('9003')));
      expect(text, isNot(contains('9004')));
      expect(text, isNot(contains('2030')));
    });
  });

  group('LvsNotesInYear (#180)', () {
    test('notes dated and labelled in the school year: none outside', () {
      final inYear = LvsNotesInYear.of([
        _note(900701, 900501),
        _note(900702, 900501, schoolYear: ' 2030 - 2031 '),
      ], _year);
      expect(inYear.outside, 0);
      expect(inYear.datedOutside, 0);
      expect(inYear.labelledOutside, 0);
      expect(inYear.unlabelled, 0);
    });

    test('labelled with the year, dated outside it: of the year by the '
        "library's rule, outside by the date", () {
      final inYear = LvsNotesInYear.of([
        _note(900711, 900501, date: DateTime.utc(2030, 8, 15)),
        _note(900712, 900501, date: DateTime.utc(2031, 9, 15)),
        _note(900713, 900501, date: DateTime.utc(2031, 3, 1)),
      ], _year);
      expect(inYear.outside, 0);
      expect(inYear.datedOutside, 2);
      expect(inYear.labelledOutside, 0);
    });

    test('labelled with another school year: outside by the label and by '
        "the library's rule, though dated in the year", () {
      final inYear = LvsNotesInYear.of([
        _note(900721, 900501, schoolYear: '2029-2030'),
        _note(900722, 900501, schoolYear: '2031-2032'),
      ], _year);
      expect(inYear.outside, 2);
      expect(inYear.labelledOutside, 2);
      expect(inYear.datedOutside, 0);
      expect(inYear.unlabelled, 0);
    });

    test('a label that is empty or names no school year (one year alone, '
        "two that do not follow): unlabelled, and by the library's rule of "
        'the year by its date', () {
      final inYear = LvsNotesInYear.of([
        _note(900731, 900501, schoolYear: ''),
        _note(900732, 900501, schoolYear: 'Testjaar'),
        _note(900733, 900501, schoolYear: '2029'),
        _note(900734, 900501, schoolYear: '2030-2032'),
        _note(900735, 900501, schoolYear: '', date: DateTime.utc(2029, 10, 1)),
      ], _year);
      expect(inYear.unlabelled, 5);
      expect(inYear.labelledOutside, 0);
      expect(inYear.datedOutside, 1);
      expect(inYear.outside, 1);
    });

    test('dated by the Belgian day, as the LVS reads its days: late on 31 '
        'August in UTC is 1 September in Brussels', () {
      final inYear = LvsNotesInYear.of([
        // 2030-09-01 00:30 in Brussels (CEST): the first day, in the year.
        _note(900741, 900501, date: DateTime.utc(2030, 8, 31, 22, 30)),
        // 2031-09-01 00:30 in Brussels: the day after the last, outside.
        _note(900742, 900501, date: DateTime.utc(2031, 8, 31, 22, 30)),
        // 2031-08-31 23:30 in Brussels: the last day, in the year.
        _note(900743, 900501, date: DateTime.utc(2031, 8, 31, 21, 30)),
      ], _year);
      expect(inYear.datedOutside, 1);
    });

    test('no notes: nothing outside', () {
      final inYear = LvsNotesInYear.of(const [], _year);
      expect(inYear.outside, 0);
      expect(inYear.datedOutside, 0);
      expect(inYear.labelledOutside, 0);
      expect(inYear.unlabelled, 0);
    });

    test('toString says counts only, no ID, no date and no label', () {
      final text = LvsNotesInYear.of([
        _note(900751, 900501, date: DateTime.utc(2029, 10, 1)),
        _note(900752, 900501, schoolYear: '2029-2030'),
        _note(900753, 900501, schoolYear: 'Testjaar'),
      ], _year).toString();
      expect(text, contains('not of the school year read: 1'));
      expect(text, contains('dated outside it: 1'));
      expect(text, contains('labelled with another school year: 1'));
      expect(text, contains('with no school year label read: 1'));
      expect(text, isNot(contains('9007')));
      expect(text, isNot(contains('2029')));
      expect(text, isNot(contains('2030')));
      expect(text, isNot(contains('Test')));
    });
  });
}
