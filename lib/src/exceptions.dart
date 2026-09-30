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
/// - [SmartschoolUnsupportedTwoFactorMethodError]: the account uses a 2FA
///   method other than an authenticator app (Google Authenticator).
/// - [SmartschoolAccountVerificationRequiredError]: Smartschool asks for
///   account verification (a date of birth), but the credentials hold no
///   usable answer.
/// - [SmartschoolAccountVerificationRejectedError]: the account verification
///   answer was rejected.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the session
///   for a request, also after logging in again.
///
/// This class itself is still thrown for the remaining authentication
/// failures, such as an unrecognised step in the login chain, or an HTML page
/// where data was expected. Catching [SmartschoolAuthenticationError] catches
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
/// again after an answer that Smartschool accepts; a new `SmartschoolClient`
/// starts counting afresh.
///
/// It is not a missing access right: when the session is accepted but the
/// account may not make the request, the service reports that in its own
/// error type (e.g. [SmartschoolPresenceError]).
class SmartschoolSessionExpiredError extends SmartschoolAuthenticationError {
  const SmartschoolSessionExpiredError([
    super.message = 'Smartschool did not accept the session.',
  ]);
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

/// Thrown when parsing server response data fails.
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

/// Thrown when JSON decoding of a response body fails.
class SmartschoolJsonError extends SmartschoolDownloadError {
  SmartschoolJsonError(super.message, super.statusCode);
}

/// Thrown when uploading a message attachment fails.
class SmartschoolAttachmentUploadError extends SmartschoolException {
  const SmartschoolAttachmentUploadError(super.message);
}

/// Thrown when the message compose flow fails (e.g. hidden fields missing,
/// recipient add rejected, or the final send returns an unexpected response).
class SmartschoolComposeError extends SmartschoolException {
  const SmartschoolComposeError(super.message);
}

/// Thrown when a Presence (attendance) operation fails.
///
/// This covers a rejected save (the server returns a non-empty `errors[]`
/// array, exposed via [errors]), a request the Presence module refuses or
/// cannot handle (it answers with an HTML page instead of JSON, such as its
/// generic `500` error page: the request is invalid, or the account may lack
/// Presence access), and precondition failures such as an unknown class, an
/// unresolvable status code, or a pupil not present in the class. The session
/// was accepted for all of them, so signing in again does not help.
///
/// A session that Smartschool does not accept is not reported with this type
/// but as a [SmartschoolSessionExpiredError] (a
/// [SmartschoolAuthenticationError]), like any other authentication failure.
class SmartschoolPresenceError extends SmartschoolException {
  /// The server-reported error strings, when the failure originated from a
  /// non-empty `errors[]` in the save response. Empty for precondition
  /// failures raised client-side.
  final List<String> errors;

  const SmartschoolPresenceError(super.message, {this.errors = const []});

  @override
  String toString() => errors.isEmpty
      ? '$runtimeType: $message'
      : '$runtimeType: $message (${errors.join('; ')})';
}
