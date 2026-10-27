import 'dart:io' show HandshakeException, OSError;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/errors/transport_failure.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';

import '../../support/fake_shared_preferences.dart';

/// **Task 11.113 — the sync bar said "Offline" about a certificate this device
/// had refused.**
///
/// Michael pointed the app at a server presenting a self-signed certificate.
/// Safari on the same phone said *"this connection is not private — this
/// website may be impersonating…"*, so the server was reachable and the
/// certificate was genuinely rejected. Tapping **Sync now** produced
/// **"Offline"** — while the app's own Server Connection screen, taught over
/// three consecutive tasks, named the certificate correctly at that same
/// moment on that same device.
///
/// The fourth instance of one class in a week, and the class is that a cause
/// was decided in more than one place. So the tests below are in two halves:
/// the sync surface has to name it (which is the reported defect), **and the
/// two surfaces have to be provably unable to disagree** (which is the class).
void main() {
  setUp(installFakeSharedPreferences);

  /// A self-signed rejection as `dart:io` reports it — Android, Windows,
  /// Linux. iOS and macOS produce `NSErrorClientException` instead and cannot
  /// be constructed off a Darwin host; see
  /// `server_config_screen_macos_test.dart` and the Apple code-only group in
  /// `server_config_screen_test.dart`.
  const selfSigned = HandshakeException(
    'Handshake error in client',
    OSError('CERTIFICATE_VERIFY_FAILED: self signed certificate'),
  );

  HttpSyncTransport transportThatThrows(Object error) => HttpSyncTransport(
    httpClient: MockClient((_) async => throw error),
    baseUrl: 'https://test.local',
    sessionToken: 'token',
  );

  Future<SyncTransportException> refusalFrom(Object error) async {
    try {
      await transportThatThrows(error).listMyProjects();
    } on SyncTransportException catch (e) {
      return e;
    }
    fail('the transport swallowed the failure instead of refusing');
  }

  group('the sync transport stops flattening TLS into "no network"', () {
    test('a rejected certificate is not reported as unreachable', () async {
      // **The measured defect.** `HttpSyncTransport`'s catch threw a bare
      // `unreachable` for every transport exception, so `classifySyncFailure`
      // never saw a certificate and could not have been taught about one.
      final refusal = await refusalFrom(selfSigned);

      expect(refusal.reason, SyncTransportException.certificateRejected);
      expect(refusal.reason, isNot(SyncTransportException.unreachable));
    });

    test('and it carries the cause rather than just the fact', () async {
      final refusal = await refusalFrom(selfSigned);

      expect(refusal.transportFailure, isNotNull);
      expect(
        refusal.transportFailure!.cause,
        TransportFaultCause.certificateUntrusted,
      );
    });

    test('a genuinely unreachable server is still unreachable', () async {
      // The other half, and it matters as much: if everything became a
      // certificate problem the distinction would be exactly as useless
      // pointed the other way. A dead zone is the normal field condition.
      final refusal = await refusalFrom(
        http.ClientException('Connection closed before full header'),
      );

      expect(refusal.reason, SyncTransportException.unreachable);
      expect(refusal.transportFailure, isNull);
    });
  });

  group('the sync-status classification', () {
    SyncTransportException certificateRefusal() => SyncTransportException(
      SyncTransportException.certificateRejected,
      transportFailure: classifyTransportFailure(selfSigned),
    );

    test('a rejected certificate is never classified as unreachable', () {
      final cause = classifySyncFailure(certificateRefusal(), departed: false);

      expect(cause, SyncFailureCause.certificateRejected);
      expect(cause, isNot(SyncFailureCause.unreachable));
    });

    test('and it outranks the remedy check, so it is not "Update needed"', () {
      // This refusal carries a `userMessage`, and `refusedWithRemedy` is
      // checked on exactly that. Classified one line later, every surface
      // would head it "Update needed" — the wrong cause again, one enum
      // member on. The identical trap task 11.104 documented, which is why
      // the second cause to fall into it would have proved nobody had fixed
      // the class.
      final status = SyncStatus(
        schedule: const SyncSchedule(),
        lastFailure: classifySyncFailure(certificateRefusal(), departed: false),
      );

      expect(status.health, SyncHealth.certificateRejected);
      expect(status.health, isNot(SyncHealth.versionRefused));
      expect(status.health, isNot(SyncHealth.offline));
    });

    test('one failed round is enough — it does not wait to look broken', () {
      // Unlike `unreachable`, this is deterministic: the second attempt fails
      // identically, so gating on three consecutive failures would only mean
      // telling somebody they were offline twice first.
      for (final failures in [1, 2, 5]) {
        final status = SyncStatus(
          schedule: SyncSchedule(consecutiveFailures: failures),
          lastFailure: SyncFailureCause.certificateRejected,
        );
        expect(status.health, SyncHealth.certificateRejected);
        expect(status.health, isNot(SyncHealth.broken));
      }
    });

    test('the words for it deny the network and say who can fix it', () {
      final message = certificateRefusal().userMessage!;

      expect(message, contains('does not trust its security certificate'));
      expect(message, contains('self-signed'));
      expect(message, contains('has been changed or lost'));
    });

    test('the retry schedule is not stopped by it', () {
      // A certificate is replaced on the server with nothing changing here, so
      // stopping the schedule would mean the app never noticed the day it was
      // fixed. Backing off is right; giving up is not.
      expect(certificateRefusal().isTerminal, isFalse);
    });
  });

  group('the sync status surface', () {
    // **Read off `SyncStatusPresentation` rather than off a pumped widget**
    // (task 11.189). This used to pump `SyncStatusBanner`, the strip above
    // every tab; the strip is gone, the sentence and the severity it
    // asserted moved into a class that owns nothing but them, and the icon
    // that replaced it reads that class. What is being checked is unchanged.
    test('names the certificate instead of saying Offline', () {
      final presentation = SyncStatusPresentation.of(
        SyncStatus(
          schedule: const SyncSchedule(consecutiveFailures: 1),
          lastFailure: SyncFailureCause.certificateRejected,
        ),
      );

      // Stated as the thing that must never come back, not as the thing that
      // should be there.
      expect(presentation.message, isNot(contains('Offline')));
      expect(presentation.icon, isNot(Icons.cloud_off));

      expect(presentation.message, contains('Not a network problem'));
      expect(presentation.message, contains('security certificate'));
      // One occurrence is enough for a certificate, so this is a fault on the
      // first failure rather than after three — the icon must not spend two
      // rounds looking calm first.
      expect(presentation.severity, SyncSeverity.fault);
    });
  });

  group('the two surfaces cannot disagree', () {
    test('both name the same cause for the same exception', () {
      // **This is the class, not the instance.** Before this task the server
      // screen classified `HandshakeException` itself and the sync engine
      // could not reach that classification at all, so the two could — and
      // did — describe one rejected certificate two different ways at once.
      final failure = classifyTransportFailure(selfSigned)!;

      final onServerScreen = transportFailureMessage(failure);
      final onSyncSurface = SyncTransportException(
        SyncTransportException.certificateRejected,
        transportFailure: failure,
      ).userMessage!;

      expect(onServerScreen, contains(failure.explanation));
      expect(onSyncSurface, contains(failure.explanation));
    });

    test('only the reassurance clause differs, and deliberately so', () {
      // The cause is shared; what a failure meant for the person's data is
      // each surface's own to say. On the sign-in form nothing was changed;
      // on the sync surface the worry is their records.
      final failure = classifyTransportFailure(selfSigned)!;

      expect(
        transportFailureMessage(failure),
        endsWith('Nothing was changed.'),
      );
      expect(
        SyncTransportException(
          SyncTransportException.certificateRejected,
          transportFailure: failure,
        ).userMessage,
        endsWith('Nothing on this device has been changed or lost.'),
      );
    });

    test('a non-certificate transport failure is not dressed up as one', () {
      // The classifier is the only place this judgment is made, so this is the
      // only place it has to be checked — which is the point of merging them.
      final failure = classifyTransportFailure(
        http.ClientException('Connection refused'),
      )!;

      expect(failure.cause, TransportFaultCause.unreachable);
      expect(failure.isCertificate, isFalse);
      expect(transportFailureMessage(failure), contains('Could not reach'));
    });

    test('something that is not a transport failure at all is not claimed', () {
      // A bug in this app must not be reported as a fact about the network —
      // the wrong-cause defect pointed inward.
      expect(classifyTransportFailure(StateError('a bug')), isNull);
      expect(classifyTransportFailure(FormatException('bad json')), isNull);
    });
  });
}

/// A controller that just holds a status, so the banner can be pumped against
/// a state without standing up a database, a project link and a server.
