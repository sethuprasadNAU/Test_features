/// Something takes a backup, and something says how old the newest one is
/// (task 11.78 / Security Model §4.9).
///
/// ## What went wrong, and why these are the assertions
///
/// Task 11.70 made a backup work when it runs. Nothing ran it: `server/
/// README.md` said to add a daily cron, which is a step a human performs and
/// nothing checks. The end state for a person was identical to the bug 11.70
/// had just fixed — they believe they have encrypted backups, and the newest
/// archive is from the week they set the server up.
///
/// So these tests are about two properties and nothing else:
///
///   1. the schedule is a **declaration in the repository**, not a paragraph
///      an operator is trusted to have acted on; and
///   2. what reports on it measures **the age of the newest archive**, never
///      whether a scheduler process exists.
///
/// Task 11.45's rule applies: these assert the property, not the presence of
/// files. "A `freshness.sh` exists" would pass against a script that printed
/// nothing and exited 0.
library;

import 'dart:io';

import 'package:test/test.dart';

String _read(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '$path is missing. If it moved, these assertions must move with it '
        'rather than pass vacuously',
  );
  return file.readAsStringSync();
}

/// The body of one compose service — the lines indented under `  name:`, up to
/// the next key at the same or a shallower indent. Same shape as
/// `shipped_defaults_test.dart`'s reader, deliberately: a textual read of the
/// file an operator actually deploys, rather than a YAML parse that would also
/// accept a value arriving from somewhere this file cannot see.
String _service(String compose, String name) {
  final lines = compose.split('\n');
  final start = lines.indexWhere((l) => l.trimRight() == '  $name:');
  expect(
    start,
    isNot(-1),
    reason:
        'no `$name:` service in docker-compose.yml. If it was renamed, these '
        'assertions must move with it rather than pass vacuously',
  );
  final out = <String>[];
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    // A `  #` line at two spaces starts the next top-level block's comment
    // header, so it ends this service. Comments *inside* a service body are
    // indented with it and are kept.
    //
    // This used to be kept, and task 11.79 found out why that was wrong: it
    // absorbed the comment header of the service declared next, so a sentence
    // in that header saying why the NEXT service has no compose profile read
    // as a declaration on this one, and turned this test red for a property
    // that was still true.
    if (line.trim().isNotEmpty && !line.startsWith('    ')) {
      break;
    }
    out.add(line);
  }
  return out.join('\n');
}

void main() {
  late String compose;
  late String scheduler;
  late String backup;
  late String freshness;
  late String schedule;

  setUpAll(() {
    // `dart test` runs from the package root, so the repository root is one up.
    compose = _read('../docker-compose.yml');
    scheduler = _service(compose, 'backup-scheduler');
    backup = _service(compose, 'backup');
    freshness = _read('../server/backup/freshness.sh');
    schedule = _read('../server/backup/schedule.sh');
  });

  group('a backup happens without anybody remembering to take one', () {
    test('the shipped compose file declares a scheduler, and starts it', () {
      expect(
        scheduler,
        contains('tritrack-backup-schedule'),
        reason:
            'the `backup-scheduler` service must actually run the schedule '
            'loop; a service that runs something else schedules nothing',
      );
      // The one that matters most. `backup` is behind `profiles: ["backup"]`
      // on purpose — it is a one-shot job. A scheduler behind a profile is a
      // schedule nobody applied, which is exactly the state this task found.
      expect(
        scheduler,
        isNot(contains('profiles:')),
        reason:
            'a `backup-scheduler` behind a compose profile is not started by '
            '`docker compose up`, which makes the schedule a step a human '
            'performs — the defect task 11.78 exists to remove',
      );
      expect(
        scheduler,
        contains('restart: unless-stopped'),
        reason:
            'a schedule that does not survive a reboot is a schedule that '
            'stops silently on the first power cut, which is the same harm '
            'in a different costume',
      );
    });

    test('and the one-shot backup job stays a one-shot job', () {
      // The complement of the assertion above: this guards against somebody
      // "fixing" the profile problem by removing the profile from `backup`,
      // which would make `docker compose up` hold a long-lived container with
      // a mount of the age identity and every historical archive.
      expect(
        backup,
        contains('profiles: ["backup"]'),
        reason:
            '`backup` is invoked by scripts/backup_db.sh as a one-shot run. '
            'It must not become a service `docker compose up` starts',
      );
    });
  });

  group('what reports measures the archive, not the schedule', () {
    test('the healthcheck runs the freshness check and nothing else', () {
      final healthLine = scheduler
          .split('\n')
          .map((l) => l.trim())
          .firstWhere(
            (l) => l.startsWith('test:'),
            orElse: () => '',
          );
      expect(
        healthLine,
        contains('tritrack-backup-freshness'),
        reason:
            'the scheduler service must be measured by the age of the newest '
            'archive. A healthcheck that pinged the loop, or checked a pid, '
            'would stay green through an empty TRITRACK_BACKUP_RECIPIENTS, a '
            'full disk and a .env edited last month — all of which are the '
            'same fact to a person: the newest archive is old',
      );
    });

    test('the freshness check reads archives, never the scheduler', () {
      expect(
        freshness,
        contains('/backups'),
        reason: 'it has to look at the archive directory to measure it',
      );
      for (final forbidden in ['pgrep', 'pidof', '/proc/', 'kill -0']) {
        expect(
          freshness,
          isNot(contains(forbidden)),
          reason:
              'freshness.sh must not ask whether a process is running — the '
              'whole distinction task 11.78 turns on is that a timer existing '
              'and a backup existing are different facts',
        );
      }
    });

    test('and so is "I cannot read the directory"', () {
      // Task 11.70's whole finding was a message naming the wrong cause. On
      // Linux a bind mount passes host ownership through, so a container
      // running as the wrong user cannot read `backups/` — and reporting that
      // as "no backup has ever been taken" would send an operator to
      // reconfigure a backup job that is working, or to panic about data that
      // is safely on disk.
      expect(
        freshness,
        contains('BACKUP FRESHNESS UNKNOWN'),
        reason:
            'an unreadable directory is a fourth outcome, not a flavour of '
            'absent — nothing in that case says whether archives exist',
      );
      expect(
        freshness,
        contains('tritrack_ownership_note'),
        reason:
            'task 11.70 already wrote the sentence that turns a permission '
            'problem into a sentence about permissions; this must reuse it '
            'rather than invent a second, drifting copy',
      );
    });

    test('stale and absent are different sentences, not one message', () {
      expect(
        freshness,
        contains('NO BACKUP HAS EVER BEEN TAKEN'),
        reason:
            'absent must be its own sentence: it means every observation on '
            'this server exists only on the devices that recorded it, which '
            'is a different situation from a schedule that stopped last week',
      );
      expect(
        freshness,
        contains('NEWEST BACKUP IS'),
        reason:
            'stale must name the age. "backups are unhealthy" is the message '
            'a person cannot act on; "34 days old" is the one they cannot '
            'hold a false belief through',
      );
    });

    test('a planted filename cannot make the check green', () {
      // Findings H-7 and I-2, one layer up. Anyone who can write into
      // `backups/` could otherwise drop `tritrack-29991231T235959Z.age` and
      // silence the staleness alarm forever — which is a thing an attacker
      // wants far more than they want to delete an archive.
      expect(
        freshness,
        contains('minisign -V'),
        reason:
            'the age comes from a filename, so the filename has to be '
            'authenticated — the same predicate retention uses',
      );
      expect(
        freshness,
        contains(r'archive=\([^[:space:]]*\)'),
        reason:
            'a signature covers bytes, not the name beside them (finding '
            'I-2). The signed `archive=` field must be checked against this '
            "file's own basename, or a renamed copy of one genuine pair "
            'reads as a fresh backup',
      );
      expect(
        freshness,
        isNot(contains('stat ')),
        reason:
            'the age must not come from mtime (`stat -c %Y`): whoever can '
            'write the '
            'directory can touch a genuine archive, and an eighteen-month-old '
            'backup would then read as this morning\'s',
      );
    });
  });

  group('the scheduler stays up while it is broken', () {
    test('a failed backup does not end the loop', () {
      expect(
        schedule,
        contains('while :'),
        reason: 'it is a loop, and it has to still be one',
      );
      // A stopped container has no healthcheck, so exiting on failure would
      // replace a red signal with no signal — the exact shape of the defect.
      expect(
        schedule,
        isNot(contains('exit 1')),
        reason:
            'the loop must not exit when a backup fails. A stopped container '
            'reports no health at all, so exiting would turn a visible '
            'failure back into a silent one',
      );
    });
  });

  group('the two backup containers cannot drift apart', () {
    test('they run as the same user, read from the environment', () {
      String userLine(String service) => service
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('user:'));
      expect(
        userLine(scheduler),
        equals(userLine(backup)),
        reason:
            'task 11.70: on Linux a bind mount passes host ownership through, '
            'so both containers must run as the operator. A scheduler running '
            'as somebody else would write archives the operator cannot read '
            'and could not open the signing key at all',
      );
      expect(
        userLine(scheduler),
        contains(r'${TRITRACK_BACKUP_UID'),
        reason:
            'read from the environment (scripts/lib/backup_user.sh sets it). '
            'A literal uid here would be right on exactly one machine',
      );
    });

    test('the scheduler is given everything the pipeline reads', () {
      // Named one by one rather than diffed against `backup`, which also
      // carries restore-only variables the scheduler has no business holding.
      // Anything backup.sh reads and this omits is a scheduled backup that
      // behaves differently from a manual one — silently, and only on the
      // machine where nobody is watching.
      const needed = [
        'POSTGRES_HOST:',
        'POSTGRES_PORT:',
        'POSTGRES_USER:',
        'POSTGRES_PASSWORD:',
        'POSTGRES_DB:',
        'TRITRACK_BACKUP_RECIPIENTS:',
        'TRITRACK_BACKUP_KEEP:',
        'TRITRACK_BACKUP_VERIFY_KEY:',
      ];
      for (final key in needed) {
        expect(
          scheduler,
          contains(key),
          reason:
              '`backup-scheduler` does not declare $key, which server/backup/'
              'backup.sh reads. A scheduled backup would then differ from the '
              'manual one the drill exercises',
        );
      }
      expect(
        scheduler,
        contains(':/backups'),
        reason: 'it has to be able to write an archive',
      );
      expect(
        scheduler,
        contains('/signing/key.sec:ro'),
        reason:
            'an unattended job is exactly the case §4.9.2 keeps a signing key '
            'on this machine for. Without it every scheduled archive is '
            'unsigned and can never be restored in place',
      );
      // And the one it must NOT have: the age identity is what READS an
      // archive, and §4.9 keeps it off this machine entirely.
      expect(
        scheduler,
        isNot(contains('/identity/key.txt')),
        reason:
            'the scheduler never restores. Mounting the decryption identity '
            'into a long-lived container would put the key that can read '
            'every archive on the machine that holds every archive',
      );
    });
  });

  group('the documentation no longer describes a step nothing performs', () {
    test('server/README.md does not send the operator to write a cron entry',
        () {
      final readme = _read('../server/README.md');
      expect(
        readme,
        isNot(contains('Nothing schedules\nit for you')),
        reason:
            'that sentence is the defect in prose form. The schedule is a '
            'declaration in docker-compose.yml now',
      );
      expect(
        readme,
        contains('scripts/backup_status.sh'),
        reason:
            'a person has to be told where to look. The floor task 11.78 '
            'adopted is that something visible names the age of the newest '
            'archive',
      );
    });
  });
}
