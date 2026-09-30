import 'dart:convert';
import 'dart:typed_data';

import '../exceptions.dart';
import '../session.dart';
import '../models/intradesk_models.dart';

export '../models/intradesk_models.dart';

/// Provides read access to the Smartschool Intradesk document repository.
///
/// Intradesk is Smartschool's shared file store, organised as a tree of
/// folders that may contain folders, files, and weblinks.
///
/// ```dart
/// final intradesk = IntradeskService(client);
///
/// // List root folders and files
/// final root = await intradesk.getRootListing();
/// for (final folder in root.folders) {
///   print('${folder.name}  (hasSubfolders: ${folder.hasSubfolders})');
/// }
///
/// // Drill into a folder (also one without subfolders: it can still hold
/// // files and weblinks)
/// final sub = await intradesk.getFolderListing(root.folders.first.id);
/// for (final link in sub.weblinks) {
///   print('${link.name}: ${link.url}');
/// }
///
/// // Download a file
/// final bytes = await intradesk.downloadFile(sub.files.first.id);
/// ```
///
/// ### Upload
/// File upload is not yet implemented — the server-side endpoint and required
/// form fields have not been captured safely.  Use the `postMultipartRaw`
/// transport on [SmartschoolClient] directly once the endpoint is known.
class IntradeskService {
  final SmartschoolClient _client;

  IntradeskService(SmartschoolClient client) : _client = client;

  // -------------------------------------------------------------------------
  // Listing endpoints
  // -------------------------------------------------------------------------

  /// Returns the root-level [IntradeskListing] (folders, files, weblinks at
  /// the top of the tree).
  ///
  /// Calls `GET /intradesk/api/v1/{platformId}/directory-listing/forTreeOnlyFolders`
  Future<IntradeskListing> getRootListing() async {
    final platformId = await _client.platformId;
    final data = await _client.getJson(
      '/intradesk/api/v1/$platformId/directory-listing/forTreeOnlyFolders',
    );
    return IntradeskListing.fromJson(asMap(data));
  }

  /// Returns the [IntradeskListing] for the folder identified by [folderId].
  ///
  /// Calls `GET /intradesk/api/v1/{platformId}/directory-listing/forTreeOnlyFolders/{folderId}`
  ///
  /// Throws a [SmartschoolIntradeskFolderNotFoundError] when Smartschool
  /// knows no folder with [folderId]: an unknown ID, or the ID of a file or a
  /// weblink (#37). Smartschool answers the listing of such an ID with HTTP
  /// `500`, as it would for a failure of its own; to tell them apart, a
  /// listing that fails with `500` is followed by one more request, for the
  /// parents of the folder (`GET /intradesk/api/v1/{platformId}/folders/{folderId}/parents`),
  /// which Smartschool answers with `404` for an ID that is not a folder. Any
  /// other failure of the listing is thrown as before, typically as a
  /// [SmartschoolDownloadError] with the HTTP status; that includes an ID
  /// that is not a UUID at all, whose parents Smartschool answers with `500`
  /// too.
  Future<IntradeskListing> getFolderListing(String folderId) async {
    if (folderId.isEmpty) {
      throw ArgumentError.value(
        folderId,
        'folderId',
        'Must be a non-empty folder UUID.',
      );
    }
    final platformId = await _client.platformId;
    final dynamic data;
    try {
      data = await _client.getJson(
        '/intradesk/api/v1/$platformId/directory-listing/forTreeOnlyFolders/$folderId',
      );
    } on SmartschoolDownloadError catch (e) {
      if (e.statusCode == 500 && await _isNotAFolder(platformId, folderId)) {
        throw SmartschoolIntradeskFolderNotFoundError(folderId);
      }
      rethrow;
    }
    return IntradeskListing.fromJson(asMap(data));
  }

  /// Whether Smartschool answers the parents of [folderId] with `404`, as it
  /// does for an ID that is not a folder (an unknown ID, or the ID of a file
  /// or a weblink), where it answers a folder with its parents (#37).
  ///
  /// `false` for any other answer, and when the request fails: the caller
  /// then keeps the error of the listing.
  Future<bool> _isNotAFolder(int platformId, String folderId) async {
    try {
      final resp = await _client.getResponse(
        '/intradesk/api/v1/$platformId/folders/$folderId/parents',
      );
      return resp.statusCode == 404;
    } on Exception {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // File download
  // -------------------------------------------------------------------------

  /// Downloads the binary content of the file identified by [fileId].
  ///
  /// Calls `GET /intradesk/api/v1/{platformId}/files/{fileId}/download`
  ///
  /// Returns the raw bytes.  To write to disk:
  /// ```dart
  /// final bytes = await intradesk.downloadFile(file.id);
  /// await File('output.docx').writeAsBytes(bytes);
  /// ```
  ///
  /// The whole file is held in memory; [downloadFileStream] reads it as it
  /// comes in instead. With [maxBytes], the download fails with a
  /// [SmartschoolDownloadTooLargeError] as soon as the file turns out to be
  /// larger than that many bytes, and stops the transfer (#41); see
  /// [SmartschoolClient.download]. The size in a listing
  /// (`IntradeskFile.currentRevision.fileSize`) may be out of date, so this
  /// checks the file itself.
  ///
  /// Throws a [SmartschoolDownloadError] with status `404` when Smartschool
  /// knows no file with [fileId].
  Future<Uint8List> downloadFile(String fileId, {int? maxBytes}) async {
    return _client.download(await _downloadPath(fileId), maxBytes: maxBytes);
  }

  /// Downloads the file identified by [fileId] as a stream, from the same
  /// URL as [downloadFile] (#41).
  ///
  /// Returns as soon as the headers of Smartschool's answer are in, with the
  /// size (`contentLength`) and name (`fileName`) Smartschool gives the file,
  /// and the content to be read from `stream` as it comes in; cancelling the
  /// subscription stops the transfer. [maxBytes] limits the download as for
  /// [downloadFile]: a larger announced size throws a
  /// [SmartschoolDownloadTooLargeError] here, otherwise the stream ends with
  /// it. See [SmartschoolClient.downloadStream].
  ///
  /// ```dart
  /// final download = await intradesk.downloadFileStream(
  ///   file.id,
  ///   maxBytes: 25 * 1024 * 1024,
  /// );
  /// await download.stream.pipe(File('download.bin').openWrite());
  /// ```
  ///
  /// Smartschool's answer gives every file the `contentType`
  /// `application/x-www-form-urlencoded`; tell the type from the name.
  Future<SmartschoolDownload> downloadFileStream(
    String fileId, {
    int? maxBytes,
  }) async {
    return _client.downloadStream(
      await _downloadPath(fileId),
      maxBytes: maxBytes,
    );
  }

  /// The download URL of the file identified by [fileId].
  Future<String> _downloadPath(String fileId) async {
    if (fileId.isEmpty) {
      throw ArgumentError.value(
        fileId,
        'fileId',
        'Must be a non-empty file UUID.',
      );
    }
    final platformId = await _client.platformId;
    return '/intradesk/api/v1/$platformId/files/$fileId/download';
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Ensures the decoded JSON value is a [Map].  The listing endpoints always
  /// return a JSON object at the top level; anything else indicates a parsing
  /// error.
  static Map<String, dynamic> asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    throw FormatException(
      'IntradeskService: expected a JSON object, got ${data.runtimeType}',
    );
  }
}
