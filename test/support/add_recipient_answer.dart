// Smartschool's answers to `addUserToSelected`, the request that registers a
// recipient on the compose form, for the fake Smartschools of the send tests.
//
// Captured live for #39 on a new-message compose form that was then
// abandoned (never submitted), and anonymised here.

/// Smartschool's answer to `addUserToSelected` with [fields] (the form
/// fields of the request) when it registers the recipient: HTTP `200`,
/// `application/xml`, and XML that describes the recipient, with the
/// `typeId` and the ID (`realUserId`) that were asked for. A group is
/// described in a `<user>` element too, with `userType` `G`.
String registeredRecipientAnswer(Map<dynamic, dynamic> fields) {
  final group = fields['typeId'] == 'groups';
  final id = fields['id'];
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<users><user>'
      '<type>${fields['type']}</type>'
      '<ssID>${fields['ssid']}</ssID>'
      '<parentNodeId>${fields['parentNodeId']}</parentNodeId>'
      '<userID>${group ? 'G' : 'U'}$id</userID>'
      '<name>Recipient $id</name>'
      '<userLT>${fields['userlt']}</userLT>'
      '<userType>${group ? 'G' : 'U'}</userType>'
      '<typeId>${fields['typeId']}</typeId>'
      '<realUserId>$id</realUserId>'
      '<spannameclass>${group ? 'group' : 'userm'}</spannameclass>'
      '<extrastyle />'
      '<haslegalresponsible>0</haslegalresponsible>'
      '</user></users>';
}

/// The content type of [registeredRecipientAnswer].
const registeredRecipientContentType = 'application/xml; charset=UTF-8';
