import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/data/auth/auth_client.dart';

/// Task 10.67: `requestMagicLink`/`redeem` used naked `json['key']! as
/// String` casts on the server's response body — a malformed or
/// unexpected-shape 2xx response threw an uncaught `TypeError` instead of
/// the typed [AuthProtocolException] every field here now draws. Not a
/// permissive-fallback case (the old cast already failed closed — sign-in
/// simply crashed rather than succeeding with garbage data) but the same
/// typed-rejection treatment the sync wire's equivalent fields already had,
/// per task 10.66's "fix the class" rule.
void main() {
  AuthClient clientWithBody(String path, int status, Object? body) {
    return AuthClient(
      baseUrl: 'http://example.invalid',
      httpClient: MockClient((request) async {
        expect(request.url.path, path);
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
        );
      }),
    );
  }

  group('requestMagicLink', () {
    test('a well-formed response parses normally', () async {
      final client = clientWithBody('/auth/magic-link', 202, {
        'request_id': 'req-1',
      });
      final result = await client.requestMagicLink('sam@example.com');
      expect(result.requestId, 'req-1');
    });

    test('a wrongly-typed request_id is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/magic-link', 202, {
        'request_id': 12345,
      });
      await expectLater(
        client.requestMagicLink('sam@example.com'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test('a missing request_id is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/magic-link', 202, <String, Object?>{});
      await expectLater(
        client.requestMagicLink('sam@example.com'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test('a non-object body is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/magic-link', 202, [1, 2, 3]);
      await expectLater(
        client.requestMagicLink('sam@example.com'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test('non-JSON body is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/magic-link', 202, 'not json');
      await expectLater(
        client.requestMagicLink('sam@example.com'),
        throwsA(isA<AuthProtocolException>()),
      );
    });
  });

  group('redeem', () {
    test('a well-formed response parses normally', () async {
      final client = clientWithBody('/auth/redeem', 200, {
        'session_token': 'tok-1',
        'user_id': 'user-1',
        'email': 'sam@example.com',
        'expires_at': '2026-11-01T00:00:00.000Z',
      });
      final session = await client.redeem(token: 't', deviceId: 'd');
      expect(session.token, 'tok-1');
      expect(session.userId, 'user-1');
      expect(session.email, 'sam@example.com');
      expect(session.expiresAt, DateTime.utc(2026, 11, 1));
    });

    test('a wrongly-typed user_id is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/redeem', 200, {
        'session_token': 'tok-1',
        'user_id': 12345,
        'email': 'sam@example.com',
        'expires_at': '2026-11-01T00:00:00.000Z',
      });
      await expectLater(
        client.redeem(token: 't', deviceId: 'd'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test('an unparseable expires_at is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/redeem', 200, {
        'session_token': 'tok-1',
        'user_id': 'user-1',
        'email': 'sam@example.com',
        'expires_at': 'not-a-date',
      });
      await expectLater(
        client.redeem(token: 't', deviceId: 'd'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test('a missing field is a protocol error, not a crash', () async {
      final client = clientWithBody('/auth/redeem', 200, {
        'session_token': 'tok-1',
        'email': 'sam@example.com',
        'expires_at': '2026-11-01T00:00:00.000Z',
      });
      await expectLater(
        client.redeem(token: 't', deviceId: 'd'),
        throwsA(isA<AuthProtocolException>()),
      );
    });

    test("the server's own rejection is RedemptionRejected, unaffected by "
        'this fix', () async {
      final client = clientWithBody('/auth/redeem', 400, {
        'error': 'invalid_or_expired_link',
      });
      await expectLater(
        client.redeem(token: 't', deviceId: 'd'),
        throwsA(isA<RedemptionRejected>()),
      );
    });

    test('but any OTHER non-200 is not (task 11.37)', () async {
      // Narrowed from "every non-200" on 2026-08-28. A `404` from a
      // slash-suffixed address used to arrive here as "that sign-in code did
      // not work", which sends somebody to request a second code that fails
      // against the same wrong address — and each request spends a slot
      // against the three-per-fifteen-minutes per-address cap.
      // `test/data/auth/auth_server_error_test.dart` covers the full matrix.
      final client = clientWithBody('/auth/redeem', 401, {'error': 'nope'});
      await expectLater(
        client.redeem(token: 't', deviceId: 'd'),
        throwsA(allOf(isA<AuthServerError>(), isNot(isA<RedemptionRejected>()))),
      );
    });
  });

  group('linkStatus', () {
    test('an unrecognized status string defaults to pending, by design', () async {
      final client = clientWithBody('/auth/link-status/req-1', 200, {
        'status': 'something-unexpected',
      });
      expect(await client.linkStatus('req-1'), LinkStatus.pending);
    });

    // A non-object body was already a crash before this fix (the old code
    // cast straight to `Map<String, Object?>` before ever reading `status`)
    // — this only changes WHAT it throws, from a raw TypeError to the same
    // typed AuthProtocolException every other malformed-body case now draws.
    test('a non-object body is a protocol error, not a raw TypeError', () async {
      final client = clientWithBody('/auth/link-status/req-1', 200, [1, 2]);
      await expectLater(
        client.linkStatus('req-1'),
        throwsA(isA<AuthProtocolException>()),
      );
    });
  });
}
