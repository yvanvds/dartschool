// Tests for issue #87: filling a lesson hour of the own planner with a lesson,
// editing it and clearing it again (`PlannerService.planLesson`,
// `renameElement`, `changePublicInfo`, `changePrivateInfo`, `clearLesson`):
// the first writes of the planner service.
//
// The answers below are trimmed captures of the live planner API, from the
// fill, edits and clear the developer tried in their own planner (with
// permission, cleared again) on 2026-10-02:
//   - GET  /planner/api/v1/planned-placeholders/{platformId}/{id}
//       (the empty lesson hour before the fill)
//   - POST .../planned-placeholders/{platformId}/{id}/replace/
//       planned-lessons/blanco -> 200 with the new lesson
//   - POST .../planned-lessons/{platformId}/{id}/rename, change-public-info,
//       change-private-info -> 200 with the lesson
//   - POST .../planned-elements/clear -> 200 with a timetable slot that has
//       a new ID; the lesson's detail is 404 afterwards
// with every name, picture, user, group, course, location and element ID
// and every free text replaced by obvious fakes ("Jan Janssens" is the
// authenticated user `4069_1001_0`, "Wim Willems" a colleague, classes
// `4069_2001`/`4069_2002`, room `101`, "Springfield Academy"). The
// capabilities are trimmed to the flags that matter. The answers that the
// planner did not give live (an own assignment, a slot with participant
// roles, unusable answers) are made up from those.
//
// The fake Smartschool answers only the requests each test scripts (and the
// login chain), and fails the test on any other request: the bulk endpoints
// (`planned-elements/trash`, `.../delete`, `.../bulk/...`,
// `.../replace-with-...`, the period trash), `DELETE` and a second fill or
// clear never get an answer.
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
const _assignmentId = 'e0000000-0000-4000-8000-000000000013';

const _api = '/planner/api/v1';
const _slotPath = '$_api/planned-placeholders/4069/$_slotId';
const _fillPath = '$_slotPath/replace/planned-lessons/blanco';
const _lessonPath = '$_api/planned-lessons/4069/$_lessonId';
const _assignmentPath = '$_api/planned-assignments/4069/$_assignmentId';
const _clearPath = '$_api/planned-elements/clear';
const _ownWeekPath = '$_api/planned-elements/user/$_me';

/// The requests, as the fake logs them.
const _readSlot = 'GET $_slotPath';
const _fill = 'POST $_fillPath';
const _readLesson = 'GET $_lessonPath';
const _rename = 'POST $_lessonPath/rename';
const _changePublic = 'POST $_lessonPath/change-public-info';
const _changePrivate = 'POST $_lessonPath/change-private-info';
const _clear = 'POST $_clearPath';

/// The login chain that a refused request starts (see
/// session_login_chain_retry_test.dart).
const _login = [
  'GET /login',
  'POST /login',
  'GET /',
  'GET /2fa/api/v1/config',
  'POST /2fa/api/v1/google-authenticator',
];

/// An empty lesson hour of the own planner on Friday 20 November 2026 (winter
/// time, `+01:00`), classes 6A1 and 6A2, course informatica, room 101: no
/// name, and it can be filled (`canUserReplace`).
const _slot = r'''
{"id":"e0000000-0000-5000-8000-000000000010","platformId":4069,"period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"labels":[],"presenceSaved":false,"showPresenceChoices":false,"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"isParticipant":false,"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserReplace":true,"canUserReschedule":false,"canUserChangeParticipants":true,"canUserChangeLocations":true,"canUserRename":false,"canUserChangeIcon":false,"canUserSeeProperties":{"id":true,"platformId":true,"period":true,"organisers":true,"participants":true,"courses":true,"locations":true,"plannedElementType":true}},"plannedElementType":"planned-placeholders","onlineSession":null,"reservations":[],"sort":"20261120111000_8_6A1_","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000010","to":"f0000000-0000-5000-8000-000000000011"}}
''';

/// The planner's answer to the fill: the new lesson, with a new ID, in the
/// slot's period, with its classes, course and room (the planner escapes `<`
/// and `/` in its HTML, as here; `info` follows `privateInfo`).
const _lesson = r'''
{"id":"e0000000-0000-4000-8000-000000000011","platformId":4069,"name":"Lussen: for en while","icon":"document_observation","info":"<p>Oefening 3 overslaan<\/p>","privateInfo":"<p>Oefening 3 overslaan<\/p>","publicInfo":"<p>Breng je laptop mee<\/p>","period":{"dateTimeFrom":"2026-11-20T11:10:00+01:00","dateTimeTo":"2026-11-20T12:00:00+01:00","wholeDay":false,"deadline":false},"organisers":{"users":[{"id":"4069_1001_0","pictureHash":"initials_JJ","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Jan Janssens","startingWithLastName":"Janssens Jan"},"sort":"janssens-jan","deleted":false}],"groups":[]},"participants":{"users":[],"groups":[{"identifier":"4069_2001","id":"4069_2001","platformId":4069,"name":"6A1","type":"K","icon":"briefcase","sort":"6A1"},{"identifier":"4069_2002","id":"4069_2002","platformId":4069,"name":"6A2","type":"K","icon":"briefcase","sort":"6A2"}],"userRoles":[],"groupFilters":{"filters":[],"additionalUsers":[]}},"miniDBItems":[],"labels":[],"attachments":[],"courses":[{"id":"c0000000-0000-4000-8000-000000000005","platformId":4069,"name":"informatica","scheduleCodes":["INFO"],"icon":"schoolbord","courseCluster":{"id":4,"name":"Informatica"},"isVisible":true}],"courseLinks":[],"locations":[{"id":"10000000-0000-4000-8000-000000000101","platformId":4069,"platformName":"Springfield Academy","number":"","title":"101","icon":"","type":"mini-db-item","selectable":true}],"goals":[],"weblinks":[],"partnerWeblinks":[],"deeplinks":[],"reservations":[],"isParticipant":false,"albums":[],"capabilities":{"canUserTrash":false,"canUserDelete":false,"canUserEdit":true,"canUserChangePrivateInfo":true,"canUserChangePublicInfo":true,"canUserReplace":true,"canUserReschedule":false,"canUserRename":true,"canUserChangeIcon":true,"canUserSaveInSourceModule":true,"canUserSeeProperties":{"id":true,"platformId":true,"name":true,"icon":true,"info":true,"privateInfo":true,"publicInfo":true,"period":true,"organisers":true,"participants":true,"courses":true,"locations":true,"plannedElementType":true}},"presenceSaved":false,"showPresenceChoices":false,"onlineSession":null,"plannedElementType":"planned-lessons","plannedToDos":[],"sort":"20261120111000_4_6A1_Lussen: for en while","unconfirmed":false,"pinned":false,"color":"aqua-200","reminders":[],"joinIds":{"from":"f0000000-0000-5000-8000-000000000010","to":"f0000000-0000-5000-8000-000000000011"}}
''';

/// The planner's answer to the clear: the lesson hour is a timetable slot
/// again, the same as before the fill but for its ID.
final _cleared = _with(_slot, changes: {'id': _newSlotId});

/// The values the tests fill the slot with: those of [_lesson].
const _name = 'Lussen: for en while';
const _publicInfo = '<p>Breng je laptop mee</p>';
const _privateInfo = '<p>Oefening 3 overslaan</p>';

/// The colleague (Wim Willems) as an organiser.
final _colleague =
    jsonDecode(r'''
{"id":"4069_1003_0","pictureHash":"initials_WW","pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_WW\/plain\/1\/res\/128","description":{"startingWithFirstName":"","startingWithLastName":""},"name":{"startingWithFirstName":"Wim Willems","startingWithLastName":"Willems Wim"},"sort":"willems-wim","deleted":false}
''')
        as Map<String, dynamic>;

/// [json], an element, organised by the colleague instead.
String _byColleague(String json) => _with(
  json,
  changes: {
    'organisers': {
      'users': [_colleague],
      'groups': <Object>[],
    },
  },
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

/// The body the web client sends to fill [_slot] (as tried live), with the
/// lesson's [name], info and [icon].
Map<String, Object?> _fillBody({
  String name = _name,
  String publicInfo = _publicInfo,
  String privateInfo = _privateInfo,
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
  'name': name,
  'info': '',
  'publicInfo': publicInfo,
  'privateInfo': privateInfo,
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
typedef _Request = ({String label, Object? body, String contentType});

/// A Smartschool whose session is accepted, that answers the planner
/// requests of [answers] (by label, `METHOD path`; a list is answered in
/// turn, its last answer for every later request), the reads the client
/// makes for the authenticated user, and the login chain; and fails the test
/// on any other request.
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

  /// The labels of the requests to the planner, in order.
  List<String> get plannerLog => [
    for (final label in log)
      if (label.contains('/planner/')) label,
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
    final path = options.uri.path;
    final label = '${options.method} $path';
    final text = await _read(requestStream);
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    requests.add((
      label: label,
      body: body,
      contentType: options.contentType ?? '',
    ));

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

/// A check before the write refused it: nothing was sent.
Matcher _refused(Object? message) => isA<SmartschoolPlannerWriteRefusedError>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.message, 'message', contains('Nothing was sent'));

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
    _Answer? Function(String label, Object? body)? respond,
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

  // ---------------------------------------------------------------------------
  // planLesson
  // ---------------------------------------------------------------------------

  group('PlannerService.planLesson', () {
    test('reads the slot again, then fills it once with the body the web '
        'client sends, and returns the lesson', () async {
      final (server, planner) = await serve({
        _readSlot: [_json(_slot)],
        _fill: [_json(_lesson)],
      });

      final lesson = await planner.planLesson(
        placeholder: _listed(_slot),
        name: _name,
        publicInfo: _publicInfo,
        privateInfo: _privateInfo,
      );

      expect(server.plannerLog, [_readSlot, _fill]);
      // The route of a blank lesson ("/blanco"), as JSON with the slot's
      // organisers, classes, course, period and room, IDs as strings.
      expect(server.bodyOf(_fill), _fillBody());
      expect(
        server.requests.singleWhere((r) => r.label == _fill).contentType,
        contains('application/json'),
      );

      expect(lesson, isA<PlannedElementDetail>());
      expect(lesson.id, _lessonId);
      expect(lesson.type, PlannedElementType.lesson);
      expect(lesson.name, _name);
      expect(lesson.publicInfo, _publicInfo);
      expect(lesson.privateInfo, _privateInfo);
      expect(lesson.info, _privateInfo);
      expect(lesson.participantGroups.map((g) => g.name), ['6A1', '6A2']);
      expect(lesson.locations.single.title, '101');
      expect(
        lesson.period.from.isAtSameMomentAs(DateTime.utc(2026, 11, 20, 10, 10)),
        isTrue,
      );
    });

    test('reads the authenticated user before the slot', () async {
      final (server, planner) = await serve({
        _readSlot: [_json(_slot)],
        _fill: [_json(_lesson)],
      });

      await planner.planLesson(
        placeholder: _listed(_slot),
        name: _name,
        publicInfo: _publicInfo,
        privateInfo: _privateInfo,
      );

      expect(server.log, [
        'GET /course-list/api/v1/courses',
        'GET /',
        _readSlot,
        _fill,
      ]);
    });

    test('fills the body from the slot as read again, not from the listed '
        'element', () async {
      // The list showed the slot without a room (an older state); the detail
      // has room 101 now.
      final (server, planner) = await serve({
        _readSlot: [_json(_slot)],
        _fill: [_json(_lesson)],
      });

      await planner.planLesson(
        placeholder: _listed(_with(_slot, changes: {'locations': <Object>[]})),
        name: _name,
        publicInfo: _publicInfo,
        privateInfo: _privateInfo,
      );

      expect(server.bodyOf(_fill), _fillBody());
    });

    test('sends the name without the white space around it, empty info by '
        'default, and the icon asked for', () async {
      final (server, planner) = await serve({
        _readSlot: [_json(_slot)],
        _fill: [
          _json(
            _with(
              _lesson,
              changes: {
                'publicInfo': '',
                'privateInfo': '',
                'info': '',
                'icon': 'book',
              },
            ),
          ),
        ],
      });

      final lesson = await planner.planLesson(
        placeholder: _listed(_slot),
        name: '  $_name\n',
        icon: 'book',
      );

      expect(
        server.bodyOf(_fill),
        _fillBody(publicInfo: '', privateInfo: '', icon: 'book'),
      );
      expect(lesson.name, _name);
    });

    test('the default icon is the one of the lessons seen live', () {
      expect(PlannerService.defaultLessonIcon, 'document_observation');
    });

    group('refuses before anything is sent', () {
      test(
        "a colleague's slot, even one the planner lets the user fill",
        () async {
          final (server, planner) = await serve({
            _readSlot: [_json(_byColleague(_slot))],
          });

          await expectLater(
            planner.planLesson(placeholder: _listed(_slot), name: _name),
            throwsA(
              _refused(
                allOf(
                  contains('not in your own planner'),
                  contains('Wim Willems (4069_1003_0)'),
                  contains('not by $_me'),
                ),
              ),
            ),
          );
          expect(server.plannerLog, [_readSlot]);
        },
      );

      test('a slot the planner does not let the user fill '
          '(canUserReplace)', () async {
        final (server, planner) = await serve({
          _readSlot: [
            _json(_with(_slot, capabilities: {'canUserReplace': false})),
          ],
        });

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(_refused(contains('canUserReplace not set'))),
        );
        expect(server.plannerLog, [_readSlot]);
      });

      test('a slot without capabilities', () async {
        final slot = jsonDecode(_slot) as Map<String, dynamic>
          ..remove('capabilities');
        final (server, planner) = await serve({
          _readSlot: [_json(jsonEncode(slot))],
        });

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(_refused(contains('canUserReplace not set'))),
        );
        expect(server.plannerLog, [_readSlot]);
      });

      test('a slot that is no longer in the period it was read with', () async {
        final (server, planner) = await serve({
          _readSlot: [
            _json(_with(_slot, changes: {'period': _period('12:00', '12:50')})),
          ],
        });

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(_refused(contains('no longer in the period'))),
        );
        expect(server.plannerLog, [_readSlot]);
      });

      test('a slot that is no longer a slot (filled or cleared since): the '
          'planner no longer has it', () async {
        final (server, planner) = await serve({
          _readSlot: [_json(_notFound, status: 404)],
        });

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(
            isA<SmartschoolPlannedElementNotFoundError>()
                .having(
                  (e) => e.elementType,
                  'elementType',
                  'planned-placeholders',
                )
                .having((e) => e.elementId, 'elementId', _slotId),
          ),
        );
        expect(server.plannerLog, [_readSlot]);
      });

      test('a slot with participant roles or group filters', () async {
        final participants =
            (jsonDecode(_slot) as Map<String, dynamic>)['participants']
                as Map<String, dynamic>;
        for (final changed in [
          {
            ...participants,
            'userRoles': [
              {'id': 'leerling'},
            ],
          },
          {
            ...participants,
            'groupFilters': {
              'filters': [
                {'type': 'course'},
              ],
              'additionalUsers': <Object>[],
            },
          },
          {
            ...participants,
            'groupFilters': {
              'filters': <Object>[],
              'additionalUsers': ['4069_1004_0'],
            },
          },
        ]) {
          final (server, planner) = await serve({
            _readSlot: [
              _json(_with(_slot, changes: {'participants': changed})),
            ],
          });

          await expectLater(
            planner.planLesson(placeholder: _listed(_slot), name: _name),
            throwsA(_refused(contains('participant roles or group filters'))),
          );
          expect(server.plannerLog, [_readSlot]);
        }
      });

      test('an element that is not a timetable slot, an empty name or an '
          'empty icon: an ArgumentError, before any request', () async {
        final (server, planner) = await serve({});

        await expectLater(
          () => planner.planLesson(placeholder: _listed(_lesson), name: _name),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('not a timetable slot'),
            ),
          ),
        );
        expect(
          () => planner.planLesson(placeholder: _listed(_slot), name: ' \n'),
          throwsArgumentError,
        );
        expect(
          () => planner.planLesson(
            placeholder: _listed(_slot),
            name: _name,
            icon: '',
          ),
          throwsArgumentError,
        );
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the fill is unconfirmed, and the '
        'fill is not sent again', () {
      final answers = <String, (_Answer, Object?, Object?)>{
        'HTTP 500': (
          _json(_errorPage, status: 500),
          contains('cannot be used'),
          500,
        ),
        'HTTP 400': (
          _json(
            '{"status":400,"title":"Bad Request","detail":"","type":""}',
            status: 400,
          ),
          contains('HTTP 400'),
          400,
        ),
        'an HTML page': (_json(_errorPage), contains('HTML page'), 200),
        'not an element': (_json('[]'), contains('cannot be used'), 200),
        'a timetable slot': (
          _json(_slot),
          contains('a planned-placeholders instead of a lesson'),
          200,
        ),
        'another name': (
          _json(_with(_lesson, changes: {'name': 'Iets anders'})),
          contains('named "Iets anders" instead of "$_name"'),
          200,
        ),
        'another period': (
          _json(_with(_lesson, changes: {'period': _period('12:00', '12:50')})),
          contains('in another period'),
          200,
        ),
      };
      for (final MapEntry(key: name, value: (answer, message, status))
          in answers.entries) {
        test(name, () async {
          final (server, planner) = await serve({
            _readSlot: [_json(_slot)],
            _fill: [answer],
          });

          await expectLater(
            planner.planLesson(
              placeholder: _listed(_slot),
              name: _name,
              publicInfo: _publicInfo,
              privateInfo: _privateInfo,
            ),
            throwsA(
              _unconfirmed(
                allOf(contains('planLesson'), contains('fill'), message),
                statusCode: status,
              ),
            ),
          );
          expect(server.plannerLog, [_readSlot, _fill]);
        });
      }

      test('the connection drops after the fill went out', () async {
        final (server, planner) = await serve(
          {
            _readSlot: [_json(_slot)],
          },
          failures: {_fill: _dropped},
        );

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(
            _unconfirmed(
              contains('no answer came in'),
              statusCode: isNull,
              cause: isA<SmartschoolConnectionError>(),
            ),
          ),
        );
        expect(server.plannerLog, [_readSlot, _fill]);
      });

      test('no second fill after a failure: calling again reads the slot, '
          'which the fill took', () async {
        final (server, planner) = await serve({
          _readSlot: [_json(_slot), _json(_notFound, status: 404)],
          _fill: [_json(_errorPage, status: 500)],
        });

        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(isA<SmartschoolPlannerSaveUnconfirmedError>()),
        );
        await expectLater(
          planner.planLesson(placeholder: _listed(_slot), name: _name),
          throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
        );
        expect(server.plannerLog, [_readSlot, _fill, _readSlot]);
      });
    });

    test('a session refused for the fill is not retried after logging in '
        'again: no login, no second fill', () async {
      final (server, planner) = await serve({
        _readSlot: [_json(_slot)],
        _fill: [_toLogin, _json(_lesson)],
      });

      await expectLater(
        planner.planLesson(placeholder: _listed(_slot), name: _name),
        throwsA(_notRetried),
      );
      expect(server.log, isNot(contains('GET /login')));
      expect(server.plannerLog, [_readSlot, _fill]);
    });
  });

  // ---------------------------------------------------------------------------
  // renameElement, changePublicInfo, changePrivateInfo
  // ---------------------------------------------------------------------------

  group('the edits', () {
    test('renameElement reads the element again, sends its new name to '
        '{type}/{platformId}/{id}/rename and returns the element', () async {
      const newName = 'Lussen: for, while en break';
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
        _rename: [
          _json(_with(_lesson, changes: {'name': newName})),
        ],
      });

      final renamed = await planner.renameElement(
        _listed(_lesson),
        '  $newName ',
      );

      expect(server.plannerLog, [_readLesson, _rename]);
      expect(server.bodyOf(_rename), {'newName': newName});
      expect(renamed.id, _lessonId);
      expect(renamed.name, newName);
    });

    test(
      'changePublicInfo sends the HTML as given, to change-public-info',
      () async {
        const html = '<p>Breng je laptop <strong>opgeladen</strong> mee</p>';
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _changePublic: [
            _json(_with(_lesson, changes: {'publicInfo': html})),
          ],
        });

        final changed = await planner.changePublicInfo(_listed(_lesson), html);

        expect(server.plannerLog, [_readLesson, _changePublic]);
        expect(server.bodyOf(_changePublic), {'newInfo': html});
        expect(changed.publicInfo, html);
        expect(changed.privateInfo, _privateInfo);
      },
    );

    test('changePrivateInfo sends the HTML as given, to change-private-info; '
        'info follows', () async {
      const html = '<p>Oefening 3 en 4 overslaan</p>';
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
        _changePrivate: [
          _json(_with(_lesson, changes: {'privateInfo': html, 'info': html})),
        ],
      });

      final changed = await planner.changePrivateInfo(_listed(_lesson), html);

      expect(server.plannerLog, [_readLesson, _changePrivate]);
      expect(server.bodyOf(_changePrivate), {'newInfo': html});
      expect(changed.privateInfo, html);
      expect(changed.info, html);
      expect(changed.publicInfo, _publicInfo);
    });

    test('an info can be emptied', () async {
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
        _changePublic: [
          _json(_with(_lesson, changes: {'publicInfo': ''})),
        ],
      });

      final changed = await planner.changePublicInfo(_listed(_lesson), '');

      expect(server.bodyOf(_changePublic), {'newInfo': ''});
      expect(changed.publicInfo, '');
    });

    test('the edits work on any element type, at its own route: an own '
        'assignment', () async {
      final assignment = _with(
        _lesson,
        changes: {
          'id': _assignmentId,
          'plannedElementType': 'planned-assignments',
          'name': 'Test: lussen',
          'icon': 'flags_red_yellow',
          'assignmentType': {
            'id': 'a0000000-0000-4000-8000-000000000001',
            'name': 'Kleine Overhoring',
            'abbreviation': 'KO',
          },
          'period': {..._period('11:10', '12:00'), 'deadline': true},
        },
      );
      final (server, planner) = await serve({
        'GET $_assignmentPath': [_json(assignment)],
        'POST $_assignmentPath/rename': [
          _json(_with(assignment, changes: {'name': 'Test: lussen (H3)'})),
        ],
      });

      final renamed = await planner.renameElement(
        _listed(assignment),
        'Test: lussen (H3)',
      );

      expect(server.plannerLog, [
        'GET $_assignmentPath',
        'POST $_assignmentPath/rename',
      ]);
      expect(renamed.type, PlannedElementType.assignment);
      expect(renamed.name, 'Test: lussen (H3)');
    });

    test('a value the element has already is not sent', () async {
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
      });

      final same = await planner.renameElement(_listed(_lesson), _name);
      final samePublic = await planner.changePublicInfo(
        _listed(_lesson),
        _publicInfo,
      );
      final samePrivate = await planner.changePrivateInfo(
        _listed(_lesson),
        _privateInfo,
      );

      expect(same.name, _name);
      expect(samePublic.publicInfo, _publicInfo);
      expect(samePrivate.privateInfo, _privateInfo);
      expect(server.plannerLog, [_readLesson, _readLesson, _readLesson]);
    });

    test('a refused session is retried once after logging in again: the '
        'change sets a value', () async {
      const newName = 'Lussen: for, while en break';
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
        _rename: [
          _toLogin,
          _json(_with(_lesson, changes: {'name': newName})),
        ],
      });

      final renamed = await planner.renameElement(_listed(_lesson), newName);

      expect(renamed.name, newName);
      expect(server.log.sublist(server.log.indexOf(_rename)), [
        _rename,
        ..._login,
        _rename,
      ]);
      expect(
        [
          for (final r in server.requests)
            if (r.label == _rename) r.body,
        ],
        [
          {'newName': newName},
          {'newName': newName},
        ],
      );
    });

    group('refuse before anything is sent', () {
      final edits =
          <String, Future<PlannedElementDetail> Function(PlannerService)>{
            'renameElement': (p) => p.renameElement(_listed(_lesson), 'Nieuw'),
            'changePublicInfo': (p) =>
                p.changePublicInfo(_listed(_lesson), '<p>Nieuw</p>'),
            'changePrivateInfo': (p) =>
                p.changePrivateInfo(_listed(_lesson), '<p>Nieuw</p>'),
          };
      final flags = {
        'renameElement': 'canUserRename',
        'changePublicInfo': 'canUserChangePublicInfo',
        'changePrivateInfo': 'canUserChangePrivateInfo',
      };
      for (final MapEntry(key: name, value: edit) in edits.entries) {
        test("$name: a colleague's element, even one the planner lets the "
            'user change', () async {
          final (server, planner) = await serve({
            _readLesson: [_json(_byColleague(_lesson))],
          });

          await expectLater(
            edit(planner),
            throwsA(
              _refused(
                allOf(contains(name), contains('not in your own planner')),
              ),
            ),
          );
          expect(server.plannerLog, [_readLesson]);
        });

        test('$name: an element the planner does not let the user edit '
            '(canUserEdit)', () async {
          final (server, planner) = await serve({
            _readLesson: [
              _json(_with(_lesson, capabilities: {'canUserEdit': false})),
            ],
          });

          await expectLater(
            edit(planner),
            throwsA(_refused(contains('canUserEdit not set'))),
          );
          expect(server.plannerLog, [_readLesson]);
        });

        test('$name: an element the planner does not let the user change so '
            '(${flags[name]})', () async {
          final (server, planner) = await serve({
            _readLesson: [
              _json(_with(_lesson, capabilities: {flags[name]!: false})),
            ],
          });

          await expectLater(
            edit(planner),
            throwsA(_refused(contains('${flags[name]} not set'))),
          );
          expect(server.plannerLog, [_readLesson]);
        });

        test('$name: an element the planner no longer has', () async {
          final (server, planner) = await serve({
            _readLesson: [_json(_notFound, status: 404)],
          });

          await expectLater(
            edit(planner),
            throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
          );
          expect(server.plannerLog, [_readLesson]);
        });
      }

      test('a timetable slot cannot be renamed (canUserRename)', () async {
        final (server, planner) = await serve({
          _readSlot: [_json(_slot)],
        });

        await expectLater(
          planner.renameElement(_listed(_slot), 'Nieuw'),
          throwsA(_refused(contains('canUserRename not set'))),
        );
        expect(server.plannerLog, [_readSlot]);
      });

      test('an empty new name: an ArgumentError, before any request', () async {
        final (server, planner) = await serve({});

        await expectLater(
          () => planner.renameElement(_listed(_lesson), '   '),
          throwsArgumentError,
        );
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the edit is unconfirmed', () {
      test('another name', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _rename: [_json(_lesson)],
        });

        await expectLater(
          planner.renameElement(_listed(_lesson), 'Nieuw'),
          throwsA(
            _unconfirmed(
              allOf(contains('renameElement'), contains('the name "$_name"')),
              statusCode: 200,
            ),
          ),
        );
        expect(server.plannerLog, [_readLesson, _rename]);
      });

      test('another info text', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _changePrivate: [_json(_lesson)],
        });

        await expectLater(
          planner.changePrivateInfo(_listed(_lesson), '<p>Nieuw</p>'),
          throwsA(_unconfirmed(contains('the privateInfo'))),
        );
      });

      test('another element', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _rename: [
            _json(_with(_lesson, changes: {'id': _assignmentId, 'name': 'X'})),
          ],
        });

        await expectLater(
          planner.renameElement(_listed(_lesson), 'X'),
          throwsA(_unconfirmed(contains('element $_assignmentId'))),
        );
      });

      test('HTTP 403', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _changePublic: [
            _json(
              '{"status":403,"title":"Forbidden","detail":"","type":""}',
              status: 403,
            ),
          ],
        });

        await expectLater(
          planner.changePublicInfo(_listed(_lesson), '<p>Nieuw</p>'),
          throwsA(
            _unconfirmed(
              contains('HTTP 403'),
              statusCode: 403,
              cause: isA<SmartschoolPlannerError>(),
            ),
          ),
        );
        expect(server.plannerLog, [_readLesson, _changePublic]);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // clearLesson
  // ---------------------------------------------------------------------------

  group('PlannerService.clearLesson', () {
    test('reads the lesson again, clears it once and returns the slot, which '
        'has a new ID', () async {
      final (server, planner) = await serve({
        _readLesson: [_json(_lesson)],
        _clear: [_json(_cleared)],
      });

      final slot = await planner.clearLesson(_listed(_lesson));

      expect(server.plannerLog, [_readLesson, _clear]);
      expect(server.bodyOf(_clear), {
        'type': 'planned-lessons',
        'elementId': _lessonId,
        'elementPlatformId': 4069,
      });
      expect(slot.type, PlannedElementType.placeholder);
      expect(slot.id, _newSlotId);
      expect(slot.name, isNull);
      expect(slot.participantGroups.map((g) => g.name), ['6A1', '6A2']);
      expect(slot.courses.single.name, 'informatica');
      expect(slot.locations.single.title, '101');
      expect(slot.capabilities.canReplace, isTrue);
    });

    group('refuses before anything is sent', () {
      test(
        "a colleague's lesson, even one the planner lets the user edit",
        () async {
          final (server, planner) = await serve({
            _readLesson: [_json(_byColleague(_lesson))],
          });

          await expectLater(
            planner.clearLesson(_listed(_lesson)),
            throwsA(_refused(contains('not in your own planner'))),
          );
          expect(server.plannerLog, [_readLesson]);
        },
      );

      test('a lesson the planner does not let the user edit '
          '(canUserEdit)', () async {
        final (server, planner) = await serve({
          _readLesson: [
            _json(_with(_lesson, capabilities: {'canUserEdit': false})),
          ],
        });

        await expectLater(
          planner.clearLesson(_listed(_lesson)),
          throwsA(_refused(contains('canUserEdit not set'))),
        );
        expect(server.plannerLog, [_readLesson]);
      });

      for (final flag in ['canUserTrash', 'canUserDelete']) {
        test('a lesson the planner lets the user trash or delete ($flag): '
            'not a lesson in a timetable hour', () async {
          final (server, planner) = await serve({
            _readLesson: [
              _json(_with(_lesson, capabilities: {flag: true})),
            ],
          });

          await expectLater(
            planner.clearLesson(_listed(_lesson)),
            throwsA(_refused(allOf(contains(flag), contains('timetable')))),
          );
          expect(server.plannerLog, [_readLesson]);
        });
      }

      test('a lesson the planner no longer has', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_notFound, status: 404)],
        });

        await expectLater(
          planner.clearLesson(_listed(_lesson)),
          throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
        );
        expect(server.plannerLog, [_readLesson]);
      });

      test('an element that is not a lesson: an ArgumentError, before any '
          'request', () async {
        final (server, planner) = await serve({});

        await expectLater(
          () => planner.clearLesson(_listed(_slot)),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('not a lesson'),
            ),
          ),
        );
        expect(server.requests, isEmpty);
      });
    });

    group('an answer that does not confirm the clear is unconfirmed, and the '
        'clear is not sent again', () {
      final answers = <String, (_Answer, Object?)>{
        'HTTP 500': (_json(_errorPage, status: 500), contains('HTTP 500')),
        'the lesson': (
          _json(_lesson),
          contains('a planned-lessons instead of a timetable slot'),
        ),
        'a slot in another period': (
          _json(
            _with(_cleared, changes: {'period': _period('12:00', '12:50')}),
          ),
          contains('another period'),
        ),
        "a colleague's slot": (
          _json(_byColleague(_cleared)),
          contains('not organised by $_me'),
        ),
      };
      for (final MapEntry(key: name, value: (answer, message))
          in answers.entries) {
        test(name, () async {
          final (server, planner) = await serve({
            _readLesson: [_json(_lesson)],
            _clear: [answer],
          });

          await expectLater(
            planner.clearLesson(_listed(_lesson)),
            throwsA(
              _unconfirmed(
                allOf(
                  contains('clearLesson'),
                  message,
                  contains('404 once it was cleared'),
                ),
              ),
            ),
          );
          expect(server.plannerLog, [_readLesson, _clear]);
        });
      }

      test('the connection drops after the clear went out', () async {
        final (server, planner) = await serve(
          {
            _readLesson: [_json(_lesson)],
          },
          failures: {_clear: _dropped},
        );

        await expectLater(
          planner.clearLesson(_listed(_lesson)),
          throwsA(
            _unconfirmed(
              contains('no answer came in'),
              cause: isA<SmartschoolConnectionError>(),
            ),
          ),
        );
        expect(server.plannerLog, [_readLesson, _clear]);
      });

      test('a session refused for the clear is not retried after logging in '
          'again', () async {
        final (server, planner) = await serve({
          _readLesson: [_json(_lesson)],
          _clear: [_toLogin, _json(_cleared)],
        });

        await expectLater(
          planner.clearLesson(_listed(_lesson)),
          throwsA(_notRetried),
        );
        expect(server.log, isNot(contains('GET /login')));
        expect(server.plannerLog, [_readLesson, _clear]);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // The whole flow
  // ---------------------------------------------------------------------------

  test('the flow of the issue against a planner that keeps its state: find '
      'an empty hour in the own week, fill it, edit it, clear it, and find '
      'the hour empty again', () async {
    // A planner with one lesson hour in the own week, that changes as the
    // live planner did: the fill takes the slot (its detail is 404) and
    // makes a lesson, the edits change the lesson, the clear takes the
    // lesson and makes a slot with a new ID.
    String? slot = _slot;
    String? lesson;

    _Answer? planner(String label, Object? body) {
      final slotId = slot == null
          ? null
          : (jsonDecode(slot!) as Map<String, dynamic>)['id'];
      switch (label) {
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
        case _fill:
          expect(slotId, _slotId, reason: 'only the slot that exists');
          final fill = body! as Map<String, dynamic>;
          lesson = _with(
            _lesson,
            changes: {
              'name': fill['name'],
              'publicInfo': fill['publicInfo'],
              'privateInfo': fill['privateInfo'],
              'info': fill['privateInfo'],
              'icon': fill['icon'],
            },
          );
          slot = null;
          return _json(lesson!);
        case _rename:
          lesson = _with(
            lesson!,
            changes: {'name': (body! as Map<String, dynamic>)['newName']},
          );
          return _json(lesson!);
        case _changePublic:
          lesson = _with(
            lesson!,
            changes: {'publicInfo': (body! as Map<String, dynamic>)['newInfo']},
          );
          return _json(lesson!);
        case _changePrivate:
          final info = (body! as Map<String, dynamic>)['newInfo'];
          lesson = _with(lesson!, changes: {'privateInfo': info, 'info': info});
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

    final (server, service) = await serve({}, respond: planner);
    final week = await service.getPlannedElements(
      await service.ownCalendar(),
      from: DateTime.utc(2026, 11, 16),
      to: DateTime.utc(2026, 11, 20, 22, 59, 59),
    );
    final hour = week.singleWhere(
      (e) =>
          e.type == PlannedElementType.placeholder &&
          e.period.from.isAtSameMomentAs(DateTime.utc(2026, 11, 20, 10, 10)),
    );

    final planned = await service.planLesson(
      placeholder: hour,
      name: '[dartschool test] Lussen',
      publicInfo: '<p>Voor de leerlingen</p>',
      privateInfo: '<p>Notities</p>',
    );
    expect(planned.name, '[dartschool test] Lussen');
    expect(planned.participantGroups.map((g) => g.id), [
      '4069_2001',
      '4069_2002',
    ]);

    final renamed = await service.renameElement(
      planned,
      'Lussen: for en while',
    );
    final informed = await service.changePublicInfo(
      renamed,
      '<p>Breng je laptop <strong>opgeladen</strong> mee</p>',
    );
    final noted = await service.changePrivateInfo(
      informed,
      '<p>Oefening 3</p>',
    );
    expect(noted.name, 'Lussen: for en while');
    expect(
      noted.publicInfo,
      '<p>Breng je laptop <strong>opgeladen</strong> mee</p>',
    );
    expect(noted.privateInfo, '<p>Oefening 3</p>');

    // A second fill of the hour is refused: the slot is gone.
    await expectLater(
      service.planLesson(placeholder: hour, name: 'Nog een les'),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );

    final empty = await service.clearLesson(noted);
    expect(empty.type, PlannedElementType.placeholder);
    expect(empty.id, isNot(hour.id));
    await expectLater(
      service.getDetail(noted),
      throwsA(isA<SmartschoolPlannedElementNotFoundError>()),
    );

    final weekAfter = await service.getPlannedElements(
      await service.ownCalendar(),
      from: DateTime.utc(2026, 11, 16),
      to: DateTime.utc(2026, 11, 20, 22, 59, 59),
    );
    expect(weekAfter.single.type, PlannedElementType.placeholder);
    expect(weekAfter.single.id, _newSlotId);

    expect(server.plannerLog.where((l) => l.startsWith('POST')).toList(), [
      _fill,
      _rename,
      _changePublic,
      _changePrivate,
      _clear,
    ]);
  });
}
