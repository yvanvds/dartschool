// Tests for LiveLock (support/live_lock.dart), the lock that keeps a second
// live run out of the session of the live suite (#62), in temporary folders.
//
// This file is not tagged `live`: it runs offline, in every `dart test`.
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/no_network.dart';
import '../support/temp_cache_dir.dart';
import 'support/live_lock.dart';

const _tag = 'run-20261001-120000-0abc';
const _otherTag = 'run-20261001-110000-0def';

/// The PID of another process, which runs or not as each test says.
const _otherPid = 4242;

/// A PID that no process has: odd, so never one on Windows (whose PIDs are
/// multiples of 4), and above the highest PID of Linux and macOS.
const _noSuchPid = 2147483647;

/// A process list that lists this process and [others].
RunningProcessIds _running([Iterable<int> others = const []]) =>
    () async => {pid, ...others};

/// The lock file of the session folder [dir].
File _lockFile(String dir) => File(p.join(dir, LiveLock.fileName));

/// Writes the lock of another run into [dir]: run [_otherTag] in process
/// [processId] on [host] (this machine by default).
String _writeOtherLock(String dir, {int processId = _otherPid, String? host}) {
  final content = LiveLockHolder(
    runTag: _otherTag,
    processId: processId,
    host: host ?? Platform.localHostname,
    started: DateTime.utc(2026, 10, 1, 11),
  ).encode();
  _lockFile(dir).writeAsStringSync(content);
  return content;
}

/// The files in [dir], by name.
List<String> _files(String dir) =>
    Directory(dir).listSync().map((e) => p.basename(e.path)).toList()..sort();

/// Fails with a [LiveLockHeld] whose message contains [text].
Matcher _held(String text) => throwsA(
  isA<LiveLockHeld>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  forbidRealNetwork();

  group('acquire', () {
    test(
      'creates the lock, naming the run, its process and its machine',
      () async {
        final dir = p.join(tempCacheDir(), 'user');

        final lock = await LiveLock.acquire(dir, runTag: _tag);

        expect(lock.file.path, p.join(dir, '.lock'));
        final holder = LiveLockHolder.parse(lock.file.readAsStringSync());
        expect(holder, isNotNull);
        expect(holder!.runTag, _tag);
        expect(holder.processId, pid);
        expect(holder.host, Platform.localHostname);
        expect(holder.toString(), lock.holder.toString());
        expect(_files(dir), ['.lock']);
      },
    );

    test('refuses while another live file of the same run holds it, '
        'whatever the process list says', () async {
      final dir = tempCacheDir();
      final first = await LiveLock.acquire(dir, runTag: _otherTag);
      final content = first.file.readAsStringSync();

      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: _running()),
        _held(
          'this same process, so another live file of this `dart test` run',
        ),
      );
      expect(_lockFile(dir).readAsStringSync(), content);
    });

    test('refuses in another isolate of this process, as a second live file '
        'of the same run would be', () async {
      final dir = tempCacheDir();
      await LiveLock.acquire(dir, runTag: _otherTag);

      final refusal = await Isolate.run(() async {
        try {
          await LiveLock.acquire(dir, runTag: _tag);
          return null;
        } on LiveLockHeld catch (e) {
          return e.message;
        }
      });

      expect(refusal, contains(_otherTag));
      expect(
        LiveLockHolder.parse(_lockFile(dir).readAsStringSync())?.runTag,
        _otherTag,
      );
    });

    test('refuses while a run in another process that runs holds it, and '
        'names that run', () async {
      final dir = tempCacheDir();
      final content = _writeOtherLock(dir);

      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: _running([_otherPid])),
        _held('run $_otherTag, PID $_otherPid on ${Platform.localHostname}'),
      );
      expect(_lockFile(dir).readAsStringSync(), content);
      expect(_files(dir), ['.lock']);
    });

    test('refuses a lock it cannot read, such as one a run is still '
        'writing', () async {
      for (final content in ['', '{"runTag": "x"', 'not json', '[]']) {
        final dir = tempCacheDir();
        _lockFile(dir).writeAsStringSync(content);

        await expectLater(
          LiveLock.acquire(dir, runTag: _tag, processIds: _running()),
          _held('no run it can read'),
          reason: content,
        );
        expect(_lockFile(dir).readAsStringSync(), content, reason: content);
      }
    });

    test('refuses the lock of another machine, whose processes it cannot '
        'see', () async {
      final dir = tempCacheDir();
      final content = _writeOtherLock(dir, host: 'other-machine');

      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: _running()),
        _held('on other-machine'),
      );
      expect(_lockFile(dir).readAsStringSync(), content);
    });

    test('refuses when it cannot tell whether the process of the lock '
        'runs', () async {
      final dir = tempCacheDir();
      final content = _writeOtherLock(dir);

      // The process list could not be read.
      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: () async => null),
        throwsA(isA<LiveLockHeld>()),
      );
      // A process list without this process is not one it can trust.
      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: () async => {1, 2}),
        throwsA(isA<LiveLockHeld>()),
      );
      expect(_lockFile(dir).readAsStringSync(), content);
    });

    test('takes over a stale lock: one a process of this machine that no '
        'longer runs left behind', () async {
      final dir = tempCacheDir();
      _writeOtherLock(dir);

      final lock = await LiveLock.acquire(
        dir,
        runTag: _tag,
        processIds: _running([1, 8]),
      );

      final holder = LiveLockHolder.parse(lock.file.readAsStringSync());
      expect(holder?.runTag, _tag);
      expect(holder?.processId, pid);
      expect(_files(dir), ['.lock'], reason: 'no takeover marker left');
    });

    test('takes over a stale lock with the real process list', () async {
      final dir = tempCacheDir();
      _writeOtherLock(dir, processId: _noSuchPid);

      final lock = await LiveLock.acquire(dir, runTag: _tag);

      expect(LiveLockHolder.parse(lock.file.readAsStringSync())?.runTag, _tag);
    });

    test('waits while another run takes over the same stale lock, and then '
        'finds the lock that run took', () async {
      final dir = tempCacheDir();
      _writeOtherLock(dir);
      final marker = File(p.join(dir, '.lock.takeover-$_otherPid-$_otherTag'))
        ..createSync();
      // The other run, process 8, which runs: it deletes the stale lock,
      // takes the lock, and deletes its marker.
      final taken = LiveLockHolder(
        runTag: 'run-20261001-120000-0bbb',
        processId: 8,
        host: Platform.localHostname,
        started: DateTime.now().toUtc(),
      ).encode();
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        _lockFile(dir).writeAsStringSync(taken);
        marker.deleteSync();
      });

      await expectLater(
        LiveLock.acquire(
          dir,
          runTag: _tag,
          processIds: _running([8]),
          retryDelay: const Duration(milliseconds: 50),
        ),
        _held('run-20261001-120000-0bbb'),
      );
      expect(_lockFile(dir).readAsStringSync(), taken);
    });

    test('gives up, leaving the stale lock alone, while a takeover marker '
        'stays', () async {
      final dir = tempCacheDir();
      final content = _writeOtherLock(dir);
      File(p.join(dir, '.lock.takeover-$_otherPid-$_otherTag')).createSync();

      await expectLater(
        LiveLock.acquire(
          dir,
          runTag: _tag,
          processIds: _running(),
          attempts: 3,
          retryDelay: const Duration(milliseconds: 10),
        ),
        _held('.lock.takeover-* file'),
      );
      expect(_lockFile(dir).readAsStringSync(), content);
    });

    test('does not delete the lock that another run took over after it found '
        'the stale one', () async {
      final dir = tempCacheDir();
      _writeOtherLock(dir);
      final taken = LiveLockHolder(
        runTag: 'run-20261001-120000-0bbb',
        processId: 8,
        host: Platform.localHostname,
        started: DateTime.now().toUtc(),
      ).encode();

      // While this run looks up the processes, run 0bbb (process 8, which
      // runs) takes the stale lock over.
      Future<Set<int>?> processIds() async {
        _lockFile(dir).writeAsStringSync(taken);
        return {pid, 8};
      }

      await expectLater(
        LiveLock.acquire(dir, runTag: _tag, processIds: processIds),
        _held('run-20261001-120000-0bbb'),
      );
      expect(_lockFile(dir).readAsStringSync(), taken);
      expect(_files(dir), ['.lock'], reason: 'no takeover marker left');
    });

    test('of two runs that take a stale lock at the same time, one takes it '
        'and the other is refused', () async {
      final dir = tempCacheDir();
      _writeOtherLock(dir);

      Future<LiveLock?> attempt(String tag) async {
        try {
          return await LiveLock.acquire(
            dir,
            runTag: tag,
            processIds: _running(),
          );
        } on LiveLockHeld {
          return null;
        }
      }

      final locks = await Future.wait([
        attempt('run-20261001-120000-0001'),
        attempt('run-20261001-120000-0002'),
      ]);

      final taken = locks.nonNulls.toList();
      expect(taken, hasLength(1));
      expect(
        LiveLockHolder.parse(_lockFile(dir).readAsStringSync())?.runTag,
        taken.single.holder.runTag,
      );
      expect(_files(dir), ['.lock']);
    });
  });

  group('release', () {
    test('deletes the lock, so that the next run takes it', () async {
      final dir = tempCacheDir();
      final lock = await LiveLock.acquire(dir, runTag: _otherTag);

      await lock.release();

      expect(_lockFile(dir).existsSync(), isFalse);
      // Given back twice: nothing happens.
      await lock.release();
      final next = await LiveLock.acquire(dir, runTag: _tag);
      expect(LiveLockHolder.parse(next.file.readAsStringSync())?.runTag, _tag);
    });

    test('leaves a lock that no longer names the run alone', () async {
      final dir = tempCacheDir();
      final lock = await LiveLock.acquire(dir, runTag: _tag);
      final content = _writeOtherLock(dir);

      await lock.release();

      expect(_lockFile(dir).readAsStringSync(), content);
    });
  });

  group('runningProcessIds', () {
    test('lists this process and others, and not a PID that no process '
        'has', () async {
      final ids = await runningProcessIds();

      expect(ids, isNotNull);
      expect(ids, contains(pid));
      expect(ids!.length, greaterThan(1));
      expect(ids, isNot(contains(_noSuchPid)));
    });
  });

  group('LiveLockHolder', () {
    test('reads back what it writes', () {
      final holder = LiveLockHolder(
        runTag: _tag,
        processId: 1234,
        host: 'host',
        started: DateTime.utc(2026, 10, 1, 12),
      );

      final read = LiveLockHolder.parse(holder.encode());

      expect(read?.runTag, _tag);
      expect(read?.processId, 1234);
      expect(read?.host, 'host');
      expect(read?.started, DateTime.utc(2026, 10, 1, 12));
    });

    test('reads no holder from content that does not name one', () {
      for (final content in [
        '',
        'x',
        '[]',
        '{}',
        '{"runTag": "x", "pid": "1", "host": "h", "started": "2026-10-01"}',
        '{"runTag": "x", "pid": 1, "host": "h", "started": "never"}',
      ]) {
        expect(LiveLockHolder.parse(content), isNull, reason: content);
      }
    });
  });
}
