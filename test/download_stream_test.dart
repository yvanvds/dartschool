// Tests for issue #41: `SmartschoolClient.download` (and so
// `IntradeskService.downloadFile` and `MessageAttachment.download`) read the
// whole answer into memory and returned it as one `Uint8List`. A caller could
// not refuse a file above a size, stop a download partway, or read it as a
// stream, and did not see the headers (`Content-Length`, the file name in
// `Content-Disposition`). On a real school Intradesk files go up to hundreds
// of MB (427 MB seen); smartschool-mcp only wants files up to 25 MB.
//
// Now:
// - `download(path, {maxBytes})` (and `downloadFile`, `MessageAttachment
//   .download`) fail with a `SmartschoolDownloadTooLargeError` as soon as the
//   file turns out larger than `maxBytes`: at once when `Content-Length`
//   announces more, else once more bytes than that came in;
// - `downloadStream(path, {maxBytes})` (and `downloadFileStream`,
//   `MessageAttachment.downloadStream`) hand over a `SmartschoolDownload` as
//   soon as the headers are in: `contentLength`, `fileName`, `contentType` and
//   the content as a stream.
//
// Dio (5.11.1) subscribes to the body of a response as soon as it comes in
// and keeps reading it when the reader of a `ResponseType.stream` body
// cancels its subscription; only cancelling the request (its `CancelToken`)
// closes the connection. The fakes below tell whether the transfer was
// stopped (the fake's body lost its listener before its end), and the
// loopback tests whether the server could send its whole body.
//
// A download on a session that Smartschool refuses goes through the auth
// interceptor as every request does: the refused answer is a page of the
// login chain, which the client reads (and fills in, for
// `/account-verification`) instead of handing it over as the file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:flutter_smartschool/src/download.dart'
    show contentDispositionFileName;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

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

const _verificationPage = '''
<html><body>
<form name="account_verification_form" method="post">
<input type="date" name="account_verification_form[_security_question_answer]" />
<input type="hidden" name="account_verification_form[_token]" value="csrf" />
<button type="submit">Bevestigen</button>
</form>
</body></html>
''';

/// How the fake Smartschool refuses a download on a session it does not
/// accept.
enum _Refusal {
  /// A page request redirected to `/login`, as the live platform does.
  redirectToLogin,

  /// A bare `401`, as for an XHR/form POST (#8).
  unauthorized,

  /// A session that got past the password but still has to answer the
  /// account verification: redirected to `/account-verification`.
  accountVerification,
}

/// A response body that the test feeds chunk by chunk, and that tells
/// whether the client stopped the transfer: whether its reader stopped
/// listening before the end.
class _Body {
  late final StreamController<Uint8List> _controller = StreamController(
    onPause: () => paused = true,
    onResume: () => paused = false,
    onCancel: () => stoppedEarly = !_closed,
  );
  bool _closed = false;

  /// Whether the transfer was stopped before the body ended.
  bool stoppedEarly = false;

  /// Whether the reader paused the body.
  bool paused = false;

  Stream<Uint8List> get stream => _controller.stream;

  void add(List<int> bytes) => _controller.add(Uint8List.fromList(bytes));

  void addError(Object error) => _controller.addError(error);

  Future<void> close() {
    _closed = true;
    return _controller.close();
  }
}

/// A 200 answer with [body] and [headers].
ResponseBody _answer(
  Stream<Uint8List> body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody(body, 200, headers: {...headers});

ResponseBody _bytes(List<int> bytes, {int? contentLength}) => _answer(
  Stream.value(Uint8List.fromList(bytes)),
  headers: {
    if (contentLength != null) 'content-length': ['$contentLength'],
  },
);

ResponseBody _html(String html, {int status = 200}) => ResponseBody.fromString(
  html,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html'],
  },
);

/// Stands in for Smartschool: answers `file()` to any download on a session
/// it accepts, refuses the session the way of [refusal] until the client
/// logs in, and serves the login chain.
class _Smartschool implements HttpClientAdapter {
  _Smartschool(
    this.file, {
    this.loggedIn = true,
    this.refusal = _Refusal.redirectToLogin,
    this.acceptsLogin = true,
  });

  /// The answer to a download on an accepted session.
  ResponseBody Function() file;

  /// Whether Smartschool accepts the session.
  bool loggedIn;

  final _Refusal refusal;

  /// Whether a login gets the session accepted.
  final bool acceptsLogin;

  /// Every request the client made, as `METHOD path` (with the query for a
  /// message attachment, which is addressed by query on `/`).
  final List<String> log = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final attachment =
        uri.path == '/' && uri.queryParameters['file'] == 'download';
    log.add(
      '${options.method} ${uri.path}${attachment ? '?${uri.query}' : ''}',
    );

    switch ((options.method, uri.path)) {
      case ('GET', '/login'):
        return _html(_loginPage);
      case ('POST', '/login' || '/account-verification'):
        loggedIn = acceptsLogin;
        return ResponseBody.fromString(
          'Redirecting to /',
          302,
          headers: {
            'location': ['/'],
          },
        );
      case ('GET', '/course-list/api/v1/courses'):
        return ResponseBody.fromString(
          '[{"platformId":49}]',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      case ('GET', '/') when !attachment:
        return _html('<html><body>home</body></html>');
    }

    if (!loggedIn) {
      return switch (refusal) {
        _Refusal.redirectToLogin =>
          _html(_loginPage)
            ..redirects = [
              RedirectRecord(302, 'GET', Uri.parse('https://$_host/login')),
            ],
        _Refusal.unauthorized => ResponseBody.fromString('', 401),
        _Refusal.accountVerification =>
          _html(_verificationPage)
            ..redirects = [
              RedirectRecord(
                302,
                'GET',
                Uri.parse('https://$_host/account-verification'),
              ),
            ],
      };
    }
    return file();
  }

  @override
  void close({bool force = false}) {}
}

/// A [SmartschoolConnectionError] whose `cause` is a [DioException] of
/// [type].
TypeMatcher<SmartschoolConnectionError> _connectionError(
  DioExceptionType type,
) => isA<SmartschoolConnectionError>()
    .having(
      (e) => e.cause,
      'cause',
      isA<DioException>().having((d) => d.type, 'type', type),
    )
    .having(
      (e) => e.message,
      'message',
      startsWith('Unable to reach Smartschool at $_host: '),
    );

TypeMatcher<SmartschoolDownloadTooLargeError> _tooLarge({
  required int maxBytes,
  int? contentLength,
}) => isA<SmartschoolDownloadTooLargeError>()
    .having((e) => e.maxBytes, 'maxBytes', maxBytes)
    .having((e) => e.contentLength, 'contentLength', contentLength);

Future<List<int>> _read(SmartschoolDownload download) async => [
  for (final chunk in await download.stream.toList()) ...chunk,
];

/// A server on loopback that answers every request with a body of 64 MiB,
/// far more than the socket buffers hold, in chunks of 64 KiB; with a
/// `Content-Length` when [announceLength], else chunked.
///
/// It writes the HTTP answer on a plain socket, so that it sees the client
/// close the connection while it is still writing (an `HttpServer` does not
/// tell), and stops writing then.
class _FileServer {
  _FileServer._(this._server, this.announceLength) {
    _server.listen(_serve);
  }

  static Future<_FileServer> start({required bool announceLength}) async =>
      _FileServer._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        announceLength,
      );

  static const _chunkSize = 64 * 1024;
  static const _chunks = 1024;

  final ServerSocket _server;
  final bool announceLength;
  final List<Socket> _sockets = [];
  final Completer<int?> _closedAfter = Completer();
  int _sent = 0;

  int get port => _server.port;

  /// The size of the body.
  int get length => _chunks * _chunkSize;

  /// The bytes of the body written when the client closed the connection,
  /// or `null` when the whole body was written first.
  Future<int?> get closedAfter =>
      _closedAfter.future.timeout(const Duration(seconds: 20));

  void _serve(Socket socket) {
    _sockets.add(socket);
    socket.done.ignore();
    var answering = false;
    socket.listen(
      (_) {
        // The first bytes of the request (a GET without a body).
        if (answering) return;
        answering = true;
        _answer(socket);
      },
      onDone: _clientClosed,
      onError: (Object _) => _clientClosed(),
    );
  }

  void _clientClosed() {
    if (!_closedAfter.isCompleted) _closedAfter.complete(_sent);
  }

  Future<void> _answer(Socket socket) async {
    socket.add(
      ascii.encode(
        'HTTP/1.1 200 OK\r\n'
        '${announceLength ? 'content-length: $length' : 'transfer-encoding: chunked'}'
        '\r\n\r\n',
      ),
    );
    final chunk = Uint8List(_chunkSize);
    try {
      for (var i = 0; i < _chunks && !_closedAfter.isCompleted; i++) {
        if (announceLength) {
          socket.add(chunk);
        } else {
          socket
            ..add(ascii.encode('${_chunkSize.toRadixString(16)}\r\n'))
            ..add(chunk)
            ..add(ascii.encode('\r\n'));
        }
        _sent += _chunkSize;
        await socket.flush();
      }
      if (_closedAfter.isCompleted) return;
      if (!announceLength) socket.add(ascii.encode('0\r\n\r\n'));
      await socket.flush();
      if (!_closedAfter.isCompleted) _closedAfter.complete(null);
    } on Object {
      _clientClosed();
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

void main() {
  forbidRealNetwork();

  group('with a fake Smartschool', () {
    late SmartschoolClient client;
    late _Smartschool server;

    Future<void> start(
      ResponseBody Function() file, {
      bool loggedIn = true,
      _Refusal refusal = _Refusal.redirectToLogin,
      bool acceptsLogin = true,
      String? mfa,
    }) async {
      client = await SmartschoolClient.create(
        AppCredentials(
          username: 'user',
          password: 'pass',
          mainUrl: _host,
          mfa: mfa,
        ),
        cacheDir: tempCacheDir(),
      );
      addTearDown(client.dispose);
      server = _Smartschool(
        file,
        loggedIn: loggedIn,
        refusal: refusal,
        acceptsLogin: acceptsLogin,
      );
      client.dio.httpClientAdapter = server;
    }

    group('downloadStream', () {
      test('hands the download over once the headers are in, and the '
          'content as it comes in', () async {
        final body = _Body();
        await start(
          () => _answer(
            body.stream,
            headers: {
              'content-length': ['6'],
              'content-type': ['application/x-www-form-urlencoded'],
              'content-disposition': ['attachment; filename="Verslag 3.docx"'],
            },
          ),
        );

        // Before the change: no downloadStream; download waited for the
        // whole body.
        final download = await client.downloadStream('/file');

        expect(download.contentLength, 6);
        expect(download.fileName, 'Verslag 3.docx');
        expect(download.contentType, 'application/x-www-form-urlencoded');

        final chunks = <List<int>>[];
        final done = download.stream.listen(chunks.add).asFuture<void>();
        body.add([1, 2, 3]);
        await pumpEventQueue();
        expect(chunks, [
          [1, 2, 3],
        ], reason: 'the first chunk arrives before the body ends');

        body.add([4, 5, 6]);
        await body.close();
        await done;
        expect(chunks, [
          [1, 2, 3],
          [4, 5, 6],
        ]);
        expect(body.stoppedEarly, isFalse);
      });

      test('pausing the stream pauses the transfer', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final download = await client.downloadStream('/file');
        final subscription = download.stream.listen((_) {});
        await pumpEventQueue();
        expect(body.paused, isFalse);

        subscription.pause();
        await pumpEventQueue();
        expect(body.paused, isTrue);

        subscription.resume();
        await pumpEventQueue();
        expect(body.paused, isFalse);
        await subscription.cancel();
      });

      test('cancelling the subscription before the end stops the '
          'transfer', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final download = await client.downloadStream('/file');
        final subscription = download.stream.listen((_) {});
        body.add([1, 2, 3]);
        await pumpEventQueue();
        await subscription.cancel();
        await pumpEventQueue();

        // Dio alone would keep reading the body to its end.
        expect(body.stoppedEarly, isTrue);
      });

      test('cancel() stops the transfer without reading, and the stream '
          'then ends with a StateError', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final download = await client.downloadStream('/file');
        await download.cancel();
        await pumpEventQueue();

        expect(body.stoppedEarly, isTrue);
        await expectLater(
          download.stream.toList(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('/file was cancelled'),
            ),
          ),
        );
      });

      test('cancel() while the stream is read ends it with a '
          'StateError', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final download = await client.downloadStream('/file');
        final read = expectLater(
          download.stream.toList(),
          throwsA(isA<StateError>()),
        );
        body.add([1]);
        await pumpEventQueue();
        await download.cancel();

        await read;
        expect(body.stoppedEarly, isTrue);
      });
    });

    group('maxBytes', () {
      test('a Content-Length above maxBytes fails before the content is '
          'read, and stops the transfer', () async {
        final body = _Body();
        await start(
          () => _answer(
            body.stream,
            headers: {
              'content-length': ['1000'],
            },
          ),
        );

        await expectLater(
          client.downloadStream('/file', maxBytes: 999),
          throwsA(
            _tooLarge(maxBytes: 999, contentLength: 1000).having(
              (e) => e.message,
              'message',
              allOf(contains('/file'), contains('announced 1000 bytes')),
            ),
          ),
        );
        await pumpEventQueue();
        expect(body.stoppedEarly, isTrue);
      });

      test('download throws it for a Content-Length above maxBytes', () async {
        final body = _Body();
        await start(
          () => _answer(
            body.stream,
            headers: {
              'content-length': ['1000'],
            },
          ),
        );

        await expectLater(
          client.download('/file', maxBytes: 10),
          throwsA(_tooLarge(maxBytes: 10, contentLength: 1000)),
        );
        await pumpEventQueue();
        expect(body.stoppedEarly, isTrue);
      });

      test('without a Content-Length the bytes are counted: the stream ends '
          'with the error once more than maxBytes came in, and the transfer '
          'stops', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final download = await client.downloadStream('/file', maxBytes: 5);
        expect(download.contentLength, isNull);

        final chunks = <List<int>>[];
        final errors = <Object>[];
        final done = Completer<void>();
        download.stream.listen(
          chunks.add,
          onError: errors.add,
          onDone: done.complete,
        );
        body
          ..add([1, 2, 3])
          ..add([4, 5]); // 5 bytes: still allowed
        await pumpEventQueue();
        expect(errors, isEmpty);

        body.add([6]);
        await done.future;

        expect(chunks, [
          [1, 2, 3],
          [4, 5],
        ], reason: 'at most maxBytes bytes are handed over');
        expect(errors, [_tooLarge(maxBytes: 5)]);
        expect(body.stoppedEarly, isTrue);
      });

      test('download counts the bytes too, also past a smaller '
          'Content-Length', () async {
        await start(
          () => _answer(
            Stream.fromIterable([
              Uint8List.fromList([1, 2, 3, 4]),
              Uint8List.fromList([5, 6, 7, 8]),
            ]),
            headers: {
              'content-length': ['4'],
            },
          ),
        );

        await expectLater(
          client.download('/file', maxBytes: 6),
          throwsA(_tooLarge(maxBytes: 6, contentLength: 4)),
        );
      });

      test('a file of exactly maxBytes, or smaller, gets through', () async {
        final bytes = List<int>.generate(10, (i) => i);
        await start(() => _bytes(bytes, contentLength: 10));

        expect(await client.download('/file', maxBytes: 10), bytes);
        expect(await client.download('/file', maxBytes: 100), bytes);
        expect(await client.download('/file'), bytes, reason: 'no limit');
        expect(await _read(await client.downloadStream('/file')), bytes);
      });

      test('maxBytes 0 lets an empty file through', () async {
        await start(() => _bytes([], contentLength: 0));

        expect(await client.download('/file', maxBytes: 0), isEmpty);
      });

      test('a negative maxBytes is an ArgumentError, before any '
          'request', () async {
        await start(() => _bytes([1]));

        expect(
          () => client.downloadStream('/file', maxBytes: -1),
          throwsArgumentError,
        );
        expect(
          () => client.download('/file', maxBytes: -1),
          throwsArgumentError,
        );
        expect(server.log, isEmpty);
      });
    });

    group('errors', () {
      test('another status than 200 is a SmartschoolDownloadError, and the '
          'error page is not read', () async {
        final body = _Body();
        await start(() => ResponseBody(body.stream, 404));

        await expectLater(
          client.downloadStream('/file'),
          throwsA(
            isA<SmartschoolDownloadError>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        await pumpEventQueue();
        expect(body.stoppedEarly, isTrue);
      });

      test('a connection that fails halfway ends the stream with a '
          'SmartschoolConnectionError', () async {
        final body = _Body();
        await start(() => _answer(body.stream));
        const closed = HttpException('Connection closed while receiving data');

        final download = await client.downloadStream('/file');
        final read = download.stream.toList();
        body
          ..add([1, 2])
          ..addError(closed);

        await expectLater(
          read,
          throwsA(
            _connectionError(DioExceptionType.unknown).having(
              (e) => (e.cause! as DioException).error,
              'cause.error',
              same(closed),
            ),
          ),
        );
      });

      test('download throws it for a connection that fails halfway', () async {
        final body = _Body();
        await start(() => _answer(body.stream));

        final bytes = client.download('/file');
        await pumpEventQueue();
        body
          ..add([1, 2])
          ..addError(const SocketException('Connection reset by peer'));

        await expectLater(
          bytes,
          throwsA(_connectionError(DioExceptionType.unknown)),
        );
      });

      test('a receive timeout halfway ends the stream with a '
          'SmartschoolConnectionError', () async {
        final body = _Body();
        await start(() => _answer(body.stream));
        client.dio.options.receiveTimeout = const Duration(milliseconds: 50);

        final download = await client.downloadStream('/file');

        await expectLater(
          download.stream.toList(),
          throwsA(_connectionError(DioExceptionType.receiveTimeout)),
        );
      });
    });

    group('a session that Smartschool refuses', () {
      final file = utf8.encode('the file');

      for (final refusal in [_Refusal.redirectToLogin, _Refusal.unauthorized]) {
        test('(${refusal.name}): the client logs in again and streams the '
            'retry, not the login page', () async {
          await start(
            () => _bytes(file, contentLength: file.length),
            loggedIn: false,
            refusal: refusal,
          );

          final download = await client.downloadStream('/file');
          final bytes = await _read(download);

          expect(utf8.decode(bytes), 'the file');
          expect(download.contentLength, file.length);
          expect(server.log, [
            'GET /file',
            'GET /login',
            'POST /login',
            'GET /',
            'GET /file',
          ]);
        });
      }

      test('on the account verification: the client fills in the page it '
          'was answered with, and streams the retry', () async {
        await start(
          () => _bytes(file),
          loggedIn: false,
          refusal: _Refusal.accountVerification,
          mfa: '2000-01-01',
        );

        // Before the fix: SmartschoolParsingError (no account verification
        // form in the unread stream).
        final bytes = await client.download('/file');

        expect(utf8.decode(bytes), 'the file');
        expect(server.log, [
          'GET /file',
          'POST /account-verification',
          'GET /',
          'GET /file',
        ]);
      });

      test('a retry that is refused too is a SmartschoolSessionExpiredError, '
          'and nothing is handed over', () async {
        await start(() => _bytes(file), loggedIn: false, acceptsLogin: false);

        await expectLater(
          client.downloadStream('/file'),
          throwsA(isA<SmartschoolSessionExpiredError>()),
        );
        expect(server.log, [
          'GET /file',
          'GET /login',
          'POST /login',
          'GET /',
          'GET /file',
        ]);
      });
    });

    group('the services', () {
      test('IntradeskService.downloadFileStream streams the file from its '
          'download URL', () async {
        await start(
          () => _answer(
            Stream.value(Uint8List.fromList([7, 8, 9])),
            headers: {
              'content-length': ['3'],
              'content-disposition': [
                "attachment; filename*=UTF-8''R%C3%A9sultaten.xlsx",
              ],
            },
          ),
        );

        final download = await IntradeskService(
          client,
        ).downloadFileStream('abc', maxBytes: 3);

        expect(download.fileName, 'Résultaten.xlsx');
        expect(await _read(download), [7, 8, 9]);
        expect(server.log, [
          'GET /course-list/api/v1/courses',
          'GET /intradesk/api/v1/49/files/abc/download',
        ]);
      });

      test('IntradeskService.downloadFile takes maxBytes', () async {
        await start(() => _bytes([1, 2, 3, 4], contentLength: 4));
        final intradesk = IntradeskService(client);

        expect(await intradesk.downloadFile('abc', maxBytes: 4), [1, 2, 3, 4]);
        await expectLater(
          intradesk.downloadFile('abc', maxBytes: 3),
          throwsA(_tooLarge(maxBytes: 3, contentLength: 4)),
        );
        await expectLater(
          intradesk.downloadFileStream(''),
          throwsArgumentError,
        );
      });

      test('MessageAttachment.download and downloadStream take '
          'maxBytes', () async {
        await start(() => _bytes([1, 2, 3], contentLength: 3));
        const attachment = MessageAttachment(
          fileId: 7,
          name: 'bijlage.pdf',
          mime: 'application/pdf',
          size: '3 B',
          icon: '',
          wopiAllowed: false,
          order: 0,
        );

        expect(await attachment.download(client, maxBytes: 3), [1, 2, 3]);
        expect(await _read(await attachment.downloadStream(client)), [1, 2, 3]);
        await expectLater(
          attachment.download(client, maxBytes: 2),
          throwsA(_tooLarge(maxBytes: 2, contentLength: 3)),
        );
        expect(
          server.log,
          everyElement('GET /?module=Messages&file=download&fileID=7&target=0'),
        );
      });
    });
  });

  group('over a connection to a server on loopback', () {
    late HttpServer server;
    late SmartschoolClient client;
    late Future<void> Function(HttpRequest request) handle;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => handle(request));
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

    /// Points the client at a [_FileServer] instead of the HTTP server.
    Future<_FileServer> fileServer({required bool announceLength}) async {
      final files = await _FileServer.start(announceLength: announceLength);
      addTearDown(files.close);
      client.dio.options.baseUrl = 'http://127.0.0.1:${files.port}';
      return files;
    }

    test('maxBytes stops a body without a Content-Length once more than '
        'maxBytes came in, and closes the connection', () async {
      final files = await fileServer(announceLength: false);

      await expectLater(
        client.download('/file', maxBytes: 256 * 1024),
        throwsA(_tooLarge(maxBytes: 256 * 1024)),
      );
      expect(
        await files.closedAfter,
        lessThan(files.length ~/ 2),
        reason: 'the client closed the connection long before the end',
      );
    });

    test('a Content-Length above maxBytes fails before the content is read, '
        'and closes the connection', () async {
      final files = await fileServer(announceLength: true);

      await expectLater(
        client.downloadStream('/file', maxBytes: 1024 * 1024),
        throwsA(_tooLarge(maxBytes: 1024 * 1024, contentLength: files.length)),
      );
      expect(await files.closedAfter, lessThan(files.length ~/ 2));
    });

    test('a reader that stops after the first chunk closes the '
        'connection', () async {
      final files = await fileServer(announceLength: true);

      final download = await client.downloadStream('/file');
      // `first` cancels the subscription after the first chunk.
      final first = await download.stream.first;

      expect(first, isNotEmpty);
      // Dio alone would read the whole 64 MiB off the connection.
      expect(await files.closedAfter, lessThan(files.length ~/ 2));
    });

    test('streams a file to disk with its headers', () async {
      final content = Uint8List.fromList(
        List<int>.generate(300 * 1024, (i) => i % 251),
      );
      handle = (request) async {
        final response = request.response
          ..contentLength = content.length
          ..headers.set('content-type', 'application/x-www-form-urlencoded')
          ..headers.set(
            'content-disposition',
            'attachment; filename="Verslag.docx"; '
                "filename*=UTF-8''Verslag%20%C3%A9%C3%A9n.docx",
          );
        for (var i = 0; i < content.length; i += 64 * 1024) {
          response.add(
            content.sublist(i, (i + 64 * 1024).clamp(0, content.length)),
          );
          await response.flush();
        }
        await response.close();
      };

      final download = await client.downloadStream(
        '/file',
        maxBytes: content.length,
      );
      expect(download.contentLength, content.length);
      expect(download.fileName, 'Verslag één.docx');
      expect(download.contentType, 'application/x-www-form-urlencoded');

      final dir = Directory.systemTemp.createTempSync('smartschool_download_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final out = File(p.join(dir.path, 'out.docx'));
      await download.stream.pipe(out.openWrite());

      expect(await out.readAsBytes(), content);
    });

    test('a download redirected to the login page logs in again and gets '
        'the file, not the login page', () async {
      final file = utf8.encode('the file');
      var loggedIn = false;
      final log = <String>[];
      handle = (request) async {
        await request.drain<void>();
        log.add('${request.method} ${request.uri.path}');
        final response = request.response;
        switch ((request.method, request.uri.path)) {
          case ('GET', '/file') when !loggedIn:
            response
              ..statusCode = HttpStatus.found
              ..headers.set('location', '/login');
          case ('GET', '/file'):
            response.add(file);
          case ('GET', '/login'):
            response
              ..headers.contentType = ContentType.html
              ..write(_loginPage);
          case ('POST', '/login'):
            loggedIn = true;
            response
              ..statusCode = HttpStatus.found
              ..headers.set('location', '/');
          default:
            response
              ..headers.contentType = ContentType.html
              ..write('<html><body>home</body></html>');
        }
        await response.close();
      };

      final bytes = await client.download('/file');

      expect(utf8.decode(bytes), 'the file');
      expect(log, [
        'GET /file',
        'GET /login', // the redirect, followed by the HTTP client
        'GET /login', // the login loads its own login form (#45)
        'POST /login',
        'GET /',
        'GET /file',
      ]);
    });
  });

  group('SmartschoolDownload', () {
    SmartschoolDownload withHeaders(Map<String, List<String>> headers) =>
        SmartschoolDownload(
          stream: const Stream.empty(),
          headers: Headers.fromMap(headers),
        );

    test('contentLength is the Content-Length, or null when there is none '
        'or it is not a size', () {
      expect(
        withHeaders({
          'content-length': ['1234'],
        }).contentLength,
        1234,
      );
      expect(withHeaders({}).contentLength, isNull);
      expect(
        withHeaders({
          'content-length': ['abc'],
        }).contentLength,
        isNull,
      );
      expect(
        withHeaders({
          'content-length': ['-1'],
        }).contentLength,
        isNull,
      );
    });

    test('contentLength is null for encoded content, whose size it does '
        'not give', () {
      expect(
        withHeaders({
          'content-length': ['100'],
          'content-encoding': ['gzip'],
        }).contentLength,
        isNull,
      );
      expect(
        withHeaders({
          'content-length': ['100'],
          'content-encoding': ['identity'],
        }).contentLength,
        100,
      );
    });

    test('fileName and contentType come from the headers, or are null', () {
      final download = withHeaders({
        'Content-Type': ['application/pdf'],
        'Content-Disposition': ['attachment; filename="a.pdf"'],
      });
      expect(download.contentType, 'application/pdf');
      expect(download.fileName, 'a.pdf');
      expect(withHeaders({}).contentType, isNull);
      expect(withHeaders({}).fileName, isNull);
    });

    test('cancel() without an onCancel does nothing', () async {
      await withHeaders({}).cancel();
    });
  });

  group('contentDispositionFileName', () {
    final cases = <String, String?>{
      'attachment; filename="Verslag 3.docx"': 'Verslag 3.docx',
      'attachment; filename=plain.txt': 'plain.txt',
      'attachment;filename="a\\"b.txt"': 'a"b.txt',
      'attachment; filename="semi;colon.txt"': 'semi;colon.txt',
      'attachment; filename="fallback.txt"; '
              "filename*=UTF-8''na%C3%AFve%20file.txt":
          'naïve file.txt',
      "attachment; filename*=utf-8''a+b.txt": 'a+b.txt',
      "attachment; filename*=iso-8859-1'nl'caf%E9.txt": 'café.txt',
      // A charset it cannot read, or a malformed value: the plain name.
      "attachment; filename*=UTF-16''x.txt; filename=\"x.txt\"": 'x.txt',
      "attachment; filename*=UTF-8''bad%ZZ.txt; filename=\"ok.txt\"": 'ok.txt',
      "attachment; filename*=UTF-8'bad.txt; filename=\"ok.txt\"": 'ok.txt',
      'inline; filename=""': null,
      'attachment': null,
    };
    for (final MapEntry(key: header, value: name) in cases.entries) {
      test(header, () {
        expect(contentDispositionFileName(header), name);
      });
    }

    test('no header', () {
      expect(contentDispositionFileName(null), isNull);
    });
  });
}
