// Belgian time for the LVS models and services (#161). Internal, but for
// lvsDayOf, which the library exports (#185): an app shows a note on its
// Belgian day with the very function the library keeps notes by.
//
// The LVS works in Belgian time (Europe/Brussels): a school year runs from
// 1 September to 31 August there, and a date field of a note is a Unix time
// of a Belgian day. The package has no time zone database, so this follows
// the EU rules, as SkoreGradebookService does for the publication times of
// Skore (#149, the other way round): CEST (UTC+2) from the last
// Sunday of March, 01:00 UTC, to the last Sunday of October, 01:00 UTC; CET
// (UTC+1) otherwise.

/// The Belgian wall-clock time of [instant], as a UTC [DateTime] whose
/// fields (year, month, day, hour, ...) read as the time in Brussels.
DateTime brusselsWallTime(DateTime instant) {
  final utc = instant.toUtc();
  final summerStart = _lastSundayAtOneUtc(utc.year, DateTime.march);
  final summerEnd = _lastSundayAtOneUtc(utc.year, DateTime.october);
  final summer = !utc.isBefore(summerStart) && utc.isBefore(summerEnd);
  return utc.add(Duration(hours: summer ? 2 : 1));
}

/// 01:00 UTC on the last Sunday of [month] of [year].
DateTime _lastSundayAtOneUtc(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final sunday = lastDay.subtract(Duration(days: lastDay.weekday % 7));
  return DateTime.utc(sunday.year, sunday.month, sunday.day, 1);
}

/// The day of [instant] in Belgian time (Europe/Brussels), the LVS's, as
/// `YYYY-MM-DD` (#185): the day the LVS shows a note on.
///
/// The LVS models give their moments in UTC (`LvsNote.date`,
/// `LvsNoteField.date`, `LvsEvaluation.date`, `LvsFeedbackEvaluation.date`,
/// `LvsReport.date`): a note made at 00:30 in Brussels is dated 22:30 UTC
/// the day before, and `toLocal()` gives the day in the computer's own time
/// zone, which need not be Belgium's. [instant] may be in any time zone:
/// only the moment counts.
///
/// It is the day `LvsSchoolYear.includesDay` and `includesNote` keep a note
/// by, and the `value` of a date field (`LvsNoteField`): the same function.
String lvsDayOf(DateTime instant) => isoDay(brusselsWallTime(instant));

/// The calendar day of [date] (its year, month and day fields) as
/// `YYYY-MM-DD`.
String isoDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
