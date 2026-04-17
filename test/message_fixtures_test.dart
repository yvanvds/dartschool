import 'dart:convert';
import 'dart:io';

import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/messages_service.dart';
import 'package:flutter_smartschool/src/xml_interface.dart';
import 'package:test/test.dart';

void main() {
  group('Smartschool snapshot fixtures (messages)', () {
    test('message list fixture parses into ShortMessage objects', () {
      final xml = _readFixture('post/postboxes/message list.xml');

      final entries = XmlInterface.parseResponse(xml, './/messages/message');
      final headers = entries.map(ShortMessage.fromXml).toList();

      expect(headers, isNotEmpty);
      expect(headers.first.id, 123456);
      expect(headers.first.sender, 'Teacher');
      expect(headers.first.unread, isTrue);
      expect(headers.first.realBox, 'inbox');
      expect(headers.first.subject, contains('LO'));
    });

    test(
      'show message fixture parses into FullMessage with receiver lists',
      () {
        final xml = _readFixture('post/postboxes/show message.xml');

        final entries = XmlInterface.parseResponse(xml, './/data/message');
        expect(entries, hasLength(1));

        final full = FullMessage.fromXml(entries.single);

        expect(full.id, 123456);
        expect(full.sender, 'Teacher');
        expect(full.subject, 'Griezelfestijn');
        expect(full.attachment, 2);
        expect(full.receivers, isEmpty);
        expect(full.ccReceivers, ['Person1', 'Person2']);
        expect(full.bccReceivers, ['Parent']);
      },
    );

    test('attachment list fixture parses into attachment models', () {
      final xml = _readFixture('post/postboxes/attachment list.xml');

      final entries = XmlInterface.parseResponse(
        xml,
        './/attachmentlist/attachment',
      );
      final attachments = entries.map(MessageAttachment.fromXml).toList();

      expect(attachments, hasLength(2));
      expect(attachments.first.fileId, 123);
      expect(attachments.first.name, contains('Oproep'));
      expect(attachments.first.wopiAllowed, isTrue);
      expect(attachments.last.order, 1);
    });

    test('mark unread fixture parses into MessageChanged', () {
      final xml = _readFixture('post/postboxes/mark message unread.xml');

      final entries = XmlInterface.parseResponse(xml, './/data/message');
      final changed = MessageChanged.fromXml(entries.single);

      expect(changed.id, 123);
      expect(changed.newValue, 0);
    });

    test('mark read fixture parses into MessageChanged with newValue=1', () {
      final xml = _readFixture('post/postboxes/mark message read.xml');

      final entries = XmlInterface.parseResponse(xml, './/data/message');
      final changed = MessageChanged.fromXml(entries.single);

      expect(changed.id, 123);
      expect(changed.newValue, 1);
    });

    test('mark read and mark unread fixtures share the same xml schema', () {
      // markRead  → server responds with status=1 (now read)
      // markUnread → server responds with status=0 (now unread)
      // Both use identical XML structure; only the status value differs.
      final readXml = _readFixture('post/postboxes/mark message read.xml');
      final unreadXml = _readFixture('post/postboxes/mark message unread.xml');

      final readEntries = XmlInterface.parseResponse(readXml, './/data/message');
      final unreadEntries = XmlInterface.parseResponse(unreadXml, './/data/message');

      final readChanged = MessageChanged.fromXml(readEntries.single);
      final unreadChanged = MessageChanged.fromXml(unreadEntries.single);

      expect(readChanged.id, unreadChanged.id);
      expect(readChanged.newValue, 1);
      expect(unreadChanged.newValue, 0);
    });

    test('save label fixture parses into MessageChanged', () {
      final xml = _readFixture('post/postboxes/save msglabel.xml');

      final entries = XmlInterface.parseResponse(xml, './/data/message');
      final changed = MessageChanged.fromXml(entries.single);

      expect(changed.id, 123);
      expect(changed.newValue, 1);
    });

    test('quick delete fixture parses into MessageDeletionStatus', () {
      final xml = _readFixture('post/postboxes/quick delete.xml');

      final entries = XmlInterface.parseResponse(xml, './/data/details');
      final status = MessageDeletionStatus.fromXml(entries.single);

      expect(status.msgId, 123);
      expect(status.boxType, 'inbox');
      expect(status.isDeleted, isTrue);
    });

    test('archive messages fixture json shape stays compatible', () {
      final raw = _readFixture('post/messages/xhr/archivemessages.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;

      final success = (json['success'] as List).cast<int>();
      expect(success, [123]);
    });

    // -----------------------------------------------------------------------
    // Compose-form & search fixtures
    // -----------------------------------------------------------------------

    test('compose HTML hidden fields are extracted correctly', () {
      final html = _readFixture('get/composemessage/new-message.html');

      final fields = MessagesService.parseHiddenFields(html);

      expect(fields, isNotEmpty);
      expect(fields['randomDir'], 'dnV3ujSKmTkE48qLbjMxFrG4y17757280351002146');
      expect(
        fields['uniqueUsc'],
        '4069fDsFgJGxHbeGeCwnF3HXbNTDg17757280354069',
      );
      expect(fields['encryptedSender'], '76542a9717766d290cf71e6028dc4a7f');
      expect(fields['origMsgID'], '0');
      expect(fields['composeAction'], '0');
    });

    test('compose HTML contains no non-hidden fields in result', () {
      final html = _readFixture('get/composemessage/new-message.html');

      final fields = MessagesService.parseHiddenFields(html);

      // email/text inputs must NOT appear — only hidden fields
      expect(fields.containsKey('username'), isFalse);
    });

    test('search-user.xml parses into MessageSearchUser list', () {
      final xml = _readFixture('post/composemessage/search-user.xml');

      final users = XmlInterface.parseResponse(
        xml,
        './/users/user',
      ).map(MessageSearchUser.fromXml).toList();

      expect(users, isNotEmpty);
      expect(users.first.userId, 146);
      expect(users.first.displayName, 'John Smith');
      expect(users.first.ssId, 4069);
      expect(users.first.userLt, 0);
      // schoolName is present
      expect(users.first.schoolName, isNotNull);
      // groups element should yield nothing from user xpath
      final groups = XmlInterface.parseResponse(
        xml,
        './/groups/group',
      ).map(MessageSearchGroup.fromXml).toList();
      expect(groups, isEmpty);
    });

    test('search-group.xml parses into MessageSearchGroup list', () {
      final xml = _readFixture('post/composemessage/search-group.xml');

      final groups = XmlInterface.parseResponse(
        xml,
        './/groups/group',
      ).map(MessageSearchGroup.fromXml).toList();

      expect(groups, hasLength(2));
      expect(groups.first.groupId, 298);
      expect(groups.first.displayName, '1A');
      expect(groups.first.ssId, 4069);
      expect(groups.first.description, '1ste leerjaar A');
      // users element should yield nothing from group xpath
      final users = XmlInterface.parseResponse(
        xml,
        './/users/user',
      ).map(MessageSearchUser.fromXml).toList();
      expect(users, isEmpty);
    });

    test('RecipientType enum values match Smartschool protocol constants', () {
      expect(RecipientType.to.requestType, '0');
      expect(RecipientType.cc.requestType, '2');
      expect(RecipientType.bcc.requestType, '3');

      expect(RecipientType.to.parentNodeId, 'insertSearchFieldContainer_0_0');
      expect(RecipientType.cc.parentNodeId, 'insertSearchFieldContainer_2_0');
      expect(RecipientType.bcc.parentNodeId, 'insertSearchFieldContainer_3_0');
    });

    // -----------------------------------------------------------------------
    // Archive fixture
    // -----------------------------------------------------------------------

    test('archive message list fixture parses into ShortMessage list', () {
      final xml = _readFixture('post/postboxes/message list archive.xml');

      final entries = XmlInterface.parseResponse(xml, './/messages/message');
      final headers = entries.map(ShortMessage.fromXml).toList();

      expect(headers, hasLength(1));
      expect(headers.first.id, 999001);
      expect(headers.first.sender, 'Archived Sender');
      expect(headers.first.subject, 'Archived Message Subject');
      expect(headers.first.unread, isFalse);
      expect(headers.first.realBox, 'inbox');
    });

    test('archive and inbox lists use the same XML schema', () {
      // Demonstrates that getHeaders(boxId: 208) and getHeaders() differ
      // only in the request payload while sharing identical response parsing.
      final inboxXml = _readFixture('post/postboxes/message list.xml');
      final archiveXml = _readFixture(
        'post/postboxes/message list archive.xml',
      );

      final inboxMsgs = XmlInterface.parseResponse(
        inboxXml,
        './/messages/message',
      ).map(ShortMessage.fromXml).toList();

      final archiveMsgs = XmlInterface.parseResponse(
        archiveXml,
        './/messages/message',
      ).map(ShortMessage.fromXml).toList();

      // Both parse without errors and return ShortMessage objects.
      expect(inboxMsgs, isNotEmpty);
      expect(archiveMsgs, isNotEmpty);
      // IDs are distinct — different content in each fixture.
      expect(inboxMsgs.map((m) => m.id), isNot(contains(archiveMsgs.first.id)));
    });

    test('threadSubjectKey strips stacked prefixes and normalises spaces', () {
      expect(
        MessagesService.threadSubjectKey(' Re:   FWD:  AW:   Project update '),
        'Project update',
      );
      expect(MessagesService.threadSubjectKey('FW: Re: Topic'), 'Topic');
      expect(
        MessagesService.threadSubjectKey('No prefix subject'),
        'No prefix subject',
      );
      expect(MessagesService.threadSubjectKey('   '), '');
    });

    test('ensureReplySubject adds one reply prefix only', () {
      expect(
        MessagesService.ensureReplySubject('Re:  Re: Lesson plan'),
        'Re: Lesson plan',
      );
      expect(
        MessagesService.ensureReplySubject('FW: Parent meeting'),
        'Re: Parent meeting',
      );
      expect(
        MessagesService.ensureReplySubject('Topic', replyPrefix: 'Antwort:'),
        'Antwort: Topic',
      );
      expect(MessagesService.ensureReplySubject('   '), 'Re:');
    });

    // -----------------------------------------------------------------------
    // getMessage with includeAllRecipients fixture
    // -----------------------------------------------------------------------

    test(
      'show message all recipients fixture parses full To and CC lists',
      () {
        final xml = _readFixture(
          'post/postboxes/show message all recipients.xml',
        );

        final entries = XmlInterface.parseResponse(xml, './/data/message');
        expect(entries, hasLength(1));

        final full = FullMessage.fromXml(entries.single);

        expect(full.id, 789012);
        expect(full.sender, 'Teacher');
        expect(full.subject, 'Class trip announcement');
        expect(full.receivers, ['Student A', 'Student B', 'Student C']);
        expect(full.ccReceivers, ['Parent X', 'Parent Y']);
        expect(full.bccReceivers, isEmpty);
        expect(full.totalNrOtherToReceivers, 0);
        expect(full.totalNrOtherCcReceivers, 0);
      },
    );

    // -----------------------------------------------------------------------
    // parseReplyAllRecipients
    // -----------------------------------------------------------------------

    test('reply-all fixture parses To and CC recipients with IDs', () {
      final html = _readFixture('get/composemessage/reply-all.html');

      final (toList, ccList) = MessagesService.parseReplyAllRecipients(html);

      expect(toList, hasLength(2));
      expect(ccList, hasLength(2));

      expect(toList[0].userId, 201);
      expect(toList[0].displayName, 'Alice Johnson');
      expect(toList[0].ssId, 4069);
      expect(toList[0].userLt, 0);

      expect(toList[1].userId, 202);
      expect(toList[1].displayName, 'Bob Smith');
      expect(toList[1].ssId, 4069);

      expect(ccList[0].userId, 301);
      expect(ccList[0].displayName, 'Carol White');
      expect(ccList[0].ssId, 4069);
      expect(ccList[0].userLt, 1);

      expect(ccList[1].userId, 302);
      expect(ccList[1].displayName, 'Dave Brown');
    });

    test('parseReplyAllRecipients returns empty lists for empty HTML', () {
      final (toList, ccList) = MessagesService.parseReplyAllRecipients(
        '<html><body></body></html>',
      );

      expect(toList, isEmpty);
      expect(ccList, isEmpty);
    });

    test(
      'parseReplyAllRecipients skips spans missing required attributes',
      () {
        const html = '''
<html><body>
  <div class="receiverSpan" ssidatt="4069" typeatt="0">
    <span class="receiverSpanName">No userId</span>
  </div>
  <div class="receiverSpan" realuserid="401" typeatt="0">
    <span class="receiverSpanName">No ssId</span>
  </div>
  <div class="receiverSpan" realuserid="402" ssidatt="4069" typeatt="0">
  </div>
  <div class="receiverSpan" realuserid="403" ssidatt="4069" typeatt="0">
    <span class="receiverSpanName">Valid User</span>
  </div>
</body></html>''';

        final (toList, ccList) = MessagesService.parseReplyAllRecipients(html);

        expect(toList, hasLength(1));
        expect(toList.single.userId, 403);
        expect(toList.single.displayName, 'Valid User');
        expect(ccList, isEmpty);
      },
    );

    test(
      'parseReplyAllRecipients defaults typeatt-less spans to To list',
      () {
        const html = '''
<html><body>
  <div class="receiverSpan" realuserid="501" ssidatt="4069">
    <span class="receiverSpanName">Default To</span>
  </div>
</body></html>''';

        final (toList, ccList) = MessagesService.parseReplyAllRecipients(html);

        expect(toList, hasLength(1));
        expect(toList.single.userId, 501);
        expect(ccList, isEmpty);
      },
    );

    test(
      'parseReplyAllRecipients defaults missing userltatt to zero',
      () {
        const html = '''
<html><body>
  <div class="receiverSpan" realuserid="601" ssidatt="4069" typeatt="0">
    <span class="receiverSpanName">No UserLt</span>
  </div>
</body></html>''';

        final (toList, _) = MessagesService.parseReplyAllRecipients(html);

        expect(toList.single.userLt, 0);
      },
    );
  });
}

String _readFixture(String name) {
  final file = File('test/fixtures/smartschool/requests/$name');
  if (!file.existsSync()) {
    fail('Missing fixture file: ${file.path}');
  }
  return file.readAsStringSync();
}
