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
/// and the periods and pupils of one gradebook, with whether the teacher may
/// change it ([getGradebook]).
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
/// ([checkRpcMethod]).
///
/// ### Errors
/// - [SmartschoolSkoreError]: Skore answered with something the service
///   cannot use: another HTTP status than `200` (also a redirect), an HTML
///   page instead of data, invalid JSON, an RPC answer without its `result`,
///   or data in a shape it does not recognise (such as a tree without its
///   lists, a non-numeric ID, or an answer about another gradebook or school
///   year). Never an empty list instead. The session was accepted: signing in again does not help.
///   Its message may quote the answer, which can hold names: keep it in a
///   log. What Skore answers an account without a gradebook of its own (a
///   pupil, say) was not captured.
/// - [ArgumentError]: a school year ID that is not positive (before
///   anything is sent), or one Skore does not offer (Skore answers it with
///   no gradebooks; seen live).
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered without a session. Sign in again and retry.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
class SkoreGradebookService {
  final SmartschoolClient _client;

  SkoreGradebookService(SmartschoolClient client) : _client = client;

  /// Skore's gradebook RPC service, behind `/SkoreGradebook`.
  static const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';

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
}
