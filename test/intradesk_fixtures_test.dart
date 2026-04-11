// Tests that parse the captured fixture JSON files into Intradesk model objects
// and validate that every field maps correctly.
//
// Fixture files live under:
//   test/fixtures/smartschool/requests/get/intradesk/api/v1/49/
//
// No live Smartschool session is required for these tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/src/models/intradesk_models.dart';
import 'package:test/test.dart';

String _readFixture(String path) => File(
  'test/fixtures/smartschool/requests/get/intradesk/api/v1/49/$path',
).readAsStringSync();

Map<String, dynamic> _jsonFixture(String path) =>
    jsonDecode(_readFixture(path)) as Map<String, dynamic>;

void main() {
  group('IntradeskListing (root) fixture', () {
    late IntradeskListing listing;

    setUpAll(() {
      listing = IntradeskListing.fromJson(
        _jsonFixture('directory-listing/fortreeonlyfolders.json'),
      );
    });

    test('parses two folders', () {
      expect(listing.folders, hasLength(2));
    });

    test('first folder – basic fields', () {
      final f = listing.folders.first;
      expect(f.id, 'aaaa1111-1111-4111-b111-111111111111');
      expect(f.name, 'Documenten');
      expect(f.color, 'yellow');
      expect(f.state, 'active');
      expect(f.visible, isTrue);
      expect(f.confidential, isFalse);
      expect(f.officeTemplateFolder, isFalse);
      expect(f.parentFolderId, isEmpty);
      expect(f.hasChildren, isTrue);
      expect(f.isFavourite, isFalse);
      expect(f.inConfidentialFolder, isFalse);
    });

    test('first folder – platform', () {
      final p = listing.folders.first.platform;
      expect(p.id, 49);
      expect(p.name, 'Testschool');
    });

    test('first folder – capabilities', () {
      final c = listing.folders.first.capabilities;
      expect(c.canManage, isFalse);
      expect(c.canAdd, isFalse);
      expect(c.canSeeHistory, isFalse);
      expect(c.canSeeViewHistory, isFalse);
    });

    test('first folder – dates parse without throwing', () {
      final f = listing.folders.first;
      expect(f.dateCreated, isA<DateTime>());
      expect(f.dateChanged, isA<DateTime>());
      expect(f.dateStateChanged, isA<DateTime>());
    });

    test('second folder has no children', () {
      expect(listing.folders[1].hasChildren, isFalse);
      expect(listing.folders[1].id, 'aaaa2222-2222-4222-b222-222222222222');
    });

    test('parses one file', () {
      expect(listing.files, hasLength(1));
    });

    test('file – basic fields', () {
      final file = listing.files.first;
      expect(file.id, 'cccc1111-1111-4111-b111-111111111111');
      expect(file.name, 'welkom.docx');
      expect(file.state, 'active');
      expect(file.parentFolderId, isEmpty);
      expect(file.isFavourite, isFalse);
      expect(file.confidential, isFalse);
      expect(file.ownerId, '49_1001_0');
    });

    test('file – capabilities', () {
      final c = listing.files.first.capabilities;
      expect(c.canManage, isFalse);
      expect(c.canMove, isFalse);
      expect(c.canHandleRevisions, isFalse);
    });

    test('file – currentRevision present', () {
      final rev = listing.files.first.currentRevision;
      expect(rev, isNotNull);
      expect(rev!.id, 'dddd1111-1111-4111-b111-111111111111');
      expect(rev.fileId, 'cccc1111-1111-4111-b111-111111111111');
      expect(rev.fileSize, 182108);
      expect(rev.label, 'welkom.docx');
      expect(rev.dateCreated, isA<DateTime>());
    });

    test('file – revision owner', () {
      final owner = listing.files.first.currentRevision!.owner;
      expect(owner.userIdentifier, '49_1001_0');
      expect(owner.name, 'Jan Janssens');
      expect(owner.nameReverse, 'Janssens Jan');
      expect(owner.userPictureUrl, contains('example.com'));
    });

    test('weblinks list is empty', () {
      expect(listing.weblinks, isEmpty);
    });
  });

  group('IntradeskListing (subfolder aaaa1111) fixture', () {
    late IntradeskListing listing;

    setUpAll(() {
      listing = IntradeskListing.fromJson(
        _jsonFixture(
          'directory-listing/fortreeonlyfolders/aaaa1111-1111-4111-b111-111111111111.json',
        ),
      );
    });

    test('one sub-folder', () {
      expect(listing.folders, hasLength(1));
      final f = listing.folders.first;
      expect(f.id, 'bbbb1111-1111-4111-b111-111111111111');
      expect(f.name, 'Archief');
      expect(f.parentFolderId, 'aaaa1111-1111-4111-b111-111111111111');
      expect(f.hasChildren, isFalse);
    });

    test('one file in subfolder', () {
      expect(listing.files, hasLength(1));
      final file = listing.files.first;
      expect(file.id, 'cccc2222-2222-4222-b222-222222222222');
      expect(file.name, 'info.pdf');
      expect(file.parentFolderId, 'aaaa1111-1111-4111-b111-111111111111');
    });

    test('subfolder file – revision size', () {
      expect(listing.files.first.currentRevision!.fileSize, 51050);
    });
  });

  group('IntradeskListing (subfolder aaaa2222) fixture – empty', () {
    late IntradeskListing listing;

    setUpAll(() {
      listing = IntradeskListing.fromJson(
        _jsonFixture(
          'directory-listing/fortreeonlyfolders/aaaa2222-2222-4222-b222-222222222222.json',
        ),
      );
    });

    test('no folders', () => expect(listing.folders, isEmpty));
    test('no files', () => expect(listing.files, isEmpty));
    test('no weblinks', () => expect(listing.weblinks, isEmpty));
  });

  group('IntradeskListing.toString', () {
    test('includes counts', () {
      final l = IntradeskListing(
        folders: const [],
        files: const [],
        weblinks: const [],
      );
      expect(l.toString(), contains('folders: 0'));
      expect(l.toString(), contains('files: 0'));
    });
  });
}
