// The RPC protocol of Skore's backend services, shared by SkoreService (the
// admin side, #70) and SkoreGradebookService (the teacher's own gradebooks,
// #148). Not exported.
import 'dart:convert';

import 'package:dio/dio.dart' show Response;

import '../exceptions.dart';

/// The RPC protocol of Skore's backend services (`owners.php`,
/// `rapportbeheer/rpc/data.php`, `gradebook/rpc.php`), as Skore's web client
/// speaks it, and the small readers both Skore services use.
///
/// A call is a form POST with `rpc_sessionobj` (the session object, JSON),
/// `rpc_requestType` (`requestData`), `rpc_method` and `rpc_params` (the
/// arguments as a JSON array). Skore answers
/// `{"result": ..., "session": 1, "method": ..., ...}`.
abstract final class SkoreRpc {
  /// The session object Skore's web client sends at [now]: `requestSource`
  /// (`skore-web`), `timelimit` (`null`) and `client_epoch` ([now] in
  /// seconds), with [extra] (such as the gradebook's `teacher` and
  /// `restriction`) after `requestSource`, and [trailing] (such as `wy`) at
  /// the end, in the web client's order.
  static Map<String, Object?> session(
    DateTime now, {
    Map<String, Object?> extra = const {},
    Map<String, Object?> trailing = const {},
  }) => {
    'requestSource': 'skore-web',
    ...extra,
    'timelimit': null,
    'client_epoch': now.millisecondsSinceEpoch ~/ 1000,
    ...trailing,
  };

  /// The form fields of a call to [method] with [params] and [session].
  static Map<String, String> fields(
    String method,
    List<Object?> params, {
    required Map<String, Object?> session,
  }) => {
    'rpc_sessionobj': jsonEncode(session),
    'rpc_requestType': 'requestData',
    'rpc_method': method,
    'rpc_params': jsonEncode(params),
  };

  /// The `result` of an RPC answer [body] to [method].
  ///
  /// Like Skore's web client, takes an answer without a (truthy) `session`
  /// for an expired session: a [SmartschoolSessionExpiredError]. An answer
  /// that is not a JSON object, or has no `result`, is a
  /// [SmartschoolSkoreError].
  static dynamic result(String body, String method) {
    final what = 'the RPC call $method';
    final json = decodeJson(body, what);
    if (json is! Map<String, dynamic>) {
      throw SmartschoolSkoreError(
        'Skore answered $what with ${json.runtimeType} instead of an object.',
      );
    }
    final session = json['session'];
    if (session == null || session == false || session == 0 || session == '') {
      throw SmartschoolSessionExpiredError(
        'Skore answered $what without a session.',
      );
    }
    if (!json.containsKey('result')) {
      throw SmartschoolSkoreError('Skore answered $what without a result.');
    }
    return json['result'];
  }

  /// Decodes [body], the JSON answer to [what]; an empty body, an HTML page
  /// or invalid JSON is a [SmartschoolSkoreError].
  static dynamic decodeJson(String body, String what) {
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty) {
      throw SmartschoolSkoreError('Skore answered $what with an empty body.');
    }
    if (trimmed.startsWith('<')) {
      throw SmartschoolSkoreError(
        'Skore answered $what with an HTML page instead of JSON: '
        '${preview(trimmed)}',
      );
    }
    try {
      return jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw SmartschoolSkoreError(
        'Skore answered $what with invalid JSON (${e.message}): '
        '${preview(trimmed)}',
      );
    }
  }

  /// A Skore ID: an int, or a string of digits as Skore mostly sends them;
  /// anything else is a [SmartschoolSkoreError] that names [what].
  static int id(Object? value, String what) {
    final id = tryId(value);
    if (id == null) {
      throw SmartschoolSkoreError('Skore gave $what the ID "$value".');
    }
    return id;
  }

  /// [value] as a Skore ID (see [id]), or `null` when it is none.
  static int? tryId(Object? value) {
    if (value is int) return value;
    return value is String ? int.tryParse(value.trim()) : null;
  }

  /// What [response] redirects to, for the message of an error about it:
  /// `, a redirect to <target>` for a redirect (`3xx`) with a `Location`,
  /// `, a redirect without a Location` for one without, and `""` for any
  /// other answer (#192).
  ///
  /// The target is the path of the `Location`, resolved against the
  /// requested URL, with only the `module` of its query
  /// (`/?module=Homepage`), and with its host only when it is another one
  /// than the request's: the rest of a query can hold IDs, which a log
  /// should not get from the message.
  static String redirectNote(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return '';
    final location = response.headers.value('location')?.trim() ?? '';
    if (location.isEmpty) return ', a redirect without a Location';
    try {
      final request = response.realUri;
      final target = request.resolve(location);
      final module = target.queryParameters['module'];
      final host = target.host == request.host
          ? ''
          : '${target.scheme}://${target.host}';
      final path = target.path.isEmpty ? '/' : target.path;
      final query = module == null ? '' : '?module=$module';
      return ', a redirect to $host$path$query';
    } on FormatException {
      return ', a redirect to a Location that is not a URL';
    } on ArgumentError {
      return ', a redirect to a Location that is not a URL';
    }
  }

  /// [value], a decoded JSON answer, as a short JSON text for a message.
  static String jsonPreview(Object? value) => preview(jsonEncode(value));

  /// [body] on one line, cut after [max] characters, for a message.
  static String preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
