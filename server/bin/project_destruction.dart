/// Carries out scheduled project deletions, and says whether any is overdue
/// (task 11.290).
///
/// ## Why this is a container and not "on next sync"
///
/// Michael's design has an owner schedule a project's destruction and every
/// member see the countdown. The one correction that shaped this file: **the
/// server owns the clock and executes on its own timer.** An owner who
/// schedules a deletion and leaves for a field season must not end up with a
/// project that quietly never dies because no device came back to trigger
/// it, and a device with a wrong clock must not be able to move somebody
/// else's deadline. So nothing about a device is involved here: the sweep
/// reads `project_destruction.destroy_at`, compares it to this machine's
/// clock, and deletes.
///
/// It is `bin/audit_retention.dart` one table over, deliberately the same
/// shape rather than a second invention — that file's own header says why a
/// compiled entrypoint in the shipped image beats a README line, and why the
/// loop decides by the rows rather than by remembering when it last ran.
///
/// ## Three modes, and the third is the point
///
///     tritrack-project-destruction              destroy what is due, once
///     tritrack-project-destruction --schedule   the loop docker compose runs
///     tritrack-project-destruction --check      the measurement; exit 1 if
///                                               a deletion is overdue
///
/// `--check` reads **how far past its date the most overdue scheduled
/// deletion is**, and knows nothing about whether the loop is running. A
/// wedged scheduler, a container somebody stopped and a database the sweep
/// cannot write to all produce the same red, because to a person they are the
/// same fact: **we promised somebody a project would be gone on a date, and
/// it is still here.**
///
/// ## Where the failure arrives, and who reads it
///
/// `docker compose ps` shows this container `(unhealthy)`, and
/// `scripts/project_destruction_status.sh` prints the sentence. **Neither is
/// a reader on a schedule** — this project has already lost ten days to a
/// red nobody was looking at (task 11.78's scheduler, 2026-09-12) — so the
/// same sentence is also the last line of every cycle in `docker compose
/// logs`; `scripts/operator_status.sh` names this as a question it does not
/// ask, beside the audit sweep. An owner who scheduled a deletion has a
/// countdown on their own screen and will notice a project that outlives
/// it; that person is the reader this design actually has.
///
/// ## Its last line is its finding (CLAUDE.md, established by task 11.69)
///
/// Docker keeps only the tail of a healthcheck's output, so the last thing
/// every mode prints is what it found, never its own name.
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// How long past its date a scheduled deletion may survive before that is a
/// fault. Two hours: the loop wakes hourly, so a deletion due at 09:00 is
/// carried out by 10:00; a check with no grace would be red for most of
/// every hour and therefore ignored, which is the one failure mode that puts
/// this back where the audit sweep started.
Duration get _grace => Duration(
  hours:
      int.tryParse(
        Platform.environment['TRITRACK_PROJECT_DESTRUCTION_GRACE_HOURS'] ?? '',
      ) ??
      2,
);

/// How often the loop wakes. Hourly by default, like the audit sweep: the
/// grace period is measured in days, and a tighter loop would spend a
/// database connection for nothing.
Duration get _checkInterval => Duration(
  seconds:
      int.tryParse(
        Platform.environment['TRITRACK_PROJECT_DESTRUCTION_CHECK_SECONDS'] ??
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
      'usage: tritrack-project-destruction [--once | --schedule | --check]',
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

ProjectDestructionService _service(Connection connection) =>
    ProjectDestructionService(
      connection,
      policy: ProjectDeletionPolicy.fromEnvironment(),
    );

/// Opens a connection and drops to the app role.
///
/// **The app role, not `tritrack_retention`**, and the difference is the
/// point of that role: retention may read and delete three log tables and
/// nothing else, while destroying a project deletes rows from every synced
/// table. `tritrack_app` already holds `DELETE` on all of them — it is the
/// role the server's own purge runs as — and still cannot touch the audit
/// log, so task 10.83's property survives: nothing this loop can do erases
/// the record that it ran.
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
      'PROJECT DELETION UNKNOWN — no database available '
      '(${error.runtimeType}), so whether any scheduled deletion is overdue '
      'cannot be measured. This does NOT say deletions are being carried '
      'out, and it does not say they are not.',
    );
    return null;
  }
}

Future<void> _sweepOnce(Connection connection) async {
  try {
    final sweep = await _service(connection).destroyDue();
    stdout.writeln(
      'Destroyed ${sweep.projectsDestroyed} '
      '${sweep.projectsDestroyed == 1 ? 'project' : 'projects'} whose date '
      'had passed (${sweep.rowsDeleted} rows).',
    );
  } on Object catch (error) {
    stderr.writeln(
      'SWEEP FAILED (${error.runtimeType}) — nothing was destroyed.',
    );
    exitCode = 1;
  }
}

/// Prints how many deletions are waiting and how far overdue the worst is.
///
/// Returns whether nothing is past its date plus the grace.
Future<bool> _report(Connection connection) async {
  final ProjectDestructionReading reading;
  try {
    reading = await _service(connection).measure();
  } on Object catch (error) {
    stderr.writeln(
      'PROJECT DELETION UNKNOWN — the overdue query failed '
      '(${error.runtimeType}). Nothing here says whether scheduled '
      'deletions are being carried out.',
    );
    return false;
  }

  final grace = _grace;
  final worst = reading.mostOverdueBy;
  if (reading.scheduled == 0 && reading.overdue == 0) {
    stdout.writeln(
      'No project deletion is scheduled on this server — nothing to carry '
      'out.',
    );
    return true;
  }
  if (worst == null || worst <= grace) {
    final one = reading.scheduled == 1;
    stdout.writeln(
      '${reading.scheduled} scheduled '
      '${one ? 'deletion is' : 'deletions are'} waiting '
      'for ${one ? 'its' : 'their'} date'
      '${reading.overdue == 0 ? '' : ', and ${reading.overdue} due within the '
                'last ${worst!.inMinutes} minutes will be carried out on the next '
                'cycle'}. '
      'DELETIONS ARE BEING CARRIED OUT — nothing on this server is past its '
      'date by more than ${grace.inHours}h.',
    );
    return true;
  }
  stdout.writeln(
    'DELETIONS HAVE STOPPED BEING CARRIED OUT — this server is still holding '
    '${reading.overdue} ${reading.overdue == 1 ? 'project' : 'projects'} '
    'whose deletion date has passed'
    '${reading.overdue == 1 ? '' : ', the worst'} by ${worst.inHours}h '
    '(${worst.inDays}d). Somebody was told '
    '${reading.overdue == 1 ? 'that project' : 'those projects'} would be '
    'gone by now, and the sweep that should have destroyed '
    '${reading.overdue == 1 ? 'it' : 'them'} has not run.',
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
  final policy = ProjectDeletionPolicy.fromEnvironment();
  stdout.writeln(
    'tritrack-project-destruction: destroying projects whose scheduled date '
    'has passed; checked every ${interval.inSeconds}s. New deletions wait '
    '${policy.graceDays} days. Overdue is reported at +${_grace.inHours}h '
    'grace — that is the number the healthcheck uses.',
  );

  while (true) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    var failed = false;
    final connection = await _connect();
    if (connection != null) {
      try {
        final sweep = await _service(connection).destroyDue();
        stdout.writeln(
          '--- $stamp destroyed ${sweep.projectsDestroyed} '
          '${sweep.projectsDestroyed == 1 ? 'project' : 'projects'} '
          '(${sweep.rowsDeleted} rows)'
          '${sweep.destroyedProjectIds.isEmpty ? '' : ': ${sweep.destroyedProjectIds.join(', ')}'}.',
        );
        // The last thing each cycle prints is the finding, not the count.
        await _report(connection);
      } on Object catch (error) {
        failed = true;
        stderr.writeln(
          'SWEEP FAILED (${error.runtimeType}) — nothing was destroyed this '
          'cycle. This container stays up so the healthcheck keeps reporting '
          'whether anything is overdue; it will try again in '
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
