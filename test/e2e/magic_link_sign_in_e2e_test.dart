@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/sync/server_identity_adopter.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';
import 'support/magic_link_reader.dart';

/// Task 10.17: exercises the actual magic-link sign-in flow
/// (`AuthClient` + `ServerIdentityAdopter`, in the order
/// `CurrentSession.completeSignIn` uses) against a live server, including
/// the identity-adoption path task 10.6 designed and unit-tested but never
/// ran over real HTTP.
///
/// A UI-driven flow needs a simulator, which this suite does not have —
/// per the task's own scope, driving the client's auth layer directly is
/// sufficient here.
void main() {
  group('magic-link sign-in against a live server', skip: e2eSkipReason, () {
    late E2eDevice device;

    setUp(() async {
      device = await E2eDevice.create();
    });


    test(
      'a fresh device adopts the server user_id and creates a Users row',
      () async {
        final email = randomEmail();
        await device.signIn(email, firstName: 'Sam', lastName: 'Ranger');

        final rows = await device.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [device.userId],
        );
        expect(rows, hasLength(1));
        expect(rows.single['email'], normalizeEmail(email));
        expect(rows.single['first_name'], 'Sam');
      },
    );

    test(
      'two devices signing in with the same email converge on one user_id',
      () async {
        final email = randomEmail();
        await device.signIn(email);

        final second = await E2eDevice.create();
        addTearDown(second.close);
        await second.signIn(email);

        expect(second.userId, device.userId);
      },
    );

    test(
      'a second sign-in on the same device is idempotent (no churn)',
      () async {
        final email = randomEmail();
        await device.signIn(email);
        final userIdAfterFirst = device.userId;

        // Redeem a second link for the same device/email — the "re-sign-in"
        // case (e.g. after a session expired locally).
        final auth = AuthClient(
          httpClient: device.httpClient,
          baseUrl: E2eEnv.requireBaseUrl,
        );
        // **The case the freshness check exists for.** This is the second link
        // for the same address, and the file is named after the address and
        // overwritten — so without an issue time to compare, reading it can
        // return the *first* link, which was already redeemed above, and the
        // failure arrives as "already used" three lines later (task 11.37).
        final requestedAt = DateTime.now().toUtc();
        await auth.requestMagicLink(email);
        final token = await waitForMagicLinkToken(email, issuedAfter: requestedAt);
        final redeemed = await auth.redeem(
          token: token,
          deviceId: device.deviceId,
        );
        expect(redeemed.userId, userIdAfterFirst);

        final report = await ServerIdentityAdopter(device.db.raw).adopt(
          serverUserId: redeemed.userId,
          email: redeemed.email,
          firstName: 'Sam',
          lastName: 'Ranger',
          deviceId: device.deviceId,
          now: DateTime.now().toUtc(),
        );
        // Nothing to remap and no second Users row to create — re-running
        // adoption for an identity this device already holds is a no-op,
        // which is exactly what makes it safe to run on every sign-in.
        expect(report.changedAnything, isFalse);

        final rows = await device.db.raw.query(Tables.users);
        expect(
          rows.where((r) => r['email'] == normalizeEmail(email)),
          hasLength(1),
          reason: 'no duplicate Users row from the second sign-in',
        );
      },
    );

    test('an unknown token is refused, not silently accepted', () async {
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );
      await expectLater(
        auth.redeem(
          token: 'not-a-real-token-${randomId()}-${randomId()}-${randomId()}',
          deviceId: device.deviceId,
        ),
        throwsA(isA<RedemptionRejected>()),
      );
    });
  });
}
