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
  ///
  /// With [page], the answer's page as [pageOf] names it, the error of an
  /// HTML page names that page instead of quoting the start of it (#194):
  /// Smartschool's pages all start with the same banner, in a comment, so
  /// the start of one does not tell which page it is.
  static dynamic decodeJson(String body, String what, {String? page}) {
    final trimmed = body.trimLeft();
    if (trimmed.isEmpty) {
      throw SmartschoolSkoreError('Skore answered $what with an empty body.');
    }
    if (trimmed.startsWith('<')) {
      throw SmartschoolSkoreError(
        page == null
            ? 'Skore answered $what with an HTML page instead of JSON: '
                  '${preview(trimmed)}'
            : 'Skore answered $what with an HTML page instead of JSON: '
                  '$page.',
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
  /// The target is the `Location`, resolved against the requested URL, as
  /// [place] names it.
  static String redirectNote(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return '';
    final location = response.headers.value('location')?.trim() ?? '';
    if (location.isEmpty) return ', a redirect without a Location';
    try {
      final request = response.realUri;
      return ', a redirect to ${place(request.resolve(location), request)}';
    } on FormatException {
      return ', a redirect to a Location that is not a URL';
    } on ArgumentError {
      return ', a redirect to a Location that is not a URL';
    }
  }

  /// The page that [response] is, for the message of an error about it
  /// (#194): the URL it ended on, as [place] names it, with the module that
  /// Smartschool names in the page's `smsc-module` header when that URL names
  /// none, and the redirects that led there, each as [place] names it:
  /// `/ (module Homepage), after a redirect to /` for Smartschool's start
  /// page, which it serves at `/` (seen live, 2026-10-27).
  ///
  /// Neither the page's text nor its title: Smartschool's pages start with
  /// the same banner, in a comment, and carry the signed-in user's name.
  static String pageOf(Response<dynamic> response) {
    final request = response.requestOptions.uri;
    final at = request.resolveUri(response.realUri);
    final header = response.headers.value('smsc-module')?.trim() ?? '';
    final module =
        at.queryParameters['module'] == null && _moduleName.hasMatch(header)
        ? ' (module $header)'
        : '';
    final hops = [
      for (final redirect in response.redirects)
        place(request.resolveUri(redirect.location), request),
    ];
    final via = switch (hops) {
      [] => '',
      [final hop] => ', after a redirect to $hop',
      _ => ', after redirects to ${hops.join(', then ')}',
    };
    return '${place(at, request)}$module$via';
  }

  /// A module name as Smartschool gives one (`Homepage`, `Skore`).
  static final _moduleName = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

  /// [target], a URL, for a message: its path, with only the `module` of its
  /// query (`/?module=Homepage`), and with its host only when it is another
  /// one than that of [request]. The rest of a query can hold IDs, which a
  /// log should not get from the message (#192).
  static String place(Uri target, Uri request) {
    final module = target.queryParameters['module'];
    final host = target.host == request.host
        ? ''
        : '${target.scheme}://${target.host}';
    final path = target.path.isEmpty ? '/' : target.path;
    final query = module == null ? '' : '?module=$module';
    return '$host$path$query';
  }

  /// [value], a decoded JSON answer, as a short JSON text for a message.
  static String jsonPreview(Object? value) => preview(jsonEncode(value));

  /// [body] on one line, cut after [max] characters, for a message.
  static String preview(String body, {int max = 160}) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}
