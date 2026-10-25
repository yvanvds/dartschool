/// Models for the absences of a pupil's file in Smartschool's pupil tracking
/// system (LVS, `/?module=LVS`, #164): the half-days with an absence code,
/// grouped by school year (the periods of the LVS's answer), as the file's
/// absences section ([LvsSectionType.absences], "Afwezigheden") lists them
/// for a teacher.
///
/// The codes are the school's own, those of the Presence module
/// (`PresenceService`, for absence administrators): the LVS gives each with
/// its short code, its description and the colour the web client shows it
/// in, kept as they come. A half-day is a [DayPart] of the Presence models;
/// an absence for the whole day has none ([LvsAbsence.isFullDay]).
///
/// The shape is that of a real pupil's answer, as the developer captured it
/// in a browser (#176, shapes only). Like the other LVS models, these never
/// print their values: their `toString()` shows counts only
/// (`doc/lvs-privacy.md`, rule 6). A motivation can hold health
/// information: the library returns it, the app decides whether to show it.
library;

import 'lvs_models.dart' show LvsSectionType;
import 'presence_models.dart' show DayPart;

/// The absences of a pupil (`LvsService.getAbsences`), grouped by period:
/// the school years the LVS gives, several, in its order.
class LvsAbsences {
  /// The school year the LVS names in its answer (`year_label`, such as
  /// `2030-2031`), the one its web client shows when there are no absences;
  /// empty when it gives none. The LVS picks it: its web client sends no
  /// school year.
  final String yearLabel;

  /// The periods (`presences`), in the LVS's order, each a school year with
  /// its absences; empty when the pupil has none.
  final List<LvsAbsencePeriod> periods;

  const LvsAbsences({this.yearLabel = '', required this.periods});

  /// Every absence, period after period, in the LVS's order.
  List<LvsAbsence> get absences => [
    for (final period in periods) ...period.absences,
  ];

  /// Whether the pupil has no absence in any period.
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

/// A period of [LvsAbsences.periods]: a key of the LVS's `presences`, a
/// school year for a pupil's file, with the absences in it.
class LvsAbsencePeriod {
  /// The period's label as the LVS gives it (the key of `presences`): the
  /// school year as `YYYY-YYYY` (`2030-2031`) for a pupil's file.
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
/// (`{partOfDay, codeKey, code, codeColor, codeDescr, motivation,
/// formattedDate}`).
class LvsAbsence {
  /// The day, at midnight UTC (its year, month and day are the Belgian
  /// day): from [dateKey] when that is a day `YYYY-MM-DD`, else from
  /// [formattedDate] (#176), `<day name> <day> <month name> <year>` as in
  /// `vr 23 oktober 2030`, the month by the answer's names of the months
  /// (`lng_months`, in any case) or its Dutch name. A shown day without a
  /// year takes it from the period's school year: September to December its
  /// first year, January to August its second. `null` when neither gives a
  /// day.
  final DateTime? date;

  /// The key of the day in the LVS's answer, as it comes: the day as
  /// `YYYY-MM-DD` (as the LVS keys the days of its class view); empty when
  /// the LVS gives the days of a period as a list, as it does for a pupil's
  /// file (#176).
  final String dateKey;

  /// The day as the LVS shows it (`formattedDate`, such as
  /// `vr 23 oktober 2030`); empty when it gives none.
  final String formattedDate;

  /// The half-day of the absence (the LVS's key `am` or `pm`); `null` for a
  /// whole day ([isFullDay], the key `full`).
  final DayPart? dayPart;

  /// The part of the day as the LVS shows it (`partOfDay`); empty when it
  /// gives none.
  final String partOfDayLabel;

  /// The short code (`code`), as the school's Presence codes name it.
  final String code;

  /// The key of the code as the LVS gives it (`codeKey`: a number, or two
  /// joined by a dash, `<n>-<n>`); empty when it gives none.
  final String codeKey;

  /// The code's description (`codeDescr`); empty when the LVS gives none.
  final String codeDescription;

  /// The colour the LVS shows the code in (`codeColor`, a class name of the
  /// web client such as `red`), or `null` when it gives none.
  final String? color;

  /// The motivation (`motivation`) as plain text: the LVS gives it as plain
  /// text or as HTML; HTML is left out, with a line for each line break and
  /// block of it (see `LvsService`). Empty when there is none. It can hold
  /// health information.
  final String motivation;

  /// The motivation as the LVS gives it (trimmed), plain text or HTML;
  /// empty when there is none.
  final String motivationHtml;

  const LvsAbsence({
    this.date,
    this.dateKey = '',
    this.formattedDate = '',
    this.dayPart,
    this.partOfDayLabel = '',
    required this.code,
    this.codeKey = '',
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
