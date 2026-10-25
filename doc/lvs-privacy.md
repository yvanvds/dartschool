# LVS: privacy rules for research, fixtures, tests and issues

The pupil tracking system (LVS, "leerlingvolgsysteem", `/?module=LVS`) holds
the most sensitive data Smartschool has: notes on behaviour and wellbeing,
educational needs and support plans, care notes, sometimes health. **No LVS
data from a live school ever goes into this repository or onto GitHub.**
These rules hold for every contributor and every coding agent, for all LVS
work (#159; the LVS issues #160 to #165 build on them). They hold in
[yvanvds/smartschool-mcp](https://github.com/yvanvds/smartschool-mcp) too,
for its fake LVS (yvanvds/smartschool-mcp#153 and
yvanvds/smartschool-mcp#158).

The usual scrubbing ("replace the names with fakes before committing", see
`tool/sync_all_fixtures.ps1`) is not enough here: an LVS answer is mostly free
text written about a pupil, and a forgotten sentence is a leak. So for the
LVS the rule is stricter: **no LVS fixture is ever derived from a live answer
by trimming it.** Fixtures are written by hand, in the shape the research
found.

## The rules

1. **Research.** The researcher MCP (`bin/smartschool_researcher_mcp.dart`)
   and `DevInspector` write raw answers only **outside the repository**: a
   temp folder (`%TEMP%\lvs-capture\` on Windows, `/tmp/lvs-capture/`
   elsewhere), deleted when the shapes are written down. Never in
   `dev_dumps/` either: that folder is git-ignored, but it lives in the
   working tree, where a `git add -f`, a tool or an agent can pick it up.
   A coding agent does not open a pupil's data: it may read the LVS's static
   code and pages that hold no pupil (the app shell, the JavaScript
   bundles, the root of the class tree); capturing a pupil's answer is the
   developer's step. A capture in the browser goes the same way, and is
   reduced to shapes before anyone else sees it: see
   [Capturing with the browser](#capturing-with-the-browser).
2. **Issues, PRs, commit messages, CHANGELOG, code comments and docs**
   describe an LVS answer by its **shape**: field names, types, nesting, and
   placeholder values (`<pupil id>`, `<text>`, `"Jan Janssens"`). Never a
   value from a live answer: no names, no pupil, class or note ids, no dates
   of a note, no text of a note, no category names a school made itself, no
   base64 strings (they can encode names, as the `alternate` attribute of
   Skore does). Like this:

   ```text
   GET /LVS/Spotlight?searchVal=<text>
   {"pupils": [{"userID": <pupil id: int>, "classID": <class id: int>,
                "className": "<class>", "foundName": "<HTML: name, match in <b>>"}]}
   ```

3. **Fixtures** for the LVS live in `test/fixtures/lvs/` and are written by
   hand (see [Writing an LVS fixture](#writing-an-lvs-fixture)). Every
   person, school, class and label in them is one of the fakes of
   [`test/fixtures/lvs/FAKES.md`](../test/fixtures/lvs/FAKES.md) (Jan
   Janssens, Marie Peeters, Springfield Academy, ...); every id is in the
   reserved range **900000–999999**; every free text is an obvious fake
   ("Testnotitie over de leerling."). `test/lvs_fixtures_guard_test.dart`
   checks them.
4. **Live tests** (`dart test -P live`) for the LVS assert only shapes and
   counts. They never `print` a value from an answer, and their failure
   messages do not quote answers (a test failure log is easily pasted in an
   issue). Mind that `expect` prints the actual value when it fails: pass
   it a count, a type or a `bool` (`expect(note.title.isNotEmpty, isTrue)`,
   `expect(notes.length, greaterThan(0))`), never a name or a text of the
   answer (`expect(pupil.name, contains(...))` is out). The name of a pupil
   to read comes from an environment variable, never from the code. The live
   suite's wire guard (`test/live/support/live_wire_guard.dart`) lets the
   LVS's POST reads out by an allowlist (path, and the dispatcher's
   subsystem and action or function), and never a write (it already sends
   no `PUT`).
5. **Examples** in `example/` for the LVS print shapes and counts by
   default. Printing values needs an explicit flag (`--show-values`), and
   the example says why: what it prints is about a pupil, and terminal
   output gets copied.
6. **Exceptions** of the LVS service never carry answer text or names in
   their `message` (an app logs messages); a `cause` or a separate field
   can, so that an app decides. Models do not print their values in
   `toString()`.

## Capturing with the browser

What the web client itself sends and gets, for the developer's capture
step (#168), is captured in the browser. The live test reads a pupil
through the library and asserts shapes and counts only
(`DARTSCHOOL_LVS_PUPIL`, see `test/live/lvs_live_test.dart`); a browser
capture shows what the web client does besides. A HAR file holds every
answer in full, and the session's cookies, so it is reduced to shapes
before anyone else sees it (#178):

1. Open Smartschool in the browser, open the DevTools (F12) on their
   **Network** tab, and check **Preserve log** (Firefox: *Persist Logs*),
   so that a redirect or a new page keeps the requests before it.
2. Do what the capture is for (open the pupil's file, a category, the
   absences, ...), and little else.
3. Save the log as a HAR file (Chrome and Edge: *Export HAR* on the
   Network tab; Firefox: *Save All As HAR*) into a temp folder outside the
   repository, `%TEMP%\lvs-capture\` on Windows, `/tmp/lvs-capture/`
   elsewhere (rule 1). Where the browser offers a sanitized export, take
   it: it leaves the cookies out (the answers are in the file either way).
4. From the package root, run:

   ```bash
   dart run tool/lvs_har_shapes.dart <temp folder>/<file>.har
   ```

   It refuses a HAR file inside the repository. Per request to Smartschool
   (static files, the web apps' translations `/smsc/locales/` and other
   hosts left out), it prints the method and the path, the query and form
   fields with the pattern of their values (`"9999-99-99"`, `<text>`,
   `<html>`, `<url>`, `<uuid>`, `<JSON text: ...>`; the XML of the
   dispatcher's `command` as a shape), the names of the request headers
   that are not a browser's own, the status, the content type, a
   redirect's path, and the answer's shape: JSON keys with the kinds of
   their values, XML elements and attributes (repeated children as lists
   with their lengths), JSON inside a text, JSON encoded twice. Keys that
   are data (days, school years, ids, labels) and the numbers in a path or
   a name (`<n>`) are masked like values. Only a few enum-like keys show their
   value (`type`, `partOfDay`, `color`, `status`, ...), and the names of
   endpoints (`module`, `file`, `function`, the dispatcher's `subsystem`
   and `action` or `command`, a param's `@name`), and only as a lower-case
   word or an identifier, never one with a number in it.
5. Read the output before you share it, as rule 2 asks of every shape:
   besides the shapes, only those words and the counts may show.
6. Delete the HAR file.

`test/tool/lvs_har_shapes_test.dart` checks, on a fake HAR made of the
fakes of `FAKES.md`, that no value of it shows in the output, that the
shapes do, and that a HAR file inside the repository is refused.

## Writing an LVS fixture

1. Find the shape: the research of the issue, written down as in rule 2.
2. Put the fixture in a folder for its kind under `test/fixtures/lvs/` (the
   answers of one endpoint, say `test/fixtures/lvs/spotlight/`), and
   register the kind in `lvsFixtureKinds` in
   `test/lvs_fixtures_guard_test.dart`: its folder, what it is (with the
   issue), and the fields of its answers that hold names (`nameFields`),
   ids (`idFields`) and free text (`textFields`) beyond the common ones.
   Field names are matched in any spelling (`pupil_name`, `pupilName` and
   `data-pupil-name` are one). For fields known by position only (the
   children of a node of the XML dispatcher), add an `extraFields`
   function; the `example` kind and its fixtures show how.
3. Write it with the fakes of `FAKES.md`. Need another person or label? Add
   it there first, as an obvious fake.
   - Ids: from 900000 up; numbers below 100 (0 for "none", a type, a flag)
     are fine. A UUID: `00000000-0000-0000-0000-000000900001`. No hashes.
   - Texts that hold free text: say "test" ("Testnotitie over de
     leerling.", `<p>Testverslag.</p>`).
   - Dates: made up (school year 2030-2031, say); never the date of a live
     note.
   - Pictures: `/smsc/img/fake/initials_JJ.png`, no hash.
   - No base64 of anything but fakes.
   - Small: at most 20 KB. Write the cases a test needs, not a whole answer.
4. Run `dart test test/lvs_fixtures_guard_test.dart`.

What the guard checks, on every file under `test/fixtures/lvs/` but
`FAKES.md`: it sits in the folder of a registered kind and parses as JSON,
XML or HTML by its extension (JSON inside a string or an XML node is read
too); every value of a name-like field is on the fake list (in one of the
forms `FAKES.md` lists); every number in an id-like field is in the range,
and no hash or real-looking UUID is in one; every value of a text-like field
says "test"; the file is at most 20 KB. And on every file under `test/`: no
base64 string decodes to a name whose words are not those of the fake list.
It fails with the file and the field, never the value.

The common fields, for every kind:

- name-like: `name`, `firstName`, `lastName`, `surname`, `fullName`,
  `displayName`, `foundName`, `userName`, `pupilName`, `studentName`,
  `teacherName`, `authorName`, `ownerName`, `parentName`, `author`,
  `authorReverse`, `teacher`, `teachers` (a map from ids to names too),
  `titularis`, `titularissen`, `startingWithFirstName`,
  `startingWithLastName`, `schoolName`, `class`, `className`, `groupName`,
  `courseName`, `catName`, `categoryName` (in HTML, an element's `class`
  tokens name its field; the `class` attribute itself is not a value);
- id-like: `id` and every name that ends in one (`pupil_id`,
  `data-pupil-id`, `pupilId`, `classID`, `courseIds`), and `pid`, `gid`,
  `uid`, `userid`, `pupilid`, `classid`, `groupid`, `catid`, `itemid`,
  ... `identifier`, `avatarHash`, `pictureHash`, `fileHash`, `picUrl`,
  `pictureUrl`, `downloadUrl`; a JSON key that is an id (`"900201"`,
  `"n_900301"`);
- text-like: `text`, `motivation`, `comment`, `remark`.

The full lists are `commonNameFields`, `commonIdFields` and
`commonTextFields` in the guard.

## When the guard fails

It names the file and the field. Fix the fixture: use a fake of
`FAKES.md`, an id of the range, a text that says "test". When the value is a
fake the list lacks, add it to `FAKES.md`; when a field is checked that
holds no name, id or text (a word of Smartschool itself, say), add that word
to the *Labels* of `FAKES.md`. Never weaken the guard to let a value of a
live answer through, and never paste the failing value into an issue or a
PR.

## What else

- `dev_dumps/` stays git-ignored (`.gitignore`) and out of the package
  (`.pubignore`), for captures of other modules; an LVS answer does not go
  there (rule 1).
- A failing LVS test, a log or an exception that shows a value from a live
  answer: describe what happened instead of pasting it.
