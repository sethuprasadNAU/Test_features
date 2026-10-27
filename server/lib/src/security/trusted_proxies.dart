/// Which peer addresses are allowed to speak for a client (task 10.52,
/// Security Model §4.4).
///
/// **This is an allowlist of peer addresses, never a header read.** Nothing in
/// this file consults a request header; it answers exactly one question —
/// "is the machine on the other end of this socket a proxy this deployment
/// declared?" — and `request_identity.dart` is the only caller. The ordering
/// matters and is the whole design: the socket decides whether a header is
/// even looked at, so a caller who is not the proxy cannot make their own
/// header meaningful by sending it.
library;

import 'dart:io';
import 'dart:typed_data';

/// The environment variable that declares this deployment's source-identity
/// posture. Required whenever this server is reachable by more than one
/// caller; see [TrustedProxies.fromEnvironment].
const String trustedProxiesVariable = 'TRITRACK_TRUSTED_PROXIES';

/// The address the *host* publishes this server on, passed into the container
/// by the compose files (task 10.62, Security Model §4.4.2).
///
/// The server cannot otherwise see it. Inside a container every interface is
/// the Docker bridge, so [TransportSecurityConfig.assertExposureIsPrivate]
/// records "how the host publishes the port" as a documented blind spot. That
/// blind spot is also what made finding J-2 invisible: whether a second caller
/// can reach this process at all is the question that decides whether the
/// per-source rate limit is counting anything, and it was never asked.
///
/// The value is the host-side bind address (`127.0.0.1`, `0.0.0.0`, a specific
/// LAN address), or [publishAddressUnpublished] when no host port maps here.
/// Unset means *unknown*, which is treated as reachable — see
/// [DeploymentReach.of].
const String publishAddressVariable = 'TRITRACK_PUBLISH_ADDRESS';

/// [publishAddressVariable]'s value when no host port maps to this server at
/// all — `docker-compose.tls.yml`'s `ports: !override []`, where the only way
/// in is the proxy.
const String publishAddressUnpublished = 'none';

/// The literal value that means "nothing is in front of me": the TCP peer of
/// every request *is* the client, and no forwarding header is ever read.
///
/// Spelled out rather than expressed by leaving the variable unset, because
/// unset is what a deployment that never thought about it looks like, and
/// telling those two apart is the entire point of the refusal in
/// [TrustedProxies.fromEnvironment].
///
/// **Accepted only for a deployment nobody else can reach.** `none` is a claim
/// about the network path, not about this project's configuration, and finding
/// J-2 is that claim being false on the harness this project ships: Docker
/// Desktop's port proxy rewrites every inbound connection's source address to
/// one VM-gateway address before the server sees it. Use
/// [trustedProxiesPeerVerified] to make the claim for a reachable deployment,
/// which says the same thing about headers and additionally says it was
/// measured.
const String trustedProxiesNone = 'none';

/// [trustedProxiesNone]'s meaning, asserted for a deployment other machines can
/// reach: no proxy is in front, the TCP peer is the client, **and that was
/// measured on this deployment** with
/// `scripts/verify_source_identity.sh --assisted`.
///
/// Behaves exactly like [trustedProxiesNone] once accepted. It is a separate
/// spelling rather than a second variable so that the answer to "what is the
/// source key here?" stays in one place, and so that the awkwardness of
/// writing it is proportional to what it asserts: the operator is vouching for
/// a property of the network path that the server has no way to check and that
/// is false on the shipped macOS harness.
const String trustedProxiesPeerVerified = 'peer-verified';

/// How callers reach the proxy named in [trustedProxiesVariable] (task 10.74,
/// Security Model §4.4.2 — finding K-2).
///
/// [trustedProxiesPeerVerified] closed this question for the proxy-*less*
/// exposed deployment: the operator measured that a caller's address survives
/// the host's publish path before declaring it. Declaring an allowlist skipped
/// the same question one hop upstream, and that is the whole of K-2 — the
/// proxy faithfully forwards the address *it* sees, so if the publish path in
/// front of the proxy rewrote it, `X-Forwarded-For` carries one gateway
/// address for everybody and the allowlist cannot help. The origin cannot see
/// its proxy's publish path any more than it can see its own.
///
/// So an allowlist now requires this variable too, and the two answers are the
/// two shapes that actually exist. There is no "unknown" spelling on purpose.
const String proxySourceIdentityVariable = 'TRITRACK_PROXY_SOURCE_IDENTITY';

/// `scripts/verify_source_identity.sh --assisted` was run **on this host** and
/// reported `proxied: PRESERVED` — two distinct **real off-host devices**
/// reached the origin through the proxy as two distinct addresses.
///
/// This is the only value that licenses an exposable deployment. It is the
/// operator's claim, not this repository's: no Docker Desktop host can make it
/// truthfully, and no host has been measured on this project's behalf.
///
/// `--assisted` is not optional flavour (task 10.110, Security Model §4.4.4).
/// The question needs two real network endpoints and a probe holding only
/// containers cannot manufacture one, so the probe's automatic mode returns
/// `COLLAPSED` or `NO VERDICT` and **never `PRESERVED`**. Its first version did
/// answer automatically, by having two containers dial the host's own LAN
/// address, and on Linux that measured the host's hairpin NAT rather than any
/// caller: it returned `COLLAPSED` for every Linux host it was ever run on, so
/// this constant was unreachable and no deployment could be exposed at all.
/// The probe now carries three controls — attribution, falsifiability and
/// machinery — and refuses to report anything if one fails, so the claim is
/// testable by whoever deploys rather than assumed by whoever wrote this.
const String proxySourceIdentityProbeVerified = 'probe-verified';

/// Nothing off this host reaches the proxy: every caller is already on the
/// compose network, crossing no publish path.
///
/// Identity is preserved there by construction — it is the probe's own
/// negative control, and the shape `verify_i1_source_identity.sh` drives. It
/// is a true and useful answer for the repository's drills and for a
/// single-host deployment, and it is **not** an exposable one: the moment a
/// phone on the Wi-Fi can reach the proxy, this value is false and the answer
/// is [proxySourceIdentityProbeVerified] or nothing.
const String proxySourceIdentityOnNetworkOnly = 'on-network-only';

/// Whether anything other than this host can open a connection to this server.
///
/// The discriminator for §4.4.2's refusal. A loopback-only deployment has
/// exactly one caller identity by construction, so a single rate-limit bucket
/// *is* the per-source bucket and no declaration is needed. The moment a
/// second machine can connect, the source key has to distinguish callers, and
/// whether it does is a property of the publish path rather than of anything
/// the server can inspect.
enum DeploymentReach {
  loopback,
  beyondLoopback;

  /// Resolves reach from [publishAddressVariable], failing closed when it
  /// cannot be determined.
  ///
  /// Unset is *unknown*, not *loopback*. A server started outside the compose
  /// harness with a non-loopback listener is exactly the shape whose reach
  /// nobody can vouch for, so it is treated as reachable and must declare.
  /// When the listener is loopback-scoped (§4.1: no TLS and no cleartext-LAN
  /// opt-in) the socket itself settles it and no declaration is required.
  static DeploymentReach of(Map<String, String> env) {
    final raw = (env[publishAddressVariable] ?? '').trim();
    if (raw.isNotEmpty) {
      if (raw.toLowerCase() == publishAddressUnpublished) {
        return DeploymentReach.loopback;
      }
      final address = InternetAddress.tryParse(_unbracket(raw));
      if (address == null) return DeploymentReach.beyondLoopback;
      return address.isLoopback
          ? DeploymentReach.loopback
          : DeploymentReach.beyondLoopback;
    }

    final servesTls =
        (env['TRITRACK_TLS_CERT_PATH'] ?? '').trim().isNotEmpty &&
        (env['TRITRACK_TLS_KEY_PATH'] ?? '').trim().isNotEmpty;
    final allowsCleartextLan = env['TRITRACK_ALLOW_CLEARTEXT_LAN'] == '1';
    return servesTls || allowsCleartextLan
        ? DeploymentReach.beyondLoopback
        : DeploymentReach.loopback;
  }
}

/// The narrowest prefix a declared range may cover, given its family's total
/// bit width (32 for IPv4, 128 for IPv6).
///
/// One-eighth of the bit width: `/4` for IPv4, `/16` for IPv6 — still a
/// sixteenth of the whole address family (`0.0.0.0/4` alone covers sixteen
/// `/8`s), which is the point: even the narrowest range this threshold
/// admits is far broader than any address block a real proxy operator's
/// infrastructure occupies. See [IpRange.isDangerouslyBroad] for why the
/// line is drawn well short of the literal `/0` wildcard rather than at it.
int minimumUsablePrefixBits(int maxBits) => maxBits ~/ 8;

/// One allowlist entry: a single address, or a CIDR block.
class IpRange {
  const IpRange._(this._network, this._prefixBits);

  /// Parses `203.0.113.4`, `203.0.113.0/24`, `2001:db8::1`, `2001:db8::/32`.
  ///
  /// Returns null rather than throwing so the caller can name the offending
  /// entry in one message alongside the variable it came from.
  static IpRange? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final slash = text.indexOf('/');
    final addressPart = slash < 0 ? text : text.substring(0, slash);
    final address = InternetAddress.tryParse(_unbracket(addressPart));
    if (address == null) return null;
    final bytes = _canonicalBytes(address);
    final maxBits = bytes.length * 8;

    if (slash < 0) return IpRange._(bytes, maxBits);

    final prefix = int.tryParse(text.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > maxBits) return null;
    // Masked on parse, not on match: `203.0.113.4/24` and `203.0.113.0/24`
    // must behave identically, and an unmasked network address would make a
    // sloppy-but-correct entry silently match nothing.
    return IpRange._(_mask(bytes, prefix), prefix);
  }

  final Uint8List _network;
  final int _prefixBits;

  /// Whether this range covers so much of its address family that declaring
  /// it is indistinguishable from declaring no allowlist at all (finding
  /// M-11, Security Model §16.3).
  ///
  /// `/0` is the literal wildcard; the threshold is wider than that on
  /// purpose. A `/1` still matches half the internet, and an allowlist that
  /// admits half of every possible peer protects nothing an allowlist of
  /// nobody didn't already fail to protect — the per-source rate limit and
  /// `source_address` attribution this range gates are exactly as
  /// meaningless at `/1` as at `/0`. [minimumUsablePrefixBits] draws the line
  /// well short of that: narrow enough that any address block a real
  /// reverse-proxy operator's infrastructure sits in (a single host, a
  /// `/24`, even a large cloud provider's published egress block) is
  /// unaffected, wide enough that nothing this broad is a plausible typo for
  /// a specific proxy.
  bool get isDangerouslyBroad =>
      _prefixBits < minimumUsablePrefixBits(_maxBits);

  int get _maxBits => _network.length * 8;

  bool contains(InternetAddress address) {
    final bytes = _canonicalBytes(address);
    // A v4 range never matches a v6 address and vice versa. Comparing across
    // families would be a silent widening of the allowlist, which is the one
    // mistake an allowlist may not make.
    if (bytes.length != _network.length) return false;
    final masked = _mask(bytes, _prefixBits);
    for (var i = 0; i < masked.length; i++) {
      if (masked[i] != _network[i]) return false;
    }
    return true;
  }
}

/// The declared set of peers that may speak for a client.
class TrustedProxies {
  const TrustedProxies._(this._ranges);

  /// Nothing in front: the TCP peer is the client, and no header is read.
  ///
  /// **This is the default everywhere**, including every in-process test and
  /// every server started without the variable set outside production. Through
  /// task 10.49 it was the only behaviour there was, and it is still the
  /// correct behaviour for a directly-bound server — the change in 10.52 is
  /// that a deployment can now declare the other case instead of silently
  /// suffering it.
  static const TrustedProxies none = TrustedProxies._(<IpRange>[]);

  final List<IpRange> _ranges;

  bool get isEmpty => _ranges.isEmpty;

  bool contains(InternetAddress address) =>
      _ranges.any((range) => range.contains(address));

  /// Parses a comma- or whitespace-separated list, or [trustedProxiesNone].
  ///
  /// Throws [StateError] naming the bad entry rather than skipping it. A typo
  /// in an allowlist that quietly matches nothing is the failure mode this
  /// whole task exists to close: the forwarding header would then never be
  /// read, every request would key on the proxy's own address, and the
  /// deployment would look configured while behaving exactly as it did before.
  factory TrustedProxies.parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.toLowerCase() == trustedProxiesNone) return none;

    final ranges = <IpRange>[];
    for (final entry in text.split(RegExp(r'[,\s]+'))) {
      if (entry.isEmpty) continue;
      final range = IpRange.tryParse(entry);
      if (range == null) {
        throw StateError(
          '$trustedProxiesVariable contains an entry that is not an IP '
          'address or CIDR block: "$entry". Use an address '
          '(203.0.113.4), a CIDR block (203.0.113.0/24), or the literal '
          '"$trustedProxiesNone" if no proxy sits in front of this server.',
        );
      }
      if (range.isDangerouslyBroad) {
        // Finding M-11 (Security Model §16.3): "0.0.0.0/0" and "::/0" parse
        // to a range that contains every address, so the allowlist check
        // passes for a caller who is not this deployment's proxy — the same
        // shape as L-1's empty allowlist, with the sign flipped. A value that
        // means "all peers" is not a narrower case of "these peers"; it is
        // the header read the allowlist exists to prevent, wearing an
        // allowlist's syntax.
        final minimumPrefix = minimumUsablePrefixBits(range._maxBits);
        throw StateError(
          '$trustedProxiesVariable contains an entry that is too broad to '
          'name a specific proxy: "$entry". A single entry must cover no '
          'more than a /$minimumPrefix of its address family — "$entry" '
          'matches every address a caller could possibly connect from, '
          'which reads X-Forwarded-For from any peer on the internet '
          'exactly as if no allowlist were declared at all. Use the '
          'specific address or CIDR block your proxy actually runs on, or '
          '"$trustedProxiesNone" if no proxy sits in front of this server.',
        );
      }
      ranges.add(range);
    }
    return TrustedProxies._(List.unmodifiable(ranges));
  }

  /// Reads the posture from the environment, **refusing to guess whenever a
  /// second machine can reach this server**.
  ///
  /// The refusal is the structural half of §4.4's trusted-proxy decision, and
  /// it exists because of how finding I-1 actually happened. Task 10.14 filed
  /// the requirement in 2026-08-07's Discovered Scope; task 10.49 shipped a
  /// reverse proxy on 2026-08-14 without reading it; four security gates then
  /// measured a per-source rate limit that had collapsed into one global
  /// bucket. Nothing was missing — the requirement was unread. A comment
  /// asking the next person to remember would have failed the same way, so the
  /// question is asked by the process refusing to start until it is answered.
  ///
  /// Deliberately **not** inferred from whether TLS is configured or whether
  /// `docker-compose.tls.yml` is in play: a deployment can put a proxy in
  /// front of a cleartext origin, or terminate TLS on the origin with no proxy
  /// at all, and a guess that is right most of the time produces exactly the
  /// silent wrong answer this control is about.
  ///
  /// **Task 10.62 (finding J-2) widened the trigger and narrowed the
  /// answers.** Through 10.52 the question was only asked under
  /// `TRITRACK_ENV=production`, and `$trustedProxiesNone` was always an
  /// acceptable answer to it. Both were wrong in the same way: the README's
  /// LAN walkthrough is not production, sets nothing, and reaches this branch
  /// with `none` — and on the shipped Docker harness `none` is *false*, because
  /// the port proxy rewrites every caller's address to one VM-gateway address
  /// before the server sees it. Two distinct callers, one `source_address`;
  /// twelve requests from one returned 429 to the other. So the trigger is now
  /// "can a second machine reach this?" ([DeploymentReach]) rather than "is
  /// this production?", and answering it with an unmeasured `none` is refused
  /// in favour of [trustedProxiesPeerVerified], which says the same thing and
  /// says it was measured.
  factory TrustedProxies.fromEnvironment([Map<String, String>? env]) {
    final environment = env ?? Platform.environment;
    final raw = (environment[trustedProxiesVariable] ?? '').trim();
    final lowered = raw.toLowerCase();

    if (lowered == trustedProxiesPeerVerified) return none;
    if (raw.isNotEmpty && lowered != trustedProxiesNone) {
      // An allowlist was declared the moment `raw` is non-empty and not one
      // of the two literals above — that is the fact the question below is
      // keyed on. Whether `parse` found any usable entries in it is a
      // separate question, and answering "no" by silently falling through to
      // `none` is L-1: a value like "," is non-empty, is not `none`, and
      // parses to zero ranges, so the K-2 question was never asked and this
      // factory returned as if nobody had declared anything at all.
      final allowlist = TrustedProxies.parse(raw);
      if (allowlist.isEmpty) {
        throw StateError(
          '$trustedProxiesVariable="$raw" is not empty and is not '
          '"$trustedProxiesNone", so it declares an allowlist — but every '
          'entry in it is blank (a bare comma, or only whitespace between '
          'separators), so it names zero proxies. A value that means nothing '
          'is treated the same as a value that is wrong, not the same as an '
          'unset variable.\n\n'
          'Use an address (203.0.113.4), a CIDR block (203.0.113.0/24), the '
          'literal "$trustedProxiesNone" if no proxy sits in front of this '
          'server, or unset $trustedProxiesVariable entirely.',
        );
      }
      _assertProxySourceIdentityDeclared(environment);
      return allowlist;
    }

    // Nothing is claimed to be in front, either by silence or by `none`.
    final isProduction = environment['TRITRACK_ENV'] == 'production';
    final reach = DeploymentReach.of(environment);
    if (!isProduction && reach == DeploymentReach.loopback) return none;

    final trigger = isProduction
        ? 'TRITRACK_ENV=production'
        : '$publishAddressVariable='
              '${(environment[publishAddressVariable] ?? '').trim().isEmpty ? '<unset>' : environment[publishAddressVariable]!.trim()}'
              ' — this server is reachable from another machine';
    final problem = lowered == trustedProxiesNone
        ? '$trustedProxiesVariable=$trustedProxiesNone is a claim about the '
              'network path in front of this server, and it is not a claim '
              'this server can check.'
        : '$trustedProxiesVariable is not set.';

    throw StateError(
      '$problem\n\n'
      'Trigger: $trigger.\n\n'
      'The answer decides what the per-source rate limit (Security Model '
      '§4.4) is counting. If callers do not arrive with distinguishable '
      'addresses — because an undeclared proxy is in front, or because the '
      'publish path rewrote them — the per-source limit becomes ONE BUCKET '
      'SHARED BY EVERY USER: ten unauthenticated requests from a stranger '
      'deny magic-link sign-in to the entire deployment for 15 minutes, and '
      'every audit row records a gateway instead of a person.\n\n'
      'Set one of:\n'
      '  $trustedProxiesVariable=<address|CIDR>[,...]\n'
      '      These peers are proxies this deployment operates. Only from '
      'these peers is X-Forwarded-For read, and the proxy MUST overwrite that '
      'header rather than append to it (see proxy/Caddyfile).\n'
      '  $trustedProxiesVariable=$trustedProxiesPeerVerified\n'
      '      Nothing is in front of this server, the TCP peer IS the client, '
      'and you have run scripts/verify_source_identity.sh --assisted '
      'against this deployment, from two real off-host devices, and seen it '
      'record distinct addresses for distinct callers. The probe without '
      '--assisted cannot report PRESERVED at all (Security Model 4.4.4).\n\n'
      'On Docker Desktop (macOS, Windows) the second answer is false for any '
      'caller that crosses a published host port, and the probe will say so. '
      'That deployment does not have a per-source rate limit and must not be '
      'exposed; see README.md and Security Model §4.4.2, §12.4.\n\n'
      'See server/README.md, "Source identity behind a proxy".',
    );
  }
}

/// Refuses to start an allowlist deployment that has not answered how callers
/// reach its proxy (task 10.74, finding K-2).
///
/// Deliberately the *same* control as [TrustedProxies.fromEnvironment]'s own
/// refusal rather than a warning or a README line, because the class of miss
/// is identical and documented: §4.4.2's requirement to run the probe against
/// the TLS overlay was written down, in `README.md` and in
/// `docker-compose.tls.yml`'s own comment, and the gate found the deployment
/// shipped anyway. A requirement that only exists in prose is a requirement
/// that gets read after the incident.
///
/// Not inferred from anything the container can see. Whether an off-host
/// caller can reach the *proxy* is one more fact on the far side of §4.1's
/// documented blind spot: inside a container every interface is the Docker
/// bridge, and the proxy's `ports:` belong to a different service in a file
/// this process never reads.
void _assertProxySourceIdentityDeclared(Map<String, String> env) {
  final declared = (env[proxySourceIdentityVariable] ?? '')
      .trim()
      .toLowerCase();
  if (declared == proxySourceIdentityProbeVerified ||
      declared == proxySourceIdentityOnNetworkOnly) {
    return;
  }

  final problem = declared.isEmpty
      ? '$proxySourceIdentityVariable is not set.'
      : '$proxySourceIdentityVariable="${env[proxySourceIdentityVariable]!.trim()}" '
            'is not one of the two answers this question has.';

  throw StateError(
    '$problem\n\n'
    'Trigger: $trustedProxiesVariable declares a proxy, so callers reach '
    'this server through one.\n\n'
    'An allowlist decides WHICH peer may speak for a client. It cannot '
    'decide whether the address that peer forwards still belongs to the '
    'caller. Your proxy forwards the address IT sees, and if the host '
    'publish path in front of the proxy rewrote every inbound connection to '
    'one gateway address — Docker Desktop does, always — then '
    'X-Forwarded-For carries that one address for everybody. The allowlist '
    'is then working perfectly and the per-source limit is still ONE BUCKET '
    'SHARED BY EVERY USER: ten unauthenticated requests from a stranger deny '
    'magic-link sign-in to the entire deployment for 15 minutes, and every '
    'auth_audit_log.source_address names your proxy instead of a person. '
    'This server cannot see its proxy\'s publish path, so it asks.\n\n'
    'Set one of:\n'
    '  $proxySourceIdentityVariable=$proxySourceIdentityProbeVerified\n'
    '      You ran scripts/verify_source_identity.sh --assisted ON THIS\n'
    '      HOST, from two real off-host devices, and its `proxied` shape\n'
    '      reported PRESERVED. That run is what qualifies a deployment to\n'
    '      be exposed; nothing else does. Without --assisted the probe can\n'
    '      only screen: it holds containers, and a container on this host\n'
    '      is not an off-host caller (Security Model 4.4.4).\n'
    '  $proxySourceIdentityVariable=$proxySourceIdentityOnNetworkOnly\n'
    '      Nothing outside this host can reach the proxy either — every\n'
    '      caller is on the compose network, crossing no publish path.\n'
    '      Identity is preserved there by construction. Do NOT use this for\n'
    '      a deployment a phone can reach.\n\n'
    'On Docker Desktop (macOS, Windows) the first answer is false and the '
    'probe will say so, for the proxied shape as well as the direct one — '
    'the rewrite happens at the VM boundary, before Caddy. No host has been '
    'measured on this project\'s behalf; measure yours. '
    'Security Model §4.4.2.',
  );
}

String _unbracket(String value) => value.startsWith('[') && value.endsWith(']')
    ? value.substring(1, value.length - 1)
    : value;

/// The address as bytes, with an IPv4-mapped IPv6 address (`::ffff:203.0.113.4`)
/// reduced to its four IPv4 bytes.
///
/// Without this, a dual-stack listener would report a v4 peer in v6 clothing
/// and a v4 allowlist entry would not match it — an allowlist that silently
/// fails to match is indistinguishable from one nobody configured.
Uint8List _canonicalBytes(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length == 16) {
    var mapped = true;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) mapped = false;
    }
    if (mapped && raw[10] == 0xff && raw[11] == 0xff) {
      return Uint8List.fromList(raw.sublist(12));
    }
  }
  return Uint8List.fromList(raw);
}

Uint8List _mask(Uint8List bytes, int prefixBits) {
  final out = Uint8List.fromList(bytes);
  for (var i = 0; i < out.length; i++) {
    final bitsBefore = i * 8;
    if (prefixBits >= bitsBefore + 8) continue;
    if (prefixBits <= bitsBefore) {
      out[i] = 0;
    } else {
      out[i] &= 0xff << (8 - (prefixBits - bitsBefore));
    }
  }
  return out;
}
