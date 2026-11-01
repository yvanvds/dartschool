import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/goal_models.dart';
import '../session.dart';

export '../models/goal_models.dart';

/// Reads the curricula and learning goals of Smartschool's goal selector
/// (#222): the dialog in which the Lesfiches module and the planner let a
/// teacher pick the learning goals of a lesfiche or a lesson (the eindtermen,
/// the curricula of the philosophies of life, the school's own
/// mini-databases), and names the goals a lesfiche or lesson already has.
///
/// ```dart
/// final goals = GoalService(client);
/// final groups = await goals.getCurricula();          // List<CurriculumGroup>
/// final tree = await goals.getCurriculum(groups.first.curricula.first.id);
/// for (final goal in tree.goals) {                    // List<SelectableGoal>
///   print('${goal.node.prefix ?? ''} ${goal.titles.join(' > ')}');
/// }
/// final ref = tree.goals.first.ref;                   // LearningGoalRef
///
/// // Name stored goals ({id, leerplanId, type}).
/// final named = await goals.resolve([ref]);           // List<Curriculum>
/// print(named.single.goals.single.node.text);
/// ```
///
/// The selector is its own app (`/goal/`), with a JSON API under
/// `/goal/selector/api/v1/`. Every route has a [GoalLocation] (where the
/// selector is opened: the Lesfiches module or the planner) and a day (the
/// selector sends today's; curricula can change with the school year). The
/// three routes the service reads were seen live on 2026-11-01:
/// - `GET leerplannen/{location}/list/{date}`: the list ([getCurricula]);
/// - `GET leerplannen/{location}/{leerplanId}/{date}`: one curriculum as a
///   tree ([getCurriculum]);
/// - `POST leerplannen/{location}/{date}` with
///   `{"selection": [{"id", "goalId", "leerplanId", "type"}], "isView": true}`:
///   the curricula of the goals asked for, pruned to them and the nodes above
///   them ([resolve]). It only reads.
///
/// The service only reads. It does not mark curricula as favourites, keep
/// the selector's settings, or read goals of LLinkid (Katholiek Onderwijs
/// Vlaanderen, picked on its own site), Zill, OVSG, POV, GO! Navigator or
/// Op Stap. Writing goals belongs to the Lesfiches module and the planner.
///
/// ### Errors
/// - [SmartschoolGoalError]: the selector answered with something the
///   service cannot use: another HTTP status than `200` (its
///   [SmartschoolGoalError.statusCode]), an HTML page, invalid JSON, or data
///   in an unknown shape. The session was accepted.
/// - [SmartschoolGoalAccessDeniedError] (a [SmartschoolGoalError]): the
///   selector refused the read with `403`.
/// - [SmartschoolCurriculumNotFoundError] (a [SmartschoolGoalError]):
///   [getCurriculum] for an ID the selector has no curriculum for (`404`).
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried once.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
class GoalService {
  final SmartschoolClient _client;

  GoalService(SmartschoolClient client) : _client = client;

  /// The base path of the goal selector's curricula.
  static const _apiPath = '/goal/selector/api/v1/leerplannen';

  static const _source = 'The goal selector';

  /// Returns the curricula the goal selector offers, in groups, in the
  /// selector's order (#222): such as `Overheid SO` (the eindtermen, per
  /// grade and finality), `Levensbeschouwing SO`, `Andere SO` and
  /// `Minidatabanken` (the school's own).
  ///
  /// Sends `GET leerplannen/{location}/list/{date}`, with [location] (the
  /// Lesfiches module by default) and the day of [date] (today by default).
  Future<List<CurriculumGroup>> getCurricula({
    GoalLocation location = GoalLocation.lessonContent,
    DateTime? date,
  }) async {
    final response = await _client.getResponse(
      '$_apiPath/${location.wireName}/list/${formatDay(date)}',
    );
    return parseCurricula(_decode(response, 'the list of curricula'));
  }

  /// Returns the curriculum [curriculumId] (a [CurriculumListItem.id]) as a
  /// tree, with every node (#222). [Curriculum.goals] lists its goals with
  /// the headings above each.
  ///
  /// Sends `GET leerplannen/{location}/{curriculumId}/{date}`. Throws an
  /// [ArgumentError], without sending anything, for an ID that is empty or
  /// holds a character other than a letter, a digit or `-`; a
  /// [SmartschoolCurriculumNotFoundError] when the selector answers `404`
  /// (seen live for a made-up ID).
  Future<Curriculum> getCurriculum(
    String curriculumId, {
    GoalLocation location = GoalLocation.lessonContent,
    DateTime? date,
  }) async {
    if (!_id.hasMatch(curriculumId)) {
      throw ArgumentError.value(
        curriculumId,
        'curriculumId',
        'is not the ID of a curriculum',
      );
    }
    final response = await _client.getResponse(
      '$_apiPath/${location.wireName}/$curriculumId/${formatDay(date)}',
    );
    if (response.statusCode == 404) {
      throw SmartschoolCurriculumNotFoundError(
        '$_source has no curriculum $curriculumId (HTTP 404).',
        curriculumId: curriculumId,
      );
    }
    return parseCurriculum(_decode(response, 'the curriculum'));
  }

  /// Names the stored goals [goals] (#222): returns their curricula, one
  /// tree per curriculum, pruned to the goals asked for and the nodes above
  /// them, in the selector's order. [Curriculum.goal] finds a goal by its
  /// ID in it; [findGoal] across all of them.
  ///
  /// Sends `POST leerplannen/{location}/{date}` with
  /// `{"selection": [...], "isView": true}`, each goal as
  /// [LearningGoalRef.toWire], as the selector does to show the goals of a
  /// lesfiche. It only reads, and is retried once after logging in again.
  /// Without [goals], it sends nothing and returns an empty list.
  ///
  /// The selector answers what it does not know without complaint (seen
  /// live, 2026-11-01): a goal it does not know leaves its curriculum
  /// without that goal (a curriculum without children when none are known),
  /// and a curriculum it does not know (an LLinkid goal, for instance) is
  /// left out. So a goal that is not named by the answer has no
  /// [findGoal].
  ///
  /// Throws an [ArgumentError], without sending anything, for a goal with
  /// an empty `id`, `leerplanId` or `type`.
  Future<List<Curriculum>> resolve(
    Iterable<LearningGoalRef> goals, {
    GoalLocation location = GoalLocation.lessonContent,
    DateTime? date,
  }) async {
    final refs = goals.toList();
    for (final (index, ref) in refs.indexed) {
      if (ref.id.isEmpty || ref.leerplanId.isEmpty || ref.type.isEmpty) {
        throw ArgumentError.value(
          ref,
          'goals[$index]',
          'needs an id, a leerplanId and a type',
        );
      }
    }
    if (refs.isEmpty) return const [];
    final response = await _client.postJsonResponse(
      '$_apiPath/${location.wireName}/${formatDay(date)}',
      data: {
        'selection': [for (final ref in refs) ref.toWire()],
        'isView': true,
      },
    );
    return parseResolved(_decode(response, 'the goals asked for'));
  }

  /// The goal [ref] in [curricula] (an answer of [resolve] or
  /// [getCurriculum]), or `null` when none of them has it.
  static SelectableGoal? findGoal(
    Iterable<Curriculum> curricula,
    LearningGoalRef ref,
  ) {
    for (final curriculum in curricula) {
      if (curriculum.id != ref.leerplanId) continue;
      final goal = curriculum.goal(ref.id);
      if (goal != null) return goal;
    }
    return null;
  }

  /// [date] (today, in local time, when `null`) as the selector's routes
  /// take a day: `yyyy-MM-dd`, of the year, month and day of [date] as given.
  static String formatDay(DateTime? date) {
    final day = date ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
        '${two(day.day)}';
  }

  /// Parses the list of curricula (a JSON array of groups). Throws a
  /// [SmartschoolGoalError] for a list in an unknown shape.
  static List<CurriculumGroup> parseCurricula(dynamic json) {
    if (json is! List) {
      throw SmartschoolGoalError(
        '$_source gave the list of curricula as ${json.runtimeType} instead '
        'of a list.',
      );
    }
    return List.unmodifiable([
      for (final (index, group) in json.indexed)
        if (group is Map<String, dynamic>)
          CurriculumGroup.fromJson(group)
        else
          throw SmartschoolGoalError(
            '$_source gave group $index of the curricula as '
            '${group.runtimeType} instead of an object.',
          ),
    ]);
  }

  /// Parses a curriculum tree (a JSON object). Throws a
  /// [SmartschoolGoalError] for a tree in an unknown shape.
  static Curriculum parseCurriculum(dynamic json) {
    if (json is! Map<String, dynamic>) {
      throw SmartschoolGoalError(
        '$_source gave the curriculum as ${json.runtimeType} instead of an '
        'object.',
      );
    }
    return Curriculum.fromJson(json);
  }

  /// Parses the answer of [resolve] (a JSON array of curriculum trees).
  /// Throws a [SmartschoolGoalError] for an answer in an unknown shape.
  static List<Curriculum> parseResolved(dynamic json) {
    if (json is! List) {
      throw SmartschoolGoalError(
        '$_source gave the goals asked for as ${json.runtimeType} instead of '
        'a list.',
      );
    }
    return List.unmodifiable([for (final tree in json) parseCurriculum(tree)]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// A curriculum ID: a UUID for every curriculum seen, but a mini-database's
  /// is not of version 4; letters, digits and `-` only, so that it stays one
  /// segment of the route.
  static final _id = RegExp(r'^[0-9A-Za-z-]+$');

  /// The decoded JSON of [response], the selector's answer to [what].
  static dynamic _decode(Response<String> response, String what) {
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (status == 403) {
      throw SmartschoolGoalAccessDeniedError(
        '$_source refused $what to the account (HTTP 403).',
      );
    }
    if (status != 200) {
      throw SmartschoolGoalError(
        '$_source answered $what with HTTP $status: ${_preview(body)}',
        statusCode: status,
      );
    }
    if (body.isEmpty) {
      throw SmartschoolGoalError('$_source answered $what with an empty body.');
    }
    if (body.startsWith('<')) {
      throw SmartschoolGoalError(
        '$_source answered $what with an HTML page instead of JSON: '
        '${_preview(body)}',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolGoalError(
        '$_source answered $what with invalid JSON (${e.message}): '
        '${_preview(body)}',
      );
    }
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
