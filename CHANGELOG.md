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
