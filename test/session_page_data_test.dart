// Tests for issue #212: reading the authenticated user from the page data
// of Smartschool's pages (`SmartschoolClient.authenticatedUser` and
// `getCurrentUser`).
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

    test('a page without vars.authenticatedUser is still a '
        'SmartschoolAuthenticationError', () async {
      final (server, client) = await serve(
        smartschoolPage([
          mergeScript('{"vars":{"showNotifyAlerts":false}}'),
          mergeScript('{"quickSearch":{}}'),
          mergeScript('{"topnav":{}}'),
        ]),
      );

      await expectLater(
        client.authenticatedUser,
        throwsA(
          isA<SmartschoolAuthenticationError>().having(
            (e) => e.message,
            'message',
            'Could not retrieve authenticated user information',
          ),
        ),
      );
      await expectLater(
        client.getCurrentUser(),
        throwsA(isA<SmartschoolAuthenticationError>()),
      );
      expect(server.paths, contains('/'));
    });
  });
}
