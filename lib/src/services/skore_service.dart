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
/// (group) > (class).
///
/// It also reads the gradebooks of a teacher with the teachers they are
/// shared with ([getGradebookShares]), and shares a gradebook with another
/// teacher or stops sharing it ([shareGradebook], [unshareGradebook]), as
/// Skore's "share gradebooks" manager does (Puntenboeken > the share button
/// next to a teacher).
///
/// The reads change nothing; only [addTeacher], [replaceTeacher],
/// [shareGradebook] and [unshareGradebook] write to Skore. They never delete
/// an assignment or a gradebook.
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
/// Modellen) and to its gradebooks management (Puntenboeken), as a Skore
/// administrator has ([SkoreAccessArea]). [checkAccess] tells which of the
/// two the account has.
///
/// Skore answers every request of these parts to a teacher without the
/// rights by sending it on to Smartschool's start page (a redirect to
/// `/?module=Homepage`; seen live, #91), never with an empty list; a call
/// then throws a [SmartschoolSkoreAccessDeniedError] that names the part of
/// Skore. An answer with HTTP 403 is one too. What Skore answers a pupil,
/// and an account with only one of the two rights, was not captured.
///
/// ### Errors
/// - [SmartschoolSkoreAccessDeniedError] (a [SmartschoolSkoreError]): Skore
///   refused the request to the account, which lacks the rights for that
///   part of Skore (its `area`; see above for when it is thrown). Its message
///   quotes nothing of the answer. From a write, nothing was saved.
/// - [SmartschoolSkoreChangeRefusedError] (a [SmartschoolSkoreError]): a
///   write's check before the save refused the change. Nothing was saved.
///   Its message says why, so the call can be corrected.
/// - [SmartschoolSkoreMyGroupsError] (a
///   [SmartschoolSkoreChangeRefusedError]): [replaceTeacher] found that the
///   current teacher works with "Mijn lesgroepen" for the course. Nothing was
///   saved.
/// - [SmartschoolSkoreError] itself (none of the types above): Skore answered
///   with something the service cannot use (another HTTP status than `200`,
///   an HTML page instead of data, invalid JSON, a missing RPC `result`, or
///   data in an unknown shape). The session was accepted: signing in again
///   does not help. Its message may quote the answer, which can hold names.
///   From a write, nothing was saved.
/// - [SmartschoolSkoreSaveUnconfirmedError]: a write sent the save, but
///   Skore's answer (or, for [shareGradebook] and [unshareGradebook], reading
///   the gradebooks again) does not confirm it. It may or may not have been
///   saved: read again.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried the request
///   once; or Skore answered an RPC without a session. Sign in again and
///   retry. The save of [addTeacher] and [replaceTeacher] is never retried:
///   when the session is refused for it, it fails at once.
/// - Another [SmartschoolAuthenticationError]: logging in again for the
///   request failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached. From a
///   write, only before the save went out: a save that failed on the way is
///   a [SmartschoolSkoreSaveUnconfirmedError].
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

  /// The RPC service behind the "share gradebooks" manager. It also holds
  /// methods that delete or lock (`deleteTeacher`, `cleanUpSkore`,
  /// `hideWorkyear`, `unlockReport`, ...): only [_gradebooksRpcMethods] are
  /// ever called on it.
  static const _gradebooksRpcPath =
      '/modules/Skore/modules/rapportbeheer/rpc/data.php';

  /// The only methods of [_gradebooksRpcPath] the service calls.
  static const _gradebooksRpcMethods = {'getCourses', 'saveShared'};

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
    return parseClasses(
      _decodeJson(
        _body(response, what, SkoreAccessArea.reportManagement),
        what,
      ),
    );
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
      _body(
        response,
        'the assignments page of class $classId',
        SkoreAccessArea.reportManagement,
      ),
    );
  }

  /// Returns the teachers that Skore lets assign to a course, in Skore's
  /// order (by name).
  Future<List<SkoreTeacher>> getTeachers() async {
    return parseTeachers(await _ownersRpc('getTeachers', const []));
  }

  /// Returns the gradebooks of teacher [ownerId] (a Smartschool user ID), in
  /// Skore's order, each with the teachers it is shared with.
  ///
  /// Skore answers a teacher without gradebooks and a user ID it does not
  /// know the same way, so both give an empty list.
  Future<List<SkoreGradebookShares>> getGradebookShares(int ownerId) async {
    return parseGradebookShares(
      await _gradebooksRpc('getCourses', [ownerId]),
      ownerId: ownerId,
    );
  }

  /// Returns the parts of Skore the account can use: each [SkoreAccessArea]
  /// whose read Skore answers with data rather than refuses (#91). For a
  /// status check, before calling the rest.
  ///
  /// It reads one small thing per part, and changes nothing:
  /// - [SkoreAccessArea.reportManagement]: the teachers ([getTeachers]);
  /// - [SkoreAccessArea.gradebookManagement]: the account's own gradebooks
  ///   ([getGradebookShares] with its own user ID, from
  ///   [SmartschoolClient.getCurrentUser]).
  ///
  /// A part is left out when Skore refuses its read with a
  /// [SmartschoolSkoreAccessDeniedError]. Any other failure of a read is
  /// thrown, as the read throws it: an answer the service cannot use (a plain
  /// [SmartschoolSkoreError]) is not taken for missing rights.
  ///
  /// Seen live: a teacher without Skore's management rights gets an empty
  /// set (both reads refused, #91); a Skore administrator gets both parts.
  /// An account with only one of the two rights was not captured, and which
  /// right Skore checks for each request was not seen: a call of a part in
  /// the set may still be refused, with a
  /// [SmartschoolSkoreAccessDeniedError].
  Future<Set<SkoreAccessArea>> checkAccess() async {
    final areas = <SkoreAccessArea>{};
    try {
      await getTeachers();
      areas.add(SkoreAccessArea.reportManagement);
    } on SmartschoolSkoreAccessDeniedError {
      // Left out.
    }
    final own = await _client.getCurrentUser();
    try {
      await getGradebookShares(own.id);
      areas.add(SkoreAccessArea.gradebookManagement);
    } on SmartschoolSkoreAccessDeniedError {
      // Left out.
    }
    return areas;
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Assigns teacher [teacherId] to course [courseId] of class [classId]: a
  /// new assignment, as the green **+** on the class's assignments page adds.
  /// Returns the new assignment, with the course as read before the save
  /// ([SkoreSavedAssignment.course]: its label, and its teachers before the
  /// change); its [SkoreSavedAssignment.replaced] is `null`.
  ///
  /// A new assignment holds all pupils of the class.
  ///
  /// Before it saves, it reads the class ([getCourses]) and the teachers
  /// ([getTeachers]), and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
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
  Future<SkoreSavedAssignment> addTeacher({
    required int classId,
    required int courseId,
    required int teacherId,
  }) async {
    const operation = 'addTeacher';
    final course = await _courseToAssign(operation, classId, courseId);
    _refuseAssignedTeacher(operation, course, teacherId);
    final teacher = await _knownTeacher(operation, teacherId);
    return _saveOwner(
      operation,
      course: course,
      replaced: null,
      teacher: teacher,
    );
  }

  /// Gives assignment [assignmentId] of course [courseId] of class [classId]
  /// another teacher, [teacherId], as choosing another name in the teacher
  /// drop-down of the class's assignments page does. Returns the assignment,
  /// which keeps its ID: the assignment, and its gradebook, stay; only the
  /// teacher changes.
  ///
  /// The result also holds what was read before the save: the course
  /// ([SkoreSavedAssignment.course]: its label, and its teachers before the
  /// change) and the assignment as it was ([SkoreSavedAssignment.replaced]:
  /// the teacher it had).
  ///
  /// Before it saves, it reads the class ([getCourses]) and the teachers
  /// ([getTeachers]), and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
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
  /// saving nothing; the error names the current teacher (its `teacherId`
  /// and `teacherName`). The web client offers to delete those groups; this
  /// never deletes them. An answer it does not recognise is refused with a
  /// plain [SmartschoolSkoreError] (an answer it cannot use, not a refused
  /// change), also saving nothing.
  ///
  /// The save (Skore's `saveOwner` with the assignment's `ownerID`) is sent
  /// once and never retried, not even after logging in again. When Skore's
  /// answer does not confirm it (it names the same assignment and the teacher
  /// asked for), this throws a [SmartschoolSkoreSaveUnconfirmedError]: read
  /// the class again before trying again.
  ///
  /// The checks and the save are separate requests: do not change the same
  /// course from two places at once.
  Future<SkoreSavedAssignment> replaceTeacher({
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
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: assignment $assignmentId is not one of course $courseId '
        'of class $classId. Nothing was saved.',
      );
    }
    _refuseAssignedTeacher(operation, course, teacherId);
    final teacher = await _knownTeacher(operation, teacherId);
    await _refuseMyGroups(operation, course: course, current: assignment);
    return _saveOwner(
      operation,
      course: course,
      replaced: assignment,
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
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: course $courseId is not in class $classId (Skore lists '
        '${courses.length} courses for it). Nothing was saved.',
      );
    }
    if (course.isGroupHeader) {
      throw SmartschoolSkoreChangeRefusedError(
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
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: teacher $teacherId (${assigned.teacherName}) already has '
        'assignment ${assigned.id} on course ${course.id} of class '
        '${course.classId} ("${course.label}"). Nothing was saved.',
      );
    }
  }

  /// Returns teacher [teacherId] from [getTeachers]; refuses one that is not
  /// in it.
  Future<SkoreTeacher> _knownTeacher(String operation, int teacherId) async {
    final teacher = (await getTeachers())
        .where((t) => t.id == teacherId)
        .firstOrNull;
    if (teacher == null) {
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: teacher $teacherId is not one of Skore\'s teachers (not '
        'in getTeachers). Nothing was saved.',
      );
    }
    return teacher;
  }

  /// Asks Skore (`getMyGroups`) whether the teacher of [current], an
  /// assignment of [course], works with "Mijn lesgroepen" for the course, and
  /// refuses when they do, or when the answer is not one it recognises.
  ///
  /// Skore answers `{"mygroups": null}` when the teacher has none. The answer
  /// when they have some has not been seen; Skore's web client takes a
  /// non-empty `mygroups` for groups (`r.mygroups && r.mygroups.length`), so
  /// a non-empty list or object counts as groups. Anything else but `null`
  /// or an empty list is refused as unknown.
  Future<void> _refuseMyGroups(
    String operation, {
    required SkoreCourse course,
    required SkoreAssignment current,
  }) async {
    final classId = course.classId;
    final courseId = course.id;
    final teacherId = current.teacherId;
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
        '$operation: the current teacher, $teacherId '
        '(${current.teacherName}), works with "Mijn lesgroepen" for course '
        '$courseId of class $classId ("${course.label}"). Handle those '
        'groups in Skore first; this does not delete them. Nothing was saved.',
        classId: classId,
        courseId: courseId,
        teacherId: teacherId,
        teacherName: current.teacherName,
      );
    }
    throw SmartschoolSkoreError(
      '$operation: Skore answered getMyGroups with ${_jsonPreview(result)}, '
      'which does not say whether the current teacher ($teacherId) works '
      'with "Mijn lesgroepen" for the course. Nothing was saved.',
    );
  }

  /// Saves an assignment of [course] with [teacher]: Skore's
  /// `saveOwner(classID, courseID, ownerID, userID)`, with the `ownerID` of
  /// [replaced], or an empty one for a new assignment ([replaced] `null`).
  /// Sent once, never retried (not even after logging in again); returns the
  /// assignment, with [course] and [replaced] as read before the save, once
  /// Skore's answer confirms it.
  ///
  /// Skore answers `{"ownerID": 34826, "userID": 146}`: the assignment
  /// (new, or the same for a replace) and its teacher.
  Future<SkoreSavedAssignment> _saveOwner(
    String operation, {
    required SkoreCourse course,
    required SkoreAssignment? replaced,
    required SkoreTeacher teacher,
  }) async {
    final classId = course.classId;
    final courseId = course.id;
    final assignmentId = replaced?.id;
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
    return SkoreSavedAssignment(
      id: ownerId!,
      teacherId: userId!,
      teacherName: teacher.name,
      course: course,
      replaced: replaced,
    );
  }

  // ---------------------------------------------------------------------------
  // Gradebook shares
  // ---------------------------------------------------------------------------

  /// Shares gradebook [gradebookId] of teacher [ownerId] with teacher
  /// [teacherId], with [access]: read, or read and write. Returns the
  /// gradebook as Skore holds it after the save, with what the call read
  /// before it and whether it saved anything (#103):
  /// [SkoreGradebookShareChange.before] (the gradebook as read before the
  /// change, so [SkoreGradebookShareChange.accessBefore] is the access
  /// [teacherId] had) and [SkoreGradebookShareChange.saved].
  ///
  /// The teachers the gradebook is already shared with keep their access. A
  /// teacher has one kind of access: sharing with write access takes
  /// [teacherId] off the readers, and sharing with read access takes them
  /// off the writers.
  ///
  /// Before it saves, it reads the owner's gradebooks
  /// ([getGradebookShares]) and the teachers ([getTeachers]), and refuses
  /// with a [SmartschoolSkoreChangeRefusedError], saving nothing:
  /// - the owner as [teacherId] (before any request);
  /// - a gradebook that is not one of the owner's (also for a user ID Skore
  ///   does not know), so a gradebook is never saved under another owner;
  /// - a teacher who is not in [getTeachers].
  ///
  /// When the gradebook is already shared with [teacherId] with [access], it
  /// saves nothing and returns the gradebook as read (without reading the
  /// teachers), with [SkoreGradebookShareChange.saved] `false`.
  ///
  /// The save (Skore's `saveShared`) holds this gradebook only, with its
  /// complete new readers and writers; Skore leaves the owner's other
  /// gradebooks as they are. Since it holds the complete lists, sending it
  /// again does not change the outcome: it is retried once after logging in
  /// again, as a read is. Skore must answer it with `state` 1, and reading the
  /// owner's gradebooks again must show exactly the readers and writers
  /// saved; otherwise this throws a [SmartschoolSkoreSaveUnconfirmedError]:
  /// read the gradebooks again before trying again.
  ///
  /// The checks and the save are separate requests: do not change the shares
  /// of the same gradebook from two places at once.
  Future<SkoreGradebookShareChange> shareGradebook({
    required int ownerId,
    required int gradebookId,
    required int teacherId,
    required SkoreShareAccess access,
  }) async {
    const operation = 'shareGradebook';
    _refuseOwnerAsTeacher(operation, ownerId, teacherId);
    final gradebook = await _gradebookToShare(operation, ownerId, gradebookId);
    final readers = [
      ...gradebook.readerIds.where((id) => id != teacherId),
      if (access == SkoreShareAccess.read) teacherId,
    ];
    final writers = [
      ...gradebook.writerIds.where((id) => id != teacherId),
      if (access == SkoreShareAccess.write) teacherId,
    ];
    if (_sameIds(readers, gradebook.readerIds) &&
        _sameIds(writers, gradebook.writerIds)) {
      return _shareChange(gradebook, gradebook, teacherId, saved: false);
    }
    await _knownTeacher(operation, teacherId);
    return _saveShared(
      operation,
      gradebook: gradebook,
      teacherId: teacherId,
      readers: readers,
      writers: writers,
      change: 'sharing it with teacher $teacherId (${access.name})',
    );
  }

  /// Stops sharing gradebook [gradebookId] of teacher [ownerId] with teacher
  /// [teacherId]: takes them off its readers and its writers. Returns the
  /// gradebook as Skore holds it after the save, with what the call read
  /// before it and whether it saved anything (#103):
  /// [SkoreGradebookShareChange.before] (so
  /// [SkoreGradebookShareChange.accessBefore] is the access [teacherId] had)
  /// and [SkoreGradebookShareChange.saved].
  ///
  /// The other teachers the gradebook is shared with keep their access.
  ///
  /// Before it saves, it reads the owner's gradebooks
  /// ([getGradebookShares]), and refuses with a
  /// [SmartschoolSkoreChangeRefusedError], saving nothing:
  /// - the owner as [teacherId] (before any request);
  /// - a gradebook that is not one of the owner's (also for a user ID Skore
  ///   does not know).
  ///
  /// [teacherId] need not be in [getTeachers]: a teacher who has left the
  /// school can still be taken off. When the gradebook is not shared with
  /// them, it saves nothing and returns the gradebook as read, with
  /// [SkoreGradebookShareChange.saved] `false`.
  ///
  /// The save and its checks afterwards are those of [shareGradebook].
  Future<SkoreGradebookShareChange> unshareGradebook({
    required int ownerId,
    required int gradebookId,
    required int teacherId,
  }) async {
    const operation = 'unshareGradebook';
    _refuseOwnerAsTeacher(operation, ownerId, teacherId);
    final gradebook = await _gradebookToShare(operation, ownerId, gradebookId);
    if (gradebook.accessOf(teacherId) == null) {
      return _shareChange(gradebook, gradebook, teacherId, saved: false);
    }
    return _saveShared(
      operation,
      gradebook: gradebook,
      teacherId: teacherId,
      readers: [...gradebook.readerIds.where((id) => id != teacherId)],
      writers: [...gradebook.writerIds.where((id) => id != teacherId)],
      change: 'no longer sharing it with teacher $teacherId',
    );
  }

  /// Refuses [teacherId] when it is the owner of the gradebook: Skore's
  /// manager never offers the owner as a reader or a writer.
  static void _refuseOwnerAsTeacher(
    String operation,
    int ownerId,
    int teacherId,
  ) {
    if (teacherId == ownerId) {
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: teacher $teacherId is the owner of the gradebook, who '
        'cannot be a reader or a writer of it. Nothing was saved.',
      );
    }
  }

  /// Reads the gradebooks of teacher [ownerId] again and returns gradebook
  /// [gradebookId]; refuses one that is not among them.
  Future<SkoreGradebookShares> _gradebookToShare(
    String operation,
    int ownerId,
    int gradebookId,
  ) async {
    final gradebooks = await getGradebookShares(ownerId);
    final gradebook = gradebooks
        .where((g) => g.gradebookId == gradebookId)
        .firstOrNull;
    if (gradebook == null) {
      throw SmartschoolSkoreChangeRefusedError(
        '$operation: gradebook $gradebookId is not one of teacher $ownerId '
        '(Skore lists ${gradebooks.length} gradebooks for them). Nothing was '
        'saved.',
      );
    }
    return gradebook;
  }

  /// Saves the [readers] and [writers] of [gradebook], the change of the
  /// access of [teacherId]: Skore's `saveShared(userID, readers, writers)`,
  /// with only this gradebook in the two maps. Returns the gradebook as read
  /// again, with [gradebook] as it was before, once Skore's answer (`state`
  /// 1) and that read confirm it.
  ///
  /// Skore answers `{"state": 1}`.
  Future<SkoreGradebookShareChange> _saveShared(
    String operation, {
    required SkoreGradebookShares gradebook,
    required int teacherId,
    required List<int> readers,
    required List<int> writers,
    required String change,
  }) async {
    final ownerId = gradebook.ownerId;
    final gradebookId = gradebook.gradebookId;
    final what =
        'the save (gradebook $gradebookId of teacher $ownerId: $change; '
        'readers $readers, writers $writers)';
    const unconfirmed =
        'It may or may not have been saved: read the gradebooks again '
        '(getGradebookShares) before trying again.';

    final dynamic result;
    try {
      result = await _gradebooksRpc('saveShared', [
        ownerId,
        {'$gradebookId': readers},
        {'$gradebookId': writers},
      ]);
    } on SmartschoolSessionExpiredError {
      // Refused before Skore handled it, also after logging in again (or
      // answered without a session).
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolSkoreSaveUnconfirmedError(
          '$operation: $what was sent, but no usable answer came in ($e). '
          '$unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
    final state = result is Map ? _tryId(result['state']) : null;
    if (state != 1) {
      throw SmartschoolSkoreSaveUnconfirmedError(
        '$operation: $what was sent, but Skore\'s answer '
        '${_jsonPreview(result)} does not confirm it (state 1). $unconfirmed',
      );
    }

    final SkoreGradebookShares? after;
    try {
      after = (await getGradebookShares(
        ownerId,
      )).where((g) => g.gradebookId == gradebookId).firstOrNull;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolSkoreSaveUnconfirmedError(
          '$operation: Skore confirmed $what, but reading the gradebooks '
          'again to check it failed ($e). $unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
    final String? problem;
    if (after == null) {
      problem = 'no longer lists the gradebook for teacher $ownerId';
    } else if (!_sameIds(after.readerIds, readers) ||
        !_sameIds(after.writerIds, writers)) {
      problem =
          'shows readers ${after.readerIds} and writers ${after.writerIds}';
    } else {
      problem = null;
    }
    if (problem != null) {
      throw SmartschoolSkoreSaveUnconfirmedError(
        '$operation: Skore confirmed $what, but reading the gradebooks again '
        '$problem. $unconfirmed',
      );
    }
    return _shareChange(gradebook, after!, teacherId, saved: true);
  }

  /// [after], the gradebook after a change of the access of [teacherId], with
  /// [before], the gradebook as read before it, and whether it was [saved].
  static SkoreGradebookShareChange _shareChange(
    SkoreGradebookShares before,
    SkoreGradebookShares after,
    int teacherId, {
    required bool saved,
  }) => SkoreGradebookShareChange(
    gradebookId: after.gradebookId,
    ownerId: after.ownerId,
    className: after.className,
    courseName: after.courseName,
    icon: after.icon,
    readerIds: after.readerIds,
    writerIds: after.writerIds,
    teacherId: teacherId,
    before: before,
    saved: saved,
  );

  /// Whether [a] and [b] hold the same IDs, in any order.
  static bool _sameIds(Iterable<int> a, Iterable<int> b) {
    final setA = a.toSet();
    final setB = b.toSet();
    return setA.length == setB.length && setA.containsAll(setB);
  }

  // ---------------------------------------------------------------------------
  // RPC
  // ---------------------------------------------------------------------------

  /// Calls [method] of Skore's assignments RPC service (`owners.php`) with
  /// [params] (the web client sends IDs as strings to it); see [_rpc].
  Future<dynamic> _ownersRpc(
    String method,
    List<Object?> params, {
    bool retryAfterLogin = true,
  }) => _rpc(
    _ownersRpcPath,
    SkoreAccessArea.reportManagement,
    method,
    params,
    retryAfterLogin: retryAfterLogin,
  );

  /// Calls [method] of Skore's gradebooks RPC service
  /// (`rapportbeheer/rpc/data.php`) with [params] (the "share gradebooks"
  /// manager sends IDs as numbers to it); see [_rpc].
  ///
  /// Only the methods in [_gradebooksRpcMethods]: any other is refused before
  /// anything is sent, since that service also deletes and locks.
  Future<dynamic> _gradebooksRpc(String method, List<Object?> params) {
    if (!_gradebooksRpcMethods.contains(method)) {
      throw ArgumentError.value(
        method,
        'method',
        'not one the service calls on $_gradebooksRpcPath',
      );
    }
    return _rpc(
      _gradebooksRpcPath,
      SkoreAccessArea.gradebookManagement,
      method,
      params,
    );
  }

  /// Calls [method] of the Skore RPC service at [path] (in [area] of Skore)
  /// with [params], and returns the `result` of its answer.
  ///
  /// Sends the form Skore's web client sends: `rpc_sessionobj`,
  /// `rpc_requestType` (`requestData`), `rpc_method` and `rpc_params` (the
  /// arguments as a JSON array).
  ///
  /// Pass `retryAfterLogin: false` for a call that must not be sent twice:
  /// when Smartschool refuses the session for it, it then fails at once with
  /// a [SmartschoolSessionExpiredError], instead of being sent again after
  /// logging in (see [SmartschoolClient.postFormResponse]).
  Future<dynamic> _rpc(
    String path,
    SkoreAccessArea area,
    String method,
    List<Object?> params, {
    bool retryAfterLogin = true,
  }) async {
    final response = await _client.postFormResponse(
      path,
      _rpcFields(method, params, DateTime.now()),
      retryAfterLogin: retryAfterLogin,
    );
    return _rpcResult(_body(response, 'the RPC call $method', area), method);
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

  /// Parses the `result` of the gradebooks service's `getCourses(userID)`
  /// for teacher [ownerId]: a list of
  /// `{"id": "34826", "icon": "IconLib:laptop", "name": "Digitale
  /// vaardigheden", "class": "5WW1", "readers": [], "writers": [320]}`, the
  /// gradebook ID as a string and the teacher IDs as numbers (numeric
  /// strings are taken too).
  ///
  /// An entry without its `readers` or `writers` list is refused rather than
  /// read as empty: a save built on it would take those teachers off.
  static List<SkoreGradebookShares> parseGradebookShares(
    dynamic result, {
    required int ownerId,
  }) {
    if (result is! List) {
      throw SmartschoolSkoreError(
        'Skore gave the gradebooks of teacher $ownerId as '
        '${result.runtimeType} instead of a list.',
      );
    }
    return [
      for (final entry in result)
        if (entry is Map)
          _gradebookShares(entry, ownerId)
        else
          throw SmartschoolSkoreError(
            'Skore gave a gradebook of teacher $ownerId as '
            '${entry.runtimeType} instead of an object.',
          ),
    ];
  }

  static SkoreGradebookShares _gradebookShares(
    Map<dynamic, dynamic> entry,
    int ownerId,
  ) {
    final gradebookId = _id(entry['id'], 'a gradebook');
    List<int> teachers(String key) {
      final ids = entry[key];
      if (ids is! List) {
        throw SmartschoolSkoreError(
          'Skore gave the $key of gradebook $gradebookId as '
          '${_jsonPreview(ids)} instead of a list.',
        );
      }
      return [
        for (final id in ids)
          _id(id, 'one of the $key of gradebook $gradebookId'),
      ];
    }

    return SkoreGradebookShares(
      gradebookId: gradebookId,
      ownerId: ownerId,
      className: '${entry['class'] ?? ''}'.trim(),
      courseName: '${entry['name'] ?? ''}'.trim(),
      icon: '${entry['icon'] ?? ''}'.trim(),
      readerIds: teachers('readers'),
      writerIds: teachers('writers'),
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// The body of [response], an answer to [what], a request in [area] of
  /// Skore; throws when Skore did not answer with `200`, or sent the request
  /// on to Smartschool's start page.
  ///
  /// A [SmartschoolSkoreAccessDeniedError]:
  /// - an answer that sends the request on to Smartschool's start page
  ///   ([_sentToStartPage]): Skore's answer to every request of a teacher
  ///   without the rights (seen live, #91);
  /// - an answer with `403` (Forbidden): HTTP's answer for a request the
  ///   server refuses to the account (#83; not seen from Skore).
  static String _body(
    Response<String> response,
    String what,
    SkoreAccessArea area,
  ) {
    final status = response.statusCode;
    if (status == 403) {
      throw SmartschoolSkoreAccessDeniedError(
        'Skore refused $what to the account (HTTP 403): it lacks the rights '
        'for ${_areaName(area)}.',
        area: area,
      );
    }
    if (_sentToStartPage(response)) {
      throw SmartschoolSkoreAccessDeniedError(
        'Skore refused $what to the account (it sent the request on to '
        "Smartschool's start page): it lacks the rights for "
        '${_areaName(area)}.',
        area: area,
      );
    }
    if (status != 200) {
      throw SmartschoolSkoreError('Skore answered $what with HTTP $status.');
    }
    return response.data ?? '';
  }

  /// Whether [response] sends its request on to Smartschool's start page,
  /// `/?module=Homepage` on the same host: Skore's answer to a request of a
  /// teacher without the rights for that part of Skore (#91).
  ///
  /// Seen live (2026-10-04) for every request of the service: a `302` with
  /// `Location: /?module=Homepage` (an empty `text/html` body). The client
  /// follows the redirect of a GET, which then ends on the start page with
  /// `200` (its [Response.redirects] and [Response.realUri] say so); it does
  /// not follow that of a POST, which comes as the `302` itself.
  ///
  /// A redirect elsewhere is not one: the client handles one to its login
  /// pages, and another is an answer the service cannot use.
  static bool _sentToStartPage(Response<String> response) {
    final request = response.requestOptions.uri;
    final status = response.statusCode ?? 0;
    final location = Uri.tryParse(
      response.headers.value('location')?.trim() ?? '',
    );
    final Uri target;
    if (status >= 300 && status < 400 && location != null) {
      target = request.resolveUri(location);
    } else if (response.redirects.isNotEmpty) {
      target = request.resolveUri(response.realUri);
    } else {
      return false;
    }
    return target.host == request.host &&
        (target.path == '/' || target.path.isEmpty) &&
        target.queryParameters['module'] == 'Homepage';
  }

  /// [area] as Skore's menus name it, for a message.
  static String _areaName(SkoreAccessArea area) => switch (area) {
    SkoreAccessArea.reportManagement =>
      "Skore's report management (Rapporten > Modellen)",
    SkoreAccessArea.gradebookManagement =>
      "Skore's gradebook management (Puntenboeken)",
  };

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
