import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import 'models/lesson_content_models.dart' show LessonContentItem;
import 'models/message_models.dart' show BoxType;
import 'models/planner_models.dart'
    show PlannedElement, PlannedElementDetail, PlannerWriteRefusalReason;
import 'models/presence_models.dart'
    show DayPart, PresenceHalfDay, PresenceSaveError;
import 'models/skore_models.dart' show SkoreAccessArea;

/// Base exception for all Smartschool API errors.
class SmartschoolException implements Exception {
  final String message;

  const SmartschoolException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when authentication fails or the session is not accepted.
///
/// Login failures that callers need to tell apart are thrown as one of these
/// subclasses, so they can be matched on type rather than on [message]:
///
/// - [SmartschoolInvalidCredentialsError]: the username or password was
///   rejected.
/// - [SmartschoolTwoFactorRequiredError]: Smartschool asks for a 2FA code, but
///   the credentials hold no TOTP secret (`mfa`).
/// - [SmartschoolTwoFactorRejectedError]: the 2FA code was rejected.
/// - [SmartschoolInvalidTotpSecretError]: the TOTP secret (`mfa`) is not a
///   Base32 key, such as the 6-digit code of the authenticator app.
/// - [SmartschoolUnsupportedTwoFactorMethodError]: the account uses a 2FA
///   method other than an authenticator app (Google Authenticator).
/// - [SmartschoolAccountVerificationRequiredError]: Smartschool asks for
///   account verification (a date of birth), but the credentials hold no
///   usable answer.
/// - [SmartschoolAccountVerificationRejectedError]: the account verification
///   answer was rejected.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the session
///   for a request, also after logging in again.
/// - [SmartschoolUnexpectedPageError]: Smartschool answered an XML command
///   with an HTML page; it says whether that is the login page, which an
///   error page, for one, is not (#106).
///
/// This class itself is still thrown for the remaining authentication
/// failures, such as an unrecognised step in the login chain, or an HTML page
/// where JSON was expected. Catching [SmartschoolAuthenticationError] catches
/// all of them.
///
/// It is thrown as itself also when the login is triggered by a regular
/// request (e.g. a service call on a cold or expired session): the request
/// methods of `SmartschoolClient`, and so every service, unwrap it from the
/// `DioException` the login failure travels in. Only a request made on
/// `SmartschoolClient.dio` directly gets it wrapped (as the `error`).
///
/// An unreachable Smartschool is not an authentication failure:
/// `ensureAuthenticated()` and the request methods (so every service) throw a
/// [SmartschoolConnectionError] for that.
class SmartschoolAuthenticationError extends SmartschoolException {
  const SmartschoolAuthenticationError(super.message);
}

/// Thrown when Smartschool rejects the username or password.
///
/// Accounts that can only sign in through single sign-on (Microsoft, Google)
/// end up here too: Smartschool rejects their password login.
///
/// In rare cases it can also mean that Smartschool rejected the login form's
/// token (`login_form[_token]`, its CSRF token) rather than the credentials
/// (#46). Smartschool answers both with the same page: back on `/login`, with
/// the same error ("Ongeldige inloggegevens.") and the username kept, so the
/// login cannot tell them apart. Since #45 the login posts the token of a
/// login form it loaded itself, in a new session that no other request uses,
/// so a rejected token should be rare.
///
/// Do not log in again on this error automatically, also not to rule out a
/// rejected token: every rejected login brings the account closer to being
/// locked. For the same reason the client does not try one login again after
/// its `loginCooldown` when the last login ended on this error (#32), but
/// waits for `SmartschoolClient.resetLoginAttempts()`.
class SmartschoolInvalidCredentialsError
    extends SmartschoolAuthenticationError {
  const SmartschoolInvalidCredentialsError([
    super.message =
        'Login failed. Check username/password or SSO-only account setup.',
  ]);
}

/// Thrown when Smartschool asks for a 2FA code, but the credentials hold no
/// TOTP secret in `mfa`.
class SmartschoolTwoFactorRequiredError extends SmartschoolAuthenticationError {
  const SmartschoolTwoFactorRequiredError([
    super.message =
        '2FA requires a TOTP secret in the mfa field of credentials',
  ]);
}

/// Thrown when Smartschool rejects the 2FA code: the TOTP secret (`mfa`) is
/// wrong, or the device clock is off.
class SmartschoolTwoFactorRejectedError extends SmartschoolAuthenticationError {
  const SmartschoolTwoFactorRejectedError([
    super.message =
        '2FA verification failed. Check your TOTP secret (mfa) and '
        'ensure your device time is synchronized.',
  ]);
}

/// Thrown when the TOTP secret in `mfa` is not one (#79): with white space
/// and hyphens removed, it is empty, holds a character that is not Base32
/// (the letters A-Z and the digits 2-7, with `=` padding only at the end), or
/// holds only digits, such as the 6-digit code an authenticator app shows
/// rather than the key it was set up with. Lower case is fine.
///
/// The login checks `mfa` before it loads the login form and posts the
/// password, when `mfa` is not a date (`yyyy-mm-dd`, the answer to
/// Smartschool's account verification) and not empty once trimmed (an `mfa`
/// of only white space is no `mfa`, there as at the steps after the
/// password, which throw [SmartschoolTwoFactorRequiredError] and
/// [SmartschoolAccountVerificationRequiredError] for it): such an `mfa` can
/// answer neither
/// the 2FA step nor the account verification, so the login sends nothing,
/// and every login fails this way until the credentials are fixed. That
/// holds for an account that would not ask for either step too: set `mfa`
/// only to a date or a TOTP secret. An `mfa` that is a date is checked when
/// Smartschool asks for a 2FA code: after the password, before anything of
/// the 2FA step is sent; the client then counts it as rejected credentials
/// (see [SmartschoolSessionExpiredError]).
///
/// `Credentials.normalizeTotpSecret` runs the same check without a client,
/// for instance where a user enters the key. The message never holds the
/// secret.
class SmartschoolInvalidTotpSecretError extends SmartschoolAuthenticationError {
  const SmartschoolInvalidTotpSecretError([
    super.message =
        'The TOTP secret (mfa) is not a Base32 key. Use the key Smartschool '
        'shows when an authenticator app is added (the letters A-Z and the '
        'digits 2-7; spaces and hyphens are ignored), not the 6-digit code '
        'the app shows.',
  ]);
}

/// Thrown when the account's 2FA does not offer an authenticator app (Google
/// Authenticator), the only method this library supports.
class SmartschoolUnsupportedTwoFactorMethodError
    extends SmartschoolAuthenticationError {
  /// The 2FA methods Smartschool reports for the account
  /// (`possibleAuthenticationMechanisms`). Empty when it reported none.
  final List<String> availableMethods;

  const SmartschoolUnsupportedTwoFactorMethodError(
    this.availableMethods, [
    super.message = 'Only googleAuthenticator 2FA is supported',
  ]);

  @override
  String toString() => availableMethods.isEmpty
      ? '$runtimeType: $message'
      : '$runtimeType: $message '
            '(account offers: ${availableMethods.join(', ')})';
}

/// Thrown when Smartschool asks for account verification (a date of birth),
/// but the credentials hold no usable answer: `mfa` is empty, or it is not a
/// date while the form asks for one (typically a TOTP secret, on an account
/// without 2FA set up).
class SmartschoolAccountVerificationRequiredError
    extends SmartschoolAuthenticationError {
  const SmartschoolAccountVerificationRequiredError([
    super.message =
        'account-verification requires mfa (birthday date) in credentials',
  ]);
}

/// Thrown when Smartschool rejects the account verification answer (the date
/// of birth in `mfa`).
class SmartschoolAccountVerificationRejectedError
    extends SmartschoolAuthenticationError {
  const SmartschoolAccountVerificationRejectedError([
    super.message =
        'Account verification is still pending. Check the verification '
        'answer format in credentials.yml (often yyyy-mm-dd).',
  ]);
}

/// Thrown when Smartschool does not accept the session for a request: it
/// answers with its login chain instead of the data.
///
/// Smartschool signals this in two ways: it answers an XHR or form POST with
/// `401`, or it redirects the request to the login chain (`/login`, `/2fa`,
/// `/account-verification`; a POST sent without `X-Requested-With` gets a
/// `302` to `/login`). The client then logs in again and retries the request
/// once on its own, so this error means Smartschool refused the retry too:
/// the new session was not taken into account either. The request was not
/// carried out, so it is safe to sign in again (for instance with a new
/// `SmartschoolClient`, after `clearCookies()`) and retry.
///
/// Thrown by the request methods of `SmartschoolClient`, and so by every
/// service, when that retry is still answered with `401` or by the login
/// chain.
///
/// Also thrown, without logging in, once the client has stopped logging in
/// again: after three logins in a row that did not get the session accepted
/// (the login failed, or the retry was refused), a request that Smartschool
/// refuses fails at once, whichever way it was refused. The client logs in
/// again after an answer that Smartschool accepts, and tries one login again
/// once the `loginCooldown` of `SmartschoolClient.create` (5 minutes by
/// default) has passed since the last one (#32) — unless Smartschool rejected
/// the credentials at that login. `SmartschoolClient.resetLoginAttempts()`
/// lets it log in again at once; a new `SmartschoolClient` starts counting
/// afresh.
///
/// Also thrown, without logging in again and without a retry, for a request
/// that must not be retried in a new session because it carries state of the
/// session that was refused (`retryAfterLogin: false` on the request methods
/// of `SmartschoolClient`). `MessagesService.sendMessage` sends every step
/// after loading the compose form that way (#25): the message was not sent,
/// and calling `sendMessage` again logs in and starts from a new compose form.
///
/// Also thrown, without sending the request, for a request that must go out
/// in the session of an earlier answer (`sameSessionAs` on the POST methods
/// of `SmartschoolClient`) when the client logged in again since that
/// answer's request went out, or is logging in, for instance for another
/// request on the same client (#38). `MessagesService.sendMessage` and
/// `sendReply` send every step after loading the compose form that way too:
/// the send stops before the submit, nothing was sent, and calling the method
/// again starts from a new compose form in the new session.
/// `MessagesService.searchRecipientsForCompose` sends its search both ways
/// (#97): when the search is refused or not sent, it loads a new compose form
/// and searches once more itself, and throws this error only when that search
/// cannot go out in the session of its form either. So does
/// `MessagesService.searchRecipientsForComposeAll` with its searches on one
/// form (#107): it loads a new form once per call, and throws this error when
/// a search on that form cannot go out in its session either.
///
/// Also thrown, without logging in again and without a retry, by
/// `SkoreService` when Smartschool's Skore module answers an RPC without a
/// session (its web client reports that answer as an empty session).
///
/// It is not a missing access right: when the session is accepted but the
/// account may not make the request, the service reports that in its own
/// error type (e.g. [SmartschoolPresenceError], a [SmartschoolPlannerError]
/// with the planner's HTTP status, or a [SmartschoolSkoreAccessDeniedError]).
class SmartschoolSessionExpiredError extends SmartschoolAuthenticationError {
  const SmartschoolSessionExpiredError([
    super.message = 'Smartschool did not accept the session.',
  ]);
}

/// Thrown by `SmartschoolClient.postXml`, and so by the calls of
/// `MessagesService` that send an XML command (`getHeaders`, `getMessage`,
/// `markRead`, `moveToTrashFrom`, ...), when Smartschool answers the command
/// with an HTML page instead of XML (#106).
///
/// That includes a page with a comment before its doctype, and a piece of a
/// page, such as the one Smartschool answers an XHR to a module page with
/// (`<!-- TRANSPARANT LAYER -->` and `<div>`s, seen live), also one that
/// happens to be well-formed XML (#110). Such a piece seldom has a [title],
/// and the [message] calls it a page too. Malformed XML that is not HTML is
/// a [SmartschoolParsingError].
///
/// `MessagesService.searchRecipientsForCompose` and
/// `searchRecipientsForComposeAll` throw it too, the same way, when
/// Smartschool answers a recipient search (a form POST to `searchUsers`, not
/// a command) with HTML instead of XML; its [action] is then `searchUsers`
/// (#112).
///
/// The client logs in again on the answers with which Smartschool refuses a
/// session: a `401`, its answer to an XML command on an expired session, or a
/// redirect to its login chain. So an HTML page that comes this far is
/// something else, and [isLoginPage] tells what:
///
/// - `false`: a page that is not Smartschool's login page, such as one of its
///   error pages (it serves some of those with status `200`). Not a sign of
///   an expired session: Smartschool's web client reports such an answer to
///   a command as an unknown error, and goes on in the same session. Seen
///   once in a live run, for a `message list`, after which the same session
///   listed the boxes again; what that page was is not known yet. Whether a
///   command that changes something was carried out is not known either:
///   check before sending it again.
/// - `true`: a page with Smartschool's login form, or its account
///   verification form. Smartschool did not accept the session, although it
///   did not refuse it in a way that makes the client log in again. Not seen
///   live.
///
/// It extends [SmartschoolAuthenticationError] because `postXml` threw that
/// error for every HTML page before: code that catches it still catches this
/// one.
///
/// It keeps what tells one page from another, so that a next one can be
/// understood: the [statusCode], [contentType] and [url] of the answer, and
/// the page's [title] and [heading], all in the [message] too, and the start
/// of its text in [excerpt], which is not in the message. None of them holds
/// the page's scripts, styles or forms (Smartschool's pages carry the
/// signed-in user, with their name, in a script), and e-mail addresses and
/// token-like strings (long runs of letters and digits) are masked in each.
/// None holds the request's cookies or credentials, which are not in the
/// page. Yet a page can show a name in its text: that is why [excerpt] is
/// left out of the message.
class SmartschoolUnexpectedPageError extends SmartschoolAuthenticationError {
  /// The XML command that Smartschool answered with the page, such as
  /// `message list`, or `searchUsers` for a recipient search (#112), or
  /// `null` when it is not known.
  final String? action;

  /// The HTTP status of the answer, or `null` when it is not known.
  final int? statusCode;

  /// The URL of the answer (after any redirect), or `null` when it is not
  /// known.
  final Uri? url;

  /// The `Content-Type` of the answer, or `null` when it had none.
  final String? contentType;

  /// The page's `<title>`, or `null` when it has none. Smartschool's own
  /// pages, its login page and its error pages alike, are titled with the
  /// school's name (`<school> - Smartschool`).
  final String? title;

  /// The page's first `<h1>`, or else its first `<h2>`, or `null` when it
  /// has neither. On Smartschool's own error pages, it says what went wrong
  /// (such as "De opgevraagde pagina kon niet worden gevonden").
  final String? heading;

  /// The start of the page's text, without its scripts, styles and forms, or
  /// `null` for a page without text: its first [maxExcerptLength]
  /// characters, followed by `...` when it goes on. Not in the [message].
  final String? excerpt;

  /// Whether the page holds Smartschool's login form (`login_form`) or its
  /// account verification form (`account_verification_form`), the forms the
  /// client fills in when it logs in.
  final bool isLoginPage;

  /// How many characters of the page's [title] and [heading] are kept: a
  /// longer one is cut off there, and ends in `...`.
  static const maxLabelLength = 120;

  /// How many characters of the page's text [excerpt] keeps.
  static const maxExcerptLength = 200;

  const SmartschoolUnexpectedPageError(
    super.message, {
    this.action,
    this.statusCode,
    this.url,
    this.contentType,
    this.title,
    this.heading,
    this.excerpt,
    this.isLoginPage = false,
  });

  /// The error for [page], the HTML that Smartschool answered the XML command
  /// [action] with, with the [statusCode], [url] and [contentType] of that
  /// answer.
  ///
  /// Reads the [title], [heading], [excerpt] and [isLoginPage] from [page],
  /// and builds a [message] that says what the page is.
  factory SmartschoolUnexpectedPageError.fromPage(
    String page, {
    required String action,
    int? statusCode,
    Uri? url,
    String? contentType,
  }) {
    final document = html_parser.parse(page);
    final isLoginPage = document.querySelector(_loginForms) != null;
    final title = _label(document.querySelector('title'), maxLabelLength);
    final heading = _label(
      document.querySelector('h1') ?? document.querySelector('h2'),
      maxLabelLength,
    );
    final excerpt = _label(document.body, maxExcerptLength);

    final details = [
      'status ${statusCode ?? 'unknown'}',
      ?contentType,
      if (title != null) 'title "$title"',
      if (heading != null) 'heading "$heading"',
    ].join(', ');
    final what = isLoginPage
        ? 'its login page ($details). It did not accept the session, although '
              'not in a way that makes the client log in again (a 401, or a '
              'redirect to its login chain)'
        : 'a page that is not its login page ($details), so not a sign of an '
              "expired session: Smartschool's web client reports such an "
              'answer as an unknown error';
    return SmartschoolUnexpectedPageError(
      'Smartschool returned HTML instead of XML for "$action": $what.'
      '${url == null ? '' : ' Response URL: $url'}',
      action: action,
      statusCode: statusCode,
      url: url,
      contentType: contentType,
      title: title,
      heading: heading,
      excerpt: excerpt,
      isLoginPage: isLoginPage,
    );
  }

  /// The forms that the client's login fills in.
  static const _loginForms =
      'form[name="login_form"], form[name="account_verification_form"]';

  /// The elements whose content is left out of the text of a page: what is
  /// not its text (scripts, styles, and the like), and its forms, whose lists
  /// and fields can name people.
  static const _notText = {
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'iframe',
    'object',
    'form',
    'select',
    'textarea',
  };

  static final _whiteSpace = RegExp(r'\s+');
  static final _email = RegExp(r'[^\s@<>()"]+@[^\s@<>()"]+\.[A-Za-z]{2,}');
  static final _tokenLike = RegExp(r'[A-Za-z0-9_+/=\-]{24,}');
  static final _digit = RegExp(r'\d');

  /// The text of [node] on one line, without the content of [_notText], with
  /// e-mail addresses and token-like strings masked, cut off after [max]
  /// characters; `null` when nothing is left.
  ///
  /// Its pieces of text are joined with a space, so that the text of one
  /// block does not run into the next one (where a word could run into an
  /// e-mail address).
  static String? _label(html_dom.Node? node, int max) {
    if (node == null) return null;
    final pieces = <String>[];
    void collect(html_dom.Node parent) {
      for (final child in parent.nodes) {
        if (child is html_dom.Text) {
          pieces.add(child.data);
        } else if (child is! html_dom.Element ||
            !_notText.contains(child.localName)) {
          collect(child);
        }
      }
    }

    collect(node);
    final masked = pieces
        .join(' ')
        .replaceAll(_whiteSpace, ' ')
        .trim()
        .replaceAll(_email, '[e-mail]')
        .replaceAllMapped(
          _tokenLike,
          (match) => _digit.hasMatch(match[0]!) ? '[token]' : match[0]!,
        );
    if (masked.isEmpty) return null;
    final characters = masked.runes;
    if (characters.length <= max) return masked;
    return '${String.fromCharCodes(characters.take(max))}...';
  }
}

/// Thrown when Smartschool cannot be reached: the host does not resolve, the
/// connection is refused or drops, a request times out, or the TLS handshake
/// fails.
///
/// A network problem, not a failed login: it is deliberately not a
/// [SmartschoolAuthenticationError], so an app can tell the user to check
/// their connection rather than their password.
///
/// `SmartschoolClient.ensureAuthenticated()` throws it, and so do the request
/// methods of `SmartschoolClient` (`getJson`, `postXml`, `getRaw`, …) and so
/// every service call, also when the network fails halfway through a login
/// the request triggered. Only a request made on `SmartschoolClient.dio`
/// directly gets the plain `DioException` instead.
class SmartschoolConnectionError extends SmartschoolException {
  /// The underlying error, typically the `DioException` the request failed
  /// with (its own `error` holds the `SocketException`, if any).
  final Object? cause;

  const SmartschoolConnectionError(super.message, {this.cause});
}

/// Thrown by a `SmartschoolClient` that was disposed (`dispose()`, #54): by
/// every request method, and so by every service call, before it sends
/// anything, and by a request that was running when the client was disposed
/// and did not complete. The stream of a download that was being read ends
/// with it too. Its [message] starts with "SmartschoolClient was disposed".
///
/// A type of its own, so that a caller can tell it apart from any other
/// [StateError] (such as the "No element" of a `.first` in its own code)
/// without matching the message (#73). Catch it to stop work that outlives
/// the client, such as a walk over many folders that the app shut down
/// halfway; `SmartschoolClient.isDisposed` tells the same without an error.
///
/// It is a [StateError], so an `on StateError` clause still catches it, and
/// deliberately not a [SmartschoolException]: using a disposed client is a
/// mistake of its caller, not a problem of Smartschool or of the network, so
/// code that shows "offline" or retries on a [SmartschoolConnectionError]
/// does not take it for one. Create a new client to use Smartschool again.
class SmartschoolClientDisposedError extends StateError {
  SmartschoolClientDisposedError(super.message);
}

/// Thrown when parsing server response data fails.
///
/// `SmartschoolClient.postXml`, and so every call of `MessagesService` that
/// sends an XML command, throws it for an answer that is neither XML nor
/// HTML: one that is empty or does not start with `<`, and malformed XML,
/// whose message says where the XML breaks off but not what it holds
/// (#110). For HTML it throws a [SmartschoolUnexpectedPageError].
/// `MessagesService.searchRecipientsForCompose` and
/// `searchRecipientsForComposeAll` throw both the same way for an answer to
/// a recipient search that is not XML (#112), where an empty answer with
/// status `200` holds no one.
class SmartschoolParsingError extends SmartschoolException {
  const SmartschoolParsingError(super.message);
}

/// Thrown when a network request returns a non-200 status.
class SmartschoolDownloadError extends SmartschoolException {
  final int statusCode;

  SmartschoolDownloadError(super.message, this.statusCode);

  @override
  String toString() => '$runtimeType($statusCode): $message';
}

/// Thrown when a download is larger than the `maxBytes` its caller allows
/// (#41), by `SmartschoolClient.download` and `downloadStream`, and so by
/// `IntradeskService.downloadFile` and `downloadFileStream` and by
/// `MessageAttachment.download` and `downloadStream`.
///
/// When Smartschool announces the size of the file (`Content-Length`) and it
/// is larger than [maxBytes], the download fails before any of the content
/// is read, and [contentLength] holds that size. Otherwise the bytes are
/// counted as they come in, and the download fails as soon as more than
/// [maxBytes] came in: `download` throws this error, and the stream of
/// `downloadStream` ends with it, after at most [maxBytes] bytes.
///
/// Either way the client stops the transfer: it closes the connection
/// rather than reading the rest of the file.
///
/// Not a [SmartschoolDownloadError]: Smartschool answered with the file
/// (HTTP `200`); the caller's limit is what stopped it.
class SmartschoolDownloadTooLargeError extends SmartschoolException {
  /// The largest size, in bytes, that the caller allowed.
  final int maxBytes;

  /// The size of the file in bytes as Smartschool announced it
  /// (`Content-Length`), or `null` when it announced none. When it is not
  /// larger than [maxBytes] (or `null`), the download failed on the bytes
  /// that came in: more than [maxBytes] of them.
  final int? contentLength;

  const SmartschoolDownloadTooLargeError(
    super.message, {
    required this.maxBytes,
    this.contentLength,
  });
}

/// Thrown when JSON decoding of a response body fails.
class SmartschoolJsonError extends SmartschoolDownloadError {
  SmartschoolJsonError(super.message, super.statusCode);
}

/// Thrown by `IntradeskService.getFolderListing` when Smartschool knows no
/// Intradesk folder with the given ID: an unknown ID, or the ID of a file or
/// a weblink (#37).
///
/// Smartschool answers the listing of such an ID with HTTP `500` and a bare
/// `Internal Server Error` problem, the same answer as for a failure of its
/// own, so the answer alone does not tell them apart. When a listing fails
/// with `500`, `getFolderListing` therefore asks Smartschool for the parents
/// of the folder (`folders/{id}/parents`), which it answers with `404` for an
/// ID that is not a folder, and with the parents for a folder. Only that
/// `404` makes this error; any other answer keeps the plain
/// [SmartschoolDownloadError] of the listing.
///
/// It is a [SmartschoolDownloadError] with the [statusCode] of the listing
/// (`500`), so a `catch` of that type still catches it.
class SmartschoolIntradeskFolderNotFoundError extends SmartschoolDownloadError {
  /// The ID that was asked for.
  final String folderId;

  SmartschoolIntradeskFolderNotFoundError(this.folderId)
    : super(
        'Intradesk has no folder with ID "$folderId": the ID is unknown, or '
        'it is the ID of a file or a weblink.',
        500,
      );
}

/// Thrown when uploading a message attachment fails.
class SmartschoolAttachmentUploadError extends SmartschoolException {
  const SmartschoolAttachmentUploadError(super.message);
}

/// Thrown when Smartschool's message compose form cannot be used: its hidden
/// fields (`uniqueUsc`, `randomDir`) or the IDs of the current user are
/// missing from it, or Smartschool does not register a recipient on it (its
/// answer to `addUserToSelected` does not name the recipient; the message
/// names it, #39). `MessagesService.sendReply` also throws it when
/// Smartschool does not answer with the reply form of the message (#26), or
/// does not take a recipient that the reply form names and the params leave
/// out off the form (its answer to `deleteUsersFromSelected` does not list
/// the recipient; the message names it, #42). Both throw it too when the
/// form does not offer an option that the send asks for: the LVS copy of
/// `MessageSendOptions.lvsCopy`, or the delayed send of
/// `MessageSendOptions.sendAt` (#47).
///
/// `MessagesService.sendMessage` and `sendReply` throw it before the message
/// is submitted, so nothing was sent. A submitted message that Smartschool
/// does not confirm as sent is a [SmartschoolSendUnconfirmedError] instead
/// (#25).
class SmartschoolComposeError extends SmartschoolException {
  const SmartschoolComposeError(super.message);
}

/// Thrown by `MessagesService.sendMessage` (and `sendReply`, #26) when the
/// message was submitted, but Smartschool's answer does not confirm that it
/// was sent (#25).
///
/// **The message may or may not have been sent.** Do not send it again
/// blindly: check the sent box first (e.g. `getHeaders(boxType:
/// BoxType.sent)`), or tell the user to. A message sent with a delayed send
/// (`MessageSendOptions.sendAt`, #47) waits in the scheduled box
/// (`BoxType.scheduled`) until its time; the message of the error says so.
///
/// Smartschool confirms a sent message by answering the submit with HTTP
/// `200` and a page that closes the compose window (`window.close()`). This
/// error is thrown when:
///
/// - the answer is anything else: another status (in [statusCode]), or a
///   page without `window.close()` or with an error marker;
/// - the submit failed after it went out, before an answer came in: the
///   connection dropped or timed out ([cause] holds the failure, typically a
///   [SmartschoolConnectionError]).
///
/// Every other failure of `sendMessage` means the message was not sent, and
/// it is safe to call `sendMessage` again: a failure before the submit (such
/// as a [SmartschoolComposeError], a [SmartschoolAttachmentUploadError], a
/// [SmartschoolConnectionError] or a login failure), or Smartschool refusing
/// the session for a step of the send, the submit included, before handling
/// it, or the client not sending a step because it logged in again since it
/// loaded the compose form (both a [SmartschoolSessionExpiredError], #38).
///
/// Deliberately not a [SmartschoolComposeError], so a `catch` meant for the
/// failures that are safe to retry does not catch it.
class SmartschoolSendUnconfirmedError extends SmartschoolException {
  /// The HTTP status of Smartschool's answer to the submit, or `null` when no
  /// answer came in (see [cause]).
  final int? statusCode;

  /// The failure of the submit when no answer came in, typically a
  /// [SmartschoolConnectionError]; `null` when Smartschool answered.
  final Object? cause;

  const SmartschoolSendUnconfirmedError(
    super.message, {
    this.statusCode,
    this.cause,
  });
}

/// Thrown by `MessagesService.moveToTrashFrom` when its move to the trash
/// went out and Smartschool answered it, but the check after it failed
/// (#115).
///
/// `moveToTrashFrom` sends Smartschool's `quickmove messages`, which
/// Smartschool answers the same whether it moved a message or not, and then
/// checks the move with a `show message` in the box it moved the copy out
/// of (#96). When that check throws, this error is thrown with the check's
/// error as its [cause]: a [SmartschoolSessionExpiredError] (Smartschool did
/// not accept the session for the check, also after the client logged in
/// again), a [SmartschoolUnexpectedPageError] or a [SmartschoolParsingError]
/// (an answer that is not XML), a [SmartschoolConnectionError], or another
/// failure of a login for the check.
///
/// **The move went out and may have been made.** Do not send it again
/// blindly: ask the box first, with `MessagesService.getMessage(msgId,
/// boxType: boxType)`, which returns `null` once the box (none of its
/// folders) holds the message any more. [msgId], [boxType] and [boxId] are
/// those of the move.
///
/// Every other failure of `moveToTrashFrom` is the move's own: an
/// [ArgumentError] before any request, or an error of the move's request,
/// such as a [SmartschoolSessionExpiredError] when Smartschool did not
/// accept the session for the move, also after the client logged in again
/// (the move was not carried out). So a caller that sends a call again on a
/// [SmartschoolSessionExpiredError] does not send a move again that went
/// out.
///
/// Deliberately not a [SmartschoolAuthenticationError], whatever its
/// [cause], so a `catch` meant for the session refused for the move does
/// not catch it.
class SmartschoolMoveUncheckedError extends SmartschoolException {
  /// The ID of the message whose copy was moved.
  final int msgId;

  /// The box the copy was moved out of, which the check asked.
  final BoxType boxType;

  /// The folder of [boxType] the copy was moved out of; `0` for the box
  /// itself.
  final int boxId;

  /// What the check failed with.
  final Object cause;

  const SmartschoolMoveUncheckedError(
    super.message, {
    required this.msgId,
    required this.boxType,
    this.boxId = 0,
    required this.cause,
  });
}

/// Thrown by `MessagesService.getHeaderPages` and `getArchiveHeaderPages`,
/// and so by `getAllHeaders` and `getAllArchiveHeaders`, when Smartschool
/// restarted the paging of the box halfway: the box was listed again while
/// it was being paged (#76).
///
/// Smartschool keeps the paging position per user and box, not in the
/// session: every `message list` of the box restarts it, in any session of
/// the account, and every `continue_messages` moves it on, whichever paging
/// sent it. A listing of the box on the same client (a `getHeaders`, also in
/// poll mode, or a paging of the box started later) is seen coming: the
/// paging throws this error at its next page, before it asks Smartschool for
/// it (#80). A listing elsewhere (by another client or app, or the user
/// opening the box in Smartschool's web client) shows in the answer: the
/// next `continue_messages` answers with the second page again, and the
/// paging recognises it, a page that holds headers which were all emitted
/// already, and throws this error instead of ending as after the last page.
///
/// The pages emitted before it are correct, but they are not the whole box.
/// List the box again (for instance call `getAllHeaders` again).
///
/// Not every clash of two listings of a box shows: two pagings of the same
/// box at the same time in different clients or apps can skip each other's
/// pages without this error (see `MessagesService.getHeaderPages`).
///
/// The session was accepted, so this is not a
/// [SmartschoolSessionExpiredError]: signing in again does not help.
class SmartschoolPagingRestartedError extends SmartschoolException {
  const SmartschoolPagingRestartedError(super.message);
}

/// Thrown when a Presence (attendance) operation fails.
///
/// This covers a rejected save (the server returns a non-empty `errors[]`
/// array, exposed via [saveErrors], typed, and [errors], as text), a request
/// the Presence module refuses or cannot handle (it answers with an HTML page
/// instead of JSON, such as its generic `500` error page: the request is
/// invalid, or the account may lack Presence access), and precondition
/// failures such as an unknown class, an unresolvable status code, or a pupil
/// not present in the class. The session was accepted for all of them, so
/// signing in again does not help.
///
/// A half-day that `setLate` or `setPresent` refuses to change because it
/// holds a status their `onlyReplacing` does not allow is reported with the
/// subtype [SmartschoolPresenceChangeRefusedError] (#105): nothing was sent.
///
/// A session that Smartschool does not accept is not reported with this type
/// but as a [SmartschoolSessionExpiredError] (a
/// [SmartschoolAuthenticationError]), like any other authentication failure.
class SmartschoolPresenceError extends SmartschoolException {
  /// The errors of a save the Presence module refused, as text: the
  /// [PresenceSaveError.message] of each of [saveErrors], the module's reason
  /// (#109). Empty for precondition failures raised client-side.
  ///
  /// The pupil's name, which the module gives with the record of each error,
  /// is not in them, nor in [toString], which shows them.
  final List<String> errors;

  /// The errors of a save the Presence module refused (the `errors[]` of its
  /// answer), typed (#109): each with the module's reason and the record that
  /// was not saved (its day, half of the day, the pupil's `userID`, and the
  /// pupil's name, which is in no message). Empty for precondition failures
  /// raised client-side, and for an error made without them.
  final List<PresenceSaveError> saveErrors;

  const SmartschoolPresenceError(
    super.message, {
    this.errors = const [],
    this.saveErrors = const [],
  });

  @override
  String toString() => errors.isEmpty
      ? '$runtimeType: $message'
      : '$runtimeType: $message (${errors.join('; ')})';
}

/// Thrown by `PresenceService.setLate` and `setPresent` when the half-day
/// holds a status that their `onlyReplacing` does not allow (#105). Nothing
/// was sent.
///
/// The check looks at the half-day as the call read it right before the
/// save (`Presence/Class/getClass`), so a status recorded meanwhile, such as
/// an absence the secretariat recorded, is not overwritten. Its message
/// names the pupil, the half-day, what it holds and what `onlyReplacing`
/// allows.
///
/// A [SmartschoolPresenceError], so `catch` clauses for that type keep
/// catching it; its [errors] is empty.
class SmartschoolPresenceChangeRefusedError extends SmartschoolPresenceError {
  /// The pupil's internal `userID`.
  final int userId;

  /// The half of the day the call would have changed.
  final DayPart part;

  /// The day the call would have changed (`yyyy-MM-dd`).
  final String date;

  /// The half-day as the call read it right before the save, or `null` when
  /// the pupil had no record for it.
  final PresenceHalfDay? halfDay;

  /// The name of the status the half-day holds, as
  /// `PresenceService.statusNameOf` gives it: the name of its code or alias,
  /// `PresenceService.nothingRecorded` (`""`) when it holds nothing, or
  /// `null` when it holds a code or alias that is not among the codes of the
  /// class's school structure (see [halfDay] for its ID).
  final String? heldStatus;

  /// The statuses the call allowed the half-day to hold (its
  /// `onlyReplacing`), as passed.
  final Set<String> onlyReplacing;

  const SmartschoolPresenceChangeRefusedError(
    super.message, {
    required this.userId,
    required this.part,
    required this.date,
    this.halfDay,
    this.heldStatus,
    this.onlyReplacing = const {},
  });
}

/// Thrown by `SkoreService` when Smartschool's Skore module (grading and
/// reports) does not give what was asked for. The session was accepted:
/// signing in again does not help. A Skore RPC answer that carries no session
/// is reported as a [SmartschoolSessionExpiredError] instead.
///
/// Three cases, which a caller handles differently, have a type each (#83):
/// - [SmartschoolSkoreAccessDeniedError]: Skore refused the request to the
///   account, which lacks the rights for that part of Skore (its `area`).
/// - [SmartschoolSkoreChangeRefusedError]: a check before a save refused the
///   change (its subtype [SmartschoolSkoreMyGroupsError] too). Its message
///   says why, so the call can be corrected.
/// - This type itself (none of its subtypes): Skore answered with something
///   the service cannot use: another HTTP status than `200`, an HTML page
///   instead of data, an answer that is not valid JSON, an RPC answer without
///   its `result`, or data in a shape it does not recognise (such as an
///   assignments page without its table of courses, a non-numeric ID, or a
///   `getMyGroups` answer it does not know). Its message may quote the
///   answer, which can hold names: keep it in a log.
///
/// A teacher without the rights gets a [SmartschoolSkoreAccessDeniedError]
/// from every call, not this type itself, and never an empty list (seen
/// live, #91). What Skore answers a pupil, and an account with only one of
/// the two rights, was not captured.
///
/// From the writes (`SkoreService.addTeacher`, `replaceTeacher`, #71;
/// `shareGradebook`, `unshareGradebook`, #74), this type and all its subtypes
/// always mean that **nothing was saved**: a read before the save failed, or
/// a check refused the change. A save that went out without Skore confirming
/// it is a [SmartschoolSkoreSaveUnconfirmedError] instead.
class SmartschoolSkoreError extends SmartschoolException {
  const SmartschoolSkoreError(super.message);
}

/// Thrown by `SkoreService` when Skore refuses a request because the account
/// lacks the rights for the part of Skore it belongs to ([area]) (#83):
/// report management (Rapporten > Modellen) or gradebook management
/// (Puntenboeken). An account can have one without the other. Ask the
/// school's Smartschool administrator for the rights.
///
/// Thrown when Skore sends the request on to Smartschool's start page (a
/// redirect to `/?module=Homepage`): its answer to every request of the
/// service from a teacher without Skore's management rights, seen live
/// (#91). The request was refused: no data came. Also thrown when Skore
/// answers with HTTP 403 (Forbidden), HTTP's own answer for a request the
/// server refuses to the account (#83; not seen from Skore). What Skore
/// answers a pupil, and an account with only one of the two rights, was not
/// captured. `SkoreService.checkAccess` tells which parts the account can
/// use.
///
/// Its message names the request and the part of Skore, and quotes nothing
/// of the answer, so it can be shown to the user. A
/// [SmartschoolSkoreError], so `catch` clauses for that type keep catching
/// it. From the writes, it comes from a read before the save: nothing was
/// saved. When Skore answers a save itself so, the write throws a
/// [SmartschoolSkoreSaveUnconfirmedError] with this error as its `cause`.
class SmartschoolSkoreAccessDeniedError extends SmartschoolSkoreError {
  /// The part of Skore the refused request belongs to.
  final SkoreAccessArea area;

  const SmartschoolSkoreAccessDeniedError(super.message, {required this.area});

  @override
  String toString() => '$runtimeType(${area.name}): $message';
}

/// Thrown by the writes of `SkoreService` when a check before the save
/// refuses the change, after reading Skore again (#83). **Nothing was
/// saved.**
///
/// The checks of `addTeacher` and `replaceTeacher` (#71): the course is not
/// in the class (also for a class ID Skore does not know) or is a group
/// header; the assignment is not one of that course; the teacher already has
/// an assignment on that course (for a replace, the current teacher of the
/// assignment too), or is not one Skore lets assign (`getTeachers`); the
/// current teacher works with "Mijn lesgroepen" for the course
/// ([SmartschoolSkoreMyGroupsError], a subtype). The checks of
/// `shareGradebook` and `unshareGradebook` (#74): the teacher is the owner of
/// the gradebook, the gradebook is not one of the owner's (also for a user ID
/// Skore does not know), or (to share) the teacher is not one of Skore's
/// teachers.
///
/// Its message says which check refused and why, with the IDs (and the
/// course label or teacher name it read), and quotes nothing else of Skore's
/// answers, so it can be passed on to correct the call. A
/// [SmartschoolSkoreError], so `catch` clauses for that type keep catching
/// it. A `getMyGroups` answer the service does not recognise is not a
/// refused change but a plain [SmartschoolSkoreError] (nothing saved either).
class SmartschoolSkoreChangeRefusedError extends SmartschoolSkoreError {
  const SmartschoolSkoreChangeRefusedError(super.message);
}

/// Thrown by `SkoreService.replaceTeacher` when the current teacher of the
/// assignment works with "Mijn lesgroepen" (their own groups of pupils) for
/// the course (#71). Nothing was saved.
///
/// Skore's web client offers to delete those groups before it gives the
/// course another teacher, which cannot be undone. The service never deletes
/// them: handle the groups in Skore itself first.
///
/// A [SmartschoolSkoreChangeRefusedError] (#83), like the other checks
/// before the save.
class SmartschoolSkoreMyGroupsError extends SmartschoolSkoreChangeRefusedError {
  /// The Skore class ID of the assignment.
  final int classId;

  /// The Skore course ID of the assignment.
  final int courseId;

  /// The Smartschool user ID of the current teacher, the one with the groups.
  final int teacherId;

  /// The name of the current teacher as Skore shows it (`"Last, First"`), as
  /// `replaceTeacher` read it from the class before it asked about the groups
  /// (#102). `replaceTeacher` always sets it; `null` only for an error made
  /// without it.
  final String? teacherName;

  const SmartschoolSkoreMyGroupsError(
    super.message, {
    required this.classId,
    required this.courseId,
    required this.teacherId,
    this.teacherName,
  });
}

/// Thrown when Smartschool's planner answers a request with something
/// `PlannerService` cannot use (#84): another HTTP status than `200` (in
/// [statusCode], such as `400` for a calendar ID or a date range the planner
/// refuses), an HTML page instead of data, an answer that is not valid JSON,
/// or data in a shape it does not recognise (such as an element without its
/// `id` or `period`, or the detail of another element than the one asked
/// for).
///
/// The session was accepted: signing in again does not help. A session that
/// Smartschool does not accept is a [SmartschoolSessionExpiredError]
/// instead.
///
/// An element the planner does not know is a
/// [SmartschoolPlannedElementNotFoundError], a subtype of this one; a write
/// that a check refused before it was sent is a
/// [SmartschoolPlannerWriteRefusedError], another one.
///
/// From the writes of `PlannerService` (`planLesson`, `renameElement`,
/// `changePublicInfo`, `changePrivateInfo`, `clearLesson`, #87;
/// `planLessonContent`, #88; `planAssignment`, `trashAssignment`, #89), this
/// type and its subtypes always mean that **nothing was sent**: the read
/// before the write failed, or a check refused it. A write that went out without
/// the planner confirming it is a [SmartschoolPlannerSaveUnconfirmedError]
/// instead.
class SmartschoolPlannerError extends SmartschoolException {
  /// The HTTP status of the planner's answer when it was not `200`; `null`
  /// when the answer had status `200` but could not be used.
  final int? statusCode;

  const SmartschoolPlannerError(super.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? '$runtimeType: $message'
      : '$runtimeType($statusCode): $message';
}

/// Thrown by `PlannerService.getPlannedElement` and `getDetail` when the
/// planner answers `404`: it has no element of that type with that ID (#84).
/// The ID is unknown, or the element was removed or moved to the trash (a
/// lesson hour that was cleared comes back as a timetable slot with a new
/// ID). The planner answers a type name it does not have, given to
/// `getPlannedElement` as its `typeName`, with `404` too (#99).
///
/// A [SmartschoolPlannerError] with [statusCode] `404`.
class SmartschoolPlannedElementNotFoundError extends SmartschoolPlannerError {
  /// The planner's name of the element type that was asked for
  /// (`planned-lessons`).
  final String elementType;

  /// The platform ID that was asked for.
  final int platformId;

  /// The element ID that was asked for.
  final String elementId;

  const SmartschoolPlannedElementNotFoundError(
    super.message, {
    required this.elementType,
    required this.platformId,
    required this.elementId,
  }) : super(statusCode: 404);
}

/// Thrown by the writes of `PlannerService` (#87) when a check before the
/// write refuses it, after reading the element again. **Nothing was sent**:
/// the planner was not changed.
///
/// The checks keep the writes to the authenticated user's own planner, as
/// far as the planner tells: the element must be organised by the
/// authenticated user (`organisers.users`), and the planner's capabilities
/// must allow the change (`canUserReplace` to fill a timetable slot,
/// `canUserEdit` with `canUserRename`, `canUserChangePublicInfo` or
/// `canUserChangePrivateInfo` to edit, `canUserEdit` to clear,
/// `canUserTrash` to move an assignment to the trash). A slot must still be
/// a slot, in the period it was read with. A lesfiche planned into a slot
/// (`planLessonContent`, #88) must be a lesson lesfiche among the user's
/// lesfiches. A new assignment (`planAssignment`, #89) must be of one of the
/// school's assignment types, and an assignment moved to the trash
/// (`trashAssignment`, #89) must not have a linked Skore evaluation.
///
/// Which check refused is a value an app can switch on (#100): [reason],
/// with the [element] the check read (to name it in the app's own words:
/// its period, name, classes, course and organisers), the
/// [capabilityFlags] it missed or found, and for a lesfiche that is not a
/// lesson one the [lessonContent]. The [message] says the same for a log,
/// in the library's words: it names the method, the element by its type,
/// ID and period, and ends with "Nothing was sent.".
///
/// A [SmartschoolPlannerError] (without a [statusCode]), so that from the
/// writes that type always means nothing was sent. An element that is gone
/// when it is read again (such as a slot that was filled since it was read)
/// is a [SmartschoolPlannedElementNotFoundError] instead, also before
/// anything was sent.
class SmartschoolPlannerWriteRefusedError extends SmartschoolPlannerError {
  /// Which check refused the write (#100). `PlannerService` always sets it;
  /// `null` only for an error made without it.
  final PlannerWriteRefusalReason? reason;

  /// The element the write was for, as the write read it again before the
  /// check (its detail, a [PlannedElementDetail]): the slot to fill, the
  /// element to edit, the lesson to clear, the assignment to trash. For
  /// [PlannerWriteRefusalReason.periodChanged] it has the period the slot
  /// has now, for [PlannerWriteRefusalReason.notOwn] its organisers.
  ///
  /// `null` when the check refused before an element was read
  /// ([PlannerWriteRefusalReason.unknownLessonContent],
  /// [PlannerWriteRefusalReason.notALessonLessonContent],
  /// [PlannerWriteRefusalReason.unknownAssignmentType]), and for an error
  /// made without it.
  final PlannedElement? element;

  /// The capability flags of [element] the check refused on, by the
  /// planner's names: for [PlannerWriteRefusalReason.notAllowed] the flags
  /// the write needs that are not set (such as `canUserReplace`), for
  /// [PlannerWriteRefusalReason.trashable] the ones set of `canUserTrash`
  /// and `canUserDelete`. Empty for the other reasons.
  final List<String> capabilityFlags;

  /// For [PlannerWriteRefusalReason.notALessonLessonContent], the lesfiche
  /// that is not a lesson one, as `planLessonContent` read it again (without
  /// the names of its courses: `LessonContentCourse.name` is `null`); `null`
  /// otherwise.
  final LessonContentItem? lessonContent;

  const SmartschoolPlannerWriteRefusedError(
    super.message, {
    this.reason,
    this.element,
    this.capabilityFlags = const [],
    this.lessonContent,
  });

  @override
  String toString() => reason == null
      ? super.toString()
      : '$runtimeType(${reason!.name}): $message';
}

/// Thrown by the writes of `PlannerService` (#87) when the write went out to
/// the planner, but the planner's answer does not confirm it.
///
/// **The change may or may not have been made.** Read the element again
/// (`PlannerService.getDetail`) before trying again; the message says what
/// to read. For the fill of a timetable slot (`planLesson`,
/// `planLessonContent`), the clear of a lesson (`clearLesson`) and the move
/// of an assignment to the trash (`trashAssignment`, #89), the planner
/// answers the element they replaced or trashed with `404` once the change
/// went through. Calling those methods again is safe in itself: they read
/// the element first, so a fill, a clear or a trash that did go through is
/// not made a second time, and an edit that did is not sent again. **Not so
/// for the create of an assignment** (`planAssignment`, #89): there is no
/// element to read first, and calling it again adds a second assignment
/// when the first was made. Look for it in the calendar of one of its
/// classes first.
///
/// Thrown when the planner answers the write with another status than the
/// one it gives on success (`200`; `201` or `200` for the create of an
/// assignment) ([statusCode]), an answer that is not the element as
/// expected (another type, name, assignment type, period, info text or
/// element), or an answer the service cannot use; when the element is
/// still there after its move to the trash; and when the write failed after
/// it went out, before a usable answer came in ([cause] holds the failure,
/// typically a [SmartschoolConnectionError]).
///
/// A session that Smartschool refuses for the write is not this error but a
/// [SmartschoolSessionExpiredError] (or another
/// [SmartschoolAuthenticationError]): Smartschool refused it before handling
/// it, so the planner was not changed.
///
/// Deliberately not a [SmartschoolPlannerError], so a `catch` meant for the
/// failures where nothing was sent does not catch it.
class SmartschoolPlannerSaveUnconfirmedError extends SmartschoolException {
  /// The HTTP status of the planner's answer to the write, or `null` when no
  /// answer came in (see [cause]).
  final int? statusCode;

  /// The failure of the write when no usable answer came in: a
  /// [SmartschoolConnectionError], or a [SmartschoolPlannerError] about the
  /// answer; `null` when the planner answered with an element that does not
  /// confirm the write.
  final Object? cause;

  const SmartschoolPlannerSaveUnconfirmedError(
    super.message, {
    this.statusCode,
    this.cause,
  });

  @override
  String toString() => statusCode == null
      ? '$runtimeType: $message'
      : '$runtimeType($statusCode): $message';
}

/// Thrown when Smartschool's Lesfiches module (lesson content), or the
/// school's course list that names the courses of the lesfiches (#101),
/// answers a request with something `LessonContentService` cannot use
/// (#88): another HTTP status than `200` (in [statusCode]), an HTML page
/// instead of data (the module answers a route it does not know with its web
/// app), an answer that is not valid JSON, or data in a shape it does not
/// recognise (such as a lesfiche without its `id` or `type`, or a course
/// without its `id`).
///
/// The session was accepted: signing in again does not help. A session that
/// Smartschool does not accept is a [SmartschoolSessionExpiredError]
/// instead.
///
/// `PlannerService.planLessonContent` reads the lesfiches before it plans
/// one; this error from it means that **nothing was sent** to the planner.
class SmartschoolLessonContentError extends SmartschoolException {
  /// The HTTP status of the module's answer when it was not `200`; `null`
  /// when the answer had status `200` but could not be used.
  final int? statusCode;

  const SmartschoolLessonContentError(super.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? '$runtimeType: $message'
      : '$runtimeType($statusCode): $message';
}

/// Thrown by `SkoreService.addTeacher` and `replaceTeacher` when the save
/// went out to Skore, but Skore's answer does not confirm it (#71).
///
/// **The change may or may not have been saved.** Read the class again
/// (`SkoreService.getCourses`) before trying again. Calling the method again
/// is safe in itself: it reads the class first and refuses a teacher who
/// already has an assignment on the course, so a save that did go through is
/// not made a second time. The service never retries the save itself: an add
/// is not idempotent, so a repeated one would add a second assignment.
///
/// Thrown when Skore answers the save with anything other than the
/// assignment it saved for the teacher asked for (another status, an HTML
/// page, an answer without its `ownerID` and `userID`, another teacher, or,
/// for a replace, another assignment), and when the save failed after it
/// went out, before an answer came in ([cause] holds the failure, typically
/// a [SmartschoolConnectionError]).
///
/// Also thrown by `SkoreService.shareGradebook` and `unshareGradebook` (#74)
/// when Skore answers their save (`saveShared`) with anything other than
/// `state` 1, when no usable answer came in, and when reading the owner's
/// gradebooks again afterwards fails, or does not show the gradebook with
/// exactly the readers and writers saved. Read the gradebooks again
/// (`SkoreService.getGradebookShares`) before trying again. That save holds
/// the complete readers and writers of one gradebook, so sending it again
/// does not change the outcome.
///
/// Deliberately not a [SmartschoolSkoreError], so a `catch` meant for the
/// failures where nothing was saved does not catch it.
class SmartschoolSkoreSaveUnconfirmedError extends SmartschoolException {
  /// The failure of the save when no usable answer came in, such as a
  /// [SmartschoolConnectionError] or a [SmartschoolSkoreError] about the
  /// answer (a [SmartschoolSkoreAccessDeniedError] for an answer that sends
  /// the save on to Smartschool's start page, or with HTTP 403), or of the
  /// read that checks a gradebook share afterwards; `null`
  /// when Skore answered with a result that does not confirm the save.
  final Object? cause;

  const SmartschoolSkoreSaveUnconfirmedError(super.message, {this.cause});
}
