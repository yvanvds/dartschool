// Regression tests for issue #37: three gaps of `IntradeskService`, found by
// walking a whole school's Intradesk (about 5900 folders and 22000 files,
// from yvanvds/smartschool-mcp at bfd6258).
//
// 1. Weblinks came as raw maps (`List<Map<String, dynamic>>`), documented as
//    "always empty"; the walk found 214. Each has the keys `id`, `platform`,
//    `name`, `state`, `url`, `icon`, `parentFolderId`, `dateStateChanged`,
//    `dateCreated`, `dateChanged`, `isFavourite`, `confidential`, `ownerId`
//    and `capabilities` (`canManage`, `canMove`, `canSeeHistory`,
//    `canSeeViewHistory`), as a live folder listing showed again (read-only).
//    They are now `IntradeskWeblink`s.
// 2. `IntradeskFolder.hasChildren` counts subfolders only: 3845 of the 5863
//    folders had it false and still held files. Its doc now says so, and
//    `hasSubfolders` names the value for what it counts.
// 3. Smartschool answers the listing of an ID that is not a folder with HTTP
//    `500` and a bare problem (`{"status":500,"title":"Internal Server
//    Error","detail":"","type":""}`, `application/problem+json`): live for an
//    unknown UUID, the ID of a file, the ID of a weblink and an ID that is
//    not a UUID. Its `folders/{id}/parents` answers `404` (`"title":"Not
//    Found"`) for the first three and the parents for a folder (`[]` at the
//    root); the ID that is not a UUID gets `500` there too. A listing that
//    fails with `500` is now followed by that request, and its `404` makes a
//    `SmartschoolIntradeskFolderNotFoundError`.
//
// The fake Smartschool below serves the recorded listings under
// test/fixtures/smartschool/requests/get/intradesk (made-up names and IDs:
// "Testschool", "Jan Janssens"); bbbb1111 (the "Archief" folder that its
// parent lists with `hasChildren: false`) holds a file and a weblink.
import 'dart:io';
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

const _documenten = 'aaaa1111-1111-4111-b111-111111111111';
const _examens = 'aaaa2222-2222-4222-b222-222222222222';
const _archief = 'bbbb1111-1111-4111-b111-111111111111';
const _fileInDocumenten = 'cccc2222-2222-4222-b222-222222222222';
const _weblinkInArchief = 'eeee1111-1111-4111-b111-111111111111';
const _unknown = '00000000-0000-4000-8000-000000000000';

/// The parents Smartschool gives for each folder of the fixtures.
const _parents = {
  _documenten: '[]',
  _examens: '[]',
  _archief: '["$_documenten"]',
};

String _fixture(String path) =>
    File('test/fixtures/smartschool/requests/get/$path').readAsStringSync();

ResponseBody _json(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

/// Smartschool's answer to a request it fails, as a bare problem.
ResponseBody _problem(int status, String title) => ResponseBody.fromString(
  '{"status":$status,"title":"$title","detail":"","type":""}',
  status,
  headers: {
    Headers.contentTypeHeader: ['application/problem+json'],
  },
);

ResponseBody _serverError() => _problem(500, 'Internal Server Error');
ResponseBody _notFound() => _problem(404, 'Not Found');

typedef _Answer = ResponseBody Function(RequestOptions options);

/// A Smartschool that answers the Intradesk listings from the fixtures, and
/// the parents of a folder as Smartschool does: `404` for an ID that is not
/// a folder of the fixtures.
///
/// [answers] replaces the answer for a path.
class _Smartschool implements HttpClientAdapter {
  _Smartschool([this.answers = const {}]);

  final Map<String, _Answer> answers;

  /// Every request the client made, as `METHOD path`.
  final List<String> log = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    log.add('${options.method} $path');
    expect(options.method, 'GET');

    final answer = answers[path];
    if (answer != null) return answer(options);

    if (path == '/course-list/api/v1/courses') {
      return _json(_fixture('course-list/api/v1/courses.json'));
    }
    if (path == _listing) {
      return _json(
        _fixture(
          'intradesk/api/v1/49/directory-listing/fortreeonlyfolders.json',
        ),
      );
    }
    if (path.startsWith('$_listing/')) {
      final id = path.substring('$_listing/'.length);
      final file = File(
        'test/fixtures/smartschool/requests/get/intradesk/api/v1/49/'
        'directory-listing/fortreeonlyfolders/$id.json',
      );
      return file.existsSync()
          ? _json(file.readAsStringSync())
          : _serverError();
    }
    final parents = RegExp(
      '^${RegExp.escape(_api)}/folders/([^/]+)/parents\$',
    ).firstMatch(path);
    if (parents != null) {
      final known = _parents[parents.group(1)];
      return known == null ? _notFound() : _json(known);
    }
    fail('unexpected request: GET $path');
  }

  @override
  void close({bool force = false}) {}
}

/// The error for an ID that Smartschool knows no folder for, which a `catch`
/// of [SmartschoolDownloadError] (with the listing's `500`) still catches.
Matcher _folderNotFound(String folderId) => allOf(
  isA<SmartschoolDownloadError>().having((e) => e.statusCode, 'status', 500),
  isA<SmartschoolIntradeskFolderNotFoundError>()
      .having((e) => e.folderId, 'folderId', folderId)
      .having((e) => e.message, 'message', contains(folderId)),
);

/// The listing's own error, not taken for an ID that is not a folder.
Matcher _listingFailed(int status) => allOf(
  isA<SmartschoolDownloadError>().having((e) => e.statusCode, 'status', status),
  isNot(isA<SmartschoolIntradeskFolderNotFoundError>()),
);

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<_Smartschool> serve([Map<String, _Answer> answers = const {}]) async {
    final server = _Smartschool(answers);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  tearDown(() => client.dispose());

  group('weblinks are typed (#37)', () {
    test('a folder listing gives its weblinks as IntradeskWeblinks', () async {
      await serve();

      final listing = await IntradeskService(client).getFolderListing(_archief);

      // Before the fix: a raw map, `listing.weblinks.single['url']`.
      final IntradeskWeblink link = listing.weblinks.single;
      expect(link.id, _weblinkInArchief);
      expect(link.name, 'Schoolkalender');
      expect(link.url, 'https://www.example.com/springfield-academy/kalender');
      expect(link.icon, 'folder_orange');
      expect(link.state, 'active');
      expect(link.parentFolderId, _archief);
      expect(link.platform.id, 49);
      expect(link.platform.name, 'Testschool');
      expect(link.dateCreated, DateTime.parse('2023-03-25T12:29:59+01:00'));
      expect(
        link.dateStateChanged,
        DateTime.parse('2023-03-25T12:29:59+01:00'),
      );
      expect(link.dateChanged, DateTime.parse('2023-07-01T11:11:13+02:00'));
      expect(link.isFavourite, isFalse);
      expect(link.confidential, isTrue);
      expect(link.ownerId, '49_1001_0');
      expect(link.capabilities.canManage, isTrue);
      expect(link.capabilities.canMove, isTrue);
      expect(link.capabilities.canSeeHistory, isFalse);
      expect(link.capabilities.canSeeViewHistory, isFalse);
      expect(link.toString(), contains('Schoolkalender'));
      expect(listing.toString(), contains('weblinks: 1'));
    });

    test('a weblink without capabilities has none', () async {
      await serve({
        '$_listing/$_archief': (_) => _json(
          _fixture(
            'intradesk/api/v1/49/directory-listing/fortreeonlyfolders/'
            '$_archief.json',
          ).replaceFirst(
            '"capabilities": {"canManage": true, "canMove": true, '
                '"canSeeHistory": false, "canSeeViewHistory": false}',
            '"capabilities": null',
          ),
        ),
      });

      final listing = await IntradeskService(client).getFolderListing(_archief);

      final capabilities = listing.weblinks.single.capabilities;
      expect(capabilities.canManage, isFalse);
      expect(capabilities.canMove, isFalse);
    });
  });

  group('hasChildren counts subfolders only (#37)', () {
    test(
      'a folder with hasChildren false still holds a file and a weblink',
      () async {
        await serve();
        final intradesk = IntradeskService(client);

        final root = await intradesk.getRootListing();
        final documenten = root.folders.firstWhere((f) => f.id == _documenten);
        expect(documenten.hasChildren, isTrue);
        expect(documenten.hasSubfolders, isTrue);

        final archief = (await intradesk.getFolderListing(
          _documenten,
        )).folders.single;
        expect(archief.id, _archief);
        expect(archief.hasChildren, isFalse);
        expect(archief.hasSubfolders, isFalse);

        // Listing it anyway finds what it holds.
        final inArchief = await intradesk.getFolderListing(_archief);
        expect(inArchief.folders, isEmpty);
        expect(inArchief.files.single.name, 'jaarverslag.pdf');
        expect(inArchief.weblinks.single.name, 'Schoolkalender');
      },
    );
  });

  group('an ID that is not a folder (#37)', () {
    test(
      'an unknown ID is a SmartschoolIntradeskFolderNotFoundError',
      () async {
        final server = await serve();

        // Before the fix: SmartschoolDownloadError('Failed to retrieve JSON',
        // 500), the same as for a failure of Smartschool's own.
        await expectLater(
          IntradeskService(client).getFolderListing(_unknown),
          throwsA(_folderNotFound(_unknown)),
        );
        expect(server.log, [
          'GET /course-list/api/v1/courses',
          'GET $_listing/$_unknown',
          'GET $_api/folders/$_unknown/parents',
        ]);
      },
    );

    test(
      'the ID of a file is a SmartschoolIntradeskFolderNotFoundError',
      () async {
        await serve();

        await expectLater(
          IntradeskService(client).getFolderListing(_fileInDocumenten),
          throwsA(_folderNotFound(_fileInDocumenten)),
        );
      },
    );

    test(
      'the ID of a weblink is a SmartschoolIntradeskFolderNotFoundError',
      () async {
        await serve();

        await expectLater(
          IntradeskService(client).getFolderListing(_weblinkInArchief),
          throwsA(_folderNotFound(_weblinkInArchief)),
        );
      },
    );

    test(
      'a folder whose listing fails with 500 keeps the listing error',
      () async {
        final server = await serve({
          '$_listing/$_archief': (_) => _serverError(),
        });

        await expectLater(
          IntradeskService(client).getFolderListing(_archief),
          throwsA(_listingFailed(500)),
        );
        expect(server.log.last, 'GET $_api/folders/$_archief/parents');
      },
    );

    test('an ID whose parents Smartschool fails too (not a UUID) keeps the '
        'listing error', () async {
      await serve({
        '$_api/folders/not-a-folder-id/parents': (_) => _serverError(),
      });

      await expectLater(
        IntradeskService(client).getFolderListing('not-a-folder-id'),
        throwsA(_listingFailed(500)),
      );
    });

    test('a failed request for the parents keeps the listing error', () async {
      await serve({
        '$_api/folders/$_unknown/parents': (options) =>
            throw DioException.connectionError(
              requestOptions: options,
              reason: 'Connection reset by peer',
              error: const SocketException('Connection reset by peer'),
            ),
      });

      await expectLater(
        IntradeskService(client).getFolderListing(_unknown),
        throwsA(_listingFailed(500)),
      );
    });

    test('another status does not ask for the parents', () async {
      final server = await serve({
        '$_listing/$_unknown': (_) => _problem(403, 'Forbidden'),
      });

      await expectLater(
        IntradeskService(client).getFolderListing(_unknown),
        throwsA(_listingFailed(403)),
      );
      expect(server.log.last, 'GET $_listing/$_unknown');
    });

    test(
      'a folder listing that succeeds does not ask for the parents',
      () async {
        final server = await serve();

        await IntradeskService(client).getFolderListing(_examens);

        expect(server.log, [
          'GET /course-list/api/v1/courses',
          'GET $_listing/$_examens',
        ]);
      },
    );
  });
}
