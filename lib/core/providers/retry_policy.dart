/// **The app's retry policy for a failed provider, and why it is this one.**
///
/// Task 11.107.
///
/// ## What it replaces
///
/// Riverpod 3 retries a failed provider automatically. Nothing in this app set
/// `retry:` on its `ProviderScope`, so every provider in it ran Riverpod's
/// `ProviderContainer.defaultRetry`: **ten attempts, exponential backoff from
/// 200 ms to a 6.4-second ceiling — 38.2 seconds, measured on 2026-08-31** (task
/// 11.105; the mechanism is pinned in
/// `test/core/providers/provider_boundary_behaviour_test.dart`). `p.future`
/// stays pending for the whole of that, so a screen awaiting a provider cannot
/// say anything at all until the last attempt has failed.
///
/// **Nothing was broken by it, which is what made it easy to leave.** But a
/// field tech whose sync fails watches a still screen for most of a minute and
/// concludes the app has hung — the same harm as being told the wrong cause,
/// arriving more slowly.
///
/// ## The decision
///
/// **Keep automatic retry; bound it to under two seconds; then hand the person
/// the retry.** [appRetryPolicy] allows the initial attempt plus
/// [kMaxAutomaticRetries] retries, waiting 400 ms and then 1200 ms —
/// [kMaxAutomaticRetryDelay] of waiting in the worst case, on top of however
/// long the attempts themselves take.
///
/// Retry is kept rather than switched off because this app runs on a field
/// connection that drops and comes back, and a momentary blip healing without
/// anybody noticing is worth having. **What gets worse:** an outage lasting
/// between two and thirty-eight seconds used to be ridden out invisibly and now
/// surfaces as a failure the person has to tap past. That is the trade, and it
/// is the right way round — a person who can see what happened after 1.6
/// seconds and press "Try again" is better served than one who is shown nothing
/// for 38 and cannot tell the app from a freeze. **The screen must give them
/// that control**; a bounded retry with no visible failure state would be
/// strictly worse than the 38 seconds.
///
/// Automatic retry is also not this app's network resilience. Sync has its own
/// scheduling — `SyncController.syncIfDue` on every foreground, plus the manual
/// control on the Sync Status screen — and a failed sync is retried by that,
/// not by this.
///
/// ## What is not retried, and what is
///
/// An `Error` is not retried: it is a defect in this app, and running it three
/// times produces the same defect three times. A `ProviderException` is not
/// retried: the provider it wraps has already run its own retries. Both
/// exclusions are Riverpod's and are kept deliberately.
///
/// **A request that already spent a deadline is not retried either — added by
/// task 11.61, and it is what keeps that task from undoing this one.** Once
/// requests are bounded, the timeout multiplies through this policy: a screen
/// awaiting a provider that makes one small request would have waited
/// 30 + 0.4 + 30 + 1.2 + 30 = **91.6 seconds** before being told anything,
/// which is worse than the 38 seconds this file exists to have removed and
/// flatly contradicts its own promise above of "under two seconds".
///
/// **The trade, stated:** a blip lasting less than a request's deadline is
/// already ridden out by the deadline itself, so what is given up is only the
/// case where a server is silent for a full thirty seconds and then well
/// within the next thirty. A person who is shown the failure and a "Try again"
/// control recovers from that in one tap; one watching a still screen for a
/// minute and a half cannot tell the app from a freeze. **This is not sync's
/// resilience either** — sync has its own schedule, and a timed-out round is
/// retried by that.
///
/// **Everything else is retried, including failures that cannot possibly
/// succeed on a second attempt** — a refused `http://` server address
/// (`InvalidServerUrl`), a denied location permission
/// (`LocationPermissionDeniedException`). Those are pointless retries and they
/// are allowed to happen: the cost is now 1.6 seconds, and a hand-written list
/// of "types not worth retrying" is a list that goes stale silently, which this
/// project has been bitten by three times (tasks 11.46, 11.81, 11.98). The
/// better fix for those two specifically is already built and is not a retry
/// policy: the refusal travels as a *value* from a `keepAlive` provider that
/// cannot throw — see `provider_error.dart` and `serverUrlRefusalProvider`.
///
/// ## Where it is applied
///
/// On the `ProviderScope` in `main.dart`, which is every provider in the
/// running app, and on the container the full-app widget tests boot
/// (`test/support/app_boot_helper.dart`) so a test measures what ships.
/// `test/documentation/retry_policy_applied_test.dart` fails if a
/// `ProviderScope` is added without it.
library;

import 'package:flutter_riverpod/misc.dart' show ProviderException;

import '../errors/transport_failure.dart';
import '../net/request_deadline.dart';
import '../../data/sync/sync_transport.dart';

/// Retries after the first attempt. Three attempts in total.
const int kMaxAutomaticRetries = 2;

/// The longest a person waits on retry backoff alone before a failed provider
/// is allowed to say so: 400 ms + 1200 ms.
const Duration kMaxAutomaticRetryDelay = Duration(milliseconds: 1600);

/// The app-wide [ProviderScope] retry policy. See this library's doc for the
/// decision and what it costs.
///
/// Returns `null` — meaning "stop, deliver the error" — once
/// [kMaxAutomaticRetries] retries have run, and for the two error kinds
/// Riverpod itself never retries.
Duration? appRetryPolicy(int retryCount, Object error) {
  if (retryCount >= kMaxAutomaticRetries) return null;
  // An `Error` is a defect in this app and a `ProviderException` has already
  // been retried by the provider it wraps. Same exclusions as Riverpod's
  // default, restated here so this function is readable on its own.
  if (error is Error) return null;
  if (error is ProviderException) return null;
  if (alreadySpentARequestDeadline(error)) return null;
  return retryCount == 0
      ? const Duration(milliseconds: 400)
      : const Duration(milliseconds: 1200);
}

/// Whether [error] is a request this device already gave up on after waiting
/// out its full deadline (task 11.61).
///
/// **Two shapes, because a timed-out request surfaces as two types and both
/// reach a provider.** `AuthClient` lets [RequestGaveUp] travel unwrapped —
/// that is what lets the sign-in screen tell a transport failure from a server
/// that answered — while `HttpSyncTransport` catches it and rethrows a
/// `SyncTransportException` carrying the classified cause.
///
/// **Keyed on the classifier's answer, not on a reason string.** The cause is
/// decided in one place (`core/errors/transport_failure.dart`) and travels; a
/// second file matching `'request_timed_out'` by hand would be the pair that
/// drifts, which is the reason every one of those codes is a named constant in
/// the first place.
bool alreadySpentARequestDeadline(Object error) =>
    error is RequestGaveUp ||
    (error is SyncTransportException &&
        error.transportFailure?.cause == TransportFaultCause.timedOut);
