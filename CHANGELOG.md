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
