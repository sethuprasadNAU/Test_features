@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/e2e_env.dart';
import 'support/stack_identity.dart';

/// The one test in this suite that must never skip.
///
/// **What this file no longer does — task 11.45.** It used to also assert that
/// `test/e2e/` held exactly nine `*_e2e_test.dart` files. Counting files says
/// nothing about what they cover: the suite could hold its count while losing
/// the only test that ever signed two different people in, which is what task
/// 11.41 had just added. That check is replaced by `suite_coverage_test.dart`,
/// which derives the client's whole server surface from `SyncTransport` and
/// `AuthClient` and requires each route to be exercised, and requires some
/// test to sign two different people in. It is deliberately **not** tagged
/// `e2e`, because it reads source and needs no server — so the suite's
/// coverage is checked on every plain `flutter test` rather than only on the
/// runs where a stack happens to be up.
///
/// Every other group in `test/e2e/` skips cleanly when `TRITRACK_E2E_BASE_URL`
/// / `TRITRACK_E2E_MAGIC_LINK_DIR` aren't set (`e2e_env.dart`), which is
/// correct for a plain `flutter test` run with no server up. But
/// `flutter test test/e2e --tags e2e --run-skipped` run unconfigured prints
/// "All tests skipped" and exits 0 — the exact shape task 10.31 closed for
/// the server suite (`database_coverage_guard_test.dart`), reopened here
/// because that guard was written for `dart test` only and never mirrored
/// onto the one suite that exercises the wire protocol (task 10.39, closing
/// a finding from the second failed Gate C run).
///
/// This test fails — not skips — whenever [E2eEnv.isConfigured] is false, so
/// that an unconfigured `--run-skipped` run fails loudly instead of quietly
/// reporting success. `dart_test.yaml` (task 10.41, H-1) skips every
/// `e2e`-tagged test by default so a bare `flutter test` stays green; that
/// same `skip:` config is exactly why `--run-skipped` is required to force
/// this suite to actually execute at all. See the README's "End-to-end
/// integration suite" section for how to bring up a server and set both
/// variables.
void main() {
  test('the e2e suite must not pass with no server configured', () {
    if (!E2eEnv.isConfigured) {
      fail(
        'No live server is configured (TRITRACK_E2E_BASE_URL/'
        'TRITRACK_E2E_MAGIC_LINK_DIR). Every group in test/e2e/ is skipping '
        'right now, including the wire-protocol coverage this suite exists '
        'to exercise. That is not a passing run. Bring up '
        'docker-compose.e2e.yml and set both variables — see the README\'s '
        '"End-to-end integration suite" section — before trusting a green '
        '`flutter test test/e2e --tags e2e --run-skipped` result.',
      );
    }
  });

  test(
    'the e2e suite must be talking to the stack it started, not a stray one',
    () async {
      // Finding M-12 (Security Model §16.3): a compose stack that outlives
      // its own run can squat the port this suite's TRITRACK_E2E_BASE_URL
      // names, and /health cannot be extended to tell the two apart without
      // giving up the "the only unauthenticated route that reveals anything
      // is liveness" invariant (`router.dart`). This asks Docker the same
      // question a human ran `docker ps` to answer when that happened live.
      if (!E2eEnv.isConfigured) return;
      await StackIdentity.assertConnectedToExpectedStack();
    },
  );
}
