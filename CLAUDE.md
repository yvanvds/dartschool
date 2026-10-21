# Notes for coding agents

The conventions of this repository, and what never to do with the live
Smartschool, are in `.github/copilot-instructions.md`: they hold for every
agent, not only Copilot.

## LVS (leerlingvolgsysteem): read the privacy rules first

Before any work on the pupil tracking system (`/?module=LVS`): research,
captures, fixtures, tests, examples, issues, PRs, commit messages: read
[`doc/lvs-privacy.md`](doc/lvs-privacy.md). In short:

- No value from a live LVS answer goes into the repository, a commit
  message, an issue, a PR or a test log: no names, ids, dates or texts of a
  note, no category names of a school, no base64. Describe answers by their
  shape, with placeholders.
- Raw captures go to a temp folder outside the repository, never to
  `dev_dumps/`. Do not open a pupil's data yourself: that capture is the
  developer's step.
- LVS fixtures (`test/fixtures/lvs/`) are written by hand, never trimmed
  from a live answer, with the fakes of `test/fixtures/lvs/FAKES.md` and ids
  in 900000-999999; a new kind of fixture is registered in
  `lvsFixtureKinds`. `test/lvs_fixtures_guard_test.dart` checks them.
