import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.69, second pass — **the guard for the host side of the development
/// magic-link mount.**
///
/// ## What went wrong, in one sentence
///
/// The first pass fixed *who* the development server runs as, so that the
/// mode-600 sign-in link it writes is owned by the person who asked for it.
/// It did not fix *where* that file lands: `.e2e_magic_links/` and
/// `.dev_magic_links/` are bind-mounted from the host and are in `.gitignore`
/// — correctly, they hold live credentials — so **a clean checkout does not
/// have them**, and Docker creates a missing bind-mount source as `root`. The
/// server, now correctly running as the invoking user, could not write into
/// the root-owned directory it had just been handed.
///
/// Nothing said so. `auth_routes.dart` swallows a delivery failure on purpose
/// — §4.5 requires `/auth/magic-link` to answer an identical `202` whether or
/// not delivery worked, otherwise the response is an account-enumeration
/// oracle — so the request succeeded, no link appeared, and eleven gate
/// instruments could report only the symptom.
///
/// **It passed on the development machine because that directory has been
/// sitting there since the first e2e run.** Same class as the
/// `server/.dart_tool/package_config.json` failure this task started with, and
/// it hid in the same place: something that is not committed is not part of
/// the build, and a directory is a something.
///
/// ## Why a test and not just the fix
///
/// The fix is four lines in `scripts/lib/host_user.sh`. What those four lines
/// cannot do is reach a bring-up that does not go through them — and there
/// were five of those, all of them usage blocks telling a person to type a raw
/// `docker compose ... up` line. A person following one on Linux gets a
/// sign-in that never arrives and no error anywhere. Task 10.66's standing
/// criterion is to fix the class, and the class here is "a raw bring-up of
/// these two overlays that does not arrange the host side of the mount".
void main() {
  /// Every file in the repository, minus the places it is wrong to constrain:
  /// `CLAUDE_DOCS/` (a historical record — a past report that quoted a
  /// bring-up line must not be rewritten to look like it always had the fix),
  /// and the two magic-link mount points.
  ///
  /// **"The repository" is asked of git rather than assumed from the working
  /// directory (task 11.118).** This used to walk `Directory.current` and skip
  /// a hand-written list of directory names, which meant it also read
  /// **generated, git-ignored output that no commit contains** — and on
  /// 2026-09-02 that turned `flutter test` red for a file nobody could fix by
  /// editing the repository.
  ///
  /// What it found was `.agents/`, a mirror of `.claude/commands/` that the
  /// Claude Code harness generates and never refreshes. Its copy of task
  /// 11.125's command file was **stale**: it still quoted the raw bring-up
  /// line that the tracked original had since been rewritten to *describe*
  /// rather than quote — and that original says, in so many words, that it
  /// describes the line because this very check fails a file that carries a
  /// runnable one. **The tracked file was right, the generated copy was a
  /// month behind, and the check could not tell them apart.**
  ///
  /// > A copy of a document acquires its own maintenance burden the moment it
  /// > exists, and nothing tells you when it has fallen behind. Here nothing
  /// > had to: the copy is not the project's to maintain at all.
  ///
  /// `git ls-files --cached --others --exclude-standard` is exactly the set a
  /// commit could contain — tracked files, **plus** untracked ones that are
  /// not ignored, so a script somebody wrote five minutes ago and has not yet
  /// added is still constrained. Ignored build and tool output is not.
  List<File> repositoryFiles() {
    const skipDirs = {
      'CLAUDE_DOCS',
      '.e2e_magic_links',
      '.dev_magic_links',
      'INVENTION_DISCLOSURE',
    };
    final listed = Process.runSync('git', [
      'ls-files',
      '--cached',
      '--others',
      '--exclude-standard',
    ]);
    expect(
      listed.exitCode,
      0,
      reason:
          'git could not list the repository, so this check has no corpus. '
          'It must not silently pass on an empty one: ${listed.stderr}',
    );
    final paths = (listed.stdout as String)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .where((l) => !skipDirs.contains(l.split('/').first));

    final out = [for (final p in paths) File(p)];
    expect(
      out,
      isNotEmpty,
      reason: 'an empty corpus would make every assertion below vacuous',
    );
    return out.where((f) => f.existsSync()).toList();
  }

  /// Line continuations joined first: one of the five usage blocks spells the
  /// overlay on one line and `up --build -d` on the next.
  String joinContinuations(String source) =>
      source.replaceAll(RegExp(r'\\+\n\s*'), ' ');

  final bringUp = RegExp(
    r'docker\s+compose[^\n]*docker-compose\.(e2e|dev-lan)\.yml[^\n]*\bup\b',
  );

  test('every raw bring-up of the e2e or dev-lan overlay arranges the host '
      'side of the magic-link mount', () {
    final offenders = <String>[];
    for (final file in repositoryFiles()) {
      final path = file.path.replaceFirst('${Directory.current.path}/', '');
      // This file names the pattern in order to search for it.
      if (path == 'test/documentation/dev_stack_host_prerequisites_test.dart') {
        continue;
      }
      String source;
      try {
        source = file.readAsStringSync();
      } on FileSystemException {
        continue; // binary, or unreadable — neither can spell a compose line
      }
      if (!bringUp.hasMatch(joinContinuations(source))) continue;

      // Two ways to be correct, and the second exists for the one caller that
      // legitimately cannot source a shell library: a GitHub workflow step,
      // which sets the variables through GITHUB_ENV and creates the directory
      // itself.
      final sourcesTheLibrary = source.contains('scripts/lib/host_user.sh');
      final arrangesItInline = source.contains('TRITRACK_DEV_UID') &&
          RegExp(r'mkdir\s+-p\s+\.?e2e_magic_links|'
                  r'mkdir\s+-p\s+\.?dev_magic_links|'
                  r'makedirs\(')
              .hasMatch(source);
      if (!sourcesTheLibrary && !arrangesItInline) {
        offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files tell somebody — a person, a workflow, or a script — to '
          'bring up the e2e or dev-lan stack directly, without arranging the '
          'two things that bring-up needs on a Linux host: the user the server '
          'container runs as, and a magic-link directory owned by that user. '
          'On Linux the result is a sign-in link that is never written, and '
          'NOTHING reports it — /auth/magic-link answers 202 either way, '
          'because §4.5 requires it to. Add `. scripts/lib/host_user.sh` '
          'before the bring-up line (it does both halves), or, if this is a '
          'workflow step that cannot source a shell library, set '
          'TRITRACK_DEV_UID/GID and create the directory in the step itself.\n'
          'Offenders: ${offenders.join(', ')}',
    );
  });

  test('sourcing scripts/lib/host_user.sh really does create both link '
      'directories, in a directory that does not have them', () {
    // **Run, not read.** The test above lets a file off the hook the moment it
    // mentions this library, so this library has to be the thing that does the
    // work — and an assertion that the library *mentions* `.e2e_magic_links`
    // would pass on a version where the only mention left is this comment.
    // That is the weak-assertion shape task 10.42 swept for and this project
    // has found in its own instruments three times. So: a scratch directory
    // with neither name in it, source the file, and look.
    final scratch = Directory.systemTemp.createTempSync('tt1169-hostuser-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    Directory('${scratch.path}/scripts/lib').createSync(recursive: true);
    File('scripts/lib/host_user.sh')
        .copySync('${scratch.path}/scripts/lib/host_user.sh');

    final result = Process.runSync(
      'bash',
      ['-c', 'set -eu; . scripts/lib/host_user.sh'],
      workingDirectory: scratch.path,
    );
    expect(
      result.exitCode,
      0,
      reason:
          'Sourcing scripts/lib/host_user.sh failed. Every script that brings '
          'up a development stack sources it, so this is not a small failure.\n'
          '${result.stdout}\n${result.stderr}',
    );

    for (final name in ['.e2e_magic_links', '.dev_magic_links']) {
      expect(
        Directory('${scratch.path}/$name').existsSync(),
        isTrue,
        reason:
            'Sourcing scripts/lib/host_user.sh did not create $name. On a '
            'clean checkout that directory does not exist — it is gitignored, '
            'because it holds live sign-in credentials — and Docker creates a '
            'missing bind-mount source as root. The server then runs as the '
            'invoking user and cannot write the sign-in link into it, and '
            'nothing anywhere reports that: /auth/magic-link answers the same '
            '202 whether the link was written or not, because §4.5 requires '
            'it to. That is exactly how eleven gate instruments went red on '
            'the 2026-08-30 CI run with nothing to show but "no magic link '
            'appeared".',
      );
    }
  }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

  test('every script that runs the backup container sets the user it runs as',
      () {
    // Task 11.70, replacing task 11.69's "every drill passes --user".
    //
    // **The rule inverted, and that is the point.** 11.69 made the two drill
    // scripts pass `--user` explicitly so they would run on a Linux host at
    // all — the image's own `USER postgres` (uid 70) cannot traverse a drill's
    // 0700 working directory, read the 0600 signing key mounted out of it, or
    // create a file in the backup directory. That fixed the instruments and
    // left the shipped procedure broken, which meant **a green drill was no
    // longer evidence that a real deployment could write an archive.**
    //
    // Now `docker-compose.yml`'s `backup` service declares the `user:` itself,
    // reading TRITRACK_BACKUP_UID/GID, and `scripts/lib/backup_user.sh` sets
    // those to the invoking user. The drills therefore run the same mechanism
    // an operator gets — and this test covers `scripts/backup_db.sh` and
    // `scripts/restore_db.sh` too, which the `--user` rule never could,
    // because those are the commands `server/README.md` actually tells a
    // person to type.
    //
    // The set is derived, not typed: any script that runs the backup profile
    // has to answer this question, including one written next year.
    final scripts = Directory('scripts')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sh'))
        .where((f) => RegExp(r'--profile\s+backup\s+run')
            .hasMatch(joinContinuations(f.readAsStringSync())))
        .toList();

    expect(
      scripts.length,
      greaterThanOrEqualTo(4),
      reason:
          'Expected at least backup_db.sh, restore_db.sh, '
          'backup_restore_drill.sh and verify_h6_archive_forgery.sh to run the '
          'backup profile. Finding fewer means this enumeration has stopped '
          'matching the call sites and is passing vacuously — the failure mode '
          'it exists to prevent.',
    );

    final offenders = <String>[];
    for (final script in scripts) {
      final source = script.readAsStringSync();
      final sourcesTheLibrary = source.contains('scripts/lib/backup_user.sh');
      final setsItInline = source.contains('TRITRACK_BACKUP_UID');
      if (!sourcesTheLibrary && !setsItInline) {
        offenders.add(script.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These scripts run the backup container without saying which user it '
          'runs as, so it falls back to the image\'s own uid 70. On a Linux '
          'host that user can neither create the archive in the operator\'s '
          'backups/ directory nor read the mode-600 signing key, and the '
          'operator sees "pg_dump | age pipeline failed; no archive written" — '
          'a message about the database for a failure entirely about a '
          'directory, which reads like something transient. Add '
          '`. scripts/lib/backup_user.sh` after the .env load.\n'
          'Offenders: ${offenders.join(', ')}',
    );
  });

  test('sourcing scripts/lib/backup_user.sh really does set both variables',
      () {
    // Run, not read — same reasoning as the host_user.sh test above. The test
    // before this one lets a script off the hook the moment it mentions this
    // library, so the library has to be the thing that does the work.
    final scratch = Directory.systemTemp.createTempSync('tt1170-backupuser-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    Directory('${scratch.path}/scripts/lib').createSync(recursive: true);
    File('scripts/lib/backup_user.sh')
        .copySync('${scratch.path}/scripts/lib/backup_user.sh');

    final result = Process.runSync(
      'bash',
      [
        '-c',
        'set -eu; . scripts/lib/backup_user.sh; '
            r'printf "%s:%s" "$TRITRACK_BACKUP_UID" "$TRITRACK_BACKUP_GID"',
      ],
      workingDirectory: scratch.path,
    );
    expect(
      result.exitCode,
      0,
      reason:
          'Sourcing scripts/lib/backup_user.sh failed. Every command that '
          'takes or restores a backup sources it.\n'
          '${result.stdout}\n${result.stderr}',
    );

    final expected = Process.runSync('bash', ['-c', r'printf "%s:%s" "$(id -u)" "$(id -g)"']);
    expect(
      result.stdout.toString().trim(),
      expected.stdout.toString().trim(),
      reason:
          'scripts/lib/backup_user.sh must resolve to the invoking user. That '
          'is the whole mechanism: the backup directory and the mode-600 '
          'signing key belong to whoever runs the command, and on Linux a bind '
          'mount passes that ownership straight through to the container.',
    );
  }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);
}
