/// Uniform error responses (task 10.14, Security Model §4.13).
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'request_identity.dart';

/// Builds the one error shape every route returns.
///
/// `{"error": <code>, "trace_id": <id>, ...detail}` — a stable machine-
/// readable code, a correlation id, and integers only in [detail].
///
/// **`trace_id`, not `request_id`**: `/auth/magic-link`'s 202 already carries a
/// `request_id` meaning "poll this id for the link's outcome", which is a
/// different thing with a longer-lived contract. One key with two meanings on
/// one route is a trap for whoever reads the logs next.
///
/// **What is deliberately absent:** table names, column names, SQL fragments,
/// exception messages, stack traces, and framework versions. §4.13's reasoning
/// is that internal structure is reconnaissance (§2.2, §2.4), and that a
/// 404-versus-403 distinction is a working existence oracle — so a caller who
/// may not see a row and a caller asking for a row that does not exist must be
/// unable to tell which they are.
///
/// [detail] carries integers only, by convention enforced at the type level:
/// the version numbers a skew refusal needs to be actionable (§4.13's one
/// deliberate exception, task 10.11) cross the wire, and nothing else can.
Response errorResponse(
  int status,
  String code, {
  Map<String, int> detail = const {},
  String? traceId,
}) => Response(
  status,
  body: jsonEncode({
    'error': code,
    if (traceId != null) 'trace_id': traceId,
    ...detail,
  }),
  headers: const {'content-type': 'application/json'},
);

/// The error code every unhandled failure collapses to.
const String internalErrorCode = 'internal_error';

/// Catches everything a handler can throw and turns it into an opaque 500.
///
/// **Without this, shelf's default handler answers with the exception's
/// `toString()`** — which for a Postgres error is the SQL, the constraint name,
/// the table, and frequently the offending *value*. On an `Observations`
/// insert that value is a coordinate, so the framework default is
/// simultaneously a §4.13 violation (internal structure in a response) and a
/// §4.7 rule 6 violation (asset 1 in a log line and a response body).
///
/// **Server-side logging is the exception's runtime type and the request id —
/// nothing else, in every environment.** Not the message: the same
/// coordinate-bearing text that must not reach the client must not reach a log
/// file either, and §4.7's never-log list has no development exemption. The
/// type plus the correlation id is enough to find the failure; `bin/server.dart`
/// already set this precedent for connection errors.
Middleware errorHandlerMiddleware({void Function(String)? log}) {
  final write = log ?? _printLine;
  return (Handler innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } catch (error, stack) {
        final id = traceIdOf(request);
        // `stack` is deliberately received and deliberately not logged — see
        // above. Naming it documents that dropping it is a choice.
        assert(stack.toString().isNotEmpty);
        write(
          'request ${id ?? '(no id)'} failed: ${error.runtimeType} '
          'on ${request.method} ${_safePath(request)}',
        );
        return errorResponse(500, internalErrorCode, traceId: id);
      }
    };
  };
}

/// The request path, with the query string stripped.
///
/// §4.7 rule 4: the magic-link redemption route's full URL must never be
/// logged, because its query string *is* a live credential. Stripping the
/// query for every path rather than special-casing that one route means a new
/// route cannot forget to opt in.
String _safePath(Request request) => '/${request.url.path}';

// ignore: avoid_print
void _printLine(String line) => print(line);
