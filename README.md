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
- Skore gradebook support (`SkoreGradebookService`): as the logged-in teacher, without admin rights, the teacher's own gradebooks of the current or an earlier school year and those colleagues shared with them, the periods (open or closed, and until when) and the pupils of a gradebook, with whether the teacher may change it, and the evaluations of a period with whether and when they are published, the pupils' grades and their feedback, and the report periods with each pupil's results so far and course comment; create an evaluation in a period, never published, save pupils' grades and feedback in it, and write a pupil's course comment on a report.
- Planner support (`PlannerService`): the planned elements (lessons, assignments, timetable slots, ...) of the own planner, of another teacher, of a class or of a location in a period, optionally of some types only, and the full detail of one element; find the calendar of a class, a teacher or a location by name; the school's assignment types, and the assignments of classes in a period with the planner's workload figures per day (the planner's workload view); in the own planner, fill an empty lesson hour with a new lesson or with a lesfiche of the Lesfiches library and clear the hour again, add an assignment (a test, a task) for classes and move it to the planner's trash again, and change the name and info of an own lesson or assignment, with checks before each write that keep it out of colleagues' elements, and creates, fills, clears and trashes that are never retried.
- Lesfiches support (`LessonContentService`): the lesfiches (lessons and assignments) a teacher keeps in the Lesfiches module, with their labels and courses (named after the school's course list), to plan into the planner; one lesfiche in full, with its private info, weblinks and attachments (downloaded unchanged); and, in the own library, make a complete lesfiche in one create (info, courses, weblinks and attachments, each with when pupils see it), change its name, icon, info, courses and visibility, add, change and remove its weblinks and attachments, and move lesfiches to the module's trash, with checks before each write and creates that are never retried.
- Pupil tracking system support (`LvsService`, LVS): as the logged-in teacher, find a pupil by name and read the overview of the pupil's file (who, which class, today's attendance, and which sections of the file hold something), the pupil's notes per category (behaviour, care, talks with parents: the school's own categories) or all of them, with their fields, the pupil's results in every course (evaluations with their scores, feedback, reports), the pupil's support plan (support needs, goals, approach, profile sketch), and whether the account may use the LVS; read only, by an allowlist of requests, with models and errors that never print a pupil's data (see [`doc/lvs-privacy.md`](doc/lvs-privacy.md)).

---

## Installation

Add the package to `pubspec.yaml`:

```yaml
dependencies:
	flutter_smartschool: ^0.4.0
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

## Reference

The README gives an overview of each service, with a short example. The rest of the reference (the methods, the checks before a write, the errors, what was seen live) is in `doc/`, as pub.dev limits `README.md` to 256 KB:

| Part | Reference |
|---|---|
| `SmartschoolClient` | below, in this README |
| `MessagesService` | [`doc/messages.md`](doc/messages.md) |
| `IntradeskService` | [`doc/intradesk.md`](doc/intradesk.md) |
| `PresenceService` | [`doc/presence.md`](doc/presence.md) |
| `SkoreService`, `SkoreGradebookService` | [`doc/skore.md`](doc/skore.md) |
| `PlannerService` | [`doc/planner.md`](doc/planner.md) |
| `LessonContentService` | [`doc/lesson-content.md`](doc/lesson-content.md) |
| `LvsService` | [`doc/lvs.md`](doc/lvs.md) |
| Models and enums | [`doc/models.md`](doc/models.md) |
| Exceptions | [`doc/exceptions.md`](doc/exceptions.md) |

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

The rest of its reference is in [`doc/messages.md`](doc/messages.md#messagesservice): [Reading](doc/messages.md#reading), [Mutating](doc/messages.md#mutating), [Composing & searching](doc/messages.md#composing--searching), [Thread subject helpers](doc/messages.md#thread-subject-helpers), [Event-driven message detection](doc/messages.md#event-driven-message-detection), [Static parsers (exposed for testing)](doc/messages.md#static-parsers-exposed-for-testing).

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

The rest of its reference is in [`doc/intradesk.md`](doc/intradesk.md#intradeskservice): [Methods](doc/intradesk.md#methods), [Example](doc/intradesk.md#example).

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

The rest of its reference is in [`doc/presence.md`](doc/presence.md#presenceservice): [Methods](doc/presence.md#methods), [Errors](doc/presence.md#errors), [Example](doc/presence.md#example).

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

The rest of its reference is in [`doc/skore.md`](doc/skore.md#skoreservice): [Methods](doc/skore.md#methods), [Assigning a teacher](doc/skore.md#assigning-a-teacher), [Sharing a gradebook](doc/skore.md#sharing-a-gradebook), [Errors](doc/skore.md#errors).

---

## `SkoreGradebookService`

Reads Skore's gradebook **as the logged-in teacher** (#148, #149): what a teacher sees at `/SkoreGradebook` ("Puntenboek"). Any teacher can use it with their own login; it needs none of the admin rights of `SkoreService`. It reads, creates evaluations (#150), saves grades (#151), feedback (#152) and the course comment on a report (#195), and never publishes.

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

// Gradebooks colleagues shared with you (#191): read them as your own, and
// save grades and feedback in one shared to write.
final shared = await gradebooks.getSharedGradebooks(); // List<SkoreGradebook>
for (final book in shared) {
  print('${book.gradebookId}  ${book.className}  ${book.ownerName}  ${book.access.name}'); // write / read
}

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
final note = await gradebooks.saveFeedback(books.first, created, sheet.pupils.first.id, 'Goed gewerkt.'); // SkoreSavedFeedback
print(note.isUpdate ? 'changed' : 'created'); // for a change, note.before is the feedback as it was (#158)

// A report period ("Rapporten | Rapport 1", #195): each pupil's results so far
// and the course comment that goes on the report.
final r1 = sheet.reports.first; // SkoreReportPeriod: R1D, open until ...
final report = await gradebooks.getReport(books.first, r1.id); // SkoreReport
for (final pupil in report.pupils) {
  print('${pupil.pupilId}: ${pupil.results.map((r) => r.value).join(' ')} '
      '${pupil.comment?.text}');
}
// Writes it, replacing only the comment Skore holds now (null: none yet).
final current = report.pupil(sheet.pupils.first.id)!.comment!;
final comment = await gradebooks.saveReportComment(books.first, r1.id,
    sheet.pupils.first.id, 'Goed gewerkt.', replacing: current.isEmpty ? null : current.text);
// Clears it again (#203), only while it is the comment just written.
await gradebooks.clearReportComment(books.first, r1.id, sheet.pupils.first.id,
    replacing: comment.text);
```

The rest of its reference is in [`doc/skore.md`](doc/skore.md#skoregradebookservice): [Methods](doc/skore.md#methods-1), [Errors](doc/skore.md#errors-1).

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

The rest of its reference is in [`doc/planner.md`](doc/planner.md#plannerservice): [Calendars](doc/planner.md#calendars), [Finding a calendar by name](doc/planner.md#finding-a-calendar-by-name), [Naming a calendar by its ID](doc/planner.md#naming-a-calendar-by-its-id), [Assignment types and workload](doc/planner.md#assignment-types-and-workload), [Lessons in the own planner](doc/planner.md#lessons-in-the-own-planner), [Assignments in the own planner](doc/planner.md#assignments-in-the-own-planner), [Methods](doc/planner.md#methods), [What the planner shows](doc/planner.md#what-the-planner-shows), [Errors](doc/planner.md#errors).

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

The rest of its reference is in [`doc/lesson-content.md`](doc/lesson-content.md#lessoncontentservice): [Methods](doc/lesson-content.md#methods), [Errors](doc/lesson-content.md#errors).

---

## `LvsService`

Reads Smartschool's pupil tracking system (LVS, "leerlingvolgsysteem", `/?module=LVS`) **as the logged-in teacher** (#160): finds a pupil by name, reads the overview of the pupil's file, the pupil's notes per category (#161), results (#162), support plan (#163) and absences (#164). The LVS holds the most sensitive data of Smartschool: what this service returns is about pupils, see [`doc/lvs-privacy.md`](doc/lvs-privacy.md).

```dart
final lvs = LvsService(client);

if (await lvs.checkAccess()) {
  final found = await lvs.searchPupils('janssens');   // List<LvsPupilMatch>
  final file = await lvs.getPupilFile(                // LvsPupilFile
    pupilId: found.first.pupilId,
    classId: found.first.classId,
    withTodayStatus: false, // the sections only: no attendance (#186)
  );
  final withItems = file.allSections.where((s) => s.hasItems);
  print('${withItems.length} sections hold something');

  // The school's own categories of notes ("gedrag", "zorg", ...), each read
  // on its own: a category's notes are not its sub-categories'.
  final categories = [
    for (final c in file.noteCategories) ...[c, ...c.descendants],
  ];
  for (final category in categories.where((c) => c.hasNotes)) {
    final notes = await lvs.getNotes(                 // List<LvsNote>
      pupilId: file.pupilId,
      classId: file.classId,
      categoryId: category.id,
    );
    print('${notes.length} notes');
    // A note's date is in UTC; the LVS shows it on its day in Belgian time:
    // lvsDayOf(note.date), 'YYYY-MM-DD' (#185).
  }

  // The results, in every course: evaluations page by page, up to a cap.
  final evaluations = await lvs.getAllEvaluations(    // LvsEvaluationList
    pupilId: file.pupilId,
    classId: file.classId,
  );
  print('${evaluations.evaluations.length} evaluations');
}
```

The rest of its reference is in [`doc/lvs.md`](doc/lvs.md#lvsservice): [Methods](doc/lvs.md#methods), [Errors](doc/lvs.md#errors).

---

## Models

The models the services return, with their fields, are in [`doc/models.md`](doc/models.md#models).

---

## Enums

The enums, with their values, are in [`doc/models.md`](doc/models.md#enums).

---

## Exceptions

When each exception is thrown, and how to catch a login that failed, a Smartschool that cannot be reached and a client that was disposed, is in [`doc/exceptions.md`](doc/exceptions.md).

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

pub.dev refuses a `README.md` or `CHANGELOG.md` larger than 262144 bytes (256 KB) at upload, which `dart pub publish --dry-run` does not check. `test/docs_guard_test.dart` fails from 240000 bytes on, and checks that every relative link of the README and of `doc/` leads to a file and heading that exist (#199). So document a service's methods, checks and errors in its file in `doc/` (see *Reference* above), and keep the README to its overview and a short example; archive the oldest full entries of the CHANGELOG in `doc/CHANGELOG-archive.md`.

### LVS data

The pupil tracking system (LVS, `/?module=LVS`) holds the most sensitive data of Smartschool. Before any work on it (research, captures, fixtures, tests, examples, issues, PRs), read **[`doc/lvs-privacy.md`](doc/lvs-privacy.md)**: no value from a live LVS answer goes into the repository or onto GitHub; raw captures stay in a temp folder outside the repository, never in `dev_dumps/`; LVS fixtures (`test/fixtures/lvs/`) are written by hand with the fakes of `test/fixtures/lvs/FAKES.md`, and `test/lvs_fixtures_guard_test.dart` checks them (fake names, ids in a reserved range, no base64 names anywhere under `test/`, no pasted answers). A browser capture is reduced to shapes with `tool/lvs_har_shapes.dart` before it is shared (*Capturing with the browser* in `doc/lvs-privacy.md`).

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

### Captures

Write captured answers to a folder **outside the repository** (a temp folder), not into the working tree. `dev_dumps/` is git-ignored, but a `git add -f`, a tool or an agent can still pick a file up there; an answer of the pupil tracking system (LVS) never goes there, nor anything that quotes one: see [`doc/lvs-privacy.md`](doc/lvs-privacy.md). The server tells an MCP client the same in its `initialize` instructions.

> **Keep `credentials.yml` local and private.** It is listed in `.gitignore` and must never be committed.
