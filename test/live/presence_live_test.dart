// The live answers of the Presence module to getClassPupils (#104): the
// pupils of a class, or the module's reason for listing none, against the
// Presence module of credentials.yml; the names of the statuses its
// half-days hold, which the onlyReplacing check of setLate and setPresent
// compares (#105); the active class of getConfig, a class or none, with
// a placeholder such as the class -2 ("Uit Planner") kept apart (#117); and
// the names of the statuses of a grouping class, which has no structure:
// the name the module gives with each half-day, and the codes of the
// structure of each pupil's official class (#126). And the HTTP status of
// every answer of the module to those reads: a `200`, which the service
// reads as the module's answer, while a JSON answer with a status outside
// `200`–`299` is an error it never reads as data (#143; tested offline in
// presence_unreadable_answer_test.dart, not provoked here).
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/presence_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It passes for an account with the right to set half-days
// (`userCanConfirm`, an absence administrator's) and for one without it:
// the module answers a day ahead differently for the two (#123).
//
// It only reads, with the Presence module's three POSTs that read:
// getConfig; getClass for a class the account may record for (a week ago,
// each of the seven days before today, and some eight weeks ahead), for a
// class ID the module does not know and, when getConfig gives one, for the
// placeholder active class, and for a grouping class (from yesterday back to
// the last day with half-days, at most a week); and getAllCodes for the
// class's school structure and for those of the official classes of the
// grouping class's pupils. It changes no presence: it calls no setLate or
// setPresent, so the onlyReplacing check and the half-day a save returns
// (#105) are tested offline only (presence_set_status_test.dart);
// LiveWireGuard
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
/// LiveWireGuard decides whether it goes out, and the HTTP status of every
/// answer of the Presence module (#143).
class _Attempts extends Interceptor {
  final List<String> requests = [];

  /// The answers of the Presence module, as `METHOD path` and HTTP status.
  final List<(String, int?)> presenceAnswers = [];

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

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final options = response.requestOptions;
    if (options.uri.path.startsWith('/Presence/')) {
      presenceAnswers.add((
        '${options.method.toUpperCase()} ${options.uri.path}',
        response.statusCode,
      ));
    }
    handler.next(response);
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

      test('the same class some eight weeks ahead, with the class: for an '
          'account without the right to set its half-days, no pupils, '
          "saveIsAllowed false and the module's reason; with it, its pupils "
          'and saveIsAllowed true (#123)', () async {
        final mark = attempts.requests.length;

        final pupils = await classPupils(
          recordable.groupId,
          day.add(const Duration(days: 56)),
        );
        // Which of the two the module gave depends on the account's rights
        // (#121, #123): with the absence-administrator rights switched off
        // (userCanConfirm false), no pupils, false and a reason (seen
        // 2026-10-03: "Het is niet mogelijk om in de toekomst afwezigheden op
        // te nemen.", and in a run of 2026-10-04); seen 2026-10-04 with them on
        // (userCanConfirm true), the pupils, true and no reason, as for a day
        // up to today (up to some seventeen weeks ahead; a day of the next
        // school year got no pupils and "Deze klas bevat geen leerlingen.",
        // so for such an account this test holds outside the last eight
        // weeks of a school year).
        final mayConfirm = recordable.userCanConfirm;
        print(
          'a day ahead, ${mayConfirm ? 'with' : 'without'} userCanConfirm: '
          '${pupils.length} pupils, saveIsAllowed ${pupils.saveIsAllowed}',
        );

        // By count, not the list: a failure prints no pupil's name.
        if (mayConfirm) {
          expect(pupils.length, greaterThan(0), reason: pupils.errorMessage);
          expect(pupils.saveIsAllowed, isTrue);
          expect(pupils.errorMessage, isNull);
        } else {
          expect(pupils.length, 0);
          expect(pupils.saveIsAllowed, isFalse);
          expect(pupils.errorMessage, isNotNull);
        }
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
              // The name the module gives with the record is the same
              // (#126).
              expect(halfDay.statusName, status);
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

      test('a grouping class, without a structure: each half-day carries the '
          "name of its status, which the codes of the structure of the pupil's "
          'official class give too (#126)', () async {
        final mark = attempts.requests.length;
        final groupingClasses = [
          for (final c in config.allowedClasses)
            if (c.structId == null && !c.isPlaceholder) c,
        ];
        // Seen 2026-10-05, with the absence-administrator rights on: 17
        // grouping classes, 6 of them naming the classes they group (such as
        // 2A), beside 103 official classes.
        print(
          'getConfig: ${groupingClasses.length} grouping classes, '
          '${groupingClasses.where((c) => c.downStreamGroupIds.isNotEmpty).length} '
          'naming the classes they group',
        );
        if (groupingClasses.isEmpty) {
          markTestSkipped('getConfig lists no grouping class to this account');
          return;
        }

        // An official class groups none; the classes a grouping class names
        // are official classes, when getConfig lists them.
        for (final c in config.allowedClasses) {
          if (c.structId != null) {
            expect(c.downStreamGroupIds, isEmpty, reason: '${c.groupId}');
          }
        }
        for (final c in groupingClasses) {
          for (final id in c.downStreamGroupIds) {
            final grouped = config.classForGroup(id);
            if (grouped != null) {
              expect(grouped.structId, isNotNull, reason: '$id');
            }
          }
        }

        // One that names the classes it groups when there is one.
        final grouping = groupingClasses.firstWhere(
          (c) => c.downStreamGroupIds.isNotEmpty,
          orElse: () => groupingClasses.first,
        );
        var halfDays = 0;
        var byOfficialClass = 0;
        final unresolved = <int?>{};
        // Back from yesterday to the last day with half-days, at most a week.
        for (var back = 1; back <= 7 && halfDays == 0; back++) {
          final pupils = await classPupils(
            grouping.groupId,
            day.subtract(Duration(days: back)),
          );
          for (final pupil in pupils) {
            final official = pupil.officialClassId == null
                ? null
                : config.classForGroup(pupil.officialClassId!);
            final structId = official?.structId;
            if (structId == null) unresolved.add(pupil.officialClassId);
            final codes = structId == null
                ? null
                : await presence.getAllCodes(structId);
            for (final halfDay in pupil.halfDays) {
              halfDays++;
              expect(
                halfDay.statusName,
                isNotNull,
                reason:
                    'a half-day of ${halfDay.presenceDate} in class '
                    '${grouping.groupId} (codeID ${halfDay.codeId}, aliasID '
                    '${halfDay.aliasId}) carries no name',
              );
              if (codes != null) {
                byOfficialClass++;
                expect(
                  PresenceService.statusNameOf(halfDay, codes),
                  halfDay.statusName,
                  reason:
                      'codeID ${halfDay.codeId}, aliasID ${halfDay.aliasId} '
                      'in getAllCodes($structId)',
                );
              }
            }
          }
        }
        print(
          'grouping class ${grouping.groupId} '
          '(${grouping.downStreamGroupIds.length} classes named): '
          '$halfDays half-days, $byOfficialClass named by the codes of the '
          "pupil's official class; official classes not resolved: "
          '${unresolved.length}',
        );

        expect(halfDays, greaterThan(0), reason: 'no half-day in a week');
        expect(grouping.structId, isNull);
        // Seen 2026-10-05 with the rights on (userCanConfirm): getConfig
        // listed the official class of every pupil of all seventeen grouping
        // classes. An account without them is listed fewer classes (#121).
        if (grouping.userCanConfirm) {
          expect(unresolved, isEmpty);
          expect(byOfficialClass, halfDays);
        }
        expect(attempts.presenceWritesSince(mark), isEmpty);
      });

      test('the module answered every read of the run with a 200, which '
          'the service reads as its answer (#143)', () {
        // The service refuses a JSON answer with a status outside 200-299
        // as an error (SmartschoolPresenceUnreadableAnswerError, kind
        // errorStatus): the module's own answers to its reads are not, a
        // class it does not know and a day it lists no pupils for included.
        expect(attempts.presenceAnswers, isNotEmpty);
        expect(
          attempts.presenceAnswers,
          everyElement(
            isA<(String, int?)>()
                .having(
                  (a) => a.$1,
                  'request',
                  anyOf(
                    'POST $_getConfig',
                    'POST $_getAllCodes',
                    'POST $_getClass',
                  ),
                )
                .having((a) => a.$2, 'statusCode', 200),
          ),
        );
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
