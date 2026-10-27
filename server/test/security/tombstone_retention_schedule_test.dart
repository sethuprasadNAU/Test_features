/// Something purges deleted records after their window, and something says
/// whether any is overdue (task 11.291).
///
/// The audit sweep's schedule test, one table over — and deliberately the same
/// three properties, because the defect it guards against is the same one,
/// and this is the third time this project has met it:
///
///   1. the sweep is a **declaration in the repository**, started by `docker
///      compose up`, not a step an operator is trusted to have performed;
///   2. the entrypoint is **in the image that actually ships**; and
///   3. what reports on it measures **the rows** — a tombstone past the
///      window that the sweep should have deleted and has not — never
///      whether a loop process exists.
///
/// Why this one matters: `TombstoneRetentionService.purge()` was written on
/// 2026-08-05, tested against real Postgres, and **called from nowhere for
/// seven weeks.** The refusal around it was real; the purge was not. Task
/// 11.290 found it with one grep while reusing the service's table order,
/// and its brief had said "the purge already works". The behavior of
/// `--check` against real rows is asserted in
/// `test/sync/tombstone_retention_test.dart`; this file asserts the wiring.
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

/// The body of one compose service — see `audit_retention_schedule_test.dart`
/// for why this is a textual read of the file an operator deploys, and why a
/// `  #` line at two spaces ends the service.
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
    if (line.trim().isNotEmpty && !line.startsWith('    ')) {
      break;
    }
    out.add(line);
  }
  return out.join('\n');
}

void main() {
  late String compose;
  late String service;
  late String dockerfile;
  late String entrypoint;

  setUpAll(() {
    compose = _read('../docker-compose.yml');
    service = _service(compose, 'tombstone-retention');
    dockerfile = _read('../server/Dockerfile');
    entrypoint = _read('bin/tombstone_retention.dart');
  });

  group('the sweep happens without anybody remembering to run it', () {
    test('the shipped compose file declares it, and starts it', () {
      expect(service, contains('--schedule'));
      expect(
        service,
        contains('/app/bin/tritrack-tombstone-retention'),
        reason:
            'it must run the compiled entrypoint from the image; there is no '
            'Dart SDK in the runtime image',
      );
      expect(
        service,
        isNot(contains('profiles:')),
        reason:
            'a sweep behind a compose profile is not started by `docker '
            'compose up`, and the retention window the security model '
            'describes would again depend on an operator remembering a '
            'command — which is exactly the seven weeks this task closes',
      );
      expect(service, contains('restart: unless-stopped'));
    });

    test('the entrypoint is compiled into the image that ships', () {
      expect(
        dockerfile,
        contains('dart compile exe bin/tombstone_retention.dart'),
      );
      expect(dockerfile, contains('/app/bin/tritrack-tombstone-retention'));
    });

    test('the loop is given everything it needs to reach the database', () {
      for (final key in [
        'POSTGRES_HOST:',
        'POSTGRES_PORT:',
        'POSTGRES_USER:',
        'POSTGRES_PASSWORD:',
        'POSTGRES_DB:',
      ]) {
        expect(service, contains(key));
      }
    });

    test('the purge and its floor advance in one transaction', () {
      // A floor that failed to advance after its tombstones were deleted
      // would leave a stale device unrefused on a project that can no longer
      // describe what it missed — the resurrection the whole service exists
      // to prevent.
      expect(entrypoint, contains('runTx('));
      expect(
        entrypoint.split('runTx(').last.split('\n').first,
        contains('purge()'),
      );
    });
  });

  group('what reports measures the rows, not the schedule', () {
    test('the healthcheck runs the measurement and nothing else', () {
      final healthLine = service
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('test:'), orElse: () => '');
      expect(
        healthLine,
        contains('--check'),
        reason:
            'the service must be measured by whether a purgeable tombstone '
            'is overdue. A healthcheck that pinged the loop would stay green '
            'through a wedged sweep, which to the security model is the same '
            'fact as the seven weeks in which nothing ran at all',
      );
      expect(
        healthLine,
        contains('/app/bin/tritrack-tombstone-retention'),
        reason:
            'the healthcheck names the binary the Dockerfile ships; a rename '
            'on either side leaves the container unhealthy forever with '
            'nothing saying why (the compose healthcheck coupling class, '
            'task 11.128)',
      );
    });

    test('the check asks the database, never the process table', () {
      for (final forbidden in ['pgrep', 'pidof', '/proc/', 'Process.run']) {
        expect(entrypoint, isNot(contains(forbidden)));
      }
      expect(entrypoint, contains('measure()'));
    });

    test('"I cannot reach the database" is its own outcome, not green', () {
      expect(entrypoint, contains('TOMBSTONE RETENTION UNKNOWN'));
      expect(entrypoint, contains('RETENTION HAS STOPPED BEING APPLIED'));
    });

    test('the check says what the next sweep would refuse', () {
      // The first-run question. An operator switching this on against a
      // server with history reads this number before `docker compose up`,
      // and the README and the status script both send them here for it.
      expect(entrypoint, contains('devicesNextSweepWouldRefuse'));
      expect(entrypoint, contains('The sweep will refuse'));
    });

    test('and, when it would refuse anybody, that the app has no way back', () {
      // Task 11.299's trip-wire. The app offers a refused device export and
      // nothing else — task 10.11's recovery flow is deliberately unbuilt,
      // and the decision to build it was deferred until a sweep can actually
      // refuse somebody (August 2028 at the earliest on a server whose code
      // dates from August 2026). A deferral written only into a plan
      // document is a reopen trigger nobody reads; this one is printed by the
      // measurement, to the operator, at the moment the condition is true,
      // and it is silent until then.
      expect(entrypoint, contains('no way back onto'));
      expect(entrypoint, contains('decide whether to build the recovery flow'));
      final refuseBranch = entrypoint.split('The sweep will refuse').last;
      expect(
        refuseBranch.split('if (overdue <= grace)').first,
        contains('no way back onto'),
        reason:
            'the sentence belongs to the branch that reports a refusal, not '
            'to the one that reports none',
      );
    });
  });

  group('the loop stays up while it is failing', () {
    test('a failed sweep does not end it', () {
      expect(entrypoint, contains('while (true)'));
      expect(entrypoint, contains('SWEEP FAILED'));
      expect(
        entrypoint.split('_scheduleForever').last,
        isNot(contains('exit(')),
      );
    });
  });

  group('a person is told where to look', () {
    test('the README and the status script name the measurement', () {
      final readme = _read('README.md');
      expect(readme, contains('scripts/tombstone_retention_status.sh'));
      final script = _read('../scripts/tombstone_retention_status.sh');
      expect(
        script,
        contains('tombstone-retention --check'),
        reason:
            'the script and the healthcheck run the same program, which is '
            'what lets them never disagree',
      );
      expect(
        script,
        isNot(contains('--once')),
        reason:
            'a status command that purges is not a status command (task '
            '11.140); this one is what an operator runs to find out what a '
            'sweep WOULD do',
      );
    });

    test('the gate runs the status script, and operator_status names it', () {
      expect(
        _read('../scripts/gate_smoke_test.sh'),
        contains('scripts/tombstone_retention_status.sh'),
      );
      expect(
        _read('../scripts/operator_status.sh'),
        contains('scripts/tombstone_retention_status.sh'),
      );
    });
  });
}
