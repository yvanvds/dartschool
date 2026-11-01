// The client of the live suite (#57).
//
// The live suite logs in with the gitignored credentials.yml in the package
// root, and keeps its session cookies between runs in a persistent,
// gitignored folder of its own, `.dart_tool/live_cache/<username>`: not the
// user's real cache (`~/.cache/smartschool`, which an app on the same machine
// may use), and not a temporary folder, which would make every run log in.
// So a run normally does not log in at all, and it logs in at most once
// (LiveWireGuard refuses a second login).
//
// One live run at a time works in that session: a run takes the lock of its
// folder first (live_lock.dart, #62).
//
// Only the live suite (test/live/) may use that folder: the offline tests
// give each client a temporary one (test/support/temp_cache_dir.dart, #49),
// and cache_dir_guard_test.dart fails on any other file that names it.
import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:path/path.dart' as p;

import 'live_lock.dart';

/// The environment variable that names another credentials file for the live
/// suite (#168): a second account, such as a pupil's, to run the same live
/// files as.
const liveCredentialsVariable = 'DARTSCHOOL_LIVE_CREDENTIALS';

/// The credentials file of the live suite, `credentials.yml` in the package
/// root, or `null` when there is none: the live suite then skips.
///
/// Only that file counts: `PathCredentials` would also look in the parent
/// folders and the home folder.
///
/// With [liveCredentialsVariable] set, the file it names instead (a path
/// relative to the package root, or absolute), for a run as another account:
///
///   DARTSCHOOL_LIVE_CREDENTIALS=student-credentials.yml \
///     dart test -P live test/live/lvs_live_test.dart
///
/// That file must exist (a run that names one never skips quietly), and,
/// inside the package root, its name must end in `credentials.yml`, the
/// pattern `.gitignore` keeps out of git. Each account keeps a session folder
/// of its own ([liveCacheDir]), so runs as two accounts do not share cookies.
File? liveCredentialsFile() => liveCredentialsFileFor(
  Platform.environment[liveCredentialsVariable],
  root: Directory.current.path,
);

/// [liveCredentialsFile] for the value [named] of [liveCredentialsVariable]
/// and the package root [root]: tested offline.
File? liveCredentialsFileFor(String? named, {required String root}) {
  final name = named?.trim() ?? '';
  if (name.isEmpty) {
    final file = File(p.join(root, 'credentials.yml'));
    return file.existsSync() ? file : null;
  }
  final path = p.normalize(p.absolute(root, name));
  if (p.isWithin(p.normalize(p.absolute(root)), path) &&
      !p.basename(path).endsWith('credentials.yml')) {
    throw StateError(
      '$liveCredentialsVariable names a file in the package root whose name '
      'does not end in "credentials.yml": .gitignore would not keep it out '
      'of git.',
    );
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      '$liveCredentialsVariable names a file that does not exist.',
    );
  }
  return file;
}

/// The folder the live client of [username] keeps its session cookies in
/// between runs.
String liveCacheDir(String username) =>
    p.join(Directory.current.path, '.dart_tool', 'live_cache', username);

/// A client for [credentials] that carries on in the session of the last
/// live run, if it is still valid.
Future<SmartschoolClient> createLiveClient(Credentials credentials) =>
    SmartschoolClient.create(
      credentials,
      cacheDir: liveCacheDir(credentials.username),
    );

/// Takes the lock of the session of [credentials] for the run tagged
/// [runTag], before its client loads that session (#62), or throws a
/// [LiveLockHeld] when another live run holds it.
Future<LiveLock> lockLiveSession(Credentials credentials, String runTag) =>
    LiveLock.acquire(liveCacheDir(credentials.username), runTag: runTag);
