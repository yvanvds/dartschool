import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../exceptions.dart';
import '../models/skore_gradebook_models.dart';
import '../session.dart';
import 'skore_rpc.dart';

export '../models/skore_gradebook_models.dart';

/// Reads Skore's gradebook **as the logged-in teacher** (#148): the teacher's
/// own gradebooks of a school year ([getGradebooks], [getGradebookYear]),
/// the periods and pupils of one gradebook, with whether the teacher may
/// change it ([getGradebook]), and the evaluations of a period with whether
/// and when they are published and the pupils' grades ([getEvaluations],
/// [getResults]) and feedback ([getFeedback], #149). And creates an
/// evaluation in a period, never published ([createEvaluation], #150), saves
/// the pupils' grades in it ([saveGrade], [saveGrades], #151), and gives a
/// pupil feedback on it ([saveFeedback], #152).
///
/// This is what a teacher sees at `/SkoreGradebook` ("Puntenboek"), and it
/// works for any teacher with their own login: it needs none of the admin
/// rights of `SkoreService`, which is the admin side of Skore (report
/// models, assignments, sharing gradebooks).
///
/// ```dart
/// final gradebooks = SkoreGradebookService(client);
///
/// final books = await gradebooks.getGradebooks(); // the current school year
/// for (final book in books) {
///   print('${book.className}: ${book.courseName} (${book.gradebookId})');
/// }
/// final sheet = await gradebooks.getGradebook(books.first);
/// for (final period in sheet.periods) {
///   print('${period.name}: ${period.isOpen ? 'open' : 'closed'}, '
///       'closes ${period.closesAt}');
/// }
/// for (final pupil in sheet.pupils) {
///   print('${pupil.number}. ${pupil.name}');
/// }
/// final evaluations =
///     await gradebooks.getEvaluations(books.first, sheet.activePeriod!.id);
/// for (final evaluation in evaluations) {
///   print('${evaluation.title}: ${evaluation.publication.state.name}');
///   for (final grade in evaluation.results.grades) {
///     print('  ${grade.pupilId}: ${grade.grade ?? '-'}');
///   }
/// }
/// ```
///
/// The only changes it makes in Skore are [createEvaluation], the grades
/// of [saveGrade] and [saveGrades], and the user's own feedback of
/// [saveFeedback], which check the gradebook, the period, the evaluation and
/// the values first, and read Skore again to check the save. **It never
/// publishes**: a new evaluation goes out unpublished, and teachers publish
/// it in Smartschool themselves; grades and feedback go into an evaluation
/// that is published or scheduled only when the caller asks for it
/// (`allowPublished`). Nothing in the service publishes, deletes or moves an
/// evaluation, nor deletes or changes another teacher's feedback.
///
/// ### The endpoint
/// Every call is an RPC call to Skore's gradebook service
/// (`POST /modules/Skore/backend/gradebook/rpc.php`), with the session object
/// of Skore's web client: `teacher` (the logged-in user's ID), `restriction`
/// (`0`: the own gradebooks) and `wy`, the ID of the school year, which
/// switches Skore to that year (seen live). `wy` goes with every call about
/// a gradebook (its [SkoreGradebook.workyearId]; for the current school
/// year Skore answered the same as without it, seen live) and with
/// [getGradebookYear] for a school year asked for; without it, Skore answers
/// for its current school year. The calls work straight after a login: no
/// page needs to be loaded first (seen live). That service also deletes,
/// moves, publishes and shares evaluations: the service only calls the
/// methods in [rpcMethods], and refuses any other before anything is sent
/// ([checkRpcMethod]). Feedback comes from Skore's REST API instead
/// (`GET /skore/api/v1/gradebook/feedback/...`), as the feedback panel of
/// Skore's gradebook reads it ([getFeedback]), and goes there with a `POST`
/// ([saveFeedback]); the service sends no other request to that API.
///
/// ### Errors
/// - [SmartschoolSkoreError]: Skore answered with something the service
///   cannot use: another HTTP status than `200` (also a redirect), an HTML
///   page instead of data, invalid JSON, an RPC answer without its `result`,
///   or data in a shape it does not recognise (such as a tree without its
///   lists, a non-numeric ID, a grade cell without its `raw`, or an answer
///   about another gradebook, period, school year or pupil). Never an empty
///   list instead. For the feedback, its message names the `title` and
///   `detail` of Skore's error answer, when it has them. The session was
///   accepted: signing in again does not help.
///   Its message may quote the answer, which can hold names: keep it in a
///   log. What Skore answers an account without a gradebook of its own (a
///   pupil, say) was not captured.
///   From [createEvaluation], [saveGrade], [saveGrades] and [saveFeedback],
///   it always means that nothing was saved; from [saveFeedback] also when
///   Skore refused the save with a `4xx` status.
/// - [SmartschoolSkoreChangeRefusedError] (a [SmartschoolSkoreError]): a
///   check of [createEvaluation], [saveGrade], [saveGrades] or
///   [saveFeedback] refused the change before the save. Nothing was saved;
///   its message says why.
/// - [SmartschoolSkoreEvaluationCreateUnconfirmedError] (a
///   [SmartschoolSkoreSaveUnconfirmedError], not a [SmartschoolSkoreError]):
///   [createEvaluation] sent the save, but could not confirm it. The
///   evaluation may or may not have been created: read the period again.
/// - [SmartschoolSkoreGradeSaveUnconfirmedError] (the same): [saveGrade] or
///   [saveGrades] sent the grades, but could not confirm all of them; it
///   says which ones are confirmed. Saving a grade again is harmless.
/// - [SmartschoolSkoreFeedbackSaveUnconfirmedError] (the same):
///   [saveFeedback] sent the feedback, but could not confirm it. Read the
///   feedback again; calling [saveFeedback] again does not add a second.
/// - [SmartschoolSkoreEvaluationPublicError] (neither): [createEvaluation]
///   created the evaluation, but Skore shows it as public. It was created;
///   check its publication in Smartschool.
/// - [ArgumentError]: a school year ID that is not positive (before
///   anything is sent), or one Skore does not offer (Skore answers it with
///   no gradebooks; seen live); a period or pupil ID that is not positive,
///   or an evaluation of another gradebook (before anything is sent).
/// - [SmartschoolParsingError]: the session's user ID
///   (`authenticatedUser.id`) is not in the form `4069_146_0`, which
///   [getFeedback] and [saveFeedback] build Skore's IDs from.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered without a session. Sign in again and retry.
///   For the save of [createEvaluation], at once, without logging in again:
///   the save is never sent twice, and was not handled; so for a new
///   feedback of [saveFeedback]. For [saveGrade] and [saveGrades], only for
///   the first save: nothing was saved.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
class SkoreGradebookService {
  final SmartschoolClient _client;

  /// Tells the time the publication of an evaluation is compared with
  /// ([SkorePublication.state]).
  final DateTime Function() _clock;

  /// A service on [client]. [clock] tells the time that decides whether an
  /// evaluation is published or scheduled ([SkorePublication.state]); it
  /// defaults to [DateTime.now]. A test can pass a fixed one.
  SkoreGradebookService(
    SmartschoolClient client, {
    DateTime Function() clock = DateTime.now,
  }) : _client = client,
       _clock = clock;

  /// Skore's gradebook RPC service, behind `/SkoreGradebook`.
  static const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';

  /// Skore's REST API of the gradebook, which its feedback panel uses.
  static const _restPath = '/skore/api/v1/gradebook';

  /// The only methods of Skore's gradebook RPC service
  /// (`/modules/Skore/backend/gradebook/rpc.php`) that the service calls; it
  /// refuses every other one before sending ([checkRpcMethod]).
  ///
  /// The same service also holds methods that delete, move, publish or share
  /// (`deleteEvaluation`, `destroyEvaluations`, `moveEvaluation`,
  /// `setPublicProp`, `saveEvalProperties`, `usersThatCanAccess`,
  /// `importWizardResults`, ...): none of them is here. The writes are
  /// `saveEvaluation`, which [createEvaluation] always sends with `public` 0
  /// and `publicdatetime` `""`, and `saveGrade`, the grade of one pupil
  /// ([saveGrade], [saveGrades]). The library never publishes an evaluation.
  static const Set<String> rpcMethods = {
    'getNavigation',
    'init',
    'getGradebookContext',
    'getEvaluations',
    // #150: the reads of the "new evaluation" dialog, and its save.
    'getNewEvalDialogBox',
    'getPosComponents',
    'saveEvaluation',
    // #151: the grade of one pupil in an evaluation.
    'saveGrade',
  };

  /// Throws an [ArgumentError] when [method] is not one of [rpcMethods]:
  /// the check every call of the service goes through before it is sent.
  /// Exposed for testing.
  static void checkRpcMethod(String method) {
    if (!rpcMethods.contains(method)) {
      throw ArgumentError.value(
        method,
        'method',
        'not one SkoreGradebookService calls on $_rpcPath (only '
            '${rpcMethods.join(', ')}); nothing was sent',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns the logged-in teacher's own gradebooks of a school year, as the
  /// left panel of Skore's gradebook lists them, with the school years Skore
  /// offers.
  ///
  /// Without [workyearId], the gradebooks of Skore's current school year.
  /// With it, those of that school year (a [SkoreWorkyear.id] from
  /// [SkoreGradebookYear.workyears]; seen live for an earlier year). An ID
  /// that is not positive is refused before anything is sent; one Skore
  /// does not offer is refused after its answer (Skore answers it with no
  /// gradebooks rather than refusing it), both with an [ArgumentError].
  ///
  /// One request (Skore's `getNavigation`). Its answer is big (some 270 KB
  /// for a teacher with 22 gradebooks; 1.7 MB for 50), since Skore sends the
  /// colleagues of every gradebook with it: read it once, not per gradebook.
  Future<SkoreGradebookYear> getGradebookYear({int? workyearId}) async {
    if (workyearId != null && workyearId <= 0) {
      throw ArgumentError.value(
        workyearId,
        'workyearId',
        'not a school year ID; nothing was sent',
      );
    }
    final userId = (await _client.getCurrentUser()).id;
    final result = await _rpc(
      'getNavigation',
      [userId, 0],
      userId: userId,
      workyearId: workyearId,
    );
    return parseNavigation(result, workyearId: workyearId);
  }

  /// Returns the logged-in teacher's own gradebooks of a school year: the
  /// [SkoreGradebookYear.gradebooks] of [getGradebookYear], with the same
  /// [workyearId] (the current school year without it).
  Future<List<SkoreGradebook>> getGradebooks({int? workyearId}) async =>
      (await getGradebookYear(workyearId: workyearId)).gradebooks;

  /// Returns [gradebook] (from [getGradebooks]) with its periods, its pupils
  /// and whether Skore lets the user change it.
  ///
  /// Two requests, for the gradebook's school year
  /// ([SkoreGradebook.workyearId]): Skore's `init` (the periods and the
  /// pupils, as the web client opens a gradebook) and `getGradebookContext`
  /// for the period Skore opens the gradebook on
  /// ([SkoreGradebookSheet.activePeriod]; not sent for a gradebook without
  /// periods), which says whether the user may change it
  /// ([SkoreGradebookSheet.writable]).
  ///
  /// Skore's answers must be about [gradebook]: an answer about another
  /// gradebook or class is refused with a [SmartschoolSkoreError].
  Future<SkoreGradebookSheet> getGradebook(SkoreGradebook gradebook) async {
    final userId = (await _client.getCurrentUser()).id;
    final sheet = await _readInit(gradebook, userId);
    final active = sheet.activePeriod;
    if (active == null) return sheet;
    return _withContext(
      sheet,
      await _readContext(gradebook, active.id, userId),
    );
  }

  /// [gradebook] as Skore's `init(courses, owners, userID, pathIds, 0, 0)`
  /// gives it, for its school year; not yet [SkoreGradebookSheet.writable].
  Future<SkoreGradebookSheet> _readInit(
    SkoreGradebook gradebook,
    int userId,
  ) async => _parseInit(
    gradebook,
    await _rpc(
      'init',
      [
        ['${gradebook.courseId}'],
        ['${gradebook.gradebookId}'],
        userId,
        _pathIds(gradebook),
        0,
        0,
      ],
      userId: userId,
      workyearId: gradebook.workyearId,
    ),
  );

  /// The `result` of Skore's `getGradebookContext(pathIds, courses, owners,
  /// userID, periodId, 0, wy)` for period [periodId] of [gradebook].
  Future<dynamic> _readContext(
    SkoreGradebook gradebook,
    int periodId,
    int userId,
  ) => _rpc(
    'getGradebookContext',
    [
      _pathIds(gradebook),
      ['${gradebook.courseId}'],
      ['${gradebook.gradebookId}'],
      userId,
      periodId,
      0,
      gradebook.workyearId,
    ],
    userId: userId,
    workyearId: gradebook.workyearId,
  );

  /// [gradebook]'s `pathIds` as Skore's web client sends them: strings.
  static List<String> _pathIds(SkoreGradebook gradebook) => [
    for (final id in gradebook.pathIds) '$id',
  ];

  /// Returns the evaluations of [gradebook] in its period [periodId] (a
  /// [SkoreGradebookPeriod.id] of [getGradebook]), in Skore's order, each
  /// with whether and when it is published ([SkoreEvaluation.publication])
  /// and the grades of the gradebook's pupils ([SkoreEvaluation.results]).
  /// Empty for a period without evaluations.
  ///
  /// One request, for the gradebook's school year: Skore's
  /// `getEvaluations(periodID, userID, courses, groupID, classID, pathIds)`,
  /// as the web client opens a period. Skore sends the rows of the other
  /// classes of the group along; only the gradebook's own evaluations and
  /// the rows of its class are kept.
  ///
  /// The publication state is that at the time of the answer, by the
  /// service's clock: [SkorePublication.stateAt] gives it for another time.
  /// A grade is the value Skore stores (`"16.7"`), not the text it shows
  /// (`16,7`).
  ///
  /// A [periodId] that is not positive is refused with an [ArgumentError]
  /// before anything is sent; an answer about another period with a
  /// [SmartschoolSkoreError].
  Future<List<SkoreEvaluation>> getEvaluations(
    SkoreGradebook gradebook,
    int periodId,
  ) async {
    if (periodId <= 0) {
      throw ArgumentError.value(
        periodId,
        'periodId',
        'not a period ID; nothing was sent',
      );
    }
    final userId = (await _client.getCurrentUser()).id;
    final result = await _rpc(
      'getEvaluations',
      [
        periodId,
        userId,
        ['${gradebook.courseId}'],
        '${gradebook.groupId}',
        '${gradebook.classId}',
        _pathIds(gradebook),
      ],
      userId: userId,
      workyearId: gradebook.workyearId,
    );
    return parseEvaluations(result, gradebook, periodId, now: _clock());
  }

  /// Returns the grades of [evaluation] (from [getEvaluations]) as Skore
  /// has them now: [getEvaluations] for its period again, for this
  /// evaluation (by its [SkoreEvaluation.id]).
  ///
  /// An evaluation of another gradebook is refused with an [ArgumentError]
  /// before anything is sent; an evaluation Skore no longer lists in its
  /// period (moved to the trash, say) with a [SmartschoolSkoreError].
  Future<SkoreEvaluationResults> getResults(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
  ) async {
    _checkEvaluation(gradebook, evaluation);
    final evaluations = await getEvaluations(gradebook, evaluation.periodId);
    final current = evaluations.where((e) => e.id == evaluation.id).firstOrNull;
    if (current == null) {
      throw SmartschoolSkoreError(
        'Skore no longer lists evaluation ${evaluation.id} in period '
        '${evaluation.periodId} of gradebook ${gradebook.gradebookId}.',
      );
    }
    return current.results;
  }

  /// Returns the feedback of pupil [pupilId] on [evaluation] (from
  /// [getEvaluations]), in Skore's order (the order they were written in,
  /// seen live): the feedback of every teacher, and more than one of a
  /// teacher when there are. Empty when there is none
  /// ([SkoreGrade.hasFeedback] is `false`).
  ///
  /// One request to Skore's REST API, as the feedback panel of Skore's
  /// gradebook reads it: `GET /skore/api/v1/gradebook/feedback/
  /// {ss}_{evaluationId}/student/{ss}_{pupilId}_0/class/{ss}_{classId}/
  /// teacher/{ss}_{userId}_0/context/{modelId}_{groupId}_{classId}`, with
  /// `ss` the platform of the session's user ID (`4069` of `4069_146_0`).
  /// Unlike the cell's tooltip and Skore's older `getGradeInfo`, which join
  /// all feedback of a pupil into one text, it keeps them apart.
  ///
  /// An evaluation of another gradebook, or a [pupilId] that is not
  /// positive, is refused with an [ArgumentError] before anything is sent;
  /// feedback about another pupil or evaluation with a
  /// [SmartschoolSkoreError].
  Future<List<SkoreFeedback>> getFeedback(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
    int pupilId,
  ) async {
    _checkEvaluation(gradebook, evaluation);
    if (pupilId <= 0) {
      throw ArgumentError.value(
        pupilId,
        'pupilId',
        'not a pupil ID; nothing was sent',
      );
    }
    final (platform, userId) = await _platformAndUser();
    return _readFeedback(
      feedbackPath(
        platform: platform,
        userId: userId,
        gradebook: gradebook,
        evaluationId: evaluation.id,
        pupilId: pupilId,
      ),
      pupilId,
      evaluation.id,
    );
  }

  /// The path of Skore's REST API for the feedback of pupil [pupilId] on
  /// evaluation [evaluationId] of [gradebook], read by user [userId] of
  /// platform [platform] (see [getFeedback]). Exposed for testing.
  static String feedbackPath({
    required int platform,
    required int userId,
    required SkoreGradebook gradebook,
    required int evaluationId,
    required int pupilId,
  }) =>
      '$_restPath/feedback/${platform}_$evaluationId'
      '/student/${platform}_${pupilId}_0'
      '/class/${platform}_${gradebook.classId}'
      '/teacher/${platform}_${userId}_0'
      '/context/${gradebook.pathIds.join('_')}';

  /// Refuses [evaluation] with an [ArgumentError] when it is not one of
  /// [gradebook].
  static void _checkEvaluation(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
  ) {
    if (evaluation.gradebookId != gradebook.gradebookId) {
      throw ArgumentError.value(
        evaluation.id,
        'evaluation',
        'an evaluation of gradebook ${evaluation.gradebookId}, not of '
            'gradebook ${gradebook.gradebookId}; nothing was sent',
      );
    }
  }

  /// The session's user ID in its parts (`4069_146_0`): the platform
  /// (`4069`, Skore's `ss`) and the user ID (`146`).
  Future<(int, int)> _platformAndUser() async {
    final id = (await _client.authenticatedUser)['id'];
    final match = id is String ? _sessionUserId.firstMatch(id.trim()) : null;
    if (match == null) {
      throw SmartschoolParsingError(
        'Could not read the platform and the user ID from '
        'authenticatedUser.id "$id".',
      );
    }
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  static final _sessionUserId = RegExp(r'^(\d+)_(\d+)_\d+$');

  /// Returns the components an evaluation in period [periodId] of
  /// [gradebook] can count for, as the "new evaluation" dialog of Skore's
  /// gradebook offers them (#150), in Skore's order: `geen` (none, ID `0`)
  /// and the period's components (seen live for 6EWI's DW1: `geen` and
  /// `DW`). [createEvaluation] takes one of their IDs.
  ///
  /// One request, for the gradebook's school year: Skore's
  /// `getPosComponents(0, periodID, groupID, courseID, pathIds)`, as the
  /// dialog sends it. A [periodId] that is not positive is refused with an
  /// [ArgumentError] before anything is sent.
  Future<List<SkoreEvaluationComponent>> getComponents(
    SkoreGradebook gradebook,
    int periodId,
  ) async {
    if (periodId <= 0) {
      throw ArgumentError.value(
        periodId,
        'periodId',
        'not a period ID; nothing was sent',
      );
    }
    final userId = (await _client.getCurrentUser()).id;
    return _readComponents(gradebook, periodId, userId);
  }

  Future<List<SkoreEvaluationComponent>> _readComponents(
    SkoreGradebook gradebook,
    int periodId,
    int userId,
  ) async => parseComponents(
    await _rpc(
      'getPosComponents',
      [
        0,
        periodId,
        '${gradebook.groupId}',
        '${gradebook.courseId}',
        _pathIds(gradebook),
      ],
      userId: userId,
      workyearId: gradebook.workyearId,
    ),
  );

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// What `saveEvaluation` always sends as `public` and `publicdatetime`:
  /// not published, what Skore's dialog sends when "Publiceren" is not
  /// ticked. The library never publishes (#150).
  static const _notPublic = 0;
  static const _noPublicationTime = '';

  /// Creates an evaluation (a column of grades) in period [periodId] of
  /// [gradebook], **unpublished**, and returns it as Skore lists it right
  /// after the save (#150). Teachers check it in Smartschool and publish it
  /// there themselves: the library never publishes it, and has no parameter
  /// to.
  ///
  /// - [title]: not blank; sent trimmed.
  /// - [shortName]: optional; none when `null` or blank.
  /// - [date]: the day of the evaluation (its year, month and day; the time
  ///   does not count), in the school year: from 1 September to 31 August,
  ///   as Skore's dialog allows (seen live: 2026-09-01 to 2027-08-31).
  /// - [max]: the highest grade, a positive whole number.
  /// - [componentId]: one of [getComponents] (`0` for none). Without it, the
  ///   one Skore's dialog picks: the second when Skore offers exactly two
  ///   (`geen` and the period's component), else `geen`.
  ///
  /// The evaluation counts in points ("Cijfers"), without cumulation, type
  /// or import.
  ///
  /// Before the save, it reads Skore again and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
  /// - a blank [title], a [max] that is not positive, or a [periodId] that
  ///   is not positive (before anything is sent);
  /// - a gradebook that is not one of the user's own gradebooks of Skore's
  ///   current school year ([getGradebookYear]): the library writes in the
  ///   current school year only;
  /// - a period that is not one of the gradebook's, or is closed
  ///   ([SkoreGradebookPeriod.isOpen]);
  /// - a gradebook Skore shows read-only in that period
  ///   ([SkoreGradebookSheet.writable], asked for that period; or coordinator
  ///   mode);
  /// - a [date] outside the school year;
  /// - a course Skore does not offer for a new evaluation in the period
  ///   (`getNewEvalDialogBox`), or a [componentId] it does not offer.
  ///
  /// A read before the save that fails throws as the reads do (a
  /// [SmartschoolSkoreError]): nothing was saved either.
  ///
  /// The save is Skore's `saveEvaluation`, as the dialog sends it, with
  /// `public` 0 and `publicdatetime` `""` (verified live). **It is sent
  /// once**, never again, not even after logging in again: a create is not
  /// idempotent, so a second one would make a second evaluation. Skore must
  /// answer it with `state` 1 and the new evaluation's `refID`, and reading
  /// the period again ([getEvaluations]) must list that evaluation with the
  /// title, date, highest grade and component asked for. Otherwise this
  /// throws a [SmartschoolSkoreEvaluationCreateUnconfirmedError] (also for
  /// an answer with another HTTP status, such as a `500`, or that is not
  /// JSON): read the period again before trying again. A session Smartschool
  /// refuses for the save, or an answer without a session, is a
  /// [SmartschoolSessionExpiredError] at once: Skore did not handle it.
  ///
  /// When Skore shows the new evaluation as public anyway (`public` `"1"`:
  /// published or scheduled), this throws a
  /// [SmartschoolSkoreEvaluationPublicError] that names it, and changes
  /// nothing: undoing it would take the publishing calls the library never
  /// makes. Change it in Smartschool.
  ///
  /// The checks and the save are separate requests: do not change the same
  /// period from two places at once.
  Future<SkoreEvaluation> createEvaluation(
    SkoreGradebook gradebook,
    int periodId, {
    required String title,
    String? shortName,
    required DateTime date,
    required int max,
    int? componentId,
  }) async {
    const operation = 'createEvaluation';
    final name = title.trim();
    final short = shortName?.trim() ?? '';
    if (name.isEmpty) _refuse(operation, 'the title is blank');
    if (max <= 0) {
      _refuse(
        operation,
        'the highest grade ($max) is not a positive whole number',
      );
    }
    final day = DateTime(date.year, date.month, date.day);

    final target = await _checkWritable(operation, gradebook, periodId);
    final book = target.gradebook;
    final period = target.period;
    final where =
        'period ${period.name} ($periodId) of gradebook ${book.gradebookId}';
    final (first, last) = _schoolYearDays(target.workyear);
    if (day.isBefore(first) || day.isAfter(last)) {
      _refuse(
        operation,
        'the date ${_dayText(day)} is not in school year '
        '${target.workyear.name} (${_dayText(first)} to ${_dayText(last)})',
      );
    }
    final course = await _newEvaluationCourse(operation, target, where);
    final component = _component(
      operation,
      await _readComponents(book, periodId, target.userId),
      componentId,
      where,
    );

    final what =
        '$operation: the save of evaluation "$name" (${_dayText(day)}, max '
        '$max, component ${component.name}) in $where';
    SmartschoolSkoreEvaluationCreateUnconfirmedError unconfirmed(
      String message, {
      Object? cause,
      int? evaluationId,
    }) => SmartschoolSkoreEvaluationCreateUnconfirmedError(
      '$message ${evaluationId == null ? 'It may or may not have been created' : 'Skore answered that it created it'}'
      ', unpublished: read the evaluations of the period again '
      '(getEvaluations) before trying again; createEvaluation again makes a '
      'second evaluation.',
      cause: cause,
      gradebookId: book.gradebookId,
      periodId: periodId,
      title: name,
      evaluationId: evaluationId,
    );

    final result = await _save(
      'saveEvaluation',
      [
        0, // evaluationID: a new evaluation
        '${book.gradebookId}', // ownerID
        target.userId,
        '${book.courseId}',
        course.name,
        name,
        short,
        periodId,
        _dayText(day),
        '$max',
        component.name,
        component.isNone ? 0 : '${component.id}',
        _notPublic,
        const <Object?>[], // chain: no cumulation
        _pathIds(book),
        null, // contentType
        null, // contentTypeName
        _noPublicationTime,
        null, // importParams
        1, // evalType: points ("Cijfers")
      ],
      gradebook: book,
      userId: target.userId,
      retryAfterLogin: false,
      unconfirmed: (failure) => unconfirmed(
        '$what was sent, but no usable answer came in ($failure).',
        cause: failure,
      ),
    );

    // {"state":1,"incumul":0,"evaluationID":395764,"refID":395764,
    // "importData":null} (seen live).
    final state = result is Map ? SkoreRpc.tryId(result['state']) : null;
    final id = result is Map ? SkoreRpc.tryId(result['refID']) : null;
    if (state != 1 || id == null || id <= 0) {
      throw unconfirmed(
        '$what was sent, but Skore\'s answer ${SkoreRpc.jsonPreview(result)} '
        'does not confirm it (state 1 with the refID of the new '
        'evaluation).',
      );
    }

    final SkoreEvaluation? created;
    try {
      created = (await getEvaluations(
        book,
        periodId,
      )).where((e) => e.id == id).firstOrNull;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        unconfirmed(
          '$what was confirmed as evaluation $id, but reading the period '
          'again to check it failed ($e).',
          cause: e,
          evaluationId: id,
        ),
        stackTrace,
      );
    }
    if (created == null) {
      throw unconfirmed(
        '$what was confirmed as evaluation $id, but reading the period again '
        'does not list it.',
        evaluationId: id,
      );
    }
    final publication = created.publication;
    if (publication.isPublic) {
      throw SmartschoolSkoreEvaluationPublicError(
        '$operation: evaluation "${created.title}" ($id) was created in '
        '$where, but Skore shows it as ${publication.state.name} (public '
        '"${publication.rawPublic}", publicdatetime '
        '"${publication.rawPublicDateTime}"), although it was sent '
        'unpublished. The library does not change a publication: check the '
        'evaluation in Smartschool and change it there. Do not create it '
        'again.',
        evaluation: created,
      );
    }
    final differences = [
      if (created.title != name) 'the title "${created.title}"',
      if (!_sameDay(created.date, day)) 'the date ${_dayText(created.date)}',
      if (created.max != max) 'the highest grade ${created.max}',
      if (created.componentId != component.id)
        'component ${created.componentId} (${created.componentName})',
    ];
    if (differences.isNotEmpty) {
      throw unconfirmed(
        '$what was confirmed as evaluation $id, but reading the period again '
        'shows it with ${differences.join(', ')}.',
        evaluationId: id,
      );
    }
    return created;
  }

  /// Saves the grade of pupil [pupilId] in [evaluation] (from
  /// [getEvaluations]) of [gradebook], or clears it, and returns the pupil's
  /// cell as Skore lists it right after the save (#151).
  ///
  /// [grade]: a number of 0 or more, up to the evaluation's
  /// [SkoreEvaluation.max] (`"15"`, `"15.5"`, or `"15,5"` as a teacher types
  /// it); `null` or blank clears the grade. An evaluation that is published
  /// or scheduled is refused unless [allowPublished] is `true`.
  ///
  /// [saveGrades] for one pupil: the same checks, the same save and the same
  /// errors; see there.
  Future<SkoreGrade> saveGrade(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
    int pupilId,
    String? grade, {
    bool allowPublished = false,
  }) async => (await _saveGrades('saveGrade', gradebook, evaluation, {
    pupilId: grade,
  }, allowPublished: allowPublished))[pupilId]!;

  /// Saves the grades of pupils in [evaluation] (from [getEvaluations]) of
  /// [gradebook], or clears them, and returns each pupil's cell as Skore
  /// lists it right after the saves, by pupil ID, in the order of [grades]
  /// (#151).
  ///
  /// [grades] maps a pupil's ID ([SkoreGrade.pupilId], the pupil's
  /// Smartschool user ID) to the grade: a number of 0 or more, up to the
  /// evaluation's [SkoreEvaluation.max], with a decimal point or comma
  /// (`"15"`, `"15.5"`, `"15,5"`, as a teacher types it), or `null` or blank
  /// to clear it. It is sent as a plain decimal with a point, without
  /// leading or trailing zeros (`"15,50"` as `"15.5"`). For empty [grades],
  /// nothing is read or sent.
  ///
  /// **Published evaluations.** A grade in a published evaluation is
  /// visible to its pupils at once, and the school sends them a
  /// notification; in a scheduled one, from its publication on. So an
  /// evaluation that is published or scheduled ([SkorePublication.isPublic],
  /// as Skore lists it right before the save) is refused unless
  /// [allowPublished] is `true`.
  ///
  /// Before the first save, it reads Skore again and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
  /// - a pupil ID that is not positive, or a grade that is not a number of
  ///   0 or more (before anything is sent);
  /// - a gradebook or period [createEvaluation] refuses too: not one of the
  ///   user's own gradebooks of Skore's current school year, a period that
  ///   is closed, or one Skore shows read-only;
  /// - an evaluation of another gradebook, or one Skore no longer lists in
  ///   its period;
  /// - an evaluation from the planner ([SkoreEvaluation.isPlannerEvaluation]:
  ///   Skore's web client leaves those to the planner), one that is not in
  ///   points ([SkoreEvaluationType.points]), or one without a highest
  ///   grade;
  /// - a published or scheduled evaluation, without [allowPublished];
  /// - a pupil without a cell in the evaluation's rows of the gradebook's
  ///   class (a pupil of another class, say), or whose cell has no
  ///   evaluation ID;
  /// - a grade above the highest grade: Skore answers that with HTTP 500 and
  ///   does not save it (seen live).
  ///
  /// All pupils are checked first: one refused pupil saves none.
  ///
  /// Then it sends Skore's `saveGrade` for each pupil in turn, as the web
  /// client sends it for a cell (verified live), and Skore must answer each
  /// with `savedState` 1. A failed save does not stop the others. Saving the
  /// same grade twice gives the same state, so a save is sent again after a
  /// new login when Smartschool refuses the session for it. When Smartschool
  /// refuses it even then, or logging in again fails, for the first save
  /// this throws that [SmartschoolSessionExpiredError] (or other
  /// [SmartschoolAuthenticationError]): nothing was saved. For a later save,
  /// the pupils after it are not sent.
  ///
  /// Afterwards it reads the period again ([getEvaluations]), once: each
  /// pupil's grade must be the one sent (the same number, or none for a
  /// cleared one). When a save failed, or that read fails or shows another
  /// grade, this throws a [SmartschoolSkoreGradeSaveUnconfirmedError] that
  /// tells, per pupil, which grades are confirmed and why the others are
  /// not. Saving a grade again is harmless.
  ///
  /// The checks and the saves are separate requests: do not change the same
  /// evaluation from two places at once.
  Future<Map<int, SkoreGrade>> saveGrades(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
    Map<int, String?> grades, {
    bool allowPublished = false,
  }) => _saveGrades(
    'saveGrades',
    gradebook,
    evaluation,
    grades,
    allowPublished: allowPublished,
  );

  Future<Map<int, SkoreGrade>> _saveGrades(
    String operation,
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
    Map<int, String?> grades, {
    required bool allowPublished,
  }) async {
    if (grades.isEmpty) return const {};
    // Before anything is sent: the pupils' IDs and the grades.
    final values = <int, _GradeValue>{};
    final wrong = <String>[];
    for (final MapEntry(key: pupilId, value: grade) in grades.entries) {
      final value = _gradeValue(grade);
      if (pupilId <= 0) {
        wrong.add('$pupilId is not a pupil ID');
      } else if (value == null) {
        wrong.add(
          'the grade ${jsonEncode(grade)} of pupil $pupilId is not a number '
          'of 0 or more (such as 15, 15.5 or 15,5), nor empty to clear it',
        );
      } else {
        values[pupilId] = value;
      }
    }
    if (wrong.isNotEmpty) _refuse(operation, wrong.join('; '));

    final checked = await _checkEvaluationWrite(
      operation,
      gradebook,
      evaluation,
      allowPublished: allowPublished,
    );
    final target = checked.target;
    final book = target.gradebook;
    final current = checked.evaluation;
    final where = checked.where;
    if (current.type != SkoreEvaluationType.points) {
      _refuse(
        operation,
        '$where is not in points (evaltype ${current.typeCode}): the library '
        'saves grades in points only',
      );
    }
    final max = current.max;
    if (max == null) {
      _refuse(operation, '$where has no highest grade to check grades against');
    }
    final cells = <int, SkoreGrade>{};
    for (final MapEntry(key: pupilId, value: value) in values.entries) {
      final cell = current.results.gradeOf(pupilId);
      final number = value.number;
      if (cell == null) {
        wrong.add(
          'pupil $pupilId has no cell in its rows of class ${book.classId}',
        );
      } else if (cell.cellEvaluationId <= 0) {
        wrong.add('the cell of pupil $pupilId has no evaluation ID');
      } else if (number != null && number > max) {
        wrong.add(
          'the grade ${value.text} of pupil $pupilId is above the highest '
          'grade, $max',
        );
      } else {
        cells[pupilId] = cell;
      }
    }
    if (wrong.isNotEmpty) _refuse(operation, 'in $where, ${wrong.join('; ')}');

    // One save per pupil, in turn; a failed one does not stop the others.
    final entries = values.entries.toList();
    final failures = <int, String>{};
    Exception? cause;
    var handled = false; // whether Skore may have handled a save
    for (var i = 0; i < entries.length; i++) {
      final MapEntry(key: pupilId, value: value) = entries[i];
      final cell = cells[pupilId]!;
      try {
        final result = await _rpc(
          'saveGrade',
          [
            '${current.id}', // col: the evaluation's column, its refID
            cell.rowKey, // row: pupil_<pupilId>_<classId>
            value.text,
            target.userId,
            0, // projectID: an evaluation, not a project
            0, // catID
            0, // courseID
            '${cell.categoryType}', // catType: p[1] of the cell
            _pathIds(book),
            '${cell.cellEvaluationId}', // evaluationID: p[2] of the cell
            '${book.gradebookId}', // ownerID: p[3] of the cell
          ],
          userId: target.userId,
          workyearId: book.workyearId,
        );
        handled = true;
        // {"savedState":1,"postEvalData":null,"grade":"15.5","stream":[...]}
        // (seen live). -1 is the web client's "wrong component" alert.
        final state = result is Map ? result['savedState'] : null;
        if (SkoreRpc.tryId(state) != 1) {
          failures[pupilId] =
              'Skore answered ${SkoreRpc.jsonPreview(result)} instead of '
              'savedState 1';
        }
      } on SmartschoolAuthenticationError catch (e) {
        // Smartschool refused the session, also after a new login, logging
        // in again failed, or Skore answered without a session: Skore did
        // not handle this save, and would not handle the next ones.
        if (!handled) rethrow;
        cause ??= e;
        failures[pupilId] = 'Smartschool did not accept the session ($e)';
        for (final MapEntry(key: later) in entries.skip(i + 1)) {
          failures[later] =
              'not sent, as Smartschool did not accept the session for an '
              'earlier save';
        }
        break;
      } on Exception catch (e) {
        // Another HTTP status (Skore answers a bad value with a 500), an
        // answer that is not JSON, a connection that dropped.
        handled = true;
        cause ??= e;
        failures[pupilId] = 'no usable answer came in ($e)';
      }
    }

    // The check: the period read again, once.
    SkoreEvaluation? after;
    Exception? readFailure;
    try {
      after = (await getEvaluations(
        book,
        current.periodId,
      )).where((e) => e.id == current.id).firstOrNull;
    } on Exception catch (e) {
      readFailure = e;
    }
    final confirmed = <int, SkoreGrade>{};
    final unconfirmed = <int, String>{};
    for (final MapEntry(key: pupilId, value: value) in entries) {
      final cell = after?.results.gradeOf(pupilId);
      final shows = readFailure != null
          ? 'reading the period again to check it failed ($readFailure)'
          : after == null
          ? 'reading the period again does not list the evaluation'
          : cell == null
          ? 'reading the period again shows no cell for the pupil'
          : 'reading the period again shows '
                '${cell.grade == null ? 'no grade' : '"${cell.grade}"'}';
      final failure = failures[pupilId];
      if (failure != null) {
        unconfirmed[pupilId] = '$failure; $shows';
      } else if (cell != null && _sameGrade(cell.grade, value)) {
        confirmed[pupilId] = cell;
      } else {
        unconfirmed[pupilId] = shows;
      }
    }
    if (unconfirmed.isEmpty) return confirmed;

    final count = entries.length;
    final sent = count == 1 ? 'the grade' : 'the grades of $count pupils';
    final which = confirmed.isNotEmpty
        ? '${unconfirmed.length} of them'
        : count == 1
        ? 'it'
        : 'any of them';
    final reasons = [
      for (final MapEntry(key: pupilId, value: why) in unconfirmed.entries)
        'pupil $pupilId (${_sentText(values[pupilId]!)}): $why',
    ];
    throw SmartschoolSkoreGradeSaveUnconfirmedError(
      '$operation: $sent in $where went out, but Skore does not confirm '
      '$which: ${reasons.join('; ')}. '
      '${confirmed.isEmpty ? '' : 'The others are confirmed. '}'
      'Saving a grade again is harmless: read the grades again (getResults) '
      'and save the ones that differ.',
      cause: cause ?? readFailure,
      gradebookId: book.gradebookId,
      periodId: current.periodId,
      evaluationId: current.id,
      grades: {for (final MapEntry(:key, :value) in entries) key: value.text},
      confirmed: confirmed,
      unconfirmed: unconfirmed,
    );
  }

  static final _decimalGrade = RegExp(r'^(\d+)(?:[.,](\d+))?$');
  static final _leadingZeros = RegExp(r'^0+(?=\d)');
  static final _trailingZeros = RegExp(r'0+$');

  /// [grade] as `saveGrade` sends it, with its number: a plain decimal with
  /// a point, without leading or trailing zeros (`"015,50"` is `"15.5"`);
  /// `""` without a number for `null` or blank, which clears the grade.
  /// `null` when it is neither a number of 0 or more nor blank.
  static _GradeValue? _gradeValue(String? grade) {
    final text = grade?.trim() ?? '';
    if (text.isEmpty) return (text: '', number: null);
    final match = _decimalGrade.firstMatch(text);
    if (match == null) return null;
    final whole = match.group(1)!.replaceFirst(_leadingZeros, '');
    final fraction = (match.group(2) ?? '').replaceFirst(_trailingZeros, '');
    final plain = fraction.isEmpty ? whole : '$whole.$fraction';
    return (text: plain, number: num.parse(plain));
  }

  /// Whether [raw], a grade Skore lists ([SkoreGrade.grade]), is the grade
  /// [sent]: none for a cleared one, else the same number (`"15"` for
  /// `15`).
  static bool _sameGrade(String? raw, _GradeValue sent) {
    final number = sent.number;
    if (number == null) return raw == null;
    return raw != null && (raw == sent.text || num.tryParse(raw) == number);
  }

  /// [sent] for a message: `"15.5"`, or `cleared`.
  static String _sentText(_GradeValue sent) =>
      sent.number == null ? 'cleared' : '"${sent.text}"';

  /// Gives pupil [pupilId] written feedback on [evaluation] (from
  /// [getEvaluations]) of [gradebook], or changes the feedback the user gave
  /// them there before, and returns it as Skore lists it right after the
  /// save (#152).
  ///
  /// [text]: not blank; sent trimmed. An evaluation that is published or
  /// scheduled is refused unless [allowPublished] is `true`: feedback on a
  /// published evaluation is visible to the pupil at once.
  ///
  /// It reads the pupil's feedback first ([getFeedback]) and keeps to the
  /// user's own, by teacher ID: **the feedback of other teachers is never
  /// changed**. Then, through Skore's REST API, as the feedback panel of
  /// Skore's gradebook sends it (verified live), with a JSON body and
  /// `X-Requested-With: XMLHttpRequest`:
  /// - the user has none: it creates one (`POST
  ///   /skore/api/v1/gradebook/feedback` with `{evaluation, studentId, text,
  ///   attachments: []}`). **The create is sent once**, never again, not even
  ///   after logging in again: a second create adds a second feedback (seen
  ///   live), it does not replace the first;
  /// - the user has one: it changes its text (`POST
  ///   .../feedback/{id}` with `{id, evaluation, studentId, text,
  ///   attachments}`, its attachments sent back as they are). It sends the
  ///   whole text, so it is sent again after a new login.
  ///
  /// `evaluation` is `{evaluationId: "{ss}_{refID}", classGroupId:
  /// "{ss}_{classId}", teacherId: "{ss}_{userId}_0", context:
  /// "{modelId}_{groupId}_{classId}"}` and `studentId` `"{ss}_{pupilId}_0"`,
  /// the IDs of [getFeedback].
  ///
  /// Before the save, it reads Skore again and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
  /// - a pupil ID that is not positive, or a blank [text] (before anything
  ///   is sent);
  /// - what [saveGrade] refuses for the gradebook, the period and the
  ///   evaluation: not one of the user's own gradebooks of Skore's current
  ///   school year, a period that is closed or read-only, an evaluation of
  ///   another gradebook, no longer listed, or from the planner, and one
  ///   that is published or scheduled, without [allowPublished] (any type
  ///   of evaluation: feedback is not a grade);
  /// - a pupil without a cell in the evaluation's rows of the gradebook's
  ///   class;
  /// - the user's own feedback for the pupil that Skore does not let them
  ///   change (`capabilities.can_edit` `false`), or **more than one** of it
  ///   (a second create makes that): it changes none of them, as it cannot
  ///   tell which one is meant. Keep one in Smartschool.
  ///
  /// Skore answering the save with `400` to `499` is a
  /// [SmartschoolSkoreError] with the `title` and `detail` of its answer:
  /// Skore refused it, nothing was saved. A session Smartschool refuses (for
  /// the create, at once; for a change, also after a new login) is a
  /// [SmartschoolSessionExpiredError]: nothing was saved either.
  ///
  /// Skore must answer the save with the feedback (`200`): of the pupil and
  /// the user, and for a change with the same ID. Then it reads the pupil's
  /// feedback again: the user's feedback with that ID must have the text
  /// sent. Otherwise this throws a
  /// [SmartschoolSkoreFeedbackSaveUnconfirmedError] (also for another
  /// status, such as a `500`, an answer that is not JSON, or a connection
  /// that dropped): read the feedback again. Calling `saveFeedback` again is
  /// safe: it reads first, and changes the feedback a create made.
  ///
  /// The checks and the save are separate requests: do not change the same
  /// feedback from two places at once.
  Future<SkoreFeedback> saveFeedback(
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation,
    int pupilId,
    String text, {
    bool allowPublished = false,
  }) async {
    const operation = 'saveFeedback';
    final sent = text.trim();
    if (pupilId <= 0) _refuse(operation, '$pupilId is not a pupil ID');
    if (sent.isEmpty) _refuse(operation, 'the text is blank');

    final checked = await _checkEvaluationWrite(
      operation,
      gradebook,
      evaluation,
      allowPublished: allowPublished,
    );
    final book = checked.target.gradebook;
    final current = checked.evaluation;
    final where = checked.where;
    if (current.results.gradeOf(pupilId) == null) {
      _refuse(
        operation,
        'in $where, pupil $pupilId has no cell in its rows of class '
        '${book.classId}',
      );
    }

    // The user's own feedback for the pupil, as Skore has it now.
    final (platform, userId) = await _platformAndUser();
    final readPath = feedbackPath(
      platform: platform,
      userId: userId,
      gradebook: book,
      evaluationId: current.id,
      pupilId: pupilId,
    );
    final own = [
      for (final f in await _readFeedback(readPath, pupilId, current.id))
        if (f.teacherId == userId) f,
    ];
    if (own.length > 1) {
      _refuse(
        operation,
        'you gave pupil $pupilId ${own.length} feedbacks on $where already '
        '(${own.map((f) => f.id).join(', ')}): the library changes none of '
        'them, as it cannot tell which one is meant. Keep one in Smartschool',
      );
    }
    final existing = own.firstOrNull;
    if (existing != null && !existing.canEdit) {
      _refuse(
        operation,
        'Skore does not let you change your feedback ${existing.id} for pupil '
        '$pupilId on $where (can_edit false)',
      );
    }

    final isUpdate = existing != null;
    final reference = {
      'evaluationId': '${platform}_${current.id}',
      'classGroupId': '${platform}_${book.classId}',
      'teacherId': '${platform}_${userId}_0',
      'context': book.pathIds.join('_'),
    };
    final studentId = '${platform}_${pupilId}_0';
    final Map<String, Object?> body;
    final String path;
    if (existing == null) {
      path = '$_restPath/feedback';
      body = {
        'evaluation': reference,
        'studentId': studentId,
        'text': sent,
        'attachments': const <Object?>[],
      };
    } else {
      path = '$_restPath/feedback/${Uri.encodeComponent(existing.id)}';
      body = {
        'id': existing.id,
        'evaluation': reference,
        'studentId': studentId,
        'text': sent,
        'attachments': [for (final a in existing.attachments) a.json],
      };
    }

    final what = isUpdate
        ? '$operation: the change of your feedback ${existing.id} for pupil '
              '$pupilId on $where'
        : '$operation: the new feedback for pupil $pupilId on $where';
    SmartschoolSkoreFeedbackSaveUnconfirmedError unconfirmed(
      String message, {
      Object? cause,
      String? feedbackId,
    }) {
      final created = feedbackId == null
          ? 'It may or may not have been created'
          : 'Skore answered that it created it';
      final advice = isUpdate
          ? 'It may or may not have been changed: saving it again is '
                'harmless.'
          : '$created: read the feedback again (getFeedback) before trying '
                'again. saveFeedback again changes the feedback it created, '
                'if it did, rather than adding a second.';
      return SmartschoolSkoreFeedbackSaveUnconfirmedError(
        '$message $advice',
        cause: cause,
        gradebookId: book.gradebookId,
        periodId: current.periodId,
        evaluationId: current.id,
        pupilId: pupilId,
        text: sent,
        isUpdate: isUpdate,
        feedbackId: feedbackId ?? existing?.id,
      );
    }

    final Response<String> response;
    try {
      response = await _client.postJsonResponse(
        path,
        data: body,
        headers: const {kXRequestedWith: 'XMLHttpRequest'},
        // A create is not idempotent: a second one adds a second feedback.
        retryAfterLogin: isUpdate,
      );
    } on SmartschoolAuthenticationError {
      // Smartschool refused the session (for a change, also after a new
      // login), or logging in again failed: Skore did not handle the save.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        unconfirmed('$what was sent, but no answer came in ($e).', cause: e),
        stackTrace,
      );
    }

    final status = response.statusCode ?? 0;
    if (status >= 400 && status < 500) {
      final problem = _problem(response.data);
      throw SmartschoolSkoreError(
        '$what was refused by Skore with HTTP $status'
        '${problem == null ? '' : ': $problem'}. Nothing was saved.',
      );
    }
    final SkoreFeedback answer;
    try {
      if (status != 200) {
        final problem = _problem(response.data);
        throw SmartschoolSkoreError(
          'Skore answered with HTTP $status'
          '${problem == null ? '' : ': $problem'}',
        );
      }
      answer = _feedback(
        SkoreRpc.decodeJson(response.data ?? '', 'the save'),
        'its answer',
        pupilId: pupilId,
        evaluationId: current.id,
      );
    } on SmartschoolSkoreError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        unconfirmed(
          '$what was sent, but Skore\'s answer is not the feedback saved '
          '(${e.message}).',
          cause: e,
        ),
        stackTrace,
      );
    }
    if (answer.teacherId != userId ||
        (existing != null && answer.id != existing.id)) {
      throw unconfirmed(
        '$what was sent, but Skore answered with feedback ${answer.id} of '
        'teacher ${answer.teacherId} instead of '
        '${existing == null ? 'a new feedback' : 'feedback ${existing.id}'} '
        'of yours ($userId).',
      );
    }

    // The check: the pupil's feedback read again.
    final SkoreFeedback? saved;
    try {
      saved = (await _readFeedback(
        readPath,
        pupilId,
        current.id,
      )).where((f) => f.id == answer.id).firstOrNull;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        unconfirmed(
          '$what was confirmed as feedback ${answer.id}, but reading the '
          'feedback again to check it failed ($e).',
          cause: e,
          feedbackId: answer.id,
        ),
        stackTrace,
      );
    }
    if (saved == null) {
      throw unconfirmed(
        '$what was confirmed as feedback ${answer.id}, but reading the '
        'feedback again does not list it.',
        feedbackId: answer.id,
      );
    }
    if (saved.teacherId != userId || saved.text.trim() != sent) {
      throw unconfirmed(
        '$what was confirmed as feedback ${answer.id}, but reading the '
        'feedback again shows it '
        '${saved.teacherId != userId ? 'of teacher ${saved.teacherId}' : 'with another text (${saved.text.length} characters, not ${sent.length})'}.',
        feedbackId: answer.id,
      );
    }
    return saved;
  }

  /// The feedback of pupil [pupilId] on evaluation [evaluationId], read
  /// from Skore's REST API at [path] ([feedbackPath]).
  Future<List<SkoreFeedback>> _readFeedback(
    String path,
    int pupilId,
    int evaluationId,
  ) async => parseFeedback(
    _restJson(
      await _client.getResponse(path),
      'the feedback of pupil $pupilId on evaluation $evaluationId',
    ),
    pupilId: pupilId,
    evaluationId: evaluationId,
  );

  /// Reads [gradebook] and its period [periodId] again, and refuses a write
  /// in them with a [SmartschoolSkoreChangeRefusedError] that names
  /// [operation] unless:
  /// - [periodId] is positive (checked before anything is sent);
  /// - the gradebook is one of the user's own gradebooks of Skore's current
  ///   school year (`getNavigation` without `wy`), with the user as its
  ///   teacher;
  /// - the period is one of the gradebook's, and open (`init`);
  /// - Skore lets the user change the gradebook in that period
  ///   (`getGradebookContext` for the period: `writable` 1, no coordinator
  ///   mode). `writable` alone is not enough: Skore answers it for a closed
  ///   period of an earlier school year too (seen live, #148).
  ///
  /// The checks every write in a gradebook makes first: [createEvaluation]
  /// (#150), and the grades and feedback of #151 and #152. Returns what
  /// they read, the gradebook as Skore lists it now included, which the
  /// write then uses.
  Future<_WriteTarget> _checkWritable(
    String operation,
    SkoreGradebook gradebook,
    int periodId,
  ) async {
    if (periodId <= 0) _refuse(operation, '$periodId is not a period ID');
    final gradebookId = gradebook.gradebookId;
    final userId = (await _client.getCurrentUser()).id;
    final year = await getGradebookYear();
    final current = year.workyear;
    if (gradebook.workyearId != current.id) {
      _refuse(
        operation,
        'gradebook $gradebookId is of school year ${gradebook.workyearId}, '
        'not of the current one, ${current.name} (${current.id}): the '
        'library writes in the current school year only',
      );
    }
    final book = year.gradebooks
        .where((g) => g.gradebookId == gradebookId)
        .firstOrNull;
    if (book == null) {
      _refuse(
        operation,
        'gradebook $gradebookId is not one of your own gradebooks of '
        '${current.name} (Skore lists ${year.gradebooks.length})',
      );
    }
    if (book.teacherId != userId) {
      _refuse(
        operation,
        'gradebook $gradebookId is of teacher ${book.teacherId}, not your own '
        '(you are $userId)',
      );
    }
    final sheet = await _readInit(book, userId);
    final period = sheet.periods.where((p) => p.id == periodId).firstOrNull;
    if (period == null) {
      _refuse(
        operation,
        'period $periodId is not one of gradebook $gradebookId (it has '
        '${sheet.periods.isEmpty ? 'none' : sheet.periods.map((p) => '${p.name} (${p.id})').join(', ')})',
      );
    }
    if (!period.isOpen) {
      _refuse(
        operation,
        'period ${period.name} ($periodId) of gradebook $gradebookId is '
        'closed',
      );
    }
    final checked = _withContext(
      SkoreGradebookSheet(
        gradebook: book,
        courseName: sheet.courseName,
        periods: sheet.periods,
        activePeriod: period,
        pupils: sheet.pupils,
      ),
      await _readContext(book, periodId, userId),
    );
    if (!checked.writable || checked.isCoordinator) {
      _refuse(
        operation,
        'Skore shows gradebook $gradebookId read-only to you in period '
        '${period.name} ($periodId) '
        '(${checked.isCoordinator ? 'coordinator mode' : 'writable 0'})',
      );
    }
    return _WriteTarget(
      userId: userId,
      workyear: current,
      gradebook: book,
      sheet: checked,
      period: period,
    );
  }

  /// Reads Skore again, and refuses a write into [evaluation] of
  /// [gradebook] with a [SmartschoolSkoreChangeRefusedError] that names
  /// [operation] unless:
  /// - [evaluation] is one of [gradebook] (checked before anything is
  ///   sent);
  /// - [_checkWritable] lets a write in its period;
  /// - Skore still lists it in that period ([getEvaluations]);
  /// - it does not come from the planner (`isPlannerEval` 1: Skore's web
  ///   client leaves those to the planner);
  /// - it is not published or scheduled, unless [allowPublished]
  ///   ([_checkPublication]).
  ///
  /// The checks every write into an evaluation makes first: the grades of
  /// #151, and the feedback of #152. Returns what they read: the target of
  /// [_checkWritable], the evaluation as Skore lists it now (with its
  /// cells), which the write then uses, and how messages name it.
  Future<({_WriteTarget target, SkoreEvaluation evaluation, String where})>
  _checkEvaluationWrite(
    String operation,
    SkoreGradebook gradebook,
    SkoreEvaluation evaluation, {
    required bool allowPublished,
  }) async {
    if (evaluation.gradebookId != gradebook.gradebookId) {
      _refuse(
        operation,
        'evaluation ${evaluation.id} is one of gradebook '
        '${evaluation.gradebookId}, not of gradebook ${gradebook.gradebookId}',
      );
    }
    final periodId = evaluation.periodId;
    final target = await _checkWritable(operation, gradebook, periodId);
    final book = target.gradebook;
    final inPeriod =
        'period ${target.period.name} ($periodId) of gradebook '
        '${book.gradebookId}';
    final current = (await getEvaluations(
      book,
      periodId,
    )).where((e) => e.id == evaluation.id).firstOrNull;
    if (current == null) {
      _refuse(
        operation,
        'Skore no longer lists evaluation ${evaluation.id} in $inPeriod',
      );
    }
    final where = 'evaluation ${current.id} ("${current.title}") in $inPeriod';
    if (current.isPlannerEvaluation) {
      _refuse(
        operation,
        '$where comes from the planner (isPlannerEval 1): Skore\'s web client '
        'leaves it to the planner',
      );
    }
    _checkPublication(
      operation,
      current,
      where,
      allowPublished: allowPublished,
    );
    return (target: target, evaluation: current, where: where);
  }

  /// Refuses a write into [evaluation], as Skore lists it right before the
  /// write ([where] names it), with a [SmartschoolSkoreChangeRefusedError]
  /// when its pupils see it or will: Skore's `public` `"1"`, published or
  /// scheduled ([SkorePublication.isPublic], whatever the time), unless
  /// [allowPublished].
  ///
  /// The rule of every write into an evaluation (`allowPublished`, `false`
  /// by default): the grades of #151 and the feedback of #152. What is
  /// written into a published evaluation is visible to its pupils at once,
  /// and the school sends them a notification.
  static void _checkPublication(
    String operation,
    SkoreEvaluation evaluation,
    String where, {
    required bool allowPublished,
  }) {
    final publication = evaluation.publication;
    if (!publication.isPublic || allowPublished) return;
    final scheduled = publication.state == SkorePublicationState.scheduled;
    _refuse(
      operation,
      '$where is ${scheduled ? 'scheduled to be published' : 'published'} '
      '(public "1", publicdatetime "${publication.rawPublicDateTime}"): its '
      'pupils see what is written in it ${scheduled ? 'from then on' : 'at once'}. '
      'Pass allowPublished: true to write in it anyway',
    );
  }

  /// Sends the save [method] with [params] in [gradebook], as user
  /// [userId], and returns the `result` of Skore's answer. With
  /// [retryAfterLogin] `false`, it goes out once, never again.
  ///
  /// A session Smartschool refuses for it, or an answer without a session,
  /// is rethrown as the [SmartschoolSessionExpiredError] it is: Skore did not
  /// handle the save. Any other failure, after the save went out (another
  /// HTTP status than `200`, an answer that is not JSON, a connection that
  /// dropped), is thrown as [unconfirmed] makes it from that failure.
  Future<dynamic> _save(
    String method,
    List<Object?> params, {
    required SkoreGradebook gradebook,
    required int userId,
    required bool retryAfterLogin,
    required SmartschoolSkoreSaveUnconfirmedError Function(Exception failure)
    unconfirmed,
  }) async {
    try {
      return await _rpc(
        method,
        params,
        userId: userId,
        workyearId: gradebook.workyearId,
        retryAfterLogin: retryAfterLogin,
      );
    } on SmartschoolSessionExpiredError {
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(unconfirmed(e), stackTrace);
    }
  }

  /// The course of [target]'s gradebook as Skore's "new evaluation" dialog
  /// offers it in the period ([where]): Skore's `getNewEvalDialogBox(0,
  /// owners, groupID, periodID)`, `[["2264", "Informaticawetenschappen (2
  /// uur)"]]` (seen live), with the name the save sends. Refuses a course it
  /// does not offer.
  Future<({int id, String name})> _newEvaluationCourse(
    String operation,
    _WriteTarget target,
    String where,
  ) async {
    final book = target.gradebook;
    final result = await _rpc(
      'getNewEvalDialogBox',
      [
        0,
        ['${book.gradebookId}'],
        '${book.groupId}',
        target.period.id,
      ],
      userId: target.userId,
      workyearId: book.workyearId,
    );
    const what = 'the courses of a new evaluation (getNewEvalDialogBox)';
    if (result is! List) {
      throw SmartschoolSkoreError(
        'Skore gave $what as ${SkoreRpc.jsonPreview(result)} instead of a '
        'list. Nothing was saved.',
      );
    }
    final courses = [
      for (final entry in result)
        if (entry is List && entry.length >= 2 && entry[1] is String)
          (
            id: SkoreRpc.id(entry[0], 'a course in $what'),
            name: (entry[1] as String).trim(),
          )
        else
          throw SmartschoolSkoreError(
            'Skore gave a course in $what as ${SkoreRpc.jsonPreview(entry)} '
            'instead of [id, name]. Nothing was saved.',
          ),
    ];
    final course = courses.where((c) => c.id == book.courseId).firstOrNull;
    if (course == null) {
      _refuse(
        operation,
        'Skore does not offer course ${book.courseId} for a new evaluation in '
        '$where (it offers '
        '${courses.isEmpty ? 'none' : courses.map((c) => c.id).join(', ')})',
      );
    }
    if (course.name.isEmpty) {
      throw SmartschoolSkoreError(
        'Skore gave course ${course.id} in $what no name. Nothing was saved.',
      );
    }
    return course;
  }

  /// The component of a new evaluation in [where]: the one of [components]
  /// with ID [componentId], or, without it, the one Skore's dialog picks
  /// (the second when there are exactly two, else `geen`). Refuses one
  /// Skore does not offer.
  static SkoreEvaluationComponent _component(
    String operation,
    List<SkoreEvaluationComponent> components,
    int? componentId,
    String where,
  ) {
    final offered = components.isEmpty
        ? 'none'
        : components.map((c) => '${c.id} ${c.name}').join(', ');
    if (componentId != null) {
      final chosen = components.where((c) => c.id == componentId).firstOrNull;
      if (chosen == null) {
        _refuse(
          operation,
          'component $componentId is not one Skore offers for $where (it '
          'offers $offered)',
        );
      }
      return chosen;
    }
    if (components.length == 2) return components[1];
    final none = components.where((c) => c.isNone).firstOrNull;
    if (none == null) {
      _refuse(
        operation,
        'Skore offers no "geen" component for $where to pick by default (it '
        'offers $offered): pass a componentId',
      );
    }
    return none;
  }

  /// Refuses a write: a [SmartschoolSkoreChangeRefusedError] that names
  /// [operation] and says [why].
  static Never _refuse(String operation, String why) =>
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: $why. Nothing was saved.',
      );

  static final _schoolYearName = RegExp(r'^(\d{4})\s*-\s*(\d{4})$');

  /// The first and last day of school year [workyear], from its name:
  /// `"2026-2027"` is 1 September 2026 to 31 August 2027, the days Skore's
  /// "new evaluation" dialog allows (seen live). A name not in that form is
  /// a [SmartschoolSkoreError]: the days are not known.
  static (DateTime, DateTime) _schoolYearDays(SkoreWorkyear workyear) {
    final match = _schoolYearName.firstMatch(workyear.name.trim());
    final start = match == null ? null : int.parse(match.group(1)!);
    if (start == null || int.parse(match!.group(2)!) != start + 1) {
      throw SmartschoolSkoreError(
        'Skore names the current school year "${workyear.name}" '
        '(${workyear.id}), not in the form 2026-2027: its first and last day '
        'are not known. Nothing was saved.',
      );
    }
    return (DateTime(start, 9, 1), DateTime(start + 1, 8, 31));
  }

  /// [day] as Skore writes a day: `2026-10-08`.
  static String _dayText(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ---------------------------------------------------------------------------
  // RPC
  // ---------------------------------------------------------------------------

  /// Calls [method] of Skore's gradebook RPC service with [params], as user
  /// [userId], for school year [workyearId] (`null`: Skore's current one),
  /// and returns the `result` of its answer.
  ///
  /// Only the methods in [rpcMethods]: any other is refused before anything
  /// is sent.
  ///
  /// Pass `retryAfterLogin: false` for a call that must not be sent twice
  /// (a create): when Smartschool refuses the session for it, it fails at
  /// once with a [SmartschoolSessionExpiredError], instead of being sent
  /// again after logging in (see [SmartschoolClient.postFormResponse]).
  Future<dynamic> _rpc(
    String method,
    List<Object?> params, {
    required int userId,
    required int? workyearId,
    bool retryAfterLogin = true,
  }) async {
    checkRpcMethod(method);
    final response = await _client.postFormResponse(
      _rpcPath,
      SkoreRpc.fields(
        method,
        params,
        session: SkoreRpc.session(
          DateTime.now(),
          extra: {'teacher': userId, 'restriction': 0},
          trailing: {if (workyearId != null) 'wy': '$workyearId'},
        ),
      ),
      retryAfterLogin: retryAfterLogin,
    );
    return SkoreRpc.result(_body(response, method), method);
  }

  /// The body of [response], the answer to RPC call [method]; any other
  /// status than `200` is a [SmartschoolSkoreError]. Also a redirect: the
  /// admin side of Skore sends a request it refuses on to the start page
  /// (#91); what the gradebook answers an account without one was not seen.
  static String _body(Response<String> response, String method) {
    final status = response.statusCode;
    if (status != 200) {
      throw SmartschoolSkoreError(
        'Skore answered the RPC call $method of its gradebook with HTTP '
        '$status.',
      );
    }
    return response.data ?? '';
  }

  /// The decoded JSON of [response], the answer of Skore's REST API to
  /// [what]. Any other status than `200` is a [SmartschoolSkoreError] that
  /// names the `title` and `detail` of Skore's error answer, when it is JSON
  /// with them; so is an answer that is not JSON.
  static dynamic _restJson(Response<String> response, String what) {
    final status = response.statusCode;
    if (status != 200) {
      final problem = _problem(response.data);
      throw SmartschoolSkoreError(
        'Skore answered $what with HTTP $status'
        '${problem == null ? '' : ': $problem'}.',
      );
    }
    return SkoreRpc.decodeJson(response.data ?? '', what);
  }

  /// The `title` and `detail` of an error answer of Skore's REST API
  /// ([body]), or `null` when it has neither.
  static String? _problem(String? body) {
    try {
      final json = jsonDecode(body ?? '');
      if (json is! Map) return null;
      final parts = [
        for (final key in ['title', 'detail'])
          if (json[key] is String && (json[key] as String).trim().isNotEmpty)
            (json[key] as String).trim(),
      ];
      return parts.isEmpty ? null : SkoreRpc.preview(parts.join(': '));
    } on FormatException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Parses the `result` of `getNavigation(userID, 0)`, asked for school
  /// year [workyearId] (`null`: Skore's current one).
  ///
  /// The answer is `{navigation, workyears, currentWorkyear}`:
  /// - `workyears`: `[["24", "2026-2027"], ["22", "2025-2026"], ...]`;
  /// - `currentWorkyear`: the school year of the answer (`"24"`; the one
  ///   asked for, also when Skore does not offer it);
  /// - `navigation`: the tree of the left panel. A node has `raw` (its
  ///   name), `content`, `icon`, `children`, and, below the top (the report
  ///   models), `crum.ids`: `[modelId, groupId]` for a group of classes,
  ///   `[modelId, groupId, classId]` for a class. Its `data` holds the
  ///   gradebooks: `{coursename, data: {ownerID, userID, classID, groupID,
  ///   modelID, courseID, structureID}, part, colleagues, icon, ...}`.
  ///
  /// A group node repeats gradebooks of its classes: the gradebooks are
  /// taken from the class nodes only, each once (by `ownerID`), in the order
  /// of the tree.
  ///
  /// With [workyearId], a school year that is not among `workyears` is
  /// refused with an [ArgumentError]. Anything not in this shape is refused
  /// with a [SmartschoolSkoreError].
  static SkoreGradebookYear parseNavigation(dynamic result, {int? workyearId}) {
    const what = 'the gradebooks (getNavigation)';
    if (result is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave $what as ${result.runtimeType} instead of an object.',
      );
    }
    final workyears = _workyears(result['workyears']);
    final current = SkoreRpc.tryId(result['currentWorkyear']);
    if (workyearId != null && !workyears.any((y) => y.id == workyearId)) {
      throw ArgumentError.value(
        workyearId,
        'workyearId',
        'not a school year Skore offers (it offers '
            '${workyears.map((y) => '${y.id} ${y.name}').join(', ')})',
      );
    }
    if (current == null || (workyearId != null && current != workyearId)) {
      throw SmartschoolSkoreError(
        'Skore gave $what for school year '
        '${SkoreRpc.jsonPreview(result['currentWorkyear'])}'
        '${workyearId == null ? '' : ' instead of $workyearId'}.',
      );
    }
    final workyear = workyears.where((y) => y.id == current).firstOrNull;
    if (workyear == null) {
      throw SmartschoolSkoreError(
        'Skore gave $what for school year $current, which is not among the '
        'school years it offers.',
      );
    }

    final navigation = result['navigation'];
    if (navigation is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the tree of $what as '
        '${SkoreRpc.jsonPreview(navigation)} instead of a list.',
      );
    }
    final gradebooks = <int, SkoreGradebook>{};
    for (final node in navigation) {
      _collectGradebooks(
        node,
        gradebooks,
        workyearId: current,
        names: const [],
      );
    }
    return SkoreGradebookYear(
      workyear: workyear,
      workyears: workyears,
      gradebooks: [...gradebooks.values],
    );
  }

  /// The school years of `getNavigation`: `[["24", "2026-2027"], ...]`.
  static List<SkoreWorkyear> _workyears(Object? workyears) {
    if (workyears is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the school years of its gradebook as '
        '${SkoreRpc.jsonPreview(workyears)} instead of a list.',
      );
    }
    return [
      for (final year in workyears)
        if (year is List && year.length >= 2)
          SkoreWorkyear(
            id: SkoreRpc.id(year[0], 'a school year'),
            name: '${year[1] ?? ''}'.trim(),
          )
        else
          throw SmartschoolSkoreError(
            'Skore gave a school year as ${SkoreRpc.jsonPreview(year)} '
            'instead of [id, name].',
          ),
    ];
  }

  /// Adds the gradebooks of [node] and the nodes under it to [gradebooks],
  /// by ID; [names] are the names of the nodes above it (model, group).
  static void _collectGradebooks(
    Object? node,
    Map<int, SkoreGradebook> gradebooks, {
    required int workyearId,
    required List<String> names,
  }) {
    if (node is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave a node of the gradebooks tree as '
        '${SkoreRpc.jsonPreview(node)} instead of an object.',
      );
    }
    final name = _nodeName(node);
    final crum = node['crum'];
    final ids = crum is Map ? crum['ids'] : null;
    if (ids is List && ids.length == 3) {
      // A class: its gradebooks.
      final data = node['data'];
      if (data is! List) {
        throw SmartschoolSkoreError(
          'Skore gave the gradebooks of class "$name" as '
          '${SkoreRpc.jsonPreview(data)} instead of a list.',
        );
      }
      for (final entry in data) {
        final gradebook = _gradebook(
          entry,
          className: name,
          modelName: names.isNotEmpty ? names.first : '',
          groupName: names.length > 1 ? names[1] : '',
          workyearId: workyearId,
        );
        gradebooks.putIfAbsent(gradebook.gradebookId, () => gradebook);
      }
    }
    final children = node['children'];
    if (children == null) return;
    if (children is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the nodes under "$name" in its gradebooks tree as '
        '${SkoreRpc.jsonPreview(children)} instead of a list.',
      );
    }
    for (final child in children) {
      _collectGradebooks(
        child,
        gradebooks,
        workyearId: workyearId,
        names: [...names, name],
      );
    }
  }

  /// A gradebook [entry] of the `data` of a class node.
  static SkoreGradebook _gradebook(
    Object? entry, {
    required String className,
    required String modelName,
    required String groupName,
    required int workyearId,
  }) {
    final data = entry is Map ? entry['data'] : null;
    if (entry is! Map || data is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave a gradebook of class "$className" as '
        '${SkoreRpc.jsonPreview(entry)} instead of an object with its IDs.',
      );
    }
    final gradebookId = SkoreRpc.id(data['ownerID'], 'a gradebook');
    int id(String key) =>
        SkoreRpc.id(data[key], 'the $key of gradebook $gradebookId');
    final part = entry['part'];
    if (part != null && part is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the teachers of gradebook $gradebookId as '
        '${SkoreRpc.jsonPreview(part)} instead of a list.',
      );
    }
    return SkoreGradebook(
      gradebookId: gradebookId,
      teacherId: id('userID'),
      modelId: id('modelID'),
      modelName: modelName,
      groupId: id('groupID'),
      groupName: groupName,
      classId: id('classID'),
      className: className,
      courseId: id('courseID'),
      courseName: '${entry['coursename'] ?? ''}'.trim(),
      workyearId: workyearId,
      teacherNames: [
        for (final name in (part as List?) ?? const [])
          if ('$name'.trim().isNotEmpty) '$name'.trim(),
      ],
    );
  }

  /// The name of a tree node: its `raw`, or the text of its `content` (an
  /// icon, `&nbsp;` and the name).
  static String _nodeName(Map<dynamic, dynamic> node) {
    final raw = node['raw'];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    final content = node['content'];
    if (content is! String) return '';
    return html_parser.parseFragment(content).text?.trim() ?? '';
  }

  /// Parses [gradebook] from the `result` of Skore's
  /// `init(courses, owners, userID, pathIds, 0, 0)` ([init]) and, when the
  /// gradebook has periods, that of `getGradebookContext(...)` for its
  /// active period ([context]).
  ///
  /// `init` gives (the parts read):
  /// - `periods`, read by [parsePeriods];
  /// - `activePeriodE`: the index of the period Skore opens the gradebook
  ///   on (the first period when it is not an index of one);
  /// - `left_0`: the rows of the gradebook, whose `stream` [parsePupils]
  ///   reads;
  /// - `ownerMap`: a list of `{courseID, groupID, coursename, ownerID,
  ///   classID}`, which must hold the gradebook in its class; its
  ///   `coursename` is the course name without the grade.
  ///
  /// `getGradebookContext` gives `{"writable": 1, "coordinator": 0,
  /// "classId": 2440, "owners": [32508], ...}`, which must name the
  /// gradebook and its class. Without periods, [context] is not read (Skore
  /// is not asked) and the gradebook is not [SkoreGradebookSheet.writable].
  ///
  /// Anything not in this shape, or about another gradebook, is refused
  /// with a [SmartschoolSkoreError].
  static SkoreGradebookSheet parseGradebook(
    SkoreGradebook gradebook,
    dynamic init, {
    dynamic context,
  }) => _withContext(_parseInit(gradebook, init), context);

  /// [gradebook] as the `result` of `init` ([init]) gives it, not yet
  /// [SkoreGradebookSheet.writable]; see [parseGradebook].
  static SkoreGradebookSheet _parseInit(
    SkoreGradebook gradebook,
    dynamic init,
  ) {
    final gradebookId = gradebook.gradebookId;
    if (init is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave gradebook $gradebookId (init) as ${init.runtimeType} '
        'instead of an object.',
      );
    }
    final ownerMap = init['ownerMap'];
    if (ownerMap is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the gradebooks of gradebook $gradebookId (init) as '
        '${SkoreRpc.jsonPreview(ownerMap)} instead of a list.',
      );
    }
    final owner = ownerMap
        .whereType<Map<dynamic, dynamic>>()
        .where((o) => SkoreRpc.tryId(o['ownerID']) == gradebookId)
        .firstOrNull;
    if (owner == null ||
        SkoreRpc.tryId(owner['classID']) != gradebook.classId) {
      throw SmartschoolSkoreError(
        'Skore answered init for gradebook $gradebookId (class '
        '${gradebook.classId}) with another gradebook: '
        '${SkoreRpc.jsonPreview(ownerMap)}.',
      );
    }

    final periods = parsePeriods(init['periods']);
    final index = SkoreRpc.tryId(init['activePeriodE']) ?? 0;
    final rows = init['left_0'];
    return SkoreGradebookSheet(
      gradebook: gradebook,
      courseName: '${owner['coursename'] ?? ''}'.trim(),
      periods: periods,
      activePeriod: periods.isEmpty
          ? null
          : periods[index >= 0 && index < periods.length ? index : 0],
      pupils: parsePupils(rows is Map ? rows['stream'] : rows, gradebook),
    );
  }

  /// [sheet] with what the `result` of `getGradebookContext` ([context])
  /// says about it; [sheet] itself when it has no periods.
  static SkoreGradebookSheet _withContext(
    SkoreGradebookSheet sheet,
    dynamic context,
  ) {
    if (sheet.activePeriod == null) return sheet;
    final gradebook = sheet.gradebook;
    final gradebookId = gradebook.gradebookId;
    final owners = context is Map ? context['owners'] : null;
    if (context is! Map ||
        SkoreRpc.tryId(context['classId']) != gradebook.classId ||
        owners is! List ||
        !owners.any((o) => SkoreRpc.tryId(o) == gradebookId)) {
      throw SmartschoolSkoreError(
        'Skore answered getGradebookContext for gradebook $gradebookId '
        '(class ${gradebook.classId}) with ${SkoreRpc.jsonPreview(context)}.',
      );
    }
    return SkoreGradebookSheet(
      gradebook: gradebook,
      courseName: sheet.courseName,
      periods: sheet.periods,
      activePeriod: sheet.activePeriod,
      pupils: sheet.pupils,
      writable: SkoreRpc.tryId(context['writable']) == 1,
      isCoordinator: SkoreRpc.tryId(context['coordinator']) == 1,
    );
  }

  /// Parses the `periods` of `init`: `[{"name": "DW1", "fullname": "DW1",
  /// "id": "1704", "info": "<p>...</p>", "open": 1, "timestamp":
  /// "2026-12-18T20:00:00+0100", "categoryMode": 1, "virtual": "0",
  /// "scope": "1", "lockIcon": 0}]`.
  ///
  /// An empty `timestamp` gives a period without [SkoreGradebookPeriod.closesAt];
  /// one that is not a date with its offset is refused, as is anything else
  /// not in this shape, with a [SmartschoolSkoreError].
  static List<SkoreGradebookPeriod> parsePeriods(dynamic periods) {
    if (periods is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the periods of a gradebook as '
        '${SkoreRpc.jsonPreview(periods)} instead of a list.',
      );
    }
    return [for (final period in periods) _period(period)];
  }

  static SkoreGradebookPeriod _period(Object? period) {
    if (period is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave a period of a gradebook as '
        '${SkoreRpc.jsonPreview(period)} instead of an object.',
      );
    }
    final id = SkoreRpc.id(period['id'], 'a period');
    final timestamp = '${period['timestamp'] ?? ''}'.trim();
    final DateTime? closesAt;
    if (timestamp.isEmpty) {
      closesAt = null;
    } else {
      final parsed = DateTime.tryParse(timestamp);
      if (parsed == null || !parsed.isUtc) {
        throw SmartschoolSkoreError(
          'Skore gave period $id the closing time "$timestamp", which is not '
          'a date and time with its offset.',
        );
      }
      closesAt = parsed;
    }
    final name = '${period['name'] ?? ''}'.trim();
    final fullName = '${period['fullname'] ?? ''}'.trim();
    return SkoreGradebookPeriod(
      id: id,
      name: name,
      fullName: fullName.isNotEmpty ? fullName : name,
      isOpen: SkoreRpc.tryId(period['open']) == 1,
      closesAt: closesAt,
      info: '${period['info'] ?? ''}',
      categoryMode: SkoreRpc.tryId(period['categoryMode']) ?? 0,
    );
  }

  /// Parses the pupils of [gradebook] from [stream], the `stream` of the
  /// rows of `init` (`left_0`): one cell per row, such as
  /// `{"c": 0, "r": "pupil_1201_2440", "v": "<span ...>1.  Last, First</span>"}`,
  /// whose `span` carries the name first name first, in base64, as its
  /// `alternate`.
  ///
  /// A pupil is a row `pupil_<pupilId>_<classId>` of the gradebook's class.
  /// The class average (`clavg_<classId>`), the group average and rows of
  /// other classes are left out. The text is `1.  Last, First` (the class
  /// number first), or `- Last, First` without a class number; a row whose
  /// first `span` has the class `gbc_hidden` is an inactive pupil.
  ///
  /// Anything not in this shape is refused with a [SmartschoolSkoreError].
  static List<SkoreGradebookPupil> parsePupils(
    dynamic stream,
    SkoreGradebook gradebook,
  ) {
    if (stream is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the rows of gradebook ${gradebook.gradebookId} as '
        '${SkoreRpc.jsonPreview(stream)} instead of a list.',
      );
    }
    final pupils = <SkoreGradebookPupil>[];
    final seen = <int>{};
    for (final cell in stream) {
      if (cell is! Map) {
        throw SmartschoolSkoreError(
          'Skore gave a row of gradebook ${gradebook.gradebookId} as '
          '${SkoreRpc.jsonPreview(cell)} instead of an object.',
        );
      }
      final key = '${cell['r'] ?? ''}';
      final parts = key.split('_');
      if (parts.first != 'pupil') continue;
      if (parts.length != 3) {
        throw SmartschoolSkoreError(
          'Skore gave gradebook ${gradebook.gradebookId} the row "$key".',
        );
      }
      final id = SkoreRpc.id(parts[1], 'the pupil of row "$key"');
      final classId = SkoreRpc.id(parts[2], 'the class of row "$key"');
      if (classId != gradebook.classId || !seen.add(id)) continue;
      pupils.add(_pupil(id, classId, '${cell['v'] ?? ''}', key));
    }
    return pupils;
  }

  static final _numbered = RegExp(r'^(\d+)\s*\.\s*(.*)$', dotAll: true);
  static final _unnumbered = RegExp(r'^-\s*(.*)$', dotAll: true);

  static SkoreGradebookPupil _pupil(
    int id,
    int classId,
    String html,
    String key,
  ) {
    final span = html_parser.parseFragment(html).querySelector('span');
    final text = (span?.text ?? '').replaceAll(' ', ' ').trim();
    final numbered = _numbered.firstMatch(text);
    final unnumbered = numbered == null ? _unnumbered.firstMatch(text) : null;
    final name = (numbered?.group(2) ?? unnumbered?.group(1) ?? '').trim();
    if (span == null || name.isEmpty) {
      throw SmartschoolSkoreError(
        'Skore gave row "$key" no pupil name in the shape "1.  Last, First": '
        '${SkoreRpc.preview(html)}',
      );
    }
    return SkoreGradebookPupil(
      id: id,
      classId: classId,
      number: numbered == null ? null : int.parse(numbered.group(1)!),
      name: name,
      displayName: _decodedName(span.attributes['alternate']) ?? name,
      isActive: !span.classes.contains('gbc_hidden'),
    );
  }

  /// The name in [alternate], base64 UTF-8 (`"SmFuIEphbnNzZW5z"` → `"Jan
  /// Janssens"`), or `null` when there is none or it is not base64.
  static String? _decodedName(String? alternate) {
    if (alternate == null || alternate.trim().isEmpty) return null;
    try {
      final name = utf8.decode(base64.decode(alternate.trim())).trim();
      return name.isEmpty ? null : name;
    } on FormatException {
      return null;
    }
  }

  /// Parses the `result` of `getEvaluations(...)` for period [periodId] of
  /// [gradebook], with the publication state at [now] (#149).
  ///
  /// The answer is `{head, max, details, periodStatus, evalType, archive}`;
  /// read are:
  /// - `head`, one entry per evaluation: `{"refID": "395742",
  ///   "evaluationID": "395742", "colID": "A", "title": ..., "short": null,
  ///   "date": "2026-09-30", "max": 100, "componentID": 2, "component":
  ///   "DW", "evaltype": 1, "courseID": "2264", "coursename": ...,
  ///   "periodID": 1704, "ownerID": "32508", "isPlannerEval": 0, "public":
  ///   "1", "publicdatetime": "2026-10-09T08:00:00", ...}` ([parsePublication]
  ///   reads the last two). Entries of another gradebook (`ownerID`) are
  ///   left out; one of another period is refused.
  /// - `details.stream`, one cell per row and evaluation, such as
  ///   `{"c": "395742", "r": "pupil_9200_2440", "v": "...", "p": [1, 0,
  ///   "395742", "32508", 395742]}`, whose `v` is HTML
  ///   (`<div class="gbc" raw="79">79</div>...`). The grade is the `raw`
  ///   of `div.gbc` (`""`: none); a `span` with the class `gbc_message`
  ///   marks feedback. `p` is `[1, catType, evaluationID, ownerID, ...]`.
  ///   The rows `clavg_<classId>` and `gravg_<groupId>` hold the averages.
  ///   Rows of other classes, and of another gradebook (`p[3]`), are left
  ///   out; a pupil's first cell of an evaluation counts. For a period
  ///   without evaluations, Skore gives an empty `head` and the stream `1`
  ///   (seen live): no evaluations.
  ///
  /// Anything not in this shape is refused with a [SmartschoolSkoreError].
  static List<SkoreEvaluation> parseEvaluations(
    dynamic result,
    SkoreGradebook gradebook,
    int periodId, {
    required DateTime now,
  }) {
    final what =
        'the evaluations of period $periodId of gradebook '
        '${gradebook.gradebookId} (getEvaluations)';
    if (result is! Map) {
      throw SmartschoolSkoreError(
        'Skore gave $what as ${result.runtimeType} instead of an object.',
      );
    }
    final head = result['head'];
    if (head is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the evaluations in $what as '
        '${SkoreRpc.jsonPreview(head)} instead of a list.',
      );
    }
    final details = result['details'];
    final stream = details is Map ? details['stream'] : null;
    // A period without evaluations has the stream `1` (seen live).
    if (head.isEmpty && (stream is List || stream == 1)) return const [];
    if (stream is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the grades in $what as ${SkoreRpc.jsonPreview(details)} '
        'instead of an object with a stream.',
      );
    }

    // The gradebook's evaluations, in Skore's order, each once.
    final entries = <int, Map<dynamic, dynamic>>{};
    for (final entry in head) {
      if (entry is! Map) {
        throw SmartschoolSkoreError(
          'Skore gave an evaluation in $what as '
          '${SkoreRpc.jsonPreview(entry)} instead of an object.',
        );
      }
      final id = SkoreRpc.id(entry['refID'], 'an evaluation');
      final owner = SkoreRpc.id(
        entry['ownerID'],
        'the gradebook of evaluation $id',
      );
      if (owner != gradebook.gradebookId) continue;
      final period = SkoreRpc.id(
        entry['periodID'],
        'the period of evaluation $id',
      );
      if (period != periodId) {
        throw SmartschoolSkoreError(
          'Skore answered $what with evaluation $id of period $period.',
        );
      }
      entries.putIfAbsent(id, () => entry);
    }
    final results = _results(stream, gradebook, entries.keys.toSet());
    return [
      for (final MapEntry(key: id, value: entry) in entries.entries)
        _evaluation(id, entry, gradebook, periodId, results[id]!, now),
    ];
  }

  static SkoreEvaluation _evaluation(
    int id,
    Map<dynamic, dynamic> entry,
    SkoreGradebook gradebook,
    int periodId,
    SkoreEvaluationResults results,
    DateTime now,
  ) {
    final title = entry['title'];
    if (title is! String) {
      throw SmartschoolSkoreError(
        'Skore gave evaluation $id the title ${SkoreRpc.jsonPreview(title)}.',
      );
    }
    final short = entry['short'];
    if (short != null && short is! String) {
      throw SmartschoolSkoreError(
        'Skore gave evaluation $id the short name '
        '${SkoreRpc.jsonPreview(short)}.',
      );
    }
    final shortName = (short as String?)?.trim() ?? '';
    final component = entry['component'];
    final typeCode = SkoreRpc.id(
      entry['evaltype'],
      'the type of evaluation $id',
    );
    return SkoreEvaluation(
      id: id,
      evaluationId: SkoreRpc.id(
        entry['evaluationID'],
        'the evaluationID of evaluation $id',
      ),
      gradebookId: gradebook.gradebookId,
      periodId: periodId,
      column: '${entry['colID'] ?? ''}'.trim(),
      title: title.trim(),
      shortName: shortName.isEmpty ? null : shortName,
      date: _day(entry['date'], id),
      max: _max(entry['max'], id),
      componentId: entry['componentID'] == null || entry['componentID'] == ''
          ? 0
          : SkoreRpc.id(
              entry['componentID'],
              'the component of evaluation $id',
            ),
      componentName: component is String ? component.trim() : '',
      type: switch (typeCode) {
        1 => SkoreEvaluationType.points,
        2 => SkoreEvaluationType.scale,
        _ => SkoreEvaluationType.unknown,
      },
      typeCode: typeCode,
      courseId: SkoreRpc.id(entry['courseID'], 'the course of evaluation $id'),
      courseName: '${entry['coursename'] ?? ''}'.trim(),
      isPlannerEvaluation: SkoreRpc.tryId(entry['isPlannerEval']) == 1,
      publication: parsePublication(
        entry['public'],
        entry['publicdatetime'],
        now: now,
      ),
      results: results,
    );
  }

  static final _isoDay = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// The `date` of evaluation [id] (`"2026-09-30"`), at local midnight.
  static DateTime _day(Object? date, int id) {
    final match = date is String ? _isoDay.firstMatch(date.trim()) : null;
    final day = match == null
        ? null
        : DateTime(
            int.parse(match.group(1)!),
            int.parse(match.group(2)!),
            int.parse(match.group(3)!),
          );
    if (day == null ||
        day.month != int.parse(match!.group(2)!) ||
        day.day != int.parse(match.group(3)!)) {
      throw SmartschoolSkoreError(
        'Skore gave evaluation $id the date ${SkoreRpc.jsonPreview(date)}, '
        'which is not a day in the form 2026-09-30.',
      );
    }
    return day;
  }

  /// The `max` of evaluation [id]: a number (or one as a string), or `null`
  /// for none (`null` or `""`).
  static num? _max(Object? max, int id) {
    if (max == null) return null;
    if (max is num) return max;
    if (max is String) {
      if (max.trim().isEmpty) return null;
      final parsed = num.tryParse(max.trim());
      if (parsed != null) return parsed;
    }
    throw SmartschoolSkoreError(
      'Skore gave evaluation $id the highest grade '
      '${SkoreRpc.jsonPreview(max)}.',
    );
  }

  /// The grades of the evaluations [evaluationIds] of [gradebook] in
  /// [stream] (the `details.stream` of `getEvaluations`), by evaluation; see
  /// [parseEvaluations].
  static Map<int, SkoreEvaluationResults> _results(
    List<dynamic> stream,
    SkoreGradebook gradebook,
    Set<int> evaluationIds,
  ) {
    final grades = {for (final id in evaluationIds) id: <int, SkoreGrade>{}};
    final classAverages = <int, String?>{};
    final groupAverages = <int, String?>{};
    for (final cell in stream) {
      if (cell is! Map) {
        throw SmartschoolSkoreError(
          'Skore gave a grade cell of gradebook ${gradebook.gradebookId} as '
          '${SkoreRpc.jsonPreview(cell)} instead of an object.',
        );
      }
      final evaluationId = SkoreRpc.tryId(cell['c']);
      if (evaluationId == null || !evaluationIds.contains(evaluationId)) {
        continue;
      }
      final key = '${cell['r'] ?? ''}';
      final parts = key.split('_');
      switch (parts.first) {
        case 'pupil':
          if (parts.length != 3) {
            throw SmartschoolSkoreError(
              'Skore gave gradebook ${gradebook.gradebookId} the grade row '
              '"$key".',
            );
          }
          final pupilId = SkoreRpc.id(parts[1], 'the pupil of row "$key"');
          final classId = SkoreRpc.id(parts[2], 'the class of row "$key"');
          if (classId != gradebook.classId) continue;
          final p = cell['p'];
          if (p is! List || p.length < 4) {
            throw SmartschoolSkoreError(
              'Skore gave the cell of row "$key" in evaluation $evaluationId '
              'the parameters ${SkoreRpc.jsonPreview(p)}.',
            );
          }
          if (SkoreRpc.tryId(p[3]) != gradebook.gradebookId) continue;
          final cells = grades[evaluationId]!;
          if (cells.containsKey(pupilId)) continue;
          final (raw, feedback) = _cell(cell['v'], key, evaluationId);
          cells[pupilId] = SkoreGrade(
            pupilId: pupilId,
            classId: classId,
            grade: raw,
            hasFeedback: feedback,
            categoryType: SkoreRpc.id(p[1], 'the category of row "$key"'),
            cellEvaluationId: SkoreRpc.id(p[2], 'the evaluation of row "$key"'),
          );
        case 'clavg' when parts.length == 2:
          if (SkoreRpc.tryId(parts[1]) != gradebook.classId) continue;
          if (classAverages.containsKey(evaluationId)) continue;
          classAverages[evaluationId] = _cell(cell['v'], key, evaluationId).$1;
        case 'gravg' when parts.length == 2:
          if (SkoreRpc.tryId(parts[1]) != gradebook.groupId) continue;
          if (groupAverages.containsKey(evaluationId)) continue;
          groupAverages[evaluationId] = _cell(cell['v'], key, evaluationId).$1;
      }
    }
    return {
      for (final id in evaluationIds)
        id: SkoreEvaluationResults(
          evaluationId: id,
          grades: [...grades[id]!.values],
          classAverage: classAverages[id],
          groupAverage: groupAverages[id],
        ),
    };
  }

  /// The value of a grade cell [html] of row [key] (the `raw` of its
  /// `div.gbc`, `null` for `""`) and whether it is marked with feedback.
  static (String?, bool) _cell(Object? html, String key, int evaluationId) {
    final fragment = html is String ? html_parser.parseFragment(html) : null;
    final raw = fragment?.querySelector('div.gbc')?.attributes['raw'];
    if (fragment == null || raw == null) {
      throw SmartschoolSkoreError(
        'Skore gave the cell of row "$key" in evaluation $evaluationId no '
        'value (a div.gbc with its raw): '
        '${html is String ? SkoreRpc.preview(html) : SkoreRpc.jsonPreview(html)}',
      );
    }
    final value = raw.trim();
    return (
      value.isEmpty ? null : value,
      fragment.querySelector('span.gbc_message') != null,
    );
  }

  /// Parses the publication of an evaluation from Skore's `public`
  /// ([public]: `"1"` or `"0"`, also as a number) and `publicdatetime`
  /// ([publicDateTime]: a time in Belgium without an offset,
  /// `"2026-10-09T08:00:00"`, or `""`/`null` for none), with its state at
  /// [now] (#149).
  ///
  /// Seen live: `"0"` with `""` for an evaluation that is not published
  /// (also for one just saved with `public` 0 and `publicdatetime` `""`, as
  /// [createEvaluation] saves it, #150), and `"1"` with the time it is
  /// published from. `"1"` without a time was not seen, and counts as
  /// published. A time with an offset is taken as it is.
  ///
  /// Anything else is refused with a [SmartschoolSkoreError].
  static SkorePublication parsePublication(
    Object? public,
    Object? publicDateTime, {
    required DateTime now,
  }) {
    final rawPublic = switch (public) {
      int() => '$public',
      String() => public.trim(),
      _ => null,
    };
    if (rawPublic != '0' && rawPublic != '1') {
      throw SmartschoolSkoreError(
        'Skore gave an evaluation the publication flag '
        '${SkoreRpc.jsonPreview(public)} instead of "0" or "1".',
      );
    }
    final rawTime = publicDateTime is String ? publicDateTime.trim() : '';
    final at = rawTime.isEmpty ? null : _belgianTime(rawTime);
    if ((publicDateTime != null && publicDateTime is! String) ||
        (rawTime.isNotEmpty && at == null)) {
      throw SmartschoolSkoreError(
        'Skore gave an evaluation the publication time '
        '${SkoreRpc.jsonPreview(publicDateTime)}, which is not a date and '
        'time.',
      );
    }
    final read = SkorePublication(
      state: SkorePublicationState.notPublished,
      at: at,
      rawPublic: rawPublic!,
      rawPublicDateTime: rawTime,
    );
    return SkorePublication(
      state: read.stateAt(now),
      at: at,
      rawPublic: rawPublic,
      rawPublicDateTime: rawTime,
    );
  }

  /// Parses the `result` of `getPosComponents(0, periodID, groupID,
  /// courseID, pathIds)` (#150): `[[0, "geen"], ["2", "DW"]]` (seen live),
  /// `[id, short name]` per component, `geen` (none) with the ID `0`.
  ///
  /// Anything not in this shape is refused with a [SmartschoolSkoreError].
  static List<SkoreEvaluationComponent> parseComponents(dynamic result) {
    const what = 'the components of a new evaluation (getPosComponents)';
    if (result is! List) {
      throw SmartschoolSkoreError(
        'Skore gave $what as ${SkoreRpc.jsonPreview(result)} instead of a '
        'list.',
      );
    }
    return [
      for (final entry in result)
        if (entry is List &&
            entry.length >= 2 &&
            entry[1] is String &&
            (SkoreRpc.tryId(entry[0]) ?? -1) >= 0)
          SkoreEvaluationComponent(
            id: SkoreRpc.tryId(entry[0])!,
            name: (entry[1] as String).trim(),
          )
        else
          throw SmartschoolSkoreError(
            'Skore gave a component in $what as '
            '${SkoreRpc.jsonPreview(entry)} instead of [id, name].',
          ),
    ];
  }

  static final _wallClock = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$',
  );

  /// [text], a time in Belgium (`"2026-10-09T08:00:00"`), in UTC; or, with
  /// an offset, the time it names. `null` when it is neither.
  ///
  /// Belgium is on CET (UTC+1), and on CEST (UTC+2) from the last Sunday
  /// of March to the last Sunday of October, 01:00 UTC each. In the hour
  /// that comes twice in October, the first; a time in the hour skipped in
  /// March counts as CET.
  static DateTime? _belgianTime(String text) {
    final match = _wallClock.firstMatch(text);
    if (match == null) {
      final parsed = DateTime.tryParse(text);
      return parsed != null && parsed.isUtc ? parsed : null;
    }
    final [year, month, day, hour, minute] = [
      for (var i = 1; i <= 5; i++) int.parse(match.group(i)!),
    ];
    final second = int.parse(match.group(6) ?? '0');
    final wall = DateTime.utc(year, month, day, hour, minute, second);
    if (wall.month != month ||
        wall.day != day ||
        wall.hour != hour ||
        wall.minute != minute ||
        wall.second != second) {
      return null;
    }
    final summer = wall.subtract(const Duration(hours: 2));
    if (_isBelgianSummerTime(summer)) return summer;
    return wall.subtract(const Duration(hours: 1));
  }

  /// Whether Belgium is on summer time (CEST) at [utc].
  static bool _isBelgianSummerTime(DateTime utc) {
    DateTime lastSunday(int month) {
      final last = DateTime.utc(utc.year, month + 1, 0); // its last day
      return last.subtract(Duration(days: last.weekday % 7));
    }

    const switchHour = Duration(hours: 1);
    final start = lastSunday(DateTime.march).add(switchHour);
    final end = lastSunday(DateTime.october).add(switchHour);
    return !utc.isBefore(start) && utc.isBefore(end);
  }

  /// Parses the answer of Skore's REST API to the feedback of pupil
  /// [pupilId] on evaluation [evaluationId] (#149): a list of
  /// `{"id": "1d44ef86-...", "evaluationId": "4069_395742", "student":
  /// {"id": "4069_9200_0", "name": {...}, ...}, "teacher": {"id":
  /// "4069_146_0", "name": {"startingWithFirstName": ...}, ...}, "text":
  /// "...", "createdAt": "2026-10-08T09:49:36+02:00", "changedAt": ...,
  /// "attachments": [], "capabilities": {"can_read": true, "can_edit":
  /// true}}`, in Skore's order.
  ///
  /// Feedback about another pupil or evaluation, or anything not in this
  /// shape, is refused with a [SmartschoolSkoreError].
  static List<SkoreFeedback> parseFeedback(
    dynamic json, {
    required int pupilId,
    required int evaluationId,
  }) {
    final what = 'the feedback of pupil $pupilId on evaluation $evaluationId';
    if (json is! List) {
      throw SmartschoolSkoreError(
        'Skore gave $what as ${SkoreRpc.jsonPreview(json)} instead of a list.',
      );
    }
    return [
      for (final item in json)
        _feedback(item, what, pupilId: pupilId, evaluationId: evaluationId),
    ];
  }

  static SkoreFeedback _feedback(
    Object? item,
    String what, {
    required int pupilId,
    required int evaluationId,
  }) {
    final id = item is Map ? item['id'] : null;
    final text = item is Map ? item['text'] : null;
    if (item is! Map || id is! String || id.trim().isEmpty || text is! String) {
      throw SmartschoolSkoreError(
        'Skore gave a feedback in $what without its ID or text (with '
        '${item is Map ? 'the fields ${item.keys.join(', ')}' : item.runtimeType}).',
      );
    }
    final student = item['student'];
    final teacher = item['teacher'];
    final studentId = _middleId(student is Map ? student['id'] : null);
    final teacherId = _middleId(teacher is Map ? teacher['id'] : null);
    if (studentId != pupilId || teacherId == null) {
      throw SmartschoolSkoreError(
        'Skore gave feedback $id in $what for pupil '
        '${SkoreRpc.jsonPreview(student is Map ? student['id'] : student)} '
        'by teacher '
        '${SkoreRpc.jsonPreview(teacher is Map ? teacher['id'] : teacher)}.',
      );
    }
    final evaluation = item['evaluationId'];
    if (evaluation != null && _middleId(evaluation) != evaluationId) {
      throw SmartschoolSkoreError(
        'Skore gave feedback $id in $what for evaluation '
        '${SkoreRpc.jsonPreview(evaluation)}.',
      );
    }
    final name = teacher is Map ? teacher['name'] : null;
    final teacherName = name is Map ? name['startingWithFirstName'] : null;
    final attachments = item['attachments'];
    if (attachments != null && attachments is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the attachments of feedback $id as '
        '${SkoreRpc.jsonPreview(attachments)} instead of a list.',
      );
    }
    final capabilities = item['capabilities'];
    return SkoreFeedback(
      id: id.trim(),
      text: text,
      pupilId: pupilId,
      teacherId: teacherId,
      teacherName: teacherName is String ? teacherName.trim() : '',
      createdAt: _feedbackTime(item['createdAt'], id, 'createdAt'),
      changedAt: _feedbackTime(item['changedAt'], id, 'changedAt'),
      attachments: [
        for (final attachment in (attachments as List?) ?? const [])
          if (attachment is Map)
            SkoreFeedbackAttachment(
              id: '${attachment['id'] ?? ''}',
              name: '${attachment['name'] ?? ''}',
              size: attachment['size'] is int
                  ? attachment['size'] as int
                  : null,
              json: {for (final e in attachment.entries) '${e.key}': e.value},
            )
          else
            throw SmartschoolSkoreError(
              'Skore gave an attachment of feedback $id as '
              '${SkoreRpc.jsonPreview(attachment)} instead of an object.',
            ),
      ],
      canEdit: capabilities is Map && capabilities['can_edit'] == true,
    );
  }

  /// The ID after the platform in a Skore REST ID (`9200` of `4069_9200_0`,
  /// `395742` of `4069_395742`), or `null` when [value] is none.
  static int? _middleId(Object? value) {
    final match = value is String ? _restId.firstMatch(value.trim()) : null;
    return match == null ? null : int.parse(match.group(1)!);
  }

  static final _restId = RegExp(r'^\d+_(\d+)(?:_\d+)?$');

  /// The time [value] of feedback [id] (`"2026-10-08T09:49:36+02:00"`) in
  /// UTC, or `null` when Skore gives none; one without its offset is
  /// refused.
  static DateTime? _feedbackTime(Object? value, String id, String field) {
    if (value == null || (value is String && value.trim().isEmpty)) {
      return null;
    }
    final parsed = value is String ? DateTime.tryParse(value.trim()) : null;
    if (parsed == null || !parsed.isUtc) {
      throw SmartschoolSkoreError(
        'Skore gave feedback $id the $field ${SkoreRpc.jsonPreview(value)}, '
        'which is not a date and time with its offset.',
      );
    }
    return parsed;
  }
}

/// What the checks before a write in a period of a gradebook read
/// (`SkoreGradebookService._checkWritable`, #150), which the write then
/// sends and checks against.
class _WriteTarget {
  /// The logged-in user (Skore's `userID`).
  final int userId;

  /// Skore's current school year, the gradebook's.
  final SkoreWorkyear workyear;

  /// The gradebook as Skore lists it now (`getNavigation`).
  final SkoreGradebook gradebook;

  /// The gradebook's periods and pupils (`init`), `writable` for [period]
  /// (`getGradebookContext` for it). Its `activePeriod` is [period], not
  /// the one Skore opens the gradebook on.
  final SkoreGradebookSheet sheet;

  /// The period of the write: one of the gradebook's, open, and writable.
  final SkoreGradebookPeriod period;

  const _WriteTarget({
    required this.userId,
    required this.workyear,
    required this.gradebook,
    required this.sheet,
    required this.period,
  });
}

/// A grade as `SkoreGradebookService.saveGrades` sends it (#151): [text] is
/// what goes out (`"15.5"`, `""` to clear), [number] its value (`null` to
/// clear).
typedef _GradeValue = ({String text, num? number});
