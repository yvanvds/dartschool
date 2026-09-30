// Smartschool's answers to `deleteUsersFromSelected`, the request that takes a
// recipient off the compose form, for the fake Smartschools of the send tests.
//
// Captured live for #42 on the reply form of a message the account sent to
// itself, which was then abandoned (never submitted), and anonymised here.
import 'package:xml/xml.dart';

/// Smartschool's answer to `deleteUsersFromSelected` with the form field
/// `xml` [requestXml] when the compose form has the entries it names: HTTP
/// `200`, `application/xml`, and XML that lists each entry it took off, with
/// the `type`, `ssID`, `userID` and `userLT` that were asked for (the
/// request names them `type`, `userid`, `ssid` and `userlt`).
String removedRecipientsAnswer(String requestXml) {
  final users = XmlDocument.parse(requestXml).findAllElements('user');
  String field(XmlElement user, String name) =>
      user.getElement(name)?.innerText ?? '';
  final removed = users.map(
    (user) =>
        '<user>'
        '<type>${field(user, 'type')}</type>'
        '<ssID>${field(user, 'ssid')}</ssID>'
        '<userID>${field(user, 'userid')}</userID>'
        '<userLT>${field(user, 'userlt')}</userLT>'
        '</user>',
  );
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<users>${removed.join()}</users>';
}

/// Smartschool's answer to `deleteUsersFromSelected` for an entry that the
/// compose form does not have (taken off already, asked for in another field,
/// or with the user ID without its `U` prefix): HTTP `200`,
/// `application/xml`, and an empty list.
const noRecipientRemovedAnswer =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<users />';

/// The content type of Smartschool's answers to `deleteUsersFromSelected`.
const removedRecipientContentType = 'application/xml; charset=UTF-8';
