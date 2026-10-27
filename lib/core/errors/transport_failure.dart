/// **The one place that turns a failed request into a cause** (task 11.113).
///
/// ## The defect this exists to close
///
/// Until this file, the app had **two classifiers for one question — "why did
/// that request fail?" — and only one of them had ever been taught anything.**
///
/// `server_config_screen.dart` learned about TLS over three consecutive tasks:
/// 11.104 gave a refused `http://` address its own cause, 11.108 gave
/// `HandshakeException` one, 11.112 gave `NSErrorClientException` one for iOS
/// and macOS. `classifySyncFailure` learned none of them, because it sits
/// behind `HttpSyncTransport`, whose `catch` collapsed **every** transport
/// exception to `unreachable`. So a server presenting a self-signed
/// certificate — reachable, and genuinely rejected, confirmed by Safari on the
/// same phone saying *"this connection is not private"* — produced **"Offline"**
/// on the sync bar and a correct, specific certificate message on the server
/// screen, at the same moment, on the same device, about the same server.
///
/// **Each of those three fixes was correct and none of them fixed the class**,
/// because the class is that a cause was decided in more than one place. This
/// file is the merge: every surface consumes what this decides, and
/// `test/documentation/one_transport_classifier_test.dart` fails if a second
/// place in `lib/` starts naming transport exception types.
///
/// ## What is deliberately *not* here
///
/// **Anything the server answered.** A `404`, a `429`, a refusal code, a
/// version skew — those are not transport failures, the request completed, and
/// they already have exactly one home each (`AuthServerError`,
/// `SyncTransportException.userMessage`). This file's whole subject is the
/// narrow one: **a request that never produced an HTTP response**, and the
/// three causes that shape has — nothing answered, this device declined the
/// far end's certificate, or this device set a deadline and reached it (task
/// 11.61).
///
/// ## What the caller must add
///
/// [TransportFailure.explanation] carries **no reassurance clause**, on
/// purpose. "Nothing was changed" is true on the sign-in screen; the sync
/// surface says "Nothing on this device has been changed or lost". That is a
/// real difference between surfaces and it is the caller's to add — everything
/// *about the cause* is decided here, so two surfaces cannot disagree about
/// why a request failed while still speaking in their own voice about what it
/// meant for the person's data.
library;

import 'dart:io' show HandshakeException, SocketException;

import 'package:cupertino_http/cupertino_http.dart' show NSErrorClientException;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:objective_c/objective_c.dart'
    show NSError$Methods, NSStringToString;

import '../net/request_deadline.dart';

/// Why a request never produced a response.
///
/// **Certificate rejection is ranked away from [unreachable] deliberately, and
/// the precedent is in this codebase already.** Task 11.104 gave a refused
/// `http://` address its own state rather than folding it into "offline",
/// because *a configuration fault is not a transient one*: offline is fixed by
/// walking uphill, and a refused address never is, so reporting one as the
/// other guarantees the person looks in the wrong place. **A rejected
/// certificate is the same shape** — it will not fix itself with signal, and
/// the remedy lives with whoever runs the server.
enum TransportFaultCause {
  /// **Nothing answered** — no route, no DNS, connection refused, the socket
  /// dropped. The normal field condition, transient, and the one worth a
  /// silent retry rather than somebody's attention.
  unreachable,

  /// The far end's certificate is past its dates (or not yet valid).
  certificateExpired,

  /// Self-signed, or issued by an authority this device does not recognise.
  certificateUntrusted,

  /// Issued for a different address than the one this device is using.
  ///
  /// Only ever produced from a `HandshakeException`'s free text. Apple's trust
  /// evaluation reports one failure for the whole chain and cannot separate
  /// this from [certificateUntrusted]; see [certificateMessageForNsError].
  certificateHostnameMismatch,

  /// The certificate was rejected and **this device cannot say which of the
  /// above it was.** An honest answer, and better than a confident wrong one:
  /// a guess here sends whoever runs the server to fix the wrong thing.
  certificateCauseUnknown,

  /// **This device set a deadline on the request and reached it** (task
  /// 11.61). Either nothing came back at all, or the answer stopped part way
  /// through — see [RequestGaveUp], which says which and names the request.
  ///
  /// **Its own cause rather than [unreachable]**, because the two are not the
  /// same event and the difference is worth keeping where anything looks: a
  /// socket that was refused never opened, while this one opened and then went
  /// quiet, which is what a loaded or wedged server looks like from a phone.
  /// The *sentence* is shared with [unreachable] deliberately — see
  /// [_timedOut].
  timedOut;

  /// Whether this is a rejected certificate rather than a silent network.
  ///
  /// **Listed rather than derived by exclusion.** This used to read
  /// `this != unreachable`, which was true of every value at the time and
  /// silently made [timedOut] a certificate problem the moment it was added —
  /// the fail-open direction, and exactly the sort of thing a value added a
  /// year later inherits without anybody deciding it.
  bool get isCertificate => const {
    TransportFaultCause.certificateExpired,
    TransportFaultCause.certificateUntrusted,
    TransportFaultCause.certificateHostnameMismatch,
    TransportFaultCause.certificateCauseUnknown,
  }.contains(this);
}

/// A classified transport failure: the cause, and the words for it.
class TransportFailure {
  const TransportFailure(this.cause, this.explanation);

  final TransportFaultCause cause;

  /// What to tell a person, **without a reassurance clause** — see the library
  /// comment. Always names something to check or somebody to ask, per the
  /// standing rule from task 11.104 that a diagnosis nobody can act on is not
  /// help.
  final String explanation;

  bool get isCertificate => cause.isCertificate;
}

/// What every certificate-failure message leads with, on every platform.
const String certificateLead =
    'The server was reached, but this device does not trust its security '
    'certificate.';

/// Shown when the request never completed — nothing answered.
///
/// **Task 11.37 narrowed this from "every failure" to "this one."** It used to
/// be what the server screen said whenever anything went wrong, including when
/// the server answered `404` because the saved address had a trailing slash. A
/// message that names the wrong cause is worse than one that names none: it is
/// confidently actionable, and the action is useless.
///
/// **Says "the server address", not "the address above"** (task 11.113). This
/// sentence is no longer owned by one screen — the sync surface can reach it
/// too, and there is no address above anything there.
const String unreachableExplanation =
    'Could not reach the server — nothing answered at that address. Check the '
    'server address, check this device is on the same network, and check the '
    'server is running.';

const TransportFailure _unreachable = TransportFailure(
  TransportFaultCause.unreachable,
  unreachableExplanation,
);

/// A request this device gave up on.
///
/// **Deliberately reuses [unreachableExplanation] rather than getting a
/// sentence of its own**, and the reason is the same one that gave a rejected
/// certificate its own words: *a cause earns separate copy when it has a
/// separate remedy.* A certificate does — nobody fixes one by walking uphill.
/// A request that timed out does not: check the address, check this device is
/// on the same network, check the server is running. Those are the three
/// things to try, they are already written, and a second sentence saying them
/// differently would be a second thing to keep true.
///
/// **The cause is still kept apart from [TransportFaultCause.unreachable]**
/// where it matters — the durable failure record, the retry policy, and
/// [RequestGaveUp]'s own text, which names the request and which half of the
/// exchange had stopped.
const TransportFailure _timedOut = TransportFailure(
  TransportFaultCause.timedOut,
  unreachableExplanation,
);

/// **The classifier. The only one.**
///
/// Returns null when [error] is not a transport failure at all — a bug in this
/// app, a domain exception, anything the server actually answered. The caller
/// then falls back to whatever it knows about what the person was doing, which
/// is knowledge this function does not have and must not invent.
///
/// The order of the type tests is the design:
///
/// 0. [RequestGaveUp] first of all — this app's own deadline (task 11.61),
///    which is not a platform exception and must not be shadowed by one.
/// 1. [HandshakeException] next. It is `dart:io`'s TLS failure and is neither
///    a [SocketException] nor an `http.ClientException`, which is exactly how
///    it reached a catch-all for a week before task 11.108.
/// 2. [NSErrorClientException] **before** `http.ClientException`, because it is
///    a subtype of it (task 11.112). On iOS and macOS every transport failure
///    arrives as this type — DNS failures and refused connections included —
///    so the certificate test is by structured `NSError` code, and anything
///    else falls through to [unreachableExplanation] rather than being
///    reported as a certificate problem it is not.
/// 3. [SocketException] and `http.ClientException` last, together: both mean
///    the request never completed, and that is the one thing the old blanket
///    message was ever right about.
TransportFailure? classifyTransportFailure(Object error) {
  // **First**, and it has to be: on iOS and macOS a deadline reached inside
  // `NSURLSession` arrives as an `NSErrorClientException` like everything else
  // on that platform, so a [RequestGaveUp] raised by this app's own policy must
  // be recognised before any type test that a subclass could satisfy. It is
  // also the only member of this function's subject that this project writes
  // itself (task 11.61).
  if (error is RequestGaveUp) return _timedOut;
  if (error is HandshakeException) return _fromHandshake(error);
  if (error is NSErrorClientException) {
    return _fromNsError(
          domain: error.error.domain.toDartString(),
          code: error.error.code,
        ) ??
        _unreachable;
  }
  if (error is SocketException || error is http.ClientException) {
    return _unreachable;
  }
  return null;
}

// ---------------------------------------------------------------------------
// dart:io — Android, Windows, Linux (task 11.108)
// ---------------------------------------------------------------------------

/// The exact substrings [_fromHandshake] matches against a
/// `HandshakeException`'s free text, for "expired".
///
/// **Pulled out and made visible to the test suite for task 11.112.** A control
/// built on free-text matching works only for as long as the text it matches
/// stays the same — a Dart or BoringSSL update can silently change it, and the
/// branch stops matching with every test still green.
/// `server_config_screen_test.dart` pins these three lists verbatim so that
/// editing any entry — not just the behavior it currently produces — fails a
/// test and has to be a deliberate choice.
@visibleForTesting
const List<String> handshakeExpiredSubstrings = ['expired'];

/// See [handshakeExpiredSubstrings]. For "self-signed or untrusted issuer".
@visibleForTesting
const List<String> handshakeSelfSignedSubstrings = [
  'self signed',
  'self-signed',
  'unable to get local issuer certificate',
  'unable to get issuer certificate',
];

/// See [handshakeExpiredSubstrings]. For "wrong hostname".
@visibleForTesting
const List<String> handshakeHostnameMismatchSubstrings = [
  'hostname',
  'does not match',
];

/// A TLS handshake this device would not complete — an untrusted, expired, or
/// wrongly-issued certificate (task 11.108).
///
/// **Task 10.49 committed a terminating proxy and §4.1 requires `https`, so
/// this is the first thing a tester meets** when a server is freshly stood up,
/// not an edge case.
///
/// `dart:io`'s [HandshakeException] carries no typed field for *which* of
/// self-signed, expired, or wrong-hostname it is — only a free-text
/// OpenSSL/BoringSSL message. Matching known substrings of that text is
/// **best-effort and BoringSSL-version-dependent**, so this only names a
/// specific cause when the text plainly says so, and returns
/// [TransportFaultCause.certificateCauseUnknown] otherwise rather than
/// guessing.
///
/// **These are the platforms this app runs on least** (Android, Windows,
/// Linux) — iOS and macOS never throw [HandshakeException] at all; see
/// [certificateMessageForNsError].
TransportFailure _fromHandshake(HandshakeException error) {
  final text = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  if (handshakeExpiredSubstrings.any(text.contains)) {
    return const TransportFailure(
      TransportFaultCause.certificateExpired,
      '$certificateLead The certificate has expired and has to be replaced '
      'on the server — tell TriTrack support (More → App Info).',
    );
  }
  if (handshakeSelfSignedSubstrings.any(text.contains)) {
    return const TransportFailure(
      TransportFaultCause.certificateUntrusted,
      '$certificateLead It is self-signed, or issued by an authority this '
      'device does not recognize. If this is a server you set up '
      'yourself, it needs a certificate from a trusted authority.',
    );
  }
  if (handshakeHostnameMismatchSubstrings.any(text.contains)) {
    return const TransportFailure(
      TransportFaultCause.certificateHostnameMismatch,
      '$certificateLead It was issued for a different address than the one '
      'this device has saved. Check that the server address in '
      'More → Server Connection matches the certificate exactly.',
    );
  }
  return _certificateCauseUnknown;
}

/// The honest fallback when nothing available — free text or a structured code
/// — says which of self-signed, expired, or wrong-hostname this is.
const TransportFailure _certificateCauseUnknown = TransportFailure(
  TransportFaultCause.certificateCauseUnknown,
  '$certificateLead This device could not tell exactly why: it may be '
  'self-signed, expired, or issued for a different address. Tell TriTrack '
  'support (More → App Info).',
);

// ---------------------------------------------------------------------------
// NSURLSession — iOS and macOS (task 11.112)
// ---------------------------------------------------------------------------

/// `NSURLErrorDomain` codes (from Apple's Foundation headers) that mean this
/// device declined the server's TLS certificate, rather than failing to reach
/// it at all — DNS failures, connection refusals, and timeouts are also
/// `NSErrorClientException`s on this platform, and must not be reported as a
/// certificate problem they are not.
///
/// **Verified against Apple's published constants on 2026-09-01, not copied
/// from `DEVELOPMENT_PLAN.md`'s own note about this exception** — that note
/// numbered three of these six wrong. Numbers this easy to transpose by hand
/// are exactly why they are pinned in one place.
@visibleForTesting
const int nsUrlErrorSecureConnectionFailed = -1200;
@visibleForTesting
const int nsUrlErrorServerCertificateHasBadDate = -1201;
@visibleForTesting
const int nsUrlErrorServerCertificateUntrusted = -1202;
@visibleForTesting
const int nsUrlErrorServerCertificateHasUnknownRoot = -1203;
@visibleForTesting
const int nsUrlErrorServerCertificateNotYetValid = -1204;

/// The `NSURLErrorDomain` codes this device ever reports for a rejected server
/// certificate. An `NSErrorClientException` carrying any other code —
/// including any other domain entirely — is not a certificate problem and
/// falls back to [unreachableExplanation].
const Set<int> _appleServerCertificateErrorCodes = {
  nsUrlErrorSecureConnectionFailed,
  nsUrlErrorServerCertificateHasBadDate,
  nsUrlErrorServerCertificateUntrusted,
  nsUrlErrorServerCertificateHasUnknownRoot,
  nsUrlErrorServerCertificateNotYetValid,
};

/// The code-only half of the Apple classification.
///
/// **Split out for task 11.112's own tripwire and kept split for 11.113's.**
/// Constructing a real `NSError` requires linking Apple's Foundation
/// framework, which this project's CI (`ubuntu-latest`,
/// `.github/workflows/offline-suite.yml`) cannot do — so the classification
/// that matters (which numeric code means what) has to be reachable without
/// one, or nothing here runs on every commit.
///
/// **Self-signed and wrong-hostname are not separable this way, and this says
/// so rather than guessing.** Apple's trust evaluation reports one failure for
/// the whole certificate chain — an untrusted root, an unknown root, and a
/// hostname that does not match all surface as the same `-1202`/`-1203` (or,
/// in some OS versions, the more general `-1200`). The sub-reason lives in an
/// OS-private `NSUnderlyingErrorKey` chain this project chose not to walk — the
/// same judgment 11.108 made about not parsing OpenSSL internals.
///
/// Returns null when this is not a certificate problem at all.
@visibleForTesting
TransportFailure? certificateMessageForNsError({
  required String domain,
  required int code,
}) => _fromNsError(domain: domain, code: code);

TransportFailure? _fromNsError({required String domain, required int code}) {
  if (domain != 'NSURLErrorDomain' ||
      !_appleServerCertificateErrorCodes.contains(code)) {
    return null;
  }
  if (code == nsUrlErrorServerCertificateHasBadDate ||
      code == nsUrlErrorServerCertificateNotYetValid) {
    return const TransportFailure(
      TransportFaultCause.certificateExpired,
      '$certificateLead Its dates are wrong — it has either expired or is '
      'not yet valid. It has to be replaced on the server — tell TriTrack '
      'support (More → App Info).',
    );
  }
  if (code == nsUrlErrorServerCertificateUntrusted ||
      code == nsUrlErrorServerCertificateHasUnknownRoot) {
    return const TransportFailure(
      TransportFaultCause.certificateUntrusted,
      '$certificateLead It is self-signed, from an authority this device '
      'does not recognize, or issued for a different address. If you run '
      'the server, check that its certificate comes from a trusted '
      'authority and matches the address in More → Server Connection '
      'exactly.',
    );
  }
  return _certificateCauseUnknown;
}
