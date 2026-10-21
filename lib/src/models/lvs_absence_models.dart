/// Models for the absences of a pupil's file in Smartschool's pupil tracking
/// system (LVS, `/?module=LVS`, #164): the half-days with an absence code in
/// a school year, grouped by period, as the file's absences section
/// ([LvsSectionType.absences], "Afwezigheden") lists them for a teacher.
///
/// The codes are the school's own, those of the Presence module
/// (`PresenceService`, for absence administrators): the LVS gives each with
/// its short code, its description and the colour the web client shows it
/// in, kept as they come. A half-day is a [DayPart] of the Presence models;
/// an absence for the whole day has none ([LvsAbsence.isFullDay]).
///
/// The shapes are those the LVS's web client reads (its JavaScript,
/// 2026-10-21); a real pupil's answer is the developer's capture step (#168).
/// Like the other LVS models, these never print their values: their
/// `toString()` shows counts only (`doc/lvs-privacy.md`, rule 6). A
/// motivation can hold health information: the library returns it, the app
/// decides whether to show it.
library;

import 'lvs_models.dart' show LvsSectionType;
import 'presence_models.dart' show DayPart;

/// The absences of a pupil in one school year (`LvsService.getAbsences`),
/// grouped by period, in the LVS's order.
class LvsAbsences {
  /// The LVS's label of the school year the absences are of (`year_label`),
  /// such as `2030 - 2031`; empty when it gives none. The LVS picks the year:
  /// its web client sends none.
  final String yearLabel;

  /// The periods (`presences`), in the LVS's order, each with its absences;
  /// empty when the pupil has none in the year.
  final List<LvsAbsencePeriod> periods;

  const LvsAbsences({this.yearLabel = '', required this.periods});

  /// Every absence, period after period, in the LVS's order.
  List<LvsAbsence> get absences => [
    for (final period in periods) ...period.absences,
  ];

  /// Whether the pupil has no absence in the year.
  bool get isEmpty => periods.every((period) => period.absences.isEmpty);

  /// The number of half-days of all absences: a full day counts two.
  int get halfDays => periods.fold(0, (sum, period) => sum + period.halfDays);

  /// The totals per code, in the order a code first comes: how many
  /// absences and half-days each has. The library counts them itself, from
  /// [absences]; the LVS's charts (`/LVS/Pupilpresencesgraphs`) are not read.
  List<LvsAbsenceTotal> get totalsByCode {
    final totals = <String, LvsAbsenceTotal>{};
    for (final absence in absences) {
      final total = totals[absence.code];
      totals[absence.code] = total == null
          ? LvsAbsenceTotal(
              code: absence.code,
              codeDescription: absence.codeDescription,
              color: absence.color,
              count: 1,
              halfDays: absence.halfDays,
            )
          : LvsAbsenceTotal(
              code: total.code,
              codeDescription: total.codeDescription,
              color: total.color,
              count: total.count + 1,
              halfDays: total.halfDays + absence.halfDays,
            );
    }
    return totals.values.toList();
  }

  /// Shows counts only: the absences are a pupil's.
  @override
  String toString() =>
      'LvsAbsences(periods: ${periods.length}, '
      'absences: ${absences.length}, halfDays: $halfDays)';
}

/// A period of [LvsAbsences.periods]: a key of the LVS's `presences`, with
/// the absences in it.
class LvsAbsencePeriod {
  /// The period's label as the LVS gives it (the key of `presences`).
  final String label;

  /// The absences in the period, day after day, in the LVS's order; each
  /// day's whole-day absence or its half-days in the order the LVS gives
  /// them.
  final List<LvsAbsence> absences;

  const LvsAbsencePeriod({required this.label, required this.absences});

  /// The number of half-days of the absences: a full day counts two.
  int get halfDays => absences.fold(0, (sum, a) => sum + a.halfDays);

  /// Shows the count only: the label is the school's own.
  @override
  String toString() => 'LvsAbsencePeriod(absences: ${absences.length})';
}

/// An absence of a pupil: a whole day or a half-day with an absence code
/// (`{formattedDate, partOfDay, code, codeColor, codeDescr, motivation}`).
class LvsAbsence {
  /// The day, at midnight UTC (its year, month and day are the Belgian
  /// day), from [dateKey]; `null` when that is not a day `YYYY-MM-DD`.
  final DateTime? date;

  /// The key of the day in the LVS's answer, as it comes: the day as
  /// `YYYY-MM-DD` (as the LVS keys the days of its class view); empty when
  /// the LVS gives the days of a period as a list.
  final String dateKey;

  /// The day as the LVS shows it (`formattedDate`); empty when it gives
  /// none.
  final String formattedDate;

  /// The half-day of the absence (the LVS's key `am` or `pm`); `null` for a
  /// whole day ([isFullDay], the key `full`).
  final DayPart? dayPart;

  /// The part of the day as the LVS shows it (`partOfDay`); empty when it
  /// gives none.
  final String partOfDayLabel;

  /// The short code (`code`), as the school's Presence codes name it.
  final String code;

  /// The code's description (`codeDescr`); empty when the LVS gives none.
  final String codeDescription;

  /// The colour the LVS shows the code in (`codeColor`, a class name of the
  /// web client such as `red`), or `null` when it gives none.
  final String? color;

  /// The motivation (`motivation`) as plain text: the LVS's HTML left out.
  /// Empty when there is none. It can hold health information.
  final String motivation;

  /// The motivation as HTML, as the LVS gives it (trimmed); empty when there
  /// is none.
  final String motivationHtml;

  const LvsAbsence({
    this.date,
    this.dateKey = '',
    this.formattedDate = '',
    this.dayPart,
    this.partOfDayLabel = '',
    required this.code,
    this.codeDescription = '',
    this.color,
    this.motivation = '',
    this.motivationHtml = '',
  });

  /// Whether the absence is for the whole day (the LVS's key `full`).
  bool get isFullDay => dayPart == null;

  /// The number of half-days: two for a whole day, one for a half-day.
  int get halfDays => isFullDay ? 2 : 1;

  /// Shows the part of the day only: the rest is a pupil's.
  @override
  String toString() => 'LvsAbsence(${dayPart?.wire ?? 'full'})';
}

/// The total of one code of [LvsAbsences.totalsByCode].
class LvsAbsenceTotal {
  /// The short code ([LvsAbsence.code]).
  final String code;

  /// The code's description, of its first absence.
  final String codeDescription;

  /// The code's colour, of its first absence; `null` when the LVS gives none.
  final String? color;

  /// The number of absences with the code.
  final int count;

  /// The number of half-days of those absences: a full day counts two.
  final int halfDays;

  const LvsAbsenceTotal({
    required this.code,
    this.codeDescription = '',
    this.color,
    required this.count,
    required this.halfDays,
  });

  /// Shows the counts only: a code says why a pupil was absent.
  @override
  String toString() => 'LvsAbsenceTotal(count: $count, halfDays: $halfDays)';
}
