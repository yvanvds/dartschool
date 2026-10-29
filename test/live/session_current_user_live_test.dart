// The live read of the own user from Smartschool's page data (#213):
// SmartschoolClient.getCurrentUser reads the signed-in user from the start
// page, where it is JSON in a JavaScript string. Its escapes were undone in
// two passes, which left the `/` of a URL as `\/`: `avatarUrl` (the
// `pictureUrl` of the page data) read `https:\/\/...`. The test checks the
// user by its shape: an ID, a name and a picture URL without a JavaScript
// escape, the URL an https URL on a smartschool.be host.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/session_current_user_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// It only reads what LiveRun reads to check the own account: the compose
// page, the course list and the start page (`GET /`), which holds the user;
// and it logs in at most once, as every live run, after it took the lock of
// the session. It makes, changes and sends nothing, and prints no
// credential, no cookie, no name and no URL: they are checked as booleans,
// never shown.
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
    'live, the own user from the page data (#213):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('getCurrentUser gives the picture URL with its slashes, and the '
          'name without a JavaScript escape', () async {
        final user = await run.client.getCurrentUser();
        // Checked as booleans, so that a failure shows no name and no URL.
        final name = user.displayName;
        final url = user.avatarUrl;
        final uri = url == null ? null : Uri.tryParse(url);

        expect(user.id, isPositive);
        expect(name.isNotEmpty, isTrue, reason: 'the name is empty');
        expect(
          name.contains(r'\'),
          isFalse,
          reason: 'the name holds a backslash',
        );
        expect(url != null, isTrue, reason: 'there is no picture URL');
        // Before the fix: https:\/\/...
        expect(
          url!.contains(r'\'),
          isFalse,
          reason: 'the picture URL holds a backslash',
        );
        expect(uri?.scheme == 'https', isTrue, reason: 'no https URL');
        expect(
          uri!.host.endsWith('.smartschool.be'),
          isTrue,
          reason: 'the picture URL is not on a smartschool.be host',
        );
        expect(uri.pathSegments.isNotEmpty, isTrue, reason: 'no path');
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
