// The requests of the LVS services, by an allowlist (#160). Internal: not
// exported by the library.
//
// The pupil tracking system (LVS, `/?module=LVS`) has writes right next to
// its reads, some on the same URL (`PUT /LVS/Message` next to
// `GET /LVS/Message`, `PUT /LVS/Watch`, `setLastPupil`, the "viewed" flags,
// the edit locks, every `save*`, `update*`, `delete*`, `print*`, `export*`).
// So no LVS service sends a request on its own: each goes through [LvsWire],
// which checks it against [LvsWire.reads] and refuses any other before it is
// sent. The LVS issues that follow (#161 to #164) add their reads to that
// list, next to those of #160.
//
// The LVS talks to its web client in three ways (#160):
// 1. an XML dispatcher, `POST /?module=LVS&file=dispatcher`;
// 2. `POST /?module=LVS&file=jqDispatcher_<area>&function=<fn>`, answered
//    with JSON as text;
// 3. controller routes, `/LVS/<Controller>/<action>` (GET or POST, JSON).
// An [LvsRead] names the method, the path and the query fields of a request
// (for 1 and 2, the fixed `module`, `file` and `function`), and the form
// fields it may carry; for 1, also the one command its `command` field may
// hold ([LvsCommand]: subsystem, action and param names), since every
// command of the LVS goes to that one URL, its writes too
// (`changeItemViewStatus`, `saveProfile`, ...). #160 reads with 3, and with
// the left tree's `treeBuilder` (2's form, without a `function`); #161 with
// 1, the notes of a pupil.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../exceptions.dart';
import '../session.dart';
import '../xml_answer.dart' show isHtmlAnswer;

/// The one command of the LVS's XML dispatcher (`POST
/// /?module=LVS&file=dispatcher`, form field `command`) that an [LvsRead]
/// may send: its subsystem, its action, and the names of the params it may
/// carry (#161).
final class LvsCommand {
  const LvsCommand({
    required this.subsystem,
    required this.action,
    required this.params,
  });

  /// The command's `subsystem`, such as `lvs_cats`.
  final String subsystem;

  /// The command's `action`, such as `getUserCatItems`.
  final String action;

  /// The names of the params it may carry, with any value.
  final Set<String> params;

  /// The `command` form field for this command with [values]: a `<request>`
  /// of one `<command>`, each value in a CDATA section (a `]]>` in it split
  /// over two sections, as the web client does).
  String build(Map<String, String> values) {
    final unknown = values.keys.where((name) => !params.contains(name));
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
        unknown.join(', '),
        'values',
        'not params of $subsystem/$action',
      );
    }
    final buffer = StringBuffer()
      ..write('<request><command>')
      ..write('<subsystem>$subsystem</subsystem>')
      ..write('<action>$action</action>')
      ..write('<params>');
    for (final MapEntry(:key, :value) in values.entries) {
      final cdata = value.replaceAll(']]>', ']]]]><![CDATA[>');
      buffer.write('<param name="$key"><![CDATA[$cdata]]></param>');
    }
    buffer.write('</params></command></request>');
    return buffer.toString();
  }

  /// Whether the `command` form field [xml] is this command: a `<request>`
  /// with one `<command>` of this [subsystem] and [action], whose `<params>`
  /// hold only `<param>`s of [params], each once, and nothing else.
  bool allows(String? xml) {
    final command = _commandOf(xml);
    if (command == null) return false;
    final (:subsystem, :action, :params) = command;
    return subsystem == this.subsystem &&
        action == this.action &&
        params != null &&
        params.every(this.params.contains);
  }

  /// The subsystem and action of the `command` form field [xml], for a
  /// message, when it is a `<request>` of one command; `null` otherwise.
  static String? describe(String? xml) {
    final command = _commandOf(xml);
    if (command == null) return null;
    return '${command.subsystem}/${command.action}';
  }

  /// The subsystem, the action and the param names (`null` when a param is
  /// not a `<param name>` or comes twice) of the `<request>` [xml] of one
  /// `<command>` with `<subsystem>`, `<action>` and `<params>`, each once and
  /// nothing else; `null` for any other text.
  static ({String subsystem, String action, List<String>? params})? _commandOf(
    String? xml,
  ) {
    if (xml == null) return null;
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException {
      return null;
    }
    final roots = document.childElements.toList();
    if (roots.length != 1) return null;
    final request = roots.single;
    if (request.name.qualified != 'request' || !_onlyElements(request)) {
      return null;
    }
    final commands = request.childElements.toList();
    if (commands.length != 1 || commands.single.name.qualified != 'command') {
      return null;
    }
    final command = commands.single;
    if (!_onlyElements(command) || command.attributes.isNotEmpty) return null;
    final parts = command.childElements.toList();
    final names = parts.map((part) => part.name.qualified).toList();
    if (names.length != 3 ||
        names[0] != 'subsystem' ||
        names[1] != 'action' ||
        names[2] != 'params' ||
        parts[0].childElements.isNotEmpty ||
        parts[1].childElements.isNotEmpty ||
        !_onlyElements(parts[2])) {
      return null;
    }
    final params = <String>[];
    for (final param in parts[2].childElements) {
      final name = param.getAttribute('name');
      if (param.name.qualified != 'param' ||
          name == null ||
          param.attributes.length != 1 ||
          param.childElements.isNotEmpty ||
          params.contains(name)) {
        return (
          subsystem: parts[0].innerText.trim(),
          action: parts[1].innerText.trim(),
          params: null,
        );
      }
      params.add(name);
    }
    return (
      subsystem: parts[0].innerText.trim(),
      action: parts[1].innerText.trim(),
      params: params,
    );
  }

  /// Whether [element] holds elements and white space only (no text, no
  /// CDATA, no comments or instructions between them).
  static bool _onlyElements(XmlElement element) => element.children.every(
    (node) =>
        node is XmlElement || (node is XmlText && node.value.trim() == ''),
  );
}

/// A request the LVS services may send: a read of the LVS.
final class LvsRead {
  const LvsRead({
    required this.method,
    required this.path,
    required this.what,
    this.fixedQuery = const {},
    this.queryFields = const {},
    this.formFields = const {},
    this.command,
  });

  /// `GET` or `POST`.
  final String method;

  /// The path: a `String` for exactly that path, a [RegExp] for a path that
  /// matches it as a whole (such as `/LVS/Spotlight/<pupil id>`).
  final Pattern path;

  /// What the read is, for messages: `"the pupil search"`.
  final String what;

  /// The query fields the request must carry with exactly these values
  /// (`module`, `file`, `function` of the dispatchers).
  final Map<String, String> fixedQuery;

  /// The other query fields the request may carry, with any value.
  final Set<String> queryFields;

  /// The form fields a `POST` may carry, with any value.
  final Set<String> formFields;

  /// For a read of the XML dispatcher: the one command its `command` form
  /// field must hold. `null` for the other reads.
  final LvsCommand? command;

  /// Whether a request of [method] to [path] with [query] and [form] is this
  /// read.
  bool allows(
    String method,
    String path,
    Map<String, String> query,
    Map<String, String> form,
  ) {
    if (method.toUpperCase() != this.method) return false;
    final pattern = this.path;
    final pathMatches = pattern is RegExp
        ? pattern.matchAsPrefix(path)?.end == path.length
        : pattern == path;
    if (!pathMatches) return false;
    for (final MapEntry(:key, :value) in fixedQuery.entries) {
      if (query[key] != value) return false;
    }
    for (final key in query.keys) {
      if (!fixedQuery.containsKey(key) && !queryFields.contains(key)) {
        return false;
      }
    }
    if (method.toUpperCase() != 'POST' && form.isNotEmpty) return false;
    if (!form.keys.every(formFields.contains)) return false;
    final command = this.command;
    return command == null || command.allows(form['command']);
  }
}

/// Sends the reads of the LVS services, and only those ([reads]); reads
/// their answers.
final class LvsWire {
  LvsWire(this._client);

  final SmartschoolClient _client;

  /// The pupil search (#160): `GET /LVS/Spotlight?searchVal=<text>`. The
  /// same URL with `classID`, `type` or `catID` picks people for a note:
  /// not on the list.
  static const pupilSearch = LvsRead(
    method: 'GET',
    path: '/LVS/Spotlight',
    what: 'the pupil search',
    queryFields: {'searchVal'},
  );

  /// A pupil's file (#160): `GET /LVS/Spotlight/<pupil id>?classID=<id>`.
  static final pupilFile = LvsRead(
    method: 'GET',
    path: RegExp(r'/LVS/Spotlight/[1-9][0-9]*'),
    what: "the pupil's file",
    queryFields: const {'classID'},
  );

  /// A pupil's attendance today (#160):
  /// `POST /LVS/Pupilxhr/getStatusInfo` with `pupilID`.
  static const todayStatus = LvsRead(
    method: 'POST',
    path: '/LVS/Pupilxhr/getStatusInfo',
    what: "the pupil's status today",
    formFields: {'pupilID'},
  );

  /// A node of the left tree (#160): `POST /?module=LVS&file=treeBuilder`
  /// with `id` (`0` for the root: the classes the account may see). Not
  /// its `adminTree` or `lostAndFound` (a `function`).
  static const tree = LvsRead(
    method: 'POST',
    path: '/',
    what: 'the class tree',
    fixedQuery: {'module': 'LVS', 'file': 'treeBuilder'},
    formFields: {'id'},
  );

  /// The query of the LVS's XML dispatcher: `/?module=LVS&file=dispatcher`.
  static const dispatcherQuery = {'module': 'LVS', 'file': 'dispatcher'};

  /// The notes of a category of a pupil's file (#161): the dispatcher's
  /// `lvs_cats/getUserCatItems` with the params the web client sends
  /// (`catID`, `userID`, `toolbarType`, `syRange`, `groupID`,
  /// `toolbarSide`), answered with the action `renderPupilNotes`. The web
  /// client sends `lvs_pupils/getCatListView` (its saved list layouts) in the
  /// same request: not on the list.
  static const categoryNotes = LvsRead(
    method: 'POST',
    path: '/',
    what: 'the notes of a category',
    fixedQuery: dispatcherQuery,
    formFields: {'command'},
    command: LvsCommand(
      subsystem: 'lvs_cats',
      action: 'getUserCatItems',
      params: {
        'catID',
        'userID',
        'toolbarType',
        'syRange',
        'groupID',
        'toolbarSide',
      },
    ),
  );

  /// All of a pupil's file, the "all items" view (#161): the dispatcher's
  /// `lvs_pupils/getUserData` with `userID`, `toolbarType`, `groupID`,
  /// `syRange`, `viewAllFilter` and `filterData`, answered with the action
  /// `renderPupilAllNotes`.
  static const allNotes = LvsRead(
    method: 'POST',
    path: '/',
    what: "all of a pupil's notes",
    fixedQuery: dispatcherQuery,
    formFields: {'command'},
    command: LvsCommand(
      subsystem: 'lvs_pupils',
      action: 'getUserData',
      params: {
        'userID',
        'toolbarType',
        'groupID',
        'syRange',
        'viewAllFilter',
        'filterData',
      },
    ),
  );

  /// Every request the LVS services may send. Any other is refused with a
  /// [SmartschoolLvsRequestNotAllowedError] before it is sent.
  static final List<LvsRead> reads = List.unmodifiable([
    pupilSearch,
    pupilFile,
    todayStatus,
    tree,
    categoryNotes,
    allNotes,
  ]);

  /// The read of [reads] that a request of [method] to [path] with [query]
  /// and [form] is, or `null` when it is none.
  static LvsRead? readOf(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, String> form = const {},
  }) {
    for (final read in reads) {
      if (read.allows(method, path, query, form)) return read;
    }
    return null;
  }

  /// Sends a GET of [path] with [query], when it is one of [reads].
  Future<Response<String>> get(
    String path, {
    Map<String, String> query = const {},
  }) {
    final read = _check('GET', path, query, const {});
    return _guarded(
      read,
      query,
      () => _client.getResponse(path, query: query.isEmpty ? null : query),
    );
  }

  /// Sends a form POST of [form] to [path] with [query], when it is one of
  /// [reads].
  Future<Response<String>> post(
    String path, {
    Map<String, String> query = const {},
    Map<String, String> form = const {},
  }) {
    final read = _check('POST', path, query, form);
    return _guarded(
      read,
      query,
      () => _client.postFormResponse(
        path,
        form,
        query: query.isEmpty ? null : query,
      ),
    );
  }

  /// Sends the command of [read], a read of the XML dispatcher (one with a
  /// [LvsRead.command]), with the params [params], when it is one of
  /// [reads].
  Future<Response<String>> dispatch(LvsRead read, Map<String, String> params) {
    final command = read.command;
    final path = read.path;
    if (command == null || path is! String) {
      throw StateError('${read.what} is not a read of the XML dispatcher.');
    }
    return post(
      path,
      query: read.fixedQuery,
      form: {'command': command.build(params)},
    );
  }

  /// Sends any request, when it is one of [reads]: for the tests of the
  /// allowlist, which try what the services never send (a `PUT`, a
  /// `setLastPupil`).
  Future<Response<String>> send(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, String> form = const {},
  }) async {
    final upper = method.toUpperCase();
    _check(upper, path, query, form);
    return switch (upper) {
      'GET' => get(path, query: query),
      'POST' => post(path, query: query, form: form),
      _ => throw StateError('The LVS wire sends GET and POST only.'),
    };
  }

  static LvsRead _check(
    String method,
    String path,
    Map<String, String> query,
    Map<String, String> form,
  ) {
    final read = readOf(method, path, query: query, form: form);
    if (read != null) return read;
    final upper = method.toUpperCase();
    final fields = [...query.keys, ...form.keys];
    // The command of the dispatcher, by its subsystem and action (the
    // library's own words, never a value of the params).
    final command = LvsCommand.describe(form['command']);
    throw SmartschoolLvsRequestNotAllowedError(
      'The LVS service does not send $upper $path'
      '${fields.isEmpty ? '' : ' (with ${fields.join(', ')})'}'
      '${command == null ? '' : ' with the command $command'}: it is not '
      'one of its reads. Nothing was sent.',
      method: upper,
      path: path,
    );
  }

  /// Runs [send], the request of [read] with [query]. The client's errors
  /// for a refused session or a disposed client name the request's URL;
  /// when the query holds a text (the name a pupil search was for), it is
  /// left out of their message (`doc/lvs-privacy.md`, rule 6).
  static Future<Response<String>> _guarded(
    LvsRead read,
    Map<String, String> query,
    Future<Response<String>> Function() send,
  ) async {
    try {
      return await send();
    } on SmartschoolSessionExpiredError catch (e, stack) {
      final message = _withoutTexts(e.message, read, query);
      if (message == e.message) rethrow;
      Error.throwWithStackTrace(SmartschoolSessionExpiredError(message), stack);
    } on SmartschoolClientDisposedError catch (e, stack) {
      final message = _withoutTexts(e.message, read, query);
      if (message == e.message) rethrow;
      Error.throwWithStackTrace(SmartschoolClientDisposedError(message), stack);
    }
  }

  /// [message] with the value of each free query field of [query] that holds
  /// a text (not a number) replaced by `<field>` where the message names the
  /// request's URL (`searchVal=<searchVal>`).
  static String _withoutTexts(
    String message,
    LvsRead read,
    Map<String, String> query,
  ) {
    var result = message;
    for (final MapEntry(:key, :value) in query.entries) {
      if (read.fixedQuery.containsKey(key)) continue;
      if (value.isEmpty || RegExp(r'^\d+$').hasMatch(value)) continue;
      result = result.replaceAll(
        RegExp('(?<=[?&])${RegExp.escape(key)}=[^&#\\s]*'),
        '$key=<$key>',
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Answers
  // ---------------------------------------------------------------------------

  /// The JSON of [response], the answer to [read]. Throws a
  /// [SmartschoolLvsAccessDeniedError] for a refusal, and a
  /// [SmartschoolLvsError] for an answer that is not JSON. Never quotes the
  /// answer.
  static Object? json(Response<String> response, LvsRead read) {
    final what = read.what;
    final status = response.statusCode ?? 0;
    final body = _body(response, read);
    if (body.startsWith('<')) {
      throw SmartschoolLvsError(
        'The LVS answered $what with an HTML page instead of data.',
        statusCode: status,
      );
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SmartschoolLvsError(
        'The LVS answered $what with something that is not JSON.',
        statusCode: status,
        cause: e,
      );
    }
  }

  /// The data of the action [answer] in [response], the XML dispatcher's
  /// answer to [read] (#161): the one element in its `<data>`, whose
  /// children the web client reads by position.
  ///
  /// The answer is (seen live):
  ///
  /// ```text
  /// <server><response><status>ok</status><actions><action>
  ///   <subsystem>…</subsystem><command>[answer]</command><data>…</data>
  /// </action>…</actions></response></server>
  /// ```
  ///
  /// Throws a
  /// [SmartschoolLvsAccessDeniedError] for a refusal (as [json]), and a
  /// [SmartschoolLvsError] for an answer that is not XML, a `status` other
  /// than `ok` (the answer's `message` in [SmartschoolLvsError.cause]), and
  /// an answer without the action. Never quotes the answer.
  static XmlElement dispatcherContent(
    Response<String> response,
    LvsRead read, {
    required String answer,
  }) {
    final what = read.what;
    final status = response.statusCode ?? 0;
    final body = _body(response, read);
    if (isHtmlAnswer(body)) {
      throw SmartschoolLvsError(
        'The LVS answered $what with an HTML page instead of data.',
        statusCode: status,
      );
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw SmartschoolLvsError(
        'The LVS answered $what with something that is not well-formed XML.',
        statusCode: status,
        cause: e,
      );
    }
    final server = document.childElements.singleOrNull;
    if (server == null || server.name.local != 'server') {
      throw unknownShape(read, 'no <server>');
    }
    for (final reply in server.childElements) {
      if (reply.name.local != 'response') continue;
      final state = reply.getElement('status')?.innerText.trim();
      if (state != 'ok') {
        throw SmartschoolLvsError(
          'The LVS answered $what with an error (its status is not "ok").',
          statusCode: status,
          cause: reply.getElement('message')?.innerText.trim(),
        );
      }
      final actions = reply.getElement('actions')?.childElements ?? const [];
      for (final action in actions) {
        final parts = action.childElements.toList();
        if (parts.length < 3 || parts[1].innerText.trim() != answer) continue;
        final content = parts[2].childElements.toList();
        if (content.length != 1) {
          throw unknownShape(read, 'the data of $answer is not one element');
        }
        return content.single;
      }
    }
    throw unknownShape(read, 'no $answer action');
  }

  /// The body of [response], the answer to [read], trimmed. Throws a
  /// [SmartschoolLvsAccessDeniedError] for a refusal (HTTP `403`, or a
  /// redirect to Smartschool's start page), and a [SmartschoolLvsError] for
  /// another status than `200` and an empty answer.
  static String _body(Response<String> response, LvsRead read) {
    final what = read.what;
    final status = response.statusCode ?? 0;
    if (status == 403) {
      throw SmartschoolLvsAccessDeniedError(
        'The LVS refused $what to the account (HTTP 403).',
        statusCode: status,
      );
    }
    if (_sentToStartPage(response)) {
      throw SmartschoolLvsAccessDeniedError(
        "The LVS refused $what to the account: it sent the request on to "
        "Smartschool's start page.",
        statusCode: status,
      );
    }
    if (status != 200) {
      throw SmartschoolLvsError(
        'The LVS answered $what with HTTP $status.',
        statusCode: status,
      );
    }
    final body = (response.data ?? '').trim();
    if (body.isEmpty) {
      throw SmartschoolLvsError(
        'The LVS answered $what with an empty answer.',
        statusCode: status,
      );
    }
    return body;
  }

  /// Whether [response] sends its request on to Smartschool's start page,
  /// `/?module=Homepage` on the same host, as Skore does for an account
  /// without its rights (#91): a GET that the client followed there, or the
  /// redirect itself (the client does not follow one after a POST).
  static bool _sentToStartPage(Response<String> response) {
    final request = response.requestOptions.uri;
    final status = response.statusCode ?? 0;
    final location = Uri.tryParse(
      response.headers.value('location')?.trim() ?? '',
    );
    final Uri target;
    if (status >= 300 && status < 400 && location != null) {
      target = request.resolveUri(location);
    } else if (response.redirects.isNotEmpty) {
      target = request.resolveUri(response.realUri);
    } else {
      return false;
    }
    return target.host == request.host &&
        (target.path == '/' || target.path.isEmpty) &&
        target.queryParameters['module'] == 'Homepage';
  }

  // ---------------------------------------------------------------------------
  // Values
  // ---------------------------------------------------------------------------

  /// The [SmartschoolLvsError] for an answer to [read] in a shape the
  /// service does not recognise; [where] names the field, never its value.
  static SmartschoolLvsError unknownShape(LvsRead read, String where) =>
      SmartschoolLvsError(
        'The LVS answered ${read.what} in a shape the service does not '
        'recognise: $where.',
        statusCode: 200,
      );

  /// [value] as an ID: an int, or a string of digits; `null` for anything
  /// else.
  static int? tryId(Object? value) => switch (value) {
    int() => value,
    String() when RegExp(r'^\s*-?\d+\s*$').hasMatch(value) => int.parse(
      value.trim(),
    ),
    _ => null,
  };

  /// [value] as a flag: a `bool`, `0`/`1`, or `"0"`/`"1"`/`"true"`/
  /// `"false"`; `null` for anything else.
  static bool? tryFlag(Object? value) => switch (value) {
    bool() => value,
    int() when value == 0 || value == 1 => value == 1,
    String() when const {'0', '1', 'true', 'false'}.contains(value) =>
      value == '1' || value == 'true',
    _ => null,
  };

  /// The plain text of [html]: without its tags, its entities decoded, its
  /// white space collapsed.
  static String plainText(String html) {
    final text = html.contains('<') || html.contains('&')
        ? html_parser.parseFragment(html).text ?? ''
        : html;
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
