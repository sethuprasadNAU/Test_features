import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/provider_error.dart';

/// **Task 11.105 — what a provider boundary actually does to an error.**
///
/// Task 11.105's brief said Riverpod 3 wraps a provider's error in
/// `ProviderException` when you await `.future`, so every typed `catch` at
/// such a site is unreachable. That is **not** what riverpod 3.3.2 does, and
/// the difference decides what the fix has to be — so the claims are measured
/// here rather than believed, and measured against the same package version
/// the app ships.
///
/// **Why this file exists at all.** The two defects task 11.66 found on a
/// phone were invisible in code review: nothing looked wrong, it compiled, and
/// the tests passed. What was missing was a written-down, checked answer to
/// "what arrives at the catch". Every one of the facts below is load-bearing
/// for a decision made in `provider_error.dart`, `gps_provider.dart` or
/// `server_config_provider.dart`, and if a Riverpod upgrade changes one, this
/// file goes red and names it instead of a screen quietly going back to
/// blaming the network.
///
/// **No wall-clock assertions.** Riverpod's automatic retry makes the real
/// delay tens of seconds, and a test that waits is both slow and, on a loaded
/// machine, a coin flip — the shape task 11.88's lesson forbids. The retry is
/// measured by counting builds with the delay set to zero, and by asking
/// `defaultRetry` directly what it classifies as retryable. Both are exact.
class Boom implements Exception {
  const Boom();
  @override
  String toString() => 'Boom';
}

class BoomError extends Error {
  @override
  String toString() => 'BoomError';
}

/// A container whose providers fail on the first attempt, so a test measures
/// the boundary rather than the retry policy. Retry is measured on its own,
/// below.
ProviderContainer noRetry() => ProviderContainer(retry: (_, _) => null);

/// A real, nested `ProviderException`, obtained the only way this app can get
/// one: **provoked, never constructed.** Its constructor is `@internal`, and
/// that is a good thing here — a hand-built stand-in would keep passing after
/// an upgrade changed the shape of the real object.
///
/// [inner] throws; [outer] reads it synchronously and lets the resulting
/// `ProviderException` propagate, so reading [outer] wraps it a second time.
Object nestedProviderException() {
  final inner = Provider<int>((ref) => throw const Boom());
  final outer = Provider<int>((ref) => ref.watch(inner));
  final c = ProviderContainer(retry: (_, _) => null);
  try {
    c.read(outer);
    throw StateError('expected a ProviderException');
  } catch (e) {
    return e;
  } finally {
    c.dispose();
  }
}

void main() {
  group('mechanism 1 — an awaited provider delivers the raw error, unwrapped', () {
    // This is the claim task 11.105's brief got backwards, and everything
    // else follows from it: because the error is *not* wrapped here, the two
    // dead branches task 11.66 found were not dead from wrapping, and a shared
    // `ProviderException` unwrap would have fixed neither of them.

    test('FutureProvider', () async {
      final p = FutureProvider<int>((ref) async {
        ref.keepAlive();
        await null;
        throw const Boom();
      });
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});

      await expectLater(
        c.read(p.future),
        throwsA(isA<Boom>()),
        reason:
            'If this is a ProviderException, task 11.105\'s original premise '
            'has become true in a Riverpod upgrade and every typed catch at '
            'an awaited provider needs unwrapProviderError.',
      );
    });

    test('StreamProvider — gpsPositionProvider\'s shape', () async {
      final p = StreamProvider<int>((ref) {
        ref.keepAlive();
        return Stream<int>.error(const Boom());
      });
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});

      await expectLater(c.read(p.future), throwsA(isA<Boom>()));
    });

    test('AsyncNotifier', () async {
      final p = AsyncNotifierProvider<_ThrowingNotifier, int>(
        _ThrowingNotifier.new,
      );
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});

      await expectLater(c.read(p.future), throwsA(isA<Boom>()));
    });

    test('through a chain of providers — still not wrapped, not even once',
        () async {
      // The case that would most plausibly wrap, and the one a single-level
      // unwrap would be written for: a provider awaits another provider's
      // failed future and is itself awaited.
      final inner = FutureProvider<int>((ref) async {
        ref.keepAlive();
        await null;
        throw const Boom();
      });
      final outer = FutureProvider<int>((ref) async {
        ref.keepAlive();
        return await ref.watch(inner.future);
      });
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(outer, (_, _) {}, onError: (_, _) {});

      await expectLater(c.read(outer.future), throwsA(isA<Boom>()));
    });

    test('watching it as an AsyncValue gives the raw error too', () async {
      final p = StreamProvider<int>((ref) {
        ref.keepAlive();
        return Stream<int>.error(const Boom());
      });
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      await pumpEventQueue();

      expect(c.read(p).error, isA<Boom>());
    });
  });

  group('mechanism 2 — an autoDispose provider destroys the error instead',
      () {
    // This is what actually killed both branches task 11.66 reproduced. It is
    // not a wrap and no unwrap recovers it: the object that carried the
    // sentence is gone.

    test('the real gpsPositionProvider, read the way a screen reads it',
        () async {
      // Not a stand-in: `gpsPositionProvider` is `@riverpod` (autoDispose) and
      // `ProjectSetupScreen._fillFromCurrentLocation` awaits exactly this,
      // holding no listener across the await. This is the production call.
      final c = ProviderContainer(
        overrides: [
          gpsPositionProvider.overrideWith(
            (ref) => Stream<Position>.error(
              const LocationPermissionDeniedException(),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      Object? caught;
      try {
        await c.read(gpsPositionProvider.future);
        fail('expected the provider boundary to throw something');
      } catch (e) {
        caught = e;
      }

      expect(
        caught,
        isNot(isA<LocationPermissionDeniedException>()),
        reason:
            'If this now arrives intact, mechanism 2 has been fixed upstream. '
            'The value-carrying locationProblemProvider is still correct, but '
            'this file\'s account of why it exists needs rewriting.',
      );
      expect(
        providerErrorWasDestroyed(caught),
        isTrue,
        reason:
            'providerErrorWasDestroyed matches Riverpod\'s wording by hand. '
            'This provokes the real thing from a real provider, so a reworded '
            'message fails here rather than silently returning false '
            'everywhere.',
      );
      // And the thing that makes it a defect rather than a nuisance: nothing
      // about the object that arrives names the cause.
      expect(caught.toString(), isNot(contains('permission')));
    });

    test('unwrapping does not help — the point of the whole task', () {
      final destroyed = StateError(
        'The provider gpsPositionProvider was disposed during loading state, '
        'yet no value could be emitted.',
      );
      expect(unwrapProviderError(destroyed), same(destroyed));
    });
  });

  group('mechanism 3 — ProviderException is real, at other reads', () {
    // So `unwrapProviderError` is not dead code written against a premise that
    // turned out false. These two reads both happen in this app.

    test('reading a synchronous provider that threw', () {
      final p = Provider<int>((ref) => throw const Boom());
      final c = noRetry();
      addTearDown(c.dispose);

      expect(
        () => c.read(p),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.exception,
            'exception',
            isA<Boom>(),
          ),
        ),
      );
      try {
        c.read(p);
      } catch (e) {
        expect(unwrapProviderError(e), isA<Boom>());
      }
    });

    test('AsyncValue.requireValue on an error state', () async {
      final p = FutureProvider<int>((ref) async {
        ref.keepAlive();
        await null;
        throw const Boom();
      });
      final c = noRetry();
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      await pumpEventQueue();

      try {
        c.read(p).requireValue;
        fail('expected requireValue to throw');
      } catch (e) {
        expect(e, isA<ProviderException>());
        expect(unwrapProviderError(e), isA<Boom>());
      }
    });

    test('unwrapProviderError peels a nest, not just one layer', () {
      final nested = nestedProviderException();
      expect(
        nested,
        isA<ProviderException>().having(
          (e) => e.exception,
          'exception',
          isA<ProviderException>(),
        ),
        reason:
            'Riverpod really does nest these two deep here; if it stops, the '
            'recursion in unwrapProviderError is no longer load-bearing and '
            'this test is no longer testing it.',
      );
      expect(unwrapProviderError(nested), isA<Boom>());
    });

    test('unwrapProviderError returns anything else unchanged', () {
      const plain = Boom();
      expect(unwrapProviderError(plain), same(plain));
      expect(unwrapProviderError(const FormatException()), isA<FormatException>());
    });


  });

  group('the delay — an Exception is retried before the error is delivered',
      () {
    // Not a type problem, but it reaches a person the same way: the await does
    // not return, so nothing can be said, for as long as the retries run.
    // Riverpod's defaults are ten attempts with exponential backoff to a 6.4s
    // ceiling, which is 38 seconds. Measured once, on 2026-08-31, and asserted
    // here structurally rather than by waiting — see this file's header.
    //
    // **These tests measure Riverpod's default, which task 11.107 replaced as
    // the app's policy.** They still matter: the default is what any container
    // built without `appRetryPolicy` gets, including most of this suite's own.
    // The app's own budget is pinned in `retry_policy_test.dart`.

    test('the build really is re-run, and .future waits for the last attempt',
        () async {
      var builds = 0;
      final p = FutureProvider<int>((ref) async {
        ref.keepAlive();
        builds++;
        await null;
        throw const Boom();
      });
      final c = ProviderContainer(
        retry: (count, _) => count < 2 ? Duration.zero : null,
      );
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});

      await expectLater(c.read(p.future), throwsA(isA<Boom>()));
      expect(
        builds,
        3,
        reason:
            'One attempt plus two retries. If this is 1, automatic retry is '
            'gone from Riverpod itself — good news, but `appRetryPolicy` and '
            'the comments in provider_error.dart describing the default it '
            'replaced are now wrong.',
      );
    });

    test('anything that merely implements Exception is retried', () {
      // LocationPermissionDeniedException and InvalidServerUrl are both this
      // shape, which is why both take the slow path rather than failing fast.
      expect(
        ProviderContainer.defaultRetry(0, const Boom()),
        isNotNull,
        reason: 'an Exception is retried',
      );
      expect(
        ProviderContainer.defaultRetry(0, const LocationPermissionDeniedException()),
        isNotNull,
      );
    });

    test('an Error, and a ProviderException, are not retried', () {
      expect(ProviderContainer.defaultRetry(0, BoomError()), isNull);
      expect(ProviderContainer.defaultRetry(0, nestedProviderException()), isNull);
    });
  });
}

class _ThrowingNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    await null;
    throw const Boom();
  }
}
