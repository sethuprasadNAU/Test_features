import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// §4.4's limits, verified **by exceeding them** — which is the task's own
/// acceptance criterion, and the only way to test a limit that means anything.
void main() {
  var now = DateTime.utc(2026, 8, 7, 12);
  RateLimiter build([RateLimitPolicy? policy]) =>
      RateLimiter(policy: policy, clock: () => now);

  setUp(() => now = DateTime.utc(2026, 8, 7, 12));

  group('magic link, per email', () {
    test('allows exactly 3 in 15 minutes and limits the 4th', () {
      final limiter = build();
      for (var i = 0; i < 3; i++) {
        expect(
          limiter.checkMagicLink(
            email: 'sam@example.com',
            source: RequestSource.inProcess,
          ),
          RateLimitOutcome.allowed,
          reason: 'request ${i + 1} of 3 must be allowed',
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.emailLimited,
      );
    });

    test('the limit is per address — a second address is unaffected', () {
      // Otherwise one attacker requesting links for one colleague would lock
      // out everybody else's sign-in, turning a bombing control into a
      // denial-of-service primitive.
      final limiter = build();
      for (var i = 0; i < 4; i++) {
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'kim@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.allowed,
      );
    });

    test('the window reopens once it has elapsed', () {
      final limiter = build();
      for (var i = 0; i < 4; i++) {
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        );
      }
      now = now.add(const Duration(minutes: 16));
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.allowed,
      );
    });

    test('the daily cap still holds after many short windows', () {
      // The reason there are two rules per key rather than one: a 3-per-15-min
      // limit alone permits 288 emails a day to one address, which is email
      // bombing at a leisurely pace.
      final limiter = build();
      var allowed = 0;
      for (var attempt = 0; attempt < 40; attempt++) {
        if (limiter.checkMagicLink(
              email: 'sam@example.com',
              source: RequestSource.inProcess,
            ) ==
            RateLimitOutcome.allowed) {
          allowed++;
        }
        now = now.add(const Duration(minutes: 16));
      }
      expect(allowed, 10, reason: '10 per day is the second rule');
    });

    test('an exhausted daily cap does not keep pushing the 15-minute window', () {
      // The all-or-nothing consumption rule in `_admit`. If the short window
      // kept incrementing on requests the daily cap already refused, a caller
      // who kept retrying would stay locked out of the short window long after
      // the day rolled over — a limit that gets stricter the more it is hit is
      // not the limit §4.4 specified.
      final limiter = build();
      for (var attempt = 0; attempt < 40; attempt++) {
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        );
        now = now.add(const Duration(minutes: 16));
      }
      // Day rolls over; the short window has long since expired too.
      now = now.add(const Duration(days: 1));
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.allowed,
      );
    });
  });

  group('magic link, per source', () {
    test('allows 10 in 15 minutes and limits the 11th', () {
      final limiter = build();
      for (var i = 0; i < 10; i++) {
        expect(
          limiter.checkMagicLink(
            // A different address every time: this is the enumeration/bombing
            // pattern per-email limits cannot see.
            email: 'user$i@example.com',
            source: const RequestSource.direct('203.0.113.5'),
          ),
          RateLimitOutcome.allowed,
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'user99@example.com',
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.sourceLimited,
      );
    });

    test('the limit is per source — another address is unaffected', () {
      final limiter = build();
      for (var i = 0; i < 11; i++) {
        limiter.checkMagicLink(
          email: 'user$i@example.com',
          source: const RequestSource.direct('203.0.113.5'),
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'other@example.com',
          source: const RequestSource.direct('198.51.100.7'),
        ),
        RateLimitOutcome.allowed,
      );
    });

    test('source limiting is reported ahead of email limiting', () {
      // Order matters: a caller flooding one address from one host must get the
      // honest 429 rather than a stream of silent 202s, or a source-limited
      // attacker still learns per-address information from which requests were
      // quietly dropped.
      final limiter = build(
        const RateLimitPolicy(
          magicLinkPerEmail: [
            RateLimitRule(limit: 1, window: Duration(minutes: 15)),
          ],
          magicLinkPerSource: [
            RateLimitRule(limit: 1, window: Duration(minutes: 15)),
          ],
        ),
      );
      limiter.checkMagicLink(
        email: 'sam@example.com',
        source: const RequestSource.direct('203.0.113.5'),
      );
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.sourceLimited,
      );
    });

    test('a null source (in-process request) is not source limited', () {
      final limiter = build();
      for (var i = 0; i < 50; i++) {
        expect(
          limiter.checkMagicLink(
            email: 'user$i@example.com',
            source: RequestSource.inProcess,
          ),
          RateLimitOutcome.allowed,
        );
      }
    });
  });

  group('redemption, per source', () {
    test('allows 20 a minute and limits the 21st', () {
      final limiter = build();
      for (var i = 0; i < 20; i++) {
        expect(
          limiter.checkRedemption(
            source: const RequestSource.direct('203.0.113.5'),
          ),
          RateLimitOutcome.allowed,
        );
      }
      expect(
        limiter.checkRedemption(
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.sourceLimited,
      );
    });

    test('redemption and magic-link budgets are independent', () {
      // Sharing a counter would let a burst of sign-in requests lock out the
      // redemption a legitimate user is about to perform.
      final limiter = build();
      for (var i = 0; i < 11; i++) {
        limiter.checkMagicLink(
          email: 'user$i@example.com',
          source: const RequestSource.direct('203.0.113.5'),
        );
      }
      expect(
        limiter.checkRedemption(
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.allowed,
      );
    });
  });

  group('link-status poll, per source (task 10.56, I-6)', () {
    test('allows 30 a minute and limits the 31st', () {
      final limiter = build();
      for (var i = 0; i < 30; i++) {
        expect(
          limiter.checkLinkStatus(
            source: const RequestSource.direct('203.0.113.5'),
          ),
          RateLimitOutcome.allowed,
        );
      }
      expect(
        limiter.checkLinkStatus(
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.sourceLimited,
      );
    });

    test('link-status, redemption, and magic-link budgets are independent', () {
      final limiter = build();
      for (var i = 0; i < 30; i++) {
        limiter.checkLinkStatus(
          source: const RequestSource.direct('203.0.113.5'),
        );
      }
      expect(
        limiter.checkRedemption(
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.allowed,
      );
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: const RequestSource.direct('203.0.113.5'),
        ),
        RateLimitOutcome.allowed,
      );
    });

    test('a degenerate source is not link-status limited', () {
      final limiter = build();
      for (var i = 0; i < 200; i++) {
        expect(
          limiter.checkLinkStatus(source: RequestSource.unattributed),
          RateLimitOutcome.allowed,
        );
      }
    });
  });

  group('RateLimitPolicy.fromEnvironment (task 10.26)', () {
    test('defaults to the shipped policy when unset', () {
      final policy = RateLimitPolicy.fromEnvironment({});
      const shipped = RateLimitPolicy();
      expect(
        policy.magicLinkPerSource.first.limit,
        shipped.magicLinkPerSource.first.limit,
      );
    });

    test('ignores an unrecognized value the same as unset', () {
      final policy = RateLimitPolicy.fromEnvironment({
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': 'true',
      });
      const shipped = RateLimitPolicy();
      expect(
        policy.magicLinkPerSource.first.limit,
        shipped.magicLinkPerSource.first.limit,
      );
    });

    test('raises the per-source ceiling when explicitly disabled', () {
      final policy = RateLimitPolicy.fromEnvironment({
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': '1',
      });
      final limiter = RateLimiter(policy: policy);
      for (var i = 0; i < 100; i++) {
        expect(
          limiter.checkMagicLink(
            email: 'user$i@example.com',
            source: const RequestSource.direct('203.0.113.5'),
          ),
          RateLimitOutcome.allowed,
          reason:
              'request ${i + 1} of 100 from one collapsed source must '
              'still be allowed',
        );
      }
    });

    test('raises the link-status ceiling when explicitly disabled too', () {
      final policy = RateLimitPolicy.fromEnvironment({
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': '1',
      });
      final limiter = RateLimiter(policy: policy);
      for (var i = 0; i < 100; i++) {
        expect(
          limiter.checkLinkStatus(
            source: const RequestSource.direct('203.0.113.5'),
          ),
          RateLimitOutcome.allowed,
          reason:
              'request ${i + 1} of 100 from one collapsed source must '
              'still be allowed',
        );
      }
    });

    test('leaves the per-email limit untouched', () {
      // Disabling the per-source rule must not be a side door to disabling
      // the per-email rule too — nothing about the Docker port-proxy problem
      // this exists for touches email keying.
      final policy = RateLimitPolicy.fromEnvironment({
        'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': '1',
      });
      final limiter = RateLimiter(policy: policy);
      for (var i = 0; i < 3; i++) {
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.emailLimited,
      );
    });

    test('refuses the combination in production', () {
      expect(
        () => RateLimitPolicy.fromEnvironment({
          'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': '1',
          'TRITRACK_ENV': 'production',
        }),
        throwsStateError,
      );
    });

    test('the production refusal survives case and whitespace in TRITRACK_ENV', () {
      // Security Model §16.3's M-11 sweep: an exact `==` comparison let
      // "Production" silently disable the per-source limit instead of
      // refusing.
      for (final value in ['Production', 'PRODUCTION', ' production', 'production ']) {
        expect(
          () => RateLimitPolicy.fromEnvironment({
            'TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED': '1',
            'TRITRACK_ENV': value,
          }),
          throwsStateError,
          reason: 'TRITRACK_ENV="$value" must still be recognised as production',
        );
      }
    });
  });

  group('memory bounds', () {
    test(
      'expired windows are evicted so counters cannot grow without bound',
      () {
        // Keys include attacker-supplied email addresses, so without eviction
        // this map is an unbounded-growth primitive on an unauthenticated route
        // — the same class of problem as the request body limits (§3.1).
        //
        // **Distinct source per request, deliberately.** From a *single* source
        // the per-source limit refuses at 10 and no further email keys are ever
        // created, so the limiter bounds its own growth. The case that actually
        // grows the map is the distributed one — the botnet §4.4 names — where
        // every request is under its own source's limit.
        final limiter = build();
        for (var i = 0; i < 500; i++) {
          limiter.checkMagicLink(
            email: 'flood$i@example.com',
            source: RequestSource.direct('203.0.113.${i % 256}'),
          );
        }
        expect(limiter.trackedKeys, greaterThan(100));

        // Past every window, including the daily one.
        now = now.add(const Duration(days: 2));
        limiter.evictExpired();
        expect(limiter.trackedKeys, 0);
      },
    );

    test('eviction does not drop a window that can still refuse', () {
      final limiter = build();
      for (var i = 0; i < 3; i++) {
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        );
      }
      limiter.evictExpired();
      expect(
        limiter.checkMagicLink(
          email: 'sam@example.com',
          source: RequestSource.inProcess,
        ),
        RateLimitOutcome.emailLimited,
        reason: 'eviction must not silently reset a live limit',
      );
    });
  });

  group('a degenerate source key cannot refuse anybody (task 10.52, I-1)', () {
    test('an unattributed source is never source-limited, however many', () {
      // **This is finding I-1, as a test.** Behind a proxy that names nobody,
      // every request resolves to the same value. Counting against it would
      // not be a rate limit at all — the eleventh request from ANY caller
      // would refuse, which means the first ten unauthenticated requests deny
      // sign-in to every user of the deployment for fifteen minutes.
      final limiter = build();
      for (var i = 0; i < 200; i++) {
        expect(
          limiter.checkMagicLink(
            email: 'person$i@example.com',
            source: RequestSource.unattributed,
          ),
          RateLimitOutcome.allowed,
          reason: 'request $i was refused on a key that identifies nobody',
        );
      }
    });

    test('the per-email rule still governs a degenerate source', () {
      // The fallback is to *fewer* refusals, not to none. The attack §4.4's
      // per-source rule names — a botnet bombing one colleague — is defined by
      // its victim's address, so the per-email rule bounds it unchanged.
      final limiter = build();
      for (var i = 0; i < 3; i++) {
        expect(
          limiter.checkMagicLink(
            email: 'victim@nau.edu',
            source: RequestSource.unattributed,
          ),
          RateLimitOutcome.allowed,
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'victim@nau.edu',
          source: RequestSource.unattributed,
        ),
        RateLimitOutcome.emailLimited,
        reason:
            'the per-email limit is the whole protection here and must hold',
      );
    });

    test('redemption is not source-limited on a degenerate key either', () {
      // Defence in depth over §4.2's 256 bits of token entropy, versus one
      // caller stopping every user from completing a sign-in they have already
      // been emailed. The trade is not close.
      final limiter = build();
      for (var i = 0; i < 200; i++) {
        expect(
          limiter.checkRedemption(source: RequestSource.unattributed),
          RateLimitOutcome.allowed,
        );
      }
    });

    test('a degenerate source consumes no per-source budget for anyone', () {
      // A weaker fix — count the degenerate key but forgive it — would still
      // let a flood through the proxy poison a real client's bucket. Nothing
      // may be recorded against a key that identifies nobody.
      final limiter = build();
      for (var i = 0; i < 100; i++) {
        limiter.checkMagicLink(
          email: 'flood$i@example.com',
          source: RequestSource.unattributed,
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'biologist@nau.edu',
          source: const RequestSource.forwarded('198.51.100.9'),
        ),
        RateLimitOutcome.allowed,
      );
    });
  });

  group('forwarded sources are counted separately (task 10.52)', () {
    test('two clients behind one proxy do not share a bucket', () {
      // The whole point of resolving the client address: this is the assertion
      // that was false in every real deployment through task 10.51.
      final limiter = build();
      for (var i = 0; i < 12; i++) {
        limiter.checkMagicLink(
          email: 'attacker$i@example.com',
          source: const RequestSource.forwarded('198.51.100.9'),
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'attacker99@example.com',
          source: const RequestSource.forwarded('198.51.100.9'),
        ),
        RateLimitOutcome.sourceLimited,
        reason: 'the flooding client must still be refused',
      );
      expect(
        limiter.checkMagicLink(
          email: 'biologist@nau.edu',
          source: const RequestSource.forwarded('203.0.113.77'),
        ),
        RateLimitOutcome.allowed,
        reason: 'an unrelated client behind the same proxy must be unaffected',
      );
    });

    test('a forwarded address and a direct one are not the same key', () {
      // Distinct namespaces would be a footgun the other way round, so this
      // pins the actual behaviour: the KEY is the address, whichever way it
      // was learned, because it names the same machine either way.
      final limiter = build();
      for (var i = 0; i < 12; i++) {
        limiter.checkMagicLink(
          email: 'flood$i@example.com',
          source: const RequestSource.forwarded('198.51.100.9'),
        );
      }
      expect(
        limiter.checkMagicLink(
          email: 'again@example.com',
          source: const RequestSource.direct('198.51.100.9'),
        ),
        RateLimitOutcome.sourceLimited,
      );
    });
  });
}
