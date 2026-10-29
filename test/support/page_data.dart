// Smartschool's pages as they hand their page data to their JavaScript, for
// the fake Smartschools of the tests that read the authenticated user
// (`vars.authenticatedUser`, #212).
//
// Written by hand after the shape of the live start page (read-only,
// 2026-10-29), with made-up data: a page has several inline scripts, one per
// block of data (`vars`, `quickSearch`, `wopiConfig`, `topnav`, ...), each
// with a `nonce` and a `JSON.parse('...')` of its block in the JavaScript
// escaping of Smartschool's templates (see [jsEscaped]). On the live page,
// the first block is a `vars` without the user, and the user is in the
// second, next to `quickSearch`.
import 'dart:convert';

/// [json] escaped as Smartschool's templates escape the JSON of its page
/// data for a JavaScript string (as Twig's `js` escaping does): letters,
/// digits, `,`, `.` and `_` stay as they are, `\` becomes `\\`, `/` becomes
/// `\/`, a backspace, form feed, line feed, carriage return and tab `\b`,
/// `\f`, `\n`, `\r` and `\t`, and every other character `\uXXXX` (upper
/// case; one outside the BMP as the two of its UTF-16 surrogates), so that
/// a `"` is `\u0022` and the whole of it is on one line.
///
/// Give it JSON with `/` escaped as `\/`, as Smartschool's JSON has it (in a
/// URL: `https:\/\/...`; see [smartschoolJson]), to get the `\\\/` of the
/// live page (#213).
String jsEscaped(String json) {
  const short = {
    r'\': r'\\',
    '/': r'\/',
    '\b': r'\b',
    '\f': r'\f',
    '\n': r'\n',
    '\r': r'\r',
    '\t': r'\t',
  };
  final out = StringBuffer();
  for (final unit in json.codeUnits) {
    final char = String.fromCharCode(unit);
    if (RegExp(r'[A-Za-z0-9,._]').hasMatch(char)) {
      out.write(char);
    } else if (short[char] case final escape?) {
      out.write(escape);
    } else {
      out.write(r'\u');
      out.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
  }
  return out.toString();
}

/// [value] as JSON as Smartschool writes the JSON of its page data (as
/// PHP's `json_encode` does with `JSON_UNESCAPED_UNICODE`): `/` escaped as
/// `\/`, and every other character as `jsonEncode` writes it, so `é` as it
/// is (#213).
String smartschoolJson(Object? value) =>
    jsonEncode(value).replaceAll('/', r'\/');

/// An inline script that merges [data] into `window.SMSC`, as Smartschool's
/// pages hand each block of their data to their JavaScript since 2026-10
/// (#212). [data] is encoded with `jsonEncode` when it is not a [String]
/// already (JSON as Smartschool writes it).
String mergeScript(Object? data) {
  final json = data is String ? data : jsonEncode(data);
  return '<script type="text/javascript" nonce="fake-nonce">\n'
      '                (function (data) {\n'
      "            if (data && typeof data === 'object') {\n"
      '                window.smscMergeJsVariables(window.SMSC, data);\n'
      '            }\n'
      "        })(JSON.parse('${jsEscaped(json)}'));\n"
      '    </script>';
}

/// An inline script that extends `APP.vars` with [data], as Smartschool's
/// pages handed their data to their JavaScript before #212.
String appExtendScript(Object? data) {
  final json = data is String ? data : jsonEncode(data);
  return '<script type="text/javascript">\n'
      "APP.extend(APP.vars || {}, JSON.parse('${jsEscaped(json)}'));\n"
      '</script>';
}

/// An inline script that extends `SMSC` with [data] through jQuery, as the
/// account verification page handed its data to its JavaScript before #212.
String jQueryExtendScript(Object? data) {
  final json = data is String ? data : jsonEncode(data);
  return '<script type="text/javascript">'
      "\$.extend(true, SMSC, JSON.parse('${jsEscaped(json)}'));"
      '</script>';
}

/// A Smartschool page with [scripts] in its body.
String smartschoolPage(List<String> scripts) =>
    '<!DOCTYPE html>\n'
    '<html lang="nl"><head><title>Springfield Academy - Smartschool</title>'
    '</head>\n<body>\n'
    '${scripts.join('\n')}\n'
    '</body></html>';

/// The `authenticatedUser` of the page data, with the keys of the live
/// start page and made-up values: [id] (`{platformId}_{userId}_{coaccount}`),
/// [firstNameFirst] and [lastNameFirst] its name.
String authenticatedUserJson({
  String id = '49_777_0',
  String firstNameFirst = 'Jan Janssens',
  String lastNameFirst = 'Janssens Jan',
}) =>
    '{"id":"$id",'
    '"pictureHash":"initials_JJ",'
    r'"pictureUrl":"https:\/\/userpicture20.smartschool.be\/User\/Userimage'
    r'\/hashimage\/hash\/initials_JJ\/plain\/1\/res\/128",'
    '"description":{"startingWithFirstName":"","startingWithLastName":""},'
    '"name":{"startingWithFirstName":"$firstNameFirst",'
    '"startingWithLastName":"$lastNameFirst"},'
    '"sort":"janssens-jan",'
    '"deleted":false}';

/// Smartschool's start page as it is served since 2026-10 (#212), with the
/// user [userJson] in the second of its four page-data scripts, as on the
/// live start page: a `vars` block without the user first, then
/// `quickSearch` with the `vars` that hold the user, then `wopiConfig` and
/// `topnav`.
String startPage({String? userJson}) => smartschoolPage([
  mergeScript(
    '{"vars":{"showNotifyAlerts":false,"isMP":false,"tracklogging":false}}',
  ),
  mergeScript(
    '{"quickSearch":{"quicksearch.search_placeholder":"Zoeken..."},'
    '"vars":{"authenticatedUser":${userJson ?? authenticatedUserJson()},'
    '"ssID":49}}',
  ),
  mergeScript(
    r'{"wopiConfig":{"wopiActions":{"pdf":{"view":{"applicationName":"Pdf",'
    r'"url":"https:\/\/school.smartschool.be\/wopi\/view"}}}}}',
  ),
  mergeScript('{"topnav":{"title":"Springfield Academy"}}'),
]);
