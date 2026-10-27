import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// The *route-level* behaviour of §4.4's rate limits and §4.3's revocation —
/// specifically the parts that are about what the HTTP layer says and does, not
/// about what SQL runs.
///
/// Runs against a fake [AuthService] with no Postgres, which is what lets these
/// assert the subtle requirement: a per-email limit must be **byte-identical**
/// to a successful request. That is a statement about two response objects, and
/// comparing them is much clearer without a database in the way. The SQL half —
/// two real sessions on two devices both dying — needs Postgres and lives in
/// `revocation_test.dart`.
void main() {
  late _FakeAuthService auth;
  var now = DateTime.utc(2026, 8, 7, 12);

  setUp(() {
    auth = _FakeAuthService();
    now = DateTime.utc(2026, 8, 7, 12);
  });

  Handler build({
    RateLimiter? limiter,
    List<Map<String, String?>>? auditEvents,
    SourceIdentity? sourceIdentity,
  }) => createHandler(
    withAuthService: <T>(action) => action(auth),
    // Deterministic, so a byte-comparison of two 202s is meaningful.
    newId: () => 'fixed-id',
    rateLimiter: limiter ?? RateLimiter(clock: () => now),
    withAuditLog: auditEvents == null
        ? null
        : (action) async => action(_RecordingAuditLog(auditEvents)),
    sourceIdentity: sourceIdentity,
  );

  Future<Response> requestLink(
    Handler handler, {
    String email = 'sam@example.com',
    String? source,
    String? forwardedFor,
  }) {
    var request = Request(
      'POST',
      Uri.parse('http://localhost/auth/magic-link'),
      body: jsonEncode({'email': email}),
      headers: {
        'content-type': 'application/json',
        if (forwardedFor != null) 'x-forwarded-for': forwardedFor,
      },
    );
    if (source != null) {
      request = request.change(
        context: {
          'shelf.io.connection_info': _FakeConnectionInfo(
            InternetAddress(source),
          ),
        },
      );
    }
    return Future.sync(() => handler(request));
  }

  group('per-email limit is silent, per-source limit is honest (§4.4)', () {
    test(
      'the 4th request for one address is a 202 identical to the 1st',
      () async {
        // **The subtlest requirement in §4.4.** A 429 keyed on an email address
        // tells the caller somebody recently requested links for it — a real
        // oracle about a third party, and the exact thing §4.5's byte-identical
        // response exists to prevent.
        final handler = build();
        final first = await requestLink(handler);
        final firstBody = await first.readAsString();

        Response? fourth;
        for (var i = 0; i < 3; i++) {
          fourth = await requestLink(handler);
        }
        final fourthBody = await fourth!.readAsString();

        expect(fourth.statusCode, first.statusCode);
        expect(fourth.statusCode, 202);
        expect(fourthBody, firstBody);
      },
    );

    test('and no email is actually sent once the address is limited', () async {
      // The other half: identical response, but the send must not happen. A
      // limiter that returns 202 and still sends is not a limiter.
      final handler = build();
      for (var i = 0; i < 3; i++) {
        await requestLink(handler);
      }
      expect(auth.linkRequests, 3);

      await requestLink(handler);
      expect(
        auth.linkRequests,
        3,
        reason: 'the 4th request must not reach requestMagicLink',
      );
    });

    test('an over-limit source gets an honest 429', () async {
      // This fact is about the caller, not any third party, so telling them is
      // useful — and unlike the email case there is nothing to disclose.
      final handler = build();
      for (var i = 0; i < 10; i++) {
        final response = await requestLink(
          handler,
          email: 'user$i@example.com',
          source: '203.0.113.5',
        );
        expect(response.statusCode, 202);
      }
      final limited = await requestLink(
        handler,
        email: 'user99@example.com',
        source: '203.0.113.5',
      );
      expect(limited.statusCode, 429);
      final body = jsonDecode(await limited.readAsString());
      expect((body as Map)['error'], 'rate_limited');
    });

    test('the source address comes from the socket, not a header', () async {
      // A header-derived source would let any caller forge it and walk through
      // the per-source limit — the same reasoning as the diagnostics console's
      // loopback gate.
      final handler = build();
      for (var i = 0; i < 15; i++) {
        var request = Request(
          'POST',
          Uri.parse('http://localhost/auth/magic-link'),
          body: jsonEncode({'email': 'user$i@example.com'}),
          headers: {
            'content-type': 'application/json',
            // Rotating a forged forwarding header must not reset anything.
            'x-forwarded-for': '198.51.100.$i',
            'x-real-ip': '198.51.100.$i',
          },
        );
        request = request.change(
          context: {
            'shelf.io.connection_info': _FakeConnectionInfo(
              InternetAddress('203.0.113.5'),
            ),
          },
        );
        final response = await handler(request);
        if (i >= 10) {
          expect(
            response.statusCode,
            429,
            reason: 'a forged X-Forwarded-For must not bypass the limit',
          );
        }
      }
    });

    test('a redemption flood is limited per source', () async {
      final handler = build();
      Future<Response> redeem() {
        var request = Request(
          'POST',
          Uri.parse('http://localhost/auth/redeem'),
          body: jsonEncode({'token': 'guess', 'device_id': 'device-A'}),
          headers: const {'content-type': 'application/json'},
        );
        request = request.change(
          context: {
            'shelf.io.connection_info': _FakeConnectionInfo(
              InternetAddress('203.0.113.5'),
            ),
          },
        );
        return Future.sync(() => handler(request));
      }

      for (var i = 0; i < 20; i++) {
        expect(
          (await redeem()).statusCode,
          400,
          reason: 'bad token, not limited',
        );
      }
      expect((await redeem()).statusCode, 429);
    });

    // Task 10.56, finding I-6: this route drew a `200` for all 60 probes,
    // with no `429` and nothing audited.
    test('a link-status poll flood is limited per source', () async {
      final handler = build();
      Future<Response> poll() {
        var request = Request(
          'GET',
          Uri.parse('http://localhost/auth/link-status/some-request-id'),
        );
        request = request.change(
          context: {
            'shelf.io.connection_info': _FakeConnectionInfo(
              InternetAddress('203.0.113.5'),
            ),
          },
        );
        return Future.sync(() => handler(request));
      }

      for (var i = 0; i < 30; i++) {
        expect((await poll()).statusCode, 200, reason: 'poll $i of 30');
      }
      expect((await poll()).statusCode, 429);
    });

    test(
      'an oversized request id is refused before it reaches the service',
      () async {
        final handler = build();
        var request = Request(
          'GET',
          Uri.parse('http://localhost/auth/link-status/${'x' * 201}'),
        );
        request = request.change(
          context: {
            'shelf.io.connection_info': _FakeConnectionInfo(
              InternetAddress('203.0.113.5'),
            ),
          },
        );
        final response = await Future.sync(() => handler(request));
        expect(response.statusCode, 400);
      },
    );
  });

  group('behind a reverse proxy, at the route level (task 10.52, I-1)', () {
    const proxy = '172.31.242.10';
    SourceIdentity behindProxy() =>
        SourceIdentity(trustedProxies: TrustedProxies.parse(proxy));

    test('a flood from one client does not refuse an unrelated one', () {
      // **§11.3's live reproduction, inverted into an assertion.** In the
      // shipped Caddy deployment this exact sequence gave the innocent
      // biologist a 429 with `{"error":"rate_limited"}`, because every request
      // keyed on the proxy's container address. This is the acceptance
      // criterion task 10.52 was set, at the route level; the same thing
      // against a live stack is scripts/verify_i1_source_identity.sh.
      final handler = build(sourceIdentity: behindProxy());
      return Future(() async {
        for (var i = 0; i < 12; i++) {
          await requestLink(
            handler,
            email: 'attacker$i@example.com',
            source: proxy,
            forwardedFor: '198.51.100.9',
          );
        }
        final attacker = await requestLink(
          handler,
          email: 'attacker99@example.com',
          source: proxy,
          forwardedFor: '198.51.100.9',
        );
        expect(attacker.statusCode, 429, reason: 'the flooder is refused');

        final innocent = await requestLink(
          handler,
          email: 'innocent-biologist@nau.edu',
          source: proxy,
          forwardedFor: '203.0.113.77',
        );
        expect(
          innocent.statusCode,
          202,
          reason: 'ten strangers must not be able to lock everyone out',
        );
      });
    });

    test('audit rows name the client, not the proxy', () async {
      // 158 events with one distinct source_address is what the old behaviour
      // produced, and it is why C-5's forensic contribution was void.
      final events = <Map<String, String?>>[];
      final handler = build(sourceIdentity: behindProxy(), auditEvents: events);
      await requestLink(
        handler,
        email: 'sam@example.com',
        source: proxy,
        forwardedFor: '198.51.100.9',
      );
      await requestLink(
        handler,
        email: 'kim@example.com',
        source: proxy,
        forwardedFor: '203.0.113.77',
      );
      final sources = events.map((e) => e['source_address']).toSet();
      expect(sources, {'198.51.100.9', '203.0.113.77'});
      expect(sources, isNot(contains(proxy)));
    });

    test(
      'a proxy that names nobody refuses nobody, and says so honestly',
      () async {
        // The fail-safe, at the route level: a misconfigured proxy must not
        // become a global lockout, and the audit row must not blame the proxy
        // for traffic it only carried.
        final events = <Map<String, String?>>[];
        final handler = build(
          sourceIdentity: behindProxy(),
          auditEvents: events,
        );
        for (var i = 0; i < 20; i++) {
          final response = await requestLink(
            handler,
            email: 'person$i@example.com',
            source: proxy,
          );
          expect(response.statusCode, 202, reason: 'request $i was refused');
        }
        expect(events.map((e) => e['source_address']).toSet(), {
          'proxy-unattributed',
        });
      },
    );

    test(
      'a forged header from a peer that is NOT the proxy changes nothing',
      () async {
        // The property that must survive: the allowlist is of sockets. Rotating
        // a forged X-Forwarded-For from an ordinary caller must not mint a fresh
        // bucket per request.
        final handler = build(sourceIdentity: behindProxy());
        for (var i = 0; i < 15; i++) {
          final response = await requestLink(
            handler,
            email: 'user$i@example.com',
            source: '203.0.113.5',
            forwardedFor: '198.51.100.$i',
          );
          if (i >= 10) {
            expect(
              response.statusCode,
              429,
              reason:
                  'a forged header from a non-proxy peer must not bypass '
                  'the limit',
            );
          }
        }
      },
    );
  });

  group('rate-limit trips are audited even when the caller is not told', () {
    test('a silent per-email limit still records an event', () async {
      // The operator's only view of a per-email trip, since the caller is
      // deliberately told nothing.
      final events = <Map<String, String?>>[];
      final handler = build(auditEvents: events);
      for (var i = 0; i < 4; i++) {
        await requestLink(handler);
      }
      expect(
        events,
        contains(
          allOf(
            containsPair('event', 'rate_limit_tripped'),
            containsPair('outcome', 'email_limited'),
            containsPair('reason', 'magic_link'),
          ),
        ),
      );
    });

    test('an honest per-source limit records one too', () async {
      final events = <Map<String, String?>>[];
      final handler = build(auditEvents: events);
      for (var i = 0; i < 11; i++) {
        await requestLink(
          handler,
          email: 'user$i@example.com',
          source: '203.0.113.5',
        );
      }
      expect(
        events,
        contains(
          allOf(
            containsPair('event', 'rate_limit_tripped'),
            containsPair('outcome', 'source_limited'),
          ),
        ),
      );
    });
  });

  group(
    'a detached delivery outcome does not touch the response it arrives '
    'after (task 11.293)',
    () {
      // `SmtpEmailSender` reports success or failure from its own detached
      // future — strictly after `AuthService.requestMagicLink` has already
      // returned and this route has already answered (see
      // `EmailSender.sendMagicLink`, `auth_routes.dart`). `_FakeAuthService`
      // stands in for that: it does not call `onDeliveryOutcome` itself, but
      // remembers it so a test can invoke it the same way a real detached
      // delivery would, after the response is already in hand.

      test(
        'the 202 is already returned before the outcome is known — the '
        'callback cannot be part of the response path',
        () async {
          final events = <Map<String, String?>>[];
          final handler = build(auditEvents: events);
          final response = await requestLink(handler);
          expect(response.statusCode, 202);
          // The route's only audit write so far is the initial 'sent' row —
          // proof the second row is not part of answering the request.
          expect(events, hasLength(1));
          expect(events.single['outcome'], 'sent');
          expect(auth.lastDeliveryOutcomeCallback, isNotNull);
        },
      );

      test(
        'a refused delivery is recorded as a second row, distinct from the '
        'first — a refused link must not read as sent forever',
        () async {
          final events = <Map<String, String?>>[];
          final handler = build(auditEvents: events);
          final response = await requestLink(
            handler,
            email: 'sam@example.com',
          );
          final body = await response.readAsString();

          // The detached delivery now reports failure, well after the
          // response above was already generated.
          auth.lastDeliveryOutcomeCallback!(false);
          // The failure row is written from a continuation that waits for
          // the request's own row (task 11.298) — one microtask, even when
          // that row is long since written. Let it land.
          await Future<void>.delayed(Duration.zero);

          expect(
            events,
            containsAllInOrder([
              allOf(
                containsPair('event', 'link_requested'),
                containsPair('outcome', 'sent'),
              ),
              allOf(
                containsPair('event', 'link_requested'),
                containsPair('outcome', 'undelivered'),
                containsPair('email', 'sam@example.com'),
              ),
            ]),
            reason: 'two rows: the honest one written at request time, and '
                'the one the relay\'s answer adds later',
          );
          // What the caller received is unaffected by any of this — it was
          // already generated and read before the callback ever fired.
          expect(response.statusCode, 202);
          expect(body, contains('"status":"sent"'));
        },
      );

      test(
        'a successful delivery adds no second row — only a refusal is '
        'invisible today',
        () async {
          final events = <Map<String, String?>>[];
          final handler = build(auditEvents: events);
          await requestLink(handler);
          auth.lastDeliveryOutcomeCallback!(true);
          expect(events, hasLength(1), reason: 'no confirmation row on success');
        },
      );
    },
  );

  group('the boundary applies the sender\'s own address rule (task 11.298)', () {
    // Until 11.298 the boundary was looser than the SMTP sender: these four
    // passed here, were refused in the sender, and the person got the same
    // `202` as everybody with no mail behind it. Reproduced live 2026-09-21.
    for (final locked in [
      'üser@example.com',
      'josé@universidad.mx',
      '"odd name"@example.com',
      'user@[192.168.1.1]',
    ]) {
      test('$locked is refused with 400 invalid_email, and no link is made',
          () async {
        final events = <Map<String, String?>>[];
        final handler = build(auditEvents: events);
        final response = await requestLink(handler, email: locked);
        expect(response.statusCode, 400);
        expect(
          jsonDecode(await response.readAsString()),
          containsPair('error', 'invalid_email'),
        );
        expect(auth.linkRequests, 0, reason: 'no token, no send');
        expect(events, isEmpty, reason: 'a malformed request is not audited');
      });
    }

    test('an ordinary address still gets its 202', () async {
      final response = await requestLink(
        build(),
        email: 'first.last+tag@sub.example.edu',
      );
      expect(response.statusCode, 202);
      expect(auth.linkRequests, 1);
    });

    test(
      'the failure row is written after the request\'s own row even when the '
      'sender reports before the handler gets there',
      () async {
        // `_FakeAuthService` normally hands the callback back for the test
        // to fire later. Here it fires it *inside* `requestMagicLink`, which
        // is what `SmtpEmailSender` did on the path that never opened a
        // socket (task 11.298's second finding) and what any sender that
        // fails instantly — port closed, relay down — can still do. The
        // route must order the rows itself rather than trust the sender's
        // speed: on a live server on 2026-09-21 the `undelivered` row was
        // 2 ms *ahead* of the `sent` row.
        auth.reportDeliveryFailureAtOnce = true;
        final events = <Map<String, String?>>[];
        final handler = build(auditEvents: events);
        final response = await requestLink(handler);
        expect(response.statusCode, 202);
        // The failure row is written from a detached future; let it land.
        await Future<void>.delayed(Duration.zero);
        expect(
          events.map((e) => e['outcome']).toList(),
          ['sent', 'undelivered'],
          reason: 'the request\'s own row first, whatever the sender did',
        );
      },
    );
  });

  group('GET /auth/sessions lists the caller and nobody else (task 11.35)', () {
    Future<Response> list(
      Handler handler, {
      String? token = 'good-token',
      String query = '',
    }) => Future.sync(
      () => handler(
        Request(
          'GET',
          Uri.parse('http://localhost/auth/sessions$query'),
          headers: {if (token != null) 'authorization': 'Bearer $token'},
        ),
      ),
    );

    test('the user listed is the session\'s, and it is the only input', () async {
      // The acceptance criterion, stated as an assertion: a caller "sees their
      // own sessions and nobody else's, demonstrated by a test that tries."
      // Everything a caller could possibly aim at somebody else is here — a
      // query string, and (below) a body — and none of it reaches the query.
      auth.activeSession = const ActiveSession(
        sessionId: 'sess-1',
        userId: 'user-me',
        deviceId: 'laptop',
      );
      final handler = build();
      final response = await list(
        handler,
        query: '?user_id=user-someone-else&device_id=someone-elses-phone',
      );

      expect(response.statusCode, 200);
      expect(auth.listedFor, ('user-me', 'laptop'));
      expect(
        auth.listedFor?.$1,
        isNot('user-someone-else'),
        reason: 'a query-supplied user_id must be ignored entirely',
      );
    });

    test('a body naming another user is ignored too', () async {
      // A GET with a body is unusual, not impossible, and "the route reads
      // nothing from the body" is worth measuring rather than assuming.
      auth.activeSession = const ActiveSession(
        sessionId: 'sess-1',
        userId: 'user-me',
        deviceId: 'laptop',
      );
      final handler = build();
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/auth/sessions'),
          headers: const {
            'authorization': 'Bearer good-token',
            'content-type': 'application/json',
          },
          body: jsonEncode({'user_id': 'user-someone-else'}),
        ),
      );

      expect(response.statusCode, 200);
      expect(auth.listedFor, ('user-me', 'laptop'));
    });

    test('it is unreachable without a token', () async {
      final handler = build();
      final response = await list(handler, token: null);
      expect(response.statusCode, 401);
      expect(
        auth.listedFor,
        isNull,
        reason: 'no query may run for an unauthenticated caller',
      );
    });

    test('and unreachable with a token that no longer resolves', () async {
      auth.activeSession = null;
      final handler = build();
      final response = await list(handler);
      expect(response.statusCode, 401);
      expect(auth.listedFor, isNull);
    });

    test('a row carries no source address and no token', () async {
      // The decision the task asked for out loud: a device label and a
      // last-used time are enough to pick a lost phone out of a list, and an
      // address is location-revealing data arriving on a new read for a
      // convenience. Asserted as an exact key set so a later "just add one
      // field" cannot pass.
      final handler = build();
      final response = await list(handler);
      final body = jsonDecode(await response.readAsString()) as Map;
      final rows = (body['sessions'] as List).cast<Map<String, Object?>>();

      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.keys.toSet(), {
          'device_id',
          'first_signed_in_at',
          'last_seen_at',
          'expires_at',
          'is_current_device',
        });
      }
      final raw = jsonEncode(body).toLowerCase();
      for (final forbidden in [
        'address',
        'token',
        'ip',
        'session_id',
        'email',
      ]) {
        expect(
          raw.contains(forbidden),
          isFalse,
          reason: '"$forbidden" must not appear in a session listing',
        );
      }
    });

    test('the caller can tell which row is the device in their hand', () async {
      final handler = build();
      final body =
          jsonDecode(await (await list(handler)).readAsString()) as Map;
      final rows = (body['sessions'] as List).cast<Map<String, Object?>>();
      expect(rows.where((r) => r['is_current_device'] == true), hasLength(1));
      expect(rows.first['device_id'], 'device-A');
    });

    test('the listing is not left in a shared cache', () async {
      final handler = build();
      final response = await list(handler);
      expect(response.headers['cache-control'], 'no-store');
    });

    test('a flood from one signed-in user is limited, and audited', () async {
      // Task 10.56's standard treatment, keyed on the authenticated user the
      // way invite redemption is — an authenticated route has a better key
      // than an address, and a per-user bucket cannot be collapsed by a proxy.
      final auditEvents = <Map<String, String?>>[];
      final handler = build(auditEvents: auditEvents);
      for (var i = 0; i < 60; i++) {
        expect((await list(handler)).statusCode, 200, reason: 'read $i of 60');
      }
      final limited = await list(handler);
      expect(limited.statusCode, 429);
      expect(
        auditEvents.where((e) => e['event'] == 'rate_limit_tripped'),
        isNotEmpty,
      );
    });

    test('one user hitting the limit does not lock out another', () async {
      // What a per-user key buys, stated as a test: the failure mode of a
      // per-source key is that one caller behind a shared address can refuse
      // service to everybody else behind it.
      final handler = build();
      for (var i = 0; i < 61; i++) {
        await list(handler);
      }
      auth.activeSession = const ActiveSession(
        sessionId: 'sess-2',
        userId: 'user-other',
        deviceId: 'device-Z',
      );
      expect((await list(handler)).statusCode, 200);
    });
  });

  group('revocation routes are self-service only (§4.3, §4.11)', () {
    test(
      'revoke-all revokes the session\'s own user, never a body value',
      () async {
        // The §4.11 rule applied to a destructive route: the `user_id` comes from
        // the validated session. A route that took it from the body would let any
        // authenticated caller sign out any user they could name.
        auth.activeSession = const ActiveSession(
          sessionId: 'sess-1',
          userId: 'user-me',
          deviceId: 'device-A',
        );
        final handler = build();
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/auth/sessions/revoke-all'),
            headers: const {'authorization': 'Bearer good-token'},
            body: jsonEncode({'user_id': 'user-someone-else'}),
          ),
        );

        expect(response.statusCode, 200);
        expect(auth.revokedAllForUser, 'user-me');
        expect(
          auth.revokedAllForUser,
          isNot('user-someone-else'),
          reason: 'a body-supplied user_id must be ignored entirely',
        );
      },
    );

    test(
      'revoke-device scopes to the caller, with the device from the body',
      () async {
        auth.activeSession = const ActiveSession(
          sessionId: 'sess-1',
          userId: 'user-me',
          deviceId: 'laptop',
        );
        final handler = build();
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/auth/sessions/revoke-device'),
            headers: const {'authorization': 'Bearer good-token'},
            body: jsonEncode({
              'device_id': 'lost-phone',
              // Ignored, same as above.
              'user_id': 'user-someone-else',
            }),
          ),
        );

        expect(response.statusCode, 200);
        expect(auth.revokedDevice, ('user-me', 'lost-phone'));
      },
    );

    test('both routes refuse an absent token', () async {
      final handler = build();
      for (final path in [
        '/auth/sessions/revoke-all',
        '/auth/sessions/revoke-device',
      ]) {
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            body: jsonEncode({'device_id': 'phone'}),
          ),
        );
        expect(response.statusCode, 401, reason: path);
        expect(auth.revokedAllForUser, isNull);
        expect(auth.revokedDevice, isNull);
      }
    });

    test('both routes refuse an invalid token', () async {
      auth.activeSession = null; // validateSession returns null
      final handler = build();
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/auth/sessions/revoke-all'),
          headers: const {'authorization': 'Bearer stale-token'},
        ),
      );
      expect(response.statusCode, 401);
      expect(auth.revokedAllForUser, isNull);
    });

    test('there is no cross-user revocation route at all', () async {
      // Deliberate absence: task 11.2 calls the service method server-side,
      // inside a flow that has already established the caller is an owner.
      // Exposing an HTTP endpoint now would mean shipping an attack surface for
      // a capability nothing yet calls.
      final handler = build();
      for (final path in [
        '/auth/sessions/revoke-user',
        '/auth/users/user-x/revoke',
        '/admin/revoke',
      ]) {
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            headers: const {'authorization': 'Bearer good-token'},
            body: jsonEncode({'user_id': 'user-victim'}),
          ),
        );
        expect(response.statusCode, 404, reason: '$path must not exist');
      }
    });

    test('a revocation is audited with the actor and the reason', () async {
      // §4.7 requires "session revoked (with actor and reason)".
      auth.activeSession = const ActiveSession(
        sessionId: 'sess-1',
        userId: 'user-me',
        deviceId: 'laptop',
      );
      final events = <Map<String, String?>>[];
      final handler = build(auditEvents: events);
      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/auth/sessions/revoke-all'),
          headers: const {'authorization': 'Bearer good-token'},
        ),
      );
      expect(
        events,
        contains(
          allOf(
            containsPair('event', 'session_revoked'),
            // The actor …
            containsPair('user_id', 'user-me'),
            // … and the reason.
            containsPair('reason', 'revoked_all_devices'),
          ),
        ),
      );
    });
  });

  group(
    'a NUL byte cannot reach Postgres unrefused, on any auth route '
    '(task 10.64, finding J-4\'s class)',
    () {
      // `device_id` is stored/queried verbatim against Postgres `TEXT`
      // columns, bound as query parameters, unlike `token` (always hashed
      // first) or `email` (already filtered). A NUL byte there throws
      // `invalid_byte_sequence` directly from the driver, not through any
      // typed refusal this route writes — the same failure mode
      // `sync_routes.dart`'s J-4 fix closed for `project_id`/`device_id` on
      // the sync routes, found here on both routes that take a
      // caller-supplied `device_id` by asking the same question of each. A
      // third candidate site — `/auth/link-status/<requestId>` — turned out
      // not to be reachable; see the note at the end of this group.
      test('/auth/redeem with a NUL byte in device_id draws 400, not 500', () async {
        final handler = build();
        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/auth/redeem'),
            body: jsonEncode({
              'token': 'some-token',
              'device_id': 'device\u0000A',
            }),
          ),
        );
        expect(response.statusCode, 400);
        expect(
          jsonDecode(await response.readAsString())['error'],
          'missing_device_id',
        );
      });

      test(
        '/auth/sessions/revoke-device with a NUL byte in device_id draws '
        '400, not 500',
        () async {
          auth.activeSession = const ActiveSession(
            sessionId: 'sess-1',
            userId: 'user-me',
            deviceId: 'laptop',
          );
          final handler = build();
          final response = await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/auth/sessions/revoke-device'),
              headers: const {'authorization': 'Bearer good-token'},
              body: jsonEncode({'device_id': 'lost\u0000phone'}),
            ),
          );
          expect(response.statusCode, 400);
          expect(
            auth.revokedDevice,
            isNull,
            reason: 'must be refused before it reaches AuthService at all',
          );
        },
      );

      // `/auth/link-status/<requestId>` looked like a third site of the same
      // shape — `linkRequestOutcome`'s `WHERE request_id = $1` binds it
      // exactly the way `device_id` reaches `auth_sessions` — and is worth
      // recording precisely because it is **not** one, having chased it three
      // ways against a live server: a percent-encoded `%00` over a real
      // socket, a raw literal NUL byte written directly onto the wire
      // (bypassing URI encoding entirely), and constructing a `shelf.Request`
      // in-process with a `Uri(path: ...)` carrying a raw NUL character rather
      // than `Uri.parse`. All three came back `200 pending`, not `400`. The
      // reason is structural, not incidental: `dart:core`'s `Uri` percent-
      // encodes a raw control character the moment one is written into its
      // `path` component — `Uri(path: 'req\x00id').path` is already
      // `req%00id` — and `Uri.parse` never decodes a `%00` it is handed
      // either. There is no `Uri` value whose `.path` getter returns a literal
      // NUL byte, and `request.url.path` is exactly that getter, so
      // `_hasNulByte` has nothing to see by construction of the type it is
      // checking, not by anything clever happening between here and it.
      //
      // No test asserts this, same as §12.6's own "claims I chased and could
      // not reproduce" — a gate that only reports its hits is not a
      // measurement, and a test built to make an unreachable path *look*
      // reachable (by handing the check a value no real request can produce)
      // would be exactly that kind of false measurement. The `_hasNulByte`
      // check on `requestId` in `auth_routes.dart` stays anyway: it costs one
      // boolean per request and is correct defense in depth against this
      // becoming reachable if the routing layer ever changes.
    },
  );

  group('no token value ever reaches a response or an audit row', () {
    test('the revocation response carries no token', () async {
      auth.activeSession = const ActiveSession(
        sessionId: 'sess-1',
        userId: 'user-me',
        deviceId: 'laptop',
      );
      final events = <Map<String, String?>>[];
      final handler = build(auditEvents: events);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/auth/sessions/revoke-all'),
          headers: const {'authorization': 'Bearer super-secret-token-value'},
        ),
      );
      final body = await response.readAsString();
      expect(body, isNot(contains('super-secret-token-value')));
      for (final event in events) {
        for (final value in event.values) {
          expect(value, isNot(contains('super-secret-token-value')));
        }
      }
    });
  });
}

/// Captures every field of every audit call so a test can assert on what was
/// logged without a database — and, just as importantly, on what was *not*
/// (see the no-token-value group).
class _RecordingAuditLog extends AuthAuditLog {
  _RecordingAuditLog(this.events)
    : super(_UnusableSession(), onError: _unreachable);

  final List<Map<String, String?>> events;

  @override
  Future<void> record(
    AuthAuditEvent event, {
    String? userId,
    String? email,
    String? deviceId,
    String? sourceAddress,
    String? outcome,
    String? reason,
    String? requestId,
  }) async {
    events.add({
      'event': event.db,
      'user_id': userId,
      'email': email,
      'device_id': deviceId,
      'source_address': sourceAddress,
      'outcome': outcome,
      'reason': reason,
      'request_id': requestId,
    });
  }
}

/// Never called: [_RecordingAuditLog] overrides the only method that would.
Never _unreachable(String type) =>
    throw StateError('unreachable: record() is overridden');

/// Never touched: [_RecordingAuditLog] overrides the only method that would.
class _UnusableSession implements Session {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the recording audit log issues no SQL');
}

class _FakeAuthService implements AuthService {
  int linkRequests = 0;
  String? revokedAllForUser;
  (String, String)? revokedDevice;

  /// The `user_id` and `device_id` [listSessionsForUser] was last called with.
  /// The whole point of the route is that the first of these can only ever be
  /// the caller's own, so the tests assert on it directly.
  (String, String)? listedFor;

  /// What [listSessionsForUser] returns.
  List<ListedSession> sessions = [
    ListedSession(
      deviceId: 'device-A',
      firstSignedInAt: DateTime.utc(2026, 8, 1),
      lastSeenAt: DateTime.utc(2026, 8, 7),
      expiresAt: DateTime.utc(2026, 10, 30),
      isCurrentDevice: true,
    ),
    ListedSession(
      deviceId: 'device-B',
      firstSignedInAt: DateTime.utc(2026, 7, 2),
      lastSeenAt: DateTime.utc(2026, 8, 3),
      expiresAt: DateTime.utc(2026, 9, 30),
      isCurrentDevice: false,
    ),
  ];

  /// What [validateSession] returns. Non-null by default so the revocation
  /// routes are reachable; set to null to model a stale token. Named
  /// `activeSession` rather than `session` because `AuthService.session` is the
  /// Postgres session, and shadowing it would be an invalid override.
  ActiveSession? activeSession = const ActiveSession(
    sessionId: 'sess-1',
    userId: 'user-me',
    deviceId: 'device-A',
  );

  /// Set by a test to see what the route does with a detached delivery
  /// outcome, without a real `EmailSender` in the way (task 11.293).
  void Function(bool delivered)? lastDeliveryOutcomeCallback;

  /// When set, [requestMagicLink] reports a failed delivery synchronously,
  /// before it returns — the shape of a sender that refuses without ever
  /// reaching an `await` (task 11.298).
  bool reportDeliveryFailureAtOnce = false;

  @override
  Future<String> requestMagicLink({
    required String rawEmail,
    required String requestId,
    void Function(bool delivered)? onDeliveryOutcome,
  }) async {
    linkRequests++;
    lastDeliveryOutcomeCallback = onDeliveryOutcome;
    if (reportDeliveryFailureAtOnce) onDeliveryOutcome?.call(false);
    return requestId;
  }

  @override
  Future<IssuedSession?> redeem({
    required String token,
    required String deviceId,
    required String sessionId,
    required String newUserId,
  }) async => null;

  @override
  Future<ActiveSession?> validateSession(String token) async => activeSession;

  @override
  Future<void> signOut(String token) async {}

  @override
  Future<int> revokeAllSessionsForUser(
    String userId, {
    String reason = 'revoked',
  }) async {
    revokedAllForUser = userId;
    return 2;
  }

  @override
  Future<int> revokeDeviceSessions(
    String userId,
    String deviceId, {
    String reason = 'device_revoked',
  }) async {
    revokedDevice = (userId, deviceId);
    return 1;
  }

  @override
  Future<List<ListedSession>> listSessionsForUser(
    String userId, {
    required String currentDeviceId,
    int limit = maxListedSessions,
  }) async {
    listedFor = (userId, currentDeviceId);
    return sessions;
  }

  @override
  Future<LinkRequestOutcome?> linkRequestOutcome(String requestId) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
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
