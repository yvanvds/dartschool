// The wire-level guard of the live suite (#57).
//
// The live suite sends real messages, so it may send them to the own account
// only: the account of credentials.yml, in To, CC or BCC, never a group. The
// tests ask for nothing else, but a bug in the library or in a test could
// still register another recipient on a compose form (a reply form comes
// with its recipients registered on it already, #26, #42). So the live
// client gets this Dio interceptor, the last one, which sees every request as
// it goes out and every answer as it comes in, and refuses what the live
// suite may not do before it is sent:
// - a request to another host than the one of credentials.yml;
// - registering anyone but the own account on a compose form
//   (`addUserToSelected`), or an answer that registers anyone else;
// - a recipient search (`searchUsers` without a `function`,
//   MessagesService.searchRecipientsForCompose, #97) on a compose form that
//   was not loaded through the guard, or with another selection (`xml`)
//   than the empty one the library sends. A search only reads: it registers
//   no one on the form;
// - submitting a compose form that has anyone but the own account
//   registered, that stores the message in the LVS or schedules it, whose
//   subject lacks the run's tag, or that replies to a message the run did not
//   send to the own account only;
// - a `quick delete` (MessagesService.moveToTrash), of any ID, 0 included:
//   it names no box, Smartschool acts on whichever copy of the ID its own
//   session state points to, and one of a copy in the trash deletes it for
//   good (#19). Smartschool once answered a `quick delete` of ID 0, which
//   names no message, as one in the trash (#61);
// - moving a copy of a message to the trash with `quickmove messages`
//   (MessagesService.moveToTrashFrom, which names the box of the copy, #60)
//   unless it is a copy of a message this run sent: one that Smartschool
//   listed in that box, or in the archive folder of the inbox
//   (`message list`), with the run's subject, and that the run checked
//   there; a second move of a copy, whichever folder it is in; and a move
//   out of another box than the inbox or the sent box, out of a folder other
//   than the archive folder that Smartschool's Messages page names (#64), or
//   to another box than the trash. So the run moves no ID it did not send,
//   0 included (#61);
// - moving a message to the archive (MessagesService.moveToArchive) unless
//   it is the inbox copy of a message this run sent, listed in the inbox
//   with the run's subject and checked there, one per request; a second
//   archive move of a message, and one of a copy the run moved to the trash
//   (#64);
// - changing the read state or the flag of a message (`mark message read`,
//   `mark message unread`, `save msglabel`: MessagesService.markRead,
//   markUnread, setLabel) unless it is the inbox copy of a message this run
//   sent, listed in the inbox or in its archive folder with the run's subject
//   and checked there, and not moved to the trash; and one in a folder of the
//   inbox other than the archive folder (#94);
// - any request to the Presence module but its three POSTs that only read,
//   `getConfig`, `getAllCodes` and `getClass` (PresenceService.getConfig,
//   getAllCodes and getClassPupils, #104, #105): the live suite changes no
//   presence, so a save of presences (`savePupilsPresences`: setLate,
//   setPresent) never goes out;
// - any POST to the Skore module but its two RPC reads `getTeachers` of
//   `owners.php` and `getCourses` of `rapportbeheer/rpc/data.php`
//   (SkoreService.getTeachers, getGradebookShares and checkAccess, #91):
//   the live suite changes nothing in Skore, which drives the school's
//   grading and has no test instance, and both services also hold methods
//   that write, delete or lock (saveOwner, saveShared, deleteTeacher, ...);
// - any POST to the planner but its lookup of a calendar by ID
//   (`quick-search/planner/start`, PlannerService.getCalendar, #127), which
//   only reads: the live suite changes nothing in the planner, whose POSTs
//   also fill and clear lesson hours, add assignments and move a whole
//   period to the trash;
// - any Intradesk POST but the writes of IntradeskService that the live
//   suite tries (#128), and those only in the Intradesk folder it may write
//   in: "tests" in "2. SMA" at the root, as Smartschool's listings name it
//   and the run allows it (allowIntradeskFolder), or a folder the run made
//   there. So: the create of a folder (not a confidential one) or a weblink
//   in such a folder, named after the run ("dartschool test <run tag>");
//   taking an upload directory into such a folder (`files/upload`), once
//   per directory (a second time adds its files again), and only a
//   directory Smartschool handed out through the guard
//   (`get-upload-directory`); and the move to the trash of an item the run
//   made, of its kind, until Smartschool answered one for it. Never a
//   rename, move, copy or restore, and never a DELETE (deleted for good);
// - an upload (`/Upload/Upload/Index`) into another directory than the one
//   of a compose form loaded through the guard or one handed out through it
//   and not yet taken into Intradesk, or of a file the live suite did not
//   make;
// - any other request that changes something, and a second login.
//
// A refused request fails the test that sent it, as forbidRealNetwork() does
// (test/support/no_network.dart), whatever the library makes of the error.
//
// It also keeps every answer to an XML command that is not XML, such as the
// HTML page that Smartschool answered a `message list` with once (#106), and
// prints what the page is when the test fails: its status, whether it is the
// login page, its title and main heading, and the start of its text, without
// its scripts and forms (SmartschoolUnexpectedPageError.fromPage). It lets
// such an answer through: the library reports it.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// The start of the subject of every message the live suite sends, before
/// the run's tag (a reply's subject starts with `Re: ` before it).
const liveSubjectPrefix = '[dartschool test]';

/// The start of the name of every file the live suite attaches or uploads.
const liveFilePrefix = 'dartschool-test-';

/// The start of the name of every folder and weblink the live suite adds to
/// Intradesk (#128), before the run's tag.
const liveIntradeskPrefix = 'dartschool test';

/// The Intradesk folder the live suite may write in (#128): `tests`, in the
/// folder `2. SMA` at the root, as (parent, folder).
const liveIntradeskFolder = ('2. SMA', 'tests');

/// A request that [LiveWireGuard] did not let out, or an answer it did not
/// let through.
class LiveGuardViolation implements Exception {
  LiveGuardViolation(this.message);

  final String message;

  @override
  String toString() => 'LiveGuardViolation: $message';
}

/// Lets out only what the live suite may send (see the top of this file).
///
/// Add it to the live client's `dio` as its last interceptor, before the
/// first request, and set [own] before the first send. Until then, it
/// refuses every request that registers a recipient or sends a message.
class LiveWireGuard extends Interceptor {
  LiveWireGuard({
    required this.host,
    required this.runTag,
    // One per message of messages_live_test.dart: seven sends, and the
    // read-receipt one, which throws before any request (#43).
    this.maxSubmits = 8,
    // The creates of intradesk_write_live_test.dart: two folders, a weblink
    // and an upload (#128).
    this.maxIntradeskCreates = 6,
    void Function(LiveGuardViolation violation)? onViolation,
  }) : _onViolation = onViolation ?? _failTest;

  /// The host of credentials.yml: the only one requests may go to.
  final String host;

  /// The tag of this run, which every subject carries.
  final String runTag;

  /// How many messages the run may send at most.
  final int maxSubmits;

  /// How many Intradesk creates (a folder, a weblink, an upload) the run may
  /// send at most (#128).
  final int maxIntradeskCreates;

  final void Function(LiveGuardViolation violation) _onViolation;

  /// Fails the test that runs, also when the code under test catches the
  /// error the request fails with.
  static void _failTest(LiveGuardViolation violation) =>
      registerException(violation, StackTrace.current);

  /// Every violation so far, in order.
  final List<LiveGuardViolation> violations = [];

  /// How many requests the guard let out.
  int requestsSent = 0;

  /// How many messages (submits of a compose form) it let out.
  int submits = 0;

  /// How many recipient searches it let out (#97).
  int searches = 0;

  /// How many Intradesk creates it let out (#128).
  int intradeskCreates = 0;

  /// The own account: the only recipient a message may have.
  MessageSearchUser? get own => _own;
  MessageSearchUser? _own;
  set own(MessageSearchUser user) {
    final current = _own;
    if (current != null && _key(current) != _key(user)) {
      throw StateError('the own account of the run is set already');
    }
    _own = user;
  }

  /// The compose forms loaded through the guard, by their `uniqueUsc`.
  final Map<String, _Form> _forms = {};

  /// The messages the run sent to the own account only: the only ones it may
  /// reply to.
  final Set<int> _replyTargets = {};

  /// The copies of the run's messages that Smartschool listed, as (ID, box,
  /// folder): the headers with the run's subject in its answers to a
  /// `message list` of the inbox or the sent box, by the folder listed (`0`
  /// for the box itself). A move to the trash takes only the box itself or
  /// the archive folder of the inbox.
  final Set<(int, String, int)> _listed = {};

  /// The copies of messages the run may move to the trash out of their box
  /// (`quickmove messages`, MessagesService.moveToTrashFrom), as (ID, box,
  /// folder): those it sent and checked there.
  final Set<(int, String, int)> _movable = {};

  /// The copies the run asked to move to the trash, as (ID, box), whichever
  /// folder of the box they were in: a copy goes once.
  final Set<(int, String)> _moveRequested = {};

  /// The messages whose inbox copy the run may move to the archive: those it
  /// sent and checked in the inbox.
  final Set<int> _archivable = {};

  /// The messages whose inbox copy the run asked to move to the archive.
  final Set<int> _archiveRequested = {};

  /// The messages whose inbox copy the run may mark read or unread and flag
  /// (#94): those it sent and checked in the inbox or its archive folder.
  final Set<int> _markable = {};

  /// The archive folders that Smartschool's Messages page named (#64): one,
  /// unless pages named different ones.
  final Set<int> _archiveFolders = {};

  /// How often each step of a login went out.
  final Map<String, int> _loginSteps = {};

  /// The Intradesk folders Smartschool listed as `2. SMA` at the root.
  final Set<String> _intradeskParents = {};

  /// The Intradesk folders Smartschool listed as `tests` in a folder of
  /// [_intradeskParents].
  final Set<String> _intradeskTestFolders = {};

  /// The test folders the run allowed writes in ([allowIntradeskFolder]).
  final Set<String> _intradeskAllowed = {};

  /// What the run made in Intradesk, as Smartschool answered its creates: the
  /// kind (`folders`, `weblinks`, `files`) by ID.
  final Map<String, String> _intradeskMade = {};

  /// The items the run made that Smartschool answered a move to the trash
  /// for.
  final Set<String> _intradeskTrashed = {};

  /// The upload directories Smartschool handed out through the guard
  /// (`get-upload-directory`, #128).
  final Set<String> _uploadDirs = {};

  /// The upload directories the run had Intradesk take (`files/upload`).
  final Set<String> _uploadDirsTaken = {};

  /// Smartschool's answers to the moves to the trash out of a box, by
  /// (message ID, box), as they came in.
  final Map<(int, String), String> trashMoveAnswers = {};

  /// Smartschool's answers to the moves to the archive, by message ID, as
  /// they came in.
  final Map<int, String> archiveAnswers = {};

  /// Smartschool's answers to the changes of the read state and the flag of
  /// a message (#94), in order, with the command and the message ID.
  final List<({String action, int id, String answer})> markAnswers = [];

  /// The answers to an XML command that were not XML (#106), in order, each
  /// as the line that the test that got it prints when it fails: the
  /// command, the status and content type of the answer, and what the page
  /// is. An empty answer is not one of them: Smartschool answers some
  /// commands that change nothing that way (#59).
  final List<String> unexpectedAnswers = [];

  /// The archive folder of the inbox, as Smartschool's Messages page names it
  /// (MessagesService.getArchiveBoxId loads that page), or `null` while no
  /// page named one, or when pages named different ones: then the guard
  /// lets no move out of a folder go out.
  int? get archiveBoxId =>
      _archiveFolders.length == 1 ? _archiveFolders.single : null;

  /// Lets the run reply to message [msgId] of the inbox: a message it sent
  /// to the own account only.
  void allowReplyTo(int msgId) => _replyTargets.add(msgId);

  /// Lets the run move the copy of message [msgId] in [box] (the inbox or
  /// the sent box), or in its folder [boxId] (the archive folder of the
  /// inbox, #64), to the trash, once: a message it sent and checked there.
  ///
  /// The guard lets the move out only for a copy that Smartschool listed
  /// there with the run's subject too, whatever this allows (#61), and only
  /// out of the box itself or the archive folder that the Messages page
  /// names.
  void allowTrashFrom(int msgId, BoxType box, {int boxId = 0}) =>
      _movable.add((msgId, box.value, boxId));

  /// Lets the run move the inbox copy of message [msgId] to the archive,
  /// once: a message it sent and checked in the inbox (#64).
  ///
  /// The guard lets the move out only for a copy that Smartschool listed in
  /// the inbox with the run's subject too, whatever this allows.
  void allowArchive(int msgId) => _archivable.add(msgId);

  /// Lets the run mark the inbox copy of message [msgId] read or unread and
  /// set its flag, in the inbox or in its archive folder: a message it sent
  /// and checked there (#94).
  ///
  /// The guard lets such a change out only for a copy that Smartschool
  /// listed there with the run's subject too, whatever this allows, and that
  /// the run did not move to the trash.
  void allowMark(int msgId) => _markable.add(msgId);

  /// Lets the run write in the Intradesk folder [folderId] (#128): the test
  /// folder, `tests` in `2. SMA` at the root.
  ///
  /// The guard lets a write in it out only when Smartschool listed it so
  /// too (the root listing and that of `2. SMA`, read through the guard),
  /// whatever this allows; and in the folders the run made in it.
  void allowIntradeskFolder(String folderId) =>
      _intradeskAllowed.add(folderId.toLowerCase());

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final refusal = _guarded(() => _requestRefusal(options));
    if (refusal != null) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: _violation('${_describe(options)} was not sent: $refusal'),
        ),
        true,
      );
      return;
    }
    requestsSent++;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final refusal = _guarded(() => _answerRefusal(response));
    if (refusal != null) {
      final options = response.requestOptions;
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          error: _violation('the answer to ${_describe(options)}: $refusal'),
        ),
        true,
      );
      return;
    }
    handler.next(response);
  }

  /// What [check] returns, or why the guard could not check: a request or an
  /// answer it cannot read is refused.
  static String? _guarded(String? Function() check) {
    try {
      return check();
    } on Object catch (e) {
      return 'the guard could not check it ($e)';
    }
  }

  LiveGuardViolation _violation(String message) {
    final violation = LiveGuardViolation(message);
    violations.add(violation);
    _onViolation(violation);
    return violation;
  }

  /// The method and the URL of a request, without its host. Neither ever
  /// holds a credential: the password, the 2FA code and the cookies are in
  /// the body and the headers, which this never shows.
  static String _describe(RequestOptions options) {
    final uri = options.uri;
    return '${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  /// Why [options] may not go out, or `null` when it may.
  String? _requestRefusal(RequestOptions options) {
    final uri = options.uri;
    if (uri.scheme != 'https' || uri.host != host) {
      return 'it goes to another host than the one of credentials.yml';
    }
    final method = options.method.toUpperCase();
    if (method == 'GET') return null;
    if (method != 'POST') return 'the live suite sends no $method';

    final path = uri.path;
    if (path.endsWith('/login')) return _loginStep('password');
    if (path.startsWith('/2fa/')) return _loginStep('2FA code');
    if (path.endsWith('/account-verification')) {
      return _loginStep('account verification');
    }
    if (path == '/Upload/Upload/Index') return _uploadRefusal(options.data);
    if (path == _archivePath) return _archiveRefusal(options.data);
    if (path.startsWith('/Presence/')) return _presenceRefusal(path);
    if (path.startsWith('/modules/Skore/')) {
      return _skoreRefusal(path, options.data);
    }
    if (path.startsWith('/planner/')) return _plannerRefusal(path);
    if (path.startsWith('/intradesk/')) {
      return _intradeskRefusal(path, options.data);
    }

    final query = uri.queryParameters;
    if (path == '/' && query['module'] == 'Messages') {
      switch ((query['file'], query['function'])) {
        case ('dispatcher', _):
          return _commandRefusal(options.data);
        case ('searchUsers', null):
          return _searchRefusal(options.data);
        case ('searchUsers', 'addUserToSelected'):
          return _addRefusal(options.data);
        case ('searchUsers', 'deleteUsersFromSelected'):
          return _removeRefusal(options.data);
        case ('composeMessage', _):
          return _submitRefusal(uri, options.data);
      }
    }
    return 'it is not a request the live suite sends';
  }

  /// Counts a POST of the login chain; refuses the second of a kind: the run
  /// logs in at most once.
  String? _loginStep(String step) {
    final count = (_loginSteps[step] ?? 0) + 1;
    _loginSteps[step] = count;
    if (count == 1) return null;
    return 'it would log in a second time in this run (its $step); the live '
        'suite logs in at most once per run';
  }

  /// The Presence module's POSTs that only read: its config and the pupils
  /// of a class on a day (#104), and the codes of a school structure (#105).
  static const _presenceReads = {
    '/Presence/Main/getConfig',
    '/Presence/Code/getAllCodes',
    '/Presence/Class/getClass',
  };

  /// Why the Presence request to [path] may not go out, or `null`: only the
  /// reads go out, never a save of presences.
  String? _presenceRefusal(String path) {
    if (_presenceReads.contains(path)) return null;
    return 'the live suite changes no presence: it sends no Presence request '
        'but the reads getConfig, getAllCodes and getClass (#104, #105)';
  }

  /// The Skore RPC POSTs that only read, by path: the one method of each
  /// service the live suite calls (#91).
  static const _skoreReads = {
    '/modules/Skore/backend/models/owners.php': 'getTeachers',
    '/modules/Skore/modules/rapportbeheer/rpc/data.php': 'getCourses',
  };

  /// Why the Skore POST to [path] with [data] may not go out, or `null`:
  /// only the reads go out, never a save.
  String? _skoreRefusal(String path, Object? data) {
    final method = data is Map ? data['rpc_method'] : null;
    if (method != null && _skoreReads[path] == method) return null;
    return 'the live suite changes nothing in Skore: it sends no Skore POST '
        'but the reads getTeachers (owners.php) and getCourses '
        '(rapportbeheer/rpc/data.php) (#91)';
  }

  /// The planner's POSTs that the live suite sends, which only read: the
  /// lookup of a calendar by ID (PlannerService.getCalendar, #127).
  static const _plannerReads = {'/planner/api/v1/quick-search/planner/start'};

  /// Why the planner POST to [path] may not go out, or `null`: only the
  /// lookup goes out, never a write.
  String? _plannerRefusal(String path) {
    if (_plannerReads.contains(path)) return null;
    return 'the live suite changes nothing in the planner: it sends no '
        'planner POST but the lookup of a calendar by ID, '
        'quick-search/planner/start (#127)';
  }

  /// An Intradesk API path: the platform and the rest.
  static final _intradeskPath = RegExp(r'^/intradesk/api/v1/(\d+)/(.+)$');

  /// A move to the trash of an Intradesk item: its kind and its ID.
  static final _intradeskTrash = RegExp(
    r'^(folders|weblinks|files)/([^/]+)/trash$',
  );

  /// The start of the name of every folder and weblink of the run.
  String get _intradeskTagged => '$liveIntradeskPrefix $runTag';

  /// Why the Intradesk POST to [path] with the JSON body [data] may not go
  /// out, or `null` (#128).
  String? _intradeskRefusal(String path, Object? data) {
    final rest = _intradeskPath.firstMatch(path)?.group(2);
    switch (rest) {
      case 'folders/':
        return _intradeskCreateRefusal('a folder', data);
      case 'weblinks/':
        return _intradeskCreateRefusal('a weblink', data);
      case 'files/upload':
        return _intradeskTakeRefusal(data);
    }
    final trash = rest == null ? null : _intradeskTrash.firstMatch(rest);
    if (trash != null) {
      return _intradeskTrashRefusal(trash.group(1)!, trash.group(2)!);
    }
    return 'the live suite sends no Intradesk POST but the creates of a '
        'folder (not a confidential one) and a weblink, the take of an upload '
        '(files/upload) and moves to the trash of what it made (#128)';
  }

  /// Whether the run may add to the Intradesk folder [folderId]: the test
  /// folder, as Smartschool listed it and the run allowed it, or a folder
  /// the run made (in it) and did not move to the trash.
  bool _mayWriteIn(String folderId) {
    final id = folderId.toLowerCase();
    if (_intradeskTestFolders.contains(id) && _intradeskAllowed.contains(id)) {
      return true;
    }
    return _intradeskMade[id] == 'folders' && !_intradeskTrashed.contains(id);
  }

  /// Why the parent folder of the Intradesk write [data] may not be written
  /// in, or `null`.
  String? _intradeskParentRefusal(Map<dynamic, dynamic> data) {
    final parent = data['parentFolderId'];
    if (parent is String && _mayWriteIn(parent)) return null;
    return 'it adds to Intradesk folder "$parent", which is neither the test '
        'folder ("${liveIntradeskFolder.$1}" > "${liveIntradeskFolder.$2}", '
        'as Smartschool listed it and the run allowed it) nor a folder the '
        'run made there';
  }

  /// Why the create of [item] with the JSON body [data] may not go out, or
  /// `null`.
  String? _intradeskCreateRefusal(String item, Object? data) {
    if (data is! Map) return 'it carries no JSON body';
    final parent = _intradeskParentRefusal(data);
    if (parent != null) return parent;
    final name = data['name'];
    if (name is! String || !name.startsWith(_intradeskTagged)) {
      return 'the name of $item does not start with "$_intradeskTagged"';
    }
    return _countIntradeskCreate();
  }

  /// Why the take of an upload directory into Intradesk (`files/upload`)
  /// with the JSON body [data] may not go out, or `null`.
  String? _intradeskTakeRefusal(Object? data) {
    if (data is! Map) return 'it carries no JSON body';
    final parent = _intradeskParentRefusal(data);
    if (parent != null) return parent;
    final dir = data['uploadDir'];
    if (dir is! String || !_uploadDirs.contains(dir)) {
      return 'its upload directory was not handed out through the guard';
    }
    if (_uploadDirsTaken.contains(dir)) {
      return 'its upload directory was taken into Intradesk already: a '
          'second time adds its files again';
    }
    final count = _countIntradeskCreate();
    if (count != null) return count;
    _uploadDirsTaken.add(dir);
    return null;
  }

  /// Counts an Intradesk create; refuses one more than
  /// [maxIntradeskCreates].
  String? _countIntradeskCreate() {
    if (intradeskCreates >= maxIntradeskCreates) {
      return 'the run sent $maxIntradeskCreates Intradesk creates already, '
          'its maximum';
    }
    intradeskCreates++;
    return null;
  }

  /// Why the move of the Intradesk item [id] of the kind [kind] to the
  /// trash may not go out, or `null`: only an item the run made, of that
  /// kind, until Smartschool answered a move to the trash for it.
  String? _intradeskTrashRefusal(String kind, String id) {
    final made = _intradeskMade[id.toLowerCase()];
    if (made == null) {
      return 'it moves Intradesk item $id to the trash, which this run did '
          'not make';
    }
    if (made != kind) {
      return 'it moves Intradesk item $id to the trash as one of the $kind, '
          'but the run made it as one of the $made';
    }
    if (_intradeskTrashed.contains(id.toLowerCase())) {
      return 'Intradesk item $id was moved to the trash already in this run';
    }
    return null;
  }

  /// The XML commands that only read.
  static const _readActions = {
    'message list',
    'continue_messages',
    'show message',
    'attachment list',
  };

  String? _commandRefusal(Object? data) {
    final command = data is Map ? data['command'] : null;
    if (command is! String) return 'it carries no XML command';
    final xml = XmlDocument.parse(command);
    final subsystem = _text(xml, 'subsystem');
    final action = _text(xml, 'action');
    if (subsystem != 'postboxes') {
      return 'the live suite sends no "$subsystem" command';
    }
    if (_readActions.contains(action)) return null;
    if (action == 'quickmove messages') return _moveRefusal(xml);
    if (_markActions.contains(action)) return _markRefusal(action, xml);
    if (action == 'quick delete') {
      return 'the live suite sends no quick delete (moveToTrash), of any '
          'ID: it names no box, Smartschool acts on whichever copy of the ID '
          'its session state points to, and one of a copy in the trash '
          'deletes it for good (#19, #61)';
    }
    return 'the live suite sends no "$action" command';
  }

  /// Why the `quickmove messages` command [xml] may not go out, or `null`.
  ///
  /// It moves one copy of a message, the one in the box (and folder) it
  /// names, as the web client does when a message is dragged onto the trash
  /// (#60). The live suite sends it only to move the inbox or sent-box copy
  /// of a message it sent to the trash, once per copy: a copy that
  /// Smartschool listed in that box, or in the archive folder of the inbox
  /// (#64), with the run's subject, and that the run checked there. It may
  /// do so while the other copy is in the trash: that the move takes the
  /// copy of the box it names, and leaves the other one alone, was seen live.
  String? _moveRefusal(XmlDocument xml) {
    final id = int.tryParse(_param(xml, 'msgID') ?? '');
    if (id == null) return 'its move names no message';
    if (id <= 0) {
      return 'it moves message $id, which names no message: the live suite '
          'moves only messages it sent (#61)';
    }
    if (_param(xml, 'toBoxType') != BoxType.trash.value ||
        _param(xml, 'toBoxID') != '0') {
      return 'it moves message $id elsewhere than to the trash';
    }
    final box = _param(xml, 'boxType') ?? '';
    if (box != BoxType.inbox.value && box != BoxType.sent.value) {
      return 'it moves message $id out of the "$box": the live suite moves '
          'only copies in the inbox or the sent box to the trash';
    }
    final archive = archiveBoxId;
    final int folder;
    switch (_param(xml, 'boxID')) {
      case '0':
        folder = 0;
      case final named?
          when archive != null &&
              box == BoxType.inbox.value &&
              named == '$archive':
        folder = archive;
      default:
        return 'it moves message $id out of a folder of the $box that is not '
            'the archive folder of the inbox, as a Messages page named it';
    }
    final where = folder == 0
        ? 'the $box'
        : 'the archive folder ($folder) of the inbox';
    if (!_listed.contains((id, box, folder))) {
      return 'Smartschool did not list message $id in $where with the '
          "run's subject: it is not a message this run sent (#61)";
    }
    if (!_movable.contains((id, box, folder))) {
      return 'the $box copy of message $id is not one this run sent and '
          'checked in $where';
    }
    if (!_moveRequested.add((id, box))) {
      return 'the $box copy of message $id was moved to the trash already in '
          'this run';
    }
    return null;
  }

  /// The XML commands that change the read state (`mark message read`,
  /// `mark message unread`) or the flag (`save msglabel`) of a message.
  static const _markActions = {
    'mark message read',
    'mark message unread',
    'save msglabel',
  };

  /// Why the [action] command [xml], which changes the read state or the
  /// flag of a message, may not go out, or `null` (#94).
  ///
  /// The live suite sends it only for the inbox copy of a message it sent,
  /// in the inbox or in its archive folder: a copy that Smartschool listed
  /// there with the run's subject, that the run checked there, and that it
  /// did not move to the trash. `mark message unread` names the folder of
  /// the copy (`boxID`), as the web client sends it; `mark message read` and
  /// `save msglabel` name none, as the web client sends them for a message
  /// in a folder too, so the copy may then be in the inbox or in its archive
  /// folder.
  String? _markRefusal(String action, XmlDocument xml) {
    final id = int.tryParse(_param(xml, 'msgID') ?? '');
    if (id == null) return 'its $action names no message';
    if (id <= 0) {
      return 'it changes message $id, which names no message: the live suite '
          'changes only messages it sent (#61)';
    }
    final box = _param(xml, 'boxType') ?? '';
    if (box != BoxType.inbox.value) {
      return 'it changes the $box copy of message $id: the live suite changes '
          'the read state and the flag of inbox copies only';
    }
    final archive = archiveBoxId;
    final List<int> folders;
    switch (_param(xml, 'boxID')) {
      case null:
        folders = [0, ?archive];
      case '0':
        folders = [0];
      case final named when archive != null && named == '$archive':
        folders = [archive];
      default:
        return 'it changes message $id in a folder of the inbox that is not '
            'the archive folder, as a Messages page named it';
    }
    if (!folders.any((folder) => _listed.contains((id, box, folder)))) {
      final where = switch (folders) {
        [0] => 'the inbox',
        [final folder] => 'the archive folder ($folder) of the inbox',
        _ => 'the inbox or its archive folder (${folders.last})',
      };
      return "Smartschool did not list message $id in $where with the run's "
          'subject: it is not a message this run sent (#61)';
    }
    if (!_markable.contains(id)) {
      return 'message $id is not one this run sent and checked to change its '
          'read state and flag';
    }
    if (_moveRequested.contains((id, box))) {
      return 'the inbox copy of message $id was moved to the trash already in '
          'this run';
    }
    return null;
  }

  /// The path of MessagesService.moveToArchive's request.
  static const _archivePath = '/Messages/Xhr/archivemessages';

  /// Why the move to the archive with the form body [data] may not go out,
  /// or `null` (#64).
  ///
  /// It names the messages only (`msgIDs[]`), not a box: the archive is a
  /// folder of the inbox, and the live suite sends it only to move the inbox
  /// copy of a message it sent there, one message per request, once: a copy
  /// that Smartschool listed in the inbox with the run's subject, and that
  /// the run checked there. The inbox no longer lists it then, so a move to
  /// the trash out of the inbox needs a new listing there.
  String? _archiveRefusal(Object? data) {
    if (data is! String) return 'it carries no form body';
    final fields = [
      for (final pair in data.split('&'))
        if (pair.isNotEmpty) pair.split('='),
    ];
    if (fields.length != 1) {
      return 'it archives ${fields.length} messages at once: the live suite '
          'archives one message per request';
    }
    final field = fields.single;
    final id =
        field.length == 2 && Uri.decodeQueryComponent(field[0]) == 'msgIDs[]'
        ? int.tryParse(Uri.decodeQueryComponent(field[1]))
        : null;
    if (id == null) return 'its move to the archive names no message';
    if (id <= 0) {
      return 'it archives message $id, which names no message: the live '
          'suite archives only messages it sent (#61)';
    }
    if (_archiveRequested.contains(id)) {
      return 'message $id was moved to the archive already in this run';
    }
    final inbox = BoxType.inbox.value;
    if (_moveRequested.contains((id, inbox))) {
      return 'the inbox copy of message $id was moved to the trash already in '
          'this run';
    }
    if (!_listed.contains((id, inbox, 0))) {
      return 'Smartschool did not list message $id in the inbox with the '
          "run's subject: it is not a message this run sent (#61)";
    }
    if (!_archivable.contains(id)) {
      return 'message $id is not one this run sent and checked in the inbox '
          'to archive';
    }
    _archiveRequested.add(id);
    _listed.remove((id, inbox, 0));
    return null;
  }

  /// The selection that MessagesService.searchRecipientsForCompose sends
  /// with a search: none.
  static const _emptySelection = '<results></results>';

  /// Why the recipient search with the fields [data] may not go out, or
  /// `null` (#97): only on a compose form loaded through the guard, and with
  /// the empty selection the library sends.
  String? _searchRefusal(Object? data) {
    if (data is! Map) return 'it carries no form fields';
    final form = _formRefusal(data['uniqueUsc']);
    if (form != null) return form;
    if (data['xml'] != _emptySelection) {
      return 'its selection (xml) is not the empty one the library sends '
          '($_emptySelection)';
    }
    searches++;
    return null;
  }

  String? _addRefusal(Object? data) {
    final own = _own;
    if (own == null) return 'the own account of the run is not known yet';
    if (data is! Map) return 'it carries no form fields';
    final formRefusal = _formRefusal(data['uniqueUsc']);
    if (formRefusal != null) return formRefusal;
    if (data['typeId'] != 'users') {
      return 'it registers a group; the live suite sends to the own account '
          'only';
    }
    if (!const {'0', '2', '3'}.contains(data['type'])) {
      return 'it registers a recipient in another field than To, CC or BCC';
    }
    if (data['id'] != '${own.userId}' ||
        data['ssid'] != '${own.ssId}' ||
        data['userlt'] != '${own.userLt}') {
      return 'it registers someone other than the own account';
    }
    return null;
  }

  String? _removeRefusal(Object? data) {
    if (data is! Map) return 'it carries no form fields';
    return _formRefusal(data['uniqueUsc']);
  }

  String? _uploadRefusal(Object? data) {
    if (data is! FormData) return 'it is not a multipart upload';
    final folder = _field(data, 'uploadDir');
    final handedOut =
        _uploadDirs.contains(folder) && !_uploadDirsTaken.contains(folder);
    if (folder == null ||
        !(handedOut || _forms.values.any((f) => f.randomDir == folder))) {
      return 'it uploads to a folder that is neither the one of a compose '
          'form loaded through the guard nor an upload directory handed out '
          'through it and not yet taken into Intradesk (#128)';
    }
    if (data.files.isEmpty) return 'it uploads no file';
    for (final file in data.files) {
      final name = file.value.filename ?? '';
      if (!name.startsWith(liveFilePrefix)) {
        return 'it uploads a file that the live suite did not make';
      }
    }
    return null;
  }

  String? _submitRefusal(Uri uri, Object? data) {
    final own = _own;
    if (own == null) return 'the own account of the run is not known yet';
    if (data is! FormData) return 'it is not a multipart submit';
    if (data.files.isNotEmpty) {
      return 'a compose form is submitted without files';
    }
    final fields = {for (final field in data.fields) field.key: field.value};
    if (fields['send'] != 'send') return 'it is not a send';
    final formRefusal = _formRefusal(fields['uniqueUsc']);
    if (formRefusal != null) return formRefusal;
    final form = _forms[fields['uniqueUsc']]!;

    final query = uri.queryParameters;
    if (!_sameQuery(form.url.queryParameters, query)) {
      return 'it goes to another URL than its compose form was loaded from';
    }
    for (final name in const ['boxType', 'composeType', 'msgID']) {
      if (fields[name] != query[name]) {
        return 'its $name does not match its URL';
      }
    }
    switch (query['composeType']) {
      case '0':
        break;
      case '1' || '2':
        final target = int.tryParse(query['msgID'] ?? '');
        if (query['boxType'] != BoxType.inbox.value ||
            target == null ||
            !_replyTargets.contains(target)) {
          return 'it replies to a message that this run did not send to the '
              'own account only';
        }
      default:
        return 'it is neither a new message nor a reply';
    }

    if (form.recipients.isEmpty) return 'its compose form has no recipient';
    if (!form.recipients.values.every((r) => r.isOwn(own))) {
      return 'its compose form has someone other than the own account '
          'registered';
    }
    if (fields['copyToLVS'] != LvsCopy.none.value) {
      return 'it stores the message in the LVS';
    }
    if ((fields['sendDate'] ?? '').isNotEmpty) {
      return 'it schedules the message for later';
    }
    if (!_isRunSubject(fields['subject'] ?? '')) {
      return 'its subject does not start with "$_tagged"';
    }
    if (submits >= maxSubmits) {
      return 'the run sent $maxSubmits messages already, its maximum';
    }
    submits++;
    return null;
  }

  /// Why the compose form with [uniqueUsc] may not be used, or `null`.
  String? _formRefusal(Object? uniqueUsc) {
    final form = _forms[uniqueUsc];
    if (form == null) {
      return 'its compose form was not loaded through the guard';
    }
    final unusable = form.unusable;
    if (unusable != null) return 'its compose form is unusable: $unusable';
    return null;
  }

  // -------------------------------------------------------------------------
  // Answers
  // -------------------------------------------------------------------------

  /// Why [response] may not reach the library, or `null` when it may; keeps
  /// track of the compose forms and what is registered on them.
  String? _answerRefusal(Response<dynamic> response) {
    final options = response.requestOptions;
    final uri = options.uri;
    final query = uri.queryParameters;
    final body = response.data is String ? response.data as String : '';
    if (uri.path == _archivePath) {
      _recordArchiveAnswer(options.data, body);
      return null;
    }
    if (uri.path.startsWith('/intradesk/') ||
        uri.path == _uploadDirectoryPath) {
      _recordIntradeskAnswer(options, response.statusCode ?? 0, body);
      return null;
    }
    if (uri.path != '/' || query['module'] != 'Messages') return null;
    switch ((options.method.toUpperCase(), query['file'], query['function'])) {
      case ('GET', 'index', 'main'):
        final folder = MessagesService.parseArchiveBoxIdFromMessagesHtml(body);
        if (folder != null && folder > 0) _archiveFolders.add(folder);
      case ('GET', 'composeMessage', _):
        _recordForm(uri, body);
      case ('POST', 'searchUsers', 'addUserToSelected'):
        return _addedRefusal(options.data, body);
      case ('POST', 'searchUsers', 'deleteUsersFromSelected'):
        _recordRemoved(options.data, body);
      case ('POST', 'dispatcher', _):
        _noteUnexpectedAnswer(options.data, response, body);
        _recordCommandAnswer(options.data, body);
    }
    return null;
  }

  /// Keeps Smartschool's answer [body] to the XML command with the fields
  /// [data] in [unexpectedAnswers] when it is not XML, and prints it when the
  /// test fails (#106).
  void _noteUnexpectedAnswer(
    Object? data,
    Response<dynamic> response,
    String body,
  ) {
    final trimmed = body.trim();
    if (trimmed.isEmpty || _isXml(trimmed)) return;
    final command = data is Map ? data['command'] : null;
    final action = command is String
        ? _text(XmlDocument.parse(command), 'action')
        : '(no command)';
    final page = SmartschoolUnexpectedPageError.fromPage(
      body,
      action: action,
      statusCode: response.statusCode,
      contentType: response.headers.value(Headers.contentTypeHeader),
    );
    final line = [
      'Smartschool answered "$action" with something that is not XML '
          '(#106): status ${response.statusCode}',
      page.contentType ?? 'no content type',
      page.isLoginPage ? 'its login page' : 'not its login page',
      if (page.title != null) 'title "${page.title}"',
      if (page.heading != null) 'heading "${page.heading}"',
      'text "${page.excerpt ?? ''}"',
    ].join(', ');
    unexpectedAnswers.add(line);
    try {
      printOnFailure(line);
    } on StateError {
      // Not in a test: the line is in unexpectedAnswers.
    }
  }

  /// Whether [body], a trimmed answer, is an XML document, and not an HTML
  /// page (which can be one too).
  static bool _isXml(String body) {
    if (_htmlStart.hasMatch(body)) return false;
    try {
      XmlDocument.parse(body);
      return true;
    } on XmlException {
      return false;
    }
  }

  static final _htmlStart = RegExp(
    r'^<(!doctype\s+html|html)\b',
    caseSensitive: false,
  );

  /// Keeps the compose form of [html], loaded from [url], with the
  /// recipients it names: a reply form has them registered already.
  void _recordForm(Uri url, String html) {
    final hidden = MessagesService.parseHiddenFields(html);
    final uniqueUsc = hidden['uniqueUsc'] ?? '';
    if (uniqueUsc.isEmpty) return;
    final form = _Form(url, hidden['randomDir'] ?? '');
    final page = html_parser.parse(html);
    for (final span in page.querySelectorAll('div.receiverSpan')) {
      final a = span.attributes;
      final recipient = _Recipient(
        type: a['typeatt'] ?? '0',
        id: a['idatt'] ?? '',
        ssId: a['ssidatt'] ?? '',
        userLt: a['userltatt'] ?? '0',
        realUserId: a['realuserid'] ?? '',
        isUser: a['typeidatt'] == 'users',
      );
      form.recipients[recipient.key] = recipient;
    }
    _forms[uniqueUsc] = form;
  }

  /// Checks that Smartschool's answer [body] to `addUserToSelected` with the
  /// fields [data] registered the own account only, and keeps what it
  /// registered. An answer the guard cannot read makes the form unusable.
  String? _addedRefusal(Object? data, String body) {
    final form = _forms[(data as Map)['uniqueUsc']]!;
    if (body.trim().isEmpty) return null; // Nothing registered.
    final Iterable<XmlElement> users;
    try {
      users = XmlDocument.parse(body).findAllElements('user');
    } on XmlException {
      form.unusable = 'an answer to addUserToSelected was not XML';
      return form.unusable;
    }
    for (final user in users) {
      final recipient = _Recipient(
        type: _text(user, 'type'),
        id: _text(user, 'userID'),
        ssId: _text(user, 'ssID'),
        userLt: _text(user, 'userLT'),
        realUserId: _text(user, 'realUserId'),
        isUser: _text(user, 'typeId') == 'users',
      );
      form.recipients[recipient.key] = recipient;
      if (!recipient.isOwn(_own!)) {
        form.unusable =
            'Smartschool registered someone other than the own '
            'account on it';
        return form.unusable;
      }
    }
    return null;
  }

  /// Drops the recipients that Smartschool's answer [body] to
  /// `deleteUsersFromSelected` lists as taken off the form. An answer the
  /// guard cannot read takes nothing off.
  void _recordRemoved(Object? data, String body) {
    final form = _forms[(data as Map)['uniqueUsc']];
    if (form == null || body.trim().isEmpty) return;
    try {
      for (final user in XmlDocument.parse(body).findAllElements('user')) {
        form.recipients.remove(
          _Recipient.keyOf(
            _text(user, 'type'),
            _text(user, 'userID'),
            _text(user, 'ssID'),
            _text(user, 'userLT'),
          ),
        );
      }
    } on XmlException {
      return;
    }
  }

  void _recordCommandAnswer(Object? data, String body) {
    final command = data is Map ? data['command'] : null;
    if (command is! String) return;
    final xml = XmlDocument.parse(command);
    switch (_text(xml, 'action')) {
      case 'message list':
        _recordListed(xml, body);
      case 'quickmove messages':
        final id = int.tryParse(_param(xml, 'msgID') ?? '');
        if (id == null) return;
        trashMoveAnswers[(id, _param(xml, 'boxType') ?? '')] = body;
      case final action when _markActions.contains(action):
        final id = int.tryParse(_param(xml, 'msgID') ?? '');
        if (id == null) return;
        markAnswers.add((action: action, id: id, answer: body));
    }
  }

  /// The path that hands out an upload directory (#128).
  static const _uploadDirectoryPath = '/upload/api/v1/get-upload-directory';

  /// Keeps what Smartschool's answer [body], with [status], to the Intradesk
  /// request [options] (or to a request for an upload directory) says the
  /// run may write in or to (#128): the upload directory it hands out, the
  /// test folder its listings name, the items the run made, and those it
  /// moved to the trash. An answer the guard cannot read says nothing.
  void _recordIntradeskAnswer(RequestOptions options, int status, String body) {
    final path = options.uri.path;
    final method = options.method.toUpperCase();
    Object? json() {
      try {
        return jsonDecode(body);
      } on FormatException {
        return null;
      }
    }

    if (path == _uploadDirectoryPath) {
      final answer = json();
      final dir = answer is Map ? answer['uploadDir'] : null;
      if (status == 200 && dir is String && dir.isNotEmpty) {
        _uploadDirs.add(dir);
      }
      return;
    }
    final rest = _intradeskPath.firstMatch(path)?.group(2);
    if (rest == null) return;
    if (method == 'GET') {
      _recordIntradeskListing(rest, status, json());
      return;
    }
    if (status < 200 || status >= 300) return;
    if (rest == 'folders/' || rest == 'weblinks/') {
      final answer = json();
      final id = answer is Map ? answer['id'] : null;
      if (id is String && id.isNotEmpty) {
        _intradeskMade[id.toLowerCase()] = rest.substring(0, rest.length - 1);
      }
      return;
    }
    if (rest == 'files/upload') {
      final answer = json();
      final files = answer is Map ? answer['files'] : null;
      if (files is Map) {
        for (final id in files.keys) {
          _intradeskMade['$id'.toLowerCase()] = 'files';
        }
      }
      return;
    }
    final trash = _intradeskTrash.firstMatch(rest);
    if (trash != null) _intradeskTrashed.add(trash.group(2)!.toLowerCase());
  }

  /// Keeps the test folder that the Intradesk listing [answer] of [rest]
  /// (`directory-listing/forTreeOnlyFolders[/<id>]`) names: `2. SMA` at the
  /// root, and `tests` in it.
  void _recordIntradeskListing(String rest, int status, Object? answer) {
    const listing = 'directory-listing/forTreeOnlyFolders';
    if (status != 200 || answer is! Map) return;
    final folders = answer['folders'];
    if (folders is! List) return;
    final String listed;
    if (rest == listing) {
      listed = '';
    } else if (rest.startsWith('$listing/')) {
      listed = rest.substring(listing.length + 1).toLowerCase();
    } else {
      return;
    }
    final (parentName, folderName) = liveIntradeskFolder;
    for (final folder in folders.whereType<Map<dynamic, dynamic>>()) {
      final id = folder['id'];
      final parent = '${folder['parentFolderId'] ?? ''}'.toLowerCase();
      if (id is! String || parent != listed) continue;
      if (listed.isEmpty && folder['name'] == parentName) {
        _intradeskParents.add(id.toLowerCase());
      } else if (_intradeskParents.contains(listed) &&
          folder['name'] == folderName) {
        _intradeskTestFolders.add(id.toLowerCase());
      }
    }
  }

  /// Keeps Smartschool's answer [body] to the move to the archive with the
  /// form body [data], which the guard let out with one message ID.
  void _recordArchiveAnswer(Object? data, String body) {
    if (data is! String) return;
    final id = int.tryParse(Uri.decodeQueryComponent(data.split('=').last));
    if (id != null) archiveAnswers[id] = body;
  }

  /// Keeps the copies of the run's messages that Smartschool's answer [body]
  /// to the `message list` [command] lists: the headers with the run's
  /// subject, read as MessagesService.getHeaders reads them, when the list
  /// is of the inbox or the sent box, by the folder listed (`0` for the box
  /// itself). An answer the guard cannot read lists none, so no move of what
  /// it lists goes out.
  void _recordListed(XmlDocument command, String body) {
    final box = _param(command, 'boxType') ?? '';
    if (box != BoxType.inbox.value && box != BoxType.sent.value) return;
    final folder = int.tryParse(_param(command, 'boxID') ?? '');
    if (folder == null || folder < 0) return;
    final List<ShortMessage> headers;
    try {
      headers = XmlInterface.parseResponse(
        body,
        './/messages/message',
      ).map(ShortMessage.fromXml).toList();
    } on Object {
      return; // The library reports what it cannot read itself.
    }
    for (final header in headers) {
      if (_isRunSubject(header.subject)) _listed.add((header.id, box, folder));
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// The start of the subject of every message of the run, after `Re: ` for
  /// a reply.
  String get _tagged => '$liveSubjectPrefix $runTag ';

  /// Whether [subject] is the subject of a message of the run.
  bool _isRunSubject(String subject) =>
      subject.startsWith(_tagged) || subject.startsWith('Re: $_tagged');

  static String _key(MessageSearchUser user) =>
      '${user.userId}|${user.ssId}|${user.userLt}';

  static String _text(XmlNode node, String name) =>
      node.findAllElements(name).firstOrNull?.innerText.trim() ?? '';

  static String? _param(XmlNode command, String name) => command
      .findAllElements('param')
      .where((param) => param.getAttribute('name') == name)
      .firstOrNull
      ?.innerText
      .trim();

  static String? _field(FormData data, String name) =>
      data.fields.where((field) => field.key == name).firstOrNull?.value;

  static bool _sameQuery(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// A compose form that was loaded through the guard.
class _Form {
  _Form(this.url, this.randomDir);

  /// The URL it was loaded from, which its submit goes to.
  final Uri url;

  /// Its upload folder.
  final String randomDir;

  /// What is registered on it, by [_Recipient.key].
  final Map<String, _Recipient> recipients = {};

  /// Why it may not be used anymore, or `null`.
  String? unusable;
}

/// A recipient registered on a compose form, as its entry on the form
/// (`div.receiverSpan`) and Smartschool's answers to `addUserToSelected` and
/// `deleteUsersFromSelected` name it.
class _Recipient {
  _Recipient({
    required this.type,
    required this.id,
    required this.ssId,
    required this.userLt,
    required this.realUserId,
    required this.isUser,
  });

  /// The field: `0` To, `2` CC, `3` BCC (`1`, `4`, `5` co-account fields).
  final String type;

  /// The ID with Smartschool's prefix (`U` for a user), as `idatt`/`userID`.
  final String id;
  final String ssId;
  final String userLt;
  final String realUserId;
  final bool isUser;

  String get key => keyOf(type, id, ssId, userLt);

  static String keyOf(String type, String id, String ssId, String userLt) =>
      '$type|$id|$ssId|$userLt';

  bool isOwn(MessageSearchUser own) =>
      isUser &&
      realUserId == '${own.userId}' &&
      id == 'U${own.userId}' &&
      ssId == '${own.ssId}' &&
      userLt == '${own.userLt}';
}
