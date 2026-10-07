// A run of the live suite (#57): its client, its guard, the own account, and
// the messages it sent, which it finds in the inbox (or its archive folder,
// #64) and the sent box and moves to the trash at the end.
import 'dart:io';
import 'dart:math';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;

import 'live_client.dart';
import 'live_lock.dart';
import 'live_wire_guard.dart';

/// Where a message the run sent arrived: its headers with its subject in
/// the inbox and in the sent box.
class Arrival {
  Arrival(this.subject, this.inbox, this.sent);

  final String subject;
  final List<ShortMessage> inbox;
  final List<ShortMessage> sent;
}

/// What the cleanup did with the copy of message [id] of the run in [box]
/// (in its folder [boxId]): moved it to the trash ([left] says whether it
/// left the box), or left it alone ([leftAlone] says why).
class Trashing {
  Trashing.moved(
    this.id,
    this.subject,
    this.box, {
    required this.left,
    this.boxId = 0,
  }) : leftAlone = null;
  Trashing.leftAlone(
    this.id,
    this.subject,
    this.box,
    String this.leftAlone, {
    this.boxId = 0,
  }) : left = null;

  final int id;
  final String subject;

  /// The box of the copy: the box it was checked in, which the move names.
  final BoxType box;

  /// The folder of [box] the copy was checked in, which the move names: `0`
  /// for the box itself, the archive folder's ID for an archived inbox copy.
  final int boxId;
  final String? leftAlone;

  /// For a moved copy, what `moveToTrashFrom` returned (#96): `true` when,
  /// right after the move, [box] held no message [id] any more, `false` when
  /// it still did, `null` when Smartschool's answer said neither. `null` for
  /// a copy left alone.
  final bool? left;

  @override
  String toString() {
    final copy = boxId == 0
        ? '${box.value} copy'
        : '${box.value} copy in folder $boxId';
    return leftAlone == null
        ? 'message $id ("$subject"), $copy: moved to the trash, left the '
              '${box.value}: $left'
        : 'message $id ("$subject"), $copy: left alone, $leftAlone';
  }
}

class LiveRun {
  LiveRun._(
    this.client,
    this.messages,
    this.guard,
    this.own,
    this.tag,
    this._files,
    this._lock,
  );

  final SmartschoolClient client;
  final MessagesService messages;
  final LiveWireGuard guard;

  /// The own account: the only recipient of every message of the run.
  final MessageSearchUser own;

  /// The tag of the run, which every subject carries.
  final String tag;

  /// A temporary folder for the run's attachments.
  final Directory _files;

  /// The lock of the session: one live run at a time works in it (#62).
  final LiveLock _lock;

  /// The subjects of the messages the run sent, or tried to: the cleanup
  /// looks for each of them.
  final List<String> _subjects = [];

  /// The copies of the run's messages, as (ID, box), that the run asked to
  /// move to the trash, whichever folder of the box they were in. It never
  /// asks twice for one.
  final Set<(int, BoxType)> _trashed = {};

  /// The run's messages whose inbox copy the run asked to move to the
  /// archive. It never asks twice for one.
  final Set<int> _archived = {};

  /// The archive folder of the inbox, once the run asked to move a message
  /// there: the cleanup then looks for the run's inbox copies in it too.
  int? _archiveBoxId;

  Future<Arrival>? _original;

  /// Takes the lock of the session, logs in (only when the session of the
  /// last run expired) with the credentials in [credentialsFile], and finds
  /// the own account.
  ///
  /// Throws a [LiveLockHeld], before any request, when another live run
  /// works in the session (#62).
  static Future<LiveRun> start(File credentialsFile) async {
    final credentials = PathCredentials(filename: credentialsFile.path);
    final tag = _newTag();
    final lock = await lockLiveSession(credentials, tag);
    SmartschoolClient? client;
    try {
      client = await createLiveClient(credentials);
      final guard = LiveWireGuard(host: credentials.mainUrl, runTag: tag);
      client.dio.interceptors.add(guard);
      final messages = MessagesService(client);
      final own = await messages.getCurrentUserAsRecipient();
      await _checkOwn(client, own);
      guard.own = own;
      final files = await Directory.systemTemp.createTemp('dartschool_live_');
      return LiveRun._(client, messages, guard, own, tag, files, lock);
    } catch (_) {
      try {
        await client?.dispose();
      } finally {
        await lock.release();
      }
      rethrow;
    }
  }

  /// A tag that no other run has: the time and four random hex digits.
  static String _newTag() {
    final now = DateTime.now().toUtc();
    String pad(int n) => '$n'.padLeft(2, '0');
    final random = Random.secure().nextInt(0x10000).toRadixString(16);
    return 'run-${now.year}${pad(now.month)}${pad(now.day)}-'
        '${pad(now.hour)}${pad(now.minute)}${pad(now.second)}-'
        '${random.padLeft(4, '0')}';
  }

  /// Checks [own], the user of the compose page, against the authenticated
  /// user of the session (`<ssID>_<userID>_<co-account>`), so that the run
  /// sends to the account it is logged in as and to nobody else.
  static Future<void> _checkOwn(
    SmartschoolClient client,
    MessageSearchUser own,
  ) async {
    final user = await client.authenticatedUser;
    final parts = '${user['id']}'.split('_');
    if (parts.length < 2 ||
        parts[0] != '${own.ssId}' ||
        parts[1] != '${own.userId}') {
      throw StateError(
        'The compose page and the session name different accounts; the live '
        'suite sends nothing.',
      );
    }
  }

  /// Closes the client (its session stays in the live cache for the next
  /// run), deletes the run's attachments, and gives the lock of the session
  /// back.
  Future<void> close() async {
    try {
      await client.dispose();
      if (_files.existsSync()) await _files.delete(recursive: true);
    } finally {
      await _lock.release();
    }
  }

  /// The subject of the message of [scenario].
  String subject(String scenario) => '$liveSubjectPrefix $tag $scenario';

  /// The subject of the reply of [scenario].
  String replySubject(String scenario) =>
      MessagesService.ensureReplySubject(subject(scenario));

  /// The body of the message of [scenario].
  String body(String scenario) =>
      '<p>Automated live test of the dartschool library (#57), run $tag, '
      '$scenario. Sent to the own account only; the test moves it to the '
      'trash.</p>';

  /// Whether [user] is the own account.
  bool isOwn(MessageSearchUser user) =>
      user.userId == own.userId &&
      user.ssId == own.ssId &&
      user.userLt == own.userLt;

  /// Whether the recipients of a reply form, as `getReplyRecipients` and
  /// `getReplyAllRecipients` return them, are the own account alone, in To.
  bool ownOnly(
    (List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)
    recipients,
  ) {
    final (to, cc, bcc) = recipients;
    return to.length == 1 && isOwn(to.single) && cc.isEmpty && bcc.isEmpty;
  }

  /// A small text file to attach, named after the run.
  Future<File> attachment(String scenario) async {
    final file = File(p.join(_files.path, '$liveFilePrefix$tag-$scenario.txt'));
    await file.writeAsString(
      'Attachment of a live test of the dartschool library, $tag.\n',
    );
    return file;
  }

  /// The message of the first scenario: sent to the own account once per
  /// run, and replied to by the reply scenarios.
  Future<Arrival> original() => _original ??= _sendOriginal();

  Future<Arrival> _sendOriginal() async {
    final subject = this.subject('send');
    final arrival = await send(
      subject,
      () => messages.sendMessage(
        SendMessageParams(to: [own], subject: subject, bodyHtml: body('send')),
      ),
    );
    // Sent to the own account only, by this run: one it may reply to.
    if (arrival.inbox.length == 1) guard.allowReplyTo(arrival.inbox.single.id);
    return arrival;
  }

  /// Sends the message with [subject] by [sending], and finds where it
  /// arrived. When [sending] throws, the message is looked for as well (it
  /// may have been sent, #25) before the error is rethrown, so that the
  /// cleanup finds it.
  Future<Arrival> send(String subject, Future<void> Function() sending) async {
    _subjects.add(subject);
    try {
      await sending();
    } on Object {
      try {
        await find(subject);
      } on Object {
        // The error of the send says more; the cleanup looks again.
      }
      rethrow;
    }
    return find(subject);
  }

  /// Records [subject] as one the run may have sent, without sending it.
  void expectNoSend(String subject) => _subjects.add(subject);

  /// The headers with [subject] in the inbox and the sent box, once the
  /// message is in both (waiting up to half a minute), looked at once more a
  /// few seconds later for a second copy.
  Future<Arrival> find(String subject) async {
    var inbox = <ShortMessage>[];
    var sent = <ShortMessage>[];
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      inbox = await listed(BoxType.inbox, subject);
      sent = await listed(BoxType.sent, subject);
      final found = inbox.isNotEmpty && sent.isNotEmpty;
      if (found || DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (inbox.isNotEmpty || sent.isNotEmpty) {
      await Future<void>.delayed(const Duration(seconds: 3));
      inbox = await listed(BoxType.inbox, subject);
      sent = await listed(BoxType.sent, subject);
    }
    return Arrival(subject, inbox, sent);
  }

  /// The headers of [box] (of its folder [boxId]: `0` for the box itself)
  /// with [subject], among its newest 50.
  Future<List<ShortMessage>> listed(
    BoxType box,
    String subject, {
    int boxId = 0,
  }) async => (await messages.getHeaders(
    boxType: box,
    boxId: boxId,
  )).where((message) => message.subject == subject).toList();

  /// The header of message [id] in the inbox, or `null`.
  Future<ShortMessage?> inboxHeader(int id) async =>
      (await messages.getHeaders()).where((m) => m.id == id).firstOrNull;

  /// Moves every copy of the run's messages that is still in [boxes] to the
  /// trash, once each, box by box in the order given, and returns what it
  /// did with each.
  ///
  /// A message the account sends to itself has the same ID in the inbox and
  /// in the sent box. The cleanup moves each copy with `moveToTrashFrom`,
  /// which names the box of the copy (Smartschool's `quickmove messages`
  /// to the trash): by default first the sent-box copies, while the inbox
  /// copies are in the inbox and nothing of the run's messages is in the
  /// trash, and then the inbox copies. It does so only because that request
  /// names its box, in Smartschool's web client too, and was seen live to
  /// take the copy of that box and leave the other copy alone, also with
  /// the other copy in the trash (#60). It never sends a `quick delete`
  /// (`moveToTrash`): that names the ID only, Smartschool acts on whichever
  /// copy of the ID its session state points to, and one of a message in
  /// the trash deletes it for good (#19, #61).
  ///
  /// It looks for the run's subjects in each box, and in the inbox also in
  /// its archive folder once the run moved a message there (#64), and moves
  /// a copy as [trash] does.
  Future<List<Trashing>> cleanUp({
    List<BoxType> boxes = const [BoxType.sent, BoxType.inbox],
  }) async {
    final done = <Trashing>[];
    for (final box in boxes) {
      final archive = _archiveBoxId;
      for (final folder in [
        0,
        if (box == BoxType.inbox && archive != null) archive,
      ]) {
        for (final subject in _subjects) {
          for (final message in await listed(box, subject, boxId: folder)) {
            if (_trashed.contains((message.id, box))) continue;
            done.add(await trash(message.id, subject, box, boxId: folder));
          }
        }
      }
    }
    return done;
  }

  /// Moves the copy of message [id] of the run, with [subject], in [box] (in
  /// its folder [boxId]: `0` for the box itself, the archive folder for an
  /// archived inbox copy) to the trash with `moveToTrashFrom`, and returns
  /// what it did with it, with what `moveToTrashFrom` returned (#96).
  ///
  /// It moves the copy only when:
  /// - the run did not ask to move that copy before (from any folder);
  /// - its reply form, in its box, names the own account alone as the
  ///   sender;
  /// - its box (its folder) still lists it with the run's subject, right
  ///   before the move.
  Future<Trashing> trash(
    int id,
    String subject,
    BoxType box, {
    int boxId = 0,
  }) async {
    if (_trashed.contains((id, box))) {
      return Trashing.leftAlone(
        id,
        subject,
        box,
        'the run moved it to the trash already',
        boxId: boxId,
      );
    }
    if (!ownOnly(await messages.getReplyRecipients(id, boxType: box))) {
      return Trashing.leftAlone(
        id,
        subject,
        box,
        'its reply form does not name the own account alone as its sender',
        boxId: boxId,
      );
    }
    final listedNow = await listed(box, subject, boxId: boxId);
    if (!listedNow.any((message) => message.id == id)) {
      final where = boxId == 0
          ? 'the ${box.value}'
          : 'folder $boxId of the ${box.value}';
      return Trashing.leftAlone(
        id,
        subject,
        box,
        "$where no longer lists it with the run's subject",
        boxId: boxId,
      );
    }
    _trashed.add((id, box));
    guard.allowTrashFrom(id, box, boxId: boxId);
    final left = await messages.moveToTrashFrom(id, boxType: box, boxId: boxId);
    return Trashing.moved(id, subject, box, left: left, boxId: boxId);
  }

  /// Moves the inbox copy of message [id] of the run, with [subject], to the
  /// archive folder with `moveToArchive` (#64), and returns Smartschool's
  /// answer as the library reads it.
  ///
  /// It moves it only once, and only while the inbox lists it with the
  /// run's subject, right before the move; it throws a [StateError]
  /// otherwise. It resolves the archive folder first (`getArchiveBoxId`,
  /// which reads the folder tree, or else the Messages page (#141); the guard
  /// reads it there too), so that the cleanup looks for the message there,
  /// also when the move fails.
  Future<List<MessageChanged>> archive(int id, String subject) async {
    if (!_archived.add(id)) {
      throw StateError('the run moved message $id to the archive already');
    }
    final listedNow = await listed(BoxType.inbox, subject);
    if (!listedNow.any((message) => message.id == id)) {
      throw StateError(
        "the inbox does not list message $id with the run's subject; the run "
        'does not archive it',
      );
    }
    _archiveBoxId = await messages.getArchiveBoxId();
    guard.allowArchive(id);
    return messages.moveToArchive([id]);
  }
}
