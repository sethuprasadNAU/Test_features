import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 10.13's four hard security constraints, tested at the routing layer
/// without a real Postgres connection — `/diagnostics/health` never touches
/// [DiagnosticsContext], so these exercise the gating middleware and the
/// enabled/disabled mount decision on their own, in isolation from the read
/// queries (covered by `diagnostics_repository_test.dart`, which does need a
/// real database).
void main() {
  // Never actually invoked in any test below — every one either fails before
  // reaching a route that calls this, or hits /diagnostics/health, which
  // answers without touching [DiagnosticsContext] at all.
  Future<Response> notCalled(
    Request request,
    Future<Response> Function(DiagnosticsContext) action,
  ) async {
    fail('withDiagnostics should not have been called for this request');
  }

  Request request(String path, {String? token, InternetAddress? remote}) {
    final headers = token == null
        ? const <String, String>{}
        : {'authorization': 'Bearer $token'};
    var req = Request('GET', Uri.parse('http://localhost$path'), headers: headers);
    if (remote != null) {
      req = req.change(
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(remote),
        },
      );
    }
    return req;
  }

  test('disabled by default: the route does not exist at all', () async {
    final handler = createHandler();
    final response = await handler(request('/diagnostics/health'));
    expect(response.statusCode, isNot(200));
  });

  test(
    'disabled explicitly (config present but enabled: false) still mounts nothing',
    () async {
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: false,
          allowRemote: false,
          token: 'unused',
        ),
        withDiagnostics: notCalled,
      );
      final response = await handler(request('/diagnostics/health'));
      expect(response.statusCode, isNot(200));
    },
  );

  test('enabled requires a bearer token at all', () async {
    final handler = createHandler(
      diagnosticsConfig: const DiagnosticsConfig(
        enabled: true,
        allowRemote: false,
        token: 'right-token',
      ),
      withDiagnostics: notCalled,
    );
    final response = await handler(request('/diagnostics/health'));
    expect(response.statusCode, 401);
  });

  test('enabled rejects the wrong token', () async {
    final handler = createHandler(
      diagnosticsConfig: const DiagnosticsConfig(
        enabled: true,
        allowRemote: false,
        token: 'right-token',
      ),
      withDiagnostics: notCalled,
    );
    final response = await handler(
      request('/diagnostics/health', token: 'wrong-token'),
    );
    expect(response.statusCode, 401);
  });

  test(
    'never renders a token in any response, including a 401',
    () async {
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: true,
          allowRemote: false,
          token: 'right-token',
        ),
        withDiagnostics: notCalled,
      );
      final response = await handler(
        request('/diagnostics/health', token: 'wrong-token'),
      );
      final body = await response.readAsString();
      expect(body, isNot(contains('right-token')));
      expect(body, isNot(contains('wrong-token')));
    },
  );

  test(
    'the correct token from an in-process call (no real socket) succeeds',
    () async {
      // No `shelf.io.connection_info` in context — the request was built
      // directly, not received over a real socket, and that is treated as
      // local (see `_requireLocalUnlessAllowed`'s doc comment).
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: true,
          allowRemote: false,
          token: 'right-token',
        ),
        withDiagnostics: (req, action) async =>
            action(const _StubDiagnosticsContext()),
      );
      final response = await handler(
        request('/diagnostics/health', token: 'right-token'),
      );
      expect(response.statusCode, 200);
    },
  );

  test(
    'a request whose real peer address is not loopback is refused, by default',
    () async {
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: true,
          allowRemote: false,
          token: 'right-token',
        ),
        withDiagnostics: notCalled,
      );
      final response = await handler(
        request(
          '/diagnostics/health',
          token: 'right-token',
          remote: InternetAddress('203.0.113.5'),
        ),
      );
      expect(response.statusCode, 403);
    },
  );

  test(
    'a loopback peer address succeeds even with the real connection-info path',
    () async {
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: true,
          allowRemote: false,
          token: 'right-token',
        ),
        withDiagnostics: (req, action) async =>
            action(const _StubDiagnosticsContext()),
      );
      final response = await handler(
        request(
          '/diagnostics/health',
          token: 'right-token',
          remote: InternetAddress.loopbackIPv4,
        ),
      );
      expect(response.statusCode, 200);
    },
  );

  test(
    'allow_remote lets a non-loopback peer through, once explicitly opted in',
    () async {
      final handler = createHandler(
        diagnosticsConfig: const DiagnosticsConfig(
          enabled: true,
          allowRemote: true,
          token: 'right-token',
        ),
        withDiagnostics: (req, action) async =>
            action(const _StubDiagnosticsContext()),
      );
      final response = await handler(
        request(
          '/diagnostics/health',
          token: 'right-token',
          remote: InternetAddress('203.0.113.5'),
        ),
      );
      expect(response.statusCode, 200);
    },
  );

  test('/diagnostics/health never reveals a session token or magic link', () async {
    final handler = createHandler(
      diagnosticsConfig: const DiagnosticsConfig(
        enabled: true,
        allowRemote: false,
        token: 'right-token',
      ),
      withDiagnostics: (req, action) async =>
          action(const _StubDiagnosticsContext()),
    );
    final response = await handler(
      request('/diagnostics/health', token: 'right-token'),
    );
    final body = jsonDecode(await response.readAsString()) as Map<String, Object?>;
    expect(body, isNot(contains('token')));
    expect(body, isNot(contains('magic_link')));
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

/// Never dereferenced by these tests — every test either fails before a
/// [DiagnosticsContext] would be needed, or reaches /diagnostics/health,
/// which never touches it. Exists only to satisfy the type signature.
class _StubDiagnosticsContext implements DiagnosticsContext {
  const _StubDiagnosticsContext();

  @override
  DiagnosticsRepository get repo => throw UnimplementedError();

  @override
  SyncTrafficLogStore get trafficLog => throw UnimplementedError();

  @override
  AuthAuditLog get auditLog => throw UnimplementedError();
}
