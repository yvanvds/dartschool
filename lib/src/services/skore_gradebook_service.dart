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
/// [getResults]) and feedback ([getFeedback], #149).
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
/// It only reads, and changes nothing in Skore.
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
/// Skore's gradebook reads it ([getFeedback]).
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
/// - [ArgumentError]: a school year ID that is not positive (before
///   anything is sent), or one Skore does not offer (Skore answers it with
///   no gradebooks; seen live); a period or pupil ID that is not positive,
///   or an evaluation of another gradebook (before anything is sent).
/// - [SmartschoolParsingError]: the session's user ID
///   (`authenticatedUser.id`) is not in the form `4069_146_0`, which
///   [getFeedback] builds Skore's IDs from.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered without a session. Sign in again and retry.
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
  /// `importWizardResults`, ...): none of them is here. The library never
  /// publishes an evaluation.
  static const Set<String> rpcMethods = {
    'getNavigation',
    'init',
    'getGradebookContext',
    'getEvaluations',
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
    final workyearId = gradebook.workyearId;
    final pathIds = [for (final id in gradebook.pathIds) '$id'];
    final courses = ['${gradebook.courseId}'];
    final owners = ['${gradebook.gradebookId}'];

    final sheet = _parseInit(
      gradebook,
      await _rpc(
        'init',
        [courses, owners, userId, pathIds, 0, 0],
        userId: userId,
        workyearId: workyearId,
      ),
    );
    final active = sheet.activePeriod;
    if (active == null) return sheet;
    final context = await _rpc(
      'getGradebookContext',
      [pathIds, courses, owners, userId, active.id, 0, workyearId],
      userId: userId,
      workyearId: workyearId,
    );
    return _withContext(sheet, context);
  }

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
        [for (final id in gradebook.pathIds) '$id'],
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
    final what =
        'the feedback of pupil $pupilId on evaluation ${evaluation.id}';
    final response = await _client.getResponse(
      feedbackPath(
        platform: platform,
        userId: userId,
        gradebook: gradebook,
        evaluationId: evaluation.id,
        pupilId: pupilId,
      ),
    );
    return parseFeedback(
      _restJson(response, what),
      pupilId: pupilId,
      evaluationId: evaluation.id,
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

  // ---------------------------------------------------------------------------
  // RPC
  // ---------------------------------------------------------------------------

  /// Calls [method] of Skore's gradebook RPC service with [params], as user
  /// [userId], for school year [workyearId] (`null`: Skore's current one),
  /// and returns the `result` of its answer.
  ///
  /// Only the methods in [rpcMethods]: any other is refused before anything
  /// is sent.
  Future<dynamic> _rpc(
    String method,
    List<Object?> params, {
    required int userId,
    required int? workyearId,
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
  /// Seen live: `"0"` with `""` for an evaluation that is not published,
  /// and `"1"` with the time it is published from. `"1"` without a time was
  /// not seen, and counts as published. A time with an offset is taken as
  /// it is.
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
