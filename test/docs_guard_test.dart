// Guard for #199: README.md and CHANGELOG.md stay under pub.dev's limit,
// and the links of the README and of doc/ lead somewhere.
//
// pub.dev refuses a package whose README.md or CHANGELOG.md is larger than
// 262144 bytes (256 KB) at upload; `dart pub publish --dry-run` does not
// check it. It refused 0.3.6 for its CHANGELOG.md (the oldest full entries
// then moved to doc/CHANGELOG-archive.md), and #199 moved the reference of
// each service from the README to doc/. This test fails from [docsMaxBytes]
// on, a margin under the limit, so that the feature that crosses it fails
// here and not at the release: put the reference it adds in the service's
// file in doc/ (the README keeps an overview and a short example of each
// service), and archive the oldest full entries of the CHANGELOG in
// doc/CHANGELOG-archive.md.
//
// It also checks every relative link of README.md and of the Markdown files
// in doc/: the file or folder it names exists, and so does the heading its
// `#anchor` names, as GitHub makes the anchor of a heading. pub.dev rewrites
// a relative link of the README to the file in the repository on GitHub.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/no_network.dart';

/// pub.dev's limit on the size of README.md and CHANGELOG.md, in bytes.
const pubDevMaxBytes = 262144;

/// The size from which this test fails, in bytes: some 22 KB under
/// [pubDevMaxBytes].
const docsMaxBytes = 240000;

/// The files whose size pub.dev limits.
const limitedFiles = ['README.md', 'CHANGELOG.md'];

/// The folder of the reference that moved out of the README.
const docFolder = 'doc';

/// The target of a Markdown link or image: `](target)`, without spaces.
final _linkTarget = RegExp(r'\]\(([^)\s]+)\)');

/// An inline code span, which holds no link.
final _codeSpan = RegExp(r'`[^`\n]*`');

/// A heading: one to six `#`, then its text (without closing `#`s).
final _heading = RegExp(r'^#{1,6}\s+(.*?)(?:\s+#+)?\s*$');

/// A line that opens or closes a fenced code block.
final _fence = RegExp(r'^\s*(```|~~~)');

/// A target with a scheme (`https:`, `mailto:`), not a relative link.
final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// The lines of [markdown] outside its fenced code blocks.
Iterable<String> proseLines(String markdown) sync* {
  var inFence = false;
  for (final line in markdown.split('\n')) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (!inFence) yield line;
  }
}

/// The anchor GitHub gives a heading with [text]: in lower case, without
/// punctuation (so without the backticks of a code span), its spaces as
/// `-`.
String githubSlug(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}_\- ]', unicode: true), '')
    .replaceAll(' ', '-');

/// The anchors of the headings of [markdown], as GitHub makes them: a
/// heading whose anchor an earlier one has gets `-1`, `-2`, ... appended.
Set<String> headingAnchors(String markdown) {
  final anchors = <String>{};
  for (final line in proseLines(markdown)) {
    final match = _heading.firstMatch(line);
    if (match == null) continue;
    final slug = githubSlug(match.group(1)!);
    var anchor = slug;
    for (var n = 1; anchors.contains(anchor); n++) {
      anchor = '$slug-$n';
    }
    anchors.add(anchor);
  }
  return anchors;
}

/// The relative link targets of [markdown], outside code, in order.
List<String> relativeLinks(String markdown) => [
  for (final line in proseLines(markdown))
    for (final match in _linkTarget.allMatches(line.replaceAll(_codeSpan, '')))
      if (!_scheme.hasMatch(match.group(1)!)) match.group(1)!,
];

/// What is wrong with each relative link of the Markdown file at [path]
/// (relative to the package root): a file that does not exist, or an anchor
/// no heading of its target has. Empty when every link leads somewhere.
List<String> brokenLinks(String path) {
  final problems = <String>[];
  final anchorsOf = <String, Set<String>>{};
  Set<String> anchors(String file) => anchorsOf.putIfAbsent(
    file,
    () => headingAnchors(File(file).readAsStringSync()),
  );
  for (final link in relativeLinks(File(path).readAsStringSync())) {
    final hash = link.indexOf('#');
    final target = hash < 0 ? link : link.substring(0, hash);
    final anchor = hash < 0 ? null : link.substring(hash + 1);
    final file = target.isEmpty
        ? path
        : p.normalize(p.join(p.dirname(path), Uri.decodeFull(target)));
    if (!File(file).existsSync() && !Directory(file).existsSync()) {
      problems.add('$path: $link: no file $file');
    } else if (anchor != null &&
        file.endsWith('.md') &&
        !anchors(file).contains(anchor)) {
      problems.add('$path: $link: no heading with anchor #$anchor in $file');
    }
  }
  return problems;
}

void main() {
  forbidRealNetwork();

  group('pub.dev size limit', () {
    for (final name in limitedFiles) {
      test('$name is under $docsMaxBytes bytes', () {
        final size = File(name).lengthSync();
        expect(
          size,
          lessThan(docsMaxBytes),
          reason:
              '$name is $size bytes; pub.dev refuses it above $pubDevMaxBytes '
              'at upload. Move reference from README.md to its file in '
              '$docFolder/, or the oldest full CHANGELOG.md entries to '
              '$docFolder/CHANGELOG-archive.md.',
        );
      });
    }
  });

  group('links', () {
    final files = [
      'README.md',
      ...Directory(docFolder)
          .listSync()
          .whereType<File>()
          .map((file) => p.split(p.relative(file.path)).join('/'))
          .where((path) => path.endsWith('.md'))
          .toList()
        ..sort(),
    ];

    for (final path in files) {
      test('every relative link of $path leads to a file and heading', () {
        expect(brokenLinks(path), isEmpty);
      });
    }

    test('the README links to the reference of every service in doc/', () {
      final readmeLinks = relativeLinks(File('README.md').readAsStringSync());
      final docFiles = files.where(
        (path) =>
            path.startsWith('$docFolder/') &&
            path != '$docFolder/CHANGELOG-archive.md',
      );
      for (final path in docFiles) {
        expect(
          readmeLinks.any((link) => link.split('#').first == path),
          isTrue,
          reason: 'README.md links to no $path',
        );
      }
    });
  });

  group('githubSlug and headingAnchors', () {
    test('make the anchors GitHub makes', () {
      expect(githubSlug('`SkoreService`'), 'skoreservice');
      expect(githubSlug('Composing & searching'), 'composing--searching');
      expect(
        githubSlug('Static parsers (exposed for testing)'),
        'static-parsers-exposed-for-testing',
      );
      expect(
        headingAnchors(
          '# A\n## Methods\n```\n# not a heading\n```\n## Methods',
        ),
        {'a', 'methods', 'methods-1'},
      );
    });

    test('relativeLinks leaves out absolute links and code', () {
      expect(
        relativeLinks(
          '[a](doc/a.md#x) [b](https://x.y) `[c](d)`\n```\n[e](f)\n```',
        ),
        ['doc/a.md#x'],
      );
    });
  });
}
