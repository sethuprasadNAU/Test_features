import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 10.2's core invariant: "not configured" is the default, first-class
/// state — not a placeholder waiting to be replaced. Every assertion here is
/// really about that: what the provider returns before anything is ever set,
/// and that setting/clearing it behaves exactly like a normal settings field.
void main() {
  setUp(installFakeSharedPreferences);

  test('defaults to unconfigured with no prior state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final config = await container.read(serverConfigProvider.future);
    expect(config.isConfigured, isFalse);
    expect(config.baseUrl, isNull);
  });

  test('setUrl persists a trimmed URL and isConfigured flips true', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(serverConfigProvider.notifier)
        .setUrl('  http://192.168.1.42:8080  ');

    final config = container.read(serverConfigProvider).value!;
    expect(config.isConfigured, isTrue);
    expect(config.baseUrl, 'http://192.168.1.42:8080');
  });

  test(
    'the configured URL survives a fresh provider container (restart)',
    () async {
      final first = ProviderContainer();
      await first
          .read(serverConfigProvider.notifier)
          .setUrl('https://tritrack.example.edu');
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      final config = await second.read(serverConfigProvider.future);
      expect(config.baseUrl, 'https://tritrack.example.edu');
    },
  );

  test(
    'setUrl with an empty/whitespace value clears the configuration',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      expect(container.read(serverConfigProvider).value!.isConfigured, isTrue);

      await container.read(serverConfigProvider.notifier).setUrl('   ');
      final config = container.read(serverConfigProvider).value!;
      expect(config.isConfigured, isFalse);
      expect(config.baseUrl, isNull);
    },
  );

  test(
    'clear() returns to the unconfigured state and removes the stored value',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      await container.read(serverConfigProvider.notifier).clear();

      expect(container.read(serverConfigProvider).value!.isConfigured, isFalse);

      // A fresh container reading from the same (fake) persisted store must
      // also see "unconfigured" — clear() has to remove the key, not just
      // reset in-memory state, or a restart would resurrect the old URL.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      expect(
        (await second.read(serverConfigProvider.future)).isConfigured,
        isFalse,
      );
    },
  );

  group('validateServerUrl', () {
    test('accepts an empty value (represents "clear")', () {
      expect(validateServerUrl(''), isNull);
      expect(validateServerUrl('   '), isNull);
      expect(validateServerUrl(null), isNull);
    });

    test(
      'accepts absolute http/https URLs, including bare LAN IPs with a port',
      () {
        expect(validateServerUrl('http://192.168.1.42:8080'), isNull);
        expect(validateServerUrl('https://tritrack.example.edu'), isNull);
      },
    );

    test('rejects a non-URL value', () {
      expect(validateServerUrl('not a url'), isNotNull);
    });

    test('rejects a scheme other than http/https', () {
      expect(validateServerUrl('ftp://example.com'), isNotNull);
    });

    test('rejects a relative/schemeless value', () {
      expect(validateServerUrl('192.168.1.42:8080'), isNotNull);
    });
  });
}
