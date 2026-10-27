import 'dart:io';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The half of Gate C finding C-3 that no unit test could have caught, because
/// the defect was not in any Dart file: `docker-compose.yml` defaulted
/// `TRITRACK_ALLOW_CLEARTEXT_LAN=1` and `TRITRACK_ENV=development` behind a
/// `0.0.0.0` publish, so the artifact people actually ran was cleartext on
/// every interface while `security_config_test.dart` sat green.
///
/// §4.10's reasoning — **the default is what gets deployed** — is a claim about
/// shipped configuration, so it is asserted against the shipped configuration.
/// This is the same posture as the app's release-manifest test: read the real
/// file, fail on the real string, so nobody can quietly reintroduce the
/// default while every other test stays green.
///
/// Text assertions rather than a YAML parse on purpose — adding a parser
/// dependency to read four lines would be a worse trade under §3.8's exact-pin
/// policy than matching on the lines themselves.
/// Every `docker-compose*.yml` in the repository root, by filename.
///
/// **Enumerated from the directory, not from a list somebody has to remember
/// to extend.** Two groups below used to hold hand-written filename lists, and
/// a compose file added later would have been silently exempt from both — the
/// same shape as every drift finding this project has logged, and the reason
/// task 10.66 made "fix the class, not the instance" a standing criterion. A
/// fifth file added tomorrow is covered by existing.
Map<String, String> _composeFiles() {
  final files = Directory('..').listSync().whereType<File>().where((f) {
    final name = f.uri.pathSegments.last;
    return name.startsWith('docker-compose') && name.endsWith('.yml');
  }).toList();
  expect(
    files.length,
    greaterThanOrEqualTo(4),
    reason:
        'the repository ships a base compose file and at least three '
        'overrides; finding fewer means this enumeration is looking in the '
        'wrong directory and every assertion below is passing vacuously',
  );
  return {
    for (final file in files)
      file.uri.pathSegments.last: file.readAsStringSync(),
  };
}

/// Whether [content] actually declares the YAML key [key], as opposed to
/// mentioning it in a comment.
///
/// **This distinction is not pedantry; it broke a check.** The two guards below
/// used a bare `contains('ports:')`, so a compose file whose header *explains*
/// why it deliberately declares no `ports:` key was judged to declare one, and
/// failed a rule it satisfies by construction. The same substring reasoning
/// would let a future rename slip past in the other direction. Matching a
/// non-comment line that starts with the key is the property these guards
/// actually mean.
bool _declaresKey(String content, String key) => content
    .split('\n')
    .map((line) => line.trim())
    .any((line) => !line.startsWith('#') && line.startsWith(key));

/// The text of one service's block in a compose file, by name.
///
/// Line-based like everything else here (see the note on `_declaresKey`).
/// Introduced by task 11.70, when `docker-compose.yml` first needed two
/// opposite assertions about two different services: the `server` container
/// must NOT declare a `user:` and the `backup` container MUST. A whole-file
/// assertion cannot express that, and the version that could not would have
/// read the correct change as a violation.
String _service(String content, String name) {
  final lines = content.split('\n');
  final start = lines.indexWhere((l) => l.trimRight() == '  $name:');
  expect(
    start,
    isNot(-1),
    reason:
        'no `$name:` service in this compose file. If it was renamed, the '
        'assertions about it must move with it rather than pass vacuously',
  );
  final out = <String>[];
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    // The next top-level key (`volumes:`) or the next service, both of which
    // start at a shallower or equal indent than this service's own keys.
    if (line.trim().isNotEmpty &&
        !line.startsWith('    ') &&
        !line.startsWith('  #')) {
      break;
    }
    out.add(line);
  }
  return out.join('\n');
}

/// The merged configuration `docker compose -f <files> config` would build —
/// the shape the named `!override` keys actually leave behind, not what a
/// reader has to work out by eye.
///
/// **Task 11.223.** `docker-compose.tls.yml` — the production deployment —
/// used to drop the durable-degradation-record volume without saying so: its
/// `server.volumes: !override` replaces the base file's list rather than
/// merging it, and `server/test/security/shipped_defaults_test.dart`'s own
/// "a named volume covers the directory" test read `docker-compose.yml`
/// alone, so it stayed green through the entire life of that defect — a check
/// that reads a different artifact from the one that ships cannot fail when
/// the shipped one is wrong. This runs the real merge rather than
/// re-implementing `!override`'s semantics in Dart, the same reason the file
/// doc comment above gives for text assertions over a YAML parse: Compose's
/// own merge behaviour is the thing being trusted, not a second
/// implementation of it that could itself drift from what `docker compose`
/// does.
///
/// Every `${VAR:?...}` in either file needs a value or `docker compose
/// config` refuses before it prints anything — none of these need to be
/// *real* credentials or certificates, `config` only renders the merged YAML,
/// it never starts a container or reads a file these variables might name.
/// Passed as explicit environment entries rather than left to whatever `.env`
/// a developer's checkout happens to have, so this is deterministic whether
/// or not `.env` sets the TLS-only values a plain `docker-compose.yml` run
/// never needs.
String _mergedConfig(List<String> files) {
  final result = Process.runSync(
    'docker',
    [
      'compose',
      for (final file in files) ...['-f', file],
      'config',
    ],
    workingDirectory: '..',
    environment: {
      'POSTGRES_USER': 'placeholder',
      'POSTGRES_PASSWORD': 'placeholder',
      'POSTGRES_DB': 'placeholder',
      'TRITRACK_TLS_ORIGIN_CERT': '/dev/null',
      'TRITRACK_TLS_ORIGIN_KEY': '/dev/null',
      'TRITRACK_TLS_DOMAIN': 'localhost',
    },
  );
  expect(
    result.exitCode,
    0,
    reason:
        'docker compose config -f ${files.join(' -f ')} failed: '
        '${result.stderr}',
  );
  return result.stdout as String;
}

void main() {
  late String compose;
  late String entryPoint;

  setUpAll(() {
    // `dart test` runs from the package root, so the repository root is one up.
    final file = File('../docker-compose.yml');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'docker-compose.yml is the artifact this test exists to constrain; '
          'if it moved, this test must move with it rather than be deleted',
    );
    compose = file.readAsStringSync();
    entryPoint = File('bin/server.dart').readAsStringSync();
  });

  // Task 11.128. The healthcheck's `test:` string names a flag implemented in
  // another file, in another language, in a directory this one does not own —
  // the coupling task 11.125 found in `verify_11_85_broken_control.py`, where a
  // refactor deleted a line a harness patched and the harness's own guard was
  // the only thing that noticed. **Here nothing would notice**: rename the flag
  // and the binary prints a usage-less nothing, exits 0 as a normal server
  // start would not, and the container reports whatever that produces — the
  // failure is a container quietly stuck at `unhealthy` forever, which is
  // exactly the kind of red nobody re-derives. So the two ends are asserted
  // against each other here, where a rename of either fails immediately.
  group('the server healthcheck is wired to a flag that exists', () {
    test('docker-compose.yml gives the server service a healthcheck', () {
      expect(
        compose,
        contains('/app/bin/server --health-check'),
        reason:
            'the server service must have a healthcheck, and it must invoke '
            'the binary already in the image rather than a curl the '
            'debian-slim runtime stage does not have',
      );
    });

    test('bin/server.dart implements that flag', () {
      expect(
        entryPoint,
        contains("args.contains('--health-check')"),
        reason:
            'docker-compose.yml runs `/app/bin/server --health-check` every 30 '
            'seconds. If this flag is renamed, the healthcheck does not fail '
            'loudly — the container simply reports unhealthy forever and '
            'nothing says why',
      );
    });

    test('the healthcheck asks /health, never /ready', () {
      // The whole liveness/readiness split in one assertion. `unhealthy` is
      // the slot a restart hangs off, and a restart cannot reach a database
      // that is down — so readiness must never decide it. See
      // `server/lib/src/readiness.dart`.
      final healthcheckBlock = compose.substring(
        compose.indexOf('healthcheck:', compose.indexOf('  server:')),
      );
      final testLine = healthcheckBlock.substring(
        0,
        healthcheckBlock.indexOf('\n    ports:'),
      );
      expect(
        testLine,
        isNot(contains('/ready')),
        reason:
            "a container healthcheck driven by readiness would make Docker's "
            'remedy — a restart — the response to an unreachable database',
      );
    });
  });

  // Task 11.129, and it is task 11.128's rule one file over: **a string in one
  // file naming something another file implements is a dependency, and a
  // refactor is exactly when it dies.** Four ends have to agree for the durable
  // degradation record to exist at all — the default path in Dart, the path
  // compose passes, the volume mounted over that directory, and the directory
  // the image creates — and **not one of them fails loudly when they stop
  // agreeing.** The record simply is not there during the outage it exists for,
  // which is the one moment nobody can go and check.
  group('the durable degradation record is actually mounted somewhere', () {
    late String dockerfile;

    setUpAll(() {
      dockerfile = File('Dockerfile').readAsStringSync();
    });

    test('compose passes the same default path the code uses', () {
      expect(
        compose,
        contains(
          'TRITRACK_DEGRADATION_PATH: '
          '\${TRITRACK_DEGRADATION_PATH:-$defaultDegradationPath}',
        ),
        reason:
            'if these drift, the server writes its record somewhere the '
            'volume below does not cover and it is lost on the next '
            '`docker compose up --build`',
      );
    });

    test('a named volume covers the directory the record is written to', () {
      final directory = defaultDegradationPath.substring(
        0,
        defaultDegradationPath.lastIndexOf('/'),
      );
      expect(
        compose,
        contains('- tritrack_server_state:$directory'),
        reason:
            'without this the record lives in the container layer and dies '
            'with the container — durable against a dead database, which is '
            'the point, but not against the restart that follows it',
      );
      expect(
        compose,
        contains('\n  tritrack_server_state:'),
        reason: 'the named volume must also be declared under `volumes:`',
      );
    });

    // Task 11.223. The two assertions above read `docker-compose.yml` alone,
    // and stayed green through the entire life of the actual defect: the TLS
    // overlay's `server.volumes: !override` replaced this mount out of the
    // deployment that actually ships, for two weeks, without either
    // assertion above ever noticing — a check that reads a different
    // artifact from the one that ships cannot fail when the shipped one is
    // wrong. This reads the merged configuration instead, the same way
    // `docker compose -f docker-compose.yml -f docker-compose.tls.yml up`
    // would actually see it.
    test('the merged production deployment still mounts it — `!override` on '
        '`server.volumes:` in docker-compose.tls.yml replaces the whole list '
        'rather than merging it, and it silently dropped this exact mount for '
        'two weeks before anybody noticed (task 11.223)', () {
      final directory = defaultDegradationPath.substring(
        0,
        defaultDegradationPath.lastIndexOf('/'),
      );
      final merged = _mergedConfig([
        'docker-compose.yml',
        'docker-compose.tls.yml',
      ]);
      expect(
        merged,
        contains(
          RegExp(
            '- type: volume\\s*\\n\\s*source: tritrack_server_state\\s*\\n'
            '\\s*target: ${RegExp.escape(directory)}',
          ),
        ),
        reason:
            'without this the record lives in the container layer and '
            'dies with the container — durable against a dead database, '
            'which is the point, but not against the restart that '
            'follows it. `docker compose config` renders every mount in '
            'long form (`type: volume`, `source:`, `target:`), not the '
            'short `source:target` syntax either compose file writes',
      );
      expect(
        merged,
        contains('\n  tritrack_server_state:'),
        reason:
            'the named volume must survive into the merged top-level '
            '`volumes:` too — Compose drops a named volume from that '
            'list entirely if no service in the merged configuration '
            'still mounts it',
      );
    });

    // The named-volume choice is itself the control, not a preference. A bind
    // mount passes host ownership straight through on Linux, which is what
    // made task 11.70's backup silently unwritable and task 11.125's two
    // status commands disagree about the same backups.
    test('it is a named volume, never a bind mount', () {
      final directory = defaultDegradationPath.substring(
        0,
        defaultDegradationPath.lastIndexOf('/'),
      );
      final mounts = RegExp(
        r'- *([^\s]+):' + RegExp.escape(directory),
      ).allMatches(compose).map((match) => match.group(1)!).toList();
      expect(mounts, isNotEmpty);
      for (final source in mounts) {
        expect(
          source,
          isNot(anyOf(contains('/'), contains(r'$'))),
          reason:
              'a host path or a variable here is a bind mount, and a bind '
              'mount passes host ownership through on Linux — tasks 11.70 '
              'and 11.125 both cost a day to that exact shape',
        );
      }
    });

    // Task 11.228. The TLS test above reads one overlay by name; the base
    // `server` service's `volumes:` gained the degradation-record mount on
    // 2026-09-02 (task 11.129), and `docker-compose.e2e.yml` and
    // `docker-compose.dev-lan.yml` — both of which `!override` the same key —
    // silently stopped mounting it for weeks before task 11.223's own sweep
    // found them, the exact defect 11.223 fixed in the TLS overlay. A guard
    // that reads one overlay is the same shape as the guard it replaced,
    // which read only the base file.
    //
    // **What every overlay is checked against, and why it is a decision
    // rather than a derivation.** Whether the volume belongs in a given
    // overlay is a judgement about that stack, not something the filename can
    // answer — `docker-compose.e2e.yml`'s comment on the mount states in
    // writing why a throwaway stack still wants it (nothing in `test/e2e/`
    // ever makes Postgres unreachable, and a red run is already kept up
    // rather than torn down for the same reason), and
    // `docker-compose.dev-lan.yml`'s states why a developer's LAN stack is
    // simply production at lower stakes. So this list is the record of those
    // decisions, not a guess: an overlay reaching `main` without an entry
    // here fails loudly rather than passing by omission, which is the failure
    // this whole group exists to close.
    //
    // **What is derived, so the list above cannot go stale by omission:**
    // which files count as overlays at all. `_composeFiles()` already
    // enumerates every `docker-compose*.yml` by filename rather than from a
    // list; this reuses it, so a fifth overlay dropped into the repository
    // tomorrow is walked into this group automatically and fails until
    // somebody adds its verdict below — which is exactly how a fourth overlay
    // gets caught.
    group('every overlay\'s decided outcome for the degradation-record '
        'volume, not just the production one', () {
      // The decision per overlay, each backed by a comment in that file
      // saying why. `docker-compose.yml` (the base) is excluded: it is what
      // every decision here is measured against, not an overlay itself.
      const decisions = {
        'docker-compose.tls.yml': true, // task 11.223: the production shape.
        'docker-compose.e2e.yml': true, // task 11.228: see the file's own
        // comment on the mount — nothing in the e2e suite ever makes this
        // record non-empty, and a red run is kept up rather than torn down
        // regardless of the volume, so mounting it costs nothing and matches
        // production.
        'docker-compose.dev-lan.yml': true, // task 11.228: a developer's
        // stack on a real network is production at lower stakes; no reason
        // for it to lose the record production keeps.
        'docker-compose.server-test.yml': true, // never touches
        // `server.volumes:` at all, so it inherits the base mount
        // undisturbed — recorded so an overlay that starts overriding that
        // key without updating this map fails here instead of shipping
        // silently degraded, the same way the other three would have.
      };

      // `_composeFiles()` calls `expect` to refuse an empty directory listing,
      // which only `test()` may do — this walks the same directory without
      // it, at group-registration time, and the "found something" half of
      // that guarantee is asserted separately below instead.
      final overlays = Directory('..')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where(
            (name) =>
                name.startsWith('docker-compose') &&
                name.endsWith('.yml') &&
                name != 'docker-compose.yml',
          )
          .toList();

      test('found at least one overlay to check (a derivation that finds '
          'nothing is indistinguishable from one checking nothing)', () {
        expect(overlays, isNotEmpty);
      });

      for (final overlay in overlays) {
        test(overlay, () {
          expect(
            decisions,
            contains(overlay),
            reason:
                '$overlay has no recorded decision in this test\'s '
                '`decisions` map. Every overlay must state, in its own file '
                'and in this map, whether the durable degradation-record '
                'volume belongs in it — an overlay with no decision must '
                'fail here rather than pass by omission (task 11.228).',
          );
          final expectMounted = decisions[overlay]!;
          final directory = defaultDegradationPath.substring(
            0,
            defaultDegradationPath.lastIndexOf('/'),
          );
          final merged = _mergedConfig(['docker-compose.yml', overlay]);
          final mountPattern = RegExp(
            '- type: volume\\s*\\n\\s*source: tritrack_server_state\\s*\\n'
            '\\s*target: ${RegExp.escape(directory)}',
          );
          if (expectMounted) {
            expect(
              merged,
              contains(mountPattern),
              reason:
                  '$overlay is decided to mount the durable '
                  'degradation-record volume and does not, in the merged '
                  'configuration `docker compose -f docker-compose.yml -f '
                  '$overlay config` would actually run — this is the '
                  'exact defect tasks 11.223 and 11.228 fixed',
            );
            expect(
              merged,
              contains('\n  tritrack_server_state:'),
              reason:
                  'the named volume must survive into the merged '
                  'top-level `volumes:` too',
            );
          } else {
            expect(
              merged,
              isNot(contains(mountPattern)),
              reason:
                  '$overlay is decided NOT to mount the volume, but '
                  'the merged configuration mounts it anyway — update the '
                  'decision above if that is now intentional, or the '
                  'overlay if it is not',
            );
          }
        });
      }
    });

    test('the image creates that directory', () {
      final directory = defaultDegradationPath.substring(
        0,
        defaultDegradationPath.lastIndexOf('/'),
      );
      expect(
        dockerfile,
        contains('mkdir -p $directory'),
        reason:
            'so a deployment that forgets the volume still records something '
            'rather than nothing',
      );
    });

    test('bin/server.dart implements the flag the runbook tells an operator '
        'to type', () {
      expect(
        entryPoint,
        contains("args.contains('--degradation-report')"),
        reason:
            'server/README.md tells an operator to run `/app/bin/server '
            '--degradation-report` during an outage. If this flag is renamed '
            'the binary prints nothing and starts a second server instead, '
            'and the person finds that out at the worst possible moment',
      );
    });

    // Task 11.158, the same coupling a third time.
    // `measure_numeric_population.sh` is the one command Michael is told to
    // run to decide whether a stricter numeric rule can ship, and it names a
    // flag implemented in this binary. A rename would not fail loudly — the
    // binary would print nothing and start a second server, and the operator
    // would read that as "the measurement came back empty".
    test('bin/server.dart implements the flag the measurement script types', () {
      final script = File('../scripts/measure_numeric_population.sh');
      expect(
        script.existsSync(),
        isTrue,
        reason:
            'scripts/measure_numeric_population.sh is the artifact this test '
            'constrains; if it moved, this test moves with it',
      );
      expect(
        script.readAsStringSync(),
        contains('/app/bin/server --numeric-population'),
      );
      expect(
        entryPoint,
        contains("args.contains('--numeric-population')"),
        reason:
            'scripts/measure_numeric_population.sh runs `/app/bin/server '
            '--numeric-population`. If this flag is renamed the binary prints '
            'nothing and starts a second server, and an operator reads that '
            'as a measurement that found nothing',
      );
    });
  });

  group('docker-compose.yml cannot ship cleartext to the LAN by default', () {
    test('the server port is published to loopback unless overridden', () {
      // The one line that decides who can reach this server. Before 10.22 it
      // read `- "0.0.0.0:${SERVER_PORT:-8080}:8080"`.
      expect(
        compose,
        contains(r'"${SERVER_PUBLISH_ADDRESS:-127.0.0.1}:'),
        reason: 'the default publish address must be loopback',
      );
      expect(
        compose,
        isNot(contains('- "0.0.0.0:')),
        reason: 'a hardcoded 0.0.0.0 publish is the C-3 finding itself',
      );
    });

    test('TRITRACK_ENV does not default to development', () {
      // A shipped `:-development` default means the production refusals are
      // off before anyone has made a decision — which is exactly what §4.10
      // says a default is.
      expect(compose, isNot(contains(r'${TRITRACK_ENV:-development}')));
      expect(compose, contains(r'TRITRACK_ENV: ${TRITRACK_ENV:-}'));
    });

    test('the diagnostics console is still off by default', () {
      // §4.10's original application, kept under the same guard now that there
      // is one. Regression cover, not new ground.
      expect(compose, contains(r'${TRITRACK_DIAGNOSTICS_ENABLED:-false}'));
      expect(compose, contains(r'${TRITRACK_DIAGNOSTICS_ALLOW_REMOTE:-false}'));
    });

    test('Postgres is still never published', () {
      // §2.2's opportunistic-scanner finding. The base file has exactly one
      // `ports:` block, and it belongs to `server`.
      expect(
        RegExp('^ *ports:', multiLine: true).allMatches(compose),
        hasLength(1),
      );
      expect(compose, isNot(contains('5432:5432')));
    });
  });

  group('docker-compose.server-test.yml cannot re-render the public port '
      '(task 10.57, I-9)', () {
    late String serverTestOverride;

    setUpAll(() {
      final file = File('../docker-compose.server-test.yml');
      expect(file.existsSync(), isTrue);
      serverTestOverride = file.readAsStringSync();
    });

    test('the server service is overridden, not left to fall through', () {
      // Before this task, this file touched only `postgres:` — `server:`
      // was absent entirely, so its `ports:` fell straight through to the
      // base file's `${SERVER_PUBLISH_ADDRESS:-127.0.0.1}` and a `.env`
      // opted into the LAN walkthrough re-rendered `server: 0.0.0.0:8080`
      // in the merged config, G-2's exact shape (Security Model §11.8's I-8). Compose
      // merges sequence-typed keys like `ports:` by concatenation, so
      // `!override` — not just the presence of a `server:` block — is what
      // makes this a replacement rather than an addition.
      expect(
        RegExp(
          r'^  server:\s*\n\s*ports:\s*!override',
          multiLine: true,
        ).hasMatch(serverTestOverride),
        isTrue,
        reason:
            'expected a `server: / ports: !override` block, verified '
            'as text here and by rendering the merged config with '
            '`docker compose -f docker-compose.yml -f '
            'docker-compose.server-test.yml config` (see task 10.57\'s '
            'Discovered Scope entry for the live render)',
      );
    });

    test('the override is hardcoded to loopback, not the LAN variable', () {
      expect(
        serverTestOverride,
        contains('"127.0.0.1:\${SERVER_PORT:-8080}:8080"'),
      );
      // Checks the live `- "..."` port mapping line, not the explanatory
      // comment above it, which names the variable deliberately to say why
      // it must never appear here.
      final portLine = serverTestOverride
          .split('\n')
          .firstWhere((line) => line.trim().startsWith('- "127.0.0.1:'));
      expect(
        portLine,
        isNot(contains('SERVER_PUBLISH_ADDRESS')),
        reason:
            'reading the LAN-opt-in variable at all would reopen '
            'exactly what this override exists to prevent',
      );
    });
  });

  // Task 10.62, finding J-2. The server cannot see how its host published it,
  // so the compose files tell it, and that makes TRITRACK_PUBLISH_ADDRESS a
  // shipped-configuration control in exactly the way `ports:` already is —
  // same file, same drift risk, same class of miss. Enumerated over every
  // compose file rather than asserted where the bug reproduced, per §12.11.
  group('every compose file declares how the host publishes the server', () {
    late Map<String, String> overrides;

    setUpAll(() {
      overrides = _composeFiles()..remove('docker-compose.yml');
    });

    test('the base file mirrors its own publish address into the container', () {
      // Verbatim from `ports:` below it. If these two ever disagree the server
      // is reasoning about an exposure it does not have, in one direction or
      // the other.
      expect(
        compose,
        contains(
          r'TRITRACK_PUBLISH_ADDRESS: ${SERVER_PUBLISH_ADDRESS:-127.0.0.1}',
        ),
      );
    });

    test('every override that pins ports also pins the publish address', () {
      // The class, not the instance: an override that hardcodes a loopback
      // port while letting this variable fall through from the base file hands
      // the server a `0.0.0.0` from someone's `.env` and makes it refuse to
      // start over an exposure the override already removed. Only the
      // overrides that pin `ports:` are subject to it — task 11.35's
      // `docker-compose.dev-lan.yml` deliberately pins neither, so that the
      // exposure decision stays in the one `.env` line task 10.22 put it in.
      for (final entry in overrides.entries) {
        if (!_declaresKey(entry.value, 'ports:')) continue;
        expect(
          _declaresKey(entry.value, 'TRITRACK_PUBLISH_ADDRESS:'),
          isTrue,
          reason:
              '${entry.key} overrides the published port, so it must also say '
              'what it published to — otherwise the value falls through from '
              'docker-compose.yml, where it follows SERVER_PUBLISH_ADDRESS',
        );
        expect(
          entry.value,
          isNot(
            contains(r'TRITRACK_PUBLISH_ADDRESS: ${SERVER_PUBLISH_ADDRESS'),
          ),
          reason:
              '${entry.key} must hardcode the value for the same reason it '
              'hardcodes the port: no .env value may change it',
        );
      }
    });

    test(
      'the loopback overrides say loopback, and the TLS overlay says none',
      () {
        expect(
          overrides['docker-compose.e2e.yml'],
          contains('TRITRACK_PUBLISH_ADDRESS: 127.0.0.1'),
        );
        expect(
          overrides['docker-compose.server-test.yml'],
          contains('TRITRACK_PUBLISH_ADDRESS: 127.0.0.1'),
        );
        // `ports: !override []` — no host port maps to the server at all, so the
        // only way in is the proxy, which is what this file's allowlist answers.
        expect(
          overrides['docker-compose.tls.yml'],
          contains('TRITRACK_PUBLISH_ADDRESS: none'),
        );
      },
    );
  });

  // Task 11.35. The LAN multi-device overlay exists because the only file that
  // turned the readable magic-link sender on also pinned the port back to
  // loopback, so nobody could sign in on a stack a phone could reach. The
  // hazard in fixing that is obvious and worth pinning down: a file that hands
  // out live sign-in tokens must not also be the file that decides who can
  // reach the server.
  group('a compose file that drops magic links to disk stays out of the '
      'exposure decision', () {
    late Map<String, String> composeFiles;

    setUpAll(() {
      composeFiles = _composeFiles();
    });

    test('the LAN overlay turns the file sender on', () {
      final devLan = composeFiles['docker-compose.dev-lan.yml'];
      expect(
        devLan,
        isNotNull,
        reason:
            'docker-compose.dev-lan.yml is what makes a two-device test '
            'possible to run; if it moved, this test moves with it',
      );
      expect(devLan, contains('TRITRACK_DEV_MAGIC_LINK_DIR:'));
    });

    test('and says nothing about who can reach the server', () {
      // The rule for the class, not for this file: any override that ships a
      // token-retrieval path must leave `ports:` and the publish address
      // exactly where task 10.22 put them — in one deliberate `.env` line —
      // rather than quietly widening or narrowing them alongside a
      // convenience. The e2e override is exempt because it narrows to
      // loopback and pins both together, which the group above enforces.
      for (final entry in composeFiles.entries) {
        if (entry.key == 'docker-compose.e2e.yml') continue;
        if (!_declaresKey(entry.value, 'TRITRACK_DEV_MAGIC_LINK_DIR:')) {
          continue;
        }
        expect(
          _declaresKey(entry.value, 'ports:'),
          isFalse,
          reason:
              '${entry.key} drops live sign-in tokens on disk, so it must not '
              'also be the file that decides the publish address',
        );
        expect(
          _declaresKey(entry.value, 'TRITRACK_PUBLISH_ADDRESS:'),
          isFalse,
          reason: '${entry.key}: same reason as the port',
        );
      }
    });

    // Task 11.69. The link file is mode 600 on purpose — it is a live sign-in
    // credential and §4.7 forbids logging one, so "only its owner can read it"
    // is the affordance that replaces printing it. That leaves ownership as
    // the thing that has to be right, and on a Linux host a bind mount passes
    // ownership straight through: a server container running as root writes
    // `root:root 0600` and the developer who asked for the link cannot open
    // it. Docker Desktop remaps it, which is why this held for months on one
    // machine and broke on the first clean runner — eleven gate instruments
    // and a whole workflow, all on `Errno 13`.
    test('a file that hands out sign-in links runs the server as the reader', () {
      for (final entry in composeFiles.entries) {
        if (!_declaresKey(entry.value, 'TRITRACK_DEV_MAGIC_LINK_DIR:')) {
          continue;
        }
        expect(
          _declaresKey(entry.value, 'user:'),
          isTrue,
          reason:
              '${entry.key} writes a mode-600 sign-in credential into a bind '
              'mount, so it must say which user writes it — otherwise the '
              'file is root-owned on every host that does not remap ownership '
              'and nobody can read the link the file exists to provide',
        );
        final userLine = entry.value
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.startsWith('user:'));
        expect(
          userLine,
          contains(r'${TRITRACK_DEV_UID'),
          reason:
              '${entry.key} must read the invoking user from the environment '
              '(scripts/lib/host_user.sh sets it). A literal uid here would be '
              'right on exactly one machine',
        );
      }
    });

    test('and the shipped base file still runs the SERVER as it always did', () {
      // The other half, and the one that matters more: whatever the
      // development overlays do, `docker-compose.yml` is the file a real
      // deployment's configuration resembles. It retrieves no token at all
      // (`resolveEmailSender` falls back to `NullEmailSender` without
      // TRITRACK_DEV_MAGIC_LINK_DIR), and task 11.69 must not have changed how
      // any of its services run. Asserted rather than described, because "this
      // only affects development" is the claim every one of these overlays
      // makes in a comment.
      //
      // Narrowed from the whole file to the `server` service by task 11.70,
      // which added a `user:` to the `backup` service for an unrelated
      // reason — see the test below. A whole-file assertion would have made
      // that change look like this one being violated, and the two are
      // opposite facts about different containers.
      expect(
        _declaresKey(_service(compose, 'server'), 'user:'),
        isFalse,
        reason:
            'docker-compose.yml declares no `user:` on its `server` service '
            'and task 11.69 did not add one — the magic-link ownership fix '
            'lives in the development and end-to-end overlays only',
      );
    });

    // Task 11.70. The opposite fact about the other container, and it belongs
    // in the shipped base file precisely because the shipped procedure is what
    // was broken.
    //
    // `server/backup/Dockerfile` ends `USER postgres` (uid 70) — right, since
    // this container needs no root. But uid 70 is a stranger on the host, and
    // `server/README.md` tells the operator to create the backup directory as
    // themselves and the signing key mode 600. On Linux a bind mount passes
    // ownership straight through, so uid 70 could neither write the archive
    // nor read the key, and `backup.sh` reported it as a pg_dump failure. An
    // operator following the instructions saw what read like a transient
    // database error and had every reason to believe they had encrypted
    // backups when no archive had ever been written.
    test('and the shipped base file says which user takes the BACKUP', () {
      final backup = _service(compose, 'backup');
      expect(
        _declaresKey(backup, 'user:'),
        isTrue,
        reason:
            'docker-compose.yml\'s `backup` service mounts a host directory '
            'and a mode-600 signing key, so it must say which user writes '
            'them. Without it the container is the image\'s uid 70 and, on '
            'every host that does not remap ownership, no archive is written '
            'at all — reported as `pg_dump | age pipeline failed`',
      );
      final userLine = backup
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.startsWith('user:'));
      expect(
        userLine,
        contains(r'${TRITRACK_BACKUP_UID'),
        reason:
            'the backup user must be read from the environment '
            '(scripts/lib/backup_user.sh sets it to the invoking user, and '
            'scripts/backup_db.sh and scripts/restore_db.sh source it). A '
            'literal uid here would be right on exactly one machine',
      );
      expect(
        userLine,
        isNot(contains(':-0}')),
        reason:
            'the fallback must not be root: it would work, and leave every '
            'archive on the host owned by root and mode 600 — an operator who '
            'cannot read their own backups. 70 is the image\'s own user, so a '
            'raw `docker compose run backup` behaves as its Dockerfile says '
            'and backup.sh refuses with a message naming the cause',
      );
    });

    test('and never declares itself production', () {
      // `resolveEmailSender` refuses the file sender under
      // `TRITRACK_ENV=production` (task 10.6), which is the guard that matters
      // and is measured in `test/auth/email_sender_test.dart`. This is the
      // shipped-configuration half: a compose file that set both would not be
      // a hole — the server would refuse to start — but it would be a stack
      // nobody could run and a mixed message about what the overlay is for.
      for (final entry in composeFiles.entries) {
        if (!_declaresKey(entry.value, 'TRITRACK_DEV_MAGIC_LINK_DIR:')) {
          continue;
        }
        expect(
          entry.value,
          isNot(contains('TRITRACK_ENV: production')),
          reason:
              '${entry.key} enables the development magic-link sender, which '
              'resolveEmailSender refuses in production',
        );
      }
    });
  });

  // Task 10.74, finding K-2. An allowlist in a shipped compose file is a
  // deployment claiming a proxy is in front of it, and that claim now carries
  // a second question the origin cannot answer for itself. Enumerated over
  // every compose file for the same reason as the group above: the defect this
  // closes was in the one override that ships a proxy, and the next one added
  // would inherit it silently.
  group('a compose file that ships an allowlist ships the K-2 question', () {
    late Map<String, String> composeFiles;

    setUpAll(() {
      composeFiles = _composeFiles();
    });

    test(
      'every file that sets TRITRACK_TRUSTED_PROXIES also passes the answer',
      () {
        for (final entry in composeFiles.entries) {
          if (!_declaresKey(entry.value, 'TRITRACK_TRUSTED_PROXIES:')) continue;
          expect(
            _declaresKey(entry.value, 'TRITRACK_PROXY_SOURCE_IDENTITY:'),
            isTrue,
            reason:
                '${entry.key} declares a trusted-proxy posture, so the server '
                'will ask how callers reach that proxy — and if this variable '
                'never reaches the container, the operator has no way to answer '
                'and the file cannot start at all',
          );
        }
      },
    );

    test('no compose file answers the question on the host\'s behalf', () {
      // The whole point of K-2. `TRITRACK_PUBLISH_ADDRESS` is hardcoded in the
      // overrides because it is a fact about the file; this one is a fact
      // about the machine, and a shipped default would be this repository
      // vouching for a host it has never seen — which is the assumption the
      // finding is made of.
      for (final entry in composeFiles.entries) {
        final line = entry.value
            .split('\n')
            .where((l) => l.contains('TRITRACK_PROXY_SOURCE_IDENTITY:'))
            .toList();
        for (final l in line) {
          expect(
            l.trim(),
            r'TRITRACK_PROXY_SOURCE_IDENTITY: ${TRITRACK_PROXY_SOURCE_IDENTITY:-}',
            reason:
                '${entry.key} must pass this through from the environment with '
                'no default — probe-verified is a measurement of the host, not '
                'a property this repository can ship',
          );
        }
      }
    });
  });

  group('the entry point cannot skip the private-range check', () {
    test(
      'bin/server.dart resolves the transport, not just the environment',
      () {
        // `fromEnvironment` is the configuration half and stops short of §4.1's
        // second condition. Calling it here is precisely the omission C-3 was,
        // and it would look completely reasonable in review — hence a test.
        expect(entryPoint, contains('TransportSecurityConfig.resolve('));
        expect(
          entryPoint,
          isNot(contains('TransportSecurityConfig.fromEnvironment(')),
          reason:
              'the real entry point must use resolve(), which also checks this '
              'machine\'s interfaces',
        );
      },
    );

    test('a transport refusal is reported before the process exits', () {
      // 10.25: "a correct refusal nobody can see is a support call." An
      // unhandled StateError in a restart-looping container reads as "the
      // server is broken", and the fix people reach for is switching the
      // control off.
      expect(entryPoint, contains('REFUSING TO START'));
      expect(entryPoint, contains('exit(78)'));
    });
  });

  // Task 11.127, and it is the mirror image of the same task's item 0. There,
  // a harness was coupled to a line in code it did not own and the owner
  // deleted it invisibly. Here a control lives **inside a caller that has no
  // obligation to keep calling it**.
  //
  // `scripts/assert_suite_scope.py` is that control. Task 11.156 wrote it
  // because `flutter test` and `dart test` both exit 0 over an unknown
  // fraction of their directory, and the runner scripts used to echo PASS on
  // that exit code. Two ways to remove it and they are not alike:
  //
  //   * Drop `--file-reporter` and the run **fails loudly** — the report is
  //     missing and the check says so.
  //   * Drop the whole `python3 scripts/assert_suite_scope.py` block and the
  //     caller goes back to reporting success on an exit code, and **nothing
  //     anywhere notices.**
  //
  // So this group asserts the *call*, in the sense of the wiring that makes a
  // call mean something, rather than the presence of the script's name: the
  // report the run writes is the report the check reads, the verdict can fail
  // the run, and every flag typed is a flag the check implements. Then it runs
  // the called program for real against a synthetic subject, in both
  // directions, so "the block is there" also means "the thing it calls still
  // refuses".
  //
  // **The set of callers is derived, not listed.** Task 11.156 named one;
  // there are three, and a fourth added tomorrow fails this group until
  // somebody decides how it is covered. A hand-written list of what gets
  // checked is the shape this project has been bitten by more times than any
  // other.
  //
  // **What it still cannot see**, said plainly rather than left to be
  // discovered: whether the block is reachable at all (a caller could wrap it
  // in a condition that is never true), and whether `assert_suite_scope.py`'s
  // *other* assertions — the declared-skips comparison in particular — still
  // hold. The live exercise below covers only the missing-suite arm.
  const scopeCheck = 'assert_suite_scope.py';
  const scopeCheckPath = '../scripts/$scopeCheck';

  /// Every file in this repository that invokes the scope check, and the
  /// non-comment line on which it does it.
  Map<String, String> callersOfScopeCheck() {
    final found = <String, String>{};
    for (final directory in const ['../scripts', '../.github/workflows']) {
      for (final file in Directory(directory).listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (name == scopeCheck) continue;
        // `\`-newline continuations joined, so one logical command is one line
        // however it is wrapped.
        final lines = file
            .readAsStringSync()
            .replaceAll(RegExp(r'\\\r?\n\s*'), ' ')
            .split('\n')
            // **Comment lines are excluded and it is not pedantry** — the
            // first draft of this group matched the paragraph in a script that
            // *explains* the scope check and concluded it passed no flags. A
            // file that talks about a control and a file that calls one must
            // not read the same, which is the distinction `_declaresKey` above
            // exists for one file over.
            .where(
              (line) =>
                  !line.trimLeft().startsWith('#') && line.contains(scopeCheck),
            )
            .toList();
        if (lines.isEmpty) continue;
        expect(
          lines,
          hasLength(1),
          reason:
              '${file.path} invokes $scopeCheck more than once, so the '
              'assertions below would read whichever line came first and the '
              'others would be unexamined:\n${lines.join('\n')}',
        );
        found[name] = lines.single;
      }
    }
    return found;
  }

  /// The four callers as of 2026-09-05, each with what it is for.
  ///
  /// The value says whether the caller is a shell script — a workflow step
  /// fails its job on a non-zero exit by itself, where a script has to capture
  /// the status and act on it.
  ///
  /// `run_e2e_tests.sh` is the fourth, added by task 11.171 and named by
  /// 11.127's survey as the caller this check should always have had. It runs
  /// with `--no-skips` rather than a declared-skips file, because that suite
  /// exists to run precisely the tests `dart_test.yaml` skips by default:
  /// **drop its `--run-skipped` flag and `flutter test` prints "All tests
  /// skipped." and exits 0** — measured 2026-09-05 — so a single skipped test
  /// in it is the whole failure mode rather than an edge of it.
  const knownCallers = {
    'run_offline_suite.sh': true,
    'run_server_tests_docker.sh': true,
    'run_e2e_tests.sh': true,
    'tile-credit-freshness.yml': false,
  };

  group('every caller of the check that says how much of a suite ran still '
      'calls it', () {
    test('the control itself still exists', () {
      expect(
        File(scopeCheckPath).existsSync(),
        isTrue,
        reason:
            'scripts/$scopeCheck is the control every caller below invokes. '
            'Without it they are back to reporting success on an exit code '
            'that cannot distinguish "the whole suite passed" from "a tenth '
            'of it passed"',
      );
    });

    test('the set of callers is the set this group covers', () {
      final found = callersOfScopeCheck();
      expect(
        found.keys.toSet(),
        knownCallers.keys.toSet(),
        reason:
            'The files invoking scripts/$scopeCheck are not the ones this '
            'group knows about.\n\n'
            'One missing means a suite gate went back to reporting success on '
            'an exit code that is 0 for a run that loaded seven of 250 files '
            'and passed all seven, and nothing else in this repository would '
            'have said so.\n\n'
            'One extra means a new caller is invoking the control and nothing '
            'checks that it keeps doing so. Add it to knownCallers, saying '
            'whether it is a shell script (it must capture the verdict and '
            'exit on it) or a workflow step (a non-zero exit fails the job by '
            'itself).',
      );
    });

    for (final entry in knownCallers.entries) {
      final name = entry.key;
      final isShellScript = entry.value;

      group(name, () {
        late final String invocation = callersOfScopeCheck()[name] ?? '';
        late final String source =
            (isShellScript
                    ? File('../scripts/$name')
                    : File('../.github/workflows/$name'))
                .readAsStringSync()
                .replaceAll(RegExp(r'\\\r?\n\s*'), ' ');

        test('the report the run writes is the report the check reads', () {
          final written = RegExp(
            r'--file-reporter[= ]"?json:"?([^"\s]+)"?',
          ).firstMatch(source);
          expect(
            written,
            isNotNull,
            reason:
                '$name no longer asks its test runner for a JSON report, so '
                'there is nothing for the scope check to read and no way to '
                'know what fraction of its directory the run reached',
          );
          final read = RegExp(
            r'--report\s+"?([^"\s]+)"?',
          ).firstMatch(invocation);
          expect(
            read,
            isNotNull,
            reason:
                '$name invokes $scopeCheck without pointing it at a report at '
                'all:\n  $invocation',
          );
          expect(
            read!.group(1),
            written!.group(1),
            reason:
                '$name writes its JSON report to ${written.group(1)} and '
                'points the scope check at ${read.group(1)}, so the check is '
                'answering about a different run — or about no run at all',
          );
        });

        if (isShellScript) {
          test("the check's verdict is captured and can fail the run", () {
            final captured = RegExp(
              r'\|\|\s*(\w+)=\$\?\s*$',
            ).firstMatch(invocation.trim());
            expect(
              captured,
              isNotNull,
              reason:
                  "the scope check's exit status is not captured in $name. "
                  'Under `set -e` a bare invocation would at least abort, but '
                  '`... || true` and a trailing `; true` both read as "we ran '
                  'it" while discarding the one thing it produces. Its '
                  'verdict must land in a variable this script then acts '
                  'on.\n\nThe line as it stands:\n  $invocation',
            );
            expect(
              source,
              contains('exit "\$${captured!.group(1)}"'),
              reason:
                  "$name captures the scope check's verdict into "
                  '\$${captured.group(1)} and never exits on it, so a '
                  'narrowed run would be reported as a pass with the failure '
                  'printed above it. A control whose answer nobody acts on is '
                  'not a control',
            );
          });
        } else {
          test('the step that runs it is not allowed to fail quietly', () {
            // A workflow step fails its job on a non-zero exit by itself —
            // unless somebody adds `continue-on-error`, which is the same
            // discard as `|| true` one layer up.
            expect(
              source,
              isNot(contains('continue-on-error')),
              reason:
                  '$name sets continue-on-error somewhere. If it is on the '
                  'scope-check step, the job goes green having been told the '
                  'run reached almost none of its subject',
            );
          });
        }

        test('every flag it types is a flag the check implements', () {
          // The `healthcheck:` coupling again: one file names a string
          // another file implements, and a rename fails in the quiet
          // direction — argparse exits 2, a script's `|| scope_rc=$?` catches
          // it, and the failure reads as "the scope check refused" rather
          // than "nobody asked it anything". Cheap to rule out.
          final flags = RegExp(
            r'--[a-z][a-z-]+',
          ).allMatches(invocation).map((m) => m.group(0)!).toSet();
          expect(
            flags,
            isNotEmpty,
            reason:
                'no long flags were parsed out of the scope-check invocation '
                'in $name, so this test is comparing nothing against '
                'nothing:\n  $invocation',
          );
          final implemented = File(scopeCheckPath).readAsStringSync();
          for (final flag in flags) {
            expect(
              implemented,
              contains('add_argument("$flag"'),
              reason:
                  '$name passes $flag and scripts/$scopeCheck does not '
                  'declare it. argparse would exit 2 on an unrecognised '
                  'flag, and the run would report that as the scope check '
                  'failing rather than as nobody having asked it anything',
            );
          }
        });
      });
    }

    // **The block being present is not the block still working.** Everything
    // above reads text; this runs the program the text names, against a
    // subject built here, and requires it to refuse a run that reached less
    // than its whole directory. Watched failing on 2026-09-05, four ways: the
    // block deleted from either script, its verdict discarded with `|| true`,
    // and a flag renamed on the implementing side.
    test('and the check they call still refuses a run that reached less than '
        'its whole directory', () async {
      final temp = await Directory.systemTemp.createTemp('tritrack-scope-');
      addTearDown(() => temp.delete(recursive: true));
      final tests = Directory('${temp.path}/t')..createSync();
      for (final name in const ['a_test.dart', 'b_test.dart']) {
        File('${tests.path}/$name').writeAsStringSync('');
      }

      String reportFor(List<String> loaded) {
        final lines = <String>[];
        for (var i = 0; i < loaded.length; i++) {
          lines.add(
            '{"type":"suite","suite":{"id":$i,'
            '"path":"${tests.path}/${loaded[i]}"}}',
          );
          lines.add(
            '{"type":"testStart","test":{"id":${100 + i},'
            '"suiteID":$i,"name":"synthetic"}}',
          );
          lines.add('{"type":"testDone","testID":${100 + i},"skipped":false}');
        }
        final path = '${temp.path}/${loaded.length}.json';
        File(path).writeAsStringSync('${lines.join('\n')}\n');
        return path;
      }

      Future<ProcessResult> ask(List<String> loaded) => Process.run('python3', [
        scopeCheckPath,
        '--report',
        reportFor(loaded),
        '--test-dir',
        tests.path,
        '--label',
        'synthetic ${loaded.length} of 2',
      ]);

      final complete = await ask(const ['a_test.dart', 'b_test.dart']);
      expect(
        complete.exitCode,
        0,
        reason:
            'scripts/$scopeCheck refused a run that did reach every file on '
            'disk. Either it has become unable to pass, or this test\'s '
            'synthetic report no longer resembles the reporter\'s output — '
            'and in that case the failing half below proves '
            'nothing.\n\n${complete.stdout}${complete.stderr}',
      );

      final narrowed = await ask(const ['a_test.dart']);
      expect(
        narrowed.exitCode,
        isNot(0),
        reason:
            'scripts/$scopeCheck accepted a run that loaded one of two test '
            'files. Every caller above is still calling it and it no longer '
            'refuses anything, which is the exact silence it was written to '
            'break.\n\n${narrowed.stdout}${narrowed.stderr}',
      );
      expect(
        '${narrowed.stdout}${narrowed.stderr}',
        contains('b_test.dart'),
        reason:
            'it refused, without naming the file that did not run. A refusal '
            'that does not say what it found leaves the reader to guess, and '
            'CI keeps only the tail of the log',
      );
    });
  });

  // Task 11.171, and it is task 11.127's group applied to the four call sites
  // its survey ranked highest. Same sentence: **a control that lives inside a
  // caller which has no obligation to keep calling it.** Deleting the line
  // leaves no red anywhere, and in two of the four it leaves behind a sentence
  // still claiming the check happened.
  //
  // **Three of the seven 11.127 listed are deliberately not here**, and the
  // reason is a measurement rather than a budget. They are
  // `gate_smoke_test.sh`'s `--selftest` line and its two `run_detection_proof`
  // calls — and that file already derives, on every invocation, the set of
  // wire-speaking `scripts/*.py` instruments and fails if any of them is not
  // run (`DERIVED_WIRE`). Measured 2026-09-05: that derivation covers **11 of
  // the 22 lines in the file that run something.** The other 11 include
  // `backup_restore_drill`, `verify_deployment_refusal_matrix`,
  // `verify_i1_source_identity` and the bare `verify_instrument_unchecked_returns`
  // as well as the three named. **Naming three of eleven here would assert that
  // a detection proof matters more than the drill it is a proof about**, which
  // is false, and it would put the list in a different file from the derivation
  // that already answers this question for the other half. The right repair is
  // to widen `DERIVED_WIRE` to the shell instruments, inside `gate_smoke_test.sh`
  // — one change rather than eleven assertions over here. Recorded for the
  // planning session rather than done under a brief that says not to invent a
  // fourth instrument.

  /// Every file under `scripts/` or `.github/workflows/` with a non-comment
  /// line naming [what], and those lines.
  ///
  /// Comment lines are excluded for the reason 11.127's version gives: a file
  /// that *explains* a control and a file that *calls* one must not read the
  /// same.
  Map<String, List<String>> callersOf(String what) {
    final found = <String, List<String>>{};
    for (final directory in const ['../scripts', '../.github/workflows']) {
      for (final file in Directory(directory).listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (name == what) continue;
        final lines = file
            .readAsStringSync()
            .replaceAll(RegExp(r'\\\r?\n\s*'), ' ')
            .split('\n')
            .where(
              (line) => !line.trimLeft().startsWith('#') && line.contains(what),
            )
            .toList();
        if (lines.isNotEmpty) found[name] = lines;
      }
    }
    return found;
  }

  group('the abort proof for every wire-speaking instrument is still invoked', () {
    // One line in one workflow. `gate_smoke_test.sh` under
    // `GATE_SMOKE_SELFTEST=1` forces a stale schema major and requires every
    // wire-speaking instrument to abort on it — which is the only evidence in
    // this repository that those instruments can still *fail*. Without it,
    // "all of them passed" and "all of them aborted before running a single
    // control" are the same exit code from here, which is task 10.40 exactly.
    final workflow = File('../.github/workflows/gate-instruments.yml');
    late final String source = workflow.readAsStringSync();

    /// The workflow's steps, split on the `      - ` that begins each one.
    List<String> steps() {
      // Comment lines come out before the split. A step is delimited by "up
      // to the next step", so without this a comment written *above* a step
      // — which is exactly where a person explains what the step is for, in
      // the step's own vocabulary — is handed to the step before it. Task
      // 11.221 met that here: a note above the self-test step naming
      // GATE_SMOKE_SELFTEST made the log-upload step above it read as a
      // second setter. `CLAUDE.md` records the same bug twice in task 11.173
      // (a job's prose header attached to the last step of the job above).
      final withoutComments = source
          .split('\n')
          .where((line) => !RegExp(r'^\s*#').hasMatch(line))
          .join('\n');
      final parts = withoutComments.split(
        RegExp(r'^      - ', multiLine: true),
      );
      expect(
        parts,
        hasLength(greaterThan(1)),
        reason:
            '${workflow.path} could not be split into steps, so every '
            'assertion below would be reading one undifferentiated string and '
            'agreeing with itself. The file\'s step indentation changed',
      );
      return parts.skip(1).toList();
    }

    test('exactly one step sets GATE_SMOKE_SELFTEST, and it runs the gate '
        'script', () {
      final selftestSteps = steps()
          .where((s) => s.contains('GATE_SMOKE_SELFTEST'))
          .toList();
      expect(
        selftestSteps,
        hasLength(1),
        reason:
            'Exactly one step in ${workflow.path} is supposed to set '
            'GATE_SMOKE_SELFTEST. None means the abort proof for every '
            'wire-speaking instrument is gone and nothing else in this '
            'repository runs it — the gate would stay green while every '
            'instrument in it had quietly lost the ability to fail. More than '
            'one means the assertions below are reading whichever came first.',
      );
      expect(
        selftestSteps.single,
        contains('scripts/gate_smoke_test.sh'),
        reason:
            'the step that sets GATE_SMOKE_SELFTEST no longer runs '
            'scripts/gate_smoke_test.sh, so the variable is being set for '
            'nobody',
      );
      expect(
        selftestSteps.single,
        contains(RegExp(r"GATE_SMOKE_SELFTEST:\s*'?1'?")),
        reason:
            'gate_smoke_test.sh takes the self-test branch only on the exact '
            'value 1 (`[ "\${GATE_SMOKE_SELFTEST:-0}" = "1" ]`). Any other '
            'value runs the ordinary gate and reports success, having proved '
            'nothing about whether the instruments can fail',
      );
    });

    test('the script it names still implements that variable', () {
      // The `healthcheck:` coupling: one file names a string another file
      // implements, and a rename here fails in the quiet direction — the
      // workflow sets a variable nothing reads, the ordinary gate runs, and
      // the step goes green.
      final script = File('../scripts/gate_smoke_test.sh').readAsStringSync();
      expect(
        script,
        contains(RegExp(r'\$\{GATE_SMOKE_SELFTEST:-0\}')),
        reason:
            'gate-instruments.yml sets GATE_SMOKE_SELFTEST and '
            'scripts/gate_smoke_test.sh no longer reads it. The step would '
            'run the ordinary gate, pass, and be indistinguishable from a '
            'self-test that proved all eleven instruments can still abort',
      );
      expect(
        script,
        contains('SELFTEST PASSED'),
        reason:
            "the self-test branch no longer has a passing verdict to print, "
            'so there is no longer anything for the step above to be running',
      );
    });

    test('the condition on that step can actually be true', () {
      // 11.127 named this as the thing its own group could not see: a caller
      // could wrap the block in a condition that is never true. A workflow
      // step's `if:` is exactly that, in one line, and the event names in it
      // are a string naming something the `on:` block implements.
      final step = steps().firstWhere(
        (s) => s.contains('GATE_SMOKE_SELFTEST'),
        // The test above is the one that reports a missing step, and it says
        // so at length. Throwing a bare StateError here on the same sabotage
        // would put an unexplained stack trace in the five-line CI tail
        // beside it.
        orElse: () => '',
      );
      if (step.isEmpty) return;
      final condition = RegExp(
        r'^\s*if:\s*(.+)$',
        multiLine: true,
      ).firstMatch(step);
      if (condition == null) return; // unconditional: it always runs.
      final events = RegExp(
        r"github\.event_name\s*==\s*'([a-z_]+)'",
      ).allMatches(condition.group(1)!).map((m) => m.group(1)!).toSet();
      expect(
        events,
        isNotEmpty,
        reason:
            'the self-test step has an `if:` this test could not read any '
            'event name out of, so it cannot say whether the condition is '
            'ever true:\n  ${condition.group(1)}',
      );
      final triggers = RegExp(r'^  ([a-z_]+):', multiLine: true)
          .allMatches(source.split(RegExp(r'^jobs:', multiLine: true)).first)
          .map((m) => m.group(1)!)
          .toSet();
      for (final event in events) {
        expect(
          triggers,
          contains(event),
          reason:
              "the self-test step runs only on '$event' and "
              '${workflow.path} has no $event: trigger, so the abort proof '
              'for every wire-speaking instrument is behind a condition that '
              'is never true. The step is present, green, and has never '
              'run.\n\nTriggers declared: ${triggers.join(', ')}',
        );
      }
      // The reopen trigger for task 11.221, mechanised rather than written
      // in prose: the nightly schedule was commented out on 2026-09-10 until
      // 1 October 2026 to save Actions minutes, and `schedule` had to come
      // out of the step's `if:` with it (the assertion above refuses an event
      // no trigger declares). The self-test exists to run unattended — that
      // is what "can the instruments still fail" is worth — so the day the
      // schedule block is uncommented and this line is not, the abort proof
      // would go on running only when somebody presses the button, and
      // nothing would say so. This says so.
      if (triggers.contains('schedule')) {
        expect(
          events,
          contains('schedule'),
          reason:
              '${workflow.path} declares a schedule: trigger again, but the '
              'self-test step\'s `if:` does not name it — so the nightly would '
              'run the instruments and never the proof that they can still '
              'fail. Add github.event_name == \'schedule\' back to that '
              'condition (task 11.221 took it out with the schedule).',
        );
      }
    });

    test('and it is not allowed to fail quietly', () {
      expect(
        source,
        isNot(contains('continue-on-error')),
        reason:
            '${workflow.path} sets continue-on-error somewhere. On the '
            'self-test step that is the same discard as `|| true`: the job '
            'goes green having been told the instruments can no longer fail',
      );
    });
  });

  group('the gate\'s instrument-coverage derivation is still invoked on every '
      'push', () {
    // Task 11.173, and it is task 11.171's group one door along.
    //
    // `scripts/gate_smoke_test.sh` derives which of its own lines run
    // something, and requires each of those names to be claimed by a
    // `# gate-instrument:` declaration in the script it runs. That derivation
    // is the only thing in this repository that notices a `run_instrument`
    // line quietly disappearing. `GATE_SMOKE_COVERAGE_ONLY=1` (task 11.172)
    // runs it and *nothing else* — no Docker, no stack, no instrument — so the
    // question can be asked on every push instead of only when the gate itself
    // runs.
    //
    // **Adding a CI step is adding another call site nothing guards**, which
    // is the class 11.171 and 11.172 spent themselves closing. This group is
    // the guard, and it asserts the same four things 11.171's does, because
    // each of the four was earned by a defect: exactly one step sets the
    // variable; that step runs the gate script; the script still implements
    // the variable (the `healthcheck:` coupling — a rename there leaves the
    // step setting a variable nothing reads, running the *ordinary* gate, and
    // going green); and the events in the step's `if:` are events its workflow
    // actually declares a trigger for (11.127 named this as the hole its own
    // group could not see).
    //
    // Which workflow hosts the step is **derived rather than named**, so
    // moving it does not silently leave this group reading a file that no
    // longer has it — and an empty derivation is a failure with its own
    // sentence rather than a vacuous pass over nothing.
    const variable = 'GATE_SMOKE_COVERAGE_ONLY';
    const script = 'scripts/gate_smoke_test.sh';

    /// Every workflow file, by name, with its source.
    Map<String, String> workflows() {
      final found = <String, String>{};
      for (final file in Directory(
        '../.github/workflows',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.yml'))) {
        found[file.uri.pathSegments.last] = file.readAsStringSync();
      }
      expect(
        found,
        isNotEmpty,
        reason:
            'no workflow files were found under ../.github/workflows, so '
            'every assertion below would be searching an empty set and '
            'agreeing with itself',
      );
      return found;
    }

    /// The workflow files that mention [variable] outside a comment.
    Map<String, String> hosts() {
      final found = <String, String>{};
      workflows().forEach((name, source) {
        final mentions = source
            .split('\n')
            .where(
              (line) =>
                  !line.trimLeft().startsWith('#') && line.contains(variable),
            );
        if (mentions.isNotEmpty) found[name] = source;
      });
      return found;
    }

    /// [source] split on the `      - ` that begins each step, with comment
    /// lines dropped.
    ///
    /// Dropping comments is not cosmetic and this group found out the hard
    /// way. A step chunk runs *up to the next step*, so the last step of a job
    /// swallows the header comment of the job below it — 11.84's
    /// delimit-by-the-next-one defect, here on a YAML file. The prose header
    /// of the coverage job names the variable, so `Server suite in Docker`
    /// matched as a second step setting it. Same rule as `callersOf` above: a
    /// file that *explains* a control and a file that *calls* one must not
    /// read the same.
    List<String> stepsOf(String name, String source) {
      final parts = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n')
          .split(RegExp(r'^      - ', multiLine: true));
      expect(
        parts,
        hasLength(greaterThan(1)),
        reason:
            '.github/workflows/$name could not be split into steps, so every '
            'assertion below would be reading one undifferentiated string and '
            "agreeing with itself. The file's step indentation changed",
      );
      return parts.skip(1).toList();
    }

    test('exactly one step sets $variable, and it runs the gate script', () {
      final hosting = hosts();
      expect(
        hosting.keys,
        hasLength(1),
        reason:
            'Exactly one workflow is supposed to set $variable. None means '
            'the gate\'s coverage derivation is no longer asked on every push '
            '— it would be exercised only by the twenty-minute Docker run in '
            'gate-instruments.yml, which is path-filtered, so a commit that '
            'deletes a run_instrument line while touching nothing under '
            'scripts/ would not start it. (That run was also nightly until '
            '2026-09-10, when task 11.221 switched the schedule off to save '
            'Actions minutes, until it came back on 2026-10-01 with task '
            '11.318 — and for that month nothing else would have caught such '
            'a commit.) More than one means the assertions below are '
            'reading whichever came first.\n\n'
            'Workflows setting it: ${hosting.keys.join(', ')}',
      );
      final name = hosting.keys.single;
      final coverageSteps = stepsOf(
        name,
        hosting[name]!,
      ).where((s) => s.contains(variable)).toList();
      expect(
        coverageSteps,
        hasLength(1),
        reason:
            '.github/workflows/$name is supposed to have exactly one step '
            'setting $variable and has ${coverageSteps.length}',
      );
      expect(
        coverageSteps.single,
        contains(script),
        reason:
            'the step that sets $variable no longer runs $script, so the '
            'variable is being set for nobody',
      );
      expect(
        coverageSteps.single,
        contains(RegExp('$variable:\\s*\'?1\'?')),
        reason:
            '$script takes the coverage-only branch on the exact value 1 '
            '(it reads the variable with a :-0 default and compares the '
            'result to the string 1). Any other value runs the ORDINARY gate '
            '— which on a '
            'runner with no .env and a cold Docker means a long red step that '
            'says nothing about coverage, or worse, a long green one',
      );
    });

    test('the script it names still implements that variable', () {
      // The `healthcheck:` coupling again: one file names a string another
      // file implements, and a rename here fails in the quiet direction.
      final source = File('../$script').readAsStringSync();
      expect(
        source,
        contains(RegExp('\\\$\\{$variable:-0\\}')),
        reason:
            'a workflow sets $variable and $script no longer reads it. The '
            'step would run the ordinary gate — bringing up compose stacks on '
            'a runner that has no .env — and whatever it reported would not '
            'be about coverage',
      );
      expect(
        source,
        contains('COVERAGE ONLY:'),
        reason:
            'the coverage-only branch of $script no longer has a verdict to '
            'print, so there is no longer anything for the workflow step to '
            'be running',
      );
    });

    test('the condition on that step can actually be true', () {
      final hosting = hosts();
      if (hosting.length != 1) return; // reported at length by the test above.
      final name = hosting.keys.single;
      final source = hosting[name]!;
      final step = stepsOf(name, source).firstWhere(
        (s) => s.contains(variable),
        // The test above is the one that reports a missing step, and it says
        // so at length. A bare StateError here on the same sabotage would put
        // an unexplained stack trace in the five-line CI tail beside it.
        orElse: () => '',
      );
      if (step.isEmpty) return;
      final condition = RegExp(
        r'^\s*if:\s*(.+)$',
        multiLine: true,
      ).firstMatch(step);
      if (condition == null) return; // unconditional: it always runs.
      final events = RegExp(
        r"github\.event_name\s*==\s*'([a-z_]+)'",
      ).allMatches(condition.group(1)!).map((m) => m.group(1)!).toSet();
      expect(
        events,
        isNotEmpty,
        reason:
            'the coverage step has an `if:` this test could not read any '
            'event name out of, so it cannot say whether the condition is '
            'ever true:\n  ${condition.group(1)}',
      );
      final triggers = RegExp(r'^  ([a-z_]+):', multiLine: true)
          .allMatches(source.split(RegExp(r'^jobs:', multiLine: true)).first)
          .map((m) => m.group(1)!)
          .toSet();
      for (final event in events) {
        expect(
          triggers,
          contains(event),
          reason:
              "the coverage step runs only on '$event' and "
              '.github/workflows/$name has no $event: trigger, so the gate\'s '
              'coverage derivation is behind a condition that is never true. '
              'The step is present, green, and has never run.\n\n'
              'Triggers declared: ${triggers.join(', ')}',
        );
      }
    });

    test('and "every push" is still every push', () {
      // The point of the task, and the one thing 11.171's four assertions
      // cannot see: a workflow can be perfectly wired and never start. A
      // `paths:` filter under `push:` is how — gate-instruments.yml has one,
      // which is exactly why this step is not in it. The failure is silent:
      // no red, no skipped step, just a commit that deleted a run line and a
      // checks list with nothing about coverage in it.
      final hosting = hosts();
      if (hosting.length != 1) return; // reported at length above.
      final name = hosting.keys.single;
      final preamble = hosting[name]!
          .split(RegExp(r'^jobs:', multiLine: true))
          .first
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');
      final push = RegExp(
        r'^  push:\s*$',
        multiLine: true,
      ).firstMatch(preamble);
      // **A declared pause (task 11.325, 2026-10-02) is not a silent one.**
      // The workflow starts only by hand while `# PAUSED <date> (task …):`
      // heads its `on:` block, and what must still be true is that *restoring*
      // it restores "every push": the saved copy of the old triggers has a
      // bare `push:` and no `paths:` under it. `test/documentation/
      // ci_pause_test.dart` holds the notice and the real triggers to each
      // other; this holds what the notice promises to bring back.
      if (push == null &&
          RegExp(
            r'^# PAUSED \d{4}-\d{2}-\d{2} \(task [^)]+\):',
            multiLine: true,
          ).hasMatch(hosting[name]!)) {
        final saved = hosting[name]!
            .split('# Saved triggers, exactly as they were:')
            .last
            .split('\n')
            .skip(1)
            .takeWhile((line) => line.startsWith('#'))
            .map((line) => line.replaceFirst(RegExp(r'^# ?'), ''))
            .join('\n');
        expect(
          RegExp(r'^  push:\s*$', multiLine: true).hasMatch(saved),
          isTrue,
          reason:
              '.github/workflows/$name is paused, and the triggers its notice '
              'says to restore have no bare `push:`, so restoring it would '
              'not ask the gate\'s coverage derivation on every push.\n\n$saved',
        );
        final savedPush = saved.split(RegExp(r'^  push:\s*$', multiLine: true))[1];
        final savedBody = RegExp(r'^  \S', multiLine: true).firstMatch(savedPush);
        expect(
          savedBody == null ? savedPush : savedPush.substring(0, savedBody.start),
          isNot(contains('paths')),
          reason: 'the saved push: trigger has a paths filter',
        );
        return;
      }
      expect(
        push,
        isNotNull,
        reason:
            '.github/workflows/$name hosts the gate\'s coverage derivation '
            'and has no bare `push:` trigger, so it is not asked on every '
            'push. That is the whole of what task 11.173 added',
      );
      // Everything indented under `push:` until the next two-space key.
      final after = preamble.substring(push!.end);
      final body = RegExp(r'^  \S', multiLine: true).firstMatch(after);
      final pushBlock = body == null ? after : after.substring(0, body.start);
      expect(
        pushBlock,
        isNot(contains('paths')),
        reason:
            '.github/workflows/$name\'s push: trigger has acquired a paths '
            'filter, so the coverage derivation now runs only on commits that '
            'touch those paths. A commit that deletes a run_instrument line '
            'from scripts/gate_smoke_test.sh while touching nothing on the '
            'list would not start it, and nothing would say so:\n$pushBlock',
      );
    });

    test('and its result cannot be read as a gate result', () {
      // 11.172 made this mode print "NOTHING WAS RUN. No instrument executed,
      // no server was reached and no control was exercised" on purpose. A
      // green tick beside the word "gate" on a run that exercised no control
      // is the lying-instrument class arriving by a new door, so the sentence
      // has to survive into CI rather than stopping at the script.
      final scriptSource = File('../$script').readAsStringSync();
      expect(
        scriptSource,
        contains('NOTHING WAS RUN.'),
        reason:
            '$script\'s coverage-only mode no longer says that it ran '
            'nothing, so its output is a verdict about a gate that did not '
            'happen',
      );
      final hosting = hosts();
      if (hosting.length != 1) return; // reported at length above.
      final name = hosting.keys.single;
      final source = hosting[name]!;
      final step = stepsOf(
        name,
        source,
      ).firstWhere((s) => s.contains(variable), orElse: () => '');
      if (step.isEmpty) return;
      final stepName = RegExp(
        r'^\s*name:\s*(.+)$',
        multiLine: true,
      ).firstMatch(step);
      expect(
        stepName?.group(1),
        contains('NOTHING IS RUN'),
        reason:
            'the step running the coverage-only mode in '
            '.github/workflows/$name does not say in its own name that it '
            'runs nothing. The step name is what appears in the checks list '
            'and in a notification, and neither of those shows the log:\n'
            '  ${stepName?.group(1) ?? '(no name:)'}',
      );
      // Comment lines dropped before splitting, for the reason `stepsOf`
      // gives at length: a job chunk runs up to the next job, so without this
      // the job *above* the coverage job swallows its prose header — which
      // names the variable — and is picked as the match.
      final job = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n')
          .split(RegExp(r'^  [a-z0-9-]+:$', multiLine: true))
          .firstWhere((chunk) => chunk.contains(variable), orElse: () => '');
      expect(
        job,
        contains(RegExp(r'^    name:.*nothing is executed', multiLine: true)),
        reason:
            'the job holding the coverage-only step in '
            '.github/workflows/$name does not say in its own name that '
            'nothing is executed. That name is the green tick a person sees',
      );
      expect(
        step + job,
        contains('NOTHING WAS RUN'),
        reason:
            'nothing in .github/workflows/$name carries the script\'s own '
            '"NOTHING WAS RUN" sentence into the run summary, so a reader who '
            'does not open the log sees a green check with the word gate in '
            'it and nothing else',
      );
    });

    test('and it is not allowed to fail quietly', () {
      final hosting = hosts();
      if (hosting.length != 1) return; // reported at length above.
      final name = hosting.keys.single;
      expect(
        hosting[name],
        isNot(contains('continue-on-error')),
        reason:
            '.github/workflows/$name sets continue-on-error somewhere. On the '
            'coverage step that is the same discard as `|| true`: the job '
            'goes green having been told the gate no longer runs what it says '
            'it runs',
      );
    });
  });

  group('the only check on the capabilities the shipped Android app declares '
      'is still invoked', () {
    // `capability_matrix_test.dart` reads the three hand-written manifests, so
    // everything Gradle merges in from a plugin is invisible to it — task
    // 11.66 found seven such additions by hand.
    // `verify_merged_manifest_capabilities.sh` reads the manifest the build
    // actually produced, and nothing else does. Delete the step and
    // build-check.yml is green having built an APK nobody looked inside.
    const check = 'verify_merged_manifest_capabilities.sh';

    test('the control itself still exists', () {
      expect(
        File('../scripts/$check').existsSync(),
        isTrue,
        reason:
            'scripts/$check is the only thing in this repository that reads '
            'the merged Android manifest. Without it, what the shipped app '
            'asks the operating system for is checked nowhere',
      );
    });

    test('the set of callers is the set this group covers', () {
      expect(
        callersOf(check).keys.toSet(),
        {'build-check.yml', 'nightly_check.sh'},
        reason:
            'The files invoking scripts/$check are not the ones this group '
            'knows about. None means the merged manifest is unread. An extra '
            'one means a new caller is invoking it and nothing checks that it '
            'keeps doing so — add it here.',
      );
    });

    test('the nightly check inspects both builds and cannot skip a failure', () {
      // Task 11.325 round 2. GitHub's build-check.yml is paused (the code
      // changes many times a day), so `scripts/nightly_check.sh` runs these
      // two builds and this check instead. It runs them as one step of a
      // `&&` chain: a failing build or a refused manifest ends the chain, the
      // step exits non-zero, and the night's report says FAIL. This pins the
      // shape of that chain, in the same terms as build-check.yml's two tests
      // below; the night's own `--self-test` pins that a failing step is
      // reported.
      final lines = callersOf(check)['nightly_check.sh'] ?? const [];
      expect(
        lines,
        hasLength(1),
        reason:
            'nightly_check.sh should invoke scripts/$check in exactly one step '
            '(its Android build step); it has ${lines.length} non-comment '
            'lines naming it:\n${lines.join('\n')}',
      );
      final step = lines.single;
      expect(
        RegExp(RegExp.escape(check)).allMatches(step),
        hasLength(2),
        reason:
            'the nightly Android step must run scripts/$check twice, once on '
            'the debug manifest and once on the profile one. Only the debug '
            'build carries usesCleartextTraffic="true"; see the next test.\n$step',
      );
      expect(
        step,
        contains(
          'flutter build apk --debug && scripts/$check && '
          'flutter build apk --profile && scripts/$check ',
        ),
        reason:
            'the nightly step is no longer build debug, check debug (bare), '
            'build profile, check profile, each joined by &&, so a failure '
            'in one can no longer stop the ones after it:\n$step',
      );
      expect(
        step,
        matches(RegExp(r'merged_manifest/profile/\w+/AndroidManifest\.xml')),
        reason:
            'the second check in the nightly step does not name the profile '
            'merged manifest:\n$step',
      );
      expect(
        step,
        isNot(anyOf(contains('|| true'), contains('; scripts/'))),
        reason:
            'the nightly step discards a failure of one of its checks '
            '(`|| true`, or a `;` instead of `&&`):\n$step',
      );
    });

    test('both builds are still inspected, not just the debug one', () {
      // Task 11.125, item 2(iv): the *debug* manifest is the one that merges
      // in usesCleartextTraffic="true", so checking only that build measures
      // the capability guard in the configuration where the transport control
      // is switched off — task 10.54's shape. The profile build was added for
      // exactly that reason and is the easier of the two to drop, because
      // dropping it leaves a passing check with the same name behind.
      final invocations = callersOf(check)['build-check.yml'] ?? const [];
      expect(
        invocations,
        hasLength(2),
        reason:
            'build-check.yml is supposed to run scripts/$check twice — once '
            'on the debug merged manifest and once on the profile one. It '
            'runs it ${invocations.length} time(s).\n\n'
            'Only the debug build carries usesCleartextTraffic="true", so a '
            'debug-only check measures the capability matrix in the build '
            'where the transport control is disabled and reports full '
            'coverage.\n\n${invocations.join('\n')}',
      );
      expect(
        invocations.where((l) => l.trim().endsWith(check)),
        hasLength(1),
        reason:
            'neither invocation of scripts/$check in build-check.yml is the '
            'bare one, which is the debug build (the script defaults to the '
            'debug merged manifest when given no path):\n'
            '${invocations.join('\n')}',
      );
      expect(
        invocations.where((l) => l.contains('profile')),
        hasLength(1),
        reason:
            'no invocation of scripts/$check in build-check.yml names a '
            'profile manifest, so only the debug build is '
            'inspected:\n${invocations.join('\n')}',
      );
    });

    test('and neither step is allowed to fail quietly', () {
      expect(
        File('../.github/workflows/build-check.yml').readAsStringSync(),
        isNot(contains('continue-on-error')),
        reason:
            'build-check.yml sets continue-on-error somewhere. On either '
            'manifest step the job would go green having been told the '
            'shipped app declares a capability nobody approved',
      );
    });
  });

  group("the C-3 wrapper still runs the check it exists for", () {
    // The sharpest of the four, because of what it leaves behind.
    // `verify_c3_cleartext_defaults_stack.sh` is a compose lifecycle wrapped
    // around one command. Delete that command and the wrapper brings a stack
    // up, tears it down, exits 0 — and `gate_smoke_test.sh` prints
    // `verify_c3_cleartext_defaults PASS`. **A named instrument reporting
    // success having measured nothing** is worse than one that disappears,
    // because the name is the thing anybody reading the gate looks for.
    final wrapper = File('../scripts/verify_c3_cleartext_defaults_stack.sh');
    const check = 'verify_c3_cleartext_defaults.py';

    test('the control itself still exists', () {
      expect(
        File('../scripts/$check').existsSync(),
        isTrue,
        reason:
            'scripts/$check is the whole content of the wrapper below; '
            'without it the wrapper is a compose stack that starts and '
            'stops',
      );
    });

    test('the wrapper invokes it, and its verdict can fail the run', () {
      final source = wrapper.readAsStringSync();
      final lines = source
          .replaceAll(RegExp(r'\\\r?\n\s*'), ' ')
          .split('\n')
          .where(
            (line) => !line.trimLeft().startsWith('#') && line.contains(check),
          )
          .toList();
      expect(
        lines,
        hasLength(1),
        reason:
            '${wrapper.path} invokes scripts/$check ${lines.length} time(s), '
            'and it exists to invoke it exactly once. Zero means the wrapper '
            'still reports PASS to gate_smoke_test.sh under the name '
            'verify_c3_cleartext_defaults, having brought a stack up and '
            'checked nothing about it.',
      );
      expect(
        source,
        contains('set -euo pipefail'),
        reason:
            '${wrapper.path} no longer runs under `set -e`, so a non-zero '
            'exit from scripts/$check partway through would not stop the '
            'script and the wrapper would exit on whatever came last',
      );
      expect(
        lines.single,
        isNot(contains(RegExp(r'\|\|\s*(true|:)|;\s*true\s*$'))),
        reason:
            "the C-3 check's exit status is discarded in ${wrapper.path}. "
            'Under `set -e` a bare invocation aborts the wrapper, which is '
            'what makes gate_smoke_test.sh report FAIL; `|| true` reads as '
            '"we ran it" while throwing away the one thing it '
            'produces:\n  ${lines.single}',
      );
    });

    test('and it is still pointed at the shipped compose file', () {
      // The check is specifically about the *unmodified* docker-compose.yml
      // defaults. A wrapper that brought up the e2e overlay instead would run
      // the check happily against rewritten ports and pass.
      expect(
        wrapper.readAsStringSync(),
        contains(RegExp(r'docker compose -f docker-compose\.yml up')),
        reason:
            '${wrapper.path} no longer brings up the shipped '
            'docker-compose.yml on its own, so scripts/$check would be '
            'answering about whatever stack happened to be running',
      );
    });
  });

  group('the offline suite still measures the claim it prints', () {
    // W-6. The PASS line of the gate that runs on every push says
    // "verified: 127.0.0.1:<port> does not answer". Delete the curl above it
    // and **the sentence still prints** — an assertion about a measurement
    // nobody took, on the one claim that whole suite exists to make.
    final script = File('../scripts/run_offline_suite.sh');
    late final String source = script.readAsStringSync();

    test('the address the PASS line names is an address something probed', () {
      final claim = source
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .where((l) => l.contains('does not answer'))
          .toList();
      expect(
        claim,
        hasLength(1),
        reason:
            '${script.path} no longer prints exactly one "does not answer" '
            'claim. If the claim was removed on purpose this test is what '
            'needs updating; if it was duplicated, the assertions below read '
            'only the first:\n${claim.join('\n')}',
      );
      final address = RegExp(
        r'(127\.0\.0\.1:\$\{?\w+\}?)',
      ).firstMatch(claim.single);
      expect(
        address,
        isNotNull,
        reason:
            'the offline suite claims something does not answer without '
            'naming what:\n  ${claim.single}',
      );
      final probes = source
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .where((l) => l.contains('curl') && l.contains(address!.group(1)!))
          .toList();
      expect(
        probes,
        isNotEmpty,
        reason:
            '${script.path} prints "verified: ${address!.group(1)} does not '
            'answer" and nothing in it probes ${address.group(1)}.\n\n'
            'That sentence is the whole claim of the offline suite — every '
            'test in it is asserted to pass with no server reachable — and '
            'without the probe it is asserting a measurement nobody took. '
            '`docker compose down || true` swallows "brought it down" and '
            '"could not bring it down" into the same branch (W-6), so the '
            'teardown above is not evidence.',
      );
    });

    test('and the probe can stop the run', () {
      // A probe whose answer nobody acts on is not a control. This one has to
      // be able to abort before the suite runs at all: a suite that passed
      // with a server up has not demonstrated the thing it claims.
      final abort = RegExp(
        r'if curl[^\n]*\n(?:.*\n)*?\s*exit 1\n',
        multiLine: true,
      ).firstMatch(source);
      expect(
        abort,
        isNotNull,
        reason:
            "${script.path} probes the server port and never exits on the "
            'answer, so a stack that is still up produces a warning at most '
            'and the suite runs anyway — reporting "fully green with no '
            'server running" about a run that had one',
      );
    });
  });

  // Task 11.242. **A copy of a constant kept in a shell script is a
  // hand-maintained list, and this one had drifted.** `backup.sh` labels every
  // archive with the schema major its database is on — in the cleartext
  // sidecar and in the *signed* trusted comment restore.sh decides on — by a
  // chain of `-ge` thresholds, and `restore.sh` refuses an archive whose major
  // is above `SCHEMA_MAX`. Both said "2" from the day major 3 shipped
  // (task 11.219, 2026-09-10) until this test existed: every backup of a v14
  // or v15 server carried the wrong major, restore.sh would have refused a
  // correctly-labelled one, and `backup_restore_drill.sh` — which asserted
  // "2" too — passed throughout. Nothing read the constant. Now the history
  // is data (`schemaMajorFirstMinor`) and this group reads the scripts
  // against it: same shape as the healthcheck group above — a string in one
  // file naming something another file implements.
  group('the backup scripts agree with schemaMajorFirstMinor', () {
    late String backup;
    late String restore;

    setUpAll(() {
      backup = File('backup/backup.sh').readAsStringSync();
      restore = File('backup/restore.sh').readAsStringSync();
    });

    /// `backup.sh`'s threshold chain, derived: `{major: first minor}`, in
    /// file order, plus the `else` arm as major 1.
    List<MapEntry<int, int>> backupChain() {
      final arms = RegExp(
        r'\[ "\$SCHEMA_VERSION" -ge (\d+) \] 2>/dev/null; then\s*\n\s*SCHEMA_MAJOR=(\d+)',
      ).allMatches(backup).toList();
      expect(
        arms,
        isNotEmpty,
        reason:
            'backup.sh no longer maps the schema version to a major with '
            '`-ge N ... SCHEMA_MAJOR=M` arms, so this test is reading nothing; '
            'update the regex or the script, not the assertion',
      );
      final fallthrough = RegExp(
        r'else\s*\n\s*SCHEMA_MAJOR=(\d+)',
      ).firstMatch(backup);
      expect(
        fallthrough,
        isNotNull,
        reason: 'backup.sh must name the major a pre-threshold database is on',
      );
      return [
        for (final arm in arms)
          MapEntry(int.parse(arm.group(2)!), int.parse(arm.group(1)!)),
        MapEntry(int.parse(fallthrough!.group(1)!), 1),
      ];
    }

    test('backup.sh labels an archive with the major its schema is on', () {
      final chain = backupChain();
      expect(
        {for (final e in chain) e.key: e.value},
        schemaMajorFirstMinor,
        reason:
            "backup.sh's threshold chain is a copy of schemaMajorFirstMinor. "
            'A major was bumped (or the map was edited) and the script was '
            'not: add an `elif [ "\$SCHEMA_VERSION" -ge <first minor> ]` arm '
            'setting SCHEMA_MAJOR to the new major, highest first.',
      );
    });

    test('and tests the thresholds highest first, so the chain is correct', () {
      // An `if/elif` chain takes the first true arm. Thresholds out of order
      // would label a v16 database as major 2 while every arm is present.
      final thresholds = backupChain().map((e) => e.value).toList();
      for (var i = 1; i < thresholds.length; i++) {
        expect(
          thresholds[i],
          lessThan(thresholds[i - 1]),
          reason:
              'backup.sh tests `-ge ${thresholds[i]}` after '
              '`-ge ${thresholds[i - 1]}`; the higher threshold must come first',
        );
      }
    });

    test('and agrees with what the package computes for every version', () {
      // The chain as bash evaluates it, against schemaMajorFor — so a
      // subtle off-by-one in a threshold cannot hide behind the map matching.
      final chain = backupChain();
      for (var minor = 1; minor <= latestSchemaVersion; minor++) {
        final labelled = chain.firstWhere((e) => minor >= e.value).key;
        expect(
          labelled,
          schemaMajorFor(minor),
          reason: 'a database at schema v$minor',
        );
      }
    });

    test(
      "restore.sh accepts archives up to and including this build's major",
      () {
        final max = RegExp(
          r'^SCHEMA_MAX=(\d+)$',
          multiLine: true,
        ).firstMatch(restore);
        expect(max, isNotNull, reason: 'restore.sh must declare SCHEMA_MAX');
        expect(
          int.parse(max!.group(1)!),
          schemaMajorVersion,
          reason:
              'restore.sh refuses an archive whose major is above SCHEMA_MAX, '
              "and a backup this build's own backup.sh takes is labelled "
              'major $schemaMajorVersion — so a stale SCHEMA_MAX refuses the '
              "server's own backups. Update it in the same commit as "
              'schemaMajorVersion.',
        );
        final min = RegExp(
          r'^SCHEMA_MIN=(\d+)$',
          multiLine: true,
        ).firstMatch(restore);
        expect(min, isNotNull, reason: 'restore.sh must declare SCHEMA_MIN');
        expect(
          int.parse(min!.group(1)!),
          lessThanOrEqualTo(schemaMajorVersion),
        );
      },
    );

    test('backup_restore_drill.sh reads the major from the constant rather '
        'than typing it', () {
      // The drill asserted `schema_major=2` in three places and passed for a
      // week against a v14 server, because backup.sh had the same stale
      // copy. It derives the number now; a literal creeping back in is the
      // same defect returning.
      final drill = File(
        '../scripts/backup_restore_drill.sh',
      ).readAsStringSync();
      expect(
        drill,
        contains('schemaMajorVersion = '),
        reason:
            'the drill must read schemaMajorVersion out of '
            'schema_constants.dart',
      );
      final literals = RegExp(r'schema_major=(\d+)')
          .allMatches(drill)
          .map((m) => int.parse(m.group(1)!))
          .where((m) => m == schemaMajorVersion)
          .toList();
      expect(
        literals,
        isEmpty,
        reason:
            'backup_restore_drill.sh names the current major as a literal; '
            'use \$EXPECTED_MAJOR, which it reads from schema_constants.dart. '
            'Literals for *other* majors are forged sidecars and are fine.',
      );
    });
  });

  // Task 11.287. A production server used to resolve `NullEmailSender` and
  // deliver nothing while answering 202 to every sign-in request — §4.5's
  // identical response hiding a total outage. The sender is measured in
  // `test/auth/smtp_email_sender_test.dart`; this is the shipped-configuration
  // half: the relay's variables have to reach the container from `.env`, with
  // no default, through both the base file and the overlay that ships.
  group('the shipped compose files can name a sign-in relay (task 11.287)', () {
    const passthroughs = [
      'TRITRACK_SMTP_HOST',
      'TRITRACK_SMTP_PORT',
      'TRITRACK_SMTP_TLS',
      'TRITRACK_SMTP_USERNAME',
      'TRITRACK_SMTP_PASSWORD',
      'TRITRACK_SMTP_FROM',
    ];

    test('the base file passes every relay variable through with no default', () {
      final server = _service(compose, 'server');
      for (final name in passthroughs) {
        expect(
          server,
          contains('$name: \${$name:-}'),
          reason:
              'docker-compose.yml must pass $name from .env with an empty '
              'default — a default relay would be this repository naming a '
              'provider on the operator\'s behalf, and a missing line would '
              'make the variable in .env.example unreachable',
        );
      }
      // The CA file is the one that is not a plain passthrough: the host path
      // is mounted and the container path is derived from whether it was set.
      expect(
        server,
        contains(
          r'TRITRACK_SMTP_CA_CERT_PATH: ${TRITRACK_SMTP_CA_CERT:+/tls/smtp-ca.pem}',
        ),
      );
      expect(
        server,
        contains(r'${TRITRACK_SMTP_CA_CERT:-/dev/null}:/tls/smtp-ca.pem:ro'),
      );
    });

    test('the TLS overlay — the deployment that ships — still carries them', () {
      // `environment:` maps merge, `volumes: !override` does not; task 11.223
      // is the memory of what that asymmetry cost. Assert against the real
      // merge rather than either file.
      final merged = _mergedConfig([
        'docker-compose.yml',
        'docker-compose.tls.yml',
      ]);
      final server = _service(merged, 'server');
      for (final name in passthroughs) {
        expect(
          server,
          contains('$name:'),
          reason: '$name dropped by the merge',
        );
      }
      expect(
        server,
        matches(RegExp(r'target: /tls/smtp-ca\.pem')),
        reason:
            'docker-compose.tls.yml replaces the server\'s volume list and '
            'must repeat the CA mount, or TRITRACK_SMTP_CA_CERT is a variable '
            'that does nothing in production',
      );
    });

    test('.env.example lists every relay variable, empty (§4.6)', () {
      final example = File('../.env.example').readAsStringSync();
      for (final name in [...passthroughs, 'TRITRACK_SMTP_CA_CERT']) {
        expect(
          example,
          contains('\n$name=\n'),
          reason:
              '§4.6: the required set must be discoverable without possessing '
              'a secret — $name belongs in .env.example with an empty value',
        );
      }
    });

    test(
      'the entry point resolves the sender once, at startup, and refuses',
      () {
        // Once, not per request: a refusal has to happen before the server is
        // serving, and a relay's credentials should be read one time rather
        // than on every sign-in.
        expect(
          RegExp(r'= resolveEmailSender\(').allMatches(entryPoint).length,
          1,
          reason: 'bin/server.dart should call resolveEmailSender exactly once',
        );
        expect(entryPoint, contains('REFUSING TO START — sign-in email'));
        // And the probe that puts the relay\'s answer in the boot log.
        expect(entryPoint, contains('.probe()'));
        expect(entryPoint, contains('--send-test-email'));
      },
    );
  });
}
