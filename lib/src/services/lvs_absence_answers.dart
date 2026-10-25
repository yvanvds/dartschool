// The absences of a pupil's file in the LVS (#164): the answer of
// `POST /LVS/Pupilpresences` with `pupilID` and `groupID`, the list the
// file's absences section shows ("Afwezigheden", the left tree's
// `presences` node of the pupil). Internal: not exported by the library.
//
// The shape below is that of a real pupil's answer, as the developer
// captured it in a browser (#176), with placeholders only
// (doc/lvs-privacy.md); #164 had read a first shape from the LVS's
// JavaScript (`main-built*.js` of `/modules/LVS/desktop/main/`: the model
// `models/pupilpresences` and the templates of `pupilPresencesControl`).
// The LVS answered a made-up pupil in a made-up class with HTTP 500 and
// Smartschool's error page (seen live).
//
// {lng_noresults: "<text>", lng_months: [12 x "<text>"],
//  lng_days: [7 x "<text>"],
//  presences: {"<YYYY-YYYY>": [{full|am|pm: {partOfDay: "<text>",
//    codeKey: "<n>" | "<n>-<n>", code: "<code>", codeColor: "<class>",
//    codeDescr: "<text>", motivation: "<text or HTML>" | "",
//    formattedDate: "<text>"}}]},
//  year_label: "<YYYY-YYYY>"}
//
// A period of `presences` is a school year, and the answer holds several.
// Its days come as a list, without a day key: the day is only in
// `formattedDate`, as the LVS shows it, `<short day name> <day> <month
// name> <year>` (`vr 23 oktober 2026`, a made-up day). This file reads that
// text, the month by the answer's `lng_months` or its Dutch name; a text
// without a year takes it from the school year (September to December its
// first year, January to August its second). Any other text gives no date,
// never an error. The class view of the same family (`/LVS/Classpresences`)
// keys its days `YYYY-MM-DD`: such a key dates its day, as #164 read it,
// and is still taken.
//
// The web client shows a period's title, then per day the half-day of each
// key `full`, `am` or `pm`, in the answer's order; other keys it leaves out,
// and so does this file. `partOfDay` is only a label. Without absences it
// shows `year_label` and `lng_noresults` (`presences` falsy; PHP sends an
// empty map as `[]`). The web client's other route (`jqDispatcher_presence`,
// `getPupilPresences`) is no longer called, and its charts
// (`/LVS/Pupilpresencesgraphs`) are not read: the totals are counted from
// the list (LvsAbsences.totalsByCode).
import '../models/lvs_absence_models.dart';
import '../models/presence_models.dart' show DayPart;
import 'lvs_wire.dart';

/// Reads the answer of [LvsWire.absences].
abstract final class LvsAbsenceAnswers {
  /// The keys of a day that the web client shows, and their half-day
  /// (`null`: the whole day).
  static const _parts = {
    'full': null,
    'am': DayPart.morning,
    'pm': DayPart.afternoon,
  };

  /// A day key `YYYY-MM-DD`.
  static final _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// A school year, the key of a period: `YYYY-YYYY`.
  static final _schoolYear = RegExp(r'^(\d{4})\s*-\s*(\d{4})$');

  /// The absences of the answer [json].
  static LvsAbsences absences(Object? json) {
    const read = LvsWire.absences;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    if (!json.containsKey('presences') && !json.containsKey('year_label')) {
      throw LvsWire.unknownShape(read, 'no presences');
    }
    final months = _ShownDays.monthsOf(json['lng_months']);
    final presences = json['presences'];
    final List<LvsAbsencePeriod> periods;
    switch (presences) {
      // None: falsy for the web client, or PHP's empty map.
      case null || false || '':
        periods = const [];
      case final List<Object?> list when list.isEmpty:
        periods = const [];
      case final Map<Object?, Object?> map:
        periods = [
          for (final (i, MapEntry(:key, :value)) in map.entries.indexed)
            _period('$key', value, months, 'presences[$i]'),
        ];
      default:
        throw LvsWire.unknownShape(read, 'presences is not a map of periods');
    }
    return LvsAbsences(
      yearLabel: _text(json['year_label'], 'year_label'),
      periods: periods,
    );
  }

  /// The period [label] of `presences`: its days, a list of days (as the
  /// LVS gives a school year of a pupil's file) or a map from a day key to
  /// the day (as its class view does).
  static LvsAbsencePeriod _period(
    String label,
    Object? days,
    List<String?> months,
    String where,
  ) {
    final Iterable<(String, Object?)> entries = switch (days) {
      null => const [],
      final List<Object?> list => [for (final day in list) ('', day)],
      final Map<Object?, Object?> map => [
        for (final MapEntry(:key, :value) in map.entries) ('$key', value),
      ],
      _ => throw LvsWire.unknownShape(
        LvsWire.absences,
        '$where is not a list of days',
      ),
    };
    final period = label.trim();
    final shownDays = _ShownDays(months, _schoolYearOf(period));
    return LvsAbsencePeriod(
      label: period,
      absences: [
        for (final (i, (key, day)) in entries.indexed)
          ..._dayAbsences(key, day, shownDays, '$where[$i]'),
      ],
    );
  }

  /// The absences of the day [key] (empty for a day of a list): its keys
  /// `full`, `am` and `pm`, in the answer's order.
  static Iterable<LvsAbsence> _dayAbsences(
    String key,
    Object? day,
    _ShownDays shownDays,
    String where,
  ) sync* {
    const read = LvsWire.absences;
    if (day is List && day.isEmpty) return;
    if (day is! Map) {
      throw LvsWire.unknownShape(read, '$where is not a map of half-days');
    }
    final dateKey = key.trim();
    final keyDate = _date(dateKey);
    for (final MapEntry(key: part, value: halfDay) in day.entries) {
      if (!_parts.containsKey(part)) continue;
      yield _absence(
        halfDay,
        dateKey: dateKey,
        keyDate: keyDate,
        shownDays: shownDays,
        dayPart: _parts[part],
        where: '$where.$part',
      );
    }
  }

  /// The half-day [halfDay], dated by [keyDate] (the day of its key), else
  /// by the day it shows.
  static LvsAbsence _absence(
    Object? halfDay, {
    required String dateKey,
    required DateTime? keyDate,
    required _ShownDays shownDays,
    required DayPart? dayPart,
    required String where,
  }) {
    const read = LvsWire.absences;
    if (halfDay is! Map) {
      throw LvsWire.unknownShape(read, '$where is not an object');
    }
    if (halfDay['code'] == null) {
      throw LvsWire.unknownShape(read, '$where: no code');
    }
    final html = _text(halfDay['motivation'], '$where.motivation');
    final color = _text(halfDay['codeColor'], '$where.codeColor');
    final shown = _text(halfDay['formattedDate'], '$where.formattedDate');
    return LvsAbsence(
      date: keyDate ?? shownDays.dateOf(shown),
      dateKey: dateKey,
      formattedDate: shown,
      dayPart: dayPart,
      partOfDayLabel: _text(halfDay['partOfDay'], '$where.partOfDay'),
      code: _text(halfDay['code'], '$where.code'),
      codeKey: _text(halfDay['codeKey'], '$where.codeKey'),
      codeDescription: _text(halfDay['codeDescr'], '$where.codeDescr'),
      color: color.isEmpty ? null : color,
      motivation: LvsWire.plainText(html),
      motivationHtml: html,
    );
  }

  /// [value] as a text, trimmed: `''` for `null`; a number as its text.
  static String _text(Object? value, String where) => switch (value) {
    null => '',
    final String text => text.trim(),
    final num number => '$number',
    _ => throw LvsWire.unknownShape(LvsWire.absences, '$where is not a text'),
  };

  /// The years of the school year [label] (`YYYY-YYYY`), or `null` for a
  /// label that is not one.
  static (int, int)? _schoolYearOf(String label) {
    final match = _schoolYear.firstMatch(label);
    if (match == null) return null;
    return (int.parse(match[1]!), int.parse(match[2]!));
  }

  /// The day [key] (`YYYY-MM-DD`) at midnight UTC; `null` for another key
  /// or a day that does not exist.
  static DateTime? _date(String key) {
    final match = _day.firstMatch(key);
    if (match == null) return null;
    return _utcDay(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }
}

/// The day [year]-[month]-[day] at midnight UTC; `null` for a day that does
/// not exist.
DateTime? _utcDay(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}

/// Dates the days of one period by the text the LVS shows for them
/// (`formattedDate`): `<day name> <day> <month name> <year>`, as
/// `vr 23 oktober 2026`, or the same without the year.
class _ShownDays {
  const _ShownDays(this.months, this.schoolYear);

  /// The month names of the answer (`lng_months`), in lower case, January
  /// first; empty when it gives none that can be used.
  final List<String?> months;

  /// The years of the period's school year, or `null` when its key is not
  /// one.
  final (int, int)? schoolYear;

  /// A shown day: a day name, the day, the month's name and, optionally,
  /// the year.
  static final _shownDay = RegExp(
    r'^[^\s\d]+\s+(\d{1,2})\s+([^\s\d]+)(?:\s+(\d{4}))?$',
  );

  /// The Dutch names of the months, for a name `lng_months` does not have.
  static const _dutchMonths = [
    'januari',
    'februari',
    'maart',
    'april',
    'mei',
    'juni',
    'juli',
    'augustus',
    'september',
    'oktober',
    'november',
    'december',
  ];

  /// The month names of `lng_months` ([names]), trimmed, in lower case,
  /// January first; `null` for one that is not a text. Empty when the
  /// answer gives none, or not a list of 12: then the Dutch names alone
  /// are used. Never an error: they only date the absences.
  static List<String?> monthsOf(Object? names) {
    if (names is! List || names.length != 12) return const [];
    return [
      for (final name in names)
        name is String && name.trim().isNotEmpty
            ? name.trim().toLowerCase()
            : null,
    ];
  }

  /// The day [shown] at midnight UTC; `null` when it does not parse, names
  /// a day that does not exist, or has no year in a period that is not a
  /// school year.
  DateTime? dateOf(String shown) {
    final match = _shownDay.firstMatch(shown);
    if (match == null) return null;
    final month = _month(match[2]!.toLowerCase());
    if (month == null) return null;
    final int year;
    if (match[3] case final text?) {
      year = int.parse(text);
    } else if (schoolYear case (final first, final second)) {
      // September to December in the first year, January to August in the
      // second.
      year = month >= 9 ? first : second;
    } else {
      return null;
    }
    return _utcDay(year, month, int.parse(match[1]!));
  }

  /// The month (1 for January) named [name], in lower case: by the
  /// answer's names first, then by the Dutch ones; `null` for neither.
  int? _month(String name) {
    final index = months.indexOf(name);
    if (index >= 0) return index + 1;
    final dutch = _dutchMonths.indexOf(name);
    return dutch >= 0 ? dutch + 1 : null;
  }
}
