import '../exceptions.dart';

// ---------------------------------------------------------------------------
// Private helpers (mirror the pattern from message_models.dart)
// ---------------------------------------------------------------------------

String _str(Map<String, dynamic> json, String key) =>
    (json[key] ?? '').toString();

int _int(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  final n = int.tryParse(v?.toString() ?? '');
  if (n != null) return n;
  throw SmartschoolParsingError("Cannot parse int for key '$key': $v");
}

bool _bool(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}

DateTime _dateTime(Map<String, dynamic> json, String key) {
  final v = _str(json, key);
  if (v.isEmpty) {
    throw SmartschoolParsingError("Missing datetime for key '$key'");
  }
  try {
    return DateTime.parse(v);
  } catch (_) {
    throw SmartschoolParsingError("Cannot parse datetime for key '$key': '$v'");
  }
}

T? _optionalOf<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>) factory,
) {
  final v = json[key];
  if (v == null) return null;
  if (v is Map<String, dynamic>) return factory(v);
  return null;
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// Platform reference embedded in folder and file objects.
class IntradeskPlatform {
  final int id;
  final String name;

  const IntradeskPlatform({required this.id, required this.name});

  factory IntradeskPlatform.fromJson(Map<String, dynamic> json) =>
      IntradeskPlatform(id: _int(json, 'id'), name: _str(json, 'name'));

  @override
  String toString() => 'IntradeskPlatform(id: $id, name: "$name")';
}

/// Capabilities attached to a folder.
class IntradeskFolderCapabilities {
  final bool canManage;

  /// Whether the user may add to the folder: an ordinary folder, a weblink
  /// or a file, in an ordinary folder; a confidential folder, in a
  /// confidential one (`IntradeskService.createFolder`, `createWeblink`,
  /// `uploadFiles`, #128). The web client offers none of them without it.
  /// The writes do not check it: read a folder's own with
  /// `IntradeskService.getFolder` (#132).
  final bool canAdd;

  /// Whether the user may add a confidential folder here
  /// (`IntradeskService.createFolder(confidential: true)`, #128): Smartschool's
  /// `canAddConfidentialFolder`, `false` when the answer does not carry it.
  ///
  /// The web client's folder model has it (default `false`), and offers a
  /// confidential folder at the root only when it is set; the platform
  /// capabilities in the Intradesk page's configuration carry it. The folder
  /// listings do not: none of the folders listed live (2026-10-05) carried
  /// it, so it is `false` for every folder of a listing. Inside a
  /// confidential folder, the web client offers a confidential folder on
  /// [canAdd] instead.
  final bool canAddConfidentialFolder;

  final bool canSeeHistory;
  final bool canSeeViewHistory;

  const IntradeskFolderCapabilities({
    required this.canManage,
    required this.canAdd,
    required this.canSeeHistory,
    required this.canSeeViewHistory,
    this.canAddConfidentialFolder = false,
  });

  factory IntradeskFolderCapabilities.fromJson(Map<String, dynamic> json) =>
      IntradeskFolderCapabilities(
        canManage: _bool(json, 'canManage'),
        canAdd: _bool(json, 'canAdd'),
        canAddConfidentialFolder: _bool(json, 'canAddConfidentialFolder'),
        canSeeHistory: _bool(json, 'canSeeHistory'),
        canSeeViewHistory: _bool(json, 'canSeeViewHistory'),
      );

  @override
  String toString() =>
      'IntradeskFolderCapabilities(canManage: $canManage, canAdd: $canAdd)';
}

/// Capabilities attached to a file.
class IntradeskFileCapabilities {
  final bool canManage;
  final bool canMove;
  final bool canHandleRevisions;
  final bool canSeeHistory;
  final bool canSeeViewHistory;

  const IntradeskFileCapabilities({
    required this.canManage,
    required this.canMove,
    required this.canHandleRevisions,
    required this.canSeeHistory,
    required this.canSeeViewHistory,
  });

  factory IntradeskFileCapabilities.fromJson(Map<String, dynamic> json) =>
      IntradeskFileCapabilities(
        canManage: _bool(json, 'canManage'),
        canMove: _bool(json, 'canMove'),
        canHandleRevisions: _bool(json, 'canHandleRevisions'),
        canSeeHistory: _bool(json, 'canSeeHistory'),
        canSeeViewHistory: _bool(json, 'canSeeViewHistory'),
      );
}

/// The owner of a file revision.
class IntradeskFileOwner {
  final String userIdentifier;
  final String name;
  final String nameReverse;
  final String userPictureUrl;

  const IntradeskFileOwner({
    required this.userIdentifier,
    required this.name,
    required this.nameReverse,
    required this.userPictureUrl,
  });

  factory IntradeskFileOwner.fromJson(Map<String, dynamic> json) =>
      IntradeskFileOwner(
        userIdentifier: _str(json, 'userIdentifier'),
        name: _str(json, 'name'),
        nameReverse: _str(json, 'nameReverse'),
        userPictureUrl: _str(json, 'userPictureUrl'),
      );

  @override
  String toString() => 'IntradeskFileOwner(name: "$name")';
}

/// Current revision metadata for a file.
class IntradeskFileRevision {
  final String id;
  final String fileId;
  final int fileSize;
  final String label;
  final DateTime dateCreated;
  final IntradeskFileOwner owner;

  const IntradeskFileRevision({
    required this.id,
    required this.fileId,
    required this.fileSize,
    required this.label,
    required this.dateCreated,
    required this.owner,
  });

  factory IntradeskFileRevision.fromJson(Map<String, dynamic> json) {
    final ownerJson = json['owner'];
    return IntradeskFileRevision(
      id: _str(json, 'id'),
      fileId: _str(json, 'fileId'),
      fileSize: _int(json, 'fileSize'),
      label: _str(json, 'label'),
      dateCreated: _dateTime(json, 'dateCreated'),
      owner: ownerJson is Map<String, dynamic>
          ? IntradeskFileOwner.fromJson(ownerJson)
          : const IntradeskFileOwner(
              userIdentifier: '',
              name: '',
              nameReverse: '',
              userPictureUrl: '',
            ),
    );
  }
}

/// A folder in the Intradesk document repository.
class IntradeskFolder {
  final String id;
  final IntradeskPlatform platform;
  final String name;
  final String color;
  final String state;
  final bool visible;
  final bool confidential;
  final bool officeTemplateFolder;

  /// Empty string at root level; parent folder UUID otherwise.
  final String parentFolderId;

  final DateTime dateStateChanged;
  final DateTime dateCreated;
  final DateTime dateChanged;
  final bool isFavourite;
  final bool inConfidentialFolder;
  final IntradeskFolderCapabilities capabilities;

  /// Whether the folder holds subfolders: Smartschool's `hasChildren`, which
  /// counts folders only, not files or weblinks (#37).
  ///
  /// The listings come from Smartschool's folder tree (`forTreeOnlyFolders`),
  /// whose web client uses `hasChildren` to tell whether a folder can be
  /// expanded in that tree. A folder with `hasChildren` false can still hold
  /// files and weblinks: do not skip it, list it with
  /// `IntradeskService.getFolderListing` to find them.
  ///
  /// [hasSubfolders] is the same value, under a name that says what it
  /// counts.
  final bool hasChildren;

  /// Whether the folder holds subfolders (#37); the same value as
  /// [hasChildren].
  ///
  /// It says nothing about files and weblinks: a folder without subfolders
  /// can still hold them, so list it with `IntradeskService.getFolderListing`
  /// to find them.
  bool get hasSubfolders => hasChildren;

  const IntradeskFolder({
    required this.id,
    required this.platform,
    required this.name,
    required this.color,
    required this.state,
    required this.visible,
    required this.confidential,
    required this.officeTemplateFolder,
    required this.parentFolderId,
    required this.dateStateChanged,
    required this.dateCreated,
    required this.dateChanged,
    required this.isFavourite,
    required this.inConfidentialFolder,
    required this.capabilities,
    required this.hasChildren,
  });

  factory IntradeskFolder.fromJson(Map<String, dynamic> json) {
    final capJson = json['capabilities'];
    final platJson = json['platform'];
    return IntradeskFolder(
      id: _str(json, 'id'),
      platform: platJson is Map<String, dynamic>
          ? IntradeskPlatform.fromJson(platJson)
          : const IntradeskPlatform(id: 0, name: ''),
      name: _str(json, 'name'),
      color: _str(json, 'color'),
      state: _str(json, 'state'),
      visible: _bool(json, 'visible'),
      confidential: _bool(json, 'confidential'),
      officeTemplateFolder: _bool(json, 'officeTemplateFolder'),
      parentFolderId: _str(json, 'parentFolderId'),
      dateStateChanged: _dateTime(json, 'dateStateChanged'),
      dateCreated: _dateTime(json, 'dateCreated'),
      dateChanged: _dateTime(json, 'dateChanged'),
      isFavourite: _bool(json, 'isFavourite'),
      inConfidentialFolder: _bool(json, 'inConfidentialFolder'),
      capabilities: capJson is Map<String, dynamic>
          ? IntradeskFolderCapabilities.fromJson(capJson)
          : const IntradeskFolderCapabilities(
              canManage: false,
              canAdd: false,
              canSeeHistory: false,
              canSeeViewHistory: false,
            ),
      hasChildren: _bool(json, 'hasChildren'),
    );
  }

  @override
  String toString() => 'IntradeskFolder(id: "$id", name: "$name")';
}

/// A file in the Intradesk document repository.
class IntradeskFile {
  final String id;
  final IntradeskPlatform platform;
  final String name;
  final String state;

  /// Empty string at root level; parent folder UUID otherwise.
  final String parentFolderId;

  final DateTime dateCreated;
  final DateTime dateStateChanged;
  final DateTime dateChanged;

  /// Current revision metadata, if present in the API response.
  final IntradeskFileRevision? currentRevision;

  final bool isFavourite;
  final bool confidential;
  final String ownerId;
  final IntradeskFileCapabilities capabilities;

  const IntradeskFile({
    required this.id,
    required this.platform,
    required this.name,
    required this.state,
    required this.parentFolderId,
    required this.dateCreated,
    required this.dateStateChanged,
    required this.dateChanged,
    this.currentRevision,
    required this.isFavourite,
    required this.confidential,
    required this.ownerId,
    required this.capabilities,
  });

  factory IntradeskFile.fromJson(Map<String, dynamic> json) {
    final platJson = json['platform'];
    final capJson = json['capabilities'];
    return IntradeskFile(
      id: _str(json, 'id'),
      platform: platJson is Map<String, dynamic>
          ? IntradeskPlatform.fromJson(platJson)
          : const IntradeskPlatform(id: 0, name: ''),
      name: _str(json, 'name'),
      state: _str(json, 'state'),
      parentFolderId: _str(json, 'parentFolderId'),
      dateCreated: _dateTime(json, 'dateCreated'),
      dateStateChanged: _dateTime(json, 'dateStateChanged'),
      dateChanged: _dateTime(json, 'dateChanged'),
      currentRevision: _optionalOf(
        json,
        'currentRevision',
        IntradeskFileRevision.fromJson,
      ),
      isFavourite: _bool(json, 'isFavourite'),
      confidential: _bool(json, 'confidential'),
      ownerId: _str(json, 'ownerId'),
      capabilities: capJson is Map<String, dynamic>
          ? IntradeskFileCapabilities.fromJson(capJson)
          : const IntradeskFileCapabilities(
              canManage: false,
              canMove: false,
              canHandleRevisions: false,
              canSeeHistory: false,
              canSeeViewHistory: false,
            ),
    );
  }

  @override
  String toString() => 'IntradeskFile(id: "$id", name: "$name")';
}

/// Capabilities attached to a weblink.
class IntradeskWeblinkCapabilities {
  final bool canManage;
  final bool canMove;
  final bool canSeeHistory;
  final bool canSeeViewHistory;

  const IntradeskWeblinkCapabilities({
    required this.canManage,
    required this.canMove,
    required this.canSeeHistory,
    required this.canSeeViewHistory,
  });

  factory IntradeskWeblinkCapabilities.fromJson(Map<String, dynamic> json) =>
      IntradeskWeblinkCapabilities(
        canManage: _bool(json, 'canManage'),
        canMove: _bool(json, 'canMove'),
        canSeeHistory: _bool(json, 'canSeeHistory'),
        canSeeViewHistory: _bool(json, 'canSeeViewHistory'),
      );
}

/// A weblink in the Intradesk document repository: a named link to a web
/// page, kept in a folder next to its files (#37).
class IntradeskWeblink {
  final String id;
  final IntradeskPlatform platform;
  final String name;

  /// The address of the web page the weblink opens.
  final String url;

  /// The name of the icon Smartschool shows for the weblink, such as
  /// `folder_orange`.
  final String icon;

  final String state;

  /// Empty string at root level; parent folder UUID otherwise.
  final String parentFolderId;

  final DateTime dateCreated;
  final DateTime dateStateChanged;
  final DateTime dateChanged;
  final bool isFavourite;
  final bool confidential;
  final String ownerId;
  final IntradeskWeblinkCapabilities capabilities;

  const IntradeskWeblink({
    required this.id,
    required this.platform,
    required this.name,
    required this.url,
    required this.icon,
    required this.state,
    required this.parentFolderId,
    required this.dateCreated,
    required this.dateStateChanged,
    required this.dateChanged,
    required this.isFavourite,
    required this.confidential,
    required this.ownerId,
    required this.capabilities,
  });

  factory IntradeskWeblink.fromJson(Map<String, dynamic> json) {
    final platJson = json['platform'];
    final capJson = json['capabilities'];
    return IntradeskWeblink(
      id: _str(json, 'id'),
      platform: platJson is Map<String, dynamic>
          ? IntradeskPlatform.fromJson(platJson)
          : const IntradeskPlatform(id: 0, name: ''),
      name: _str(json, 'name'),
      url: _str(json, 'url'),
      icon: _str(json, 'icon'),
      state: _str(json, 'state'),
      parentFolderId: _str(json, 'parentFolderId'),
      dateCreated: _dateTime(json, 'dateCreated'),
      dateStateChanged: _dateTime(json, 'dateStateChanged'),
      dateChanged: _dateTime(json, 'dateChanged'),
      isFavourite: _bool(json, 'isFavourite'),
      confidential: _bool(json, 'confidential'),
      ownerId: _str(json, 'ownerId'),
      capabilities: capJson is Map<String, dynamic>
          ? IntradeskWeblinkCapabilities.fromJson(capJson)
          : const IntradeskWeblinkCapabilities(
              canManage: false,
              canMove: false,
              canSeeHistory: false,
              canSeeViewHistory: false,
            ),
    );
  }

  @override
  String toString() => 'IntradeskWeblink(id: "$id", name: "$name")';
}

/// The combined result of a directory-listing API call.
///
/// Returned by both the root listing (`forTreeOnlyFolders`) and per-folder
/// listing (`forTreeOnlyFolders/{folderId}`) endpoints.
class IntradeskListing {
  final List<IntradeskFolder> folders;
  final List<IntradeskFile> files;

  /// The weblinks in the listed folder (#37).
  final List<IntradeskWeblink> weblinks;

  const IntradeskListing({
    required this.folders,
    required this.files,
    required this.weblinks,
  });

  factory IntradeskListing.fromJson(Map<String, dynamic> json) {
    final foldersRaw = json['folders'];
    final filesRaw = json['files'];
    final weblinksRaw = json['weblinks'];

    return IntradeskListing(
      folders: foldersRaw is List
          ? foldersRaw
                .whereType<Map<String, dynamic>>()
                .map(IntradeskFolder.fromJson)
                .toList()
          : const [],
      files: filesRaw is List
          ? filesRaw
                .whereType<Map<String, dynamic>>()
                .map(IntradeskFile.fromJson)
                .toList()
          : const [],
      weblinks: weblinksRaw is List
          ? weblinksRaw
                .whereType<Map<String, dynamic>>()
                .map(IntradeskWeblink.fromJson)
                .toList()
          : const [],
    );
  }

  @override
  String toString() =>
      'IntradeskListing(folders: ${folders.length}, '
      'files: ${files.length}, weblinks: ${weblinks.length})';
}

/// A file that Intradesk did not take in an upload (#128): an entry of the
/// `exceptions` of its answer to `files/upload`.
///
/// Not seen live: Intradesk answered every upload tried on 2026-10-05 with
/// an empty list of exceptions. This follows the web client
/// (`handleExceptionArray` of `@smartschool/errorhandler`), which reads the
/// exceptions as an object with an entry per failure, each with a
/// `violations` object whose first value is the message it shows.
class IntradeskUploadFailure {
  /// The key Intradesk gives the failure, going by the web client one per
  /// file; for an entry of a list, its position in it.
  final String key;

  /// Intradesk's reasons, in its own words and order (the values of the
  /// entry's `violations`); empty when it gave none.
  final List<String> violations;

  const IntradeskUploadFailure({required this.key, required this.violations});

  /// The first of [violations], the one the web client shows; empty when
  /// there is none.
  String get message => violations.isEmpty ? '' : violations.first;

  /// Reads the entry [key] of the `exceptions` of an upload answer.
  factory IntradeskUploadFailure.fromJson(String key, Object? json) {
    final raw = json is Map ? json['violations'] : json;
    final List<String> violations;
    if (raw is Map) {
      violations = [for (final v in raw.values) '$v'];
    } else if (raw is List) {
      violations = [for (final v in raw) '$v'];
    } else if (raw is String) {
      violations = [raw];
    } else {
      violations = const [];
    }
    return IntradeskUploadFailure(
      key: key,
      violations: List.unmodifiable(violations),
    );
  }

  @override
  String toString() => 'IntradeskUploadFailure(key: "$key", "$message")';
}

/// What Intradesk made of an upload (`IntradeskService.uploadFiles`, #128):
/// its answer to `files/upload`.
class IntradeskUploadResult {
  /// The files Intradesk added, as it answered them: the `files` of its
  /// answer, an object keyed by file ID (not a list), in its order.
  ///
  /// A file's name is the name it was uploaded under, unless the folder held
  /// a file of that name already: Intradesk then renames the new one (seen
  /// live, 2026-10-05: `dartschool-test.txt` became `dartschool-test
  /// (1).txt`), so tell the files by their [IntradeskFile.id], not by name.
  final List<IntradeskFile> files;

  /// The files Intradesk did not take, as its answer lists them in
  /// `exceptions`; empty when it took all of them (an empty list, as seen
  /// live).
  final List<IntradeskUploadFailure> failures;

  const IntradeskUploadResult({required this.files, required this.failures});

  /// Reads Intradesk's answer to `files/upload`:
  /// `{"files": {"<fileId>": {...}}, "exceptions": []}`.
  ///
  /// Throws a [SmartschoolParsingError] when `files` is missing or neither
  /// an object nor a list, or a file in it lacks a field it must have (such
  /// as its dates).
  factory IntradeskUploadResult.fromJson(Map<String, dynamic> json) {
    final filesRaw = json['files'];
    final Iterable<Object?> fileEntries;
    if (filesRaw is Map) {
      fileEntries = filesRaw.values;
    } else if (filesRaw is List) {
      fileEntries = filesRaw;
    } else {
      throw SmartschoolParsingError(
        'An Intradesk upload answer without its files: '
        '${filesRaw == null ? 'no "files"' : '"files" is a ${filesRaw.runtimeType}'}',
      );
    }
    final files = <IntradeskFile>[];
    for (final entry in fileEntries) {
      if (entry is! Map<String, dynamic>) {
        throw SmartschoolParsingError(
          'An Intradesk upload answer with a file that is a '
          '${entry.runtimeType}, not an object',
        );
      }
      files.add(IntradeskFile.fromJson(entry));
    }

    final exceptionsRaw = json['exceptions'];
    final failures = <IntradeskUploadFailure>[
      if (exceptionsRaw is Map)
        for (final entry in exceptionsRaw.entries)
          IntradeskUploadFailure.fromJson('${entry.key}', entry.value)
      else if (exceptionsRaw is List)
        for (var i = 0; i < exceptionsRaw.length; i++)
          IntradeskUploadFailure.fromJson('$i', exceptionsRaw[i]),
    ];
    return IntradeskUploadResult(
      files: List.unmodifiable(files),
      failures: List.unmodifiable(failures),
    );
  }

  @override
  String toString() =>
      'IntradeskUploadResult(files: ${files.length}, '
      'failures: ${failures.length})';
}
