import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 11.128. `docker-compose.yml`'s healthcheck runs
/// `/app/bin/server --health-check` every thirty seconds, and **the two things
/// most worth asserting about it are the two least likely to be noticed
/// broken**: that a server whose database is gone still reports *healthy*, and
/// that the sentence it prints says so anyway.
///
/// Both matter for the same reason. `unhealthy` is the slot a restart hangs
/// off, and a restart cannot reach a database that is down — so the exit code
/// deliberately ignores readiness. That is indistinguishable, from the outside,
/// from a probe that simply never learned to ask. The message is what tells the
/// two apart, and Docker keeps it: a `docker compose ps` reading `healthy` on a
/// server where nobody can sign in is the reassuring-but-useless answer this
/// whole task exists to correct.
///
/// Runs the real binary as a subprocess against a real socket, because the
/// coupling under test is between a compose file, a process boundary and an
/// exit code — none of which a unit test of a function would cross.
void main() {
  late HttpServer server;

  /// A handler with no database, which is what `createHandler()` with no
  /// arguments is: the auth and sync routers mount on exactly the condition
  /// `bin/server.dart` mounts them on, so `/ready` reports the database
  /// degraded and `/health` still answers 200.
  setUp(() async {
    server = await shelf_io.serve(
      createHandler(),
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
  });

  tearDown(() => server.close(force: true));

  Future<ProcessResult> healthCheck(int port) => Process.run('dart', [
    'run',
    'bin/server.dart',
    '--health-check',
  ], environment: {'PORT': '$port'});

  test(
    'a server with no database is HEALTHY, and the message says sign-in is '
    'dead anyway',
    () async {
      final result = await healthCheck(server.port);
      final output = result.stdout as String;

      expect(
        result.exitCode,
        0,
        reason:
            'liveness, not readiness, decides this — a restart cannot reach a '
            'database that is down. If this ever becomes 1, Docker starts '
            'reporting an outage it cannot fix as a container fault',
      );
      expect(output, contains('NOT READY'));
      expect(
        output,
        contains('database'),
        reason: 'the health log must name what is degraded, not just that '
            'something is',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('nothing listening is UNHEALTHY, and says a restart is the remedy', () async {
    // A port that was just closed: the one state where restarting the
    // container genuinely is the fix, and the only one this probe fails on.
    final port = server.port;
    await server.close(force: true);

    final result = await healthCheck(port);
    final output = result.stdout as String;

    expect(result.exitCode, 1);
    expect(output, contains('unhealthy'));
    expect(
      output,
      contains('restart'),
      reason: 'the one case where a restart is the remedy is the one case '
          'worth saying so in',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
