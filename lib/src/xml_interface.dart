import 'package:xml/xml.dart';

/// Helper for Smartschool's bespoke XML-over-HTTP-POST protocol.
///
/// The protocol works as follows:
/// 1. Build an XML command with [buildCommand].
/// 2. POST it to a dispatcher URL as the form field `command`.
/// 3. Parse the XML response with [parseResponse] or [elementToMap].
///
/// This is a static helper class rather than the abstract base class used in
/// the Python version — services compose it directly instead of inheriting it.
class XmlInterface {
  XmlInterface._();

  /// Builds the XML command string for a Smartschool XML API call.
  ///
  /// Example output:
  /// ```xml
  /// <request><command>
  ///   <subsystem>postboxes</subsystem>
  ///   <action>message list</action>
  ///   <params>
  ///     <param name="boxType"><![CDATA[inbox]]></param>
  ///   </params>
  /// </command></request>
  /// ```
  static String buildCommand(
    String subsystem,
    String action,
    Map<String, String> params,
  ) {
    final buf = StringBuffer()
      ..write('<request><command>')
      ..write('<subsystem>$subsystem</subsystem>')
      ..write('<action>$action</action>')
      ..write('<params>');

    for (final entry in params.entries) {
      buf.write(
        '<param name="${_escapeAttr(entry.key)}">'
        '<![CDATA[${entry.value}]]></param>',
      );
    }

    buf.write('</params></command></request>');
    return buf.toString();
  }

  /// Parses a Smartschool XML response body and extracts the elements
  /// identified by the given [xpath] expression.
  ///
  /// Supported xpath format: `.//parent/child` — finds all `child` elements
  /// that are direct children of `parent` elements, anywhere in the tree.
  ///
  /// Each matched [XmlElement] is converted to a [Map<String, dynamic>] via
  /// [elementToMap] and returned as a list.
  static List<Map<String, dynamic>> parseResponse(
    String xmlBody,
    String xpath,
  ) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlBody);
    } catch (e) {
      throw FormatException('Failed to parse Smartschool XML response: $e');
    }
    return _findElements(doc, xpath).map(elementToMap).toList();
  }

  /// Recursively converts an [XmlElement] to a [Map<String, dynamic>].
  ///
  /// - Leaf nodes (no child elements) become their [String] text content.
  /// - Nested elements recurse into a [Map<String, dynamic>].
  /// - Multiple sibling elements with the same tag name become a [List].
  ///
  /// This mirrors the behaviour of Python's `common.xml_to_dict()`.
  static Map<String, dynamic> elementToMap(XmlElement element) {
    final result = <String, dynamic>{};

    for (final child in element.childElements) {
      final tag = child.name.local;
      final dynamic value;

      if (child.childElements.isEmpty) {
        value = child.innerText;
      } else {
        value = elementToMap(child);
      }

      final existing = result[tag];
      if (existing != null) {
        if (existing is List) {
          existing.add(value);
        } else {
          result[tag] = [existing, value];
        }
      } else {
        result[tag] = value;
      }
    }

    return result;
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  /// Finds XML elements described by a `.//parent/child` style [xpath].
  ///
  /// Algorithm:
  /// 1. Strip the leading `./` or `//` prefix.
  /// 2. Split on `/` to get the path parts, e.g. `['messages', 'message']`.
  /// 3. Find every descendant whose tag matches the first part.
  /// 4. From each such element, follow direct child links for the
  ///    remaining parts.
  static List<XmlElement> _findElements(XmlNode root, String xpath) {
    final path = xpath.replaceFirst(RegExp(r'^\./+|^//'), '');
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();

    if (parts.isEmpty) return [];

    if (parts.length == 1) {
      // Simple case: find all descendants with this tag.
      return root.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == parts[0])
          .toList();
    }

    // General case: first part is searched anywhere; remaining parts are
    // followed as direct child paths.
    final results = <XmlElement>[];
    for (final el in root.descendants.whereType<XmlElement>()) {
      if (el.name.local == parts[0]) {
        results.addAll(_followDirectPath(el, parts.sublist(1)));
      }
    }
    return results;
  }

  /// Walks [parts] down through direct children of [root], collecting leaves.
  static List<XmlElement> _followDirectPath(
    XmlElement root,
    List<String> parts,
  ) {
    if (parts.isEmpty) return [root];

    final tag = parts[0];
    final rest = parts.sublist(1);
    final results = <XmlElement>[];

    for (final child in root.childElements) {
      if (child.name.local == tag) {
        results.addAll(_followDirectPath(child, rest));
      }
    }
    return results;
  }

  /// Escapes a string for use as an XML attribute value (double-quoted).
  static String _escapeAttr(String value) =>
      value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
}
