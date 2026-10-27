# Skore

The reference of `SkoreService` and `SkoreGradebookService`, moved here from the README as pub.dev limits `README.md` to 256 KB (#199). The README keeps the overview of each, with a short example: [`SkoreService`](../README.md#skoreservice) and [`SkoreGradebookService`](../README.md#skoregradebookservice).

## `SkoreService`

### Methods

| Method | Returns | Description |
|---|---|---|
| `getClasses()` | `Future<List<SkoreClass>>` | The classes of all report models, with their model and group. |
| `getCourses(classId)` | `Future<List<SkoreCourse>>` | The courses of a class, in Skore's order, each with its `assignments`. Empty for a class without a course structure, and for a class ID Skore does not know (Skore answers both the same way). |
| `getTeachers()` | `Future<List<SkoreTeacher>>` | The teachers that can be assigned to a course. |
| `addTeacher({classId, courseId, teacherId})` | `Future<SkoreSavedAssignment>` | Adds the teacher to the course of the class: a new assignment (as the green **+** does), which holds all pupils of the class. Returns it, with the course as read before the save. |
| `replaceTeacher({classId, courseId, assignmentId, teacherId})` | `Future<SkoreSavedAssignment>` | Gives an assignment of the course another teacher (as the teacher drop-down does). The assignment keeps its ID, and its gradebook stays. Returns it, with the course and the assignment as it was (`replaced`: the previous teacher), as read before the save. |
| `getGradebookShares(ownerId)` | `Future<List<SkoreGradebookShares>>` | The gradebooks of a teacher, each with the teachers who may read it and those who may read and change it. Empty for a teacher without gradebooks, and for a user ID Skore does not know. |
| `shareGradebook({ownerId, gradebookId, teacherId, access})` | `Future<SkoreGradebookShareChange>` | Shares a gradebook of the owner with the teacher, with `SkoreShareAccess.read` or `.write`; a teacher with the other access is moved. Returns the gradebook as read again, with the gradebook as read before the change and whether anything was saved. |
| `unshareGradebook({ownerId, gradebookId, teacherId})` | `Future<SkoreGradebookShareChange>` | Stops sharing a gradebook of the owner with the teacher. Returns the gradebook as read again, with the gradebook as read before the change and whether anything was saved. |
| `checkAccess()` | `Future<Set<SkoreAccessArea>>` | The parts of Skore the account can use, for a status check: reads the teachers (report management) and the account's own gradebooks (gradebook management), and leaves out a part whose read Skore refuses. Any other failure is thrown. Empty for a teacher without Skore's management rights (seen live, #91). |

A course code is **not** unique within a class: a course and its sub-course can both end in the same `[CODE]`. Tell them apart by `id` (or `label`). Group headers (`isGroupHeader`) are headings for the courses under them and cannot get a teacher.

### Assigning a teacher

> **Warning:** Skore drives the school's grading and reports, and has no test instance. These calls change the live Skore.

```dart
// A new assignment on a course of a class.
final added = await skore.addTeacher(classId: 2516, courseId: 1588, teacherId: 146);

// Another teacher on an existing assignment: the assignment and its gradebook stay.
final saved = await skore.replaceTeacher(
    classId: 2516, courseId: 1588, assignmentId: added.id, teacherId: 320);

// The change in its context, as read before the save: no second read needed.
print('${saved.teacherName} instead of ${saved.replaced?.teacherName} '
    'on course "${saved.course.label}" of class ${saved.course.classId}');
```

Both return a `SkoreSavedAssignment`: the assignment saved (a `SkoreAssignment`: `id`, `teacherId`, `teacherName` of its new teacher), with what the call read before the save (#102): `course`, the `SkoreCourse` as it was (its `label`, `code`, `depth`, and its `assignments` before the change), and, for `replaceTeacher`, `replaced`, the assignment with the teacher it had (`null` for `addTeacher`). So reporting the change needs no second read of the class, which could differ from what the call checked.

Both go through Skore's `saveOwner`. Before it, they read the class (`getCourses`) and the teachers (`getTeachers`) again, and refuse with a `SmartschoolSkoreChangeRefusedError`, saving nothing:

- a course that is not in the class (also for a class ID Skore does not know), or that is a group header;
- for `replaceTeacher`, an `assignmentId` that is not one of that course in that class;
- a teacher who already has an assignment on the course (for `replaceTeacher`, the current teacher of the assignment too);
- a teacher who is not in `getTeachers()`.

`replaceTeacher` then asks Skore whether the current teacher works with "Mijn lesgroepen" for the course, as Skore's web client does, and refuses with a `SmartschoolSkoreMyGroupsError` (a `SmartschoolSkoreChangeRefusedError`) when they do. Skore's web client offers to delete those groups, which cannot be undone; the service never does: handle them in Skore first.

The save is sent **once**: it is never retried, not even after logging in again, since a repeated add adds a second assignment. Skore answers it with the assignment and its teacher; when the answer does not confirm the save (another teacher, for a replace another assignment, or no usable answer at all), the call throws a `SmartschoolSkoreAssignmentSaveUnconfirmedError` (a `SmartschoolSkoreSaveUnconfirmedError`): the change may or may not have been saved, so read the class again before trying again. The error carries what the call read before the save (#120), as the result would have: `course` (the `SkoreCourse` as read before the save: its `label`, and its teachers then), `replaced` (for `replaceTeacher`, the assignment with the teacher it had; `null` for `addTeacher`) and `teacher` (the `SkoreTeacher` it was saving: ID and name). So telling the user what may have been saved, and what to look for, needs no read of your own: a read after a save that may have gone through cannot tell what was there before. Calling the method again is safe in itself: it reads the class first, and refuses a teacher who already has an assignment on the course. The checks and the save are separate requests, so do not change the same course from two places at once.

The example asks for confirmation before it saves, and reads the class again afterwards:

```bash
dart run example/skore_assign_teacher_example.dart CLASS_ID COURSE_ID TEACHER_ID [ASSIGNMENT_ID]
```

### Sharing a gradebook

> **Warning:** these calls change the live Skore too, and need Skore admin rights.

```dart
// Every year: share the titularis's "Digitale vaardigheden" gradebook of a
// class with the other teachers of the class.
final gradebooks = await skore.getGradebookShares(146); // List<SkoreGradebookShares>
final shared = await skore.shareGradebook(
    ownerId: 146, gradebookId: 34826, teacherId: 320, access: SkoreShareAccess.write);
print('${shared.readerIds} ${shared.writerIds}');

// The change in its context, as the call read it: no read of your own needed.
print(shared.saved
    ? 'now ${shared.accessAfter?.name} access (had: ${shared.accessBefore?.name ?? 'none'})'
    : 'already had ${shared.accessBefore?.name} access; nothing saved');

// And undo it.
await skore.unshareGradebook(ownerId: 146, gradebookId: 34826, teacherId: 320);
```

Both return a `SkoreGradebookShareChange`: the gradebook as read again after the save (a `SkoreGradebookShares`: `readerIds`, `writerIds`, ...), with what the call read and did (#103): `before`, the gradebook as it read it before the change (the one it checked), `teacherId`, the teacher whose access it changed, with their `accessBefore` and `accessAfter` (`SkoreShareAccess?`, `null` for none), and `saved`, whether it sent a save (and Skore confirmed it). So reporting the change ("now write access instead of read access", "already had write access; nothing saved", "unshared (had read access)") needs no read of the owner's gradebooks of your own, which could differ from what the call checked.

Both go through Skore's `saveShared`. The save holds **this gradebook only**, with its complete new readers and writers: the teachers it is already shared with keep their access, unless the change is about them, and the owner's other gradebooks are not touched. A teacher has one kind of access: sharing with write access takes them off the readers, and the other way round.

Before the save, they read the owner's gradebooks again, and refuse with a `SmartschoolSkoreChangeRefusedError`, saving nothing:

- the owner as the teacher (Skore never offers the owner as a reader or a writer);
- a gradebook that is not one of the owner's (also for a user ID Skore does not know), so a gradebook is never saved under another owner;
- for `shareGradebook`, a teacher who is not in `getTeachers()`. `unshareGradebook` can take off a teacher who is no longer in it, such as one who has left the school.

When nothing changes (already shared with that access, or not shared when unsharing), nothing is saved and the gradebook is returned as read, with `saved` `false` (and `before` the same gradebook).

Skore answers the save with `state` 1. The call then reads the owner's gradebooks again and checks that the gradebook has exactly the readers and writers saved; when the answer or that read does not confirm the save, it throws a `SmartschoolSkoreShareSaveUnconfirmedError` (a `SmartschoolSkoreSaveUnconfirmedError`): read the gradebooks again before trying again. The error carries what the call read before the save (#120): `before`, the gradebook as read before the change (its `className` and `courseName`, and its readers and writers then), and `teacherId`, with their `accessBefore`. Since the save holds the complete lists, sending it again does not change the outcome, so (unlike `addTeacher` and `replaceTeacher`) it is retried once after logging in again, as a read is. The checks and the save are separate requests, so do not change the shares of the same gradebook from two places at once.

The example shows the gradebook, asks for confirmation before it saves, and prints the change from the result (it reads the gradebooks again only when the save was not confirmed):

```bash
dart run example/skore_share_gradebook_example.dart OWNER_ID GRADEBOOK_ID TEACHER_ID read|write|remove
```

### Errors

`SmartschoolSkoreError` has a type for each case a caller handles differently (#83): a missing right, a refused change, and (the type itself) an answer the service cannot use. A `catch` of `SmartschoolSkoreError` catches all of them, and from `addTeacher`, `replaceTeacher`, `shareGradebook` and `unshareGradebook` every `SmartschoolSkoreError` means nothing was saved.

- `SmartschoolSkoreAccessDeniedError` — Skore refused the request to the account, which lacks the rights for that part of Skore (carries `area`: `SkoreAccessArea.reportManagement` or `.gradebookManagement`). Thrown when Skore sends the request on to Smartschool's start page, its answer to every request of a teacher without the rights (#91), and for an answer with HTTP 403. Its message quotes nothing of the answer, so it can be shown to the user.
- `SmartschoolSkoreChangeRefusedError` — a check before the save refused the change (the checks are listed above). Nothing was saved. Its message says which check refused and why, so the call can be corrected.
- `SmartschoolSkoreMyGroupsError` (a `SmartschoolSkoreChangeRefusedError`) — `replaceTeacher`: the current teacher works with "Mijn lesgroepen" for the course (carries `classId`, `courseId`, `teacherId`, and `teacherName` as read from the class). Nothing was saved.
- `SmartschoolSkoreError` itself (none of the types above) — Skore answered with something the service cannot use: another HTTP status than `200`, an HTML page instead of data, invalid JSON, an RPC answer without a `result`, or data in an unknown shape (also a gradebook without its list of readers or writers, or a `getMyGroups` answer it does not recognise). The session was accepted: signing in again does not help. Its message may quote the answer, which can hold names: keep it in a log. An HTML page instead of the list of report models (`getClasses`) is named, not quoted: where it ended and the redirects that led there, by path and `module` only (#194).
- `SmartschoolSkoreSaveUnconfirmedError` — `addTeacher`, `replaceTeacher`, `shareGradebook` or `unshareGradebook` sent the save, but Skore's answer (for a share, also the read afterwards) does not confirm it, or no answer came in (carries the `cause`). It may or may not have been saved: read again. Not a `SmartschoolSkoreError`. The service always throws one of its two subtypes, which carry what the call read before the save (#120): `SmartschoolSkoreAssignmentSaveUnconfirmedError` from `addTeacher` and `replaceTeacher` (`course`, `replaced`, `teacher`), and `SmartschoolSkoreShareSaveUnconfirmedError` from `shareGradebook` and `unshareGradebook` (`before`, `teacherId`, `accessBefore`). A `catch` of `SmartschoolSkoreSaveUnconfirmedError` catches both. Its message names the change by IDs only.
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; or Skore answered an RPC without a session (which its web client reports as an empty session); or Skore sent a read of `getClasses` or `getCourses` on to Smartschool's start page at `/` twice (#194). Sign in again and retry. The save of `addTeacher` and `replaceTeacher` is not retried: it fails at once, and the client logs in before its next request (#134), so calling the method again is enough. Skore sends a read in a session it does not accept on to `/`, which is the start page in a session Smartschool accepts: the service then sends the read once more, as following the redirect loaded the start page, after which Skore accepts the session (#192, #194).

## `SkoreGradebookService`

### Methods

| Method | Returns | Description |
|---|---|---|
| `getGradebooks({workyearId})` | `Future<List<SkoreGradebook>>` | The teacher's own gradebooks of the school year (Skore's current one without `workyearId`), one per class and course, in the order of Skore's left panel. Empty for a teacher without gradebooks. |
| `getGradebookYear({workyearId, includeShared})` | `Future<SkoreGradebookYear>` | The same gradebooks, with the school year they are of (`workyear`) and the school years Skore offers (`workyears`); with `includeShared: true`, also the gradebooks shared with the teacher (`sharedGradebooks`). |
| `getSharedGradebooks({workyearId})` | `Future<List<SkoreGradebook>>` | The gradebooks of the school year that colleagues shared with the teacher, each with its teacher (`teacherId`, `ownerName`) and the teacher's `access` (`write` or `read`). |
| `getGradebook(gradebook)` | `Future<SkoreGradebookSheet>` | A gradebook with its periods, the period Skore opens it on (`activePeriod`), the pupils of its class and whether Skore lets the user change it (`writable`). |
| `getEvaluations(gradebook, periodId)` | `Future<List<SkoreEvaluation>>` | The gradebook's evaluations in the period, in Skore's order, each with its `publication` and the `results` (grades) of the class's pupils. One request. |
| `getResults(gradebook, evaluation)` | `Future<SkoreEvaluationResults>` | The grades of an evaluation as Skore has them now (`getEvaluations` again). |
| `getFeedback(gradebook, evaluation, pupilId)` | `Future<List<SkoreFeedback>>` | A pupil's feedback on an evaluation, each apart, from every teacher, in the order written. Empty for none. |
| `getScale()` | `Future<SkoreScale>` | The school's scale of the evaluations on a scale ("Waarderingen"): its `levels` (`description`, `abbreviation`, `lowerThreshold`), and `levelOf(evaluation, grade)`, a grade's level as Skore's web client finds it. Two GETs (#193). |
| `getComponents(gradebook, periodId)` | `Future<List<SkoreEvaluationComponent>>` | The components a new evaluation in the period can count for (`0` `geen`, `2` `DW`, ...). |
| `createEvaluation(gradebook, periodId, {title, shortName, date, max, componentId})` | `Future<SkoreEvaluation>` | Creates an evaluation in the period, **unpublished**, and returns it as read again. |
| `saveGrade(gradebook, evaluation, pupilId, grade, {allowPublished})` | `Future<SkoreGrade>` | Saves (or, with `null`, clears) a pupil's grade, and returns the cell as read again. |
| `saveGrades(gradebook, evaluation, grades, {allowPublished})` | `Future<Map<int, SkoreGrade>>` | The same for several pupils (`{pupilId: grade}`), one save each, one read afterwards. |
| `saveFeedback(gradebook, evaluation, pupilId, text, {allowPublished})` | `Future<SkoreFeedback>` | Creates your feedback for the pupil, or changes it, and returns it as read again. |
| `getReport(gradebook, reportId)` | `Future<SkoreReport>` | A report period of the gradebook (one of `SkoreGradebookSheet.reports`): per pupil of the class, the results so far per component and the course comment, with whether Skore lets you change it. One request (#195). |
| `saveReportComment(gradebook, reportId, pupilId, text, {replacing})` | `Future<SkoreReportComment>` | Writes the pupil's course comment on the report, replacing the comment passed as `replacing` (`null`: none), and returns it as read again (#195). |

- **One big read.** `getGradebooks` sends Skore's `getNavigation` once; its answer holds the colleagues of every gradebook and is big (some 270 KB for 22 gradebooks, 1.7 MB for 50). Read it once, not per gradebook. A group of classes in Skore's tree repeats gradebooks of its classes: each gradebook is listed once.
- **IDs.** `gradebookId` is Skore's `ownerID`, the same ID as the assignment that holds the gradebook (`SkoreAssignment.id` of the admin side). `pathIds` (`[modelId, groupId, classId]`) is how Skore's gradebook calls name the class. A pupil ID is the pupil's Smartschool user ID; `rowKey` is Skore's key of the pupil's row (`pupil_<id>_<classId>`).
- **School years.** A school year is Skore's ID (`SkoreWorkyear`: `24` is `2026-2027`). The calls about a gradebook go out for its `workyearId`. A `workyearId` that is not positive is refused before anything is sent, one Skore does not offer after its answer (Skore answers it with no gradebooks), both with an `ArgumentError`.
- **Course names.** `SkoreGradebook.courseName` is the name as the left panel shows it, with the grade Skore adds (`Informaticawetenschappen (2 uur) (6e j DO)`); `SkoreGradebookSheet.courseName` is the name without it (`Informaticawetenschappen (2 uur)`).
- **Periods.** `isOpen` says whether Skore takes grades in the period; `closesAt` is when it closes (UTC). Skore adds periods during the school year.
- **Pupils.** The pupils of the gradebook's class, in class order: `number` (`null` when Skore shows none, as for an earlier school year), `name` (`Last, First`), `displayName` (`First Last`), `isActive` (`false` for a row Skore greys out).
- **Shared gradebooks.** `getSharedGradebooks` lists what the tab "Gedeeld" of Skore's gradebook lists (Skore's `accessableList`), such as a class's behaviour gradebook in the name of one form teacher, shared with the co-titularis (#191). A shared gradebook is a `SkoreGradebook` whose `teacherId` is the colleague who shared it, with `access` `write` or `read` (`own` for your own; `isShared`); its `className` and `courseName` come from Skore's label (`6EWI/Digitale vaardigheden`), and it has no `modelName`, `groupName` or `teacherNames`. Pass it to the other methods as any gradebook: they open it as Skore's web client does, in the name of its teacher and restricted to it. `saveGrade`, `saveGrades` and `saveFeedback` write in one shared to write, with the same checks (re-reading the shared list too); your feedback there is the feedback you wrote. One shared to read only is refused before anything is sent, with a `SmartschoolSkoreGradebookReadOnlyError`. `createEvaluation` keeps to your own gradebooks. The writes in a shared gradebook follow the web client's code; they were not tried live yet.
- **Writable.** `writable` is Skore's answer for the user's rights in the gradebook (`getGradebookContext`), not about a period: Skore also answers it for a closed period of an earlier year. Without periods, Skore is not asked and it is `false`.
- **Evaluations.** Know an evaluation by its `id` (Skore's `refID`): its `column` (`A`, `B`) changes when one is added. Skore sends the rows of the other classes of the group along; only the gradebook's own evaluations and pupils are kept. One of a type or with cells the library does not know comes back with `isReadable` `false` and its `unreadableReason`, and its `results` throw a `SmartschoolSkoreEvaluationUnreadableError`: the rest of the period is read (#193).
- **Publication.** `publication.state` is `notPublished` (Skore's `public` `"0"`), `scheduled` (`"1"` with a `publicdatetime` still to come) or `published`, by the service's clock (`SkoreGradebookService(client, clock: ...)`) at the time of the read; `stateAt(time)` for another time. `at` is Skore's `publicdatetime`, a Belgian time without offset, in UTC; the raw values are kept (`rawPublic`, `rawPublicDateTime`).
- **Grades.** `grade` is the value Skore stores, as a string (`"15.5"`, with a point; Skore shows `15,5`), `null` for none; `value` parses it. `hasFeedback` is the cell's marker; `getFeedback` reads the texts from Skore's REST API (`/skore/api/v1/gradebook/feedback/...`), each apart, which the cell's tooltip joins into one.
- **Never publishes.** Skore's gradebook RPC service also deletes, moves, publishes and shares evaluations. The service calls only the methods in `SkoreGradebookService.rpcMethods` (the reads, `accessableList` and `getReportsResults` among them, `saveEvaluation`, `saveGrade`, and `saveType` with the type `info` only), and refuses any other before it is sent.
- **Creating an evaluation.** `createEvaluation` always sends `public` 0 and `publicdatetime` `""`: teachers publish in Smartschool themselves. It first refuses, with a `SmartschoolSkoreChangeRefusedError` and nothing saved, a blank title, a `max` that is not positive, a gradebook that is not your own of the current school year, a closed period or one Skore shows read-only, a date outside the school year, and a course or component Skore does not offer. The save is sent once, never retried; if the answer, or reading the period again, does not confirm it, a `SmartschoolSkoreEvaluationCreateUnconfirmedError` (read the period again before trying again). If it comes back public anyway, a `SmartschoolSkoreEvaluationPublicError` names it, and the library changes nothing.
- **Saving grades.** `saveGrade` / `saveGrades` refuse first, with a `SmartschoolSkoreChangeRefusedError` and nothing saved: a grade that is not a number of 0 or more, or above `max` (Skore answers it with HTTP 500); an evaluation that is **published or scheduled, unless `allowPublished: true`** (pupils see it, and get a notification), from the planner, or not in points; a pupil without a cell of the gradebook's class; and what `createEvaluation` refuses for the gradebook and period. All pupils are checked before the first save. A failed save does not stop the others; afterwards the period is read once, and a `SmartschoolSkoreGradeSaveUnconfirmedError` tells per pupil what is `confirmed`. Saving a grade again is harmless.
- **Reports.** `SkoreGradebookSheet.reports` are the report periods of a gradebook (Skore's `init`, `reports`: `R1D`, "Rapport 1"), with `isOpen`, `closesAt` and `info`, also for a gradebook without evaluation periods, such as a behaviour gradebook (#195). `getReport` sends Skore's `getReportsResults`, as the web client opens a report: `components` (`DW`, with Skore's `column` and the class average), and per pupil (`SkoreReportPupil`) the `results` as Skore shows them (`value`, `null` for `-`; `isLow`), read-only, and the `comment` (`SkoreReportComment`: `text`, with its lines; `isEditable`, `false` for a comment Skore closed for the pupil). A behaviour gradebook's report has the comments only. Skore keeps **one** course comment per pupil, course and report, and does not say who wrote it: the teachers of a course share it. A course that is not on the report is a `SmartschoolSkoreError` (Skore's HTTP 404 "Course not found in source!", seen live).
- **Saving a course comment.** `saveReportComment` replaces the pupil's course comment, so it replaces only the comment you expect: pass the comment `getReport` showed as `replacing`, or `null` when the pupil has none; when Skore holds another one, nothing is saved. It refuses first, with a `SmartschoolSkoreChangeRefusedError` and nothing saved: a blank text, a gradebook that is not your own of the current school year nor shared with you to write, a report that is not the gradebook's or is closed, a pupil without a comment on it in the class, a comment closed for the pupil, a text longer than the report allows (`commentMaxLength`, 1600 seen live), and another comment than `replacing`. The text is sent as Skore's comment editor sends it (trimmed, each line trimmed, line breaks as `\n`) with Skore's `saveType` (type `info`; the service sends no other type), and read again; a `SmartschoolSkoreReportCommentSaveUnconfirmedError` when Skore's answer or that read does not confirm it (saving again is harmless). It never closes, unlocks, calculates or publishes a report. The save follows the web client's code: it was not tried live yet.
- **Saving feedback.** `saveFeedback` reads the pupil's feedback first: without feedback of yours it creates it (`POST /skore/api/v1/gradebook/feedback`, sent once: a second create adds a second feedback), with one it changes that (`POST .../feedback/{id}`). Other teachers' feedback is never changed. It refuses what `saveGrade` refuses for the gradebook, period, evaluation (published or scheduled unless `allowPublished: true`) and pupil, a blank text, your feedback when Skore does not let you change it, and more than one of yours. A `4xx` answer is a `SmartschoolSkoreError`; an answer, or a read afterwards, that does not confirm the text a `SmartschoolSkoreFeedbackSaveUnconfirmedError`.

The example lists the gradebooks and prints the periods and pupils of one of them, its reports with each pupil's results and course comment, and the evaluations of its active period with their publication, grades and feedback (read-only):

```bash
dart run example/skore_gradebook_example.dart [GRADEBOOK_ID] [--workyear=ID]
# Creates an evaluation after asking (y/N); changes the live Skore:
dart run example/skore_create_evaluation_example.dart GRADEBOOK_ID PERIOD_ID TITLE YYYY-MM-DD MAX [--short=NAME] [--component=ID]
# Saves a pupil's grades in an unpublished evaluation after asking (y/N; "-" clears):
dart run example/skore_save_grade_example.dart GRADEBOOK_ID PERIOD_ID EVALUATION_ID PUPIL_ID GRADE [GRADE ...]
# Writes a pupil's course comment on an open report after asking (y/N); it goes on a real report:
dart run example/skore_save_report_comment_example.dart GRADEBOOK_ID REPORT_ID PUPIL_ID TEXT
```

### Errors

- `SmartschoolSkoreError` — Skore answered with something the service cannot use: another HTTP status than `200` (also a redirect, whose target the message names by its path and `module` only), an HTML page instead of data, invalid JSON, an RPC answer without a `result`, data in an unknown shape, or an answer about another gradebook or school year. Never an empty list instead. The session was accepted: signing in again does not help. Its message may quote the answer, which can hold names: keep it in a log. What Skore answers an account without a gradebook of its own (a pupil, say) was not captured.
- `SmartschoolSkoreGradebookReadOnlyError` (a `SmartschoolSkoreChangeRefusedError`) — `saveGrade`, `saveGrades`, `saveFeedback`, `saveReportComment` or `createEvaluation` in a gradebook shared with you to read only (as passed, before anything is sent, or as Skore lists it right before the save); carries the `gradebook`. Nothing was saved (#191).
- `ArgumentError` — a `workyearId` that is not positive, or not one Skore offers; a `periodId`, `reportId` or `pupilId` that is not positive, or an evaluation of another gradebook (nothing sent).
- `SmartschoolSessionExpiredError` — Smartschool did not accept the session, also after the client logged in again and retried once; or Skore answered without a session. Sign in again and retry. Skore answers a call in a session that expired with a redirect to `/`, which the client takes for a refused session: it logs in and sends the call again, as for any other request (#192).
