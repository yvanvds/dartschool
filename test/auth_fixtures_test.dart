import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

void main() {
  group('Smartschool auth fixtures', () {
    test('all captured response files are mirrored into test fixtures', () {
      final source = Directory('smartschool/tests/requests');
      final target = Directory('test/fixtures/smartschool/requests');

      expect(
        source.existsSync(),
        isTrue,
        reason: 'Source fixture tree is missing',
      );
      expect(
        target.existsSync(),
        isTrue,
        reason: 'Target fixture tree is missing',
      );

      final sourceFiles = source
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => _relativePath(source.path, f.path))
          .toSet();

      final targetFiles = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => _relativePath(target.path, f.path))
          .toSet();

      expect(
        targetFiles,
        sourceFiles,
        reason: 'Fixture mirror diverged. Run tool/sync_all_fixtures.ps1',
      );
    });

    test('login fixture contains login_form and hidden token fields', () {
      final html = _readFixture('get/login.json');
      final doc = html_parser.parse(html);

      final form = doc.querySelector('form[name="login_form"]');
      expect(form, isNotNull);

      final username = form!.querySelector('input[name*="_username"]');
      final password = form.querySelector('input[name*="_password"]');
      final token = form.querySelector('input[name*="_token"]');

      expect(username, isNotNull);
      expect(password, isNotNull);
      expect(token, isNotNull);
    });

    test('account verification fixture contains account_verification_form', () {
      final html = _readFixture('get/account-verification.json');
      final doc = html_parser.parse(html);

      final form = doc.querySelector('form[name="account_verification_form"]');
      expect(form, isNotNull);

      final answer = form!.querySelector(
        'input[name*="_security_question_answer"]',
      );
      final token = form.querySelector('input[name*="_token"]');

      expect(answer, isNotNull);
      expect(token, isNotNull);
    });

    test('raw .html fixtures are present and parse as HTML documents', () {
      final composeNew = _readFixture('get/composemessage/new-message.html');
      final composeSend = _readFixture('post/composemessage/on_send.html');

      final doc1 = html_parser.parse(composeNew);
      final doc2 = html_parser.parse(composeSend);

      expect(doc1.querySelector('html'), isNotNull);
      expect(doc2.querySelector('html'), isNotNull);
    });
  });
}

String _readFixture(String relativePath) {
  final file = File('test/fixtures/smartschool/requests/$relativePath');
  if (!file.existsSync()) {
    fail('Missing fixture file: ${file.path}');
  }
  return file.readAsStringSync();
}

String _relativePath(String rootPath, String fullPath) {
  final normalizedRoot = rootPath.replaceAll('\\', '/');
  final normalizedFull = fullPath.replaceAll('\\', '/');
  if (!normalizedFull.startsWith(normalizedRoot)) {
    return normalizedFull;
  }
  var rel = normalizedFull.substring(normalizedRoot.length);
  if (rel.startsWith('/')) rel = rel.substring(1);
  return rel;
}
