import 'dart:io' show HttpStatus;

import 'package:dio/dio.dart';

import 'exceptions.dart';

/// Reads [answer], Smartschool's answer to [action] that should be XML, with
/// [parse], and throws a [SmartschoolException] for one that is not XML
/// (#106, #110, #112).
///
/// `SmartschoolClient.postXml` reads the answers of the XML dispatcher with
/// it ([action] is the command, such as `message list`), and
/// `MessagesService` the answers of its recipient search (`searchUsers`),
/// which is a form POST, not a command: so both tell the same answers apart.
///
/// - HTML, a page or a piece of one (see [_isHtmlAnswer]): a
///   [SmartschoolUnexpectedPageError] built from it, which says whether it is
///   Smartschool's login page, with the status, content type and URL of
///   [answer];
/// - an answer that does not start with `<`, an empty one included: a
///   [SmartschoolParsingError] with the status, content type and URL of
///   [answer], and the start of what it holds;
/// - XML that [parse] cannot read: [parse] throws a [FormatException] for it,
///   as `XmlInterface.parseResponse` does for malformed XML, and this throws
///   a [SmartschoolParsingError] with [action], the status, content type and
///   URL of [answer] and the parser's message, which says where the XML
///   breaks off, and not what the answer holds, which can name people.
///
/// So [parse] reads the XML only: a [FormatException] it throws for another
/// reason would be reported as malformed XML.
///
/// With [allowEmptyAnswer], an empty answer (no body, or white space only)
/// with status `200` goes to [parse] instead, which
/// `XmlInterface.parseResponse` reads as no elements. An empty answer with
/// another status still throws.
T readXmlAnswer<T>(
  Response<String> answer, {
  required String action,
  required T Function(String body) parse,
  bool allowEmptyAnswer = false,
}) {
  final body = answer.data ?? '';
  final trimmed = body.trimLeft();
  final status = answer.statusCode;

  if (allowEmptyAnswer && trimmed.isEmpty && status == HttpStatus.ok) {
    return parse(body);
  }

  final contentType = answer.headers.value(Headers.contentTypeHeader);
  if (_isHtmlAnswer(trimmed)) {
    throw SmartschoolUnexpectedPageError.fromPage(
      body,
      action: action,
      statusCode: status,
      url: answer.realUri,
      contentType: contentType,
    );
  }

  final details =
      'status ${status ?? 'unknown'}, '
      '${contentType == null ? '' : '$contentType, '}'
      'url: ${answer.realUri}';

  if (!trimmed.startsWith('<')) {
    throw SmartschoolParsingError(
      'Smartschool returned a non-XML response for "$action" ($details): '
      '${trimmed.isEmpty ? 'empty' : _preview(trimmed)}',
    );
  }

  try {
    return parse(body);
  } on FormatException catch (e) {
    // The parser's message says what is wrong and where (such as
    // "XmlTagException: Missing </message> at 33:29"), not the content of
    // the answer, which can name people (#110).
    throw SmartschoolParsingError(
      'Smartschool returned an answer for "$action" that is not '
      'well-formed XML ($details): ${e.message}',
    );
  }
}

/// Whether [body], an answer that should be XML without its leading white
/// space, is HTML: a page, or a piece of one (#106, #110).
///
/// After any white space, comments, processing instructions (such as the
/// XML declaration of an XHTML page) and doctypes other than HTML's, it
/// starts with an HTML doctype, or with the tag of an element of
/// [_htmlElements]. So a page with a comment before its doctype is one, and
/// so is a piece of a page such as the one Smartschool answers an XHR to a
/// module page with (`<!-- TRANSPARANT LAYER -->` and `<div>`s), also when
/// it happens to be well-formed XML. The answers of the XML dispatcher
/// (`<server>`, `<results>`, `<users>`) and of the recipient search
/// (`<results>`) are not.
bool _isHtmlAnswer(String body) {
  final start = _beforeContent.matchAsPrefix(body)?.end ?? 0;
  final content = _contentStart.matchAsPrefix(body, start);
  if (content == null) return false;
  final tag = content[1];
  return tag == null || _htmlElements.contains(tag.toLowerCase());
}

/// White space, comments, processing instructions and doctypes other than
/// HTML's: what can come before the content of a document.
final _beforeContent = RegExp(
  r'(?:\s|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!doctype\s+(?!html\b)[^>]*>)*',
  caseSensitive: false,
);

/// The start of the content of a document: an HTML doctype, or a start tag,
/// with its name.
final _contentStart = RegExp(
  r'<(?:!doctype\s+html\b|([a-z][a-z0-9-]*)(?=[\s/>]|$))',
  caseSensitive: false,
);

/// The elements that make an answer HTML when it starts with one: common
/// elements of HTML. The answers of the XML dispatcher and of the recipient
/// search start with none of them.
const _htmlElements = {
  'html', 'head', 'body', 'title', 'base', 'meta', 'link', // document
  'script', 'style', 'noscript', 'iframe', // scripts and frames
  'div', 'span', 'p', 'pre', 'blockquote', 'center', 'br', 'hr', // blocks
  'section', 'article', 'aside', 'nav', 'main', 'header', 'footer', // parts
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', // headings
  'a', 'b', 'i', 'u', 'em', 'strong', 'small', 'font', 'img', // inline
  'ul', 'ol', 'li', 'dl', // lists
  'table', 'thead', 'tbody', 'tr', 'td', 'th', // tables
  'form', 'input', 'button', 'select', 'textarea', // forms
};

String _preview(String body, {int max = 180}) {
  if (body.length <= max) return body;
  return '${body.substring(0, max)}...';
}
