# Planner

The reference of `PlannerService`, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps its overview, with a short example: [`PlannerService`](../README.md#plannerservice).

## `PlannerService`

### Calendars

| Calendar | ID | Example |
|---|---|---|
| `PlannerCalendar.user(id)` | the whole user ID `{platformId}_{userId}_{coaccount}` | `4069_146_0` |
| `PlannerCalendar.group(id)` | a class, `{platformId}_{groupId}` | `4069_2001` |
| `PlannerCalendar.location(id)` | a location, `{platformId}_{itemId}` | `4069_<item UUID>` |

`ownCalendar()` gives the planner of the authenticated user (from `authenticatedUser.id`; note that `getCurrentUser().id` is only the middle part of that ID). The users, classes and locations an element names give their own calendar: `element.organiserUsers.first.calendar`, `element.participantGroups.first.calendar`, `element.locations.first.calendar` (a location's calendar ID joins its platform ID and its item ID; the planner answers the bare item ID with `400`). The constructors check the form of the ID and throw an `ArgumentError` for another one.

### Finding a calendar by name

`searchCalendars(text)` does what the planner's search field ("Zoek een planner") does: it finds the users, classes and locations whose name holds the text (`6A` finds `6A1` and `6A2`, `Janssens` every Janssens, `101` the room), each with its `calendar`:

| Hit (`kind`) | Planner type (`typeName`) | `calendar` |
|---|---|---|
| `PlannerSearchResultKind.user` | `user` | `PlannerCalendar.user(id)` |
| `PlannerSearchResultKind.group` | `group` | `PlannerCalendar.group(id)` |
| `PlannerSearchResultKind.location` | an item of the location module (`location` in `origin.modules`), `mini-db-2` on the live site | `PlannerCalendar.location(id)` |
| `PlannerSearchResultKind.other` | anything else | `null` |

**Users are not told apart**: teachers, pupils and co-accounts come with the same fields, and no field says which is which. A co-account has an ID of its own (ending in its number, such as `_1`) and a `description` such as `Interimaris van ...`; the `title` of the pupils seen live ended in their class, but that is display text, which the library does not rely on. To keep teachers only, compare the user ID (the middle part of the calendar ID) with `SkoreService.getTeachers()`. The search is a `POST quick-search/planner/search` with `{"searchString": text, "searchOptions": []}`, as the web client sends it; it only reads. The planner's `include-deleted` option is not sent, and the favourites of the search (which the planner keeps per user) are not touched.

### Naming a calendar by its ID

`getCalendar(calendar)` names a calendar by its ID, as the planner's search names it (a `PlannerSearchResult` whose `calendar` is the one asked for: `name`, `title`, `description`, `isDeleted`, ...), or returns `null` when the planner does not know the ID (#127). This tells a calendar ID that names no planner from a planner with nothing planned, which `getPlannedElements` does not: the planner does not check the ID whose elements it lists (seen live, 2026-10-05):

| Calendar ID | `getPlannedElements` | `getCalendar` |
|---|---|---|
| a user, class or room with nothing planned | `[]` | the user, class or room |
| a room the planner does not have | `[]` | `null` |
| a user or class the planner does not have (a made-up ID, a co-account number the user does not have, an ID of another platform) | `SmartschoolPlannerError` with `statusCode` `500` | `null` |
| a group the planner's search does not find either (seen live: groups with the icon `star_green`, whose planner page `/planner/main/group/{id}` does name them) | `[]` | `null` |

- A **deleted user** is named, with `isDeleted` set (the search leaves deleted users out).
- The **own calendar** is named after the authenticated user (`authenticatedUser.name`): the planner itself names it `%quicksearch.me%` (`Mezelf` in the web client).
- The lookup is a `POST quick-search/planner/start` with `{"users": [], "groups": [], "miniDbItems": []}` and the calendar ID in the list of its kind (a location in `miniDbItems`): the request with which the planner's web client opens its search field, whose `selection` names the calendars it is given. It only reads; the search's suggestions and the user's favourites in its answer are not returned.
- A `SmartschoolPlannerError` when the planner answers with another status (`500` for a class ID whose part after the platform ID is not a number, such as `4069_abc`), or names another calendar than the one asked for (it reads the parts of a user or class ID as numbers, and answered `4069_04256` as `4069_4256`).
- Whether the planner names other users' calendars for an account that may not see other planners was not tried.

### Assignment types and workload

What a caller needs to answer "when is a good moment for a test in class X": the school's assignment types, the assignments of the class in a period (of all its teachers, with their type), and the workload figures the planner itself uses, per day or for one moment. The library returns these facts as the planner gives them; choosing the moment (no other test that day, not right before an exam, ...) is up to the caller.

```dart
final types = await planner.getAssignmentTypes();  // List<PlannerAssignmentType>: GO, GT, KO, ...

final assignments = await planner.getAssignmentsOfGroups(
  groupIds: [klas.id],                             // '4069_2001'; several classes in one request
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
);                                                 // List<PlannedElement>
for (final a in assignments) {
  print('${a.period.from} ${a.assignmentType?.abbreviation} ${a.name} '
      '(${a.organiserUsers.first.name})');
}

final load = await planner.getWorkloadSchedule(
  groupIds: [klas.id],
  from: DateTime(2026, 10, 5),
  to: DateTime(2026, 10, 9, 23, 59, 59),
);                                                 // Map<DateTime, List<PlannerGroupWorkload>>
for (final MapEntry(key: day, value: groups) in load.entries) {
  for (final g in groups) {
    print('$day ${g.group.name}: weight ${g.weight}, ${g.setting?.name}');
  }
}

// The check the planner runs before it saves an assignment.
final now = await planner.calculateWorkload(
  groupIds: [klas.id],
  from: DateTime(2026, 10, 6, 8, 30),
  to: DateTime(2026, 10, 6, 9, 20),
);                                                 // List<PlannerGroupWorkload>
```

- `groupIds` are class IDs `{platformId}_{groupId}`: the `id` of a class's `PlannerCalendar` (from `searchCalendars`) or of a `PlannerGroup` an element names. Each goes out once. No class, an ID in another form, or `to` before `from` throws an `ArgumentError` before anything is sent. `from` and `to` go out as for `getPlannedElements`.
- `getAssignmentsOfGroups` returns the assignments as the planner's workload view lists them, in the planner's order (not by date). An assignment of several classes comes once, with all its classes in `participantGroups`, also those that were not asked for. The same assignments are in each class calendar (`getPlannedElements` with `PlannedElementType.assignment`), one request per class.
- `getWorkloadSchedule` returns, per day the planner names (a local `DateTime` at midnight, in date order), a `PlannerGroupWorkload` per class: the planner's `weight` and `concurrentWeight` and the class's workload `setting` (name, `limit`, allowed assignment types). An empty schedule is an empty map.
- **The figures are returned as they are**: what `weight` and `concurrentWeight` add up was not checked. At the school seen live every assignment type had weight `0` and every class the setting `Geen limiet` (limit `-1` per `day`, `soft`), so the weights stayed `0`, also on days with tests: there, the assignments per day (with their type and teacher) are what says something.
- The workload calls are POSTs that only read, as the planner's web client sends them (checked in its code, and called live): `workload/planned-elements?from=&to=` with `{"users": [], "groups": [...], "courses": []}`, `workload/schedule?from=&to=` with `{"groups": [...]}`, and `workload/calculate` with the period and `{"users": [], "groups": [...], "groupFilters": {}}`; `calculate` saves nothing. The assignment types come from `GET /lesson-content/api/v1/assignments/applicable-assignment-types`.

### Lessons in the own planner

> **Warning:** these calls change the live planner. Pupils of the hour's classes see a lesson's name and public info as soon as it is planned.

```dart
final me = await planner.ownCalendar();
final slot = (await planner.getPlannedElements(
  me,
  from: DateTime(2026, 11, 20, 11, 10),
  to: DateTime(2026, 11, 20, 12),
  types: {PlannedElementType.placeholder},
)).single;                                         // an empty lesson hour

final lesson = await planner.planLesson(
  placeholder: slot,
  name: 'Lussen: for en while',
  publicInfo: '<p>Breng je laptop mee.</p>',       // HTML, what pupils see
  privateInfo: '<p>Oefening 3 overslaan.</p>',     // HTML, what pupils do not see
);                                                 // PlannedElementDetail, a new ID

await planner.renameElement(lesson, 'Lussen: for, while en break');
await planner.changePublicInfo(lesson, '<p>Breng je laptop <strong>opgeladen</strong> mee.</p>');
await planner.changePrivateInfo(lesson, '<p>Oefening 3 en 4 overslaan.</p>');

final emptyAgain = await planner.clearLesson(lesson); // the slot again, with a new ID

// A lesfiche of the Lesfiches library into the same hour.
final fiche = (await LessonContentService(client).getItems())
    .firstWhere((item) => item.type == LessonContentType.lesson);
final planned = await planner.planLessonContent(
  placeholder: emptyAgain,
  lessonContentId: fiche.id,
);                                                 // named after the lesfiche
await planner.clearLesson(planned);
```

> **`privateInfo` is not private to the teacher.** It is the info that pupils do not see; colleagues who can read the lesson (in the calendar of one of its classes, for instance) see it too.

| Method | Request (to `/planner/api/v1/`) | Sent |
|---|---|---|
| `planLesson({placeholder, name, publicInfo, privateInfo, icon})` | `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons/blanco` with the slot's organisers, classes, course, period and rooms, and the lesson's `name`, `publicInfo`, `privateInfo` and `icon` (default `PlannerService.defaultLessonIcon`, `document_observation`) | once |
| `planLessonContent({placeholder, lessonContentId})` | `POST planned-placeholders/{platformId}/{id}/replace/planned-lessons` (without `/blanco`) with the slot's organisers, classes, course, period and rooms, the lesfiche's ID as `sourceId` and its icon (`defaultLessonIcon` when it has none), and no name or info: the planner names the lesson after the lesfiche | once |
| `renameElement(element, newName)` | `POST {plannedElementType}/{platformId}/{id}/rename` with `{"newName"}` | retried once after logging in again |
| `changePublicInfo(element, newInfo)` | `POST .../change-public-info` with `{"newInfo"}` (HTML as given) | retried once after logging in again |
| `changePrivateInfo(element, newInfo)` | `POST .../change-private-info` with `{"newInfo"}`; `info` follows | retried once after logging in again |
| `clearLesson(lesson)` | `POST planned-elements/clear` with `{"type": "planned-lessons", "elementId", "elementPlatformId"}`; returns the slot, with a new ID | once |

Each call reads the element again first (its detail, which is up to date at once, unlike the list) and refuses with a `SmartschoolPlannerWriteRefusedError`, sending nothing:

- an element that is **not organised by the authenticated user**: a class calendar also shows colleagues' slots, lessons and assignments, and the planner may even let a user change some of them; the service never does;
- an element whose capabilities do not allow the change: `canUserReplace` to fill a slot; `canUserEdit` with `canUserRename`, `canUserChangePublicInfo` or `canUserChangePrivateInfo` to edit; `canUserEdit` to clear (as the web client requires);
- for `planLesson` and `planLessonContent`, a slot that is no longer in the period it was read with, or that has participant roles or group filters (never seen on a timetable slot);
- for `planLessonContent`, a lesfiche that is not among the user's lesfiches (`LessonContentService.getItems`, read again first), or that is not a lesson lesfiche (`LessonContentType.lesson`): an assignment lesfiche would be planned as an assignment, which the service does not do;
- for `clearLesson`, a lesson that the planner lets the user trash or delete (`canUserTrash`, `canUserDelete`): the lessons in a timetable hour seen live allowed neither, clearing being the planner's way to remove them, and the clear of any other lesson was not tried.

An element that is gone throws a `SmartschoolPlannedElementNotFoundError`, also before anything is sent: a slot that was filled since it was read is gone under its ID. The fill body is built from the slot as read again, not from the listed element. `planLesson` and `planLessonContent` refuse an element that is not a slot, and the calls refuse an empty name, icon or lesfiche ID, with an `ArgumentError` before any request. When `planLessonContent` cannot read the lesfiches, it throws the `SmartschoolLessonContentError` of `LessonContentService`, also before anything is sent. An edit to the value the element has already sends nothing. An info is compared as HTML, there and in the planner's answer (#155): the planner keeps an info in its own form, which need not be the HTML sent character for character (it answers `&quot;`, `&#39;` and `&eacute;` as `"`, `'` and `é`, and keeps `&amp;`, `&lt;` and `&gt;`; seen live, 2026-10-27), so the same text and markup, with its character references decoded, is the same value (`&quot;` and `"`, `&#233;` and `é`, `<BR/>` and `<br>`), and the element returned holds the info in the planner's form. A name is compared as it is.

**Why a write was refused.** The error says which check refused as a value, so that an app can tell its user why in its own words instead of passing on the library's message (a sentence for a log, which names the method and the element by its type and ID, and ends with "Nothing was sent."):

```dart
try {
  await planner.planLesson(placeholder: slot, name: 'Lussen');
} on SmartschoolPlannerWriteRefusedError catch (e) {
  final hour = e.element;                          // the slot as read again (null when none was read)
  final why = switch (e.reason) {
    PlannerWriteRefusalReason.notOwn =>
      'that hour belongs to ${hour!.organiserUsers.map((u) => u.name).join(', ')}',
    PlannerWriteRefusalReason.notAllowed =>
      'Smartschool does not allow it (${e.capabilityFlags.join(', ')} not set)',
    PlannerWriteRefusalReason.periodChanged =>
      'the hour is at ${hour!.period.from} now',
    _ => e.message,
  };
  print('Not planned: $why.');                     // nothing was sent
}
```

| `reason` (`PlannerWriteRefusalReason`) | From | Adds |
|---|---|---|
| `notOwn` — not organised by the authenticated user | every write that changes an element | `element` (with its `organiserUsers`) |
| `notAllowed` — the capabilities do not allow the change | every write that changes an element | `element`; `capabilityFlags`: the flags the write needs that are not set |
| `noLongerASlot` — the slot to fill is another kind of element now | `planLesson`, `planLessonContent` | `element` |
| `periodChanged` — the slot is no longer in the period it was read with | `planLesson`, `planLessonContent` | `element`, in the period it has now |
| `participantRoles` — the slot has participant roles or group filters | `planLesson`, `planLessonContent` | `element` |
| `trashable` — the planner lets the user trash or delete the lesson | `clearLesson` | `element`; `capabilityFlags`: those set of `canUserTrash`, `canUserDelete` |
| `unknownLessonContent` — the lesfiche is not among the user's lesfiches | `planLessonContent` | — |
| `notALessonLessonContent` — the lesfiche is not a lesson one | `planLessonContent` | `lessonContent`: the lesfiche (`LessonContentItem`) |
| `unknownAssignmentType` — the type is not one of the school's | `planAssignment` | `assignmentTypes`: the school's types (`PlannerAssignmentType`) as the check read them (#119) |
| `linkedEvaluation` — the assignment has a linked Skore evaluation | `trashAssignment` | `element` |

`element` is the element as the write read it again (its detail, a `PlannedElementDetail`), so its name, period (a `DateTime`), classes, course and organisers are at hand; it is `null` when the check refused before an element was read (a lesfiche, a new assignment's type). `assignmentTypes` is empty for every other reason; for `unknownAssignmentType` it lists the school's types in the planner's order, so that an app can name them to its user, or pick the one it meant (a type the school replaced by one of the same name has a new ID), without reading them again with `getAssignmentTypes`, a read that could differ from the one the check refused on. `reason` is `null` only for an error made without it (its constructor takes the new fields as optional ones).

The fill and the clear are sent **once**: never again after logging in again (a second fill could plan a second lesson). The edits set a value, so they are retried once after logging in again, as a read is. When the planner's answer does not confirm a write (a lesson with the name asked for, or the lesfiche's name, in the slot's period; the element with the new value; a slot of the own planner in the lesson's period), or no usable answer comes in, the call throws a `SmartschoolPlannerSaveUnconfirmedError`: the change may or may not have been made, so read the element again (`getDetail`; it answers `404` for a slot that was filled or a lesson that was cleared) before trying again. Calling the method again is safe in itself: it reads the element first.

Of the planner's trash, the service only uses the move of one own assignment (`trashAssignment`, see *Assignments in the own planner*). It never uses the planner's `DELETE` of an element (which deletes it for good), the restore from the trash, or its bulk endpoints (`planned-elements/trash`, `planned-elements/delete`, `planned-elements/bulk/...`, `planned-elements/replace-with-...`, and `planned-elements/{calendarType}/{calendarId}/trash?from=&to=`, which moves everything in a period to the trash). Attachments, weblinks, goals, labels, the icon of an existing lesson, rescheduling and lessons outside the timetable are not covered.

**Planning a lesfiche.** The planner makes the lesson from the lesfiche: in the try live it took the lesfiche's name, labels and goals, and its (empty) info; the answer has no field that points back to the lesfiche. Planning did not change the lesfiche (the whole list was the same afterwards), and a hidden lesfiche (`isVisible` `false`) was planned like any other. Whether the planner copies the attachments, weblinks and info of a richer lesfiche, and whether later changes to a lesfiche reach the lessons planned from it, was not checked. The bulk plan of one lesfiche into several hours (`planned-elements/replace-with-lesson-content`) is not used: `planLessonContent` plans one hour at a time, each with its own checks.

The example shows the hour, asks for confirmation, fills it with a `[dartschool test]` lesson, renames it, clears it (also when the rename failed) and shows the hour again; given a lesfiche (its ID or exact name), it plans that lesfiche into the hour instead, and clears it again without renaming it (a lesfiche that matches none, such as `?`, lists the lesson lesfiches and changes nothing):

```bash
dart run example/planner_lesson_example.dart 2026-11-20 11:10
dart run example/planner_lesson_example.dart 2026-11-20 11:10 '?'
dart run example/planner_lesson_example.dart 2026-11-20 11:10 b0000000-0000-4000-8000-000000000001
```

### Assignments in the own planner

> **Warning:** these calls change the live planner. **Pupils of the classes see a new assignment at once**: the planner makes it visible from the moment it is created (`visibleFrom`), with its name and public info, until it is in the trash.

An assignment ("opdracht": a test, a task, something to bring along) is not tied to a lesson hour: it is a deadline, for one or more classes. In a class calendar it shows next to the timetable slot of that hour, which stays as it is. With *Assignment types and workload* above, a caller can pick a moment and then plan the test:

```dart
final ko = (await planner.getAssignmentTypes())
    .firstWhere((type) => type.abbreviation == 'KO');

final test = await planner.planAssignment(
  groupIds: [for (final group in slot.participantGroups) group.id], // '4069_2001', ...
  course: slot.courses.first,                      // a PlannerCourse, e.g. of a timetable slot
  type: ko,                                        // one of getAssignmentTypes()
  name: 'Test: hoofdstuk 3',
  due: slot.period.from,                           // the deadline, usually the start of a lesson hour
  until: slot.period.to,                           // the end of that hour
  publicInfo: '<p>Leerstof: hoofdstuk 3.</p>',     // HTML, what pupils see
  locations: slot.locations,                       // optional
);                                                 // PlannedElementDetail, organised by you

await planner.renameElement(test, 'Test: hoofdstuk 3 en 4');
await planner.changePublicInfo(test, '<p>Leerstof: hoofdstuk 3 en 4.</p>');
await planner.trashAssignment(test);               // to the planner's trash (30 days)
```

| Method | Request (to `/planner/api/v1/`) | Sent |
|---|---|---|
| `planAssignment({groupIds, course, type, name, due, until, publicInfo, privateInfo, icon, locations})` | `POST planned-assignments/blanco?waitForRefresh=true` with the authenticated user as the only organiser, the classes as participants, the course, the period (`dateTimeFrom` = `due`, `dateTimeTo` = `until`, `wholeDay` `false`, `deadline` `true`, `dateTime` = `due`), the `name` (sent trimmed), an empty `info`, `publicInfo` and `privateInfo` (HTML as given, empty by default), the type's ID as `assignmentType`, the `icon` (required by the planner; default `PlannerService.defaultAssignmentIcon`, `flags_red_yellow`) and the `locations`; answered with `201` and the assignment | once |
| `renameElement`, `changePublicInfo`, `changePrivateInfo` | as for a lesson, at `planned-assignments/{platformId}/{id}/...` | retried once after logging in again |
| `trashAssignment(assignment)` | `POST planned-assignments/{platformId}/{id}/trash` without a body, answered with `200` and `[]`; then the assignment's detail is read again and must be `404` | once |

Before anything is sent:

- `planAssignment` reads the school's assignment types again (`getAssignmentTypes`) and refuses a `type` whose ID is not among them with a `SmartschoolPlannerWriteRefusedError`, which carries the types it read as `assignmentTypes` (#119); types that cannot be read throw the `SmartschoolPlannerError` of `getAssignmentTypes`. No class, an ID that is not a class ID, an empty name, icon, course ID or type ID, or `until` before `due` throws an `ArgumentError` before any request. `due` and `until` go out as `PlannerService.formatDateTime` writes them.
- The edits and `trashAssignment` read the assignment again and refuse, as for a lesson, one that is **not organised by the authenticated user** (a class calendar also shows colleagues' tests, which the service never changes, even when the planner would let the user) or whose capabilities do not allow the change (`canUserTrash` to trash, as the web client's delete requires). `trashAssignment` also refuses an assignment with a linked Skore evaluation (`hasLinkedEvaluation`): the trash of one was not tried. An assignment that is gone (also one that is in the trash already) throws a `SmartschoolPlannedElementNotFoundError`; an element that is not an assignment throws an `ArgumentError` before any request.

The create and the trash are sent **once**, never again after logging in again. When the planner's answer does not confirm the create (an assignment of the authenticated user with the name and type asked for, due at `due`; `201` or `200`), or no usable answer comes in, `planAssignment` throws a `SmartschoolPlannerSaveUnconfirmedError`: the assignment may or may not have been made. **Calling `planAssignment` again adds another assignment** when the first one was made: look for it in the calendar of one of its classes first (`getPlannedElements(PlannerCalendar.group(id), ..., types: {PlannedElementType.assignment})`, or `getAssignmentsOfGroups`). `trashAssignment` throws it when the trash is not answered with a list, or when the assignment is still there (or cannot be read) afterwards; calling it again is safe, since it reads the assignment first.

The planner keeps what is in its trash for 30 days, and its web client can restore it from there; the service does not read, restore or empty the trash (the restore was not tried). Not covered either: rescheduling an assignment, changing its type, classes or visibility, pinning or resolving it, announcing it (`announce`; whether it notifies pupils or parents is not known), hand-in folders, linking a Skore evaluation, attachments, weblinks, goals, reminders, recurrence, and planning an assignment lesfiche of the Lesfiches library.

The example shows a lesson hour of the own planner and the assignment type, asks for confirmation, adds a `[dartschool test]` assignment for the hour's classes, due at its start, reads it back and looks for it in the class calendar, renames it, and moves it to the trash (also when the read or the rename failed; after a create that was not confirmed it looks for it in the class calendar and trashes what it finds); a type that matches none (such as `?`) lists the school's types and changes nothing:

```bash
dart run example/planner_assignment_example.dart 2026-11-20 11:10
dart run example/planner_assignment_example.dart 2026-11-20 11:10 GO
```

### Methods

| Method | Returns | Description |
|---|---|---|
| `ownCalendar()` | `Future<PlannerCalendar>` | The planner of the authenticated user. |
| `searchCalendars(text)` | `Future<List<PlannerSearchResult>>` | The users, classes and locations whose name holds `text`, in the planner's order, each with its calendar (see *Finding a calendar by name*). An empty text throws an `ArgumentError` before anything is sent. |
| `getCalendar(calendar)` | `Future<PlannerSearchResult?>` | The calendar named by its ID, as the planner's search names it (a deleted user too, with `isDeleted`; the own calendar after the authenticated user); `null` when the planner does not know the ID (see *Naming a calendar by its ID*). |
| `getPlannedElements(calendar, {from, to, types})` | `Future<List<PlannedElement>>` | The elements of the calendar in the period, in the planner's order. `types` keeps only those types (`null`: every type). A whole school year in one request works. The planner does not check the calendar ID: a room it does not have is an empty list, a user or class it does not have a `SmartschoolPlannerError` with `statusCode` `500`; `getCalendar` tells them apart. |
| `getPlannedElement({type, typeName, platformId, id})` | `Future<PlannedElementDetail>` | The full detail of one element, by its `type` or by its `typeName`, the planner's name of the type (`planned-lessons`, as `PlannedElement.typeName` keeps it; also for a type the library does not know): pass one of the two. Neither or both, `PlannedElementType.other`, a `typeName` not of the planner's form (`planned-` and words of lowercase letters and digits joined by hyphens) or an empty `id` throw an `ArgumentError` before anything is sent. |
| `getDetail(element)` | `Future<PlannedElementDetail>` | The same, for a listed element (also one of a type the library does not know). |
| `getAssignmentTypes()` | `Future<List<PlannerAssignmentType>>` | The school's assignment types (such as `Kleine Overhoring`, `KO`), in the planner's order. |
| `getAssignmentsOfGroups({groupIds, from, to})` | `Future<List<PlannedElement>>` | The assignments of the classes in the period, of every teacher, in the planner's order (see *Assignment types and workload*). |
| `getWorkloadSchedule({groupIds, from, to})` | `Future<Map<DateTime, List<PlannerGroupWorkload>>>` | The planner's workload figures of the classes per day of the period. |
| `calculateWorkload({groupIds, from, to, wholeDay, deadline})` | `Future<List<PlannerGroupWorkload>>` | The planner's workload figures of the classes for an assignment in that period (`deadline` defaults to `true`, `wholeDay` to `false`), as the planner computes them before it saves an assignment. Saves nothing. |
| `planLesson({placeholder, name, publicInfo, privateInfo, icon})` | `Future<PlannedElementDetail>` | Fills an empty lesson hour of the own planner with a new lesson; returns it (see *Lessons in the own planner*). |
| `planLessonContent({placeholder, lessonContentId})` | `Future<PlannedElementDetail>` | Plans a lesson lesfiche of the Lesfiches library (an ID from `LessonContentService.getItems`) into an empty lesson hour of the own planner; returns the lesson, named after the lesfiche. |
| `clearLesson(lesson)` | `Future<PlannedElementDetail>` | Clears an own lesson in a lesson hour; returns the empty slot, with a new ID. |
| `planAssignment({groupIds, course, type, name, due, until, publicInfo, privateInfo, icon, locations})` | `Future<PlannedElementDetail>` | Adds an assignment of one of the school's types for the classes to the own planner, due at `due`; returns it. Pupils see it at once (see *Assignments in the own planner*). |
| `trashAssignment(assignment)` | `Future<void>` | Moves an own assignment to the planner's trash, and checks that it is gone. |
| `renameElement(element, newName)` | `Future<PlannedElementDetail>` | Renames an own lesson or assignment (or another own element the planner lets the user rename); returns it. |
| `changePublicInfo(element, newInfo)` / `changePrivateInfo(element, newInfo)` | `Future<PlannedElementDetail>` | Sets the info that pupils see / do not see of an own lesson or assignment (HTML); returns it. |
| `formatDateTime(time, {timeZoneOffset})` (static) | `String` | A date as the planner's API takes it: ISO 8601 to the second with the offset from UTC (`2026-11-20T11:10:00+01:00`); in the given offset when `timeZoneOffset` is set. |

`from` and `to` go out as ISO 8601 with their offset (URL-encoded, `+` as `%2B`): a local `DateTime` in the local time of the machine, with its offset at that moment (in Belgium `+02:00` in summer, `+01:00` in winter), a UTC one in UTC. The planner's own dates are read into local `DateTime`s. Use `23:59:59` rather than midnight to include the last day. `to` before `from`, an empty `types` and `PlannedElementType.other` in `types` throw an `ArgumentError` before anything is sent.

### What the planner shows

- **A class calendar holds the elements of all teachers of the class**, and a colleague's lessons and assignments can be read in full. `privateInfo` is the info that pupils do not see, **not** info that only its teacher sees: other teachers who can read the element see it too. `publicInfo` is what pupils see. Both are HTML (`""` when empty); `info` held the same text as `privateInfo` in every answer seen.
- **Timetable slots** are `PlannedElementType.placeholder` elements: one per teacher per lesson hour, with the classes, the course and the room, but no `name`. `capabilities.canReplace` tells whether a slot can be filled. Do not keep their IDs: a slot that was filled and cleared again comes back with a new ID. Find a slot again by its period, course and groups.
- **The list lags behind**: after a change in the planner, `getPlannedElements` may show the old state for a few seconds, while `getPlannedElement` / `getDetail` show the new one at once. Read the detail to check a change.
- Only lessons, assignments and placeholders were seen live; the other `PlannedElementType`s are the web client's constants. An element of a type the library does not know is kept as `PlannedElementType.other`, with the planner's name in `typeName`.

### Errors

- `SmartschoolPlannerError` — the planner answered with something the service cannot use: another status than `200` (in `statusCode`, such as `400` for a calendar it refuses, or `500` for the elements of a user or class it does not have), an HTML page, invalid JSON, or data in an unknown shape (also a search hit of a user, class or location whose ID is not a calendar ID, and a lookup of `getCalendar` that names another calendar than the one asked for). The session was accepted: signing in again does not help.
- `SmartschoolPlannedElementNotFoundError` (a `SmartschoolPlannerError`) — `getPlannedElement` / `getDetail`: the planner has no element of that type with that ID (`404`): unknown, removed, or in the trash, or a `typeName` the planner does not have (carries `elementType`, `platformId`, `elementId`). Also from a write, for the element it reads again first (such as a slot that was filled since it was read): nothing was sent.
- `SmartschoolPlannerWriteRefusedError` (a `SmartschoolPlannerError`) — a check before a write refused it (not organised by the authenticated user, a capability not set, a slot in another period, an assignment type the school does not have, ...). Nothing was sent. Carries the check as `reason` (a `PlannerWriteRefusalReason`), the `element` as read again, the `capabilityFlags`, for a lesfiche that is not a lesson one the `lessonContent`, and for an assignment type the school does not have the school's `assignmentTypes` as the check read them (see *Why a write was refused*). From the writes, every `SmartschoolPlannerError` means nothing was sent.
- `SmartschoolLessonContentError` — `planLessonContent` could not read the lesfiches before planning one (see `LessonContentService`). Nothing was sent.
- `SmartschoolPlannerSaveUnconfirmedError` — a write went out, but the planner's answer does not confirm it, or no answer came in (carries the `statusCode` or the `cause`). It may or may not have been made: read the element again before trying again; for `planAssignment`, look for the assignment in the calendar of one of its classes, since calling it again adds another one. Not a `SmartschoolPlannerError`.
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; for `planLesson`, `planLessonContent`, `clearLesson`, `planAssignment` and `trashAssignment`, which are not retried, at once. Nothing was changed: call the method again; the client logs in before its next request (#134).
- `SmartschoolParsingError` — `ownCalendar()`: the session's user ID is not in the form `{platformId}_{userId}_{coaccount}`.
