import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'exceptions.dart';

/// A file that Smartschool is sending, handed over as soon as the headers of
/// its answer are in, before its content is read (#41): what the headers say
/// about the file, and the content as a [stream] that is read as it comes
/// in.
///
/// Returned by `SmartschoolClient.downloadStream`, and so by
/// `IntradeskService.downloadFileStream` and
/// `MessageAttachment.downloadStream`. The client has checked the answer by
/// then: Smartschool accepted the session (a login page is never handed over
/// as the file), answered with HTTP `200`, and did not announce a size above
/// the `maxBytes` asked for.
///
/// Read [stream] once, or call [cancel] to leave the rest unread. Until
/// [stream] is listened to, the HTTP client keeps what comes in in memory,
/// so listen to it right away.
///
/// ```dart
/// final download = await IntradeskService(client).downloadFileStream(
///   file.id,
///   maxBytes: 25 * 1024 * 1024,
/// );
/// print('${download.fileName}: ${download.contentLength} bytes');
/// await download.stream.pipe(File('out.bin').openWrite());
/// ```
class SmartschoolDownload {
  /// A download of [stream], with the [headers] of the answer it comes in.
  ///
  /// [onCancel] stops the transfer; [cancel] calls it. The client passes its
  /// own; a fake for a test can pass none.
  SmartschoolDownload({
    required this.stream,
    required this.headers,
    FutureOr<void> Function()? onCancel,
  }) : _onCancel = onCancel;

  /// The content of the file, in chunks as they come in. It can be listened
  /// to once. A byte stream as `dart:io` has them, so it can be piped into a
  /// file: `stream.pipe(file.openWrite())`, which also closes the file when
  /// the stream fails, and then completes with the stream's error.
  ///
  /// Pausing the subscription pauses the transfer. Cancelling it stops the
  /// transfer and closes the connection, and so does an error: the stream
  /// ends at the first one.
  ///
  /// The errors, from the client's downloads:
  /// - a [SmartschoolDownloadTooLargeError] once more than `maxBytes` bytes
  ///   came in (only when Smartschool did not announce a larger size: the
  ///   download then fails before it is handed over). Everything before it
  ///   is at most `maxBytes` bytes;
  /// - a [SmartschoolConnectionError] when the connection fails halfway;
  /// - a [SmartschoolClientDisposedError] when the client was disposed while
  ///   it was read (#54, #73);
  /// - a [StateError] after [cancel].
  final Stream<List<int>> stream;

  /// The headers of Smartschool's answer.
  final Headers headers;

  final FutureOr<void> Function()? _onCancel;

  /// The size of the file in bytes, as Smartschool announced it
  /// (`Content-Length`), or `null` when it announced none.
  ///
  /// Also `null` for content that comes in encoded (a `Content-Encoding`
  /// such as `gzip`): the HTTP client decodes it, and the header gives the
  /// size of the encoded content, not of the file.
  int? get contentLength {
    final coding = _header('content-encoding')?.trim().toLowerCase();
    if (coding != null && coding.isNotEmpty && coding != 'identity') {
      return null;
    }
    final length = int.tryParse(
      _header(Headers.contentLengthHeader)?.trim() ?? '',
    );
    return length != null && length >= 0 ? length : null;
  }

  /// The media type of the answer (`Content-Type`) as Smartschool gave it,
  /// or `null` when it gave none.
  ///
  /// It does not always tell the type of the file: Smartschool's Intradesk
  /// answers `application/x-www-form-urlencoded` for every file (observed
  /// live on docx, xlsx, pptx, pdf, png, jpg, csv and html files, #41); the
  /// extension of [fileName] tells it there.
  String? get contentType => _header(Headers.contentTypeHeader);

  /// The name Smartschool gave the file (in `Content-Disposition`), or
  /// `null` when it gave none.
  ///
  /// Taken from the `filename*` parameter (UTF-8 or ISO-8859-1, RFC 6266)
  /// when there is one it can read, else from `filename`. It is the name as
  /// Smartschool sent it: check it before using it as a path, as it could
  /// hold a folder or characters that the file system does not allow.
  String? get fileName =>
      contentDispositionFileName(_header('content-disposition'));

  /// Stops the transfer, leaving the rest of the content unread, and closes
  /// the connection. [stream] then ends with a [StateError], also when it is
  /// being read.
  ///
  /// A reader that no longer wants the content can cancel its subscription
  /// instead, which stops the transfer as well.
  Future<void> cancel() async => _onCancel?.call();

  String? _header(String name) {
    final values = headers[name];
    return values == null || values.isEmpty ? null : values.first;
  }
}

/// The file name in [contentDisposition], the value of a
/// `Content-Disposition` header, or `null` when it holds none: the
/// `filename*` parameter (RFC 6266, in UTF-8 or ISO-8859-1) when it can be
/// read, else the `filename` parameter (#41).
String? contentDispositionFileName(String? contentDisposition) {
  if (contentDisposition == null) return null;
  String? plain;
  String? extended;
  for (final match in _dispositionParameter.allMatches(contentDisposition)) {
    final name = match.group(1)!.toLowerCase();
    final value = _unquote(match.group(2)!.trim());
    if (name == 'filename*') {
      extended ??= _decodeExtendedValue(value);
    } else if (name == 'filename') {
      plain ??= value;
    }
  }
  final fileName = extended ?? plain;
  return fileName == null || fileName.isEmpty ? null : fileName;
}

/// A `name=value` parameter of a header such as `Content-Disposition`: the
/// value is a quoted string (which may hold a `;`) or runs to the next `;`.
final _dispositionParameter = RegExp(
  r'(?:^|;)\s*([^\s=;]+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]*)',
);

/// [value] without its quotes and backslash escapes, when it is a quoted
/// string; otherwise [value] itself.
String _unquote(String value) {
  if (value.length < 2 || !value.startsWith('"') || !value.endsWith('"')) {
    return value;
  }
  return value
      .substring(1, value.length - 1)
      .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
}

/// Decodes an RFC 8187 extended value (`charset'language'percent-encoded`),
/// or returns `null` when it is malformed or in another charset than UTF-8
/// or ISO-8859-1.
String? _decodeExtendedValue(String value) {
  final charsetEnd = value.indexOf("'");
  if (charsetEnd < 0) return null;
  final languageEnd = value.indexOf("'", charsetEnd + 1);
  if (languageEnd < 0) return null;
  final Encoding encoding;
  switch (value.substring(0, charsetEnd).toLowerCase()) {
    case 'utf-8':
      encoding = utf8;
    case 'iso-8859-1':
      encoding = latin1;
    default:
      return null;
  }
  // A `+` is itself here, not a space as in a query.
  final encoded = value.substring(languageEnd + 1).replaceAll('+', '%2B');
  try {
    return Uri.decodeQueryComponent(encoded, encoding: encoding);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}
