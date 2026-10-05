import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../session.dart';

/// Smartschool's own upload step, which every module that takes files goes
/// through first (#128): the files are uploaded one by one into an **upload
/// directory**, and the module is then told to take the files of that
/// directory.
///
/// - `MessagesService.sendMessage` and `sendReply` upload a message's
///   attachments into the directory of their compose form (its hidden
///   `randomDir`), which belongs to the session the form was loaded in
///   (#25, #38): they pass `retryAfterLogin: false` and `sameSessionAs` to
///   [uploadFile].
/// - `IntradeskService.uploadFiles` asks for a new directory ([newDirectory])
///   for every call, uploads into it, and then sends Intradesk's
///   `files/upload` with it (#128). Such a directory is not bound to the
///   session: seen live on 2026-10-05, a second session of the same user,
///   from a fresh login, could upload into it and list it. So its steps are
///   retried after logging in again, like a read.
/// - The Lesfiches module takes such a directory, from [newDirectory], as
///   the `randomDir` of a lesfiche's attachments (seen live, #129).
///
/// Internal to the library: the services use it, it is not exported.
class SmartschoolUploader {
  SmartschoolUploader(SmartschoolClient client) : _client = client;

  final SmartschoolClient _client;

  /// The path that hands out a new upload directory.
  static const directoryPath = '/upload/api/v1/get-upload-directory';

  /// The path that takes one file into an upload directory.
  static const uploadPath = '/Upload/Upload/Index';

  /// Asks Smartschool for a new, empty upload directory, as the web client's
  /// dropzone does (`@smartschool/smsc-dropzone`), and returns its name.
  ///
  /// Calls `GET /upload/api/v1/get-upload-directory`, which answers
  /// `{"uploadDir": "<30 hex characters>"}` (seen live, 2026-10-05). A read:
  /// it is retried once after logging in again, as every request. Smartschool
  /// hands out a new directory for every request.
  ///
  /// **A directory is not used up** by the module that takes its files: seen
  /// live for Intradesk's `files/upload`, which added the files of a
  /// directory a second time when it was sent again with the same directory.
  /// Ask for a new directory for every set of files.
  ///
  /// Throws a [SmartschoolAttachmentUploadError] (nothing was uploaded) when
  /// the answer has another status than `200` or holds no directory name.
  Future<String> newDirectory() async {
    final response = await _client.getResponse(directoryPath);
    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    final dir = decoded is Map ? decoded['uploadDir'] : null;
    if (status != 200 || dir is! String || dir.trim().isEmpty) {
      throw SmartschoolAttachmentUploadError(
        'Smartschool gave no upload directory: $directoryPath answered with '
        'HTTP $status and ${_excerpt(body)}. Nothing was uploaded.',
        statusCode: status,
      );
    }
    return dir;
  }

  /// Uploads the file at [filePath] into the upload directory [uploadDir],
  /// under the last segment of its path as its name.
  ///
  /// Calls `POST /Upload/Upload/Index`, multipart, with the fields `file`
  /// (with the type [guessMimeType] gives its name) and `uploadDir`.
  /// Smartschool answers `true` when it took the file.
  ///
  /// [retryAfterLogin] and [sameSessionAs] are passed on to
  /// [SmartschoolClient.postMultipartResponse]: a directory that belongs to
  /// the session of a page (a message's compose form) is uploaded into only
  /// in that session (#25, #38).
  ///
  /// Throws a [SmartschoolAttachmentUploadError] when the file does not
  /// exist, and when Smartschool does not answer `true`; it carries the
  /// [SmartschoolAttachmentUploadError.fileName], the HTTP
  /// [SmartschoolAttachmentUploadError.statusCode], and, for a refusal in
  /// Smartschool's own words, its [SmartschoolAttachmentUploadError.serverMessage].
  /// Seen live (2026-10-05): a name with one of `/ : * ? " \ < > |`, or one
  /// that starts with a dot, gets HTTP `400` with a plain-text answer (not
  /// JSON): "De karakters: / : * ? " \ < > | zijn niet toegestaan in de naam
  /// van een map of bestand. Een punt voor of achter de naam van een map of
  /// bestand is ook niet toegestaan." ([isAllowedName] tells such a name
  /// beforehand.)
  Future<void> uploadFile(
    String uploadDir,
    String filePath, {
    bool retryAfterLogin = true,
    Response<dynamic>? sameSessionAs,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw SmartschoolAttachmentUploadError(
        'Attachment file not found: $filePath',
      );
    }

    final fileName = file.uri.pathSegments.last;
    final mimeType = guessMimeType(fileName);
    final bytes = await file.readAsBytes();

    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: fileName,
        contentType: DioMediaType.parse(mimeType),
      ),
      'uploadDir': uploadDir,
    });

    final response = await _client.postMultipartResponse(
      uploadPath,
      formData,
      retryAfterLogin: retryAfterLogin,
      sameSessionAs: sameSessionAs,
    );

    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    final result = body.trim().toLowerCase();
    if (result == 'true') return;
    if (result == 'false') {
      throw SmartschoolAttachmentUploadError(
        "Attachment upload failed for '$fileName': server returned false.",
        fileName: fileName,
        statusCode: status,
      );
    }
    final text = _plainText(body);
    if (status >= 400 && status < 500 && text != null) {
      throw SmartschoolAttachmentUploadError(
        "Smartschool refused the upload of '$fileName' (HTTP $status): $text",
        fileName: fileName,
        statusCode: status,
        serverMessage: text,
      );
    }
    throw SmartschoolAttachmentUploadError(
      "Attachment upload returned unexpected response for '$fileName' (HTTP "
      '$status): ${body.length > 100 ? body.substring(0, 100) : body}',
      fileName: fileName,
      statusCode: status,
    );
  }

  /// The characters that Smartschool does not allow in the name of a folder
  /// or a file, and a name that starts or ends with a dot: the web client's
  /// `nameCharsAreAllowed` (Intradesk's `src/helpers/helperFunctions`), which
  /// it checks before it creates or renames a folder, a weblink or a file.
  static final _forbiddenInName = RegExp(r'([/:*?"\\<>|]|\.$|^\.)');

  /// Whether Smartschool allows [name] as the name of a folder, a weblink or
  /// a file, as the web client checks it (`nameCharsAreAllowed`): not one of
  /// `/ : * ? " \ < > |`, and no dot at its start or end, nor at the end of
  /// the part before its last dot (so `notes..txt` is refused as well). An
  /// empty name passes this check; refuse it separately.
  ///
  /// The upload step refuses such a file name with HTTP `400` and the rule
  /// in Smartschool's words ([uploadFile]); Intradesk's creates of a folder
  /// or a weblink answer a `/` with a bare HTTP `500` (seen live,
  /// 2026-10-05).
  static bool isAllowedName(String name) {
    if (_forbiddenInName.hasMatch(name)) return false;
    final dot = name.lastIndexOf('.');
    return dot < 0 || !_forbiddenInName.hasMatch(name.substring(0, dot));
  }

  /// Returns a MIME type string for [fileName] based on file extension.
  ///
  /// Falls back to `application/octet-stream` for unknown types.
  static String guessMimeType(String fileName) {
    const table = {
      'pdf': 'application/pdf',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'svg': 'image/svg+xml',
      'webp': 'image/webp',
      'txt': 'text/plain',
      'html': 'text/html',
      'htm': 'text/html',
      'csv': 'text/csv',
      'xml': 'application/xml',
      'json': 'application/json',
      'zip': 'application/zip',
      'tar': 'application/x-tar',
      'gz': 'application/gzip',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
    };
    final ext = fileName.split('.').lastOrNull?.toLowerCase() ?? '';
    return table[ext] ?? 'application/octet-stream';
  }

  /// [body] trimmed, when it is a short plain text (Smartschool's own words,
  /// such as the `400` of the upload step for a name it does not allow), or
  /// `null` for an empty answer, an HTML page or a long one.
  static String? _plainText(String body) {
    final text = body.trim();
    if (text.isEmpty || text.length > 500 || text.startsWith('<')) {
      return null;
    }
    return text;
  }

  /// The start of [body], to name an answer in an error.
  static String _excerpt(String body) {
    final text = body.trim();
    if (text.isEmpty) return 'an empty body';
    return '"${text.length > 100 ? '${text.substring(0, 100)}...' : text}"';
  }
}
