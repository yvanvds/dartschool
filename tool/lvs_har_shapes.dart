// Reduces a browser capture (HAR) of the LVS to shapes only, for the
// developer's capture step (#168, #178; doc/lvs-privacy.md, "Capturing with
// the browser").
//
// Open a pupil's file in the browser with the DevTools' Network tab
// recording, save the log as a HAR file OUTSIDE the repository (a temp
// folder), and run, from the package root:
//
//   dart run tool/lvs_har_shapes.dart <path to the .har>
//
// It refuses a HAR file inside the repository. Per request the page sent to
// Smartschool (static files, the web apps' translations and other hosts left
// out), it prints the method and the path, the names of the query and form
// fields with the pattern of their values (the XML of the dispatcher's
// `command` as a shape), the names of the request headers that are not a
// browser's own, the status, the content type, a redirect's path, and the
// shape of the answer: JSON keys with the kinds of their values, XML
// elements with their children, lists with their lengths, JSON inside a
// text, and JSON encoded twice.
//
// It never prints a value: a number is `int`, a text `<text>` (or `<html>`,
// `<url>`, `<uuid>`), and a text of digits and separators its pattern
// (`9999-99-99`), so a date format shows but no date. Keys that are data (a
// day, an id, a label) are masked the same way, and so are the numbers in a
// path or a name (`<n>`). Only the values of a few enum-like keys (`type`,
// `partOfDay`, ...) and the names of endpoints (`module`, `subsystem`, a
// param's `@name`, ...) show, and only when they are a lower-case word or an
// identifier, never a name. Read the output before you paste it anywhere,
// and delete the HAR file afterwards: it holds the answers in full, and your
// session's cookies.
//
// [shapesOf] is what it prints, and [isInsideRepository] what it refuses:
// test/tool/lvs_har_shapes_test.dart checks both on a fake HAR, offline.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Keys whose values are enums of the LVS, shown when they are a lower-case
/// word (the capture asks which values occur).
const _enumKeys = {
  'type',
  'source',
  'partOfDay',
  'evalType',
  'iconType',
  'color',
  'codeColor',
  'versionType',
  'kind',
  'status',
};

/// Keys whose values name an endpoint (the module, the dispatcher's file,
/// function, subsystem and command), shown when they are an identifier.
const _endpointKeys = {
  'module',
  'file',
  'function',
  'subsystem',
  'command',
  'action',
};

/// Request headers every browser sends; any other is listed by name.
const _browserHeaders = {
  'accept',
  'accept-encoding',
  'accept-language',
  'cache-control',
  'connection',
  'content-length',
  'cookie',
  'dnt',
  'host',
  'origin',
  'pragma',
  'priority',
  'referer',
  'te',
  'upgrade-insecure-requests',
  'user-agent',
};

const _staticExtensions = {
  '.js',
  '.mjs',
  '.css',
  '.map',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.svg',
  '.webp',
  '.ico',
  '.woff',
  '.woff2',
  '.ttf',
  '.eot',
  '.ejs',
};

const _staticTypes = {
  'script',
  'stylesheet',
  'image',
  'font',
  'media',
  'manifest',
};

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/lvs_har_shapes.dart <file.har>');
    exitCode = 64;
    return;
  }
  final path = args.single;
  if (isInsideRepository(path, repositoryRoot())) {
    stderr.writeln(
      'The HAR file is inside the repository. Move it to a temp folder '
      'first (doc/lvs-privacy.md, rule 1 and "Capturing with the browser").',
    );
    exitCode = 64;
    return;
  }
  final Object? har;
  try {
    har = jsonDecode(File(path).readAsStringSync());
  } on FileSystemException catch (error) {
    stderr.writeln(
      'Cannot read the HAR file: ${error.osError?.message ?? error.message}.',
    );
    exitCode = 66;
    return;
  } on FormatException catch (error) {
    // Not the error itself: its message quotes the file around the offset.
    stderr.writeln(
      'Not a HAR file: no valid JSON'
      '${error.offset == null ? '' : ' (at offset ${error.offset})'}.',
    );
    exitCode = 65;
    return;
  }
  if (har is! Map<String, dynamic>) {
    stderr.writeln('Not a HAR file: its JSON is not an object.');
    exitCode = 65;
    return;
  }
  stdout.write(shapesOf(har));
}

/// The root of the repository: the folder above `tool/`, where this file
/// is, when it runs from its source (`dart run tool/lvs_har_shapes.dart`);
/// the current folder otherwise.
String repositoryRoot() {
  final script = Platform.script;
  if (script.isScheme('file') &&
      p.url.basename(script.path) == 'lvs_har_shapes.dart') {
    return p.dirname(p.dirname(script.toFilePath()));
  }
  return Directory.current.path;
}

/// Whether the file at [path] is inside the folder [root] (the
/// repository): by its absolute path, and, when both exist, by the paths
/// their links resolve to. A HAR file holds the answers in full, so it stays
/// out of the working tree (doc/lvs-privacy.md, rule 1).
bool isInsideRepository(String path, String root) {
  final absoluteRoot = p.normalize(p.absolute(root));
  if (p.isWithin(absoluteRoot, p.normalize(p.absolute(path)))) return true;
  try {
    return p.isWithin(
      Directory(root).resolveSymbolicLinksSync(),
      File(path).resolveSymbolicLinksSync(),
    );
  } on FileSystemException {
    return false;
  }
}

/// What the tool prints for [har], a HAR file's decoded JSON: a block per
/// request to Smartschool (see the top of this file), then a line that
/// counts the requests shown and those left out. Never a value of the
/// capture: see [_valuePattern] and [_keyPattern].
String shapesOf(Map<String, dynamic> har) {
  final out = StringBuffer();
  final entries = ((har['log'] as Map)['entries'] as List)
      .cast<Map<String, dynamic>>();

  var shown = 0;
  var otherHosts = 0;
  var staticFiles = 0;
  for (final entry in entries) {
    final request = entry['request'] as Map<String, dynamic>;
    final url = Uri.tryParse(request['url'] as String? ?? '');
    if (url == null || !url.host.endsWith('smartschool.be')) {
      otherHosts++;
      continue;
    }
    if (_isStatic(url, entry)) {
      staticFiles++;
      continue;
    }
    shown++;
    _writeEntry(
      out,
      shown,
      url,
      request,
      entry['response'] as Map<String, dynamic>,
    );
  }
  out.writeln(
    '\n$shown requests shown; $staticFiles static files and $otherHosts '
    'requests to other hosts left out.',
  );
  return out.toString();
}

bool _isStatic(Uri url, Map<String, dynamic> entry) {
  final type = entry['_resourceType'] as String?;
  if (type != null && _staticTypes.contains(type)) return true;
  // The translations of the web apps: no answer of the LVS.
  if (url.path.startsWith('/smsc/locales/')) return true;
  return _staticExtensions.contains(p.url.extension(url.path).toLowerCase());
}

void _writeEntry(
  StringBuffer out,
  int index,
  Uri url,
  Map<String, dynamic> request,
  Map<String, dynamic> response,
) {
  out
    ..writeln()
    ..writeln('#$index ${request['method']} ${_maskPath(url.path)}');

  for (final MapEntry(key: name, value: values)
      in url.queryParametersAll.entries) {
    for (final value in values) {
      out.writeln('  query ${_maskName(name)} = ${_valuePattern(name, value)}');
    }
  }

  final headers = (request['headers'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final extra = <String>{};
  for (final header in headers) {
    final name = (header['name'] as String).toLowerCase();
    if (name.startsWith(':') || name.startsWith('sec-')) continue;
    if (name == 'referer') {
      final referer = Uri.tryParse(header['value'] as String? ?? '');
      if (referer != null) {
        final names = _queryNames(referer);
        out.writeln(
          '  referer ${_maskPath(referer.path)}'
          '${names.isEmpty ? '' : ' (query: $names)'}',
        );
      }
      continue;
    }
    if (name == 'content-type') {
      out.writeln('  content-type ${header['value']}');
      continue;
    }
    if (!_browserHeaders.contains(name)) extra.add(_maskName(name));
  }
  if (extra.isNotEmpty) out.writeln('  other headers: ${extra.join(', ')}');

  final post = request['postData'] as Map<String, dynamic>?;
  if (post != null) _writePostData(out, post);

  final content = response['content'] as Map<String, dynamic>? ?? const {};
  final mime = (content['mimeType'] as String? ?? '').split(';').first;
  final size = content['size'];
  out.writeln('  -> ${response['status']} $mime, $size bytes');
  final redirect = response['redirectURL'] as String? ?? '';
  if (redirect.isNotEmpty) {
    final target = Uri.tryParse(redirect);
    out.writeln(
      '  redirect to ${target == null ? '<url>' : _maskPath(target.path)}'
      '${target == null || target.query.isEmpty ? '' : ' (query: ${_queryNames(target)})'}',
    );
  }
  final body = _bodyText(content);
  if (body != null) _writeBody(out, body);
}

/// The names of the query fields of [url], masked, comma-separated.
String _queryNames(Uri url) =>
    url.queryParameters.keys.map(_maskName).join(', ');

void _writePostData(StringBuffer out, Map<String, dynamic> post) {
  final mime = post['mimeType'] as String? ?? '';
  final params = (post['params'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final text = post['text'] as String? ?? '';
  if (params.isNotEmpty) {
    for (final param in params) {
      _writeFormField(
        out,
        _formDecode(param['name'] as String? ?? ''),
        _formDecode(param['value'] as String? ?? ''),
      );
    }
  } else if (mime.contains('x-www-form-urlencoded')) {
    for (final MapEntry(key: name, value: value) in Uri.splitQueryString(
      text,
    ).entries) {
      _writeFormField(out, name, value);
    }
  } else if (mime.contains('json')) {
    out.writeln('  json body:');
    _writeValueShape(out, _tryJson(text), '    ');
  } else if (text.isNotEmpty) {
    out.writeln('  body: $mime, ${text.length} chars');
  }
}

/// A form field, with the shape of the XML it holds (the dispatcher's
/// `command`) or the pattern of its value.
void _writeFormField(StringBuffer out, String name, String value) {
  final xml = _tryXml(value);
  if (xml == null) {
    out.writeln('  form ${_maskName(name)} = ${_valuePattern(name, value)}');
    return;
  }
  out.writeln('  form ${_maskName(name)} = XML:');
  _writeValueShape(out, {xml.name.local: _xmlToValue(xml)}, '    ');
}

XmlElement? _tryXml(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('<') || trimmed.toLowerCase().startsWith('<html')) {
    return null;
  }
  try {
    return XmlDocument.parse(trimmed).rootElement;
  } on XmlException {
    return null;
  }
}

/// A HAR's form params (names and values) may still be URL-encoded.
String _formDecode(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on Object {
    return value;
  }
}

String? _bodyText(Map<String, dynamic> content) {
  final text = content['text'] as String?;
  if (text == null || text.isEmpty) return null;
  if (content['encoding'] == 'base64') {
    try {
      return utf8.decode(base64.decode(text), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }
  return text;
}

void _writeBody(StringBuffer out, String body) {
  final trimmed = body.trimLeft();
  final json = _tryJson(trimmed);
  if (json != _notJson) {
    if (json is String && _tryJson(json.trim()) != _notJson) {
      out.writeln('  answer: JSON text holding JSON (encoded twice):');
      _writeValueShape(out, _tryJson(json.trim()), '    ');
    } else {
      out.writeln('  answer (JSON):');
      _writeValueShape(out, json, '    ');
    }
    return;
  }
  if (trimmed.startsWith('<?xml') || trimmed.startsWith('<server')) {
    final root = _tryXml(trimmed);
    if (root != null) {
      out.writeln('  answer (XML):');
      _writeValueShape(out, {root.name.local: _xmlToValue(root)}, '    ');
      return;
    }
  }
  final kind = _looksLikeHtml(trimmed) ? 'HTML' : 'text';
  out.writeln('  answer: $kind, ${body.length} chars (not shown)');
}

final Object _notJson = Object();

Object? _tryJson(String text) {
  if (text.isEmpty) return _notJson;
  final first = text[0];
  if (!'{["'.contains(first) &&
      text != 'true' &&
      text != 'false' &&
      text != 'null') {
    return _notJson;
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    return _notJson;
  }
}

/// An XML element as the JSON-like value the shape printer takes: a leaf
/// without attributes is its text; any other element a map of its
/// attributes (`@name`), its text (`#text`) and its child elements by name,
/// in the order they first appear (a list when a name repeats).
Object? _xmlToValue(XmlElement element) {
  final children = element.childElements.toList();
  if (children.isEmpty && element.attributes.isEmpty) {
    return element.innerText.trim();
  }
  final value = <String, Object?>{};
  for (final attribute in element.attributes) {
    value['@${attribute.name.local}'] = attribute.value;
  }
  final byName = <String, List<Object?>>{};
  for (final child in children) {
    (byName[child.name.local] ??= []).add(_xmlToValue(child));
  }
  for (final MapEntry(key: name, value: list) in byName.entries) {
    value[name] = list.length == 1 ? list.single : list;
  }
  if (children.isEmpty) {
    final text = element.innerText.trim();
    if (text.isNotEmpty) value['#text'] = text;
  }
  return value;
}

// --- shapes -----------------------------------------------------------------

/// The merged shape of every value seen at one place of an answer.
class _Shape {
  final kinds = <String>{};
  _MapShape? map;
  _ListShape? list;
  _Shape? jsonText;
  int seen = 0;

  void add(Object? value, String? key) {
    seen++;
    switch (value) {
      case null:
        kinds.add('null');
      case bool():
        kinds.add('bool');
      case int():
        kinds.add('int');
      case double():
        kinds.add('double');
      case String():
        final nested = value.length > 1 ? _tryJson(value.trim()) : _notJson;
        if (nested != _notJson && nested is! String && nested is! num) {
          (jsonText ??= _Shape()).add(nested, key);
        } else {
          kinds.add(_valuePattern(key, value));
        }
      case List():
        (list ??= _ListShape()).add(value);
      case Map():
        (map ??= _MapShape()).add(value);
      default:
        kinds.add(value.runtimeType.toString());
    }
  }
}

class _ListShape {
  int min = -1;
  int max = 0;
  final element = _Shape();

  void add(List<Object?> value) {
    if (min < 0 || value.length < min) min = value.length;
    if (value.length > max) max = value.length;
    for (final item in value) {
      element.add(item, null);
    }
  }
}

class _MapShape {
  int count = 0;
  final fields = <String, _Shape>{};
  final present = <String, int>{};
  final dataKeys = <String>{};
  int dataKeyCount = 0;
  final dataValues = _Shape();

  void add(Map<Object?, Object?> value) {
    count++;
    for (final MapEntry(:key, value: item) in value.entries) {
      final name = '$key';
      if (_isSchemaKey(name)) {
        (fields[name] ??= _Shape()).add(item, name);
        present[name] = (present[name] ?? 0) + 1;
      } else {
        dataKeys.add(_keyPattern(name));
        dataKeyCount++;
        dataValues.add(item, null);
      }
    }
  }
}

void _writeValueShape(StringBuffer out, Object? value, String indent) {
  final shape = _Shape()..add(value, null);
  _writeShape(out, shape, indent, null);
}

void _writeShape(StringBuffer out, _Shape shape, String indent, String? label) {
  final head = label == null ? indent : '$indent$label: ';
  final parts = [...shape.kinds..remove('{}')];
  final map = shape.map;
  final list = shape.list;
  final jsonText = shape.jsonText;

  if (map == null && list == null) {
    if (jsonText == null) {
      out.writeln('$head${parts.isEmpty ? '?' : parts.join(' | ')}');
      return;
    }
    final other = parts.isEmpty ? '' : ' (or ${parts.join(' | ')})';
    out.writeln('$head<JSON text>$other');
    _writeShape(out, jsonText, '$indent  ', null);
    return;
  }
  final extra = parts.isEmpty ? '' : ' (or ${parts.join(' | ')})';
  if (list != null) {
    final lengths = list.min == list.max
        ? '${list.max}'
        : '${list.min}..${list.max}';
    out.writeln('$head[list of $lengths]$extra');
    if (list.element.seen > 0) {
      _writeShape(out, list.element, '$indent  ', '[]');
    }
  }
  if (map != null) {
    if (map.fields.isEmpty && map.dataKeys.isEmpty) {
      out.writeln('$head{} (empty)$extra');
    } else {
      out.writeln('$head{$extra');
      for (final MapEntry(key: name, value: field) in map.fields.entries) {
        final optional = map.present[name]! < map.count
            ? ' (in ${map.present[name]} of ${map.count})'
            : '';
        _writeShape(out, field, '$indent  ', '$name$optional');
      }
      if (map.dataKeys.isNotEmpty) {
        _writeShape(
          out,
          map.dataValues,
          '$indent  ',
          '<keys ${map.dataKeys.take(4).join(' | ')}> x${map.dataKeyCount}',
        );
      }
      out.writeln('$indent}');
    }
  }
  if (jsonText != null) {
    _writeShape(out, jsonText, '$indent  ', '(JSON text)');
  }
}

// --- values and keys --------------------------------------------------------

final _schemaKey = RegExp(r'^[@#]?[A-Za-z_$][A-Za-z0-9_$\-]{0,40}$');
final _digitsAndSeparators = RegExp(r'^[0-9][0-9\s\-/:.,|T+Z]*$');
final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,40}$');
final _fieldName = RegExp(r'^[a-z][A-Za-z0-9_]{0,40}$');
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _base64 = RegExp(r'^[A-Za-z0-9+/_\-]{32,}={0,2}$');
final _enumWord = RegExp(r'^[a-z][a-z0-9_\-]{0,24}$');
final _html = RegExp(r'<[a-zA-Z/][^>]*>');

/// A number in a name, a key or a word: an id (`n_900301`,
/// `tree_group_900101`), never part of a field's name.
final _number = RegExp(r'\d{4,}');

/// A key of lower-case words and numbers (`n_900301`): its numbers are
/// masked, its words show.
final _wordsAndNumbers = RegExp(r'^[a-z_\-]*(?:\d+[a-z_\-]*)+$');

/// A key that names a field, not one that is data (a day, an id, a label,
/// a key with an id in it).
bool _isSchemaKey(String key) =>
    _schemaKey.hasMatch(key) &&
    !RegExp(r'^\d+$').hasMatch(key) &&
    !_number.hasMatch(key);

String _keyPattern(String key) {
  if (_digitsAndSeparators.hasMatch(key) && key.length <= 32) {
    return key.replaceAll(RegExp(r'\d'), '9');
  }
  if (_uuid.hasMatch(key)) return '<uuid>';
  if (_wordsAndNumbers.hasMatch(key) && key.length <= 40) {
    return key.replaceAll(RegExp(r'\d'), '9');
  }
  return '<text>';
}

/// [name], the name of a field, a header or a part of a path, with its
/// numbers masked (`notes[<n>]`).
String _maskName(String name) => name.replaceAll(_number, '<n>');

/// The pattern of a text value: never the value, but its kind, and for a
/// text of digits and separators the format (`9999-99-99`).
String _valuePattern(String? key, String value) {
  if (value.isEmpty) return '""';
  if (value == 'true' || value == 'false') return '"<bool>"';
  if (_digitsAndSeparators.hasMatch(value) && value.length <= 32) {
    return '"${value.replaceAll(RegExp(r'\d'), '9')}"';
  }
  if (_uuid.hasMatch(value)) return '<uuid>';
  // The words below show: never one with an id in it.
  final shows = !_number.hasMatch(value);
  if (shows &&
      key != null &&
      _enumKeys.contains(key) &&
      _enumWord.hasMatch(value)) {
    return '"$value"';
  }
  if (shows &&
      key != null &&
      _endpointKeys.contains(key) &&
      _identifier.hasMatch(value)) {
    return '"$value"';
  }
  // The name of a dispatcher's param (`userID`, `catID`): a lower-case
  // identifier, never a person's name.
  if (shows && key == '@name' && _fieldName.hasMatch(value)) {
    return '"$value"';
  }
  final trimmed = value.trim();
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    final json = _tryJson(trimmed);
    if (json != _notJson) return '<JSON text: ${_inlineShape(json)}>';
  }
  if (_looksLikeHtml(value)) return '<html>';
  if (value.startsWith('http') || value.startsWith('/')) return '<url>';
  if (_base64.hasMatch(value)) return '<base64?>';
  if (value.startsWith('#') && value.length <= 9) return '<colour>';
  return '<text>';
}

/// A short, one-line shape of a JSON value inside a form or query field.
String _inlineShape(Object? json) => switch (json) {
  List() when json.isEmpty => '[]',
  List() => '[list of ${json.length}]',
  Map() when json.isEmpty => '{}',
  Map() =>
    '{${json.keys.map((k) => _isSchemaKey('$k') ? '$k' : _keyPattern('$k')).join(', ')}}',
  _ => json.runtimeType.toString(),
};

bool _looksLikeHtml(String value) => _html.hasMatch(value);

/// A path with its numbers, uuids and long parts masked.
String _maskPath(String path) => path
    .split('/')
    .map((segment) {
      if (RegExp(r'^\d+$').hasMatch(segment)) return '<n>';
      if (_uuid.hasMatch(segment)) return '<uuid>';
      if (segment.length > 40) return '<long>';
      return _maskName(segment);
    })
    .join('/');
