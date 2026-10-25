// The notes in the answers of the LVS's XML dispatcher (#161). Internal: not
// exported by the library.
//
// The web client reads these answers by the position of each child, not by
// its name (`getData(e.childNodes[5])`), and so does this file. The names
// below are the web client's. The shapes (read from the LVS's JavaScript,
// 2026-10-21; seen live for a made-up pupil and category: the envelope and
// the children 0 to 9 of `renderPupilNotes`, 0 to 12 of `renderPupilAllNotes`)
// are, with placeholders only (doc/lvs-privacy.md):
//
// renderPupilNotes (lvs_cats/getUserCatItems), the children of `content`:
//   [0] hasData (0 or 1)  [1] buttons (the toolbar)  [2] updateToolbar
//   [3] pupilID  [4] catID  [5] catInfo, JSON of the category read:
//   {catID, parentID, name, catType, ...}, or {icon, gFilter, following}
//   without catID and name for a category the LVS does not know (seen live)
//   [6] hideWindow  [7] catFilter, JSON {start, end}  [8] pupilInfo, JSON:
//   {pupilID, name, class, classDesc, classID, teachers, ...}, classID null
//   for the LVS's placeholder pupil (seen live)  [9] viewType
//   (form|list|title, or empty); with hasData 1 also [10] the notes,
//   [11] the categories' info, [12] their order, [13] their views (JSON).
//   The notes are the category's own, never those of its sub-categories
//   (seen live for a real pupil, #180: a parent read without the note of
//   its sub-category, the sub-category read with it; the categories' info
//   of a browser capture described the one category read, #168).
//
// Neither answer keeps to the `syRange` it was asked for (seen live, #180:
// notes of other school years, by their date and by their `schoolyear`):
// LvsService keeps the notes of the period itself, not this file.
//
// renderPupilAllNotes (lvs_pupils/getUserData), the children of `content`:
//   [0] hasData  [1] buttons  [2] updateToolbar  [3] pupilID  [4] dates,
//   JSON: the items in the order of the "all items" view, each "n_<note
//   id>", "r_<report id>", "a_<absence id>", "e_<evaluation id>",
//   "m_<link id>" or "s_<signal id>"  [5] reports  [6] absences  [7] notes
//   [8] filterData  [9] evals  [10] skore_rights  [11] messages
//   [12] smartsignals (JSON). This file reads the notes only.
//
// A note (a child of the notes), by position: [0] itemID [1] groupID
//   [2] pupilID [3] catID [4] title [5] date (Unix time) [6] author
//   [7] rights (JSON) [8] assigned [9] assignees (JSON) [10] history
//   [11] params (the fields) [12] viewed [13] privateFile (1: confidential)
//   [14] studierichting [15] itemGroupID [16] authorSex [17] bulkID
//   [18] schoolyear ("<YYYY-YYYY>") [19] isNew [20] originalCreate; and, in
//   newer answers, [21] catName [22] authorReverse.
//
// A field (a child of params), by position: [0] itemID [1] paramID [2] type
//   [3] val [4] title [5] optionValue [6] itemType [7] sortorder. By type:
//   1 text, 2 rich text (HTML) in val; 3 radio, 4 checkbox, 5 select: the
//   option IDs in val (comma-separated), the shown text in optionValue;
//   6 attachments: optionValue JSON {"<file id>": {fileName, fileMime,
//   fileHash}}; 7 date: val a Unix time (or empty); 8 heading: its text in
//   title, its level in optionValue.
import 'dart:convert';

import 'package:xml/xml.dart';

import '../exceptions.dart';
import '../models/lvs_models.dart';
import '../models/lvs_time.dart';
import 'lvs_wire.dart';

/// Reads the notes of the answers of [LvsWire.categoryNotes] and
/// [LvsWire.allNotes].
abstract final class LvsNoteAnswers {
  /// The notes of `renderPupilNotes`, the answer to the notes of category
  /// [categoryId] of pupil [pupilId] in class [classId], in the LVS's order:
  /// the category's own, never those of its sub-categories (#180), of any
  /// school year the LVS answers with.
  ///
  /// Throws a [SmartschoolLvsPupilNotFoundError] for the LVS's placeholder
  /// pupil, a [SmartschoolLvsCategoryNotFoundError] for a category it does
  /// not know, and a [SmartschoolLvsError] for an unknown shape.
  static List<LvsNote> categoryNotes(
    XmlElement content, {
    required int pupilId,
    required int classId,
    required int categoryId,
  }) {
    const read = LvsWire.categoryNotes;
    final parts = content.childElements.toList();
    if (parts.length < 10) {
      throw LvsWire.unknownShape(read, 'fewer than 10 parts');
    }
    if (LvsWire.tryId(_text(parts[3])) != pupilId) {
      throw LvsWire.unknownShape(read, 'the pupil is not the one asked for');
    }
    if (LvsWire.tryId(_text(parts[4])) != categoryId) {
      throw LvsWire.unknownShape(read, 'the category is not the one asked for');
    }
    final pupil = _json(parts[8], read, 'pupilInfo');
    if (pupil is! Map) throw LvsWire.unknownShape(read, 'pupilInfo');
    if (pupil.containsKey('pupilID') &&
        LvsWire.tryId(pupil['pupilID']) != pupilId) {
      throw LvsWire.unknownShape(read, 'pupilInfo is not the pupil asked for');
    }
    if (!pupil.containsKey('classID')) {
      throw LvsWire.unknownShape(read, 'pupilInfo without classID');
    }
    // The LVS's placeholder pupil, as in the pupil's file (#160): a class
    // of `null` (seen live for a made-up pupil ID).
    if (pupil['classID'] == null) {
      throw SmartschoolLvsPupilNotFoundError(
        'The LVS knows no such pupil in that class that the account may see '
        '(it answered with its placeholder pupil).',
        pupilId: pupilId,
        classId: classId,
      );
    }
    final category = _json(parts[5], read, 'catInfo');
    // A category the LVS does not know: no catID (seen live). None at all,
    // or `[]` (PHP's empty map), is taken the same way.
    if (category is! Map || !category.containsKey('catID')) {
      throw SmartschoolLvsCategoryNotFoundError(
        'The LVS knows no such category of notes (it answered without the '
        'category).',
        pupilId: pupilId,
        classId: classId,
        categoryId: categoryId,
      );
    }
    if (LvsWire.tryId(category['catID']) != categoryId) {
      throw LvsWire.unknownShape(read, 'catInfo is not the category asked for');
    }
    final categoryName = switch (category['name']) {
      final String name => name.trim(),
      _ => '',
    };
    if (!_hasData(parts[0], read)) return const [];
    if (parts.length < 11) throw LvsWire.unknownShape(read, 'no notes');
    return _notes(
      parts[10],
      read,
      pupilId: pupilId,
      categoryNames: {categoryId: categoryName},
    );
  }

  /// The notes of `renderPupilAllNotes`, the answer to all of the file of
  /// pupil [pupilId], of any school year the LVS answers with, in the order
  /// of the LVS's "all items" view (its `dates`); a note it leaves out of
  /// that order comes after, in the answer's order.
  static List<LvsNote> allNotes(XmlElement content, {required int pupilId}) {
    const read = LvsWire.allNotes;
    final parts = content.childElements.toList();
    if (parts.length < 8) {
      throw LvsWire.unknownShape(read, 'fewer than 8 parts');
    }
    if (LvsWire.tryId(_text(parts[3])) != pupilId) {
      throw LvsWire.unknownShape(read, 'the pupil is not the one asked for');
    }
    if (!_hasData(parts[0], read)) return const [];
    final notes = _notes(parts[7], read, pupilId: pupilId);
    final order = <int, int>{};
    for (final (i, id) in _noteOrder(_json(parts[4], read, 'dates')).indexed) {
      order.putIfAbsent(id, () => i);
    }
    final indexed = notes.indexed.toList()
      ..sort((a, b) {
        final byOrder = (order[a.$2.id] ?? order.length + a.$1).compareTo(
          order[b.$2.id] ?? order.length + b.$1,
        );
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    return [for (final (_, note) in indexed) note];
  }

  /// The note IDs of `dates`, in the order the web client walks it: a list
  /// in its order; a map as JavaScript walks an object, its keys that are
  /// array indices first, in ascending order, then the others in the
  /// answer's order. Its values are `"n_<id>"` for a note, another letter for
  /// the other items.
  static List<int> _noteOrder(Object? dates) {
    const read = LvsWire.allNotes;
    final List<Object?> items;
    if (dates is List) {
      items = dates;
    } else if (dates is Map) {
      final keys = dates.keys.map((key) => '$key').toList();
      final indices =
          keys
              .where((key) => RegExp(r'^(0|[1-9]\d{0,8})$').hasMatch(key))
              .toList()
            ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
      final others = keys.where((key) => !indices.contains(key));
      items = [
        for (final key in [...indices, ...others]) dates[key],
      ];
    } else {
      throw LvsWire.unknownShape(read, 'dates is not a list');
    }
    final ids = <int>[];
    for (final item in items) {
      if (item is! String) {
        throw LvsWire.unknownShape(read, 'an item of dates is not a text');
      }
      final note = RegExp(r'^n_(\d+)$').firstMatch(item.trim());
      if (note != null) ids.add(int.parse(note.group(1)!));
    }
    return ids;
  }

  /// Whether `hasData` says the answer holds data.
  static bool _hasData(XmlElement part, LvsRead read) {
    final value = LvsWire.tryId(_text(part));
    if (value == null) throw LvsWire.unknownShape(read, 'hasData');
    return value != 0;
  }

  /// The notes, the children of [notes]. [categoryNames] names the
  /// categories whose notes come without their `catName`.
  static List<LvsNote> _notes(
    XmlElement notes,
    LvsRead read, {
    required int pupilId,
    Map<int, String> categoryNames = const {},
  }) => [
    for (final (i, note) in notes.childElements.indexed)
      _note(
        note,
        read,
        'notes[$i]',
        pupilId: pupilId,
        categoryNames: categoryNames,
      ),
  ];

  static LvsNote _note(
    XmlElement note,
    LvsRead read,
    String where, {
    required int pupilId,
    required Map<int, String> categoryNames,
  }) {
    final parts = note.childElements.toList();
    if (parts.length < 20) {
      throw LvsWire.unknownShape(read, '$where: fewer than 20 parts');
    }
    final id = LvsWire.tryId(_text(parts[0]));
    if (id == null || id <= 0) {
      throw LvsWire.unknownShape(read, '$where: no itemID');
    }
    if (LvsWire.tryId(_text(parts[2])) != pupilId) {
      throw LvsWire.unknownShape(read, '$where: not a note of the pupil');
    }
    final categoryId = LvsWire.tryId(_text(parts[3]));
    if (categoryId == null || categoryId <= 0) {
      throw LvsWire.unknownShape(read, '$where: no catID');
    }
    final seconds = LvsWire.tryId(_text(parts[5]));
    if (seconds == null || seconds <= 0) {
      throw LvsWire.unknownShape(read, '$where: the date is not a time');
    }
    final catName = parts.length > 21 ? _text(parts[21]).trim() : '';
    return LvsNote(
      id: id,
      categoryId: categoryId,
      categoryName: catName.isNotEmpty
          ? catName
          : categoryNames[categoryId] ?? '',
      title: _text(parts[4]).trim(),
      date: _fromUnix(seconds),
      author: _text(parts[6]).trim(),
      isConfidential: _flag(parts[13]),
      isNew: _flag(parts[19]),
      viewed: _flag(parts[12]),
      schoolYear: _text(parts[18]).trim(),
      fields: [
        for (final (i, field) in parts[11].childElements.indexed)
          _field(field, read, '$where.params[$i]'),
      ],
    );
  }

  static LvsNoteField _field(XmlElement field, LvsRead read, String where) {
    final parts = field.childElements.toList();
    if (parts.length < 6) {
      throw LvsWire.unknownShape(read, '$where: fewer than 6 parts');
    }
    final paramId = LvsWire.tryId(_text(parts[1]));
    if (paramId == null || paramId < 0) {
      throw LvsWire.unknownShape(read, '$where: no paramID');
    }
    // An unreadable type is a type the library does not know: kept.
    final typeCode = LvsWire.tryId(_text(parts[2])) ?? 0;
    final type = LvsNoteFieldType.of(typeCode);
    final raw = _text(parts[3]);
    final rawOption = _text(parts[5]);
    final label = LvsWire.plainText(_text(parts[4]));
    LvsNoteField make(
      String value, {
      String? html,
      List<int> optionIds = const [],
      DateTime? date,
      List<LvsAttachment> attachments = const [],
    }) => LvsNoteField(
      paramId: paramId,
      typeCode: typeCode,
      type: type,
      label: label,
      value: value,
      html: html,
      optionIds: optionIds,
      date: date,
      attachments: attachments,
      rawValue: raw,
      rawOptionValue: rawOption,
    );

    switch (type) {
      case LvsNoteFieldType.text:
        return make(raw.trim());
      case LvsNoteFieldType.richText:
        return make(LvsWire.plainText(raw), html: raw);
      case LvsNoteFieldType.radio ||
          LvsNoteFieldType.checkbox ||
          LvsNoteFieldType.select:
        return make(
          LvsWire.plainText(rawOption),
          optionIds: _optionIds(raw, read, where),
        );
      case LvsNoteFieldType.attachment:
        final attachments = _attachments(rawOption, read, where);
        return make(
          attachments.map((a) => a.name).join('\n'),
          attachments: attachments,
        );
      case LvsNoteFieldType.date:
        final value = raw.trim();
        final seconds = RegExp(r'^\d+$').hasMatch(value)
            ? int.parse(value)
            : null;
        if (seconds == null) return make(value);
        final date = _fromUnix(seconds);
        return make(isoDay(brusselsWallTime(date)), date: date);
      case LvsNoteFieldType.heading:
        return make('');
      case LvsNoteFieldType.unknown:
        return make(raw.trim());
    }
  }

  /// The option IDs of a choice's `val`: comma-separated, or empty.
  static List<int> _optionIds(String value, LvsRead read, String where) {
    final ids = <int>[];
    for (final part in value.split(',')) {
      if (part.trim().isEmpty) continue;
      final id = LvsWire.tryId(part);
      if (id == null) {
        throw LvsWire.unknownShape(read, '$where: an option is not an ID');
      }
      ids.add(id);
    }
    return ids;
  }

  /// The attachments of an attachment field's `optionValue`: JSON
  /// `{"<file id>": {fileName, fileMime, ...}}`, or empty (`""`, `[]`,
  /// `{}`).
  static List<LvsAttachment> _attachments(
    String value,
    LvsRead read,
    String where,
  ) {
    if (value.trim().isEmpty) return const [];
    final Object? json;
    try {
      json = jsonDecode(value);
    } on FormatException {
      throw LvsWire.unknownShape(read, '$where: the attachments are not JSON');
    }
    if (json is List && json.isEmpty) return const [];
    if (json is! Map) {
      throw LvsWire.unknownShape(read, '$where: the attachments are no map');
    }
    return [
      for (final MapEntry(:key, :value) in json.entries)
        _attachment(key, value, read, where),
    ];
  }

  static LvsAttachment _attachment(
    Object? key,
    Object? file,
    LvsRead read,
    String where,
  ) {
    final id = LvsWire.tryId('$key');
    if (id == null || file is! Map || file['fileName'] is! String) {
      throw LvsWire.unknownShape(read, '$where: an attachment');
    }
    return LvsAttachment(
      id: id,
      name: (file['fileName'] as String).trim(),
      mimeType: switch (file['fileMime']) {
        final String mime => mime.trim(),
        _ => '',
      },
    );
  }

  /// The JSON in [part], named [name] for messages.
  static Object? _json(XmlElement part, LvsRead read, String name) {
    final text = _text(part).trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw LvsWire.unknownShape(read, '$name is not JSON');
    }
  }

  /// A flag of a note: a number, `0` or empty for "no".
  static bool _flag(XmlElement part) => (LvsWire.tryId(_text(part)) ?? 0) > 0;

  /// The text of [part], as the web client reads it: its text and CDATA,
  /// joined (a `]]>` split over two CDATA sections comes back whole).
  static String _text(XmlElement part) => part.innerText;

  /// The UTC time of the Unix time [seconds].
  static DateTime _fromUnix(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
