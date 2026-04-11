// Tests for Intradesk model parsing logic that can be validated offline
// (i.e. without a live Smartschool session).
//
// Coverage:
// - [IntradeskListing.fromJson] with inline JSON (edge cases & missing fields)
// - [IntradeskFolder.fromJson]  / [IntradeskFile.fromJson] field mapping
// - [IntradeskFileRevision] / [IntradeskFileOwner] construction
// - Guard-rail behaviour when optional sub-objects are absent
// - toString helpers
//
// End-to-end tests that require an authenticated session are in
// `example/send_message_lifecycle_example.dart` (messages) and the live MCP
// researcher for intradesk.

import 'dart:convert';

import 'package:flutter_smartschool/src/models/intradesk_models.dart';
import 'package:test/test.dart';

Map<String, dynamic> _j(String src) => jsonDecode(src) as Map<String, dynamic>;

void main() {
  // -------------------------------------------------------------------------
  // IntradeskPlatform
  // -------------------------------------------------------------------------

  group('IntradeskPlatform.fromJson', () {
    test('parses id and name', () {
      final p = IntradeskPlatform.fromJson(
        _j('{"id": 4069, "name": "Mijn school"}'),
      );
      expect(p.id, 4069);
      expect(p.name, 'Mijn school');
    });

    test('toString contains id and name', () {
      final p = IntradeskPlatform(id: 1, name: 'Test');
      expect(p.toString(), contains('1'));
      expect(p.toString(), contains('Test'));
    });
  });

  // -------------------------------------------------------------------------
  // IntradeskFolderCapabilities
  // -------------------------------------------------------------------------

  group('IntradeskFolderCapabilities.fromJson', () {
    test('all-false capabilities', () {
      final c = IntradeskFolderCapabilities.fromJson(
        _j(
          '{"canManage":false,"canAdd":false,"canSeeHistory":false,"canSeeViewHistory":false}',
        ),
      );
      expect(c.canManage, isFalse);
      expect(c.canAdd, isFalse);
    });

    test('all-true capabilities', () {
      final c = IntradeskFolderCapabilities.fromJson(
        _j(
          '{"canManage":true,"canAdd":true,"canSeeHistory":true,"canSeeViewHistory":true}',
        ),
      );
      expect(c.canManage, isTrue);
      expect(c.canAdd, isTrue);
      expect(c.canSeeHistory, isTrue);
      expect(c.canSeeViewHistory, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // IntradeskFileCapabilities
  // -------------------------------------------------------------------------

  group('IntradeskFileCapabilities.fromJson', () {
    test('parses all five fields', () {
      final c = IntradeskFileCapabilities.fromJson(
        _j(
          '{"canManage":true,"canMove":false,"canHandleRevisions":true,'
          '"canSeeHistory":false,"canSeeViewHistory":true}',
        ),
      );
      expect(c.canManage, isTrue);
      expect(c.canMove, isFalse);
      expect(c.canHandleRevisions, isTrue);
      expect(c.canSeeHistory, isFalse);
      expect(c.canSeeViewHistory, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // IntradeskFolder
  // -------------------------------------------------------------------------

  group('IntradeskFolder.fromJson', () {
    const rootFolderJson = '''
    {
      "id": "aaaa1111-1111-4111-b111-111111111111",
      "platform": {"id": 49, "name": "Testschool"},
      "name": "Documenten",
      "color": "blue",
      "state": "active",
      "visible": true,
      "confidential": false,
      "officeTemplateFolder": false,
      "parentFolderId": "",
      "dateStateChanged": "2020-01-15T10:00:00+01:00",
      "dateCreated": "2019-09-01T08:00:00+01:00",
      "dateChanged": "2024-08-29T17:01:56+02:00",
      "isFavourite": true,
      "inConfidentialFolder": false,
      "capabilities": {"canManage": true, "canAdd": true, "canSeeHistory": false, "canSeeViewHistory": false},
      "hasChildren": true
    }
    ''';

    late IntradeskFolder folder;
    setUpAll(() => folder = IntradeskFolder.fromJson(_j(rootFolderJson)));

    test('id', () => expect(folder.id, 'aaaa1111-1111-4111-b111-111111111111'));
    test('name', () => expect(folder.name, 'Documenten'));
    test('color', () => expect(folder.color, 'blue'));
    test('visible', () => expect(folder.visible, isTrue));
    test(
      'parentFolderId is empty at root',
      () => expect(folder.parentFolderId, isEmpty),
    );
    test('hasChildren', () => expect(folder.hasChildren, isTrue));
    test('isFavourite', () => expect(folder.isFavourite, isTrue));
    test(
      'capabilities.canManage',
      () => expect(folder.capabilities.canManage, isTrue),
    );
    test('platform.name', () => expect(folder.platform.name, 'Testschool'));

    test('toString contains id and name', () {
      expect(folder.toString(), contains('aaaa1111'));
      expect(folder.toString(), contains('Documenten'));
    });
  });

  group('IntradeskFolder – missing capabilities object', () {
    test('defaults to all-false capabilities', () {
      final folder = IntradeskFolder.fromJson(
        _j('''
      {
        "id": "x",
        "platform": {"id": 1, "name": ""},
        "name": "Test",
        "color": "",
        "state": "active",
        "visible": false,
        "confidential": false,
        "officeTemplateFolder": false,
        "parentFolderId": "",
        "dateStateChanged": "2020-01-01T00:00:00+00:00",
        "dateCreated":      "2020-01-01T00:00:00+00:00",
        "dateChanged":      "2020-01-01T00:00:00+00:00",
        "isFavourite": false,
        "inConfidentialFolder": false,
        "hasChildren": false
      }
      '''),
      );
      expect(folder.capabilities.canManage, isFalse);
      expect(folder.capabilities.canAdd, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // IntradeskFile
  // -------------------------------------------------------------------------

  group('IntradeskFile.fromJson', () {
    const fileJson = '''
    {
      "id": "cccc1111-1111-4111-b111-111111111111",
      "platform": {"id": 49, "name": "Testschool"},
      "name": "bureau.pdf",
      "state": "active",
      "parentFolderId": "aaaa1111-1111-4111-b111-111111111111",
      "dateCreated":      "2023-02-13T10:38:11+01:00",
      "dateStateChanged": "2023-02-13T10:38:11+01:00",
      "dateChanged":      "2023-02-13T10:38:11+01:00",
      "currentRevision": {
        "id": "dddd1111-1111-4111-b111-111111111111",
        "platform": {"id": 49, "name": "Testschool"},
        "fileId": "cccc1111-1111-4111-b111-111111111111",
        "fileSize": 99000,
        "dateCreated": "2023-02-13T10:38:11+01:00",
        "label": "bureau.pdf",
        "owner": {
          "userIdentifier": "49_1001_0",
          "userPictureHash": "initials_JJ",
          "userPictureUrl": "https://example.com/pic",
          "name": "Jan Janssens",
          "nameReverse": "Janssens Jan",
          "description": "",
          "descriptionReverse": ""
        }
      },
      "isFavourite": false,
      "confidential": true,
      "ownerId": "49_1001_0",
      "capabilities": {"canManage": false, "canMove": false,
                       "canHandleRevisions": false, "canSeeHistory": false,
                       "canSeeViewHistory": false}
    }
    ''';

    late IntradeskFile file;
    setUpAll(() => file = IntradeskFile.fromJson(_j(fileJson)));

    test('id', () => expect(file.id, 'cccc1111-1111-4111-b111-111111111111'));
    test('name', () => expect(file.name, 'bureau.pdf'));
    test('confidential', () => expect(file.confidential, isTrue));
    test(
      'parentFolderId',
      () => expect(file.parentFolderId, 'aaaa1111-1111-4111-b111-111111111111'),
    );
    test('ownerId', () => expect(file.ownerId, '49_1001_0'));

    test(
      'currentRevision – present',
      () => expect(file.currentRevision, isNotNull),
    );

    test(
      'currentRevision.fileSize',
      () => expect(file.currentRevision!.fileSize, 99000),
    );

    test(
      'currentRevision.label',
      () => expect(file.currentRevision!.label, 'bureau.pdf'),
    );

    test(
      'currentRevision.owner.name',
      () => expect(file.currentRevision!.owner.name, 'Jan Janssens'),
    );

    test('toString contains id and name', () {
      expect(file.toString(), contains('cccc1111'));
      expect(file.toString(), contains('bureau.pdf'));
    });
  });

  group('IntradeskFile – missing currentRevision', () {
    test('currentRevision is null when key absent', () {
      final file = IntradeskFile.fromJson(
        _j('''
      {
        "id": "x",
        "platform": {"id": 1, "name": ""},
        "name": "no-rev.txt",
        "state": "active",
        "parentFolderId": "",
        "dateCreated":      "2020-01-01T00:00:00+00:00",
        "dateStateChanged": "2020-01-01T00:00:00+00:00",
        "dateChanged":      "2020-01-01T00:00:00+00:00",
        "isFavourite": false,
        "confidential": false,
        "ownerId": "",
        "capabilities": {"canManage": false, "canMove": false,
                         "canHandleRevisions": false, "canSeeHistory": false,
                         "canSeeViewHistory": false}
      }
      '''),
      );
      expect(file.currentRevision, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // IntradeskListing
  // -------------------------------------------------------------------------

  group('IntradeskListing.fromJson', () {
    test('empty listing', () {
      final l = IntradeskListing.fromJson(
        _j('{"folders":[],"files":[],"weblinks":[]}'),
      );
      expect(l.folders, isEmpty);
      expect(l.files, isEmpty);
      expect(l.weblinks, isEmpty);
    });

    test('handles missing keys gracefully', () {
      // An empty map should produce an empty listing rather than throwing.
      final l = IntradeskListing.fromJson({});
      expect(l.folders, isEmpty);
      expect(l.files, isEmpty);
      expect(l.weblinks, isEmpty);
    });

    test('toString reports counts correctly', () {
      const l = IntradeskListing(folders: [], files: [], weblinks: []);
      final s = l.toString();
      expect(s, contains('folders: 0'));
      expect(s, contains('files: 0'));
      expect(s, contains('weblinks: 0'));
    });
  });
}
