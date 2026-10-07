// Tests for issue #132: IntradeskService reads a folder's own entry by its
// ID alone (getFolder), the folders above it (getFolderPath) and their IDs
// (getFolderParentIds). getFolderListing answers what is in a folder, not the
// folder itself, and the folder's entry (its capabilities, whether it is
// confidential, its name) only came with the listing of the folder above
// it, which nothing named.
//
// The fake Smartschool below answers as the live one did on 2026-10-07
// (read-only, apart from one folder made in the live suite's test folder and
// moved to the trash again; made-up names and IDs here: "Testschool",
// platform 49):
// - `GET .../folders/{id}/parents` answers a JSON list of folder IDs, the
//   folder at the root first and the folder's parent last: `[]` for a
//   folder at the root, `["<2. SMA>"]` for "2. SMA" > "tests",
//   `["<2. SMA>", "<tests>"]` for a folder in "tests". It answers `404`
//   (`{"status":404,"title":"Not Found",...}`) for an unknown UUID and the
//   ID of a file, and takes the ID in capitals too.
// - A folder in Intradesk's trash answers its parents with `[]`, as a folder
//   at the root does (before its move to the trash, the same folder answered
//   `["<2. SMA>", "<tests>"]`); the root listing does not hold it, and its
//   own listing answers `403`.
// - `GET .../folders/{id}` answers the web client's HTML page, not JSON:
//   Smartschool has no request for one folder. The web client, opened at a
//   folder's address, asks for the parents and lists each of them
//   (`getParents` in its bundle), as these methods do.
//
// The live test of the same reads is
// test/live/intradesk_folder_live_test.dart.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
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
const _listing = '$_api/directory-listing/forTreeOnlyFolders';

/// "Documenten", at the root.
const _documenten = 'aaaa1111-1111-4111-b111-111111111111';

/// "Archief", at the root, hidden from pupils (`visible` false).
const _archief = 'aaaa2222-2222-4222-b222-222222222222';

/// "Vakgroepen", in "Documenten".
const _vakgroepen = 'bbbb1111-1111-4111-b111-111111111111';

/// "Wiskunde", in "Vakgroepen".
const _wiskunde = 'cccc1111-1111-4111-b111-111111111111';

/// "Leerlingbegeleiding", a confidential folder in "Vakgroepen" that the
/// user may not add to.
const _leerlingbegeleiding = 'cccc2222-2222-4222-b222-222222222222';

/// A folder in Intradesk's trash.
const _trashed = 'dddd1111-1111-4111-b111-111111111111';

/// A file in "Documenten".
const _file = 'eeee1111-1111-4111-b111-111111111111';

const _unknown = '00000000-0000-4000-8000-000000000000';

const _platform = '"platform":{"id":49,"name":"Testschool"}';
const _dates =
    '"dateStateChanged":"2024-12-17T13:52:39+01:00",'
    '"dateCreated":"2024-12-17T13:52:39+01:00",'
    '"dateChanged":"2025-07-01T11:05:13+02:00"';

/// A folder of a listing (trimmed capture).
String _folder(
  String id,
  String name, {
  String parent = '',
  bool visible = true,
  bool confidential = false,
  bool inConfidential = false,
  bool canManage = true,
  bool canAdd = true,
  bool hasChildren = false,
  String color = 'yellow',
}) =>
    '{"id":"$id",$_platform,"name":"$name","color":"$color",'
    '"state":"active","visible":$visible,"confidential":$confidential,'
    '"officeTemplateFolder":false,"parentFolderId":"$parent",$_dates,'
    '"isFavourite":false,"inConfidentialFolder":$inConfidential,'
    '"capabilities":{"canManage":$canManage,"canAdd":$canAdd,'
    '"canSeeHistory":true,"canSeeViewHistory":true},'
    '"hasChildren":$hasChildren}';

/// A file of a listing (trimmed capture).
String _fileIn(String parent) =>
    '{"id":"$_file",$_platform,"name":"jaarverslag.pdf","state":"active",'
    '"parentFolderId":"$parent",$_dates,"isFavourite":false,'
    '"confidential":false,"ownerId":"49_1001_0","capabilities":'
    '{"canManage":true,"canMove":true,"canHandleRevisions":true,'
    '"canSeeHistory":true,"canSeeViewHistory":true}}';

String _listingOf({
  List<String> folders = const [],
  List<String> files = const [],
}) =>
    '{"folders":[${folders.join(',')}],"files":[${files.join(',')}],'
    '"weblinks":[]}';

final _rootListing = _listingOf(
  folders: [
    _folder(_documenten, 'Documenten', hasChildren: true),
    _folder(_archief, 'Archief', visible: false, color: 'brown'),
  ],
);

final _documentenListing = _listingOf(
  folders: [
    _folder(
      _vakgroepen,
      'Vakgroepen',
      parent: _documenten,
      hasChildren: true,
      color: 'green',
    ),
  ],
  files: [_fileIn(_documenten)],
);

final _vakgroepenListing = _listingOf(
  folders: [
    _folder(_wiskunde, 'Wiskunde', parent: _vakgroepen, color: 'blue'),
    _folder(
      _leerlingbegeleiding,
      'Leerlingbegeleiding',
      parent: _vakgroepen,
      confidential: true,
      canManage: false,
      canAdd: false,
    ),
  ],
);

/// The parents Smartschool gives for each folder; `404` for any other ID.
const _parents = {
  _documenten: '[]',
  _archief: '[]',
  _vakgroepen: '["$_documenten"]',
  _wiskunde: '["$_documenten","$_vakgroepen"]',
  _leerlingbegeleiding: '["$_documenten","$_vakgroepen"]',
  // In the trash: answered as a folder at the root, which it is not.
  _trashed: '[]',
};

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, contentType: 'application/json');

/// Smartschool's bare problem answer.
_Answer _problem(int status, String title) => (
  status: status,
  body: '{"status":$status,"title":"$title","detail":"","type":""}',
  contentType: 'application/problem+json',
);

/// A Smartschool that answers the Intradesk tree above, the parents of each
/// folder as the live one does, and logs every request as `METHOD path`.
/// [answers] replaces the answer for a path. Any other request fails the
/// test.
class _Smartschool implements HttpClientAdapter {
  _Smartschool([this.answers = const {}]);

  final Map<String, _Answer> answers;

  /// Every Intradesk request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    expect(options.method, 'GET', reason: 'the reads send no write');
    final answer = _answer(path);
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: [answer.contentType],
      },
    );
  }

  _Answer _answer(String path) {
    if (path == '/course-list/api/v1/courses') {
      return _json('[{"id":"c1","platformId":49,"name":"Wiskunde"}]');
    }
    log.add('GET $path');
    final replaced = answers[path];
    if (replaced != null) return replaced;
    if (path == _listing) return _json(_rootListing);
    if (path == '$_listing/$_documenten') return _json(_documentenListing);
    if (path == '$_listing/$_vakgroepen') return _json(_vakgroepenListing);
    if (path.startsWith('$_listing/')) return _json(_listingOf());
    final parents = RegExp(
      '^${RegExp.escape(_api)}/folders/([^/]+)/parents\$',
    ).firstMatch(path);
    if (parents != null) {
      final known = _parents[parents.group(1)!.toLowerCase()];
      return known == null ? _problem(404, 'Not Found') : _json(known);
    }
    fail('unexpected request: GET $path');
  }

  @override
  void close({bool force = false}) {}
}

String _parentsOf(String id) => 'GET $_api/folders/$id/parents';

/// A [SmartschoolIntradeskFolderNotFoundError] for [folderId], with
/// [status]: what a `catch` of [SmartschoolDownloadError] still catches.
Matcher _notFound(String folderId, int status, {Object? message}) => allOf(
  isA<SmartschoolDownloadError>().having(
    (e) => e.statusCode,
    'statusCode',
    status,
  ),
  isA<SmartschoolIntradeskFolderNotFoundError>()
      .having((e) => e.folderId, 'folderId', folderId)
      .having((e) => e.message, 'message', message ?? contains(folderId)),
);

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<(IntradeskService, _Smartschool)> serve([
    Map<String, _Answer> answers = const {},
  ]) async {
    final server = _Smartschool(answers);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    client.dio.httpClientAdapter = server;
    return (IntradeskService(client), server);
  }

  tearDown(() => client.dispose());

  group('getFolderParentIds', () {
    test('gives the IDs of the folders above, the folder at the root first, '
        'in one request', () async {
      final (intradesk, server) = await serve();

      final ids = await intradesk.getFolderParentIds(_wiskunde);

      expect(ids, [_documenten, _vakgroepen]);
      expect(server.log, [_parentsOf(_wiskunde)]);
      expect(() => ids.add('x'), throwsUnsupportedError);
    });

    test('is empty for a folder at the root', () async {
      final (intradesk, _) = await serve();

      expect(await intradesk.getFolderParentIds(_documenten), isEmpty);
    });

    test('is empty for a folder in the trash too, as Smartschool answers '
        'it', () async {
      final (intradesk, _) = await serve();

      expect(await intradesk.getFolderParentIds(_trashed), isEmpty);
    });

    test('takes the ID in capitals, as Smartschool does', () async {
      final (intradesk, server) = await serve();

      final ids = await intradesk.getFolderParentIds(_vakgroepen.toUpperCase());

      expect(ids, [_documenten]);
      expect(server.log, [_parentsOf(_vakgroepen.toUpperCase())]);
    });

    test('an unknown ID is a SmartschoolIntradeskFolderNotFoundError with '
        'status 404', () async {
      final (intradesk, server) = await serve();

      await expectLater(
        intradesk.getFolderParentIds(_unknown),
        throwsA(_notFound(_unknown, 404)),
      );
      expect(server.log, [_parentsOf(_unknown)]);
    });

    test(
      'the ID of a file is a SmartschoolIntradeskFolderNotFoundError',
      () async {
        final (intradesk, _) = await serve();

        await expectLater(
          intradesk.getFolderParentIds(_file),
          throwsA(_notFound(_file, 404)),
        );
      },
    );

    test(
      'another status is the SmartschoolDownloadError of the answer',
      () async {
        final (intradesk, _) = await serve({
          '$_api/folders/$_wiskunde/parents': _problem(
            500,
            'Internal Server Error',
          ),
        });

        await expectLater(
          intradesk.getFolderParentIds(_wiskunde),
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
      },
    );

    test(
      'an answer that is not a list of IDs is a SmartschoolParsingError',
      () async {
        final (intradesk, _) = await serve({
          '$_api/folders/$_wiskunde/parents': _json('{"parents":[]}'),
        });

        await expectLater(
          intradesk.getFolderParentIds(_wiskunde),
          throwsA(isA<SmartschoolParsingError>()),
        );
      },
    );

    for (final id in ['', 'not-a-folder-id', '$_wiskunde/../x']) {
      test('refuses "$id" (not a UUID) without sending anything', () async {
        final (intradesk, server) = await serve();

        await expectLater(
          intradesk.getFolderParentIds(id),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'folderId'),
          ),
        );
        expect(server.log, isEmpty);
      });
    }
  });

  group('getFolder', () {
    test('reads a folder by its ID alone: its entry in the listing of its '
        'parent, in two requests', () async {
      final (intradesk, server) = await serve();

      final folder = await intradesk.getFolder(_wiskunde);

      expect(folder.id, _wiskunde);
      expect(folder.name, 'Wiskunde');
      expect(folder.color, 'blue');
      expect(folder.parentFolderId, _vakgroepen);
      expect(folder.confidential, isFalse);
      expect(folder.inConfidentialFolder, isFalse);
      expect(folder.capabilities.canAdd, isTrue);
      expect(folder.capabilities.canManage, isTrue);
      expect(server.log, [_parentsOf(_wiskunde), 'GET $_listing/$_vakgroepen']);
    });

    test('gives what the writes need: canAdd and whether it is '
        'confidential', () async {
      final (intradesk, _) = await serve();

      final folder = await intradesk.getFolder(_leerlingbegeleiding);

      expect(folder.name, 'Leerlingbegeleiding');
      expect(folder.confidential, isTrue);
      expect(folder.capabilities.canAdd, isFalse);
      expect(folder.capabilities.canManage, isFalse);
    });

    test('reads a folder at the root from the root listing', () async {
      final (intradesk, server) = await serve();

      final folder = await intradesk.getFolder(_archief);

      expect(folder.name, 'Archief');
      expect(folder.parentFolderId, isEmpty);
      expect(folder.visible, isFalse);
      expect(server.log, [_parentsOf(_archief), 'GET $_listing']);
    });

    test('takes the ID in capitals', () async {
      final (intradesk, _) = await serve();

      final folder = await intradesk.getFolder(_vakgroepen.toUpperCase());

      expect(folder.id, _vakgroepen);
      expect(folder.name, 'Vakgroepen');
      expect(folder.hasChildren, isTrue);
    });

    test('a folder in the trash is a SmartschoolIntradeskFolderNotFoundError '
        '(status 200), not taken for a folder at the root', () async {
      final (intradesk, server) = await serve();

      await expectLater(
        intradesk.getFolder(_trashed),
        throwsA(
          _notFound(
            _trashed,
            200,
            message: allOf(
              contains('does not list folder $_trashed in the root'),
              contains('trash'),
            ),
          ),
        ),
      );
      expect(server.log, [_parentsOf(_trashed), 'GET $_listing']);
    });

    test('an unknown ID is a SmartschoolIntradeskFolderNotFoundError (status '
        '404), without a listing', () async {
      final (intradesk, server) = await serve();

      await expectLater(
        intradesk.getFolder(_unknown),
        throwsA(_notFound(_unknown, 404)),
      );
      expect(server.log, [_parentsOf(_unknown)]);
    });

    test('a listing that fails throws as getFolderListing does', () async {
      final (intradesk, _) = await serve({
        '$_listing/$_vakgroepen': _problem(403, 'Forbidden'),
      });

      await expectLater(
        intradesk.getFolder(_wiskunde),
        throwsA(
          isA<SmartschoolDownloadError>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    test('refuses an ID that is not a UUID without sending anything', () async {
      final (intradesk, server) = await serve();

      await expectLater(intradesk.getFolder(''), throwsArgumentError);
      await expectLater(
        intradesk.getFolder('Documenten'),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.log, isEmpty);
    });
  });

  group('getFolderPath', () {
    test('gives the folders from the root down to the folder, listing the '
        'root and each parent in turn', () async {
      final (intradesk, server) = await serve();

      final path = await intradesk.getFolderPath(_wiskunde);

      expect(path.map((f) => f.name), ['Documenten', 'Vakgroepen', 'Wiskunde']);
      expect(path.map((f) => f.id), [_documenten, _vakgroepen, _wiskunde]);
      expect(path.map((f) => f.parentFolderId), ['', _documenten, _vakgroepen]);
      expect(path.map((f) => f.color), ['yellow', 'green', 'blue']);
      expect(server.log, [
        _parentsOf(_wiskunde),
        'GET $_listing',
        'GET $_listing/$_documenten',
        'GET $_listing/$_vakgroepen',
      ]);
      expect(() => path.add(path.first), throwsUnsupportedError);
    });

    test('ends with the folder getFolder reads', () async {
      final (intradesk, _) = await serve();

      final path = await intradesk.getFolderPath(_leerlingbegeleiding);
      final folder = await intradesk.getFolder(_leerlingbegeleiding);

      expect(path.last.id, folder.id);
      expect(path.last.confidential, folder.confidential);
      expect(path.last.capabilities.canAdd, folder.capabilities.canAdd);
    });

    test('is the folder alone for a folder at the root', () async {
      final (intradesk, server) = await serve();

      final path = await intradesk.getFolderPath(_documenten);

      expect(path.map((f) => f.name), ['Documenten']);
      expect(server.log, [_parentsOf(_documenten), 'GET $_listing']);
    });

    test(
      'a folder in the trash is a SmartschoolIntradeskFolderNotFoundError',
      () async {
        final (intradesk, _) = await serve();

        await expectLater(
          intradesk.getFolderPath(_trashed),
          throwsA(_notFound(_trashed, 200, message: contains('trash'))),
        );
      },
    );

    test('a parent that the listing above it does not hold (moved in '
        'between) is a SmartschoolIntradeskFolderNotFoundError for the '
        'folder asked for', () async {
      final (intradesk, server) = await serve({
        '$_listing/$_documenten': _json(_listingOf()),
      });

      await expectLater(
        intradesk.getFolderPath(_wiskunde),
        throwsA(
          _notFound(
            _wiskunde,
            200,
            message: allOf(
              contains(
                'does not list folder $_vakgroepen in folder $_documenten, '
                'where the parents of folder $_wiskunde put it',
              ),
            ),
          ),
        ),
      );
      expect(server.log.last, 'GET $_listing/$_documenten');
    });

    test('an unknown ID is a SmartschoolIntradeskFolderNotFoundError (status '
        '404)', () async {
      final (intradesk, server) = await serve();

      await expectLater(
        intradesk.getFolderPath(_unknown),
        throwsA(_notFound(_unknown, 404)),
      );
      expect(server.log, [_parentsOf(_unknown)]);
    });
  });

  group('parseFolderParentIds', () {
    test('reads the list of IDs in its order', () {
      expect(
        IntradeskService.parseFolderParentIds([_documenten, _vakgroepen]),
        [_documenten, _vakgroepen],
      );
      expect(IntradeskService.parseFolderParentIds(<Object?>[]), isEmpty);
    });

    for (final (what, data) in [
      ('an object', <String, Object?>{}),
      ('null', null),
      ('a string', _documenten),
      ('a number in the list', [_documenten, 7]),
      ('an empty ID', ['']),
    ]) {
      test('refuses $what with a SmartschoolParsingError', () {
        expect(
          () => IntradeskService.parseFolderParentIds(data),
          throwsA(isA<SmartschoolParsingError>()),
        );
      });
    }
  });

  group('SmartschoolIntradeskFolderNotFoundError', () {
    test('keeps the status 500 and the message of a listing by default', () {
      final error = SmartschoolIntradeskFolderNotFoundError(_unknown);

      expect(error.statusCode, 500);
      expect(error.folderId, _unknown);
      expect(
        error.message,
        'Intradesk has no folder with ID "$_unknown": the ID is unknown, or '
        'it is the ID of a file or a weblink.',
      );
    });

    test('takes the status and the message of a read of #132', () {
      final error = SmartschoolIntradeskFolderNotFoundError(
        _trashed,
        statusCode: 200,
        message: 'in the trash',
      );

      expect(error.statusCode, 200);
      expect(error.message, 'in the trash');
      expect(error.toString(), contains('(200)'));
    });
  });
}
