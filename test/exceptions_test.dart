import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:flutter_smartschool/src/models/lesson_content_models.dart'
    show
        LessonContentAttachment,
        LessonContentItem,
        LessonContentType,
        LessonContentVisibility;
import 'package:flutter_smartschool/src/models/message_models.dart'
    show BoxType;
import 'package:flutter_smartschool/src/models/planner_models.dart'
    show PlannedElement, PlannerAssignmentType, PlannerWriteRefusalReason;
import 'package:flutter_smartschool/src/models/presence_models.dart'
    show
        DayPart,
        PresenceClassRef,
        PresenceHalfDay,
        PresenceSaveError,
        PresenceUnreadableAnswerKind;
import 'package:flutter_smartschool/src/models/skore_gradebook_models.dart'
    show
        SkoreEvaluation,
        SkoreEvaluationResults,
        SkoreEvaluationType,
        SkorePublication,
        SkorePublicationState;
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

  group('SmartschoolPresenceNoConfirmRightError (#121)', () {
    test('is a SmartschoolPresenceError without server errors, not a session '
        'problem nor another refusal, and keeps the class', () {
      const classRef = PresenceClassRef(
        groupId: 298,
        name: '1A',
        structId: 311,
        userCanRecord: true,
      );
      const error = SmartschoolPresenceNoConfirmRightError(
        'no right',
        userId: 1001,
        classGroupId: 298,
        date: '2026-10-02',
        part: DayPart.morning,
        classRef: classRef,
      );
      expect(error, isA<SmartschoolPresenceError>());
      expect(error, isNot(isA<SmartschoolPresenceChangeRefusedError>()));
      expect(error, isNot(isA<SmartschoolPresencePupilNotFoundError>()));
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.errors, isEmpty);
      expect(error.saveErrors, isEmpty);
      expect(
        (error.userId, error.classGroupId, error.date, error.part),
        (1001, 298, '2026-10-02', DayPart.morning),
      );
      expect(error.classRef, same(classRef));
      expect(error.classRef.userCanConfirm, isFalse);
      expect(
        error.toString(),
        'SmartschoolPresenceNoConfirmRightError: no right',
      );
    });
  });

  group('SmartschoolPresenceUnreadableAnswerError (#137)', () {
    test('is a SmartschoolPresenceError without server errors, not a session '
        'problem nor another refusal, and keeps the answer', () {
      const error = SmartschoolPresenceUnreadableAnswerError(
        'Empty response from /Presence/Main/getConfig (HTTP 502).',
        path: '/Presence/Main/getConfig',
        kind: PresenceUnreadableAnswerKind.empty,
        statusCode: 502,
      );
      expect(error, isA<SmartschoolPresenceError>());
      expect(error, isNot(isA<SmartschoolPresenceChangeRefusedError>()));
      expect(error, isNot(isA<SmartschoolPresencePupilNotFoundError>()));
      expect(error, isNot(isA<SmartschoolPresenceNoConfirmRightError>()));
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.errors, isEmpty);
      expect(error.saveErrors, isEmpty);
      expect(
        (error.path, error.statusCode, error.kind),
        ('/Presence/Main/getConfig', 502, PresenceUnreadableAnswerKind.empty),
      );
      expect(error.title, isNull);
      expect(error.heading, isNull);
      expect(
        error.toString(),
        'SmartschoolPresenceUnreadableAnswerError: Empty response from '
        '/Presence/Main/getConfig (HTTP 502).',
      );
    });

    test('fromPage: the title and heading, read and masked as '
        'SmartschoolUnexpectedPageError reads them, and nothing else of the '
        'page in the message', () {
      final error = SmartschoolPresenceUnreadableAnswerError.fromPage(
        '<!DOCTYPE html><html><head><title>Fout voor jan.janssens@example.com'
        '</title><script>var user = "Jan Janssens";</script></head><body>'
        '<h1>Sessie <span>a1b2c3d4e5f6a7b8c9d0e1f2a3b4</span> verlopen</h1>'
        '<form><select><option>Peeters, Lotte</option></select></form>'
        '<p>Leerling Peeters, Lotte</p></body></html>',
        path: '/Presence/Class/savePupilsPresences',
        statusCode: 500,
      );

      expect(error.kind, PresenceUnreadableAnswerKind.html);
      expect(error.path, '/Presence/Class/savePupilsPresences');
      expect(error.statusCode, 500);
      expect(error.title, 'Fout voor [e-mail]');
      expect(error.heading, 'Sessie [token] verlopen');
      expect(
        error.message,
        'Smartschool answered /Presence/Class/savePupilsPresences with an HTML '
        'page instead of JSON (HTTP 500, title "Fout voor [e-mail]", heading '
        '"Sessie [token] verlopen").',
      );
      expect(error.toString(), isNot(contains('Janssens')));
      expect(error.toString(), isNot(contains('Peeters')));
    });

    test('fromPage: a page without title or heading, of an unknown '
        'status', () {
      final error = SmartschoolPresenceUnreadableAnswerError.fromPage(
        '<div>Fout</div>',
        path: '/Presence/Class/getClass',
      );

      expect(error.statusCode, isNull);
      expect(error.title, isNull);
      expect(error.heading, isNull);
      expect(
        error.message,
        'Smartschool answered /Presence/Class/getClass with an HTML page '
        'instead of JSON (status unknown).',
      );
    });

    test('fromPage: a long heading is cut off as for '
        'SmartschoolUnexpectedPageError', () {
      final long = 'Oeps ' * 40;
      final error = SmartschoolPresenceUnreadableAnswerError.fromPage(
        '<html><body><h2>$long</h2></body></html>',
        path: '/Presence/Main/getConfig',
        statusCode: 200,
      );

      expect(
        error.heading,
        '${long.substring(0, SmartschoolUnexpectedPageError.maxLabelLength)}'
        '...',
      );
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

    test('SmartschoolSkoreEvaluationCreateUnconfirmedError is a '
        'SmartschoolSkoreSaveUnconfirmedError, not a SmartschoolSkoreError, '
        'and carries the gradebook, the period, the title and the new ID '
        '(#150)', () {
      const cause = SmartschoolConnectionError('dropped');
      const error = SmartschoolSkoreEvaluationCreateUnconfirmedError(
        'unconfirmed',
        cause: cause,
        gradebookId: 32508,
        periodId: 1704,
        title: 'Toets 1',
      );
      expect(error, isA<SmartschoolSkoreSaveUnconfirmedError>());
      expect(error, isNot(isA<SmartschoolSkoreError>()));
      expect(error.cause, same(cause));
      expect(error.gradebookId, 32508);
      expect(error.periodId, 1704);
      expect(error.title, 'Toets 1');
      expect(error.evaluationId, isNull);
      expect(
        error.toString(),
        'SmartschoolSkoreEvaluationCreateUnconfirmedError: unconfirmed',
      );
      const answered = SmartschoolSkoreEvaluationCreateUnconfirmedError(
        'unconfirmed',
        gradebookId: 32508,
        periodId: 1704,
        title: 'Toets 1',
        evaluationId: 500003,
      );
      expect(answered.evaluationId, 500003);
      expect(answered.cause, isNull);
    });

    test('SmartschoolSkoreEvaluationPublicError is neither a '
        'SmartschoolSkoreError nor unconfirmed: the evaluation was created '
        '(#150)', () {
      final evaluation = SkoreEvaluation(
        id: 500003,
        evaluationId: 500003,
        gradebookId: 32508,
        periodId: 1704,
        column: 'A',
        title: 'Toets 1',
        shortName: null,
        date: DateTime(2026, 10, 8),
        max: 20,
        componentId: 2,
        componentName: 'DW',
        type: SkoreEvaluationType.points,
        typeCode: 1,
        courseId: 2264,
        courseName: 'Informaticawetenschappen (2 uur)',
        isPlannerEvaluation: false,
        publication: const SkorePublication(
          state: SkorePublicationState.published,
          at: null,
          rawPublic: '1',
          rawPublicDateTime: '',
        ),
        results: const SkoreEvaluationResults(evaluationId: 500003),
      );
      final error = SmartschoolSkoreEvaluationPublicError(
        'public',
        evaluation: evaluation,
      );
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolSkoreError>()));
      expect(error, isNot(isA<SmartschoolSkoreSaveUnconfirmedError>()));
      expect(error.evaluation, same(evaluation));
      expect(error.toString(), 'SmartschoolSkoreEvaluationPublicError: public');
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

    test('SmartschoolLessonContentNotFoundError and '
        'SmartschoolLessonContentWriteRefusedError are '
        'SmartschoolLessonContentErrors (nothing was changed), with their '
        'status (#129)', () {
      const missing = SmartschoolLessonContentNotFoundError(
        'no such lesfiche',
        type: LessonContentType.assignment,
        id: 'b0000000-0000-4000-8000-000000000001',
      );
      expect(missing, isA<SmartschoolLessonContentError>());
      expect(missing.statusCode, 404);
      expect(missing.type, LessonContentType.assignment);
      expect(missing.id, 'b0000000-0000-4000-8000-000000000001');
      expect(
        missing.toString(),
        'SmartschoolLessonContentNotFoundError(404): no such lesfiche',
      );

      const refused = SmartschoolLessonContentWriteRefusedError(
        'refused',
        statusCode: 400,
      );
      expect(refused, isA<SmartschoolLessonContentError>());
      expect(refused, isNot(isA<SmartschoolAuthenticationError>()));
      expect(refused.statusCode, 400);
      expect(refused.violations, isEmpty);
      expect(
        refused.toString(),
        'SmartschoolLessonContentWriteRefusedError(400): refused',
      );
      expect(
        const SmartschoolLessonContentWriteRefusedError(
          'refused',
          statusCode: 422,
          violations: ['Naam is verplicht.'],
        ).violations,
        ['Naam is verplicht.'],
      );
    });

    test('SmartschoolLessonContentSaveUnconfirmedError is not a '
        'SmartschoolLessonContentError (it may have been changed), and keeps '
        'its status, cause and lesfiche ID (#129)', () {
      const cause = SmartschoolConnectionError('reset');
      const error = SmartschoolLessonContentSaveUnconfirmedError(
        'unconfirmed',
        cause: cause,
        lessonContentId: 'b0000000-0000-4000-8000-000000000001',
      );
      expect(error, isA<SmartschoolException>());
      expect(error, isNot(isA<SmartschoolLessonContentError>()));
      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(error.statusCode, isNull);
      expect(error.cause, same(cause));
      expect(error.lessonContentId, 'b0000000-0000-4000-8000-000000000001');
      expect(
        error.toString(),
        'SmartschoolLessonContentSaveUnconfirmedError: unconfirmed',
      );
      expect(
        const SmartschoolLessonContentSaveUnconfirmedError(
          'unconfirmed',
          statusCode: 500,
        ).toString(),
        'SmartschoolLessonContentSaveUnconfirmedError(500): unconfirmed',
      );
    });

    test('SmartschoolLessonContentVisibilityNotSetError is a '
        'SmartschoolLessonContentSaveUnconfirmedError, not a '
        'SmartschoolLessonContentError, and keeps the attachments made, the '
        'one whose visibility failed and the visibilities not set (#135)', () {
      const lesson = 'b0000000-0000-4000-8000-000000000001';
      const set = LessonContentAttachment(
        id: 'f0000000-0000-4000-8000-000000000001',
        fileName: 'a.txt',
        visibility: LessonContentVisibility.never,
      );
      const failed = LessonContentAttachment(
        id: 'f0000000-0000-4000-8000-000000000002',
        fileName: 'b.txt',
      );
      const cause = SmartschoolLessonContentWriteRefusedError(
        'refused',
        statusCode: 400,
      );
      const error = SmartschoolLessonContentVisibilityNotSetError(
        'the files were added',
        cause: cause,
        lessonContentId: lesson,
        addedAttachments: [set, failed],
        attachment: failed,
        visibility: LessonContentVisibility.atEnd,
        visibilitiesNotSet: {
          'f0000000-0000-4000-8000-000000000002': LessonContentVisibility.atEnd,
        },
      );
      expect(error, isA<SmartschoolLessonContentSaveUnconfirmedError>());
      expect(error, isNot(isA<SmartschoolLessonContentError>()));
      expect(error.statusCode, isNull);
      expect(error.cause, same(cause));
      expect(error.lessonContentId, lesson);
      expect(error.addedAttachments, [same(set), same(failed)]);
      expect(error.attachment, same(failed));
      expect(error.attachment.visibility, LessonContentVisibility.always);
      expect(error.visibility, LessonContentVisibility.atEnd);
      expect(error.visibilitiesNotSet, {
        failed.id: LessonContentVisibility.atEnd,
      });
      expect(
        error.toString(),
        'SmartschoolLessonContentVisibilityNotSetError: the files were added',
      );

      // A catch of the type it extends catches it.
      Object? caught;
      try {
        throw error;
      } on SmartschoolLessonContentSaveUnconfirmedError catch (e) {
        caught = e;
      }
      expect(caught, same(error));
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
