# Lesfiches

The reference of `LessonContentService` and of the year plans, `TeachingAssignmentService` (#229), moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps its overview, with a short example: [`LessonContentService`](../README.md#lessoncontentservice), [`TeachingAssignmentService`](../README.md#teachingassignmentservice).

## `LessonContentService`

### Methods

| Method | Returns | Description |
|---|---|---|
| `getItems({withCourseNames = true})` | `Future<List<LessonContentItem>>` | The lesfiches of the authenticated user, lessons and assignments, hidden ones included (not those in the trash), in the module's order (`GET lesson-content/`). With `withCourseNames` (the default) and a lesfiche with a course, it then reads the course list (`getCourses`, one request more) and names each course after the course with the same ID in it; `false` sends the one request, and leaves every course name `null`. A course list it cannot use does not lose the lesfiches: it throws a `SmartschoolLessonContentCourseListError` whose `items` are the lesfiches as read, with every course name `null` (#118). |
| `getDetail(item, {withCourseNames = true})` / `getDetailById(type, id, {withCourseNames = true})` | `Future<LessonContentDetail>` | One lesfiche in full (`GET lessons/{id}` or `assignments/{id}`, #129): a `LessonContentItem` with its `privateInfo`, its `weblinks` (`LessonContentWeblink`: `id`, `name`, `url`, `icon`, `visibility`) its `attachments` (`LessonContentAttachment`: `id`, `fileName`, `fileSize`, `mimeType`, `visibility`) and its learning `goals` (`LearningGoalRef`: `id`, `leerplanId`, `type`, #223; `GoalService.resolve` names them). No dates. Courses named as `getItems` names them. A `404` (an unknown ID, or one of the other kind) is a `SmartschoolLessonContentNotFoundError`. |
| `getCourses()` | `Future<List<PlannerCourse>>` | The school's courses (all of them, not only the teacher's), in the course list's order (`GET /course-list/api/v1/courses`): `id` (the ID of a lesfiche's course and of a planner course), `name`, `scheduleCodes`, `icon`, `clusterId`, `clusterName`, `isVisible`. The list the Lesfiches web client names its course filter from, and the course IDs the writes take. |
| `createLesson({name, icon, publicInfo, privateInfo, courseIds, weblinks, attachments, goals, labels})` | `Future<LessonContentDetail>` | Makes a lesson lesfiche in the own library, with everything in one create, and returns it as read back (see below). |
| `createAssignment({name, assignmentTypeId, ...})` | `Future<LessonContentDetail>` | The same for an assignment lesfiche of one of the school's assignment types (`PlannerService.getAssignmentTypes`), checked against the module's own list first. |
| `rename(item, name)` / `changeIcon(item, icon)` / `changePublicInfo(item, html)` / `changePrivateInfo(item, html)` | `Future<LessonContentDetail>` | Change one value (`POST {type}/{id}/rename`, `change-icon`, `change-public-info`, `change-private-info`); the module answers with the whole lesfiche. |
| `changeCourses(item, courseIds)` | `Future<LessonContentDetail>` | Sets the courses (`change-courses`), after checking each ID against `getCourses`; empty clears them. The answer has the courses named. |
| `setVisible(item, visible)` | `Future<LessonContentDetail>` | Shows or hides the lesfiche in the module (`mark-as-visible` / `mark-as-invisible`). |
| `changeGoals(item, goals)` | `Future<LessonContentDetail>` | Sets the learning goals (`change-goals` with `{"newGoals": [{id, goalId, leerplanId, type}]}`, #223); the list replaces the goals, empty clears them. See *Learning goals* below. |
| `getLabels()` | `Future<List<LessonContentLabel>>` | The labels a lesfiche can get (#228): the school's for the Lesfiches module, then the user's own. See *Labels* below. |
| `changeLabels(item, labels)` | `Future<LessonContentDetail>` | Puts exactly those labels on the lesfiche (`change-labels` with `{"newLabels": [...]}`, #228); the list replaces the labels, empty takes them all off. |
| `createUserLabel(text, {color = 'steel'})` | `Future<LessonContentLabel>` | Makes a new own label (`POST /labels/api/v1/user-labels/{userId}`, #228), sent once. |
| `parseLabels(json)` (static) | `List<LessonContentLabel>` | Parses a list of labels of the labels module. |
| `addWeblink(item, weblink)` / `changeWeblink(item, weblinkId, weblink)` / `removeWeblink(item, weblinkId)` | `Future<LessonContentWeblink>` / `Future<void>` | A weblink of the lesfiche (`POST {type}/{id}/weblinks`, `.../weblinks/{id}`; `DELETE .../weblinks/{id}`, answered with `204`). `changeWeblink` sends every value: name, address, icon and visibility. |
| `addAttachments(item, attachments)` | `Future<List<LessonContentAttachment>>` | Uploads files into a new upload directory and has the module take it (`POST {type}/{id}/attachments` with `{"randomDir"}`); returns the new attachments, told apart from the ones there by reading the lesfiche first. The module gives each new one `always`, so another visibility is set after (`changeAttachmentVisibility`), one at a time. When that fails, the files were added: a `SmartschoolLessonContentVisibilityNotSetError` (#135, see *Errors*). |
| `changeAttachmentVisibility(item, attachmentId, visibility)` / `removeAttachment(item, attachmentId)` | `Future<LessonContentDetail>` / `Future<void>` | `POST .../attachments/{id}/change-visibility`; `DELETE .../attachments/{id}` (answered with `204`). |
| `downloadAttachment(item, attachmentId, {maxBytes})` / `downloadAttachmentStream(...)` | `Future<Uint8List>` / `Future<SmartschoolDownload>` | The file of an attachment, unchanged (`GET .../attachments/{id}/download`), sent without `Accept: application/json` (with it, Smartschool answered `503` and an HTML page). See [*Downloads*](../README.md#downloads) in the README. |
| `trash(items)` | `Future<void>` | Moves lesfiches to the module's trash (`POST lesson-content/trash/bulk`, answered with `{"exceptions": []}`). They leave `getItems`; their detail is still answered. |
| `getTrash({withCourseNames = true})` | `Future<List<LessonContentItem>>` | The lesfiches in the module's trash (`GET lesson-content/trashed`, #227), in the shape of `getItems`; `dateStateChanged` is when each went there. Courses named as `getItems` names them. The web client says a lesfiche can be restored "binnen 100 dagen". |
| `restore(items)` | `Future<void>` | Takes lesfiches out of the trash, back into the library (`POST lesson-content/restore/bulk` with the body of `trash`, answered with `{"exceptions": []}`, #227). A lesfiche that is not in the trash gets an exception (`404`) keyed by the lesfiche as sent: a `SmartschoolLessonContentBulkSaveUnconfirmedError` with it in `failed` and the others in `done` (#235). Retried once after logging in again. |
| `duplicate(items)` | `Future<List<LessonContentDetail>>` | Copies lesfiches in the own library (`POST lesson-content/duplicate/bulk` with the body of `trash`, #227) and returns the copies in the order given. The module answers with each copy (detail shape) keyed by the lesfiche as sent: a new ID, the name with " - kopie" behind it, and the icon, info, visibility, courses, goals, weblinks and attachments of the lesfiche (seen live). Sent once: a second send makes more copies. A lesfiche in the trash gets an exception (`403`) and no copy: a `SmartschoolLessonContentWriteRefusedError` when no copy was made; some copies made and others not is a `SmartschoolLessonContentBulkSaveUnconfirmedError` with the `copies` made, the lesfiches `failed` and those `unanswered` (#235). |
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
- **A create answers with the new ID only** (`201` with `{"id"}`), so `createLesson` and `createAssignment` read the lesfiche back (`GET lessons/{id}`) and return its detail, which must show the name, courses, weblinks and attachments sent. The create carries everything, as the web client's does: the attachments are uploaded into a new upload directory first (the step Intradesk uploads and message attachments use), which goes out as `randomDir`, with each file's visibility by name in `visibilityOptions`. A body with only a name gets a bare `400`, so the service sends every list the web client sends (the goals and labels given, partner weblinks, deeplinks and mini-DB items empty). A name that is taken is kept: the module makes a second lesfiche of that name.
- **A create is sent once**: never again after logging in again, since a second one makes a second lesfiche. The same for `addWeblink`, the take of `addAttachments` and `duplicate` (the module takes the files of a directory again every time it is told to, and keeps two attachments of the same name). The edits set a value, and the removals, the move to the trash and the restore name what they act on, so they are retried once after logging in again, as a read is.
- **Checks before sending**: the module answers a bad name or address with a bare `400`, and stores a course it does not know without complaint. So the writes throw an `ArgumentError`, before anything is sent, for an empty name or one longer than 255 characters (the web client's field), an empty icon, a weblink without a name or with an address `normalizeWeblinkUrl` refuses, a visibility the web client does not offer, a file that does not exist or whose name Smartschool does not allow, two files of the same name in one call, an ID that is not a UUID, and a lesfiche of a kind the library does not know. A course ID that is not one of `getCourses`, and an assignment type that is not one of the module's, are refused the same way after reading those lists.
- Not covered: changing or removing a label itself (its text, colour or position), the bulk label writes (`lesson-content/add-labels/bulk`, `delete-labels/bulk`), mini-database items (`change-minidb-items`), gathering the goals of several lesfiches (`harvest-goals`), merging, converting between lesson and assignment, sharing, year plans and lesson clusters (see [`TeachingAssignmentService`](#teachingassignmentservice), #229), method lessons of publishers, printing and deleting for good (`lesson-content/delete/bulk`). Whether `planLessonContent` copies a lesfiche's attachments, weblinks and visibility into the planned lesson was not checked.

**Learning goals (#223).** A lesfiche stores its goals as references (`goals: [{"id", "leerplanId", "type"}]`), which `LessonContentDetail.goals` gives as `LearningGoalRef`s. A goal of the goal selector (`GoalService.getCurriculum`, see [`doc/goals.md`](goals.md)) gives its reference with `SelectableGoal.ref`; `GoalService.resolve` names stored ones.

```dart
final tree = await GoalService(client).getCurriculum(curriculumId);
var fiche = await lessonContent.createLesson(
  name: 'Lussen',
  goals: [tree.goals.first.ref],          // in the create
);
fiche = await lessonContent.changeGoals(fiche, [...fiche.goals, tree.goals.last.ref]);
```

- `changeGoals(item, goals)` sends `POST {type}/{id}/change-goals` with `{"newGoals": [...]}`, each goal as `{id, goalId, leerplanId, type}` with `goalId` the same as `id` (`LearningGoalRef.toWire`), as the web client does. The module answers `200` with the whole lesfiche, whose goals must be exactly those sent. The list **replaces** the goals, as in the web client, which sends its whole selection every time: to add one, send the lesfiche's `goals` with it. Retried once after logging in again, as the other edits are.
- The creates take `goals` too, sent in the same shape in the create's `goals`; the lesfiche read back must have exactly those.
- Checks before sending (an `ArgumentError`): a goal whose `id` is not a UUID, with an empty `leerplanId` or `type` (or white space around one), and two different goals with the same `id`. A goal given twice is sent once.
- The module stores a goal ID it does not know without complaint (seen live, 2026-11-01, with a made-up ID in a real curriculum), as it does a course; `GoalService.resolve` does not name such a goal. Name the goals with `resolve` when that matters.
- Seen live (2026-11-01): a goal of the eindtermen (`type` `eindtermen-derde-graad-doorstroom`) and one of a school mini-database (`miniDB`), set with `change-goals` and in a create, read back by `getDetail`. LLinkid goals, which are picked on the external LLinkid site, are not covered.

**Labels (#228).** A label is a `LessonContentLabel`: `id`, `text`, `color`, `type` (`platform` for a school label such as `TRIMESTER 1`, `user` for an own one; `isSchoolLabel`, `isUserLabel`), `isVisible`, and `platformId` (a school label) or `userId` (an own label; `ownerId` falls back to the user ID its `id` starts with). Seen live on 2026-11-01, in the own library:

```dart
final labels = await lessonContent.getLabels();          // school labels, then own ones
final mine = await lessonContent.createUserLabel('Herhaling', color: 'aqua');
var fiche = await lessonContent.createLesson(name: 'Lussen', labels: [labels.first]);
fiche = await lessonContent.changeLabels(fiche, [...fiche.labels, mine]);
```

- `getLabels()` reads Smartschool's labels module (`/labels/api/v1`), as the Lesfiches web client's label picker does: `GET locations/lesson_content/platform-labels` (the school's labels whose `locations` hold `lesson_content`) and `GET user-labels/{userId}`, with the session's whole user ID (`authenticatedUser.id`, such as `4069_146_0`). Both answer a JSON array of labels (`{identifier, id, type, text, color, isVisible}`, with `platformId` and `locations` for a school label, `userId` for an own one). `GET platform-labels` is answered with the module's web app, not JSON.
- `changeLabels(item, labels)` sends `POST {type}/{id}/change-labels` with `{"newLabels": [...]}`, each label as `LessonContentLabel.toWire` gives it: `identifier` and `id` (both the label's ID), `type`, `text`, `color`, `isVisible`, with the `userId` of an own label and the `platformId` of a school one. The module answers `200` with the whole lesfiche, whose labels must be exactly those sent (by ID). The list **replaces** the labels. Retried once after logging in again. The module answers an own label sent without its `userId`, and a school label sent with only its `id` and `type`, with a bare `500` (seen live): the labels of `getLabels` and of a lesfiche's `labels` have all it needs. A label given twice is sent once.
- The creates take `labels` too, sent the same way in the create's `labels`; the lesfiche read back must have exactly those.
- `createUserLabel(text, {color})` sends `POST /labels/api/v1/user-labels/{userId}` with `{"text", "color", "isVisible": true}`, which the labels module answers `201` with the new label; it must be an own label with the text sent. Sent once, never again after logging in again. A text one of the own labels has is refused with `400` and `languageCode` `name.already.used`, a text of more than 50 characters with a bare `400` (both seen live): a `SmartschoolLessonContentWriteRefusedError` (the `languageCode` in its `violations`).
- Checks before sending (an `ArgumentError`): a label with an empty ID, of another kind than `platform` or `user`, or an own label whose owner is not known; a label text that is empty or longer than `LessonContentService.maxLabelLength` (50, the web client's `DEFAULT_LABEL_MAX_AMOUNT_OF_CHARACTERS`), or a colour that is not one of `LessonContentService.labelColors` (the web client's 18 colours, `steel` by default).
- The library does not change or remove a label. The web client removes an own label with `DELETE /labels/api/v1/user/{id}` (answered `204`; `DELETE user-labels/{id}` is answered with the web app and removes nothing), which the live test uses to clean up after itself.

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
- `SmartschoolLessonContentBulkSaveUnconfirmedError` (a `SmartschoolLessonContentSaveUnconfirmedError`, #235) — `trash`, `restore` or `duplicate` was answered with `200` (or `TeachingAssignmentService.addLessonContent` with `201`, #244: see *The content filter* below; `added` maps each lesfiche of `done` to the lesfiche as answered in the cluster), and the answer says for some lesfiches that they were done or not: an exception for some (`trash`, `restore`, `duplicate`), or a copy of only some (`duplicate`). Each lesfiche of `items` (those given to the call, as given, each once) is in one of `done`, `failed` (a map to its `LessonContentBulkFailure`: `statusCode`, `message` — the exception's `title`, `detail` and `violations`, no name —, `raw`) and `unanswered`; from `duplicate`, `copies` maps each lesfiche of `done` to its copy (made: do not make it again). For `trash` and `restore`, a lesfiche without an exception is done, unless the module gives an exception that is not keyed by a lesfiche of the call: then those are `unanswered`. From these three, a `SmartschoolLessonContentSaveUnconfirmedError` that is not of this type means the answer says nothing usable about any lesfiche (another status, no answer, no `exceptions`).

  ```dart
  try {
    await lessonContent.duplicate(fiches);
  } on SmartschoolLessonContentBulkSaveUnconfirmedError catch (e) {
    // e.copies were made; e.failed were not (with the module's exception);
    // e.unanswered may or may not have been copied: look in getItems.
  }
  ```
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once (for a create, without that retry). Nothing was changed. Calling the method again is enough: the client logs in before its next request (#134).

## `TeachingAssignmentService`

The year plans of the Lesfiches module (#229): a **teaching assignment** ("leeropdracht", `teaching-assignments`) is a named collection of a teacher's lesfiches, split into **lesson clusters** (`lesson-clusters`, the units of the year), each holding lesfiches and titles in order, with learning goals, info for pupils and for the teacher, and an estimate of its teaching hours. The planner plans a lesson cluster over a period for a class, keeping a link back to it (#230): a `LessonClusterRef` (`id`, `platformId`, `teachingAssignment`) names one, and every `LessonCluster` is one. All under `/lesson-content/api/v1/teaching-assignments`, tried live on 2026-11-01 in the own library; `{userId}` is the session's whole user ID (`authenticatedUser.id`).

```dart
final plans = TeachingAssignmentService(client);
final plan = await plans.createTeachingAssignment(name: 'Informatica 5');
final unit = await plans.addCluster(plan, name: 'Lussen');
await plans.addTitle(unit, 'Week 1');
await plans.addLessonContent(unit, [fiche]);         // lesfiches of getItems or getLessonContent
await plans.changeClusterGoals(unit, [goal.ref]);   // a SelectableGoal of GoalService
for (final entry in await plans.getClusterContent(unit)) {
  switch (entry) {
    case LessonClusterTitle(:final text):
      print('# $text');
    case LessonClusterLesfiche(:final item):
      print('- ${item.name}');
  }
}
await plans.deleteTeachingAssignment(plan);         // with its clusters; the lesfiches stay
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `getTeachingAssignments()` | `Future<List<TeachingAssignment>>` | The user's teaching assignments (`GET teaching-assignments/{userId}`; `[]` for a teacher without one). |
| `getTeachingAssignment(ref)` | `Future<TeachingAssignment>` | One (`GET teaching-assignments/{platformId}/{id}`), with its clusters in short (ID, name, icon, position, visibility). A `404` is a `SmartschoolLessonContentError` with that status. |
| `createTeachingAssignment({name, icon = 'box_curver_blue', contentFilter = all})` | `Future<TeachingAssignment>` | Makes one (`POST teaching-assignments/{userId}`, answered `201` with it), with the web client's body: `name`, `icon`, `contentFilter` (`{type, labels: [], labelFilterType: "oneOf", courses: [], courseFilterType: "oneOf", assignmentTypes: []}`), `privileges` (`{read, edit, delete}`), no collaborators and no publication. Sent once. |
| `deleteTeachingAssignment(ref)` | `Future<void>` | Deletes it with its clusters (`DELETE teaching-assignments/{platformId}/{id}`, answered `204`); the lesfiches stay in the library. Not a trash: it is gone. Retried once after logging in again. |
| `getLessonContent(ref)` | `Future<List<LessonContentItem>>` | The lesfiches it takes (`GET .../{platformId}/{id}/lesson-content`), as its content filter selects them: with `all`, the user's lesfiches. The owner comes as a user object there; `ownerId` is its `id`. No course names. |
| `getClusters(ref)` | `Future<List<LessonCluster>>` | Its clusters with their counts, info and goals (`GET teaching-assignments/{userId}/{platformId}/{id}/lesson-clusters?includeMetadata=true`). |
| `getCluster(clusterRef)` | `Future<LessonCluster>` | One cluster (`GET teaching-assignments/{taPlatformId}/{taId}/lesson-clusters/{platformId}/{id}`). |
| `addCluster(ref, {name, icon = 'box_curver_blue', visible = true})` | `Future<LessonCluster>` | Adds a cluster (`POST teaching-assignments/{userId}/{platformId}/{id}/lesson-clusters` with `{name, icon, isVisible}`, answered `201` with it). Sent once. |
| `getClusterContent(clusterRef)` | `Future<List<LessonClusterEntry>>` | Its entries in order (`GET .../lesson-cluster-content`): `LessonClusterTitle`s and `LessonClusterLesfiche`s (a lesfiche in the list shape, with its `position`, `teachingHoursEstimate` and `numberOfGoals`). |
| `addLessonContent(clusterRef, items)` | `Future<List<LessonContentItem>>` | Adds lesfiches to the end of the cluster (`POST .../lesson-content-from-teaching-assignment` with `{"lessonContentIdentifiers": [{id, type, platformId}]}`, answered `201` with `{"lessonContent": [...], "exceptions": []}`). Sent once: the same lesfiche can be in a cluster twice, and a second send adds it again (seen live). |
| `addTitle(clusterRef, text)` | `Future<LessonClusterTitle>` | Adds a title to the end of the cluster (`POST .../titles` with `{text}`, answered `200` with it). Sent once. |
| `changeClusterGoals(clusterRef, goals)` | `Future<LessonCluster>` | Sets the cluster's goals (`POST .../change-goals` with `{"newGoals": [{id, goalId, leerplanId, type}]}`, as for a lesfiche, #223); the list replaces them, empty clears them. The answer must have exactly those. Retried once after logging in again. |
| `getClusterGoals(clusterRef)` | `Future<List<LessonClusterGoal>>` | The cluster's goals with the module's `count` (`GET .../goals`, `[{id, leerplanId, type, count}]`). |

- **The content filter decides which lesfiches can go in.** With `none`, the module refused each lesfiche added to a cluster with an exception keyed by the lesfiche (`{platformId}_lesson_{id}`) with the status `403`; with `all`, it took them (seen live). `addLessonContent` throws a `SmartschoolLessonContentWriteRefusedError` when it added none and each has such an exception (`400` to `499`): nothing was changed; a `SmartschoolLessonContentBulkSaveUnconfirmedError` when it added only some, or its answer does not account for each (#244): the lesfiches added in `done` (and in `added`, each as the module answered it: do not add them again), those with an exception in `failed`, those it names neither way in `unanswered` (read the cluster with `getClusterContent` before adding those again). `createTeachingAssignment` makes `all` (the default) or `none`; `particular` (by labels, courses and assignment types) is read, not made.
- **Checks before sending** (an `ArgumentError`): a name or title text that is empty or longer than `TeachingAssignmentService.maxNameLength` (50: the module answers one of 51 characters with a bare `400`, seen live for all three), an empty icon, an ID that is not a UUID, no lesfiches or a lesfiche of a kind the library does not know, and a goal that `LessonContentService.changeGoals` refuses.
- **Sent once**: the creates and the adds are never sent again after logging in again; the goals and the delete are, as a read is.
- The errors are those of `LessonContentService` (see [*Errors*](#errors)); a teaching assignment or cluster the module does not know is answered `404`: a `SmartschoolLessonContentError` from a read, a `SmartschoolLessonContentWriteRefusedError` from a write.
- Not covered: sharing (collaborators, publication), export and import, partner teaching assignments, the old Jaarplannen module (`/yearplan/api/v1`) and its import, renaming, reordering or removing clusters and entries (`rename`, `reorder`, `remove/bulk`, `DELETE` of a cluster or title), their info, attachments and weblinks, their visibility, and the teaching-hours estimates. Where a cluster was planned (`.../planned-lesson-clusters`) is read with `PlannerService.getPlannedLessonClustersOf`, and a cluster is planned for a class with `PlannerService.planLessonCluster` (#230, see [`doc/planner.md`](planner.md#lesson-clusters-for-a-class)).
