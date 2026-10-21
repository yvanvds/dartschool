# Fakes for LVS fixtures

The only people, schools, classes and labels an LVS fixture (a file under
`test/fixtures/lvs/`) may name. LVS fixtures are written by hand, never
trimmed from a live answer: the rules are in
[`doc/lvs-privacy.md`](../../../doc/lvs-privacy.md).

`test/lvs_fixtures_guard_test.dart` reads this file. Every value of a
name-like field in an LVS fixture must be one of the entries below, and every
name in a base64 string anywhere under `test/` must be made of their words.
Need another one? Add it here first: an obvious fake, never a real person,
class or label of a school.

Format: one entry per line, `` - `<entry>` ``, under one of the four headings
below; what follows the entry is a comment. The guard reads the entries only.

## People

First name (one word), then last name. A name-like field may hold a person in
any of these forms, in any case: `Jan Janssens`, `Janssens Jan`,
`Janssens, Jan`, `JANSSENS Jan`, `Jan`, `Janssens`, `J. Janssens`,
`Janssens J.`; HTML around or inside it (`<b>Jans</b>sens Jan`, as a search
highlights) is stripped first. A list of fakes in one field
(`Jan Janssens, Marie Peeters`) is fine too.

- `Jan Janssens` — pupil; the default one
- `Marie Peeters` — pupil
- `Noor Van den Broeck` — pupil, with a last name of three words
- `Chloé Dupont` — pupil, with an accent
- `Lars Peeters` — pupil, a second Peeters (a search with several matches, #160)
- `An Aerts` — pupil (also in the Skore gradebook tests)
- `Bart Claes` — pupil (Skore)
- `Lotte Maes` — pupil (Skore)
- `Fien Verbeke` — pupil (Skore)
- `Piet Peeters` — teacher
- `Céline Dupré` — teacher
- `Els Jacobs` — care coordinator ("zorgcoördinator")
- `Koen Wouters` — parent

## Schools

- `Springfield Academy`

## Classes

- `1A`
- `2B`
- `3C`

## Labels

What a school names itself: note categories, courses, periods, absence codes,
reports, components. Use one of these, or add one that starts with `Test`.
When a name-like field holds a word of Smartschool itself (the same at every
school), it goes here too.

- `Testcategorie`
- `Testsubcategorie`
- `Testvak`
- `Testperiode`
- `Testcode`
- `Testrapport`
- `Testcomponent`
- `TEST` — the abbreviation of a component (#162)
- `Testevaluatie` — an evaluation of a pupil's results (#162)
- `Testbijlage.pdf` — the file name of an attachment of feedback (#162)
- `Testsectie` — a section of a pupil's file in the LVS (#160)
- `Testrichting` — the description of a class (#160)
- `Klassen` — Smartschool's own title of the root of the LVS's class tree (#160)
- `Niet beschikbaar` — Smartschool's own name of the LVS's placeholder pupil (#160)
- `Klas niet gekend` — Smartschool's own class of that placeholder (#160)

## The rest, in short

These are not read from this file; the guard holds them as constants.

- **Ids**: every number in an id-like field is in **900000–999999**
  (`lvsIdMin`, `lvsIdMax`). Numbers below 100 there (0 for "none", a type,
  a flag) identify nothing and are let through. Strings: every number in
  them counts (`tree_group_900101_pupil_900001`, `n_900301`). A UUID is
  `00000000-0000-0000-0000-000000900001` (zeros, then an id of the range);
  a hash or a real-looking UUID (hex letters and digits, 8 or more) fails.
  A JSON key that is an id (`"900201": "Piet Peeters"`) is checked as one.
- **Free text** in a text-like field says `test`: "Testnotitie over de
  leerling.", "<p>Testverslag van het gesprek.</p>".
- **Dates** are made up (a school year such as 2030-2031 makes that plain);
  never the date of a live note.
- **Pictures**: `/smsc/img/fake/initials_JJ.png`, no picture hash.
- **Size**: at most **20 KB** per file (`lvsFixtureMaxBytes`); a
  hand-written fixture is far smaller, a bigger one is likely a pasted
  answer.
- **Which fields** are name-like, id-like and text-like: the common lists
  (`commonNameFields`, `commonIdFields`, `commonTextFields`) and every
  `...Id`/`...ID`/`..._id` field hold for every fixture; each kind of
  fixture (a folder here) adds its own in `lvsFixtureKinds`, all in
  `test/lvs_fixtures_guard_test.dart`.
