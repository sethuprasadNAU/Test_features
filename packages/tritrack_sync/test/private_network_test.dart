import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// §4.1's second condition, tested at the boundaries rather than at the middle
/// of each range — `172.16.0.0/12` is the one everybody writes as `172.x`, and
/// a test that only checks `172.17.0.1` would never notice.
void main() {
  List<int> v4(String dotted) =>
      dotted.split('.').map(int.parse).toList(growable: false);

  List<int> v6(List<int> leading) => [
    ...leading,
    ...List.filled(16 - leading.length, 0),
  ];

  group('IPv4', () {
    test('accepts every RFC 1918 range', () {
      for (final address in const [
        '10.0.0.0',
        '10.255.255.255',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '192.168.255.255',
      ]) {
        expect(
          isPrivateNetworkAddress(v4(address)),
          isTrue,
          reason: '$address is RFC 1918',
        );
      }
    });

    test('rejects the addresses just outside 172.16.0.0/12', () {
      // The off-by-one that makes this whole predicate worth writing down:
      // 172.15.x and 172.32.x are ordinary public internet.
      expect(isPrivateNetworkAddress(v4('172.15.255.255')), isFalse);
      expect(isPrivateNetworkAddress(v4('172.32.0.0')), isFalse);
    });

    test('accepts loopback, link-local, and CGNAT/mesh-VPN ranges', () {
      expect(isPrivateNetworkAddress(v4('127.0.0.1')), isTrue);
      expect(isPrivateNetworkAddress(v4('169.254.10.1')), isTrue);
      expect(isPrivateNetworkAddress(v4('100.64.0.1')), isTrue);
      expect(isPrivateNetworkAddress(v4('100.127.255.255')), isTrue);
      expect(isPrivateNetworkAddress(v4('100.128.0.0')), isFalse);
      expect(isPrivateNetworkAddress(v4('100.63.255.255')), isFalse);
    });

    test('rejects real public addresses', () {
      for (final address in const [
        '8.8.8.8',
        '1.1.1.1',
        '134.114.1.1', // NAU's range — the deployment this model is written for
        '0.0.0.0', // a bind wildcard, never a private *target*
      ]) {
        expect(
          isPrivateNetworkAddress(v4(address)),
          isFalse,
          reason: '$address must not be treated as private',
        );
      }
    });
  });

  group('IPv6', () {
    test('accepts loopback, ULA, and link-local', () {
      expect(isPrivateNetworkAddress(v6([0, 0, 0, 0, 0, 0, 0, 0])..[15] = 1),
          isTrue);
      expect(isPrivateNetworkAddress(v6([0xfd, 0x00])), isTrue);
      expect(isPrivateNetworkAddress(v6([0xfc, 0x00])), isTrue);
      expect(isPrivateNetworkAddress(v6([0xfe, 0x80])), isTrue);
      expect(isPrivateNetworkAddress(v6([0xfe, 0xbf])), isTrue);
    });

    test('rejects global unicast', () {
      // 2000::/3 is the routable internet; fe00:: is outside fe80::/10.
      expect(isPrivateNetworkAddress(v6([0x20, 0x01, 0x0d, 0xb8])), isFalse);
      expect(isPrivateNetworkAddress(v6([0xfe, 0x00])), isFalse);
      expect(isPrivateNetworkAddress(v6([0xfe, 0xc0])), isFalse);
    });

    test('unwraps IPv4-mapped addresses instead of calling them public', () {
      // A dual-stack listening socket reports LAN peers as ::ffff:192.168.x.x.
      // Reading those 16 bytes as "not a recognised IPv6 private range" would
      // refuse the exact deployment §4.1 permits.
      final mapped = [
        ...List.filled(10, 0),
        0xff,
        0xff,
        ...v4('192.168.1.42'),
      ];
      expect(isPrivateNetworkAddress(mapped), isTrue);

      final mappedPublic = [
        ...List.filled(10, 0),
        0xff,
        0xff,
        ...v4('8.8.8.8'),
      ];
      expect(isPrivateNetworkAddress(mappedPublic), isFalse);
    });
  });

  test('an address of an unexpected length is public, not private', () {
    // Fail closed (§1.5): something we cannot parse must not be waved through
    // as "probably local".
    expect(isPrivateNetworkAddress(const []), isFalse);
    expect(isPrivateNetworkAddress(const [192, 168, 1]), isFalse);
  });

  group('hostnames', () {
    test('accepts only definitionally local names', () {
      for (final host in const [
        'localhost',
        'LOCALHOST',
        'my-laptop.local',
        'server.home.arpa',
        'dev.localhost',
      ]) {
        expect(isLocalNetworkHostname(host), isTrue, reason: host);
      }
    });

    test('rejects names that merely sound internal', () {
      // The generous reading — "it has `internal` in it, must be fine" — is
      // how a predicate like this stops meaning anything. A name that only
      // resolves privately today is still a name that can resolve anywhere
      // tomorrow, and a form validator cannot check.
      for (final host in const [
        'tracker.example.edu',
        'localhost.attacker.com',
        'internal',
        'intranet.example.com',
        'nau.edu',
      ]) {
        expect(isLocalNetworkHostname(host), isFalse, reason: host);
      }
    });
  });
}
