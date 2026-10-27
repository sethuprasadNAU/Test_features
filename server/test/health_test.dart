import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

void main() {
  group('/health', () {
    test('responds 200 with a plain liveness body', () async {
      final handler = createHandler();
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/health')),
      );

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body, {'status': 'ok'});
    });

    // Security model §2.2: an opportunistic scanner's first move is a
    // reconnaissance request to any open endpoint. `/health` is deliberately
    // uninformative — no schema version, no dependency versions, nothing an
    // attacker could use to fingerprint what to target next.
    test('never leaks version or dependency information', () async {
      final handler = createHandler();
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      final body = await response.readAsString();

      for (final leak in ['version', 'schema', 'dart', 'shelf', 'dependen']) {
        expect(body.toLowerCase(), isNot(contains(leak)));
      }
    });
  });

  group('unknown routes', () {
    test('a nonexistent path is not the health endpoint', () async {
      final handler = createHandler();
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/nope')),
      );

      expect(response.statusCode, isNot(200));
    });
  });
}
