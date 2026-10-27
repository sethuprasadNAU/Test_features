import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 11.128. The question these tests exist to keep answered is not "does
/// `/ready` work" but **"do `/health` and `/ready` still mean two different
/// things"** — the defect 11.125 found was one endpoint being read as though it
/// answered both questions, and the only durable fix is a test that fails when
/// the two collapse back into one.
///
/// A server with no database is the whole point: it is the configuration
/// 11.125 measured `200` on, and it is one line to build here because
/// `createHandler()` with no arguments *is* a database-less server — the auth
/// and sync routers are mounted on exactly the condition `bin/server.dart`
/// mounts them on.
Future<Response> _get(Handler handler, String path) =>
    Future.value(handler(Request('GET', Uri.parse('http://localhost$path'))));

Future<Map<String, Object?>> _body(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, Object?>;

/// Enough of a mounted auth/sync surface for `createHandler` to consider this
/// server database-backed. Neither closure is ever called by these tests —
/// their presence is the signal, which is itself the property under test.
Handler _handlerWithDatabase({ReadinessProbe? readiness}) => createHandler(
  withAuthService: <T>(action) => throw StateError('not called'),
  withSyncContext: (request, action) => throw StateError('not called'),
  readiness: readiness,
);

void main() {
  group('/ready on a server with no database', () {
    test('answers 503 and names the database as degraded', () async {
      final response = await _get(createHandler(), '/ready');

      expect(response.statusCode, 503);
      expect(await _body(response), {
        'status': 'not_ready',
        'degraded': ['database'],
      });
    });

    // The liveness/readiness split, stated as an assertion rather than as a
    // comment. If somebody later "fixes" /health by making it fail here, this
    // is what tells them it is load-bearing: fourteen instruments under
    // scripts/ read a 200 from it as "the process is up", and a restart — the
    // only remedy a failing liveness probe triggers — cannot reach a database
    // that is down.
    test('/health still answers 200, and that is the contract', () async {
      final response = await _get(createHandler(), '/health');

      expect(response.statusCode, 200);
      expect(await _body(response), {'status': 'ok'});
    });
  });

  group('/ready on a server with a database', () {
    test('answers 200 ready when the routes needing one are mounted', () async {
      final response = await _get(_handlerWithDatabase(), '/ready');

      expect(response.statusCode, 200);
      expect(await _body(response), {'status': 'ready'});
    });

    // bin/server.dart's probe reports `database` when a connection that opened
    // at startup has since closed. The mounted-routes default cannot see that
    // — those closures are decided once and never revisited — so a supplied
    // probe has to be able to override a mounted surface, in that direction.
    test('a supplied probe overrides what the mounted routes imply', () async {
      final response = await _get(
        _handlerWithDatabase(readiness: () => {Subsystem.database}),
        '/ready',
      );

      expect(response.statusCode, 503);
      expect((await _body(response))['degraded'], ['database']);
    });
  });

  group('what /ready is allowed to say', () {
    // The disclosure decision in readiness.dart rests on the vocabulary being
    // closed and reviewable. This is the test that makes "closed" mean
    // something: a subsystem added to the enum without the disclosure question
    // being re-asked fails here, in the file where the reasoning is written
    // down, rather than shipping quietly to an unauthenticated route.
    test('the subsystem vocabulary is exactly the reviewed set', () {
      expect(Subsystem.values.map((s) => s.wireName).toList(), ['database']);
    });

    // Same reconnaissance rule /health lives under (Security Model §2.2), now
    // applied to the second unauthenticated route rather than assumed to
    // follow it.
    test('never leaks version or dependency information', () async {
      for (final handler in [createHandler(), _handlerWithDatabase()]) {
        final body = await (await _get(handler, '/ready')).readAsString();

        for (final leak in [
          'version',
          'schema',
          'dart',
          'shelf',
          'postgres',
          'dependen',
          'exception',
          'error',
        ]) {
          expect(body.toLowerCase(), isNot(contains(leak)));
        }
      }
    });

    // A header policy with holes is a header policy someone finds the hole in
    // — router.dart's own words about /health and 404s. A new route added
    // below the pipeline inherits this; a new route added above it would not,
    // and nothing else would notice.
    test('the security headers apply to it like every other route', () async {
      final response = await _get(createHandler(), '/ready');

      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(response.headers['content-type'], 'application/json');
    });
  });
}
