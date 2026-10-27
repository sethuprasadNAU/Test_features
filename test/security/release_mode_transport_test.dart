import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/data/sync/sync_transport.dart';

/// The client half of §4.1 and §4.3 (task 10.14).
///
/// **Why `releaseMode` is a parameter rather than a bare constant read.**
/// A test binary is never a release *or* profile build, so a check that read
/// `kReleaseMode`/`kDebugMode` directly could never be exercised — and §4.1 is
/// explicit that "a control with no failing-path test is decoration." The
/// default is `!kDebugMode` (task 10.57, finding I-8 — it was `kReleaseMode`
/// until then, which left a profile build, neither debug nor release,
/// exempted from the check by accident), so the production call site cannot
/// forget it. `releaseMode: true` below stands for "any non-debug build" —
/// release and profile are indistinguishable to this function by design.
void main() {
  group('release and profile builds refuse cleartext (§4.1)', () {
    test('http:// is rejected', () {
      final error = validateServerUrl(
        'http://192.168.1.42:8080',
        releaseMode: true,
      );
      expect(error, isNotNull);
      expect(error, contains('https://'));
    });

    test('the refusal says why, in terms a field tech can act on', () {
      // Not "invalid URL": the address is perfectly valid, the *transport* is
      // the problem, and a message that says "invalid" invites retyping the
      // same thing.
      final error = validateServerUrl('http://example.edu', releaseMode: true);
      expect(error!.toLowerCase(), contains('network'));
    });

    test('https:// is accepted', () {
      expect(
        validateServerUrl('https://tritrack.example.edu', releaseMode: true),
        isNull,
      );
    });

    test('an empty value is still valid — it clears the configuration', () {
      // The field's way of saying "work offline". Rejecting it in release would
      // trap a user with a server they cannot remove.
      expect(validateServerUrl('', releaseMode: true), isNull);
      expect(validateServerUrl(null, releaseMode: true), isNull);
    });

    test('a loopback http:// address is refused too', () {
      // No carve-out for localhost in a release build: there is no development
      // server on a user's phone, so a loopback URL in a shipped app is either
      // a mistake or an attempt to work around the control.
      expect(
        validateServerUrl('http://localhost:8080', releaseMode: true),
        isNotNull,
      );
      expect(
        validateServerUrl('http://127.0.0.1:8080', releaseMode: true),
        isNotNull,
      );
    });
  });

  group('the default is not readable as kReleaseMode (task 10.57, I-8)', () {
    test('server_config_provider.dart never reads kReleaseMode', () async {
      // A build-mode bug like this one cannot be caught by calling the
      // function under test: `kReleaseMode` and `!kDebugMode` are
      // indistinguishable from inside `flutter test`, since a test binary
      // is neither release nor profile and both constants evaluate to
      // `false` there (see the file doc comment above). A real release vs.
      // profile difference can only be observed by actually building each
      // — expensive, and not what a fast test suite should require to
      // catch a one-word regression. So this pins the fix at the source
      // level instead, the same way `platform_cleartext_test.dart` proves
      // Android's exemption is debug-only by inspecting file placement
      // rather than a merged Gradle build.
      final source = await File(
        'lib/core/providers/server_config_provider.dart',
      ).readAsString();
      // Checks the live code, not the doc comments explaining the fix (which
      // deliberately still name `kReleaseMode` as the thing NOT to do).
      expect(
        source,
        isNot(contains("show kReleaseMode")),
        reason: 'kReleaseMode must not be imported at all',
      );
      expect(
        source,
        isNot(contains('= kReleaseMode')),
        reason:
            'kReleaseMode is false in both debug AND profile builds — '
            'gating a default on it (rather than !kDebugMode) is exactly '
            'how I-8 let a profile build keep the LAN-cleartext exemption '
            'meant only for a developer\'s own machine',
      );
      // **Derived from the source, not counted against a number typed here**
      // (task 11.104). This read `expect(matches.length, 2)`, which is a
      // hand-maintained list wearing a different hat: splitting the rule into
      // `describeServerUrlProblem` turned a passing check red without any
      // control changing, and the only thing that would have made it green
      // again is editing the number — the failure mode that rule exists to
      // prevent. What actually matters is that *every* `releaseMode` parameter
      // in this file defaults to `!kDebugMode`, however many there are.
      final defaults = RegExp(r'bool releaseMode = ([^,)}]+)')
          .allMatches(source)
          .map((m) => m.group(1)!.trim())
          .toList();
      expect(
        defaults,
        isNotEmpty,
        reason:
            'the releaseMode seam has disappeared from '
            'server_config_provider.dart — if the check moved, move this '
            'test with it rather than deleting it',
      );
      expect(
        defaults.toSet(),
        {'!kDebugMode'},
        reason:
            'every releaseMode default must be !kDebugMode. kReleaseMode is '
            'false in both debug AND profile builds — gating on it is exactly '
            'how I-8 let a profile build keep the LAN-cleartext exemption '
            "meant only for a developer's own machine. Found: \$defaults",
      );
    });
  });

  group('debug builds keep the LAN development workflow', () {
    test('http:// to a LAN address is accepted', () {
      // The whole point of the exemption: task 10.2 makes the server URL a
      // field the developer types at runtime, and it is a laptop's current LAN
      // IP over plain HTTP.
      expect(
        validateServerUrl('http://192.168.1.42:8080', releaseMode: false),
        isNull,
      );
    });

    test('a non-http scheme is still rejected in debug', () {
      expect(
        validateServerUrl('ftp://example.com', releaseMode: false),
        isNotNull,
      );
      expect(validateServerUrl('not a url', releaseMode: false), isNotNull);
      expect(
        validateServerUrl('192.168.1.42:8080', releaseMode: false),
        isNotNull,
      );
    });
  });

  group('debug builds still refuse cleartext off the LAN (§4.1, task 10.22)', () {
    // §4.1 permits cleartext only when the build is debug **and** the target
    // is loopback or a private range. Security Gate C (§7.3 B3) found both
    // enforcement points had built only the first half of that sentence —
    // the server, and this. These are the tests for the half that did not
    // exist.

    test('http:// to a public host is rejected even in a debug build', () {
      for (final url in const [
        'http://tracker.example.edu',
        'http://8.8.8.8:8080',
        'http://134.114.1.10',
        'http://172.32.0.1:8080', // just outside RFC 1918's 172.16.0.0/12
      ]) {
        expect(
          validateServerUrl(url, releaseMode: false),
          isNotNull,
          reason: '$url is a public target — no debug exemption applies',
        );
      }
    });

    test('the refusal tells the researcher what to type instead', () {
      // The failure mode a vague message produces here is not "user gives up",
      // it is "user finds a way around it". Naming the LAN-address shape and
      // https:// is what makes the correct action the easy one.
      final error = validateServerUrl(
        'http://tracker.example.edu',
        releaseMode: false,
      )!;
      expect(error, contains('192.168'));
      expect(error, contains('https://'));
    });

    test('every private target the README can produce is still accepted', () {
      for (final url in const [
        'http://192.168.1.42:8080',
        'http://10.0.0.5:8080',
        'http://172.16.3.9:8080',
        'http://172.31.255.254:8080',
        'http://100.64.1.2:8080', // Tailscale, a safer setup than the LAN one
        'http://localhost:8080',
        'http://127.0.0.1:8080',
        'http://my-laptop.local:8080',
        'http://[fd00::1]:8080', // bracketed IPv6 literal, as Uri.host reports it
      ]) {
        expect(
          validateServerUrl(url, releaseMode: false),
          isNull,
          reason: '$url is on a private network and must keep working',
        );
      }
    });

    test('https:// to a public host is unaffected', () {
      // The check is about transport, not about where the server lives. A real
      // deployment is a public address over TLS and must not be caught here.
      expect(
        validateServerUrl('https://tritrack.example.edu', releaseMode: false),
        isNull,
      );
    });

    test('a hostname that merely looks local does not get the exemption', () {
      // `localhost.attacker.com` resolves to whatever its owner wants. A
      // suffix check that matched it would hand the exemption to the one
      // caller most motivated to ask for it.
      expect(
        validateServerUrl('http://localhost.attacker.com', releaseMode: false),
        isNotNull,
      );
    });
  });

  group('a 401 is a session end, distinct from any other refusal (§4.3)', () {
    test('401 is recognised as a session end', () {
      const error = SyncTransportException('server_rejected', statusCode: 401);
      expect(error.isSessionEnded, isTrue);
      expect(error.isTerminal, isTrue);
    });

    test('403 is terminal but NOT a session end', () {
      // The conflation this fixes: both are terminal, so before task 10.14 a
      // revoked session and an authorization refusal produced the same generic
      // "sync isn't working" with no actionable text.
      const error = SyncTransportException('server_rejected', statusCode: 403);
      expect(error.isSessionEnded, isFalse);
      expect(error.isTerminal, isTrue);
    });

    test('409 and an unreachable server are not session ends', () {
      const version = SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
      );
      const unreachable = SyncTransportException('unreachable');
      expect(version.isSessionEnded, isFalse);
      expect(unreachable.isSessionEnded, isFalse);
    });

    test('a 401 carries actionable copy where it previously carried none', () {
      // `unauthorized` is not in `knownSyncRefusals`, so the code collapses to
      // `server_rejected` and `userMessage` used to return null — which the
      // status surface rendered as generic breakage.
      const error = SyncTransportException('server_rejected', statusCode: 401);
      expect(error.userMessage, isNotNull);
      expect(error.userMessage!.toLowerCase(), contains('sign in'));
    });

    test('the 401 message does not say WHY the session ended', () {
      // Expired, revoked, and server-reinstalled are indistinguishable from
      // outside by design (§4.13). Guessing "you were removed" would also make
      // the app deliver a message that is the project owner's to deliver.
      const error = SyncTransportException('server_rejected', statusCode: 401);
      final message = error.userMessage!.toLowerCase();
      expect(message, isNot(contains('revoked')));
      expect(message, isNot(contains('expired')));
      expect(message, isNot(contains('removed')));
    });

    test('the 401 message reassures that nothing local was lost', () {
      // Same reassurance every other terminal refusal carries. Being signed out
      // is the moment a user is most likely to fear their data went with it.
      const error = SyncTransportException('server_rejected', statusCode: 401);
      expect(error.userMessage, contains('Nothing on this device'));
    });
  });
}
