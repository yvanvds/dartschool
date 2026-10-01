// Tests for issue #54: what a SmartschoolClient does after dispose().
//
// A request on a disposed client failed with a SmartschoolConnectionError,
// "Unable to reach Smartschool": the closed Dio refuses a request with a
// connection error of its own, and since #21 the client reported every
// connection error as Smartschool being unreachable, so an app that shows
// "offline" or retries on a SmartschoolConnectionError did so for a
// use-after-dispose. And emitNotificationCounterUpdate threw a StateError
// (adding to the closed stream), where its doc promised `true` or `false`.
//
// Now every request method, ensureAuthenticated, platformId,
// authenticatedUser and getCurrentUser throw a StateError that says the
// client was disposed, before anything is sent; a request that was running
// when the client was disposed, and the stream of a download that was being
// read, fail with it too. emitNotificationCounterUpdate returns `false`, and
// dispose can be called again.
//
// Issue #73: that StateError could only be told apart from any other
// StateError (such as the "No element" of a `.first`) by its message. It is
// now a SmartschoolClientDisposedError, still a StateError, and the client
// tells whether it was disposed (isDisposed). The walk of the issue, which
// skips a broken folder and stops for a disposed client, is in
// intradesk_listing_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

/// Stands in for Smartschool: answers every request with a `200` and a
/// course list (the answer [SmartschoolClient.platformId] reads), and keeps
/// each request as `<method> <path>` and the `force` of each [close].
///
/// With [refuse], it answers with a `401` instead, as Smartschool answers a
/// request on a session it does not accept, so that the client logs in.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({this.refuse = false});

  final bool refuse;

  final requests = <String>[];
  final closes = <bool>[];

  /// Runs when a request comes in, before it is answered.
  void Function()? onRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    onRequest?.call();
    if (refuse) return ResponseBody.fromString('', HttpStatus.unauthorized);
    return ResponseBody.fromString(
      jsonEncode([
        {'platformId': 7},
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) => closes.add(force);
}

Future<SmartschoolClient> _clientOf(HttpClientAdapter server) async {
  final client = await SmartschoolClient.create(
    AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
    cacheDir: tempCacheDir(),
  );
  addTearDown(client.dispose);
  client.dio.httpClientAdapter = server;
  return client;
}

/// The error of a disposed client: a [SmartschoolClientDisposedError] (#73),
/// a [StateError] that says so, and not a [SmartschoolException] such as a
/// [SmartschoolConnectionError].
final _disposed = isA<SmartschoolClientDisposedError>().having(
  (e) => e.message,
  'message',
  startsWith('SmartschoolClient was disposed'),
);

/// Each public method of [SmartschoolClient] that talks to Smartschool, by
/// name.
final _calls = <String, Future<Object?> Function(SmartschoolClient client)>{
  'getJson': (client) => client.getJson('/json'),
  'postJson': (client) => client.postJson('/json', data: {'a': 1}),
  'postXml': (client) => client.postXml(
    url: '/xml',
    subsystem: 'postboxes',
    action: 'message list',
    params: const {'boxType': 'inbox'},
    xpath: './/messages/message',
  ),
  'getRaw': (client) => client.getRaw('/page'),
  'getResponse': (client) => client.getResponse('/page'),
  'postFormRaw': (client) => client.postFormRaw('/form', const {'a': 'b'}),
  'postFormResponse': (client) =>
      client.postFormResponse('/form', const {'a': 'b'}),
  'postMultipartRaw': (client) =>
      client.postMultipartRaw('/upload', FormData.fromMap({'a': 'b'})),
  'postMultipartResponse': (client) =>
      client.postMultipartResponse('/upload', FormData.fromMap({'a': 'b'})),
  'postFormEncodedRaw': (client) =>
      client.postFormEncodedRaw('/form', 'ids[]=1&ids[]=2'),
  'download': (client) => client.download('/file'),
  'downloadStream': (client) => client.downloadStream('/file'),
  'ensureAuthenticated': (client) => client.ensureAuthenticated(),
  'platformId': (client) => client.platformId,
  'authenticatedUser': (client) => client.authenticatedUser,
  'getCurrentUser': (client) => client.getCurrentUser(),
};

void main() {
  forbidRealNetwork();

  group('a disposed client', () {
    for (final MapEntry(key: name, value: call) in _calls.entries) {
      test('$name throws a SmartschoolClientDisposedError saying so, without '
          'sending anything', () async {
        final server = _Smartschool();
        final client = await _clientOf(server);

        await client.dispose();

        await expectLater(call(client), throwsA(_disposed));
        expect(server.requests, isEmpty);
      });
    }

    test('ensureAuthenticated and platformId throw it also when they '
        'validated the session before', () async {
      final server = _Smartschool();
      final client = await _clientOf(server);
      await client.ensureAuthenticated();
      expect(await client.platformId, 7);
      expect(server.requests, ['GET /course-list/api/v1/courses']);

      await client.dispose();

      await expectLater(client.ensureAuthenticated(), throwsA(_disposed));
      await expectLater(client.platformId, throwsA(_disposed));
      expect(server.requests, hasLength(1));
    });

    test(
      'a service call throws it, not a SmartschoolConnectionError',
      () async {
        final server = _Smartschool();
        final client = await _clientOf(server);

        await client.dispose();

        await expectLater(
          MessagesService(client).getHeaders(),
          throwsA(_disposed),
        );
        expect(server.requests, isEmpty);
      },
    );

    test('emitNotificationCounterUpdate returns false and emits '
        'nothing', () async {
      final client = await _clientOf(_Smartschool());
      final updates = <NotificationCounterUpdate>[];
      client.notificationCounterUpdates.listen(updates.add);

      await client.dispose();

      expect(
        client.emitNotificationCounterUpdate(
          moduleName: 'Messages',
          counter: 3,
        ),
        isFalse,
      );
      await pumpEventQueue();
      expect(updates, isEmpty);
    });

    test('can be disposed again: that closes nothing again', () async {
      final server = _Smartschool();
      final client = await _clientOf(server);

      final first = client.dispose();
      final second = client.dispose(force: false);
      await Future.wait([first, second]);
      await client.dispose();

      expect(server.closes, [true], reason: 'the first call closes, forced');
      await expectLater(client.getRaw('/'), throwsA(_disposed));
    });
  });

  group('isDisposed (#73)', () {
    test('is false until dispose is called, and true from that call on, '
        'before its future completes', () async {
      final client = await _clientOf(_Smartschool());
      expect(client.isDisposed, isFalse);
      await client.getRaw('/page');
      expect(client.isDisposed, isFalse, reason: 'a request changes nothing');

      final disposal = client.dispose();
      expect(client.isDisposed, isTrue);
      await disposal;
      expect(client.isDisposed, isTrue);
      await client.dispose();
      expect(client.isDisposed, isTrue);
    });

    test('tells a disposed client apart in a catch of every error', () async {
      final server = _Smartschool();
      final client = await _clientOf(server);
      server.onRequest = () => unawaited(client.dispose());

      // The request goes out, the client is disposed while it runs, and the
      // request after it is not sent.
      await client.getRaw('/first');
      Object? failure;
      try {
        await client.getRaw('/second');
      } catch (e) {
        failure = e;
      }

      expect(client.isDisposed, isTrue);
      expect(failure, _disposed);
      expect(server.requests, ['GET /first']);
    });
  });

  group('disposing a client', () {
    test('during a login that a request started makes the request fail with '
        'the SmartschoolClientDisposedError, not as Smartschool '
        'unreachable', () async {
      // Smartschool refuses the request, so the client logs in: the GET of
      // the login form is refused by the closed HTTP client with a
      // connection error, which is not Smartschool being unreachable.
      final server = _Smartschool(refuse: true);
      final client = await _clientOf(server);
      server.onRequest = () => unawaited(client.dispose());

      await expectLater(
        client.getRaw('/page'),
        throwsA(
          _disposed.having(
            (e) => e.message,
            'message',
            contains('GET https://$_host/login'),
          ),
        ),
      );
      expect(server.requests, ['GET /page']);
    });

    group('over a connection to a server on loopback', () {
      late HttpServer server;
      late SmartschoolClient client;
      late void Function(HttpRequest request) handle;
      late Completer<void> arrived;

      setUp(() async {
        arrived = Completer<void>();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          handle(request);
          arrived.complete();
        });
        client = await SmartschoolClient.create(
          AppCredentials(username: 'user', password: 'pass', mainUrl: _host),
          cacheDir: tempCacheDir(),
        );
        // Dio's own adapter, a real connection, to this server.
        client.dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
        addTearDown(() async {
          await client.dispose();
          await server.close(force: true);
        });
      });

      test('while a request runs makes it fail with the '
          'SmartschoolClientDisposedError, not as Smartschool '
          'unreachable', () async {
        // The server never answers: the request runs until the client is
        // disposed, which drops the connection.
        handle = (_) {};
        final page = client.getRaw('/page');
        await arrived.future;

        await client.dispose();

        await expectLater(
          page,
          throwsA(
            _disposed.having(
              (e) => e.message,
              'message',
              contains('GET http://127.0.0.1:${server.port}/page'),
            ),
          ),
        );
      });

      test('while a download is read ends its stream with the '
          'SmartschoolClientDisposedError, not as Smartschool '
          'unreachable', () async {
        // The server sends the first 64 KiB of the file and then holds the
        // connection open. (A few bytes would not do: they may not reach the
        // reader before the rest of the file.)
        handle = (request) {
          request.response
            ..contentLength = 1024 * 1024
            ..add(Uint8List(64 * 1024));
          unawaited(request.response.flush());
        };
        final download = await client.downloadStream('/file');
        final content = StreamIterator(download.stream);
        expect(await content.moveNext(), isTrue);

        await client.dispose();

        await expectLater(() async {
          while (await content.moveNext()) {}
        }(), throwsA(_disposed));
      });
    });
  });
}
