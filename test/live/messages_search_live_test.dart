// The live recipient search (#97): MessagesService.searchRecipientsForCompose
// on the live Smartschool of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/messages_search_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads: it sends no message and registers no one. The search loads
// the new-message compose form and searches with its `uniqueUsc`, which
// registers no one on the form, and LiveWireGuard (support/live_wire_guard.dart)
// lets a search out only on a compose form loaded through it, with the empty
// selection the library sends. As every live run, it takes the lock of the
// session first, logs in at most once, and prints no credential, no cookie
// and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 1)),
    () {
      LiveRun? started;
      late LiveRun run;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('searchRecipientsForCompose finds the own account by its name, '
          'with one search on its compose form (#97)', () async {
        final name = (await run.client.getCurrentUser()).displayName;
        final searchesBefore = run.guard.searches;

        final (users, _) = await run.messages.searchRecipientsForCompose(name);

        expect(
          users.where(run.isOwn),
          hasLength(1),
          reason:
              'the search for the own name must find the own account once, '
              'with its user ID, ssID and userLT',
        );
        // The search went out once, on a compose form loaded through the
        // guard: the session of its form was accepted, so it was not sent
        // again on a new form.
        expect(run.guard.searches - searchesBefore, 1);
        expect(run.guard.submits, 0, reason: 'a search sends no message');
      });
    },
  );
}
