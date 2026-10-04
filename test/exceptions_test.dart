import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/lesson_content_models.dart'
    show LessonContentItem;
import 'package:flutter_smartschool/src/models/message_models.dart'
    show BoxType;
import 'package:flutter_smartschool/src/models/planner_models.dart'
    show PlannedElement, PlannerAssignmentType, PlannerWriteRefusalReason;
import 'package:flutter_smartschool/src/models/presence_models.dart'
    show DayPart, PresenceHalfDay, PresenceSaveError;
import 'package:flutter_smartschool/src/models/skore_models.dart'
    show
        SkoreAccessArea,
        SkoreAssignment,
        SkoreCourse,
        SkoreGradebookShares,
        SkoreShareAccess,
        SkoreTeacher;
import 'package:test/test.dart';

import 'support/no_network.dart';

void main() {
  forbidRealNetwork();

  group('SmartschoolParsingError', () {
    test('toString returns message', () {
      final err = SmartschoolParsingError('fail');
      expect(err.toString(), contains('fail'));
    });
  });

  group('login failure types (#11)', () {
    // Default instances, paired with the wording the untyped error used to
    // carry: callers that still match on the message keep working.
    final legacyWording = <SmartschoolAuthenticationError, String>{
      const SmartschoolInvalidCredentialsError(): 'Login failed.',
      const SmartschoolTwoFactorRequiredError(): '2FA requires a TOTP secret',
      const SmartschoolTwoFactorRejectedError(): '2FA verification failed.',
      const SmartschoolUnsupportedTwoFactorMethodError([]):
          'Only googleAuthenticator 2FA is supported',
      const SmartschoolAccountVerificationRequiredError():
          'account-verification requires mfa',
      const SmartschoolAccountVerificationRejectedError():
          'Account verification is still pending.',
    };

    for (final MapEntry(key: error, value: wording) in legacyWording.entries) {
      test('${error.runtimeType} is a SmartschoolAuthenticationError', () {
        // A catch of the base class (or of SmartschoolException) still
        // catches the new type.
        expect(error, isA<SmartschoolAuthenticationError>());
        expect(error, isA<SmartschoolException>());
      });

      test('${error.runtimeType} keeps the legacy message by default', () {
        expect(error.message, startsWith(wording));
      });
    }

    test('a custom message replaces the default', () {
      const error = SmartschoolAccountVerificationRequiredError('custom');
      expect(error.message, 'custom');
      expect(
        error.toString(),
        'SmartschoolAccountVerificationRequiredError: custom',
      );
    });

    test('SmartschoolUnsupportedTwoFactorMethodError lists the methods the '
        'account offers', () {
      const error = SmartschoolUnsupportedTwoFactorMethodError(['sms', 'mail']);
      expect(error.availableMethods, ['sms', 'mail']);
      expect(error.toString(), endsWith('(account offers: sms, mail)'));
    });

    test('SmartschoolInvalidTotpSecretError is a login failure that points at '
        'the key (#79)', () {
      // A catch of the base class still catches it; the default message
      // tells the key from the code of the app.
      const error = SmartschoolInvalidTotpSecretError();
      expect(error, isA<SmartschoolAuthenticationError>());
      expect(error, isNot(isA<SmartschoolTwoFactorRejectedError>()));
      expect(
        error.message,
        allOf(contains('not a Base32 key'), contains('not the 6-digit code')),
      );
    });

    test('SmartschoolUnsupportedTwoFactorMethodError without methods prints '
        'only the message', () {
      const error = SmartschoolUnsupportedTwoFactorMethodError([]);
      expect(
        error.toString(),
        'SmartschoolUnsupportedTwoFactorMethodError: '
        'Only googleAuthenticator 2FA is supported',
      );
    });
  });

  test('SmartschoolPagingRestartedError is a SmartschoolException, not a '
      'session error (#76)', () {
    // The session was accepted: a catch meant for signing in again must not
    // catch a restarted paging.
    const error = SmartschoolPagingRestartedError('restarted');
    expect(error, isA<SmartschoolException>());
    expect(error, isNot(isA<SmartschoolAuthenticationError>()));
  });

  group('SmartschoolConnectionError (#10)', () {
    test('is a SmartschoolException, not a SmartschoolAuthenticationError', () {
      // A network problem must not be caught as a failed login.
      const error = SmartschoolConnectionError('unreachable');
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
    });

    test('carries its cause', () {
      final cause = Exception('socket');
      final error = SmartschoolConnectionError('unreachable', cause: cause);
      expect(error.cause, same(cause));
      expect(error.toString(), 'SmartschoolConnectionError: unreachable');
    });
  });

  group('SmartschoolSessionExpiredError (#5)', () {
    test('is a SmartschoolAuthenticationError, not a '
        'SmartschoolPresenceError', () {
      // "Sign in again" and "give up" must not share a type.
      const error = SmartschoolSessionExpiredError();
      expect(error, isA<SmartschoolAuthenticationError>());
      expect(error, isNot(isA<SmartschoolPresenceError>()));
      expect(
        error.toString(),
        'SmartschoolSessionExpiredError: '
        'Smartschool did not accept the session.',
      );
    });
  });

  group('SmartschoolMoveUncheckedError (#115)', () {
    test('is not a SmartschoolAuthenticationError, whatever its cause, and '
        'carries the move and the cause', () {
      // "The move went out" must not share a type with "Smartschool refused
      // the session for the move": a caller sends the call again on the
      // latter.
      const cause = SmartschoolSessionExpiredError();
      const error = SmartschoolMoveUncheckedError(
        'unchecked',
        msgId: 4242,
        boxType: BoxType.inbox,
        boxId: 208,
        cause: cause,
      );
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.msgId, 4242);
      expect(error.boxType, BoxType.inbox);
      expect(error.boxId, 208);
      expect(error.cause, same(cause));
      expect(error.toString(), 'SmartschoolMoveUncheckedError: unchecked');
    });

    test('a move out of the box itself: folder 0', () {
      const error = SmartschoolMoveUncheckedError(
        'unchecked',
        msgId: 1,
        boxType: BoxType.sent,
        cause: SmartschoolParsingError('empty'),
      );
      expect(error.boxId, 0);
    });
  });

  group('SmartschoolPresenceError of a refused save (#109)', () {
    test('keeps the typed errors; its text shows their messages, without the '
        "pupil's name", () {
      const saveError = PresenceSaveError(
        message: 'De afwezigheid kon niet worden opgeslagen.',
        userId: 1001,
        date: '2026-06-01',
        part: DayPart.morning,
        pupilName: 'Peeters, Lotte',
      );
      const error = SmartschoolPresenceError(
        'Saving the presence for userID 1001 failed.',
        errors: ['De afwezigheid kon niet worden opgeslagen.'],
        saveErrors: [saveError],
      );
      expect(error.saveErrors.single, same(saveError));
      expect(
        error.toString(),
        'SmartschoolPresenceError: Saving the presence for userID 1001 '
        'failed. (De afwezigheid kon niet worden opgeslagen.)',
      );
      expect(
        saveError.toString(),
        'PresenceSaveError: De afwezigheid kon niet worden opgeslagen. '
        '(2026-06-01, morning, userID 1001)',
      );
      expect('$error$saveError', isNot(contains('Peeters')));
      expect('$error$saveError', isNot(contains('Lotte')));
    });

    test('made without errors: both empty; an error without a record shows '
        'its message only', () {
      const error = SmartschoolPresenceError('failed');
      expect(error.errors, isEmpty);
      expect(error.saveErrors, isEmpty);
      expect(error.toString(), 'SmartschoolPresenceError: failed');
      expect(
        const PresenceSaveError(message: 'geen rechten').toString(),
        'PresenceSaveError: geen rechten',
      );
    });
  });

  group('SmartschoolPresenceChangeRefusedError (#105)', () {
    test('is a SmartschoolPresenceError without server errors, not a session '
        'problem, and keeps what the half-day held', () {
      const halfDay = PresenceHalfDay(
        presenceId: 90005,
        presenceDate: '2026-06-01',
        part: DayPart.morning,
        codeId: 479,
        aliasId: null,
        motivation: '',
      );
      const error = SmartschoolPresenceChangeRefusedError(
        'holds "Doktersattest"',
        userId: 1003,
        part: DayPart.morning,
        date: '2026-06-01',
        halfDay: halfDay,
        heldStatus: 'Doktersattest',
        onlyReplacing: {'Aanwezig'},
      );
      expect(error, isA<SmartschoolPresenceError>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.errors, isEmpty);
      expect(error.saveErrors, isEmpty);
      expect(
        (error.userId, error.part, error.date),
        (1003, DayPart.morning, '2026-06-01'),
      );
      expect(error.halfDay, same(halfDay));
      expect(error.heldStatus, 'Doktersattest');
      expect(error.onlyReplacing, {'Aanwezig'});
      expect(
        error.toString(),
        'SmartschoolPresenceChangeRefusedError: holds "Doktersattest"',
      );
    });

    test('made without a half-day, status or set: null, null and empty', () {
      const error = SmartschoolPresenceChangeRefusedError(
        'refused',
        userId: 1,
        part: DayPart.afternoon,
        date: '2026-06-01',
      );
      expect(error.halfDay, isNull);
      expect(error.heldStatus, isNull);
      expect(error.onlyReplacing, isEmpty);
    });
  });

  group('SmartschoolPresencePupilNotFoundError (#116)', () {
    test('is a SmartschoolPresenceError without server errors, not a session '
        'problem nor a refusal of onlyReplacing, and keeps the read', () {
      const error = SmartschoolPresencePupilNotFoundError(
        'not listed',
        userId: 1001,
        classGroupId: 298,
        date: '2026-11-03',
        saveIsAllowed: false,
        errorMessage: 'Deze klas bevat geen leerlingen.',
      );
      expect(error, isA<SmartschoolPresenceError>());
      expect(error, isNot(isA<SmartschoolPresenceChangeRefusedError>()));
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.errors, isEmpty);
      expect(error.saveErrors, isEmpty);
      expect(
        (error.userId, error.classGroupId, error.date),
        (1001, 298, '2026-11-03'),
      );
      expect(error.saveIsAllowed, isFalse);
      expect(error.errorMessage, 'Deze klas bevat geen leerlingen.');
      expect(
        error.toString(),
        'SmartschoolPresencePupilNotFoundError: not listed',
      );
    });

    test('made without what the module said: both null', () {
      const error = SmartschoolPresencePupilNotFoundError(
        'not listed',
        userId: 1,
        classGroupId: 2,
        date: '2026-06-01',
      );
      expect(error.saveIsAllowed, isNull);
      expect(error.errorMessage, isNull);
    });
  });

  group('Skore write errors (#71)', () {
    test('SmartschoolSkoreMyGroupsError is a SmartschoolSkoreError: nothing '
        'was saved', () {
      const error = SmartschoolSkoreMyGroupsError(
        'groups',
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
      );
      expect(error, isA<SmartschoolSkoreError>());
      expect(error.classId, 2516);
      expect(error.courseId, 1588);
      expect(error.teacherId, 1005);
      // Made without a name, as before #102.
      expect(error.teacherName, isNull);
      expect(error.toString(), 'SmartschoolSkoreMyGroupsError: groups');
    });

    test('SmartschoolSkoreMyGroupsError carries the name of the current '
        'teacher (#102)', () {
      const error = SmartschoolSkoreMyGroupsError(
        'groups',
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
        teacherName: 'Willems, Wim',
      );
      expect(error.teacherId, 1005);
      expect(error.teacherName, 'Willems, Wim');
      expect(error.toString(), 'SmartschoolSkoreMyGroupsError: groups');
    });

    test('SmartschoolSkoreMyGroupsError is a refused change (#83)', () {
      const error = SmartschoolSkoreMyGroupsError(
        'groups',
        classId: 2516,
        courseId: 1588,
        teacherId: 1005,
      );
      expect(error, isA<SmartschoolSkoreChangeRefusedError>());
      expect(error, isNot(isA<SmartschoolSkoreAccessDeniedError>()));
    });

    test('SmartschoolSkoreSaveUnconfirmedError is not a SmartschoolSkoreError '
        'and carries its cause', () {
      // "Nothing was saved" and "may have been saved" must not share a type.
      const cause = SmartschoolConnectionError('dropped');
      const error = SmartschoolSkoreSaveUnconfirmedError(
        'unconfirmed',
        cause: cause,
      );
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolSkoreError>()));
      expect(error.cause, same(cause));
      expect(
        error.toString(),
        'SmartschoolSkoreSaveUnconfirmedError: unconfirmed',
      );
    });

    test('SmartschoolSkoreAssignmentSaveUnconfirmedError is a '
        'SmartschoolSkoreSaveUnconfirmedError, not a SmartschoolSkoreError, '
        'and carries the course, the replaced assignment and the teacher '
        '(#120)', () {
      const cause = SmartschoolConnectionError('dropped');
      const replaced = SkoreAssignment(
        id: 34826,
        teacherId: 1005,
        teacherName: 'Willems, Wim',
      );
      const course = SkoreCourse(
        id: 1588,
        classId: 2516,
        name: 'Digitale vaardigheden',
        label: 'Digitale vaardigheden  [Digitale vaardigheden]',
        code: 'Digitale vaardigheden',
        isGroupHeader: false,
        depth: 1,
        assignments: [replaced],
      );
      const teacher = SkoreTeacher(id: 1006, name: 'Maes, Mieke');
      const error = SmartschoolSkoreAssignmentSaveUnconfirmedError(
        'unconfirmed',
        cause: cause,
        course: course,
        replaced: replaced,
        teacher: teacher,
      );
      expect(error, isA<SmartschoolSkoreSaveUnconfirmedError>());
      expect(error, isNot(isA<SmartschoolSkoreError>()));
      expect(error.cause, same(cause));
      expect(error.course, same(course));
      expect(error.replaced, same(replaced));
      expect(error.teacher, same(teacher));
      expect(
        error.toString(),
        'SmartschoolSkoreAssignmentSaveUnconfirmedError: unconfirmed',
      );

      // An add replaces nothing, and an answer that does not confirm the save
      // has no cause.
      const add = SmartschoolSkoreAssignmentSaveUnconfirmedError(
        'unconfirmed',
        course: course,
        teacher: teacher,
      );
      expect(add.replaced, isNull);
      expect(add.cause, isNull);
    });

    test('SmartschoolSkoreShareSaveUnconfirmedError is a '
        'SmartschoolSkoreSaveUnconfirmedError, not a SmartschoolSkoreError, '
        'and carries the gradebook before and the teacher, with the access '
        'they had (#120)', () {
      const before = SkoreGradebookShares(
        gradebookId: 31886,
        ownerId: 1005,
        className: '5WW1',
        courseName: 'Esthetica (1 uur)',
        icon: 'palette2',
        readerIds: [1001],
        writerIds: [1003],
      );
      const error = SmartschoolSkoreShareSaveUnconfirmedError(
        'unconfirmed',
        before: before,
        teacherId: 1001,
      );
      expect(error, isA<SmartschoolSkoreSaveUnconfirmedError>());
      expect(error, isNot(isA<SmartschoolSkoreError>()));
      expect(error.cause, isNull);
      expect(error.before, same(before));
      expect(error.teacherId, 1001);
      expect(error.accessBefore, SkoreShareAccess.read);
      expect(
        error.toString(),
        'SmartschoolSkoreShareSaveUnconfirmedError: unconfirmed',
      );

      const writer = SmartschoolSkoreShareSaveUnconfirmedError(
        'unconfirmed',
        before: before,
        teacherId: 1003,
      );
      expect(writer.accessBefore, SkoreShareAccess.write);
      const none = SmartschoolSkoreShareSaveUnconfirmedError(
        'unconfirmed',
        before: before,
        teacherId: 1007,
      );
      expect(none.accessBefore, isNull);
    });
  });

  group('Skore errors a caller tells apart (#83)', () {
    test('SmartschoolSkoreAccessDeniedError is a SmartschoolSkoreError, not a '
        'session problem or a refused change, and names the part of Skore', () {
      const error = SmartschoolSkoreAccessDeniedError(
        'no rights',
        area: SkoreAccessArea.gradebookManagement,
      );
      expect(error, isA<SmartschoolSkoreError>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error, isNot(isA<SmartschoolSkoreChangeRefusedError>()));
      expect(error.area, SkoreAccessArea.gradebookManagement);
      expect(
        error.toString(),
        'SmartschoolSkoreAccessDeniedError(gradebookManagement): no rights',
      );
    });

    test('SmartschoolSkoreChangeRefusedError is a SmartschoolSkoreError, not '
        'a missing right', () {
      const error = SmartschoolSkoreChangeRefusedError('group header');
      expect(error, isA<SmartschoolSkoreError>());
      expect(error, isNot(isA<SmartschoolSkoreAccessDeniedError>()));
      expect(
        error.toString(),
        'SmartschoolSkoreChangeRefusedError: group header',
      );
    });
  });

  group('planner errors (#84)', () {
    test('SmartschoolPlannerError is a SmartschoolException, not a session '
        'problem, and shows its status when it has one', () {
      const error = SmartschoolPlannerError('refused', statusCode: 400);
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.statusCode, 400);
      expect(error.toString(), 'SmartschoolPlannerError(400): refused');
      expect(
        const SmartschoolPlannerError('unknown shape').toString(),
        'SmartschoolPlannerError: unknown shape',
      );
    });

    test('SmartschoolPlannedElementNotFoundError is a SmartschoolPlannerError '
        'with status 404 and names the element', () {
      const error = SmartschoolPlannedElementNotFoundError(
        'gone',
        elementType: 'planned-lessons',
        platformId: 4069,
        elementId: 'e0000000-0000-4000-8000-000000000002',
      );
      expect(error, isA<SmartschoolPlannerError>());
      expect(error.statusCode, 404);
      expect(error.elementType, 'planned-lessons');
      expect(error.platformId, 4069);
      expect(error.elementId, 'e0000000-0000-4000-8000-000000000002');
      expect(
        error.toString(),
        'SmartschoolPlannedElementNotFoundError(404): gone',
      );
    });
  });

  group('planner write errors (#87)', () {
    test('SmartschoolPlannerWriteRefusedError is a SmartschoolPlannerError '
        'without a status: nothing was sent', () {
      const error = SmartschoolPlannerWriteRefusedError('not your slot');
      expect(error, isA<SmartschoolPlannerError>());
      expect(error, isNot(isA<SmartschoolPlannedElementNotFoundError>()));
      expect(error.statusCode, isNull);
      expect(
        error.toString(),
        'SmartschoolPlannerWriteRefusedError: not your slot',
      );
    });

    test('SmartschoolPlannerWriteRefusedError made without a reason has none '
        '(#100): no reason, element, flags or lesfiche', () {
      // The constructor of 0.3.2 still works: the new fields are optional.
      const error = SmartschoolPlannerWriteRefusedError('not your slot');
      expect(error.reason, isNull);
      expect(error.element, isNull);
      expect(error.capabilityFlags, isEmpty);
      expect(error.lessonContent, isNull);
      expect(error.assignmentTypes, isEmpty);
    });

    test('SmartschoolPlannerWriteRefusedError carries its reason, element and '
        'flags, and shows the reason (#100)', () {
      final slot = PlannedElement.fromJson({
        'id': 'e0000000-0000-5000-8000-000000000001',
        'platformId': 4069,
        'plannedElementType': 'planned-placeholders',
        'period': {
          'dateTimeFrom': '2026-11-20T11:10:00+01:00',
          'dateTimeTo': '2026-11-20T12:00:00+01:00',
        },
      });
      final error = SmartschoolPlannerWriteRefusedError(
        'cannot fill it',
        reason: PlannerWriteRefusalReason.notAllowed,
        element: slot,
        capabilityFlags: const ['canUserReplace'],
      );
      expect(error, isA<SmartschoolPlannerError>());
      expect(error.statusCode, isNull);
      expect(error.reason, PlannerWriteRefusalReason.notAllowed);
      expect(error.element, same(slot));
      expect(error.capabilityFlags, ['canUserReplace']);
      expect(error.lessonContent, isNull);
      expect(error.message, 'cannot fill it');
      expect(
        error.toString(),
        'SmartschoolPlannerWriteRefusedError(notAllowed): cannot fill it',
      );
    });

    test('SmartschoolPlannerWriteRefusedError carries the school\'s '
        'assignment types for an unknown one, and does not show them '
        '(#119)', () {
      const types = [
        PlannerAssignmentType(
          id: 'a0000000-0000-4000-8000-000000000001',
          platformId: 4069,
          name: 'Kleine Overhoring',
          abbreviation: 'KO',
        ),
        PlannerAssignmentType(
          id: 'a0000000-0000-4000-8000-000000000002',
          platformId: 4069,
          name: 'Grote Overhoring',
          abbreviation: 'GO',
        ),
      ];
      const error = SmartschoolPlannerWriteRefusedError(
        'not a type of the school',
        reason: PlannerWriteRefusalReason.unknownAssignmentType,
        assignmentTypes: types,
      );
      expect(error, isA<SmartschoolPlannerError>());
      expect(error.assignmentTypes, same(types));
      expect(error.element, isNull);
      expect(error.capabilityFlags, isEmpty);
      expect(error.lessonContent, isNull);
      expect(
        error.toString(),
        'SmartschoolPlannerWriteRefusedError(unknownAssignmentType): '
        'not a type of the school',
      );
    });

    test('PlannerWriteRefusalReason has the reasons of the issue (#100)', () {
      expect(PlannerWriteRefusalReason.values.map((r) => r.name), [
        'notOwn',
        'notAllowed',
        'noLongerASlot',
        'periodChanged',
        'participantRoles',
        'trashable',
        'unknownLessonContent',
        'notALessonLessonContent',
        'unknownAssignmentType',
        'linkedEvaluation',
      ]);
    });

    test('SmartschoolPlannerSaveUnconfirmedError is not a '
        'SmartschoolPlannerError and carries its status and cause', () {
      // "Nothing was sent" and "may have been changed" must not share a type.
      const cause = SmartschoolConnectionError('dropped');
      const dropped = SmartschoolPlannerSaveUnconfirmedError(
        'unconfirmed',
        cause: cause,
      );
      expect(dropped, isA<SmartschoolException>());
      expect(dropped, isNot(isA<SmartschoolPlannerError>()));
      expect(dropped.cause, same(cause));
      expect(dropped.statusCode, isNull);
      expect(
        dropped.toString(),
        'SmartschoolPlannerSaveUnconfirmedError: unconfirmed',
      );

      const answered = SmartschoolPlannerSaveUnconfirmedError(
        'unconfirmed',
        statusCode: 500,
      );
      expect(answered.statusCode, 500);
      expect(answered.cause, isNull);
      expect(
        answered.toString(),
        'SmartschoolPlannerSaveUnconfirmedError(500): unconfirmed',
      );
    });
  });

  group('lesson content errors (#88)', () {
    test('SmartschoolLessonContentError is a SmartschoolException, not a '
        'session problem nor a planner error, and shows its status when it '
        'has one', () {
      const error = SmartschoolLessonContentError('refused', statusCode: 500);
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error, isNot(isA<SmartschoolPlannerError>()));
      expect(error.statusCode, 500);
      expect(error.toString(), 'SmartschoolLessonContentError(500): refused');
      expect(
        const SmartschoolLessonContentError('unknown shape').toString(),
        'SmartschoolLessonContentError: unknown shape',
      );
    });

    test('SmartschoolLessonContentCourseListError is a '
        'SmartschoolLessonContentError that keeps the lesfiches read, and '
        'shows its status but not the lesfiches (#118)', () {
      final fiche = LessonContentItem.fromJson(const {
        'id': 'b0000000-0000-4000-8000-000000000001',
        'platformId': 4069,
        'type': 'lessons',
        'name': 'Herhaling: lussen',
      });
      final error = SmartschoolLessonContentCourseListError(
        'The course list answered the courses with HTTP 500: Oeps',
        statusCode: 500,
        items: [fiche],
      );
      expect(error, isA<SmartschoolLessonContentError>());
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error, isNot(isA<SmartschoolPlannerError>()));
      expect(error.statusCode, 500);
      expect(error.items, [fiche]);
      expect(
        error.toString(),
        'SmartschoolLessonContentCourseListError(500): The course list '
        'answered the courses with HTTP 500: Oeps',
      );
      expect(
        const SmartschoolLessonContentCourseListError(
          'invalid JSON',
          items: [],
        ).toString(),
        'SmartschoolLessonContentCourseListError: invalid JSON',
      );
    });
  });

  group('SmartschoolClientDisposedError (#73)', () {
    const message = 'SmartschoolClient was disposed: it sends no more requests';

    test('is a StateError, not a SmartschoolException', () {
      // A mistake of the caller, not a problem of Smartschool or the network
      // (#54): code that retries on a SmartschoolException must not catch it.
      final Object error = SmartschoolClientDisposedError(message);
      expect(error, isA<StateError>());
      expect(error, isNot(isA<SmartschoolException>()));
    });

    test('an on StateError clause still catches it, as before #73', () {
      Object? caught;
      try {
        throw SmartschoolClientDisposedError(message);
      } on StateError catch (e) {
        caught = e;
      }
      expect(caught, isA<SmartschoolClientDisposedError>());
    });

    test('keeps the message and the text of the plain StateError', () {
      final error = SmartschoolClientDisposedError(message);
      expect(error.message, message);
      expect(error.toString(), 'Bad state: $message');
    });
  });
}
