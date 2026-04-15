

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
