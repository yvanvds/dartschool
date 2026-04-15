import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../credentials.dart';
import '../session.dart';
import 'dev_request_options.dart';

/// A developer tool for inspecting raw Smartschool HTTP traffic.
/// Use this to reverse-engineer new endpoints and page structures.
///
/// Example:
/// ```dart
/// final inspector = await DevInspector.create(credentials);
/// final result = await inspector.getPage('/?module=Messages');
/// inspector.prettyPrint(result);
/// await inspector.saveToFile(result, 'messages_page.html');
/// ```
class DevInspector {
  final SmartschoolClient _client;
  final Credentials _credentials;

  DevInspector._(this._client, this._credentials);

  static Future<DevInspector> create(Credentials credentials) async {
    final client = await SmartschoolClient.create(credentials);
    return DevInspector._(client, credentials);
  }

  Uri _uri(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }

    final normalized = path.startsWith('/') ? path : '/$path';
    final queryIndex = normalized.indexOf('?');
    if (queryIndex == -1) {
      return Uri.https(_credentials.mainUrl, normalized);
    }

    final rawPath = normalized.substring(0, queryIndex);
    final rawQuery = normalized.substring(queryIndex + 1);
    final pathPart = rawPath.isEmpty ? '/' : rawPath;

    return Uri.https(
      _credentials.mainUrl,
      pathPart,
      DevInspector.parseQueryString(rawQuery),
    );
  }

  static Map<String, String> parseQueryString(String rawQuery) {
    if (rawQuery.trim().isEmpty) return const {};
    final result = <String, String>{};
    for (final part in rawQuery.split('&')) {
      if (part.isEmpty) continue;
      final equalsIndex = part.indexOf('=');
      if (equalsIndex == -1) {
        result[Uri.decodeQueryComponent(part)] = '';
      } else {
        final key = Uri.decodeQueryComponent(part.substring(0, equalsIndex));
        final value = Uri.decodeQueryComponent(part.substring(equalsIndex + 1));
        result[key] = value;
      }
    }
    return result;
  }

  /// Fetches a full Smartschool page (GET).
  Future<InspectionResult> getPage(String path) async {
    final uri = _uri(path);
    final response = await _client.dio.getUri<String>(uri);
    return InspectionResult(
      uri: uri,
      method: 'GET',
      statusCode: response.statusCode ?? 0,
      headers: _flattenHeaders(response.headers),
      body: response.data ?? '',
    );
  }

  /// Sends a POST request and inspects the response.
  Future<InspectionResult> postRequest(
    String path, {
    required Map<String, String> formData,
  }) async {
    return request(
      'POST',
      path,
      options: DevRequestOptions(
        formData: formData,
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  /// Fetches a URL and tries to parse the response as JSON.
  Future<InspectionResult> getJson(String path) async {
    return request(
      'GET',
      path,
      options: DevRequestOptions(
        headers: {'Accept': 'application/json'},
        isJson: true,
      ),
    );
  }

  /// Returns the authenticated Smartschool user payload.
  Future<Map<String, dynamic>> getAuthenticatedUser() {
    return _client.authenticatedUser;
  }

  /// Executes a low-level request for reverse-engineering purposes.
  ///
  /// This method is intentionally flexible so MCP tools can experiment with
  /// various Smartschool endpoints.
  Future<InspectionResult> request(
    String method,
    String path, {
    DevRequestOptions options = const DevRequestOptions(),
  }) async {
    final headers = options.headers;
    final query = options.query;
    final data = options.data;
    final formData = options.formData;
    final contentType = options.contentType;
    final isJson = options.isJson;
    final baseUri = _uri(path);
    final uri = (query == null || query.isEmpty)
        ? baseUri
        : baseUri.replace(
            queryParameters: {
              ...baseUri.queryParameters,
              for (final entry in query.entries)
                entry.key: entry.value?.toString() ?? '',
            },
          );
    final response = await _client.dio.requestUri<String>(
      uri,
      data: data ?? formData,
      options: Options(
        method: method,
        headers: headers,
        contentType: contentType,
      ),
    );

    return InspectionResult(
      uri: uri,
      method: method.toUpperCase(),
      statusCode: response.statusCode ?? 0,
      headers: _flattenHeaders(response.headers),
      body: response.data ?? '',
      isJson: isJson,
    );
  }

  /// Converts Dio's [Headers] (which allows multiple values per key) to a
  /// flat [Map<String, String>] for display purposes.
  Map<String, String> _flattenHeaders(Headers headers) {
    return {
      for (final entry in headers.map.entries)
        entry.key: entry.value.join(', '),
    };
  }

  /// Pretty-prints an [InspectionResult] to stdout.
  void prettyPrint(InspectionResult result) {
    print('─' * 60);
    print('${result.method} ${result.uri}');
    print('Status: ${result.statusCode}');
    print('Response Headers:');
    result.headers.forEach((k, v) => print('  $k: $v'));
    print('Body (truncated to 2000 chars):');
    print(result.body.substring(0, result.body.length.clamp(0, 2000)));
    if (result.isJson) {
      try {
        final decoded = jsonDecode(result.body);
        print('Parsed JSON:');
        print(const JsonEncoder.withIndent('  ').convert(decoded));
      } catch (_) {
        print('[Body is not valid JSON]');
      }
    }
    print('─' * 60);
  }

  /// Saves the body of an [InspectionResult] to a local file.
  Future<void> saveToFile(InspectionResult result, String filename) async {
    final file = File(filename);
    await file.writeAsString(result.body);
    print('Saved to ${file.absolute.path}');
  }

  /// Dumps all cookies currently held by the session.
  void dumpCookies() {
    // Expose via SmartschoolClient if you store a CookieJar
    print(
      'Cookie dump not yet implemented — expose cookieJar on SmartschoolClient',
    );
  }
}

class InspectionResult {
  final Uri uri;
  final String method;
  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final bool isJson;

  const InspectionResult({
    required this.uri,
    required this.method,
    required this.statusCode,
    required this.headers,
    required this.body,
    this.isJson = false,
  });

  Map<String, dynamic> toMap({int? maxBodyChars}) {
    final hasLimit = maxBodyChars != null && maxBodyChars >= 0;
    final limitedBody = hasLimit && body.length > maxBodyChars
        ? body.substring(0, maxBodyChars)
        : body;

    return {
      'uri': uri.toString(),
      'method': method,
      'statusCode': statusCode,
      'headers': headers,
      'body': limitedBody,
      'bodyLength': body.length,
      'bodyTruncated': limitedBody.length != body.length,
      'isJson': isJson,
      if (isJson) 'json': _tryParseJson(body),
    };
  }

  String toJsonString({int? maxBodyChars}) {
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(toMap(maxBodyChars: maxBodyChars));
  }

  dynamic _tryParseJson(String input) {
    try {
      return jsonDecode(input);
    } catch (_) {
      return null;
    }
  }
}
