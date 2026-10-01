// The lock of the live suite (#62): one live run at a time in a session.
//
// The live suite keeps its Smartschool session in a folder of its own
// (live_client.dart), and its cleanup assumes that it is the only run in
// that session: it finds the run's messages by their subjects and checks
// each right before it moves it, and Smartschool keeps state of its own in
// the session (such as a paging position per box, #15). Two live runs at
// once, in two terminals, or two live files of one `dart test` run, which
// package:test runs side by side unless told otherwise, would share that
// session.
//
// So a live run takes this lock before its client loads the session, and
// gives it back at the end:
// - the lock is a file, `.lock` in the session's folder, created with
//   `File.create(exclusive: true)`: of two runs that try at once, exactly one
//   creates it (`CREATE_NEW` on Windows, `O_EXCL` elsewhere), across
//   processes and across the isolates of one process alike;
// - it names the run that holds it: its tag, the process (PID) and machine
//   (host name) it runs in, and when it started;
// - a run that finds it refuses to start, unless the lock is stale.
//
// Stale is decided on positive evidence only: the lock was written on this
// machine, and the list of this machine's processes (`tasklist` on Windows,
// `ps` elsewhere) was read, lists this process, and does not list the
// lock's. That is a run that was killed, so that its tearDownAll never gave
// the lock back. Anything else counts as held: a lock that cannot be read
// (also one that its run is still writing), one of another machine, one of
// this process (another live file of the same run), or a process list that
// could not be read. When the system gave the PID of a killed run to another
// process since, its lock looks held: the run refuses, which is the safe
// side, and says to delete the lock by hand.
//
// Two runs may find the same stale lock at once. Each first creates a marker
// next to it, named after it, with `File.create(exclusive: true)`; only the
// run that creates it deletes the lock, after reading it again and finding
// it unchanged (a lock names a run that never comes back, so it does not
// come back either), and then deletes the marker. Then the runs try to
// create the lock again, and one of them does. A marker that a run stopped
// halfway left behind makes the next runs give up on that stale lock, and
// say to delete both.
//
// It is a file rather than an OS lock (`RandomAccessFile.lock`): an OS lock
// is given back by the system when its process dies, but on Linux and macOS
// it is held per process, so two live files of one run (isolates of one
// process) would both get it.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The run that holds, or held, a [LiveLock], as its lock file names it.
class LiveLockHolder {
  LiveLockHolder({
    required this.runTag,
    required this.processId,
    required this.host,
    required this.started,
  });

  /// This run: the current process, on this machine, from now.
  LiveLockHolder.current(String runTag)
    : this(
        runTag: runTag,
        processId: pid,
        host: Platform.localHostname,
        started: DateTime.now().toUtc(),
      );

  /// The holder that [content], the content of a lock file, names, or `null`
  /// when it names none (such as an empty file, which a run is still
  /// writing).
  static LiveLockHolder? parse(String content) {
    try {
      final json = jsonDecode(content);
      if (json is! Map) return null;
      final runTag = json['runTag'];
      final processId = json['pid'];
      final host = json['host'];
      final started = DateTime.tryParse('${json['started']}');
      if (runTag is! String ||
          processId is! int ||
          host is! String ||
          started == null) {
        return null;
      }
      return LiveLockHolder(
        runTag: runTag,
        processId: processId,
        host: host,
        started: started,
      );
    } on FormatException {
      return null;
    }
  }

  final String runTag;
  final int processId;
  final String host;
  final DateTime started;

  /// The content of a lock file that names this holder.
  String encode() => jsonEncode({
    'runTag': runTag,
    'pid': processId,
    'host': host,
    'started': started.toUtc().toIso8601String(),
  });

  @override
  String toString() =>
      'run $runTag, PID $processId on $host, started '
      '${started.toUtc().toIso8601String()}';
}

/// [LiveLock.acquire] did not take the lock: another run holds it, or it
/// could not tell that the lock is stale.
class LiveLockHeld implements Exception {
  LiveLockHeld(this.message);

  final String message;

  @override
  String toString() => 'LiveLockHeld: $message';
}

/// The PIDs of the processes running on this machine, or `null` when they
/// cannot be told.
typedef RunningProcessIds = Future<Set<int>?> Function();

/// The PIDs of the processes running on this machine, from `tasklist` on
/// Windows and `ps` elsewhere, or `null` when they cannot be told: the list
/// could not be read, or it does not list this process.
Future<Set<int>?> runningProcessIds() async {
  try {
    final ProcessResult result;
    final RegExp row;
    if (Platform.isWindows) {
      // One CSV row per process, without a header: "image","PID",...
      result = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      row = RegExp(r'^"[^"]*","(\d+)"', multiLine: true);
    } else {
      result = await Process.run('ps', ['-A', '-o', 'pid=']);
      row = RegExp(r'^\s*(\d+)\s*$', multiLine: true);
    }
    if (result.exitCode != 0) return null;
    final ids = {
      for (final match in row.allMatches('${result.stdout}'))
        int.parse(match[1]!),
    };
    return ids.contains(pid) ? ids : null;
  } on ProcessException {
    return null;
  }
}

/// The lock of one live run on its session folder (see the top of this
/// file).
class LiveLock {
  LiveLock._(this.file, this.holder, this._content);

  /// The name of the lock file in the session folder.
  static const fileName = '.lock';

  /// The lock file.
  final File file;

  /// This run, as the lock file names it.
  final LiveLockHolder holder;

  final String _content;

  /// Takes the lock of the session folder [dir] (creating the folder when it
  /// does not exist) for the run tagged [runTag], or throws a [LiveLockHeld]
  /// when another run holds it.
  ///
  /// Takes over a stale lock (see the top of this file); [processIds] lists
  /// the running processes. While another run takes over the same stale
  /// lock, waits [retryDelay] and tries again, [attempts] times in all.
  static Future<LiveLock> acquire(
    String dir, {
    required String runTag,
    RunningProcessIds processIds = runningProcessIds,
    int attempts = 20,
    Duration retryDelay = const Duration(milliseconds: 100),
  }) async {
    await Directory(dir).create(recursive: true);
    final file = File(p.join(dir, fileName));
    final holder = LiveLockHolder.current(runTag);
    final content = holder.encode();

    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (await _create(file, content)) {
        return LiveLock._(file, holder, content);
      }
      final found = await _read(file);
      if (found == null) continue; // Given back since: try again.
      final other = LiveLockHolder.parse(found);
      if (other == null || !await _isStale(other, processIds)) {
        throw LiveLockHeld(_heldMessage(file, other));
      }
      if (!await _takeOver(file, found, other)) {
        // Another run is taking over the same stale lock.
        await Future<void>.delayed(retryDelay);
      }
    }
    throw LiveLockHeld(
      'Could not take the live lock ${file.path}: other runs kept taking it, '
      'or one is taking over a stale lock, or was stopped halfway through. '
      'If no live run is going on, delete that file and every '
      '$fileName.takeover-* file next to it.',
    );
  }

  /// Gives the lock back: deletes the lock file, if it still names this run.
  /// Does nothing when it was given back already.
  Future<void> release() async {
    if (await _read(file) == _content) await _delete(file);
  }

  /// Creates [file] with [content], when there is no such file yet.
  static Future<bool> _create(File file, String content) async {
    try {
      await file.create(exclusive: true);
    } on PathExistsException {
      return false;
    }
    try {
      await file.writeAsString(content, flush: true);
    } catch (_) {
      await _delete(file);
      rethrow;
    }
    return true;
  }

  /// The content of [file], or `null` when there is none.
  static Future<String?> _read(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// Deletes [file], if it is there.
  static Future<void> _delete(File file) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await file.delete();
        return;
      } on PathNotFoundException {
        return;
      } on PathAccessException {
        // Windows does not delete a file while another run reads it.
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// Whether the lock of [other] is stale: written on this machine by a
  /// process that no longer runs (and so not by this one), as a process list
  /// that lists this process shows.
  static Future<bool> _isStale(
    LiveLockHolder other,
    RunningProcessIds processIds,
  ) async {
    if (other.host != Platform.localHostname) return false;
    final running = await processIds();
    if (running == null || !running.contains(pid)) return false;
    return !running.contains(other.processId);
  }

  /// Deletes the stale lock [file], which read [found] (naming [other]),
  /// unless another run is taking it over: then returns `false`.
  static Future<bool> _takeOver(
    File file,
    String found,
    LiveLockHolder other,
  ) async {
    final name = '${other.processId}-${other.runTag}'.replaceAll(
      RegExp('[^A-Za-z0-9-]'),
      '_',
    );
    final marker = File('${file.path}.takeover-$name');
    try {
      await marker.create(exclusive: true);
    } on PathExistsException {
      return false;
    }
    try {
      // Only a run with the marker deletes the lock, and a new lock names
      // another run: when the lock still reads [found], it is the stale one.
      if (await _read(file) == found) await _delete(file);
    } finally {
      await _delete(marker);
    }
    return true;
  }

  static String _heldMessage(File file, LiveLockHolder? other) {
    final String who;
    if (other == null) {
      who = 'no run it can read (a run may be writing it right now)';
    } else if (other.processId == pid && other.host == Platform.localHostname) {
      who =
          '$other: this same process, so another live file of this `dart '
          'test` run (the live preset runs one test file at a time, '
          'concurrency: 1), or one that did not give the lock back';
    } else {
      who = '$other';
    }
    return 'Another live run is going on in this Smartschool session: the '
        'live lock ${file.path} names $who. One live run at a time per '
        'session (#62): wait for it to end. If no live run is going on, '
        'delete that file.';
  }
}
