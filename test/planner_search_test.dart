// Tests for issue #85: finding the calendar of a class, a teacher or a
// location by name (`PlannerService.searchCalendars`), the search field of
// the planner ("Zoek een planner").
//
// The answers below are trimmed captures of the live planner API (read-only,
// 2026-10-02) of `POST /planner/api/v1/quick-search/planner/search`:
//   - a search for part of a class name (two classes);
//   - a search for a last name (11 users, trimmed to 3: a teacher, a pupil,
//     whose title in the search list ends in the class, and a co-account
//     with its own ID and an "Interimaris van ..." description);
//   - a search for a room number (one location, `mini-db-2`);
// with every name, picture hash and URL, user, group and item ID, class
// name and free text replaced by obvious fakes ("Jan Janssens",
// `initials_XX`). The hit of type `partner` and the `mini-db-2` item outside
// the location module are made up: no other kind of hit was seen live, and
// the service must keep one it cannot map to a calendar.
//
// The search is a POST that only reads. The fake Smartschool fails the test
// on any other POST (the planner also has the POSTs `mark-as-favourite` and
// `discard-as-favourite` next to the search, which change the user's
// favourites), and answers GETs of calendars only.
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
const _searchPath = '$_api/quick-search/planner/search';

const _roomId = '10000000-0000-4000-8000-000000000101';

/// The search for `6A`: two classes.
const _classes = r'''
[{"identifier":{"id":"4069_2001","type":"group"},"title":[{"part":"6A","isHighlighted":true},{"part":"1","isHighlighted":false}],"description":[],"graphic":{"type":"icon","value":"briefcase"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"groupIdentifier":"4069_2001","name":"6A1","description":"6 Latijn 1"},"sortField":"0-group-6A1"},
{"identifier":{"id":"4069_2002","type":"group"},"title":[{"part":"6A","isHighlighted":true},{"part":"2","isHighlighted":false}],"description":[],"graphic":{"type":"icon","value":"briefcase"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"groupIdentifier":"4069_2002","name":"6A2","description":"6 Latijn 2"},"sortField":"0-group-6A2"}]
''';

/// The search for `Janssens`, trimmed to a teacher, a pupil (the title ends
/// in the class, after a bullet the planner escapes as `•`) and a
/// co-account (its own ID ending in `_1`, a name in capitals, sorted under
/// the account it stands in for).
const _users = r'''
[{"identifier":{"id":"4069_1001_0","type":"user"},"title":[{"part":"Janssens","isHighlighted":true},{"part":" ","isHighlighted":false},{"part":"Jan","isHighlighted":false}],"description":[],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_1001_0","userPictureHash":"initials_JJ","userPictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128","name":"Jan Janssens","nameReverse":"Janssens Jan","description":"","descriptionReverse":"","sort":"janssens-jan"},"sortField":"1-user-janssens-jan"},
{"identifier":{"id":"4069_3001_0","type":"user"},"title":[{"part":"Janssens","isHighlighted":true},{"part":" ","isHighlighted":false},{"part":"Lotte","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"•","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"6A1","isHighlighted":false}],"description":[],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_LJ\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_3001_0","userPictureHash":"initials_LJ","userPictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_LJ\/plain\/1\/res\/128","name":"Lotte Janssens","nameReverse":"Janssens Lotte","description":"","descriptionReverse":"","sort":"janssens-lotte"},"sortField":"1-user-janssens-lotte"},
{"identifier":{"id":"4069_1004_1","type":"user"},"title":[{"part":"JANSSENS","isHighlighted":true},{"part":" ELS","isHighlighted":false}],"description":[{"part":"Interimaris van","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"Peeters","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"Piet","isHighlighted":false}],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_1004_1","userPictureHash":"initials_PP","userPictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","name":"ELS JANSSENS","nameReverse":"JANSSENS ELS","description":"Interimaris van Piet Peeters","descriptionReverse":"Interimaris van Peeters Piet","sort":"peeters-piet"},"sortField":"1-user-peeters-piet"}]
''';

/// The search for `101`: one room, an item of the location module.
const _room = r'''
[{"identifier":{"id":"4069_10000000-0000-4000-8000-000000000101","type":"mini-db-2"},"title":[{"part":"101","isHighlighted":true}],"description":[{"part":"Locatie","isHighlighted":false}],"graphic":{"type":"icon","value":"location_ic_action"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"itemId":"10000000-0000-4000-8000-000000000101","name":"101","icon":"location_ic_action","breadCrumbs":["Locatie"],"modules":["location"],"isParent":false},"sortField":"3-mini-db-2-101"}]
''';

/// Made up: a hit of a type the library does not know (`partner`, a type
/// the web client knows from other searches), and a `mini-db-2` item of
/// another module than the location module.
const _unknown = r'''
[{"identifier":{"id":"4069_77","type":"partner"},"title":[{"part":"Bibliotheek","isHighlighted":true},{"part":" Springfield","isHighlighted":false}],"description":[],"graphic":{"type":"icon","value":"partner"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"name":"Bibliotheek Springfield"},"sortField":"4-partner-bibliotheek-springfield"},
{"identifier":{"id":"4069_20000000-0000-4000-8000-000000000001","type":"mini-db-2"},"title":[{"part":"Beamer","isHighlighted":true},{"part":" 3","isHighlighted":false}],"description":[{"part":"Materiaal","isHighlighted":false}],"graphic":{"type":"icon","value":"beamer"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"itemId":"20000000-0000-4000-8000-000000000001","name":"Beamer 3","icon":"beamer","breadCrumbs":["Materiaal"],"modules":["equipment"],"isParent":false},"sortField":"3-mini-db-2-beamer-3"}]
''';

/// The planner's answer to a request it refuses, in the form it answers a
/// calendar ID it refuses.
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
  String? contentType,
  String body,
});

/// A Smartschool that answers the search ([searches], by search string) and
/// the GETs of [calendars] (by path), and fails the test on any other
/// request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.searches = const {}, this.calendars = const {}});

  final Map<String, _Answer> searches;
  final Map<String, _Answer> calendars;

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
      contentType: options.contentType,
      body: body,
    ));

    final _Answer? answer;
    if (options.method == 'POST') {
      // The search is the one POST the service may send: it only reads.
      expect(uri.path, _searchPath, reason: 'the only POST is the search');
      final json = jsonDecode(body) as Map<String, dynamic>;
      answer = searches[json['searchString']];
    } else {
      expect(options.method, 'GET');
      answer = calendars[uri.path];
    }
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

List<PlannerSearchResult> _parse(String answer) =>
    PlannerService.parseSearchResults(jsonDecode(answer));

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, PlannerService)> serve(_Smartschool server) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    return (server, PlannerService(client));
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  group('PlannerService.parseSearchResults', () {
    test('a class is a group calendar, with its name and full name', () {
      final hits = _parse(_classes);
      expect(hits.map((h) => h.name), ['6A1', '6A2']);

      final klas = hits.first;
      expect(klas.id, '4069_2001');
      expect(klas.typeName, 'group');
      expect(klas.kind, PlannerSearchResultKind.group);
      expect(klas.calendar, PlannerCalendar.group('4069_2001'));
      expect(klas.title, '6A1');
      expect(klas.description, '6 Latijn 1');
      expect(klas.icon, 'briefcase');
      expect(klas.pictureUrl, isNull);
      expect(hits.last.calendar, PlannerCalendar.group('4069_2002'));
    });

    test('a teacher is a user calendar with the whole user ID, a name and a '
        'picture', () {
      final teacher = _parse(_users).first;
      expect(teacher.id, '4069_1001_0');
      expect(teacher.typeName, 'user');
      expect(teacher.kind, PlannerSearchResultKind.user);
      expect(teacher.calendar, PlannerCalendar.user('4069_1001_0'));
      expect(teacher.name, 'Jan Janssens');
      expect(teacher.title, 'Janssens Jan');
      expect(teacher.description, '');
      expect(
        teacher.pictureUrl,
        'https://userpicture20.smartschool.be/User/Userimage/hashimage/hash/'
        'initials_JJ/plain/1/res/128',
      );
      expect(teacher.icon, isNull);
    });

    test('a pupil comes in the same form; the title of the search list ends '
        'in the class', () {
      final pupil = _parse(_users)[1];
      expect(pupil.kind, PlannerSearchResultKind.user);
      expect(pupil.calendar, PlannerCalendar.user('4069_3001_0'));
      expect(pupil.name, 'Lotte Janssens');
      expect(pupil.title, 'Janssens Lotte • 6A1');
      expect(pupil.description, '');
    });

    test('a co-account has its own ID and an "Interimaris van" '
        'description', () {
      final coAccount = _parse(_users).last;
      expect(coAccount.kind, PlannerSearchResultKind.user);
      expect(coAccount.calendar, PlannerCalendar.user('4069_1004_1'));
      expect(coAccount.name, 'ELS JANSSENS');
      expect(coAccount.title, 'JANSSENS ELS');
      expect(coAccount.description, 'Interimaris van Piet Peeters');
    });

    test('a room is a location calendar with {platformId}_{itemId}', () {
      final room = _parse(_room).single;
      expect(room.id, '4069_$_roomId');
      expect(room.typeName, 'mini-db-2');
      expect(room.kind, PlannerSearchResultKind.location);
      expect(room.calendar, PlannerCalendar.location('4069_$_roomId'));
      expect(room.name, '101');
      expect(room.title, '101');
      expect(room.description, 'Locatie');
      expect(room.icon, 'location_ic_action');
      expect(room.pictureUrl, isNull);
    });

    test('a room found by name is the calendar of the room an element '
        'names', () {
      final named = PlannerLocation(
        id: _roomId,
        platformId: 4069,
        title: '101',
      );
      expect(_parse(_room).single.calendar, named.calendar);
    });

    test('a hit of an unknown type is kept, without a calendar', () {
      final partner = _parse(_unknown).first;
      expect(partner.kind, PlannerSearchResultKind.other);
      expect(partner.calendar, isNull);
      expect(partner.id, '4069_77');
      expect(partner.typeName, 'partner');
      expect(partner.name, 'Bibliotheek Springfield');
      expect(partner.icon, 'partner');
    });

    test('an item outside the location module is not a location', () {
      final beamer = _parse(_unknown).last;
      expect(beamer.typeName, 'mini-db-2');
      expect(beamer.kind, PlannerSearchResultKind.other);
      expect(beamer.calendar, isNull);
      expect(beamer.name, 'Beamer 3');
      expect(beamer.description, 'Materiaal');
    });

    test('without an origin name, the name is the title', () {
      final hit = (jsonDecode(_classes) as List).first as Map<String, dynamic>;
      (hit['origin'] as Map).remove('name');
      expect(PlannerService.parseSearchResults([hit]).single.name, '6A1');
    });

    test('raw keeps the fields the model does not cover, read-only', () {
      final klas = _parse(_classes).first;
      expect(klas.raw['sortField'], '0-group-6A1');
      expect((klas.raw['state'] as Map)['favourite'], {
        'isFavourable': true,
        'isFavoured': false,
      });
      expect(() => klas.raw['sortField'] = 'x', throwsUnsupportedError);
    });

    test('nothing found is an empty list', () {
      expect(PlannerService.parseSearchResults(<dynamic>[]), isEmpty);
    });

    test('an answer that is not a list is refused', () {
      expect(
        () => PlannerService.parseSearchResults(<String, dynamic>{}),
        throwsA(_plannerError(contains('instead of a list'))),
      );
    });

    test('a hit that is not an object is refused', () {
      expect(
        () => PlannerService.parseSearchResults(['x']),
        throwsA(_plannerError(contains('hit 0'))),
      );
    });

    test('a hit without its identifier, ID or type is refused', () {
      Map<String, dynamic> hit() =>
          (jsonDecode(_classes) as List).first as Map<String, dynamic>;

      expect(
        () => PlannerService.parseSearchResults([hit()..remove('identifier')]),
        throwsA(_plannerError(contains('the identifier of a hit'))),
      );
      expect(
        () => PlannerService.parseSearchResults([
          hit()..['identifier'] = {'type': 'group'},
        ]),
        throwsA(_plannerError(contains('without its id'))),
      );
      expect(
        () => PlannerService.parseSearchResults([
          hit()..['identifier'] = {'id': '4069_2001'},
        ]),
        throwsA(_plannerError(contains('without its type'))),
      );
    });

    test('a user, class or location ID that is not a calendar ID is '
        'refused', () {
      Map<String, dynamic> hit(String answer, String id) {
        final json = (jsonDecode(answer) as List).first as Map<String, dynamic>;
        (json['identifier'] as Map)['id'] = id;
        return json;
      }

      expect(
        () => PlannerService.parseSearchResults([hit(_users, '1001')]),
        throwsA(_plannerError(contains('not a planner user calendar ID'))),
      );
      expect(
        () => PlannerService.parseSearchResults([hit(_classes, '2001')]),
        throwsA(_plannerError(contains('not a planner group calendar ID'))),
      );
      expect(
        () => PlannerService.parseSearchResults([hit(_room, _roomId)]),
        throwsA(_plannerError(contains('not a planner location calendar ID'))),
      );
    });

    test('a title in an unknown shape is refused', () {
      final hit = (jsonDecode(_classes) as List).first as Map<String, dynamic>;
      hit['title'] = '6A1';
      expect(
        () => PlannerService.parseSearchResults([hit]),
        throwsA(_plannerError(contains('the title of hit 4069_2001'))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------

  group('PlannerService.searchCalendars', () {
    test('POSTs the text as JSON to quick-search/planner/search, as the web '
        'client does', () async {
      final (server, planner) = await serve(
        _Smartschool(searches: {'6A': _json(_classes)}),
      );

      final hits = await planner.searchCalendars('6A');

      expect(hits.map((h) => h.calendar), [
        PlannerCalendar.group('4069_2001'),
        PlannerCalendar.group('4069_2002'),
      ]);
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _searchPath);
      expect(request.rawQuery, isEmpty);
      expect(request.contentType, startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'searchString': '6A',
        'searchOptions': <Object>[],
      });
    });

    test('sends the text without the white space around it', () async {
      final (server, planner) = await serve(
        _Smartschool(searches: {'Janssens': _json(_users)}),
      );

      final hits = await planner.searchCalendars('  Janssens\n');

      expect(hits, hasLength(3));
      expect(
        (jsonDecode(server.requests.single.body) as Map)['searchString'],
        'Janssens',
      );
    });

    test('nothing found is an empty list', () async {
      final (_, planner) = await serve(
        _Smartschool(searches: {'xyz': _json('[]')}),
      );

      expect(await planner.searchCalendars('xyz'), isEmpty);
    });

    test('a class, a teacher and a room found by name are read with '
        'getPlannedElements', () async {
      const groupPath = '$_api/planned-elements/group/4069_2001';
      const userPath = '$_api/planned-elements/user/4069_1001_0';
      const roomPath = '$_api/planned-elements/location/4069_$_roomId';
      final (server, planner) = await serve(
        _Smartschool(
          searches: {
            '6A': _json(_classes),
            'Janssens': _json(_users),
            '101': _json(_room),
          },
          calendars: {
            groupPath: _json('[]'),
            userPath: _json('[]'),
            roomPath: _json('[]'),
          },
        ),
      );
      final from = DateTime.utc(2026, 10, 5);
      final to = DateTime.utc(2026, 10, 9, 21, 59, 59);

      for (final (text, name) in [
        ('6A', '6A1'),
        ('Janssens', 'Jan Janssens'),
        ('101', '101'),
      ]) {
        final hits = await planner.searchCalendars(text);
        final hit = hits.firstWhere((h) => h.name == name);
        await planner.getPlannedElements(hit.calendar!, from: from, to: to);
      }

      expect(server.requests.map((r) => '${r.method} ${r.path}'), [
        'POST $_searchPath',
        'GET $groupPath',
        'POST $_searchPath',
        'GET $userPath',
        'POST $_searchPath',
        'GET $roomPath',
      ]);
    });

    test('refuses an empty text before sending anything', () async {
      final (server, planner) = await serve(_Smartschool());

      for (final text in ['', '   ', '\n\t']) {
        await expectLater(
          planner.searchCalendars(text),
          throwsA(isA<ArgumentError>()),
          reason: '"$text"',
        );
      }
      expect(server.requests, isEmpty);
    });

    test('a search the planner refuses is a SmartschoolPlannerError with the '
        'status', () async {
      final (_, planner) = await serve(
        _Smartschool(searches: {'6A': _json(_badRequest, status: 400)}),
      );

      await expectLater(
        planner.searchCalendars('6A'),
        throwsA(
          allOf(
            _plannerError(
              allOf(
                contains('the search for "6A"'),
                contains('HTTP 400'),
                contains('Bad Request'),
              ),
            ),
            isA<SmartschoolPlannerError>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        ),
      );
    });

    test('an HTML page, invalid JSON or an answer that is not a list is a '
        'SmartschoolPlannerError', () async {
      for (final answer in [
        (status: 200, body: _errorPage, contentType: 'text/html'),
        _json('[{"identifier":'),
        _json(''),
        _json('{"selection":[]}'),
      ]) {
        final (_, planner) = await serve(
          _Smartschool(searches: {'6A': answer}),
        );
        await expectLater(
          planner.searchCalendars('6A'),
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
          reason: answer.body,
        );
      }
    });
  });
}
