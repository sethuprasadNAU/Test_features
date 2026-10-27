// Task 10.50 (F13, `TriTrack_Security_Model.md` §7.6/§8.5/§9.0/§10, closed
// by task 10.48's client-side enforcement, verified here on real hardware).
//
// **This proves App Transport Security, not the app's own scheme check.**
// 10.48 gave `serverHttpClientProvider` a check that refuses a cleartext URL
// to a public host before a client is even constructed. That check is
// correct and stays — but it means going through the provider makes request
// #2 below fail for the wrong reason: rejected before a packet moves, which
// would make this test pass while proving nothing about ATS. This is
// deliberately the one place in the app that calls
// `createPlatformHttpClient()` directly, below that check, exercising
// exactly the client the provider builds and nothing else.
//
// **Runs as the real, sandboxed app bundle.** `flutter test` (plain) uses the
// `flutter_tester` harness, which ships no `Info.plist` of its own and
// cannot exercise `NSAllowsLocalNetworking`/ATS at all — the exact reason
// F13 stayed "not verified empirically" through task 10.48. `integration_test`
// tests run as the genuine compiled app, with its real Info.plist, on a real
// device or simulator:
//
//   flutter test integration_test/ats_transport_security_test.dart -d macos --release
//   flutter test integration_test/ats_transport_security_test.dart -d <ios-simulator-or-device-id>
//
// Living under `integration_test/` rather than `test/` is what keeps this
// out of the default `flutter test` invocation (task 10.41's invariant) —
// Flutter's test runner never discovers this directory on its own, so no
// skip tag is needed to keep the offline-green suite green.
//
// The three requests are load-bearing together, not separately (the plan's
// own words): #2 failing alone proves nothing, because an unreachable host
// and an ATS refusal are indistinguishable from here — #1 is what makes #2
// evidence. #3 proves `NSAllowsLocalNetworking` still works and local
// development on this exact client is not broken by the same policy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';

/// Loopback responder started by `scripts/verify_ats_transport_security.sh`
/// before this test runs — never bound from inside this process, sandboxed
/// or not. A release-mode macOS build's own entitlements
/// (`macos/Runner/Release.entitlements`) grant `network.client` only, not
/// `network.server`; binding a listening socket from inside the sandboxed
/// app under test would need an entitlement change this task does not make
/// (verification, not configuration — see the command's own instruction).
/// The responder is therefore a separate, unsandboxed process the app only
/// ever connects *out* to, which is also what a real LAN server is.
const _localTarget = String.fromEnvironment(
  'ATS_TEST_LOCAL_URL',
  defaultValue: 'http://127.0.0.1:8123/',
);

/// A public host expected to answer both `https://` and `http://` reliably.
/// IANA-reserved for documentation and testing (RFC 2606) — stable by
/// design, not a dependency on an ordinary third-party service staying up.
const _publicHost = 'example.com';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'App Transport Security refuses cleartext to a public host, on the '
    "app's real client, on the real platform (task 10.50, F13)",
    (tester) async {
      if (!(Platform.isIOS || Platform.isMacOS)) {
        fail(
          'This test verifies App Transport Security, which is enforced by '
          'NSURLSession and only applies where the app routes through '
          'CupertinoClient — iOS and macOS. Run it with `-d macos` or an '
          'iOS simulator/device. Failing loudly here (not skipping) is '
          'deliberate: a platform this cannot apply to must never report a '
          'silent pass for it, per the task instructions.',
        );
      }

      // The exact function `serverHttpClientProvider` calls — never a
      // `CupertinoClient` constructed inline here, which would test only
      // the package and not the app's own client-construction path.
      final client = createPlatformHttpClient();
      addTearDown(client.close);

      expect(
        client.runtimeType.toString(),
        'CupertinoClient',
        reason:
            'createPlatformHttpClient() did not return CupertinoClient on '
            '${Platform.operatingSystem} — ATS has no NSURLSession traffic '
            'to govern here, and nothing below this line tests anything.',
      );

      // --- #1: https:// to a public host must succeed -----------------
      //
      // The control. Without it, #2 below is worthless: a host that is
      // merely unreachable (DNS hiccup, no network) and a host ATS refused
      // produce the identical symptom — an exception — from this vantage
      // point. This is the check that tells them apart.
      late http.Response httpsResponse;
      try {
        httpsResponse = await client
            .get(Uri.parse('https://$_publicHost'))
            .timeout(const Duration(seconds: 20));
      } on Object catch (e) {
        fail(
          'Request #1 (https:// to a public host) failed: $e\n'
          'This must succeed for request #2 to mean anything — an '
          'unreachable host and an ATS refusal look identical otherwise. '
          'Check network connectivity before trusting any result below.',
        );
      }
      expect(
        httpsResponse.statusCode,
        inInclusiveRange(200, 399),
        reason: 'https:// control request did not succeed',
      );

      // --- #2: http:// to the SAME host must be refused, by ATS -------
      Object? refusal;
      try {
        await client
            .get(Uri.parse('http://$_publicHost'))
            .timeout(const Duration(seconds: 20));
      } on Object catch (e) {
        refusal = e;
      }
      expect(
        refusal,
        isNotNull,
        reason:
            'a plain http:// request to a public host SUCCEEDED — ATS did '
            'not refuse it. F13 reproduces.',
      );
      // Asserted on the ATS error text itself, not merely that something
      // threw — a timeout, a DNS failure, or an unrelated error must not
      // be mistaken for ATS holding. This is the exact string NSURLSession
      // reports for an App Transport Security refusal.
      expect(
        refusal.toString(),
        contains(
          'App Transport Security policy requires the use of a secure '
          'connection',
        ),
        reason:
            'request #2 was refused, but not by ATS — got: $refusal. This '
            'does not confirm the control this test exists to prove.',
      );

      // --- #3: http:// to loopback/LAN must still succeed -------------
      //
      // NSAllowsLocalNetworking (task 5.1) exists so a LAN dev server still
      // works. If ATS's refusal above also caught this, local development
      // is broken and #2 alone would be the wrong evidence to celebrate.
      late http.Response localResponse;
      try {
        localResponse = await client
            .get(Uri.parse(_localTarget))
            .timeout(const Duration(seconds: 10));
      } on Object catch (e) {
        fail(
          'Request #3 (http:// to $_localTarget) failed: $e\n'
          'Is the local responder running? See '
          'scripts/verify_ats_transport_security.sh — this test does not '
          'start it itself (see the file header on why).',
        );
      }
      expect(
        localResponse.statusCode,
        200,
        reason: 'local http:// request did not succeed — '
            'NSAllowsLocalNetworking may not be working',
      );
    },
  );
}
