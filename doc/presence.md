# Presence

The reference of `PresenceService`, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps its overview, with a short example: [`PresenceService`](../README.md#presenceservice).

## `PresenceService`

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
