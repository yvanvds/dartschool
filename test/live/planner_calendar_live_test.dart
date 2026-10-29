// The live lookup of a planner calendar by its ID (#127): the names that
// PlannerService.getCalendar gives the own calendar and the calendars of a
// class, a room and a colleague (the same names as the elements of the
// planner give them), and its null for a made-up ID of each kind, which
// getPlannedElements answers as a room with nothing planned or with an
// error that does not say why, against the live planner of
// credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/planner_calendar_live_test.dart`
// alone. Without a credentials.yml in the package root, it skips.
//
// It only reads: GETs of the own planner in the coming weeks, of the
// calendar of a class of it in the same weeks (to find a colleague), and of
// a made-up class and room; and the planner's lookup, POST
// quick-search/planner/start, which only reads. LiveWireGuard
// (support/live_wire_guard.dart) refuses every other planner POST, and the
// last test checks that the library did not even try one. As every live
// run, it takes the lock of the session first, logs in at most once, and
// prints no credential, no cookie and no name: names are compared in the
// test and checked as booleans, never shown (support/unshown.dart: `expect`
// shows the actual value of a failed match whatever the matcher, #215).
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/unshown.dart';

const _lookupPath = '/planner/api/v1/quick-search/planner/start';

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The requests tried to the planner that are not a GET or its lookup.
  List<String> get plannerWrites => [
    for (final request in requests)
      if (request.contains(' /planner/') &&
          !request.startsWith('GET ') &&
          request != 'POST $_lookupPath')
        request,
  ];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add('${options.method.toUpperCase()} ${options.uri.path}');
    handler.next(options);
  }
}

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late LiveRun run;
      late PlannerService planner;
      late _Attempts attempts;
      late PlannerCalendar own;
      late String platformId;
      late DateTime from;
      late DateTime to;
      late List<PlannedElement> ownElements;

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        planner = PlannerService(run.client);

        own = await planner.ownCalendar();
        platformId = own.id.split('_').first;
        final today = DateTime.now();
        from = DateTime(today.year, today.month, today.day - today.weekday + 1);
        to = DateTime(from.year, from.month, from.day + 27, 23, 59, 59);
        ownElements = await planner.getPlannedElements(own, from: from, to: to);
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('the own calendar is named after the authenticated user', () async {
        final me = await planner.getCalendar(own);
        final user = await run.client.getCurrentUser();

        expect(me, isNotNull);
        expect(me!.calendar, own);
        expect(me.kind, PlannerSearchResultKind.user);
        expect(me.isDeleted, isFalse);
        expectSameUnshown(
          me.name,
          user.displayName,
          reason: 'the own calendar is not named as the authenticated user',
        );
        expect(
          me.title.contains('%'),
          isFalse,
          reason: 'the title of the own calendar holds a % (not shown)',
        );
      });

      test('a class and a room of the own planner are named as its elements '
          'name them', () async {
        final group = ownElements
            .expand((e) => e.participantGroups)
            .firstOrNull;
        final room = ownElements.expand((e) => e.locations).firstOrNull;
        if (group == null || room == null) {
          markTestSkipped(
            'no element with a class and a room in the own planner from '
            '$from to $to',
          );
          return;
        }

        final klas = await planner.getCalendar(group.calendar);
        final location = await planner.getCalendar(room.calendar);

        expect(klas, isNotNull);
        expect(klas!.calendar, group.calendar);
        expect(klas.kind, PlannerSearchResultKind.group);
        expectSameUnshown(
          klas.name,
          group.name,
          reason: 'the class is not named as the element names it',
        );
        expect(klas.isDeleted, isFalse);
        expect(location, isNotNull);
        expect(location!.calendar, room.calendar);
        expect(location.kind, PlannerSearchResultKind.location);
        expectSameUnshown(
          location.name,
          room.title,
          reason: 'the room is not named as the element names it',
        );
      });

      test('a colleague of a class of the own planner is named as the '
          'elements name the colleague', () async {
        final group = ownElements
            .expand((e) => e.participantGroups)
            .firstOrNull;
        if (group == null) {
          markTestSkipped('no class in the own planner from $from to $to');
          return;
        }
        final colleague =
            (await planner.getPlannedElements(
                  group.calendar,
                  from: from,
                  to: to,
                ))
                .expand((e) => e.organiserUsers)
                .where((u) => u.id != own.id)
                .firstOrNull;
        if (colleague == null) {
          markTestSkipped('no colleague in the class from $from to $to');
          return;
        }

        final named = await planner.getCalendar(colleague.calendar);

        expect(named, isNotNull);
        expect(named!.calendar, colleague.calendar);
        expect(named.kind, PlannerSearchResultKind.user);
        expectSameUnshown(
          named.name,
          colleague.name,
          reason: 'the colleague is not named as the elements name them',
        );
      });

      test('a made-up class, user, co-account and room are null', () async {
        final userId = own.id.split('_')[1];
        final madeUp = [
          PlannerCalendar.group('${platformId}_999999999'),
          PlannerCalendar.user('${platformId}_999999999_0'),
          PlannerCalendar.user('${platformId}_${userId}_9'),
          PlannerCalendar.location(
            '${platformId}_00000000-0000-4000-8000-000000000000',
          ),
        ];

        for (final calendar in madeUp) {
          // Checked as a boolean: a calendar found would show its name.
          final found = await planner.getCalendar(calendar);
          expect(
            found == null,
            isTrue,
            reason: '$calendar: a calendar was found (not shown)',
          );
        }
      });

      test('getPlannedElements answers a made-up room as a room with nothing '
          'planned, and a made-up class with HTTP 500', () async {
        final room = PlannerCalendar.location(
          '${platformId}_00000000-0000-4000-8000-000000000000',
        );
        final klas = PlannerCalendar.group('${platformId}_999999999');

        expect(
          await planner.getPlannedElements(room, from: from, to: to),
          isEmpty,
        );
        await expectLater(
          planner.getPlannedElements(klas, from: from, to: to),
          throwsA(
            isA<SmartschoolPlannerError>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
        // getCalendar tells both from a planner with nothing planned
        // (checked as booleans: a calendar found would show its name).
        final foundRoom = await planner.getCalendar(room);
        final foundClass = await planner.getCalendar(klas);
        expect(
          foundRoom == null,
          isTrue,
          reason: 'getCalendar found the made-up room (not shown)',
        );
        expect(
          foundClass == null,
          isTrue,
          reason: 'getCalendar found the made-up class (not shown)',
        );
      });

      test('nothing but reads went out', () {
        expect(attempts.requests, contains('POST $_lookupPath'));
        expect(attempts.plannerWrites, isEmpty);
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
