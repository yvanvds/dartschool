import 'dart:convert';

import '../exceptions.dart';
import '../models/lvs_models.dart';
import '../models/lvs_plan_models.dart';
import '../models/lvs_results_models.dart';
import '../session.dart';
import 'lvs_note_answers.dart';
import 'lvs_plan_answers.dart';
import 'lvs_result_answers.dart';
import 'lvs_wire.dart';

export '../models/lvs_models.dart';
export '../models/lvs_plan_models.dart';
export '../models/lvs_results_models.dart';

/// Reads Smartschool's pupil tracking system (LVS, "leerlingvolgsysteem",
/// `/?module=LVS`) **as the logged-in teacher** (#160): finds a pupil by
/// name ([searchPupils]) and reads the overview of the pupil's file
/// ([getPupilFile]): who, which class, today's attendance, and which
/// sections of the file hold something; the pupil's notes, per category
/// ([getNotes]) or all of them ([getAllNotes], #161); and the pupil's
/// results ([getEvaluations], [getAllEvaluations], [getFeedback],
/// [getReports], #162); and the pupil's support plan ([getSupportPlan],
/// [getSupportPlanPeriods], [getProfileSketch], #163). [checkAccess] tells
/// whether the account may use the LVS.
///
/// ```dart
/// final lvs = LvsService(client);
///
/// final found = await lvs.searchPupils('janssens'); // several can match
/// final pupil = found.first;
/// final file = await lvs.getPupilFile(
///   pupilId: pupil.pupilId,
///   classId: pupil.classId,
/// );
/// for (final category in file.noteCategories.where((c) => c.hasNotes)) {
///   final notes = await lvs.getNotes(
///     pupilId: pupil.pupilId,
///     classId: pupil.classId,
///     categoryId: category.id,
///   );
///   print('${notes.length} notes'); // the notes are about the pupil
/// }
/// ```
///
/// **Only reads, by an allowlist.** The LVS has writes right next to its
/// reads, some on the same URL (`PUT /LVS/Message`, `PUT /LVS/Watch`,
/// `setLastPupil`, which the web client sends for every pupil it shows, the
/// "viewed" flags, the edit locks). The service sends only its reads, each
/// on an explicit list (method, path, query and form fields), and refuses
/// any other request before it is sent
/// ([SmartschoolLvsRequestNotAllowedError]). It never sends what the web
/// client sends "on the side" either: reading a pupil's file here does not
/// make it the last pupil the account viewed, and marks nothing as seen.
///
/// The requests (read from the LVS's own JavaScript, and tried live without
/// a pupil, 2026-10-21):
/// - [searchPupils]: `GET /LVS/Spotlight?searchVal=<text>`, answered with
///   `{search, classes, pupils, teachers, groups, groupUsers}` (lists);
/// - [getPupilFile]: `GET /LVS/Spotlight/<pupil id>?classID=<class id>`,
///   answered with `{categories, pupil}`, then
///   `POST /LVS/Pupilxhr/getStatusInfo` with `pupilID`, answered with a list
///   of `{partOfDay, code: {name, code, color}}`;
/// - [checkAccess]: `POST /?module=LVS&file=treeBuilder` with `id` `0`, the
///   root of the LVS's left tree: the classes the account may see, no pupil;
/// - [getNotes]: the LVS's XML dispatcher, `POST /?module=LVS&file=dispatcher`
///   with the command `lvs_cats/getUserCatItems`, answered with the action
///   `renderPupilNotes` (#161);
/// - [getAllNotes]: the same dispatcher with `lvs_pupils/getUserData`,
///   answered with `renderPupilAllNotes` (#161);
/// - the results (#162): the GETs of the results app that the file's
///   "Resultaten" section shows, `/LVS/Results/getConfiguration`,
///   `getperiods`, `getcourses`, `getevaluationsofuser`, `getfeedback` and
///   `getreports`, each with `pupilId` and `groupId` (the class) and, but
///   the first, the school year (`startDate`, `endDate`), answered with
///   JSON;
/// - the support plans (#163): the LVS's JSON dispatchers,
///   `POST /?module=LVS&file=jqDispatcher_hp&function=getIHP` (the plan) and
///   `getProfielSchets` (the profile sketch), and
///   `jqDispatcher_settings&function=getLVSspecificTitles` (the periods),
///   form-encoded, answered with JSON as text.
///
/// They answer straight after a login: the LVS page (some 300 KB) does not
/// have to be loaded first (seen live).
///
/// ### Privacy
/// What this service returns is about pupils: see `doc/lvs-privacy.md`. Its
/// models print counts only (`toString()`), and its errors never carry a
/// name, a text or an ID of an answer in their message; a refused session
/// that names a search's URL has the search text left out.
///
/// ### Errors
/// - [SmartschoolLvsAccessDeniedError] (a [SmartschoolLvsError]): the LVS
///   refused the read to the account (HTTP `403`, or a redirect to
///   Smartschool's start page). What the LVS answers a teacher without LVS
///   rights and a pupil account was not captured. For the results, a `403`
///   is what the results app takes for "no access" (#162): with
///   [checkAccess] `true`, the account may use the LVS but not see the
///   pupil's results.
/// - [SmartschoolLvsPupilNotFoundError] (a [SmartschoolLvsError]):
///   [getPupilFile] or [getNotes] got the LVS's placeholder pupil: it knows
///   no pupil of that ID in that class that the account may see.
/// - [SmartschoolLvsCategoryNotFoundError] (a [SmartschoolLvsError]):
///   [getNotes] got no category: the LVS knows no category of notes of that
///   ID.
/// - [SmartschoolLvsRequestNotAllowedError] (a [SmartschoolLvsError]): the
///   service refused to send a request that is not one of its reads (a bug
///   of the library). Nothing was sent.
/// - [SmartschoolLvsError] itself: the LVS answered with something the
///   service cannot use (another HTTP status than `200`, an HTML page,
///   invalid JSON, an unknown shape). Never an empty result.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried once.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
/// - [ArgumentError]: a blank search text, an ID that is not positive, a
///   school year that ends before it starts, or a page number, page size or
///   cap that is not positive, before anything is sent.
class LvsService {
  final LvsWire _wire;

  LvsService(SmartschoolClient client) : _wire = LvsWire(client);

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Whether the account may use the LVS: `true` when the LVS answers the
  /// root of its left tree (the classes the account may see), `false` when
  /// it refuses it to the account ([SmartschoolLvsAccessDeniedError]). Reads
  /// no pupil; for a status check, before the other reads.
  ///
  /// Any other failure is thrown: an answer the service cannot read (a
  /// plain [SmartschoolLvsError]) is not taken for missing rights.
  Future<bool> checkAccess() async {
    const read = LvsWire.tree;
    try {
      final response = await _wire.post(
        '/',
        query: read.fixedQuery,
        form: const {'id': '0'},
      );
      _parseTreeRoot(LvsWire.json(response, read));
      return true;
    } on SmartschoolLvsAccessDeniedError {
      return false;
    }
  }

  /// The pupils whose name matches [text], each with their class, in the
  /// LVS's order. Empty when no pupil matches. The classes the search also
  /// finds are left out.
  ///
  /// Several pupils can match. [LvsPupilMatch.name] is plain text: the
  /// LVS's markup that highlights the match is left out.
  ///
  /// A blank [text] is an [ArgumentError], before anything is sent.
  Future<List<LvsPupilMatch>> searchPupils(String text) async {
    final search = text.trim();
    if (search.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be blank');
    }
    const read = LvsWire.pupilSearch;
    final response = await _wire.get(
      '/LVS/Spotlight',
      query: {'searchVal': search},
    );
    return _parseSearch(LvsWire.json(response, read));
  }

  /// The overview of the file of pupil [pupilId] in class [classId] (an
  /// [LvsPupilMatch] of [searchPupils] has both): who, which class, the
  /// sections of the file with whether each holds something, and the
  /// pupil's attendance today.
  ///
  /// Two reads: the file, then today's status. The LVS answers a pupil it
  /// does not know in that class with a placeholder pupil, which is a
  /// [SmartschoolLvsPupilNotFoundError] (today's status is then not read).
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<LvsPupilFile> getPupilFile({
    required int pupilId,
    required int classId,
  }) async {
    if (pupilId <= 0) {
      throw ArgumentError.value(pupilId, 'pupilId', 'must be positive');
    }
    if (classId <= 0) {
      throw ArgumentError.value(classId, 'classId', 'must be positive');
    }
    final fileRead = LvsWire.pupilFile;
    final fileResponse = await _wire.get(
      '/LVS/Spotlight/$pupilId',
      query: {'classID': '$classId'},
    );
    final file = _parseFile(
      LvsWire.json(fileResponse, fileRead),
      pupilId: pupilId,
      classId: classId,
    );

    const statusRead = LvsWire.todayStatus;
    final statusResponse = await _wire.post(
      '/LVS/Pupilxhr/getStatusInfo',
      form: {'pupilID': '$pupilId'},
    );
    final status = _parseStatus(LvsWire.json(statusResponse, statusRead));
    return LvsPupilFile(
      pupilId: file.pupilId,
      classId: file.classId,
      name: file.name,
      className: file.className,
      classDescription: file.classDescription,
      teachers: file.teachers,
      sections: file.sections,
      todayStatus: status,
    );
  }

  /// The notes of category [categoryId] of the file of pupil [pupilId] in
  /// class [classId], with those of its sub-categories, in the LVS's order
  /// (#161). Empty when the category holds no notes in [schoolYear].
  ///
  /// [LvsPupilFile.noteCategories] lists the categories (the school's own:
  /// "gedrag", "zorg", ...). [schoolYear] is the period of the notes: the
  /// current school year (1 September to 31 August, Belgian time) when not
  /// given. Confidential notes come with [LvsNote.isConfidential] `true`:
  /// the LVS decides which ones the account receives, the library does not
  /// leave them out.
  ///
  /// One request: the dispatcher's `lvs_cats/getUserCatItems` with `catID`,
  /// `userID`, `toolbarType` `main`, `syRange` (`{"from", "until"}`),
  /// `groupID` and `toolbarSide` `left`, as the web client opens a category
  /// (without its list layouts, `getCatListView`). The library sends nothing
  /// else: no "viewed" flag, no edit lock. Whether the LVS itself takes the
  /// notes as seen by the account on this read (their [LvsNote.isNew]) was
  /// not captured (#168).
  ///
  /// The LVS answers a pupil it does not know in that class with its
  /// placeholder pupil, a [SmartschoolLvsPupilNotFoundError], and a category
  /// it does not know without the category, a
  /// [SmartschoolLvsCategoryNotFoundError] (both seen live for made-up IDs),
  /// never an empty list. An ID that is not positive, or a [schoolYear] that
  /// ends before it starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsNote>> getNotes({
    required int pupilId,
    required int classId,
    required int categoryId,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    _checkId(categoryId, 'categoryId');
    final period = _period(schoolYear);
    const read = LvsWire.categoryNotes;
    final response = await _wire.dispatch(read, {
      'catID': '$categoryId',
      'userID': '$pupilId',
      'toolbarType': 'main',
      'syRange': period,
      'groupID': '$classId',
      'toolbarSide': 'left',
    });
    final content = LvsWire.dispatcherContent(
      response,
      read,
      answer: 'renderPupilNotes',
    );
    return LvsNoteAnswers.categoryNotes(
      content,
      pupilId: pupilId,
      classId: classId,
      categoryId: categoryId,
    );
  }

  /// All notes of the file of pupil [pupilId] in class [classId], of every
  /// category, in the order of the LVS's "all items" view of the file (its
  /// `dates`) (#161). Empty when the file holds no notes in [schoolYear].
  ///
  /// [schoolYear] is as for [getNotes]. One request: the dispatcher's
  /// `lvs_pupils/getUserData` with `userID`, `toolbarType` `main`, `groupID`,
  /// `syRange`, `viewAllFilter` `[]` and `filterData` `0`, as the web client
  /// opens the view, before it shows its filter buttons. Its
  /// answer holds the file's reports, absences, evaluations, messages and
  /// signals too: only the notes are read.
  ///
  /// The LVS answers a pupil it does not know with no data at all (seen live
  /// for a made-up ID): an empty list, as for a pupil without notes.
  /// [getPupilFile] tells the two apart. An ID that is not positive, or a
  /// [schoolYear] that ends before it starts, is an [ArgumentError], before
  /// anything is sent.
  Future<List<LvsNote>> getAllNotes({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    final period = _period(schoolYear);
    const read = LvsWire.allNotes;
    final response = await _wire.dispatch(read, {
      'userID': '$pupilId',
      'toolbarType': 'main',
      'groupID': '$classId',
      'syRange': period,
      'viewAllFilter': '[]',
      'filterData': '0',
    });
    final content = LvsWire.dispatcherContent(
      response,
      read,
      answer: 'renderPupilAllNotes',
    );
    return LvsNoteAnswers.allNotes(content, pupilId: pupilId);
  }

  // ---------------------------------------------------------------------------
  // Results (#162)
  // ---------------------------------------------------------------------------
  //
  // The "Resultaten" section of a pupil's file ([LvsSectionType.results]):
  // the results app pupils and parents see, embedded in the LVS for one
  // pupil, so that a teacher sees the pupil's results in every course, not
  // only in their own gradebooks. A school whose file shows the older
  // [LvsSectionType.skore] section instead is not covered.
  //
  // Each read is one GET; the LVS answered every one of them with HTTP 500
  // and Smartschool's error page for a made-up pupil ID in a made-up class
  // (seen live, 2026-10-21): a plain SmartschoolLvsError, never an empty
  // list. A real pupil's answers were not captured (#168).

  /// What the results app may show the account for pupil [pupilId] in class
  /// [classId] (#162): `GET /LVS/Results/getConfiguration?pupilId&groupId`,
  /// answered with `{capabilities: {canUserSeeAll, canUserSeeSchoolyear}}`.
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<LvsResultsConfiguration> getResultsConfiguration({
    required int pupilId,
    required int classId,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    const read = LvsWire.resultsConfiguration;
    final response = await _wire.get(
      read.path as String,
      query: {'pupilId': '$pupilId', 'groupId': '$classId'},
    );
    return LvsResultAnswers.configuration(LvsWire.json(response, read));
  }

  /// The periods of the results of pupil [pupilId] in class [classId] in
  /// [schoolYear] (the current school year when not given), in the LVS's
  /// order (#162): `GET /LVS/Results/getperiods`. Their IDs are what
  /// [getEvaluations] takes in `periodIds`.
  ///
  /// An ID that is not positive, or a school year that ends before it
  /// starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsResultsPeriod>> getResultsPeriods({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    const read = LvsWire.resultsPeriods;
    final json = await _readResults(read, pupilId, classId, schoolYear);
    return LvsResultAnswers.periods(json);
  }

  /// The courses of the results of pupil [pupilId] in class [classId] in
  /// [schoolYear] (the current school year when not given), in the LVS's
  /// order (#162): `GET /LVS/Results/getcourses`. Their IDs are what
  /// [getEvaluations] takes in `courseIds`.
  ///
  /// An ID that is not positive, or a school year that ends before it
  /// starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsResultsCourse>> getResultsCourses({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    const read = LvsWire.resultsCourses;
    final json = await _readResults(read, pupilId, classId, schoolYear);
    return LvsResultAnswers.courses(json);
  }

  /// Page [pageNumber] (from 1) of the evaluations of pupil [pupilId] in
  /// class [classId] in [schoolYear] (the current school year when not
  /// given), [itemsOnPage] per page, in the LVS's order (#162). Only those
  /// of the courses [courseIds] and the periods [periodIds] when given; all
  /// of them when empty, as the results app asks for them.
  ///
  /// One request: `GET /LVS/Results/getevaluationsofuser` with `pupilId`,
  /// `groupId`, `pageNumber`, `itemsOnPage`, `courseIds` and `periodIds`
  /// (sorted, comma-separated, left out when empty) and the school year
  /// (`startDate`, `endDate`). The answer is a list: [LvsEvaluationPage]
  /// tells whether a next page may hold more ([LvsEvaluationPage.mayHaveMore]);
  /// [getAllEvaluations] reads them all. The results app itself asks for one
  /// page of 9999; whether the LVS pages a real pupil's list was not
  /// captured (#168).
  ///
  /// An ID that is not positive, a [pageNumber] or [itemsOnPage] that is not
  /// positive, or a school year that ends before it starts, is an
  /// [ArgumentError], before anything is sent.
  Future<LvsEvaluationPage> getEvaluations({
    required int pupilId,
    required int classId,
    Iterable<int> courseIds = const [],
    Iterable<int> periodIds = const [],
    int pageNumber = 1,
    int itemsOnPage = 100,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    _checkCount(pageNumber, 'pageNumber');
    _checkCount(itemsOnPage, 'itemsOnPage');
    final courses = _idList(courseIds, 'courseIds');
    final periods = _idList(periodIds, 'periodIds');
    final period = _schoolYear(schoolYear);
    const read = LvsWire.evaluations;
    final response = await _wire.get(
      read.path as String,
      query: {
        'pupilId': '$pupilId',
        'groupId': '$classId',
        'pageNumber': '$pageNumber',
        'itemsOnPage': '$itemsOnPage',
        if (courses.isNotEmpty) 'courseIds': courses,
        if (periods.isNotEmpty) 'periodIds': periods,
        'startDate': period.firstDay,
        'endDate': period.lastDay,
      },
    );
    return LvsEvaluationPage(
      pageNumber: pageNumber,
      itemsOnPage: itemsOnPage,
      evaluations: LvsResultAnswers.evaluations(LvsWire.json(response, read)),
    );
  }

  /// The evaluations of pupil [pupilId] in class [classId], read page by
  /// page with [getEvaluations] ([itemsOnPage] per page, the filters as
  /// there) until a page is not full, or [maxPages] pages were read (#162).
  ///
  /// [LvsEvaluationList.isComplete] is `false` when the cap stopped the
  /// reading with a full page: there may be more. An evaluation that comes
  /// again on a later page (the list changed while it was read) is kept
  /// once. A page that holds only evaluations of the pages before it means
  /// that the LVS does not page the list: a [SmartschoolLvsError], not a
  /// list that looks complete. A page with more than [itemsOnPage]
  /// evaluations means it sent all of them at once: the list is complete.
  ///
  /// A [maxPages] that is not positive is an [ArgumentError], as are the
  /// arguments [getEvaluations] refuses, before anything is sent.
  Future<LvsEvaluationList> getAllEvaluations({
    required int pupilId,
    required int classId,
    Iterable<int> courseIds = const [],
    Iterable<int> periodIds = const [],
    int itemsOnPage = 100,
    int maxPages = 10,
    LvsSchoolYear? schoolYear,
  }) async {
    _checkCount(maxPages, 'maxPages');
    final courses = courseIds.toList();
    final periods = periodIds.toList();
    final year = schoolYear ?? LvsSchoolYear.current();
    final evaluations = <LvsEvaluation>[];
    final seen = <String>{};
    for (var number = 1; number <= maxPages; number++) {
      final page = await getEvaluations(
        pupilId: pupilId,
        classId: classId,
        courseIds: courses,
        periodIds: periods,
        pageNumber: number,
        itemsOnPage: itemsOnPage,
        schoolYear: year,
      );
      final fresh = [
        for (final evaluation in page.evaluations)
          if (seen.add(evaluation.identifier)) evaluation,
      ];
      if (number > 1 && page.evaluations.isNotEmpty && fresh.isEmpty) {
        throw SmartschoolLvsError(
          "The LVS answered page $number of the pupil's evaluations with the "
          'evaluations of the pages before it: it does not page the list, so '
          'the evaluations read are not all of them.',
          statusCode: 200,
        );
      }
      evaluations.addAll(fresh);
      if (!page.mayHaveMore) {
        return LvsEvaluationList(
          evaluations: evaluations,
          isComplete: true,
          pagesRead: number,
        );
      }
    }
    return LvsEvaluationList(
      evaluations: evaluations,
      isComplete: false,
      pagesRead: maxPages,
    );
  }

  /// The feedback on the results of pupil [pupilId] in class [classId] in
  /// [schoolYear] (the current school year when not given), in the LVS's
  /// order (#162): `GET /LVS/Results/getfeedback`. Remarks on reports (of
  /// the class council, or per course) and teachers' feedback on
  /// evaluations, with their attachments as metadata ([LvsFeedback.kind]).
  ///
  /// An ID that is not positive, or a school year that ends before it
  /// starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsFeedback>> getFeedback({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    const read = LvsWire.resultsFeedback;
    final json = await _readResults(read, pupilId, classId, schoolYear);
    return LvsResultAnswers.feedback(json);
  }

  /// The reports of pupil [pupilId] in class [classId] in [schoolYear] (the
  /// current school year when not given), in the LVS's order (#162):
  /// `GET /LVS/Results/getreports`. Metadata only: the library does not
  /// download a report ([LvsReport.downloadUrl] is kept).
  ///
  /// An ID that is not positive, or a school year that ends before it
  /// starts, is an [ArgumentError], before anything is sent.
  Future<List<LvsReport>> getReports({
    required int pupilId,
    required int classId,
    LvsSchoolYear? schoolYear,
  }) async {
    const read = LvsWire.reports;
    final json = await _readResults(read, pupilId, classId, schoolYear);
    return LvsResultAnswers.reports(json);
  }

  /// Sends [read], a GET of the results app with `pupilId`, `groupId` and
  /// the school year, and returns the JSON of its answer.
  Future<Object?> _readResults(
    LvsRead read,
    int pupilId,
    int classId,
    LvsSchoolYear? schoolYear,
  ) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    final period = _schoolYear(schoolYear);
    final response = await _wire.get(
      read.path as String,
      query: {
        'pupilId': '$pupilId',
        'groupId': '$classId',
        'startDate': period.firstDay,
        'endDate': period.lastDay,
      },
    );
    return LvsWire.json(response, read);
  }

  // ---------------------------------------------------------------------------
  // Support plans (#163)
  // ---------------------------------------------------------------------------
  //
  // The sections of type `handelingsplannen` of a pupil's file
  // ([LvsPupilFile.supportPlanSections]): the individual plan ("IHP") of the
  // pupil, per period of the school's structure of support plans, and the
  // profile sketch. Only the live plan is read (`exportID` 0): not an
  // archived export, nor the versions of an item. The evaluation of the plan
  // and its report are not read either (#170). Every read is one form POST of the
  // LVS's JSON dispatchers, as the web client opens a view; none of the calls
  // of its edit flow (`getIHPondersteuningsnood`, `getOD_doelstellingen`,
  // `/LVS/Handelingsplannen/checkSyntheseEditor`, ...) is on the allowlist.

  /// The left tree's colour that the web client sends with the period menu.
  static const _menuColor = '#418b09';

  /// The periods of the support plans of pupil [pupilId] in class [classId]
  /// (#163), in the LVS's order: what [getSupportPlan] and [getProfileSketch]
  /// take as `periodId`. Empty when the LVS gives no period menu, as for a
  /// class without a structure of support plans (seen live for a made-up
  /// class).
  ///
  /// One request: `POST /?module=LVS&file=jqDispatcher_settings&function=`
  /// `getLVSspecificTitles` with `groupID`, `pupilID`, `type` `hp_ihp`,
  /// `activeID` `0`, `color` and `archiveID` `0`, the menu the web client
  /// shows above the plan.
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<List<LvsPlanPeriod>> getSupportPlanPeriods({
    required int pupilId,
    required int classId,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    const read = LvsWire.supportPlanPeriods;
    final response = await _wire.post(
      '/',
      query: read.fixedQuery,
      form: {
        'groupID': '$classId',
        'pupilID': '$pupilId',
        'type': 'hp_ihp',
        'activeID': '0',
        'color': _menuColor,
        'archiveID': '0',
      },
    );
    return LvsPlanAnswers.periods(LvsWire.json(response, read));
  }

  /// The support plan of pupil [pupilId] in class [classId] in period
  /// [periodId] (one of [getSupportPlanPeriods]; the current period when not
  /// given) (#163): the individual plan ("IHP") with its items, each with the
  /// support needs, goals and approach of its last version.
  ///
  /// [LvsSupportPlan.status] tells the outcomes apart: a plan, no plan for
  /// the pupil in the period, or no period (the LVS answered a made-up class
  /// so, seen live: a class without a structure of support plans). A school
  /// that does not use support plans has no section of their type in the
  /// pupil's file ([LvsPupilFile.supportPlanSections]). The LVS's answer for
  /// a pupil it does not know in a class it knows was not captured (#168):
  /// [getPupilFile] tells it apart.
  ///
  /// One request: `POST /?module=LVS&file=jqDispatcher_hp&function=getIHP`
  /// with `groupID`, `pupilID`, `periodID` (`0` for the current one) and
  /// `exportID` `0` (the live plan, not an archived export). The item filters
  /// the web client saves for the account are not applied.
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<LvsSupportPlan> getSupportPlan({
    required int pupilId,
    required int classId,
    int? periodId,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    if (periodId != null) _checkId(periodId, 'periodId');
    const read = LvsWire.supportPlan;
    final response = await _wire.post(
      '/',
      query: read.fixedQuery,
      form: {
        'groupID': '$classId',
        'pupilID': '$pupilId',
        'periodID': '${periodId ?? 0}',
        'exportID': '0',
      },
    );
    return LvsPlanAnswers.plan(LvsWire.json(response, read));
  }

  /// The profile sketch ("profielschets") of pupil [pupilId] in class
  /// [classId] in period [periodId] (the current period when not given)
  /// (#163). [LvsProfileSketch.hasSketch] is `false` when there is none: the
  /// LVS's own message in its place is left out.
  ///
  /// One request: `POST /?module=LVS&file=jqDispatcher_hp&function=`
  /// `getProfielSchets` with `pupilID`, `classID`, `periodID` (`0` for the
  /// current one) and `exportID` `0`. The pupil's name, birth date and age
  /// in its answer are not read.
  ///
  /// An ID that is not positive is an [ArgumentError], before anything is
  /// sent.
  Future<LvsProfileSketch> getProfileSketch({
    required int pupilId,
    required int classId,
    int? periodId,
  }) async {
    _checkId(pupilId, 'pupilId');
    _checkId(classId, 'classId');
    if (periodId != null) _checkId(periodId, 'periodId');
    const read = LvsWire.profileSketch;
    final response = await _wire.post(
      '/',
      query: read.fixedQuery,
      form: {
        'pupilID': '$pupilId',
        'classID': '$classId',
        'periodID': '${periodId ?? 0}',
        'exportID': '0',
      },
    );
    return LvsPlanAnswers.profileSketch(LvsWire.json(response, read));
  }

  /// Throws an [ArgumentError] for a [count] (a page number, a page size, a
  /// cap) that is not positive.
  static void _checkCount(int count, String name) {
    if (count <= 0) throw ArgumentError.value(count, name, 'must be positive');
  }

  /// [ids] sorted, each once, comma-separated, as the results app sends
  /// them; `''` for none. Throws an [ArgumentError] for an ID that is not
  /// positive.
  static String _idList(Iterable<int> ids, String name) {
    final sorted = ids.toSet().toList()..sort();
    for (final id in sorted) {
      if (id <= 0) throw ArgumentError.value(id, name, 'must be positive');
    }
    return sorted.join(',');
  }

  /// Throws an [ArgumentError] for an [id] that is not positive.
  static void _checkId(int id, String name) {
    if (id <= 0) throw ArgumentError.value(id, name, 'must be positive');
  }

  /// The `syRange` of [schoolYear], the current school year when `null`:
  /// `{"from":"YYYY-MM-DD","until":"YYYY-MM-DD"}`, as the LVS page sends it.
  static String _period(LvsSchoolYear? schoolYear) {
    final period = _schoolYear(schoolYear);
    return jsonEncode({'from': period.firstDay, 'until': period.lastDay});
  }

  /// [schoolYear], the current school year when `null`. Throws an
  /// [ArgumentError] for one that ends before it starts.
  static LvsSchoolYear _schoolYear(LvsSchoolYear? schoolYear) {
    final period = schoolYear ?? LvsSchoolYear.current();
    if (period.isEmpty) {
      throw ArgumentError.value(
        period,
        'schoolYear',
        'must not end before it starts',
      );
    }
    return period;
  }

  // ---------------------------------------------------------------------------
  // Answers
  // ---------------------------------------------------------------------------

  /// Checks the root of the left tree: a list whose first node is the LVS's
  /// root (`attributes.rel` `lvs`) with a list of `children` (the classes).
  static void _parseTreeRoot(Object? json) {
    const read = LvsWire.tree;
    if (json is! List || json.isEmpty || json.first is! Map) {
      throw LvsWire.unknownShape(read, 'not a list of tree nodes');
    }
    final root = json.first as Map;
    final attributes = root['attributes'];
    if (attributes is! Map || attributes['rel'] != 'lvs') {
      throw LvsWire.unknownShape(read, 'no root node (attributes.rel "lvs")');
    }
    final children = root['children'];
    if (children != null && children is! List) {
      throw LvsWire.unknownShape(read, 'children is not a list');
    }
  }

  /// The pupils of a search answer: `{pupils: [{userID, classID, className,
  /// foundName, ...}], ...}`.
  static List<LvsPupilMatch> _parseSearch(Object? json) {
    const read = LvsWire.pupilSearch;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    final pupils = json['pupils'];
    if (pupils is! List) {
      throw LvsWire.unknownShape(read, 'no list of pupils');
    }
    return [
      for (final (i, pupil) in pupils.indexed) _parseMatch(pupil, 'pupils[$i]'),
    ];
  }

  static LvsPupilMatch _parseMatch(Object? pupil, String where) {
    const read = LvsWire.pupilSearch;
    if (pupil is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final pupilId = LvsWire.tryId(pupil['userID']);
    final classId = LvsWire.tryId(pupil['classID']);
    final foundName = pupil['foundName'];
    final className = pupil['className'];
    if (pupilId == null || pupilId <= 0) {
      throw LvsWire.unknownShape(read, '$where: no userID');
    }
    if (classId == null || classId <= 0) {
      throw LvsWire.unknownShape(read, '$where: no classID');
    }
    if (foundName is! String) {
      throw LvsWire.unknownShape(read, '$where: no foundName');
    }
    if (className != null && className is! String) {
      throw LvsWire.unknownShape(read, '$where: className is not a text');
    }
    return LvsPupilMatch(
      pupilId: pupilId,
      classId: classId,
      name: LvsWire.plainText(foundName),
      className: (className as String?)?.trim() ?? '',
    );
  }

  /// A pupil's file without today's status: `{categories: [...], pupil:
  /// {pupilID, name, class, classDesc, classID, teachers, ...}}`.
  static LvsPupilFile _parseFile(
    Object? json, {
    required int pupilId,
    required int classId,
  }) {
    final read = LvsWire.pupilFile;
    if (json is! Map) throw LvsWire.unknownShape(read, 'not an object');
    final pupil = json['pupil'];
    final categories = json['categories'];
    if (pupil is! Map) throw LvsWire.unknownShape(read, 'no pupil');
    if (categories is! List) {
      throw LvsWire.unknownShape(read, 'no list of categories');
    }
    if (LvsWire.tryId(pupil['pupilID']) != pupilId) {
      throw LvsWire.unknownShape(read, 'the pupil is not the one asked for');
    }
    // The LVS's placeholder for a pupil it does not know in that class: a
    // class of `null` (seen live, with a "not available" name).
    final answerClassId = pupil['classID'];
    if (answerClassId == null) {
      throw SmartschoolLvsPupilNotFoundError(
        'The LVS knows no such pupil in that class that the account may see '
        '(it answered with its placeholder pupil).',
        pupilId: pupilId,
        classId: classId,
      );
    }
    final fileClassId = LvsWire.tryId(answerClassId);
    if (fileClassId == null || fileClassId <= 0) {
      throw LvsWire.unknownShape(read, 'pupil.classID is not an ID');
    }
    final name = pupil['name'];
    if (name is! String) throw LvsWire.unknownShape(read, 'no pupil.name');
    return LvsPupilFile(
      pupilId: pupilId,
      classId: fileClassId,
      name: name.trim(),
      className: _text(pupil['class'], 'pupil.class'),
      classDescription: _text(pupil['classDesc'], 'pupil.classDesc'),
      teachers: _parseTeachers(pupil['teachers']),
      sections: [
        for (final (i, node) in categories.indexed)
          _parseSection(node, 'categories[$i]'),
      ],
      todayStatus: LvsTodayStatus.none,
    );
  }

  /// [value] as a text of the file: a string, trimmed, or `''` for none.
  static String _text(Object? value, String where) {
    if (value == null) return '';
    if (value is! String) {
      throw LvsWire.unknownShape(LvsWire.pupilFile, '$where is not a text');
    }
    return value.trim();
  }

  /// The class teachers: `{"<teacher id>": "<name>"}`, or `[]` for none (PHP
  /// sends an empty map as a list; seen live).
  static List<LvsTeacher> _parseTeachers(Object? teachers) {
    final read = LvsWire.pupilFile;
    if (teachers == null || (teachers is List && teachers.isEmpty)) {
      return const [];
    }
    if (teachers is! Map) {
      throw LvsWire.unknownShape(read, 'pupil.teachers is not a map');
    }
    final result = <LvsTeacher>[];
    for (final MapEntry(:key, :value) in teachers.entries) {
      final id = LvsWire.tryId(key);
      if (id == null || id <= 0 || value is! String) {
        throw LvsWire.unknownShape(
          read,
          'pupil.teachers: not an ID and a name',
        );
      }
      result.add(LvsTeacher(id: id, name: value.trim()));
    }
    return result;
  }

  /// A node of `categories`: `{id, type, name, isTitle, hasItems,
  /// hasNewItems, hasChildren, children, ...}`.
  static LvsSection _parseSection(Object? node, String where) {
    final read = LvsWire.pupilFile;
    if (node is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final id = LvsWire.tryId(node['id']);
    final type = node['type'];
    final name = node['name'];
    if (id == null || id < 0) {
      throw LvsWire.unknownShape(read, '$where: no id');
    }
    if (type is! String || type.trim().isEmpty) {
      throw LvsWire.unknownShape(read, '$where: no type');
    }
    if (name is! String) throw LvsWire.unknownShape(read, '$where: no name');
    bool flag(String key) {
      final value = node[key];
      if (value == null) return false;
      return LvsWire.tryFlag(value) ??
          (throw LvsWire.unknownShape(read, '$where: $key is not a flag'));
    }

    final children = node['children'];
    if (children != null && children is! List) {
      throw LvsWire.unknownShape(read, '$where: children is not a list');
    }
    return LvsSection(
      id: id,
      type: type.trim(),
      name: name.trim(),
      isTitle: flag('isTitle'),
      hasItems: flag('hasItems'),
      hasNewItems: flag('hasNewItems'),
      children: [
        for (final (i, child) in ((children as List?) ?? const []).indexed)
          _parseSection(child, '$where.children[$i]'),
      ],
    );
  }

  /// Today's status: `[{partOfDay, code: {name, code, color}}]`, `[]` for
  /// none.
  static LvsTodayStatus _parseStatus(Object? json) {
    const read = LvsWire.todayStatus;
    final List<Object?> halfDays;
    if (json is List) {
      halfDays = json;
    } else if (json is Map) {
      // PHP sends a list with gaps in its keys as a map.
      halfDays = json.values.toList();
    } else {
      throw LvsWire.unknownShape(read, 'not a list');
    }
    return LvsTodayStatus([
      for (final (i, halfDay) in halfDays.indexed)
        _parseHalfDay(halfDay, '[$i]'),
    ]);
  }

  static LvsHalfDayStatus _parseHalfDay(Object? halfDay, String where) {
    const read = LvsWire.todayStatus;
    if (halfDay is! Map) throw LvsWire.unknownShape(read, '$where: no object');
    final partOfDay = halfDay['partOfDay'];
    final code = halfDay['code'];
    if (partOfDay is! String || partOfDay.trim().isEmpty) {
      throw LvsWire.unknownShape(read, '$where: no partOfDay');
    }
    if (code is! Map) throw LvsWire.unknownShape(read, '$where: no code');
    String? text(String key) => switch (code[key]) {
      final String value => value.trim(),
      final num value => '$value',
      _ => null,
    };
    final short = text('code');
    final name = text('name');
    if (short == null) {
      throw LvsWire.unknownShape(read, '$where: no code.code');
    }
    if (name == null) {
      throw LvsWire.unknownShape(read, '$where: no code.name');
    }
    final color = text('color');
    return LvsHalfDayStatus(
      partOfDay: partOfDay.trim(),
      code: short,
      name: name,
      color: color == null || color.isEmpty ? null : color,
    );
  }
}
