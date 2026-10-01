import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import '../exceptions.dart';
import '../models/skore_models.dart';
import '../session.dart';

export '../models/skore_models.dart';

/// Reads Smartschool's **Skore** module (grading and reports): the classes of
/// its report models, the courses of a class with the teachers assigned to
/// them ("lesopdrachten"), and the teachers that can be assigned. And assigns
/// a teacher to a course of a class: [addTeacher] and [replaceTeacher].
///
/// This is what Skore shows under Rapporten > Modellen > (model) > Leden >
/// (group) > (class). The reads change nothing; only [addTeacher] and
/// [replaceTeacher] write to Skore, and they never delete an assignment.
///
/// ```dart
/// final skore = SkoreService(client);
///
/// final classes = await skore.getClasses();
/// final courses = await skore.getCourses(classes.first.id);
/// for (final course in courses.where((c) => !c.isGroupHeader)) {
///   final teachers = course.assignments.map((a) => a.teacherName);
///   print('${course.label}: ${teachers.join('; ')}');
/// }
/// final teachers = await skore.getTeachers();
/// ```
///
/// ### Access requirement
/// The account needs access to Skore's report management (Rapporten >
/// Modellen), as a Skore administrator has.
///
/// ### Errors
/// - [SmartschoolSkoreError]: Skore answered with something the service
///   cannot use (an HTML page instead of data, invalid JSON, a missing RPC
///   `result`, or data in an unknown shape). The session was accepted:
///   signing in again does not help. [addTeacher] and [replaceTeacher] also
///   throw it when a check before the save refuses the change; from them, it
///   means nothing was saved.
/// - [SmartschoolSkoreMyGroupsError] (a [SmartschoolSkoreError]):
///   [replaceTeacher] found that the current teacher works with "Mijn
///   lesgroepen" for the course. Nothing was saved.
/// - [SmartschoolSkoreSaveUnconfirmedError]: [addTeacher] or
///   [replaceTeacher] sent the save, but Skore's answer does not confirm it.
///   It may or may not have been saved: read the class again.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered an RPC without a session. Sign in again and
///   retry. The save of [addTeacher] and [replaceTeacher] is never retried:
///   when the session is refused for it, it fails at once.
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached. From
///   [addTeacher] and [replaceTeacher], only before the save went out: a
///   save that failed on the way is a [SmartschoolSkoreSaveUnconfirmedError].
class SkoreService {
  final SmartschoolClient _client;

  SkoreService(SmartschoolClient client) : _client = client;

  // ---------------------------------------------------------------------------
  // Endpoints
  // ---------------------------------------------------------------------------

  /// The tree of report models (`select_models`), answered as JSON.
  static const _modelsPath = '/modules/Skore/modules/rapportbeheer/data.php';
  static const _modelsQuery = {
    'skajax_respons_type': 'JSON',
    'skajax_function': 'select_models',
  };

  /// The assignments page of a class, answered as an HTML table.
  static const _ownersPagePath =
      '/turbowidgets_dev/skore/templates/module/owners/template.php';

  /// The RPC service behind the assignments page.
  static const _ownersRpcPath = '/modules/Skore/backend/models/owners.php';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns the classes of all report models, in Skore's order: per model,
  /// per group of classes under its members ("Leden").
  Future<List<SkoreClass>> getClasses() async {
    const what = 'the list of report models';
    final response = await _client.getResponse(
      _modelsPath,
      query: _modelsQuery,
    );
    return parseClasses(_decodeJson(_body(response, what), what));
  }

  /// Returns the courses of class [classId] (a [SkoreClass.id]), in Skore's
  /// order, each with the teachers assigned to it.
  ///
  /// Skore answers a class it holds no course structure for (one that has not
  /// been linked to a structure yet) and a class ID it does not know the same
  /// way, so both give an empty list. Check the ID against [getClasses] to
  /// tell them apart.
  Future<List<SkoreCourse>> getCourses(int classId) async {
    final response = await _client.getResponse(
      _ownersPagePath,
      query: {'classID': '$classId'},
    );
    return parseCourses(
      _body(response, 'the assignments page of class $classId'),
    );
  }

  /// Returns the teachers that Skore lets assign to a course, in Skore's
  /// order (by name).
  Future<List<SkoreTeacher>> getTeachers() async {
    return parseTeachers(await _ownersRpc('getTeachers', const []));
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Assigns teacher [teacherId] to course [courseId] of class [classId]: a
  /// new assignment, as the green **+** on the class's assignments page adds.
  /// Returns the new assignment.
  ///
  /// A new assignment holds all pupils of the class.
  ///
  /// Before it saves, it reads the class ([getCourses]) and the teachers
  /// ([getTeachers]), and refuses with a [SmartschoolSkoreError], saving
  /// nothing:
  /// - a course that is not in the class (also for a class ID Skore does not
  ///   know), or that is a group header;
  /// - a teacher who already has an assignment on the course (Skore's web
  ///   client leaves them out of its choice too);
  /// - a teacher who is not in [getTeachers].
  ///
  /// The save (Skore's `saveOwner` without an `ownerID`) is sent once and
  /// never retried, not even after logging in again: a repeated add would
  /// add a second assignment. When Skore's answer does not confirm the save
  /// (it names the new assignment and the teacher asked for), this throws a
  /// [SmartschoolSkoreSaveUnconfirmedError]: read the class again before
  /// trying again. Calling this again is safe in itself: when the earlier
  /// save went through, the teacher has an assignment on the course, and the
  /// call is refused.
  ///
  /// The checks and the save are separate requests: do not change the same
  /// course from two places at once.
  Future<SkoreAssignment> addTeacher({
    required int classId,
    required int courseId,
    required int teacherId,
  }) async {
    const operation = 'addTeacher';
    final course = await _courseToAssign(operation, classId, courseId);
    _refuseAssignedTeacher(operation, course, teacherId);
    final teacher = await _teacherToAssign(operation, teacherId);
    return _saveOwner(
      operation,
      classId: classId,
      courseId: courseId,
      assignmentId: null,
      teacher: teacher,
    );
  }

  /// Gives assignment [assignmentId] of course [courseId] of class [classId]
  /// another teacher, [teacherId], as choosing another name in the teacher
  /// drop-down of the class's assignments page does. Returns the assignment,
  /// which keeps its ID: the assignment, and its gradebook, stay; only the
  /// teacher changes.
  ///
  /// Before it saves, it reads the class ([getCourses]) and the teachers
  /// ([getTeachers]), and refuses with a [SmartschoolSkoreError], saving
  /// nothing:
  /// - a course that is not in the class (also for a class ID Skore does not
  ///   know), or that is a group header;
  /// - an [assignmentId] that is not one of that course in that class;
  /// - a teacher who already has an assignment on the course, the current
  ///   teacher of [assignmentId] included;
  /// - a teacher who is not in [getTeachers].
  ///
  /// It then asks Skore whether the current teacher works with "Mijn
  /// lesgroepen" (their own groups of pupils) for the course, as Skore's web
  /// client does, and throws a [SmartschoolSkoreMyGroupsError] when they do,
  /// saving nothing. The web client offers to delete those groups; this
  /// never deletes them. An answer it does not recognise is refused with a
  /// [SmartschoolSkoreError], also saving nothing.
  ///
  /// The save (Skore's `saveOwner` with the assignment's `ownerID`) is sent
  /// once and never retried, not even after logging in again. When Skore's
  /// answer does not confirm it (it names the same assignment and the teacher
  /// asked for), this throws a [SmartschoolSkoreSaveUnconfirmedError]: read
  /// the class again before trying again.
  ///
  /// The checks and the save are separate requests: do not change the same
  /// course from two places at once.
  Future<SkoreAssignment> replaceTeacher({
    required int classId,
    required int courseId,
    required int assignmentId,
    required int teacherId,
  }) async {
    const operation = 'replaceTeacher';
    final course = await _courseToAssign(operation, classId, courseId);
    final assignment = course.assignments
        .where((a) => a.id == assignmentId)
        .firstOrNull;
    if (assignment == null) {
      throw SmartschoolSkoreError(
        '$operation: assignment $assignmentId is not one of course $courseId '
        'of class $classId. Nothing was saved.',
      );
    }
    _refuseAssignedTeacher(operation, course, teacherId);
    final teacher = await _teacherToAssign(operation, teacherId);
    await _refuseMyGroups(
      operation,
      classId: classId,
      courseId: courseId,
      teacherId: assignment.teacherId,
    );
    return _saveOwner(
      operation,
      classId: classId,
      courseId: courseId,
      assignmentId: assignmentId,
      teacher: teacher,
    );
  }

  /// Reads class [classId] again and returns its course [courseId]; refuses
  /// a course that is not in the class, or that is a group header.
  Future<SkoreCourse> _courseToAssign(
    String operation,
    int classId,
    int courseId,
  ) async {
    final courses = await getCourses(classId);
    final course = courses
        .where((c) => c.id == courseId && c.classId == classId)
        .firstOrNull;
    if (course == null) {
      throw SmartschoolSkoreError(
        '$operation: course $courseId is not in class $classId (Skore lists '
        '${courses.length} courses for it). Nothing was saved.',
      );
    }
    if (course.isGroupHeader) {
      throw SmartschoolSkoreError(
        '$operation: course $courseId of class $classId ("${course.label}") '
        'is a group header, which cannot get a teacher. Nothing was saved.',
      );
    }
    return course;
  }

  /// Refuses [teacherId] when they already have an assignment on [course].
  static void _refuseAssignedTeacher(
    String operation,
    SkoreCourse course,
    int teacherId,
  ) {
    final assigned = course.assignments
        .where((a) => a.teacherId == teacherId)
        .firstOrNull;
    if (assigned != null) {
      throw SmartschoolSkoreError(
        '$operation: teacher $teacherId (${assigned.teacherName}) already has '
        'assignment ${assigned.id} on course ${course.id} of class '
        '${course.classId} ("${course.label}"). Nothing was saved.',
      );
    }
  }

  /// Returns teacher [teacherId] from [getTeachers]; refuses one that is not
  /// in it.
  Future<SkoreTeacher> _teacherToAssign(String operation, int teacherId) async {
    final teacher = (await getTeachers())
        .where((t) => t.id == teacherId)
        .firstOrNull;
    if (teacher == null) {
      throw SmartschoolSkoreError(
        '$operation: teacher $teacherId is not one Skore lets assign to a '
        'course (not in getTeachers). Nothing was saved.',
      );
    }
    return teacher;
  }

  /// Asks Skore (`getMyGroups`) whether teacher [teacherId] works with "Mijn
  /// lesgroepen" for course [courseId] of class [classId], and refuses when
  /// they do, or when the answer is not one it recognises.
  ///
  /// Skore answers `{"mygroups": null}` when the teacher has none. The answer
  /// when they have some has not been seen; Skore's web client takes a
  /// non-empty `mygroups` for groups (`r.mygroups && r.mygroups.length`), so
  /// a non-empty list or object counts as groups. Anything else but `null`
  /// or an empty list is refused as unknown.
  Future<void> _refuseMyGroups(
    String operation, {
    required int classId,
    required int courseId,
    required int teacherId,
  }) async {
    final result = await _ownersRpc('getMyGroups', [
      '$teacherId',
      '$classId',
      '$courseId',
    ]);
    final groups = result is Map ? result['mygroups'] : null;
    final known = result is Map && result.containsKey('mygroups');
    if (known && (groups == null || groups is List && groups.isEmpty)) return;
    if (known && (groups is List || groups is Map && groups.isNotEmpty)) {
      throw SmartschoolSkoreMyGroupsError(
        '$operation: the current teacher ($teacherId) works with "Mijn '
        'lesgroepen" for course $courseId of class $classId. Handle those '
        'groups in Skore first; this does not delete them. Nothing was saved.',
        classId: classId,
        courseId: courseId,
        teacherId: teacherId,
      );
    }
    throw SmartschoolSkoreError(
      '$operation: Skore answered getMyGroups with ${_jsonPreview(result)}, '
      'which does not say whether the current teacher ($teacherId) works '
      'with "Mijn lesgroepen" for the course. Nothing was saved.',
    );
  }

  /// Saves the assignment: Skore's `saveOwner(classID, courseID, ownerID,
  /// userID)`, with an empty `ownerID` for a new assignment
  /// ([assignmentId] `null`). Sent once, never retried (not even after
  /// logging in again); returns the assignment once Skore's answer confirms
  /// it.
  ///
  /// Skore answers `{"ownerID": 34826, "userID": 146}`: the assignment
  /// (new, or the same for a replace) and its teacher.
  Future<SkoreAssignment> _saveOwner(
    String operation, {
    required int classId,
    required int courseId,
    required int? assignmentId,
    required SkoreTeacher teacher,
  }) async {
    const unconfirmed =
        'It may or may not have been saved: read the class again '
        '(getCourses) before trying again.';
    final change = assignmentId == null
        ? 'adding teacher ${teacher.id} to course $courseId of class $classId'
        : 'giving assignment $assignmentId (course $courseId of class '
              '$classId) teacher ${teacher.id}';
    final dynamic result;
    try {
      result = await _ownersRpc('saveOwner', [
        '$classId',
        '$courseId',
        assignmentId == null ? '' : '$assignmentId',
        '${teacher.id}',
      ], retryAfterLogin: false);
    } on SmartschoolSessionExpiredError {
      // Refused before Skore handled it (or answered without a session):
      // not retried, and calling again reads the class first.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolSkoreSaveUnconfirmedError(
          '$operation: the save ($change) was sent, but no usable answer '
          'came in ($e). $unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }

    final ownerId = result is Map ? _tryId(result['ownerID']) : null;
    final userId = result is Map ? _tryId(result['userID']) : null;
    final String? problem;
    if (ownerId == null || ownerId <= 0 || userId == null || userId <= 0) {
      problem = 'does not name the assignment and its teacher';
    } else if (userId != teacher.id) {
      problem = 'names teacher $userId instead';
    } else if (assignmentId != null && ownerId != assignmentId) {
      problem = 'names assignment $ownerId instead';
    } else {
      problem = null;
    }
    if (problem != null) {
      throw SmartschoolSkoreSaveUnconfirmedError(
        '$operation: the save ($change) was sent, but Skore\'s answer '
        '${_jsonPreview(result)} $problem. $unconfirmed',
      );
    }
    return SkoreAssignment(
      id: ownerId!,
      teacherId: userId!,
      teacherName: teacher.name,
    );
  }

  // ---------------------------------------------------------------------------
  // RPC
  // ---------------------------------------------------------------------------

  /// Calls [method] of Skore's assignments RPC service (`owners.php`) with
  /// [params], and returns the `result` of its answer.
  ///
  /// Sends the form Skore's web client sends: `rpc_sessionobj`,
  /// `rpc_requestType` (`requestData`), `rpc_method` and `rpc_params` (the
  /// arguments as a JSON array; the web client sends IDs as strings).
  ///
  /// Pass `retryAfterLogin: false` for a call that must not be sent twice:
  /// when Smartschool refuses the session for it, it then fails at once with
  /// a [SmartschoolSessionExpiredError], instead of being sent again after
  /// logging in (see [SmartschoolClient.postFormResponse]).
  Future<dynamic> _ownersRpc(
    String method,
    List<Object?> params, {
    bool retryAfterLogin = true,
  }) async {
    final response = await _client.postFormResponse(
      _ownersRpcPath,
      _rpcFields(method, params, DateTime.now()),
      retryAfterLogin: retryAfterLogin,
    );
    return _rpcResult(_body(response, 'the RPC call $method'), method);
  }

  /// The form fields of an RPC call to [method] with [params] at [now].
  static Map<String, String> _rpcFields(
    String method,
    List<Object?> params,
    DateTime now,
  ) => {
    'rpc_sessionobj': jsonEncode({
      'requestSource': 'skore-web',
      'timelimit': null,
      'client_epoch': now.millisecondsSinceEpoch ~/ 1000,
    }),
    'rpc_requestType': 'requestData',
    'rpc_method': method,
    'rpc_params': jsonEncode(params),
  };

  /// The `result` of an RPC answer [body] to [method].
  ///
  /// Like Skore's web client, takes an answer without a (truthy) `session`
  /// for an expired session.
  static dynamic _rpcResult(String body, String method) {
    final what = 'the RPC call $method';
    final json = _decodeJson(body, what);
    if (json is! Map<String, dynamic>) {
      throw SmartschoolSkoreError(
        'Skore answered $what with ${json.runtimeType} instead of an object.',
      );
    }
    final session = json['session'];
    if (session == null || session == false || session == 0 || session == '') {
      throw SmartschoolSessionExpiredError(
        'Skore answered $what without a session.',
      );
    }
    if (!json.containsKey('result')) {
      throw SmartschoolSkoreError('Skore answered $what without a result.');
    }
    return json['result'];
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Parses the tree of report models (`select_models`) into its classes.
  ///
  /// Each node has `content` (HTML: an icon and the name), `data` and
  /// `children`; `data.item` tells the kind of node. A `model` node (`func`:
  /// the model ID, `modelname`) holds a `members` node, which holds
  /// `childmember` nodes (groups of classes; `func`: `<modelId>_<groupId>`,
  /// `groupname`), which hold the `classroom` nodes (`func`: the class ID,
  /// the name in `content`). The other nodes (periods, divisions, reports)
  /// hold no classes.
  static List<SkoreClass> parseClasses(dynamic json) {
    if (json is! Map) {
      throw SmartschoolSkoreError(
        'The list of report models is ${json.runtimeType} instead of an '
        'object.',
      );
    }
    final classes = <SkoreClass>[];
    _collectClasses(json, classes, model: null, group: null);
    return classes;
  }

  static void _collectClasses(
    Map<dynamic, dynamic> node,
    List<SkoreClass> classes, {
    required ({int id, String name})? model,
    required ({int? id, String name})? group,
  }) {
    final data = node['data'];
    final item = data is Map ? data['item'] : null;
    switch (item) {
      case 'model':
        final name = '${data['modelname'] ?? ''}'.trim();
        model = (
          id: _id(data['func'], 'a report model'),
          name: name.isNotEmpty ? name : _contentText(node['content']),
        );
        group = null;
      case 'childmember':
        final func = '${data['func'] ?? ''}';
        final name = '${data['groupname'] ?? ''}'.trim();
        group = (
          id: int.tryParse(func.substring(func.lastIndexOf('_') + 1)),
          name: name.isNotEmpty ? name : _contentText(node['content']),
        );
      case 'classroom':
        final id = _id(data['func'], 'a class');
        if (model == null) {
          throw SmartschoolSkoreError(
            'The list of report models holds class $id outside a model.',
          );
        }
        classes.add(
          SkoreClass(
            id: id,
            name: _contentText(node['content']),
            modelId: model.id,
            modelName: model.name,
            groupId: group?.id,
            groupName: group?.name,
          ),
        );
        return;
    }
    final children = node['children'];
    if (children is! List) return;
    for (final child in children) {
      if (child is Map) {
        _collectClasses(child, classes, model: model, group: group);
      }
    }
  }

  /// Parses the assignments page of a class into its courses.
  ///
  /// The page is a `table.ownertable` with a row per course. The first cell
  /// holds the label in a `div.owners_v` (a course) or `div.owners_vz` (a
  /// group header), indented 10 pixels per level (`margin-left`). The second
  /// holds a `div` with `dojoType="ownercontainer"` (`courseID`,
  /// `coursename`, `classID`, and `grouponly="true"` on a group header), with
  /// a `div` with `dojoType="ownernode"` per assignment (`ownerID`, `userID`;
  /// the teacher's name as text).
  ///
  /// A page with Skore's "class has no structure" message
  /// (`class_has_no_structure`) gives an empty list.
  static List<SkoreCourse> parseCourses(String html) {
    final page = html_parser.parseFragment(html);
    final table = page.querySelector('table.ownertable');
    if (table == null) {
      if (page.querySelector('[data-i18n="class_has_no_structure"]') != null) {
        return const [];
      }
      throw SmartschoolSkoreError(
        'The assignments page holds no table of courses: ${_preview(html)}',
      );
    }

    final courses = <SkoreCourse>[];
    for (final row in table.querySelectorAll('tr')) {
      // The html parser lowercases attribute names (dojoType, courseID, …).
      final container = row.querySelector('div[dojotype="ownercontainer"]');
      if (container == null) continue;
      final labelDiv = row.querySelector('div.owners_v, div.owners_vz');
      final label = labelDiv?.text.trim() ?? '';
      final attributes = container.attributes;
      courses.add(
        SkoreCourse(
          id: _id(attributes['courseid'], 'a course'),
          classId: _id(attributes['classid'], 'the class of a course'),
          name: (attributes['coursename'] ?? '').trim(),
          label: label,
          code: _codeOf(label),
          isGroupHeader: attributes['grouponly'] == 'true',
          depth: _depthOf(labelDiv),
          assignments: [
            for (final node in container.querySelectorAll(
              'div[dojotype="ownernode"]',
            ))
              SkoreAssignment(
                id: _id(node.attributes['ownerid'], 'an assignment'),
                teacherId: _id(node.attributes['userid'], 'a teacher'),
                teacherName: node.text.trim(),
              ),
          ],
        ),
      );
    }
    return courses;
  }

  /// Parses the `result` of `getTeachers`: a list of
  /// `{"userID": "122", "name": "Last, First"}`.
  static List<SkoreTeacher> parseTeachers(dynamic result) {
    if (result is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the teachers as ${result.runtimeType} instead of a list.',
      );
    }
    return [
      for (final entry in result)
        if (entry is Map)
          SkoreTeacher(
            id: _id(entry['userID'], 'a teacher'),
            name: '${entry['name'] ?? ''}'.trim(),
          )
        else
          throw SmartschoolSkoreError(
            'Skore gave a teacher as ${entry.runtimeType} instead of an '
            'object.',
          ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// The body of [response], an answer to [what]; throws when Skore did not
  /// answer with `200`.
  static String _body(Response<String> response, String what) {
    final status = response.statusCode;
    if (status != 200) {
      throw SmartschoolSkoreError('Skore answered $what with HTTP $status.');
    }
    return response.data ?? '';
  }

  /// Decodes [body], the JSON answer to [what].
  static dynamic _decodeJson(String body, String what) {
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty) {
      throw SmartschoolSkoreError('Skore answered $what with an empty body.');
    }
    if (trimmed.startsWith('<')) {
      throw SmartschoolSkoreError(
        'Skore answered $what with an HTML page instead of JSON: '
        '${_preview(trimmed)}',
      );
    }
    try {
      return jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw SmartschoolSkoreError(
        'Skore answered $what with invalid JSON (${e.message}): '
        '${_preview(trimmed)}',
      );
    }
  }

  /// A Skore ID: an int, or a string of digits as Skore mostly sends them.
  static int _id(Object? value, String what) {
    final id = _tryId(value);
    if (id == null) {
      throw SmartschoolSkoreError('Skore gave $what the ID "$value".');
    }
    return id;
  }

  /// [value] as a Skore ID (see [_id]), or `null` when it is none.
  static int? _tryId(Object? value) {
    if (value is int) return value;
    return value is String ? int.tryParse(value.trim()) : null;
  }

  /// [value], a decoded JSON answer, as a short JSON text for a message.
  static String _jsonPreview(Object? value) => _preview(jsonEncode(value));

  /// The text of a tree node's `content`: an icon, `&nbsp;` and the name.
  static String _contentText(Object? content) {
    if (content is! String) return '';
    return html_parser.parseFragment(content).text?.trim() ?? '';
  }

  static final _trailingCode = RegExp(r'\[([^\[\]]*)\]\s*$');

  /// The course code at the end of [label] (`... [BEELD]`), or `null`.
  static String? _codeOf(String label) =>
      _trailingCode.firstMatch(label)?.group(1)?.trim();

  static final _marginLeft = RegExp(r'margin-left\s*:\s*(\d+)\s*px');

  /// The nesting depth of a label: its `margin-left`, 10 pixels per level.
  static int _depthOf(html_dom.Element? label) {
    final style = label?.attributes['style'] ?? '';
    final pixels = int.tryParse(_marginLeft.firstMatch(style)?.group(1) ?? '');
    return pixels == null ? 0 : pixels ~/ 10;
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
