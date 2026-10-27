import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Finding G-3's structural guard (task 10.37): **the restore path must not be
/// able to destroy data before it knows the archive is readable.**
///
/// `scripts/backup_restore_drill.sh` proves this properly — it restores a real
/// archive over a real database and checks the canary survives. But the drill
/// needs Docker, takes minutes, and is run quarterly. G-3 was a regression that
/// sat in `restore.sh` from one gate to the next precisely because the only
/// thing that would have caught it was a drill nobody had reason to run, and
/// the drill of the day exercised only the fresh-name path anyway.
///
/// So this is the cheap half: a structural read of the script that runs in
/// `flutter test` on every checkout, with no Docker and no database. It cannot
/// prove the restore *works* — only the drill can do that — but it fails the
/// moment someone reorders the script back to drop-then-decrypt, which is the
/// specific mistake that cost a season's data at the second Gate C re-run.
void main() {
  late String script;

  setUpAll(() async {
    script = await File('server/backup/restore.sh').readAsString();
  });

  /// Index of the first line matching [pattern], or -1.
  int lineOf(String script, Pattern pattern) {
    final lines = script.split('\n');
    for (var i = 0; i < lines.length; i++) {
      // Comments describe the ordering at length; only executable lines count.
      if (lines[i].trimLeft().startsWith('#')) continue;
      if (lines[i].contains(pattern)) return i;
    }
    return -1;
  }

  group('restore.sh verifies before it destroys', () {
    test('the full decrypt happens before any rename', () {
      final verify = lineOf(script, RegExp(r'age --decrypt.*\|\s*awk'));
      expect(
        verify,
        greaterThan(-1),
        reason: 'restore.sh must verify the whole archive decrypts before it '
            'touches anything — see §9.4 G-3',
      );

      final rename = lineOf(script, 'ALTER DATABASE');
      expect(rename, greaterThan(-1), reason: 'the swap should be a rename');
      expect(
        verify,
        lessThan(rename),
        reason: 'the decrypt verification must come BEFORE the first rename. '
            'This is G-3 verbatim: the gate reproduced a live database being '
            'destroyed and only then discovering the archive was unreadable.',
      );
    });

    test('the recorded checksum is verified, on this path and not only in the '
        'wrapper', () {
      // The checksum check used to live only in scripts/restore_db.sh, which
      // cannot perform an in-place replace (it never sets
      // TRITRACK_RESTORE_REPLACE). So the one path that could destroy data was
      // the one path with no integrity check. That is the root cause of how a
      // truncated archive reached a DROP DATABASE.
      expect(
        script,
        contains('sha256sum -c'),
        reason: 'restore.sh must check the .sha256 backup.sh writes',
      );
      final checksum = lineOf(script, 'sha256sum -c');
      final rename = lineOf(script, 'ALTER DATABASE');
      expect(checksum, lessThan(rename));
    });

    test('nothing drops a database', () {
      // The strongest form of the rule, and the easiest to check: a restore
      // has no business issuing DROP DATABASE against anything except the
      // staging database it created itself moments earlier.
      //
      // WHAT THIS TEST DOES NOT PROVE (finding H-9, task 10.43). It is a text
      // grep, and it was *satisfied by the bug it should have caught*: the
      // staging drop mentioned `$STAGING`, so it passed — while nothing
      // checked that `$STAGING` was a database this run created rather than
      // one it collided with. A drop assembled in a variable would pass it
      // too. "The only name it drops is $STAGING" and "$STAGING is ours to
      // drop" are two claims, and for two tasks this file only checked the
      // first. The second is the test below; the behavioural proof is the
      // drill's step 7m.
      final drops = script
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          // The success message prints a DROP for the operator to run by hand
          // on the database it kept. Printing one is the opposite of issuing one.
          .where((l) => !l.trimLeft().startsWith('echo'))
          .where((l) => l.contains('DROP DATABASE'))
          .toList();
      expect(
        drops,
        isNotEmpty,
        reason: 'this test is vacuous if restore.sh has no DROP DATABASE at '
            'all — that would mean the staging cleanup has moved somewhere '
            'this file no longer reads',
      );
      for (final drop in drops) {
        expect(
          drop,
          contains(r'$STAGING'),
          reason: 'the only database restore.sh may drop is its own staging '
              'database; found: ${drop.trim()}',
        );
      }
    });

    test('the staging database it drops is one it created (H-9)', () {
      // The claim `restore.sh` makes in its own pre-flight banner — "creates
      // something new under a name nobody is using" — was enforced for
      // $TARGET (a pg_database lookup plus TRITRACK_RESTORE_REPLACE) and for
      // $STAGING by nothing at all, while the EXIT trap dropped $STAGING with
      // output suppressed. The name is derived from the current UTC second,
      // so a collision needs two concurrent restores of the same target or a
      // leftover from an interrupted one. Both are reachable; neither is
      // something a comment gets to assume away.
      final guard = lineOf(
        script,
        RegExp(r'SELECT 1 FROM pg_database WHERE datname = .\$STAGING'),
      );
      expect(
        guard,
        greaterThan(-1),
        reason: 'restore.sh must check that the staging name is free before '
            'creating it — otherwise its cleanup can drop a database that '
            'belongs to another run',
      );

      final create = lineOf(script, RegExp(r'CREATE DATABASE.*STAGING'));
      expect(
        guard,
        lessThan(create),
        reason: 'the collision check has to come BEFORE the CREATE, or the '
            'CREATE fails on a taken name and the trap that is already armed '
            'drops the database it collided with',
      );

      final arm = lineOf(script, RegExp(r'^\s*trap drop_staging EXIT'));
      expect(arm, greaterThan(-1), reason: 'the staging cleanup must be armed');
      expect(
        create,
        lessThan(arm),
        reason: 'the trap must be armed only once this run is the thing that '
            'created the staging database',
      );
    });

    test('the staging cleanup is disarmed before the swap, and covers '
        'interrupts (H-9)', () {
      // Two edges from H-9, and they pull in opposite directions, which is
      // why they are one test.
      //
      // Disarm BEFORE the swap: once the staging database holds a fully
      // decrypted, fully verified restore it is the most valuable database on
      // the server. The trap used to stay armed across the rename, so the
      // worst case — rename aside, promote fails, rollback fails — printed
      // the correct manual instructions and then silently dropped the restore
      // on the way out.
      final disarm = lineOf(script, RegExp(r'^\s*trap - EXIT'));
      expect(disarm, greaterThan(-1), reason: 'the trap must be disarmed');
      final firstRename = lineOf(script, 'ALTER DATABASE');
      expect(
        disarm,
        lessThan(firstRename),
        reason: 'the staging cleanup must be disarmed BEFORE the first rename, '
            'not after the last one: every way the swap can fail is a way an '
            'operator needs the verified restore to still exist',
      );

      // But an interrupt before the swap must still clean up — only EXIT was
      // trapped, so Ctrl-C left a staging database behind under a name a
      // later run would then (correctly, now) refuse.
      expect(
        script,
        contains('drop_staging; exit 130'),
        reason: 'INT must clean up the staging database it created',
      );
      expect(
        script,
        contains('drop_staging; exit 143'),
        reason: 'TERM must clean up the staging database it created',
      );
    });

    test('the restore runs in a single transaction', () {
      // age authenticates per STREAM chunk, so a truncated archive decrypts a
      // valid prefix and then aborts. Without this flag that prefix is already
      // committed statement by statement — a database that exists, answers
      // queries, and is missing rows.
      expect(
        script,
        contains('--single-transaction'),
        reason: 'a mid-stream decrypt abort must not leave a partial restore',
      );
    });

    test('the archive origin is verified before any rename (H-6)', () {
      // Finding H-6, reproduced live at the third Gate C re-run: an archive
      // forged with nothing but the PUBLIC age recipient passed the checksum,
      // the schema marker and the decrypt-verify, had its SQL piped into psql
      // as a superuser, and was renamed into the live database name. `age` has
      // no signing mode; it proves the bytes were not altered after
      // encryption and says nothing about who encrypted them. All three gates
      // were files the attacker authored.
      final verify = lineOf(script, RegExp(r'minisign -V'));
      expect(
        verify,
        greaterThan(-1),
        reason: 'restore.sh must verify a signature over the archive — '
            'integrity is not origin (§4.9.2, finding H-6)',
      );
      final rename = lineOf(script, 'ALTER DATABASE');
      expect(verify, lessThan(rename));
    });

    test('the verifying key comes from the environment, never from beside the '
        'archive (H-6)', () {
      // The half of the design that is easy to get wrong and impossible to
      // notice: a directory that supplies its own verifying key proves only
      // that it is internally consistent, which H-6's forgery also was.
      expect(script, contains(r'${TRITRACK_BACKUP_VERIFY_KEY:-}'));
      expect(
        script,
        isNot(contains(r'/backups/*.pub')),
        reason: 'the verifying key must not be read from the archive directory',
      );
      final keySource = lineOf(script, 'TRITRACK_BACKUP_VERIFY_KEY');
      final verify = lineOf(script, RegExp(r'minisign -V'));
      expect(keySource, lessThan(verify));
    });

    test('an archive of unverified origin is never promoted over an existing '
        'database (H-6)', () {
      // The refusal that actually closes H-6, as opposed to the check that
      // detects it. An unsigned archive is still restorable — every archive
      // written before task 10.43 is one — but only into a name of its own,
      // where an operator can look at it before believing it.
      expect(
        script,
        contains('I_ACCEPT_UNVERIFIED_ORIGIN'),
        reason: 'restoring an unattributable archive must be a deliberate act',
      );
      final unsignedReplaceGuard = lineOf(
        script,
        RegExp(r'TRITRACK_RESTORE_REPLACE:-.* = "I_UNDERSTAND"'),
      );
      expect(
        unsignedReplaceGuard,
        greaterThan(-1),
        reason: 'the unsigned path must specifically refuse the replace flag; '
            'if any combination of flags can promote an unattributable '
            'archive then H-6 is closed by a sentence rather than by code',
      );
      final rename = lineOf(script, 'ALTER DATABASE');
      expect(unsignedReplaceGuard, lessThan(rename));
    });

    test('the restore lands in a staging database, not the target', () {
      expect(script, contains(r'STAGING="${TARGET}_restore_'));
      expect(script, contains(r'DISPLACED="${TARGET}_replaced_'));
      final create = lineOf(script, RegExp(r'CREATE DATABASE.*STAGING'));
      expect(
        create,
        greaterThan(-1),
        reason: 'the restore must be built under a name nothing is using, then '
            'renamed into place',
      );
    });
  });

  group('the drill exercises the path that can destroy data', () {
    late String drill;

    setUpAll(() async {
      drill = await File('scripts/backup_restore_drill.sh').readAsString();
    });

    test('it types the replace flag against the live database', () {
      // Until task 10.37 it did not, which is why eleven green checks and G-3
      // coexisted. A drill that only runs the safe path is not a drill.
      expect(
        drill,
        contains('I_UNDERSTAND'),
        reason: 'the drill must exercise TRITRACK_RESTORE_REPLACE, or the only '
            'path capable of losing data is covered by nothing',
      );
      expect(drill, contains(r'try_restore "$(basename "$TRUNCATED")"'));
      expect(drill, contains(r'try_restore "$(basename "$WRONGKEY")"'));
    });

    test('it checks the live canary survives a failed replace', () {
      expect(drill, contains('live_canary'));
      expect(
        drill,
        contains('DATA LOST'),
        reason: 'the drill must assert on the live data, not just on exit codes',
      );
    });

    test('it includes an adversary, not only accidents (H-6)', () {
      // Every case the drill had before task 10.43 was an accident: a
      // checksum that rotted, a file cut short, the wrong holder's key. H-6
      // was missed for three gates because a control designed against
      // accident and a control against an adversary get written down in the
      // same sentence, and nobody asked what someone who can write a file
      // into the archive directory can do.
      expect(
        drill,
        contains('forged.sql'),
        reason: 'the drill must forge an archive with the PUBLIC recipient — '
            'the attacker position §4.9.1 explicitly permits',
      );
      expect(
        drill,
        contains(r'try_restore "$FORGED" "$POSTGRES_DB"'),
        reason: 'the forged archive has to be aimed at the LIVE database with '
            'the replace flag, which is what reproduced',
      );
      expect(
        drill,
        contains('I_ACCEPT_UNVERIFIED_ORIGIN'),
        reason: 'the drill must prove the unsigned escape hatch does not '
            're-open the in-place path',
      );
      expect(
        drill,
        contains('untrusted-sign.sec'),
        reason: '"carries a signature" and "carries a signature by a key this '
            'operator trusts" are different claims; the drill must separate '
            'them',
      );
    });

    test('it forces a rollback and a staging collision (H-9)', () {
      // The rollback protects an operator from ending up with no target
      // database at all, and it had never executed once: nothing in the four
      // destructive cases can make a rename fail. Untested recovery code is
      // indistinguishable from absent recovery code.
      expect(
        drill,
        contains('promote_and_rollback'),
        reason: 'the drill must force the worst-case swap failure — rename '
            'aside succeeds, promote fails, rollback fails — which is the '
            'case where the EXIT trap silently dropped the verified restore',
      );
      expect(
        drill,
        contains('H-9 REPRODUCES'),
        reason: 'the drill must assert the verified restore survives the '
            'double failure, not just that the script exits non-zero',
      );
      expect(
        drill,
        contains('is already taken'),
        reason: 'the drill must force a staging-name collision and prove the '
            'planted databases are not dropped',
      );
    });
  });
}
