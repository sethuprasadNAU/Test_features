/// Something applies §4.7's retention windows, and something says how old the
/// oldest surviving row is (task 11.79).
///
/// ## What went wrong, and why these are the assertions
///
/// `AuditRetentionService.purge()` worked and **nothing called it**, so the
/// windows in `server/README.md` described an intention rather than what was on
/// disk. And the one documented remedy — `dart run bin/purge_audit_logs.dart` —
/// **could not run in the shipped image at all**, which has no Dart SDK and no
/// source. So the fix a person was pointed at was never available to them.
///
/// These tests are about three properties and nothing else:
///
///   1. the sweep is a **declaration in the repository**, not a paragraph an
///      operator is trusted to have acted on;
///   2. the entrypoint is **in the image that actually ships**; and
///   3. what reports on it measures **the age of the oldest surviving row**,
///      never whether a scheduler process exists.
///
/// Task 11.45's rule applies: these assert the property, not the presence of
/// files. "An `audit_retention.dart` exists" would pass against a program that
/// printed nothing and exited 0 — which is why the behaviour of `--check`
/// against real rows is asserted in `audit_log_test.dart`, against a database.
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
/// the next key at the same or a shallower indent. The same reader
/// `backup_schedule_test.dart` uses, deliberately: a textual read of the file
/// an operator actually deploys, rather than a YAML parse that would also
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
  late String service;
  late String dockerfile;
  late String entrypoint;

  setUpAll(() {
    // `dart test` runs from the package root, so the repository root is one up.
    compose = _read('../docker-compose.yml');
    service = _service(compose, 'audit-retention');
    dockerfile = _read('../server/Dockerfile');
    entrypoint = _read('bin/audit_retention.dart');
  });

  group('the sweep happens without anybody remembering to run it', () {
    test('the shipped compose file declares it, and starts it', () {
      expect(
        service,
        contains('--schedule'),
        reason:
            'the `audit-retention` service must actually run the loop; a '
            'service that runs something else schedules nothing',
      );
      expect(
        service,
        contains('/app/bin/tritrack-audit-retention'),
        reason:
            'it must run the compiled entrypoint from the image. A `dart run` '
            'here would be the original defect back: there is no Dart SDK in '
            'the runtime image',
      );
      expect(
        service,
        isNot(contains('profiles:')),
        reason:
            'a retention sweep behind a compose profile is not started by '
            '`docker compose up`, which makes it a step a human performs — '
            'the defect task 11.79 exists to remove',
      );
      expect(
        service,
        contains('restart: unless-stopped'),
        reason:
            'a schedule that does not survive a reboot stops silently on the '
            'first power cut, which is the same harm in a different costume',
      );
    });

    test('the entrypoint is compiled into the image that ships', () {
      // The second, less expected half of the finding: the documented command
      // could not run where it was documented to run. A remedy the operator
      // cannot follow is not a remedy.
      expect(
        dockerfile,
        contains('dart compile exe bin/audit_retention.dart'),
        reason:
            'the runtime stage is a bare debian-slim with no Dart SDK and no '
            'source. If this is not AOT-compiled in the build stage, the only '
            'way to apply retention is on a developer laptop — which is '
            'exactly the state task 11.79 found',
      );
      expect(
        dockerfile,
        contains('/app/bin/tritrack-audit-retention'),
        reason:
            'compiling it and not copying it into the runtime stage would '
            'leave the image exactly as it was',
      );
    });

    test('the loop is given everything it needs to reach the database', () {
      const needed = [
        'POSTGRES_HOST:',
        'POSTGRES_PORT:',
        'POSTGRES_USER:',
        'POSTGRES_PASSWORD:',
        'POSTGRES_DB:',
      ];
      for (final key in needed) {
        expect(
          service,
          contains(key),
          reason:
              '`audit-retention` does not declare $key, so the sweep cannot '
              'connect — and a sweep that cannot connect deletes nothing, '
              'quietly, which is the state this task found',
        );
      }
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
            'the service must be measured by the age of the oldest surviving '
            'row. A healthcheck that pinged the loop, or checked a pid, would '
            'stay green through a wedged sweep, a database the purge cannot '
            'write to and a container somebody stopped — all of which are the '
            'same fact to a person: we are still holding rows we said we '
            'would have deleted',
      );
    });

    test('the check asks the database, never the process table', () {
      for (final forbidden in ['pgrep', 'pidof', '/proc/', 'Process.run']) {
        expect(
          entrypoint,
          isNot(contains(forbidden)),
          reason:
              'the check must not ask whether a process is running — the '
              'whole distinction tasks 11.78 and 11.79 turn on is that a '
              'timer existing and the work having happened are different '
              'facts',
        );
      }
      expect(
        entrypoint,
        contains('measure()'),
        reason: 'it has to read the oldest surviving row to report on it',
      );
    });

    test('"I cannot reach the database" is its own outcome, not green', () {
      expect(
        entrypoint,
        contains('AUDIT RETENTION UNKNOWN'),
        reason:
            'a check that cannot measure must not answer "nothing is past its '
            'window". That is the difference between a check and a '
            'decoration, and this project has been caught by it before',
      );
      expect(
        entrypoint,
        contains('RETENTION HAS STOPPED BEING APPLIED'),
        reason:
            'over-window must be its own sentence and must name what is still '
            'held. "retention is unhealthy" is a message a person cannot act '
            'on',
      );
    });
  });

  group('the loop stays up while it is failing', () {
    test('a failed sweep does not end it', () {
      expect(
        entrypoint,
        contains('while (true)'),
        reason: 'it is a loop, and it has to still be one',
      );
      expect(
        entrypoint,
        contains('SWEEP FAILED'),
        reason:
            'a failed sweep has to say so out loud. A stopped container '
            'reports no health at all, so exiting here would turn a visible '
            'failure into a silent one',
      );
      expect(
        entrypoint.split('_scheduleForever').last,
        isNot(contains('exit(')),
        reason:
            'the loop must not exit when a sweep fails, for the reason above',
      );
    });
  });

  group('the documentation no longer gives a command that cannot run', () {
    late String readme;
    setUpAll(() => readme = _read('README.md'));

    test('nothing points at the old dart-run command', () {
      // Checked over the fenced code blocks — the commands a person copies —
      // rather than over the whole file, because the prose deliberately says
      // what the old command was and why it could not work. Explaining a
      // retired command and offering it are different things, and a check that
      // could not tell them apart would have forced the explanation out.
      final blocks = RegExp(
        '```[^\n]*\n(.*?)```',
        dotAll: true,
      ).allMatches(readme).map((m) => m.group(1)!);
      expect(blocks, isNotEmpty, reason: 'the section has runnable commands');
      for (final block in blocks) {
        expect(
          block,
          isNot(contains('purge_audit_logs')),
          reason:
              'that command needs a Dart SDK and source, and the shipped '
              'image has neither. Offering a remedy the operator cannot '
              'follow is the defect, not a description of it',
        );
      }
      expect(
        File('bin/purge_audit_logs.dart').existsSync(),
        isFalse,
        reason:
            'the old entrypoint was replaced by bin/audit_retention.dart. '
            'Leaving it would leave a second copy of the sweep that the '
            'schedule does not run and no check measures',
      );
    });

    test('and a person is told where to look', () {
      expect(
        readme,
        contains('scripts/audit_retention_status.sh'),
        reason:
            'the floor task 11.78 set and this task copies is that something '
            'visible names the measurement. A control nobody can read the '
            'state of is one nobody can tell has stopped',
      );
    });
  });
}
