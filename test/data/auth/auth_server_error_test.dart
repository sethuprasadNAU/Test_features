import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/data/auth/auth_client.dart';

/// **Task 11.37, item 1, second half.** "Nothing answered" and "something
/// answered and said no" are different failures with different fixes, and
/// until this task every auth route reported the second as the first — or as
/// something else entirely wrong.
///
/// Each `group` below is one route that had its own version of the defect.
void main() {
  AuthClient clientAnswering(int status, [Object? body]) => AuthClient(
    baseUrl: 'http://example.invalid',
    httpClient: MockClient((request) async {
      return http.Response(
        body == null ? '' : (body is String ? body : jsonEncode(body)),
        status,
      );
    }),
  );

  AuthClient clientThatNeverConnects() => AuthClient(
    baseUrl: 'http://example.invalid',
    httpClient: MockClient((request) async {
      // What `http` and `CupertinoClient` actually raise when the request
      // never completed — no route to host, connection refused.
      throw const SocketException('No route to host');
    }),
  );

  group('requestMagicLink — the reproduced trailing-slash case', () {
    test('a 404 is a server that answered, not a server out of reach', () async {
      await expectLater(
        clientAnswering(404, {'error': 'not_found'}).requestMagicLink('s@x.com'),
        throwsA(
          isA<AuthServerError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.path, 'path', '/auth/magic-link'),
        ),
      );
    });

    test('a per-source 429 is reported as a refusal, not as unreachable', () async {
      await expectLater(
        clientAnswering(429, {'error': 'rate_limited'}).requestMagicLink('s@x.com'),
        throwsA(
          isA<AuthServerError>().having((e) => e.isRateLimited, 'isRateLimited', isTrue),
        ),
      );
    });

    test('a 500 is marked as the server\'s own fault', () async {
      await expectLater(
        clientAnswering(500).requestMagicLink('s@x.com'),
        throwsA(
          isA<AuthServerError>().having((e) => e.isServerFault, 'isServerFault', isTrue),
        ),
      );
    });

    test(
      'a 400 invalid_email carries the code, so the screen can talk about '
      'the address rather than the server (task 11.298)',
      () async {
        await expectLater(
          clientAnswering(400, {
            'error': 'invalid_email',
            'trace_id': 't',
          }).requestMagicLink('üser@example.com'),
          throwsA(
            isA<AuthServerError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.code, 'code', 'invalid_email')
                .having((e) => e.isInvalidEmail, 'isInvalidEmail', isTrue),
          ),
        );
      },
    );

    test('a 400 with no readable code is still just a 400', () async {
      // A proxy answering in its own words, or a body that is not JSON: the
      // status is a fact, the code is absent, and nothing guesses.
      await expectLater(
        clientAnswering(400, '<html>bad request</html>').requestMagicLink(
          's@x.com',
        ),
        throwsA(
          isA<AuthServerError>()
              .having((e) => e.code, 'code', isNull)
              .having((e) => e.isInvalidEmail, 'isInvalidEmail', isFalse),
        ),
      );
    });

    test('a transport failure is NOT an AuthServerError', () async {
      // This is the half that keeps the distinction meaningful. If the client
      // wrapped everything, "the server answered" would stop being a fact.
      await expectLater(
        clientThatNeverConnects().requestMagicLink('s@x.com'),
        throwsA(allOf(isA<SocketException>(), isNot(isA<AuthServerError>()))),
      );
    });

    test('the per-address rate limit is still indistinguishable from a sent link', () async {
      // §4.5's oracle. The server answers the same 202 whether or not it sent
      // anything, and nothing in this client may add a way to tell — a
      // distinguishable outcome here would disclose that somebody recently
      // requested a link for an address the caller may not own.
      final result = await clientAnswering(202, {'request_id': 'r1'})
          .requestMagicLink('s@x.com');
      expect(result.requestId, 'r1');
    });
  });

  group('linkStatus', () {
    test('a 404 throws instead of polling "pending" forever', () async {
      // Before this task a wrong address answered 404 and this reported
      // `pending`, so a device polling a route that does not exist waited
      // indefinitely and never said why.
      await expectLater(
        clientAnswering(404).linkStatus('req-1'),
        throwsA(isA<AuthServerError>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('a 429 is still "pending" — being throttled while polling is normal', () async {
      expect(await clientAnswering(429).linkStatus('req-1'), LinkStatus.pending);
    });

    test('an unknown status value in a 200 is still pending', () async {
      expect(
        await clientAnswering(200, {'status': 'something_new'}).linkStatus('r'),
        LinkStatus.pending,
      );
    });

    test('consumed and expired still parse', () async {
      expect(
        await clientAnswering(200, {'status': 'consumed'}).linkStatus('r'),
        LinkStatus.consumed,
      );
      expect(
        await clientAnswering(200, {'status': 'expired'}).linkStatus('r'),
        LinkStatus.expired,
      );
    });
  });

  group('redeem', () {
    test('the server\'s own rejection is still a rejection', () async {
      await expectLater(
        clientAnswering(400, {'error': 'invalid_or_expired_link'})
            .redeem(token: 't', deviceId: 'd'),
        throwsA(isA<RedemptionRejected>()),
      );
    });

    test('a 404 is NOT reported as a bad sign-in code', () async {
      // The old behaviour sent somebody to request a second code, which would
      // fail identically against the same wrong address — and each attempt
      // spends a slot against the three-per-fifteen-minutes cap.
      await expectLater(
        clientAnswering(404).redeem(token: 't', deviceId: 'd'),
        throwsA(allOf(isA<AuthServerError>(), isNot(isA<RedemptionRejected>()))),
      );
    });

    test('a 400 that is not the documented rejection is a server error', () async {
      // `missing_device_id` and `malformed_body` are also 400s, and neither is
      // a statement about the code the person pasted.
      await expectLater(
        clientAnswering(400, {'error': 'missing_device_id'})
            .redeem(token: 't', deviceId: 'd'),
        throwsA(allOf(isA<AuthServerError>(), isNot(isA<RedemptionRejected>()))),
      );
    });

    test('an unparseable 400 body is a server error, not a rejection', () async {
      await expectLater(
        clientAnswering(400, '<html>proxy error</html>')
            .redeem(token: 't', deviceId: 'd'),
        throwsA(isA<AuthServerError>()),
      );
    });
  });

  group('signOut', () {
    test('401 is success — the session is already gone', () async {
      await clientAnswering(401).signOut('tok');
    });

    test('200 is success', () async {
      await clientAnswering(200).signOut('tok');
    });

    test('a 404 no longer reports success', () async {
      // It used to discard the status entirely, so a mistyped address left the
      // session live on the server while the screen said "Signed out".
      await expectLater(
        clientAnswering(404).signOut('tok'),
        throwsA(isA<AuthServerError>()),
      );
    });
  });

  group('revokeAllSessions', () {
    test('a non-200 is a typed server error', () async {
      await expectLater(
        clientAnswering(404).revokeAllSessions('tok'),
        throwsA(isA<AuthServerError>()),
      );
    });

    test('401 is a failure here, unlike signOut', () async {
      await expectLater(
        clientAnswering(401).revokeAllSessions('tok'),
        throwsA(isA<AuthServerError>()),
      );
    });

    test('a 200 returns the count', () async {
      expect(
        await clientAnswering(200, {'sessions_revoked': 3}).revokeAllSessions('t'),
        3,
      );
    });
  });
}
