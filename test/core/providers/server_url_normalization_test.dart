import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/sync/sync_transport.dart';

import '../../support/dart_source.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.37, item 1.** A server address saved as
/// `http://192.168.0.136:8080/` produced `http://192.168.0.136:8080//auth/
/// magic-link`, the server answered `404`, and the app reported it as the
/// server being unreachable. Reproduced by hand on 2026-08-26; it cost the
/// first hour of the two-device walkthrough.
///
/// The spec was explicit that fixing the sign-in call site would not do,
/// because several paths append to this value. So the assertions here are
/// about the *stored value* being canonical, and the last one derives the set
/// of call sites from the code rather than from a list somebody has to
/// remember to update.
void main() {
  setUp(installFakeSharedPreferences);

  group('normalizeServerBaseUrl', () {
    test('strips a trailing slash — the reproduced case', () {
      expect(
        normalizeServerBaseUrl('http://192.168.0.136:8080/'),
        'http://192.168.0.136:8080',
      );
    });

    test('strips several trailing slashes', () {
      expect(normalizeServerBaseUrl('http://host:8080///'), 'http://host:8080');
    });

    test('leaves an already-canonical address exactly as it is', () {
      for (final url in const [
        'http://192.168.1.42:8080',
        'https://tritrack.example.edu',
        'http://localhost:8080',
        'http://[fd00::1]:8080',
      ]) {
        expect(normalizeServerBaseUrl(url), url);
      }
    });

    test('keeps a path prefix but not its trailing slash', () {
      expect(
        normalizeServerBaseUrl('https://example.edu/tritrack/'),
        'https://example.edu/tritrack',
      );
    });

    test('drops a query and a fragment', () {
      // Neither has any meaning on a value that only ever has paths appended
      // to it, and both produce exactly the same misleading 404 if kept.
      expect(normalizeServerBaseUrl('http://host:8080/?debug=1'), 'http://host:8080');
      expect(normalizeServerBaseUrl('http://host:8080/#top'), 'http://host:8080');
    });

    test('trims surrounding whitespace', () {
      expect(
        normalizeServerBaseUrl('  http://host:8080/  '),
        'http://host:8080',
      );
    });

    test('hands back something it cannot parse rather than repairing it', () {
      // `validateServerUrl`/`requireValidServerUrl` are the two places that
      // say no. This one must not throw from inside a settings read.
      expect(normalizeServerBaseUrl('not a url'), 'not a url');
      expect(normalizeServerBaseUrl('192.168.1.42:8080/'), '192.168.1.42:8080');
    });

    test('the output can always have a path appended with one slash', () {
      const raw = [
        'http://192.168.0.136:8080/',
        'http://192.168.0.136:8080//',
        'http://192.168.0.136:8080',
        '  https://example.edu/  ',
        'https://example.edu/tritrack/',
        'http://host:8080/?x=1',
      ];
      for (final value in raw) {
        final base = normalizeServerBaseUrl(value);
        final uri = Uri.parse('$base/auth/magic-link');
        expect(
          uri.path,
          endsWith('/auth/magic-link'),
          reason: '$value produced $uri',
        );
        expect(uri.path, isNot(contains('//')), reason: '$value produced $uri');
        expect(uri.hasQuery, isFalse, reason: '$value produced $uri');
      }
    });
  });

  group('ServerConfig', () {
    test('normalises whatever it is constructed with', () {
      expect(
        ServerConfig(baseUrl: 'http://host:8080/').baseUrl,
        'http://host:8080',
      );
    });

    test('a value that is only punctuation is not "configured"', () {
      // Storing an empty string as configured would be a server that exists
      // and can never be reached.
      expect(ServerConfig(baseUrl: '///').isConfigured, isFalse);
      expect(ServerConfig(baseUrl: '   ').isConfigured, isFalse);
    });

    test('copyWith cannot smuggle a non-canonical value back in', () {
      final config = ServerConfig(baseUrl: 'http://host:8080');
      expect(
        config.copyWith(baseUrl: 'http://other:9090/').baseUrl,
        'http://other:9090',
      );
    });
  });

  group('ServerConfigNotifier', () {
    test('setUrl persists the canonical form, not what was typed', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.0.136:8080/');

      expect(
        container.read(serverConfigProvider).value!.baseUrl,
        'http://192.168.0.136:8080',
      );

      // A fresh container reads the persisted string. If `setUrl` had stored
      // the raw value and only normalised in memory, this is where it shows.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      expect(
        (await second.read(serverConfigProvider.future)).baseUrl,
        'http://192.168.0.136:8080',
      );
    });

    test(
      'a trailing slash saved by an older build is fixed on read, without '
      're-saving the field',
      () async {
        // **This is the case that matters most and the one a save-time-only
        // fix would miss.** The address is already in SharedPreferences on
        // every device that typed it before this change. Nobody is going to
        // re-open Server Connection and re-type it, because from the outside
        // the symptom is "the server is down".
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData({
              'server_base_url_v1': 'http://192.168.0.136:8080/',
            });

        final container = ProviderContainer();
        addTearDown(container.dispose);

        final config = await container.read(serverConfigProvider.future);
        expect(config.baseUrl, 'http://192.168.0.136:8080');
      },
    );
  });

  group('the address as every caller actually uses it', () {
    test('AuthClient built from a slash-suffixed config hits the real route',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.0.136:8080/');
      final config = await container.read(serverConfigProvider.future);

      late Uri requested;
      final client = AuthClient(
        baseUrl: config.baseUrl!,
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response('{"request_id":"r1"}', 202);
        }),
      );
      await client.requestMagicLink('sam@example.com');

      expect(requested.toString(), 'http://192.168.0.136:8080/auth/magic-link');
    });

    test('HttpSyncTransport built from the same config does too', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.0.136:8080/');
      final config = await container.read(serverConfigProvider.future);

      late Uri requested;
      final transport = HttpSyncTransport(
        baseUrl: config.baseUrl!,
        sessionToken: 'tok',
        httpClient: MockClient((request) async {
          requested = request.url;
          return http.Response('{"error":"server_rejected"}', 500);
        }),
      );
      await expectLater(
        transport.listMyProjects(),
        throwsA(isA<SyncTransportException>()),
      );

      expect(requested.toString(), 'http://192.168.0.136:8080/projects/mine');
    });
  });

  test(
    'every baseUrl argument in lib/ comes from a ServerConfig, so a new '
    'caller inherits the normalisation without knowing it exists',
    () {
      // **Derived from the code, not from a list.** The spec's instruction was
      // "do not fix this at the one call site that happened to be hit", and a
      // guard naming today's five call sites would have exactly the failure
      // mode it warns about: the sixth one lands, nothing objects, and the
      // symptom shows up on somebody's phone in the field. This asks instead
      // whether any `baseUrl:` argument anywhere in `lib/` is fed from
      // something other than the normalising type.
      final offenders = <String>[];
      final argument = RegExp(r'\bbaseUrl:\s*([^,\n)]+)');
      for (final file in dartFilesUnder('lib')) {
        // The declaring file is where normalisation is defined; its own
        // `baseUrl:` arguments are the constructor being called on raw input,
        // which is the point.
        if (file.path.endsWith('server_config_provider.dart')) continue;
        final source = stripComments(file.readAsStringSync());
        for (final match in argument.allMatches(source)) {
          final value = match.group(1)!.trim();
          // `this.baseUrl` is a constructor parameter declaration, not an
          // argument, and the field it initialises is typed String either way.
          if (value.startsWith('this.')) continue;
          final fromConfig =
              RegExp(r'^config\.baseUrl!?$').hasMatch(value) ||
              value.contains('normalizeServerBaseUrl(');
          if (!fromConfig) {
            offenders.add('${file.path}: baseUrl: $value');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These pass a server address that never went through '
            'ServerConfig, so a trailing slash reaches the wire and the '
            'server answers 404:\n${offenders.join('\n')}',
      );
    },
  );

  test('the guard above can actually see a violation', () {
    // A check that cannot distinguish success from its own failure is not a
    // check. The regex is asserted against a line of the exact shape it is
    // meant to catch, since the real scan passing tells us nothing on its own.
    const violating = "AuthClient(httpClient: c, baseUrl: 'http://host:8080/')";
    final match = RegExp(r'\bbaseUrl:\s*([^,\n)]+)').firstMatch(violating);
    expect(match, isNotNull);
    expect(match!.group(1)!.trim(), "'http://host:8080/'");
    expect(
      RegExp(r'^config\.baseUrl!?$').hasMatch(match.group(1)!.trim()),
      isFalse,
    );
  });
}
