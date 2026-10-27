/// Security response headers and the (absent, deliberately) CORS policy
/// (task 10.14, Security Model §4.16).
library;

import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';

/// Header name for the policy the landing page overrides — see
/// [securityHeadersMiddleware]'s note on why an existing value is preserved.
const String contentSecurityPolicyHeader = 'content-security-policy';

/// The CSP for everything that is not HTML: permit nothing at all.
///
/// The API returns JSON. There is no script, no stylesheet, no image, no
/// frame, and no form — so the honest policy is `'none'` for all of it, and
/// anything that later needs an exception has to say so explicitly rather than
/// inheriting a permissive default.
const String apiContentSecurityPolicy =
    "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; "
    "form-action 'none'";

/// Headers applied to every response, including `/health` and 404s.
///
/// Not conditional on the route, because a header policy with holes is a
/// header policy someone will find the hole in. `Strict-Transport-Security` is
/// the one exception and is added only when actually serving TLS — see
/// [securityHeadersMiddleware].
const Map<String, String> constantSecurityHeaders = {
  // The API's only content type is JSON; sniffing it as anything else is
  // never useful and is how a JSON endpoint becomes an XSS vector.
  'x-content-type-options': 'nosniff',
  // Nothing here is meant to be framed. `frame-ancestors 'none'` in the CSP
  // is the modern equivalent; this is kept for older browsers, which are
  // exactly the ones a phishing page would target.
  'x-frame-options': 'DENY',
  // §4.7 rule 4 in header form: the redemption URL's query string is a live
  // credential, so no referrer may ever leave a page that has one.
  'referrer-policy': 'no-referrer',
  'cross-origin-resource-policy': 'same-origin',
  'cross-origin-opener-policy': 'same-origin',
  // The server has no use for any of these and the diagnostics console is
  // read-only text; denying them costs nothing.
  'permissions-policy': 'geolocation=(), camera=(), microphone=()',
};

/// Response header names that would grant a browser cross-origin access.
///
/// Stripped rather than merely never-written, so "TriTrack sends no CORS
/// headers" is a property of this middleware rather than a property of every
/// handler remembering not to.
const List<String> _corsHeaders = [
  'access-control-allow-origin',
  'access-control-allow-credentials',
  'access-control-allow-methods',
  'access-control-allow-headers',
  'access-control-expose-headers',
  'access-control-max-age',
];

/// A CSP nonce for an HTML response with inline `<style>`/`<script>`.
///
/// 128 bits from the platform CSPRNG. A nonce rather than `'unsafe-inline'`
/// because `'unsafe-inline'` disables the protection for the one page that has
/// any HTML at all — and that page renders a live magic-link token, which is
/// precisely the value an injected script would want.
String cspNonce() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  return base64.encode(bytes);
}

final Random _random = Random.secure();

/// Applies [constantSecurityHeaders], the API CSP, and the no-CORS policy.
///
/// **The CORS decision, recorded in Security Model §4.16:** no origin is
/// allowed, because no browser origin needs access. The Flutter client is not
/// a browser and is unaffected by CORS entirely; the diagnostics console
/// (§4.10) is served by this same origin, so it needs nothing either. A
/// preflight is therefore refused outright rather than answered — see
/// [_preflightRefused].
///
/// [tlsEnabled] gates HSTS. Sending `Strict-Transport-Security` over cleartext
/// is meaningless (a MITM strips it) and actively harmful on the LAN dev path:
/// a browser that has pinned HSTS for `192.168.1.42:8080` will refuse the
/// plain-HTTP dev server afterwards, and the developer has no obvious way to
/// undo it. So it is sent only where it is both true and useful.
Middleware securityHeadersMiddleware({required bool tlsEnabled}) {
  final headers = <String, String>{
    ...constantSecurityHeaders,
    if (tlsEnabled)
      // Two years, includeSubDomains, no `preload` — preload is a one-way
      // submission to a browser-vendor list and is not this project's call to
      // make on behalf of whoever self-hosts.
      'strict-transport-security': 'max-age=63072000; includeSubDomains',
  };

  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') return _preflightRefused();
      final response = await innerHandler(request);
      return response.change(
        headers: <String, Object?>{
          ...headers,
          // Preserved if the handler already chose one: the magic-link landing
          // page needs a nonce-based policy for its inline style and script,
          // which is stricter than a blanket `'unsafe-inline'` would be and
          // must not be overwritten by the JSON default.
          if (!response.headers.containsKey(contentSecurityPolicyHeader))
            contentSecurityPolicyHeader: apiContentSecurityPolicy,
          // Explicitly removed, not merely never written — see [_corsHeaders].
          // shelf's `change` drops any header whose value is null.
          for (final header in _corsHeaders) header: null,
        },
      );
    };
  };
}

/// Refuses a CORS preflight.
///
/// A refusal rather than a 404 so the reason is legible in a browser console
/// and so there is something specific to assert on in a test — "no route
/// happens to handle OPTIONS" is an accident that a future router change could
/// reverse, while this is a decision.
Response _preflightRefused() => Response(
  403,
  body: jsonEncode({'error': 'cors_not_supported'}),
  headers: const {
    'content-type': 'application/json',
    contentSecurityPolicyHeader: apiContentSecurityPolicy,
    ...constantSecurityHeaders,
  },
);
