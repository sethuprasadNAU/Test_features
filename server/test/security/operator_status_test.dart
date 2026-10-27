/// The one command an operator runs, and the one thing it must never do
/// (task 11.140).
///
/// ## What is actually being tested here
///
/// Not that `scripts/operator_status.sh` can collect three answers — that part
/// is easy and a reading of its source would show it. What is worth a test is
/// the property the whole command lives or dies by: **an input that could not
/// answer must be reported as unanswered, never as fine.** A health summary
/// that folds "I could not check" into "nothing to report" is worse than the
/// three separate commands it replaces, because it converts three honest
/// silences into one confident lie.
///
/// So every one of the three inputs is made to fail here, one at a time, and
/// the assertion is the same each time: the section says COULD NOT CHECK, the
/// summary says COULD NOT CHECK, the process does not exit 0, and the words
/// that mean good news are absent.
///
/// ## How the failures are made to happen
///
/// The script takes its compose command from `COMPOSE`, the seam
/// `scripts/audit_retention_status.sh` opened for the gate stack and
/// `scripts/backup_status.sh` now carries too. A stub on that variable is the
/// same technique `backup_ownership_message_test.dart` uses with its `stat`
/// shim: the real script runs, for real, with its own control flow, and only
/// the thing it shells out to is replaced. Nothing here needs Docker.
///
/// ## The last group is about a dependency that is invisible from the other end
///
/// The script recognises "the container cannot read the backup directory" by
/// the sentence `server/backup/freshness.sh` prints, because that script exits
/// 1 for all three of its bad outcomes — Docker's healthcheck has one failing
/// value, so the sentence is what carries the difference. That makes the
/// literal a dependency on a file this one does not own, which is exactly the
/// class CLAUDE.md records from task 11.125: a refactor deleted a line another
/// file was patching and nothing said so. The last group is what says so.
library;

import 'dart:io';

import 'package:test/test.dart';

/// A stand-in for `docker compose`, driven entirely by environment variables so
/// each test can decide which of the three inputs is unable to answer.
const String _stub = r'''
#!/usr/bin/env bash
args="$*"
case "$args" in
  *config\ --format\ json*)
    case "${FAKE_STACK:-alpha}" in
      alpha)
        echo '{"name": "tritrack-alpha", "services": {"backup-scheduler": {"volumes": [{"type": "bind", "source": "/srv/alpha/backups", "target": "/backups"}]}}}'
        exit 0 ;;
      beta)
        echo '{"name": "tritrack-beta", "services": {"backup-scheduler": {"volumes": [{"type": "bind", "source": "/srv/beta/backups", "target": "/backups"}]}}}'
        exit 0 ;;
      broken)
        echo "no configuration file provided" >&2
        exit 1 ;;
    esac ;;
  *tritrack-backup-freshness*)
    case "${FAKE_BACKUP:-fresh}" in
      fresh)
        echo "Newest archive: tritrack-20260902T030000Z.age"
        echo "newest backup: 2h old, within the 48h limit — backups are being taken."
        exit 0 ;;
      unreadable)
        echo "BACKUP FRESHNESS UNKNOWN — this container cannot read /backups, so the age of the newest archive cannot be measured."
        exit 1 ;;
      stale)
        echo "NEWEST BACKUP IS 3 DAYS OLD (72h), past the 48h limit — backups have stopped being taken."
        exit 1 ;;
      absent)
        echo "NO BACKUP HAS EVER BEEN TAKEN — there is no archive in /backups."
        exit 1 ;;
      broken)
        echo "docker: command not found" >&2
        exit 127 ;;
      hang)
        sleep 300 ;;
    esac ;;
  *--degradation-report*)
    case "${FAKE_DEGRADATION:-clean}" in
      clean)
        echo "Durable degradation record: /var/lib/tritrack/degradation.json"
        echo "Server last started: 2026-09-02T01:00:00.000Z"
        echo "The audit log has lost no writes."
        exit 0 ;;
      lost)
        echo "Durable degradation record: /var/lib/tritrack/degradation.json"
        echo "The audit log LOST 6 write(s) — first 2026-09-01T09:00:00.000Z, last 2026-09-01T10:00:00.000Z."
        exit 0 ;;
      missing)
        echo "No durable record at /var/lib/tritrack/degradation.json."
        echo "This does NOT mean nothing has failed."
        exit 0 ;;
      unparseable)
        echo "The record at /var/lib/tritrack/degradation.json could not be read (FormatException)."
        echo "Treat the history as lost, not as empty."
        exit 0 ;;
      unavailable)
        echo "Error response from daemon: container is not running" >&2
        exit 1 ;;
    esac ;;
  *revision_anomalies*)
    case "${FAKE_PINS:-clean}" in
      clean) echo "0||" ; exit 0 ;;
      found) echo "2|1|2026-09-02 10:00:00+00" ; exit 0 ;;
      down)
        echo "Error response from daemon: container postgres is not running" >&2
        exit 1 ;;
    esac ;;
  *psql*)
    case "${FAKE_DB:-quiet}" in
      quiet) echo "0|0|0|" ; exit 0 ;;
      recent) echo "4|9|2|2026-09-02 10:00:00+00" ; exit 0 ;;
      earlier) echo "0|5|1|2026-08-29 10:00:00+00" ; exit 0 ;;
      down)
        echo "Error response from daemon: container postgres is not running" >&2
        exit 1 ;;
    esac ;;
esac
echo "unexpected stub invocation: $args" >&2
exit 99
''';

late Directory _stubDir;
late String _stubPath;

/// Runs the real script with the stub in place. Returns stdout and stderr
/// joined, because an operator reads one terminal.
({String output, int exitCode}) status({
  String backup = 'fresh',
  String degradation = 'clean',
  String db = 'quiet',
  String pins = 'clean',
  String stack = 'alpha',
  int timeoutSeconds = 30,
}) {
  final result = Process.runSync(
    '../scripts/operator_status.sh',
    const [],
    environment: {
      'COMPOSE': _stubPath,
      'FAKE_BACKUP': backup,
      'FAKE_DEGRADATION': degradation,
      'FAKE_DB': db,
      'FAKE_PINS': pins,
      'FAKE_STACK': stack,
      'TRITRACK_STATUS_TIMEOUT': '$timeoutSeconds',
    },
  );
  return (
    output: '${result.stdout}${result.stderr}',
    exitCode: result.exitCode,
  );
}

String _read(String path) => File(path).readAsStringSync();

/// One line of the script's summary block, padded the way its `printf` pads it.
/// Built rather than typed so a column change is a one-line edit here and not
/// ten near-identical string literals to re-count by eye.
String summary(String question, String verdict) =>
    '    ${question.padRight(34)} $verdict';

void main() {
  setUpAll(() {
    _stubDir = Directory.systemTemp.createTempSync('tritrack-compose-stub');
    _stubPath = '${_stubDir.path}/compose';
    File(_stubPath).writeAsStringSync(_stub);
    Process.runSync('chmod', ['0755', _stubPath]);
  });

  tearDownAll(() => _stubDir.deleteSync(recursive: true));

  group('one command answers all four questions', () {
    late String output;
    late int code;

    setUpAll(() {
      final run = status();
      output = run.output;
      code = run.exitCode;
    });

    test('each question is asked and answered', () {
      expect(output, contains('1. BACKUPS'));
      expect(output, contains('2. OUTAGES'));
      expect(output, contains('3. SIGN-IN'));
      expect(output, contains('4. PINNED ROWS'));
      expect(
        output,
        contains('newest backup: 2h old'),
        reason: 'the backup answer must be the real check\'s own sentence, not '
            'a paraphrase of it',
      );
    });

    test('a clean run exits 0 and says so in words', () {
      expect(code, 0);
      expect(
        output,
        contains('The three questions that can fail this command were '
            'answered and none of them found a problem.'),
      );
    });

    test('its last words are the finding, not its own name', () {
      final lines = output
          .trim()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(
        lines.last,
        anyOf(
          contains('The three questions that can fail this command'),
          contains('SOMETHING IS WRONG'),
          contains('COULD NOT BE ANSWERED'),
        ),
        reason: 'CLAUDE.md, task 11.69: an instrument\'s last line is what it '
            'found. The boundary paragraph is printed before the summary for '
            'this reason.',
      );
    });
  });

  group('an input that cannot answer is never reported as healthy', () {
    test('the backup directory is unreadable', () {
      final run = status(backup: 'unreadable');
      expect(run.exitCode, 2);
      expect(run.output, contains('COULD NOT CHECK'));
      expect(
        run.output,
        contains(summary('1. Recent backup?', 'COULD NOT CHECK')),
      );
      expect(
        run.output,
        contains('AT LEAST ONE QUESTION COULD NOT BE ANSWERED'),
      );
      expect(
        run.output,
        isNot(contains('none of them found a problem')),
        reason: 'this is the whole defect the command exists to avoid: an '
            'unreadable directory must not read as a clean bill of health',
      );
      expect(
        run.output,
        contains('NOT the same as having no backups'),
        reason: 'task 11.70: "I cannot read the directory" and "there are no '
            'backups" are different facts and naming the wrong one is what '
            'cost an operator their backups the first time',
      );
    });

    test('the backup check itself fails to run', () {
      final run = status(backup: 'broken');
      expect(run.exitCode, 2);
      expect(run.output, contains('failed to run\n       (exit 127)'));
      expect(
        run.output,
        contains('Nothing above is evidence'),
        reason: 'a check that did not run is not a reading',
      );
    });

    test('the backup check hangs', () {
      final run = status(backup: 'hang', timeoutSeconds: 3);
      expect(run.exitCode, 2);
      expect(run.output, contains('did not finish\n       within 3s'));
      expect(
        run.output,
        contains(summary('1. Recent backup?', 'COULD NOT CHECK')),
      );
    });

    test('the durable degradation record is missing', () {
      final run = status(degradation: 'missing');
      expect(run.exitCode, 2);
      expect(
        run.output,
        contains(summary('2. Refusals during an outage?', 'COULD NOT CHECK')),
      );
      expect(
        run.output,
        contains('nothing here says whether the database has ever been'),
      );
    });

    test('the durable degradation record cannot be parsed', () {
      final run = status(degradation: 'unparseable');
      expect(run.exitCode, 2);
      expect(
        run.output,
        contains(summary('2. Refusals during an outage?', 'COULD NOT CHECK')),
      );
      expect(run.output, contains('Treat the history as lost, not as empty.'));
    });

    test('neither the running server nor a throwaway container answers', () {
      final run = status(degradation: 'unavailable');
      expect(run.exitCode, 2);
      expect(
        run.output,
        contains(summary('2. Refusals during an outage?', 'COULD NOT CHECK')),
      );
    });

    test('the database is down, so the rate-limit count is unread', () {
      final run = status(db: 'down');
      expect(run.exitCode, 2);
      expect(
        run.output,
        contains(
          summary('3. Sign-in limit turning people away?', 'COULD NOT CHECK'),
        ),
      );
      expect(
        run.output,
        contains('Zero rows were NOT'),
        reason: 'the one sentence that separates "no refusals happened" from '
            '"no rows were read"',
      );
    });

    test(
      'a database that is down does not stop the other two being answered',
      () {
        final run = status(db: 'down');
        expect(run.output, contains('newest backup: 2h old'));
        expect(run.output, contains('The audit log has lost no writes.'));
        expect(
          run.output,
          contains(summary('1. Recent backup?', 'OK')),
        );
        expect(
          run.output,
          contains(summary('2. Refusals during an outage?', 'OK')),
        );
      },
    );
  });

  group('question 4 reports a pinned row and never fails the command '
      '(task 11.163, §4.30)', () {
    test('the clean case reads well', () {
      final run = status();
      expect(run.exitCode, 0);
      expect(run.output, contains(summary('4. Any row pinned (revision)?', 'OK')));
      expect(
        run.output,
        contains('No row on this server carries a revision no honest edit'),
      );
      expect(run.output, contains('server has looked and found nothing.'));
      expect(
        run.output,
        isNot(contains('Rows carrying an unexplainable revision')),
        reason: 'the clean case must not read like a near-miss of the '
            'reporting case',
      );
    });

    test('a pinned row is named, but the exit status is unchanged', () {
      final run = status(pins: 'found');
      expect(
        run.exitCode,
        0,
        reason: 'a pinned row is an accepted risk under §4.30 — recorded, '
            'not refused — so this question can never move the exit status '
            'that the other three do',
      );
      expect(
        run.output,
        contains(summary('4. Any row pinned (revision)?', 'PROBLEM')),
      );
      expect(run.output, contains('Rows carrying an unexplainable revision:      2'));
      expect(
        run.output,
        contains('found only by blocking a later edit: 1'),
      );
      expect(
        run.output,
        contains('The three questions that can fail this command were '
            'answered and none of them found a problem.'),
        reason: 'the sentence that decides the exit status must not be '
            'silenced by a finding that cannot affect it',
      );
      expect(
        run.output,
        contains('does NOT change the exit status'),
      );
      expect(
        run.output,
        contains('/diagnostics/revision-anomalies'),
        reason: 'the operator reading this is exactly the person who was '
            'never going to open the console (§4.10)',
      );
    });

    test('the database being unreachable for this question alone does not '
        'change the exit status either', () {
      final run = status(pins: 'down');
      expect(
        run.exitCode,
        0,
        reason: 'question 4 is exempt from the exit-status calculation '
            'entirely — an unanswered pinned-row check is still not a '
            'reason to fail the command',
      );
      expect(
        run.output,
        contains(summary('4. Any row pinned (revision)?', 'COULD NOT CHECK')),
      );
      expect(
        run.output,
        contains('The three questions that can fail this command were '
            'answered and none of them found a problem.'),
      );
    });
  });

  group('a real fault is reported as a fault, not as an unknown', () {
    test('backups have stopped', () {
      final run = status(backup: 'stale');
      expect(run.exitCode, 1);
      expect(run.output, contains(summary('1. Recent backup?', 'PROBLEM')));
      expect(run.output, contains('SOMETHING IS WRONG'));
    });

    test('no backup has ever been taken', () {
      final run = status(backup: 'absent');
      expect(run.exitCode, 1);
      expect(run.output, contains(summary('1. Recent backup?', 'PROBLEM')));
    });

    test('audit writes were lost during an outage', () {
      final run = status(degradation: 'lost');
      expect(run.exitCode, 1);
      expect(
        run.output,
        contains(summary('2. Refusals during an outage?', 'PROBLEM')),
      );
    });

    test('somebody was turned away by the sign-in limit today', () {
      final run = status(db: 'recent');
      expect(run.exitCode, 1);
      expect(run.output, contains('Refusals in the last 24 hours: 4'));
      expect(run.output, contains('across 2 address(es)'));
      expect(
        run.output,
        contains('Somebody was turned away in the last 24 hours.'),
      );
    });

    test('refusals earlier in the week are reported without crying wolf', () {
      final run = status(db: 'earlier');
      expect(run.exitCode, 0);
      expect(run.output, contains('Refusals in the last 7 days:   5'));
      expect(run.output, contains('There were refusals earlier in'));
    });

    test('no address is named', () {
      final run = status(db: 'recent');
      expect(
        run.output,
        isNot(contains('@')),
        reason: 'the count of distinct addresses separates one impatient '
            'person from a flood without putting anybody\'s email in an '
            'operator\'s terminal',
      );
    });

    test(
      'lost audit writes are said to undermine a low rate-limit count',
      () {
        final run = status(degradation: 'lost', db: 'quiet');
        expect(
          run.output,
          contains('a low number'),
          reason: 'during an outage the rows this count reads were never '
              'written, so zero is not evidence that nobody was refused',
        );
      },
    );

    test('a known fault outranks an unknown in the exit status', () {
      final run = status(backup: 'stale', db: 'down');
      expect(
        run.exitCode,
        1,
        reason: 'both are non-zero so neither reads as fine; the more '
            'actionable of the two is the one the status names',
      );
      expect(run.output, contains('COULD NOT CHECK'));
      expect(run.output, contains('SOMETHING IS WRONG'));
    });
  });

  group('the output names which machine it is about (task 11.141)', () {
    test('the host, compose project and backup directory come before any verdict', () {
      final run = status();
      final identityEnd = run.output.indexOf('1. BACKUPS');
      expect(
        identityEnd,
        greaterThan(0),
        reason: 'the identity block must appear before question 1, not after',
      );
      final identity = run.output.substring(0, identityEnd);
      expect(identity, contains('Host:'));
      expect(identity, contains('Compose project:  tritrack-alpha'));
      expect(identity, contains('Backup directory: /srv/alpha/backups'));
    });

    test('a run against a different stack produces a visibly different header',
        () {
      final alpha = status(stack: 'alpha').output;
      final beta = status(stack: 'beta').output;
      expect(alpha, contains('tritrack-alpha'));
      expect(alpha, contains('/srv/alpha/backups'));
      expect(beta, contains('tritrack-beta'));
      expect(beta, contains('/srv/beta/backups'));
      expect(
        alpha,
        isNot(contains('tritrack-beta')),
        reason: 'two stacks must read as two different subjects, not the '
            'same textual output twice',
      );
    });

    test('an unanswerable compose config says so rather than guessing', () {
      final run = status(stack: 'broken');
      expect(run.output, contains('COULD NOT BE DETERMINED'));
      expect(
        run.output,
        isNot(contains('Compose project:  tritrack')),
        reason: 'a config that did not answer must not be reported as any '
            'particular project',
      );
    });
  });

  group('the command states its own boundary', () {
    late String output;
    setUpAll(() => output = status().output);

    test('it says that nothing tells anybody', () {
      expect(output, contains('It does not tell anybody.'));
      expect(output, contains('no email, no push, no alert'));
    });

    test('it says it is a snapshot of four things and not a monitor', () {
      expect(output, contains('snapshot of four things'));
      expect(output, contains('not a monitor of everything'));
    });

    test('it says question 4 cannot fail the command', () {
      expect(
        output,
        contains('Question 4 is also the one question here that can never '
            'fail the command'),
      );
    });

    test('it names things it deliberately does not cover', () {
      expect(output, contains('audit_retention_status.sh'));
      expect(
        output,
        contains('nothing has'),
        reason: 'task 11.80: no archive is copied off this machine, and this '
            'command must not let a reader think it checks that',
      );
    });
  });

  group('the sentences this script keys on still exist where it reads them',
      () {
    // A patch target in a file you do not own is a dependency, and a refactor
    // is exactly when it dies (CLAUDE.md, task 11.125, extended by 11.128).
    // These are the four literals `operator_status.sh` greps for, asserted
    // against the files that print them.
    test('freshness.sh still says it cannot read the directory', () {
      expect(
        _read('../server/backup/freshness.sh'),
        contains('BACKUP FRESHNESS UNKNOWN'),
        reason: 'operator_status.sh distinguishes "I could not read the backup '
            'directory" from "backups have stopped" by this sentence, because '
            'freshness.sh exits 1 for both. Rewording it here without '
            'updating operator_status.sh would silently downgrade an '
            'unanswerable question to a fault, or the reverse.',
      );
    });

    test('freshness.sh still says stale and absent in its own words', () {
      final freshness = _read('../server/backup/freshness.sh');
      expect(freshness, contains('NEWEST BACKUP IS'));
      expect(freshness, contains('NO BACKUP HAS EVER BEEN TAKEN'));
    });

    test('describeDegradationRecord still says all three of its states', () {
      final source = _read('../server/lib/src/security/degradation_record.dart');
      expect(
        source,
        contains('No durable record at'),
        reason: 'a missing record is unanswerable, not clean',
      );
      expect(
        source,
        contains('could not be read'),
        reason: 'an unparseable record is unanswerable, not clean',
      );
      expect(
        source,
        contains('The audit log LOST'),
        reason: 'this is the only phrase that makes the outage a PROBLEM '
            'rather than an OK',
      );
    });

    test('the audit event this command counts is still spelled that way', () {
      expect(
        _read('../server/lib/src/security/audit_log.dart'),
        contains("rateLimitTripped('rate_limit_tripped')"),
        reason: 'operator_status.sh queries auth_audit_log for this exact '
            'event string; a rename here would leave it reporting zero '
            'refusals forever with nothing saying why',
      );
    });

    test('backup_status.sh still honours the COMPOSE seam', () {
      expect(
        _read('../scripts/backup_status.sh'),
        contains(r'COMPOSE=${COMPOSE:-"docker compose"}'),
        reason: 'operator_status.sh points the backup question at the stack it '
            'was given; without this seam it would ask a different stack',
      );
    });

    test('the revision_anomalies table and columns question 4 queries '
        'still exist', () {
      final source = _read('../server/lib/src/sync/revision_anomaly_log.dart');
      expect(
        source,
        contains('CREATE TABLE IF NOT EXISTS revision_anomalies'),
        reason: 'operator_status.sh queries this table by name outside any '
            'ORM; a rename here would leave question 4 reporting COULD NOT '
            'CHECK forever with nothing saying why',
      );
      expect(
        source,
        contains("blocking('blocking')"),
        reason: 'question 4 counts rows with observed_as = \'blocking\' '
            'separately; this is the literal that spells that value',
      );
      expect(source, contains('last_seen_at'));
    });
  });
}
