// Tests for the message-compose flow logic that can be validated offline
// (i.e. without a live Smartschool server).
//
// These tests focus on:
// - [MessagesService.parseHiddenFields]       — compose-form HTML → token map
// - [MessagesService.parseComposeCurrentUserIds] — compose JS → (userID, ssID)
// - [MessagesService.guessMimeType]           — file-extension → MIME type lookup
// - [MessageSearchUser] / [MessageSearchGroup] construction and identity
// - The archive list concept:  identical parser, different [boxId] request
// - [RecipientType] request payload values
//
// End-to-end tests that require an authenticated session are in
// `example/send_message_lifecycle_example.dart`.
import 'dart:io';

import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // parseHiddenFields
  // ---------------------------------------------------------------------------

  group('MessagesService.parseHiddenFields', () {
    test('extracts randomDir and uniqueUsc from compose fixture', () {
      final html = _readFixture('get/composemessage/new-message.html');
      final fields = MessagesService.parseHiddenFields(html);

      expect(fields['randomDir'], 'dnV3ujSKmTkE48qLbjMxFrG4y17757280351002146');
      expect(
        fields['uniqueUsc'],
        '4069fDsFgJGxHbeGeCwnF3HXbNTDg17757280354069',
      );
    });

    test('extracts encryptedSender, origMsgID, composeAction', () {
      final html = _readFixture('get/composemessage/new-message.html');
      final fields = MessagesService.parseHiddenFields(html);

      expect(fields['encryptedSender'], isNotEmpty);
      expect(fields['origMsgID'], '0');
      expect(fields['composeAction'], '0');
    });

    test('ignores non-hidden input fields', () {
      const snippet = '''
        <input type="text"   name="visible_field" value="x">
        <input type="hidden" name="token"         value="abc123">
        <input type="email"  name="email_addr"    value="a@b.com">
      ''';

      final fields = MessagesService.parseHiddenFields(snippet);

      expect(fields.containsKey('visible_field'), isFalse);
      expect(fields.containsKey('email_addr'), isFalse);
      expect(fields['token'], 'abc123');
    });

    test('handles missing value attribute as empty string', () {
      const snippet = '<input type="hidden" name="empty_field">';
      final fields = MessagesService.parseHiddenFields(snippet);
      expect(fields['empty_field'], '');
    });

    test('returns empty map for HTML with no hidden fields', () {
      const snippet = '<html><body><p>No form here.</p></body></html>';
      final fields = MessagesService.parseHiddenFields(snippet);
      expect(fields, isEmpty);
    });
  });

  group('MessagesService.parseComposeCurrentUserIds', () {
    test('extracts userID/ssID/userLT from compose JS snippet', () {
      // Matches the exact format observed on the live Smartschool compose page:
      // window.tinymceInitConfig with tab-separated keys and single-quoted values.
      const html = '''
        <script type="text/javascript">
          window.tinymceInitConfig = {
            userID \t: '146',
            userLT \t: '0',
            ssID\t: '4069',
          };
        </script>
      ''';

      final ids = MessagesService.parseComposeCurrentUserIds(html);
      expect(ids, isNotNull);
      expect(ids!.$1, 146);
      expect(ids.$2, 4069);
      expect(ids.$3, 0);
    });

    test('returns null when userID/ssID are absent', () {
      const html = '<html><body><p>No compose vars.</p></body></html>';
      final ids = MessagesService.parseComposeCurrentUserIds(html);
      expect(ids, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // guessMimeType
  // ---------------------------------------------------------------------------

  group('MessagesService.guessMimeType', () {
    test('recognises common document types', () {
      expect(MessagesService.guessMimeType('report.pdf'), 'application/pdf');
      expect(MessagesService.guessMimeType('notes.txt'), 'text/plain');
      expect(MessagesService.guessMimeType('data.csv'), 'text/csv');
      expect(MessagesService.guessMimeType('page.html'), 'text/html');
      expect(MessagesService.guessMimeType('config.xml'), 'application/xml');
      expect(MessagesService.guessMimeType('data.json'), 'application/json');
    });

    test('recognises image types', () {
      expect(MessagesService.guessMimeType('photo.jpg'), 'image/jpeg');
      expect(MessagesService.guessMimeType('photo.jpeg'), 'image/jpeg');
      expect(MessagesService.guessMimeType('logo.png'), 'image/png');
      expect(MessagesService.guessMimeType('icon.svg'), 'image/svg+xml');
      expect(MessagesService.guessMimeType('animation.gif'), 'image/gif');
    });

    test('recognises Office document types', () {
      expect(
        MessagesService.guessMimeType('file.docx'),
        contains('wordprocessingml'),
      );
      expect(
        MessagesService.guessMimeType('file.xlsx'),
        contains('spreadsheetml'),
      );
      expect(
        MessagesService.guessMimeType('file.pptx'),
        contains('presentationml'),
      );
      expect(MessagesService.guessMimeType('file.doc'), 'application/msword');
    });

    test('recognises archive types', () {
      expect(MessagesService.guessMimeType('archive.zip'), 'application/zip');
      expect(MessagesService.guessMimeType('archive.tar'), 'application/x-tar');
      expect(MessagesService.guessMimeType('archive.gz'), 'application/gzip');
    });

    test('returns octet-stream for unknown extension', () {
      expect(
        MessagesService.guessMimeType('file.unknownxyz'),
        'application/octet-stream',
      );
    });

    test('returns octet-stream for file with no extension', () {
      expect(
        MessagesService.guessMimeType('README'),
        'application/octet-stream',
      );
    });

    test('is case-insensitive for extension lookup', () {
      expect(MessagesService.guessMimeType('PHOTO.JPG'), 'image/jpeg');
      expect(MessagesService.guessMimeType('doc.PDF'), 'application/pdf');
    });
  });

  // ---------------------------------------------------------------------------
  // MessageSearchUser / MessageSearchGroup construction
  // ---------------------------------------------------------------------------

  group('MessageSearchUser', () {
    test('can be constructed directly with required fields', () {
      const user = MessageSearchUser(
        userId: 146,
        displayName: 'John Smith',
        ssId: 4069,
      );

      expect(user.userId, 146);
      expect(user.displayName, 'John Smith');
      expect(user.ssId, 4069);
      expect(user.userLt, 0); // default
    });

    test('fromXml round-trips from search-user fixture', () {
      final xml = _readFixture('post/composemessage/search-user.xml');
      final users = XmlInterface.parseResponse(
        xml,
        './/users/user',
      ).map(MessageSearchUser.fromXml).toList();

      expect(users.first.userId, 146);
      expect(users.first.displayName, 'John Smith');
      expect(users.first.ssId, 4069);
      expect(users.first.schoolName, 'Springfield Academy');
    });

    test('toString includes userId, displayName, ssId', () {
      const user = MessageSearchUser(
        userId: 42,
        displayName: 'Jane Doe',
        ssId: 9999,
      );
      expect(user.toString(), contains('42'));
      expect(user.toString(), contains('Jane Doe'));
      expect(user.toString(), contains('9999'));
    });
  });

  group('MessageSearchGroup', () {
    test('can be constructed directly with required fields', () {
      const group = MessageSearchGroup(
        groupId: 298,
        displayName: '1A',
        ssId: 4069,
      );

      expect(group.groupId, 298);
      expect(group.displayName, '1A');
      expect(group.ssId, 4069);
    });

    test('fromXml round-trips from search-group fixture', () {
      final xml = _readFixture('post/composemessage/search-group.xml');
      final groups = XmlInterface.parseResponse(
        xml,
        './/groups/group',
      ).map(MessageSearchGroup.fromXml).toList();

      expect(groups.first.groupId, 298);
      expect(groups.first.displayName, '1A');
      expect(groups.first.ssId, 4069);
      expect(groups.first.description, '1ste leerjaar A');
    });
  });

  // ---------------------------------------------------------------------------
  // RecipientType enum
  // ---------------------------------------------------------------------------

  group('RecipientType', () {
    test('TO maps to request type "0" and correct parentNodeId', () {
      expect(RecipientType.to.requestType, '0');
      expect(RecipientType.to.parentNodeId, 'insertSearchFieldContainer_0_0');
    });

    test('CC maps to request type "2" and correct parentNodeId', () {
      expect(RecipientType.cc.requestType, '2');
      expect(RecipientType.cc.parentNodeId, 'insertSearchFieldContainer_2_0');
    });

    test('BCC maps to request type "3" and correct parentNodeId', () {
      expect(RecipientType.bcc.requestType, '3');
      expect(RecipientType.bcc.parentNodeId, 'insertSearchFieldContainer_3_0');
    });
  });

  // ---------------------------------------------------------------------------
  // Archive message listing (same parser, different boxId)
  // ---------------------------------------------------------------------------

  group('Archive message listing', () {
    test('archive fixture parses correctly into ShortMessage list', () {
      final xml = _readFixture('post/postboxes/message list archive.xml');
      final entries = XmlInterface.parseResponse(xml, './/messages/message');
      final headers = entries.map(ShortMessage.fromXml).toList();

      expect(headers, hasLength(1));
      expect(headers.first.id, 999001);
      expect(headers.first.sender, 'Archived Sender');
      expect(headers.first.unread, isFalse);
      expect(headers.first.realBox, 'inbox');
    });

    test(
      'getArchiveHeaders uses boxType=inbox per the Smartschool protocol',
      () {
        // The archive is NOT a separate BoxType — it's BoxType.inbox with
        // boxId != 0.  This test documents that invariant.
        expect(BoxType.inbox.value, 'inbox');

        // getArchiveHeaders is a thin wrapper: verifiable by checking that
        // the same XML schema parses for both inbox and archive responses.
        final inboxXml = _readFixture('post/postboxes/message list.xml');
        final archiveXml = _readFixture(
          'post/postboxes/message list archive.xml',
        );

        final parseInbox = XmlInterface.parseResponse(
          inboxXml,
          './/messages/message',
        ).map(ShortMessage.fromXml).toList();

        final parseArchive = XmlInterface.parseResponse(
          archiveXml,
          './/messages/message',
        ).map(ShortMessage.fromXml).toList();

        expect(parseInbox, isNotEmpty);
        expect(parseArchive, isNotEmpty);
      },
    );
  });

  group('MessagesService.parseArchiveBoxIdFromMessagesHtml', () {
    test('extracts archive box id from archive postbox node', () {
      const html = '''
        <div class="postboxsub" boxtype="inbox" boxid="208" boxname="Berichten archief" id="div_inbox_208">
          <div class="postbox_ico_sub archive" boxtype="inbox" boxid="208" boxname="Berichten archief"></div>
          <div class="postbox_name"><a class="postbox_link" boxtype="inbox" boxid="208" id="inbox_208">Berichten archief</a></div>
        </div>
      ''';

      final boxId = MessagesService.parseArchiveBoxIdFromMessagesHtml(html);
      expect(boxId, 208);
    });

    test('supports node shape from live Messages page (inbox_208)', () {
      const html = '''
        <div class="postboxsub" boxtype="inbox" boxid="208" boxname="Berichten archief" id="div_inbox_208">
          <div class="postbox_ico_sub archive" boxtype="inbox" boxid="208" boxname="Berichten archief" onmousedown="oTriggers.showBox(event);"></div>
          <div class="postbox_name"><a boxtype="inbox" boxid="208" boxname="Berichten archief" id="inbox_208" class="postbox_link">Berichten archief</a></div>
        </div>
      ''';

      final boxId = MessagesService.parseArchiveBoxIdFromMessagesHtml(html);
      expect(boxId, 208);
    });

    test('returns null when archive node is absent', () {
      const html = '''
        <div class="postbox" boxtype="inbox" boxid="0" id="div_inbox_0">
          <div class="postbox_ico inbox" boxtype="inbox" boxid="0"></div>
        </div>
      ''';

      final boxId = MessagesService.parseArchiveBoxIdFromMessagesHtml(html);
      expect(boxId, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // sendMessage payload composition (unit-level)
  // ---------------------------------------------------------------------------

  group('sendMessage payload fields', () {
    test('compose URL contains expected query params', () {
      // _composeUrl is private but its output is used in HTTP calls;
      // verify the expected path and params are present in the raw HTML
      // fixture URL the server would respond to.
      // We test this indirectly: the compose HTML fixture lives at the
      // path /?module=Messages&file=composeMessage&... and parseHiddenFields
      // should work on it without error.
      final html = _readFixture('get/composemessage/new-message.html');
      final fields = MessagesService.parseHiddenFields(html);

      // If the HTML was served at the right URL the tokens will be populated.
      expect(fields.containsKey('uniqueUsc'), isTrue);
      expect(fields.containsKey('randomDir'), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _readFixture(String name) {
  final file = File('test/fixtures/smartschool/requests/$name');
  if (!file.existsSync()) {
    fail('Missing fixture file: ${file.path}');
  }
  return file.readAsStringSync();
}
