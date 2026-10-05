import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../exceptions.dart';
import '../session.dart';
import '../models/intradesk_models.dart';
import 'smartschool_uploader.dart';

export '../models/intradesk_models.dart';

/// Provides access to the Smartschool Intradesk document repository: it
/// lists folders and downloads files, and adds folders, weblinks and files
/// (#128).
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
///
/// // Add a folder, a weblink in it and a file (#128). Intradesk renames an
/// // item whose name is taken, so use what it answers.
/// final folder = await intradesk.createFolder(
///   parentFolderId: sub.folders.first.id,
///   name: 'Toetsen',
/// );
/// await intradesk.createWeblink(
///   parentFolderId: folder.id,
///   name: 'Oefenplatform',
///   url: 'https://example.com/oefenen',
/// );
/// final upload = await intradesk.uploadFiles(
///   parentFolderId: folder.id,
///   filePaths: ['toets 1.pdf'],
/// );
/// print(upload.files.map((f) => f.name));
///
/// // Move a file to Intradesk's trash
/// await intradesk.trashFile(upload.files.first.id);
/// ```
///
/// ### Writes (#128)
/// [createFolder], [createWeblink] and [uploadFiles] add what the web
/// client's "Toevoegen" menu adds; [trashFolder], [trashWeblink] and
/// [trashFile] move an item to Intradesk's trash, which Intradesk keeps for
/// 30 days (its `daysTrashSaved`). All of them were tried live on
/// 2026-10-05, in a test folder of the school's Intradesk. The service never
/// deletes anything for good (Intradesk's `DELETE`), and renames, moves,
/// copies, colour changes, new versions of a file and rights are not
/// covered.
///
/// What Smartschool answers, and what the service makes of it:
/// - **A name that is taken is not refused.** Intradesk adds the item under
///   a new name, `name (1)` (`name (1).ext` for a file), so the name of the
///   item it answers can differ from the one asked for. Every create returns
///   the item Intradesk made.
/// - **A create is sent once.** It is never sent again after logging in
///   again, nor retried in any other way: a second one would add a second
///   item. [uploadFiles] asks for a new upload directory for every call:
///   Intradesk takes the files of a directory again every time it is told
///   to.
/// - **Checks before sending.** Intradesk answers a bad name, colour, icon or
///   parent with a bare HTTP `500` that does not say why. So the writes
///   refuse with an [ArgumentError], before anything is sent: an empty name,
///   a name Smartschool does not allow ([isAllowedName]), a colour that is
///   not in [folderColors], an empty icon, an address that is not a URL
///   ([normalizeWeblinkUrl]), a parent folder ID that is not a UUID, a
///   weblink or a file at the root (the web client offers neither), and a
///   file that does not exist.
///
/// ### Errors of the writes
/// - [ArgumentError]: a check before sending refused the write; nothing was
///   sent.
/// - [SmartschoolIntradeskWriteRefusedError]: Intradesk refused the write
///   with an HTTP status from `400` to `499`, with its reasons in
///   `violations` when it gave any. Nothing was made.
/// - [SmartschoolIntradeskFolderNotFoundError]: Smartschool knows no folder
///   with the parent folder ID of a create. Nothing was made.
/// - [SmartschoolAttachmentUploadError]: [uploadFiles] got no upload
///   directory, or Smartschool did not take a file into it. Intradesk was
///   not told to take the files, so nothing was added.
/// - [SmartschoolIntradeskSaveUnconfirmedError]: the write went out, but
///   Intradesk's answer does not confirm it (a bare `500` for another reason,
///   an answer that is not the item made, or no answer). List the folder
///   before trying again.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session for the write. Nothing was made.
/// - [SmartschoolConnectionError]: Smartschool could not be reached for a
///   request before the write (such as an upload step). When the write
///   itself fails so, it may have gone out: a
///   [SmartschoolIntradeskSaveUnconfirmedError] instead.
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
  // Writes (#128)
  // -------------------------------------------------------------------------

  /// The colours Intradesk has for a folder, in the web client's order (its
  /// `src/list/changeColorConfig`). [createFolder] takes one of them;
  /// Intradesk answers any other colour, and a folder without one, with a
  /// bare HTTP `500` (seen live, 2026-10-05, for `mauve`).
  static const List<String> folderColors = [
    'red',
    'brown',
    'orange',
    'yellow',
    'green',
    'aqua',
    'blue',
    'purple',
    'pink',
    'white',
    'black',
  ];

  /// The colour [createFolder] gives a folder by default: the colour of
  /// nearly every folder of the school's Intradesk.
  static const defaultFolderColor = 'yellow';

  /// The icon [createWeblink] gives a weblink by default: the web client's
  /// default, a globe.
  static const defaultWeblinkIcon = 'earth';

  /// Adds a folder named [name], with the colour [color], to the folder
  /// [parentFolderId] (`''` for the root), and returns the folder Intradesk
  /// made (#128).
  ///
  /// **Its name can differ from [name]**: when the parent holds a folder of
  /// that name already, Intradesk does not refuse the new one but names it
  /// `name (1)` (seen live, 2026-10-05).
  ///
  /// Sends `POST /intradesk/api/v1/{platformId}/folders/` with
  /// `{"name", "color", "parentFolderId", "platform": {"id"}}`, which
  /// Intradesk answers with `201` and the folder (without `hasChildren`, so
  /// [IntradeskFolder.hasChildren] is `false`). With [confidential], it
  /// sends the same to `.../folders/as-confidential`, the web client's
  /// confidential folder. Intradesk refuses that in an ordinary folder (HTTP
  /// `400`, seen live: a [SmartschoolIntradeskWriteRefusedError]); the web
  /// client offers it inside a confidential folder (where it offers no
  /// ordinary folder) and at the root when the platform allows it
  /// ([IntradeskFolderCapabilities.canAddConfidentialFolder]). A confidential
  /// folder that Intradesk made was not seen live.
  ///
  /// At the root, `parentFolderId` is sent as `''`, as the web client sends
  /// it. That was not tried live (it would have added a folder outside the
  /// test folder); nor was a folder without `canAdd`
  /// ([IntradeskFolderCapabilities.canAdd]): the live account is an
  /// administrator.
  ///
  /// The create is sent **once**, never again after logging in again: a
  /// second one would add a second folder (see the class doc).
  ///
  /// Throws an [ArgumentError], without sending anything, when [name] is
  /// empty or not allowed ([isAllowedName]), [color] is not one of
  /// [folderColors], or [parentFolderId] is neither `''` nor a UUID. A
  /// parent that Smartschool knows no folder for is a
  /// [SmartschoolIntradeskFolderNotFoundError]. See the class doc for the
  /// other errors.
  Future<IntradeskFolder> createFolder({
    required String parentFolderId,
    required String name,
    String color = defaultFolderColor,
    bool confidential = false,
  }) async {
    const operation = 'createFolder';
    _checkParent(parentFolderId, allowRoot: true);
    _checkName(name);
    if (!folderColors.contains(color)) {
      throw ArgumentError.value(
        color,
        'color',
        'is not one of the colours Intradesk has for a folder: '
            '${folderColors.join(', ')}',
      );
    }
    final platformId = await _client.platformId;
    final kind = confidential ? 'confidential folder' : 'folder';
    final what = 'the creation of $kind "$name" in ${_where(parentFolderId)}';
    final json = await _create(
      operation,
      platformId: platformId,
      path:
          '/intradesk/api/v1/$platformId/folders/'
          '${confidential ? 'as-confidential' : ''}',
      body: {
        'name': name,
        'color': color,
        'parentFolderId': parentFolderId,
        'platform': {'id': platformId},
      },
      parentFolderId: parentFolderId,
      change: what,
    );
    final folder = _parsed(
      operation,
      what,
      () => IntradeskFolder.fromJson(json),
    );
    _checkMade(
      operation,
      what,
      'a folder',
      id: folder.id,
      answeredParent: folder.parentFolderId,
      parentFolderId: parentFolderId,
    );
    return folder;
  }

  /// Adds a weblink named [name] to the folder [parentFolderId], which opens
  /// [url] and shows the icon [icon], and returns the weblink Intradesk made
  /// (#128).
  ///
  /// **Its name can differ from [name]**: when the folder holds a weblink of
  /// that name already, Intradesk names the new one `name (1)` (seen live,
  /// 2026-10-05).
  ///
  /// [url] is sent the way the web client sends it
  /// ([normalizeWeblinkUrl]): without white space, and with `http://` in
  /// front when it starts without `http://` or `https://`; so
  /// `example.com/page` is sent as `http://example.com/page`, where
  /// Intradesk itself refuses an address without them (HTTP `400`, seen
  /// live). [IntradeskWeblink.url] of the answer is the address Intradesk
  /// stored.
  ///
  /// Intradesk does not check [icon] (it stored a made-up icon name as it
  /// was sent, live), but it needs one: without it, it answers with a bare
  /// HTTP `500`. The web client picks one from Smartschool's icon set; its
  /// default is [defaultWeblinkIcon].
  ///
  /// Sends `POST /intradesk/api/v1/{platformId}/weblinks/` with
  /// `{"name", "url", "icon", "parentFolderId", "platform": {"id"}}`, which
  /// Intradesk answers with `201` and the weblink. The create is sent
  /// **once**, never again after logging in again: a second one would add a
  /// second weblink.
  ///
  /// Throws an [ArgumentError], without sending anything, when [name] is
  /// empty or not allowed ([isAllowedName]), [url] is not an address the web
  /// client takes, [icon] is empty, or [parentFolderId] is not a folder UUID:
  /// the web client offers no weblink at the root (`''`), and that was not
  /// tried live. A parent that Smartschool knows no folder for is a
  /// [SmartschoolIntradeskFolderNotFoundError]. See the class doc for the
  /// other errors.
  Future<IntradeskWeblink> createWeblink({
    required String parentFolderId,
    required String name,
    required String url,
    String icon = defaultWeblinkIcon,
  }) async {
    const operation = 'createWeblink';
    _checkParent(parentFolderId, allowRoot: false);
    _checkName(name);
    final address = normalizeWeblinkUrl(url);
    if (address == null) {
      throw ArgumentError.value(
        url,
        'url',
        'is not a web address (such as https://example.com/page)',
      );
    }
    if (icon.trim().isEmpty) {
      throw ArgumentError.value(icon, 'icon', 'is empty');
    }
    final platformId = await _client.platformId;
    final what =
        'the creation of weblink "$name" (${_preview(address)}) in '
        '${_where(parentFolderId)}';
    final json = await _create(
      operation,
      platformId: platformId,
      path: '/intradesk/api/v1/$platformId/weblinks/',
      body: {
        'name': name,
        'url': address,
        'icon': icon,
        'parentFolderId': parentFolderId,
        'platform': {'id': platformId},
      },
      parentFolderId: parentFolderId,
      change: what,
    );
    final weblink = _parsed(
      operation,
      what,
      () => IntradeskWeblink.fromJson(json),
    );
    _checkMade(
      operation,
      what,
      'a weblink',
      id: weblink.id,
      answeredParent: weblink.parentFolderId,
      parentFolderId: parentFolderId,
    );
    return weblink;
  }

  /// Uploads the files at [filePaths] into the folder [parentFolderId], each
  /// under the last segment of its path as its name, and returns what
  /// Intradesk made of them (#128).
  ///
  /// **The names can differ**: when the folder holds a file of that name
  /// already, Intradesk names the new one `name (1).ext` (seen live,
  /// 2026-10-05). Tell the files of [IntradeskUploadResult.files] by their
  /// IDs. A file that Intradesk did not take is in
  /// [IntradeskUploadResult.failures] instead, with Intradesk's reason (not
  /// seen live).
  ///
  /// Three steps, as the web client's dropzone takes them (all tried live,
  /// 2026-10-05):
  /// 1. `GET /upload/api/v1/get-upload-directory`: a new upload directory,
  ///    for this call only.
  /// 2. For each file, `POST /Upload/Upload/Index` with the file and the
  ///    directory (Smartschool's upload step, shared with the attachments of
  ///    `MessagesService.sendMessage`).
  /// 3. `POST /intradesk/api/v1/{platformId}/files/upload` with
  ///    `{"parentFolderId", "uploadDir"}`: Intradesk takes the files of the
  ///    directory into the folder, and answers `201` with
  ///    `{"files": {"<fileId>": {...}}, "exceptions": []}`.
  ///
  /// The directory is not bound to the session (seen live: a second session
  /// of the same user, from a fresh login, could upload into it), so steps 1
  /// and 2 are retried after logging in again, like a read. Step 3 is sent
  /// **once**, never again after logging in again: Intradesk takes the files
  /// of a directory again every time it is told to (seen live: the second
  /// time, as `name (1).ext`). When step 2 fails for a file, the files
  /// uploaded before it stay in the directory, which is not used again:
  /// Intradesk is not told to take them.
  ///
  /// The uploaded file downloads back unchanged through [downloadFile] (seen
  /// live).
  ///
  /// Throws an [ArgumentError], without sending anything, when [filePaths]
  /// is empty, names a file that does not exist, a file whose name is not
  /// allowed ([isAllowedName], which Smartschool refuses at step 2 with HTTP
  /// `400`), or two files with the same name; or when [parentFolderId] is
  /// not a folder UUID: the web client offers no upload at the root (`''`),
  /// and that was not tried live. A failure of step 1 or 2 is a
  /// [SmartschoolAttachmentUploadError] (nothing was added); a parent that
  /// Smartschool knows no folder for, a
  /// [SmartschoolIntradeskFolderNotFoundError]. See the class doc for the
  /// other errors.
  Future<IntradeskUploadResult> uploadFiles({
    required String parentFolderId,
    required List<String> filePaths,
  }) async {
    const operation = 'uploadFiles';
    _checkParent(parentFolderId, allowRoot: false);
    if (filePaths.isEmpty) {
      throw ArgumentError.value(filePaths, 'filePaths', 'is empty');
    }
    final names = <String>{};
    for (final path in filePaths) {
      final file = File(path);
      if (!file.existsSync()) {
        throw ArgumentError.value(path, 'filePaths', 'names no file');
      }
      final name = file.uri.pathSegments.last;
      _checkName(name, argument: 'filePaths');
      if (!names.add(name)) {
        throw ArgumentError.value(
          path,
          'filePaths',
          'names a second file called "$name": upload files with the same '
              'name in separate calls',
        );
      }
    }
    final platformId = await _client.platformId;

    final uploader = SmartschoolUploader(_client);
    final uploadDir = await uploader.newDirectory();
    for (final path in filePaths) {
      await uploader.uploadFile(uploadDir, path);
    }

    final count = filePaths.length == 1
        ? 'file "${names.single}"'
        : '${filePaths.length} files';
    final what = 'the upload of $count into ${_where(parentFolderId)}';
    final json = await _create(
      operation,
      platformId: platformId,
      path: '/intradesk/api/v1/$platformId/files/upload',
      body: {'parentFolderId': parentFolderId, 'uploadDir': uploadDir},
      parentFolderId: parentFolderId,
      change: what,
    );
    final result = _parsed(
      operation,
      what,
      () => IntradeskUploadResult.fromJson(json),
    );
    for (final file in result.files) {
      _checkMade(
        operation,
        what,
        'a file',
        id: file.id,
        answeredParent: file.parentFolderId,
        parentFolderId: parentFolderId,
      );
    }
    return result;
  }

  /// Moves the folder [folderId] to Intradesk's trash (#128).
  ///
  /// Sends `POST /intradesk/api/v1/{platformId}/folders/{folderId}/trash`
  /// with `{}`, which Intradesk answers with `204` (seen live, 2026-10-05);
  /// the folder then no longer shows in the listing of its parent. Intradesk
  /// keeps its trash for 30 days, and its web client can restore from it;
  /// the service does neither read nor restore the trash, and never deletes
  /// for good (`DELETE`).
  ///
  /// Intradesk answers the trash of a folder that is in the trash already
  /// with `204` as well (seen live, for a weblink), so the move is retried
  /// once after logging in again, like a read.
  ///
  /// Throws an [ArgumentError], without sending anything, when [folderId] is
  /// not a UUID. A refusal by Intradesk (HTTP `400` to `499`) is a
  /// [SmartschoolIntradeskWriteRefusedError]; another answer than `2xx`, a
  /// [SmartschoolIntradeskSaveUnconfirmedError]. Neither the answer for an
  /// unknown ID nor that for an item without the rights to it was seen live.
  Future<void> trashFolder(String folderId) =>
      _trash('trashFolder', 'folders', 'folder', folderId, 'folderId');

  /// Moves the weblink [weblinkId] to Intradesk's trash (#128), with
  /// `POST /intradesk/api/v1/{platformId}/weblinks/{weblinkId}/trash`; see
  /// [trashFolder].
  Future<void> trashWeblink(String weblinkId) =>
      _trash('trashWeblink', 'weblinks', 'weblink', weblinkId, 'weblinkId');

  /// Moves the file [fileId] to Intradesk's trash (#128), with
  /// `POST /intradesk/api/v1/{platformId}/files/{fileId}/trash`; see
  /// [trashFolder].
  Future<void> trashFile(String fileId) =>
      _trash('trashFile', 'files', 'file', fileId, 'fileId');

  /// Whether Smartschool allows [name] as the name of a folder, a weblink or
  /// a file: none of `/ : * ? " \ < > |`, and no dot at its start or end, as
  /// the web client checks it before it adds or renames an item
  /// (`nameCharsAreAllowed`, #128). [createFolder], [createWeblink] and
  /// [uploadFiles] refuse a name it does not allow, and an empty one.
  ///
  /// Seen live (2026-10-05): Intradesk answers a folder or weblink named
  /// with a `/` with a bare HTTP `500`, and Smartschool's upload step a file
  /// name with one of those characters, or one that starts with a dot, with
  /// HTTP `400` and the rule in its own words. `#` is allowed.
  static bool isAllowedName(String name) =>
      SmartschoolUploader.isAllowedName(name);

  /// [url] as the web client sends the address of a weblink, or `null` when
  /// the web client would refuse it (#128): without white space, with
  /// `http://` in front when it does not start with `http://` or `https://`
  /// (in any case), and then only when it holds an address of the form the
  /// web client checks (a host name with a dot and a top-level domain of
  /// letters, such as `example.com`, after `http(s)://`).
  ///
  /// So `example.com/page` gives `http://example.com/page`, and `geen url`
  /// gives `null`. Intradesk itself refuses an address without
  /// `http(s)://`, and one that is not a URL, with HTTP `400` (seen live,
  /// 2026-10-05).
  static String? normalizeWeblinkUrl(String url) {
    var address = url.replaceAll(RegExp(r'\s'), '');
    if (address.isEmpty) return null;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(address)) {
      address = 'http://$address';
    }
    return _webAddress.hasMatch(address) ? address : null;
  }

  /// The web client's check of a weblink's address (`isUrlValid` of its
  /// `src/weblinkDialog/weblinkDialog`), as it has it: not anchored.
  static final _webAddress = RegExp(
    r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._+~#=]{2,256}\.[a-z]{2,63}\b'
    r'([-a-zA-Z0-9@:%_+.~#?&//=]*)',
    caseSensitive: false,
  );

  /// A folder, weblink or file ID: a UUID.
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// Throws an [ArgumentError] unless [parentFolderId] is a folder UUID, or
  /// `''` (the root) when [allowRoot].
  static void _checkParent(String parentFolderId, {required bool allowRoot}) {
    if (parentFolderId.isEmpty) {
      if (allowRoot) return;
      throw ArgumentError.value(
        parentFolderId,
        'parentFolderId',
        'is the root (""): the web client adds no weblink or file at the '
            'root, so the service does not either; name a folder',
      );
    }
    if (!_uuid.hasMatch(parentFolderId)) {
      throw ArgumentError.value(
        parentFolderId,
        'parentFolderId',
        allowRoot
            ? 'is neither a folder UUID nor "" (the root)'
            : 'is not a folder UUID',
      );
    }
  }

  /// Throws an [ArgumentError] (for [argument]) when [name] is empty or not
  /// allowed ([isAllowedName]).
  static void _checkName(String name, {String argument = 'name'}) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, argument, 'is empty');
    }
    if (!isAllowedName(name)) {
      throw ArgumentError.value(
        name,
        argument,
        'is not allowed by Smartschool: no / : * ? " \\ < > |, and no dot at '
        'its start or end',
      );
    }
  }

  /// The parent folder [parentFolderId] in a message: the root for `''`.
  static String _where(String parentFolderId) =>
      parentFolderId.isEmpty ? 'the root' : 'folder $parentFolderId';

  /// [text], cut short for a message.
  static String _preview(String text, {int max = 80}) =>
      text.length <= max ? text : '${text.substring(0, max)}...';

  /// Sends the create [body] to [path] **once** (never again after logging
  /// in again), and returns Intradesk's answer as a JSON object when it has
  /// status `201` (or `200`).
  ///
  /// Throws:
  /// - a [SmartschoolIntradeskWriteRefusedError] for an answer from `400` to
  ///   `499`;
  /// - a [SmartschoolIntradeskFolderNotFoundError] for a `500` when
  ///   [parentFolderId] names no folder (asked as [getFolderListing] asks,
  ///   #37);
  /// - a [SmartschoolIntradeskSaveUnconfirmedError] for any other answer,
  ///   one that is not a JSON object, and a failure after the create went
  ///   out.
  Future<Map<String, dynamic>> _create(
    String operation, {
    required int platformId,
    required String path,
    required Map<String, Object?> body,
    required String parentFolderId,
    required String change,
  }) async {
    final unconfirmed =
        'It may or may not have been made: list ${_where(parentFolderId)} '
        '(getFolderListing) before trying again; trying again adds another '
        'one if it was made.';
    final response = await _send(
      operation,
      path: path,
      body: body,
      retryAfterLogin: false,
      change: change,
      unconfirmed: unconfirmed,
    );
    final status = response.statusCode ?? 0;
    if (status != 201 && status != 200) {
      if (status == 500 &&
          parentFolderId.isNotEmpty &&
          await _isNotAFolder(platformId, parentFolderId)) {
        throw SmartschoolIntradeskFolderNotFoundError(parentFolderId);
      }
      _throwFailure(operation, response, change, unconfirmed);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.data ?? '');
    } on FormatException {
      throw SmartschoolIntradeskSaveUnconfirmedError(
        '$operation: $change was sent, but Intradesk answered with something '
        'that is not JSON (HTTP $status). $unconfirmed',
        statusCode: status,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw SmartschoolIntradeskSaveUnconfirmedError(
        '$operation: $change was sent, but Intradesk answered with '
        '${decoded.runtimeType} instead of an object (HTTP $status). '
        '$unconfirmed',
        statusCode: status,
      );
    }
    return decoded;
  }

  /// What [parse] makes of a create's answer, or a
  /// [SmartschoolIntradeskSaveUnconfirmedError] when it cannot read it.
  static T _parsed<T>(String operation, String change, T Function() parse) {
    try {
      return parse();
    } on SmartschoolParsingError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolIntradeskSaveUnconfirmedError(
          '$operation: $change was sent, but Intradesk\'s answer cannot be '
          'read (${e.message}). List the folder (getFolderListing) before '
          'trying again.',
          statusCode: 201,
          cause: e,
        ),
        stackTrace,
      );
    }
  }

  /// Throws a [SmartschoolIntradeskSaveUnconfirmedError] unless the [item]
  /// of a create's answer has an [id] and is in the folder [parentFolderId]
  /// that [change] asked for: its [answeredParent].
  static void _checkMade(
    String operation,
    String change,
    String item, {
    required String id,
    required String answeredParent,
    required String parentFolderId,
  }) {
    final String problem;
    if (id.isEmpty) {
      problem = '$item without an ID';
    } else if (answeredParent.toLowerCase() != parentFolderId.toLowerCase()) {
      problem = '$item in ${_where(answeredParent)}';
    } else {
      return;
    }
    throw SmartschoolIntradeskSaveUnconfirmedError(
      '$operation: $change was sent, but Intradesk answered with $problem. '
      'List ${_where(parentFolderId)} (getFolderListing) before trying '
      'again.',
      statusCode: 201,
    );
  }

  /// Moves the item [id] of the kind [path] (`folders`, `weblinks`,
  /// `files`) to Intradesk's trash; see [trashFolder].
  Future<void> _trash(
    String operation,
    String path,
    String item,
    String id,
    String argument,
  ) async {
    if (!_uuid.hasMatch(id)) {
      throw ArgumentError.value(id, argument, 'Must be a UUID.');
    }
    final platformId = await _client.platformId;
    final change = 'the move of $item $id to the trash';
    const unconfirmed =
        'It may or may not be in the trash: list its folder '
        '(getFolderListing) before trying again; moving it to the trash '
        'again is harmless.';
    final response = await _send(
      operation,
      path: '/intradesk/api/v1/$platformId/$path/$id/trash',
      body: const <String, Object?>{},
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
    );
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    _throwFailure(operation, response, change, unconfirmed);
  }

  /// Sends the write [body] to [path] and returns Intradesk's answer,
  /// whatever its status.
  ///
  /// A session that Smartschool refuses (a [SmartschoolAuthenticationError])
  /// is thrown as it is: the write was not carried out. Any other failure is
  /// a [SmartschoolIntradeskSaveUnconfirmedError] that ends in
  /// [unconfirmed]: the write may have reached Intradesk.
  Future<Response<String>> _send(
    String operation, {
    required String path,
    required Map<String, Object?> body,
    required bool retryAfterLogin,
    required String change,
    required String unconfirmed,
  }) async {
    try {
      return await _client.postJsonResponse(
        path,
        data: body,
        retryAfterLogin: retryAfterLogin,
      );
    } on SmartschoolAuthenticationError {
      // Refused before Intradesk handled it (and, for a create, not sent
      // again): nothing was made.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolIntradeskSaveUnconfirmedError(
          '$operation: $change was sent, but no answer came in ($e). '
          '$unconfirmed',
          cause: e,
        ),
        stackTrace,
      );
    }
  }

  /// Throws the error for Intradesk's answer [response] to a write, which
  /// has another status than the write expects: a
  /// [SmartschoolIntradeskWriteRefusedError] for `400` to `499`, a
  /// [SmartschoolIntradeskSaveUnconfirmedError] that ends in [unconfirmed]
  /// for any other status.
  static Never _throwFailure(
    String operation,
    Response<String> response,
    String change,
    String unconfirmed,
  ) {
    final status = response.statusCode ?? 0;
    final body = response.data ?? '';
    if (status >= 400 && status < 500) {
      final violations = parseViolations(body);
      final why = violations.isEmpty
          ? 'without saying why'
          : violations.map((v) => '"$v"').join(', ');
      throw SmartschoolIntradeskWriteRefusedError(
        '$operation: Intradesk refused $change (HTTP $status), $why. Nothing '
        'was made.',
        statusCode: status,
        violations: violations,
      );
    }
    throw SmartschoolIntradeskSaveUnconfirmedError(
      '$operation: $change was sent, but Intradesk answered with HTTP '
      '$status${body.trim().isEmpty ? '' : ' (${_preview(body.trim())})'}. '
      '$unconfirmed',
      statusCode: status,
    );
  }

  /// The `violations` of Intradesk's problem answer [body] (#128): the
  /// reasons it gives, in its own words, for a write it refuses, such as
  /// `{"status":400,"title":"Bad Request","detail":"","type":"",
  /// "violations":["De URL die je hebt ingegeven is niet geldig."]}` (seen
  /// live, 2026-10-05). A list, or an object whose values are the reasons
  /// (as the web client also reads them); empty when there are none, or
  /// when [body] is not such an answer.
  ///
  /// Exposed for testing.
  static List<String> parseViolations(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    final raw = decoded is Map ? decoded['violations'] : null;
    final Iterable<Object?> values = switch (raw) {
      final List<Object?> list => list,
      final Map<Object?, Object?> map => map.values,
      _ => const [],
    };
    return List.unmodifiable([
      for (final value in values)
        if (value != null && '$value'.trim().isNotEmpty) '$value'.trim(),
    ]);
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
