import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/goal_models.dart';
import '../models/lesson_content_models.dart';
import '../models/teaching_assignment_models.dart';
import '../session.dart';
import 'goal_refs.dart';

export '../models/teaching_assignment_models.dart';

/// Reads and builds the **year plans** of Smartschool's Lesfiches module
/// (#229): the teaching assignments ("leeropdrachten",
/// `teaching-assignments`) of a teacher, each a collection of the teacher's
/// lesfiches split into lesson clusters (`lesson-clusters`, the units of the
/// year), which hold lesfiches and titles in order, with learning goals.
/// The planner plans a lesson cluster over a period for a class (#230).
///
/// ```dart
/// final plans = TeachingAssignmentService(client);
/// final plan = await plans.createTeachingAssignment(name: 'Informatica 5');
/// final unit = await plans.addCluster(plan, name: 'Lussen');
/// await plans.addTitle(unit, 'Week 1');
/// await plans.addLessonContent(unit, [fiche]); // lesfiches of getItems
/// await plans.changeClusterGoals(unit, [goal.ref]);
/// for (final entry in await plans.getClusterContent(unit)) {
///   switch (entry) {
///     case LessonClusterTitle(:final text):
///       print('# $text');
///     case LessonClusterLesfiche(:final item):
///       print('- ${item.name}');
///   }
/// }
/// ```
///
/// All under `/lesson-content/api/v1/teaching-assignments`, tried live on
/// 2026-11-01 in the developer's own library. A teaching assignment and a
/// lesson cluster are named by their platform and ID
/// ([TeachingAssignmentRef], [LessonClusterRef]); a [TeachingAssignment] and
/// a [LessonCluster] are such references.
///
/// ### Reads
/// [getTeachingAssignments] lists the user's teaching assignments,
/// [getTeachingAssignment] reads one (with its clusters in short),
/// [getLessonContent] the lesfiches it takes, [getClusters] and
/// [getCluster] its clusters with their counts, info and goals,
/// [getClusterContent] the lesfiches and titles of a cluster in order, and
/// [getClusterGoals] the goals of a cluster with their counts.
///
/// ### Writes
/// [createTeachingAssignment] and [deleteTeachingAssignment] (the
/// teaching assignment and its clusters; the lesfiches stay in the
/// library), [addCluster], [addLessonContent], [addTitle] and
/// [changeClusterGoals]. The creates and adds are sent **once**, never
/// again after logging in again: a second one makes a second teaching
/// assignment, cluster or title, and the same lesfiche can be in a cluster
/// twice (seen live). The goals and the delete are retried once after
/// logging in again, as a read is: they set a value, or name what they act
/// on.
///
/// Not covered: sharing (collaborators, publication), export and import,
/// partner teaching assignments, the old Jaarplannen module, renaming,
/// reordering or removing clusters and entries, their info, attachments and
/// weblinks, and the teaching-hours estimates.
///
/// ### Errors
/// The errors of `LessonContentService`: a [SmartschoolLessonContentError]
/// for an answer the service cannot use (with its `statusCode`; `404` for a
/// teaching assignment or cluster the module does not know), a
/// [SmartschoolLessonContentAccessDeniedError] for a read refused with
/// `403`, a [SmartschoolLessonContentWriteRefusedError] for a write refused
/// with a status from `400` to `499` (nothing was changed), and a
/// [SmartschoolLessonContentSaveUnconfirmedError] for a write that went out
/// but whose answer does not confirm it (read before trying again). An
/// [ArgumentError] for a value refused before anything is sent.
class TeachingAssignmentService {
  final SmartschoolClient _client;

  TeachingAssignmentService(SmartschoolClient client) : _client = client;

  static const _apiPath = '/lesson-content/api/v1/teaching-assignments';
  static const _module = 'The Lesfiches module';

  /// The icon [createTeachingAssignment] and [addCluster] give by default:
  /// the web client's (`box_curver_blue`).
  static const defaultIcon = 'box_curver_blue';

  /// The longest name of a teaching assignment or a lesson cluster, and the
  /// longest text of a title, that the module takes: it refuses one of 51
  /// characters with a bare `400` (seen live, 2026-11-01, for all three).
  static const maxNameLength = 50;

  // ---------------------------------------------------------------------------
  // Teaching assignments
  // ---------------------------------------------------------------------------

  /// Returns the teaching assignments of the authenticated user, in the
  /// module's order (#229).
  ///
  /// Sends `GET teaching-assignments/{userId}`, with the session's whole
  /// user ID (`authenticatedUser.id`). Seen live: `[]` for a teacher without
  /// one.
  Future<List<TeachingAssignment>> getTeachingAssignments() async {
    final userId = await _ownUserId();
    final json = await _read('$_apiPath/$userId', 'the teaching assignments');
    return List.unmodifiable([
      for (final (index, entry) in _jsonList(
        json,
        'the teaching assignments',
      ).indexed)
        TeachingAssignment.fromJson(
          _jsonMap(entry, 'teaching assignment $index'),
        ),
    ]);
  }

  /// Returns the teaching assignment [ref], with its clusters in short (#229).
  ///
  /// Sends `GET teaching-assignments/{platformId}/{id}`. Throws an
  /// [ArgumentError], without sending anything, for an ID that is not a
  /// UUID.
  Future<TeachingAssignment> getTeachingAssignment(
    TeachingAssignmentRef ref,
  ) async {
    final path = _taPath(ref);
    final what = 'teaching assignment ${ref.id}';
    final plan = TeachingAssignment.fromJson(
      _jsonMap(await _read(path, what), what),
    );
    if (plan != ref) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with another one: ${plan.id}.',
      );
    }
    return plan;
  }

  /// Makes a teaching assignment of the authenticated user named [name] (sent
  /// without the white space around it), with the icon [icon], that takes
  /// the lesfiches [contentFilter] says, and returns it (#229).
  ///
  /// Sends `POST teaching-assignments/{userId}` with the body of the web
  /// client: `{"name", "icon", "contentFilter": {"type", "labels": [],
  /// "labelFilterType": "oneOf", "courses": [], "courseFilterType": "oneOf",
  /// "assignmentTypes": []}, "privileges": {"read", "edit", "delete"},
  /// "collaborators": {"users": [], "groups": []}, "publication": null}`,
  /// which the module answers with `201` and the new teaching assignment
  /// (seen live, 2026-11-01); it must have the name sent. **Sent once**,
  /// never again after logging in again: a second one makes a second
  /// teaching assignment.
  ///
  /// With [TeachingAssignmentContentFilter.all] (the default), every
  /// lesfiche of the user can be added to its clusters; with
  /// [TeachingAssignmentContentFilter.none], the module refuses each (seen
  /// live). Throws an [ArgumentError], without sending anything, for a name
  /// that is empty or longer than [maxNameLength], an empty icon, or another
  /// filter ([TeachingAssignmentContentFilter.particular] needs labels,
  /// courses or assignment types, which the library does not send).
  Future<TeachingAssignment> createTeachingAssignment({
    required String name,
    String icon = defaultIcon,
    TeachingAssignmentContentFilter contentFilter =
        TeachingAssignmentContentFilter.all,
  }) async {
    const operation = 'createTeachingAssignment';
    final newName = _checkedName(name);
    final newIcon = _checkedIcon(icon);
    if (contentFilter != TeachingAssignmentContentFilter.all &&
        contentFilter != TeachingAssignmentContentFilter.none) {
      throw ArgumentError.value(
        contentFilter,
        'contentFilter',
        'is not all or none',
      );
    }
    final userId = await _ownUserId();
    final change = 'the creation of the teaching assignment "$newName"';
    const unconfirmed =
        'It may or may not have been made: look for it '
        '(getTeachingAssignments) before trying again; trying again makes a '
        'second one.';
    final response = await _write(
      operation,
      path: '$_apiPath/$userId',
      body: {
        'name': newName,
        'icon': newIcon,
        'contentFilter': {
          'type': contentFilter.wireName,
          'labels': <Object>[],
          'labelFilterType': 'oneOf',
          'courses': <Object>[],
          'courseFilterType': 'oneOf',
          'assignmentTypes': <Object>[],
        },
        'privileges': {'read': true, 'edit': true, 'delete': true},
        'collaborators': {'users': <Object>[], 'groups': <Object>[]},
        'publication': null,
      },
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final json = _answer(operation, response, change, unconfirmed, {201, 200});
    final plan = _parsed(
      operation,
      change,
      unconfirmed,
      () => TeachingAssignment.fromJson(json),
    );
    if (!_uuid.hasMatch(plan.id) || plan.name != newName) {
      _unconfirmed(
        operation,
        change,
        unconfirmed,
        'another teaching assignment ("${plan.name}", ${plan.id})',
      );
    }
    return plan;
  }

  /// Deletes the teaching assignment [ref], with its clusters (#229). The
  /// lesfiches in them stay in the library.
  ///
  /// Sends `DELETE teaching-assignments/{platformId}/{id}`, as the web
  /// client does, which the module answers with `204` (seen live,
  /// 2026-11-01). It is not moved to a trash: it is gone. Retried once after
  /// logging in again: it names what it deletes.
  ///
  /// Throws an [ArgumentError], without sending anything, for an ID that is
  /// not a UUID; a [SmartschoolLessonContentWriteRefusedError] when the
  /// module answers with a status from `400` to `499` (such as `404` for one
  /// it does not know).
  Future<void> deleteTeachingAssignment(TeachingAssignmentRef ref) async {
    const operation = 'deleteTeachingAssignment';
    final change = 'the delete of teaching assignment ${ref.id}';
    const unconfirmed =
        'It may or may not have been deleted: look for it '
        '(getTeachingAssignments) before trying again.';
    final response = await _write(
      operation,
      path: _taPath(ref),
      delete: true,
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
    );
    final status = response.statusCode ?? 0;
    if (status == 204 || status == 200) return;
    _throwFailure(operation, response, change, unconfirmed);
  }

  /// Returns the lesfiches the teaching assignment [ref] takes, as its
  /// content filter selects them from the user's lesfiches (#229): those
  /// that can be added to its clusters.
  ///
  /// Sends `GET teaching-assignments/{platformId}/{id}/lesson-content`. Seen
  /// live: with the filter `all`, the user's lesfiches, in the shape of
  /// `LessonContentService.getItems` (the owner as a user object, whose ID
  /// is [LessonContentItem.ownerId]). Their courses have no names: read
  /// `LessonContentService.getCourses` for them.
  Future<List<LessonContentItem>> getLessonContent(
    TeachingAssignmentRef ref,
  ) async {
    final what = 'the lesfiches of teaching assignment ${ref.id}';
    final json = await _read('${_taPath(ref)}/lesson-content', what);
    return List.unmodifiable([
      for (final (index, item) in _jsonList(json, what).indexed)
        LessonContentItem.fromJson(_jsonMap(item, 'lesfiche $index of $what')),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Lesson clusters
  // ---------------------------------------------------------------------------

  /// Returns the lesson clusters of the teaching assignment [ref], with their
  /// counts, info and goals, in the module's order (#229).
  ///
  /// Sends `GET teaching-assignments/{userId}/{platformId}/{id}/lesson-clusters`
  /// with `includeMetadata=true`, as the web client does.
  Future<List<LessonCluster>> getClusters(TeachingAssignmentRef ref) async {
    final userId = await _ownUserId();
    final what = 'the lesson clusters of teaching assignment ${ref.id}';
    final json = await _read(
      '$_apiPath/$userId/${_taRest(ref)}/lesson-clusters',
      what,
      query: const {'includeMetadata': 'true'},
    );
    return List.unmodifiable([
      for (final (index, cluster) in _jsonList(json, what).indexed)
        LessonCluster.fromJson(
          _jsonMap(cluster, 'cluster $index of $what'),
          teachingAssignment: ref,
        ),
    ]);
  }

  /// Returns the lesson cluster [ref], with its counts, info and goals
  /// (#229).
  ///
  /// Sends `GET teaching-assignments/{taPlatformId}/{taId}/lesson-clusters/
  /// {platformId}/{id}`.
  Future<LessonCluster> getCluster(LessonClusterRef ref) async {
    final what = 'lesson cluster ${ref.id}';
    final cluster = LessonCluster.fromJson(
      _jsonMap(await _read(_clusterPath(ref), what), what),
      teachingAssignment: ref.teachingAssignment,
    );
    if (cluster.id.toLowerCase() != ref.id.toLowerCase()) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with another one: ${cluster.id}.',
      );
    }
    return cluster;
  }

  /// Adds a lesson cluster named [name] (sent without the white space around
  /// it), with the icon [icon], to the teaching assignment [ref], and returns
  /// it (#229).
  ///
  /// Sends `POST teaching-assignments/{userId}/{platformId}/{id}/
  /// lesson-clusters` with `{"name", "icon", "isVisible"}`, which the module
  /// answers with `201` and the new cluster (seen live, 2026-11-01); it must
  /// have the name sent, in [ref]. **Sent once**, never again after logging
  /// in again: a second one makes a second cluster.
  ///
  /// Throws an [ArgumentError], without sending anything, for a name that is
  /// empty or longer than [maxNameLength], an empty icon, or an ID that is
  /// not a UUID.
  Future<LessonCluster> addCluster(
    TeachingAssignmentRef ref, {
    required String name,
    String icon = defaultIcon,
    bool visible = true,
  }) async {
    const operation = 'addCluster';
    final newName = _checkedName(name);
    final newIcon = _checkedIcon(icon);
    final rest = _taRest(ref);
    final userId = await _ownUserId();
    final change =
        'the creation of the lesson cluster "$newName" in teaching '
        'assignment ${ref.id}';
    const unconfirmed =
        'It may or may not have been made: look for it (getClusters) before '
        'trying again; trying again makes a second one.';
    final response = await _write(
      operation,
      path: '$_apiPath/$userId/$rest/lesson-clusters',
      body: {'name': newName, 'icon': newIcon, 'isVisible': visible},
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final json = _answer(operation, response, change, unconfirmed, {201, 200});
    final cluster = _parsed(
      operation,
      change,
      unconfirmed,
      () => LessonCluster.fromJson(json, teachingAssignment: ref),
    );
    if (!_uuid.hasMatch(cluster.id) ||
        cluster.name != newName ||
        cluster.teachingAssignment != ref) {
      _unconfirmed(
        operation,
        change,
        unconfirmed,
        'another lesson cluster ("${cluster.name}", ${cluster.id})',
      );
    }
    return cluster;
  }

  /// Returns the entries of the lesson cluster [ref] in order: its lesfiches
  /// ([LessonClusterLesfiche]) and titles ([LessonClusterTitle]) (#229).
  ///
  /// Sends `GET .../lesson-clusters/{platformId}/{id}/lesson-cluster-content`
  /// (seen live: a list of titles, `{id, platformId, lessonClusterId,
  /// position, text, "type": "titles"}`, and lesfiches in the shape of
  /// `LessonContentService.getItems` with `lessonClusterId`, `position`,
  /// `teachingHoursEstimate` and `numberOfGoals`).
  Future<List<LessonClusterEntry>> getClusterContent(
    LessonClusterRef ref,
  ) async {
    final what = 'the content of lesson cluster ${ref.id}';
    final json = await _read(
      '${_clusterPath(ref)}/lesson-cluster-content',
      what,
    );
    return List.unmodifiable([
      for (final (index, entry) in _jsonList(json, what).indexed)
        LessonClusterEntry.fromJson(_jsonMap(entry, 'entry $index of $what')),
    ]);
  }

  /// Adds the lesfiches [items] (such as those of [getLessonContent]) to the
  /// end of the lesson cluster [ref], and returns them as the module answers
  /// them, in the order of [items] (#229).
  ///
  /// Sends `POST .../lesson-clusters/{platformId}/{id}/
  /// lesson-content-from-teaching-assignment` with
  /// `{"lessonContentIdentifiers": [{"id", "type", "platformId"}]}`, as the
  /// web client does, which the module answers with `201` and
  /// `{"lessonContent": [...], "exceptions": []}` (seen live, 2026-11-01).
  /// **Sent once**, never again after logging in again: the same lesfiche
  /// can be in a cluster twice, and a second send adds it again (seen live).
  /// A lesfiche given twice is sent once.
  ///
  /// The module refuses a lesfiche that the teaching assignment's content
  /// filter does not take, with an exception for it keyed by the lesfiche
  /// (`{platformId}_lesson_{id}`) with the status `403` (seen live, with the
  /// filter `none`). When it added none and each has such an exception
  /// (`400` to `499`), a [SmartschoolLessonContentWriteRefusedError] that
  /// names them: nothing was changed. When it added some and not others, or
  /// its answer does not account for each, a
  /// [SmartschoolLessonContentSaveUnconfirmedError] that names those added.
  ///
  /// Throws an [ArgumentError], without sending anything, for no lesfiches,
  /// a lesfiche of a kind this library does not know, or an ID that is not
  /// a UUID.
  Future<List<LessonContentItem>> addLessonContent(
    LessonClusterRef ref,
    Iterable<LessonContentItem> items,
  ) async {
    const operation = 'addLessonContent';
    final byKey = <String, LessonContentItem>{};
    for (final item in items) {
      if (item.type == LessonContentType.other) {
        throw ArgumentError.value(
          item,
          'items',
          'is a lesfiche of a kind this library does not know',
        );
      }
      _checkId(item.id, 'items');
      byKey.putIfAbsent(item.id.toLowerCase(), () => item);
    }
    if (byKey.isEmpty) throw ArgumentError.value(items, 'items', 'is empty');
    final list = byKey.values.toList();
    final path = '${_clusterPath(ref)}/lesson-content-from-teaching-assignment';
    final change =
        'the add of ${list.length == 1 ? 'lesfiche ${list.single.id}' : '${list.length} lesfiches'} '
        'to lesson cluster ${ref.id}';
    const unconfirmed =
        'They may or may not have been added: read the cluster '
        '(getClusterContent) before trying again; trying again adds them a '
        'second time.';
    final response = await _write(
      operation,
      path: path,
      body: {
        'lessonContentIdentifiers': [
          for (final item in list)
            {
              'id': item.id,
              'type': item.typeName,
              'platformId': item.platformId,
            },
        ],
      },
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final json = _answer(operation, response, change, unconfirmed, {201, 200});
    final added = <String, LessonContentItem>{};
    final content = json['lessonContent'];
    if (content is! List) {
      _unconfirmed(operation, change, unconfirmed, 'without its lesfiches');
    }
    for (final entry in content) {
      final item = _parsed(
        operation,
        change,
        unconfirmed,
        () => LessonContentItem.fromJson(_jsonMap(entry, 'a lesfiche added')),
      );
      added[item.id.toLowerCase()] = item;
    }
    final failed = <String, Object?>{};
    switch (json['exceptions']) {
      case final List<Object?> exceptions when exceptions.isEmpty:
        break;
      case final Map<Object?, Object?> exceptions:
        for (final MapEntry(:key, :value) in exceptions.entries) {
          final id = key is String ? _trailingUuid.firstMatch(key) : null;
          if (id == null) {
            _unconfirmed(
              operation,
              change,
              unconfirmed,
              'with an exception it names in an unknown way ("$key")',
            );
          }
          failed[id[0]!.toLowerCase()] = value;
        }
      default:
        _unconfirmed(operation, change, unconfirmed, 'without its exceptions');
    }
    final result = <LessonContentItem>[];
    final refused = <String>[];
    final unknown = <String>[];
    for (final item in list) {
      final key = item.id.toLowerCase();
      if (added[key] case final made?) {
        result.add(made);
      } else if (failed.containsKey(key)) {
        refused.add('lesfiche ${item.id}: ${jsonEncode(failed[key])}');
      } else {
        unknown.add(item.id);
      }
    }
    if (result.length == list.length) return List.unmodifiable(result);
    final statuses = [
      for (final value in failed.values)
        value is Map && value['status'] is int ? value['status'] as int : 0,
    ];
    if (result.isEmpty &&
        unknown.isEmpty &&
        statuses.every((s) => s >= 400 && s < 500)) {
      throw SmartschoolLessonContentWriteRefusedError(
        '$operation: $_module refused $change, with exceptions: '
        '${refused.join('; ')} (a lesfiche the teaching assignment\'s content '
        'filter does not take is answered with 403). Nothing was changed.',
        statusCode: statuses.first,
      );
    }
    throw SmartschoolLessonContentSaveUnconfirmedError(
      '$operation: $change was sent, but $_module added '
      '${result.isEmpty ? 'none of them' : 'only ${result.map((i) => 'lesfiche ${i.id}').join(', ')}, which are in the cluster: do not add them again'}'
      '${refused.isEmpty ? '' : '; with exceptions: ${refused.join('; ')}'}'
      '${unknown.isEmpty ? '' : '; it named nothing for ${unknown.map((id) => 'lesfiche $id').join(', ')}'}. '
      '$unconfirmed',
      statusCode: response.statusCode,
    );
  }

  /// Adds a title with the text [text] (sent without the white space around
  /// it), such as "Week 1", to the end of the lesson cluster [ref], and
  /// returns it (#229).
  ///
  /// Sends `POST .../lesson-clusters/{platformId}/{id}/titles` with
  /// `{"text"}`, which the module answers with `200` and the title (seen
  /// live, 2026-11-01); it must have the text sent. **Sent once**, never
  /// again after logging in again: a second one adds a second title.
  ///
  /// Throws an [ArgumentError], without sending anything, for a text that is
  /// empty or longer than [maxNameLength] (the module answers that with a
  /// bare `400`), or an ID that is not a UUID.
  Future<LessonClusterTitle> addTitle(LessonClusterRef ref, String text) async {
    const operation = 'addTitle';
    final newText = text.trim();
    if (newText.isEmpty) throw ArgumentError.value(text, 'text', 'is empty');
    if (newText.length > maxNameLength) {
      throw ArgumentError.value(
        text,
        'text',
        'is longer than $maxNameLength characters',
      );
    }
    final path = '${_clusterPath(ref)}/titles';
    final change =
        'the add of the title "$newText" to lesson cluster ${ref.id}';
    const unconfirmed =
        'It may or may not have been added: read the cluster '
        '(getClusterContent) before trying again; trying again adds a second '
        'one.';
    final response = await _write(
      operation,
      path: path,
      body: {'text': newText},
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final json = _answer(operation, response, change, unconfirmed, {200, 201});
    final entry = _parsed(
      operation,
      change,
      unconfirmed,
      () => LessonClusterEntry.fromJson(json),
    );
    if (entry is! LessonClusterTitle ||
        entry.text != newText ||
        entry.lessonClusterId.toLowerCase() != ref.id.toLowerCase()) {
      _unconfirmed(operation, change, unconfirmed, 'something else ($entry)');
    }
    return entry;
  }

  /// Sets the learning goals of the lesson cluster [ref] to [goals] (empty
  /// clears them), and returns the cluster (#229).
  ///
  /// The list replaces the goals the cluster had, as for a lesfiche
  /// (`LessonContentService.changeGoals`, #223): to add one, send the
  /// cluster's [LessonCluster.goals] with it. Sends `POST
  /// .../lesson-clusters/{platformId}/{id}/change-goals` with `{"newGoals":
  /// [{id, goalId, leerplanId, type}]}` ([LearningGoalRef.toWire]), which
  /// the module answers with `200` and the cluster (seen live, 2026-11-01);
  /// it must have exactly the goals sent. Retried once after logging in
  /// again: it sets a value.
  ///
  /// Throws an [ArgumentError], without sending anything, for a goal that
  /// `LessonContentService.changeGoals` refuses, or an ID that is not a
  /// UUID.
  Future<LessonCluster> changeClusterGoals(
    LessonClusterRef ref,
    Iterable<LearningGoalRef> goals,
  ) async {
    const operation = 'changeClusterGoals';
    final newGoals = GoalRefs.checked(goals);
    final path = '${_clusterPath(ref)}/change-goals';
    final change =
        'the change of the goals of lesson cluster ${ref.id} to '
        '${GoalRefs.describe(newGoals)}';
    const unconfirmed =
        'It may or may not have been changed: read the cluster (getCluster) '
        'before trying again; sending the change again is harmless.';
    final response = await _write(
      operation,
      path: path,
      body: {
        'newGoals': [for (final goal in newGoals) goal.toWire()],
      },
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
    );
    final json = _answer(operation, response, change, unconfirmed, {200});
    final cluster = _parsed(
      operation,
      change,
      unconfirmed,
      () => LessonCluster.fromJson(
        json,
        teachingAssignment: ref.teachingAssignment,
      ),
    );
    if (cluster.id.toLowerCase() != ref.id.toLowerCase()) {
      _unconfirmed(operation, change, unconfirmed, 'another cluster');
    }
    if (!GoalRefs.same(cluster.goals, newGoals)) {
      _unconfirmed(
        operation,
        change,
        unconfirmed,
        'the goals ${GoalRefs.describe(cluster.goals)}',
      );
    }
    return cluster;
  }

  /// Returns the learning goals of the lesson cluster [ref] with the
  /// module's count for each (#229).
  ///
  /// Sends `GET .../lesson-clusters/{platformId}/{id}/goals`, which the
  /// module answers with `[{id, leerplanId, type, count}]`.
  Future<List<LessonClusterGoal>> getClusterGoals(LessonClusterRef ref) async {
    final what = 'the goals of lesson cluster ${ref.id}';
    final json = await _read('${_clusterPath(ref)}/goals', what);
    return List.unmodifiable([
      for (final (index, goal) in _jsonList(json, what).indexed)
        LessonClusterGoal.fromJson(_jsonMap(goal, 'goal $index of $what')),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// A teaching assignment, cluster or lesfiche ID: a UUID.
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// The UUID at the end of the key of an exception (`4069_lesson_{id}`).
  static final _trailingUuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  static final _wholeUserId = RegExp(r'^\d+_\d+_\d+$');

  static String _checkId(String id, String argument) {
    if (_uuid.hasMatch(id)) return id;
    throw ArgumentError.value(id, argument, 'is not a UUID');
  }

  /// `{platformId}/{id}` of the teaching assignment [ref].
  static String _taRest(TeachingAssignmentRef ref, {String argument = 'ref'}) =>
      '${ref.platformId}/${_checkId(ref.id, argument)}';

  static String _taPath(TeachingAssignmentRef ref) =>
      '$_apiPath/${_taRest(ref)}';

  static String _clusterPath(LessonClusterRef ref) =>
      '$_apiPath/${_taRest(ref.teachingAssignment)}/lesson-clusters/'
      '${ref.platformId}/${_checkId(ref.id, 'ref')}';

  static String _checkedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    if (trimmed.length > maxNameLength) {
      throw ArgumentError.value(
        name,
        'name',
        'is longer than $maxNameLength characters',
      );
    }
    return trimmed;
  }

  static String _checkedIcon(String icon) {
    final trimmed = icon.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(icon, 'icon', 'is empty');
    return trimmed;
  }

  /// The whole user ID of the session (`authenticatedUser.id`).
  Future<String> _ownUserId() async {
    final id = (await _client.authenticatedUser)['id'];
    if (id is! String || !_wholeUserId.hasMatch(id)) {
      throw SmartschoolParsingError(
        'Could not read a user ID for the teaching assignments from '
        'authenticatedUser.id "$id".',
      );
    }
    return id;
  }

  /// The decoded JSON of the read of [path].
  Future<Object?> _read(
    String path,
    String what, {
    Map<String, dynamic>? query,
  }) async {
    final response = await _client.getResponse(path, query: query);
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (status == 403) {
      throw SmartschoolLessonContentAccessDeniedError(
        '$_module refused $what to the account (HTTP 403).',
      );
    }
    if (status != 200) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with HTTP $status: ${_preview(body)}',
        statusCode: status,
      );
    }
    if (body.isEmpty || body.startsWith('<')) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with '
        '${body.isEmpty ? 'an empty body' : 'an HTML page instead of JSON: ${_preview(body)}'}.',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with invalid JSON (${e.message}): '
        '${_preview(body)}',
      );
    }
  }

  static List<dynamic> _jsonList(Object? json, String what) {
    if (json is List) return json;
    throw SmartschoolLessonContentError(
      '$_module gave $what as ${json.runtimeType} instead of a list.',
    );
  }

  static Map<String, dynamic> _jsonMap(Object? json, String what) {
    if (json is Map<String, dynamic>) return json;
    throw SmartschoolLessonContentError(
      '$_module gave $what as ${json.runtimeType} instead of an object.',
    );
  }

  /// Sends the write [body] to [path] (or a `DELETE` of [path] when
  /// [delete]) and returns the module's answer, whatever its status. A
  /// refused session is thrown as it is (nothing was changed); any other
  /// failure is a [SmartschoolLessonContentSaveUnconfirmedError].
  Future<Response<String>> _write(
    String operation, {
    required String path,
    Map<String, Object?>? body,
    bool delete = false,
    required bool retryAfterLogin,
    required String change,
    required String unconfirmed,
  }) async {
    try {
      if (delete) {
        return await _client.deleteResponse(
          path,
          retryAfterLogin: retryAfterLogin,
        );
      }
      return await _client.postJsonResponse(
        path,
        data: body,
        retryAfterLogin: retryAfterLogin,
      );
    } on SmartschoolAuthenticationError {
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$operation: $change was sent, but no answer came in ($e). '
          '$unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
  }

  /// The JSON object of the answer [response] to a write, whose status must
  /// be one of [statuses].
  static Map<String, dynamic> _answer(
    String operation,
    Response<String> response,
    String change,
    String unconfirmed,
    Set<int> statuses,
  ) {
    final status = response.statusCode ?? 0;
    if (!statuses.contains(status)) {
      _throwFailure(operation, response, change, unconfirmed);
    }
    final body = response.data ?? '';
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map<String, dynamic>) return decoded;
    throw SmartschoolLessonContentSaveUnconfirmedError(
      '$operation: $change was sent, but $_module answered with something '
      'that is not a JSON object (HTTP $status: ${_preview(body)}). '
      '$unconfirmed',
      statusCode: status,
    );
  }

  /// [parse] of the answer to a write; an answer it cannot read is a
  /// [SmartschoolLessonContentSaveUnconfirmedError].
  static T _parsed<T>(
    String operation,
    String change,
    String unconfirmed,
    T Function() parse,
  ) {
    try {
      return parse();
    } on SmartschoolLessonContentError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$operation: $change was sent, but $_module\'s answer cannot be '
          'read (${e.message}). $unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
  }

  static Never _unconfirmed(
    String operation,
    String change,
    String unconfirmed,
    String what,
  ) => throw SmartschoolLessonContentSaveUnconfirmedError(
    '$operation: $change was sent, but $_module answered with $what. '
    '$unconfirmed',
  );

  /// Throws the error for an answer to a write with a status it does not
  /// expect: a [SmartschoolLessonContentWriteRefusedError] from `400` to
  /// `499`, a [SmartschoolLessonContentSaveUnconfirmedError] otherwise.
  static Never _throwFailure(
    String operation,
    Response<String> response,
    String change,
    String unconfirmed,
  ) {
    final status = response.statusCode ?? 0;
    final body = (response.data ?? '').trim();
    if (status >= 400 && status < 500) {
      throw SmartschoolLessonContentWriteRefusedError(
        '$operation: $_module refused $change (HTTP $status)'
        '${status == 404 ? ': it knows no such teaching assignment or lesson cluster' : ''}. '
        'Nothing was changed.',
        statusCode: status,
      );
    }
    throw SmartschoolLessonContentSaveUnconfirmedError(
      '$operation: $change was sent, but $_module answered with HTTP '
      '$status${body.isEmpty ? '' : ' (${_preview(body)})'}. $unconfirmed',
      statusCode: status,
    );
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
