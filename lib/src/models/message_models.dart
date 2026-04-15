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
  factory ShortMessage.fromXml(Map<String, dynamic> xml) {
    return ShortMessage(
      id: _int(xml, 'id'),
      sender: _str(xml, 'from'),
      fromImage: _str(xml, 'fromImage'),
      subject: _str(xml, 'subject'),
      date: _dateTime(xml, 'date'),
      status: _int(xml, 'status'),
      attachment: _int(xml, 'attachment'),
      unread: _bool(xml, 'unread'),
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

  /// Recipients in the To field.
  final List<String> receivers;

  /// Recipients in the CC field.
  final List<String> ccReceivers;

  /// Recipients in the BCC field.
  final List<String> bccReceivers;

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
  });

  /// Constructs a [FullMessage] from the map produced by
  /// [XmlInterface.elementToMap] for a `<message>` element, after running
  /// the post-processing that normalises the receiver lists.
  factory FullMessage.fromXml(Map<String, dynamic> xml) {
    return FullMessage(
      id: _int(xml, 'id'),
      to: xml['to'] as String?,
      subject: _str(xml, 'subject'),
      date: _dateTime(xml, 'date'),
      body: _str(xml, 'body'),
      status: _int(xml, 'status'),
      attachment: _int(xml, 'attachment'),
      unread: _bool(xml, 'unread'),
      receivers: _receiverList(xml, 'receivers'),
      ccReceivers: _receiverList(xml, 'ccreceivers'),
      bccReceivers: _receiverList(xml, 'bccreceivers'),
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
  /// The Smartschool server returns the file as Base64-encoded content —
  /// this method decodes it automatically.
  Future<Uint8List> download(SmartschoolClient client) {
    return client.download(
      '/?module=Messages&file=download&fileID=$fileId&target=0',
    );
  }

  @override
  String toString() => 'MessageAttachment(fileId: $fileId, name: "$name")';
}

/// Result model for mutation operations (mark unread, adjust label).
///
/// Corresponds to Python's `MessageChanged` dataclass.
class MessageChanged {
  final int id;

  /// The new status / label value after the mutation.
  final int newValue;

  const MessageChanged({required this.id, required this.newValue});

  factory MessageChanged.fromXml(Map<String, dynamic> xml) {
    return MessageChanged(
      id: _int(xml, 'id'),
      newValue: _intOr(xml, 'status', orKey: 'label', fallback: 0),
    );
  }
}

/// Result model for trash / delete operations.
///
/// Corresponds to Python's `MessageDeletionStatus` dataclass.
class MessageDeletionStatus {
  final int msgId;
  final String boxType;
  final bool isDeleted;

  const MessageDeletionStatus({
    required this.msgId,
    required this.boxType,
    required this.isDeleted,
  });

  factory MessageDeletionStatus.fromXml(Map<String, dynamic> xml) {
    return MessageDeletionStatus(
      msgId: _int(xml, 'msgID'),
      boxType: _str(xml, 'boxType'),
      isDeleted: _bool(xml, 'status'),
    );
  }
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

  // ISO 8601 with timezone: 2024-01-15T10:30:00+02:00 or with Z: 2024-01-15T10:30:00Z
  try {
    return DateTime.parse(v);
  } catch (_) {}

  // ISO 8601 with microseconds/milliseconds (no timezone): 2024-01-15T10:30:00.123456
  final isoMicro = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+$');
  if (isoMicro.hasMatch(v)) {
    try {
      // Truncate microseconds to milliseconds (6 digits to 3) if needed
      final parts = v.split('.');
      if (parts.length == 2 && parts[1].length > 3) {
        final truncated = '${parts[0]}.${parts[1].substring(0, 3)}';
        return DateTime.parse(truncated);
      }
      return DateTime.parse(v);
    } catch (_) {}
  }

  // Date with time and seconds, no timezone: 2024-01-15T10:30:00
  final isoSeconds = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$');
  if (isoSeconds.hasMatch(v)) {
    try {
      return DateTime.parse(v);
    } catch (_) {}
  }

  // Date with time, no timezone: 2024-01-15 10:30
  final spaceFormat = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$');
  if (spaceFormat.hasMatch(v)) {
    try {
      return DateTime.parse(v.replaceFirst(' ', 'T'));
    } catch (_) {}
  }

  // Date with time and seconds: 2024-01-15 10:30:00
  final spaceFormatSeconds = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
  if (spaceFormatSeconds.hasMatch(v)) {
    try {
      return DateTime.parse(v.replaceFirst(' ', 'T'));
    } catch (_) {}
  }

  // Date only: 2024-01-15
  final dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (dateOnly.hasMatch(v)) {
    try {
      return DateTime.parse(v);
    } catch (_) {}
  }

  // If we get here, the datetime is in an unrecognized format.
  // This can happen when Smartschool returns error messages or malformed data.
  // Return epoch (1970-01-01) as a safe fallback rather than crashing.
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
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
