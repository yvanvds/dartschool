// Tests for issue #238: `MessagesService.searchRecipientsForCompose` and
// `searchRecipientsForComposeAll` with `includeOtherSchools`, Smartschool's
// checkbox "Toon personen van andere scholen" under the search results of its
// compose form, which finds the people of the other schools of the school
// group.
//
// The option is a setting of the account, not of the session (verified live
// on 2026-11-09): the checkbox sends
// `GET /?module=Messages&file=searchUsers&function=changesgr&val=1` (or
// `val=0`), answered with an empty `200`, and every answer to a search says
// in its `<sgrdetails>` whether Smartschool offers the option to the account
// (`<sgrselect>`) and whether it is on (`<dosgrsearch>`). The library reads
// the setting from the first answer, switches it only when it differs from
// what was asked, searches again, and sets it back afterwards, also when a
// search throws. `null`, the default, sends no switch.
//
// The fake Smartschool below keeps that setting for the account and answers a
// search with it on with the hand-written
// `post/composemessage/search-user-other-schools.xml` (made-up people and
// schools, made-up platforms 5810 and 6120 besides the own 4069), and with
// it off with the recorded `search-user.xml` (the own school only).
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

/// The recorded new-message compose form, which holds a `uniqueUsc`.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// A search's answer with the option off: users of the own school only.
final _ownSchoolOnly = _fixture('post/composemessage/search-user.xml');

/// A search's answer with the option on: a user of the own school and two of
/// other schools.
final _withOtherSchools = _fixture(
  'post/composemessage/search-user-other-schools.xml',
);

/// The own platform of the fixtures.
const _ownPlatform = 4069;

// The requests, as the fake logs them.
const _form = 'form';
String _search(String query) => 'search $query';
const _switchOn = 'switch 1';
const _switchOff = 'switch 0';

/// An answer of the fake Smartschool.
typedef _Answer = ({String body, int status, String contentType});

_Answer _html(String body, {int status = 200}) =>
    (body: body, status: status, contentType: 'text/html; charset=UTF-8');

_Answer _xml(String body) =>
    (body: body, status: 200, contentType: 'text/xml; charset=UTF-8');

/// One of Smartschool's error pages, made up in the shape of those seen live
/// (#106).
const _errorPage =
    '<!DOCTYPE html>\n<html lang="nl"><head>'
    '<title>Springfield Academy - Smartschool</title></head><body>'
    '<div class="container"><h1>Er is een fout opgetreden</h1>'
    '<p>Probeer het later opnieuw.</p></div></body></html>';

/// A Smartschool that keeps the account's setting "Toon personen van andere
/// scholen" ([otherSchools]) and answers the searches with it. It accepts the
/// session for every request, so the client never logs in.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.otherSchools = false, this.offered = true});

  /// The account's setting: whether the option is on.
  bool otherSchools;

  /// Whether Smartschool offers the option to the account (`<sgrselect>`).
  final bool offered;

  /// Every request: [_form], [_search], [_switchOn] or [_switchOff], or
  /// `METHOD <path and query>` for any other.
  final List<String> log = [];

  /// The switches, as they went out: their query and their headers.
  final List<RequestOptions> switches = [];

  /// The answers to the searches by their number (from 1, over the whole
  /// test), instead of the answer for the setting.
  final Map<int, _Answer> searchAnswers = {};

  /// The answers to the switches by their number (from 1), instead of an
  /// empty `200`. The switch is made all the same.
  final Map<int, _Answer> switchAnswers = {};

  /// Runs before the search of its number is answered: what else that uses
  /// the account does meanwhile, such as the web interface.
  final Map<int, void Function()> beforeSearch = {};

  int _searches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final query = uri.queryParameters;
    final file = query['file'];
    if (options.method == 'GET' && file == 'composeMessage') {
      log.add(_form);
      return _answer(_html(_newMessageForm));
    }
    if (options.method == 'POST' &&
        file == 'searchUsers' &&
        !query.containsKey('function')) {
      final number = ++_searches;
      log.add(_search('${(options.data as Map)['val']}'));
      beforeSearch[number]?.call();
      return _answer(searchAnswers[number] ?? _xml(_searchAnswer()));
    }
    if (options.method == 'GET' &&
        file == 'searchUsers' &&
        query['function'] == 'changesgr') {
      switches.add(options);
      log.add('switch ${query['val']}');
      otherSchools = query['val'] == '1';
      return _answer(switchAnswers[switches.length] ?? _html(''));
    }
    log.add('${options.method} ${uri.path}?${uri.query}');
    return _answer(_html('<html><body>Not here</body></html>', status: 404));
  }

  /// The answer to a search with the setting as it is.
  String _searchAnswer() {
    final answer = otherSchools ? _withOtherSchools : _ownSchoolOnly;
    return offered
        ? answer
        : answer.replaceFirst(
            '<sgrselect>1</sgrselect>',
            '<sgrselect>0</sgrselect>',
          );
  }

  static ResponseBody _answer(_Answer answer) => ResponseBody.fromString(
    answer.body,
    answer.status,
    headers: {
      Headers.contentTypeHeader: [answer.contentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

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

/// The platforms of the users of [result].
List<int> _platforms(
  (List<MessageSearchUser>, List<MessageSearchGroup>) result,
) => result.$1.map((u) => u.ssId).toList();

/// A [SmartschoolComposeError] whose message holds every one of [parts].
Matcher _composeError(List<String> parts) =>
    isA<SmartschoolComposeError>().having(
      (e) => e.message,
      'message',
      allOf([for (final p in parts) contains(p)]),
    );

void main() {
  forbidRealNetwork();

  late _Smartschool server;
  late SmartschoolClient client;
  late MessagesService messages;

  Future<void> serve(_Smartschool smartschool) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
  }

  group('includeOtherSchools: true', () {
    test('with the setting off: a search, the switch on, the search again, '
        'and the switch back off, in that order; the results hold the people '
        'of other schools, each with the platform of their school', () async {
      await serve(_Smartschool());

      final (users, groups) = await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );

      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _switchOff,
      ]);
      expect(server.otherSchools, isFalse, reason: 'set back as it was found');
      expect(users.map((u) => u.displayName), [
        'Rod Flanders',
        'Ned Flanders',
        'Maude Flanders',
      ]);
      expect(_platforms((users, groups)), [_ownPlatform, 5810, 6120]);
      expect(groups, isEmpty);
      final ned = users[1];
      expect(ned.userId, 2231);
      expect(ned.userLt, 0);
      expect(ned.platformName, 'Shelbyville High');
      expect(ned.schoolName, 'Shelbyville High');
      expect(users[2].platformName, 'Ogdenville College');
      expect(users.first.platformName, isNull, reason: 'empty for own school');
    });

    test('the switch is the GET of the checkbox: val, and no uniqueUsc, as an '
        'XHR', () async {
      await serve(_Smartschool());

      await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );

      expect(server.switches, hasLength(2));
      for (final (i, request) in server.switches.indexed) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/');
        expect(request.uri.queryParameters, {
          'module': 'Messages',
          'file': 'searchUsers',
          'function': 'changesgr',
          'val': i == 0 ? '1' : '0',
        });
        expect(request.data, isNull);
        expect(request.headers[kXRequestedWith], 'XMLHttpRequest');
      }
    });

    test('with the setting on already: one search, and no switch', () async {
      await serve(_Smartschool(otherSchools: true));

      final result = await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );

      expect(server.log, [_form, _search('Flanders')]);
      expect(server.otherSchools, isTrue);
      expect(_platforms(result), [_ownPlatform, 5810, 6120]);
    });

    test(
      'searchRecipientsForComposeAll: one switch before all the queries '
      'and one set-back after them, the first query searched again',
      () async {
        await serve(_Smartschool());

        final results = await messages.searchRecipientsForComposeAll([
          'Flanders',
          'Lovejoy',
          'Flanders',
          'Wiggum',
        ], includeOtherSchools: true);

        expect(server.log, [
          _form,
          _search('Flanders'),
          _switchOn,
          _search('Flanders'),
          _search('Lovejoy'),
          _search('Wiggum'),
          _switchOff,
        ]);
        expect(results.keys, ['Flanders', 'Lovejoy', 'Wiggum']);
        for (final result in results.values) {
          expect(_platforms(result), [_ownPlatform, 5810, 6120]);
        }
        expect(server.otherSchools, isFalse);
      },
    );

    test(
      'with the setting on already, several queries: no switch at all',
      () async {
        await serve(_Smartschool(otherSchools: true));

        final results = await messages.searchRecipientsForComposeAll([
          'Flanders',
          'Lovejoy',
        ], includeOtherSchools: true);

        expect(server.log, [_form, _search('Flanders'), _search('Lovejoy')]);
        expect(results.keys, ['Flanders', 'Lovejoy']);
        expect(server.otherSchools, isTrue);
      },
    );

    test('when Smartschool does not offer the option to the account '
        '(sgrselect 0), it throws a SmartschoolComposeError after the first '
        'search, and switches nothing', () async {
      await serve(_Smartschool(offered: false));

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError([
            'does not offer the option "Toon personen van andere scholen"',
            'Nothing was switched',
          ]),
        ),
      );
      expect(server.log, [_form, _search('Flanders')]);
      expect(server.otherSchools, isFalse);
    });

    test('when the first answer does not say whether the option is on (an '
        'empty 200), it throws a SmartschoolComposeError, and switches '
        'nothing', () async {
      await serve(_Smartschool()..searchAnswers[1] = _html(''));

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError(['does not say whether', 'Nothing was switched']),
        ),
      );
      expect(server.log, [_form, _search('Flanders')]);
    });
  });

  group('includeOtherSchools: false', () {
    test('with the setting on: switched off for the search, and back on '
        'after it', () async {
      await serve(_Smartschool(otherSchools: true));

      final result = await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: false,
      );

      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOff,
        _search('Flanders'),
        _switchOn,
      ]);
      expect(server.otherSchools, isTrue, reason: 'set back as it was found');
      expect(_platforms(result), everyElement(_ownPlatform));
    });

    test('with the setting off: one search, and no switch', () async {
      await serve(_Smartschool());

      final result = await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: false,
      );

      expect(server.log, [_form, _search('Flanders')]);
      expect(_platforms(result), everyElement(_ownPlatform));
    });

    test('for an account that Smartschool does not offer the option to, with '
        'the setting off: searched as asked, no error and no switch', () async {
      await serve(_Smartschool(offered: false));

      final result = await messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: false,
      );

      expect(server.log, [_form, _search('Flanders')]);
      expect(_platforms(result), everyElement(_ownPlatform));
    });
  });

  group('includeOtherSchools: null (the default) searches as before, with the '
      'account\'s setting, and sends no switch', () {
    for (final on in [false, true]) {
      test('with the setting ${on ? 'on' : 'off'}', () async {
        await serve(_Smartschool(otherSchools: on));

        final result = await messages.searchRecipientsForCompose('Flanders');
        final all = await messages.searchRecipientsForComposeAll([
          'Flanders',
          'Lovejoy',
        ]);

        expect(server.log, [
          _form,
          _search('Flanders'),
          _form,
          _search('Flanders'),
          _search('Lovejoy'),
        ]);
        expect(server.switches, isEmpty);
        final platforms = on ? [_ownPlatform, 5810, 6120] : null;
        if (platforms != null) {
          expect(_platforms(result), platforms);
          expect(_platforms(all['Lovejoy']!), platforms);
        } else {
          expect(_platforms(result), everyElement(_ownPlatform));
          expect(_platforms(all['Lovejoy']!), everyElement(_ownPlatform));
        }
      });
    }
  });

  group('the setting is set back after a failure', () {
    test('when the search after the switch throws: set back off, and the '
        'search\'s error is thrown', () async {
      await serve(_Smartschool()..searchAnswers[2] = _html(_errorPage));

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          isA<SmartschoolUnexpectedPageError>().having(
            (e) => e.action,
            'action',
            'searchUsers',
          ),
        ),
      );
      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _switchOff,
      ]);
      expect(server.otherSchools, isFalse);
    });

    test('when a later search of searchRecipientsForComposeAll throws: set '
        'back off once, and the queries after it are not searched', () async {
      await serve(
        _Smartschool()..searchAnswers[3] = _xml('Fout bij het zoeken'),
      );

      await expectLater(
        messages.searchRecipientsForComposeAll([
          'Flanders',
          'Lovejoy',
          'Wiggum',
        ], includeOtherSchools: true),
        throwsA(isA<SmartschoolParsingError>()),
      );
      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _search('Lovejoy'),
        _switchOff,
      ]);
      expect(server.otherSchools, isFalse);
    });

    test('when Smartschool answers the switch with anything but an empty '
        '200: a SmartschoolComposeError, after setting it back', () async {
      await serve(
        _Smartschool()..switchAnswers[1] = _html(_errorPage, status: 500),
      );

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError([
            'did not answer the switch of its option "Toon personen van '
                'andere scholen" on',
            'HTTP 500',
          ]),
        ),
      );
      expect(server.log, [_form, _search('Flanders'), _switchOn, _switchOff]);
      expect(server.otherSchools, isFalse);
    });

    test('when the setting cannot be set back: a SmartschoolComposeError that '
        'says it may be left on', () async {
      await serve(_Smartschool()..switchAnswers[2] = _html(_errorPage));

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError([
            'could not be set back off',
            'It may be left on for the account',
            'with the checkbox',
          ]),
        ),
      );
      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _switchOff,
      ]);
    });

    test('when a search throws and the setting cannot be set back either: a '
        'SmartschoolComposeError that names both', () async {
      await serve(
        _Smartschool()
          ..searchAnswers[2] = _html(_errorPage)
          ..switchAnswers[2] = _html('', status: 503),
      );

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError([
            'could not be set back off',
            'HTTP 503',
            'after the search failed',
            '"searchUsers"',
            'It may be left on',
          ]),
        ),
      );
      expect(server.log.last, _switchOff);
    });

    test('when an answer after the switch says the setting is off again '
        '(switched meanwhile, in the web interface say): a '
        'SmartschoolComposeError, not results of the other setting, and set '
        'back', () async {
      await serve(
        _Smartschool()..beforeSearch[2] = () => server.otherSchools = false,
      );

      await expectLater(
        messages.searchRecipientsForCompose(
          'Flanders',
          includeOtherSchools: true,
        ),
        throwsA(
          _composeError([
            'searched with its option "Toon personen van andere scholen" off',
            'was switched meanwhile',
          ]),
        ),
      );
      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _switchOff,
      ]);
    });

    test('also when the setting was as asked: an answer that says otherwise '
        'is an error, and nothing is switched', () async {
      await serve(
        _Smartschool(otherSchools: true)
          ..beforeSearch[2] = () => server.otherSchools = false,
      );

      await expectLater(
        messages.searchRecipientsForComposeAll([
          'Flanders',
          'Lovejoy',
        ], includeOtherSchools: true),
        throwsA(_composeError(['was switched meanwhile'])),
      );
      expect(server.log, [_form, _search('Flanders'), _search('Lovejoy')]);
    });
  });

  group('the calls with includeOtherSchools take turns on one client', () {
    test('two calls at once, through two MessagesService of the client: the '
        'second starts after the first set the setting back', () async {
      await serve(_Smartschool());
      final other = MessagesService(client);

      final first = messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );
      final second = other.searchRecipientsForCompose(
        'Lovejoy',
        includeOtherSchools: false,
      );
      final (withOthers, ownOnly) = await (first, second).wait;

      expect(server.log, [
        _form,
        _search('Flanders'),
        _switchOn,
        _search('Flanders'),
        _switchOff,
        // Off, as asked: no switch.
        _form,
        _search('Lovejoy'),
      ]);
      expect(_platforms(withOthers), [_ownPlatform, 5810, 6120]);
      expect(_platforms(ownOnly), everyElement(_ownPlatform));
    });

    test('a call that failed does not stop the next one', () async {
      await serve(_Smartschool()..searchAnswers[1] = _html(_errorPage));

      final first = messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );
      final second = messages.searchRecipientsForCompose(
        'Lovejoy',
        includeOtherSchools: true,
      );

      await expectLater(first, throwsA(isA<SmartschoolUnexpectedPageError>()));
      expect(_platforms(await second), [_ownPlatform, 5810, 6120]);
      expect(server.log, [
        _form,
        _search('Flanders'),
        _form,
        _search('Lovejoy'),
        _switchOn,
        _search('Lovejoy'),
        _switchOff,
      ]);
    });

    test('another client does not wait', () async {
      // On already, so that neither switches: they would race.
      await serve(_Smartschool(otherSchools: true));
      final otherClient = await SmartschoolClient.create(
        _Credentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(otherClient.dispose);
      otherClient.dio.httpClientAdapter = server;

      final first = messages.searchRecipientsForCompose(
        'Flanders',
        includeOtherSchools: true,
      );
      final second = MessagesService(
        otherClient,
      ).searchRecipientsForCompose('Lovejoy', includeOtherSchools: true);
      await (first, second).wait;

      // Both loaded their form before either searched.
      expect(server.log.take(2), [_form, _form]);
    });
  });
}
