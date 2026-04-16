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
