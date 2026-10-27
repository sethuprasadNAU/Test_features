/// What `/ready` is allowed to say, and why there is a `/ready` at all.
///
/// **The distinction this file exists to make, because nothing stated it
/// before (task 11.128).** A server process can be in three states, and until
/// this file there was one endpoint for all three:
///
/// - **Alive.** The process is running and answering HTTP. Restarting it is
///   the remedy for the opposite of this, and for nothing else.
/// - **Ready.** It can actually do its job — for this server, that means it
///   holds a working Postgres connection, because every route except
///   `/health` and `/ready` needs one.
/// - **Neither.**
///
/// `/health` answers the first question only, and `bin/server.dart` deliberately
/// starts without a database (the server-optional seam, task 10.2) — so a
/// server whose database is unreachable answers `/health` with `200` while
/// every sign-in is dead. That was measured on a real stack by task 11.125 and
/// reported as a defect. **It is not a defect in `/health`.** Restarting the
/// container would not make an unreachable database reachable, so a liveness
/// probe answering "alive" is correct. The defect was that readiness had no
/// answer at all, and that nothing said which of the two `/health` was.
///
/// ## Why a separate route rather than changing `/health`
///
/// Three options were on the table (task 11.128): a `503` from `/health`, a
/// richer body on `/health`, or this. This one was chosen because:
///
/// 1. **A `503` from `/health` would be a false alarm to the one consumer that
///    acts on it.** A container orchestrator restarts on a failed liveness
///    probe; restarting cannot reach a database that is down, so the result is
///    a restart loop layered on top of an outage.
/// 2. **`/health`'s `200` is load-bearing.** Fourteen committed instruments
///    under `scripts/` request it over HTTP and read the answer as "the
///    process is up" — every gate harness, the backup-restore drill, the TLS
///    check, the e2e and offline runners. Changing its code would silently
///    redefine what all of them measure, and several would then be waiting for
///    a readiness they never needed.
/// 3. **A status code is what an uptime monitor can act on without parsing a
///    body.** The consumer here is a `curl` in a cron job or a hosted checker,
///    not a program written against this server.
///
/// ## The disclosure decision, and it is a verdict rather than a reading
///
/// `/ready` is **unauthenticated**, and it tells any caller whether this
/// deployment's database is reachable. Security Model §2.2's rule is that an
/// unauthenticated endpoint must not hand a scanner free reconnaissance, and
/// §4.13's is that a refusal must not disclose what exists.
///
/// **Measured on 2026-09-02, on a server started with no database:**
/// `POST /auth/magic-link` answers `404 Route not found`, because
/// `createHandler` does not mount the auth router without a database, while
/// the same request against a healthy server answers `202`. **So one
/// unauthenticated request already distinguishes the two states.** `/ready`
/// therefore discloses nothing a caller cannot obtain without it; it makes an
/// existing disclosure legible to an operator instead of only to somebody
/// probing. That is a measurement, not an argument from principle — and it is
/// the reason this is recorded as settled rather than as a judgement call.
///
/// **What keeps it settled is the vocabulary being closed.** [Subsystem] is an
/// enum, not a string: the body can name `database` and cannot name an
/// exception type, a host, a driver version or a connection string, because
/// there is no code path that could put one there. Adding a subsystem is a
/// deliberate edit to this enum, which is where the next person is required to
/// re-ask the disclosure question rather than inherit this answer.
///
/// Anything richer than one word per subsystem belongs on the diagnostics
/// console, which is loopback-plus-token gated (§4.10) — with the standing
/// caveat that an uptime monitor cannot reach it, which is exactly why the
/// coarse answer lives out here.
library;

/// A named part of the server whose absence means it cannot do its job.
///
/// **Deliberately an enum with a fixed wire name, not a `String`.** See this
/// library's doc comment: the disclosure decision for `/ready` rests on the
/// set of words it can emit being closed and reviewable, and a `Set<String>`
/// probe would let any caller-visible string — an exception type, a hostname —
/// reach an unauthenticated response by accident.
enum Subsystem {
  /// Postgres. Every route except `/health` and `/ready` needs it, so this
  /// being degraded means sign-in, sync and the project directory are all
  /// unavailable — the state task 11.125 measured `/health` reporting `200`
  /// through.
  database('database');

  const Subsystem(this.wireName);

  /// The word that appears in `/ready`'s body. Stable: an uptime check may be
  /// keyed on it.
  final String wireName;
}

/// Returns the subsystems that are currently degraded; empty means ready.
///
/// **Must be cheap and must not touch the network.** `/ready` is
/// unauthenticated, so a probe that issued a database query would turn one
/// unauthenticated request into one database round trip — an amplifier, and on
/// this server a hazard as well: `bin/server.dart` holds a single `Connection`
/// per role, and `package:postgres` refuses a statement issued on a connection
/// while that connection's own `runTx` is open. A probe that queried would
/// report "not ready" every time it raced a real request.
///
/// **What the shipped probe can and cannot see, stated because an unstated
/// meaning is the defect this whole task is about.** `bin/server.dart` reports
/// `database` degraded when no connection was opened at startup, or when
/// either connection's `isOpen` has since gone false — which covers the two
/// states an operator actually hits: started without a reachable database, and
/// a database that went away underneath a running server. It does **not**
/// cover a database that is reachable and answering with errors — a full disk,
/// or a role whose password was changed without restarting the server. That
/// case reports ready and is not detected here; the diagnostics console's
/// queries are what surface it.
typedef ReadinessProbe = Set<Subsystem> Function();
