/// Configuration for the read-only diagnostics console (task 10.13).
library;

import 'dart:io';

import '../security/placeholder_secrets.dart';
import '../security/security_config.dart';

/// Whether, and how, the diagnostics console is reachable.
///
/// **Off by default in every environment, not just production.** The console
/// has no per-user session — a request that clears the network and token
/// gates below sees everything this build knows about every project — so
/// "off unless explicitly turned on" is the only default that doesn't depend
/// on someone remembering to change a config before a real deployment.
///
/// **Task 10.80 moved four rules out of prose and into [fromEnvironment].**
/// Security Model §4.10 has always said the console is never enabled in
/// production, and §4.6 has always said a secret that is a known placeholder
/// is not a secret; neither was enforced here, so `changeme` started cleanly
/// as this console's entire authentication mechanism and `TRITRACK_ENV=
/// production` did nothing. Those rules now refuse at startup, by name, with
/// a sentence saying what to change — because the operator meets them while
/// setting the console up, and a refusal they cannot read costs them an
/// evening.
class DiagnosticsConfig {
  const DiagnosticsConfig({
    required this.enabled,
    required this.allowRemote,
    required this.token,
  });

  /// The shortest token this console will accept, in characters.
  ///
  /// `Tokens.generate()` produces 43 characters and `openssl rand -hex 32`
  /// produces 64, so the floor rejects nothing an operator following
  /// `server/README.md` would ever produce. It is deliberately a *floor*
  /// rather than a strength grader — §4.6's own reasoning, restated in
  /// `placeholder_secrets.dart`: TriTrack has no business scoring an
  /// operator's passphrase. What it has business refusing is a string short
  /// enough to be guessed by a script, which is the failure the placeholder
  /// list cannot catch on its own because nobody can enumerate every short
  /// thing a person might type.
  static const int minimumTokenLength = 32;

  /// Whether the diagnostics routes exist at all. When false, [createHandler]
  /// (`router.dart`) is never given a diagnostics context and mounts nothing
  /// — the acceptance criterion is that disabling this removes the routes,
  /// not that it hides them behind a 403.
  final bool enabled;

  /// Whether a request from off-loopback is answered at all, rather than
  /// refused before it reaches any route. False (bind-to-localhost, the task's
  /// own words) is the default; true requires an explicit opt-in, same as
  /// [enabled] itself.
  ///
  /// **Coupled to TLS since task 10.80.** Allowing this console off-host over
  /// cleartext publishes the operator token — and with it every project,
  /// identity and device on the server — to anything that can watch the
  /// network, which is the guarantee §4.1 requires everywhere else. See
  /// [fromEnvironment]'s `tlsEnabled` argument.
  final bool allowRemote;

  /// The shared secret a caller must present (`Authorization: Bearer <token>`)
  /// once past the network gate. Non-null whenever [enabled] is true — see
  /// [fromEnvironment]. There is deliberately no session-based login here:
  /// this console reads across every project and every user, and building a
  /// second authorization system for a tool with one intended caller (a
  /// developer with shell access to set the token in the first place) would
  /// be a second thing to get wrong for no real gain over a shared secret
  /// they can rotate by restarting the process.
  ///
  /// **Task 10.80 did not change that, and it is the one property to carry
  /// knowingly rather than discover:** after this task the console still has
  /// no per-user session, so anyone holding this token reads every project on
  /// the server. What changed is only *which configurations can hold it* —
  /// not production, not off-host in cleartext, and not `changeme`.
  final String? token;

  /// Resolves the console's configuration, refusing every arrangement §4.10
  /// and §4.6 forbid.
  ///
  /// [tlsEnabled] is required rather than defaulted because it is a fact about
  /// a subsystem this class does not own: `TransportSecurityConfig` decides
  /// whether this server serves TLS, and a default here would be this file
  /// asserting an answer it cannot see. `bin/server.dart` resolves the
  /// transport first and passes the answer down.
  ///
  /// Throws [StateError] with a message naming the variable to change. Every
  /// refusal below fires only when the console was explicitly asked for; a
  /// server that never set `TRITRACK_DIAGNOSTICS_ENABLED` cannot be stopped
  /// from starting by anything in here.
  static DiagnosticsConfig fromEnvironment(
    Map<String, String>? env, {
    required bool tlsEnabled,
  }) {
    final environment = env ?? Platform.environment;
    final enabled = environment['TRITRACK_DIAGNOSTICS_ENABLED'] == 'true';
    final allowRemote =
        environment['TRITRACK_DIAGNOSTICS_ALLOW_REMOTE'] == 'true';
    final token = environment['TRITRACK_DIAGNOSTICS_TOKEN'];

    if (!enabled) {
      // Setting a token, or even ALLOW_REMOTE, without ENABLED is not an
      // error: staging a token ahead of flipping the feature on is a normal
      // thing to do, and nothing here is reachable until ENABLED is true.
      return DiagnosticsConfig(
        enabled: false,
        allowRemote: allowRemote,
        token: token,
      );
    }

    // §4.10: "Never enabled in a production deployment." Checked before the
    // token rules because it is the refusal that no better token can fix —
    // telling an operator to lengthen their token and then refusing them
    // again for the environment would be two evenings instead of one.
    if (isProductionEnvironment(environment)) {
      throw StateError(
        'TRITRACK_DIAGNOSTICS_ENABLED=true and TRITRACK_ENV=production. The '
        'diagnostics console reads every project, identity, device and '
        'sign-in event on this server through one shared token and no '
        'per-user login, so Security Model §4.10 does not permit it on a '
        'production deployment. To read this server: unset '
        'TRITRACK_DIAGNOSTICS_ENABLED and use psql, or run the console on a '
        'non-production deployment. See server/README.md, "The diagnostics '
        'console".',
      );
    }

    if (token == null || token.isEmpty) {
      // Refusing to start is the same posture `DatabaseConfig` takes on a
      // missing credential: loud and immediate beats a console that is
      // reachable and unauthenticated because nobody set a token yet.
      throw StateError(
        'TRITRACK_DIAGNOSTICS_ENABLED is set but TRITRACK_DIAGNOSTICS_TOKEN '
        'is not. The console has no per-user login, so this token is the '
        'only thing standing between "reachable" and "readable." Generate '
        'one with: openssl rand -hex 32',
      );
    }

    // §4.6, which this variable was exempt from until task 10.80. Names the
    // variable and never the value — a configuration error message must not
    // become a way to read secrets out of a log (§4.7).
    if (isPlaceholderSecret(token)) {
      throw StateError(
        'TRITRACK_DIAGNOSTICS_TOKEN is set to a known placeholder value. It '
        'is the diagnostics console\'s entire authentication mechanism, so a '
        'guessable one is the same as none at all (Security Model §4.6). '
        'Generate a real token with: openssl rand -hex 32',
      );
    }

    if (token.length < minimumTokenLength) {
      throw StateError(
        'TRITRACK_DIAGNOSTICS_TOKEN is ${token.length} characters; the '
        'diagnostics console requires at least $minimumTokenLength. It is '
        'the console\'s entire authentication mechanism and there is no rate '
        'limit in front of it, so a short token is one a script guesses. '
        'Generate one with: openssl rand -hex 32',
      );
    }

    // §4.1's transport guarantee, which `allowRemote` used to sit outside of.
    // Off-host and cleartext means this token — and every coordinate the
    // console renders with it — crosses the network in the clear.
    if (allowRemote && !tlsEnabled) {
      throw StateError(
        'TRITRACK_DIAGNOSTICS_ALLOW_REMOTE=true but this server is not '
        'serving TLS. That would send the diagnostics token, and every '
        'project, identity and location the console renders, in cleartext to '
        'anything that can watch the network (Security Model §4.1). Either '
        'configure TRITRACK_TLS_CERT_PATH and TRITRACK_TLS_KEY_PATH, or '
        'unset TRITRACK_DIAGNOSTICS_ALLOW_REMOTE and reach the console '
        'through an SSH tunnel to this machine\'s loopback interface — see '
        'server/README.md, "The diagnostics console".',
      );
    }

    return DiagnosticsConfig(
      enabled: true,
      allowRemote: allowRemote,
      token: token,
    );
  }
}
