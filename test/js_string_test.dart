// Tests for issue #213: unescapeJsString undoes the escapes of the
// JavaScript string that a Smartschool page hands its page data in
// (`JSON.parse('...')`), in one pass. The session reads the authenticated
// user with it (test/session_page_data_test.dart) and the Intradesk service
// the capabilities of the root (test/intradesk_write_test.dart).
import 'package:flutter_smartschool/src/js_string.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';

void main() {
  forbidRealNetwork();

  group('unescapeJsString (#213)', () {
    test(r'undoes \\ and \/ in the same pass: the \\\/ of a URL in the page '
        r'data gives the \/ of its JSON', () {
      expect(
        unescapeJsString(r'"https:\\\/\\\/school.smartschool.be\\\/"'),
        r'"https:\/\/school.smartschool.be\/"',
      );
    });

    test(
      r'reads no \u escape in an escaped \ before u and four hex digits',
      () {
        expect(unescapeJsString(r'\\u00E9'), r'\u00E9');
        expect(unescapeJsString(r'\\\u00E9'), '\\é');
      },
    );

    test(r'gives the UTF-16 code unit of \uXXXX, in upper or lower case, so '
        'the two surrogates of a character outside the BMP give it', () {
      expect(unescapeJsString(r'\u0022\u00e9\u00C9'), '"éÉ');
      expect(unescapeJsString(r'\uD83D\uDE00'), '\u{1F600}');
    });

    test(r'gives the character of \xXX', () {
      expect(unescapeJsString(r'\x41\x2f'), 'A/');
    });

    test(r'undoes \n, \r, \t, \b, \f and \v', () {
      expect(unescapeJsString(r'a\nb\rc\td\be\ff\vg'), 'a\nb\rc\td\be\ff\vg');
    });

    test(r'gives the character after any other \, and nothing for a \ '
        'before a line break', () {
      expect(unescapeJsString(r'''\'\"\/\a'''), '\'"/a');
      expect(unescapeJsString('a\\\nb'), 'ab');
    });

    test(r'reads a \u or \x without its hex digits as the letter, and keeps a '
        r'\ at the end', () {
      expect(unescapeJsString(r'\u12G4'), 'u12G4');
      expect(unescapeJsString(r'\u+123 \x-1'), 'u+123 x-1');
      expect(unescapeJsString(r'\u12'), 'u12');
      expect(unescapeJsString(r'end\'), r'end\');
    });

    test('keeps a text without escapes as it is', () {
      expect(unescapeJsString(''), '');
      expect(unescapeJsString('{"vars":{}}'), '{"vars":{}}');
    });
  });
}
