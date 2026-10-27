/// Per-request identity: a correlation id, and the caller's real peer address
/// (task 10.14).
library;

import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';

import 'trusted_proxies.dart';

/// Context key under which [traceIdMiddleware] stashes the correlation id.
const String traceIdContextKey = 'tritrack.trace_id';

/// The correlation id for [request], or null if the middleware did not run.
///
/// Included in every error response (§4.13 requires a request id so a support
/// conversation is possible *without* the response carrying internal detail)
/// and in every audit-log row, so "the app showed me an error at 14:02" can be
/// matched to a server-side record without the error itself having said
/// anything.
String? traceIdOf(Request request) =>
    request.context[traceIdContextKey] as String?;

/// The caller's actual TCP peer address, or null when there is no real socket
/// (an in-process request built by a test).
///
/// **Reads the real connection, never a header, and never will.** This is the
/// authorization-grade answer to "who is on the other end of this socket", and
/// it is the only thing [SourceIdentity] is allowed to make its trust decision
/// from. The diagnostics console's loopback gate (§4.10,
/// `diagnostics_routes.dart`) reads the same connection info directly and
/// deliberately does **not** go through [SourceIdentity]: a console gate that
/// honoured a forwarding header would let anyone who can reach the proxy claim
/// `127.0.0.1`. Behind Caddy the console therefore fails closed, which is the
/// verified behaviour §11.3 recorded and task 10.52 was told not to "fix".
InternetAddress? peerInternetAddressOf(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is HttpConnectionInfo) return info.remoteAddress;
  return null;
}

// There is deliberately no `String? peerAddressOf(request)` any more (task
// 10.52). It existed to produce a rate-limit key and an audit value directly
// from the socket, which is the behaviour finding I-1 was: behind a proxy it
// returns the proxy for every caller. Both of those now come from
// [SourceIdentity], and leaving the old accessor in place would leave the next
// person a one-line way to reintroduce the bug that looks entirely reasonable.
// [peerInternetAddressOf] above is what remains, for the gate that genuinely
// wants the socket and nothing else.

/// How much a resolved source address is worth as an identifier.
enum SourceAttribution {
  /// The TCP peer is the client. No proxy was declared for this peer, so no
  /// header was consulted.
  direct,

  /// The TCP peer is a declared trusted proxy, and it named the client.
  forwarded,

  /// The TCP peer is a declared trusted proxy that did **not** usably name the
  /// client — no forwarding header, an unparseable one, or a chain made
  /// entirely of trusted hops.
  ///
  /// **A degenerate key**: every caller reaching this server through that
  /// proxy resolves to the same value, so anything keyed on it is keyed on
  /// "everybody". See [RequestSource.isDistinguishing].
  unattributed,

  /// No socket at all — a request constructed in-process by a test. The only
  /// way to produce one is to already be running inside this process.
  inProcess,
}

/// The source of one request, and how much that answer is worth.
class RequestSource {
  const RequestSource._(this.address, this.attribution);

  /// The TCP peer, used directly.
  const RequestSource.direct(String address)
    : this._(address, SourceAttribution.direct);

  /// A client named by a trusted proxy.
  const RequestSource.forwarded(String address)
    : this._(address, SourceAttribution.forwarded);

  /// A trusted proxy that named nobody.
  static const RequestSource unattributed = RequestSource._(
    null,
    SourceAttribution.unattributed,
  );

  /// No socket — an in-process test request.
  static const RequestSource inProcess = RequestSource._(
    null,
    SourceAttribution.inProcess,
  );

  /// The client address, or null when there isn't one.
  final String? address;

  final SourceAttribution attribution;

  /// Whether this value can tell two callers apart.
  ///
  /// **The predicate every per-source control must consult before refusing
  /// anything** (§4.4, task 10.52). A key that cannot distinguish callers
  /// cannot refuse one of them — it can only refuse all of them, which turns a
  /// rate limit into a denial-of-service lever anyone may pull. See
  /// `RateLimiter.checkMagicLink`.
  bool get isDistinguishing =>
      address != null &&
      (attribution == SourceAttribution.direct ||
          attribution == SourceAttribution.forwarded);

  /// What §4.7's `source_address` column records.
  ///
  /// An honest marker rather than the proxy's own address for the degenerate
  /// case: writing the proxy's address there is what produced 158 audit rows
  /// with one distinct source between them (§11.3), and a row that names the
  /// wrong machine is worse than a row that admits it does not know.
  String? get auditValue => switch (attribution) {
    SourceAttribution.direct || SourceAttribution.forwarded => address,
    SourceAttribution.unattributed => 'proxy-unattributed',
    SourceAttribution.inProcess => null,
  };
}

/// The forwarding header, read **only** from a declared trusted proxy.
const String forwardedForHeader = 'x-forwarded-for';

/// Longest `X-Forwarded-For` this will parse at all.
///
/// The header is attacker-controlled on an unauthenticated route, and splitting
/// an unbounded string on commas is an unbounded allocation per request —
/// finding D-2's class (task 10.30) on a different field. A real chain is a
/// handful of addresses; anything past this is not a chain, and is treated as
/// [SourceAttribution.unattributed] rather than parsed.
const int maxForwardedForLength = 512;

/// Resolves the source of each request, given this deployment's declared
/// proxy posture.
///
/// **The trust order is the design** (§4.4, task 10.52): the socket decides
/// whether a header is read, so a caller who is not the proxy cannot make
/// their own header mean anything. [TrustedProxies.none] — the default
/// everywhere — never reads a header at all, which is byte-for-byte the
/// behaviour that shipped through task 10.51.
///
/// **This is for rate-limit keying and audit attribution only. It is never an
/// authorization input**, and no caller may make it one: a forwarded address is
/// a claim by a machine we trust *to report*, not proof of anything about the
/// client. Authorization reads [peerInternetAddressOf].
class SourceIdentity {
  SourceIdentity({
    this.trustedProxies = TrustedProxies.none,
    void Function(String)? log,
    DateTime Function()? clock,
    // prefer_initializing_formals misfires here: a named parameter cannot be
    // written `this._log`, because named parameters may not start with an
    // underscore.
    // ignore: prefer_initializing_formals
  }) : _log = log,
       _clock = clock ?? DateTime.now;

  final TrustedProxies trustedProxies;
  final void Function(String)? _log;
  final DateTime Function() _clock;

  DateTime? _lastDegenerateWarning;

  /// How often the degenerate-source warning is repeated. Frequent enough that
  /// a misconfigured deployment is not diagnosed once and then forgotten,
  /// rare enough that an attacker cannot make the server write its own log.
  static const Duration degenerateWarningInterval = Duration(minutes: 15);

  RequestSource of(Request request) {
    final peer = peerInternetAddressOf(request);
    if (peer == null) return RequestSource.inProcess;
    if (trustedProxies.isEmpty || !trustedProxies.contains(peer)) {
      return RequestSource.direct(peer.address);
    }
    final forwarded = _forwardedClient(request);
    if (forwarded == null) {
      _warnDegenerate(peer);
      return RequestSource.unattributed;
    }
    return RequestSource.forwarded(forwarded);
  }

  /// The client named by a trusted proxy, or null if it named nobody usable.
  ///
  /// Walks the chain **right to left**, because each hop appends and the
  /// rightmost entry is therefore the one written by the hop closest to us —
  /// everything to its left was supplied by whoever spoke to that hop, which
  /// includes the caller. Trusted hops are skipped so a two-proxy deployment
  /// resolves to the real client rather than to its own inner proxy.
  ///
  /// A chain that is entirely trusted hops, or whose first untrusted entry is
  /// not an address at all, yields null. It does **not** keep walking left past
  /// something unparseable: garbage where an address should be means the chain
  /// is not the shape this deployment declared, and guessing further left would
  /// be reading an attacker's value.
  ///
  /// Note that the shipped `proxy/Caddyfile` *overwrites* this header rather
  /// than appending to it, so in that deployment the chain is always exactly
  /// one entry and none of the above is reachable. The walk exists because the
  /// allowlist can name a proxy this repository did not configure.
  String? _forwardedClient(Request request) {
    final raw = request.headers[forwardedForHeader];
    if (raw == null || raw.isEmpty || raw.length > maxForwardedForLength) {
      return null;
    }
    final hops = raw.split(',');
    for (var i = hops.length - 1; i >= 0; i--) {
      final token = hops[i].trim();
      if (token.isEmpty) return null;
      final address = InternetAddress.tryParse(
        token.startsWith('[') && token.endsWith(']')
            ? token.substring(1, token.length - 1)
            : token,
      );
      if (address == null) return null;
      if (trustedProxies.contains(address)) continue;
      return address.address;
    }
    return null;
  }

  void _warnDegenerate(InternetAddress peer) {
    final log = _log;
    if (log == null) return;
    final now = _clock();
    final last = _lastDegenerateWarning;
    if (last != null && now.difference(last) < degenerateWarningInterval) {
      return;
    }
    _lastDegenerateWarning = now;
    log(
      '!!! ${peer.address} is a declared trusted proxy '
      '($trustedProxiesVariable) but sent no usable X-Forwarded-For. Every '
      'request through it is indistinguishable, so the per-source rate limits '
      '(Security Model §4.4) are NOT being applied to those requests — '
      'applying them would refuse every user at once rather than one caller. '
      'Configure the proxy to set X-Forwarded-For to the client address (see '
      'proxy/Caddyfile), or set $trustedProxiesVariable=$trustedProxiesNone '
      'if that peer is not actually a proxy.',
    );
  }
}

/// Assigns a correlation id to every request and echoes it as `x-request-id`.
///
/// Generated from `Random.secure()` rather than a counter: a sequential id
/// would let a caller infer total request volume across all users from two
/// responses, which is minor but free to avoid.
Middleware traceIdMiddleware({String Function()? newId}) {
  final generate = newId ?? _randomTraceId;
  return (Handler innerHandler) {
    return (Request request) async {
      final id = traceIdOf(request) ?? generate();
      final response = await innerHandler(
        request.change(context: {traceIdContextKey: id}),
      );
      return response.change(headers: {'x-trace-id': id});
    };
  };
}

final Random _random = Random.secure();

String _randomTraceId() {
  const hex = '0123456789abcdef';
  return String.fromCharCodes([
    for (var i = 0; i < 16; i++) hex.codeUnitAt(_random.nextInt(16)),
  ]);
}
