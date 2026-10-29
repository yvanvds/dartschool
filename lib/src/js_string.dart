/// The text of the JavaScript string literal whose content (between its
/// quotes) is [literal]: its escapes undone, in one pass from left to right
/// (#138, #213).
///
/// Smartschool's pages hand their page data to their scripts as
/// `JSON.parse('...')`, with the JSON written into the string with the `js`
/// escaping of its templates (Twig's): letters, digits, `,`, `.` and `_` stay
/// as they are, `\` becomes `\\`, `/` becomes `\/`, a line break, tab and
/// the like `\n`, `\t`, ..., and every other character `\uXXXX` (one outside
/// the BMP as the two of its UTF-16 surrogates). The JSON itself has `/` as
/// `\/`, as PHP's `json_encode` writes it, so the `/` of a URL is `\\\/` on
/// the page: this gives `\/` of it, which `jsonDecode` reads as `/`.
///
/// Undone: `\u` with four hex digits and `\x` with two, to that UTF-16 code
/// unit; `\n`, `\r`, `\t`, `\b`, `\f` and `\v`; a `\` before a line break (a
/// line continuation), to nothing; and a `\` before any other character, to
/// that character (`\\` to `\`, `\/` to `/`, `\'` to `'`). A `\` at the end
/// stays.
///
/// In one pass, so that no escape is read as part of another: undoing every
/// `\uXXXX` first and then every `\\` turned the `\\\/` of a URL into `\\/`,
/// which `jsonDecode` reads as `\/` (#213), and would turn `\\u00E9`, an
/// escaped `\` before `u00E9` (the `é` of a JSON that writes it as `\u00E9`),
/// into `\é`, which is no JSON.
String unescapeJsString(String literal) {
  final out = StringBuffer();
  for (var i = 0; i < literal.length; i++) {
    final char = literal[i];
    if (char != r'\' || i + 1 == literal.length) {
      out.write(char);
      continue;
    }
    final escaped = literal[++i];
    final hexDigits = switch (escaped) {
      'u' => 4,
      'x' => 2,
      _ => 0,
    };
    if (hexDigits > 0 && i + hexDigits < literal.length) {
      final hex = literal.substring(i + 1, i + 1 + hexDigits);
      // Hex digits only: int.parse would also take a sign and white space.
      if (_hexDigits.hasMatch(hex)) {
        out.writeCharCode(int.parse(hex, radix: 16));
        i += hexDigits;
        continue;
      }
    }
    switch (escaped) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'v':
        out.write('\v');
      case '\n':
        break; // A line continuation.
      default:
        out.write(escaped);
    }
  }
  return out.toString();
}

final _hexDigits = RegExp(r'^[0-9A-Fa-f]+$');
