// A run of the live suite (#57): its client, its guard, the own account, and
// the messages it sent, which it finds in the inbox and the sent box and
// moves to the trash at the end.
import 'dart:io';
import 'dart:math';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;

import 'live_client.dart';
import 'live_wire_guard.dart';

/// Where a message the run sent arrived: its headers with its subject in
/// the inbox and in the sent box.
class Arrival {
  Arrival(this.subject, this.inbox, this.sent);

  final String subject;
  final List<ShortMessage> inbox;
  final List<ShortMessage> sent;
}

/// What the cleanup did with message [id] of the run: moved it to the trash
/// ([status] is Smartschool's answer), or left it alone ([leftAlone] says
/// why).
class Trashing {
  Trashing.moved(this.id, this.subject, this.box, this.status)
    : leftAlone = null;
  Trashing.leftAlone(this.id, this.subject, this.box, String this.leftAlone)
    : status = null;

  final int id;
  final String subject;

  /// The box the message was checked in before the move.
  final BoxType box;
  final MessageDeletionStatus? status;
  final String? leftAlone;

  @override
  String toString() => leftAlone == null
      ? 'message $id ("$subject", ${box.value}): moved, $status'
      : 'message $id ("$subject", ${box.value}): left alone, $leftAlone';
}

class LiveRun {
  LiveRun._(
    this.client,
    this.messages,
    this.guard,
    this.own,
    this.tag,
    this._files,
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

  /// The subjects of the messages the run sent, or tried to: the cleanup
  /// looks for each of them.
  final List<String> _subjects = [];

  /// The messages the run asked to move to the trash. It never asks twice
  /// for one: a second `quick delete` could delete it for good (#19).
  final Set<int> _trashed = {};

  Future<Arrival>? _original;

  /// Logs in (only when the session of the last run expired) with the
  /// credentials in [credentialsFile], and finds the own account.
  static Future<LiveRun> start(File credentialsFile) async {
    final credentials = PathCredentials(filename: credentialsFile.path);
    final tag = _newTag();
    final client = await createLiveClient(credentials);
    final guard = LiveWireGuard(host: credentials.mainUrl, runTag: tag);
    client.dio.interceptors.add(guard);
    try {
      final messages = MessagesService(client);
      final own = await messages.getCurrentUserAsRecipient();
      await _checkOwn(client, own);
      guard.own = own;
      final files = await Directory.systemTemp.createTemp('dartschool_live_');
      return LiveRun._(client, messages, guard, own, tag, files);
    } catch (_) {
      await client.dispose();
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
  /// run) and deletes the run's attachments.
  Future<void> close() async {
    await client.dispose();
    if (_files.existsSync()) await _files.delete(recursive: true);
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

  /// The headers of [box] with [subject], among its newest 50.
  Future<List<ShortMessage>> listed(BoxType box, String subject) async =>
      (await messages.getHeaders(
        boxType: box,
      )).where((message) => message.subject == subject).toList();

  /// The header of message [id] in the inbox, or `null`.
  Future<ShortMessage?> inboxHeader(int id) async =>
      (await messages.getHeaders()).where((m) => m.id == id).firstOrNull;

  /// Moves every message of the run that is not in the trash yet to the
  /// trash, once, and returns what it did with each.
  ///
  /// It looks for the run's subjects in the inbox and the sent box, and moves
  /// a message only when:
  /// - the run did not ask to move it before, and it is not in the trash:
  ///   a `quick delete` of a message in the trash deletes it for good (#19);
  /// - its reply form names the own account alone as its sender;
  /// - the box it was found in still lists it with the run's subject, right
  ///   before the move (Smartschool's `quick delete` names the message only,
  ///   and a message the account sent to itself has the same ID in the inbox
  ///   and the sent box).
  ///
  /// It moves the inbox copy of such a message (seen live); the sent box
  /// keeps its copy, which the library cannot move yet (#60).
  Future<List<Trashing>> cleanUp() async {
    final done = <Trashing>[];
    for (final subject in _subjects) {
      final inbox = await listed(BoxType.inbox, subject);
      final sent = await listed(BoxType.sent, subject);
      final boxes = <int, BoxType>{
        for (final message in sent) message.id: BoxType.sent,
        for (final message in inbox) message.id: BoxType.inbox,
      };
      for (final MapEntry(key: id, value: box) in boxes.entries) {
        if (_trashed.contains(id)) continue;
        done.add(await _trash(id, subject, box));
      }
    }
    return done;
  }

  Future<Trashing> _trash(int id, String subject, BoxType box) async {
    final trash = await messages.getHeaders(boxType: BoxType.trash);
    if (trash.any((message) => message.id == id)) {
      return Trashing.leftAlone(id, subject, box, 'it is in the trash already');
    }
    if (!ownOnly(await messages.getReplyRecipients(id, boxType: box))) {
      return Trashing.leftAlone(
        id,
        subject,
        box,
        'its reply form does not name the own account alone as its sender',
      );
    }
    final listedNow = await listed(box, subject);
    if (!listedNow.any((message) => message.id == id)) {
      return Trashing.leftAlone(
        id,
        subject,
        box,
        'the ${box.value} no longer lists it with the run\'s subject',
      );
    }
    _trashed.add(id);
    guard.allowTrash(id);
    return Trashing.moved(id, subject, box, await messages.moveToTrash(id));
  }
}
