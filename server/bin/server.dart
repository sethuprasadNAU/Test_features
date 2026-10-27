import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tritrack_server/tritrack_server.dart';

/// Entry point for both `dart run bin/server.dart` (bare-metal dev) and the
/// Docker image built from `server/Dockerfile`.
///
/// **What interface this binds is now a decision, not a constant** (task 10.14,
/// `TriTrack_Security_Model.md` §4.1). It was `InternetAddress.anyIPv4`
/// unconditionally through task 10.13, which meant a deployment that forgot to
/// configure anything published session tokens and coordinates in cleartext to
/// whatever network it landed on. [TransportSecurityConfig] resolves the
/// posture instead: TLS if configured, cleartext-on-all-interfaces only with an
/// explicit opt-in that is refused in production, and **loopback-only by
/// default** so a forgotten setting fails closed.
Future<void> main(List<String> args) async {
  // **`--health-check` is a second mode of this same binary, not a second
  // program** (task 11.128, at Michael's request). The runtime image is
  // `debian:bookworm-slim` with `ca-certificates` and nothing else — no `curl`,
  // no `wget` — and the Dockerfile says in as many words that it carries no
  // Dart SDK because a smaller image is a smaller attack surface. Installing an
  // HTTP client to check on an HTTP server would spend exactly what that
  // decision bought. `audit-retention --check` already established the shape.
  //
  // Answered before anything else in this function, because none of the
  // startup work below is meaningful for a probe: this process is not the
  // server, it is a short-lived question asked of the server next door.
  if (args.contains('--health-check')) {
    exit(await _runHealthCheck());
  }

  // **A third mode of the same binary, and it is the one that has to work when
  // nothing else does** (task 11.129). It reads a file and touches no database
  // — which is the whole point, because the record it prints exists precisely
  // for the outage in which every database-backed answer is unavailable.
  //
  // Same argument as `--health-check` above for why it is a flag rather than a
  // script: the runtime image is `debian:bookworm-slim` with `ca-certificates`
  // and nothing else.
  if (args.contains('--degradation-report')) {
    // ignore: avoid_print
    print(
      describeDegradationRecord(
        readDegradationRecord(DegradationRecord.pathFrom(Platform.environment)),
      ),
    );
    exit(0);
  }

  // **A fourth mode, and the shortest-lived of them** (task 11.158). It asks
  // the database one question — how many stored rows would the widened
  // numeric rule newly refuse — prints the answer with its interpretation
  // already attached, and exits. A flag rather than a script for the same
  // reason as the three above: the runtime image carries no Dart SDK and no
  // psql, and the column list has to come from `tableSpecs` rather than from
  // a list somebody typed.
  if (args.contains('--numeric-population')) {
    exit(await _runNumericPopulation());
  }

  // **A fifth mode, and the one that closes task 11.287** — or rather, the
  // one that lets Michael close it. Everything else about sign-in email can
  // be proven against a local catcher; whether a link reaches a real inbox
  // through NAU's relay can only be proven by sending one. This sends a test
  // message (no link) through the configured relay and reports what the relay
  // said. Same argument as the four modes above for why it is a flag: the
  // runtime image carries no Dart SDK, so `docker compose run --rm --no-deps
  // server --send-test-email you@example.edu` is the only way to run it where
  // the real configuration lives.
  final testEmailAt = args.indexOf('--send-test-email');
  if (testEmailAt != -1) {
    exit(await _runSendTestEmail(args, testEmailAt));
  }

  final startedAt = DateTime.now();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // Read before anything else: a contradictory transport configuration
  // (cleartext-LAN in production, half-configured TLS, cleartext on a machine
  // with a public address) must stop the process rather than be discovered
  // after it is already serving. Unlike the diagnostics console, this one does
  // not degrade — the console is optional, the transport is not.
  //
  // `resolve`, not `fromEnvironment`: the latter is only the environment half
  // and skips the private-range check that task 10.22 added (§4.1's second
  // condition, Gate C finding C-3).
  //
  // Caught and reported rather than left to the default unhandled-exception
  // handler: a refusal nobody can read is a support call. A `Bad state:` line
  // wrapped in a stack trace, in a container that then restart-loops, is how a
  // correct control gets diagnosed as "the server is broken" and switched off.
  final TransportSecurityConfig transport;
  try {
    transport = await TransportSecurityConfig.resolve();
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      '\nTriTrack server: REFUSING TO START — transport security\n\n'
      '${error.message}\n\n'
      'See server/README.md, "Transport security", for the full decision '
      'table.\n',
    );
    // 78 is sysexits.h EX_CONFIG: the configuration is wrong, retrying it
    // unchanged cannot help. `restart: unless-stopped` will still loop, but the
    // message above is printed in full on every pass.
    exit(78);
  }

  // Read next, and with the same refusal posture as the transport above —
  // and before the diagnostics console below, which also refuses now (task
  // 10.80) but is optional: when a deployment has both problems, the one
  // that governs everybody's rate limit and every audit row is the one the
  // operator should read first. The rate-limit policy further down still
  // degrades (task 10.52, Security Model §4.4).
  //
  // **Task 10.62 widened what this refuses.** Through 10.52 the question was
  // asked only under TRITRACK_ENV=production, which is not what the README's
  // LAN walkthrough is; there the server started, called every caller
  // `direct`, and merged them all into one bucket anyway, because Docker's
  // publish path had already rewritten their addresses (finding J-2, §12.4).
  // The trigger is now reachability — TRITRACK_PUBLISH_ADDRESS, which the
  // compose files pass in because the container cannot see it — and `none` is
  // no longer an acceptable answer for a reachable deployment, because `none`
  // is a claim about the network path rather than about this configuration.
  //
  // **Degrading here would reproduce finding I-1 exactly.** Behind an
  // undeclared reverse proxy every request's TCP peer is the proxy, so §4.4's
  // per-source limit becomes one bucket shared by every user of the
  // deployment — ten unauthenticated requests deny sign-in to everybody, and
  // every audit row names the proxy instead of the caller. That is not a
  // degraded control, it is an inverted one: the rule written to stop a botnet
  // bombing one colleague becomes a lever any stranger can pull on all of
  // them. A server that quietly picked a default here would be making that
  // choice on the operator's behalf, silently, which is how the requirement
  // filed on 2026-08-07 got past task 10.49 and four security gates.
  final TrustedProxies trustedProxies;
  try {
    trustedProxies = TrustedProxies.fromEnvironment();
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      '\nTriTrack server: REFUSING TO START — source identity\n\n'
      '${error.message}\n',
    );
    exit(78);
  }
  if (!trustedProxies.isEmpty) {
    // ignore: avoid_print
    print(
      'Trusted proxies declared: X-Forwarded-For will be read from those '
      'peers and from no others.',
    );
  }

  // Read here — after the transport and the source-identity question, both of
  // which are mandatory, and before the database, which is slow. Every refusal
  // below is a typo in `.env`, and making the operator wait through a Postgres
  // connection attempt to be told about one is the difference between a
  // two-second correction and a puzzled minute. It needs the transport's
  // answer, so it cannot come any earlier than this.
  // Off unless explicitly turned on, in every environment — see
  // [DiagnosticsConfig]'s doc comment.
  //
  // **Task 10.80 turned this from a graceful degrade into a refusal, and the
  // reversal is deliberate.** Through 10.79 a misconfigured console printed a
  // line and started with the console off, on the reasoning that sync and auth
  // for real users must not go down for an optional debugging tool. That
  // reasoning does not survive the question "who does this happen to": every
  // refusal `fromEnvironment` raises fires *only* when somebody set
  // TRITRACK_DIAGNOSTICS_ENABLED=true, so the affected deployment is one whose
  // operator asked for the console — and what they got was a server that
  // started normally and answered 404 on every diagnostics route, which is
  // indistinguishable from the console being off, from a typo in the URL, and
  // from a build without the feature. That is finding D-5's shape exactly: an
  // evening spent debugging a working server.
  //
  // A refusal costs the same operator one line of output and one variable to
  // change, and it costs a deployment that never asked for the console
  // nothing at all, because none of these checks can fire there.
  final DiagnosticsConfig diagnostics;
  try {
    diagnostics = DiagnosticsConfig.fromEnvironment(
      null,
      // Resolved above, before anything binds a socket. `allowRemote` without
      // TLS is refused there rather than here, because this file must not be
      // the place that decides what the transport guarantees.
      tlsEnabled: transport.tlsEnabled,
    );
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      '\nTriTrack server: REFUSING TO START — diagnostics console\n\n'
      '${error.message}\n\n'
      'See server/README.md, "The diagnostics console", for the full '
      'procedure.\n',
    );
    // 78 is sysexits.h EX_CONFIG, same as the transport refusal above: the
    // configuration is wrong and retrying it unchanged cannot help.
    exit(78);
  }

  // **Who delivers the sign-in link — decided once, here, and refused in
  // production when the answer is nobody** (task 11.287). Until then this was
  // `resolveEmailSender()` called inside every request's transaction, and in
  // production it returned the silent sender: every `POST /auth/magic-link`
  // answered `202` and delivered nothing. That was §4.5 working exactly as
  // designed — the response must not vary with delivery — and it hid a total
  // outage behind the account-enumeration defense. Sign-in is the first thing
  // anybody does with this server and it was the first thing that failed.
  //
  // Placed after the diagnostics console on purpose: `verify_deployment_
  // refusal_matrix.sh` checks that a production deployment with the console
  // on refuses *for the console's reason*, and a refusal here would otherwise
  // pre-empt it. The order does not matter to an operator who has both
  // problems; they will meet the second one on the next boot.
  final EmailSender emailSender;
  try {
    emailSender = resolveEmailSender();
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      '\nTriTrack server: REFUSING TO START — sign-in email\n\n'
      '${error.message}\n\n'
      'See server/README.md, "Sign-in email", for the variables and how to '
      'check delivery.\n',
    );
    exit(78);
  }
  switch (emailSender) {
    case SmtpEmailSender(:final config):
      // ignore: avoid_print
      print('Sign-in email: relay ${config.describe()}; checking it now.');
      // Not awaited: a relay that is down should not keep `/health` from
      // answering, and a relay that is slow should not delay the boot. The
      // result lands in the log a moment later, with the same prefix, so
      // `docker compose logs server | grep "Sign-in email"` tells the whole
      // story either way.
      unawaited(
        SmtpClient(config).probe().then(
          (result) =>
              // ignore: avoid_print
              print(
                'Sign-in email: relay ${config.host}:${config.port} '
                'answered as "${result.greeting}"'
                '${result.tlsEstablished ? ", TLS established" : ""}'
                '${result.authenticated ? ", credentials accepted" : ""}'
                '. No message was sent; the first real sign-in is the '
                'first delivery.',
              ),
          onError: (Object error) {
            final detail = error is SmtpException
                ? error.message
                : error.runtimeType.toString();
            // ignore: avoid_print
            print(
              'Sign-in email: WARNING — relay ${config.host}:${config.port} '
              'could not be used: $detail. The server is running, and '
              'every sign-in request will still answer 202, but NO LINK '
              'WILL ARRIVE until this is fixed. Check TRITRACK_SMTP_* in '
              '.env and recreate the server container.',
            );
          },
        ),
      );
    case FileEmailSender(:final directory):
      // ignore: avoid_print
      print('Sign-in email: written to ${directory.path} (development).');
    default:
      // ignore: avoid_print
      print(
        'Sign-in email: NOT CONFIGURED. Sign-in requests answer 202 and no '
        'link goes anywhere. Set TRITRACK_DEV_MAGIC_LINK_DIR for development, '
        'or TRITRACK_SMTP_* for a real relay.',
      );
  }

  // The database is optional at startup so `/health` still answers without
  // one — useful for container orchestration, and it keeps a misconfigured
  // database from looking like a dead server. Auth simply isn't mounted.
  Connection? connection;
  Connection? auditConnection;
  try {
    final config = DatabaseConfig.fromEnvironment();
    connection = await Connection.open(
      config.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await PostgresMigrations.run(connection);
    // Task 10.63 (Security Model §12.5, finding J-3): from here down, every
    // statement this connection sends for the rest of the process's life runs
    // without the superuser attribute `config.username` holds. Migrations
    // above needed that attribute for DDL; the sync and auth traffic this
    // connection serves afterward does not, and demoting it is what removes
    // `COPY ... FROM PROGRAM` from whatever a future injection or driver bug
    // could reach through it. `ensureServerAppRole` already ran inside
    // [PostgresMigrations.run], so the role and its grants exist by now.
    await assumeServerAppRole(connection);
    // A connection of its own, never shared with `connection`. `postgres`
    // refuses a second statement on a connection while that same connection's
    // `runTx` is open, so an audit write issued from inside the sync or auth
    // handler's transaction — on `connection` — would be refused every time.
    // That is Security Model §7.3 B5 (task 10.23): `authorization_denied`
    // rows were silently lost 100% of the time this way. See [AuthAuditLog].
    auditConnection = await Connection.open(
      config.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    // Same demotion, task 10.63 — this connection never runs migrations, so
    // the role it assumes here is the one `connection` above just ensured.
    await assumeServerAppRole(auditConnection);
    // ignore: avoid_print
    print('Connected to Postgres; auth routes enabled.');
  } on Object catch (error) {
    // Never interpolate the error object into a log line that might carry the
    // connection string — §4.7's never-log list includes it. The type alone is
    // enough to tell a developer what to look at.
    // ignore: avoid_print
    print(
      'No database available (${error.runtimeType}); serving /health and '
      '/ready only. GET /ready answers 503 for as long as this lasts. '
      'Set POSTGRES_* to enable authentication.',
    );
    // Either connection can fail independently after the other opened; treat
    // that the same as no database at all rather than serving with one half
    // of the audit story missing.
    await connection?.close();
    connection = null;
    await auditConnection?.close();
    auditConnection = null;
  }

  final db = connection;
  final auditDb = auditConnection;
  final publicUrl =
      Platform.environment['TRITRACK_PUBLIC_URL'] ?? 'http://localhost:$port';

  if (diagnostics.enabled && db != null) {
    // ignore: avoid_print
    print(
      'Diagnostics console enabled '
      '(${diagnostics.allowRemote ? "reachable remotely" : "localhost only"}).',
    );
  }

  // Same graceful-degrade posture as diagnostics above: refusing outright
  // would take auth down for a rate-limiter misconfiguration, which is a far
  // smaller failure than the transport check above guards against.
  RateLimitPolicy rateLimitPolicy;
  try {
    rateLimitPolicy = RateLimitPolicy.fromEnvironment();
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      'Rate limit policy misconfigured (${error.message}); using '
      'defaults.',
    );
    rateLimitPolicy = const RateLimitPolicy();
  }

  Response unauthorized() => Response(
    401,
    body: jsonEncode({'error': 'unauthorized'}),
    headers: const {'content-type': 'application/json'},
  );

  // **The record that survives the database** (task 11.129). Opened here,
  // while the server is healthy, and it writes the file immediately — a
  // fallback whose own writability is first discovered during the outage is
  // the same defect one layer out, and a reader finding no file could
  // otherwise not tell "nothing has failed" from "nothing could be written".
  // See `degradation_record.dart` for what it may contain and why it names
  // nobody.
  final degradationPath = DegradationRecord.pathFrom(Platform.environment);
  final degradation = await DegradationRecord.open(
    degradationPath,
    // ignore: avoid_print
    onWriteFailure: (type) => print('degradation record write failed: $type'),
    startedAt: startedAt,
  );
  if (degradation == null) {
    // Not fatal: §1 ranks server availability last but not at zero, and
    // refusing to serve because a log file is unwritable would be the same
    // trade the audit log already refuses to make. But it is said loudly and
    // completely, here, where somebody is looking at the startup output —
    // because during the outage nothing will be able to say it.
    // ignore: avoid_print
    print(
      'WARNING: no durable degradation record. $degradationPath is not '
      'writable, so if the database becomes unreachable there will be no '
      'lasting record that sign-ins were refused — only these stdout lines, '
      'which go wherever this process\'s output goes. Set '
      '$degradationPathVariable to a writable path.',
    );
  }

  // Type only, never the exception — a Postgres message can carry column
  // values, and §4.7 rule 6 has no development exemption.
  void onAuditError(String type) {
    // ignore: avoid_print
    print('audit log write failed: $type');
    // The durable half. `print` goes to a container's stdout, which is
    // rotated, unqueryable and gone with the container; this survives both.
    degradation?.auditWriteLost();
  }

  final handler = createHandler(
    withAuthService: db == null
        ? null
        : <T>(action) => db.runTx((tx) async {
            return action(
              AuthService(
                session: tx,
                emailSender: emailSender,
                linkBaseUrl: publicUrl,
              ),
            );
          }),
    // Every sync and project-directory route needs a valid session, resolved
    // here — the one place a bearer token becomes an ActiveSession. Both
    // routers (task 10.7's sync, task 10.9's project directory) share this so
    // there is exactly one authentication path to reason about.
    withSyncContext: db == null
        ? null
        : (request, action) async {
            final token = bearerToken(request);
            if (token == null) return unauthorized();
            return db.runTx((tx) async {
              final auth = AuthService(
                session: tx,
                emailSender: emailSender,
                linkBaseUrl: publicUrl,
              );
              final session = await auth.validateSession(token);
              if (session == null) return unauthorized();
              return action(
                SyncContext(
                  sync: SyncService(session: tx),
                  cursors: CursorStore(tx),
                  session: session,
                  trafficLog: SyncTrafficLogStore(tx),
                ),
              );
            });
          },
    diagnosticsConfig: diagnostics,
    withDiagnostics: db == null || auditDb == null || !diagnostics.enabled
        ? null
        : (request, action) async => action(
            DiagnosticsContext(
              repo: DiagnosticsRepository(db),
              trafficLog: SyncTrafficLogStore(db),
              auditLog: AuthAuditLog(auditDb, onError: onAuditError),
            ),
          ),
    diagnosticsStartedAt: startedAt,
    // Readiness, task 11.128. Synchronous and query-free by design — see
    // `readiness.dart`: `/ready` is unauthenticated, so a probe that issued a
    // statement would make one anonymous request cost one database round trip,
    // and on the single connection this process holds it would also lose the
    // race against any request whose `runTx` was open.
    //
    // `isOpen` is `package:postgres`'s own view of the socket, and it goes
    // false when the connection is closed either explicitly or by an
    // unrecoverable server error. That covers the database going away under a
    // running server, which the mounted-routes check alone cannot see: those
    // closures are decided once at startup and never revisited.
    //
    // **Both connections, not just `db`.** The startup path already treats one
    // of the two failing as no database at all, because a server serving sync
    // with no audit connection is serving with half the audit story missing
    // (task 10.23). Readiness has to say the same thing the startup path says
    // or the two disagree about what "has a database" means.
    readiness: () => {
      if (db == null || auditDb == null || !db.isOpen || !auditDb.isOpen)
        Subsystem.database,
    },
    // Outside any transaction, deliberately, and on its own connection: an
    // audit row records that a request happened, which stays true even when
    // the request's own work rolls back — and `auditDb` never has a `runTx`
    // of its own for a write here to collide with (task 10.23; see
    // [AuthAuditLog]'s note on the bug this replaced).
    withAuditLog: db == null || auditDb == null
        ? null
        : (action) => action(AuthAuditLog(auditDb, onError: onAuditError)),
    // One limiter for the process lifetime, so its counters actually
    // accumulate. In-process state is §4.4's explicit prototype shortcut and
    // is a documented deployment precondition — see the server README.
    rateLimiter: RateLimiter(policy: rateLimitPolicy),
    // One resolver for the process lifetime, for the same reason as the
    // limiter: the degenerate-source warning is throttled per instance, and a
    // per-request resolver would print it on every request instead.
    sourceIdentity: SourceIdentity(
      trustedProxies: trustedProxies,
      // ignore: avoid_print
      log: print,
    ),
    tlsEnabled: transport.tlsEnabled,
  );

  if (transport.isCleartextBeyondLoopback) {
    // ignore: avoid_print
    print(transport.startupWarning);
  }

  final server = await shelf_io.serve(
    handler,
    transport.address,
    port,
    securityContext: transport.securityContext(),
    // shelf_io defaults to an `X-Powered-By: Dart with package:shelf` header
    // on every response — exactly the dependency-fingerprinting information
    // `/health` (and every other route) must not hand an opportunistic
    // scanner for free (`TriTrack_Security_Model.md` §2.2).
    poweredByHeader: null,
  );
  // ignore: avoid_print
  print(
    'TriTrack server listening on '
    '${transport.tlsEnabled ? 'https' : 'http'}://'
    '${server.address.address}:${server.port}'
    '${transport.scope == BindScope.loopback ? ' (loopback only)' : ''}',
  );
  if (transport.scope == BindScope.loopback) {
    // ignore: avoid_print
    print(
      'Not reachable from other machines. To let a phone on the same Wi-Fi '
      'reach this dev server, set TRITRACK_ALLOW_CLEARTEXT_LAN=1; for any '
      'real deployment configure TRITRACK_TLS_CERT_PATH and '
      'TRITRACK_TLS_KEY_PATH instead.',
    );
  }

  // `docker compose down` and `docker stop` send SIGTERM, and the degradation
  // record coalesces its writes (task 11.129) — so without this, up to five
  // seconds of counts from an outage that is still running would be lost at
  // exactly the moment somebody restarts the stack to fix it. The first loss
  // of any burst is already on disk unconditionally; this is the tail.
  if (degradation != null) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await degradation.close();
      await server.close(force: true);
      exit(0);
    });
  }
}

/// The container healthcheck: asks the server next door whether it is alive,
/// and says what it found.
///
/// **The verdict is LIVENESS — `/health` — and that is the decision, not an
/// oversight.** A healthcheck is the slot a restart hangs off; readiness must
/// never drive one, because restarting this container cannot make an
/// unreachable database reachable. See `readiness.dart` for the whole split.
///
/// **But it reports readiness in its message**, because Docker keeps the
/// output of each probe and this project's standing rule is that an
/// instrument's last words must be a finding rather than a name (task 11.69).
/// A `docker compose ps` that says `healthy` on a server where nobody can sign
/// in is the same reassuring-but-true-in-the-wrong-sense answer this whole task
/// exists to correct, so the health log carries the readiness sentence even
/// though the exit code deliberately ignores it.
///
/// Task 11.158's measurement, run against this deployment's database.
///
/// **Read-only, and it opens its own connection** — it is a one-off question,
/// not part of serving. It names the deployment it read (task 11.141): a run
/// against a throwaway local stack must not read the same as a run against
/// the beta server.
///
/// Returns a process exit code: 0 when the question was answered, 1 when it
/// was not. **Never non-zero for a large count** — that is a finding for a
/// person to act on, not a failure of the instrument.
Future<int> _runNumericPopulation() async {
  Connection? connection;
  try {
    final config = DatabaseConfig.fromEnvironment();
    connection = await Connection.open(
      config.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    final report = await measureNumericPopulation(
      deployment:
          '${config.username}@${config.host}:${config.port}/${config.database} '
          '(asked from ${Platform.localHostname})',
      query: (sql) async {
        final result = await connection!.execute(sql);
        return result.map((row) => row.toList()).toList();
      },
    );
    // ignore: avoid_print
    print(describeNumericPopulation(report));
    return 0;
  } on Object catch (error) {
    // The type only. §4.7 rule 6 has no exemption for a one-off command, and
    // a connection failure's message can carry a host and a user name.
    // ignore: avoid_print
    print(
      'COULD NOT CHECK — the database did not answer '
      '(${error.runtimeType}). No rows were read. That is not the same as '
      'zero rows found.',
    );
    return 1;
  } finally {
    await connection?.close();
  }
}

/// Returns a process exit code: 0 healthy, 1 not.
Future<int> _runHealthCheck() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // **Both schemes are tried, and the probe reads no configuration at all.**
  // Under `docker-compose.tls.yml` the origin itself serves https with a
  // self-signed pair, so a hard-coded `http://` probe would report every TLS
  // deployment dead. The obvious fix — ask [TransportSecurityConfig] which one
  // is configured — is the wrong one twice over: it would put a second copy of
  // `tlsEnabled`'s meaning in a file that does not own it, and it would make
  // this probe's answer depend on a policy decision rather than on what is
  // actually listening. `shipped_defaults_test.dart` also, correctly, forbids
  // this file from calling `fromEnvironment` at all, because doing so in the
  // *server's* path was finding C-3.
  //
  // So the question stays the narrow one a probe can actually answer: does
  // something on this container's own loopback answer `/health` over either
  // transport? The second attempt costs one refused connection, and only in
  // the case that is about to be reported unhealthy anyway.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  // **Loopback only, and identity is not what this measures.** The origin
  // certificate under the TLS overlay is self-signed on purpose — Caddy is what
  // presents a trusted one to the world — so verifying it here would fail by
  // design. The check is "does the process on this container's own loopback
  // answer", and nothing about that is a claim about who it is.
  client.badCertificateCallback = (_, host, _) => host == '127.0.0.1';

  // `status` is null when nothing answered at all — a refused connection or a
  // timeout, which is a different fact from a server that answered 500 and
  // must not be reported as one. `detail` carries the exception TYPE only:
  // §4.7 rule 6 has no healthcheck exemption, and Docker stores this string
  // where `docker inspect` prints it back.
  Future<({int? status, String detail})> at(Uri base, String path) async {
    try {
      final request = await client.getUrl(base.replace(path: path));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      return (status: response.statusCode, detail: body.trim());
    } on Object catch (error) {
      return (status: null, detail: error.runtimeType.toString());
    }
  }

  // Cleartext first: it is what every deployment except the TLS overlay uses,
  // so the second attempt is the rare one rather than the common one.
  var base = Uri.parse('http://127.0.0.1:$port');
  var liveness = await at(base, '/health');
  if (liveness.status == null) {
    final https = Uri.parse('https://127.0.0.1:$port');
    final overTls = await at(https, '/health');
    if (overTls.status != null) {
      base = https;
      liveness = overTls;
    }
  }
  final readiness = await at(base, '/ready');
  client.close(force: true);

  if (liveness.status != 200) {
    final detail = liveness.status == null
        ? 'did not answer (${liveness.detail})'
        : 'answered ${liveness.status}';
    // ignore: avoid_print
    print(
      'unhealthy: $base/health $detail. The process is not serving. '
      'Check the container logs — a restart is the remedy for this one.',
    );
    return 1;
  }

  // **One of the two things that read the durable record** (task 11.129), and
  // the only one that runs without somebody deciding to look. Docker keeps
  // each probe's output, so a `docker compose ps` reading `healthy` still
  // carries the sentence "the audit log lost writes this morning" — for as
  // long as `recentWindow`, after which it stops nagging and
  // `--degradation-report` is where the history lives.
  //
  // **It never changes the exit code.** A gap that has already happened is not
  // a reason to restart anything, and readiness does not decide health here
  // for the same reason (task 11.128).
  final gap = recentDegradationSentence(
    readDegradationRecord(DegradationRecord.pathFrom(Platform.environment)),
  );

  // Healthy either way from here down. Only the sentence changes.
  if (readiness.status == 200) {
    // ignore: avoid_print
    print(
      'healthy: alive, and ready — it holds a working database connection'
      '${gap == null ? '' : '\n$gap'}',
    );
    return 0;
  }

  final degraded = _degradedFrom(readiness.detail) ?? 'unknown';
  // ignore: avoid_print
  print(
    'healthy: alive, but NOT READY — degraded: $degraded. Sign-in and sync '
    'are dead while this lasts. **This container is still reported healthy on '
    'purpose**: /health is a liveness probe, and restarting cannot reach a '
    'database that is down (task 11.128). Ask $base/ready, and fix what it '
    'names.'
    '${gap == null ? '' : '\n$gap'}',
  );
  return 0;
}

/// Pulls the `degraded` list out of `/ready`'s body for the health log.
///
/// Returns null rather than guessing if the body is not the shape this server
/// sends — a healthcheck that invented a cause would be the wrong-cause defect
/// this task's own reporting rules exist to prevent, in the one place nobody
/// re-reads.
String? _degradedFrom(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map<String, Object?>) return null;
    final degraded = json['degraded'];
    if (degraded is! List || degraded.isEmpty) return null;
    return degraded.whereType<String>().join(', ');
  } on FormatException {
    return null;
  }
}

/// `--send-test-email <address>`: one message through the configured relay,
/// then a verdict. Exit 0 when the relay accepted it, 78 when the
/// configuration is refused (same code as every other refusal here), 1 when
/// the relay would not take it. The message names the relay and never the
/// credentials.
Future<int> _runSendTestEmail(List<String> args, int flagAt) async {
  final address = flagAt + 1 < args.length ? args[flagAt + 1] : null;
  if (address == null || !isDeliverableAddress(address)) {
    // ignore: avoid_print
    print(
      'Usage: server --send-test-email <address>\n'
      'The address must be a plain one (one @, no spaces or brackets).',
    );
    return 64; // EX_USAGE
  }
  final SmtpConfig config;
  try {
    config = SmtpConfig.fromEnvironment(Platform.environment);
  } on StateError catch (error) {
    // ignore: avoid_print
    print(
      'Sign-in email: cannot send — ${error.message}\n'
      'See .env.example for TRITRACK_SMTP_*.',
    );
    return 78;
  }
  // ignore: avoid_print
  print(
    'Sign-in email: sending a test message to $address via '
    '${config.describe()} ...',
  );
  final message = buildTestMessage(
    from: config.from,
    to: address,
    now: DateTime.now().toUtc(),
    messageId: newMessageId(
      config.from.substring(config.from.indexOf('@') + 1),
    ),
    relay: '${config.host}:${config.port}',
  );
  try {
    await SmtpClient(
      config,
    ).send(from: config.from, to: address, message: message);
  } on Object catch (error) {
    final detail = switch (error) {
      SmtpException(:final message) => message,
      SocketException(:final message, :final osError) =>
        'connection failed: ${osError?.message ?? message}',
      TlsException(:final message) => 'TLS failed: $message',
      TimeoutException() =>
        'the relay did not answer within ${config.timeout.inSeconds}s',
      _ => error.runtimeType.toString(),
    };
    // ignore: avoid_print
    print(
      'Sign-in email: FAILED — $detail.\n'
      'Nothing was delivered. Sign-in links would fail the same way.',
    );
    return 1;
  }
  // ignore: avoid_print
  print(
    'Sign-in email: the relay ACCEPTED the message for $address.\n'
    'That is the relay\'s promise, not delivery — now check the inbox '
    '(and its spam folder). A message that arrives is the whole proof; a '
    'message that does not is a question for whoever runs the relay, since '
    'this server\'s part is done.',
  );
  return 0;
}
