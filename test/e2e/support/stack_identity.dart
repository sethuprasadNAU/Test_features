import 'dart:io';

import 'e2e_env.dart';

/// Confirms the compose stack answering [E2eEnv.baseUrl] is the one this
/// suite believes it is talking to (finding M-12, Security Model §16.3).
///
/// **The measurement this replaces.** `gate_smoke_test.sh` used to tear its
/// `tritrack-gate` stack down before a run and never after, so its server
/// kept `127.0.0.1:8080` bound long past that run's end. When a
/// `docker-compose.e2e.yml` stack was brought up afterwards for this suite,
/// its own server container failed to bind that port — `docker compose up`
/// printed the bind error, but nothing failed *the suite*, and `curl
/// localhost:8080/health` answered `{"status":"ok"}` regardless, because that
/// was the gate's server still running, backed by the gate's database. The
/// e2e run went red that round, but only because of unrelated data already
/// in that database — the collision itself was diagnosed by a human running
/// `docker ps`, not by anything this suite checked. One refactor away, the
/// same collision produces a run that passes against the wrong stack.
///
/// **What this checks instead of trusting `/health`.** `/health` is
/// deliberately the only unauthenticated route that reveals anything, and it
/// reveals only liveness (`router.dart`) — it cannot be extended to answer
/// "which stack are you" without opening exactly the reconnaissance surface
/// that invariant exists to close. So this asks Docker directly, the same
/// question a human ran `docker ps` to answer: which compose project's
/// container is actually publishing the port [E2eEnv.baseUrl] points at.
abstract final class StackIdentity {
  /// The compose project this suite expects to be talking to.
  ///
  /// Defaults to `tritrack-e2e` — the `-p tritrack-e2e` this project's README
  /// now asks for, mirroring 10.90's `-p tritrack-gate` discipline for the
  /// gate stack so the two can never resolve to the same project by
  /// accident. Overridable for a deployment that names it differently.
  static String get expectedProject =>
      Platform.environment['TRITRACK_E2E_EXPECTED_PROJECT'] ?? 'tritrack-e2e';

  /// Throws [StateError], naming the wrong stack, unless exactly one
  /// container — and it is [expectedProject]'s own — publishes the port
  /// [E2eEnv.baseUrl] points at.
  ///
  /// Requires `docker` on `PATH`; that dependency already exists for anyone
  /// following the README's e2e walkthrough, since nothing else can bring
  /// the stack up in the first place.
  static Future<void> assertConnectedToExpectedStack() async {
    final baseUrl = E2eEnv.baseUrl;
    if (baseUrl == null) {
      // e2e_coverage_guard_test.dart's own "must not skip" test already
      // fails the run for this case; nothing more to say here.
      return;
    }
    final uri = Uri.parse(baseUrl);
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

    final ProcessResult result;
    try {
      result = await Process.run('docker', [
        'ps',
        '--filter',
        'publish=$port',
        '--format',
        '{{.Label "com.docker.compose.project"}}\t{{.Names}}',
      ]);
    } on ProcessException catch (error) {
      throw StateError(
        'Could not run `docker` to confirm which compose project answers '
        'port $port ($error). The e2e suite needs `docker` on PATH to '
        'verify it is talking to its own stack rather than one left over '
        'from a prior run.',
      );
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Could not confirm which compose project answers port $port — '
        '`docker ps` exited ${result.exitCode}: ${result.stderr}',
      );
    }

    final lines = (result.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw StateError(
        'No container is publishing port $port. TRITRACK_E2E_BASE_URL='
        '$baseUrl points nowhere real — bring the e2e stack up first (see '
        'the README\'s "End-to-end integration suite" section).',
      );
    }

    final projects = lines
        .map((line) => line.split('\t').first)
        .toSet();
    if (projects.length != 1 || projects.single != expectedProject) {
      throw StateError(
        'Port $port is published by compose project '
        '${projects.isEmpty ? "<none>" : projects.join(", ")}, not '
        '"$expectedProject" — this suite is about to run against the WRONG '
        'STACK.\n\n'
        'This is finding M-12 (Security Model §16.3): a stack that outlives '
        'its own run can squat this port, and an e2e run against it used to '
        'look like an ordinary run rather than a misdirected one. Tear the '
        'other stack down (`docker compose -p '
        '${projects.isEmpty ? "<project>" : projects.join(" -p ")} down '
        '-v`) and bring up "$expectedProject" (`docker compose -p '
        '$expectedProject -f docker-compose.yml -f docker-compose.e2e.yml '
        'up --build -d`) before running this suite.',
      );
    }
  }
}
