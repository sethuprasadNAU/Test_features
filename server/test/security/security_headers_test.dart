import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Security headers and the no-CORS policy (§4.16, authored by task 10.14 —
/// the security model had no recorded decision for this control).
///
/// Asserted through `createHandler` rather than against the middleware in
/// isolation, because the property that matters is "every response, including
/// `/health` and a 404, carries these" — and that is a property of where the
/// middleware is *mounted*, which a middleware-only test would not catch.
void main() {
  Future<Response> get(String path, {Handler? handler}) async =>
      (handler ?? createHandler())(
        Request('GET', Uri.parse('http://localhost$path')),
      );

  group('applied everywhere', () {
    // /health is the only unauthenticated informative route; a 404 is the
    // response an opportunistic scanner will see most of (§2.2).
    for (final path in ['/health', '/nope', '/auth/magic-link']) {
      test('$path carries every constant security header', () async {
        final response = await get(path);
        for (final entry in constantSecurityHeaders.entries) {
          expect(
            response.headers[entry.key],
            entry.value,
            reason: '$path is missing ${entry.key}',
          );
        }
      });

      test('$path carries the restrictive CSP', () async {
        final response = await get(path);
        expect(
          response.headers[contentSecurityPolicyHeader],
          apiContentSecurityPolicy,
        );
      });
    }

    test('a 500 from a failing route still carries the headers', () async {
      // Headers are the outermost middleware precisely so the error handler's
      // own response is covered — a 500 without `nosniff` is still a response a
      // browser can be talked into misinterpreting.
      final handler = createHandler(
        withAuthService: <T>(action) => throw StateError('boom'),
        logLine: (_) {},
      );
      // `/auth/link-status` rather than `/auth/magic-link`: the latter
      // deliberately swallows exceptions for anti-enumeration reasons (§4.5)
      // and so never reaches the 500 path.
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/auth/link-status/req-1')),
      );
      expect(response.statusCode, 500);
      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(
        response.headers[contentSecurityPolicyHeader],
        apiContentSecurityPolicy,
      );
    });
  });

  group('CORS is absent, not permissive', () {
    test('no Access-Control-Allow-Origin on any response', () async {
      for (final path in ['/health', '/nope']) {
        final response = await get(path);
        expect(
          response.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('access-control-allow-origin')),
          reason: 'no browser origin needs access to $path',
        );
      }
    });

    test('an Origin header does not earn a CORS response', () async {
      // The failure mode a permissive default would produce: reflecting
      // whatever origin asked.
      final response = await createHandler()(
        Request(
          'GET',
          Uri.parse('http://localhost/health'),
          headers: {'origin': 'https://evil.example'},
        ),
      );
      expect(
        response.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('access-control-allow-origin')),
      );
      expect(await response.readAsString(), isNot(contains('evil.example')));
    });

    test('a preflight is refused explicitly rather than 404ing by accident',
        () async {
      // A decision, not an accident: "no route happens to handle OPTIONS" is
      // something a future router change could silently reverse.
      final response = await createHandler()(
        Request(
          'OPTIONS',
          Uri.parse('http://localhost/sync/push'),
          headers: {
            'origin': 'https://evil.example',
            'access-control-request-method': 'POST',
          },
        ),
      );
      expect(response.statusCode, 403);
      expect(
        response.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('access-control-allow-origin')),
      );
    });

    test('a handler that emits a CORS header has it stripped', () async {
      // The reason the middleware removes these rather than merely never
      // writing them: "TriTrack sends no CORS headers" should be a property of
      // one place, not of every handler remembering.
      final stripped = securityHeadersMiddleware(tlsEnabled: false)(
        (_) async => Response.ok(
          '{}',
          headers: const {
            'access-control-allow-origin': '*',
            'access-control-allow-credentials': 'true',
          },
        ),
      );
      final response = await stripped(
        Request('GET', Uri.parse('http://localhost/anything')),
      );
      final names = response.headers.keys.map((k) => k.toLowerCase());
      expect(names, isNot(contains('access-control-allow-origin')));
      expect(names, isNot(contains('access-control-allow-credentials')));
    });
  });

  group('HSTS is conditional on actually serving TLS', () {
    test('absent over cleartext', () async {
      // Sending HSTS over plain HTTP is meaningless (a MITM strips it) and
      // actively harmful on the LAN dev path: a browser that pins HSTS for
      // 192.168.1.42:8080 will then refuse the plain-HTTP dev server, with no
      // obvious way for the developer to undo it.
      final response = await get('/health');
      expect(
        response.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('strict-transport-security')),
      );
    });

    test('present when TLS is configured', () async {
      final response = await get(
        '/health',
        handler: createHandler(tlsEnabled: true),
      );
      expect(
        response.headers['strict-transport-security'],
        contains('max-age='),
      );
      expect(
        response.headers['strict-transport-security'],
        isNot(contains('preload')),
        reason:
            'preload is a one-way browser-vendor submission and is not this '
            'project\'s call to make for whoever self-hosts',
      );
    });
  });

  group('the landing page keeps its own stricter CSP', () {
    test('a handler-set CSP is not overwritten by the API default', () async {
      // The magic-link page has inline style and script and needs a
      // nonce-based policy. If the middleware clobbered it with
      // `default-src 'none'`, the page would break — and the tempting fix
      // would be to loosen the API policy for everything.
      const custom = "default-src 'none'; script-src 'nonce-abc'";
      final wrapped = securityHeadersMiddleware(tlsEnabled: false)(
        (_) async => Response.ok(
          '<html></html>',
          headers: const {contentSecurityPolicyHeader: custom},
        ),
      );
      final response = await wrapped(
        Request('GET', Uri.parse('http://localhost/auth/redeem')),
      );
      expect(response.headers[contentSecurityPolicyHeader], custom);
    });

    test('a nonce is fresh per call and long enough to be unguessable', () {
      final nonces = {for (var i = 0; i < 50; i++) cspNonce()};
      expect(nonces, hasLength(50), reason: 'a reused nonce is no nonce');
      expect(base64.decode(nonces.first), hasLength(16));
    });
  });
}
