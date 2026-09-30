## 0.2.11 - Unreleased

### Added
- Auth: typed login failures (#11). Each login failure is now thrown as its own subclass of `SmartschoolAuthenticationError`, so callers can match on the type instead of on the message text:
  - `SmartschoolInvalidCredentialsError` — the username or password is rejected (also SSO-only accounts);
  - `SmartschoolTwoFactorRequiredError` — Smartschool asks for a 2FA code, but `mfa` holds no TOTP secret;
  - `SmartschoolTwoFactorRejectedError` — the 2FA code is rejected;
  - `SmartschoolUnsupportedTwoFactorMethodError` — the account's 2FA does not offer an authenticator app; `availableMethods` lists what it does offer;
  - `SmartschoolAccountVerificationRequiredError` — Smartschool asks for account verification (date of birth), but `mfa` is empty or not a date;
  - `SmartschoolAccountVerificationRejectedError` — the account verification answer is rejected.

  Backwards compatible: they extend `SmartschoolAuthenticationError` and keep the previous messages, so existing `catch` clauses and message checks keep working. The base class is still thrown for the other authentication failures (maximum login attempts, an unrecognised login step, HTML where data was expected).
- `SmartschoolConnectionError` (extends `SmartschoolException`): Smartschool cannot be reached. Carries the underlying error as `cause`.

### Fixed
- Auth: an XML or form POST on an expired session now logs in again (#8). Smartschool does not redirect such a POST (the XML dispatcher behind `MessagesService.getHeaders()`, `postFormRaw`, …) to `/login`: it answers with a bare `401` and an empty body. The auth interceptor only reacted to landing on the login chain, so it never logged in again, and `postXml` threw `SmartschoolParsingError` ("non-XML response") — `postFormRaw` and the other raw helpers returned an empty string. A `401` now starts the login chain from `/login` (password, 2FA or account verification as needed) and retries the request once, as a GET that is redirected to `/login` already did. A login failure on that path arrives as the matching `SmartschoolAuthenticationError` subtype, like any login triggered by a regular request (see #20 below); a retry that Smartschool still answers with `401` is reported as a `SmartschoolAuthenticationError` instead of a parsing error.
- Auth: the request that triggered a new login is now accepted when it is retried (#9). With an expired session in the cookie cache, the client logged in again (password and 2FA accepted), but the retry was refused anyway: a GET was redirected to `/login` again (`getJson` threw `SmartschoolAuthenticationError` "Expected JSON but received HTML"), an XML or form POST got a `401` again. The retry copied the headers of the original request, including its `Cookie` header with the refused `PHPSESSID`; `CookieManager` merged that header with the jar and listed the stale session id first, and Smartschool reads the first one. The retry now takes its cookies from the jar only, which holds the new session. Only a new `SmartschoolClient`, which reloads the cookie file, used to work around it.
- Auth: a login failure during a service call is now thrown as itself, not wrapped in a `DioException` (#20). When a regular request finds the session cold or expired, the auth interceptor logs in first; when that login failed, Dio handed the caller a `DioException` with the `SmartschoolAuthenticationError` (or the #11 subtype) as its `error`, so an `on SmartschoolAuthenticationError` / `on SmartschoolInvalidCredentialsError` around `MessagesService(client).getHeaders()` or any other service call never matched — only `ensureAuthenticated()` unwrapped it. The request methods of `SmartschoolClient` (`getJson`, `postJson`, `postXml`, `getRaw`, `postFormRaw`, `postMultipartRaw`, `postFormEncodedRaw`, `download`), and so every service, now throw any `SmartschoolException` that a request failed with as itself. **Behaviour change:** code that caught `DioException` around a service call and read the login failure from its `error` must catch the `SmartschoolAuthenticationError` (or `SmartschoolException`) instead. A `DioException` that carries no `SmartschoolException` — a network failure, for one — is still thrown unchanged, and a request made on `client.dio` directly still gets the wrapped form.
- Auth: `ensureAuthenticated()` no longer reports an unreachable Smartschool as a failed login (#10). A host that does not resolve, a refused or dropped connection, a timeout or a failed TLS handshake — also halfway through the login chain — used to surface as `SmartschoolAuthenticationError('Unable to validate Smartschool session: …')`, with the network error only in the message text, so an app could not tell the user whether to check their network or their password. It is now thrown as a `SmartschoolConnectionError` with the `DioException` as its `cause`. **Behaviour change:** `SmartschoolConnectionError` is deliberately not a `SmartschoolAuthenticationError`, so a `catch` of the authentication error no longer catches a network problem; catch `SmartschoolConnectionError` (or `SmartschoolException`) for that. Other failures of `ensureAuthenticated()` are unchanged.

## 0.2.10 - 2026-09-15

### Fixed
- Auth: a login POST that Smartschool answers with a **302** (`Location: /` — what the platform sends for an accepted password since September 2026) is no longer reported as `Login failed. Check username/password…` (#6). `dart:io`'s `HttpClient` only follows a redirect after a POST when it is a 303, so `doLogin()`'s response still had `realUri` on `/login` and the auth chain read that as a rejected password — with the right password, and before the 2FA step was ever reached. `_rawPost` now follows a 301/302 with a GET of the `Location`, as a browser does, so the chain sees the real next page (`/2fa`, `/account-verification`, or home). A wrong password (302 back to `/login`) still reads as a failed login.

## 0.2.9 - 2026-07-05

### Added
- `PresenceService` — writes a pupil's absence/presence code for a specific half-day via Smartschool's **internal** Presence module (the official/public API cannot write presences). Primary use case: mark a pupil **Te laat** ("late"), optionally **Te laat zonder geldige reden** ("late without a valid reason"), with a motivation.
  - `setLate({userId, classGroupId, date, part, withoutValidReason, motivation})` and `setPresent({userId, classGroupId, date, part, motivation})` — resolve the class structure, resolve the status code by name, locate the target half-day cell, and save it (handling both the update case and the create case when a half-day has no record yet).
  - Read helpers `getConfig()`, `getAllCodes(structId)`, and `getClassPupils({classGroupId, date, schoolyearRefDate})`, with the config cached and codes cached per structure.
  - Status codes are resolved **dynamically by name** (`Presence/Code/getAllCodes`) rather than hard-coded, because code IDs are per-school/per-structure. "Te laat zonder geldige reden" is resolved as an alias of "Te laat".
  - Requires an account with **Presence-handling access** for the class; otherwise the server rejects the save. A non-empty `errors[]` in the response is surfaced as a `SmartschoolPresenceError`.
- `DayPart` enum (`morning` / `afternoon`, wire values `"am"` / `"pm"`).
- Presence models `PresenceConfig`, `PresenceClassRef`, `PresenceCode`, `PresenceAlias`, `PresencePupil`, `PresenceHalfDay`.
- `SmartschoolPresenceError` exception (carries the server-reported `errors`).
- New example `example/set_late_example.dart`: marks the configured pupil late and restores the original status.

> **Identity note:** the Presence module speaks Smartschool's internal `userID` (not the public API's `AccountID` / `RegisterID` / `UID`). Callers supply the internal `userId` and the class `groupID`; classes map to the public API by `adminNumber`.

## 0.2.8 - 2026-07-05

### Fixed
- Auth: a **successful** 2FA verification is no longer misdetected as a failure (#1). `_driveAuthChain` decided success/failure by inspecting the request URL, but `do2fa()` POSTs to `/2fa/api/v1/google-authenticator` — whose path contains `/2fa/` — so a correct TOTP code (HTTP 200, `{"success":true}`) was wrongly classified as "still on the 2FA page" and threw `SmartschoolAuthenticationError('2FA verification failed…')`. Success/failure is now decided from the response **body** (`success: true`/`false`) via the new `SmartschoolClient.parse2faSuccess`. This surfaced only on a cold session (no cached cookie) on the first authenticated call.
- MCP `login` tool now verifies the session with a real authenticated request and reports the true status instead of swallowing the error and always returning `ok: true`.

## 0.2.7 - 2026-04-18

### Added
- `SmartschoolUser` model — `id` (int), `displayName` (String), `avatarUrl` (String?) — representing the currently authenticated user.
- `SmartschoolClient.getCurrentUser()` — returns a `SmartschoolUser` for the session owner. Reads directly from the `authenticatedUser` data already embedded in every Smartschool page; no extra HTTP requests are made after the first authenticated call.

### Fixed
- `SmartschoolClient.authenticatedUser` getter now correctly handles sessions where cookies are already valid and no authentication flow is triggered. Previously, calling `await authenticatedUser` after a cookie-based login silently returned an error because `_authenticatedUser` was never populated (the auth interceptor only calls `_parseLoginInformation` during a fresh login). The getter now falls back to fetching `/` and parsing it when `_authenticatedUser` is still `null` after `platformId`.

## 0.2.6 - 2026-04-18

### Added
- `MessagesService.getSentMessageRecipients(msgId)` — resolves the original recipients of a sent-folder message with their numeric user IDs. The reply-all compose page for the outbox (`boxType=outbox&composeType=2`) pre-populates the To field with both the original recipients and the authenticated user (as sender); this method filters out the authenticated user and returns the remainder as a `(List<MessageSearchUser>, List<MessageSearchUser>)` record (To, CC). `getReplyAllRecipients` did not work for sent messages because no exclusion of the sender was applied.
- `MessagesService.parseSentMessageRecipients(htmlBody)` static method — pure HTML parser counterpart to `parseReplyAllRecipients` for the sent-folder case; combines `parseComposeCurrentUserIds` to identify the sender and `parseReplyAllRecipients` to extract all recipient spans, then removes the sender by `userId`.
- New example `example/get_recipients_from_sent_messages.dart`: fetches the 20 most recent sent messages and prints the resolved recipient IDs for each via `getSentMessageRecipients`.

## 0.2.5 - 2026-04-17

### Added
- `MessagesService.getMessage` now accepts an `includeAllRecipients` flag (default `false`). When set to `true` the request is sent with `limitList: 'false'`, and the server returns the full list of recipient display names in `FullMessage.receivers` / `ccReceivers` / `bccReceivers` instead of a truncated list.
- `MessagesService.getReplyAllRecipients(msgId, {boxType})` — parses the reply-all compose page and returns every pre-populated recipient as a `(List<MessageSearchUser>, List<MessageSearchUser>)` record (To, CC). This is the only server-side endpoint that exposes numeric user IDs for all recipients, which are required for a subsequent reply-all send.
- `MessagesService.parseReplyAllRecipients(htmlBody)` static method — pure HTML parser for the compose reply-all page, extracted for unit-testing without a live session.
- `FullMessage` now exposes `totalNrOtherToReceivers`, `totalNrOtherCcReceivers`, and `totalNrOtherBccReceivers` — the count of recipients hidden behind a "show more" link when `limitList` is `true`.
- New example `example/reply_all_recipients_example.dart`: scans the 50 most recent inbox messages, locates the first message with multiple To recipients and the first with multiple CC recipients, and prints the full recipient list with user IDs resolved via `getReplyAllRecipients`.
- New test fixtures `test/fixtures/smartschool/requests/post/postboxes/show message all recipients.xml` and `test/fixtures/smartschool/requests/get/composemessage/reply-all.html` (all personal data replaced with fakes).
- Six new tests in `test/message_fixtures_test.dart` covering full-recipient XML parsing, To/CC separation by `typeatt`, correct ID extraction, graceful skip of incomplete `receiverSpan` elements, missing `typeatt` defaulting to To, and missing `userltatt` defaulting to zero.

## 0.2.4 - 2026-04-16

### Fixed
- `SendMessageParams` is now correctly exposed.


## 0.2.3 - 2026-04-16

### Added
- `MessagesService.markRead(msgId, {boxType})` — explicitly marks a message as read using the `postboxes / mark message read` XML dispatcher action. This is the call the Smartschool website makes when opening a message (batched alongside `show message` and `attachment list`). `getMessage` continues to leave read-state untouched; call `markRead` separately when you want the server to record the message as opened.
- New fixture `test/fixtures/smartschool/requests/post/postboxes/mark message read.xml` and two tests covering the response parsing.
- New example `example/mark_read_toggle_example.dart` that toggles the read/unread status of the first inbox message and explains manual browser verification.

### Fixed
- **`ShortMessage.unread` and `FullMessage.unread` were inverted.** Smartschool's list XML uses `<status>0</status>` for *unread* messages and `<status>1</status>` for *read* messages — matching the website's own JavaScript (`isNew = parseInt(status) <= 0`). The `<unread>` XML field carries the same numeric value as `<status>` but its name implies the opposite, leading to a silent inversion in the Dart models. Both models now derive `unread` from `<status>` (`status == 0 → unread: true`) instead of from the misleadingly-named `<unread>` field. Callers that used `msg.unread` to display bold/unread indicators, count unread messages, or drive mark-read/unread logic were all affected.
- Corrected the `message list` and `message list archive` fixtures to reflect the live server's consistent behaviour (both `<status>` and `<unread>` fields always carry the same value).

## 0.2.2 - 2026-04-15

- Added notification support for new messages: `MessagesService` now emits real-time updates via `messageCounterUpdates` and can be bound to `SmartschoolClient.notificationCounterUpdates` for push-style notification flows.
- Increased test coverage for `SmartschoolClient` and core session logic.
- Added `test/session_additional_test.dart` with more unit and error-path tests.
- Improved analyzer and linter compliance in test files.
- Maintenance: removed unused imports, unnecessary type checks, and null comparisons in tests.
- No breaking changes; all public APIs remain stable.

## 0.2.1 - 2026-04-11

- Added message thread-subject helpers on `MessagesService`:
	- `threadSubjectKey(subject)` for stable thread grouping.
	- `ensureReplySubject(subject, {replyPrefix})` for consistent reply headers.
- Clarified message attachment docs and examples:
	- Corrected `MessageAttachment` field names (`fileId`, `name`, `mime`, `size`, ...).
	- Added explicit `attachment.download(client)` usage for byte downloads.
- Documented explicit logout/session reset path via `SmartschoolClient.clearCookies()`.

## 0.2.0 - 2026-04-11

- Added `IntradeskService` with root/folder listing and file download support.
- Added Intradesk data models (`IntradeskListing`, `IntradeskFolder`, `IntradeskFile`, revisions, capabilities, platform/owner).
- Added interactive Intradesk browser example (`example/intradesk_browser.dart`) for terminal-based navigation and downloads.
- Added fixture-driven and model-flow test coverage for Intradesk parsing/mapping.
- Updated README with Intradesk usage, scope notes, and example controls.

## 0.1.0 - 2026-04-11

- First public release of `flutter_smartschool`.
- Added authenticated Smartschool session client with cookie persistence and MFA/account-verification support.
- Added `MessagesService` with inbox/archive listing, message retrieval, attachment listing, recipient search, and compose/send flow.
- Added archive-box ID discovery and compose current-user ID parsing helpers.
- Added examples and test coverage for message workflows and parser behavior.
