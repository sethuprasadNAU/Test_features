import 'package:test/test.dart';

import 'database_test_config.dart';

/// The one test in this suite that must never skip.
///
/// Every other Postgres-backed group skips cleanly when no database is
/// configured (`database_test_config.dart`), which is correct for a
/// developer running unit tests without Docker up. But `dart test`'s own
/// exit code does not distinguish "0 tests skipped" from "150 tests
/// skipped" — a no-database run reports the same success as a full run,
/// even though it covers none of C-1, C-2, or C-5 (task 10.31, closing a
/// finding from the second failed Gate C run).
///
/// This test fails — not skips — whenever [testDatabaseConfig] is null, so
/// that a no-database run fails loudly instead of quietly passing. Run
/// `scripts/run_server_tests_docker.sh`, or set POSTGRES_HOST/POSTGRES_PORT/
/// POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD yourself, before trusting a
/// green `dart test` result.
///
/// Unlike the client's `test/e2e/e2e_coverage_guard_test.dart` (task 10.41,
/// H-1), this guard is deliberately **not** given a `dart_test.yaml` tag
/// exclusion. A no-database `dart test` failing here is the intended
/// default — the server has no offline mode to fall back to the way the
/// client does — so there is nothing to exclude it for.
void main() {
  test('the server suite must not pass with no database configured', () {
    if (testDatabaseConfig == null) {
      fail(
        'No Postgres is configured (POSTGRES_HOST/POSTGRES_PORT/'
        'POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD). Every '
        'Postgres-backed group in this suite is skipping right now, '
        'including the C-1, C-2, and C-5 security-gate coverage in '
        'test/authz/, test/integration/, and test/security/. That is not '
        'a passing run. Run scripts/run_server_tests_docker.sh, or set '
        'POSTGRES_* yourself and re-run `dart test`.',
      );
    }
  });
}
