// Tests for issue #127: naming a calendar of the planner by its ID
// (`PlannerService.getCalendar`), which also tells a calendar ID that names
// no planner from a planner with nothing planned; and whether the planner
// counts a user as deleted (`PlannerSearchResult.isDeleted`).
//
// The answers below are trimmed captures of the live planner API (read-only,
// 2026-10-05) of `POST /planner/api/v1/quick-search/planner/start`, the
// request with which the planner's web client opens its search field, with
// a calendar ID in its `users`, `groups` or `miniDbItems`:
//   - a class (its name and full name);
//   - a colleague, and a user the planner counts as deleted (named all the
//     same, with `state.deleted.isDeleted`);
//   - a room (`mini-db-2`, an item of the location module), asked for by
//     its calendar ID `{platformId}_{itemId}`;
//   - the authenticated user, whom the planner names `%quicksearch.me%`;
//   - a made-up ID of each kind: an empty `selection`;
//   - a class asked for with a leading zero (`4069_02001`), which the
//     planner answered as the class without it;
// and the planner's `500` to a class ID that is not a number, and to the
// elements of a user or class ID it does not have; its empty list for the
// elements of a location ID it does not have. Every name, picture hash and
// URL, user, group and item ID is replaced by obvious fakes ("Jan
// Janssens", `initials_XX`). Each answer also holds the search's
// suggestions (the authenticated user), the user's favourites (none), its
// options and its settings, as the planner sends them.
//
// The lookup is a POST that only reads. The fake Smartschool fails the test
// on any other POST (the planner also has the POSTs `mark-as-favourite`
// and `discard-as-favourite` next to it, which change the user's
// favourites), and answers only the GETs it is given.
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
const _lookupPath = '$_api/quick-search/planner/start';

const _roomId = '10000000-0000-4000-8000-000000000101';

/// The class 6A1.
const _class = r'''
{"identifier":{"id":"4069_2001","type":"group"},"title":[{"part":"6A1","isHighlighted":false}],"description":[],"graphic":{"type":"icon","value":"briefcase"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"groupIdentifier":"4069_2001","name":"6A1","description":"6 Latijn 1"},"sortField":"0-group-6A1"}
''';

/// A colleague.
const _colleague = r'''
{"identifier":{"id":"4069_1002_0","type":"user"},"title":[{"part":"Peeters","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"Piet","isHighlighted":false}],"description":[],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_1002_0","userPictureHash":"initials_PP","userPictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_PP\/plain\/1\/res\/128","name":"Piet Peeters","nameReverse":"Peeters Piet","description":"","descriptionReverse":"","sort":"peeters-piet"},"sortField":"1-user-peeters-piet"}
''';

/// A user the planner counts as deleted: named all the same.
const _deletedUser = r'''
{"identifier":{"id":"4069_1005_0","type":"user"},"title":[{"part":"Claes","isHighlighted":false},{"part":" ","isHighlighted":false},{"part":"Karel","isHighlighted":false}],"description":[],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_KC\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":true,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_1005_0","userPictureHash":"initials_KC","userPictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_KC\/plain\/1\/res\/128","name":"Karel Claes","nameReverse":"Claes Karel","description":"","descriptionReverse":"","sort":"claes-karel"},"sortField":"1-user-claes-karel"}
''';

/// The room 101.
const _room = r'''
{"identifier":{"id":"4069_10000000-0000-4000-8000-000000000101","type":"mini-db-2"},"title":[{"part":"101","isHighlighted":false}],"description":[{"part":"Locatie","isHighlighted":false}],"graphic":{"type":"icon","value":"location_ic_action"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"itemId":"10000000-0000-4000-8000-000000000101","name":"101","icon":"location_ic_action","breadCrumbs":["Locatie"],"modules":["location"],"isParent":false},"sortField":"3-mini-db-2-101"}
''';

/// The authenticated user (Jan Janssens, `4069_1001_0`), as the planner
/// names it: a key of the web client's texts, without a picture URL in its
/// origin.
const _me = r'''
{"identifier":{"id":"4069_1001_0","type":"user"},"title":[{"part":"%quicksearch.me%","isHighlighted":false}],"description":[],"graphic":{"type":"image","value":"https:\/\/userpicture20.smartschool.be\/User\/Userimage\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/48"},"state":{"favourite":{"isFavourable":true,"isFavoured":false},"deleted":{"isDeleted":false,"deletedLabel":""},"visibility":{"isVisible":true}},"origin":{"userIdentifier":"4069_1001_0","userPictureHash":"initials_JJ","name":"%quicksearch.me%","nameReverse":"%quicksearch.me%","sort":"-1-me"},"sortField":"1-user--1-me"}
''';

/// The planner's answer to the lookup, with [selection] (the hits joined)
/// as the calendars it names, and the rest as it always sends it: the
/// authenticated user as the search's suggestion, no favourites, and its
/// option and setting.
String _lookup(List<String> selection) =>
    '{"selection":[${selection.map((hit) => hit.trim()).join(',')}],'
    '"suggestions":[${_me.trim().replaceFirst('"isFavourable":true', '"isFavourable":false')}],'
    '"favourites":[],'
    '"searchOptions":[{"id":"include-deleted","isDefaultSelected":false,'
    '"extraData":{}}],'
    '"settings":[{"id":"debounce-values","extraData":{"cutOffPoint":1,'
    '"before":1000,"after":200}}]}';

/// The planner's answer to a class ID that is not a number, and to the
/// elements of a user or class ID it does not have.
const _serverError =
    '{"status":500,"title":"Internal Server Error","detail":"","type":""}';

/// Smartschool's generic error page.
const _errorPage = '''
<!DOCTYPE html>
<html><head><title></title></head>
<body><div id="#smscMain"><h1>Oeps, er ging iets mis</h1></div></body>
</html>
''';

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

typedef _Answer = ({int status, String body, String contentType});

_Answer _json(String body, {int status = 200}) =>
    (status: status, body: body, contentType: 'application/json');

/// The GETs with which the client reads the authenticated user [userId]:
/// the platform ID (which logs in when needed), and the home page.
Map<String, _Answer> _loggedInAs(String userId) => {
  '/course-list/api/v1/courses': _json('[{"platformId":4069}]'),
  '/': (
    status: 200,
    body: _homePage(userId),
    contentType: 'text/html; charset=UTF-8',
  ),
};

/// A request as it reached the fake Smartschool.
typedef _Request = ({
  String method,
  String path,
  String rawQuery,
  String? contentType,
  String body,
});

/// A Smartschool that answers the lookup ([lookups], by the one calendar ID
/// in it) and the GETs of [gets] (by path), and fails the test on any other
/// request.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.lookups = const {}, this.gets = const {}});

  final Map<String, _Answer> lookups;
  final Map<String, _Answer> gets;

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
      // The lookup is the one POST the service may send here: it only reads.
      expect(uri.path, _lookupPath, reason: 'the only POST is the lookup');
      final json = jsonDecode(body) as Map<String, dynamic>;
      final ids = [
        for (final kind in ['users', 'groups', 'miniDbItems'])
          ...json[kind] as List,
      ];
      expect(ids, hasLength(1), reason: 'one calendar per lookup');
      answer = lookups[ids.single];
    } else {
      expect(options.method, 'GET');
      answer = gets[uri.path];
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
    PlannerService.parseCalendarLookup(jsonDecode(answer));

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

  group('PlannerService.parseCalendarLookup', () {
    test('gives the calendars of the selection in the form of the search\'s '
        'hits, without the suggestions and favourites', () {
      final named = _parse(_lookup([_class, _colleague]));

      expect(named.map((hit) => hit.calendar), [
        PlannerCalendar.group('4069_2001'),
        PlannerCalendar.user('4069_1002_0'),
      ]);
      expect(named.first.name, '6A1');
      expect(named.first.description, '6 Latijn 1');
      expect(named.last.name, 'Piet Peeters');
      expect(named.last.title, 'Peeters Piet');
    });

    test('a room is a location calendar with {platformId}_{itemId}', () {
      final room = _parse(_lookup([_room])).single;

      expect(room.kind, PlannerSearchResultKind.location);
      expect(room.calendar, PlannerCalendar.location('4069_$_roomId'));
      expect(room.name, '101');
      expect(room.description, 'Locatie');
    });

    test('an empty selection is an empty list, whatever the suggestions', () {
      expect(_parse(_lookup([])), isEmpty);
    });

    test('an answer that is not an object, or without a selection list, is '
        'refused', () {
      expect(
        () => PlannerService.parseCalendarLookup(<dynamic>[]),
        throwsA(_plannerError(contains('instead of an object'))),
      );
      final answer = jsonDecode(_lookup([])) as Map<String, dynamic>;
      expect(
        () => PlannerService.parseCalendarLookup(
          {...answer}..remove('selection'),
        ),
        throwsA(_plannerError(contains('selection'))),
      );
      expect(
        () => PlannerService.parseCalendarLookup({...answer, 'selection': {}}),
        throwsA(_plannerError(contains('instead of a list'))),
      );
    });

    test('a calendar that is not an object is refused', () {
      expect(
        () => PlannerService.parseCalendarLookup({
          'selection': ['4069_2001'],
        }),
        throwsA(_plannerError(contains('calendar 0 of a lookup'))),
      );
    });
  });

  group('PlannerSearchResult.isDeleted', () {
    test('is the planner\'s state.deleted.isDeleted', () {
      expect(_parse(_lookup([_deletedUser])).single.isDeleted, isTrue);
      expect(_parse(_lookup([_colleague])).single.isDeleted, isFalse);
      expect(_parse(_lookup([_class])).single.isDeleted, isFalse);
    });

    test('is false for a hit without a state', () {
      final hit = jsonDecode(_class) as Map<String, dynamic>;
      hit.remove('state');
      expect(
        PlannerService.parseSearchResults([hit]).single.isDeleted,
        isFalse,
      );
    });

    test('a state in an unknown shape is refused', () {
      final hit = jsonDecode(_class) as Map<String, dynamic>;
      hit['state'] = {'deleted': true};
      expect(
        () => PlannerService.parseSearchResults([hit]),
        throwsA(_plannerError(contains('the deleted state of hit 4069_2001'))),
      );
    });

    test('shows in toString', () {
      final deleted = _parse(_lookup([_deletedUser])).single;
      expect(deleted.toString(), endsWith(', deleted)'));
      expect(
        _parse(_lookup([_colleague])).single.toString(),
        isNot(contains('deleted')),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------

  group('PlannerService.getCalendar', () {
    test('POSTs a class ID in groups to quick-search/planner/start, as the '
        'web client does, and names the class', () async {
      final (server, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_2001': _json(_lookup([_class])),
          },
        ),
      );

      final klas = await planner.getCalendar(
        PlannerCalendar.group('4069_2001'),
      );

      expect(klas!.calendar, PlannerCalendar.group('4069_2001'));
      expect(klas.kind, PlannerSearchResultKind.group);
      expect(klas.name, '6A1');
      expect(klas.description, '6 Latijn 1');
      expect(klas.isDeleted, isFalse);
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _lookupPath);
      expect(request.rawQuery, isEmpty);
      expect(request.contentType, startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'users': <Object>[],
        'groups': ['4069_2001'],
        'miniDbItems': <Object>[],
      });
    });

    test('a user ID goes in users, a location ID in miniDbItems', () async {
      final (server, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_1002_0': _json(_lookup([_colleague])),
            '4069_$_roomId': _json(_lookup([_room])),
          },
        ),
      );

      final colleague = await planner.getCalendar(
        PlannerCalendar.user('4069_1002_0'),
      );
      final room = await planner.getCalendar(
        PlannerCalendar.location('4069_$_roomId'),
      );

      expect(colleague!.calendar, PlannerCalendar.user('4069_1002_0'));
      expect(colleague.name, 'Piet Peeters');
      expect(colleague.title, 'Peeters Piet');
      expect(room!.calendar, PlannerCalendar.location('4069_$_roomId'));
      expect(room.name, '101');
      expect(server.requests.map((r) => jsonDecode(r.body)), [
        {
          'users': ['4069_1002_0'],
          'groups': <Object>[],
          'miniDbItems': <Object>[],
        },
        {
          'users': <Object>[],
          'groups': <Object>[],
          'miniDbItems': ['4069_$_roomId'],
        },
      ]);
    });

    test('names a deleted user, as deleted', () async {
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_1005_0': _json(_lookup([_deletedUser])),
          },
        ),
      );

      final user = await planner.getCalendar(
        PlannerCalendar.user('4069_1005_0'),
      );

      expect(user!.name, 'Karel Claes');
      expect(user.isDeleted, isTrue);
    });

    test('a calendar the planner does not know is null: a made-up class, '
        'user or room', () async {
      final (server, planner) = await serve(
        _Smartschool(
          lookups: {
            for (final id in ['4069_99999', '4069_99999_0', '4069_$_roomId'])
              id: _json(_lookup([])),
          },
        ),
      );

      expect(
        await planner.getCalendar(PlannerCalendar.group('4069_99999')),
        isNull,
      );
      expect(
        await planner.getCalendar(PlannerCalendar.user('4069_99999_0')),
        isNull,
      );
      expect(
        await planner.getCalendar(PlannerCalendar.location('4069_$_roomId')),
        isNull,
      );
      expect(server.requests, hasLength(3));
    });

    test('tells a room the planner does not know from a room with nothing '
        'planned, which getPlannedElements answers alike', () async {
      const unknownRoom = '4069_00000000-0000-4000-8000-000000000000';
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            unknownRoom: _json(_lookup([])),
            '4069_$_roomId': _json(_lookup([_room])),
          },
          gets: {
            '$_api/planned-elements/location/$unknownRoom': _json('[]'),
            '$_api/planned-elements/location/4069_$_roomId': _json('[]'),
          },
        ),
      );
      final unknown = PlannerCalendar.location(unknownRoom);
      final empty = PlannerCalendar.location('4069_$_roomId');
      final from = DateTime.utc(2026, 10, 5);
      final to = DateTime.utc(2026, 10, 9, 21, 59, 59);

      // The planner lists both as a room with nothing planned...
      expect(
        await planner.getPlannedElements(unknown, from: from, to: to),
        isEmpty,
      );
      expect(
        await planner.getPlannedElements(empty, from: from, to: to),
        isEmpty,
      );
      // ...and names only the one it has.
      expect(await planner.getCalendar(unknown), isNull);
      expect((await planner.getCalendar(empty))!.name, '101');
    });

    test('names a class the planner does not know as null, where '
        'getPlannedElements fails with HTTP 500', () async {
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {'4069_99999': _json(_lookup([]))},
          gets: {
            '$_api/planned-elements/group/4069_99999': _json(
              _serverError,
              status: 500,
            ),
          },
        ),
      );
      final unknown = PlannerCalendar.group('4069_99999');

      await expectLater(
        planner.getPlannedElements(
          unknown,
          from: DateTime.utc(2026, 10, 5),
          to: DateTime.utc(2026, 10, 9, 21, 59, 59),
        ),
        throwsA(
          isA<SmartschoolPlannerError>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      expect(await planner.getCalendar(unknown), isNull);
    });

    test('names the own calendar after the authenticated user, where the '
        'planner gives a placeholder', () async {
      final (server, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_1001_0': _json(_lookup([_me])),
          },
          gets: _loggedInAs('4069_1001_0'),
        ),
      );

      final me = await planner.getCalendar(PlannerCalendar.user('4069_1001_0'));

      expect(me!.calendar, PlannerCalendar.user('4069_1001_0'));
      expect(me.name, 'Jan Janssens');
      expect(me.title, 'Janssens Jan');
      expect(me.kind, PlannerSearchResultKind.user);
      expect(me.isDeleted, isFalse);
      expect(
        me.pictureUrl,
        'https://userpicture20.smartschool.be/User/Userimage/hashimage/hash/'
        'initials_JJ/plain/1/res/48',
      );
      expect((me.raw['origin'] as Map)['name'], '%quicksearch.me%');
      expect(server.requests.first.path, _lookupPath);
    });

    test('reads the authenticated user only for the placeholder', () async {
      final (server, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_1002_0': _json(_lookup([_colleague])),
          },
          gets: _loggedInAs('4069_1001_0'),
        ),
      );

      await planner.getCalendar(PlannerCalendar.user('4069_1002_0'));

      expect(server.requests.map((r) => '${r.method} ${r.path}'), [
        'POST $_lookupPath',
      ]);
    });

    test('keeps the placeholder of a user who is not the authenticated '
        'one', () async {
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_1001_0': _json(_lookup([_me])),
          },
          gets: _loggedInAs('4069_1001_2'),
        ),
      );

      final hit = await planner.getCalendar(
        PlannerCalendar.user('4069_1001_0'),
      );

      expect(hit!.name, '%quicksearch.me%');
    });

    test('a calendar the planner names under another ID is a '
        'SmartschoolPlannerError', () async {
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_02001': _json(_lookup([_class])),
          },
        ),
      );

      await expectLater(
        planner.getCalendar(PlannerCalendar.group('4069_02001')),
        throwsA(
          _plannerError(
            allOf(
              contains('the lookup of PlannerCalendar(group: 4069_02001)'),
              contains('group 4069_2001'),
              contains('not with that calendar'),
            ),
          ),
        ),
      );
    });

    test('an ID the planner names as another kind is a '
        'SmartschoolPlannerError', () async {
      // The room's ID asked for as a class: a hit, but not of that calendar.
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_$_roomId': _json(_lookup([_room])),
          },
        ),
      );

      await expectLater(
        planner.getCalendar(PlannerCalendar.group('4069_$_roomId')),
        throwsA(_plannerError(contains('not with that calendar'))),
      );
    });

    test('a lookup the planner refuses is a SmartschoolPlannerError with the '
        'status', () async {
      final (_, planner) = await serve(
        _Smartschool(lookups: {'4069_abc': _json(_serverError, status: 500)}),
      );

      await expectLater(
        planner.getCalendar(PlannerCalendar.group('4069_abc')),
        throwsA(
          allOf(
            _plannerError(
              allOf(
                contains('the lookup of PlannerCalendar(group: 4069_abc)'),
                contains('HTTP 500'),
              ),
            ),
            isA<SmartschoolPlannerError>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        ),
      );
    });

    test('an HTML page is a SmartschoolPlannerError', () async {
      final (_, planner) = await serve(
        _Smartschool(
          lookups: {
            '4069_2001': (
              status: 200,
              body: _errorPage,
              contentType: 'text/html; charset=UTF-8',
            ),
          },
        ),
      );

      await expectLater(
        planner.getCalendar(PlannerCalendar.group('4069_2001')),
        throwsA(_plannerError(contains('an HTML page instead of JSON'))),
      );
    });
  });
}
