/// Something destroys a project on the date its owner scheduled, and
/// something says whether any such date has passed with the project still
/// here (task 11.290).
///
/// The audit sweep's schedule test, one table over — and deliberately the same
/// three properties, because the defect it guards against is the same one:
///
///   1. the sweep is a **declaration in the repository**, started by `docker
///      compose up`, not a step an operator is trusted to have performed;
///   2. the entrypoint is **in the image that actually ships**; and
///   3. what reports on it measures **the rows** — a scheduled deletion whose
///      date has passed and whose project is still here — never whether a
///      loop process exists.
///
/// Why this matters more here than for the audit log: an unrun audit sweep
/// keeps rows past a window nobody was promised. An unrun destruction sweep
/// keeps a project **somebody was shown a date for** — a contributor exported
/// their season on the strength of that countdown, and an owner told a
/// landowner the data would be gone. The behavior of `--check` against real
/// rows is asserted in `test/projects/project_destruction_test.dart`; this
/// file asserts the wiring.
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
  late String serverService;
  late String dockerfile;
  late String entrypoint;

  setUpAll(() {
    compose = _read('../docker-compose.yml');
    service = _service(compose, 'project-destruction');
    serverService = _service(compose, 'server');
    dockerfile = _read('../server/Dockerfile');
    entrypoint = _read('bin/project_destruction.dart');
  });

  group('the sweep happens without anybody remembering to run it', () {
    test('the shipped compose file declares it, and starts it', () {
      expect(service, contains('--schedule'));
      expect(
        service,
        contains('/app/bin/tritrack-project-destruction'),
        reason:
            'it must run the compiled entrypoint from the image; there is no '
            'Dart SDK in the runtime image',
      );
      expect(
        service,
        isNot(contains('profiles:')),
        reason:
            'a sweep behind a compose profile is not started by `docker '
            'compose up`, and a deletion date shown to a whole team would '
            'then depend on an operator remembering a command',
      );
      expect(service, contains('restart: unless-stopped'));
    });

    test('the entrypoint is compiled into the image that ships', () {
      expect(
        dockerfile,
        contains('dart compile exe bin/project_destruction.dart'),
      );
      expect(dockerfile, contains('/app/bin/tritrack-project-destruction'));
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

    test(
      'the server and the sweep read the grace period from the same lines',
      () {
        // The number an owner is shown before committing comes from the
        // server's routes; the number applied comes from the same policy
        // class in both processes. Both containers therefore declare both
        // variables, or one of them would fall back to a default the other
        // does not have.
        for (final key in [
          'TRITRACK_PROJECT_DELETION_GRACE_DAYS:',
          'TRITRACK_BACKUP_KEEP:',
        ]) {
          expect(service, contains(key), reason: 'the sweep must see $key');
          expect(
            serverService,
            contains(key),
            reason: 'the server must see $key',
          );
        }
      },
    );
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
            'the service must be measured by whether a scheduled deletion is '
            'overdue. A healthcheck that pinged the loop would stay green '
            'through a wedged sweep, which to the person who was shown a '
            'date is the same fact as no sweep at all',
      );
      expect(
        healthLine,
        contains('/app/bin/tritrack-project-destruction'),
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
      expect(entrypoint, contains('PROJECT DELETION UNKNOWN'));
      expect(entrypoint, contains('DELETIONS HAVE STOPPED BEING CARRIED OUT'));
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
      expect(readme, contains('scripts/project_destruction_status.sh'));
      final script = _read('../scripts/project_destruction_status.sh');
      expect(
        script,
        contains('project-destruction --check'),
        reason:
            'the script and the healthcheck run the same program, which is '
            'what lets them never disagree',
      );
    });
  });
}
