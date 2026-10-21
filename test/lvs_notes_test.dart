// Tests for issue #161: the notes of a pupil's file in the LVS, read as the
// logged-in teacher through LvsService: the note categories of a pupil's file
// (LvsPupilFile.noteCategories), the notes of one category with those of its
// sub-categories (getNotes), all notes of the file (getAllNotes), the school
// year sent (LvsSchoolYear), the allowlist of the XML dispatcher's commands,
// and errors that carry no name.
//
// The answers are the hand-written fixtures of test/fixtures/lvs/notes/
// (doc/lvs-privacy.md: never trimmed from a live answer), in the shapes read
// from the LVS's own JavaScript and seen live for a made-up pupil and a
// made-up category (2026-10-21): the dispatcher's envelope, the parts of
// renderPupilNotes and renderPupilAllNotes up to the notes, the placeholder
// pupil and the category without its ID. Smaller variants (an unknown shape,
// a refusal) are made from them below.
//
// The fake Smartschool fails the test on any request that is not one of the
// service's reads.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/services/lvs_wire.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

String _fixture(String name) =>
    File('test/fixtures/lvs/$name').readAsStringSync();

ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'application/xml; charset=UTF-8',
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
    ...headers,
  },
);

ResponseBody Function() _xml(String fixture) =>
    () => _answer(_fixture('notes/$fixture'));

ResponseBody Function() _text(String body) =>
    () => _answer(body);

/// A POST that the LVS sent on to Smartschool's start page: the redirect
/// itself (the client does not follow one after a POST).
ResponseBody _redirectToStartPage() => _answer(
  '',
  status: 302,
  contentType: 'text/html',
  headers: {
    'location': ['/?module=Homepage'],
  },
);

/// A command the fake Smartschool received from the XML dispatcher.
typedef _Command = ({
  String subsystem,
  String action,
  Map<String, String> params,
  String? requestedWith,
});

/// A Smartschool whose LVS answers the reads of the service with [answers],
/// by read: `notes` (getUserCatItems), `allNotes` (getUserData), `file` and
/// `status` (getPupilFile). Any other request fails the test.
class _Lvs implements HttpClientAdapter {
  _Lvs(this.answers);

  final Map<String, ResponseBody Function()> answers;

  /// Every request that reached it, as `METHOD path?query`.
  final requests = <String>[];

  /// The dispatcher commands among them.
  final commands = <_Command>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(
      '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    );
    final query = uri.queryParameters;
    final String? read;
    if (options.method == 'POST' &&
        uri.path == '/' &&
        query.length == 2 &&
        query['module'] == 'LVS' &&
        query['file'] == 'dispatcher') {
      final data = options.data;
      final command = _parse((data is Map ? data['command'] : null) as String);
      commands.add((
        subsystem: command.subsystem,
        action: command.action,
        params: command.params,
        requestedWith: options.headers['X-Requested-With'] as String?,
      ));
      read = switch ((command.subsystem, command.action)) {
        ('lvs_cats', 'getUserCatItems') => 'notes',
        ('lvs_pupils', 'getUserData') => 'allNotes',
        _ => null,
      };
    } else {
      read = switch ((options.method, uri.path)) {
        ('GET', final path) when path.startsWith('/LVS/Spotlight/') => 'file',
        ('POST', '/LVS/Pupilxhr/getStatusInfo') => 'status',
        _ => null,
      };
    }
    if (read == null) {
      fail('Not a read of LvsService: ${options.method} ${uri.path}');
    }
    final answer = answers[read];
    if (answer == null) fail('The test gave no answer to the $read read');
    return answer();
  }

  static ({String subsystem, String action, Map<String, String> params}) _parse(
    String xml,
  ) {
    final command = XmlDocument.parse(xml).rootElement.getElement('command')!;
    return (
      subsystem: command.getElement('subsystem')!.innerText,
      action: command.getElement('action')!.innerText,
      params: {
        for (final param in command.getElement('params')!.childElements)
          param.getAttribute('name')!: param.innerText,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<(_Lvs, LvsService)> _serve(
  Map<String, ResponseBody Function()> answers,
) async {
  final server = _Lvs(answers);
  final client = await SmartschoolClient.create(
    _Credentials(),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  return (server, LvsService(client));
}

/// The fake people, labels, texts and IDs of the fixtures: an error message
/// holds none of them.
const _answerValues = [
  'Janssens',
  'Jan',
  'Peeters',
  'Piet',
  'Dupré',
  'Jacobs',
  'Wouters',
  'Test',
  'test',
  '1A',
  '9000',
  '9001',
  '9004',
  '9006',
  '9007',
  '9008',
  '9999',
  'Niet beschikbaar',
];

/// A message that quotes nothing of the answers.
Matcher get _quotesNothing =>
    allOf([for (final value in _answerValues) isNot(contains(value))]);

/// A plain [SmartschoolLvsError]: an answer the service cannot use, no
/// refusal, no unknown pupil or category.
Matcher _unreadable({int? statusCode}) => allOf(
  isNot(isA<SmartschoolLvsAccessDeniedError>()),
  isNot(isA<SmartschoolLvsPupilNotFoundError>()),
  isNot(isA<SmartschoolLvsCategoryNotFoundError>()),
  isNot(isA<SmartschoolLvsRequestNotAllowedError>()),
  isA<SmartschoolLvsError>()
      .having((e) => e.message, 'message', _quotesNothing)
      .having((e) => '$e', 'toString()', _quotesNothing)
      .having((e) => e.statusCode, 'statusCode', statusCode ?? anything),
);

/// [text] with its [n]th (from 1) [from] replaced by [to].
String _replaceNth(String text, String from, String to, int n) {
  var at = -1;
  for (var i = 0; i < n; i++) {
    at = text.indexOf(from, at + 1);
    if (at < 0) throw StateError('no $n occurrences in the fixture');
  }
  return text.replaceRange(at, at + from.length, to);
}

/// The notes of category 900401 of pupil 900001 in class 900101.
Future<List<LvsNote>> _notesOf(LvsService lvs, {LvsSchoolYear? schoolYear}) =>
    lvs.getNotes(
      pupilId: 900001,
      classId: 900101,
      categoryId: 900401,
      schoolYear: schoolYear,
    );

void main() {
  forbidRealNetwork();

  group('getNotes', () {
    test("one request: the dispatcher's lvs_cats/getUserCatItems with the "
        "web client's params, for the school year asked for", () async {
      final (server, lvs) = await _serve({'notes': _xml('category.xml')});

      await _notesOf(lvs, schoolYear: LvsSchoolYear.starting(2030));

      expect(server.requests, ['POST /?module=LVS&file=dispatcher']);
      final command = server.commands.single;
      expect(command.subsystem, 'lvs_cats');
      expect(command.action, 'getUserCatItems');
      expect(command.params, {
        'catID': '900401',
        'userID': '900001',
        'toolbarType': 'main',
        'syRange': '{"from":"2030-09-01","until":"2031-08-31"}',
        'groupID': '900101',
        'toolbarSide': 'left',
      });
      expect(command.params.keys, [
        'catID',
        'userID',
        'toolbarType',
        'syRange',
        'groupID',
        'toolbarSide',
      ]);
      expect(command.requestedWith, 'XMLHttpRequest');
    });

    test('without a school year: the current one, in Belgian time', () async {
      final (server, lvs) = await _serve({'notes': _xml('category.xml')});

      await _notesOf(lvs);

      final current = LvsSchoolYear.current();
      expect(jsonDecode(server.commands.single.params['syRange']!), {
        'from': current.firstDay,
        'until': current.lastDay,
      });
    });

    test("the notes of the category and its sub-categories, in the LVS's "
        'order', () async {
      final (_, lvs) = await _serve({'notes': _xml('category.xml')});

      final notes = await _notesOf(lvs);

      expect(notes.map((n) => n.id), [900301, 900302, 900303]);
      expect(notes.map((n) => n.categoryId), [900401, 900402, 900401]);
      // The third note comes without catName: the name of the category read.
      expect(notes.map((n) => n.categoryName), [
        'Testcategorie',
        'Testsubcategorie',
        'Testcategorie',
      ]);
      expect(notes.map((n) => n.title), [
        'Testnotitie over de les.',
        'Testnotitie vertrouwelijk.',
        '',
      ]);
      expect(notes.map((n) => n.date), [
        DateTime.utc(2030, 10, 1, 8, 30),
        DateTime.utc(2030, 10, 8, 14),
        DateTime.utc(2030, 11, 5, 13, 15),
      ]);
      expect(notes.every((n) => n.date.isUtc), isTrue);
      expect(notes.map((n) => n.author), [
        'Peeters Piet',
        'Dupré Céline',
        'Jacobs Els',
      ]);
      expect(notes.map((n) => n.schoolYear), ['2030', '2030', '2030']);
      expect(notes.map((n) => n.fields.length), [11, 1, 0]);
    });

    test('a confidential note is returned, marked; new and viewed', () async {
      final (_, lvs) = await _serve({'notes': _xml('category.xml')});

      final notes = await _notesOf(lvs);

      expect(notes.map((n) => n.isConfidential), [false, true, false]);
      expect(notes.map((n) => n.isNew), [true, false, false]);
      expect(notes.map((n) => n.viewed), [false, true, false]);
    });

    test('every field type: its label, the text to show, and what the type '
        'adds; an unknown type kept with its raw values', () async {
      final (_, lvs) = await _serve({'notes': _xml('category.xml')});

      final fields = (await _notesOf(lvs)).first.fields;

      expect(fields.map((f) => f.paramId), [
        for (var id = 900601; id <= 900611; id++) id,
      ]);
      expect(fields.map((f) => f.type), [
        LvsNoteFieldType.text,
        LvsNoteFieldType.richText,
        LvsNoteFieldType.radio,
        LvsNoteFieldType.checkbox,
        LvsNoteFieldType.select,
        LvsNoteFieldType.attachment,
        LvsNoteFieldType.date,
        LvsNoteFieldType.heading,
        LvsNoteFieldType.unknown,
        LvsNoteFieldType.date,
        LvsNoteFieldType.select,
      ]);
      expect(fields.map((f) => f.typeCode), [1, 2, 3, 4, 5, 6, 7, 8, 42, 7, 5]);

      final [
        text,
        rich,
        radio,
        checkbox,
        select,
        files,
        date,
        heading,
        unknown,
        today,
        empty,
      ] = fields;

      expect(text.label, 'Testveld tekst');
      expect(text.value, 'Testtekst over het gedrag.');
      expect(text.html, isNull);

      // A "]]>" in the CDATA comes back whole; the HTML as plain text.
      expect(rich.html, '<p>Testverslag met <b>nadruk</b> &amp; ]]> erin.</p>');
      expect(rich.value, 'Testverslag met nadruk & ]]> erin.');

      expect(radio.optionIds, [900701]);
      expect(radio.value, 'Testoptie goed');
      expect(checkbox.optionIds, [900702, 900703]);
      expect(checkbox.value, 'Testoptie een, Testoptie twee');
      expect(select.optionIds, [900704]);
      expect(select.value, 'Testoptie & meer');
      expect(select.rawOptionValue, 'Testoptie &amp; meer');

      expect(files.attachments.map((a) => a.id), [900801, 900802]);
      expect(files.attachments.map((a) => a.name), [
        'testverslag.pdf',
        'testfoto.jpg',
      ]);
      expect(files.attachments.map((a) => a.mimeType), [
        'application/pdf',
        'image/jpeg',
      ]);
      expect(files.value, 'testverslag.pdf\ntestfoto.jpg');

      // Midnight in Brussels (CEST) is 22:00 UTC the day before.
      expect(date.date, DateTime.utc(2030, 10, 14, 22));
      expect(date.value, '2030-10-15');
      expect(date.rawValue, '1918245600');

      expect(heading.label, 'Testtitel');
      expect(heading.value, '');
      expect(heading.hasValue, isFalse);
      expect(heading.rawOptionValue, '2');

      expect(unknown.value, 'Testwaarde onbekend');
      expect(unknown.rawValue, 'Testwaarde onbekend');
      expect(unknown.rawOptionValue, 'Testoptie onbekend');
      expect(unknown.hasValue, isTrue);

      expect(today.date, isNull);
      expect(today.value, 'current');

      expect(empty.optionIds, isEmpty);
      expect(empty.value, '');
      expect(empty.hasValue, isFalse);

      for (final field in [text, rich, radio, checkbox, select, unknown]) {
        expect(field.attachments, isEmpty);
        expect(field.date, isNull);
      }
      for (final field in [text, rich, files, date, heading, unknown]) {
        expect(field.optionIds, isEmpty);
      }
      expect(files.hasValue, isTrue);
    });

    // The fixture's HTML has line breaks of its own between some blocks: LF
    // or CRLF, as the checkout gives them (a Windows checkout gives CRLF), and
    // as an answer of the LVS can have them. Both are tried, whatever the
    // checkout.
    for (final (ends, eol) in [('LF', '\n'), ('CRLF', '\r\n')]) {
      test('a rich text as plain text keeps its lines: a line break and each '
          'block of its HTML start a new line, the cells of a row stay on one; '
          'the line ends of the HTML ($ends) are white space (#171)', () async {
        final answer = _fixture(
          'notes/category_lines.xml',
        ).replaceAll('\r\n', '\n').replaceAll('\n', eol);
        final (_, lvs) = await _serve({'notes': _text(answer)});

        final field = (await _notesOf(lvs)).single.fields.single;

        expect(field.type, LvsNoteFieldType.richText);
        expect(
          field.value,
          [
            'Testkop',
            'Testtekst met',
            'twee regels',
            'Tweede testalinea.',
            'Testpunt een',
            'Testpunt twee',
            'Testblok',
            'Testcel een Testcel twee',
            'Testcel drie',
            'Testslot.',
          ].join('\n'),
        );
        // The HTML as the LVS sent it, its line ends kept.
        expect(LineSplitter.split(field.html!), [
          '<h3>Testkop</h3>',
          '<p>Testtekst met<br>twee regels</p><p>Tweede testalinea.</p>',
          '<p>&nbsp;</p>',
          '<ul>',
          '  <li>Testpunt een</li><li>Testpunt <b>twee</b></li>',
          '</ul><div>Testblok</div><table><tbody><tr><td>Testcel een</td>'
              '<td>Testcel twee</td></tr><tr><td>Testcel drie</td></tr></tbody>'
              '</table><p>Testslot.<br></p>',
        ]);
        expect(field.html, contains('</h3>$eol<p>'));
      });
    }

    test(
      'a category without notes in the school year: an empty list',
      () async {
        final (_, lvs) = await _serve({'notes': _xml('category_empty.xml')});

        expect(await _notesOf(lvs), isEmpty);
      },
    );

    test('a category the LVS does not know: '
        'SmartschoolLvsCategoryNotFoundError, never an empty list', () async {
      final (_, lvs) = await _serve({'notes': _xml('category_unknown.xml')});

      await expectLater(
        lvs.getNotes(pupilId: 900001, classId: 900101, categoryId: 999999),
        throwsA(
          isA<SmartschoolLvsCategoryNotFoundError>()
              .having((e) => e.pupilId, 'pupilId', 900001)
              .having((e) => e.classId, 'classId', 900101)
              .having((e) => e.categoryId, 'categoryId', 999999)
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', _quotesNothing),
        ),
      );
    });

    test("the LVS's placeholder pupil: SmartschoolLvsPupilNotFoundError, "
        'never an empty list', () async {
      final (_, lvs) = await _serve({'notes': _xml('pupil_unknown.xml')});

      await expectLater(
        lvs.getNotes(pupilId: 999998, classId: 999997, categoryId: 900401),
        throwsA(
          isA<SmartschoolLvsPupilNotFoundError>()
              .having((e) => e.pupilId, 'pupilId', 999998)
              .having((e) => e.classId, 'classId', 999997)
              .having((e) => e.message, 'message', _quotesNothing),
        ),
      );
    });

    test('an answer the service cannot read is a SmartschoolLvsError that '
        'quotes nothing, never an empty list', () async {
      final notes = _fixture('notes/category.xml');
      final empty = _fixture('notes/category_empty.xml');
      final answers = <String, String>{
        'not XML': 'Testnotitie over Janssens Jan',
        'XML that is not well-formed': '<server><response>Janssens Jan',
        'an HTML page': '<html><body>Janssens Jan</body></html>',
        'another root': '<results><Janssens/></results>',
        'no renderPupilNotes action': notes.replaceFirst(
          '<command>renderPupilNotes</command>',
          '<command>renderPupilNotesTest</command>',
        ),
        'data of two elements': notes.replaceFirst(
          '</content>',
          '</content><content/>',
        ),
        'fewer than 10 parts': empty.replaceFirst('<viewType></viewType>', ''),
        'another pupil': notes.replaceFirst(
          '<pupilID>900001</pupilID>',
          '<pupilID>900002</pupilID>',
        ),
        'another category': notes.replaceFirst(
          '<catID>900401</catID>',
          '<catID>900409</catID>',
        ),
        'catInfo of another category': notes.replaceFirst(
          '"catID":"900401"',
          '"catID":"900409"',
        ),
        'pupilInfo of another pupil': notes.replaceFirst(
          '"pupilID":900001',
          '"pupilID":900002',
        ),
        'pupilInfo without classID': notes.replaceFirst(
          '"classID":900101,',
          '',
        ),
        'pupilInfo not JSON': notes.replaceFirst(
          '{"pupilID":900001',
          'Janssens {"pupilID":900001',
        ),
        'hasData not a number': notes.replaceFirst(
          '<hasData>1</hasData>',
          '<hasData>Janssens</hasData>',
        ),
        'hasData 1 without notes': empty.replaceFirst(
          '<hasData>0</hasData>',
          '<hasData>1</hasData>',
        ),
        'a note of another pupil': _replaceNth(
          notes,
          '<pupilID>900001</pupilID>',
          '<pupilID>900002</pupilID>',
          2,
        ),
        'a note without itemID': notes.replaceFirst(
          // The note's own itemID comes before those of its fields.
          '<itemID>900301</itemID>',
          '<itemID></itemID>',
        ),
        'a note without catID': _replaceNth(
          notes,
          '<catID>900401</catID>',
          '<catID>Testcategorie</catID>',
          2,
        ),
        'a note without a date': notes.replaceFirst(
          '<date>1917073800</date>',
          '<date>2030-10-01</date>',
        ),
        'a note of fewer than 20 parts': notes.replaceFirst(
          RegExp(
            r'<isNew>0</isNew>\s*<originalCreate>0</originalCreate>\s*'
            r'</item>\s*</items>',
          ),
          '</item></items>',
        ),
        'a field of fewer than 6 parts': notes.replaceFirst(
          RegExp(
            r'<optionValue><!\[CDATA\[Testoptie goed\]\]></optionValue>\s*'
            r'<itemType>1</itemType>\s*<sortorder>3</sortorder>',
          ),
          '',
        ),
        'a field without paramID': notes.replaceFirst(
          '<paramID>900601</paramID>',
          '<paramID>Testveld</paramID>',
        ),
        'an option that is not an ID': notes.replaceFirst(
          '<val>900701</val>',
          '<val>Testoptie goed</val>',
        ),
        'attachments that are not JSON': notes.replaceFirst(
          RegExp(r'\{"900801".*?\}\}'),
          'testverslag.pdf',
        ),
        'attachments that are not a map': notes.replaceFirst(
          RegExp(r'\{"900801".*?\}\}'),
          '["testverslag.pdf"]',
        ),
        'an attachment without a name': notes.replaceFirst(
          '"fileName":"testverslag.pdf",',
          '',
        ),
      };
      for (final MapEntry(key: name, value: body) in answers.entries) {
        final (_, lvs) = await _serve({'notes': _text(body)});
        await expectLater(
          _notesOf(lvs),
          throwsA(_unreadable(statusCode: 200)),
          reason: name,
        );
      }
    });

    test(
      'XML that is not well-formed keeps the parser\'s error as the cause',
      () async {
        final (_, lvs) = await _serve({
          'notes': _text('<server><response>Janssens Jan'),
        });

        await expectLater(
          _notesOf(lvs),
          throwsA(
            isA<SmartschoolLvsError>().having(
              (e) => e.cause,
              'cause',
              isA<XmlException>(),
            ),
          ),
        );
      },
    );

    test('a status other than "ok" is a SmartschoolLvsError with the '
        "answer's message as the cause, out of the message", () async {
      final (_, lvs) = await _serve({
        'notes': _text(
          '<server><response><status>error</status>'
          '<message>Testfout over Janssens Jan.</message>'
          '</response></server>',
        ),
      });

      await expectLater(
        _notesOf(lvs),
        throwsA(
          allOf(
            _unreadable(statusCode: 200),
            isA<SmartschoolLvsError>().having(
              (e) => e.cause,
              'cause',
              'Testfout over Janssens Jan.',
            ),
          ),
        ),
      );
    });

    test('another status is a SmartschoolLvsError with it; an empty answer '
        'one too', () async {
      for (final (status, body) in [(500, '<html>Oeps</html>'), (200, '')]) {
        final (_, lvs) = await _serve({
          'notes': () =>
              _answer(body, status: status, contentType: 'text/html'),
        });
        await expectLater(
          _notesOf(lvs),
          throwsA(_unreadable(statusCode: status)),
          reason: '$status',
        );
      }
    });

    test('a refusal (403, or the start page) is a '
        'SmartschoolLvsAccessDeniedError, never an empty list', () async {
      for (final answer in [
        () => _answer('', status: 403, contentType: 'text/html'),
        _redirectToStartPage,
      ]) {
        final (_, lvs) = await _serve({'notes': answer});
        await expectLater(
          _notesOf(lvs),
          throwsA(
            isA<SmartschoolLvsAccessDeniedError>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('refused the notes of a category'),
                )
                .having((e) => e.message, 'message', _quotesNothing),
          ),
        );
      }
    });

    test('an ID that is not positive, or a school year that ends before it '
        'starts, is an ArgumentError, before anything is sent', () async {
      final (server, lvs) = await _serve({});

      for (final (pupil, group, category) in [
        (0, 900101, 900401),
        (900001, -1, 900401),
        (900001, 900101, 0),
      ]) {
        await expectLater(
          lvs.getNotes(pupilId: pupil, classId: group, categoryId: category),
          throwsArgumentError,
        );
      }
      await expectLater(
        _notesOf(
          lvs,
          schoolYear: LvsSchoolYear(
            from: DateTime.utc(2031, 9),
            until: DateTime.utc(2031, 8, 31),
          ),
        ),
        throwsArgumentError,
      );
      expect(server.requests, isEmpty);
    });

    test('the notes, fields and attachments print no value', () async {
      final (_, lvs) = await _serve({'notes': _xml('category.xml')});

      final notes = await _notesOf(lvs);

      expect('${notes.first}', 'LvsNote(fields: 11)');
      expect('${notes.first.fields[1]}', 'LvsNoteField(type: richText)');
      expect(
        '${notes.first.fields[5].attachments.first}',
        'LvsAttachment(<values hidden>)',
      );
      for (final note in notes) {
        expect('$note', _quotesNothing);
        for (final field in note.fields) {
          expect('$field', _quotesNothing);
          for (final attachment in field.attachments) {
            expect('$attachment', _quotesNothing);
          }
        }
      }
    });
  });

  group('getAllNotes', () {
    test("one request: the dispatcher's lvs_pupils/getUserData as the web "
        "client opens the 'all items' view", () async {
      final (server, lvs) = await _serve({'allNotes': _xml('all_notes.xml')});

      await lvs.getAllNotes(
        pupilId: 900001,
        classId: 900101,
        schoolYear: LvsSchoolYear.starting(2030),
      );

      expect(server.requests, ['POST /?module=LVS&file=dispatcher']);
      final command = server.commands.single;
      expect(command.subsystem, 'lvs_pupils');
      expect(command.action, 'getUserData');
      expect(command.params, {
        'userID': '900001',
        'toolbarType': 'main',
        'groupID': '900101',
        'syRange': '{"from":"2030-09-01","until":"2031-08-31"}',
        'viewAllFilter': '[]',
        'filterData': '0',
      });
    });

    test("the notes of every category, in the order of the 'all items' view "
        '(its dates), not the order of the answer', () async {
      final (_, lvs) = await _serve({'allNotes': _xml('all_notes.xml')});

      final notes = await lvs.getAllNotes(pupilId: 900001, classId: 900101);

      expect(notes.map((n) => n.id), [900303, 900301, 900302]);
      expect(notes.map((n) => n.categoryId), [900404, 900401, 900402]);
      // Without catName and without a category read, no name.
      expect(notes.map((n) => n.categoryName), [
        '',
        'Testcategorie',
        'Testsubcategorie',
      ]);
      expect(notes.map((n) => n.isConfidential), [false, false, true]);
      expect(notes[1].fields.single.value, 'Testtekst over het gedrag.');
    });

    test('dates as a map: walked as JavaScript walks an object (its index '
        'keys first, ascending); a note it leaves out comes last', () async {
      final body = _fixture('notes/all_notes.xml').replaceFirst(
        '["n_900303","a_900901","n_900301","r_900902","n_900302"]',
        '{"10":"n_900301","2":"n_900302","x_test":"a_900901"}',
      );
      final (_, lvs) = await _serve({'allNotes': _text(body)});

      final notes = await lvs.getAllNotes(pupilId: 900001, classId: 900101);

      expect(notes.map((n) => n.id), [900302, 900301, 900303]);
    });

    test('a file without notes in the school year, or a pupil the LVS does '
        'not know: an empty list', () async {
      final (_, lvs) = await _serve({'allNotes': _xml('all_notes_empty.xml')});

      expect(await lvs.getAllNotes(pupilId: 900001, classId: 900101), isEmpty);
    });

    test('an answer the service cannot read is a SmartschoolLvsError that '
        'quotes nothing', () async {
      final all = _fixture('notes/all_notes.xml');
      final answers = <String, String>{
        'no renderPupilAllNotes action': all.replaceFirst(
          '<command>renderPupilAllNotes</command>',
          '<command>renderPupilNotes</command>',
        ),
        'another pupil': all.replaceFirst(
          '<pupilID>900001</pupilID>',
          '<pupilID>900002</pupilID>',
        ),
        'dates not a list': all.replaceFirst(
          RegExp(r'\["n_900303".*?\]'),
          '900303',
        ),
        'an item of dates not a text': all.replaceFirst('"n_900303"', '900303'),
        'dates not JSON': all.replaceFirst(
          '["n_900303"',
          'Janssens ["n_900303"',
        ),
        'fewer than 8 parts': all.replaceFirst(
          RegExp(r'<notes>[\s\S]*'),
          '</content></data></action></actions></response></server>',
        ),
        'a note without a date': all.replaceFirst(
          '<date>1917073800</date>',
          '<date></date>',
        ),
      };
      for (final MapEntry(key: name, value: body) in answers.entries) {
        final (_, lvs) = await _serve({'allNotes': _text(body)});
        await expectLater(
          lvs.getAllNotes(pupilId: 900001, classId: 900101),
          throwsA(_unreadable(statusCode: 200)),
          reason: name,
        );
      }
    });

    test('a refusal is a SmartschoolLvsAccessDeniedError; an ID that is not '
        'positive an ArgumentError, before anything is sent', () async {
      final (_, refusing) = await _serve({
        'allNotes': () => _answer('', status: 403, contentType: 'text/html'),
      });
      await expectLater(
        refusing.getAllNotes(pupilId: 900001, classId: 900101),
        throwsA(isA<SmartschoolLvsAccessDeniedError>()),
      );

      final (server, lvs) = await _serve({});
      await expectLater(
        lvs.getAllNotes(pupilId: 0, classId: 900101),
        throwsArgumentError,
      );
      await expectLater(
        lvs.getAllNotes(pupilId: 900001, classId: 0),
        throwsArgumentError,
      );
      expect(server.requests, isEmpty);
    });
  });

  group('noteCategories', () {
    test("the categories of notes of a pupil's file, with their "
        'sub-categories at any depth; the other sections left out', () async {
      final (_, lvs) = await _serve({
        'file': () => _answer(
          _fixture('spotlight/pupil_file.json'),
          contentType: 'application/json',
        ),
        'status': () => _answer('[]', contentType: 'application/json'),
      });

      final file = await lvs.getPupilFile(pupilId: 900001, classId: 900101);
      final categories = file.noteCategories;

      expect(categories.map((c) => c.id), [900401]);
      final category = categories.single;
      expect(category.name, 'Testcategorie');
      expect(category.hasNotes, isTrue);
      expect(category.hasNewNotes, isTrue);
      expect(category.isTitle, isFalse);
      expect(category.subcategories.map((c) => c.id), [900402, 900403]);
      final heading = category.subcategories.last;
      expect(heading.isTitle, isTrue);
      expect(heading.subcategories.single.id, 900404);
      expect(heading.subcategories.single.hasNewNotes, isFalse);
      expect(category.descendants.map((c) => c.id), [900402, 900403, 900404]);
      expect(
        '$category',
        'LvsCategory(hasNotes: true, hasNewNotes: true, subcategories: 2)',
      );
    });

    test('a category under a section of another type is listed in its '
        'place', () {
      LvsSection section(
        int id,
        String type, [
        List<LvsSection> children = const [],
      ]) => LvsSection(
        id: id,
        type: type,
        name: 'Testsectie',
        hasItems: true,
        hasNewItems: false,
        children: children,
      );
      const status = LvsTodayStatus.none;
      final file = LvsPupilFile(
        pupilId: 900001,
        classId: 900101,
        name: 'Janssens Jan',
        className: '1A',
        classDescription: '',
        teachers: const [],
        sections: [
          section(0, 'testsection', [
            section(900401, LvsSectionType.items),
            section(900405, LvsSectionType.supportPlans),
          ]),
          section(900402, LvsSectionType.items, [
            section(900406, LvsSectionType.supportPlans, [
              section(900403, LvsSectionType.items),
            ]),
          ]),
        ],
        todayStatus: status,
      );

      expect(file.noteCategories.map((c) => c.id), [900401, 900402]);
      expect(file.noteCategories.last.subcategories.map((c) => c.id), [900403]);
    });
  });

  group('LvsSchoolYear', () {
    test('from 1 September to 31 August', () {
      final year = LvsSchoolYear.starting(2030);

      expect(year.firstDay, '2030-09-01');
      expect(year.lastDay, '2031-08-31');
      expect(year.isEmpty, isFalse);
      expect('$year', 'LvsSchoolYear(2030-09-01 - 2031-08-31)');
      expect(LvsSchoolYear.containing(DateTime(2031, 8, 31)), year);
      expect(LvsSchoolYear.containing(DateTime(2030, 9)), year);
      expect(
        LvsSchoolYear.containing(DateTime(2031, 9)).firstDay,
        '2031-09-01',
      );
    });

    test('the current one changes at midnight in Brussels', () {
      // 1 September 00:30 in Brussels (CEST) is 22:30 UTC on 31 August.
      expect(
        LvsSchoolYear.current(now: DateTime.utc(2031, 8, 31, 22, 30)).firstDay,
        '2031-09-01',
      );
      // 31 August 23:30 in Brussels.
      expect(
        LvsSchoolYear.current(now: DateTime.utc(2031, 8, 31, 21, 30)).firstDay,
        '2030-09-01',
      );
      expect(
        LvsSchoolYear.current(now: DateTime.utc(2031, 1, 15)).firstDay,
        '2030-09-01',
      );
    });

    test('any range of days; empty when it ends before it starts', () {
      final range = LvsSchoolYear(
        from: DateTime(2030, 10, 1, 18),
        until: DateTime(2030, 10, 1, 6),
      );
      expect(range.firstDay, '2030-10-01');
      expect(range.lastDay, '2030-10-01');
      expect(range.isEmpty, isFalse);
      expect(
        LvsSchoolYear(
          from: DateTime.utc(2030, 10, 2),
          until: DateTime.utc(2030, 10, 1),
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('the allowlist of the XML dispatcher', () {
    String request(
      String subsystem,
      String action,
      Map<String, String> params, {
      String extra = '',
    }) =>
        '<request><command><subsystem>$subsystem</subsystem>'
        '<action>$action</action><params>'
        '${[for (final MapEntry(:key, :value) in params.entries) '<param name="$key"><![CDATA[$value]]></param>'].join()}'
        '</params>$extra</command></request>';

    const notesParams = {
      'catID': '900401',
      'userID': '900001',
      'toolbarType': 'main',
      'syRange': '{"from":"2030-09-01","until":"2031-08-31"}',
      'groupID': '900101',
      'toolbarSide': 'left',
    };

    test('the reads of the service are on it', () {
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: LvsWire.dispatcherQuery,
          form: {
            'command': request('lvs_cats', 'getUserCatItems', notesParams),
          },
        ),
        same(LvsWire.categoryNotes),
      );
      expect(
        LvsWire.readOf(
          'POST',
          '/',
          query: LvsWire.dispatcherQuery,
          form: {
            'command': LvsWire.allNotes.command!.build({
              'userID': '900001',
              'viewAllFilter': '[]',
            }),
          },
        ),
        same(LvsWire.allNotes),
      );
    });

    test(
      'a value with "]]>" goes out whole, split over two CDATA sections',
      () {
        final command = LvsWire.categoryNotes.command!.build({
          'syRange': 'Test ]]> waarde',
        });

        expect(command, contains('Test ]]]]><![CDATA[> waarde'));
        final param = XmlDocument.parse(
          command,
        ).findAllElements('param').single;
        expect(param.innerText, 'Test ]]> waarde');
        expect(
          () => LvsWire.categoryNotes.command!.build({'itemID': '900301'}),
          throwsArgumentError,
        );
      },
    );

    test('any other command, or the read with more, is refused before it is '
        'sent', () async {
      final server = _Lvs({});
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = server;
      final wire = LvsWire(client);

      const dispatcher = LvsWire.dispatcherQuery;
      final refused = <(String, Map<String, String>, Map<String, String>)>[
        // The web client sends it with getUserCatItems: its list layouts.
        (
          'POST',
          dispatcher,
          {'command': request('lvs_pupils', 'getCatListView', notesParams)},
        ),
        // Writes of the same dispatcher.
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_pupils', 'changeItemViewStatus', {
              'userID': '900001',
              'itemID': '900301',
              'viewed': '1',
            }),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_pupils', 'saveProfile', {
              'userID': '900001',
            }),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_cats', 'getCatParams', {'catID': '900401'}),
          },
        ),
        // The read, of another subsystem, with a param more, twice, with
        // something more in the command or the request.
        (
          'POST',
          dispatcher,
          {'command': request('lvs_pupils', 'getUserCatItems', notesParams)},
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_cats', 'getUserCatItems', {
              ...notesParams,
              'itemID': '900301',
            }),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_cats', 'getUserCatItems', notesParams)
                .replaceFirst(
                  '</params>',
                  '<param name="catID">1</param></params>',
                ),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request(
              'lvs_cats',
              'getUserCatItems',
              notesParams,
              extra: '<subsystem>lvs_pupils</subsystem>',
            ),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_cats', 'getUserCatItems', notesParams)
                .replaceFirst(
                  '</request>',
                  '<command><subsystem>lvs_pupils</subsystem>'
                      '<action>changeItemViewStatus</action><params/></command>'
                      '</request>',
                ),
          },
        ),
        (
          'POST',
          dispatcher,
          {
            'command': request(
              'lvs_cats',
              'getUserCatItems',
              notesParams,
            ).replaceFirst('<command>', 'test<command>'),
          },
        ),
        // Not a command, none, or with another field.
        ('POST', dispatcher, {'command': '<request><command>'}),
        ('POST', dispatcher, const {}),
        (
          'POST',
          dispatcher,
          {
            'command': request('lvs_cats', 'getUserCatItems', notesParams),
            'save': '1',
          },
        ),
        // The read to another file of the LVS, or as a GET.
        (
          'POST',
          {'module': 'LVS', 'file': 'jqDispatcher_item'},
          {'command': request('lvs_cats', 'getUserCatItems', notesParams)},
        ),
        ('GET', dispatcher, const {}),
      ];
      for (final (method, query, form) in refused) {
        await expectLater(
          wire.send(method, '/', query: query, form: form),
          throwsA(
            isA<SmartschoolLvsRequestNotAllowedError>()
                .having((e) => e.method, 'method', method)
                .having((e) => e.path, 'path', '/')
                .having(
                  (e) => e.message,
                  'message',
                  contains('Nothing was sent'),
                )
                .having((e) => e.message, 'message', isNot(contains('9001')))
                .having((e) => e.message, 'message', isNot(contains('9003'))),
          ),
          reason: '$method $query ${form['command']}',
        );
      }
      expect(server.requests, isEmpty);
    });

    test('a refused command is named by its subsystem and action', () async {
      final client = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      client.dio.httpClientAdapter = _Lvs({});

      await expectLater(
        LvsWire(client).send(
          'POST',
          '/',
          query: LvsWire.dispatcherQuery,
          form: {
            'command': request('lvs_pupils', 'changeItemViewStatus', {
              'itemID': '900301',
            }),
          },
        ),
        throwsA(
          isA<SmartschoolLvsRequestNotAllowedError>().having(
            (e) => e.message,
            'message',
            contains('the command lvs_pupils/changeItemViewStatus'),
          ),
        ),
      );
    });
  });
}
