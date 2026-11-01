// Tests for issue #88: planning a lesfiche of the Lesfiches library into an
// empty lesson hour of the own planner (`PlannerService.planLessonContent`),
// on top of the fill, the guards and the clear of #87.
//
// The answers below are trimmed captures of the live API, from the plan the
// developer tried in their own planner (with permission, cleared again) on
// 2026-10-02:
//   - GET  /lesson-content/api/v1/lesson-content/ (the lesfiches; the whole
//       list was the same after the plan and the clear)
//   - GET  /planner/api/v1/planned-placeholders/{platformId}/{id}
//       (the empty lesson hour before the plan)
//   - POST .../planned-placeholders/{platformId}/{id}/replace/planned-lessons
//       with the slot's organisers, participants, courses, period and
//       locations, the lesfiche's `sourceId` and an icon, and no name or info
//       -> 200 with a lesson named after the lesfiche, with its labels and
//       goals, and empty info (the lesfiche's was empty too)
//   - POST .../planned-elements/clear -> 200 with the slot, a new ID
// with every name, picture, user, group, course, label, goal, location,
// lesfiche and element ID and every title replaced by obvious fakes ("Jan
// Janssens" is the authenticated user `4069_1001_0`, "Wim Willems" a
// colleague, classes `4069_2001`/`4069_2002`, room `101`, "Springfield
// Academy"; `JAAR 6` and `TRIMESTER 1` are the school's labels as they are).
// The capabilities are trimmed to the flags that matter. The answers that
// the planner did not give live (unusable answers, other kinds of
// lesfiches) are made up from those.
//
// Issue #224 adds the replace of a filled lesson by a lesfiche
// (`replaceWithLessonContent`, `POST planned-lessons/replace/planned-lessons/
// {platformId}/{id}` -> 201 with the new lesson) and the plan of one
// lesfiche into several hours at once (`planLessonContentInto`, `POST
// planned-elements/replace-with-lesson-content?waitForRefresh=true` -> 200
// with short elements and `exceptions`), both tried live on 2026-11-01 (two
// hours of the developer's own planner, cleared again). Their answers below
// are made from the answers above, in the shape the issue writes down; the
// exceptions in the object form were not seen live, and their values are
// made up.
//
// The fake Smartschool answers only the requests each test scripts (and the
// login chain), and fails the test on any other request: the blank fill of
// #87 (`.../blanco`), the bulk plan where a test does not script it, any
// write to the Lesfiches module, `DELETE`, and a second fill never get an
// answer.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

/// The authenticated user (Jan Janssens).
const _me = '4069_1001_0';

const _slotId = 'e0000000-0000-5000-8000-000000000010';
const _lessonId = 'e0000000-0000-4000-8000-000000000011';
const _newSlotId = 'e0000000-0000-5000-8000-000000000012';

/// The lesson lesfiche ("Herhaling: lussen") and the assignment lesfiche of
/// [_fiches].
const _ficheId = 'b0000000-0000-4000-8000-000000000001';
const _assignmentFicheId = 'b0000000-0000-4000-8000-000000000002';
const _ficheName = 'Herhaling: lussen';

const _api = '/planner/api/v1';
const _slotPath = '$_api/planned-placeholders/4069/$_slotId';
const _planPath = '$_slotPath/replace/planned-lessons';
const _lessonPath = '$_api/planned-lessons/4069/$_lessonId';
const _clearPath = '$_api/planned-elements/clear';
const _ownWeekPath = '$_api/planned-elements/user/$_me';
const _fichesPath = '/lesson-content/api/v1/lesson-content/';

/// The requests, as the fake logs them.
const _readFiches = 'GET $_fichesPath';
const _readSlot = 'GET $_slotPath';
const _plan = 'POST $_planPath';
const _readLesson = 'GET $_lessonPath';
const _clear = 'POST $_clearPath';
const _readCourses = 'GET /course-list/api/v1/courses';

/// An empty lesson hour of the own planner on Friday 20 November 2026 (winter
/// time, `+01:00`), classes 6A1 and 6A2, course informatica, room 101: no
/// name, and it can be filled (`canUserReplace`).
const _slot = r'''
{"id":"e0000000-0000-5000-8000-000000000010","platformId":4069,"period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"labels":[],"presenceSaved":false,"showPresenceChoices":false,"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserReplace":true,"canUserReschedule":false,"canUserChangeParticipants":true,"canUserChangeLocations":true,"canUserRename":false,"canUserChangeIcon":false,"canUserSeeProperties":{"id":true,"platformId":true,"period":true,"organisers":true,"participants":true,"courses":true,"locations":true,"plannedElementType":true}},"plannedElementType":"planned-placeholders","onlineSession":null,"reservations":[],"sort":"20261120111000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000010","to":"f0000000-0000-5000-8000-000000000011"}}
''';

/// The school's course list (`/course-list/api/v1/courses`), trimmed to the
/// course of the slot (informatica), as the planner names it (#101).
const _courses = r'''
[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}]
''';

/// The planner's answer to the plan: a new lesson in the slot's period, with
/// the slot's classes, course and room, named after the lesfiche, with the
/// lesfiche's labels and goals and its (empty) info. Nothing in it points
/// back to the lesfiche.
const _planned = r'''
{"id":"e0000000-0000-4000-8000-000000000011","platformId":4069,"name":"Herhaling: lussen","icon":"document_observation","info":"","privateInfo":"","publicInfo":"","period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[{"identifier":"4069_d0000000-0000-4000-8000-000000000001","type":"platform","text":"JAAR 6","color":"aqua","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000001","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]},{"identifier":"4069_d0000000-0000-4000-8000-000000000002","type":"platform","text":"TRIMESTER 1","color":"yellow","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000002","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]}],"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"goals":[{"id":"90000000-0000-4000-8000-000000000001","leerplanId":"90000000-0000-4000-8000-000000000010","type":"llinkid"},{"id":"90000000-0000-4000-8000-000000000002","leerplanId":"90000000-0000-4000-8000-000000000010","type":"llinkid"}],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserChangePrivateInfo":true,"canUserChangePublicInfo":true,"canUserReplace":true,"canUserReschedule":false,"canUserRename":true,"canUserChangeIcon":true,"canUserChangeLabels":true,"canUserChangeGoals":true,"canUserSaveInSourceModule":true,"canUserSeeProperties":{"id":true,"platformId":true,"name":true,"icon":true,"info":true,"privateInfo":true,"publicInfo":true,"period":true,"organisers":true,"participants":true,"labels":true,"courses":true,"locations":true,"goals":true,"plannedElementType":true}},"presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-lessons","plannedToDos":[],"sort":"20261120111000_4_6A1_Herhaling: lussen","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000010","to":"f0000000-0000-5000-8000-000000000011"}}
''';

/// The planner's answer to the clear: the lesson hour is a timetable slot
/// again, the same as before the plan but for its ID.
final _cleared = _with(_slot, changes: {'id': _newSlotId});

/// Two lesfiches as the Lesfiches module lists them: a hidden lesson
/// lesfiche with two school labels and no info, and an assignment lesfiche
/// (`Kleine Taak`).
const _fiches = r'''
[{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Herhaling: lussen","icon":"document_observation","publicInfo":"","isVisible":false,"owner":"4069_1001_0","dateStateChanged":"2025-09-01 08:15:00","dateLastChanged":"2026-09-07 19:51:25","courses":[{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000005"}],"labels":[{"identifier":"4069_d0000000-0000-4000-8000-000000000001","type":"platform","text":"JAAR 6","color":"aqua","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000001","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]},{"identifier":"4069_d0000000-0000-4000-8000-000000000002","type":"platform","text":"TRIMESTER 1","color":"yellow","isVisible":true,"id":"4069_d0000000-0000-4000-8000-000000000002","platformId":4069,"ssId":4069,"locations":["planner_routines","planner_activities","navigator","lesson_content","planner"]}],"weblinks":[],"partnerWeblinks":[],"attachments":[],"deeplinks":[],"capabilities":{"canUserSeeDetails":true,"canUserEdit":true,"canUserTrash":true,"canUserTrashAsAdmin":false},"type":"lessons"},
{"id":"b0000000-0000-4000-8000-000000000002","platformId":4069,"assignmentType":{"id":"a0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Kleine Taak","abbreviation":"KT","isVisible":true,"defaultTiming":"deadline","weight":0},"name":"Taak: een eigen spel","icon":"flags_red_yellow","publicInfo":"<p>Dien je taak in via de digitale klas.<\/p>","isVisible":true,"owner":"4069_1001_0","dateStateChanged":"2025-09-05 11:30:28","dateLastChanged":"2025-09-05 11:30:28","courses":[{"platformId":4069,"id":"c0000000-0000-4000-8000-000000000005"}],"labels":[],"weblinks":[],"partnerWeblinks":[],"attachments":[],"deeplinks":[],"capabilities":{"canUserSeeDetails":true,"canUserEdit":true,"canUserTrash":true,"canUserTrashAsAdmin":false,"canUserChangeAssignmentTypeAsAdmin":false},"type":"assignments"}]
''';

/// [_fiches] with the lesson lesfiche changed by [change].
String _fichesWith(void Function(Map<String, dynamic> fiche) change) {
  final fiches = [
    for (final item in jsonDecode(_fiches) as List)
      item as Map<String, dynamic>,
  ];
  change(fiches.first);
  return jsonEncode(fiches);
}

/// The colleague (Wim Willems) as an organiser.
final _colleague =
    jsonDecode(r'''
{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}
''')
        as Map<String, dynamic>;

/// [json], an element, with [changes] to its fields and [capabilities] to its
/// capabilities.
String _with(
  String json, {
  Map<String, Object?> changes = const {},
  Map<String, bool> capabilities = const {},
}) {
  final element = jsonDecode(json) as Map<String, dynamic>;
  element.addAll(changes);
  (element['capabilities'] as Map<String, dynamic>).addAll(capabilities);
  return jsonEncode(element);
}

/// A period of 20 November 2026 from [from] to [to] (`HH:mm`), as the
/// planner writes it.
Map<String, Object> _period(String from, String to) => {
  'dateTimeFrom': '2026-11-20T$from:00+01:00',
  'dateTimeTo': '2026-11-20T$to:00+01:00',
  'wholeDay': false,
  'deadline': false,
};

/// [json] as the calendar lists it (`getPlannedElements`).
PlannedElement _listed(String json) =>
    PlannerService.parsePlannedElements(jsonDecode('[$json]')).single;

/// The body that plans lesfiche [sourceId] into [_slot] (as tried live): the
/// slot's organisers, classes, course, period and room, the lesfiche's ID
/// and [icon], and no name or info.
Map<String, Object?> _planBody({
  String sourceId = _ficheId,
  String icon = 'document_observation',
}) => {
  'organisers': {
    'users': [_me],
    'groups': <Object>[],
  },
  'participants': {
    'groups': ['4069_2001', '4069_2002'],
    'users': <Object>[],
    'userRoles': <Object>[],
    'groupFilters': {'filters': <Object>[], 'additionalUsers': <Object>[]},
  },
  'courses': [
    {'platformId': 4069, 'id': 'c0000000-0000-4000-8000-000000000005'},
  ],
  'period': {
    'dateTimeFrom': '2026-11-20T11:10:00+01:00',
    'dateTimeTo': '2026-11-20T12:00:00+01:00',
    'wholeDay': false,
  },
  'sourceId': sourceId,
  'icon': icon,
  'locations': [
    {
      'id': '10000000-0000-4000-8000-000000000101',
      'platformId': 4069,
      'platformlName': 'Springfield Academy',
      'type': 'mini-db-item',
    },
  ],
};

/// The planner's answer to the detail of an element it does not have.
const _notFound = '{"status":404,"title":"Not Found","detail":"","type":""}';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

/// Smartschool's home page, trimmed to the script that holds the
/// authenticated user (`vars.authenticatedUser`).
const _homePage =
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>\n'
    '<script>\n'
    'APP.extend(APP.vars || {}, JSON.parse(\'{"vars":{"authenticatedUser":'
    '{"id":"$_me","name":{"startingWithFirstName":"Jan Janssens",'
    '"startingWithLastName":"Janssens Jan"}}}}\'));\n'
    '</script>\n'
    '</body></html>';

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

typedef _Answer = ({int status, String body, String? location});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, location: null);

/// Smartschool's answer to a JSON POST on a session it does not accept: a
/// `302` to `/login`, which the HTTP client leaves unfollowed (#22).
const _Answer _toLogin = (
  status: 302,
  body: '<html><body>Redirecting to /login</body></html>',
  location: '/login',
);

/// A request as it reached the fake Smartschool: its body decoded when it
/// is JSON.
typedef _Request = ({String label, Object? body, String query});

/// A Smartschool whose session is accepted, that answers the planner and
/// Lesfiches requests of [answers] (by label, `METHOD path`; a list is
/// answered in turn, its last answer for every later request), the reads the
/// client makes for the authenticated user, and the login chain; and fails
/// the test on any other request.
///
/// [failures] makes the requests of those labels fail on the way, after they
/// went out. [respond] answers a request before [answers] when it returns an
/// answer.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    Map<String, List<_Answer>> answers, {
    this.failures = const {},
    this.respond,
  }) : _answers = {
         for (final MapEntry(:key, :value) in answers.entries) key: [...value],
       };

  final Map<String, List<_Answer>> _answers;
  final Map<String, Object Function(RequestOptions options)> failures;
  final _Answer? Function(String label, Object? body)? respond;

  bool _passwordDone = false;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The labels of [requests], in order.
  List<String> get log => [for (final r in requests) r.label];

  /// The labels of the requests to the planner and the Lesfiches module, in
  /// order.
  List<String> get moduleLog => [
    for (final label in log)
      if (label.contains('/planner/') || label.contains('/lesson-content/'))
        label,
  ];

  /// The body of the one request [label].
  Object? bodyOf(String label) =>
      requests.singleWhere((r) => r.label == label).body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final label = '${options.method} ${options.uri.path}';
    final text = await _read(requestStream);
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    requests.add((label: label, body: body, query: options.uri.query));

    final failure = failures[label];
    if (failure != null) throw failure(options);

    switch (label) {
      case _readCourses:
        return _respond(_json(_courses));
      case 'GET /login':
        return _respond((status: 200, body: _loginPage, location: null));
      case 'POST /login':
        _passwordDone = true;
        return _respond((
          status: 302,
          body: '<html><body>Redirecting to /</body></html>',
          location: '/',
        ));
      case 'GET /':
        if (_passwordDone) {
          return _respond((
              status: 200,
              body: '<html>2fa</html>',
              location: null,
            ))
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/2fa')),
            ];
        }
        return _respond((status: 200, body: _homePage, location: null));
      case 'GET /2fa/api/v1/config':
        return _respond(
          _json('{"possibleAuthenticationMechanisms":["googleAuthenticator"]}'),
        );
      case 'POST /2fa/api/v1/google-authenticator':
        _passwordDone = false;
        return _respond(_json('{"success":true,"redirectTo":"/"}'));
    }

    final scripted = respond?.call(label, body);
    if (scripted != null) return _respond(scripted);
    final queue = _answers[label];
    if (queue == null || queue.isEmpty) {
      fail('Unexpected request: ${options.method} ${options.uri}');
    }
    return _respond(queue.length > 1 ? queue.removeAt(0) : queue.single);
  }

  static ResponseBody _respond(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: [
        answer.body.trimLeft().startsWith('<')
            ? 'text/html; charset=UTF-8'
            : 'application/json',
      ],
      if (answer.location != null) 'location': [answer.location!],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<String> _read(Stream<Uint8List>? body) async => body == null
    ? ''
    : utf8.decode(
        await body.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)),
        allowMalformed: true,
      );

/// A check before the plan refused it: nothing was sent. The error gives the
/// check as [reason] (#100), with the ID of the [element] it read again
/// (`null` when it refused the lesfiche before reading the slot), the
/// capability [flags] it refused on and the ID of the [lessonContent] that
/// is not a lesson one. It carries no assignment types (#119: only an
/// unknown assignment type does).
Matcher _refused(
  Object? message, {
  required PlannerWriteRefusalReason reason,
  Object? element = anything,
  Object? flags = isEmpty,
  Object? lessonContent = isNull,
}) => isA<SmartschoolPlannerWriteRefusedError>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.message, 'message', contains('planLessonContent'))
    .having((e) => e.message, 'message', contains('Nothing was sent'))
    .having((e) => e.reason, 'reason', reason)
    .having((e) => e.element?.id, 'element', element)
    .having((e) => e.capabilityFlags, 'capabilityFlags', flags)
    .having((e) => e.lessonContent?.id, 'lessonContent', lessonContent)
    .having((e) => e.assignmentTypes, 'assignmentTypes', isEmpty);

/// The plan went out without the planner confirming it.
Matcher _unconfirmed(
  Object? message, {
  Object? statusCode = anything,
  Object? cause = anything,
}) => allOf(
  isNot(isA<SmartschoolPlannerError>()),
  isA<SmartschoolPlannerSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('planLessonContent'))
      .having((e) => e.message, 'message', contains('may or may not'))
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.cause, 'cause', cause),
);

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService, SmartschoolClient)> serve(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures = const {},
    _Answer? Function(String label, Object? body)? respond,
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers, failures: failures, respond: respond);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client), client);
  }

  group('PlannerService.planLessonContent', () {
    test('reads the lesfiches and the slot again, then plans the lesfiche '
        'once: the route without /blanco, its sourceId and icon, no name or '
        'info; returns the lesson named after the lesfiche', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot: [_json(_slot)],
        _plan: [_json(_planned)],
      });

      final lesson = await planner.planLessonContent(
        placeholder: _listed(_slot),
        lessonContentId: _ficheId,
      );

      expect(server.moduleLog, [_readFiches, _readSlot, _plan]);
      expect(server.log, isNot(contains(endsWith('/blanco'))));
      // The lesfiche's ID and kind are all it needs: it does not read the
      // course list for the names of the lesfiches' courses (#101). The one
      // read of it is the client's, for the platform ID it reads with the
      // authenticated user.
      expect(server.log.where((l) => l == _readCourses), hasLength(1));
      expect(server.bodyOf(_plan), _planBody());
      final body = server.bodyOf(_plan)! as Map<String, dynamic>;
      for (final key in ['name', 'info', 'publicInfo', 'privateInfo']) {
        expect(body, isNot(contains(key)), reason: key);
      }

      expect(lesson, isA<PlannedElementDetail>());
      expect(lesson.id, _lessonId);
      expect(lesson.type, PlannedElementType.lesson);
      expect(lesson.name, _ficheName);
      expect(lesson.icon, 'document_observation');
      expect(lesson.publicInfo, '');
      expect(lesson.privateInfo, '');
      expect(lesson.participantGroups.map((g) => g.name), ['6A1', '6A2']);
      expect(lesson.courses.single.name, 'informatica');
      expect(lesson.locations.single.title, '101');
      expect(
        lesson.period.from.isAtSameMomentAs(DateTime.utc(2026, 11, 20, 10, 10)),
        isTrue,
      );
      // The lesfiche's labels and goals came along (seen live); the labels
      // are typed (#98), the goals are only in raw.
      expect(lesson.labels!.map((l) => l.text), ['JAAR 6', 'TRIMESTER 1']);
      expect(lesson.labels!.every((l) => l.isSchoolLabel), isTrue);
      expect(lesson.attachments, isEmpty);
      expect(lesson.weblinks, isEmpty);
      expect(lesson.raw['goals'] as List, hasLength(2));
    });

    test('plans a hidden lesfiche like any other, as seen live', () async {
      final (_, planner, client) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot: [_json(_slot)],
        _plan: [_json(_planned)],
      });
      final fiche = (await LessonContentService(
        client,
      ).getItems()).firstWhere((f) => f.id == _ficheId);
      expect(fiche.isVisible, isFalse);

      final lesson = await planner.planLessonContent(
        placeholder: _listed(_slot),
        lessonContentId: fiche.id,
      );

      expect(lesson.name, fiche.name);
    });

    test('finds the lesfiche whatever the case of the ID and the white '
        'space around it, and sends its ID as listed', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot: [_json(_slot)],
        _plan: [_json(_planned)],
      });

      await planner.planLessonContent(
        placeholder: _listed(_slot),
        lessonContentId: ' ${_ficheId.toUpperCase()}\n',
      );

      expect(server.bodyOf(_plan), _planBody());
    });

    test("sends the lesfiche's own icon, and the default lesson icon for a "
        'lesfiche without one', () async {
      for (final (icon, sent) in [
        ('book', 'book'),
        (null, PlannerService.defaultLessonIcon),
        ('  ', PlannerService.defaultLessonIcon),
      ]) {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fichesWith((f) => f['icon'] = icon))],
          _readSlot: [_json(_slot)],
          _plan: [
            _json(_with(_planned, changes: {'icon': sent})),
          ],
        });

        await planner.planLessonContent(
          placeholder: _listed(_slot),
          lessonContentId: _ficheId,
        );

        expect(server.bodyOf(_plan), _planBody(icon: sent), reason: '$icon');
      }
    });

    test('fills the body from the slot as read again, not from the listed '
        'element', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot: [_json(_slot)],
        _plan: [_json(_planned)],
      });

      await planner.planLessonContent(
        placeholder: _listed(_with(_slot, changes: {'locations': <Object>[]})),
        lessonContentId: _ficheId,
      );

      expect(server.bodyOf(_plan), _planBody());
    });

    group('refuses before anything is sent', () {
      test('a lesfiche that is not among the lesfiches: the planner is not '
          'read', () async {
        const unknown = 'b0000000-0000-4000-8000-000000000099';
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: unknown,
          ),
          throwsA(
            _refused(
              allOf(contains('no lesfiche $unknown'), contains('2 lesfiches')),
              reason: PlannerWriteRefusalReason.unknownLessonContent,
              element: isNull,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches]);
      });

      test('an assignment lesfiche (#89 territory)', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _assignmentFicheId,
          ),
          throwsA(
            allOf(
              _refused(
                allOf(
                  contains('"Taak: een eigen spel"'),
                  contains('an assignment lesfiche (assignments)'),
                  contains('not a lesson one'),
                ),
                reason: PlannerWriteRefusalReason.notALessonLessonContent,
                element: isNull,
                lessonContent: _assignmentFicheId,
              ),
              // The lesfiche as read again, to name it in the app's words.
              isA<SmartschoolPlannerWriteRefusedError>()
                  .having(
                    (e) => e.lessonContent?.name,
                    'lessonContent.name',
                    'Taak: een eigen spel',
                  )
                  .having(
                    (e) => e.lessonContent?.type,
                    'lessonContent.type',
                    LessonContentType.assignment,
                  ),
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches]);
      });

      test('a lesfiche of a kind the library does not know', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fichesWith((f) => f['type'] = 'activities'))],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            _refused(
              contains('a "activities" lesfiche'),
              reason: PlannerWriteRefusalReason.notALessonLessonContent,
              element: isNull,
              lessonContent: _ficheId,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches]);
      });

      test('lesfiches that cannot be read: a SmartschoolLessonContentError, '
          'the planner is not read', () async {
        for (final answer in [
          _json(_errorPage, status: 500),
          _json('<!DOCTYPE html><html><body>Lesfiches</body></html>'),
        ]) {
          final (server, planner, _) = await serve({
            _readFiches: [answer],
          });

          await expectLater(
            planner.planLessonContent(
              placeholder: _listed(_slot),
              lessonContentId: _ficheId,
            ),
            throwsA(isA<SmartschoolLessonContentError>()),
          );
          expect(server.moduleLog, [_readFiches]);
        }
      });

      test(
        "a colleague's slot, even one the planner lets the user fill",
        () async {
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readSlot: [
              _json(
                _with(
                  _slot,
                  changes: {
                    'organisers': {
                      'users': [_colleague],
                      'groups': <Object>[],
                    },
                  },
                ),
              ),
            ],
          });

          await expectLater(
            planner.planLessonContent(
              placeholder: _listed(_slot),
              lessonContentId: _ficheId,
            ),
            throwsA(
              _refused(
                allOf(
                  contains('not in your own planner'),
                  contains('Wim Willems (4069_1003_0)'),
                ),
                reason: PlannerWriteRefusalReason.notOwn,
                element: _slotId,
              ),
            ),
          );
          expect(server.moduleLog, [_readFiches, _readSlot]);
        },
      );

      test('a slot the planner does not let the user fill '
          '(canUserReplace)', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot: [
            _json(_with(_slot, capabilities: {'canUserReplace': false})),
          ],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            _refused(
              contains('canUserReplace not set'),
              reason: PlannerWriteRefusalReason.notAllowed,
              element: _slotId,
              flags: ['canUserReplace'],
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches, _readSlot]);
      });

      test('a slot that is no longer in the period it was read with', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot: [
            _json(_with(_slot, changes: {'period': _period('12:00', '12:50')})),
          ],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            _refused(
              contains('no longer in the period'),
              reason: PlannerWriteRefusalReason.periodChanged,
              element: _slotId,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches, _readSlot]);
      });

      test('a slot with participant roles', () async {
        final participants =
            (jsonDecode(_slot) as Map<String, dynamic>)['participants']
                as Map<String, dynamic>;
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot: [
            _json(
              _with(
                _slot,
                changes: {
                  'participants': {
                    ...participants,
                    'userRoles': [
                      {'id': 'leerling'},
                    ],
                  },
                },
              ),
            ),
          ],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            _refused(
              contains('participant roles or group filters'),
              reason: PlannerWriteRefusalReason.participantRoles,
              element: _slotId,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches, _readSlot]);
      });

      test('a slot the planner no longer has (filled since)', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot: [_json(_notFound, status: 404)],
        });

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            isA<SmartschoolPlannedElementNotFoundError>().having(
              (e) => e.elementId,
              'elementId',
              _slotId,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches, _readSlot]);
      });

      test('an element that is not a timetable slot, or an empty lesfiche '
          'ID: an ArgumentError, before any request', () async {
        final (server, planner, _) = await serve({});

        await expectLater(
          () => planner.planLessonContent(
            placeholder: _listed(_planned),
            lessonContentId: _ficheId,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('not a timetable slot'),
            ),
          ),
        );
        await expectLater(
          () => planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: ' \n',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              'lessonContentId',
            ),
          ),
        );
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the plan is unconfirmed, and the '
        'plan is not sent again', () {
      final answers = <String, (_Answer, Object?, Object?)>{
        'HTTP 500': (
          _json(_errorPage, status: 500),
          contains('cannot be used'),
          500,
        ),
        'not an element': (_json('[]'), contains('cannot be used'), 200),
        'a timetable slot': (
          _json(_slot),
          contains('a planned-placeholders instead of a lesson'),
          200,
        ),
        'a lesson named otherwise than the lesfiche': (
          _json(_with(_planned, changes: {'name': 'Iets anders'})),
          contains('named "Iets anders" instead of "$_ficheName"'),
          200,
        ),
        'a lesson in another period': (
          _json(
            _with(_planned, changes: {'period': _period('12:00', '12:50')}),
          ),
          contains('in another period'),
          200,
        ),
      };
      for (final MapEntry(key: name, value: (answer, message, status))
          in answers.entries) {
        test(name, () async {
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readSlot: [_json(_slot)],
            _plan: [answer],
          });

          await expectLater(
            planner.planLessonContent(
              placeholder: _listed(_slot),
              lessonContentId: _ficheId,
            ),
            throwsA(
              _unconfirmed(
                allOf(contains('fill'), message, contains('404 once it was')),
                statusCode: status,
              ),
            ),
          );
          expect(server.moduleLog, [_readFiches, _readSlot, _plan]);
        });
      }

      test('the connection drops after the plan went out', () async {
        final (server, planner, _) = await serve(
          {
            _readFiches: [_json(_fiches)],
            _readSlot: [_json(_slot)],
          },
          failures: {_plan: _dropped},
        );

        await expectLater(
          planner.planLessonContent(
            placeholder: _listed(_slot),
            lessonContentId: _ficheId,
          ),
          throwsA(
            _unconfirmed(
              contains('no answer came in'),
              statusCode: isNull,
              cause: isA<SmartschoolConnectionError>(),
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches, _readSlot, _plan]);
      });
    });

    test('a session refused for the plan is not retried after logging in '
        'again: no login, no second plan', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot: [_json(_slot)],
        _plan: [_toLogin, _json(_planned)],
      });

      await expectLater(
        planner.planLessonContent(
          placeholder: _listed(_slot),
          lessonContentId: _ficheId,
        ),
        throwsA(
          isA<SmartschoolSessionExpiredError>().having(
            (e) => e.message,
            'message',
            contains('not retried after logging in again'),
          ),
        ),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.moduleLog, [_readFiches, _readSlot, _plan]);
    });
  });

  _issue224(serve);
  _issue225(serve);

  // ---------------------------------------------------------------------------
  // The whole flow
  // ---------------------------------------------------------------------------

  test('the flow of the issue against a planner that keeps its state: list '
      'the lesfiches, find an empty hour in the own week, plan a lesson '
      'lesfiche into it, have an assignment lesfiche and a second plan '
      'refused, clear it, and find the hour empty and the lesfiches '
      'unchanged', () async {
    // A planner with one lesson hour in the own week, that changes as the
    // live planner did: the plan takes the slot (its detail is 404) and makes
    // a lesson named after the lesfiche, the clear takes the lesson and makes
    // a slot with a new ID. The Lesfiches module only answers its list.
    String? slot = _slot;
    String? lesson;

    _Answer? planner(String label, Object? body) {
      final slotId = slot == null
          ? null
          : (jsonDecode(slot!) as Map<String, dynamic>)['id'];
      switch (label) {
        case _readFiches:
          return _json(_fiches);
        case 'GET $_ownWeekPath':
          return _json('[${slot ?? lesson}]');
        case 'GET $_api/planned-placeholders/4069/$_slotId':
        case 'GET $_api/planned-placeholders/4069/$_newSlotId':
          return label.endsWith('$slotId')
              ? _json(slot!)
              : _json(_notFound, status: 404);
        case _readLesson:
          return lesson == null
              ? _json(_notFound, status: 404)
              : _json(lesson!);
        case _plan:
          expect(slotId, _slotId, reason: 'only the slot that exists');
          final plan = body! as Map<String, dynamic>;
          final fiche = (jsonDecode(_fiches) as List).singleWhere(
            (f) => f['id'] == plan['sourceId'],
          );
          // The planner names the lesson after the lesfiche.
          lesson = _with(
            _planned,
            changes: {'name': fiche['name'], 'icon': plan['icon']},
          );
          slot = null;
          return _json(lesson!);
        case _clear:
          expect(body, {
            'type': 'planned-lessons',
            'elementId': _lessonId,
            'elementPlatformId': 4069,
          });
          lesson = null;
          slot = _cleared;
          return _json(slot!);
      }
      return null;
    }

    final (server, service, client) = await serve({}, respond: planner);
    final lessonContent = LessonContentService(client);
    final fiches = await lessonContent.getItems();
    final fiche = fiches.singleWhere(
      (f) => f.type == LessonContentType.lesson && f.name == _ficheName,
    );
    final assignmentFiche = fiches.singleWhere(
      (f) => f.type == LessonContentType.assignment,
    );

    Future<PlannedElement> hourOfWeek() async {
      final week = await service.getPlannedElements(
        await service.ownCalendar(),
        from: DateTime.utc(2026, 11, 16),
        to: DateTime.utc(2026, 11, 20, 22, 59, 59),
      );
      return week.singleWhere(
        (e) =>
            e.period.from.isAtSameMomentAs(DateTime.utc(2026, 11, 20, 10, 10)),
      );
    }

    final hour = await hourOfWeek();
    expect(hour.type, PlannedElementType.placeholder);
    // The lesfiche names its course as the planner names the hour's course:
    // the course list has the planner's course IDs (#101).
    expect(fiche.courses.single.id, hour.courses.single.id);
    expect(fiche.courses.single.name, hour.courses.single.name);
    expect(fiche.courses.single.name, 'informatica');

    // An assignment lesfiche is refused before the slot is read, with the
    // lesfiche (#100).
    await expectLater(
      service.planLessonContent(
        placeholder: hour,
        lessonContentId: assignmentFiche.id,
      ),
      throwsA(
        isA<SmartschoolPlannerWriteRefusedError>()
            .having(
              (e) => e.reason,
              'reason',
              PlannerWriteRefusalReason.notALessonLessonContent,
            )
            .having(
              (e) => e.lessonContent?.name,
              'lesfiche',
              assignmentFiche.name,
            )
            .having((e) => e.element, 'element', isNull),
      ),
    );

    final planned = await service.planLessonContent(
      placeholder: hour,
      lessonContentId: fiche.id,
    );
    expect(planned.type, PlannedElementType.lesson);
    expect(planned.name, fiche.name);
    expect(planned.icon, fiche.icon);
    expect(planned.participantGroups.map((g) => g.id), [
      '4069_2001',
      '4069_2002',
    ]);
    expect((await service.getDetail(planned)).name, fiche.name);

    // A second plan of the hour is refused: the slot is gone.
    await expectLater(
      service.planLessonContent(placeholder: hour, lessonContentId: fiche.id),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );

    final empty = await service.clearLesson(planned);
    expect(empty.type, PlannedElementType.placeholder);
    expect(empty.id, isNot(hour.id));
    final after = await hourOfWeek();
    expect(after.type, PlannedElementType.placeholder);
    expect(after.id, _newSlotId);

    // The lesfiches are as before: the plan wrote nothing to the module.
    final fichesAfter = await lessonContent.getItems();
    expect(
      [for (final f in fichesAfter) '${f.id} ${f.name} ${f.dateLastChanged}'],
      [for (final f in fiches) '${f.id} ${f.name} ${f.dateLastChanged}'],
    );
    expect(
      server.log.where((l) => l.contains('/lesson-content/')),
      everyElement(_readFiches),
    );
    expect(server.moduleLog.where((l) => l.startsWith('POST')).toList(), [
      _plan,
      _clear,
    ]);
  });
}

// -----------------------------------------------------------------------------
// #224: replace a filled lesson by a lesfiche, and plan one lesfiche into
// several hours at once
// -----------------------------------------------------------------------------

/// A lesson typed in by hand (`planLesson`) in the hour of [_slot].
const _typedId = 'e0000000-0000-4000-8000-000000000020';

/// The lesson the replace of [_typedId] makes.
const _replacedId = 'e0000000-0000-4000-8000-000000000021';

/// A second empty lesson hour of the own planner, 12:00 - 12:50.
const _slot2Id = 'e0000000-0000-5000-8000-000000000022';

/// The lessons the bulk plan makes in [_slot2Id] and in [_typedId].
const _bulkSlotLessonId = 'e0000000-0000-4000-8000-000000000023';
const _bulkTypedLessonId = 'e0000000-0000-4000-8000-000000000024';

const _typedPath = '$_api/planned-lessons/4069/$_typedId';
const _replacePath =
    '$_api/planned-lessons/replace/planned-lessons/4069/$_typedId';
const _bulkPath = '$_api/planned-elements/replace-with-lesson-content';
const _slot2Path = '$_api/planned-placeholders/4069/$_slot2Id';

const _readTyped = 'GET $_typedPath';
const _replace = 'POST $_replacePath';
const _bulk = 'POST $_bulkPath';
const _readSlot2 = 'GET $_slot2Path';
String _readNewLesson(String id) => 'GET $_api/planned-lessons/4069/$id';

/// The lesson typed in by hand: its own name and info, no labels or goals.
final _typed = _with(
  _planned,
  changes: {
    'id': _typedId,
    'name': 'Lussen: for en while',
    'info': '<p>Oefening 3 overslaan.</p>',
    'privateInfo': '<p>Oefening 3 overslaan.</p>',
    'publicInfo': '<p>Breng je laptop mee.</p>',
    'labels': <Object>[],
    'goals': <Object>[],
  },
);

/// The planner's answer to the replace of [_typed] (`201`): a new lesson in
/// its hour, named after the lesfiche, with the lesfiche's info and goals.
final _replaced = _with(
  _planned,
  changes: {
    'id': _replacedId,
    'info': '<p>Start met de quiz.</p>',
    'privateInfo': '<p>Start met de quiz.</p>',
    'publicInfo': '<p>Lees hoofdstuk 3.</p>',
  },
);

/// The second empty lesson hour, 12:00 - 12:50.
final _slot2 = _with(
  _slot,
  changes: {'id': _slot2Id, 'period': _period('12:00', '12:50')},
);

/// The new lessons of the bulk plan, as their detail gives them.
final _bulkSlotLesson = _with(
  _planned,
  changes: {'id': _bulkSlotLessonId, 'period': _period('12:00', '12:50')},
);
final _bulkTypedLesson = _with(_planned, changes: {'id': _bulkTypedLessonId});

/// A short element of the bulk answer: the planner leaves the info, goals,
/// attachments, weblinks and labels `null`.
Map<String, Object?> _short(String id, String from, String to) => {
  'id': id,
  'platformId': 4069,
  'name': _ficheName,
  'icon': 'document_observation',
  'period': _period(from, to),
  'plannedElementType': 'planned-lessons',
  'publicInfo': null,
  'privateInfo': null,
  'goals': null,
  'attachments': null,
  'weblinks': null,
  'labels': null,
};

/// The bulk answer with [planned] and [exceptions].
String _bulkAnswer(List<Map<String, Object?>> planned, [Object? exceptions]) =>
    jsonEncode({
      'plannedElements': planned,
      'exceptions': exceptions ?? <Object>[],
    });

/// The body of the bulk plan of [_ficheId] into [targets] (ID and type), as
/// tried live.
Map<String, Object?> _bulkBody(List<(String, String)> targets) => {
  'platformId': 4069,
  'sourceId': _ficheId,
  'sourceType': 'lesson',
  'courses': [
    {'platformId': 4069, 'id': 'c0000000-0000-4000-8000-000000000005'},
  ],
  'visibility': <Object>[],
  'plannedElements': [
    for (final (id, type) in targets)
      {'plannedElementId': id, 'platformId': 4069, 'plannedElementType': type},
  ],
};

/// A check of [operation] refused the write: nothing was sent.
Matcher _refusedBy(
  String operation, {
  required PlannerWriteRefusalReason reason,
  Object? message = anything,
  Object? element = anything,
  Object? flags = isEmpty,
  Object? lessonContent = isNull,
}) => isA<SmartschoolPlannerWriteRefusedError>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.message, 'message', startsWith('$operation: '))
    .having((e) => e.message, 'message', endsWith('Nothing was sent.'))
    .having((e) => e.reason, 'reason', reason)
    .having((e) => e.element?.id, 'element', element)
    .having((e) => e.capabilityFlags, 'capabilityFlags', flags)
    .having((e) => e.lessonContent?.id, 'lessonContent', lessonContent);

/// [operation] went out without the planner confirming it.
Matcher _unconfirmedBy(String operation, Object? message) => allOf(
  isNot(isA<SmartschoolPlannerError>()),
  isA<SmartschoolPlannerSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', startsWith('$operation: '))
      .having((e) => e.message, 'message', contains('may')),
);

void _issue224(
  Future<(_Smartschool, PlannerService, SmartschoolClient)> Function(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures,
    _Answer? Function(String label, Object? body)? respond,
  })
  serve,
) {
  group('PlannerService.replaceWithLessonContent (#224)', () {
    const op = 'replaceWithLessonContent';

    test('reads the lesfiches and the lesson again, then sends the replace '
        "once: the lesson's hour, the lesfiche's sourceId and icon; returns "
        'the new lesson from the 201 answer', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readTyped: [_json(_typed)],
        _replace: [_json(_replaced, status: 201)],
      });

      final lesson = await planner.replaceWithLessonContent(
        lesson: _listed(_typed),
        lessonContentId: _ficheId,
      );

      expect(server.moduleLog, [_readFiches, _readTyped, _replace]);
      // The body of the fill of an empty hour, built from the lesson.
      expect(server.bodyOf(_replace), _planBody());
      expect(lesson.id, _replacedId);
      expect(lesson.type, PlannedElementType.lesson);
      expect(lesson.name, _ficheName);
      expect(lesson.publicInfo, '<p>Lees hoofdstuk 3.</p>');
      expect(lesson.privateInfo, '<p>Start met de quiz.</p>');
      expect(lesson.raw['goals'] as List, hasLength(2));
    });

    test('refuses an element that is not a lesson, and an empty lesfiche ID, '
        'with an ArgumentError before any request', () async {
      final (server, planner, _) = await serve({});

      expect(
        () => planner.replaceWithLessonContent(
          lesson: _listed(_slot),
          lessonContentId: _ficheId,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('planLessonContent'),
          ),
        ),
      );
      await expectLater(
        planner.replaceWithLessonContent(
          lesson: _listed(_typed),
          lessonContentId: '  ',
        ),
        throwsArgumentError,
      );
      expect(server.moduleLog, isEmpty);
    });

    group('refuses before anything is sent', () {
      test('a lesfiche that is not among the lesfiches, before the lesson '
          'is read', () async {
        const unknown = 'b0000000-0000-4000-8000-000000000099';
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
        });

        await expectLater(
          planner.replaceWithLessonContent(
            lesson: _listed(_typed),
            lessonContentId: unknown,
          ),
          throwsA(
            _refusedBy(
              op,
              reason: PlannerWriteRefusalReason.unknownLessonContent,
              element: isNull,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches]);
      });

      test('an assignment lesfiche, with the lesfiche', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
        });

        await expectLater(
          planner.replaceWithLessonContent(
            lesson: _listed(_typed),
            lessonContentId: _assignmentFicheId,
          ),
          throwsA(
            _refusedBy(
              op,
              reason: PlannerWriteRefusalReason.notALessonLessonContent,
              element: isNull,
              lessonContent: _assignmentFicheId,
            ),
          ),
        );
        expect(server.moduleLog, [_readFiches]);
      });

      for (final (name, change, reason, flags) in [
        (
          "a colleague's lesson",
          (Map<String, dynamic> lesson) => lesson['organisers'] = {
            'users': [_colleague],
            'groups': <Object>[],
          },
          PlannerWriteRefusalReason.notOwn,
          isEmpty,
        ),
        (
          'a lesson the planner does not let the user replace',
          (Map<String, dynamic> lesson) =>
              (lesson['capabilities'] as Map)['canUserReplace'] = false,
          PlannerWriteRefusalReason.notAllowed,
          ['canUserReplace'],
        ),
        (
          'a lesson that is no longer in the period it was read with',
          (Map<String, dynamic> lesson) =>
              lesson['period'] = _period('12:00', '12:50'),
          PlannerWriteRefusalReason.periodChanged,
          isEmpty,
        ),
      ]) {
        test(name, () async {
          final now = jsonDecode(_typed) as Map<String, dynamic>;
          change(now);
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readTyped: [_json(jsonEncode(now))],
          });

          await expectLater(
            planner.replaceWithLessonContent(
              lesson: _listed(_typed),
              lessonContentId: _ficheId,
            ),
            throwsA(
              _refusedBy(op, reason: reason, element: _typedId, flags: flags),
            ),
          );
          expect(server.moduleLog, [_readFiches, _readTyped]);
        });
      }

      test(
        'a lesson the planner no longer has (replaced or cleared since)',
        () async {
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readTyped: [_json(_notFound, status: 404)],
          });

          await expectLater(
            planner.replaceWithLessonContent(
              lesson: _listed(_typed),
              lessonContentId: _ficheId,
            ),
            throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
          );
          expect(server.moduleLog, [_readFiches, _readTyped]);
        },
      );
    });

    group('an answer that does not confirm the replace is unconfirmed, and '
        'the replace is not sent again:', () {
      for (final (name, answer, message) in [
        (
          'the old lesson, as it was',
          _json(_typed, status: 201),
          contains('instead of "$_ficheName"'),
        ),
        (
          'a lesson in another hour',
          _json(
            _with(_replaced, changes: {'period': _period('12:00', '12:50')}),
            status: 201,
          ),
          contains('another period'),
        ),
        (
          'an error',
          _json('{"status":400,"title":"Bad Request"}', status: 400),
          contains('HTTP 400'),
        ),
      ]) {
        test(name, () async {
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readTyped: [_json(_typed)],
            _replace: [answer],
          });

          await expectLater(
            planner.replaceWithLessonContent(
              lesson: _listed(_typed),
              lessonContentId: _ficheId,
            ),
            throwsA(_unconfirmedBy(op, message)),
          );
          expect(server.moduleLog.where((l) => l == _replace), hasLength(1));
        });
      }

      test('the connection drops after the replace went out', () async {
        final (server, planner, _) = await serve(
          {
            _readFiches: [_json(_fiches)],
            _readTyped: [_json(_typed)],
          },
          failures: {_replace: _dropped},
        );

        await expectLater(
          planner.replaceWithLessonContent(
            lesson: _listed(_typed),
            lessonContentId: _ficheId,
          ),
          throwsA(_unconfirmedBy(op, contains('no answer came in'))),
        );
        expect(server.moduleLog.where((l) => l == _replace), hasLength(1));
      });
    });
  });

  group('PlannerService.planLessonContentInto (#224)', () {
    const op = 'planLessonContentInto';

    test('reads the lesfiches and every target again, sends the bulk plan '
        'once with waitForRefresh, and returns each target with the new '
        'lesson read in full, matched by its hour', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot2: [_json(_slot2)],
        _readTyped: [_json(_typed)],
        // In another order than the targets: matched by the hour.
        _bulk: [
          _json(
            _bulkAnswer([
              _short(_bulkTypedLessonId, '11:10', '12:00'),
              _short(_bulkSlotLessonId, '12:00', '12:50'),
            ]),
          ),
        ],
        _readNewLesson(_bulkTypedLessonId): [_json(_bulkTypedLesson)],
        _readNewLesson(_bulkSlotLessonId): [_json(_bulkSlotLesson)],
      });

      final result = await planner.planLessonContentInto(
        lessonContentId: _ficheId,
        targets: [_listed(_slot2), _listed(_typed)],
      );

      expect(server.moduleLog, [
        _readFiches,
        _readSlot2,
        _readTyped,
        _bulk,
        _readNewLesson(_bulkTypedLessonId),
        _readNewLesson(_bulkSlotLessonId),
      ]);
      expect(
        server.bodyOf(_bulk),
        _bulkBody([
          (_slot2Id, 'planned-placeholders'),
          (_typedId, 'planned-lessons'),
        ]),
      );
      expect(
        server.requests.singleWhere((r) => r.label == _bulk).query,
        'waitForRefresh=true',
      );

      expect(result.allPlanned, isTrue);
      expect(result.failed, isEmpty);
      expect(result.outcomes.map((o) => o.target.id), [_slot2Id, _typedId]);
      expect(result.lessons.map((l) => l.id), [
        _bulkSlotLessonId,
        _bulkTypedLessonId,
      ]);
      for (final lesson in result.lessons) {
        expect(lesson.name, _ficheName);
        expect(lesson.type, PlannedElementType.lesson);
        // The detail, not the short element: the info is there.
        expect(lesson.publicInfo, '');
        expect(lesson.raw['goals'] as List, hasLength(2));
      }
      expect(result.outcomes.every((o) => o.exception == null), isTrue);
    });

    test('a target with an exception is reported with it, not retried, and '
        'the others are planned', () async {
      final exception = {'message': 'Element kon niet vervangen worden.'};
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot2: [_json(_slot2)],
        _readTyped: [_json(_typed)],
        _bulk: [
          _json(
            _bulkAnswer(
              [_short(_bulkSlotLessonId, '12:00', '12:50')],
              {'4069_$_typedId': exception},
            ),
          ),
        ],
        _readNewLesson(_bulkSlotLessonId): [_json(_bulkSlotLesson)],
      });

      final result = await planner.planLessonContentInto(
        lessonContentId: _ficheId,
        targets: [_listed(_slot2), _listed(_typed)],
      );

      expect(server.moduleLog.where((l) => l == _bulk), hasLength(1));
      expect(result.allPlanned, isFalse);
      expect(result.lessons.map((l) => l.id), [_bulkSlotLessonId]);
      expect(result.failed.single.target.id, _typedId);
      expect(result.failed.single.exception, exception);
      expect(result.failed.single.lesson, isNull);
      expect(result.outcomes.first.isPlanned, isTrue);
    });

    test('refuses an empty list, an element that is neither an hour nor a '
        'lesson, the same target twice and an empty lesfiche ID, with an '
        'ArgumentError before any request', () async {
      final (server, planner, _) = await serve({});
      final assignment = _listed(
        _with(_planned, changes: {'plannedElementType': 'planned-assignments'}),
      );

      for (final (targets, id) in [
        (<PlannedElement>[], _ficheId),
        ([_listed(_slot2), assignment], _ficheId),
        ([_listed(_slot2), _listed(_slot2)], _ficheId),
        ([_listed(_slot2)], ' '),
      ]) {
        await expectLater(
          planner.planLessonContentInto(lessonContentId: id, targets: targets),
          throwsArgumentError,
        );
      }
      expect(server.moduleLog, isEmpty);
    });

    test('a target that fails a check refuses the whole plan: nothing is '
        'sent', () async {
      final colleagues = jsonDecode(_typed) as Map<String, dynamic>;
      colleagues['organisers'] = {
        'users': [_colleague],
        'groups': <Object>[],
      };
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
        _readSlot2: [_json(_slot2)],
        _readTyped: [_json(jsonEncode(colleagues))],
      });

      await expectLater(
        planner.planLessonContentInto(
          lessonContentId: _ficheId,
          targets: [_listed(_slot2), _listed(_typed)],
        ),
        throwsA(
          _refusedBy(
            op,
            reason: PlannerWriteRefusalReason.notOwn,
            element: _typedId,
          ),
        ),
      );
      expect(server.moduleLog, [_readFiches, _readSlot2, _readTyped]);
    });

    test('an assignment lesfiche is refused before a target is read', () async {
      final (server, planner, _) = await serve({
        _readFiches: [_json(_fiches)],
      });

      await expectLater(
        planner.planLessonContentInto(
          lessonContentId: _assignmentFicheId,
          targets: [_listed(_slot2)],
        ),
        throwsA(
          _refusedBy(
            op,
            reason: PlannerWriteRefusalReason.notALessonLessonContent,
            element: isNull,
            lessonContent: _assignmentFicheId,
          ),
        ),
      );
      expect(server.moduleLog, [_readFiches]);
    });

    group('an answer that does not account for the targets is unconfirmed, '
        'and the plan is not sent again:', () {
      for (final (name, answer, message) in [
        (
          'too few elements',
          _json(_bulkAnswer([_short(_bulkSlotLessonId, '12:00', '12:50')])),
          contains('1 planned element and 0 exceptions for 2 targets'),
        ),
        (
          'an exception for an element that is not a target',
          _json(
            _bulkAnswer(
              [_short(_bulkSlotLessonId, '12:00', '12:50')],
              {'4069_e0000000-0000-4000-8000-000000000099': 'x'},
            ),
          ),
          contains('none of the targets'),
        ),
        (
          'exceptions as a text',
          _json(jsonEncode({'plannedElements': <Object>[], 'exceptions': 'x'})),
          contains('cannot be used'),
        ),
        (
          'an element of another type',
          _json(
            _bulkAnswer([
              {
                ..._short(_bulkSlotLessonId, '12:00', '12:50'),
                'plannedElementType': 'planned-placeholders',
              },
              _short(_bulkTypedLessonId, '11:10', '12:00'),
            ]),
          ),
          contains('instead of a lesson'),
        ),
        (
          'the 400 of a body the planner does not take',
          _json(
            '{"status":400,"title":"Bad Request","detail":"","type":""}',
            status: 400,
          ),
          contains('HTTP 400'),
        ),
      ]) {
        test(name, () async {
          final (server, planner, _) = await serve({
            _readFiches: [_json(_fiches)],
            _readSlot2: [_json(_slot2)],
            _readTyped: [_json(_typed)],
            _bulk: [answer],
            _readNewLesson(_bulkSlotLessonId): [_json(_bulkSlotLesson)],
            _readNewLesson(_bulkTypedLessonId): [_json(_bulkTypedLesson)],
          });

          await expectLater(
            planner.planLessonContentInto(
              lessonContentId: _ficheId,
              targets: [_listed(_slot2), _listed(_typed)],
            ),
            throwsA(_unconfirmedBy(op, message)),
          );
          expect(server.moduleLog.where((l) => l == _bulk), hasLength(1));
        });
      }

      test('a new lesson in none of the hours of the targets', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot2: [_json(_slot2)],
          _bulk: [
            _json(_bulkAnswer([_short(_bulkTypedLessonId, '11:10', '12:00')])),
          ],
          _readNewLesson(_bulkTypedLessonId): [_json(_bulkTypedLesson)],
        });

        await expectLater(
          planner.planLessonContentInto(
            lessonContentId: _ficheId,
            targets: [_listed(_slot2)],
          ),
          throwsA(_unconfirmedBy(op, contains('in none of the hours'))),
        );
        expect(server.moduleLog.where((l) => l == _bulk), hasLength(1));
      });

      test('a new lesson that cannot be read', () async {
        final (_, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot2: [_json(_slot2)],
          _bulk: [
            _json(_bulkAnswer([_short(_bulkSlotLessonId, '12:00', '12:50')])),
          ],
          _readNewLesson(_bulkSlotLessonId): [_json(_notFound, status: 404)],
        });

        await expectLater(
          planner.planLessonContentInto(
            lessonContentId: _ficheId,
            targets: [_listed(_slot2)],
          ),
          throwsA(_unconfirmedBy(op, contains('reading the new lesson'))),
        );
      });

      test('a session refused for the plan is not retried after logging in '
          'again', () async {
        final (server, planner, _) = await serve({
          _readFiches: [_json(_fiches)],
          _readSlot2: [_json(_slot2)],
          _bulk: [_toLogin],
        });

        await expectLater(
          planner.planLessonContentInto(
            lessonContentId: _ficheId,
            targets: [_listed(_slot2)],
          ),
          throwsA(isA<SmartschoolSessionExpiredError>()),
        );
        expect(server.log, isNot(contains('GET /login')));
        expect(server.moduleLog.where((l) => l == _bulk), hasLength(1));
      });
    });
  });

  test('the flow of #224 against a planner that keeps its state: replace '
      'a lesson typed in by hand by a lesfiche, then plan the lesfiche into '
      'that new lesson and an empty hour at once, and find both hours '
      'holding new lessons named after the lesfiche', () async {
    // The planner's elements by ID; a replace or a bulk plan takes the
    // target (its detail is 404) and makes a new lesson in its hour.
    final elements = <String, Map<String, dynamic>>{
      _typedId: jsonDecode(_typed) as Map<String, dynamic>,
      _slot2Id: jsonDecode(_slot2) as Map<String, dynamic>,
    };
    var next = 30;
    Map<String, dynamic> newLessonIn(Map<String, dynamic> target) {
      final id = 'e0000000-0000-4000-8000-0000000000${next++}';
      final lesson = jsonDecode(_planned) as Map<String, dynamic>
        ..['id'] = id
        ..['period'] = target['period'];
      elements.remove(target['id']);
      return elements[id] = lesson;
    }

    _Answer? planner(String label, Object? body) {
      if (label == _readFiches) return _json(_fiches);
      if (label == 'GET $_ownWeekPath') {
        return _json(jsonEncode(elements.values.toList()));
      }
      final read = RegExp(
        r'^GET /planner/api/v1/(planned-[a-z-]+)/4069/([0-9a-f-]+)$',
      ).firstMatch(label);
      if (read != null) {
        final element = elements[read[2]];
        return element == null || element['plannedElementType'] != read[1]
            ? _json(_notFound, status: 404)
            : _json(jsonEncode(element));
      }
      final replace = RegExp(
        r'^POST /planner/api/v1/planned-lessons/replace/planned-lessons/4069/'
        r'([0-9a-f-]+)$',
      ).firstMatch(label);
      if (replace != null) {
        expect((body! as Map)['sourceId'], _ficheId);
        return _json(
          jsonEncode(newLessonIn(elements[replace[1]]!)),
          status: 201,
        );
      }
      if (label == _bulk) {
        final targets = (body! as Map)['plannedElements'] as List;
        final made = [
          for (final target in targets)
            newLessonIn(elements[(target as Map)['plannedElementId']]!),
        ];
        return _json(
          _bulkAnswer([
            for (final lesson in made)
              {
                'id': lesson['id'],
                'platformId': 4069,
                'name': lesson['name'],
                'period': lesson['period'],
                'plannedElementType': 'planned-lessons',
                'publicInfo': null,
              },
          ]),
        );
      }
      return null;
    }

    final (server, service, client) = await serve({}, respond: planner);
    final fiche = (await LessonContentService(
      client,
    ).getItems()).singleWhere((f) => f.type == LessonContentType.lesson);
    Future<List<PlannedElement>> week() async => service.getPlannedElements(
      await service.ownCalendar(),
      from: DateTime.utc(2026, 11, 16),
      to: DateTime.utc(2026, 11, 20, 22, 59, 59),
    );

    final typed = (await week()).singleWhere(
      (e) => e.type == PlannedElementType.lesson,
    );
    expect(typed.name, isNot(fiche.name));

    final replaced = await service.replaceWithLessonContent(
      lesson: typed,
      lessonContentId: fiche.id,
    );
    expect(replaced.id, isNot(typed.id));
    expect(replaced.name, fiche.name);
    await expectLater(
      service.getDetail(typed),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );

    final hour = (await week()).singleWhere(
      (e) => e.type == PlannedElementType.placeholder,
    );
    final result = await service.planLessonContentInto(
      lessonContentId: fiche.id,
      targets: [replaced, hour],
    );
    expect(result.allPlanned, isTrue);
    expect(result.outcomes.map((o) => o.target.id), [replaced.id, hour.id]);

    final after = await week();
    expect(after.map((e) => e.type), everyElement(PlannedElementType.lesson));
    expect(after.map((e) => e.name), everyElement(fiche.name));
    expect(
      after.map((e) => e.id).toSet(),
      result.lessons.map((l) => l.id).toSet(),
    );
    expect(server.moduleLog.where((l) => l.startsWith('POST')), [
      'POST $_api/planned-lessons/replace/planned-lessons/4069/$_typedId',
      _bulk,
    ]);
  });

  group('PlannerService.parseBulkAnswer (#224)', () {
    test('no exceptions as an empty list, a missing or null field, and '
        'exceptions as an object by target', () {
      for (final exceptions in [<Object>[], null, 'missing']) {
        final answer = PlannerService.parseBulkAnswer({
          'plannedElements': [_short(_bulkSlotLessonId, '12:00', '12:50')],
          if (exceptions != 'missing') 'exceptions': exceptions,
        });
        expect(answer.planned.single['id'], _bulkSlotLessonId);
        expect(answer.failed, isEmpty, reason: '$exceptions');
      }
      final failed = PlannerService.parseBulkAnswer({
        'plannedElements': <Object>[],
        'exceptions': {
          '4069_$_typedId': {'message': 'x'},
        },
      }).failed;
      expect(failed, {
        '4069_$_typedId': {'message': 'x'},
      });
    });

    test('an answer in another shape is a SmartschoolPlannerError', () {
      for (final json in [
        <Object>[],
        <String, Object?>{},
        {'plannedElements': 'x'},
        {
          'plannedElements': ['x'],
        },
        {
          'plannedElements': <Object>[],
          'exceptions': ['x'],
        },
      ]) {
        expect(
          () => PlannerService.parseBulkAnswer(json),
          throwsA(isA<SmartschoolPlannerError>()),
          reason: '$json',
        );
      }
    });
  });
}

// -----------------------------------------------------------------------------
// #225: save an own lesson as a new lesfiche ("Opslaan in Lesfiches")
// -----------------------------------------------------------------------------
//
// Tried live on 2026-11-01 (the developer's own planner, cleared again; the
// lesfiche moved to the trash): `POST planned-lessons/{platformId}/{id}/
// save-in-source-module` with `{"newName"}` -> 200 with `{}`. The answer
// does not name the lesfiche: there was exactly one new one in the list, a
// lesson lesfiche named `newName` with the lesson's info, goals and icon;
// the lesson was unchanged. The answers below are made from the ones above,
// in that shape.

/// The lesfiche the save of [_typed] makes.
const _savedFicheId = 'b0000000-0000-4000-8000-000000000003';
const _savedName = 'Lussen: for en while';

const _savePath = '$_typedPath/save-in-source-module';
const _save = 'POST $_savePath';
const _readSavedFiche = 'GET /lesson-content/api/v1/lessons/$_savedFicheId';

/// The new lesfiche as the module lists it, named [name], with [id].
Map<String, dynamic> _savedItem({
  String id = _savedFicheId,
  String name = _savedName,
  String type = 'lessons',
}) => (jsonDecode(_fiches) as List).first as Map<String, dynamic>
  ..['id'] = id
  ..['name'] = name
  ..['type'] = type
  ..['isVisible'] = true
  ..['labels'] = <Object>[]
  ..['publicInfo'] = '<p>Breng je laptop mee.</p>';

/// [_fiches] with [added] after them.
String _fichesPlus(List<Map<String, dynamic>> added) =>
    jsonEncode([...(jsonDecode(_fiches) as List), ...added]);

/// The new lesfiche's detail: the lesson's info and goals.
final _savedDetail = jsonEncode(
  _savedItem()
    ..['privateInfo'] = '<p>Oefening 3 overslaan.</p>'
    ..['goals'] = [
      {
        'id': '90000000-0000-4000-8000-000000000001',
        'goalId': '90000000-0000-4000-8000-000000000001',
        'leerplanId': '90000000-0000-4000-8000-000000000010',
        'type': 'llinkid',
      },
    ],
);

void _issue225(
  Future<(_Smartschool, PlannerService, SmartschoolClient)> Function(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures,
    _Answer? Function(String label, Object? body)? respond,
  })
  serve,
) {
  group('PlannerService.saveAsLessonContent (#225)', () {
    const op = 'saveAsLessonContent';

    test('reads the lesson and the lesfiches, sends the save once with '
        '{"newName"} (the lesson\'s name), and returns the one new lesson '
        'lesfiche of that name, read in full', () async {
      final (server, planner, _) = await serve({
        _readTyped: [_json(_typed)],
        _readFiches: [
          _json(_fiches),
          _json(_fichesPlus([_savedItem()])),
        ],
        _save: [_json('{}')],
        _readSavedFiche: [_json(_savedDetail)],
      });

      final fiche = await planner.saveAsLessonContent(_listed(_typed));

      expect(server.moduleLog, [
        _readTyped,
        _readFiches,
        _save,
        _readFiches,
        _readSavedFiche,
      ]);
      expect(server.bodyOf(_save), {'newName': _savedName});
      expect(fiche.id, _savedFicheId);
      expect(fiche.type, LessonContentType.lesson);
      expect(fiche.name, _savedName);
      expect(fiche.privateInfo, '<p>Oefening 3 overslaan.</p>');
      expect(fiche.goals.map((g) => g.id), [
        '90000000-0000-4000-8000-000000000001',
      ]);
      // The courses are named, as getDetail names them.
      expect(fiche.courses.single.name, 'informatica');
    });

    test('a name of its own, sent without the white space around it; a '
        'lesfiche of that name already there is no matter: the new ID '
        'is', () async {
      const name = 'Herhaling: lussen'; // the name of lesfiche _ficheId
      final (server, planner, _) = await serve({
        _readTyped: [_json(_typed)],
        _readFiches: [
          _json(_fiches),
          _json(_fichesPlus([_savedItem(name: name)])),
        ],
        _save: [_json('{}')],
        _readSavedFiche: [
          _json(
            jsonEncode(
              (jsonDecode(_savedDetail) as Map<String, dynamic>)
                ..['name'] = name,
            ),
          ),
        ],
      });

      final fiche = await planner.saveAsLessonContent(
        _listed(_typed),
        name: '  $name\n',
      );

      expect(server.bodyOf(_save), {'newName': name});
      expect(fiche.id, _savedFicheId);
      expect(fiche.name, name);
    });

    test('an element that is not a lesson, or an empty name: an '
        'ArgumentError before any request', () async {
      final (server, planner, _) = await serve({});

      expect(
        () => planner.saveAsLessonContent(_listed(_slot)),
        throwsArgumentError,
      );
      expect(
        () => planner.saveAsLessonContent(_listed(_typed), name: ' \t'),
        throwsArgumentError,
      );
      expect(server.moduleLog, isEmpty);
    });

    test(
      'no name given and a lesson without one: an ArgumentError after '
      'reading it, before the lesfiches are read or anything is sent',
      () async {
        final unnamed = _with(_typed, changes: {'name': null});
        final (server, planner, _) = await serve({
          _readTyped: [_json(unnamed)],
        });

        await expectLater(
          planner.saveAsLessonContent(_listed(_typed)),
          throwsArgumentError,
        );
        expect(server.moduleLog, [_readTyped]);
      },
    );

    test("a colleague's lesson: notOwn, nothing read of the lesfiches, "
        'nothing sent', () async {
      final colleagues = _with(
        _typed,
        changes: {
          'organisers': {
            'users': [_colleague],
            'groups': <Object>[],
          },
        },
      );
      final (server, planner, _) = await serve({
        _readTyped: [_json(colleagues)],
      });

      await expectLater(
        planner.saveAsLessonContent(_listed(_typed)),
        throwsA(
          _refusedBy(
            op,
            reason: PlannerWriteRefusalReason.notOwn,
            element: _typedId,
          ),
        ),
      );
      expect(server.moduleLog, [_readTyped]);
    });

    test('a lesson without canUserSaveInSourceModule: notAllowed, with the '
        'flag', () async {
      final (server, planner, _) = await serve({
        _readTyped: [
          _json(
            _with(_typed, capabilities: {'canUserSaveInSourceModule': false}),
          ),
        ],
      });

      await expectLater(
        planner.saveAsLessonContent(_listed(_typed)),
        throwsA(
          _refusedBy(
            op,
            reason: PlannerWriteRefusalReason.notAllowed,
            element: _typedId,
            flags: ['canUserSaveInSourceModule'],
          ),
        ),
      );
      expect(server.moduleLog, [_readTyped]);
    });

    test('a lesson that is gone: SmartschoolPlannedElementNotFoundError, '
        'nothing sent', () async {
      final (server, planner, _) = await serve({
        _readTyped: [_json(_notFound, status: 404)],
      });

      await expectLater(
        planner.saveAsLessonContent(_listed(_typed)),
        throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
      );
      expect(server.moduleLog, [_readTyped]);
    });

    test('lesfiches that cannot be read first: the '
        'SmartschoolLessonContentError of getItems, nothing sent', () async {
      final (server, planner, _) = await serve({
        _readTyped: [_json(_typed)],
        _readFiches: [_json(_errorPage)],
      });

      await expectLater(
        planner.saveAsLessonContent(_listed(_typed)),
        throwsA(isA<SmartschoolLessonContentError>()),
      );
      expect(server.moduleLog, [_readTyped, _readFiches]);
    });

    group('sent, but not confirmed:', () {
      Future<void> expectUnconfirmed(
        Map<String, List<_Answer>> answers,
        Object? message, {
        Map<String, Object Function(RequestOptions options)> failures =
            const {},
        Object? statusCode = anything,
        Object? cause = anything,
      }) async {
        final (server, planner, _) = await serve({
          _readTyped: [_json(_typed)],
          ...answers,
        }, failures: failures);
        await expectLater(
          planner.saveAsLessonContent(_listed(_typed)),
          throwsA(
            allOf(
              _unconfirmedBy(op, message),
              isA<SmartschoolPlannerSaveUnconfirmedError>()
                  .having((e) => e.message, 'message', contains('getItems'))
                  .having((e) => e.statusCode, 'statusCode', statusCode)
                  .having((e) => e.cause, 'cause', cause),
            ),
          ),
        );
        // Sent once, whatever came of it.
        expect(server.moduleLog.where((l) => l == _save), hasLength(1));
      }

      test('no new lesfiche in the list', () async {
        await expectUnconfirmed({
          _readFiches: [_json(_fiches)],
          _save: [_json('{}')],
        }, contains('no new lesson lesfiche of that name (0 new lesfiches)'));
      });

      test('a new lesfiche of another name, or an assignment one', () async {
        await expectUnconfirmed({
          _readFiches: [
            _json(_fiches),
            _json(
              _fichesPlus([
                _savedItem(name: 'iets anders'),
                _savedItem(
                  id: 'b0000000-0000-4000-8000-000000000004',
                  type: 'assignments',
                ),
              ]),
            ),
          ],
          _save: [_json('{}')],
        }, contains('(2 new lesfiches)'));
      });

      test('two new lesson lesfiches of that name', () async {
        await expectUnconfirmed(
          {
            _readFiches: [
              _json(_fiches),
              _json(
                _fichesPlus([
                  _savedItem(),
                  _savedItem(id: 'b0000000-0000-4000-8000-000000000004'),
                ]),
              ),
            ],
            _save: [_json('{}')],
          },
          allOf(
            contains('2 new lesson lesfiches of that name'),
            contains(_savedFicheId),
          ),
        );
      });

      test('another status than 200, with nothing new: the status', () async {
        await expectUnconfirmed(
          {
            _readFiches: [_json(_fiches)],
            _save: [_json('{"status":400,"title":"Bad Request"}', status: 400)],
          },
          contains('HTTP 400'),
          statusCode: 400,
        );
      });

      test('the lesfiches cannot be read again', () async {
        await expectUnconfirmed(
          {
            _readFiches: [_json(_fiches), _json(_errorPage)],
            _save: [_json('{}')],
          },
          contains('reading the lesfiches again failed'),
          cause: isA<SmartschoolLessonContentError>(),
        );
      });

      test('the new lesfiche\'s detail cannot be read', () async {
        await expectUnconfirmed(
          {
            _readFiches: [
              _json(_fiches),
              _json(_fichesPlus([_savedItem()])),
            ],
            _save: [_json('{}')],
            _readSavedFiche: [_json(_errorPage)],
          },
          contains('reading the detail of lesfiche $_savedFicheId'),
          cause: isA<SmartschoolLessonContentError>(),
        );
      });

      test('no answer: the connection drops after the save went out', () async {
        await expectUnconfirmed(
          {
            _readFiches: [_json(_fiches)],
          },
          contains('no answer came in'),
          failures: {_save: _dropped},
          statusCode: isNull,
          cause: isNotNull,
        );
      });
    });

    test('a session refused for the save is not retried after logging in '
        'again: no login, no second save', () async {
      final (server, planner, _) = await serve({
        _readTyped: [_json(_typed)],
        _readFiches: [_json(_fiches)],
        _save: [_toLogin, _json('{}')],
      });

      await expectLater(
        planner.saveAsLessonContent(_listed(_typed)),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.moduleLog.where((l) => l == _save), hasLength(1));
    });
  });

  test('the flow of #225 against a planner and a library that keep their '
      'state: find a lesson typed in by hand in the own week, save it as a '
      'lesfiche, find the lesfiche in the library, plan it into an empty '
      'hour, and find the typed lesson as it was', () async {
    final elements = <String, Map<String, dynamic>>{
      _typedId: jsonDecode(_typed) as Map<String, dynamic>,
      _slot2Id: jsonDecode(_slot2) as Map<String, dynamic>,
    };
    final library = [
      for (final item in jsonDecode(_fiches) as List)
        item as Map<String, dynamic>,
    ];
    final details = <String, Map<String, dynamic>>{};
    var nextFiche = 50;
    var nextLesson = 60;

    _Answer? smartschool(String label, Object? body) {
      if (label == _readFiches) return _json(jsonEncode(library));
      if (label == 'GET $_ownWeekPath') {
        return _json(jsonEncode(elements.values.toList()));
      }
      final ficheRead = RegExp(
        r'^GET /lesson-content/api/v1/lessons/([0-9a-f-]+)$',
      ).firstMatch(label);
      if (ficheRead != null) {
        final detail = details[ficheRead[1]];
        return detail == null
            ? _json(_notFound, status: 404)
            : _json(jsonEncode(detail));
      }
      final read = RegExp(
        r'^GET /planner/api/v1/(planned-[a-z-]+)/4069/([0-9a-f-]+)$',
      ).firstMatch(label);
      if (read != null) {
        final element = elements[read[2]];
        return element == null || element['plannedElementType'] != read[1]
            ? _json(_notFound, status: 404)
            : _json(jsonEncode(element));
      }
      final save = RegExp(
        r'^POST /planner/api/v1/planned-lessons/4069/([0-9a-f-]+)/'
        r'save-in-source-module$',
      ).firstMatch(label);
      if (save != null) {
        // The lesson's info, goals and icon, under the new name; the lesson
        // stays as it is.
        final lesson = elements[save[1]]!;
        final id = 'b0000000-0000-4000-8000-0000000000${nextFiche++}';
        final item =
            _savedItem(id: id, name: (body! as Map)['newName'] as String)
              ..['icon'] = lesson['icon']
              ..['publicInfo'] = lesson['publicInfo'];
        library.add(item);
        details[id] = {
          ...item,
          'privateInfo': lesson['privateInfo'],
          'goals': lesson['goals'],
        };
        return _json('{}');
      }
      final fill = RegExp(
        r'^POST /planner/api/v1/planned-placeholders/4069/([0-9a-f-]+)/'
        r'replace/planned-lessons$',
      ).firstMatch(label);
      if (fill != null) {
        final slot = elements.remove(fill[1])!;
        final fiche = details[(body! as Map)['sourceId']]!;
        final id = 'e0000000-0000-4000-8000-0000000000${nextLesson++}';
        final lesson = jsonDecode(_planned) as Map<String, dynamic>
          ..['id'] = id
          ..['period'] = slot['period']
          ..['name'] = fiche['name']
          ..['privateInfo'] = fiche['privateInfo']
          ..['info'] = fiche['privateInfo']
          ..['publicInfo'] = fiche['publicInfo']
          ..['goals'] = fiche['goals'];
        return _json(jsonEncode(elements[id] = lesson));
      }
      return null;
    }

    final (server, service, client) = await serve({}, respond: smartschool);
    Future<List<PlannedElement>> week() async => service.getPlannedElements(
      await service.ownCalendar(),
      from: DateTime.utc(2026, 11, 16),
      to: DateTime.utc(2026, 11, 20, 22, 59, 59),
    );
    final typed = (await week()).singleWhere(
      (e) => e.type == PlannedElementType.lesson,
    );
    final typedBefore = await service.getDetail(typed);

    final fiche = await service.saveAsLessonContent(typed);
    expect(fiche.name, typed.name);
    expect(fiche.type, LessonContentType.lesson);
    expect(fiche.privateInfo, typedBefore.privateInfo);
    expect(fiche.publicInfo, typedBefore.publicInfo);

    // The library lists it; the lesson is as it was.
    final listed = await LessonContentService(client).getItems();
    expect(listed.where((f) => f.id == fiche.id), hasLength(1));
    expect(
      jsonEncode((await service.getDetail(typed)).raw),
      jsonEncode(typedBefore.raw),
    );

    // Planned into the other hour, it brings the lesson's content along.
    final hour = (await week()).singleWhere(
      (e) => e.type == PlannedElementType.placeholder,
    );
    final planned = await service.planLessonContent(
      placeholder: hour,
      lessonContentId: fiche.id,
    );
    expect(planned.name, typed.name);
    expect(planned.privateInfo, typedBefore.privateInfo);
    expect(planned.publicInfo, typedBefore.publicInfo);

    final after = await week();
    expect(after.map((e) => e.type), everyElement(PlannedElementType.lesson));
    expect(after.map((e) => e.id), containsAll([typed.id, planned.id]));
    expect(server.moduleLog.where((l) => l.startsWith('POST')), [
      _save,
      'POST $_api/planned-placeholders/4069/$_slot2Id/replace/planned-lessons',
    ]);
  });
}
