/// Magic-link delivery (task 10.6).
library;

import 'dart:io';

import '../security/security_config.dart';
import 'smtp_email_sender.dart';

/// Sends the sign-in link.
///
/// An interface because real SMTP needs credentials, and secrets management is
/// task 10.14's — this task should not be the reason a password lands in a
/// config file. It also keeps the auth tests free of any network.
abstract interface class EmailSender {
  /// Delivers a sign-in link. Called fire-and-forget by `AuthService` so
  /// response latency cannot vary with delivery, which would turn timing into
  /// the account-enumeration oracle the identical response body closes.
  ///
  /// Implementations must not include any caller-supplied content in the
  /// message beyond the address itself — otherwise this becomes a
  /// message-delivery channel for whoever can hit the endpoint.
  ///
  /// [onOutcome], when given, is called once with whether delivery is known
  /// to have succeeded — **strictly after this method has returned**, since
  /// the whole point of fire-and-forget is that nothing here may be awaited.
  /// It exists so a caller can learn that a *detached* delivery failed
  /// (task 11.293): a synchronous implementation whose failure already
  /// reaches its own caller as a thrown exception (see [FileEmailSender])
  /// has no need of it and may ignore it, and an implementation that never
  /// attempts a real delivery (see [NullEmailSender]) is not obliged to call
  /// it at all.
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  });
}

/// Development sender: writes the link to a file so a developer can use it,
/// without ever putting the token in a log.
///
/// **Why a file rather than `print`.** The security model's never-log list
/// (§4.7) includes magic-link tokens "at any level, in any environment", with
/// no development exemption — because a token in stdout is a token in the CI
/// artifact, the terminal scrollback, and whatever aggregator is tailing the
/// container. Writing to a known path keeps the link usable for local
/// development while the only thing logged is the path.
///
/// `.gitignore` covers the default location (`server/.dev_magic_links/`) only.
/// If you point `TRITRACK_DEV_MAGIC_LINK_DIR` somewhere else, that path is
/// yours to keep out of version control — these files are live credentials.
///
/// This is a development affordance and is not wired up when
/// `TRITRACK_ENV=production` — see `resolveEmailSender`.
class FileEmailSender implements EmailSender {
  FileEmailSender({required this.directory, DateTime Function()? now})
    : _now = now ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final Directory directory;

  /// Injectable so the `Issued:` line below can be asserted exactly rather
  /// than approximately — a test that can only check "some timestamp is
  /// present" would still pass if the value were the expiry, or last year.
  final DateTime Function() _now;

  @override
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) {
    // [onOutcome] is unused here on purpose. Unlike the SMTP sender, this
    // one runs synchronously and rethrows — its failure already reaches
    // `AuthService.requestMagicLink`'s caller as a thrown exception, which
    // `auth_routes.dart` already turns into the initial audit row's
    // `outcome: 'internal_error'`. Calling [onOutcome] as well would double
    // that report rather than fill a gap (task 11.293 is about the
    // *detached* SMTP path, whose failure a thrown exception cannot reach).
    //
    // Task 11.69. Every failure below is invisible from outside this class:
    // `AuthService` calls this fire-and-forget and `auth_routes.dart` swallows
    // whatever it throws, because §4.5 requires `/auth/magic-link` to answer
    // an identical 202 whether or not delivery worked — otherwise the response
    // becomes the account-enumeration oracle that rule exists to close. That
    // is right for the HTTP response and wrong for the operator: on the
    // 2026-08-30 CI run the directory was root-owned, no link was ever
    // written, and neither the response nor the container's log said anything
    // at all. Eleven gate instruments could only report the symptom.
    //
    // So the diagnosis goes to this container's own stderr, where a caller
    // cannot see it. The directory and the error, never the address and never
    // the token (§4.7) — strictly less than the success line below, which
    // already prints the path.
    try {
      _write(email: email, url: url, expiresAt: expiresAt);
    } on FileSystemException catch (e) {
      // ignore: avoid_print
      print(
        '[auth] MAGIC LINK NOT DELIVERED. Could not write into '
        '${directory.path}: ${e.osError?.message ?? e.message}. '
        'This server is running as uid ${_currentUid()}. The sign-in request '
        'still answered 202 — it must (§4.5) — so nothing outside this log '
        'will tell anybody the link never arrived. If this is a container, '
        'the bind-mount source on the host is most likely owned by root '
        'because it did not exist when the stack came up; '
        'scripts/lib/host_user.sh creates it owned by the invoking user.',
      );
      rethrow;
    }
  }

  static String _currentUid() {
    if (Platform.isWindows) return 'n/a';
    try {
      final result = Process.runSync('id', ['-u']);
      return (result.stdout as String).trim();
    } catch (_) {
      return 'unknown';
    }
  }

  void _write({
    required String email,
    required String url,
    required DateTime expiresAt,
  }) {
    directory.createSync(recursive: true);
    // One file per address rather than an append-only log, so the current link
    // is unambiguous and stale tokens don't accumulate on disk.
    final safeName = email.replaceAll(RegExp(r'[^a-zA-Z0-9._@-]'), '_');
    final file = File('${directory.path}/$safeName.link');
    // **`Issued:` is what makes a stale file distinguishable from a fresh one
    // (task 11.37, item 4).** Because the name is the address and the write
    // overwrites, a request that the per-address rate limit silently refused
    // (§4.4 — same 202, no email sent) leaves the *previous* link sitting
    // here looking exactly like a new one. Reading it and getting
    // "that sign-in code did not work" reads as a spent or broken token; the
    // real cause is one step earlier and nothing on the outside said so. It
    // cost a working session on 2026-08-26. The expiry alone cannot settle it
    // — every link expires 15 minutes after issue, so a stale one still has a
    // plausible-looking future expiry for most of its life.
    file.writeAsStringSync(
      'TriTrack sign-in link for $email\n'
      'Issued: ${_now().toIso8601String()}\n'
      'Expires: ${expiresAt.toIso8601String()}\n'
      '$url\n',
    );
    // Owner-only. The default umask would leave a working credential readable
    // by every account on the machine.
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['600', file.path]);
    }
    // ignore: avoid_print
    print('[auth] magic link written to ${file.path}');
  }
}

/// Sender used when nothing is configured: accepts and drops the message.
///
/// Deliberately silent rather than throwing. A sign-in request must behave
/// identically whether or not delivery is possible — if a misconfigured mailer
/// made the endpoint fail for registered addresses only, or made it slower,
/// that difference would be the enumeration oracle §4.5 exists to close.
/// Failing to *deliver* is a visible operational problem; failing to respond
/// uniformly is a security one.
class NullEmailSender implements EmailSender {
  const NullEmailSender();

  @override
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) {
    // Intentionally empty. Never log `url` — it contains a live token.
    // [onOutcome] is never called: there is no relay configured, so there is
    // no delivery attempt to report the outcome of, successful or not.
  }
}

/// Picks a sender from the environment.
///
/// | `TRITRACK_SMTP_HOST` | `TRITRACK_DEV_MAGIC_LINK_DIR` | `TRITRACK_ENV` | Result |
/// | --- | --- | --- | --- |
/// | set | — | any | [SmtpEmailSender] — see `smtp_email_sender.dart` |
/// | set | set | any | **refuses to start** — two senders is a question, not a configuration |
/// | — | set | not production | [FileEmailSender] |
/// | — | set | production | **refuses to start** |
/// | — | — | production | **refuses to start** (task 11.287) |
/// | — | — | not production | [NullEmailSender], with a startup line saying so |
///
/// Refuses the development file sender under `TRITRACK_ENV=production` for the
/// same reason `docker-compose.yml` has no default password: a development
/// convenience that still works in production is how prototypes ship with a
/// hole in them.
///
/// **And refuses production with no sender at all** (task 11.287). Until then
/// the bottom-right cell was the silent sender: a production deployment
/// accepted every sign-in request, answered `202`, and delivered nothing —
/// correctly, because §4.5 requires the identical response — so sign-in was
/// the first thing anybody did and the first thing that failed, and nothing
/// said so. A server that cannot deliver a sign-in link has no users, and it
/// should say that at `docker compose up` rather than be discovered by the
/// first person who waits for a link.
EmailSender resolveEmailSender([Map<String, String>? env]) {
  final environment = env ?? Platform.environment;
  final isProduction = isProductionEnvironment(environment);
  final devDirectory = environment['TRITRACK_DEV_MAGIC_LINK_DIR'];
  final hasDevDirectory = devDirectory != null && devDirectory.isNotEmpty;
  final hasSmtp = SmtpConfig.isConfigured(environment);

  if (hasSmtp && hasDevDirectory) {
    throw StateError(
      'Both TRITRACK_SMTP_HOST and TRITRACK_DEV_MAGIC_LINK_DIR are set. One '
      'sender: unset the directory to send real mail, or unset the relay to '
      'write links to disk for development.',
    );
  }
  if (hasSmtp) {
    return SmtpEmailSender(config: SmtpConfig.fromEnvironment(environment));
  }
  if (hasDevDirectory) {
    if (isProduction) {
      throw StateError(
        'TRITRACK_DEV_MAGIC_LINK_DIR is set but TRITRACK_ENV=production. '
        'Writing sign-in links to disk is a development-only affordance.',
      );
    }
    return FileEmailSender(directory: Directory(devDirectory));
  }
  if (isProduction) {
    throw StateError(
      'TRITRACK_ENV=production and no sign-in email relay is configured. '
      'Nobody could sign in: every request would answer 202 and no link '
      'would arrive. Set TRITRACK_SMTP_HOST, TRITRACK_SMTP_FROM and, if the '
      'relay needs them, TRITRACK_SMTP_USERNAME/TRITRACK_SMTP_PASSWORD — see '
      '.env.example and server/README.md, "Sign-in email".',
    );
  }
  return const NullEmailSender();
}
