import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/src/session.dart';
import 'package:flutter_smartschool/src/credentials.dart';
import 'package:flutter_smartschool/src/exceptions.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

class DummyCredentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => 'school.smartschool.be';
  @override
  String? get mfa => null;
}

/// Stands in for Smartschool: answers every request with a `404 Not Found`,
/// and keeps each request as `<method> <path>`.
class _NotFound implements HttpClientAdapter {
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    return ResponseBody.fromString(
      '<html><body>Not Found</body></html>',
      404,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A request as [_Smartschool] received it.
class _Request {
  _Request(this.options, this.body);

  final RequestOptions options;

  /// The body that was sent, decoded as UTF-8.
  final String body;

  String get method => options.method;
  String get path => options.uri.path;
  Map<String, String> get query => options.uri.queryParameters;
  String? get contentType =>
      options.headers[Headers.contentTypeHeader] as String?;

  /// The `Cookie` header, or `null` when the request carried no cookie.
  String? get cookie => options.headers[HttpHeaders.cookieHeader] as String?;
}

/// Stands in for Smartschool: answers every request with a `200` and
/// [answer], and keeps each request it got and each time it was closed.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.answer = 'the answer', this.answerType = 'text/html'});

  /// The body of every answer.
  final String answer;

  /// The `Content-Type` of every answer.
  final String answerType;

  /// A `Set-Cookie` header that every answer carries while it is set.
  String? setCookie;

  final requests = <_Request>[];

  /// The `force` of each call to [close], in order.
  final closes = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    requests.add(_Request(options, utf8.decode(body)));
    final cookie = setCookie;
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [answerType],
        if (cookie != null) HttpHeaders.setCookieHeader: [cookie],
      },
    );
  }

  @override
  void close({bool force = false}) => closes.add(force);
}

/// A client that sends its requests to [server], with its data in [cacheDir]
/// (a temporary folder of its own when none is given).
Future<SmartschoolClient> _clientOf(
  _Smartschool server, {
  String? cacheDir,
}) async {
  final client = await SmartschoolClient.create(
    DummyCredentials(),
    cacheDir: cacheDir ?? tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  return client;
}

void main() {
  forbidRealNetwork();

  group('SmartschoolClient', () {
    test('clearCookies deletes the saved session: neither the client nor a '
        'new client in the same cacheDir sends it afterwards', () async {
      final cacheDir = tempCacheDir();
      final server = _Smartschool()..setCookie = 'PHPSESSID=abc123; Path=/';
      final client = await _clientOf(server, cacheDir: cacheDir);
      await client.getRaw('/');
      server.setCookie = null;

      // The session is kept, and saved in cacheDir for the next client.
      await client.getRaw('/');
      expect(server.requests.last.cookie, 'PHPSESSID=abc123');
      await (await _clientOf(server, cacheDir: cacheDir)).getRaw('/');
      expect(server.requests.last.cookie, 'PHPSESSID=abc123');

      await client.clearCookies();

      await client.getRaw('/');
      expect(server.requests.last.cookie, isNull);
      await (await _clientOf(server, cacheDir: cacheDir)).getRaw('/');
      expect(server.requests.last.cookie, isNull);
    });

    test('postFormRaw POSTs the fields form-urlencoded and returns the '
        'answer', () async {
      final server = _Smartschool(answer: '<users><user/></users>');
      final client = await _clientOf(server);

      final answer = await client.postFormRaw(
        '/search',
        {'val': 'Jan Janssens', 'type': '0'},
        query: {'module': 'Messages'},
      );

      expect(answer, '<users><user/></users>');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/search');
      expect(request.query, {'module': 'Messages'});
      expect(request.contentType, Headers.formUrlEncodedContentType);
      expect(Uri.splitQueryString(request.body), {
        'val': 'Jan Janssens',
        'type': '0',
      });
    });

    test('postMultipartRaw POSTs the form data as multipart/form-data and '
        'returns the answer', () async {
      final server = _Smartschool(answer: 'sent');
      final client = await _clientOf(server);
      final form = FormData.fromMap({
        'subject': 'Hallo',
        'file': MultipartFile.fromString('inhoud', filename: 'bijlage.txt'),
      });

      final answer = await client.postMultipartRaw('/send', form);

      expect(answer, 'sent');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/send');
      expect(
        request.contentType,
        '${Headers.multipartFormDataContentType}; boundary=${form.boundary}',
      );
      expect(
        request.body,
        allOf(
          startsWith('--${form.boundary}\r\n'),
          contains('name="subject"\r\n\r\nHallo\r\n'),
          contains('name="file"; filename="bijlage.txt"'),
          contains('\r\n\r\ninhoud\r\n'),
          endsWith('--${form.boundary}--\r\n'),
        ),
      );
    });

    test('postFormEncodedRaw POSTs the body form-urlencoded as given and '
        'returns the answer', () async {
      final server = _Smartschool(answer: 'ok');
      final client = await _clientOf(server);

      final answer = await client.postFormEncodedRaw(
        '/trash',
        'msgIDs[]=12&msgIDs[]=34',
      );

      expect(answer, 'ok');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/trash');
      expect(request.contentType, Headers.formUrlEncodedContentType);
      // Repeated names, which a Map of fields cannot hold, go out unchanged.
      expect(request.body, 'msgIDs[]=12&msgIDs[]=34');
    });

    test(
      'emitNotificationCounterUpdate returns true for valid module',
      () async {
        final client = await SmartschoolClient.create(
          DummyCredentials(),
          cacheDir: tempCacheDir(),
        );
        final result = client.emitNotificationCounterUpdate(
          moduleName: 'messages',
          counter: 2,
        );
        expect(result, isTrue);
      },
    );

    test(
      'emitNotificationCounterUpdate returns false for empty module',
      () async {
        final client = await SmartschoolClient.create(
          DummyCredentials(),
          cacheDir: tempCacheDir(),
        );
        final result = client.emitNotificationCounterUpdate(
          moduleName: '',
          counter: 1,
        );
        expect(result, isFalse);
      },
    );

    test('dispose closes the HTTP client: a later request fails without '
        'reaching Smartschool', () async {
      final server = _Smartschool();
      final client = await _clientOf(server);

      await client.dispose();

      expect(server.closes, [true], reason: 'closed with force by default');
      // What it fails with is not settled yet (#54).
      await expectLater(client.getRaw('/'), throwsA(anything));
      expect(server.requests, isEmpty);
    });

    test('dispose closes notificationCounterUpdates', () async {
      final client = await _clientOf(_Smartschool());
      var closed = false;
      client.notificationCounterUpdates.listen(
        null,
        onDone: () => closed = true,
      );

      await client.dispose();

      expect(closed, isTrue);
    });

    test('getRaw GETs the path with its query and returns the body as it '
        'came, without decoding it', () async {
      final server = _Smartschool(
        answer: '{"id": 1}',
        answerType: Headers.jsonContentType,
      );
      final client = await _clientOf(server);

      final body = await client.getRaw(
        '/messages',
        query: {'module': 'Messages', 'page': 2},
      );

      expect(body, '{"id": 1}');
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/messages');
      expect(request.query, {'module': 'Messages', 'page': '2'});
    });

    test('download throws a SmartschoolDownloadError with the status code '
        'when Smartschool answers an error (#50)', () async {
      final client = await SmartschoolClient.create(
        DummyCredentials(),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      final server = _NotFound();
      client.dio.httpClientAdapter = server;

      await expectLater(
        client.download('/notfound'),
        throwsA(
          isA<SmartschoolDownloadError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('/notfound')),
        ),
      );
      // One GET of the file, and no login: a 404 is not a sign of an
      // expired session.
      expect(server.requests, ['GET /notfound']);
    });
  });
}
