// Tests for issue #15: `MessagesService.getHeaders()` and
// `getArchiveHeaders()` return at most 50 headers, the newest 50 of the box,
// with no way to get the older ones. And for #76: when Smartschool restarted
// the paging halfway, `getHeaderPages` ended as after the last page, so that
// `getAllHeaders` returned part of the box without telling. And for #80: two
// pagings of the same box on one client could skip each other's pages
// without an error, since they share Smartschool's one position of the box.
//
// How Smartschool pages, verified live (read-only, `postboxes / message list`
// and `continue_messages` on the inbox, the sent box, the archive, the drafts
// and the trash of a teacher account) and in the web client's Messages
// script (`oMessageList.scrollList` / `handleAction`):
//
// - `message list` answers with a `rebuild` action holding at most 50
//   headers. It takes no offset (`offset`, `start`, `page` and `limit` are
//   ignored), and poll mode only returns headers newer than the given ones.
// - When the box holds more, the answer ends with a `continue_messages`
//   action (`<details><boxID>…</boxID><boxType>…</boxType></details>`). The
//   web client then sends `postboxes / continue_messages` with `boxID`,
//   `boxType` and `layout` when the user scrolls to the bottom; the answer
//   is a `rebuildcontinue` action with the next headers, in the order of
//   the `message list`, and again a `continue_messages` action while there
//   are more. The last page (and a box that fits in one page) ends with a
//   `rebuildfinish` action instead (`<data><message/></data>`); a
//   `continue_messages` after that gets only `rebuildfinish` again.
// - The position is kept per user and box, not in the session (#76, verified
//   live with two clients, each with its own cookie cache, on an inbox of
//   186 headers): paging the inbox and the sent box in turns works, and a
//   new login between two pages (the cookies cleared, a `401`, a full login)
//   goes on with the next page. But any `message list` of a box (also in
//   poll mode), in any session of the account, restarts its paging at the
//   second page: the next `continue_messages` answers with the second page
//   again, all of it emitted already, and still announces more.
// - The `message list` answer holds no total for the box (its `changetext`
//   action holds only `postboxName`), so a listing cannot be checked against
//   one.
// - Pages are 50 headers, but some pages of the trash held 49, so a short
//   page does not mean the end.
// - Not checked: whether a box that is an exact multiple of the page size
//   announces more on its last page. If it does, the `continue_messages`
//   after it gets `rebuildfinish` only, which must end the paging normally.
//
// The fake Smartschool below answers from the anonymised fixtures `message
// list more.xml`, `continue_messages.xml` and `continue_messages last.xml`
// (the shape of the live answers, with made-up names), from pages built by
// `_page`, or from `_Account`, which keeps the paging position per box as
// Smartschool does.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

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

String _fixture(String name) => File(
  'test/fixtures/smartschool/requests/post/postboxes/$name',
).readAsStringSync();

/// A `message list` (`rebuild`) or `continue_messages` (`rebuildcontinue`)
/// answer holding a header for each of [ids], ending with a
/// `continue_messages` action when [more] and with `rebuildfinish` when not.
String _page(List<int> ids, {required bool more, bool first = false}) {
  final messages = ids
      .map(
        (id) =>
            '<message><id>$id</id><from>Jan Janssens</from>'
            '<fromImage>https://userpicture20.smartschool.be/User/Userimage/'
            'hashimage/hash/initials_JJ/plain/1/res/32</fromImage>'
            '<subject>Bericht $id</subject><date>2026-09-01 08:00</date>'
            '<status>1</status><attachment>0</attachment><unread>1</unread>'
            '<label>0</label><deleted>0</deleted><allowreply>1</allowreply>'
            '<allowreplyenabled>1</allowreplyenabled><hasreply>0</hasreply>'
            '<hasForward>0</hasForward><realBox>inbox</realBox><sendDate />'
            '</message>',
      )
      .join();
  final end = more
      ? '<action><subsystem>message list</subsystem>'
            '<command>continue_messages</command><data><details>'
            '<boxID>0</boxID><boxType>inbox</boxType></details></data></action>'
      : '<action><subsystem>message list</subsystem>'
            '<command>rebuildfinish</command><data><message /></data></action>';
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<server><response><status>ok</status><actions>'
      '<action><subsystem>message list</subsystem>'
      '<command>${first ? 'rebuild' : 'rebuildcontinue'}</command>'
      '<data><messages>$messages</messages></data></action>'
      '$end</actions></response></server>';
}

/// A request to the XML dispatcher: its action and params.
typedef _Request = ({String action, Map<String, String> params});

/// Smartschool's answer to `quickactions` / `requestmovelist` (#136), as it
/// came in live, with the archive at box ID [archive] (`208` live).
String _folderTree(int archive) =>
    File(
      'test/fixtures/smartschool/requests/post/quickactions/requestmovelist.xml',
    ).readAsStringSync().replaceFirst(
      '&quot;postboxID&quot;:&quot;208&quot;',
      '&quot;postboxID&quot;:&quot;$archive&quot;',
    );

/// A Smartschool whose XML dispatcher answers `message list` and
/// `continue_messages` with [answer] and `requestmovelist` with
/// [folderTree] (where `getArchiveBoxId` finds the archive box ID since
/// #141), and whose Messages page (where it found the ID before) is
/// [messagesPage].
///
/// [before], when given, runs before each request to the dispatcher is
/// answered, so that a test can make something happen in between.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    this.answer, {
    this.messagesPage = '',
    String? folderTree,
    this.before,
  }) : folderTree = folderTree ?? _folderTree(208);

  final String Function(_Request request) answer;
  final String messagesPage;
  final String folderTree;
  final Future<void> Function(_Request request)? before;

  /// Every request to the XML dispatcher, in order.
  final List<_Request> requests = [];

  /// [requests] as `[action, params]` pairs, to compare with `equals`.
  List<List<Object>> get log => [
    for (final r in requests) [r.action, r.params],
  ];

  static final _action = RegExp(r'<action>(.*?)</action>');
  static final _param = RegExp(
    r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      expect(options.uri.queryParameters['module'], 'Messages');
      return ResponseBody.fromString(
        messagesPage,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    final command = (options.data as Map)['command'] as String;
    final request = (
      action: _action.firstMatch(command)!.group(1)!,
      params: {
        for (final m in _param.allMatches(command)) m.group(1)!: m.group(2)!,
      },
    );
    requests.add(request);
    // A paging that does not stop would run forever against a server that
    // keeps announcing more; fail instead.
    if (requests.length > 20) fail('more than 20 requests: paging loops');
    await before?.call(request);
    return ResponseBody.fromString(
      request.action == 'requestmovelist' ? folderTree : answer(request),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers `message list` with [pages].first and each `continue_messages`
/// with the next page of [pages]; past the end, with [afterLast] (by default
/// `rebuildfinish` only, as Smartschool does).
String Function(_Request) _pages(
  List<String> pages, {
  String Function()? afterLast,
}) {
  var next = 0;
  return (request) {
    if (request.action == 'message list') {
      next = 1;
      return pages.first;
    }
    expect(request.action, 'continue_messages');
    if (next < pages.length) return pages[next++];
    return afterLast?.call() ?? _page(const [], more: false);
  };
}

/// A Smartschool account whose boxes hold the header IDs of [boxes] (by
/// `boxType/boxID`, such as `inbox/0`), paged [pageSize] at a time (2, to
/// keep the boxes small).
///
/// Like Smartschool (#76), it keeps one paging position per box for the
/// account, whichever session asks: a `message list` of a box answers with
/// its first page and sets the position of the box to the second page, and
/// a `continue_messages` answers with the page at the position and moves it
/// on. Past the last page it answers with `rebuildfinish` only. Clients that
/// share an account have sessions of their own, but share its positions.
///
/// The IDs of a box are in descending order; a `message list` with `sortKey`
/// `asc` gets them the other way round. A `continue_messages` names no order,
/// so it goes on in the order of the box's last `message list` (assumed, not
/// checked live; #80's tests use it to show a page of another listing).
class _Account {
  _Account(this.boxes);

  static const pageSize = 2;

  final Map<String, List<int>> boxes;
  final Map<String, int> _position = {};
  final Map<String, bool> _ascending = {};

  String answer(_Request request) {
    final box = '${request.params['boxType']}/${request.params['boxID']}';
    final first = request.action == 'message list';
    if (first) _ascending[box] = request.params['sortKey'] == 'asc';
    final ids = _ascending[box]! ? boxes[box]!.reversed.toList() : boxes[box]!;
    final page = first ? 0 : _position[box]!;
    _position[box] = page + 1;
    final start = page * pageSize;
    return _page(
      ids.skip(start).take(pageSize).toList(),
      more: start + pageSize < ids.length,
      first: first,
    );
  }
}

List<int> _ids(Iterable<ShortMessage> headers) =>
    headers.map((h) => h.id).toList();

const _inboxList = {
  'boxType': 'inbox',
  'boxID': '0',
  'sortField': 'date',
  'sortKey': 'desc',
  'poll': 'false',
  'poll_ids': '',
  'layout': 'new',
};

const _inboxContinue = {'boxID': '0', 'boxType': 'inbox', 'layout': 'new'};

void main() {
  forbidRealNetwork();

  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(
    String Function(_Request request) answer, {
    String messagesPage = '',
    String? folderTree,
    Future<void> Function(_Request request)? before,
  }) async {
    final server = _Smartschool(
      answer,
      messagesPage: messagesPage,
      folderTree: folderTree,
      before: before,
    );
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
  }

  /// A second client of the same account, with a cookie cache and so a
  /// session of its own, served by [answer].
  Future<(SmartschoolClient, _Smartschool)> otherSession(
    String Function(_Request request) answer,
  ) async {
    final dir = Directory.systemTemp.createTempSync('smartschool_pages_');
    final other = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: dir.path,
    );
    final server = _Smartschool(answer);
    other.dio.httpClientAdapter = server;
    addTearDown(() async {
      await other.dispose();
      dir.deleteSync(recursive: true);
    });
    return (other, server);
  }

  /// The three fixture pages: 2 headers, 2 more, and the last one.
  Future<_Smartschool> serveFixtures() => serve(
    _pages([
      _fixture('message list more.xml'),
      _fixture('continue_messages.xml'),
      _fixture('continue_messages last.xml'),
    ]),
  );

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('smartschool_pages_');
  });

  tearDown(() async {
    await client.dispose();
    cacheDir.deleteSync(recursive: true);
  });

  group(
    'getHeaderPages pages through the box as the web client does (#15)',
    () {
      test(
        'a message list, then continue_messages until the last page',
        () async {
          final server = await serveFixtures();

          final pages = await MessagesService(client).getHeaderPages().toList();

          expect(pages.map(_ids), [
            [6400006, 6400005],
            [6400004, 6400003],
            [6400002],
          ]);
          expect(pages[1].first.sender, 'Piet Pieters');
          expect(pages[2].single.date, DateTime(2026, 9, 2, 7, 33));
          expect(server.log, [
            ['message list', _inboxList],
            ['continue_messages', _inboxContinue],
            ['continue_messages', _inboxContinue],
          ]);
        },
      );

      test('the first page is what getHeaders returns', () async {
        final server = await serveFixtures();
        final messages = MessagesService(client);

        final first = await messages.getHeaderPages().first;
        final headers = await messages.getHeaders();

        expect(_ids(first), _ids(headers));
        expect(server.log[0], server.log[1]);
      });

      test('a box that fits in one page takes one request', () async {
        // `message list.xml` ends with `rebuildfinish`, as a live answer for a
        // box of less than 50 messages does.
        final server = await serve((_) => _fixture('message list.xml'));

        final pages = await MessagesService(client).getHeaderPages().toList();

        expect(pages.map(_ids), [
          [123456, 7890123],
        ]);
        expect(server.requests.map((r) => r.action), ['message list']);
      });

      test('an empty box gives no pages', () async {
        final server = await serve((_) => _page(const [], more: false));

        final pages = await MessagesService(client).getHeaderPages().toList();

        expect(pages, isEmpty);
        expect(server.requests, hasLength(1));
      });

      test('asks for the next page only when the listener wants it', () async {
        final server = await serveFixtures();
        final messages = MessagesService(client);

        await messages.getHeaderPages().first;
        expect(server.requests, hasLength(1));

        await messages.getHeaderPages().take(2).toList();
        expect(server.requests.map((r) => r.action), [
          'message list',
          'message list',
          'continue_messages',
        ]);
      });

      test('pages the sent box in the requested order', () async {
        final server = await serve(
          _pages([
            _page([1, 2], more: true, first: true),
            _page([3], more: false),
          ]),
        );

        final pages = await MessagesService(client)
            .getHeaderPages(
              boxType: BoxType.sent,
              sortBy: SortField.from,
              sortOrder: SortOrder.asc,
            )
            .toList();

        expect(pages.map(_ids), [
          [1, 2],
          [3],
        ]);
        expect(server.log, [
          [
            'message list',
            {
              ..._inboxList,
              'boxType': 'outbox',
              'sortField': 'from',
              'sortKey': 'asc',
            },
          ],
          [
            'continue_messages',
            {..._inboxContinue, 'boxType': 'outbox'},
          ],
        ]);
      });

      test('a short page before the last does not end the paging', () async {
        final server = await serve(
          _pages([
            _page([1, 2, 3], more: true, first: true),
            _page([4], more: true),
            _page([5, 6], more: false),
          ]),
        );

        final pages = await MessagesService(client).getHeaderPages().toList();

        expect(pages.map(_ids), [
          [1, 2, 3],
          [4],
          [5, 6],
        ]);
        expect(server.requests, hasLength(3));
      });

      test('an error on a later page reaches the listener', () async {
        await serve(
          _pages([
            _page([1, 2], more: true, first: true),
            '<html><body>Login</body></html>',
          ]),
        );

        final pages = <List<int>>[];
        await expectLater(
          MessagesService(
            client,
          ).getHeaderPages().forEach((page) => pages.add(_ids(page))),
          throwsA(isA<SmartschoolAuthenticationError>()),
        );
        expect(pages, [
          [1, 2],
        ]);
      });
    },
  );

  /// The pages [stream] emits before it fails with [error].
  Future<List<List<int>>> pagesBefore(
    Stream<List<ShortMessage>> stream,
    Matcher error,
  ) async {
    final pages = <List<int>>[];
    await expectLater(
      stream.forEach((page) => pages.add(_ids(page))),
      throwsA(error),
    );
    return pages;
  }

  group('getHeaderPages fails when Smartschool restarts the paging (#76)', () {
    final restarted = isA<SmartschoolPagingRestartedError>();

    test('a server that restarts at the second page, as a new message list '
        'of the box makes Smartschool do', () async {
      final second = _page([3, 4], more: true);
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          second,
          _page([5, 6], more: true),
          second,
          _page([5, 6], more: true),
        ]),
      );

      final pages = await pagesBefore(
        MessagesService(client).getHeaderPages(),
        restarted,
      );

      expect(pages, [
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
      expect(server.requests, hasLength(4));
    });

    test(
      'a second page that a new message shifted is recognised too',
      () async {
        // A message that arrived since the second page went out moves the box
        // by one: the second page sent again starts with the last header of
        // the first page.
        await serve(
          _pages([
            _page([1, 2], more: true, first: true),
            _page([3, 4], more: true),
            _page([5, 6], more: true),
            _page([2, 3], more: true),
          ]),
        );

        final pages = await pagesBefore(
          MessagesService(client).getHeaderPages(),
          restarted,
        );

        expect(pages, [
          [1, 2],
          [3, 4],
          [5, 6],
        ]);
      },
    );

    test('a server that repeats the last page, announcing more, cannot keep '
        'the paging going', () async {
      final last = _page([3, 4], more: true);
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          last,
        ], afterLast: () => last),
      );

      final pages = await pagesBefore(
        MessagesService(client).getHeaderPages(),
        restarted,
      );

      expect(pages, [
        [1, 2],
        [3, 4],
      ]);
      expect(server.requests, hasLength(3));
    });

    test('says which box, and to list it again', () async {
      await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([1, 2], more: true),
        ]),
      );

      await pagesBefore(
        MessagesService(client).getHeaderPages(boxType: BoxType.sent),
        isA<SmartschoolPagingRestartedError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('boxType outbox, boxID 0'),
            contains('after 2 headers'),
            contains('List the box again'),
          ),
        ),
      );
    });
  });

  group('getHeaderPages ends normally without a restart (#15, #76)', () {
    test('a last continue_messages answered with rebuildfinish only', () async {
      // What a box that is an exact multiple of the page size gets, if
      // Smartschool announces more on its last page (not checked live).
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([3, 4], more: true),
        ]),
      );

      final pages = await MessagesService(client).getHeaderPages().toList();

      expect(pages.map(_ids), [
        [1, 2],
        [3, 4],
      ]);
      expect(server.requests, hasLength(3));
    });

    test('an empty page that announces more', () async {
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page(const [], more: true),
          _page([3], more: false),
        ]),
      );

      final pages = await MessagesService(client).getHeaderPages().toList();

      expect(pages.map(_ids), [
        [1, 2],
      ]);
      expect(server.requests, hasLength(2));
    });

    test('headers already emitted are left out of a later page', () async {
      // A message that arrives while paging shifts the box by one: the next
      // page starts with the last header of the previous one.
      await serve(
        _pages([
          _page([10, 9], more: true, first: true),
          _page([9, 8, 7], more: true),
          _page([6], more: false),
        ]),
      );

      final pages = await MessagesService(client).getHeaderPages().toList();

      expect(pages.map(_ids), [
        [10, 9],
        [8, 7],
        [6],
      ]);
    });
  });

  group('getAllHeaders (#15)', () {
    test('returns the headers of every page, in order', () async {
      final server = await serveFixtures();

      final headers = await MessagesService(client).getAllHeaders();

      expect(_ids(headers), [6400006, 6400005, 6400004, 6400003, 6400002]);
      expect(server.requests, hasLength(3));
    });

    test('stops requesting pages at limit', () async {
      final server = await serveFixtures();

      final headers = await MessagesService(client).getAllHeaders(limit: 3);

      expect(_ids(headers), [6400006, 6400005, 6400004]);
      expect(server.requests, hasLength(2));
    });

    test('a limit on a page boundary takes no further page', () async {
      final server = await serveFixtures();

      final headers = await MessagesService(client).getAllHeaders(limit: 2);

      expect(_ids(headers), [6400006, 6400005]);
      expect(server.requests, hasLength(1));
    });

    test('a limit above the size of the box returns the whole box', () async {
      await serveFixtures();

      final headers = await MessagesService(client).getAllHeaders(limit: 50);

      expect(headers, hasLength(5));
    });

    test('rejects a limit below 1 without a request', () async {
      final server = await serveFixtures();

      await expectLater(
        MessagesService(client).getAllHeaders(limit: 0),
        throwsArgumentError,
      );
      expect(server.requests, isEmpty);
    });

    test('fails, rather than return part of the box, when the box is listed '
        'in another session halfway; listing it again gets all of it '
        '(#76)', () async {
      final box = [for (var id = 10; id > 0; id--) id];
      final account = _Account({'inbox/0': box});
      final (other, otherServer) = await otherSession(account.answer);
      var continues = 0;
      final server = await serve(
        account.answer,
        // Right before Smartschool answers the second continue_messages,
        // after the first two pages, the box is listed in the other session,
        // as another app or the web client would.
        before: (request) async {
          if (request.action != 'continue_messages') return;
          if (++continues == 2) await MessagesService(other).getHeaders();
        },
      );
      final messages = MessagesService(client);

      await expectLater(
        messages.getAllHeaders(),
        throwsA(isA<SmartschoolPagingRestartedError>()),
      );
      expect(server.requests, hasLength(3));
      expect(otherServer.requests.map((r) => r.action), ['message list']);

      expect(_ids(await messages.getAllHeaders()), box);
    });
  });

  group('archive (#15)', () {
    final archiveList = {..._inboxList, 'boxID': '208'};
    final archiveContinue = {..._inboxContinue, 'boxID': '208'};

    test('getArchiveHeaderPages pages the given archive box', () async {
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([3], more: false),
        ]),
      );

      final pages = await MessagesService(
        client,
      ).getArchiveHeaderPages(boxId: 208).toList();

      expect(pages.map(_ids), [
        [1, 2],
        [3],
      ]);
      expect(server.log, [
        ['message list', archiveList],
        ['continue_messages', archiveContinue],
      ]);
    });

    test('getAllArchiveHeaders resolves the archive box ID, in the folder '
        'tree (#141)', () async {
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([3], more: false),
        ]),
        folderTree: _folderTree(312),
      );

      final headers = await MessagesService(client).getAllArchiveHeaders();

      expect(_ids(headers), [1, 2, 3]);
      expect(server.log, [
        ['requestmovelist', <String, String>{}],
        [
          'message list',
          {..._inboxList, 'boxID': '312'},
        ],
        [
          'continue_messages',
          {..._inboxContinue, 'boxID': '312'},
        ],
      ]);
    });

    test('getAllArchiveHeaders honours limit', () async {
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([3], more: false),
        ]),
      );

      final headers = await MessagesService(
        client,
      ).getAllArchiveHeaders(boxId: 208, limit: 1);

      expect(_ids(headers), [1]);
      expect(server.log, [
        ['message list', archiveList],
      ]);
    });

    test('getAllArchiveHeaders fails when the paging is restarted '
        '(#76)', () async {
      final second = _page([3, 4], more: true);
      await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          second,
          second,
        ]),
      );

      await expectLater(
        MessagesService(client).getAllArchiveHeaders(boxId: 208),
        throwsA(
          isA<SmartschoolPagingRestartedError>().having(
            (e) => e.message,
            'message',
            contains('boxType inbox, boxID 208'),
          ),
        ),
      );
    });
  });

  group('pagings of a box on one client (#80)', () {
    // Five pages of two headers.
    final box = [for (var id = 10; id > 0; id--) id];
    final restarted = isA<SmartschoolPagingRestartedError>();
    final restartedHere = restarted.having(
      (e) => e.message,
      'message',
      allOf(
        contains('boxType inbox, boxID 0'),
        contains('listed again on this client'),
        contains('List the box again'),
      ),
    );

    /// The actions of [server]'s requests.
    List<String> actions(_Smartschool server) =>
        server.requests.map((r) => r.action).toList();

    /// The actions of a paging of [box], from its `message list` on.
    const wholeBox = [
      'message list',
      'continue_messages',
      'continue_messages',
      'continue_messages',
      'continue_messages',
    ];

    /// Fails a paging that hangs, rather than let the test time out.
    Future<T> inTime<T>(Future<T> future) =>
        future.timeout(const Duration(seconds: 5));

    test('a paging started while another runs makes the first one fail '
        'before its next page, rather than skip one: the issue\'s '
        'interleaving', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);
      final messages = MessagesService(client);
      final a = StreamIterator(messages.getHeaderPages());
      final b = StreamIterator(messages.getHeaderPages());

      // A and B each send their message list and get the first page.
      expect(await a.moveNext(), isTrue);
      expect(_ids(a.current), [10, 9]);
      expect(await b.moveNext(), isTrue);
      expect(_ids(b.current), [10, 9]);

      // A's continue_messages would get the second page and leave B the
      // third: A fails without sending it.
      await expectLater(
        a.moveNext(),
        throwsA(
          restartedHere.having(
            (e) => e.message,
            'message',
            contains('after 2 headers'),
          ),
        ),
      );
      final ofB = _ids(b.current);
      while (await b.moveNext()) {
        ofB.addAll(_ids(b.current));
      }

      expect(ofB, box);
      expect(actions(server), ['message list', ...wholeBox]);
    });

    test('two getAllHeaders of a box at the same time run one after the '
        'other, also on two services of the client, and both get the whole '
        'box', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);

      final results = await inTime(
        Future.wait([
          MessagesService(client).getAllHeaders(),
          MessagesService(client).getAllHeaders(),
        ]),
      );

      expect(results.map(_ids), [box, box]);
      expect(actions(server), [...wholeBox, ...wholeBox]);
    });

    test('a getHeaderPages waits for a getAllHeaders of the box that '
        'runs', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);
      final messages = MessagesService(client);

      final all = messages.getAllHeaders();
      final pages = messages.getHeaderPages().toList();

      expect(_ids(await inTime(all)), box);
      expect(_ids((await inTime(pages)).expand((page) => page)), box);
      expect(actions(server), [...wholeBox, ...wholeBox]);
    });

    test('a getAllHeaders in the listener of a getHeaderPages of the box '
        'goes ahead rather than wait for it; the paging then fails', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);
      final messages = MessagesService(client);
      final pages = <List<int>>[];
      List<ShortMessage>? inner;

      // Waiting for the paging would never end: it goes on only once the
      // listener is done with its page.
      await expectLater(
        inTime(() async {
          await for (final page in messages.getHeaderPages()) {
            pages.add(_ids(page));
            inner ??= await messages.getAllHeaders();
          }
        }()),
        throwsA(restartedHere),
      );

      expect(pages, [
        [10, 9],
      ]);
      expect(_ids(inner!), box);
      expect(actions(server), ['message list', ...wholeBox]);
    });

    test('a getHeaderPages whose listener stops without cancelling does not '
        'hold the box; it fails once its listener goes on', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);
      final messages = MessagesService(client);
      final pages = <List<int>>[];
      final firstPage = Completer<void>();
      final ended = Completer<void>();
      late StreamSubscription<List<ShortMessage>> paging;
      paging = messages.getHeaderPages().listen(
        (page) {
          pages.add(_ids(page));
          paging.pause();
          if (!firstPage.isCompleted) firstPage.complete();
        },
        onError: ended.completeError,
        onDone: ended.complete,
        cancelOnError: true,
      );
      await firstPage.future;

      expect(_ids(await inTime(messages.getAllHeaders())), box);

      paging.resume();
      await expectLater(inTime(ended.future), throwsA(restartedHere));
      expect(pages, [
        [10, 9],
      ]);
      expect(actions(server), ['message list', ...wholeBox]);
    });

    test('a getHeaders of the box between two pages makes the paging fail '
        'before it asks for the next one', () async {
      final server = await serve(_Account({'inbox/0': box}).answer);
      final paging = StreamIterator(MessagesService(client).getHeaderPages());

      expect(await paging.moveNext(), isTrue);
      // On another service of the client, in another order: the next
      // continue_messages would get the second page of that listing.
      await MessagesService(client).getHeaders(sortOrder: SortOrder.asc);

      await expectLater(paging.moveNext(), throwsA(restartedHere));
      expect(actions(server), ['message list', 'message list']);
    });

    test('a getHeaders of the box sent while a page is asked for makes the '
        'paging fail without that page', () async {
      var listed = false;
      final server = await serve(
        _Account({'inbox/0': box}).answer,
        // Smartschool gets the getHeaders before the continue_messages that
        // was on its way, and answers it with the second page of that
        // listing.
        before: (request) async {
          if (request.action != 'continue_messages' || listed) return;
          listed = true;
          await MessagesService(client).getHeaders(sortOrder: SortOrder.asc);
        },
      );

      final pages = await pagesBefore(
        MessagesService(client).getHeaderPages(),
        restartedHere,
      );

      expect(pages, [
        [10, 9],
      ]);
      expect(actions(server), [
        'message list',
        'continue_messages',
        'message list',
      ]);
    });

    test('pagings and listings of different boxes do not wait for or cut '
        'into each other', () async {
      final sentBox = [for (var id = 25; id > 20; id--) id];
      final server = await serve(
        _Account({'inbox/0': box, 'outbox/0': sentBox}).answer,
      );
      final messages = MessagesService(client);
      final inbox = StreamIterator(messages.getHeaderPages());
      final sent = StreamIterator(
        messages.getHeaderPages(boxType: BoxType.sent),
      );
      final ofInbox = <int>[];
      final ofSent = <int>[];

      // Page by page in turns, while the sent box has pages.
      while (await sent.moveNext()) {
        ofSent.addAll(_ids(sent.current));
        if (await inbox.moveNext()) ofInbox.addAll(_ids(inbox.current));
      }
      // A listing of the sent box, then the rest of the inbox.
      await messages.getHeaders(boxType: BoxType.sent);
      while (await inbox.moveNext()) {
        ofInbox.addAll(_ids(inbox.current));
      }

      expect(ofSent, sentBox);
      expect(ofInbox, box);
      expect(server.requests, hasLength(9));
    });

    test('a getAllHeaders that fails, or stops at limit, lets the next one '
        'of the box go', () async {
      final account = _Account({'inbox/0': box});
      var requests = 0;
      final server = await serve(
        (request) => ++requests == 2
            ? '<html><body>Login</body></html>'
            : account.answer(request),
      );
      final messages = MessagesService(client);

      final failing = messages.getAllHeaders();
      final limited = messages.getAllHeaders(limit: 3);
      final whole = messages.getAllHeaders();

      await expectLater(
        inTime(failing),
        throwsA(isA<SmartschoolAuthenticationError>()),
      );
      expect(_ids(await inTime(limited)), [10, 9, 8]);
      expect(_ids(await inTime(whole)), box);
      expect(actions(server), [
        'message list',
        'continue_messages',
        'message list',
        'continue_messages',
        ...wholeBox,
      ]);
    });

    test('getAllArchiveHeaders and a getAllHeaders of the archive box ID '
        'take turns', () async {
      // The folder tree names the archive 208, as live (#141).
      final server = await serve(_Account({'inbox/208': box}).answer);
      final messages = MessagesService(client);

      final results = await inTime(
        Future.wait([
          messages.getAllArchiveHeaders(),
          messages.getAllHeaders(boxId: 208),
        ]),
      );

      expect(results.map(_ids), [box, box]);
      // The tree's request is no listing of the box, so it may go out before
      // or among the pages of the getAllHeaders: only its count is checked.
      expect(
        actions(server).where((a) => a == 'requestmovelist'),
        hasLength(1),
      );
      expect(actions(server).where((a) => a != 'requestmovelist'), [
        ...wholeBox,
        ...wholeBox,
      ]);
    });

    test('another client of the account is not seen coming: its listing '
        'restarts the paging, which fails as in #76', () async {
      // The #76 test above, with a paging on the second client instead of a
      // getHeaders: the first client's paging is not told of it, and only
      // Smartschool's answer shows the restart.
      final account = _Account({'inbox/0': box});
      final (other, otherServer) = await otherSession(account.answer);
      final server = await serve(account.answer);
      final paging = StreamIterator(MessagesService(client).getHeaderPages());

      expect(await paging.moveNext(), isTrue);
      expect(await paging.moveNext(), isTrue);
      expect(await MessagesService(other).getHeaderPages().first, hasLength(2));

      await expectLater(
        paging.moveNext(),
        throwsA(
          restarted.having(
            (e) => e.message,
            'message',
            contains('Smartschool restarted the paging'),
          ),
        ),
      );
      expect(actions(server), [
        'message list',
        'continue_messages',
        'continue_messages',
      ]);
      expect(actions(otherServer), ['message list']);
    });
  });

  test('getHeaders still returns only the first page (#15)', () async {
    final server = await serveFixtures();

    final headers = await MessagesService(client).getHeaders();

    expect(_ids(headers), [6400006, 6400005]);
    expect(server.log, [
      ['message list', _inboxList],
    ]);
  });
}
