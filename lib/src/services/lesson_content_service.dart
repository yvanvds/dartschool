import 'dart:convert';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/lesson_content_models.dart';
import '../models/planner_models.dart';
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
///   print('${fiche.name}  ${fiche.courses.map((c) => c.name).join(', ')}  '
///       '${fiche.labels.map((l) => l.text).join(', ')}');
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
/// (`/lesson-content/api/v1/`), and to the school's course list
/// (`/course-list/api/v1/courses`) for the names of the courses, which the
/// module's list does not give. Creating, changing, sharing or trashing
/// lesfiches is not covered. A lesson lesfiche is planned by
/// `PlannerService.planLessonContent`, which reads the lesfiches with this
/// service first; the school's assignment types, which the planner reads from
/// this module too, are read by `PlannerService.getAssignmentTypes`.
///
/// ### Errors
/// - [SmartschoolLessonContentError]: the module, or the course list, answered
///   with something the service cannot use: another HTTP status than `200`
///   (its [SmartschoolLessonContentError.statusCode]), an HTML page (the
///   module answers a route it does not know with its web app), invalid JSON,
///   or data in an unknown shape. The session was accepted: signing in again
///   does not help.
/// - [SmartschoolLessonContentCourseListError] (a
///   [SmartschoolLessonContentError]): [getItems] read the lesfiches, but the
///   course list that names their courses answered so. It carries the
///   lesfiches as read, without the course names (#118).
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

  /// The school's course list, which names the courses of the lesfiches.
  static const _courseListPath = '/course-list/api/v1/courses';

  static const _module = 'The Lesfiches module';
  static const _courseList = 'The course list';

  /// Returns the lesfiches of the authenticated user in the Lesfiches
  /// module, lessons and assignments, in the order the module gives them.
  ///
  /// Each has its [LessonContentItem.type] (keep the
  /// [LessonContentType.lesson]s to plan one with
  /// `PlannerService.planLessonContent`), name, icon, public info, courses
  /// (with their names, see below), labels, owner, dates, the number of its
  /// attachments and links, and its capabilities. Hidden lesfiches
  /// ([LessonContentItem.isVisible] `false`) are in the list too.
  ///
  /// Sends `GET lesson-content/` (with the slash, as the web client does;
  /// seen live, 2026-10-02: all the teacher's lesfiches, both kinds). The
  /// detail of one lesfiche is not read: the module answers
  /// `lesson-content/{id}` with its web app, not with JSON.
  ///
  /// The list names a lesfiche's courses by ID only (`{platformId, id}`).
  /// When [withCourseNames] is `true` (the default) and a lesfiche has a
  /// course, it then reads the school's course list ([getCourses], one
  /// request more) and names each course after the course with the same ID
  /// in it ([LessonContentCourse.name]), as the Lesfiches web client names
  /// the courses of its course filter (#101). A course that the course list
  /// does not have keeps a `null` name. With [withCourseNames] `false` it
  /// sends the one request only, and every course has a `null` name.
  ///
  /// A course list it cannot use (another status than `200`, an HTML page,
  /// invalid JSON, a course without its `id` or `platformId`) does not lose
  /// the lesfiches: it throws a [SmartschoolLessonContentCourseListError]
  /// with the course list's message and status, whose
  /// [SmartschoolLessonContentCourseListError.items] are the lesfiches as
  /// read, every course with a `null` name (#118). Catch it to list them
  /// without the names. Any other [SmartschoolLessonContentError] is about
  /// the lesfiches: none were read. A session refused for the course list
  /// (also after logging in again) or a failed connection is thrown as for
  /// the lesfiches, without them.
  Future<List<LessonContentItem>> getItems({
    bool withCourseNames = true,
  }) async {
    final response = await _client.getResponse('$_apiPath/lesson-content/');
    final json = _decode(response, 'the lesfiches', _module);
    final items = parseItems(json);
    if (!withCourseNames || items.every((item) => item.courses.isEmpty)) {
      return items;
    }
    final List<PlannerCourse> courses;
    try {
      courses = await getCourses();
    } on SmartschoolLessonContentError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentCourseListError(
          e.message,
          statusCode: e.statusCode,
          items: items,
        ),
        stackTrace,
      );
    }
    return parseItems(json, courses: courses);
  }

  /// Returns the courses of the school, in the order the course list gives
  /// them: each with its ID, the same as the [LessonContentCourse.id] of a
  /// lesfiche's course and the [PlannerCourse.id] of a planned element's
  /// course, its name, timetable codes, icon, cluster and visibility.
  ///
  /// Sends `GET /course-list/api/v1/courses`, the course list that the
  /// Lesfiches web client reads to name the courses of the lesfiches (and
  /// [SmartschoolClient.platformId] reads for the platform ID). Seen live
  /// (read-only, 2026-10-03): all the school's courses (100 there), not only
  /// the teacher's, each in the shape of a [PlannerCourse], and among them
  /// every course of the teacher's lesfiches and of the own planner, with the
  /// planner's names.
  ///
  /// An answer it cannot use is a plain [SmartschoolLessonContentError]:
  /// only [getItems] throws a [SmartschoolLessonContentCourseListError] for
  /// it, with the lesfiches it read before.
  Future<List<PlannerCourse>> getCourses() async {
    final response = await _client.getResponse(_courseListPath);
    return parseCourses(_decode(response, 'the courses', _courseList));
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Parses the Lesfiches list (a JSON array of lesfiches), naming the
  /// courses of each lesfiche after the course with the same ID in
  /// [courses] (the school's courses, [getCourses]). Without [courses], or
  /// for a course that is not in it (or has no name), a course has a `null`
  /// [LessonContentCourse.name].
  static List<LessonContentItem> parseItems(
    dynamic json, {
    Iterable<PlannerCourse> courses = const [],
  }) {
    if (json is! List) {
      throw SmartschoolLessonContentError(
        '$_module gave the lesfiches as ${json.runtimeType} instead of a '
        'list.',
      );
    }
    final names = {
      for (final course in courses)
        if (course.name.isNotEmpty) course.id: course.name,
    };
    return List.unmodifiable([
      for (final (index, item) in json.indexed)
        if (item is Map<String, dynamic>)
          LessonContentItem.fromJson(item, courseNames: names)
        else
          throw SmartschoolLessonContentError(
            '$_module gave lesfiche $index as ${item.runtimeType} instead of '
            'an object.',
          ),
    ]);
  }

  /// Parses the school's course list (a JSON array of courses, each as a
  /// [PlannerCourse]). Throws a [SmartschoolLessonContentError] for a list
  /// in an unknown shape, or a course without its `id` or `platformId`.
  static List<PlannerCourse> parseCourses(dynamic json) {
    if (json is! List) {
      throw SmartschoolLessonContentError(
        '$_courseList gave the courses as ${json.runtimeType} instead of a '
        'list.',
      );
    }
    return List.unmodifiable([
      for (final (index, course) in json.indexed)
        if (course is Map<String, dynamic>)
          _course(course, index)
        else
          throw SmartschoolLessonContentError(
            '$_courseList gave course $index as ${course.runtimeType} '
            'instead of an object.',
          ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Course [index] of the course list, in the shape of a planner course.
  static PlannerCourse _course(Map<String, dynamic> json, int index) {
    try {
      return PlannerCourse.fromJson(json);
    } on SmartschoolPlannerError catch (e) {
      throw SmartschoolLessonContentError(
        '$_courseList gave course $index in an unknown shape: ${e.message}',
      );
    }
  }

  /// The decoded JSON of [response], the answer of [source] (`The Lesfiches
  /// module`) to [what].
  static dynamic _decode(
    Response<String> response,
    String what,
    String source,
  ) {
    final status = response.statusCode;
    final body = (response.data ?? '').trimLeft();
    if (status != 200) {
      throw SmartschoolLessonContentError(
        '$source answered $what with HTTP $status: ${_preview(body)}',
        statusCode: status,
      );
    }
    if (body.isEmpty) {
      throw SmartschoolLessonContentError(
        '$source answered $what with an empty body.',
      );
    }
    if (body.startsWith('<')) {
      throw SmartschoolLessonContentError(
        '$source answered $what with an HTML page instead of JSON: '
        '${_preview(body)}',
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolLessonContentError(
        '$source answered $what with invalid JSON (${e.message}): '
        '${_preview(body)}',
      );
    }
  }

  static String _preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
