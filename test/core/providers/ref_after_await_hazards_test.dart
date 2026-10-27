import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 11.256 — **two hazards have been wearing one name, and this file
/// separates them by measurement.** Everything below runs against riverpod
/// 3.3.2 with hand-written providers built to have exactly one property each,
/// so that each test changes one thing and reads one outcome.
///
/// The two hazards, as the plan entry names them:
///
/// - **(a) A bare read of an auto-disposing provider.** Nothing listens, so
///   riverpod disposes the provider a microtask after the read returns, while
///   its `async` body is still running. The next `ref.*` in that body throws
///   *"Cannot use the Ref of … after it has been disposed"*. This is what
///   broke the tag database's + button (task 11.235) and the Sync Status
///   screen's "Try again" (task 11.236).
/// - **(b) An invalidation landing while a provider is mid-build.** The
///   comment on `currentUser` and the one in `tag_view_refresh.dart` both
///   describe an in-flight `Future` that is orphaned and never completes.
///
/// **What the measurements say, so the guard next door can be read without
/// re-running this file** (`ref_after_await_guard_test.dart`):
///
/// 1. **(a) needs three things at once: an auto-disposing provider, a `ref.*`
///    use after a completed `await` in its body, and a read that nothing
///    keeps alive.** Remove any one and it does not happen — the same body
///    completes normally when a listener holds it, and a body with no `ref.*`
///    after its gap completes normally even read bare. The `.future` of the
///    bare read completes *with an error*, not never; the person sees a
///    control that does nothing because nobody catches it. A listener that
///    leaves mid-build disposes the provider too, but the stale build's error
///    is swallowed and nothing is waiting, so nothing surfaces.
/// 2. **(b) is not a property of the provider's body at all.** An
///    invalidation mid-build orphans a bare `keepAlive` read's future *whether
///    or not* the body ever touches `ref` after a gap: nothing listens, so the
///    rebuild is lazy and never runs, and the stale build's value is discarded
///    — silently, since the old `Ref` is still the live one and nothing
///    throws. The same invalidation is harmless to a provider something is
///    listening to: the stale build's `ref.*` throws (or its value is
///    discarded), riverpod ignores the stale build (`if (!running) return` in
///    its `handleFuture`), and the listener and the pending `.future` both
///    receive the rebuild's value.
/// 3. **So "always watched, never read bare" is a complete exemption from
///    (a)** — a listener is the one thing that changes (a)'s outcome — **and
///    from (b) as well**, for the same reason: the rebuild that completes the
///    orphaned future runs promptly only when something listens. What it is
///    *not* is something a call site can be trusted to remember, which is why
///    the guard derives it from the code rather than accepting it as a note.
/// 4. **(b) belongs to `ArrivalRefresh.settleFirst`, not to this class.** It
///    is a hazard of *when an invalidation lands*, which no predicate over a
///    provider body can see. Task 11.153 measured it and built the settle
///    guard; this file confirms it is a different hazard from (a) and that a
///    body-shape predicate cannot be asked about it. The `currentUser`
///    comment's "orphaned forever" is (b) self-inflicted — a build that writes
///    what it watches — and it is measured true for a bare read and false for
///    a listened one.
///
/// Every test here awaits its `.future` through [_outcome], which turns
/// "hangs" into a stated result rather than a ten-minute timeout.
void main() {
  group('hazard (a): bare read of an auto-disposing provider', () {
    test(
      'auto-dispose + ref after a real gap + read bare: the body throws '
      '"after it has been disposed" and the .future errors (it does not hang)',
      () async {
        final gate = Completer<void>();
        final thrown = <Object>[];
        final subject = _autoDisposeSubject(
          gate,
          refAfterGap: true,
          thrown: thrown,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final future = container.read(subject.future);
        await pumpEventQueue();
        gate.complete();

        final outcome = await _outcome(future);
        expect(outcome, isA<_Errored>());
        expect(
          (outcome as _Errored).error.toString(),
          contains('after it has been disposed'),
        );
        expect(thrown, hasLength(1), reason: 'the body itself threw, once');
      },
    );

    test(
      'control: the same read of a body with no ref after its gap completes',
      () async {
        final gate = Completer<void>();
        final subject = _autoDisposeSubject(gate, refAfterGap: false);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final future = container.read(subject.future);
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _Completed('built 0'));
      },
    );

    test(
      'control: the same body, read while something listens, completes',
      () async {
        final gate = Completer<void>();
        final thrown = <Object>[];
        final subject = _autoDisposeSubject(
          gate,
          refAfterGap: true,
          thrown: thrown,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final sub = container.listen(subject, (_, _) {});
        addTearDown(sub.close);
        final future = container.read(subject.future);
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _Completed('built 0'));
        expect(thrown, isEmpty);
      },
    );

    test('the listener leaving mid-build disposes the provider: the stale body '
        'throws, nothing surfaces, and the .future errors quietly', () async {
      final gate = Completer<void>();
      final thrown = <Object>[];
      final subject = _autoDisposeSubject(
        gate,
        refAfterGap: true,
        thrown: thrown,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final sub = container.listen(subject, (_, _) {});
      final future = container.read(subject.future);
      await pumpEventQueue();
      sub.close(); // the screen was popped
      await pumpEventQueue();
      gate.complete();

      // An unhandled async error would fail this test on its own; that it
      // does not is the "nothing surfaces" half of the claim.
      final outcome = await _outcome(future);
      expect(outcome, isA<_Errored>());
      expect(thrown, hasLength(1));
    });
  });

  group('hazard (b): an invalidation landing mid-build', () {
    test(
      'auto-dispose, listened, invalidated mid-gap: the stale build throws, '
      'riverpod discards it, and the pending .future gets the rebuild value',
      () async {
        final gate = Completer<void>();
        final thrown = <Object>[];
        final builds = <int>[];
        final counter = _Counter();
        final subject = _autoDisposeSubject(
          gate,
          refAfterGap: true,
          thrown: thrown,
          builds: builds,
          counter: counter,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final seen = <AsyncValue<String>>[];
        final sub = container.listen(subject, (_, next) => seen.add(next));
        addTearDown(sub.close);
        final future = container.read(subject.future);
        await pumpEventQueue();
        counter.value = 1;
        container.invalidate(subject);
        // Let the rebuild start before the stale build resumes — the
        // ordering a database gap produces. (Completing the gate first lets
        // the stale build finish on a `Ref` that is not yet stale, and its
        // value is accepted; that ordering is a scheduler race, not the app.)
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _Completed('built 1'));
        expect(builds, [0, 1], reason: 'two builds ran');
        expect(
          thrown,
          hasLength(1),
          reason: 'the first build threw on its ref',
        );
        expect(seen.last, const AsyncData('built 1'));
      },
    );

    test('auto-dispose, listened, invalidated mid-gap, NO ref after the gap: '
        'the same outcome — the body shape is not what (b) is about', () async {
      final gate = Completer<void>();
      final builds = <int>[];
      final counter = _Counter();
      final subject = _autoDisposeSubject(
        gate,
        refAfterGap: false,
        builds: builds,
        counter: counter,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final sub = container.listen(subject, (_, _) {});
      addTearDown(sub.close);
      final future = container.read(subject.future);
      await pumpEventQueue();
      counter.value = 1;
      container.invalidate(subject);
      // Let the rebuild start before the stale build resumes — the
      // ordering a database gap produces. (Completing the gate first lets
      // the stale build finish on a `Ref` that is not yet stale, and its
      // value is accepted; that ordering is a scheduler race, not the app.)
      await pumpEventQueue();
      gate.complete();

      expect(await _outcome(future), const _Completed('built 1'));
      expect(builds, [0, 1]);
    });

    test(
      'keepAlive, read bare, invalidated mid-gap, NO ref after the gap: '
      'the .future never completes (task 11.153\'s measurement, kept)',
      () async {
        final gate = Completer<void>();
        final builds = <int>[];
        final counter = _Counter();
        final subject = _keepAliveSubject(
          gate,
          refAfterGap: false,
          builds: builds,
          counter: counter,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final future = container.read(subject.future);
        await pumpEventQueue();
        counter.value = 1;
        container.invalidate(subject);
        // Let the rebuild start before the stale build resumes — the
        // ordering a database gap produces. (Completing the gate first lets
        // the stale build finish on a `Ref` that is not yet stale, and its
        // value is accepted; that ordering is a scheduler race, not the app.)
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _NeverCompleted());
        expect(
          builds,
          [0],
          reason:
              'nothing listens, so the rebuild is lazy and never runs — '
              'which is why nothing can complete the future',
        );
      },
    );

    test(
      'keepAlive, read bare, invalidated mid-gap, WITH ref after the gap: '
      'nothing throws — no rebuild ran, so the old Ref is still the live '
      'one — the stale value is discarded, and the .future never completes',
      () async {
        final gate = Completer<void>();
        final thrown = <Object>[];
        final counter = _Counter();
        final subject = _keepAliveSubject(
          gate,
          refAfterGap: true,
          thrown: thrown,
          counter: counter,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final future = container.read(subject.future);
        await pumpEventQueue();
        counter.value = 1;
        container.invalidate(subject);
        // Let the rebuild start before the stale build resumes — the
        // ordering a database gap produces. (Completing the gate first lets
        // the stale build finish on a `Ref` that is not yet stale, and its
        // value is accepted; that ordering is a scheduler race, not the app.)
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _NeverCompleted());
        expect(
          thrown,
          isEmpty,
          reason: 'the hang is silent: not even the stale build complains',
        );
      },
    );

    test(
      'keepAlive, listened, invalidated mid-gap: completes with the rebuild '
      'value — a listener is the exemption from (b) as much as from (a)',
      () async {
        final gate = Completer<void>();
        final builds = <int>[];
        final counter = _Counter();
        final subject = _keepAliveSubject(
          gate,
          refAfterGap: true,
          builds: builds,
          counter: counter,
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final sub = container.listen(subject, (_, _) {});
        addTearDown(sub.close);
        final future = container.read(subject.future);
        await pumpEventQueue();
        counter.value = 1;
        container.invalidate(subject);
        // Let the rebuild start before the stale build resumes — the
        // ordering a database gap produces. (Completing the gate first lets
        // the stale build finish on a `Ref` that is not yet stale, and its
        // value is accepted; that ordering is a scheduler race, not the app.)
        await pumpEventQueue();
        gate.complete();

        expect(await _outcome(future), const _Completed('built 1'));
        expect(builds, [0, 1]);
      },
    );

    test('the currentUser shape — a build that watches a dependency and writes '
        'it — completes when listened (the write schedules a rebuild whose '
        'second pass has nothing left to write) and never completes when read '
        'bare (the rebuild is lazy and nothing asks for it)', () async {
      // `currentUser`'s comment says a watch-and-mutate build "orphans the
      // original Future forever". Measured here on 3.3.2: it does, for a
      // bare read — which is how `currentUserProvider.future` is reached
      // from most of the app — and it is hazard (b) again, self-inflicted.
      final flag = NotifierProvider<_Flag, int>(_Flag.new);
      final builds = <int>[];
      final subject = FutureProvider<String>((ref) async {
        final v = ref.watch(flag);
        builds.add(v);
        await Future<void>.delayed(Duration.zero);
        if (v == 0) ref.read(flag.notifier).set(1);
        return 'v=$v';
      });

      final listened = ProviderContainer();
      addTearDown(listened.dispose);
      final sub = listened.listen(subject, (_, _) {});
      addTearDown(sub.close);
      final listenedOutcome = await _outcome(listened.read(subject.future));

      builds.clear();
      final bare = ProviderContainer();
      addTearDown(bare.dispose);
      final bareOutcome = await _outcome(bare.read(subject.future));

      expect(listenedOutcome, const _Completed('v=1'));
      expect(bareOutcome, const _NeverCompleted());
      expect(builds, [0], reason: 'the bare read never rebuilt');
    });
  });
}

/// A provider whose only interesting property is where its `ref.*` calls
/// sit relative to a real asynchronous gap ([gate]). `ref.watch` is the call
/// that throws once the `Ref` is stale, so it is the one placed after the gap
/// when [refAfterGap] is set. [counter] is a plain value read at the top of
/// each build so that a rebuild's result can be told from the first build's.
FutureProvider<String> _autoDisposeSubject(
  Completer<void> gate, {
  required bool refAfterGap,
  List<Object>? thrown,
  List<int>? builds,
  _Counter? counter,
}) {
  return FutureProvider.autoDispose<String>(
    _subjectBody(
      gate,
      refAfterGap: refAfterGap,
      thrown: thrown,
      builds: builds,
      counter: counter ?? _Counter(),
    ),
  );
}

FutureProvider<String> _keepAliveSubject(
  Completer<void> gate, {
  required bool refAfterGap,
  List<Object>? thrown,
  List<int>? builds,
  _Counter? counter,
}) {
  return FutureProvider<String>(
    _subjectBody(
      gate,
      refAfterGap: refAfterGap,
      thrown: thrown,
      builds: builds,
      counter: counter ?? _Counter(),
    ),
  );
}

Future<String> Function(Ref) _subjectBody(
  Completer<void> gate, {
  required bool refAfterGap,
  required _Counter counter,
  List<Object>? thrown,
  List<int>? builds,
}) {
  final dep = Provider<int>((ref) => 0);
  return (ref) async {
    ref.watch(dep);
    final before = counter.value;
    builds?.add(before);
    await gate.future;
    if (!refAfterGap) return 'built $before';
    try {
      ref.watch(dep);
      return 'built ${counter.value}';
    } catch (e) {
      thrown?.add(e);
      rethrow;
    }
  };
}

class _Counter {
  int value = 0;
}

class _Flag extends Notifier<int> {
  @override
  int build() => 0;
  void set(int v) => state = v;
}

sealed class _Outcome {
  const _Outcome();
}

class _Completed extends _Outcome {
  const _Completed(this.value);
  final String value;
  @override
  bool operator ==(Object other) => other is _Completed && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'Completed($value)';
}

class _Errored extends _Outcome {
  const _Errored(this.error);
  final Object error;
  @override
  String toString() => 'Errored($error)';
}

class _NeverCompleted extends _Outcome {
  const _NeverCompleted();
  @override
  bool operator ==(Object other) => other is _NeverCompleted;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'NeverCompleted';
}

/// "Never completes" as a value rather than a timeout: the event queue is
/// drained repeatedly, and a future still pending after that has nothing left
/// that could complete it. Every path here is microtask- or `Duration.zero`-
/// bound, so twenty drains is a large margin rather than a guess about time.
Future<_Outcome> _outcome(Future<String> future) async {
  _Outcome? result;
  future.then<void>(
    (v) => result = _Completed(v),
    onError: (Object e) => result = _Errored(e),
  );
  for (var i = 0; i < 20 && result == null; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(Duration.zero);
  }
  return result ?? const _NeverCompleted();
}
