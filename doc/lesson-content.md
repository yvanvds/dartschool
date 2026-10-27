# Lesfiches

The reference of `LessonContentService`, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps its overview, with a short example: [`LessonContentService`](../README.md#lessoncontentservice).

## `LessonContentService`

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
| `downloadAttachment(item, attachmentId, {maxBytes})` / `downloadAttachmentStream(...)` | `Future<Uint8List>` / `Future<SmartschoolDownload>` | The file of an attachment, unchanged (`GET .../attachments/{id}/download`), sent without `Accept: application/json` (with it, Smartschool answered `503` and an HTML page). See [*Downloads*](../README.md#downloads) in the README. |
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
