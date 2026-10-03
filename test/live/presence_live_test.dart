// The live answers of the Presence module to getClassPupils (#104): the
// pupils of a class, or the module's reason for listing none, against the
// Presence module of credentials.yml.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/presence_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads, with the Presence module's two POSTs that read: getConfig,
// and getClass for a class the account may record for (a week ago and some
// eight weeks ahead) and for a class ID the module does not know. It changes
// no presence: it calls no setLate or setPresent, LiveWireGuard
// (support/live_wire_guard.dart) refuses every Presence request but those
// two reads, a save of presences above all, and each test checks that the
// library did not even try one. As every live run, it takes the lock of the
// session first, logs in at most once, and prints no credential, no cookie
// and no name.
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

const _getConfig = '/Presence/Main/getConfig';
const _getClass = '/Presence/Class/getClass';

/// A class ID the Presence module does not know (seen live, 2026-10-03: it
/// answers it without a class).
const _unknownClassId = 99999;

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The requests tried since [from] to the Presence module that are not one
  /// of its two reads.
  List<String> presenceWritesSince(int from) => [
    for (final request in requests.skip(from))
      if (request.contains(' /Presence/') &&
          request != 'POST $_getConfig' &&
          request != 'POST $_getClass')
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
      late PresenceService presence;
      late _Attempts attempts;
      late PresenceConfig config;

      /// The first official class the account may record for.
      late PresenceClassRef recordable;

      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);

      Future<PresenceClassPupils> classPupils(
        int classGroupId,
        DateTime date,
      ) => presence.getClassPupils(
        classGroupId: classGroupId,
        date: date,
        schoolyearRefDate: config.schoolyearRefDate,
      );

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        attempts = _Attempts();
        // Before the guard, the last interceptor, so that it also sees a
        // request the guard refuses.
        final interceptors = run.client.dio.interceptors;
        interceptors.insert(interceptors.indexOf(run.guard), attempts);
        presence = PresenceService(run.client);
        config = await presence.getConfig();
        recordable = config.allowedClasses.firstWhere(
          (c) => c.userCanRecord && c.structId != null,
          orElse: () => throw StateError(
            'getConfig lists no official class the account may record for',
          ),
        );
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('a class the account may record for, a week ago: its pupils, '
          'saveIsAllowed true, no reason, and the class', () async {
        final mark = attempts.requests.length;

        final pupils = await classPupils(
          recordable.groupId,
          day.subtract(const Duration(days: 7)),
        );

        expect(pupils, isNotEmpty, reason: '${pupils.errorMessage}');
        expect(pupils.saveIsAllowed, isTrue);
        expect(pupils.errorMessage, isNull);
        expect(pupils.classRef?.groupId, recordable.groupId);
        expect(pupils.classRef?.name, recordable.name);
        expect(pupils.classRef?.structId, recordable.structId);
        expect(attempts.requests.skip(mark).toList(), ['POST $_getClass']);
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('the same class some eight weeks ahead: no pupils, saveIsAllowed '
          "false and the module's reason, with the class", () async {
        final mark = attempts.requests.length;

        final pupils = await classPupils(
          recordable.groupId,
          day.add(const Duration(days: 56)),
        );

        expect(pupils, isEmpty);
        expect(pupils.saveIsAllowed, isFalse);
        // Seen 2026-10-03: "Het is niet mogelijk om in de toekomst
        // afwezigheden op te nemen."
        expect(pupils.errorMessage, isNotNull);
        expect(pupils.classRef?.groupId, recordable.groupId);
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('a class ID the module does not know: no pupils, saveIsAllowed '
          "false and the module's reason, without a class", () async {
        expect(
          config.classForGroup(_unknownClassId),
          isNull,
          reason: 'getConfig lists class $_unknownClassId',
        );
        final mark = attempts.requests.length;

        final pupils = await classPupils(
          _unknownClassId,
          day.subtract(const Duration(days: 7)),
        );

        expect(pupils, isEmpty);
        expect(pupils.saveIsAllowed, isFalse);
        // Seen 2026-10-03: "Deze klas bevat geen leerlingen.", as for a
        // class without pupils.
        expect(pupils.errorMessage, isNotNull);
        expect(pupils.classRef, isNull);
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('the run tried no Presence request but its reads', () {
        expect(attempts.presenceWritesSince(0), isEmpty);
        expect(
          attempts.requests.where((r) => r.contains(' /Presence/')),
          everyElement(anyOf('POST $_getConfig', 'POST $_getClass')),
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
