import 'dart:convert';
import 'dart:typed_data';

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
///   print('${folder.name}  (hasChildren: ${folder.hasChildren})');
/// }
///
/// // Drill into a folder
/// final sub = await intradesk.getFolderListing(root.folders.first.id);
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
  Future<IntradeskListing> getFolderListing(String folderId) async {
    if (folderId.isEmpty) {
      throw ArgumentError.value(
        folderId,
        'folderId',
        'Must be a non-empty folder UUID.',
      );
    }
    final platformId = await _client.platformId;
    final data = await _client.getJson(
      '/intradesk/api/v1/$platformId/directory-listing/forTreeOnlyFolders/$folderId',
    );
    return IntradeskListing.fromJson(asMap(data));
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
  Future<Uint8List> downloadFile(String fileId) async {
    if (fileId.isEmpty) {
      throw ArgumentError.value(
        fileId,
        'fileId',
        'Must be a non-empty file UUID.',
      );
    }
    final platformId = await _client.platformId;
    return _client.download(
      '/intradesk/api/v1/$platformId/files/$fileId/download',
    );
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
