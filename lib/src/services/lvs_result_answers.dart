// The results of a pupil's file in the LVS (#162): the answers of the results
// app's routes, `GET /LVS/Results/*`. Internal: not exported by the library.
//
// The pupil's file shows its "Resultaten" in an iframe, `/lvs/results`, the
// results app of `/production/Results/results-app/` (`lvs-built*.js` and its
// chunks); the LVS page tells it the pupil and the class (`pupilId`,
// `groupId`). The shapes below come from that app's JavaScript (its zod
// schemas, what its pages read, and its own mock data, 2026-10-21), with
// placeholders only (doc/lvs-privacy.md). Every route answered a made-up
// pupil ID in a made-up class with HTTP 500 and Smartschool's error page
// (seen live); a real pupil's answers are the developer's capture step
// (#168).
//
// getConfiguration: {capabilities: {canUserSeeAll: <bool>,
//   canUserSeeSchoolyear: <bool>}}
// getperiods: [period], a period: {id: <int>, name: "<text>", icon:
//   "<icon>", class, skoreWorkYear: {id: <int>, dateRange: {start:
//   "<date-time with offset>", end: "<date-time with offset>"}}, isActive:
//   <bool>}
// getcourses: [course], a course: {id: <int>, name: "<text>", graphic:
//   {type: "image"|"icon", value: "<path or icon>"}, class, skoreClassId:
//   <int>, parentCourseId: <int>|null}; in an evaluation also teachers:
//   [{id: "<school>_<user>_0", name: {startingWithFirstName,
//   startingWithLastName}, ...}]
// a class: {identifier: "<school>_<class>", id: <int>, platformId: <int>,
//   name: "<class>", type: "K"|"G"|"M", icon: "<icon>"}
// getevaluationsofuser: [evaluation] (not validated by the app), an
//   evaluation: {identifier: "<text>", type: "normal"|"project"|...,
//   name: "<text>", graphic: {type: "percentage"|"text"|"icon"|"image"|
//   "rubrics", color: "<colour>", value: <number or text>, description:
//   "<text>"|null}, date: "<date-time with offset>", courses: [course],
//   period, component: {name, abbreviation, ...}, doesCount: <bool>,
//   isPublished: <bool>, feedbacks: [...]}
// getfeedback: [feedback], one of (the app tries them in this order):
//   {identifier, text, type: {identifier, name, sort, isVisible,
//   maximumCharacters}, report} (class council), {identifier, text, course,
//   report} (per course), {identifier, text, owner: {id, name: {...}, ...},
//   evaluation: {identifier, name, courses: [{id, name, class: {id}}],
//   period, schoolyearLabel, date}, attachments: [{id: "<text>", name, type:
//   "OTHER"|"MICROPHONE_RECORDING"|"WEBCAM_RECORDING", size: <int>,
//   metadata, downloadUrl, wopiUrl}]} (an evaluation), and the same with
//   goal: {goalId, leerplanId, leerplanKey} (a project's goal)
// getreports: [report], a report: {id: <int>, name: "<text>", icon:
//   "<icon>", date: "<date-time with offset>", class|null, schoolyearLabel:
//   "<text>", downloadUrl: "<path>"}
import '../models/lvs_results_models.dart';
import 'lvs_wire.dart';

/// Reads the answers of the results app's reads ([LvsWire.resultsPeriods]
/// and the others).
abstract final class LvsResultAnswers {
  /// The configuration of `getConfiguration`.
  static LvsResultsConfiguration configuration(Object? json) {
    const read = LvsWire.resultsConfiguration;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    final capabilities = json['capabilities'];
    if (capabilities is! Map) {
      throw LvsWire.unknownShape(read, 'no capabilities');
    }
    return LvsResultsConfiguration(
      canSeeAll: _flag(capabilities, 'canUserSeeAll', read, 'capabilities'),
      canSeeSchoolYear: _flag(
        capabilities,
        'canUserSeeSchoolyear',
        read,
        'capabilities',
      ),
    );
  }

  /// The periods of `getperiods`, in the LVS's order.
  static List<LvsResultsPeriod> periods(Object? json) {
    const read = LvsWire.resultsPeriods;
    return [
      for (final (i, period) in _list(json, read).indexed)
        _period(period, read, '[$i]'),
    ];
  }

  /// The courses of `getcourses`, in the LVS's order.
  static List<LvsResultsCourse> courses(Object? json) {
    const read = LvsWire.resultsCourses;
    return [
      for (final (i, course) in _list(json, read).indexed)
        _course(course, read, '[$i]'),
    ];
  }

  /// The evaluations of a page of `getevaluationsofuser`, in the LVS's
  /// order.
  static List<LvsEvaluation> evaluations(Object? json) {
    const read = LvsWire.evaluations;
    return [
      for (final (i, evaluation) in _list(json, read).indexed)
        _evaluation(evaluation, '[$i]'),
    ];
  }

  /// The feedback of `getfeedback`, in the LVS's order.
  static List<LvsFeedback> feedback(Object? json) {
    const read = LvsWire.resultsFeedback;
    return [
      for (final (i, item) in _list(json, read).indexed)
        _feedback(item, '[$i]'),
    ];
  }

  /// The reports of `getreports`, in the LVS's order.
  static List<LvsReport> reports(Object? json) {
    const read = LvsWire.reports;
    return [
      for (final (i, report) in _list(json, read).indexed)
        _report(report, read, '[$i]'),
    ];
  }

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  static LvsResultsPeriod _period(Object? node, LvsRead read, String where) {
    final period = _object(node, read, where);
    final workYear = _optionalObject(period, 'skoreWorkYear', read, where);
    final range = workYear == null
        ? null
        : _optionalObject(workYear, 'dateRange', read, '$where.skoreWorkYear');
    final klass = _optionalObject(period, 'class', read, where);
    return LvsResultsPeriod(
      id: _id(period, 'id', read, where),
      name: _text(period, 'name', read, where, required: true),
      icon: _text(period, 'icon', read, where),
      classId: klass == null
          ? null
          : _optionalId(klass, 'id', read, '$where.class'),
      className: klass == null
          ? ''
          : _text(klass, 'name', read, '$where.class'),
      isActive: _flag(period, 'isActive', read, where) ?? false,
      workYearId: workYear == null
          ? null
          : _optionalId(workYear, 'id', read, '$where.skoreWorkYear'),
      workYearStart: range == null
          ? null
          : _date(range, 'start', read, '$where.skoreWorkYear.dateRange'),
      workYearEnd: range == null
          ? null
          : _date(range, 'end', read, '$where.skoreWorkYear.dateRange'),
    );
  }

  static LvsResultsCourse _course(Object? node, LvsRead read, String where) {
    final course = _object(node, read, where);
    final klass = _optionalObject(course, 'class', read, where);
    final graphic = _optionalObject(course, 'graphic', read, where);
    final teachers = course['teachers'];
    if (teachers != null && teachers is! List) {
      throw LvsWire.unknownShape(read, '$where.teachers is not a list');
    }
    return LvsResultsCourse(
      id: _id(course, 'id', read, where),
      name: _text(course, 'name', read, where, required: true),
      classId: klass == null
          ? null
          : _optionalId(klass, 'id', read, '$where.class'),
      className: klass == null
          ? ''
          : _text(klass, 'name', read, '$where.class'),
      skoreClassId: _optionalId(course, 'skoreClassId', read, where),
      parentCourseId: _optionalId(course, 'parentCourseId', read, where),
      graphicType: graphic == null
          ? ''
          : _text(graphic, 'type', read, '$where.graphic'),
      graphicValue: graphic == null
          ? ''
          : _scalar(graphic, 'value', read, '$where.graphic'),
      teacherNames: [
        for (final (i, teacher) in ((teachers as List?) ?? const []).indexed)
          _personName(teacher, read, '$where.teachers[$i]'),
      ],
    );
  }

  static LvsEvaluation _evaluation(Object? node, String where) {
    const read = LvsWire.evaluations;
    final evaluation = _object(node, read, where);
    final graphic = _optionalObject(evaluation, 'graphic', read, where);
    final period = _optionalObject(evaluation, 'period', read, where);
    final component = _optionalObject(evaluation, 'component', read, where);
    final feedbacks = evaluation['feedbacks'];
    if (feedbacks != null && feedbacks is! List) {
      throw LvsWire.unknownShape(read, '$where.feedbacks is not a list');
    }
    return LvsEvaluation(
      identifier: _identifier(evaluation, read, where),
      type: _text(evaluation, 'type', read, where),
      name: _text(evaluation, 'name', read, where, required: true),
      date: _date(evaluation, 'date', read, where),
      score: graphic == null
          ? LvsScore.none
          : _score(graphic, '$where.graphic'),
      courses: _courses(evaluation, read, where),
      period: period == null ? null : _period(period, read, '$where.period'),
      componentName: component == null
          ? ''
          : _text(component, 'name', read, '$where.component'),
      componentAbbreviation: component == null
          ? ''
          : _text(component, 'abbreviation', read, '$where.component'),
      doesCount: _flag(evaluation, 'doesCount', read, where),
      isPublished: _flag(evaluation, 'isPublished', read, where),
      feedbackCount: (feedbacks as List?)?.length ?? 0,
    );
  }

  /// An evaluation's `graphic`: `{type, color, value, description}`.
  static LvsScore _score(Map<Object?, Object?> graphic, String where) {
    const read = LvsWire.evaluations;
    final value = graphic['value'];
    if (value != null && value is! String && value is! num) {
      throw LvsWire.unknownShape(read, '$where.value is not a text or number');
    }
    return LvsScore(
      type: _text(graphic, 'type', read, where),
      value: switch (value) {
        final String text => text.trim(),
        final num number => '$number',
        _ => '',
      },
      percentage: value is num ? value : null,
      description: _text(graphic, 'description', read, where),
      color: _text(graphic, 'color', read, where),
    );
  }

  static LvsFeedback _feedback(Object? node, String where) {
    const read = LvsWire.resultsFeedback;
    final item = _object(node, read, where);
    final goal = _optionalObject(item, 'goal', read, where);
    final evaluation = _optionalObject(item, 'evaluation', read, where);
    final course = _optionalObject(item, 'course', read, where);
    final report = _optionalObject(item, 'report', read, where);
    final part = _optionalObject(item, 'type', read, where);
    // The kinds of the results app, the most specific first: a goal's
    // feedback has the fields of an evaluation's too.
    final kind = switch ((goal, evaluation, course, report, part)) {
      (_?, _?, _, _, _) => LvsFeedbackKind.goal,
      (null, _?, _, _, _) => LvsFeedbackKind.evaluation,
      (null, null, _?, _?, _) => LvsFeedbackKind.course,
      (null, null, null, _?, _?) => LvsFeedbackKind.classCouncil,
      _ => LvsFeedbackKind.unknown,
    };
    final known = kind != LvsFeedbackKind.unknown;
    final owner = _optionalObject(item, 'owner', read, where);
    final attachments = item['attachments'];
    if (attachments != null && attachments is! List) {
      throw LvsWire.unknownShape(read, '$where.attachments is not a list');
    }
    return LvsFeedback(
      identifier: _identifier(item, read, where),
      kind: kind,
      text: _text(item, 'text', read, where, required: true),
      author: owner == null ? '' : _personName(owner, read, '$where.owner'),
      report: known && report != null
          ? _report(report, read, '$where.report')
          : null,
      reportPart: kind == LvsFeedbackKind.classCouncil
          ? _text(part!, 'name', read, '$where.type')
          : '',
      course: kind == LvsFeedbackKind.course
          ? _course(course, read, '$where.course')
          : null,
      evaluation: known && evaluation != null
          ? _feedbackEvaluation(evaluation, '$where.evaluation')
          : null,
      goalId: goal == null
          ? null
          : _scalar(goal, 'goalId', read, '$where.goal'),
      curriculumId: goal == null
          ? null
          : _scalar(goal, 'leerplanId', read, '$where.goal'),
      attachments: [
        for (final (i, file) in ((attachments as List?) ?? const []).indexed)
          _attachment(file, '$where.attachments[$i]'),
      ],
    );
  }

  static LvsFeedbackEvaluation _feedbackEvaluation(
    Map<Object?, Object?> evaluation,
    String where,
  ) {
    const read = LvsWire.resultsFeedback;
    final period = _optionalObject(evaluation, 'period', read, where);
    return LvsFeedbackEvaluation(
      identifier: _identifier(evaluation, read, where),
      name: _text(evaluation, 'name', read, where, required: true),
      date: _date(evaluation, 'date', read, where),
      courses: _courses(evaluation, read, where),
      period: period == null ? null : _period(period, read, '$where.period'),
      schoolYearLabel: _text(evaluation, 'schoolyearLabel', read, where),
    );
  }

  static LvsResultsAttachment _attachment(Object? node, String where) {
    const read = LvsWire.resultsFeedback;
    final file = _object(node, read, where);
    final id = _scalar(file, 'id', read, where);
    if (id.isEmpty) throw LvsWire.unknownShape(read, '$where: no id');
    final size = file['size'];
    if (size != null && size is! num) {
      throw LvsWire.unknownShape(read, '$where.size is not a number');
    }
    return LvsResultsAttachment(
      id: id,
      name: _text(file, 'name', read, where, required: true),
      type: _text(file, 'type', read, where),
      size: (size as num?)?.toInt(),
      downloadUrl: _text(file, 'downloadUrl', read, where),
    );
  }

  static LvsReport _report(Object? node, LvsRead read, String where) {
    final report = _object(node, read, where);
    final klass = _optionalObject(report, 'class', read, where);
    return LvsReport(
      id: _id(report, 'id', read, where),
      name: _text(report, 'name', read, where, required: true),
      icon: _text(report, 'icon', read, where),
      date: _date(report, 'date', read, where),
      classId: klass == null
          ? null
          : _optionalId(klass, 'id', read, '$where.class'),
      className: klass == null
          ? ''
          : _text(klass, 'name', read, '$where.class'),
      schoolYearLabel: _text(report, 'schoolyearLabel', read, where),
      downloadUrl: _text(report, 'downloadUrl', read, where),
    );
  }

  // ---------------------------------------------------------------------------
  // Values
  // ---------------------------------------------------------------------------

  /// [json] as the list of items it must be. The LVS sends an empty map as
  /// `[]`, so an empty list is no items.
  static List<Object?> _list(Object? json, LvsRead read) {
    if (json is! List) throw LvsWire.unknownShape(read, 'not a list');
    return json;
  }

  static Map<Object?, Object?> _object(
    Object? node,
    LvsRead read,
    String where,
  ) {
    if (node is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    return node;
  }

  /// The object of [key] of [node]; `null` when it is absent or `null`.
  static Map<Object?, Object?>? _optionalObject(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) {
    final value = node[key];
    if (value == null) return null;
    if (value is! Map) {
      throw LvsWire.unknownShape(read, '$where.$key is not an object');
    }
    return value;
  }

  /// The courses of [node] (`courses`); empty when absent.
  static List<LvsResultsCourse> _courses(
    Map<Object?, Object?> node,
    LvsRead read,
    String where,
  ) {
    final courses = node['courses'];
    if (courses == null) return const [];
    if (courses is! List) {
      throw LvsWire.unknownShape(read, '$where.courses is not a list');
    }
    return [
      for (final (i, course) in courses.indexed)
        _course(course, read, '$where.courses[$i]'),
    ];
  }

  /// The positive ID of [key] of [node].
  static int _id(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) {
    final id = LvsWire.tryId(node[key]);
    if (id == null || id <= 0) {
      throw LvsWire.unknownShape(read, '$where: no $key');
    }
    return id;
  }

  /// The ID of [key] of [node]; `null` when it is absent, `null` or `0`.
  static int? _optionalId(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) {
    final value = node[key];
    if (value == null) return null;
    final id = LvsWire.tryId(value);
    if (id == null || id < 0) {
      throw LvsWire.unknownShape(read, '$where.$key is not an ID');
    }
    return id == 0 ? null : id;
  }

  /// The non-empty `identifier` of [node].
  static String _identifier(
    Map<Object?, Object?> node,
    LvsRead read,
    String where,
  ) {
    final identifier = _scalar(node, 'identifier', read, where);
    if (identifier.isEmpty) {
      throw LvsWire.unknownShape(read, '$where: no identifier');
    }
    return identifier;
  }

  /// The text of [key] of [node], trimmed; `''` when it is absent or `null`
  /// (an error when [required]).
  static String _text(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where, {
    bool required = false,
  }) {
    final value = node[key];
    if (value == null && !required) return '';
    if (value is! String) {
      throw LvsWire.unknownShape(
        read,
        '$where: ${value == null ? 'no $key' : '$key is not a text'}',
      );
    }
    return value.trim();
  }

  /// [key] of [node] as text, a text or a number (an ID that may come either
  /// way); `''` when it is absent or `null`.
  static String _scalar(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) => switch (node[key]) {
    null => '',
    final String text => text.trim(),
    final num number => '$number',
    _ => throw LvsWire.unknownShape(read, '$where.$key is not a text'),
  };

  /// The flag of [key] of [node]; `null` when it is absent or `null`.
  static bool? _flag(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) {
    final value = node[key];
    if (value == null) return null;
    return LvsWire.tryFlag(value) ??
        (throw LvsWire.unknownShape(read, '$where.$key is not a flag'));
  }

  /// The moment of [key] of [node] (an ISO 8601 date-time, with its offset),
  /// in UTC; `null` when it is absent, `null` or empty.
  static DateTime? _date(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) {
    final value = node[key];
    if (value == null || (value is String && value.trim().isEmpty)) {
      return null;
    }
    final date = value is String ? DateTime.tryParse(value.trim()) : null;
    if (date == null) {
      throw LvsWire.unknownShape(read, '$where.$key is not a date');
    }
    return date.toUtc();
  }

  /// The name of a person (a teacher, an owner): `name.startingWithFirstName`,
  /// or `name` itself when it is a text.
  static String _personName(Object? node, LvsRead read, String where) {
    final person = _object(node, read, where);
    final name = person['name'];
    if (name is String) return name.trim();
    if (name is Map) return _text(name, 'startingWithFirstName', read, where);
    throw LvsWire.unknownShape(read, '$where: no name');
  }
}
