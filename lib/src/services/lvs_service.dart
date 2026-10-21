import 'dart:convert';

import '../exceptions.dart';
import '../models/lvs_models.dart';
import '../session.dart';
import 'lvs_note_answers.dart';
import 'lvs_wire.dart';

export '../models/lvs_models.dart';

/// Reads Smartschool's pupil tracking system (LVS, "leerlingvolgsysteem",
/// `/?module=LVS`) **as the logged-in teacher** (#160): finds a pupil by
/// name ([searchPupils]) and reads the overview of the pupil's file
/// ([getPupilFile]): who, which class, today's attendance, and which
/// sections of the file hold something; and the pupil's notes, per category
/// ([getNotes]) or all of them ([getAllNotes], #161). [checkAccess] tells
/// whether the account may use the LVS.
///
/// ```dart
/// final lvs = LvsService(client);
///
/// final found = await lvs.searchPupils('janssens'); // several can match
/// final pupil = found.first;
/// final file = await lvs.getPupilFile(
///   pupilId: pupil.pupilId,
///   classId: pupil.classId,
/// );
/// for (final category in file.noteCategories.where((c) => c.hasNotes)) {
///   final notes = await lvs.getNotes(
///     pupilId: pupil.pupilId,
///     classId: pupil.classId,
///     categoryId: category.id,
///   );
///   print('${notes.length} notes'); // the notes are about the pupil
/// }
/// ```
///
/// **Only reads, by an allowlist.** The LVS has writes right next to its
/// reads, some on the same URL (`PUT /LVS/Message`, `PUT /LVS/Watch`,
/// `setLastPupil`, which the web client sends for every pupil it shows, the
/// "viewed" flags, the edit locks). The service sends only its reads, each
/// on an explicit list (method, path, query and form fields), and refuses
/// any other request before it is sent
/// ([SmartschoolLvsRequestNotAllowedError]). It never sends what the web
/// client sends "on the side" either: reading a pupil's file here does not
/// make it the last pupil the account viewed, and marks nothing as seen.
///
/// The requests (read from the LVS's own JavaScript, and tried live without
/// a pupil, 2026-10-21):
/// - [searchPupils]: `GET /LVS/Spotlight?searchVal=<text>`, answered with
///   `{search, classes, pupils, teachers, groups, groupUsers}` (lists);
/// - [getPupilFile]: `GET /LVS/Spotlight/<pupil id>?classID=<class id>`,
///   answered with `{categories, pupil}`, then
///   `POST /LVS/Pupilxhr/getStatusInfo` with `pupilID`, answered with a list
///   of `{partOfDay, code: {name, code, color}}`;
/// - [checkAccess]: `POST /?module=LVS&file=treeBuilder` with `id` `0`, the
///   root of the LVS's left tree: the classes the account may see, no pupil;
/// - [getNotes]: the LVS's XML dispatcher, `POST /?module=LVS&file=dispatcher`
///   with the command `lvs_cats/getUserCatItems`, answered with the action
///   `renderPupilNotes` (#161);
/// - [getAllNotes]: the same dispatcher with `lvs_pupils/getUserData`,
///   answered with `renderPupilAllNotes` (#161).
///
/// They answer straight after a login: the LVS page (some 300 KB) does not
/// have to be loaded first (seen live).
///
/// ### Privacy
/// What this service returns is about pupils: see `doc/lvs-privacy.md`. Its
/// models print counts only (`toString()`), and its errors never carry a
/// name, a text or an ID of an answer in their message; a refused session
/// that names a search's URL has the search text left out.
///
/// ### Errors
/// - [SmartschoolLvsAccessDeniedError] (a [SmartschoolLvsError]): the LVS
///   refused the read to the account (HTTP `403`, or a redirect to
///   Smartschool's start page). What the LVS answers a teacher without LVS
///   rights and a pupil account was not captured.
/// - [SmartschoolLvsPupilNotFoundError] (a [SmartschoolLvsError]):
///   [getPupilFile] or [getNotes] got the LVS's placeholder pupil: it knows
///   no pupil of that ID in that class that the account may see.
/// - [SmartschoolLvsCategoryNotFoundError] (a [SmartschoolLvsError]):
///   [getNotes] got no category: the LVS knows no category of notes of that
///   ID.
/// - [SmartschoolLvsRequestNotAllowedError] (a [SmartschoolLvsError]): the
///   service refused to send a request that is not one of its reads (a bug
///   of the library). Nothing was sent.
/// - [SmartschoolLvsError] itself: the LVS answered with something the
///   service cannot use (another HTTP status than `200`, an HTML page,
///   invalid JSON, an unknown shape). Never an empty result.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried once.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
/// - [ArgumentError]: a blank search text, an ID that is not positive, or a
///   school year that ends before it starts, before anything is sent.
class LvsService {
  final LvsWire _wire;

  LvsService(SmartschoolClient client) : _wire = LvsWire(client);

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Whether the account may use the LVS: `true` when the LVS answers the
  /// root of its left tree (the classes the account may see), `false` when
  /// it refuses it to the account ([SmartschoolLvsAccessDeniedError]). Reads
  /// no pupil; for a status check, before the other reads.
  ///
  /// Any other failure is thrown: an answer the service cannot read (a
  /// plain [SmartschoolLvsError]) is not taken for missing rights.
  Future<bool> checkAccess() async {
    const read = LvsWire.tree;
    try {
      final response = await _wire.post(
        '/',
        query: read.fixedQuery,
        form: const {'id': '0'},
      );
      _parseTreeRoot(LvsWire.json(response, read));
      return true;
    } on SmartschoolLvsAccessDeniedError {
      return false;
    }
  }

  /// The pupils whose name matches [text], each with their class, in the
  /// LVS's order. Empty when no pupil matches. The classes the search also
  /// finds are left out.
  ///
  /// Several pupils can match. [LvsPupilMatch.name] is plain text: the
  /// LVS's markup that highlights the match is left out.
  ///
  /// A blank [text] is an [ArgumentError], before anything is sent.
  Future<List<LvsPupilMatch>> searchPupils(String text) async {
    final search = text.trim();
    if (search.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be blank');
    }
    const read = LvsWire.pupilSearch;
    final response = await _wire.get(
      '/LVS/Spotlight',
      query: {'searchVal': search},
    );
    return _parseSearch(LvsWire.json(response, read));
  }

  /// The overview of the file of pupil [pupilId] in class [classId] (an
  /// [LvsPupilMatch] of [searchPupils] has both): who, which class, the
  /// sections of the file with whether each holds something, and the
  /// pupil's attendance today.
  ///
  /// Two reads: the file, then today's status. The LVS answers a pupil it
  /// does not know in that class with a placeholder pupil, which is a
  /// [SmartschoolLvsPupilNotFoundError] (today's status is then not read).
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<LvsPupilFile> getPupilFile({
    required int pupilId,
    required int classId,
  }) async {
    if (pupilId <= 0) {
      throw ArgumentError.value(pupilId, 'pupilId', 'must be positive');
    }
    if (classId <= 0) {
      throw ArgumentError.value(classId, 'classId', 'must be positive');
    }
    final fileRead = LvsWire.pupilFile;
    final fileResponse = await _wire.get(
      '/LVS/Spotlight/$pupilId',
      query: {'classID': '$classId'},
    );
    final file = _parseFile(
      LvsWire.json(fileResponse, fileRead),
      pupilId: pupilId,
      classId: classId,
    );

    const statusRead = LvsWire.todayStatus;
    final statusResponse = await _wire.post(
      '/LVS/Pupilxhr/getStatusInfo',
      form: {'pupilID': '$pupilId'},
    );
    final status = _parseStatus(LvsWire.json(statusResponse, statusRead));
    return LvsPupilFile(
      pupilId: file.pupilId,
      classId: file.classId,
      name: file.name,
      className: file.className,
      classDescription: file.classDescription,
      teachers: file.teachers,
      sections: file.sections,
      todayStatus: status,
    );
  }

  /// The notes of category [categoryId] of the file of pupil [pupilId] in
  /// class [classId], with those of its sub-categories, in the LVS's order
  /// (#161). Empty when the category holds no notes in [schoolYear].
  ///
  /// [LvsPupilFile.noteCategories] lists the categories (the school's own:
  /// "gedrag", "zorg", ...). [schoolYear] is the period of the notes: the
  /// current school year (1 September to 31 August, Belgian time) when not
  /// given. Confidential notes come with [LvsNote.isConfidential] `true`:
  /// the LVS decides which ones the account receives, the library does not
  /// leave them out.
  ///
  /// One request: the dispatcher's `lvs_cats/getUserCatItems` with `catID`,
  /// `userID`, `toolbarType` `main`, `syRange` (`{"from", "until"}`),
  /// `groupID` and `toolbarSide` `left`, as the web client opens a category
  /// (without its list layouts, `getCatListView`). The library sends nothing
  /// else: no "viewed" flag, no edit lock. Whether the LVS itself takes the
  /// notes as seen by the account on this read (their [LvsNote.isNew]) was
  /// not captured (#168).
  ///
  /// The LVS answers a pupil it does not know in that class with its
  /// placeholder pupil, a [SmartschoolLvsPupilNotFoundError], and a category
  /// it does not know without the category, a
  /// [SmartschoolLvsCategoryNotFoundError] (both seen live for made-up IDs),
  /// never an empty list. An ID that is not positive, or a [schoolYear] that
  /// ends before it starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsNote>> getNotes({
    required int pupilId,
    required int classId,
    required int categoryId,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    _checkId(categoryId, 'categoryId');
    final period = _period(schoolYear);
    const read = LvsWire.categoryNotes;
    final response = await _wire.dispatch(read, {
      'catID': '$categoryId',
      'userID': '$pupilId',
      'toolbarType': 'main',
      'syRange': period,
      'groupID': '$classId',
      'toolbarSide': 'left',
    });
    final content = LvsWire.dispatcherContent(
      response,
      read,
      answer: 'renderPupilNotes',
    );
    return LvsNoteAnswers.categoryNotes(
      content,
      pupilId: pupilId,
      classId: classId,
      categoryId: categoryId,
    );
  }

  /// All notes of the file of pupil [pupilId] in class [classId], of every
  /// category, in the order of the LVS's "all items" view of the file (its
  /// `dates`) (#161). Empty when the file holds no notes in [schoolYear].
  ///
  /// [schoolYear] is as for [getNotes]. One request: the dispatcher's
  /// `lvs_pupils/getUserData` with `userID`, `toolbarType` `main`, `groupID`,
  /// `syRange`, `viewAllFilter` `[]` and `filterData` `0`, as the web client
  /// opens the view, before it shows its filter buttons. Its
  /// answer holds the file's reports, absences, evaluations, messages and
  /// signals too: only the notes are read.
  ///
  /// The LVS answers a pupil it does not know with no data at all (seen live
  /// for a made-up ID): an empty list, as for a pupil without notes.
  /// [getPupilFile] tells the two apart. An ID that is not positive, or a
  /// [schoolYear] that ends before it starts, is an [ArgumentError], before
  /// anything is sent.
  Future<List<LvsNote>> getAllNotes({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    final period = _period(schoolYear);
    const read = LvsWire.allNotes;
    final response = await _wire.dispatch(read, {
      'userID': '$pupilId',
      'toolbarType': 'main',
      'groupID': '$classId',
      'syRange': period,
      'viewAllFilter': '[]',
      'filterData': '0',
    });
    final content = LvsWire.dispatcherContent(
      response,
      read,
      answer: 'renderPupilAllNotes',
    );
    return LvsNoteAnswers.allNotes(content, pupilId: pupilId);
  }

  /// Throws an [ArgumentError] for an [id] that is not positive.
  static void _checkId(int id, String name) {
    if (id <= 0) throw ArgumentError.value(id, name, 'must be positive');
  }

  /// The `syRange` of [schoolYear], the current school year when `null`:
  /// `{"from":"YYYY-MM-DD","until":"YYYY-MM-DD"}`, as the LVS page sends it.
  static String _period(LvsSchoolYear? schoolYear) {
    final period = schoolYear ?? LvsSchoolYear.current();
    if (period.isEmpty) {
      throw ArgumentError.value(
        period,
        'schoolYear',
        'must not end before it starts',
      );
    }
    return jsonEncode({'from': period.firstDay, 'until': period.lastDay});
  }

  // ---------------------------------------------------------------------------
  // Answers
  // ---------------------------------------------------------------------------

  /// Checks the root of the left tree: a list whose first node is the LVS's
  /// root (`attributes.rel` `lvs`) with a list of `children` (the classes).
  static void _parseTreeRoot(Object? json) {
    const read = LvsWire.tree;
    if (json is! List || json.isEmpty || json.first is! Map) {
      throw LvsWire.unknownShape(read, 'not a list of tree nodes');
    }
    final root = json.first as Map;
    final attributes = root['attributes'];
    if (attributes is! Map || attributes['rel'] != 'lvs') {
      throw LvsWire.unknownShape(read, 'no root node (attributes.rel "lvs")');
    }
    final children = root['children'];
    if (children != null && children is! List) {
      throw LvsWire.unknownShape(read, 'children is not a list');
    }
  }

  /// The pupils of a search answer: `{pupils: [{userID, classID, className,
  /// foundName, ...}], ...}`.
  static List<LvsPupilMatch> _parseSearch(Object? json) {
    const read = LvsWire.pupilSearch;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    final pupils = json['pupils'];
    if (pupils is! List) {
      throw LvsWire.unknownShape(read, 'no list of pupils');
    }
    return [
      for (final (i, pupil) in pupils.indexed) _parseMatch(pupil, 'pupils[$i]'),
    ];
  }

  static LvsPupilMatch _parseMatch(Object? pupil, String where) {
    const read = LvsWire.pupilSearch;
    if (pupil is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final pupilId = LvsWire.tryId(pupil['userID']);
    final classId = LvsWire.tryId(pupil['classID']);
    final foundName = pupil['foundName'];
    final className = pupil['className'];
    if (pupilId == null || pupilId <= 0) {
      throw LvsWire.unknownShape(read, '$where: no userID');
    }
    if (classId == null || classId <= 0) {
      throw LvsWire.unknownShape(read, '$where: no classID');
    }
    if (foundName is! String) {
      throw LvsWire.unknownShape(read, '$where: no foundName');
    }
    if (className != null && className is! String) {
      throw LvsWire.unknownShape(read, '$where: className is not a text');
    }
    return LvsPupilMatch(
      pupilId: pupilId,
      classId: classId,
      name: LvsWire.plainText(foundName),
      className: (className as String?)?.trim() ?? '',
    );
  }

  /// A pupil's file without today's status: `{categories: [...], pupil:
  /// {pupilID, name, class, classDesc, classID, teachers, ...}}`.
  static LvsPupilFile _parseFile(
    Object? json, {
    required int pupilId,
    required int classId,
  }) {
    final read = LvsWire.pupilFile;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    final pupil = json['pupil'];
    final categories = json['categories'];
    if (pupil is! Map) throw LvsWire.unknownShape(read, 'no pupil');
    if (categories is! List) {
      throw LvsWire.unknownShape(read, 'no list of categories');
    }
    if (LvsWire.tryId(pupil['pupilID']) != pupilId) {
      throw LvsWire.unknownShape(read, 'the pupil is not the one asked for');
    }
    // The LVS's placeholder for a pupil it does not know in that class: a
    // class of `null` (seen live, with a "not available" name).
    final answerClassId = pupil['classID'];
    if (answerClassId == null) {
      throw SmartschoolLvsPupilNotFoundError(
        'The LVS knows no such pupil in that class that the account may see '
        '(it answered with its placeholder pupil).',
        pupilId: pupilId,
        classId: classId,
      );
    }
    final fileClassId = LvsWire.tryId(answerClassId);
    if (fileClassId == null || fileClassId <= 0) {
      throw LvsWire.unknownShape(read, 'pupil.classID is not an ID');
    }
    final name = pupil['name'];
    if (name is! String) throw LvsWire.unknownShape(read, 'no pupil.name');
    return LvsPupilFile(
      pupilId: pupilId,
      classId: fileClassId,
      name: name.trim(),
      className: _text(pupil['class'], 'pupil.class'),
      classDescription: _text(pupil['classDesc'], 'pupil.classDesc'),
      teachers: _parseTeachers(pupil['teachers']),
      sections: [
        for (final (i, node) in categories.indexed)
          _parseSection(node, 'categories[$i]'),
      ],
      todayStatus: LvsTodayStatus.none,
    );
  }

  /// [value] as a text of the file: a string, trimmed, or `''` for none.
  static String _text(Object? value, String where) {
    if (value == null) return '';
    if (value is! String) {
      throw LvsWire.unknownShape(LvsWire.pupilFile, '$where is not a text');
    }
    return value.trim();
  }

  /// The class teachers: `{"<teacher id>": "<name>"}`, or `[]` for none (PHP
  /// sends an empty map as a list; seen live).
  static List<LvsTeacher> _parseTeachers(Object? teachers) {
    final read = LvsWire.pupilFile;
    if (teachers == null || (teachers is List && teachers.isEmpty)) {
      return const [];
    }
    if (teachers is! Map) {
      throw LvsWire.unknownShape(read, 'pupil.teachers is not a map');
    }
    final result = <LvsTeacher>[];
    for (final MapEntry(:key, :value) in teachers.entries) {
      final id = LvsWire.tryId(key);
      if (id == null || id <= 0 || value is! String) {
        throw LvsWire.unknownShape(
          read,
          'pupil.teachers: not an ID and a name',
        );
      }
      result.add(LvsTeacher(id: id, name: value.trim()));
    }
    return result;
  }

  /// A node of `categories`: `{id, type, name, isTitle, hasItems,
  /// hasNewItems, hasChildren, children, ...}`.
  static LvsSection _parseSection(Object? node, String where) {
    final read = LvsWire.pupilFile;
    if (node is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final id = LvsWire.tryId(node['id']);
    final type = node['type'];
    final name = node['name'];
    if (id == null || id < 0) {
      throw LvsWire.unknownShape(read, '$where: no id');
    }
    if (type is! String || type.trim().isEmpty) {
      throw LvsWire.unknownShape(read, '$where: no type');
    }
    if (name is! String) throw LvsWire.unknownShape(read, '$where: no name');
    bool flag(String key) {
      final value = node[key];
      if (value == null) return false;
      return LvsWire.tryFlag(value) ??
          (throw LvsWire.unknownShape(read, '$where: $key is not a flag'));
    }

    final children = node['children'];
    if (children != null && children is! List) {
      throw LvsWire.unknownShape(read, '$where: children is not a list');
    }
    return LvsSection(
      id: id,
      type: type.trim(),
      name: name.trim(),
      isTitle: flag('isTitle'),
      hasItems: flag('hasItems'),
      hasNewItems: flag('hasNewItems'),
      children: [
        for (final (i, child) in ((children as List?) ?? const []).indexed)
          _parseSection(child, '$where.children[$i]'),
      ],
    );
  }

  /// Today's status: `[{partOfDay, code: {name, code, color}}]`, `[]` for
  /// none.
  static LvsTodayStatus _parseStatus(Object? json) {
    const read = LvsWire.todayStatus;
    final List<Object?> halfDays;
    if (json is List) {
      halfDays = json;
    } else if (json is Map) {
      // PHP sends a list with gaps in its keys as a map.
      halfDays = json.values.toList();
    } else {
      throw LvsWire.unknownShape(read, 'not a list');
    }
    return LvsTodayStatus([
      for (final (i, halfDay) in halfDays.indexed)
        _parseHalfDay(halfDay, '[$i]'),
    ]);
  }

  static LvsHalfDayStatus _parseHalfDay(Object? halfDay, String where) {
    const read = LvsWire.todayStatus;
    if (halfDay is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final partOfDay = halfDay['partOfDay'];
    final code = halfDay['code'];
    if (partOfDay is! String || partOfDay.trim().isEmpty) {
      throw LvsWire.unknownShape(read, '$where: no partOfDay');
    }
    if (code is! Map) throw LvsWire.unknownShape(read, '$where: no code');
    String? text(String key) => switch (code[key]) {
      final String value => value.trim(),
      final num value => '$value',
      _ => null,
    };
    final short = text('code');
    final name = text('name');
    if (short == null) {
      throw LvsWire.unknownShape(read, '$where: no code.code');
    }
    if (name == null) {
      throw LvsWire.unknownShape(read, '$where: no code.name');
    }
    final color = text('color');
    return LvsHalfDayStatus(
      partOfDay: partOfDay.trim(),
      code: short,
      name: name,
      color: color == null || color.isEmpty ? null : color,
    );
  }
}
