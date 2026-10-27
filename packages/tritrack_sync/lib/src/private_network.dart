/// §4.1's second condition, as a predicate both sides can share.
///
/// `TriTrack_Security_Model.md` §4.1 permits cleartext only when **both** hold:
/// the build is debug or profile, *and* the target host is loopback or a
/// private-range address. Security Gate C (§7.3 B3) found that only the first
/// half had ever been built — on the server *and* on the client, from the same
/// sentence. This file is the missing half, written once so the two enforcement
/// points cannot drift apart about what "private" means.
///
/// Plain Dart on purpose: no `dart:io`, so the server can hand it the raw bytes
/// of a `NetworkInterface` address and the app can hand it a parsed URL host
/// without either side importing the other's world.
library;

/// Whether [rawAddress] — 4 bytes for IPv4, 16 for IPv6, the layout
/// `InternetAddress.rawAddress` returns — is on a network that cannot be
/// routed to from the public internet.
///
/// **The list is deliberately closed.** Anything not named here is treated as
/// public, so a range nobody thought about fails toward refusing cleartext
/// rather than toward permitting it (§1.5). An unparseable length is public for
/// the same reason.
bool isPrivateNetworkAddress(List<int> rawAddress) {
  if (rawAddress.length == 4) return _isPrivateIPv4(rawAddress);
  if (rawAddress.length == 16) return _isPrivateIPv6(rawAddress);
  return false;
}

bool _isPrivateIPv4(List<int> a) {
  // 127.0.0.0/8 — loopback.
  if (a[0] == 127) return true;
  // 10.0.0.0/8 — RFC 1918.
  if (a[0] == 10) return true;
  // 172.16.0.0/12 — RFC 1918. The one people get wrong: 172.32.x is public.
  if (a[0] == 172 && a[1] >= 16 && a[1] <= 31) return true;
  // 192.168.0.0/16 — RFC 1918.
  if (a[0] == 192 && a[1] == 168) return true;
  // 169.254.0.0/16 — link-local, what a machine self-assigns with no DHCP.
  if (a[0] == 169 && a[1] == 254) return true;
  // 100.64.0.0/10 — RFC 6598 carrier-grade NAT, and the range Tailscale hands
  // out. A mesh VPN address is exactly the "reachable only by my own devices"
  // case this predicate is for, so excluding it would refuse a *safer* setup
  // than the LAN one §4.1 was written around.
  if (a[0] == 100 && a[1] >= 64 && a[1] <= 127) return true;
  return false;
}

bool _isPrivateIPv6(List<int> a) {
  // ::1 — loopback.
  if (a.take(15).every((byte) => byte == 0) && a[15] == 1) return true;
  // ::ffff:0:0/96 — an IPv4 address wearing an IPv6 coat. Dual-stack sockets
  // report LAN peers this way, so failing to unwrap it would call 192.168.1.5
  // public.
  if (a.take(10).every((byte) => byte == 0) && a[10] == 0xff && a[11] == 0xff) {
    return _isPrivateIPv4(a.sublist(12));
  }
  // fc00::/7 — unique local addresses.
  if (a[0] == 0xfc || a[0] == 0xfd) return true;
  // fe80::/10 — link-local.
  if (a[0] == 0xfe && (a[1] & 0xc0) == 0x80) return true;
  return false;
}

/// Whether [host] is a *name* (not a literal address) that can only resolve on
/// the local machine or the local network.
///
/// Names are the hard case: `dev.example.edu` may well point at `192.168.1.42`
/// today, but nothing about the string says so, and the app cannot do a DNS
/// lookup inside a synchronous form validator. So this answers the narrow
/// question it can answer honestly — is this name *definitionally* local — and
/// says no to everything else. A researcher following the README types their
/// laptop's LAN IP, which takes the literal path above, not this one.
bool isLocalNetworkHostname(String host) {
  final name = host.toLowerCase();
  if (name == 'localhost') return true;
  // RFC 6762 mDNS (`my-laptop.local`), RFC 8375 (`home.arpa`), and the
  // `localhost` special-use suffix. All three are unresolvable off-link by
  // definition rather than by convention.
  for (final suffix in const ['.local', '.localhost', '.home.arpa']) {
    if (name.endsWith(suffix)) return true;
  }
  return false;
}
