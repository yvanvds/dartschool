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
/// // Read a folder by its ID alone: its own entry, and the folders above
/// // it (#132)
/// final folder = await intradesk.getFolder(folderId);
/// print('${folder.name}, may add: ${folder.capabilities.canAdd}');
/// final path = await intradesk.getFolderPath(folderId);
/// print(path.map((f) => f.name).join(' > ')); // 2. SMA > tests
///
/// // Download a file
/// final bytes = await intradesk.downloadFile(sub.files.first.id);
///
/// // Add a folder, a weblink in it and a file (#128). Intradesk renames an
/// // item whose name is taken, so use what it answers.
/// final toetsen = await intradesk.createFolder(
///   parentFolderId: sub.folders.first.id,
///   name: 'Toetsen',
/// );
/// await intradesk.createWeblink(
///   parentFolderId: toetsen.id,
///   name: 'Oefenplatform',
///   url: 'https://example.com/oefenen',
/// );
/// final upload = await intradesk.uploadFiles(
///   parentFolderId: toetsen.id,
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
/// - **The parent folder is read first (#138).** The creates read the
///   folder they add to ([getFolder]: two requests; at the root
///   [getRootCapabilities]: one) and add only what Intradesk's web client
///   offers there: nothing without `canAdd`, no confidential folder in an
///   ordinary folder (Intradesk answers one with HTTP `400`), no ordinary
///   folder in a confidential one, and a confidential folder at the root
///   only with the platform's `canAddConfidentialFolder`. Anything else is a
///   [SmartschoolIntradeskAddRefusedError], and a parent the read does not
///   find (an unknown ID, a folder in the trash) a
///   [SmartschoolIntradeskFolderNotFoundError], both before anything of the
///   write is sent.
///
/// ### Errors of the writes
/// - [ArgumentError]: a check before sending refused the write; nothing was
///   sent.
/// - [SmartschoolIntradeskWriteRefusedError]: Intradesk refused the write
///   with an HTTP status from `400` to `499`, with its reasons in
///   `violations` when it gave any. Nothing was made.
/// - [SmartschoolIntradeskAddRefusedError], one of those: the parent folder
///   does not allow what a create adds, as the web client tells it (#138:
///   its `reason`, with the folder as it was read). Nothing was sent; its
///   `statusCode` is `null`.
/// - [SmartschoolIntradeskItemNotFoundError], one of those: Intradesk has no
///   item of that kind with the ID of a move to the trash (`404`: a made-up
///   ID, or the ID of an item of another kind, #133). Nothing was moved.
/// - [SmartschoolIntradeskFolderNotFoundError]: Smartschool knows no folder
///   with the parent folder ID of a create, or the folder is in the trash or
///   not visible to the user (seen in the read of the parent before the
///   create, #138, or told apart after a bare `500`, #37). Nothing was made.
/// - [SmartschoolDownloadError] (and the other errors of a read): the read
///   of the parent folder before a create failed (#138). Nothing was sent.
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
  // A folder's own entry (#132)
  // -------------------------------------------------------------------------

  /// The IDs of the folders above the folder [folderId]: the folder at the
  /// root first, the folder's parent last (#132).
  ///
  /// Calls `GET /intradesk/api/v1/{platformId}/folders/{folderId}/parents`,
  /// which Smartschool answers with a JSON list of folder IDs in that order
  /// (seen live, 2026-10-07: `["<2. SMA>"]` for "2. SMA" > "tests",
  /// `["<2. SMA>", "<tests>"]` for a folder in "tests"). The web client asks
  /// it when it opens a folder by its address, to list the folders above it.
  ///
  /// **An empty list does not mean the folder is at the root**: Smartschool
  /// answers `[]` for a folder at the root, and also for a folder in
  /// Intradesk's trash (seen live: a folder moved to the trash from "tests"
  /// answered `["<2. SMA>", "<tests>"]` before, and `[]` after). [getFolder]
  /// and [getFolderPath] tell them apart: they look the folder up where its
  /// parents put it.
  ///
  /// One request. Throws an [ArgumentError], without sending anything, when
  /// [folderId] is not a UUID (Smartschool answers such an ID with a bare
  /// HTTP `500`). Throws a [SmartschoolIntradeskFolderNotFoundError] (with
  /// [SmartschoolDownloadError.statusCode] `404`) when Smartschool knows no
  /// folder with [folderId]: an unknown ID, or the ID of a file or a weblink,
  /// which it answers with `404` (#37). Another status is a
  /// [SmartschoolDownloadError] with that status, an answer that is not JSON
  /// a [SmartschoolJsonError], and one that is not a list of IDs a
  /// [SmartschoolParsingError].
  Future<List<String>> getFolderParentIds(String folderId) async {
    _checkFolderId(folderId);
    final platformId = await _client.platformId;
    final dynamic data;
    try {
      data = await _client.getJson(
        '/intradesk/api/v1/$platformId/folders/$folderId/parents',
      );
    } on SmartschoolDownloadError catch (e) {
      if (e.statusCode == 404) {
        throw SmartschoolIntradeskFolderNotFoundError(
          folderId,
          statusCode: 404,
        );
      }
      rethrow;
    }
    return parseFolderParentIds(data);
  }

  /// The folder [folderId] as Intradesk lists it: its entry in the listing
  /// of the folder above it (#132), with its name, colour, `confidential`,
  /// `inConfidentialFolder`, `parentFolderId`, `hasChildren` and
  /// `capabilities` ([IntradeskFolderCapabilities.canAdd] says whether the
  /// user may add to it, as [createFolder], [createWeblink] and [uploadFiles]
  /// do).
  ///
  /// [getFolderListing] answers what is *in* a folder, not the folder
  /// itself, and Smartschool has no request for one folder (`GET
  /// .../folders/{folderId}` answers the web client's page, not JSON). So
  /// this asks for the folder's parents ([getFolderParentIds]) and lists the
  /// last of them ([getFolderListing]), or the root ([getRootListing]) for a
  /// folder at the root, as the web client does when it opens a folder by
  /// its address: two requests. [getFolderPath] reads the folders above it
  /// too.
  ///
  /// Throws an [ArgumentError], without sending anything, when [folderId] is
  /// not a UUID. Throws a [SmartschoolIntradeskFolderNotFoundError] when
  /// Smartschool knows no folder with [folderId] (status `404`, see
  /// [getFolderParentIds]), and when the listing where its parents put it
  /// does not hold it (status `200`): a folder in Intradesk's trash (seen
  /// live, 2026-10-07: its parents are `[]`, and the root listing does not
  /// hold it), or a folder the user does not see. A listing that fails
  /// throws as [getFolderListing] and [getRootListing] do.
  Future<IntradeskFolder> getFolder(String folderId) async {
    final parentIds = await getFolderParentIds(folderId);
    final parentId = parentIds.isEmpty ? '' : parentIds.last;
    final listing = await _listingOf(parentId);
    return _listed(listing, folderId, parentId, folderId);
  }

  /// The folders from the root down to the folder [folderId]: the folder at
  /// the root first, the folder itself last, each one an entry of the
  /// listing of the one before it (#132). The path the web client shows
  /// above a folder; `getFolderPath(id).last` is [getFolder]'s folder, and
  /// the folders before it are those above it, as [IntradeskFolder]s.
  ///
  /// Asks for the folder's parents ([getFolderParentIds]), then lists the
  /// root and each of the parents in turn, as the web client does when it
  /// opens a folder by its address: one request more than the folder has
  /// folders above it, plus the parents (three for "2. SMA" > "tests").
  ///
  /// Throws as [getFolder]: an [ArgumentError] for a [folderId] that is not
  /// a UUID; a [SmartschoolIntradeskFolderNotFoundError] for an ID that is
  /// not a folder (status `404`), and when a listing does not hold the
  /// folder that the parents put in it (status `200`; a folder in the trash,
  /// one the user does not see, or a folder that was moved in between).
  Future<List<IntradeskFolder>> getFolderPath(String folderId) async {
    final parentIds = await getFolderParentIds(folderId);
    final path = <IntradeskFolder>[];
    var where = '';
    for (final id in [...parentIds, folderId]) {
      final listing = await _listingOf(where);
      final folder = _listed(listing, id, where, folderId);
      path.add(folder);
      where = folder.id;
    }
    return List.unmodifiable(path);
  }

  /// Reads Smartschool's answer to `folders/{folderId}/parents` (#132): a
  /// JSON list of folder IDs, the folder at the root first.
  ///
  /// Throws a [SmartschoolParsingError] for anything else: not a list, or an
  /// entry that is not a non-empty string.
  ///
  /// Exposed for testing.
  static List<String> parseFolderParentIds(Object? data) {
    if (data is! List) {
      throw SmartschoolParsingError(
        'Intradesk answered the parents of a folder with '
        '${data.runtimeType}, not a list of folder IDs',
      );
    }
    return List.unmodifiable([
      for (final id in data)
        if (id is String && id.isNotEmpty)
          id
        else
          throw SmartschoolParsingError(
            'Intradesk answered the parents of a folder with an entry that '
            'is not a folder ID: $id',
          ),
    ]);
  }

  /// The listing of the folder [folderId], or of the root for `''`.
  Future<IntradeskListing> _listingOf(String folderId) =>
      folderId.isEmpty ? getRootListing() : getFolderListing(folderId);

  /// The folder [id] of [listing], the listing of [where] (`''` for the
  /// root), where the parents of [asked] put it; a
  /// [SmartschoolIntradeskFolderNotFoundError] for [asked] when the listing
  /// does not hold it.
  static IntradeskFolder _listed(
    IntradeskListing listing,
    String id,
    String where,
    String asked,
  ) {
    final key = id.toLowerCase();
    for (final folder in listing.folders) {
      if (folder.id.toLowerCase() == key) return folder;
    }
    final which = key == asked.toLowerCase()
        ? 'folder $asked in ${_where(where)}, where its parents put it'
        : 'folder $id in ${_where(where)}, where the parents of folder '
              '$asked put it';
    throw SmartschoolIntradeskFolderNotFoundError(
      asked,
      statusCode: 200,
      message:
          'Intradesk does not list $which: the folder is in Intradesk\'s '
          'trash (Smartschool answers the parents of a folder in the trash '
          'as those of a folder at the root), the user does not see it, or '
          'it was moved.',
    );
  }

  /// Throws an [ArgumentError] unless [folderId] is a folder UUID.
  static void _checkFolderId(String folderId) {
    if (!_uuid.hasMatch(folderId)) {
      throw ArgumentError.value(folderId, 'folderId', 'is not a folder UUID');
    }
  }

  // -------------------------------------------------------------------------
  // The root's capabilities (#138)
  // -------------------------------------------------------------------------

  /// What the user may do at the root of Intradesk: the capabilities of the
  /// school's own platform (#138), where a folder's come with its entry
  /// ([getFolder]). [IntradeskFolderCapabilities.canAdd] says whether the
  /// user may add a folder at the root, and
  /// [IntradeskFolderCapabilities.canAddConfidentialFolder] whether a
  /// confidential one ([createFolder] checks both before it adds a folder at
  /// the root).
  ///
  /// The root has no entry in any listing, and Intradesk's JSON API has no
  /// request for these: its web client takes them from the configuration
  /// that the Intradesk page (`GET /intradesk`) carries in a script,
  /// `SMSC.vars.config.ownPlatform.capabilities`, and gives them to its root
  /// item. So this reads that page (one request, about 100 KB) and takes the
  /// same object ([parseRootCapabilities]). Seen live (2026-10-07, an
  /// administrator): `{"canManage": true, "canAlterConfidentialState":
  /// false, "canAdd": true, "canAddConfidentialFolder": false}`. A missing
  /// capability is `false`; `canAlterConfidentialState` is not kept.
  ///
  /// Throws a [SmartschoolDownloadError] when Smartschool answers the page
  /// with another status than `200`, and a [SmartschoolParsingError] when the
  /// page carries no such configuration.
  Future<IntradeskFolderCapabilities> getRootCapabilities() async {
    final response = await _client.getResponse('/intradesk');
    final status = response.statusCode ?? 0;
    if (status != 200) {
      throw SmartschoolDownloadError(
        'Smartschool answered the Intradesk page (/intradesk) with HTTP '
        '$status, so the capabilities of the root are not known.',
        status,
      );
    }
    return parseRootCapabilities(response.data ?? '');
  }

  /// Reads the capabilities of the root from the Intradesk page [html]
  /// (#138): `vars.config.ownPlatform.capabilities` of the first
  /// configuration the page hands its scripts (`JSON.parse('...')`) that
  /// carries it, as the web client reads them.
  ///
  /// Throws a [SmartschoolParsingError] when no configuration of the page
  /// carries them as an object.
  ///
  /// Exposed for testing.
  static IntradeskFolderCapabilities parseRootCapabilities(String html) {
    for (final match in _jsonParseCall.allMatches(html)) {
      final Object? config;
      try {
        config = jsonDecode(_unescapeJsString(match.group(1)!));
      } on FormatException {
        continue;
      }
      final capabilities = _at(config, const [
        'vars',
        'config',
        'ownPlatform',
        'capabilities',
      ]);
      if (capabilities is Map<String, dynamic>) {
        return IntradeskFolderCapabilities.fromJson(capabilities);
      }
    }
    throw const SmartschoolParsingError(
      'The Intradesk page carries no capabilities of the root '
      '(SMSC.vars.config.ownPlatform.capabilities in its configuration).',
    );
  }

  /// A configuration that a Smartschool page hands its scripts:
  /// `JSON.parse('...')`, with the JSON as a JavaScript string between
  /// single quotes.
  static final _jsonParseCall = RegExp(
    r"JSON\s*\.\s*parse\s*\(\s*'((?:[^'\\]|\\.)*)'\s*\)",
  );

  /// The value at [path] of the JSON [value], or `null`.
  static Object? _at(Object? value, List<String> path) {
    var at = value;
    for (final key in path) {
      if (at is! Map) return null;
      at = at[key];
    }
    return at;
  }

  /// The text of the JavaScript string literal whose content (between its
  /// quotes) is [literal]: its escapes (a `u` with four hex digits, an `x`
  /// with two, `\\`, `\'`, `\/`, `\n`, ...) undone, in one pass.
  static String _unescapeJsString(String literal) {
    final out = StringBuffer();
    for (var i = 0; i < literal.length; i++) {
      final char = literal[i];
      if (char != r'\' || i + 1 == literal.length) {
        out.write(char);
        continue;
      }
      final escaped = literal[++i];
      final hexDigits = switch (escaped) {
        'u' => 4,
        'x' => 2,
        _ => 0,
      };
      if (hexDigits > 0 && i + hexDigits < literal.length) {
        final code = int.tryParse(
          literal.substring(i + 1, i + 1 + hexDigits),
          radix: 16,
        );
        if (code != null) {
          out.writeCharCode(code);
          i += hexDigits;
          continue;
        }
      }
      switch (escaped) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case 'v':
          out.write('\v');
        case '\n':
          break; // A line continuation.
        default:
          out.write(escaped);
      }
    }
    return out.toString();
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
  /// `400`, seen live), so the service does not send it there (see below);
  /// the web client offers it inside a confidential folder (where it offers
  /// no ordinary folder) and at the root when the platform allows it
  /// ([IntradeskFolderCapabilities.canAddConfidentialFolder]). A confidential
  /// folder that Intradesk made was not seen live.
  ///
  /// At the root, `parentFolderId` is sent as `''`, as the web client sends
  /// it. That was not tried live (it would have added a folder outside the
  /// test folder); nor was a folder without `canAdd`
  /// ([IntradeskFolderCapabilities.canAdd]): the live account is an
  /// administrator.
  ///
  /// **The parent is read first (#138)**, and the folder is added only where
  /// the web client offers it: [getFolder] reads the parent's entry (two
  /// requests), and the folder needs its `canAdd`, and, for an ordinary
  /// folder, a parent that is not [IntradeskFolder.confidential], for a
  /// confidential one ([confidential]) a parent that is. At the root,
  /// [getRootCapabilities] reads the platform's capabilities (one request):
  /// an ordinary folder needs their `canAdd`, a confidential one their
  /// `canAddConfidentialFolder` (the web client's right-click menu offers it
  /// on that alone). Otherwise a [SmartschoolIntradeskAddRefusedError], with
  /// the [IntradeskAddRefusalReason]; a confidential folder in an ordinary
  /// one, which Intradesk answered with `400` before, is refused so too.
  ///
  /// The create is sent **once**, never again after logging in again: a
  /// second one would add a second folder (see the class doc).
  ///
  /// Throws an [ArgumentError], without sending anything, when [name] is
  /// empty or not allowed ([isAllowedName]), [color] is not one of
  /// [folderColors], or [parentFolderId] is neither `''` nor a UUID. A
  /// parent that Smartschool knows no folder for, or that is in the trash,
  /// is a [SmartschoolIntradeskFolderNotFoundError] (from the read before the
  /// create, so nothing was sent). See the class doc for the other errors.
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
    await _checkParentAllows(
      operation,
      confidential ? _Addition.confidentialFolder : _Addition.folder,
      parentFolderId: parentFolderId,
    );
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
  /// **The parent is read first (#138)** ([getFolder]: two requests): a
  /// folder without `canAdd` ([IntradeskFolderCapabilities.canAdd]), where
  /// the web client offers no weblink, is a
  /// [SmartschoolIntradeskAddRefusedError]
  /// ([IntradeskAddRefusalReason.cannotAdd]), before the create is sent. A
  /// confidential folder takes a weblink (the web client offers one there).
  ///
  /// Throws an [ArgumentError], without sending anything, when [name] is
  /// empty or not allowed ([isAllowedName]), [url] is not an address the web
  /// client takes, [icon] is empty, or [parentFolderId] is not a folder UUID:
  /// the web client offers no weblink at the root (`''`), and that was not
  /// tried live. A parent that Smartschool knows no folder for, or that is in
  /// the trash, is a [SmartschoolIntradeskFolderNotFoundError] (from the read
  /// before the create, so nothing was sent). See the class doc for the other
  /// errors.
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
    await _checkParentAllows(
      operation,
      _Addition.weblink,
      parentFolderId: parentFolderId,
    );
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
  /// **The parent is read first (#138)**, before step 1 ([getFolder]: two
  /// requests): a folder without `canAdd`
  /// ([IntradeskFolderCapabilities.canAdd]), where the web client offers no
  /// upload, is a [SmartschoolIntradeskAddRefusedError]
  /// ([IntradeskAddRefusalReason.cannotAdd]), and no file is uploaded. A
  /// confidential folder takes files (the web client offers an upload there).
  ///
  /// Throws an [ArgumentError], without sending anything, when [filePaths]
  /// is empty, names a file that does not exist, a file whose name is not
  /// allowed ([isAllowedName], which Smartschool refuses at step 2 with HTTP
  /// `400`), or two files with the same name; or when [parentFolderId] is
  /// not a folder UUID: the web client offers no upload at the root (`''`),
  /// and that was not tried live. A failure of step 1 or 2 is a
  /// [SmartschoolAttachmentUploadError] (nothing was added); a parent that
  /// Smartschool knows no folder for, or that is in the trash, a
  /// [SmartschoolIntradeskFolderNotFoundError] (from the read before step 1,
  /// so nothing was sent). See the class doc for the other errors.
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
    await _checkParentAllows(
      operation,
      _Addition.file,
      parentFolderId: parentFolderId,
    );

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
  /// with `204` as well (seen live, 2026-10-07, for a folder, a weblink and a
  /// file), so the move is retried once after logging in again, like a read.
  ///
  /// Intradesk answers `404` when it has no folder with [folderId] (#133,
  /// seen live 2026-10-07): a made-up ID, or the ID of a file or a weblink
  /// (also one in the trash). It moves nothing then, also not the file or
  /// weblink with that ID. That is a [SmartschoolIntradeskItemNotFoundError]
  /// (with [IntradeskItemKind.folder]), so a caller can tell "there is no
  /// such folder" apart from a move that went through (`204`, also for a
  /// folder in the trash already) and from a move that may or may not have
  /// gone through.
  ///
  /// Throws an [ArgumentError], without sending anything, when [folderId] is
  /// not a UUID. Any other refusal by Intradesk (HTTP `400` to `499`) is a
  /// plain [SmartschoolIntradeskWriteRefusedError], the class that
  /// [SmartschoolIntradeskItemNotFoundError] extends; another answer than
  /// `2xx`, a [SmartschoolIntradeskSaveUnconfirmedError]. The answer for an
  /// item without the rights to it (`capabilities.canManage` false) was not
  /// seen live (#139).
  Future<void> trashFolder(String folderId) =>
      _trash('trashFolder', IntradeskItemKind.folder, folderId, 'folderId');

  /// Moves the weblink [weblinkId] to Intradesk's trash (#128), with
  /// `POST /intradesk/api/v1/{platformId}/weblinks/{weblinkId}/trash`; see
  /// [trashFolder].
  ///
  /// A [SmartschoolIntradeskItemNotFoundError] (with
  /// [IntradeskItemKind.weblink]) when Intradesk has no weblink with
  /// [weblinkId]: a made-up ID, or the ID of a folder or a file (#133).
  Future<void> trashWeblink(String weblinkId) =>
      _trash('trashWeblink', IntradeskItemKind.weblink, weblinkId, 'weblinkId');

  /// Moves the file [fileId] to Intradesk's trash (#128), with
  /// `POST /intradesk/api/v1/{platformId}/files/{fileId}/trash`; see
  /// [trashFolder].
  ///
  /// A [SmartschoolIntradeskItemNotFoundError] (with
  /// [IntradeskItemKind.file]) when Intradesk has no file with [fileId]: a
  /// made-up ID, or the ID of a folder or a weblink (#133).
  Future<void> trashFile(String fileId) =>
      _trash('trashFile', IntradeskItemKind.file, fileId, 'fileId');

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

  /// Reads the folder [parentFolderId] that [operation] adds [addition] to
  /// (#138), and throws a [SmartschoolIntradeskAddRefusedError] unless
  /// Intradesk's web client offers that addition there (see
  /// [IntradeskAddRefusalReason]); nothing is sent then.
  ///
  /// A folder is read with [getFolder] (its parents and the listing of the
  /// folder above it: two requests), the root with [getRootCapabilities]
  /// (the Intradesk page: one request). A folder that the read does not find
  /// is a [SmartschoolIntradeskFolderNotFoundError] (status `404` for an ID
  /// that is not a folder, `200` for a folder in the trash or one the user
  /// does not see), with a message that names [operation] and says that
  /// nothing was sent. Any other failure of the read is thrown as the read
  /// throws it: nothing was sent either.
  Future<void> _checkParentAllows(
    String operation,
    _Addition addition, {
    required String parentFolderId,
  }) async {
    final IntradeskFolder? parent;
    final IntradeskFolderCapabilities capabilities;
    if (parentFolderId.isEmpty) {
      parent = null;
      capabilities = await getRootCapabilities();
    } else {
      try {
        parent = await getFolder(parentFolderId);
      } on SmartschoolIntradeskFolderNotFoundError catch (e, stackTrace) {
        Error.throwWithStackTrace(
          SmartschoolIntradeskFolderNotFoundError(
            parentFolderId,
            statusCode: e.statusCode,
            message:
                '$operation: the folder to add to was not found. '
                '${e.message} Nothing was sent.',
          ),
          stackTrace,
        );
      }
      capabilities = parent.capabilities;
    }

    final where = parent == null
        ? 'the root'
        : 'folder $parentFolderId ("${parent.name}")';
    final (IntradeskAddRefusalReason, String)? refusal;
    if (parent == null) {
      refusal = switch (addition) {
        _Addition.confidentialFolder
            when !capabilities.canAddConfidentialFolder =>
          (
            IntradeskAddRefusalReason.cannotAddConfidentialFolder,
            'the platform allows the user no confidential folder at the root '
                '(its canAddConfidentialFolder is false), and Intradesk\'s web '
                'client offers none there',
          ),
        _Addition.confidentialFolder => null,
        _ when !capabilities.canAdd => (
          IntradeskAddRefusalReason.cannotAdd,
          'the user may not add to the root (the platform\'s canAdd is '
              'false), and Intradesk\'s web client offers no folder there',
        ),
        _ => null,
      };
    } else if (!capabilities.canAdd) {
      refusal = (
        IntradeskAddRefusalReason.cannotAdd,
        'the user may not add to $where (its canAdd is false), and '
            'Intradesk\'s web client offers no folder, weblink or file there',
      );
    } else {
      refusal = switch (addition) {
        _Addition.confidentialFolder when !parent.confidential => (
          IntradeskAddRefusalReason.ordinaryParent,
          '$where is an ordinary folder, which holds no confidential folder: '
              'Intradesk refuses one there (HTTP 400), and its web client '
              'offers none',
        ),
        _Addition.folder when parent.confidential => (
          IntradeskAddRefusalReason.confidentialParent,
          '$where is a confidential folder, where Intradesk\'s web client '
              'offers a confidential folder only, not an ordinary one (pass '
              'confidential: true)',
        ),
        _ => null,
      };
    }
    if (refusal == null) return;
    final (reason, why) = refusal;
    throw SmartschoolIntradeskAddRefusedError(
      '$operation: $why. Nothing was sent.',
      reason: reason,
      parentFolderId: parentFolderId,
      parent: parent,
      capabilities: capabilities,
    );
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

  /// Moves the item [id] of the [kind] to Intradesk's trash; see
  /// [trashFolder].
  Future<void> _trash(
    String operation,
    IntradeskItemKind kind,
    String id,
    String argument,
  ) async {
    if (!_uuid.hasMatch(id)) {
      throw ArgumentError.value(id, argument, 'Must be a UUID.');
    }
    final platformId = await _client.platformId;
    final item = kind.name;
    final change = 'the move of $item $id to the trash';
    const unconfirmed =
        'It may or may not be in the trash: list its folder '
        '(getFolderListing) before trying again; moving it to the trash '
        'again is harmless.';
    final response = await _send(
      operation,
      path: '/intradesk/api/v1/$platformId/${kind.pathSegment}/$id/trash',
      body: const <String, Object?>{},
      retryAfterLogin: true,
      change: change,
      unconfirmed: unconfirmed,
    );
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) return;
    if (status == 404) {
      final others = [
        for (final other in IntradeskItemKind.values)
          if (other != kind) other.name,
      ].join(' or a ');
      throw SmartschoolIntradeskItemNotFoundError(
        '$operation: Intradesk has no $item with ID "$id" (HTTP 404): the ID '
        'is unknown, or it is the ID of a $others. Nothing was moved to the '
        'trash.',
        kind: kind,
        id: id,
        violations: parseViolations(response.data ?? ''),
      );
    }
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

/// What a create adds to a folder, for the check of the folder (#138).
enum _Addition { folder, confidentialFolder, weblink, file }
