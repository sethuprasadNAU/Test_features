import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/retry_policy.dart';

/// **Task 11.107 — what the app's retry policy costs a person who is waiting.**
///
/// The decision and its trade-offs are written down in `retry_policy.dart`.
/// This file pins the two numbers that decision rests on, so that changing
/// either one is a deliberate act rather than a side effect.
///
/// **No wall-clock assertions** — the delays are summed from the policy
/// function, not waited out. Task 11.88's lesson: a test that waits on a real
/// clock is a coin flip on a loaded machine.
class _Blip implements Exception {
  const _Blip();
}

class _Defect extends Error {}

void main() {
  test('the whole retry budget is under two seconds', () {
    final delays = <Duration>[];
    for (var attempt = 0;; attempt++) {
      final delay = appRetryPolicy(attempt, const _Blip());
      if (delay == null) break;
      delays.add(delay);
      expect(attempt, lessThan(10), reason: 'the policy must terminate');
    }

    expect(delays.length, kMaxAutomaticRetries);
    expect(
      delays.fold(Duration.zero, (a, b) => a + b),
      kMaxAutomaticRetryDelay,
      reason:
          'This is the longest a person waits on backoff alone before a failed '
          'provider is allowed to say anything. Riverpod\'s default is 38.2 '
          'seconds, which reads as a frozen app (task 11.107). If this test is '
          'red because the budget grew, the screens that show "still trying" '
          'are the only thing standing between that number and a person who '
          'thinks the app has hung.',
    );
  });

  test('the whole budget is a fraction of the default it replaces', () {
    // Per attempt the policy is not uniformly shorter — its first wait is
    // 400 ms against Riverpod's 200 ms, deliberately, because a retry 200 ms
    // after a failure usually hits the same blip. What matters is the total a
    // person waits before anything can be said, and that is the comparison.
    Duration budget(Duration? Function(int) policy) {
      var total = Duration.zero;
      for (var attempt = 0; attempt < 64; attempt++) {
        final delay = policy(attempt);
        if (delay == null) break;
        total += delay;
      }
      return total;
    }

    final theirs =
        budget((attempt) => ProviderContainer.defaultRetry(attempt, const _Blip()));
    expect(
      theirs.inSeconds,
      greaterThan(30),
      reason:
          'Riverpod\'s default, measured at 38.2 s on 2026-08-31. If this has '
          'dropped, an upgrade changed the default and the reasoning in '
          'retry_policy.dart should be re-read rather than assumed.',
    );
    expect(kMaxAutomaticRetryDelay * 10, lessThan(theirs));
  });

  test('an Error is not retried — running a defect three times is still a defect',
      () {
    expect(appRetryPolicy(0, _Defect()), isNull);
  });

  test('an Exception is retried — a field connection blips and comes back', () {
    expect(appRetryPolicy(0, const _Blip()), isNotNull);
  });
}
