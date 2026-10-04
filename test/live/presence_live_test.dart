// The live answers of the Presence module to getClassPupils (#104): the
// pupils of a class, or the module's reason for listing none, against the
// Presence module of credentials.yml; the names of the statuses its
// half-days hold, which the onlyReplacing check of setLate and setPresent
// compares (#105); and the active class of getConfig, a class or none, with
// a placeholder such as the class -2 ("Uit Planner") kept apart (#117).
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/presence_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads, with the Presence module's three POSTs that read:
// getConfig; getClass for a class the account may record for (a week ago,
// each of the seven days before today, and some eight weeks ahead), for a
// class ID the module does not know and, when getConfig gives one, for the
// placeholder active class; and getAllCodes for the class's school
// structure. It changes no presence: it calls no setLate or setPresent, so
// the onlyReplacing check and the half-day a save returns (#105) are tested
// offline only (presence_set_status_test.dart); LiveWireGuard
// (support/live_wire_guard.dart) refuses every Presence request but those
// three reads, a save of presences above all, and each test checks that the
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
const _getAllCodes = '/Presence/Code/getAllCodes';
const _getClass = '/Presence/Class/getClass';

/// A class ID the Presence module does not know (seen live, 2026-10-03: it
/// answers it without a class).
const _unknownClassId = 99999;

/// Records every request the library tries to send (`METHOD path`), before
/// LiveWireGuard decides whether it goes out.
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The requests tried since [from] to the Presence module that are not one
  /// of its three reads.
  List<String> presenceWritesSince(int from) => [
    for (final request in requests.skip(from))
      if (request.contains(' /Presence/') &&
          request != 'POST $_getConfig' &&
          request != 'POST $_getAllCodes' &&
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

      test('the active class is a class or none, and a placeholder (the class '
          '-2 of a teacher without a lesson now) is kept apart, which '
          'getClass lists no pupils for (#117)', () async {
        final mark = attempts.requests.length;
        final active = config.activeClass;
        final placeholder = config.activePlaceholder;
        // Which of the two the module gave depends on the hour: seen
        // 2026-10-04 (a Sunday), the placeholder -2.
        print(
          'getConfig: active class ${active?.groupId ?? 'none'}, placeholder '
          '${placeholder?.groupId ?? 'none'}',
        );

        if (active != null) {
          expect(active.isPlaceholder, isFalse);
          expect(config.classForGroup(active.groupId), isNotNull);
          expect(placeholder, isNull);
        }
        if (placeholder != null) {
          expect(placeholder.isPlaceholder, isTrue);
          expect(config.classForGroup(placeholder.groupId), isNull);
          final pupils = await classPupils(
            placeholder.groupId,
            day.subtract(const Duration(days: 7)),
          );
          expect(pupils, isEmpty);
          expect(pupils.saveIsAllowed, isFalse);
          // Seen 2026-10-03: "U geeft momenteel geen les. Kies een andere
          // klas in de keuzelijst."
          expect(pupils.errorMessage, isNotNull);
          expect(pupils.classRef, isNull);
        }
        // The classes of the account, as a caller lists them (the allowed
        // classes, plus the active class when it is not among them): none is
        // a placeholder.
        final classes = [...config.allowedClasses, ?config.activeClass];
        expect(classes.where((c) => c.isPlaceholder), isEmpty);
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('the half-days of the class over the last seven days hold statuses '
          'that the codes of its structure name, as the onlyReplacing check '
          'of setLate and setPresent names them (#105)', () async {
        final mark = attempts.requests.length;

        final codes = await presence.getAllCodes(recordable.structId!);
        final held = <String>{};
        var halfDays = 0;
        for (var back = 1; back <= 7; back++) {
          final date = day.subtract(Duration(days: back));
          for (final pupil in await classPupils(recordable.groupId, date)) {
            for (final halfDay in pupil.halfDays) {
              halfDays++;
              final status = PresenceService.statusNameOf(halfDay, codes);
              expect(
                status,
                isNotNull,
                reason:
                    'a half-day of ${halfDay.presenceDate} holds codeID '
                    '${halfDay.codeId}, aliasID ${halfDay.aliasId}, which '
                    'getAllCodes(${recordable.structId}) does not name',
              );
              held.add(status!);
            }
          }
        }

        // The statuses setLate and setPresent set, by the names of the
        // library (seen 2026-10-03, with "Doktersattest" among others).
        final late = codes.firstWhere(
          (c) => c.name == PresenceService.lateCodeName,
        );
        expect(
          late.aliasByName(PresenceService.lateWithoutReasonAliasName),
          isNotNull,
        );
        expect(
          codes.map((c) => c.name),
          contains(PresenceService.presentCodeName),
        );
        expect(halfDays, greaterThan(0), reason: 'no half-day in a week');
        expect(held, isNotEmpty);
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('the run tried no Presence request but its reads', () {
        expect(attempts.presenceWritesSince(0), isEmpty);
        expect(
          attempts.requests.where((r) => r.contains(' /Presence/')),
          everyElement(
            anyOf('POST $_getConfig', 'POST $_getAllCodes', 'POST $_getClass'),
          ),
        );
        expect(run.guard.violations, isEmpty);
      });
    },
  );
}
