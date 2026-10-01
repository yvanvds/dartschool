# flutter_smartschool

An unofficial Dart client library for the [Smartschool](https://www.smartschool.be) school platform. It handles authentication (including TOTP 2FA and birthday-based account verification), cookie persistence, and the mix of XML-protocol and JSON/REST endpoints that Smartschool uses internally.

Repository: [yvanvds/dartschool](https://github.com/yvanvds/dartschool)

> **Unofficial.** This library reverse-engineers the private Smartschool web API. It is not endorsed by or affiliated with Smartschool. Use responsibly.

[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=bugs)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Coverage](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=coverage)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool)

## Features

- Authenticated Smartschool client with cookie persistence and MFA/account-verification support.
- Full messaging workflow (`MessagesService`): list, read, attachments, recipient search, send, replies linked to the original message, archive, trash, labels, reply-all recipient resolution.
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

	// List the newest inbox headers: one page, at most 50 (getAllHeaders
	// pages through the rest).
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
		SendMessageParams(
			to: [myself],
			subject: 'Hello from flutter_smartschool',
			bodyHtml: '<p>It works!</p>',
		),
	);
}
```

See [example/send_message_lifecycle_example.dart](example/send_message_lifecycle_example.dart) for a complete send → inbox poll → archive → trash flow, on a message it sends to the own account only. It changes that account: it moves both copies of the message to the trash with `moveToTrashFrom`, the sent-box copy first and then the archived inbox copy (`boxType: BoxType.inbox`, with the archive folder's ID from `getArchiveBoxId()` as `boxId`), and checks the trash, archive, inbox and sent-box listings, since Smartschool's answer to a move says nothing about it. It never empties the trash.

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
| `SmartschoolClient.create(credentials, {cacheDir, loginCooldown, clock})` | Factory — creates the Dio client, configures cookie jar, returns ready instance. `cacheDir`: see *Cache folder* below. `loginCooldown` (default 5 minutes) and `clock` (default `DateTime.now`): see *Logging in again* below |
| `cacheDir` | The folder this client keeps its per-user data in (see *Cache folder* below) |
| `SmartschoolClient.defaultCacheDir(username)` | Static — the folder `create` uses for `username` when it is given no `cacheDir` (see *Cache folder* below) |
| `ensureAuthenticated()` | Triggers login if not already done; safe to call repeatedly. Throws a `SmartschoolAuthenticationError` subtype when the login fails, a `SmartschoolConnectionError` when Smartschool is unreachable |
| `clearCookies()` | Deletes persisted cookies (use this for explicit logout/session reset). |
| `resetLoginAttempts()` | Lets a client that stopped logging in on its own log in again at once (see *Logging in again* below) |
| `getRaw(path)` | Authenticated GET → response body as `String` |
| `getResponse(path, {query})` | Same GET → the whole `Response<String>`; pass it as `sameSessionAs` to a request that carries state of the page (see *Logging in again* below) |
| `getJson(path, {query})` | Authenticated GET with JSON Accept header → decoded `dynamic` |
| `postFormRaw(path, fields, {query, retryAfterLogin, sameSessionAs})` | `application/x-www-form-urlencoded` POST → `String` |
| `postFormResponse(path, fields, {query, retryAfterLogin, sameSessionAs})` | Same POST → the whole `Response<String>` (status code, headers, final URL and body) |
| `postFormEncodedRaw(path, body)` | Same but accepts a pre-encoded body string |
| `postMultipartRaw(path, formData, {retryAfterLogin, sameSessionAs})` | `multipart/form-data` POST → `String` |
| `postMultipartResponse(path, formData, {retryAfterLogin, sameSessionAs})` | Same POST → the whole `Response<String>` |
| `postXml(..., {allowEmptyAnswer})` | Posts to the legacy XML dispatcher and returns parsed element maps. Throws for an answer that is not XML; with `allowEmptyAnswer`, an empty `200` answer returns no elements instead |
| `download(path, {maxBytes})` | Authenticated GET → the whole file as `Uint8List`. With `maxBytes`, throws `SmartschoolDownloadTooLargeError` as soon as the file turns out larger (see *Downloads* below) |
| `downloadStream(path, {maxBytes})` | Same GET → a `SmartschoolDownload` as soon as the headers are in: `contentLength`, `fileName`, `contentType`, and the content as a `stream` (see *Downloads* below) |
| `notificationCounterUpdates` | `Stream<NotificationCounterUpdate>` — broadcast stream of counter events emitted by any notification source |
| `emitNotificationCounterUpdate({moduleName, counter, isNew, source, timestamp})` | Push a `NotificationCounterUpdate` into the stream; returns `false`, emitting nothing, when `moduleName` is empty or the client was disposed (the stream is closed) |
| `getCurrentUser()` | `Future<SmartschoolUser>` — returns the logged-in user (`id`, `displayName`, `avatarUrl`). Uses cached page data; no extra HTTP requests after the first authenticated call. |
| `dispose({force})` | Closes the notification stream and the underlying Dio client (`force`, the default, cuts off the requests that run). The client cannot be used afterwards: every request method, `ensureAuthenticated()`, `platformId` and `getCurrentUser()` throw a `StateError` ("SmartschoolClient was disposed") without sending anything (see *Exceptions*). Calling it again does nothing |
| `dio` | Exposes the underlying `Dio` instance for advanced / dev use |

### Cache folder

A client keeps its per-user data, such as the saved session cookies (in `.cookies`), in a cache folder, so a new client for the same user carries on in the saved session. Pass `cacheDir` to `create` to choose the folder; without it, the client uses `.cache/smartschool/<username>` in the user's home folder: the `HOME` environment variable, or `USERPROFILE` when `HOME` is not set (as on Windows, where that is typically `C:\Users\<name>\.cache\smartschool\<username>`), or the current directory when neither is set. `create` makes the folder when it does not exist yet.

`client.cacheDir` is the folder a client uses, default or given. `SmartschoolClient.defaultCacheDir(username)` is the default folder for a username, without a client; it only works out the path, and does not create the folder. Use these rather than building the path yourself, so an app keeps finding the folder if the library's default changes.

```dart
final client = await SmartschoolClient.create(credentials);
final myCache = Directory(p.join(client.cacheDir, 'my_app')); // next to the library's data

// Without a client, for example to clean up after a user signs out:
final dir = Directory(SmartschoolClient.defaultCacheDir('john.doe'));
if (dir.existsSync()) dir.deleteSync(recursive: true);
```

An app can keep its own per-user data in the folder, so it is found and cleaned up together with the library's: put it in a subfolder of its own and leave the library's files alone (call `clearCookies()` to delete the session).

### Logging in again

When Smartschool refuses the session for a request (it expired, or was never there), the client logs in and retries the request once; a retry that Smartschool refuses too throws `SmartschoolSessionExpiredError`. Requests on one client share that login: a request that Smartschool refuses while a login runs waits for it and is then retried in the new session, and fails with the same error when the login fails, so concurrent requests on an expired session send the password and the 2FA code once, and the login counts once toward the limit below. The login loads Smartschool's login page itself, in a new session, and the answers that Smartschool refused do not change the cookie cache, so the password always goes out in the session its login form belongs to. After three logins in a row that did not get the session accepted, the client stops logging in on its own: a refused request throws `SmartschoolSessionExpiredError` at once, without logging in. So that a long-lived client (a daemon, a background queue) gets out of that state by itself, it tries one login again once `loginCooldown` has passed since the last one (5 minutes by default); when the session is accepted it counts from zero again, and when it is not, it waits another cooldown. It does not when Smartschool rejected the credentials at the last login (the password, the 2FA code or the account-verification answer): trying them again every few minutes could get the account locked. Call `resetLoginAttempts()` to let it log in again at once, for instance once the credentials are fixed. A test can pass a fake `clock` to `create` and move it forward instead of waiting.

Pass `retryAfterLogin: false` to `postFormRaw`, `postFormResponse`, `postMultipartRaw` or `postMultipartResponse` for a request that carries state of the session it was prepared in, such as the tokens of Smartschool's compose form: a retry would send that state in a session it does not belong to. When Smartschool refuses the session for such a request, it is neither retried nor used to log in again: it throws `SmartschoolSessionExpiredError` at once, and the next refused request logs in. `MessagesService.sendMessage` sends its steps after loading the compose form this way.

That covers the request being refused. A login replaces the client's session whichever request it runs for, and Smartschool then accepts such a request in the new session, stale state and all. Pass `sameSessionAs` too, the earlier answer the state comes from (for instance the page, loaded with `getResponse`), for a request that must go out only in that answer's session: when a login started on the client since that answer's request went out, or one runs, the request is not sent and throws `SmartschoolSessionExpiredError` at once. A login that runs or failed counts as well as one that completed: the login replaces the session cookie as soon as it loads its login form, and a login that failed after Smartschool accepted it (the connection dropped on its last answer) leaves the new session behind. `MessagesService.sendMessage` and `sendReply` send their steps after loading the compose form this way too.

### Downloads

`download(path)` (and `IntradeskService.downloadFile`, `MessageAttachment.download`) returns the whole file in memory. `downloadStream(path)` (and `IntradeskService.downloadFileStream`, `MessageAttachment.downloadStream`) returns a `SmartschoolDownload` as soon as the headers of Smartschool's answer are in, before the file is read:

- `contentLength`: the size Smartschool announces (`Content-Length`), or `null` when it announces none (or the content comes in encoded, such as gzip);
- `fileName`: the name in `Content-Disposition` (`filename*` in UTF-8 or ISO-8859-1 when there is one, else `filename`), as Smartschool sends it: check it before using it as a path;
- `contentType`: as Smartschool gives it. Intradesk answers `application/x-www-form-urlencoded` for every file, so tell the type from the name;
- `stream`: the content, as it comes in. Pausing the subscription pauses the transfer; cancelling it, or calling `cancel()` on the download, stops the transfer and closes the connection (Dio alone would read the answer to its end). Listen to it right away: until then, what comes in is held in memory.

Pass `maxBytes` to any of them to refuse a larger file: the download fails with a `SmartschoolDownloadTooLargeError` (carrying `maxBytes` and the announced `contentLength`) as soon as the file turns out larger. When Smartschool announces a larger size, that happens before any of it is read (`downloadStream` throws it); otherwise the bytes are counted as they come in, and the download fails once more than `maxBytes` came in (`stream` ends with the error, after at most `maxBytes` bytes). Either way the client stops the transfer. The size in an Intradesk listing may be out of date; `maxBytes` checks the file itself.

```dart
final download = await IntradeskService(client).downloadFileStream(
  file.id,
  maxBytes: 25 * 1024 * 1024,
);
print('${download.fileName}: ${download.contentLength} bytes');
await download.stream.pipe(File('out.bin').openWrite());
```

A download on a session that Smartschool refuses is handled as every request (see *Logging in again* above): the client reads the login page it gets instead of the file, logs in and retries, and the stream holds the answer to the retry; when the retry is refused too, it throws `SmartschoolSessionExpiredError` and hands nothing over. Another status than `200` (such as `404` for an Intradesk file that does not exist) throws a `SmartschoolDownloadError`, and a connection that fails, also halfway through the file, a `SmartschoolConnectionError`.

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
| `getMessage(msgId, {boxType, includeAllRecipients})` | `Future<FullMessage?>` | Fetches the full HTML body, receiver lists, and metadata for a message. Pass `includeAllRecipients: true` to receive every recipient name in `receivers`/`ccReceivers`/`bccReceivers`; the default truncates the list and exposes the hidden count via `totalNrOther*` fields instead. For a message in the sent box, `toRecipients`/`ccRecipients`/`bccRecipients` also say whether each recipient has read it. Returns `null` when `boxType` holds no message `msgId` (an unknown ID, or one in another box). |
| `getReplyRecipients(msgId, {boxType})` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns the recipient of a plain reply, the sender of the message, with their numeric user ID by parsing Smartschool's reply compose page (`composeType=1`), as `(to, cc, bcc)`: the sender in `to`, `cc` and `bcc` empty. Pass the lists to `sendReply` to send the reply; the To list of `getReplyAllRecipients` holds the sender too, but among the other recipients, unmarked. For a message in the sent box, or one you sent to yourself, the sender is you. |
| `getReplyAllRecipients(msgId, {boxType})` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns all To, CC and BCC recipients with their numeric user IDs by parsing the reply-all compose page, as `(to, cc, bcc)`. Pass the lists to `sendReply(…, all: true)` to send the reply to all. The page of a received message is not expected to name BCC recipients. |
| `getSentMessageRecipients(msgId)` | `Future<(List<MessageSearchUser>, List<MessageSearchUser>, List<MessageSearchUser>)>` | Returns the original recipients of a **sent** message with their numeric user IDs. The outbox reply-all compose page includes the authenticated user (sender) alongside the recipients, once, whether or not they were a recipient too; this method also fetches the message (`getMessage` with all recipients) and keeps the authenticated user only where its recipient names include them, so a message sent to yourself returns you. Returns `(to, cc, bcc)`: the BCC recipients are in `bcc`, so a reply-all built from `to` and `cc` does not reveal them (#33). Use this instead of `getReplyAllRecipients` for messages in `BoxType.sent`. |
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
| `moveToTrash(msgId)` | `Future<MessageDeletionStatus?>` | Moves a message to the trash, or deletes it for good: prefer `moveToTrashFrom`. It sends Smartschool's `quick delete`, which names the ID only, not the box: Smartschool acts on whichever copy of the ID its own session state points to. That can be a copy in the trash, which a `quick delete` deletes for good, so this is never a guaranteed no-op, not even for an ID that names no message such as `0` (#61). For a message you sent to yourself (the same ID in the inbox and the sent box) it moved the inbox copy; `moveToTrashFrom` moves the sent-box copy. `null` when Smartschool does not confirm it, as when it deleted nothing (it then answered with an empty body). |
| `moveToTrashFrom(msgId, {boxType, boxId})` | `Future<void>` | Moves the copy of a message in `boxType`, `BoxType.inbox` or `BoxType.sent`, to the trash, and leaves its other copy where it is, as dragging it onto the trash in Smartschool's web client does. A move, not a deletion: safe while another copy of the ID is in the trash. Smartschool's answer says nothing about the move, so list the boxes to check. Pass `boxId` for a folder of the box, such as the archive: tried live once (2026-10-01, #64), it took an archived message out of the archive, and the trash then listed it. Another `boxType` throws an `ArgumentError`. |
| `moveToArchive(msgIds)` | `Future<List<MessageChanged>>` | Archives one or more messages (REST endpoint). |

### Composing & searching

| Method | Returns | Description |
|---|---|---|
| `getCurrentUserAsRecipient()` | `Future<MessageSearchUser>` | Returns the currently-logged-in user as a compose recipient (reads IDs from compose page JS — safe and reliable). |
| `searchRecipients(query)` | `Future<List<MessageSearchResult>>` | JSON-based recipient search; results lack `ssId` — use `searchRecipientsForCompose` when sending. |
| `searchRecipientsForCompose(query)` | `Future<(List<MessageSearchUser>, List<MessageSearchGroup>)>` | Compose-form XML search; results carry `ssId`/`userLt` required by `sendMessage`. |
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

See [example/notification_listener_full_message_example.dart](example/notification_listener_full_message_example.dart) for a complete runnable demo.
See [example/message_change_stream_example.dart](example/message_change_stream_example.dart) for a stream-binding walkthrough with synthetic events.

### Static parsers (exposed for testing)

| Method | Description |
|---|---|
| `parseHiddenFields(htmlBody)` | Extracts all `<input type="hidden">` name→value pairs from an HTML page. |
| `parseComposeCurrentUserIds(htmlBody)` | Extracts `(userId, ssId, userLt)` from the `window.tinymceInitConfig` block. |
| `parseArchiveBoxIdFromMessagesHtml(htmlBody)` | Extracts the archive folder box ID from the Messages module HTML. |
| `parseReplyAllRecipients(htmlBody)` | Extracts To, CC and BCC recipients with numeric IDs from a reply-all or reply compose page (parses `div.receiverSpan` elements; their `typeatt` is the field: `0`/`1` To, `2`/`4` CC, `3`/`5` BCC, the second of each for co-accounts). Returns `(toList, ccList, bccList)`. |
| `parseSentMessageRecipients(htmlBody, {message})` | Like `parseReplyAllRecipients` but for the sent-folder compose page: additionally extracts the authenticated user's ID and removes them from the result, unless the sent `message` (a `FullMessage`) names them among its recipients (in the field that names them). Returns `(toList, ccList, bccList)`. |

---

## `IntradeskService`

Access to the Smartschool Intradesk document repository. Construct with a `SmartschoolClient`.

```dart
final intradesk = IntradeskService(client);

// Root listing
final root = await intradesk.getRootListing();
for (final folder in root.folders) {
  print('${folder.name}  hasSubfolders: ${folder.hasSubfolders}');
}

// Drill into a sub-folder (also one without subfolders: it can still hold
// files and weblinks)
final sub = await intradesk.getFolderListing(root.folders.first.id);
for (final link in sub.weblinks) {
  print('${link.name}: ${link.url}');
}

// Download a file
final bytes = await intradesk.downloadFile(sub.files.first.id);
await File('output.docx').writeAsBytes(bytes);

// Or stream it to disk, refusing anything above 25 MB
final download = await intradesk.downloadFileStream(
  sub.files.first.id,
  maxBytes: 25 * 1024 * 1024,
);
print('${download.fileName}: ${download.contentLength} bytes');
await download.stream.pipe(File('output.docx').openWrite());
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getRootListing()` | `Future<IntradeskListing>` | Root-level folders, files, and weblinks. |
| `getFolderListing(folderId)` | `Future<IntradeskListing>` | Folders, files, and weblinks inside the identified folder. Throws a `SmartschoolIntradeskFolderNotFoundError` when Smartschool knows no folder with that ID (an unknown ID, or the ID of a file or a weblink). |
| `downloadFile(fileId, {maxBytes})` | `Future<Uint8List>` | Raw bytes of the identified file. With `maxBytes`, throws a `SmartschoolDownloadTooLargeError` as soon as the file turns out larger (see *Downloads* above). A `SmartschoolDownloadError` with status `404` when there is no such file. |
| `downloadFileStream(fileId, {maxBytes})` | `Future<SmartschoolDownload>` | The same file as a stream, with its size and name, as soon as the headers are in (see *Downloads* above). |

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
Returned by `getHeaders` / `getArchiveHeaders`, `getHeaderPages` / `getArchiveHeaderPages` (page by page) and `getAllHeaders` / `getAllArchiveHeaders`. Fields: `id`, `sender`, `subject`, `date`, `unread`, `deleted`, `attachment`, `coloredFlag`, `allowReply`, `realBox`, …

### `FullMessage`
Returned by `getMessage`. Adds: `body` (HTML), `receivers`, `ccReceivers`, `bccReceivers` (recipient names), `toRecipients`, `ccRecipients`, `bccRecipients` (the same recipients as `MessageRecipient`s), `canReply`, `senderPicture`, `totalNrOtherToReceivers`, `totalNrOtherCcReceivers`, `totalNrOtherBccReceivers` (count of recipients hidden behind a "show more" link when `includeAllRecipients` is `false`), …

### `MessageRecipient`
A recipient in `FullMessage.toRecipients` / `ccRecipients` / `bccRecipients`. Fields: `name`, `hasRead` (`bool?`). For a message in the sent box, Smartschool starts each recipient name with `+` (the recipient's copy is read) or `-` (unread); `getMessage` removes the marker from the name and sets `hasRead` from it. In every other box `hasRead` is `null`.

### `MessageAttachment`
Returned by `getAttachments`. Fields: `fileId`, `name`, `mime`, `size`, `icon`, `wopiAllowed`, `order`.

Use `attachment.download(client)` to fetch raw bytes for a specific attachment, or `attachment.downloadStream(client)` for a `SmartschoolDownload`; both take `maxBytes` (see *Downloads* under `SmartschoolClient`).

### `SmartschoolDownload`
Returned by `SmartschoolClient.downloadStream`, `IntradeskService.downloadFileStream` and `MessageAttachment.downloadStream` as soon as the headers of the answer are in. Fields: `contentLength` (`int?`), `fileName` (`String?`), `contentType` (`String?`), `headers`, `stream` (`Stream<List<int>>`, the content as it comes in, to be read once), and `cancel()`. See *Downloads* under `SmartschoolClient`.

### `MessageSearchUser` / `MessageSearchGroup`
Used as recipients in `SendMessageParams`. Returned by `searchRecipientsForCompose`; users also by `getCurrentUserAsRecipient`, `getReplyRecipients`, `getReplyAllRecipients` and `getSentMessageRecipients`. Key fields: `userId`/`groupId`, `ssId`, `userLt` (users only), `displayName`.

### `SmartschoolUser`
Returned by `SmartschoolClient.getCurrentUser()`. Fields: `id` (int — server-assigned numeric user ID), `displayName` (String), `avatarUrl` (String? — profile picture URL).

### `MessageChanged` / `MessageDeletionStatus`
Returned by mutation operations. `MessageChanged` carries the `id` of the affected message and its `newValue`. `MessageDeletionStatus` (from `moveToTrash`) carries the `msgId`, the `boxType` it was in, `isDeleted` (`true` when Smartschool confirms the deletion) and `unread`, the read state of the message.

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
Returned by `getRootListing` / `getFolderListing`. Fields: `folders` (`List<IntradeskFolder>`), `files` (`List<IntradeskFile>`), `weblinks` (`List<IntradeskWeblink>`).

### `IntradeskFolder`
Fields: `id`, `name`, `color`, `state`, `visible`, `confidential`, `parentFolderId` (empty at root), `hasChildren`, `isFavourite`, `capabilities` (`IntradeskFolderCapabilities`), `platform`, `dateCreated`, `dateChanged`, `dateStateChanged`.

`hasChildren` is Smartschool's own flag for its folder tree and counts **subfolders only**: a folder with `hasChildren` false can still hold files and weblinks, so list it anyway to find them. `hasSubfolders` is the same value under a name that says what it counts.

### `IntradeskFile`
Fields: `id`, `name`, `state`, `parentFolderId`, `ownerId`, `confidential`, `isFavourite`, `currentRevision` (`IntradeskFileRevision?`), `capabilities` (`IntradeskFileCapabilities`), `platform`, `dateCreated`, `dateChanged`, `dateStateChanged`.

### `IntradeskWeblink`
A link to a web page, kept in a folder next to its files. Fields: `id`, `name`, `url`, `icon` (Smartschool's icon name, e.g. `folder_orange`), `state`, `parentFolderId`, `ownerId`, `confidential`, `isFavourite`, `capabilities` (`IntradeskWeblinkCapabilities`: `canManage`, `canMove`, `canSeeHistory`, `canSeeViewHistory`), `platform`, `dateCreated`, `dateChanged`, `dateStateChanged`.

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
| `LvsCopy` | `none` (`dontCopyToLVS`), `store` (`copyToLVS`), `storeConfidential` (`copyToLVSAndMarkAsPrivate`) |
| `MessageLabel` | `noFlag`, `greenFlag`, `yellowFlag`, `redFlag`, `blueFlag` |
| `DayPart` | `morning` (`"am"`), `afternoon` (`"pm"`) |

---

## Exceptions

| Exception | Thrown when |
|---|---|
| `SmartschoolAuthenticationError` | Login fails or session has expired (base class of the login failures below, and thrown itself for other authentication failures) |
| `SmartschoolInvalidCredentialsError` | Smartschool rejects the username or password (also SSO-only accounts). In rare cases a rejected login form token instead, which Smartschool answers with the same page (#46); do not log in again automatically |
| `SmartschoolTwoFactorRequiredError` | Smartschool asks for a 2FA code, but `mfa` holds no TOTP secret |
| `SmartschoolTwoFactorRejectedError` | Smartschool rejects the 2FA code (wrong TOTP secret, or the device clock is off) |
| `SmartschoolUnsupportedTwoFactorMethodError` | The account's 2FA does not offer an authenticator app (carries the `availableMethods`) |
| `SmartschoolAccountVerificationRequiredError` | Smartschool asks for account verification (date of birth), but `mfa` is empty or not a date |
| `SmartschoolAccountVerificationRejectedError` | Smartschool rejects the account verification answer |
| `SmartschoolSessionExpiredError` | Smartschool does not accept the session: after logging in again, the retry of a request is still answered with `401` or by the login chain (redirected to `/login`, `/2fa` or `/account-verification`), or a request sent with `retryAfterLogin: false` (such as a step of `sendMessage`) is refused, or a request sent with `sameSessionAs` (such as a step of `sendMessage`) is not sent because the client logged in again since that answer was loaded. The request was not carried out: sign in again and retry |
| `SmartschoolConnectionError` | `ensureAuthenticated()` or a service call cannot reach Smartschool: the host does not resolve, the connection fails or times out (carries the `cause`). A network problem, so not an authentication error |
| `SmartschoolComposeError` | The compose form cannot be used (its tokens or the current user's IDs are missing), or Smartschool does not register a recipient on it (the message names the recipient). From `sendMessage` or `sendReply`, before the message is submitted: nothing was sent. `sendReply` also throws it when Smartschool does not answer with the reply form of the message, or does not take a recipient that the reply form names and `params` leave out off the form (the message names the recipient). Both throw it too when the form does not offer the LVS copy or the delayed send that `params.options` asks for (#47) |
| `SmartschoolSendUnconfirmedError` | `sendMessage` or `sendReply` submitted the message, but Smartschool's answer does not confirm that it was sent, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been sent: check the sent box (for a delayed send, the scheduled box) before sending it again. Not a `SmartschoolComposeError` |
| `SmartschoolAttachmentUploadError` | An attachment upload step fails |
| `SmartschoolPresenceError` | A presence save is rejected (carries the server `errors`), the Presence module refuses or cannot handle a request (an HTML error page instead of JSON), or a class/code/pupil cannot be resolved. Not a session problem |
| `SmartschoolDownloadTooLargeError` | A download given `maxBytes` (`download`, `downloadStream`, `IntradeskService.downloadFile` / `downloadFileStream`, `MessageAttachment.download` / `downloadStream`) turns out larger: Smartschool announces a larger `Content-Length` (before any of it is read), or more than `maxBytes` bytes come in (carries `maxBytes` and the announced `contentLength`). The client stops the transfer. Not a `SmartschoolDownloadError`: Smartschool answered with the file |
| `SmartschoolIntradeskFolderNotFoundError` | `IntradeskService.getFolderListing` is given an ID that Smartschool knows no folder for: an unknown ID, or the ID of a file or a weblink (carries the `folderId`). A `SmartschoolDownloadError` with status `500`, the status Smartschool answers the listing with |

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

A request on a client that was disposed (`client.dispose()`) is not a network problem, and is not reported as one: every request method, and so every service call, `ensureAuthenticated()`, `platformId` and `getCurrentUser()` throw a `StateError` that says the client was disposed, before sending anything (also when they have the answer cached). A request that was running when the client was disposed, and the stream of a download that was being read, fail with it too. A `StateError` is not a `SmartschoolException`: it is a mistake in the app, which should not retry or show "offline" for it, but create a new client.

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

The tests never use the network: they talk to fake Smartschools, and every test file calls `forbidRealNetwork()` (`test/support/no_network.dart`) and gives its clients a temporary cache folder (`tempCacheDir()`); `test/network_guard_test.dart` and `test/cache_dir_guard_test.dart` fail otherwise.

### Live tests

`test/live/` holds a live suite that **really sends messages** on the Smartschool of `credentials.yml`, to check that sending still works there (Smartschool can change its compose flow at any time). It is local and on demand only: `dart_test.yaml` skips the suites tagged `live` without loading them, so `dart test` (and so CI and the pre-commit hook) never runs it. Run it on purpose, with a `credentials.yml` in the package root (without one, it skips):

```bash
# The whole live suite: every live file in test/live/.
dart test -P live test/live

# One live file only.
dart test -P live test/live/messages_live_test.dart
```

The `live` preset runs the tests tagged `live` only, in the paths named on the command line: it names no paths of its own, since a preset's paths replace those of the command line (#62). Without a path, `dart test -P live` loads every test file under `test/` to find the live ones. The preset runs one test file at a time (`concurrency: 1`, which a `-j` on the command line does not override), so that live files take turns in the session. Do not pass `--run-skipped` to a plain `dart test`: that runs the live suite too.

What it checks, on messages it sends to the own account: `sendMessage` is confirmed and arrives once, in the inbox and the sent box; a small attachment; `sendReply` is linked to the message it answers (`hasReply`); `sendReply(all: true)`; `sendReply` moving the recipient from To to CC; `MessageSendOptions(requestReadReceipt: true)` throws before any request; `moveToTrashFrom` out of the archive folder: a message moved to the archive with `moveToArchive` is listed by `getArchiveHeaders`, and after its sent-box copy, `moveToTrashFrom(id, boxType: BoxType.inbox, boxId: <getArchiveBoxId()>)` takes it out of the archive and leaves it in the trash (#64); and `moveToTrashFrom`, which cleans up: moving the sent-box copy of each message to the trash leaves its inbox copy in the inbox, and moving the inbox copy then takes it out of the inbox and leaves the message in the trash (#60).

Its rules, kept by the tests and, on the wire, by a guard on the live client (`test/live/support/live_wire_guard.dart`, a Dio interceptor that refuses a request before it is sent and fails the test):

- Every message goes to the **own account only** (the account of `credentials.yml`, as `getCurrentUserAsRecipient()` and the session name it), in To, CC or BCC, never to a group. The guard refuses registering anyone else on a compose form, checks Smartschool's answer to every registration, and refuses a submit with anyone else registered (a reply form comes with its recipients registered already).
- Replies go only to a message the same run sent to the own account only, after checking that its reply form names the own account alone.
- Every subject starts with `[dartschool test]` and a tag of the run (a reply's with `Re: ` before it).
- No LVS copy (`lvsCopy`) and no delayed send (`sendAt`: the library cannot cancel a scheduled message yet, #58).
- At the end, also when a test failed, the run moves both copies of every message it sent to the trash (a message you send yourself has the same ID in the inbox and the sent box): first the sent-box copies, then the inbox copies (an archived one out of the archive folder, #64), once each, after checking the run's subject and that the own account sent it. It moves them with `moveToTrashFrom`, which names the box of the copy (#60). It never empties the trash: emptying it stays manual.
- It moves to the archive (`moveToArchive`) only the inbox copy of a message it sent, one message per request and once, while the inbox lists it with the run's subject (#64).
- It sends no `quick delete` (`moveToTrash`) at all, and moves no ID it did not send in the same run, `0` included (#61). A `quick delete` names the ID only, Smartschool acts on whichever copy of the ID its session state points to, and one of a copy in the trash deletes it for good: it is never a guaranteed no-op. The guard refuses every `quick delete`, a move of a copy that Smartschool did not list in its box (or in the archive folder that Smartschool's Messages page names, #64) with the run's subject or that the run did not check there, a move out of any other folder, and a second move of a copy; likewise a move to the archive of a message the inbox did not list with the run's subject, of more than one message at once, or a second one.
- It logs in at most once per run, and usually not at all: it keeps its session in `.dart_tool/live_cache/<username>` (gitignored; not the user's `~/.cache/smartschool`, and only the live suite may use it). It never prints a credential or a cookie.
- One live run at a time in that session (#62): the cleanup assumes it is the only run there. A run first takes a lock, `.dart_tool/live_cache/<username>/.lock` (`test/live/support/live_lock.dart`), created atomically and naming the run's tag, PID and host, and deletes it at the end. While another run holds it (a run in another terminal, say, or another live file of the same run if they ran side by side), a run refuses to start: its tests fail before any request, so it sends nothing and does not log in. A lock left behind by a run that was killed is taken over, but only when it is stale for certain: written on this machine by a process that no longer runs. If a run refuses while no other live run is going on (for instance, the system gave the killed run's PID to another process since), delete that file.

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
