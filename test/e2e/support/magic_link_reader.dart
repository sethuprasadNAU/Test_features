import 'dart:io';

import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'e2e_env.dart';
import 'stack_identity.dart';

/// Reads a real magic-link token off the host filesystem.
///
/// The counterpart to `server/lib/src/auth/email_sender.dart`'s
/// `FileEmailSender`, which the `docker-compose.e2e.yml` override switches on
/// via `TRITRACK_DEV_MAGIC_LINK_DIR`. This is the one piece of the sign-in
/// flow a real device can't do headlessly (there is no inbox to read) — every
/// other step in this suite drives the actual client code
/// (`AuthClient`/`ServerIdentityAdopter`) against the actual server.
///
/// Polls rather than reading once: the request and the server's write to disk
/// are two separate hops (HTTP round trip, then a file write inside the
/// container, then visible on the host through the bind mount), so a fixed
/// delay would either be too short some of the time or needlessly slow all of
/// the time.
///
/// [issuedAfter], when given, makes this wait for a link the server wrote
/// *after* that instant, rather than accepting whatever is on disk.
///
/// **Task 11.37, item 4.** The file is named after the address and
/// overwritten, so a request the per-address rate limit refused — three per
/// address per fifteen minutes, answered with the identical 202 and no email
/// (§4.4/§4.5) — leaves the previous run's link sitting there. This function
/// used to return it immediately and the test then failed at redemption, as
/// "already used". That reads as a spent or broken token; the real cause is
/// one step earlier, and it is exactly how a debugging session on 2026-08-26
/// reached the wrong conclusion. The server now writes an `Issued:` line, so
/// a reader can tell, and this is a reader.
///
/// It stays optional and defaults to off: a caller that has no "before"
/// instant to compare against is better served by the old behaviour than by a
/// timestamp this function invented for itself.
///
/// Compared with no grace period: the server writes the timestamp inside a
/// container sharing this host's kernel clock, so there is no skew to absorb,
/// and a grace window wide enough to matter is also wide enough to accept the
/// previous test's link.
///
/// **That premise is true on Linux and unproven on Docker Desktop** (task
/// 11.130). There the daemon runs inside its own virtual machine with its own
/// clock, which is exactly the shape of difference task 11.69 was bitten by —
/// a bind mount passes ownership through on Linux and is remapped on Docker
/// Desktop, and nothing said so. A container clock a few milliseconds *behind*
/// this process's would make a link that really is new look older than the
/// request that asked for it, and this comparison has no grace to absorb it,
/// so a random minority of sign-ins would fail as "no NEW link appeared".
/// **Nobody has reproduced that and this file does not assert it.** What it
/// does is print both instants in the timeout report, so the next person meets
/// a measurement rather than a guess. Measured on this machine on 2026-09-02:
/// the container read *ahead* of the host, which is the harmless direction.
///
/// ---
///
/// ## Task 11.40, item 3 — this reader used to report a timeout as the rate limit
///
/// Twice on 2026-08-29 a run failed here saying the server *"accepted the
/// request and wrote nothing, which is what the per-address rate limit looks
/// like from the outside"* — and every address involved had been freshly
/// minted seconds earlier, against a limit of three per address per fifteen
/// minutes. **It could not have been the limiter.** What fits is the server's
/// write taking longer than this reader's ten-second ceiling, with the reader
/// offering the stale file it last saw as evidence of a limiter that was never
/// tripped. It sent whoever was debugging to restart the server for no reason.
///
/// **The reader could never have known.** §4.5 makes an email-limited response
/// *byte-identical* to an accepted one on purpose — a 429 keyed on an address
/// would tell the caller that somebody else recently requested links for it.
/// So "the server is being slow" and "the limiter silently refused" are
/// indistinguishable from the outside **by design**, and a reader that claims
/// to tell them apart from the outside is claiming something the security
/// model spent effort making impossible.
///
/// Three changes, in the order they matter:
///
/// 1. **It never asserts the limiter.** It reports what it observed and names
///    both causes.
/// 2. **It asks the one thing that actually knows.** `auth_routes.dart` writes
///    an `auth_audit_log` row with `outcome = 'email_limited'` on exactly this
///    path — the trip is recorded where only an operator can see it, which is
///    the whole design. This reader is running on the operator's machine with
///    `docker` already on `PATH` (`StackIdentity` needs it too), so on timeout
///    it looks, and reports a decisive answer when it gets one. When it cannot
///    look, it says so rather than guessing.
/// 3. **The ceiling is thirty seconds, not ten.** The poll returns the instant
///    the link appears, so a longer ceiling costs a passing run nothing; ten
///    seconds was a number nobody had measured, and the suspected cause is a
///    write that exceeded it.
Future<String> waitForMagicLinkToken(
  String email, {
  Duration timeout = const Duration(seconds: 30),
  DateTime? issuedAfter,
}) async {
  final dir = E2eEnv.requireMagicLinkDir;
  // Mirrors FileEmailSender's own sanitization exactly — this must compute
  // the identical filename or it will simply never find the file.
  final safeName = email.replaceAll(RegExp(r'[^a-zA-Z0-9._@-]'), '_');
  final file = File('$dir/$safeName.link');

  final startedAt = DateTime.now();
  final deadline = startedAt.add(timeout);
  var sawStale = false;
  // The stale file's own `Issued:` line, kept so the timeout report can print
  // it beside the instant this request began (task 11.130). Without both
  // numbers, "it was issued before this request" cannot be told apart from
  // "the two clocks disagree by milliseconds" — and `_isStale` allows no
  // grace at all, on the stated premise that there is no skew to absorb.
  String? staleIssuedLine;
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      // Task 11.69. The link is written mode 600 on purpose — it is a live
      // sign-in credential — so the server container's user has to be one
      // this process can read files from. On a Linux host a bind mount
      // passes ownership straight through, so a stack brought up without
      // TRITRACK_DEV_UID writes `root:root` and this read throws. Docker
      // Desktop remaps it, which is why nobody saw this until CI first ran
      // on Linux. Retrying cannot help, so say what it is and stop.
      final List<String> lines;
      try {
        lines = file.readAsLinesSync();
      } on FileSystemException catch (e) {
        throw StateError(
          'The magic link at ${file.path} exists but this process cannot '
          'read it (${e.osError?.message ?? e.message}). The file is mode '
          '600 deliberately, so what has to match is the OWNER: the server '
          'container wrote it as its own user. Bring the stack up through '
          'scripts/run_e2e_tests.sh, which sources scripts/lib/host_user.sh '
          'and runs the development server as you — or export '
          'TRITRACK_DEV_UID and TRITRACK_DEV_GID before `docker compose up`. '
          'This is not a rate limit and not a missing link.',
        );
      }
      if (issuedAfter != null && _isStale(lines, issuedAfter)) {
        sawStale = true;
        staleIssuedLine = lines.firstWhere(
          (l) => l.startsWith('Issued: '),
          orElse: () => '',
        );
      } else {
        final line = lines.firstWhere(
          (l) => l.startsWith('http'),
          orElse: () => '',
        );
        final token = extractSignInToken(line);
        if (token != null) return token;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  throw StateError(
    await _timeoutReport(
      email: email,
      file: file,
      timeout: timeout,
      startedAt: startedAt,
      sawStale: sawStale,
      issuedAfter: issuedAfter,
      staleIssuedLine: staleIssuedLine,
    ),
  );
}

/// What actually happened, in the order a person debugging needs it.
///
/// **Every sentence here is either something observed or something explicitly
/// flagged as not established.** The message this replaces asserted a cause it
/// had no way to observe, and the cost was a wasted server restart.
Future<String> _timeoutReport({
  required String email,
  required File file,
  required Duration timeout,
  required DateTime startedAt,
  required bool sawStale,
  required DateTime? issuedAfter,
  required String? staleIssuedLine,
}) async {
  final buffer = StringBuffer();

  if (sawStale) {
    buffer
      ..writeln(
        'Waited $timeout for a NEW magic link at ${file.path} and none '
        'appeared. A link for this address is on disk, but it was issued '
        'before this request, so it is a previous one.',
      )
      // **Both instants, because the comparison that produced this verdict
      // allows no grace** (see [_isStale]). The file's timestamp is written
      // inside the server container and the one below it was taken in this
      // process, so a *negative* gap of a few milliseconds is not a stale
      // link at all — it is two clocks disagreeing, which the container
      // sharing the host kernel rules out on Linux and does not rule out on
      // Docker Desktop, where the daemon runs in its own VM. Task 11.130
      // could not reproduce that and does not assert it; it prints the two
      // numbers so the next person does not have to guess which it was.
      ..writeln(
        '  file says   ${staleIssuedLine!.isEmpty ? "(no Issued: line)" : staleIssuedLine}',
      )
      ..writeln(
        '  request began at ${issuedAfter?.toIso8601String()} (this process\'s clock)',
      );
  } else if (file.existsSync()) {
    buffer.writeln(
      'Waited $timeout for a magic link at ${file.path}. The file exists but '
      'no line in it parses as a sign-in URL.',
    );
  } else {
    buffer.writeln(
      'Waited $timeout and no magic link appeared at ${file.path} — the file '
      'was never created. Is the server running with docker-compose.e2e.yml '
      'applied? That override is what sets TRITRACK_DEV_MAGIC_LINK_DIR; '
      'without it the server drops the message silently and correctly.',
    );
  }

  final verdict = await _askTheAuditLog(email: email, since: startedAt);
  buffer
    ..writeln()
    ..writeln(verdict);
  return buffer.toString().trimRight();
}

/// Asks the server's own audit log why this address got nothing.
///
/// `auth_routes.dart` writes an `auth_audit_log` row for **every** magic-link
/// request: `rate_limit_tripped` with `outcome = 'email_limited'` when the
/// per-address limit refused it, `rate_limit_tripped` with `'source_limited'`
/// when the per-source one did, and `link_requested` when it was accepted and
/// a link really was issued. That is the only place the three are
/// distinguishable, and putting them there rather than in the response is
/// deliberate (§4.4/§4.5).
///
/// Returns prose for the failure message, never a thrown error: this runs
/// while a test is *already* failing, and a reader that dies trying to explain
/// a failure has replaced a bad diagnosis with none at all.
Future<String> _askTheAuditLog({
  required String email,
  required DateTime since,
}) async {
  final user = Platform.environment['POSTGRES_USER'];
  final database = Platform.environment['POSTGRES_DB'];
  if (user == null || database == null) {
    return _cannotTell(
      'POSTGRES_USER/POSTGRES_DB are not in this process\'s environment, so '
      'the audit log could not be queried. `scripts/run_e2e_tests.sh` exports '
      'them from .env; a hand-assembled run does not.',
    );
  }

  final String container;
  try {
    final found = await Process.run('docker', [
      'ps',
      '--filter',
      'label=com.docker.compose.project=${StackIdentity.expectedProject}',
      '--filter',
      'label=com.docker.compose.service=postgres',
      '--format',
      '{{.Names}}',
    ]);
    final names = (found.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (found.exitCode != 0 || names.length != 1) {
      return _cannotTell(
        'could not find exactly one Postgres container for compose project '
        '"${StackIdentity.expectedProject}" (found ${names.length}).',
      );
    }
    container = names.single;
  } on ProcessException catch (error) {
    return _cannotTell('`docker ps` could not be run ($error).');
  }

  // `normalizeEmail` itself, not a second copy of what it does — the server
  // stores the normalized address and a hand-rolled `toLowerCase()` here would
  // be one edit away from looking up an address that was never recorded.
  final normalized = normalizeEmail(email);

  // **No caller-supplied value reaches this SQL, and no psql variable either.**
  // The first attempt passed the address with `-v addr=...` and `:'addr'`, and
  // psql's `-c` does not perform variable interpolation at all — measured
  // against the live stack on 2026-08-29, where it produced `syntax error at
  // or near ":"`. That is the whole reason this function runs its own probe
  // before being believed: it would have shipped as a helper that answers
  // "COULD NOT ESTABLISH WHY" every single time, which looks exactly like the
  // honest uncertainty it is supposed to express only when it is true.
  //
  // So the window is an integer this function computed, the address is not in
  // the query at all, and the matching happens in Dart below.
  final windowSeconds = DateTime.now().difference(since).inSeconds + 5;
  final ProcessResult query;
  try {
    query = await Process.run('docker', [
      'exec',
      container,
      'psql',
      '-U',
      user,
      '-d',
      database,
      '-At',
      '-F',
      '\u0001',
      '-v',
      'ON_ERROR_STOP=1',
      '-c',
      'SELECT email, event, coalesce(outcome, \'none\') '
          'FROM auth_audit_log '
          "WHERE occurred_at >= now() - interval '$windowSeconds seconds' "
          'ORDER BY occurred_at',
    ]);
  } on ProcessException catch (error) {
    return _cannotTell('`docker exec ... psql` could not be run ($error).');
  }
  if (query.exitCode != 0) {
    return _cannotTell('the audit-log query failed: ${query.stderr}');
  }

  // `email\u0001event\u0001outcome` per line, reduced to `event / outcome` for
  // the rows belonging to this address. The separator is a control character
  // rather than a comma because an email address may contain one.
  final rows = (query.stdout as String)
      .split('\n')
      .map((l) => l.split('\u0001'))
      .where((f) => f.length == 3 && f[0].trim() == normalized)
      .map((f) => '${f[1].trim()} / ${f[2].trim()}')
      .toList();

  if (rows.any((r) => r.endsWith('email_limited'))) {
    return 'THE AUDIT LOG SAYS THE PER-ADDRESS LIMIT REFUSED THIS. '
        'auth_audit_log holds a rate_limit_tripped / email_limited row for '
        '$normalized since this request began. That is three requests per '
        'address per fifteen minutes (§4.4), answered with the same 202 as a '
        'success and no email — so nothing on the wire could have told you. '
        'Use a different address. Restarting the server also clears the '
        'in-process counters, but reach for the address first.';
  }
  if (rows.any((r) => r.endsWith('source_limited'))) {
    return 'THE AUDIT LOG SAYS THE PER-SOURCE LIMIT REFUSED THIS '
        '(rate_limit_tripped / source_limited). That should not happen under '
        'docker-compose.e2e.yml, which sets '
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1 precisely because Docker '
        'collapses every client into one address — so the override is not '
        'being applied to the stack this suite is talking to.';
  }
  if (rows.any((r) => r == 'link_requested / internal_error')) {
    return 'THE AUDIT LOG SAYS THE SERVER ACCEPTED THIS AND THEN FAILED TO '
        'SEND IT (link_requested / internal_error). **No link was issued**, '
        'so there is nothing on disk to wait for and no limiter is involved. '
        'auth_routes.dart swallows the delivery failure on purpose — §4.5 '
        'requires the same 202 whether or not delivery worked — and records '
        'the failure here instead. The reason is in the server container\'s '
        'own stderr, which is where FileEmailSender prints it: '
        '`docker compose -p ${StackIdentity.expectedProject} logs server`. '
        'The commonest cause is the bind-mount directory being owned by '
        'somebody the server container is not (scripts/lib/host_user.sh).';
  }
  if (rows.any((r) => r.startsWith('link_requested'))) {
    return 'THE AUDIT LOG SAYS THE SERVER ACCEPTED THIS AND ISSUED A LINK '
        '(link_requested), and no limiter refused it. So the link exists and '
        'this reader did not see it within the timeout stated above: either the write '
        'into the container took longer than that, or the bind mount is not '
        'delivering it to the host. Check that .e2e_magic_links/ is the '
        'directory docker-compose.e2e.yml mounts, and that it is not '
        'root-owned. **This is the shape that was misreported as the rate '
        'limit twice on 2026-08-29.**';
  }
  if (rows.isEmpty) {
    return 'THE AUDIT LOG HOLDS NOTHING FOR THIS ADDRESS since the request '
        'began, so as far as the server is concerned the request never '
        'arrived. Check that the suite is pointed at the stack you think it '
        'is (TRITRACK_E2E_BASE_URL) and that the sign-in call ahead of this '
        'one actually returned 202.';
  }
  return 'The audit log holds rows for this address that none of the known '
      'cases matches: ${rows.join(", ")}. Read auth_routes.dart rather than '
      'trusting this message — it has just told you it does not recognise '
      'what it found.';
}

String _cannotTell(String why) =>
    'COULD NOT ESTABLISH WHY — $why\n'
    'So the two candidates below are both still open, and this reader is not '
    'able to choose between them:\n'
    '  (a) the server accepted the request and its write took longer than the '
    'timeout, or never reached the host through the bind mount;\n'
    '  (b) the per-address rate limit refused it — three per address per '
    'fifteen minutes, answered with the identical 202 and no email (§4.4, '
    '§4.5), so it is invisible from the outside on purpose.\n'
    'To settle it, read the server\'s audit log: a rate_limit_tripped row '
    'with outcome = \'email_limited\' for this address means (b), and its '
    'absence means (a). **Do not restart the server on the strength of this '
    'message** — an earlier version of it asserted (b) and sent two debugging '
    'sessions down that path with freshly-minted addresses that could not '
    'possibly have been limited.';

/// Whether the file on disk predates [issuedAfter].
///
/// A file with no `Issued:` line is **not** treated as stale: that is what a
/// server built before task 11.37 writes, and refusing it would turn a
/// version skew into a confusing rate-limit message. The freshness check is
/// an improvement on a guess, not a precondition.
bool _isStale(List<String> lines, DateTime issuedAfter) {
  const prefix = 'Issued: ';
  final line = lines.firstWhere((l) => l.startsWith(prefix), orElse: () => '');
  if (line.isEmpty) return false;
  final issued = DateTime.tryParse(line.substring(prefix.length).trim());
  if (issued == null) return false;
  return issued.toUtc().isBefore(issuedAfter.toUtc());
}
