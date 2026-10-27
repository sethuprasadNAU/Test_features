import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// `test/health_test.dart` calls the `Handler` directly — cheap, but it can't
/// see anything `shelf_io.serve` itself adds to the real response, such as
/// its default `X-Powered-By` header. This starts the actual bound server
/// (an ephemeral loopback port, not the app's 0.0.0.0/`PORT` — this test
/// doesn't need LAN reachability, just a real socket) and hits it over HTTP,
/// so a regression like that default header creeping back in is caught here
/// rather than only by manual `curl`.
void main() {
  late HttpServer server;
  late Uri baseUri;

  setUp(() async {
    server = await shelf_io.serve(
      createHandler(),
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    baseUri = Uri.parse('http://${server.address.address}:${server.port}');
  });

  tearDown(() => server.close(force: true));

  test(
    'a real HTTP round-trip to /health succeeds with no fingerprinting headers',
    () async {
      final response = await http.get(baseUri.replace(path: '/health'));

      expect(response.statusCode, 200);
      expect(
        response.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-powered-by')),
      );
    },
  );
}
