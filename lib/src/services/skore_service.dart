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
/// them ("lesopdrachten"), and the teachers that can be assigned.
///
/// This is what Skore shows under Rapporten > Modellen > (model) > Leden >
/// (group) > (class). It only reads: nothing here changes Skore.
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
///   signing in again does not help.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered an RPC without a session. Sign in again and
///   retry.
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
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
  // RPC
  // ---------------------------------------------------------------------------

  /// Calls [method] of Skore's assignments RPC service (`owners.php`) with
  /// [params], and returns the `result` of its answer.
  ///
  /// Sends the form Skore's web client sends: `rpc_sessionobj`,
  /// `rpc_requestType` (`requestData`), `rpc_method` and `rpc_params` (the
  /// arguments as a JSON array; the web client sends IDs as strings).
  Future<dynamic> _ownersRpc(String method, List<Object?> params) async {
    final response = await _client.postFormResponse(
      _ownersRpcPath,
      _rpcFields(method, params, DateTime.now()),
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
    if (value is int) return value;
    final id = value is String ? int.tryParse(value.trim()) : null;
    if (id == null) {
      throw SmartschoolSkoreError('Skore gave $what the ID "$value".');
    }
    return id;
  }

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
