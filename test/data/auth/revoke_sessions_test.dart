import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/data/auth/auth_client.dart';

/// **Task 11.28 parts 2 and 3: "sign out everywhere", finally reachable.**
///
/// `POST /auth/sessions/revoke-all` has existed and been correct since task
/// 10.14 — the person revoked is always the authenticated caller, taken from
/// the session and never from the request. **No screen called it.** The
/// security model names it as the answer both to "I think somebody has my
/// token" (§4.3) and to a lost or stolen device (§4.8), so until this wiring
/// the answer to both was that the person could do nothing.
///
/// What is tested here is the client half, and the property that matters is
/// not that it succeeds. It is that it **cannot report success when nothing
/// was revoked**: somebody reaches for this because they believe their
/// credentials are compromised, and a false confirmation is the worst thing
/// the control can do.
void main() {
  AuthClient clientReturning(
    int status,
    Object? body, {
    void Function(http.Request request)? inspect,
  }) => AuthClient(
    baseUrl: 'http://example.invalid',
    httpClient: MockClient((request) async {
      inspect?.call(request);
      return http.Response(
        body is String ? body : jsonEncode(body),
        status,
      );
    }),
  );

  test('revokes and reports how many sessions ended', () async {
    late String path;
    late String? authorization;
    late String method;
    final client = clientReturning(
      200,
      {'status': 'revoked', 'sessions_revoked': 3},
      inspect: (request) {
        path = request.url.path;
        method = request.method;
        authorization = request.headers['authorization'];
      },
    );
    expect(await client.revokeAllSessions('tok-1'), 3);
    expect(path, '/auth/sessions/revoke-all');
    expect(method, 'POST');
    expect(authorization, 'Bearer tok-1');
  });

  test('sends no body at all', () async {
    // §4.11: an authorization input never comes from a client-supplied value,
    // and this route destroys credentials. The server takes the person from
    // the session; a client that started sending a `user_id` would be the
    // first step toward a route that accepted one.
    late String body;
    final client = clientReturning(
      200,
      {'sessions_revoked': 1},
      inspect: (request) => body = request.body,
    );
    await client.revokeAllSessions('tok-1');
    expect(body, isEmpty);
  });

  test('zero revoked is a real answer, not an error', () async {
    final client = clientReturning(200, {'sessions_revoked': 0});
    expect(await client.revokeAllSessions('tok-1'), 0);
  });

  test('a 401 throws rather than reporting success', () async {
    // Unlike `signOut`, which is deliberately idempotent and swallows
    // everything: there, the local half is what was really being asked for.
    // Here the entire point is the server forgetting the credentials.
    final client = clientReturning(401, {'error': 'unauthorized'});
    await expectLater(
      client.revokeAllSessions('tok-1'),
      throwsA(isA<AuthServerError>()),
    );
  });

  test('a 500 throws', () async {
    final client = clientReturning(500, {'error': 'internal'});
    await expectLater(
      client.revokeAllSessions('tok-1'),
      throwsA(isA<AuthServerError>()),
    );
  });

  test('a missing count is a protocol error, not a silent zero', () async {
    // Zero is a real answer, so a malformed response must not look like one —
    // the same typed-rejection rule task 10.67 applied to every string field
    // in this file's sibling, applied to its one numeric field.
    final client = clientReturning(200, {'status': 'revoked'});
    await expectLater(
      client.revokeAllSessions('tok-1'),
      throwsA(isA<AuthProtocolException>()),
    );
  });

  test('a wrongly-typed count is a protocol error', () async {
    final client = clientReturning(200, {'sessions_revoked': '3'});
    await expectLater(
      client.revokeAllSessions('tok-1'),
      throwsA(isA<AuthProtocolException>()),
    );
  });

  test('a non-JSON body is a protocol error', () async {
    final client = clientReturning(200, 'not json');
    await expectLater(
      client.revokeAllSessions('tok-1'),
      throwsA(isA<AuthProtocolException>()),
    );
  });
}
