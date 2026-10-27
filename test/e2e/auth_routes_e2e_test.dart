@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/sync/sync_transport.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';
import 'support/magic_link_reader.dart';

/// **The three things the app could ask an auth server for that had never been
/// asked of a real one** (task 11.45, closed here by task 11.36).
///
/// Deriving the suite's coverage from `AuthClient` rather than reading a list
/// of it — which is what `suite_coverage_test.dart` now does — turned up that
/// `linkStatus`, `signOut` and `revokeAllSessions` had no end-to-end test at
/// all. Two of the three had an honest excuse: task 11.28 found that sign-out
/// and "sign out everywhere" were never wired to a screen, and a control with
/// no caller has no end-to-end path to drive. `linkStatus` had none: it is on
/// the path every single user takes, and the only failure ever found in it was
/// found **by hand, on real hardware** (task 11.37), which is the definition of
/// a route no test was watching.
///
/// ## Why half of this file points at an address that does not work
///
/// Task 11.37 changed what two of these three routes do, and a test written
/// against the old behaviour would pass while proving nothing:
///
/// - **The poll** used to report `pending` for *any* non-200. A saved address
///   with a trailing slash produced `//auth/link-status/<id>`, the server
///   answered 404, and the app waited forever without ever saying why.
/// - **Sign-out** used to discard the status entirely and report success. A 404
///   from the same mistyped address left the session live on the server while
///   the screen said "Signed out".
///
/// Both now throw [AuthServerError] — *the server answered, and said no* — as
/// distinct from a connection that never completed. A happy-path test against a
/// good address cannot tell the new behaviour from the old, so each of those
/// two routes is exercised twice here: once against the real server, and once
/// against `<base>/` — **the literal shape that cost the two-device walkthrough
/// its first hour on 2026-08-26**, reproduced rather than approximated. The
/// app itself can no longer hold that address (`ServerConfig` normalises on
/// read as well as on write), which is exactly why the wrong address has to be
/// handed to [AuthClient] directly: the fix for the *stored value* is not the
/// same as the fix for *what the client does when the server says 404*, and
/// only the second is what these tests are about.
void main() {
  group('the sign-in poll, against a live server', skip: e2eSkipReason, () {
    late http.Client httpClient;

    setUp(() {
      httpClient = http.Client();
      addTearDown(httpClient.close);
    });

    AuthClient clientAt(String baseUrl) =>
        AuthClient(httpClient: httpClient, baseUrl: baseUrl);

    test(
      'a link reports pending while it waits, and consumed once it is redeemed',
      () async {
        final auth = clientAt(E2eEnv.requireBaseUrl);
        final email = randomEmail();
        final requestedAt = DateTime.now().toUtc();
        final request = await auth.requestMagicLink(email);

        expect(
          await auth.linkStatus(request.requestId),
          LinkStatus.pending,
          reason:
              'nothing has opened the link yet, so the requesting device has '
              'no reason to stop waiting',
        );

        final token = await waitForMagicLinkToken(email, issuedAfter: requestedAt);
        await auth.redeem(token: token, deviceId: 'e2e-device-${randomId()}');

        // The whole point of the poll: this device asked for the link, somebody
        // opened it (here, the same process; in the field, the phone), and the
        // requesting screen can now stop waiting.
        expect(
          await auth.linkStatus(request.requestId),
          LinkStatus.consumed,
          reason:
              'the link was redeemed, so a device still polling must be told '
              'so rather than waiting out the fifteen-minute expiry',
        );
      },
    );

    test('an unknown request id is pending, not an error', () async {
      // Deliberate, and it is a control rather than an oversight: an unknown
      // request id and a real pending one answer identically, so a guessed id
      // cannot be confirmed as real (`auth_routes.dart`). This test exists so
      // that "unknown reads as pending" is a decision somebody has to change on
      // purpose, not something a later refactor can quietly turn into a 404.
      final auth = clientAt(E2eEnv.requireBaseUrl);
      expect(
        await auth.linkStatus('e2e-not-a-real-request-${randomId()}'),
        LinkStatus.pending,
      );
    });

    test(
      'a poll against a wrong address says the server answered, not "still '
      'waiting"',
      () async {
        // The measured failure, in its original shape: a saved address with a
        // trailing slash, which appends to `//auth/link-status/<id>` and gets a
        // 404 from a server that is up and healthy.
        final auth = clientAt('${E2eEnv.requireBaseUrl}/');
        final good = clientAt(E2eEnv.requireBaseUrl);
        final request = await good.requestMagicLink(randomEmail());

        // `expectLater(..., throwsA(...))` rather than a returned value,
        // because the failure this replaces *returned* a value —
        // `LinkStatus.pending` — forever. A test that merely asserted "not
        // consumed" would have passed against the broken build.
        await expectLater(
          auth.linkStatus(request.requestId),
          throwsA(
            isA<AuthServerError>()
                .having((e) => e.isNotFound, 'isNotFound', isTrue)
                .having((e) => e.path, 'path', contains('/auth/link-status/')),
          ),
          reason:
              'before task 11.37 this returned pending and the app polled a '
              'route that does not exist until the user gave up',
        );
      },
    );
  });

  group('signing out, against a live server', skip: e2eSkipReason, () {
    test('the session stops working on its very next request', () async {
      // **The property the whole session design exists for.** Not "the screen
      // said signed out" and not "the token expires eventually" — the next
      // request this device makes is refused.
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );

      // Works before, so the refusal below is the sign-out and not the token
      // having never worked in the first place.
      await device.transport().listMyProjects();

      await auth.signOut(device.sessionToken);

      await expectLater(
        device.transport().listMyProjects(),
        throwsA(
          isA<SyncTransportException>()
              .having((e) => e.isSessionEnded, 'isSessionEnded', isTrue),
        ),
      );
    });

    test('signing out twice is not a failure', () async {
      // The route is deliberately idempotent and `AuthClient` treats the 401
      // from an already-dead session as success — a session that is already
      // gone is the state being asked for. Pinned because the *other* half of
      // task 11.37's change (any other non-200 now throws) is easy to
      // over-apply to this one.
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );
      await auth.signOut(device.sessionToken);
      await auth.signOut(device.sessionToken);
    });

    test('a wrong address reports a failure rather than "Signed out"', () async {
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: '${E2eEnv.requireBaseUrl}/',
      );

      await expectLater(
        auth.signOut(device.sessionToken),
        throwsA(
          isA<AuthServerError>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.path, 'path', '/auth/sign-out'),
        ),
        reason:
            'before task 11.37 this returned normally and the screen said '
            '"Signed out" while the session stayed live on the server',
      );

      // And it really did stay live — which is what made the false success
      // dangerous rather than merely wrong.
      await device.transport().listMyProjects();
    });
  });

  group('signing out everywhere, against a live server', skip: e2eSkipReason, () {
    test(
      'every device this person holds is cut off, including the one asking',
      () async {
        // Two devices, one person: the same address converges on one `user_id`
        // (task 10.6), which is exactly the shape "I think somebody has my
        // token" is about.
        final email = randomEmail();
        final phone = await E2eDevice.create();
        await phone.signIn(email);
        final laptop = await E2eDevice.create();
        await laptop.signIn(email);
        expect(laptop.userId, phone.userId);

        final auth = AuthClient(
          httpClient: laptop.httpClient,
          baseUrl: E2eEnv.requireBaseUrl,
        );
        final revoked = await auth.revokeAllSessions(laptop.sessionToken);
        expect(
          revoked,
          greaterThanOrEqualTo(2),
          reason:
              'both sessions were live, so a count below two means one device '
              'was left signed in by a control whose whole purpose is that '
              'none are',
        );

        // The other device, on its next request — not on a timer.
        await expectLater(
          phone.transport().listMyProjects(),
          throwsA(
            isA<SyncTransportException>()
                .having((e) => e.isSessionEnded, 'isSessionEnded', isTrue),
          ),
        );
        // And the device that asked, which is the half a per-device revocation
        // would have spared and this one deliberately does not.
        await expectLater(
          laptop.transport().listMyProjects(),
          throwsA(
            isA<SyncTransportException>()
                .having((e) => e.isSessionEnded, 'isSessionEnded', isTrue),
          ),
        );
      },
    );

    test('a session that is already gone is a failure, not a silent zero', () async {
      // Unlike [AuthClient.signOut], this one must not report success when
      // nothing was revoked: somebody reaching for "sign out everywhere" is
      // acting on a suspicion, and "done" when nothing happened is the worst
      // available answer.
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );
      await auth.revokeAllSessions(device.sessionToken);

      await expectLater(
        auth.revokeAllSessions(device.sessionToken),
        throwsA(
          isA<AuthServerError>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });

  group('the device list, against a live server', skip: e2eSkipReason, () {
    // Task 11.36's own half: the route task 11.35 built, and the per-device
    // revocation it exists to make usable. Both are new client methods, so
    // both would be red in `suite_coverage_test.dart` without this group —
    // which is the check working rather than a coincidence.

    test('one row per device, most recently used first, one marked "this "'
        'device', () async {
      final email = randomEmail();
      final phone = await E2eDevice.create();
      await phone.signIn(email);
      final laptop = await E2eDevice.create();
      await laptop.signIn(email);

      // The phone does something, then the laptop asks — so the laptop is the
      // most recently seen and the ordering has a right answer rather than an
      // arbitrary one.
      await phone.transport().listMyProjects();
      final auth = AuthClient(
        httpClient: laptop.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );
      final sessions = await auth.listSessions(laptop.sessionToken);

      expect(
        sessions.map((s) => s.deviceId),
        containsAll([phone.deviceId, laptop.deviceId]),
      );
      expect(
        sessions.where((s) => s.isCurrentDevice).map((s) => s.deviceId),
        [laptop.deviceId],
        reason:
            'exactly one row is the device asking, and it is the one asking — '
            'a screen offering a revoke control marks this one differently, '
            'so getting it wrong signs somebody out of the wrong device',
      );
      expect(
        sessions.first.deviceId,
        laptop.deviceId,
        reason:
            'most recently used first: the laptop made this very request, '
            'after the phone made its own',
      );
      // The response carries nothing that would turn a convenience into a
      // credential leak. Asserted over the wire rather than by reading the
      // route, because that is the only version of the claim an attacker
      // could not read differently.
      final body = await laptop.httpClient.get(
        Uri.parse('${E2eEnv.requireBaseUrl}/auth/sessions'),
        headers: {'authorization': 'Bearer ${laptop.sessionToken}'},
      );
      expect(body.body, isNot(contains(laptop.sessionToken)));
      expect(body.body.toLowerCase(), isNot(contains('token')));
    });

    test(
      'revoking one device takes effect on that device\'s next request, and '
      'leaves the others working',
      () async {
        // **The property the whole session design exists for**, and the one
        // the task names: on the next request, not on a timer.
        final email = randomEmail();
        final lost = await E2eDevice.create();
        await lost.signIn(email);
        final kept = await E2eDevice.create();
        await kept.signIn(email);

        final auth = AuthClient(
          httpClient: kept.httpClient,
          baseUrl: E2eEnv.requireBaseUrl,
        );
        final revoked = await auth.revokeDevice(
          sessionToken: kept.sessionToken,
          deviceId: lost.deviceId,
        );
        expect(revoked, greaterThanOrEqualTo(1));

        await expectLater(
          lost.transport().listMyProjects(),
          throwsA(
            isA<SyncTransportException>()
                .having((e) => e.isSessionEnded, 'isSessionEnded', isTrue),
          ),
        );
        // The whole point of a per-device revocation rather than "sign out
        // everywhere": the laptop in your hand keeps working.
        await kept.transport().listMyProjects();

        final after = await auth.listSessions(kept.sessionToken);
        expect(
          after.map((s) => s.deviceId),
          isNot(contains(lost.deviceId)),
          reason:
              'a revoked device that is still listed offers a control that '
              'does nothing, and reads as a revocation that did not take',
        );
      },
    );

    test('revoking the device you are holding ends this session too', () async {
      // The case the screen has to explain rather than let look like a
      // failure: it succeeds, and the success is that you are signed out here.
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: E2eEnv.requireBaseUrl,
      );

      final revoked = await auth.revokeDevice(
        sessionToken: device.sessionToken,
        deviceId: device.deviceId,
      );
      expect(revoked, greaterThanOrEqualTo(1));

      await expectLater(
        device.transport().listMyProjects(),
        throwsA(
          isA<SyncTransportException>()
              .having((e) => e.isSessionEnded, 'isSessionEnded', isTrue),
        ),
      );
      // And the list itself is gone with it, rather than answering from a
      // credential that no longer exists.
      await expectLater(
        auth.listSessions(device.sessionToken),
        throwsA(
          isA<AuthServerError>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('a wrong address reports a failure rather than an empty list', () async {
      // An unknown list must never read as an empty one. `listSessions`
      // throwing is what lets the screen say "could not ask" instead of "you
      // have no other devices", which is the same distinction task 11.37 drew
      // for sign-out and the poll.
      final device = await E2eDevice.create();
      await device.signIn(randomEmail());
      final auth = AuthClient(
        httpClient: device.httpClient,
        baseUrl: '${E2eEnv.requireBaseUrl}/',
      );
      await expectLater(
        auth.listSessions(device.sessionToken),
        throwsA(
          isA<AuthServerError>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.path, 'path', '/auth/sessions'),
        ),
      );
      await expectLater(
        auth.revokeDevice(
          sessionToken: device.sessionToken,
          deviceId: device.deviceId,
        ),
        throwsA(isA<AuthServerError>()
            .having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      // Nothing was revoked by either failure.
      await device.transport().listMyProjects();
    });
  });
}
