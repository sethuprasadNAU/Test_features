import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 10.2's acceptance criterion: "with no server URL set... a new test
/// asserts no HTTP client is constructed in the unconfigured state."
/// `serverHttpClientProvider` is the one seam any future sync code (10.7/
/// 10.8) is meant to obtain a client through, and its `http.Client()` call is
/// unreachable unless [ServerConfig.isConfigured] is true — a null result
/// here is direct evidence that line never ran.
void main() {
  setUp(installFakeSharedPreferences);

  test(
    'resolves to null when no server is configured (the default state)',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final client = await container.read(serverHttpClientProvider.future);
      expect(client, isNull);
    },
  );

  test('resolves to a usable client once a server URL is configured', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    final client = await container.read(serverHttpClientProvider.future);

    expect(client, isNotNull);
    expect(client, isA<http.Client>());
    client?.close();
  });

  test('reverts to null after the server is cleared', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    expect(await container.read(serverHttpClientProvider.future), isNotNull);

    await container.read(serverConfigProvider.notifier).clear();
    container.invalidate(serverHttpClientProvider);
    expect(await container.read(serverHttpClientProvider.future), isNull);
  });

  /// Task 10.48 (F13): `setUrl` itself does not validate — by design, see
  /// its doc comment — so this is the only place a cleartext URL to a public
  /// host is ever refused for a value that reached storage without going
  /// through the settings field's `validator:`. That is the case the finding
  /// named: "any saved value, migration, or future code path" bypasses a
  /// widget's validator, and only a check at the seam every request passes
  /// through actually closes it.
  test(
    'refuses to construct a client for a stored cleartext URL to a public host',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://tritrack.example.edu');

      // Reads the settled `AsyncValue` behind an active listener rather than
      // awaiting `.future` directly: this provider is autoDispose, and an
      // error thrown mid-build races the disposal riverpod schedules once
      // `.future` has no listener holding the element alive — the race
      // surfaces as "disposed during loading state", not the real error.
      // A listener plus a real delay avoids it.
      final sub = container.listen(serverHttpClientProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final value = container.read(serverHttpClientProvider);
      expect(value.hasError, isTrue);
      expect(value.error, isA<InvalidServerUrl>());
    },
  );
}
