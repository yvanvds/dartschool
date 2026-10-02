import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/lesson_content_models.dart';
import '../session.dart';

export '../models/lesson_content_models.dart';

/// Reads Smartschool's **Lesfiches** module (lesson content,
/// `/lesson-content`): the lesfiches a teacher keeps there, lessons and
/// assignments, to plan into the planner.
///
/// ```dart
/// final lessonContent = LessonContentService(client);
/// final fiches = await lessonContent.getItems();
/// final lessons = fiches.where((f) => f.type == LessonContentType.lesson);
/// for (final fiche in lessons) {
///   print('${fiche.name}  ${fiche.labels.map((l) => l.text).join(', ')}');
/// }
///
/// // Plan one into an empty lesson hour of the own planner.
/// final lesson = await PlannerService(client).planLessonContent(
///   placeholder: slot,
///   lessonContentId: lessons.first.id,
/// );
/// ```
///
/// It only reads, with GET requests to the module's JSON API
/// (`/lesson-content/api/v1/`). Creating, changing, sharing or trashing
/// lesfiches is not covered. A lesson lesfiche is planned by
/// `PlannerService.planLessonContent`, which reads the lesfiches with this
/// service first; the school's assignment types, which the planner reads from
/// this module too, are read by `PlannerService.getAssignmentTypes`.
///
/// ### Errors
/// - [SmartschoolLessonContentError]: the module answered with something the
///   service cannot use: another HTTP status than `200` (its
///   [SmartschoolLessonContentError.statusCode]), an HTML page (the module
///   answers a route it does not know with its web app), invalid JSON, or
///   data in an unknown shape. The session was accepted: signing in again
///   does not help.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once.
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
class LessonContentService {
  final SmartschoolClient _client;

  LessonContentService(SmartschoolClient client) : _client = client;

  /// The base path of the module's JSON API.
  static const _apiPath = '/lesson-content/api/v1';

  /// Returns the lesfiches of the authenticated user in the Lesfiches
  /// module, lessons and assignments, in the order the module gives them.
  ///
  /// Each has its [LessonContentItem.type] (keep the
  /// [LessonContentType.lesson]s to plan one with
  /// `PlannerService.planLessonContent`), name, icon, public info, courses
  /// (IDs only), labels, owner, dates, the number of its attachments and
  /// links, and its capabilities. Hidden lesfiches
  /// ([LessonContentItem.isVisible] `false`) are in the list too.
  ///
  /// Sends `GET lesson-content/` (with the slash, as the web client does;
  /// seen live, 2026-10-02: all the teacher's lesfiches, both kinds). The
  /// detail of one lesfiche is not read: the module answers
  /// `lesson-content/{id}` with its web app, not with JSON.
  Future<List<LessonContentItem>> getItems() async {
    final response = await _client.getResponse('$_apiPath/lesson-content/');
    return parseItems(_decode(response, 'the lesfiches'));
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Parses the Lesfiches list (a JSON array of lesfiches).
  static List<LessonContentItem> parseItems(dynamic json) {
    if (json is! List) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module gave the lesfiches as ${json.runtimeType} '
        'instead of a list.',
      );
    }
    return List.unmodifiable([
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          LessonContentItem.fromJson(item)
        else
          throw SmartschoolLessonContentError(
            'The Lesfiches module gave lesfiche $index as '
            '${item.runtimeType} instead of an object.',
          ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// The decoded JSON of [response], the module's answer to [what].
  static dynamic _decode(Response<String> response, String what) {
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (status != 200) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module answered $what with HTTP $status: '
        '${_preview(body)}',
        statusCode: status,
      );
    }
    if (body.isEmpty) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module answered $what with an empty body.',
      );
    }
    if (body.startsWith('<')) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module answered $what with an HTML page instead of '
        'JSON: ${_preview(body)}',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolLessonContentError(
        'The Lesfiches module answered $what with invalid JSON '
        '(${e.message}): ${_preview(body)}',
      );
    }
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
