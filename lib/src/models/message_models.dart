import 'dart:typed_data';

import '../session.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Recipient field for message composition.
///
/// Maps to the request type and parent node ID expected by the Smartschool
/// compose-form endpoints (`searchUsers` / `addUserToSelected`).
enum RecipientType {
  to('0', 'insertSearchFieldContainer_0_0'),
  cc('2', 'insertSearchFieldContainer_2_0'),
  bcc('3', 'insertSearchFieldContainer_3_0');

  const RecipientType(this.requestType, this.parentNodeId);

  /// The string sent as the `type` field when adding a recipient.
  final String requestType;

  /// The `parentNodeId` value sent when adding a recipient.
  final String parentNodeId;
}

/// Identifies a message box (mailbox).
///
/// The string [value] is sent to the Smartschool XML protocol.
enum BoxType {
  inbox('inbox'),
  draft('draft'),
  scheduled('scheduled'),
  sent('outbox'),
  trash('trash');

  const BoxType(this.value);
  final String value;
}

/// Determines the sort field for message listings.
enum SortField {
  date('date'),
  from('from'),
  readUnread('status'),
  attachment('attachment'),
  flag('label');

  const SortField(this.value);
  final String value;
}

/// Sort direction.
enum SortOrder {
  asc('asc'),
  desc('desc');

  const SortOrder(this.value);
  final String value;
}

/// Colour flag label that can be applied to a message.
enum MessageLabel {
  noFlag(0),
  greenFlag(1),
  yellowFlag(2),
  redFlag(3),
  blueFlag(4);

  const MessageLabel(this.value);
  final int value;
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A message header as returned by the *message list* XML action.
///
/// Corresponds to Python's `ShortMessage` Pydantic dataclass in `objects.py`.
class ShortMessage {
  final int id;

  /// Display name of the sender.  Python field `from_` / XML tag `from`.
  final String sender;

  /// Profile picture URL of the sender.  Python field `from_image`.
  final String fromImage;

  final String subject;
  final DateTime date;
  final int status;

  /// Whether the message has attachments (1 = yes, 0 = no).
  final int attachment;

  final bool unread;
  final bool deleted;
  final bool allowReply;
  final bool allowReplyEnabled;
  final bool hasReply;
  final bool hasForward;

  /// The box this message actually lives in (may differ from the queried box).
  final String realBox;

  final DateTime? sendDate;

  /// Colour flag index (0–4).  Python field `colored_flag` / XML `label`.
  final int coloredFlag;

  const ShortMessage({
    required this.id,
    required this.sender,
    required this.fromImage,
    required this.subject,
    required this.date,
    required this.status,
    required this.attachment,
    required this.unread,
    required this.deleted,
    required this.allowReply,
    required this.allowReplyEnabled,
    required this.hasReply,
    required this.hasForward,
    required this.realBox,
    this.sendDate,
    this.coloredFlag = 0,
  });

  /// Constructs a [ShortMessage] from the [Map] produced by
  /// [XmlInterface.elementToMap] for a `<message>` element.
  ///
  /// The XML `<unread>` field is misleadingly named: Smartschool emits `0` for
  /// unread messages and `1` for read messages (it mirrors `<status>`). The
  /// Smartschool JavaScript derives the new/unread flag from `<status>` via
  /// `isNew = parseInt(status) <= 0`, which is the semantic we follow here.
  factory ShortMessage.fromXml(Map<String, dynamic> xml) {
    return ShortMessage(
      id: _int(xml, 'id'),
      sender: _str(xml, 'from'),
      fromImage: _str(xml, 'fromImage'),
      subject: _str(xml, 'subject'),
      date: _dateTime(xml, 'date'),
      status: _int(xml, 'status'),
      attachment: _int(xml, 'attachment'),
      unread: _int(xml, 'status') == 0,
      deleted: _bool(xml, 'deleted'),
      allowReply: _bool(xml, 'allowreply'),
      allowReplyEnabled: _bool(xml, 'allowreplyenabled'),
      hasReply: _bool(xml, 'hasreply'),
      hasForward: _bool(xml, 'hasForward'),
      realBox: _str(xml, 'realBox'),
      sendDate: _optionalDateTime(xml, 'sendDate'),
      coloredFlag: _intOr(xml, 'coloredFlag', orKey: 'label', fallback: 0),
    );
  }

  @override
  String toString() =>
      'ShortMessage(id: $id, subject: "$subject", '
      'sender: "$sender", unread: $unread)';
}

/// A recipient of a message, with whether they have read it where
/// Smartschool says so.
///
/// Listed by [FullMessage.toRecipients], [FullMessage.ccRecipients] and
/// [FullMessage.bccRecipients].
class MessageRecipient {
  /// Display name of the recipient, as Smartschool shows it.
  final String name;

  /// Whether the recipient has read the message: known for a message in the
  /// sent box ([BoxType.sent]), `null` in every other box, where Smartschool
  /// does not say (and for a sent-box name without a marker).
  ///
  /// In the sent box, Smartschool starts each recipient name with `+` when
  /// the recipient's copy of the message is read and with `-` when it is
  /// unread, as the recipient's own box shows it ([ShortMessage.unread]).
  /// Its web client removes the marker and shows the recipients with `-` as
  /// not having read the message.
  final bool? hasRead;

  const MessageRecipient({required this.name, this.hasRead});

  /// Reads [raw], a recipient name of a message in the sent box as
  /// Smartschool sends it: `+` and the name for a recipient who has read the
  /// message, `-` and the name for one who has not.
  ///
  /// A name without either marker is kept as it is, with [hasRead] `null`.
  factory MessageRecipient.fromSentBoxName(String raw) {
    if (raw.startsWith('+')) {
      return MessageRecipient(name: raw.substring(1), hasRead: true);
    }
    if (raw.startsWith('-')) {
      return MessageRecipient(name: raw.substring(1), hasRead: false);
    }
    return MessageRecipient(name: raw);
  }

  @override
  bool operator ==(Object other) =>
      other is MessageRecipient &&
      other.name == name &&
      other.hasRead == hasRead;

  @override
  int get hashCode => Object.hash(name, hasRead);

  @override
  String toString() => 'MessageRecipient(name: "$name", hasRead: $hasRead)';
}

/// The full content of a single message.
///
/// Corresponds to Python's `FullMessage` Pydantic dataclass in `objects.py`.
class FullMessage {
  final int id;
  final String? to;
  final String subject;
  final DateTime date;
  final String body;
  final int status;
  final int attachment;
  final bool unread;

  /// Names of the recipients in the To field.
  ///
  /// For a message in the sent box, Smartschool starts each name with a
  /// `+` or `-` read marker, which is not part of the name:
  /// [FullMessage.fromXml] removes it, and [toRecipients] holds what it
  /// says.
  final List<String> receivers;

  /// Names of the recipients in the CC field; see [receivers] and
  /// [ccRecipients].
  final List<String> ccReceivers;

  /// Names of the recipients in the BCC field; see [receivers] and
  /// [bccRecipients].
  final List<String> bccReceivers;

  final List<MessageRecipient>? _toRecipients;
  final List<MessageRecipient>? _ccRecipients;
  final List<MessageRecipient>? _bccRecipients;

  /// The recipients in the To field, in the order of [receivers], with
  /// whether each has read the message ([MessageRecipient.hasRead]) for a
  /// message in the sent box.
  ///
  /// For a message constructed without them, these are the [receivers] with
  /// an unknown read state.
  List<MessageRecipient> get toRecipients =>
      _toRecipients ?? _unknownReadState(receivers);

  /// The recipients in the CC field; see [toRecipients].
  List<MessageRecipient> get ccRecipients =>
      _ccRecipients ?? _unknownReadState(ccReceivers);

  /// The recipients in the BCC field; see [toRecipients].
  List<MessageRecipient> get bccRecipients =>
      _bccRecipients ?? _unknownReadState(bccReceivers);

  static List<MessageRecipient> _unknownReadState(List<String> names) => [
    for (final name in names) MessageRecipient(name: name),
  ];

  final String senderPicture;
  final int fromTeam;
  final int totalNrOtherToReceivers;
  final int totalNrOtherCcReceivers;
  final int totalNrOtherBccReceivers;
  final bool canReply;
  final bool hasReply;
  final bool hasForward;
  final DateTime? sendDate;

  /// Display name of the sender.  Python field `from_` / XML tag `from`.
  final String sender;

  /// Colour flag index (0–4).
  final int coloredFlag;

  const FullMessage({
    required this.id,
    this.to,
    required this.subject,
    required this.date,
    required this.body,
    required this.status,
    required this.attachment,
    required this.unread,
    required this.receivers,
    required this.ccReceivers,
    required this.bccReceivers,
    required this.senderPicture,
    required this.fromTeam,
    required this.totalNrOtherToReceivers,
    required this.totalNrOtherCcReceivers,
    required this.totalNrOtherBccReceivers,
    required this.canReply,
    required this.hasReply,
    required this.hasForward,
    this.sendDate,
    required this.sender,
    this.coloredFlag = 0,
    List<MessageRecipient>? toRecipients,
    List<MessageRecipient>? ccRecipients,
    List<MessageRecipient>? bccRecipients,
  }) : _toRecipients = toRecipients,
       _ccRecipients = ccRecipients,
       _bccRecipients = bccRecipients;

  /// Constructs a [FullMessage] from the map produced by
  /// [XmlInterface.elementToMap] for a `<message>` element, after running
  /// the post-processing that normalises the receiver lists.
  ///
  /// [boxType] is the box the message was requested from. For
  /// [BoxType.sent], each recipient name starts with a `+` (read) or `-`
  /// (unread) marker, which is removed from the name and read into
  /// [MessageRecipient.hasRead], as Smartschool's web client does for the
  /// sent box. In any other box the names are kept as they are, and the
  /// read state of the recipients is unknown.
  ///
  /// See [ShortMessage.fromXml] for the `<status>`/`<unread>` semantics —
  /// `unread` is derived from `<status>` (`status == 0` → unread).
  factory FullMessage.fromXml(
    Map<String, dynamic> xml, {
    BoxType boxType = BoxType.inbox,
  }) {
    List<MessageRecipient> recipients(String key) => [
      for (final raw in _receiverList(xml, key))
        boxType == BoxType.sent
            ? MessageRecipient.fromSentBoxName(raw)
            : MessageRecipient(name: raw),
    ];
    List<String> names(List<MessageRecipient> list) => [
      for (final recipient in list) recipient.name,
    ];
    final to = recipients('receivers');
    final cc = recipients('ccreceivers');
    final bcc = recipients('bccreceivers');

    return FullMessage(
      id: _int(xml, 'id'),
      to: xml['to'] as String?,
      subject: _str(xml, 'subject'),
      date: _dateTime(xml, 'date'),
      body: _str(xml, 'body'),
      status: _int(xml, 'status'),
      attachment: _int(xml, 'attachment'),
      unread: _int(xml, 'status') == 0,
      receivers: names(to),
      ccReceivers: names(cc),
      bccReceivers: names(bcc),
      toRecipients: to,
      ccRecipients: cc,
      bccRecipients: bcc,
      senderPicture: _str(xml, 'senderPicture'),
      fromTeam: _int(xml, 'fromTeam'),
      totalNrOtherToReceivers: _int(xml, 'totalNrOtherToReciviers'),
      totalNrOtherCcReceivers: _int(xml, 'totalnrOtherCcReceivers'),
      totalNrOtherBccReceivers: _int(xml, 'totalnrOtherBccReceivers'),
      canReply: _bool(xml, 'canReply'),
      hasReply: _bool(xml, 'hasReply'),
      hasForward: _bool(xml, 'hasForward'),
      sendDate: _optionalDateTime(xml, 'sendDate'),
      sender: _str(xml, 'from'),
      coloredFlag: _intOr(xml, 'coloredFlag', orKey: 'label', fallback: 0),
    );
  }

  @override
  String toString() => 'FullMessage(id: $id, subject: "$subject")';
}

/// An attachment belonging to a message.
///
/// Corresponds to Python's `Attachment` dataclass in `objects.py` plus the
/// session-aware `Attachment` subclass in `messages.py`.
///
/// To download the bytes, call [download] and pass the active [SmartschoolClient].
/// The Python version stored the session on the model — in Dart the client is
/// passed explicitly to keep models stateless.
class MessageAttachment {
  final int fileId;
  final String name;
  final String mime;
  final String size;
  final String icon;
  final bool wopiAllowed;
  final int order;

  const MessageAttachment({
    required this.fileId,
    required this.name,
    required this.mime,
    required this.size,
    required this.icon,
    required this.wopiAllowed,
    required this.order,
  });

  factory MessageAttachment.fromXml(Map<String, dynamic> xml) {
    return MessageAttachment(
      fileId: _int(xml, 'fileID'),
      name: _str(xml, 'name'),
      mime: _str(xml, 'mime'),
      size: _str(xml, 'size'),
      icon: _str(xml, 'icon'),
      wopiAllowed: _bool(xml, 'wopiAllowed'),
      order: _int(xml, 'order'),
    );
  }

  /// Downloads and returns the raw bytes of this attachment.
  ///
  /// Smartschool sends the file itself, not encoded (no Base64; checked
  /// live, #52): the bytes are returned as they come in and can be written
  /// to a file as they are. [size] gives their number, rounded (such as
  /// `3.87 KiB`).
  ///
  /// With [maxBytes], the download fails with a
  /// `SmartschoolDownloadTooLargeError` as soon as the attachment turns out
  /// to be larger than that many bytes, and stops the transfer (#41); see
  /// [SmartschoolClient.download].
  Future<Uint8List> download(SmartschoolClient client, {int? maxBytes}) {
    return client.download(_downloadPath, maxBytes: maxBytes);
  }

  /// Downloads this attachment as a stream, from the same URL as [download]:
  /// returns as soon as the headers of Smartschool's answer are in, with the
  /// content to be read from its `stream` as it comes in (#41). See
  /// [SmartschoolClient.downloadStream], also for [maxBytes].
  ///
  /// The stream holds the same bytes as [download] returns: the file itself.
  /// Its `contentType` does not tell the type of the file (Smartschool
  /// answered `application/x-www-form-urlencoded` for an attachment checked
  /// live, #52); the extension of [name] does.
  Future<SmartschoolDownload> downloadStream(
    SmartschoolClient client, {
    int? maxBytes,
  }) {
    return client.downloadStream(_downloadPath, maxBytes: maxBytes);
  }

  String get _downloadPath =>
      '/?module=Messages&file=download&fileID=$fileId&target=0';

  @override
  String toString() => 'MessageAttachment(fileId: $fileId, name: "$name")';
}

/// Result model for mutation operations (mark read or unread, adjust label,
/// archive).
///
/// Corresponds to Python's `MessageChanged` dataclass.
class MessageChanged {
  final int id;

  /// The new status / label value after the mutation.
  final int newValue;

  const MessageChanged({required this.id, required this.newValue});

  /// Reads the `<message>` of Smartschool's answer to `mark message read` or
  /// `mark message unread` ([MessagesService.markRead],
  /// [MessagesService.markUnread]): the message's `<id>` and its new read
  /// state, `<status>` (`1` read, `0` unread) as [newValue].
  ///
  /// Returns `null` when the answer gives no usable ID or read state: either
  /// element missing, empty, repeated or not a whole number (#95). A
  /// `<label>` is not read: it is not the read state.
  static MessageChanged? fromStatusXml(Map<String, dynamic> xml) =>
      _changed(xml, 'status');

  /// Reads the `<message>` of Smartschool's answer to `save msglabel`
  /// ([MessagesService.setLabel]): the message's `<id>` and its new flag,
  /// `<label>` ([MessageLabel.value]) as [newValue].
  ///
  /// Returns `null` when the answer gives no usable ID or flag: either
  /// element missing, empty, repeated or not a whole number (#95). A
  /// `<status>` is not read: it is the read state, not the flag.
  static MessageChanged? fromLabelXml(Map<String, dynamic> xml) =>
      _changed(xml, 'label');

  /// Reads `<id>` and the `<status>`, or else the `<label>`, of [xml].
  ///
  /// A missing, empty or non-numeric value reads as `0`, which is also a
  /// confirmed state: unread after [MessagesService.markUnread], no flag
  /// after [MessagesService.setLabel] with [MessageLabel.noFlag]. And when
  /// [xml] holds both, [newValue] is the `<status>`, also for an answer to
  /// `save msglabel`.
  @Deprecated(
    'Reads a missing or unusable ID or state as 0, which also means unread '
    'or no flag: use fromStatusXml or fromLabelXml, which return null for it '
    '(#95)',
  )
  factory MessageChanged.fromXml(Map<String, dynamic> xml) {
    return MessageChanged(
      id: _int(xml, 'id'),
      newValue: _intOr(xml, 'status', orKey: 'label', fallback: 0),
    );
  }

  static MessageChanged? _changed(Map<String, dynamic> xml, String key) {
    final id = _strictInt(xml, 'id');
    final value = _strictInt(xml, key);
    if (id == null || value == null) return null;
    return MessageChanged(id: id, newValue: value);
  }
}

/// Result model for trash / delete operations.
///
/// Corresponds to Python's `MessageDeletionStatus` dataclass.
class MessageDeletionStatus {
  /// The ID of the message, as Smartschool's answer names it.
  final int msgId;

  /// The type of box the message was in, as Smartschool's answer names it
  /// (`inbox` for a message in the archive too, a folder of the inbox).
  final String boxType;

  /// Whether Smartschool's answer confirms that the message was deleted.
  final bool isDeleted;

  /// Whether the message was unread, from the `<status>` of Smartschool's
  /// answer (`0` unread, `1` read, as in every message list); `null` when the
  /// answer gives neither.
  final bool? unread;

  const MessageDeletionStatus({
    required this.msgId,
    required this.boxType,
    required this.isDeleted,
    this.unread,
  });

  /// Reads the `<details>` of Smartschool's `finish quick delete` answer, the
  /// answer to a `quick delete` of a message ([MessagesService.moveToTrash]).
  ///
  /// Smartschool's web client takes that answer as the message deleted: it
  /// removes the message from the list whatever the details say. So
  /// [isDeleted] is `true`. The details' `<status>` is not the outcome of the
  /// deletion but the read state of the message ([unread]), which the web
  /// client passes on to its unread counter (#19).
  factory MessageDeletionStatus.fromXml(Map<String, dynamic> xml) {
    final status = _str(xml, 'status');
    return MessageDeletionStatus(
      msgId: _int(xml, 'msgID'),
      boxType: _str(xml, 'boxType'),
      isDeleted: true,
      unread: switch (status) {
        '0' => true,
        '1' => false,
        _ => null,
      },
    );
  }

  @override
  String toString() =>
      'MessageDeletionStatus(msgId: $msgId, boxType: "$boxType", '
      'isDeleted: $isDeleted, unread: $unread)';
}

/// A user or group returned by the recipient search endpoint.
///
/// Produced by [MessagesService.searchRecipients] which uses the JSON-based
/// `/Messages/Xhr/searchRecipients` endpoint.  For the compose-form–based
/// search (which returns `ssID` and is required for [MessagesService.sendMessage])
/// use [MessagesService.searchRecipientsForCompose] instead, which returns
/// [MessageSearchUser] / [MessageSearchGroup] objects.
class MessageSearchResult {
  /// `"user"` or `"group"`.
  final String type;
  final int id;
  final String displayName;
  final String? picture;
  final String? className;
  final String? schoolName;

  const MessageSearchResult({
    required this.type,
    required this.id,
    required this.displayName,
    this.picture,
    this.className,
    this.schoolName,
  });

  factory MessageSearchResult.fromJson(Map<String, dynamic> json) {
    final isUser = json.containsKey('userID');
    return MessageSearchResult(
      type: isUser ? 'user' : 'group',
      id: isUser ? json['userID'] as int : json['groupID'] as int,
      displayName: (json['value'] as String?) ?? '',
      picture: json['picture'] as String?,
      className: json['classname'] as String?,
      schoolName: json['schoolname'] as String?,
    );
  }
}

/// A user result from the compose-form XML search endpoint
/// (`/?module=Messages&file=searchUsers`).
///
/// Used as a recipient in [MessagesService.sendMessage].  Obtain instances
/// via [MessagesService.searchRecipientsForCompose].
class MessageSearchUser {
  final int userId;
  final String displayName;

  /// The Smartschool platform / school ID.  Required when adding this user
  /// as a recipient via the compose-form `addUserToSelected` endpoint.
  final int ssId;

  final String? coaccountName;
  final String? className;
  final String? schoolName;
  final String? picture;

  /// The `userLT` value from the search response (usually 0).
  final int userLt;

  const MessageSearchUser({
    required this.userId,
    required this.displayName,
    required this.ssId,
    this.coaccountName,
    this.className,
    this.schoolName,
    this.picture,
    this.userLt = 0,
  });

  factory MessageSearchUser.fromXml(Map<String, dynamic> xml) {
    return MessageSearchUser(
      userId: _int(xml, 'userID'),
      displayName: _str(xml, 'value'),
      ssId: _int(xml, 'ssID'),
      coaccountName: _nullableStr(xml, 'coaccountname'),
      className: _nullableStr(xml, 'classname'),
      schoolName: _nullableStr(xml, 'schoolname'),
      picture: _nullableStr(xml, 'picture'),
      userLt: _int(xml, 'userLT'),
    );
  }

  @override
  String toString() =>
      'MessageSearchUser(userId: $userId, displayName: "$displayName", ssId: $ssId)';
}

/// A group result from the compose-form XML search endpoint
/// (`/?module=Messages&file=searchUsers`).
///
/// Used as a recipient in [MessagesService.sendMessage].  Obtain instances
/// via [MessagesService.searchRecipientsForCompose].
class MessageSearchGroup {
  final int groupId;
  final String displayName;

  /// The Smartschool platform / school ID.  Required when adding this group
  /// as a recipient via the compose-form `addUserToSelected` endpoint.
  final int ssId;

  final String? icon;
  final String? description;

  const MessageSearchGroup({
    required this.groupId,
    required this.displayName,
    required this.ssId,
    this.icon,
    this.description,
  });

  factory MessageSearchGroup.fromXml(Map<String, dynamic> xml) {
    return MessageSearchGroup(
      groupId: _int(xml, 'groupID'),
      displayName: _str(xml, 'value'),
      ssId: _int(xml, 'ssID'),
      icon: _nullableStr(xml, 'icon'),
      description: _nullableStr(xml, 'description'),
    );
  }

  @override
  String toString() =>
      'MessageSearchGroup(groupId: $groupId, displayName: "$displayName", ssId: $ssId)';
}

/// A folder of a message box: the archive of the inbox, or a folder the user
/// made in Smartschool ("Map toevoegen"), in the inbox, in the sent box or
/// in another folder (#136).
///
/// Returned by [MessagesService.getFolders], as a tree: the folders directly
/// in a box, each with the folders in it as its [children]. The boxes
/// themselves are no folders: they are a [BoxType] (box ID `0`).
/// [flatten] lists the whole tree, each folder with its [path].
///
/// A folder is a box ID of its [boxType]. Its messages are listed as those
/// of the archive are, with [MessagesService.getHeaders],
/// [MessagesService.getHeaderPages] or [MessagesService.getAllHeaders] and
/// `boxType: folder.boxType, boxId: folder.id`, and read with
/// [MessagesService.getMessage] and `boxType: folder.boxType` (its request
/// names no folder); both tried live on 2026-10-07 with a folder the user
/// made in the inbox. The other requests for a message in a folder work as
/// for one in the archive: [MessagesService.markRead] and
/// [MessagesService.setLabel] take the folder's [boxType] only,
/// [MessagesService.markUnread] and [MessagesService.moveToTrashFrom] also
/// its [id] as their `boxId` (tried live in the archive, #94, #64, not in a
/// folder the user made).
class MessageFolder {
  /// The folder's box ID: the `boxId` its messages are listed with. Never
  /// `0`, which is the box itself.
  final int id;

  /// The box the folder is in: [BoxType.inbox] for the archive and the
  /// folders of the inbox, [BoxType.sent] for those of the sent box.
  final BoxType boxType;

  /// The folder's name, as Smartschool shows it (`Berichten archief` for
  /// the archive).
  final String name;

  /// Smartschool's description of the folder: [archiveDescription] for the
  /// archive, empty for a folder the user made (seen live, 2026-10-07).
  final String description;

  /// The [id] of the folder this folder is in, or `null` for a folder
  /// directly in its box.
  ///
  /// Smartschool's own `parentID` was `-1` for the folders seen live, also
  /// for one directly in the inbox (whose box ID is `0`), so this is taken
  /// from the tree: the folder whose [children] hold this one.
  final int? parentId;

  /// The names of the folders from the one directly in the box down to this
  /// one, this folder's [name] last: `[name]` for a folder directly in its
  /// box. The box's own name is not in it.
  final List<String> path;

  /// The folders in this folder, in Smartschool's order.
  final List<MessageFolder> children;

  const MessageFolder({
    required this.id,
    required this.boxType,
    required this.name,
    required this.path,
    this.description = '',
    this.parentId,
    this.children = const [],
  });

  /// The [description] Smartschool gives the archive of the inbox.
  static const archiveDescription = 'msg archive';

  /// Whether this folder is the archive of the inbox (the folder
  /// [MessagesService.moveToArchive] moves messages to): the folder with
  /// [archiveDescription] as its [description], as Smartschool tells it
  /// apart.
  bool get isArchive => description == archiveDescription;

  /// Every folder of [folders] and of their [children], depth first: each
  /// folder before the folders in it, in Smartschool's order.
  ///
  /// [path] and [parentId] tell where each one is.
  static List<MessageFolder> flatten(Iterable<MessageFolder> folders) => [
    for (final folder in folders) ...[folder, ...flatten(folder.children)],
  ];

  @override
  String toString() =>
      'MessageFolder(id: $id, boxType: ${boxType.name}, '
      'path: ${path.map((name) => '"$name"').join(' / ')}'
      '${isArchive ? ', archive' : ''}, children: ${children.length})';
}

// ---------------------------------------------------------------------------
// XML parsing helpers
// ---------------------------------------------------------------------------

String _str(Map<String, dynamic> xml, String key) =>
    (xml[key] as String? ?? '').trim();

String? _nullableStr(Map<String, dynamic> xml, String key) {
  final v = _str(xml, key);
  return v.isEmpty ? null : v;
}

int _int(Map<String, dynamic> xml, String key) {
  final v = xml[key];
  if (v == null) return 0;
  if (v is int) return v;
  return int.tryParse(v.toString()) ?? 0;
}

/// The whole (decimal) number in the element [key] of [xml], or `null` when
/// [xml] has no such element, or one that is empty, repeated, has child
/// elements or holds anything else than a whole number (surrounding
/// whitespace aside).
int? _strictInt(Map<String, dynamic> xml, String key) {
  final v = xml[key];
  return v is String ? int.tryParse(v.trim(), radix: 10) : null;
}

int _intOr(
  Map<String, dynamic> xml,
  String key, {
  required String orKey,
  required int fallback,
}) {
  if (xml.containsKey(key) && xml[key] != null) return _int(xml, key);
  if (xml.containsKey(orKey) && xml[orKey] != null) return _int(xml, orKey);
  return fallback;
}

bool _bool(Map<String, dynamic> xml, String key) {
  final v = _str(xml, key).toLowerCase();
  return v == '1' || v == 'true';
}

DateTime _dateTime(Map<String, dynamic> xml, String key) =>
    _parseDateTime(_str(xml, key)) ?? DateTime.now().toLocal();

DateTime? _optionalDateTime(Map<String, dynamic> xml, String key) {
  final v = _str(xml, key);
  if (v.isEmpty) return null;
  return _parseDateTime(v);
}

/// Parses a datetime string in the formats used by Smartschool.
///
/// Mirrors Python's `convert_to_datetime` in `common.py`.
/// Handles various datetime formats including ISO 8601 with/without timezone,
/// space-separated formats with or without seconds, and milliseconds/microseconds.
DateTime? _parseDateTime(String v) {
  if (v.isEmpty) return null;
  v = v.trim();
  if (v.isEmpty) return null;

  DateTime? parsed;
  parsed = _tryParseIsoWithTimezone(v);
  if (parsed != null) return parsed;
  parsed = _tryParseIsoMicro(v);
  if (parsed != null) return parsed;
  parsed = _tryParseIsoSeconds(v);
  if (parsed != null) return parsed;
  parsed = _tryParseSpaceFormat(v);
  if (parsed != null) return parsed;
  parsed = _tryParseSpaceFormatSeconds(v);
  if (parsed != null) return parsed;
  parsed = _tryParseDateOnly(v);
  if (parsed != null) return parsed;

  // If we get here, the datetime is in an unrecognized format.
  // This can happen when Smartschool returns error messages or malformed data.
  // Return epoch (1970-01-01) as a safe fallback rather than crashing.
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

DateTime? _tryParseIsoWithTimezone(String v) {
  try {
    return DateTime.parse(v);
  } catch (_) {
    return null;
  }
}

DateTime? _tryParseIsoMicro(String v) {
  final isoMicro = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+$');
  if (isoMicro.hasMatch(v)) {
    try {
      final parts = v.split('.');
      if (parts.length == 2 && parts[1].length > 3) {
        final truncated = '${parts[0]}.${parts[1].substring(0, 3)}';
        return DateTime.parse(truncated);
      }
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }
  return null;
}

DateTime? _tryParseIsoSeconds(String v) {
  final isoSeconds = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$');
  if (isoSeconds.hasMatch(v)) {
    try {
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }
  return null;
}

DateTime? _tryParseSpaceFormat(String v) {
  final spaceFormat = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$');
  if (spaceFormat.hasMatch(v)) {
    try {
      return DateTime.parse(v.replaceFirst(' ', 'T'));
    } catch (_) {
      return null;
    }
  }
  return null;
}

DateTime? _tryParseSpaceFormatSeconds(String v) {
  final spaceFormatSeconds = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
  if (spaceFormatSeconds.hasMatch(v)) {
    try {
      return DateTime.parse(v.replaceFirst(' ', 'T'));
    } catch (_) {
      return null;
    }
  }
  return null;
}

DateTime? _tryParseDateOnly(String v) {
  final dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (dateOnly.hasMatch(v)) {
    try {
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Normalises a receiver list field in a [FullMessage] XML map.
///
/// The Python post-processor in `messages.py` transforms:
/// - Empty string → `[]`
/// - Non-empty: extracts the nested `to` element value(s)
///   (`{'to': 'name'}` or `{'to': ['name1', 'name2']}`)
List<String> _receiverList(Map<String, dynamic> xml, String key) {
  final v = xml[key];
  if (v == null || (v is String && v.trim().isEmpty)) return [];

  if (v is Map<String, dynamic>) {
    final to = v['to'];
    if (to == null) return [];
    if (to is List) return to.map((e) => e.toString()).toList();
    return [to.toString()];
  }

  return [];
}
