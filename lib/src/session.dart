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
import 'xml_interface.dart';

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
  // Kept so callers can clear cookies on logout via [clearCookies].
  final PersistCookieJar _cookieJar; // ignore: unused_field

  // Cached after first successful login (parsed from account-verification HTML)
  Map<String, dynamic>? _authenticatedUser;

  // Cached platform ID (from /course-list/api/v1/courses)
  int? _platformId;

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
  Dio get dio => _dio;

  /// Creates and configures a [SmartschoolClient].
  ///
  /// Call this factory instead of the private constructor.
  static Future<SmartschoolClient> create(
    Credentials credentials, {
    String? cacheDir,
  }) async {
    credentials.validate();

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

    // Cookie manager must be added before auth interceptor so cookies are
    // available on each retry request.
    dio.interceptors
      ..add(CookieManager(cookieJar))
      ..add(_SmartschoolAuthInterceptor(client));

    return client;
  }

  // -------------------------------------------------------------------------
  // Public API used by services
  // -------------------------------------------------------------------------

  /// Performs a GET request and returns the decoded JSON body.
  ///
  /// Handles Smartschool's double-encoded JSON (a JSON string whose content
  /// is another JSON string) transparently.
  Future<dynamic> getJson(String path, {Map<String, dynamic>? query}) async {
    final resp = await _dio.get<String>(path, queryParameters: query);
    return _decodeJson(resp);
  }

  /// Performs a POST request and returns the decoded JSON body.
  Future<dynamic> postJson(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    final resp = await _dio.post<String>(
      path,
      data: data,
      queryParameters: query,
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

    final resp = await _dio.post<String>(
      url,
      data: {'command': command},
      options: Options(
        headers: {'X-Requested-With': 'XMLHttpRequest'},
        contentType: Headers.formUrlEncodedContentType,
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
    final resp = await _dio.get<List<int>>(
      path,
      options: Options(responseType: ResponseType.bytes),
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
    final resp = await _dio.get<String>(path, queryParameters: query);
    return resp.data ?? '';
  }

  /// Performs an authenticated `application/x-www-form-urlencoded` POST and
  /// returns the raw response body string.
  ///
  /// Used for Smartschool operations that submit legacy HTML forms (such as
  /// recipient search) whose responses are XML or plain text instead of JSON.
  Future<String> postFormRaw(
    String path,
    Map<String, String> fields, {
    Map<String, dynamic>? query,
  }) async {
    final resp = await _dio.post<String>(
      path,
      data: fields,
      queryParameters: query,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'X-Requested-With': 'XMLHttpRequest'},
      ),
    );
    return resp.data ?? '';
  }

  /// Performs an authenticated `multipart/form-data` POST and returns the raw
  /// response body string.
  ///
  /// Used for the Smartschool message send endpoint and file upload endpoint,
  /// both of which require multipart rather than JSON or URL-encoded bodies.
  Future<String> postMultipartRaw(String path, FormData formData) async {
    final resp = await _dio.post<String>(path, data: formData);
    return resp.data ?? '';
  }

  /// Performs an authenticated `application/x-www-form-urlencoded` POST with
  /// a raw body string and returns the raw response body string.
  ///
  /// Used when the endpoint requires form-urlencoded data with repeated field
  /// names (e.g. `msgIDs[]=123&msgIDs[]=456`), which cannot be represented
  /// as a [Map<String, String>].
  Future<String> postFormEncodedRaw(String path, String body) async {
    final resp = await _dio.post<String>(
      path,
      data: body,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'X-Requested-With': 'XMLHttpRequest'},
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
    final user = _authenticatedUser;
    if (user == null) {
      throw const SmartschoolAuthenticationError(
        'Could not retrieve authenticated user information',
      );
    }
    return user;
  }

  /// Returns the platform ID for the authenticated user.
  ///
  /// Lazily fetched and cached after the first call.
  Future<int> get platformId async {
    _platformId ??= await _fetchPlatformId();
    return _platformId!;
  }

  /// Forces a lightweight authenticated request and throws if session is invalid.
  Future<void> ensureAuthenticated() async {
    try {
      await platformId;
    } on DioException catch (e) {
      final inner = e.error;
      if (inner is SmartschoolException) {
        throw inner;
      }
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
      throw const SmartschoolAuthenticationError(
        'account-verification requires mfa (birthday date) in credentials',
      );
    }

    final doc = html_parser.parse(htmlBody);
    final answerInput = doc.querySelector(
      'form[name="account_verification_form"] input[name*="_security_question_answer"]',
    );
    final expectsDate = answerInput?.attributes['type'] == 'date';
    final dateLike = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(mfa.trim());
    if (expectsDate && !dateLike) {
      throw SmartschoolAuthenticationError(
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
      throw const SmartschoolAuthenticationError(
        '2FA requires a TOTP secret in the mfa field of credentials',
      );
    }

    // Verify TOTP is configured on this account
    final configResp = await _rawGet('/2fa/api/v1/config');
    final config = jsonDecode(configResp.data ?? '{}') as Map<String, dynamic>;
    final mechanisms =
        (config['possibleAuthenticationMechanisms'] as List?)?.cast<String>() ??
        [];
    if (!mechanisms.contains('googleAuthenticator')) {
      throw const SmartschoolAuthenticationError(
        'Only googleAuthenticator 2FA is supported',
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

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

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

    return _dio.post<String>(
      url,
      data: data,
      options: Options(
        contentType: resolvedContentType,
        extra: {_noAuthKey: true},
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
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

/// Intercepts Dio responses that land on Smartschool's login chain and drives
/// the authentication flow transparently, then retries the original request.
///
/// This replaces Python's `Smartschool.request()` override which called
/// `_handle_auth_redirect()` and then re-issued the original call using
/// `super().request()`.
class _SmartschoolAuthInterceptor extends Interceptor {
  final SmartschoolClient _client;
  int _loginAttempts = 0;
  static const _maxLoginAttempts = 3;
  static const _noAuthKey = '_smartschool_noAuth';
  static const _retryKey = '_smartschool_retry';

  _SmartschoolAuthInterceptor(this._client);

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    // Do not intercept requests we marked as part of the auth flow, or retries
    final extra = response.requestOptions.extra;
    if (extra[_noAuthKey] == true || extra[_retryKey] == true) {
      _resetAttempts(response.realUri);
      handler.next(response);
      return;
    }

    final realUri = response.realUri;
    if (!_client.isAuthUri(realUri)) {
      _resetAttempts(realUri);
      handler.next(response);
      return;
    }

    if (_loginAttempts >= _maxLoginAttempts) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: const SmartschoolAuthenticationError(
            'Maximum login attempts reached',
          ),
        ),
        true,
      );
      return;
    }

    _loginAttempts++;

    try {
      await _driveAuthChain(realUri, response);

      // Re-issue the original request now that we are authenticated
      final originalOptions = response.requestOptions.copyWith(
        extra: {...response.requestOptions.extra, _retryKey: true},
      );
      final retried = await _client._dio.fetch<dynamic>(originalOptions);
      handler.resolve(retried);
    } on SmartschoolAuthenticationError catch (e) {
      handler.reject(
        DioException(requestOptions: response.requestOptions, error: e),
        true,
      );
    }
  }

  Future<void> _driveAuthChain(Uri uri, Response<dynamic> response) async {
    final path = uri.path;
    final htmlBody = _bodyAsString(response);
    final url = uri.toString();

    Response<String>? nextResponse;

    if (path.endsWith('/login')) {
      nextResponse = await _client.doLogin(htmlBody, url);
    }

    if (path.endsWith('/account-verification') ||
        (nextResponse?.realUri.path.endsWith('/account-verification') ??
            false)) {
      final body = nextResponse != null ? (nextResponse.data ?? '') : htmlBody;
      final verUrl = nextResponse?.realUri.toString() ?? url;
      nextResponse = await _client.doAccountVerification(body, verUrl);
    }

    if (path.endsWith('/2fa') ||
        (nextResponse?.realUri.path.endsWith('/2fa') ?? false)) {
      nextResponse = await _client.do2fa();
    }

    final finalUri = nextResponse?.realUri ?? uri;
    if (_client.isAuthUri(finalUri)) {
      if (finalUri.path.endsWith('/login')) {
        throw const SmartschoolAuthenticationError(
          'Login failed. Check username/password or SSO-only account setup.',
        );
      }
      if (finalUri.path.endsWith('/account-verification')) {
        throw const SmartschoolAuthenticationError(
          'Account verification is still pending. Check the verification '
          'answer format in credentials.yml (often yyyy-mm-dd).',
        );
      }
      if (finalUri.path.endsWith('/2fa') || finalUri.path.contains('/2fa/')) {
        throw const SmartschoolAuthenticationError(
          '2FA verification failed. Check your TOTP secret (mfa) and '
          'ensure your device time is synchronized.',
        );
      }

      throw SmartschoolAuthenticationError(
        'Authentication flow did not complete. Still on ${finalUri.path}',
      );
    }
  }

  void _resetAttempts(Uri uri) {
    if (_loginAttempts > 0 && !_client.isAuthUri(uri)) {
      _loginAttempts = 0;
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
