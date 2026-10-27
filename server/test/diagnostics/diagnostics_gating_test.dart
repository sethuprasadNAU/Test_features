import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Finding F9 (task 10.80): the console's gates belong to the console's own
/// routes, and to nothing else.
///
/// Until this task `diagnostics_routes.dart` ended with
/// `Router()..mount('/', pipeline)` and `router.dart` mounts that at `/` too,
/// so with the console enabled **every unmatched path on the whole server**
/// went through the diagnostics gates. `/nope`, `/admin` and `/wp-login.php`
/// answered `403 diagnostics_console_local_only` — which announces the console
/// to an unauthenticated scanner in one request, and replaces the ordinary 404
/// for the entire API for as long as the console is on.
///
/// **The route list is derived from `diagnostics_routes.dart`, never typed
/// here.** A hand-kept list would pass forever the day somebody adds a tenth
/// route and forgets the gate, which is the failure this file exists to catch.
/// The derivation refuses an empty or short result: a search that finds
/// nothing and a file that declares nothing are indistinguishable from the
/// inside, and only one of them is true.
void main() {
  Future<Response> notCalled(
    Request request,
    Future<Response> Function(DiagnosticsContext) action,
  ) async {
    fail('withDiagnostics should not have been called for this request');
  }

  Handler consoleOn() => createHandler(
    diagnosticsConfig: const DiagnosticsConfig(
      enabled: true,
      allowRemote: false,
      token: 'right-token',
    ),
    withDiagnostics: notCalled,
  );

  Request get(String path) =>
      Request('GET', Uri.parse('http://localhost$path'));

  final declaredRoutes = _declaredDiagnosticsRoutes();

  test('the derivation actually read the routes it claims to gate', () {
    // Nine routes today (`health`, `projects`, `projects/<id>`,
    // `projects/<id>/rows/<table>`, `identities`, `devices`, `auth-events`,
    // `revision-anomalies`, `traffic`). Asserting "at least nine" rather than
    // "exactly nine" so adding a tenth route is not a failure — forgetting to
    // gate it is, below.
    expect(
      declaredRoutes,
      hasLength(greaterThanOrEqualTo(9)),
      reason:
          'derived ${declaredRoutes.length} route(s) from '
          '${_routesSource.path} — if that file still declares the console, '
          'this test is reading it wrong and is proving nothing',
    );
    expect(declaredRoutes, contains('/diagnostics/health'));
  });

  group('every declared route is gated', () {
    for (final route in declaredRoutes) {
      test('$route refuses an unauthenticated caller', () async {
        final response = await consoleOn()(get(_fillParams(route)));
        expect(
          response.statusCode,
          401,
          reason:
              '$route answered ${response.statusCode} with no token. Every '
              'route in diagnostics_routes.dart must be registered through '
              'its local `get` helper, which applies both gates.',
        );
      });
    }
  });

  group('and nothing else is', () {
    // The paths a scanner actually tries, plus one this server really has a
    // handler for, so the test cannot pass by the console being unmounted.
    for (final path in const [
      '/nope',
      '/admin',
      '/wp-login.php',
      '/api/v1/users',
    ]) {
      test('$path 404s with the console enabled, exactly as it does without',
          () async {
        final withConsole = await consoleOn()(get(path));
        final withoutConsole = await createHandler()(get(path));

        expect(
          withConsole.statusCode,
          404,
          reason:
              '$path answered ${withConsole.statusCode}. An unmatched path '
              'must not be answered by the diagnostics gates (finding F9).',
        );
        expect(withConsole.statusCode, withoutConsole.statusCode);

        final body = await withConsole.readAsString();
        expect(
          body,
          isNot(contains('diagnostics')),
          reason:
              'a 404 that names the console tells a scanner it exists, which '
              'is the half of F9 that is about disclosure rather than about '
              'masking the API\'s own 404s',
        );
      });
    }

    test('an undeclared path under /diagnostics 404s too', () async {
      // Not merely tidiness: `/diagnostics` is the first thing anyone would
      // try, and a gate answering there is the same one-request disclosure.
      for (final path in const [
        '/diagnostics',
        '/diagnostics/',
        '/diagnostics/secrets',
      ]) {
        final response = await consoleOn()(get(path));
        expect(response.statusCode, 404, reason: '$path was answered');
      }
    });

    test('the health route still means liveness, not the console', () async {
      // `/health` is mounted before the console and must keep answering 200
      // to an unauthenticated caller — the regression a per-route gate could
      // plausibly introduce is gating something that was never the console's.
      final response = await consoleOn()(get('/health'));
      expect(response.statusCode, 200);
      expect(
        jsonDecode(await response.readAsString()),
        {'status': 'ok'},
      );
    });
  });
}

/// The console's declared routes, read out of its source rather than listed.
///
/// Comment lines are dropped before matching, per the rule this project keeps
/// relearning: a delimiter that does not know what a comment is picks up the
/// words a human wrote *about* the code as if they were the code. The doc
/// comment above `createDiagnosticsRouter` names `/diagnostics/health`.
///
/// Matches `router.get('...` as well as the local `get('...` helper on
/// purpose — a route registered the old way would bypass the gates, and this
/// file must be able to see one in order to fail on it.
List<String> _declaredDiagnosticsRoutes() {
  final source = _routesSource.readAsLinesSync();
  final pattern = RegExp(r"""(?:router\.)?get\(\s*'(/diagnostics[^']*)'""");
  final routes = <String>[];
  for (final line in source) {
    if (line.trimLeft().startsWith('//') || line.trimLeft().startsWith('///')) {
      continue;
    }
    final match = pattern.firstMatch(line);
    if (match != null) routes.add(match.group(1)!);
  }
  return routes;
}

final File _routesSource = File('lib/src/diagnostics/diagnostics_routes.dart');

/// Turns `/diagnostics/projects/<projectId>/rows/<table>` into a concrete
/// path. The values are arbitrary: every route below refuses before any
/// handler reads them.
String _fillParams(String route) =>
    route.replaceAll(RegExp(r'<[^>]+>'), 'gated-before-this-is-read');
