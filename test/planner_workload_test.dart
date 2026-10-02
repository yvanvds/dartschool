// Tests for issue #86: the school's assignment types, and the assignments
// and the workload of classes in a period (`PlannerService.
// getAssignmentTypes`, `getAssignmentsOfGroups`, `getWorkloadSchedule` and
// `calculateWorkload`), what the planner's workload view ("werkbelasting")
// shows and the check it runs before it saves an assignment.
//
// The answers below are trimmed captures of the live API (read-only,
// 2026-10-02):
//   - GET /lesson-content/api/v1/assignments/applicable-assignment-types
//       (the school's six assignment types);
//   - POST /planner/api/v1/workload/planned-elements?from=...&to=...
//       with one class (four assignments of three teachers in a week);
//   - POST /planner/api/v1/workload/schedule?from=...&to=...
//       with one class (Monday to Friday; the allowed assignment types of
//       each day trimmed to two);
//   - POST /planner/api/v1/workload/calculate with one class and one lesson
//       hour;
// with every name, picture, user, group, course, location, element, type and
// setting ID, class name and title replaced by obvious fakes ("Piet
// Peeters", "Springfield Academy", `initials_XX`). The `capabilities` are
// trimmed to a few flags. Every weight was 0 at the school seen live: the
// answers with other figures, a second class or a class without a setting
// are made up from the captures, and say so.
//
// Everything here reads. The workload calls are POSTs that only read; the
// fake Smartschool answers those, the search of #85 and the GET of the
// assignment types, and fails the test on any other request.
import 'dart:convert';
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
const _typesPath =
    '/lesson-content/api/v1/assignments/applicable-assignment-types';
const _assignmentsPath = '$_api/workload/planned-elements';
const _schedulePath = '$_api/workload/schedule';
const _calculatePath = '$_api/workload/calculate';
const _searchPath = '$_api/quick-search/planner/search';

/// The POSTs the service may send: they only read.
const _readingPosts = {
  _assignmentsPath,
  _schedulePath,
  _calculatePath,
  _searchPath,
};

const _koId = 'a0000000-0000-4000-8000-000000000001';
const _goId = 'a0000000-0000-4000-8000-000000000002';
const _mbId = 'a0000000-0000-4000-8000-000000000005';

/// The school's assignment types.
const _types = r'''
[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Grote Taak","abbreviation":"GT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Kleine Taak","abbreviation":"KT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000005","platformId":4069,"name":"Meebrengen","abbreviation":"MB","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000006","platformId":4069,"name":"Voorbereiding","abbreviation":"V","isVisible":true,"defaultTiming":"deadline","weight":0}]
''';

/// The assignments of class 6A1 (group `4069_2001`) in the week of
/// 2026-10-05, in the planner's order (not by date): a KO on Tuesday shared
/// with two other classes, and on Monday a GO of six classes and an MB and a
/// KO of one teacher in the same hour.
const _assignments = r'''
[{"id":"e0000000-0000-4000-8000-000000000011","platformId":4069,"name":"Test: hoofdstuk 3","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"period":{"dateTimeFrom":"2026-10-06T08:30:00+02:00","dateTimeTo":"2026-10-06T09:20:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1002_0","pictureHash":"initials_PP","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Piet Peeters","startingWithLastName":"Peeters Piet"},"sort":"peeters-piet","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2003","id":"4069_2003","platformId":4069,"name":"6B1","type":"K","icon":"briefcase","sort":"6B1"},{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2004","id":"4069_2004","platformId":4069,"name":"6C1","type":"K","icon":"briefcase","sort":"6C1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReschedule":false,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true}},"plannedElementType":"planned-assignments","resolvedStatus":"unresolved","onlineSession":null,"icon":"flags_red_yellow","courses":[{"id":"c0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Nederlands","scheduleCodes":["NEDER","NEDER1"],"icon":"schoolbord","courseCluster":{"id":3,"name":"Nederlands"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000102","platformId":4069,"platformName":"Springfield Academy","number":"","title":"102","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261006083000_5_6B1_Test: hoofdstuk 3","unconfirmed":false,"pinned":false,"color":"aqua-200","participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000011","to":"f0000000-0000-5000-8000-000000000011"}},
{"id":"e0000000-0000-4000-8000-000000000012","platformId":4069,"name":"Toets: atoombouw","assignmentType":{"id":"a0000000-0000-4000-8000-000000000002","name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},"period":{"dateTimeFrom":"2026-10-05T12:50:00+02:00","dateTimeTo":"2026-10-05T13:40:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"},{"identifier":"4069_2007","id":"4069_2007","platformId":4069,"name":"6D2","type":"K","icon":"briefcase","sort":"6D2"},{"identifier":"4069_2006","id":"4069_2006","platformId":4069,"name":"6D1","type":"K","icon":"briefcase","sort":"6D1"},{"identifier":"4069_2005","id":"4069_2005","platformId":4069,"name":"6C2","type":"K","icon":"briefcase","sort":"6C2"},{"identifier":"4069_2004","id":"4069_2004","platformId":4069,"name":"6C1","type":"K","icon":"briefcase","sort":"6C1"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReschedule":false,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true}},"plannedElementType":"planned-assignments","resolvedStatus":"unresolved","onlineSession":null,"icon":"flags_red_yellow","courses":[{"id":"c0000000-0000-4000-8000-000000000006","platformId":4069,"name":"chemie","scheduleCodes":["CHEMI"],"icon":"schoolbord","courseCluster":{"id":6,"name":"Wetenschappen"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000104","platformId":4069,"platformName":"Springfield Academy","number":"","title":"104","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261005125000_5_6A1_Toets: atoombouw","unconfirmed":false,"pinned":false,"color":"aqua-200","participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000012","to":"f0000000-0000-5000-8000-000000000012"}},
{"id":"e0000000-0000-4000-8000-000000000013","platformId":4069,"name":"Rekenmachine meebrengen","assignmentType":{"id":"a0000000-0000-4000-8000-000000000005","name":"Meebrengen","abbreviation":"MB","isVisible":true,"defaultTiming":"deadline","weight":0},"period":{"dateTimeFrom":"2026-10-05T09:20:00+02:00","dateTimeTo":"2026-10-05T10:10:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1005_0","pictureHash":"initials_AC","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_AC\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"An Claes","startingWithLastName":"Claes An"},"sort":"claes-an","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReschedule":false,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true}},"plannedElementType":"planned-assignments","resolvedStatus":"unresolved","onlineSession":null,"icon":"flags_red_yellow","courses":[{"id":"c0000000-0000-4000-8000-000000000007","platformId":4069,"name":"economie","scheduleCodes":["ECONO"],"icon":"schoolbord","courseCluster":{"id":7,"name":"Economie"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000105","platformId":4069,"platformName":"Springfield Academy","number":"","title":"105","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261005092000_5_6A1_Rekenmachine meebrengen","unconfirmed":false,"pinned":false,"color":"aqua-200","participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000013","to":"f0000000-0000-5000-8000-000000000013"}},
{"id":"e0000000-0000-4000-8000-000000000014","platformId":4069,"name":"Test: begroting","assignmentType":{"id":"a0000000-0000-4000-8000-000000000001","name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},"period":{"dateTimeFrom":"2026-10-05T09:20:00+02:00","dateTimeTo":"2026-10-05T10:10:00+02:00","wholeDay":false,"deadline":true},"organisers":{"users":[{"id":"4069_1005_0","pictureHash":"initials_AC","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_AC\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"An Claes","startingWithLastName":"Claes An"},"sort":"claes-an","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":false,"canUserChangeAssignmentType":false,"canUserReschedule":false,"canUserSeeProperties":{"id":true,"name":true,"assignmentType":true,"period":true,"organisers":true,"participants":true}},"plannedElementType":"planned-assignments","resolvedStatus":"unresolved","onlineSession":null,"icon":"flags_red_yellow","courses":[{"id":"c0000000-0000-4000-8000-000000000007","platformId":4069,"name":"economie","scheduleCodes":["ECONO"],"icon":"schoolbord","courseCluster":{"id":7,"name":"Economie"},"isVisible":true}],"locations":[{"id":"10000000-0000-4000-8000-000000000105","platformId":4069,"platformName":"Springfield Academy","number":"","title":"105","icon":"","type":"mini-db-item","selectable":true}],"sort":"20261005092000_5_6A1_Test: begroting","unconfirmed":false,"pinned":false,"color":"aqua-200","participantsChangedAfterEvaluation":false,"joinIds":{"from":"f0000000-0000-5000-8000-000000000014","to":"f0000000-0000-5000-8000-000000000014"}}]
''';

/// The workload of class 6A1 per day, Monday to Friday of the week of
/// 2026-10-05: weight 0 every day (also on the days with the assignments
/// above), and the setting `Geen limiet`.
const _schedule = r'''
{"schedule":{"2026-10-05":[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0}]}}],
"2026-10-06":[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0}]}}],
"2026-10-07":[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0}]}}],
"2026-10-08":[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0}]}}],
"2026-10-09":[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0}]}}]}}
''';

/// The workload of class 6A1 for one lesson hour, as the planner computes it
/// before it saves an assignment.
const _calculated = r'''
[{"group":{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},"weight":0,"concurrentWeight":0,"workloadSetting":{"id":"b0000000-0000-4000-8000-000000000001","platformId":4069,"color":"aqua-500","name":"Geen limiet","limit":{"value":-1,"period":"day","type":"soft"},"allowedAssignmentTypes":[{"id":"a0000000-0000-4000-8000-000000000002","platformId":4069,"name":"Grote Overhoring","abbreviation":"GO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000003","platformId":4069,"name":"Grote Taak","abbreviation":"GT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000001","platformId":4069,"name":"Kleine Overhoring","abbreviation":"KO","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000004","platformId":4069,"name":"Kleine Taak","abbreviation":"KT","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000005","platformId":4069,"name":"Meebrengen","abbreviation":"MB","isVisible":true,"defaultTiming":"deadline","weight":0},{"id":"a0000000-0000-4000-8000-000000000006","platformId":4069,"name":"Voorbereiding","abbreviation":"V","isVisible":true,"defaultTiming":"deadline","weight":0}]}}]
''';

/// The search for `6A` (#85), trimmed to class 6A1.
const _searchClass = r'''
[{"identifier":{"id":"4069_2001","type":"group"},"title":[{"part":"6A","isHighlighted":true},{"part":"1","isHighlighted":false}],"description":[],"graphic":{"type":"icon","value":"briefcase"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"groupIdentifier":"4069_2001","name":"6A1","description":"6 Latijn 1"},"sortField":"0-group-6A1"}]
''';

/// The planner's answer to a request it refuses.
const _badRequest =
    '{"status":400,"title":"Bad Request","detail":"","type":""}';

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
  String? contentType,
  String body,
});

/// A Smartschool that answers [answers] (by `METHOD path`), and fails the
/// test on a POST to anything but the reading POSTs and on any other
/// request.
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
    final body = requestStream == null
        ? ''
        : utf8.decode(
            await requestStream.fold<List<int>>([], (all, c) => all..addAll(c)),
          );
    requests.add((
      method: options.method,
      path: uri.path,
      rawQuery: uri.query,
      query: uri.queryParameters,
      contentType: options.contentType,
      body: body,
    ));
    // Never let a write through: the service only reads.
    if (options.method == 'POST') {
      expect(
        _readingPosts,
        contains(uri.path),
        reason: 'the planner service only sends POSTs that read',
      );
    } else {
      expect(options.method, 'GET', reason: 'the planner service only reads');
    }
    final answer = answers['${options.method} ${uri.path}'];
    if (answer == null) {
      fail('Unexpected request: ${options.method} $uri $body');
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

/// A [SmartschoolPlannerError] with [statusCode].
Matcher _plannerStatus(int? statusCode, [Object? message = anything]) => allOf(
  _plannerError(message),
  isA<SmartschoolPlannerError>().having(
    (e) => e.statusCode,
    'statusCode',
    statusCode,
  ),
);

/// The day of [time] in the school's summer time (`+02:00`), as the planner
/// names a day of its schedule: the same on any machine.
String _schoolDay(DateTime time) => PlannerService.formatDateTime(
  time,
  timeZoneOffset: const Duration(hours: 2),
).substring(0, 10);

/// The day a key of the schedule (a local date at midnight) names.
String _keyDay(DateTime day) =>
    PlannerService.formatDateTime(day).substring(0, 10);

Map<String, dynamic> _scheduleJson() =>
    jsonDecode(_schedule) as Map<String, dynamic>;

/// The days of a schedule answer, to change for a made-up one.
Map<String, dynamic> _days(Map<String, dynamic> schedule) =>
    schedule['schedule'] as Map<String, dynamic>;

/// The workload of 6A1 on [day] of the captured schedule, to change.
Map<String, dynamic> _entry(Map<String, dynamic> schedule, String day) =>
    (_days(schedule)[day] as List).first as Map<String, dynamic>;

/// A week of 2026-10-05, Monday to Friday, in UTC (Belgian summer time).
final _monday = DateTime.utc(2026, 10, 4, 22);
final _friday = DateTime.utc(2026, 10, 9, 21, 59, 59);
const _weekQuery =
    'from=2026-10-04T22%3A00%3A00%2B00%3A00'
    '&to=2026-10-09T21%3A59%3A59%2B00%3A00';

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
  // Assignment types
  // ---------------------------------------------------------------------------

  group('PlannerService.parseAssignmentTypes', () {
    test('lists the school\'s types in the planner\'s order, with their '
        'abbreviation, timing and weight', () {
      final types = PlannerService.parseAssignmentTypes(jsonDecode(_types));

      expect(types.map((t) => t.abbreviation), [
        'GO',
        'GT',
        'KO',
        'KT',
        'MB',
        'V',
      ]);
      final ko = types[2];
      expect(ko.id, _koId);
      expect(ko.platformId, 4069);
      expect(ko.name, 'Kleine Overhoring');
      expect(ko.isVisible, isTrue);
      expect(ko.defaultTiming, 'deadline');
      expect(ko.weight, 0);
    });

    test('are the types the planned assignments name', () {
      final types = {
        for (final type in PlannerService.parseAssignmentTypes(
          jsonDecode(_types),
        ))
          type.id: type,
      };
      final assignments = PlannerService.parsePlannedElements(
        jsonDecode(_assignments),
      );

      for (final assignment in assignments) {
        final named = assignment.assignmentType!;
        expect(types[named.id]?.name, named.name);
        expect(types[named.id]?.abbreviation, named.abbreviation);
        // An assignment names its type without the platform ID.
        expect(named.platformId, isNull);
      }
    });

    test('no types is an empty list', () {
      expect(PlannerService.parseAssignmentTypes(<dynamic>[]), isEmpty);
    });

    test('an answer that is not a list, a type that is not an object, and a '
        'type without its ID are refused', () {
      expect(
        () => PlannerService.parseAssignmentTypes(<String, dynamic>{}),
        throwsA(_plannerError(contains('instead of a list'))),
      );
      expect(
        () => PlannerService.parseAssignmentTypes(['KO']),
        throwsA(_plannerError(contains('assignment type 0'))),
      );
      expect(
        () => PlannerService.parseAssignmentTypes([
          {'name': 'Kleine Overhoring'},
        ]),
        throwsA(_plannerError(contains('without its id'))),
      );
    });
  });

  group('PlannerService.getAssignmentTypes', () {
    test('GETs assignments/applicable-assignment-types of the lesson-content '
        'API', () async {
      final (server, planner) = await serve({'GET $_typesPath': _json(_types)});

      final types = await planner.getAssignmentTypes();

      expect(types, hasLength(6));
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, _typesPath);
      expect(request.rawQuery, isEmpty);
    });

    test(
      'an answer the service cannot use is a SmartschoolPlannerError',
      () async {
        for (final (answer, status) in [
          (_json(_badRequest, status: 400), 400),
          ((status: 200, body: _errorPage, contentType: 'text/html'), null),
          (_json('[{"id":'), null),
          (_json('{"types":[]}'), null),
        ]) {
          final (_, planner) = await serve({'GET $_typesPath': answer});
          await expectLater(
            planner.getAssignmentTypes(),
            throwsA(_plannerStatus(status)),
            reason: answer.body,
          );
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Assignments of classes
  // ---------------------------------------------------------------------------

  group('PlannerService.getAssignmentsOfGroups', () {
    test('POSTs the class as JSON to workload/planned-elements, with the '
        'period in the query', () async {
      final (server, planner) = await serve({
        'POST $_assignmentsPath': _json(_assignments),
      });

      await planner.getAssignmentsOfGroups(
        groupIds: ['4069_2001'],
        from: _monday,
        to: _friday,
      );

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _assignmentsPath);
      expect(request.rawQuery, _weekQuery);
      expect(request.rawQuery, isNot(contains('+')));
      expect(request.contentType, startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'users': <Object>[],
        'groups': ['4069_2001'],
        'courses': <Object>[],
      });
    });

    test('returns the assignments of every teacher in the planner\'s order, '
        'with their type and teacher', () async {
      final (_, planner) = await serve({
        'POST $_assignmentsPath': _json(_assignments),
      });

      final assignments = await planner.getAssignmentsOfGroups(
        groupIds: ['4069_2001'],
        from: _monday,
        to: _friday,
      );

      expect(
        assignments.map((a) => a.type),
        everyElement(PlannedElementType.assignment),
      );
      expect(
        assignments.map(
          (a) =>
              '${_schoolDay(a.period.from)} ${a.assignmentType!.abbreviation} '
              '${a.organiserUsers.single.name}',
        ),
        [
          '2026-10-06 KO Piet Peeters',
          '2026-10-05 GO Wim Willems',
          '2026-10-05 MB An Claes',
          '2026-10-05 KO An Claes',
        ],
      );
      final ko = assignments.first;
      expect(ko.name, 'Test: hoofdstuk 3');
      expect(ko.assignmentType!.id, _koId);
      expect(ko.period.deadline, isTrue);
      expect(
        ko.organiserUsers.single.calendar,
        PlannerCalendar.user('4069_1002_0'),
      );
      // An assignment of several classes names them all, also the classes
      // that were not asked for.
      expect(ko.participantGroups.map((g) => g.name), ['6B1', '6A1', '6C1']);
    });

    test('sends several classes in one request, each once', () async {
      final (server, planner) = await serve({
        'POST $_assignmentsPath': _json('[]'),
      });

      final assignments = await planner.getAssignmentsOfGroups(
        groupIds: {'4069_2001', '4069_2002'},
        from: _monday,
        to: _friday,
      );
      await planner.getAssignmentsOfGroups(
        groupIds: ['4069_2002', '4069_2001', '4069_2002'],
        from: _monday,
        to: _friday,
      );

      expect(assignments, isEmpty);
      expect(
        server.requests.map((r) => (jsonDecode(r.body) as Map)['groups']),
        [
          ['4069_2001', '4069_2002'],
          ['4069_2002', '4069_2001'],
        ],
      );
    });

    test('sends local dates in local time, each with its own offset', () async {
      final (server, planner) = await serve({
        'POST $_assignmentsPath': _json('[]'),
      });
      final from = DateTime(2026, 10, 5);
      final to = DateTime(2026, 11, 20, 23, 59, 59);

      await planner.getAssignmentsOfGroups(
        groupIds: ['4069_2001'],
        from: from,
        to: to,
      );

      final request = server.requests.single;
      expect(request.rawQuery, isNot(contains('+')));
      expect(request.query['from'], PlannerService.formatDateTime(from));
      expect(request.query['to'], PlannerService.formatDateTime(to));
    });

    test('refuses no classes, an ID that is not a group ID and a period that '
        'ends before it starts, before sending anything', () async {
      final (server, planner) = await serve({});

      for (final groupIds in [
        <String>[],
        ['2001'],
        [''],
        ['4069_2001', '6A1'],
        ['4069_20 01'],
      ]) {
        await expectLater(
          planner.getAssignmentsOfGroups(
            groupIds: groupIds,
            from: _monday,
            to: _friday,
          ),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'groupIds'),
          ),
          reason: '$groupIds',
        );
      }
      await expectLater(
        planner.getAssignmentsOfGroups(
          groupIds: ['4069_2001'],
          from: _friday,
          to: _monday,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'to')),
      );
      expect(server.requests, isEmpty);
    });

    test('an answer the service cannot use is a SmartschoolPlannerError with '
        'the status', () async {
      for (final (answer, status) in [
        (_json(_badRequest, status: 400), 400),
        ((status: 200, body: _errorPage, contentType: 'text/html'), null),
        (_json('{"elements":[]}'), null),
      ]) {
        final (_, planner) = await serve({'POST $_assignmentsPath': answer});
        await expectLater(
          planner.getAssignmentsOfGroups(
            groupIds: ['4069_2001'],
            from: _monday,
            to: _friday,
          ),
          throwsA(_plannerStatus(status)),
          reason: answer.body,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Workload per day
  // ---------------------------------------------------------------------------

  group('PlannerService.parseWorkloadSchedule', () {
    test('one entry per day, keyed by the local date at midnight, in date '
        'order', () {
      final schedule = PlannerService.parseWorkloadSchedule(_scheduleJson());

      expect(schedule.keys, [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 6),
        DateTime(2026, 10, 7),
        DateTime(2026, 10, 8),
        DateTime(2026, 10, 9),
      ]);
      expect(schedule.keys.map((d) => d.isUtc), everyElement(isFalse));
      expect(schedule.values.map((day) => day.single.group.id), [
        for (var i = 0; i < 5; i++) '4069_2001',
      ]);
    });

    test('the workload of a class: its group, the planner\'s figures as they '
        'are, and its setting', () {
      final schedule = PlannerService.parseWorkloadSchedule(_scheduleJson());
      final monday = schedule[DateTime(2026, 10, 5)]!.single;

      expect(monday.group.id, '4069_2001');
      expect(monday.group.name, '6A1');
      expect(monday.group.calendar, PlannerCalendar.group('4069_2001'));
      // Weight 0 on a day with three assignments: at the school seen live
      // the figures say nothing, and the library does not make them say
      // anything.
      expect(monday.weight, 0);
      expect(monday.concurrentWeight, 0);

      final setting = monday.setting!;
      expect(setting.id, 'b0000000-0000-4000-8000-000000000001');
      expect(setting.platformId, 4069);
      expect(setting.name, 'Geen limiet');
      expect(setting.color, 'aqua-500');
      expect(setting.limit!.value, -1);
      expect(setting.limit!.period, 'day');
      expect(setting.limit!.type, 'soft');
      expect(setting.allowedAssignmentTypes.map((t) => t.abbreviation), [
        'GO',
        'KO',
      ]);
      expect(setting.allowedAssignmentTypes.last.id, _koId);

      expect(monday.raw['workloadSetting'], isA<Map<String, dynamic>>());
      expect(() => monday.raw['weight'] = 1, throwsUnsupportedError);
    });

    test('figures that are not 0 and several classes are returned as they '
        'are (made up)', () {
      final json = _scheduleJson();
      final tuesday = _entry(json, '2026-10-06')
        ..['weight'] = 2.5
        ..['concurrentWeight'] = 3;
      final other = jsonDecode(jsonEncode(tuesday)) as Map<String, dynamic>;
      other['group'] = {
        'identifier': '4069_2002',
        'id': '4069_2002',
        'platformId': 4069,
        'name': '6A2',
        'type': 'K',
        'icon': 'briefcase',
        'sort': '6A2',
      };
      other['weight'] = '4';
      (_days(json)['2026-10-06'] as List).add(other);

      final day = PlannerService.parseWorkloadSchedule(
        json,
      )[DateTime(2026, 10, 6)]!;

      expect(day.map((w) => w.group.name), ['6A1', '6A2']);
      expect(day.map((w) => w.weight), [2.5, 4]);
      expect(day.map((w) => w.concurrentWeight), [3, 3]);
    });

    test('days the planner gives out of order come in date order (made '
        'up)', () {
      final days = _days(_scheduleJson());
      final reversed = {
        'schedule': {
          for (final key in days.keys.toList().reversed) key: days[key],
        },
      };

      expect(PlannerService.parseWorkloadSchedule(reversed).keys, [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 6),
        DateTime(2026, 10, 7),
        DateTime(2026, 10, 8),
        DateTime(2026, 10, 9),
      ]);
    });

    test('a day without classes, and a class without a setting or limit '
        '(made up)', () {
      final json = _scheduleJson();
      _days(json)['2026-10-07'] = <Object>[];
      _entry(json, '2026-10-08').remove('workloadSetting');
      (_entry(json, '2026-10-09')['workloadSetting'] as Map).remove('limit');

      final schedule = PlannerService.parseWorkloadSchedule(json);

      expect(schedule[DateTime(2026, 10, 7)], isEmpty);
      expect(schedule[DateTime(2026, 10, 8)]!.single.setting, isNull);
      expect(schedule[DateTime(2026, 10, 9)]!.single.setting!.limit, isNull);
    });

    test('an empty schedule is an empty map, also as an empty list', () {
      expect(
        PlannerService.parseWorkloadSchedule({'schedule': <String, dynamic>{}}),
        isEmpty,
      );
      expect(
        PlannerService.parseWorkloadSchedule({'schedule': <dynamic>[]}),
        isEmpty,
      );
    });

    test('an answer in an unknown shape is refused', () {
      expect(
        () => PlannerService.parseWorkloadSchedule(<dynamic>[]),
        throwsA(_plannerError(contains('instead of an object'))),
      );
      for (final schedule in [
        null,
        'x',
        <Object>[1],
      ]) {
        expect(
          () => PlannerService.parseWorkloadSchedule({'schedule': schedule}),
          throwsA(_plannerError(contains('the days of the workload'))),
          reason: '$schedule',
        );
      }
    });

    test('a day that is not a date is refused', () {
      for (final key in ['maandag', '2026-10-5', '2026-13-01', '2026-02-30']) {
        final json = _scheduleJson();
        _days(json)[key] = <Object>[];
        expect(
          () => PlannerService.parseWorkloadSchedule(json),
          throwsA(_plannerError(contains('"$key"'))),
          reason: key,
        );
      }
    });

    test('a day or a class in an unknown shape is refused', () {
      Map<String, dynamic> changed(void Function(Map<String, dynamic>) change) {
        final json = _scheduleJson();
        change(json);
        return json;
      }

      expect(
        () => PlannerService.parseWorkloadSchedule(
          changed((json) => _days(json)['2026-10-05'] = {'weight': 0}),
        ),
        throwsA(_plannerError(contains('the workload of 2026-10-05'))),
      );
      expect(
        () => PlannerService.parseWorkloadSchedule(
          changed((json) => _days(json)['2026-10-05'] = ['6A1']),
        ),
        throwsA(_plannerError(contains('group 0 of the workload'))),
      );
      expect(
        () => PlannerService.parseWorkloadSchedule(
          changed((json) => _entry(json, '2026-10-05').remove('group')),
        ),
        throwsA(_plannerError(contains('the group of a workload'))),
      );
      for (final key in ['weight', 'concurrentWeight']) {
        for (final value in [null, 'veel', true]) {
          expect(
            () => PlannerService.parseWorkloadSchedule(
              changed((json) => _entry(json, '2026-10-05')[key] = value),
            ),
            throwsA(_plannerError(contains('without a numeric $key'))),
            reason: '$key: $value',
          );
        }
      }
      expect(
        () => PlannerService.parseWorkloadSchedule(
          changed(
            (json) => (_entry(json, '2026-10-05')['workloadSetting'] as Map)
                .remove('id'),
          ),
        ),
        throwsA(_plannerError(contains('a workload setting without its id'))),
      );
      expect(
        () => PlannerService.parseWorkloadSchedule(
          changed(
            (json) =>
                ((_entry(json, '2026-10-05')['workloadSetting'] as Map)['limit']
                        as Map)
                    .remove('value'),
          ),
        ),
        throwsA(_plannerError(contains('without a numeric value'))),
      );
    });
  });

  group('PlannerService.getWorkloadSchedule', () {
    test('POSTs the class as JSON to workload/schedule, with the period in '
        'the query', () async {
      final (server, planner) = await serve({
        'POST $_schedulePath': _json(_schedule),
      });

      final schedule = await planner.getWorkloadSchedule(
        groupIds: ['4069_2001'],
        from: _monday,
        to: _friday,
      );

      expect(schedule, hasLength(5));
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _schedulePath);
      expect(request.rawQuery, _weekQuery);
      expect(request.contentType, startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'groups': ['4069_2001'],
      });
    });

    test('sends several classes in one request, each once', () async {
      final (server, planner) = await serve({
        'POST $_schedulePath': _json('{"schedule":[]}'),
      });

      final schedule = await planner.getWorkloadSchedule(
        groupIds: ['4069_2001', '4069_2002', '4069_2001'],
        from: _monday,
        to: _friday,
      );

      expect(schedule, isEmpty);
      expect(jsonDecode(server.requests.single.body), {
        'groups': ['4069_2001', '4069_2002'],
      });
    });

    test('refuses no classes, an ID that is not a group ID and a period that '
        'ends before it starts, before sending anything', () async {
      final (server, planner) = await serve({});

      await expectLater(
        planner.getWorkloadSchedule(groupIds: [], from: _monday, to: _friday),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.getWorkloadSchedule(
          groupIds: ['2001'],
          from: _monday,
          to: _friday,
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.getWorkloadSchedule(
          groupIds: ['4069_2001'],
          from: _friday,
          to: _monday,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });

    test('an answer the service cannot use is a SmartschoolPlannerError with '
        'the status', () async {
      for (final (answer, status) in [
        (_json(_badRequest, status: 400), 400),
        ((status: 200, body: _errorPage, contentType: 'text/html'), null),
        (_json('{"schedule":'), null),
        (_json('[]'), null),
      ]) {
        final (_, planner) = await serve({'POST $_schedulePath': answer});
        await expectLater(
          planner.getWorkloadSchedule(
            groupIds: ['4069_2001'],
            from: _monday,
            to: _friday,
          ),
          throwsA(_plannerStatus(status)),
          reason: answer.body,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Workload for one moment
  // ---------------------------------------------------------------------------

  group('PlannerService.calculateWorkload', () {
    test(
      'POSTs the period and the class as JSON to workload/calculate',
      () async {
        final (server, planner) = await serve({
          'POST $_calculatePath': _json(_calculated),
        });

        final workload = await planner.calculateWorkload(
          groupIds: ['4069_2001'],
          from: DateTime.utc(2026, 10, 6, 6, 30),
          to: DateTime.utc(2026, 10, 6, 7, 20),
        );

        final request = server.requests.single;
        expect(request.method, 'POST');
        expect(request.path, _calculatePath);
        expect(request.rawQuery, isEmpty);
        expect(request.contentType, startsWith('application/json'));
        expect(jsonDecode(request.body), {
          'period': {
            'dateTimeFrom': '2026-10-06T06:30:00+00:00',
            'dateTimeTo': '2026-10-06T07:20:00+00:00',
            'wholeDay': false,
            'deadline': true,
          },
          'participants': {
            'users': <Object>[],
            'groups': ['4069_2001'],
            'groupFilters': <String, Object>{},
          },
        });

        final sixA1 = workload.single;
        expect(sixA1.group.name, '6A1');
        expect(sixA1.weight, 0);
        expect(sixA1.concurrentWeight, 0);
        expect(sixA1.setting!.name, 'Geen limiet');
        expect(sixA1.setting!.allowedAssignmentTypes, hasLength(6));
      },
    );

    test('sends wholeDay and deadline as given, local dates with their '
        'offset, and several classes each once', () async {
      final (server, planner) = await serve({
        'POST $_calculatePath': _json('[]'),
      });
      final from = DateTime(2026, 11, 20);
      final to = DateTime(2026, 11, 20, 23, 59, 59);

      final workload = await planner.calculateWorkload(
        groupIds: ['4069_2001', '4069_2002', '4069_2002'],
        from: from,
        to: to,
        wholeDay: true,
        deadline: false,
      );

      expect(workload, isEmpty);
      final body = jsonDecode(server.requests.single.body) as Map;
      expect(body['period'], {
        'dateTimeFrom': PlannerService.formatDateTime(from),
        'dateTimeTo': PlannerService.formatDateTime(to),
        'wholeDay': true,
        'deadline': false,
      });
      expect((body['participants'] as Map)['groups'], [
        '4069_2001',
        '4069_2002',
      ]);
    });

    test('refuses no classes, an ID that is not a group ID and a period that '
        'ends before it starts, before sending anything', () async {
      final (server, planner) = await serve({});
      final from = DateTime.utc(2026, 10, 6, 6, 30);
      final to = DateTime.utc(2026, 10, 6, 7, 20);

      await expectLater(
        planner.calculateWorkload(groupIds: [], from: from, to: to),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.calculateWorkload(groupIds: ['6A1'], from: from, to: to),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        planner.calculateWorkload(groupIds: ['4069_2001'], from: to, to: from),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });

    test('an answer the service cannot use is a SmartschoolPlannerError with '
        'the status', () async {
      for (final (answer, status) in [
        (_json(_badRequest, status: 400), 400),
        ((status: 200, body: _errorPage, contentType: 'text/html'), null),
        (_json('{"schedule":{}}'), null),
        (_json('[1]'), null),
      ]) {
        final (_, planner) = await serve({'POST $_calculatePath': answer});
        await expectLater(
          planner.calculateWorkload(
            groupIds: ['4069_2001'],
            from: DateTime.utc(2026, 10, 6, 6, 30),
            to: DateTime.utc(2026, 10, 6, 7, 20),
          ),
          throwsA(_plannerStatus(status)),
          reason: answer.body,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The whole question
  // ---------------------------------------------------------------------------

  group('the tests of a class in a week', () {
    test('a class found by name: its assignments per day with their type, '
        'next to the planner\'s workload of each day', () async {
      final (server, planner) = await serve({
        'POST $_searchPath': _json(_searchClass),
        'GET $_typesPath': _json(_types),
        'POST $_assignmentsPath': _json(_assignments),
        'POST $_schedulePath': _json(_schedule),
      });

      final klas = (await planner.searchCalendars('6A'))
          .firstWhere((hit) => hit.kind == PlannerSearchResultKind.group)
          .calendar!;
      final types = {
        for (final type in await planner.getAssignmentTypes()) type.id: type,
      };
      final assignments = await planner.getAssignmentsOfGroups(
        groupIds: [klas.id],
        from: _monday,
        to: _friday,
      );
      final schedule = await planner.getWorkloadSchedule(
        groupIds: [klas.id],
        from: _monday,
        to: _friday,
      );

      // What a caller would put before the model: per day, the planner's
      // figures of the class and the assignments of that day.
      final week = {
        for (final MapEntry(key: day, value: load) in schedule.entries)
          _keyDay(day): {
            'weight': load.single.weight,
            'setting': load.single.setting!.name,
            'assignments': [
              for (final a in assignments)
                if (_schoolDay(a.period.from) == _keyDay(day))
                  '${types[a.assignmentType!.id]!.name} '
                      '(${a.organiserUsers.single.name})',
            ]..sort(),
          },
      };

      const free = {
        'weight': 0,
        'setting': 'Geen limiet',
        'assignments': <String>[],
      };
      expect(week, {
        '2026-10-05': {
          'weight': 0,
          'setting': 'Geen limiet',
          'assignments': [
            'Grote Overhoring (Wim Willems)',
            'Kleine Overhoring (An Claes)',
            'Meebrengen (An Claes)',
          ],
        },
        '2026-10-06': {
          'weight': 0,
          'setting': 'Geen limiet',
          'assignments': ['Kleine Overhoring (Piet Peeters)'],
        },
        '2026-10-07': free,
        '2026-10-08': free,
        '2026-10-09': free,
      });
      expect(types.keys, containsAll([_koId, _goId, _mbId]));
      expect(server.requests.map((r) => '${r.method} ${r.path}'), [
        'POST $_searchPath',
        'GET $_typesPath',
        'POST $_assignmentsPath',
        'POST $_schedulePath',
      ]);
      expect(
        server.requests
            .where((r) => r.path.startsWith('$_api/workload/'))
            .map((r) => r.rawQuery),
        everyElement(_weekQuery),
      );
    });
  });
}
