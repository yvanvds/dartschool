// The support plans of a pupil's file in the LVS (#163): the answers of the
// LVS's JSON dispatchers for them, `POST /?module=LVS&file=jqDispatcher_<area>
// &function=<fn>`, form-encoded, answered with JSON as text (`text/html`).
// Internal: not exported by the library.
//
// The shapes below come from the LVS's JavaScript (`lvs-hp-built*.js`,
// `lvs-main-built*.js`) and its templates
// (`/modules/LVS/themes/default/ejs/ihpMain*.ejs`, `profielschets.ejs`),
// 2026-10-21, with placeholders only (doc/lvs-privacy.md). The three were
// seen live for a made-up pupil in a made-up class only: the period menu as
// `{check: 0, title: "", titleMenu: []}`, the plan and the profile sketch
// with `period: {error: 1, message: "<the LVS's message>"}` (no
// `currentPeriodID`), the plan with `count` 0 and `items` `[]`, the sketch
// with `check` 0 and a message of the LVS's own in `content`. A real pupil's
// answers are the developer's capture step (#168).
//
// getLVSspecificTitles (type hp_ihp): {check: 0|1, title: "<HTML>",
//   titleMenu: [{titleGroup, titleType, titleIcon, actionID: <period id>,
//   titleText: "<text>", selected}], width}; an entry with a `titleGroup`
//   is a heading (its `titleType` "title" a divider), the others periods
// getIHP: {count: <int>, classInfo: "<HTML>", period, items: [item],
//   filters: {groupBy, filterTeacher, filterCourse}, filterdata, domains
//   (the items grouped by domain), OV, titles, canWrite, courses: [{courseID,
//   title}] (the courses the edit form offers for an item, gwpEdit.ejs)}.
//   The web client filters the items itself (#189): by teacher, an item
//   whose `authorID` (a document's `author`) is the teacher's ID; by course,
//   an item whose `courses[<course id>]` is 1 (never a document); `filters`
//   holds the chosen teacher's and course's IDs (0 for all), `filterdata`
//   {teachers, courses} the options of the two filters, each in the shape of
//   the web client's select (`{option: {<n>: {value, title, selected}}}`).
//   A goal's planning entry of `occType` "course" has the course's ID in
//   `occID`, as the edit form reads it. The library reads `courses`, an
//   item's `authorID` and `courses`, and `occType` / `occID`; not `filters`
//   and `filterdata`, whose values for a real plan were not captured (#168)
// a period: {currentPeriodID: <int>, error: 0|1, message: "<text>",
//   currentlyInOpenPeriod: <flag>}
// an item, by its type:
//   ihp: {itemID, type, author: "<name>", authorID, courses: {<course id>:
//     1}, rights, itemHistory, lastversion: {itemID, versionID, versionType,
//     dateToShow, ihp: {noden: [{ondName}], hoofddoelen: [{doelID,
//     parentID, doelName, ...}], werkdoelen: [{doelName}], aanpak:
//     [{aanpakName}], aanpakcomment: "<HTML>", courses: [{title}]}}}
//   from_gwp: {itemID, type, source: "new"|..., author, authorID, courses,
//     rights, itemHistory, lastversion: {itemID, versionID, versionType:
//     "normal"|"bubao"|"eigendb", dateToShow, themeName, beginsituatie:
//     "<HTML>", doelen: [{parentID, parentName, parentDeprecated, deleted,
//     path, offDoelen, doelstellingen: [{doelID, doelName}], aanpak:
//     [{aanpakID, aanpakName}], occurrence: [{occType, occID, occName}]}],
//     ...}}
//   document: {documentID, type, author: <author id>, authorName,
//     dateToShow, fileName, mime: {type, icon}, rights}
// getProfielSchets: {check: 0|1, content: "<HTML>", avatarHash, pupilName,
//   birthdate, age, className_teacher, lastrevision: "<text>", period, and
//   the labels of the page (_BIRTHDATE, _AGE, ...)}; the library reads
//   `check`, `content`, `lastrevision` and `period` only
import '../models/lvs_plan_models.dart';
import 'lvs_wire.dart';

/// Reads the answers of the support plans' reads
/// ([LvsWire.supportPlanPeriods], [LvsWire.supportPlan],
/// [LvsWire.profileSketch]).
abstract final class LvsPlanAnswers {
  /// The periods of the period menu: its entries that are no heading, each
  /// with the heading before it. None when the LVS gives no menu (`check`
  /// not `1`, as for a class without a structure of support plans, seen
  /// live): an empty list.
  static List<LvsPlanPeriod> periods(Object? json) {
    const read = LvsWire.supportPlanPeriods;
    final answer = _object(json, read, 'the answer');
    final check =
        _flag(answer, 'check', read, 'the answer') ??
        (throw LvsWire.unknownShape(read, 'no check'));
    final menu = answer['titleMenu'];
    if (menu != null && menu is! List) {
      throw LvsWire.unknownShape(read, 'titleMenu is not a list');
    }
    if (!check) return const [];
    final periods = <LvsPlanPeriod>[];
    var heading = '';
    for (final (i, node) in ((menu as List?) ?? const []).indexed) {
      final where = 'titleMenu[$i]';
      final entry = _object(node, read, where);
      final text = _plain(entry, 'titleText', read, where, required: true);
      if (_truthy(entry['titleGroup'])) {
        heading = text;
        continue;
      }
      periods.add(
        LvsPlanPeriod(
          id: _id(entry, 'actionID', read, where),
          name: text,
          heading: heading,
        ),
      );
    }
    return periods;
  }

  /// The plan of `getIHP`: its period and its items.
  static LvsSupportPlan plan(Object? json) {
    const read = LvsWire.supportPlan;
    final answer = _object(json, read, 'the answer');
    final items = switch (answer['items']) {
      null => const <Object?>[],
      final List<Object?> list => list,
      // PHP sends a list with gaps in its keys as a map.
      final Map<Object?, Object?> map => map.values.toList(),
      _ => throw LvsWire.unknownShape(read, 'items is not a list'),
    };
    return LvsSupportPlan(
      period: _period(answer, read),
      items: [
        for (final (i, item) in items.indexed)
          if (item != null) _item(item, 'items[$i]'),
      ],
      courses: _courses(answer),
    );
  }

  /// The profile sketch of `getProfielSchets`.
  static LvsProfileSketch profileSketch(Object? json) {
    const read = LvsWire.profileSketch;
    final answer = _object(json, read, 'the answer');
    final period = _period(answer, read);
    final hasSketch =
        _flag(answer, 'check', read, 'the answer') ??
        (throw LvsWire.unknownShape(read, 'no check'));
    if (!hasSketch) {
      return LvsProfileSketch(period: period, hasSketch: false);
    }
    final html = _text(answer, 'content', read, 'the answer', required: true);
    return LvsProfileSketch(
      period: period,
      hasSketch: true,
      html: html,
      text: LvsWire.plainText(html),
      lastRevision: _plain(answer, 'lastrevision', read, 'the answer'),
    );
  }

  // ---------------------------------------------------------------------------
  // Parts
  // ---------------------------------------------------------------------------

  /// The `period` of an answer.
  static LvsPlanPeriodInfo _period(Map<Object?, Object?> answer, LvsRead read) {
    final period = answer['period'];
    if (period is! Map) throw LvsWire.unknownShape(read, 'no period');
    const where = 'period';
    final hasError =
        _flag(period, 'error', read, where) ??
        (throw LvsWire.unknownShape(read, 'no period.error'));
    final id = _optionalId(period, 'currentPeriodID', read, where);
    return LvsPlanPeriodInfo(
      id: id,
      hasError: hasError,
      message: _plain(period, 'message', read, where),
      isOpen: _flag(period, 'currentlyInOpenPeriod', read, where),
    );
  }

  static LvsPlanItem _item(Object? node, String where) {
    const read = LvsWire.supportPlan;
    final item = _object(node, read, where);
    final type = _text(item, 'type', read, where, required: true);
    return switch (type) {
      'ihp' => _needs(item, type, where),
      'from_gwp' => _goals(item, type, where),
      'document' => LvsPlanItem(
        id: _id(item, 'documentID', read, where),
        type: type,
        kind: LvsPlanItemKind.document,
        author: _plain(item, 'authorName', read, where),
        // A document's `author` is its author's ID (the web client's filter
        // by teacher compares it), its name is `authorName`.
        authorId: _optionalId(item, 'author', read, where),
        date: _plain(item, 'dateToShow', read, where),
        fileName: _text(item, 'fileName', read, where, required: true),
        mimeType: switch (_optionalObject(item, 'mime', read, where)) {
          null => '',
          final mime => _plain(mime, 'type', read, '$where.mime'),
        },
      ),
      _ => LvsPlanItem(
        id: item.containsKey('itemID')
            ? _id(item, 'itemID', read, where)
            : _id(item, 'documentID', read, where),
        type: type,
        kind: LvsPlanItemKind.unknown,
        author: _author(item, where),
        authorId: _authorId(item, where),
      ),
    };
  }

  /// An item of support needs (`ihp`).
  static LvsPlanItem _needs(
    Map<Object?, Object?> item,
    String type,
    String where,
  ) {
    const read = LvsWire.supportPlan;
    final version = _lastVersion(item, where);
    final at = '$where.lastversion';
    final plan = _optionalObject(version, 'ihp', read, at);
    if (plan == null) throw LvsWire.unknownShape(read, '$at: no ihp');
    final comment = _text(plan, 'aanpakcomment', read, '$at.ihp');
    return LvsPlanItem(
      id: _id(item, 'itemID', read, where),
      type: type,
      kind: LvsPlanItemKind.needs,
      versionId: _optionalId(version, 'versionID', read, at),
      versionType: _plain(version, 'versionType', read, at),
      author: _author(item, where),
      authorId: _authorId(item, where),
      date: _plain(version, 'dateToShow', read, at),
      supportNeeds: _names(plan, 'noden', 'ondName', '$at.ihp'),
      mainGoals: _names(plan, 'hoofddoelen', 'doelName', '$at.ihp'),
      workGoals: _names(plan, 'werkdoelen', 'doelName', '$at.ihp'),
      approach: _names(plan, 'aanpak', 'aanpakName', '$at.ihp'),
      approachComment: LvsWire.plainText(comment),
      approachCommentHtml: comment,
      courses: _names(plan, 'courses', 'title', '$at.ihp'),
      courseIds: _courseIds(item, where),
    );
  }

  /// An item of goals (`from_gwp`).
  static LvsPlanItem _goals(
    Map<Object?, Object?> item,
    String type,
    String where,
  ) {
    const read = LvsWire.supportPlan;
    final version = _lastVersion(item, where);
    final at = '$where.lastversion';
    final start = _text(version, 'beginsituatie', read, at);
    return LvsPlanItem(
      id: _id(item, 'itemID', read, where),
      type: type,
      kind: LvsPlanItemKind.goals,
      fromGroupPlan: _plain(item, 'source', read, where) != 'new',
      versionId: _optionalId(version, 'versionID', read, at),
      versionType: _plain(version, 'versionType', read, at),
      author: _author(item, where),
      authorId: _authorId(item, where),
      courseIds: _courseIds(item, where),
      date: _plain(version, 'dateToShow', read, at),
      theme: _plain(version, 'themeName', read, at),
      startSituation: LvsWire.plainText(start),
      startSituationHtml: start,
      goals: [
        for (final (i, goal) in _list(version, 'doelen', read, at).indexed)
          _goal(goal, '$at.doelen[$i]'),
      ],
    );
  }

  static LvsPlanGoal _goal(Object? node, String where) {
    const read = LvsWire.supportPlan;
    final goal = _object(node, read, where);
    final deprecated = goal['parentDeprecated'];
    final moments = [
      for (final (i, entry) in _list(goal, 'occurrence', read, where).indexed)
        _moment(entry, '$where.occurrence[$i]'),
    ];
    return LvsPlanGoal(
      id: _optionalId(goal, 'parentID', read, where),
      name: _plain(goal, 'parentName', read, where, required: true),
      domain: _plain(goal, 'path', read, where),
      isDeprecated: deprecated != null && LvsWire.tryId(deprecated) == 1,
      objectives: _names(goal, 'doelstellingen', 'doelName', where),
      approach: _names(goal, 'aanpak', 'aanpakName', where),
      planning: [for (final moment in moments) moment.name],
      moments: moments,
    );
  }

  /// An entry of a goal's planning (`occurrence`).
  static LvsPlanMoment _moment(Object? node, String where) {
    const read = LvsWire.supportPlan;
    final entry = _object(node, read, where);
    return LvsPlanMoment(
      type: _text(entry, 'occType', read, where),
      id: _optionalId(entry, 'occID', read, where),
      name: _plain(entry, 'occName', read, where, required: true),
    );
  }

  /// The courses of the answer (`courses`, `[{courseID, title}]`); none when
  /// it is absent, `null` or empty.
  static List<LvsPlanCourse> _courses(Map<Object?, Object?> answer) {
    const read = LvsWire.supportPlan;
    final courses = switch (answer['courses']) {
      null => const <Object?>[],
      final List<Object?> list => list,
      // PHP sends a list with gaps in its keys as a map.
      final Map<Object?, Object?> map => map.values.toList(),
      _ => throw LvsWire.unknownShape(read, 'courses is not a list'),
    };
    return [
      for (final (i, node) in courses.indexed) _course(node, 'courses[$i]'),
    ];
  }

  /// A course of the answer's `courses`.
  static LvsPlanCourse _course(Object? node, String where) {
    const read = LvsWire.supportPlan;
    final course = _object(node, read, where);
    return LvsPlanCourse(
      id: _id(course, 'courseID', read, where),
      name: _plain(course, 'title', read, where, required: true),
    );
  }

  /// The IDs of the courses an item is planned in: the keys of its
  /// `courses` (`{<course id>: 1}`) whose value is `1`, as the web client's
  /// filter by course tests them; none when it is absent, `null` or empty
  /// (PHP sends an empty map as `[]`).
  static List<int> _courseIds(Map<Object?, Object?> item, String where) {
    const read = LvsWire.supportPlan;
    final courses = item['courses'];
    if (courses == null || (courses is List && courses.isEmpty)) {
      return const [];
    }
    if (courses is! Map) {
      throw LvsWire.unknownShape(read, '$where.courses is not a map');
    }
    final ids = <int>[];
    for (final MapEntry(:key, :value) in courses.entries) {
      final id = LvsWire.tryId(key);
      if (id == null || id <= 0) {
        throw LvsWire.unknownShape(
          read,
          '$where.courses has a key that is not a course ID',
        );
      }
      final planned =
          LvsWire.tryFlag(value) ??
          (throw LvsWire.unknownShape(
            read,
            '$where.courses has a value that is not a flag',
          ));
      if (planned) ids.add(id);
    }
    return ids;
  }

  /// The `lastversion` of an item.
  static Map<Object?, Object?> _lastVersion(
    Map<Object?, Object?> item,
    String where,
  ) {
    const read = LvsWire.supportPlan;
    return _optionalObject(item, 'lastversion', read, where) ??
        (throw LvsWire.unknownShape(read, '$where: no lastversion'));
  }

  /// The name of an item's author (`author`, a text); `''` when absent.
  static String _author(Map<Object?, Object?> item, String where) =>
      _plain(item, 'author', LvsWire.supportPlan, where);

  /// The user ID of an item's author (`authorID`); `null` when absent.
  static int? _authorId(Map<Object?, Object?> item, String where) =>
      _optionalId(item, 'authorID', LvsWire.supportPlan, where);

  // ---------------------------------------------------------------------------
  // Values
  // ---------------------------------------------------------------------------

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

  /// The list of [key] of [node]; empty when it is absent, `null`, or an
  /// empty map (PHP sends an empty list as `[]`, and the web client reads
  /// an empty object as no entries).
  static List<Object?> _list(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where,
  ) => switch (node[key]) {
    null => const [],
    final List<Object?> list => list,
    final Map<Object?, Object?> map when map.isEmpty => const [],
    _ => throw LvsWire.unknownShape(read, '$where.$key is not a list'),
  };

  /// The texts of [field] of the entries of the list [key] of [node], as
  /// plain text, in the LVS's order.
  static List<String> _names(
    Map<Object?, Object?> node,
    String key,
    String field,
    String where,
  ) {
    const read = LvsWire.supportPlan;
    return [
      for (final (i, entry) in _list(node, key, read, where).indexed)
        _plain(
          _object(entry, read, '$where.$key[$i]'),
          field,
          read,
          '$where.$key[$i]',
          required: true,
        ),
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

  /// The text of [key] of [node], trimmed; `''` when it is absent or `null`
  /// (an error when [required]). A number is taken as its text.
  static String _text(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where, {
    bool required = false,
  }) {
    final value = node[key];
    if (value == null && !required) return '';
    return switch (value) {
      final String text => text.trim(),
      final num number => '$number',
      _ => throw LvsWire.unknownShape(
        read,
        '$where: ${value == null ? 'no $key' : '$key is not a text'}',
      ),
    };
  }

  /// [_text] as plain text: the LVS's HTML left out.
  static String _plain(
    Map<Object?, Object?> node,
    String key,
    LvsRead read,
    String where, {
    bool required = false,
  }) => LvsWire.plainText(_text(node, key, read, where, required: required));

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

  /// Whether [value] is true as JavaScript takes it in a condition, as the
  /// web client tests a menu entry's `titleGroup`.
  static bool _truthy(Object? value) => switch (value) {
    null || false => false,
    final num number => number != 0 && !number.isNaN,
    final String text => text.isNotEmpty,
    _ => true,
  };
}
