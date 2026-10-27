/// What the backup containers say when they cannot write where they were told
/// to (tasks 11.70 and 11.80).
///
/// ## The two defects behind this file, and they are one level apart
///
/// **Task 11.70:** a backup that could not create a file in `backups/` reported
/// `pg_dump | age pipeline failed`, which sent the operator to look at their
/// database. A message naming the wrong cause.
///
/// **Task 11.80, found on Michael's own server:** the replacement named the
/// *right* cause — the uid/gid mismatch, correctly, with the real numbers — and
/// then gave one remedy: *use `scripts/server_up.sh` instead of a raw compose
/// line.* **He had used `scripts/server_up.sh`.** The directory was owned by
/// root, left that way by a bare `docker compose up` taken before 11.70 landed;
/// no script in this repository can change who owns a directory on the host.
///
/// **The second is worse than the first in one specific way:** the reader
/// follows it exactly, fails again, and now doubts the diagnosis as well as the
/// remedy. So these tests are not about whether the message explains the cause
/// — 11.70 settled that — they are about whether **the reader who already did
/// what it said** is given something that works.
///
/// Both branches run for real here, against the actual shell function the image
/// carries, rather than being asserted about its source text. The
/// somebody-else case is made deterministic with a `stat` shim on `PATH`, so
/// this holds the same on a laptop and on a CI runner, root or not — task
/// 11.88's rule: a check whose answer depends on the host is expressing
/// something other than the property.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Runs `tritrack_ownership_note <path>` from the real `permissions.sh`.
///
/// [fakeOwner] installs a `stat` on `PATH` reporting that owner, which is how
/// the "belongs to somebody else" branch is reached without needing a
/// differently-owned directory to exist on whatever machine this runs on.
String note(String path, {String? fakeOwner, required Directory shimDir}) {
  var env = <String, String>{};
  if (fakeOwner != null) {
    final stat = File('${shimDir.path}/stat');
    // Answers `%u:%g` with the fake owner and anything else with a mode. The
    // real function tries GNU `stat -c` first, so this shim only has to answer
    // that form.
    stat.writeAsStringSync('''
#!/bin/sh
case "\$*" in
  *%u:%g*) echo '$fakeOwner' ;;
  *) echo '755' ;;
esac
''');
    Process.runSync('chmod', ['0755', stat.path]);
    env = {'PATH': '${shimDir.path}:${Platform.environment['PATH']}'};
  }
  final result = Process.runSync('sh', [
    '-c',
    '. ../server/backup/permissions.sh; tritrack_ownership_note "$path"',
  ], environment: env);
  expect(
    result.exitCode,
    0,
    reason:
        'the note must never fail: it runs inside a failure path, and a '
        'diagnosis that dies leaves the original message with no explanation '
        'at all. stderr: ${result.stderr}',
  );
  return result.stdout as String;
}

void main() {
  late Directory shimDir;

  setUp(() => shimDir = Directory.systemTemp.createTempSync('tritrack-shim'));
  tearDown(() => shimDir.deleteSync(recursive: true));

  group('when the directory belongs to somebody else', () {
    late String message;

    setUp(() {
      // A uid nothing can legitimately be, so this branch is reached on every
      // host including a root CI container.
      message = note(
        Directory.current.path,
        fakeOwner: '4294967290:4294967290',
        shimDir: shimDir,
      );
    });

    test('it gives the one command that actually fixes it', () {
      expect(
        message,
        contains('chown -R'),
        reason:
            'this is the whole finding. No script in this repository can '
            'change who owns a directory on the host, so a message that '
            'offers only scripts leaves the operator who ran them with '
            'nowhere to go',
      );
      final me = '${Process.runSync('id', ['-u']).stdout}'.trim();
      expect(
        message,
        contains('chown -R $me:'),
        reason:
            'the numbers must be read out of the running container, not left '
            'as a template. An operator copying a command with placeholders '
            'in it is an operator guessing at the values',
      );
      expect(
        message,
        contains(Directory.current.path),
        reason: 'and it must name the path that actually failed',
      );
    });

    test('it tells the reader who already ran the scripts that that was not '
        'their mistake', () {
      expect(
        message,
        contains('THAT IS EXPECTED'),
        reason:
            'Michael had used scripts/server_up.sh and was told to use '
            'scripts/server_up.sh. A reader who followed the advice and '
            'failed must be told the advice was not wrong for them, or they '
            'stop trusting the diagnosis too',
      );
    });

    test('the fix comes before the scripts, not after them', () {
      // Measured against the block that OFFERS the scripts as the remedy, not
      // against the earlier sentence that names them to say "you already did
      // that and it was not your mistake". Those two mentions do opposite
      // jobs and only the second is a competing remedy.
      final chownAt = message.indexOf('chown -R');
      final scriptsAt = message.indexOf('If instead you ran a raw');
      expect(chownAt, greaterThan(-1));
      expect(
        scriptsAt,
        greaterThan(-1),
        reason:
            'the raw-compose case is real and still needs its answer — this '
            'task reordered the remedies, it did not delete one',
      );
      expect(
        chownAt,
        lessThan(scriptsAt),
        reason:
            'order is the defect. The reader who needs the chown is by '
            'definition the reader the script advice already failed, and a '
            'remedy they have to scroll past a failed one to find is a '
            'remedy most people will not reach',
      );
    });

    test('it still explains why, and says nothing was written', () {
      // Task 11.70's property, kept: this must not become a bare command.
      expect(message, contains('NOT a database problem'));
      expect(message, contains('nothing has been written'));
      expect(
        message,
        contains('bind mount'),
        reason:
            'the reason a laptop differs from a server is the fact that makes '
            'this diagnosable at all',
      );
    });
  });

  group('when the directory is already ours', () {
    late String message;

    setUp(() => message = note(Directory.current.path, shimDir: shimDir));

    test('it does not tell us to chown something we already own', () {
      expect(
        message,
        contains('ALREADY owned by this user'),
        reason:
            'two different causes wear the same symptom, and naming the wrong '
            'one is what this whole file exists to prevent',
      );
      expect(
        message,
        isNot(contains('chown -R')),
        reason:
            'sending somebody to chown a directory that is already theirs '
            'wastes the one action they were given and teaches them the '
            'message is guessing',
      );
    });

    test('and it names the causes that are actually left', () {
      expect(message, contains('read-only'));
    });
  });
}
