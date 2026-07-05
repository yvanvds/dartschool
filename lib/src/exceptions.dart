/// Base exception for all Smartschool API errors.
class SmartschoolException implements Exception {
  final String message;

  const SmartschoolException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when authentication fails (wrong password, max retries, etc.).
class SmartschoolAuthenticationError extends SmartschoolException {
  const SmartschoolAuthenticationError(super.message);
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
/// This covers both a rejected save (the server returns a non-empty `errors[]`
/// array, exposed via [errors]) and precondition failures such as an unknown
/// class, an unresolvable status code, or a pupil not present in the class.
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
