# flutter_smartschool

An unofficial Dart client library for the [Smartschool](https://www.smartschool.be) school platform. It handles authentication (including TOTP 2FA and birthday-based account verification), cookie persistence, and the mix of XML-protocol and JSON/REST endpoints that Smartschool uses internally.

Repository: [yvanvds/dartschool](https://github.com/yvanvds/dartschool)

> **Unofficial.** This library reverse-engineers the private Smartschool web API. It is not endorsed by or affiliated with Smartschool. Use responsibly.

[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=bugs)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Coverage](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=coverage)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool)

## Features

- Authenticated Smartschool client with cookie persistence and MFA/account-verification support.
- Full messaging workflow (`MessagesService`): list, read, attachments, recipient search, send, archive, trash, labels, reply-all recipient resolution.
- **Event-driven message detection**: notification counter stream with debounced incremental inbox refresh; wires into any notification source (polling bridge or WebSocket).
- Intradesk read support (`IntradeskService`): root/folder listing and file download.
- Interactive terminal browser for Intradesk: [example/intradesk_browser.dart](example/intradesk_browser.dart).
- Presence write support (`PresenceService`): mark a pupil **Te laat** / **Te laat zonder geldige reden** for a half-day via Smartschool's internal Presence module (requires Presence-handling access).

---

## Installation

Add the package to `pubspec.yaml`:

```yaml
dependencies:
	flutter_smartschool: ^0.2.7
```

or directly from GitHub (`dartschool`) while iterating:

```yaml
dependencies:
	flutter_smartschool:
		git:
			url: https://github.com/yvanvds/dartschool.git
```

---

## Quick start

```dart
import 'package:flutter_smartschool/flutter_smartschool.dart';

Future<void> main() async {
	// 1. Provide credentials — pick one of the three credential classes.
	final creds = PathCredentials(); // reads credentials.yml from disk

	// 2. Create an authenticated client.
	final client = await SmartschoolClient.create(creds);
	await client.ensureAuthenticated();

	// 3. Use a service.
	final messages = MessagesService(client);

	// List the 20 most-recent inbox headers.
	final headers = await messages.getHeaders();
	for (final msg in headers) {
		print('${msg.date}  ${msg.sender}: ${msg.subject}');
	}

	// Fetch the full body and attachment list of the first message.
	final full = await messages.getMessage(headers.first.id);
	print(full?.body);

	final attachments = await messages.getAttachments(headers.first.id);
	for (final a in attachments) {
		print('  📎 ${a.name} (${a.size})');
		final bytes = await a.download(client);
		print('     downloaded ${bytes.length} bytes');
	}

	// Send a message to yourself.
	final myself = await messages.getCurrentUserAsRecipient();
	await messages.sendMessage(
		to: [myself],
		subject: 'Hello from flutter_smartschool',
		bodyHtml: '<p>It works!</p>',
	);
}
```

See [example/send_message_lifecycle_example.dart](example/send_message_lifecycle_example.dart) for a complete send → inbox poll → archive → trash flow.

See [example/mark_read_toggle_example.dart](example/mark_read_toggle_example.dart) for toggling the read/unread status of a message.

See [example/reply_all_recipients_example.dart](example/reply_all_recipients_example.dart) to scan the inbox for messages with multiple recipients and resolve their user IDs via `getReplyAllRecipients`.

See [example/get_recipients_from_sent_messages.dart](example/get_recipients_from_sent_messages.dart) to resolve the original recipient IDs for sent messages via `getSentMessageRecipients`.

For thread grouping on real inbox headers, see [example/message_threading_headers_example.dart](example/message_threading_headers_example.dart).

For Intradesk navigation and file downloads, see [example/intradesk_browser.dart](example/intradesk_browser.dart) (interactive text UI).

---

## Credentials

Three credential classes are provided, all extending the abstract `Credentials` base.

| Class | Source |
|---|---|
| `AppCredentials` | Inline constructor arguments |
| `EnvCredentials` | Environment variables (`SMARTSCHOOL_USERNAME`, `SMARTSCHOOL_PASSWORD`, `SMARTSCHOOL_MAIN_URL`, `SMARTSCHOOL_MFA`) |
| `PathCredentials` | `credentials.yml` file — searched from cwd upwards, then `~/.cache/smartschool/` |

`credentials.yml` format:
```yaml
username: john.doe
password: s3cr3t
main_url: school.smartschool.be
mfa: 2010-05-15   # date for account-verification, or Base32 secret for TOTP
```

If you need mfa, open your smartschool profile, two-factor authentication, add authenticator app.
When a QR code is displayed, choose 'I do not have a camera'. A code is shown and that's the one you need.

---

## `SmartschoolClient`

The authenticated HTTP client. Create one instance per session and share it across services.

```dart
final client = await SmartschoolClient.create(credentials);
await client.ensureAuthenticated();
```

| Method / getter | Description |
|---|---|
| `SmartschoolClient.create(credentials, {cacheDir, loginCooldown, clock})` | Factory — creates the Dio client, configures cookie jar, returns ready instance. `loginCooldown` (default 5 minutes) and `clock` (default `DateTime.now`): see *Logging in again* below |
| `ensureAuthenticated()` | Triggers login if not already done; safe to call repeatedly. Throws a `SmartschoolAuthenticationError` subtype when the login fails, a `SmartschoolConnectionError` when Smartschool is unreachable |
| `clearCookies()` | Deletes persisted cookies (use this for explicit logout/session reset). |
| `resetLoginAttempts()` | Lets a client that stopped logging in on its own log in again at once (see *Logging in again* below) |
| `getRaw(path)` | Authenticated GET → response body as `String` |
| `getJson(path, {query})` | Authenticated GET with JSON Accept header → decoded `dynamic` |
| `postFormRaw(path, fields)` | `application/x-www-form-urlencoded` POST → `String` |
| `postFormResponse(path, fields)` | Same POST → the whole `Response<String>` (status code, headers, final URL and body) |
| `postFormEncodedRaw(path, body)` | Same but accepts a pre-encoded body string |
| `postMultipartRaw(path, formData)` | `multipart/form-data` POST → `String` |
| `postXml(...)` | Posts to the legacy XML dispatcher and returns parsed element maps |
| `notificationCounterUpdates` | `Stream<NotificationCounterUpdate>` — broadcast stream of counter events emitted by any notification source |
| `emitNotificationCounterUpdate({moduleName, counter, isNew, source, timestamp})` | Push a `NotificationCounterUpdate` into the stream; returns `false` if the stream is already closed |
| `getCurrentUser()` | `Future<SmartschoolUser>` — returns the logged-in user (`id`, `displayName`, `avatarUrl`). Uses cached page data; no extra HTTP requests after the first authenticated call. |
| `dispose({force})` | Closes the notification stream and the underlying Dio client |
| `dio` | Exposes the underlying `Dio` instance for advanced / dev use |

### Logging in again

When Smartschool refuses the session for a request (it expired, or was never there), the client logs in and retries the request once; a retry that Smartschool refuses too throws `SmartschoolSessionExpiredError`. After three logins in a row that did not get the session accepted, the client stops logging in on its own: a refused request throws `SmartschoolSessionExpiredError` at once, without logging in. So that a long-lived client (a daemon, a background queue) gets out of that state by itself, it tries one login again once `loginCooldown` has passed since the last one (5 minutes by default); when the session is accepted it counts from zero again, and when it is not, it waits another cooldown. It does not when Smartschool rejected the credentials at the last login (the password, the 2FA code or the account-verification answer): trying them again every few minutes could get the account locked. Call `resetLoginAttempts()` to let it log in again at once, for instance once the credentials are fixed. A test can pass a fake `clock` to `create` and move it forward instead of waiting.

---

## `MessagesService`

All message operations. Construct with a `SmartschoolClient`.

```dart
final messages = MessagesService(client);
```

### Reading

| Method | Returns | Description |
|---|---|---|
| `getHeaders({boxType, boxId, sortBy, sortOrder, alreadySeenIds})` | `List<ShortMessage>` | List message headers for any box: one page, at most the first 50 (the newest 50 by default). Pass `alreadySeenIds` for lightweight polling. |
| `getArchiveHeaders({boxId, sortBy, sortOrder, alreadySeenIds})` | `List<ShortMessage>` | Convenience wrapper for the archive folder — resolves the box ID automatically. One page, like `getHeaders`. |
| `getHeaderPages({boxType, boxId, sortBy, sortOrder})` | `Stream<List<ShortMessage>>` | All headers of a box, page by page (about 50 each), as Smartschool's web client loads them while scrolling. The first page is what `getHeaders` returns; each next page is requested only when the listener wants it, so `take`/`takeWhile` or cancelling stops the paging. Ends after the last page, or at a page that brings no header not yet emitted. |
| `getArchiveHeaderPages({boxId, sortBy, sortOrder})` | `Stream<List<ShortMessage>>` | `getHeaderPages` for the archive folder. |
| `getAllHeaders({boxType, boxId, sortBy, sortOrder, limit})` | `Future<List<ShortMessage>>` | Collects `getHeaderPages`: every header of the box, or the first `limit`. Each page is a request. |
| `getAllArchiveHeaders({boxId, sortBy, sortOrder, limit})` | `Future<List<ShortMessage>>` | `getAllHeaders` for the archive folder. |
| `getArchiveBoxId()` | `Future<int>` | Returns the archive folder's numeric box ID (cached; falls back to `208`). |
| `getMessage(msgId, {boxType, includeAllRecipients})` | `Future<FullMessage?>` | Fetches the full HTML body, receiver lists, and metadata for a message. Pass `includeAllRecipients: true` to receive every recipient name in `receivers`/`ccReceivers`/`bccReceivers`; the default truncates the list and exposes the hidden count via `totalNrOther*` fields instead. Returns `null` when `boxType` holds no message `msgId` (an unknown ID, or one in another box). |
| `getReplyAllRecipients(msgId, {boxType})` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns all To and CC recipients with their numeric user IDs by parsing the reply-all compose page. Use this when you need IDs for a subsequent `sendMessage` reply-all. |
| `getSentMessageRecipients(msgId)` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns the original recipients of a **sent** message with their numeric user IDs. The outbox reply-all compose page includes the authenticated user (sender) alongside the recipients, once, whether or not they were a recipient too; this method also fetches the message (`getMessage` with all recipients) and keeps the authenticated user only where its recipient names include them, so a message sent to yourself returns you. BCC recipients are returned in the To list (#33). Use this instead of `getReplyAllRecipients` for messages in `BoxType.sent`. |
| `getAttachments(msgId, {boxType})` | `Future<List<MessageAttachment>>` | Returns the attachment list for a message. |

Smartschool keeps the paging position in the session, one per box, and restarts it whenever that box is listed again (`getHeaders`, also in poll mode, or another paging of the same box), which ends a paging of that box early. Paging different boxes at once is fine.

```dart
// Every message of the sent box, 50 per request.
final sent = await messages.getAllHeaders(boxType: BoxType.sent);

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

### Mutating

| Method | Returns | Description |
|---|---|---|
| `markRead(msgId, {boxType})` | `Future<MessageChanged?>` | Marks a message as read. `getMessage` does not flip the read state; call this after (or alongside) `getMessage` when you want the server to record the message as opened. Idempotent — safe to call on an already-read message. |
| `markUnread(msgId, {boxType, boxId})` | `Future<MessageChanged?>` | Marks a message as unread. |
| `setLabel(msgId, label, {boxType})` | `Future<MessageChanged?>` | Applies a colour flag (`MessageLabel`). Use `noFlag` to clear. |
| `moveToTrash(msgId)` | `Future<MessageDeletionStatus?>` | Moves a message to the trash. |
| `moveToArchive(msgIds)` | `Future<List<MessageChanged>>` | Archives one or more messages (REST endpoint). |

### Composing & searching

| Method | Returns | Description |
|---|---|---|
| `getCurrentUserAsRecipient()` | `Future<MessageSearchUser>` | Returns the currently-logged-in user as a compose recipient (reads IDs from compose page JS — safe and reliable). |
| `searchRecipients(query)` | `Future<List<MessageSearchResult>>` | JSON-based recipient search; results lack `ssId` — use `searchRecipientsForCompose` when sending. |
| `searchRecipientsForCompose(query)` | `Future<(List<MessageSearchUser>, List<MessageSearchGroup>)>` | Compose-form XML search; results carry `ssId`/`userLt` required by `sendMessage`. |
| `sendMessage({to, cc, bcc, toGroups, ..., subject, bodyHtml, attachmentPaths})` | `Future<void>` | Full multi-step send: loads compose form, registers recipients, uploads attachments, submits. |

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

See [example/notification_listener_full_message_example.dart](example/notification_listener_full_message_example.dart) for a complete runnable demo.
See [example/message_change_stream_example.dart](example/message_change_stream_example.dart) for a stream-binding walkthrough with synthetic events.

### Static parsers (exposed for testing)

| Method | Description |
|---|---|
| `parseHiddenFields(htmlBody)` | Extracts all `<input type="hidden">` name→value pairs from an HTML page. |
| `parseComposeCurrentUserIds(htmlBody)` | Extracts `(userId, ssId, userLt)` from the `window.tinymceInitConfig` block. |
| `parseArchiveBoxIdFromMessagesHtml(htmlBody)` | Extracts the archive folder box ID from the Messages module HTML. |
| `parseReplyAllRecipients(htmlBody)` | Extracts To and CC recipients with numeric IDs from a reply-all compose page (parses `div.receiverSpan` elements). Returns `(toList, ccList)`. |
| `parseSentMessageRecipients(htmlBody, {message})` | Like `parseReplyAllRecipients` but for the sent-folder compose page: additionally extracts the authenticated user's ID and removes them from the result, unless the sent `message` (a `FullMessage`) names them among its recipients. Returns `(toList, ccList)`. |

---

## `IntradeskService`

Access to the Smartschool Intradesk document repository. Construct with a `SmartschoolClient`.

```dart
final intradesk = IntradeskService(client);

// Root listing
final root = await intradesk.getRootListing();
for (final folder in root.folders) {
  print('${folder.name}  hasChildren: ${folder.hasChildren}');
}

// Drill into a sub-folder
final sub = await intradesk.getFolderListing(root.folders.first.id);

// Download a file
final bytes = await intradesk.downloadFile(sub.files.first.id);
await File('output.docx').writeAsBytes(bytes);
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getRootListing()` | `Future<IntradeskListing>` | Root-level folders, files, and weblinks. |
| `getFolderListing(folderId)` | `Future<IntradeskListing>` | Folders, files, and weblinks inside the identified folder. |
| `downloadFile(fileId)` | `Future<Uint8List>` | Raw bytes of the identified file. |

> **Not yet implemented**: file upload — the server-side endpoint and required form fields have not been captured safely.  
> **Not scoped**: the `/recent` endpoint returns an SPA HTML shell, not a JSON listing.

### Example

Run the interactive browser:

```bash
dart run example/intradesk_browser.dart
```

Controls:
- `U` / `D`: move selection up/down
- `Enter`: open folder or download selected file
- `B` / `Backspace`: go to parent folder
- `Q`: quit

---

## `PresenceService`

Writes a pupil's absence/presence code for a specific half-day via Smartschool's **internal** Presence module. Smartschool's official (public) API cannot write presences — only this internal endpoint can. The primary use case is marking a pupil **Te laat** ("late"), optionally **Te laat zonder geldige reden** ("late without a valid reason").

> **Access requirement:** this only works when the signed-in account has **Presence-handling access** for the class (`userCanRecord` is true in the module config). Without that right, the server rejects the request and a `SmartschoolPresenceError` is thrown.

> **Identity note:** the Presence module speaks Smartschool's **internal `userID`** (e.g. `11110`), which is *not* the public API's `AccountID` / `RegisterID` / `UID`. You supply the internal `userId` and the class `groupID` (classes map to the public API by `adminNumber`).

```dart
final presence = PresenceService(client);

// Mark internal userID 11110 (class groupID 298) late this morning.
await presence.setLate(
  userId: 11110,
  classGroupId: 298,
  date: DateTime(2026, 6, 1),
  part: DayPart.morning,
  motivation: 'Overslept',
);

// "Late without a valid reason" uses the alias of "Te laat".
await presence.setLate(
  userId: 11110,
  classGroupId: 298,
  date: DateTime(2026, 6, 1),
  part: DayPart.afternoon,
  withoutValidReason: true,
);

// Restore to present.
await presence.setPresent(
  userId: 11110,
  classGroupId: 298,
  date: DateTime(2026, 6, 1),
  part: DayPart.morning,
);
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `setLate({userId, classGroupId, date, part, withoutValidReason, motivation})` | `Future<void>` | Mark a pupil late for a half-day; `withoutValidReason` selects the "Te laat zonder geldige reden" alias. |
| `setPresent({userId, classGroupId, date, part, motivation})` | `Future<void>` | Mark a pupil present ("Aanwezig") — useful to clear a status. |
| `getConfig({forceRefresh})` | `Future<PresenceConfig>` | Module config: schoolyear ref date + the classes the account may record. Cached. |
| `getAllCodes(structId, {forceRefresh})` | `Future<List<PresenceCode>>` | Presence status codes for a school structure. Cached per structure. |
| `getClassPupils({classGroupId, date, schoolyearRefDate})` | `Future<List<PresencePupil>>` | Pupils and their am/pm half-day cells for a single day. |

Status codes are **not hard-coded** — their numeric IDs are per-school/per-structure, so they are resolved dynamically by name (`Te laat`, `Te laat zonder geldige reden`, `Aanwezig`). The service handles both updating an existing half-day cell and creating one where none exists, and surfaces a non-empty server `errors[]` as a `SmartschoolPresenceError`.

### Errors

An expired session and a missing access right need opposite actions, so they arrive as different types:

- `SmartschoolPresenceError` — the Presence module refused or could not handle the request (it answers with an HTML error page instead of JSON, typically HTTP `500`), the save came back with a non-empty `errors[]`, or a class, code or pupil could not be resolved (e.g. a class the account may not record for). The session was accepted: signing in again does not help.
- `SmartschoolSessionExpiredError` (a `SmartschoolAuthenticationError`) — Smartschool answered with its login chain instead of the data, also after the client logged in again and retried the request once. The request was not carried out: sign in again and retry.

```dart
try {
  await presence.setLate(/* … */);
} on SmartschoolSessionExpiredError {
  // Sign in again (e.g. a new SmartschoolClient) and retry.
} on SmartschoolAuthenticationError {
  // Logging in failed: check the credentials.
} on SmartschoolPresenceError catch (e) {
  // Permanent: show e.message (and e.errors) to the operator.
} on SmartschoolConnectionError {
  // Smartschool is unreachable: retry later.
}
```

### Example

```bash
dart run example/set_late_example.dart
```

---

## Models

### `ShortMessage`
Returned by `getHeaders` / `getArchiveHeaders`. Fields: `id`, `sender`, `subject`, `date`, `unread`, `deleted`, `attachment`, `coloredFlag`, `allowReply`, `realBox`, …

### `FullMessage`
Returned by `getMessage`. Adds: `body` (HTML), `receivers`, `ccReceivers`, `bccReceivers`, `canReply`, `senderPicture`, `totalNrOtherToReceivers`, `totalNrOtherCcReceivers`, `totalNrOtherBccReceivers` (count of recipients hidden behind a "show more" link when `includeAllRecipients` is `false`), …

### `MessageAttachment`
Returned by `getAttachments`. Fields: `fileId`, `name`, `mime`, `size`, `icon`, `wopiAllowed`, `order`.

Use `attachment.download(client)` to fetch raw bytes for a specific attachment.

### `MessageSearchUser` / `MessageSearchGroup`
Used as recipients in `sendMessage`. Key fields: `userId`/`groupId`, `ssId`, `userLt`, `displayName`.

### `SmartschoolUser`
Returned by `SmartschoolClient.getCurrentUser()`. Fields: `id` (int — server-assigned numeric user ID), `displayName` (String), `avatarUrl` (String? — profile picture URL).

### `MessageChanged` / `MessageDeletionStatus`
Returned by mutation operations. Carry the `id` of the affected message and a `newValue` / status field.

### `NotificationCounterUpdate`
Transport-agnostic event produced by any notification source (WebSocket, polling bridge, or manual emit).

| Field | Type | Description |
|---|---|---|
| `moduleName` | `String` | Smartschool module name (e.g. `'Messages'`, `'Ticket'`). |
| `counter` | `int` | Current badge count reported by the source. |
| `isNew` | `bool` | Whether the source flagged this as a new-item signal. |
| `source` | `String` | Opaque tag identifying the origin (`'websocket'`, `'poll'`, …). |
| `timestamp` | `DateTime` | When the event was created. |

### `MessageCounterUpdate`
Produced by `MessagesService` after deduplication and emitted on `messageCounterUpdates`.

| Field | Type | Description |
|---|---|---|
| `counter` | `int` | New message counter value. |
| `previousCounter` | `int?` | Previous value (null on first event). |
| `isNew` | `bool` | Forwarded from the source `NotificationCounterUpdate`. |
| `source` | `String` | Forwarded source tag. |
| `timestamp` | `DateTime` | When the event was created. |

### `IntradeskListing`
Returned by `getRootListing` / `getFolderListing`. Fields: `folders` (`List<IntradeskFolder>`), `files` (`List<IntradeskFile>`), `weblinks` (raw maps).

### `IntradeskFolder`
Fields: `id`, `name`, `color`, `state`, `visible`, `confidential`, `parentFolderId` (empty at root), `hasChildren`, `isFavourite`, `capabilities` (`IntradeskFolderCapabilities`), `platform`, `dateCreated`, `dateChanged`, `dateStateChanged`.

### `IntradeskFile`
Fields: `id`, `name`, `state`, `parentFolderId`, `ownerId`, `confidential`, `isFavourite`, `currentRevision` (`IntradeskFileRevision?`), `capabilities` (`IntradeskFileCapabilities`), `platform`, `dateCreated`, `dateChanged`, `dateStateChanged`.

### `IntradeskFileRevision`
Current revision metadata. Fields: `id`, `fileId`, `fileSize`, `label`, `dateCreated`, `owner` (`IntradeskFileOwner`).

### `PresenceConfig`
Returned by `PresenceService.getConfig()`. Fields: `activeClass` (`PresenceClassRef?`), `allowedClasses` (`List<PresenceClassRef>`), `schoolyearRefDate` (String, `yyyy-MM-dd`). Helper `classForGroup(groupId)`.

### `PresenceClassRef`
A class as listed by the Presence config. Fields: `groupId`, `name`, `adminNumber` (`int?`), `instituteNumber` (`int?`), `structId` (`int?` — `null` for virtual grouping classes), `userCanRecord`, `userCanConfirm`, `isOfficial`.

### `PresenceCode` / `PresenceAlias`
A presence status code (`codeId`, `code`, `name`, `aliases`) and its aliases (`aliasId`, `parentCodeId`, `name`). Codes are per-structure, resolved by name. `PresenceCode.aliasByName(name)` looks up an alias case-insensitively.

### `PresencePupil` / `PresenceHalfDay`
Returned by `PresenceService.getClassPupils()`. A pupil (`userId`, `movementId`, `name`, `halfDays`) and its half-day cells (`presenceId` — `null` when no record yet, `presenceDate`, `part`, `codeId`, `aliasId`, `motivation`). `PresencePupil.halfDayFor(part, {date})` returns the matching cell.

---

## Enums

| Enum | Values |
|---|---|
| `BoxType` | `inbox`, `draft`, `scheduled`, `sent`, `trash` |
| `SortField` | `date`, `from`, `readUnread`, `attachment`, `flag` |
| `SortOrder` | `asc`, `desc` |
| `RecipientType` | `to`, `cc`, `bcc` |
| `MessageLabel` | `noFlag`, `greenFlag`, `yellowFlag`, `redFlag`, `blueFlag` |
| `DayPart` | `morning` (`"am"`), `afternoon` (`"pm"`) |

---

## Exceptions

| Exception | Thrown when |
|---|---|
| `SmartschoolAuthenticationError` | Login fails or session has expired (base class of the login failures below, and thrown itself for other authentication failures) |
| `SmartschoolInvalidCredentialsError` | Smartschool rejects the username or password (also SSO-only accounts) |
| `SmartschoolTwoFactorRequiredError` | Smartschool asks for a 2FA code, but `mfa` holds no TOTP secret |
| `SmartschoolTwoFactorRejectedError` | Smartschool rejects the 2FA code (wrong TOTP secret, or the device clock is off) |
| `SmartschoolUnsupportedTwoFactorMethodError` | The account's 2FA does not offer an authenticator app (carries the `availableMethods`) |
| `SmartschoolAccountVerificationRequiredError` | Smartschool asks for account verification (date of birth), but `mfa` is empty or not a date |
| `SmartschoolAccountVerificationRejectedError` | Smartschool rejects the account verification answer |
| `SmartschoolSessionExpiredError` | Smartschool does not accept the session: after logging in again, the retry of a request is still answered with `401` or by the login chain (redirected to `/login`, `/2fa` or `/account-verification`). Sign in again and retry |
| `SmartschoolConnectionError` | `ensureAuthenticated()` or a service call cannot reach Smartschool: the host does not resolve, the connection fails or times out (carries the `cause`). A network problem, so not an authentication error |
| `SmartschoolComposeError` | The compose form cannot be parsed, or the server rejects the message |
| `SmartschoolAttachmentUploadError` | An attachment upload step fails |
| `SmartschoolPresenceError` | A presence save is rejected (carries the server `errors`), the Presence module refuses or cannot handle a request (an HTML error page instead of JSON), or a class/code/pupil cannot be resolved. Not a session problem |

The login failure types all extend `SmartschoolAuthenticationError`, so a `catch` of the base class still catches them. They are thrown directly, by `ensureAuthenticated()` and also by a service call (or any `SmartschoolClient` request method) that finds the session cold or expired and fails to log in again, so the same `on` clauses work around either. Only a request made on `client.dio` itself gets them wrapped in a `DioException`, as its `error`.

```dart
try {
  await client.ensureAuthenticated();
  final headers = await MessagesService(client).getHeaders();
} on SmartschoolInvalidCredentialsError {
  // Ask the user to check their username and password.
} on SmartschoolTwoFactorRejectedError {
  // Ask the user to check their TOTP secret and device clock.
} on SmartschoolAuthenticationError catch (e) {
  // Any other authentication failure.
} on SmartschoolConnectionError {
  // Smartschool is unreachable: ask the user to check their network.
}
```

`SmartschoolConnectionError` extends `SmartschoolException`, not `SmartschoolAuthenticationError`: a `catch` of the authentication error does not swallow a network problem. `ensureAuthenticated()` and every service call (or any `SmartschoolClient` request method) report an unreachable Smartschool this way, also when the network fails during a login the call triggered. Only a request made on `client.dio` itself gets the plain `DioException`.

---

## Development

Git hooks are managed by [Lefthook](https://github.com/evilmartians/lefthook), installed as an npm dev dependency (`node_modules/` is not committed). Run this once after cloning — and once after pulling e09cd55, which removed the previously committed `node_modules/`:

```bash
npm install
```

This installs Lefthook (pinned in `package.json`) and its postinstall step installs the Git hooks. To (re)install the hooks yourself — e.g. after changing `.lefthook.yml` — run:

```bash
npx lefthook install
```

The `pre-commit` hook runs the same checks as CI, in parallel:

| Command | Check |
|---|---|
| `dart format --output=none --set-exit-if-changed .` | Formatting |
| `dart analyze` | Static analysis |
| `dart test` | Unit tests |

`.lefthook.yml` sets `assert_lefthook_installed: true`: if the hook is installed but Lefthook is missing (e.g. `node_modules/` was deleted), the commit is aborted with `Can't find lefthook in PATH` instead of silently skipping the checks. Run `npm install` to fix it.

---

## Smartschool Researcher MCP Server

This repository includes a local [MCP](https://modelcontextprotocol.io) server that wraps the `DevInspector` HTTP client so **Copilot Agent mode** can explore live Smartschool endpoints directly. It is intended for development and reverse-engineering only.

- **Entrypoint**: `bin/smartschool_researcher_mcp.dart`
- **VS Code config**: `.vscode/mcp.json` (pre-configured)
- **Credentials**: `credentials.yml` (auto-discovered; never commit this file)

### Available tools

| Tool | Description |
|---|---|
| `login` | Authenticates with `credentials.yml`, or with inline `username`/`password`/`mainUrl`. |
| `login_status` | Checks whether the current MCP session has an active Smartschool session. |
| `get_page` | Authenticated GET → `statusCode`, `headers`, `body`. |
| `get_json` | GET with JSON Accept header → parsed `json` field in addition to raw body. |
| `post_form` | Authenticated `application/x-www-form-urlencoded` POST. |
| `request` | Generic tool: arbitrary method, headers, query params, body, content type. |

### Typical agent workflow

1. Call `login` once at the start of the session.
2. Call `get_page` on the target module URL (e.g. `/?module=Messages&file=composeMessage`).
3. Inspect the returned HTML/JSON to identify form field names, JS config blobs, and API endpoints.
4. Use `post_form` or `request` to replicate browser actions.
5. Design the Dart service method and models from the confirmed response shape.

Pass `maxBodyChars` to any tool to truncate large responses before they fill the context window.

> **Keep `credentials.yml` local and private.** It is listed in `.gitignore` and must never be committed.
