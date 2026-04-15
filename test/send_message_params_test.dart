import 'package:test/test.dart';
import 'package:flutter_smartschool/src/services/send_message_params.dart';
import 'package:flutter_smartschool/src/models/message_models.dart';
import 'package:flutter_smartschool/src/services/message_send_options.dart';

void main() {
  group('SendMessageParams', () {
    test('constructor assigns all fields', () {
      final user = MessageSearchUser(
        userId: 1,
        displayName: 'Test User',
        ssId: 100,
        coaccountName: 'coaccount',
        className: 'classA',
        schoolName: 'Test School',
        picture: null,
        userLt: 0,
      );
      final group = MessageSearchGroup(
        groupId: 2,
        displayName: 'Test Group',
        ssId: 200,
        icon: null,
        description: 'A group',
      );
      final params = SendMessageParams(
        to: [user],
        cc: [user],
        bcc: [user],
        toGroups: [group],
        ccGroups: [group],
        bccGroups: [group],
        subject: 'Subject',
        bodyHtml: '<b>Body</b>',
        attachmentPaths: ['/tmp/file.txt'],
        options: MessageSendOptions(
          requestReadReceipt: true,
          highPriority: true,
          extra: {'foo': 'bar'},
        ),
      );
      expect(params.to, [user]);
      expect(params.cc, [user]);
      expect(params.bcc, [user]);
      expect(params.toGroups, [group]);
      expect(params.ccGroups, [group]);
      expect(params.bccGroups, [group]);
      expect(params.subject, 'Subject');
      expect(params.bodyHtml, '<b>Body</b>');
      expect(params.attachmentPaths, ['/tmp/file.txt']);
      expect(params.options.requestReadReceipt, true);
      expect(params.options.highPriority, true);
      expect(params.options.extra, {'foo': 'bar'});
    });

    test('defaults are correct', () {
      final user = MessageSearchUser(
        userId: 1,
        displayName: 'Test User',
        ssId: 100,
        coaccountName: null,
        className: null,
        schoolName: null,
        picture: null,
        userLt: 0,
      );
      final params = SendMessageParams(
        to: [user],
        subject: 'Subject',
        bodyHtml: 'Body',
      );
      expect(params.cc, isEmpty);
      expect(params.bcc, isEmpty);
      expect(params.toGroups, isEmpty);
      expect(params.ccGroups, isEmpty);
      expect(params.bccGroups, isEmpty);
      expect(params.attachmentPaths, isEmpty);
      expect(params.options.requestReadReceipt, false);
      expect(params.options.highPriority, false);
      expect(params.options.extra, isNull);
    });
  });
}
