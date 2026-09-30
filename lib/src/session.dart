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

import 'credentials.dart';
import 'exceptions.dart';
import 'models/notification_models.dart';
import 'models/user_models.dart';
import 'xml_interface.dart';

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

  /// The default `loginCooldown` of [create]: how long a client that stopped
  /// logging in on its own waits before it tries one login again.
  static const Duration defaultLoginCooldown = Duration(minutes: 5);

  SmartschoolClient._({
    required this.credentials,
    required Dio dio,
    required PersistCookieJar cookieJar,
  }) : _dio = dio,
       _cookieJar = cookieJar;

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

    final cachePath = cacheDir ?? _defaultCachePath(credentials.username);
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
      dio: dio,
      cookieJar: cookieJar,
    );

    client._auth = _SmartschoolAuthInterceptor(
      client,
      loginCooldown: loginCooldown,
      clock: clock,
    );

    // Cookie manager must be added before auth interceptor so cookies are
    // available on each retry request.
    dio.interceptors
      ..add(CookieManager(cookieJar))
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
  // (#21).
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

  /// Executes the Smartschool XML command protocol.
  ///
  /// Builds the `<request>` XML, POSTs it to the dispatcher URL, parses the
  /// response and returns each matched element as a [Map<String, dynamic>].
  Future<List<Map<String, dynamic>>> postXml({
    required String url,
    required String subsystem,
    required String action,
    required Map<String, String> params,
    required String xpath,
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

    final body = resp.data ?? '';
    final trimmed = body.trimLeft();

    if (_isLikelyHtml(trimmed)) {
      throw SmartschoolAuthenticationError(
        'Smartschool returned HTML instead of XML for "$action". '
        'Login may have failed or expired. Response URL: ${resp.realUri}',
      );
    }

    if (!trimmed.startsWith('<')) {
      throw SmartschoolParsingError(
        'Smartschool returned a non-XML response for "$action" '
        '(url: ${resp.realUri}): ${_preview(trimmed)}',
      );
    }

    return XmlInterface.parseResponse(body, xpath);
  }

  /// Downloads raw bytes from [path].
  Future<Uint8List> download(String path) async {
    final resp = await _send(
      () => _dio.get<List<int>>(
        path,
        options: Options(responseType: ResponseType.bytes),
      ),
    );
    if ((resp.statusCode ?? 0) != 200) {
      throw SmartschoolDownloadError(
        'Download failed: $path',
        resp.statusCode ?? 0,
      );
    }
    return Uint8List.fromList(resp.data!);
  }

  /// Performs an authenticated GET and returns the raw response body string.
  ///
  /// Unlike [getJson], this method does **not** attempt to JSON-decode the
  /// response — it is used when the expected response is HTML or plain text
  /// (e.g. the message compose form page).
  Future<String> getRaw(String path, {Map<String, dynamic>? query}) async {
    final resp = await _send(
      () => _dio.get<String>(path, queryParameters: query),
    );
    return resp.data ?? '';
  }

  /// Performs an authenticated `application/x-www-form-urlencoded` POST and
  /// returns the raw response body string.
  ///
  /// Used for Smartschool operations that submit legacy HTML forms (such as
  /// recipient search) whose responses are XML or plain text instead of JSON.
  ///
  /// [retryAfterLogin]: see [postMultipartResponse].
  Future<String> postFormRaw(
    String path,
    Map<String, String> fields, {
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
  }) async {
    final resp = await postFormResponse(
      path,
      fields,
      query: query,
      retryAfterLogin: retryAfterLogin,
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
  /// [retryAfterLogin]: see [postMultipartResponse].
  Future<Response<String>> postFormResponse(
    String path,
    Map<String, String> fields, {
    Map<String, dynamic>? query,
    bool retryAfterLogin = true,
  }) {
    return _send(
      () => _dio.post<String>(
        path,
        data: fields,
        queryParameters: query,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {kXRequestedWith: 'XMLHttpRequest'},
          extra: _retryExtra(retryAfterLogin),
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
  /// [retryAfterLogin]: see [postMultipartResponse].
  Future<String> postMultipartRaw(
    String path,
    FormData formData, {
    bool retryAfterLogin = true,
  }) async {
    final resp = await postMultipartResponse(
      path,
      formData,
      retryAfterLogin: retryAfterLogin,
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
  /// [SmartschoolSessionExpiredError], and the next request that Smartschool
  /// refuses logs in (#25).
  Future<Response<String>> postMultipartResponse(
    String path,
    FormData formData, {
    bool retryAfterLogin = true,
  }) {
    return _send(
      () => _dio.post<String>(
        path,
        data: formData,
        options: Options(extra: _retryExtra(retryAfterLogin)),
      ),
    );
  }

  /// The request `extra` that keeps the auth interceptor from retrying a
  /// request in a new session, or `null` when it may.
  static Map<String, dynamic>? _retryExtra(bool retryAfterLogin) =>
      retryAfterLogin ? null : {_SmartschoolAuthInterceptor._noRetryKey: true};

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
  Future<Map<String, dynamic>> get authenticatedUser async {
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
  /// Lazily fetched and cached after the first call.
  Future<int> get platformId async {
    _platformId ??= await _fetchPlatformId();
    return _platformId!;
  }

  /// Forces a lightweight authenticated request and throws if session is invalid.
  ///
  /// A login failure is thrown as the matching [SmartschoolAuthenticationError]
  /// subclass (e.g. [SmartschoolInvalidCredentialsError]), as every request
  /// helper throws it.
  ///
  /// When Smartschool cannot be reached (the host does not resolve, the
  /// connection fails or times out), a [SmartschoolConnectionError] is thrown
  /// instead, with the `DioException` as its `cause`, as every request helper
  /// throws it: a network problem is not reported as a failed login.
  Future<void> ensureAuthenticated() async {
    try {
      await platformId;
    } on DioException catch (e) {
      throw SmartschoolAuthenticationError(
        'Unable to validate Smartschool session: ${e.message ?? e.toString()}',
      );
    } on SmartschoolException {
      rethrow;
    } catch (e) {
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
  /// Returns `false` when [moduleName] is empty, otherwise `true`.
  bool emitNotificationCounterUpdate({
    required String moduleName,
    required int counter,
    bool isNew = false,
    String source = 'unknown',
    DateTime? timestamp,
  }) {
    if (moduleName.trim().isEmpty) return false;

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

  /// Releases long-lived client resources.
  ///
  /// This is optional for short-lived scripts but recommended for daemon-like
  /// usage that keeps a [SmartschoolClient] alive for longer periods.
  Future<void> dispose({bool force = true}) async {
    _dio.close(force: force);
    if (!_notificationCounterController.isClosed) {
      await _notificationCounterController.close();
    }
  }

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
    final dateLike = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(mfa.trim());
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

  /// Handles the `/2fa` page: generates a TOTP code and POSTs it.
  Future<Response<String>> do2fa() async {
    final mfa = credentials.mfa;
    if (mfa == null || mfa.trim().isEmpty) {
      throw const SmartschoolTwoFactorRequiredError();
    }

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
      mfa,
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
  Future<Response<T>> _send<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final inner = e.error;
      if (inner is SmartschoolException) {
        Error.throwWithStackTrace(inner, e.stackTrace);
      }
      final unreachable = _describeConnectionFailure(e);
      if (unreachable != null) {
        Error.throwWithStackTrace(
          SmartschoolConnectionError(
            'Unable to reach Smartschool at ${credentials.mainUrl}: '
            '$unreachable',
            cause: e,
          ),
          e.stackTrace,
        );
      }
      rethrow;
    }
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
  Future<Response<String>> _rawGet(String url) async {
    return _dio.get<String>(
      url,
      options: Options(
        extra: {_noAuthKey: true},
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
  }

  static String get _noAuthKey => '_smartschool_noAuth';

  static String _defaultCachePath(String username) {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.cache', 'smartschool', username);
  }

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
// Auth interceptor
// ---------------------------------------------------------------------------

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
/// A request sent with `retryAfterLogin: false` (see
/// [SmartschoolClient.postMultipartResponse]) carries state of the session it
/// was prepared in, such as the tokens of the compose form, so it is not
/// retried in a new session: when refused, it fails with a
/// [SmartschoolSessionExpiredError] at once, without a login (#25), also
/// while a login runs (#36).
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
  /// for that login are retried: something that holds state of the session
  /// it was loaded in, such as the compose form's tokens, can compare it the
  /// same way to tell that the client logged in since (#38).
  int _sessionGeneration = 0;

  /// The request `extra` that holds the [_sessionGeneration] the request was
  /// sent in.
  static const _sessionKey = '_smartschool_session';

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

  /// Stamps [options] with the session the request goes out in (#36).
  ///
  /// [CookieManager] runs before this interceptor and has put the cookies on
  /// the request by now, so the stamp is never older than the session the
  /// request carries: a request that it says went out before a login did.
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_sessionKey] = _sessionGeneration;
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

    // A request that carries state of the session it was prepared in (the
    // tokens of the compose form) is not retried in the new session, where
    // that state is stale: a retried message submit would send the message
    // with the compose state of the refused session (its recipients and
    // attachments), and what Smartschool makes of that was never checked.
    // Smartschool refused it before handling it, so it fails as not carried
    // out, without a login: the next refused request logs in (#25). Nor does
    // it wait for a login that is running (#36).
    if (extra[_noRetryKey] == true) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: SmartschoolSessionExpiredError(
            'Smartschool did not accept the session for $request. It is not '
            'retried after logging in again, because it carries state of the '
            'refused session',
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
        throw SmartschoolSessionExpiredError(
          'Smartschool still answered 401 to $request after logging in again',
        );
      }
      // Only one retry: a retry that lands on the login chain again (or is
      // redirected there) is not the data, and logging in once more would
      // not help either (#22).
      final stillOnLoginChain = _loginChainTarget(retried);
      if (stillOnLoginChain != null) {
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

    // Set before the login sends anything, so a request that Smartschool
    // refuses from now on waits for it; cleared before the requests that
    // waited for it resume.
    final login = _logIn(response, loginChain).whenComplete(() {
      _login = null;
    });
    _login = login;
    return login;
  }

  /// Runs the login chain for the refused [response]: from its own page when
  /// it landed on the login chain, otherwise from [loginChain] (or `/login`).
  ///
  /// Counts the login toward [_maxLoginAttempts] and, when it completes,
  /// moves the client to the next [_sessionGeneration].
  Future<void> _logIn(Response<dynamic> response, Uri? loginChain) async {
    _loginAttempts++;
    _lastLoginAt = _clock();
    _rejectedCredentials = null;

    try {
      final realUri = response.realUri;
      if (_client.isAuthUri(realUri)) {
        // Redirected onto the login chain: the response is its first page.
        await _driveAuthChain(realUri, response);
      } else {
        // A 401 does not say where the login chain starts, and a redirect the
        // HTTP client left unfollowed only points at it: open it ourselves.
        final loginPage = await _client._rawGet(
          loginChain?.toString() ?? '/login',
        );
        await _driveAuthChain(loginPage.realUri, loginPage);
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
  /// do not hold (#11). Logging in with them again does not help, and every
  /// rejected attempt brings the account closer to being locked (#32).
  static bool _rejectsCredentials(SmartschoolAuthenticationError e) =>
      e is SmartschoolInvalidCredentialsError ||
      e is SmartschoolTwoFactorRequiredError ||
      e is SmartschoolTwoFactorRejectedError ||
      e is SmartschoolUnsupportedTwoFactorMethodError ||
      e is SmartschoolAccountVerificationRequiredError ||
      e is SmartschoolAccountVerificationRejectedError;

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

  String _bodyAsString(Response<dynamic> response) {
    final data = response.data;
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data);
    return data.toString();
  }
}
