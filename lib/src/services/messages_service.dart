import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../exceptions.dart';
import '../session.dart';
import '../xml_interface.dart';
import '../models/message_models.dart';
import '../models/notification_models.dart';
// import 'message_send_options.dart';
import 'send_message_params.dart';

const String _xpathMessage = './/data/message';

/// Provides access to the Smartschool messaging system.
///
/// All Python message classes (`MessageHeaders`, `Message`, `Attachments`,
/// `MarkMessageUnread`, `AdjustMessageLabel`, `MessageMoveToTrash`,
/// `MessageMoveToArchive`) have been collapsed into methods on this single
/// service class.  Instead of instantiating an iterable and calling `list()`
/// on it, callers simply `await` a named method.
///
/// ```dart
/// final messages = MessagesService(client);
///
/// // List inbox headers
/// final headers = await messages.getHeaders();
///
/// // Fetch the full body of the first message
/// final full = await messages.getMessage(headers.first.id);
///
/// // Mark as unread
/// await messages.markUnread(headers.first.id);
/// ```
class MessagesService {
  final SmartschoolClient _client;
  final StreamController<MessageCounterUpdate> _messageCounterController =
      StreamController<MessageCounterUpdate>.broadcast();
  final Map<String, Set<int>> _incrementalSeenIdsByMailbox = {};
  final Map<String, Future<List<ShortMessage>>> _inFlightIncrementalByMailbox =
      {};
  final Map<String, Timer> _incrementalDebounceTimers = {};
  final Map<String, Completer<List<ShortMessage>>> _incrementalCompleters = {};

  int? _lastMessageCounter;
  int? _archiveBoxIdCache;

  static final RegExp _threadPrefixRegex = RegExp(
    r'^(?:(?:re|fw|fwd|aw|wg)\s*(?:\[\d+\])?\s*:\s*)+',
    caseSensitive: false,
  );

  /// The URL for the legacy Smartschool XML dispatcher (messages module).
  static const _messagesXmlUrl = '/?module=Messages&file=dispatcher';

  MessagesService(SmartschoolClient client) : _client = client;

  /// Emits message-specific counter updates derived from Smartschool
  /// notification counters.
  Stream<MessageCounterUpdate> get messageCounterUpdates =>
      _messageCounterController.stream;

  /// Normalizes a generic module [update] into a message counter update.
  ///
  /// Only updates for module `Messages` are emitted.
  /// Returns `true` when an event was emitted.
  bool handleNotificationCounterUpdate(NotificationCounterUpdate update) {
    if (update.moduleName.toLowerCase() != 'messages') return false;
    if (_lastMessageCounter == update.counter) return false;

    final previousCounter = _lastMessageCounter;
    _lastMessageCounter = update.counter;
    _messageCounterController.add(
      MessageCounterUpdate(
        counter: update.counter,
        previousCounter: previousCounter,
        isNew: update.isNew,
        source: update.source,
        timestamp: update.timestamp,
      ),
    );
    return true;
  }

  /// Binds this service to a stream of generic module counter updates.
  ///
  /// Caller owns the returned subscription and should cancel it when done.
  StreamSubscription<NotificationCounterUpdate> bindNotificationCounterStream(
    Stream<NotificationCounterUpdate> updates,
  ) {
    return updates.listen(handleNotificationCounterUpdate);
  }

  /// Seeds the incremental-sync seen-ID cache for a mailbox.
  ///
  /// Use this once after an initial header fetch to avoid a full list refresh
  /// on the first event-triggered incremental sync.
  void seedIncrementalSeenIds(
    Iterable<int> messageIds, {
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
  }) {
    final key = _mailboxKey(boxType, boxId, sortBy, sortOrder);
    final seen = _incrementalSeenIdsByMailbox.putIfAbsent(key, () => <int>{});
    seen.addAll(messageIds);
  }

  /// Schedules an incremental headers refresh with debounce and in-flight
  /// dedupe per mailbox.
  ///
  /// Multiple calls within [debounceWindow] are coalesced into one request.
  /// If a request is already in-flight for the same mailbox, callers await
  /// that request instead of spawning another one.
  Future<List<ShortMessage>> refreshHeadersIncremental({
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    Duration debounceWindow = const Duration(milliseconds: 300),
  }) {
    final key = _mailboxKey(boxType, boxId, sortBy, sortOrder);
    final existingCompleter = _incrementalCompleters[key];
    if (existingCompleter != null && !existingCompleter.isCompleted) {
      _rescheduleIncrementalTimer(
        key: key,
        boxType: boxType,
        boxId: boxId,
        sortBy: sortBy,
        sortOrder: sortOrder,
        debounceWindow: debounceWindow,
        completer: existingCompleter,
      );
      return existingCompleter.future;
    }

    final completer = Completer<List<ShortMessage>>();
    _incrementalCompleters[key] = completer;

    _rescheduleIncrementalTimer(
      key: key,
      boxType: boxType,
      boxId: boxId,
      sortBy: sortBy,
      sortOrder: sortOrder,
      debounceWindow: debounceWindow,
      completer: completer,
    );

    return completer.future;
  }

  /// Consumes a [MessageCounterUpdate] and performs a debounced incremental
  /// mailbox refresh.
  Future<List<ShortMessage>> refreshHeadersOnMessageCounter(
    MessageCounterUpdate update, {
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    Duration debounceWindow = const Duration(milliseconds: 300),
  }) {
    return refreshHeadersIncremental(
      boxType: boxType,
      boxId: boxId,
      sortBy: sortBy,
      sortOrder: sortOrder,
      debounceWindow: debounceWindow,
    );
  }

  /// Disposes timers/streams owned by this service.
  Future<void> dispose() async {
    for (final timer in _incrementalDebounceTimers.values) {
      timer.cancel();
    }
    _incrementalDebounceTimers.clear();
    _incrementalCompleters.clear();

    if (!_messageCounterController.isClosed) {
      await _messageCounterController.close();
    }
  }

  // -------------------------------------------------------------------------
  // Read operations
  // -------------------------------------------------------------------------

  /// Returns the message headers in [boxType], sorted by [sortBy] / [sortOrder].
  ///
  /// [boxId] identifies the sub-mailbox within [boxType].  Pass `0` (the
  /// default) for the primary inbox/outbox/etc.  Pass a non-zero value to
  /// reach a named folder — for example the archive folder at ID `208`
  /// (see [getArchiveHeaders] for the convenience wrapper).
  ///
  /// Pass [alreadySeenIds] to enable poll mode — only messages whose IDs are
  /// **not** in that list will be returned.
  Future<List<ShortMessage>> getHeaders({
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    List<int> alreadySeenIds = const [],
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'message list',
      params: {
        'boxType': boxType.value,
        'boxID': '$boxId',
        'sortField': sortBy.value,
        'sortKey': sortOrder.value,
        'poll': alreadySeenIds.isEmpty ? 'false' : 'true',
        'poll_ids': alreadySeenIds.join(','),
        'layout': 'new',
      },
      xpath: './/messages/message',
    );

    return entries.map(ShortMessage.fromXml).toList();
  }

  /// Returns message headers from the archive folder.
  ///
  /// The archive is not a separate [BoxType]; it is the inbox with a non-zero
  /// box ID.  If [boxId] is omitted, this method first resolves the archive
  /// folder ID from the Messages module HTML and caches it. If resolution
  /// fails, it falls back to `208`.
  ///
  /// This is a convenience wrapper around [getHeaders] with
  /// `boxType = BoxType.inbox` and the given [boxId].
  ///
  /// Use [getArchiveBoxId] when you need the resolved folder ID explicitly.
  Future<List<ShortMessage>> getArchiveHeaders({
    int? boxId,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    List<int> alreadySeenIds = const [],
  }) async {
    final resolvedBoxId = boxId ?? await _resolveArchiveBoxId();
    return getHeaders(
      boxType: BoxType.inbox,
      boxId: resolvedBoxId,
      sortBy: sortBy,
      sortOrder: sortOrder,
      alreadySeenIds: alreadySeenIds,
    );
  }

  /// Returns the archive folder box ID for the current account.
  ///
  /// The value is discovered from the Messages module HTML and cached for this
  /// service instance. If discovery fails, this returns the legacy fallback
  /// value `208`.
  Future<int> getArchiveBoxId() => _resolveArchiveBoxId();

  /// Resolves and caches the archive folder box ID for the current account.
  Future<int> _resolveArchiveBoxId() async {
    final cached = _archiveBoxIdCache;
    if (cached != null && cached > 0) return cached;

    try {
      final html = await _client.getRaw(
        '/?module=Messages&file=index&function=main',
      );
      final parsed = parseArchiveBoxIdFromMessagesHtml(html);
      if (parsed != null && parsed > 0) {
        _archiveBoxIdCache = parsed;
        return parsed;
      }
    } catch (_) {
      // Keep legacy fallback for resilience.
    }

    _archiveBoxIdCache = 208;
    return 208;
  }

  /// Fetches the full content of message [msgId] from [boxType].
  ///
  /// By default Smartschool truncates the recipient lists and reports the
  /// hidden count via [FullMessage.totalNrOtherToReceivers] /
  /// [FullMessage.totalNrOtherCcReceivers].  Set [includeAllRecipients] to
  /// `true` to retrieve the complete lists in a single call — the server
  /// then returns all names and the `totalNr*` fields become 0.
  ///
  /// To also obtain the numeric user IDs of every recipient (required for a
  /// programmatic reply-all), call [getReplyAllRecipients] instead of or in
  /// addition to this method.
  ///
  /// Returns `null` if the server returns no message element for this ID.
  Future<FullMessage?> getMessage(
    int msgId, {
    BoxType boxType = BoxType.inbox,
    bool includeAllRecipients = false,
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'show message',
      params: {
        'msgID': '$msgId',
        'boxType': boxType.value,
        'limitList': includeAllRecipients ? 'false' : 'true',
      },
      xpath: _xpathMessage,
    );

    if (entries.isEmpty) return null;

    // Post-process receiver lists (mirrors Python's `_post_process_element`)
    final xml = Map<String, dynamic>.from(entries.first);
    for (final field in ['receivers', 'ccreceivers', 'bccreceivers']) {
      final v = xml[field];
      if (v == null || (v is String && v.trim().isEmpty)) {
        xml[field] = null; // _receiverList handles null as []
      }
    }

    return FullMessage.fromXml(xml);
  }

  /// Returns the attachments on message [msgId] in [boxType].
  Future<List<MessageAttachment>> getAttachments(
    int msgId, {
    BoxType boxType = BoxType.inbox,
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'attachment list',
      params: {
        'msgID': '$msgId',
        'boxType': boxType.value,
        'limitList': 'true',
      },
      xpath: './/attachmentlist/attachment',
    );

    return entries.map(MessageAttachment.fromXml).toList();
  }

  // -------------------------------------------------------------------------
  // Mutation operations
  // -------------------------------------------------------------------------

  /// Marks message [msgId] in [boxType] as unread.
  ///
  /// For messages in the archive folder pass the same [boxId] you used when
  /// retrieving them (usually `208`).  Defaults to `0` (primary mailbox).
  ///
  /// Returns the updated [MessageChanged] record from the server.
  Future<MessageChanged?> markUnread(
    int msgId, {
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'mark message unread',
      params: {
        'boxType': boxType.value,
        'boxID': '$boxId',
        'msgID': '$msgId',
        'clAction': 'status',
      },
      xpath: _xpathMessage,
    );

    return entries.isEmpty ? null : MessageChanged.fromXml(entries.first);
  }

  /// Marks message [msgId] in [boxType] as read.
  ///
  /// [getMessage] intentionally does not flip the read state; call this method
  /// after (or alongside) [getMessage] when you want the server to treat the
  /// message as opened. The call is idempotent — invoking it on an
  /// already-read message is a no-op.
  ///
  /// Returns the updated [MessageChanged] record from the server. The server
  /// responds with `<status>1</status>` to indicate the message is now read.
  Future<MessageChanged?> markRead(
    int msgId, {
    BoxType boxType = BoxType.inbox,
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'mark message read',
      params: {
        'msgID': '$msgId',
        'boxType': boxType.value,
        'limitList': 'true',
      },
      xpath: _xpathMessage,
    );

    return entries.isEmpty ? null : MessageChanged.fromXml(entries.first);
  }

  /// Sets the colour [label] on message [msgId] in [boxType].
  ///
  /// Use [MessageLabel.noFlag] to clear the flag.
  Future<MessageChanged?> setLabel(
    int msgId,
    MessageLabel label, {
    BoxType boxType = BoxType.inbox,
  }) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'save msglabel',
      params: {
        'boxType': boxType.value,
        'msgLabel': '${label.value}',
        'msgID': '$msgId',
        'clAction': 'label',
      },
      xpath: _xpathMessage,
    );

    return entries.isEmpty ? null : MessageChanged.fromXml(entries.first);
  }

  /// Moves message [msgId] to the trash.
  ///
  /// Returns the deletion status from the server.
  Future<MessageDeletionStatus?> moveToTrash(int msgId) async {
    final entries = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: 'quick delete',
      params: {'msgID': '$msgId'},
      xpath: './/data/details',
    );

    return entries.isEmpty
        ? null
        : MessageDeletionStatus.fromXml(entries.first);
  }

  /// Archives one or more messages identified by [msgIds].
  ///
  /// Unlike other message operations this uses a separate REST endpoint
  /// (`/Messages/Xhr/archivemessages`) rather than the XML dispatcher —
  /// this is noted as "weird" in the Python source too.
  ///
  /// Returns a list of [MessageChanged] with the result for each message.
  Future<List<MessageChanged>> moveToArchive(List<int> msgIds) async {
    // The server expects form-urlencoded data with repeated field names:
    // msgIDs[]=123&msgIDs[]=456
    final body = msgIds.map((id) => 'msgIDs%5B%5D=$id').join('&');

    final responseStr = await _client.postFormEncodedRaw(
      '/Messages/Xhr/archivemessages',
      body,
    );

    final resp = jsonDecode(responseStr);
    final map = resp as Map<String, dynamic>;
    final success = (map['success'] as List?)?.cast<int>() ?? [];

    return msgIds
        .map(
          (id) =>
              MessageChanged(id: id, newValue: success.contains(id) ? 1 : 0),
        )
        .toList();
  }

  // -------------------------------------------------------------------------
  // Search / compose
  // -------------------------------------------------------------------------

  /// Searches for recipients using the JSON-based `/Messages/Xhr/searchRecipients`
  /// endpoint.
  ///
  /// Results have type `"user"` or `"group"`.  These objects do **not** carry
  /// the `ssID` required by the compose-form — for compose-form searches use
  /// [searchRecipientsForCompose] instead.
  Future<List<MessageSearchResult>> searchRecipients(String query) async {
    final resp = await _client.getJson(
      '/Messages/Xhr/searchRecipients',
      query: {'q': query},
    );

    final list = resp as List;
    return list
        .map((e) => MessageSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Searches for recipients using the compose-form XML endpoint
  /// (`/?module=Messages&file=searchUsers`).
  ///
  /// Returns a record `(users, groups)` where each element carries the `ssId`
  /// and `userLt` values needed to pass them to [sendMessage].
  ///
  /// Internally loads a fresh compose page to obtain the `uniqueUsc` token
  /// required by the search endpoint.  If you intend to call [sendMessage]
  /// immediately after, that call will perform its own form load — two
  /// lightweight page requests total, which is acceptable for normal use.
  Future<(List<MessageSearchUser>, List<MessageSearchGroup>)>
  searchRecipientsForCompose(String query) async {
    final hidden = await _loadComposeFields();
    final uniqueUsc = hidden['uniqueUsc'] ?? '';
    if (uniqueUsc.isEmpty) {
      throw const SmartschoolComposeError(
        'searchRecipientsForCompose: could not extract uniqueUsc from the '
        'compose form. Check that the account has permission to send messages.',
      );
    }
    return _searchUsers(query, uniqueUsc);
  }

  /// Fetches all reply-all recipients for [msgId] with their platform user IDs.
  ///
  /// The XML `show message` endpoint only returns recipient display names.
  /// This method loads the Smartschool reply-all compose page
  /// (`composeType=2`), which pre-populates every recipient slot with the
  /// resolved `realuserid` and `ssID`, and extracts that data via
  /// [parseReplyAllRecipients].
  ///
  /// Returns a record `(to, cc)` where each list contains [MessageSearchUser]
  /// instances ready to be passed directly to [sendMessage].  The sender of
  /// the original message is placed in the `to` list following Smartschool's
  /// standard reply-all logic.  The authenticated user is excluded.
  Future<(List<MessageSearchUser>, List<MessageSearchUser>)>
  getReplyAllRecipients(
    int msgId, {
    BoxType boxType = BoxType.inbox,
  }) async {
    final html = await _client.getRaw(
      _composeUrl(
        boxType: boxType,
        composeType: 2,
        msgId: '$msgId',
      ),
    );
    return parseReplyAllRecipients(html);
  }

  /// Parses the reply-all compose page HTML and extracts pre-populated
  /// recipients with their numeric user IDs.
  ///
  /// Each recipient `<div class="receiverSpan">` carries `realuserid`,
  /// `ssidatt`, `userltatt`, and `typeatt` attributes.  `typeatt=2` indicates
  /// CC; everything else is treated as a To recipient.
  ///
  /// Returns `(toList, ccList)`.
  static (List<MessageSearchUser>, List<MessageSearchUser>)
  parseReplyAllRecipients(String htmlBody) {
    final doc = html_parser.parse(htmlBody);
    final to = <MessageSearchUser>[];
    final cc = <MessageSearchUser>[];

    for (final span in doc.querySelectorAll('div.receiverSpan')) {
      final userIdStr = span.attributes['realuserid'];
      final ssIdStr = span.attributes['ssidatt'];
      final userLtStr = span.attributes['userltatt'] ?? '0';
      final typeStr = span.attributes['typeatt'] ?? '0';
      final nameEl = span.querySelector('.receiverSpanName');

      if (userIdStr == null || ssIdStr == null || nameEl == null) continue;

      final userId = int.tryParse(userIdStr);
      final ssId = int.tryParse(ssIdStr);
      if (userId == null || ssId == null) continue;

      final user = MessageSearchUser(
        userId: userId,
        displayName: nameEl.text.trim(),
        ssId: ssId,
        userLt: int.tryParse(userLtStr) ?? 0,
      );

      if (typeStr == '2') {
        cc.add(user);
      } else {
        to.add(user);
      }
    }

    return (to, cc);
  }

  /// Returns the original recipients of a sent message identified by [msgId].
  ///
  /// The XML `show message` endpoint does not expose recipient user IDs for
  /// outbox messages.  This method loads the reply-all compose page for the
  /// sent folder (`boxType=outbox&composeType=2`), which pre-populates the
  /// To field with both the original recipients **and** the authenticated user
  /// (as sender).  The authenticated user is identified via the page's
  /// embedded `tinymceInitConfig.userID` value and filtered out, leaving only
  /// the actual recipients.
  ///
  /// Returns a record `(to, cc)` where each list contains [MessageSearchUser]
  /// instances ready to be passed directly to [sendMessage].
  Future<(List<MessageSearchUser>, List<MessageSearchUser>)>
  getSentMessageRecipients(int msgId) async {
    final html = await _client.getRaw(
      _composeUrl(
        boxType: BoxType.sent,
        composeType: 2,
        msgId: '$msgId',
      ),
    );
    return parseSentMessageRecipients(html);
  }

  /// Parses the reply-all compose page for a sent message and returns the
  /// original recipients with the authenticated user excluded.
  ///
  /// The sent-folder reply-all compose page places the sender (the
  /// authenticated user) alongside the original recipients in the To field.
  /// This method combines [parseComposeCurrentUserIds] to identify the sender
  /// and [parseReplyAllRecipients] to extract all pre-populated recipient
  /// spans, then removes any entry whose `userId` matches the sender.
  ///
  /// Returns `(toList, ccList)`.
  static (List<MessageSearchUser>, List<MessageSearchUser>)
  parseSentMessageRecipients(String htmlBody) {
    final ids = parseComposeCurrentUserIds(htmlBody);
    final currentUserId = ids?.$1;

    final (to, cc) = parseReplyAllRecipients(htmlBody);

    if (currentUserId == null) return (to, cc);

    return (
      to.where((u) => u.userId != currentUserId).toList(),
      cc.where((u) => u.userId != currentUserId).toList(),
    );
  }

  /// Returns the logged-in user as a compose recipient candidate.
  ///
  /// This reads `userID` / `ssID` directly from the compose page JavaScript,
  /// so callers can safely send a message to themselves without relying on a
  /// fuzzy recipient search match.
  Future<MessageSearchUser> getCurrentUserAsRecipient() async {
    final html = await _client.getRaw(_composeUrl());
    final ids = parseComposeCurrentUserIds(html);
    if (ids == null) {
      throw const SmartschoolComposeError(
        'Could not extract compose current user IDs (userID/ssID) from '
        'compose page.',
      );
    }

    return MessageSearchUser(
      userId: ids.$1,
      displayName: 'Me',
      ssId: ids.$2,
      userLt: ids.$3,
    );
  }

  /// Sends a new message using the full Smartschool compose-form workflow.
  ///
  /// This follows the exact multi-step flow observed in the browser:
  /// 1. Fetch the compose page and extract hidden form tokens
  ///    (`uniqueUsc`, `randomDir`, `encryptedSender`, …).
  /// 2. Register each recipient via `addUserToSelected` for every
  ///    to / cc / bcc slot.
  /// 3. Optionally upload files from [attachmentPaths].
  /// 4. POST the completed payload as `multipart/form-data`.
  ///
  /// Obtain [MessageSearchUser] / [MessageSearchGroup] objects from
  /// [searchRecipientsForCompose], or build them directly when you already
  /// know the recipient's `userId`/`groupId` and `ssId`
  /// (e.g. from [SmartschoolClient.authenticatedUser]).
  ///
  /// Throws [SmartschoolComposeError] if the compose form cannot be parsed or
  /// the server rejects the submission.
  /// Throws [SmartschoolAttachmentUploadError] if an attachment fails to upload.
  Future<void> sendMessage(SendMessageParams params) async {
    // Step 1: load a fresh compose form and extract all hidden token fields.
    final hidden = await _loadComposeFields();

    final uniqueUsc = hidden['uniqueUsc'] ?? '';
    final randomDir = hidden['randomDir'] ?? '';

    if (uniqueUsc.isEmpty) {
      throw const SmartschoolComposeError(
        'sendMessage: could not extract uniqueUsc from the compose form. '
        'Check that the account has permission to send messages.',
      );
    }

    // Step 2: register all recipients on the server-side form state.
    for (final user in params.to) {
      await _addUserToForm(user, RecipientType.to, uniqueUsc);
    }
    for (final user in params.cc) {
      await _addUserToForm(user, RecipientType.cc, uniqueUsc);
    }
    for (final user in params.bcc) {
      await _addUserToForm(user, RecipientType.bcc, uniqueUsc);
    }
    for (final group in params.toGroups) {
      await _addGroupToForm(group, RecipientType.to, uniqueUsc);
    }
    for (final group in params.ccGroups) {
      await _addGroupToForm(group, RecipientType.cc, uniqueUsc);
    }
    for (final group in params.bccGroups) {
      await _addGroupToForm(group, RecipientType.bcc, uniqueUsc);
    }

    // Step 3: upload attachments.
    if (params.attachmentPaths.isNotEmpty && randomDir.isEmpty) {
      throw const SmartschoolComposeError(
        'sendMessage: randomDir is missing from the compose form; '
        'cannot upload attachments.',
      );
    }
    for (final path in params.attachmentPaths) {
      await _uploadAttachment(path, randomDir);
    }

    // Step 4: build multipart payload matching the observed browser request.
    final url = _composeUrl();
    final payload = <String, dynamic>{
      'module': 'Messages',
      'file': 'composeMessage',
      'boxType': BoxType.inbox.value,
      'composeType': '0',
      'msgID': 'undefined',
      'encryptedSender': hidden['encryptedSender'] ?? '',
      'send': 'send',
      'origMsgID': hidden['origMsgID'] ?? '0',
      'composeAction': hidden['composeAction'] ?? '0',
      'randomDir': randomDir,
      'uniqueUsc': uniqueUsc,
      'showTab': hidden['showTab'] ?? 'tab1Container',
      'delFile': hidden['delFile'] ?? '0',
      'msgFormSelectedTab': hidden['msgFormSelectedTab'] ?? '',
      'sendDate': hidden['sendDate'] ?? '',
      'searchField3': '',
      'searchField1': '',
      'searchField4': '',
      'searchField5': '',
      'subject': params.subject,
      'copyToLVS': 'dontCopyToLVS',
      'message': params.bodyHtml,
      'bcc': '0',
    };

    final formData = FormData.fromMap(payload);
    final responseHtml = await _client.postMultipartRaw(url, formData);

    // The success response is an HTML window-close page.  An error page
    // typically contains a JS `var error` assignment or an error element.
    if (responseHtml.contains('var error') ||
        responseHtml.contains('type=\'error\'') ||
        responseHtml.contains('type="error"')) {
      throw SmartschoolComposeError(
        'sendMessage: server returned an error page. '
        'Response preview: '
        '${responseHtml.substring(0, responseHtml.length.clamp(0, 300))}',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Private compose helpers
  // -------------------------------------------------------------------------

  static String _composeUrl({
    BoxType boxType = BoxType.inbox,
    int composeType = 0,
    String msgId = 'undefined',
  }) =>
      '/?module=Messages&file=composeMessage'
      '&boxType=${boxType.value}&composeType=$composeType&msgID=$msgId';

  /// GETs the compose page and returns all hidden `<input>` field values.
  Future<Map<String, String>> _loadComposeFields() async {
    final html = await _client.getRaw(_composeUrl());
    return parseHiddenFields(html);
  }

  /// Extracts all `<input type="hidden">` fields from an HTML document.
  ///
  /// Exposed as a public static for testing compose-form parsing.
  static Map<String, String> parseHiddenFields(String htmlBody) {
    final doc = html_parser.parse(htmlBody);
    final result = <String, String>{};
    for (final input in doc.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'];
      final value = input.attributes['value'] ?? '';
      if (name != null && name.isNotEmpty) {
        result[name] = value;
      }
    }
    return result;
  }

  /// Extracts `(userId, ssId, userLt)` from compose page HTML.
  ///
  /// The values are sourced from the `window.tinymceInitConfig` JS object
  /// that Smartschool embeds in the compose page.  Confirmed live format:
  ///
  /// ```js
  /// window.tinymceInitConfig = {
  ///   userID \t: '146',
  ///   userLT \t: '0',
  ///   ssID\t: '4069',
  ///   ...
  /// };
  /// ```
  ///
  /// Returns `null` when required values are not present.
  static (int, int, int)? parseComposeCurrentUserIds(String htmlBody) {
    // Scope the search to the script block that contains `tinymceInit` to
    // avoid false matches elsewhere on the page.
    final doc = html_parser.parse(htmlBody);
    String? configBlock;
    for (final script in doc.querySelectorAll('script')) {
      final text = script.text;
      if (text.contains('tinymceInit')) {
        configBlock = text;
        break;
      }
    }

    // Defensive fall-back: search the full HTML when the expected block is absent.
    final source = configBlock ?? htmlBody;

    int? readInt(RegExp rx) {
      final m = rx.firstMatch(source);
      return m == null ? null : int.tryParse(m.group(1)!);
    }

    final userId = readInt(RegExp(r'''\buserID\s*:\s*['"](\d+)['"]'''));
    final ssId = readInt(RegExp(r'''\bssID\s*:\s*['"](\d+)['"]'''));
    final userLt = readInt(RegExp(r'''\buserLT\s*:\s*['"](\d+)['"]''')) ?? 0;

    if (userId == null || ssId == null) return null;
    return (userId, ssId, userLt);
  }

  /// Extracts the archive folder box ID from the Messages module HTML.
  ///
  /// Returns `null` when no archive folder element is found.
  static int? parseArchiveBoxIdFromMessagesHtml(String htmlBody) {
    final doc = html_parser.parse(htmlBody);

    for (final node in doc.querySelectorAll('div.postboxsub')) {
      final icon = node.querySelector('.postbox_ico_sub.archive');
      if (icon == null) continue;

      final iconBoxId = int.tryParse(icon.attributes['boxid'] ?? '');
      if (iconBoxId != null && iconBoxId > 0) return iconBoxId;

      final nodeBoxId = int.tryParse(node.attributes['boxid'] ?? '');
      if (nodeBoxId != null && nodeBoxId > 0) return nodeBoxId;

      final link = node.querySelector('a.postbox_link[boxid]');
      final linkBoxId = int.tryParse(link?.attributes['boxid'] ?? '');
      if (linkBoxId != null && linkBoxId > 0) return linkBoxId;
    }

    return null;
  }

  /// Normalises [subject] to a stable thread key.
  ///
  /// This strips leading reply/forward prefixes (for example `Re:`, `Fwd:`,
  /// `FW:`, `AW:`, `WG:`), trims surrounding whitespace and collapses repeated
  /// internal whitespace.
  ///
  /// Useful for grouping message headers by conversation thread.
  static String threadSubjectKey(String subject) {
    final compact = subject.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return '';
    return compact.replaceFirst(_threadPrefixRegex, '').trim();
  }

  /// Returns a reply subject for [subject] with exactly one [replyPrefix].
  ///
  /// Existing reply/forward prefixes are removed before the prefix is added,
  /// preventing values such as `Re: Re: Topic`.
  static String ensureReplySubject(
    String subject, {
    String replyPrefix = 'Re:',
  }) {
    final cleanedPrefix = replyPrefix.trim();
    final root = threadSubjectKey(subject);

    if (cleanedPrefix.isEmpty) return root;
    if (root.isEmpty) return cleanedPrefix;
    return '$cleanedPrefix $root';
  }

  /// POSTs the compose-form search endpoint and returns parsed results.
  Future<(List<MessageSearchUser>, List<MessageSearchGroup>)> _searchUsers(
    String query,
    String uniqueUsc,
  ) async {
    final xml = await _client
        .postFormRaw('/?module=Messages&file=searchUsers', {
          'val': query,
          'type': RecipientType.to.requestType,
          'parentNodeId': RecipientType.to.parentNodeId,
          'xml': '<results></results>',
          'uniqueUsc': uniqueUsc,
        });

    final users = XmlInterface.parseResponse(
      xml,
      './/users/user',
    ).map(MessageSearchUser.fromXml).toList();

    final groups = XmlInterface.parseResponse(
      xml,
      './/groups/group',
    ).map(MessageSearchGroup.fromXml).toList();

    return (users, groups);
  }

  /// Registers a single user recipient on the server-side compose form state.
  Future<void> _addUserToForm(
    MessageSearchUser user,
    RecipientType recipientType,
    String uniqueUsc,
  ) => _client.postFormRaw(
    '/?module=Messages&file=searchUsers&function=addUserToSelected',
    {
      'id': '${user.userId}',
      'typeId': 'users',
      'type': recipientType.requestType,
      'parentNodeId': recipientType.parentNodeId,
      'ssid': '${user.ssId}',
      'userlt': '${user.userLt}',
      'uniqueUsc': uniqueUsc,
    },
  );

  /// Registers a single group recipient on the server-side compose form state.
  Future<void> _addGroupToForm(
    MessageSearchGroup group,
    RecipientType recipientType,
    String uniqueUsc,
  ) => _client.postFormRaw(
    '/?module=Messages&file=searchUsers&function=addUserToSelected',
    {
      'id': '${group.groupId}',
      'typeId': 'groups',
      'type': recipientType.requestType,
      'parentNodeId': recipientType.parentNodeId,
      'ssid': '${group.ssId}',
      'userlt': '0',
      'uniqueUsc': uniqueUsc,
    },
  );

  /// Uploads a single attachment file to `/Upload/Upload/Index`.
  ///
  /// [uploadDir] should be the `randomDir` token from the compose form.
  Future<void> _uploadAttachment(String filePath, String uploadDir) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw SmartschoolAttachmentUploadError(
        'Attachment file not found: $filePath',
      );
    }

    final fileName = file.uri.pathSegments.last;
    final mimeType = guessMimeType(fileName);
    final bytes = await file.readAsBytes();

    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: DioMediaType.parse(mimeType),
      ),
      'uploadDir': uploadDir,
    });

    final response = await _client.postMultipartRaw(
      '/Upload/Upload/Index',
      formData,
    );

    final result = response.trim().toLowerCase();
    if (result == 'true') return;
    if (result == 'false') {
      throw SmartschoolAttachmentUploadError(
        "Attachment upload failed for '$fileName': server returned false.",
      );
    }
    throw SmartschoolAttachmentUploadError(
      "Attachment upload returned unexpected response for '$fileName': "
      '${response.length > 100 ? response.substring(0, 100) : response}',
    );
  }

  /// Returns a MIME type string for [fileName] based on file extension.
  ///
  /// Falls back to `application/octet-stream` for unknown types.
  /// Exposed as a public static for testing and custom compose flows.
  static String guessMimeType(String fileName) {
    const table = {
      'pdf': 'application/pdf',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'svg': 'image/svg+xml',
      'webp': 'image/webp',
      'txt': 'text/plain',
      'html': 'text/html',
      'htm': 'text/html',
      'csv': 'text/csv',
      'xml': 'application/xml',
      'json': 'application/json',
      'zip': 'application/zip',
      'tar': 'application/x-tar',
      'gz': 'application/gzip',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
    };
    final ext = fileName.split('.').lastOrNull?.toLowerCase() ?? '';
    return table[ext] ?? 'application/octet-stream';
  }

  void _rescheduleIncrementalTimer({
    required String key,
    required BoxType boxType,
    required int boxId,
    required SortField sortBy,
    required SortOrder sortOrder,
    required Duration debounceWindow,
    required Completer<List<ShortMessage>> completer,
  }) {
    _incrementalDebounceTimers[key]?.cancel();
    _incrementalDebounceTimers[key] = Timer(debounceWindow, () async {
      try {
        final headers = await _startOrJoinIncrementalFetch(
          key: key,
          boxType: boxType,
          boxId: boxId,
          sortBy: sortBy,
          sortOrder: sortOrder,
        );
        if (!completer.isCompleted) {
          completer.complete(headers);
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      } finally {
        _incrementalDebounceTimers.remove(key);
        if (identical(_incrementalCompleters[key], completer)) {
          _incrementalCompleters.remove(key);
        }
      }
    });
  }

  Future<List<ShortMessage>> _startOrJoinIncrementalFetch({
    required String key,
    required BoxType boxType,
    required int boxId,
    required SortField sortBy,
    required SortOrder sortOrder,
  }) {
    final inFlight = _inFlightIncrementalByMailbox[key];
    if (inFlight != null) {
      return inFlight;
    }

    final seen = _incrementalSeenIdsByMailbox.putIfAbsent(key, () => <int>{});

    final future =
        getHeaders(
              boxType: boxType,
              boxId: boxId,
              sortBy: sortBy,
              sortOrder: sortOrder,
              alreadySeenIds: seen.toList(growable: false),
            )
            .then((headers) {
              for (final header in headers) {
                seen.add(header.id);
              }
              return headers;
            })
            .whenComplete(() {
              _inFlightIncrementalByMailbox.remove(key);
            });

    _inFlightIncrementalByMailbox[key] = future;
    return future;
  }

  static String _mailboxKey(
    BoxType boxType,
    int boxId,
    SortField sortBy,
    SortOrder sortOrder,
  ) => '${boxType.value}|$boxId|${sortBy.value}|${sortOrder.value}';
}
