import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:otp/otp.dart';
import 'package:path/path.dart' as p;

import 'cache_dir.dart';
import 'credentials.dart';
import 'download.dart';
import 'exceptions.dart';
import 'models/notification_models.dart';
import 'models/user_models.dart';
import 'xml_answer.dart';
import 'xml_interface.dart';

export 'download.dart' show SmartschoolDownload;

const String kXRequestedWith = 'X-Requested-With';
const String kAccountVerificationPath = '/account-verification';

/// The main entry point for the Smartschool Dart library.
///
/// Wraps a [Dio] HTTP client configured with:
/// - Cookie persistence ([PersistCookieJar] + [CookieManager]).
/// - Transparent authentication via [_SmartschoolAuthInterceptor].
///
/// Unlike the Python version which *inherits* from `requests.Session`, this
/// class uses composition — Dio is held as a private field.  Services receive
/// a [SmartschoolClient] by constructor injection rather than through a mixin.
///
/// Usage:
/// ```dart
/// final client = await SmartschoolClient.create(
///   AppCredentials(
///     username: 'john.doe',
///     password: 's3cr3t',
///     mainUrl: 'school.smartschool.be',
///   ),
/// );
/// final messages = MessagesService(client);
/// final headers = await messages.getHeaders();
/// ```
class SmartschoolClient {
  final Credentials credentials;

  /// The folder this client keeps its per-user data in, such as the saved
  /// session cookies (in `.cookies`), which let a new client for the same user
  /// carry on in that session (#30).
  ///
  /// It is the `cacheDir` given to [create], exactly as given, or
  /// [defaultCacheDir] for the username of [credentials] when none was given.
  /// [create] makes the folder when it does not exist yet.
  ///
  /// An app can keep its own per-user data here too, so that it is found and
  /// cleaned up together with the library's: put it in a subfolder of its own
  /// and leave the library's files alone (call [clearCookies] to delete the
  /// session).
  final String cacheDir;

  final Dio _dio;
  final StreamController<NotificationCounterUpdate>
  _notificationCounterController =
      StreamController<NotificationCounterUpdate>.broadcast();
  // Kept so callers can clear cookies on logout via [clearCookies].
  final PersistCookieJar _cookieJar; // ignore: unused_field

  // Cached after first successful login (parsed from account-verification HTML)
  Map<String, dynamic>? _authenticatedUser;

  // Cached platform ID (from /course-list/api/v1/courses)
  int? _platformId;

  // Logs in again when Smartschool refuses the session; set by [create].
  late final _SmartschoolAuthInterceptor _auth;

  // What the first call of [dispose] returned; the client is disposed once it
  // is set (#54).
  Future<void>? _disposal;

  /// The default `loginCooldown` of [create]: how long a client that stopped
  /// logging in on its own waits before it tries one login again.
  static const Duration defaultLoginCooldown = Duration(minutes: 5);

  SmartschoolClient._({
    required this.credentials,
    required this.cacheDir,
    required Dio dio,
    required PersistCookieJar cookieJar,
  }) : _dio = dio,
       _cookieJar = cookieJar;

  /// The folder that [create] keeps the per-user data of [username] in when
  /// it is given no `cacheDir` (#30).
  ///
  /// That is `.cache/smartschool/<username>` in the user's home folder: the
  /// `HOME` environment variable, or `USERPROFILE` when `HOME` is not set (as
  /// on Windows, where it is typically `C:\Users\<name>`), or the current
  /// directory when neither is set (the path is then relative). Call this
  /// rather than building the path yourself, so it keeps matching [create]
  /// if the library's default ever changes.
  ///
  /// It only works out the path: it does not create the folder, and does not
  /// tell whether it exists. Use it to find a user's folder without a client,
  /// for example to clean it up; a client reports the folder it actually
  /// uses, default or given, as [cacheDir].
  static String defaultCacheDir(String username) =>
      defaultCacheDirFor(username, Platform.environment);

  /// Exposes the underlying [Dio] instance for low-level / dev-tool use.
  ///
  /// Prefer the typed methods ([getRaw], [postFormRaw], [getJson], etc.) in
  /// production code. This getter is intended for [DevInspector] and similar
  /// reverse-engineering helpers.
  ///
  /// A request made on it directly still gets a login failure wrapped in a
  /// [DioException] (as its `error`), and a network failure as the plain
  /// [DioException]; the typed methods throw the login failure as itself and
  /// the network failure as a [SmartschoolConnectionError].
  ///
  /// Close the client with [dispose], not by closing this [Dio]: only then
  /// does the client report a request as made on a disposed client, rather
  /// than as Smartschool being unreachable (#54).
  Dio get dio => _dio;

  /// Stream of normalized module counter updates.
  ///
  /// This is intentionally transport-agnostic: a websocket listener, polling
  /// loop, or test harness can publish updates through
  /// [emitNotificationCounterUpdate].
  Stream<NotificationCounterUpdate> get notificationCounterUpdates =>
      _notificationCounterController.stream;

  /// Creates and configures a [SmartschoolClient].
  ///
  /// Call this factory instead of the private constructor.
  ///
  /// [cacheDir] is the folder the client keeps its per-user data in, such as
  /// the saved session cookies; it defaults to [defaultCacheDir] for the
  /// username of [credentials], and is made when it does not exist yet. The
  /// client reports it as [SmartschoolClient.cacheDir].
  ///
  /// When Smartschool refuses the session for a request, the client logs in
  /// again and retries it. Requests share that login: one that Smartschool
  /// refuses while a login runs waits for it and is then retried, so
  /// concurrent requests on an expired session log in once (#36). After
  /// three logins in a row that did not get the
  /// session accepted, it stops logging in on its own, and tries one login
  /// again once [loginCooldown] has passed since the last one (see
  /// [resetLoginAttempts]). [loginCooldown] defaults to
  /// [defaultLoginCooldown] (5 minutes) and must not be negative.
  ///
  /// A request that is not retried after logging in again
  /// (`retryAfterLogin: false`, see [postMultipartResponse]) does not log in
  /// when Smartschool refuses its session, but the client remembers that the
  /// session was refused: the next request logs in before it is sent, or
  /// waits for the login that runs (#134). The same holds after a login that
  /// failed. So a write that failed for its session can be tried again: it
  /// goes out in a new session, once.
  ///
  /// [clock] tells the time for that cooldown; it defaults to [DateTime.now].
  /// A test can pass a fake clock and move it forward instead of waiting.
  static Future<SmartschoolClient> create(
    Credentials credentials, {
    String? cacheDir,
    Duration loginCooldown = defaultLoginCooldown,
    DateTime Function() clock = DateTime.now,
  }) async {
    credentials.validate();
    if (loginCooldown.isNegative) {
      throw ArgumentError.value(
        loginCooldown,
        'loginCooldown',
        'must not be negative',
      );
    }

    final cachePath = cacheDir ?? defaultCacheDir(credentials.username);
    await Directory(cachePath).create(recursive: true);

    final cookieJar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(p.join(cachePath, '.cookies')),
    );

    final baseUrl = 'https://${credentials.mainUrl}';

    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        followRedirects: true,
        maxRedirects: 10,
        headers: {'User-Agent': 'unofficial Smartschool API interface'},
        // Treat all status codes as success so we can inspect redirects;
        // error handling is done in getJson / the auth interceptor.
        validateStatus: (_) => true,
      ),
    );

    final client = SmartschoolClient._(
      credentials: credentials,
      cacheDir: cachePath,
      dio: dio,
      cookieJar: cookieJar,
    );

    client._auth = _SmartschoolAuthInterceptor(
      client,
      loginCooldown: loginCooldown,
      clock: clock,
    );

    // A request that goes out once Smartschool refused the session logs in
    // first (#134): before the cookie manager, so that it then carries the
    // cookies of the new session.
    //
    // Cookie manager must be added before auth interceptor so cookies are
    // available on each retry request. It keeps the answers that Smartschool
    // refused out of the jar (#45), and stamps each request with the session
    // its cookies were loaded in (#38).
    dio.interceptors
      ..add(_SmartschoolLogInFirstInterceptor(client._auth))
      ..add(
        _SmartschoolCookieManager(
          cookieJar,
          client._auth.refusedSession,
          () => client._auth.settledSession,
        ),
      )
      ..add(client._auth);

    return client;
  }

  // -------------------------------------------------------------------------
  // Public API used by services
  //
  // A request that finds the session unauthenticated logs in first. When that
  // login fails, these methods throw the SmartschoolException (typically a
  // SmartschoolAuthenticationError subtype) itself, not the DioException that
  // carries it (see _send, #20). When Smartschool cannot be reached, they
  // throw a SmartschoolConnectionError with the DioException as its cause
  // (#21). On a disposed client, they throw a SmartschoolClientDisposedError
  // (a StateError) without sending anything (see dispose, #54, #73).
  // -------------------------------------------------------------------------

  /// Performs a GET request and returns the decoded JSON body.
  ///
  /// Handles Smartschool's double-encoded JSON (a JSON string whose content
  /// is another JSON string) transparently.
  Future<dynamic> getJson(String path, {Map<String, dynamic>? query}) async {
    final resp = await _send(
      () => _dio.get<String>(path, queryParameters: query),
    );
    return _decodeJson(resp);
  }

  /// Performs a POST request and returns the decoded JSON body.
  Future<dynamic> postJson(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    final resp = await _send(
      () => _dio.post<String>(path, data: data, queryParameters: query),
    );
    return _decodeJson(resp);
  }

  /// Performs an authenticated POST with a JSON body and returns the whole
  /// [Response]: the status code, the headers and the final URL (`realUri`)
  /// as well as the body, which is not decoded.
  ///
  /// [data] goes out as `application/json`: a map or a list is encoded as
  /// JSON, a string is sent as it is. Unlike [postJson], this neither
  /// decodes the answer nor throws for a status other than `200`, so that a
  /// service can read a JSON API's error answers itself (such as the
  /// planner's, #85). A session that Smartschool refuses is handled as for
  /// every request: the client logs in again and retries the request once,
  /// with the same body.
  ///
  /// Pass `retryAfterLogin: false` for a request that must go out once only,
  /// such as one that creates something (the planner's fill of a timetable
  /// slot, #87): when Smartschool refuses the session for it, it then fails
  /// at once with a [SmartschoolSessionExpiredError], without logging in and
  /// sending it again, and the client's next request logs in before it is
  /// sent (#134; see [postMultipartResponse]).
  Future<Response<String>> postJsonResponse(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
  }) {
    return _send(
      () => _dio.post<String>(
        path,
        data: data,
        queryParameters: query,
        options: Options(
          contentType: Headers.jsonContentType,
          extra: _sessionStateExtra(retryAfterLogin, null),
        ),
      ),
    );
  }

  /// Performs an authenticated DELETE and returns the whole [Response]: the
  /// status code, the headers and the final URL (`realUri`) as well as the
  /// body, which is not decoded.
  ///
  /// Like [postJsonResponse], it does not throw for a status other than
  /// `200`, so that a service can read a JSON API's answers itself (such as
  /// the `204` with which the Lesfiches module answers the removal of a
  /// weblink or an attachment from a lesfiche, #129). A session that
  /// Smartschool refuses is handled as for every request: the client logs
  /// in again and retries the request once, unless `retryAfterLogin` is
  /// `false` (see [postJsonResponse]).
  Future<Response<String>> deleteResponse(
    String path, {
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
  }) {
    return _send(
      () => _dio.delete<String>(
        path,
        queryParameters: query,
        options: Options(extra: _sessionStateExtra(retryAfterLogin, null)),
      ),
    );
  }

  /// Executes the Smartschool XML command protocol.
  ///
  /// Builds the `<request>` XML, POSTs it to the dispatcher URL, parses the
  /// response and returns each matched element as a [Map<String, dynamic>].
  ///
  /// Throws a [SmartschoolUnexpectedPageError] (a
  /// [SmartschoolAuthenticationError]) when Smartschool answers with an HTML
  /// page: it says whether that is Smartschool's login page, and keeps the
  /// status, the title and the main heading of the page, so that an error
  /// page is not taken for an expired session (#106). The same for a page
  /// with a comment before its doctype, and for a piece of a page, such as
  /// `<!-- ... -->` and `<div>`s, also one that happens to be well-formed XML
  /// (#110). Such an answer is not retried, nor does the client log in again
  /// for it: it does that for the answers with which Smartschool refuses a
  /// session (see below). Throws a [SmartschoolParsingError] when Smartschool
  /// answers with anything else that is not XML, an empty answer included,
  /// and for malformed XML, saying where it breaks off but not what it holds
  /// (#110). So every answer that is not XML is a [SmartschoolException].
  ///
  /// With [allowEmptyAnswer], an empty answer (no body, or white space only)
  /// with status `200` returns no elements instead: Smartschool answers some
  /// commands that way when they change nothing, such as a `quick delete` of
  /// a message it does not delete (#59). An empty answer with another status
  /// still throws. Nor is a refused session read as an empty answer: on an
  /// expired session Smartschool answers the command with an empty `401`,
  /// and the client logs in again and retries it (see [create]), or throws a
  /// [SmartschoolSessionExpiredError] when it is refused again.
  Future<List<Map<String, dynamic>>> postXml({
    required String url,
    required String subsystem,
    required String action,
    required Map<String, String> params,
    required String xpath,
    bool allowEmptyAnswer = false,
  }) async {
    final command = XmlInterface.buildCommand(subsystem, action, params);

    final resp = await _send(
      () => _dio.post<String>(
        url,
        data: {'command': command},
        options: Options(
          headers: {kXRequestedWith: 'XMLHttpRequest'},
          contentType: Headers.formUrlEncodedContentType,
        ),
      ),
    );

    return readXmlAnswer(
      resp,
      action: action,
      allowEmptyAnswer: allowEmptyAnswer,
      parse: (body) => XmlInterface.parseResponse(body, xpath),
    );
  }

  /// Downloads raw bytes from [path].
  ///
  /// The whole file is held in memory; [downloadStream] reads it as it comes
  /// in instead.
  ///
  /// With [maxBytes], the download fails with a
  /// [SmartschoolDownloadTooLargeError] as soon as the file turns out to be
  /// larger than that many bytes: before any of it is read when Smartschool
  /// announces a larger size (`Content-Length`), otherwise once more than
  /// [maxBytes] bytes came in. The client then stops the transfer (#41).
  /// Without it, there is no limit.
  ///
  /// Throws a [SmartschoolDownloadError] when Smartschool answers with
  /// another status than `200`, and a [SmartschoolConnectionError] when the
  /// connection fails, also halfway through the file. A session that
  /// Smartschool refuses is handled as for every request (see
  /// [downloadStream]).
  Future<Uint8List> download(String path, {int? maxBytes}) async {
    final file = await downloadStream(path, maxBytes: maxBytes);
    final bytes = BytesBuilder();
    await for (final chunk in file.stream) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// Downloads [path] as a stream: returns the [SmartschoolDownload] as soon
  /// as the headers of Smartschool's answer are in, with its size
  /// (`contentLength`), `fileName` and `contentType`, and the content to be
  /// read from its `stream` as it comes in (#41).
  ///
  /// Reading the stream reads the transfer: pausing the subscription pauses
  /// it, and cancelling the subscription (or [SmartschoolDownload.cancel])
  /// stops it and closes the connection. The client stops the transfer
  /// itself: Dio would read a response to its end after its reader stopped
  /// listening.
  ///
  /// Until the stream is listened to, the transfer waits, as while it is
  /// paused: no more of the content comes in than the few chunks that
  /// arrived while the client handled the headers, however late the stream
  /// is listened to (#81). So it can be listened to once the file it is
  /// written to is open. A download that is neither read nor cancelled keeps
  /// its connection open. (A `receiveTimeout` set on [dio] counts that wait,
  /// as it counts a pause.)
  ///
  /// A session that Smartschool refuses is handled as for every request: it
  /// answers the download with its login chain (or `401`) instead of the
  /// file, the client logs in again and retries the download once, and the
  /// stream holds the answer to that retry. The login page is read by the
  /// client, never handed over as the file: when the retry is refused too,
  /// this throws a [SmartschoolSessionExpiredError], and when the login
  /// fails, the error it failed with (see [SmartschoolAuthenticationError]).
  ///
  /// With [maxBytes], the download fails with a
  /// [SmartschoolDownloadTooLargeError] as soon as the file turns out to be
  /// larger than that many bytes. When Smartschool announces a larger size
  /// (`Content-Length`), this throws it and nothing is read. Otherwise the
  /// bytes are counted as they come in, and the stream ends with it once
  /// more than [maxBytes] came in, after at most [maxBytes] bytes. Either way
  /// the client stops the transfer. Every byte of the content counts, also
  /// one that came in before the stream was listened to: whenever it is
  /// listened to, the transfer, and what the client holds of it in memory,
  /// stays within [maxBytes] and a few chunks (#81). Must not be negative.
  ///
  /// Throws a [SmartschoolDownloadError] when Smartschool answers with
  /// another status than `200` (such as `404` for an Intradesk file that
  /// does not exist), and a [SmartschoolConnectionError] when it cannot be
  /// reached; the stream ends with a [SmartschoolConnectionError] when the
  /// connection fails halfway through the file.
  Future<SmartschoolDownload> downloadStream(
    String path, {
    int? maxBytes,
  }) async {
    if (maxBytes != null && maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
    }
    // Stops the transfer: Dio closes the connection of a response it is
    // reading only when its request is cancelled. The retry after a new
    // login is sent with the same token.
    final cancelToken = CancelToken();
    final resp = await _send(
      () => _dio.get<ResponseBody>(
        path,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream),
      ),
    );
    final body = resp.data;
    final status = resp.statusCode ?? 0;
    if (status != 200 || body == null) {
      cancelToken.cancel();
      throw SmartschoolDownloadError('Download failed: $path', status);
    }

    int? announced;
    final content = _DownloadContent(
      body.stream,
      cancelToken: cancelToken,
      maxBytes: maxBytes,
      tooLarge: () => SmartschoolDownloadTooLargeError(
        'The download of $path is larger than the $maxBytes bytes allowed: '
        'more than $maxBytes bytes came in',
        maxBytes: maxBytes!,
        contentLength: announced,
      ),
      failure: (error) => _transferFailure(error, resp.requestOptions),
      cancelled: () => StateError('The download of $path was cancelled'),
    );
    final download = SmartschoolDownload(
      stream: content.stream,
      headers: resp.headers,
      onCancel: content.cancel,
    );

    announced = download.contentLength;
    if (maxBytes != null && announced != null && announced > maxBytes) {
      content.cancel();
      throw SmartschoolDownloadTooLargeError(
        'The download of $path is larger than the $maxBytes bytes allowed: '
        'Smartschool announced $announced bytes',
        maxBytes: maxBytes,
        contentLength: announced,
      );
    }
    return download;
  }

  /// Performs an authenticated GET and returns the raw response body string.
  ///
  /// Unlike [getJson], this method does **not** attempt to JSON-decode the
  /// response — it is used when the expected response is HTML or plain text
  /// (e.g. the message compose form page).
  Future<String> getRaw(String path, {Map<String, dynamic>? query}) async {
    final resp = await getResponse(path, query: query);
    return resp.data ?? '';
  }

  /// Performs the same GET as [getRaw], but returns the whole [Response]:
  /// the status code, the headers and the final URL (`realUri`) as well as
  /// the body.
  ///
  /// Pass it as `sameSessionAs` to a later request that carries state of
  /// this page, such as the tokens of a form it holds, so that the request
  /// goes out only in the session the page was loaded in (see
  /// [postMultipartResponse]).
  Future<Response<String>> getResponse(
    String path, {
    Map<String, dynamic>? query,
  }) {
    return _send(() => _dio.get<String>(path, queryParameters: query));
  }

  /// Performs an authenticated `application/x-www-form-urlencoded` POST and
  /// returns the raw response body string.
  ///
  /// Used for Smartschool operations that submit legacy HTML forms (such as
  /// recipient search) whose responses are XML or plain text instead of JSON.
  ///
  /// [retryAfterLogin] and [sameSessionAs]: see [postMultipartResponse].
  Future<String> postFormRaw(
    String path,
    Map<String, String> fields, {
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
    Response<dynamic>? sameSessionAs,
  }) async {
    final resp = await postFormResponse(
      path,
      fields,
      query: query,
      retryAfterLogin: retryAfterLogin,
      sameSessionAs: sameSessionAs,
    );
    return resp.data ?? '';
  }

  /// Performs the same POST as [postFormRaw], but returns the whole
  /// [Response]: the status code, the headers and the final URL
  /// (`realUri`) as well as the body.
  ///
  /// Used when the body alone is not enough, such as for the HTTP status of
  /// an error page. (An answer of the login chain never arrives here: the
  /// client logs in again and retries the request once, and throws a
  /// [SmartschoolSessionExpiredError] when the retry is refused too.)
  ///
  /// [retryAfterLogin] and [sameSessionAs]: see [postMultipartResponse].
  Future<Response<String>> postFormResponse(
    String path,
    Map<String, String> fields, {
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
    Response<dynamic>? sameSessionAs,
  }) {
    return _send(
      () => _dio.post<String>(
        path,
        data: fields,
        queryParameters: query,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {kXRequestedWith: 'XMLHttpRequest'},
          extra: _sessionStateExtra(retryAfterLogin, sameSessionAs),
        ),
      ),
    );
  }

  /// Performs an authenticated `multipart/form-data` POST and returns the raw
  /// response body string.
  ///
  /// Used for the Smartschool message send endpoint and file upload endpoint,
  /// both of which require multipart rather than JSON or URL-encoded bodies.
  ///
  /// [retryAfterLogin] and [sameSessionAs]: see [postMultipartResponse].
  Future<String> postMultipartRaw(
    String path,
    FormData formData, {
    bool retryAfterLogin = true,
    Response<dynamic>? sameSessionAs,
  }) async {
    final resp = await postMultipartResponse(
      path,
      formData,
      retryAfterLogin: retryAfterLogin,
      sameSessionAs: sameSessionAs,
    );
    return resp.data ?? '';
  }

  /// Performs the same POST as [postMultipartRaw], but returns the whole
  /// [Response]: the status code, the headers and the final URL (`realUri`)
  /// as well as the body.
  ///
  /// When Smartschool refuses the session for a request, the client logs in
  /// again and retries the request once (a multipart request with a copy of
  /// its [FormData]). Pass `retryAfterLogin: false` for a request that
  /// carries state of the session it was prepared in, such as the tokens of
  /// Smartschool's compose form (`uniqueUsc`, `randomDir`): a retry would
  /// send that state stale, in a session it does not belong to. Such a
  /// request is neither retried nor used to log in again: when Smartschool
  /// refuses its session, it fails at once with a
  /// [SmartschoolSessionExpiredError] (#25). The client remembers that the
  /// session was refused, and its next request logs in before it is sent
  /// (#134), unless it logged in since: so calling the write again sends it
  /// once, in a new session. A request sent with [sameSessionAs] does not
  /// log in first: it goes out only in the session of that answer.
  ///
  /// That only covers the request being refused. Pass [sameSessionAs] too,
  /// an earlier answer of this client that the state comes from (such as the
  /// compose form, loaded with [getResponse]), for a request that must not
  /// go out in another session than that answer's in any case. The client
  /// replaces its session when it logs in again, also for another request on
  /// the same client, and Smartschool then accepts the request in the new
  /// session, stale state and all. Such a request is only sent when no login
  /// started on this client since the request of [sameSessionAs] went out,
  /// and none runs: otherwise it is not sent, and fails at once with a
  /// [SmartschoolSessionExpiredError]. A login replaces the session in the
  /// cookie cache before it completes (it loads the login form in a new
  /// session, #45), and it may have replaced it when it fails, so a login
  /// that runs or failed counts as well as one that completed (#38). Pass
  /// `retryAfterLogin: false` with it: a retry after logging in would not be
  /// sent either.
  Future<Response<String>> postMultipartResponse(
    String path,
    FormData formData, {
    bool retryAfterLogin = true,
    Response<dynamic>? sameSessionAs,
  }) {
    return _send(
      () => _dio.post<String>(
        path,
        data: formData,
        options: Options(
          extra: _sessionStateExtra(retryAfterLogin, sameSessionAs),
        ),
      ),
    );
  }

  /// The request `extra` that keeps the auth interceptor from retrying a
  /// request in a new session (unless [retryAfterLogin]), and from sending
  /// it in another session than that of [sameSessionAs] (when given), or
  /// `null` when neither applies.
  static Map<String, dynamic>? _sessionStateExtra(
    bool retryAfterLogin,
    Response<dynamic>? sameSessionAs,
  ) {
    if (retryAfterLogin && sameSessionAs == null) return null;
    return {
      if (!retryAfterLogin) _SmartschoolAuthInterceptor._noRetryKey: true,
      if (sameSessionAs != null)
        _SmartschoolAuthInterceptor._sameSessionKey: _SameSession.of(
          sameSessionAs,
        ),
    };
  }

  /// Performs an authenticated `application/x-www-form-urlencoded` POST with
  /// a raw body string and returns the raw response body string.
  ///
  /// Used when the endpoint requires form-urlencoded data with repeated field
  /// names (e.g. `msgIDs[]=123&msgIDs[]=456`), which cannot be represented
  /// as a [Map<String, String>].
  Future<String> postFormEncodedRaw(String path, String body) async {
    final resp = await _send(
      () => _dio.post<String>(
        path,
        data: body,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {kXRequestedWith: 'XMLHttpRequest'},
        ),
      ),
    );
    return resp.data ?? '';
  }

  /// Returns the currently authenticated user.
  ///
  /// Triggers a minimal API call to force login if not yet authenticated.
  ///
  /// Throws a [SmartschoolClientDisposedError] on a disposed client, also
  /// when the user is cached (see [dispose]).
  Future<Map<String, dynamic>> get authenticatedUser async {
    _checkNotDisposed();
    if (_authenticatedUser == null) {
      await platformId; // login side-effect populates _authenticatedUser
    }
    if (_authenticatedUser == null) {
      // Session was already valid (no auth flow triggered), so
      // _parseLoginInformation was never called. Fetch any page to hydrate it.
      _parseLoginInformation(await getRaw('/'));
    }
    final user = _authenticatedUser;
    if (user == null) {
      throw const SmartschoolAuthenticationError(
        'Could not retrieve authenticated user information',
      );
    }
    return user;
  }

  /// Returns the currently logged-in user.
  ///
  /// Reads from the `authenticatedUser` data embedded in every Smartschool page
  /// (already cached after the first authenticated request).  No extra HTTP
  /// requests are made.
  ///
  /// The integer [SmartschoolUser.id] is the server-assigned user ID, parsed
  /// from the `authenticatedUser.id` string (`{ssID}_{userId}_{coaccountIdx}`).
  ///
  /// Throws a [SmartschoolClientDisposedError] on a disposed client (see
  /// [dispose]).
  Future<SmartschoolUser> getCurrentUser() async {
    final user = await authenticatedUser;

    final idStr = user['id'] as String? ?? '';
    final parts = idStr.split('_');
    final id = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    if (id == null) {
      throw SmartschoolParsingError(
        'Could not parse user ID from authenticatedUser.id "$idStr"',
      );
    }

    final nameMap = user['name'] as Map<String, dynamic>?;
    final displayName = (nameMap?['startingWithFirstName'] as String? ?? '')
        .trim();
    if (displayName.isEmpty) {
      throw const SmartschoolParsingError(
        'Could not parse display name from authenticatedUser',
      );
    }

    final avatarUrl = user['pictureUrl'] as String?;

    return SmartschoolUser(
      id: id,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );
  }

  /// Returns the platform ID for the authenticated user.
  ///
  /// Lazily fetched and cached after the first call: once known, it sends
  /// nothing, so it does not tell whether Smartschool still accepts the
  /// session (use [ensureAuthenticated] for that). Throws a
  /// [SmartschoolClientDisposedError] on a disposed client, also when it is
  /// cached (see [dispose]).
  Future<int> get platformId async {
    _checkNotDisposed();
    _platformId ??= await _fetchPlatformId();
    return _platformId!;
  }

  /// Sends a light authenticated request on every call, and throws when
  /// Smartschool does not accept the session for it, also after logging in
  /// again.
  ///
  /// The request is a GET of the user's course list
  /// (`/course-list/api/v1/courses`), the one [platformId] is read from; the
  /// platform ID it gives is cached for [platformId]. It goes out on every
  /// call, also when an earlier call (or [platformId]) found the session
  /// valid: the session may have expired on the server since, or been dropped
  /// with [clearCookies] (#140). Like any request of the client, it logs in
  /// when Smartschool refuses the session, and is then retried once; and it
  /// logs in before it is sent when Smartschool refused the session for an
  /// earlier request and no login completed since (#134). So when it returns
  /// normally, Smartschool accepted the client's session for it, and the
  /// requests after it go out in that session.
  ///
  /// When Smartschool refuses the session also after the client logged in
  /// again, or the client does not log in (after three logins in a row that
  /// did not get the session accepted, see [resetLoginAttempts]), it throws a
  /// [SmartschoolSessionExpiredError].
  ///
  /// A login failure is thrown as the matching [SmartschoolAuthenticationError]
  /// subclass (e.g. [SmartschoolInvalidCredentialsError]), as every request
  /// helper throws it.
  ///
  /// When Smartschool cannot be reached (the host does not resolve, the
  /// connection fails or times out), a [SmartschoolConnectionError] is thrown
  /// instead, with the `DioException` as its `cause`, as every request helper
  /// throws it: a network problem is not reported as a failed login.
  ///
  /// On a disposed client, it throws a [SmartschoolClientDisposedError]
  /// without sending anything, also when it validated the session before (see
  /// [dispose]).
  Future<void> ensureAuthenticated() async {
    _checkNotDisposed();
    try {
      // Not [platformId], which sends nothing once the ID is cached (#140).
      _platformId = await _fetchPlatformId();
    } on DioException catch (e) {
      throw SmartschoolAuthenticationError(
        'Unable to validate Smartschool session: ${e.message ?? e.toString()}',
      );
    } on SmartschoolException {
      rethrow;
    } catch (e) {
      // Disposed while it ran: the SmartschoolClientDisposedError (#54, #73),
      // which says more than a failed login would.
      if (isDisposed) rethrow;
      throw SmartschoolAuthenticationError(
        'Unable to validate Smartschool session: $e',
      );
    }
  }

  /// Deletes all persisted cookies for this user (effectively logs out).
  Future<void> clearCookies() => _cookieJar.deleteAll();

  /// Lets the client log in again at once after it stopped logging in on its
  /// own (#32).
  ///
  /// After three logins in a row that did not get Smartschool to accept the
  /// session (the login failed, or the retry of the request was refused
  /// again), a request that Smartschool refuses fails with a
  /// [SmartschoolSessionExpiredError] without logging in. Once the
  /// `loginCooldown` of [create] has passed since the last login, the next
  /// such request logs in once: when Smartschool accepts the session, the
  /// client counts from zero again, otherwise it waits another cooldown.
  ///
  /// It does not try again after a cooldown when the last login failed on the
  /// credentials: Smartschool rejected the password, the 2FA code or the
  /// account-verification answer, or asked for a 2FA code or verification
  /// answer they cannot give ([SmartschoolInvalidCredentialsError] and the
  /// 2FA and account-verification errors listed at
  /// [SmartschoolAuthenticationError]).
  /// Logging in with them every few minutes could get the account locked.
  /// Call this method once they are fixed (for instance when [credentials]
  /// returns the new password), or to log in again before the cooldown ends.
  /// The next refused request logs in again, and three logins in a row are
  /// allowed again.
  void resetLoginAttempts() => _auth.reset();

  /// Emits a normalized notification counter update to listeners.
  ///
  /// Returns `true` when it emitted the update. Returns `false`, and emits
  /// nothing, when [moduleName] is empty, or when the client was disposed:
  /// [dispose] closes [notificationCounterUpdates], so nobody can receive the
  /// update anymore (#54). A source that publishes updates as they come in,
  /// such as a websocket listener, may well get one more in after the app
  /// disposed the client, which is no reason to make it fail.
  bool emitNotificationCounterUpdate({
    required String moduleName,
    required int counter,
    bool isNew = false,
    String source = 'unknown',
    DateTime? timestamp,
  }) {
    if (moduleName.trim().isEmpty) return false;
    if (_notificationCounterController.isClosed) return false;

    _notificationCounterController.add(
      NotificationCounterUpdate(
        moduleName: moduleName,
        counter: counter,
        isNew: isNew,
        source: source,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );
    return true;
  }

  /// Releases long-lived client resources: closes the HTTP client and
  /// [notificationCounterUpdates].
  ///
  /// This is optional for short-lived scripts but recommended for daemon-like
  /// usage that keeps a [SmartschoolClient] alive for longer periods.
  ///
  /// With [force] (the default), the requests that are running are cut off;
  /// without it, the connections they use are left to finish them.
  ///
  /// A disposed client cannot be used for Smartschool anymore (#54). Every
  /// request method ([getJson], [postJson], [postJsonResponse], [postXml],
  /// [getRaw], [getResponse], [postFormRaw], [postFormResponse],
  /// [postMultipartRaw], [postMultipartResponse], [postFormEncodedRaw],
  /// [download], [downloadStream]), and so every service call, throws a
  /// [SmartschoolClientDisposedError] saying that the client was disposed,
  /// before it sends anything; so do [ensureAuthenticated], [platformId],
  /// [authenticatedUser] and [getCurrentUser], also when they have their
  /// answer cached. A request that was running when the client was disposed
  /// fails with the same error when it does not complete, and so does the
  /// stream of a download that was being read; such a request may or may not
  /// have reached Smartschool (a message submitted by
  /// `MessagesService.sendMessage` may have been sent). Using a disposed
  /// client is a mistake of its caller, not a problem of Smartschool or of
  /// the network: the error is a [StateError], not a [SmartschoolException],
  /// so code that shows "offline" or retries on a [SmartschoolConnectionError]
  /// does not take it for one. It has a type of its own, so that it can be
  /// told apart from any other [StateError] (#73), and [isDisposed] tells
  /// whether the client was disposed. Create a new client to use Smartschool
  /// again.
  ///
  /// [emitNotificationCounterUpdate] returns `false` on a disposed client,
  /// and [clearCookies] still deletes the session saved in [cacheDir].
  ///
  /// Calling it again does nothing: it returns what the first call returned,
  /// and its [force] is ignored.
  Future<void> dispose({bool force = true}) => _disposal ??= _dispose(force);

  Future<void> _dispose(bool force) async {
    _dio.close(force: force);
    await _notificationCounterController.close();
  }

  /// Whether [dispose] was called (#73).
  ///
  /// It is `true` from the moment [dispose] is called, before the future it
  /// returns completes, and stays `true`: from then on the client sends no
  /// more requests, and its request methods throw a
  /// [SmartschoolClientDisposedError]. Code that catches every error of a
  /// call can ask it to tell a client that was shut down from a call that
  /// failed, as catching the [SmartschoolClientDisposedError] tells by type.
  bool get isDisposed => _disposal != null;

  /// Throws the [SmartschoolClientDisposedError] when [dispose] was called.
  void _checkNotDisposed() {
    if (isDisposed) throw _disposedError();
  }

  /// The [SmartschoolClientDisposedError] that the client throws once it is
  /// disposed (#54, #73), for a request that it did not send, or [during]
  /// which it was disposed.
  static SmartschoolClientDisposedError _disposedError([String? during]) =>
      SmartschoolClientDisposedError(
        during == null
            ? 'SmartschoolClient was disposed: it sends no more requests'
            : 'SmartschoolClient was disposed during $during',
      );

  // -------------------------------------------------------------------------
  // Internal auth helpers — called by [_SmartschoolAuthInterceptor]
  // -------------------------------------------------------------------------

  /// Checks if [uri] is one of Smartschool's authentication pages.
  bool isAuthUri(Uri uri) {
    const authSegments = {'login', 'account-verification', '2fa'};
    return uri.pathSegments.any(authSegments.contains);
  }

  /// Handles the `/login` page: parses the form and POSTs credentials.
  Future<Response<String>> doLogin(String htmlBody, String loginUrl) async {
    final formData = _fillForm(htmlBody, 'form[name="login_form"]', {
      'username': credentials.username,
      'password': credentials.password,
    });

    return _rawPost(
      loginUrl,
      formData,
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  /// Handles the `/account-verification` page: extracts user info from JS,
  /// then POSTs the birthday/MFA answer.
  Future<Response<String>> doAccountVerification(
    String htmlBody,
    String verificationUrl,
  ) async {
    _parseLoginInformation(htmlBody);

    final mfa = credentials.mfa;
    if (mfa == null || mfa.trim().isEmpty) {
      throw const SmartschoolAccountVerificationRequiredError();
    }

    final doc = html_parser.parse(htmlBody);
    final answerInput = doc.querySelector(
      'form[name="account_verification_form"] input[name*="_security_question_answer"]',
    );
    final expectsDate = answerInput?.attributes['type'] == 'date';
    final dateLike = _dateAnswer.hasMatch(mfa.trim());
    if (expectsDate && !dateLike) {
      throw const SmartschoolAccountVerificationRequiredError(
        'Account verification expects a date (yyyy-mm-dd), but mfa looks like '
        'a TOTP secret. Set credentials.yml mfa to the requested date answer.',
      );
    }

    final formData = _fillForm(
      htmlBody,
      'form[name="account_verification_form"]',
      {'security_question_answer': mfa},
    );

    return _rawPost(
      verificationUrl,
      formData,
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  /// An account verification answer as Smartschool's date field takes it.
  static final _dateAnswer = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Throws a [SmartschoolInvalidTotpSecretError] when [Credentials.mfa] can
  /// answer neither step that may follow the password: it is not a date for
  /// the account verification, and not a TOTP secret for the 2FA step (#79).
  ///
  /// Run before a login loads the login form, so that an `mfa` that cannot
  /// work does not cost a password login, on every login. An `mfa` that is
  /// empty once trimmed (no `mfa`, as the steps after the password take it)
  /// or a date passes: the steps after the password check it as they use it.
  void _checkMfaBeforeLogin() {
    final mfa = credentials.mfa?.trim();
    if (mfa == null || mfa.isEmpty || _dateAnswer.hasMatch(mfa)) return;
    try {
      Credentials.normalizeTotpSecret(mfa);
    } on SmartschoolInvalidTotpSecretError {
      throw const SmartschoolInvalidTotpSecretError(
        'mfa is neither a TOTP secret nor a date (yyyy-mm-dd) for account '
        'verification, so the login did not post the password. As a TOTP '
        'secret, use the key Smartschool shows when an authenticator app is '
        'added (the letters A-Z and the digits 2-7; spaces and hyphens are '
        'ignored), not the 6-digit code the app shows.',
      );
    }
  }

  /// Handles the `/2fa` page: generates a TOTP code and POSTs it.
  ///
  /// The code is generated from [Credentials.mfa] as
  /// [Credentials.normalizeTotpSecret] returns it, so a secret copied in
  /// groups works; one that is not a TOTP secret throws its
  /// [SmartschoolInvalidTotpSecretError] before anything of this step is sent
  /// (#79).
  Future<Response<String>> do2fa() async {
    final mfa = credentials.mfa;
    if (mfa == null || mfa.trim().isEmpty) {
      throw const SmartschoolTwoFactorRequiredError();
    }
    final secret = Credentials.normalizeTotpSecret(mfa);

    // Verify TOTP is configured on this account
    final configResp = await _rawGet('/2fa/api/v1/config');
    final config = jsonDecode(configResp.data ?? '{}') as Map<String, dynamic>;
    final mechanisms =
        (config['possibleAuthenticationMechanisms'] as List?)?.cast<String>() ??
        [];
    if (!mechanisms.contains('googleAuthenticator')) {
      throw SmartschoolUnsupportedTwoFactorMethodError(
        List.unmodifiable(mechanisms),
      );
    }

    final code = OTP.generateTOTPCodeString(
      secret,
      DateTime.now().millisecondsSinceEpoch,
      length: 6,
      interval: 30,
      algorithm: Algorithm.SHA1,
      isGoogle: true,
    );

    return _rawPost(
      '/2fa/api/v1/google-authenticator',
      '{"google2fa":"$code"}',
      contentType: Headers.jsonContentType,
    );
  }

  /// Interprets the response returned by the `/2fa/api/v1/google-authenticator`
  /// endpoint that [do2fa] posts to.
  ///
  /// That endpoint answers with HTTP 200 and a JSON body on **both** success
  /// (`{"success":true,"redirectTo":"/"}`) and failure
  /// (`{"success":false,"error":"…"}`), and never issues an HTTP redirect — so
  /// the request URL alone (whose path contains `/2fa/`) cannot distinguish the
  /// two. The body's `success` flag is the only reliable signal.
  ///
  /// Returns `true` when 2FA was accepted, `false` when it was rejected, and
  /// `null` when the response is not the expected JSON shape (e.g. the client
  /// was redirected back to the HTML `/2fa` page), leaving the caller to fall
  /// back to URL-based classification.
  bool? parse2faSuccess(Response<String> response) {
    final body = response.data;
    if (body == null || body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['success'] is bool) {
        return decoded['success'] as bool;
      }
    } on FormatException {
      // Not JSON — most likely the HTML /2fa page.
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Runs [request], a request on [_dio], and throws the [SmartschoolException]
  /// that its failure means rather than the [DioException] it arrives in.
  ///
  /// Dio delivers every failure of a request as a [DioException]: when the
  /// auth interceptor logs in for a regular request and the login fails, the
  /// [SmartschoolAuthenticationError] (subtype) arrives as its `error`, and
  /// that is thrown as itself (#20). When Smartschool cannot be reached (see
  /// [_describeConnectionFailure]), a [SmartschoolConnectionError] is thrown
  /// with the [DioException] as its `cause` (#21). The public request helpers
  /// go through here so that a service call throws the typed error its caller
  /// can catch. Any other [DioException] is rethrown unchanged.
  ///
  /// On a disposed client, [request] is not made: this throws the
  /// [SmartschoolClientDisposedError] instead (see [dispose], #54), and so
  /// does a request that fails once the client was disposed while it ran
  /// (see [_requestFailure]).
  Future<Response<T>> _send<T>(Future<Response<T>> Function() request) async {
    _checkNotDisposed();
    try {
      return await request();
    } on DioException catch (e) {
      final inner = e.error;
      if (inner is SmartschoolException) {
        Error.throwWithStackTrace(inner, e.stackTrace);
      }
      final failure = _requestFailure(e);
      if (failure != null) {
        Error.throwWithStackTrace(failure, e.stackTrace);
      }
      rethrow;
    }
  }

  /// What a request that failed with [e] throws instead of [e], or `null`
  /// when it throws [e] itself.
  ///
  /// On a disposed client, that is the [SmartschoolClientDisposedError]
  /// (#54): the client closed its HTTP client, which refuses a new request
  /// (such as one of a login that the request started) with a connection
  /// error, and a forced [dispose] drops the connections of the requests that
  /// run. Neither means that Smartschool could not be reached, so
  /// [_describeConnectionFailure] is not asked on a disposed client.
  /// Otherwise, it is the [SmartschoolConnectionError] that [e] means (#21),
  /// if any.
  Object? _requestFailure(DioException e) {
    if (isDisposed) {
      final request = e.requestOptions;
      return _disposedError('${request.method} ${request.uri}');
    }
    return _connectionError(e);
  }

  /// The [SmartschoolConnectionError] that [e] means, with [e] as its
  /// `cause`, or `null` when [e] does not mean that Smartschool could not be
  /// reached (see [_describeConnectionFailure]).
  SmartschoolConnectionError? _connectionError(DioException e) {
    final unreachable = _describeConnectionFailure(e);
    if (unreachable == null) return null;
    return SmartschoolConnectionError(
      'Unable to reach Smartschool at ${credentials.mainUrl}: $unreachable',
      cause: e,
    );
  }

  /// The error that the reader of a download gets for [error], a failure of
  /// the transfer of its content (#41), as [_send] throws a failure of the
  /// request: the [SmartschoolClientDisposedError] when the client was
  /// disposed while it was read (#54), a [SmartschoolConnectionError] when the
  /// connection failed or timed out, [error] itself otherwise.
  ///
  /// Dio hands on what the connection fails with halfway through a
  /// response as it comes, such as the `HttpException` of a connection that
  /// closed early, and a timeout as a [DioException] of [request].
  Object _transferFailure(Object error, RequestOptions request) {
    if (error is SmartschoolException) return error;
    final dioError = error is DioException
        ? error
        : DioException(requestOptions: request, error: error);
    return _requestFailure(dioError) ?? error;
  }

  Future<int> _fetchPlatformId() async {
    final courses = await getJson('/course-list/api/v1/courses') as List;
    return (courses[0] as Map<String, dynamic>)['platformId'] as int;
  }

  dynamic _decodeJson(Response<String> resp) {
    if (resp.statusCode != 200) {
      throw SmartschoolDownloadError(
        'Failed to retrieve JSON',
        resp.statusCode ?? 0,
      );
    }

    dynamic value = resp.data ?? '';
    // Handle double-encoded JSON: a JSON response whose value is another JSON
    // string. Keep decoding until we reach a non-string result.
    while (value is String) {
      if (value.isEmpty) return {};

      final trimmed = value.trimLeft();
      if (_isLikelyHtml(trimmed)) {
        throw SmartschoolAuthenticationError(
          'Expected JSON but received HTML from ${resp.realUri}. '
          'Session may be unauthenticated or login flow did not complete.',
        );
      }

      try {
        value = jsonDecode(value);
      } on FormatException {
        throw SmartschoolJsonError(
          'Failed to decode JSON response from ${resp.realUri}. '
          'Body preview: ${_preview(trimmed)}',
          resp.statusCode ?? 0,
        );
      }
    }
    return value;
  }

  /// Parses the authenticated user from a Smartschool HTML page.
  ///
  /// Smartschool embeds user data in a script tag like:
  /// `APP.extend({...}, JSON.parse('{"vars":{"authenticatedUser":{...}}}'));`
  void _parseLoginInformation(String htmlBody) {
    final doc = html_parser.parse(htmlBody);
    for (final script in doc.querySelectorAll('script')) {
      final src = script.attributes['src'];
      if (src != null) continue; // skip external scripts

      final text = script.text;
      if (!text.contains('extend')) continue;

      final match = RegExp(
        r'''JSON\s*\.\s*parse\s*\(\s*'(.*)'\s*\)\s*\)\s*;?\s*$''',
        caseSensitive: false,
      ).firstMatch(text);

      if (match == null) continue;

      try {
        // Unescape \uXXXX sequences and double back-slashes
        var raw = match.group(1)!;
        raw = raw.replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        );
        raw = raw.replaceAll(r'\\', r'\');

        final data = jsonDecode(raw) as Map<String, dynamic>;
        final vars = data['vars'] as Map<String, dynamic>?;
        final user = vars?['authenticatedUser'] as Map<String, dynamic>?;
        if (user != null) {
          _authenticatedUser = user;
          return;
        }
      } catch (_) {
        // Malformed script — try next one
      }
    }
  }

  /// Extracts all form inputs and overlays [values] onto them.
  ///
  /// Mirrors Python's `fill_form` / `get_all_values_from_form` helpers
  /// from `common.py`.
  Map<String, String> _fillForm(
    String htmlBody,
    String formSelector,
    Map<String, String> values,
  ) {
    final doc = html_parser.parse(htmlBody);
    final form = doc.querySelector(formSelector);
    if (form == null) {
      throw SmartschoolParsingError(
        'Could not find form "$formSelector" in response',
      );
    }

    final data = <String, String>{};
    final remaining = Map<String, String>.from(values);

    for (final input in form.querySelectorAll(
      'input, select, textarea, button',
    )) {
      final name = input.attributes['name'];
      if (name == null) continue;

      // Try to match one of the override keys
      String? overrideValue;
      String? matchedKey;
      for (final key in remaining.keys) {
        if (name.contains(key)) {
          overrideValue = remaining[key];
          matchedKey = key;
          break;
        }
      }

      if (matchedKey != null) {
        data[name] = overrideValue!;
        remaining.remove(matchedKey);
      } else {
        data[name] = _defaultInputValue(input);
      }
    }

    if (remaining.isNotEmpty) {
      throw SmartschoolParsingError(
        'Form fields not found in HTML form: ${remaining.keys.toList()}',
      );
    }

    return data;
  }

  String _defaultInputValue(html_dom.Element input) {
    if (input.localName == 'select') {
      final selected = input.querySelector('option[selected]');
      if (selected != null) {
        return selected.attributes['value'] ?? selected.text.trim();
      }
      final first = input.querySelector('option');
      return first?.attributes['value'] ?? first?.text.trim() ?? '';
    }
    return input.attributes['value'] ?? '';
  }

  /// A raw POST that bypasses the auth interceptor (marked with `_noAuth`).
  ///
  /// Follows a `301`/`302` the way a browser does — with a GET of the
  /// `Location` — because `dart:io`'s `HttpClient` only auto-follows a redirect
  /// after a POST when it is a `303`. Smartschool answers a successful login
  /// form POST with `302 Location: /`, and without this the response handed
  /// back still has `realUri` on `/login`, which the auth chain reads as a
  /// failed login (#6).
  Future<Response<String>> _rawPost(
    String url,
    Object data, {
    String? contentType,
  }) async {
    final resolvedContentType =
        contentType ??
        (data is Map<String, dynamic>
            ? Headers.formUrlEncodedContentType
            : null);

    final response = await _dio.post<String>(
      url,
      data: data,
      options: Options(
        contentType: resolvedContentType,
        extra: {_noAuthKey: true},
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    return _followUnfollowedRedirect(response);
  }

  /// GETs the `Location` of a `301`/`302` that the HTTP client left unfollowed
  /// (it does that for every POST; see [_rawPost]). Anything else is returned
  /// untouched. Bounded by Dio's own `maxRedirects` on the GET.
  Future<Response<String>> _followUnfollowedRedirect(
    Response<String> response,
  ) async {
    const browserFollowsAsGet = {HttpStatus.movedPermanently, HttpStatus.found};
    if (!browserFollowsAsGet.contains(response.statusCode)) return response;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return response;
    return _rawGet(response.realUri.resolve(location).toString());
  }

  /// A raw GET that bypasses the auth interceptor.
  ///
  /// With [newSession], the request is sent without the session cookie
  /// ([_SmartschoolCookieManager.sessionCookie]), so that Smartschool starts
  /// a new session for it and sends its id with the answer (#45).
  Future<Response<String>> _rawGet(
    String url, {
    bool newSession = false,
  }) async {
    return _dio.get<String>(
      url,
      options: Options(
        extra: {
          _noAuthKey: true,
          if (newSession) _SmartschoolCookieManager.newSessionKey: true,
        },
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
  }

  static String get _noAuthKey => '_smartschool_noAuth';

  /// Describes [e] when it means Smartschool could not be reached (the request
  /// got no complete answer), or returns `null` for any other failure.
  ///
  /// `IOHttpClientAdapter` reports a DNS failure or refused connection as
  /// [DioExceptionType.connectionError] and a timeout as the matching timeout
  /// type; other socket, HTTP or TLS errors (a connection reset mid-request, a
  /// failed TLS handshake) pass through unconverted and reach us as
  /// [DioExceptionType.unknown].
  static String? _describeConnectionFailure(DioException e) {
    final error = e.error;
    final String failure;
    switch (e.type) {
      case DioExceptionType.connectionError:
        failure = 'the connection failed';
      case DioExceptionType.connectionTimeout:
        failure = 'the connection timed out';
      case DioExceptionType.sendTimeout:
        failure = 'sending the request timed out';
      case DioExceptionType.receiveTimeout:
        failure = 'waiting for the response timed out';
      case DioExceptionType.badCertificate:
        failure = 'the server certificate was rejected';
      case DioExceptionType.unknown
          when error is SocketException ||
              error is HttpException ||
              error is TlsException:
        failure = 'the connection failed';
      default:
        return null;
    }
    return error == null ? failure : '$failure ($error)';
  }

  static bool _isLikelyHtml(String body) {
    final lower = body.toLowerCase();
    return lower.startsWith('<!doctype html') || lower.startsWith('<html');
  }

  static String _preview(String body, {int max = 180}) {
    if (body.length <= max) return body;
    return '${body.substring(0, max)}...';
  }
}

// ---------------------------------------------------------------------------
// Download content
// ---------------------------------------------------------------------------

/// Hands the content of a download to its reader, as the `stream` of a
/// [SmartschoolDownload] (#41): counts the bytes against the `maxBytes` of
/// the download, turns a failure of the connection into the error the
/// client throws for it, and stops the transfer when the content is not
/// read to its end.
///
/// Dio subscribes to the body of a response as soon as its headers are in,
/// and keeps what comes in in memory until the body is listened to. So the
/// body is taken over as soon as the download has its answer, and held
/// until the reader listens: its subscription is paused, which pauses the
/// transfer (#81). What came in before then is no more than the chunks that
/// arrived while the client handled the headers, and every byte of the
/// content is counted against `maxBytes`, whenever the reader listens.
///
/// Dio also keeps reading a body to its end when the reader of a
/// `ResponseType.stream` body cancels its subscription; only cancelling the
/// request (its [CancelToken]) closes the connection. So the transfer is
/// stopped by cancelling the download's token: when the reader cancels its
/// subscription before the end, when more than `maxBytes` bytes came in,
/// on [cancel], and when the transfer fails.
class _DownloadContent {
  _DownloadContent(
    Stream<List<int>> source, {
    required CancelToken cancelToken,
    required int? maxBytes,
    required Object Function() tooLarge,
    required Object Function(Object error) failure,
    required Object Function() cancelled,
  }) : _cancelToken = cancelToken,
       _maxBytes = maxBytes,
       _tooLarge = tooLarge,
       _failure = failure,
       _cancelled = cancelled {
    // Held until the reader listens (see [_listen]).
    _subscription = source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    )..pause();
  }

  /// The token of the download's request, and of its retry after a login.
  final CancelToken _cancelToken;

  final int? _maxBytes;

  /// The error for content larger than [_maxBytes].
  final Object Function() _tooLarge;

  /// The error the reader gets for a failure of the transfer.
  final Object Function(Object error) _failure;

  /// The error the reader gets after [cancel].
  final Object Function() _cancelled;

  late final StreamController<List<int>> _reader = StreamController(
    onListen: _listen,
    onPause: () => _subscription.pause(),
    onResume: () => _subscription.resume(),
    onCancel: _readerCancelled,
  );

  /// The subscription to the body of the response, as Dio hands it on.
  late final StreamSubscription<List<int>> _subscription;
  int _received = 0;

  /// Whether the content ended: it was read to its end, the transfer failed
  /// or was stopped, or the reader cancelled.
  bool _finished = false;

  /// The content, for the reader.
  Stream<List<int>> get stream => _reader.stream;

  /// Stops the transfer; the reader gets the [_cancelled] error.
  void cancel() => _stop(_cancelled());

  void _listen() {
    // Cancelled before it was read: the error is waiting for the reader.
    if (_finished) return;
    // The transfer, held until now, goes on.
    _subscription.resume();
  }

  void _onData(List<int> chunk) {
    _received += chunk.length;
    final maxBytes = _maxBytes;
    if (maxBytes != null && _received > maxBytes) {
      _stop(_tooLarge());
      return;
    }
    _reader.add(chunk);
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (_finished) return;
    _finished = true;
    // Whatever is left of the connection is closed.
    _cancelToken.cancel();
    _reader
      ..addError(_failure(error), stackTrace)
      ..close();
  }

  void _onDone() {
    if (_finished) return;
    _finished = true;
    _reader.close();
  }

  /// Stops the transfer and ends the content with [error].
  void _stop(Object error) {
    if (_finished) return;
    _finished = true;
    _cancelToken.cancel();
    _subscription.cancel();
    _reader
      ..addError(error)
      ..close();
  }

  /// The reader cancelled its subscription (which it also does, done, at
  /// the end of the content).
  Future<void>? _readerCancelled() {
    if (_finished) return null;
    _finished = true;
    _cancelToken.cancel();
    return _subscription.cancel();
  }
}

// ---------------------------------------------------------------------------
// Cookie manager
// ---------------------------------------------------------------------------

/// A [CookieManager] that keeps the session a login runs in to the login
/// chain (#45).
///
/// It saves and loads cookies as [CookieManager] does, except that:
/// - it does not save the cookies of an answer that Smartschool refused the
///   session for (see [_SmartschoolAuthInterceptor.refusedSession]): such an
///   answer comes from a session the client is about to replace, and one
///   that comes in while a login runs, or after it, must not replace the
///   cookies of the new session. Smartschool sets a `pid` cookie on every
///   answer to a request without one, refused or not;
/// - it sends a request marked with [newSessionKey] without the session
///   cookie, so that Smartschool starts a new session for it;
/// - it stamps each request with the session its cookies were loaded in
///   (under [sessionKey]), so that a request can be kept to the session of
///   an earlier answer (#38).
class _SmartschoolCookieManager extends CookieManager {
  _SmartschoolCookieManager(super.cookieJar, this._refused, this._session);

  /// The name of Smartschool's session cookie, the PHP session that holds
  /// the login state and the CSRF token of the login form.
  static const sessionCookie = 'PHPSESSID';

  /// The request `extra` that sends a request without [sessionCookie].
  static const newSessionKey = '_smartschool_newSession';

  /// The request `extra` that holds the session the request's cookies were
  /// loaded in: [_SmartschoolAuthInterceptor.settledSession] when it was the
  /// same before and after they were loaded, `null` when a login ran or
  /// started meanwhile. Two requests with the same (non-null) stamp carried
  /// the same session (#38).
  static const sessionKey = '_smartschool_cookieSession';

  /// Whether Smartschool refused the session for the request of a response.
  final bool Function(Response<dynamic> response) _refused;

  /// The session the cookie jar holds now, as
  /// [_SmartschoolAuthInterceptor.settledSession] tells it.
  final int? Function() _session;

  @override
  Future<String> loadCookies(RequestOptions options) async {
    final before = _session();
    final cookies = await _loadCookies(options);
    options.extra[sessionKey] = before == _session() ? before : null;
    return cookies;
  }

  Future<String> _loadCookies(RequestOptions options) async {
    if (options.extra[newSessionKey] != true) {
      return super.loadCookies(options);
    }
    final saved = await cookieJar.loadForRequest(options.uri);
    return CookieManager.getCookies([
      for (final cookie in saved)
        if (cookie.name != sessionCookie) cookie,
    ]);
  }

  @override
  Future<void> saveCookies(Response<dynamic> response) async {
    if (_refused(response)) return;
    await super.saveCookies(response);
  }
}

// ---------------------------------------------------------------------------
// Auth interceptor
// ---------------------------------------------------------------------------

/// The session of an earlier answer that a request goes out in only (see
/// `sameSessionAs` of [SmartschoolClient.postMultipartResponse], #38).
class _SameSession {
  const _SameSession(this.session, this.answer);

  /// The session of the request of [response], as the cookie manager stamped
  /// it ([_SmartschoolCookieManager.sessionKey]).
  factory _SameSession.of(Response<dynamic> response) {
    final options = response.requestOptions;
    final session = options.extra[_SmartschoolCookieManager.sessionKey];
    return _SameSession(
      session is int ? session : null,
      '${options.method} ${options.uri}',
    );
  }

  /// The session the answer's request carried its cookies in, or `null` when
  /// that is not known (a login ran while they were loaded, or it is not an
  /// answer of this client): then no request goes out in it.
  final int? session;

  /// The answer's request, as `METHOD url`, for the error message.
  final String answer;
}

/// Logs in before a request is sent when Smartschool refused the session the
/// client holds, and no login replaced it since (#134; see
/// [_SmartschoolAuthInterceptor.logInBeforeSending]).
///
/// It is the first interceptor of the client, before
/// [_SmartschoolCookieManager]: the cookies of a request are loaded after
/// that login, so the request carries the new session.
class _SmartschoolLogInFirstInterceptor extends Interceptor {
  _SmartschoolLogInFirstInterceptor(this._auth);

  final _SmartschoolAuthInterceptor _auth;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) => _auth.logInBeforeSending(options, handler);
}

/// Intercepts Dio responses that show the session is not (or no longer)
/// authenticated, drives the authentication flow transparently, then retries
/// the original request once.
///
/// Smartschool signals an unauthenticated session in three ways:
/// - a page request (GET) is redirected to the login chain (`/login`, `/2fa`,
///   `/account-verification`), so the response lands on an auth page;
/// - an XHR or form POST (the XML dispatcher, for instance) is answered with a
///   bare `401` and an empty body (#8). The chain is then started by fetching
///   `/login`;
/// - a POST sent without `X-Requested-With` (a multipart or JSON POST) is
///   answered with `302 Location: /login` and a "Redirecting to /login" page,
///   a redirect the HTTP client does not follow after a POST (#22). The chain
///   is then started by fetching the `Location`, as a browser would.
///
/// A retry that Smartschool refuses again, in any of these ways, is not
/// retried again: it fails with a [SmartschoolSessionExpiredError] (#22), so
/// the caller never gets a login page in place of the data.
///
/// The answer to a download comes as a stream, which Dio hands on before
/// its body is read (#41). A refused one is read here: it is a page of the
/// login chain (or an empty `401`), which the login may go on from, and not
/// the file. A retry that is refused again is read to its end and dropped.
///
/// A request sent with `retryAfterLogin: false` (see
/// [SmartschoolClient.postMultipartResponse]) carries state of the session it
/// was prepared in, such as the tokens of the compose form, so it is not
/// retried in a new session: when refused, it fails with a
/// [SmartschoolSessionExpiredError] at once, without a login (#25), also
/// while a login runs (#36).
///
/// The client does remember that Smartschool refused the session it holds
/// (#134): after a refused request for which no login completed since (one
/// sent with `retryAfterLogin: false`, or one whose login failed or was not
/// tried), the next request logs in before it is sent, or waits for the
/// login that runs, and then goes out once in the new session (see
/// [logInBeforeSending]). Otherwise a caller that tries such a write again
/// would send it in the refused session again, where it can only be refused
/// again without a login. That login counts toward [_maxLoginAttempts] as
/// any other, and is held back by it in the same way: at the limit, the
/// request goes out as it is. A request sent after such a login that
/// Smartschool refuses all the same fails as a refused retry does, without
/// another login: one request never costs two logins. A retry that
/// Smartschool refuses does not mark the session: the login it followed
/// replaced the session, which Smartschool did not take, and the next
/// request is sent, refused, and logs in as before.
///
/// The client does not keep logging in when that does not help: after
/// [_maxLoginAttempts] logins in a row that did not get Smartschool to accept
/// the session (the login failed, or the retry was refused again), a refused
/// request fails with a [SmartschoolSessionExpiredError] without logging in.
/// Every way of refusing counts the same, and only an answer that Smartschool
/// did not refuse, to a request or to its retry, clears the count (#31).
///
/// So that a long-lived client does not stay stuck there (#32), a refused
/// request logs in once more when [_loginCooldown] has passed since the last
/// login started (half-open): an accepted retry clears the count, and any
/// failure makes the next login wait another cooldown. Not when Smartschool
/// rejected the credentials at the last login: trying them again every
/// cooldown could get the account locked, so that waits for [reset]
/// ([SmartschoolClient.resetLoginAttempts]) or a new client.
///
/// Requests on one client share a login (#36): a request that Smartschool
/// refuses while a login runs does not start one of its own, but waits for
/// that login and is then retried once in its session, and when that login
/// fails, it fails with the same error. A request that went out before a
/// login completed and is refused after it is retried in the new session
/// without logging in again. So concurrent requests that find the session
/// expired send the password (and the one-time 2FA code) once, and the login
/// counts once toward [_maxLoginAttempts]. The login chain's own requests and
/// the retries never wait for a login, so a login cannot wait for itself.
///
/// A login that starts at the login form loads that form itself, in a new
/// session, instead of using the page of the refused request (#45). The
/// form's CSRF token is stored in the PHP session, and Smartschool keeps a
/// session id it does not know as a new, empty session, which it does not
/// lock: concurrent requests on an expired session each render the login
/// page in that one session, each store a token of their own there, and the
/// last one stored wins, so the page the login got first could post a token
/// that Smartschool no longer holds, which it answers like a wrong password.
/// No other request carries the new session, and [_SmartschoolCookieManager]
/// keeps the cookies of refused answers out of the jar, so the password POST
/// always goes out in the session of the token it posts.
///
/// A request sent with `sameSessionAs` (see
/// [SmartschoolClient.postMultipartResponse]) carries state of the session
/// of an earlier answer, such as the compose form's tokens, and goes out only
/// in that session (#38). A login replaces the session in the cookie jar,
/// whichever request it runs for, and Smartschool would accept such a
/// request in the new session, stale state and all. So when a login started
/// since the answer's request went out, or runs, the request is not sent:
/// it fails at once with a [SmartschoolSessionExpiredError]. The sessions of
/// the two requests are told apart by the stamp of
/// [_SmartschoolCookieManager.sessionKey], not by [_sessionGeneration]: the
/// login replaces the session cookie with the one of its login form before
/// it completes, and a login that fails after Smartschool accepted it (the
/// connection dropped on the answer to the 2FA code) leaves an authenticated
/// new session in the jar without completing.
///
/// This replaces Python's `Smartschool.request()` override which called
/// `_handle_auth_redirect()` and then re-issued the original call using
/// `super().request()`.
class _SmartschoolAuthInterceptor extends Interceptor {
  final SmartschoolClient _client;

  /// How long the client waits, once it reached [_maxLoginAttempts], before
  /// it starts one login again (#32).
  final Duration _loginCooldown;

  /// Tells the time for [_loginCooldown].
  final DateTime Function() _clock;

  /// The logins started since Smartschool last accepted the session for a
  /// request, whatever way it refused the session (#31).
  int _loginAttempts = 0;
  static const _maxLoginAttempts = 3;
  static const _noAuthKey = '_smartschool_noAuth';
  static const _retryKey = '_smartschool_retry';

  /// Marks a request that is not retried after logging in again (see
  /// [SmartschoolClient.postMultipartResponse]).
  static const _noRetryKey = '_smartschool_noRetry';

  /// Holds the [_SameSession] of a request that goes out only in the
  /// session of an earlier answer (`sameSessionAs`, #38).
  static const _sameSessionKey = '_smartschool_sameSession';

  /// Marks a request that the client logged in for before sending it
  /// ([logInBeforeSending], #134): it went out in a new session already, so,
  /// like a retry, it is not retried after another login when Smartschool
  /// refuses it.
  static const _loggedInFirstKey = '_smartschool_loggedInFirst';

  /// When the last login started; `null` when none did since the count was
  /// last cleared. The cooldown runs from here, not from when the login
  /// ended.
  DateTime? _lastLoginAt;

  /// The failure of the last login when Smartschool rejected the credentials
  /// at it (see [_rejectsCredentials]), `null` otherwise.
  SmartschoolAuthenticationError? _rejectedCredentials;

  /// The login that is running, which every request that Smartschool refuses
  /// meanwhile waits for (#36); `null` when none is.
  Future<void>? _login;

  /// How many logins completed on this client: each one got it a new
  /// session. Every request is stamped with it when it is sent (under
  /// [_sessionKey]), so a request that Smartschool refuses can tell whether a
  /// login completed since it went out, in which case it carried the session
  /// from before that login and is retried in the new one without logging in
  /// again (#36). It only grows, and it grows before the requests that waited
  /// for that login are retried. It does not tell whether two requests
  /// carried the same session (see [settledSession] for that, #38): a login
  /// replaces the session cookie before it completes, and may have when it
  /// fails.
  int _sessionGeneration = 0;

  /// The request `extra` that holds the [_sessionGeneration] the request was
  /// sent in.
  static const _sessionKey = '_smartschool_session';

  /// The [_sessionGeneration] in which Smartschool last refused the session
  /// for a regular request (not one of the login chain, nor a retry), or
  /// `null` when it never did (#134).
  ///
  /// While it equals [_sessionGeneration], no login completed since that
  /// refusal: the cookie jar still holds the refused session (or the one of
  /// a login that failed), and a request logs in before it is sent (see
  /// [logInBeforeSending]). A completed login moves [_sessionGeneration] on,
  /// which ends that. An answer that Smartschool accepts does not: it may be
  /// to a request that went out before the refusal.
  int? _refusedGeneration;

  /// How many logins started on this client, whether they completed, failed
  /// or still run (#38).
  int _loginsStarted = 0;

  /// The session the cookie jar holds now, as a number that changes
  /// whenever a login may have replaced it, or `null` while a login runs.
  ///
  /// Only a login puts another session cookie in the jar: it loads its login
  /// form in a new session (#45), Smartschool may move the session to a new
  /// id when it accepts the password, and the answers that Smartschool
  /// refused are kept out of the jar. So the number of logins started tells
  /// the sessions apart when no login runs: the jar held the same session at
  /// two moments that give the same number, and possibly another one at two
  /// moments that do not (#38).
  int? get settledSession => _login == null ? _loginsStarted : null;

  _SmartschoolAuthInterceptor(
    this._client, {
    required Duration loginCooldown,
    required DateTime Function() clock,
  }) : _loginCooldown = loginCooldown,
       _clock = clock;

  /// Clears the login count: the next refused request logs in again, and
  /// [_maxLoginAttempts] logins in a row are allowed again.
  void reset() {
    _loginAttempts = 0;
    _lastLoginAt = null;
    _rejectedCredentials = null;
  }

  /// Logs in before [options] is sent when Smartschool refused the session
  /// the client holds and no login completed since ([_refusedGeneration]),
  /// then hands [options] on; called by [_SmartschoolLogInFirstInterceptor],
  /// before the cookies are loaded (#134).
  ///
  /// It waits for the login that runs, if any, and otherwise starts one
  /// (shared as in [_renewSession], #36). When that login fails, the request
  /// is not sent: it fails with what the login failed with, as a refused
  /// request does. When it completes, the request goes out once in the new
  /// session; when Smartschool refuses it there too, it fails as a refused
  /// retry does, without another login (see [_loggedInFirstKey]), so one
  /// request never costs two logins. At [_maxLoginAttempts] (see
  /// [_whyNotLogIn]), it does not log in, and the request goes out as it is:
  /// Smartschool's answer is then handled as before.
  ///
  /// Neither the requests of the login chain nor the retries wait for a login
  /// here, so a login cannot wait for itself. Nor does a request that goes
  /// out only in the session of an earlier answer (`sameSessionAs`, #38): a
  /// login would only keep it from being sent (see [onRequest]), and when a
  /// login runs, it fails at once, as before.
  Future<void> logInBeforeSending(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final extra = options.extra;
    final logsIn =
        extra[_noAuthKey] != true &&
        extra[_retryKey] != true &&
        extra[_sameSessionKey] == null &&
        _refusedGeneration == _sessionGeneration;
    if (logsIn) {
      try {
        final running = _login;
        if (running != null) {
          await running;
          extra[_loggedInFirstKey] = true;
        } else if (_whyNotLogIn() == null) {
          await _startLogin(null, null);
          extra[_loggedInFirstKey] = true;
        }
      } on DioException catch (e) {
        handler.reject(e, true);
        return;
      } on Object catch (e, stackTrace) {
        handler.reject(
          DioException(
            requestOptions: options,
            error: e,
            stackTrace: stackTrace,
          ),
          true,
        );
        return;
      }
    }
    handler.next(options);
  }

  /// Notes that Smartschool refused the session that the request of
  /// [options] went out in (#134). When no login completed since, that is
  /// the session the jar holds: the next request logs in before it is sent
  /// (see [logInBeforeSending]), unless a login completes first. A request
  /// that went out before a login that completed since says nothing about
  /// the new session.
  void _noteRefused(RequestOptions options) {
    final sentIn = options.extra[_sessionKey];
    if (sentIn is int && sentIn == _sessionGeneration) {
      _refusedGeneration = sentIn;
    }
  }

  /// Stamps [options] with the session the request goes out in (#36), and
  /// does not send a request that must go out in the session of an earlier
  /// answer when its cookies were not loaded in that session (#38).
  ///
  /// [CookieManager] runs before this interceptor and has put the cookies on
  /// the request by now, so the stamp is never older than the session the
  /// request carries: a request that it says went out before a login did.
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_sessionKey] = _sessionGeneration;
    final same = options.extra[_sameSessionKey];
    if (same is _SameSession) {
      final loadedIn = options.extra[_SmartschoolCookieManager.sessionKey];
      if (same.session == null || loadedIn != same.session) {
        final why = same.session == null
            ? 'the client was logging in when that request went out, or it '
                  'is not a request of this client'
            : 'the client has logged in again since that request went out, '
                  'or is logging in (for another request)';
        handler.reject(
          DioException(
            requestOptions: options,
            error: SmartschoolSessionExpiredError(
              '${options.method} ${options.uri} was not sent: it carries '
              'state of the session that ${same.answer} was answered in, and '
              '$why',
            ),
          ),
          true,
        );
        return;
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    // Do not intercept requests we marked as part of the auth flow, or
    // retries. Neither touches the login count: an answer of the login chain
    // does not say whether Smartschool accepts the session for a request (a
    // login without 2FA lands on `/`), and a retry is judged below, where it
    // is made (#31).
    final extra = response.requestOptions.extra;
    if (extra[_noAuthKey] == true || extra[_retryKey] == true) {
      handler.next(response);
      return;
    }

    final loginChain = _loginChainTarget(response);
    if (loginChain == null && !_isUnauthorized(response)) {
      reset();
      handler.next(response);
      return;
    }

    final request =
        '${response.requestOptions.method} ${response.requestOptions.uri}';

    _noteRefused(response.requestOptions);

    // The answer to a download comes as a stream (#41). Refused, it is not
    // the file but a page of the login chain (or an empty 401): read it here,
    // so that the login can go on from it (an `/account-verification` page is
    // filled in) and it never reaches the caller as the file.
    await _readStreamedBody(response);

    // A request that carries state of the session it was prepared in (the
    // tokens of the compose form) is not retried in the new session, where
    // that state is stale: a retried message submit would send the message
    // with the compose state of the refused session (its recipients and
    // attachments), and what Smartschool makes of that was never checked.
    // Smartschool refused it before handling it, so it fails as not carried
    // out, without a login (#25). Nor does it wait for a login that is
    // running (#36). The same holds for a request that must go out once only,
    // such as one that creates something (Skore's saveOwner, #71; the
    // planner's fill of a slot, #87). The session is marked as refused
    // above, so the next request, whatever it is, logs in before it is sent
    // (#134): trying the write again sends it once, in a new session.
    if (extra[_noRetryKey] == true) {
      final notLoggingIn = _whyNotLogIn();
      final next = notLoggingIn == null
          ? 'The client logs in before its next request, so it can be tried '
                'again'
          : 'The client does not log in before its next request: its last '
                '$_maxLoginAttempts logins in a row did not get the session '
                'accepted$notLoggingIn';
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: SmartschoolSessionExpiredError(
            'Smartschool did not accept the session for $request. It is not '
            'retried after logging in again, because it carries state of the '
            'refused session or must not be sent twice; it was not carried '
            'out. $next',
          ),
        ),
        true,
      );
      return;
    }

    // The client logged in for the request before sending it (#134): it
    // went out in a new session already, and Smartschool refused that one
    // too. Like a refused retry, it fails without another login.
    if (extra[_loggedInFirstKey] == true) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: SmartschoolSessionExpiredError(
            'Smartschool still refused the session for $request after '
            'logging in again before it was sent',
          ),
        ),
        true,
      );
      return;
    }

    try {
      await _renewSession(response, loginChain, request);

      // Re-issue the original request now that we are authenticated
      final data = response.requestOptions.data;
      final originalOptions = response.requestOptions.copyWith(
        extra: {...response.requestOptions.extra, _retryKey: true},
        // A FormData body is consumed by sending it: a multipart POST is
        // retried with a copy (#22).
        data: data is FormData ? data.clone() : data,
      );
      // The copied headers include the `Cookie` header CookieManager put on
      // the original request, with the session id that was just refused.
      // CookieManager would merge it with the jar and list it first, so
      // Smartschool would read the stale session again (#9). Drop it: the
      // retry gets its cookies from the jar, which holds the new session.
      originalOptions.headers.remove(HttpHeaders.cookieHeader);
      final retried = await _client._dio.fetch<dynamic>(originalOptions);
      if (_isUnauthorized(retried)) {
        _discardStreamedBody(retried);
        throw SmartschoolSessionExpiredError(
          'Smartschool still answered 401 to $request after logging in again',
        );
      }
      // Only one retry: a retry that lands on the login chain again (or is
      // redirected there) is not the data, and logging in once more would
      // not help either (#22).
      final stillOnLoginChain = _loginChainTarget(retried);
      if (stillOnLoginChain != null) {
        _discardStreamedBody(retried);
        throw SmartschoolSessionExpiredError(
          'Smartschool still answered $request with its login chain '
          '(${stillOnLoginChain.path}) after logging in again',
        );
      }
      reset();
      handler.resolve(retried);
    } on SmartschoolAuthenticationError catch (e) {
      handler.reject(
        DioException(requestOptions: response.requestOptions, error: e),
        true,
      );
    }
  }

  /// Gets the client a new session to retry the request of [response] in,
  /// which Smartschool refused ([request] names it): the login that is
  /// running, a login that completed since the request went out, or a new
  /// login (#36).
  ///
  /// Only a new login counts toward [_maxLoginAttempts], and only it is held
  /// back by the limit: waiting for a running login or retrying after one
  /// that completed does not log in. When the client does not log in, this
  /// throws a [SmartschoolSessionExpiredError]; when the login fails, it
  /// throws what the login failed with, the same error for every request
  /// that waited for it.
  Future<void> _renewSession(
    Response<dynamic> response,
    Uri? loginChain,
    String request,
  ) async {
    final running = _login;
    if (running != null) return running;

    final sentIn = response.requestOptions.extra[_sessionKey];
    if (sentIn is int && sentIn != _sessionGeneration) return;

    final notLoggingIn = _whyNotLogIn();
    if (notLoggingIn != null) {
      throw SmartschoolSessionExpiredError(
        'Smartschool did not accept the session for $request, and the '
        'client did not log in again: its last $_maxLoginAttempts logins '
        'in a row did not get the session accepted$notLoggingIn',
      );
    }

    return _startLogin(response, loginChain);
  }

  /// Starts a login (see [_logIn]) that every request refused meanwhile, or
  /// about to be sent in the refused session, waits for (#36, #134).
  Future<void> _startLogin(Response<dynamic>? response, Uri? loginChain) {
    // Set before the login sends anything, so a request that Smartschool
    // refuses from now on waits for it; cleared before the requests that
    // waited for it resume.
    final login = _logIn(response, loginChain).whenComplete(() {
      _login = null;
    });
    _login = login;
    return login;
  }

  /// Runs the login chain for the refused [response], from the page of the
  /// login chain it landed on, or else [loginChain], or else `/login` (a
  /// `401` does not say where the chain starts). Without a [response] (a
  /// login before a request is sent, #134), it starts at `/login`.
  ///
  /// When that is the login form, the login loads it itself, in a new
  /// session, so that the CSRF token it posts is the one stored in the
  /// session it posts it in (#45). A `/2fa` or `/account-verification` page
  /// continues the session that got past the password: the chain starts
  /// from the refused page, or from a GET of [loginChain].
  ///
  /// Counts the login toward [_maxLoginAttempts] and in [_loginsStarted]
  /// and, when it completes, moves the client to the next
  /// [_sessionGeneration].
  ///
  /// A login that would post the password first checks that the credentials'
  /// `mfa` can answer a step after it (#79): when it cannot, it throws the
  /// [SmartschoolInvalidTotpSecretError] before it sends anything, so it is
  /// not counted.
  Future<void> _logIn(Response<dynamic>? response, Uri? loginChain) async {
    final realUri = response?.realUri;
    final landedOnChain = realUri != null && _client.isAuthUri(realUri);
    final start = landedOnChain ? realUri : loginChain;
    final fromLoginForm = start == null || start.path.endsWith('/login');
    if (fromLoginForm) _client._checkMfaBeforeLogin();

    _loginsStarted++;
    _loginAttempts++;
    _lastLoginAt = _clock();
    _rejectedCredentials = null;

    try {
      if (fromLoginForm) {
        final loginPage = await _client._rawGet(
          start?.toString() ?? '/login',
          newSession: true,
        );
        await _driveAuthChain(loginPage.realUri, loginPage);
      } else if (landedOnChain) {
        // Redirected onto the login chain: the response is its page.
        await _driveAuthChain(realUri, response!);
      } else {
        // A redirect the HTTP client left unfollowed only points at the
        // page: open it ourselves.
        final page = await _client._rawGet(start.toString());
        await _driveAuthChain(page.realUri, page);
      }
    } on SmartschoolAuthenticationError catch (e) {
      if (_rejectsCredentials(e)) _rejectedCredentials = e;
      rethrow;
    }
    _sessionGeneration++;
  }

  /// Why the client does not log in for a refused request now, as the end of
  /// the [SmartschoolSessionExpiredError] message, or `null` when it does.
  ///
  /// Below [_maxLoginAttempts] logins in a row it does. At the limit it does
  /// once [_loginCooldown] has passed since the last login started (#32); a
  /// clock that was set back since then does not hold it for the size of the
  /// jump. It does not when Smartschool rejected the credentials at the last
  /// login: that waits for [reset].
  String? _whyNotLogIn() {
    if (_loginAttempts < _maxLoginAttempts) return null;
    final rejected = _rejectedCredentials;
    if (rejected != null) {
      return ', and Smartschool rejected the credentials at the last one '
          '(${rejected.runtimeType}). It does not log in again on its own '
          'until resetLoginAttempts() is called';
    }
    final last = _lastLoginAt!;
    final next = last.add(_loginCooldown);
    final now = _clock();
    if (!now.isBefore(next) || now.isBefore(last)) return null;
    return '. It tries one login again from ${next.toIso8601String()} on';
  }

  /// Whether [e] says that the credentials do not get past the login chain:
  /// Smartschool rejected the password, the 2FA code or the account
  /// verification answer, or asked for a 2FA code or verification answer they
  /// do not hold (#11), or a 2FA code while their TOTP secret is not one
  /// (#79). Logging in with them again does not help, and every rejected
  /// attempt brings the account closer to being locked (#32).
  static bool _rejectsCredentials(SmartschoolAuthenticationError e) =>
      e is SmartschoolInvalidCredentialsError ||
      e is SmartschoolTwoFactorRequiredError ||
      e is SmartschoolTwoFactorRejectedError ||
      e is SmartschoolInvalidTotpSecretError ||
      e is SmartschoolUnsupportedTwoFactorMethodError ||
      e is SmartschoolAccountVerificationRequiredError ||
      e is SmartschoolAccountVerificationRejectedError;

  /// Whether Smartschool refused the session for the request of [response]:
  /// a regular request (or a retry) that it answered with `401` or with its
  /// login chain, the answers that make this interceptor log in (#45). An
  /// answer to a request of the login chain itself is not refused.
  bool refusedSession(Response<dynamic> response) =>
      response.requestOptions.extra[_noAuthKey] != true &&
      (_isUnauthorized(response) || _loginChainTarget(response) != null);

  /// Whether [response] is Smartschool's answer to an XHR/form POST on an
  /// expired session: `401 Unauthorized` (with an empty body), not a redirect
  /// to the login chain.
  static bool _isUnauthorized(Response<dynamic> response) =>
      response.statusCode == HttpStatus.unauthorized;

  /// The page of the login chain (`/login`, `/2fa`, `/account-verification`)
  /// that [response] comes from or redirects to, or `null` when it is not an
  /// answer of the login chain.
  ///
  /// The HTTP client follows a redirect after a GET itself, so the final URL
  /// (`realUri`) is on the login chain. It does not follow one after a POST
  /// (only a `303`): Smartschool answers a POST sent without
  /// `X-Requested-With` on an expired session with `302 Location: /login`, so
  /// the response keeps the requested URL and only its `Location` points at
  /// the login chain (#22).
  Uri? _loginChainTarget(Response<dynamic> response) {
    final realUri = response.realUri;
    if (_client.isAuthUri(realUri)) return realUri;

    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    final target = realUri.resolve(location);
    return _client.isAuthUri(target) ? target : null;
  }

  Future<void> _driveAuthChain(Uri uri, Response<dynamic> response) async {
    final path = uri.path;
    final htmlBody = _bodyAsString(response);
    final url = uri.toString();

    Response<String>? nextResponse;

    if (path.endsWith('/login')) {
      nextResponse = await _client.doLogin(htmlBody, url);
    }

    if (path.endsWith(kAccountVerificationPath) ||
        (nextResponse?.realUri.path.endsWith(kAccountVerificationPath) ??
            false)) {
      final body = nextResponse != null ? (nextResponse.data ?? '') : htmlBody;
      final verUrl = nextResponse?.realUri.toString() ?? url;
      nextResponse = await _client.doAccountVerification(body, verUrl);
    }

    if (path.endsWith('/2fa') ||
        (nextResponse?.realUri.path.endsWith('/2fa') ?? false)) {
      final twoFaResponse = await _client.do2fa();

      // do2fa() POSTs to /2fa/api/v1/google-authenticator, which answers with
      // HTTP 200 and a JSON body on BOTH success and failure — the URL alone
      // (whose path contains '/2fa/') cannot tell them apart. Decide from the
      // response body instead of misclassifying the API endpoint as "still on
      // the 2FA page".
      final success = _client.parse2faSuccess(twoFaResponse);
      if (success == true) {
        // 2FA accepted. The session cookie has already been persisted by the
        // CookieManager, so the interceptor can retry the original request.
        return;
      }
      if (success == false) {
        throw const SmartschoolTwoFactorRejectedError();
      }
      // Unrecognised response shape — fall through to the URL-based checks
      // below (e.g. genuinely still on the HTML /2fa page).
      nextResponse = twoFaResponse;
    }

    final finalUri = nextResponse?.realUri ?? uri;
    if (_client.isAuthUri(finalUri)) {
      if (finalUri.path.endsWith('/login')) {
        throw const SmartschoolInvalidCredentialsError();
      }
      if (finalUri.path.endsWith(kAccountVerificationPath)) {
        throw const SmartschoolAccountVerificationRejectedError();
      }
      if (finalUri.path.endsWith('/2fa') || finalUri.path.contains('/2fa/')) {
        throw const SmartschoolTwoFactorRejectedError();
      }

      throw SmartschoolAuthenticationError(
        'Authentication flow did not complete. Still on ${finalUri.path}',
      );
    }
  }

  /// Replaces the body of [response] with its text when it comes as a
  /// stream (the answer to a download, #41), reading it to its end; leaves
  /// any other body alone.
  static Future<void> _readStreamedBody(Response<dynamic> response) async {
    final data = response.data;
    if (data is! ResponseBody) return;
    response.data = await const Utf8Decoder(
      allowMalformed: true,
    ).bind(data.stream).join();
  }

  /// Reads the body of [response] to its end and drops it when it comes as a
  /// stream (the answer to a download, #41), so that its connection is
  /// released; the response is not handed on.
  static void _discardStreamedBody(Response<dynamic> response) {
    final data = response.data;
    if (data is! ResponseBody) return;
    unawaited(data.stream.drain<void>().then((_) {}, onError: (_) {}));
  }

  String _bodyAsString(Response<dynamic> response) {
    final data = response.data;
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data);
    return data.toString();
  }
}
