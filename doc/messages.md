# Messages

The reference of `MessagesService`, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps its overview, with a short example: [`MessagesService`](../README.md#messagesservice).

## `MessagesService`

### Reading

| Method | Returns | Description |
|---|---|---|
| `getHeaders({boxType, boxId, sortBy, sortOrder, alreadySeenIds})` | `List<ShortMessage>` | List message headers for any box: one page, at most the first 50 (the newest 50 by default). Pass `alreadySeenIds` for lightweight polling. Never waits, but makes a paging of the box on the same client fail at its next page (see below). |
| `getArchiveHeaders({boxId, sortBy, sortOrder, alreadySeenIds})` | `List<ShortMessage>` | Convenience wrapper for the archive folder — resolves the box ID automatically. One page, like `getHeaders`. |
| `getHeaderPages({boxType, boxId, sortBy, sortOrder})` | `Stream<List<ShortMessage>>` | All headers of a box, page by page (about 50 each), as Smartschool's web client loads them while scrolling. The first page is what `getHeaders` returns; each next page is requested only when the listener wants it, so `take`/`takeWhile` or cancelling stops the paging. Ends after the last page. Fails with `SmartschoolPagingRestartedError` when Smartschool restarts the paging because the box was listed again (see below). |
| `getArchiveHeaderPages({boxId, sortBy, sortOrder})` | `Stream<List<ShortMessage>>` | `getHeaderPages` for the archive folder. |
| `getAllHeaders({boxType, boxId, sortBy, sortOrder, limit})` | `Future<List<ShortMessage>>` | Collects `getHeaderPages`: every header of the box, or the first `limit`. Each page is a request. On one client, the `getAllHeaders` and `getAllArchiveHeaders` calls of a box run one at a time. Fails with `SmartschoolPagingRestartedError` rather than return part of the box when the paging is restarted. |
| `getAllArchiveHeaders({boxId, sortBy, sortOrder, limit})` | `Future<List<ShortMessage>>` | `getAllHeaders` for the archive folder. |
| `getArchiveBoxId()` | `Future<int>` | Returns the archive folder's numeric box ID: the archive (`isArchive`) among the folders of `getFolders()`, one request of about 2 KB (#141); when the tree cannot be read or names none, the one Smartschool's Messages page names (about 95 KB, as before #141); else `208`. Cached per service, the fallback too. |
| `getFolders()` | `Future<List<MessageFolder>>` | The account's own message folders (#136): the archive and the folders the user made ("Map toevoegen") in the inbox and the sent box, also those in another folder, as a tree (`children`); `MessageFolder.flatten` lists them all, each with its `path`. The boxes themselves are not in it (they are a `BoxType`). List a folder's messages with `getHeaders` / `getHeaderPages` / `getAllHeaders(boxType: folder.boxType, boxId: folder.id)`. Read again at every call. See *Folders* below. |
| `getMessage(msgId, {boxType, includeAllRecipients})` | `Future<FullMessage?>` | Fetches the full HTML body, receiver lists, and metadata for a message. Pass `includeAllRecipients: true` to receive every recipient name in `receivers`/`ccReceivers`/`bccReceivers`; the default truncates the list and exposes the hidden count via `totalNrOther*` fields instead. For a message in the sent box, `toRecipients`/`ccRecipients`/`bccRecipients` also say whether each recipient has read it. Returns `null` when `boxType` holds no message `msgId` (an unknown ID, or one in another box). It names no folder: it finds a message in the archive with `BoxType.inbox`. It returns `null` for a message moved to the trash, in the box it left, and the message with `BoxType.trash` (seen live, #96). |
| `getReplyRecipients(msgId, {boxType})` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns the recipient of a plain reply, the sender of the message, with their numeric user ID by parsing Smartschool's reply compose page (`composeType=1`), as `(to, cc, bcc)`: the sender in `to`, `cc` and `bcc` empty. Pass the lists to `sendReply` to send the reply; the To list of `getReplyAllRecipients` holds the sender too, but among the other recipients, unmarked. For a message in the sent box, or one you sent to yourself, the sender is you. |
| `getReplyAllRecipients(msgId, {boxType})` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns all To, CC and BCC recipients with their numeric user IDs by parsing the reply-all compose page, as `(to, cc, bcc)`. Pass the lists to `sendReply(…, all: true)` to send the reply to all. The page of a received message is not expected to name BCC recipients. |
| `getSentMessageRecipients(msgId)` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns the original recipients of a **sent** message with their numeric user IDs. The outbox reply-all compose page includes the authenticated user (sender) alongside the recipients, once, whether or not they were a recipient too; this method also fetches the message (`getMessage` with all recipients) and keeps the authenticated user only where its recipient names include them, so a message sent to yourself returns you. Returns `(to, cc, bcc)`: the BCC recipients are in `bcc`, so a reply-all built from `to` and `cc` does not reveal them (#33). Use this instead of `getReplyAllRecipients` for messages in `BoxType.sent`. |
| `getAttachments(msgId, {boxType})` | `Future<List<MessageAttachment>>` | Returns the attachment list for a message. |

Smartschool keeps the paging position per user and box, not in the session (#76): every listing of the box restarts it, in any session of the account, and every next page moves it on, whichever paging asked for it. So a paging only gets its next page when no other listing of the box reached Smartschool in between. When one may have, `getHeaderPages` fails with `SmartschoolPagingRestartedError` after the pages it emitted, and `getAllHeaders` fails with it rather than return part of the box. The pages emitted are correct, but not the whole box: list it again then.

On one client (on any `MessagesService` of it), the library sees the listings of a box coming (#80):
- `getAllHeaders` and `getAllArchiveHeaders` of a box run one at a time: one waits for the calls of that box that started before it, so two calls at the same time both get the whole box. `getHeaderPages` and `getArchiveHeaderPages` wait for them too before they start.
- A paging of a box started after a `getHeaderPages` of that box waits only for its first page, not for its end: the stream's listener decides when, and whether, it goes on, so waiting for it could hang (a listener that waits for the other paging, or stops without cancelling). The later paging goes ahead, and the stream fails at its next page.
- `getHeaders` of the box (also in poll mode, as `refreshHeadersIncremental` sends it) never waits, and makes a paging of the box that runs fail at its next page.

Such a paging fails before it asks Smartschool for the next page; when the other listing went out while that page was being asked for, it fails without emitting the page. A paging also waits for the requests of the box that are on their way before it sends its first one.

A listing of the box elsewhere (by another client or app, or the user opening the box in Smartschool's web client) cannot be seen coming, but its effect can: the next page of a paging that was running is the second page again. `getHeaderPages` recognises it, a page whose headers were all emitted already, and fails with the same error. A new login between two pages does not restart the paging: Smartschool goes on with the next page in the new session.

Two pagings of the same box at the same time in different clients or apps can still skip each other's pages: once both have listed the box, each next page moves the position on for both, so one paging can skip the pages the other one got, without an error. Do not page a box in two places at once. Paging different boxes at once is fine.

```dart
// Every message of the sent box, 50 per request; once more when the box
// was listed again halfway.
List<ShortMessage> sent;
try {
	sent = await messages.getAllHeaders(boxType: BoxType.sent);
} on SmartschoolPagingRestartedError {
	sent = await messages.getAllHeaders(boxType: BoxType.sent);
}

// Inbox headers of the last 30 days: stops requesting pages once past them.
final since = DateTime.now().subtract(const Duration(days: 30));
final recent = await messages
	.getHeaderPages()
	.expand((page) => page)
	.takeWhile((header) => header.date.isAfter(since))
	.toList();
```

Attachment bytes can be downloaded from each `MessageAttachment`:

```dart
final attachments = await messages.getAttachments(messageId);
for (final attachment in attachments) {
	final bytes = await attachment.download(client);
	print('${attachment.name}: ${bytes.length} bytes');
}
```

#### Folders

`getFolders()` lists the folders of the account's boxes (#136), as the folder tree of Smartschool's "move messages" dialog has them (`quickactions` / `requestmovelist`, which only reads): the archive of the inbox (`isArchive`) and the folders the user made in the inbox and the sent box, each with the folders in it as its `children`. A folder is a box ID of its box: list it with its `boxType` and its `id` as the `boxId`, as the archive is listed. Each folder keeps a paging position of its own: seen live, listing a folder of the inbox between two pages of the archive did not restart the archive's paging. `getArchiveBoxId()` takes the archive from this tree too (#141), once per service.

```dart
for (final folder in MessageFolder.flatten(await messages.getFolders())) {
	final headers = await messages.getAllHeaders(
		boxType: folder.boxType,
		boxId: folder.id,
	);
	print('${folder.boxType.name}: ${folder.path.join(' / ')} '
		'(${headers.length} messages${folder.isArchive ? ', archive' : ''})');
}
```

`getMessage(id, boxType: folder.boxType)` reads a message in a folder (its request names no folder), and so do `markRead` and `setLabel`; `markUnread` and `moveToTrashFrom` also take the folder's `id` as their `boxId`. Tried live: the tree, a folder of the inbox listed and a message read in it; folders of the sent box and folders in a folder were not seen live (the web client's code offers both).

### Mutating

| Method | Returns | Description |
|---|---|---|
| `markRead(msgId, {boxType})` | `Future<MessageChanged?>` | Marks a message as read. `getMessage` does not flip the read state; call this after (or alongside) `getMessage` when you want the server to record the message as opened. Idempotent — safe to call on an already-read message. Names no folder, as the web client's request does, also for a message in the archive: tried live there (2026-10-03, #94), the archive then listed it as read. `null` when the answer gives no message ID or read state (#95). |
| `markUnread(msgId, {boxType, boxId})` | `Future<MessageChanged?>` | Marks a message as unread. For a message in a folder, such as the archive, pass the folder's `boxId` (`getArchiveBoxId()`), as the web client does: tried live in the archive (2026-10-03, #94). `null` when the answer gives no message ID or read state (#95), so a `newValue` of `0` is an "unread" Smartschool confirmed. |
| `setLabel(msgId, label, {boxType})` | `Future<MessageChanged?>` | Applies a colour flag (`MessageLabel`). Use `noFlag` to clear. Names no folder, as the web client's requests do, also for a message in the archive: tried live there (2026-10-03, #94), the archive then listed the flag set and cleared. `newValue` is the answer's `<label>`; `null` when the answer gives no message ID or label (#95), so a `newValue` of `0` is a "no flag" Smartschool confirmed. |
| `moveToTrash(msgId)` | `Future<MessageDeletionStatus?>` | Moves a message to the trash, or deletes it for good: prefer `moveToTrashFrom`. It sends Smartschool's `quick delete`, which names the ID only, not the box: Smartschool acts on whichever copy of the ID its own session state points to. That can be a copy in the trash, which a `quick delete` deletes for good, so this is never a guaranteed no-op, not even for an ID that names no message such as `0` (#61). For a message you sent to yourself (the same ID in the inbox and the sent box) it moved the inbox copy; `moveToTrashFrom` moves the sent-box copy. `null` when Smartschool does not confirm it, as when it deleted nothing (it then answered with an empty body). |
| `moveToTrashFrom(msgId, {boxType, boxId})` | `Future<bool?>` | Moves the copy of a message in `boxType`, `BoxType.inbox` or `BoxType.sent`, to the trash, and leaves its other copy where it is, as dragging it onto the trash in Smartschool's web client does. A move, not a deletion: safe while another copy of the ID is in the trash. Smartschool's answer says nothing about the move, so it checks the move with a `show message` in `boxType` (as `getMessage` does, #96): `true` when the box (none of its folders) no longer holds the message, also for an ID it never held; `false` when it still does; `null` when the answer says neither. Seen live: `true` for each move out of the inbox, the sent box and the archive, as the box listings showed. Pass `boxId` for a folder of the box, such as the archive: tried live (#64), it took an archived message out of the archive, and the trash then listed it. Another `boxType` throws an `ArgumentError`. When the check fails after the move went out (Smartschool refuses the session for it also after logging in again, answers it with something that is not XML, or the connection fails), it throws a `SmartschoolMoveUncheckedError` with the check's error as its `cause` (#115): the move may have been made, so check with `getMessage` before moving it again. A `SmartschoolSessionExpiredError` is the move's own: it was not carried out. |
| `moveToArchive(msgIds)` | `Future<List<MessageChanged>>` | Archives one or more messages (REST endpoint). |

### Composing & searching

| Method | Returns | Description |
|---|---|---|
| `getCurrentUserAsRecipient()` | `Future<MessageSearchUser>` | Returns the currently-logged-in user as a compose recipient (reads IDs from compose page JS — safe and reliable). |
| `searchRecipients(query)` | `Future<List<MessageSearchResult>>` | JSON-based recipient search; results lack `ssId` — use `searchRecipientsForCompose` when sending. |
| `searchRecipientsForCompose(query)` | `Future<(List<MessageSearchUser>, List<MessageSearchGroup>)>` | Compose-form XML search; results carry `ssId`/`userLt` required by `sendMessage`. Loads a compose form for its `uniqueUsc` and searches only in that form's session (#97): when Smartschool refuses that session for the search, or the client logged in again meanwhile (for another request), it loads a new form and searches once more; it throws a `SmartschoolSessionExpiredError` when that search cannot go out in its form's session either. An answer to the search that is not XML throws as for `postXml` (#112): a `SmartschoolUnexpectedPageError` (action `searchUsers`) for an HTML page or a piece of one, a `SmartschoolParsingError` for anything else, malformed XML and an empty answer with another status than `200` included (an empty `200` finds no one); it loads no new form for those. To look up several names, use `searchRecipientsForComposeAll`. |
| `searchRecipientsForComposeAll(queries)` | `Future<Map<String, (List<MessageSearchUser>, List<MessageSearchGroup>)>>` | The search of `searchRecipientsForCompose` for each of several queries, on one compose form (#107): one form and one search per query, where a call per query loads a form each. Returns the results by query, in the order of `queries`; a query given twice is searched once, and no queries send no request. Each search goes out only in the session of its form: when one cannot, it loads a new form once and goes on from that query on it, keeping the results it has; it throws a `SmartschoolSessionExpiredError` when a search on that form cannot go out in its session either. An answer to a search that is not XML throws as for `searchRecipientsForCompose` (#112). |
| `sendMessage(params)` | `Future<void>` | Sends `params` (a `SendMessageParams`, see below) as a new message. Full multi-step send: loads compose form, registers recipients (checking that Smartschool registers each), uploads attachments, submits. Returns normally only when Smartschool confirms the send; see below for what a failure means. |
| `sendReply(msgId, params, {boxType, all})` | `Future<void>` | Sends `params` (a `SendMessageParams`) as a reply that Smartschool links to message `msgId`: the same steps as `sendMessage`, on the message's reply form (`composeType=1`, or the reply-all form with `all: true`), submitted with its `origMsgID` and `composeAction`. The reply goes to the recipients of `params`: those the form names and `params` keep are not registered again, those `params` leave out are taken off the form first; see below. |

`sendMessage` and `sendReply` take the message as a `SendMessageParams`:

| Field | Type | Default | Description |
|---|---|---|---|
| `to` | `List<MessageSearchUser>` | required | To recipients. |
| `cc`, `bcc` | `List<MessageSearchUser>` | `[]` | CC and BCC recipients. |
| `toGroups`, `ccGroups`, `bccGroups` | `List<MessageSearchGroup>` | `[]` | Groups as To, CC and BCC recipients. |
| `subject` | `String` | required | The subject. |
| `bodyHtml` | `String` | required | The body, as HTML. |
| `attachmentPaths` | `List<String>` | `[]` | Paths of local files to attach; each is uploaded before the submit. |
| `options` | `MessageSendOptions` | `MessageSendOptions()` | The compose form's own options (see below). The default sends the message as the compose form does by default: not stored in the LVS, sent now. |

`MessageSendOptions` holds the options of Smartschool's compose form (#47), each submitted in its own field of the form:

| Field | Type | Default | Description |
|---|---|---|---|
| `lvsCopy` | `LvsCopy` | `LvsCopy.none` | Whether Smartschool stores the message in the LVS: the form's `copyToLVS` select. `none` (`dontCopyToLVS`, the option the form selects), `store` (`copyToLVS`, "Bericht bewaren in het LVS") or `storeConfidential` (`copyToLVSAndMarkAsPrivate`, "… en markeren als vertrouwelijk"). An option other than `none` is sent only when the loaded form offers it: Smartschool leaves the select out for an account that may not store messages in the LVS, and the send then throws a `SmartschoolComposeError` before registering any recipient (nothing was sent). |
| `sendAt` | `DateTime?` | `null` (send now) | A delayed send, as the "Uitgesteld versturen" dialog of Smartschool's web client schedules it: Smartschool sends the message at that time, and until then the web client counts it in the scheduled box (`BoxType.scheduled`). It must be after now and at most a year ahead (until the end of the same day next year, the last day the dialog offers), or the send throws an `ArgumentError` before any request. It goes in the form's `sendDate` field as the dialog writes it: ISO 8601 in the local time of the machine, to the second, with its UTC offset (`2026-10-02T07:30:00+02:00`, or `…Z` on a machine that runs on UTC); the instant is the same whatever the time zone of the `DateTime`. When the loaded form offers no delayed send (scheduled messages not enabled for the account), the send throws a `SmartschoolComposeError` before registering any recipient. |
| `requestReadReceipt`, `highPriority`, `extra` | `bool`, `bool`, `Map<String, dynamic>?` | `false`, `false`, `null` | Deprecated: Smartschool's compose form has no read receipt or priority, and the submit already holds every field of the form, so none of them can be sent. A send that sets one (`true`, or a non-empty `extra`) throws an `ArgumentError` before any request, and sends nothing, instead of sending the message without it (#43). |

Not verified with a real send (the library's tests never send one): Smartschool's answer to the submit of a scheduled message, which `sendMessage` and `sendReply` take as a sent one only when it is the answer to a sent message (another answer is a `SmartschoolSendUnconfirmedError`, which for a delayed send says to check the scheduled box); whether Smartschool reads the offset of a time outside Belgium's time zone (a browser in Belgium always sends `+01:00` or `+02:00`); and what Smartschool does with an LVS copy, for instance of a message to recipients who are not pupils.

```dart
await messages.sendMessage(
  SendMessageParams(
    to: [pupil],
    subject: 'Remediëring',
    bodyHtml: '<p>Tot maandag.</p>',
    options: MessageSendOptions(
      lvsCopy: LvsCopy.store,
      sendAt: DateTime(2026, 10, 5, 7, 30), // Monday morning, local time
    ),
  ),
);
```

Get the recipients from `searchRecipientsForCompose`, `getCurrentUserAsRecipient`, or for a reply from `getReplyRecipients` / `getReplyAllRecipients`:

```dart
final (users, _) = await messages.searchRecipientsForCompose('Janssens');
final myself = await messages.getCurrentUserAsRecipient();
final params = SendMessageParams(
  to: [users.first],
  bcc: [myself],
  subject: 'Report',
  bodyHtml: '<p>See the attachment.</p>',
  attachmentPaths: ['report.pdf'],
);
await messages.sendMessage(params);
```

`sendMessage` returns normally only when Smartschool answers the submit as it does for a sent message: HTTP `200` with the page that closes the compose window (`window.close()`). A `SmartschoolSendUnconfirmedError` means the message was submitted, but that confirmation did not come (another answer, or the connection failed or timed out after the submit went out): the message may or may not have been sent, so check the sent box (for a delayed send, the scheduled box) before sending it again. Every other failure means nothing was sent, and calling `sendMessage` again is safe:

```dart
try {
  await messages.sendMessage(params);
} on SmartschoolSendUnconfirmedError {
  // Submitted, not confirmed: it may have been sent. Check the sent box
  // before sending it again.
} on SmartschoolException {
  // Not sent: the compose form, a recipient, an attachment, the network or
  // the session failed before the message was sent. Safe to try again.
}
```

The steps after loading the compose form carry its tokens, which belong to the session it was loaded in, so they are not retried after logging in again: when Smartschool refuses the session for one of them (the submit included), `sendMessage` throws `SmartschoolSessionExpiredError` and nothing was sent. Calling it again loads a new compose form, logging in first.

Those steps go out only in the session the compose form was loaded in. When another request on the same client finds the session expired and logs in while `sendMessage` runs, the login replaces the session, and Smartschool would accept the remaining steps in the new session with the tokens of the old one: `sendMessage` then stops before the next step, at the latest before the submit, with `SmartschoolSessionExpiredError`. Nothing was sent, and calling it again loads a new compose form in the new session.

A message sent with `sendMessage` is a new message, also when it answers another one. `sendReply` sends a reply that Smartschool links to the message it answers, as its Reply (and Reply all) button does: it loads the message's reply form instead of the new-message form. That form already names the recipients of the reply (the sender, or with `all: true` everyone `getReplyAllRecipients` returns), and the reply goes to the recipients of `params`, in their fields: start from the lists of `getReplyRecipients` (or `getReplyAllRecipients`) and add, leave out or move recipients as needed. A recipient that the form names and `params` keep in its field is not registered a second time; one that `params` leave out of its field is taken off the form first, as the × of the recipient in Smartschool's web client does (`deleteUsersFromSelected`); one moved to another field is taken off its field and registered in the other, as the web client's drag and drop does. When Smartschool's answer does not confirm that it took a recipient off (or registered one), `sendReply` throws `SmartschoolComposeError` naming the recipient, before the submit, and sends nothing. The subject and body are sent as given (the form's quote of the message is not added). Outcomes and failures are those of `sendMessage` above.

```dart
final (to, cc, bcc) = await messages.getReplyRecipients(original.id);
await messages.sendReply(
  original.id,
  SendMessageParams(
    to: to,
    cc: cc,
    bcc: bcc,
    subject: MessagesService.ensureReplySubject(original.subject),
    bodyHtml: '<p>Thanks!</p>',
  ),
);

// Reply to all, without one of the recipients (`someone`):
final (allTo, allCc, allBcc) =
    await messages.getReplyAllRecipients(original.id);
await messages.sendReply(
  original.id,
  SendMessageParams(
    to: allTo.where((u) => u.userId != someone.userId).toList(),
    cc: allCc.where((u) => u.userId != someone.userId).toList(),
    bcc: allBcc,
    subject: MessagesService.ensureReplySubject(original.subject),
    bodyHtml: '<p>Thanks, all!</p>',
  ),
  all: true,
);
```

### Thread subject helpers

| Method | Returns | Description |
|---|---|---|
| `threadSubjectKey(subject)` | `String` | Normalises a subject for thread grouping by removing leading reply/forward prefixes (`Re:`, `Fwd:`, `FW:`, `AW:`, `WG:`). |
| `ensureReplySubject(subject, {replyPrefix})` | `String` | Produces a reply subject with exactly one prefix (default `Re:`), avoiding `Re: Re: ...`. |

### Event-driven message detection

`MessagesService` can react to external notification signals (e.g. a WebSocket push or a polling bridge) and trigger a debounced incremental inbox refresh automatically.

```dart
final messages = MessagesService(client);

// 1. Seed the seen-ID baseline so only genuinely new messages trigger events.
final initial = await messages.getHeaders();
messages.seedIncrementalSeenIds(initial.map((m) => m.id));

// 2. Bind MessagesService to the client's notification stream.
//    The subscription is cancelled automatically by dispose().
messages.bindNotificationCounterStream(client.notificationCounterUpdates);

// 3. React to new messages detected by the debounced refresh.
messages.messageCounterUpdates.listen((update) async {
  final newHeaders = await messages.refreshHeadersOnMessageCounter(update);
  for (final msg in newHeaders) {
    final full = await messages.getMessage(msg.id);
    print('[${msg.date}] ${msg.sender}: ${msg.subject}');
    print(full?.body);
  }
});

// 4. Fire a notification — normally this comes from a WebSocket, but you can
//    emit one manually or from a polling bridge.
client.emitNotificationCounterUpdate(
  moduleName: 'Messages',
  counter: 3,
  isNew: true,
  source: 'websocket',
);

// 5. Clean up when done.
await messages.dispose();
await client.dispose();
```

#### Event-driven API

| Method / getter | Returns | Description |
|---|---|---|
| `messageCounterUpdates` | `Stream<MessageCounterUpdate>` | Broadcast stream emitting one event per debounce window when the counter rises. |
| `handleNotificationCounterUpdate(update)` | `bool` | Processes a `NotificationCounterUpdate` for the `Messages` module; deduplicates identical consecutive counter values; returns `true` if a new `MessageCounterUpdate` was emitted. |
| `bindNotificationCounterStream(stream)` | `StreamSubscription` | Subscribes to any `Stream<NotificationCounterUpdate>` and pipes `Messages` events through `handleNotificationCounterUpdate`. |
| `seedIncrementalSeenIds(ids, {boxType, boxId, sortBy, sortOrder})` | `void` | Populates the per-mailbox seen-ID baseline so the first real refresh only surfaces messages newer than the seed. |
| `refreshHeadersIncremental({boxType, boxId, sortBy, sortOrder, debounceWindow})` | `Future<List<ShortMessage>>` | Debounced incremental fetch — concurrent calls within the window share the same in-flight request. |
| `refreshHeadersOnMessageCounter(update, {boxType, boxId, sortBy, sortOrder, debounceWindow})` | `Future<List<ShortMessage>>` | Convenience wrapper: calls `refreshHeadersIncremental` using context from a `MessageCounterUpdate`. |
| `dispose()` | `Future<void>` | Cancels debounce timers, closes the message counter stream, and cancels any bound notification subscription. |

#### Polling bridge pattern

If no WebSocket is available, use the existing `alreadySeenIds` polling parameter as a bridge:

```dart
final seen = <int>{};
Timer.periodic(Duration(seconds: 30), (_) async {
  final newHeaders = await messages.getHeaders(alreadySeenIds: seen.toList());
  if (newHeaders.isNotEmpty) {
    seen.addAll(newHeaders.map((m) => m.id));
    client.emitNotificationCounterUpdate(
      moduleName: 'Messages',
      counter: seen.length,
      isNew: true,
      source: 'poll',
    );
  }
});
```

See [example/notification_listener_full_message_example.dart](../example/notification_listener_full_message_example.dart) for a complete runnable demo.
See [example/message_change_stream_example.dart](../example/message_change_stream_example.dart) for a stream-binding walkthrough with synthetic events.

### Static parsers (exposed for testing)

| Method | Description |
|---|---|
| `parseHiddenFields(htmlBody)` | Extracts all `<input type="hidden">` name→value pairs from an HTML page. |
| `parseComposeCurrentUserIds(htmlBody)` | Extracts `(userId, ssId, userLt)` from the `window.tinymceInitConfig` block. |
| `parseArchiveBoxIdFromMessagesHtml(htmlBody)` | Extracts the archive folder box ID from the Messages module HTML (what `getArchiveBoxId` reads when the folder tree names no archive, #141). |
| `parseFolders(json)` | Reads the folder tree of a `requestmovelist` answer (its JSON data) into the `MessageFolder`s of `getFolders` (#136). Throws a `SmartschoolParsingError` for a tree it cannot read. |
| `parseReplyAllRecipients(htmlBody)` | Extracts To, CC and BCC recipients with numeric IDs from a reply-all or reply compose page (parses `div.receiverSpan` elements; their `typeatt` is the field: `0`/`1` To, `2`/`4` CC, `3`/`5` BCC, the second of each for co-accounts). Returns `(toList, ccList, bccList)`. |
| `parseSentMessageRecipients(htmlBody, {message})` | Like `parseReplyAllRecipients` but for the sent-folder compose page: additionally extracts the authenticated user's ID and removes them from the result, unless the sent `message` (a `FullMessage`) names them among its recipients (in the field that names them). Returns `(toList, ccList, bccList)`. |
