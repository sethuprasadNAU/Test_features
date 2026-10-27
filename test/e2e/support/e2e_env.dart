import 'dart:io';

/// Opt-in configuration for the end-to-end integration suite (task 10.17).
///
/// Mirrors the server's `DatabaseConfig.fromEnvironment`/`_skipReason` pattern
/// exactly: presence of the required environment variables is what makes a
/// suite opt-in rather than a live reachability probe, which would need to be
/// async at exactly the point (`group(..., skip: ...)`) where only a
/// synchronous value is accepted. A `flutter test` run with neither variable
/// set — the default, everywhere except a machine deliberately running this
/// suite — sees every e2e group skip cleanly rather than fail.
abstract final class E2eEnv {
  static String? get baseUrl => _read('TRITRACK_E2E_BASE_URL');

  /// Where `FileEmailSender` (via the `docker-compose.e2e.yml` override)
  /// writes magic-link tokens for this suite to read back. See
  /// `magic_link_reader.dart`.
  static String? get magicLinkDir => _read('TRITRACK_E2E_MAGIC_LINK_DIR');

  static bool get isConfigured =>
      baseUrl != null &&
      baseUrl!.isNotEmpty &&
      magicLinkDir != null &&
      magicLinkDir!.isNotEmpty;

  /// [baseUrl], or a failure that says which variable is missing and how to
  /// set it.
  ///
  /// **Exists because `--run-skipped` makes the opt-out unreachable.**
  /// `e2eSkipReason` keeps every group out of an unconfigured run — but
  /// `--run-skipped` is exactly the flag that overrides a skip, and it is also
  /// the flag this suite *requires* (`dart_test.yaml` skips the `e2e` tag by
  /// default). So the ordinary way to run this suite is also the way to run it
  /// with no configuration at all, and when that happened every test died on
  /// `E2eEnv.baseUrl!` with **"Null check operator used on a null value"** —
  /// once per test, naming nothing, burying the one line that said what was
  /// wrong under a screen of identical stack traces.
  ///
  /// Measured, 2026-08-27: seven such crashes above the single useful message
  /// from `e2e_coverage_guard_test.dart`. A check that knows exactly what is
  /// missing and reports a null-pointer instead is the same defect class this
  /// suite exists to catch in the app.
  static String get requireBaseUrl =>
      baseUrl ??
      (throw StateError(
        'TRITRACK_E2E_BASE_URL is not set, so there is no server to talk to. '
        'This suite needs both variables on the command line, not just the '
        'flags:\n\n'
        '  TRITRACK_E2E_BASE_URL=http://localhost:8080 \\\n'
        '  TRITRACK_E2E_MAGIC_LINK_DIR=.e2e_magic_links \\\n'
        '    flutter test test/e2e --tags e2e --run-skipped\n\n'
        "See the README's \"End-to-end integration suite\" section for the "
        'docker compose command that has to run first.',
      ));

  /// [magicLinkDir], or the same failure as [requireBaseUrl].
  static String get requireMagicLinkDir =>
      magicLinkDir ??
      (throw StateError(
        'TRITRACK_E2E_MAGIC_LINK_DIR is not set, so there is nowhere to read '
        'a sign-in token from. See [requireBaseUrl] for the full command and '
        "the README's \"End-to-end integration suite\" section.",
      ));

  static String? _read(String key) {
    final value = Platform.environment[key];
    return (value == null || value.isEmpty) ? null : value;
  }
}

/// Passed to every top-level `group(..., skip: e2eSkipReason)` in this suite.
///
/// Non-null (skips) unless both variables above are set. Set them by running
/// the suite the one supported way — `scripts/run_e2e_tests.sh`, which brings
/// the stack up, exports both, and tears it down again.
///
/// **This doc comment used to spell the invocation out itself, and it had
/// already gone stale**: it omitted `--run-skipped`, so anyone who copied it
/// got "All tests skipped" and exit 0 — twenty-six lines below [requireBaseUrl],
/// which spelled the same command correctly. Two copies in one file, one of
/// them wrong, is task 11.52's finding in miniature. See
/// `CLAUDE_DOCS/SETUP_OWNERSHIP.md`.
String? get e2eSkipReason => E2eEnv.isConfigured
    ? null
    : 'e2e suite is opt-in — set TRITRACK_E2E_BASE_URL and '
          'TRITRACK_E2E_MAGIC_LINK_DIR to run against a live server; see '
          "the README's \"End-to-end integration suite\" section.";
