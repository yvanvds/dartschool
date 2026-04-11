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
  final bool canAdd;
  final bool canSeeHistory;
  final bool canSeeViewHistory;

  const IntradeskFolderCapabilities({
    required this.canManage,
    required this.canAdd,
    required this.canSeeHistory,
    required this.canSeeViewHistory,
  });

  factory IntradeskFolderCapabilities.fromJson(Map<String, dynamic> json) =>
      IntradeskFolderCapabilities(
        canManage: _bool(json, 'canManage'),
        canAdd: _bool(json, 'canAdd'),
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
          : IntradeskFileOwner(
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
  final bool hasChildren;

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
          : IntradeskPlatform(id: 0, name: ''),
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
          : IntradeskFolderCapabilities(
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
          : IntradeskPlatform(id: 0, name: ''),
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
          : IntradeskFileCapabilities(
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

/// The combined result of a directory-listing API call.
///
/// Returned by both the root listing (`forTreeOnlyFolders`) and per-folder
/// listing (`forTreeOnlyFolders/{folderId}`) endpoints.
class IntradeskListing {
  final List<IntradeskFolder> folders;
  final List<IntradeskFile> files;

  /// Raw weblink entries.  The API returns an array that is always empty in
  /// current observation; typed as dynamic maps to avoid breakage if fields
  /// are added later.
  final List<Map<String, dynamic>> weblinks;

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
          ? weblinksRaw.whereType<Map<String, dynamic>>().toList()
          : const [],
    );
  }

  @override
  String toString() =>
      'IntradeskListing(folders: ${folders.length}, '
      'files: ${files.length}, weblinks: ${weblinks.length})';
}
