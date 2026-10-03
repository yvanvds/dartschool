// Tests for issue #106: Smartschool answered a `message list` (an XML command
// of the Messages dispatcher) with an HTML page, once, in the middle of a
// live run, and `SmartschoolClient.postXml` threw it as a failed login
// ("Login may have failed or expired"), although the same session listed the
// boxes again right after. The page itself was not kept.
//
// Seen live (2026-10-03, read-only):
// - on a session that is not there, Smartschool answers an XML command with
//   an empty `401` (with `X-Requested-With`, as the library sends it), or
//   with `302 Location: /login` (without it): the answers on which the
//   client logs in again, before `postXml` sees them. A malformed command
//   gets an XML error, not a page;
// - Smartschool serves some error pages with status `200`: a GET of a path it
//   does not know got its "page not found" page, titled with the school's
//   name ("<school> - Smartschool", as its login page is) and naming the
//   error in its `<h1>`, with the signed-in user (ID, name, picture) in a
//   script;
// - its login page holds `form[name="login_form"]`, the form the client's
//   login fills in;
// - Smartschool's web client (the Messages module's main-built.js) reloads
//   the page on a `500`, goes to `/` on a `401`, and reports a `200` that is
//   not XML as an unknown error, going on in the same session;
// - 31 reads in 4 seconds (message lists of the inbox and the sent box, and
//   show message of sent-box copies, six of them at once) were all answered
//   with XML: the page did not come back.
//
// So an HTML page that reaches `postXml` is not an expired session in any
// shape the client knows; what it was in #106 is still unknown. `postXml`
// now throws a `SmartschoolUnexpectedPageError` (a
// `SmartschoolAuthenticationError`, as before) that says whether the page is
// the login page, and keeps the status, the title and the main heading of
// the page, and the start of its text, without its scripts and forms.
//
// Issue #110: an answer that starts with `<` but neither with an HTML doctype
// or `<html` nor is well-formed XML went to the XML parser, whose
// `FormatException` escaped `postXml`: not a `SmartschoolException`. Seen
// live (read-only, 2026-10-03): Smartschool answers an XHR POST to a module
// page with a piece of a page that starts with `<!-- TRANSPARANT LAYER -->`
// (status `200`, `text/html`). So `postXml` now reads an answer as HTML also
// after a comment, and for a piece of a page, one that happens to be
// well-formed XML included, and throws a `SmartschoolParsingError` for other
// malformed XML.
//
// The fake Smartschool below answers the dispatcher's commands with the pages
// given, in turn, and then with the recorded `message list`.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

const _dispatcher = 'https://$_host/?module=Messages&file=dispatcher';

final _messageList = File(
  'test/fixtures/smartschool/requests/post/postboxes/message list.xml',
).readAsStringSync();

/// The signed-in user as Smartschool's pages carry them, in a script.
const _userScript =
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\''
    '{"vars":{"authenticatedUser":{"id":"49_777_0","name":'
    '{"startingWithFirstName":"Jan Janssens"}}}}\'));</script>';

/// Smartschool's "page not found" page, in the shape of the one seen live
/// (status `200`), with a made-up school and user.
const _errorPage =
    '\n\n<!DOCTYPE html>\n'
    '<!--\n  ___ __  __   _   ___ _____ ___  ___ _  _  ___   ___  _\n-->\n'
    '<html lang="nl">\n'
    '  <head>\n'
    '    <title>Springfield Academy - Smartschool</title>\n'
    '    <meta charset="utf-8">\n'
    '    <style>.container { color: red; }</style>\n'
    '    <script type="text/javascript">window.SMSC = {};</script>\n'
    '  </head>\n'
    '  <body class=" ">\n'
    '    <div id="smscMain" class="smscMain " tabindex="-1">\n'
    '      <div class="container"><div class="container-textbox">\n'
    '        <h1>De opgevraagde pagina kon niet worden gevonden</h1>\n'
    '        <p>Het lijkt er op dat de pagina of het bestand dat je probeert '
    'te bekijken niet meer bestaat.</p>\n'
    '        <div class="container-textbox-links">'
    '<a href="/">Ga naar de startpagina</a>'
    '<a href="/?module=Manual">Ga naar de handleiding</a></div>\n'
    '      </div></div>\n'
    '    </div>\n'
    '    $_userScript\n'
    '  </body>\n'
    '</html>\n';

/// The text of [_errorPage], as `excerpt` keeps it.
const _errorPageText =
    'De opgevraagde pagina kon niet worden gevonden Het lijkt er op dat de '
    'pagina of het bestand dat je probeert te bekijken niet meer bestaat. Ga '
    'naar de startpagina Ga naar de handleiding';

/// An error page of a proxy in front of a web server, such as nginx's.
const _gatewayPage =
    '<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n<body>\r\n'
    '<center><h1>502 Bad Gateway</h1></center>\r\n<hr><center>nginx</center>'
    '\r\n</body>\r\n</html>\r\n';

/// Smartschool's login page, in the shape of the one seen live, after a
/// login that kept the username.
const _loginPage =
    '<!DOCTYPE html>\n<html lang="nl"><head>'
    '<title>Springfield Academy - Smartschool</title></head><body>'
    '<div class="login-app">Springfield Academy</div>'
    '<form class="form" name="login_form" method="post">'
    '<label>Gebruikersnaam</label>'
    '<input type="text" name="login_form[_username]" value="jan.janssens">'
    '<label>Wachtwoord</label>'
    '<input type="password" name="login_form[_password]">'
    '<input type="hidden" name="login_form[_token]" '
    'value="Xy7pQ2rT9vW4kL1mN8bC3dF6gH0jK5sA">'
    '<button type="submit">Aanmelden</button>'
    '</form></body></html>';

/// Smartschool's account verification page (the step after the password).
const _accountVerificationPage =
    '<!DOCTYPE html><html><head>'
    '<title>Springfield Academy - Smartschool</title></head><body>'
    '<form class="form" name="account_verification_form" method="post">'
    '<input type="date" name="account_verification_form[_birthday]">'
    '</form></body></html>';

/// An answer of the fake Smartschool's dispatcher.
typedef _Page = ({String body, int status, String contentType});

_Page _html(String body, {int status = 200}) =>
    (body: body, status: status, contentType: 'text/html; charset=UTF-8');

/// A Smartschool whose dispatcher answers the commands with [pages], one per
/// command, and then with the recorded `message list`.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(List<_Page> pages) : _pages = [...pages];

  final List<_Page> _pages;

  /// Every request that reached it, as `METHOD <path and query>`.
  final List<String> log = [];

  /// The action of every XML command that reached it.
  final List<String> actions = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    log.add('${options.method} ${uri.path}?${uri.query}');
    final command = (options.data as Map)['command'] as String;
    actions.add(RegExp('<action>(.*?)</action>').firstMatch(command)![1]!);
    final page = _pages.isEmpty
        ? (body: _messageList, status: 200, contentType: 'application/xml')
        : _pages.removeAt(0);
    return ResponseBody.fromString(
      page.body,
      page.status,
      headers: {
        Headers.contentTypeHeader: [page.contentType],
      },
    );
  }

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

/// What a caller gets from [call]: the error it throws.
Future<SmartschoolUnexpectedPageError> _thrownBy(
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

/// An XHTML page: an XML declaration and an HTML doctype before `<html>`, and
/// well-formed XML.
const _xhtmlPage =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" '
    '"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\n'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    '<title>Onderhoud</title></head><body>'
    '<h1>Smartschool is in onderhoud</h1></body></html>';

/// The recorded `message list`, cut off in its second message: malformed
/// XML.
final _cutOffMessageList = _messageList.substring(
  0,
  _messageList.indexOf('<subject>Frans'),
);

_Page _xml(String body) =>
    (body: body, status: 200, contentType: 'text/xml; charset=UTF-8');

void main() {
  forbidRealNetwork();

  late _Smartschool server;
  late MessagesService messages;

  Future<void> serve(List<_Page> pages) async {
    server = _Smartschool(pages);
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    messages = MessagesService(client);
  }

  group('an HTML page that is not the login page is not read as a failed '
      'login (#106)', () {
    test('getHeaders: an error page of Smartschool, with status 200, says '
        'what the page is', () async {
      await serve([_html(_errorPage)]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.action, 'message list');
      expect(error.statusCode, 200);
      expect(error.contentType, 'text/html; charset=UTF-8');
      expect(error.url, Uri.parse(_dispatcher));
      expect(error.title, 'Springfield Academy - Smartschool');
      expect(error.heading, 'De opgevraagde pagina kon niet worden gevonden');
      expect(error.excerpt, _errorPageText);
      expect(
        error.message,
        'Smartschool returned HTML instead of XML for "message list": a page '
        'that is not its login page (status 200, text/html; charset=UTF-8, '
        'title "Springfield Academy - Smartschool", heading "De opgevraagde '
        'pagina kon niet worden gevonden"), so not a sign of an expired '
        "session: Smartschool's web client reports such an answer as an "
        'unknown error. Response URL: $_dispatcher',
      );
      // Before the fix: "... Login may have failed or expired. Response URL:
      // ...", the same for every page.
      expect(error.message, isNot(contains('Login may have failed')));
    });

    test('it is still a SmartschoolAuthenticationError, as postXml threw '
        'before, and not an expired session', () async {
      await serve([_html(_errorPage)]);

      await expectLater(
        messages.getHeaders(),
        throwsA(
          allOf(
            isA<SmartschoolAuthenticationError>(),
            isNot(isA<SmartschoolSessionExpiredError>()),
            isA<SmartschoolUnexpectedPageError>(),
          ),
        ),
      );
    });

    test('the client does not log in again for it, and the session goes on: '
        'the next getHeaders lists the box, as in the live run', () async {
      await serve([_html(_errorPage)]);

      await expectLater(
        messages.getHeaders(),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      final headers = await messages.getHeaders();

      expect(headers, isNotEmpty);
      expect(server.log, [
        'POST /?module=Messages&file=dispatcher',
        'POST /?module=Messages&file=dispatcher',
      ], reason: 'no login, and no retry of the command');
      expect(server.actions, ['message list', 'message list']);
    });

    test("an error page with another status, such as a proxy's 502, keeps "
        'its status and title', () async {
      await serve([_html(_gatewayPage, status: 502)]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.statusCode, 502);
      expect(error.title, '502 Bad Gateway');
      expect(error.heading, '502 Bad Gateway');
      expect(error.excerpt, '502 Bad Gateway nginx');
      expect(
        error.message,
        allOf(
          contains('a page that is not its login page (status 502, '),
          contains('title "502 Bad Gateway"'),
        ),
      );
    });

    test('getMessage (show message) and moveToTrashFrom (a change) throw it '
        'too, with their command', () async {
      await serve([_html(_errorPage), _html(_errorPage)]);

      final shown = await _thrownBy(() => messages.getMessage(4242));
      final moved = await _thrownBy(
        () => messages.moveToTrashFrom(4242, boxType: BoxType.sent),
      );

      expect(shown.action, 'show message');
      expect(shown.message, contains('for "show message": a page that is not'));
      expect(moved.action, 'quickmove messages');
      expect(server.actions, ['show message', 'quickmove messages']);
    });
  });

  group('a login page is told apart (#106)', () {
    test('a page with the login form', () async {
      await serve([_html(_loginPage)]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isTrue);
      expect(error.statusCode, 200);
      expect(error.title, 'Springfield Academy - Smartschool');
      expect(
        error.message,
        'Smartschool returned HTML instead of XML for "message list": its '
        'login page (status 200, text/html; charset=UTF-8, title "Springfield '
        'Academy - Smartschool"). It did not accept the session, although not '
        'in a way that makes the client log in again (a 401, or a redirect to '
        'its login chain). Response URL: $_dispatcher',
      );
      // The form, with the username it kept and its token, is left out.
      expect(error.excerpt, 'Springfield Academy');
      expect(server.log, hasLength(1), reason: 'no login');
    });

    test('a page with the account verification form', () async {
      await serve([_html(_accountVerificationPage)]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isTrue);
      expect(error.message, contains('its login page (status 200'));
    });
  });

  group('the error keeps no scripts, forms, e-mail addresses or tokens of the '
      'page (#106)', () {
    test("the signed-in user in a script of Smartschool's page is neither in "
        'the message nor in the excerpt', () async {
      await serve([_html(_errorPage)]);

      final error = await _thrownBy(messages.getHeaders);

      for (final kept in [error.message, error.excerpt!, error.toString()]) {
        expect(kept, isNot(contains('Jan Janssens')));
        expect(kept, isNot(contains('authenticatedUser')));
        expect(kept, isNot(contains('color: red')));
      }
    });

    test("a form's options and values are left out, e-mail addresses and "
        'tokens masked, and a long title or text cut off', () async {
      final longTitle = 'Onderhoud ${'x' * 200}';
      final longText = List.filled(60, 'woord').join(' ');
      await serve([
        _html(
          '<!DOCTYPE html><html><head><title>$longTitle</title></head><body>'
          '<h2>Fout bij jan.janssens@springfield.be</h2>'
          '<p>Sessie 5odeg88vqd80f3vsmek44n1b16ppv8vrlfo8tkmrgjkqfsfi51 '
          'verlopen, leerlingenadministratiesysteem werkt.</p>'
          '<form><select><option>Piet Peeters</option></select>'
          '<input name="q" value="geheim"><textarea>Nota</textarea></form>'
          '<p>$longText</p></body></html>',
        ),
      ]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.heading, 'Fout bij [e-mail]');
      expect(
        error.excerpt,
        startsWith(
          'Fout bij [e-mail] Sessie [token] verlopen, '
          // A long word without digits is not a token.
          'leerlingenadministratiesysteem werkt. woord woord',
        ),
      );
      expect(error.excerpt, endsWith('...'));
      expect(
        error.excerpt!.length,
        SmartschoolUnexpectedPageError.maxExcerptLength + 3,
      );
      expect(
        error.title,
        '${longTitle.substring(0, SmartschoolUnexpectedPageError.maxLabelLength)}'
        '...',
      );
      for (final kept in [error.message, error.excerpt!]) {
        expect(kept, isNot(contains('springfield.be')));
        expect(kept, isNot(contains('5odeg88')));
        expect(kept, isNot(contains('Piet Peeters')));
        expect(kept, isNot(contains('geheim')));
        expect(kept, isNot(contains('Nota')));
      }
    });

    test('a page without a title, heading or text', () async {
      await serve([_html('<html><head></head><body> </body></html>')]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.title, isNull);
      expect(error.heading, isNull);
      expect(error.excerpt, isNull);
      expect(
        error.message,
        contains(
          'a page that is not its login page (status 200, text/html; '
          'charset=UTF-8), so',
        ),
      );
    });
  });

  test('fromPage without the answer\'s status, URL or content type', () {
    final error = SmartschoolUnexpectedPageError.fromPage(
      _gatewayPage,
      action: 'message list',
    );

    expect(error.statusCode, isNull);
    expect(error.url, isNull);
    expect(error.contentType, isNull);
    expect(
      error.message,
      'Smartschool returned HTML instead of XML for "message list": a page '
      'that is not its login page (status unknown, title "502 Bad Gateway", '
      'heading "502 Bad Gateway"), so not a sign of an expired session: '
      "Smartschool's web client reports such an answer as an unknown error.",
    );
    expect(
      error.toString(),
      'SmartschoolUnexpectedPageError: ${error.message}',
    );
  });

  group('an answer that starts with "<" but is not XML is a '
      'SmartschoolException, not a FormatException (#110)', () {
    test('getHeaders: a piece of a page that starts with a comment, as seen '
        'live, says what it is', () async {
      await serve([_html(_fragment)]);

      // Before the fix: a FormatException ("Failed to parse Smartschool XML
      // response: XmlParserException: ..."), not a SmartschoolException.
      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.action, 'message list');
      expect(error.statusCode, 200);
      expect(error.contentType, 'text/html; charset=UTF-8');
      expect(error.url, Uri.parse(_dispatcher));
      expect(error.title, isNull);
      expect(error.heading, 'Berichten');
      expect(error.excerpt, 'Berichten Er ging iets mis. Probeer het opnieuw.');
      expect(
        error.message,
        'Smartschool returned HTML instead of XML for "message list": a page '
        'that is not its login page (status 200, text/html; charset=UTF-8, '
        'heading "Berichten"), so not a sign of an expired session: '
        "Smartschool's web client reports such an answer as an unknown error. "
        'Response URL: $_dispatcher',
      );
      for (final kept in [error.message, error.excerpt!]) {
        expect(kept, isNot(contains('Jan Janssens')));
      }
    });

    test('a piece of a page that is well-formed XML is not read as an answer '
        'without messages', () async {
      await serve([_html(_wellFormedFragment)]);

      // Before the fix: getHeaders returned no headers, as for an empty box.
      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.heading, 'Berichten');
      expect(error.excerpt, 'Berichten Er ging iets mis.');
    });

    test('a page with a comment before its doctype keeps its title and '
        'heading', () async {
      await serve([_html('<!-- smsc -->\n$_errorPage')]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.title, 'Springfield Academy - Smartschool');
      expect(error.heading, 'De opgevraagde pagina kon niet worden gevonden');
      expect(error.excerpt, _errorPageText);
    });

    test('the login page after a comment is told apart', () async {
      await serve([_html('<!-- login -->\n$_loginPage')]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isTrue);
      expect(error.message, contains('its login page (status 200'));
      expect(server.log, hasLength(1), reason: 'no login');
    });

    test('an XHTML page, which is well-formed XML, is a page', () async {
      await serve([_html(_xhtmlPage)]);

      final error = await _thrownBy(messages.getHeaders);

      expect(error.isLoginPage, isFalse);
      expect(error.title, 'Onderhoud');
      expect(error.heading, 'Smartschool is in onderhoud');
    });

    test('malformed XML is a SmartschoolParsingError that says where the XML '
        'breaks off, without its content', () async {
      await serve([_xml(_cutOffMessageList)]);

      // Before the fix: a FormatException.
      final error = await _parsingErrorOf(messages.getHeaders);

      expect(error, isNot(isA<SmartschoolAuthenticationError>()));
      expect(
        error.message,
        allOf(
          startsWith(
            'Smartschool returned an answer for "message list" that is not '
            'well-formed XML (status 200, text/xml; charset=UTF-8, url: '
            '$_dispatcher): ',
          ),
          contains('XmlTagException'),
          matches(RegExp(r' at \d+:\d+$')),
        ),
      );
      // The messages it lists, cut off or not, are not in the error.
      for (final listed in ['Teacher', 'Re: LO les', '123456', '7890123']) {
        expect(error.message, isNot(contains(listed)));
      }
    });

    test(
      'an answer that is only a comment is a SmartschoolParsingError',
      () async {
        await serve([_html('<!-- leeg -->')]);

        final error = await _parsingErrorOf(messages.getHeaders);

        expect(error, isNot(isA<SmartschoolUnexpectedPageError>()));
        expect(
          error.message,
          startsWith(
            'Smartschool returned an answer for "message list" that is not '
            'well-formed XML (status 200, text/html; charset=UTF-8, url: ',
          ),
        );
      },
    );

    test('an answer that does not start with "<" is a SmartschoolParsingError '
        'that says its status and content type (#112)', () async {
      await serve([_html('Fatal error: lijst mislukt', status: 500)]);

      final error = await _parsingErrorOf(messages.getHeaders);

      // Before #112: '... for "message list" (url: ...): Fatal error: ...',
      // without the status. The recipient search reads its answer with the
      // same code since #112.
      expect(
        error.message,
        'Smartschool returned a non-XML response for "message list" (status '
        '500, text/html; charset=UTF-8, url: $_dispatcher): Fatal error: '
        'lijst mislukt',
      );
    });

    test('the client does not log in again or retry, and the session goes '
        'on', () async {
      await serve([_html(_fragment), _xml(_cutOffMessageList)]);

      await expectLater(
        messages.getHeaders(),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      await expectLater(
        messages.getHeaders(),
        throwsA(isA<SmartschoolParsingError>()),
      );
      final headers = await messages.getHeaders();

      expect(headers, isNotEmpty);
      expect(server.actions, ['message list', 'message list', 'message list']);
      expect(
        server.log,
        everyElement('POST /?module=Messages&file=dispatcher'),
      );
    });

    test('every command: getMessage and moveToTrash (which allows an empty '
        'answer) throw them too', () async {
      await serve([
        _html(_fragment),
        _xml('<server><response><status>ok</status>'),
        _html(_fragment),
      ]);

      final shown = await _thrownBy(() => messages.getMessage(4242));
      final moved = await _parsingErrorOf(
        () => messages.moveToTrashFrom(4242, boxType: BoxType.sent),
      );
      final deleted = await _thrownBy(() => messages.moveToTrash(4242));

      expect(shown.action, 'show message');
      expect(moved.message, contains('for "quickmove messages" that is not'));
      expect(deleted.action, 'quick delete');
      expect(server.actions, [
        'show message',
        'quickmove messages',
        'quick delete',
      ]);
    });
  });
}
