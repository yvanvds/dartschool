// Tests for the writes of IntradeskService (#128): createFolder,
// createWeblink, uploadFiles and the moves to the trash, and the upload step
// they share with MessagesService (SmartschoolUploader), against a fake
// Smartschool.
//
// Its answers are trimmed captures of Smartschool's own, taken live on
// 2026-10-05 in a test folder of the school's Intradesk (made-up names and
// IDs here: "Testschool", platform 49, "Jan Janssens"):
// - `POST .../folders/` and `.../weblinks/` answer `201` with the item
//   (a folder without `hasChildren`); a name that is taken is renamed to
//   `name (1)`, never refused;
// - `GET /upload/api/v1/get-upload-directory` answers `{"uploadDir"}`;
//   `POST /Upload/Upload/Index` answers `true`, or `400` with plain text
//   for a name Smartschool does not allow;
// - `POST .../files/upload` answers `201` with `files` as an object keyed by
//   file ID and `exceptions` as an empty list, and a directory without
//   files with a bare `400`;
// - an invalid URL and a confidential folder in an ordinary folder get
//   `400` with `violations`; a bad name, colour, icon or parent a bare
//   `500`;
// - `POST .../{kind}/{id}/trash` with `{}` answers `204`, also for an item
//   in the trash already.
//
// And on 2026-10-07 (#133): a move to the trash of a made-up ID, and of the
// ID of an item of another kind (a file's ID as a folder, a folder's as a
// file, ...), answers `404` with a bare
// `{"status":404,"title":"Not Found","detail":"","type":""}`
// (`application/problem+json`), and moves nothing.
//
// Since #138 the creates read the folder they add to first, and add only
// what Intradesk's web client offers there (its "Toevoegen" button and
// right-click menu, read in its bundle on 2026-10-07): the fake answers that
// read for the test folder by default, as Smartschool answered it live
// (`GET .../folders/{id}/parents`, then the listing of the folder above),
// and the root's with the Intradesk page (`GET /intradesk`), whose
// configuration carries the platform's capabilities in a `JSON.parse('...')`
// script, escaped as the live page escapes it (trimmed capture, 2026-10-07).
//
// The live test of the same writes is test/live/intradesk_write_live_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/services/smartschool_uploader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

const _api = '/intradesk/api/v1/49';
const _createFolder = 'POST $_api/folders/';
const _createConfidential = 'POST $_api/folders/as-confidential';
const _createWeblink = 'POST $_api/weblinks/';
const _uploadDirectory = 'GET /upload/api/v1/get-upload-directory';
const _upload = 'POST /Upload/Upload/Index';
const _takeFiles = 'POST $_api/files/upload';

/// The folder the writes go into ("tests").
const _parent = 'aaaa1111-1111-4111-b111-111111111111';

/// The folder above it, at the root ("2. SMA").
const _top = 'aaaa0000-0000-4000-b000-000000000000';

/// The read of [_parent] before a create (#138): its parents, then the
/// listing of the folder above it.
const _parentsOfParent = 'GET $_api/folders/$_parent/parents';
const _listingOfTop = 'GET $_api/directory-listing/forTreeOnlyFolders/$_top';
const _readParent = [_parentsOfParent, _listingOfTop];

/// The read of the root's capabilities before a create there (#138).
const _intradeskPage = 'GET /intradesk';

/// The folder, weblink and file Intradesk makes.
const _newFolder = 'ffff1111-1111-4111-b111-111111111111';
const _newWeblink = 'ffff2222-2222-4222-b222-222222222222';
const _newFile = 'ffff3333-3333-4333-b333-333333333333';
const _secondFile = 'ffff4444-4444-4444-b444-444444444444';

const _platform = '"platform":{"id":49,"name":"Testschool"}';
const _dates =
    '"dateStateChanged":"2026-10-05T20:09:03+02:00",'
    '"dateCreated":"2026-10-05T20:09:03+02:00",'
    '"dateChanged":"2026-10-05T20:09:03+02:00"';

/// Intradesk's answer to the create of a folder (trimmed capture): the
/// folder, without `hasChildren`. A folder of a listing has the same fields,
/// with `hasChildren`.
String _folder({
  String name = 'dartschool test map',
  String color = 'green',
  String parent = _parent,
  String id = _newFolder,
  bool confidential = false,
  bool canAdd = true,
}) =>
    '{"id":"$id",$_platform,"name":"$name","color":"$color",'
    '"state":"active","visible":true,"confidential":$confidential,'
    '"officeTemplateFolder":false,"parentFolderId":"$parent",$_dates,'
    '"isFavourite":false,"inConfidentialFolder":false,'
    '"capabilities":{"canManage":$canAdd,"canAdd":$canAdd,'
    '"canSeeHistory":true,"canSeeViewHistory":true}}';

/// The listing of [_top] (trimmed capture): the test folder, which the user
/// may add to ([canAdd]) and which is ordinary unless [confidential].
String _topListing({bool canAdd = true, bool confidential = false}) =>
    '{"folders":[${_folder(id: _parent, name: 'tests', parent: _top, color: 'yellow', canAdd: canAdd, confidential: confidential)}],'
    '"files":[],"weblinks":[]}';

/// [json] as the Smartschool pages hand it to their scripts in
/// `JSON.parse('...')`: a JavaScript string with every character but
/// letters, digits, `,`, `.` and `_` as `\uXXXX`, a `\` as `\\` and a `/` as
/// `\/` (as the live Intradesk page has it, 2026-10-07).
String _jsLiteral(String json) => json.runes.map((rune) {
  final char = String.fromCharCode(rune);
  if (RegExp(r'[A-Za-z0-9,._]').hasMatch(char)) return char;
  if (char == r'\') return r'\\';
  if (char == '/') return r'\/';
  return '\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}).join();

/// The Intradesk page (`GET /intradesk`, trimmed capture, 2026-10-07): the
/// configurations it hands its scripts, the platform's capabilities in the
/// one of the Intradesk module, with a translation that holds the escapes
/// of `\` and `"` (`De karakters / : * ? " \ < > |`).
String _intradeskPageWith({
  bool canAdd = true,
  bool canAddConfidentialFolder = false,
}) {
  String script(String json) =>
      '<script type="text/javascript" nonce="abc">\$.extend(true, SMSC, '
      "JSON.parse('${_jsLiteral(json)}'));</script>";
  final module = jsonEncode({
    'intradesk': {
      'module_title': 'Intradesk',
      'lng_filename_not_allowed':
          r'De karakters / : * ? " \ < > | zijn niet toegestaan.',
    },
    'vars': {
      'config': {
        'allowOtherPlatforms': true,
        'ownPlatform': {
          'id': 49,
          'name': 'Testschool',
          'capabilities': {
            'canManage': canAdd,
            'canAlterConfidentialState': false,
            'canAdd': canAdd,
            'canAddConfidentialFolder': canAddConfidentialFolder,
          },
        },
        'communities': [
          {
            'id': 3723,
            'name': 'Scholengemeenschap',
            'platforms': [
              {
                'id': 50,
                'name': 'Andere school',
                'capabilities': {
                  'canManage': false,
                  'canAlterConfidentialState': false,
                  'canAdd': false,
                  'canAddConfidentialFolder': false,
                },
              },
            ],
          },
        ],
        'daysRevisionsSaved': 30,
        'daysTrashSaved': 30,
        'userIsAdmin': true,
      },
    },
  }).replaceAll('/', r'\/');
  return '<!DOCTYPE html><html><head><title>Testschool - Smartschool</title>'
      '</head><body><div id="smscMain"></div>'
      '<script type="text/javascript" nonce="abc">var SMSC = SMSC || {};'
      '</script>'
      '${script('{"vars":{"showNotifyAlerts":true}}')}'
      "<script type=\"text/javascript\" nonce=\"abc\">\$.extend(true, SMSC, "
      "JSON.parse('null'));</script>"
      '${script(module)}'
      '${script('{"wopiConfig":{"allowCreate":true}}')}'
      '</body></html>';
}

/// Intradesk's answer to the create of a weblink (trimmed capture).
String _weblink({
  String name = 'dartschool test link',
  String url = r'https:\/\/example.com\/dartschool',
  String icon = 'earth',
  String parent = _parent,
}) =>
    '{"id":"$_newWeblink",$_platform,"name":"$name","state":"active",'
    '"url":"$url","icon":"$icon","parentFolderId":"$parent",$_dates,'
    '"isFavourite":false,"confidential":false,"ownerId":"49_1001_0",'
    '"capabilities":{"canManage":true,"canMove":true,"canSeeHistory":true,'
    '"canSeeViewHistory":true}}';

/// A file of Intradesk's answer to `files/upload` (trimmed capture).
String _file({
  String id = _newFile,
  String name = 'dartschool-test.txt',
  String parent = _parent,
  int size = 16,
}) =>
    '{"id":"$id",$_platform,"name":"$name","state":"active",'
    '"parentFolderId":"$parent",$_dates,"currentRevision":{"id":'
    '"eeee1111-1111-4111-b111-111111111111",$_platform,"fileId":"$id",'
    '"fileSize":$size,"dateCreated":"2026-10-05T20:09:04+02:00",'
    '"label":"$name","owner":{"userIdentifier":"49_1001_0",'
    '"userPictureHash":"initials_JJ","userPictureUrl":'
    r'"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage'
    r'\/hash\/initials_JJ\/plain\/1\/res\/128",'
    '"name":"Jan Janssens","nameReverse":"Janssens Jan","description":"",'
    '"descriptionReverse":""}},"isFavourite":false,"confidential":false,'
    '"ownerId":"49_1001_0","capabilities":{"canManage":true,"canMove":true,'
    '"canHandleRevisions":true,"canSeeHistory":true,'
    '"canSeeViewHistory":true}}';

/// Intradesk's answer to `files/upload`: `files` keyed by file ID.
String _uploaded(List<(String, String)> files, {String exceptions = '[]'}) =>
    '{"files":{${[for (final (id, json) in files) '"$id":$json'].join(',')}},'
    '"exceptions":$exceptions}';

/// The upload step's refusal of a name Smartschool does not allow, as it
/// answers it: HTTP 400, plain text (as `text/html`).
const _badNameText =
    'De karakters: / : * ? " \\ < > | zijn niet toegestaan in de naam van een '
    'map of bestand. Een punt voor of achter de naam van een map of bestand '
    'is ook niet toegestaan.';

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

const _homePage =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>'
    '</body></html>';

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, contentType: 'application/json');

/// Smartschool's problem answer, with [violations] when given.
_Answer _problem(int status, String title, [List<String>? violations]) => (
  status: status,
  body: jsonEncode({
    'status': status,
    'title': title,
    'detail': '',
    'type': '',
    'violations': ?violations,
  }),
  contentType: 'application/problem+json',
);

final _bareServerError = _problem(500, 'Internal Server Error');

/// An empty `204`, Intradesk's answer to a move to the trash.
const _Answer _noContent = (status: 204, body: '', contentType: '');

/// Smartschool refusing the session (#8): an empty `401`.
const _Answer _unauthorized = (status: 401, body: '', contentType: '');

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

/// A request as it reached the fake Smartschool.
typedef _Request = ({String label, Object? data});

/// A Smartschool that answers each request (`METHOD path`) with the next
/// answer of its queue in [answers] (the last one again when one is left),
/// logs in when asked to, and records what reached it. Any other request
/// fails the test.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(Map<String, List<_Answer>> answers, this.failures)
    : _answers = {
        for (final entry in answers.entries) entry.key: [...entry.value],
      };

  final Map<String, List<_Answer>> _answers;
  final Map<String, Object Function(RequestOptions options)> failures;

  bool _passwordDone = false;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The requests as `METHOD path`.
  List<String> get log => [for (final r in requests) r.label];

  /// The requests that are not part of the login and not the platform ID.
  List<String> get calls => [
    for (final label in log)
      if (label != 'GET /course-list/api/v1/courses' &&
          !label.endsWith('/login') &&
          !label.contains('/2fa') &&
          label != 'GET /')
        label,
  ];

  /// The [calls] but the reads of the test folder and of the root before a
  /// create (#138): the steps of the write.
  List<String> get writes => [
    for (final label in calls)
      if (!_readParent.contains(label) && label != _intradeskPage) label,
  ];

  /// The JSON bodies of the requests with [label].
  List<Object?> bodiesOf(String label) => [
    for (final r in requests)
      if (r.label == label) r.data,
  ];

  /// The `uploadDir` and the file name of each upload step.
  List<(String?, String?)> get uploads => [
    for (final r in requests)
      if (r.label == _upload)
        (
          (r.data! as FormData).fields
              .where((f) => f.key == 'uploadDir')
              .firstOrNull
              ?.value,
          (r.data! as FormData).files.single.value.filename,
        ),
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final label = '${options.method} ${options.uri.path}';
    requests.add((label: label, data: options.data));

    final failure = failures[label];
    if (failure != null) throw failure(options);

    switch (label) {
      case 'GET /course-list/api/v1/courses':
        return _respond(_json('[{"platformId":49}]'));
      case 'GET /login':
        return _respond((
          status: 200,
          body: _loginPage,
          contentType: 'text/html',
        ));
      case 'POST /login':
        _passwordDone = true;
        return _respond((
          status: 302,
          body: '<html><body>Redirecting to /</body></html>',
          contentType: 'text/html',
        ), location: '/');
      case 'GET /':
        if (_passwordDone) {
          return _respond((
              status: 200,
              body: '<html>2fa</html>',
              contentType: 'text/html',
            ))
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
            ];
        }
        return _respond((
          status: 200,
          body: _homePage,
          contentType: 'text/html',
        ));
      case 'GET /2fa/api/v1/config':
        return _respond(
          _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        return _respond(_json('{"success":true,"redirectTo":"/"}'));
    }

    final queue = _answers[label];
    if (queue == null || queue.isEmpty) {
      fail('Unexpected request: $label');
    }
    return _respond(queue.length > 1 ? queue.removeAt(0) : queue.single);
  }

  static ResponseBody _respond(_Answer answer, {String? location}) =>
      ResponseBody.fromString(
        answer.body,
        answer.status,
        headers: {
          if (answer.contentType.isNotEmpty)
            Headers.contentTypeHeader: [answer.contentType],
          'location': ?(location == null ? null : [location]),
        },
      );

  @override
  void close({bool force = false}) {}
}

/// Nothing was made: Intradesk refused the write.
Matcher _refused({required int status, Object? violations = anything}) => allOf(
  isNot(isA<SmartschoolIntradeskSaveUnconfirmedError>()),
  isA<SmartschoolIntradeskWriteRefusedError>()
      .having((e) => e.statusCode, 'statusCode', status)
      .having((e) => e.violations, 'violations', violations)
      .having((e) => e.message, 'message', contains('Nothing was made')),
);

/// The write went out without Intradesk confirming it.
Matcher _unconfirmed(
  Object? message, {
  Object? statusCode = anything,
  Object? cause = anything,
}) => allOf(
  isNot(isA<SmartschoolIntradeskWriteRefusedError>()),
  isA<SmartschoolIntradeskSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.cause, 'cause', cause),
);

/// A session refused for a write that is not retried.
final _notRetried = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('not retried after logging in again'),
);

void main() {
  forbidRealNetwork();

  late Directory files;

  setUp(() {
    files = Directory.systemTemp.createTempSync('intradesk_write_test_');
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// A file [name] with [content] in the temporary folder of the test.
  String file(String name, [String content = 'dartschool test\n']) {
    final path = p.join(files.path, name);
    File(path).writeAsStringSync(content);
    return path;
  }

  Future<(_Smartschool, IntradeskService)> serve(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures = const {},
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    // The read of the test folder and of the root before a create (#138),
    // as Smartschool answers them for an administrator, unless the test
    // answers them itself.
    final server = _Smartschool({
      _parentsOfParent: [_json('["$_top"]')],
      _listingOfTop: [_json(_topListing())],
      _intradeskPage: [
        (status: 200, body: _intradeskPageWith(), contentType: 'text/html'),
      ],
      ...answers,
    }, failures);
    client.dio.httpClientAdapter = server;
    return (server, IntradeskService(client));
  }

  // ---------------------------------------------------------------------------
  // createFolder
  // ---------------------------------------------------------------------------

  group('createFolder', () {
    test('sends name, colour, parent and platform to folders/ once, and '
        'returns the folder Intradesk made', () async {
      final (server, intradesk) = await serve({
        _createFolder: [_json(_folder(), status: 201)],
      });

      final folder = await intradesk.createFolder(
        parentFolderId: _parent,
        name: 'dartschool test map',
        color: 'green',
      );

      // The test folder is read first (#138): its parents, then the listing
      // of the folder above it, which holds its entry.
      expect(server.calls, [..._readParent, _createFolder]);
      expect(server.bodiesOf(_createFolder), [
        {
          'name': 'dartschool test map',
          'color': 'green',
          'parentFolderId': _parent,
          'platform': {'id': 49},
        },
      ]);
      expect(folder.id, _newFolder);
      expect(folder.name, 'dartschool test map');
      expect(folder.color, 'green');
      expect(folder.parentFolderId, _parent);
      expect(folder.confidential, isFalse);
      expect(folder.platform.id, 49);
      // The answer has no hasChildren: a new folder holds no subfolders.
      expect(folder.hasChildren, isFalse);
      expect(folder.capabilities.canAdd, isTrue);
      expect(folder.capabilities.canAddConfidentialFolder, isFalse);
    });

    test('is yellow by default', () async {
      final (server, intradesk) = await serve({
        _createFolder: [_json(_folder(color: 'yellow'), status: 201)],
      });

      await intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen');

      expect(
        (server.bodiesOf(_createFolder).single! as Map)['color'],
        'yellow',
      );
    });

    test('returns the name Intradesk gave it when the name was taken: '
        'renamed, not refused', () async {
      final (_, intradesk) = await serve({
        _createFolder: [
          _json(_folder(name: 'dartschool test map (1)'), status: 201),
        ],
      });

      final folder = await intradesk.createFolder(
        parentFolderId: _parent,
        name: 'dartschool test map',
      );

      expect(folder.name, 'dartschool test map (1)');
    });

    test('at the root, reads the root\'s capabilities (the Intradesk page, '
        '#138) and sends "" as the parent', () async {
      final (server, intradesk) = await serve({
        _createFolder: [_json(_folder(parent: ''), status: 201)],
      });

      final folder = await intradesk.createFolder(
        parentFolderId: '',
        name: 'Nieuwe map',
      );

      expect(server.calls, [_intradeskPage, _createFolder]);
      expect(
        (server.bodiesOf(_createFolder).single! as Map)['parentFolderId'],
        '',
      );
      expect(folder.parentFolderId, '');
    });

    test('a confidential folder in a confidential folder goes to '
        'folders/as-confidential (#128, #138)', () async {
      final (server, intradesk) = await serve({
        _listingOfTop: [_json(_topListing(confidential: true))],
        _createConfidential: [
          _json(_folder(name: 'dartschool vertrouwelijk'), status: 201),
        ],
      });

      final folder = await intradesk.createFolder(
        parentFolderId: _parent,
        name: 'dartschool vertrouwelijk',
        confidential: true,
      );

      expect(server.calls, [..._readParent, _createConfidential]);
      expect(server.bodiesOf(_createConfidential), [
        {
          'name': 'dartschool vertrouwelijk',
          'color': 'yellow',
          'parentFolderId': _parent,
          'platform': {'id': 49},
        },
      ]);
      expect(folder.name, 'dartschool vertrouwelijk');
    });

    test('a 4xx from folders/as-confidential is refused with Intradesk\'s '
        'reason', () async {
      // Intradesk's reason for a confidential folder in an ordinary one
      // (seen live, 2026-10-05), which the service no longer sends (#138);
      // here the read said the parent was confidential, as when it changed
      // between the read and the create.
      const reason =
          'In een gewone map kan je enkel gewone mappen toevoegen. '
          'Vertrouwelijke mappen kan je hier niet toevoegen.';
      final (server, intradesk) = await serve({
        _listingOfTop: [_json(_topListing(confidential: true))],
        _createConfidential: [
          _problem(400, 'Bad Request', [reason]),
        ],
      });

      await expectLater(
        intradesk.createFolder(
          parentFolderId: _parent,
          name: 'dartschool vertrouwelijk',
          confidential: true,
        ),
        throwsA(
          allOf(
            _refused(status: 400, violations: [reason]),
            isNot(isA<SmartschoolIntradeskAddRefusedError>()),
            isA<SmartschoolIntradeskWriteRefusedError>().having(
              (e) => e.message,
              'message',
              allOf(contains('confidential folder'), contains(reason)),
            ),
          ),
        ),
      );
      expect(server.writes, [_createConfidential]);
    });

    test('refuses, before sending anything, an empty name, a name '
        'Smartschool does not allow, a colour Intradesk does not have and a '
        'parent that is not a folder UUID', () async {
      final (server, intradesk) = await serve({});

      for (final (name, color, parent) in [
        ('', 'yellow', _parent),
        ('   ', 'yellow', _parent),
        ('dartschool a/b', 'yellow', _parent),
        ('a:b', 'yellow', _parent),
        ('.verborgen', 'yellow', _parent),
        ('map.', 'yellow', _parent),
        ('dartschool kleur', 'mauve', _parent),
        ('dartschool kleur', '', _parent),
        ('dartschool ouder', 'yellow', 'root'),
        ('dartschool ouder', 'yellow', '$_parent/../x'),
      ]) {
        await expectLater(
          intradesk.createFolder(
            parentFolderId: parent,
            name: name,
            color: color,
          ),
          throwsA(isA<ArgumentError>()),
          reason: '($name, $color, $parent)',
        );
      }
      expect(server.log, isEmpty);
    });

    test('a parent Smartschool knows no folder for: the read of the parent '
        '(#138) finds none (its parents answer 404), a '
        'SmartschoolIntradeskFolderNotFoundError before the create is '
        'sent', () async {
      const unknown = '00000000-0000-4000-8000-000000000000';
      final (server, intradesk) = await serve({
        'GET $_api/folders/$unknown/parents': [_problem(404, 'Not Found')],
      });

      await expectLater(
        intradesk.createFolder(
          parentFolderId: unknown,
          name: 'dartschool onbekende ouder',
        ),
        throwsA(
          isA<SmartschoolIntradeskFolderNotFoundError>()
              .having((e) => e.folderId, 'folderId', unknown)
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  startsWith(
                    'createFolder: the folder to add to was not '
                    'found.',
                  ),
                  endsWith('Nothing was sent.'),
                ),
              ),
        ),
      );
      expect(server.calls, ['GET $_api/folders/$unknown/parents']);
    });

    test('a parent gone after its read: the bare 500 is told apart with the '
        'parents of the parent (#37), as a '
        'SmartschoolIntradeskFolderNotFoundError', () async {
      final (server, intradesk) = await serve({
        _parentsOfParent: [_json('["$_top"]'), _problem(404, 'Not Found')],
        _createFolder: [_bareServerError],
      });

      await expectLater(
        intradesk.createFolder(
          parentFolderId: _parent,
          name: 'dartschool weggehaalde ouder',
        ),
        throwsA(
          isA<SmartschoolIntradeskFolderNotFoundError>()
              .having((e) => e.folderId, 'folderId', _parent)
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
      expect(server.calls, [..._readParent, _createFolder, _parentsOfParent]);
    });

    test('a bare 500 for a parent that is a folder is not taken for nothing '
        'made: unconfirmed', () async {
      final (server, intradesk) = await serve({
        _createFolder: [_bareServerError],
      });

      await expectLater(
        intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
        throwsA(
          _unconfirmed(
            allOf(contains('HTTP 500'), contains('may or may not')),
            statusCode: 500,
            cause: isNull,
          ),
        ),
      );
      expect(server.calls, [..._readParent, _createFolder, _parentsOfParent]);
    });

    test('an answer that is not the folder made is unconfirmed', () async {
      for (final answer in [
        _json('<html>fout</html>', status: 201),
        _json('[]', status: 201),
        _json('{"id":"$_newFolder","name":"x"}', status: 201),
        _json(_folder(id: ''), status: 201),
        _json(_folder(parent: _newWeblink), status: 201),
        _json(_folder(), status: 302),
      ]) {
        final (server, intradesk) = await serve({
          _createFolder: [answer],
        });

        await expectLater(
          intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
          throwsA(_unconfirmed(anything)),
          reason: answer.body,
        );
        expect(server.writes, [_createFolder]);
      }
    });

    test('the connection dropping after the create went out: unconfirmed, '
        'with the cause, sent once', () async {
      final (server, intradesk) = await serve(
        {},
        failures: {_createFolder: _dropped},
      );

      await expectLater(
        intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
        throwsA(
          _unconfirmed(
            contains('no answer came in'),
            statusCode: isNull,
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.writes, [_createFolder]);
    });

    test('a session refused for the create is not retried after logging in '
        'again: no login, no second create', () async {
      final (server, intradesk) = await serve({
        _createFolder: [_unauthorized, _json(_folder(), status: 201)],
      });

      await expectLater(
        intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
        throwsA(_notRetried),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.writes, [_createFolder]);
    });
  });

  // ---------------------------------------------------------------------------
  // createWeblink
  // ---------------------------------------------------------------------------

  group('createWeblink', () {
    test('sends name, address, icon, parent and platform to weblinks/ once, '
        'and returns the weblink Intradesk made', () async {
      final (server, intradesk) = await serve({
        _createWeblink: [_json(_weblink(), status: 201)],
      });

      final link = await intradesk.createWeblink(
        parentFolderId: _parent,
        name: 'dartschool test link',
        url: 'https://example.com/dartschool',
      );

      expect(server.calls, [..._readParent, _createWeblink]);
      expect(server.bodiesOf(_createWeblink), [
        {
          'name': 'dartschool test link',
          'url': 'https://example.com/dartschool',
          'icon': 'earth',
          'parentFolderId': _parent,
          'platform': {'id': 49},
        },
      ]);
      expect(link.id, _newWeblink);
      expect(link.name, 'dartschool test link');
      expect(link.url, 'https://example.com/dartschool');
      expect(link.icon, 'earth');
      expect(link.parentFolderId, _parent);
      expect(link.ownerId, '49_1001_0');
    });

    test('sends the address as the web client does: without white space, '
        'with http:// when it has no scheme', () async {
      final (server, intradesk) = await serve({
        _createWeblink: [
          _json(_weblink(url: r'http:\/\/example.com\/y'), status: 201),
        ],
      });

      final link = await intradesk.createWeblink(
        parentFolderId: _parent,
        name: 'dartschool zonder schema',
        url: ' example.com/ y ',
        icon: 'bestaatniet',
      );

      final body = server.bodiesOf(_createWeblink).single! as Map;
      expect(body['url'], 'http://example.com/y');
      expect(body['icon'], 'bestaatniet');
      expect(link.url, 'http://example.com/y');
    });

    test(
      'returns the name Intradesk gave it when the name was taken',
      () async {
        final (_, intradesk) = await serve({
          _createWeblink: [
            _json(_weblink(name: 'dartschool test link (1)'), status: 201),
          ],
        });

        final link = await intradesk.createWeblink(
          parentFolderId: _parent,
          name: 'dartschool test link',
          url: 'https://example.com/other',
        );

        expect(link.name, 'dartschool test link (1)');
      },
    );

    test(
      'an address Intradesk refuses after all: refused with its reason',
      () async {
        const reason = 'De URL die je hebt ingegeven is niet geldig.';
        final (server, intradesk) = await serve({
          _createWeblink: [
            _problem(400, 'Bad Request', [reason]),
          ],
        });

        await expectLater(
          intradesk.createWeblink(
            parentFolderId: _parent,
            name: 'dartschool link',
            url: 'https://example.com/x',
          ),
          throwsA(_refused(status: 400, violations: [reason])),
        );
        expect(server.writes, [_createWeblink]);
      },
    );

    test('refuses, before sending anything, a weblink at the root, a bad '
        'name, an address that is not one, and an empty icon', () async {
      final (server, intradesk) = await serve({});

      for (final (parent, name, url, icon) in [
        ('', 'dartschool link', 'https://example.com', 'earth'),
        (_parent, '', 'https://example.com', 'earth'),
        (_parent, 'dartschool a/b', 'https://example.com', 'earth'),
        (_parent, 'dartschool link', 'geen url', 'earth'),
        (_parent, 'dartschool link', '', 'earth'),
        (_parent, 'dartschool link', 'https://localhost', 'earth'),
        (_parent, 'dartschool link', 'https://example.com', ' '),
      ]) {
        await expectLater(
          intradesk.createWeblink(
            parentFolderId: parent,
            name: name,
            url: url,
            icon: icon,
          ),
          throwsA(isA<ArgumentError>()),
          reason: '($parent, $name, $url, $icon)',
        );
      }
      expect(server.log, isEmpty);
    });

    test('a parent Smartschool knows no folder for: found out by the read '
        'of the parent (#138), before the create is sent', () async {
      const unknown = '00000000-0000-4000-8000-000000000000';
      final (server, intradesk) = await serve({
        'GET $_api/folders/$unknown/parents': [_problem(404, 'Not Found')],
      });

      await expectLater(
        intradesk.createWeblink(
          parentFolderId: unknown,
          name: 'dartschool link',
          url: 'https://example.com',
        ),
        throwsA(
          isA<SmartschoolIntradeskFolderNotFoundError>()
              .having((e) => e.folderId, 'folderId', unknown)
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
      expect(server.calls, ['GET $_api/folders/$unknown/parents']);
    });

    test('a session refused for the create is not retried', () async {
      final (server, intradesk) = await serve({
        _createWeblink: [_unauthorized, _json(_weblink(), status: 201)],
      });

      await expectLater(
        intradesk.createWeblink(
          parentFolderId: _parent,
          name: 'dartschool link',
          url: 'https://example.com',
        ),
        throwsA(_notRetried),
      );
      expect(server.writes, [_createWeblink]);
    });
  });

  // ---------------------------------------------------------------------------
  // uploadFiles
  // ---------------------------------------------------------------------------

  group('uploadFiles', () {
    test('asks for a new upload directory, uploads each file into it, then '
        'has Intradesk take the directory into the folder once, and returns '
        'the files of the answer (an object keyed by file ID)', () async {
      final (server, intradesk) = await serve({
        _uploadDirectory: [
          _json('{"uploadDir":"a1004143bdd73ab44414d20918b3dd"}'),
        ],
        _upload: [_json('true')],
        _takeFiles: [
          _json(
            _uploaded([
              (_newFile, _file()),
              (_secondFile, _file(id: _secondFile, name: 'toets #1.pdf')),
            ]),
            status: 201,
          ),
        ],
      });
      final first = file('dartschool-test.txt');
      final second = file('toets #1.pdf', 'pdf');

      final result = await intradesk.uploadFiles(
        parentFolderId: _parent,
        filePaths: [first, second],
      );

      // The test folder is read before the upload steps (#138).
      expect(server.calls, [
        ..._readParent,
        _uploadDirectory,
        _upload,
        _upload,
        _takeFiles,
      ]);
      expect(server.uploads, [
        ('a1004143bdd73ab44414d20918b3dd', 'dartschool-test.txt'),
        ('a1004143bdd73ab44414d20918b3dd', 'toets #1.pdf'),
      ]);
      expect(server.bodiesOf(_takeFiles), [
        {
          'parentFolderId': _parent,
          'uploadDir': 'a1004143bdd73ab44414d20918b3dd',
        },
      ]);
      expect(result.files.map((f) => f.id), [_newFile, _secondFile]);
      expect(result.files.map((f) => f.name), [
        'dartschool-test.txt',
        'toets #1.pdf',
      ]);
      expect(result.files.first.parentFolderId, _parent);
      expect(result.files.first.currentRevision!.fileSize, 16);
      expect(result.files.first.currentRevision!.owner.name, 'Jan Janssens');
      expect(result.failures, isEmpty);
      expect(result.toString(), contains('files: 2'));
    });

    test('every call gets a new upload directory: Intradesk takes the files '
        'of a directory again every time it is told to', () async {
      final (server, intradesk) = await serve({
        _uploadDirectory: [
          _json('{"uploadDir":"dir1"}'),
          _json('{"uploadDir":"dir2"}'),
        ],
        _upload: [_json('true')],
        _takeFiles: [
          _json(_uploaded([(_newFile, _file())]), status: 201),
          _json(
            _uploaded([
              (
                _secondFile,
                _file(id: _secondFile, name: 'dartschool-test (1).txt'),
              ),
            ]),
            status: 201,
          ),
        ],
      });
      final path = file('dartschool-test.txt');

      await intradesk.uploadFiles(parentFolderId: _parent, filePaths: [path]);
      final again = await intradesk.uploadFiles(
        parentFolderId: _parent,
        filePaths: [path],
      );

      expect(server.uploads.map((u) => u.$1), ['dir1', 'dir2']);
      expect(server.bodiesOf(_takeFiles).map((b) => (b! as Map)['uploadDir']), [
        'dir1',
        'dir2',
      ]);
      // The name was taken by the first upload: renamed, not refused.
      expect(again.files.single.name, 'dartschool-test (1).txt');
    });

    test('a file Intradesk did not take is a failure of the result, with its '
        'reason (as the web client reads the exceptions)', () async {
      final (_, intradesk) = await serve({
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_json('true')],
        _takeFiles: [
          _json(
            _uploaded(
              [(_newFile, _file())],
              exceptions:
                  '{"te groot.pdf":{"violations":{"file":"Het bestand is te '
                  'groot."}}}',
            ),
            status: 201,
          ),
        ],
      });

      final result = await intradesk.uploadFiles(
        parentFolderId: _parent,
        filePaths: [file('dartschool-test.txt'), file('te groot.pdf')],
      );

      expect(result.files.single.id, _newFile);
      expect(result.failures.single.key, 'te groot.pdf');
      expect(result.failures.single.message, 'Het bestand is te groot.');
      expect(result.failures.single.violations, ['Het bestand is te groot.']);
    });

    test(
      'a name the upload step refuses: a SmartschoolAttachmentUploadError '
      'with Smartschool\'s words; Intradesk is not told to take the files',
      () async {
        final (server, intradesk) = await serve({
          _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
          _upload: [
            (
              status: 400,
              body: _badNameText,
              contentType: 'text/html; charset=UTF-8',
            ),
          ],
        });

        await expectLater(
          intradesk.uploadFiles(
            parentFolderId: _parent,
            filePaths: [file('dartschool-test.txt')],
          ),
          throwsA(
            isA<SmartschoolAttachmentUploadError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.fileName, 'fileName', 'dartschool-test.txt')
                .having((e) => e.serverMessage, 'serverMessage', _badNameText)
                .having((e) => e.message, 'message', contains(_badNameText)),
          ),
        );
        expect(server.writes, [_uploadDirectory, _upload]);
      },
    );

    test('no upload directory: a SmartschoolAttachmentUploadError before '
        'any upload', () async {
      for (final answer in [
        _json('{}'),
        _json('{"uploadDir":""}'),
        _json('<html></html>'),
        _problem(500, 'Internal Server Error'),
      ]) {
        final (server, intradesk) = await serve({
          _uploadDirectory: [answer],
        });

        await expectLater(
          intradesk.uploadFiles(
            parentFolderId: _parent,
            filePaths: [file('dartschool-test.txt')],
          ),
          throwsA(isA<SmartschoolAttachmentUploadError>()),
          reason: answer.body,
        );
        expect(server.writes, [_uploadDirectory], reason: answer.body);
      }
    });

    test('Intradesk refusing to take the directory (a bare 400, as for a '
        'directory without files) is refused, nothing made', () async {
      final (server, intradesk) = await serve({
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_json('true')],
        _takeFiles: [_problem(400, 'Bad Request')],
      });

      await expectLater(
        intradesk.uploadFiles(
          parentFolderId: _parent,
          filePaths: [file('dartschool-test.txt')],
        ),
        throwsA(_refused(status: 400, violations: isEmpty)),
      );
      expect(server.writes, [_uploadDirectory, _upload, _takeFiles]);
    });

    test('taking the files is not retried after a session refused for it, '
        'though the upload steps before it are', () async {
      final (server, intradesk) = await serve({
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_json('true')],
        _takeFiles: [
          _unauthorized,
          _json(_uploaded([(_newFile, _file())]), status: 201),
        ],
      });

      await expectLater(
        intradesk.uploadFiles(
          parentFolderId: _parent,
          filePaths: [file('dartschool-test.txt')],
        ),
        throwsA(_notRetried),
      );
      expect(server.writes, [_uploadDirectory, _upload, _takeFiles]);
    });

    test('the upload step is retried once after logging in again: the '
        'directory is not bound to the session', () async {
      final (server, intradesk) = await serve({
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_unauthorized, _json('true')],
        _takeFiles: [
          _json(_uploaded([(_newFile, _file())]), status: 201),
        ],
      });

      final result = await intradesk.uploadFiles(
        parentFolderId: _parent,
        filePaths: [file('dartschool-test.txt')],
      );

      expect(result.files.single.id, _newFile);
      expect(server.log, contains('POST /login'));
      expect(server.writes, [_uploadDirectory, _upload, _upload, _takeFiles]);
      expect(server.uploads.map((u) => u.$1), ['dir1', 'dir1']);
    });

    test('an answer without its files, or with a file in another folder, '
        'is unconfirmed', () async {
      for (final answer in [
        _json('{"exceptions":[]}', status: 201),
        _json('{"files":"x","exceptions":[]}', status: 201),
        _json(_uploaded([(_newFile, _file(parent: _newFolder))]), status: 201),
      ]) {
        final (_, intradesk) = await serve({
          _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
          _upload: [_json('true')],
          _takeFiles: [answer],
        });

        await expectLater(
          intradesk.uploadFiles(
            parentFolderId: _parent,
            filePaths: [file('dartschool-test.txt')],
          ),
          throwsA(_unconfirmed(anything)),
          reason: answer.body,
        );
      }
    });

    test('refuses, before sending anything, no files, a file that does not '
        'exist, a name Smartschool does not allow, two files with one name, '
        'and an upload at the root', () async {
      final (server, intradesk) = await serve({});
      final ok = file('dartschool-test.txt');
      final other = Directory(p.join(files.path, 'other'))..createSync();
      final sameName = p.join(other.path, 'dartschool-test.txt');
      File(sameName).writeAsStringSync('x');

      for (final (parent, paths) in [
        (_parent, <String>[]),
        (_parent, [p.join(files.path, 'bestaat-niet.txt')]),
        (_parent, [file('.verborgen.txt')]),
        (_parent, [file('notes..txt')]),
        (_parent, [ok, sameName]),
        ('', [ok]),
        ('niet-een-uuid', [ok]),
      ]) {
        await expectLater(
          intradesk.uploadFiles(parentFolderId: parent, filePaths: paths),
          throwsA(isA<ArgumentError>()),
          reason: '($parent, $paths)',
        );
      }
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // The check of the parent folder (#138)
  // ---------------------------------------------------------------------------

  group('the creates check the folder they add to first (#138)', () {
    /// The service refused the write itself, after reading the parent:
    /// nothing was sent.
    Matcher addRefused(
      IntradeskAddRefusalReason reason, {
      String parentFolderId = _parent,
      Object? parent = anything,
      Object? message = anything,
    }) => allOf(
      isNot(isA<SmartschoolIntradeskSaveUnconfirmedError>()),
      // A refusal of the write, as Intradesk's 400 for a confidential
      // folder in an ordinary one was before: existing catches catch it.
      isA<SmartschoolIntradeskWriteRefusedError>()
          .having((e) => e.statusCode, 'statusCode', isNull)
          .having((e) => e.violations, 'violations', isEmpty),
      isA<SmartschoolIntradeskAddRefusedError>()
          .having((e) => e.reason, 'reason', reason)
          .having((e) => e.parentFolderId, 'parentFolderId', parentFolderId)
          .having((e) => e.parent, 'parent', parent)
          .having((e) => e.message, 'message', message)
          .having((e) => e.message, 'message', endsWith('Nothing was sent.'))
          .having((e) => '$e', 'toString', contains('(${reason.name})')),
    );

    final isTheTestFolder = isA<IntradeskFolder>()
        .having((f) => f.id, 'id', _parent)
        .having((f) => f.name, 'name', 'tests');

    test('a folder the user may not add to (canAdd false): no folder, '
        'weblink or file, refused before anything of the write is sent '
        '(also no upload step)', () async {
      final (server, intradesk) = await serve({
        _listingOfTop: [_json(_topListing(canAdd: false))],
      });
      final path = file('dartschool-test.txt');

      for (final (what, write) in [
        (
          'folder',
          () =>
              intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
        ),
        (
          'confidential folder',
          () => intradesk.createFolder(
            parentFolderId: _parent,
            name: 'Toetsen',
            confidential: true,
          ),
        ),
        (
          'weblink',
          () => intradesk.createWeblink(
            parentFolderId: _parent,
            name: 'Oefenplatform',
            url: 'https://example.com',
          ),
        ),
        (
          'file',
          () =>
              intradesk.uploadFiles(parentFolderId: _parent, filePaths: [path]),
        ),
      ]) {
        await expectLater(
          write(),
          throwsA(
            allOf(
              addRefused(
                IntradeskAddRefusalReason.cannotAdd,
                parent: isTheTestFolder,
                message: allOf(
                  contains('may not add to folder $_parent ("tests")'),
                  contains('canAdd is false'),
                ),
              ),
              isA<SmartschoolIntradeskAddRefusedError>().having(
                (e) => e.capabilities.canAdd,
                'capabilities.canAdd',
                isFalse,
              ),
            ),
          ),
          reason: what,
        );
      }
      // Only the reads of the parent, one per write.
      expect(server.calls, [for (var i = 0; i < 4; i++) ..._readParent]);
    });

    test('a confidential folder in an ordinary folder, which Intradesk '
        'refuses with HTTP 400 (seen live), is not sent', () async {
      final (server, intradesk) = await serve({});

      await expectLater(
        intradesk.createFolder(
          parentFolderId: _parent,
          name: 'dartschool vertrouwelijk',
          confidential: true,
        ),
        throwsA(
          addRefused(
            IntradeskAddRefusalReason.ordinaryParent,
            parent: isTheTestFolder.having(
              (f) => f.confidential,
              'confidential',
              isFalse,
            ),
            message: allOf(
              startsWith(
                'createFolder: folder $_parent ("tests") is an '
                'ordinary folder',
              ),
              contains('HTTP 400'),
            ),
          ),
        ),
      );
      expect(server.calls, _readParent);
    });

    test('an ordinary folder in a confidential folder is not sent; a '
        'weblink and a file are (the web client offers them there)', () async {
      final (server, intradesk) = await serve({
        _listingOfTop: [_json(_topListing(confidential: true))],
        _createWeblink: [_json(_weblink(), status: 201)],
        _uploadDirectory: [_json('{"uploadDir":"dir1"}')],
        _upload: [_json('true')],
        _takeFiles: [
          _json(_uploaded([(_newFile, _file())]), status: 201),
        ],
      });

      await expectLater(
        intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
        throwsA(
          addRefused(
            IntradeskAddRefusalReason.confidentialParent,
            parent: isTheTestFolder.having(
              (f) => f.confidential,
              'confidential',
              isTrue,
            ),
            message: allOf(
              contains('is a confidential folder'),
              contains('confidential: true'),
            ),
          ),
        ),
      );
      expect(server.calls, _readParent);

      await intradesk.createWeblink(
        parentFolderId: _parent,
        name: 'dartschool test link',
        url: 'https://example.com/dartschool',
      );
      await intradesk.uploadFiles(
        parentFolderId: _parent,
        filePaths: [file('dartschool-test.txt')],
      );
      expect(server.writes, [
        _createWeblink,
        _uploadDirectory,
        _upload,
        _takeFiles,
      ]);
    });

    test('at the root, a folder needs the platform\'s canAdd and a '
        'confidential folder its canAddConfidentialFolder, from the '
        'Intradesk page', () async {
      final (server, intradesk) = await serve({
        _intradeskPage: [
          (
            status: 200,
            body: _intradeskPageWith(canAdd: false),
            contentType: 'text/html',
          ),
        ],
      });

      await expectLater(
        intradesk.createFolder(parentFolderId: '', name: 'Nieuwe map'),
        throwsA(
          allOf(
            addRefused(
              IntradeskAddRefusalReason.cannotAdd,
              parentFolderId: '',
              parent: isNull,
              message: contains('may not add to the root'),
            ),
            isA<SmartschoolIntradeskAddRefusedError>().having(
              (e) => e.capabilities.canAdd,
              'capabilities.canAdd',
              isFalse,
            ),
          ),
        ),
      );
      await expectLater(
        intradesk.createFolder(
          parentFolderId: '',
          name: 'Nieuwe map',
          confidential: true,
        ),
        throwsA(
          addRefused(
            IntradeskAddRefusalReason.cannotAddConfidentialFolder,
            parentFolderId: '',
            parent: isNull,
            message: contains('canAddConfidentialFolder is false'),
          ),
        ),
      );
      expect(server.calls, [_intradeskPage, _intradeskPage]);
    });

    test('at the root, a confidential folder goes out with the platform\'s '
        'canAddConfidentialFolder (the web client\'s right-click menu offers '
        'it on that alone), an ordinary one with its canAdd', () async {
      final (server, intradesk) = await serve({
        _intradeskPage: [
          (
            status: 200,
            body: _intradeskPageWith(
              canAdd: false,
              canAddConfidentialFolder: true,
            ),
            contentType: 'text/html',
          ),
          (status: 200, body: _intradeskPageWith(), contentType: 'text/html'),
        ],
        _createConfidential: [_json(_folder(parent: ''), status: 201)],
        _createFolder: [_json(_folder(parent: ''), status: 201)],
      });

      await intradesk.createFolder(
        parentFolderId: '',
        name: 'Vertrouwelijk',
        confidential: true,
      );
      await intradesk.createFolder(parentFolderId: '', name: 'Nieuwe map');

      expect(server.calls, [
        _intradeskPage,
        _createConfidential,
        _intradeskPage,
        _createFolder,
      ]);
    });

    test(
      'a parent in Intradesk\'s trash (its parents answer [], and the root '
      'listing does not hold it, as seen live): a '
      'SmartschoolIntradeskFolderNotFoundError (200), nothing sent',
      () async {
        final (server, intradesk) = await serve({
          _parentsOfParent: [_json('[]')],
          'GET $_api/directory-listing/forTreeOnlyFolders': [
            _json('{"folders":[],"files":[],"weblinks":[]}'),
          ],
        });

        for (final write in [
          () =>
              intradesk.createFolder(parentFolderId: _parent, name: 'Toetsen'),
          () => intradesk.createWeblink(
            parentFolderId: _parent,
            name: 'Oefenplatform',
            url: 'https://example.com',
          ),
          () => intradesk.uploadFiles(
            parentFolderId: _parent,
            filePaths: [file('dartschool-test.txt')],
          ),
        ]) {
          await expectLater(
            write(),
            throwsA(
              isA<SmartschoolIntradeskFolderNotFoundError>()
                  .having((e) => e.folderId, 'folderId', _parent)
                  .having((e) => e.statusCode, 'statusCode', 200)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(contains('trash'), endsWith('Nothing was sent.')),
                  ),
            ),
          );
        }
        // Only the reads of the parent, one per write.
        expect(server.calls, [
          for (var i = 0; i < 3; i++) ...[
            _parentsOfParent,
            'GET $_api/directory-listing/forTreeOnlyFolders',
          ],
        ]);
      },
    );

    test('a read of the parent that fails is thrown as the read throws it, '
        'and nothing of the write is sent', () async {
      final (server, intradesk) = await serve({
        _listingOfTop: [_bareServerError],
        'GET $_api/folders/$_top/parents': [_json('[]')],
        _intradeskPage: [
          (
            status: 503,
            body: '<html>Onderhoud</html>',
            contentType: 'text/html',
          ),
          (
            status: 200,
            body: '<html>Smartschool</html>',
            contentType: 'text/html',
          ),
        ],
      });

      await expectLater(
        intradesk.createWeblink(
          parentFolderId: _parent,
          name: 'Oefenplatform',
          url: 'https://example.com',
        ),
        throwsA(
          allOf(
            isA<SmartschoolDownloadError>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
            isNot(isA<SmartschoolIntradeskFolderNotFoundError>()),
          ),
        ),
      );
      await expectLater(
        intradesk.createFolder(parentFolderId: '', name: 'Nieuwe map'),
        throwsA(
          isA<SmartschoolDownloadError>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      await expectLater(
        intradesk.createFolder(parentFolderId: '', name: 'Nieuwe map'),
        throwsA(isA<SmartschoolParsingError>()),
      );
      expect(
        server.calls.where(
          (c) => c.startsWith('POST') || c == _uploadDirectory,
        ),
        isEmpty,
      );
    });

    test('getRootCapabilities reads the platform\'s capabilities from the '
        'Intradesk page, in one request', () async {
      final (server, intradesk) = await serve({
        _intradeskPage: [
          (
            status: 200,
            body: _intradeskPageWith(canAddConfidentialFolder: true),
            contentType: 'text/html',
          ),
        ],
      });

      final capabilities = await intradesk.getRootCapabilities();

      expect(capabilities.canAdd, isTrue);
      expect(capabilities.canManage, isTrue);
      expect(capabilities.canAddConfidentialFolder, isTrue);
      expect(server.calls, [_intradeskPage]);
    });

    test(
      'parseRootCapabilities takes ownPlatform.capabilities, not those of '
      'another platform of the community, and undoes the page\'s escapes',
      () {
        final none = IntradeskService.parseRootCapabilities(
          _intradeskPageWith(canAdd: false),
        );
        expect(none.canAdd, isFalse);
        expect(none.canManage, isFalse);
        expect(none.canAddConfidentialFolder, isFalse);
        // The configuration holds a translation with the JSON escapes of a
        // `/`, a `"` and a `\`, escaped once more for the JavaScript string,
        // as on the live page (2026-10-07). It was read above, so they were
        // undone.
        final page = _intradeskPageWith(canAdd: false);
        expect(page, contains(r'\\\/'));
        expect(
          page,
          contains(
            r'\\\'
            'u0022',
          ),
        );
        expect(page, contains(r'\\\\'));
      },
    );

    test('parseRootCapabilities refuses a page without them', () {
      for (final html in [
        '',
        '<html><body>Smartschool</body></html>',
        "<script>\$.extend(true, SMSC, JSON.parse('null'));</script>",
        "<script>\$.extend(true, SMSC, JSON.parse('${_jsLiteral('{"vars":{"config":{"ownPlatform":{"id":49}}}}')}'));</script>",
        "<script>\$.extend(true, SMSC, JSON.parse('{\"vars\": broken'));</script>",
      ]) {
        expect(
          () => IntradeskService.parseRootCapabilities(html),
          throwsA(isA<SmartschoolParsingError>()),
          reason: html,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The moves to the trash
  // ---------------------------------------------------------------------------

  group('the moves to the trash', () {
    test('trashFolder, trashWeblink and trashFile send {} to '
        '{kind}/{id}/trash; Intradesk answers 204', () async {
      final (server, intradesk) = await serve({
        'POST $_api/folders/$_newFolder/trash': [_noContent],
        'POST $_api/weblinks/$_newWeblink/trash': [_noContent],
        'POST $_api/files/$_newFile/trash': [_noContent],
      });

      await intradesk.trashFile(_newFile);
      await intradesk.trashWeblink(_newWeblink);
      await intradesk.trashFolder(_newFolder);

      expect(server.writes, [
        'POST $_api/files/$_newFile/trash',
        'POST $_api/weblinks/$_newWeblink/trash',
        'POST $_api/folders/$_newFolder/trash',
      ]);
      for (final label in server.writes) {
        expect(server.bodiesOf(label), [<String, Object?>{}]);
      }
    });

    test(
      'a move to the trash is retried once after logging in again: '
      'Intradesk answers it for an item in the trash already with 204 too',
      () async {
        final (server, intradesk) = await serve({
          'POST $_api/files/$_newFile/trash': [_unauthorized, _noContent],
        });

        await intradesk.trashFile(_newFile);

        expect(server.log, contains('POST /login'));
        expect(server.writes, [
          'POST $_api/files/$_newFile/trash',
          'POST $_api/files/$_newFile/trash',
        ]);
      },
    );

    test(
      'a 404 (Intradesk has no item of that kind with that ID: a made-up ID, '
      'or the ID of another kind) is a SmartschoolIntradeskItemNotFoundError '
      'with the kind and the ID, sent once, and a refusal (#133)',
      () async {
        // As Intradesk answered all of them live (2026-10-07).
        final notFound = _problem(404, 'Not Found');
        final (server, intradesk) = await serve({
          'POST $_api/folders/$_newFile/trash': [notFound],
          'POST $_api/weblinks/$_newFolder/trash': [notFound],
          'POST $_api/files/$_newWeblink/trash': [notFound],
        });

        Matcher notFoundAs(IntradeskItemKind kind, String id, String others) =>
            allOf(
              isNot(isA<SmartschoolIntradeskSaveUnconfirmedError>()),
              isNot(isA<SmartschoolDownloadError>()),
              isA<SmartschoolIntradeskWriteRefusedError>()
                  .having((e) => e.statusCode, 'statusCode', 404)
                  .having((e) => e.violations, 'violations', isEmpty),
              isA<SmartschoolIntradeskItemNotFoundError>()
                  .having((e) => e.kind, 'kind', kind)
                  .having((e) => e.id, 'id', id)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains('no ${kind.name} with ID "$id" (HTTP 404)'),
                      contains('the ID of a $others'),
                      contains('Nothing was moved to the trash'),
                    ),
                  ),
            );

        await expectLater(
          intradesk.trashFolder(_newFile),
          throwsA(
            notFoundAs(IntradeskItemKind.folder, _newFile, 'weblink or a file'),
          ),
        );
        await expectLater(
          intradesk.trashWeblink(_newFolder),
          throwsA(
            notFoundAs(
              IntradeskItemKind.weblink,
              _newFolder,
              'folder or a file',
            ),
          ),
        );
        await expectLater(
          intradesk.trashFile(_newWeblink),
          throwsA(
            notFoundAs(
              IntradeskItemKind.file,
              _newWeblink,
              'folder or a weblink',
            ),
          ),
        );
        // Each sent once: a 404 is not retried, and nothing else is asked.
        expect(server.writes, [
          'POST $_api/folders/$_newFile/trash',
          'POST $_api/weblinks/$_newFolder/trash',
          'POST $_api/files/$_newWeblink/trash',
        ]);
      },
    );

    test('IntradeskItemKind names the paths of the kinds', () {
      expect(IntradeskItemKind.values.map((k) => k.pathSegment), [
        'folders',
        'weblinks',
        'files',
      ]);
    });

    test('another 4xx answer is refused, another one unconfirmed', () async {
      final (_, intradesk) = await serve({
        'POST $_api/files/$_newFile/trash': [
          _problem(403, 'Forbidden'),
          _bareServerError,
        ],
      });

      await expectLater(
        intradesk.trashFile(_newFile),
        throwsA(
          allOf(
            _refused(status: 403, violations: isEmpty),
            isNot(isA<SmartschoolIntradeskItemNotFoundError>()),
          ),
        ),
      );
      await expectLater(
        intradesk.trashFile(_newFile),
        throwsA(
          _unconfirmed(
            allOf(contains('HTTP 500'), contains('moving it to the trash')),
            statusCode: 500,
          ),
        ),
      );
    });

    test('refuses an ID that is not a UUID before sending anything', () async {
      final (server, intradesk) = await serve({});

      for (final id in ['', 'abc', '$_newFile/../x']) {
        await expectLater(
          intradesk.trashFile(id),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          intradesk.trashFolder(id),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          intradesk.trashWeblink(id),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(server.log, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  group('isAllowedName follows the web client (nameCharsAreAllowed)', () {
    test('allows ordinary names, # included', () {
      for (final name in [
        'dartschool test map',
        'dartschool-test.txt',
        'toets #1.pdf',
        'Les 1 - intro (v2).docx',
        'a.b.c',
        '',
      ]) {
        expect(IntradeskService.isAllowedName(name), isTrue, reason: name);
      }
    });

    test('refuses / : * ? " \\ < > |, and a dot at the start or end, also '
        'before the extension', () {
      for (final name in [
        'a/b',
        'a:b',
        'a*b',
        'a?b',
        'a"b',
        r'a\b',
        'a<b',
        'a>b',
        'a|b',
        '.dartschool-punt.txt',
        'map.',
        'notes..txt',
      ]) {
        expect(IntradeskService.isAllowedName(name), isFalse, reason: name);
      }
    });
  });

  group('normalizeWeblinkUrl follows the web client', () {
    test('removes white space and adds http:// without a scheme', () {
      expect(
        IntradeskService.normalizeWeblinkUrl('https://example.com/dartschool'),
        'https://example.com/dartschool',
      );
      expect(
        IntradeskService.normalizeWeblinkUrl('HTTPS://Example.com'),
        'HTTPS://Example.com',
      );
      expect(
        IntradeskService.normalizeWeblinkUrl('example.com/y'),
        'http://example.com/y',
      );
      expect(
        IntradeskService.normalizeWeblinkUrl(' www.example.be/a b\n'),
        'http://www.example.be/ab',
      );
    });

    test('refuses what is not a web address', () {
      for (final url in ['', '   ', 'geen url', 'https://localhost', 'x']) {
        expect(IntradeskService.normalizeWeblinkUrl(url), isNull, reason: url);
      }
    });
  });

  group('parseViolations', () {
    test('reads a list, or the values of an object', () {
      expect(
        IntradeskService.parseViolations(
          '{"status":400,"title":"Bad Request","detail":"","type":"",'
          '"violations":["De URL die je hebt ingegeven is niet geldig."]}',
        ),
        ['De URL die je hebt ingegeven is niet geldig.'],
      );
      expect(
        IntradeskService.parseViolations(
          '{"violations":{"name":"Naam ontbreekt","url":"Fout"}}',
        ),
        ['Naam ontbreekt', 'Fout'],
      );
    });

    test('is empty for a bare problem and for what is not one', () {
      for (final body in [
        '{"status":400,"title":"Bad Request"}',
        '{"violations":null}',
        '[]',
        '',
        'De karakters ...',
      ]) {
        expect(IntradeskService.parseViolations(body), isEmpty, reason: body);
      }
    });
  });

  group('models', () {
    test('IntradeskFolderCapabilities reads canAddConfidentialFolder, false '
        'when the answer does not carry it (as the listings do not)', () {
      expect(
        IntradeskFolderCapabilities.fromJson({
          'canManage': true,
          'canAdd': true,
          'canAddConfidentialFolder': true,
        }).canAddConfidentialFolder,
        isTrue,
      );
      expect(
        IntradeskFolderCapabilities.fromJson({
          'canManage': true,
          'canAdd': true,
        }).canAddConfidentialFolder,
        isFalse,
      );
      expect(
        const IntradeskFolderCapabilities(
          canManage: true,
          canAdd: true,
          canSeeHistory: false,
          canSeeViewHistory: false,
        ).canAddConfidentialFolder,
        isFalse,
      );
    });

    test('IntradeskUploadResult reads files as an object or a list, and '
        'exceptions as an object or a list', () {
      final asObject = IntradeskUploadResult.fromJson(
        jsonDecode(_uploaded([(_newFile, _file())])) as Map<String, dynamic>,
      );
      expect(asObject.files.single.id, _newFile);
      expect(asObject.failures, isEmpty);

      final asList = IntradeskUploadResult.fromJson(
        jsonDecode(
              '{"files":[${_file()}],"exceptions":[{"violations":["Fout"]}]}',
            )
            as Map<String, dynamic>,
      );
      expect(asList.files.single.id, _newFile);
      expect(asList.failures.single.key, '0');
      expect(asList.failures.single.message, 'Fout');
    });

    test('IntradeskUploadResult refuses an answer without its files', () {
      for (final json in [
        <String, dynamic>{},
        <String, dynamic>{'files': 'x'},
        <String, dynamic>{
          'files': {'x': 1},
        },
      ]) {
        expect(
          () => IntradeskUploadResult.fromJson(json),
          throwsA(isA<SmartschoolParsingError>()),
          reason: '$json',
        );
      }
    });

    test('IntradeskUploadFailure without violations has an empty message', () {
      final failure = IntradeskUploadFailure.fromJson('a.txt', {'x': 1});
      expect(failure.violations, isEmpty);
      expect(failure.message, '');
      expect(failure.toString(), contains('a.txt'));
    });
  });

  group(
    'SmartschoolUploader (the upload step shared with MessagesService)',
    () {
      test('guessMimeType is the one MessagesService has', () {
        for (final name in ['a.pdf', 'b.docx', 'c.unknown', 'README']) {
          expect(
            SmartschoolUploader.guessMimeType(name),
            MessagesService.guessMimeType(name),
          );
        }
      });

      test(
        'a file that does not exist is an upload error, before any request',
        () async {
          final (server, _) = await serve({});
          final client = await SmartschoolClient.create(
            _Credentials(),
            cacheDir: tempCacheDir(),
          );
          addTearDown(client.dispose);
          client.dio.httpClientAdapter = server;

          await expectLater(
            SmartschoolUploader(
              client,
            ).uploadFile('dir1', p.join(files.path, 'bestaat-niet.txt')),
            throwsA(
              isA<SmartschoolAttachmentUploadError>().having(
                (e) => e.message,
                'message',
                contains('not found'),
              ),
            ),
          );
          expect(server.log, isEmpty);
        },
      );
    },
  );
}
