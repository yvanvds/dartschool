import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../models/lesson_content_models.dart';
import '../models/planner_models.dart';
import '../session.dart';
import 'smartschool_uploader.dart';

export '../models/lesson_content_models.dart';

/// A weblink as a write sends it, after the checks.
typedef _Weblink = ({
  String name,
  String url,
  String icon,
  LessonContentVisibility visibility,
});

/// A file as a write uploads it, after the checks: its path, the name it is
/// uploaded under, and its visibility.
typedef _File = ({
  String path,
  String fileName,
  LessonContentVisibility visibility,
});

/// Courses as a write sends them (`{platformId, id}`), with the names of the
/// school's courses by ID to name them in the answer.
typedef _Courses = ({
  List<Map<String, Object>> wire,
  Map<String, String> names,
});

/// Reads and builds the lesfiches of Smartschool's **Lesfiches** module
/// (lesson content, `/lesson-content`): the lessons and assignments a teacher
/// keeps in the own library ("Mijn lesfiches"), to plan into the planner.
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
/// // Make a complete lesfiche once (#129) ...
/// final fiche = await lessonContent.createLesson(
///   name: 'Lussen',
///   publicInfo: '<p>Hoofdstuk 3</p>',
///   courseIds: [informatica.id], // a course of getCourses()
///   weblinks: [
///     NewLessonContentWeblink(
///       name: 'Oefeningen',
///       url: 'example.com/lussen', // sent as http://example.com/lussen
///       visibility: LessonContentVisibility.atEnd,
///     ),
///   ],
///   attachments: [NewLessonContentAttachment('lussen.pdf')],
/// );
///
/// // ... and plan it into empty lesson hours of the own planner.
/// final lesson = await PlannerService(client).planLessonContent(
///   placeholder: slot,
///   lessonContentId: fiche.id,
/// );
/// ```
///
/// ### Reads
/// [getItems] lists the lesfiches, [getDetail] and [getDetailById] read one
/// with its weblinks, attachments and private info, [getCourses] reads the
/// school's courses, which name the courses of the lesfiches, and
/// [downloadAttachment] / [downloadAttachmentStream] download an attachment.
/// The school's assignment types, which the planner reads from this module
/// too, are read by `PlannerService.getAssignmentTypes`; a lesson lesfiche
/// is planned by `PlannerService.planLessonContent`.
///
/// ### Writes (#129)
/// [createLesson] and [createAssignment] make a lesfiche, with its courses,
/// weblinks and attachments in one create; [rename], [changeIcon],
/// [changePublicInfo], [changePrivateInfo], [changeCourses] and [setVisible]
/// change one; [addWeblink], [changeWeblink], [removeWeblink],
/// [addAttachments], [changeAttachmentVisibility] and [removeAttachment]
/// change its weblinks and attachments; [trash] moves lesfiches to the
/// module's trash. All of them were tried live on 2026-10-05, in the own
/// library, which is private to the teacher. The service never deletes a
/// lesfiche for good (`lesson-content/delete/bulk`), never restores one, and
/// does not cover labels, goals, duplicating, merging or converting
/// lesfiches, sharing, year plans, method lessons of publishers or printing.
///
/// What Smartschool answers, and what the service makes of it:
/// - **A create answers with the ID only** (`201` with `{"id"}`), so the
///   creates read the new lesfiche back and return its detail. The edits
///   answer with the whole lesfiche, which they return; a weblink write
///   answers with the weblink only.
/// - **A create is sent once**, never again after logging in again, nor
///   retried in any other way: a second one makes a second lesfiche (the
///   module keeps a name that is taken, seen live). The same for
///   [addWeblink] and the last step of [addAttachments]. The edits set a
///   value, the removals and the move to the trash name what they act on,
///   so they are retried once after logging in again, as a read is.
/// - **Checks before sending.** The module answers a bad name or address
///   with a bare HTTP `400` that does not say why, and stores a course it
///   does not know without complaint (seen live). So the writes refuse with
///   an [ArgumentError], before anything is sent: an empty name or one
///   longer than [maxNameLength], an empty icon, a weblink without a name
///   or with an address the web client refuses ([normalizeWeblinkUrl]), a
///   visibility the web client does not offer, a file that does not exist,
///   a file name Smartschool does not allow, two files of the same name, an
///   ID that is not a UUID, and a lesfiche of a kind this library does not
///   know ([LessonContentType.other]). Courses and an assignment type are
///   checked against the school's own ([getCourses], the module's
///   assignment types) after reading them, also before anything is sent.
///
/// ### Errors
/// - [SmartschoolLessonContentError]: the module, or the course list,
///   answered with something the service cannot use: another HTTP status
///   than `200` (its [SmartschoolLessonContentError.statusCode]), an HTML
///   page (the module answers a route it does not know with its web app),
///   invalid JSON, or data in an unknown shape. The session was accepted:
///   signing in again does not help. From a write, it and its subtypes mean
///   that nothing was changed.
/// - [SmartschoolLessonContentCourseListError] (a
///   [SmartschoolLessonContentError]): [getItems] or [getDetail] read the
///   lesfiches, but the course list that names their courses answered so.
///   It carries the lesfiches as read, without the course names (#118).
/// - [SmartschoolLessonContentNotFoundError] (a
///   [SmartschoolLessonContentError]): the module answered `404`: it has no
///   lesfiche of that kind with that ID (an unknown ID, or, for a write, a
///   lesfiche in the trash), or no such weblink or attachment.
/// - [SmartschoolLessonContentWriteRefusedError] (a
///   [SmartschoolLessonContentError]): the module refused a write with
///   another status from `400` to `499`. Nothing was changed.
/// - [SmartschoolAttachmentUploadError]: Smartschool gave no upload
///   directory for the attachments of a create or of [addAttachments], or
///   did not take a file into it. Nothing was changed.
/// - [SmartschoolLessonContentSaveUnconfirmedError]: a write went out, but
///   the module's answer does not confirm it. Read the lesfiche before
///   trying again; for a create, its `lessonContentId` is the ID of the
///   lesfiche when the module answered with one.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once (for a create, without that retry). Nothing was changed. Calling
///   the method again is enough: the client logs in before its next request
///   (#134).
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached for a
///   read, or a request before a write. When the write itself fails so, it
///   may have gone out: a [SmartschoolLessonContentSaveUnconfirmedError]
///   instead.
/// - [SmartschoolDownloadError]: the download of an attachment answered
///   with another status than `200`.
class LessonContentService {
  final SmartschoolClient _client;

  LessonContentService(SmartschoolClient client) : _client = client;

  /// The base path of the module's JSON API.
  static const _apiPath = '/lesson-content/api/v1';

  /// The school's course list, which names the courses of the lesfiches.
  static const _courseListPath = '/course-list/api/v1/courses';

  /// The school's assignment types, as the module lists them.
  static const _assignmentTypesPath =
      '$_apiPath/assignments/applicable-assignment-types';

  static const _module = 'The Lesfiches module';
  static const _courseList = 'The course list';

  /// The icon [createLesson] gives a lesfiche by default: the web client's
  /// icon for a lesson (`document_observation`).
  static const defaultLessonIcon = 'document_observation';

  /// The icon [createAssignment] gives a lesfiche by default: the web
  /// client's icon for an assignment (`flags_red_yellow`).
  static const defaultAssignmentIcon = 'flags_red_yellow';

  /// The icon a new weblink gets by default: the web client's, a globe
  /// (`earth`).
  static const defaultWeblinkIcon = 'earth';

  /// The longest name of a lesfiche the web client's name field takes.
  static const maxNameLength = 255;

  /// Returns the lesfiches of the authenticated user in the Lesfiches
  /// module, lessons and assignments, in the order the module gives them.
  ///
  /// Each has its [LessonContentItem.type] (keep the
  /// [LessonContentType.lesson]s to plan one with
  /// `PlannerService.planLessonContent`), name, icon, public info, courses
  /// (with their names, see below), labels, owner, dates, the number of its
  /// attachments and links, and its capabilities. Hidden lesfiches
  /// ([LessonContentItem.isVisible] `false`) are in the list too; lesfiches
  /// in the trash are not (seen live, #129).
  ///
  /// Sends `GET lesson-content/` (with the slash, as the web client does;
  /// seen live, 2026-10-02: all the teacher's lesfiches, both kinds). The
  /// detail of one lesfiche, with its weblinks, attachments and private
  /// info, is [getDetail] (`GET lessons/{id}` or `assignments/{id}`, #129;
  /// `lesson-content/{id}` is not it: the module answers that with its web
  /// app).
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
    final courses = await _coursesFor(items);
    return parseItems(json, courses: courses);
  }

  /// Returns the detail of [item], a lesfiche of [getItems] (or a
  /// [LessonContentDetail]): the lesfiche with its private info, its
  /// weblinks and its attachments, each with when pupils see it (#129).
  ///
  /// The same as [getDetailById] with the [LessonContentItem.type] and
  /// [LessonContentItem.id] of [item]; see there.
  Future<LessonContentDetail> getDetail(
    LessonContentItem item, {
    bool withCourseNames = true,
  }) => getDetailById(item.type, item.id, withCourseNames: withCourseNames);

  /// Returns the detail of the lesfiche [id] of the kind [type] (#129): the
  /// lesfiche with its private info, its weblinks and its attachments, each
  /// with when pupils see it.
  ///
  /// Sends `GET lessons/{id}` (or `assignments/{id}`), which the module
  /// answers with the whole lesfiche (seen live, 2026-10-05; the module's
  /// web client reads it there too). It has no dates
  /// ([LessonContentItem.dateLastChanged] is `null`). A lesfiche in the trash
  /// is still answered, though [getItems] no longer lists it, and with the
  /// same capabilities (`canUserEdit` still `true`, seen live): the edits of
  /// such a lesfiche are answered with `404`
  /// ([SmartschoolLessonContentNotFoundError]).
  ///
  /// Its courses are named as [getItems] names them: with [withCourseNames]
  /// (the default) and a course, it reads [getCourses] too. A course list it
  /// cannot use throws a [SmartschoolLessonContentCourseListError] whose
  /// `items` hold the detail, without the course names.
  ///
  /// Throws an [ArgumentError], without sending anything, for a [type] of
  /// [LessonContentType.other] or an [id] that is not a UUID (the module
  /// answers that with a bare `500`, seen live). Throws a
  /// [SmartschoolLessonContentNotFoundError] when the module answers `404`:
  /// it has no lesfiche of that kind with that ID (seen live for a made-up
  /// ID, and for a lesson's ID asked for as an assignment).
  Future<LessonContentDetail> getDetailById(
    LessonContentType type,
    String id, {
    bool withCourseNames = true,
  }) async {
    _kindPath(type, 'type');
    _checkId(id, 'id');
    final detail = await _readDetail(type, id);
    if (!withCourseNames || detail.courses.isEmpty) return detail;
    final courses = await _coursesFor([detail]);
    return parseDetail(detail.raw, courses: courses);
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
  /// planner's names. The writes that take courses ([createLesson],
  /// [createAssignment], [changeCourses]) take the IDs of these courses.
  ///
  /// An answer it cannot use is a plain [SmartschoolLessonContentError]:
  /// only [getItems] and [getDetail] throw a
  /// [SmartschoolLessonContentCourseListError] for it, with the lesfiches
  /// they read before.
  Future<List<PlannerCourse>> getCourses() async {
    final response = await _client.getResponse(_courseListPath);
    return parseCourses(_decode(response, 'the courses', _courseList));
  }

  /// Downloads the attachment [attachmentId] of the lesfiche [item]
  /// ([LessonContentAttachment.id] of its [LessonContentDetail.attachments])
  /// and returns its bytes (#129).
  ///
  /// Sends `GET lessons/{id}/attachments/{attachmentId}/download` (or
  /// `assignments/...`), the web client's download URL, which answers with
  /// the file as it was uploaded (seen live, 2026-10-05). The request goes
  /// out without `Accept: application/json`: with that header, Smartschool
  /// answered it with `503` and an HTML page that reloads itself (seen
  /// live).
  ///
  /// The whole file is held in memory; [downloadAttachmentStream] reads it
  /// as it comes in instead. With [maxBytes], the download fails with a
  /// [SmartschoolDownloadTooLargeError] as soon as the file turns out to be
  /// larger (see [SmartschoolClient.download]).
  ///
  /// Throws an [ArgumentError], without sending anything, for a lesfiche of
  /// a kind this library does not know, or IDs that are not UUIDs; a
  /// [SmartschoolDownloadError] when Smartschool answers with another status
  /// than `200`.
  Future<Uint8List> downloadAttachment(
    LessonContentItem item,
    String attachmentId, {
    int? maxBytes,
  }) async {
    return _client.download(
      _downloadPath(item, attachmentId),
      maxBytes: maxBytes,
    );
  }

  /// Downloads the attachment [attachmentId] of the lesfiche [item] as a
  /// stream, from the same URL as [downloadAttachment] (#129).
  ///
  /// Returns as soon as the headers of Smartschool's answer are in, with the
  /// size (`contentLength`) and name (`fileName`) Smartschool gives the file,
  /// and the content to be read from `stream` as it comes in; cancelling the
  /// subscription stops the transfer. [maxBytes] limits the download as for
  /// [downloadAttachment]. See [SmartschoolClient.downloadStream].
  Future<SmartschoolDownload> downloadAttachmentStream(
    LessonContentItem item,
    String attachmentId, {
    int? maxBytes,
  }) async {
    return _client.downloadStream(
      _downloadPath(item, attachmentId),
      maxBytes: maxBytes,
    );
  }

  /// The download URL of the attachment [attachmentId] of [item].
  static String _downloadPath(LessonContentItem item, String attachmentId) {
    _checkItem(item);
    _checkId(attachmentId, 'attachmentId');
    return '${_itemPath(item.type, item.id)}/attachments/$attachmentId/'
        'download';
  }

  // ---------------------------------------------------------------------------
  // Creates (#129)
  // ---------------------------------------------------------------------------

  /// Makes a lesson lesfiche in the own library, and returns its detail
  /// (#129).
  ///
  /// It gets the name [name] (sent without the white space around it), the
  /// icon [icon], the info for pupils [publicInfo] and for the teacher only
  /// [privateInfo] (both HTML, as the web client's editor makes it; empty
  /// by default), the courses [courseIds] (IDs of [getCourses]), the
  /// [weblinks] and the [attachments], each with when pupils see it: all in
  /// one create, as the web client makes a lesfiche (seen live, 2026-10-05).
  /// A name that is taken is kept: the module makes a second lesfiche of
  /// that name (seen live).
  ///
  /// The steps:
  /// 1. With [courseIds], `GET /course-list/api/v1/courses` ([getCourses]):
  ///    the module stores a course it does not know without complaint (seen
  ///    live), so every ID must be one of the school's courses.
  /// 2. With [attachments], a new upload directory
  ///    (`GET /upload/api/v1/get-upload-directory`) and each file uploaded
  ///    into it (`POST /Upload/Upload/Index`), Smartschool's upload step
  ///    shared with `IntradeskService.uploadFiles` and message attachments.
  ///    These are retried after logging in again, as a read is: the
  ///    directory is not bound to the session (#128).
  /// 3. `POST /lesson-content/api/v1/lessons/` with the body the web client
  ///    sends: `name`, `icon`, `publicInfo`, `privateInfo`, `courses`
  ///    (`{platformId, id}`), `weblinks` (`{name, url, icon, visibility}`),
  ///    the upload directory as `randomDir` (`null` without attachments), the
  ///    visibility of each attachment by its file name in
  ///    `visibilityOptions`, and empty `goals`, `labels`, `partnerWeblinks`,
  ///    `miniDBItems` and `deeplinks` (the module answers a body with only a
  ///    name with a bare `400`, seen live). Sent **once**, never again after
  ///    logging in again. The module answers `201` with `{"id"}` only.
  /// 4. `GET lessons/{id}`: the detail of the new lesfiche ([getDetailById]),
  ///    which is returned, with its courses named when it has any. It must
  ///    show the name, the courses, every weblink and every attachment with
  ///    the visibility sent, as it did live.
  ///
  /// Throws an [ArgumentError], without sending anything, for a name that is
  /// empty or longer than [maxNameLength], an empty icon, a course ID that is
  /// not a UUID, a weblink without a name or icon, with an address the web
  /// client refuses ([normalizeWeblinkUrl]) or a visibility it does not
  /// offer, an attachment whose file does not exist or has a name
  /// Smartschool does not allow ([SmartschoolUploader.isAllowedName]), two
  /// attachments of the same name (their visibility is sent by name), or an
  /// attachment visibility the web client does not offer. Throws it after
  /// reading the school's courses, still without sending anything, for a
  /// course ID that is not one of them.
  ///
  /// A failure of step 4, or a lesfiche that does not show what was sent, is
  /// a [SmartschoolLessonContentSaveUnconfirmedError] whose
  /// `lessonContentId` is the new lesfiche's ID: it was made. See the class
  /// doc for the other errors.
  Future<LessonContentDetail> createLesson({
    required String name,
    String icon = defaultLessonIcon,
    String publicInfo = '',
    String privateInfo = '',
    Iterable<String> courseIds = const [],
    List<NewLessonContentWeblink> weblinks = const [],
    List<NewLessonContentAttachment> attachments = const [],
  }) => _create(
    'createLesson',
    LessonContentType.lesson,
    name: name,
    icon: icon,
    publicInfo: publicInfo,
    privateInfo: privateInfo,
    courseIds: courseIds,
    weblinks: weblinks,
    attachments: attachments,
  );

  /// Makes an assignment lesfiche of the assignment type [assignmentTypeId]
  /// in the own library, and returns its detail (#129).
  ///
  /// The same as [createLesson] (see there), with `assignments/` for
  /// `lessons/`, `assignmentType` in the body, and [defaultAssignmentIcon]
  /// as the default icon. [assignmentTypeId] is the ID of one of the
  /// school's assignment types (`PlannerService.getAssignmentTypes`, such as
  /// `Kleine Taak`); it is checked against the module's list of them
  /// (`GET assignments/applicable-assignment-types`) before anything is
  /// sent, and an ID that is not among them is an [ArgumentError]. Seen live
  /// (2026-10-05): an assignment made with a type of that list has that
  /// type ([LessonContentItem.assignmentType]); a type that is not in it
  /// was not tried.
  ///
  /// The library does not plan an assignment lesfiche:
  /// `PlannerService.planLessonContent` plans lesson lesfiches only.
  Future<LessonContentDetail> createAssignment({
    required String name,
    required String assignmentTypeId,
    String icon = defaultAssignmentIcon,
    String publicInfo = '',
    String privateInfo = '',
    Iterable<String> courseIds = const [],
    List<NewLessonContentWeblink> weblinks = const [],
    List<NewLessonContentAttachment> attachments = const [],
  }) => _create(
    'createAssignment',
    LessonContentType.assignment,
    name: name,
    assignmentTypeId: assignmentTypeId,
    icon: icon,
    publicInfo: publicInfo,
    privateInfo: privateInfo,
    courseIds: courseIds,
    weblinks: weblinks,
    attachments: attachments,
  );

  /// Makes a lesfiche of [type]; see [createLesson].
  Future<LessonContentDetail> _create(
    String operation,
    LessonContentType type, {
    required String name,
    String? assignmentTypeId,
    required String icon,
    required String publicInfo,
    required String privateInfo,
    required Iterable<String> courseIds,
    required List<NewLessonContentWeblink> weblinks,
    required List<NewLessonContentAttachment> attachments,
  }) async {
    final newName = _checkedName(name);
    final newIcon = _checkedIcon(icon);
    final links = [for (final link in weblinks) _checkedWeblink(link)];
    final files = _checkedFiles(attachments);
    final ids = _checkedCourseIds(courseIds);
    final typeId = assignmentTypeId?.trim();
    if (typeId != null && typeId.isEmpty) {
      throw ArgumentError.value(
        assignmentTypeId,
        'assignmentTypeId',
        'is empty',
      );
    }

    final courses = await _checkedCourses(ids);
    if (typeId != null) await _checkAssignmentType(typeId);

    String? uploadDir;
    if (files.isNotEmpty) {
      final uploader = SmartschoolUploader(_client);
      uploadDir = await uploader.newDirectory();
      for (final file in files) {
        await uploader.uploadFile(uploadDir, file.path);
      }
    }

    final what = '${_noun(type)} "$newName"';
    final change = 'the creation of $what';
    const unconfirmed =
        'It may or may not have been made: look for it in the lesfiches '
        '(getItems) before trying again; trying again makes a second one if '
        'it was made.';
    final response = await _write(
      operation,
      path: '$_apiPath/${type.wireName}/',
      body: {
        'name': newName,
        'assignmentType': ?typeId,
        'icon': newIcon,
        'publicInfo': publicInfo,
        'privateInfo': privateInfo,
        'courses': courses.wire,
        'goals': const <Object>[],
        'labels': const <Object>[],
        'weblinks': [
          for (final link in links)
            {
              'name': link.name,
              'url': link.url,
              'icon': link.icon,
              'visibility': link.visibility.toJson(),
            },
        ],
        'partnerWeblinks': const <Object>[],
        'miniDBItems': const <Object>[],
        'deeplinks': const <Object>[],
        'randomDir': uploadDir,
        'previousLessonContent': null,
        'visibilityOptions': {
          for (final file in files) file.fileName: file.visibility.toJson(),
        },
      },
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final status = response.statusCode ?? 0;
    if (status != 201 && status != 200) {
      _throwFailure(operation, response, change, unconfirmed);
    }
    final id = _jsonObject(operation, response, change, unconfirmed)['id'];
    if (id is! String || !_uuid.hasMatch(id)) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$operation: $change was sent, but $_module answered without the ID '
        'of a lesfiche (HTTP $status: ${_preview(response.data ?? '')}). '
        '$unconfirmed',
        statusCode: status,
      );
    }

    final made = '$operation: $what was made with ID $id (HTTP $status), but';
    const readIt =
        'Read it (getDetailById) before anything else, and do not make it '
        'again: it exists. Moving it to the trash (trash) is safe.';
    final LessonContentDetail detail;
    try {
      detail = await _readDetail(type, id, courseNames: courses.names);
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$made reading it back failed ($e). $readIt',
          cause: e,
          lessonContentId: id,
        ),
        stackTrace,
      );
    }
    final missing = [
      if (detail.name != newName)
        'the name "$newName" (it has "${detail.name}")',
      if (!_sameIds(
        detail.courses.map((c) => c.id),
        courses.wire.map((c) => c['id']! as String),
      ))
        'the courses sent (it has ${_ids(detail.courses.map((c) => c.id))})',
      for (final link in links)
        if (!detail.weblinks.any(
          (w) =>
              w.name == link.name &&
              w.url == link.url &&
              w.visibility == link.visibility,
        ))
          'weblink "${link.name}" (${link.url}, ${link.visibility.optionName})',
      for (final file in files)
        if (!detail.attachments.any(
          (a) => a.fileName == file.fileName && a.visibility == file.visibility,
        ))
          'attachment "${file.fileName}" (${file.visibility.optionName})',
    ];
    if (missing.isNotEmpty) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$made its detail does not show ${missing.join('; ')}. $readIt',
        lessonContentId: id,
      );
    }
    return detail;
  }

  // ---------------------------------------------------------------------------
  // Edits (#129)
  // ---------------------------------------------------------------------------

  /// Renames the lesfiche [item] to [name] (sent without the white space
  /// around it), and returns its detail as the module answers it (#129).
  ///
  /// Sends `POST lessons/{id}/rename` (or `assignments/...`) with
  /// `{"newName"}`, which the module answers with `200` and the whole
  /// lesfiche (seen live, 2026-10-05); the answer must have the new name.
  /// The module refuses an empty name with a bare `400` (seen live), and
  /// keeps a name that another lesfiche has. Retried once after logging in
  /// again, as a read is: it sets a value.
  ///
  /// The detail's courses have no names ([LessonContentCourse.name] `null`):
  /// read [getDetail] for them. The same for the other edits but
  /// [changeCourses].
  ///
  /// Throws an [ArgumentError], without sending anything, for a name that is
  /// empty or longer than [maxNameLength], a lesfiche of a kind this library
  /// does not know, or an ID that is not a UUID. A lesfiche the module does
  /// not know, or one in the trash (seen live), is a
  /// [SmartschoolLessonContentNotFoundError]. See the class doc for the
  /// other errors.
  Future<LessonContentDetail> rename(
    LessonContentItem item,
    String name,
  ) async {
    _checkItem(item);
    final newName = _checkedName(name);
    return _edit(
      'rename',
      item,
      'rename',
      {'newName': newName},
      change: 'the rename of ${_what(item)} to "$newName"',
      mismatch: (detail) =>
          detail.name == newName ? null : 'the name "${detail.name}"',
    );
  }

  /// Changes the icon of the lesfiche [item] to [icon], one of Smartschool's
  /// icon names (such as `book`), and returns its detail (#129).
  ///
  /// Sends `POST lessons/{id}/change-icon` with `{"newIcon"}` (seen live,
  /// 2026-10-05, with `book`); the answer must have the new icon. The module
  /// was not seen checking the icon name. See [rename] for the rest.
  Future<LessonContentDetail> changeIcon(
    LessonContentItem item,
    String icon,
  ) async {
    _checkItem(item);
    final newIcon = _checkedIcon(icon);
    return _edit(
      'changeIcon',
      item,
      'change-icon',
      {'newIcon': newIcon},
      change: 'the change of the icon of ${_what(item)} to "$newIcon"',
      mismatch: (detail) =>
          detail.icon == newIcon ? null : 'the icon "${detail.icon}"',
    );
  }

  /// Changes the info that pupils see of the lesfiche [item] to [publicInfo]
  /// (HTML; `''` clears it), and returns its detail (#129).
  ///
  /// Sends `POST lessons/{id}/change-public-info` with `{"newPublicInfo"}`
  /// (seen live, 2026-10-05: the answer held the info as sent). The answer
  /// is returned as the module stored the info; the service does not
  /// compare it with [publicInfo], since the module may store HTML in its
  /// own way. See [rename] for the rest.
  Future<LessonContentDetail> changePublicInfo(
    LessonContentItem item,
    String publicInfo,
  ) async {
    _checkItem(item);
    return _edit('changePublicInfo', item, 'change-public-info', {
      'newPublicInfo': publicInfo,
    }, change: 'the change of the public info of ${_what(item)}');
  }

  /// Changes the info that only the teacher sees of the lesfiche [item] to
  /// [privateInfo] (HTML; `''` clears it), and returns its detail (#129).
  ///
  /// Sends `POST lessons/{id}/change-private-info` with `{"newPrivateInfo"}`
  /// (seen live, 2026-10-05). See [changePublicInfo] for the rest.
  Future<LessonContentDetail> changePrivateInfo(
    LessonContentItem item,
    String privateInfo,
  ) async {
    _checkItem(item);
    return _edit('changePrivateInfo', item, 'change-private-info', {
      'newPrivateInfo': privateInfo,
    }, change: 'the change of the private info of ${_what(item)}');
  }

  /// Sets the courses of the lesfiche [item] to [courseIds] (IDs of
  /// [getCourses]; empty clears them), and returns its detail with the
  /// courses named (#129).
  ///
  /// Reads the school's courses first ([getCourses]): the module stores a
  /// course it does not know without complaint (seen live, 2026-10-05), so
  /// an ID that is not one of the school's courses is an [ArgumentError],
  /// and nothing is sent. Then sends `POST lessons/{id}/change-courses` with
  /// `{"newCourses": [{platformId, id}]}`; the answer must have exactly
  /// those courses. An ID given twice is sent once. See [rename] for the
  /// rest.
  Future<LessonContentDetail> changeCourses(
    LessonContentItem item,
    Iterable<String> courseIds,
  ) async {
    _checkItem(item);
    final courses = await _checkedCourses(_checkedCourseIds(courseIds));
    final sent = courses.wire.map((c) => c['id']! as String);
    return _edit(
      'changeCourses',
      item,
      'change-courses',
      {'newCourses': courses.wire},
      change: 'the change of the courses of ${_what(item)} to ${_ids(sent)}',
      courseNames: courses.names,
      mismatch: (detail) {
        final has = detail.courses.map((c) => c.id);
        return _sameIds(has, sent) ? null : 'the courses ${_ids(has)}';
      },
    );
  }

  /// Shows ([visible] `true`) or hides the lesfiche [item] in the module,
  /// and returns its detail (#129).
  ///
  /// Sends `POST lessons/{id}/mark-as-visible` or `.../mark-as-invisible`
  /// with `{}` (both seen live, 2026-10-05); the answer must have
  /// [LessonContentItem.isVisible] as asked. A hidden lesfiche is still
  /// listed by [getItems], and can still be planned (seen live, #88). See
  /// [rename] for the rest.
  Future<LessonContentDetail> setVisible(
    LessonContentItem item,
    bool visible,
  ) async {
    _checkItem(item);
    return _edit(
      'setVisible',
      item,
      visible ? 'mark-as-visible' : 'mark-as-invisible',
      const <String, Object?>{},
      change: '${visible ? 'showing' : 'hiding'} ${_what(item)}',
      mismatch: (detail) =>
          detail.isVisible == visible ? null : 'isVisible ${detail.isVisible}',
    );
  }

  // ---------------------------------------------------------------------------
  // Weblinks (#129)
  // ---------------------------------------------------------------------------

  /// Adds [weblink] to the lesfiche [item], and returns the weblink the
  /// module made (#129).
  ///
  /// Sends `POST lessons/{id}/weblinks` (or `assignments/...`) with
  /// `{"newName", "newIcon", "newUrl", "newVisibility"}`, which the module
  /// answers with `200` and the new weblink only (seen live, 2026-10-05). It
  /// must have the name, address, icon and visibility sent. The address is
  /// sent as the web client sends it ([normalizeWeblinkUrl]); the module
  /// refuses one without `http(s)://`, or that is not a URL, with a bare
  /// `400` (seen live).
  ///
  /// Sent **once**, never again after logging in again: a second one adds a
  /// second weblink.
  ///
  /// Throws an [ArgumentError], without sending anything, for a weblink with
  /// an empty name or icon, an address the web client refuses, or a
  /// visibility it does not offer, a lesfiche of a kind this library does
  /// not know, or an ID that is not a UUID. See the class doc for the other
  /// errors.
  Future<LessonContentWeblink> addWeblink(
    LessonContentItem item,
    NewLessonContentWeblink weblink,
  ) async {
    _checkItem(item);
    final link = _checkedWeblink(weblink, argument: 'weblink');
    return _weblinkWrite(
      'addWeblink',
      item,
      link,
      path: '${_itemPath(item.type, item.id)}/weblinks',
      retryAfterLogin: false,
      change: 'the addition of weblink "${link.name}" to ${_what(item)}',
      unconfirmed:
          'It may or may not have been added: read the lesfiche (getDetail) '
          'before trying again; trying again adds a second weblink if it was '
          'added.',
    );
  }

  /// Changes the weblink [weblinkId] of the lesfiche [item]
  /// ([LessonContentWeblink.id]) to the name, address, icon and visibility
  /// of [weblink], and returns the weblink as the module answers it (#129).
  ///
  /// Sends `POST lessons/{id}/weblinks/{weblinkId}` with the same body as
  /// [addWeblink], which the module answers with `200` and the weblink (seen
  /// live, 2026-10-05); it must be that weblink, with the values sent. Every
  /// value is sent, so give the ones that stay the same too. Retried once
  /// after logging in again, as a read is: it sets values. See [addWeblink]
  /// for the rest.
  Future<LessonContentWeblink> changeWeblink(
    LessonContentItem item,
    String weblinkId,
    NewLessonContentWeblink weblink,
  ) async {
    _checkItem(item);
    _checkId(weblinkId, 'weblinkId');
    final link = _checkedWeblink(weblink, argument: 'weblink');
    return _weblinkWrite(
      'changeWeblink',
      item,
      link,
      path: '${_itemPath(item.type, item.id)}/weblinks/$weblinkId',
      weblinkId: weblinkId,
      retryAfterLogin: true,
      change: 'the change of weblink $weblinkId of ${_what(item)}',
      unconfirmed:
          'It may or may not have been changed: read the lesfiche '
          '(getDetail) before trying again; sending the change again is '
          'harmless.',
    );
  }

  /// Removes the weblink [weblinkId] from the lesfiche [item] (#129).
  ///
  /// Sends `DELETE lessons/{id}/weblinks/{weblinkId}`, which the module
  /// answers with `204` (seen live, 2026-10-05). It removes the weblink from
  /// the lesfiche; the lesfiche stays. Retried once after logging in again.
  ///
  /// Throws an [ArgumentError], without sending anything, for a lesfiche of
  /// a kind this library does not know, or IDs that are not UUIDs. See the
  /// class doc for the other errors.
  Future<void> removeWeblink(LessonContentItem item, String weblinkId) async {
    _checkItem(item);
    _checkId(weblinkId, 'weblinkId');
    await _remove(
      'removeWeblink',
      item,
      'weblinks/$weblinkId',
      'the removal of weblink $weblinkId from ${_what(item)}',
    );
  }

  // ---------------------------------------------------------------------------
  // Attachments (#129)
  // ---------------------------------------------------------------------------

  /// Adds the files of [attachments] to the lesfiche [item], and returns the
  /// attachments the module made of them, in the order of [attachments],
  /// each with the visibility asked for (#129).
  ///
  /// The steps:
  /// 1. `GET lessons/{id}` (or `assignments/...`): the lesfiche's
  ///    attachments before, to tell the new ones by their IDs (the module
  ///    keeps two attachments of the same name, seen live).
  /// 2. A new upload directory and each file uploaded into it, as for
  ///    [createLesson]; retried after logging in again.
  /// 3. `POST lessons/{id}/attachments` with `{"randomDir"}`, which the
  ///    module answers with `200` and the whole lesfiche (seen live,
  ///    2026-10-05). Sent **once**, never again after logging in again: the
  ///    module takes the files of a directory again every time it is told
  ///    to. The new attachments must be exactly the files uploaded.
  /// 4. The module gives each new attachment the visibility
  ///    [LessonContentVisibility.always], and ignores `visibilityOptions` in
  ///    that body (seen live). So for each attachment that asks for another
  ///    one, [changeAttachmentVisibility].
  ///
  /// Throws an [ArgumentError], without sending anything, for no
  /// attachments, a file that does not exist or has a name Smartschool does
  /// not allow, two files of the same name, a visibility the web client does
  /// not offer, a lesfiche of a kind this library does not know, or an ID
  /// that is not a UUID. A failure of step 1 is a
  /// [SmartschoolLessonContentError] (a
  /// [SmartschoolLessonContentNotFoundError] for a lesfiche the module does
  /// not know), and one of step 2 a [SmartschoolAttachmentUploadError]:
  /// nothing was changed. When step 4 fails, the files were added: a
  /// [SmartschoolLessonContentSaveUnconfirmedError] says which visibility
  /// was not set. See the class doc for the other errors.
  Future<List<LessonContentAttachment>> addAttachments(
    LessonContentItem item,
    List<NewLessonContentAttachment> attachments,
  ) async {
    const operation = 'addAttachments';
    _checkItem(item);
    if (attachments.isEmpty) {
      throw ArgumentError.value(attachments, 'attachments', 'is empty');
    }
    final files = _checkedFiles(attachments);

    final before = {
      for (final attachment in (await _readDetail(
        item.type,
        item.id,
      )).attachments)
        attachment.id.toLowerCase(),
    };

    final uploader = SmartschoolUploader(_client);
    final uploadDir = await uploader.newDirectory();
    for (final file in files) {
      await uploader.uploadFile(uploadDir, file.path);
    }

    final count = files.length == 1
        ? 'file "${files.single.fileName}"'
        : '${files.length} files';
    final change = 'the addition of $count to ${_what(item)}';
    const unconfirmed =
        'They may or may not have been added: read the lesfiche (getDetail) '
        'before trying again; trying again adds the files a second time if '
        'they were added.';
    final response = await _write(
      operation,
      path: '${_itemPath(item.type, item.id)}/attachments',
      body: {'randomDir': uploadDir},
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
      item: item,
    );
    final detail = _detailAnswer(
      operation,
      response,
      item,
      change,
      unconfirmed,
    );

    final added = [
      for (final attachment in detail.attachments)
        if (!before.contains(attachment.id.toLowerCase())) attachment,
    ];
    final sentNames = [for (final file in files) file.fileName]..sort();
    final addedNames = [for (final a in added) a.fileName]..sort();
    if (sentNames.join('\u0000') != addedNames.join('\u0000')) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$operation: $change was sent, but $_module answered with '
        '${addedNames.isEmpty ? 'no new attachments' : 'the new attachments ${addedNames.map((n) => '"$n"').join(', ')}'}. '
        '$unconfirmed',
        statusCode: response.statusCode,
        lessonContentId: item.id,
      );
    }

    final result = <LessonContentAttachment>[];
    for (final file in files) {
      final attachment = added.firstWhere((a) => a.fileName == file.fileName);
      if (attachment.visibility == file.visibility) {
        result.add(attachment);
        continue;
      }
      final LessonContentDetail changed;
      try {
        changed = await changeAttachmentVisibility(
          item,
          attachment.id,
          file.visibility,
        );
      } on Exception catch (e, stackTrace) {
        Error.throwWithStackTrace(
          SmartschoolLessonContentSaveUnconfirmedError(
            '$operation: $change went through (attachment "${file.fileName}" '
            'is ${attachment.id}), but setting its visibility to '
            '${file.visibility.optionName} failed ($e). Do not add the files '
            'again: set the visibility with changeAttachmentVisibility, after '
            'reading the lesfiche (getDetail).',
            cause: e,
            lessonContentId: item.id,
          ),
          stackTrace,
        );
      }
      result.add(
        changed.attachments.firstWhere(
          (a) => a.id.toLowerCase() == attachment.id.toLowerCase(),
        ),
      );
    }
    return result;
  }

  /// Sets when pupils see the attachment [attachmentId] of the lesfiche
  /// [item] ([LessonContentAttachment.id]) to [visibility], and returns the
  /// lesfiche's detail (#129).
  ///
  /// Sends `POST lessons/{id}/attachments/{attachmentId}/change-visibility`
  /// with `{"newVisibility": {"option", "daysAfterEnd"}}` (seen live,
  /// 2026-10-05); the answer must have the attachment with that visibility.
  /// Retried once after logging in again, as a read is: it sets a value.
  ///
  /// Throws an [ArgumentError], without sending anything, for a visibility
  /// the web client does not offer, a lesfiche of a kind this library does
  /// not know, or IDs that are not UUIDs. See the class doc for the other
  /// errors.
  Future<LessonContentDetail> changeAttachmentVisibility(
    LessonContentItem item,
    String attachmentId,
    LessonContentVisibility visibility,
  ) async {
    _checkItem(item);
    _checkId(attachmentId, 'attachmentId');
    _checkVisibility(visibility, 'visibility');
    return _edit(
      'changeAttachmentVisibility',
      item,
      'attachments/$attachmentId/change-visibility',
      {'newVisibility': visibility.toJson()},
      change:
          'the change of the visibility of attachment $attachmentId of '
          '${_what(item)} to ${visibility.optionName}',
      mismatch: (detail) {
        final attachment = detail.attachments
            .where((a) => a.id.toLowerCase() == attachmentId.toLowerCase())
            .firstOrNull;
        if (attachment == null) return 'no attachment $attachmentId';
        return attachment.visibility == visibility
            ? null
            : 'the attachment with visibility ${attachment.visibility}';
      },
    );
  }

  /// Removes the attachment [attachmentId] from the lesfiche [item] (#129).
  ///
  /// Sends `DELETE lessons/{id}/attachments/{attachmentId}`, as the web
  /// client does, which the module answers with `204` (seen live,
  /// 2026-10-05). It removes the file from the lesfiche; the lesfiche stays.
  /// Retried once after logging in again. See [removeWeblink] for the rest.
  Future<void> removeAttachment(
    LessonContentItem item,
    String attachmentId,
  ) async {
    _checkItem(item);
    _checkId(attachmentId, 'attachmentId');
    await _remove(
      'removeAttachment',
      item,
      'attachments/$attachmentId',
      'the removal of attachment $attachmentId from ${_what(item)}',
    );
  }

  // ---------------------------------------------------------------------------
  // Trash (#129)
  // ---------------------------------------------------------------------------

  /// Moves the lesfiches [items] to the module's trash (#129).
  ///
  /// Sends `POST lesson-content/trash/bulk` with `{"lessonContent": [{"id",
  /// "type", "platformId"}]}`, as the web client does, which the module
  /// answers with `200` and `{"exceptions": []}` (seen live, 2026-10-05).
  /// The lesfiches then leave [getItems]; their detail is still answered,
  /// and the web client lists them in its trash, from where it can restore
  /// or delete them for good. The service does neither: it never deletes a
  /// lesfiche for good. A lesfiche given twice is sent once. Retried once
  /// after logging in again.
  ///
  /// The module answers the move of a lesfiche that is in the trash already
  /// with a bare `500` (seen live), a
  /// [SmartschoolLessonContentSaveUnconfirmedError]; so is an answer whose
  /// `exceptions` are not empty (not seen live; they are listed in the
  /// message): check [getItems] before trying again.
  ///
  /// Throws an [ArgumentError], without sending anything, for no lesfiches,
  /// a lesfiche of a kind this library does not know, or an ID that is not a
  /// UUID. See the class doc for the other errors.
  Future<void> trash(Iterable<LessonContentItem> items) async {
    const operation = 'trash';
    final fiches = <String, LessonContentItem>{};
    for (final item in items) {
      _checkItem(item, argument: 'items');
      fiches.putIfAbsent(
        '${item.typeName} ${item.id.toLowerCase()}',
        () => item,
      );
    }
    if (fiches.isEmpty) {
      throw ArgumentError.value(items, 'items', 'is empty');
    }
    final list = fiches.values.toList();
    final change = list.length == 1
        ? 'the move of ${_what(list.single)} to the trash'
        : 'the move of ${list.length} lesfiches to the trash';
    const unconfirmed =
        'They may or may not be in the trash: look for them in the lesfiches '
        '(getItems) before trying again; the module answers the move of a '
        'lesfiche that is in the trash already with HTTP 500.';
    final response = await _write(
      operation,
      path: '$_apiPath/lesson-content/trash/bulk',
      body: {
        'lessonContent': [
          for (final item in list)
            {
              'id': item.id,
              'type': item.typeName,
              'platformId': item.platformId,
            },
        ],
      },
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
      item: list.length == 1 ? list.single : null,
    );
    if (response.statusCode != 200) {
      _throwFailure(
        operation,
        response,
        change,
        unconfirmed,
        item: list.length == 1 ? list.single : null,
      );
    }
    final json = _jsonObject(operation, response, change, unconfirmed);
    final exceptions = json['exceptions'];
    final failures = switch (exceptions) {
      final List<Object?> list => list,
      final Map<Object?, Object?> map => map.values.toList(),
      _ => null,
    };
    if (failures == null || failures.isNotEmpty) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$operation: $change was sent, but $_module answered '
        '${failures == null ? 'without its exceptions (${_preview(response.data ?? '')})' : 'with exceptions: ${failures.map(_describeException).join('; ')}'}. '
        '$unconfirmed',
        statusCode: 200,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (exposed for testing)
  // ---------------------------------------------------------------------------

  /// [url] as the Lesfiches web client sends the address of a weblink, or
  /// `null` when its weblink dialog would refuse it (#129).
  ///
  /// As the web client (its `transformUrl` and `isValid`): the white space
  /// around it is dropped; an address with more than one `?` is refused;
  /// before the `?`, all white space is removed, and after it, the query is
  /// percent-encoded as `encodeURI` does (a space becomes `%20`); `http://`
  /// goes in front when it does not start with `http://` or `https://` (in
  /// any case); and then it must hold an address of the form the web client
  /// checks (a host name with a dot and a top-level domain of letters, such
  /// as `example.com`, after `http(s)://`). Unlike `encodeURI`, an escape
  /// that is in the query already (`%20`) is kept as it is, so an address
  /// that is encoded already is not encoded a second time.
  ///
  /// So `example.com/page` gives `http://example.com/page`,
  /// `https://example.com/?q=a b` gives `https://example.com/?q=a%20b`, and
  /// `geen url` gives `null`. The module itself refuses an address without
  /// `http(s)://`, and one that is not a URL, with a bare HTTP `400` (seen
  /// live, 2026-10-05), and stored `https://example.com/r129?q=a%20b` as it
  /// was sent.
  static String? normalizeWeblinkUrl(String url) {
    final parts = url.trim().split('?');
    if (parts.length > 2) return null;
    var address = parts.first.replaceAll(RegExp(r'\s'), '');
    if (parts.length == 2 && parts.last.isNotEmpty) {
      address = '$address?${_encodeQuery(parts.last)}';
    }
    if (address.isEmpty) return null;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(address)) {
      address = 'http://$address';
    }
    return _webAddress.hasMatch(address) ? address : null;
  }

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
    final names = _names(courses);
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

  /// Parses the detail of a lesfiche (a JSON object, #129), naming its
  /// courses after [courses] as [parseItems] does.
  static LessonContentDetail parseDetail(
    dynamic json, {
    Iterable<PlannerCourse> courses = const [],
  }) {
    if (json is! Map<String, dynamic>) {
      throw SmartschoolLessonContentError(
        '$_module gave the lesfiche as ${json.runtimeType} instead of an '
        'object.',
      );
    }
    return LessonContentDetail.fromJson(json, courseNames: _names(courses));
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

  /// The school's courses, read to name the courses of [items], which were
  /// read; a course list that cannot be used is a
  /// [SmartschoolLessonContentCourseListError] with [items] (#118).
  Future<List<PlannerCourse>> _coursesFor(List<LessonContentItem> items) async {
    try {
      return await getCourses();
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
  }

  /// The names of [courses] by course ID, of those that have one.
  static Map<String, String> _names(Iterable<PlannerCourse> courses) => {
    for (final course in courses)
      if (course.name.isNotEmpty) course.id: course.name,
  };

  /// Reads the detail of the lesfiche [id] of the kind [type], with its
  /// courses named after [courseNames]; see [getDetailById].
  Future<LessonContentDetail> _readDetail(
    LessonContentType type,
    String id, {
    Map<String, String> courseNames = const {},
  }) async {
    final what = '${_noun(type)} $id';
    final response = await _client.getResponse(_itemPath(type, id));
    if (response.statusCode == 404) {
      throw SmartschoolLessonContentNotFoundError(
        '$_module knows no $what (HTTP 404): an unknown ID, or the ID of '
        'another kind of lesfiche.',
        type: type,
        id: id,
      );
    }
    final json = _decode(response, what, _module);
    if (json is! Map<String, dynamic>) {
      throw SmartschoolLessonContentError(
        '$_module gave $what as ${json.runtimeType} instead of an object.',
      );
    }
    final detail = LessonContentDetail.fromJson(json, courseNames: courseNames);
    if (detail.id.toLowerCase() != id.toLowerCase() || detail.type != type) {
      throw SmartschoolLessonContentError(
        '$_module answered $what with another lesfiche: ${detail.typeName} '
        '${detail.id}.',
      );
    }
    return detail;
  }

  /// Checks [courseIds] (each a UUID; one given twice is kept once), and
  /// returns them in their order. Throws an [ArgumentError] otherwise.
  static List<String> _checkedCourseIds(Iterable<String> courseIds) {
    final seen = <String>{};
    return [
      for (final id in courseIds)
        if (seen.add(_checkId(id.trim(), 'courseIds').toLowerCase())) id.trim(),
    ];
  }

  /// The courses [ids] as a write sends them, after checking that each is
  /// one of the school's courses ([getCourses], read only when there are
  /// [ids]), with the names of the school's courses.
  Future<_Courses> _checkedCourses(List<String> ids) async {
    if (ids.isEmpty) {
      return (
        wire: const <Map<String, Object>>[],
        names: const <String, String>{},
      );
    }
    final school = await getCourses();
    final byId = {for (final course in school) course.id.toLowerCase(): course};
    final unknown = [
      for (final id in ids)
        if (!byId.containsKey(id.toLowerCase())) id,
    ];
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
        unknown,
        'courseIds',
        'names courses the school does not have (getCourses): '
            '${unknown.join(', ')}. Smartschool would store them without '
            'complaint. Nothing was sent',
      );
    }
    return (
      wire: [
        for (final id in ids)
          {
            'platformId': byId[id.toLowerCase()]!.platformId,
            'id': byId[id.toLowerCase()]!.id,
          },
      ],
      names: _names(school),
    );
  }

  /// Checks that [typeId] is one of the school's assignment types, as the
  /// module lists them; throws an [ArgumentError] otherwise.
  Future<void> _checkAssignmentType(String typeId) async {
    final response = await _client.getResponse(_assignmentTypesPath);
    final json = _decode(response, 'the assignment types', _module);
    if (json is! List) {
      throw SmartschoolLessonContentError(
        '$_module gave the assignment types as ${json.runtimeType} instead '
        'of a list.',
      );
    }
    final types = [
      for (final (index, type) in json.indexed)
        if (type is Map<String, dynamic>)
          _assignmentType(type, index)
        else
          throw SmartschoolLessonContentError(
            '$_module gave assignment type $index as ${type.runtimeType} '
            'instead of an object.',
          ),
    ];
    if (types.any((t) => t.id.toLowerCase() == typeId.toLowerCase())) return;
    throw ArgumentError.value(
      typeId,
      'assignmentTypeId',
      'is not one of the school\'s assignment types '
          '(${types.map((t) => '${t.name} ${t.id}').join(', ')}). Nothing was '
          'sent',
    );
  }

  /// Assignment type [index] of the module's list.
  static PlannerAssignmentType _assignmentType(
    Map<String, dynamic> json,
    int index,
  ) {
    try {
      return PlannerAssignmentType.fromJson(json);
    } on SmartschoolPlannerError catch (e) {
      throw SmartschoolLessonContentError(
        '$_module gave assignment type $index in an unknown shape: '
        '${e.message}',
      );
    }
  }

  /// Sends the edit [body] of [item] to its path with [action] (retried once
  /// after logging in again), and returns the lesfiche the module answers
  /// with, after checking that it is [item], and that [mismatch] finds no
  /// difference with what was sent.
  Future<LessonContentDetail> _edit(
    String operation,
    LessonContentItem item,
    String action,
    Map<String, Object?> body, {
    required String change,
    String? Function(LessonContentDetail detail)? mismatch,
    Map<String, String> courseNames = const {},
  }) async {
    const unconfirmed =
        'It may or may not have been changed: read the lesfiche (getDetail) '
        'before trying again; sending the change again is harmless.';
    final response = await _write(
      operation,
      path: '${_itemPath(item.type, item.id)}/$action',
      body: body,
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
      item: item,
    );
    return _detailAnswer(
      operation,
      response,
      item,
      change,
      unconfirmed,
      mismatch: mismatch,
      courseNames: courseNames,
    );
  }

  /// The lesfiche [item] as the module answered the write [change] with it
  /// ([response], which must have status `200`), checked with [mismatch].
  LessonContentDetail _detailAnswer(
    String operation,
    Response<String> response,
    LessonContentItem item,
    String change,
    String unconfirmed, {
    String? Function(LessonContentDetail detail)? mismatch,
    Map<String, String> courseNames = const {},
  }) {
    if (response.statusCode != 200) {
      _throwFailure(operation, response, change, unconfirmed, item: item);
    }
    final json = _jsonObject(
      operation,
      response,
      change,
      unconfirmed,
      item: item,
    );
    final LessonContentDetail detail;
    try {
      detail = LessonContentDetail.fromJson(json, courseNames: courseNames);
    } on SmartschoolLessonContentError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$operation: $change was sent, but $_module\'s answer cannot be '
          'read (${e.message}). $unconfirmed',
          statusCode: 200,
          cause: e,
          lessonContentId: item.id,
        ),
        stackTrace,
      );
    }
    final problem =
        detail.id.toLowerCase() != item.id.toLowerCase() ||
            detail.type != item.type
        ? 'another lesfiche (${detail.typeName} ${detail.id})'
        : mismatch?.call(detail);
    if (problem != null) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$operation: $change was sent, but $_module answered with $problem. '
        '$unconfirmed',
        statusCode: 200,
        lessonContentId: item.id,
      );
    }
    return detail;
  }

  /// Sends the weblink [link] to [path] (an add, or the change of
  /// [weblinkId]), and returns the weblink the module answers with, after
  /// checking that it has the values sent.
  Future<LessonContentWeblink> _weblinkWrite(
    String operation,
    LessonContentItem item,
    _Weblink link, {
    required String path,
    String? weblinkId,
    required bool retryAfterLogin,
    required String change,
    required String unconfirmed,
  }) async {
    final response = await _write(
      operation,
      path: path,
      body: {
        'newName': link.name,
        'newIcon': link.icon,
        'newUrl': link.url,
        'newVisibility': link.visibility.toJson(),
      },
      retryAfterLogin: retryAfterLogin,
      change: change,
      unconfirmed: unconfirmed,
      item: item,
    );
    final status = response.statusCode ?? 0;
    if (status != 200 && status != 201) {
      _throwFailure(operation, response, change, unconfirmed, item: item);
    }
    final json = _jsonObject(
      operation,
      response,
      change,
      unconfirmed,
      item: item,
    );
    final LessonContentWeblink weblink;
    try {
      weblink = LessonContentWeblink.fromJson(json);
    } on SmartschoolLessonContentError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$operation: $change was sent, but $_module\'s answer cannot be '
          'read as a weblink (${e.message}). $unconfirmed',
          statusCode: status,
          cause: e,
          lessonContentId: item.id,
        ),
        stackTrace,
      );
    }
    final String? problem;
    if (weblinkId != null &&
        weblink.id.toLowerCase() != weblinkId.toLowerCase()) {
      problem = 'another weblink (${weblink.id})';
    } else if (weblink.name != link.name ||
        weblink.url != link.url ||
        weblink.icon != link.icon ||
        weblink.visibility != link.visibility) {
      problem =
          'a weblink with other values: "${weblink.name}", ${weblink.url}, '
          '${weblink.icon}, ${weblink.visibility}';
    } else {
      problem = null;
    }
    if (problem != null) {
      throw SmartschoolLessonContentSaveUnconfirmedError(
        '$operation: $change was sent, but $_module answered with $problem. '
        '$unconfirmed',
        statusCode: status,
        lessonContentId: item.id,
      );
    }
    return weblink;
  }

  /// Sends `DELETE` to [rest] of [item] (a weblink or an attachment), which
  /// the module answers with `204`.
  Future<void> _remove(
    String operation,
    LessonContentItem item,
    String rest,
    String change,
  ) async {
    const unconfirmed =
        'It may or may not have been removed: read the lesfiche (getDetail) '
        'before trying again.';
    final response = await _write(
      operation,
      path: '${_itemPath(item.type, item.id)}/$rest',
      delete: true,
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
      item: item,
    );
    final status = response.statusCode ?? 0;
    if (status == 204 || status == 200) return;
    _throwFailure(operation, response, change, unconfirmed, item: item);
  }

  /// Sends the write [body] to [path] (or a `DELETE` of [path] when
  /// [delete]) and returns the module's answer, whatever its status.
  ///
  /// A session that Smartschool refuses (a [SmartschoolAuthenticationError])
  /// is thrown as it is: the write was not carried out. Any other failure is
  /// a [SmartschoolLessonContentSaveUnconfirmedError] that ends in
  /// [unconfirmed]: the write may have reached the module.
  Future<Response<String>> _write(
    String operation, {
    required String path,
    Map<String, Object?>? body,
    bool delete = false,
    required bool retryAfterLogin,
    required String change,
    required String unconfirmed,
    LessonContentItem? item,
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
      // Refused before the module handled it (and, for a create, not sent
      // again): nothing was changed.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolLessonContentSaveUnconfirmedError(
          '$operation: $change was sent, but no answer came in ($e). '
          '$unconfirmed',
          cause: e,
          lessonContentId: item?.id,
        ),
        stackTrace,
      );
    }
  }

  /// The JSON object of the module's answer [response] to a write, or a
  /// [SmartschoolLessonContentSaveUnconfirmedError] when it is not one.
  static Map<String, dynamic> _jsonObject(
    String operation,
    Response<String> response,
    String change,
    String unconfirmed, {
    LessonContentItem? item,
  }) {
    final status = response.statusCode ?? 0;
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
      lessonContentId: item?.id,
    );
  }

  /// Throws the error for the module's answer [response] to a write, which
  /// has another status than the write expects: a
  /// [SmartschoolLessonContentNotFoundError] for `404` (for the write of an
  /// [item]), a [SmartschoolLessonContentWriteRefusedError] for another
  /// status from `400` to `499`, and a
  /// [SmartschoolLessonContentSaveUnconfirmedError] that ends in
  /// [unconfirmed] for any other status.
  static Never _throwFailure(
    String operation,
    Response<String> response,
    String change,
    String unconfirmed, {
    LessonContentItem? item,
  }) {
    final status = response.statusCode ?? 0;
    final body = (response.data ?? '').trim();
    if (status == 404 && item != null) {
      throw SmartschoolLessonContentNotFoundError(
        '$operation: $_module answered $change with HTTP 404: it knows no '
        'such lesfiche (an unknown ID, or a lesfiche in the trash), or the '
        'lesfiche has no such weblink or attachment. Nothing was changed.',
        type: item.type,
        id: item.id,
      );
    }
    if (status >= 400 && status < 500) {
      final violations = _violations(body);
      final why = violations.isEmpty
          ? 'without saying why'
          : violations.map((v) => '"$v"').join(', ');
      throw SmartschoolLessonContentWriteRefusedError(
        '$operation: $_module refused $change (HTTP $status), $why. Nothing '
        'was changed.',
        statusCode: status,
        violations: violations,
      );
    }
    throw SmartschoolLessonContentSaveUnconfirmedError(
      '$operation: $change was sent, but $_module answered with HTTP '
      '$status${body.isEmpty ? '' : ' (${_preview(body)})'}. $unconfirmed',
      statusCode: status,
      lessonContentId: item?.id,
    );
  }

  /// The `violations` of the module's problem answer [body]: a list, or an
  /// object whose values are the reasons; empty when there are none (the
  /// bare `400` seen live), or when [body] is not such an answer.
  static List<String> _violations(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    final raw = decoded is Map ? decoded['violations'] : null;
    final Iterable<Object?> values = switch (raw) {
      final List<Object?> list => list,
      final Map<Object?, Object?> map => map.values,
      _ => const [],
    };
    return List.unmodifiable([
      for (final value in values)
        if (value != null && '$value'.trim().isNotEmpty) '$value'.trim(),
    ]);
  }

  /// One of the `exceptions` of a move to the trash, for a message: its
  /// `title`, `detail` and `violations` when it is a problem object.
  static String _describeException(Object? exception) {
    if (exception is! Map) return '"$exception"';
    final parts = [
      for (final key in const ['title', 'detail'])
        if ('${exception[key] ?? ''}'.trim().isNotEmpty)
          '${exception[key]}'.trim(),
      ..._violations(jsonEncode(exception)),
    ];
    return parts.isEmpty ? jsonEncode(exception) : parts.join(': ');
  }

  // ---------------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------------

  /// A lesfiche, weblink, attachment or course ID: a UUID.
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// The Lesfiches web client's check of a weblink's address (`isValid` of
  /// its weblink dialog), as it has it: not anchored.
  static final _webAddress = RegExp(
    r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._+~#=]{2,256}\.[a-z]{2,63}\b'
    r'([-a-zA-Z0-9@:%_+.~#?&//=]*)',
    caseSensitive: false,
  );

  /// [query] percent-encoded as `encodeURI` does, keeping the escapes that
  /// are in it already.
  static String _encodeQuery(String query) => query.splitMapJoin(
    RegExp('%[0-9a-fA-F]{2}'),
    onMatch: (match) => match[0]!,
    onNonMatch: Uri.encodeFull,
  );

  /// [id] when it is a UUID; an [ArgumentError] for [argument] otherwise.
  static String _checkId(String id, String argument) {
    if (_uuid.hasMatch(id)) return id;
    throw ArgumentError.value(id, argument, 'is not a UUID');
  }

  /// The path of the module's API for [type] (`lessons`, `assignments`); an
  /// [ArgumentError] for [argument] when it is [LessonContentType.other].
  static String _kindPath(LessonContentType type, String argument) {
    final wire = type.wireName;
    if (wire != null) return wire;
    throw ArgumentError.value(
      type,
      argument,
      'is a kind of lesfiche this library does not know: only lessons and '
      'assignments can be read and written',
    );
  }

  /// Throws an [ArgumentError] (for [argument]) unless [item] is a lesson or
  /// an assignment with a UUID.
  static void _checkItem(LessonContentItem item, {String argument = 'item'}) {
    if (item.type == LessonContentType.other) {
      throw ArgumentError.value(
        item,
        argument,
        'is a lesfiche of a kind this library does not know '
        '("${item.typeName}"): only lessons and assignments can be '
        'written',
      );
    }
    if (!_uuid.hasMatch(item.id)) {
      throw ArgumentError.value(item, argument, 'has an ID that is not a UUID');
    }
  }

  /// The path of the lesfiche [id] of the kind [type].
  static String _itemPath(LessonContentType type, String id) =>
      '$_apiPath/${_kindPath(type, 'type')}/$id';

  /// [name] without the white space around it; an [ArgumentError] when that
  /// is empty or longer than [maxNameLength].
  static String _checkedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'is empty');
    }
    if (trimmed.length > maxNameLength) {
      throw ArgumentError.value(
        name,
        'name',
        'is longer than the $maxNameLength characters the web client takes',
      );
    }
    return trimmed;
  }

  /// [icon] without the white space around it; an [ArgumentError] when that
  /// is empty.
  static String _checkedIcon(String icon, {String argument = 'icon'}) {
    final trimmed = icon.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(icon, argument, 'is empty');
    return trimmed;
  }

  /// Throws an [ArgumentError] (for [argument]) unless [visibility] is one
  /// the web client offers.
  static void _checkVisibility(
    LessonContentVisibility visibility,
    String argument,
  ) {
    final days = visibility.daysAfterEnd;
    final offered = switch (visibility.option) {
      LessonContentVisibilityOption.other => false,
      LessonContentVisibilityOption.daysAfterEnd =>
        days != null &&
            days >= 1 &&
            days <= LessonContentVisibility.maxDaysAfterEnd,
      _ => days == null,
    };
    if (offered) return;
    throw ArgumentError.value(
      visibility,
      argument,
      'is not a visibility the web client offers: always, never, at-start, '
      'at-end, or days-after-end with 1 to '
      '${LessonContentVisibility.maxDaysAfterEnd} days',
    );
  }

  /// [weblink] as a write sends it, after the checks (for [argument]).
  static _Weblink _checkedWeblink(
    NewLessonContentWeblink weblink, {
    String argument = 'weblinks',
  }) {
    final name = weblink.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(weblink, argument, 'has an empty name');
    }
    final url = normalizeWeblinkUrl(weblink.url);
    if (url == null) {
      throw ArgumentError.value(
        weblink.url,
        argument,
        'is not a web address the web client takes (such as '
        'https://example.com/page)',
      );
    }
    _checkVisibility(weblink.visibility, argument);
    return (
      name: name,
      url: url,
      icon: _checkedIcon(weblink.icon, argument: argument),
      visibility: weblink.visibility,
    );
  }

  /// The files of [attachments] as a write uploads them, after the checks:
  /// each file must exist, have a name Smartschool allows, a name no other
  /// file of [attachments] has, and a visibility the web client offers.
  static List<_File> _checkedFiles(
    List<NewLessonContentAttachment> attachments,
  ) {
    const argument = 'attachments';
    final names = <String>{};
    final files = <_File>[];
    for (final attachment in attachments) {
      final file = File(attachment.path);
      if (!file.existsSync()) {
        throw ArgumentError.value(attachment.path, argument, 'names no file');
      }
      final name = file.uri.pathSegments.last;
      if (name.trim().isEmpty || !SmartschoolUploader.isAllowedName(name)) {
        throw ArgumentError.value(
          attachment.path,
          argument,
          'names a file whose name Smartschool does not allow: no / : * ? " '
          '\\ < > |, and no dot at its start or end',
        );
      }
      if (!names.add(name)) {
        throw ArgumentError.value(
          attachment.path,
          argument,
          'names a second file called "$name": the visibility of an '
          'attachment goes by its name, so add files with the same name '
          'in separate calls',
        );
      }
      _checkVisibility(attachment.visibility, argument);
      files.add((
        path: attachment.path,
        fileName: name,
        visibility: attachment.visibility,
      ));
    }
    return files;
  }

  /// Whether [a] and [b] hold the same IDs, in any order and case.
  static bool _sameIds(Iterable<String> a, Iterable<String> b) {
    final left = {for (final id in a) id.toLowerCase()};
    final right = {for (final id in b) id.toLowerCase()};
    return left.length == right.length && left.containsAll(right);
  }

  /// [ids] for a message.
  static String _ids(Iterable<String> ids) =>
      ids.isEmpty ? 'none' : '[${ids.join(', ')}]';

  /// The kind of lesfiche [type] in a message.
  static String _noun(LessonContentType type) => switch (type) {
    LessonContentType.lesson => 'lesson lesfiche',
    LessonContentType.assignment => 'assignment lesfiche',
    LessonContentType.other => 'lesfiche',
  };

  /// [item] in a message.
  static String _what(LessonContentItem item) =>
      '${_noun(item.type)} ${item.id}';

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
