import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 10.52 / Security Model §4.4 — finding I-1.
///
/// Every test here fails if the control it covers is removed, which is §4.4's
/// standing acceptance bar. The two that matter most, and would be the first
/// to rot:
///
/// - **"a header is never read from an untrusted peer"** — the property task
///   10.52 was explicitly told must survive. Deleting the allowlist check and
///   reading `X-Forwarded-For` unconditionally turns it red.
/// - **"an unattributed source cannot refuse anybody"** — the fail-safe. Making
///   the limiter treat a degenerate key as an ordinary one turns it red, and
///   that regression *is* finding I-1.
void main() {
  Request requestFrom(String peer, {Map<String, String>? headers}) =>
      Request(
        'POST',
        Uri.parse('http://localhost/auth/magic-link'),
        headers: headers,
      ).change(
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(
            InternetAddress(peer),
          ),
        },
      );

  group('TrustedProxies parsing', () {
    test('"none" and an empty value both mean no proxy at all', () {
      expect(TrustedProxies.parse('none').isEmpty, isTrue);
      expect(TrustedProxies.parse('NONE').isEmpty, isTrue);
      expect(TrustedProxies.parse('  ').isEmpty, isTrue);
      expect(TrustedProxies.none.isEmpty, isTrue);
    });

    test('single addresses match exactly and nothing else', () {
      final trusted = TrustedProxies.parse('172.31.242.10');
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
      expect(trusted.contains(InternetAddress('172.31.242.11')), isFalse);
      expect(trusted.contains(InternetAddress('172.31.242.1')), isFalse);
    });

    test('CIDR blocks match their range and stop at its edges', () {
      final trusted = TrustedProxies.parse('10.1.2.0/24');
      expect(trusted.contains(InternetAddress('10.1.2.0')), isTrue);
      expect(trusted.contains(InternetAddress('10.1.2.255')), isTrue);
      expect(trusted.contains(InternetAddress('10.1.3.0')), isFalse);
      expect(trusted.contains(InternetAddress('10.1.1.255')), isFalse);
    });

    test('a non-zero host part in a CIDR entry still matches its block', () {
      // `203.0.113.4/24` is what an operator actually types. Masking on parse
      // is what stops that from being an entry that matches nothing.
      final trusted = TrustedProxies.parse('203.0.113.4/24');
      expect(trusted.contains(InternetAddress('203.0.113.200')), isTrue);
    });

    test('a malformed prefix is refused, not silently rounded to something', () {
      expect(() => TrustedProxies.parse('10.0.0.0/'), throwsStateError);
      expect(() => TrustedProxies.parse('10.0.0.0/33'), throwsStateError);
      expect(() => TrustedProxies.parse('10.0.0.0/-1'), throwsStateError);
    });

    test('several entries, comma or whitespace separated', () {
      final trusted = TrustedProxies.parse('172.31.242.10, 10.0.0.0/8');
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
      expect(trusted.contains(InternetAddress('10.9.9.9')), isTrue);
      expect(trusted.contains(InternetAddress('192.168.1.1')), isFalse);
    });

    test('IPv6, including a CIDR block', () {
      final trusted = TrustedProxies.parse('2001:db8::/32');
      expect(trusted.contains(InternetAddress('2001:db8::1')), isTrue);
      expect(trusted.contains(InternetAddress('2001:db9::1')), isFalse);
    });

    test('a v4 entry never matches a v6 peer, or vice versa', () {
      // Comparing across families would silently widen the allowlist, and an
      // allowlist that widens by accident is not one. Exercised on the widest
      // possible range of each family (via IpRange directly — M-11 refuses
      // these two as a *declared* TRITRACK_TRUSTED_PROXIES value, see below,
      // but the family check is IpRange's own property and must hold at
      // every width).
      expect(
        IpRange.tryParse('0.0.0.0/0')!.contains(InternetAddress('::1')),
        isFalse,
      );
      expect(
        IpRange.tryParse('::/0')!.contains(InternetAddress('10.0.0.1')),
        isFalse,
      );
    });

    test('an IPv4-mapped IPv6 peer matches its v4 allowlist entry', () {
      // A dual-stack listener reports `::ffff:203.0.113.4`. Without the
      // normalisation this is an allowlist that silently fails to match, which
      // looks exactly like one nobody configured.
      expect(
        TrustedProxies.parse(
          '203.0.113.4',
        ).contains(InternetAddress('::ffff:203.0.113.4')),
        isTrue,
      );
    });

    test('a malformed entry is refused loudly, never skipped', () {
      // A typo that quietly matched nothing would reproduce I-1 on a
      // deployment that believed it had configured its way out of it.
      expect(() => TrustedProxies.parse('not-an-address'), throwsStateError);
      expect(
        () => TrustedProxies.parse('172.31.242.10, oops'),
        throwsStateError,
      );
      expect(
        () => TrustedProxies.parse('oops'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('TRITRACK_TRUSTED_PROXIES'), contains('oops')),
          ),
        ),
      );
    });
  });

  group('TrustedProxies.fromEnvironment', () {
    test('unset outside production means no proxy', () {
      expect(TrustedProxies.fromEnvironment({}).isEmpty, isTrue);
      expect(
        TrustedProxies.fromEnvironment({'TRITRACK_ENV': 'development'}).isEmpty,
        isTrue,
      );
    });

    test('unset in production REFUSES, naming the denial of service', () {
      // The structural half of the fix. Task 10.14 filed this requirement on
      // 2026-08-07; task 10.49 shipped a proxy without reading it; four gates
      // measured the collapsed control. A comment asking the next person to
      // remember would have failed the same way — so the process refuses to
      // start until the question is answered.
      expect(
        () => TrustedProxies.fromEnvironment({'TRITRACK_ENV': 'production'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('TRITRACK_TRUSTED_PROXIES'),
              contains('ONE BUCKET SHARED BY EVERY USER'),
              contains('X-Forwarded-For'),
            ),
          ),
        ),
      );
    });

    test('an explicit "none" NO LONGER satisfies production', () {
      // Task 10.62, finding J-2. `none` asserts a property of the network path
      // in front of the server — that the TCP peer is the client — and the
      // server has no way to check it. On the harness this project ships it is
      // false: Docker's publish path rewrites every caller to one gateway
      // address. An unverifiable claim that the deployment cannot make good on
      // is not an answer to the question, so the answer that says it was
      // measured is now the only one that satisfies a reachable deployment.
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': 'none',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('claim about the network path'),
              contains(trustedProxiesPeerVerified),
              contains('verify_source_identity.sh'),
            ),
          ),
        ),
      );
    });

    test('"peer-verified" satisfies production and reads no header', () {
      final trusted = TrustedProxies.fromEnvironment({
        'TRITRACK_ENV': 'production',
        'TRITRACK_TRUSTED_PROXIES': trustedProxiesPeerVerified,
      });
      expect(trusted.isEmpty, isTrue);
      // Same posture as `none` once accepted: an allowlist of nobody, so
      // `SourceIdentity` never reads X-Forwarded-For from anyone.
      expect(trusted.contains(InternetAddress('172.31.242.10')), isFalse);
    });

    test('an explicit allowlist satisfies production, once measured', () {
      final trusted = TrustedProxies.fromEnvironment({
        'TRITRACK_ENV': 'production',
        'TRITRACK_TRUSTED_PROXIES': '172.31.242.10',
        'TRITRACK_PROXY_SOURCE_IDENTITY': proxySourceIdentityProbeVerified,
      });
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
    });
  });

  // Finding M-11 (Security Model §16.3, overruled and closed by task 10.108).
  // `TRITRACK_TRUSTED_PROXIES=0.0.0.0/0` and `::/0` used to parse to a range
  // that matches every address, satisfying the allowlist check for every
  // possible caller — L-1's class with the sign flipped: L-1 was a value that
  // named zero proxies and was treated as none declared; this is a value that
  // names every address and was treated as a legitimate allowlist.
  group('a wildcard, or near-wildcard, allowlist entry is refused (M-11)', () {
    test('the literal wildcard is refused for both families', () {
      expect(
        () => TrustedProxies.parse('0.0.0.0/0'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('TRITRACK_TRUSTED_PROXIES'),
              contains('too broad'),
              contains('0.0.0.0/0'),
            ),
          ),
        ),
      );
      expect(() => TrustedProxies.parse('::/0'), throwsStateError);
    });

    test('a prefix broad enough to be equivalent is refused too', () {
      // Nothing a real proxy operator runs occupies a /1 — this is still
      // "every peer" for practical purposes.
      expect(() => TrustedProxies.parse('128.0.0.0/1'), throwsStateError);
      expect(() => TrustedProxies.parse('8000::/1'), throwsStateError);
    });

    test('a narrow entry alongside a wildcard one still refuses', () {
      // The wildcard entry must not be forgiven because another entry in the
      // same list is legitimate — a real proxy and a header read from
      // anybody is still a header read from anybody.
      expect(
        () => TrustedProxies.parse('203.0.113.4, 0.0.0.0/0'),
        throwsStateError,
      );
    });

    test('the licensed narrow shapes still start', () {
      expect(TrustedProxies.parse('203.0.113.4').isEmpty, isFalse);
      expect(TrustedProxies.parse('10.1.2.0/24').isEmpty, isFalse);
      expect(TrustedProxies.parse('2001:db8::/32').isEmpty, isFalse);
    });

    test('fromEnvironment refuses the wildcard for a reachable deployment', () {
      // The exact shape §16.3 measured live: reachable, wildcard allowlist,
      // K-2's attestation present — it used to start.
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': '0.0.0.0/0',
          'TRITRACK_PROXY_SOURCE_IDENTITY': proxySourceIdentityProbeVerified,
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('too broad'),
          ),
        ),
      );
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': '::/0',
          'TRITRACK_PROXY_SOURCE_IDENTITY': proxySourceIdentityProbeVerified,
        }),
        throwsStateError,
      );
    });
  });

  // Finding L-1. `TRITRACK_TRUSTED_PROXIES=,` is non-empty, is not `none`,
  // and TrustedProxies.parse silently skips every blank entry — so it parsed
  // to zero ranges and fromEnvironment used to treat that the same as an
  // unset variable, returning `none` without ever asking K-2's question.
  // Measured live: three malformed shapes refused and this one started the
  // server. The fix must reject a declared-but-empty allowlist as malformed,
  // not fall through to "nothing was declared."
  group('a declared allowlist that names nobody is malformed (L-1)', () {
    test('a bare comma no longer starts the server', () {
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': ',',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('TRITRACK_TRUSTED_PROXIES'),
              contains('names zero proxies'),
            ),
          ),
        ),
      );
    });

    test(
      'several separators and nothing between them are equally malformed',
      () {
        for (final bogus in [',,,', ' , , ', ',,\t,']) {
          expect(
            () => TrustedProxies.fromEnvironment({
              'TRITRACK_ENV': 'production',
              'TRITRACK_TRUSTED_PROXIES': bogus,
            }),
            throwsA(isA<StateError>()),
            reason: '"$bogus" parses to zero usable entries',
          );
        }
      },
    );

    test('the K-2 question is never reached for a degenerate allowlist', () {
      // Before the fix, `,` skipped both the K-2 refusal (§4.4.2) AND the
      // reachable-deployment refusal — it must fail even with no
      // TRITRACK_PROXY_SOURCE_IDENTITY in the environment at all, i.e. it
      // cannot be relying on that later check to catch it.
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': ',',
          'TRITRACK_PROXY_SOURCE_IDENTITY': proxySourceIdentityProbeVerified,
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('outside production, a degenerate allowlist is still malformed', () {
      // The refusal is not gated on TRITRACK_ENV=production — a reachable
      // non-production deployment (the README's LAN walkthrough) is exactly
      // the shape L-1 was measured on.
      expect(
        () => TrustedProxies.fromEnvironment({'TRITRACK_TRUSTED_PROXIES': ','}),
        throwsA(isA<StateError>()),
      );
    });

    test('a real entry alongside blank ones still requires K-2\'s answer', () {
      // ",172.31.242.10," has one real entry and two blank ones — it must
      // NOT throw as malformed (it names a real proxy), but it must still
      // demand TRITRACK_PROXY_SOURCE_IDENTITY, proving the assertion is keyed
      // on "declared" and not accidentally bypassed by the blank entries.
      expect(
        () => TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': ',172.31.242.10,',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(proxySourceIdentityVariable),
          ),
        ),
      );
    });
  });

  // Task 10.74, finding K-2. `peer-verified` made the proxy-LESS exposed
  // deployment measure its publish path before declaring it; declaring an
  // allowlist skipped the identical question one hop upstream. A proxy
  // forwards the address it sees, so a rewriting publish path in front of the
  // proxy collapses every caller into one bucket with the allowlist working
  // perfectly — which is the deployment §4.1 mandates, measured COLLAPSED by
  // the repository's own probe with its negative control passing in the run.
  group('an allowlist must say how callers reach the proxy (K-2)', () {
    Map<String, String> tlsOverlay({String? reach}) => {
      'TRITRACK_ENV': 'production',
      'TRITRACK_TLS_CERT_PATH': '/tls/origin.crt',
      'TRITRACK_TLS_KEY_PATH': '/tls/origin.key',
      'TRITRACK_PUBLISH_ADDRESS': 'none',
      'TRITRACK_TRUSTED_PROXIES': '172.31.242.10',
      if (reach != null) 'TRITRACK_PROXY_SOURCE_IDENTITY': reach,
    };

    test('undeclared, the TLS overlay REFUSES, naming the collapse', () {
      expect(
        () => TrustedProxies.fromEnvironment(tlsOverlay()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(proxySourceIdentityVariable),
              contains('ONE BUCKET SHARED BY EVERY USER'),
              contains('verify_source_identity.sh'),
              contains('proxied'),
              // The refusal has to distinguish itself from the one above it:
              // an operator who already set TRITRACK_TRUSTED_PROXIES and gets
              // a message about TRITRACK_TRUSTED_PROXIES will conclude the
              // server is broken and reach for the nearest override.
              contains('cannot see its proxy'),
            ),
          ),
        ),
      );
    });

    test('a measured `proxied: PRESERVED` run starts', () {
      final trusted = TrustedProxies.fromEnvironment(
        tlsOverlay(reach: proxySourceIdentityProbeVerified),
      );
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
    });

    test('on-network-only callers start — the drills and the control', () {
      // `verify_i1_source_identity.sh` and `verify_tls_termination.sh` are
      // exactly this shape, and it is the probe's own negative control: no
      // publish path is crossed, so identity survives by construction.
      final trusted = TrustedProxies.fromEnvironment(
        tlsOverlay(reach: proxySourceIdentityOnNetworkOnly),
      );
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
    });

    test('the value is matched, not merely present', () {
      // The failure mode of every attestation variable: something plausible
      // in `.env` that means nothing, accepted because it is non-empty.
      for (final bogus in [
        'yes',
        'true',
        '1',
        'verified',
        'none',
        'peer-verified',
      ]) {
        expect(
          () => TrustedProxies.fromEnvironment(tlsOverlay(reach: bogus)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is not one of the two answers'),
            ),
          ),
          reason: '"$bogus" asserts nothing about the publish path',
        );
      }
    });

    test('case and surrounding whitespace do not change the answer', () {
      final trusted = TrustedProxies.fromEnvironment(
        tlsOverlay(reach: '  Probe-Verified  '),
      );
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
    });

    test('the question is only asked of deployments that have a proxy', () {
      // The loopback default and `peer-verified` answered it already, by
      // construction and by measurement respectively. Demanding a second
      // variable from them would be noise, and noise is what gets defaulted.
      expect(TrustedProxies.fromEnvironment({}).isEmpty, isTrue);
      expect(
        TrustedProxies.fromEnvironment({
          'TRITRACK_ENV': 'production',
          'TRITRACK_TRUSTED_PROXIES': trustedProxiesPeerVerified,
        }).isEmpty,
        isTrue,
      );
    });

    test('a malformed allowlist is still named first', () {
      // Ordering, deliberately: a typo in the allowlist is a fact about the
      // value in front of you, and reporting the missing attestation instead
      // would send the operator to fix the wrong line.
      expect(
        () => TrustedProxies.fromEnvironment(
          tlsOverlay()..['TRITRACK_TRUSTED_PROXIES'] = 'not-an-address',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not an IP address or CIDR block'),
          ),
        ),
      );
    });
  });

  // Task 10.62, finding J-2. The trigger for the refusal above used to be
  // `TRITRACK_ENV=production` alone, and the README's LAN walkthrough is not
  // production: it sets one variable in `.env`, publishes the server to the
  // whole Wi-Fi, declares nothing, and got `none` by default. These tests are
  // the widened trigger — reachability, which the compose files now pass in
  // because a container cannot see how its host published it.
  group('DeploymentReach (§4.4.2)', () {
    test('a loopback publish address is one caller by construction', () {
      expect(
        DeploymentReach.of({'TRITRACK_PUBLISH_ADDRESS': '127.0.0.1'}),
        DeploymentReach.loopback,
      );
      expect(
        DeploymentReach.of({'TRITRACK_PUBLISH_ADDRESS': '::1'}),
        DeploymentReach.loopback,
      );
    });

    test('"none" — no host port maps here at all — is not reachable', () {
      expect(
        DeploymentReach.of({'TRITRACK_PUBLISH_ADDRESS': 'none'}),
        DeploymentReach.loopback,
      );
    });

    test('any non-loopback publish address is reachable', () {
      for (final address in ['0.0.0.0', '192.168.0.88', '::']) {
        expect(
          DeploymentReach.of({'TRITRACK_PUBLISH_ADDRESS': address}),
          DeploymentReach.beyondLoopback,
          reason: '$address publishes to something other than this machine',
        );
      }
    });

    test('an unparseable publish address fails closed', () {
      expect(
        DeploymentReach.of({'TRITRACK_PUBLISH_ADDRESS': 'lan'}),
        DeploymentReach.beyondLoopback,
      );
    });

    test('unset falls back to the §4.1 listener scope, failing closed', () {
      // Outside the compose harness nobody sets it. A server with no transport
      // configuration binds loopback (§4.1's bottom row), which settles reach
      // on its own. One that opted into cleartext-LAN or configured TLS binds
      // every interface, and then unset means "nobody can vouch for this".
      expect(DeploymentReach.of({}), DeploymentReach.loopback);
      expect(
        DeploymentReach.of({'TRITRACK_ALLOW_CLEARTEXT_LAN': '1'}),
        DeploymentReach.beyondLoopback,
      );
      expect(
        DeploymentReach.of({
          'TRITRACK_TLS_CERT_PATH': '/tls/origin.crt',
          'TRITRACK_TLS_KEY_PATH': '/tls/origin.key',
        }),
        DeploymentReach.beyondLoopback,
      );
      // Half-configured TLS is §4.1's own refusal, not this one's business.
      expect(
        DeploymentReach.of({'TRITRACK_TLS_CERT_PATH': '/tls/origin.crt'}),
        DeploymentReach.loopback,
      );
    });
  });

  group('the README LAN walkthrough refuses to start (finding J-2)', () {
    // The exact environment `docker-compose.yml` renders once an operator adds
    // `SERVER_PUBLISH_ADDRESS=0.0.0.0` to `.env` — the one line README step 4
    // used to ask for. Not production, nothing declared, and before 10.62 this
    // started and merged every caller on the Wi-Fi into one bucket.
    Map<String, String> lanWalkthrough({String? declared}) => {
      'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
      'TRITRACK_ENV': '',
      'TRITRACK_PUBLISH_ADDRESS': '0.0.0.0',
      if (declared != null) 'TRITRACK_TRUSTED_PROXIES': declared,
    };

    test('undeclared and non-production, it still refuses', () {
      expect(
        () => TrustedProxies.fromEnvironment(lanWalkthrough()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('TRITRACK_PUBLISH_ADDRESS=0.0.0.0'),
              contains('reachable from another machine'),
              contains('ONE BUCKET SHARED BY EVERY USER'),
              contains('Docker Desktop'),
            ),
          ),
        ),
      );
    });

    test('"none" does not buy its way past the refusal', () {
      expect(
        () => TrustedProxies.fromEnvironment(lanWalkthrough(declared: 'none')),
        throwsStateError,
      );
    });

    test('the loopback default it is a departure from does start', () {
      // The other half of the acceptance: the deployment that is NOT removed
      // keeps its per-source limit, and keeps it meaningfully — a loopback
      // publish address admits exactly one caller, so the single bucket IS the
      // per-source bucket rather than a collapse of several.
      final trusted = TrustedProxies.fromEnvironment({
        'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
        'TRITRACK_PUBLISH_ADDRESS': '127.0.0.1',
      });
      expect(trusted.isEmpty, isTrue);
    });

    test('the TLS overlay answers this question — and then K-2\'s', () {
      // Through task 10.62 this environment started, and finding K-2 is that
      // it should not have: it answers "which peer may speak for a client"
      // and says nothing about whether that peer's own callers arrived
      // distinguishable. The second variable is the K-2 group below.
      final overlay = {
        'TRITRACK_ENV': 'production',
        'TRITRACK_TLS_CERT_PATH': '/tls/origin.crt',
        'TRITRACK_TLS_KEY_PATH': '/tls/origin.key',
        'TRITRACK_PUBLISH_ADDRESS': 'none',
        'TRITRACK_TRUSTED_PROXIES': '172.31.242.10',
      };
      expect(() => TrustedProxies.fromEnvironment(overlay), throwsStateError);
      final trusted = TrustedProxies.fromEnvironment({
        ...overlay,
        'TRITRACK_PROXY_SOURCE_IDENTITY': proxySourceIdentityOnNetworkOnly,
      });
      expect(trusted.contains(InternetAddress('172.31.242.10')), isTrue);
    });

    test('measured and declared, an exposed proxy-less deployment starts', () {
      final trusted = TrustedProxies.fromEnvironment(
        lanWalkthrough(declared: trustedProxiesPeerVerified),
      );
      expect(trusted.isEmpty, isTrue);
    });
  });

  group('SourceIdentity with no trusted proxy (the default everywhere)', () {
    final sources = SourceIdentity();

    test('the source is the TCP peer', () {
      final source = sources.of(requestFrom('203.0.113.5'));
      expect(source.address, '203.0.113.5');
      expect(source.attribution, SourceAttribution.direct);
      expect(source.isDistinguishing, isTrue);
    });

    test('a header is never read from an untrusted peer', () {
      // **The property task 10.52 was told must survive.** A trusted-proxy
      // scheme is an allowlist of peer addresses; it is never a header read.
      final source = sources.of(
        requestFrom(
          '203.0.113.5',
          headers: {'x-forwarded-for': '198.51.100.9'},
        ),
      );
      expect(source.address, '203.0.113.5');
      expect(source.attribution, SourceAttribution.direct);
    });

    test('no socket at all is in-process, and keys nothing', () {
      final source = sources.of(
        Request('POST', Uri.parse('http://localhost/auth/magic-link')),
      );
      expect(source.attribution, SourceAttribution.inProcess);
      expect(source.isDistinguishing, isFalse);
      expect(source.auditValue, isNull);
    });
  });

  group('SourceIdentity with a declared trusted proxy', () {
    final sources = SourceIdentity(
      trustedProxies: TrustedProxies.parse('172.31.242.10'),
    );

    test('a header from the declared proxy names the client', () {
      final source = sources.of(
        requestFrom(
          '172.31.242.10',
          headers: {'x-forwarded-for': '198.51.100.9'},
        ),
      );
      expect(source.address, '198.51.100.9');
      expect(source.attribution, SourceAttribution.forwarded);
      expect(source.isDistinguishing, isTrue);
    });

    test('a header from anyone else is still ignored entirely', () {
      // The allowlist is of sockets. A caller who is not the proxy cannot make
      // their own header mean anything by sending it.
      final source = sources.of(
        requestFrom('203.0.113.5', headers: {'x-forwarded-for': '10.0.0.1'}),
      );
      expect(source.address, '203.0.113.5');
      expect(source.attribution, SourceAttribution.direct);
    });

    test('a forged chain from the client is discarded, not believed', () {
      // The client sent `1.2.3.4`; the proxy appended the real address. Reading
      // the LEFTMOST entry — the common mistake — would hand every caller a
      // free source address and defeat the limit completely.
      final source = sources.of(
        requestFrom(
          '172.31.242.10',
          headers: {'x-forwarded-for': '1.2.3.4, 198.51.100.9'},
        ),
      );
      expect(source.address, '198.51.100.9');
    });

    test('trusted hops are skipped so a two-proxy chain finds the client', () {
      final twoHops = SourceIdentity(
        trustedProxies: TrustedProxies.parse('172.31.242.10, 172.31.242.11'),
      );
      final source = twoHops.of(
        requestFrom(
          '172.31.242.10',
          headers: {'x-forwarded-for': '198.51.100.9, 172.31.242.11'},
        ),
      );
      expect(source.address, '198.51.100.9');
    });

    test('a missing header from a declared proxy is unattributed', () {
      final source = sources.of(requestFrom('172.31.242.10'));
      expect(source.attribution, SourceAttribution.unattributed);
      expect(source.isDistinguishing, isFalse);
      expect(source.address, isNull);
    });

    test('a garbage header is unattributed, not a key made of garbage', () {
      // Keying on an unparseable string would be worse than not keying at all:
      // an attacker choosing their own key chooses their own bucket.
      for (final bad in ['', '   ', 'nonsense', '1.2.3.4, nonsense', ', ,']) {
        final source = sources.of(
          requestFrom('172.31.242.10', headers: {'x-forwarded-for': bad}),
        );
        expect(
          source.attribution,
          SourceAttribution.unattributed,
          reason: 'header "$bad" must not become a rate-limit key',
        );
      }
    });

    test('a chain of nothing but trusted hops is unattributed', () {
      final source = sources.of(
        requestFrom(
          '172.31.242.10',
          headers: {'x-forwarded-for': '172.31.242.10'},
        ),
      );
      expect(source.attribution, SourceAttribution.unattributed);
    });

    test('an oversized header is not parsed at all', () {
      // Splitting an unbounded attacker-controlled string on commas, once per
      // unauthenticated request, is finding D-2's class on a different field.
      final huge = List.filled(200, '10.0.0.1').join(',');
      expect(huge.length, greaterThan(maxForwardedForLength));
      final source = sources.of(
        requestFrom('172.31.242.10', headers: {'x-forwarded-for': huge}),
      );
      expect(source.attribution, SourceAttribution.unattributed);
    });

    test('a bracketed IPv6 entry is understood', () {
      final source = sources.of(
        requestFrom(
          '172.31.242.10',
          headers: {'x-forwarded-for': '[2001:db8::5]'},
        ),
      );
      expect(source.address, '2001:db8::5');
      expect(source.attribution, SourceAttribution.forwarded);
    });

    test('a degenerate source warns, and does not warn on every request', () {
      // Loud enough that a misconfigured deployment is diagnosed; throttled so
      // an attacker cannot make the server write its own log.
      final lines = <String>[];
      var clock = DateTime.utc(2026, 8, 15, 9);
      final warning = SourceIdentity(
        trustedProxies: TrustedProxies.parse('172.31.242.10'),
        log: lines.add,
        clock: () => clock,
      );

      for (var i = 0; i < 50; i++) {
        warning.of(requestFrom('172.31.242.10'));
      }
      expect(lines, hasLength(1));
      expect(lines.single, contains('X-Forwarded-For'));
      expect(lines.single, contains('172.31.242.10'));

      clock = clock.add(SourceIdentity.degenerateWarningInterval * 2);
      warning.of(requestFrom('172.31.242.10'));
      expect(lines, hasLength(2));
    });
  });

  group('what the audit log records (§4.7)', () {
    test('a direct source records the peer', () {
      expect(
        const RequestSource.direct('203.0.113.5').auditValue,
        '203.0.113.5',
      );
    });

    test('a forwarded source records the CLIENT, never the proxy', () {
      // §11.3: 158 audit events in the gate database, one distinct
      // source_address between them. That is what recording the proxy costs.
      expect(
        const RequestSource.forwarded('198.51.100.9').auditValue,
        '198.51.100.9',
      );
    });

    test('an unattributed source admits it rather than naming the proxy', () {
      // A row that names the wrong machine is worse than a row that says it
      // does not know: the first is evidence pointing at an innocent address.
      expect(RequestSource.unattributed.auditValue, 'proxy-unattributed');
    });

    test('an in-process request records nothing', () {
      expect(RequestSource.inProcess.auditValue, isNull);
    });
  });
}

class _FakeConnectionInfo implements HttpConnectionInfo {
  const _FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 12345;

  @override
  int get localPort => 8080;
}
