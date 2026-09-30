/// Whether Smartschool stores a sent message in the LVS (the pupil tracking
/// system, "leerlingvolgsysteem"): the `copyToLVS` select of Smartschool's
/// compose form (the new-message form and the reply forms), whose options
/// are [value] (#47).
enum LvsCopy {
  /// Not stored in the LVS ("Bericht niet bewaren in het LVS"): the option
  /// the compose form selects, and the default of [MessageSendOptions].
  none('dontCopyToLVS'),

  /// Stored in the LVS ("Bericht bewaren in het LVS").
  store('copyToLVS'),

  /// Stored in the LVS and marked as confidential ("Bericht bewaren in het
  /// LVS en markeren als vertrouwelijk").
  storeConfidential('copyToLVSAndMarkAsPrivate');

  const LvsCopy(this.value);

  /// The value of the option in the compose form's `copyToLVS` select.
  final String value;
}

/// Options of a message that `MessagesService.sendMessage` and
/// `MessagesService.sendReply` send, beyond its recipients, subject, body and
/// attachments (`SendMessageParams.options`).
///
/// They are the options of Smartschool's compose form (the new-message form
/// and the reply forms), each submitted in its own field (#47):
/// - [lvsCopy], the form's `copyToLVS` select: store the message in the LVS;
/// - [sendAt], the form's `sendDate` field: a delayed send, as the "Uitgesteld
///   versturen" (send later) dialog of Smartschool's web client schedules it.
///
/// The default `MessageSendOptions()` sends the message as the compose form
/// does by default: not stored in the LVS, sent now.
///
/// The other fields are deprecated (#43): the compose form has no read
/// receipt, no priority, and no field that the library leaves for [extra] to
/// fill. Rather than send the message without what the caller asked for,
/// `sendMessage` and `sendReply` throw an [ArgumentError] when one is set
/// ([requestReadReceipt] or [highPriority] `true`, or a non-empty [extra]),
/// before any request: nothing was sent.
class MessageSendOptions {
  /// Whether Smartschool stores the message in the LVS: the option of the
  /// compose form's `copyToLVS` select. The default, [LvsCopy.none], is the
  /// option the form selects.
  ///
  /// Another option is sent only when the compose form offers it: when the
  /// form has no `copyToLVS` select (it is left out for an account that may
  /// not store messages in the LVS) or not that option, the send throws a
  /// `SmartschoolComposeError` after loading the form, before registering
  /// any recipient, and nothing was sent.
  ///
  /// Not verified with a real send: what Smartschool does with the copy
  /// (for instance with recipients who are not pupils).
  final LvsCopy lvsCopy;

  /// When Smartschool sends the message: `null` (the default) sends it now;
  /// a time schedules it, as the delayed-send dialog of Smartschool's web
  /// client does, and Smartschool sends it then. Until then, the web client
  /// counts it in the scheduled box (`BoxType.scheduled`).
  ///
  /// It must be after now, and at most a year ahead: no later than the end
  /// of the same day next year, the last day the dialog's date picker
  /// offers. A send with a time outside these limits throws an
  /// [ArgumentError] before any request, and nothing was sent. The dialog
  /// picks whole minutes; seconds are sent as given, milliseconds dropped.
  ///
  /// It is submitted in the compose form's `sendDate` field as the dialog
  /// writes it: in ISO 8601, in the local time of the machine with its
  /// offset from UTC (`2026-10-02T07:30:00+02:00`, or `…Z` on a machine that
  /// runs on UTC). The instant is the same whatever the time zone of the
  /// [DateTime]. The send throws a `SmartschoolComposeError` after loading
  /// the form, before registering any recipient, when the form offers no
  /// delayed send (no `sendDate` field, or Smartschool's scheduled messages
  /// not enabled for the account), and nothing was sent.
  ///
  /// Not verified with a real send: Smartschool's answer to the submit of a
  /// scheduled message (the send returns normally only for the answer to a
  /// sent message, see `MessagesService.sendMessage`; another answer is a
  /// `SmartschoolSendUnconfirmedError`), and whether Smartschool reads the
  /// offset of a time outside Belgium's time zone.
  final DateTime? sendAt;

  /// Asks for a read receipt. Not supported: Smartschool's compose form has
  /// no read receipt, so a send with `true` throws an [ArgumentError] and
  /// sends nothing (#43).
  @Deprecated(
    'Smartschool has no read receipt: a send that sets it throws an '
    'ArgumentError (#43)',
  )
  final bool requestReadReceipt;

  /// Marks the message as high priority. Not supported: Smartschool's
  /// compose form has no priority, so a send with `true` throws an
  /// [ArgumentError] and sends nothing (#43).
  @Deprecated(
    'Smartschool has no message priority: a send that sets it throws an '
    'ArgumentError (#43)',
  )
  final bool highPriority;

  /// Extra fields for the submit of the compose form. Not supported: the
  /// submit already holds every field of the form, filled from the other
  /// parameters of the send (tokens, recipients, subject, body, [lvsCopy],
  /// [sendAt]) or with the form's own defaults, so an extra field could only
  /// override one of them. A send with a non-empty map throws an
  /// [ArgumentError] and sends nothing (#43).
  @Deprecated(
    'Smartschool\'s compose form has no field for it: a send that sets it '
    'throws an ArgumentError (#43)',
  )
  final Map<String, dynamic>? extra;

  const MessageSendOptions({
    this.lvsCopy = LvsCopy.none,
    this.sendAt,
    @Deprecated(
      'Smartschool has no read receipt: a send that sets it throws an '
      'ArgumentError (#43)',
    )
    this.requestReadReceipt = false,
    @Deprecated(
      'Smartschool has no message priority: a send that sets it throws an '
      'ArgumentError (#43)',
    )
    this.highPriority = false,
    @Deprecated(
      'Smartschool\'s compose form has no field for it: a send that sets it '
      'throws an ArgumentError (#43)',
    )
    this.extra,
  });
}
