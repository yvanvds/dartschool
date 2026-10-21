// The absences of a pupil's file in the LVS (#164): the answer of
// `POST /LVS/Pupilpresences` with `pupilID` and `groupID`, the list the
// file's absences section shows ("Afwezigheden", the left tree's
// `presences` node of the pupil). Internal: not exported by the library.
//
// The shape below comes from the LVS's JavaScript (`main-built*.js` of
// `/modules/LVS/desktop/main/`: the model `models/pupilpresences` and the
// templates of `pupilPresencesControl`), 2026-10-21, with placeholders only
// (doc/lvs-privacy.md). The LVS answered a made-up pupil in a made-up class
// with HTTP 500 and Smartschool's error page (seen live); a real pupil's
// answer is the developer's capture step (#168).
//
// {presences: {"<period label>": {"<day>": {full|am|pm: {formattedDate:
//   "<text>", partOfDay: "<text>", code: "<code>", codeColor: "<class>",
//   codeDescr: "<text>", motivation: "<HTML>"}}}}, lng_noresults: "<text>",
//   year_label: "<text>"}
//
// The web client shows a period's title, then per day the half-day of each
// key `full`, `am` or `pm`, in the answer's order; other keys it leaves out,
// and so does this file. Without absences it shows `year_label` and
// `lng_noresults` (`presences` falsy; PHP sends an empty map as `[]`). The
// day keys are not shown; the class view of the same family
// (`/LVS/Classpresences`) keys its days `YYYY-MM-DD`. The web client's other
// route (`jqDispatcher_presence`, `getPupilPresences`) is no longer called,
// and its charts (`/LVS/Pupilpresencesgraphs`) are not read: the totals are
// counted from the list (LvsAbsences.totalsByCode).
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

  /// The absences of the answer [json].
  static LvsAbsences absences(Object? json) {
    const read = LvsWire.absences;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    if (!json.containsKey('presences') && !json.containsKey('year_label')) {
      throw LvsWire.unknownShape(read, 'no presences');
    }
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
            _period('$key', value, 'presences[$i]'),
        ];
      default:
        throw LvsWire.unknownShape(read, 'presences is not a map of periods');
    }
    return LvsAbsences(
      yearLabel: _text(json['year_label'], 'year_label'),
      periods: periods,
    );
  }

  /// The period [label] of `presences`: its days, a map from a day key to
  /// the day, or a list of days (PHP's list).
  static LvsAbsencePeriod _period(String label, Object? days, String where) {
    final Iterable<(String, Object?)> entries = switch (days) {
      null => const [],
      final List<Object?> list => [for (final day in list) ('', day)],
      final Map<Object?, Object?> map => [
        for (final MapEntry(:key, :value) in map.entries) ('$key', value),
      ],
      _ => throw LvsWire.unknownShape(
        LvsWire.absences,
        '$where is not a map of days',
      ),
    };
    return LvsAbsencePeriod(
      label: label.trim(),
      absences: [
        for (final (i, (key, day)) in entries.indexed)
          ..._dayAbsences(key, day, '$where[$i]'),
      ],
    );
  }

  /// The absences of the day [key]: its keys `full`, `am` and `pm`, in the
  /// answer's order.
  static Iterable<LvsAbsence> _dayAbsences(
    String key,
    Object? day,
    String where,
  ) sync* {
    const read = LvsWire.absences;
    if (day is List && day.isEmpty) return;
    if (day is! Map) {
      throw LvsWire.unknownShape(read, '$where is not a map of half-days');
    }
    final date = _date(key.trim());
    for (final MapEntry(key: part, value: halfDay) in day.entries) {
      if (!_parts.containsKey(part)) continue;
      yield _absence(
        halfDay,
        dateKey: key.trim(),
        date: date,
        dayPart: _parts[part],
        where: '$where.$part',
      );
    }
  }

  static LvsAbsence _absence(
    Object? halfDay, {
    required String dateKey,
    required DateTime? date,
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
    return LvsAbsence(
      date: date,
      dateKey: dateKey,
      formattedDate: _text(halfDay['formattedDate'], '$where.formattedDate'),
      dayPart: dayPart,
      partOfDayLabel: _text(halfDay['partOfDay'], '$where.partOfDay'),
      code: _text(halfDay['code'], '$where.code'),
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

  /// The day [key] (`YYYY-MM-DD`) at midnight UTC; `null` for another key
  /// or a day that does not exist.
  static DateTime? _date(String key) {
    final match = _day.firstMatch(key);
    if (match == null) return null;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }
}
