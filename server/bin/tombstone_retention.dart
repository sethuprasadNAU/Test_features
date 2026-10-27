/// Purges tombstones past the retention window, and says whether any is
/// overdue (task 11.291).
///
/// ## Why this file exists
///
/// `TombstoneRetentionService.purge()` was written for task 10.11 on
/// 2026-08-05, tested against real Postgres, and **called from nowhere for
/// seven weeks.** The guard around it — `StaleCursorException`, the refusal
/// of a device whose position predates a purge — was real and exercised;
/// the purge that would make the refusal necessary had never run, so every
/// server's floor was zero, and the security model described a control that
/// had never operated once. That is `bin/audit_retention.dart`'s founding
/// defect one table over, and this is the same remedy: a compiled entrypoint
/// in the shipped image, started by `docker compose up`, measured by the rows.
///
/// ## The first run is the whole question, and it is answered in the service
///
/// Switching a purge on against a database with history can refuse every
/// device that has been away. The policy that decides who is refused —
/// **age is measured on the server's clock, `received_at`, so the first sweep
/// on any server purges only what that server has itself held for the whole
/// window** — lives in `tombstone_retention_service.dart`'s library comment,
/// beside the code that applies it. This file adds nothing to the policy;
/// `--check` is how an operator sees what the next sweep would do *before*
/// it does it.
///
/// ## Three modes, and the third is the point
///
///     tritrack-tombstone-retention              purge once, print what went
///     tritrack-tombstone-retention --schedule   the loop docker compose runs
///     tritrack-tombstone-retention --check      the measurement; exit 1 if
///                                               a purgeable row is overdue
///
/// `--check` reads **how long the oldest purgeable tombstone has been past
/// the window** — a row the sweep should have deleted and has not — and
/// knows nothing about whether the loop is running. A wedged scheduler, a
/// stopped container and a database the sweep cannot write to all produce
/// the same red, because to a person they are the same fact: **we are still
/// holding rows we said we would have deleted.** A row an active device has
/// not yet received is *not* overdue: keeping it is the design working.
///
/// It also prints what the next sweep would refuse. **That number is the one
/// an operator reads before switching this on for the first time**, and it
/// is why `scripts/tombstone_retention_status.sh` exists as a command
/// separate from `docker compose up`.
///
/// ## Where the failure arrives, and who reads it
///
/// `docker compose ps` shows this container `(unhealthy)`, and
/// `scripts/tombstone_retention_status.sh` prints the sentence. Neither is a
/// reader on a schedule, so the same sentence is also the last line of every
/// cycle in `docker compose logs`, and `scripts/operator_status.sh` names
/// this as a question it does not ask, beside the other two sweeps.
///
/// ## Its last line is its finding (CLAUDE.md, established by task 11.69)
///
/// Docker keeps only the tail of a healthcheck's output, so the last thing
/// every mode prints is what it found, never its own name.
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// How long past the window a purgeable row may survive before that is a
/// fault. 48 hours, for the reason the audit sweep gives: the loop wakes
/// hourly, so a row legitimately sits a little past its window between
/// cycles, and a check with no grace would be red for part of every day and
/// therefore ignored. Two days past a two-year window is a schedule that has
/// stopped, not one that is late.
Duration get _grace => Duration(
  hours:
      int.tryParse(
        Platform.environment['TRITRACK_TOMBSTONE_RETENTION_GRACE_HOURS'] ?? '',
      ) ??
      48,
);

/// How often the loop wakes. Hourly by default, like the other two sweeps:
/// the window is measured in years, and a tighter loop would spend a
/// database connection for nothing.
Duration get _checkInterval => Duration(
  seconds:
      int.tryParse(
        Platform.environment['TRITRACK_TOMBSTONE_RETENTION_CHECK_SECONDS'] ??
            '',
      ) ??
      3600,
);

Future<void> main(List<String> args) async {
  final mode = switch (args) {
    [] || ['--once'] => _Mode.once,
    ['--schedule'] => _Mode.schedule,
    ['--check'] => _Mode.check,
    _ => null,
  };
  if (mode == null) {
    stderr.writeln(
      'usage: tritrack-tombstone-retention [--once | --schedule | --check]',
    );
    exitCode = 64;
    return;
  }

  if (mode == _Mode.schedule) {
    await _scheduleForever();
    return;
  }

  final connection = await _connect();
  if (connection == null) {
    exitCode = 1;
    return;
  }
  try {
    if (mode == _Mode.once) {
      await _sweepOnce(connection);
    } else {
      exitCode = await _report(connection) ? 0 : 1;
    }
  } finally {
    await connection.close();
  }
}

enum _Mode { once, schedule, check }

/// Opens a connection and drops to the app role.
///
/// **The app role, not `tritrack_retention`**, for the reason
/// `bin/project_destruction.dart` gives: that narrower role may read and
/// delete three log tables and nothing else, while purging tombstones
/// deletes rows from every synced table and advances `tombstone_purge_floor`.
/// `tritrack_app` holds exactly that and still cannot touch the audit log,
/// so task 10.83's property survives: nothing this loop can do erases the
/// record that it ran.
///
/// Returns null having already explained itself. "I cannot reach the
/// database" is its own outcome, never reported as "nothing is overdue".
Future<Connection?> _connect() async {
  try {
    final config = DatabaseConfig.fromEnvironment();
    final connection = await Connection.open(
      config.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await ensureServerAppRole(connection);
    await assumeServerAppRole(connection);
    return connection;
  } on Object catch (error) {
    // The type only — never the error, which can carry the connection string
    // (§4.7 rule 5).
    stderr.writeln(
      'TOMBSTONE RETENTION UNKNOWN — no database available '
      '(${error.runtimeType}), so whether any deleted record is past its '
      'window cannot be measured. This does NOT say the window is being '
      'applied, and it does not say it is not.',
    );
    return null;
  }
}

/// One sweep, in one transaction: a project's tombstones and its floor go
/// together or not at all, or a stale device would go unrefused on a project
/// that can no longer describe what it missed.
Future<TombstonePurgeReport> _purge(Connection connection) =>
    connection.runTx((tx) => TombstoneRetentionService(tx).purge());

Future<void> _sweepOnce(Connection connection) async {
  try {
    final sweep = await _purge(connection);
    stdout.writeln(
      'Purged ${sweep.rowsPurged} deleted '
      '${sweep.rowsPurged == 1 ? 'record' : 'records'} past the '
      '${tombstoneRetention.inDays}-day window'
      '${sweep.floorsAdvanced.isEmpty ? '' : ', advancing the floor on '
                '${sweep.floorsAdvanced.length} '
                '${sweep.floorsAdvanced.length == 1 ? 'project' : 'projects'}: '
                '${sweep.floorsAdvanced.keys.join(', ')}'}.',
    );
    // The last line is the finding, not the count.
    await _report(connection);
  } on Object catch (error) {
    stderr.writeln('SWEEP FAILED (${error.runtimeType}) — nothing was purged.');
    exitCode = 1;
  }
}

String _plural(int n, String one, String many) => n == 1 ? one : many;

/// Prints what the server holds, what the next sweep would do, and whether
/// anything is past its window by more than the grace.
///
/// Returns whether nothing purgeable is past the window plus the grace.
Future<bool> _report(Connection connection) async {
  final TombstoneRetentionReading reading;
  try {
    reading = await TombstoneRetentionService(connection).measure();
  } on Object catch (error) {
    stderr.writeln(
      'TOMBSTONE RETENTION UNKNOWN — the measurement failed '
      '(${error.runtimeType}). Nothing here says whether the window is '
      'being applied.',
    );
    return false;
  }

  final grace = _grace;
  final windowDays = reading.window.inDays;

  if (reading.heldTombstones == 0) {
    stdout.writeln(
      'No deleted record is held on this server at all — nothing to purge '
      'and nobody to refuse.',
    );
    return true;
  }

  final untilFirst = reading.untilFirstPurge!;
  stdout.writeln(
    'Holding ${reading.heldTombstones} deleted '
    '${_plural(reading.heldTombstones, 'record', 'records')}; the oldest '
    'reached this server ${(reading.window - untilFirst).inDays}d ago'
    '${untilFirst.isNegative ? '' : ' and becomes purgeable in '
              '${untilFirst.inDays}d'} '
    '(window $windowDays days).',
  );
  if (reading.heldBackByActiveDevices > 0) {
    stdout.writeln(
      '${reading.heldBackByActiveDevices} past the window '
      '${_plural(reading.heldBackByActiveDevices, 'is', 'are')} being kept '
      'because a device that synced inside the window has not received '
      '${_plural(reading.heldBackByActiveDevices, 'it', 'them')} yet — '
      'that is the design, not a fault.',
    );
  }
  if (reading.devicesAlreadyRefused > 0) {
    stdout.writeln(
      '${reading.devicesAlreadyRefused} '
      '${_plural(reading.devicesAlreadyRefused, 'device is', 'devices are')} '
      'already refused: ${_plural(reading.devicesAlreadyRefused, 'its', 'their')} '
      'last recorded position is below a floor an earlier sweep set.',
    );
  }

  final overdue = reading.mostOverdueBy;
  if (overdue == null) {
    stdout.writeln(
      'RETENTION IS BEING APPLIED — nothing on this server is past its '
      '$windowDays-day window, so the next sweep will purge nothing and '
      'refuse nobody.',
    );
    return true;
  }

  final n = reading.eligibleTombstones;
  final projects = reading.eligibleProjectIds.length;
  final refuse = reading.devicesNextSweepWouldRefuse;
  final refuseSentence = refuse == 0
      ? 'The sweep will refuse no device: every recorded position is at or '
            'past what it would purge.'
      : 'The sweep will refuse $refuse ${_plural(refuse, 'device', 'devices')} on '
            '${reading.projectsNextSweepWouldRefuseOn.length} '
            '${_plural(reading.projectsNextSweepWouldRefuseOn.length, 'project', 'projects')} '
            '(${reading.projectsNextSweepWouldRefuseOn.join(', ')}) — '
            '${_plural(refuse, 'a device', 'devices')} that '
            '${_plural(refuse, 'has', 'have')} not synced '
            '${_plural(reading.projectsNextSweepWouldRefuseOn.length, 'that project', 'those projects')} '
            'in $windowDays days, or whose acknowledgement never reached this '
            'server. Each will be told it has been offline too long to sync '
            'safely, and keeps its own records. '
            // Task 11.299's trip-wire, printed only when there is somebody
            // to refuse. The app gives a refused device export and nothing
            // else: task 10.11's recovery flow — getting the records made
            // while away onto the server without also offering stale copies
            // of what was purged — is deliberately unbuilt, and building it
            // was deferred until this number is non-zero somewhere. That
            // deferral has to be read by the person about to make it true,
            // which is whoever reads this line before `docker compose up`.
            'The app then offers that device no way back onto the project: '
            'it can export its records, and that is all. Before this sweep '
            'runs, decide whether to build the recovery flow (development '
            'plan, task 10.11\'s Discovered Scope; task 11.299).';

  if (overdue <= grace) {
    stdout.writeln(
      '$n deleted ${_plural(n, 'record', 'records')} in $projects '
      '${_plural(projects, 'project', 'projects')} '
      '(${reading.eligibleProjectIds.join(', ')}) '
      '${_plural(n, 'is', 'are')} past the window and will be purged on the '
      'next cycle. $refuseSentence',
    );
    stdout.writeln(
      'RETENTION IS BEING APPLIED — nothing on this server is past its '
      '$windowDays-day window by more than ${grace.inHours}h.',
    );
    return true;
  }
  stdout.writeln(
    'RETENTION HAS STOPPED BEING APPLIED — this server is still holding $n '
    'deleted ${_plural(n, 'record', 'records')} in $projects '
    '${_plural(projects, 'project', 'projects')} '
    '(${reading.eligibleProjectIds.join(', ')}) past the $windowDays-day '
    'window, the oldest by ${overdue.inDays}d (${overdue.inHours}h). The '
    'sweep that should have purged ${_plural(n, 'it', 'them')} has not run. '
    '$refuseSentence',
  );
  return false;
}

/// How long to wait after a cycle that could not sweep — capped, for the
/// reason `bin/audit_retention.dart` gives: the first boot of a new stack
/// starts this beside the server, before a single table exists.
Duration _retryAfter(Duration interval) =>
    interval > const Duration(seconds: 300)
    ? const Duration(seconds: 300)
    : interval;

/// The loop `docker compose up` starts. It decides by the rows, not by its
/// own clock, and it stays running when it is failing — a stopped container
/// has no healthcheck, so exiting on failure would replace a red signal with
/// no signal.
Future<void> _scheduleForever() async {
  final interval = _checkInterval;
  stdout.writeln(
    'tritrack-tombstone-retention: purging deleted records this server has '
    'held for ${tombstoneRetention.inDays} days that every active device has '
    'received; checked every ${interval.inSeconds}s. Overdue is reported at '
    '+${_grace.inHours}h grace — that is the number the healthcheck uses.',
  );

  while (true) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    var failed = false;
    final connection = await _connect();
    if (connection != null) {
      try {
        final sweep = await _purge(connection);
        stdout.writeln(
          '--- $stamp purged ${sweep.rowsPurged} deleted '
          '${_plural(sweep.rowsPurged, 'record', 'records')}'
          '${sweep.floorsAdvanced.isEmpty ? '' : ' (floor advanced on: '
                    '${sweep.floorsAdvanced.keys.join(', ')})'}.',
        );
        // The last thing each cycle prints is the finding, not the count.
        await _report(connection);
      } on Object catch (error) {
        failed = true;
        stderr.writeln(
          'SWEEP FAILED (${error.runtimeType}) — nothing was purged this '
          'cycle. This container stays up so the healthcheck keeps reporting '
          'whether anything is past its window; it will try again in '
          '${_retryAfter(interval).inSeconds}s.',
        );
      } finally {
        await connection.close();
      }
    } else {
      failed = true;
    }
    await Future<void>.delayed(failed ? _retryAfter(interval) : interval);
  }
}
