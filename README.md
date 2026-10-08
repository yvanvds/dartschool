# flutter_smartschool

An unofficial Dart client library for the [Smartschool](https://www.smartschool.be) school platform. It handles authentication (including TOTP 2FA and birthday-based account verification), cookie persistence, and the mix of XML-protocol and JSON/REST endpoints that Smartschool uses internally.

Repository: [yvanvds/dartschool](https://github.com/yvanvds/dartschool)

> **Unofficial.** This library reverse-engineers the private Smartschool web API. It is not endorsed by or affiliated with Smartschool. Use responsibly.

[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=bugs)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Coverage](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=coverage)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool) [![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=yvanvds_dartschool&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=yvanvds_dartschool)

## Features

- Authenticated Smartschool client with cookie persistence and MFA/account-verification support.
- Full messaging workflow (`MessagesService`): list (also the user's own folders), read, attachments, recipient search, send, replies linked to the original message, archive, trash, labels, reply-all recipient resolution.
- **Event-driven message detection**: notification counter stream with debounced incremental inbox refresh; wires into any notification source (polling bridge or WebSocket).
- Intradesk support (`IntradeskService`): root/folder listing and file download; a folder read by its ID alone, with the folders above it; add a folder, a weblink or uploaded files to a folder and move them to Intradesk's trash again, with checks before each write and creates that are never retried.
- Interactive terminal browser for Intradesk: [example/intradesk_browser.dart](example/intradesk_browser.dart).
- Presence write support (`PresenceService`): mark a pupil **Te laat** / **Te laat zonder geldige reden** for a half-day via Smartschool's internal Presence module (requires Presence-handling access).
- Skore support (`SkoreService`): read the classes of the report models, the courses of a class with the teachers assigned to them, and the teachers that can be assigned; assign a teacher to a course of a class (add a teacher, or give an assignment another teacher), with checks before the save and a save that is never retried; as an admin, share a teacher's gradebook with other teachers (read or write access) or stop sharing it, with checks before the save and a read afterwards that checks it.
- Skore gradebook support (`SkoreGradebookService`): as the logged-in teacher, without admin rights, the teacher's own gradebooks of the current or an earlier school year, the periods (open or closed, and until when) and the pupils of a gradebook, with whether the teacher may change it, and the evaluations of a period with whether and when they are published, the pupils' grades and their feedback; create an evaluation in a period, never published, and save pupils' grades and feedback in it.
- Planner support (`PlannerService`): the planned elements (lessons, assignments, timetable slots, ...) of the own planner, of another teacher, of a class or of a location in a period, optionally of some types only, and the full detail of one element; find the calendar of a class, a teacher or a location by name; the school's assignment types, and the assignments of classes in a period with the planner's workload figures per day (the planner's workload view); in the own planner, fill an empty lesson hour with a new lesson or with a lesfiche of the Lesfiches library and clear the hour again, add an assignment (a test, a task) for classes and move it to the planner's trash again, and change the name and info of an own lesson or assignment, with checks before each write that keep it out of colleagues' elements, and creates, fills, clears and trashes that are never retried.
- Lesfiches support (`LessonContentService`): the lesfiches (lessons and assignments) a teacher keeps in the Lesfiches module, with their labels and courses (named after the school's course list), to plan into the planner; one lesfiche in full, with its private info, weblinks and attachments (downloaded unchanged); and, in the own library, make a complete lesfiche in one create (info, courses, weblinks and attachments, each with when pupils see it), change its name, icon, info, courses and visibility, add, change and remove its weblinks and attachments, and move lesfiches to the module's trash, with checks before each write and creates that are never retried.

---

## Installation

Add the package to `pubspec.yaml`:

```yaml
dependencies:
	flutter_smartschool: ^0.3.8
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

See [example/send_message_lifecycle_example.dart](example/send_message_lifecycle_example.dart) for a complete send → inbox poll → archive → trash flow, on a message it sends to the own account only. It changes that account: it moves both copies of the message to the trash with `moveToTrashFrom`, the sent-box copy first and then the archived inbox copy (`boxType: BoxType.inbox`, with the archive folder's ID from `getArchiveBoxId()` as `boxId`), prints whether each move took the copy out of its box (what `moveToTrashFrom` returns, #96), and checks the trash, archive, inbox and sent-box listings. It never empties the trash.

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

That code is the TOTP secret (letters A-Z and digits 2-7), not the 6-digit code the authenticator app shows afterwards. It may be copied as shown, in groups: white space and hyphens are ignored, as are lower case and `=` padding (`JBSW Y3DP EHPK 3PXP` works as `JBSWY3DPEHPK3PXP`). An `mfa` that is empty or only white space counts as none (an account without 2FA logs in with it). When a login is needed and `mfa` is neither that, a date (`yyyy-mm-dd`), nor such a key, the login throws `SmartschoolInvalidTotpSecretError` before it posts the password; set `mfa` only when the account asks for one of the two. `Credentials.normalizeTotpSecret(key)` checks a key the same way without logging in (for instance where a user types it): it returns the key as the login uses it, or throws that error.

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
| `ensureAuthenticated()` | Checks the session with Smartschool and logs in when it is not (or no longer) accepted: every call sends one light GET (the user's course list, which `platformId` is read from), also when an earlier call found the session valid, so it notices a session that expired or was dropped with `clearCookies()` since (#140). Returns normally once Smartschool accepted the session for it. Throws a `SmartschoolAuthenticationError` subtype when the login fails (a `SmartschoolSessionExpiredError` when Smartschool refuses the session also after logging in again, or the client does not log in, see *Logging in again* below), a `SmartschoolConnectionError` when Smartschool is unreachable |
| `platformId` | `Future<int>` — the user's platform ID (used in Intradesk paths), read from the course list once and cached: once known it sends nothing, so it does not check the session |
| `clearCookies()` | Deletes persisted cookies (use this for explicit logout/session reset). |
| `resetLoginAttempts()` | Lets a client that stopped logging in on its own log in again at once (see *Logging in again* below) |
| `getRaw(path)` | Authenticated GET → response body as `String` |
| `getResponse(path, {query})` | Same GET → the whole `Response<String>`; pass it as `sameSessionAs` to a request that carries state of the page (see *Logging in again* below) |
| `getJson(path, {query})` | Authenticated GET with JSON Accept header → decoded `dynamic` |
| `postJsonResponse(path, {data, query})` | POST with a JSON body (`application/json`; a map or list is encoded) → the whole `Response<String>`, not decoded, whatever its status |
| `postFormRaw(path, fields, {query, retryAfterLogin, sameSessionAs})` | `application/x-www-form-urlencoded` POST → `String` |
| `postFormResponse(path, fields, {query, retryAfterLogin, sameSessionAs})` | Same POST → the whole `Response<String>` (status code, headers, final URL and body) |
| `postFormEncodedRaw(path, body)` | Same but accepts a pre-encoded body string |
| `postMultipartRaw(path, formData, {retryAfterLogin, sameSessionAs})` | `multipart/form-data` POST → `String` |
| `postMultipartResponse(path, formData, {retryAfterLogin, sameSessionAs})` | Same POST → the whole `Response<String>` |
| `postXml(..., {allowEmptyAnswer})` | Posts to the legacy XML dispatcher and returns parsed element maps. Throws for an answer that is not XML: a `SmartschoolUnexpectedPageError` for an HTML page, which says whether it is the login page and keeps its status, title and main heading (#106), also for one with a comment before its doctype and for a piece of a page, such as `<!-- ... -->` and `<div>`s (#110), a `SmartschoolParsingError` for anything else, malformed XML included (#110); with `allowEmptyAnswer`, an empty `200` answer returns no elements instead |
| `download(path, {maxBytes})` | Authenticated GET → the whole file as `Uint8List`. With `maxBytes`, throws `SmartschoolDownloadTooLargeError` as soon as the file turns out larger (see *Downloads* below) |
| `downloadStream(path, {maxBytes})` | Same GET → a `SmartschoolDownload` as soon as the headers are in: `contentLength`, `fileName`, `contentType`, and the content as a `stream` (see *Downloads* below) |
| `notificationCounterUpdates` | `Stream<NotificationCounterUpdate>` — broadcast stream of counter events emitted by any notification source |
| `emitNotificationCounterUpdate({moduleName, counter, isNew, source, timestamp})` | Push a `NotificationCounterUpdate` into the stream; returns `false`, emitting nothing, when `moduleName` is empty or the client was disposed (the stream is closed) |
| `getCurrentUser()` | `Future<SmartschoolUser>` — returns the logged-in user (`id`, `displayName`, `avatarUrl`). Uses cached page data; no extra HTTP requests after the first authenticated call. |
| `dispose({force})` | Closes the notification stream and the underlying Dio client (`force`, the default, cuts off the requests that run). The client cannot be used afterwards: every request method, `ensureAuthenticated()`, `platformId` and `getCurrentUser()` throw a `SmartschoolClientDisposedError` (a `StateError`, "SmartschoolClient was disposed") without sending anything (see *Exceptions*). Calling it again does nothing |
| `isDisposed` | `true` from the moment `dispose()` is called (before its future completes): the client sends no more requests |
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

When Smartschool refuses the session for a request (it expired, or was never there), the client logs in and retries the request once; a retry that Smartschool refuses too throws `SmartschoolSessionExpiredError`. Requests on one client share that login: a request that Smartschool refuses while a login runs waits for it and is then retried in the new session, and fails with the same error when the login fails, so concurrent requests on an expired session send the password and the 2FA code once, and the login counts once toward the limit below. The login loads Smartschool's login page itself, in a new session, and the answers that Smartschool refused do not change the cookie cache, so the password always goes out in the session its login form belongs to. After three logins in a row that did not get the session accepted, the client stops logging in on its own: a refused request throws `SmartschoolSessionExpiredError` at once, without logging in. So that a long-lived client (a daemon, a background queue) gets out of that state by itself, it tries one login again once `loginCooldown` has passed since the last one (5 minutes by default); when the session is accepted it counts from zero again, and when it is not, it waits another cooldown. It does not when Smartschool rejected the credentials at the last login (the password, the 2FA code or the account-verification answer, or the TOTP secret turned out not to be a key at the 2FA step): trying them again every few minutes could get the account locked. Call `resetLoginAttempts()` to let it log in again at once, for instance once the credentials are fixed. A test can pass a fake `clock` to `create` and move it forward instead of waiting.

Pass `retryAfterLogin: false` to `postFormRaw`, `postFormResponse`, `postMultipartRaw` or `postMultipartResponse` for a request that carries state of the session it was prepared in, such as the tokens of Smartschool's compose form: a retry would send that state in a session it does not belong to. When Smartschool refuses the session for such a request, it is neither retried nor used to log in again: it throws `SmartschoolSessionExpiredError` at once. The client remembers that the session was refused, though: its next request, whatever it is, logs in before it is sent, or waits for the login that runs (#134). So calling the write again sends it once, in a new session, also when it is the first request of the call (as for `LessonContentService.createLesson` without courses or attachments). The same holds after a login that failed. A request that the client logged in for that way and that Smartschool refuses all the same throws `SmartschoolSessionExpiredError` without a second login, as a refused retry does; at the limit on logins in a row (above), it goes out as it is. A request sent with `sameSessionAs` (below) does not log in first. `MessagesService.sendMessage` sends its steps after loading the compose form this way, and the services send their creates so (`postJsonResponse` takes `retryAfterLogin` too).

That covers the request being refused. A login replaces the client's session whichever request it runs for, and Smartschool then accepts such a request in the new session, stale state and all. Pass `sameSessionAs` too, the earlier answer the state comes from (for instance the page, loaded with `getResponse`), for a request that must go out only in that answer's session: when a login started on the client since that answer's request went out, or one runs, the request is not sent and throws `SmartschoolSessionExpiredError` at once. A login that runs or failed counts as well as one that completed: the login replaces the session cookie as soon as it loads its login form, and a login that failed after Smartschool accepted it (the connection dropped on its last answer) leaves the new session behind. `MessagesService.sendMessage` and `sendReply` send their steps after loading the compose form this way too.

### Downloads

`download(path)` (and `IntradeskService.downloadFile`, `MessageAttachment.download`) returns the whole file in memory. `downloadStream(path)` (and `IntradeskService.downloadFileStream`, `MessageAttachment.downloadStream`) returns a `SmartschoolDownload` as soon as the headers of Smartschool's answer are in, before the file is read:

- `contentLength`: the size Smartschool announces (`Content-Length`), or `null` when it announces none (or the content comes in encoded, such as gzip);
- `fileName`: the name in `Content-Disposition` (`filename*` in UTF-8 or ISO-8859-1 when there is one, else `filename`), as Smartschool sends it: check it before using it as a path;
- `contentType`: as Smartschool gives it. Intradesk answers `application/x-www-form-urlencoded` for every file, so tell the type from the name;
- `stream`: the content, as it comes in. Pausing the subscription pauses the transfer; cancelling it, or calling `cancel()` on the download, stops the transfer and closes the connection (Dio alone would read the answer to its end). Until it is listened to, the transfer waits, as while it is paused: no more comes in than the few chunks that arrived while the client handled the headers, so it may be listened to later, such as once the file it is written to is open. Read it or cancel it: until then, the download keeps its connection open.

Pass `maxBytes` to any of them to refuse a larger file: the download fails with a `SmartschoolDownloadTooLargeError` (carrying `maxBytes` and the announced `contentLength`) as soon as the file turns out larger. When Smartschool announces a larger size, that happens before any of it is read (`downloadStream` throws it); otherwise the bytes are counted as they come in, and the download fails once more than `maxBytes` came in (`stream` ends with the error, after at most `maxBytes` bytes). Either way the client stops the transfer. Every byte counts, also one that came in before `stream` was listened to, so `maxBytes` bounds what comes in, and what the client holds in memory, to `maxBytes` and a few chunks, whenever the stream is listened to. The size in an Intradesk listing may be out of date; `maxBytes` checks the file itself.

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

See [example/notification_listener_full_message_example.dart](example/notification_listener_full_message_example.dart) for a complete runnable demo.
See [example/message_change_stream_example.dart](example/message_change_stream_example.dart) for a stream-binding walkthrough with synthetic events.

### Static parsers (exposed for testing)

| Method | Description |
|---|---|
| `parseHiddenFields(htmlBody)` | Extracts all `<input type="hidden">` name→value pairs from an HTML page. |
| `parseComposeCurrentUserIds(htmlBody)` | Extracts `(userId, ssId, userLt)` from the `window.tinymceInitConfig` block. |
| `parseArchiveBoxIdFromMessagesHtml(htmlBody)` | Extracts the archive folder box ID from the Messages module HTML (what `getArchiveBoxId` reads when the folder tree names no archive, #141). |
| `parseFolders(json)` | Reads the folder tree of a `requestmovelist` answer (its JSON data) into the `MessageFolder`s of `getFolders` (#136). Throws a `SmartschoolParsingError` for a tree it cannot read. |
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

// Read a folder by its ID alone: its own entry, and the folders above it
// (#132)
final folder = await intradesk.getFolder(folderId);
print('${folder.name}, may add: ${folder.capabilities.canAdd}');
final path = await intradesk.getFolderPath(folderId);
print(path.map((f) => f.name).join(' > ')); // 2. SMA > tests

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

// Add a folder, a weblink in it and a file (#128). Intradesk renames an
// item whose name is taken ("Toetsen (1)"), so use what it answers.
final toetsen = await intradesk.createFolder(
  parentFolderId: sub.folders.first.id,
  name: 'Toetsen',
  color: 'blue',
);
await intradesk.createWeblink(
  parentFolderId: toetsen.id,
  name: 'Oefenplatform',
  url: 'example.com/oefenen', // sent as http://example.com/oefenen
);
final upload = await intradesk.uploadFiles(
  parentFolderId: toetsen.id,
  filePaths: ['toets 1.pdf'],
);
print(upload.files.map((f) => f.name)); // [toets 1.pdf]

// And move it to Intradesk's trash again (kept there for 30 days)
await intradesk.trashFile(upload.files.single.id);
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getRootListing()` | `Future<IntradeskListing>` | Root-level folders, files, and weblinks. |
| `getFolderListing(folderId)` | `Future<IntradeskListing>` | Folders, files, and weblinks inside the identified folder. Throws a `SmartschoolIntradeskFolderNotFoundError` when Smartschool knows no folder with that ID (an unknown ID, or the ID of a file or a weblink). |
| `getFolder(folderId)` | `Future<IntradeskFolder>` | The folder itself, read by its ID alone (#132): its entry in the listing of the folder above it, with its name, `confidential`, `inConfidentialFolder`, `parentFolderId` and `capabilities` (`canAdd`: whether the user may add to it). Two requests: the folder's parents, then the listing of its parent (the root listing for a folder at the root). |
| `getFolderPath(folderId)` | `Future<List<IntradeskFolder>>` | The folders from the root down to the folder, the folder itself last, each as the listing of the one above it gives it (#132): the path the web client shows. The parents, then a listing per level. |
| `getFolderParentIds(folderId)` | `Future<List<String>>` | The IDs of the folders above the folder, the folder at the root first and its parent last (`folders/{id}/parents`, one request, #132). `[]` for a folder at the root, **and for a folder in the trash** (seen live), which `getFolder` and `getFolderPath` tell apart. |
| `getRootCapabilities()` | `Future<IntradeskFolderCapabilities>` | What the user may do at the root (#138): the platform's capabilities (`canAdd`, `canAddConfidentialFolder`, `canManage`), which the root has instead of an entry. Read from the configuration of the Intradesk page (`GET /intradesk`, `SMSC.vars.config.ownPlatform.capabilities`, as the web client reads them; one request of about 100 KB). A `SmartschoolDownloadError` for another status than `200`, a `SmartschoolParsingError` for a page without them. |
| `downloadFile(fileId, {maxBytes})` | `Future<Uint8List>` | Raw bytes of the identified file. With `maxBytes`, throws a `SmartschoolDownloadTooLargeError` as soon as the file turns out larger (see *Downloads* above). A `SmartschoolDownloadError` with status `404` when there is no such file. |
| `downloadFileStream(fileId, {maxBytes})` | `Future<SmartschoolDownload>` | The same file as a stream, with its size and name, as soon as the headers are in (see *Downloads* above). |
| `createFolder({parentFolderId, name, color = 'yellow', confidential = false})` | `Future<IntradeskFolder>` | Adds a folder to the folder `parentFolderId` (`''` for the root) and returns the folder Intradesk made. `color` is one of `IntradeskService.folderColors` (`red`, `brown`, `orange`, `yellow`, `green`, `aqua`, `blue`, `purple`, `pink`, `white`, `black`). With `confidential`, a confidential folder (`folders/as-confidential`): only in a confidential folder, or at the root with the platform's `canAddConfidentialFolder`. Reads the parent first (#138, see below). |
| `createWeblink({parentFolderId, name, url, icon = 'earth'})` | `Future<IntradeskWeblink>` | Adds a weblink to a folder (not the root) and returns the weblink Intradesk made. `url` is sent as the web client sends it (`normalizeWeblinkUrl`): without white space, with `http://` in front when it has no `http(s)://`. Intradesk does not check `icon`, but needs one. Reads the parent first (#138, see below). |
| `uploadFiles({parentFolderId, filePaths})` | `Future<IntradeskUploadResult>` | Uploads files into a folder (not the root), each under the last segment of its path, and returns the files Intradesk added (`files`) and those it did not take, with its reason (`failures`). Asks for a new upload directory for every call, uploads each file into it (`/Upload/Upload/Index`, the step message attachments use), then has Intradesk take the directory once (`files/upload`). Reads the parent first, before the upload steps (#138, see below). |
| `trashFolder(folderId)` / `trashWeblink(weblinkId)` / `trashFile(fileId)` | `Future<void>` | Moves the item to Intradesk's trash (`.../trash`, answered with `204`, also for an item in the trash already). Intradesk keeps its trash for 30 days; the service never deletes for good. A `SmartschoolIntradeskItemNotFoundError` (with the `kind` and the `id`) when Intradesk has no item of that kind with that ID: a made-up ID, or the ID of an item of another kind, such as a file's ID given to `trashFolder` (#133). Nothing was moved then. |
| `isAllowedName(name)` | `bool` (static) | Whether Smartschool allows the name of a folder, weblink or file: none of `/ : * ? " \ < > \|`, no dot at its start or end (the web client's check). |
| `normalizeWeblinkUrl(url)` | `String?` (static) | The address as the web client sends it, or `null` when it would refuse it. |

**A folder by its ID (#132).** A folder's own entry otherwise only comes with the listing of the folder above it, and nothing names that folder. Smartschool has no request for one folder (`GET .../folders/{id}` answers the web client's page), so `getFolder` and `getFolderPath` do what the web client does when it opens a folder by its address: ask for the folder's parents and list them. All three were tried live on 2026-10-07.
- **Errors**: an `ArgumentError`, before anything is sent, for an ID that is not a UUID (Smartschool answers it with a bare `500`). A `SmartschoolIntradeskFolderNotFoundError` with `statusCode` `404` for an ID Smartschool knows no folder for (an unknown ID, or the ID of a file or a weblink). From `getFolder` and `getFolderPath`, the same error with `statusCode` `200` when a listing does not hold the folder where its parents put it: a folder in Intradesk's trash (Smartschool answers its parents with `[]`, as for a folder at the root, and the root listing does not hold it; seen live), one the user does not see, or one moved in between. A listing that fails throws as `getFolderListing` does.
- The creates read their parent with it before they send anything (#138, see below).

**The writes (#128).** All were tried live on 2026-10-05, in a test folder.
- **A name that is taken is not refused**: Intradesk adds the item under a new name, `name (1)` (`name (1).ext` for a file). The name of the item a create returns can differ from the one asked for; tell items by their IDs.
- **A create is sent once**: never again after logging in again, nor retried otherwise, since a second one adds a second item. `uploadFiles` uses a new upload directory for every call: Intradesk takes the files of a directory again every time it is told to. A move to the trash is retried once after logging in again: Intradesk answers it for an item in the trash already with `204` too.
- **Checks before sending**: Intradesk answers a bad name, colour, icon or parent with a bare HTTP `500` that does not say why, so the writes throw an `ArgumentError`, before anything is sent, for an empty name or one `isAllowedName` refuses, a colour not in `folderColors`, an empty icon, an address `normalizeWeblinkUrl` refuses, a parent ID that is not a UUID, a weblink or a file at the root (the web client offers neither), and a file that does not exist or two files with the same name.
- **The parent is read first (#138).** `createFolder`, `createWeblink` and `uploadFiles` read the folder they add to (`getFolder`: its parents and the listing of the folder above it, two requests; at the root `getRootCapabilities`, one) and add only what Intradesk's web client offers there (its "Toevoegen" button and right-click menu, read in its bundle on 2026-10-07):

  | Adds | In an ordinary folder | In a confidential folder | At the root |
  |---|---|---|---|
  | an ordinary folder | with `canAdd` | never (`confidentialParent`) | with the platform's `canAdd` |
  | a confidential folder | never (`ordinaryParent`) | with `canAdd` | with the platform's `canAddConfidentialFolder` |
  | a weblink, a file | with `canAdd` | with `canAdd` | never (`ArgumentError`) |

  Anything else is a `SmartschoolIntradeskAddRefusedError`, before anything of the write is sent (also no upload step): its `reason` (`IntradeskAddRefusalReason.cannotAdd`, `cannotAddConfidentialFolder`, `ordinaryParent`, `confidentialParent`), the `parent` as it was read (`null` at the root) and the `capabilities` the rule looked at. It is a `SmartschoolIntradeskWriteRefusedError` with `statusCode` `null` (nothing was sent to Intradesk), so a `catch` of that type still catches it, as it caught Intradesk's `400` for a confidential folder in an ordinary one, which is no longer sent. A parent the read does not find is a `SmartschoolIntradeskFolderNotFoundError` before anything is sent: `statusCode` `404` for an unknown ID (Smartschool answered the create of one with a bare `500` before), `200` for a folder in Intradesk's trash or one the user does not see. A read that fails otherwise throws as the read does. Only Intradesk's answer to a confidential folder in an ordinary one was seen live (`400`); the live account is an administrator, with `canAdd` on every folder it sees, none of them confidential.
- **Errors**: `SmartschoolIntradeskWriteRefusedError` (HTTP `400`–`499`, with Intradesk's reasons in `violations`, such as "De URL die je hebt ingegeven is niet geldig."; nothing made); its subclass `SmartschoolIntradeskAddRefusedError` when the parent does not allow the create (#138, above; nothing sent, `statusCode` `null`); its subclass `SmartschoolIntradeskItemNotFoundError` for a move to the trash that Intradesk answers with `404` (#133, see below); `SmartschoolIntradeskFolderNotFoundError` for a parent Smartschool knows no folder for, or one in the trash (nothing made); `SmartschoolAttachmentUploadError` when the upload step fails, with Smartschool's text in `serverMessage` (Intradesk was not told to take the files); `SmartschoolIntradeskSaveUnconfirmedError` when the write went out but Intradesk's answer does not confirm it (a bare `500` for another reason, an answer that is not the item made, or no answer): list the folder before trying again.
- **A move to the trash of an ID Intradesk has no such item for (#133).** Intradesk keeps folders, weblinks and files apart (`folders/{id}/trash`, `weblinks/{id}/trash`, `files/{id}/trash`), and answers the move of an ID it has no item of that kind for with `404` (`{"status":404,"title":"Not Found","detail":"","type":""}`), and moves nothing: a made-up ID, the ID of a file or a weblink given to `trashFolder`, of a folder or a file given to `trashWeblink`, of a folder or a weblink given to `trashFile`, also when that item is in the trash (all seen live on 2026-10-07). That is a `SmartschoolIntradeskItemNotFoundError`, with the `kind` asked for (`IntradeskItemKind.folder`, `weblink` or `file`) and the `id`. So "there is no such item" is told apart from a move that went through (`204`, also for an item in the trash already, of its own kind) and from one that may or may not have gone through (`SmartschoolIntradeskSaveUnconfirmedError`). It is a `SmartschoolIntradeskWriteRefusedError` (status `404`), as such an answer was before, so a `catch` of that type still catches it; not a `SmartschoolIntradeskFolderNotFoundError`, which is the error of a read (a `SmartschoolDownloadError`).
- Not covered: renames, moves, copies, colour changes, a new version of a file, rights, restoring from the trash, and deleting for good. Not seen live: a weblink, folder or file at the root, Intradesk's answer to a write in a folder without `canAdd` or to an ordinary folder in a confidential one (the service refuses both itself since #138), a confidential folder Intradesk made, a non-empty `exceptions` in an upload's answer, and a move to the trash of an item the user may not manage (`capabilities.canManage` false, #139).

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

> **Access requirement:** this only works when the signed-in account may set the half-days of the class: **`userCanConfirm`** is true for it in the module config (`getConfig()`), as for an absence administrator (#121). **`userCanRecord` is not that right**: seen live (2026-10-04), a teacher account with its absence-administrator rights switched off had `userCanRecord` for all 88 classes it listed and `userCanConfirm` for none, and the module refused its half-day save ("U heeft geen rechten om afwezigheden te bevestigen voor deze leerling. Contacteer uw beheerder."); with the rights on, `userCanConfirm` was true for all 120. `setLate` and `setPresent` refuse a class without `userCanConfirm` before they send anything, with a `SmartschoolPresenceNoConfirmRightError`. A caller that offers the write (such as smartschool-mcp's `setLate` / `setPresent` tools, yvanvds/smartschool-mcp#95) gates it on `userCanConfirm`, not on `userCanRecord`:
>
> ```dart
> final config = await presence.getConfig();
> final writable = config.allowedClasses.where((c) => c.userCanConfirm);
> ```

> **Identity note:** the Presence module speaks Smartschool's **internal `userID`** (e.g. `11110`), which is *not* the public API's `AccountID` / `RegisterID` / `UID`. You supply the internal `userId` and the class `groupID` (classes map to the public API by `adminNumber`).

```dart
final presence = PresenceService(client);

// Mark internal userID 11110 (class groupID 298) late this morning, unless
// the half-day holds another status than nothing or "Aanwezig" (#105).
final saved = await presence.setLate(
  userId: 11110,
  classGroupId: 298,
  date: DateTime(2026, 6, 1),
  part: DayPart.morning,
  motivation: 'Overslept',
  onlyReplacing: {
    PresenceService.nothingRecorded,
    PresenceService.presentCodeName,
  },
);
// The half-day as stored, from the save's answer, and as it was before.
print('${saved?.codeId} (was ${saved?.before?.codeId})');

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
| `setLate({userId, classGroupId, date, part, withoutValidReason, motivation, onlyReplacing})` | `Future<PresenceSavedHalfDay?>` | Mark a pupil late for a half-day; `withoutValidReason` selects the "Te laat zonder geldige reden" alias. With `onlyReplacing`, only changes a half-day that holds one of those statuses (see below). Returns the half-day as stored (#105). |
| `setPresent({userId, classGroupId, date, part, motivation, onlyReplacing})` | `Future<PresenceSavedHalfDay?>` | Mark a pupil present ("Aanwezig") — useful to clear a status. `onlyReplacing` and the result as for `setLate`. |
| `getConfig({forceRefresh})` | `Future<PresenceConfig>` | Module config: schoolyear ref date + the classes the account may record, each with `userCanConfirm`, the right to set its half-days (#121). Cached. |
| `getAllCodes(structId, {forceRefresh})` | `Future<List<PresenceCode>>` | Presence status codes for a school structure. Cached per structure. A grouping class has no structure: see `PresenceHalfDay.statusName` and `PresencePupil.officialClassId` (#126). |
| `getClassPupils({classGroupId, date, schoolyearRefDate})` | `Future<PresenceClassPupils>` | Pupils and their am/pm half-day cells for a single day: a `List<PresencePupil>` with what the module said about the class that day (`saveIsAllowed`, `errorMessage`, `classRef`). When it lists no pupils, `errorMessage` says why (#104). Each pupil has its `officialClassId` and each half-day its `statusName`, also for a grouping class (#126). |

Status codes are **not hard-coded** — their numeric IDs are per-school/per-structure, so they are resolved dynamically by name (`Te laat`, `Te laat zonder geldige reden`, `Aanwezig`). The service handles both updating an existing half-day cell and creating one where none exists, and surfaces a non-empty server `errors[]` as a `SmartschoolPresenceError`.

**Leaving other statuses alone (#105).** A half-day is an official record. `setLate` and `setPresent` read the class right before they save; without `onlyReplacing` they save over whatever the half-day holds, also an absence the secretariat recorded (a doctor's note, say). Pass `onlyReplacing` with the statuses the half-day may hold, by name (case-insensitive): `PresenceService.presentCodeName`, `lateCodeName`, `lateWithoutReasonAliasName`, any other code name of the school, or `PresenceService.nothingRecorded` (`""`) for a half-day that holds nothing. For any other status, as read right before the save, the call throws a `SmartschoolPresenceChangeRefusedError` that names it (`heldStatus`, `halfDay`) and sends nothing. An alias is a status of its own: `{lateCodeName}` does not allow "Te laat zonder geldige reden". `PresenceService.statusNameOf(halfDay, codes)` gives the name a half-day's status goes by, from the codes of its structure (`getAllCodes`): `null` for a code that is not among them, which `onlyReplacing` never allows.

**What was stored (#105).** Both return a `PresenceSavedHalfDay`, the record the module answered the save with (`presenceId`, a new one for a half-day without a record, `codeId` / `aliasId`, `motivation`), with `before`, the half-day as read right before the save (`null` when it had no record). Nothing more is read for it. `null` when the answer holds no record of the half-day (the save itself was confirmed: no `errors`, and an HTTP status in `200`–`299`, #143): read the class to see what it holds. The answer's shape is the one the module's web client reads; it was not captured from a live save for this.

### Errors

An expired session and a missing access right need opposite actions, so they arrive as different types:

- `SmartschoolPresenceError` — the save came back with a non-empty `errors[]` (whatever the HTTP status of that answer, #143), or a class, code or pupil could not be resolved (e.g. a class the account may not record for), or an answer of the module could not be read (its subtype `SmartschoolPresenceUnreadableAnswerError`, below). The session was accepted: signing in again does not help. For a refused save, `saveErrors` has the module's errors typed (#109): each a `PresenceSaveError` with the module's reason (`message`, in Dutch, as its web client shows it) and the record that was not saved (`date`, `part`, `userId`, and `pupilName`, the pupil's name); `errors` has their messages as text. The pupil's name is in neither `errors` nor the error's message or `toString()`, so not in a log of it. Its subtypes, for which nothing was sent: `SmartschoolPresenceNoConfirmRightError`, the account may not set the half-days of the class (`getConfig` lists it with `userCanConfirm` false, #121), with `userId`, `classGroupId`, `date`, `part` and `classRef` (the class as `getConfig` lists it), after reading only the config (again, when the service had one from before the call, so that rights granted during the session count); `SmartschoolPresenceChangeRefusedError`, the half-day holds a status that `onlyReplacing` does not allow (#105); and `SmartschoolPresencePupilNotFoundError`, the class, as `setLate` / `setPresent` read it right before the save, does not list the pupil on that day, such as a pupil whose movement into the class ended (#116). It carries `userId`, `classGroupId` and `date`, and, when the module listed no pupils for the class on that day, its `errorMessage` (the reason, such as a day after today) and `saveIsAllowed`.
- `SmartschoolPresenceUnreadableAnswerError` (#137), a `SmartschoolPresenceError` — an answer of the module could not be read: `kind` (`PresenceUnreadableAnswerKind`) says whether it was `empty`, an `html` page instead of JSON (such as Smartschool's generic `500` error page, or a proxy's `502` page; `title` and `heading` keep what the page says, masked as for `SmartschoolUnexpectedPageError`), `malformedJson` (anything else that is not valid JSON), or `errorStatus` (#143: valid JSON with an HTTP status outside `200`–`299`, such as a `500` or a proxy's `502` with `{"message": ...}`, which is never read as Presence data: no config, codes or class, nothing cached, no confirmed save), `statusCode` the HTTP status (a `429` or `5xx` gets here: the client only logs in again on a `401` or a redirect to the login chain) and `path` the endpoint. The body decides first: an empty, HTML or broken answer keeps its kind whatever its status. A save answered with the module's own non-empty `errors[]` is a refused save (a plain `SmartschoolPresenceError` with `saveErrors`) whatever its status. Unlike the others it can be gone a moment later, so a caller can retry it (a limited number of times: the module also answers a request it cannot handle with its `500` page). For a read (`getConfig`, `getAllCodes`, `getClassPupils`, and the reads `setLate` / `setPresent` start with), nothing changed on Smartschool. For the save (`path` `/Presence/Class/savePupilsPresences`), it is **not known** whether it landed; calling `setLate` / `setPresent` again is safe: the call reads the class again first, so it sends the half-day's record when the first save stored one, which the module updates rather than adding a second one. With `onlyReplacing`, let it allow the status the call sets (such as `PresenceService.lateCodeName`), as the second call may find what the first stored.
- `SmartschoolSessionExpiredError` (a `SmartschoolAuthenticationError`) — Smartschool answered with its login chain instead of the data, also after the client logged in again and retried the request once. The request was not carried out: sign in again and retry.

```dart
try {
  await presence.setLate(/* … */);
} on SmartschoolSessionExpiredError {
  // Sign in again (e.g. a new SmartschoolClient) and retry.
} on SmartschoolAuthenticationError {
  // Logging in failed: check the credentials.
} on SmartschoolPresenceNoConfirmRightError catch (e) {
  // The account may not set the half-days of e.classRef (userCanConfirm is
  // false): nothing was sent.
} on SmartschoolPresenceChangeRefusedError catch (e) {
  // onlyReplacing left the half-day alone: it holds e.heldStatus.
} on SmartschoolPresencePupilNotFoundError catch (e) {
  // The class does not list the pupil on that day (e.errorMessage says why
  // when it listed no pupils at all): nothing was sent.
} on SmartschoolPresenceUnreadableAnswerError catch (e) {
  // An answer could not be read (e.kind, e.statusCode, such as a proxy's
  // 502): try again later. Calling setLate again is safe, also when it was
  // the save (e.path) and it landed.
} on SmartschoolPresenceError catch (e) {
  // Permanent: show e.message (and e.errors, the module's reasons) to the
  // operator; e.saveErrors names the half-days a refused save did not store.
} on SmartschoolConnectionError {
  // Smartschool is unreachable: retry later.
}
```

### Example

```bash
dart run example/set_late_example.dart
```

---

## `SkoreService`

Reads Smartschool's **Skore** module (grading and reports): what Skore shows under Rapporten > Modellen > (model) > Leden > (group) > (class). And assigns a teacher to a course of a class there (`addTeacher`, `replaceTeacher`). It also reads the gradebooks of a teacher with the teachers they are shared with, and shares a gradebook or stops sharing it (`shareGradebook`, `unshareGradebook`), as Skore's "share gradebooks" manager does (Puntenboeken > the share button next to a teacher). Nothing else changes Skore, and nothing deletes an assignment or a gradebook.

> **Access requirement:** the account needs access to Skore's report management (Rapporten > Modellen) and its gradebooks management (Puntenboeken), as a Skore administrator has. An account can have one without the other (`SkoreAccessArea.reportManagement`, `.gradebookManagement`); `checkAccess()` tells which ones it has. Skore answers every request of a teacher without the rights by sending it on to Smartschool's start page (a redirect to `/?module=Homepage`, seen live, #91), never with an empty list: every call then throws a `SmartschoolSkoreAccessDeniedError` that names the part of Skore (so does an answer with HTTP 403). What Skore answers a pupil, and an account with only one of the two rights, was not captured.

```dart
final areas = await SkoreService(client).checkAccess(); // empty without rights
if (!areas.contains(SkoreAccessArea.reportManagement)) {
  print('No rights for Skore report management.');
}
```

> **Identity note:** class and course IDs are Skore's own. A teacher ID is the Smartschool user ID: the middle part of the ID `getCurrentUser()` reads (`4069_146_0` → `146`). A gradebook ID is the ID of the assignment that holds the gradebook (`SkoreAssignment.id`); its owner is that assignment's teacher.

```dart
final skore = SkoreService(client);

final classes = await skore.getClasses();          // List<SkoreClass>
final courses = await skore.getCourses(classes.first.id); // List<SkoreCourse>
for (final course in courses.where((c) => !c.isGroupHeader)) {
  final names = course.assignments.map((a) => a.teacherName).join('; ');
  print('${'  ' * course.depth}${course.label}: $names');
}
final teachers = await skore.getTeachers();        // List<SkoreTeacher>
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getClasses()` | `Future<List<SkoreClass>>` | The classes of all report models, with their model and group. |
| `getCourses(classId)` | `Future<List<SkoreCourse>>` | The courses of a class, in Skore's order, each with its `assignments`. Empty for a class without a course structure, and for a class ID Skore does not know (Skore answers both the same way). |
| `getTeachers()` | `Future<List<SkoreTeacher>>` | The teachers that can be assigned to a course. |
| `addTeacher({classId, courseId, teacherId})` | `Future<SkoreSavedAssignment>` | Adds the teacher to the course of the class: a new assignment (as the green **+** does), which holds all pupils of the class. Returns it, with the course as read before the save. |
| `replaceTeacher({classId, courseId, assignmentId, teacherId})` | `Future<SkoreSavedAssignment>` | Gives an assignment of the course another teacher (as the teacher drop-down does). The assignment keeps its ID, and its gradebook stays. Returns it, with the course and the assignment as it was (`replaced`: the previous teacher), as read before the save. |
| `getGradebookShares(ownerId)` | `Future<List<SkoreGradebookShares>>` | The gradebooks of a teacher, each with the teachers who may read it and those who may read and change it. Empty for a teacher without gradebooks, and for a user ID Skore does not know. |
| `shareGradebook({ownerId, gradebookId, teacherId, access})` | `Future<SkoreGradebookShareChange>` | Shares a gradebook of the owner with the teacher, with `SkoreShareAccess.read` or `.write`; a teacher with the other access is moved. Returns the gradebook as read again, with the gradebook as read before the change and whether anything was saved. |
| `unshareGradebook({ownerId, gradebookId, teacherId})` | `Future<SkoreGradebookShareChange>` | Stops sharing a gradebook of the owner with the teacher. Returns the gradebook as read again, with the gradebook as read before the change and whether anything was saved. |
| `checkAccess()` | `Future<Set<SkoreAccessArea>>` | The parts of Skore the account can use, for a status check: reads the teachers (report management) and the account's own gradebooks (gradebook management), and leaves out a part whose read Skore refuses. Any other failure is thrown. Empty for a teacher without Skore's management rights (seen live, #91). |

A course code is **not** unique within a class: a course and its sub-course can both end in the same `[CODE]`. Tell them apart by `id` (or `label`). Group headers (`isGroupHeader`) are headings for the courses under them and cannot get a teacher.

### Assigning a teacher

> **Warning:** Skore drives the school's grading and reports, and has no test instance. These calls change the live Skore.

```dart
// A new assignment on a course of a class.
final added = await skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 146);

// Another teacher on an existing assignment: the assignment and its gradebook stay.
final saved = await skore.replaceTeacher(
    classId: 2516, courseId: 1588, assignmentId: added.id, teacherId: 320);

// The change in its context, as read before the save: no second read needed.
print('${saved.teacherName} instead of ${saved.replaced?.teacherName} '
    'on course "${saved.course.label}" of class ${saved.course.classId}');
```

Both return a `SkoreSavedAssignment`: the assignment saved (a `SkoreAssignment`: `id`, `teacherId`, `teacherName` of its new teacher), with what the call read before the save (#102): `course`, the `SkoreCourse` as it was (its `label`, `code`, `depth`, and its `assignments` before the change), and, for `replaceTeacher`, `replaced`, the assignment with the teacher it had (`null` for `addTeacher`). So reporting the change needs no second read of the class, which could differ from what the call checked.

Both go through Skore's `saveOwner`. Before it, they read the class (`getCourses`) and the teachers (`getTeachers`) again, and refuse with a `SmartschoolSkoreChangeRefusedError`, saving nothing:

- a course that is not in the class (also for a class ID Skore does not know), or that is a group header;
- for `replaceTeacher`, an `assignmentId` that is not one of that course in that class;
- a teacher who already has an assignment on the course (for `replaceTeacher`, the current teacher of the assignment too);
- a teacher who is not in `getTeachers()`.

`replaceTeacher` then asks Skore whether the current teacher works with "Mijn lesgroepen" for the course, as Skore's web client does, and refuses with a `SmartschoolSkoreMyGroupsError` (a `SmartschoolSkoreChangeRefusedError`) when they do. Skore's web client offers to delete those groups, which cannot be undone; the service never does: handle them in Skore first.

The save is sent **once**: it is never retried, not even after logging in again, since a repeated add adds a second assignment. Skore answers it with the assignment and its teacher; when the answer does not confirm the save (another teacher, for a replace another assignment, or no usable answer at all), the call throws a `SmartschoolSkoreAssignmentSaveUnconfirmedError` (a `SmartschoolSkoreSaveUnconfirmedError`): the change may or may not have been saved, so read the class again before trying again. The error carries what the call read before the save (#120), as the result would have: `course` (the `SkoreCourse` as read before the save: its `label`, and its teachers then), `replaced` (for `replaceTeacher`, the assignment with the teacher it had; `null` for `addTeacher`) and `teacher` (the `SkoreTeacher` it was saving: ID and name). So telling the user what may have been saved, and what to look for, needs no read of your own: a read after a save that may have gone through cannot tell what was there before. Calling the method again is safe in itself: it reads the class first, and refuses a teacher who already has an assignment on the course. The checks and the save are separate requests, so do not change the same course from two places at once.

The example asks for confirmation before it saves, and reads the class again afterwards:

```bash
dart run example/skore_assign_teacher_example.dart CLASS_ID COURSE_ID TEACHER_ID [ASSIGNMENT_ID]
```

### Sharing a gradebook

> **Warning:** these calls change the live Skore too, and need Skore admin rights.

```dart
// Every year: share the titularis's "Digitale vaardigheden" gradebook of a
// class with the other teachers of the class.
final gradebooks = await skore.getGradebookShares(146); // List<SkoreGradebookShares>
final shared = await skore.shareGradebook(
    ownerId: 146, gradebookId: 34826, teacherId: 320, access: SkoreShareAccess.write);
print('${shared.readerIds} ${shared.writerIds}');

// The change in its context, as the call read it: no read of your own needed.
print(shared.saved
    ? 'now ${shared.accessAfter?.name} access (had: ${shared.accessBefore?.name ?? 'none'})'
    : 'already had ${shared.accessBefore?.name} access; nothing saved');

// And undo it.
await skore.unshareGradebook(ownerId: 146, gradebookId: 34826, teacherId: 320);
```

Both return a `SkoreGradebookShareChange`: the gradebook as read again after the save (a `SkoreGradebookShares`: `readerIds`, `writerIds`, ...), with what the call read and did (#103): `before`, the gradebook as it read it before the change (the one it checked), `teacherId`, the teacher whose access it changed, with their `accessBefore` and `accessAfter` (`SkoreShareAccess?`, `null` for none), and `saved`, whether it sent a save (and Skore confirmed it). So reporting the change ("now write access instead of read access", "already had write access; nothing saved", "unshared (had read access)") needs no read of the owner's gradebooks of your own, which could differ from what the call checked.

Both go through Skore's `saveShared`. The save holds **this gradebook only**, with its complete new readers and writers: the teachers it is already shared with keep their access, unless the change is about them, and the owner's other gradebooks are not touched. A teacher has one kind of access: sharing with write access takes them off the readers, and the other way round.

Before the save, they read the owner's gradebooks again, and refuse with a `SmartschoolSkoreChangeRefusedError`, saving nothing:

- the owner as the teacher (Skore never offers the owner as a reader or a writer);
- a gradebook that is not one of the owner's (also for a user ID Skore does not know), so a gradebook is never saved under another owner;
- for `shareGradebook`, a teacher who is not in `getTeachers()`. `unshareGradebook` can take off a teacher who is no longer in it, such as one who has left the school.

When nothing changes (already shared with that access, or not shared when unsharing), nothing is saved and the gradebook is returned as read, with `saved` `false` (and `before` the same gradebook).

Skore answers the save with `state` 1. The call then reads the owner's gradebooks again and checks that the gradebook has exactly the readers and writers saved; when the answer or that read does not confirm the save, it throws a `SmartschoolSkoreShareSaveUnconfirmedError` (a `SmartschoolSkoreSaveUnconfirmedError`): read the gradebooks again before trying again. The error carries what the call read before the save (#120): `before`, the gradebook as read before the change (its `className` and `courseName`, and its readers and writers then), and `teacherId`, with their `accessBefore`. Since the save holds the complete lists, sending it again does not change the outcome, so (unlike `addTeacher` and `replaceTeacher`) it is retried once after logging in again, as a read is. The checks and the save are separate requests, so do not change the shares of the same gradebook from two places at once.

The example shows the gradebook, asks for confirmation before it saves, and prints the change from the result (it reads the gradebooks again only when the save was not confirmed):

```bash
dart run example/skore_share_gradebook_example.dart OWNER_ID GRADEBOOK_ID TEACHER_ID read|write|remove
```

### Errors

`SmartschoolSkoreError` has a type for each case a caller handles differently (#83): a missing right, a refused change, and (the type itself) an answer the service cannot use. A `catch` of `SmartschoolSkoreError` catches all of them, and from `addTeacher`, `replaceTeacher`, `shareGradebook` and `unshareGradebook` every `SmartschoolSkoreError` means nothing was saved.

- `SmartschoolSkoreAccessDeniedError` — Skore refused the request to the account, which lacks the rights for that part of Skore (carries `area`: `SkoreAccessArea.reportManagement` or `.gradebookManagement`). Thrown when Skore sends the request on to Smartschool's start page, its answer to every request of a teacher without the rights (#91), and for an answer with HTTP 403. Its message quotes nothing of the answer, so it can be shown to the user.
- `SmartschoolSkoreChangeRefusedError` — a check before the save refused the change (the checks are listed above). Nothing was saved. Its message says which check refused and why, so the call can be corrected.
- `SmartschoolSkoreMyGroupsError` (a `SmartschoolSkoreChangeRefusedError`) — `replaceTeacher`: the current teacher works with "Mijn lesgroepen" for the course (carries `classId`, `courseId`, `teacherId`, and `teacherName` as read from the class). Nothing was saved.
- `SmartschoolSkoreError` itself (none of the types above) — Skore answered with something the service cannot use: another HTTP status than `200`, an HTML page instead of data, invalid JSON, an RPC answer without a `result`, or data in an unknown shape (also a gradebook without its list of readers or writers, or a `getMyGroups` answer it does not recognise). The session was accepted: signing in again does not help. Its message may quote the answer, which can hold names: keep it in a log.
- `SmartschoolSkoreSaveUnconfirmedError` — `addTeacher`, `replaceTeacher`, `shareGradebook` or `unshareGradebook` sent the save, but Skore's answer (for a share, also the read afterwards) does not confirm it, or no answer came in (carries the `cause`). It may or may not have been saved: read again. Not a `SmartschoolSkoreError`. The service always throws one of its two subtypes, which carry what the call read before the save (#120): `SmartschoolSkoreAssignmentSaveUnconfirmedError` from `addTeacher` and `replaceTeacher` (`course`, `replaced`, `teacher`), and `SmartschoolSkoreShareSaveUnconfirmedError` from `shareGradebook` and `unshareGradebook` (`before`, `teacherId`, `accessBefore`). A `catch` of `SmartschoolSkoreSaveUnconfirmedError` catches both. Its message names the change by IDs only.
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; or Skore answered an RPC without a session (which its web client reports as an empty session). Sign in again and retry. The save of `addTeacher` and `replaceTeacher` is not retried: it fails at once, and the client logs in before its next request (#134), so calling the method again is enough.

---

## `SkoreGradebookService`

Reads Skore's gradebook **as the logged-in teacher** (#148, #149): what a teacher sees at `/SkoreGradebook` ("Puntenboek"). Any teacher can use it with their own login; it needs none of the admin rights of `SkoreService`. It reads, creates evaluations (#150), saves grades (#151) and feedback (#152), and never publishes.

```dart
final gradebooks = SkoreGradebookService(client);

final books = await gradebooks.getGradebooks(); // List<SkoreGradebook>, current school year
for (final book in books) {
  print('${book.gradebookId}  ${book.className}  ${book.courseName}');
}

final sheet = await gradebooks.getGradebook(books.first); // SkoreGradebookSheet
for (final period in sheet.periods) {
  print('${period.name}: ${period.isOpen ? 'open' : 'closed'} until ${period.closesAt}');
}
for (final pupil in sheet.pupils) {
  print('${pupil.number}. ${pupil.name}'); // "1. Janssens, Jan"
}
print(sheet.writable ? 'may change it' : 'read-only');

// An earlier school year: its ID from the school years Skore offers.
final year = await gradebooks.getGradebookYear(); // SkoreGradebookYear
final earlier = await gradebooks.getGradebooks(workyearId: year.workyears[1].id);

// The evaluations of a period, with their publication, grades and feedback.
final evaluations = await gradebooks.getEvaluations(books.first, sheet.activePeriod!.id);
for (final evaluation in evaluations) {
  print('${evaluation.title}: ${evaluation.publication.state.name} ${evaluation.publication.at}');
  for (final grade in evaluation.results.grades) {
    print('${grade.pupilId}: ${grade.grade ?? '-'}'); // "15.5": Skore's value, with a point
    if (grade.hasFeedback) {
      final feedback = await gradebooks.getFeedback(books.first, evaluation, grade.pupilId);
      print(feedback.map((f) => f.text).join(' / '));
    }
  }
}

// A new evaluation, never published: teachers publish it in Smartschool (#150).
final created = await gradebooks.createEvaluation(books.first, sheet.activePeriod!.id,
    title: 'Toets 1', date: DateTime(2026, 10, 8), max: 20); // SkoreEvaluation

// Grades in it (#151): "15,5" is sent as "15.5", null clears; read again to check.
final cell = await gradebooks.saveGrade(books.first, created, sheet.pupils.first.id, '15,5'); // SkoreGrade

// Feedback (#152): creates yours, or changes it; a colleague's is left alone.
final note = await gradebooks.saveFeedback(books.first, created, sheet.pupils.first.id, 'Goed gewerkt.'); // SkoreFeedback
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getGradebooks({workyearId})` | `Future<List<SkoreGradebook>>` | The teacher's own gradebooks of the school year (Skore's current one without `workyearId`), one per class and course, in the order of Skore's left panel. Empty for a teacher without gradebooks. |
| `getGradebookYear({workyearId})` | `Future<SkoreGradebookYear>` | The same gradebooks, with the school year they are of (`workyear`) and the school years Skore offers (`workyears`). |
| `getGradebook(gradebook)` | `Future<SkoreGradebookSheet>` | A gradebook with its periods, the period Skore opens it on (`activePeriod`), the pupils of its class and whether Skore lets the user change it (`writable`). |
| `getEvaluations(gradebook, periodId)` | `Future<List<SkoreEvaluation>>` | The gradebook's evaluations in the period, in Skore's order, each with its `publication` and the `results` (grades) of the class's pupils. One request. |
| `getResults(gradebook, evaluation)` | `Future<SkoreEvaluationResults>` | The grades of an evaluation as Skore has them now (`getEvaluations` again). |
| `getFeedback(gradebook, evaluation, pupilId)` | `Future<List<SkoreFeedback>>` | A pupil's feedback on an evaluation, each apart, from every teacher, in the order written. Empty for none. |
| `getComponents(gradebook, periodId)` | `Future<List<SkoreEvaluationComponent>>` | The components a new evaluation in the period can count for (`0` `geen`, `2` `DW`, ...). |
| `createEvaluation(gradebook, periodId, {title, shortName, date, max, componentId})` | `Future<SkoreEvaluation>` | Creates an evaluation in the period, **unpublished**, and returns it as read again. |
| `saveGrade(gradebook, evaluation, pupilId, grade, {allowPublished})` | `Future<SkoreGrade>` | Saves (or, with `null`, clears) a pupil's grade, and returns the cell as read again. |
| `saveGrades(gradebook, evaluation, grades, {allowPublished})` | `Future<Map<int, SkoreGrade>>` | The same for several pupils (`{pupilId: grade}`), one save each, one read afterwards. |
| `saveFeedback(gradebook, evaluation, pupilId, text, {allowPublished})` | `Future<SkoreFeedback>` | Creates your feedback for the pupil, or changes it, and returns it as read again. |

- **One big read.** `getGradebooks` sends Skore's `getNavigation` once; its answer holds the colleagues of every gradebook and is big (some 270 KB for 22 gradebooks, 1.7 MB for 50). Read it once, not per gradebook. A group of classes in Skore's tree repeats gradebooks of its classes: each gradebook is listed once.
- **IDs.** `gradebookId` is Skore's `ownerID`, the same ID as the assignment that holds the gradebook (`SkoreAssignment.id` of the admin side). `pathIds` (`[modelId, groupId, classId]`) is how Skore's gradebook calls name the class. A pupil ID is the pupil's Smartschool user ID; `rowKey` is Skore's key of the pupil's row (`pupil_<id>_<classId>`).
- **School years.** A school year is Skore's ID (`SkoreWorkyear`: `24` is `2026-2027`). The calls about a gradebook go out for its `workyearId`. A `workyearId` that is not positive is refused before anything is sent, one Skore does not offer after its answer (Skore answers it with no gradebooks), both with an `ArgumentError`.
- **Course names.** `SkoreGradebook.courseName` is the name as the left panel shows it, with the grade Skore adds (`Informaticawetenschappen (2 uur) (6e j DO)`); `SkoreGradebookSheet.courseName` is the name without it (`Informaticawetenschappen (2 uur)`).
- **Periods.** `isOpen` says whether Skore takes grades in the period; `closesAt` is when it closes (UTC). Skore adds periods during the school year.
- **Pupils.** The pupils of the gradebook's class, in class order: `number` (`null` when Skore shows none, as for an earlier school year), `name` (`Last, First`), `displayName` (`First Last`), `isActive` (`false` for a row Skore greys out).
- **Writable.** `writable` is Skore's answer for the user's rights in the gradebook (`getGradebookContext`), not about a period: Skore also answers it for a closed period of an earlier year. Without periods, Skore is not asked and it is `false`.
- **Evaluations.** Know an evaluation by its `id` (Skore's `refID`): its `column` (`A`, `B`) changes when one is added. Skore sends the rows of the other classes of the group along; only the gradebook's own evaluations and pupils are kept.
- **Publication.** `publication.state` is `notPublished` (Skore's `public` `"0"`), `scheduled` (`"1"` with a `publicdatetime` still to come) or `published`, by the service's clock (`SkoreGradebookService(client, clock: ...)`) at the time of the read; `stateAt(time)` for another time. `at` is Skore's `publicdatetime`, a Belgian time without offset, in UTC; the raw values are kept (`rawPublic`, `rawPublicDateTime`).
- **Grades.** `grade` is the value Skore stores, as a string (`"15.5"`, with a point; Skore shows `15,5`), `null` for none; `value` parses it. `hasFeedback` is the cell's marker; `getFeedback` reads the texts from Skore's REST API (`/skore/api/v1/gradebook/feedback/...`), each apart, which the cell's tooltip joins into one.
- **Never publishes.** Skore's gradebook RPC service also deletes, moves, publishes and shares evaluations. The service calls only the methods in `SkoreGradebookService.rpcMethods` (the reads, `saveEvaluation` and `saveGrade`), and refuses any other before it is sent.
- **Creating an evaluation.** `createEvaluation` always sends `public` 0 and `publicdatetime` `""`: teachers publish in Smartschool themselves. It first refuses, with a `SmartschoolSkoreChangeRefusedError` and nothing saved, a blank title, a `max` that is not positive, a gradebook that is not your own of the current school year, a closed period or one Skore shows read-only, a date outside the school year, and a course or component Skore does not offer. The save is sent once, never retried; if the answer, or reading the period again, does not confirm it, a `SmartschoolSkoreEvaluationCreateUnconfirmedError` (read the period again before trying again). If it comes back public anyway, a `SmartschoolSkoreEvaluationPublicError` names it, and the library changes nothing.
- **Saving grades.** `saveGrade` / `saveGrades` refuse first, with a `SmartschoolSkoreChangeRefusedError` and nothing saved: a grade that is not a number of 0 or more, or above `max` (Skore answers it with HTTP 500); an evaluation that is **published or scheduled, unless `allowPublished: true`** (pupils see it, and get a notification), from the planner, or not in points; a pupil without a cell of the gradebook's class; and what `createEvaluation` refuses for the gradebook and period. All pupils are checked before the first save. A failed save does not stop the others; afterwards the period is read once, and a `SmartschoolSkoreGradeSaveUnconfirmedError` tells per pupil what is `confirmed`. Saving a grade again is harmless.
- **Saving feedback.** `saveFeedback` reads the pupil's feedback first: without feedback of yours it creates it (`POST /skore/api/v1/gradebook/feedback`, sent once: a second create adds a second feedback), with one it changes that (`POST .../feedback/{id}`). Other teachers' feedback is never changed. It refuses what `saveGrade` refuses for the gradebook, period, evaluation (published or scheduled unless `allowPublished: true`) and pupil, a blank text, your feedback when Skore does not let you change it, and more than one of yours. A `4xx` answer is a `SmartschoolSkoreError`; an answer, or a read afterwards, that does not confirm the text a `SmartschoolSkoreFeedbackSaveUnconfirmedError`.

The example lists the gradebooks and prints the periods and pupils of one of them, and the evaluations of its active period with their publication, grades and feedback (read-only):

```bash
dart run example/skore_gradebook_example.dart [GRADEBOOK_ID] [--workyear=ID]
# Creates an evaluation after asking (y/N); changes the live Skore:
dart run example/skore_create_evaluation_example.dart GRADEBOOK_ID PERIOD_ID TITLE YYYY-MM-DD MAX [--short=NAME] [--component=ID]
# Saves a pupil's grades in an unpublished evaluation after asking (y/N; "-" clears):
dart run example/skore_save_grade_example.dart GRADEBOOK_ID PERIOD_ID EVALUATION_ID PUPIL_ID GRADE [GRADE ...]
```

### Errors

- `SmartschoolSkoreError` — Skore answered with something the service cannot use: another HTTP status than `200` (also a redirect), an HTML page instead of data, invalid JSON, an RPC answer without a `result`, data in an unknown shape, or an answer about another gradebook or school year. Never an empty list instead. The session was accepted: signing in again does not help. Its message may quote the answer, which can hold names: keep it in a log. What Skore answers an account without a gradebook of its own (a pupil, say) was not captured.
- `ArgumentError` — a `workyearId` that is not positive, or not one Skore offers; a `periodId` or `pupilId` that is not positive, or an evaluation of another gradebook (nothing sent).
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; or Skore answered without a session. Sign in again and retry.

---

## `PlannerService`

Reads Smartschool's **planner**: the elements planned in a calendar in a period (lessons, assignments, timetable slots, ...) and the full detail of one element. A calendar is the planner of a user (the account itself, or another teacher), of a class, or of a location (a room), as `/planner/main/user/...`, `/planner/main/group/...` and `/planner/main/location/...` show it. It also reads what the planner's workload view ("werkbelasting") shows: the school's assignment types, and the assignments and workload figures of classes in a period. The reads are GETs to the planner's JSON API (`/planner/api/v1/`; the assignment types to the lesson-content API, `/lesson-content/api/v1/`), and for the search for a calendar by name, the lookup of a calendar by its ID and the workload calls, POSTs that only read.

In the **own planner** only, it fills an empty lesson hour with a new lesson or with a lesfiche of the Lesfiches library (see `LessonContentService`) and clears the hour again (see *Lessons in the own planner*), adds an assignment for classes and moves it to the planner's trash again (see *Assignments in the own planner*), and changes the name and info of an own lesson or assignment: eight writes, each for one element, after checks that keep them out of colleagues' elements.

```dart
final planner = PlannerService(client);

// A class found by name ("Zoek een planner").
final hits = await planner.searchCalendars('6A1');  // List<PlannerSearchResult>
final klas = hits
    .firstWhere((hit) => hit.kind == PlannerSearchResultKind.group)
    .calendar!;                                    // PlannerCalendar

// A calendar named by its ID; null when the planner does not know it.
final named = await planner.getCalendar(klas);     // PlannerSearchResult?
print(named?.name ?? 'no such planner');

// The own planner of one week.
final me = await planner.ownCalendar();            // PlannerCalendar
final week = await planner.getPlannedElements(
  me,
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
);                                                 // List<PlannedElement>

// The tests of a class in that week (all its teachers), with their detail.
final tests = await planner.getPlannedElements(
  klas,
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
  types: {PlannedElementType.assignment},
);
for (final test in tests) {
  final detail = await planner.getDetail(test);    // PlannedElementDetail
  print('${test.period.from} ${test.assignmentType?.abbreviation} '
      '${test.name} (${test.organiserUsers.first.name}): ${detail.publicInfo}');
  for (final file in detail.attachments ?? const <PlannerAttachment>[]) {
    print('  ${file.name} (${file.size} bytes)');  // the files are not downloaded
  }
  for (final link in detail.weblinks ?? const <PlannerWeblink>[]) {
    print('  ${link.name}: ${link.url}');
  }
}
```

### Calendars

| Calendar | ID | Example |
|---|---|---|
| `PlannerCalendar.user(id)` | the whole user ID `{platformId}_{userId}_{coaccount}` | `4069_146_0` |
| `PlannerCalendar.group(id)` | a class, `{platformId}_{groupId}` | `4069_2001` |
| `PlannerCalendar.location(id)` | a location, `{platformId}_{itemId}` | `4069_<item UUID>` |

`ownCalendar()` gives the planner of the authenticated user (from `authenticatedUser.id`; note that `getCurrentUser().id` is only the middle part of that ID). The users, classes and locations an element names give their own calendar: `element.organiserUsers.first.calendar`, `element.participantGroups.first.calendar`, `element.locations.first.calendar` (a location's calendar ID joins its platform ID and its item ID; the planner answers the bare item ID with `400`). The constructors check the form of the ID and throw an `ArgumentError` for another one.

### Finding a calendar by name

`searchCalendars(text)` does what the planner's search field ("Zoek een planner") does: it finds the users, classes and locations whose name holds the text (`6A` finds `6A1` and `6A2`, `Janssens` every Janssens, `101` the room), each with its `calendar`:

| Hit (`kind`) | Planner type (`typeName`) | `calendar` |
|---|---|---|
| `PlannerSearchResultKind.user` | `user` | `PlannerCalendar.user(id)` |
| `PlannerSearchResultKind.group` | `group` | `PlannerCalendar.group(id)` |
| `PlannerSearchResultKind.location` | an item of the location module (`location` in `origin.modules`), `mini-db-2` on the live site | `PlannerCalendar.location(id)` |
| `PlannerSearchResultKind.other` | anything else | `null` |

**Users are not told apart**: teachers, pupils and co-accounts come with the same fields, and no field says which is which. A co-account has an ID of its own (ending in its number, such as `_1`) and a `description` such as `Interimaris van ...`; the `title` of the pupils seen live ended in their class, but that is display text, which the library does not rely on. To keep teachers only, compare the user ID (the middle part of the calendar ID) with `SkoreService.getTeachers()`. The search is a `POST quick-search/planner/search` with `{"searchString": text, "searchOptions": []}`, as the web client sends it; it only reads. The planner's `include-deleted` option is not sent, and the favourites of the search (which the planner keeps per user) are not touched.

### Naming a calendar by its ID

`getCalendar(calendar)` names a calendar by its ID, as the planner's search names it (a `PlannerSearchResult` whose `calendar` is the one asked for: `name`, `title`, `description`, `isDeleted`, ...), or returns `null` when the planner does not know the ID (#127). This tells a calendar ID that names no planner from a planner with nothing planned, which `getPlannedElements` does not: the planner does not check the ID whose elements it lists (seen live, 2026-10-05):

| Calendar ID | `getPlannedElements` | `getCalendar` |
|---|---|---|
| a user, class or room with nothing planned | `[]` | the user, class or room |
| a room the planner does not have | `[]` | `null` |
| a user or class the planner does not have (a made-up ID, a co-account number the user does not have, an ID of another platform) | `SmartschoolPlannerError` with `statusCode` `500` | `null` |
| a group the planner's search does not find either (seen live: groups with the icon `star_green`, whose planner page `/planner/main/group/{id}` does name them) | `[]` | `null` |

- A **deleted user** is named, with `isDeleted` set (the search leaves deleted users out).
- The **own calendar** is named after the authenticated user (`authenticatedUser.name`): the planner itself names it `%quicksearch.me%` (`Mezelf` in the web client).
- The lookup is a `POST quick-search/planner/start` with `{"users": [], "groups": [], "miniDbItems": []}` and the calendar ID in the list of its kind (a location in `miniDbItems`): the request with which the planner's web client opens its search field, whose `selection` names the calendars it is given. It only reads; the search's suggestions and the user's favourites in its answer are not returned.
- A `SmartschoolPlannerError` when the planner answers with another status (`500` for a class ID whose part after the platform ID is not a number, such as `4069_abc`), or names another calendar than the one asked for (it reads the parts of a user or class ID as numbers, and answered `4069_04256` as `4069_4256`).
- Whether the planner names other users' calendars for an account that may not see other planners was not tried.

### Assignment types and workload

What a caller needs to answer "when is a good moment for a test in class X": the school's assignment types, the assignments of the class in a period (of all its teachers, with their type), and the workload figures the planner itself uses, per day or for one moment. The library returns these facts as the planner gives them; choosing the moment (no other test that day, not right before an exam, ...) is up to the caller.

```dart
final types = await planner.getAssignmentTypes();  // List<PlannerAssignmentType>: GO, GT, KO, ...

final assignments = await planner.getAssignmentsOfGroups(
  groupIds: [klas.id],                             // '4069_2001'; several classes in one request
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
);                                                 // List<PlannedElement>
for (final a in assignments) {
  print('${a.period.from} ${a.assignmentType?.abbreviation} ${a.name} '
      '(${a.organiserUsers.first.name})');
}

final load = await planner.getWorkloadSchedule(
  groupIds: [klas.id],
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
);                                                 // Map<DateTime, List<PlannerGroupWorkload>>
for (final MapEntry(key: day, value: groups) in load.entries) {
  for (final g in groups) {
    print('$day ${g.group.name}: weight ${g.weight}, ${g.setting?.name}');
  }
}

// The check the planner runs before it saves an assignment.
final now = await planner.calculateWorkload(
  groupIds: [klas.id],
  from: DateTime(2026, 10, 6, 8, 30),
  to: DateTime(2026, 10, 6, 9, 20),
);                                                 // List<PlannerGroupWorkload>
```

- `groupIds` are class IDs `{platformId}_{groupId}`: the `id` of a class's `PlannerCalendar` (from `searchCalendars`) or of a `PlannerGroup` an element names. Each goes out once. No class, an ID in another form, or `to` before `from` throws an `ArgumentError` before anything is sent. `from` and `to` go out as for `getPlannedElements`.
- `getAssignmentsOfGroups` returns the assignments as the planner's workload view lists them, in the planner's order (not by date). An assignment of several classes comes once, with all its classes in `participantGroups`, also those that were not asked for. The same assignments are in each class calendar (`getPlannedElements` with `PlannedElementType.assignment`), one request per class.
- `getWorkloadSchedule` returns, per day the planner names (a local `DateTime` at midnight, in date order), a `PlannerGroupWorkload` per class: the planner's `weight` and `concurrentWeight` and the class's workload `setting` (name, `limit`, allowed assignment types). An empty schedule is an empty map.
- **The figures are returned as they are**: what `weight` and `concurrentWeight` add up was not checked. At the school seen live every assignment type had weight `0` and every class the setting `Geen limiet` (limit `-1` per `day`, `soft`), so the weights stayed `0`, also on days with tests: there, the assignments per day (with their type and teacher) are what says something.
- The workload calls are POSTs that only read, as the planner's web client sends them (checked in its code, and called live): `workload/planned-elements?from=&to=` with `{"users": [], "groups": [...], "courses": []}`, `workload/schedule?from=&to=` with `{"groups": [...]}`, and `workload/calculate` with the period and `{"users": [], "groups": [...], "groupFilters": {}}`; `calculate` saves nothing. The assignment types come from `GET /lesson-content/api/v1/assignments/applicable-assignment-types`.

### Lessons in the own planner

> **Warning:** these calls change the live planner. Pupils of the hour's classes see a lesson's name and public info as soon as it is planned.

```dart
final me = await planner.ownCalendar();
final slot = (await planner.getPlannedElements(
  me,
  from: DateTime(2026, 11, 20, 11, 10),
  to: DateTime(2026, 11, 20, 12),
  types: {PlannedElementType.placeholder},
)).single;                                         // an empty lesson hour

final lesson = await planner.planLesson(
  placeholder: slot,
  name: 'Lussen: for en while',
  publicInfo: '<p>Breng je laptop mee.</p>',       // HTML, what pupils see
  privateInfo: '<p>Oefening 3 overslaan.</p>',     // HTML, what pupils do not see
);                                                 // PlannedElementDetail, a new ID

await planner.renameElement(lesson, 'Lussen: for, while en break');
await planner.changePublicInfo(lesson, '<p>Breng je laptop <strong>opgeladen</strong> mee.</p>');
await planner.changePrivateInfo(lesson, '<p>Oefening 3 en 4 overslaan.</p>');

final emptyAgain = await planner.clearLesson(lesson); // the slot again, with a new ID

// A lesfiche of the Lesfiches library into the same hour.
final fiche = (await LessonContentService(client).getItems())
    .firstWhere((item) => item.type == LessonContentType.lesson);
final planned = await planner.planLessonContent(
  placeholder: emptyAgain,
  lessonContentId: fiche.id,
);                                                 // named after the lesfiche
await planner.clearLesson(planned);
```

> **`privateInfo` is not private to the teacher.** It is the info that pupils do not see; colleagues who can read the lesson (in the calendar of one of its classes, for instance) see it too.

| Method | Request (to `/planner/api/v1/`) | Sent |
|---|---|---|
| `planLesson({placeholder, name, publicInfo, privateInfo, icon})` | `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons/blanco` with the slot's organisers, classes, course, period and rooms, and the lesson's `name`, `publicInfo`, `privateInfo` and `icon` (default `PlannerService.defaultLessonIcon`, `document_observation`) | once |
| `planLessonContent({placeholder, lessonContentId})` | `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons` (without `/blanco`) with the slot's organisers, classes, course, period and rooms, the lesfiche's ID as `sourceId` and its icon (`defaultLessonIcon` when it has none), and no name or info: the planner names the lesson after the lesfiche | once |
| `renameElement(element, newName)` | `POST {plannedElementType}/{platformId}/{id}/rename` with `{"newName"}` | retried once after logging in again |
| `changePublicInfo(element, newInfo)` | `POST .../change-public-info` with `{"newInfo"}` (HTML as given) | retried once after logging in again |
| `changePrivateInfo(element, newInfo)` | `POST .../change-private-info` with `{"newInfo"}`; `info` follows | retried once after logging in again |
| `clearLesson(lesson)` | `POST planned-elements/clear` with `{"type": "planned-lessons", "elementId", "elementPlatformId"}`; returns the slot, with a new ID | once |

Each call reads the element again first (its detail, which is up to date at once, unlike the list) and refuses with a `SmartschoolPlannerWriteRefusedError`, sending nothing:

- an element that is **not organised by the authenticated user**: a class calendar also shows colleagues' slots, lessons and assignments, and the planner may even let a user change some of them; the service never does;
- an element whose capabilities do not allow the change: `canUserReplace` to fill a slot; `canUserEdit` with `canUserRename`, `canUserChangePublicInfo` or `canUserChangePrivateInfo` to edit; `canUserEdit` to clear (as the web client requires);
- for `planLesson` and `planLessonContent`, a slot that is no longer in the period it was read with, or that has participant roles or group filters (never seen on a timetable slot);
- for `planLessonContent`, a lesfiche that is not among the user's lesfiches (`LessonContentService.getItems`, read again first), or that is not a lesson lesfiche (`LessonContentType.lesson`): an assignment lesfiche would be planned as an assignment, which the service does not do;
- for `clearLesson`, a lesson that the planner lets the user trash or delete (`canUserTrash`, `canUserDelete`): the lessons in a timetable hour seen live allowed neither, clearing being the planner's way to remove them, and the clear of any other lesson was not tried.

An element that is gone throws a `SmartschoolPlannedElementNotFoundError`, also before anything is sent: a slot that was filled since it was read is gone under its ID. The fill body is built from the slot as read again, not from the listed element. `planLesson` and `planLessonContent` refuse an element that is not a slot, and the calls refuse an empty name, icon or lesfiche ID, with an `ArgumentError` before any request. When `planLessonContent` cannot read the lesfiches, it throws the `SmartschoolLessonContentError` of `LessonContentService`, also before anything is sent. An edit to the value the element has already sends nothing.

**Why a write was refused.** The error says which check refused as a value, so that an app can tell its user why in its own words instead of passing on the library's message (a sentence for a log, which names the method and the element by its type and ID, and ends with "Nothing was sent."):

```dart
try {
  await planner.planLesson(placeholder: slot, name: 'Lussen');
} on SmartschoolPlannerWriteRefusedError catch (e) {
  final hour = e.element;                          // the slot as read again (null when none was read)
  final why = switch (e.reason) {
    PlannerWriteRefusalReason.notOwn =>
      'that hour belongs to ${hour!.organiserUsers.map((u) => u.name).join(', ')}',
    PlannerWriteRefusalReason.notAllowed =>
      'Smartschool does not allow it (${e.capabilityFlags.join(', ')} not set)',
    PlannerWriteRefusalReason.periodChanged =>
      'the hour is at ${hour!.period.from} now',
    _ => e.message,
  };
  print('Not planned: $why.');                     // nothing was sent
}
```

| `reason` (`PlannerWriteRefusalReason`) | From | Adds |
|---|---|---|
| `notOwn` — not organised by the authenticated user | every write that changes an element | `element` (with its `organiserUsers`) |
| `notAllowed` — the capabilities do not allow the change | every write that changes an element | `element`; `capabilityFlags`: the flags the write needs that are not set |
| `noLongerASlot` — the slot to fill is another kind of element now | `planLesson`, `planLessonContent` | `element` |
| `periodChanged` — the slot is no longer in the period it was read with | `planLesson`, `planLessonContent` | `element`, in the period it has now |
| `participantRoles` — the slot has participant roles or group filters | `planLesson`, `planLessonContent` | `element` |
| `trashable` — the planner lets the user trash or delete the lesson | `clearLesson` | `element`; `capabilityFlags`: those set of `canUserTrash`, `canUserDelete` |
| `unknownLessonContent` — the lesfiche is not among the user's lesfiches | `planLessonContent` | — |
| `notALessonLessonContent` — the lesfiche is not a lesson one | `planLessonContent` | `lessonContent`: the lesfiche (`LessonContentItem`) |
| `unknownAssignmentType` — the type is not one of the school's | `planAssignment` | `assignmentTypes`: the school's types (`PlannerAssignmentType`) as the check read them (#119) |
| `linkedEvaluation` — the assignment has a linked Skore evaluation | `trashAssignment` | `element` |

`element` is the element as the write read it again (its detail, a `PlannedElementDetail`), so its name, period (a `DateTime`), classes, course and organisers are at hand; it is `null` when the check refused before an element was read (a lesfiche, a new assignment's type). `assignmentTypes` is empty for every other reason; for `unknownAssignmentType` it lists the school's types in the planner's order, so that an app can name them to its user, or pick the one it meant (a type the school replaced by one of the same name has a new ID), without reading them again with `getAssignmentTypes`, a read that could differ from the one the check refused on. `reason` is `null` only for an error made without it (its constructor takes the new fields as optional ones).

The fill and the clear are sent **once**: never again after logging in again (a second fill could plan a second lesson). The edits set a value, so they are retried once after logging in again, as a read is. When the planner's answer does not confirm a write (a lesson with the name asked for, or the lesfiche's name, in the slot's period; the element with the new value; a slot of the own planner in the lesson's period), or no usable answer comes in, the call throws a `SmartschoolPlannerSaveUnconfirmedError`: the change may or may not have been made, so read the element again (`getDetail`; it answers `404` for a slot that was filled or a lesson that was cleared) before trying again. Calling the method again is safe in itself: it reads the element first.

Of the planner's trash, the service only uses the move of one own assignment (`trashAssignment`, see *Assignments in the own planner*). It never uses the planner's `DELETE` of an element (which deletes it for good), the restore from the trash, or its bulk endpoints (`planned-elements/trash`, `planned-elements/delete`, `planned-elements/bulk/...`, `planned-elements/replace-with-...`, and `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, which moves everything in a period to the trash). Attachments, weblinks, goals, labels, the icon of an existing lesson, rescheduling and lessons outside the timetable are not covered.

**Planning a lesfiche.** The planner makes the lesson from the lesfiche: in the try live it took the lesfiche's name, labels and goals, and its (empty) info; the answer has no field that points back to the lesfiche. Planning did not change the lesfiche (the whole list was the same afterwards), and a hidden lesfiche (`isVisible` `false`) was planned like any other. Whether the planner copies the attachments, weblinks and info of a richer lesfiche, and whether later changes to a lesfiche reach the lessons planned from it, was not checked. The bulk plan of one lesfiche into several hours (`planned-elements/replace-with-lesson-content`) is not used: `planLessonContent` plans one hour at a time, each with its own checks.

The example shows the hour, asks for confirmation, fills it with a `[dartschool test]` lesson, renames it, clears it (also when the rename failed) and shows the hour again; given a lesfiche (its ID or exact name), it plans that lesfiche into the hour instead, and clears it again without renaming it (a lesfiche that matches none, such as `?`, lists the lesson lesfiches and changes nothing):

```bash
dart run example/planner_lesson_example.dart 2026-11-20 11:10
dart run example/planner_lesson_example.dart 2026-11-20 11:10 '?'
dart run example/planner_lesson_example.dart 2026-11-20 11:10 b0000000-0000-4000-8000-000000000001
```

### Assignments in the own planner

> **Warning:** these calls change the live planner. **Pupils of the classes see a new assignment at once**: the planner makes it visible from the moment it is created (`visibleFrom`), with its name and public info, until it is in the trash.

An assignment ("opdracht": a test, a task, something to bring along) is not tied to a lesson hour: it is a deadline, for one or more classes. In a class calendar it shows next to the timetable slot of that hour, which stays as it is. With *Assignment types and workload* above, a caller can pick a moment and then plan the test:

```dart
final ko = (await planner.getAssignmentTypes())
    .firstWhere((type) => type.abbreviation == 'KO');

final test = await planner.planAssignment(
  groupIds: [for (final group in slot.participantGroups) group.id], // '4069_2001', ...
  course: slot.courses.first,                      // a PlannerCourse, e.g. of a timetable slot
  type: ko,                                        // one of getAssignmentTypes()
  name: 'Test: hoofdstuk 3',
  due: slot.period.from,                           // the deadline, usually the start of a lesson hour
  until: slot.period.to,                           // the end of that hour
  publicInfo: '<p>Leerstof: hoofdstuk 3.</p>',     // HTML, what pupils see
  locations: slot.locations,                       // optional
);                                                 // PlannedElementDetail, organised by you

await planner.renameElement(test, 'Test: hoofdstuk 3 en 4');
await planner.changePublicInfo(test, '<p>Leerstof: hoofdstuk 3 en 4.</p>');
await planner.trashAssignment(test);               // to the planner's trash (30 days)
```

| Method | Request (to `/planner/api/v1/`) | Sent |
|---|---|---|
| `planAssignment({groupIds, course, type, name, due, until, publicInfo, privateInfo, icon, locations})` | `POST planned-assignments/blanco?waitForRefresh=true` with the authenticated user as the only organiser, the classes as participants, the course, the period (`dateTimeFrom` = `due`, `dateTimeTo` = `until`, `wholeDay` `false`, `deadline` `true`, `dateTime` = `due`), the `name` (sent trimmed), an empty `info`, `publicInfo` and `privateInfo` (HTML as given, empty by default), the type's ID as `assignmentType`, the `icon` (required by the planner; default `PlannerService.defaultAssignmentIcon`, `flags_red_yellow`) and the `locations`; answered with `201` and the assignment | once |
| `renameElement`, `changePublicInfo`, `changePrivateInfo` | as for a lesson, at `planned-assignments/{platformId}/{id}/...` | retried once after logging in again |
| `trashAssignment(assignment)` | `POST planned-assignments/{platformId}/{id}/trash` without a body, answered with `200` and `[]`; then the assignment's detail is read again and must be `404` | once |

Before anything is sent:

- `planAssignment` reads the school's assignment types again (`getAssignmentTypes`) and refuses a `type` whose ID is not among them with a `SmartschoolPlannerWriteRefusedError`, which carries the types it read as `assignmentTypes` (#119); types that cannot be read throw the `SmartschoolPlannerError` of `getAssignmentTypes`. No class, an ID that is not a class ID, an empty name, icon, course ID or type ID, or `until` before `due` throws an `ArgumentError` before any request. `due` and `until` go out as `PlannerService.formatDateTime` writes them.
- The edits and `trashAssignment` read the assignment again and refuse, as for a lesson, one that is **not organised by the authenticated user** (a class calendar also shows colleagues' tests, which the service never changes, even when the planner would let the user) or whose capabilities do not allow the change (`canUserTrash` to trash, as the web client's delete requires). `trashAssignment` also refuses an assignment with a linked Skore evaluation (`hasLinkedEvaluation`): the trash of one was not tried. An assignment that is gone (also one that is in the trash already) throws a `SmartschoolPlannedElementNotFoundError`; an element that is not an assignment throws an `ArgumentError` before any request.

The create and the trash are sent **once**, never again after logging in again. When the planner's answer does not confirm the create (an assignment of the authenticated user with the name and type asked for, due at `due`; `201` or `200`), or no usable answer comes in, `planAssignment` throws a `SmartschoolPlannerSaveUnconfirmedError`: the assignment may or may not have been made. **Calling `planAssignment` again adds another assignment** when the first one was made: look for it in the calendar of one of its classes first (`getPlannedElements(PlannerCalendar.group(id), ..., types: {PlannedElementType.assignment})`, or `getAssignmentsOfGroups`). `trashAssignment` throws it when the trash is not answered with a list, or when the assignment is still there (or cannot be read) afterwards; calling it again is safe, since it reads the assignment first.

The planner keeps what is in its trash for 30 days, and its web client can restore it from there; the service does not read, restore or empty the trash (the restore was not tried). Not covered either: rescheduling an assignment, changing its type, classes or visibility, pinning or resolving it, announcing it (`announce`; whether it notifies pupils or parents is not known), hand-in folders, linking a Skore evaluation, attachments, weblinks, goals, reminders, recurrence, and planning an assignment lesfiche of the Lesfiches library.

The example shows a lesson hour of the own planner and the assignment type, asks for confirmation, adds a `[dartschool test]` assignment for the hour's classes, due at its start, reads it back and looks for it in the class calendar, renames it, and moves it to the trash (also when the read or the rename failed; after a create that was not confirmed it looks for it in the class calendar and trashes what it finds); a type that matches none (such as `?`) lists the school's types and changes nothing:

```bash
dart run example/planner_assignment_example.dart 2026-11-20 11:10
dart run example/planner_assignment_example.dart 2026-11-20 11:10 GO
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `ownCalendar()` | `Future<PlannerCalendar>` | The planner of the authenticated user. |
| `searchCalendars(text)` | `Future<List<PlannerSearchResult>>` | The users, classes and locations whose name holds `text`, in the planner's order, each with its calendar (see *Finding a calendar by name*). An empty text throws an `ArgumentError` before anything is sent. |
| `getCalendar(calendar)` | `Future<PlannerSearchResult?>` | The calendar named by its ID, as the planner's search names it (a deleted user too, with `isDeleted`; the own calendar after the authenticated user); `null` when the planner does not know the ID (see *Naming a calendar by its ID*). |
| `getPlannedElements(calendar, {from, to, types})` | `Future<List<PlannedElement>>` | The elements of the calendar in the period, in the planner's order. `types` keeps only those types (`null`: every type). A whole school year in one request works. The planner does not check the calendar ID: a room it does not have is an empty list, a user or class it does not have a `SmartschoolPlannerError` with `statusCode` `500`; `getCalendar` tells them apart. |
| `getPlannedElement({type, typeName, platformId, id})` | `Future<PlannedElementDetail>` | The full detail of one element, by its `type` or by its `typeName`, the planner's name of the type (`planned-lessons`, as `PlannedElement.typeName` keeps it; also for a type the library does not know): pass one of the two. Neither or both, `PlannedElementType.other`, a `typeName` not of the planner's form (`planned-` and words of lowercase letters and digits joined by hyphens) or an empty `id` throw an `ArgumentError` before anything is sent. |
| `getDetail(element)` | `Future<PlannedElementDetail>` | The same, for a listed element (also one of a type the library does not know). |
| `getAssignmentTypes()` | `Future<List<PlannerAssignmentType>>` | The school's assignment types (such as `Kleine Overhoring`, `KO`), in the planner's order. |
| `getAssignmentsOfGroups({groupIds, from, to})` | `Future<List<PlannedElement>>` | The assignments of the classes in the period, of every teacher, in the planner's order (see *Assignment types and workload*). |
| `getWorkloadSchedule({groupIds, from, to})` | `Future<Map<DateTime, List<PlannerGroupWorkload>>>` | The planner's workload figures of the classes per day of the period. |
| `calculateWorkload({groupIds, from, to, wholeDay, deadline})` | `Future<List<PlannerGroupWorkload>>` | The planner's workload figures of the classes for an assignment in that period (`deadline` defaults to `true`, `wholeDay` to `false`), as the planner computes them before it saves an assignment. Saves nothing. |
| `planLesson({placeholder, name, publicInfo, privateInfo, icon})` | `Future<PlannedElementDetail>` | Fills an empty lesson hour of the own planner with a new lesson; returns it (see *Lessons in the own planner*). |
| `planLessonContent({placeholder, lessonContentId})` | `Future<PlannedElementDetail>` | Plans a lesson lesfiche of the Lesfiches library (an ID from `LessonContentService.getItems`) into an empty lesson hour of the own planner; returns the lesson, named after the lesfiche. |
| `clearLesson(lesson)` | `Future<PlannedElementDetail>` | Clears an own lesson in a lesson hour; returns the empty slot, with a new ID. |
| `planAssignment({groupIds, course, type, name, due, until, publicInfo, privateInfo, icon, locations})` | `Future<PlannedElementDetail>` | Adds an assignment of one of the school's types for the classes to the own planner, due at `due`; returns it. Pupils see it at once (see *Assignments in the own planner*). |
| `trashAssignment(assignment)` | `Future<void>` | Moves an own assignment to the planner's trash, and checks that it is gone. |
| `renameElement(element, newName)` | `Future<PlannedElementDetail>` | Renames an own lesson or assignment (or another own element the planner lets the user rename); returns it. |
| `changePublicInfo(element, newInfo)` / `changePrivateInfo(element, newInfo)` | `Future<PlannedElementDetail>` | Sets the info that pupils see / do not see of an own lesson or assignment (HTML); returns it. |
| `formatDateTime(time, {timeZoneOffset})` (static) | `String` | A date as the planner's API takes it: ISO 8601 to the second with the offset from UTC (`2026-11-20T11:10:00+01:00`); in the given offset when `timeZoneOffset` is set. |

`from` and `to` go out as ISO 8601 with their offset (URL-encoded, `+` as `%2B`): a local `DateTime` in the local time of the machine, with its offset at that moment (in Belgium `+02:00` in summer, `+01:00` in winter), a UTC one in UTC. The planner's own dates are read into local `DateTime`s. Use `23:59:59` rather than midnight to include the last day. `to` before `from`, an empty `types` and `PlannedElementType.other` in `types` throw an `ArgumentError` before anything is sent.

### What the planner shows

- **A class calendar holds the elements of all teachers of the class**, and a colleague's lessons and assignments can be read in full. `privateInfo` is the info that pupils do not see, **not** info that only its teacher sees: other teachers who can read the element see it too. `publicInfo` is what pupils see. Both are HTML (`""` when empty); `info` held the same text as `privateInfo` in every answer seen.
- **Timetable slots** are `PlannedElementType.placeholder` elements: one per teacher per lesson hour, with the classes, the course and the room, but no `name`. `capabilities.canReplace` tells whether a slot can be filled. Do not keep their IDs: a slot that was filled and cleared again comes back with a new ID. Find a slot again by its period, course and groups.
- **The list lags behind**: after a change in the planner, `getPlannedElements` may show the old state for a few seconds, while `getPlannedElement` / `getDetail` show the new one at once. Read the detail to check a change.
- Only lessons, assignments and placeholders were seen live; the other `PlannedElementType`s are the web client's constants. An element of a type the library does not know is kept as `PlannedElementType.other`, with the planner's name in `typeName`.

### Errors

- `SmartschoolPlannerError` — the planner answered with something the service cannot use: another status than `200` (in `statusCode`, such as `400` for a calendar it refuses, or `500` for the elements of a user or class it does not have), an HTML page, invalid JSON, or data in an unknown shape (also a search hit of a user, class or location whose ID is not a calendar ID, and a lookup of `getCalendar` that names another calendar than the one asked for). The session was accepted: signing in again does not help.
- `SmartschoolPlannedElementNotFoundError` (a `SmartschoolPlannerError`) — `getPlannedElement` / `getDetail`: the planner has no element of that type with that ID (`404`): unknown, removed, or in the trash, or a `typeName` the planner does not have (carries `elementType`, `platformId`, `elementId`). Also from a write, for the element it reads again first (such as a slot that was filled since it was read): nothing was sent.
- `SmartschoolPlannerWriteRefusedError` (a `SmartschoolPlannerError`) — a check before a write refused it (not organised by the authenticated user, a capability not set, a slot in another period, an assignment type the school does not have, ...). Nothing was sent. Carries the check as `reason` (a `PlannerWriteRefusalReason`), the `element` as read again, the `capabilityFlags`, for a lesfiche that is not a lesson one the `lessonContent`, and for an assignment type the school does not have the school's `assignmentTypes` as the check read them (see *Why a write was refused*). From the writes, every `SmartschoolPlannerError` means nothing was sent.
- `SmartschoolLessonContentError` — `planLessonContent` could not read the lesfiches before planning one (see `LessonContentService`). Nothing was sent.
- `SmartschoolPlannerSaveUnconfirmedError` — a write went out, but the planner's answer does not confirm it, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been made: read the element again before trying again; for `planAssignment`, look for the assignment in the calendar of one of its classes, since calling it again adds another one. Not a `SmartschoolPlannerError`.
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; for `planLesson`, `planLessonContent`, `clearLesson`, `planAssignment` and `trashAssignment`, which are not retried, at once. Nothing was changed: call the method again; the client logs in before its next request (#134).
- `SmartschoolParsingError` — `ownCalendar()`: the session's user ID is not in the form `{platformId}_{userId}_{coaccount}`.

---

## `LessonContentService`

Reads and builds the lesfiches of Smartschool's **Lesfiches** module (lesson content, `/lesson-content`): the lessons and assignments a teacher keeps in the own library ("Mijn lesfiches"), with their labels (such as `JAAR 6`, `TRIMESTER 1`), courses, weblinks and attachments, to plan into the planner. It reads with GETs to the module's JSON API (`/lesson-content/api/v1/`) and to the school's course list (`/course-list/api/v1/courses`), which names the courses: the module gives them by ID only. In the own library it also makes lesfiches, changes them and moves them to the module's trash (#129). A lesson lesfiche is planned into an empty lesson hour with `PlannerService.planLessonContent` (see *Lessons in the own planner*), so a lesfiche prepared once can be planned as often as needed.

```dart
final lessonContent = LessonContentService(client);
final fiches = await lessonContent.getItems();       // List<LessonContentItem>
for (final fiche in fiches.where((f) => f.type == LessonContentType.lesson)) {
  print('${fiche.name}  ${fiche.courses.map((c) => c.name).join(', ')}  '
      '${fiche.labels.map((l) => l.text).join(', ')}');
}

// A complete lesfiche in one create (#129): info, a course, a weblink and an
// attachment, each with when pupils see it.
final informatica = (await lessonContent.getCourses())
    .firstWhere((c) => c.name == 'informatica');
final fiche = await lessonContent.createLesson(      // LessonContentDetail
  name: 'Lussen',
  publicInfo: '<p>Hoofdstuk 3</p>',
  courseIds: [informatica.id],
  weblinks: [
    NewLessonContentWeblink(
      name: 'Oefeningen',
      url: 'example.com/lussen',                     // sent as http://example.com/lussen
      visibility: LessonContentVisibility.atEnd,
    ),
  ],
  attachments: [
    NewLessonContentAttachment(
      'lussen.pdf',
      visibility: LessonContentVisibility.afterEnd(3),
    ),
  ],
);
await lessonContent.rename(fiche, 'Lussen (herhaling)');
final bytes = await lessonContent.downloadAttachment(
  fiche,
  fiche.attachments.single.id,
);
await lessonContent.trash([fiche]);                  // the module's trash, never deleted for good
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getItems({withCourseNames = true})` | `Future<List<LessonContentItem>>` | The lesfiches of the authenticated user, lessons and assignments, hidden ones included (not those in the trash), in the module's order (`GET lesson-content/`). With `withCourseNames` (the default) and a lesfiche with a course, it then reads the course list (`getCourses`, one request more) and names each course after the course with the same ID in it; `false` sends the one request, and leaves every course name `null`. A course list it cannot use does not lose the lesfiches: it throws a `SmartschoolLessonContentCourseListError` whose `items` are the lesfiches as read, with every course name `null` (#118). |
| `getDetail(item, {withCourseNames = true})` / `getDetailById(type, id, {withCourseNames = true})` | `Future<LessonContentDetail>` | One lesfiche in full (`GET lessons/{id}` or `assignments/{id}`, #129): a `LessonContentItem` with its `privateInfo`, its `weblinks` (`LessonContentWeblink`: `id`, `name`, `url`, `icon`, `visibility`) and its `attachments` (`LessonContentAttachment`: `id`, `fileName`, `fileSize`, `mimeType`, `visibility`). No dates. Courses named as `getItems` names them. A `404` (an unknown ID, or one of the other kind) is a `SmartschoolLessonContentNotFoundError`. |
| `getCourses()` | `Future<List<PlannerCourse>>` | The school's courses (all of them, not only the teacher's), in the course list's order (`GET /course-list/api/v1/courses`): `id` (the ID of a lesfiche's course and of a planner course), `name`, `scheduleCodes`, `icon`, `clusterId`, `clusterName`, `isVisible`. The list the Lesfiches web client names its course filter from, and the course IDs the writes take. |
| `createLesson({name, icon, publicInfo, privateInfo, courseIds, weblinks, attachments})` | `Future<LessonContentDetail>` | Makes a lesson lesfiche in the own library, with everything in one create, and returns it as read back (see below). |
| `createAssignment({name, assignmentTypeId, ...})` | `Future<LessonContentDetail>` | The same for an assignment lesfiche of one of the school's assignment types (`PlannerService.getAssignmentTypes`), checked against the module's own list first. |
| `rename(item, name)` / `changeIcon(item, icon)` / `changePublicInfo(item, html)` / `changePrivateInfo(item, html)` | `Future<LessonContentDetail>` | Change one value (`POST {type}/{id}/rename`, `change-icon`, `change-public-info`, `change-private-info`); the module answers with the whole lesfiche. |
| `changeCourses(item, courseIds)` | `Future<LessonContentDetail>` | Sets the courses (`change-courses`), after checking each ID against `getCourses`; empty clears them. The answer has the courses named. |
| `setVisible(item, visible)` | `Future<LessonContentDetail>` | Shows or hides the lesfiche in the module (`mark-as-visible` / `mark-as-invisible`). |
| `addWeblink(item, weblink)` / `changeWeblink(item, weblinkId, weblink)` / `removeWeblink(item, weblinkId)` | `Future<LessonContentWeblink>` / `Future<void>` | A weblink of the lesfiche (`POST {type}/{id}/weblinks`, `.../weblinks/{id}`; `DELETE .../weblinks/{id}`, answered with `204`). `changeWeblink` sends every value: name, address, icon and visibility. |
| `addAttachments(item, attachments)` | `Future<List<LessonContentAttachment>>` | Uploads files into a new upload directory and has the module take it (`POST {type}/{id}/attachments` with `{"randomDir"}`); returns the new attachments, told apart from the ones there by reading the lesfiche first. The module gives each new one `always`, so another visibility is set after (`changeAttachmentVisibility`), one at a time. When that fails, the files were added: a `SmartschoolLessonContentVisibilityNotSetError` (#135, see *Errors*). |
| `changeAttachmentVisibility(item, attachmentId, visibility)` / `removeAttachment(item, attachmentId)` | `Future<LessonContentDetail>` / `Future<void>` | `POST .../attachments/{id}/change-visibility`; `DELETE .../attachments/{id}` (answered with `204`). |
| `downloadAttachment(item, attachmentId, {maxBytes})` / `downloadAttachmentStream(...)` | `Future<Uint8List>` / `Future<SmartschoolDownload>` | The file of an attachment, unchanged (`GET .../attachments/{id}/download`), sent without `Accept: application/json` (with it, Smartschool answered `503` and an HTML page). See *Downloads* above. |
| `trash(items)` | `Future<void>` | Moves lesfiches to the module's trash (`POST lesson-content/trash/bulk`, answered with `{"exceptions": []}`). They leave `getItems`; their detail is still answered. |
| `normalizeWeblinkUrl(url)` (static) | `String?` | The address as the Lesfiches web client sends it (`http://` in front when it has none, no white space before the `?`, the query encoded as `encodeURI` does), or `null` when its weblink dialog would refuse it. |
| `parseItems(json, {courses})` / `parseDetail(json, {courses})` (static) | `List<LessonContentItem>` / `LessonContentDetail` | Parse the module's list and the detail of a lesfiche, naming the courses after `courses` (the school's courses). |
| `parseCourses(json)` (static) | `List<PlannerCourse>` | Parses the course list. |

A course of a lesfiche that the course list does not have (or names with an empty name) keeps a `null` name. `PlannerService.planLessonContent` reads the lesfiches without the course names.

When the lesfiches were read but the course list cannot be used, the lesfiches come with the error, so they can be listed without the names (#118):

```dart
List<LessonContentItem> fiches;
try {
  fiches = await lessonContent.getItems();
} on SmartschoolLessonContentCourseListError catch (e) {
  fiches = e.items;          // every course name null; e (the course list's) says why
}
```

The module gives its dates without an offset from UTC (`2025-09-01 19:51:25`, unlike the planner): the school's local time, read as the local time of the machine. The school's assignment types, which the planner also reads from this module, come from `PlannerService.getAssignmentTypes()`.

**The writes (#129).** All were tried live on 2026-10-05, in the own library, which is private to the teacher.
- **When pupils see a weblink or an attachment** is a `LessonContentVisibility`: `always` (the default), `never`, `atStart` and `atEnd` (of the lesson the lesfiche is planned in), or `afterEnd(days)` for the 1 to 14 days the web client offers.
- **A create answers with the new ID only** (`201` with `{"id"}`), so `createLesson` and `createAssignment` read the lesfiche back (`GET lessons/{id}`) and return its detail, which must show the name, courses, weblinks and attachments sent. The create carries everything, as the web client's does: the attachments are uploaded into a new upload directory first (the step Intradesk uploads and message attachments use), which goes out as `randomDir`, with each file's visibility by name in `visibilityOptions`. A body with only a name gets a bare `400`, so the service sends every list the web client sends (goals, labels, partner weblinks, deeplinks and mini-DB items empty). A name that is taken is kept: the module makes a second lesfiche of that name.
- **A create is sent once**: never again after logging in again, since a second one makes a second lesfiche. The same for `addWeblink` and the take of `addAttachments` (the module takes the files of a directory again every time it is told to, and keeps two attachments of the same name). The edits set a value, and the removals and the move to the trash name what they act on, so they are retried once after logging in again, as a read is.
- **Checks before sending**: the module answers a bad name or address with a bare `400`, and stores a course it does not know without complaint. So the writes throw an `ArgumentError`, before anything is sent, for an empty name or one longer than 255 characters (the web client's field), an empty icon, a weblink without a name or with an address `normalizeWeblinkUrl` refuses, a visibility the web client does not offer, a file that does not exist or whose name Smartschool does not allow, two files of the same name in one call, an ID that is not a UUID, and a lesfiche of a kind the library does not know. A course ID that is not one of `getCourses`, and an assignment type that is not one of the module's, are refused the same way after reading those lists.
- Not covered: labels, goals, duplicating, merging, converting between lesson and assignment, sharing, year plans and lesson clusters, method lessons of publishers, printing, restoring from the trash and deleting for good. Whether `planLessonContent` copies a lesfiche's attachments, weblinks and visibility into the planned lesson was not checked.

### Errors

- `SmartschoolLessonContentError` — the module, or the course list, answered with something the service cannot use: another status than `200` (in `statusCode`), an HTML page (its web app, for a route it does not know), invalid JSON, or data in an unknown shape (such as a lesfiche without its `id` or `type`, or a course without its `id`). The session was accepted: signing in again does not help. From `getItems`, one that is not the subtype below is about the lesfiches: none were read. From a write, this type and its subtypes mean that nothing was changed.
- `SmartschoolLessonContentCourseListError` (a `SmartschoolLessonContentError`) — `getItems` or `getDetail` read the lesfiches, but the course list they read after them to name their courses answered so; its `message` and `statusCode` are the course list's. It carries the lesfiches as read in `items`, every course with a `null` name, the same as `getItems(withCourseNames: false)` gives them (#118). `getCourses()`, which reads the course list alone, throws the plain type. A session refused for the course list, or a connection that fails for it, is thrown as for the lesfiches (`SmartschoolSessionExpiredError`, `SmartschoolConnectionError`), without them.
- `SmartschoolLessonContentNotFoundError` (a `SmartschoolLessonContentError`, #129) — the module answered `404`: no lesfiche of that kind with that ID (an unknown ID; for a write, also a lesfiche in the trash), or no such weblink or attachment. Carries the `type` and `id`. Nothing was changed.
- `SmartschoolLessonContentWriteRefusedError` (a `SmartschoolLessonContentError`, #129) — the module refused a write with another status from `400` to `499` (seen live: a bare `400`), with its reasons in `violations` when it gives any. Nothing was changed.
- `SmartschoolAttachmentUploadError` — the upload step of a create or of `addAttachments` failed. Nothing was changed.
- `SmartschoolLessonContentSaveUnconfirmedError` (#129) — a write went out, but the module's answer does not confirm it (a `500`, an answer without the change, no answer, or `exceptions` from a move to the trash; a lesfiche in the trash already is answered with `500`). Read the lesfiche before trying again. For a create, `lessonContentId` is the new lesfiche's ID when the module answered with one: it was made, only reading it back failed (or did not show everything sent).
- `SmartschoolLessonContentVisibilityNotSetError` (a `SmartschoolLessonContentSaveUnconfirmedError`, #135) — `addAttachments` added the files (the module took them), but setting the visibility of one of them failed. It carries `addedAttachments` (the attachments the module made, in the order of the call, each with the visibility it has as far as the call knows), `attachment` (the one whose change failed) with its asked `visibility`, and `visibilitiesNotSet` (by attachment ID: that one's, then those of the attachments after it, which were not tried); `cause` is the change's failure. Do not add the files again (that adds them a second time): set those visibilities with `changeAttachmentVisibility`. From `addAttachments`, a `SmartschoolLessonContentSaveUnconfirmedError` that is not of this type means the take itself is unconfirmed: the files may or may not have been added.

  ```dart
  try {
    await lessonContent.addAttachments(fiche, files);
  } on SmartschoolLessonContentVisibilityNotSetError catch (e) {
    // The files are on the lesfiche (e.addedAttachments); set what is left.
    for (final MapEntry(key: id, value: visibility) in e.visibilitiesNotSet.entries) {
      await lessonContent.changeAttachmentVisibility(fiche, id, visibility);
    }
  } on SmartschoolLessonContentSaveUnconfirmedError {
    // The files may or may not have been added: read the lesfiche first.
  }
  ```
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once (for a create, without that retry). Nothing was changed. Calling the method again is enough: the client logs in before its next request (#134).

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

### `MessageFolder`
Returned by `getFolders` (#136): a folder of a message box, the archive or one the user made. Fields: `id` (its box ID, the `boxId` to list it with), `boxType`, `name`, `description` (`msg archive` for the archive), `isArchive`, `parentId` (`null` directly in the box), `path` (the folder names from the one directly in the box down to this one) and `children`. `MessageFolder.flatten(folders)` lists a tree depth first, each folder before the ones in it.

### `MessageSearchUser` / `MessageSearchGroup`
Used as recipients in `SendMessageParams`. Returned by `searchRecipientsForCompose`; users also by `getCurrentUserAsRecipient`, `getReplyRecipients`, `getReplyAllRecipients` and `getSentMessageRecipients`. Key fields: `userId`/`groupId`, `ssId`, `userLt` (users only), `displayName`.

### `SmartschoolUser`
Returned by `SmartschoolClient.getCurrentUser()`. Fields: `id` (int — server-assigned numeric user ID), `displayName` (String), `avatarUrl` (String? — profile picture URL).

### `MessageChanged` / `MessageDeletionStatus`
Returned by mutation operations. `MessageChanged` carries the `id` of the affected message and its `newValue`. `MessageChanged.fromStatusXml` and `fromLabelXml` read the answer to a mark (its `<status>`) and to a flag change (its `<label>`), and return `null` when it gives no usable ID or state (#95); `MessageChanged.fromXml` is deprecated, as it read a missing state as `0`. `MessageDeletionStatus` (from `moveToTrash`) carries the `msgId`, the `boxType` it was in, `isDeleted` (`true` when Smartschool confirms the deletion) and `unread`, the read state of the message.

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

### `IntradeskFolderCapabilities`
Fields: `canManage`, `canAdd` (the user may add to the folder), `canAddConfidentialFolder` (#128: the user may add a confidential folder here; `false` when the answer does not carry it, as the folder listings do not; the root's, from `getRootCapabilities`, carry it, #138), `canSeeHistory`, `canSeeViewHistory`.

### `IntradeskItemKind`
The kind of an Intradesk item (#133): `folder`, `weblink` or `file`, each with its `pathSegment` (`folders`, `weblinks`, `files`). Carried by `SmartschoolIntradeskItemNotFoundError.kind`.

### `IntradeskAddRefusalReason`
Why a create was refused after reading its parent, before anything was sent (#138); carried by `SmartschoolIntradeskAddRefusedError.reason`: `cannotAdd` (the folder's `canAdd` is `false`; at the root, the platform's), `cannotAddConfidentialFolder` (a confidential folder at the root without the platform's `canAddConfidentialFolder`), `ordinaryParent` (a confidential folder in an ordinary folder), `confidentialParent` (an ordinary folder in a confidential folder).

### `IntradeskUploadResult`
Returned by `IntradeskService.uploadFiles` (#128). Fields: `files` (`List<IntradeskFile>`, the files Intradesk added, from the `files` of its answer, an object keyed by file ID; a file's name can differ from the uploaded one when the name was taken), `failures` (`List<IntradeskUploadFailure>`, the files it did not take: `key`, `violations`, and `message`, the first violation; empty when it took all of them).

### `PresenceConfig`
Returned by `PresenceService.getConfig()`. Fields: `activeClass` (`PresenceClassRef?`, the class active in the module's web client), `activePlaceholder` (`PresenceClassRef?`), `allowedClasses` (`List<PresenceClassRef>`), `schoolyearRefDate` (String, `yyyy-MM-dd`). Helper `classForGroup(groupId)`, the class from `allowedClasses` (falling back to `activeClass`), `null` when the account has no such class.

**The placeholder class `-2` (#117).** For a teacher who has no lesson at that moment, the module gives the class `-2`, "Uit Planner" (without a `structID`), as its active class: no class, `getClassPupils` lists no pupils for it ("U geeft momenteel geen les. Kies een andere klas in de keuzelijst."). `getConfig` keeps it apart: `activeClass` is `null` for it and `activePlaceholder` holds it, and `classForGroup` never returns a placeholder. The rule is `PresenceClassRef.isPlaceholder`: a `groupId` below 1. So the classes of the account, the allowed classes plus `activeClass` when it is not among them, never include it:

```dart
final config = await presence.getConfig();
final classes = [
  ...config.allowedClasses,
  if (config.activeClass case final active?
      when !config.allowedClasses.any((c) => c.groupId == active.groupId))
    active,
];
final noLessonNow = config.activePlaceholder != null;
```

### `PresenceClassRef`
A class as listed by the Presence config. Fields: `groupId`, `name`, `adminNumber` (`int?`), `instituteNumber` (`int?`), `structId` (`int?` — `null` for virtual grouping classes), `downStreamGroupIds` (`List<int>`, the `groupID`s of the classes it groups, the module's `downStreamGroups`, #126), `userCanRecord`, `userCanConfirm`, `isOfficial`. `userCanConfirm` ("bevestigen") is the right to set the class's half-days, which `setLate` and `setPresent` need; `userCanRecord` ("registreren") is not, and is true for every class of a teacher without that right (seen live, #121; it looks like the registration per lesson, which this library does not do). Getter `isPlaceholder`: no class but a placeholder the module gives in the place of one, a `groupId` below 1, such as the class `-2` ("Uit Planner") (#117).

### `PresenceCode` / `PresenceAlias`
A presence status code (`codeId`, `code`, `name`, `aliases`) and its aliases (`aliasId`, `parentCodeId`, `name`). Codes are per-structure, resolved by name. `PresenceCode.aliasByName(name)` looks up an alias case-insensitively.

### `PresenceClassPupils`
Returned by `PresenceService.getClassPupils()` (#104). The pupils of the class for the day, as a `List<PresencePupil>`, with what the Presence module said about the class that day: `saveIsAllowed` (`bool?`), `errorMessage` (`String?`, the module's reason, `null` when it gave none) and `classRef` (`PresenceClassRef?`, the class as the module names it, `null` when the module does not know the class ID). When the module lists no pupils, `saveIsAllowed` is `false` and `errorMessage` says why, in Dutch as its web client shows it. Seen live (2026-10-03): "Het is niet mogelijk om in de toekomst afwezigheden op te nemen." for a day after today (to an account without the right to set the class's half-days, `userCanConfirm` false; an absence administrator's account, with `userCanConfirm`, gets the pupils of a day after today in the school year, with `saveIsAllowed` true, seen 2026-10-04, #123), "Deze klas bevat geen leerlingen." for a class without pupils and for a class ID the module does not know (then without a `classRef`), and "U geeft momenteel geen les. Kies een andere klas in de keuzelijst." for the class `-2` ("Uit Planner", `PresenceConfig.activePlaceholder`).

```dart
final pupils = await presence.getClassPupils(
  classGroupId: 298,
  date: DateTime(2026, 10, 1),
  schoolyearRefDate: config.schoolyearRefDate,
);
if (pupils.isEmpty) {
  print(pupils.classRef == null
      ? 'No such class: ${pupils.errorMessage}'
      : 'No pupils listed: ${pupils.errorMessage}');
}
```

### `PresencePupil` / `PresenceHalfDay`
Returned by `PresenceService.getClassPupils()`, as a `PresenceClassPupils`. A pupil (`userId`, `movementId`, `name`, `halfDays`) and its half-day cells (`presenceId` — `null` when no record yet, `presenceDate`, `part`, `codeId`, `aliasId`, `motivation`). `PresencePupil.halfDayFor(part, {date})` returns the matching cell. `PresenceService.statusNameOf(halfDay, codes)` names the status a cell holds (#105). `PresencePupil.officialClassId` (`int?`) is the `groupID` of the pupil's official class (the module's `officialClass`), and `PresenceHalfDay.statusName` (`String?`) the name of the status the module gives with the record (the `name` of its `code`, an alias's name for an alias), `null` when the record carries none (#126).

**Grouping classes (#126).** A grouping class (`isOfficial` false, `structId` `null`, such as "2A" or "Taalatelier groep 1") has no structure to ask `getAllCodes` for, but `getClassPupils` lists its pupils with their half-days, the same records as in their official classes. Name their statuses with `halfDay.statusName`, which needs no other request, or with the codes of the structure of each pupil's official class. Do not ask for the codes without a structure: seen live (read-only, 2026-10-05), the module answers an empty `structID` with the four codes of the per-lesson rows ("Aanwezig", "Te laat", "Afwezig", "Online aanwezig"), which name none of the half-days. Seen live, both names were the same for every half-day (some 1700, of grouping and official classes), and every pupil of the school's 17 grouping classes had an official class that `getConfig` listed with the school's structure (to an account with the absence-administrator rights). `downStreamGroupIds` is not the list of those official classes: 11 of the 17 grouping classes name none, and one listed a pupil who had moved to a class it does not name. `setLate` / `setPresent` still refuse a grouping class: set the half-day in the pupil's official class.

```dart
final config = await presence.getConfig();
final pupils = await presence.getClassPupils(
  classGroupId: 1650, // a grouping class: structId is null
  date: DateTime(2026, 10, 2),
  schoolyearRefDate: config.schoolyearRefDate,
);
for (final pupil in pupils) {
  final structId = config.classForGroup(pupil.officialClassId ?? 0)?.structId;
  final codes = structId == null ? null : await presence.getAllCodes(structId);
  for (final halfDay in pupil.halfDays) {
    print(codes == null
        ? halfDay.statusName
        : PresenceService.statusNameOf(halfDay, codes));
  }
}
```

### `PresenceSavedHalfDay`
Returned by `PresenceService.setLate()` / `setPresent()` (#105): a `PresenceHalfDay`, the record the Presence module answered the save with (a new `presenceId` for a half-day that had no record; `codeId` `null` for an alias), with `before` (`PresenceHalfDay?`), the half-day as the call read it right before the save. The calls return `null` when the save's answer holds no record of the half-day.

### `PresenceSaveError`
In `SmartschoolPresenceError.saveErrors` (#109): an error of a save the Presence module refused, one entry of the `errors` of its answer. `message` (the module's reason, trimmed, in Dutch as its web client shows it; `PresenceSaveError.noReason` when it gave none), and the record that was not saved: `date` (`yyyy-MM-dd`), `part` (`DayPart?`), `userId` (the pupil's internal `userID`, the record's `studentID`) and `pupilName` (the pupil's name as the module gives it), each `null` when the error does not name it. `toString()` shows the message, day, half of the day and `userID`, not the pupil's name. `PresenceService.parseSaveErrorDetails(answer)` reads them from an answer; `parseSaveErrors` gives their messages. The shape is the one the module's web client reads (`{"message", "presence": {"presenceDate", "partOfDay", "studentID", "pupil", ...}}`); it was not captured from a live save.

### `SkoreClass`
Returned by `SkoreService.getClasses()`. Fields: `id` (the Skore class ID), `name`, `modelId`, `modelName`, `groupId` (`int?`), `groupName` (`String?`).

### `SkoreCourse` / `SkoreAssignment`
Returned by `SkoreService.getCourses()`. A course row (`id`, `classId`, `name`, `label` — as Skore shows it, code included, `code` (`String?`, the last `[...]` of the label), `isGroupHeader`, `depth` — `0` for a top-level row, `assignments`) and the teachers assigned to it (`id` — the assignment ID, `ownerID` in Skore, `teacherId`, `teacherName`).

### `SkoreSavedAssignment`
Returned by `SkoreService.addTeacher()` and `replaceTeacher()`. The assignment saved, a `SkoreAssignment` (`id`, `teacherId`, `teacherName` of the teacher it has now), with `course` (the `SkoreCourse` as read before the save, its `assignments` before the change) and `replaced` (`SkoreAssignment?`: for `replaceTeacher`, the assignment with the teacher it had; `null` for `addTeacher`).

### `SkoreTeacher`
Returned by `SkoreService.getTeachers()`. Fields: `id` (the Smartschool user ID), `name` (`"Last, First"`).

### `SkoreGradebookShares`
Returned by `SkoreService.getGradebookShares()` (and, as a `SkoreGradebookShareChange`, by `shareGradebook()` and `unshareGradebook()`). A gradebook of a teacher: `gradebookId` (the assignment ID), `ownerId`, `className`, `courseName`, `icon`, `readerIds` and `writerIds` (Smartschool user IDs of the teachers who may read it, and of those who may read and change it). `accessOf(teacherId)` gives a teacher's `SkoreShareAccess`, or `null` when it is not shared with them.

### `SkoreGradebookShareChange`
Returned by `SkoreService.shareGradebook()` and `unshareGradebook()`. The gradebook after the call, a `SkoreGradebookShares` (as read again after a save, or as read before it when nothing was saved), with `teacherId` (the teacher whose access the call changed), `before` (the `SkoreGradebookShares` as the call read it before the change), `saved` (`true` when it sent the save and Skore confirmed it, `false` when the teacher already had that access, or none for an unshare), and the getters `accessBefore` and `accessAfter` (the teacher's `SkoreShareAccess?` in `before` and after the call).

### `SkoreGradebookYear` / `SkoreWorkyear`
Returned by `SkoreGradebookService.getGradebookYear()`. The teacher's own `gradebooks` of a school year (`workyear`, a `SkoreWorkyear`: Skore's `id` and its `name`, `2026-2027`), with the `workyears` Skore offers.

### `SkoreGradebook`
Returned by `SkoreGradebookService.getGradebooks()`. A gradebook of the logged-in teacher: `gradebookId` (Skore's `ownerID`, the assignment ID), `teacherId`, `modelId` / `modelName`, `groupId` / `groupName`, `classId` / `className`, `courseId` / `courseName` (with the grade Skore adds), `teacherNames` (the teachers of the course, `Last First`), `workyearId`, and the getter `pathIds` (`[modelId, groupId, classId]`).

### `SkoreGradebookSheet`
Returned by `SkoreGradebookService.getGradebook()`. The `gradebook`, its `courseName` (without the grade), its `periods`, the `activePeriod` Skore opens it on (`null` without periods), the `pupils` of its class, and `writable` / `isCoordinator` from Skore's `getGradebookContext`.

### `SkoreGradebookPeriod` / `SkoreGradebookPupil`
A period of a gradebook: `id`, `name` (`DW1`), `fullName`, `isOpen`, `closesAt` (UTC, or `null`), `info` (Skore's HTML description) and `categoryMode` (`1`: evaluations). A pupil of a gradebook: `id` (the Smartschool user ID), `classId`, `number` (the class number, or `null`), `name` (`Last, First`), `displayName` (`First Last`), `isActive`, and the getter `rowKey` (`pupil_<id>_<classId>`).

### `SkoreEvaluation` / `SkorePublication`
Returned by `SkoreGradebookService.getEvaluations()`. An evaluation: `id` (Skore's `refID`), `evaluationId`, `gradebookId`, `periodId`, `column` (not stable), `title`, `shortName` (or `null`), `date` (the day), `max`, `componentId` / `componentName` (`DW`; `0` / `""` for none), `type` (`SkoreEvaluationType.points`, `.scale`, `.unknown`) and `typeCode`, `courseId` / `courseName`, `isPlannerEvaluation`, `publication` and `results`. A `SkorePublication`: `state` (`SkorePublicationState`), `at` (UTC, or `null`), `isPublic` (published or scheduled), `rawPublic`, `rawPublicDateTime`, and `stateAt(time)`.

### `SkoreEvaluationResults` / `SkoreGrade`
The grades of an evaluation: `evaluationId`, `grades` (one per pupil of the class), `classAverage` and `groupAverage` (Skore's strings, or `null`), and `gradeOf(pupilId)`. A grade: `pupilId`, `classId`, `grade` (Skore's value, or `null`), `value` (as a number), `hasFeedback`, `categoryType` and `cellEvaluationId` (the cell's `p`), and the getter `rowKey`.

### `SkoreFeedback`
Returned by `SkoreGradebookService.getFeedback()` and `saveFeedback()`. `id` (a UUID), `text`, `pupilId`, `teacherId` / `teacherName`, `createdAt` / `changedAt` (UTC), `attachments` (`SkoreFeedbackAttachment`: `id`, `name`, `size`, and Skore's `json`) and `canEdit`.

### `PlannerCalendar`
A calendar of the planner: `type` (`PlannerCalendarType`) and `id`. Made with `PlannerCalendar.user(id)`, `.group(id)` or `.location(id)` (or `PlannerCalendar(type, id)`), by `PlannerService.ownCalendar()`, or from what an element names (`PlannerUser.calendar`, `PlannerGroup.calendar`, `PlannerLocation.calendar`). Equal by type and ID.

### `PlannerSearchResult`
Returned by `PlannerService.searchCalendars()`, and by `PlannerService.getCalendar()` (the calendar named by its ID). Fields: `id` (the planner's ID, the calendar ID for a user, class or location), `typeName` (the planner's type: `user`, `group`, `mini-db-2`, ...), `kind` (`PlannerSearchResultKind`), `calendar` (`PlannerCalendar?`; `null` for `other`), `name` (a user first name first, a class, a room), `title` (as the search list shows it: a user last name first, a pupil with the class), `description` (`""` when none: a class's full name, `Interimaris van ...` for a co-account, `Locatie` for a room), `pictureUrl` (`String?`, users), `icon` (`String?`), `isDeleted` (the planner counts the user as deleted, `state.deleted.isDeleted`; never set on a search hit, which leaves deleted users out), and `raw` (the hit as the planner gave it, read-only).

### `PlannedElement`
Returned by `PlannerService.getPlannedElements()`. Fields: `id` (a UUID), `platformId`, `type` (`PlannedElementType`; `other` for a type the library does not know), `typeName` (the planner's name of the type, such as `planned-lessons`), `name` (`String?`; `null` on a timetable slot), `period` (`PlannerPeriod`: `from`, `to` in local time, `wholeDay`, `deadline`), `organiserUsers` / `organiserGroups`, `participantUsers` / `participantGroups`, `isParticipant`, `capabilities` (`PlannedElementCapabilities`), `icon` (`String?`), `courses`, `locations`, `assignmentType` (`PlannerAssignmentType?`, assignments only), `resolvedStatus` (`String?`, assignments only), `pinned`, `unconfirmed`, `color`, and `raw` (the element as the planner gave it, read-only, for the fields the model does not cover).

### `PlannedElementDetail`
Returned by `PlannerService.getPlannedElement()` and `getDetail()`. A `PlannedElement` with `info`, `privateInfo` and `publicInfo` (HTML, `""` when empty), for assignments `isAnnounced`, `visibleFrom` (from when pupils see it), `hasLinkedEvaluation` and `dateCreated` (`null` on other elements), and the element's `labels` (`List<PlannerLabel>?`), `attachments` (`List<PlannerAttachment>?`) and `weblinks` (`List<PlannerWeblink>?`), in the planner's order: `[]` when it has none, `null` when the planner gave no such list for the element (a timetable slot has no attachments or weblinks). Partner weblinks, deeplinks and goals are only in `raw`.

### `PlannerLabel` / `PlannerAttachment` / `PlannerWeblink` / `PlannerVisibility`
What the detail of an element lists. A label (`id`, `text`, `color` — `String?`, `type` — `platform` for a school label, `user` for an own one —, `isVisible`, `isSchoolLabel`; the same label as a lesfiche's `LessonContentLabel`); an attachment (`id`, `name` — the file name, `size` — bytes, `int?`, `mimeType` — `String?`, `visibility`; the file itself is not downloaded); a weblink (`id`, `name`, `url`, `icon` — `String?`, `visibility`). A `visibility` (`PlannerVisibility?`, `null` when the planner gave none) says from when pupils see the file or link: `option` (`PlannerVisibilityOption`), `optionName` (the planner's name), and `daysAfterEnd` (`int?`, for `daysAfterEnd`).

### `PlannerUser` / `PlannerGroup` / `PlannerCourse` / `PlannerLocation`
What an element names. A user (`id` — the whole planner ID `{platformId}_{userId}_{coaccount}`, `name`, `nameLastFirst`, `pictureUrl`, `isDeleted`, `calendar`); a group (`id` — `{platformId}_{groupId}`, `platformId`, `name`, `type` — `K` for a class, `icon`, `calendar`); a course (`id`, `platformId`, `name`, `scheduleCodes`, `icon`, `clusterId`, `clusterName`, `isVisible`); a location (`id` — the item UUID, `platformId`, `platformName`, `number`, `title` — the room, `icon`, `type`, `selectable`, `calendar`).

### `PlannerAssignmentType`
The type of an assignment, such as `Kleine Overhoring` (`KO`): `id`, `platformId` (`int?`; `null` inside a planned element), `name`, `abbreviation`, `isVisible`, `defaultTiming`, `weight`. Returned by `PlannerService.getAssignmentTypes()`, named by an assignment (`PlannedElement.assignmentType`) and by a workload setting (`allowedAssignmentTypes`).

### `PlannerGroupWorkload` / `PlannerWorkloadSetting` / `PlannerWorkloadLimit`
Returned by `PlannerService.getWorkloadSchedule()` (per day) and `calculateWorkload()`. The workload of one class: `group` (`PlannerGroup`), `weight` and `concurrentWeight` (`num`, the planner's figures as they are), `setting` (`PlannerWorkloadSetting?`), and `raw` (as the planner gave it, read-only). A setting: `id`, `platformId` (`int?`), `name` (`Geen limiet`), `color` (`String?`), `limit` (`PlannerWorkloadLimit?`: `value` — `-1` in `Geen limiet` —, `period` such as `day`, `type` such as `soft`), `allowedAssignmentTypes` (`PlannerAssignmentType`s).

### `PlannedElementCapabilities`
What the authenticated user may do with an element: `flags` (every `canUser...` flag by name), `visibleProperties` (the properties the user may see), `can(name)` (`false` for a flag the planner left out), and the getters `canEdit`, `canRename`, `canReplace`, `canReschedule`, `canChangePublicInfo`, `canChangePrivateInfo`, `canTrash`, `canDelete`.

### `LessonContentItem`
Returned by `LessonContentService.getItems()`. A lesfiche: `id` (a UUID, the `lessonContentId` of `PlannerService.planLessonContent`), `platformId`, `type` (`LessonContentType`; `other` for a kind the library does not know), `typeName` (`lessons`, `assignments`), `name`, `icon` (`String?`), `publicInfo` (HTML, `""` when empty), `isVisible`, `ownerId` (`String?`, the whole user ID), `dateLastChanged` / `dateStateChanged` (`DateTime?`, local time), `courses` (`LessonContentCourse`: `id`, `platformId`, `name` — `String?`, from the school's course list, `null` when not known), `labels` (`LessonContentLabel`: `id`, `text`, `color`, `type` — `platform` for a school label, `user` for an own one —, `isVisible`, `isSchoolLabel`), `assignmentType` (`PlannerAssignmentType?`, assignment lesfiches only), `attachmentCount`, `weblinkCount`, `partnerWeblinkCount`, `deeplinkCount`, `capabilities` (every `canUser...` flag by name; `can(flag)`), and `raw` (as the module gave it, read-only).

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
| `SkoreShareAccess` | `read` (Skore's `readers`), `write` (Skore's `writers`: read and change) |
| `PlannerCalendarType` | `user`, `group`, `location` (`wireName`: the name in the planner's URL) |
| `PlannerSearchResultKind` | `user`, `group`, `location`, `other` (what `PlannerService.searchCalendars` found, or `getCalendar` named) |
| `PlannedElementType` | `lesson`, `assignment`, `placeholder`, `toDo`, `schoolActivity`, `meeting`, `lessonFreeDay`, `generic`, `activity`, `routine`, `partnerElement`, `lessonCluster`, `lessonClusterMoment`, `lessonClusterLesson`, `lessonClusterAssignment`, `mergedTeachingMoment`, `other` (`wireName`: the planner's name, such as `planned-lessons`; `null` for `other`) |
| `LessonContentType` | `lesson` (`lessons`), `assignment` (`assignments`), `other` (`wireName`: the Lesfiches module's name; `null` for `other`) |
| `PlannerVisibilityOption` | `always`, `never`, `atStart` (`at-start`), `atEnd` (`at-end`), `daysAfterEnd` (`days-after-end`), `other` (`wireName`: the planner's name; `null` for `other`). From when pupils see an attachment or weblink of a planned element; only `always` was seen live |

---

## Exceptions

| Exception | Thrown when |
|---|---|
| `SmartschoolAuthenticationError` | Login fails or session has expired (base class of the login failures below, and thrown itself for other authentication failures) |
| `SmartschoolInvalidCredentialsError` | Smartschool rejects the username or password (also SSO-only accounts). In rare cases a rejected login form token instead, which Smartschool answers with the same page (#46); do not log in again automatically |
| `SmartschoolTwoFactorRequiredError` | Smartschool asks for a 2FA code, but `mfa` holds no TOTP secret |
| `SmartschoolTwoFactorRejectedError` | Smartschool rejects the 2FA code (wrong TOTP secret, or the device clock is off) |
| `SmartschoolInvalidTotpSecretError` | The TOTP secret in `mfa` is not a key: not Base32 once white space and hyphens are removed, or only digits (such as the 6-digit code of the authenticator app). Thrown before the password is posted when `mfa` is not a date either, so nothing of the login is sent; otherwise at the 2FA step, before its code is sent |
| `SmartschoolUnsupportedTwoFactorMethodError` | The account's 2FA does not offer an authenticator app (carries the `availableMethods`) |
| `SmartschoolAccountVerificationRequiredError` | Smartschool asks for account verification (date of birth), but `mfa` is empty or not a date |
| `SmartschoolAccountVerificationRejectedError` | Smartschool rejects the account verification answer |
| `SmartschoolSessionExpiredError` | Smartschool does not accept the session: after logging in again, the retry of a request is still answered with `401` or by the login chain (redirected to `/login`, `/2fa` or `/account-verification`), or a request sent with `retryAfterLogin: false` (such as a step of `sendMessage`, or a create) is refused, after which the client logs in before its next request (#134), or a request sent with `sameSessionAs` (such as a step of `sendMessage`) is not sent because the client logged in again since that answer was loaded. The request was not carried out: try it again |
| `SmartschoolUnexpectedPageError` | Smartschool answers an XML command (`postXml`, so every `MessagesService` call that sends one) with an HTML page (#106), also one with a comment before its doctype, or a piece of a page, also when that is well-formed XML (#110); also a recipient search (`searchRecipientsForCompose`, `searchRecipientsForComposeAll`, action `searchUsers`, #112). Not one of the answers with which Smartschool refuses a session (`401`, a redirect to the login chain): for those the client logs in again. `isLoginPage` says whether the page holds the login form; when it does not, such as for an error page, it is not a sign of an expired session (Smartschool's web client reports it as an unknown error). Carries the `action`, `statusCode`, `contentType`, `url`, and the page's `title` and `heading`, all in the message too, and the start of its text in `excerpt`, which is not; none of them holds the page's scripts or forms, and e-mail addresses and token-like strings are masked. A `SmartschoolAuthenticationError`, as `postXml` threw for every HTML page before. Not retried: for a command that changes something, check before sending it again |
| `SmartschoolConnectionError` | `ensureAuthenticated()` or a service call cannot reach Smartschool: the host does not resolve, the connection fails or times out (carries the `cause`). A network problem, so not an authentication error |
| `SmartschoolComposeError` | The compose form cannot be used (its tokens or the current user's IDs are missing), or Smartschool does not register a recipient on it (the message names the recipient). From `sendMessage` or `sendReply`, before the message is submitted: nothing was sent. `sendReply` also throws it when Smartschool does not answer with the reply form of the message, or does not take a recipient that the reply form names and `params` leave out off the form (the message names the recipient). Both throw it too when the form does not offer the LVS copy or the delayed send that `params.options` asks for (#47) |
| `SmartschoolSendUnconfirmedError` | `sendMessage` or `sendReply` submitted the message, but Smartschool's answer does not confirm that it was sent, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been sent: check the sent box (for a delayed send, the scheduled box) before sending it again. Not a `SmartschoolComposeError` |
| `SmartschoolMoveUncheckedError` | `MessagesService.moveToTrashFrom` sent the move and Smartschool answered it, but the check after it failed (carries the `msgId`, `boxType` and `boxId` of the move, and the check's error as its `cause`: a `SmartschoolSessionExpiredError`, `SmartschoolUnexpectedPageError`, `SmartschoolParsingError`, `SmartschoolConnectionError` or another login failure). The move may have been made: check with `getMessage(msgId, boxType: boxType)` before moving it again (#115). Not a `SmartschoolAuthenticationError`, so code that repeats a call on `SmartschoolSessionExpiredError` does not repeat the move |
| `SmartschoolAttachmentUploadError` | Smartschool's upload step fails: for an attachment of `sendMessage` / `sendReply` (nothing was sent), or for `IntradeskService.uploadFiles` (no upload directory, or a file Smartschool did not take; nothing was added). Carries the `fileName`, the `statusCode` and, for a refusal in Smartschool's own words (such as the `400` for a name with a character it does not allow), its `serverMessage` (#128) |
| `SmartschoolSkoreError` | Skore answers with something `SkoreService` or `SkoreGradebookService` cannot use (an HTML page, invalid JSON, an RPC answer without a `result`, an unknown shape), or a check of `addTeacher` / `replaceTeacher` / `shareGradebook` / `unshareGradebook` refuses the change before the save: nothing was saved. Not a session problem |
| `SmartschoolSkoreMyGroupsError` | `SkoreService.replaceTeacher`: the current teacher works with "Mijn lesgroepen" for the course (carries `classId`, `courseId`, `teacherId`, `teacherName`). Nothing was saved. A `SmartschoolSkoreError` |
| `SmartschoolSkoreSaveUnconfirmedError` | `SkoreService.addTeacher` or `replaceTeacher` sent the save, but Skore's answer does not confirm it, or no answer came in (carries the `cause`). It may or may not have been saved: read the class again (`getCourses`) before trying again. Also from `shareGradebook` / `unshareGradebook`, when Skore's answer or the read afterwards does not confirm the save: read the gradebooks again (`getGradebookShares`). Not a `SmartschoolSkoreError`. Always one of its two subtypes, with what the call read before the save (#120) |
| `SmartschoolSkoreAssignmentSaveUnconfirmedError` | The `SmartschoolSkoreSaveUnconfirmedError` of `addTeacher` / `replaceTeacher`: carries the `course` as read before the save, the assignment it was `replaced` (`null` for an add), and the `teacher` it was saving (#120) |
| `SmartschoolSkoreShareSaveUnconfirmedError` | The `SmartschoolSkoreSaveUnconfirmedError` of `shareGradebook` / `unshareGradebook`: carries the gradebook as read `before` the change and the `teacherId`, with their `accessBefore` (#120) |
| `SmartschoolSkoreGradeSaveUnconfirmedError` | The `SmartschoolSkoreSaveUnconfirmedError` of `SkoreGradebookService.saveGrade` / `saveGrades`: carries the `grades` sent, and per pupil the `confirmed` cells and why the others are `unconfirmed` (#151). Saving again is harmless |
| `SmartschoolSkoreFeedbackSaveUnconfirmedError` | The `SmartschoolSkoreSaveUnconfirmedError` of `SkoreGradebookService.saveFeedback`: carries the `evaluationId`, `pupilId`, `text`, `isUpdate` and `feedbackId` (#152). Read the feedback again; `saveFeedback` again does not add a second |
| `SmartschoolPlannerError` | The planner answers `PlannerService` with something it cannot use: another status than `200` (carries the `statusCode`), an HTML page, invalid JSON, an unknown shape. Not a session problem |
| `SmartschoolPlannedElementNotFoundError` | `PlannerService.getPlannedElement` / `getDetail`: the planner has no element of that type with that ID (`404`; carries `elementType`, `platformId`, `elementId`); also a planner write, for the element it reads again first (nothing was sent). A `SmartschoolPlannerError` |
| `SmartschoolPlannerWriteRefusedError` | `PlannerService.planLesson` / `planLessonContent` / `renameElement` / `changePublicInfo` / `changePrivateInfo` / `clearLesson`: a check before the write refused it (the element is not organised by the authenticated user, a capability is not set, the lesfiche is not a lesson lesfiche of the user, ...). Nothing was sent. A `SmartschoolPlannerError` |
| `SmartschoolPlannerSaveUnconfirmedError` | A planner write went out, but the planner's answer does not confirm it, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been made: read the element again (`getDetail`) before trying again. Not a `SmartschoolPlannerError` |
| `SmartschoolLessonContentError` | The Lesfiches module, or the course list, answers `LessonContentService` with something it cannot use: another status than `200` (carries the `statusCode`), an HTML page, invalid JSON, an unknown shape. From `PlannerService.planLessonContent`, which reads the lesfiches first: nothing was sent. Not a session problem, not a `SmartschoolPlannerError` |
| `SmartschoolLessonContentCourseListError` | `LessonContentService.getItems` read the lesfiches, but the course list that names their courses answered with something it cannot use (carries the course list's `statusCode`, and the lesfiches as read in `items`, with every course name `null`). A `SmartschoolLessonContentError` (#118) |
| `SmartschoolLessonContentVisibilityNotSetError` | `LessonContentService.addAttachments` added the files, but setting the visibility of one of them failed (#135): a `SmartschoolLessonContentSaveUnconfirmedError` that carries the `addedAttachments`, the `attachment` whose change failed with its asked `visibility`, and the `visibilitiesNotSet` (that one's and those not tried after it, by attachment ID); `cause` is the change's failure. Do not add the files again: set those visibilities. See `LessonContentService` > *Errors* |
| `SmartschoolPresenceError` | A presence save is rejected (carries the server's errors: typed in `saveErrors`, their messages in `errors`, #109), an answer of the Presence module cannot be read (the subtype below), or a class/code/pupil cannot be resolved. Not a session problem |
| `SmartschoolPresenceUnreadableAnswerError` | `PresenceService`: an answer of the Presence module cannot be read (carries the `path`, the HTTP `statusCode`, the `kind`, a `PresenceUnreadableAnswerKind`: `empty`, `html`, `malformedJson`, or `errorStatus` for valid JSON with a status outside `200`–`299`, #143, and for a page its `title` and `heading`). Can be gone a moment later (a proxy's `502`). For a read nothing changed; for the save it is not known whether it landed, and calling `setLate` / `setPresent` again is safe. A `SmartschoolPresenceError` (#137) |
| `SmartschoolPresenceChangeRefusedError` | `PresenceService.setLate` / `setPresent` with `onlyReplacing`: the half-day, as read right before the save, holds a status it does not allow (carries `userId`, `part`, `date`, `halfDay`, `heldStatus`, `onlyReplacing`). Nothing was sent. A `SmartschoolPresenceError` (#105) |
| `SmartschoolPresencePupilNotFoundError` | `PresenceService.setLate` / `setPresent`: the class, as read right before the save, does not list the pupil on that day (carries `userId`, `classGroupId`, `date`, and, when the module listed no pupils, its `saveIsAllowed` and `errorMessage`). Nothing was sent. A `SmartschoolPresenceError` (#116) |
| `SmartschoolDownloadTooLargeError` | A download given `maxBytes` (`download`, `downloadStream`, `IntradeskService.downloadFile` / `downloadFileStream`, `MessageAttachment.download` / `downloadStream`) turns out larger: Smartschool announces a larger `Content-Length` (before any of it is read), or more than `maxBytes` bytes come in (carries `maxBytes` and the announced `contentLength`). The client stops the transfer. Not a `SmartschoolDownloadError`: Smartschool answered with the file |
| `SmartschoolIntradeskFolderNotFoundError` | `IntradeskService.getFolderListing` is given an ID that Smartschool knows no folder for: an unknown ID, or the ID of a file or a weblink (carries the `folderId`). A `SmartschoolDownloadError` with status `500`, the status Smartschool answers the listing with. Also from `createFolder`, `createWeblink` and `uploadFiles` for such a parent folder: nothing was made (#128); since #138 from their read of the parent, before anything is sent (status `404`, or `200` for a parent in the trash). From `getFolderParentIds`, `getFolder` and `getFolderPath` with status `404` for such an ID, and from `getFolder` and `getFolderPath` with status `200` for a folder that the listing where its parents put it does not hold, such as a folder in the trash (#132) |
| `SmartschoolIntradeskWriteRefusedError` | An `IntradeskService` write that Intradesk refused with HTTP `400`–`499` (carries the `statusCode` and Intradesk's reasons in `violations`, such as an invalid URL). Nothing was made (#128). `statusCode` is `null` for its subclass `SmartschoolIntradeskAddRefusedError` (#138) |
| `SmartschoolIntradeskAddRefusedError` | `IntradeskService.createFolder`, `createWeblink` or `uploadFiles`: the folder they add to does not allow it, as Intradesk's web client tells it: no `canAdd`, a confidential folder in an ordinary folder (which Intradesk refuses with `400`), an ordinary folder in a confidential one, a confidential folder at the root without the platform's `canAddConfidentialFolder` (carries the `reason`, an `IntradeskAddRefusalReason`, the `parentFolderId`, the `parent` as read, `null` at the root, and the `capabilities`). Nothing was sent: the service read the parent first. A `SmartschoolIntradeskWriteRefusedError` with `statusCode` `null` (#138) |
| `SmartschoolIntradeskItemNotFoundError` | `IntradeskService.trashFolder`, `trashWeblink` or `trashFile`: Intradesk has no item of that kind with that ID, and answered the move to the trash with `404`: a made-up ID, or the ID of an item of another kind, such as a file's ID given to `trashFolder` (carries the `kind`, an `IntradeskItemKind`, and the `id`). Nothing was moved to the trash. A `SmartschoolIntradeskWriteRefusedError` with status `404` (#133) |
| `SmartschoolIntradeskSaveUnconfirmedError` | An `IntradeskService` write went out, but Intradesk's answer does not confirm it, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been made: list the folder before trying again (a create sent again adds a second item). Not a `SmartschoolIntradeskWriteRefusedError` (#128) |
| `SmartschoolPagingRestartedError` | `getHeaderPages` / `getArchiveHeaderPages`, and so `getAllHeaders` / `getAllArchiveHeaders`: the box was listed again while it was being paged, so Smartschool restarted the paging halfway. A listing on the same client (`getHeaders`, or a later paging of the box) fails the paging before its next page (#80); one elsewhere shows as Smartschool sending the second page again (#76). The headers so far are correct but not the whole box: list it again. Not a session problem |
| `SmartschoolClientDisposedError` | A request on a client that was disposed, or one that was running when it was disposed (also the stream of a download being read). A `StateError`, not a `SmartschoolException`: see below |

The login failure types all extend `SmartschoolAuthenticationError`, so a `catch` of the base class still catches them. They are thrown directly, by `ensureAuthenticated()` and also by a service call (or any `SmartschoolClient` request method) that finds the session cold or expired and fails to log in again, so the same `on` clauses work around either. Only a request made on `client.dio` itself gets them wrapped in a `DioException`, as its `error`.

```dart
try {
  await client.ensureAuthenticated();
  final headers = await MessagesService(client).getHeaders();
} on SmartschoolInvalidCredentialsError {
  // Ask the user to check their username and password.
} on SmartschoolTwoFactorRejectedError {
  // Ask the user to check their TOTP secret and device clock.
} on SmartschoolInvalidTotpSecretError {
  // Ask the user for the key of the authenticator app, not its 6-digit code.
} on SmartschoolAuthenticationError catch (e) {
  // Any other authentication failure.
} on SmartschoolConnectionError {
  // Smartschool is unreachable: ask the user to check their network.
}
```

`SmartschoolConnectionError` extends `SmartschoolException`, not `SmartschoolAuthenticationError`: a `catch` of the authentication error does not swallow a network problem. `ensureAuthenticated()` and every service call (or any `SmartschoolClient` request method) report an unreachable Smartschool this way, also when the network fails during a login the call triggered. Only a request made on `client.dio` itself gets the plain `DioException`.

A request on a client that was disposed (`client.dispose()`) is not a network problem, and is not reported as one: every request method, and so every service call, `ensureAuthenticated()`, `platformId` and `getCurrentUser()` throw a `SmartschoolClientDisposedError` that says the client was disposed, before sending anything (also when they have the answer cached). A request that was running when the client was disposed, and the stream of a download that was being read, fail with it too. It is a `StateError`, so an `on StateError` clause still catches it, and not a `SmartschoolException`: it is a mistake in the app, which should not retry or show "offline" for it, but create a new client. Its own type tells it apart from any other `StateError` (such as the "No element" of a `.first`), and `client.isDisposed` tells whether the client was disposed:

```dart
for (final id in folderIds) {
  try {
    index.add(await intradesk.getFolderListing(id));
  } on SmartschoolClientDisposedError {
    break; // The app disposed the client: stop, do not save a partial index.
  } on SmartschoolException {
    // This folder failed: skip it.
  }
}
```

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

What it checks, on messages it sends to the own account: `sendMessage` is confirmed and arrives once, in the inbox and the sent box; a small attachment; `sendReply` is linked to the message it answers (`hasReply`); `sendReply(all: true)`; `sendReply` moving the recipient from To to CC; `MessageSendOptions(requestReadReceipt: true)` throws before any request; `moveToTrashFrom` out of the archive folder: a message moved to the archive with `moveToArchive` is listed by `getArchiveHeaders`, and after its sent-box copy, `moveToTrashFrom(id, boxType: BoxType.inbox, boxId: <getArchiveBoxId()>)` takes it out of the archive and leaves it in the trash (#64); and `moveToTrashFrom`, which cleans up: moving the sent-box copy of each message to the trash leaves its inbox copy in the inbox, and moving the inbox copy then takes it out of the inbox and leaves the message in the trash (#60). For each move, `moveToTrashFrom` returns `true`, and `getMessage` agrees with the listings: `null` in the box the copy left, the other copy in its box (the inbox copy also in the archive folder), the message in the trash (#96).

`test/live/messages_search_live_test.dart` only reads: `searchRecipientsForCompose` finds the own account by its name, with one search on its compose form (#97), and `searchRecipientsForComposeAll` searches a name that is no one's and then the own name on one compose form, and the second search finds the own account (#107). The guard lets a recipient search out only on a compose form loaded through it, with the empty selection the library sends; a search registers no one on the form.

`test/live/intradesk_write_live_test.dart` writes in Intradesk, in one folder only: `tests` in `2. SMA` at the root, found by name, which must be empty when the run starts (#128). It adds a folder (`createFolder`) and checks it in the listing, adds it a second time and checks that Intradesk renames the new one (`name (1)`), adds a weblink to the new folder with an address without `http://` (`createWeblink`), uploads a file to it (`uploadFiles`) and downloads it back unchanged, sends a made-up ID and the IDs of its own file, weblink and folder as another kind to the trash, and checks that each is a `SmartschoolIntradeskItemNotFoundError` and that nothing moved (#133), and then moves all of it to Intradesk's trash (`trashFile`, `trashWeblink`, `trashFolder`) and checks that the test folder is empty again. It reads the new folder by its ID alone (`getFolder`, `getFolderPath`, #132), and again once it is in the trash, where Smartschool answers its parents as those of a folder at the root and `getFolder` throws a `SmartschoolIntradeskFolderNotFoundError`. Every folder and weblink it makes is named `dartschool test <run tag> ...`, every file `dartschool-test-<run tag>-....txt`; at the end, also when a test failed, it moves what is left to the trash. It never deletes for good. The guard lets an Intradesk write out only in that folder, as Smartschool's own listings name it (read through the guard), and in the folders the run made there; refuses a name without the run's tag, a move to the trash of anything the run did not make (but a made-up ID that the guard made up itself, a random UUID, once per kind; and an item of the run as another kind, once, when the run allows it and before the item went to the trash, #133), a second take of an upload directory, and every other Intradesk POST (a confidential folder, a rename, a move, a copy, a restore).

`test/live/intradesk_folder_live_test.dart` only reads (#132): `getFolderParentIds`, `getFolder` and `getFolderPath` of the test folder, of `2. SMA` at the root and of a folder two levels down, each compared with the listing that holds it, and a made-up ID and the ID of a file, which are no folder (`404`). Names are compared, never shown.

`test/live/lesson_content_write_live_test.dart` writes in the Lesfiches module, in the own library only, which is private to the teacher (#129). It makes a lesson lesfiche with a course, a weblink and an attachment in one create (`createLesson`) and checks it with `getDetail` and `getItems`, downloads the attachment back unchanged (also as a stream), changes its name, icon, info, courses and visibility, adds, changes and removes a weblink and an attachment, checks that an empty name, an address the web client refuses and a course the school does not have send no write, makes an assignment lesfiche of a school assignment type (`createAssignment`), and moves both to the module's trash (`trash`), after which `getItems` no longer lists them. Every lesfiche it makes is named `[dartschool test] <run tag> ...`, every file `dartschool-test-<run tag>-....txt`; at the end, also when a test failed, it moves what is left to the trash. It never deletes a lesfiche for good, never shares or plans one, and sends no label or goal. The guard lets a lesfiche write out only for a lesfiche the run made (as Smartschool answered its create) and did not move to the trash: a create named after the run, without labels, goals or other lists, at most two per run; a rename to a name after the run, the other edits, its weblinks and attachments (the DELETE of one of them is the only DELETE the live suite sends), an upload directory handed out through the guard once; and the move to the trash of what the run made. It refuses everything else in the module (labels, goals, deeplinks, a share, a restore, `delete/bulk`).

Its rules, kept by the tests and, on the wire, by a guard on the live client (`test/live/support/live_wire_guard.dart`, a Dio interceptor that refuses a request before it is sent and fails the test):

- Every message goes to the **own account only** (the account of `credentials.yml`, as `getCurrentUserAsRecipient()` and the session name it), in To, CC or BCC, never to a group. The guard refuses registering anyone else on a compose form, checks Smartschool's answer to every registration, and refuses a submit with anyone else registered (a reply form comes with its recipients registered already).
- Replies go only to a message the same run sent to the own account only, after checking that its reply form names the own account alone.
- Every subject starts with `[dartschool test]` and a tag of the run (a reply's with `Re: ` before it).
- No LVS copy (`lvsCopy`) and no delayed send (`sendAt`: the library cannot cancel a scheduled message yet, #58).
- At the end, also when a test failed, the run moves both copies of every message it sent to the trash (a message you send yourself has the same ID in the inbox and the sent box): first the sent-box copies, then the inbox copies (an archived one out of the archive folder, #64), once each, after checking the run's subject and that the own account sent it. It moves them with `moveToTrashFrom`, which names the box of the copy (#60). It never empties the trash: emptying it stays manual.
- It moves to the archive (`moveToArchive`) only the inbox copy of a message it sent, one message per request and once, while the inbox lists it with the run's subject (#64).
- It sends no `quick delete` (`moveToTrash`) at all, and moves no ID it did not send in the same run, `0` included (#61). A `quick delete` names the ID only, Smartschool acts on whichever copy of the ID its session state points to, and one of a copy in the trash deletes it for good: it is never a guaranteed no-op. The guard refuses every `quick delete`, a move of a copy that Smartschool did not list in its box (or in the archive folder that Smartschool names: its folder tree, `requestmovelist`, which `getArchiveBoxId` reads since #141, or its Messages page, #64) with the run's subject or that the run did not check there, a move out of any other folder, and a second move of a copy; likewise a move to the archive of a message the inbox did not list with the run's subject, of more than one message at once, or a second one.
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
