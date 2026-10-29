// Tests for issues #212, #213 and #214: reading the authenticated user from
// the page data of Smartschool's pages (`SmartschoolClient.authenticatedUser`
// and `getCurrentUser`), the error for a page without the user (#214), and
// undoing the escapes of the JavaScript string that holds it (#213, at the
// end of the file).
//
// Since 2026-10 Smartschool hands its page data to its JavaScript in inline
// scripts that merge each block into `window.SMSC`
// (`window.smscMergeJsVariables(window.SMSC, data)`, applied to a
// `JSON.parse('...')`), one script per block; before, a script handed it to
// `APP.extend(...)` or `$.extend(...)`. The client skipped every script that
// did not hold `extend`, so it found no user on the new pages and every call
// that needs the own user failed with "Could not retrieve authenticated user
// information". The pages below are written by hand after the shape of the
// live start page (read-only, 2026-10-29), with made-up data
// (test/support/page_data.dart).
//
// The client reads the user from the start page (`GET /`) when no login ran
// for the request before it: the session in the cookie cache is valid. The
// fake Smartschool answers only the course list (from which the platform ID
// is read, so no login) and `/`, and fails the test on any other request.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/page_data.dart';
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
  String? get mfa => null;
}

/// A Smartschool in a valid session whose start page (`/`) is [startPage],
/// and which fails the test on any request but the course list and `/`.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(this.startPage);

  final String startPage;

  /// The path of every request that reached it, in order.
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    paths.add(path);
    expect(options.method, 'GET', reason: 'reading the user only reads');
    final (body, contentType) = switch (path) {
      '/course-list/api/v1/courses' => (
        '[{"platformId":49}]',
        'application/json',
      ),
      '/' => (startPage, 'text/html; charset=UTF-8'),
      _ => fail('Unexpected request: ${options.method} ${options.uri}'),
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SmartschoolClient)> serve(String startPage) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(startPage);
    client.dio.httpClientAdapter = server;
    return (server, client);
  }

  /// The user of [authenticatedUserJson], as `getCurrentUser` gives it.
  final janJanssens = isA<SmartschoolUser>()
      .having((u) => u.id, 'id', 777)
      .having((u) => u.displayName, 'displayName', 'Jan Janssens');

  group('SmartschoolClient.authenticatedUser (#212)', () {
    test('reads the user from the scripts that merge the page data into '
        'window.SMSC (smscMergeJsVariables), past a vars block without '
        'the user', () async {
      final (server, client) = await serve(startPage());

      final user = await client.authenticatedUser;

      expect(user['id'], '49_777_0');
      expect(user['name'], {
        'startingWithFirstName': 'Jan Janssens',
        'startingWithLastName': 'Janssens Jan',
      });
      expect(user['pictureHash'], 'initials_JJ');
      expect(user['deleted'], isFalse);
      expect(await client.getCurrentUser(), janJanssens);
      // Read once, from the start page, and kept.
      expect(server.paths, ['/course-list/api/v1/courses', '/']);
    });

    test(
      'goes on past scripts that hold other data, a script loaded from '
      'a src and one that is not JSON, to the first vars with the user',
      () async {
        final (_, client) = await serve(
          smartschoolPage([
            '<script type="text/javascript" nonce="fake-nonce" '
                'src="/js/app.js"></script>',
            mergeScript(
              '{"quickSearch":{"quicksearch.search_placeholder":'
              '"Zoeken..."}}',
            ),
            mergeScript('null'),
            mergeScript('{"vars":[]}'),
            mergeScript('{"vars":{"authenticatedUser":null}}'),
            mergeScript('{not json'),
            mergeScript(
              '{"vars":{"authenticatedUser":'
              '${authenticatedUserJson()}}}',
            ),
            mergeScript(
              '{"vars":{"authenticatedUser":'
              '${authenticatedUserJson(id: '49_888_0')}}}',
            ),
          ]),
        );

        expect((await client.authenticatedUser)['id'], '49_777_0');
        expect(await client.getCurrentUser(), janJanssens);
      },
    );

    test('keeps the number of a co-account in the ID', () async {
      final (_, client) = await serve(
        startPage(userJson: authenticatedUserJson(id: '49_777_2')),
      );

      expect((await client.authenticatedUser)['id'], '49_777_2');
      expect((await client.getCurrentUser()).id, 777);
    });

    test('still reads the user from APP.extend(APP.vars || {}, '
        'JSON.parse(...)), the form before #212', () async {
      final (_, client) = await serve(
        smartschoolPage([
          appExtendScript(
            '{"vars":{"authenticatedUser":'
            '${authenticatedUserJson()}}}',
          ),
        ]),
      );

      expect((await client.authenticatedUser)['id'], '49_777_0');
      expect(await client.getCurrentUser(), janJanssens);
    });

    test(r'and from $.extend(true, SMSC, JSON.parse(...)), past a block '
        'without the user', () async {
      final (_, client) = await serve(
        smartschoolPage([
          jQueryExtendScript('{"wopiConfig":{}}'),
          jQueryExtendScript(
            '{"quickSearch":{},"vars":{"authenticatedUser":'
            '${authenticatedUserJson()}}}',
          ),
        ]),
      );

      expect(await client.getCurrentUser(), janJanssens);
    });
  });

  // Issue #214: a page without vars.authenticatedUser, read in a session that
  // Smartschool accepted, was the same SmartschoolAuthenticationError "Could
  // not retrieve authenticated user information" as a failed login, which
  // pointed the wrong way when #212 showed itself. It is now a
  // SmartschoolAuthenticatedUserNotFoundError, a subclass, that keeps the
  // shape of the page data and none of its values.
  group('a page without vars.authenticatedUser in an accepted session '
      '(#214):', () {
    /// The error of a page without the user: still a
    /// SmartschoolAuthenticationError, with the words of the error before
    /// #214 at the start of its message, but no login failure.
    final userNotFound = isA<SmartschoolAuthenticatedUserNotFoundError>()
        .having(
          (e) => e,
          'a SmartschoolAuthenticationError',
          isA<SmartschoolAuthenticationError>(),
        )
        .having(
          (e) => e.message,
          'message',
          startsWith('Could not retrieve authenticated user information'),
        )
        .having(
          (e) => e,
          'no login failure',
          isNot(
            anyOf(
              isA<SmartschoolSessionExpiredError>(),
              isA<SmartschoolInvalidCredentialsError>(),
              isA<SmartschoolUnexpectedPageError>(),
            ),
          ),
        );

    test('is a SmartschoolAuthenticatedUserNotFoundError with the path, the '
        'status and the shape of the page data, from authenticatedUser and '
        'getCurrentUser, without logging in', () async {
      final (server, client) = await serve(
        smartschoolPage([
          '<script type="text/javascript" nonce="fake-nonce" '
              'src="/js/app.js"></script>',
          '<script type="text/javascript">var SMSC = SMSC || {};</script>',
          mergeScript('{"vars":{"showNotifyAlerts":false,"isMP":false}}'),
          mergeScript(
            '{"quickSearch":{"quicksearch.search_placeholder":"Zoeken..."},'
            '"vars":{"ssID":49}}',
          ),
          mergeScript('{not json'),
          mergeScript('null'),
          mergeScript('{"topnav":{"title":"Springfield Academy"}}'),
        ]),
      );

      final shape = userNotFound
          .having((e) => e.path, 'path', '/')
          .having((e) => e.statusCode, 'statusCode', 200)
          // The five scripts that end with JSON.parse('...'), not the one
          // loaded from a src or the one without JSON.parse.
          .having((e) => e.pageDataScripts, 'pageDataScripts', 5)
          .having(
            (e) => e.unreadablePageDataScripts,
            'unreadablePageDataScripts',
            2,
          )
          .having((e) => e.pageDataKeys, 'pageDataKeys', [
            'vars',
            'quickSearch',
            'topnav',
          ])
          .having(
            (e) => e.message,
            'message',
            allOf(
              contains("Smartschool's page / (status 200)"),
              contains(
                "5 inline scripts with JSON.parse('...'), 2 of them "
                'without a JSON object; top-level keys: vars, quickSearch, '
                'topnav',
              ),
              contains('not a failed login'),
            ),
          );
      await expectLater(client.authenticatedUser, throwsA(shape));
      await expectLater(client.getCurrentUser(), throwsA(shape));
      // The start page was read in the session of the cookie cache: no login
      // (the fake fails the test on any other request).
      expect(server.paths.toSet(), {'/course-list/api/v1/courses', '/'});
    });

    test('holds none of the values of the page data: not the name of a user '
        'kept under another key, not the keys of vars, not the text of the '
        'page', () async {
      final (_, client) = await serve(
        smartschoolPage([
          '<p>Welkom, Jan Janssens</p>',
          mergeScript(
            '{"vars":{"authUser":{"id":"49_777_0","name":'
            '{"startingWithFirstName":"Jan Janssens",'
            '"startingWithLastName":"Janssens Jan"}},"ssID":49}}',
          ),
          mergeScript('{"topnav":{"title":"Springfield Academy"}}'),
        ]),
      );

      final error = await client.authenticatedUser.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      expect(error, userNotFound);
      final e = error! as SmartschoolAuthenticatedUserNotFoundError;
      expect(e.pageDataKeys, ['vars', 'topnav']);
      for (final value in [
        'Jan',
        'Janssens',
        '777',
        '49_',
        'authUser',
        'ssID',
        'Springfield',
        'Welkom',
      ]) {
        expect(e.message, isNot(contains(value)));
        expect(e.toString(), isNot(contains(value)));
      }
    });

    test(
      'a page without a script with JSON.parse says that it has none',
      () async {
        final (_, client) = await serve(
          smartschoolPage([
            '<script type="text/javascript">'
                "window.SMSC = {vars: {}};</script>",
          ]),
        );

        await expectLater(
          client.authenticatedUser,
          throwsA(
            userNotFound
                .having((e) => e.pageDataScripts, 'pageDataScripts', 0)
                .having(
                  (e) => e.unreadablePageDataScripts,
                  'unreadablePageDataScripts',
                  0,
                )
                .having((e) => e.pageDataKeys, 'pageDataKeys', isEmpty)
                .having(
                  (e) => e.message,
                  'message',
                  contains(
                    "page / (status 200) holds no vars.authenticatedUser in "
                    "its page data (no inline script with JSON.parse('...'))",
                  ),
                ),
          ),
        );
      },
    );
  });

  // Issue #213: the page data is JSON in a JavaScript string, with the
  // escaping of Smartschool's templates (jsEscaped), and the JSON has `/` as
  // `\/` itself (smartschoolJson): the `/` of a URL is `\\\/` on the page.
  // The escapes were undone in two passes (every `\uXXXX`, then every
  // `\\`), which left `\/`: the picture URL came out as `https:\/\/...`.
  group('the page data is JSON in a JavaScript string (#213):', () {
    /// The picture of [authenticatedUserJson], as the URL it is.
    const pictureUrl =
        'https://userpicture20.smartschool.be/User/Userimage/hashimage/hash/'
        'initials_JJ/plain/1/res/128';

    test('getCurrentUser gives the picture URL with its slashes, on the '
        'start page as it is served since 2026-10', () async {
      final (_, client) = await serve(startPage());

      expect((await client.authenticatedUser)['pictureUrl'], pictureUrl);
      expect((await client.getCurrentUser()).avatarUrl, pictureUrl);
    });

    for (final (form, script) in [
      ('APP.extend(APP.vars || {}, JSON.parse(...))', appExtendScript),
      (r'$.extend(true, SMSC, JSON.parse(...))', jQueryExtendScript),
    ]) {
      test('and from $form', () async {
        final (_, client) = await serve(
          smartschoolPage([
            script(
              '{"vars":{"authenticatedUser":'
              '${authenticatedUserJson()}}}',
            ),
          ]),
        );

        expect((await client.getCurrentUser()).avatarUrl, pictureUrl);
      });
    }

    test(r'a name with a ", a \, a /, an apostrophe and letters outside '
        'ASCII comes out as written', () async {
      const firstNameFirst = 'Zoë "Jo" D\'Hondt \\ A/B \u{1F600}';
      const lastNameFirst = 'D\'Hondt \\ A/B Zoë "Jo" \u{1F600}';
      final (_, client) = await serve(
        startPage(
          userJson: smartschoolJson({
            'id': '49_777_0',
            'pictureUrl': pictureUrl,
            'name': {
              'startingWithFirstName': firstNameFirst,
              'startingWithLastName': lastNameFirst,
            },
          }),
        ),
      );

      expect((await client.authenticatedUser)['name'], {
        'startingWithFirstName': firstNameFirst,
        'startingWithLastName': lastNameFirst,
      });
      final user = await client.getCurrentUser();
      expect(user.displayName, firstNameFirst);
      expect(user.avatarUrl, pictureUrl);
    });

    test(r'JSON that writes a letter outside ASCII as \uXXXX (as json_encode '
        r'does by default), which is \\uXXXX on the page, is read', () async {
      final (_, client) = await serve(
        startPage(
          userJson: authenticatedUserJson(
            firstNameFirst: r'Zo\u00eb Janssens',
            lastNameFirst: r'Janssens Zo\u00EB',
          ),
        ),
      );

      final user = await client.getCurrentUser();
      expect(user.displayName, 'Zoë Janssens');
      expect((await client.authenticatedUser)['name'], {
        'startingWithFirstName': 'Zoë Janssens',
        'startingWithLastName': 'Janssens Zoë',
      });
    });

    test(r'JSON with line breaks and tabs between its tokens, which are \n, '
        r'\r and \t on the page, is read', () async {
      final (_, client) = await serve(
        smartschoolPage([
          mergeScript(
            '{\n\t"vars": {\r\n\t\t"authenticatedUser": '
            '${authenticatedUserJson()}\n\t}\n}',
          ),
        ]),
      );

      expect(await client.getCurrentUser(), janJanssens);
    });
  });
}
