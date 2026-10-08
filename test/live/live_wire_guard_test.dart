// Tests for LiveWireGuard (support/live_wire_guard.dart), the wire-level
// guard of the live suite (#57), against a fake Smartschool: it lets out
// what the live suite sends to the own account, and refuses everything else
// before it reaches Smartschool.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/add_recipient_answer.dart';
import '../support/no_network.dart';
import '../support/remove_recipient_answer.dart';
import '../support/temp_cache_dir.dart';
import 'support/live_wire_guard.dart';

const _host = 'school.smartschool.be';
const _tag = 'run-20261001-120000-0abc';

/// The own account of the run: user 777 (Jan Janssens) of the recorded
/// reply form.
const _own = MessageSearchUser(userId: 777, displayName: 'Me', ssId: 100);

/// Another user: the sender of message 900030 in the recorded reply form.
const _other = MessageSearchUser(
  userId: 201,
  displayName: 'Piet Peeters',
  ssId: 100,
);

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

final _newMessageForm = _fixture('get/composemessage/new-message.html');
final _sendAnswer = _fixture('post/composemessage/on_send.html');
final _quickDeleteAnswer = _fixture('post/postboxes/quick delete.xml');
final _moveAnswer = _fixture('post/postboxes/quickmove messages.xml');
final _searchAnswer = _fixture('post/composemessage/search-user.xml');

/// The reply form of received message 900030, from [_other].
final _replyFormFromOther = _fixture('get/composemessage/reply.html');

/// The To entry of the sender in [_replyFormFromOther].
const _senderSpan =
    '<div oncontextmenu="disableContext(event); return false;" '
    'typeidatt="users" realuserid="201" idatt="U201" userltatt="0" '
    'typeatt="0" ssidatt="100" selected="no" unselectable="on" '
    'name="receiverPart0" id="receiverPart0_100_U201_0" '
    'class="receiverSpan user">';

/// The reply form of message 900030 as the own account sent it to itself:
/// the form names the own account as the sender.
final _replyFormFromOwn = _replyFormFromOther
    .replaceFirst(_senderSpan, _senderSpan.replaceAll('201', '777'))
    .replaceFirst('>Piet Peeters<', '>Jan Janssens<');

/// The subject of a message of the run.
const _runSubject = '[dartschool test] $_tag send';

const _skoreOwners = '/modules/Skore/backend/models/owners.php';
const _skoreGradebooks = '/modules/Skore/modules/rapportbeheer/rpc/data.php';
const _skoreGradebook = '/modules/Skore/backend/gradebook/rpc.php';

/// The `result` of Skore's answers to its reads (#91, #148), by RPC method,
/// with a made-up teacher and pupil; any other method is answered as a save
/// that went through.
const _skoreResults = {
  'getTeachers': '[{"userID":"1001","name":"Janssens, Jan"}]',
  'getCourses':
      '[{"id":"34826","icon":"IconLib:laptop","name":"Digitale vaardigheden",'
      '"class":"5WW1","readers":[],"writers":[]}]',
  'getNavigation':
      '{"navigation":[{"raw":"3gr D-D/A","children":[{"raw":"6DO","crum":'
      '{"ids":["176","472"]},"data":[],"children":[{"raw":"6EWI","crum":'
      '{"ids":["176","472","2440"]},"data":[{"coursename":"Informatica",'
      '"data":{"ownerID":"32508","userID":"777","classID":"2440",'
      '"groupID":"472","modelID":"176","courseID":"2264"},"part":[]}]}]}]}],'
      '"workyears":[["24","2026-2027"]],"currentWorkyear":"24"}',
  'init':
      '{"periods":[{"id":"1704","name":"DW1","open":1,'
      '"timestamp":"2026-12-18T20:00:00+0100"}],"activePeriodE":0,'
      '"ownerMap":[{"ownerID":"32508","classID":"2440",'
      '"coursename":"Informatica"}],"left_0":{"stream":[{"c":0,'
      '"r":"pupil_1201_2440","v":"<span>1.  Aerts, An</span>"}]}}',
  'getGradebookContext':
      '{"writable":1,"coordinator":0,"classId":2440,"owners":[32508]}',
};

/// The start page, where the client reads the own user (777, #148).
const _startPage =
    r"""<html><body><script>$.extend(true, SMSC, JSON.parse('{"vars":"""
    r"""{"authenticatedUser":{"id":"49_777_0","name":{"startingWithFirstName":"""
    r""""Me","startingWithLastName":"Me"}}}}'));</script></body></html>""";

/// The planner's lookup of a calendar by ID (#127), the one planner POST the
/// live suite sends.
const _plannerLookup = '/planner/api/v1/quick-search/planner/start';

/// The planner's answer to the lookup of class `4069_2001`, trimmed to the
/// class (made up).
const _plannerLookupAnswer =
    '{"selection":[{"identifier":{"id":"4069_2001","type":"group"},'
    '"title":[{"part":"6A1","isHighlighted":false}],"description":[],'
    '"origin":{"groupIdentifier":"4069_2001","name":"6A1",'
    '"description":"6 Latijn 1"}}],"suggestions":[],"favourites":[]}';

/// The Intradesk folders of the fake Smartschool (#128): "2. SMA" at the
/// root with "tests" in it (the folder the live suite may write in), and
/// another root folder with a "tests" of its own.
const _sma = 'aaaa0001-0000-4000-8000-000000000000';
const _tests = 'aaaa0002-0000-4000-8000-000000000000';
const _otherRoot = 'aaaa0003-0000-4000-8000-000000000000';
const _otherTests = 'aaaa0004-0000-4000-8000-000000000000';
const _intradesk = '/intradesk/api/v1/49';

/// The Intradesk folders each listing names, by the folder listed (`''` for
/// the root), as (ID, name).
const _intradeskFolders = {
  '': [(_sma, '2. SMA'), (_otherRoot, 'Andere')],
  _sma: [(_tests, 'tests')],
  _otherRoot: [(_otherTests, 'tests')],
};

/// The fields of a folder of a listing that the creates read before they
/// send anything (#138): an ordinary folder the account may add to.
const _intradeskFolderFields =
    ',"color":"yellow","confidential":false,"inConfidentialFolder":false,'
    '"capabilities":{"canManage":true,"canAdd":true,"canSeeHistory":true,'
    '"canSeeViewHistory":true}';

/// An Intradesk item as Smartschool answers it (#128), with [extra] keys.
String _intradeskItem(
  String id,
  String name,
  String parent, [
  String extra = '',
]) =>
    '{"id":"$id","platform":{"id":49,"name":"Testschool"},"name":"$name",'
    '"state":"active","parentFolderId":"$parent",'
    '"dateStateChanged":"2026-10-05T20:09:03+02:00",'
    '"dateCreated":"2026-10-05T20:09:03+02:00",'
    '"dateChanged":"2026-10-05T20:09:03+02:00"$extra}';

/// The Presence module's answers to its reads (#104, #105), by path, with a
/// made-up pupil; any other Presence request is answered as a save that went
/// through. The account may set the half-days of the class
/// (`userCanConfirm`, #121), so that `setLate` gets as far as its save.
const _presenceAnswers = {
  '/Presence/Main/getConfig':
      '{"hasErrors":false,"errors":[],"state":{"activeClass":null,'
      '"schoolyear":"2026-11-05"},"main":{"allowedClasses":[{"groupID":298,'
      '"name":"1A  ","structID":311,"userCanConfirm":true,'
      '"userCanRecord":true}]}}',
  '/Presence/Code/getAllCodes':
      '[{"codeID":497,"code":"L","name":"Te laat","alias":[]}]',
  '/Presence/Class/getClass':
      '{"groupID":298,"name":"1A  ","structID":311,"userCanRecord":true,'
      '"errorMessage":"","pupils":[{"movementID":35714,"userID":11110,'
      '"name":"Test Pupil","presence":[]}],"saveIsAllowed":true}',
};

/// The recorded answer to a `message list`, with the headers [headers], as
/// (ID, subject), in place of the recorded ones.
String _messageList(List<(int, String)> headers) {
  final recorded = _fixture('post/postboxes/message list.xml');
  final start = recorded.indexOf('<message>');
  final end = recorded.lastIndexOf('</message>') + '</message>'.length;
  final template = recorded.substring(
    start,
    recorded.indexOf('</message>') + '</message>'.length,
  );
  return recorded.replaceRange(
    start,
    end,
    [
      for (final (id, subject) in headers)
        template
            .replaceFirst('<id>123456</id>', '<id>$id</id>')
            .replaceFirst(
              '<subject>Re: LO les</subject>',
              '<subject>$subject</subject>',
            ),
    ].join(),
  );
}

/// Smartschool's answer to `requestmovelist` (#136, #141): the folder tree,
/// as the live answer has it, with [archive] as the archive of the inbox
/// (`postboxDescription` `msg archive`), or none when `null`, beside the
/// folder "dartschool test" (30650). [archiveType] is the box the archive
/// is in, and [secondArchive] another folder of the inbox with the
/// archive's description.
String _folderTree({
  int? archive,
  String archiveType = 'inbox',
  int? secondArchive,
}) {
  String folder(int id, String type, {required bool isArchive}) =>
      '{"postboxID":"$id","postboxType":"$type","parentID":"-1",'
      '"postboxName":"${isArchive ? 'Berichten archief' : 'dartschool test'}",'
      '"postboxDescription":"${isArchive ? 'msg archive' : ''}",'
      '"children":[]}';
  final inbox = [
    if (archive != null && archiveType == 'inbox')
      folder(archive, 'inbox', isArchive: true),
    if (secondArchive != null) folder(secondArchive, 'inbox', isArchive: true),
    folder(30650, 'inbox', isArchive: false),
  ];
  final outbox = [
    if (archive != null && archiveType == 'outbox')
      folder(archive, 'outbox', isArchive: true),
  ];
  final tree =
      '[{"postboxID":0,"postboxType":"inbox","parentID":-1,'
      '"postboxName":"Postvak in","postboxDescription":"","children":'
      '[${inbox.join(',')}]},'
      '{"postboxID":0,"postboxType":"outbox","parentID":-1,'
      '"postboxName":"Verzonden","postboxDescription":"","children":'
      '[${outbox.join(',')}]},'
      '{"postboxID":0,"postboxType":"trash","parentID":-1,'
      '"postboxName":"Prullenmand","postboxDescription":"","children":[]}]';
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<server><response><status>ok</status><actions><action>'
      '<subsystem>triggers</subsystem>'
      '<command>moveToPostboxFinnishTreeRequest</command>'
      '<data>${tree.replaceAll('&', '&amp;').replaceAll('"', '&quot;')}</data>'
      '</action></actions></response></server>';
}

/// A Smartschool that answers the steps of a send, a move to the trash or
/// to the archive, a message list, the folder tree and the Messages page,
/// and records what reaches it.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    required this.replyForm,
    this.answerAdd,
    this.boxes = const {},
    this.archiveFolder,
  });

  /// The reply form of message 900030.
  final String replyForm;

  /// The archive folder of the inbox that the Messages page names, or
  /// `null` for a page that names none; and that the folder tree
  /// (`requestmovelist`) names, unless [folderTree] is set (#141).
  int? archiveFolder;

  /// The answer to `requestmovelist`, when it is not the tree of
  /// [archiveFolder] (#141).
  String? folderTree;

  /// The headers, as (ID, subject), that a `message list` of each box lists,
  /// by `<boxType>/<boxID>` (such as `inbox/0`); other boxes list none.
  final Map<String, List<(int, String)>> boxes;

  /// The answer to `addUserToSelected` with the given fields; the recorded
  /// answer that registers the recipient asked for when `null`.
  final String Function(Map<dynamic, dynamic> fields)? answerAdd;

  /// HTML pages that the dispatcher answers the next XML commands with, one
  /// per command, before it answers them as usual again (#106).
  final List<String> dispatcherPages = [];

  /// Every request that reached it, as `METHOD <path and query>`.
  final List<String> log = [];

  /// The fields of each `addUserToSelected` that reached it.
  final List<Map<dynamic, dynamic>> registered = [];

  /// The fields of each recipient search that reached it (#97).
  final List<Map<dynamic, dynamic>> searched = [];

  /// The fields of each submit that reached it.
  final List<Map<String, String>> submits = [];

  /// The `msgID` of each `quick delete` that reached it.
  final List<String> trashed = [];

  /// Each Skore RPC call that reached it, as `<path> <rpc_method>` (#91).
  final List<String> skoreCalls = [];

  /// Each `quickmove messages` that reached it, as `<boxType> <msgID>`, or
  /// `<boxType>/<boxID> <msgID>` out of a folder.
  final List<String> moved = [];

  /// The IDs of each move to the archive that reached it.
  final List<List<int>> archived = [];

  /// Each change of the read state or the flag of a message that reached it,
  /// as `<action> <boxType> <msgID>` for a command that names no folder, or
  /// `<action> <boxType>/<boxID> <msgID>` for one that names it (#94).
  final List<String> marked = [];

  /// How many Intradesk items and upload directories it made (#128).
  int _made = 0;

  /// The kind (`folders`, `weblinks`, `files`) of each Intradesk item it
  /// made, by ID: it answers a move to the trash of another ID, or of one as
  /// another kind, with `404`, as Intradesk does (#133).
  final Map<String, String> _intradeskKinds = {};

  /// Each Intradesk POST and upload that reached it, as `POST <path>`.
  List<String> get intradeskWrites => [
    for (final line in log)
      if (line.startsWith('POST /intradesk/') ||
          line == 'POST /Upload/Upload/Index')
        line,
  ];

  /// The folders it made, by ID, as (parent, name) (#138): its listings and
  /// the parents hold them until they are moved to the trash.
  final Map<String, (String, String)> _intradeskMadeFolders = {};

  /// The IDs of the Intradesk items it moved to the trash.
  final Set<String> _intradeskTrashed = {};

  /// The parent of the Intradesk folder [id] (`''` at the root), or `null`
  /// for an ID it has no folder for.
  String? _intradeskParentOf(String id) {
    for (final MapEntry(key: listed, value: folders)
        in _intradeskFolders.entries) {
      if (folders.any((f) => f.$1 == id)) return listed;
    }
    return _intradeskMadeFolders[id]?.$1;
  }

  /// Answers an Intradesk request or a request for an upload directory
  /// (#128): the listings of [_intradeskFolders] and of the folders it made,
  /// the parents of a folder (`[]` for one in the trash, as Smartschool,
  /// #132), a new directory, and the creates and moves to the trash as
  /// Smartschool answers them (a move to the trash of an ID it has no such
  /// item for with `404`, #133).
  ResponseBody _intradeskAnswer(RequestOptions options) {
    final path = options.uri.path;
    const listing = '$_intradesk/directory-listing/forTreeOnlyFolders';
    const notFound = '{"status":404,"title":"Not Found","detail":"","type":""}';
    if (options.method == 'GET') {
      if (path == '/upload/api/v1/get-upload-directory') {
        return _answer(
          '{"uploadDir":"dir${++_made}"}',
          contentType: 'application/json',
        );
      }
      final parents = RegExp(
        '^$_intradesk/folders/([^/]+)/parents\$',
      ).firstMatch(path);
      if (parents != null) {
        final id = parents.group(1)!;
        if (_intradeskTrashed.contains(id)) {
          return _answer('[]', contentType: 'application/json');
        }
        final chain = <String>[];
        for (var at = _intradeskParentOf(id); at != null && at.isNotEmpty;) {
          chain.insert(0, at);
          at = _intradeskParentOf(at);
        }
        if (_intradeskParentOf(id) == null) {
          return _answer(
            notFound,
            contentType: 'application/problem+json',
            status: 404,
          );
        }
        return _answer(jsonEncode(chain), contentType: 'application/json');
      }
      final listed = path == listing
          ? ''
          : path.startsWith('$listing/')
          ? path.substring(listing.length + 1)
          : null;
      final folders = [
        ...?_intradeskFolders[listed],
        for (final MapEntry(key: id, value: (parent, name))
            in _intradeskMadeFolders.entries)
          if (parent == listed && !_intradeskTrashed.contains(id)) (id, name),
      ];
      return _answer(
        '{"folders":[${[for (final (id, name) in folders) _intradeskItem(id, name, listed ?? '', _intradeskFolderFields)].join(',')}],'
        '"files":[],"weblinks":[]}',
        contentType: 'application/json',
      );
    }
    final body = options.data is Map ? options.data as Map : const {};
    final parent = '${body['parentFolderId']}';
    final id =
        'bbbb${(++_made).toString().padLeft(4, '0')}-0000-4000-8000-000000000000';
    if (path == '$_intradesk/folders/') {
      _intradeskKinds[id] = 'folders';
      _intradeskMadeFolders[id] = (parent, '${body['name']}');
      return _answer(
        _intradeskItem(id, '${body['name']}', parent, ',"color":"yellow"'),
        contentType: 'application/json',
        status: 201,
      );
    }
    if (path == '$_intradesk/weblinks/') {
      _intradeskKinds[id] = 'weblinks';
      return _answer(
        _intradeskItem(
          id,
          '${body['name']}',
          parent,
          ',"url":"${body['url']}"',
        ),
        contentType: 'application/json',
        status: 201,
      );
    }
    if (path == '$_intradesk/files/upload') {
      _intradeskKinds[id] = 'files';
      return _answer(
        '{"files":{"$id":${_intradeskItem(id, '$liveFilePrefix$_tag.txt', parent)}},'
        '"exceptions":[]}',
        contentType: 'application/json',
        status: 201,
      );
    }
    final trash = RegExp(
      '^$_intradesk/(folders|weblinks|files)/([^/]+)/trash\$',
    ).firstMatch(path);
    if (trash != null) {
      if (_intradeskKinds[trash.group(2)] == trash.group(1)) {
        _intradeskTrashed.add(trash.group(2)!);
        return _answer('', status: 204);
      }
      return _answer(
        notFound,
        contentType: 'application/problem+json',
        status: 404,
      );
    }
    return _answer('{}', contentType: 'application/json');
  }

  /// The lesfiches it made (#129), each as its detail, by ID.
  final Map<String, Map<String, Object?>> lessonContent = {};

  /// Each Lesfiches write and upload that reached it, as `METHOD <path>`.
  List<String> get lessonContentWrites => [
    for (final line in log)
      if (line.startsWith('POST /lesson-content/') ||
          line.startsWith('DELETE /lesson-content/') ||
          line == 'POST /Upload/Upload/Index')
        line,
  ];

  /// A new UUID of the fake.
  String _uuid() =>
      'dddd${(++_made).toString().padLeft(4, '0')}-0000-4000-8000-000000000000';

  /// Answers a request to the Lesfiches module (#129) as the module does,
  /// keeping the lesfiches it made: a create with the new ID only, the
  /// detail of a lesfiche, an edit with the lesfiche, a weblink with the
  /// weblink, a removal with `204`, and a move to the trash with no
  /// exceptions.
  ResponseBody _lessonContentAnswer(RequestOptions options) {
    const api = '/lesson-content/api/v1/';
    const json = 'application/json';
    final path = options.uri.path.substring(api.length);
    final body = options.data is Map ? options.data as Map : const {};
    if (path == 'lessons/' || path == 'assignments/') {
      final id = _uuid();
      lessonContent[id] = {
        'id': id,
        'platformId': 49,
        'name': body['name'],
        'icon': body['icon'],
        'publicInfo': body['publicInfo'],
        'privateInfo': body['privateInfo'],
        'isVisible': true,
        'owner': '49_777_0',
        'courses': body['courses'],
        'labels': [],
        'weblinks': [
          for (final link in body['weblinks'] as List)
            {...link as Map, 'id': _uuid()},
        ],
        'attachments': [
          for (final MapEntry(:key, :value)
              in (body['visibilityOptions'] as Map).entries)
            {'id': _uuid(), 'fileName': key, 'visibility': value},
        ],
        'type': path.substring(0, path.length - 1),
      };
      return _answer('{"id":"$id"}', contentType: json, status: 201);
    }
    if (path == 'lesson-content/trash/bulk') {
      return _answer('{"exceptions":[]}', contentType: json);
    }
    if (path == 'assignments/applicable-assignment-types') {
      return _answer(
        '[{"id":"a0000000-0000-4000-8000-000000000004","platformId":49,'
        '"name":"Kleine Taak","abbreviation":"KT","isVisible":true,'
        '"defaultTiming":"deadline","weight":0}]',
        contentType: json,
      );
    }
    final match = RegExp(
      r'^(lessons|assignments)/([^/]+)(?:/(.*))?$',
    ).firstMatch(path);
    final fiche = lessonContent[match?.group(2)];
    if (fiche == null) {
      return _answer(
        '{"status":404,"title":"Not Found","detail":"","type":""}',
        contentType: json,
        status: 404,
      );
    }
    final action = match!.group(3);
    if (options.method == 'DELETE') {
      final [kind, id] = action!.split('/');
      (fiche[kind] as List).removeWhere((item) => (item as Map)['id'] == id);
      return _answer('', status: 204);
    }
    switch (action) {
      case 'rename':
        fiche['name'] = body['newName'];
      case 'mark-as-visible' || 'mark-as-invisible':
        fiche['isVisible'] = action == 'mark-as-visible';
      case 'weblinks':
        final link = {
          'id': _uuid(),
          'name': body['newName'],
          'url': body['newUrl'],
          'icon': body['newIcon'],
          'visibility': body['newVisibility'],
        };
        (fiche['weblinks'] as List).add(link);
        return _answer(jsonEncode(link), contentType: json);
    }
    return _answer(jsonEncode(fiche), contentType: json);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    log.add(
      '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
    );
    final query = uri.queryParameters;
    final post = options.method == 'POST';
    switch ((post, uri.path, query['file'], query['function'])) {
      case (false, '/', 'composeMessage', _):
        return _answer(
          query['composeType'] == '0' ? _newMessageForm : replyForm,
        );
      case (true, '/', 'composeMessage', _):
        submits.add({
          for (final field in (options.data as FormData).fields)
            field.key: field.value,
        });
        return _answer(_sendAnswer);
      case (true, '/', 'searchUsers', 'addUserToSelected'):
        final fields = options.data as Map;
        registered.add(fields);
        return _answer(
          (answerAdd ?? registeredRecipientAnswer)(fields),
          contentType: registeredRecipientContentType,
        );
      case (true, '/', 'searchUsers', 'deleteUsersFromSelected'):
        return _answer(
          removedRecipientsAnswer((options.data as Map)['xml'] as String),
          contentType: removedRecipientContentType,
        );
      case (true, '/', 'searchUsers', null):
        searched.add(options.data as Map);
        return _answer(_searchAnswer, contentType: 'text/xml');
      case (true, '/Upload/Upload/Index', _, _):
        return _answer('true');
      case (true, final path, _, _) when path.startsWith('/Presence/'):
        return _answer(
          _presenceAnswers[path] ?? '{"hasErrors":false,"errors":[]}',
          contentType: 'application/json',
        );
      case (true, final path, _, _) when path.startsWith('/modules/Skore/'):
        final method = (options.data as Map)['rpc_method'];
        skoreCalls.add('$path $method');
        return _answer(
          '{"result":${_skoreResults[method] ?? '{"state":1}'},"session":1}',
          contentType: 'application/json',
        );
      case (true, _plannerLookup, _, _):
        return _answer(_plannerLookupAnswer, contentType: 'application/json');
      case (false, '/course-list/api/v1/courses', _, _):
        return _answer('[{"platformId":49}]', contentType: 'application/json');
      case (false, '/', null, null) when query.isEmpty:
        return _answer(_startPage);
      case (_, final path, _, _)
          when path.startsWith('/intradesk/') ||
              path == '/upload/api/v1/get-upload-directory':
        return _intradeskAnswer(options);
      case (_, final path, _, _)
          when path.startsWith('/lesson-content/api/v1/'):
        return _lessonContentAnswer(options);
      case (false, '/', 'index', 'main'):
        final folder = archiveFolder;
        return _answer(
          folder == null
              ? '<html><body>Berichten</body></html>'
              : '<div class="postboxsub" boxtype="inbox" boxid="$folder">'
                    '<div class="postbox_ico_sub archive" boxtype="inbox" '
                    'boxid="$folder"></div></div>',
        );
      case (true, '/Messages/Xhr/archivemessages', _, _):
        final ids = [
          for (final match in RegExp(
            r'msgIDs%5B%5D=(\d+)',
          ).allMatches(options.data as String))
            int.parse(match.group(1)!),
        ];
        archived.add(ids);
        return _answer(
          '{"success":[${ids.join(',')}]}',
          contentType: 'application/json',
        );
      case (true, '/', 'dispatcher', _) when dispatcherPages.isNotEmpty:
        return _answer(dispatcherPages.removeAt(0));
      case (true, '/', 'dispatcher', _):
        final command = (options.data as Map)['command'] as String;
        if (command.contains('<action>requestmovelist</action>')) {
          return _answer(
            folderTree ?? _folderTree(archive: archiveFolder),
            contentType: 'text/xml',
          );
        }
        final id = RegExp(r'name="msgID"><!\[CDATA\[(\d+)').firstMatch(command);
        if (command.contains('<action>quick delete</action>')) {
          trashed.add(id!.group(1)!);
          return _answer(
            _quickDeleteAnswer.replaceFirst('123', id.group(1)!),
            contentType: 'text/xml',
          );
        }
        final box = RegExp(
          r'name="boxType"><!\[CDATA\[(\w+)',
        ).firstMatch(command)?.group(1);
        final folder = RegExp(
          r'name="boxID"><!\[CDATA\[(\d+)',
        ).firstMatch(command)?.group(1);
        if (command.contains('<action>quickmove messages</action>')) {
          final from = folder == '0' ? '$box' : '$box/$folder';
          moved.add('$from ${id!.group(1)}');
          return _answer(_moveAnswer, contentType: 'text/xml');
        }
        if (command.contains('<action>message list</action>')) {
          return _answer(
            _messageList(boxes['$box/$folder'] ?? const []),
            contentType: 'text/xml',
          );
        }
        final mark = RegExp(
          '<action>(mark message read|mark message unread|save msglabel)'
          '</action>',
        ).firstMatch(command)?.group(1);
        if (mark != null) {
          final where = folder == null ? '$box' : '$box/$folder';
          marked.add('$mark $where ${id!.group(1)}');
        }
        return _answer(
          '<server><response><status>ok</status><actions><action><data>'
          '<messages/></data></action></actions></response></server>',
          contentType: 'text/xml',
        );
    }
    return _answer('<html><body>ok</body></html>');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _answer(
  String body, {
  String contentType = 'text/html; charset=UTF-8',
  int status = 200,
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
  },
);

/// A client on [server] with a [LiveWireGuard] for the own account (none
/// when [own] is `false`) that records its violations instead of failing the
/// test.
Future<(MessagesService, LiveWireGuard)> _guarded(
  _Smartschool server, {
  bool own = true,
  int maxSubmits = 6,
}) async {
  final (client, guard) = await _guardedClient(
    server,
    own: own,
    maxSubmits: maxSubmits,
  );
  return (MessagesService(client), guard);
}

/// The client of [_guarded] itself, for another service than Messages.
Future<(SmartschoolClient, LiveWireGuard)> _guardedClient(
  _Smartschool server, {
  bool own = true,
  int maxSubmits = 6,
  int maxIntradeskCreates = 6,
  int maxLessonContentCreates = 2,
}) async {
  final client = await SmartschoolClient.create(
    AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  final guard = LiveWireGuard(
    host: _host,
    runTag: _tag,
    maxSubmits: maxSubmits,
    maxIntradeskCreates: maxIntradeskCreates,
    maxLessonContentCreates: maxLessonContentCreates,
    onViolation: (_) {},
  );
  client.dio.interceptors.add(guard);
  if (own) guard.own = _own;
  return (client, guard);
}

/// A bare Dio on [server] with [guard], for requests the library does not
/// make.
Dio _dio(_Smartschool server, LiveWireGuard guard) {
  final dio = Dio(BaseOptions(baseUrl: 'https://$_host'))
    ..httpClientAdapter = server
    ..interceptors.add(guard);
  addTearDown(dio.close);
  return dio;
}

/// The create of a folder named [name] in [parent], sent bare through
/// [guard] as `IntradeskService.createFolder` sends it, without its read of
/// the parent: since #138 the service reads the parent first and refuses a
/// parent it does not find (a made-up ID, a folder in the trash) itself,
/// and that read lists folders through the guard. The guard must refuse
/// such a create on the wire as well.
Future<Response<String>> _bareFolderCreate(
  _Smartschool server,
  LiveWireGuard guard, {
  required String parent,
  required String name,
}) => _dio(server, guard).post<String>(
  '$_intradesk/folders/',
  data: {
    'name': name,
    'color': 'yellow',
    'parentFolderId': parent,
    'platform': {'id': 49},
  },
);

SendMessageParams _params({
  List<MessageSearchUser> to = const [_own],
  List<MessageSearchUser> cc = const [],
  List<MessageSearchUser> bcc = const [],
  List<MessageSearchGroup> toGroups = const [],
  String subject = '[dartschool test] $_tag send',
  List<String> attachmentPaths = const [],
  MessageSendOptions options = const MessageSendOptions(),
}) => SendMessageParams(
  to: to,
  cc: cc,
  bcc: bcc,
  toGroups: toGroups,
  subject: subject,
  bodyHtml: '<p>Live test.</p>',
  attachmentPaths: attachmentPaths,
  options: options,
);

/// A file [name] in a temporary folder, deleted after the test.
File _tempFile(String name) {
  final dir = Directory.systemTemp.createTempSync('live_wire_guard_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return File(p.join(dir.path, name))..writeAsStringSync('attachment');
}

/// The violations of [guard], as text.
List<String> _violations(LiveWireGuard guard) =>
    guard.violations.map((v) => v.message).toList();

/// The name of an Intradesk folder or weblink of the run (#128).
String _intradeskName(String what) => '$liveIntradeskPrefix $_tag $what';

/// The name of a lesfiche of the run (#129).
String _lessonName(String what) => '$liveLessonContentPrefix $_tag $what';

/// An [IntradeskService] on a guarded client of [server] (#128), which has
/// read the root and "2. SMA" through the guard, and allowed the test folder
/// when [allow].
Future<(IntradeskService, LiveWireGuard)> _intradeskRun(
  _Smartschool server, {
  bool allow = true,
  int maxIntradeskCreates = 6,
}) async {
  final (client, guard) = await _guardedClient(
    server,
    maxIntradeskCreates: maxIntradeskCreates,
  );
  final intradesk = IntradeskService(client);
  await intradesk.getRootListing();
  await intradesk.getFolderListing(_sma);
  if (allow) guard.allowIntradeskFolder(_tests);
  return (intradesk, guard);
}

void main() {
  forbidRealNetwork();

  test('the recorded reply form names the sender as these tests expect', () {
    expect(_replyFormFromOther, contains(_senderSpan));
    expect(_replyFormFromOwn, isNot(contains(_senderSpan)));
  });

  test('the live suite calls no moveToTrash, which sends a quick delete: the '
      'guard would refuse it on the wire (#61)', () {
    // This file calls it, to check that the guard refuses it.
    final suite = [
      for (final file in Directory(
        p.join('test', 'live'),
      ).listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            p.basename(file.path) != 'live_wire_guard_test.dart')
          file,
    ];
    final call = RegExp(r'\.moveToTrash\s*\(');

    expect(
      suite.map((file) => p.basename(file.path)),
      containsAll(['messages_live_test.dart', 'live_run.dart']),
    );
    expect([
      for (final file in suite)
        if (call.hasMatch(file.readAsStringSync())) file.path,
    ], isEmpty);
  });

  group('lets out', () {
    test('a message to the own account, in To, CC and BCC', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await messages.sendMessage(_params(cc: [_own], bcc: [_own]));

      expect(server.registered.map((f) => (f['id'], f['type'])), [
        ('777', '0'),
        ('777', '2'),
        ('777', '3'),
      ]);
      expect(server.submits, hasLength(1));
      expect(guard.submits, 1);
      expect(guard.violations, isEmpty);
    });

    test('a reply to a message the run sent to the own account only, also '
        'one that moves the own account from To to CC', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      guard.allowReplyTo(900030);
      const subject = 'Re: [dartschool test] $_tag reply';

      await messages.sendReply(900030, _params(subject: subject));
      await messages.sendReply(
        900030,
        _params(to: [], cc: [_own], subject: subject),
      );
      await messages.sendReply(900030, _params(subject: subject), all: true);

      expect(server.submits.map((s) => s['composeType']), ['1', '1', '2']);
      expect(server.registered.map((f) => (f['id'], f['type'])), [
        ('777', '2'),
      ]);
      expect(guard.violations, isEmpty);
    });

    test('an attachment the run made', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      final file = _tempFile('${liveFilePrefix}x.txt');

      await messages.sendMessage(_params(attachmentPaths: [file.path]));

      expect(server.log, contains('POST /Upload/Upload/Index'));
      expect(server.submits, hasLength(1));
      expect(guard.violations, isEmpty);
    });

    test('a move to the trash of the sent-box copy, and then of the inbox '
        'copy, of a message the run sent, listed and checked in each box, '
        'once each (#60, #61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'outbox/0': [(4242, _runSubject)],
          'inbox/0': [(4242, 'Re: $_runSubject'), (5555, 'Hello')],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders();
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox);

      // The second move goes out with the sent-box copy in the trash: it
      // names its box, the inbox.
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox);

      expect(server.moved, ['outbox 4242', 'inbox 4242']);
      expect(guard.trashMoveAnswers.keys, [(4242, 'outbox'), (4242, 'inbox')]);
      expect(guard.trashMoveAnswers.values, everyElement(_moveAnswer));
      expect(guard.violations, isEmpty);
    });

    test('a move to the archive of the inbox copy of a message the run sent, '
        'listed and checked in the inbox; then a move to the trash of its '
        'sent-box copy, and of its archived copy out of the archive folder '
        'that Smartschool names (the folder tree that getArchiveBoxId reads, '
        '#141), listed and checked there, once each (#64)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (5555, 'Hello')],
          'outbox/0': [(4242, _runSubject)],
          'inbox/312': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      guard.allowArchive(4242);

      final archiveBoxId = await messages.getArchiveBoxId();
      final archived = await messages.moveToArchive([4242]);
      await messages.getArchiveHeaders(boxId: archiveBoxId);
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox, boxId: archiveBoxId);
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await messages.moveToTrashFrom(
        4242,
        boxType: BoxType.inbox,
        boxId: archiveBoxId,
      );

      expect(archiveBoxId, 312);
      expect(guard.archiveBoxId, 312);
      // The guard learned it from the tree: no Messages page was loaded.
      expect(server.log.where((l) => l.contains('function=main')), isEmpty);
      expect(archived.map((c) => (c.id, c.newValue)), [(4242, 1)]);
      expect(server.archived, [
        [4242],
      ]);
      expect(guard.archiveAnswers, {4242: '{"success":[4242]}'});
      expect(server.moved, ['outbox 4242', 'inbox/312 4242']);
      expect(guard.trashMoveAnswers.keys, [(4242, 'outbox'), (4242, 'inbox')]);
      expect(guard.violations, isEmpty);
    });

    test('marking the inbox copy of a message the run sent unread and read, '
        'and flagging it, listed and checked in the inbox, and after a move '
        'to the archive in the archive folder that Smartschool names (the '
        'folder tree, #141); markUnread names the folder, markRead and '
        'setLabel name none (#94)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (5555, 'Hello')],
          'inbox/312': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      guard
        ..allowMark(4242)
        ..allowArchive(4242);

      await messages.markUnread(4242);
      await messages.markRead(4242);
      await messages.setLabel(4242, MessageLabel.redFlag);
      final archiveBoxId = await messages.getArchiveBoxId();
      await messages.moveToArchive([4242]);
      // The inbox no longer lists it: only the archive folder's list does.
      await messages.getArchiveHeaders(boxId: archiveBoxId);
      await messages.markUnread(4242, boxId: archiveBoxId);
      await messages.markRead(4242);
      await messages.setLabel(4242, MessageLabel.noFlag);

      expect(server.marked, [
        'mark message unread inbox/0 4242',
        'mark message read inbox 4242',
        'save msglabel inbox 4242',
        'mark message unread inbox/312 4242',
        'mark message read inbox 4242',
        'save msglabel inbox 4242',
      ]);
      expect(guard.markAnswers.map((a) => (a.action, a.id)), [
        ('mark message unread', 4242),
        ('mark message read', 4242),
        ('save msglabel', 4242),
        ('mark message unread', 4242),
        ('mark message read', 4242),
        ('save msglabel', 4242),
      ]);
      expect(guard.violations, isEmpty);
    });

    test('the archive folder is learned from the folder tree that '
        'getArchiveBoxId reads (requestmovelist, #141), without a Messages '
        'page: a tree that names none, one the guard cannot read and an '
        'archive in the sent box name none; a tree that names another '
        'archive, or two, makes the guard trust none', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/312': [(4242, _runSubject), (3333, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      // The tree's request as getFolders sends it, through [through] (the
      // guard of messages by default), answered with [answer].
      Future<void> tree(String answer, [LiveWireGuard? through]) async {
        server.folderTree = answer;
        await _dio(server, through ?? guard).post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(
              'quickactions',
              'requestmovelist',
              {},
            ),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
      }

      await tree(_folderTree());
      await tree(_folderTree(archive: 312, archiveType: 'outbox'));
      await tree('<html><body>Berichten</body></html>');
      await tree(
        '<server><response><status>ok</status><actions><action>'
        '<subsystem>triggers</subsystem>'
        '<command>moveToPostboxFinnishTreeRequest</command>'
        '<data>[{</data></action></actions></response></server>',
      );
      expect(guard.archiveBoxId, isNull);

      server.folderTree = null; // The tree of archiveFolder, 312.
      expect(await messages.getArchiveBoxId(), 312);
      expect(guard.archiveBoxId, 312);
      await messages.getHeaders(boxId: 312);
      guard
        ..allowTrashFrom(4242, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(3333, BoxType.inbox, boxId: 312);
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 312);

      // A tree that names another archive folder: the guard trusts neither,
      // and refuses a move it let out until then.
      await tree(_folderTree(archive: 400));
      expect(guard.archiveBoxId, isNull);
      await expectLater(
        messages.moveToTrashFrom(3333, boxType: BoxType.inbox, boxId: 312),
        throwsA(anything),
      );

      // A tree that names two archive folders of the inbox, on another
      // guard: a tree that names one of them afterwards does not make it
      // trust that one.
      final (_, fresh) = await _guarded(server);
      await tree(_folderTree(archive: 312, secondArchive: 400), fresh);
      await tree(_folderTree(archive: 312), fresh);
      expect(fresh.archiveBoxId, isNull);
      expect(fresh.violations, isEmpty);

      expect(server.log.where((l) => l.contains('function=main')), isEmpty);
      expect(server.moved, ['inbox/312 4242']);
      expect(_violations(guard), [
        contains(
          'it moves message 3333 out of a folder of the inbox that is not the '
          'archive folder of the inbox',
        ),
      ]);
    });

    test('reading: message lists, messages, attachments', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.trash);
      await messages.getMessage(4242);
      await messages.getAttachments(4242);
      await messages.getReplyRecipients(4242);

      expect(server.log, hasLength(5));
      expect(guard.requestsSent, 5);
      expect(guard.violations, isEmpty);
      expect(guard.unexpectedAnswers, isEmpty);
    });

    test('an answer to an XML command that is not XML, which it keeps with '
        'what the page is, without its scripts (#106)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn)
        ..dispatcherPages.addAll([
          '\n<!DOCTYPE html><html><head><title>Springfield Academy - '
              'Smartschool</title></head><body><h1>Storing</h1><p>Probeer het '
              'later opnieuw.</p><script>var user = "Jan Janssens";</script>'
              '</body></html>',
          'Fatal error',
        ]);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.getHeaders(),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      await expectLater(
        messages.getMessage(4242),
        throwsA(isA<SmartschoolParsingError>()),
      );
      await messages.getHeaders();

      expect(guard.unexpectedAnswers, [
        'Smartschool answered "message list" with something that is not XML '
            '(#106): status 200, text/html; charset=UTF-8, not its login page, '
            'title "Springfield Academy - Smartschool", heading "Storing", text '
            '"Storing Probeer het later opnieuw."',
        'Smartschool answered "show message" with something that is not XML '
            '(#106): status 200, text/html; charset=UTF-8, not its login page, '
            'text "Fatal error"',
      ]);
      expect(server.log, hasLength(3));
      expect(guard.violations, isEmpty);
    });

    test('the read of the folder tree (quickactions / requestmovelist, '
        'MessagesService.getFolders, #136)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn)
        ..dispatcherPages.add(
          File(
            'test/fixtures/smartschool/requests/post/quickactions/'
            'requestmovelist.xml',
          ).readAsStringSync(),
        );
      final (messages, guard) = await _guarded(server);

      final folders = await messages.getFolders();

      expect(folders.map((f) => f.id), [208, 30650]);
      expect(server.log, ['POST /?module=Messages&file=dispatcher']);
      expect(guard.violations, isEmpty);
    });

    test('the Presence reads: the config, the pupils of a class on a day '
        '(#104), and the codes of a school structure (#105)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final presence = PresenceService(client);

      final config = await presence.getConfig();
      final pupils = await presence.getClassPupils(
        classGroupId: 298,
        date: DateTime(2026, 10, 1),
        schoolyearRefDate: config.schoolyearRefDate,
      );
      final codes = await presence.getAllCodes(311);

      expect(pupils.single.userId, 11110);
      expect(codes.single.name, 'Te laat');
      expect(server.log, [
        'POST /Presence/Main/getConfig',
        'POST /Presence/Class/getClass',
        'POST /Presence/Code/getAllCodes',
      ]);
      expect(guard.violations, isEmpty);
    });

    test('the Skore reads: the teachers and the gradebooks of a teacher '
        '(#91)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final skore = SkoreService(client);

      final teachers = await skore.getTeachers();
      final gradebooks = await skore.getGradebookShares(146);

      expect(teachers.single.id, 1001);
      expect(gradebooks.single.gradebookId, 34826);
      expect(server.skoreCalls, [
        '$_skoreOwners getTeachers',
        '$_skoreGradebooks getCourses',
      ]);
      expect(guard.violations, isEmpty);
    });

    test("the Skore reads of the teacher's own gradebook (#148)", () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final gradebooks = SkoreGradebookService(client);

      final books = await gradebooks.getGradebooks();
      final sheet = await gradebooks.getGradebook(books.single);

      expect(books.single.gradebookId, 32508);
      expect(sheet.pupils.single.name, 'Aerts, An');
      expect(sheet.writable, isTrue);
      expect(server.skoreCalls, [
        '$_skoreGradebook getNavigation',
        '$_skoreGradebook init',
        '$_skoreGradebook getGradebookContext',
      ]);
      expect(guard.violations, isEmpty);
    });

    test('the planner\'s lookup of a calendar by ID (#127)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);

      final klas = await PlannerService(
        client,
      ).getCalendar(PlannerCalendar.group('4069_2001'));

      expect(klas!.name, '6A1');
      expect(server.log, ['POST $_plannerLookup']);
      expect(guard.violations, isEmpty);
    });

    test('a recipient search on a compose form loaded through it, which '
        'registers no one (#97)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      final (users, _) = await messages.searchRecipientsForCompose('John');

      expect(users.map((u) => u.userId), contains(146));
      expect(server.log, [
        'GET /?module=Messages&file=composeMessage&boxType=inbox'
            '&composeType=0&msgID=undefined',
        'POST /?module=Messages&file=searchUsers',
      ]);
      expect(server.searched.single['val'], 'John');
      expect(server.registered, isEmpty);
      expect(guard.searches, 1);
      expect(guard.violations, isEmpty);
    });

    test('several recipient searches on one compose form loaded through it '
        '(#107)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      final results = await messages.searchRecipientsForComposeAll([
        'John',
        'Piet',
      ]);

      expect(results.keys, ['John', 'Piet']);
      expect(results['Piet']!.$1.map((u) => u.userId), contains(146));
      expect(server.log, [
        'GET /?module=Messages&file=composeMessage&boxType=inbox'
            '&composeType=0&msgID=undefined',
        'POST /?module=Messages&file=searchUsers',
        'POST /?module=Messages&file=searchUsers',
      ]);
      expect(server.searched.map((f) => f['val']), ['John', 'Piet']);
      expect(server.searched.map((f) => f['uniqueUsc']).toSet(), hasLength(1));
      expect(server.registered, isEmpty);
      expect(guard.searches, 2);
      expect(guard.violations, isEmpty);
    });
  });

  group('lets out (Intradesk, #128)', () {
    test('in the test folder that Smartschool lists as "2. SMA" > "tests" and '
        'the run allows, and in a folder the run made there: the creates of a '
        'folder and a weblink named after the run, an upload, and the moves '
        'to the trash of what it made', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(server);

      final folder = await intradesk.createFolder(
        parentFolderId: _tests,
        name: _intradeskName('map'),
      );
      final link = await intradesk.createWeblink(
        parentFolderId: folder.id,
        name: _intradeskName('link'),
        url: 'https://example.com/dartschool',
      );
      final upload = await intradesk.uploadFiles(
        parentFolderId: folder.id,
        filePaths: [_tempFile('${liveFilePrefix}x.txt').path],
      );
      await intradesk.trashFile(upload.files.single.id);
      await intradesk.trashWeblink(link.id);
      await intradesk.trashFolder(folder.id);

      expect(server.intradeskWrites, [
        'POST $_intradesk/folders/',
        'POST $_intradesk/weblinks/',
        'POST /Upload/Upload/Index',
        'POST $_intradesk/files/upload',
        'POST $_intradesk/files/${upload.files.single.id}/trash',
        'POST $_intradesk/weblinks/${link.id}/trash',
        'POST $_intradesk/folders/${folder.id}/trash',
      ]);
      expect(guard.intradeskCreates, 3);
      expect(guard.violations, isEmpty);
    });

    test('a move to the trash of a made-up ID that the guard handed out, once '
        'per kind, and of an item the run made as another kind, once, when '
        'the run allowed it (#133); the 404 of Intradesk for them leaves the '
        'items the run may move to the trash', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(server);
      Future<void> notFound(Future<void> trash) => expectLater(
        trash,
        throwsA(isA<SmartschoolIntradeskItemNotFoundError>()),
      );

      final madeUp = guard.newMadeUpIntradeskId();
      final folder = await intradesk.createFolder(
        parentFolderId: _tests,
        name: _intradeskName('map'),
      );
      final link = await intradesk.createWeblink(
        parentFolderId: folder.id,
        name: _intradeskName('link'),
        url: 'https://example.com/dartschool',
      );
      await notFound(intradesk.trashFolder(madeUp));
      await notFound(intradesk.trashWeblink(madeUp));
      await notFound(intradesk.trashFile(madeUp));
      guard.allowIntradeskTrashAs(link.id, 'folders');
      guard.allowIntradeskTrashAs(folder.id.toUpperCase(), 'files');
      await notFound(intradesk.trashFolder(link.id));
      await notFound(intradesk.trashFile(folder.id));
      await intradesk.trashWeblink(link.id);
      await intradesk.trashFolder(folder.id);

      expect(
        madeUp,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
      expect(guard.newMadeUpIntradeskId(), isNot(madeUp));
      expect(server.intradeskWrites, [
        'POST $_intradesk/folders/',
        'POST $_intradesk/weblinks/',
        'POST $_intradesk/folders/$madeUp/trash',
        'POST $_intradesk/weblinks/$madeUp/trash',
        'POST $_intradesk/files/$madeUp/trash',
        'POST $_intradesk/folders/${link.id}/trash',
        'POST $_intradesk/files/${folder.id}/trash',
        'POST $_intradesk/weblinks/${link.id}/trash',
        'POST $_intradesk/folders/${folder.id}/trash',
      ]);
      expect(guard.violations, isEmpty);
    });
  });

  group('refuses before it reaches Smartschool (Intradesk, #128)', () {
    test('a create outside the test folder: before Smartschool listed it, '
        'before the run allowed it, in another folder called "tests", at the '
        'root, and one named without the run\'s tag', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final intradesk = IntradeskService(client);
      Future<void> refused(Future<Object?> write) =>
          expectLater(write, throwsA(anything));

      // Not listed through the guard yet, though the run allows it.
      guard.allowIntradeskFolder(_tests);
      await refused(
        _bareFolderCreate(
          server,
          guard,
          parent: _tests,
          name: _intradeskName('a'),
        ),
      );
      // Listed, but another "tests", the root, and names without the tag.
      await intradesk.getRootListing();
      await intradesk.getFolderListing(_sma);
      await intradesk.getFolderListing(_otherRoot);
      guard.allowIntradeskFolder(_otherTests);
      await refused(
        intradesk.createFolder(
          parentFolderId: _otherTests,
          name: _intradeskName('b'),
        ),
      );
      await refused(
        _bareFolderCreate(server, guard, parent: '', name: _intradeskName('c')),
      );
      await refused(
        intradesk.createFolder(
          parentFolderId: _tests,
          name: '$liveIntradeskPrefix run-other map',
        ),
      );
      await refused(
        intradesk.createWeblink(
          parentFolderId: _tests,
          name: 'Toetsen',
          url: 'https://example.com',
        ),
      );

      expect(server.intradeskWrites, isEmpty);
      expect(_violations(guard), [
        contains('neither the test folder'),
        contains('neither the test folder'),
        contains('neither the test folder'),
        contains('does not start with "$liveIntradeskPrefix $_tag"'),
        contains('does not start with "$liveIntradeskPrefix $_tag"'),
      ]);
    });

    test('a create in the test folder that the run did not allow', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(server, allow: false);

      await expectLater(
        intradesk.createFolder(
          parentFolderId: _tests,
          name: _intradeskName('a'),
        ),
        throwsA(anything),
      );

      expect(server.intradeskWrites, isEmpty);
      expect(_violations(guard), [contains('neither the test folder')]);
    });

    test('more creates than the run may send', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(
        server,
        maxIntradeskCreates: 1,
      );

      await intradesk.createFolder(
        parentFolderId: _tests,
        name: _intradeskName('a'),
      );
      await expectLater(
        intradesk.createFolder(
          parentFolderId: _tests,
          name: _intradeskName('b'),
        ),
        throwsA(anything),
      );

      expect(server.intradeskWrites, ['POST $_intradesk/folders/']);
      expect(_violations(guard), [contains('1 Intradesk creates already')]);
    });

    test('an upload into a directory not handed out through the guard, a '
        'second take of a directory, an upload into a directory taken '
        'already, and a file the run did not make', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(server);
      final dio = _dio(server, guard);
      final run = _tempFile('${liveFilePrefix}x.txt').path;
      Future<void> refused(Future<Object?> write) =>
          expectLater(write, throwsA(anything));
      Future<Response<String>> take(String dir) => dio.post<String>(
        '$_intradesk/files/upload',
        data: {'parentFolderId': _tests, 'uploadDir': dir},
      );
      Future<Response<String>> upload(String dir) => dio.post<String>(
        '/Upload/Upload/Index',
        data: FormData.fromMap({
          'file': MultipartFile.fromString(
            'x',
            filename: '${liveFilePrefix}y.txt',
          ),
          'uploadDir': dir,
        }),
      );

      await refused(take('made-up'));
      await refused(upload('made-up'));
      await intradesk.uploadFiles(parentFolderId: _tests, filePaths: [run]);
      // dir1 was handed out and taken by the upload above.
      await refused(take('dir1'));
      await refused(upload('dir1'));
      await refused(
        intradesk.uploadFiles(
          parentFolderId: _tests,
          filePaths: [_tempFile('notes.txt').path],
        ),
      );

      expect(server.intradeskWrites, [
        'POST /Upload/Upload/Index',
        'POST $_intradesk/files/upload',
      ]);
      expect(_violations(guard), [
        contains('not handed out through the guard'),
        contains('nor an upload directory handed out through it'),
        contains('taken into Intradesk already'),
        contains('nor an upload directory handed out through it'),
        contains('a file that the live suite did not make'),
      ]);
    });

    test(
      'a move to the trash of an item the run did not make, of another '
      'kind, or after Smartschool answered one; any other Intradesk POST '
      '(a confidential folder, a rename, a move, a restore), and a DELETE',
      () async {
        final server = _Smartschool(replyForm: _replyFormFromOwn);
        final (intradesk, guard) = await _intradeskRun(server);
        final dio = _dio(server, guard);
        Future<void> refused(Future<Object?> write) =>
            expectLater(write, throwsA(anything));

        final folder = await intradesk.createFolder(
          parentFolderId: _tests,
          name: _intradeskName('map'),
        );
        await refused(intradesk.trashFolder(_tests));
        await refused(intradesk.trashFile(folder.id));
        await intradesk.trashFolder(folder.id);
        await refused(intradesk.trashFolder(folder.id));
        // A folder the run trashed is no longer one it may write in.
        await refused(
          _bareFolderCreate(
            server,
            guard,
            parent: folder.id,
            name: _intradeskName('in de prullenbak'),
          ),
        );
        for (final path in [
          '$_intradesk/folders/as-confidential',
          '$_intradesk/folders/${folder.id}/rename',
          '$_intradesk/folders/${folder.id}/move',
          '$_intradesk/folders/${folder.id}/restore',
        ]) {
          await refused(
            dio.post<String>(
              path,
              data: {'parentFolderId': _tests, 'name': _intradeskName('x')},
            ),
          );
        }
        await refused(dio.delete<String>('$_intradesk/folders/${folder.id}'));

        expect(server.intradeskWrites, [
          'POST $_intradesk/folders/',
          'POST $_intradesk/folders/${folder.id}/trash',
        ]);
        expect(_violations(guard), [
          contains('which this run did not make'),
          contains(
            'as one of the files, but the run made it as one of the '
            'folders',
          ),
          contains('moved to the trash already'),
          contains('neither the test folder'),
          for (var i = 0; i < 4; i++)
            contains('no Intradesk POST but the creates'),
          contains('sends no DELETE'),
        ]);
      },
    );

    test('(#133) a second move of a made-up ID as the same kind, a create in '
        'it, a move as another kind without the run allowing it or a second '
        'time, one of an item the run did not make, and one as another kind '
        'of an item it moved to the trash already', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (intradesk, guard) = await _intradeskRun(server);
      Future<void> refused(Future<Object?> write) => expectLater(
        write,
        throwsA(isNot(isA<SmartschoolIntradeskItemNotFoundError>())),
      );
      Future<void> notFound(Future<void> trash) => expectLater(
        trash,
        throwsA(isA<SmartschoolIntradeskItemNotFoundError>()),
      );

      final madeUp = guard.newMadeUpIntradeskId();
      final folder = await intradesk.createFolder(
        parentFolderId: _tests,
        name: _intradeskName('map'),
      );
      final link = await intradesk.createWeblink(
        parentFolderId: folder.id,
        name: _intradeskName('link'),
        url: 'https://example.com/dartschool',
      );
      await notFound(intradesk.trashFolder(madeUp));
      await refused(intradesk.trashFolder(madeUp));
      await refused(
        _bareFolderCreate(
          server,
          guard,
          parent: madeUp,
          name: _intradeskName('in een verzonnen map'),
        ),
      );
      // Not allowed, and allowed for an item the run did not make.
      await refused(intradesk.trashWeblink(folder.id));
      guard.allowIntradeskTrashAs(_tests, 'files');
      await refused(intradesk.trashFile(_tests));
      // Allowed once: Intradesk answers it with 404, and the allowance is
      // used up.
      guard.allowIntradeskTrashAs(link.id, 'files');
      await notFound(intradesk.trashFile(link.id));
      await refused(intradesk.trashFile(link.id));
      // The folder in the trash, then as another kind.
      await intradesk.trashFolder(folder.id);
      guard.allowIntradeskTrashAs(folder.id, 'weblinks');
      await refused(intradesk.trashWeblink(folder.id));

      expect(server.intradeskWrites, [
        'POST $_intradesk/folders/',
        'POST $_intradesk/weblinks/',
        'POST $_intradesk/folders/$madeUp/trash',
        'POST $_intradesk/files/${link.id}/trash',
        'POST $_intradesk/folders/${folder.id}/trash',
      ]);
      expect(_violations(guard), [
        contains(
          'made-up Intradesk ID $madeUp to the trash as one of the folders a '
          'second time',
        ),
        contains('neither the test folder'),
        contains(
          'as one of the weblinks, but the run made it as one of the folders',
        ),
        contains('which this run did not make'),
        contains(
          'as one of the files, but the run made it as one of the weblinks',
        ),
        contains('moved to the trash already'),
      ]);
    });
  });

  group('lets out (Lesfiches, #129)', () {
    test('the create of a lesfiche named after the run, with an upload '
        'directory handed out through the guard; on it, a rename after the '
        'run, a change of its visibility, the add and the removal of a '
        'weblink; and its move to the trash', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final lessonContent = LessonContentService(client);

      final made = await lessonContent.createLesson(
        name: _lessonName('les'),
        attachments: [
          NewLessonContentAttachment(_tempFile('${liveFilePrefix}x.txt').path),
        ],
      );
      await lessonContent.rename(made, _lessonName('les 2'));
      await lessonContent.setVisible(made, false);
      final link = await lessonContent.addWeblink(
        made,
        const NewLessonContentWeblink(
          name: 'Oefeningen',
          url: 'https://example.com',
        ),
      );
      await lessonContent.removeWeblink(made, link.id);
      await lessonContent.trash([made]);

      const api = '/lesson-content/api/v1';
      expect(server.lessonContentWrites, [
        'POST /Upload/Upload/Index',
        'POST $api/lessons/',
        'POST $api/lessons/${made.id}/rename',
        'POST $api/lessons/${made.id}/mark-as-invisible',
        'POST $api/lessons/${made.id}/weblinks',
        'DELETE $api/lessons/${made.id}/weblinks/${link.id}',
        'POST $api/lesson-content/trash/bulk',
      ]);
      expect(guard.lessonContentCreates, 1);
      expect(guard.lessonContentMade, {made.id});
      expect(guard.violations, isEmpty);
    });
  });

  group('refuses before it reaches Smartschool (Lesfiches, #129)', () {
    const api = '/lesson-content/api/v1';

    /// The body of a create as the library sends it, named [name], with
    /// [extra] keys over it.
    Map<String, Object?> create(
      String name, [
      Map<String, Object?> extra = const {},
    ]) => {
      'name': name,
      'icon': 'document_observation',
      'publicInfo': '',
      'privateInfo': '',
      'courses': <Object>[],
      'goals': <Object>[],
      'labels': <Object>[],
      'weblinks': <Object>[],
      'partnerWeblinks': <Object>[],
      'miniDBItems': <Object>[],
      'deeplinks': <Object>[],
      'randomDir': null,
      'previousLessonContent': null,
      'visibilityOptions': <String, Object>{},
      ...extra,
    };

    test('a create named without the run\'s tag, with labels, goals, '
        'deeplinks or a lesfiche it continues, and more creates than the '
        'run may send', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(
        server,
        maxLessonContentCreates: 1,
      );
      final lessonContent = LessonContentService(client);
      final dio = _dio(server, guard);
      Future<void> refused(Future<Object?> write) =>
          expectLater(write, throwsA(anything));

      await refused(lessonContent.createLesson(name: 'Lussen'));
      await refused(
        lessonContent.createLesson(name: '$liveSubjectPrefix run-other les'),
      );
      for (final extra in [
        {
          'labels': [
            {'type': 'platform', 'identifier': '49_x'},
          ],
        },
        {
          'goals': ['x'],
        },
        {
          'deeplinks': ['x'],
        },
        {'previousLessonContent': 'x'},
      ]) {
        await refused(
          dio.post<String>(
            '$api/lessons/',
            data: create(_lessonName('a'), extra),
          ),
        );
      }
      await lessonContent.createLesson(name: _lessonName('b'));
      await refused(
        lessonContent.createAssignment(
          name: _lessonName('c'),
          assignmentTypeId: 'a0000000-0000-4000-8000-000000000004',
        ),
      );

      expect(server.lessonContentWrites, ['POST $api/lessons/']);
      expect(_violations(guard), [
        contains('does not start with "$liveSubjectPrefix $_tag"'),
        contains('does not start with "$liveSubjectPrefix $_tag"'),
        contains('with labels'),
        contains('with goals'),
        contains('with deeplinks'),
        contains('continues another one'),
        contains('1 lesfiches already'),
      ]);
    });

    test('an upload directory that was not handed out through the guard, or '
        'was taken already, in a create or an add of attachments', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final lessonContent = LessonContentService(client);
      final dio = _dio(server, guard);
      Future<void> refused(Future<Object?> write) =>
          expectLater(write, throwsA(anything));

      await refused(
        dio.post<String>(
          '$api/lessons/',
          data: create(_lessonName('a'), {'randomDir': 'made-up'}),
        ),
      );
      final made = await lessonContent.createLesson(
        name: _lessonName('b'),
        attachments: [
          NewLessonContentAttachment(_tempFile('${liveFilePrefix}x.txt').path),
        ],
      );
      // dir1 was handed out and taken by the create above.
      await refused(
        dio.post<String>(
          '$api/lessons/${made.id}/attachments',
          data: {'randomDir': 'dir1'},
        ),
      );
      await refused(
        dio.post<String>(
          '$api/lessons/${made.id}/attachments',
          data: {'randomDir': 'made-up'},
        ),
      );

      expect(server.lessonContentWrites, [
        'POST /Upload/Upload/Index',
        'POST $api/lessons/',
      ]);
      expect(_violations(guard), [
        contains('not handed out through the guard'),
        contains('taken already'),
        contains('not handed out through the guard'),
      ]);
    });

    test('a write to a lesfiche the run did not make, or as another kind; a '
        'rename to a name without the run\'s tag; labels, goals and the '
        'rest; a DELETE of the lesfiche itself; a delete for good or a '
        'restore; and anything after its move to the trash', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final lessonContent = LessonContentService(client);
      final dio = _dio(server, guard);
      Future<void> refused(Future<Object?> write) =>
          expectLater(write, throwsA(anything));
      const other = 'eeee0001-0000-4000-8000-000000000000';
      final otherItem = LessonContentItem.fromJson(const {
        'id': other,
        'platformId': 49,
        'type': 'lessons',
      });

      final made = await lessonContent.createLesson(name: _lessonName('a'));
      final fiche = '$api/lessons/${made.id}';
      // Not made by the run.
      await refused(lessonContent.rename(otherItem, _lessonName('x')));
      await refused(lessonContent.removeWeblink(otherItem, other));
      await refused(lessonContent.trash([otherItem]));
      await refused(lessonContent.trash([made, otherItem]));
      // Made by the run, but as another kind.
      await refused(
        dio.post<String>(
          '$api/assignments/${made.id}/rename',
          data: {'newName': _lessonName('x')},
        ),
      );
      // Made by the run, but not a write the live suite sends.
      await refused(lessonContent.rename(made, 'Lussen'));
      for (final action in [
        'change-labels',
        'change-goals',
        'deeplinks',
        'partner-weblinks/bulk',
      ]) {
        await refused(dio.post<String>('$fiche/$action', data: {'x': 1}));
      }
      await refused(dio.delete<String>(fiche));
      await refused(
        dio.post<String>(
          '$api/lesson-content/delete/bulk',
          data: {
            'lessonContent': [
              {'id': made.id, 'type': 'lessons', 'platformId': 49},
            ],
          },
        ),
      );
      await refused(
        dio.post<String>(
          '$api/lesson-content/restore/bulk',
          data: {'lessonContent': <Object>[]},
        ),
      );
      // After its move to the trash.
      await lessonContent.trash([made]);
      await refused(lessonContent.trash([made]));
      await refused(lessonContent.setVisible(made, true));

      expect(server.lessonContentWrites, [
        'POST $api/lessons/',
        'POST $api/lesson-content/trash/bulk',
      ]);
      expect(_violations(guard), [
        contains('which this run did not make'),
        contains('which this run did not make'),
        contains('which this run did not make'),
        contains('which this run did not make'),
        contains(
          'as one of the assignments, but the run made it as one of '
          'the lessons',
        ),
        contains('to a name that does not start with'),
        for (var i = 0; i < 4; i++) contains('to a lesfiche: only renames'),
        contains('sends no DELETE but of a weblink or an attachment'),
        contains('sends no Lesfiches POST but'),
        contains('sends no Lesfiches POST but'),
        contains('moved to the trash already'),
        contains('moved to the trash already'),
      ]);
    });

    test('a DELETE elsewhere is still refused', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guardedClient(server);

      await expectLater(
        _dio(server, guard).delete<String>('/planner/api/v1/x'),
        throwsA(anything),
      );

      expect(server.log, isEmpty);
      expect(_violations(guard), [contains('the live suite sends no DELETE')]);
    });
  });

  group('refuses before it reaches Smartschool', () {
    for (final (field, params) in [
      ('To', _params(to: [_own, _other])),
      ('CC', _params(cc: [_other])),
      ('BCC', _params(bcc: [_other])),
    ]) {
      test('registering another user, in $field', () async {
        final server = _Smartschool(replyForm: _replyFormFromOwn);
        final (messages, guard) = await _guarded(server);

        await expectLater(messages.sendMessage(params), throwsA(anything));

        expect(server.registered.map((f) => f['id']), everyElement('777'));
        expect(server.submits, isEmpty);
        expect(_violations(guard), [
          contains('it registers someone other than the own account'),
        ]);
      });
    }

    test('registering a group', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      const group = MessageSearchGroup(
        groupId: 5,
        displayName: 'Group',
        ssId: 100,
      );

      await expectLater(
        messages.sendMessage(_params(toGroups: [group])),
        throwsA(anything),
      );

      expect(server.registered.map((f) => f['typeId']), ['users']);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('it registers a group')]);
    });

    test('registering anyone before the own account is known', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server, own: false);

      await expectLater(messages.sendMessage(_params()), throwsA(anything));

      expect(server.registered, isEmpty);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('is not known yet')]);
    });

    test('a message whose compose form has another user registered: a '
        'reply form that names them', () async {
      final server = _Smartschool(replyForm: _replyFormFromOther);
      final (messages, guard) = await _guarded(server);
      guard.allowReplyTo(900030);

      // The library leaves the sender on the form (the params keep them),
      // and registers the own account too.
      await expectLater(
        messages.sendReply(
          900030,
          _params(to: [_other, _own], subject: 'Re: [dartschool test] $_tag x'),
        ),
        throwsA(anything),
      );

      expect(server.registered.map((f) => f['id']), ['777']);
      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('someone other than the own account registered'),
      ]);
    });

    test('a reply to a message that the run did not send to the own account '
        'only', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.sendReply(
          900030,
          _params(subject: 'Re: [dartschool test] $_tag x'),
        ),
        throwsA(anything),
      );

      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('replies to a message that this run did not send'),
      ]);
    });

    test(
      'anything more on a form whose answer registered someone else',
      () async {
        // Smartschool answers with the own account and another user: the
        // library finds the own account in it and would go on.
        final server = _Smartschool(
          replyForm: _replyFormFromOwn,
          answerAdd: (fields) => registeredRecipientAnswer(fields).replaceFirst(
            '</users>',
            registeredRecipientAnswer({
              ...fields,
              'id': '201',
            }).split('<users>').last,
          ),
        );
        final (messages, guard) = await _guarded(server);

        await expectLater(messages.sendMessage(_params()), throwsA(anything));

        expect(server.registered, hasLength(1));
        expect(server.submits, isEmpty);
        expect(_violations(guard), [
          contains('Smartschool registered someone other than the own account'),
        ]);
      },
    );

    test('a message stored in the LVS, or sent later', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      await expectLater(
        messages.sendMessage(
          _params(options: const MessageSendOptions(lvsCopy: LvsCopy.store)),
        ),
        throwsA(anything),
      );
      await expectLater(
        messages.sendMessage(
          _params(
            options: MessageSendOptions(
              sendAt: DateTime.now().add(const Duration(days: 1)),
            ),
          ),
        ),
        throwsA(anything),
      );

      expect(server.submits, isEmpty);
      expect(_violations(guard), [
        contains('it stores the message in the LVS'),
        contains('it schedules the message for later'),
      ]);
    });

    test("a subject without the run's tag", () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);

      for (final subject in [
        'Hello',
        '[dartschool test] run-20200101-000000-0000 send',
        'Fwd: [dartschool test] $_tag send',
      ]) {
        await expectLater(
          messages.sendMessage(_params(subject: subject)),
          throwsA(anything),
        );
      }

      expect(server.submits, isEmpty);
      expect(_violations(guard), everyElement(contains('its subject')));
    });

    test('more messages than the run may send', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server, maxSubmits: 1);

      await messages.sendMessage(_params());
      await expectLater(messages.sendMessage(_params()), throwsA(anything));

      expect(server.submits, hasLength(1));
      expect(_violations(guard), [contains('its maximum')]);
    });

    test('an attachment the run did not make', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (messages, guard) = await _guarded(server);
      final file = _tempFile('notes.txt');

      await expectLater(
        messages.sendMessage(_params(attachmentPaths: [file.path])),
        throwsA(anything),
      );

      expect(server.log, isNot(contains('POST /Upload/Upload/Index')));
      expect(server.submits, isEmpty);
      expect(_violations(guard), [contains('did not make')]);
    });

    test('another quickactions command than the read of the folder tree, '
        'and a requestmovelist of another subsystem (#136)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);
      Future<void> send(String subsystem, String action) => expectLater(
        dio.post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(subsystem, action, const {}),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );

      await send('quickactions', 'requestmovelists');
      await send('quickactions', 'move messages');
      await send('postboxes', 'requestmovelist');

      expect(server.log, isEmpty);
      expect(_violations(guard), [
        contains(
          'the live suite sends no "quickactions" command but requestmovelist',
        ),
        contains(
          'the live suite sends no "quickactions" command but requestmovelist',
        ),
        contains('the live suite sends no "requestmovelist" command'),
      ]);
    });

    test('a quick delete (moveToTrash), of any ID: of 0, and of a message '
        'the run sent, listed and checked (#61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [(4242, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      guard.allowTrashFrom(4242, BoxType.inbox);

      await expectLater(messages.moveToTrash(0), throwsA(anything));
      await expectLater(messages.moveToTrash(4242), throwsA(anything));

      expect(server.trashed, isEmpty);
      expect(
        _violations(guard),
        everyElement(contains('the live suite sends no quick delete')),
      );
      expect(guard.violations, hasLength(2));
    });

    test(
      'a move to the trash of ID 0, also when the run allowed it, and '
      'Smartschool listed it in the box with the run\'s subject (#61)',
      () async {
        final server = _Smartschool(
          replyForm: _replyFormFromOwn,
          boxes: {
            'inbox/0': [(0, _runSubject)],
            'outbox/0': [(0, _runSubject)],
          },
        );
        final (messages, guard) = await _guarded(server);
        await messages.getHeaders();
        await messages.getHeaders(boxType: BoxType.sent);
        guard
          ..allowTrashFrom(0, BoxType.inbox)
          ..allowTrashFrom(0, BoxType.sent);

        await expectLater(
          messages.moveToTrashFrom(0, boxType: BoxType.inbox),
          throwsA(anything),
        );
        await expectLater(
          messages.moveToTrashFrom(0, boxType: BoxType.sent),
          throwsA(anything),
        );

        expect(server.moved, isEmpty);
        expect(_violations(guard), [
          contains('it moves message 0, which names no message'),
          contains('it moves message 0, which names no message'),
        ]);
      },
    );

    test('a move to the trash of a copy that Smartschool did not list in its '
        'box with the run\'s subject, also when the run allowed it: not a '
        'message this run sent (#61)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [
            (4242, _runSubject),
            (5555, 'Hello'),
            (6666, '[dartschool test] run-20200101-000000-0000 send'),
          ],
          'trash/0': [(7777, _runSubject)],
          'inbox/208': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders(boxType: BoxType.trash);
      await messages.getHeaders(boxId: 208);
      for (final (id, box) in [
        (1234, BoxType.inbox), // Listed nowhere.
        (4242, BoxType.sent), // Listed in the inbox only.
        (5555, BoxType.inbox), // Another subject.
        (6666, BoxType.inbox), // The subject of another run.
        (7777, BoxType.inbox), // Listed in the trash only.
        (8888, BoxType.inbox), // Listed in a folder of the inbox only.
        (4242, BoxType.inbox),
      ]) {
        guard.allowTrashFrom(id, box);
      }

      for (final (id, box) in [
        (1234, BoxType.inbox),
        (4242, BoxType.sent),
        (5555, BoxType.inbox),
        (6666, BoxType.inbox),
        (7777, BoxType.inbox),
        (8888, BoxType.inbox),
      ]) {
        await expectLater(
          messages.moveToTrashFrom(id, boxType: box),
          throwsA(anything),
          reason: '$id, ${box.value}',
        );
      }
      // The copy that Smartschool listed in its box with the run's subject.
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox);

      expect(server.moved, ['inbox 4242']);
      expect(_violations(guard), [
        for (final (id, box) in [
          (1234, 'inbox'),
          (4242, 'outbox'),
          (5555, 'inbox'),
          (6666, 'inbox'),
          (7777, 'inbox'),
          (8888, 'inbox'),
        ])
          contains(
            "Smartschool did not list message $id in the $box with the run's "
            'subject',
          ),
      ]);
    });

    test('a move to the trash of a copy the run did not check in its box, '
        'or a second one of a copy (#60)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [(4242, _runSubject)],
          'outbox/0': [(4242, _runSubject), (1234, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      guard.allowTrashFrom(4242, BoxType.sent);

      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.inbox),
        throwsA(anything),
      );
      await expectLater(
        messages.moveToTrashFrom(1234, boxType: BoxType.sent),
        throwsA(anything),
      );
      await messages.moveToTrashFrom(4242, boxType: BoxType.sent);
      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.sent),
        throwsA(anything),
      );

      expect(server.moved, ['outbox 4242']);
      expect(_violations(guard), [
        contains(
          'the inbox copy of message 4242 is not one this run sent and '
          'checked in the inbox',
        ),
        contains('the outbox copy of message 1234 is not one this run sent'),
        contains(
          'the outbox copy of message 4242 was moved to the trash '
          'already',
        ),
      ]);
    });

    test('a move elsewhere than to the trash, or out of the trash or of a '
        'folder (#60)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      guard
        ..allowTrashFrom(4242, BoxType.sent)
        ..allowTrashFrom(4242, BoxType.inbox);
      final dio = _dio(server, guard);
      Future<void> move(Map<String, String> params) => expectLater(
        dio.post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(
              'postboxes',
              'quickmove messages',
              params,
            ),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );
      const fromSent = {
        'boxType': 'outbox',
        'boxID': '0',
        'msgID': '4242',
        'toBoxType': 'trash',
        'toBoxID': '0',
      };

      await move({...fromSent, 'toBoxType': 'inbox'});
      await move({...fromSent, 'toBoxID': '208'});
      await move({...fromSent, 'boxType': 'trash'});
      await move({...fromSent, 'boxType': 'inbox', 'boxID': '208'});

      expect(server.moved, isEmpty);
      expect(_violations(guard), [
        contains('it moves message 4242 elsewhere than to the trash'),
        contains('it moves message 4242 elsewhere than to the trash'),
        contains('it moves message 4242 out of the "trash"'),
        contains('it moves message 4242 out of a folder of the inbox'),
      ]);
    });

    test('a move to the archive of ID 0, of a message that Smartschool did '
        "not list in the inbox with the run's subject, of one the run did not "
        'check there, of more than one message at once, of a copy the run '
        'moved to the trash, and a second one (#64)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        boxes: {
          'inbox/0': [
            (0, _runSubject),
            (4242, _runSubject),
            (1234, _runSubject),
            (5555, 'Hello'),
            (9999, _runSubject),
          ],
          'outbox/0': [(6666, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      for (final id in [0, 4242, 5555, 6666, 7777, 9999]) {
        guard.allowArchive(id);
      }
      guard.allowTrashFrom(9999, BoxType.inbox);
      await messages.moveToTrashFrom(9999, boxType: BoxType.inbox);

      for (final ids in [
        [0],
        [5555], // Another subject.
        [6666], // Listed in the sent box only.
        [7777], // Listed nowhere.
        [1234], // Listed, but the run did not check it.
        [4242, 1234],
        [9999], // Its inbox copy was moved to the trash.
      ]) {
        await expectLater(
          messages.moveToArchive(ids),
          throwsA(anything),
          reason: '$ids',
        );
      }
      await messages.moveToArchive([4242]);
      // The inbox no longer lists it: a move to the trash out of the inbox
      // needs a new listing there.
      guard.allowTrashFrom(4242, BoxType.inbox);
      await expectLater(
        messages.moveToTrashFrom(4242, boxType: BoxType.inbox),
        throwsA(anything),
      );
      await expectLater(messages.moveToArchive([4242]), throwsA(anything));

      expect(server.archived, [
        [4242],
      ]);
      expect(server.moved, ['inbox 9999']);
      String notListed(int id) =>
          "Smartschool did not list message $id in the inbox with the run's "
          'subject';
      expect(_violations(guard), [
        contains('it archives message 0, which names no message'),
        contains(notListed(5555)),
        contains(notListed(6666)),
        contains(notListed(7777)),
        contains(
          'message 1234 is not one this run sent and checked in the inbox',
        ),
        contains('it archives 2 messages at once'),
        contains(
          'the inbox copy of message 9999 was moved to the trash already',
        ),
        contains(notListed(4242)),
        contains('message 4242 was moved to the archive already'),
      ]);
    });

    test('a move to the trash out of the archive folder of a copy that '
        "Smartschool did not list there with the run's subject, or that the "
        'run did not check there; a second move of a copy, out of any folder; '
        'and a move out of another folder, or out of the archive while '
        'neither the folder tree nor a Messages page names it (#64, '
        '#141)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [(4242, _runSubject), (6666, _runSubject)],
          'inbox/312': [
            (4242, _runSubject),
            (3333, _runSubject),
            (5555, 'Hello'),
            (7777, _runSubject),
          ],
          'inbox/400': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxId: 312);
      await messages.getHeaders(boxId: 400);
      guard
        ..allowTrashFrom(4242, BoxType.inbox)
        ..allowTrashFrom(4242, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(4242, BoxType.sent, boxId: 312)
        ..allowTrashFrom(3333, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(5555, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(6666, BoxType.inbox, boxId: 312)
        ..allowTrashFrom(7777, BoxType.inbox) // Out of the inbox itself only.
        ..allowTrashFrom(8888, BoxType.inbox, boxId: 400);
      Future<void> refused(int id, BoxType box, int boxId) => expectLater(
        messages.moveToTrashFrom(id, boxType: box, boxId: boxId),
        throwsA(anything),
        reason: '$id, ${box.value}/$boxId',
      );

      await refused(4242, BoxType.inbox, 312); // Not named yet.
      expect(await messages.getArchiveBoxId(), 312);
      await refused(5555, BoxType.inbox, 312); // Another subject.
      await refused(6666, BoxType.inbox, 312); // Listed in the inbox only.
      await refused(7777, BoxType.inbox, 312); // Not checked in the archive.
      await refused(8888, BoxType.inbox, 400); // Not the archive folder.
      await refused(4242, BoxType.sent, 312); // A folder of the sent box.
      await messages.moveToTrashFrom(4242, boxType: BoxType.inbox, boxId: 312);
      await refused(4242, BoxType.inbox, 312);
      await refused(4242, BoxType.inbox, 0); // The same copy.
      // A page that names another archive folder: the guard trusts neither,
      // and refuses a move it let out until then.
      server.archiveFolder = 400;
      await _dio(
        server,
        guard,
      ).get<String>('/?module=Messages&file=index&function=main');
      expect(guard.archiveBoxId, isNull);
      await refused(3333, BoxType.inbox, 312);

      expect(server.moved, ['inbox/312 4242']);
      const notArchive = 'that is not the archive folder of the inbox';
      expect(_violations(guard), [
        contains(
          'it moves message 4242 out of a folder of the inbox $notArchive',
        ),
        contains(
          "Smartschool did not list message 5555 in the archive folder (312) "
          "of the inbox with the run's subject",
        ),
        contains(
          "Smartschool did not list message 6666 in the archive folder (312) "
          "of the inbox with the run's subject",
        ),
        contains(
          'the inbox copy of message 7777 is not one this run sent and '
          'checked in the archive folder (312) of the inbox',
        ),
        contains(
          'it moves message 8888 out of a folder of the inbox $notArchive',
        ),
        contains(
          'it moves message 4242 out of a folder of the outbox $notArchive',
        ),
        contains(
          'the inbox copy of message 4242 was moved to the trash already',
        ),
        contains(
          'the inbox copy of message 4242 was moved to the trash already',
        ),
        contains(
          'it moves message 3333 out of a folder of the inbox $notArchive',
        ),
      ]);
    });

    test('marking read or unread, or flagging, ID 0, a message that '
        "Smartschool did not list in the inbox or its archive folder with the "
        "run's subject, one the run did not check, a copy in another box or "
        'in another folder, or in the archive folder while neither the '
        'folder tree nor a Messages page names it, and a copy the run moved '
        'to the trash (#94, #141)', () async {
      final server = _Smartschool(
        replyForm: _replyFormFromOwn,
        archiveFolder: 312,
        boxes: {
          'inbox/0': [
            (4242, _runSubject),
            (5555, 'Hello'),
            (6666, _runSubject),
            (9999, _runSubject),
          ],
          'outbox/0': [(4242, _runSubject)],
          'inbox/312': [(7777, _runSubject)],
          'inbox/400': [(8888, _runSubject)],
        },
      );
      final (messages, guard) = await _guarded(server);
      await messages.getHeaders();
      await messages.getHeaders(boxType: BoxType.sent);
      await messages.getHeaders(boxId: 312);
      await messages.getHeaders(boxId: 400);
      guard
        ..allowMark(0)
        ..allowMark(4242)
        ..allowMark(5555)
        ..allowMark(7777)
        ..allowMark(8888)
        ..allowMark(9999)
        ..allowTrashFrom(9999, BoxType.inbox);
      Future<void> refused(Future<Object?> change, String reason) =>
          expectLater(change, throwsA(anything), reason: reason);

      // Neither the folder tree nor a Messages page named the archive
      // folder yet.
      await refused(messages.markUnread(7777, boxId: 312), 'archive unknown');
      await refused(messages.markRead(7777), 'archive unknown: inbox only');
      expect(await messages.getArchiveBoxId(), 312);
      await refused(messages.markRead(0), 'ID 0');
      await refused(
        messages.setLabel(5555, MessageLabel.redFlag),
        'another subject',
      );
      await refused(messages.markRead(6666), 'not checked');
      await refused(
        messages.markRead(4242, boxType: BoxType.sent),
        'the sent box',
      );
      await refused(
        messages.markUnread(8888, boxId: 400),
        'not the archive folder',
      );
      await refused(
        messages.markUnread(4242, boxId: 312),
        'listed in the inbox, not in the archive folder',
      );
      await messages.moveToTrashFrom(9999, boxType: BoxType.inbox);
      await refused(
        messages.setLabel(9999, MessageLabel.redFlag),
        'moved to the trash',
      );
      // What it lets out: a copy listed in the archive folder (a command
      // without a folder), and one listed in the inbox (with folder 0).
      await messages.markRead(7777);
      await messages.markUnread(4242);

      expect(server.moved, ['inbox 9999']);
      expect(server.marked, [
        'mark message read inbox 7777',
        'mark message unread inbox/0 4242',
      ]);
      const notArchive = 'in a folder of the inbox that is not the archive';
      String notListed(int id, String where) =>
          "Smartschool did not list message $id in $where with the run's "
          'subject';
      expect(_violations(guard), [
        contains('it changes message 7777 $notArchive'),
        contains(notListed(7777, 'the inbox')),
        contains('it changes message 0, which names no message'),
        contains(notListed(5555, 'the inbox or its archive folder (312)')),
        contains(
          'message 6666 is not one this run sent and checked to change its '
          'read state and flag',
        ),
        contains('it changes the outbox copy of message 4242'),
        contains('it changes message 8888 $notArchive'),
        contains(notListed(4242, 'the archive folder (312) of the inbox')),
        contains(
          'the inbox copy of message 9999 was moved to the trash already',
        ),
      ]);
    });

    test('any other request that changes something', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);

      await expectLater(
        dio.post<String>(
          '/?module=Messages&file=dispatcher',
          data: {
            'command': XmlInterface.buildCommand(
              'postboxes',
              'empty_trash',
              {},
            ),
          },
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.post<String>(
          '/?module=Messages&file=index&function=main',
          data: {'folder': '1'},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );

      expect(server.log, isEmpty);
      expect(_violations(guard), [
        contains('no "empty_trash" command'),
        contains('not a request the live suite sends'),
      ]);
    });

    test('a save of presences, and any other Presence request but its reads '
        '(#104)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final dio = _dio(server, guard);

      // setLate reads the config, the codes and the pupils (#105: the codes
      // are a read too), then saves: refused there.
      await expectLater(
        PresenceService(client).setLate(
          userId: 11110,
          classGroupId: 298,
          date: DateTime(2026, 10, 1),
          part: DayPart.morning,
        ),
        throwsA(anything),
      );
      for (final path in [
        '/Presence/Class/savePupilsPresences',
        '/Presence/Class/deletePresences',
      ]) {
        await expectLater(
          dio.post<String>(
            path,
            data: {'pupils': '[]'},
            options: Options(contentType: Headers.formUrlEncodedContentType),
          ),
          throwsA(isA<DioException>()),
        );
      }

      expect(server.log, [
        'POST /Presence/Main/getConfig',
        'POST /Presence/Code/getAllCodes',
        'POST /Presence/Class/getClass',
      ]);
      expect(_violations(guard), [
        allOf(
          contains('POST /Presence/Class/savePupilsPresences was not sent'),
          contains('changes no presence'),
        ),
        allOf(
          contains('POST /Presence/Class/savePupilsPresences was not sent'),
          contains('changes no presence'),
        ),
        allOf(
          contains('POST /Presence/Class/deletePresences was not sent'),
          contains('changes no presence'),
        ),
      ]);
    });

    test('a save in Skore, and any other Skore POST but its reads (#91, '
        '#148)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (client, guard) = await _guardedClient(server);
      final dio = _dio(server, guard);

      // shareGradebook reads the gradebooks and the teachers, then saves:
      // refused there.
      await expectLater(
        SkoreService(client).shareGradebook(
          ownerId: 146,
          gradebookId: 34826,
          teacherId: 1001,
          access: SkoreShareAccess.read,
        ),
        throwsA(anything),
      );
      final others = [
        (_skoreOwners, 'saveOwner'),
        (_skoreOwners, 'deleteOwner'),
        (_skoreOwners, 'getMyGroups'),
        (_skoreGradebooks, 'deleteTeacher'),
        (_skoreGradebooks, 'getTeachers'),
        (_skoreGradebook, 'gradebooksToAccess'),
        // The gradebook's writes, its publishing above all (#148), and its
        // reads on the other services.
        (_skoreGradebook, 'setPublicProp'),
        (_skoreGradebook, 'saveEvalProperties'),
        (_skoreGradebook, 'saveEvaluation'),
        (_skoreGradebook, 'deleteEvaluation'),
        (_skoreGradebook, 'destroyEvaluations'),
        (_skoreGradebook, 'saveGrade'),
        (_skoreGradebooks, 'getNavigation'),
        (_skoreOwners, 'init'),
      ];
      for (final (path, method) in others) {
        await expectLater(
          dio.post<String>(
            path,
            data: {'rpc_method': method, 'rpc_params': '[]'},
            options: Options(contentType: Headers.formUrlEncodedContentType),
          ),
          throwsA(isA<DioException>()),
        );
      }

      expect(server.skoreCalls, [
        '$_skoreGradebooks getCourses',
        '$_skoreOwners getTeachers',
      ]);
      expect(_violations(guard), [
        for (final path in [
          _skoreGradebooks,
          for (final (path, _) in others) path,
        ])
          allOf(
            contains('POST $path was not sent'),
            contains('changes nothing in Skore'),
          ),
      ]);
    });

    test(
      'any planner POST but its lookup of a calendar by ID (#127)',
      () async {
        final server = _Smartschool(replyForm: _replyFormFromOwn);
        final (_, guard) = await _guardedClient(server);
        final dio = _dio(server, guard);

        // The search (which only reads, but the live suite does not send it),
        // a change of the user's favourites, the clear of a lesson hour, and
        // the move of a whole period to the trash.
        final others = [
          '/planner/api/v1/quick-search/planner/search',
          '/planner/api/v1/quick-search/planner/mark-as-favourite',
          '/planner/api/v1/planned-elements/clear',
          '/planner/api/v1/planned-elements/user/4069_1001_0/trash'
              '?from=2026-10-05&to=2026-10-09',
        ];
        for (final path in others) {
          await expectLater(
            dio.post<String>(path, data: {'users': <Object>[]}),
            throwsA(isA<DioException>()),
          );
        }

        expect(server.log, isEmpty);
        expect(_violations(guard), [
          for (final path in others)
            allOf(
              contains('POST $path was not sent'),
              contains('changes nothing in the planner'),
            ),
        ]);
      },
    );

    test('a recipient search on a compose form not loaded through it, or with '
        'a selection (#97)', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);
      final form = await dio.get<String>(
        '/?module=Messages&file=composeMessage&boxType=inbox&composeType=0'
        '&msgID=undefined',
      );
      final uniqueUsc = MessagesService.parseHiddenFields(
        form.data!,
      )['uniqueUsc']!;
      Future<void> search(String uniqueUsc, String xml) => expectLater(
        dio.post<String>(
          '/?module=Messages&file=searchUsers',
          data: {'val': 'Piet', 'xml': xml, 'uniqueUsc': uniqueUsc},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );

      await search('not-a-loaded-form', '<results></results>');
      await search(
        uniqueUsc,
        '<results><users><user><userID>201</userID></user></users></results>',
      );

      expect(server.searched, isEmpty);
      expect(guard.searches, 0);
      expect(_violations(guard), [
        contains('its compose form was not loaded through the guard'),
        contains('its selection (xml) is not the empty one'),
      ]);
    });

    test('a second login', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);
      expect(guard.loggedIn, isFalse);

      await dio.post<String>('/login', data: 'login form');
      // A test that logs in on purpose asks this first (#134).
      expect(guard.loggedIn, isTrue);
      await dio.post<String>('/2fa/api/v1/google-authenticator', data: '{}');
      await expectLater(
        dio.post<String>('/login', data: 'login form'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.post<String>('/2fa/api/v1/google-authenticator', data: '{}'),
        throwsA(isA<DioException>()),
      );

      expect(server.log, [
        'POST /login',
        'POST /2fa/api/v1/google-authenticator',
      ]);
      expect(_violations(guard), [
        contains('log in a second time in this run (its password)'),
        contains('log in a second time in this run (its 2FA code)'),
      ]);
    });

    test('a request to another host', () async {
      final server = _Smartschool(replyForm: _replyFormFromOwn);
      final (_, guard) = await _guarded(server);
      final dio = _dio(server, guard);

      await expectLater(
        dio.get<String>('https://example.com/'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get<String>('http://$_host/'),
        throwsA(isA<DioException>()),
      );

      expect(server.log, isEmpty);
      expect(_violations(guard), everyElement(contains('another host')));
    });
  });

  test('a refusal fails the test that sent the request, whatever the code '
      'under test does with the error', () async {
    final server = _Smartschool(replyForm: _replyFormFromOwn);
    final guard = LiveWireGuard(host: _host, runTag: _tag);
    final dio = _dio(server, guard);

    // What would fail this test is caught here instead, to be checked.
    final failures = <Object>[];
    await runZonedGuarded(() async {
      try {
        await dio.get<String>('https://example.com/');
      } on DioException {
        // The code under test swallows it.
      }
    }, (error, _) => failures.add(error));

    expect(failures, [isA<LiveGuardViolation>()]);
    expect(server.log, isEmpty);
  });
}
