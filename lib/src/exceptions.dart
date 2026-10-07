import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import 'models/intradesk_models.dart'
    show
        IntradeskAddRefusalReason,
        IntradeskFolder,
        IntradeskFolderCapabilities,
        IntradeskItemKind;
import 'models/lesson_content_models.dart'
    show
        LessonContentAttachment,
        LessonContentItem,
        LessonContentType,
        LessonContentVisibility;
import 'models/message_models.dart' show BoxType;
import 'models/planner_models.dart'
    show
        PlannedElement,
        PlannedElementDetail,
        PlannerAssignmentType,
        PlannerWriteRefusalReason;
import 'models/presence_models.dart'
    show
        DayPart,
        PresenceClassRef,
        PresenceHalfDay,
        PresenceSaveError,
        PresenceUnreadableAnswerKind;
import 'models/skore_models.dart'
    show
        SkoreAccessArea,
        SkoreAssignment,
        SkoreCourse,
        SkoreGradebookShares,
        SkoreShareAccess,
        SkoreTeacher;

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
/// of `SmartschoolClient`), or must not be sent twice, such as a create. The
/// client remembers that Smartschool refused the session: its next request
/// logs in before it is sent (#134), so calling the method again sends the
/// request once, in a new session, also when that request is its first.
/// `MessagesService.sendMessage` sends every step after loading the compose
/// form that way (#25): the message was not sent, and calling `sendMessage`
/// again logs in and starts from a new compose form.
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
///
/// The creates of `IntradeskService` throw it too (#128), for a parent
/// folder Smartschool knows no folder for: `createFolder`, `createWeblink`
/// and `uploadFiles`. Since #138 they read the parent first
/// (`IntradeskService.getFolder`), so they throw it from that read, with its
/// [statusCode] (`404` or `200`, below), before anything of the write is
/// sent; also for a parent in Intradesk's trash. A parent that is gone after
/// that read: Smartschool answers the create with the same bare `500` (seen
/// live, 2026-10-05, for a folder in a made-up parent), and the service asks
/// for the parents of the parent folder the same way. Nothing was made then;
/// [folderId] is the parent folder's ID.
///
/// The reads of a folder's own entry throw it too (#132):
/// `IntradeskService.getFolderParentIds`, `getFolder` and `getFolderPath`.
/// There [statusCode] is the status of the answer that showed it:
/// - `404`, Smartschool's answer to the parents of an ID that is not a
///   folder (an unknown ID, or the ID of a file or a weblink);
/// - `200`, when Smartschool answered the parents, but the listing where they
///   put the folder (answered with `200`) does not hold it: a folder in
///   Intradesk's trash (seen live, 2026-10-07: Smartschool answers its
///   parents as those of a top-level folder, `[]`, and the root listing does
///   not hold it), or a folder that the user does not see. The [message]
///   says so.
///
/// `IntradeskService.trashFolder` does not throw it: a move to the trash of
/// an ID Intradesk has no folder for is a
/// [SmartschoolIntradeskItemNotFoundError] (#133), a
/// [SmartschoolIntradeskWriteRefusedError] as before, not a
/// [SmartschoolDownloadError].
class SmartschoolIntradeskFolderNotFoundError extends SmartschoolDownloadError {
  /// The ID that was asked for.
  final String folderId;

  /// [statusCode] is the status of the answer that showed that there is no
  /// such folder: `500` (the default) for a listing or a create, `404` and
  /// `200` for the reads of #132 (see the class doc). [message] replaces the
  /// default message, which says the ID is unknown or names a file or a
  /// weblink.
  SmartschoolIntradeskFolderNotFoundError(
    this.folderId, {
    int statusCode = 500,
    String? message,
  }) : super(
         message ??
             'Intradesk has no folder with ID "$folderId": the ID is unknown, '
                 'or it is the ID of a file or a weblink.',
         statusCode,
       );
}

/// Thrown by the writes of `IntradeskService` (#128) when Intradesk refused
/// the write: it answered with an HTTP status from `400` to `499`. **Nothing
/// was made**: no folder, weblink or file was added, and nothing was moved
/// to the trash. Seen live (2026-10-05): the listing of the folder showed
/// nothing new after each such answer.
///
/// Intradesk says why in [violations], in its own words (Dutch), when it
/// gives a reason; seen live with HTTP `400`:
/// - `createWeblink` with an address that is not a valid URL: "De URL die je
///   hebt ingegeven is niet geldig." (`createWeblink` checks the URL the way
///   the web client does before it sends anything, so this only comes from
///   an address that Intradesk refuses after all);
/// - `createFolder(confidential: true)` in an ordinary folder: "In een gewone
///   map kan je enkel gewone mappen toevoegen. Vertrouwelijke mappen kan je
///   hier niet toevoegen." (Since #138 the service does not send that: it
///   reads the parent first and throws a
///   [SmartschoolIntradeskAddRefusedError] instead.)
///
/// `uploadFiles` throws it when Intradesk refuses to take the files of the
/// upload directory, such as a directory that holds no files (seen live:
/// HTTP `400` without violations). The files stay in the upload directory,
/// which is not used again.
///
/// The moves to the trash throw its subclass
/// [SmartschoolIntradeskItemNotFoundError] for Intradesk's `404`: it has no
/// item of that kind with that ID (#133).
///
/// The creates throw its subclass [SmartschoolIntradeskAddRefusedError]
/// when the service refused the write itself, after reading the parent
/// folder and **before sending it** (#138): the user may not add to it
/// (`canAdd`), or it is of the wrong kind (a confidential folder in an
/// ordinary one, which Intradesk answered with the `400` above before, or an
/// ordinary folder in a confidential one). There is no answer of Intradesk
/// then, so its [statusCode] is `null`.
///
/// The session was accepted: signing in again does not help. A session that
/// Smartschool does not accept for the write is a
/// [SmartschoolSessionExpiredError] instead (nothing was made either: the
/// creates are never sent again after logging in again). A parent folder
/// that Smartschool does not know is a
/// [SmartschoolIntradeskFolderNotFoundError]; Intradesk's answer to other
/// failures, a bare HTTP `500`, is a
/// [SmartschoolIntradeskSaveUnconfirmedError].
class SmartschoolIntradeskWriteRefusedError extends SmartschoolException {
  /// The HTTP status of Intradesk's answer (`400` to `499`); `null` when the
  /// service refused the write itself, before sending it
  /// ([SmartschoolIntradeskAddRefusedError], #138).
  final int? statusCode;

  /// Intradesk's reasons, in its own words, in its order; empty when it
  /// gave none (a bare `{"status":400,"title":"Bad Request"}`).
  final List<String> violations;

  const SmartschoolIntradeskWriteRefusedError(
    super.message, {
    required this.statusCode,
    this.violations = const [],
  });

  @override
  String toString() => '$runtimeType($statusCode): $message';
}

/// Thrown by `IntradeskService.trashFolder`, `trashWeblink` and `trashFile`
/// when Intradesk has no item of that [kind] with that [id] (#133): it
/// answered the move to the trash with `404`. **Nothing was moved to the
/// trash.**
///
/// Seen live (2026-10-07), each answered with
/// `404 {"status":404,"title":"Not Found","detail":"","type":""}` and with
/// nothing moved:
/// - a made-up ID, sent as a folder, a weblink and a file;
/// - the ID of an item of another kind: a file or a weblink sent as a folder
///   (`folders/{fileId}/trash`), a folder or a file as a weblink, a folder
///   or a weblink as a file. The item stayed where it was;
/// - the ID of an item of another kind that is in the trash already.
///
/// So a caller can tell "there is no such item" from a move that went
/// through: Intradesk answers the move of an item that is in the trash
/// already, of its own kind, with `204`, as the first move. An item deleted
/// for good was not tried (the library never deletes for good), nor an item
/// the user may not manage (`capabilities.canManage` false, #139), which may
/// be answered otherwise.
///
/// A [SmartschoolIntradeskWriteRefusedError] with [statusCode] `404` (and
/// Intradesk's [violations], none seen), as a move to the trash answered
/// `404` was before #133, so a `catch` of that type still catches it. Not a
/// [SmartschoolIntradeskFolderNotFoundError], also for a folder: that one is
/// a [SmartschoolDownloadError], the error of a read.
class SmartschoolIntradeskItemNotFoundError
    extends SmartschoolIntradeskWriteRefusedError {
  /// The kind of item the move to the trash asked for: the one Intradesk has
  /// no item of with [id].
  final IntradeskItemKind kind;

  /// The ID that was asked for.
  final String id;

  const SmartschoolIntradeskItemNotFoundError(
    super.message, {
    required this.kind,
    required this.id,
    super.violations,
  }) : super(statusCode: 404);
}

/// Thrown by `IntradeskService.createFolder`, `createWeblink` and
/// `uploadFiles` when the folder they add to does not allow what they add,
/// as Intradesk's web client tells it (#138). **Nothing was sent**: the
/// service read the folder first and refused the write before any request
/// of it (also before an upload step).
///
/// Which rule refused is the [reason] (an app can switch on it), with the
/// folder as the service read it: [parent] (its entry, from
/// `IntradeskService.getFolder`; `null` at the root) and the [capabilities]
/// the rule looked at (the folder's, or at the root the platform's, from
/// `IntradeskService.getRootCapabilities`). The [message] says the same for
/// a log and ends with "Nothing was sent.".
/// - [IntradeskAddRefusalReason.cannotAdd]: the user may not add to the
///   folder (`canAdd` false);
/// - [IntradeskAddRefusalReason.cannotAddConfidentialFolder]: a
///   confidential folder at the root, which the platform does not allow;
/// - [IntradeskAddRefusalReason.ordinaryParent]: a confidential folder in an
///   ordinary folder, which Intradesk refused with HTTP `400` before #138
///   (seen live, 2026-10-05);
/// - [IntradeskAddRefusalReason.confidentialParent]: an ordinary folder in a
///   confidential folder.
///
/// These are the web client's rules, which offers nothing else: Intradesk's
/// own answer was seen live only for [IntradeskAddRefusalReason.ordinaryParent]
/// (the live account is an administrator, with `canAdd` on every folder it
/// sees, none of them confidential).
///
/// A [SmartschoolIntradeskWriteRefusedError] (as the `400` for a
/// confidential folder in an ordinary one was before), so a `catch` of that
/// type still catches it, with [statusCode] `null`: Intradesk did not
/// answer, nothing was sent to it. Not thrown for a parent that the read
/// does not find: that is a [SmartschoolIntradeskFolderNotFoundError], also
/// before anything was sent.
class SmartschoolIntradeskAddRefusedError
    extends SmartschoolIntradeskWriteRefusedError {
  /// Which rule refused the write.
  final IntradeskAddRefusalReason reason;

  /// The ID of the folder the write added to, as the caller gave it: `''`
  /// for the root.
  final String parentFolderId;

  /// The folder the write added to, as the service read it
  /// (`IntradeskService.getFolder`); `null` at the root, which has no entry.
  final IntradeskFolder? parent;

  /// The capabilities the rule looked at: those of [parent], or at the root
  /// the platform's (`IntradeskService.getRootCapabilities`).
  final IntradeskFolderCapabilities capabilities;

  const SmartschoolIntradeskAddRefusedError(
    super.message, {
    required this.reason,
    required this.parentFolderId,
    required this.capabilities,
    this.parent,
  }) : super(statusCode: null);

  @override
  String toString() => '$runtimeType(${reason.name}): $message';
}

/// Thrown by the writes of `IntradeskService` (#128) when the write went out
/// to Intradesk, but Intradesk's answer does not confirm it.
///
/// **The change may or may not have been made.** List the folder
/// (`IntradeskService.getFolderListing`) before trying again: a create that
/// is sent again when the first one went through adds a second item, since
/// Intradesk does not refuse a name that is taken but renames the new item
/// (`name (1)`, seen live on 2026-10-05). `uploadFiles` is the same: sending
/// its last step again adds the files again (`name (1).ext`). Moving an item
/// to the trash again is harmless: Intradesk answers the trash of an item
/// that is in the trash already with `204`, as the first time (seen live).
///
/// Thrown when Intradesk answers the write with a status from `500` up
/// (other than for a parent folder it does not know, which is a
/// [SmartschoolIntradeskFolderNotFoundError]), or with another status the
/// write does not expect ([statusCode]); when it answers a create with
/// something that is not the item made (a body that is not JSON, or JSON in
/// another shape); and when the write failed after it went out, before an
/// answer came in ([cause] holds the failure, typically a
/// [SmartschoolConnectionError]).
///
/// The bare `500` (`{"status":500,"title":"Internal Server Error",
/// "detail":"","type":""}`) is what Intradesk answered, live, for a name
/// with a `/`, an empty name, a colour it does not know, a missing colour or
/// icon, and a made-up parent folder; nothing was made for any of them.
/// `IntradeskService` refuses those before it sends anything (an
/// [ArgumentError]) or tells the made-up parent apart, so a `500` that
/// reaches this error has a cause the service does not know, and it does
/// not assume that nothing was made.
///
/// A session that Smartschool refuses for the write is not this error but a
/// [SmartschoolSessionExpiredError] (or another
/// [SmartschoolAuthenticationError]): Smartschool refused it before handling
/// it, so nothing was made.
///
/// Deliberately not a [SmartschoolIntradeskWriteRefusedError], so a `catch`
/// meant for the failures where nothing was made does not catch it.
class SmartschoolIntradeskSaveUnconfirmedError extends SmartschoolException {
  /// The HTTP status of Intradesk's answer to the write, or `null` when no
  /// answer came in (see [cause]).
  final int? statusCode;

  /// The failure of the write when no usable answer came in, typically a
  /// [SmartschoolConnectionError]; `null` when Intradesk answered.
  final Object? cause;

  const SmartschoolIntradeskSaveUnconfirmedError(
    super.message, {
    this.statusCode,
    this.cause,
  });

  @override
  String toString() => statusCode == null
      ? '$runtimeType: $message'
      : '$runtimeType($statusCode): $message';
}

/// Thrown when Smartschool's upload step fails: the step every module that
/// takes files goes through first, which uploads the files one by one into
/// an upload directory (`POST /Upload/Upload/Index`) before the module is
/// told to take them (#128).
///
/// From `MessagesService.sendMessage` and `sendReply`, for an attachment:
/// the message was not submitted, so nothing was sent. From
/// `IntradeskService.uploadFiles` (#128): Smartschool gave no upload
/// directory, or did not take a file into it; Intradesk was not told to take
/// the files, so nothing was added to it. From the creates of
/// `LessonContentService` and its `addAttachments` (#129), for an
/// attachment of a lesfiche: the lesfiche was not made, or the module was
/// not told to take the files, so nothing was changed.
///
/// Seen live (2026-10-05): a file name with one of `/ : * ? " \ < > |`, or
/// one that starts with a dot, gets HTTP `400` with the rule in Smartschool's
/// words as plain text, which [serverMessage] holds. (`IntradeskService` and
/// `LessonContentService` refuse such a name before they send anything, with
/// an [ArgumentError].)
class SmartschoolAttachmentUploadError extends SmartschoolException {
  /// The name the file was uploaded under, or `null` when the error is not
  /// about one file (such as an upload directory Smartschool did not give,
  /// or a file that was not found).
  final String? fileName;

  /// The HTTP status of Smartschool's answer, or `null` when the error is
  /// not about an answer (a file that was not found).
  final int? statusCode;

  /// Smartschool's own words when it refused the file, such as the `400`
  /// for a name with a character it does not allow; `null` when it did not
  /// give any.
  final String? serverMessage;

  const SmartschoolAttachmentUploadError(
    super.message, {
    this.fileName,
    this.statusCode,
    this.serverMessage,
  });
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
/// array, exposed via [saveErrors], typed, and [errors], as text), an answer
/// that cannot be read (empty, an HTML page instead of JSON, such as
/// Smartschool's generic `500` error page, or not valid JSON), and
/// precondition failures such as an unknown class, an unresolvable status
/// code, or a pupil not present in the class. The session was accepted for
/// all of them, so signing in again does not help.
///
/// An answer that cannot be read is reported with the subtype
/// [SmartschoolPresenceUnreadableAnswerError] (#137), with the HTTP status
/// of the answer and what made it unreadable: unlike a refused save or a
/// failed precondition, it can be gone a moment later (a proxy's `502`, an
/// answer cut off), so a caller that retries can tell it apart.
///
/// A half-day that `setLate` or `setPresent` refuses to change because it
/// holds a status their `onlyReplacing` does not allow is reported with the
/// subtype [SmartschoolPresenceChangeRefusedError] (#105), a pupil the
/// class does not list on that day with the subtype
/// [SmartschoolPresencePupilNotFoundError] (#116), and a class whose
/// half-days the account may not set (`PresenceClassRef.userCanConfirm` is
/// `false`) with the subtype [SmartschoolPresenceNoConfirmRightError]
/// (#121): nothing was sent for any of them.
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

/// Thrown by `PresenceService.setLate` and `setPresent` when the class, as
/// the call read it right before the save (`Presence/Class/getClass`), does
/// not list the pupil on that day (#116). Nothing was sent.
///
/// A fact about the pupil on that day, not a refusal of the module: the
/// pupil is not (or no longer) in the class on that day, such as a pupil
/// whose movement into the class ended, or a `userId` the class does not
/// list at all. When the module listed no pupils for the class on that day
/// (a day after today, a class without pupils), [errorMessage] has its
/// reason and [saveIsAllowed] what it answered with it (#104).
///
/// A [SmartschoolPresenceError], so `catch` clauses for that type keep
/// catching it; its [errors] is empty.
class SmartschoolPresencePupilNotFoundError extends SmartschoolPresenceError {
  /// The pupil's internal `userID`, as passed.
  final int userId;

  /// The class's `groupID`, as passed.
  final int classGroupId;

  /// The day the call would have changed (`yyyy-MM-dd`).
  final String date;

  /// When the module listed no pupils for the class on that day: its
  /// `saveIsAllowed` (`false` in every such answer seen live), or `null`
  /// when its answer did not say. `null` when it listed other pupils.
  final bool? saveIsAllowed;

  /// When the module listed no pupils for the class on that day: its reason,
  /// as it shows it to the user (such as "Het is niet mogelijk om in de
  /// toekomst afwezigheden op te nemen."), or `null` when it gave none.
  /// `null` when it listed other pupils.
  final String? errorMessage;

  const SmartschoolPresencePupilNotFoundError(
    super.message, {
    required this.userId,
    required this.classGroupId,
    required this.date,
    this.saveIsAllowed,
    this.errorMessage,
  });
}

/// Thrown by `PresenceService.setLate` and `setPresent` when the account may
/// not set the half-days of the class: `getConfig` lists the class with
/// `userCanConfirm` `false` (#121). Nothing was sent: the call read only the
/// config.
///
/// `userCanConfirm` ("bevestigen") is the right the Presence module asks
/// for a half-day; `userCanRecord` ("registreren") is not. Seen live
/// (2026-10-04, one teacher account): with its absence-administrator rights
/// switched off, `getConfig` gave `userCanRecord` `true` and
/// `userCanConfirm` `false` for every class it listed, and the module
/// refused a half-day save ("U heeft geen rechten om afwezigheden te
/// bevestigen voor deze leerling. Contacteer uw beheerder."); with them on,
/// `userCanConfirm` was `true` for every class. The call reads the config
/// again before it refuses when it had one from before the call, so rights
/// granted during the session count.
///
/// A [SmartschoolPresenceError], so `catch` clauses for that type keep
/// catching it; its [errors] is empty.
class SmartschoolPresenceNoConfirmRightError extends SmartschoolPresenceError {
  /// The pupil's internal `userID`, as passed.
  final int userId;

  /// The class's `groupID`, as passed.
  final int classGroupId;

  /// The day the call would have changed (`yyyy-MM-dd`).
  final String date;

  /// The half of the day the call would have changed.
  final DayPart part;

  /// The class as `getConfig` lists it, with its [PresenceClassRef.name]
  /// and both rights: [PresenceClassRef.userCanConfirm] `false`.
  final PresenceClassRef classRef;

  const SmartschoolPresenceNoConfirmRightError(
    super.message, {
    required this.userId,
    required this.classGroupId,
    required this.date,
    required this.part,
    required this.classRef,
  });
}

/// Thrown by `PresenceService` when an answer of the Presence module cannot
/// be read (#137): it is empty, an HTML page instead of JSON, or not valid
/// JSON. [kind] says which, [statusCode] gives the HTTP status of the
/// answer and [path] the endpoint that gave it.
///
/// Not a session problem: the client logs in again, and retries once, on
/// the answers with which Smartschool refuses a session (a `401`, or a
/// redirect to its login chain), and reports a retry refused again as a
/// [SmartschoolSessionExpiredError]. Every other status, `429` and the
/// `5xx` ones included, comes this far as an answer. So this is what a
/// caller sees of a hiccup between it and the module, such as a proxy's
/// `502`, `503` or `504`, or an answer cut off, which can be gone a moment
/// later: unlike a save the module refused (its `errors[]`, in [saveErrors]
/// of a plain [SmartschoolPresenceError]) and the checks before a save (an
/// unknown class, code or pupil, and the other subtypes of
/// [SmartschoolPresenceError]), which give the same answer the next time.
/// Smartschool's generic error page (HTTP `500`, "Oeps, er ging iets mis")
/// is also how the module answers a request it cannot handle, such as an
/// invalid one (seen live, #5), so a retry can get the same page again:
/// retry a limited number of times.
///
/// What a caller may assume depends on the request, its [path]:
///
/// - a read (`/Presence/Main/getConfig`, `/Presence/Code/getAllCodes` or
///   `/Presence/Class/getClass`: `getConfig`, `getAllCodes`,
///   `getClassPupils`, and the reads with which `setLate` and `setPresent`
///   start): nothing changed on Smartschool.
/// - the save (`/Presence/Class/savePupilsPresences`, the last request of
///   `setLate` and `setPresent`): it is **not known** whether the save
///   landed. Calling `setLate` or `setPresent` again is safe: the call reads
///   the class again first and so sends the half-day's record (its
///   `presenceID`) when the first save stored one, which the module updates
///   rather than adding a second record for the half-day. With
///   `onlyReplacing`, that read may find the status the first save stored
///   (such as "Te laat" for `setLate`): let `onlyReplacing` allow it
///   (`PresenceService.lateCodeName`, or `lateWithoutReasonAliasName` with
///   `withoutValidReason`; `presentCodeName` for `setPresent`), or the call
///   is refused with a [SmartschoolPresenceChangeRefusedError] that names
///   it.
///
/// For an HTML page, it keeps the page's [title] and [heading], read and
/// masked as [SmartschoolUnexpectedPageError] reads them (#110): Smartschool's
/// error pages say what went wrong in their heading. Both are in the
/// [message] too; nothing else of the answer is, nor of an answer that is
/// not valid JSON, which can name pupils: its [message] has the JSON
/// parser's reason and where the JSON breaks off.
///
/// A [SmartschoolPresenceError], so `catch` clauses for that type keep
/// catching it; its [errors] and [saveErrors] are empty. Of these answers,
/// only the HTML `500` of a request the module cannot handle was seen live
/// (#5); the others are tested offline. (The empty `401` of an expired
/// session, seen live on a release before #8 as "Empty response", is a
/// session refusal now: the client logs in again for it.)
class SmartschoolPresenceUnreadableAnswerError
    extends SmartschoolPresenceError {
  /// The Presence endpoint that gave the answer: `/Presence/Main/getConfig`,
  /// `/Presence/Code/getAllCodes`, `/Presence/Class/getClass`, or
  /// `/Presence/Class/savePupilsPresences` for the save (whether it landed
  /// is not known, see above).
  final String path;

  /// The HTTP status of the answer, such as `502`, or `null` when it is not
  /// known.
  final int? statusCode;

  /// What made the answer unreadable: empty, an HTML page, or not valid
  /// JSON.
  final PresenceUnreadableAnswerKind kind;

  /// For an HTML page ([PresenceUnreadableAnswerKind.html]): its `<title>`,
  /// or `null` when it has none, as [SmartschoolUnexpectedPageError.title]
  /// reads it: without scripts, styles and forms, e-mail addresses and
  /// token-like strings masked, cut off after
  /// [SmartschoolUnexpectedPageError.maxLabelLength] characters. `null` for
  /// the other kinds.
  final String? title;

  /// For an HTML page ([PresenceUnreadableAnswerKind.html]): its first
  /// `<h1>`, or else its first `<h2>`, or `null` when it has neither, read
  /// as [title] is. On Smartschool's own error pages it says what went wrong
  /// (such as "Oeps, er ging iets mis"). `null` for the other kinds.
  final String? heading;

  const SmartschoolPresenceUnreadableAnswerError(
    super.message, {
    required this.path,
    required this.kind,
    this.statusCode,
    this.title,
    this.heading,
  });

  /// The error for [page], the HTML that Smartschool answered the Presence
  /// endpoint [path] with, with the [statusCode] of that answer.
  ///
  /// Reads the [title] and [heading] of [page] and builds a [message] that
  /// names them, with [path] and [statusCode].
  factory SmartschoolPresenceUnreadableAnswerError.fromPage(
    String page, {
    required String path,
    int? statusCode,
  }) {
    final document = html_parser.parse(page);
    final title = SmartschoolUnexpectedPageError._label(
      document.querySelector('title'),
      SmartschoolUnexpectedPageError.maxLabelLength,
    );
    final heading = SmartschoolUnexpectedPageError._label(
      document.querySelector('h1') ?? document.querySelector('h2'),
      SmartschoolUnexpectedPageError.maxLabelLength,
    );
    final details = [
      statusCode == null ? 'status unknown' : 'HTTP $statusCode',
      if (title != null) 'title "$title"',
      if (heading != null) 'heading "$heading"',
    ].join(', ');
    return SmartschoolPresenceUnreadableAnswerError(
      'Smartschool answered $path with an HTML page instead of JSON '
      '($details).',
      path: path,
      kind: PresenceUnreadableAnswerKind.html,
      statusCode: statusCode,
      title: title,
      heading: heading,
    );
  }
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
/// [capabilityFlags] it missed or found, for a lesfiche that is not a
/// lesson one the [lessonContent], and for an assignment type the school
/// does not have the school's [assignmentTypes] as the check read them
/// (#119). The [message] says the same for a log,
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

  /// For [PlannerWriteRefusalReason.unknownAssignmentType], the school's
  /// assignment types as `planAssignment` read them again for the check
  /// (`getAssignmentTypes`), in the planner's order: the types the refused
  /// one is not among (#119). An app can list them to its user, and keep its
  /// own copy up to date, without reading them a second time (a read that
  /// could differ from the one the check refused on). Empty when the school
  /// has none, and for the other reasons. The type that was refused is the
  /// caller's own `type`.
  final List<PlannerAssignmentType> assignmentTypes;

  const SmartschoolPlannerWriteRefusedError(
    super.message, {
    this.reason,
    this.element,
    this.capabilityFlags = const [],
    this.lessonContent,
    this.assignmentTypes = const [],
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
/// When `LessonContentService.getItems` read the lesfiches but the course
/// list it reads after them to name their courses fails so, it throws the
/// subtype [SmartschoolLessonContentCourseListError], which carries the
/// lesfiches as read (#118). From `getItems`, an error of this type that is
/// not of that subtype is about the lesfiches: none were read.
///
/// `PlannerService.planLessonContent` reads the lesfiches before it plans
/// one; this error from it means that **nothing was sent** to the planner.
///
/// From the writes of `LessonContentService` (#129: the creates, the edits,
/// the weblinks and attachments, the move to the trash), this type and its
/// subtypes always mean that **nothing was changed**: a read before the
/// write failed (the school's courses, the assignment types, or the
/// lesfiche itself for `addAttachments`), or Smartschool refused the write
/// ([SmartschoolLessonContentWriteRefusedError]), or knows no such lesfiche,
/// weblink or attachment ([SmartschoolLessonContentNotFoundError]). A write
/// that went out without Smartschool confirming it is a
/// [SmartschoolLessonContentSaveUnconfirmedError] instead.
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

/// Thrown by `LessonContentService.getItems` when it read the lesfiches, but
/// the school's course list, which it reads after them to name their courses
/// (#101), answered with something the service cannot use (#118): another
/// HTTP status than `200` (in [statusCode]), an HTML page, an answer that is
/// not valid JSON, or a list in a shape it does not recognise (such as a
/// course without its `id` or `platformId`). Its [message] and [statusCode]
/// are those of the course list's answer.
///
/// The lesfiches are not lost: [items] holds them as read, the same as
/// `getItems(withCourseNames: false)` gives them (every course with a `null`
/// `LessonContentCourse.name`). A caller that can do without the names lists
/// those:
///
/// ```dart
/// List<LessonContentItem> fiches;
/// try {
///   fiches = await lessonContent.getItems();
/// } on SmartschoolLessonContentCourseListError catch (e) {
///   fiches = e.items; // the courses without their names; e says why
/// }
/// ```
///
/// A [SmartschoolLessonContentError], so `catch` clauses for that type keep
/// catching it. From `getItems`, a [SmartschoolLessonContentError] that is
/// not of this type is about the lesfiches themselves: none were read. A
/// session that Smartschool does not accept for the course list (also after
/// the client logged in again), or a connection that fails for it, is thrown
/// as for the lesfiches ([SmartschoolSessionExpiredError],
/// [SmartschoolConnectionError]), without the lesfiches: calling `getItems`
/// again reads both. `LessonContentService.getCourses`, which reads the
/// course list alone, throws a plain [SmartschoolLessonContentError].
///
/// `LessonContentService.getDetail` and `getDetailById` (#129) throw it the
/// same way, when they read the detail of a lesfiche but not the course list
/// that names its courses: [items] then holds that one lesfiche, a
/// `LessonContentDetail` with its courses unnamed.
class SmartschoolLessonContentCourseListError
    extends SmartschoolLessonContentError {
  /// The lesfiches `getItems` read, in the module's order, with their
  /// courses unnamed (`LessonContentCourse.name` `null`); from `getDetail`,
  /// the one `LessonContentDetail` it read.
  final List<LessonContentItem> items;

  const SmartschoolLessonContentCourseListError(
    super.message, {
    super.statusCode,
    required this.items,
  });
}

/// Thrown by `LessonContentService` when the Lesfiches module answers `404`
/// (#129): it has no lesfiche of that kind with that ID, or, for a write on
/// a weblink or an attachment, the lesfiche has no such weblink or
/// attachment.
///
/// Seen live (2026-10-05): the detail of a made-up ID, and of a lesson's ID
/// asked for as an assignment (`assignments/{id}`), answer `404`, and so
/// does a rename of a lesfiche that is in the trash (whose detail the module
/// still answers with `200`). From a write, **nothing was changed**.
///
/// A [SmartschoolLessonContentError] with [statusCode] `404`.
class SmartschoolLessonContentNotFoundError
    extends SmartschoolLessonContentError {
  /// The kind of lesfiche that was asked for.
  final LessonContentType type;

  /// The lesfiche ID that was asked for.
  final String id;

  const SmartschoolLessonContentNotFoundError(
    super.message, {
    required this.type,
    required this.id,
  }) : super(statusCode: 404);
}

/// Thrown by the writes of `LessonContentService` (#129) when the Lesfiches
/// module refused the write: it answered with an HTTP status from `400` to
/// `499` (other than `404`, a [SmartschoolLessonContentNotFoundError]).
/// **Nothing was changed.**
///
/// The module rarely says why. Seen live (2026-10-05), each with a bare
/// `{"status":400,"title":"Bad Request","detail":"","type":""}`: a create
/// with only a name (without the lists the web client sends), a rename to
/// `""`, and a weblink whose address is not a URL or lacks `http(s)://`.
/// `LessonContentService` refuses the last two before it sends anything (an
/// [ArgumentError]), so a `400` that reaches this error has another cause.
/// When the module gives its reasons (`violations`, as Intradesk does), they
/// are in [violations].
///
/// The session was accepted: signing in again does not help. A session that
/// Smartschool does not accept for the write is a
/// [SmartschoolSessionExpiredError] instead (nothing was changed either: a
/// create is never sent again after logging in again).
class SmartschoolLessonContentWriteRefusedError
    extends SmartschoolLessonContentError {
  /// The module's reasons, in its own words, in its order; empty when it
  /// gave none (a bare `400`).
  final List<String> violations;

  const SmartschoolLessonContentWriteRefusedError(
    super.message, {
    required int super.statusCode,
    this.violations = const [],
  });
}

/// Thrown by the writes of `LessonContentService` (#129) when the write went
/// out to the Lesfiches module, but its answer does not confirm it.
///
/// **The change may or may not have been made.** Read the lesfiche
/// (`LessonContentService.getDetail`, or `getItems` for a create or a move
/// to the trash) before trying again. The edits set a value, so sending one
/// again is harmless; but a create that is sent again when the first went
/// through makes a second lesfiche (the module keeps a name that is taken,
/// seen live), `addWeblink` a second weblink and `addAttachments` the files
/// a second time (the module keeps two attachments of the same name, seen
/// live). A lesfiche that is in the trash already is answered with a bare
/// `500` when it is moved to the trash again (seen live).
///
/// Thrown when the module answers the write with a status from `500` up, or
/// another status the write does not expect ([statusCode]); with something
/// that is not what the write made (not JSON, another lesfiche, a value
/// other than the one sent, a weblink or an attachment missing from the
/// lesfiche); when a move to the trash answers with `exceptions`; and when
/// the write failed after it went out, before a usable answer came in
/// ([cause] holds the failure, typically a [SmartschoolConnectionError]).
///
/// A create that the module answered with the new lesfiche's ID, but whose
/// detail could not be read back, or does not hold everything sent, carries
/// that ID in [lessonContentId]: **the lesfiche was made** then; read it
/// with `LessonContentService.getDetailById`, or move it to the trash.
///
/// A session that Smartschool refuses for the write is not this error but a
/// [SmartschoolSessionExpiredError] (or another
/// [SmartschoolAuthenticationError]): Smartschool refused it before handling
/// it, so nothing was changed.
///
/// `addAttachments` throws the subtype
/// [SmartschoolLessonContentVisibilityNotSetError] when the module took the
/// files and only setting the visibility of one of them failed (#135): the
/// files were added then, and the error carries their attachments. From
/// `addAttachments`, this error itself (not of that subtype) means that the
/// take is unconfirmed: the files may or may not have been added.
///
/// Deliberately not a [SmartschoolLessonContentError], so a `catch` meant
/// for the failures where nothing was changed does not catch it.
class SmartschoolLessonContentSaveUnconfirmedError
    extends SmartschoolException {
  /// The HTTP status of the module's answer to the write, or `null` when no
  /// answer came in (see [cause]), or the write was confirmed and a later
  /// step failed.
  final int? statusCode;

  /// The failure when no usable answer came in, such as a
  /// [SmartschoolConnectionError], or of the step after the write (the read
  /// of a new lesfiche's detail, or, in a
  /// [SmartschoolLessonContentVisibilityNotSetError], the visibility of an
  /// added attachment); `null` when the module answered with something that
  /// does not confirm the write.
  final Object? cause;

  /// The ID of the lesfiche the write was for: the lesfiche that was edited,
  /// or, for a create, the ID the module answered with (the lesfiche was
  /// made); `null` for a create that no ID came back for, and for a move to
  /// the trash.
  final String? lessonContentId;

  const SmartschoolLessonContentSaveUnconfirmedError(
    super.message, {
    this.statusCode,
    this.cause,
    this.lessonContentId,
  });

  @override
  String toString() => statusCode == null
      ? '$runtimeType: $message'
      : '$runtimeType($statusCode): $message';
}

/// The [SmartschoolLessonContentSaveUnconfirmedError] of
/// `LessonContentService.addAttachments` when **the files were added**, and
/// only setting the visibility of one of them failed (#135).
///
/// `addAttachments` has the module take the uploaded files (`POST
/// {type}/{id}/attachments`), which gives every new attachment the
/// visibility [LessonContentVisibility.always] (seen live), and then sets the
/// visibility asked for of each attachment that asks for another one, one at
/// a time, with `changeAttachmentVisibility`. This error means that the take
/// went through, with exactly the files uploaded (their attachments are in
/// [addedAttachments]), and that the change of the visibility of
/// [attachment] to [visibility] failed. The call stopped there: the
/// attachments after it whose visibility it would have changed still have
/// the module's `always` too. [visibilitiesNotSet] holds all of them.
///
/// [cause] is the failure of that change: a [SmartschoolLessonContentError]
/// (the module refused it, such as a
/// [SmartschoolLessonContentWriteRefusedError]: the visibility was not set),
/// a [SmartschoolLessonContentSaveUnconfirmedError] (sent, but not confirmed:
/// it may or may not have been set), or a [SmartschoolAuthenticationError]
/// (the session was refused, also after logging in again: not set).
///
/// **Do not add the files again**: that adds them a second time (the module
/// keeps two attachments of the same name, seen live). Set the visibilities
/// instead; a visibility change sets a value, so sending one that went
/// through again is harmless:
///
/// ```dart
/// try {
///   await lessonContent.addAttachments(fiche, files);
/// } on SmartschoolLessonContentVisibilityNotSetError catch (e) {
///   // The files are on the lesfiche: e.addedAttachments.
///   for (final MapEntry(key: id, value: visibility)
///       in e.visibilitiesNotSet.entries) {
///     await lessonContent.changeAttachmentVisibility(fiche, id, visibility);
///   }
/// }
/// ```
///
/// Its [statusCode] is `null` and its [lessonContentId] the ID of the
/// lesfiche. From `addAttachments`, a
/// [SmartschoolLessonContentSaveUnconfirmedError] that is not of this type
/// means that the take itself is unconfirmed: the files may or may not have
/// been added, and the error carries no attachments.
class SmartschoolLessonContentVisibilityNotSetError
    extends SmartschoolLessonContentSaveUnconfirmedError {
  /// The attachments the module made of the files, one per file, in the
  /// order of the call's `attachments`, each with the visibility it has as
  /// far as the call knows: for those before [attachment], the one asked for
  /// (as the module answered its change); for [attachment] and those after
  /// it, the one the module gave them ([LessonContentVisibility.always], seen
  /// live).
  final List<LessonContentAttachment> addedAttachments;

  /// The attachment whose visibility could not be set, as the module answered
  /// the take: one of [addedAttachments].
  final LessonContentAttachment attachment;

  /// The visibility asked for [attachment].
  final LessonContentVisibility visibility;

  /// The visibilities asked for that the call did not set, by attachment ID
  /// ([LessonContentAttachment.id]), in the order of the call's
  /// `attachments`: [visibility] for [attachment] first, then, for each
  /// attachment after it that asks for another visibility than the module
  /// gave it, the one asked for (the call did not try those). Each can be set
  /// with `LessonContentService.changeAttachmentVisibility`.
  final Map<String, LessonContentVisibility> visibilitiesNotSet;

  const SmartschoolLessonContentVisibilityNotSetError(
    super.message, {
    required Object super.cause,
    required String super.lessonContentId,
    required this.addedAttachments,
    required this.attachment,
    required this.visibility,
    required this.visibilitiesNotSet,
  });
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
/// The service throws one of its two subtypes, which carry what the call
/// read before the save (#120), as its result would have:
/// - [SmartschoolSkoreAssignmentSaveUnconfirmedError] from `addTeacher` and
///   `replaceTeacher`: the course, the assignment it was replacing, and the
///   teacher it was saving;
/// - [SmartschoolSkoreShareSaveUnconfirmedError] from `shareGradebook` and
///   `unshareGradebook`: the gradebook as read before the change, and the
///   teacher whose access it was changing.
///
/// So a `catch` of this type keeps catching both. Its message names the
/// change by IDs only (no labels or names); the subtypes carry those.
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

/// The [SmartschoolSkoreSaveUnconfirmedError] of `SkoreService.addTeacher`
/// and `replaceTeacher`: the save went out, but Skore's answer does not
/// confirm it. **It may or may not have been saved**: read the class again
/// (`SkoreService.getCourses`) before trying again.
///
/// It carries what the call read before the save (#120), as the
/// `SkoreSavedAssignment` it returns when the save is confirmed does (#102),
/// so that telling the user what may have been saved, and what to look for
/// to check it, needs no read of its own. A read after a save that may have
/// gone through cannot tell what was there before.
class SmartschoolSkoreAssignmentSaveUnconfirmedError
    extends SmartschoolSkoreSaveUnconfirmedError {
  /// The course of the assignment, as the call read it right before the save
  /// (the class's assignments page, as `SkoreService.getCourses` reads it):
  /// its [SkoreCourse.label], [SkoreCourse.code], [SkoreCourse.id],
  /// [SkoreCourse.classId], and its assignments **before** the save.
  final SkoreCourse course;

  /// For `replaceTeacher`, the assignment as it was before the save: its
  /// [SkoreAssignment.id], with the teacher it had. If the save went through,
  /// the assignment keeps that ID with [teacher] instead. `null` for
  /// `addTeacher`, which replaces nothing.
  final SkoreAssignment? replaced;

  /// The teacher the call was saving on the course, as `SkoreService` read
  /// them from `getTeachers` before the save: their user ID and name.
  final SkoreTeacher teacher;

  const SmartschoolSkoreAssignmentSaveUnconfirmedError(
    super.message, {
    super.cause,
    required this.course,
    this.replaced,
    required this.teacher,
  });
}

/// The [SmartschoolSkoreSaveUnconfirmedError] of
/// `SkoreService.shareGradebook` and `unshareGradebook`: the save went out,
/// but Skore's answer, or reading the owner's gradebooks again afterwards,
/// does not confirm it. **It may or may not have been saved**: read the
/// gradebooks again (`SkoreService.getGradebookShares`) before trying again.
///
/// It carries what the call read before the save (#120), as the
/// `SkoreGradebookShareChange` it returns when the save is confirmed does
/// (#103): the gradebook as read before the change ([before]: its class and
/// course names, and its readers and writers then) and the teacher whose
/// access it was changing ([teacherId]), so the access they had before
/// ([accessBefore]). A read after a save that may have gone through cannot
/// tell what was there before.
class SmartschoolSkoreShareSaveUnconfirmedError
    extends SmartschoolSkoreSaveUnconfirmedError {
  /// The gradebook as the call read it right before the save (the owner's
  /// gradebooks, as `SkoreService.getGradebookShares` reads them), with the
  /// readers and writers it had then.
  final SkoreGradebookShares before;

  /// The Smartschool user ID of the teacher whose access the call was
  /// changing (its `teacherId`).
  final int teacherId;

  const SmartschoolSkoreShareSaveUnconfirmedError(
    super.message, {
    super.cause,
    required this.before,
    required this.teacherId,
  });

  /// The access [teacherId] had before the save, or `null` when the
  /// gradebook was not shared with them: [before]'s
  /// `SkoreGradebookShares.accessOf`.
  SkoreShareAccess? get accessBefore => before.accessOf(teacherId);
}
