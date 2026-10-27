@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/data/auth/auth_client.dart';

import 'support/e2e_env.dart';
import 'support/magic_link_reader.dart';

/// Task 11.40, item 3 — **the instrument checking itself.**
///
/// `waitForMagicLinkToken` used to report a timeout as the per-address rate
/// limit. Twice on 2026-08-29 a run failed saying the server had *"accepted
/// the request and wrote nothing, which is what the per-address rate limit
/// looks like from the outside"* — with freshly-minted addresses that could
/// not possibly have been limited. It sent whoever was debugging to restart
/// the server for no reason.
///
/// **Why the old reader could not have been right.** §4.5 makes an
/// email-limited response byte-identical to an accepted one on purpose. So
/// from the outside the two are indistinguishable *by design*, and the fix was
/// not a better guess — it was to ask the one thing that knows, the server's
/// own `auth_audit_log`.
///
/// **This file exists because that fix is only worth what it has been seen to
/// do.** The project's own rule, from `SECURITY_SCOPE_AND_EXIT.md`: *a check
/// that is not committed is a check the next round will not run.* The first
/// version of the audit-log query was written, looked correct, and failed
/// against a live server — psql's `-c` performs no variable interpolation, so
/// `:'addr'` was a syntax error and the reader would have answered "could not
/// establish why" every single time, which is indistinguishable from honest
/// uncertainty. Only running it caught that. So it runs here, every time.
///
/// The two tests are the two answers a person actually needs told apart.
void main() {
  group('the magic-link reader can say WHY no link arrived', () {
    test('a limiter that really refused is named as one', () async {
      final auth = AuthClient(
        httpClient: http.Client(),
        baseUrl: E2eEnv.requireBaseUrl,
      );
      // Freshly minted, so the three below are this address's entire history
      // and the fourth is certain to be the one that trips §4.4's limit.
      final email =
          'limit.probe.${DateTime.now().microsecondsSinceEpoch}@example.test';
      for (var i = 0; i < 3; i++) {
        await auth.requestMagicLink(email);
      }

      // The third link has to be on disk and *older* than the fourth request,
      // or `issuedAfter` cannot tell them apart. Reading it back is also what
      // proves the first three were genuinely accepted, rather than assuming
      // it from a 202 that a limited request would also have returned.
      await waitForMagicLinkToken(email);

      final fourthAt = DateTime.now().add(const Duration(milliseconds: 1));
      await auth.requestMagicLink(email);

      await expectLater(
        waitForMagicLinkToken(
          email,
          timeout: const Duration(seconds: 6),
          issuedAfter: fourthAt,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('PER-ADDRESS LIMIT REFUSED'),
              contains('email_limited'),
            ),
          ),
        ),
        reason:
            'Four requests for one address in well under fifteen minutes: the '
            'fourth must be refused by §4.4, and the reader must say so on the '
            "strength of the server's audit log rather than by inference. If "
            'this fails with "COULD NOT ESTABLISH WHY", the audit-log query '
            'itself is broken — read the message, it says which step failed.',
      );
    });

    test('a link that was never requested is not blamed on a limiter', () async {
      final email =
          'never.asked.${DateTime.now().microsecondsSinceEpoch}@example.test';

      await expectLater(
        waitForMagicLinkToken(email, timeout: const Duration(seconds: 2)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('AUDIT LOG HOLDS NOTHING'),
              isNot(contains('LIMIT REFUSED')),
            ),
          ),
        ),
        reason:
            'Nothing ever asked for a link for this address, so the audit log '
            'holds no row for it and the reader must say exactly that. **The '
            'defect this whole file exists for is the reader asserting a rate '
            'limit in this situation** — an address with no history at all.',
      );
    });
  }, skip: e2eSkipReason);
}
