// Guard for #159: the LVS fixtures are written by hand, with fakes only.
//
// The pupil tracking system (LVS, `/?module=LVS`) holds the most sensitive
// data of Smartschool: notes on behaviour and care, educational needs,
// sometimes health. Its fixtures (test/fixtures/lvs/) are never a live answer
// trimmed down, as a forgotten sentence would be a leak: they are written by
// hand, in the shape the research found, with the fakes of
// test/fixtures/lvs/FAKES.md. The rules are in doc/lvs-privacy.md. This test
// checks what a test can of them:
//
// - every file under test/fixtures/lvs/ (but FAKES.md) sits in the folder of
//   a fixture kind registered in [lvsFixtureKinds], and parses as JSON, XML
//   or HTML, by its extension;
// - every value of a name-like field is on the fake list;
// - every number in an id-like field is in the reserved range (or below 100,
//   which identifies nothing), and no hash or real-looking UUID is in one;
// - every value of a text-like field is an obvious fake: it says "test";
// - no file there is larger than [lvsFixtureMaxBytes], to catch a pasted
//   live answer;
// - no file anywhere under test/ holds a base64 string that decodes to a name
//   that is not made of the words of the fake list (Skore's `alternate`
//   carries a pupil's name like that).
//
// A failure names the file and the field, never the value: a test log is
// easily pasted in an issue.
//
// A new kind of LVS fixture (the answers of one endpoint, say): put its files
// in a folder of their own under test/fixtures/lvs/ and add an
// [LvsFixtureKind] for that folder to [lvsFixtureKinds], with the fields of
// its answers that hold names, ids or free text beyond the common ones
// ([commonNameFields], [commonIdFields], [commonTextFields]), and, for fields
// known by position only, an [LvsFixtureKind.extraFields] function (see the
// `example` kind).
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'support/no_network.dart';

/// The folder of the LVS fixtures.
const lvsFixturesFolder = 'test/fixtures/lvs';

/// The list of fakes, in [lvsFixturesFolder].
const lvsFakesFile = '$lvsFixturesFolder/FAKES.md';

/// The lowest id an LVS fixture may hold.
const lvsIdMin = 900000;

/// The highest id an LVS fixture may hold.
const lvsIdMax = 999999;

/// Numbers below this in an id-like field (0 for "none", a type, a flag)
/// identify nothing and are let through.
const lvsSmallNumberLimit = 100;

/// The largest an LVS fixture may be, in bytes. A hand-written fixture is
/// far smaller; a bigger file is likely a pasted live answer.
const lvsFixtureMaxBytes = 20 * 1024;

/// What a field of a fixture holds, for the checks.
enum LvsFieldType {
  /// A person, school, class or label: one of the fake list.
  name,

  /// An id: every number in it in the reserved range.
  id,

  /// Free text: an obvious fake, which says "test".
  text,
}

/// A value of a fixture to check: where it is, and what it holds.
class LvsField {
  const LvsField(this.path, this.type, this.value);

  /// Where the value is, without the value itself.
  final String path;

  final LvsFieldType type;

  /// A `String`, a number, a `bool` or `null`; anything else is not checked.
  final Object? value;
}

/// The fields that hold a name in every LVS fixture: a JSON key, an XML
/// element or attribute, or an HTML attribute, element or class of that
/// name, as [normalizedFieldName] gives it.
const commonNameFields = {
  'name',
  'firstname',
  'lastname',
  'surname',
  'fullname',
  'displayname',
  'foundname',
  'username',
  'pupilname',
  'studentname',
  'teachername',
  'authorname',
  'ownername',
  'parentname',
  'author',
  'authorreverse',
  'teacher',
  'teachers',
  'titularis',
  'titularissen',
  'startingwithfirstname',
  'startingwithlastname',
  'schoolname',
  'class',
  'classname',
  'groupname',
  'coursename',
  'catname',
  'categoryname',
};

/// The fields that hold an id in every LVS fixture, as
/// [normalizedFieldName] gives them, on top of every name that ends in an
/// id by its spelling: `id`, `pupil_id`, `data-pupil-id`, `pupilId`,
/// `classID`, `courseIds`.
const commonIdFields = {
  'pid',
  'gid',
  'uid',
  'userid',
  'pupilid',
  'studentid',
  'teacherid',
  'authorid',
  'ownerid',
  'classid',
  'groupid',
  'catid',
  'categoryid',
  'itemid',
  'noteid',
  'courseid',
  'periodid',
  'paramid',
  'optionid',
  'versionid',
  'reportid',
  'fileid',
  'linkid',
  'bulkid',
  'absentid',
  'identifier',
  'evaluationidentifier',
  'avatarhash',
  'picturehash',
  'filehash',
  'picurl',
  'pictureurl',
  'downloadurl',
};

/// The fields that hold free text in every LVS fixture, as
/// [normalizedFieldName] gives them.
const commonTextFields = {'text', 'motivation', 'comment', 'remark'};

/// A kind of LVS fixture: the files in one folder of [lvsFixturesFolder],
/// and the fields of its answers that the guard checks on top of the common
/// ones.
class LvsFixtureKind {
  const LvsFixtureKind({
    required this.folder,
    required this.about,
    this.nameFields = const {},
    this.idFields = const {},
    this.textFields = const {},
    this.extraFields,
  });

  /// The folder of its files, under [lvsFixturesFolder] (one level).
  final String folder;

  /// What the files are answers of, and the issue that added them.
  final String about;

  /// Field names (JSON keys, XML elements or attributes, HTML attributes,
  /// elements or classes) that hold a name in these files, as spelled in
  /// the answer or as [normalizedFieldName] gives them.
  final Set<String> nameFields;

  /// Field names that hold an id in these files.
  final Set<String> idFields;

  /// Field names that hold free text in these files.
  final Set<String> textFields;

  /// The fields that names cannot find, such as the children of an XML node
  /// that the answer knows by position only; given the parsed file (the
  /// decoded JSON, an [XmlDocument] or an [html.Document]).
  final Iterable<LvsField> Function(Object? document)? extraFields;
}

/// The kinds of LVS fixtures. The LVS issues (#160 to #164) add theirs.
const lvsFixtureKinds = <LvsFixtureKind>[
  LvsFixtureKind(
    folder: 'example',
    about:
        'Made-up answers (#159), not shapes of the LVS: the fakes in use, '
        'and fields known by position only, as a model for the real kinds.',
    nameFields: {'tutor'},
    textFields: {'summary'},
    extraFields: _exampleNoteFields,
  ),
  LvsFixtureKind(
    folder: 'spotlight',
    about:
        'Answers of GET /LVS/Spotlight (#160): the pupil search '
        '(?searchVal=<text>) and the overview of a pupil\'s file '
        '(/<pupil id>?classID=<class id>), with the placeholder pupil the LVS '
        'answers for a pupil it does not know.',
    // `search` echoes the text searched for (a name); `classDesc` is the
    // school's description of a class; `keyword` is a teacher's keyword on
    // the pupil.
    nameFields: {'search', 'classDesc'},
    textFields: {'keyword'},
  ),
  LvsFixtureKind(
    folder: 'status',
    about:
        'Answers of POST /LVS/Pupilxhr/getStatusInfo (#160): a pupil\'s '
        'attendance today, per half-day.',
  ),
  LvsFixtureKind(
    folder: 'tree',
    about:
        'Answers of POST /?module=LVS&file=treeBuilder (#160): the root of '
        'the LVS\'s left tree, the classes the account may see.',
    // A node's `data.title` is its label: a class name, or Smartschool's
    // own title of the root.
    nameFields: {'title'},
  ),
  LvsFixtureKind(
    folder: 'notes',
    about:
        'Answers of the XML dispatcher, POST /?module=LVS&file=dispatcher '
        '(#161): the notes of a category (lvs_cats/getUserCatItems, action '
        'renderPupilNotes) and all of a pupil\'s file (lvs_pupils/getUserData, '
        'action renderPupilAllNotes).',
    // `studierichting` and `classDesc` describe a class; `title` is a note's
    // title and a field's label (a school's own label: one that says
    // "test"); `keyword` a teacher's keyword on the pupil; `fileName` the
    // name of an attachment; `dates` lists the items as "n_<note id>".
    nameFields: {'studierichting', 'classDesc'},
    idFields: {'dates'},
    textFields: {'title', 'keyword', 'fileName'},
    extraFields: _dispatcherNoteFields,
  ),
  LvsFixtureKind(
    folder: 'results',
    about:
        'Answers of the results app\'s GETs, /LVS/Results/* (#162): what it '
        'may show (getConfiguration), the periods (getperiods), courses '
        '(getcourses), a page of evaluations (getevaluationsofuser), the '
        'feedback (getfeedback) and the reports (getreports) of a pupil.',
    // `abbreviation` is a component's (a school's own label); `sort` of a
    // teacher is their name as a sort key (a number elsewhere); `goalId` and
    // `leerplanId` are UUIDs; `leerplanKey` names a curriculum. The texts of
    // the feedback are `text` (common).
    nameFields: {'abbreviation', 'sort'},
    idFields: {'goalId', 'leerplanId'},
    textFields: {'leerplanKey'},
  ),
  LvsFixtureKind(
    folder: 'supportplan',
    about:
        'Answers of the LVS\'s JSON dispatchers for the support plans (#163): '
        'the menu of periods (jqDispatcher_settings, getLVSspecificTitles), '
        'the individual plan (jqDispatcher_hp, getIHP) and the profile '
        'sketch (jqDispatcher_hp, getProfielSchets).',
    // `titleText` names a period or a heading of the menu, `title` the
    // menu's current title and a course of a plan; `className_teacher` is
    // the pupil's class. The plan's support needs, goals, objectives,
    // approach and planning (`ondName`, `doelName`, `parentName`,
    // `aanpakName`, `occName`), its theme, start situation and comment
    // (`themeName`, `beginsituatie`, `aanpakcomment`), a goal's domain
    // (`path`), the sketch (`content`, `lastrevision`), a period's
    // `message` and an uploaded plan's `fileName` are free text.
    nameFields: {'titleText', 'title', 'className_teacher'},
    textFields: {
      'ondName',
      'doelName',
      'parentName',
      'aanpakName',
      'occName',
      'themeName',
      'beginsituatie',
      'aanpakcomment',
      'path',
      'content',
      'lastrevision',
      'message',
      'fileName',
    },
  ),
  LvsFixtureKind(
    folder: 'absences',
    about:
        'Answers of POST /LVS/Pupilpresences (#164, #176): a pupil\'s '
        'absences per school year (a list of days each), as the file\'s '
        'absences section lists them.',
    // `codeDescr` is the description of a school's absence code (a label),
    // `codeKey` the key of the code (ids: `<n>` or `<n>-<n>`); the
    // motivation is `motivation` (common). The keys of `presences` are
    // school years (`2030-2031`, no label) or labels of periods:
    // _absencePeriodLabels. Not checked: `formattedDate` (a day, made up as
    // FAKES.md says; no field type tells a made-up day), and `partOfDay`,
    // `lng_months`, `lng_days` and `lng_noresults`, words of Smartschool
    // itself.
    nameFields: {'codeDescr'},
    idFields: {'codeKey'},
    extraFields: _absencePeriodLabels,
  ),
];

/// The labels of the periods of an `absences` fixture: the keys of its
/// `presences` that are not a school year `YYYY-YYYY` (a school's own
/// labels), which no field name finds. A school year, as the LVS keys the
/// periods of a pupil's file (#176), is no label.
Iterable<LvsField> _absencePeriodLabels(Object? document) sync* {
  if (document is! Map) return;
  final presences = document['presences'];
  if (presences is! Map) return;
  for (final (i, label) in presences.keys.indexed) {
    if (_schoolYearKey.hasMatch('$label')) continue;
    yield LvsField('presences key [$i]', LvsFieldType.name, '$label');
  }
}

/// A key of an `absences` fixture's `presences` that is a school year.
final _schoolYearKey = RegExp(r'^\d{4}-\d{4}$');

/// The fields of the notes of a `notes` fixture by their position, as the
/// service reads them (the names of the elements in a note are not
/// captured): the notes are the children of the 11th child of the
/// action's content for `renderPupilNotes`, of the 8th for
/// `renderPupilAllNotes`. A note's children: [0] itemID, [1] groupID,
/// [2] pupilID, [3] catID (ids), [4] title (text), [6] author (name),
/// [10] its history (each entry's [1], an author), [11] its fields,
/// [14] studierichting (name), [15] itemGroupID, [17] bulkID (ids),
/// [21] catName, [22] authorReverse (names). A field's: [0] itemID,
/// [1] paramID (ids), [4] its label (text: a school's own label says
/// "test"), and by its type [2]: [3] val, a text for a text (1) or a rich
/// text (2) and a type the service does not know, option IDs for a choice
/// (3, 4, 5); [5] optionValue, the options' text for a choice and an
/// unknown type, JSON of the attachments for 6 (a map from file IDs to
/// `{fileName, ...}`).
Iterable<LvsField> _dispatcherNoteFields(Object? document) sync* {
  if (document is! XmlDocument) return;
  for (final action in document.findAllElements('action')) {
    final parts = action.childElements.toList();
    if (parts.length < 3) continue;
    final notesAt = switch (parts[1].innerText.trim()) {
      'renderPupilNotes' => 10,
      'renderPupilAllNotes' => 7,
      _ => null,
    };
    final content = parts[2].childElements.firstOrNull;
    if (notesAt == null || content == null) continue;
    final contentParts = content.childElements.toList();
    // The pupil ([3]) and, for renderPupilNotes, the category ([4]).
    for (final i in notesAt == 10 ? const [3, 4] : const [3]) {
      if (i < contentParts.length) {
        yield LvsField(
          'content[$i]',
          LvsFieldType.id,
          contentParts[i].innerText,
        );
      }
    }
    if (notesAt >= contentParts.length) continue;
    const notePositions = {
      0: LvsFieldType.id,
      1: LvsFieldType.id,
      2: LvsFieldType.id,
      3: LvsFieldType.id,
      4: LvsFieldType.text,
      6: LvsFieldType.name,
      14: LvsFieldType.name,
      15: LvsFieldType.id,
      17: LvsFieldType.id,
      21: LvsFieldType.name,
      22: LvsFieldType.name,
    };
    for (final (n, note) in contentParts[notesAt].childElements.indexed) {
      final values = note.childElements.toList();
      final where = 'content[$notesAt] note[$n]';
      for (final MapEntry(key: i, value: type) in notePositions.entries) {
        if (i < values.length) {
          yield LvsField('$where child [$i]', type, values[i].innerText);
        }
      }
      if (values.length > 10) {
        for (final (h, entry) in values[10].childElements.indexed) {
          final entryParts = entry.childElements.toList();
          if (entryParts.length > 1) {
            yield LvsField(
              '$where history[$h] child [1]',
              LvsFieldType.name,
              entryParts[1].innerText,
            );
          }
        }
      }
      if (values.length > 11) {
        for (final (f, field) in values[11].childElements.indexed) {
          yield* _dispatcherFieldFields(field, '$where field[$f]');
        }
      }
    }
  }
}

/// The fields of one field of a note (see [_dispatcherNoteFields]).
Iterable<LvsField> _dispatcherFieldFields(
  XmlElement field,
  String where,
) sync* {
  final parts = field.childElements.toList();
  if (parts.length < 6) return;
  yield LvsField('$where child [0]', LvsFieldType.id, parts[0].innerText);
  yield LvsField('$where child [1]', LvsFieldType.id, parts[1].innerText);
  yield LvsField('$where child [4]', LvsFieldType.text, parts[4].innerText);
  final type = int.tryParse(parts[2].innerText.trim());
  final value = parts[3].innerText;
  final option = parts[5].innerText;
  switch (type) {
    case 1 || 2:
      yield LvsField('$where child [3]', LvsFieldType.text, value);
    case 3 || 4 || 5:
      yield LvsField('$where child [3]', LvsFieldType.id, value);
      yield LvsField('$where child [5]', LvsFieldType.text, option);
    case 6:
      if (option.trim().isEmpty) return;
      final Object? files;
      try {
        files = jsonDecode(option);
      } on FormatException {
        yield LvsField('$where child [5]', LvsFieldType.text, option);
        return;
      }
      if (files is! Map) return;
      for (final MapEntry(:key, value: file) in files.entries) {
        yield LvsField('$where child [5] (key)', LvsFieldType.id, '$key');
        if (file is Map) {
          yield LvsField(
            '$where child [5].fileName',
            LvsFieldType.text,
            file['fileName'],
          );
        }
      }
    case 7 || 8:
      break;
    default:
      yield LvsField('$where child [3]', LvsFieldType.text, value);
      yield LvsField('$where child [5]', LvsFieldType.text, option);
  }
}

/// The fields of each `note` of the `example` kind's XML, known by position
/// only: its first child is the note's id, the second its author, the third
/// its text.
Iterable<LvsField> _exampleNoteFields(Object? document) sync* {
  if (document is! XmlDocument) return;
  const positions = [LvsFieldType.id, LvsFieldType.name, LvsFieldType.text];
  for (final (n, note) in document.findAllElements('note').indexed) {
    final values = note.childElements.toList();
    for (final (i, type) in positions.indexed) {
      if (i >= values.length) break;
      yield LvsField('note[$n] child [$i]', type, values[i].innerText);
    }
  }
}

/// [name] in lower case, without a `data-` prefix and without anything
/// but letters and digits: `pupil_name`, `pupilName` and `data-pupil-name`
/// are all `pupilname`.
String normalizedFieldName(String name) {
  var normalized = name.toLowerCase();
  if (normalized.startsWith('data-')) normalized = normalized.substring(5);
  return normalized.replaceAll(RegExp('[^a-z0-9]'), '');
}

/// A field name that ends in an id by its spelling: `id`, `pupil_id`,
/// `data-pupil-id`, `pupil.id`, with an optional `s`.
final _idSuffix = RegExp(r'(^|[_.\-])ids?$', caseSensitive: false);

/// A camelCase field name that ends in an id: `pupilId`, `classID`,
/// `courseIds`.
final _camelIdSuffix = RegExp(r'[a-z0-9]I[dD]s?$');

/// The fields of one fixture that hold names, ids and free text.
class _FieldTypes {
  _FieldTypes(LvsFixtureKind? kind)
    : _names = {...?kind?.nameFields.map(normalizedFieldName)},
      _ids = {...?kind?.idFields.map(normalizedFieldName)},
      _texts = {...?kind?.textFields.map(normalizedFieldName)};

  final Set<String> _names;
  final Set<String> _ids;
  final Set<String> _texts;

  /// What the field [name] holds, or `null` for a field not checked.
  LvsFieldType? of(String name) {
    final normalized = normalizedFieldName(name);
    if (_names.contains(normalized)) return LvsFieldType.name;
    if (_ids.contains(normalized)) return LvsFieldType.id;
    if (_texts.contains(normalized)) return LvsFieldType.text;
    if (commonIdFields.contains(normalized) ||
        _idSuffix.hasMatch(name) ||
        _camelIdSuffix.hasMatch(name)) {
      return LvsFieldType.id;
    }
    if (commonNameFields.contains(normalized)) return LvsFieldType.name;
    if (commonTextFields.contains(normalized)) return LvsFieldType.text;
    return null;
  }
}

/// The fakes of FAKES.md.
class LvsFakes {
  LvsFakes._(this.entries, this.problems);

  /// The headings of FAKES.md whose entries are fakes.
  static const headings = {'People', 'Schools', 'Classes', 'Labels'};

  /// Reads the entries of [markdown]: per heading of [headings], the lines
  /// `` - `<entry>` ``.
  factory LvsFakes.parse(String markdown) {
    final entries = {for (final heading in headings) heading: <String>[]};
    final problems = <String>[];
    String? heading;
    for (final (i, line) in const LineSplitter().convert(markdown).indexed) {
      final title = RegExp(r'^##\s+(.+?)\s*$').firstMatch(line);
      if (title != null) {
        heading = title.group(1);
        continue;
      }
      final entry = RegExp(r'^\s*-\s+`([^`]+)`').firstMatch(line);
      if (entry == null) continue;
      final value = entry.group(1)!.trim();
      final list = entries[heading];
      if (list == null) {
        problems.add(
          'line ${i + 1}: an entry under a heading that is not '
          'one of ${headings.join(', ')}',
        );
      } else if (entries.values.any((other) => other.contains(value))) {
        problems.add('line ${i + 1}: an entry that is listed already');
      } else if (heading == 'People' &&
          value.split(RegExp(r'\s+')).length < 2) {
        problems.add('line ${i + 1}: a person without a first and last name');
      } else {
        list.add(value);
      }
    }
    return LvsFakes._(entries, problems);
  }

  /// The entries per heading.
  final Map<String, List<String>> entries;

  /// What is wrong in the file, by line, without the entry.
  final List<String> problems;

  List<String> get people => entries['People']!;

  /// Every form of every entry that a name-like field may hold, in lower
  /// case.
  late final Set<String> _names = {
    for (final person in people) ..._formsOf(person),
    for (final heading in headings.difference({'People'}))
      for (final entry in entries[heading]!) _collapsed(entry).toLowerCase(),
  };

  /// Every word of every entry, in lower case.
  late final Set<String> words = {
    for (final list in entries.values)
      for (final entry in list)
        for (final word in entry.toLowerCase().split(RegExp(r'[\s,]+')))
          if (word.isNotEmpty) word,
  };

  static Iterable<String> _formsOf(String person) {
    final words = _collapsed(person).toLowerCase().split(' ');
    final first = words.first;
    final last = words.skip(1).join(' ');
    final initial = '${first.substring(0, 1)}.';
    return {
      '$first $last',
      '$last $first',
      '$last, $first',
      first,
      last,
      '$initial $last',
      '$last $initial',
    };
  }

  /// Whether [value], the value of a name-like field, is a fake: empty, one
  /// of the entries (a person in one of its forms), or a list of them.
  bool isFake(String value) {
    for (final text in _plainTexts(value)) {
      final name = _collapsed(text).toLowerCase();
      if (name.isEmpty || _names.contains(name)) return true;
      final parts = name
          .split(RegExp(r'[,;/|()\[\]]|\s[-–&]\s|\sen\s'))
          .map((part) => part.trim().replaceFirst(RegExp(r'^\d+\.\s*'), ''))
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.isNotEmpty && parts.every(_names.contains)) return true;
    }
    return false;
  }
}

/// [value] with its whitespace collapsed to single spaces, trimmed.
String _collapsed(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The text of [value] without HTML: once with the tags left out
/// (`<b>Jans</b>sens` is `Janssens`), once with a space for each.
List<String> _plainTexts(String value) {
  if (!value.contains('<') && !value.contains('&')) return [value];
  return [
    html_parser.parseFragment(value).text ?? '',
    html_parser.parseFragment(value.replaceAll(RegExp('<[^>]*>'), ' ')).text ??
        '',
  ];
}

/// Why [value], in a name-like field, is not a fake; `null` when it is.
String? nameProblem(Object? value, LvsFakes fakes) {
  if (value is! String || fakes.isFake(value)) return null;
  return 'a name that is not on the fake list (FAKES.md)';
}

/// A run of 8 or more hex digits with both a digit and a letter in it: a
/// hash, or a part of a real UUID.
final _hashLike = RegExp(
  r'(?<![0-9A-Fa-f])(?=[0-9A-Fa-f]*[A-Fa-f])(?=[0-9A-Fa-f]*[0-9])'
  r'[0-9A-Fa-f]{8,}(?![0-9A-Fa-f])',
);

/// Why [value], in an id-like field, is not a fake id; `null` when it is.
String? idProblem(Object? value) {
  final outOfRange =
      'a number outside the reserved range $lvsIdMin-$lvsIdMax (FAKES.md)';
  if (value is num) {
    if (value != value.truncate()) return outOfRange;
    return _isFakeIdNumber(value.toInt().abs()) ? null : outOfRange;
  }
  if (value is! String) return null;
  if (_hashLike.hasMatch(value)) {
    return 'a hash or UUID that is not a fake one (FAKES.md)';
  }
  for (final digits in RegExp(r'\d+').allMatches(value)) {
    final number = int.tryParse(digits.group(0)!);
    if (number == null || !_isFakeIdNumber(number)) return outOfRange;
  }
  return null;
}

bool _isFakeIdNumber(int number) =>
    number < lvsSmallNumberLimit || (number >= lvsIdMin && number <= lvsIdMax);

/// Why [value], in a text-like field, is not an obvious fake; `null` when
/// it is.
String? textProblem(Object? value) {
  if (value is! String) return null;
  final text = value.trim().toLowerCase();
  if (text.isEmpty || text.contains('test')) return null;
  return 'a text that is not an obvious fake (it does not say "test")';
}

/// Why the LVS fixture at [path] of [bytes] bytes is too big; `null` when
/// it is not.
String? oversizedProblem(String path, int bytes) {
  if (bytes <= lvsFixtureMaxBytes) return null;
  return '$path: larger than ${lvsFixtureMaxBytes ~/ 1024} KB: a pasted '
      'answer? Write fixtures by hand (not checked further)';
}

/// The kind of the fixture at [relative], its path under
/// [lvsFixturesFolder] with `/` separators, or `null` when it is not in the
/// folder of one.
LvsFixtureKind? lvsFixtureKindOf(
  String relative, {
  List<LvsFixtureKind> kinds = lvsFixtureKinds,
}) {
  final parts = relative.split('/');
  if (parts.length < 2) return null;
  for (final kind in kinds) {
    if (kind.folder == parts.first) return kind;
  }
  return null;
}

/// The problems of the LVS fixture at [path] with [content], each as
/// `<path>: <where>: <what>`, never with the value.
List<String> lvsFixtureProblems(
  String path,
  String content,
  LvsFakes fakes, {
  LvsFixtureKind? kind,
}) {
  final types = _FieldTypes(kind);
  final fields = <LvsField>[];
  final extension = p.extension(path).toLowerCase();
  Object? document;
  try {
    switch (extension) {
      case '.json':
        document = jsonDecode(content);
        _readJson(document, r'$', types, fields);
      case '.xml':
        final xml = XmlDocument.parse(content);
        document = xml;
        final root = xml.rootElement;
        _readXml(root, '/${root.name.local}', types, fields);
      case '.html' || '.htm':
        final page = html_parser.parse(content);
        document = page;
        _readHtml(page.documentElement!, '/html', types, fields);
      default:
        return ['$path: not a JSON, XML or HTML fixture (.json, .xml, .html)'];
    }
  } on FormatException catch (error) {
    final where = error is XmlFormatException
        ? ' (line ${error.line})'
        : error.offset == null
        ? ''
        : ' (offset ${error.offset})';
    return ['$path: does not parse as ${extension.substring(1)}$where'];
  } on XmlException {
    return ['$path: does not parse as ${extension.substring(1)}'];
  }
  if (kind?.extraFields case final extra?) fields.addAll(extra(document));

  final problems = <String>[];
  for (final field in fields) {
    final problem = switch (field.type) {
      LvsFieldType.name => nameProblem(field.value, fakes),
      LvsFieldType.id => idProblem(field.value),
      LvsFieldType.text => textProblem(field.value),
    };
    if (problem != null) problems.add('$path: ${field.path}: $problem');
  }
  return problems;
}

/// A JSON key, or a key in a path, that holds an id: digits, after letters
/// or `_` (`900201`, `n_900301`, `_900101`).
final _idKey = RegExp(r'^[A-Za-z_]*\d+$');

/// [key] as a path shows it: its digits as `<n>`, and as `<key>` when it
/// does not look like a field name (it may be a value: a name, a label).
String _pathKey(String key) {
  final shape = key.replaceAll(RegExp(r'\d'), '_');
  if (!RegExp(r'^[a-z_][A-Za-z_\-]*$').hasMatch(shape)) return '<key>';
  return key.replaceAll(RegExp(r'\d+'), '<n>');
}

/// The JSON that [value] holds as text, or `null`.
Object? _embeddedJson(String value) {
  final text = value.trim();
  final looksLikeJson =
      text.length >= 2 &&
      ((text.startsWith('{') && text.endsWith('}')) ||
          (text.startsWith('[') && text.endsWith(']')));
  if (!looksLikeJson) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// Adds the checked fields of [node], a decoded JSON value at [path], to
/// [out]. A key that is an id is checked as one; JSON inside a string is
/// read too.
void _readJson(
  Object? node,
  String path,
  _FieldTypes types,
  List<LvsField> out,
) {
  if (node is Map) {
    node.forEach((key, value) {
      final name = key.toString();
      final keyPath = '$path.${_pathKey(name)}';
      if (_idKey.hasMatch(name)) {
        out.add(LvsField('$keyPath (key)', LvsFieldType.id, name));
      }
      _readValue(value, keyPath, types.of(name), types, out);
    });
  } else if (node is List) {
    for (final (i, item) in node.indexed) {
      _readJson(item, '$path[$i]', types, out);
    }
  } else if (node is String) {
    final embedded = _embeddedJson(node);
    if (embedded != null) _readJson(embedded, '$path(json)', types, out);
  }
}

/// Adds [value], the value of a field of [type] at [path], to [out]: a
/// scalar as it is, each item of a list, and the values of a map (a map
/// from ids to names, say) by their own keys, or as [type] for a key that
/// is an id.
void _readValue(
  Object? value,
  String path,
  LvsFieldType? type,
  _FieldTypes types,
  List<LvsField> out,
) {
  if (type == null) return _readJson(value, path, types, out);
  if (value is String) {
    final embedded = _embeddedJson(value);
    if (embedded != null) {
      return _readValue(embedded, '$path(json)', type, types, out);
    }
    out.add(LvsField(path, type, value));
  } else if (value is List) {
    for (final (i, item) in value.indexed) {
      _readValue(item, '$path[$i]', type, types, out);
    }
  } else if (value is Map) {
    value.forEach((key, inner) {
      final name = key.toString();
      final keyPath = '$path.${_pathKey(name)}';
      if (_idKey.hasMatch(name)) {
        out.add(LvsField('$keyPath (key)', LvsFieldType.id, name));
        _readValue(inner, keyPath, type, types, out);
      } else {
        _readValue(inner, keyPath, types.of(name), types, out);
      }
    });
  } else {
    out.add(LvsField(path, type, value));
  }
}

/// Adds the checked fields of [element], at [path], to [out]: its
/// attributes by their names, and its text by its name when it has no
/// child elements. `<x name="key">value</x>` (or `value="..."`) is the
/// field `key`.
void _readXml(
  XmlElement element,
  String path,
  _FieldTypes types,
  List<LvsField> out,
) {
  final children = element.childElements.toList();
  final text = children.isEmpty ? element.innerText : '';
  final key = element.getAttribute('name');
  final keyValue = element.getAttribute('value');
  final nameIsKey = key != null && (text.trim().isNotEmpty || keyValue != null);
  for (final attribute in element.attributes) {
    final name = attribute.name.local;
    if (attribute.name.prefix == 'xmlns' || name == 'xmlns') continue;
    if (nameIsKey && (name == 'name' || name == 'value')) continue;
    _readValue(attribute.value, '$path/@$name', types.of(name), types, out);
  }
  if (nameIsKey) {
    final keyPath = '$path(name=${_pathKey(key)})';
    _readValue(keyValue ?? text, keyPath, types.of(key), types, out);
  } else if (children.isEmpty) {
    _readValue(text, path, types.of(element.name.local), types, out);
  }
  for (final (i, child) in children.indexed) {
    final index = children.length > 1 ? '[$i]' : '';
    _readXml(child, '$path/${child.name.local}$index', types, out);
  }
}

/// Adds the checked fields of [element], at [path], to [out]: its
/// attributes by their names (`data-pupil-id`; not `class`, whose tokens
/// name the field), and its text, when it has no child elements, by its tag
/// and its classes. `<input name="key" value="...">` is the field `key`.
void _readHtml(
  html.Element element,
  String path,
  _FieldTypes types,
  List<LvsField> out,
) {
  final key = element.attributes['name'];
  element.attributes.forEach((attribute, value) {
    final name = attribute.toString();
    if (name == 'class' || name == 'name') return;
    if (name == 'value' && key != null) return;
    _readValue(value, '$path/@$name', types.of(name), types, out);
  });
  if (key != null) {
    final value = element.attributes['value'] ?? element.text;
    _readValue(
      value,
      '$path(name=${_pathKey(key)})',
      types.of(key),
      types,
      out,
    );
  }
  final children = element.children;
  if (children.isEmpty) {
    for (final name in {element.localName ?? '', ...element.classes}) {
      final type = types.of(name);
      if (type == null) continue;
      _readValue(element.text, '$path(.${_pathKey(name)})', type, types, out);
    }
  }
  for (final (i, child) in children.indexed) {
    final index = children.length > 1 ? '[$i]' : '';
    _readHtml(child, '$path/${child.localName}$index', types, out);
  }
}

/// A run that may be base64: 8 or more characters of its standard or
/// URL-safe alphabet, with its padding.
final _base64Token = RegExp(r'[A-Za-z0-9+/_\-]{8,}={0,2}');

/// A word of a name: letters, with `'` and inner `-`.
final _word = RegExp(r"[\p{L}'’]+(?:-[\p{L}'’]+)*", unicode: true);

/// What may stand between two words of one name: spaces, or a comma.
final _nameGap = RegExp(r'^(?:[ \t]+|[ \t]*,[ \t]*)$');

/// Lower-case words inside names: "Noor van den Broeck".
const _particles = {
  'van',
  'de',
  'der',
  'den',
  'het',
  'te',
  'ten',
  'ter',
  'vanden',
  'vander',
  'von',
  'le',
  'la',
  'du',
  'da',
  'di',
  'des',
  "d'",
  "'t",
};

bool _isCapitalised(String word) =>
    word.length >= 2 && RegExp(r'^\p{Lu}', unicode: true).hasMatch(word);

/// The names in [text]: runs of two or more capitalised words (with the
/// lower-case particles of names between them), as "Jan Janssens",
/// "Janssens, Jan" and "JANSSENS Jan" are written; each as its capitalised
/// words. HTML tags end a run.
List<List<String>> namesInText(String text) {
  final plain = text.replaceAll(RegExp('<[^>]*>'), '\n');
  final names = <List<String>>[];
  var run = <String>[];
  var lastEnd = -1;
  void close() {
    final capitals = run.where(_isCapitalised).toList();
    if (capitals.length >= 2) names.add(capitals);
    run = [];
  }

  for (final match in _word.allMatches(plain)) {
    final word = match.group(0)!;
    if (lastEnd < 0 ||
        !_nameGap.hasMatch(plain.substring(lastEnd, match.start))) {
      close();
    }
    if (_isCapitalised(word)) {
      run.add(word);
    } else if (run.isNotEmpty && _particles.contains(word.toLowerCase())) {
      run.add(word);
    } else {
      close();
    }
    lastEnd = match.end;
  }
  close();
  return names;
}

/// The text [token] decodes to as base64, or `null` when it is not base64
/// of printable UTF-8 text.
String? _decodedBase64Text(String token) {
  if (token.replaceAll('=', '').length % 4 == 1) return null;
  try {
    final text = utf8.decode(base64.decode(base64.normalize(token)));
    final printable = text.runes.every(
      (rune) =>
          rune == 0x09 ||
          rune == 0x0a ||
          rune == 0x0d ||
          (rune >= 0x20 && rune != 0x7f && (rune < 0x80 || rune >= 0xa0)),
    );
    return printable ? text : null;
  } on FormatException {
    return null;
  }
}

/// The names in the base64 strings of [content], each with its line.
List<({int line, List<String> words})> base64Names(String content) {
  final found = <({int line, List<String> words})>[];
  for (final match in _base64Token.allMatches(content)) {
    final decoded = _decodedBase64Text(match.group(0)!);
    if (decoded == null) continue;
    for (final words in namesInText(decoded)) {
      final line = '\n'.allMatches(content.substring(0, match.start)).length;
      found.add((line: line + 1, words: words));
    }
  }
  return found;
}

/// The base64 strings in [content], the file at [path], that decode to a
/// name with a word that is not one of [fakes], by line.
List<String> base64NameProblems(
  String path,
  String content,
  LvsFakes fakes,
) => [
  for (final name in base64Names(content))
    if (!name.words.every((word) => fakes.words.contains(word.toLowerCase())))
      '$path: line ${name.line}: a base64 string that decodes to a name that '
          'is not on the fake list (FAKES.md)',
];

/// [path] relative to the package root, with `/` separators on every
/// platform.
String _packagePath(String path) => p.split(p.relative(path)).join('/');

/// The files under [folder], as package paths, sorted.
List<String> _filesUnder(String folder) =>
    Directory(folder)
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => _packagePath(file.path))
        .toList()
      ..sort();

void main() {
  forbidRealNetwork();

  final fakes = LvsFakes.parse(File(lvsFakesFile).readAsStringSync());

  test('FAKES.md lists the fakes', () {
    expect(fakes.problems, isEmpty, reason: 'in $lvsFakesFile');
    expect(fakes.people, isNotEmpty);
    for (final heading in LvsFakes.headings) {
      expect(fakes.entries[heading], isNotEmpty, reason: '## $heading');
    }
    // The fakes doc/lvs-privacy.md and the issue name.
    expect(fakes.isFake('Jan Janssens'), isTrue);
    expect(fakes.isFake('Marie Peeters'), isTrue);
    expect(fakes.isFake('Springfield Academy'), isTrue);
  });

  test('every fixture kind has a folder with fixtures in it', () {
    final folders = <String>{};
    for (final kind in lvsFixtureKinds) {
      expect(folders.add(kind.folder), isTrue, reason: 'twice: ${kind.folder}');
      expect(kind.folder, isNot(contains('/')), reason: 'one level only');
      final folder = Directory('$lvsFixturesFolder/${kind.folder}');
      expect(folder.existsSync(), isTrue, reason: '${folder.path} is missing');
      expect(
        folder.listSync(recursive: true).whereType<File>(),
        isNotEmpty,
        reason: '${folder.path} holds no fixture',
      );
    }
  });

  test('every LVS fixture is written by hand, with fakes only', () {
    final files = _filesUnder(lvsFixturesFolder)..remove(lvsFakesFile);
    // Finding nothing would make this test pass for nothing.
    expect(files, isNotEmpty, reason: 'no fixtures under $lvsFixturesFolder');

    final problems = <String>[];
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      final tooBig = oversizedProblem(path, bytes.length);
      if (tooBig != null) {
        problems.add(tooBig);
        continue;
      }
      final relative = path.substring(lvsFixturesFolder.length + 1);
      final kind = lvsFixtureKindOf(relative);
      if (kind == null) {
        problems.add(
          '$path: not in the folder of a fixture kind: add one to '
          'lvsFixtureKinds (test/lvs_fixtures_guard_test.dart)',
        );
        continue;
      }
      final String content;
      try {
        content = utf8.decode(bytes);
      } on FormatException {
        problems.add('$path: not UTF-8 text');
        continue;
      }
      problems.addAll(lvsFixtureProblems(path, content, fakes, kind: kind));
    }
    expect(
      problems,
      isEmpty,
      reason:
          'LVS fixtures are written by hand with the fakes of $lvsFakesFile; '
          'the rules are in doc/lvs-privacy.md',
    );
  });

  test('no file under test/ holds base64 of a name not on the fake list', () {
    var names = 0;
    final problems = <String>[];
    for (final path in _filesUnder('test')) {
      final content = utf8.decode(
        File(path).readAsBytesSync(),
        allowMalformed: true,
      );
      names += base64Names(content).length;
      problems.addAll(base64NameProblems(path, content, fakes));
    }
    // The Skore gradebook tests hold fake names in base64, as Skore sends
    // them: finding none would mean that the scan does not work.
    expect(names, greaterThan(0), reason: 'no base64 name found at all');
    expect(
      problems,
      isEmpty,
      reason:
          'every name in test/ is one of $lvsFakesFile (doc/lvs-privacy.md)',
    );
  });

  group('the guard', () {
    // A fake list of its own, so that these tests do not change with
    // FAKES.md; and a name that is on no list.
    final testFakes = LvsFakes.parse('''
## People
- `Jan Janssens` — pupil
- `Noor Van den Broeck` — pupil
## Schools
- `Springfield Academy`
## Classes
- `1A`
## Labels
- `Testcategorie`
''');
    const unknown = 'Onbekende Persoon';

    /// The problems of a JSON fixture with [json].
    List<String> jsonProblems(Object json, {LvsFixtureKind? kind}) =>
        lvsFixtureProblems(
          'test/fixtures/lvs/k/a.json',
          jsonEncode(json),
          testFakes,
          kind: kind,
        );

    test('reads the fake list', () {
      expect(testFakes.problems, isEmpty);
      expect(testFakes.people, ['Jan Janssens', 'Noor Van den Broeck']);
      expect(
        LvsFakes.parse('## Pets\n- `Rex`\n## People\n- `Jan`\n').problems,
        hasLength(2),
      );
    });

    test('takes a fake person in each of its forms', () {
      for (final form in [
        'Jan Janssens',
        'Janssens Jan',
        'Janssens, Jan',
        'JANSSENS Jan',
        'jan janssens',
        'Jan',
        'Janssens',
        'J. Janssens',
        'Janssens J.',
        '  Jan   Janssens ',
        '<b>Jans</b>sens Jan',
        '<span>Jan</span> <span>Janssens</span>',
        'Van den Broeck Noor',
        'Jan Janssens, Noor Van den Broeck',
        'Springfield Academy',
        '1A',
        'testcategorie',
        '',
      ]) {
        expect(testFakes.isFake(form), isTrue, reason: form);
      }
    });

    test('refuses a name that is not on the fake list', () {
      for (final form in [
        unknown,
        'Jan Onbekend',
        'Janssens, Onbekend',
        'Jan Janssens, $unknown',
        '<b>$unknown</b>',
        '6XYZ',
        'Testcategorie Gedrag',
      ]) {
        expect(testFakes.isFake(form), isFalse, reason: form);
      }
    });

    test('takes a fixture with fakes only', () {
      expect(
        jsonProblems({
          'pupil': {
            'pupilID': 900001,
            'classID': '900101',
            'name': 'Jan Janssens',
            'class': '1A',
            'teachers': {'900201': 'Jan Janssens'},
            'picUrl': '/smsc/img/fake/initials_JJ.png',
            'state': 'unknown text in a field not checked',
          },
          'node': {'id': 'tree_group_900101_pupil_900001', 'gid': 0},
          'uuid_id': '00000000-0000-0000-0000-000000900001',
          'items': [
            {'itemID': 900301, 'text': 'Testnotitie over de leerling.'},
          ],
          'n_900301': {'type': 2},
          'flags': {'deleted': -1, 'rights': 1},
        }),
        isEmpty,
      );
    });

    test('names the file and field of an unknown name, not the name', () {
      final problems = jsonProblems({
        'pupils': [
          {'pupilID': 900001, 'name': 'Jan Janssens'},
          {'pupilID': 900002, 'name': unknown},
        ],
      });
      expect(problems, [
        r'test/fixtures/lvs/k/a.json: $.pupils[1].name: a name that is not on '
            'the fake list (FAKES.md)',
      ]);
    });

    test('finds names in every kind of name-like field', () {
      final problems = jsonProblems({
        'author': unknown,
        'foundName': '<b>Onb</b>ekende Persoon',
        'teachers': {'900201': unknown},
        'owner': {
          'id': 900202,
          'name': {'startingWithFirstName': unknown},
        },
        'firstName': 'Onbekende',
        'class': '6XYZ',
        'list': ['[{"lastName": "Persoon"}]'],
      });
      expect(problems, hasLength(7));
      expect(problems.join('\n'), isNot(contains('Onbekend')));
      expect(problems.join('\n'), isNot(contains('Persoon')));
      expect(problems.join('\n'), isNot(contains('6XYZ')));
      expect(problems.join('\n'), contains(r'$.teachers.<n>'));
    });

    test('refuses an id outside the reserved range, without its value', () {
      for (final (field, value) in [
        ('pupilID', 12345),
        ('pupilId', '12345'),
        ('pupil_id', 899999),
        ('classid', 1000000),
        ('id', 'tree_group_900101_pupil_12345'),
        ('id', 900001.5),
        ('identifier', '49_12345_0_normal_900001'),
        ('picUrl', '/smsc/svg/3f2a9c1e/foto.png'),
        ('itemID', '3f2a9c1e-5b7d-4e2a-9c1e-5b7d4e2a9c1e'),
        ('courseIds', [900001, 12345]),
      ]) {
        final problems = jsonProblems({field: value});
        expect(problems, hasLength(1), reason: '$field: $value');
        expect(problems.single, contains(field), reason: '$field: $value');
        expect(problems.single, isNot(contains('12345')));
        expect(problems.single, isNot(contains('3f2a9c1e')));
      }
    });

    test('refuses a JSON key that is an id outside the range', () {
      final problems = jsonProblems({
        'teachers': {'12345': 'Jan Janssens'},
        'dates': {'n_12345': 1},
      });
      expect(problems, hasLength(2));
      expect(problems.join('\n'), isNot(contains('12345')));
    });

    test('takes ids in the range, and small numbers', () {
      for (final value in [900000, 999999, '900123', 0, 2, -1, '0', null]) {
        expect(idProblem(value), isNull, reason: '$value');
      }
    });

    test('refuses free text that is not an obvious fake', () {
      expect(jsonProblems({'text': 'Gesprek over de leerling.'}), hasLength(1));
      expect(jsonProblems({'text': '<p>Testverslag.</p>'}), isEmpty);
      expect(jsonProblems({'motivation': ''}), isEmpty);
    });

    test('checks the fields a kind adds, and those known by position', () {
      final kind = LvsFixtureKind(
        folder: 'k',
        about: 'test',
        nameFields: {'tutor'},
        idFields: {'ref'},
        textFields: {'summary'},
        extraFields: (document) => [
          LvsField(
            r'$.values[0]',
            LvsFieldType.name,
            (document as Map)['values'][0],
          ),
        ],
      );
      final json = {
        'tutor': unknown,
        'ref': 12345,
        'summary': 'Gesprek over de leerling.',
        'values': [unknown],
      };
      expect(jsonProblems(json), isEmpty, reason: 'without the kind');
      expect(jsonProblems(json, kind: kind), hasLength(4));
    });

    test('checks the labels of the periods and of the codes of the absences '
        '(#164), and their motivation, without the values', () {
      final kind = lvsFixtureKinds.singleWhere((k) => k.folder == 'absences');
      Map<String, Object?> answer(String period, String code, String text) => {
        'presences': {
          period: {
            '2030-09-16': {
              'full': {'code': 'TA', 'codeDescr': code, 'motivation': text},
            },
          },
        },
        'year_label': '2030 - 2031',
      };

      expect(
        jsonProblems(
          answer('Testcategorie', 'Testcategorie', 'Testmotivatie.'),
          kind: kind,
        ),
        isEmpty,
      );
      final problems = jsonProblems(
        answer('Onbekende periode', 'Onbekende code', 'Ziek thuis.'),
        kind: kind,
      );
      expect(problems, hasLength(3));
      expect(problems.join('\n'), contains('presences key [0]'));
      expect(problems.join('\n'), contains('codeDescr'));
      expect(problems.join('\n'), contains('motivation'));
      expect(problems.join('\n'), isNot(contains('Onbekende')));
      expect(problems.join('\n'), isNot(contains('Ziek')));
    });

    test('takes a school year as a key of the absences for no label, and '
        'checks their code key as an id (#176), without the values', () {
      final kind = lvsFixtureKinds.singleWhere((k) => k.folder == 'absences');
      Map<String, Object?> answer(String period, String codeKey) => {
        'presences': {
          period: [
            {
              'am': {
                'codeKey': codeKey,
                'code': 'TA',
                'codeDescr': 'Testcategorie',
                'formattedDate': 'ma 16 september 2030',
              },
            },
          ],
        },
        'year_label': '2030-2031',
      };

      expect(jsonProblems(answer('2030-2031', '900501'), kind: kind), isEmpty);
      expect(
        jsonProblems(answer('2030-2031', '900502-900503'), kind: kind),
        isEmpty,
      );
      final problems = [
        ...jsonProblems(answer('2030-2031', '12345-900503'), kind: kind),
        ...jsonProblems(answer('2030-2031 Onbekend', '900501'), kind: kind),
      ];
      expect(problems, hasLength(2));
      expect(problems.join('\n'), contains('codeKey'));
      expect(problems.join('\n'), contains('presences key [0]'));
      expect(problems.join('\n'), isNot(contains('12345')));
      expect(problems.join('\n'), isNot(contains('Onbekend')));
    });

    test('reads XML: elements, attributes, name="key", embedded JSON', () {
      final problems = lvsFixtureProblems('test/fixtures/lvs/k/a.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<server>
  <pupil pupilID="900001" name="Jan Janssens"/>
  <pupil pupilID="12345" name="$unknown"/>
  <author>$unknown</author>
  <param name="userID"><![CDATA[12345]]></param>
  <param name="catID" value="900401"/>
  <data><![CDATA[{"name": "$unknown", "noteID": 900301}]]></data>
</server>
''', testFakes);
      expect(problems, hasLength(5));
      expect(problems.join('\n'), isNot(contains('Onbekend')));
      expect(problems.join('\n'), isNot(contains('12345')));
      expect(problems.join('\n'), contains('/server/param[3](name=userID)'));
    });

    test('reads HTML: attributes, classes, name="key"', () {
      final problems = lvsFixtureProblems('test/fixtures/lvs/k/a.html', '''
<div class="pupil" data-pupil-id="12345">
  <span class="name">$unknown</span>
  <span class="name">Jan Janssens</span>
  <input name="classID" value="12345">
  <a href="/x/12345" title="Bewerken">x</a>
</div>
''', testFakes);
      expect(problems, hasLength(3));
      expect(problems.join('\n'), isNot(contains('Onbekend')));
      expect(problems.join('\n'), isNot(contains('12345')));
    });

    test('refuses a file that does not parse, or of another type', () {
      String one(String path, String content) =>
          lvsFixtureProblems(path, content, testFakes).single;
      expect(one('k/a.json', '{"name": '), contains('does not parse as json'));
      expect(one('k/a.xml', '<a><b></a>'), contains('does not parse as xml'));
      expect(one('k/a.txt', 'Testtekst'), contains('not a JSON, XML or HTML'));
    });

    test('refuses a file larger than a hand-written fixture', () {
      expect(oversizedProblem('k/a.json', lvsFixtureMaxBytes), isNull);
      expect(oversizedProblem('k/a.json', lvsFixtureMaxBytes + 1), isNotNull);
    });

    test('knows a fixture by the folder of its kind', () {
      const kind = LvsFixtureKind(folder: 'k', about: 'test');
      expect(lvsFixtureKindOf('k/a.json', kinds: [kind]), same(kind));
      expect(lvsFixtureKindOf('k/sub/a.json', kinds: [kind]), same(kind));
      expect(lvsFixtureKindOf('a.json', kinds: [kind]), isNull);
      expect(lvsFixtureKindOf('other/a.json', kinds: [kind]), isNull);
    });

    test('finds names in base64, and those not on the fake list', () {
      String encoded(String text) => base64.encode(utf8.encode(text));
      final content = [
        "alternate: '${encoded('Janssens Jan')}'",
        "tooltip: '${encoded('<div><img src="/x.png" /><div>Jan Janssens</div></div>')}'",
        "list: '${encoded('<li>Eerste opmerking.</li><li>Goed gewerkt</li>')}'",
        "unknown: '${encoded(unknown)}'",
        "comma: '${encoded('Persoon, Onbekende')}'",
        "particles: '${encoded('Noor van den Broeck')}'",
        "url-safe: '${encoded(unknown).replaceAll('=', '')}'",
      ].join('\n');
      expect(base64Names(content), hasLength(6));
      final problems = base64NameProblems('test/a.dart', content, testFakes);
      expect(problems, [
        for (final line in [4, 5, 7])
          'test/a.dart: line $line: a base64 string that decodes to a name '
              'that is not on the fake list (FAKES.md)',
      ]);
    });
  });
}
