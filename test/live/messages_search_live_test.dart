// The live recipient search (#97): MessagesService.searchRecipientsForCompose
// on the live Smartschool of credentials.yml, and
// searchRecipientsForComposeAll, several searches on one compose form (#107),
// and, when the developer names someone of another school of the school
// group, the search with `includeOtherSchools: true` (#238). It also
// searches the own name with `includeOtherSchools: true` and without, and
// checks that `MessageSearchUser.otherSchool` is `false` for the own account
// both times, though Smartschool gives it a `platformName` with the option on
// (#246): that search switches the setting on and back off as well.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/messages_search_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads, apart from the setting that the searches of #238 and #246
// switch and set back (below): it sends no message and registers no one. A search loads
// the new-message compose form and searches with its `uniqueUsc` (several
// times on one form for searchRecipientsForComposeAll), which registers no
// one on the form, and LiveWireGuard (support/live_wire_guard.dart)
// lets a search out only on a compose form loaded through it, with the empty
// selection the library sends. As every live run, it takes the lock of the
// session first, logs in at most once, and prints no credential, no cookie
// and no name: the own account is counted among the results, and the names
// searched are compared in the test and checked as booleans
// (support/unshown.dart: `expect` shows the actual value of a failed match
// whatever the matcher, and a result's toString holds its name, #216).
//
// The search of people of other schools (#238) runs only with the
// environment variable below, a name (or part of one) that Smartschool finds
// at another school of the school group, and not at the own one:
//
//   DARTSCHOOL_OTHER_SCHOOL_NAME=<name> \
//     dart test -P live test/live/messages_search_live_test.dart
//
// The name comes from the environment, never from the code, and the test
// shows it nowhere: it counts the results, and compares them without showing
// them. Apart from its searches, it changes one thing: the account's setting
// "Toon personen van andere scholen" (`changesgr`), which the web interface
// and every session of the account share. The library switches it on for the
// search and back off afterwards; the test needs it off when it starts, and
// checks that it is off again at the end, as Smartschool's answer to a
// search says it (`<dosgrsearch>`, which the guard keeps). The guard lets a
// switch out only with `val` `0` or `1`, and registers no one but the own
// account on a form: the people of other schools are found, never
// registered, and nothing is sent.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/unshown.dart';

/// The environment variable that names someone of another school (#238).
const _otherSchoolVariable = 'DARTSCHOOL_OTHER_SCHOOL_NAME';

/// The platforms and user IDs of [users], sorted, as one text: compared,
/// never shown.
String _ids(Iterable<MessageSearchUser> users) =>
    (users.map((user) => '${user.ssId}_${user.userId}').toList()..sort()).join(
      ',',
    );

void main() {
  final credentials = liveCredentialsFile();
  final otherSchoolName = Platform.environment[_otherSchoolVariable]?.trim();

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

        // By count: a failure prints no result, whose toString holds the
        // name.
        expect(
          users.where(run.isOwn).length,
          1,
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

      test('searchRecipientsForComposeAll searches several names on one '
          'compose form: the second search on it finds the own account by '
          'its name, as a search on a form of its own does (#107)', () async {
        final name = (await run.client.getCurrentUser()).displayName;
        // A name that is no one's, without spaces or hyphens that a search
        // could take apart.
        const nobody = 'zqxdartschoolnobody';
        final searchesBefore = run.guard.searches;
        final requestsBefore = run.guard.requestsSent;

        final results = await run.messages.searchRecipientsForComposeAll([
          nobody,
          name,
        ]);

        // The keys compared in the test, the results by count: a failure
        // prints no name.
        final keys = results.keys.toList();
        expect(keys.length, 2, reason: 'one result per name searched');
        expectSameUnshown(
          keys.first,
          nobody,
          reason: 'the first key is not the first name searched',
        );
        expectSameUnshown(
          keys.last,
          name,
          reason: 'the second key is not the own name',
        );
        expect(
          results[nobody]!.$1.where(run.isOwn).length,
          0,
          reason: 'each name has the results of its own search',
        );
        expect(
          results[name]!.$1.where(run.isOwn).length,
          1,
          reason:
              'the second search on the compose form must find the own '
              'account once, as the search on a form of its own does',
        );
        // One compose form and two searches on it, loaded and sent through
        // the guard: the session of the form was accepted, so no new form.
        expect(run.guard.searches - searchesBefore, 2);
        expect(
          run.guard.requestsSent - requestsBefore,
          3,
          reason: 'one compose form and one search per name',
        );
        expect(run.guard.submits, 0, reason: 'a search sends no message');
      });

      test(
        'searchRecipientsForCompose with includeOtherSchools: true finds '
        'someone of another school, with the platform of their school, and '
        'leaves the account\'s setting "Toon personen van andere scholen" '
        'off, as it found it (#238)',
        skip: otherSchoolName == null || otherSchoolName.isEmpty
            ? 'set $_otherSchoolVariable to a name of someone of another school '
                  'of the school group to run it (#238)'
            : null,
        () async {
          final name = otherSchoolName!;
          final switchesBefore = run.guard.otherSchoolsSwitches;
          final submitsBefore = run.guard.submits;

          // The setting as the run finds it: a search without the option.
          final (before, _) = await run.messages.searchRecipientsForCompose(
            name,
          );
          expect(
            run.guard.otherSchoolsOn,
            isFalse,
            reason:
                'the account\'s setting "Toon personen van andere scholen" '
                'must be off when the test starts (a search answered '
                'dosgrsearch other than 0); switch it off in the web '
                'interface first',
          );

          final (users, _) = await run.messages.searchRecipientsForCompose(
            name,
            includeOtherSchools: true,
          );

          // First the setting as the run leaves it, whatever the results: a
          // search without the option says it is off, and finds what it
          // found before.
          final (after, _) = await run.messages.searchRecipientsForCompose(
            name,
          );
          expect(
            run.guard.otherSchoolsOn,
            isFalse,
            reason:
                'the setting must be off again after the search: '
                'Smartschool\'s answer to a plain search must say '
                'dosgrsearch 0',
          );
          expect(
            run.guard.otherSchoolsSwitches - switchesBefore,
            2,
            reason: 'one switch on, and one back off',
          );
          expectSameUnshown(
            _ids(after),
            _ids(before),
            reason:
                'the plain search after it must find the users the plain '
                'search before it found',
          );

          // Counts and booleans: a failure shows no name and no ID.
          expect(
            before.every((user) => user.ssId == run.own.ssId),
            isTrue,
            reason:
                'with the setting off, the search finds the own school only',
          );
          final others = users.where((user) => user.ssId != run.own.ssId);
          expect(
            others.length,
            greaterThan(0),
            reason:
                'the search with the option on must find someone of another '
                'school (a platform other than the own)',
          );
          expect(
            others.every(
              (user) =>
                  user.userId > 0 &&
                  user.userLt == 0 &&
                  (user.schoolName?.isNotEmpty ?? false),
            ),
            isTrue,
            reason:
                'each person of another school has a user ID, userLT 0 and '
                'the name of their school',
          );
          expect(
            run.guard.submits - submitsBefore,
            0,
            reason: 'a search sends no message',
          );
          expect(run.guard.violations, isEmpty);
        },
      );

      test('otherSchool tells the own account apart as of the own school, with '
          'includeOtherSchools true as without, though Smartschool gives it a '
          'platformName with the option on; the setting is left off, as found '
          '(#246)', () async {
        final name = (await run.client.getCurrentUser()).displayName;
        final switchesBefore = run.guard.otherSchoolsSwitches;
        final submitsBefore = run.guard.submits;

        // A search without the option: the setting as the run finds it.
        final (plain, _) = await run.messages.searchRecipientsForCompose(name);
        expect(
          run.guard.otherSchoolsOn,
          isFalse,
          reason:
              'the account\'s setting "Toon personen van andere scholen" '
              'must be off when the test starts; switch it off in the web '
              'interface first',
        );

        final (List<MessageSearchUser>, List<MessageSearchGroup>) withOthers;
        try {
          withOthers = await run.messages.searchRecipientsForCompose(
            name,
            includeOtherSchools: true,
          );
        } on SmartschoolOtherSchoolsNotOfferedError {
          markTestSkipped(
            'Smartschool does not offer "Toon personen van andere '
            'scholen" to this account (#246)',
          );
          return;
        }
        final (users, _) = withOthers;

        // The setting as the run leaves it, whatever the results.
        await run.messages.searchRecipientsForCompose(name);
        expect(
          run.guard.otherSchoolsOn,
          isFalse,
          reason: 'the setting must be off again after the search',
        );
        expect(
          run.guard.otherSchoolsSwitches - switchesBefore,
          2,
          reason: 'one switch on, and one back off',
        );

        // Counts and booleans: a failure shows no name and no ID.
        for (final (option, found) in [('off', plain), ('on', users)]) {
          final own = found.where(run.isOwn).toList();
          expect(
            own.length,
            1,
            reason:
                'the search for the own name with the option $option must '
                'find the own account once',
          );
          expect(
            own.single.otherSchool,
            isFalse,
            reason:
                'with the option $option, the own account must have '
                'otherSchool false',
          );
          expect(
            found.every((u) => u.otherSchool == (u.ssId != run.own.ssId)),
            isTrue,
            reason:
                'with the option $option, otherSchool must be true exactly '
                'for a platform other than the own',
          );
        }
        expect(
          users.where(run.isOwn).single.platformName,
          isNotNull,
          reason:
              'with the option on, Smartschool names the own school in '
              'ssPlName too (#246), so platformName does not tell another '
              'school apart',
        );
        expect(
          run.guard.submits - submitsBefore,
          0,
          reason: 'a search sends no message',
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
