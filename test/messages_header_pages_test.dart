// Tests for issue #15: `MessagesService.getHeaders()` and
// `getArchiveHeaders()` return at most 50 headers, the newest 50 of the box,
// with no way to get the older ones.
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
// - The position is kept in the session, one per box: paging the inbox and
//   the sent box in turns works, but any `message list` of a box (also in
//   poll mode) restarts its paging at the second page.
// - Pages are 50 headers, but some pages of the trash held 49, so a short
//   page does not mean the end.
//
// The fake Smartschool below answers from the anonymised fixtures `message
// list more.xml`, `continue_messages.xml` and `continue_messages last.xml`
// (the shape of the live answers, with made-up names), or from pages built
// by `_page`.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:test/test.dart';

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

/// A Smartschool whose XML dispatcher answers `message list` and
/// `continue_messages` with [answer], and whose Messages page (for the
/// archive box ID) is [messagesPage].
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answer, {this.messagesPage = ''});

  final String Function(_Request request) answer;
  final String messagesPage;

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
    return ResponseBody.fromString(
      answer(request),
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
  late Directory cacheDir;
  late SmartschoolClient client;

  Future<_Smartschool> serve(
    String Function(_Request request) answer, {
    String messagesPage = '',
  }) async {
    final server = _Smartschool(answer, messagesPage: messagesPage);
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: cacheDir.path,
    );
    client.dio.httpClientAdapter = server;
    return server;
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

  group('getHeaderPages stops when the paging makes no progress (#15)', () {
    test('a server that repeats the last page, announcing more', () async {
      final last = _page([3, 4], more: true);
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          last,
        ], afterLast: () => last),
      );

      final pages = await MessagesService(client).getHeaderPages().toList();

      expect(pages.map(_ids), [
        [1, 2],
        [3, 4],
      ]);
      expect(server.requests, hasLength(3));
    });

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

      final pages = await MessagesService(client).getHeaderPages().toList();

      expect(pages.map(_ids), [
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
      expect(server.requests, hasLength(4));
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

    test('getAllArchiveHeaders resolves the archive box ID', () async {
      final server = await serve(
        _pages([
          _page([1, 2], more: true, first: true),
          _page([3], more: false),
        ]),
        messagesPage:
            '<div class="postboxsub" boxid="312">'
            '<div class="postbox_ico_sub archive" boxid="312"></div></div>',
      );

      final headers = await MessagesService(client).getAllArchiveHeaders();

      expect(_ids(headers), [1, 2, 3]);
      expect(server.log, [
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
