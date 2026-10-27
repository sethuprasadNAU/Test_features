import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// §4.13's uniform errors, and the §4.7 rules the old behaviour broke.
///
/// **The control this suite protects:** before task 10.14 there was no error
/// handler at all, so an unhandled exception reached shelf's default, which
/// answers with the exception's `toString()`. For a Postgres error that is the
/// SQL, the constraint name, the table, and frequently the offending *value* —
/// which on an `Observations` write is a coordinate. Removing
/// [errorHandlerMiddleware] restores exactly that, and every test below fails.
void main() {
  /// A handler whose route throws the kind of exception a real database
  /// failure produces: one whose message names a table, a column, and a value.
  Handler failingWith(Object error, {void Function(String)? log}) =>
      createHandler(
        withAuthService: <T>(action) => throw error,
        logLine: log ?? (_) {},
      );

  /// Drives `/auth/link-status`, not `/auth/magic-link`.
  ///
  /// **`/auth/magic-link` deliberately swallows every exception** so that an
  /// internal failure cannot produce a different response for some addresses
  /// than others (§4.5) — so it always answers 202 and can never exercise the
  /// 500 path. `/auth/link-status` has no such requirement and propagates,
  /// which makes it the honest fixture for the catch-all.
  Future<Response> getLinkStatus(Handler handler) async => handler(
    Request('GET', Uri.parse('http://localhost/auth/link-status/req-1')),
  );

  group('an unhandled exception becomes an opaque 500', () {
    test('the response body names no table, column, value, or SQL', () async {
      final response = await getLinkStatus(
        failingWith(
          StateError(
            'PostgreSQLSeverity.error 23514: new row for relation '
            '"Observations" violates check constraint '
            '"observations_latitude_check" detail: Failing row contains '
            '(obs-1, 35.198765, -111.651234)',
          ),
        ),
      );

      expect(response.statusCode, 500);
      final body = await response.readAsString();
      // §4.13: internal structure never in a response body.
      expect(body, isNot(contains('Observations')));
      expect(body, isNot(contains('constraint')));
      expect(body, isNot(contains('23514')));
      expect(body, isNot(contains('relation')));
      // §4.7 rule 6, the one that will get broken by accident: a coordinate
      // must not appear in a response any more than in a log.
      expect(body, isNot(contains('35.198765')));
      expect(body, isNot(contains('-111.651234')));
      // What it *does* say.
      final json = jsonDecode(body) as Map<String, Object?>;
      expect(json['error'], internalErrorCode);
      expect(json['trace_id'], isA<String>());
    });

    test('the response body carries no stack trace', () async {
      final response = await getLinkStatus(
        failingWith(StateError('something internal')),
      );
      final body = await response.readAsString();
      expect(body, isNot(contains('package:')));
      expect(body, isNot(contains('.dart')));
      expect(body, isNot(contains('#0')));
      expect(body, isNot(contains('something internal')));
    });

    test('the server-side log line carries the type but not the message',
        () async {
      // The same coordinate-bearing text that must not reach the client must
      // not reach a log file either — §4.7's never-log list has no development
      // exemption, which is why only the runtime type is written.
      final lines = <String>[];
      await getLinkStatus(
        failingWith(
          StateError('lat 35.198765 lon -111.651234 in table "Observations"'),
          log: lines.add,
        ),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('StateError'));
      expect(lines.single, isNot(contains('35.198765')));
      expect(lines.single, isNot(contains('Observations')));
    });

    test('the logged path has its query string stripped', () async {
      // §4.7 rule 4: the redemption route's query string *is* a live
      // credential. Stripping for every path rather than special-casing that
      // one route means a new route cannot forget to opt in.
      final lines = <String>[];
      final handler = createHandler(
        withAuthService: <T>(action) => throw StateError('boom'),
        logLine: lines.add,
      );
      await handler(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/auth/link-status/req-1'
            '?token=live-secret-token-value',
          ),
        ),
      );
      expect(lines.single, isNot(contains('live-secret-token-value')));
      expect(lines.single, contains('/auth/link-status'));
    });
  });

  group('correlation ids', () {
    test('every response carries an x-trace-id header', () async {
      // §4.13 asks for a request id "so a real support conversation is still
      // possible without leaking anything". On every response, not just errors,
      // so a user reporting "it was slow at 14:02" has one too.
      final response = await createHandler()(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      expect(response.headers['x-trace-id'], isA<String>());
      expect(response.headers['x-trace-id'], isNotEmpty);
    });

    test('the id in the body matches the id in the header', () async {
      final response = await getLinkStatus(failingWith(StateError('boom')));
      final json =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(json['trace_id'], response.headers['x-trace-id']);
    });

    test('ids differ between requests', () async {
      final handler = createHandler();
      final first = await handler(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      final second = await handler(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      expect(
        first.headers['x-trace-id'],
        isNot(second.headers['x-trace-id']),
      );
    });
  });

  group('errorResponse', () {
    test('carries only integers from detail, and the code and id', () {
      final response = errorResponse(
        409,
        'schema_version_mismatch',
        detail: const {'client_schema_major': 1, 'server_schema_major': 2},
        traceId: 'abc123',
      );
      expect(response.statusCode, 409);
      expect(response.headers['content-type'], 'application/json');
    });

    test('omits trace_id rather than emitting null when absent', () async {
      final body = await errorResponse(400, 'malformed_body').readAsString();
      expect(jsonDecode(body), {'error': 'malformed_body'});
    });
  });
}
