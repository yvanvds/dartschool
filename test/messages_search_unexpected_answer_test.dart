// Tests for issue #112: `MessagesService.searchRecipientsForCompose` (and
// `searchRecipientsForComposeAll`, #107) read Smartschool's answer to a
// recipient search (`POST /?module=Messages&file=searchUsers`, a form POST,
// not a command of the XML dispatcher) with `XmlInterface.parseResponse`
// directly. So an answer that is not empty and not XML (an HTML page or a
// piece of one, an error page, malformed XML, plain text) escaped as a raw
// `FormatException` ("Failed to parse Smartschool XML response: ..."), not a
// `SmartschoolException`; and a piece of a page that happens to be
// well-formed XML (one `<div>`) was read as a search without matches. The
// path dates from the initial commit (1175c9c); #110 closed the same gap for
// `SmartschoolClient.postXml`.
//
// The search now reads its answer as `postXml` reads the answer to a
// command, with the same code (`readXmlAnswer`): a
// `SmartschoolUnexpectedPageError` (action `searchUsers`) for HTML, a
// `SmartschoolParsingError` for anything else that is not XML. Such an answer
// is not one of those with which Smartschool refuses a session (a `401`, a
// redirect to its login chain, on which the search loads a new compose form,
// #97/#107), so it loads no new form and does not log in again.
//
// Not seen live: Smartschool cannot be made to answer a search on a valid
// compose form with such an answer. The pages below are in the shapes seen
// live for #106 and #110 (an error page, the piece of a page Smartschool
// answers an XHR to a module page with, the login page), with a made-up
// school and people.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

const _searchUrl = 'https://$_host/?module=Messages&file=searchUsers';

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

/// The recorded new-message compose form, which holds a `uniqueUsc`.
final _newMessageForm = _fixture('get/composemessage/new-message.html');

/// The recorded answer to a search that found users.
final _usersFound = _fixture('post/composemessage/search-user.xml');

/// The recorded answer to a search that found groups.
final _groupsFound = _fixture('post/composemessage/search-group.xml');

/// The names in [_usersFound].
const _foundNames = [
  'John Smith',
  'Admin User',
  'Robert Johnson',
  'Emma Davis',
  'Michelle Brown',
  'Jessica Miller',
  'Sarah Wilson',
];

/// A piece of a page, as Smartschool answered an XHR to a module page with
/// (#110): it starts with the comment seen live, and has more than one
/// element at its top, so it is not well-formed XML. The rest is made up.
const _fragment =
    '<!-- TRANSPARANT LAYER -->\n'
    '<div id="transparantLayer" class="transparant-layer"></div>\n'
    '<div class="smsc-container">\n'
    '  <h2>Berichten</h2>\n'
    '  <p>Er ging iets mis.&nbsp;Probeer het opnieuw.</p>\n'
    '  <script>window.user = "Jan Janssens";</script>\n'
    '</div>\n';

/// A piece of a page that happens to be well-formed XML: one element, after
/// a comment.
const _wellFormedFragment =
    '<!-- TRANSPARANT LAYER -->\n'
    '<div class="smsc-container"><h2>Berichten</h2>'
    '<p>Er ging iets mis.</p></div>';

/// One of Smartschool's error pages, in the shape of its "page not found"
/// page seen live (#106), with the signed-in user in a script.
const _errorPage =
    '<!DOCTYPE html>\n<html lang="nl"><head>'
    '<title>Springfield Academy - Smartschool</title>'
    '<script type="text/javascript">window.SMSC = {"authenticatedUser":'
    '{"name":"Jan Janssens"}};</script></head><body>'
    '<div class="container"><h1>Er is een fout opgetreden</h1>'
    '<p>Probeer het later opnieuw.</p></div></body></html>';

/// Smartschool's login page, in the shape of the one seen live (#106).
const _loginPage =
    '<!DOCTYPE html>\n<html lang="nl"><head>'
    '<title>Springfield Academy - Smartschool</title></head><body>'
    '<form class="form" name="login_form" method="post">'
    '<input type="text" name="login_form[_username]" value="jan.janssens">'
    '<input type="password" name="login_form[_password]">'
    '<button type="submit">Aanmelden</button>'
    '</form></body></html>';

/// [_usersFound] cut off in its second user: malformed XML, with the names
/// of the first user and a half.
final _cutOffUsers = _usersFound.substring(
  0,
  _usersFound.indexOf('<schoolname>', _usersFound.indexOf('Admin User')),
);

/// An answer of the fake Smartschool to a search.
typedef _Answer = ({String body, int status, String contentType});

_Answer _html(String body, {int status = 200}) =>
    (body: body, status: status, contentType: 'text/html; charset=UTF-8');

_Answer _xml(String body, {int status = 200}) =>
    (body: body, status: status, contentType: 'text/xml; charset=UTF-8');

// The requests, as the fake logs them.
const _form = 'GET composeMessage';
const _search = 'POST searchUsers';

/// A Smartschool that answers the new-message compose form with the recorded
/// form, and the recipient searches with [answers], one per search, and then
/// with the recorded answer that found users. It accepts the session for
/// every request, so the client never logs in.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(List<_Answer> answers) : _answers = [...answers];

  final List<_Answer> _answers;

  /// Every request that reached it: [_form], [_search], or `METHOD <path and
  /// query>` for any other request (a login, say).
  final List<String> log = [];

  /// The query (`val`) of every search, with the `uniqueUsc` it carried.
  final List<String> searches = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final file = uri.queryParameters['file'];
    if (options.method == 'GET' && file == 'composeMessage') {
      log.add(_form);
      return _answer(_html(_newMessageForm));
    }
    if (options.method == 'POST' &&
        file == 'searchUsers' &&
        !uri.queryParameters.containsKey('function')) {
      log.add(_search);
      final fields = options.data as Map;
      searches.add('${fields['val']} ${fields['uniqueUsc']}');
      return _answer(
        _answers.isEmpty ? _xml(_usersFound) : _answers.removeAt(0),
      );
    }
    log.add('${options.method} ${uri.path}?${uri.query}');
    return _answer(_html('<html><body>Not here</body></html>', status: 404));
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

/// The [SmartschoolUnexpectedPageError] that [call] throws.
Future<SmartschoolUnexpectedPageError> _pageErrorOf(
  Future<Object?> Function() call,
) async {
  try {
    await call();
  } on SmartschoolUnexpectedPageError catch (e) {
    return e;
  }
  fail('no SmartschoolUnexpectedPageError was thrown');
}

/// The [SmartschoolParsingError] that [call] throws.
Future<SmartschoolParsingError> _parsingErrorOf(
  Future<Object?> Function() call,
) async {
  try {
    await call();
  } on SmartschoolParsingError catch (e) {
    return e;
  }
  fail('no SmartschoolParsingError was thrown');
}

void main() {
  forbidRealNetwork();

  late _Smartschool server;
  late MessagesService messages;

  Future<void> serve(List<_Answer> answers) async {
    server = _Smartschool(answers);
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
  }

  group('the answers of a search that are XML are read as before', () {
    test('users and groups found', () async {
      await serve([_xml(_usersFound), _xml(_groupsFound)]);

      final (users, groups) = await messages.searchRecipientsForCompose('John');
      final (noUsers, foundGroups) = await messages.searchRecipientsForCompose(
        '1A',
      );

      expect(users.map((u) => u.displayName), _foundNames);
      expect(users.first.userId, 146);
      expect(users.first.ssId, 4069);
      expect(groups, isEmpty);
      expect(noUsers, isEmpty);
      expect(foundGroups.map((g) => g.groupId), [298, 312]);
    });

    test('an empty answer with status 200 holds no users and no groups, as '
        'before', () async {
      await serve([_html(''), _xml('  \n')]);

      final (users, groups) = await messages.searchRecipientsForCompose('zq');
      final (users2, groups2) = await messages.searchRecipientsForCompose('zq');

      expect(users, isEmpty);
      expect(groups, isEmpty);
      expect(users2, isEmpty);
      expect(groups2, isEmpty);
      expect(server.log, [_form, _search, _form, _search]);
    });
  });

  group('an answer to the search that is not XML is a SmartschoolException, '
      'not a FormatException (#112)', () {
    test('a piece of a page, as Smartschool answers an XHR to a module page '
        'with, says what it is', () async {
      await serve([_html(_fragment)]);

      // Before the fix: a FormatException ("Failed to parse Smartschool XML
      // response: XmlParserException: ..."), not a SmartschoolException.
      final error = await _pageErrorOf(
        () => messages.searchRecipientsForCompose('Janssens'),
      );

      expect(error, isA<SmartschoolAuthenticationError>());
      expect(error, isNot(isA<SmartschoolSessionExpiredError>()));
      expect(error.isLoginPage, isFalse);
      expect(error.action, 'searchUsers');
      expect(error.statusCode, 200);
      expect(error.contentType, 'text/html; charset=UTF-8');
      expect(error.url, Uri.parse(_searchUrl));
      expect(error.title, isNull);
      expect(error.heading, 'Berichten');
      expect(error.excerpt, 'Berichten Er ging iets mis. Probeer het opnieuw.');
      expect(
        error.message,
        'Smartschool returned HTML instead of XML for "searchUsers": a page '
        'that is not its login page (status 200, text/html; charset=UTF-8, '
        'heading "Berichten"), so not a sign of an expired session: '
        "Smartschool's web client reports such an answer as an unknown error. "
        'Response URL: $_searchUrl',
      );
      for (final kept in [error.message, error.excerpt!, error.toString()]) {
        expect(kept, isNot(contains('Jan Janssens')));
      }
    });

    test('a piece of a page that is well-formed XML is not read as a search '
        'without matches', () async {
      await serve([_html(_wellFormedFragment)]);

      // Before the fix: no users and no groups, as for a name no one has.
      final error = await _pageErrorOf(
        () => messages.searchRecipientsForCompose('Janssens'),
      );

      expect(error.isLoginPage, isFalse);
      expect(error.action, 'searchUsers');
      expect(error.heading, 'Berichten');
      expect(error.excerpt, 'Berichten Er ging iets mis.');
    });

    test('an error page with status 500 keeps its status, title and heading, '
        'without the user in its script', () async {
      await serve([_html(_errorPage, status: 500)]);

      final error = await _pageErrorOf(
        () => messages.searchRecipientsForCompose('Janssens'),
      );

      expect(error.isLoginPage, isFalse);
      expect(error.statusCode, 500);
      expect(error.title, 'Springfield Academy - Smartschool');
      expect(error.heading, 'Er is een fout opgetreden');
      expect(
        error.message,
        allOf(
          contains('for "searchUsers": a page that is not its login page '),
          contains('(status 500, text/html; charset=UTF-8, title '),
        ),
      );
      for (final kept in [error.message, error.excerpt!]) {
        expect(kept, isNot(contains('Jan Janssens')));
      }
    });

    test('the login page is told apart', () async {
      await serve([_html(_loginPage)]);

      final error = await _pageErrorOf(
        () => messages.searchRecipientsForCompose('Janssens'),
      );

      expect(error.isLoginPage, isTrue);
      expect(error.action, 'searchUsers');
      expect(
        error.message,
        contains('for "searchUsers": its login page (status 200'),
      );
      // The form, with the username it kept, is left out.
      expect(error.excerpt, isNull);
    });

    test('malformed XML is a SmartschoolParsingError that says where the XML '
        'breaks off, without the names it holds', () async {
      await serve([_xml(_cutOffUsers)]);

      // Before the fix: a FormatException, whose message held the parser's
      // message.
      final error = await _parsingErrorOf(
        () => messages.searchRecipientsForCompose('John'),
      );

      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(
        error.message,
        allOf(
          startsWith(
            'Smartschool returned an answer for "searchUsers" that is not '
            'well-formed XML (status 200, text/xml; charset=UTF-8, url: '
            '$_searchUrl): ',
          ),
          matches(RegExp(r' at \d+:\d+$')),
        ),
      );
      for (final name in ['John', 'Smith', 'Admin User', '146', '4069']) {
        expect(error.message, isNot(contains(name)));
      }
    });

    test('an answer that does not start with "<" is a SmartschoolParsingError '
        'with its status', () async {
      await serve([_html('Fatal error: zoekopdracht mislukt', status: 500)]);

      // Before the fix: a FormatException.
      final error = await _parsingErrorOf(
        () => messages.searchRecipientsForCompose('John'),
      );

      expect(
        error.message,
        'Smartschool returned a non-XML response for "searchUsers" (status '
        '500, text/html; charset=UTF-8, url: $_searchUrl): Fatal error: '
        'zoekopdracht mislukt',
      );
    });

    test('an empty answer with another status than 200 is a '
        'SmartschoolParsingError, not a search without matches', () async {
      await serve([_html('', status: 502)]);

      // Before the fix: no users and no groups.
      final error = await _parsingErrorOf(
        () => messages.searchRecipientsForCompose('John'),
      );

      expect(
        error.message,
        'Smartschool returned a non-XML response for "searchUsers" (status '
        '502, text/html; charset=UTF-8, url: $_searchUrl): empty',
      );
    });
  });

  group('such an answer is thrown as it is: it loads no new compose form and '
      'does not log in again, as a refused session would (#97, #107)', () {
    test('searchRecipientsForCompose: one form and one search, and the next '
        'call searches on a new form as usual', () async {
      await serve([_html(_fragment), _xml(_cutOffUsers), _html(_loginPage)]);

      await expectLater(
        messages.searchRecipientsForCompose('Janssens'),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      await expectLater(
        messages.searchRecipientsForCompose('Janssens'),
        throwsA(isA<SmartschoolParsingError>()),
      );
      // Not even for the login page: the client tells a refused session
      // apart before (a 401, a redirect to the login chain).
      await expectLater(
        messages.searchRecipientsForCompose('Janssens'),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      final (users, _) = await messages.searchRecipientsForCompose('John');

      expect(users.map((u) => u.displayName), _foundNames);
      expect(server.log, [
        _form, _search, // the piece of a page
        _form, _search, // the malformed XML
        _form, _search, // the login page
        _form, _search, // the search that finds users
      ], reason: 'no new form after such an answer, and no login');
    });

    test('searchRecipientsForComposeAll: the searches before it went out on '
        'the one form, the ones after it do not go out', () async {
      await serve([_xml(_groupsFound), _html(_fragment)]);

      final error = await _pageErrorOf(
        () => messages.searchRecipientsForComposeAll(['1A', 'Janssens', 'X']),
      );

      expect(error.action, 'searchUsers');
      expect(server.log, [_form, _search, _search]);
      expect(server.searches.map((s) => s.split(' ').first), [
        '1A',
        'Janssens',
      ]);
      expect(
        server.searches.map((s) => s.split(' ').last).toSet(),
        hasLength(1),
        reason: 'both searches went out with the uniqueUsc of the one form',
      );
    });
  });
}
