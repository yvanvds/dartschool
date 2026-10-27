# Models and enums

The models the services return, with their fields, and the enums, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The reference of each service is in its own file of `doc/`, listed in the [README](../README.md#reference).

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
Returned by `SkoreGradebookService.getGradebook()`. The `gradebook`, its `courseName` (without the grade), its `periods`, the `activePeriod` Skore opens it on (`null` without periods), its report periods (`reports`), the `pupils` of its class, and `writable` / `isCoordinator` from Skore's `getGradebookContext`.

### `SkoreGradebookPeriod` / `SkoreGradebookPupil`
A period of a gradebook: `id`, `name` (`DW1`), `fullName`, `isOpen`, `closesAt` (UTC, or `null`), `info` (Skore's HTML description) and `categoryMode` (`1`: evaluations). A pupil of a gradebook: `id` (the Smartschool user ID), `classId`, `number` (the class number, or `null`), `name` (`Last, First`), `displayName` (`First Last`), `isActive`, and the getter `rowKey` (`pupil_<id>_<classId>`).

### `SkoreEvaluation` / `SkorePublication`
Returned by `SkoreGradebookService.getEvaluations()`. An evaluation: `id` (Skore's `refID`), `evaluationId`, `gradebookId`, `periodId`, `column` (not stable), `title`, `shortName` (or `null`), `date` (the day), `max`, `componentId` / `componentName` (`DW`; `0` / `""` for none), `type` (`SkoreEvaluationType.points`, `.scale`, `.unknown`) and `typeCode`, `courseId` / `courseName`, `isPlannerEvaluation`, `publication` and `results`. A `SkorePublication`: `state` (`SkorePublicationState`), `at` (UTC, or `null`), `isPublic` (published or scheduled), `rawPublic`, `rawPublicDateTime`, and `stateAt(time)`.

### `SkoreEvaluationResults` / `SkoreGrade`
The grades of an evaluation: `evaluationId`, `grades` (one per pupil of the class), `classAverage` and `groupAverage` (Skore's strings, or `null`), and `gradeOf(pupilId)`. A grade: `pupilId`, `classId`, `grade` (Skore's value, or `null`), `value` (as a number), `hasFeedback`, `categoryType` and `cellEvaluationId` (the cell's `p`), and the getter `rowKey`.

### `SkoreReportPeriod` / `SkoreReport`
A report period of a gradebook (`SkoreGradebookSheet.reports`, #195): `id`, `name` (`R1D`), `fullName` (`Rapport 1`), `isOpen`, `closesAt` (UTC, or `null`), `info` (Skore's HTML), and Skore's raw `typeCode` and `rating`. Returned by `SkoreGradebookService.getReport()`, a `SkoreReport`: `gradebookId`, `reportId`, `courseId` / `courseName`, `components` (`SkoreReportComponent`: `column`, `name`, `classAverage`), `hasComments`, `commentMaxLength` and `pupils` (`SkoreReportPupil`: `pupilId`, `classId`, `results`, `comment`, `rowKey`, `resultOf(column)`), and `pupil(pupilId)`. A `SkoreReportResult`: `column`, `value` (Skore's text, or `null`), `isLow`. A `SkoreReportComment` (also returned by `saveReportComment()`): `pupilId`, `reportId`, `courseId`, `text`, `isEditable`, `cellParams` and `isEmpty`. They print counts, not the comments.

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

### `LvsAccess`
Returned by `LvsService.checkAccessDetails()` (#184): `granted` (whether the LVS answers the root of its class tree to the account), `classCount` (the classes that root lists; `0` when not granted), and `LvsAccess.denied()`. Compared by value. Prints the flag and the count only.

### `LvsPupilMatch`
Returned by `LvsService.searchPupils()`. A pupil whose name matches: `pupilId`, `classId`, `name` (plain text), `className`. Prints no value.

### `LvsPupilFile` / `LvsTeacher`
Returned by `LvsService.getPupilFile()`. `pupilId`, `classId`, `name`, `className`, `classDescription` (`""` when none), `teachers` (the class teachers, `LvsTeacher`: `id`, `name`; empty when none: the LVS sends an empty map as `[]`), `sections` (`List<LvsSection>`, top level first), `todayStatus` (`LvsTodayStatus`; `LvsTodayStatus.none` when read with `withTodayStatus: false`, #186), and the getters `allSections` (every section at any depth, depth first) and `supportPlanSections` (#163). Prints counts only.

### `LvsSection` / `LvsSectionType`
A section of a pupil's file: `id` (for a category of notes or of support plans, the category ID; `0` for the LVS's own parts, so not unique), `type` as the LVS names it (`LvsSectionType`: `items`, `handelingsplannen` (`supportPlans`), `skore`, `results`, `deliberation`, `forms`, `contact_moments`, `absents`, `career`, `messages`, `smartsignal`; another type is kept as it comes, `isKnownType` tells), `name`, `isTitle` (a heading only), `hasItems`, `hasNewItems`, `children`, and the getter `descendants`. The sections are the school's, the same for every pupil; the flags are about the pupil.

### `LvsTodayStatus` / `LvsHalfDayStatus`
A pupil's attendance today: `halfDays` (empty when none), and the getters `am` and `pm`. `LvsHalfDayStatus`: `partOfDay` (`am`, `pm`), `code`, `name`, `color` (`String?`).

### `LvsCategory`
From `LvsPupilFile.noteCategories` (#161): a category of notes, a section of type `items`, with `id` (what `getNotes` takes), `name` (the school's own), `isTitle`, `hasNotes`, `hasNewNotes`, `subcategories` and the getter `descendants`. A category under a section of another type is listed in that section's place. Prints counts only.

### `LvsSchoolYear`
The period of `getNotes`, `getAllNotes` and the results reads (sent as `startDate` / `endDate`): `from` and `until` (days), `firstDay` / `lastDay` (`YYYY-MM-DD`), `isEmpty`. `LvsSchoolYear.starting(2030)` is 1 September 2030 to 31 August 2031; `containing(day)`; `current({now})` the one of today in Belgian time. Any other range of days can be given. `tryParse(label)` reads a note's `schoolYear`; `includesDay(instant)`, `includesNote(note)` (#180).

### `lvsDayOf`
`lvsDayOf(instant)` (`String`, `YYYY-MM-DD`): the day of a moment in Belgian time (Europe/Brussels), the day the LVS shows it on (#185). The LVS models give their dates in UTC (`LvsNote.date`, `LvsNoteField.date`, `LvsEvaluation.date`, `LvsFeedbackEvaluation.date`, `LvsReport.date`): a note made at 00:30 in Brussels is dated 22:30 UTC the day before, and `toLocal()` gives the day of the computer's own time zone. It is the day `LvsSchoolYear.includesDay` and `includesNote` keep a note by, and the `value` of a date field.

### `LvsNote`
From `getNotes` and `getAllNotes` (#161): `id`, `categoryId` (for `getNotes`, the category read), `categoryName` (`""` when the answer names none), `title`, `date` (UTC; its Belgian day: `lvsDayOf(note.date)`), `author`, `isConfidential`, `isNew`, `viewed`, `schoolYear` (as the LVS gives it, `YYYY-YYYY`), `fields`. Prints the count of fields only.

### `LvsNoteField` / `LvsNoteFieldType` / `LvsAttachment`
A field of a note: `paramId`, `typeCode` (the LVS's number) and `type` (`LvsNoteFieldType`: `text` 1, `richText` 2, `radio` 3, `checkbox` 4, `select` 5, `attachment` 6, `date` 7, `heading` 8, `unknown`), `label`, `value` (the text to show; empty for a heading and an empty field), `html` (rich text), `optionIds` (a choice's option IDs; their texts are in `value`), `date` (UTC; `null` for none or the LVS's `current`), `attachments` (`LvsAttachment`: `id`, `name`, `mimeType`; metadata only), `rawValue` / `rawOptionValue` (as sent), and `hasValue`. A field prints its type only, an attachment nothing.

### `LvsResultsConfiguration`
From `getResultsConfiguration` (#162): `canSeeAll` (`canUserSeeAll`: the web client enables its school year picker with it) and `canSeeSchoolYear` (`canUserSeeSchoolyear`), each `bool?`.

### `LvsResultsPeriod` / `LvsResultsCourse`
From `getResultsPeriods`, `getResultsCourses`, and an evaluation's own (#162). A period: `id` (what `getEvaluations` takes in `periodIds`), `name`, `icon`, `classId` / `className`, `isActive`, `workYearId` / `workYearStart` / `workYearEnd` (its Skore school year, UTC). A course: `id` (for `courseIds`), `name`, `classId` / `className`, `skoreClassId`, `parentCourseId` (`null` for a course of its own), `graphicType` / `graphicValue` (an icon or an image), `teacherNames` (as an evaluation names them). Print a flag or a count only.

### `LvsEvaluation` / `LvsScore` / `LvsScoreType` / `LvsEvaluationPage` / `LvsEvaluationList`
An evaluation (#162): `identifier`, `type` (`normal`, `project`, `project-with-rubrics`), `name`, `date` (UTC), `score`, `courses`, `period`, `componentName` / `componentAbbreviation`, `doesCount`, `isPublished` (`bool?`), `feedbackCount`. `LvsScore` (its `graphic`): `type` (`LvsScoreType`: `percentage`, `text`, `icon`, `image`, `rubrics`; another kept as it comes, `isKnownType`), `value` (as text), `percentage` (when a number), `description` (the points, "7/10"), `color`; `LvsScore.none` without a graphic. `LvsEvaluationPage`: `pageNumber`, `itemsOnPage`, `evaluations`, `mayHaveMore`. `LvsEvaluationList`: `evaluations`, `isComplete`, `pagesRead`. Print types and counts only.

### `LvsFeedback` / `LvsFeedbackKind` / `LvsFeedbackEvaluation` / `LvsReport` / `LvsResultsAttachment`
A feedback (#162): `identifier`, `kind` (`LvsFeedbackKind`: `classCouncil`, `course`, `evaluation`, `goal`, or `unknown`, kept with its identifier and text), `text` (plain text with its lines, as a note's rich text, #187) / `html` (as the LVS gives it), `author` (`""` for a remark on a report), `report` and `reportPart` (a class council's remark), `course` (a remark per course), `evaluation` (`LvsFeedbackEvaluation`: `identifier`, `name`, `date`, `courses`, `period`, `schoolYearLabel`), `goalId` / `curriculumId` (a project's goal), `attachments` (`LvsResultsAttachment`: `id`, `name`, `type`, `size`, `downloadUrl`; metadata only). `LvsReport`: `id`, `name`, `icon`, `date` (UTC), `classId` / `className`, `schoolYearLabel`, `downloadUrl` (metadata only). A feedback prints its kind and count of attachments, a report or an attachment nothing.

### `LvsPlanPeriod` / `LvsSupportPlan` / `LvsPlanItem` / `LvsPlanGoal` / `LvsPlanMoment` / `LvsPlanCourse` / `LvsProfileSketch`
From the support plan reads (#163). `LvsPlanPeriod`: `id`, `name`, `heading`. `LvsSupportPlan`: `period` (`LvsPlanPeriodInfo`: `id`, `hasError`, `message`, `isOpen`), `items`, `status` (`LvsSupportPlanStatus`), `courses` (`LvsPlanCourse`: `id`, `name`; the courses that name the course IDs below, #189). `LvsPlanItem`: `id`, `type`, `kind` (`LvsPlanItemKind`: `needs`, `goals`, `document`, `unknown`), `fromGroupPlan`, `author`, `authorId` (a Smartschool user ID: compare with `getCurrentUser().id` for the account's own items, #189), `date`, `supportNeeds`, `mainGoals`, `workGoals`, `approach`, `approachComment`, `courses`, `courseIds` (#189), `theme`, `startSituation`, `goals` (`LvsPlanGoal`: `id`, `name`, `domain`, `isDeprecated`, `objectives`, `approach`, `planning`, `moments`: `LvsPlanMoment` with `type`, `id`, `name`, `isCourse`, #189), `fileName`, `mimeType`. `LvsProfileSketch`: `period`, `hasSketch`, `html`, `text`, `lastRevision`. Which courses the account teaches is not read yet (#196). Print kinds, flags and counts only.

### `LvsAbsences` / `LvsAbsencePeriod` / `LvsAbsence` / `LvsAbsenceTotal`
From `getAbsences` (#164). `LvsAbsences`: `yearLabel`, `periods` (`label`, `absences`), `absences`, `isEmpty`, `halfDays`, `totalsByCode` (`code`, `codeDescription`, `color`, `count`, `halfDays`). `LvsAbsence`: `date` (UTC, from `formattedDate`), `dateKey`, `formattedDate`, `dayPart` (`DayPart`; `null` for a whole day, `isFullDay`), `partOfDayLabel`, `code`, `codeKey`, `codeDescription`, `color`, `motivation` (plain text) / `motivationHtml`, `halfDays`. Print counts only.

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
