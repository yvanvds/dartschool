// Tests for #178: tool/lvs_har_shapes.dart, which reduces a browser capture
// (a HAR file) of the LVS to shapes, for the developer's capture step (#168;
// doc/lvs-privacy.md, "Capturing with the browser").
//
// A capture holds a pupil's data in full, and what the tool prints is meant
// to be pasted in an issue: so the heart of this file is that no value of
// the capture shows in the output. The fake HAR below is written by hand,
// with the fakes of test/fixtures/lvs/FAKES.md only (people, the school, its
// classes, labels and texts that say "Test", ids of 900000-999999, made-up
// dates of the school year 2030-2031, base64 of fakes), and holds what a
// capture of the LVS holds: JSON answers with keys that are data (days,
// school years, ids, a label with a space), the XML dispatcher with its
// URL-encoded `command`, JSON in an XML text, JSON encoded twice, a JSON
// request body, an answer the HAR keeps in base64, an HTML error page, a
// redirect, static files, the web apps' translations and another host, with
// the cookies and headers a browser adds. The tests check that none of its
// values shows (each fake put in, and every number of four digits or more,
// every "test" word and every base64 string of the capture), that the
// shapes a capture relies on do, and that the tool refuses a HAR inside the
// repository, also when it runs as `dart run tool/lvs_har_shapes.dart`.
//
// The HAR is built in code here, not kept as a file of test/fixtures/lvs/:
// its own fields (a header's `name` and `value`, a body's `text`) are not
// the fields of an LVS answer that lvs_fixtures_guard_test.dart checks
// there, and its answers are made of the fakes, as the tests below check.
// The guard's scan of every file under test/ for base64 of names covers this
// file too.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/lvs_har_shapes.dart' show isInsideRepository, shapesOf;
import '../support/no_network.dart';

/// The fake school's Smartschool.
const _origin = 'https://springfield.smartschool.be';

/// The values of the capture that must never show: fakes of FAKES.md as the
/// LVS writes them, and what a browser adds (a header's value, a cookie).
/// On top of these, [_valuesOf] takes every number of four digits or more,
/// every word that starts with "test" and every base64 string of the
/// capture.
const _fakes = [
  'Jan Janssens',
  'Janssens Jan',
  'Janssens',
  'Jans',
  'Marie Peeters',
  'Marie',
  'Peeters Piet',
  'Piet Peeters',
  'Peeters',
  'Els Jacobs',
  'Jacobs',
  'Springfield',
  'Academy',
  '1A',
  '2B',
  'initials_JJ',
  'initials_MP',
  '00000000-0000-0000-0000-000000900001',
  '#ff0000',
  'Volledige dag',
  'ma 16 september 2030',
  'di 17 september 2030',
  '2030-09-16',
  '2030-09-01',
  '2031-08-31',
  '16/09/2030',
  '2030-2031',
  '08:00:00',
  'tree_group',
  'XMLHttpRequest',
  'PHPSESSID',
  'Mozilla',
  'Chromium',
  'nl_BE',
  'lvs-built',
  'tracker',
  'example.com',
  'main',
];

/// Base64 of fakes only, as Skore's `alternate` carries a pupil's name.
final _fakeBase64 = base64.encode(
  utf8.encode('Jan Janssens, Marie Peeters, Springfield Academy'),
);

/// The `command` of the XML dispatcher, as the web client sends it to open
/// a category of a pupil's file (lvs_wire.dart, #161).
const _command =
    '<request><command><subsystem>lvs_cats</subsystem>'
    '<action>getUserCatItems</action><params>'
    '<param name="catID"><![CDATA[900401]]></param>'
    '<param name="userID"><![CDATA[900001]]></param>'
    '<param name="toolbarType"><![CDATA[main]]></param>'
    '<param name="syRange"><![CDATA[{"from":"2030-09-01","until":"2031-08-31"}]]></param>'
    '<param name="groupID"><![CDATA[900101]]></param>'
    '<param name="searchVal"><![CDATA[Jan Janssens]]></param>'
    '</params></command></request>';

/// The dispatcher's answer to [_command]: notes of the category, with JSON
/// in the texts of its elements.
const _notesAnswer =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>lvs_pupil</subsystem><command>renderPupilNotes</command>'
    '<data><content><pupilID>900001</pupilID><catID>900401</catID>'
    '<catInfo><![CDATA[{"catID":"900401","name":"Testcategorie",'
    '"date_created":"2030-09-01 08:00:00"}]]></catInfo>'
    '<pupilInfo><![CDATA[{"pupilID":900001,"name":"Janssens Jan",'
    '"class":"1A","teachers":{"900201":"Peeters Piet"}}]]></pupilInfo>'
    '<items>'
    '<item><itemID>900301</itemID>'
    '<title><![CDATA[Testnotitie over de leerling.]]></title>'
    '<date>1917073800</date><author><![CDATA[Peeters Piet]]></author>'
    '<dates><![CDATA[{"n_900301":1,"a_900901":2}]]></dates></item>'
    '<item><itemID>900302</itemID>'
    '<title><![CDATA[Testnotitie over de les.]]></title>'
    '<date>1917160200</date><author><![CDATA[Els Jacobs]]></author>'
    '<dates><![CDATA[["n_900302","r_900902"]]]></dates></item>'
    '</items></content></data></action></actions></response></server>';

/// The headers of a read of the LVS's web apps.
const _xhr = {'x-requested-with': 'XMLHttpRequest'};

/// The headers of a form the web client posts.
const _formHeaders = {
  'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
  'x-requested-with': 'XMLHttpRequest',
};

/// The headers of the results app's reads (#175), and of a JSON body.
const _jsonHeaders = {
  'content-type': 'application/json',
  'x-requested-with': 'XMLHttpRequest',
};

/// The HAR file of a capture with [entries], as the DevTools' Network tab
/// saves it.
Map<String, Object?> _har(List<Map<String, Object?>> entries) => {
  'log': {
    'version': '1.2',
    'creator': {'name': 'WebInspector', 'version': '537.36'},
    'pages': [
      {
        'startedDateTime': '2030-09-16T08:25:00.000Z',
        'id': 'page_1',
        'title': '$_origin/?module=LVS&pupil=900001',
        'pageTimings': {'onContentLoad': 120.5, 'onLoad': 240.5},
      },
    ],
    'entries': entries,
  },
};

/// One request of a capture and its answer [body], with what a browser
/// adds: its own headers (the session's cookie, a referer, the HTTP/2
/// pseudo-headers with the full path and query), the query as a list, the
/// cookies, the answer's headers, the timings.
Map<String, Object?> _entry(
  String method,
  String url, {
  Map<String, String> headers = const {},
  Map<String, Object?>? postData,
  int status = 200,
  String mimeType = 'application/json',
  String body = '',
  bool bodyInBase64 = false,
  String redirectUrl = '',
  String resourceType = 'xhr',
}) {
  final uri = Uri.parse(url);
  Map<String, String> header(String name, String value) => {
    'name': name,
    'value': value,
  };
  return {
    '_resourceType': resourceType,
    'startedDateTime': '2030-09-16T08:25:00.000Z',
    'time': 42.5,
    'request': {
      'method': method,
      'url': url,
      'httpVersion': 'http/2.0',
      'headers': [
        header(':authority', uri.host),
        header(':method', method),
        header(':path', uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path),
        header(':scheme', 'https'),
        header('accept', '*/*'),
        header('accept-language', 'nl-BE,nl;q=0.9'),
        header('cookie', 'PHPSESSID=testsessie900911; pid=900001'),
        header('referer', '$_origin/LVS/Spotlight/900001?classID=900101'),
        header('sec-ch-ua', '"Chromium";v="130"'),
        header('user-agent', 'Mozilla/5.0 (Testbrowser)'),
        for (final MapEntry(:key, :value) in headers.entries)
          header(key, value),
      ],
      'queryString': [
        for (final MapEntry(:key, :value) in uri.queryParameters.entries)
          header(key, value),
      ],
      'cookies': [
        {'name': 'PHPSESSID', 'value': 'testsessie900911', 'httpOnly': true},
      ],
      'headersSize': -1,
      'bodySize': 0,
      'postData': ?postData,
    },
    'response': {
      'status': status,
      'statusText': '',
      'httpVersion': 'http/2.0',
      'headers': [
        header('content-type', mimeType),
        header('set-cookie', 'PHPSESSID=testsessie900912; path=/'),
        header('content-disposition', 'inline; filename="Jan Janssens.json"'),
        if (redirectUrl.isNotEmpty) header('location', redirectUrl),
      ],
      'cookies': [],
      'content': {
        'size': utf8.encode(body).length,
        'mimeType': mimeType,
        if (body.isNotEmpty)
          'text': bodyInBase64 ? base64.encode(utf8.encode(body)) : body,
        if (body.isNotEmpty && bodyInBase64) 'encoding': 'base64',
      },
      'redirectURL': redirectUrl,
      'headersSize': -1,
      'bodySize': -1,
      '_transferSize': 512,
    },
    'cache': {},
    'timings': {
      'blocked': 1.5,
      'dns': -1,
      'ssl': -1,
      'connect': -1,
      'send': 0.5,
      'wait': 40.5,
      'receive': 1.5,
    },
  };
}

/// The `postData` of a form with [fields], as the HAR holds it: the body,
/// and each field with its name and value URL-encoded.
Map<String, Object?> _form(Map<String, String> fields) => {
  'mimeType': 'application/x-www-form-urlencoded; charset=UTF-8',
  'text': Uri(queryParameters: fields).query,
  'params': [
    for (final MapEntry(:key, :value) in fields.entries)
      {
        'name': Uri.encodeQueryComponent(key),
        'value': Uri.encodeQueryComponent(value),
      },
  ],
};

/// The fake capture: a teacher searching a pupil, opening the pupil's file,
/// a category, the support plan, the absences and the results, with what
/// the page loads on the side.
Map<String, Object?> _capture() => _har([
  // The pupil search: an id key, HTML, a URL, a UUID, base64.
  _entry(
    'GET',
    '$_origin/LVS/Spotlight?searchVal=Jans',
    headers: _xhr,
    body: jsonEncode({
      'search': 'Jans',
      'classes': [],
      'pupils': [
        {
          'userID': 900001,
          'classID': 900101,
          'className': '1A',
          'foundName': '<b>Jans</b>sens Jan',
          'picUrl': '/smsc/img/fake/initials_JJ.png',
          'uuid': '00000000-0000-0000-0000-000000900001',
          'alternate': _fakeBase64,
        },
        {
          'userID': '900002',
          'classID': 900102,
          'className': '2B',
          'foundName': 'Marie <b>Peeters</b>',
          'picUrl': '/smsc/img/fake/initials_MP.png',
          'uuid': '00000000-0000-0000-0000-000000900002',
          'alternate': _fakeBase64,
        },
      ],
      'teachers': {'900201': 'Piet Peeters'},
      'groups': {},
      'groupUsers': [],
    }),
  ),
  // The pupil's file, kept in base64 by the HAR: enum keys with a word and
  // with a name, a colour, a date.
  _entry(
    'GET',
    '$_origin/LVS/Spotlight/900001?classID=900101',
    headers: _xhr,
    bodyInBase64: true,
    body: jsonEncode({
      'categories': [
        {
          'id': 900401,
          'type': 'items',
          'name': 'Testcategorie',
          'isTitle': false,
          'hasItems': true,
          'children': [
            {
              'id': 900402,
              'type': 'items',
              'name': 'Testsubcategorie',
              'isTitle': false,
              'hasItems': false,
              'children': [],
            },
          ],
        },
        {
          'id': 0,
          'type': 'Jan Janssens',
          'name': 'Testsectie',
          'isTitle': true,
          'hasItems': false,
          'children': [],
        },
      ],
      'pupil': {
        'userID': 900001,
        'name': 'Janssens Jan',
        'class': '1A',
        'classDesc': 'Testrichting',
        'classID': 900101,
        'keyword': 'Testtrefwoord',
        'color': '#ff0000',
        'birthDate': '16/09/2030',
        'teachers': {'900201': 'Peeters Piet'},
      },
    }),
  ),
  // Today's status: a form with an id in a field's name, enum words.
  _entry(
    'POST',
    '$_origin/LVS/Pupilxhr/getStatusInfo',
    headers: _formHeaders,
    postData: _form({'pupilID': '900001', 'viewed[900301]': '1'}),
    body: jsonEncode([
      {
        'partOfDay': 'am',
        'code': {'name': 'Testcode', 'code': 'TEST', 'color': 'red'},
      },
      {
        'partOfDay': 'pm',
        'code': {'name': 'Testcode 2', 'code': 'TEST', 'color': 'yellow'},
      },
    ]),
  ),
  // A category's notes: the XML dispatcher, JSON in its texts, keys with an
  // id in them.
  _entry(
    'POST',
    '$_origin/?module=LVS&file=dispatcher',
    headers: _formHeaders,
    postData: _form({'command': _command}),
    mimeType: 'text/xml; charset=UTF-8',
    body: _notesAnswer,
  ),
  // The support plan: a form as text only, with JSON in a field; JSON
  // encoded twice; an enum key with a label.
  _entry(
    'POST',
    '$_origin/?module=LVS&file=jqDispatcher_hp&function=getIHP',
    headers: _formHeaders,
    postData: {
      'mimeType': 'application/x-www-form-urlencoded; charset=UTF-8',
      'text': Uri(
        queryParameters: {
          'pupilID': '900001',
          'periodID': '0',
          'exportID': '0',
          'filter': '{"from":"2030-09-01","until":"2031-08-31"}',
        },
      ).query,
    },
    body: jsonEncode(
      jsonEncode({
        'check': 1,
        'items': [
          {
            'id': 900701,
            'type': 'ihp',
            'author': 'Els Jacobs',
            'date': '16/09/2030',
            'ondName': 'Testondersteuning',
            'versionType': 'Testversie',
          },
        ],
        'period': {'id': 900801, 'message': 'Testbericht'},
      }),
    ),
  ),
  // The absences: a JSON body; school years, a label with a space and days
  // as keys.
  _entry(
    'POST',
    '$_origin/LVS/Pupilpresences',
    headers: _jsonHeaders,
    postData: {
      'mimeType': 'application/json',
      'text': jsonEncode({
        'pupilID': 900001,
        'classID': 900101,
        'schoolYear': '2030-2031',
      }),
    },
    body: jsonEncode({
      'presences': {
        '2030-2031': [
          {
            'am': {
              'partOfDay': 'am',
              'codeKey': '900501-900502',
              'code': 'TEST',
              'codeColor': 'red',
              'codeDescr': 'Testcode',
              'formattedDate': 'ma 16 september 2030',
            },
          },
          {
            'full': {
              'partOfDay': 'Volledige dag',
              'codeKey': '900501',
              'code': 'TEST',
              'codeColor': 'yellow',
              'codeDescr': 'Testcode 2',
              'motivation': '<p>Testmotivatie.</p>',
              'formattedDate': 'di 17 september 2030',
            },
          },
        ],
        'Testperiode 2': {
          '2030-09-16': {
            'am': {
              'partOfDay': 'am',
              'codeKey': '900503',
              'codeDescr': 'Testcode',
              'motivation': 'Testmotivatie.',
            },
          },
        },
      },
      'year_label': '2030-2031',
    }),
  ),
  // The root of the class tree.
  _entry(
    'POST',
    '$_origin/?module=LVS&file=treeBuilder',
    headers: _formHeaders,
    postData: _form({'id': '0'}),
    body: jsonEncode([
      {
        'id': 'tree_group_900101',
        'text': '1A',
        'data': {'title': '1A'},
        'children': true,
      },
    ]),
  ),
  // The results app's read, with its headers (#175)...
  _entry(
    'GET',
    '$_origin/LVS/Results/getConfiguration?pupilId=900001&groupId=900101',
    headers: _jsonHeaders,
    body: jsonEncode({
      'capabilities': {'canSeeAll': true, 'canSeeSchoolYear': false},
    }),
  ),
  // ... and without them: Smartschool's error page, a fake in its title.
  _entry(
    'GET',
    '$_origin/LVS/Results/getperiods?pupilId=900001&groupId=900101'
        '&startDate=2030-09-01&endDate=2031-08-31',
    status: 500,
    mimeType: 'text/html; charset=UTF-8',
    body:
        '<!DOCTYPE html><html><head><title>Fout bij Jan Janssens</title>'
        '</head><body><h1>Testfout</h1>'
        '<p>Testfout bij het lezen van de resultaten.</p></body></html>',
  ),
  // A pupil the teacher may not see: a redirect to the start page.
  _entry(
    'GET',
    '$_origin/LVS/Spotlight/900002?classID=900102',
    status: 302,
    mimeType: 'text/html',
    redirectUrl:
        '$_origin/?module=Homepage&pupilID=900002&name=Marie%20Peeters',
    resourceType: 'document',
  ),
  // A made-up endpoint with ids in its path and in an endpoint's name, and
  // an answer in plain text.
  _entry(
    'GET',
    '$_origin/LVS/Download/attachment_900901?file=n_900301',
    status: 404,
    mimeType: 'text/plain',
    body: 'Testbijlage van Jan Janssens niet gevonden.',
  ),
  // Static files: by their type, and by their extension.
  _entry(
    'GET',
    '$_origin/smsc/js/lvs/lvs-built.js?v=900001',
    mimeType: 'application/javascript',
    body: "var pupil = 'Jan Janssens';",
    resourceType: 'script',
  ),
  _entry(
    'GET',
    '$_origin/smsc/css/lvs.css?v=900001',
    mimeType: 'text/css',
    body: '.Testklasse { color: red; }',
    resourceType: 'other',
  ),
  _entry(
    'GET',
    '$_origin/smsc/img/fake/initials_JJ.png',
    mimeType: 'image/png',
    resourceType: 'image',
  ),
  // The web apps' translations.
  _entry(
    'GET',
    '$_origin/smsc/locales/nl_BE/lvs.json',
    body: jsonEncode({
      'Testcategorie': 'Testcategorie',
      'lng_title': 'Jan Janssens',
    }),
    resourceType: 'fetch',
  ),
  // Another host.
  _entry(
    'POST',
    'https://tracker.example.com/collect?user=Jan%20Janssens&pupil=900001',
    postData: {
      'mimeType': 'application/json',
      'text': jsonEncode({'pupil': 'Jan Janssens', 'class': '1A'}),
    },
    body: jsonEncode({'Testontvangen': true}),
  ),
]);

/// Every text of [node], a decoded HAR: each string, and what it holds when
/// it is URL-encoded, base64 of UTF-8 text, or JSON (a body, a JSON text in
/// it), each read the same way in turn.
Iterable<String> _textsOf(Object? node) sync* {
  switch (node) {
    case String():
      yield node;
      final decoded = _urlDecoded(node);
      if (decoded != node) yield* _textsOf(decoded);
      if (_base64String.hasMatch(node)) {
        try {
          yield* _textsOf(utf8.decode(base64.decode(node)));
        } on FormatException {
          // Not base64 of text.
        }
      }
      final text = node.trim();
      if (text.startsWith('{') ||
          text.startsWith('[') ||
          text.startsWith('"')) {
        try {
          yield* _textsOf(jsonDecode(text));
        } on FormatException {
          // Not JSON.
        }
      }
    case Map():
      for (final value in node.values) {
        yield* _textsOf(value);
      }
    case List():
      for (final item in node) {
        yield* _textsOf(item);
      }
  }
}

/// [text] URL-decoded, or [text] when it is not URL-encoded (a `%` alone).
String _urlDecoded(String text) {
  try {
    return Uri.decodeQueryComponent(text);
  } on ArgumentError {
    return text;
  }
}

/// A base64 string of some length: of a name, of an answer.
final _base64String = RegExp(r'^[A-Za-z0-9+/]{16,}={0,2}$');

/// The values of [har] that must never show: [_fakes], and every number of
/// four digits or more, every word that starts with "test" and every text
/// that is base64 (not a path) in its texts; in lower case.
Set<String> _valuesOf(Map<String, Object?> har) {
  final texts = _textsOf(har).toList();
  return {
    for (final fake in _fakes) fake.toLowerCase(),
    for (final text in texts) ...[
      for (final match in RegExp(r'\d{4,}').allMatches(text)) match.group(0)!,
      for (final match in RegExp(
        r'test[\p{L}\d]*',
        caseSensitive: false,
        unicode: true,
      ).allMatches(text))
        match.group(0)!.toLowerCase(),
      if (text.length >= 32 &&
          _base64String.hasMatch(text) &&
          !text.startsWith('/'))
        text.toLowerCase(),
    ],
  };
}

void main() {
  forbidRealNetwork();

  final har = _capture();
  // As the tool reads it: from the JSON of the file.
  final decoded = jsonDecode(jsonEncode(har)) as Map<String, dynamic>;
  final output = shapesOf(decoded);

  group('shapesOf', () {
    test('holds the fakes it is tested with', () {
      final texts = _textsOf(har).join('\n').toLowerCase();
      final missing = [
        for (final (i, fake) in _fakes.indexed)
          if (!texts.contains(fake.toLowerCase())) 'fake [$i]',
      ];
      expect(missing, isEmpty, reason: 'fakes the capture does not hold');
      expect(texts, contains(_fakeBase64.toLowerCase()));
    });

    test('shows no value of the capture', () {
      final values = _valuesOf(har);
      // The fakes, and what the capture holds besides: ids, dates,
      // timestamps, "test" words, the base64 of a name and of an answer.
      expect(values.length, greaterThan(_fakes.length + 40));
      expect(values, contains('900001'));
      expect(values, contains('1917073800'));
      expect(values, contains('testnotitie'));
      expect(values, contains(_fakeBase64.toLowerCase()));

      final shown = output.toLowerCase();
      final leaked = [
        for (final value in values)
          if (shown.contains(value)) value,
      ];
      expect(leaked, isEmpty, reason: 'values of the capture in the output');
    });

    test('shows each request to Smartschool, with its path masked', () {
      final requests = RegExp(
        r'^#\d+ .*$',
        multiLine: true,
      ).allMatches(output).map((match) => match.group(0)).toList();
      expect(requests, [
        '#1 GET /LVS/Spotlight',
        '#2 GET /LVS/Spotlight/<n>',
        '#3 POST /LVS/Pupilxhr/getStatusInfo',
        '#4 POST /',
        '#5 POST /',
        '#6 POST /LVS/Pupilpresences',
        '#7 POST /',
        '#8 GET /LVS/Results/getConfiguration',
        '#9 GET /LVS/Results/getperiods',
        '#10 GET /LVS/Spotlight/<n>',
        '#11 GET /LVS/Download/attachment_<n>',
      ]);
    });

    test('leaves out static files, the translations and other hosts', () {
      expect(
        output,
        endsWith(
          '\n11 requests shown; 4 static files and 1 requests to other '
          'hosts left out.\n',
        ),
      );
      for (final part in ['/smsc/', 'locales', 'collect', '.js', '.css']) {
        expect(output, isNot(contains(part)), reason: part);
      }
    });

    test('shows the shapes and patterns a capture relies on', () {
      final missing = [
        for (final shape in [
          // The fields of a query, of a form, of a JSON body.
          'query searchVal = <text>',
          'query classID = "999999"',
          'query module = "LVS"',
          'query file = "dispatcher"',
          'query function = "getIHP"',
          'query startDate = "9999-99-99"',
          'form pupilID = "999999"',
          'form viewed[<n>] = "9"',
          'form command = XML:',
          'form filter = <JSON text: {from, until}>',
          'json body:',
          'schoolYear: "9999-9999"',
          // The request headers that are not a browser's own.
          'other headers: x-requested-with',
          'content-type application/json',
          'referer /LVS/Spotlight/<n> (query: classID)',
          // The dispatcher's command: its subsystem, action and params.
          'subsystem: "lvs_cats"',
          'action: "getUserCatItems"',
          '@name: "catID" | "userID" | "toolbarType" | "syRange" | "groupID" '
              '| "searchVal"',
          'from: "9999-99-99"',
          // The kinds of the answers.
          'answer (JSON):',
          'answer (XML):',
          'answer: JSON text holding JSON (encoded twice):',
          'answer: HTML, ',
          'answer: text, ',
          '(not shown)',
          '<JSON text>',
          // A redirect.
          '-> 302 text/html',
          'redirect to / (query: module, pupilID, name)',
          // The patterns of values.
          'foundName: <html>',
          'picUrl: <url>',
          'uuid: <uuid>',
          'alternate: <base64?>',
          'color: <colour>',
          'birthDate: "99/99/9999"',
          'date_created: "9999-99-99 99:99:99"',
          'date: "9999999999"',
          'codeKey: "999999-999999"',
          'userID: int | "999999"',
          'isTitle: bool',
          // Keys that are data: ids, days, school years, a label.
          '<keys 999999> x1: <text>',
          '<keys n_999999 | a_999999> x2: int',
          '<keys 9999-9999 | <text>> x2',
          '<keys 9999-99-99> x1',
          'year_label: "9999-9999"',
          // Enum words and endpoint names.
          'status: "ok"',
          'command: "renderPupilNotes"',
          'partOfDay: "am" | "pm"',
          'type: "items" | <text>',
          'type: "ihp"',
          'color: "red" | "yellow"',
          'codeColor: "yellow"',
          'versionType: <text>',
          'file = <text>',
        ])
          if (!output.contains(shape)) shape,
      ];
      expect(missing, isEmpty, reason: 'shapes not in the output');
    });
  });

  group('the tool', () {
    final root = Directory.current.path;
    final script = p.join(root, 'tool', 'lvs_har_shapes.dart');

    setUpAll(() {
      // dart test runs from the package root.
      expect(File(p.join(root, 'pubspec.yaml')).existsSync(), isTrue);
      expect(File(script).existsSync(), isTrue);
    });

    /// A folder for the test's HAR files, deleted afterwards: outside the
    /// repository (the system's temp folder), or inside it (in its
    /// git-ignored `.dart_tool/`).
    Directory folder({required bool inRepository}) {
      final parent = inRepository
          ? Directory(p.join(root, '.dart_tool'))
          : Directory.systemTemp;
      final folder = parent.createTempSync('lvs_har_shapes_test_');
      addTearDown(() => folder.deleteSync(recursive: true));
      return folder;
    }

    /// Writes the fake capture to `capture.har` in [folder].
    File writeCapture(Directory folder) =>
        File(p.join(folder.path, 'capture.har'))
          ..writeAsStringSync(jsonEncode(har));

    /// Runs `dart run <script> <path>` in [workingDirectory].
    Future<ProcessResult> run(
      String script,
      String path, {
      required String workingDirectory,
    }) => Process.run(
      Platform.resolvedExecutable,
      ['run', script, path],
      workingDirectory: workingDirectory,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    test('knows a file inside the repository', () {
      final outside = folder(inRepository: false);
      for (final path in [
        p.join(root, 'capture.har'),
        p.join(root, 'test', '..', '.dart_tool', 'capture.har'),
        p.join('.dart_tool', 'capture.har'),
        'capture.har',
        if (Platform.isWindows) p.join(root.toUpperCase(), 'capture.har'),
      ]) {
        expect(isInsideRepository(path, root), isTrue, reason: path);
      }
      expect(
        isInsideRepository(p.join(outside.path, 'capture.har'), root),
        isFalse,
      );
      expect(
        isInsideRepository(writeCapture(outside).path, root),
        isFalse,
        reason: 'an existing file',
      );
      expect(
        isInsideRepository(p.join(root, '..', 'capture.har'), root),
        isFalse,
      );
    });

    test(
      'refuses a HAR inside the repository, and prints nothing of it',
      () async {
        final inside = writeCapture(folder(inRepository: true));
        final relative = p.relative(inside.path, from: root);
        final result = await run(
          p.join('tool', 'lvs_har_shapes.dart'),
          relative,
          workingDirectory: root,
        );
        expect(result.exitCode, 64);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('inside the repository'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('refuses it when run from another folder too', () async {
      final inside = writeCapture(folder(inRepository: true));
      final result = await run(
        script,
        inside.path,
        workingDirectory: folder(inRepository: false).path,
      );
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('inside the repository'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'prints the shapes of a HAR outside the repository, from its folder',
      () async {
        final outside = folder(inRepository: false);
        final capture = writeCapture(outside);
        final result = await run(
          script,
          p.basename(capture.path),
          workingDirectory: outside.path,
        );
        expect(result.stderr, isEmpty);
        expect(result.exitCode, 0);
        expect(result.stdout, output);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
