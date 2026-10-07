// Tests for issue #136: `MessagesService` knew the boxes (`BoxType`) and one
// folder, the archive (`getArchiveBoxId`), but not the folders a user makes
// in Smartschool ("Map toevoegen"), so a caller never found the messages in
// them. `getFolders()` now lists them, the archive among them, as a tree of
// `MessageFolder`s, and a folder is listed with `getHeaders` /
// `getHeaderPages` / `getAllHeaders` and its box ID, as the archive is.
//
// What Smartschool answers, tried live on 2026-10-07 (read-only, apart from
// setting up the test folder): `quickactions` / `requestmovelist` (the
// request of the web client's "move messages" dialog, without params)
// answers with one action, subsystem `triggers`, command
// `moveToPostboxFinnishTreeRequest`, whose `<data>` is the tree as XML-escaped
// JSON. The fixture `quickactions/requestmovelist.xml` is that answer as it
// came in: the boxes a message can be moved to (inbox, sent box, trash) with
// `postboxID` 0 as a number, and their folders, the archive (`"208"`,
// description `msg archive`) and the folder "dartschool test" made for the
// live test (`"30650"`), with string IDs and `parentID` `"-1"`. The tree
// with a folder of the sent box and a folder in a folder (`_nestedTree`) is
// the shape the web client's code expects (its dialog renders `children`
// recursively); Smartschool was not seen answering one.
//
// A `message list` of the folder "dartschool test" answered with its
// messages; and a `message list` of that folder between the second and the
// third page of the archive did not restart the archive's paging: the next
// `continue_messages` of the archive answered with its third page. The fake
// below keeps a paging position per box ID, as that showed.
//
// And for #141: `getArchiveBoxId` found the archive by loading Smartschool's
// whole Messages page (about 95 KB) for its `.postbox_ico_sub.archive`. It
// now takes the archive from the folder tree (about 2 KB), the folder of the
// inbox whose description is `msg archive`, and loads the page only when the
// tree names none (or more than one) or cannot be read; then `208`. Seen live
// on 2026-10-07: the tree and the page both named folder 208.
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

/// Smartschool's answer to `requestmovelist`, as it came in live
/// (2026-10-07).
final _liveAnswer = File(
  'test/fixtures/smartschool/requests/post/quickactions/requestmovelist.xml',
).readAsStringSync();

/// An answer to `requestmovelist` with [tree] (JSON) as the data of its
/// `moveToPostboxFinnishTreeRequest` action, XML-escaped as Smartschool
/// sends it.
String _treeAnswer(String tree) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>triggers</subsystem>'
    '<command>moveToPostboxFinnishTreeRequest</command>'
    '<data>${tree.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;')}</data>'
    '</action></actions></response></server>';

/// A tree in the shape of the live one, with folders the live account does
/// not have: "Projecten" in the inbox with "2026" in it and "Oud" in that,
/// and "Ouders" in the sent box with "Klas 5A" in it. As live, every
/// `parentID` is `-1` and the folders' IDs are strings.
const _nestedTree =
    '[{"postboxID":0,"postboxType":"inbox","parentID":-1,'
    '"postboxName":"Postvak in","postboxDescription":"","children":['
    '{"postboxID":"208","postboxType":"inbox","parentID":"-1",'
    '"postboxName":"Berichten archief","postboxDescription":"msg archive",'
    '"children":[]},'
    '{"postboxID":"501","postboxType":"inbox","parentID":"-1",'
    '"postboxName":"Projecten","postboxDescription":"","children":['
    '{"postboxID":"502","postboxType":"inbox","parentID":"-1",'
    '"postboxName":"2026","postboxDescription":"","children":['
    '{"postboxID":"503","postboxType":"inbox","parentID":"-1",'
    '"postboxName":"Oud","postboxDescription":"","children":[]}]}]}]},'
    '{"postboxID":0,"postboxType":"outbox","parentID":-1,'
    '"postboxName":"Verzonden","postboxDescription":"","children":['
    '{"postboxID":"601","postboxType":"outbox","parentID":"-1",'
    '"postboxName":"Ouders","postboxDescription":"","children":['
    '{"postboxID":"602","postboxType":"outbox","parentID":"-1",'
    '"postboxName":"Klas 5A","postboxDescription":"","children":[]}]}]},'
    '{"postboxID":0,"postboxType":"trash","parentID":-1,'
    '"postboxName":"Prullenmand","postboxDescription":"","children":[]}]';

/// A tree with the inbox alone, holding the folders [folders] (JSON
/// objects), as the live one has them.
String _inboxTree(List<String> folders) =>
    '[{"postboxID":0,"postboxType":"inbox","parentID":-1,'
    '"postboxName":"Postvak in","postboxDescription":"","children":['
    '${folders.join(',')}]},'
    '{"postboxID":0,"postboxType":"outbox","parentID":-1,'
    '"postboxName":"Verzonden","postboxDescription":"","children":[]}]';

/// A folder of a tree: the archive (with the archive's description) when
/// [archive], else a folder the user made.
String _folder(int id, {bool archive = false, String type = 'inbox'}) =>
    '{"postboxID":"$id","postboxType":"$type","parentID":"-1",'
    '"postboxName":"${archive ? 'Berichten archief' : 'Map $id'}",'
    '"postboxDescription":"${archive ? 'msg archive' : ''}","children":[]}';

/// Smartschool's Messages page, trimmed to the archive's entry in its box
/// tree, naming [archive] as the archive folder; one that names none when
/// `null`.
String _messagesPage(int? archive) => archive == null
    ? '<html><body><div class="postbox" boxtype="inbox" boxid="0"></div>'
          '</body></html>'
    : '<html><body><div class="postboxsub" boxtype="inbox" boxid="$archive">'
          '<div class="postbox_ico_sub archive" boxtype="inbox" '
          'boxid="$archive"></div></div></body></html>';

/// A page of a box listing holding a header for each of [ids]: the answer to
/// a `message list` (`rebuild`) when [first], else to a `continue_messages`
/// (`rebuildcontinue`), ending with a `continue_messages` action when [more]
/// and with `rebuildfinish` when not.
String _page(
  List<int> ids, {
  required bool first,
  required bool more,
  String folderName = 'dartschool test',
}) {
  final messages = ids
      .map(
        (id) =>
            '<message><id>$id</id><from>Jan Janssens</from>'
            '<fromImage>https://userpicture20.smartschool.be/User/Userimage/'
            'hashimage/hash/initials_JJ/plain/1/res/32</fromImage>'
            '<subject>Bericht $id</subject><date>2026-10-06 08:29</date>'
            '<status>1</status><attachment>0</attachment><unread>1</unread>'
            '<label>0</label><deleted>0</deleted><allowreply>1</allowreply>'
            '<allowreplyenabled>1</allowreplyenabled><hasreply>0</hasreply>'
            '<hasForward>0</hasForward><realBox>inbox</realBox><sendDate />'
            '</message>',
      )
      .join();
  final changeText = first
      ? '<action><subsystem>message list</subsystem><command>changetext'
            '</command><data><changeTextXml><postboxName>$folderName'
            '</postboxName></changeTextXml></data></action>'
      : '';
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
      '$changeText$end</actions></response></server>';
}

/// Smartschool's answer to a `show message` of message [id].
String _shownMessage(int id) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<server><response><status>ok</status><actions><action>'
    '<subsystem>show message</subsystem><command>rebuild</command><data>'
    '<message><id>$id</id><from>Jan Janssens</from><to/>'
    '<subject>Bericht $id</subject><date>2026-10-06 08:29</date>'
    '<body>&lt;p&gt;Dag&lt;/p&gt;</body><status>1</status>'
    '<attachment>0</attachment><unread>1</unread><label>0</label>'
    '<receivers><to>Yvan Testers</to></receivers><ccreceivers/>'
    '<bccreceivers/><senderPicture>initials_JJ</senderPicture>'
    '<markedInLVS/><fromTeam>0</fromTeam>'
    '<totalNrOtherToReciviers>0</totalNrOtherToReciviers>'
    '<totalnrOtherCcReceivers>0</totalnrOtherCcReceivers>'
    '<totalnrOtherBccReceivers>0</totalnrOtherBccReceivers>'
    '<canReply>1</canReply><hasReply>0</hasReply><hasForward>0</hasForward>'
    '<sendDate/></message></data></action></actions></response></server>';

/// An XML command as it reached the fake Smartschool.
typedef _Command = ({
  String subsystem,
  String action,
  Map<String, String> params,
});

/// A Smartschool whose XML dispatcher answers `requestmovelist` with
/// [folderTree] (the live answer unless a test sets another), and `message
/// list` / `continue_messages` from [boxes] (header IDs by `boxType/boxID`),
/// [pageSize] headers a page, with a paging position per box ID as the live
/// one keeps it; and `show message` with the message asked for. Its Messages
/// page is [messagesPage] (#141).
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.boxes = const {}});

  final Map<String, List<int>> boxes;

  /// The answer to `requestmovelist`.
  String folderTree = _liveAnswer;

  /// The content type of the answer to `requestmovelist`.
  String folderTreeContentType = 'application/xml';

  /// Whether the connection breaks off for `requestmovelist`, before an
  /// answer.
  bool folderTreeFails = false;

  /// The Messages page (`/?module=Messages&file=index&function=main`), where
  /// `getArchiveBoxId` read the archive before #141: one that names no
  /// archive unless a test sets another.
  String messagesPage = _messagesPage(null);

  /// How often the Messages page was loaded.
  int pageLoads = 0;

  /// The headers a page of a box listing holds.
  static const pageSize = 2;

  /// Where the paging of each box (`boxType/boxID`) is: the number of its
  /// headers answered since its last `message list`.
  final Map<String, int> _positions = {};

  /// Every command that reached it, in order.
  final List<_Command> commands = [];

  /// [commands] as `subsystem/action boxType/boxID` lines.
  List<String> get log => [
    for (final c in commands)
      c.params.containsKey('boxID')
          ? '${c.subsystem}/${c.action} '
                '${c.params['boxType']}/${c.params['boxID']}'
          : '${c.subsystem}/${c.action}',
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      expect(
        '${options.uri.path}?${options.uri.query}',
        '/?module=Messages&file=index&function=main',
      );
      pageLoads++;
      return _answer(messagesPage, 'text/html; charset=UTF-8');
    }
    expect(options.method, 'POST');
    expect(
      '${options.uri.path}?${options.uri.query}',
      '/?module=Messages&file=dispatcher',
    );
    final command = (options.data as Map)['command'] as String;
    String tag(String name) =>
        RegExp('<$name>(.*?)</$name>').firstMatch(command)!.group(1)!;
    final params = {
      for (final m in RegExp(
        r'<param name="([^"]+)"><!\[CDATA\[(.*?)\]\]></param>',
      ).allMatches(command))
        m.group(1)!: m.group(2)!,
    };
    final sent = (
      subsystem: tag('subsystem'),
      action: tag('action'),
      params: params,
    );
    commands.add(sent);
    if (commands.length > 30) fail('more than 30 commands: paging loops');
    if (sent.subsystem == 'quickactions' && sent.action == 'requestmovelist') {
      if (folderTreeFails) {
        throw const SocketException('Connection reset by peer');
      }
      return _answer(folderTree, folderTreeContentType);
    }
    expect(sent.subsystem, 'postboxes');
    final box = '${params['boxType']}/${params['boxID']}';
    switch (sent.action) {
      case 'message list':
        _positions[box] = 0;
        return _answer(_nextPage(box, first: true));
      case 'continue_messages':
        return _answer(_nextPage(box, first: false));
      case 'show message':
        return _answer(_shownMessage(int.parse(params['msgID']!)));
    }
    throw StateError('unexpected command ${sent.action}');
  }

  /// The next page of [box] from its position, which it moves on.
  String _nextPage(String box, {required bool first}) {
    final ids = boxes[box] ?? const [];
    final from = _positions[box] ?? ids.length;
    final to = (from + pageSize).clamp(0, ids.length);
    _positions[box] = to;
    return _page(ids.sublist(from, to), first: first, more: to < ids.length);
  }

  static ResponseBody _answer(
    String body, [
    String contentType = 'application/xml',
  ]) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [contentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// [folders] as `(id, boxType, path, isArchive, parentId)` records, to
/// compare with `equals`.
List<(int, BoxType, String, bool, int?)> _shape(List<MessageFolder> folders) =>
    [
      for (final f in MessageFolder.flatten(folders))
        (f.id, f.boxType, f.path.join(' / '), f.isArchive, f.parentId),
    ];

void main() {
  forbidRealNetwork();

  late SmartschoolClient client;

  Future<(MessagesService, _Smartschool)> serve({
    Map<String, List<int>> boxes = const {},
  }) async {
    final server = _Smartschool(boxes: boxes);
    client.dio.httpClientAdapter = server;
    return (MessagesService(client), server);
  }

  setUp(() async {
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
  });

  tearDown(() => client.dispose());

  group('getFolders (#136)', () {
    test('reads the folders of the live answer: the archive and the folder '
        'the user made in the inbox, not the boxes themselves', () async {
      final (messages, server) = await serve();

      final folders = await messages.getFolders();

      expect(folders, hasLength(2));
      final [archive, made] = folders;
      expect(archive.id, 208);
      expect(archive.boxType, BoxType.inbox);
      expect(archive.name, 'Berichten archief');
      expect(archive.description, MessageFolder.archiveDescription);
      expect(archive.isArchive, isTrue);
      expect(archive.parentId, isNull);
      expect(archive.path, ['Berichten archief']);
      expect(archive.children, isEmpty);

      expect(made.id, 30650);
      expect(made.boxType, BoxType.inbox);
      expect(made.name, 'dartschool test');
      expect(made.description, isEmpty);
      expect(made.isArchive, isFalse);
      expect(made.parentId, isNull);
      expect(made.path, ['dartschool test']);
      expect(made.children, isEmpty);

      expect(
        made.toString(),
        'MessageFolder(id: 30650, boxType: inbox, path: "dartschool test", '
        'children: 0)',
      );
      expect(archive.toString(), contains(', archive,'));
    });

    test('sends quickactions / requestmovelist without params, as the web '
        "client's move dialog does, once per call", () async {
      final (messages, server) = await serve();

      await messages.getFolders();
      await messages.getFolders();

      // Not cached: the user can add or remove a folder at any time.
      expect(server.commands, hasLength(2));
      for (final command in server.commands) {
        expect(command.subsystem, 'quickactions');
        expect(command.action, 'requestmovelist');
        expect(command.params, isEmpty);
      }
    });

    test('takes the nesting from children, not from parentID (-1 for every '
        'folder), with the path of each folder, also in the sent box '
        '(the shape the web client expects)', () async {
      final (messages, server) = await serve();
      server.folderTree = _treeAnswer(_nestedTree);

      final folders = await messages.getFolders();

      expect(folders.map((f) => f.name), [
        'Berichten archief',
        'Projecten',
        'Ouders',
      ]);
      expect(_shape(folders), [
        (208, BoxType.inbox, 'Berichten archief', true, null),
        (501, BoxType.inbox, 'Projecten', false, null),
        (502, BoxType.inbox, 'Projecten / 2026', false, 501),
        (503, BoxType.inbox, 'Projecten / 2026 / Oud', false, 502),
        (601, BoxType.sent, 'Ouders', false, null),
        (602, BoxType.sent, 'Ouders / Klas 5A', false, 601),
      ]);
      final projects = folders[1];
      expect(projects.children.single.children.single.path, [
        'Projecten',
        '2026',
        'Oud',
      ]);
    });

    test('flatten lists each folder before the folders in it', () {
      const inner = MessageFolder(
        id: 2,
        boxType: BoxType.sent,
        name: 'b',
        path: ['a', 'b'],
        parentId: 1,
      );
      const outer = MessageFolder(
        id: 1,
        boxType: BoxType.sent,
        name: 'a',
        path: ['a'],
        children: [inner],
      );
      const other = MessageFolder(
        id: 3,
        boxType: BoxType.inbox,
        name: 'c',
        path: ['c'],
      );

      expect(MessageFolder.flatten([outer, other]), [outer, inner, other]);
      expect(MessageFolder.flatten(const []), isEmpty);
    });

    test('returns lists that cannot be changed', () async {
      final (messages, server) = await serve();
      server.folderTree = _treeAnswer(_nestedTree);

      final folders = await messages.getFolders();

      expect(() => folders.add(folders.first), throwsUnsupportedError);
      expect(() => folders[1].children.clear(), throwsUnsupportedError);
      expect(() => folders[1].path.add('x'), throwsUnsupportedError);
    });

    test('a box with no folders gives none; an empty tree gives an empty '
        'list', () async {
      final (messages, server) = await serve();
      server.folderTree = _treeAnswer(
        '[{"postboxID":0,"postboxType":"inbox","parentID":-1,'
        '"postboxName":"Postvak in","postboxDescription":"","children":[]}]',
      );
      expect(await messages.getFolders(), isEmpty);

      server.folderTree = _treeAnswer('[]');
      expect(await messages.getFolders(), isEmpty);
    });

    test('leaves out a box or folder of a box type the library does not '
        'know, with the folders in it; a folder without a postboxType is of '
        'its box', () async {
      final (messages, server) = await serve();
      server.folderTree = _treeAnswer(
        '[{"postboxID":0,"postboxType":"smartbox","postboxName":"Vlaggen",'
        '"children":[{"postboxID":"9","postboxType":"smartbox",'
        '"postboxName":"Rood","children":[]}]},'
        '{"postboxID":0,"postboxType":"inbox","postboxName":"Postvak in",'
        '"children":[{"postboxID":"10","postboxType":"other",'
        '"postboxName":"Vreemd","children":[{"postboxID":"11",'
        '"postboxType":"inbox","postboxName":"Erin","children":[]}]},'
        '{"postboxID":12,"postboxName":"Zonder type"}]}]',
      );

      final folders = await messages.getFolders();

      expect(_shape(folders), [
        (12, BoxType.inbox, 'Zonder type', false, null),
      ]);
    });

    group('throws a SmartschoolParsingError for an answer without a usable '
        'tree', () {
      Future<void> refused(String answer, String what) async {
        final (messages, server) = await serve();
        server.folderTree = answer;
        await expectLater(
          messages.getFolders(),
          throwsA(
            isA<SmartschoolParsingError>().having(
              (e) => e.message,
              'message',
              contains(what),
            ),
          ),
        );
      }

      test('no moveToPostboxFinnishTreeRequest action', () async {
        await refused(
          '<server><response><status>ok</status><actions><action>'
              '<subsystem>triggers</subsystem><command>somethingElse</command>'
              '<data>[]</data></action></actions></response></server>',
          'no moveToPostboxFinnishTreeRequest action',
        );
        await refused(
          '<server><response><status>ok</status><actions/></response>'
              '</server>',
          'no moveToPostboxFinnishTreeRequest action',
        );
      });

      test('the action without the tree as its data', () async {
        await refused(
          '<server><response><status>ok</status><actions><action>'
              '<subsystem>triggers</subsystem>'
              '<command>moveToPostboxFinnishTreeRequest</command>'
              '</action></actions></response></server>',
          'without the folder tree as its data',
        );
        await refused(
          '<server><response><status>ok</status><actions><action>'
              '<subsystem>triggers</subsystem>'
              '<command>moveToPostboxFinnishTreeRequest</command>'
              '<data><tree/></data></action></actions></response></server>',
          'without the folder tree as its data',
        );
      });

      test('data that is not JSON', () async {
        await refused(_treeAnswer(''), 'is not JSON');
        await refused(_treeAnswer('[{"postboxID":0'), 'is not JSON');
      });

      test('a tree that is not a list of boxes', () async {
        await refused(_treeAnswer('{"postboxID":0}'), 'not a list of boxes');
        await refused(_treeAnswer('["inbox"]'), 'a box that is not an object');
      });

      test('children that are not a list of folders', () async {
        await refused(
          _treeAnswer(
            '[{"postboxID":0,"postboxType":"inbox","children":{"a":1}}]',
          ),
          '"children" that are not a list',
        );
        await refused(
          _treeAnswer('[{"postboxID":0,"postboxType":"inbox","children":[1]}]'),
          'a folder that is not an object',
        );
      });

      test('a folder without an ID above 0, or without a name', () async {
        for (final id in ['0', '"0"', '"-1"', '"abc"', 'null', '1.5']) {
          await refused(
            _treeAnswer(
              '[{"postboxID":0,"postboxType":"inbox","children":['
              '{"postboxID":$id,"postboxType":"inbox",'
              '"postboxName":"Map","children":[]}]}]',
            ),
            'a folder without a postboxID above 0',
          );
        }
        await refused(
          _treeAnswer(
            '[{"postboxID":0,"postboxType":"inbox","children":['
            '{"postboxID":"7","postboxType":"inbox","children":[]}]}]',
          ),
          'without a postboxName (postboxID 7)',
        );
      });
    });

    test('an HTML page for an answer is a SmartschoolUnexpectedPageError, '
        'as for every command', () async {
      final (messages, server) = await serve();
      server
        ..folderTree = '<!DOCTYPE html><html><body>Berichten</body></html>'
        ..folderTreeContentType = 'text/html';

      await expectLater(
        messages.getFolders(),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
    });

    test('parseFolders reads the JSON of the tree itself', () {
      final folders = MessagesService.parseFolders(_nestedTree);

      expect(MessageFolder.flatten(folders).map((f) => f.id), [
        208,
        501,
        502,
        503,
        601,
        602,
      ]);
      expect(
        () => MessagesService.parseFolders('nope'),
        throwsA(isA<SmartschoolParsingError>()),
      );
    });
  });

  group('the messages of a folder (#136)', () {
    test('getAllHeaders lists a folder of getFolders by its box type and '
        'ID, and getMessage reads a message in it by its box type', () async {
      final (messages, server) = await serve(
        boxes: {
          'inbox/30650': [6494608, 6490278, 6489974],
        },
      );

      final folder = (await messages.getFolders()).singleWhere(
        (f) => f.name == 'dartschool test',
      );
      final headers = await messages.getAllHeaders(
        boxType: folder.boxType,
        boxId: folder.id,
      );
      final message = await messages.getMessage(
        headers.first.id,
        boxType: folder.boxType,
      );

      expect(headers.map((h) => h.id), [6494608, 6490278, 6489974]);
      expect(headers.map((h) => h.realBox), everyElement('inbox'));
      expect(message?.id, 6494608);
      expect(server.log, [
        'quickactions/requestmovelist',
        'postboxes/message list inbox/30650',
        'postboxes/continue_messages inbox/30650',
        'postboxes/show message',
      ]);
      expect(server.commands.last.params, {
        'msgID': '6494608',
        'boxType': 'inbox',
        'limitList': 'true',
      });
    });

    test('a folder of the sent box is listed with BoxType.sent', () async {
      final (messages, server) = await serve(
        boxes: {
          'outbox/602': [7001],
        },
      );
      server.folderTree = _treeAnswer(_nestedTree);

      final folder = MessageFolder.flatten(
        await messages.getFolders(),
      ).singleWhere((f) => f.path.join('/') == 'Ouders/Klas 5A');
      final headers = await messages.getHeaders(
        boxType: folder.boxType,
        boxId: folder.id,
      );

      expect(headers.map((h) => h.id), [7001]);
      expect(server.commands.last.params, containsPair('boxType', 'outbox'));
      expect(server.commands.last.params, containsPair('boxID', '602'));
    });

    test('listing one folder between two pages of another does not make '
        "the other's paging fail: each keeps its own position, as seen live "
        'with the archive and a folder of the inbox', () async {
      final (messages, server) = await serve(
        boxes: {
          'inbox/208': [1, 2, 3, 4, 5, 6],
          'inbox/30650': [7, 8, 9],
        },
      );
      final folders = await messages.getFolders();
      final archive = folders.singleWhere((f) => f.isArchive);
      final made = folders.singleWhere((f) => !f.isArchive);

      final paging = StreamIterator(
        messages.getHeaderPages(boxType: archive.boxType, boxId: archive.id),
      );
      expect(await paging.moveNext(), isTrue);
      expect(paging.current.map((h) => h.id), [1, 2]);
      expect(await paging.moveNext(), isTrue);
      expect(paging.current.map((h) => h.id), [3, 4]);

      final inFolder = await messages.getHeaders(
        boxType: made.boxType,
        boxId: made.id,
      );
      expect(inFolder.map((h) => h.id), [7, 8]);

      expect(await paging.moveNext(), isTrue);
      expect(paging.current.map((h) => h.id), [5, 6]);
      expect(await paging.moveNext(), isFalse);
      expect(server.log, [
        'quickactions/requestmovelist',
        'postboxes/message list inbox/208',
        'postboxes/continue_messages inbox/208',
        'postboxes/message list inbox/30650',
        'postboxes/continue_messages inbox/208',
      ]);
    });
  });

  group('getArchiveBoxId reads the archive in the folder tree (#141)', () {
    test('the archive of the live answer, with requestmovelist alone: the '
        'Messages page (about 95 KB) is not loaded, also when it would name '
        'another folder; and the ID is cached', () async {
      final (messages, server) = await serve();
      server.messagesPage = _messagesPage(312);

      expect(await messages.getArchiveBoxId(), 208);
      expect(await messages.getArchiveBoxId(), 208);

      expect(server.log, ['quickactions/requestmovelist']);
      expect(server.commands.single.params, isEmpty);
      expect(server.pageLoads, 0);
    });

    test('getArchiveHeaders and getAllArchiveHeaders without a boxId list '
        'the archive the tree names, read once', () async {
      final (messages, server) = await serve(
        boxes: {
          'inbox/312': [1, 2, 3],
        },
      );
      server
        ..folderTree = _treeAnswer(
          _inboxTree([_folder(30650), _folder(312, archive: true)]),
        )
        ..messagesPage = _messagesPage(208);

      final first = await messages.getArchiveHeaders();
      final all = await messages.getAllArchiveHeaders();

      expect(first.map((h) => h.id), [1, 2]);
      expect(all.map((h) => h.id), [1, 2, 3]);
      expect(server.log, [
        'quickactions/requestmovelist',
        'postboxes/message list inbox/312',
        'postboxes/message list inbox/312',
        'postboxes/continue_messages inbox/312',
      ]);
      expect(server.pageLoads, 0);
    });

    group('falls back to the Messages page, as before #141, when the '
        'tree', () {
      /// Checks that getArchiveBoxId, with the tree [folderTree], takes the
      /// archive the Messages page names, after one request of the tree,
      /// and caches it.
      Future<void> fallsBack({
        String? folderTree,
        String contentType = 'application/xml',
        bool fails = false,
      }) async {
        final (messages, server) = await serve();
        server
          ..folderTree = folderTree ?? _liveAnswer
          ..folderTreeContentType = contentType
          ..folderTreeFails = fails
          ..messagesPage = _messagesPage(312);

        expect(await messages.getArchiveBoxId(), 312);
        expect(await messages.getArchiveBoxId(), 312);

        expect(server.log, ['quickactions/requestmovelist']);
        expect(server.pageLoads, 1);
      }

      test('names no archive', () async {
        await fallsBack(folderTree: _treeAnswer(_inboxTree([_folder(30650)])));
        await fallsBack(folderTree: _treeAnswer('[]'));
      });

      test('names more than one archive in the inbox', () async {
        await fallsBack(
          folderTree: _treeAnswer(
            _inboxTree([
              _folder(208, archive: true),
              _folder(312, archive: true),
            ]),
          ),
        );
      });

      test('names a folder with the archive\'s description in the sent box '
          'only: the archive is a folder of the inbox', () async {
        await fallsBack(
          folderTree: _treeAnswer(
            '[{"postboxID":0,"postboxType":"outbox","postboxName":"Verzonden",'
            '"children":[${_folder(208, archive: true, type: 'outbox')}]}]',
          ),
        );
      });

      test('cannot be read: an HTML page, an answer without the tree, a '
          'tree that is not JSON or not a tree of folders', () async {
        await fallsBack(
          folderTree: '<!DOCTYPE html><html><body>Berichten</body></html>',
          contentType: 'text/html',
        );
        await fallsBack(
          folderTree:
              '<server><response><status>ok</status><actions/></response>'
              '</server>',
        );
        await fallsBack(folderTree: _treeAnswer('[{"postboxID":0'));
        await fallsBack(
          folderTree: _treeAnswer(
            '[{"postboxID":0,"postboxType":"inbox","children":[1]}]',
          ),
        );
      });

      test('fails: the connection breaks off', () async {
        await fallsBack(fails: true);
      });
    });

    test('falls back to 208 when neither the tree nor the Messages page '
        'names the archive, and caches that too', () async {
      final (messages, server) = await serve();
      server.folderTree = _treeAnswer(_inboxTree([_folder(30650)]));

      expect(await messages.getArchiveBoxId(), 208);
      expect(await messages.getArchiveBoxId(), 208);

      expect(server.log, ['quickactions/requestmovelist']);
      expect(server.pageLoads, 1);
    });
  });
}
