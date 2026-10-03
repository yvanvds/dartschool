// Tests for issue #84: reading the planned elements of a user, class or
// location calendar, and the detail of one element (`PlannerService`).
//
// The answers below are trimmed captures of the live planner API (read-only,
// 2026-10-02):
//   - GET /planner/api/v1/planned-elements/group/{platformId}_{groupId}
//       ?from=...&to=... (one week of a class; elements of several teachers)
//   - GET /planner/api/v1/planned-lessons/{platformId}/{id}
//       (a colleague's lesson, private info included)
//   - GET /planner/api/v1/planned-assignments/{platformId}/{id}
//   - GET /planner/api/v1/planned-placeholders/{platformId}/{id}
//       (a timetable slot of the own planner, which can be filled)
//   - the 404 of a detail and the 400 of a calendar ID the planner refuses
// with every name, picture, user ID, group, course, location and element ID
// and every free text replaced by obvious fakes ("Jan Janssens",
// "Springfield Academy", `initials_XX`). The `capabilities` are trimmed to a
// few flags. The element of type `planned-excursions` is made up: no type
// other than lessons, assignments and placeholders was seen live, and the
// service must keep an unknown one.
//
// Everything here reads: the fake Smartschool fails the test on any request
// that is not a GET (the planner API also has POSTs that change the planner,
// one of which moves a whole period to the trash).
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

const _api = '/planner/api/v1';

const _placeholderId = 'e0000000-0000-5000-8000-000000000001';
const _lessonId = 'e0000000-0000-4000-8000-000000000002';
const _assignmentId = 'e0000000-0000-4000-8000-000000000003';
const _gymLessonId = 'e0000000-0000-4000-8000-000000000004';
const _excursionId = 'e0000000-0000-4000-8000-000000000005';
const _ownSlotId = 'e0000000-0000-5000-8000-000000000006';

/// One week of class 6A1 (group `4069_2001`), trimmed to five elements: a
/// colleague's timetable slot in two rooms, a colleague's lesson, a
/// colleague's assignment, a lesson without a room, and an element of a type
/// the library does not know.
const _groupWeek = r'''
[{"id":"e0000000-0000-5000-8000-000000000001","platformId":4069,"period":{"dateTimeFrom":"2026-10-05T14:40:00+02:00","dateTimeTo":"2026-10-05T15:30:00+02:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1002_0","pictureHash":"initials_PP","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"sort":"peeters-piet","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2003","id":"4069_2003","platformId":4069,"name":"6B1","type":"K","icon":"briefcase","sort":"6B1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"plannedElementType":"planned-placeholders","isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserReplace":false,"canUserReschedule":false,"canUserChangeUserColor":true,"canUserSeeProperties":{"id":true,"platformId":true,"period":true,"organisers":true,"participants":true,"plannedElementType":true,"isParticipant":true,"capabilities":true,"onlineSession":true,"courses":true,"locations":true}},"onlineSession":null,"courses":[{"id":"c0000000-0000-4000-8000-000000000001","platformId":4069,"name":"wiskunde","scheduleCodes":["WISKU","WISKU1"],"icon":"schoolbord","courseCluster":{"id":1,"name":"Wiskunde"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true},{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261005144000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","joinIds":{"from":"f0000000-0000-5000-8000-000000000001","to":"f0000000-0000-5000-8000-000000000002"}},
{"id":"e0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Erfelijkheid","period":{"dateTimeFrom":"2026-10-09T14:40:00+02:00","dateTimeTo":"2026-10-09T15:30:00+02:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangePrivateInfo":false,"canUserChangePublicInfo":false,"canUserReplace":false,"canUserLinkToDo":true,"canUserSeeProperties":{"id":true,"platformId":true,"name":true,"period":true,"organisers":true,"participants":true,"isParticipant":true,"capabilities":true,"onlineSession":true,"plannedElementType":true,"icon":true,"courses":true,"locations":true}},"onlineSession":null,"plannedElementType":"planned-lessons","icon":"document_observation","courses":[{"id":"c0000000-0000-4000-8000-000000000002","platformId":4069,"name":"biologie","scheduleCodes":["BIOLO"],"icon":"schoolbord","courseCluster":{"id":2,"name":"Biologie"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000103","platformId":4069,"platformName":"Springfield Academy","number":"","title":"103","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261009144000_4_6A1_Erfelijkheid","unconfirmed":false,"pinned":false,"color":"aqua-200","joinIds":{"from":"f0000000-0000-5000-8000-000000000003","to":"f0000000-0000-5000-8000-000000000004"}},
{"id":"e0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Test: hoofdstuk 3","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"period":{"dateTimeFrom":"2026-10-06T08:30:00+02:00","dateTimeTo":"2026-10-06T09:20:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1002_0","pictureHash":"initials_PP","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"sort":"peeters-piet","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReplace":false,"canUserPin":false,"canUserResolve":false,"canUserSeeProperties":{"id":true,"platformId":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true,"isParticipant":true,"capabilities":true,"plannedElementType":true,"resolvedStatus":true,"onlineSession":true,"icon":true,"courses":true,"locations":true}},"plannedElementType":"planned-assignments","resolvedStatus":"unresolved","onlineSession":null,"icon":"flags_red_yellow","courses":[{"id":"c0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Nederlands","scheduleCodes":["NEDER","NEDER1"],"icon":"schoolbord","courseCluster":{"id":3,"name":"Nederlands"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261006083000_5_6A1_Test: hoofdstuk 3","unconfirmed":false,"pinned":false,"color":"aqua-200","participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000005","to":"f0000000-0000-5000-8000-000000000005"}},
{"id":"e0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Volleybal: de opslag","period":{"dateTimeFrom":"2026-10-07T10:20:00+02:00","dateTimeTo":"2026-10-07T11:10:00+02:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserEdit":false,"canUserSeeProperties":{"id":true,"name":true}},"onlineSession":null,"plannedElementType":"planned-lessons","icon":"document_observation","courses":[{"id":"c0000000-0000-4000-8000-000000000004","platformId":4069,"name":"lichamelijke opvoeding","scheduleCodes":["LO"],"icon":"schoolbord","courseCluster":null,"isVisible":true}],"locations":[],"sort":"20261007102000_3_6A1_Volleybal: de opslag","unconfirmed":false,"pinned":false,"color":"aqua-200","joinIds":{"from":"f0000000-0000-5000-8000-000000000006","to":"f0000000-0000-5000-8000-000000000007"}},
{"id":"e0000000-0000-4000-8000-000000000005","platformId":4069,"name":"Uitstap naar Brussel","period":{"dateTimeFrom":"2026-10-08T00:00:00+02:00","dateTimeTo":"2026-10-08T23:59:59+02:00","wholeDay":true,"deadline":false},"organisers":{"users":[{"id":"4069_1002_0","pictureHash":"initials_PP","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"sort":"peeters-piet","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserEdit":false},"onlineSession":null,"plannedElementType":"planned-excursions","icon":"bus","courses":[],"locations":[],"sort":"20261008000000_1_6A1_Uitstap naar Brussel","unconfirmed":false,"pinned":true,"color":"aqua-200"}]
''';

/// The detail of a colleague's lesson, private info included (the planner
/// escapes `<` and `/` in its HTML, as here).
const _lessonDetail = r'''
{"id":"e0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Erfelijkheid","icon":"document_observation","info":"\u003Cp\u003E\u003Cstrong\u003EOpmerkingen\u003C\/strong\u003E\u003Cbr \/\u003EBoek meebrengen\u003C\/p\u003E","privateInfo":"\u003Cp\u003E\u003Cstrong\u003EOpmerkingen\u003C\/strong\u003E\u003Cbr \/\u003EBoek meebrengen\u003C\/p\u003E","publicInfo":"\u003Cp\u003ELees hoofdstuk 4\u003C\/p\u003E","period":{"dateTimeFrom":"2026-10-09T14:40:00+02:00","dateTimeTo":"2026-10-09T15:30:00+02:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000002","platformId":4069,"name":"biologie","scheduleCodes":["BIOLO"],"icon":"schoolbord","courseCluster":{"id":2,"name":"Biologie"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000103","platformId":4069,"platformName":"Springfield Academy","number":"","title":"103","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangePrivateInfo":false,"canUserChangePublicInfo":false,"canUserReplace":false,"canUserRename":false,"canUserSeeProperties":{"id":true,"name":true,"info":true,"privateInfo":true,"publicInfo":true,"period":true}},"presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-lessons","plannedToDos":[],"sort":"20261009144000_4_6A1_Erfelijkheid","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000003","to":"f0000000-0000-5000-8000-000000000004"}}
''';

/// The detail of a colleague's assignment.
const _assignmentDetail = r'''
{"id":"e0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Test: hoofdstuk 3","icon":"flags_red_yellow","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"info":"","privateInfo":"","publicInfo":"","period":{"dateTimeFrom":"2026-10-06T08:30:00+02:00","dateTimeTo":"2026-10-06T09:20:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1002_0","pictureHash":"initials_PP","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"sort":"peeters-piet","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"uploadFolder":null,"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Nederlands","scheduleCodes":["NEDER","NEDER1"],"icon":"schoolbord","courseCluster":{"id":3,"name":"Nederlands"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReschedule":false,"canUserAnnounce":false,"canUserRename":false,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"visibility":true}},"resolvedStatus":"unresolved","presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-assignments","plannedToDos":[],"isAnnounced":false,"visibility":{"afterDate":"2026-09-26T10:50:00+02:00"},"canUserAccessEvaluations":true,"hasLinkedEvaluation":false,"linkedEvaluation":null,"sort":"20261006083000_5_6A1_Test: hoofdstuk 3","unconfirmed":false,"pinned":false,"color":"aqua-200","dateCreated":"2026-09-26T10:50:52+02:00","reminders":[],"participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000005","to":"f0000000-0000-5000-8000-000000000005"}}
''';

/// The detail of a timetable slot of the own planner in November (winter
/// time, `+01:00`): no name, no info, and it can be filled.
const _ownSlotDetail = r'''
{"id":"e0000000-0000-5000-8000-000000000006","platformId":4069,"period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"labels":[],"presenceSaved":false,"showPresenceChoices":false,"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserReplace":true,"canUserReschedule":false,"canUserRename":false,"canUserChangeIcon":false,"canUserSeeProperties":{"id":true,"platformId":true,"period":true,"organisers":true,"participants":true,"courses":true,"locations":true,"plannedElementType":true}},"plannedElementType":"planned-placeholders","onlineSession":null,"reservations":[],"sort":"20261120111000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000008","to":"f0000000-0000-5000-8000-000000000009"}}
''';

/// The planner's answer to the detail of an element it does not have.
const _notFound = '{"status":404,"title":"Not Found","detail":"","type":""}';

/// The planner's answer to a location calendar asked for by its bare UUID.
const _badRequest =
    '{"status":400,"title":"Bad Request","detail":"","type":""}';

/// Smartschool's home page, trimmed to the script that holds the
/// authenticated user (`vars.authenticatedUser`).
String _homePage(String userId) =>
    '<!DOCTYPE html><html><head><title>Smartschool</title></head><body>\n'
    '<script>\n'
    'APP.extend(APP.vars || {}, JSON.parse(\'{"vars":{"authenticatedUser":'
    '{"id":"$userId","name":{"startingWithFirstName":"Jan Janssens",'
    '"startingWithLastName":"Janssens Jan"}}}}\'));\n'
    '</script>\n'
    '</body></html>';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, contentType: 'application/json');

/// A request as it reached the fake Smartschool.
typedef _Request = ({
  String method,
  String path,
  String rawQuery,
  Map<String, String> query,
});

/// A Smartschool that answers GETs from [answers] (by path), and fails the
/// test on any other request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.answers);

  final Map<String, _Answer> answers;

  /// Every request that reached it, in order.
  final List<_Request> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add((
      method: options.method,
      path: uri.path,
      rawQuery: uri.query,
      query: uri.queryParameters,
    ));
    // Never let a write through: the service only reads.
    expect(options.method, 'GET', reason: 'the planner service only reads');
    final answer = answers[uri.path];
    if (answer == null) {
      fail('Unexpected request: ${options.method} $uri');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: [answer.contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A [SmartschoolPlannerError], not an authentication failure.
Matcher _plannerError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isA<SmartschoolPlannerError>().having((e) => e.message, 'message', message),
);

/// A [DateTime] at the same moment as [expected], in local time.
Matcher _localMoment(DateTime expected) => isA<DateTime>()
    .having((t) => t.isUtc, 'isUtc', isFalse)
    .having(
      (t) => t.isAtSameMomentAs(expected),
      'is at the same moment as $expected',
      isTrue,
    );

List<PlannedElement> _parseWeek() =>
    PlannerService.parsePlannedElements(jsonDecode(_groupWeek));

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService)> serve(
    Map<String, _Answer> answers,
  ) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(answers);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client));
  }

  // ---------------------------------------------------------------------------
  // Dates
  // ---------------------------------------------------------------------------

  group('PlannerService.formatDateTime', () {
    test('writes summer time with +02:00, as the planner does in October', () {
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 10, 5, 6, 30),
          timeZoneOffset: const Duration(hours: 2),
        ),
        '2026-10-05T08:30:00+02:00',
      );
    });

    test('writes winter time with +01:00, as the planner does in November', () {
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 11, 20, 10, 10),
          timeZoneOffset: const Duration(hours: 1),
        ),
        '2026-11-20T11:10:00+01:00',
      );
    });

    test('moves to the date of the offset', () {
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 10, 4, 22),
          timeZoneOffset: const Duration(hours: 2),
        ),
        '2026-10-05T00:00:00+02:00',
      );
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 1, 1, 3),
          timeZoneOffset: const Duration(hours: -5),
        ),
        '2025-12-31T22:00:00-05:00',
      );
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 1, 1),
          timeZoneOffset: const Duration(hours: 5, minutes: 30),
        ),
        '2026-01-01T05:30:00+05:30',
      );
    });

    test('writes a UTC DateTime in UTC, with +00:00', () {
      expect(
        PlannerService.formatDateTime(DateTime.utc(2026, 10, 5, 8, 30)),
        '2026-10-05T08:30:00+00:00',
      );
    });

    test('writes a local DateTime in local time with its own offset', () {
      for (final local in [
        DateTime(2026, 10, 5, 8, 30),
        DateTime(2026, 11, 20, 11, 10),
      ]) {
        final offset = local.timeZoneOffset;
        final text = PlannerService.formatDateTime(local);
        expect(
          text,
          PlannerService.formatDateTime(local, timeZoneOffset: offset),
        );
        expect(text, startsWith('${_wall(local)}T'));
        expect(DateTime.parse(text).isAtSameMomentAs(local), isTrue);
      }
    });

    test('leaves out milliseconds', () {
      expect(
        PlannerService.formatDateTime(
          DateTime.utc(2026, 10, 9, 23, 59, 59, 999),
        ),
        '2026-10-09T23:59:59+00:00',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  group('PlannerService.parsePlannedElements', () {
    test('lists the elements of every teacher and type, in order', () {
      final week = _parseWeek();
      expect(week.map((e) => e.id), [
        _placeholderId,
        _lessonId,
        _assignmentId,
        _gymLessonId,
        _excursionId,
      ]);
      expect(week.map((e) => e.type), [
        PlannedElementType.placeholder,
        PlannedElementType.lesson,
        PlannedElementType.assignment,
        PlannedElementType.lesson,
        PlannedElementType.other,
      ]);
      expect(week.map((e) => e.organiserUsers.single.name).toSet(), {
        'Piet Peeters',
        'Wim Willems',
      });
    });

    test('a timetable slot has no name, but its groups, course and rooms', () {
      final slot = _parseWeek().first;
      expect(slot.type, PlannedElementType.placeholder);
      expect(slot.typeName, 'planned-placeholders');
      expect(slot.platformId, 4069);
      expect(slot.name, isNull);
      expect(slot.icon, isNull);
      expect(slot.assignmentType, isNull);
      expect(slot.period.from, _localMoment(DateTime.utc(2026, 10, 5, 12, 40)));
      expect(slot.period.to, _localMoment(DateTime.utc(2026, 10, 5, 13, 30)));
      expect(slot.period.wholeDay, isFalse);
      expect(slot.period.deadline, isFalse);
      expect(slot.participantGroups.map((g) => g.name), ['6A1', '6B1']);
      expect(slot.participantGroups.first.id, '4069_2001');
      expect(slot.participantGroups.first.platformId, 4069);
      expect(slot.participantGroups.first.type, 'K');
      expect(slot.participantGroups.first.icon, 'briefcase');
      expect(slot.participantUsers, isEmpty);
      expect(slot.organiserGroups, isEmpty);
      expect(slot.courses.single.name, 'wiskunde');
      expect(slot.locations.map((l) => l.title), ['101', '102']);
      expect(slot.capabilities.canReplace, isFalse);
      expect(slot.capabilities.can('canUserChangeUserColor'), isTrue);
      expect(slot.capabilities.can('canUserNeverHeardOf'), isFalse);
      expect(slot.capabilities.visibleProperties, contains('locations'));
      expect(slot.capabilities.visibleProperties, isNot(contains('name')));
    });

    test('an organiser is a user with the whole planner ID and a picture', () {
      final teacher = _parseWeek().first.organiserUsers.single;
      expect(teacher.id, '4069_1002_0');
      expect(teacher.name, 'Piet Peeters');
      expect(teacher.nameLastFirst, 'Peeters Piet');
      expect(
        teacher.pictureUrl,
        'https://userpicture20.smartschool.be/User/Userimage/hashimage/hash/'
        'initials_PP/plain/1/res/128',
      );
      expect(teacher.isDeleted, isFalse);
      expect(teacher.calendar, PlannerCalendar.user('4069_1002_0'));
    });

    test('a lesson has a name, an icon, a course and a room', () {
      final lesson = _parseWeek()[1];
      expect(lesson.name, 'Erfelijkheid');
      expect(lesson.icon, 'document_observation');
      expect(lesson.isParticipant, isFalse);
      expect(lesson.pinned, isFalse);
      expect(lesson.unconfirmed, isFalse);
      expect(lesson.color, 'aqua-200');

      final course = lesson.courses.single;
      expect(course.id, 'c0000000-0000-4000-8000-000000000002');
      expect(course.platformId, 4069);
      expect(course.name, 'biologie');
      expect(course.scheduleCodes, ['BIOLO']);
      expect(course.icon, 'schoolbord');
      expect(course.clusterId, 2);
      expect(course.clusterName, 'Biologie');
      expect(course.isVisible, isTrue);

      final room = lesson.locations.single;
      expect(room.id, '10000000-0000-4000-8000-000000000103');
      expect(room.platformId, 4069);
      expect(room.platformName, 'Springfield Academy');
      expect(room.title, '103');
      expect(room.number, '');
      expect(room.type, 'mini-db-item');
      expect(room.selectable, isTrue);
      expect(
        room.calendar,
        PlannerCalendar.location('4069_10000000-0000-4000-8000-000000000103'),
      );
    });

    test('an assignment has its assignment type, status and deadline', () {
      final assignment = _parseWeek()[2];
      expect(assignment.type, PlannedElementType.assignment);
      expect(assignment.name, 'Test: hoofdstuk 3');
      expect(assignment.resolvedStatus, 'unresolved');
      expect(assignment.period.deadline, isTrue);
      expect(
        assignment.period.from,
        _localMoment(DateTime.utc(2026, 10, 6, 6, 30)),
      );

      final type = assignment.assignmentType!;
      expect(type.id, 'a0000000-0000-4000-8000-000000000001');
      expect(type.name, 'Kleine Overhoring');
      expect(type.abbreviation, 'KO');
      expect(type.isVisible, isTrue);
      expect(type.defaultTiming, 'deadline');
      expect(type.weight, 0);
      expect(type.platformId, isNull);
    });

    test('an element without a room or a course cluster', () {
      final gym = _parseWeek()[3];
      expect(gym.locations, isEmpty);
      expect(gym.courses.single.clusterId, isNull);
      expect(gym.courses.single.clusterName, isNull);
      expect(gym.capabilities.visibleProperties, {'id', 'name'});
    });

    test('an element of an unknown type is kept, with the planner\'s name '
        'of the type', () {
      final excursion = _parseWeek().last;
      expect(excursion.type, PlannedElementType.other);
      expect(excursion.typeName, 'planned-excursions');
      expect(excursion.name, 'Uitstap naar Brussel');
      expect(excursion.period.wholeDay, isTrue);
      expect(excursion.pinned, isTrue);
      expect(excursion.courses, isEmpty);
    });

    test('raw keeps the fields the models do not cover', () {
      final slot = _parseWeek().first;
      expect(slot.raw['sort'], '20261005144000_8_6A1_');
      expect(slot.raw['joinIds'], {
        'from': 'f0000000-0000-5000-8000-000000000001',
        'to': 'f0000000-0000-5000-8000-000000000002',
      });
      expect(() => slot.raw['sort'] = 'x', throwsUnsupportedError);
    });

    test('reads the capture of the Python reference project, which leaves '
        'out organisers.groups and participants.userRoles', () {
      final capture = File(
        'test/fixtures/smartschool/requests/get/planner/api/v1/'
        'planned-elements/user/49_10880_2/7966cae8d297.json',
      ).readAsStringSync();
      final elements = PlannerService.parsePlannedElements(jsonDecode(capture));
      expect(elements, isNotEmpty);
      final slot = elements.first;
      expect(slot.type, PlannedElementType.placeholder);
      expect(slot.platformId, 49);
      expect(slot.name, isNull);
      expect(slot.organiserUsers.single.id, '49_8933_0');
      expect(slot.organiserGroups, isEmpty);
      expect(slot.participantGroups.map((g) => g.name), ['4CHU', '4CNW']);
      expect(slot.isParticipant, isTrue);
    });

    test('an empty calendar has no elements', () {
      expect(PlannerService.parsePlannedElements(<dynamic>[]), isEmpty);
    });

    test('an answer that is not a list is refused', () {
      expect(
        () => PlannerService.parsePlannedElements(<String, dynamic>{}),
        throwsA(_plannerError(contains('instead of a list'))),
      );
    });

    test('an element that is not an object is refused', () {
      expect(
        () => PlannerService.parsePlannedElements(['x']),
        throwsA(_plannerError(contains('element 0'))),
      );
    });

    test('an element without its id, type or period is refused', () {
      Map<String, dynamic> slot() =>
          (jsonDecode(_groupWeek) as List).first as Map<String, dynamic>;

      expect(
        () => PlannerService.parsePlannedElements([slot()..remove('id')]),
        throwsA(_plannerError(contains('without its id'))),
      );
      expect(
        () => PlannerService.parsePlannedElements([
          slot()..remove('plannedElementType'),
        ]),
        throwsA(_plannerError(contains('plannedElementType'))),
      );
      expect(
        () => PlannerService.parsePlannedElements([slot()..remove('period')]),
        throwsA(_plannerError(contains('the period of planned element'))),
      );
      expect(
        () =>
            PlannerService.parsePlannedElements([slot()..['platformId'] = 'x']),
        throwsA(_plannerError(contains('platformId'))),
      );
    });

    test('a period that is not a date and time is refused', () {
      final slot = (jsonDecode(_groupWeek) as List).first as Map;
      (slot['period'] as Map)['dateTimeFrom'] = 'maandag';
      expect(
        () => PlannerService.parsePlannedElements([slot]),
        throwsA(_plannerError(contains('"maandag"'))),
      );
    });

    test('a part in an unknown shape is refused', () {
      final slot = (jsonDecode(_groupWeek) as List).first as Map;
      slot['locations'] = {'id': 'x'};
      expect(
        () => PlannerService.parsePlannedElements([slot]),
        throwsA(_plannerError(contains('the locations of planned element'))),
      );
    });
  });

  group('PlannerService.parsePlannedElementDetail', () {
    test('a colleague\'s lesson, with the private info pupils do not see', () {
      final lesson = PlannerService.parsePlannedElementDetail(
        jsonDecode(_lessonDetail),
      );
      expect(lesson, isA<PlannedElement>());
      expect(lesson.id, _lessonId);
      expect(lesson.type, PlannedElementType.lesson);
      expect(lesson.name, 'Erfelijkheid');
      expect(lesson.organiserUsers.single.name, 'Wim Willems');
      expect(
        lesson.privateInfo,
        '<p><strong>Opmerkingen</strong><br />Boek meebrengen</p>',
      );
      expect(lesson.info, lesson.privateInfo);
      expect(lesson.publicInfo, '<p>Lees hoofdstuk 4</p>');
      expect(lesson.capabilities.canEdit, isFalse);
      expect(lesson.capabilities.canChangePrivateInfo, isFalse);
      expect(lesson.isAnnounced, isNull);
      expect(lesson.visibleFrom, isNull);
      expect(lesson.hasLinkedEvaluation, isNull);
      expect(lesson.dateCreated, isNull);
      expect(lesson.raw['attachments'], isEmpty);
    });

    test('an assignment, with its visibility and creation date', () {
      final assignment = PlannerService.parsePlannedElementDetail(
        jsonDecode(_assignmentDetail),
      );
      expect(assignment.type, PlannedElementType.assignment);
      expect(assignment.assignmentType!.abbreviation, 'KO');
      expect(assignment.info, '');
      expect(assignment.privateInfo, '');
      expect(assignment.publicInfo, '');
      expect(assignment.isAnnounced, isFalse);
      expect(assignment.hasLinkedEvaluation, isFalse);
      expect(
        assignment.visibleFrom,
        _localMoment(DateTime.utc(2026, 9, 26, 8, 50)),
      );
      expect(
        assignment.dateCreated,
        _localMoment(DateTime.utc(2026, 9, 26, 8, 50, 52)),
      );
      expect(assignment.capabilities.canTrash, isFalse);
      expect(assignment.capabilities.canRename, isFalse);
    });

    test('a timetable slot of the own planner in winter time, which can be '
        'filled', () {
      final slot = PlannerService.parsePlannedElementDetail(
        jsonDecode(_ownSlotDetail),
      );
      expect(slot.type, PlannedElementType.placeholder);
      expect(slot.name, isNull);
      expect(slot.info, '');
      expect(slot.publicInfo, '');
      expect(
        slot.period.from,
        _localMoment(DateTime.utc(2026, 11, 20, 10, 10)),
      );
      expect(slot.period.to, _localMoment(DateTime.utc(2026, 11, 20, 11)));
      expect(slot.organiserUsers.single.id, '4069_1001_0');
      expect(slot.capabilities.canReplace, isTrue);
      expect(slot.capabilities.canEdit, isTrue);
      expect(slot.capabilities.canRename, isFalse);
    });

    test('an answer that is not an object is refused', () {
      expect(
        () => PlannerService.parsePlannedElementDetail(<dynamic>[]),
        throwsA(_plannerError(contains('instead of an object'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------

  group('PlannerService.getPlannedElements', () {
    const groupPath = '$_api/planned-elements/group/4069_2001';

    test('reads a class calendar: GET planned-elements/group/{id}', () async {
      final (server, planner) = await serve({groupPath: _json(_groupWeek)});

      final week = await planner.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: DateTime.utc(2026, 10, 4, 22),
        to: DateTime.utc(2026, 10, 9, 21, 59, 59),
      );

      expect(week, hasLength(5));
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, groupPath);
      expect(request.query.keys, ['from', 'to']);
    });

    test('sends the dates with their offset, + encoded as %2B', () async {
      final (server, planner) = await serve({groupPath: _json('[]')});

      await planner.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: DateTime.utc(2026, 10, 4, 22),
        to: DateTime.utc(2026, 10, 9, 21, 59, 59),
      );

      final request = server.requests.single;
      expect(
        request.rawQuery,
        'from=2026-10-04T22%3A00%3A00%2B00%3A00'
        '&to=2026-10-09T21%3A59%3A59%2B00%3A00',
      );
      expect(request.rawQuery, isNot(contains('+')));
    });

    test('sends local dates in local time, each with its own offset (summer '
        'and winter time in Belgium)', () async {
      final (server, planner) = await serve({groupPath: _json('[]')});
      final from = DateTime(2026, 10, 5);
      final to = DateTime(2026, 11, 20, 23, 59, 59);

      await planner.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: from,
        to: to,
      );

      final request = server.requests.single;
      expect(request.rawQuery, isNot(contains('+')));
      expect(request.query['from'], PlannerService.formatDateTime(from));
      expect(request.query['to'], PlannerService.formatDateTime(to));
      expect(request.query['from'], startsWith('2026-10-05T00:00:00'));
      expect(request.query['to'], startsWith('2026-11-20T23:59:59'));
      expect(
        DateTime.parse(request.query['from']!).isAtSameMomentAs(from),
        isTrue,
      );
      expect(DateTime.parse(request.query['to']!).isAtSameMomentAs(to), isTrue);
    });

    test('reads a user calendar with the whole user ID', () async {
      const path = '$_api/planned-elements/user/4069_1002_0';
      final (server, planner) = await serve({path: _json(_groupWeek)});

      await planner.getPlannedElements(
        PlannerCalendar.user('4069_1002_0'),
        from: DateTime.utc(2026, 10, 5),
        to: DateTime.utc(2026, 10, 9),
      );

      expect(server.requests.single.path, path);
    });

    test('reads a location calendar with {platformId}_{itemId}', () async {
      const path =
          '$_api/planned-elements/location/'
          '4069_10000000-0000-4000-8000-000000000101';
      final (server, planner) = await serve({path: _json(_groupWeek)});
      final room = _parseWeek().first.locations.first;

      await planner.getPlannedElements(
        room.calendar,
        from: DateTime.utc(2026, 10, 5),
        to: DateTime.utc(2026, 10, 9),
      );

      expect(server.requests.single.path, path);
    });

    test('filters on types with the planner\'s names', () async {
      final (server, planner) = await serve({groupPath: _json('[]')});

      await planner.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: DateTime.utc(2026, 10, 5),
        to: DateTime.utc(2026, 10, 9),
        types: {PlannedElementType.assignment},
      );
      await planner.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: DateTime.utc(2026, 10, 5),
        to: DateTime.utc(2026, 10, 9),
        types: const {PlannedElementType.assignment, PlannedElementType.lesson},
      );

      expect(server.requests[0].query['types'], 'planned-assignments');
      expect(
        server.requests[0].rawQuery,
        endsWith('&types=planned-assignments'),
      );
      expect(
        server.requests[1].query['types'],
        'planned-lessons,planned-assignments',
      );
    });

    test('refuses an empty types filter, PlannedElementType.other, and a '
        'period that ends before it starts, before sending anything', () async {
      final (server, planner) = await serve({});
      final calendar = PlannerCalendar.group('4069_2001');
      final from = DateTime.utc(2026, 10, 5);
      final to = DateTime.utc(2026, 10, 9);

      await expectLater(
        planner.getPlannedElements(calendar, from: from, to: to, types: {}),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.getPlannedElements(
          calendar,
          from: from,
          to: to,
          types: {PlannedElementType.other},
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.getPlannedElements(calendar, from: to, to: from),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });

    test('a calendar the planner refuses is a SmartschoolPlannerError with '
        'the status', () async {
      final (_, planner) = await serve({
        groupPath: _json(_badRequest, status: 400),
      });

      await expectLater(
        planner.getPlannedElements(
          PlannerCalendar.group('4069_2001'),
          from: DateTime.utc(2026, 10, 5),
          to: DateTime.utc(2026, 10, 9),
        ),
        throwsA(
          allOf(
            _plannerError(allOf(contains('HTTP 400'), contains('Bad Request'))),
            isA<SmartschoolPlannerError>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
            isNot(isA<SmartschoolPlannedElementNotFoundError>()),
          ),
        ),
      );
    });

    test('an HTML page or invalid JSON is a SmartschoolPlannerError', () async {
      for (final body in [_errorPage, '[{"id":', '']) {
        final (_, planner) = await serve({
          groupPath: (status: 200, body: body, contentType: 'text/html'),
        });
        await expectLater(
          planner.getPlannedElements(
            PlannerCalendar.group('4069_2001'),
            from: DateTime.utc(2026, 10, 5),
            to: DateTime.utc(2026, 10, 9),
          ),
          throwsA(
            allOf(
              _plannerError(),
              isA<SmartschoolPlannerError>().having(
                (e) => e.statusCode,
                'statusCode',
                isNull,
              ),
            ),
          ),
          reason: body,
        );
      }
    });
  });

  group('PlannerService.getPlannedElement / getDetail', () {
    const lessonPath = '$_api/planned-lessons/4069/$_lessonId';
    const assignmentPath = '$_api/planned-assignments/4069/$_assignmentId';
    const slotPath = '$_api/planned-placeholders/4069/$_ownSlotId';

    test(
      'reads a lesson: GET {plannedElementType}/{platformId}/{id}',
      () async {
        final (server, planner) = await serve({
          lessonPath: _json(_lessonDetail),
        });

        final lesson = await planner.getPlannedElement(
          type: PlannedElementType.lesson,
          platformId: 4069,
          id: _lessonId,
        );

        expect(lesson.name, 'Erfelijkheid');
        expect(lesson.privateInfo, contains('Boek meebrengen'));
        final request = server.requests.single;
        expect(request.method, 'GET');
        expect(request.path, lessonPath);
        expect(request.rawQuery, isEmpty);
      },
    );

    test('reads an assignment and a timetable slot', () async {
      final (server, planner) = await serve({
        assignmentPath: _json(_assignmentDetail),
        slotPath: _json(_ownSlotDetail),
      });

      final assignment = await planner.getPlannedElement(
        type: PlannedElementType.assignment,
        platformId: 4069,
        id: _assignmentId,
      );
      final slot = await planner.getPlannedElement(
        type: PlannedElementType.placeholder,
        platformId: 4069,
        id: _ownSlotId,
      );

      expect(assignment.assignmentType!.name, 'Kleine Overhoring');
      expect(slot.capabilities.canReplace, isTrue);
      expect(server.requests.map((r) => r.path), [assignmentPath, slotPath]);
    });

    test('getDetail reads the detail of a listed element', () async {
      final (server, planner) = await serve({
        lessonPath: _json(_lessonDetail),
        '$_api/planned-excursions/4069/$_excursionId': _json(
          _lessonDetail
              .replaceAll(_lessonId, _excursionId)
              .replaceAll('"planned-lessons"', '"planned-excursions"'),
        ),
      });
      final week = _parseWeek();

      final lesson = await planner.getDetail(week[1]);
      final excursion = await planner.getDetail(week.last);

      expect(lesson.publicInfo, '<p>Lees hoofdstuk 4</p>');
      expect(excursion.type, PlannedElementType.other);
      expect(excursion.typeName, 'planned-excursions');
      expect(server.requests.map((r) => r.path), [
        lessonPath,
        '$_api/planned-excursions/4069/$_excursionId',
      ]);
    });

    test('an element the planner does not have (404) is a '
        'SmartschoolPlannedElementNotFoundError', () async {
      final (_, planner) = await serve({
        lessonPath: _json(_notFound, status: 404),
      });

      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.lesson,
          platformId: 4069,
          id: _lessonId,
        ),
        throwsA(
          isA<SmartschoolPlannedElementNotFoundError>()
              .having((e) => e.elementType, 'elementType', 'planned-lessons')
              .having((e) => e.platformId, 'platformId', 4069)
              .having((e) => e.elementId, 'elementId', _lessonId)
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('Not Found')),
        ),
      );
    });

    test('the not-found error is a SmartschoolPlannerError, not a session '
        'problem', () async {
      final (_, planner) = await serve({
        lessonPath: _json(_notFound, status: 404),
      });

      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.lesson,
          platformId: 4069,
          id: _lessonId,
        ),
        throwsA(_plannerError(contains('no planned-lessons'))),
      );
    });

    test('the detail of another element than the one asked for is '
        'refused', () async {
      final (_, planner) = await serve({
        '$_api/planned-lessons/4069/$_gymLessonId': _json(_lessonDetail),
      });

      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.lesson,
          platformId: 4069,
          id: _gymLessonId,
        ),
        throwsA(_plannerError(contains('with element $_lessonId'))),
      );
    });

    // #99: an element of a type the library does not know could only be read
    // with getDetail, which takes a whole PlannedElement.
    test('reads an element of a type the library does not know by its '
        'typeName, platform and id kept from the list (#99)', () async {
      const excursionPath = '$_api/planned-excursions/4069/$_excursionId';
      final (_, lister) = await serve({
        '$_api/planned-elements/group/4069_2001': _json(_groupWeek),
      });
      final week = await lister.getPlannedElements(
        PlannerCalendar.group('4069_2001'),
        from: DateTime(2026, 10, 5),
        to: DateTime(2026, 10, 9, 23, 59, 59),
      );
      final listed = week.last;
      expect(listed.type, PlannedElementType.other);
      // What a caller (an app or a server) keeps of it between calls.
      final (typeName, platformId, id) = (
        listed.typeName,
        listed.platformId,
        listed.id,
      );

      // Later, on another client.
      final (server, planner) = await serve({
        excursionPath: _json(
          _lessonDetail
              .replaceAll(_lessonId, _excursionId)
              .replaceAll('"planned-lessons"', '"planned-excursions"'),
        ),
      });
      final excursion = await planner.getPlannedElement(
        typeName: typeName,
        platformId: platformId,
        id: id,
      );

      expect(excursion.id, _excursionId);
      expect(excursion.type, PlannedElementType.other);
      expect(excursion.typeName, 'planned-excursions');
      expect(excursion.publicInfo, '<p>Lees hoofdstuk 4</p>');
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, excursionPath);
      expect(request.rawQuery, isEmpty);
    });

    test('typeName of a type the library knows reads as its type does '
        '(#99)', () async {
      final (server, planner) = await serve({lessonPath: _json(_lessonDetail)});

      final byName = await planner.getPlannedElement(
        typeName: 'planned-lessons',
        platformId: 4069,
        id: _lessonId,
      );
      final byType = await planner.getPlannedElement(
        type: PlannedElementType.lesson,
        platformId: 4069,
        id: _lessonId,
      );

      expect(byName.type, PlannedElementType.lesson);
      expect(byName.name, byType.name);
      expect(byName.privateInfo, byType.privateInfo);
      expect(server.requests.map((r) => r.path), [lessonPath, lessonPath]);
    });

    test('takes the typeName of every type the library knows (#99)', () async {
      final known = [
        for (final type in PlannedElementType.values)
          if (type.wireName != null) type.wireName!,
      ];
      final (server, planner) = await serve({
        for (final typeName in known)
          '$_api/$typeName/4069/$_lessonId': _json(_notFound, status: 404),
      });

      for (final typeName in known) {
        await expectLater(
          planner.getPlannedElement(
            typeName: typeName,
            platformId: 4069,
            id: _lessonId,
          ),
          throwsA(
            isA<SmartschoolPlannedElementNotFoundError>().having(
              (e) => e.elementType,
              'elementType',
              typeName,
            ),
          ),
        );
      }
      expect(server.requests.map((r) => r.path), [
        for (final typeName in known) '$_api/$typeName/4069/$_lessonId',
      ]);
    });

    test('a typeName the planner does not have (404 "Resource not found") '
        'is a SmartschoolPlannedElementNotFoundError (#99)', () async {
      const path = '$_api/planned-field-trips/4069/$_excursionId';
      final (server, planner) = await serve({
        // The planner's answer to a type it does not have (read live,
        // 2026-10-03): another body than for an element it does not have.
        path: _json('{"error":"Resource not found"}', status: 404),
      });

      await expectLater(
        planner.getPlannedElement(
          typeName: 'planned-field-trips',
          platformId: 4069,
          id: _excursionId,
        ),
        throwsA(
          isA<SmartschoolPlannedElementNotFoundError>()
              .having(
                (e) => e.elementType,
                'elementType',
                'planned-field-trips',
              )
              .having((e) => e.platformId, 'platformId', 4069)
              .having((e) => e.elementId, 'elementId', _excursionId),
        ),
      );
      expect(server.requests.single.path, path);
    });

    test('refuses neither or both of type and typeName, and a typeName not '
        'of the planner\'s form, before sending anything (#99)', () async {
      final (server, planner) = await serve({});

      await expectLater(
        planner.getPlannedElement(platformId: 4069, id: _lessonId),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'type')
              .having((e) => e.message, 'message', contains('typeName')),
        ),
      );
      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.lesson,
          typeName: 'planned-lessons',
          platformId: 4069,
          id: _lessonId,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'typeName')),
      );
      for (final typeName in [
        '',
        ' ',
        'planned-',
        'lessons',
        'Planned-Lessons',
        ' planned-lessons',
        'planned-lessons/4069',
        'planned-lessons%2F4069',
        '..',
        'planned_lessons',
      ]) {
        await expectLater(
          planner.getPlannedElement(
            typeName: typeName,
            platformId: 4069,
            id: _lessonId,
          ),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'typeName'),
          ),
          reason: '"$typeName"',
        );
      }
      await expectLater(
        planner.getPlannedElement(
          typeName: 'planned-excursions',
          platformId: 4069,
          id: '',
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'id')),
      );
      expect(server.requests, isEmpty);
    });

    test('refuses PlannedElementType.other and an empty ID before sending '
        'anything', () async {
      final (server, planner) = await serve({});

      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.other,
          platformId: 4069,
          id: _excursionId,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('typeName'),
          ),
        ),
      );
      await expectLater(
        planner.getPlannedElement(
          type: PlannedElementType.lesson,
          platformId: 4069,
          id: ' ',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('PlannerService.ownCalendar', () {
    Map<String, _Answer> loggedInAs(String userId) => {
      '/course-list/api/v1/courses': _json('[{"platformId":4069}]'),
      '/': (
        status: 200,
        body: _homePage(userId),
        contentType: 'text/html; charset=UTF-8',
      ),
    };

    test('is the user calendar of the whole authenticated user ID', () async {
      final (_, planner) = await serve(loggedInAs('4069_1001_0'));

      expect(await planner.ownCalendar(), PlannerCalendar.user('4069_1001_0'));
    });

    test('keeps the number of a co-account', () async {
      final (_, planner) = await serve(loggedInAs('4069_1001_2'));

      expect(await planner.ownCalendar(), PlannerCalendar.user('4069_1001_2'));
    });

    test('reads the own planner: GET planned-elements/user/{own ID}', () async {
      const path = '$_api/planned-elements/user/4069_1001_0';
      final (server, planner) = await serve({
        ...loggedInAs('4069_1001_0'),
        path: _json('[$_ownSlotDetail]'),
      });

      final elements = await planner.getPlannedElements(
        await planner.ownCalendar(),
        from: DateTime.utc(2026, 11, 16),
        to: DateTime.utc(2026, 11, 20, 22, 59, 59),
        types: {PlannedElementType.placeholder},
      );

      expect(elements.single.id, _ownSlotId);
      expect(elements.single.capabilities.canReplace, isTrue);
      expect(server.requests.last.path, path);
      expect(server.requests.last.query['types'], 'planned-placeholders');
    });

    test(
      'an authenticated user ID in another form is a parsing error',
      () async {
        final (_, planner) = await serve(loggedInAs('1001'));

        await expectLater(
          planner.ownCalendar(),
          throwsA(isA<SmartschoolParsingError>()),
        );
      },
    );
  });
}

/// The local date of [time] as `yyyy-MM-dd`.
String _wall(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}-'
    '${time.month.toString().padLeft(2, '0')}-'
    '${time.day.toString().padLeft(2, '0')}';
