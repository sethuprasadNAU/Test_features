import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// §4.1's decision table, as tests. **Each case fails if the corresponding
/// branch of [TransportSecurityConfig.fromEnvironment] is removed** — which is
/// the point: §4.1 says in as many words that "a control with no failing-path
/// test is decoration."
///
/// No Postgres and no socket: this is a pure decision about what to bind, so it
/// is tested as one.
void main() {
  group('default posture', () {
    test('no configuration at all binds loopback only', () {
      // The load-bearing default. Through task 10.13 the server bound
      // `anyIPv4` unconditionally, so a deployment that configured nothing
      // published session tokens and coordinates to whatever network it landed
      // on. Failing closed (§1.5) means unreachable, not unencrypted.
      final config = TransportSecurityConfig.fromEnvironment(const {});
      expect(config.scope, BindScope.loopback);
      expect(config.address, InternetAddress.loopbackIPv4);
      expect(config.tlsEnabled, isFalse);
      expect(config.isCleartextBeyondLoopback, isFalse);
    });

    test('a production environment with no transport config is still loopback',
        () {
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_ENV': 'production',
      });
      expect(config.scope, BindScope.loopback);
    });
  });

  group('cleartext LAN opt-in', () {
    test('binds all interfaces and reports itself as cleartext', () {
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
      });
      expect(config.scope, BindScope.allInterfaces);
      expect(config.address, InternetAddress.anyIPv4);
      expect(config.tlsEnabled, isFalse);
      expect(config.isCleartextBeyondLoopback, isTrue);
    });

    test('carries a startup warning naming what is exposed', () {
      // §4.1 requires the flag "logs a prominent warning on every startup".
      // Asserting on the content, not just its existence: a warning that does
      // not say tokens and coordinates are readable is not the warning §4.1
      // asked for.
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
      });
      expect(config.startupWarning.toLowerCase(), contains('cleartext'));
      expect(config.startupWarning.toLowerCase(), contains('token'));
      expect(config.startupWarning, contains('§4.1'));
    });

    test('is REFUSED outright when TRITRACK_ENV=production', () {
      // The control this whole task's TLS bullet exists for: the dev exemption
      // must be structurally unable to ship. Not a warning, not a downgrade to
      // loopback — a refusal to start.
      expect(
        () => TransportSecurityConfig.fromEnvironment(const {
          'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
          'TRITRACK_ENV': 'production',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('production'), contains('§4.1')),
          ),
        ),
      );
    });

    test('the production refusal survives case and whitespace in TRITRACK_ENV', () {
      // Security Model §16.3's M-11 sweep: this refusal used to compare
      // TRITRACK_ENV with `==` exactly, so "Production" or "production "
      // silently took the *less* safe branch instead of refusing — exactly
      // the operator typo the refusal exists to catch.
      for (final value in ['Production', 'PRODUCTION', ' production', 'production ']) {
        expect(
          () => TransportSecurityConfig.fromEnvironment({
            'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
            'TRITRACK_ENV': value,
          }),
          throwsStateError,
          reason: 'TRITRACK_ENV="$value" must still be recognised as production',
        );
      }
    });

    test('any value other than exactly 1 does not enable it', () {
      // A flag that accepts "true", "yes", "0", "false" as truthy is a flag
      // somebody enables by accident.
      for (final value in ['true', 'yes', '0', 'false', '', 'TRUE']) {
        final config = TransportSecurityConfig.fromEnvironment({
          'TRITRACK_ALLOW_CLEARTEXT_LAN': value,
        });
        expect(
          config.scope,
          BindScope.loopback,
          reason: 'value "$value" must not enable cleartext LAN',
        );
      }
    });
  });

  group('the private-range condition (task 10.22, Gate C finding C-3)', () {
    // §4.1 permits cleartext only when the build is a development one *and*
    // the target is loopback or a private range. Through 10.14 only the first
    // half existed, so these are the tests that did not exist for the half
    // that did not either.
    Future<List<NetworkInterface>> Function() interfaces(
      Map<String, List<String>> byName,
    ) => () async => [
      for (final entry in byName.entries)
        _FakeInterface(
          entry.key,
          entry.value.map(InternetAddress.new).toList(),
        ),
    ];

    test('cleartext on a machine with only private addresses is allowed', () {
      // The case the flag exists for: a laptop on Wi-Fi, serving a phone.
      expect(
        TransportSecurityConfig.resolve(
          env: const {'TRITRACK_ALLOW_CLEARTEXT_LAN': '1'},
          listInterfaces: interfaces({
            'en0': ['192.168.1.42'],
            'utun3': ['fd00::1'],
          }),
        ),
        completion(
          isA<TransportSecurityConfig>().having(
            (c) => c.scope,
            'scope',
            BindScope.allInterfaces,
          ),
        ),
      );
    });

    test('cleartext on a machine with a public address is REFUSED', () {
      // The reproduction from §7.3 B3: `TRITRACK_ALLOW_CLEARTEXT_LAN=1` with
      // `TRITRACK_ENV=development` on a public host warned and then served.
      // A refusal, not a warning — the operator who set this flag for their
      // phone is the operator who later runs the same configuration on a VPS.
      expect(
        TransportSecurityConfig.resolve(
          env: const {'TRITRACK_ALLOW_CLEARTEXT_LAN': '1'},
          listInterfaces: interfaces({
            'eth0': ['134.114.1.10'],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('134.114.1.10'),
              contains('eth0'),
              contains('§4.1'),
            ),
          ),
        ),
      );
    });

    test('one public address among private ones is enough to refuse', () {
      // A dual-homed box — private LAN interface plus a public one — is the
      // shape that makes "well, it looked like a LAN server" plausible.
      expect(
        TransportSecurityConfig.resolve(
          env: const {'TRITRACK_ALLOW_CLEARTEXT_LAN': '1'},
          listInterfaces: interfaces({
            'en0': ['192.168.1.42'],
            'eth1': ['203.0.113.7'],
          }),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('TLS on a public address is fine — it is cleartext that is refused',
        () {
      expect(
        TransportSecurityConfig.resolve(
          env: const {
            'TRITRACK_TLS_CERT_PATH': '/tls/fullchain.pem',
            'TRITRACK_TLS_KEY_PATH': '/tls/privkey.pem',
          },
          listInterfaces: interfaces({
            'eth0': ['134.114.1.10'],
          }),
        ),
        completion(
          isA<TransportSecurityConfig>().having(
            (c) => c.tlsEnabled,
            'tlsEnabled',
            isTrue,
          ),
        ),
      );
    });

    test('the loopback default is unaffected by a public interface', () {
      // Nothing is served off-host, so the machine's own addresses are not
      // this check's business — and a check that fired here would make the
      // safe default the one that refuses to start.
      expect(
        TransportSecurityConfig.resolve(
          env: const {},
          listInterfaces: interfaces({
            'eth0': ['134.114.1.10'],
          }),
        ),
        completion(
          isA<TransportSecurityConfig>().having(
            (c) => c.scope,
            'scope',
            BindScope.loopback,
          ),
        ),
      );
    });

    test('the refusal names both ways out of it', () async {
      // 10.25's standard: "a correct refusal nobody can see is a support
      // call." Someone reading this at 11pm in the field needs to know what to
      // do, not only that they may not do this.
      try {
        await TransportSecurityConfig.resolve(
          env: const {'TRITRACK_ALLOW_CLEARTEXT_LAN': '1'},
          listInterfaces: interfaces({
            'eth0': ['134.114.1.10'],
          }),
        );
        fail('should have refused');
      } on StateError catch (error) {
        expect(error.message, contains('TRITRACK_TLS_CERT_PATH'));
        expect(error.message, contains('SSH tunnel'));
      }
    });

    test('real host interfaces are consulted when none are injected', () async {
      // The seam has a default, and the default is the one production uses.
      // Whatever this developer machine's addresses are, resolving with the
      // loopback default must not throw and must not hang.
      final config = await TransportSecurityConfig.resolve(env: const {});
      expect(config.scope, BindScope.loopback);
    });
  });

  group('TLS', () {
    test('both paths configured binds all interfaces with TLS', () {
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_TLS_CERT_PATH': '/tls/fullchain.pem',
        'TRITRACK_TLS_KEY_PATH': '/tls/privkey.pem',
      });
      expect(config.tlsEnabled, isTrue);
      expect(config.scope, BindScope.allInterfaces);
      expect(config.isCleartextBeyondLoopback, isFalse);
    });

    test('TLS is permitted in production, unlike cleartext', () {
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_TLS_CERT_PATH': '/tls/fullchain.pem',
        'TRITRACK_TLS_KEY_PATH': '/tls/privkey.pem',
        'TRITRACK_ENV': 'production',
      });
      expect(config.tlsEnabled, isTrue);
      expect(config.scope, BindScope.allInterfaces);
    });

    test('half-configured TLS refuses to start rather than serving cleartext',
        () {
      // The silent-downgrade trap: an operator who set up a certificate and
      // fat-fingered one variable name would otherwise fall through to the
      // loopback branch and spend an afternoon wondering why nothing connects
      // — or worse, add the cleartext flag to "fix" it.
      for (final env in [
        const {'TRITRACK_TLS_CERT_PATH': '/tls/fullchain.pem'},
        const {'TRITRACK_TLS_KEY_PATH': '/tls/privkey.pem'},
      ]) {
        expect(
          () => TransportSecurityConfig.fromEnvironment(env),
          throwsA(isA<StateError>()),
          reason: 'half-configured TLS must not silently serve cleartext',
        );
      }
    });

    test('an empty TLS path counts as unset, not as half-configured', () {
      // `docker-compose.yml` passes these through with empty defaults, so an
      // empty string must mean "not configured" rather than tripping the
      // half-configured refusal on every ordinary dev startup.
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_TLS_CERT_PATH': '',
        'TRITRACK_TLS_KEY_PATH': '',
        'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
      });
      expect(config.tlsEnabled, isFalse);
      expect(config.scope, BindScope.allInterfaces);
    });

    test('TLS wins over the cleartext flag rather than conflicting with it', () {
      // Both set is not a contradiction — it is a deployment mid-migration
      // that has not cleaned up its old flag. Serving TLS is the safe reading.
      final config = TransportSecurityConfig.fromEnvironment(const {
        'TRITRACK_TLS_CERT_PATH': '/tls/fullchain.pem',
        'TRITRACK_TLS_KEY_PATH': '/tls/privkey.pem',
        'TRITRACK_ALLOW_CLEARTEXT_LAN': '1',
        'TRITRACK_ENV': 'production',
      });
      expect(config.tlsEnabled, isTrue);
      expect(config.isCleartextBeyondLoopback, isFalse);
    });
  });
}

/// A [NetworkInterface] with addresses chosen by the test rather than by
/// whatever network this machine happens to be on. The check under test is a
/// judgement about addresses; making it depend on the developer's Wi-Fi would
/// make it untestable and, worse, intermittently green.
class _FakeInterface implements NetworkInterface {
  _FakeInterface(this.name, List<InternetAddress> addresses)
    : addresses = [for (final a in addresses) _FakeInterfaceAddress(a)];

  @override
  final String name;

  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 0;
}

/// An [InterfaceAddress] that is the given [InternetAddress] and nothing more.
/// Dart 3.13 made `NetworkInterface.addresses` a `List<InterfaceAddress>`
/// (an address plus its prefix length and broadcast); the check under test
/// reads only the [InternetAddress] half, so everything else is a default.
class _FakeInterfaceAddress implements InterfaceAddress {
  _FakeInterfaceAddress(this._address);

  final InternetAddress _address;

  @override
  String get address => _address.address;

  @override
  String get host => _address.host;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isMulticast => _address.isMulticast;

  @override
  Uint8List get rawAddress => _address.rawAddress;

  @override
  Future<InternetAddress> reverse() => _address.reverse();

  @override
  InternetAddressType get type => _address.type;

  @override
  InternetAddress? get broadcast => null;

  @override
  int get prefixLength => 0;
}
