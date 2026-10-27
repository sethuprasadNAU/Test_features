/// **What a Riverpod provider boundary does to an error on its way to a
/// person, and the one place this app deals with it.**
///
/// Task 11.105. Task 11.66 walked a real Android build and found two screens
/// showing the wrong cause for a failure — location permission denied, and a
/// plain-`http://` server address a release build refuses. In both, the code
/// that would have said the right thing was a typed `catch` sitting on the far
/// side of `await ref.read(someProvider.future)`, and in both the branch was
/// never taken.
///
/// **The brief for this task said Riverpod 3 wraps a provider's error in
/// `ProviderException`, so a typed `catch` cannot match. Measured against
/// riverpod 3.3.2 on 2026-08-31, that is not what happens at an awaited
/// provider** — see `test/core/providers/provider_boundary_behaviour_test.dart`,
/// which pins every claim below and turns red if a Riverpod upgrade changes
/// one. There are three distinct mechanisms and only one of them involves
/// wrapping:
///
/// 1. **`await ref.read(p.future)` delivers the raw exception, unwrapped.**
///    Measured for `FutureProvider`, `StreamProvider` and `AsyncNotifier`,
///    directly and through a chain of providers. So a typed `catch` at an
///    awaited provider is *not* dead because of `ProviderException`.
///
/// 2. **Unless the provider is torn down while still loading, in which case
///    the original error is destroyed rather than wrapped.** A provider
///    generated from `@riverpod` (as opposed to `@Riverpod(keepAlive: true)`)
///    is autoDispose, and `ref.read(p.future)` holds no listener across the
///    `await`, so the element is disposed the moment `read` returns. The
///    caller then gets `StateError: "The provider p was disposed during
///    loading state, yet no value could be emitted."` — a different object,
///    carrying none of the original's message. **This is what actually killed
///    both branches task 11.66 found.** No unwrap can undo it: the sentence is
///    gone, not hidden. [providerErrorWasDestroyed] recognises it.
///
/// 3. **`ProviderException` is real, but at other reads.** It is raised by
///    `ref.read(syncProvider)` on a synchronous provider whose build threw,
///    and by `AsyncValue.requireValue` on an error state. Both are reachable
///    here, so [unwrapProviderError] exists and is used wherever an error that
///    crossed a provider boundary is type-tested.
///
/// **And one behaviour that is not about types at all but reaches a person the
/// same way:** Riverpod 3 retries a failed provider automatically —
/// `ProviderContainer.defaultRetry`, ten attempts with exponential backoff,
/// skipped only for an `Error` or a `ProviderException`. Anything that merely
/// `implements Exception` is retried, and `p.future` stays pending throughout.
/// Measured: **38.2 seconds** before the error is delivered, for a provider
/// with a live listener. A button that awaits such a provider spun for the
/// better part of a minute before it could say anything.
///
/// **That is Riverpod's default, and since task 11.107 it is no longer this
/// app's.** `main.dart` installs `appRetryPolicy` on the `ProviderScope`: three
/// attempts, 1.6 seconds of backoff in the worst case, then the error is
/// delivered. The reasoning, and what the shorter budget costs, is written down
/// in `retry_policy.dart`. The 38.2 seconds above is kept because it is what
/// any code reading this file gets back the moment a `ProviderScope` is built
/// without that policy.
///
/// ## The rule this file exists to encode
///
/// **An error that has to survive a provider boundary to reach a person is an
/// error that does not reach them.** Task 11.104 wrote that sentence and built
/// the answer: the refusal travels as a *value*, from a `keepAlive` provider
/// that cannot throw, and every surface reads that one value. See
/// `serverUrlRefusalProvider` and `locationProblemProvider` for the two worked
/// examples. The helpers below are for errors that cross a boundary anyway —
/// they make a type test correct where one is unavoidable. They are not a
/// licence to put a new one there.
///
/// `test/documentation/typed_catch_at_provider_boundary_test.dart` enforces
/// the rule on new code.
library;

import 'package:flutter_riverpod/misc.dart' show ProviderException;

/// The original error, with any [ProviderException] wrapping peeled off.
///
/// **Recursive, deliberately.** Riverpod nests them: a provider that awaits
/// another provider's failed `.future` and is itself read synchronously
/// produces `ProviderException(ProviderException(cause))`, and
/// `ProviderException.toString()` has a dedicated branch for exactly that
/// shape. A single-level unwrap would work on the cases anybody thinks to test
/// and fail on a chain of three providers in the field.
///
/// Returns [error] unchanged when there is nothing to unwrap, so it is safe to
/// call on any caught object.
Object unwrapProviderError(Object error) {
  var current = error;
  // Bounded rather than `while (true)`: `ProviderException.exception` is a
  // plain `Object` and nothing in its type stops a cycle. A guard that can
  // hang the UI thread is worse than one that gives up.
  for (var depth = 0; depth < 16; depth++) {
    if (current is! ProviderException) return current;
    current = current.exception;
  }
  return current;
}

/// The text Riverpod's [StateError] carries when a provider is disposed
/// mid-load. Matched on rather than reconstructed, because the provider's name
/// is interpolated into the middle of it.
///
/// Riverpod source: `ElementWithFuture._missingLastValueError`,
/// `riverpod-3.3.2/lib/src/core/element.dart:201`.
const _destroyedErrorSuffix =
    'was disposed during loading state, yet no value could be emitted.';

/// **True when this error is Riverpod's stand-in for one it threw away.**
///
/// Not "the provider failed" — it means *the app cannot know why*. The
/// provider was disposed while still loading and whatever it was going to
/// report went with it (mechanism 2 in this library's doc). A caller that sees
/// this must not name a cause: it has none, and naming one is precisely the
/// wrong-cause defect task 11.104 exists to correct. Say what is true — the
/// check could not be completed — or, better, do not depend on a boundary that
/// can do this.
///
/// Matched on the message because Riverpod raises a bare [StateError] with no
/// type of its own. That is a hand-matched string on somebody else's text, and
/// it will silently start returning `false` if Riverpod rewords it — so
/// `test/core/providers/provider_boundary_behaviour_test.dart` provokes the
/// real thing from a real provider and asserts this returns `true`, rather
/// than asserting against a copy of the string.
bool providerErrorWasDestroyed(Object error) =>
    error is StateError && error.message.endsWith(_destroyedErrorSuffix);
