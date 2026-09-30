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

/// The message a send replies to (see [MessagesService.sendReply]): its ID,
/// its box, and whether the reply goes to all its recipients.
typedef _Reply = ({int msgId, BoxType boxType, bool all});

/// A recipient entry of a compose form (`div.receiverSpan`): the [user] it
/// names, the [field] it is in (as [MessagesService.parseReplyAllRecipients]
/// sorts it), and the attributes that Smartschool's compose script takes it
/// off the form with (`deleteUsersFromSelected`, #42): [type], its
/// `typeatt` (the `droppedtype` of its field: `0` To, `2` CC, `3` BCC, `1`,
/// `4` and `5` the co-account fields), and [id], its `idatt` (the user ID
/// with Smartschool's `U` prefix, such as `U201`).
typedef _FormEntry = ({
  MessageSearchUser user,
  RecipientType field,
  String type,
  String id,
});

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
  ///
  /// Returns one page: at most the first 50 headers in the given order (the
  /// newest 50 by default). Use [getHeaderPages] or [getAllHeaders] to get
  /// the older ones too.
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
      params: _messageListParams(
        boxType: boxType,
        boxId: boxId,
        sortBy: sortBy,
        sortOrder: sortOrder,
        alreadySeenIds: alreadySeenIds,
      ),
      xpath: './/messages/message',
    );

    return entries.map(ShortMessage.fromXml).toList();
  }

  /// Returns the message headers in [boxType] page by page, not only the
  /// first page that [getHeaders] returns.
  ///
  /// Smartschool's `message list` answers with at most 50 headers and takes
  /// no offset. Its web client loads the rest while the user scrolls down:
  /// as long as an answer announces more (with a `continue_messages`
  /// action), it asks for the next page with a `continue_messages` request,
  /// and Smartschool answers with the next 50 headers of the box, in the
  /// order of the `message list`. This stream does the same. Its first event
  /// is the page [getHeaders] returns; each next page is requested only when
  /// the listener is ready for it, so `take`, `takeWhile` or cancelling the
  /// subscription stops the paging without fetching the rest of the box.
  ///
  /// The stream closes after the last page of the box, and also at a page
  /// that brings no header the stream has not emitted yet, so a server that
  /// repeats a page cannot keep it going. A header already emitted is left
  /// out of later pages, and a page is never empty: an empty box gives a
  /// stream without events. Pages are about 50 headers each but may be
  /// shorter before the last.
  ///
  /// Smartschool keeps the paging position in the session, one per box, and
  /// restarts it on every `message list` of that box: a [getHeaders] (also in
  /// poll mode, which [refreshHeadersIncremental] uses) or another paging of
  /// the same box while this stream is paging makes the next page one that
  /// was already emitted, which ends the stream early. Paging different boxes
  /// at the same time is fine.
  ///
  /// [boxId], [sortBy] and [sortOrder] are those of [getHeaders]; for the
  /// archive, use [getArchiveHeaderPages].
  Stream<List<ShortMessage>> getHeaderPages({
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
  }) async* {
    final emitted = <int>{};
    var page = await _fetchHeaderPage(
      'message list',
      _messageListParams(
        boxType: boxType,
        boxId: boxId,
        sortBy: sortBy,
        sortOrder: sortOrder,
      ),
    );
    while (true) {
      final fresh = [
        for (final header in page.headers)
          if (emitted.add(header.id)) header,
      ];
      if (fresh.isEmpty) return;
      yield fresh;
      if (!page.hasMore) return;
      page = await _fetchHeaderPage('continue_messages', {
        'boxID': '$boxId',
        'boxType': boxType.value,
        'layout': 'new',
      });
    }
  }

  /// Returns all message headers in [boxType], not only the first 50 that
  /// [getHeaders] returns, by collecting [getHeaderPages].
  ///
  /// Each page of 50 headers is a request, and a box can hold thousands of
  /// messages. Pass [limit] (at least 1) to stop at that many headers: no
  /// further page is requested once they are in, and at most [limit] headers
  /// are returned, the first ones in the given order.
  ///
  /// The paging ends early when the box is listed again in the same session
  /// while it runs; see [getHeaderPages].
  Future<List<ShortMessage>> getAllHeaders({
    BoxType boxType = BoxType.inbox,
    int boxId = 0,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    int? limit,
  }) => _collectHeaders(
    getHeaderPages(
      boxType: boxType,
      boxId: boxId,
      sortBy: sortBy,
      sortOrder: sortOrder,
    ),
    limit,
  );

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

  /// Returns the message headers in the archive folder page by page, not
  /// only the first page that [getArchiveHeaders] returns.
  ///
  /// This is [getHeaderPages] with `boxType = BoxType.inbox` and the archive
  /// folder's box ID, resolved as [getArchiveHeaders] does when [boxId] is
  /// omitted.
  Stream<List<ShortMessage>> getArchiveHeaderPages({
    int? boxId,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
  }) async* {
    final resolvedBoxId = boxId ?? await _resolveArchiveBoxId();
    yield* getHeaderPages(
      boxType: BoxType.inbox,
      boxId: resolvedBoxId,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
  }

  /// Returns all message headers in the archive folder, not only the first
  /// 50 that [getArchiveHeaders] returns, by collecting
  /// [getArchiveHeaderPages].
  ///
  /// [limit] works as for [getAllHeaders].
  Future<List<ShortMessage>> getAllArchiveHeaders({
    int? boxId,
    SortField sortBy = SortField.date,
    SortOrder sortOrder = SortOrder.desc,
    int? limit,
  }) => _collectHeaders(
    getArchiveHeaderPages(boxId: boxId, sortBy: sortBy, sortOrder: sortOrder),
    limit,
  );

  /// The params of a `message list` request.
  static Map<String, String> _messageListParams({
    required BoxType boxType,
    required int boxId,
    required SortField sortBy,
    required SortOrder sortOrder,
    List<int> alreadySeenIds = const [],
  }) => {
    'boxType': boxType.value,
    'boxID': '$boxId',
    'sortField': sortBy.value,
    'sortKey': sortOrder.value,
    'poll': alreadySeenIds.isEmpty ? 'false' : 'true',
    'poll_ids': alreadySeenIds.join(','),
    'layout': 'new',
  };

  /// Sends [action] (`message list` or `continue_messages`) and returns the
  /// headers of the page it answers with, and whether Smartschool announces
  /// a next page.
  ///
  /// The headers are in the `rebuild` action of a `message list` answer and
  /// in the `rebuildcontinue` action of a `continue_messages` answer, both as
  /// `<data><messages><message>`. A next page is announced by a
  /// `continue_messages` action; the last page comes with a `rebuildfinish`
  /// action (`<data><message/></data>`) instead.
  Future<({List<ShortMessage> headers, bool hasMore})> _fetchHeaderPage(
    String action,
    Map<String, String> params,
  ) async {
    final actions = await _client.postXml(
      url: _messagesXmlUrl,
      subsystem: 'postboxes',
      action: action,
      params: params,
      xpath: './/actions/action',
    );

    final headers = <ShortMessage>[];
    var hasMore = false;
    for (final answer in actions) {
      if (answer['command'] == 'continue_messages') hasMore = true;
      for (final data in _elements(answer['data'])) {
        for (final messages in _elements(data['messages'])) {
          headers.addAll(
            _elements(messages['message']).map(ShortMessage.fromXml),
          );
        }
      }
    }
    return (headers: headers, hasMore: hasMore);
  }

  /// The element maps in [value], a value of [XmlInterface.elementToMap]:
  /// one element is a map, repeated elements are a list of them, and an
  /// element without children is its text, which holds none.
  static Iterable<Map<String, dynamic>> _elements(Object? value) =>
      switch (value) {
        Map<String, dynamic>() => [value],
        List() => value.whereType<Map<String, dynamic>>(),
        _ => const [],
      };

  /// Collects the headers of [pages], stopping at [limit] headers.
  static Future<List<ShortMessage>> _collectHeaders(
    Stream<List<ShortMessage>> pages,
    int? limit,
  ) async {
    if (limit != null && limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }
    final headers = <ShortMessage>[];
    await for (final page in pages) {
      headers.addAll(page);
      if (limit != null && headers.length >= limit) {
        return headers.sublist(0, limit);
      }
    }
    return headers;
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
  /// For a message in the sent box ([BoxType.sent]), the recipients also
  /// say whether each has read the message
  /// ([FullMessage.toRecipients] and [MessageRecipient.hasRead]); see
  /// [FullMessage.fromXml].
  ///
  /// Returns `null` when [boxType] holds no message [msgId]: an unknown ID,
  /// or the ID of a message in another box. Smartschool answers such a
  /// request with a placeholder message (sender `Niet beschikbaar`, no read
  /// state, no date) rather than none; this method recognises it and does
  /// not return it.
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

    if (entries.isEmpty || _isPlaceholderMessage(entries.first)) return null;

    // Post-process receiver lists (mirrors Python's `_post_process_element`)
    final xml = Map<String, dynamic>.from(entries.first);
    for (final field in ['receivers', 'ccreceivers', 'bccreceivers']) {
      final v = xml[field];
      if (v == null || (v is String && v.trim().isEmpty)) {
        xml[field] = null; // _receiverList handles null as []
      }
    }

    return FullMessage.fromXml(xml, boxType: boxType);
  }

  /// Whether [xml], the `<message>` of a `show message` answer, is the
  /// placeholder Smartschool sends for a message ID the requested box does
  /// not hold, instead of leaving the element out (#16).
  ///
  /// The placeholder echoes the requested ID and has made-up texts in the
  /// platform's language (sender `Niet beschikbaar`, subject
  /// `* Bericht zonder onderwerp *` in Dutch), which a real message can
  /// have too: a draft without a subject shows that subject. What gives it
  /// away is that no message record is behind it: its `<status>` (the read
  /// state, `0` or `1` on every real message, in every box) is empty, and
  /// its `<date>` is not a date (`wrong input format`). Both must hold.
  static bool _isPlaceholderMessage(Map<String, dynamic> xml) {
    final status = xml['status'];
    final date = xml['date'];
    final noStatus =
        status == null || (status is String && status.trim().isEmpty);
    final noDate = date is! String || DateTime.tryParse(date.trim()) == null;
    return noStatus && noDate;
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

  /// Fetches the recipient of a plain reply to [msgId] with their platform
  /// user ID: the sender of the message.
  ///
  /// This method loads the Smartschool reply compose page (`composeType=1`),
  /// the form its Reply button opens, which pre-populates the To field with
  /// the sender of the message, and extracts it via
  /// [parseReplyAllRecipients]. The To list of [getReplyAllRecipients] holds
  /// the sender too, but among the other To recipients, in no fixed place and
  /// with nothing that says which entry it is (#24).
  ///
  /// Returns a record `(to, cc, bcc)` like [getReplyAllRecipients], one list
  /// per field of the page, ready to be passed directly to [sendReply] (or
  /// [sendMessage]): `to` holds the sender, and `cc` and `bcc` are empty.
  ///
  /// The page names the sender whoever it is, the authenticated user
  /// included: for a message in the sent box ([BoxType.sent]) and for a
  /// message the user sent to themselves, `to` holds the user. For a message
  /// in the archive folder, pass [BoxType.inbox] (the default). When
  /// [boxType] holds no message [msgId], Smartschool answers with a page
  /// without a compose form, and all three lists are empty.
  Future<
    (List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)
  >
  getReplyRecipients(int msgId, {BoxType boxType = BoxType.inbox}) async {
    final html = await _client.getRaw(_replyComposeUrl(msgId, boxType));
    return parseReplyAllRecipients(html);
  }

  /// Fetches all reply-all recipients for [msgId] with their platform user IDs.
  ///
  /// The XML `show message` endpoint only returns recipient display names.
  /// This method loads the Smartschool reply-all compose page
  /// (`composeType=2`), which pre-populates every recipient slot with the
  /// resolved `realuserid` and `ssID`, and extracts that data via
  /// [parseReplyAllRecipients].
  ///
  /// Returns a record `(to, cc, bcc)` where each list contains
  /// [MessageSearchUser] instances ready to be passed directly to
  /// [sendReply] with `all: true` (or [sendMessage]), one list per field of
  /// the page (see [parseReplyAllRecipients]).  The sender of the original
  /// message is placed in the `to` list following Smartschool's standard
  /// reply-all logic, among the other To recipients and not marked as the
  /// sender; use [getReplyRecipients] for the sender alone (#24). The
  /// authenticated user is excluded, except as the sender: for a message the
  /// user sent to themselves, the page names the user in To.
  ///
  /// For a message in the sent box, the page also lists the authenticated
  /// user, as the sender, in To, and the message's BCC recipients in BCC,
  /// which are returned in `bcc` (#33); [getSentMessageRecipients] returns
  /// that message's recipients. The reply-all page of a received message is
  /// not expected to name BCC recipients, which its recipients do not see;
  /// `bcc` is then empty.
  Future<
    (List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)
  >
  getReplyAllRecipients(int msgId, {BoxType boxType = BoxType.inbox}) async {
    final html = await _client.getRaw(
      _replyComposeUrl(msgId, boxType, all: true),
    );
    return parseReplyAllRecipients(html);
  }

  /// Parses the reply-all compose page HTML and extracts pre-populated
  /// recipients with their numeric user IDs. The reply compose page
  /// ([getReplyRecipients]) has the same recipient markup.
  ///
  /// Each recipient `<div class="receiverSpan">` carries `realuserid`,
  /// `ssidatt`, `userltatt`, and `typeatt` attributes.  `typeatt` is the
  /// field the recipient is in: the `droppedtype` of the field's container,
  /// which is also the `type` [sendMessage] adds a recipient with
  /// ([RecipientType]). `2` is CC and `3` is BCC; `4` and `5` are the CC and
  /// BCC fields for co-accounts (`1` is their To field), read from the
  /// page's layout (#33). Everything else, and an entry without `typeatt`,
  /// is treated as a To recipient.
  ///
  /// Returns `(toList, ccList, bccList)`.
  static (
    List<MessageSearchUser>,
    List<MessageSearchUser>,
    List<MessageSearchUser>,
  )
  parseReplyAllRecipients(String htmlBody) {
    final to = <MessageSearchUser>[];
    final cc = <MessageSearchUser>[];
    final bcc = <MessageSearchUser>[];

    for (final entry in _formEntries(htmlBody)) {
      switch (entry.field) {
        case RecipientType.to:
          to.add(entry.user);
        case RecipientType.cc:
          cc.add(entry.user);
        case RecipientType.bcc:
          bcc.add(entry.user);
      }
    }

    return (to, cc, bcc);
  }

  /// The recipient entries (`div.receiverSpan`) of the compose form
  /// [htmlBody], in the order of the page, as [parseReplyAllRecipients]
  /// reads them, with the attributes that take an entry off the form (see
  /// [_removeFromForm]).
  static List<_FormEntry> _formEntries(String htmlBody) {
    final doc = html_parser.parse(htmlBody);
    final entries = <_FormEntry>[];

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

      entries.add((
        user: user,
        field: switch (typeStr) {
          '2' || '4' => RecipientType.cc,
          '3' || '5' => RecipientType.bcc,
          _ => RecipientType.to,
        },
        type: typeStr,
        id: span.attributes['idatt'] ?? 'U$userId',
      ));
    }

    return entries;
  }

  /// Returns the original recipients of a sent message identified by [msgId].
  ///
  /// The XML `show message` endpoint does not expose recipient user IDs for
  /// outbox messages.  This method loads the reply-all compose page for the
  /// sent folder (`boxType=outbox&composeType=2`), which pre-populates the
  /// To field with both the original recipients **and** the authenticated user
  /// (as sender).  The authenticated user is identified via the page's
  /// embedded `tinymceInitConfig.userID` value.
  ///
  /// The page lists the authenticated user once, whether or not they were
  /// also a recipient, so this method also fetches the message itself
  /// ([getMessage] with all recipients) and keeps the authenticated user
  /// only where its recipient names include them: a message the user sent
  /// to themselves returns the user (#27). See [parseSentMessageRecipients].
  ///
  /// Returns a record `(to, cc, bcc)` where each list contains
  /// [MessageSearchUser] instances ready to be passed directly to
  /// [sendMessage]: the recipients of the message's To, CC and BCC fields.
  /// A reply-all built from `to` and `cc` does not reveal the BCC
  /// recipients (#33).
  Future<
    (List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)
  >
  getSentMessageRecipients(int msgId) async {
    final html = await _client.getRaw(
      _replyComposeUrl(msgId, BoxType.sent, all: true),
    );
    final message = await getMessage(
      msgId,
      boxType: BoxType.sent,
      includeAllRecipients: true,
    );
    return parseSentMessageRecipients(html, message: message);
  }

  /// Parses the reply-all compose page for a sent message and returns the
  /// original recipients.
  ///
  /// The sent-folder reply-all compose page places the sender (the
  /// authenticated user) alongside the original recipients in the To field;
  /// the original CC and BCC recipients are in the CC and BCC fields.
  /// This method combines [parseComposeCurrentUserIds] to identify the sender
  /// and [parseReplyAllRecipients] to extract all pre-populated recipient
  /// spans, then removes any entry whose `userId` matches the sender.
  ///
  /// The page has a single entry for the sender, in the To field, also when
  /// they were a recipient of the message too (a message sent to
  /// themselves, or with themselves among the recipients, in any field), so
  /// the page alone cannot tell the two apart. Pass the sent [message] (from
  /// [getMessage] with `boxType: BoxType.sent` and
  /// `includeAllRecipients: true`) to keep the sender where its recipients
  /// list them: in the To list when [FullMessage.toRecipients] name them, in
  /// the CC list when [FullMessage.ccRecipients] do, in the BCC list when
  /// [FullMessage.bccRecipients] do. Their [MessageRecipient.name]s are
  /// compared, without the read marker Smartschool puts before each name in
  /// the sent box (#34); a name counts only as far as no other entry of the
  /// page in that field with that name accounts for it. Without [message],
  /// the sender is always removed.
  ///
  /// Returns `(toList, ccList, bccList)`.
  static (
    List<MessageSearchUser>,
    List<MessageSearchUser>,
    List<MessageSearchUser>,
  )
  parseSentMessageRecipients(String htmlBody, {FullMessage? message}) {
    final ids = parseComposeCurrentUserIds(htmlBody);
    final currentUserId = ids?.$1;

    final (to, cc, bcc) = parseReplyAllRecipients(htmlBody);

    if (currentUserId == null) return (to, cc, bcc);

    bool isSender(MessageSearchUser u) => u.userId == currentUserId;
    final sender = [...to, ...cc, ...bcc].where(isSender).firstOrNull;
    final toOthers = to.where((u) => !isSender(u)).toList();
    final ccOthers = cc.where((u) => !isSender(u)).toList();
    final bccOthers = bcc.where((u) => !isSender(u)).toList();

    if (sender != null && message != null) {
      for (final (recipients, others) in [
        (message.toRecipients, toOthers),
        (message.ccRecipients, ccOthers),
        (message.bccRecipients, bccOthers),
      ]) {
        if (_namesSender(sender, recipients, others)) others.add(sender);
      }
    }

    return (toOthers, ccOthers, bccOthers);
  }

  /// Whether [recipients], recipients of a sent message, name [sender] more
  /// often than the entries [others] of the compose page with that name
  /// account for — so that a namesake of the sender among the recipients
  /// does not make the sender a recipient too.
  static bool _namesSender(
    MessageSearchUser sender,
    List<MessageRecipient> recipients,
    List<MessageSearchUser> others,
  ) {
    String normalise(String name) => name.trim().replaceAll(_spaces, ' ');
    final senderName = normalise(sender.displayName);
    final named = recipients
        .where((r) => normalise(r.name) == senderName)
        .length;
    final namesakes = others
        .where((u) => normalise(u.displayName) == senderName)
        .length;
    return named > namesakes;
  }

  static final _spaces = RegExp(r'\s+');

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
  /// A message sent with this method is not linked to another message, also
  /// when it answers one; use [sendReply] to send a reply that Smartschool
  /// links to the message it answers (#26).
  ///
  /// This follows the exact multi-step flow observed in the browser:
  /// 1. Fetch the compose page and extract hidden form tokens
  ///    (`uniqueUsc`, `randomDir`, `encryptedSender`, …).
  /// 2. Register each recipient via `addUserToSelected` for every
  ///    to / cc / bcc slot, and check that Smartschool's answer registers
  ///    it (#39). A recipient listed twice in one field is registered once.
  /// 3. Optionally upload files from [SendMessageParams.attachmentPaths].
  /// 4. Submit the completed form as `multipart/form-data`: the request that
  ///    sends the message.
  ///
  /// Obtain [MessageSearchUser] / [MessageSearchGroup] objects from
  /// [searchRecipientsForCompose], or build them directly when you already
  /// know the recipient's `userId`/`groupId` and `ssId`
  /// (e.g. from [SmartschoolClient.authenticatedUser]).
  ///
  /// Returns normally only when Smartschool confirms that the message was
  /// sent: it answers the submit with HTTP `200` and the page that closes the
  /// compose window (`window.close()`).
  ///
  /// Throws [SmartschoolSendUnconfirmedError] when the message was submitted
  /// but that confirmation did not come: another answer, or the connection
  /// failed or timed out after the submit went out. The message may or may
  /// not have been sent, so do not send it again without checking the sent
  /// box (#25).
  ///
  /// Every other failure means the message was not sent, and calling
  /// [sendMessage] again is safe:
  /// - [SmartschoolComposeError] if the compose form cannot be used, or if
  ///   Smartschool does not register a recipient on it (it answers without
  ///   the recipient, for instance for a wrong `userId` or `ssId`); the
  ///   message names the recipient, and the send stops there, before the
  ///   attachments and the submit (#39);
  /// - [SmartschoolAttachmentUploadError] if an attachment fails to upload;
  /// - [SmartschoolConnectionError] if Smartschool cannot be reached before
  ///   the submit, and the [SmartschoolAuthenticationError] subtypes if a
  ///   login fails;
  /// - [SmartschoolSessionExpiredError] if Smartschool refuses the session
  ///   for a step, the submit included, before handling it. The steps after
  ///   loading the compose form carry its tokens, which belong to the session
  ///   they were issued in, so they are not retried after logging in again
  ///   (see [SmartschoolClient.postMultipartResponse]); a new call loads a
  ///   new compose form, logging in first.
  /// - [SmartschoolSessionExpiredError] too, without sending the step, if
  ///   the client logged in again since it loaded the compose form, or is
  ///   logging in: another request on the same [SmartschoolClient] found the
  ///   session expired, and its login replaced the session. Smartschool
  ///   would accept the steps in the new session, with the tokens of the old
  ///   one, so each step goes out only in the session the form was loaded in,
  ///   and the send stops before the first step that cannot, at the latest
  ///   before the submit (#38). A new call loads a new compose form in the
  ///   new session.
  Future<void> sendMessage(SendMessageParams params) =>
      _send(params, operation: 'sendMessage');

  /// Sends a reply to message [msgId] in [boxType] that Smartschool links to
  /// that message, as its Reply button does; with [all], as its Reply all
  /// button does (#26).
  ///
  /// [sendMessage] submits the new-message form, so a reply sent with it is a
  /// new message, linked to the one it answers by its subject only. This
  /// method loads the reply form of the message instead (`composeType=1`, or
  /// `composeType=2` with [all]), the form that [getReplyRecipients] (or
  /// [getReplyAllRecipients]) reads. Unlike the new-message form, it carries
  /// the ID of the message (`origMsgID`) and `composeAction` `2`, and
  /// Smartschool's web client submits it to the URL it was loaded from; this
  /// method submits it the same way, with the form's own hidden fields.
  /// Everything else works as in [sendMessage]: the recipients are
  /// registered with the form's `uniqueUsc`, the attachments uploaded to its
  /// `randomDir`, and the outcome and each failure mean what they mean
  /// there. In particular, a [SmartschoolSendUnconfirmedError] means that the
  /// reply may have been sent: check the sent box before sending it again;
  /// and when the client logs in again (for another request) after the reply
  /// form was loaded, the send stops with a [SmartschoolSessionExpiredError]
  /// before the submit, and nothing was sent (#38).
  ///
  /// [params] is the whole reply: its [SendMessageParams.subject] (see
  /// [ensureReplySubject]) and [SendMessageParams.bodyHtml] are sent as they
  /// are (the quote of the message that the form starts with is not added),
  /// and it goes to the recipients of [params], in their fields. The reply
  /// form already names recipients, which Smartschool registered with the
  /// form: the sender of the message, or with [all] the recipients that
  /// [getReplyAllRecipients] returns. Start from the lists of
  /// [getReplyRecipients] (or [getReplyAllRecipients] with [all]) and change
  /// them as the reply needs:
  /// - a recipient that the form names and [params] keep in its field is
  ///   not registered again, since the form has it registered already;
  /// - one that [params] leave out of its field is taken off the form
  ///   first, as the × of the recipient in Smartschool's web client does
  ///   (`deleteUsersFromSelected`, #42), so the reply does not go to it;
  /// - one that [params] move to another field is taken off its field and
  ///   registered in the other, as the web client's drag and drop does;
  /// - the other recipients of [params] are registered as [sendMessage]
  ///   registers them.
  ///
  /// Recipients are compared by [MessageSearchUser.userId],
  /// [MessageSearchUser.ssId] and [MessageSearchUser.userLt]. Each of these
  /// steps is checked against Smartschool's answer: when it does not confirm
  /// that it took a recipient off the form, or registered one (#39), the
  /// send stops with a [SmartschoolComposeError] that names the recipient,
  /// before the attachments and the submit, and nothing is sent.
  ///
  /// It throws a [SmartschoolComposeError], and sends nothing, too when
  /// Smartschool does not answer with the reply form of message [msgId], for
  /// instance when [boxType] holds no such message. For a message in the
  /// archive folder, pass [BoxType.inbox] (the default).
  Future<void> sendReply(
    int msgId,
    SendMessageParams params, {
    BoxType boxType = BoxType.inbox,
    bool all = false,
  }) => _send(
    params,
    operation: 'sendReply',
    reply: (msgId: msgId, boxType: boxType, all: all),
  );

  /// Sends [params] as [sendMessage] does, or with [reply] as [sendReply]
  /// does; [operation] names the method in error messages.
  Future<void> _send(
    SendMessageParams params, {
    required String operation,
    _Reply? reply,
  }) async {
    // Everything up to the submit only prepares the compose form: a failure
    // there leaves nothing sent.

    // Step 1: load a fresh compose form (the new-message form, or the reply
    // form) and extract all hidden token fields.
    //
    // Every step after this one carries the form's tokens, which belong to
    // the session the form was loaded in, so each goes out only in that
    // session (`sameSessionAs: form`): when the client logged in again since
    // the form's request went out, for another request, or is logging in,
    // the step is not sent and the send stops there with a
    // SmartschoolSessionExpiredError, before the submit (#38).
    final formUrl = reply == null
        ? _composeUrl()
        : _replyComposeUrl(reply.msgId, reply.boxType, all: reply.all);
    final form = await _client.getResponse(formUrl);
    final html = form.data ?? '';
    final hidden = parseHiddenFields(html);

    if (reply != null && hidden['origMsgID'] != '${reply.msgId}') {
      throw SmartschoolComposeError(
        '$operation: Smartschool did not answer with the reply form of '
        'message ${reply.msgId} (box ${reply.boxType.value}); the box may not '
        'hold that message. Nothing was sent.',
      );
    }

    final uniqueUsc = hidden['uniqueUsc'] ?? '';
    final randomDir = hidden['randomDir'] ?? '';

    if (uniqueUsc.isEmpty) {
      throw SmartschoolComposeError(
        '$operation: could not extract uniqueUsc from the compose form. '
        'Check that the account has permission to send messages.',
      );
    }

    // Step 2: make the form's recipients those of the params. A reply form
    // names recipients, registered with it already; the new-message form
    // names none.
    final onForm = reply == null ? const <_FormEntry>[] : _formEntries(html);
    final fields = [
      (RecipientType.to, params.to),
      (RecipientType.cc, params.cc),
      (RecipientType.bcc, params.bcc),
    ];

    // Step 2a: take each recipient that the form names and the params leave
    // out of its field off the form, as the × of the recipient in the web
    // client does, checked against Smartschool's answer: one that it does
    // not take off stops the send here (#42). A recipient that the params
    // move to another field is taken off here and registered in its new
    // field below, as the web client's drag and drop does.
    if (reply != null) {
      final requested = {
        for (final (type, users) in fields)
          type: users.map(_recipientKey).toSet(),
      };
      final removed = <(String, String, int, int)>{};
      for (final entry in onForm) {
        if (requested[entry.field]!.contains(_recipientKey(entry.user))) {
          continue;
        }
        final user = entry.user;
        if (!removed.add((entry.type, entry.id, user.ssId, user.userLt))) {
          continue;
        }
        await _removeFromForm(entry, reply, uniqueUsc, form, operation);
      }
    }

    // Step 2b: register the other recipients, each checked against
    // Smartschool's answer: a recipient it does not register stops the send
    // here (#39). A recipient is registered once per field: the recipients
    // a reply form names in that field (and the params keep there) are
    // registered with it already, and Smartschool answers a second
    // registration in the same field without the recipient (verified live,
    // #39).
    for (final (type, users) in fields) {
      final registered = {
        for (final entry in onForm)
          if (entry.field == type) _recipientKey(entry.user),
      };
      for (final user in users) {
        if (!registered.add(_recipientKey(user))) continue;
        await _addUserToForm(user, type, uniqueUsc, form, operation);
      }
    }
    for (final (type, groups) in [
      (RecipientType.to, params.toGroups),
      (RecipientType.cc, params.ccGroups),
      (RecipientType.bcc, params.bccGroups),
    ]) {
      final registered = <(int, int)>{};
      for (final group in groups) {
        if (!registered.add((group.groupId, group.ssId))) continue;
        await _addGroupToForm(group, type, uniqueUsc, form, operation);
      }
    }

    // Step 3: upload attachments.
    if (params.attachmentPaths.isNotEmpty && randomDir.isEmpty) {
      throw SmartschoolComposeError(
        '$operation: randomDir is missing from the compose form; '
        'cannot upload attachments.',
      );
    }
    for (final path in params.attachmentPaths) {
      await _uploadAttachment(path, randomDir, form);
    }

    // Step 4: build multipart payload matching the observed browser request.
    // The form is submitted to the URL it was loaded from, whose query the
    // payload repeats; a reply form's origMsgID and composeAction (2) are
    // those of the message it answers.
    final payload = <String, dynamic>{
      'module': 'Messages',
      'file': 'composeMessage',
      'boxType': (reply?.boxType ?? BoxType.inbox).value,
      'composeType': reply == null ? '0' : (reply.all ? '2' : '1'),
      'msgID': reply == null ? 'undefined' : '${reply.msgId}',
      'encryptedSender': hidden['encryptedSender'] ?? '',
      'send': 'send',
      'origMsgID': hidden['origMsgID'] ?? '0',
      'composeAction': hidden['composeAction'] ?? (reply == null ? '0' : '2'),
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

    await _submitComposeForm(
      formUrl,
      payload,
      operation: operation,
      form: form,
    );
  }

  /// What identifies [user] as a recipient of the compose form.
  static (int, int, int) _recipientKey(MessageSearchUser user) =>
      (user.userId, user.ssId, user.userLt);

  /// The name of the compose form field [type] in error messages.
  static String _fieldName(RecipientType type) => switch (type) {
    RecipientType.to => 'To',
    RecipientType.cc => 'CC',
    RecipientType.bcc => 'BCC',
  };

  /// Submits the compose form to [url] with [payload]: the request that
  /// sends the message.
  ///
  /// Returns normally only when Smartschool's answer confirms the send (see
  /// [_confirmsSend]). Any other outcome after the submit went out is a
  /// [SmartschoolSendUnconfirmedError], never retried: the message may have
  /// been sent (#25). A session that Smartschool refuses for the submit is a
  /// [SmartschoolSessionExpiredError]: refused before being handled, the
  /// message was not sent, and the submit is not retried with the compose
  /// state of the refused session. So is a submit that the client does not
  /// send because it logged in again since [form], the compose form, was
  /// loaded (#38). [operation] names the calling method in error messages.
  Future<void> _submitComposeForm(
    String url,
    Map<String, dynamic> payload, {
    required String operation,
    required Response<String> form,
  }) async {
    final Response<String> response;
    try {
      response = await _client.postMultipartResponse(
        url,
        FormData.fromMap(payload),
        retryAfterLogin: false,
        sameSessionAs: form,
      );
    } on SmartschoolSessionExpiredError {
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolSendUnconfirmedError(
          '$operation: the message was submitted, but no answer from '
          'Smartschool came in ($e). It may or may not have been sent: check '
          'the sent box before sending it again.',
          cause: e,
        ),
        stackTrace,
      );
    }

    if (!_confirmsSend(response)) {
      final status = response.statusCode;
      throw SmartschoolSendUnconfirmedError(
        "$operation: the message was submitted, but Smartschool's answer "
        '(HTTP $status) does not confirm that it was sent. It may or may not '
        'have been sent: check the sent box before sending it again. '
        'Answer: ${_answerPreview(response.data ?? '')}',
        statusCode: status,
      );
    }
  }

  /// Whether [response], Smartschool's answer to the compose form's submit,
  /// confirms that the message was sent.
  ///
  /// Smartschool answers a sent message with HTTP `200` and a page whose
  /// script closes the compose window (`checkOpenerActions(); window.close();`
  /// in the recorded answer, `post/composemessage/on_send.html`; the
  /// `window.close()` confirmed live, see #25). The compose form itself does
  /// not close the window. A page that closes it but carries an error marker
  /// (`var error`, `type='error'`, which the library has always read as an
  /// error page) does not count: it could be an error popup that closes
  /// itself.
  static bool _confirmsSend(Response<String> response) {
    if (response.statusCode != HttpStatus.ok) return false;
    final body = response.data ?? '';
    if (_sendErrorMarkers.any(body.contains)) return false;
    return html_parser
        .parse(body)
        .querySelectorAll('script')
        .any((script) => _windowClose.hasMatch(script.text));
  }

  static final _windowClose = RegExp(r'\bwindow\.close\s*\(\s*\)');
  static const _sendErrorMarkers = [
    'var error',
    "type='error'",
    'type="error"',
  ];

  /// The visible text of [html], shortened for an error message.
  static String _answerPreview(String html) {
    final text = (html_parser.parse(html).body?.text ?? html)
        .replaceAll(_spaces, ' ')
        .trim();
    if (text.isEmpty) return '(no text)';
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
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

  /// The URL of the form Smartschool opens to reply to message [msgId] in
  /// [boxType]: its plain reply form (`composeType=1`), or with [all] its
  /// reply-all form (`composeType=2`).
  ///
  /// Unlike the new-message form, both carry the ID of the message in their
  /// hidden `origMsgID` field (and in the unnamed `msgIDVal` input), with
  /// `composeAction` `2` instead of `0`. Their `<form>` has an empty
  /// `action`, so the page submits a reply to this URL (#24), and so does
  /// [sendReply] (#26).
  static String _replyComposeUrl(
    int msgId,
    BoxType boxType, {
    bool all = false,
  }) =>
      _composeUrl(boxType: boxType, composeType: all ? 2 : 1, msgId: '$msgId');

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
  ///
  /// Like every step of [sendMessage] after loading the compose form, [form],
  /// it is not retried after logging in again, and goes out only in the
  /// session [form] was loaded in: `uniqueUsc` belongs to that session (#25,
  /// #38).
  ///
  /// Throws a [SmartschoolComposeError] naming [user] when Smartschool's
  /// answer does not register it (see [_registers]); [operation] names the
  /// calling method in the message.
  Future<void> _addUserToForm(
    MessageSearchUser user,
    RecipientType recipientType,
    String uniqueUsc,
    Response<String> form,
    String operation,
  ) async {
    final answer = await _client.postFormResponse(
      _addToSelectedUrl,
      {
        'id': '${user.userId}',
        'typeId': 'users',
        'type': recipientType.requestType,
        'parentNodeId': recipientType.parentNodeId,
        'ssid': '${user.ssId}',
        'userlt': '${user.userLt}',
        'uniqueUsc': uniqueUsc,
      },
      retryAfterLogin: false,
      sameSessionAs: form,
    );
    if (_registers(answer, 'users', user.userId)) return;
    throw _notRegistered(
      operation,
      '${user.displayName} (user ${user.userId}, '
      '${_fieldName(recipientType)})',
      answer,
    );
  }

  /// Registers a single group recipient on the server-side compose form state
  /// (not retried after logging in again, only in the session of [form], and
  /// checked against Smartschool's answer, see [_addUserToForm]).
  Future<void> _addGroupToForm(
    MessageSearchGroup group,
    RecipientType recipientType,
    String uniqueUsc,
    Response<String> form,
    String operation,
  ) async {
    final answer = await _client.postFormResponse(
      _addToSelectedUrl,
      {
        'id': '${group.groupId}',
        'typeId': 'groups',
        'type': recipientType.requestType,
        'parentNodeId': recipientType.parentNodeId,
        'ssid': '${group.ssId}',
        'userlt': '0',
        'uniqueUsc': uniqueUsc,
      },
      retryAfterLogin: false,
      sameSessionAs: form,
    );
    if (_registers(answer, 'groups', group.groupId)) return;
    throw _notRegistered(
      operation,
      '${group.displayName} (group ${group.groupId}, '
      '${_fieldName(recipientType)})',
      answer,
    );
  }

  static const _addToSelectedUrl =
      '/?module=Messages&file=searchUsers&function=addUserToSelected';

  /// Whether [answer], Smartschool's answer to `addUserToSelected`, registers
  /// the recipient with [typeId] (`users` or `groups`) and [id] (#39).
  ///
  /// Smartschool answers a recipient it registers with HTTP `200` and XML
  /// that describes it, which its compose script turns into the recipient's
  /// entry on the form: `<users><user>` with the `typeId` and the ID
  /// (`realUserId`) that were asked for, also for a group (`userType` `G`,
  /// `userID` `G<id>`). It answers `200` with an empty body for a user it
  /// does not know and for a second registration in the same field, and
  /// `500` with its error page for an unknown `ssid` (all verified live, on
  /// a compose form that was then abandoned). It answers a group ID it does
  /// not know (`0`) as registered, so that is not caught here.
  static bool _registers(Response<String> answer, String typeId, int id) {
    if (answer.statusCode != HttpStatus.ok) return false;
    final List<Map<String, dynamic>> entries;
    try {
      entries = XmlInterface.parseResponse(answer.data ?? '', './/users/user');
    } on FormatException {
      return false;
    }
    return entries.any(
      (entry) =>
          '${entry['typeId']}'.trim() == typeId &&
          '${entry['realUserId']}'.trim() == '$id',
    );
  }

  /// The error for [recipient], a recipient that Smartschool's [answer] to
  /// `addUserToSelected` does not register: the send stops before the
  /// submit (#39).
  static SmartschoolComposeError _notRegistered(
    String operation,
    String recipient,
    Response<String> answer,
  ) {
    return SmartschoolComposeError(
      '$operation: Smartschool did not register the recipient $recipient on '
      'the compose form (${_describeAnswer(answer)}). Check its IDs, and '
      'that the account may send it messages. Nothing was sent.',
    );
  }

  /// [answer]'s HTTP status and a preview of its text, for an error message.
  static String _describeAnswer(Response<String> answer) {
    final body = answer.data ?? '';
    final shown = body.trim().isEmpty ? 'empty' : _answerPreview(body);
    return 'HTTP ${answer.statusCode}, answer: $shown';
  }

  static const _removeFromSelectedUrl =
      '/?module=Messages&file=searchUsers&function=deleteUsersFromSelected';

  /// Takes [entry], a recipient that the reply form [form] of [reply] names,
  /// off the server-side compose form state, as the × of the recipient does
  /// in Smartschool's web client (#42).
  ///
  /// Its compose script (`oSearchUsers.deleteReceiverSpan`) posts the
  /// entry's `typeatt`, `idatt`, `ssidatt` and `userltatt`, as XML, with the
  /// form's [uniqueUsc]. Like every step after loading the form, the request
  /// is not retried after logging in again, and goes out only in the session
  /// [form] was loaded in (#25, #38).
  ///
  /// Throws a [SmartschoolComposeError] naming the recipient when
  /// Smartschool's answer does not confirm that it took the entry off (see
  /// [_removes]); [operation] names the calling method in the message.
  Future<void> _removeFromForm(
    _FormEntry entry,
    _Reply reply,
    String uniqueUsc,
    Response<String> form,
    String operation,
  ) async {
    final user = entry.user;
    final answer = await _client.postFormResponse(
      _removeFromSelectedUrl,
      {
        'xml':
            '<users><user>'
            '<type>${entry.type}</type>'
            '<userid>${entry.id}</userid>'
            '<ssid>${user.ssId}</ssid>'
            '<userlt>${user.userLt}</userlt>'
            '</user></users>',
        'uniqueUsc': uniqueUsc,
      },
      retryAfterLogin: false,
      sameSessionAs: form,
    );
    if (_removes(answer, entry)) return;
    final formName = reply.all ? 'reply-all form' : 'reply form';
    throw SmartschoolComposeError(
      '$operation: Smartschool did not take the recipient '
      '${user.displayName} (user ${user.userId}, ${_fieldName(entry.field)}), '
      'which the params leave out of that field, off the $formName of '
      'message ${reply.msgId} (${_describeAnswer(answer)}). Nothing was '
      'sent.',
    );
  }

  /// Whether [answer], Smartschool's answer to `deleteUsersFromSelected`,
  /// confirms that it took [entry] off the compose form (#42).
  ///
  /// Smartschool answers with HTTP `200` and XML that lists the entries it
  /// took off, each with the `type`, `ssID`, `userID` (the `idatt`) and
  /// `userLT` that were asked for, from which its compose script builds the
  /// ID of the entry to remove from the page. It answers `200` with an empty
  /// list (`<users />`) for an entry that the form does not have: one taken
  /// off already, one asked for in another field, or with the user ID
  /// without its `U` prefix (all verified live, on a reply form that was
  /// then abandoned).
  static bool _removes(Response<String> answer, _FormEntry entry) {
    if (answer.statusCode != HttpStatus.ok) return false;
    final List<Map<String, dynamic>> removed;
    try {
      removed = XmlInterface.parseResponse(answer.data ?? '', './/users/user');
    } on FormatException {
      return false;
    }
    String text(Map<String, dynamic> xml, String key) => '${xml[key]}'.trim();
    return removed.any(
      (xml) =>
          text(xml, 'type') == entry.type &&
          text(xml, 'userID') == entry.id &&
          text(xml, 'ssID') == '${entry.user.ssId}' &&
          text(xml, 'userLT') == '${entry.user.userLt}',
    );
  }

  /// Uploads a single attachment file to `/Upload/Upload/Index`.
  ///
  /// [uploadDir] should be the `randomDir` token from the compose form,
  /// [form]. It belongs to the session the form was loaded in, so the upload
  /// is not retried after logging in again (#25), and goes out only in that
  /// session (#38).
  Future<void> _uploadAttachment(
    String filePath,
    String uploadDir,
    Response<String> form,
  ) async {
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
      retryAfterLogin: false,
      sameSessionAs: form,
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
