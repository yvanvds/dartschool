// Tests for issue #89: adding an assignment (a test, a task) to the own
// planner, editing it and moving it to the planner's trash
// (`PlannerService.planAssignment`, `trashAssignment`, and the edits of #87,
// `renameElement`, `changePublicInfo`, `changePrivateInfo`, on an
// assignment).
//
// The answers below are trimmed captures of the live planner API, from the
// create, rename and trash the developer tried in their own planner (with
// permission, moved to the trash again) on 2026-10-02:
//   - POST /planner/api/v1/planned-assignments/blanco?waitForRefresh=true
//       -> 201 with the new assignment (the same body without `icon` gave
//       400, and nothing was made)
//   - POST .../planned-assignments/{platformId}/{id}/rename -> 200 with the
//       assignment
//   - POST .../planned-assignments/{platformId}/{id}/trash (no body) -> 200
//       `[]`; the assignment's detail is 404 afterwards
//   - GET  .../planned-assignments/{platformId}/{id} of a colleague's
//       assignment in a class calendar (read only)
//   - GET  /lesson-content/api/v1/assignments/applicable-assignment-types
// with every name, picture, user, group, course, type, location and element
// ID and every free text replaced by obvious fakes ("Jan Janssens" is the
// authenticated user `4069_1001_0`, "Wim Willems" a colleague, classes
// `4069_2001`/`4069_2002`, room `101`, "Springfield Academy"). The
// capabilities are trimmed to the flags that matter. The answers that the
// planner did not give live (unusable answers, an assignment with a linked
// evaluation) are made up from those.
//
// The fake Smartschool answers only the requests each test scripts (and the
// login chain), and fails the test on any other request: `DELETE`, the bulk
// endpoints (`planned-elements/trash`, `.../delete`, `.../bulk/...`, the
// period trash), `announce`, `.../trash/restore` and a second create or
// trash never get an answer.
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

const _assignmentId = 'e0000000-0000-4000-8000-000000000021';
const _otherId = 'e0000000-0000-4000-8000-000000000022';
const _slotId = 'e0000000-0000-5000-8000-000000000010';

/// Kleine Overhoring (`KO`).
const _koId = 'a0000000-0000-4000-8000-000000000001';

/// Grote Overhoring (`GO`).
const _goId = 'a0000000-0000-4000-8000-000000000002';

const _api = '/planner/api/v1';
const _createPath = '$_api/planned-assignments/blanco';
const _assignmentPath = '$_api/planned-assignments/4069/$_assignmentId';
const _otherPath = '$_api/planned-assignments/4069/$_otherId';
const _typesPath =
    '/lesson-content/api/v1/assignments/applicable-assignment-types';

/// The requests, as the fake logs them (method and path, without the
/// query).
const _create = 'POST $_createPath';
const _readTypes = 'GET $_typesPath';
const _readAssignment = 'GET $_assignmentPath';
const _rename = 'POST $_assignmentPath/rename';
const _changePublic = 'POST $_assignmentPath/change-public-info';
const _changePrivate = 'POST $_assignmentPath/change-private-info';
const _trash = 'POST $_assignmentPath/trash';
const _readOther = 'GET $_otherPath';

/// The school's assignment types, as the lesson-content API lists them.
const _types = r'''
[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Grote Taak","abbreviation":"GT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Kleine Taak","abbreviation":"KT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000005","platformId":4069,"name":"Meebrengen","abbreviation":"MB","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000006","platformId":4069,"name":"Voorbereiding","abbreviation":"V","isVisible":true,"defaultTiming":"deadline","weight":0}]
''';

/// The planner's answer to the create (`201`): the new assignment of the
/// authenticated user for 6A1 and 6A2, a Kleine Overhoring due on Friday 20
/// November 2026 at 11:10 (winter time, `+01:00`), visible to pupils from
/// its creation, not announced. The planner escapes `/` in its HTML, as here
/// (and `<` and `>` as JSON unicode escapes, which decode the same).
const _assignment = r'''
{"id":"e0000000-0000-4000-8000-000000000021","platformId":4069,"name":"Test: lussen","icon":"flags_red_yellow","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"info":"","privateInfo":"","publicInfo":"<p>Leerstof: hoofdstuk 3<\/p>","period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"uploadFolder":null,"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserTrash":true,"canUserDelete":true,"canUserEdit":true,"canUserChangeAssignmentType":true,"canUserChangePrivateInfo":true,"canUserChangePublicInfo":true,"canUserReplace":true,"canUserPin":true,"canUserResolve":true,"canUserReschedule":true,"canUserChangeOrganisers":true,"canUserChangeParticipants":true,"canUserChangeCourses":true,"canUserChangeLocations":true,"canUserAnnounce":true,"canUserRename":true,"canUserChangeIcon":true,"canUserDuplicate":false,"canUserUnlinkEvaluation":false,"canUserSeeProperties":{"id":true,"platformId":true,"name":true,"icon":true,"assignmentType":true,"info":true,"privateInfo":true,"publicInfo":true,"period":true,"organisers":true,"participants":true,"courses":true,"locations":true,"plannedElementType":true,"isAnnounced":true,"visibility":true,"hasLinkedEvaluation":true,"linkedEvaluation":true}},"resolvedStatus":"unresolved","presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-assignments","plannedToDos":[],"isAnnounced":false,"visibility":{"afterDate":"2026-10-02T16:30:00+02:00"},"canUserAccessEvaluations":true,"hasLinkedEvaluation":false,"linkedEvaluation":null,"sort":"20261120111000_5_6A1_Test: lussen","unconfirmed":false,"pinned":false,"color":"aqua-200","dateCreated":"2026-10-02T16:30:04+02:00","reminders":[],"participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000021","to":"f0000000-0000-5000-8000-000000000021"}}
''';

/// A colleague's assignment (Wim Willems) in the calendar of 6A1, as its
/// detail reads: the planner lets the user change nothing of it.
const _other = r'''
{"id":"e0000000-0000-4000-8000-000000000022","platformId":4069,"name":"Test: hoofdstuk 1 en 2","icon":"flags_red_yellow","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"info":"","privateInfo":"","publicInfo":"","period":{"dateTimeFrom":"2026-11-20T08:30:00+01:00","dateTimeTo":"2026-11-20T09:20:00+01:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"uploadFolder":null,"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Nederlands","scheduleCodes":["NEDER"],"icon":"schoolbord","courseCluster":{"id":3,"name":"Nederlands"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserAddReminder":true,"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserChangePrivateInfo":false,"canUserChangePublicInfo":false,"canUserReplace":false,"canUserReschedule":false,"canUserChangeParticipants":false,"canUserAnnounce":false,"canUserRename":false,"canUserChangeIcon":false,"canUserSendAMessageToOneOfTheOrganisers":true,"canUserLinkToDo":true,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true,"visibility":true}},"resolvedStatus":"unresolved","presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-assignments","plannedToDos":[],"isAnnounced":false,"visibility":{"afterDate":"2026-09-26T10:50:00+02:00"},"canUserAccessEvaluations":true,"hasLinkedEvaluation":false,"linkedEvaluation":null,"sort":"20261120083000_5_6A1_Test: hoofdstuk 1 en 2","unconfirmed":false,"pinned":false,"color":"aqua-200","dateCreated":"2026-09-26T10:50:52+02:00","reminders":[],"participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000022","to":"f0000000-0000-5000-8000-000000000022"}}
''';

/// The own lesson hour of that Friday 11:10 to 12:00 (a timetable slot),
/// classes 6A1 and 6A2, course informatica, room 101, as the calendar of
/// 6A1 and the own planner list it: where the assignment's classes, course,
/// room and time come from.
const _slot = r'''
{"id":"e0000000-0000-5000-8000-000000000010","platformId":4069,"period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserReplace":true,"canUserRename":false},"plannedElementType":"planned-placeholders","onlineSession":null,"sort":"20261120111000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","joinIds":{"from":"f0000000-0000-5000-8000-000000000010","to":"f0000000-0000-5000-8000-000000000011"}}
''';

/// The values the tests create the assignment with: those of [_assignment].
const _name = 'Test: lussen';
const _publicInfo = '<p>Leerstof: hoofdstuk 3</p>';

/// 11:10 and 12:00 on 20 November 2026 in Belgium (`+01:00`).
final _due = DateTime.utc(2026, 11, 20, 10, 10);
final _until = DateTime.utc(2026, 11, 20, 11);

const _course = PlannerCourse(
  id: 'c0000000-0000-4000-8000-000000000005',
  platformId: 4069,
  name: 'informatica',
);
const _room = PlannerLocation(
  id: '10000000-0000-4000-8000-000000000101',
  platformId: 4069,
  platformName: 'Springfield Academy',
  title: '101',
  type: 'mini-db-item',
);
const _ko = PlannerAssignmentType(
  id: _koId,
  platformId: 4069,
  name: 'Kleine Overhoring',
  abbreviation: 'KO',
);

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

/// [json], an element, organised by the colleague (Wim Willems) instead.
String _byColleague(String json) => _with(
  json,
  changes: {
    'organisers': (jsonDecode(_other) as Map<String, dynamic>)['organisers'],
  },
);

/// [json] as the calendar lists it (`getPlannedElements`).
PlannedElement _listed(String json) =>
    PlannerService.parsePlannedElements(jsonDecode('[$json]')).single;

/// The body the web client sends to create [_assignment] (as tried live),
/// with [name], the info texts, [type] and [icon].
Map<String, Object?> _createBody({
  String name = _name,
  String publicInfo = _publicInfo,
  String privateInfo = '',
  String type = _koId,
  String icon = 'flags_red_yellow',
  List<String> groups = const ['4069_2001', '4069_2002'],
  bool withRoom = true,
}) => {
  'organisers': {
    'users': [_me],
    'groups': <Object>[],
  },
  'participants': {
    'groups': groups,
    'users': <Object>[],
    'userRoles': <Object>[],
  },
  'courses': [
    {'platformId': 4069, 'id': 'c0000000-0000-4000-8000-000000000005'},
  ],
  'period': {
    'dateTimeFrom': PlannerService.formatDateTime(_due),
    'dateTimeTo': PlannerService.formatDateTime(_until),
    'wholeDay': false,
    'deadline': true,
    'dateTime': PlannerService.formatDateTime(_due),
  },
  'name': name,
  'info': '',
  'publicInfo': publicInfo,
  'privateInfo': privateInfo,
  'assignmentType': type,
  'icon': icon,
  'locations': [
    if (withRoom)
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

/// The planner's answer to the create without an `icon`, as seen live.
const _badRequest =
    '{"status":400,"title":"Bad Request","detail":"","type":"",'
    '"languageCode":""}';

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

/// A request as it reached the fake Smartschool: its query, its body decoded
/// when it is JSON (`null` when it has none), and its raw body.
typedef _Request = ({
  String label,
  Map<String, String> query,
  Object? body,
  String text,
  String contentType,
});

/// A Smartschool whose session is accepted, that answers the requests of
/// [answers] (by label, `METHOD path`; a list is answered in turn, its last
/// answer for every later request), the reads the client makes for the
/// authenticated user, and the login chain; and fails the test on any other
/// request.
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
  final _Answer? Function(_Request request)? respond;

  bool _passwordDone = false;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  /// The labels of [requests], in order.
  List<String> get log => [for (final r in requests) r.label];

  /// The labels of the requests to the planner and to the lesson-content
  /// API, in order.
  List<String> get apiLog => [
    for (final label in log)
      if (label.contains('/planner/') || label.contains('/lesson-content/'))
        label,
  ];

  /// The labels of the POSTs to the planner, in order.
  List<String> get plannerPosts => [
    for (final label in log)
      if (label.startsWith('POST /planner/')) label,
  ];

  /// The one request [label].
  _Request one(String label) => requests.singleWhere((r) => r.label == label);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final label = '${options.method} ${uri.path}';
    final text = await _read(requestStream);
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    final request = (
      label: label,
      query: uri.queryParameters,
      body: body,
      text: text,
      contentType: options.contentType ?? '',
    );
    requests.add(request);

    final failure = failures[label];
    if (failure != null) throw failure(options);

    switch (label) {
      case 'GET /course-list/api/v1/courses':
        return _respond(_json('[{"platformId":4069}]'));
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

    final scripted = respond?.call(request);
    if (scripted != null) return _respond(scripted);
    final queue = _answers[label];
    if (queue == null || queue.isEmpty) {
      fail('Unexpected request: ${options.method} $uri');
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

/// A check before the write refused it: nothing was sent. The error gives
/// the check as [reason] (#100), with the ID of the [element] it read again
/// (`null` for a new assignment) and the capability [flags] it refused on.
Matcher _refused(
  Object? message, {
  required PlannerWriteRefusalReason reason,
  Object? element = anything,
  Object? flags = isEmpty,
}) => isA<SmartschoolPlannerWriteRefusedError>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.message, 'message', contains('Nothing was sent'))
    .having((e) => e.reason, 'reason', reason)
    .having((e) => e.element?.id, 'element', element)
    .having((e) => e.capabilityFlags, 'capabilityFlags', flags)
    .having((e) => e.lessonContent, 'lessonContent', isNull);

/// The write went out without the planner confirming it.
Matcher _unconfirmed(
  Object? message, {
  Object? statusCode = anything,
  Object? cause = anything,
}) => allOf(
  isNot(isA<SmartschoolPlannerError>()),
  isA<SmartschoolPlannerSaveUnconfirmedError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', contains('may or may not'))
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.cause, 'cause', cause),
);

/// A session refused for a write that is not retried.
final _notRetried = isA<SmartschoolSessionExpiredError>().having(
  (e) => e.message,
  'message',
  contains('not retried after logging in again'),
);

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService)> serve(
    Map<String, List<_Answer>> answers, {
    Map<String, Object Function(RequestOptions options)> failures = const {},
    _Answer? Function(_Request request)? respond,
  }) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers, failures: failures, respond: respond);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client));
  }

  /// [planner.planAssignment] with the values of [_assignment], and
  /// [name] and [type] when they are given.
  Future<PlannedElementDetail> plan(
    PlannerService planner, {
    String name = _name,
    PlannerAssignmentType type = _ko,
  }) => planner.planAssignment(
    groupIds: ['4069_2001', '4069_2002'],
    course: _course,
    type: type,
    name: name,
    due: _due,
    until: _until,
    publicInfo: _publicInfo,
    locations: [_room],
  );

  // ---------------------------------------------------------------------------
  // planAssignment
  // ---------------------------------------------------------------------------

  group('PlannerService.planAssignment', () {
    test('reads the user and the school\'s types, then creates the '
        'assignment once with the body the web client sends, and returns '
        'it from the 201', () async {
      final (server, planner) = await serve({
        _readTypes: [_json(_types)],
        _create: [_json(_assignment, status: 201)],
      });

      final assignment = await plan(planner);

      expect(server.log, [
        'GET /course-list/api/v1/courses',
        'GET /',
        _readTypes,
        _create,
      ]);
      final create = server.one(_create);
      // `?waitForRefresh=true`, as the web client sends it, so that the class
      // calendar shows the assignment at once.
      expect(create.query, {'waitForRefresh': 'true'});
      // A deadline period with `dateTime` = `dateTimeFrom`, the icon (the
      // planner answers 400 without it), the type as its ID, the
      // authenticated user as the only organiser, the classes as
      // participants.
      expect(create.body, _createBody());
      expect(create.contentType, contains('application/json'));

      expect(assignment, isA<PlannedElementDetail>());
      expect(assignment.id, _assignmentId);
      expect(assignment.type, PlannedElementType.assignment);
      expect(assignment.name, _name);
      expect(assignment.publicInfo, _publicInfo);
      expect(assignment.assignmentType!.id, _koId);
      expect(assignment.assignmentType!.abbreviation, 'KO');
      expect(assignment.period.deadline, isTrue);
      expect(assignment.period.from.isAtSameMomentAs(_due), isTrue);
      expect(assignment.period.to.isAtSameMomentAs(_until), isTrue);
      expect(assignment.organiserUsers.single.id, _me);
      expect(assignment.participantGroups.map((g) => g.name), ['6A1', '6A2']);
      expect(assignment.locations.single.title, '101');
      expect(assignment.icon, 'flags_red_yellow');
      // Pupils see it at once; it was not announced.
      expect(
        assignment.visibleFrom!.isAtSameMomentAs(
          DateTime.utc(2026, 10, 2, 14, 30),
        ),
        isTrue,
      );
      expect(assignment.isAnnounced, isFalse);
      expect(assignment.hasLinkedEvaluation, isFalse);
      expect(assignment.resolvedStatus, 'unresolved');
      expect(assignment.capabilities.canTrash, isTrue);
    });

    test('the period goes out as formatDateTime writes due and until: a UTC '
        'moment in UTC', () async {
      final (server, planner) = await serve({
        _readTypes: [_json(_types)],
        _create: [_json(_assignment, status: 201)],
      });

      await plan(planner);

      final period =
          (server.one(_create).body! as Map<String, dynamic>)['period'] as Map;
      expect(period['dateTimeFrom'], '2026-11-20T10:10:00+00:00');
      expect(period['dateTime'], '2026-11-20T10:10:00+00:00');
      expect(period['dateTimeTo'], '2026-11-20T11:00:00+00:00');
    });

    test('a 200 with the assignment is accepted too', () async {
      final (_, planner) = await serve({
        _readTypes: [_json(_types)],
        _create: [_json(_assignment)],
      });

      final assignment = await plan(planner);

      expect(assignment.id, _assignmentId);
    });

    test('sends the name without the white space around it, each class '
        'once, empty info, the default icon and no rooms by default, and the '
        'type as the school\'s list names it', () async {
      final (server, planner) = await serve({
        _readTypes: [_json(_types)],
        _create: [
          _json(
            _with(
              _assignment,
              changes: {'publicInfo': '', 'locations': <Object>[]},
            ),
            status: 201,
          ),
        ],
      });

      await planner.planAssignment(
        groupIds: ['4069_2001', '4069_2002', '4069_2001'],
        course: _course,
        // Only the ID matters, in any case.
        type: PlannerAssignmentType(id: _koId.toUpperCase(), name: ''),
        name: '  $_name\n',
        due: _due,
        until: _until,
      );

      expect(
        server.one(_create).body,
        _createBody(publicInfo: '', withRoom: false),
      );
      expect(PlannerService.defaultAssignmentIcon, 'flags_red_yellow');
    });

    test('the info texts and the icon asked for', () async {
      final (server, planner) = await serve({
        _readTypes: [_json(_types)],
        _create: [
          _json(
            _with(
              _assignment,
              changes: {
                'privateInfo': '<p>Versie B</p>',
                'info': '<p>Versie B</p>',
                'icon': 'book',
              },
            ),
            status: 201,
          ),
        ],
      });

      final assignment = await planner.planAssignment(
        groupIds: ['4069_2001', '4069_2002'],
        course: _course,
        type: _ko,
        name: _name,
        due: _due,
        until: _until,
        publicInfo: _publicInfo,
        privateInfo: '<p>Versie B</p>',
        icon: 'book',
        locations: [_room],
      );

      expect(
        server.one(_create).body,
        _createBody(privateInfo: '<p>Versie B</p>', icon: 'book'),
      );
      expect(assignment.privateInfo, '<p>Versie B</p>');
    });

    group('refuses before anything is sent', () {
      test('a type that is not one of the school\'s assignment types: only '
          'the types were read', () async {
        final (server, planner) = await serve({
          _readTypes: [_json(_types)],
        });

        await expectLater(
          plan(
            planner,
            type: const PlannerAssignmentType(
              id: 'a0000000-0000-4000-8000-000000000099',
              name: 'Examen',
            ),
          ),
          throwsA(
            _refused(
              allOf(
                contains('planAssignment'),
                contains('a0000000-0000-4000-8000-000000000099 "Examen"'),
                contains('not one of the school\'s 6 assignment types'),
              ),
              reason: PlannerWriteRefusalReason.unknownAssignmentType,
              // A new assignment: no element was read.
              element: isNull,
            ),
          ),
        );
        expect(server.apiLog, [_readTypes]);
      });

      test(
        'the types cannot be read: the planner error, nothing sent',
        () async {
          final (server, planner) = await serve({
            _readTypes: [_json(_errorPage, status: 500)],
          });

          await expectLater(
            plan(planner),
            throwsA(
              isA<SmartschoolPlannerError>().having(
                (e) => e.statusCode,
                'statusCode',
                500,
              ),
            ),
          );
          expect(server.apiLog, [_readTypes]);
        },
      );

      test('no class, an ID that is not a class, an empty name, icon, course '
          'or type, or an end before the deadline: an ArgumentError, before '
          'any request', () async {
        final (server, planner) = await serve({});

        Future<PlannedElementDetail> planWith({
          List<String> groupIds = const ['4069_2001'],
          PlannerCourse course = _course,
          PlannerAssignmentType type = _ko,
          String name = _name,
          String icon = 'flags_red_yellow',
          DateTime? until,
        }) => planner.planAssignment(
          groupIds: groupIds,
          course: course,
          type: type,
          name: name,
          due: _due,
          until: until ?? _until,
          icon: icon,
        );

        for (final (call, argument) in [
          (() => planWith(groupIds: []), 'groupIds'),
          (() => planWith(groupIds: ['2001']), 'groupIds'),
          (() => planWith(name: ' \n'), 'name'),
          (() => planWith(icon: ' '), 'icon'),
          (
            () => planWith(
              course: const PlannerCourse(id: ' ', platformId: 4069, name: ''),
            ),
            'course',
          ),
          (
            () => planWith(
              type: const PlannerAssignmentType(id: '', name: 'KO'),
            ),
            'type',
          ),
          (
            () => planWith(until: _due.subtract(const Duration(minutes: 1))),
            'until',
          ),
        ]) {
          await expectLater(
            call,
            throwsA(
              isA<ArgumentError>().having((e) => e.name, 'name', argument),
            ),
          );
        }
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the create is unconfirmed, and '
        'the create is not sent again', () {
      final answers = <String, (_Answer, Object?, Object?)>{
        'HTTP 400 (as without an icon)': (
          _json(_badRequest, status: 400),
          contains('HTTP 400'),
          400,
        ),
        'HTTP 500': (
          _json(_errorPage, status: 500),
          contains('cannot be used'),
          500,
        ),
        'an HTML page': (
          _json(_errorPage, status: 201),
          contains('HTML page'),
          201,
        ),
        'not an element': (
          _json('[]', status: 201),
          contains('instead of an object'),
          201,
        ),
        'a lesson': (
          _json(
            _with(
              _assignment,
              changes: {'plannedElementType': 'planned-lessons'},
            ),
            status: 201,
          ),
          contains('a planned-lessons instead of an assignment'),
          201,
        ),
        'another name': (
          _json(
            _with(_assignment, changes: {'name': 'Iets anders'}),
            status: 201,
          ),
          contains('named "Iets anders" instead of "$_name"'),
          201,
        ),
        'another type': (
          _json(
            _with(
              _assignment,
              changes: {
                'assignmentType': {'id': _goId, 'name': 'Grote Overhoring'},
              },
            ),
            status: 201,
          ),
          contains('of type $_goId "Grote Overhoring" instead of $_koId'),
          201,
        ),
        'no type': (
          _json(
            _with(_assignment, changes: {'assignmentType': null}),
            status: 201,
          ),
          contains('of type null'),
          201,
        ),
        'another deadline': (
          _json(
            _with(
              _assignment,
              changes: {
                'period': {
                  'dateTimeFrom': '2026-11-20T12:00:00+01:00',
                  'dateTimeTo': '2026-11-20T12:50:00+01:00',
                  'wholeDay': false,
                  'deadline': true,
                },
              },
            ),
            status: 201,
          ),
          contains('an assignment due at'),
          201,
        ),
        'not a deadline': (
          _json(
            _with(
              _assignment,
              changes: {
                'period': {
                  'dateTimeFrom': '2026-11-20T11:10:00+01:00',
                  'dateTimeTo': '2026-11-20T12:00:00+01:00',
                  'wholeDay': false,
                  'deadline': false,
                },
              },
            ),
            status: 201,
          ),
          contains('not a deadline'),
          201,
        ),
        "a colleague's assignment": (
          _json(_byColleague(_assignment), status: 201),
          contains('not organised by $_me'),
          201,
        ),
      };
      for (final MapEntry(key: name, value: (answer, message, status))
          in answers.entries) {
        test(name, () async {
          final (server, planner) = await serve({
            _readTypes: [_json(_types)],
            _create: [answer],
          });

          await expectLater(
            plan(planner),
            throwsA(
              _unconfirmed(
                allOf(
                  contains('planAssignment'),
                  contains('the creation of assignment "$_name"'),
                  message,
                  contains('look for it in the calendar of one of its classes'),
                ),
                statusCode: status,
              ),
            ),
          );
          expect(server.plannerPosts, [_create]);
        });
      }

      test('the connection drops after the create went out', () async {
        final (server, planner) = await serve(
          {
            _readTypes: [_json(_types)],
          },
          failures: {_create: _dropped},
        );

        await expectLater(
          plan(planner),
          throwsA(
            _unconfirmed(
              contains('no answer came in'),
              statusCode: isNull,
              cause: isA<SmartschoolConnectionError>(),
            ),
          ),
        );
        expect(server.plannerPosts, [_create]);
      });

      test('a session refused for the create is not retried after logging in '
          'again: no login, no second create', () async {
        final (server, planner) = await serve({
          _readTypes: [_json(_types)],
          _create: [_toLogin, _json(_assignment, status: 201)],
        });

        await expectLater(plan(planner), throwsA(_notRetried));
        expect(server.log, isNot(contains('GET /login')));
        expect(server.plannerPosts, [_create]);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // The edits of #87 on an assignment
  // ---------------------------------------------------------------------------

  group('the edits on an assignment', () {
    test('renameElement reads the assignment again and sends its new name to '
        'planned-assignments/{platformId}/{id}/rename', () async {
      const newName = 'Test: lussen (hernoemd)';
      final (server, planner) = await serve({
        _readAssignment: [_json(_assignment)],
        _rename: [
          _json(_with(_assignment, changes: {'name': newName})),
        ],
      });

      final renamed = await planner.renameElement(
        _listed(_assignment),
        ' $newName ',
      );

      expect(server.apiLog, [_readAssignment, _rename]);
      expect(server.one(_rename).body, {'newName': newName});
      expect(renamed.type, PlannedElementType.assignment);
      expect(renamed.name, newName);
      expect(renamed.assignmentType!.id, _koId);
    });

    test('changePublicInfo and changePrivateInfo send the HTML as given, to '
        'the assignment\'s own routes', () async {
      const public = '<p>Leerstof: hoofdstuk 3 en 4</p>';
      const private = '<p>Versie B voor 6A2</p>';
      final (server, planner) = await serve({
        _readAssignment: [_json(_assignment)],
        _changePublic: [
          _json(_with(_assignment, changes: {'publicInfo': public})),
        ],
        _changePrivate: [
          _json(
            _with(
              _assignment,
              changes: {'privateInfo': private, 'info': private},
            ),
          ),
        ],
      });

      final informed = await planner.changePublicInfo(
        _listed(_assignment),
        public,
      );
      final noted = await planner.changePrivateInfo(
        _listed(_assignment),
        private,
      );

      expect(server.apiLog, [
        _readAssignment,
        _changePublic,
        _readAssignment,
        _changePrivate,
      ]);
      expect(server.one(_changePublic).body, {'newInfo': public});
      expect(server.one(_changePrivate).body, {'newInfo': private});
      expect(informed.publicInfo, public);
      expect(noted.privateInfo, private);
    });

    group("a colleague's assignment is refused before anything is sent", () {
      final edits =
          <String, Future<Object?> Function(PlannerService, PlannedElement)>{
            'renameElement': (p, e) => p.renameElement(e, 'Nieuw'),
            'changePublicInfo': (p, e) => p.changePublicInfo(e, '<p>X</p>'),
            'changePrivateInfo': (p, e) => p.changePrivateInfo(e, '<p>X</p>'),
            'trashAssignment': (p, e) => p.trashAssignment(e),
          };
      for (final MapEntry(key: name, value: edit) in edits.entries) {
        test('$name: as read in a class calendar', () async {
          final (server, planner) = await serve({
            _readOther: [_json(_other)],
          });

          await expectLater(
            edit(planner, _listed(_other)),
            throwsA(
              allOf(
                _refused(
                  allOf(
                    contains(name),
                    contains('not in your own planner'),
                    contains('Wim Willems (4069_1003_0)'),
                  ),
                  reason: PlannerWriteRefusalReason.notOwn,
                  element: _otherId,
                ),
                // The colleague's test as read again, with its organiser.
                isA<SmartschoolPlannerWriteRefusedError>().having(
                  (e) => e.element!.organiserUsers.map((u) => u.name),
                  'organisers',
                  ['Wim Willems'],
                ),
              ),
            ),
          );
          expect(server.apiLog, [_readOther]);
        });

        test('$name: even one the planner lets the user change', () async {
          final (server, planner) = await serve({
            _readAssignment: [_json(_byColleague(_assignment))],
          });

          await expectLater(
            edit(planner, _listed(_assignment)),
            throwsA(
              _refused(
                contains('not in your own planner'),
                reason: PlannerWriteRefusalReason.notOwn,
                element: _assignmentId,
              ),
            ),
          );
          expect(server.apiLog, [_readAssignment]);
        });
      }
    });
  });

  // ---------------------------------------------------------------------------
  // trashAssignment
  // ---------------------------------------------------------------------------

  group('PlannerService.trashAssignment', () {
    test('reads the assignment again, moves it to the trash once without a '
        'body, and reads it again: gone', () async {
      final (server, planner) = await serve({
        _readAssignment: [_json(_assignment), _json(_notFound, status: 404)],
        _trash: [_json('[]')],
      });

      await planner.trashAssignment(_listed(_assignment));

      expect(server.log, [
        'GET /course-list/api/v1/courses',
        'GET /',
        _readAssignment,
        _trash,
        _readAssignment,
      ]);
      expect(server.one(_trash).text, isEmpty);
      expect(server.one(_trash).query, isEmpty);
    });

    group('refuses before anything is sent', () {
      test('an assignment the planner does not let the user trash '
          '(canUserTrash)', () async {
        final (server, planner) = await serve({
          _readAssignment: [
            _json(_with(_assignment, capabilities: {'canUserTrash': false})),
          ],
        });

        await expectLater(
          planner.trashAssignment(_listed(_assignment)),
          throwsA(
            _refused(
              contains('canUserTrash not set'),
              reason: PlannerWriteRefusalReason.notAllowed,
              element: _assignmentId,
              flags: ['canUserTrash'],
            ),
          ),
        );
        expect(server.apiLog, [_readAssignment]);
      });

      test('an assignment with a linked Skore evaluation', () async {
        final (server, planner) = await serve({
          _readAssignment: [
            _json(_with(_assignment, changes: {'hasLinkedEvaluation': true})),
          ],
        });

        await expectLater(
          planner.trashAssignment(_listed(_assignment)),
          throwsA(
            _refused(
              contains('linked Skore evaluation'),
              reason: PlannerWriteRefusalReason.linkedEvaluation,
              element: _assignmentId,
            ),
          ),
        );
        expect(server.apiLog, [_readAssignment]);
      });

      test(
        'an assignment the planner no longer has (trashed already)',
        () async {
          final (server, planner) = await serve({
            _readAssignment: [_json(_notFound, status: 404)],
          });

          await expectLater(
            planner.trashAssignment(_listed(_assignment)),
            throwsA(
              isA<SmartschoolPlannedElementNotFoundError>()
                  .having(
                    (e) => e.elementType,
                    'elementType',
                    'planned-assignments',
                  )
                  .having((e) => e.elementId, 'elementId', _assignmentId),
            ),
          );
          expect(server.apiLog, [_readAssignment]);
        },
      );

      test('an element that is not an assignment: an ArgumentError, before '
          'any request', () async {
        final (server, planner) = await serve({});

        for (final element in [
          _listed(_slot),
          _listed(
            _with(
              _assignment,
              changes: {'plannedElementType': 'planned-lessons'},
            ),
          ),
        ]) {
          await expectLater(
            () => planner.trashAssignment(element),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('not an assignment'),
              ),
            ),
          );
        }
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the trash is unconfirmed, and the '
        'trash is not sent again', () {
      final answers = <String, (List<_Answer>, _Answer, Object?, Object?)>{
        'HTTP 500': (
          [_json(_assignment)],
          _json(_errorPage, status: 500),
          contains('cannot be used'),
          500,
        ),
        'HTTP 403': (
          [_json(_assignment)],
          _json(
            '{"status":403,"title":"Forbidden","detail":"","type":""}',
            status: 403,
          ),
          contains('HTTP 403'),
          403,
        ),
        'an HTML page': (
          [_json(_assignment)],
          _json(_errorPage),
          contains('HTML page'),
          200,
        ),
        'not a list': (
          [_json(_assignment)],
          _json(_assignment),
          contains('instead of a list'),
          200,
        ),
        'the planner still has the assignment': (
          [_json(_assignment), _json(_assignment)],
          _json('[]'),
          contains('still has the assignment'),
          200,
        ),
        'reading it again fails': (
          [_json(_assignment), _json(_errorPage, status: 500)],
          _json('[]'),
          contains('reading the assignment again failed'),
          200,
        ),
      };
      for (final MapEntry(key: name, value: (reads, answer, message, status))
          in answers.entries) {
        test(name, () async {
          final (server, planner) = await serve({
            _readAssignment: reads,
            _trash: [answer],
          });

          await expectLater(
            planner.trashAssignment(_listed(_assignment)),
            throwsA(
              _unconfirmed(
                allOf(
                  contains('trashAssignment'),
                  contains('to the trash'),
                  message,
                  contains('404 once it was trashed'),
                ),
                statusCode: status,
              ),
            ),
          );
          expect(server.plannerPosts, [_trash]);
        });
      }

      test('the connection drops after the trash went out', () async {
        final (server, planner) = await serve(
          {
            _readAssignment: [_json(_assignment)],
          },
          failures: {_trash: _dropped},
        );

        await expectLater(
          planner.trashAssignment(_listed(_assignment)),
          throwsA(
            _unconfirmed(
              contains('no answer came in'),
              statusCode: isNull,
              cause: isA<SmartschoolConnectionError>(),
            ),
          ),
        );
        expect(server.plannerPosts, [_trash]);
      });

      test('a session refused for the trash is not retried after logging in '
          'again', () async {
        final (server, planner) = await serve({
          _readAssignment: [_json(_assignment)],
          _trash: [_toLogin, _json('[]')],
        });

        await expectLater(
          planner.trashAssignment(_listed(_assignment)),
          throwsA(_notRetried),
        );
        expect(server.log, isNot(contains('GET /login')));
        expect(server.plannerPosts, [_trash]);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // The whole flow
  // ---------------------------------------------------------------------------

  test('the flow of the issue against a planner that keeps its state: plan '
      'a test in an own lesson hour, find it in the class calendar next to '
      "the hour, edit it, leave a colleague's test alone, move it to the "
      'trash, and find it gone', () async {
    // A planner with one lesson hour in the own week and a colleague's test
    // in the class calendar, that changes as the live planner did: the
    // create makes an assignment next to the slot (which stays), the edits
    // change it, the trash takes it (its detail is 404).
    String? assignment;
    final created = <Map<String, String>>[];

    _Answer? planner(_Request request) {
      final body = request.body;
      switch (request.label) {
        case 'GET $_api/planned-elements/user/$_me':
          return _json('[$_slot]');
        case 'GET $_api/planned-elements/group/4069_2001':
          return _json('[${[_slot, _other, ?assignment].join(',')}]');
        case _readTypes:
          return _json(_types);
        case _create:
          created.add(request.query);
          final create = body! as Map<String, dynamic>;
          final period = {...create['period'] as Map<String, dynamic>}
            ..remove('dateTime');
          assignment = _with(
            _assignment,
            changes: {
              'name': create['name'],
              'publicInfo': create['publicInfo'],
              'privateInfo': create['privateInfo'],
              'info': create['privateInfo'],
              'icon': create['icon'],
              'period': period,
            },
          );
          return _json(assignment!, status: 201);
        case _readAssignment:
          return assignment == null
              ? _json(_notFound, status: 404)
              : _json(assignment!);
        case _readOther:
          return _json(_other);
        case _rename:
          assignment = _with(
            assignment!,
            changes: {'name': (body! as Map<String, dynamic>)['newName']},
          );
          return _json(assignment!);
        case _changePublic:
          assignment = _with(
            assignment!,
            changes: {'publicInfo': (body! as Map<String, dynamic>)['newInfo']},
          );
          return _json(assignment!);
        case _trash:
          expect(body, isNull, reason: 'the trash has no body');
          assignment = null;
          return _json('[]');
      }
      return null;
    }

    final (server, service) = await serve({}, respond: planner);
    final day = (
      from: DateTime.utc(2026, 11, 19, 23),
      to: DateTime.utc(2026, 11, 20, 22, 59, 59),
    );

    // The own lesson hour gives the classes, course, room and time.
    final hour = (await service.getPlannedElements(
      await service.ownCalendar(),
      from: day.from,
      to: day.to,
    )).singleWhere((e) => e.type == PlannedElementType.placeholder);
    final ko = (await service.getAssignmentTypes()).firstWhere(
      (type) => type.abbreviation == 'KO',
    );

    final planned = await service.planAssignment(
      groupIds: [for (final group in hour.participantGroups) group.id],
      course: hour.courses.single,
      type: ko,
      name: '[dartschool test] Test: lussen',
      due: hour.period.from,
      until: hour.period.to,
      publicInfo: '<p>Leerstof: hoofdstuk 3</p>',
      locations: hour.locations,
    );
    expect(created, [
      {'waitForRefresh': 'true'},
    ]);
    expect(planned.name, '[dartschool test] Test: lussen');
    expect(planned.period.from.isAtSameMomentAs(hour.period.from), isTrue);
    expect(planned.period.to.isAtSameMomentAs(hour.period.to), isTrue);

    // The class calendar shows it next to the hour, which stays as it is,
    // and next to the colleague's test.
    final klas = PlannerCalendar.group('4069_2001');
    final withTest = await service.getPlannedElements(
      klas,
      from: day.from,
      to: day.to,
    );
    expect(withTest.map((e) => e.id), [_slotId, _otherId, _assignmentId]);

    final renamed = await service.renameElement(planned, 'Test: lussen (H3)');
    final informed = await service.changePublicInfo(
      renamed,
      '<p>Leerstof: hoofdstuk 3 en 4</p>',
    );
    expect(informed.name, 'Test: lussen (H3)');
    expect(informed.publicInfo, '<p>Leerstof: hoofdstuk 3 en 4</p>');

    // The colleague's test in the same calendar is left alone, and the
    // refusal says whose test it is (#100).
    final colleagues = withTest.singleWhere((e) => e.id == _otherId);
    final notOwn = isA<SmartschoolPlannerWriteRefusedError>()
        .having((e) => e.reason, 'reason', PlannerWriteRefusalReason.notOwn)
        .having((e) => e.element?.id, 'element', _otherId)
        .having(
          (e) => e.element?.organiserUsers.map((u) => u.name),
          'organisers',
          ['Wim Willems'],
        );
    await expectLater(
      service.renameElement(colleagues, 'Nieuw'),
      throwsA(notOwn),
    );
    await expectLater(service.trashAssignment(colleagues), throwsA(notOwn));

    await service.trashAssignment(informed);
    await expectLater(
      service.getDetail(informed),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );
    final after = await service.getPlannedElements(
      klas,
      from: day.from,
      to: day.to,
    );
    expect(after.map((e) => e.id), [_slotId, _otherId]);

    // A second trash finds it gone, and sends nothing.
    await expectLater(
      service.trashAssignment(informed),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );

    expect(server.plannerPosts, [_create, _rename, _changePublic, _trash]);
    expect(server.log.where((l) => l.startsWith('DELETE')), isEmpty);
  });
}
